#!/usr/bin/env bash
# V4 Migration Acceptance Suite — Full Run  (Rev 4)
# ---------------------------------------------------------------------------
# Execution order:
#   Step 0  — SHA-256 verify V4 source file
#             Locate V4 in supabase/migrations by SHA-256 comparison (not glob);
#             verify the deployed copy's hash matches the canonical source;
#             verify exactly 4 migration version strings in supabase_migrations.
#   Step 1  — REQ-6 staged pre-test: apply V1→V3, insert sentinel 'active'
#             challenge (WITH ready media), apply V4 via psql,
#             assert sentinel became 'launched'
#   Step 2  — supabase db reset (V1+V2+V3+V4 full clean reset)
#   Step 3  — Verify all four migration versions are recorded (exact strings)
#   Step 4  — V4_acceptance_tests.sql (REQ-1,2,3,4,5 + Groups 1–20)
#   Step 4b — V4_V2_regression.sql (V2 behavioral groups 1–17 ported to V4 schema)
#             All 17 V2 behavioral groups verified against the live V4 database.
#             Public.challenges→cases, challenge_id→case_id, triggers and
#             function names updated; ready→launched transition tested.
#   Step 5  — V4_concurrency_harness.sh (REQ-7: TV4.1–TV4.9)
#
# Prerequisites:
#   • V4__case_investigation_schema.sql must be copied (with timestamp prefix)
#     into supabase/migrations/ before running this script.
#   • PGPASSWORD obtained at runtime — never stored in .env.dev or .env.prod.
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MIGRATION_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_ROOT="$(cd "$MIGRATION_DIR/.." && pwd)"
SUPABASE_MIG_DIR="$PROJECT_ROOT/supabase/migrations"
V4_SOURCE="$MIGRATION_DIR/V4__case_investigation_schema.sql"
LOG_FILE="$SCRIPT_DIR/v4_run_$(date +%Y%m%d_%H%M%S).log"
CONNSTR="${FORKENSICS_TEST_DB_URL:-postgresql://postgres@localhost:54322/postgres}"

EXPECTED_SHA="0eb78c66878df50f22278fb36f2b089d3f2b81ded2f550a945e9d0dd55dd0f66"

# Exact version strings for V1, V2, V3 migrations (filename timestamp prefixes)
V1_VERSION="20260807000000"
V2_VERSION="20260807000001"
V3_VERSION="20260807000002"

if [[ -z "${PGPASSWORD:-}" ]]; then
  read -r -s -p "Local Supabase DB password: " PGPASSWORD
  printf '\n'
  export PGPASSWORD
fi

trap 'unset PGPASSWORD' EXIT

PSQL="psql $CONNSTR -v ON_ERROR_STOP=1"

exec > >(tee -a "$LOG_FILE") 2>&1

echo "======================================================"
echo " V4 Migration Acceptance Suite"
echo " $(date)"
echo " Log: $LOG_FILE"
echo "======================================================"
echo ""

# ------------------------------------------------------------------ Step 0
echo "--- Step 0: SHA-256 verify V4 source and deployed copy ---"
if [[ ! -f "$V4_SOURCE" ]]; then
  echo "FAIL: V4 source not found at $V4_SOURCE"
  exit 1
fi

ACTUAL_SHA="$(sha256sum "$V4_SOURCE" | awk '{print $1}')"
if [[ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]]; then
  echo "FAIL: V4 source SHA-256 mismatch."
  echo "  Expected: $EXPECTED_SHA"
  echo "  Actual:   $ACTUAL_SHA"
  echo "The R7 patcher may not have been applied or the file was modified. Do not proceed."
  exit 1
fi
echo "✓ V4 source SHA-256 verified: $EXPECTED_SHA"

