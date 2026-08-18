#!/usr/bin/env bash
# integration-runner.sh — upload-authorize integration test runner (Amendment D: R2 presign)
# Run from the repo root: bash tools/integration-runner.sh
#
# Required env (pre-set before running; never read from supabase status):
#   R2_ENDPOINT          Cloudflare R2 S3-compatible endpoint URL
#   R2_ACCESS_KEY_ID     R2 access key ID
#   R2_SECRET_ACCESS_KEY R2 secret access key
#   R2_BUCKET            R2 bucket name (default: forkensics-dev-media)
#
# All R2 variables are required — preflight fails if any is absent.
# T-AMD-1 through T-AMD-8 all run.
#
# KEY_MANIFEST: a 0600 temp file under /tmp that records R2 keys before each PUT.
# ENV_FILE: a 0600 temp file under /tmp holding function credentials.
# Both are deleted by cleanup() on success; KEY_MANIFEST is preserved on R2 error.
set -euo pipefail
{ set +x; } 2>/dev/null  # suppress xtrace for entire script — credentials are logged at any level if re-enabled

LOG="08_Migration/tests/integration-$(date +%Y%m%d-%H%M%S).log"
mkdir -p "08_Migration/tests"
SERVE_PID=""
KEY_MANIFEST=""
ENV_FILE=""
TEST_EXIT=1      # default failure; set to 0 only on deno test success
CLEANUP_FAILED=0 # set to 1 by _r2_cleanup or log-scan failures

# ── Credential helpers ────────────────────────────────────────────────────────
_env() {
  supabase status -o env 2>/dev/null | grep "^${1}=" | cut -d= -f2- | tr -d "\"'" || true
}
_env_fb() {
  # _env_fb PRIMARY LEGACY — returns PRIMARY if set, otherwise LEGACY
  local v
  v=$(_env "$1")
  [[ -z "$v" ]] && v=$(_env "$2")
  echo "$v"
}

# ── Temp-file validator ───────────────────────────────────────────────────────
# _validate_tmp_file PATH REGEX LABEL
# Checks all five required properties: (1) exact approved path format, (2) regular
# file, (3) not a symlink, (4) owned by the current user (-O), (5) permissions
# exactly 0600 (macOS/Linux-compatible stat). Returns 0 on pass, 1 on fail.
# Caller sets CLEANUP_FAILED and preserves the file on failure.
_validate_tmp_file() {
  local _path="$1" _re="$2" _label="$3"
  if [[ ! "${_path}" =~ ${_re} ]]; then
    echo "FAIL: ${_label} path failed validation: ${_path}" >&2; return 1
  fi
  if [[ ! -f "${_path}" ]]; then
    echo "FAIL: ${_label} is not a regular file (or does not exist): ${_path}" >&2; return 1
  fi
  if [[ -L "${_path}" ]]; then
    echo "FAIL: ${_label} is a symlink: ${_path}" >&2; return 1
  fi
  if [[ ! -O "${_path}" ]]; then
    echo "FAIL: ${_label} is not owned by the current user: ${_path}" >&2; return 1
  fi
  local _perm
  if stat --version >/dev/null 2>&1; then
    _perm=$(stat -c '%a' "${_path}" 2>/dev/null || echo "")   # GNU stat (Linux)
  else
    _perm=$(stat -f '%OLp' "${_path}" 2>/dev/null || echo "")  # BSD stat (macOS)
  fi
  if [[ "${_perm}" != "600" ]]; then
    echo "FAIL: ${_label} permissions are ${_perm:-unknown}, expected 600: ${_path}" >&2
    return 1
  fi
  return 0
}

