/**
 * Local-dev direct PostgreSQL client (FK_DB_URL gate).
 *
 * Returns a postgres.js sql() tag when FK_DB_URL is present in env;
 * returns null in production where FK_DB_URL is absent.
 *
 * Motivation: when supabase functions serve is used for local integration
 * testing, the edge runtime intercepts outbound HTTP requests to its own
 * port (SUPABASE_URL / 127.0.0.1:54321), routing them internally. REST API
 * calls (supabase-js .from() / .rpc()) therefore hang until the runtime's
 * internal requestTimeout fires (~7 s). Bypassing the REST API via a direct
 * TCP connection to PostgreSQL (port 54322) avoids this entirely.
 *
 * In production FK_DB_URL is absent — this module has no effect and all
 * database operations use the supabase-js REST API path unchanged.
 *
 * FK_DB_URL is set by integration-runner.sh to the local Supabase postgres
 * URL (from `supabase status` DB_URL). The value is written to both the
 * function server ENV_FILE and the deno test process env block.
 *
 * The connection is established lazily on first query and reused across
 * requests within the same edge-runtime process lifetime.
 */
import postgres from "npm:postgres@3";

export type LocalSql = ReturnType<typeof postgres>;

let _sql: LocalSql | null = null;

/**
 * Returns a postgres.js sql() tag when FK_DB_URL is set, otherwise null.
 * Idempotent — creates one connection and reuses it.
 */
export function getLocalDbClient(): LocalSql | null {
  const url = Deno.env.get("FK_DB_URL");
  if (!url) return null;
  if (!_sql) {
    _sql = postgres(url, {
      max: 1,
      idle_timeout: 60,
      connect_timeout: 5,
    });
  }
  return _sql;
}