# Locate deployed V4 file by SHA-256 comparison (not by glob/name pattern).
# This guarantees we find the exact canonical file, not a stale copy with a
# similar name.
V4_MIGFILE=""
for f in "$SUPABASE_MIG_DIR"/*.sql; do
  if [[ -f "$f" ]] && [[ "$(sha256sum "$f" | awk '{print $1}')" == "$EXPECTED_SHA" ]]; then
    V4_MIGFILE="$f"
    break
  fi
done

if [[ -z "$V4_MIGFILE" ]]; then
  echo "FAIL: No file in $SUPABASE_MIG_DIR has SHA-256 $EXPECTED_SHA"
  echo "Copy $V4_SOURCE to $SUPABASE_MIG_DIR with a timestamp prefix, e.g.:"
  echo "  cp $V4_SOURCE $SUPABASE_MIG_DIR/20260807000003_v4_case_investigation_schema.sql"
  exit 1
fi

# Extract the version string (first 14 characters = timestamp) from filename
V4_VERSION="$(basename "$V4_MIGFILE" | cut -c1-14)"
echo "✓ V4 deployed and hash-verified in supabase/migrations: $(basename "$V4_MIGFILE")"
echo "  Deployed copy SHA-256: $EXPECTED_SHA (matches source)"
echo "  V4 version string: $V4_VERSION"
echo ""

# ------------------------------------------------------------------ Step 1
# REQ-6: staged V3→V4 state-conversion test.
# Temporarily renames the V4 file in supabase/migrations so that 'supabase db reset'
# applies only V1+V2+V3, inserts a sentinel 'active' challenge (WITH ready media),
# applies V4 directly via psql, and asserts the sentinel became 'launched'.
echo "--- Step 1: REQ-6 staged pre-test (V3→V4 active→launched conversion) ---"

V4_MIGFILE_BAK="${V4_MIGFILE}.bak_$$"
mv "$V4_MIGFILE" "$V4_MIGFILE_BAK"
# Ensure V4 is restored on any exit, including errors
trap 'unset PGPASSWORD; [[ -f "${V4_MIGFILE_BAK:-}" ]] && mv "$V4_MIGFILE_BAK" "$V4_MIGFILE" 2>/dev/null || true' EXIT

cd "$PROJECT_ROOT"
supabase db reset --local
echo "  V3-only reset complete."

# Insert sentinel in V3 state (state='active').
#
# B1 fix (Rev 3): The sentinel challenge MUST have a linked media_objects row
# with status='ready' and a corresponding media_storage_keys row. Without these,
# the V3 trigger that guards challenge state transitions will reject the
# advancement to 'active'. The media UUID (f3000000-...) and the challenge UUID
# (f2000000-...) are stable across runs so that the post-V4 lookup is reliable.
$PSQL -q -v ON_ERROR_STOP=1 <<'SQL'
-- ---- REQ-6 sentinel fixture (V3 schema, minimal prerequisites) ----
GRANT forkensics_executor TO postgres;

INSERT INTO public.profiles (id, display_name, onboarding_complete)
VALUES ('f0000000-0000-0000-0000-000000000001', 'REQ6 Poster', true)
ON CONFLICT DO NOTHING;

INSERT INTO private.profile_suspensions (profile_id, is_suspended)
VALUES ('f0000000-0000-0000-0000-000000000001', false)
ON CONFLICT DO NOTHING;

INSERT INTO public.groups (id, name, created_by)
VALUES ('f1000000-0000-0000-0000-000000000001', 'REQ6 Group',
        'f0000000-0000-0000-0000-000000000001')
ON CONFLICT DO NOTHING;

INSERT INTO public.group_members (group_id, player_id, role)
VALUES ('f1000000-0000-0000-0000-000000000001',
        'f0000000-0000-0000-0000-000000000001', 'owner')
ON CONFLICT DO NOTHING;

-- ---- Ready media for the sentinel challenge (required by V3 state trigger) ----
INSERT INTO public.media_objects (id, uploader_id, mime_type, status, re_encoded_at)
VALUES ('f3000000-0000-0000-0000-000000000001',
        'f0000000-0000-0000-0000-000000000001',
        'image/webp', 'ready', now())
ON CONFLICT DO NOTHING;

INSERT INTO private.media_storage_keys
  (media_object_id, storage_key, sha256_hash, re_encoded_storage_key)
VALUES ('f3000000-0000-0000-0000-000000000001',
        'uploads/req6-sentinel/orig.jpg',
        repeat('f', 64),
        'cases/req6-sentinel/display.webp')
ON CONFLICT DO NOTHING;

-- Set JWT so challenge_create_fields trigger sets poster_id from auth_uid()
SELECT set_config('request.jwt.claims',
  '{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}', false);

-- Insert challenge WITH media_object_id (required by state trigger on V3)
INSERT INTO public.challenges (id, group_id, media_object_id)
VALUES ('f2000000-0000-0000-0000-000000000001',
        'f1000000-0000-0000-0000-000000000001',
        'f3000000-0000-0000-0000-000000000001');
-- trigger: state='draft', poster_id=f0000000..., rules_version_id set by trigger

-- Advance to 'active' as forkensics_executor (bypasses protect-fields trigger)
SET ROLE forkensics_executor;
UPDATE public.challenges
SET state       = 'active',
    posted_at   = now() - interval '1 hour',
    deadline_at = now() + interval '2 hours'
WHERE id = 'f2000000-0000-0000-0000-000000000001';
RESET ROLE;

-- Verify: sentinel must be 'active' before V4 is applied
DO $$
DECLARE v_state text;
BEGIN
  SELECT state INTO v_state
  FROM public.challenges WHERE id = 'f2000000-0000-0000-0000-000000000001';
  IF v_state != 'active' THEN
    RAISE EXCEPTION 'REQ-6 PRE-CHECK: sentinel not active (got %)', v_state;
  END IF;
END $$;

REVOKE forkensics_executor FROM postgres;
SQL
echo "  Sentinel 'active' challenge inserted (with ready media)."

# Apply V4 directly via psql
$PSQL -q -v ON_ERROR_STOP=1 -f "$V4_SOURCE"
echo "  V4 applied via psql."

# Verify sentinel converted to 'launched' (V4 Phase 13A: UPDATE cases SET state='launched' WHERE state='active')
REQ6_STATE="$($PSQL -tAc "SELECT state FROM public.cases WHERE id = 'f2000000-0000-0000-0000-000000000001'")"
if [[ "$REQ6_STATE" == "launched" ]]; then
  echo "✓ REQ-6 PASS: sentinel active challenge converted to launched."
else
  echo "FAIL REQ-6: expected launched, got '${REQ6_STATE:-<no row>}'."
  mv "$V4_MIGFILE_BAK" "$V4_MIGFILE"
  exit 1
fi

# Restore V4 to migrations directory
mv "$V4_MIGFILE_BAK" "$V4_MIGFILE"
# Re-register the trap without the bak-restore logic
trap 'unset PGPASSWORD' EXIT
echo ""

# ------------------------------------------------------------------ Step 2
echo "--- Step 2: supabase db reset (V1+V2+V3+V4 full reset) ---"
cd "$PROJECT_ROOT"
supabase db reset --local
echo "✓ Full reset complete — all four migrations applied."
echo ""

# ------------------------------------------------------------------ Step 3
echo "--- Step 3: Verify exact migration versions ---"
$PSQL -c "SELECT version FROM supabase_migrations.schema_migrations ORDER BY 1;"

# B2 fix (Rev 3): verify exact 4 version strings, not just a count≥4.
# V1, V2, V3 version strings are fixed; V4 version is derived from the deployed filename.
EXPECTED_VERSIONS=("$V1_VERSION" "$V2_VERSION" "$V3_VERSION" "$V4_VERSION")
for v in "${EXPECTED_VERSIONS[@]}"; do
  COUNT=$($PSQL -tAc "SELECT COUNT(*) FROM supabase_migrations.schema_migrations WHERE version = '$v'")
  if [[ "$COUNT" -ne 1 ]]; then
    echo "FAIL: migration version '$v' not found in supabase_migrations.schema_migrations (count=$COUNT)."
    exit 1
  fi
  echo "  ✓ version '$v' present"
done
echo "✓ All 4 expected migration versions verified (exact strings)."

# B5 fix (Rev 4): reject any extra migrations — total must be exactly 4.
TOTAL_MIGRATIONS=$($PSQL -tAc "SELECT COUNT(*) FROM supabase_migrations.schema_migrations")
if [[ "$TOTAL_MIGRATIONS" -ne 4 ]]; then
  echo "FAIL: Expected exactly 4 migration versions, found $TOTAL_MIGRATIONS (extra migrations detected)."
  echo "Inspect: SELECT version FROM supabase_migrations.schema_migrations ORDER BY 1;"
  exit 1
fi
echo "✓ Exactly 4 migration versions total (no extras)."

# Confirm V4 content is live by checking a V4-exclusive object
$PSQL -q -v ON_ERROR_STOP=1 <<'SQL'
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema='public' AND table_name='investigations'
  ) THEN
    RAISE EXCEPTION 'MIGRATION CHECK: public.investigations missing — V4 was not applied';
  END IF;
  RAISE NOTICE 'Migration version check: public.investigations present (V4 confirmed).';
END $$;
SQL
echo "✓ V4 schema objects confirmed."
echo ""

# ------------------------------------------------------------------ Step 4
echo "--- Step 4: V4_acceptance_tests.sql (REQ-1,2,3,4,5 + Groups 1-20) ---"
$PSQL -q -v ON_ERROR_STOP=1 -f "$SCRIPT_DIR/V4_acceptance_tests.sql"
echo "✓ V4 acceptance tests PASSED."
echo ""

# ------------------------------------------------------------------ Step 4b
echo "--- Step 4b: V4_V2_regression.sql (V2 behavioral groups 1-17 ported to V4 schema) ---"
$PSQL -q -v ON_ERROR_STOP=1 -f "$SCRIPT_DIR/V4_V2_regression.sql"
echo "✓ V4_V2_regression tests PASSED."
echo ""

# ------------------------------------------------------------------ Step 5
echo "--- Step 5: V4_concurrency_harness.sh (REQ-7: TV4.1-TV4.9) ---"
bash "$SCRIPT_DIR/V4_concurrency_harness.sh" "$CONNSTR"
echo "✓ V4 concurrency harness PASSED."
echo ""

echo "======================================================"
echo " ALL STEPS PASSED — V4 migration suite complete."
echo " $(date)"
echo " Evidence log: $LOG_FILE"
echo "======================================================"
