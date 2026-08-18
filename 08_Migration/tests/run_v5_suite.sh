#!/usr/bin/env bash
# run_v5_suite.sh — V5 acceptance test runner
# Usage: DB_URL=<url> bash 08_Migration/tests/run_v5_suite.sh
set -euo pipefail

DB_URL="${DB_URL:?DB_URL not set}"
PSQL_CMD=(psql "${DB_URL}" --no-password -v ON_ERROR_STOP=1)

echo "=== V5 Test Suite ==="
echo "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"

echo "--- Step 0: Bootstrap test_helpers (idempotent) ---"
"${PSQL_CMD[@]}" -f 08_Migration/tests/test_helpers_bootstrap.sql

echo "--- Step 1: Preflight tests (pre-apply) ---"
"${PSQL_CMD[@]}" -f 08_Migration/tests/V5_preflight_tests.sql

echo "--- Step 2: Apply V5 migration ---"
"${PSQL_CMD[@]}" -f 08_Migration/V5__r2_storage_paths.sql

echo "--- Step 3: Post-apply tests ---"
"${PSQL_CMD[@]}" -f 08_Migration/tests/V5_postapply_tests.sql

echo "=== V5 Test Suite PASS ==="
echo "NOTE: V5 migration and test_helpers schema remain installed."
echo "      Test fixtures were rolled back by each test file."