# ── R2 cleanup (T-AMD-6 protocol) ────────────────────────────────────────────
# For each key in KEY_MANIFEST:
#   1. Validate manifest path and per-line key format.
#   2. Call tools/r2-cleanup-helper.ts (Deno, @aws-sdk/client-s3; aws CLI not required):
#      a. HEAD-before-delete: if 404 skip; if 200 proceed.
#      b. DeleteObjectCommand.
#      c. HEAD-after-delete: must be 404.
#   3. CLEANUP_FAILED=1 on any error; manifest preserved on failure.
#   4. AWS_* unset only after all R2 ops complete.
_r2_cleanup() {
  [[ -z "${R2_ENDPOINT:-}" ]] && return 0
  [[ -z "${KEY_MANIFEST:-}" ]] && return 0

  # Full five-check validation before any file operation.
  # A nonempty KEY_MANIFEST whose file has disappeared is an error, not a silent no-op.
  if ! _validate_tmp_file "${KEY_MANIFEST}" \
       '^/tmp/forkensics-keys-[A-Za-z0-9]+$' "T-AMD-6: KEY_MANIFEST"; then
    CLEANUP_FAILED=1
    return 1
  fi
  if [[ ! -s "${KEY_MANIFEST}" ]]; then
    echo "T-AMD-6: manifest empty — nothing to clean"
    rm -f "${KEY_MANIFEST}"
    KEY_MANIFEST=""
    return 0
  fi

  local bucket="${R2_BUCKET:-forkensics-dev-media}"
  local UUID_V4_BODY
  UUID_V4_BODY='[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}'
  local ORIG_KEY_RE="^originals/${UUID_V4_BODY}$"
  local _local_fail=0

  # T-AMD-6 item 6: map R2 credentials to AWS_* (xtrace disabled to avoid logging values).
  { set +x; } 2>/dev/null
  export AWS_ACCESS_KEY_ID="${R2_ACCESS_KEY_ID:-}"
  export AWS_SECRET_ACCESS_KEY="${R2_SECRET_ACCESS_KEY:-}"
  export AWS_DEFAULT_REGION="auto"

  while IFS= read -r key; do
    [[ -z "$key" ]] && continue

    # Per-line key validation (strict UUID v4).
    if [[ ! "${key}" =~ ${ORIG_KEY_RE} ]]; then
      echo "FAIL T-AMD-6: key failed strict validation: ${key}" >&2
      _local_fail=1
      CLEANUP_FAILED=1
      continue
    fi

    echo "T-AMD-6: processing key=${key}"

    # T-AMD-5/T-AMD-6: HEAD-before-delete, delete, HEAD-after-delete.
    # Uses tools/r2-cleanup-helper.ts (@aws-sdk/client-s3); aws CLI not required.
    # Exit 0 = deleted + confirmed absent; 1 = not present (skip); 2+ = error.
    { set +x; } 2>/dev/null
    local helper_rc
    deno run --allow-net --allow-env --allow-sys \
      tools/r2-cleanup-helper.ts "${key}" 2>&1
    helper_rc=$?
    if [[ "${helper_rc}" -eq 0 ]]; then
      : # Key deleted and confirmed absent — T-AMD-6 PASS for this key.
    elif [[ "${helper_rc}" -eq 1 ]]; then
      continue # Key not present in R2 (PUT was rejected); skip gracefully.
    else
      echo "FAIL T-AMD-6: cleanup helper failed for key=${key} (exit ${helper_rc})" >&2
      _local_fail=1
      CLEANUP_FAILED=1
    fi
  done < "${KEY_MANIFEST}"

  # T-AMD-6 item 9: unset AWS_* only after all R2 operations complete.
  { set +x; } 2>/dev/null
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION

  # T-AMD-6 item 11: preserve manifest on failure; delete only on full success.
  if [[ "${_local_fail}" -eq 0 ]]; then
    rm -f "${KEY_MANIFEST}"
    KEY_MANIFEST=""
  else
    echo "WARN: KEY_MANIFEST preserved at ${KEY_MANIFEST} for manual inspection" >&2
  fi
}

