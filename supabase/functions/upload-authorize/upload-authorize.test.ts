/**
 * Unit tests for upload-authorize.
 * All external calls are stubbed via the Deps interface.
 *
 * Run with:
 *   deno test --allow-net --allow-env --allow-read \
 *     supabase/functions/upload-authorize/upload-authorize.test.ts
 */
import {
  assert,
  assertEquals,
  assertThrows,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import type { SupabaseClient } from "npm:@supabase/supabase-js@2.112.3";
import { makeHandler } from "./index.ts";
import type { Deps } from "./index.ts";
import { parseAmzExpiry } from "../_shared/s3.ts";
import type { ProfileCheckResult } from "../_shared/profile.ts";

// ---------------------------------------------------------------------------
// Shared fixtures
// ---------------------------------------------------------------------------

const VALID_CASE_ID = "00000000-0000-0000-0000-000000000001";
const VALID_USER_ID = "00000000-0000-0000-0000-000000000002";
const SESSION_ID = "00000000-0000-0000-0000-000000000003";
const RAW_TOKEN = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"; // 43 chars
const TOKEN_HASH = "a".repeat(64);
const ORIG_PATH = `originals/${SESSION_ID}`;
// Valid signed URL: X-Amz-Date=20260813T120000Z, X-Amz-Expires=300 → expires 12:05:00Z
const PRESIGNED_URL =
  "https://s3.local/game-media/path?X-Amz-Date=20260813T120000Z&X-Amz-Expires=300&X-Amz-Credential=x&X-Amz-Signature=x";
const EXPIRES_AT = new Date("2026-08-13T12:05:00.000Z");

function makeOkAuthResult(userId = VALID_USER_ID) {
  return {
    ok: true as const,
    ctx: {
      userClaims: { id: userId },
      supabase: {} as SupabaseClient,
      supabaseAdmin: {} as SupabaseClient,
    },
    error: null,
  };
}

function makeAuthFailResult() {
  return {
    ok: false as const,
    ctx: null,
    error: new Response(
      JSON.stringify({
        error: { code: "FK_UNAUTHENTICATED", message: "Unauthorized" },
      }),
      {
        status: 401,
        headers: {
          "Content-Type": "application/json",
          "Cache-Control": "no-store",
        },
      },
    ),
  };
}

function makePostRequest(
  body: Record<string, unknown> = {
    case_id: VALID_CASE_ID,
    content_type: "image/jpeg",
    declared_size_bytes: 1024,
  },
): Request {
  return new Request("https://example.com/upload-authorize", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
}

/**
 * Returns a clean Deps object with all calls stubbed.
 * Stubs return Promise.resolve() rather than being async to satisfy
 * deno lint's require-await rule.
 */
function makeHappyDeps(overrides: Partial<Deps> = {}): Deps {
  return {
    generateToken: () => RAW_TOKEN,
    sha256: (_data) => Promise.resolve(TOKEN_HASH),
    getAuth: (_req) => Promise.resolve(makeOkAuthResult()),
    checkProfile: (_supabase, _userId) =>
      Promise.resolve<ProfileCheckResult>({ status: "ok" }),
    reserveSession: (_admin, _params) =>
      Promise.resolve({
        data: {
          session_id: SESSION_ID,
          original_storage_path: ORIG_PATH,
          display_storage_path: `display/${SESSION_ID}.webp`,
        },
        error: null,
      }),
    activateSession: (_admin, _params) =>
      Promise.resolve({ data: null, error: null }),
    failSession: (_admin, _id, _code) =>
      Promise.resolve({ data: null, error: null }),
    presign: (_path, _expiresIn, _contentType) =>
      Promise.resolve({ url: PRESIGNED_URL, expiresAt: EXPIRES_AT }),
    now: () => new Date("2026-08-13T12:00:00.000Z"),
    ...overrides,
  };
}

// ---------------------------------------------------------------------------
// T-A-P-* parseAmzExpiry unit tests
// ---------------------------------------------------------------------------

function buildAmzUrl(params: Record<string, string>): string {
  const u = new URL("https://s3.example.com/bucket/key");
  for (const [k, v] of Object.entries(params)) u.searchParams.set(k, v);
  return u.toString();
}

Deno.test("T-A-P-01: valid date returns start + 300s", () => {
  const url = buildAmzUrl({
    "X-Amz-Date": "20260813T120000Z",
    "X-Amz-Expires": "300",
  });
  const result = parseAmzExpiry(url);
  assertEquals(result.toISOString(), "2026-08-13T12:05:00.000Z");
});

Deno.test("T-A-P-02: missing X-Amz-Date throws", () => {
  const url = buildAmzUrl({ "X-Amz-Expires": "300" });
  assertThrows(() => parseAmzExpiry(url), Error);
});

Deno.test("T-A-P-03: missing X-Amz-Expires throws", () => {
  const url = buildAmzUrl({ "X-Amz-Date": "20260813T120000Z" });
  assertThrows(() => parseAmzExpiry(url), Error);
});

Deno.test("T-A-P-04: truncated X-Amz-Date throws", () => {
  const url = buildAmzUrl({
    "X-Amz-Date": "20260813T1200",
    "X-Amz-Expires": "300",
  });
  assertThrows(() => parseAmzExpiry(url), Error);
});

Deno.test("T-A-P-05: non-numeric X-Amz-Date throws", () => {
  const url = buildAmzUrl({
    "X-Amz-Date": "XXXXXXXXTXXXXXXZ",
    "X-Amz-Expires": "300",
  });
  assertThrows(() => parseAmzExpiry(url), Error);
});

Deno.test("T-A-P-06: X-Amz-Expires=600 throws", () => {
  const url = buildAmzUrl({
    "X-Amz-Date": "20260813T120000Z",
    "X-Amz-Expires": "600",
  });
  assertThrows(() => parseAmzExpiry(url), Error);
});

Deno.test("T-A-P-07: X-Amz-Expires=0 throws", () => {
  const url = buildAmzUrl({
    "X-Amz-Date": "20260813T120000Z",
    "X-Amz-Expires": "0",
  });
  assertThrows(() => parseAmzExpiry(url), Error);
});

Deno.test("T-A-P-08: X-Amz-Expires=299 throws", () => {
  const url = buildAmzUrl({
    "X-Amz-Date": "20260813T120000Z",
    "X-Amz-Expires": "299",
  });
  assertThrows(() => parseAmzExpiry(url), Error);
});

Deno.test("T-A-P-09: result equals parseAmzDate + 300s", () => {
  const url = buildAmzUrl({
    "X-Amz-Date": "20260813T120000Z",
    "X-Amz-Expires": "300",
  });
  const start = new Date("2026-08-13T12:00:00.000Z").getTime();
  assertEquals(parseAmzExpiry(url).getTime(), start + 300_000);
});

Deno.test("T-A-P-10: month 13 throws", () => {
  const url = buildAmzUrl({
    "X-Amz-Date": "20261399T120000Z",
    "X-Amz-Expires": "300",
  });
  assertThrows(() => parseAmzExpiry(url), Error);
});

Deno.test("T-A-P-11: Feb 29 non-leap year throws", () => {
  const url = buildAmzUrl({
    "X-Amz-Date": "20260229T120000Z",
    "X-Amz-Expires": "300",
  });
  assertThrows(() => parseAmzExpiry(url), Error);
});

Deno.test("T-A-P-12: April 31 throws", () => {
  const url = buildAmzUrl({
    "X-Amz-Date": "20260431T120000Z",
    "X-Amz-Expires": "300",
  });
  assertThrows(() => parseAmzExpiry(url), Error);
});

Deno.test("T-A-P-13: hour 25 throws", () => {
  const url = buildAmzUrl({
    "X-Amz-Date": "20260101T250000Z",
    "X-Amz-Expires": "300",
  });
  assertThrows(() => parseAmzExpiry(url), Error);
});

Deno.test("T-A-P-14: minute 60 throws", () => {
  const url = buildAmzUrl({
    "X-Amz-Date": "20260101T126000Z",
    "X-Amz-Expires": "300",
  });
  assertThrows(() => parseAmzExpiry(url), Error);
});

Deno.test("T-A-P-15: second 60 throws", () => {
  const url = buildAmzUrl({
    "X-Amz-Date": "20260101T120060Z",
    "X-Amz-Expires": "300",
  });
  assertThrows(() => parseAmzExpiry(url), Error);
});

// ---------------------------------------------------------------------------
// T-A-01 to T-A-07 — Happy path (unit)
// ---------------------------------------------------------------------------

Deno.test("T-A-01: valid JPEG returns 200 with required fields", async () => {
  const handler = makeHandler(makeHappyDeps());
  const res = await handler(makePostRequest());
  assertEquals(res.status, 200);
  assertEquals(res.headers.get("Cache-Control"), "no-store");
  const body = await res.json();
  assert(typeof body.presigned_url === "string");
  assert(typeof body.upload_token === "string");
  assert(typeof body.expires_at === "string");
  assert(!("session_id" in body));
});

Deno.test("T-A-02: valid WebP returns 200", async () => {
  const handler = makeHandler(makeHappyDeps());
  const res = await handler(
    makePostRequest({
      case_id: VALID_CASE_ID,
      content_type: "image/webp",
      declared_size_bytes: 512,
    }),
  );
  assertEquals(res.status, 200);
});

Deno.test(
  "T-A-03: expires_at matches presign result, not local clock",
  async () => {
    const handler = makeHandler(makeHappyDeps());
    const res = await handler(makePostRequest());
    const body = await res.json();
    assertEquals(body.expires_at, EXPIRES_AT.toISOString());
  },
);

Deno.test("T-A-05: session_id absent from 200 body", async () => {
  const handler = makeHandler(makeHappyDeps());
  const res = await handler(makePostRequest());
  const body = await res.json();
  assert(!("session_id" in body));
});

Deno.test(
  "T-A-07: expires_at = X-Amz-Date + 300s (parseAmzExpiry invariant)",
  async () => {
    const handler = makeHandler(makeHappyDeps());
    const res = await handler(makePostRequest());
    const body = await res.json();
    assertEquals(body.expires_at, "2026-08-13T12:05:00.000Z");
  },
);

// ---------------------------------------------------------------------------
// T-A-08 to T-A-10 — Method enforcement
// ---------------------------------------------------------------------------

Deno.test(
  "T-A-08: GET returns 405 with Allow: POST and Cache-Control: no-store",
  async () => {
    const handler = makeHandler(makeHappyDeps());
    const res = await handler(
      new Request("https://example.com/upload-authorize", { method: "GET" }),
    );
    assertEquals(res.status, 405);
    assertEquals(res.headers.get("Allow"), "POST");
    assertEquals(res.headers.get("Cache-Control"), "no-store");
  },
);

Deno.test("T-A-09: PUT returns 405", async () => {
  const handler = makeHandler(makeHappyDeps());
  const res = await handler(
    new Request("https://example.com/upload-authorize", { method: "PUT" }),
  );
  assertEquals(res.status, 405);
});

Deno.test("T-A-10: DELETE returns 405", async () => {
  const handler = makeHandler(makeHappyDeps());
  const res = await handler(
    new Request("https://example.com/upload-authorize", { method: "DELETE" }),
  );
  assertEquals(res.status, 405);
});

// ---------------------------------------------------------------------------
// T-A-auth-cc — Auth failure handler wiring (stub)
// ---------------------------------------------------------------------------

Deno.test(
  "T-A-auth-cc: stubAuthFail returns 401 with Cache-Control: no-store",
  async () => {
    const handler = makeHandler(
      makeHappyDeps({
        getAuth: (_req) => Promise.resolve(makeAuthFailResult()),
      }),
    );
    const res = await handler(makePostRequest());
    assertEquals(res.status, 401);
    assertEquals(res.headers.get("Cache-Control"), "no-store");
  },
);

// ---------------------------------------------------------------------------
// T-A-14 to T-A-19 — Profile checks (unit stubs)
// ---------------------------------------------------------------------------

async function profileTest(
  profile: ProfileCheckResult,
): Promise<{ status: number; code: string }> {
  const handler = makeHandler(
    makeHappyDeps({
      checkProfile: (_s, _u) => Promise.resolve(profile),
    }),
  );
  const res = await handler(makePostRequest());
  const body = await res.json();
  return { status: res.status, code: body.error.code };
}

Deno.test("T-A-14: is_active=false → 403 FK_FORBIDDEN", async () => {
  const r = await profileTest({ status: "forbidden", reason: "inactive" });
  assertEquals(r.status, 403);
  assertEquals(r.code, "FK_FORBIDDEN");
});

Deno.test("T-A-16: onboarding_complete=false → 403 FK_FORBIDDEN", async () => {
  const r = await profileTest({ status: "forbidden", reason: "incomplete" });
  assertEquals(r.status, 403);
  assertEquals(r.code, "FK_FORBIDDEN");
});

Deno.test("T-A-17: is_suspended=true → 403 FK_FORBIDDEN", async () => {
  const r = await profileTest({ status: "forbidden", reason: "suspended" });
  assertEquals(r.status, 403);
  assertEquals(r.code, "FK_FORBIDDEN");
});

Deno.test("T-A-18: profile absent → 403 FK_FORBIDDEN", async () => {
  const r = await profileTest({ status: "forbidden", reason: "absent" });
  assertEquals(r.status, 403);
  assertEquals(r.code, "FK_FORBIDDEN");
});

Deno.test("T-A-19: profile error → 500 FK_INTERNAL", async () => {
  const r = await profileTest({ status: "error" });
  assertEquals(r.status, 500);
  assertEquals(r.code, "FK_INTERNAL");
});

// ---------------------------------------------------------------------------
// T-A-20 to T-A-30 — Request validation
// ---------------------------------------------------------------------------

Deno.test("T-A-20: missing case_id → 400 FK_INVALID_INPUT", async () => {
  const handler = makeHandler(makeHappyDeps());
  const res = await handler(
    makePostRequest({ content_type: "image/jpeg", declared_size_bytes: 1024 }),
  );
  assertEquals(res.status, 400);
  assertEquals((await res.json()).error.code, "FK_INVALID_INPUT");
});

Deno.test("T-A-21: invalid case_id UUID → 400 FK_INVALID_INPUT", async () => {
  const handler = makeHandler(makeHappyDeps());
  const res = await handler(
    makePostRequest({
      case_id: "not-a-uuid",
      content_type: "image/jpeg",
      declared_size_bytes: 1024,
    }),
  );
  assertEquals(res.status, 400);
  assertEquals((await res.json()).error.code, "FK_INVALID_INPUT");
});

Deno.test(
  "T-A-22: missing content_type → 400 FK_INVALID_CONTENT_TYPE",
  async () => {
    const handler = makeHandler(makeHappyDeps());
    const res = await handler(
      makePostRequest({ case_id: VALID_CASE_ID, declared_size_bytes: 1024 }),
    );
    assertEquals(res.status, 400);
    assertEquals((await res.json()).error.code, "FK_INVALID_CONTENT_TYPE");
  },
);

Deno.test("T-A-23: image/png → 400 FK_INVALID_CONTENT_TYPE", async () => {
  const handler = makeHandler(makeHappyDeps());
  const res = await handler(
    makePostRequest({
      case_id: VALID_CASE_ID,
      content_type: "image/png",
      declared_size_bytes: 1024,
    }),
  );
  assertEquals(res.status, 400);
  assertEquals((await res.json()).error.code, "FK_INVALID_CONTENT_TYPE");
});

Deno.test("T-A-23b: image/heic → 400 FK_INVALID_CONTENT_TYPE", async () => {
  const handler = makeHandler(makeHappyDeps());
  const res = await handler(
    makePostRequest({
      case_id: VALID_CASE_ID,
      content_type: "image/heic",
      declared_size_bytes: 1024,
    }),
  );
  assertEquals(res.status, 400);
  assertEquals((await res.json()).error.code, "FK_INVALID_CONTENT_TYPE");
});

Deno.test(
  "T-A-24: missing declared_size_bytes → 400 FK_INVALID_INPUT",
  async () => {
    const handler = makeHandler(makeHappyDeps());
    const res = await handler(
      makePostRequest({ case_id: VALID_CASE_ID, content_type: "image/jpeg" }),
    );
    assertEquals(res.status, 400);
    assertEquals((await res.json()).error.code, "FK_INVALID_INPUT");
  },
);

Deno.test("T-A-25: declared_size_bytes=0 → 400 FK_INVALID_INPUT", async () => {
  const handler = makeHandler(makeHappyDeps());
  const res = await handler(
    makePostRequest({
      case_id: VALID_CASE_ID,
      content_type: "image/jpeg",
      declared_size_bytes: 0,
    }),
  );
  assertEquals(res.status, 400);
  assertEquals((await res.json()).error.code, "FK_INVALID_INPUT");
});

Deno.test(
  "T-A-25b: declared_size_bytes=-1 → 400 FK_INVALID_INPUT",
  async () => {
    const handler = makeHandler(makeHappyDeps());
    const res = await handler(
      makePostRequest({
        case_id: VALID_CASE_ID,
        content_type: "image/jpeg",
        declared_size_bytes: -1,
      }),
    );
    assertEquals(res.status, 400);
    assertEquals((await res.json()).error.code, "FK_INVALID_INPUT");
  },
);

Deno.test(
  "T-A-26: declared_size_bytes=10485761 → 400 FK_FILE_TOO_LARGE",
  async () => {
    const handler = makeHandler(makeHappyDeps());
    const res = await handler(
      makePostRequest({
        case_id: VALID_CASE_ID,
        content_type: "image/jpeg",
        declared_size_bytes: 10_485_761,
      }),
    );
    assertEquals(res.status, 400);
    assertEquals((await res.json()).error.code, "FK_FILE_TOO_LARGE");
  },
);

Deno.test("T-A-27: declared_size_bytes=10485760 (max) → 200", async () => {
  const handler = makeHandler(makeHappyDeps());
  const res = await handler(
    makePostRequest({
      case_id: VALID_CASE_ID,
      content_type: "image/jpeg",
      declared_size_bytes: 10_485_760,
    }),
  );
  assertEquals(res.status, 200);
});

Deno.test("T-A-28: declared_size_bytes=1 (min) → 200", async () => {
  const handler = makeHandler(makeHappyDeps());
  const res = await handler(
    makePostRequest({
      case_id: VALID_CASE_ID,
      content_type: "image/jpeg",
      declared_size_bytes: 1,
    }),
  );
  assertEquals(res.status, 200);
});

Deno.test("T-A-29: non-JSON body → 400 FK_INVALID_INPUT", async () => {
  const handler = makeHandler(makeHappyDeps());
  const res = await handler(
    new Request("https://example.com/upload-authorize", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: "not json",
    }),
  );
  assertEquals(res.status, 400);
  assertEquals((await res.json()).error.code, "FK_INVALID_INPUT");
});

Deno.test(
  "T-A-30: fractional declared_size_bytes → 400 FK_INVALID_INPUT",
  async () => {
    const handler = makeHandler(makeHappyDeps());
    const res = await handler(
      makePostRequest({
        case_id: VALID_CASE_ID,
        content_type: "image/jpeg",
        declared_size_bytes: 1024.5,
      }),
    );
    assertEquals(res.status, 400);
    assertEquals((await res.json()).error.code, "FK_INVALID_INPUT");
  },
);

// ---------------------------------------------------------------------------
// T-A-31 to T-A-40 — DB-driven errors and profile state
// T-A-37 and T-A-38 are integration-only (prior failed/complete → 200).
// ---------------------------------------------------------------------------

async function dbErrTest(
  dbMessage: string,
  expectedStatus: number,
  expectedCode: string,
): Promise<void> {
  const handler = makeHandler(
    makeHappyDeps({
      reserveSession: (_admin, _params) =>
        Promise.resolve({ data: null, error: { message: dbMessage } }),
    }),
  );
  const res = await handler(makePostRequest());
  assertEquals(res.status, expectedStatus);
  assertEquals((await res.json()).error.code, expectedCode);
}

// T-A-31: nonexistent case → 404 (reserve_upload_session returns FK_NOT_FOUND)
Deno.test("T-A-31: nonexistent case → 404 FK_NOT_FOUND", () =>
  dbErrTest("FK_NOT_FOUND", 404, "FK_NOT_FOUND"));

// T-A-32: non-poster requests upload → 404 FK_NOT_FOUND (security by obscurity:
// reserve_upload_session hides case existence from unauthorised callers)
Deno.test("T-A-32: non-poster → 404 FK_NOT_FOUND", () =>
  dbErrTest("FK_NOT_FOUND", 404, "FK_NOT_FOUND"));

// T-A-33: case is in a state that prohibits upload (e.g. launched) → 409
Deno.test("T-A-33: launched case (wrong state) → 409 FK_WRONG_STATE", () =>
  dbErrTest("FK_WRONG_STATE", 409, "FK_WRONG_STATE"));

// T-A-34–36: unique index blocks when a pending/processing/sanitized session
// already exists; all three surface the same FK_UPLOAD_IN_PROGRESS error.
Deno.test(
  "T-A-34: existing pending session blocks → 409 FK_UPLOAD_IN_PROGRESS",
  () => dbErrTest("FK_UPLOAD_IN_PROGRESS", 409, "FK_UPLOAD_IN_PROGRESS"),
);

Deno.test(
  "T-A-35: existing processing session blocks → 409 FK_UPLOAD_IN_PROGRESS",
  () => dbErrTest("FK_UPLOAD_IN_PROGRESS", 409, "FK_UPLOAD_IN_PROGRESS"),
);

Deno.test(
  "T-A-36: existing sanitized session blocks → 409 FK_UPLOAD_IN_PROGRESS",
  () => dbErrTest("FK_UPLOAD_IN_PROGRESS", 409, "FK_UPLOAD_IN_PROGRESS"),
);

// T-A-37: prior failed session → 200 (integration only — unique index does not
// block 'failed' status; no unit stub needed).
// T-A-38: prior complete session → 200 (integration only — same rationale).

// T-A-39: deletion-prepared user — checkProfile returns forbidden (inactive)
// because prepare_account_deletion_wrapper sets is_active=false.
Deno.test("T-A-39: deletion-prepared profile → 403 FK_FORBIDDEN", async () => {
  const handler = makeHandler(
    makeHappyDeps({
      checkProfile: (_s, _u) =>
        Promise.resolve<ProfileCheckResult>({
          status: "forbidden",
          reason: "inactive",
        }),
    }),
  );
  const res = await handler(makePostRequest());
  assertEquals(res.status, 403);
  assertEquals((await res.json()).error.code, "FK_FORBIDDEN");
});

Deno.test(
  "T-A-40: reserveSession returns null row → 500 FK_INTERNAL",
  async () => {
    const handler = makeHandler(
      makeHappyDeps({
        reserveSession: (_admin, _params) =>
          Promise.resolve({ data: null, error: null }),
      }),
    );
    const res = await handler(makePostRequest());
    assertEquals(res.status, 500);
    assertEquals((await res.json()).error.code, "FK_INTERNAL");
  },
);

// ---------------------------------------------------------------------------
// T-A-41 to T-A-46 — Presign / activate / unexpected failures
// ---------------------------------------------------------------------------

Deno.test(
  "T-A-41: presign throws → 500; failSession called exactly once",
  async () => {
    let failCallCount = 0;
    const handler = makeHandler(
      makeHappyDeps({
        presign: (_path, _expiresIn) => Promise.reject(new Error("s3 down")),
        failSession: (_admin, _id, _code) => {
          failCallCount++;
          return Promise.resolve({ data: null, error: null });
        },
      }),
    );
    const res = await handler(makePostRequest());
    assertEquals(res.status, 500);
    assertEquals(failCallCount, 1);
    assert(!("presigned_url" in (await res.json())));
  },
);

Deno.test(
  "T-A-42: activateSession returns error → 500; failSession called exactly once",
  async () => {
    let failCallCount = 0;
    const handler = makeHandler(
      makeHappyDeps({
        activateSession: (_admin, _params) =>
          Promise.resolve({ data: null, error: { message: "fail" } }),
        failSession: (_admin, _id, _code) => {
          failCallCount++;
          return Promise.resolve({ data: null, error: null });
        },
      }),
    );
    const res = await handler(makePostRequest());
    assertEquals(res.status, 500);
    assertEquals(failCallCount, 1);
    assert(!("presigned_url" in (await res.json())));
  },
);

Deno.test(
  "T-A-43: reserveSession throws → top-level catch; failSession NOT called",
  async () => {
    let failCallCount = 0;
    const handler = makeHandler(
      makeHappyDeps({
        reserveSession: (_admin, _params) =>
          Promise.reject(new Error("unexpected")),
        failSession: (_admin, _id, _code) => {
          failCallCount++;
          return Promise.resolve({ data: null, error: null });
        },
      }),
    );
    const res = await handler(makePostRequest());
    assertEquals(res.status, 500);
    assertEquals(failCallCount, 0); // sessionId is null; no compensation
  },
);

Deno.test(
  "T-A-44: activateSession throws → top-level catch; failSession called once",
  async () => {
    let failCallCount = 0;
    const handler = makeHandler(
      makeHappyDeps({
        activateSession: (_admin, _params) =>
          Promise.reject(new Error("unexpected")),
        failSession: (_admin, _id, _code) => {
          failCallCount++;
          return Promise.resolve({ data: null, error: null });
        },
      }),
    );
    const res = await handler(makePostRequest());
    assertEquals(res.status, 500);
    assertEquals(failCallCount, 1);
  },
);

Deno.test(
  "T-A-45: failSession returns error after presign failure → exactly one call; outer catch does NOT retry",
  async () => {
    let failCallCount = 0;
    const handler = makeHandler(
      makeHappyDeps({
        presign: (_path, _expiresIn) => Promise.reject(new Error("s3 down")),
        failSession: (_admin, _id, _code) => {
          failCallCount++;
          return Promise.resolve({ data: null, error: { message: "fail" } });
        },
      }),
    );
    const res = await handler(makePostRequest());
    assertEquals(res.status, 500);
    assertEquals(failCallCount, 1); // compensationAttempted=true; outer catch skips
  },
);

Deno.test(
  "T-A-46: failSession throws after presign failure → bestEffortFail catches; exactly one call",
  async () => {
    let failCallCount = 0;
    const handler = makeHandler(
      makeHappyDeps({
        presign: (_path, _expiresIn) => Promise.reject(new Error("s3 down")),
        failSession: (_admin, _id, _code) => {
          failCallCount++;
          return Promise.reject(new Error("fail_session broken"));
        },
      }),
    );
    const res = await handler(makePostRequest());
    assertEquals(res.status, 500);
    assertEquals(failCallCount, 1);
  },
);

// ---------------------------------------------------------------------------
// Race B — Concurrent duplicate reservations (unit)
// ---------------------------------------------------------------------------

function makeLatch(n: number): { wait(): Promise<void> } {
  let arrived = 0;
  let release!: () => void;
  const gate = new Promise<void>((resolve) => {
    release = resolve;
  });
  return {
    wait() {
      if (++arrived >= n) release();
      return gate;
    },
  };
}

Deno.test(
  "Race B (unit): concurrent duplicates → exactly one 200 and one 409",
  async () => {
    const tokenA = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"; // 43-char
    const tokenB = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    const hashA = "a".repeat(64);
    const hashB = "b".repeat(64);

    const latch = makeLatch(2);
    const attemptedHashes: string[] = [];

    let reserved = false;
    const latchedReserve: Deps["reserveSession"] = (_admin, params) => {
      attemptedHashes.push(params.p_token_hash);
      return latch.wait().then(() => {
        if (reserved) {
          return { data: null, error: { message: "FK_UPLOAD_IN_PROGRESS" } };
        }
        reserved = true;
        return {
          data: {
            session_id: SESSION_ID,
            original_storage_path: ORIG_PATH,
            display_storage_path: `display/${SESSION_ID}.webp`,
          },
          error: null,
        };
      });
    };

    const hashMap: Record<string, string> = {
      [tokenA]: hashA,
      [tokenB]: hashB,
    };

    function makeTokenDeps(token: string): Deps {
      return makeHappyDeps({
        generateToken: () => token,
        sha256: (data) => {
          const raw = new TextDecoder().decode(data);
          return Promise.resolve(hashMap[raw] ?? TOKEN_HASH);
        },
        reserveSession: latchedReserve,
      });
    }

    const handlerA = makeHandler(makeTokenDeps(tokenA));
    const handlerB = makeHandler(makeTokenDeps(tokenB));

    const [resA, resB] = await Promise.all([
      handlerA(makePostRequest()),
      handlerB(makePostRequest()),
    ]);

    assertEquals([resA.status, resB.status].sort(), [200, 409]);

    const loser = resA.status === 409 ? resA : resB;
    assertEquals((await loser.json()).error.code, "FK_UPLOAD_IN_PROGRESS");

    // Both hashes recorded before barrier
    assertEquals(attemptedHashes.length, 2);
    const hashSet = new Set(attemptedHashes);
    assertEquals(hashSet.size, 2);
    assert(hashSet.has(hashA) && hashSet.has(hashB));
  },
);
