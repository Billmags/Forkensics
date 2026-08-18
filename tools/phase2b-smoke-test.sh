#!/usr/bin/env bash
# phase2b-smoke-test.sh — Phase 2b live smoke test for upload-authorize on forkensics-dev.
# Run from the repo root after the function is deployed.
#
# Required env (set before running — never hardcode credentials):
#   FUNCTION_URL         https://<ref>.supabase.co/functions/v1/upload-authorize
#   ACCESS_TOKEN         Valid Supabase JWT for a test user with an active profile
#   CASE_ID              Valid case UUID in forkensics-dev
#   DB_URL               forkensics-dev psql connection string (postgres role)
#   R2_ENDPOINT          Cloudflare R2 S3-compatible endpoint URL
#   R2_ACCESS_KEY_ID     R2 access key ID (32 chars)
#   R2_SECRET_ACCESS_KEY R2 secret key (64 chars)
#   R2_BUCKET            R2 bucket name (default: forkensics-dev-media)
#
# Never enable xtrace (set -x) — credentials are in env.
set -euo pipefail
{ set +x; } 2>/dev/null

LOG="08_Migration/tests/phase2b-smoke-$(date +%Y%m%d-%H%M%S).log"
mkdir -p "08_Migration/tests"

SESSION_KEY=""   # R2 key to clean up on exit
SMOKE_FAILED=0
_TEMP_FILES=()   # Temp files to remove in EXIT handler

log() { echo "$*" | tee -a "${LOG}"; }
fail() { log "FAIL: $*"; SMOKE_FAILED=1; }

# ── Cleanup / exit handler ─────────────────────────────────────────────────────
cleanup() {
  local _rc=$?
  set +e
  trap - EXIT

  # Remove tracked temp files (safety net for early exits).
  local _f
  for _f in "${_TEMP_FILES[@]:-}"; do
    [[ -f "${_f}" ]] && rm -f "${_f}"
  done

  if [[ -n "${SESSION_KEY}" ]]; then
    log "--- R2 cleanup ---"
    { set +x; } 2>/dev/null
    AWS_ACCESS_KEY_ID="${R2_ACCESS_KEY_ID}" \
    AWS_SECRET_ACCESS_KEY="${R2_SECRET_ACCESS_KEY}" \
      deno run --allow-net --allow-env --allow-sys \
        tools/r2-cleanup-helper.ts "${SESSION_KEY}" 2>&1 | tee -a "${LOG}"
    local _cleanup_rc=${PIPESTATUS[0]}
    if [[ "${_cleanup_rc}" -ne 0 ]]; then
      log "CLEANUP FAILURE: r2-cleanup-helper exited ${_cleanup_rc} — residual R2 object may exist: SESSION_KEY=${SESSION_KEY}"
      SMOKE_FAILED=1
    fi
  fi

  if [[ "${SMOKE_FAILED}" -ne 0 || "${_rc}" -ne 0 ]]; then
    log ""
    log "=== RESULT: FAIL ==="
  else
    log ""
    log "=== RESULT: PASS ==="
  fi
  log "Log: ${LOG}"
  shasum -a 256 "${LOG}"
  exit $(( _rc != 0 || SMOKE_FAILED != 0 ? 1 : 0 ))
}
trap cleanup EXIT

# ── Preflight ─────────────────────────────────────────────────────────────────
for _v in FUNCTION_URL ACCESS_TOKEN CASE_ID DB_URL R2_ENDPOINT R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY; do
  [[ -n "${!_v:-}" ]] || { echo "FAIL: ${_v} not set" >&2; exit 1; }
done
R2_BUCKET="${R2_BUCKET:-forkensics-dev-media}"

log "=== Phase 2b Smoke Test — $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
log "Function URL: ${FUNCTION_URL}"
log "Case ID: ${CASE_ID}"
log "R2 Bucket: ${R2_BUCKET}"
log ""