# ── Cleanup: runs exactly once on EXIT ───────────────────────────────────────
cleanup() {
  local body_rc=$?
  trap - EXIT
  set +e
  local _teardown_exit=0

  # Kill and reap the function server.
  if [[ -n "$SERVE_PID" ]]; then
    kill "$SERVE_PID" 2>/dev/null || true
    wait "$SERVE_PID" 2>/dev/null || true
  fi

  # Remove ENV_FILE — full five-check validation before deletion; preserve on failure.
  if [[ -n "${ENV_FILE:-}" ]]; then
    if _validate_tmp_file "${ENV_FILE}" \
         '^/tmp/forkensics-integration-[A-Za-z0-9]+$' "ENV_FILE"; then
      rm -f "${ENV_FILE}"
    else
      echo "WARN: ENV_FILE preserved at ${ENV_FILE} for manual inspection" >&2
      CLEANUP_FAILED=1
    fi
    ENV_FILE=""
  fi

  # R2 cleanup (T-AMD-6 protocol; sets CLEANUP_FAILED on errors).
  _r2_cleanup

  # T-AMD-7: grep LOG for R2 endpoint hostname → expect zero matches.
  # Presigned URLs must not appear in the runner log.
  if [[ -n "${R2_ENDPOINT:-}" && -f "${LOG}" ]]; then
    local r2_host t7_count
    r2_host=$(printf '%s' "${R2_ENDPOINT}" | sed -E 's|^https?://||' | cut -d/ -f1)
    t7_count=$(grep -cF "${r2_host}" "${LOG}" 2>/dev/null || true)
    if [[ "${t7_count}" -gt 0 ]]; then
      echo "FAIL T-AMD-7: R2 hostname found in log (${t7_count} occurrences) — URL leakage" >&2
      CLEANUP_FAILED=1
    else
      echo "T-AMD-7: R2 hostname not found in log (PASS)"
    fi
  fi

  # T-AMD-8: grep LOG for actual R2 credential values → expect zero matches.
  # Xtrace disabled during value extraction and grep to prevent logging the values.
  if [[ -n "${R2_ENDPOINT:-}" && -f "${LOG}" ]]; then
    local _t8_fail=0
    { set +x; } 2>/dev/null
    local _akid="${R2_ACCESS_KEY_ID:-}" _sak="${R2_SECRET_ACCESS_KEY:-}"
    local _t8_akid_count=0 _t8_sak_count=0
    if [[ -n "${_akid}" ]]; then
      _t8_akid_count=$(grep -cF "${_akid}" "${LOG}" 2>/dev/null || true)
    fi
    if [[ -n "${_sak}" ]]; then
      _t8_sak_count=$(grep -cF "${_sak}" "${LOG}" 2>/dev/null || true)
    fi
    _akid=""; _sak=""
    if [[ "${_t8_akid_count}" -gt 0 ]]; then
      echo "FAIL T-AMD-8: R2_ACCESS_KEY_ID value found in log (${_t8_akid_count} occurrences)" >&2
      _t8_fail=1
    fi
    if [[ "${_t8_sak_count}" -gt 0 ]]; then
      echo "FAIL T-AMD-8: R2_SECRET_ACCESS_KEY value found in log" >&2
      _t8_fail=1
    fi
    if [[ "${_t8_fail}" -eq 0 ]]; then
      echo "T-AMD-8: no R2 credential values in log (PASS)"
    else
      CLEANUP_FAILED=1
    fi
  fi

  # DB fixture teardown.
  if [[ -n "${DB_URL:-}" ]]; then
    psql "$DB_URL" --no-password -q -v ON_ERROR_STOP=1 \
      -c "SELECT cleanup_integration_fixtures();" 2>&1 \
      || _teardown_exit=$?
    if [[ "$_teardown_exit" -ne 0 ]]; then
      echo "WARN: cleanup_integration_fixtures() failed (exit ${_teardown_exit})"
    fi
    psql "$DB_URL" --no-password -q \
      -c "REVOKE ALL ON FUNCTION public.cleanup_integration_fixtures() FROM PUBLIC;" \
      -c "DROP FUNCTION IF EXISTS public.cleanup_integration_fixtures();" \
      2>/dev/null || true
  fi

  unset SUPABASE_URL SUPABASE_PUBLISHABLE_KEY SUPABASE_SECRET_KEY \
        SUPABASE_JWT_SECRET FK_JWKS_JSON FK_DB_URL DB_URL \
        R2_ENDPOINT R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_BUCKET \
        2>/dev/null || true

  # Final exit: non-zero if any of body_rc, TEST_EXIT, teardown, or CLEANUP_FAILED failed.
  local _final_exit=0
  [[ "${body_rc}" -ne 0 ]] && _final_exit="${body_rc}"
  [[ "${TEST_EXIT}" -ne 0 ]] && _final_exit="${TEST_EXIT}"
  if [[ "$_teardown_exit" -ne 0 ]]; then
    _final_exit="${_teardown_exit}"
    echo "WARN: tests passed but DB teardown failed; result is FAIL"
  fi
  if [[ "${CLEANUP_FAILED}" -ne 0 ]]; then
    _final_exit=1
    echo "WARN: R2 cleanup or log scan failed; result is FAIL"
  fi

  echo "=== RESULT: $([ "${_final_exit}" -eq 0 ] && echo PASS || echo FAIL) ===" \
    | tee -a "$LOG"
  exit "${_final_exit}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

exec > >(tee -a "$LOG") 2>&1
echo "=== upload-authorize integration suite (Amendment D: R2 presign) ==="
echo "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ── 1. Preflight ──────────────────────────────────────────────────────────────
supabase status --output env > /dev/null

# ── 2. Supabase credentials (from supabase status) ────────────────────────────
SUPABASE_URL=$(_env API_URL)
SUPABASE_PUBLISHABLE_KEY=$(_env_fb PUBLISHABLE_KEY ANON_KEY)
SUPABASE_SECRET_KEY=$(_env_fb SECRET_KEY SERVICE_ROLE_KEY)
SUPABASE_JWT_SECRET=$(_env JWT_SECRET)
DB_URL=$(_env DB_URL)

for var in SUPABASE_URL SUPABASE_PUBLISHABLE_KEY SUPABASE_SECRET_KEY \
           SUPABASE_JWT_SECRET DB_URL; do
  [[ -z "${!var}" ]] && { echo "FAIL: could not read ${var}"; exit 1; }
done

# ── 2b. FK_JWKS_JSON — inline JWK Set for local JWT verification ──────────────
# @supabase/server@1.4.1 requires SUPABASE_JWKS / SUPABASE_JWKS_URL; the local
# edge runtime provides neither. We build an inline JWK Set from SUPABASE_JWT_SECRET
# and inject it as FK_JWKS_JSON (non-SUPABASE_ prefix, not skipped by the runtime).
# kid "forkensics-local" must match FK_JWKS_KID constant in the integration test.
{ set +x; } 2>/dev/null
_jws_b64url=$(printf '%s' "${SUPABASE_JWT_SECRET}" | openssl base64 -A | tr '+/' '-_' | tr -d '=')
FK_JWKS_JSON='{"keys":[{"kty":"oct","alg":"HS256","kid":"forkensics-local","k":"'"${_jws_b64url}"'"}]}'
_jws_b64url=""

# ── 3. R2 credentials (from caller env; never from supabase status) ───────────
# All T-AMD tests (T-AMD-2 through T-AMD-8) must run; all R2 variables required.
R2_BUCKET="${R2_BUCKET:-forkensics-dev-media}"
for var in R2_ENDPOINT R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY; do
  [[ -z "${!var:-}" ]] && { echo "FAIL: ${var} is required (all T-AMD tests must run)"; exit 1; }
done
echo "R2 credentials verified: T-AMD-2 through T-AMD-8 will run"

FUNCTION_URL="${SUPABASE_URL}/functions/v1/upload-authorize"

# ── 4. KEY_MANIFEST temp file (0600 under /tmp) ───────────────────────────────
# Integration tests record R2 object keys here BEFORE each PUT.
# cleanup() reads this file to HEAD-verify and delete uploaded objects.
KEY_MANIFEST=$(mktemp /tmp/forkensics-keys-XXXXXX)
chmod 0600 "${KEY_MANIFEST}"
_validate_tmp_file "${KEY_MANIFEST}" \
  '^/tmp/forkensics-keys-[A-Za-z0-9]+$' "KEY_MANIFEST" \
  || { echo "FAIL: KEY_MANIFEST post-creation validation failed; aborting" >&2; exit 1; }

# ── 5. ENV_FILE temp file (0600 under /tmp) ───────────────────────────────────
# Function credentials stored in /tmp (not in repo) with guaranteed cleanup.
# R2_* values written with xtrace suppressed to avoid logging credential values.
ENV_FILE=$(mktemp /tmp/forkensics-integration-XXXXXX)
chmod 0600 "${ENV_FILE}"
_validate_tmp_file "${ENV_FILE}" \
  '^/tmp/forkensics-integration-[A-Za-z0-9]+$' "ENV_FILE" \
  || { echo "FAIL: ENV_FILE pre-write validation failed; aborting" >&2; exit 1; }
cat > "${ENV_FILE}" << ENVEOF
SUPABASE_URL=${SUPABASE_URL}
SUPABASE_PUBLISHABLE_KEY=${SUPABASE_PUBLISHABLE_KEY}
SUPABASE_SECRET_KEY=${SUPABASE_SECRET_KEY}
R2_BUCKET=${R2_BUCKET}
FK_DB_URL=${DB_URL}
ENVEOF
{ set +x; } 2>/dev/null
printf 'R2_ENDPOINT=%s\nR2_ACCESS_KEY_ID=%s\nR2_SECRET_ACCESS_KEY=%s\n' \
  "${R2_ENDPOINT:-}" \
  "${R2_ACCESS_KEY_ID:-}" \
  "${R2_SECRET_ACCESS_KEY:-}" \
  >> "${ENV_FILE}"
# FK_JWKS_JSON: inline JWK Set for local JWT verification (not a SUPABASE_ prefix;
# the edge runtime will not skip it). Written suppressed — never echoed to log.
printf 'FK_JWKS_JSON=%s\n' "${FK_JWKS_JSON}" >> "${ENV_FILE}"

# ── 6. Fixtures ───────────────────────────────────────────────────────────────
psql "$DB_URL" --no-password -q -v ON_ERROR_STOP=1 -f tools/integration-fixtures.sql

# ── 7. Serve function ─────────────────────────────────────────────────────────
supabase functions serve upload-authorize \
  --env-file "${ENV_FILE}" &
SERVE_PID=$!

# ── 8. Readiness poll (|| true so connection errors don't trigger set -e) ─────
READY=false
for _ in $(seq 1 30); do
  http_code=$(curl -s -o /dev/null -w "%{http_code}" "$FUNCTION_URL" 2>/dev/null || true)
  if [[ "$http_code" == "401" || "$http_code" == "400" || "$http_code" == "405" ]]; then
    READY=true; break
  fi
  sleep 1
done
$READY || { echo "FAIL: function not ready after 30 s"; exit 1; }

# ── 9. Run tests ──────────────────────────────────────────────────────────────
# R2 credentials passed to the Deno test process (xtrace disabled during env
# block construction). Race B uses defaultDeps.presign (real R2 presigner)
# in-process, which requires R2_ACCESS_KEY_ID and R2_SECRET_ACCESS_KEY.
# T-AMD-5 uses @aws-sdk/client-s3 HeadObjectCommand directly (aws CLI not required).
{ set +x; } 2>/dev/null
_r2_akid="${R2_ACCESS_KEY_ID:-}"
_r2_sak="${R2_SECRET_ACCESS_KEY:-}"

if env \
     SUPABASE_URL="${SUPABASE_URL}" \
     SUPABASE_PUBLISHABLE_KEY="${SUPABASE_PUBLISHABLE_KEY}" \
     SUPABASE_SECRET_KEY="${SUPABASE_SECRET_KEY}" \
     SUPABASE_JWT_SECRET="${SUPABASE_JWT_SECRET}" \
     FK_JWKS_JSON="${FK_JWKS_JSON}" \
     FK_DB_URL="${DB_URL}" \
     DB_URL="${DB_URL}" \
     FUNCTION_URL="${FUNCTION_URL}" \
     R2_ENDPOINT="${R2_ENDPOINT:-}" \
     R2_BUCKET="${R2_BUCKET}" \
     KEY_MANIFEST="${KEY_MANIFEST}" \
     R2_ACCESS_KEY_ID="${_r2_akid}" \
     R2_SECRET_ACCESS_KEY="${_r2_sak}" \
   deno test \
     --allow-net --allow-env --allow-read --allow-run --allow-write --allow-sys \
     supabase/functions/upload-authorize/upload-authorize.integration.test.ts; then
  TEST_EXIT=0
else
  TEST_EXIT=$?
fi

# Wipe runner-local copies of R2 credentials before log scans in cleanup().
{ set +x; } 2>/dev/null
_r2_akid=""; _r2_sak=""

exit "$TEST_EXIT"
