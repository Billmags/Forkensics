#!/usr/bin/env bash
# run-chain-test-v5v6.sh — Proves the 000000–000006 migration chain on a clean
# local Supabase database.
#
# Prerequisites:
#   - Docker is running
#   - supabase start has been executed (local Supabase stack is up)
#   - psql is available (install via: brew install postgresql)
#   - Run from repo root: bash tools/run-chain-test-v5v6.sh
#
# This script resets the local database and re-applies every migration from
# scratch. All prior local data is lost. Do not run against a database you
# intend to keep.
set -euo pipefail
{ set +x; } 2>/dev/null

LOG="08_Migration/tests/chain-test-v5v6-$(date +%Y%m%d-%H%M%S).log"
mkdir -p "08_Migration/tests"

log()  { echo "$*" | tee -a "${LOG}"; }
pass() { log "  PASS: $*"; }
fail() { log "  FAIL: $*"; exit 1; }

LOCAL_DB_URL="postgresql://postgres:postgres@localhost:54322/postgres"

log "=== Migration Chain Test 000000–000006 — $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
log ""

# ── Preflight ─────────────────────────────────────────────────────────────────
log "--- Preflight ---"
if ! psql "${LOCAL_DB_URL}" -c "SELECT 1" >/dev/null 2>&1; then
  fail "Cannot connect to local Supabase DB (${LOCAL_DB_URL}). Is 'supabase start' running?"
fi
log "DB connection: OK"

command -v supabase >/dev/null 2>&1 || fail "'supabase' CLI not found in PATH"
log "supabase CLI: OK"

# ── Reset ─────────────────────────────────────────────────────────────────────
log ""
log "--- supabase db reset (applies all migrations from scratch) ---"
supabase db reset --local 2>&1 | tee -a "${LOG}"
log "Reset complete."

# ── Migration list ─────────────────────────────────────────────────────────────
log ""
log "--- Migration list (post-reset) ---"
supabase migration list --local 2>&1 | tee -a "${LOG}"

# ── Helper: psql query → first row, never fails under set -e ──────────────────
q() {
  local _result
  # || true ensures set -e never triggers on psql or head failure.
  _result=$(psql "${LOCAL_DB_URL}" -t -A -c "$1" 2>/dev/null | head -1) || true
  echo "${_result}"
}

# ── Diagnostic: show full forkensics_executor membership state ────────────────
log ""
log "--- Diagnostic: pg_auth_members for forkensics_executor → postgres ---"
psql "${LOCAL_DB_URL}" -t -c "
  SELECT r1.rolname   AS role,
         r2.rolname   AS member,
         COALESCE(r3.rolname,'(none)') AS grantor,
         m.admin_option,
         m.inherit_option,
         m.set_option
  FROM pg_auth_members m
  JOIN pg_roles r1 ON r1.oid = m.roleid
  JOIN pg_roles r2 ON r2.oid = m.member
  LEFT JOIN pg_roles r3 ON r3.oid = m.grantor
  WHERE r1.rolname = 'forkensics_executor'
    AND r2.rolname = 'postgres';
" 2>/dev/null | tee -a "${LOG}" || true
log "(empty = no entries)"

log ""
log "--- Diagnostic: public schema ACL for forkensics_executor ---"
psql "${LOCAL_DB_URL}" -t -c "
  SELECT r.rolname   AS grantee,
         COALESCE(r2.rolname,'(none)') AS grantor,
         acl.privilege_type
  FROM (
    SELECT (aclexplode(nspacl)).grantee       AS grantee_oid,
           (aclexplode(nspacl)).grantor        AS grantor_oid,
           (aclexplode(nspacl)).privilege_type AS privilege_type
    FROM pg_namespace WHERE nspname = 'public'
  ) acl
  JOIN pg_roles r  ON r.oid  = acl.grantee_oid
  LEFT JOIN pg_roles r2 ON r2.oid = acl.grantor_oid
  WHERE r.rolname = 'forkensics_executor';
" 2>/dev/null | tee -a "${LOG}" || true
log "(empty = no entries)"

# ── Verification queries ───────────────────────────────────────────────────────
log ""
log "--- Verification ---"