# Validate credential lengths.
if [[ ${#R2_ACCESS_KEY_ID} -ne 32 ]]; then
  fail "R2_ACCESS_KEY_ID length ${#R2_ACCESS_KEY_ID} — expected 32"; exit 1
fi
if [[ ${#R2_SECRET_ACCESS_KEY} -ne 64 ]]; then
  fail "R2_SECRET_ACCESS_KEY length ${#R2_SECRET_ACCESS_KEY} — expected 64"; exit 1
fi
log "Credential length checks: PASS"

# ── Step 1: POST upload-authorize ─────────────────────────────────────────────
log "--- Step 1: POST upload-authorize ---"

_resp_file=$(mktemp /tmp/forkensics-smoke-XXXXXX)
chmod 0600 "${_resp_file}"
_TEMP_FILES+=("${_resp_file}")

_http=$(curl -s -o "${_resp_file}" -w "%{http_code}" \
  -X POST "${FUNCTION_URL}" \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"case_id\":\"${CASE_ID}\",\"content_type\":\"image/jpeg\",\"declared_size_bytes\":1024}")

_body=$(cat "${_resp_file}"); rm -f "${_resp_file}"
log "HTTP status: ${_http}"

if [[ "${_http}" != "200" ]]; then
  fail "Expected HTTP 200, got ${_http}"
  # Log body with credentials redacted — only log status field if present.
  _status_field=$(echo "${_body}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('error','(no error field)'))" 2>/dev/null || echo "(non-JSON body)")
  log "Error field: ${_status_field}"
  exit 1
fi

# Parse response — python3 available on macOS.
PRESIGNED_URL=$(python3 -c "import sys,json; d=json.loads(sys.argv[1]); print(d['presigned_url'])" "${_body}" 2>/dev/null || true)
UPLOAD_TOKEN=$(python3  -c "import sys,json; d=json.loads(sys.argv[1]); print(d['upload_token'])" "${_body}" 2>/dev/null || true)
EXPIRES_AT=$(python3   -c "import sys,json; d=json.loads(sys.argv[1]); print(d['expires_at'])"   "${_body}" 2>/dev/null || true)

[[ -n "${PRESIGNED_URL}" ]] || { fail "presigned_url missing from response"; exit 1; }
[[ -n "${UPLOAD_TOKEN}"  ]] || { fail "upload_token missing from response";  exit 1; }
[[ -n "${EXPIRES_AT}"    ]] || { fail "expires_at missing from response";    exit 1; }
log "Response shape: presigned_url ✓  upload_token ✓  expires_at ✓"

# Host must match R2_ENDPOINT.
_r2_host=$(echo "${R2_ENDPOINT}" | sed 's|https://||')
if ! echo "${PRESIGNED_URL}" | grep -qF "${_r2_host}"; then
  fail "presigned_url host does not match R2_ENDPOINT"
  exit 1
fi
log "Host check: matches R2_ENDPOINT (PASS)"

# X-Amz-SignedHeaders must contain content-type.
if ! echo "${PRESIGNED_URL}" | grep -qi "content-type"; then
  fail "X-Amz-SignedHeaders does not contain content-type"
  exit 1
fi
log "SignedHeaders: content-type present (PASS)"

# Extract and validate key format: originals/<uuid-v4>
_uuid_re='[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}'
SESSION_KEY=$(echo "${PRESIGNED_URL}" | grep -oE "originals/${_uuid_re}" || true)
if [[ -z "${SESSION_KEY}" ]]; then
  fail "Key in presigned_url does not match originals/<uuid-v4>"
  exit 1
fi
log "Key format: ${SESSION_KEY} (PASS)"

# ── Step 2: PUT test image ────────────────────────────────────────────────────
log ""
log "--- Step 2: PUT test image ---"

_jpeg_file=$(mktemp /tmp/forkensics-smoke-XXXXXX.jpg)
chmod 0600 "${_jpeg_file}"
_TEMP_FILES+=("${_jpeg_file}")
# Minimal valid JPEG: SOI marker (FF D8) + EOI marker (FF D9)
printf '\xff\xd8\xff\xd9' > "${_jpeg_file}"

_put_status=$(curl -s -o /dev/null -w "%{http_code}" \
  -X PUT "${PRESIGNED_URL}" \
  -H "Content-Type: image/jpeg" \
  --data-binary "@${_jpeg_file}")
rm -f "${_jpeg_file}"

log "PUT HTTP status: ${_put_status}"
if [[ "${_put_status}" != "200" ]]; then
  fail "PUT expected 200, got ${_put_status}"
  exit 1
fi
log "PUT: PASS"

# ── Step 3: Resolve session_id ────────────────────────────────────────────────
log ""
log "--- Step 3: Resolve session_id ---"
{ set +x; } 2>/dev/null

# Extract uploader_id (sub) from JWT payload.
_jwt_payload=$(echo "${ACCESS_TOKEN}" | cut -d. -f2)
# Base64-pad to multiple of 4 before decode.
_padded="${_jwt_payload}$(printf '%0.s=' $((4 - ${#_jwt_payload} % 4)))"
UPLOADER_ID=$(echo "${_padded}" | base64 -d 2>/dev/null \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['sub'])" 2>/dev/null || true)

[[ -n "${UPLOADER_ID}" ]] || { fail "Could not extract sub from ACCESS_TOKEN JWT"; exit 1; }
log "uploader_id resolved from JWT (PASS)"

SESSION_ID=$(psql "${DB_URL}" -t -A -c "
  SELECT session_id
  FROM public.resolve_upload_session(
    encode(sha256('${UPLOAD_TOKEN}'::bytea), 'hex'),
    '${UPLOADER_ID}'::uuid
  );" 2>/dev/null || true)

# Upload token no longer needed — clear it.
unset UPLOAD_TOKEN

[[ -n "${SESSION_ID}" ]] || { fail "resolve_upload_session returned no row"; exit 1; }
log "resolve_upload_session: OK (session_id resolved)"

# ── Step 4: HEAD → DELETE → HEAD (R2 object verify + cleanup) ─────────────────
log ""
log "--- Step 4: R2 object verify and delete ---"

(
  { set +x; } 2>/dev/null
  trap 'unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY' EXIT
  export AWS_ACCESS_KEY_ID="${R2_ACCESS_KEY_ID}"
  export AWS_SECRET_ACCESS_KEY="${R2_SECRET_ACCESS_KEY}"

  deno run --allow-net --allow-env --allow-sys \
    tools/r2-cleanup-helper.ts "${SESSION_KEY}" 2>&1 | tee -a "${LOG}"
  _r2_rc=${PIPESTATUS[0]}

  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
  trap - EXIT

  if [[ "${_r2_rc}" -eq 0 ]]; then
    exit 0
  elif [[ "${_r2_rc}" -eq 1 ]]; then
    echo "FAIL: object not present in R2 after PUT — T-AMD-6 exit 1 (FAIL)" | tee -a "${LOG}"
    exit 1
  else
    echo "FAIL: r2-cleanup-helper exited ${_r2_rc}" | tee -a "${LOG}"
    exit 1
  fi
) || { fail "R2 object verify/delete step failed"; SMOKE_FAILED=1; }

# Clear SESSION_KEY only after confirmed deletion so the EXIT trap can retry on failure.
# If SMOKE_FAILED is set (step 4 subshell failed), SESSION_KEY is preserved for cleanup().
if [[ "${SMOKE_FAILED}" -eq 0 ]]; then
  SESSION_KEY=""
fi

# ── Step 5: fail_upload_session ───────────────────────────────────────────────
log ""
log "--- Step 5: fail_upload_session ---"

psql "${DB_URL}" -t -A -c \
  "SELECT fail_upload_session('${SESSION_ID}'::uuid, 'FK_INTERNAL');" 2>&1 | tee -a "${LOG}"

# Verify status = failed via direct table query (no token needed).
_session_status=$(psql "${DB_URL}" -t -A -c \
  "SELECT status FROM private.upload_sessions WHERE session_id='${SESSION_ID}'::uuid;" 2>/dev/null || true)

log "Session status after fail: ${_session_status}"
if [[ "${_session_status}" == "failed" ]]; then
  log "fail_upload_session: PASS"
else
  fail "Expected status='failed', got '${_session_status}'"
fi
