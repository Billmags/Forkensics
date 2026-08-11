#!/usr/bin/env bash
# V3 Migration Acceptance Suite — Full Run
# Executes: supabase db reset → V3 acceptance tests → T5 harness → T7 harness
# Stop-on-failure: exits immediately on any non-zero return code.
# Output is tee'd to a timestamped log file in this directory.
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LOG_FILE="$SCRIPT_DIR/v3_run_$(date +%Y%m%d_%H%M%S).log"
CONNSTR="${FORKENSICS_TEST_DB_URL:-postgresql://postgres@localhost:54322/postgres}"

if [[ -z "${PGPASSWORD:-}" ]]; then
  read -r -s -p "Local Supabase DB password: " PGPASSWORD
  printf '\n'
  export PGPASSWORD
fi

trap 'unset PGPASSWORD' EXIT

PSQL="psql $CONNSTR -v ON_ERROR_STOP=1"

# Redirect stdout+stderr to both terminal and log file from here on
exec > >(tee -a "$LOG_FILE") 2>&1

echo "======================================================"
echo " V3 Migration Acceptance Suite"
echo " $(date)"
echo " Log: $LOG_FILE"
echo "======================================================"
echo ""

# ------------------------------------------------------------------ Step 1
echo "--- Step 1: supabase db reset (applies V1 + V2 + V3) ---"
cd "$PROJECT_ROOT"
supabase db reset --local
echo "✓ Reset complete — all migrations applied."
echo ""

# ------------------------------------------------------------------ Step 2
echo "--- Step 2: Verify migration versions ---"
$PSQL -c "SELECT version FROM supabase_migrations.schema_migrations ORDER BY 1;"
echo ""

# ------------------------------------------------------------------ Step 3
echo "--- Step 3: V3_acceptance_tests.sql ---"
$PSQL -q -v ON_ERROR_STOP=1 -f "$SCRIPT_DIR/V3_acceptance_tests.sql"
echo "✓ V3 acceptance tests PASSED."
echo ""

# ------------------------------------------------------------------ Step 4
echo "--- Step 4: T5_lock_order_harness.sh ---"
bash "$SCRIPT_DIR/T5_lock_order_harness.sh" "$CONNSTR"
echo "✓ T5 harness PASSED."
echo ""

# ------------------------------------------------------------------ Step 5
echo "--- Step 5: T7_concurrency_harness.sh ---"
bash "$SCRIPT_DIR/T7_concurrency_harness.sh" "$CONNSTR"
echo "✓ T7 harness PASSED."
echo ""

echo "======================================================"
echo " ALL STEPS PASSED — V3 migration suite complete."
echo " $(date)"
echo " Evidence log: $LOG_FILE"
echo "======================================================"