# V1: reserve_upload_session owned by forkensics_executor
FUNC_OWNER=$(q "
  SELECT r.rolname FROM pg_proc p
  JOIN pg_roles r ON r.oid = p.proowner
  WHERE p.proname = 'reserve_upload_session'
    AND p.pronamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public');
")
if [[ "${FUNC_OWNER}" == "forkensics_executor" ]]; then
  pass "reserve_upload_session owned by forkensics_executor"
else
  fail "reserve_upload_session owner='${FUNC_OWNER}' (expected forkensics_executor)"
fi

# V2: postgres has no postgres-GRANTED forkensics_executor membership.
# The Supabase local stack may create a supabase_admin-granted entry (set_option=f)
# as a local initialization artifact — that is not a migration concern.
# We verify only that our migration grant/revoke cycles leave no postgres-granted entry.
POSTGRES_GRANTED=$(q "
  SELECT COUNT(*) FROM pg_auth_members
  WHERE roleid  = (SELECT oid FROM pg_roles WHERE rolname = 'forkensics_executor')
    AND member  = (SELECT oid FROM pg_roles WHERE rolname = 'postgres')
    AND grantor = (SELECT oid FROM pg_roles WHERE rolname = 'postgres');
")
if [[ "${POSTGRES_GRANTED}" == "0" ]]; then
  pass "no postgres-granted forkensics_executor membership (migration cycles clean)"
else
  fail "postgres-granted forkensics_executor membership still exists (count=${POSTGRES_GRANTED})"
fi

# V3: forkensics_executor does NOT have CREATE on public schema.
# Queries pg_namespace ACL directly (more reliable than information_schema in
# Supabase local environment).
CREATE_ON_PUBLIC=$(q "
  SELECT COUNT(*)
  FROM (
    SELECT (aclexplode(nspacl)).grantee       AS grantee_oid,
           (aclexplode(nspacl)).privilege_type AS pt
    FROM pg_namespace WHERE nspname = 'public'
  ) acl
  WHERE acl.grantee_oid = (SELECT oid FROM pg_roles WHERE rolname = 'forkensics_executor')
    AND acl.pt = 'CREATE';
")
if [[ "${CREATE_ON_PUBLIC}" == "0" ]]; then
  pass "forkensics_executor has no CREATE on public schema"
else
  fail "forkensics_executor still has CREATE on public schema (count=${CREATE_ON_PUBLIC})"
fi

# V4: service_role does NOT have table-level SELECT on profiles.
# Uses pg_class + pg_acl directly instead of information_schema.
TABLE_SELECT=$(q "
  SELECT COUNT(*)
  FROM (
    SELECT (aclexplode(relacl)).grantee       AS grantee_oid,
           (aclexplode(relacl)).privilege_type AS pt
    FROM pg_class
    WHERE relname = 'profiles'
      AND relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public')
      AND relkind = 'r'
  ) acl
  WHERE acl.grantee_oid = (SELECT oid FROM pg_roles WHERE rolname = 'service_role')
    AND acl.pt = 'SELECT';
")
if [[ "${TABLE_SELECT}" == "0" ]]; then
  pass "service_role has no table-level SELECT on profiles"
else
  fail "service_role has table-level SELECT on profiles (count=${TABLE_SELECT})"
fi

# V5: service_role HAS column-level SELECT on exactly 4 profiles columns.
COL_SELECT=$(q "
  SELECT COUNT(*)
  FROM pg_attribute a
  JOIN pg_class c      ON c.oid  = a.attrelid
  JOIN pg_namespace ns ON ns.oid = c.relnamespace
  WHERE c.relname  = 'profiles'
    AND ns.nspname = 'public'
    AND a.attname  IN ('id', 'is_active', 'onboarding_complete', 'is_suspended')
    AND (
      SELECT COUNT(*)
      FROM (
        SELECT (aclexplode(a.attacl)).grantee       AS grantee_oid,
               (aclexplode(a.attacl)).privilege_type AS pt
      ) col_acl
      WHERE col_acl.grantee_oid = (SELECT oid FROM pg_roles WHERE rolname = 'service_role')
        AND col_acl.pt = 'SELECT'
    ) = 1;
")
if [[ "${COL_SELECT}" == "4" ]]; then
  pass "service_role has column-level SELECT on all 4 required profiles columns"
else
  fail "service_role column-level SELECT count=${COL_SELECT} (expected 4)"
fi

# V6: reserve_upload_session function body uses flat originals/ path format.
FUNC_BODY_CHECK=$(q "
  SELECT CASE
    WHEN prosrc LIKE '%originals/%' AND prosrc NOT LIKE '%cases/%' THEN 'PASS'
    ELSE 'FAIL'
  END
  FROM pg_proc
  WHERE proname = 'reserve_upload_session'
    AND pronamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public');
")
if [[ "${FUNC_BODY_CHECK}" == "PASS" ]]; then
  pass "reserve_upload_session uses flat originals/ path format"
else
  fail "reserve_upload_session body check: expected originals/ format, got FAIL"
fi

log ""
log "=== RESULT: PASS ==="
log "Log: ${LOG}"
shasum -a 256 "${LOG}"
