import type { SupabaseClient } from "npm:@supabase/supabase-js@2.112.3";
import { getAuthContext } from "../_shared/context.ts";
import type { AuthResult } from "../_shared/context.ts";
import { checkActiveProfile } from "../_shared/profile.ts";
import type { ProfileCheckResult } from "../_shared/profile.ts";
import { getLocalDbClient } from "../_shared/dbClient.ts";
import { presignPutUrl } from "../_shared/s3.ts";
import { errorEnvelope, extractDbErrorCode } from "../_shared/errors.ts";
import type { FkErrorCode } from "../_shared/errors.ts";
import { safeLog } from "../_shared/log.ts";
import { generateUploadToken, sha256Hex } from "../_shared/crypto.ts";

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

interface ReserveParams {
  p_case_id: string;
  p_uploader_id: string;
  p_token_hash: string;
  p_content_type: string;
  p_declared_size: number;
  p_client_expires_at: string;
}

interface ReserveResult {
  session_id: string;
  original_storage_path: string;
  display_storage_path: string;
}

interface ActivateParams {
  p_session_id: string;
  p_actual_storage_upload_expires_at: string;
}

// ---------------------------------------------------------------------------
// Deps interface
// ---------------------------------------------------------------------------

export interface Deps {
  generateToken: () => string;
  sha256: (data: Uint8Array) => Promise<string>;
  getAuth: (req: Request) => Promise<AuthResult>;
  checkProfile: (
    supabase: SupabaseClient,
    userId: string,
  ) => Promise<ProfileCheckResult>;
  reserveSession: (
    admin: SupabaseClient,
    params: ReserveParams,
  ) => Promise<{ data: ReserveResult | null; error: unknown }>;
  activateSession: (
    admin: SupabaseClient,
    params: ActivateParams,
  ) => Promise<{ data: null; error: unknown }>;
  failSession: (
    admin: SupabaseClient,
    sessionId: string,
    code: FkErrorCode,
  ) => Promise<{ data: null; error: unknown }>;
  presign: (
    path: string,
    expiresIn: 300,
    contentType: string,
  ) => Promise<{ url: string; expiresAt: Date }>;
  now: () => Date;
}

