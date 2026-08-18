import { createSupabaseContext } from "npm:@supabase/server@1.4.1";
import type { SupabaseEnv } from "npm:@supabase/server@1.4.1";
import type { SupabaseClient } from "npm:@supabase/supabase-js@2.112.3";

export interface AuthContext {
  userClaims: { id: string };
  supabase: SupabaseClient;
  supabaseAdmin: SupabaseClient;
}

export type AuthResult =
  | { ok: true; ctx: AuthContext; error: null }
  | { ok: false; ctx: null; error: Response };

function makeUnauthResponse(): Response {
  return new Response(
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
  );
}

/**
 * Builds @supabase/server env overrides required for local development.
 *
 * @supabase/server@1.4.1 reads SUPABASE_JWKS / SUPABASE_JWKS_URL,
 * SUPABASE_PUBLISHABLE_KEY, and SUPABASE_SECRET_KEY. The local Supabase edge
 * runtime injects SUPABASE_ANON_KEY and SUPABASE_SERVICE_ROLE_KEY instead.
 *
 * FK_JWKS_JSON: a local-dev-only env var injected by integration-runner.sh.
 * It contains an inline JWK Set (base64url-encoded shared HS256 secret) used
 * for JWT verification. It is never committed; deleted with the runner after use.
 *
 * In the hosted environment none of these fallback vars are set, so all
 * conditions are false and the function returns undefined (no overrides).
 */
function buildEnvOverride(): Partial<SupabaseEnv> | undefined {
  const overrides: Partial<SupabaseEnv> = {};

  // JWKS: if FK_JWKS_JSON is present, parse it and use as inline JWKS override.
  // This takes precedence over SUPABASE_JWKS* which resolveJwks() would read.
  const fkJwksJson = Deno.env.get("FK_JWKS_JSON");
  if (fkJwksJson) {
    try {
      // deno-lint-ignore no-explicit-any
      overrides.jwks = JSON.parse(fkJwksJson) as any;
    } catch {
      // Malformed — omit jwks; resolveJwks() will try SUPABASE_JWKS* instead.
    }
  }

  // Secret key: bridge old SUPABASE_SERVICE_ROLE_KEY → new secretKeys format.
  // Only applied when the new-naming vars are absent (never overrides production).
  if (
    !Deno.env.get("SUPABASE_SECRET_KEY") &&
    !Deno.env.get("SUPABASE_SECRET_KEYS")
  ) {
    const srk = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (srk) overrides.secretKeys = { default: srk };
  }

  // Publishable key: bridge old SUPABASE_ANON_KEY → new publishableKeys format.
  if (
    !Deno.env.get("SUPABASE_PUBLISHABLE_KEY") &&
    !Deno.env.get("SUPABASE_PUBLISHABLE_KEYS")
  ) {
    const ak = Deno.env.get("SUPABASE_ANON_KEY");
    if (ak) overrides.publishableKeys = { default: ak };
  }

  return Object.keys(overrides).length > 0 ? overrides : undefined;
}

/**
 * Wraps createSupabaseContext(req, { auth: 'user' }).
 *
 * Hosted env: platform injects SUPABASE_JWKS, SUPABASE_PUBLISHABLE_KEY,
 * SUPABASE_SECRET_KEY directly — buildEnvOverride() returns undefined.
 * Local dev: buildEnvOverride() supplies inline JWKS + key bridging so the
 * local edge runtime's SUPABASE_ANON_KEY / SUPABASE_SERVICE_ROLE_KEY are used.
 *
 * On any authentication failure, returns a sanitized 401 Response that includes
 * Cache-Control: no-store. The handler returns this Response directly; it never
 * needs to add the header itself.
 *
 * Never throws. Never decodes JWT manually.
 */
export async function getAuthContext(req: Request): Promise<AuthResult> {
  try {
    const result = await createSupabaseContext(req, {
      auth: "user",
      env: buildEnvOverride(),
    });
    if (result.error) {
      return { ok: false, ctx: null, error: makeUnauthResponse() };
    }
    const ctx = result.data;
    const userId = ctx.userClaims?.id as string | undefined;
    if (!userId) return { ok: false, ctx: null, error: makeUnauthResponse() };
    return {
      ok: true,
      ctx: {
        userClaims: { id: userId },
        supabase: ctx.supabase as SupabaseClient,
        supabaseAdmin: ctx.supabaseAdmin as SupabaseClient,
      },
      error: null,
    };
  } catch {
    return { ok: false, ctx: null, error: makeUnauthResponse() };
  }
}
