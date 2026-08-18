/**
 * Unit tests for _shared/cf.ts — Cloudflare image-transform Worker client.
 *
 * All HTTP calls are stubbed via a monkey-patched globalThis.fetch.
 * Env vars are set/unset around each test.
 *
 * Run with:
 *   deno test --allow-env supabase/functions/_shared/cf.test.ts
 */
import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { callImageTransform } from "./cf.ts";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

const VALID_CLIENT_ID = "test-client-id";
const VALID_CLIENT_SECRET = "test-client-secret";
const VALID_CF_WORKER_URL =
  "https://forkensics-image-transform-dev.billmags.workers.dev";
const VALID_UUID = "00000000-4000-8000-0000-000000000001";
const VALID_SHA256 = "a".repeat(64);
const VALID_DISPLAY_KEY = `display/${VALID_UUID}.webp`;

function setValidEnv(): void {
  Deno.env.set("CF_ACCESS_CLIENT_ID", VALID_CLIENT_ID);
  Deno.env.set("CF_ACCESS_CLIENT_SECRET", VALID_CLIENT_SECRET);
  Deno.env.set("CF_WORKER_URL", VALID_CF_WORKER_URL);
}

function clearEnv(): void {
  Deno.env.delete("CF_ACCESS_CLIENT_ID");
  Deno.env.delete("CF_ACCESS_CLIENT_SECRET");
  Deno.env.delete("CF_WORKER_URL");
}

type FetchStub = (
  input: string | URL | Request,
  init?: RequestInit,
) => Promise<Response>;

function stubFetch(stub: FetchStub): () => void {
  const original = globalThis.fetch;
  // deno-lint-ignore no-explicit-any
  (globalThis as any).fetch = stub;
  return () => {
    // deno-lint-ignore no-explicit-any
    (globalThis as any).fetch = original;
  };
}

