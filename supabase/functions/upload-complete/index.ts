import {
  DeleteObjectCommand,
  GetObjectCommand,
  S3Client,
} from "npm:@aws-sdk/client-s3@3.1109.0";
import type { SupabaseClient } from "npm:@supabase/supabase-js@2.112.3";
import { getAuthContext } from "../_shared/context.ts";
import type { AuthResult } from "../_shared/context.ts";
import { getLocalDbClient } from "../_shared/dbClient.ts";
import { errorEnvelope, extractDbErrorCode } from "../_shared/errors.ts";
import type { FkErrorCode } from "../_shared/errors.ts";
import { safeLog } from "../_shared/log.ts";
import { sha256Hex } from "../_shared/crypto.ts";
import { callImageTransform } from "../_shared/cf.ts";
import type { CfTransformResult } from "../_shared/cf.ts";

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

interface SessionRow {
  session_id: string;
  status: string;
  original_storage_path: string;
  display_storage_path: string;
  content_type: string;
  storage_upload_expires_at: string | null;
  processing_lease_expires_at: string | null;
  media_object_id: string | null;
  replaced_media_object_id: string | null;
}

interface FinalizeResult {
  media_object_id: string;
  replaced_media_object_id: string | null;
}

// ---------------------------------------------------------------------------
// Deps interface
// ---------------------------------------------------------------------------

export interface Deps {
  getAuth: (req: Request) => Promise<AuthResult>;
  sha256: (data: Uint8Array) => Promise<string>;
  resolveSession: (
    admin: SupabaseClient,
    tokenHash: string,
    uploaderId: string,
  ) => Promise<{ data: SessionRow | null; error: unknown }>;
  advanceProcessing: (
    admin: SupabaseClient,
    sessionId: string,
    uploaderId: string,
  ) => Promise<{ error: unknown }>;
  checkLease: (
    admin: SupabaseClient,
    sessionId: string,
  ) => Promise<{ data: boolean | null; error: unknown }>;
  advanceSanitized: (
    admin: SupabaseClient,
    sessionId: string,
  ) => Promise<{ error: unknown }>;
  finalizeSession: (
    admin: SupabaseClient,
    sessionId: string,
    sha256Hash: string,
  ) => Promise<{ data: FinalizeResult | null; error: unknown }>;
  failSession: (
    admin: SupabaseClient,
    sessionId: string,
    code: FkErrorCode,
  ) => Promise<{ error: unknown }>;
  callCf: (mediaUuid: string) => Promise<CfTransformResult>;
  deleteFromR2: (key: string) => Promise<void>;
  downloadFromR2: (key: string) => Promise<Uint8Array | null>;
}

// ---------------------------------------------------------------------------
// R2 helpers (inline — s3.ts is not modified)
// ---------------------------------------------------------------------------

function buildR2Client(): S3Client {
  const endpoint = Deno.env.get("R2_ENDPOINT");
  const accessKeyId = Deno.env.get("R2_ACCESS_KEY_ID");
  const secretAccessKey = Deno.env.get("R2_SECRET_ACCESS_KEY");
  if (!endpoint || !accessKeyId || !secretAccessKey) {
    throw new Error("upload-complete: R2 credentials not configured");
  }
  return new S3Client({
    region: "auto",
    endpoint,
    forcePathStyle: true,
    credentials: { accessKeyId, secretAccessKey },
    requestChecksumCalculation: "WHEN_REQUIRED",
  });
}

function getR2Bucket(): string {
  const bucket = Deno.env.get("R2_BUCKET");
  if (!bucket) throw new Error("upload-complete: R2_BUCKET not set");
  return bucket;
}

async function defaultDeleteFromR2(key: string): Promise<void> {
  const client = buildR2Client();
  const bucket = getR2Bucket();
  // DeleteObjectCommand is idempotent: absent object returns 204.
  await client.send(new DeleteObjectCommand({ Bucket: bucket, Key: key }));
}

