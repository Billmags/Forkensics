/**
 * Integration tests for upload-complete.
 *
 * PHASE SPLIT:
 *   T-UC-1, T-UC-2, T-UC-3 — run against a local Supabase stack (Phase 1).
 *     Requires: tools/integration-runner.sh with local env vars set.
 *   T-UC-CF-1-PREFLIGHT — pre-checks CF_WORKER_URL format only (Phase 1).
 *   T-UC-CF-1 (full E2E) — authorize → PUT → upload-complete → pending_review
 *     Deferred to Phase 2 (D-3). Requires live forkensics-dev deployment,
 *     real R2 credentials, and live CF Worker. Run via tools/run-step-b-smoke.sh.
 *
 * Required environment variables (set by runner):
 *   SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, SUPABASE_SECRET_KEY,
 *   SUPABASE_JWT_SECRET, DB_URL, FUNCTION_URL,
 *   R2_ENDPOINT, R2_BUCKET, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY,
 *   CF_WORKER_URL, CF_ACCESS_CLIENT_ID, CF_ACCESS_CLIENT_SECRET
 */
import {
  assert,
  assertEquals,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import { makeHandler } from "./index.ts";

// ---------------------------------------------------------------------------
// Environment
// ---------------------------------------------------------------------------

const FUNCTION_URL = Deno.env.get("FUNCTION_URL")!;
const DB_URL = Deno.env.get("DB_URL")!;
const CF_WORKER_URL = Deno.env.get("CF_WORKER_URL");

/**
 * Shared in-process handler (bypasses edge-runtime TCP restrictions — same
 * rationale as upload-authorize integration tests).
 */
const _handler = makeHandler();

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

async function psqlQuery(sql: string): Promise<string> {
  const cmd = new Deno.Command("psql", {
    args: [DB_URL, "--tuples-only", "--no-align", "--command", sql],
    stdout: "piped",
    stderr: "piped",
  });
  const { stdout, success } = await cmd.output();
  assert(success, `psqlQuery failed: ${sql}`);
  return new TextDecoder().decode(stdout).trim();
}

async function mintJwt(userId: string): Promise<string> {
  const secret = Deno.env.get("SUPABASE_JWT_SECRET")!;
  const header = btoa(JSON.stringify({ alg: "HS256", typ: "JWT" }))
    .replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  const payload = btoa(JSON.stringify({
    sub: userId,
    role: "authenticated",
    iat: Math.floor(Date.now() / 1000),
    exp: Math.floor(Date.now() / 1000) + 3600,
  })).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  const sigInput = `${header}.${payload}`;
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = new Uint8Array(
    await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(sigInput)),
  );
  const sigB64 = btoa(String.fromCharCode(...sig))
    .replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  return `${sigInput}.${sigB64}`;
}

// ---------------------------------------------------------------------------
// T-UC-1 — Auth rejection (via function server HTTP)
// ---------------------------------------------------------------------------

Deno.test("T-UC-1: Missing JWT → 401", async () => {
  const res = await fetch(`${FUNCTION_URL}/upload-complete`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ upload_token: "invalid" }),
  });
  assertEquals(res.status, 401);
  await res.body?.cancel();
});

Deno.test("T-UC-2: Malformed JWT → 401", async () => {
  const res = await fetch(`${FUNCTION_URL}/upload-complete`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: "Bearer not.a.jwt",
    },
    body: JSON.stringify({ upload_token: "invalid" }),
  });
  assertEquals(res.status, 401);
  await res.body?.cancel();
});

// ---------------------------------------------------------------------------
// T-UC-3 — Invalid token → 400
// ---------------------------------------------------------------------------

Deno.test("T-UC-3: Invalid upload_token → 400 FK_INVALID_TOKEN", async () => {
  const userId = await psqlQuery(
    "SELECT id FROM auth.users LIMIT 1",
  );
  if (!userId) {
    console.log("T-UC-3: skipped — no users in auth.users");
    return;
  }
  const jwt = await mintJwt(userId);
  const req = new Request("https://example.com/upload-complete", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${jwt}`,
    },
    body: JSON.stringify({
      upload_token: "notarealtoken00000000000000000000000000000",
    }),
  });
  const res = await _handler(req);
  assertEquals(res.status, 400);
  const body = await res.json();
  assertEquals(body.error.code, "FK_INVALID_TOKEN");
});

// ---------------------------------------------------------------------------
// T-UC-CF-1 — CF Worker integration (skipped if CF_WORKER_URL absent)
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// NOTE: The full E2E flow (authorize → PUT → upload-complete → pending_review)
// is Phase 2 smoke test D-3, not a Phase 1 artifact. It requires a live
// forkensics-dev deployment, real R2 credentials, and a live CF Worker.
// Run via tools/run-step-b-smoke.sh after Phase 2 approval.
// ---------------------------------------------------------------------------

Deno.test(
  "T-UC-CF-1-PREFLIGHT: CF_WORKER_URL uses https scheme (format pre-check only)",
  () => {
    if (!CF_WORKER_URL) {
      console.log(
        "T-UC-CF-1-PREFLIGHT: skipped — CF_WORKER_URL not set",
      );
      return;
    }
    assert(
      CF_WORKER_URL.startsWith("https://"),
      "CF_WORKER_URL must use https:",
    );
  },
);
