/**
 * Unit tests for upload-cleanup-worker.
 * All external calls are stubbed via the Deps interface.
 *
 * Run with:
 *   deno test --allow-env \
 *     supabase/functions/upload-cleanup-worker/upload-cleanup-worker.test.ts
 */
import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import type { SupabaseClient } from "npm:@supabase/supabase-js@2.112.3";
import { makeHandler, timingSafeEqualStr } from "./index.ts";
import type { Deps } from "./index.ts";

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

const VALID_SECRET = "supersecretcronvalue12345678901234567890";
const SESSION_ID_1 = "00000000-0000-0000-0000-000000000011";
const CLAIM_TOKEN_1 = "00000000-0000-0000-0000-000000000099";
const MEDIA_ID_1 = "00000000-0000-0000-0000-000000000022";
const EXPIRY_SID_1 = "00000000-0000-0000-0000-000000000033";

function makeRequest(cronSecret?: string): Request {
  const headers: Record<string, string> = {
    "Content-Type": "application/json",
  };
  if (cronSecret !== undefined) {
    headers["X-Forkensics-Cron-Secret"] = cronSecret;
  }
  return new Request("https://example.com/upload-cleanup-worker", {
    method: "POST",
    headers,
    body: "{}",
  });
}

function makeDeps(overrides: Partial<Deps> = {}): Deps {
  return {
    getAdminClient: () => ({} as SupabaseClient),
    timingSafeEqual: timingSafeEqualStr,
    getCronSecret: () => VALID_SECRET,
    claimCleanupSessions: (_admin, _wid) =>
      Promise.resolve({ data: [], error: null }),
    markSessionCleaned: (_admin, _sid, _tok) =>
      Promise.resolve({ error: null }),
    getSupersededMedia: (_admin) => Promise.resolve({ data: [], error: null }),
    markSupersededMediaCleaned: (_admin, _mid) =>
      Promise.resolve({ error: null }),
    getExpiryCleanupSessions: (_admin) =>
      Promise.resolve({ data: [], error: null }),
    markOriginalPathCleaned: (_admin, _sid) => Promise.resolve({ error: null }),
    deleteFromR2: (_key) => Promise.resolve(),
    ...overrides,
  };
}

// ---------------------------------------------------------------------------
// Gateway-bypass and authentication tests (§7)
// ---------------------------------------------------------------------------

Deno.test(
  "No X-Forkensics-Cron-Secret header, no JWT → 401 with FK error body (not gateway 401)",
  async () => {
    const handler = makeHandler(makeDeps());
    const res = await handler(makeRequest()); // no header
    assertEquals(res.status, 401);
    const body = await res.json();
    // FK error envelope distinguishes this from the platform gateway 401
    assertEquals(body.error.code, "FK_UNAUTHENTICATED");
  },
);

Deno.test(
  "X-Forkensics-Cron-Secret with incorrect value, no JWT → 401 with FK error body",
  async () => {
    const handler = makeHandler(makeDeps());
    const res = await handler(makeRequest("wrong-secret-value"));
    assertEquals(res.status, 401);
    const body = await res.json();
    assertEquals(body.error.code, "FK_UNAUTHENTICATED");
  },
);

Deno.test(
  "X-Forkensics-Cron-Secret with correct value, no JWT → proceeds (not rejected); 200",
  async () => {
    const handler = makeHandler(makeDeps());
    const res = await handler(makeRequest(VALID_SECRET));
    assertEquals(res.status, 200);
    const body = await res.json();
    assertEquals(body.status, "ok");
  },
);

// ---------------------------------------------------------------------------
// Functional tests
// ---------------------------------------------------------------------------

Deno.test("Valid CRON_SECRET → runs all three parts; returns 200", async () => {
  const part1Called: string[] = [];
  const part2Called: string[] = [];
  const part3Called: string[] = [];
  const handler = makeHandler(makeDeps({
    claimCleanupSessions: (_admin, _wid) => {
      part1Called.push("claim");
      return Promise.resolve({ data: [], error: null });
    },
    getSupersededMedia: (_admin) => {
      part2Called.push("superseded");
      return Promise.resolve({ data: [], error: null });
    },
    getExpiryCleanupSessions: (_admin) => {
      part3Called.push("expiry");
      return Promise.resolve({ data: [], error: null });
    },
  }));
  const res = await handler(makeRequest(VALID_SECRET));
  assertEquals(res.status, 200);
  assertEquals(part1Called, ["claim"]);
  assertEquals(part2Called, ["superseded"]);
  assertEquals(part3Called, ["expiry"]);
});

