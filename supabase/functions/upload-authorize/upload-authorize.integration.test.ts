/**
 * Integration tests for upload-authorize (Amendment D: R2 presign).
 * Requires a running Supabase local stack with fixtures loaded.
 * Run via tools/integration-runner.sh — do NOT run directly.
 *
 * Required environment variables (set by runner):
 *   SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, SUPABASE_SECRET_KEY,
 *   SUPABASE_JWT_SECRET, DB_URL, FUNCTION_URL,
 *   R2_ENDPOINT, R2_BUCKET, KEY_MANIFEST,
 *   R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY
 *
 * R2 PUT/HEAD tests (T-AMD-2 through T-AMD-5) are skipped when R2_ENDPOINT
 * is not set — they require Phase 2a R2 credentials to run.
 */
import {
  assert,
  assertEquals,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import { HeadObjectCommand, S3Client } from "npm:@aws-sdk/client-s3@3.1109.0";
import { getAuthContext } from "../_shared/context.ts";
import { defaultDeps, makeHandler } from "./index.ts";
import type { Deps } from "./index.ts";

/**
 * Shared in-process handler for business-logic tests.
 *
 * The supabase-edge-runtime blocks all outbound TCP to 127.0.0.1 from inside
 * the function server process, which causes the postgres.js pool (FK_DB_URL →
 * port 54322) to fail with ECONNREFUSED and escalating retry delays.  Running
 * the handler in the deno-test process instead has no such restriction: the
 * direct-SQL path in profile.ts / index.ts reaches 127.0.0.1:54322 normally.
 *
 * Auth tests T-A-11/12/13 stay as HTTP fetches — they exercise auth rejection
 * before any DB access and continue to work through the function server.
 */
const _handler = makeHandler();

// ---------------------------------------------------------------------------
// Environment
// ---------------------------------------------------------------------------

const FUNCTION_URL = Deno.env.get("FUNCTION_URL")!;
const DB_URL = Deno.env.get("DB_URL")!;
const R2_ENDPOINT = Deno.env.get("R2_ENDPOINT");
const R2_BUCKET = Deno.env.get("R2_BUCKET") ?? "forkensics-dev-media";
const KEY_MANIFEST = Deno.env.get("KEY_MANIFEST");
// R2 credentials — used for T-AMD-5 HEAD confirmation via @aws-sdk/client-s3.
// Values are never logged; T-AMD-8 verifies absence from runner log.
const R2_ACCESS_KEY_ID = Deno.env.get("R2_ACCESS_KEY_ID") ?? "";
const R2_SECRET_ACCESS_KEY = Deno.env.get("R2_SECRET_ACCESS_KEY") ?? "";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/** Run a SQL query via psql and return trimmed stdout. */
async function psqlQuery(sql: string): Promise<string> {
  const cmd = new Deno.Command("psql", {
    args: [
      DB_URL,
      "--no-password",
      "-t",
      "-A",
      "-v",
      "ON_ERROR_STOP=1",
      "-c",
      sql,
    ],
    stdout: "piped",
    stderr: "piped",
  });
  const { code, stdout, stderr } = await cmd.output();
  if (code !== 0) {
    throw new Error(
      `psqlQuery failed (exit ${code}): ${new TextDecoder().decode(stderr)}`,
    );
  }
  return new TextDecoder().decode(stdout).trim();
}

/** Build a signed JWT for the fixture user using the local JWT secret. */
async function makeJwt(userId: string): Promise<string> {
  const secret = Deno.env.get("SUPABASE_JWT_SECRET")!;
  const header = btoa(
    JSON.stringify({ alg: "HS256", typ: "JWT", kid: FK_JWKS_KID }),
  )
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
  const iat = Math.floor(Date.now() / 1000);
  const exp = iat + 3600;
  const payload = btoa(
    JSON.stringify({
      sub: userId,
      role: "authenticated",
      aud: "authenticated",
      iat,
      exp,
    }),
  )
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
  const data = `${header}.${payload}`;
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = await crypto.subtle.sign(
    "HMAC",
    key,
    new TextEncoder().encode(data),
  );
  const sigB64 = btoa(String.fromCharCode(...new Uint8Array(sig)))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
  return `${data}.${sigB64}`;
}

function makeLivePOST(
  jwt: string,
  body: Record<string, unknown>,
): RequestInit {
  return {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${jwt}`,
    },
    body: JSON.stringify(body),
  };
}

/**
 * Extract R2 object key from presigned URL.
 * Key is the path segment after the bucket name, before the query string.
 */
function extractKeyFromUrl(presignedUrl: string, bucket: string): string {
  const withoutQuery = presignedUrl.split("?")[0];
  const bucketIdx = withoutQuery.indexOf(`/${bucket}/`);
  if (bucketIdx === -1) {
    throw new Error(
      `Bucket "${bucket}" not found in presigned URL path: ${withoutQuery}`,
    );
  }
  return withoutQuery.slice(bucketIdx + bucket.length + 2);
}

/**
 * Record an R2 key to KEY_MANIFEST before issuing the PUT.
 * Validates the manifest path and key format before appending.
 * No-op if KEY_MANIFEST is not set (allows running tests without runner).
 */
async function recordKeyToManifest(key: string): Promise<void> {
  if (!KEY_MANIFEST) return;

  const UUID_V4_RE =
    /^originals\/[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
  if (!UUID_V4_RE.test(key)) {
    throw new Error(
      `T-AMD-6: key failed strict validation: ${key}`,
    );
  }
  if (!/^\/tmp\/forkensics-keys-[A-Za-z0-9]+$/.test(KEY_MANIFEST)) {
    throw new Error(`T-AMD-6: KEY_MANIFEST path invalid: ${KEY_MANIFEST}`);
  }
  // Verify manifest is a regular, non-symlink file before appending.
  let _stat: Deno.FileInfo;
  try {
    _stat = await Deno.lstat(KEY_MANIFEST);
  } catch {
    throw new Error(
      `T-AMD-6: KEY_MANIFEST does not exist: ${KEY_MANIFEST}`,
    );
  }
  if (!_stat.isFile || _stat.isSymlink) {
    throw new Error(
      `T-AMD-6: KEY_MANIFEST is not a regular non-symlink file: ${KEY_MANIFEST}`,
    );
  }

  // Append key BEFORE issuing PUT (runner cleanup handles deletion).
  await Deno.writeTextFile(KEY_MANIFEST, key + "\n", { append: true });
}

// ---------------------------------------------------------------------------
// JWKS kid — must match the kid in FK_JWKS_JSON injected by integration-runner.sh
// ---------------------------------------------------------------------------

/** Stable kid value used by integration-runner.sh when building FK_JWKS_JSON. */
const FK_JWKS_KID = "forkensics-local";

// Fixture constants — must match integration-fixtures.sql
const FIXTURE_POSTER_ID = "10000000-0000-0000-0000-000000000001";
const FIXTURE_DELETION_USER_ID = "10000000-0000-0000-0000-000000000003";
const FIXTURE_CASE_ID_1 = "20000000-0000-0000-0000-000000000001"; // happy path
const FIXTURE_CASE_ID_2 = "20000000-0000-0000-0000-000000000002"; // Race B
const FIXTURE_CASE_ID_3 = "20000000-0000-0000-0000-000000000003"; // T-A-47 presign fail
const FIXTURE_CASE_ID_4 = "20000000-0000-0000-0000-000000000004"; // T-A-37 prior failed
const FIXTURE_CASE_ID_5 = "20000000-0000-0000-0000-000000000005"; // T-A-38 prior complete
const FIXTURE_CASE_ID_6 = "20000000-0000-0000-0000-000000000006"; // T-A-48 activate fail
// Amendment D fixture cases — added to integration-fixtures.sql
const FIXTURE_CASE_ID_7 = "20000000-0000-0000-0000-000000000007"; // T-AMD-1/T-AMD-2
const FIXTURE_CASE_ID_8 = "20000000-0000-0000-0000-000000000008"; // T-AMD-3/T-AMD-4

// ---------------------------------------------------------------------------
// T-A-auth-real — Real getAuthContext returns sanitized 401 + Cache-Control
// ---------------------------------------------------------------------------

Deno.test(
  "T-A-auth-real: real getAuthContext returns sanitized 401 + Cache-Control: no-store on invalid JWT",
  async () => {
    const req = new Request("https://example.com/", {
      method: "POST",
      headers: { Authorization: "Bearer definitely.not.a.valid.jwt" },
    });
    const result = await getAuthContext(req);

    assertEquals(result.ok, false);
    assert(result.error !== null);
    assertEquals(result.error.status, 401);
    assertEquals(result.error.headers.get("Cache-Control"), "no-store");

    const body = await result.error.json();
    assertEquals(body, {
      error: { code: "FK_UNAUTHENTICATED", message: "Unauthorized" },
    });
  },
);

// ---------------------------------------------------------------------------
// T-A-11 to T-A-13 — Auth failures via live function endpoint
// ---------------------------------------------------------------------------

Deno.test("T-A-11: missing Authorization → 401", async () => {
  const res = await fetch(FUNCTION_URL, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      case_id: FIXTURE_CASE_ID_1,
      content_type: "image/jpeg",
      declared_size_bytes: 1024,
    }),
  });
  assertEquals(res.status, 401);
  await res.body?.cancel();
});

Deno.test("T-A-12: malformed JWT → 401", async () => {
  const res = await fetch(FUNCTION_URL, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: "Bearer malformed",
    },
    body: JSON.stringify({
      case_id: FIXTURE_CASE_ID_1,
      content_type: "image/jpeg",
      declared_size_bytes: 1024,
    }),
  });
  assertEquals(res.status, 401);
  await res.body?.cancel();
});

Deno.test("T-A-13: expired JWT → 401", async () => {
  const secret = Deno.env.get("SUPABASE_JWT_SECRET")!;
  const header = btoa(
    JSON.stringify({ alg: "HS256", typ: "JWT", kid: FK_JWKS_KID }),
  )
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
  const iat = Math.floor(Date.now() / 1000) - 7200;
  const exp = Math.floor(Date.now() / 1000) - 3600;
  const payload = btoa(
    JSON.stringify({
      sub: FIXTURE_POSTER_ID,
      role: "authenticated",
      aud: "authenticated",
      iat,
      exp,
    }),
  )
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
  const data = `${header}.${payload}`;
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = await crypto.subtle.sign(
    "HMAC",
    key,
    new TextEncoder().encode(data),
  );
  const sigB64 = btoa(String.fromCharCode(...new Uint8Array(sig)))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
  const expiredJwt = `${data}.${sigB64}`;

  const res = await fetch(
    FUNCTION_URL,
    makeLivePOST(expiredJwt, {
      case_id: FIXTURE_CASE_ID_1,
      content_type: "image/jpeg",
      declared_size_bytes: 1024,
    }),
  );
  assertEquals(res.status, 401);
  await res.body?.cancel();
});

// ---------------------------------------------------------------------------
// T-A-01 happy path + T-A-04/06/07 DB evidence
// ---------------------------------------------------------------------------

Deno.test(
  "T-A-01 (integration): valid JPEG happy path → 200 + correct DB state",
  async () => {
    const jwt = await makeJwt(FIXTURE_POSTER_ID);

    const res = await _handler(
      new Request(
        FUNCTION_URL,
        makeLivePOST(jwt, {
          case_id: FIXTURE_CASE_ID_1,
          content_type: "image/jpeg",
          declared_size_bytes: 8192,
        }),
      ),
    );
    assertEquals(res.status, 200);
    const body = await res.json();

    // T-A-01: response shape
    assert(typeof body.presigned_url === "string");
    assert(typeof body.upload_token === "string");
    assertEquals(body.upload_token.length, 43);
    assert(typeof body.expires_at === "string");
    assert(!("session_id" in body));
    assertEquals(res.headers.get("Cache-Control"), "no-store");

    // T-A-04: token hash comparison via DB boolean — never prints the raw hash
    const expectedHash = Array.from(
      new Uint8Array(
        await crypto.subtle.digest(
          "SHA-256",
          new TextEncoder().encode(body.upload_token),
        ),
      ),
    )
      .map((b) => b.toString(16).padStart(2, "0"))
      .join("");
    const hashMatch = await psqlQuery(
      `SELECT (upload_token_hash = '${expectedHash}')` +
        ` FROM private.upload_sessions` +
        ` WHERE case_id = '${FIXTURE_CASE_ID_1}'` +
        ` ORDER BY status_changed_at DESC LIMIT 1`,
    );
    assertEquals(hashMatch, "t");

    // T-A-06: activate_upload_session keeps status = 'pending'
    const dbStatus = await psqlQuery(
      `SELECT status FROM private.upload_sessions` +
        ` WHERE case_id = '${FIXTURE_CASE_ID_1}'` +
        ` ORDER BY status_changed_at DESC LIMIT 1`,
    );
    assertEquals(dbStatus, "pending");

    // T-A-07: DB storage_upload_expires_at equals body.expires_at exactly.
    const dbExpiry = await psqlQuery(
      `SELECT to_char(` +
        `storage_upload_expires_at AT TIME ZONE 'UTC',` +
        ` 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')` +
        ` FROM private.upload_sessions` +
        ` WHERE case_id = '${FIXTURE_CASE_ID_1}'` +
        ` ORDER BY status_changed_at DESC LIMIT 1`,
    );
    assertEquals(dbExpiry, body.expires_at);
  },
);

// ---------------------------------------------------------------------------
// T-AMD-1 — X-Amz-SignedHeaders contains 'content-type'
// ---------------------------------------------------------------------------

Deno.test(
  "T-AMD-1: X-Amz-SignedHeaders contains content-type",
  async () => {
    const jwt = await makeJwt(FIXTURE_POSTER_ID);
    const res = await _handler(
      new Request(
        FUNCTION_URL,
        makeLivePOST(jwt, {
          case_id: FIXTURE_CASE_ID_7,
          content_type: "image/jpeg",
          declared_size_bytes: 1024,
        }),
      ),
    );
    assertEquals(res.status, 200);
    const body = await res.json();
    const presignedUrl = body.presigned_url as string;
    const u = new URL(presignedUrl);
    const signedHeaders = u.searchParams.get("X-Amz-SignedHeaders") ?? "";
    assert(
      signedHeaders.split(";").includes("content-type"),
      `X-Amz-SignedHeaders="${signedHeaders}" must include content-type`,
    );
    // Fail session to prevent it blocking subsequent tests on the same case.
    const uploadToken = body.upload_token as string;
    const tokenHash = Array.from(
      new Uint8Array(
        await crypto.subtle.digest(
          "SHA-256",
          new TextEncoder().encode(uploadToken),
        ),
      ),
    ).map((b) => b.toString(16).padStart(2, "0")).join("");
    const sessionId = await psqlQuery(
      `SELECT session_id FROM private.upload_sessions` +
        ` WHERE upload_token_hash = '${tokenHash}' LIMIT 1`,
    );
    if (sessionId) {
      await psqlQuery(
        `SELECT fail_upload_session('${sessionId}', 'FK_INTERNAL')`,
      );
    }
  },
);

// ---------------------------------------------------------------------------
// T-AMD-2 — Exact-match Content-Type PUT → HTTP 200 from R2
// T-AMD-5 — Object exists at originals/{session_id} after T-AMD-2
// (skipped when R2_ENDPOINT not set)
// ---------------------------------------------------------------------------

Deno.test({
  name: "T-AMD-2/T-AMD-5: exact Content-Type PUT → R2 200; key in manifest",
  ignore: !R2_ENDPOINT,
  async fn() {
    const jwt = await makeJwt(FIXTURE_POSTER_ID);
    const res = await _handler(
      new Request(
        FUNCTION_URL,
        makeLivePOST(jwt, {
          case_id: FIXTURE_CASE_ID_7,
          content_type: "image/jpeg",
          declared_size_bytes: 1024,
        }),
      ),
    );
    assertEquals(res.status, 200);
    const body = await res.json();
    const presignedUrl = body.presigned_url as string;

    // Extract and validate key.
    const key = extractKeyFromUrl(presignedUrl, R2_BUCKET);
    const UUID_V4_RE =
      /^originals\/[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
    assert(UUID_V4_RE.test(key), `T-AMD-2: key failed validation: ${key}`);

    // T-AMD-6: record key to manifest BEFORE issuing PUT.
    await recordKeyToManifest(key);

    // T-AMD-2: PUT with exact Content-Type → 200.
    // Body is 2 bytes — R2 validates Content-Type signature, not content.
    const putRes = await fetch(presignedUrl, {
      method: "PUT",
      headers: { "Content-Type": "image/jpeg" },
      body: new Uint8Array([0xff, 0xd8]),
    });
    assertEquals(
      putRes.status,
      200,
      `T-AMD-2: PUT status=${putRes.status}, expected 200`,
    );
    await putRes.body?.cancel();

    // T-AMD-5: HEAD-confirm object presence after successful PUT.
    // Uses @aws-sdk/client-s3 directly; aws CLI is not required.
    // Credentials are never logged; T-AMD-8 verifies absence from runner log.
    {
      const headClient = new S3Client({
        region: "auto",
        endpoint: R2_ENDPOINT!,
        forcePathStyle: true,
        credentials: {
          accessKeyId: R2_ACCESS_KEY_ID,
          secretAccessKey: R2_SECRET_ACCESS_KEY,
        },
      });
      let t5ok = false;
      try {
        await headClient.send(
          new HeadObjectCommand({ Bucket: R2_BUCKET, Key: key }),
        );
        t5ok = true;
      } catch { /* noop — object absent means test fails below */ }
      assert(t5ok, `T-AMD-5: object not found in R2 after PUT`);
    }
    // Runner cleanup() performs HEAD-before-delete, delete, and HEAD-after-delete via KEY_MANIFEST.
  },
});

// ---------------------------------------------------------------------------
// T-AMD-3 — Missing Content-Type PUT → HTTP 403 from R2
// (skipped when R2_ENDPOINT not set)
// ---------------------------------------------------------------------------

Deno.test({
  name: "T-AMD-3: missing Content-Type PUT → 403 from R2",
  ignore: !R2_ENDPOINT,
  async fn() {
    const jwt = await makeJwt(FIXTURE_POSTER_ID);
    const res = await _handler(
      new Request(
        FUNCTION_URL,
        makeLivePOST(jwt, {
          case_id: FIXTURE_CASE_ID_8,
          content_type: "image/jpeg",
          declared_size_bytes: 1024,
        }),
      ),
    );
    assertEquals(res.status, 200);
    const body = await res.json();
    const presignedUrl = body.presigned_url as string;

    // Record key BEFORE PUT (key won't exist in R2; runner cleanup handles 404 gracefully).
    const key = extractKeyFromUrl(presignedUrl, R2_BUCKET);
    await recordKeyToManifest(key);

    // PUT without Content-Type → R2 rejects (Content-Type was baked into signature).
    const putRes = await fetch(presignedUrl, {
      method: "PUT",
      body: new Uint8Array([0xff, 0xd8, 0xff, 0xd9]),
    });
    assertEquals(
      putRes.status,
      403,
      `T-AMD-3: PUT status=${putRes.status}, expected 403`,
    );
    await putRes.body?.cancel();

    // T-AMD-3 cleanup: fail the pending session so FIXTURE_CASE_ID_8 is
    // free for T-AMD-4. Session ID is embedded in the originals/ key.
    const sessionId = key.replace(/^originals\//, "");
    await psqlQuery(
      `SELECT fail_upload_session('${sessionId}', 'FK_INTERNAL')`,
    );
  },
});

// ---------------------------------------------------------------------------
// T-AMD-4 — Mismatched Content-Type PUT → HTTP 403 from R2
// (skipped when R2_ENDPOINT not set)
// ---------------------------------------------------------------------------

Deno.test({
  name: "T-AMD-4: mismatched Content-Type PUT → 403 from R2",
  ignore: !R2_ENDPOINT,
  async fn() {
    const jwt = await makeJwt(FIXTURE_POSTER_ID);
    const res = await _handler(
      new Request(
        FUNCTION_URL,
        makeLivePOST(jwt, {
          case_id: FIXTURE_CASE_ID_8,
          content_type: "image/jpeg",
          declared_size_bytes: 1024,
        }),
      ),
    );
    assertEquals(res.status, 200);
    const body = await res.json();
    const presignedUrl = body.presigned_url as string;

    const key = extractKeyFromUrl(presignedUrl, R2_BUCKET);
    await recordKeyToManifest(key);

    // PUT with wrong Content-Type (signed for image/jpeg, sending image/webp).
    const putRes = await fetch(presignedUrl, {
      method: "PUT",
      headers: { "Content-Type": "image/webp" },
      body: new Uint8Array([0x52, 0x49, 0x46, 0x46]),
    });
    assertEquals(
      putRes.status,
      403,
      `T-AMD-4: PUT status=${putRes.status}, expected 403`,
    );
    await putRes.body?.cancel();
  },
});

// ---------------------------------------------------------------------------
// T-A-15 — Deletion-prepared profile → 403 + deletion_log verified
// ---------------------------------------------------------------------------

Deno.test(
  "T-A-15 (integration): deletion-prepared user → 403 FK_FORBIDDEN",
  async () => {
    const dlStatus = await psqlQuery(
      `SELECT status FROM private.deletion_log` +
        ` WHERE profile_id = '${FIXTURE_DELETION_USER_ID}'`,
    );
    assertEquals(dlStatus, "database_prepared");

    const jwt = await makeJwt(FIXTURE_DELETION_USER_ID);
    const res = await _handler(
      new Request(
        FUNCTION_URL,
        makeLivePOST(jwt, {
          case_id: FIXTURE_CASE_ID_1,
          content_type: "image/jpeg",
          declared_size_bytes: 1024,
        }),
      ),
    );
    assertEquals(res.status, 403);
    const b = await res.json();
    assertEquals(b.error.code, "FK_FORBIDDEN");
  },
);

// ---------------------------------------------------------------------------
// T-A-37 — Prior failed session does not block a new reservation
// ---------------------------------------------------------------------------

Deno.test(
  "T-A-37 (integration): prior failed session → 200 (unique index excludes failed)",
  async () => {
    const jwt = await makeJwt(FIXTURE_POSTER_ID);

    const res1 = await _handler(
      new Request(
        FUNCTION_URL,
        makeLivePOST(jwt, {
          case_id: FIXTURE_CASE_ID_4,
          content_type: "image/jpeg",
          declared_size_bytes: 1024,
        }),
      ),
    );
    assertEquals(res1.status, 200);
    await res1.body?.cancel();

    await psqlQuery(
      `UPDATE private.upload_sessions` +
        ` SET status = 'failed', failed_reason = 'FK_INTERNAL',` +
        ` status_changed_at = now()` +
        ` WHERE case_id = '${FIXTURE_CASE_ID_4}'`,
    );

    const res2 = await _handler(
      new Request(
        FUNCTION_URL,
        makeLivePOST(jwt, {
          case_id: FIXTURE_CASE_ID_4,
          content_type: "image/jpeg",
          declared_size_bytes: 1024,
        }),
      ),
    );
    assertEquals(res2.status, 200);
    await res2.body?.cancel();
  },
);

// ---------------------------------------------------------------------------
// T-A-38 — Prior complete session does not block a new reservation
// ---------------------------------------------------------------------------

Deno.test(
  "T-A-38 (integration): prior complete session → 200 (unique index excludes complete)",
  async () => {
    const jwt = await makeJwt(FIXTURE_POSTER_ID);

    const res1 = await _handler(
      new Request(
        FUNCTION_URL,
        makeLivePOST(jwt, {
          case_id: FIXTURE_CASE_ID_5,
          content_type: "image/jpeg",
          declared_size_bytes: 1024,
        }),
      ),
    );
    assertEquals(res1.status, 200);
    await res1.body?.cancel();

    await psqlQuery(
      `UPDATE private.upload_sessions` +
        ` SET status = 'complete', status_changed_at = now()` +
        ` WHERE case_id = '${FIXTURE_CASE_ID_5}'`,
    );

    const res2 = await _handler(
      new Request(
        FUNCTION_URL,
        makeLivePOST(jwt, {
          case_id: FIXTURE_CASE_ID_5,
          content_type: "image/jpeg",
          declared_size_bytes: 1024,
        }),
      ),
    );
    assertEquals(res2.status, 200);
    await res2.body?.cancel();
  },
);

// ---------------------------------------------------------------------------
// T-A-47 — Presign failure: bestEffortFail sets session failed in DB
// ---------------------------------------------------------------------------

Deno.test(
  "T-A-47 (integration): presign failure → 500, no presigned_url, DB status=failed + reason=FK_INTERNAL",
  async () => {
    const jwt = await makeJwt(FIXTURE_POSTER_ID);

    const handler = makeHandler({
      ...defaultDeps,
      presign: (_path, _expiresIn, _contentType) =>
        Promise.reject(new Error("r2 unavailable")),
    });

    const req = new Request("https://example.com/upload-authorize", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${jwt}`,
      },
      body: JSON.stringify({
        case_id: FIXTURE_CASE_ID_3,
        content_type: "image/jpeg",
        declared_size_bytes: 1024,
      }),
    });

    const res = await handler(req);
    assertEquals(res.status, 500);
    const body = await res.json();
    assert(!("presigned_url" in body));

    const dbStatus = await psqlQuery(
      `SELECT status FROM private.upload_sessions` +
        ` WHERE case_id = '${FIXTURE_CASE_ID_3}'` +
        ` ORDER BY status_changed_at DESC LIMIT 1`,
    );
    assertEquals(dbStatus, "failed");

    const dbReason = await psqlQuery(
      `SELECT failed_reason FROM private.upload_sessions` +
        ` WHERE case_id = '${FIXTURE_CASE_ID_3}'` +
        ` ORDER BY status_changed_at DESC LIMIT 1`,
    );
    assertEquals(dbReason, "FK_INTERNAL");
  },
);

// ---------------------------------------------------------------------------
// T-A-48 — Activation failure: bestEffortFail sets session failed in DB
// ---------------------------------------------------------------------------

Deno.test(
  "T-A-48 (integration): activation failure → 500, no presigned_url, DB status=failed + reason=FK_INTERNAL",
  async () => {
    const jwt = await makeJwt(FIXTURE_POSTER_ID);

    const handler = makeHandler({
      ...defaultDeps,
      activateSession: (_admin, _params) =>
        Promise.resolve({ data: null, error: { message: "FK_INTERNAL" } }),
    });

    const req = new Request("https://example.com/upload-authorize", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${jwt}`,
      },
      body: JSON.stringify({
        case_id: FIXTURE_CASE_ID_6,
        content_type: "image/jpeg",
        declared_size_bytes: 1024,
      }),
    });

    const res = await handler(req);
    assertEquals(res.status, 500);
    const body = await res.json();
    assert(!("presigned_url" in body));

    const dbStatus = await psqlQuery(
      `SELECT status FROM private.upload_sessions` +
        ` WHERE case_id = '${FIXTURE_CASE_ID_6}'` +
        ` ORDER BY status_changed_at DESC LIMIT 1`,
    );
    assertEquals(dbStatus, "failed");

    const dbReason = await psqlQuery(
      `SELECT failed_reason FROM private.upload_sessions` +
        ` WHERE case_id = '${FIXTURE_CASE_ID_6}'` +
        ` ORDER BY status_changed_at DESC LIMIT 1`,
    );
    assertEquals(dbReason, "FK_INTERNAL");
  },
);

// ---------------------------------------------------------------------------
// Race B integration — concurrent duplicate reservations
// ---------------------------------------------------------------------------

Deno.test(
  "Race B (integration): concurrent duplicates → one 200, one 409",
  async () => {
    const jwt = await makeJwt(FIXTURE_POSTER_ID);

    const tokenA = "ccccccccccccccccccccccccccccccccccccccccccc"; // 43 chars
    const tokenB = "ddddddddddddddddddddddddddddddddddddddddddd";
    const hashA = "c".repeat(64);
    const hashB = "d".repeat(64);

    const latch = makeLatch(2);
    const attemptedHashes: string[] = [];

    const latchedReserve: Deps["reserveSession"] = async (admin, params) => {
      attemptedHashes.push(params.p_token_hash);
      await latch.wait();
      return defaultDeps.reserveSession(admin, params);
    };

    function makeTokenHandler(
      token: string,
    ): (req: Request) => Promise<Response> {
      return makeHandler({
        ...defaultDeps,
        generateToken: () => token,
        sha256: (data) => {
          const decoded = new TextDecoder().decode(data);
          if (decoded === tokenA) return Promise.resolve(hashA);
          if (decoded === tokenB) return Promise.resolve(hashB);
          // Cast safe: data is always backed by a plain ArrayBuffer here.
          const safeData = data as unknown as Uint8Array<ArrayBuffer>;
          return crypto.subtle.digest("SHA-256", safeData).then((digest) =>
            Array.from(new Uint8Array(digest))
              .map((b) => b.toString(16).padStart(2, "0"))
              .join("")
          );
        },
        reserveSession: latchedReserve,
      });
    }

    const handlerA = makeTokenHandler(tokenA);
    const handlerB = makeTokenHandler(tokenB);

    const makeReq = () =>
      new Request(FUNCTION_URL, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${jwt}`,
        },
        body: JSON.stringify({
          case_id: FIXTURE_CASE_ID_2,
          content_type: "image/jpeg",
          declared_size_bytes: 1024,
        }),
      });

    const [resA, resB] = await Promise.all([
      handlerA(makeReq()),
      handlerB(makeReq()),
    ]);

    assertEquals([resA.status, resB.status].sort(), [200, 409]);

    const loser = resA.status === 409 ? resA : resB;
    const loserBody = await loser.json();
    assertEquals(loserBody.error.code, "FK_UPLOAD_IN_PROGRESS");

    assertEquals(attemptedHashes.length, 2);
    const hashSet = new Set(attemptedHashes);
    assertEquals(hashSet.size, 2);
    assert(hashSet.has(hashA) && hashSet.has(hashB));

    const dbTotal = await psqlQuery(
      `SELECT COUNT(*) FROM private.upload_sessions` +
        ` WHERE case_id = '${FIXTURE_CASE_ID_2}'`,
    );
    assertEquals(dbTotal, "1");

    const dbPending = await psqlQuery(
      `SELECT COUNT(*) FROM private.upload_sessions` +
        ` WHERE case_id = '${FIXTURE_CASE_ID_2}' AND status = 'pending'`,
    );
    assertEquals(dbPending, "1");

    const hashValid = await psqlQuery(
      `SELECT (upload_token_hash = '${hashA}' OR upload_token_hash = '${hashB}')` +
        ` FROM private.upload_sessions` +
        ` WHERE case_id = '${FIXTURE_CASE_ID_2}' AND status = 'pending'` +
        ` LIMIT 1`,
    );
    assertEquals(hashValid, "t");
  },
);

// ---------------------------------------------------------------------------
// Latch helper (self-contained)
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
