import type { SupabaseClient } from "npm:@supabase/supabase-js@2.112.3";
import { getLocalDbClient } from "./dbClient.ts";

export type ProfileCheckResult =
  | { status: "ok" }
  | {
    status: "forbidden";
    reason: "absent" | "inactive" | "incomplete" | "suspended";
  }
  | { status: "error" };

/**
 * Queries public.profiles for the given user.
 *
 * Columns checked: is_active, onboarding_complete, is_suspended (V3).
 * No auth_deleted_at on public.profiles; deletion-prepared accounts have is_active=false.
 *
 * When FK_DB_URL is set (local integration testing), uses a direct PostgreSQL
 * connection (port 54322) to bypass the REST API. The supabase-js REST client
 * hangs in the local edge runtime because the runtime intercepts outbound HTTP
 * to its own port. Direct SQL avoids this entirely.
 *
 * In production FK_DB_URL is absent and the REST API path is used unchanged.
 *
 * Returns:
 *   ok         — profile exists, is_active, onboarding_complete, not suspended
 *   forbidden  — profile absent, inactive, incomplete, or suspended
 *   error      — transport or unexpected DB error
 */
export async function checkActiveProfile(
  supabase: SupabaseClient,
  userId: string,
): Promise<ProfileCheckResult> {
  // Local dev: direct SQL bypasses the REST API that hangs in the edge runtime.
  const sql = getLocalDbClient();
  if (sql) {
    try {
      const rows = await sql`
        SELECT is_active, onboarding_complete, is_suspended
        FROM public.profiles
        WHERE id = ${userId}::uuid
      `;
      if (rows.length === 0) return { status: "forbidden", reason: "absent" };
      const row = rows[0] as {
        is_active: boolean;
        onboarding_complete: boolean;
        is_suspended: boolean;
      };
      if (!row.is_active) return { status: "forbidden", reason: "inactive" };
      if (!row.onboarding_complete) {
        return { status: "forbidden", reason: "incomplete" };
      }
      if (row.is_suspended) return { status: "forbidden", reason: "suspended" };
      return { status: "ok" };
    } catch {
      return { status: "error" };
    }
  }

  // Production: use REST API via supabase-js.
  try {
    const { data, error } = await supabase
      .from("profiles")
      .select("is_active, onboarding_complete, is_suspended")
      .eq("id", userId)
      .maybeSingle();

    if (error) return { status: "error" };
    if (!data) return { status: "forbidden", reason: "absent" };
    if (!data.is_active) return { status: "forbidden", reason: "inactive" };
    if (!data.onboarding_complete) {
      return { status: "forbidden", reason: "incomplete" };
    }
    if (data.is_suspended) return { status: "forbidden", reason: "suspended" };
    return { status: "ok" };
  } catch {
    return { status: "error" };
  }
}
