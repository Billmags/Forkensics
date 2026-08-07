#!/usr/bin/env bash
# =============================================================================
# run_tests_full.sh
# Forkensics — Full test-run wrapper
#
# Captures the complete sequence for GPT/governance review:
#   1. supabase db reset  (wipes the local database)
#   2. Migration applied  (V1__initial_schema.sql via supabase db reset)
#   3. Acceptance tests   (V1_acceptance_tests.sql)
#   4. Concurrency script (test_alias_concurrency.sh)
#   5. Exit codes for all four steps
#
# Usage:
#   chmod +x 08_Migration/tests/run_tests_full.sh
#   ./08_Migration/tests/run_tests_full.sh 2>&1 | tee full_test_$(date +%Y%m%d_%H%M%S).log
#
# Requirements:
#   - Supabase CLI in PATH, project started: supabase start
#   - psql in PATH
# =============================================================================

set -euo pipefail

DB_URL="${SUPABASE_DB_URL:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MIGRATION="$SCRIPT_DIR/../V1__initial_schema.sql"
ACCEPTANCE="$SCRIPT_DIR/V1_acceptance_tests.sql"
CONCURRENCY="$SCRIPT_DIR/test_alias_concurrency.sh"

echo ""
echo "============================================================="
echo "Forkensics — Full Test Run"
echo "Date: $(date)"
echo "============================================================="

# -------------------------------------------------------------
# Step 1: Reset database (wipes all schemas; does NOT auto-apply
# our migration because it lives outside supabase/migrations/)
# -------------------------------------------------------------
echo ""
echo "--- Step 1: supabase db reset ---"
RESET_START=$(date +%s)
supabase db reset --local
RESET_EXIT=$?
RESET_END=$(date +%s)
echo "  Reset exit code: $RESET_EXIT  ($(( RESET_END - RESET_START ))s)"

if [[ $RESET_EXIT -ne 0 ]]; then
  echo "FATAL: supabase db reset failed. Aborting."
  exit 1
fi

# -------------------------------------------------------------
# Step 2: Apply migration + report hash for traceability
# -------------------------------------------------------------
echo ""
echo "--- Step 2: Apply V1__initial_schema.sql ---"
MIGRATION_HASH=$(sha256sum "$MIGRATION" | awk '{print $1}')
echo "  V1__initial_schema.sql SHA-256: $MIGRATION_HASH"

MIGRATE_START=$(date +%s)
psql "$DB_URL" --set ON_ERROR_STOP=on -f "$MIGRATION"
MIGRATE_EXIT=$?
MIGRATE_END=$(date +%s)
echo "  Migration exit code: $MIGRATE_EXIT  ($(( MIGRATE_END - MIGRATE_START ))s)"

if [[ $MIGRATE_EXIT -ne 0 ]]; then
  echo "FATAL: Migration failed. Aborting."
  exit 1
fi

# -------------------------------------------------------------
# Step 3: Acceptance tests
# -------------------------------------------------------------
echo ""
echo "--- Step 3: Acceptance tests ---"
ACCEPT_START=$(date +%s)
psql "$DB_URL" \
  --set ON_ERROR_STOP=on \
  -f "$ACCEPTANCE"
ACCEPT_EXIT=$?
ACCEPT_END=$(date +%s)
echo ""
echo "  Acceptance exit code: $ACCEPT_EXIT  ($(( ACCEPT_END - ACCEPT_START ))s)"

# -------------------------------------------------------------
# Step 4: Concurrency tests
# -------------------------------------------------------------
echo ""
echo "--- Step 4: Concurrency tests ---"
CONC_START=$(date +%s)
set +e  # concurrency script manages its own exit code
"$CONCURRENCY"
CONC_EXIT=$?
set -e
CONC_END=$(date +%s)
echo "  Concurrency exit code: $CONC_EXIT  ($(( CONC_END - CONC_START ))s)"

# -------------------------------------------------------------
# Summary
# -------------------------------------------------------------
echo ""
echo "============================================================="
echo "SUMMARY"
echo "  supabase db reset:  exit $RESET_EXIT"
echo "  Migration apply:    exit $MIGRATE_EXIT"
echo "  Acceptance tests:   exit $ACCEPT_EXIT"
echo "  Concurrency tests:  exit $CONC_EXIT"
echo "  Migration SHA-256:  $MIGRATION_HASH"
echo "  Tests SHA-256:      $(sha256sum "$ACCEPTANCE" | awk '{print $1}')"
echo "  Concurrency SHA-256:$(sha256sum "$CONCURRENCY" | awk '{print $1}')"
echo "============================================================="

OVERALL=0
[[ $RESET_EXIT   -ne 0 ]] && OVERALL=1
[[ $MIGRATE_EXIT -ne 0 ]] && OVERALL=1
[[ $ACCEPT_EXIT  -ne 0 ]] && OVERALL=1
[[ $CONC_EXIT    -ne 0 ]] && OVERALL=1

if [[ $OVERALL -eq 0 ]]; then
  echo "ALL STEPS PASSED"
else
  echo "ONE OR MORE STEPS FAILED — see above"
fi
echo "============================================================="
echo ""

exit $OVERALL
