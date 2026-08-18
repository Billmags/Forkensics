import { DeleteObjectCommand, S3Client } from "npm:@aws-sdk/client-s3@3.1109.0";
import { createClient } from "npm:@supabase/supabase-js@2.112.3";
import type { SupabaseClient } from "npm:@supabase/supabase-js@2.112.3";
import { getLocalDbClient } from "../_shared/dbClient.ts";
import { errorEnvelope } from "../_shared/errors.ts";
import { safeLog } from "../_shared/log.ts";

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

interface CleanupSession {
  session_id: string;
  original_storage_path: string;
  display_storage_path: string;
  status: string;
  cleanup_claim_token: string;
}

interface SupersededMedia {
  media_object_id: string;
  re_encoded_storage_key: string;
}

interface ExpirySession {
  session_id: string;
  original_storage_path: string;
}

// ---------------------------------------------------------------------------
// Deps interface
// ---------------------------------------------------------------------------

export interface Deps {
  getAdminClient: () => SupabaseClient;
  timingSafeEqual: (a: string, b: string) => boolean;
  getCronSecret: () => string;
  claimCleanupSessions: (
    admin: SupabaseClient,
    workerId: string,
  ) => Promise<{ data: CleanupSession[]; error: unknown }>;
  markSessionCleaned: (
    admin: SupabaseClient,
    sessionId: string,
    claimToken: string,
  ) => Promise<{ error: unknown }>;
  getSupersededMedia: (
    admin: SupabaseClient,
  ) => Promise<{ data: SupersededMedia[]; error: unknown }>;
  markSupersededMediaCleaned: (
    admin: SupabaseClient,
    mediaObjectId: string,
  ) => Promise<{ error: unknown }>;
  getExpiryCleanupSessions: (
    admin: SupabaseClient,
  ) => Promise<{ data: ExpirySession[]; error: unknown }>;
  markOriginalPathCleaned: (
    admin: SupabaseClient,
    sessionId: string,
  ) => Promise<{ error: unknown }>;
  deleteFromR2: (key: string) => Promise<void>;
}

// ---------------------------------------------------------------------------
// Constant-time string comparison
// ---------------------------------------------------------------------------

/**
 * Compares two strings in constant time (XOR-based).
 * Prevents timing attacks on the CRON_SECRET header check.
 * Returns true only when both strings are identical in length and content.
 */
export function timingSafeEqualStr(a: string, b: string): boolean {
  const aBytes = new TextEncoder().encode(a);
  const bBytes = new TextEncoder().encode(b);
  const len = Math.max(aBytes.length, bBytes.length);
  // XOR length difference into result — non-zero means lengths differ
  let result = aBytes.length ^ bBytes.length;
  for (let i = 0; i < len; i++) {
    result |= (aBytes[i] ?? 0) ^ (bBytes[i] ?? 0);
  }
  return result === 0;
}

// ---------------------------------------------------------------------------
// R2 helper
// ---------------------------------------------------------------------------