Deno.test("Part 1: deletion succeeds → mark_session_cleaned called", async () => {
  const marked: string[] = [];
  const handler = makeHandler(makeDeps({
    claimCleanupSessions: (_admin, _wid) =>
      Promise.resolve({
        data: [{
          session_id: SESSION_ID_1,
          original_storage_path: `originals/${SESSION_ID_1}`,
          display_storage_path: `display/${SESSION_ID_1}.webp`,
          status: "failed",
          cleanup_claim_token: CLAIM_TOKEN_1,
        }],
        error: null,
      }),
    deleteFromR2: (_key) => Promise.resolve(),
    markSessionCleaned: (_admin, sid, _tok) => {
      marked.push(sid);
      return Promise.resolve({ error: null });
    },
  }));
  const res = await handler(makeRequest(VALID_SECRET));
  assertEquals(res.status, 200);
  assertEquals(marked, [SESSION_ID_1]);
});

Deno.test("Part 1: deletion fails → no mark; next run retries", async () => {
  const marked: string[] = [];
  const handler = makeHandler(makeDeps({
    claimCleanupSessions: (_admin, _wid) =>
      Promise.resolve({
        data: [{
          session_id: SESSION_ID_1,
          original_storage_path: `originals/${SESSION_ID_1}`,
          display_storage_path: `display/${SESSION_ID_1}.webp`,
          status: "failed",
          cleanup_claim_token: CLAIM_TOKEN_1,
        }],
        error: null,
      }),
    deleteFromR2: (_key) => Promise.reject(new Error("R2 error")),
    markSessionCleaned: (_admin, sid, _tok) => {
      marked.push(sid);
      return Promise.resolve({ error: null });
    },
  }));
  const res = await handler(makeRequest(VALID_SECRET));
  assertEquals(res.status, 200);
  assertEquals(marked, []); // must NOT mark when deletion fails
});

Deno.test("Part 2: superseded key deletion → mark_superseded_media_cleaned", async () => {
  const marked: string[] = [];
  const handler = makeHandler(makeDeps({
    getSupersededMedia: (_admin) =>
      Promise.resolve({
        data: [{
          media_object_id: MEDIA_ID_1,
          re_encoded_storage_key: `display/${MEDIA_ID_1}.webp`,
        }],
        error: null,
      }),
    deleteFromR2: (_key) => Promise.resolve(),
    markSupersededMediaCleaned: (_admin, mid) => {
      marked.push(mid);
      return Promise.resolve({ error: null });
    },
  }));
  const res = await handler(makeRequest(VALID_SECRET));
  assertEquals(res.status, 200);
  assertEquals(marked, [MEDIA_ID_1]);
});

Deno.test("Part 3: original-path deletion → mark_original_path_post_expiry_cleaned", async () => {
  const marked: string[] = [];
  const handler = makeHandler(makeDeps({
    getExpiryCleanupSessions: (_admin) =>
      Promise.resolve({
        data: [{
          session_id: EXPIRY_SID_1,
          original_storage_path: `originals/${EXPIRY_SID_1}`,
        }],
        error: null,
      }),
    deleteFromR2: (_key) => Promise.resolve(),
    markOriginalPathCleaned: (_admin, sid) => {
      marked.push(sid);
      return Promise.resolve({ error: null });
    },
  }));
  const res = await handler(makeRequest(VALID_SECRET));
  assertEquals(res.status, 200);
  assertEquals(marked, [EXPIRY_SID_1]);
});

Deno.test("Part 3: deletion fails → no mark", async () => {
  const marked: string[] = [];
  const handler = makeHandler(makeDeps({
    getExpiryCleanupSessions: (_admin) =>
      Promise.resolve({
        data: [{
          session_id: EXPIRY_SID_1,
          original_storage_path: `originals/${EXPIRY_SID_1}`,
        }],
        error: null,
      }),
    deleteFromR2: (_key) => Promise.reject(new Error("R2 error")),
    markOriginalPathCleaned: (_admin, sid) => {
      marked.push(sid);
      return Promise.resolve({ error: null });
    },
  }));
  const res = await handler(makeRequest(VALID_SECRET));
  assertEquals(res.status, 200);
  assertEquals(marked, []); // must NOT mark when deletion fails
});

// ---------------------------------------------------------------------------
// timingSafeEqualStr unit tests
// ---------------------------------------------------------------------------

Deno.test("timingSafeEqualStr: identical strings → true", () => {
  assertEquals(timingSafeEqualStr("abc", "abc"), true);
});

Deno.test("timingSafeEqualStr: different strings, same length → false", () => {
  assertEquals(timingSafeEqualStr("abc", "abd"), false);
});

Deno.test("timingSafeEqualStr: different lengths → false", () => {
  assertEquals(timingSafeEqualStr("abc", "abcd"), false);
});

Deno.test("timingSafeEqualStr: both empty → true", () => {
  assertEquals(timingSafeEqualStr("", ""), true);
});

Deno.test("timingSafeEqualStr: one empty → false", () => {
  assertEquals(timingSafeEqualStr("", "x"), false);
});
