#!/usr/bin/env bash
# step-b-phase2-smoke-test.sh — Step B Phase 2 smoke test (Rev 4).
# Covers D-3 (E2E upload flow) and D-4 (cleanup-worker auth gate).
# Run via tools/run-step-b-phase2-smoke.sh — never invoke directly.
#
# Required env (set by launcher):
#   ACCESS_TOKEN          Valid short-lived JWT for smoketest@forkensics-dev.local
#   CASE_ID               Draft case UUID owned by smoke account (media_object_id IS NULL)
#   DB_URL                forkensics-dev psql connection string (postgres role)
#   CRON_SECRET           Cleanup worker authentication secret
#   R2_ENDPOINT           Cloudflare R2 S3-compatible endpoint URL
#   R2_ACCESS_KEY_ID      R2 access key ID (32 chars)
#   R2_SECRET_ACCESS_KEY  R2 secret key (64 chars)
#   R2_BUCKET             R2 bucket name
#
# Log redaction — enforced by design (values never passed to log()) for:
#   presigned_url, ACCESS_TOKEN, UPLOAD_TOKEN, CRON_SECRET,
#   R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, DB_URL
# R2 object paths (ORIG_KEY, DISPLAY_KEY) are logged: they are session UUIDs,
#   not credentials.
#
# Log-redaction assertion (EXIT handler) greps the completed log for:
#   eyJ                    — JWT prefix pattern (would catch leaked ACCESS_TOKEN)
#   X-Amz-Signature=       — presigned URL HMAC signature param
#   X-Amz-Credential=      — presigned URL credential param
#
# R2 cleanup helper exit codes (tools/r2-cleanup-helper.ts):
#   0 — key present, deleted, confirmed absent  → cleanup success
#   1 — key not present before delete           → cleanup success (already absent)
#   2 — any other error                         → cleanup FAIL
#
# SESSION_ID is extracted from the R2 object path immediately after
# upload-authorize succeeds, so teardown runs even if PUT or upload-complete fails.
#
# NEVER enable xtrace (set -x) — credentials are in env.
set -euo pipefail
{ set +x; } 2>/dev/null

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

PROJECT_REF="hkfrbdpedrxmbsawnbpr"
AUTHORIZE_URL="https://${PROJECT_REF}.supabase.co/functions/v1/upload-authorize"
COMPLETE_URL="https://${PROJECT_REF}.supabase.co/functions/v1/upload-complete"
CLEANUP_URL="https://${PROJECT_REF}.supabase.co/functions/v1/upload-cleanup-worker"
SMOKE_EMAIL="smoketest@forkensics-dev.local"

FIXTURE="tools/fixtures/smoke-test.jpg"
FIXTURE_SIZE=13674
FIXTURE_SHA256="336bbb3e3f88a084d9a19956cda4937a0e9a1c211243ce2c9e2dc09ca3242c33"

# ---------------------------------------------------------------------------
# State (tracked for teardown)
# ---------------------------------------------------------------------------

ORIG_KEY=""         # R2 original object path (upload-complete deletes on happy path)
DISPLAY_KEY=""      # R2 display object path (CF Worker creates; deleted in teardown)
MEDIA_OBJECT_ID=""  # Set after upload-complete returns 200
SESSION_ID=""       # Set immediately from R2 object path after upload-authorize succeeds
SMOKE_FAILED=0
_TEMP_FILES=()      # Registered temp files; deleted by EXIT handler

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

LOG="08_Migration/tests/step-b-phase2-smoke-$(date +%Y%m%d-%H%M%S).log"
mkdir -p "08_Migration/tests"

log()  { echo "$*" | tee -a "${LOG}"; }
fail() { log "TEST FAIL: $*"; SMOKE_FAILED=1; }

# ---------------------------------------------------------------------------
# R2 teardown helper — wraps r2-cleanup-helper.ts with teardown exit semantics.
# Exit codes 0 (deleted) and 1 (already absent) are both cleanup success.
# Only exit code 2 (error) is a cleanup failure.
# ---------------------------------------------------------------------------

