#!/usr/bin/env bash
# deploy-upload-authorize-stub.sh
# Atomically swaps the 503 stub into supabase/functions/upload-authorize/,
# deploys it, then atomically restores the real directory.
# Usage:
#   SUPABASE_PROJECT_REF=<ref> \
#   STUB_SHA256=<phase1-shasum-a-256-hash> \
#   bash tools/deploy-upload-authorize-stub.sh
set -euo pipefail

SUPABASE_PROJECT_REF="${SUPABASE_PROJECT_REF:?SUPABASE_PROJECT_REF not set}"
STUB_SHA256="${STUB_SHA256:?STUB_SHA256 not set — must equal Phase 1 evidence hash}"

# Resolve absolute paths before any directory changes.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
STUB_SRC_ABS="${REPO_ROOT}/tools/stubs/upload-authorize/index.ts"
REAL_ABS="${REPO_ROOT}/supabase/functions/upload-authorize"
FUNCTIONS_ABS="${REPO_ROOT}/supabase/functions"

# Backup lives in the same directory as the real function so mv is same-filesystem.
BACKUP_ABS="${FUNCTIONS_ABS}/upload-authorize.real-backup-$$"
REAL_MANIFEST=""

restore() {
  local rc=$?
  if [[ -d "${BACKUP_ABS}" ]]; then
    # Regenerate backup manifest using relative paths (cd into dir).
    local current_manifest
    current_manifest=$(cd "${BACKUP_ABS}" \
      && find . -type f | LC_ALL=C sort | xargs shasum -a 256 2>&1)
    if [[ "${current_manifest}" != "${REAL_MANIFEST}" ]]; then
      echo "FAIL: backup manifest mismatch after swap — MANUAL RESTORE REQUIRED" >&2
      echo "  Backup preserved at: ${BACKUP_ABS}" >&2
      exit 1
    fi
    # Atomic restore: remove stub dir, rename backup into place.
    rm -rf "${REAL_ABS}"
    mv "${BACKUP_ABS}" "${REAL_ABS}"
    echo "INFO: real upload-authorize restored (complete tree verified)"
  fi
  exit "${rc}"
}
trap restore EXIT

# 1. Validate absolute paths and safety preconditions.
[[ -f "${STUB_SRC_ABS}" ]]   || { echo "FAIL: stub not found at ${STUB_SRC_ABS}"; exit 1; }
[[ -d "${REAL_ABS}" ]]       || { echo "FAIL: real dir not found at ${REAL_ABS}"; exit 1; }
[[ ! -L "${REAL_ABS}" ]]     || { echo "FAIL: ${REAL_ABS} is a symlink — aborting"; exit 1; }
[[ -d "${FUNCTIONS_ABS}" ]]  || { echo "FAIL: functions dir not found"; exit 1; }
[[ ! -e "${BACKUP_ABS}" ]]   || { echo "FAIL: backup target already exists: ${BACKUP_ABS}"; exit 1; }

# 2. Verify stub hash against Phase 1 evidence.
actual_stub_hash=$(shasum -a 256 "${STUB_SRC_ABS}" | awk '{print $1}')
if [[ "${actual_stub_hash}" != "${STUB_SHA256}" ]]; then
  echo "FAIL: stub hash mismatch"
  echo "  Expected: ${STUB_SHA256}"
  echo "  Actual:   ${actual_stub_hash}"
  exit 1
fi

# 3. Record complete tree manifest using relative paths (cd into real dir).
#    This ensures restore comparison uses identical relative paths regardless
#    of where the backup directory is renamed to.
REAL_MANIFEST=$(cd "${REAL_ABS}" \
  && find . -type f | LC_ALL=C sort | xargs shasum -a 256 2>&1)

# 4. Atomic rename — both paths are within supabase/functions/ so mv is same-filesystem.
#    If this fails, nothing has changed; REAL_ABS is untouched.
mv "${REAL_ABS}" "${BACKUP_ABS}"

# 5. Swap in stub directory (only index.ts).
mkdir -p "${REAL_ABS}"
cp "${STUB_SRC_ABS}" "${REAL_ABS}/index.ts"

# 6. Deploy stub as upload-authorize.
supabase functions deploy upload-authorize \
  --project-ref "${SUPABASE_PROJECT_REF}" \
  --no-verify-jwt

echo "INFO: 503 stub deployed as upload-authorize"
# restore() fires on EXIT and atomically restores the real directory.