export const defaultDeps: Deps = {
  generateToken: generateUploadToken,
  sha256: sha256Hex,
  getAuth: getAuthContext,
  checkProfile: checkActiveProfile,
  // reserveSession / activateSession / failSession each use direct SQL when
  // FK_DB_URL is set (local integration testing). The edge runtime intercepts
  // outbound HTTP to its own port, causing supabase-js .rpc() calls to hang
  // for 7 s. A direct PostgreSQL connection (port 54322) avoids this.
  // In production FK_DB_URL is absent and the admin.rpc() path is used.
  reserveSession: async (admin, p) => {
    const sql = getLocalDbClient();
    if (sql) {
      try {
        const rows = await sql`
          SELECT session_id, original_storage_path, display_storage_path
          FROM reserve_upload_session(
            ${p.p_case_id}::uuid,
            ${p.p_uploader_id}::uuid,
            ${p.p_token_hash},
            ${p.p_content_type},
            ${p.p_declared_size}::bigint,
            ${p.p_client_expires_at}::timestamptz
          )
        `;
        if (rows.length === 0) {
          return {
            data: null,
            error: { message: "reserve_upload_session returned no rows" },
          };
        }
        return { data: rows[0] as ReserveResult, error: null };
      } catch (e) {
        return { data: null, error: e };
      }
    }
    return await admin.rpc("reserve_upload_session", p).single();
  },
  activateSession: async (admin, p) => {
    const sql = getLocalDbClient();
    if (sql) {
      try {
        await sql`
          SELECT activate_upload_session(
            ${p.p_session_id}::uuid,
            ${p.p_actual_storage_upload_expires_at}::timestamptz
          )
        `;
        return { data: null, error: null };
      } catch (e) {
        return { data: null, error: e };
      }
    }
    return await admin.rpc("activate_upload_session", p);
  },
  failSession: async (admin, id, code) => {
    const sql = getLocalDbClient();
    if (sql) {
      try {
        await sql`SELECT fail_upload_session(${id}::uuid, ${code})`;
        return { data: null, error: null };
      } catch (e) {
        return { data: null, error: e };
      }
    }
    return await admin.rpc("fail_upload_session", {
      p_session_id: id,
      p_error_code: code,
    });
  },
  presign: presignPutUrl,
  now: () => new Date(),
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function elapsed(t0: number): number {
  return Math.round(performance.now() - t0);
}

async function bestEffortFail(
  deps: Deps,
  admin: SupabaseClient,
  sessionId: string,
  request_id: string,
  t0: number,
): Promise<void> {
  try {
    const { error } = await deps.failSession(admin, sessionId, "FK_INTERNAL");
    if (error) {
      safeLog({
        fn: "upload-authorize",
        status: 500,
        duration_ms: elapsed(t0),
        outcome: "fail_session_error",
        request_id,
      });
    }
  } catch {
    safeLog({
      fn: "upload-authorize",
      status: 500,
      duration_ms: elapsed(t0),
      outcome: "fail_session_error",
      request_id,
    });
  }
  // Never throws.
}

// ---------------------------------------------------------------------------
// Body validation
// ---------------------------------------------------------------------------

const ALLOWED_CONTENT_TYPES = new Set(["image/jpeg", "image/webp"]);
const MAX_SIZE = 10 * 1024 * 1024; // 10 MiB

type BodyOk = {
  ok: true;
  caseId: string;
  contentType: string;
  declaredSizeBytes: number;
};
type BodyErr = {
  ok: false;
  code: FkErrorCode;
  message: string;
  status: number;
};

async function parseAndValidateBody(req: Request): Promise<BodyOk | BodyErr> {
  let parsed: unknown;
  try {
    parsed = await req.json();
  } catch {
    return {
      ok: false,
      code: "FK_INVALID_INPUT",
      message: "Body must be valid JSON",
      status: 400,
    };
  }

  if (!parsed || typeof parsed !== "object") {
    return {
      ok: false,
      code: "FK_INVALID_INPUT",
      message: "Body must be a JSON object",
      status: 400,
    };
  }

  const body = parsed as Record<string, unknown>;

  const caseId = body["case_id"];
  if (typeof caseId !== "string" || caseId.trim() === "") {
    return {
      ok: false,
      code: "FK_INVALID_INPUT",
      message: "case_id is required",
      status: 400,
    };
  }
  // Validate UUID format
  if (
    !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(
      caseId,
    )
  ) {
    return {
      ok: false,
      code: "FK_INVALID_INPUT",
      message: "case_id must be a valid UUID",
      status: 400,
    };
  }

  const contentType = body["content_type"];
  if (typeof contentType !== "string") {
    return {
      ok: false,
      code: "FK_INVALID_CONTENT_TYPE",
      message: "content_type is required",
      status: 400,
    };
  }
  if (!ALLOWED_CONTENT_TYPES.has(contentType)) {
    return {
      ok: false,
      code: "FK_INVALID_CONTENT_TYPE",
      message: "content_type must be image/jpeg or image/webp",
      status: 400,
    };
  }

  const declaredSizeBytes = body["declared_size_bytes"];
  if (typeof declaredSizeBytes !== "number") {
    return {
      ok: false,
      code: "FK_INVALID_INPUT",
      message: "declared_size_bytes is required",
      status: 400,
    };
  }
  if (!Number.isInteger(declaredSizeBytes) || declaredSizeBytes < 1) {
    return {
      ok: false,
      code: "FK_INVALID_INPUT",
      message: "declared_size_bytes must be a positive integer",
      status: 400,
    };
  }
  if (declaredSizeBytes > MAX_SIZE) {
    return {
      ok: false,
      code: "FK_FILE_TOO_LARGE",
      message: "declared_size_bytes must be at most 10485760",
      status: 400,
    };
  }

  return { ok: true, caseId, contentType, declaredSizeBytes };
}

// ---------------------------------------------------------------------------
// Handler factory
// ---------------------------------------------------------------------------

export function makeHandler(
  deps: Deps = defaultDeps,
): (req: Request) => Promise<Response> {
  return async (req: Request): Promise<Response> => {
    // Step 0 — Method enforcement (outside try/catch)
    if (req.method !== "POST") {
      return new Response("Method Not Allowed", {
        status: 405,
        headers: { Allow: "POST", "Cache-Control": "no-store" },
      });
    }

    const request_id = req.headers.get("X-Request-Id") ?? crypto.randomUUID();
    const t0 = performance.now();
    let admin: SupabaseClient | null = null;
    let sessionId: string | null = null;
    let compensationAttempted = false;

    try {
      // Step 1 — Auth
      const authResult = await deps.getAuth(req);
      if (!authResult.ok) {
        safeLog({
          fn: "upload-authorize",
          status: 401,
          duration_ms: elapsed(t0),
          error_code: "FK_UNAUTHENTICATED",
          request_id,
        });
        return authResult.error;
      }
      admin = authResult.ctx.supabaseAdmin;

      // Step 2 — Profile
      // checkActiveProfile uses direct SQL in local dev (FK_DB_URL gate) and
      // the REST API in production. See _shared/profile.ts for rationale.
      // Security: userId comes from the already-verified JWT claims.
      const pr = await deps.checkProfile(
        authResult.ctx.supabaseAdmin,
        authResult.ctx.userClaims.id,
      );
      if (pr.status === "forbidden") {
        safeLog({
          fn: "upload-authorize",
          status: 403,
          duration_ms: elapsed(t0),
          error_code: "FK_FORBIDDEN",
          request_id,
          user_id: authResult.ctx.userClaims.id,
        });
        return errorEnvelope("FK_FORBIDDEN", "Profile not eligible", 403);
      }
      if (pr.status === "error") {
        safeLog({
          fn: "upload-authorize",
          status: 500,
          duration_ms: elapsed(t0),
          error_code: "FK_INTERNAL",
          request_id,
          user_id: authResult.ctx.userClaims.id,
        });
        return errorEnvelope("FK_INTERNAL", "Internal error", 500);
      }

      // Step 3 — Body validation
      const bodyResult = await parseAndValidateBody(req);
      if (!bodyResult.ok) {
        safeLog({
          fn: "upload-authorize",
          status: bodyResult.status,
          duration_ms: elapsed(t0),
          error_code: bodyResult.code,
          request_id,
          user_id: authResult.ctx.userClaims.id,
        });
        return errorEnvelope(
          bodyResult.code,
          bodyResult.message,
          bodyResult.status,
        );
      }
      const { caseId, contentType, declaredSizeBytes } = bodyResult;

      // Step 4 — Token
      const rawToken = deps.generateToken();
      const tokenHash = await deps.sha256(new TextEncoder().encode(rawToken));
      const sessionExpiry = new Date(deps.now().getTime() + 900_000);

      // Step 5 — Reserve
      const { data: row, error: reserveErr } = await deps.reserveSession(
        authResult.ctx.supabaseAdmin,
        {
          p_case_id: caseId,
          p_uploader_id: authResult.ctx.userClaims.id,
          p_token_hash: tokenHash,
          p_content_type: contentType,
          p_declared_size: declaredSizeBytes,
          p_client_expires_at: sessionExpiry.toISOString(),
        },
      );
      if (reserveErr) {
        const code = extractDbErrorCode(reserveErr) ?? "FK_INTERNAL";
        const statusMap: Record<string, number> = {
          FK_NOT_FOUND: 404,
          FK_WRONG_STATE: 409,
          FK_UPLOAD_IN_PROGRESS: 409,
          FK_FORBIDDEN: 403,
        };
        const status = statusMap[code] ?? 500;
        safeLog({
          fn: "upload-authorize",
          status,
          error_code: code as FkErrorCode,
          duration_ms: elapsed(t0),
          request_id,
          user_id: authResult.ctx.userClaims.id,
          case_id: caseId,
        });
        return errorEnvelope(code as FkErrorCode, "Reservation failed", status);
      }
      if (!row) {
        safeLog({
          fn: "upload-authorize",
          status: 500,
          error_code: "FK_INTERNAL",
          duration_ms: elapsed(t0),
          request_id,
          user_id: authResult.ctx.userClaims.id,
          case_id: caseId,
        });
        return errorEnvelope("FK_INTERNAL", "Internal error", 500);
      }
      sessionId = row.session_id;

      // Step 6 — Presign (contentType baked into signature; R2 rejects mismatched PUT)
      let presignedUrl: string;
      let urlExpiresAt: Date;
      try {
        ({ url: presignedUrl, expiresAt: urlExpiresAt } = await deps.presign(
          row.original_storage_path,
          300,
          contentType,
        ));
      } catch (presignErr) {
        compensationAttempted = true;
        await bestEffortFail(
          deps,
          authResult.ctx.supabaseAdmin,
          sessionId,
          request_id,
          t0,
        );
        safeLog({
          fn: "upload-authorize",
          status: 500,
          error_code: "FK_INTERNAL",
          outcome: "failed_presign",
          presign_error: presignErr instanceof Error
            ? presignErr.message
            : String(presignErr),
          duration_ms: elapsed(t0),
          request_id,
          user_id: authResult.ctx.userClaims.id,
          case_id: caseId,
        });
        return errorEnvelope("FK_INTERNAL", "Internal error", 500);
      }

      // Step 7 — Activate
      const { error: activateErr } = await deps.activateSession(
        authResult.ctx.supabaseAdmin,
        {
          p_session_id: sessionId,
          p_actual_storage_upload_expires_at: urlExpiresAt.toISOString(),
        },
      );
      if (activateErr) {
        compensationAttempted = true;
        await bestEffortFail(
          deps,
          authResult.ctx.supabaseAdmin,
          sessionId,
          request_id,
          t0,
        );
        safeLog({
          fn: "upload-authorize",
          status: 500,
          error_code: "FK_INTERNAL",
          outcome: "failed_activate",
          duration_ms: elapsed(t0),
          request_id,
          user_id: authResult.ctx.userClaims.id,
          case_id: caseId,
        });
        return errorEnvelope("FK_INTERNAL", "Internal error", 500);
        // presignedUrl discarded — not returned
      }

      // Step 8 — Success
      safeLog({
        fn: "upload-authorize",
        status: 200,
        outcome: "activated",
        duration_ms: elapsed(t0),
        request_id,
        user_id: authResult.ctx.userClaims.id,
        case_id: caseId,
      });
      return new Response(
        JSON.stringify({
          presigned_url: presignedUrl,
          upload_token: rawToken,
          expires_at: urlExpiresAt.toISOString(),
        }),
        {
          status: 200,
          headers: {
            "Content-Type": "application/json",
            "Cache-Control": "no-store",
          },
        },
      );
    } catch {
      // Unanticipated throw from any adapter.
      if (admin && sessionId && !compensationAttempted) {
        compensationAttempted = true;
        await bestEffortFail(deps, admin, sessionId, request_id, t0);
      }
      safeLog({
        fn: "upload-authorize",
        status: 500,
        error_code: "FK_INTERNAL",
        outcome: "unexpected_throw",
        duration_ms: elapsed(t0),
        request_id,
      });
      return errorEnvelope("FK_INTERNAL", "Internal error", 500);
    }
  };
}

// ---------------------------------------------------------------------------
// Entrypoint — only starts server when run directly, not on import by tests
// ---------------------------------------------------------------------------

if (import.meta.main) {
  Deno.serve(makeHandler());
}