function buildR2Client(): S3Client {
  const endpoint = Deno.env.get("R2_ENDPOINT");
  const accessKeyId = Deno.env.get("R2_ACCESS_KEY_ID");
  const secretAccessKey = Deno.env.get("R2_SECRET_ACCESS_KEY");
  if (!endpoint || !accessKeyId || !secretAccessKey) {
    throw new Error("upload-cleanup-worker: R2 credentials not configured");
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
  if (!bucket) throw new Error("upload-cleanup-worker: R2_BUCKET not set");
  return bucket;
}

async function defaultDeleteFromR2(key: string): Promise<void> {
  const client = buildR2Client();
  const bucket = getR2Bucket();
  // DeleteObjectCommand is idempotent: absent object returns 204.
  await client.send(new DeleteObjectCommand({ Bucket: bucket, Key: key }));
}

// ---------------------------------------------------------------------------
// Admin client
// ---------------------------------------------------------------------------

function buildAdminClient(): SupabaseClient {
  const url = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !serviceKey) {
    throw new Error(
      "upload-cleanup-worker: SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY must be set",
    );
  }
  return createClient(url, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

// ---------------------------------------------------------------------------
// Default deps (production)
// ---------------------------------------------------------------------------

export const defaultDeps: Deps = {
  getAdminClient: buildAdminClient,
  timingSafeEqual: timingSafeEqualStr,
  getCronSecret: () => Deno.env.get("CRON_SECRET") ?? "",
  claimCleanupSessions: async (admin, workerId) => {
    const sql = getLocalDbClient();
    if (sql) {
      try {
        const rows = await sql`
          SELECT session_id, original_storage_path, display_storage_path,
                 status, cleanup_claim_token
          FROM claim_cleanup_sessions(${workerId}, '15 minutes'::interval)
        `;
        return { data: rows as unknown as CleanupSession[], error: null };
      } catch (e) {
        return { data: [], error: e };
      }
    }
    const { data, error } = await admin.rpc("claim_cleanup_sessions", {
      p_worker_id: workerId,
      p_claim_duration: "15 minutes",
    });
    return { data: (data as CleanupSession[]) ?? [], error };
  },
  markSessionCleaned: async (admin, sessionId, claimToken) => {
    const sql = getLocalDbClient();
    if (sql) {
      try {
        await sql`
          SELECT mark_session_cleaned(${sessionId}::uuid, ${claimToken}::uuid)
        `;
        return { error: null };
      } catch (e) {
        return { error: e };
      }
    }
    const { error } = await admin.rpc("mark_session_cleaned", {
      p_session_id: sessionId,
      p_cleanup_claim_token: claimToken,
    });
    return { error };
  },
  getSupersededMedia: async (admin) => {
    const sql = getLocalDbClient();
    if (sql) {
      try {
        const rows = await sql`
          SELECT media_object_id, re_encoded_storage_key
          FROM get_superseded_media_to_clean()
        `;
        return { data: rows as unknown as SupersededMedia[], error: null };
      } catch (e) {
        return { data: [], error: e };
      }
    }
    const { data, error } = await admin.rpc("get_superseded_media_to_clean");
    return { data: (data as SupersededMedia[]) ?? [], error };
  },
  markSupersededMediaCleaned: async (admin, mediaObjectId) => {
    const sql = getLocalDbClient();
    if (sql) {
      try {
        await sql`
          SELECT mark_superseded_media_cleaned(${mediaObjectId}::uuid)
        `;
        return { error: null };
      } catch (e) {
        return { error: e };
      }
    }
    const { error } = await admin.rpc("mark_superseded_media_cleaned", {
      p_media_object_id: mediaObjectId,
    });
    return { error };
  },
  getExpiryCleanupSessions: async (admin) => {
    const sql = getLocalDbClient();
    if (sql) {
      try {
        const rows = await sql`
          SELECT session_id, original_storage_path
          FROM get_complete_sessions_pending_expiry_cleanup()
        `;
        return { data: rows as unknown as ExpirySession[], error: null };
      } catch (e) {
        return { data: [], error: e };
      }
    }
    const { data, error } = await admin.rpc(
      "get_complete_sessions_pending_expiry_cleanup",
    );
    return { data: (data as ExpirySession[]) ?? [], error };
  },
  markOriginalPathCleaned: async (admin, sessionId) => {
    const sql = getLocalDbClient();
    if (sql) {
      try {
        await sql`
          SELECT mark_original_path_post_expiry_cleaned(${sessionId}::uuid)
        `;
        return { error: null };
      } catch (e) {
        return { error: e };
      }
    }
    const { error } = await admin.rpc(
      "mark_original_path_post_expiry_cleaned",
      { p_session_id: sessionId },
    );
    return { error };
  },
  deleteFromR2: defaultDeleteFromR2,
};

// ---------------------------------------------------------------------------
// Handler factory
// ---------------------------------------------------------------------------

export function makeHandler(
  deps: Deps = defaultDeps,
): (req: Request) => Promise<Response> {
  return async (req: Request): Promise<Response> => {
    const requestId = req.headers.get("X-Request-Id") ?? crypto.randomUUID();
    const t0 = performance.now();
    const fn = "upload-cleanup-worker";

    // ── Authentication (constant-time CRON_SECRET check) ─────────────────────
    // verify_jwt = false in config.toml: platform JWT gateway is bypassed so
    // pg_net requests (which carry no JWT) can reach this function.
    // Authentication is performed exclusively by the header check below.
    const incoming = req.headers.get("X-Forkensics-Cron-Secret") ?? "";
    const expected = deps.getCronSecret();

    if (!expected || !deps.timingSafeEqual(incoming, expected)) {
      safeLog({
        fn,
        status: 401,
        error_code: "FK_UNAUTHENTICATED",
        request_id: requestId,
        duration_ms: Math.round(performance.now() - t0),
      });
      return errorEnvelope("FK_UNAUTHENTICATED", "Unauthorized", 401);
    }

    // ── Only POST is accepted ────────────────────────────────────────────────
    if (req.method !== "POST") {
      return new Response("Method Not Allowed", {
        status: 405,
        headers: { Allow: "POST", "Cache-Control": "no-store" },
      });
    }

    const workerId = crypto.randomUUID();
    let admin: SupabaseClient;
    try {
      admin = deps.getAdminClient();
    } catch {
      safeLog({
        fn,
        status: 500,
        error_code: "FK_INTERNAL",
        outcome: "admin_client_failed",
        request_id: requestId,
        duration_ms: Math.round(performance.now() - t0),
      });
      return errorEnvelope("FK_INTERNAL", "Internal error", 500);
    }

    // ── Part 1 — Upload session cleanup ──────────────────────────────────────
    const { data: sessions, error: claimErr } = await deps.claimCleanupSessions(
      admin,
      workerId,
    );
    if (claimErr) {
      safeLog({
        fn,
        status: 500,
        error_code: "FK_INTERNAL",
        outcome: "claim_sessions_failed",
        request_id: requestId,
        duration_ms: Math.round(performance.now() - t0),
      });
    } else {
      for (const session of sessions) {
        let origOk = false;
        let dispOk = false;
        try {
          await deps.deleteFromR2(session.original_storage_path);
          origOk = true;
        } catch (err) {
          // NoSuchKey (absent) counts as success
          if (err instanceof Error && err.name === "NoSuchKey") {
            origOk = true;
          } else {
            // Inner-loop operational log — not a request-level safeLog
            console.log(
              JSON.stringify({
                fn,
                outcome: "part1_delete_original_failed",
                session_id: session.session_id,
                request_id: requestId,
              }),
            );
          }
        }
        try {
          await deps.deleteFromR2(session.display_storage_path);
          dispOk = true;
        } catch (err) {
          if (err instanceof Error && err.name === "NoSuchKey") {
            dispOk = true;
          } else {
            console.log(
              JSON.stringify({
                fn,
                outcome: "part1_delete_display_failed",
                session_id: session.session_id,
                request_id: requestId,
              }),
            );
          }
        }
        if (origOk && dispOk) {
          const { error: markErr } = await deps.markSessionCleaned(
            admin,
            session.session_id,
            session.cleanup_claim_token,
          );
          if (markErr) {
            console.log(
              JSON.stringify({
                fn,
                outcome: "part1_mark_cleaned_failed",
                session_id: session.session_id,
                request_id: requestId,
              }),
            );
          }
        }
      }
    }

    // ── Part 2 — Superseded media ────────────────────────────────────────────
    const { data: superseded, error: supErr } = await deps.getSupersededMedia(
      admin,
    );
    if (supErr) {
      console.log(
        JSON.stringify({
          fn,
          outcome: "part2_get_superseded_failed",
          request_id: requestId,
        }),
      );
    } else {
      for (const item of superseded) {
        try {
          await deps.deleteFromR2(item.re_encoded_storage_key);
        } catch (err) {
          if (err instanceof Error && err.name === "NoSuchKey") {
            // Absent counts as success — fall through to mark
          } else {
            console.log(
              JSON.stringify({
                fn,
                outcome: "part2_delete_superseded_failed",
                media_object_id: item.media_object_id,
                request_id: requestId,
              }),
            );
            continue;
          }
        }
        const { error: markErr } = await deps.markSupersededMediaCleaned(
          admin,
          item.media_object_id,
        );
        if (markErr) {
          console.log(
            JSON.stringify({
              fn,
              outcome: "part2_mark_superseded_cleaned_failed",
              media_object_id: item.media_object_id,
              request_id: requestId,
            }),
          );
        }
      }
    }

    // ── Part 3 — Post-expiry original-path cleanup ───────────────────────────
    const { data: expirySessions, error: expiryErr } = await deps
      .getExpiryCleanupSessions(admin);
    if (expiryErr) {
      console.log(
        JSON.stringify({
          fn,
          outcome: "part3_get_expiry_sessions_failed",
          request_id: requestId,
        }),
      );
    } else {
      for (const session of expirySessions) {
        let deleted = false;
        try {
          await deps.deleteFromR2(session.original_storage_path);
          deleted = true;
        } catch (err) {
          if (err instanceof Error && err.name === "NoSuchKey") {
            // Absent counts as success
            deleted = true;
          } else {
            console.log(
              JSON.stringify({
                fn,
                outcome: "part3_delete_failed",
                session_id: session.session_id,
                request_id: requestId,
              }),
            );
          }
        }
        if (deleted) {
          const { error: markErr } = await deps.markOriginalPathCleaned(
            admin,
            session.session_id,
          );
          if (markErr) {
            console.log(
              JSON.stringify({
                fn,
                outcome: "part3_mark_cleaned_failed",
                session_id: session.session_id,
                request_id: requestId,
              }),
            );
          }
        }
        // If not deleted: logged above; do NOT mark; retry on next run
      }
    }

    safeLog({
      fn,
      status: 200,
      outcome: "complete",
      request_id: requestId,
      duration_ms: Math.round(performance.now() - t0),
    });
    return new Response(JSON.stringify({ status: "ok" }), {
      status: 200,
      headers: {
        "Content-Type": "application/json",
        "Cache-Control": "no-store",
      },
    });
  };
}

// ---------------------------------------------------------------------------
// Entrypoint
// ---------------------------------------------------------------------------

if (import.meta.main) {
  Deno.serve(makeHandler());
}
