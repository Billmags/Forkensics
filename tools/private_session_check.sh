#!/usr/bin/env bash
# private_session_check.sh — assert upload_session state and hash match
# Usage: ./tools/private_session_check.sh <session_uuid> <expected_hash>
#
# Returns boolean hash comparison and permitted state fields.
# The actual upload_token_hash value is never printed.
set -euo pipefail

SESSION_ID="${1:?Usage: $0 <session_uuid> <expected_hash>}"
EXPECTED_HASH="${2:?Usage: $0 <session_uuid> <expected_hash>}"

DB_URL=$(supabase status -o env 2>/dev/null | grep '^DB_URL=' | cut -d= -f2- | tr -d "\"'")
[[ -z "$DB_URL" ]] && { echo "ERROR: DB_URL not found" >&2; exit 1; }

# psql named variables — no shell interpolation into SQL
psql "$DB_URL" --no-password -t -A \
  -v "sid=${SESSION_ID}" \
  -v "expected_hash=${EXPECTED_HASH}" \
  -c "SELECT
        (upload_token_hash = :'expected_hash') AS hash_match,
        status,
        storage_upload_expires_at,
        failed_reason
      FROM private.upload_sessions
      WHERE session_id = :'sid';"