r2_teardown() {
  local _key="$1" _label="$2"
  local _subshell_rc

  (
    { set +x; } 2>/dev/null
    trap 'unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY' EXIT
    export AWS_ACCESS_KEY_ID="${R2_ACCESS_KEY_ID}"
    export AWS_SECRET_ACCESS_KEY="${R2_SECRET_ACCESS_KEY}"
    deno run --allow-net --allow-env --allow-sys \
      tools/r2-cleanup-helper.ts "${_key}" 2>&1 | tee -a "${LOG}"
    _helper_rc="${PIPESTATUS[0]}"
    unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
    trap - EXIT
    # 0 = deleted; 1 = already absent — both are teardown success
    if [[ "${_helper_rc}" -eq 0 || "${_helper_rc}" -eq 1 ]]; then
      exit 0
    else
      exit 2
    fi
  )
  _subshell_rc=$?

  if [[ "${_subshell_rc}" -eq 0 ]]; then
    log "CLEANUP PASS: ${_label} (${_key})"
    return 0
  else
    log "CLEANUP FAIL: ${_label} — r2-cleanup-helper exited with error (${_key})"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Teardown / exit handler
# ---------------------------------------------------------------------------

cleanup() {
  local _rc=$?
  set +e
  trap - EXIT

  # Remove all registered temp files (safety net for early exits).
  local _f
  for _f in "${_TEMP_FILES[@]:-}"; do
    [[ -f "${_f}" ]] && rm -f "${_f}"
  done

  local _cleanup_fail=0

  if [[ -n "${ORIG_KEY}" || -n "${DISPLAY_KEY}" || \
        -n "${MEDIA_OBJECT_ID}" || -n "${SESSION_ID}" ]]; then
    log ""
    log "--- Teardown ---"

    # ── Phase 1: DB re-query and ownership validation ─────────────────────────
    # Must run BEFORE any R2 action.  If SESSION_ID is set and ownership fails,
    # R2 teardown is also skipped — we cannot confirm the keys belong to this
    # test session.
    _td_owner_ok=0
    _td_media=""

    if [[ -n "${SESSION_ID}" ]]; then
      _td_sess=$(psql "${DB_URL}" -t -A -c \
        "SELECT uploader_id, case_id, original_storage_path, media_object_id \
           FROM private.upload_sessions \
          WHERE session_id = '${SESSION_ID}'::uuid;" \
        2>/dev/null || true)

      if [[ -z "${_td_sess}" ]]; then
        log "CLEANUP FAIL: session ${SESSION_ID} not found in DB — cannot validate ownership; R2 and DB teardown skipped"
        _cleanup_fail=1
      else
        _td_uploader=$(echo "${_td_sess}" | cut -d'|' -f1)
        _td_case=$(echo "${_td_sess}" | cut -d'|' -f2)
        _td_orig=$(echo "${_td_sess}" | cut -d'|' -f3)
        _td_media=$(echo "${_td_sess}" | cut -d'|' -f4)

        _td_fail=0
        if [[ "${_td_uploader}" != "${_uploader_id}" ]]; then
          log "CLEANUP FAIL: session ${SESSION_ID} uploader_id=${_td_uploader}, expected ${_uploader_id}"
          _td_fail=1
        fi
        if [[ "${_td_case}" != "${CASE_ID}" ]]; then
          log "CLEANUP FAIL: session ${SESSION_ID} case_id=${_td_case}, expected ${CASE_ID}"
          _td_fail=1
        fi
        if [[ -n "${ORIG_KEY}" && "${_td_orig}" != "${ORIG_KEY}" ]]; then
          log "CLEANUP FAIL: session ${SESSION_ID} original_storage_path='${_td_orig}', expected '${ORIG_KEY}'"
          _td_fail=1
        fi

        if [[ "${_td_fail}" -ne 0 ]]; then
          log "CLEANUP FAIL: ownership validation failed — R2 and DB teardown skipped"
          _cleanup_fail=1
        else
          log "CLEANUP: session ownership verified (uploader ✓  case ✓  storage_path ✓)"
          _td_owner_ok=1

          # Use DB's media_object_id as the authoritative value.
          # Overrides the HTTP response value: if the client lost the 200 response
          # but the server committed, _td_media is non-empty and full teardown runs.
          if [[ -n "${_td_media}" && "${_td_media}" != "${MEDIA_OBJECT_ID}" ]]; then
            log "CLEANUP: DB media_object_id=${_td_media} overrides HTTP value '${MEDIA_OBJECT_ID}'"
          fi
          [[ -n "${_td_media}" ]] && MEDIA_OBJECT_ID="${_td_media}"
        fi
      fi
    else
      # No SESSION_ID — nothing to validate.  By construction ORIG_KEY and
      # DISPLAY_KEY are also empty when SESSION_ID is empty, so the R2 blocks
      # below are no-ops; set _td_owner_ok=1 for defensive completeness.
      _td_owner_ok=1
    fi

    # ── Phase 2: R2 teardown — only after ownership confirmed ─────────────────
    # Exit code 0 (deleted) and 1 (already absent) are both cleanup success.
    # upload-complete deletes the original on the happy path, so exit 1 is expected.
    if [[ "${_td_owner_ok}" -eq 1 ]]; then
      if [[ -n "${ORIG_KEY}" ]]; then
        r2_teardown "${ORIG_KEY}" "R2 original" || _cleanup_fail=1
      fi
      if [[ -n "${DISPLAY_KEY}" ]]; then
        r2_teardown "${DISPLAY_KEY}" "R2 display" || _cleanup_fail=1
      fi
    fi

    # ── Phase 3: DB teardown — only after ownership confirmed ─────────────────
    if [[ -n "${SESSION_ID}" && "${_td_owner_ok}" -eq 1 ]]; then
      if [[ -n "${MEDIA_OBJECT_ID}" ]]; then
        # Full teardown: session has a committed media object.
        # Must NULL cases.media_object_id before deleting media_objects (ON DELETE RESTRICT).
        # Guard explicitly distinguishes NOT FOUND (unexpected — abort) from
        # media_object_id IS NULL (normal re-run after partial teardown — continue).
        psql "${DB_URL}" -t -A -c "
BEGIN;

DO \$guard\$
DECLARE
  v_case_media uuid;
BEGIN
  SELECT media_object_id
    INTO v_case_media
    FROM public.cases
   WHERE id = '${CASE_ID}'::uuid
     FOR UPDATE;
  -- NOT FOUND: case row missing or already deleted — unexpected; abort.
  IF NOT FOUND THEN
    RAISE EXCEPTION
      'Teardown guard: case % NOT FOUND — row missing or already deleted',
      '${CASE_ID}'::uuid;
  END IF;
  -- Accept: case points to our test media (normal), or already NULL (re-run
  -- after partial teardown).  Reject anything else.
  IF v_case_media IS DISTINCT FROM '${MEDIA_OBJECT_ID}'::uuid
     AND v_case_media IS NOT NULL THEN
    RAISE EXCEPTION
      'Teardown guard: cases.media_object_id=% expected % or NULL; aborting',
      v_case_media, '${MEDIA_OBJECT_ID}'::uuid;
  END IF;
END;
\$guard\$;

-- 2. Break ON DELETE RESTRICT: NULL out case reference
UPDATE public.cases
   SET media_object_id = NULL
 WHERE id = '${CASE_ID}'::uuid;

-- 3. Delete storage-key child row
DELETE FROM private.media_storage_keys
 WHERE media_object_id = '${MEDIA_OBJECT_ID}'::uuid;

-- 4. Clear session FK columns
UPDATE private.upload_sessions
   SET media_object_id         = NULL,
       replaced_media_object_id = NULL
 WHERE session_id = '${SESSION_ID}'::uuid;

-- 5. Delete media object
DELETE FROM public.media_objects
 WHERE id = '${MEDIA_OBJECT_ID}'::uuid;

-- 6. Mark session failed (failed_reason must satisfy ^FK_[A-Z_]+\$ CHECK)
UPDATE private.upload_sessions
   SET status            = 'failed',
       failed_reason     = 'FK_INTERNAL',
       status_changed_at = now()
 WHERE session_id = '${SESSION_ID}'::uuid;

-- 7. Verify postconditions before COMMIT.
--    NOT FOUND on the case row is an explicit failure — the case row must
--    still exist after teardown (it is a pre-existing test fixture).
DO \$verify\$
DECLARE
  v_sess_status  text;
  v_case_media   uuid;
  v_mo_count     int;
  v_msk_count    int;
BEGIN
  SELECT status
    INTO v_sess_status
    FROM private.upload_sessions
   WHERE session_id = '${SESSION_ID}'::uuid;

  SELECT media_object_id
    INTO v_case_media
    FROM public.cases
   WHERE id = '${CASE_ID}'::uuid;
  -- NOT FOUND: case row was deleted during teardown — this must never happen.
  IF NOT FOUND THEN
    RAISE EXCEPTION
      'Verify: case % NOT FOUND — case row must still exist after teardown',
      '${CASE_ID}'::uuid;
  END IF;

  SELECT COUNT(*) INTO v_mo_count
    FROM public.media_objects
   WHERE id = '${MEDIA_OBJECT_ID}'::uuid;

  SELECT COUNT(*) INTO v_msk_count
    FROM private.media_storage_keys
   WHERE media_object_id = '${MEDIA_OBJECT_ID}'::uuid;

  IF v_sess_status IS DISTINCT FROM 'failed' THEN
    RAISE EXCEPTION 'Verify: session status=% expected failed', v_sess_status;
  END IF;
  IF v_case_media IS NOT NULL THEN
    RAISE EXCEPTION 'Verify: cases.media_object_id not NULL after teardown';
  END IF;
  IF v_mo_count != 0 THEN
    RAISE EXCEPTION 'Verify: media_objects row still exists after delete';
  END IF;
  IF v_msk_count != 0 THEN
    RAISE EXCEPTION 'Verify: media_storage_keys row still exists after delete';
  END IF;
END;
\$verify\$;

COMMIT;
" 2>&1 | tee -a "${LOG}" \
          && log "CLEANUP PASS: DB teardown transaction committed (all postconditions verified)" \
          || { log "CLEANUP FAIL: DB teardown transaction failed or rolled back"; _cleanup_fail=1; }
      else
        # Partial teardown: upload-authorize succeeded but PUT or upload-complete
        # failed AND the DB confirms no media object was created.
        # Wrapped in a transaction that:
        #   - Locks the session row (FOR UPDATE)
        #   - Verifies it is NOT in status='complete' (would require full teardown)
        #   - Marks it failed
        #   - Verifies final status='failed' before COMMIT (catches zero-row UPDATE)
        psql "${DB_URL}" -t -A -c "
BEGIN;

DO \$partial\$
DECLARE
  v_status text;
BEGIN
  SELECT status
    INTO v_status
    FROM private.upload_sessions
   WHERE session_id = '${SESSION_ID}'::uuid
     FOR UPDATE;
  -- Session must exist.
  IF NOT FOUND THEN
    RAISE EXCEPTION
      'Partial teardown: session % NOT FOUND', '${SESSION_ID}'::uuid;
  END IF;
  -- Session must not be complete — that requires full teardown.
  -- If this fires, the re-query was stale; investigation required.
  IF v_status = 'complete' THEN
    RAISE EXCEPTION
      'Partial teardown: session % is complete — full teardown required '
      '(media object exists but MEDIA_OBJECT_ID was empty after re-query)',
      '${SESSION_ID}'::uuid;
  END IF;
  UPDATE private.upload_sessions
     SET status            = 'failed',
         failed_reason     = 'FK_INTERNAL',
         status_changed_at = now()
   WHERE session_id = '${SESSION_ID}'::uuid
     AND status NOT IN ('complete','failed');
  -- Postcondition: final status must be 'failed'.
  -- Catches zero-row UPDATE (already 'failed' is acceptable;
  -- any other final status is not).
  SELECT status
    INTO v_status
    FROM private.upload_sessions
   WHERE session_id = '${SESSION_ID}'::uuid;
  IF v_status IS DISTINCT FROM 'failed' THEN
    RAISE EXCEPTION
      'Partial teardown: session % final status=%, expected failed',
      '${SESSION_ID}'::uuid, v_status;
  END IF;
END;
\$partial\$;

COMMIT;
" 2>&1 | tee -a "${LOG}" \
          && log "CLEANUP PASS: DB partial teardown (session failed; no media object)" \
          || { log "CLEANUP FAIL: DB partial teardown transaction failed or rolled back"; _cleanup_fail=1; }
      fi
    fi
  fi

  if [[ "${_cleanup_fail}" -ne 0 ]]; then
    SMOKE_FAILED=1
  fi

  # Log redaction assertion — runs before hashing.
  # Checks for patterns that indicate a secret value leaked into the log.
  # Values protected by design (never passed to log()):
  #   presigned_url, ACCESS_TOKEN, UPLOAD_TOKEN, CRON_SECRET,
  #   R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, DB_URL
  # Values intentionally logged (not credentials):
  #   ORIG_KEY, DISPLAY_KEY (R2 object paths; session UUIDs)
  log ""
  log "--- Log redaction check ---"
  local _redact_fail=0
  # JWTs begin with eyJ (base64url-encoded {"alg":...} header)
  if grep -q 'eyJ' "${LOG}"; then
    log "REDACTION FAIL: log contains JWT pattern (eyJ...)"
    _redact_fail=1
  fi
  # Presigned URL signature params
  if grep -qiE 'X-Amz-Signature=|X-Amz-Credential=' "${LOG}"; then
    log "REDACTION FAIL: log contains presigned URL signature params"
    _redact_fail=1
  fi
  if [[ "${_redact_fail}" -eq 0 ]]; then
    log "REDACTION PASS: no JWT or presigned URL signature params in log"
  else
    log "TEST FAIL: log contains forbidden values — do not use this log as evidence"
    SMOKE_FAILED=1
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

# ---------------------------------------------------------------------------
# Env preflight
# ---------------------------------------------------------------------------

for _v in ACCESS_TOKEN CASE_ID DB_URL CRON_SECRET \
          R2_ENDPOINT R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY; do
  [[ -n "${!_v:-}" ]] || { echo "FAIL: ${_v} not set" >&2; exit 1; }
done
R2_BUCKET="${R2_BUCKET:-forkensics-dev-media}"

if [[ ${#R2_ACCESS_KEY_ID} -ne 32 ]]; then
  echo "FAIL: R2_ACCESS_KEY_ID length ${#R2_ACCESS_KEY_ID} — expected 32" >&2; exit 1
fi
if [[ ${#R2_SECRET_ACCESS_KEY} -ne 64 ]]; then
  echo "FAIL: R2_SECRET_ACCESS_KEY length ${#R2_SECRET_ACCESS_KEY} — expected 64" >&2; exit 1
fi

log "=== Step B Phase 2 Smoke Test — $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
log "CASE_ID:   ${CASE_ID}"
log "R2_BUCKET: ${R2_BUCKET}"
log "Credential lengths: R2_ACCESS_KEY_ID=${#R2_ACCESS_KEY_ID}  R2_SECRET_ACCESS_KEY=${#R2_SECRET_ACCESS_KEY}"
log ""

# ---------------------------------------------------------------------------
# Fixture preflight
# ---------------------------------------------------------------------------

log "--- Fixture preflight ---"
[[ -f "${FIXTURE}" ]] || { fail "Fixture not found: ${FIXTURE}"; exit 1; }

_actual_size=$(stat -c%s "${FIXTURE}" 2>/dev/null \
               || stat -f%z "${FIXTURE}" 2>/dev/null \
               || echo 0)
if [[ "${_actual_size}" -ne "${FIXTURE_SIZE}" ]]; then
  fail "Fixture size mismatch: expected ${FIXTURE_SIZE}, got ${_actual_size}"
  exit 1
fi

_actual_sha256=$(shasum -a 256 "${FIXTURE}" | cut -d' ' -f1)
if [[ "${_actual_sha256}" != "${FIXTURE_SHA256}" ]]; then
  fail "Fixture SHA-256 mismatch: expected ${FIXTURE_SHA256}, got ${_actual_sha256}"
  exit 1
fi
log "TEST PASS: fixture ${FIXTURE} — ${FIXTURE_SIZE} bytes, SHA-256 verified"

# ---------------------------------------------------------------------------
# Account / case preflight (D-0 checks repeated here as a guard)
# ---------------------------------------------------------------------------

log ""
log "--- Account / case preflight ---"

# 1. Smoke account exists
_uploader_id=$(psql "${DB_URL}" -t -A -c \
  "SELECT id FROM auth.users WHERE email = '${SMOKE_EMAIL}' LIMIT 1;" \
  2>/dev/null || true)
[[ -n "${_uploader_id}" ]] \
  || { fail "Smoke account not found in auth.users: ${SMOKE_EMAIL}"; exit 1; }
log "TEST PASS: auth.users — smoke account present"

# 2. Active, onboarded, non-suspended profile
_profile_ok=$(psql "${DB_URL}" -t -A -c \
  "SELECT 1 FROM public.profiles \
   WHERE id = '${_uploader_id}'::uuid \
     AND is_active = true \
     AND onboarding_complete = true \
     AND is_suspended = false \
   LIMIT 1;" \
  2>/dev/null || true)
[[ "${_profile_ok}" == "1" ]] \
  || { fail "Smoke account has no active/onboarded/unsuspended profile"; exit 1; }
log "TEST PASS: profiles — is_active, onboarding_complete, not suspended"

# 3. Draft case owned by smoke account with media_object_id IS NULL
_case_check=$(psql "${DB_URL}" -t -A -c \
  "SELECT state, media_object_id \
   FROM public.cases \
   WHERE id = '${CASE_ID}'::uuid \
     AND poster_id = '${_uploader_id}'::uuid \
   LIMIT 1;" \
  2>/dev/null || true)
_case_state=$(echo "${_case_check}" | cut -d'|' -f1)
_case_media=$(echo "${_case_check}" | cut -d'|' -f2)
[[ "${_case_state}" == "draft" ]] \
  || { fail "Case ${CASE_ID} state='${_case_state}' (expected draft), or not owned by smoke account"; exit 1; }
[[ -z "${_case_media}" ]] \
  || { fail "Case ${CASE_ID} has media_object_id='${_case_media}' — must be NULL before test run"; exit 1; }
log "TEST PASS: case ${CASE_ID} — draft, owned by smoke account, media_object_id IS NULL"

# 4. Zero active sessions for smoke account
_active=$(psql "${DB_URL}" -t -A -c \
  "SELECT COUNT(*) FROM private.upload_sessions \
   WHERE uploader_id = '${_uploader_id}'::uuid \
     AND status IN ('pending','processing','sanitized');" \
  2>/dev/null || true)
[[ "${_active}" == "0" ]] \
  || { fail "Smoke account has ${_active} active session(s) — clean up before running"; exit 1; }
log "TEST PASS: upload_sessions — 0 active sessions for smoke account"

# ---------------------------------------------------------------------------
# D-3: E2E upload flow
# ---------------------------------------------------------------------------

log ""
log "=== D-3: E2E upload flow ==="

# ── D-3 Step 1: POST upload-authorize ────────────────────────────────────────
log ""
log "--- D-3 Step 1: POST upload-authorize ---"

_auth_file=$(mktemp /tmp/forkensics-smoke-XXXXXX)
chmod 0600 "${_auth_file}"
_TEMP_FILES+=("${_auth_file}")

_auth_http=$(curl -s -o "${_auth_file}" -w "%{http_code}" \
  -X POST "${AUTHORIZE_URL}" \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"case_id\":\"${CASE_ID}\",\"content_type\":\"image/jpeg\",\"declared_size_bytes\":${FIXTURE_SIZE}}")

log "HTTP status: ${_auth_http}"
if [[ "${_auth_http}" != "200" ]]; then
  _err=$(python3 -c \
    "import json; d=json.load(open('${_auth_file}')); print(d.get('error',{}).get('code','unknown'))" \
    2>/dev/null || echo "(non-JSON)")
  fail "upload-authorize: expected 200, got ${_auth_http} (error code: ${_err})"
  exit 1
fi

# Parse — presigned_url and upload_token are NOT logged (credential/temp HMAC signature).
PRESIGNED_URL=$(python3 -c \
  "import json; d=json.load(open('${_auth_file}')); print(d['presigned_url'])" \
  2>/dev/null || true)
UPLOAD_TOKEN=$(python3 -c \
  "import json; d=json.load(open('${_auth_file}')); print(d['upload_token'])" \
  2>/dev/null || true)
EXPIRES_AT=$(python3 -c \
  "import json; d=json.load(open('${_auth_file}')); print(d['expires_at'])" \
  2>/dev/null || true)
rm -f "${_auth_file}"

[[ -n "${PRESIGNED_URL}" ]] || { fail "presigned_url missing from response"; exit 1; }
[[ -n "${UPLOAD_TOKEN}"  ]] || { fail "upload_token missing from response";  exit 1; }
[[ -n "${EXPIRES_AT}"    ]] || { fail "expires_at missing from response";    exit 1; }
log "TEST PASS: response shape — presigned_url ✓  upload_token ✓  expires_at ✓"

# Extract R2 object path and session UUID.
# SESSION_ID is set here — before PUT — so the EXIT handler can clean up the
# DB session even if the PUT or upload-complete step fails.
_uuid_re='[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}'
ORIG_KEY=$(echo "${PRESIGNED_URL}" | grep -oE "originals/${_uuid_re}" || true)
[[ -n "${ORIG_KEY}" ]] \
  || { fail "presigned_url key does not match originals/<uuid-v4>"; exit 1; }
_session_uuid="${ORIG_KEY#originals/}"
SESSION_ID="${_session_uuid}"   # set immediately — teardown works even if PUT/complete fails
DISPLAY_KEY="display/${_session_uuid}.webp"
log "TEST PASS: R2 key format — ${ORIG_KEY}"
log "SESSION_ID (from R2 key): ${SESSION_ID}"
log "Expected display key: ${DISPLAY_KEY}"

# ── D-3 Step 2: PUT fixture to R2 ─────────────────────────────────────────────
log ""
log "--- D-3 Step 2: PUT fixture to R2 ---"

_put_status=$(curl -s -o /dev/null -w "%{http_code}" \
  -X PUT "${PRESIGNED_URL}" \
  -H "Content-Type: image/jpeg" \
  -H "Content-Length: ${FIXTURE_SIZE}" \
  --data-binary "@${FIXTURE}")

log "PUT HTTP status: ${_put_status}"
if [[ "${_put_status}" == "200" ]]; then
  log "TEST PASS: PUT to R2"
else
  fail "PUT expected 200, got ${_put_status}"
  exit 1
fi

# ── D-3 Step 3: POST upload-complete ──────────────────────────────────────────
log ""
log "--- D-3 Step 3: POST upload-complete ---"

_cmp_file=$(mktemp /tmp/forkensics-smoke-XXXXXX)
chmod 0600 "${_cmp_file}"
_TEMP_FILES+=("${_cmp_file}")

_cmp_http=$(curl -s -o "${_cmp_file}" -w "%{http_code}" \
  -X POST "${COMPLETE_URL}" \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"upload_token\":\"${UPLOAD_TOKEN}\"}")

# Clear upload token immediately — not needed again, not logged.
unset UPLOAD_TOKEN

log "HTTP status: ${_cmp_http}"
if [[ "${_cmp_http}" != "200" ]]; then
  _err=$(python3 -c \
    "import json; d=json.load(open('${_cmp_file}')); print(d.get('error',{}).get('code','unknown'))" \
    2>/dev/null || echo "(non-JSON)")
  fail "upload-complete: expected 200, got ${_cmp_http} (error code: ${_err})"
  exit 1
fi

_resp_status=$(python3 -c \
  "import json; d=json.load(open('${_cmp_file}')); print(d.get('status',''))" \
  2>/dev/null || true)
MEDIA_OBJECT_ID=$(python3 -c \
  "import json; d=json.load(open('${_cmp_file}')); print(d.get('media_object_id',''))" \
  2>/dev/null || true)
rm -f "${_cmp_file}"

log "Response body.status: ${_resp_status}"
log "media_object_id: ${MEDIA_OBJECT_ID}"

if [[ "${_resp_status}" == "pending_review" ]]; then
  log "TEST PASS: upload-complete body.status = pending_review"
else
  fail "upload-complete: expected body.status='pending_review', got '${_resp_status}'"
  exit 1
fi
if [[ -n "${MEDIA_OBJECT_ID}" && "${MEDIA_OBJECT_ID}" != "None" ]]; then
  log "TEST PASS: upload-complete media_object_id present"
else
  fail "upload-complete: media_object_id missing from response"
  exit 1
fi

# ── D-3 Step 4: DB assertions ─────────────────────────────────────────────────
log ""
log "--- D-3 Step 4: DB assertions ---"

# Verify that SESSION_ID (derived from R2 key) matches the DB record.
log "session_id (from R2 key): ${SESSION_ID}"
_db_session_id=$(psql "${DB_URL}" -t -A -c \
  "SELECT session_id FROM private.upload_sessions \
   WHERE media_object_id = '${MEDIA_OBJECT_ID}'::uuid \
   LIMIT 1;" \
  2>/dev/null || true)
log "session_id (from DB lookup): ${_db_session_id}"
if [[ "${_db_session_id}" == "${SESSION_ID}" ]]; then
  log "TEST PASS: session_id consistent — R2 key UUID matches DB"
else
  fail "session_id mismatch: R2 key gave '${SESSION_ID}', DB gave '${_db_session_id}'"
fi

# upload_sessions.status = complete
_sess_status=$(psql "${DB_URL}" -t -A -c \
  "SELECT status FROM private.upload_sessions \
   WHERE session_id = '${SESSION_ID}'::uuid;" \
  2>/dev/null || true)
log "upload_sessions.status: ${_sess_status}"
if [[ "${_sess_status}" == "complete" ]]; then
  log "TEST PASS: upload_sessions.status = complete"
else
  fail "upload_sessions: expected status='complete', got '${_sess_status}'"
fi

# media_objects.status = pending_review
_media_status=$(psql "${DB_URL}" -t -A -c \
  "SELECT status FROM public.media_objects \
   WHERE id = '${MEDIA_OBJECT_ID}'::uuid;" \
  2>/dev/null || true)
log "media_objects.status: ${_media_status}"
if [[ "${_media_status}" == "pending_review" ]]; then
  log "TEST PASS: media_objects.status = pending_review"
else
  fail "media_objects: expected status='pending_review', got '${_media_status}'"
fi

# private.media_storage_keys — re_encoded_storage_key and sha256_hash
_msk_row=$(psql "${DB_URL}" -t -A -c \
  "SELECT re_encoded_storage_key, sha256_hash \
   FROM private.media_storage_keys \
   WHERE media_object_id = '${MEDIA_OBJECT_ID}'::uuid;" \
  2>/dev/null || true)
if [[ -z "${_msk_row}" ]]; then
  fail "media_storage_keys: no row for media_object_id=${MEDIA_OBJECT_ID}"
else
  _msk_key=$(echo "${_msk_row}" | cut -d'|' -f1)
  _msk_sha=$(echo "${_msk_row}" | cut -d'|' -f2)
  log "re_encoded_storage_key: ${_msk_key}"
  if [[ "${_msk_key}" == "${DISPLAY_KEY}" ]]; then
    log "TEST PASS: media_storage_keys.re_encoded_storage_key = ${DISPLAY_KEY}"
  else
    fail "media_storage_keys: re_encoded_storage_key='${_msk_key}', expected '${DISPLAY_KEY}'"
  fi
  if [[ "${_msk_sha}" =~ ^[0-9a-f]{64}$ ]]; then
    log "TEST PASS: media_storage_keys.sha256_hash is 64-char hex"
  else
    fail "media_storage_keys: sha256_hash '${_msk_sha}' is not 64 lowercase hex chars"
  fi
fi

# cases.media_object_id = our media object (set by finalize_upload_session)
_case_media_after=$(psql "${DB_URL}" -t -A -c \
  "SELECT media_object_id FROM public.cases WHERE id = '${CASE_ID}'::uuid;" \
  2>/dev/null || true)
log "cases.media_object_id after complete: ${_case_media_after}"
if [[ "${_case_media_after}" == "${MEDIA_OBJECT_ID}" ]]; then
  log "TEST PASS: cases.media_object_id = ${MEDIA_OBJECT_ID}"
else
  fail "cases: expected media_object_id='${MEDIA_OBJECT_ID}', got '${_case_media_after}'"
fi

if [[ "${SMOKE_FAILED}" -eq 0 ]]; then
  log ""
  log "=== D-3: PASS ==="
else
  log ""
  log "=== D-3: FAIL ==="
fi

# ---------------------------------------------------------------------------
# D-4: upload-cleanup-worker auth gate
# ---------------------------------------------------------------------------

log ""
log "=== D-4: upload-cleanup-worker auth gate ==="

_d4_fail=0

# D-4a: missing header → 401
log ""
log "--- D-4a: missing X-Forkensics-Cron-Secret → expect 401 ---"
_d4a_status=$(curl -s -o /dev/null -w "%{http_code}" \
  -X POST "${CLEANUP_URL}")
log "HTTP status: ${_d4a_status}"
if [[ "${_d4a_status}" == "401" ]]; then
  log "TEST PASS: D-4a — missing secret → 401"
else
  fail "D-4a: expected 401, got ${_d4a_status}"
  _d4_fail=1
fi

# D-4b: wrong secret → 401
log ""
log "--- D-4b: wrong X-Forkensics-Cron-Secret → expect 401 ---"
_d4b_status=$(curl -s -o /dev/null -w "%{http_code}" \
  -X POST "${CLEANUP_URL}" \
  -H "X-Forkensics-Cron-Secret: this-is-not-the-secret")
log "HTTP status: ${_d4b_status}"
if [[ "${_d4b_status}" == "401" ]]; then
  log "TEST PASS: D-4b — wrong secret → 401"
else
  fail "D-4b: expected 401, got ${_d4b_status}"
  _d4_fail=1
fi

# D-4c: correct secret → 200.
# Secret written to chmod-0600 temp file; registered in _TEMP_FILES immediately;
# passed via curl --config so the value never appears in process args or logs;
# file deleted before response body is read.
log ""
log "--- D-4c: correct X-Forkensics-Cron-Secret → expect 200 ---"

_d4c_cfg=$(mktemp /tmp/forkensics-smoke-XXXXXX)
chmod 0600 "${_d4c_cfg}"
_TEMP_FILES+=("${_d4c_cfg}")            # registered immediately — EXIT handler covers early exits
printf 'header = "X-Forkensics-Cron-Secret: %s"\n' "${CRON_SECRET}" > "${_d4c_cfg}"
unset CRON_SECRET                        # not needed again

_d4c_file=$(mktemp /tmp/forkensics-smoke-XXXXXX)
chmod 0600 "${_d4c_file}"
_TEMP_FILES+=("${_d4c_file}")

_d4c_status=$(curl -s -o "${_d4c_file}" -w "%{http_code}" \
  -X POST "${CLEANUP_URL}" \
  -H "Content-Type: application/json" \
  -d '{}' \
  --config "${_d4c_cfg}")

rm -f "${_d4c_cfg}"    # secret config deleted immediately after curl returns

log "HTTP status: ${_d4c_status}"
_d4c_body_status=$(python3 -c \
  "import json; d=json.load(open('${_d4c_file}')); print(d.get('status',''))" \
  2>/dev/null || true)
rm -f "${_d4c_file}"
log "Response body.status: ${_d4c_body_status}"

if [[ "${_d4c_status}" == "200" ]]; then
  log "TEST PASS: D-4c — correct secret → 200"
else
  fail "D-4c: expected 200, got ${_d4c_status}"
  _d4_fail=1
fi
if [[ "${_d4c_body_status}" == "ok" ]]; then
  log "TEST PASS: D-4c — body.status = ok"
else
  fail "D-4c: expected body.status='ok', got '${_d4c_body_status}'"
  _d4_fail=1
fi

if [[ "${_d4_fail}" -eq 0 ]]; then
  log ""
  log "=== D-4: PASS ==="
else
  log ""
  log "=== D-4: FAIL ==="
fi