async function defaultDownloadFromR2(
  key: string,
): Promise<Uint8Array | null> {
  const client = buildR2Client();
  const bucket = getR2Bucket();
  let res;
  try {
    res = await client.send(
      new GetObjectCommand({ Bucket: bucket, Key: key }),
    );
  } catch (err) {
    // NoSuchKey → absent
    if (err instanceof Error && err.name === "NoSuchKey") return null;
    throw err;
  }
  if (!res.Body) return null;
  const chunks: Uint8Array[] = [];
  // deno-lint-ignore no-explicit-any
  for await (const chunk of res.Body as any) {
    chunks.push(chunk instanceof Uint8Array ? chunk : new Uint8Array(chunk));
  }
  const total = chunks.reduce((s, c) => s + c.length, 0);
  const merged = new Uint8Array(total);
  let off = 0;
  for (const chunk of chunks) {
    merged.set(chunk, off);
    off += chunk.length;
  }
  return merged;
}

// ---------------------------------------------------------------------------
// Default deps (production)
// ---------------------------------------------------------------------------

export const defaultDeps: Deps = {
  getAuth: getAuthContext,
  sha256: sha256Hex,
  resolveSession: async (admin, tokenHash, uploaderId) => {
    const sql = getLocalDbClient();
    if (sql) {
      try {
        const rows = await sql`
          SELECT session_id, status, original_storage_path, display_storage_path,
                 content_type, storage_upload_expires_at, processing_lease_expires_at,
                 media_object_id, replaced_media_object_id
          FROM resolve_upload_session(${tokenHash}, ${uploaderId}::uuid)
        `;
        return {
          data: rows.length > 0 ? (rows[0] as unknown as SessionRow) : null,
          error: null,
        };
      } catch (e) {
        return { data: null, error: e };
      }
    }
    const { data, error } = await admin
      .rpc("resolve_upload_session", {
        p_token_hash: tokenHash,
        p_uploader_id: uploaderId,
      })
      .single();
    return { data: data as SessionRow | null, error };
  },
  advanceProcessing: async (admin, sessionId, uploaderId) => {
    const sql = getLocalDbClient();
    if (sql) {
      try {
        await sql`
          SELECT advance_upload_session_processing(
            ${sessionId}::uuid, ${uploaderId}::uuid, '10 minutes'::interval
          )
        `;
        return { error: null };
      } catch (e) {
        return { error: e };
      }
    }
    const { error } = await admin.rpc("advance_upload_session_processing", {
      p_session_id: sessionId,
      p_uploader_id: uploaderId,
      p_lease_duration: "10 minutes",
    });
    return { error };
  },
  checkLease: async (admin, sessionId) => {
    const sql = getLocalDbClient();
    if (sql) {
      try {
        const rows = await sql`
          SELECT check_upload_session_lease(${sessionId}::uuid) AS result
        `;
        return {
          data: rows[0]?.result as boolean ?? null,
          error: null,
        };
      } catch (e) {
        return { data: null, error: e };
      }
    }
    const { data, error } = await admin
      .rpc("check_upload_session_lease", { p_session_id: sessionId })
      .single();
    return { data: data as boolean | null, error };
  },
  advanceSanitized: async (admin, sessionId) => {
    const sql = getLocalDbClient();
    if (sql) {
      try {
        await sql`
          SELECT advance_upload_session_sanitized(${sessionId}::uuid)
        `;
        return { error: null };
      } catch (e) {
        return { error: e };
      }
    }
    const { error } = await admin.rpc("advance_upload_session_sanitized", {
      p_session_id: sessionId,
    });
    return { error };
  },
  finalizeSession: async (admin, sessionId, sha256Hash) => {
    const sql = getLocalDbClient();
    if (sql) {
      try {
        const rows = await sql`
          SELECT media_object_id, replaced_media_object_id
          FROM finalize_upload_session(${sessionId}::uuid, ${sha256Hash})
        `;
        return {
          data: rows.length > 0 ? (rows[0] as unknown as FinalizeResult) : null,
          error: null,
        };
      } catch (e) {
        return { data: null, error: e };
      }
    }
    const { data, error } = await admin
      .rpc("finalize_upload_session", {
        p_session_id: sessionId,
        p_sha256_hash: sha256Hash,
      })
      .single();
    return { data: data as FinalizeResult | null, error };
  },
  failSession: async (admin, sessionId, code) => {
    const sql = getLocalDbClient();
    if (sql) {
      try {
        await sql`SELECT fail_upload_session(${sessionId}::uuid, ${code})`;
        return { error: null };
      } catch (e) {
        return { error: e };
      }
    }
    const { error } = await admin.rpc("fail_upload_session", {
      p_session_id: sessionId,
      p_error_code: code,
    });
    return { error };
  },
  callCf: callImageTransform,
  deleteFromR2: defaultDeleteFromR2,
  downloadFromR2: defaultDownloadFromR2,
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function elapsed(t0: number): number {
  return Math.round(performance.now() - t0);
}

/** Extract the UUID after the last 'originals/' prefix. */
function extractMediaUuid(originalStoragePath: string): string {
  const prefix = "originals/";
  const idx = originalStoragePath.lastIndexOf(prefix);
  if (idx === -1) return originalStoragePath;
  return originalStoragePath.slice(idx + prefix.length);
}

/**
 * Delete key from R2 with up to 2 retries.
 * NoSuchKey (absent) is treated as success (idempotent).
 * Returns true if successful (including absent), false if all attempts fail.
 */
async function deleteWithRetry(
  deps: Deps,
  key: string,
  requestId: string,
  fn: string,
): Promise<boolean> {
  for (let attempt = 0; attempt < 3; attempt++) {
    try {
      await deps.deleteFromR2(key);
      return true;
    } catch (err) {
      if (err instanceof Error && err.name === "NoSuchKey") return true;
      // Inner-loop operational log — use console.log (not request-level safeLog)
      console.log(
        JSON.stringify({
          fn,
          outcome: "r2_delete_attempt_failed",
          request_id: requestId,
          attempt: attempt + 1,
        }),
      );
    }
  }
  return false;
}

/**
 * Best-effort fail session — never throws.
 * Inspects the returned `{ error }` (failSession resolves, it does not throw)
 * and emits a credential-safe operational log when the RPC transition fails.
 */
async function bestEffortFail(
  deps: Deps,
  admin: SupabaseClient,
  sessionId: string,
  code: FkErrorCode,
): Promise<void> {
  try {
    const { error } = await deps.failSession(admin, sessionId, code);
    if (error) {
      console.log(
        JSON.stringify({
          fn: "upload-complete",
          outcome: "best_effort_fail_rpc_error",
          code,
        }),
      );
    }
  } catch {
    // Ignore throws (network errors, etc.)
  }
}

/** Re-resolve session state for error recovery branches. */
async function reResolveStatus(
  deps: Deps,
  admin: SupabaseClient,
  tokenHash: string,
  uploaderId: string,
): Promise<string | null> {
  try {
    const { data } = await deps.resolveSession(admin, tokenHash, uploaderId);
    return data?.status ?? null;
  } catch {
    return null;
  }
}

/** Verify WebP magic bytes: RIFF at 0-3, WEBP at 8-11. */
function isWebP(bytes: Uint8Array): boolean {
  if (bytes.length < 12) return false;
  return (
    bytes[0] === 0x52 && // R
    bytes[1] === 0x49 && // I
    bytes[2] === 0x46 && // F
    bytes[3] === 0x46 && // F
    bytes[8] === 0x57 && // W
    bytes[9] === 0x45 && // E
    bytes[10] === 0x42 && // B
    bytes[11] === 0x50 // P
  );
}

// ---------------------------------------------------------------------------
// §5.4 Sanitized re-entry
// ---------------------------------------------------------------------------

async function handleSanitized(
  deps: Deps,
  admin: SupabaseClient,
  session: SessionRow,
  tokenHash: string,
  uploaderId: string,
  requestId: string,
  t0: number,
): Promise<Response> {
  const fn = "upload-complete";

  // SR-1. Delete original (idempotent; absent = no-op via DeleteObjectCommand)
  const origDeleted = await deleteWithRetry(
    deps,
    session.original_storage_path,
    requestId,
    fn,
  );
  if (!origDeleted) {
    await deps.deleteFromR2(session.display_storage_path).catch(() => {});
    await bestEffortFail(
      deps,
      admin,
      session.session_id,
      "FK_PROCESSING_FAILED",
    );
    safeLog({
      fn,
      status: 422,
      outcome: "sr1_delete_original_failed",
      request_id: requestId,
      duration_ms: elapsed(t0),
    });
    return errorEnvelope("FK_PROCESSING_FAILED", "Processing failed", 422);
  }

  // SR-2. Download display from R2
  let displayBytes: Uint8Array | null;
  try {
    displayBytes = await deps.downloadFromR2(session.display_storage_path);
  } catch {
    displayBytes = null;
  }
  if (!displayBytes) {
    await bestEffortFail(
      deps,
      admin,
      session.session_id,
      "FK_PROCESSING_FAILED",
    );
    safeLog({
      fn,
      status: 422,
      outcome: "sr2_display_absent",
      request_id: requestId,
      duration_ms: elapsed(t0),
    });
    return errorEnvelope("FK_PROCESSING_FAILED", "Processing failed", 422);
  }

  // SR-3. Verify WebP magic bytes
  if (!isWebP(displayBytes)) {
    await deps.deleteFromR2(session.display_storage_path).catch(() => {});
    await bestEffortFail(
      deps,
      admin,
      session.session_id,
      "FK_PROCESSING_FAILED",
    );
    safeLog({
      fn,
      status: 422,
      outcome: "sr3_invalid_webp",
      request_id: requestId,
      duration_ms: elapsed(t0),
    });
    return errorEnvelope("FK_PROCESSING_FAILED", "Processing failed", 422);
  }

  // SR-4. Compute SHA-256
  const sha256Hash = await deps.sha256(displayBytes);

  // SR-5. Finalize session (same error handling as §5.3 step 8)
  return await finalizeAndRespond(
    deps,
    admin,
    session,
    sha256Hash,
    tokenHash,
    uploaderId,
    requestId,
    t0,
  );
}

// ---------------------------------------------------------------------------
// Finalization (shared between happy path and sanitized re-entry)
// ---------------------------------------------------------------------------

async function finalizeAndRespond(
  deps: Deps,
  admin: SupabaseClient,
  session: SessionRow,
  sha256Hash: string,
  tokenHash: string,
  uploaderId: string,
  requestId: string,
  t0: number,
): Promise<Response> {
  const fn = "upload-complete";
  const { data: finData, error: finErr } = await deps.finalizeSession(
    admin,
    session.session_id,
    sha256Hash,
  );

  if (finErr) {
    // Re-resolve to determine recovery action
    const reState = await reResolveStatus(deps, admin, tokenHash, uploaderId);
    if (reState === "complete") {
      safeLog({
        fn,
        status: 200,
        outcome: "finalize_error_resolved_complete",
        request_id: requestId,
        duration_ms: elapsed(t0),
      });
      return new Response(
        JSON.stringify({ status: "pending_review", already_complete: true }),
        {
          status: 200,
          headers: {
            "Content-Type": "application/json",
            "Cache-Control": "no-store",
          },
        },
      );
    }

    // FK_INVALID_HASH is raised by the DB but is not in FkErrorCode; check raw message.
    const rawFinErr = finErr && typeof finErr === "object"
      ? String(
        (finErr as Record<string, unknown>)["message"] ?? "",
      )
      : String(finErr ?? "");

    if (rawFinErr.includes("FK_INVALID_HASH")) {
      safeLog({
        fn,
        status: 422,
        outcome: "finalize_invalid_hash",
        request_id: requestId,
        duration_ms: elapsed(t0),
      });
      return errorEnvelope("FK_PROCESSING_FAILED", "Processing failed", 422);
    }
    const errCode = extractDbErrorCode(finErr) ?? "FK_INTERNAL";
    if (errCode === "FK_WRONG_STATE") {
      safeLog({
        fn,
        status: 409,
        outcome: "finalize_wrong_state",
        request_id: requestId,
        duration_ms: elapsed(t0),
      });
      return errorEnvelope("FK_WRONG_STATE", "Wrong state", 409);
    }
    safeLog({
      fn,
      status: 500,
      outcome: "finalize_error",
      request_id: requestId,
      duration_ms: elapsed(t0),
    });
    return errorEnvelope("FK_INTERNAL", "Internal error", 500);
  }

  if (!finData) {
    safeLog({
      fn,
      status: 500,
      outcome: "finalize_no_data",
      request_id: requestId,
      duration_ms: elapsed(t0),
    });
    return errorEnvelope("FK_INTERNAL", "Internal error", 500);
  }

  safeLog({
    fn,
    status: 200,
    outcome: "complete",
    request_id: requestId,
    duration_ms: elapsed(t0),
  });
  return new Response(
    JSON.stringify({
      status: "pending_review",
      media_object_id: finData.media_object_id,
      replaced_media_object_id: finData.replaced_media_object_id ?? null,
    }),
    {
      status: 200,
      headers: {
        "Content-Type": "application/json",
        "Cache-Control": "no-store",
      },
    },
  );
}

// ---------------------------------------------------------------------------
// Handler factory
// ---------------------------------------------------------------------------

export function makeHandler(
  deps: Deps = defaultDeps,
): (req: Request) => Promise<Response> {
  return async (req: Request): Promise<Response> => {
    if (req.method !== "POST") {
      return new Response("Method Not Allowed", {
        status: 405,
        headers: { Allow: "POST", "Cache-Control": "no-store" },
      });
    }

    const requestId = req.headers.get("X-Request-Id") ?? crypto.randomUUID();
    const t0 = performance.now();
    const fn = "upload-complete";

    try {
      // ── Auth ──────────────────────────────────────────────────────────────
      const authResult = await deps.getAuth(req);
      if (!authResult.ok) {
        safeLog({
          fn,
          status: 401,
          error_code: "FK_UNAUTHENTICATED",
          request_id: requestId,
          duration_ms: elapsed(t0),
        });
        return authResult.error;
      }
      const { supabaseAdmin: admin, userClaims } = authResult.ctx;
      const uploaderId = userClaims.id;

      // ── Parse body ────────────────────────────────────────────────────────
      let uploadToken: string;
      try {
        const body = (await req.json()) as Record<string, unknown>;
        const tok = body["upload_token"];
        if (typeof tok !== "string" || tok === "") {
          return errorEnvelope(
            "FK_INVALID_INPUT",
            "upload_token is required",
            400,
          );
        }
        uploadToken = tok;
      } catch {
        return errorEnvelope(
          "FK_INVALID_INPUT",
          "Body must be valid JSON",
          400,
        );
      }

      // ── Hash token → resolve session ──────────────────────────────────────
      const tokenHash = await deps.sha256(
        new TextEncoder().encode(uploadToken),
      );
      const { data: session, error: resolveErr } = await deps.resolveSession(
        admin,
        tokenHash,
        uploaderId,
      );

      if (resolveErr || !session) {
        safeLog({
          fn,
          status: 400,
          error_code: "FK_INVALID_TOKEN",
          request_id: requestId,
          duration_ms: elapsed(t0),
        });
        return errorEnvelope(
          "FK_INVALID_TOKEN",
          "Invalid or expired token",
          400,
        );
      }

      // ── §5.2 Idempotency branch ───────────────────────────────────────────
      if (session.status === "complete") {
        safeLog({
          fn,
          status: 200,
          outcome: "already_complete",
          request_id: requestId,
          duration_ms: elapsed(t0),
        });
        return new Response(
          JSON.stringify({
            status: "pending_review",
            media_object_id: session.media_object_id,
            replaced_media_object_id: session.replaced_media_object_id ?? null,
            already_complete: true,
          }),
          {
            status: 200,
            headers: {
              "Content-Type": "application/json",
              "Cache-Control": "no-store",
            },
          },
        );
      }

      if (session.status === "processing") {
        safeLog({
          fn,
          status: 202,
          outcome: "processing",
          request_id: requestId,
          duration_ms: elapsed(t0),
        });
        return new Response(JSON.stringify({ status: "processing" }), {
          status: 202,
          headers: {
            "Content-Type": "application/json",
            "Cache-Control": "no-store",
          },
        });
      }

      if (session.status === "sanitized") {
        return await handleSanitized(
          deps,
          admin,
          session,
          tokenHash,
          uploaderId,
          requestId,
          t0,
        );
      }

      if (session.status !== "pending") {
        safeLog({
          fn,
          status: 400,
          error_code: "FK_INVALID_TOKEN",
          request_id: requestId,
          duration_ms: elapsed(t0),
        });
        return errorEnvelope(
          "FK_INVALID_TOKEN",
          "Invalid or expired token",
          400,
        );
      }

      // ── §5.3 Happy path ───────────────────────────────────────────────────

      // Step 1. Advance to processing
      const { error: advErr } = await deps.advanceProcessing(
        admin,
        session.session_id,
        uploaderId,
      );
      if (advErr) {
        safeLog({
          fn,
          status: 400,
          error_code: "FK_INVALID_TOKEN",
          outcome: "advance_processing_failed",
          request_id: requestId,
          duration_ms: elapsed(t0),
        });
        return errorEnvelope(
          "FK_INVALID_TOKEN",
          "Invalid or expired token",
          400,
        );
      }

      // Step 2. Extract media UUID
      const mediaUuid = extractMediaUuid(session.original_storage_path);

      // Step 3. Call CF Worker
      const cfResult = await deps.callCf(mediaUuid);
      if (!cfResult.ok) {
        await bestEffortFail(deps, admin, session.session_id, cfResult.fkCode);
        const statusMap: Record<FkErrorCode, number> = {
          FK_NOT_FOUND: 404,
          FK_PROCESSING_FAILED: 422,
          FK_INTERNAL: 500,
          FK_UNAUTHENTICATED: 500,
          FK_FORBIDDEN: 500,
          FK_WRONG_STATE: 500,
          FK_UPLOAD_IN_PROGRESS: 500,
          FK_FILE_TOO_LARGE: 500,
          FK_INVALID_CONTENT_TYPE: 500,
          FK_INVALID_INPUT: 500,
          FK_INVALID_TOKEN: 500,
        };
        safeLog({
          fn,
          status: statusMap[cfResult.fkCode] ?? 500,
          error_code: cfResult.fkCode,
          outcome: "cf_worker_failed",
          request_id: requestId,
          duration_ms: elapsed(t0),
        });
        return errorEnvelope(
          cfResult.fkCode,
          "Processing failed",
          statusMap[cfResult.fkCode] ?? 500,
        );
      }

      // Step 4. Validate CF Worker response
      const cfValid = cfResult.displayKey === session.display_storage_path &&
        /^[0-9a-f]{64}$/.test(cfResult.sha256) &&
        Number.isInteger(cfResult.bytes) &&
        cfResult.bytes > 0 &&
        cfResult.bytes <= 5_242_880;
      if (!cfValid) {
        await bestEffortFail(deps, admin, session.session_id, "FK_INTERNAL");
        safeLog({
          fn,
          status: 500,
          error_code: "FK_INTERNAL",
          outcome: "cf_response_validation_failed",
          request_id: requestId,
          duration_ms: elapsed(t0),
        });
        return errorEnvelope("FK_INTERNAL", "Internal error", 500);
      }

      const { sha256: sha256Hash } = cfResult;

      // Step 5. Check lease
      const { data: leaseOk, error: leaseErr } = await deps.checkLease(
        admin,
        session.session_id,
      );
      if (leaseErr || leaseOk === false || leaseOk === null) {
        // Lease expired or error — delete original only; no fail_session
        await deps.deleteFromR2(session.original_storage_path).catch(
          () => {},
        );
        safeLog({
          fn,
          status: 422,
          error_code: "FK_PROCESSING_FAILED",
          outcome: "lease_expired",
          request_id: requestId,
          duration_ms: elapsed(t0),
        });
        return errorEnvelope(
          "FK_PROCESSING_FAILED",
          "Processing failed",
          422,
        );
      }

      // Step 6. Advance to sanitized
      const { error: sanErr } = await deps.advanceSanitized(
        admin,
        session.session_id,
      );
      if (sanErr) {
        // Re-resolve to determine recovery action
        const reState = await reResolveStatus(
          deps,
          admin,
          tokenHash,
          uploaderId,
        );
        if (reState === "sanitized") {
          return await handleSanitized(
            deps,
            admin,
            session,
            tokenHash,
            uploaderId,
            requestId,
            t0,
          );
        }
        if (reState === "complete") {
          await deps.deleteFromR2(session.original_storage_path).catch(
            () => {},
          );
          safeLog({
            fn,
            status: 200,
            outcome: "advance_sanitized_error_resolved_complete",
            request_id: requestId,
            duration_ms: elapsed(t0),
          });
          return new Response(
            JSON.stringify({
              status: "pending_review",
              already_complete: true,
            }),
            {
              status: 200,
              headers: {
                "Content-Type": "application/json",
                "Cache-Control": "no-store",
              },
            },
          );
        }
        // processing or other: clean up both files
        await deps.deleteFromR2(session.display_storage_path).catch(() => {});
        await deps.deleteFromR2(session.original_storage_path).catch(
          () => {},
        );
        await bestEffortFail(deps, admin, session.session_id, "FK_INTERNAL");
        safeLog({
          fn,
          status: 500,
          error_code: "FK_INTERNAL",
          outcome: "advance_sanitized_error_unrecoverable",
          request_id: requestId,
          duration_ms: elapsed(t0),
        });
        return errorEnvelope("FK_INTERNAL", "Internal error", 500);
      }

      // Step 7. Delete original from R2 (retry up to 2 times)
      const origDeleted = await deleteWithRetry(
        deps,
        session.original_storage_path,
        requestId,
        fn,
      );
      if (!origDeleted) {
        await deps.deleteFromR2(session.display_storage_path).catch(() => {});
        await bestEffortFail(
          deps,
          admin,
          session.session_id,
          "FK_PROCESSING_FAILED",
        );
        safeLog({
          fn,
          status: 422,
          error_code: "FK_PROCESSING_FAILED",
          outcome: "delete_original_failed",
          request_id: requestId,
          duration_ms: elapsed(t0),
        });
        return errorEnvelope(
          "FK_PROCESSING_FAILED",
          "Processing failed",
          422,
        );
      }

      // Step 8. Finalize session
      return await finalizeAndRespond(
        deps,
        admin,
        session,
        sha256Hash,
        tokenHash,
        uploaderId,
        requestId,
        t0,
      );
    } catch {
      safeLog({
        fn,
        status: 500,
        error_code: "FK_INTERNAL",
        outcome: "unexpected_throw",
        request_id: requestId,
        duration_ms: elapsed(t0),
      });
      return errorEnvelope("FK_INTERNAL", "Internal error", 500);
    }
  };
}

// ---------------------------------------------------------------------------
// Entrypoint
// ---------------------------------------------------------------------------

if (import.meta.main) {
  Deno.serve(makeHandler());
}