function makeJsonResponse(
  status: number,
  body: unknown,
  oversize = false,
): Response {
  const text = oversize
    ? JSON.stringify(body) + " ".repeat(4097)
    : JSON.stringify(body);
  return new Response(text, {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

// ---------------------------------------------------------------------------
// 200 — valid body
// ---------------------------------------------------------------------------

Deno.test("200 with valid body → ok: true, all three fields populated", async () => {
  setValidEnv();
  const restore = stubFetch(() =>
    Promise.resolve(
      makeJsonResponse(200, {
        displayKey: VALID_DISPLAY_KEY,
        sha256: VALID_SHA256,
        bytes: 1024,
      }),
    )
  );
  const result = await callImageTransform(VALID_UUID);
  restore();
  clearEnv();
  assertEquals(result.ok, true);
  if (result.ok) {
    assertEquals(result.displayKey, VALID_DISPLAY_KEY);
    assertEquals(result.sha256, VALID_SHA256);
    assertEquals(result.bytes, 1024);
  }
});

// ---------------------------------------------------------------------------
// 200 — body field failures
// ---------------------------------------------------------------------------

Deno.test("200: displayKey absent → ok: false, FK_INTERNAL", async () => {
  setValidEnv();
  const restore = stubFetch(() =>
    Promise.resolve(
      makeJsonResponse(200, { sha256: VALID_SHA256, bytes: 1024 }),
    )
  );
  const result = await callImageTransform(VALID_UUID);
  restore();
  clearEnv();
  assertEquals(result.ok, false);
  if (!result.ok) assertEquals(result.fkCode, "FK_INTERNAL");
});

Deno.test("200: sha256 is 63 hex chars → ok: false, FK_INTERNAL", async () => {
  setValidEnv();
  const restore = stubFetch(() =>
    Promise.resolve(
      makeJsonResponse(200, {
        displayKey: VALID_DISPLAY_KEY,
        sha256: "a".repeat(63),
        bytes: 1024,
      }),
    )
  );
  const result = await callImageTransform(VALID_UUID);
  restore();
  clearEnv();
  assertEquals(result.ok, false);
  if (!result.ok) assertEquals(result.fkCode, "FK_INTERNAL");
});

Deno.test(
  "200: sha256 is 64 chars but contains uppercase → ok: false, FK_INTERNAL",
  async () => {
    setValidEnv();
    const restore = stubFetch(() =>
      Promise.resolve(
        makeJsonResponse(200, {
          displayKey: VALID_DISPLAY_KEY,
          sha256: "A".repeat(64),
          bytes: 1024,
        }),
      )
    );
    const result = await callImageTransform(VALID_UUID);
    restore();
    clearEnv();
    assertEquals(result.ok, false);
    if (!result.ok) assertEquals(result.fkCode, "FK_INTERNAL");
  },
);

Deno.test("200: bytes = 0 → ok: false, FK_INTERNAL", async () => {
  setValidEnv();
  const restore = stubFetch(() =>
    Promise.resolve(
      makeJsonResponse(200, {
        displayKey: VALID_DISPLAY_KEY,
        sha256: VALID_SHA256,
        bytes: 0,
      }),
    )
  );
  const result = await callImageTransform(VALID_UUID);
  restore();
  clearEnv();
  assertEquals(result.ok, false);
  if (!result.ok) assertEquals(result.fkCode, "FK_INTERNAL");
});

Deno.test("200: bytes = 5_242_881 → ok: false, FK_INTERNAL", async () => {
  setValidEnv();
  const restore = stubFetch(() =>
    Promise.resolve(
      makeJsonResponse(200, {
        displayKey: VALID_DISPLAY_KEY,
        sha256: VALID_SHA256,
        bytes: 5_242_881,
      }),
    )
  );
  const result = await callImageTransform(VALID_UUID);
  restore();
  clearEnv();
  assertEquals(result.ok, false);
  if (!result.ok) assertEquals(result.fkCode, "FK_INTERNAL");
});

Deno.test("200: bytes = 5_242_880 (max) → ok: true", async () => {
  setValidEnv();
  const restore = stubFetch(() =>
    Promise.resolve(
      makeJsonResponse(200, {
        displayKey: VALID_DISPLAY_KEY,
        sha256: VALID_SHA256,
        bytes: 5_242_880,
      }),
    )
  );
  const result = await callImageTransform(VALID_UUID);
  restore();
  clearEnv();
  assertEquals(result.ok, true);
  if (result.ok) assertEquals(result.bytes, 5_242_880);
});

Deno.test("200: body exceeds 4096 bytes → ok: false, FK_INTERNAL", async () => {
  setValidEnv();
  const restore = stubFetch(() =>
    Promise.resolve(
      makeJsonResponse(
        200,
        { displayKey: VALID_DISPLAY_KEY, sha256: VALID_SHA256, bytes: 1 },
        true, // oversize
      ),
    )
  );
  const result = await callImageTransform(VALID_UUID);
  restore();
  clearEnv();
  assertEquals(result.ok, false);
  if (!result.ok) assertEquals(result.fkCode, "FK_INTERNAL");
});

// ---------------------------------------------------------------------------
// Non-200 status mapping
// ---------------------------------------------------------------------------

Deno.test("404 → ok: false, FK_NOT_FOUND", async () => {
  setValidEnv();
  const restore = stubFetch(() =>
    Promise.resolve(new Response('{"error":"not found"}', { status: 404 }))
  );
  const result = await callImageTransform(VALID_UUID);
  restore();
  clearEnv();
  assertEquals(result.ok, false);
  if (!result.ok) {
    assertEquals(result.fkCode, "FK_NOT_FOUND");
    assertEquals(result.workerStatus, 404);
  }
});

Deno.test("422 → ok: false, FK_PROCESSING_FAILED", async () => {
  setValidEnv();
  const restore = stubFetch(() =>
    Promise.resolve(new Response('{"error":"unprocessable"}', { status: 422 }))
  );
  const result = await callImageTransform(VALID_UUID);
  restore();
  clearEnv();
  assertEquals(result.ok, false);
  if (!result.ok) assertEquals(result.fkCode, "FK_PROCESSING_FAILED");
});

Deno.test("401 → ok: false, FK_INTERNAL", async () => {
  setValidEnv();
  const restore = stubFetch(() =>
    Promise.resolve(new Response("Unauthorized", { status: 401 }))
  );
  const result = await callImageTransform(VALID_UUID);
  restore();
  clearEnv();
  assertEquals(result.ok, false);
  if (!result.ok) assertEquals(result.fkCode, "FK_INTERNAL");
});

Deno.test("403 → ok: false, FK_INTERNAL", async () => {
  setValidEnv();
  const restore = stubFetch(() =>
    Promise.resolve(new Response("Forbidden", { status: 403 }))
  );
  const result = await callImageTransform(VALID_UUID);
  restore();
  clearEnv();
  assertEquals(result.ok, false);
  if (!result.ok) assertEquals(result.fkCode, "FK_INTERNAL");
});

Deno.test("500 → ok: false, FK_INTERNAL", async () => {
  setValidEnv();
  const restore = stubFetch(() =>
    Promise.resolve(new Response("Server Error", { status: 500 }))
  );
  const result = await callImageTransform(VALID_UUID);
  restore();
  clearEnv();
  assertEquals(result.ok, false);
  if (!result.ok) assertEquals(result.fkCode, "FK_INTERNAL");
});

Deno.test("unexpected status (503) → ok: false, FK_INTERNAL", async () => {
  setValidEnv();
  const restore = stubFetch(() =>
    Promise.resolve(new Response("Service Unavailable", { status: 503 }))
  );
  const result = await callImageTransform(VALID_UUID);
  restore();
  clearEnv();
  assertEquals(result.ok, false);
  if (!result.ok) assertEquals(result.fkCode, "FK_INTERNAL");
});

// ---------------------------------------------------------------------------
// Fetch throws / AbortController
// ---------------------------------------------------------------------------

Deno.test("fetch throws → ok: false, FK_INTERNAL", async () => {
  setValidEnv();
  const restore = stubFetch(() => Promise.reject(new Error("network error")));
  const result = await callImageTransform(VALID_UUID);
  restore();
  clearEnv();
  assertEquals(result.ok, false);
  if (!result.ok) assertEquals(result.fkCode, "FK_INTERNAL");
});

Deno.test(
  "AbortController fires (simulated timeout) → ok: false, FK_INTERNAL",
  async () => {
    setValidEnv();
    const restore = stubFetch((_input, init) => {
      return new Promise<Response>((_resolve, reject) => {
        init?.signal?.addEventListener("abort", () => {
          reject(new DOMException("The operation was aborted.", "AbortError"));
        });
        // Never resolves — waits for abort
      });
    });
    // Directly abort via the signal (simulate timeout firing immediately)
    // We cannot reduce TIMEOUT_MS in tests, so instead we throw AbortError directly
    const restore2 = stubFetch(() =>
      Promise.reject(new DOMException("Aborted", "AbortError"))
    );
    restore(); // restore original first stub
    const result = await callImageTransform(VALID_UUID);
    restore2();
    clearEnv();
    assertEquals(result.ok, false);
    if (!result.ok) assertEquals(result.fkCode, "FK_INTERNAL");
  },
);

// ---------------------------------------------------------------------------
// Env validation failures
// ---------------------------------------------------------------------------

Deno.test(
  "missing CF_WORKER_URL → ok: false, FK_INTERNAL (no throw)",
  async () => {
    Deno.env.set("CF_ACCESS_CLIENT_ID", VALID_CLIENT_ID);
    Deno.env.set("CF_ACCESS_CLIENT_SECRET", VALID_CLIENT_SECRET);
    Deno.env.delete("CF_WORKER_URL");
    const result = await callImageTransform(VALID_UUID);
    clearEnv();
    assertEquals(result.ok, false);
    if (!result.ok) assertEquals(result.fkCode, "FK_INTERNAL");
  },
);

Deno.test("CF_WORKER_URL uses http: → ok: false, FK_INTERNAL", async () => {
  Deno.env.set("CF_ACCESS_CLIENT_ID", VALID_CLIENT_ID);
  Deno.env.set("CF_ACCESS_CLIENT_SECRET", VALID_CLIENT_SECRET);
  Deno.env.set(
    "CF_WORKER_URL",
    "http://forkensics-image-transform-dev.billmags.workers.dev",
  );
  const result = await callImageTransform(VALID_UUID);
  clearEnv();
  assertEquals(result.ok, false);
  if (!result.ok) assertEquals(result.fkCode, "FK_INTERNAL");
});

Deno.test("CF_WORKER_URL uses wrong hostname → ok: false, FK_INTERNAL", async () => {
  Deno.env.set("CF_ACCESS_CLIENT_ID", VALID_CLIENT_ID);
  Deno.env.set("CF_ACCESS_CLIENT_SECRET", VALID_CLIENT_SECRET);
  Deno.env.set("CF_WORKER_URL", "https://evil.example.com");
  const result = await callImageTransform(VALID_UUID);
  clearEnv();
  assertEquals(result.ok, false);
  if (!result.ok) assertEquals(result.fkCode, "FK_INTERNAL");
});

Deno.test(
  "CF_WORKER_URL has pathname other than '' or '/' → ok: false, FK_INTERNAL",
  async () => {
    Deno.env.set("CF_ACCESS_CLIENT_ID", VALID_CLIENT_ID);
    Deno.env.set("CF_ACCESS_CLIENT_SECRET", VALID_CLIENT_SECRET);
    Deno.env.set(
      "CF_WORKER_URL",
      "https://forkensics-image-transform-dev.billmags.workers.dev/extra",
    );
    const result = await callImageTransform(VALID_UUID);
    clearEnv();
    assertEquals(result.ok, false);
    if (!result.ok) assertEquals(result.fkCode, "FK_INTERNAL");
  },
);

Deno.test(
  "CF_WORKER_URL contains query string → ok: false, FK_INTERNAL",
  async () => {
    Deno.env.set("CF_ACCESS_CLIENT_ID", VALID_CLIENT_ID);
    Deno.env.set("CF_ACCESS_CLIENT_SECRET", VALID_CLIENT_SECRET);
    Deno.env.set(
      "CF_WORKER_URL",
      "https://forkensics-image-transform-dev.billmags.workers.dev/?foo=bar",
    );
    const result = await callImageTransform(VALID_UUID);
    clearEnv();
    assertEquals(result.ok, false);
    if (!result.ok) assertEquals(result.fkCode, "FK_INTERNAL");
  },
);

Deno.test(
  "CF_WORKER_URL contains fragment → ok: false, FK_INTERNAL",
  async () => {
    Deno.env.set("CF_ACCESS_CLIENT_ID", VALID_CLIENT_ID);
    Deno.env.set("CF_ACCESS_CLIENT_SECRET", VALID_CLIENT_SECRET);
    Deno.env.set(
      "CF_WORKER_URL",
      "https://forkensics-image-transform-dev.billmags.workers.dev/#frag",
    );
    const result = await callImageTransform(VALID_UUID);
    clearEnv();
    assertEquals(result.ok, false);
    if (!result.ok) assertEquals(result.fkCode, "FK_INTERNAL");
  },
);

Deno.test(
  "CF_WORKER_URL contains username or password → ok: false, FK_INTERNAL",
  async () => {
    Deno.env.set("CF_ACCESS_CLIENT_ID", VALID_CLIENT_ID);
    Deno.env.set("CF_ACCESS_CLIENT_SECRET", VALID_CLIENT_SECRET);
    Deno.env.set(
      "CF_WORKER_URL",
      "https://user:pass@forkensics-image-transform-dev.billmags.workers.dev",
    );
    const result = await callImageTransform(VALID_UUID);
    clearEnv();
    assertEquals(result.ok, false);
    if (!result.ok) assertEquals(result.fkCode, "FK_INTERNAL");
  },
);
