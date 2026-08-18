#!/usr/bin/env bash
# tools/image-spike/gate2b-run-r14.sh — Gate 2B Rev 14 test runner
# DISPOSABLE — Gate 2B only. Execute only after three-party approval of Rev 14.
#
# Usage: PROJECT_REF=hkfrbdpedrxmbsawnbpr ANON_KEY=yyy bash tools/image-spike/gate2b-run-r14.sh
# ANON_KEY is never written to disk, echoed, or logged.
# Exits 0 on full PASS; exits 1 on FAIL, INCONCLUSIVE, or no viable ceiling.

set -uo pipefail

# ---------------------------------------------------------------------------
# Environment validation
# ---------------------------------------------------------------------------
APPROVED_PROJECT_REF="hkfrbdpedrxmbsawnbpr"
[[ -n "${PROJECT_REF:-}" ]] \
  || { echo "FATAL: PROJECT_REF not set" >&2; exit 1; }
[[ "$PROJECT_REF" == "$APPROVED_PROJECT_REF" ]] \
  || { echo "FATAL: PROJECT_REF must be '$APPROVED_PROJECT_REF'" >&2; exit 1; }
[[ -n "${ANON_KEY:-}" ]] \
  || { echo "FATAL: ANON_KEY not set" >&2; exit 1; }

# ---------------------------------------------------------------------------
# JWT preflight
# ---------------------------------------------------------------------------
python3 - <<'PYEOF' || { echo "FATAL: ANON_KEY failed JWT preflight" >&2; exit 1; }
import sys, base64, json, os, time

def b64url_decode(s: str) -> bytes:
    s += "=" * ((-len(s)) % 4)
    return base64.urlsafe_b64decode(s)

key = os.environ.get("ANON_KEY", "")
ref = os.environ.get("PROJECT_REF", "")
parts = key.split(".")
if len(parts) != 3:
    print(f"FATAL: {len(parts)} JWT segment(s), expected 3", file=sys.stderr); sys.exit(1)
if not parts[2]:
    print("FATAL: JWT signature segment empty", file=sys.stderr); sys.exit(1)
try:
    header = json.loads(b64url_decode(parts[0]))
except Exception as e:
    print(f"FATAL: JWT header decode: {e}", file=sys.stderr); sys.exit(1)
if header.get("alg") != "HS256":
    print(f"FATAL: alg='{header.get('alg')}', expected 'HS256'", file=sys.stderr); sys.exit(1)
try:
    payload = json.loads(b64url_decode(parts[1]))
except Exception as e:
    print(f"FATAL: JWT payload decode: {e}", file=sys.stderr); sys.exit(1)
if payload.get("role") != "anon":
    print(f"FATAL: role='{payload.get('role')}', expected 'anon'", file=sys.stderr); sys.exit(1)
jwt_ref = payload.get("ref", "")
if not jwt_ref:
    print("FATAL: JWT payload missing 'ref'", file=sys.stderr); sys.exit(1)
if jwt_ref != ref:
    print(f"FATAL: JWT ref='{jwt_ref}' != PROJECT_REF='{ref}'", file=sys.stderr); sys.exit(1)
exp = payload.get("exp")
if exp is None:
    print("FATAL: JWT payload missing 'exp'", file=sys.stderr); sys.exit(1)
try:
    exp_int = int(exp)
except (TypeError, ValueError):
    print(f"FATAL: exp non-integer: {exp!r}", file=sys.stderr); sys.exit(1)
if exp_int <= int(time.time()):
    print(f"FATAL: JWT expired (exp={exp_int})", file=sys.stderr); sys.exit(1)
print(f"JWT preflight: HS256, role=anon, ref={jwt_ref} ✓")
PYEOF

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WASM_SRC="$REPO_ROOT/tools/image-spike/magick.wasm"
WASM_DST="$REPO_ROOT/supabase/functions/_shared/magick.wasm"
CONFIG="$REPO_ROOT/supabase/config.toml"
SPIKE_DIR="$REPO_ROOT/supabase/functions/image-spike"
IMG_DIR="$REPO_ROOT/tools/image-spike/test-images-r14"
FIXTURES_PY="$SCRIPT_DIR/gate2b-fixtures-r14.py"
VERIFY_OUT_PY="$SCRIPT_DIR/gate2b-verify-metadata.py"
VERIFY_IN_PY="$SCRIPT_DIR/gate2b-verify-input-metadata.py"

TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RESULTS_DIR="$REPO_ROOT/tools/image-spike/gate2b-evidence-r14-${TIMESTAMP}"
OUT_DIR="$RESULTS_DIR/responses"
RESULTS_MD="$RESULTS_DIR/gate2b-results.md"
FUNC_URL="https://${PROJECT_REF}.supabase.co/functions/v1/image-spike"

MEM_THRESHOLD_MIB=200
CPU_THRESHOLD_MS=1500
SURVEY_PIXEL_LIMIT=15500000

declare -a SURVEY_FIXTURES=(
  "S-5|test-S-5.jpg|2500|2000|5000000|4000000|5500000"
  "S-8|test-S-8.jpg|4000|2000|8000000|6500000|9000000"
  "S-10|test-S-10.jpg|4000|2500|10000000|8500000|10000000"
  "S-12|test-S-12.jpg|4000|3000|12000000|9000000|10000000"
  "S-15|test-S-15.jpg|5000|3000|15000000|9000000|10000000"
)
declare -A SURVEY_DIMS=(
  [5]="2500 2000 5000000" [8]="4000 2000 8000000"
  [10]="4000 2500 10000000" [12]="4000 3000 12000000"
  [15]="5000 3000 15000000"
)
declare -A SURVEY_BANDS=(
  [5]="4000000 5500000" [8]="6500000 9000000"
  [10]="8500000 10000000" [12]="9000000 10000000"
  [15]="9000000 10000000"
)
declare -a SURVEY_MP_ORDER=(5 8 10 12 15)

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------
CLEANUP_RAN=false
REMOTE_CLEANUP_REQUIRED=false
WASM_COPIED=false
CONFIG_PATCHED=false
REMOTE_DELETE_FAILED=false
GATE2B_PASS=true
declare -a FAIL_REASONS=()
LAST_WALL_TIME=""
LAST_RUN_ID=""
LAST_INVOKE_546=false

declare -A SURVEY_CPU=()
declare -A SURVEY_MEM=()
declare -A SURVEY_REASON=()
declare -A SURVEY_FUNC_PASS=()
declare -A SURVEY_TELEM_OK=()

# Global set by survey_telemetry_result — avoids subshell
SURVEY_TELEM_OUTCOME=""

CHOSEN_MP=""
CHOSEN_W=0; CHOSEN_H=0; CHOSEN_PX=0
CHOSEN_MIN_B=0; CHOSEN_MAX_B=0
REJECT_W=0; REJECT_PX=0

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
fail() {
  GATE2B_PASS=false
  FAIL_REASONS+=("$*")
  echo "FAILURE: $*" >&2
}
results_append() { printf '%s\n' "$*" >> "$RESULTS_MD"; }
bool_field() {
  jq -r --arg f "$2" \
    'if has($f) and (.[$f]|type)=="boolean" then (.[$f]|tostring) else "MISSING" end' \
    "$1" 2>/dev/null || echo "PARSE_ERROR"
}
is_valid_uuid() {
  echo "$1" | grep -qiE \
    '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
}

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
cleanup() {
  [[ "$CLEANUP_RAN" == "true" ]] && return
  CLEANUP_RAN=true
  local trigger="${1:-EXIT}"
  echo "" >&2; echo "=== Gate 2B Rev 14 Cleanup (trigger: $trigger) ===" >&2
  if [[ "$REMOTE_CLEANUP_REQUIRED" == "true" ]]; then
    supabase functions delete image-spike --project-ref "$PROJECT_REF" 2>/dev/null || true
    sleep 3
    local lo le
    lo=$(supabase functions list --project-ref "$PROJECT_REF" 2>/dev/null); le=$?
    if [[ $le -ne 0 ]]; then
      echo "WARNING: functions list failed" >&2; REMOTE_DELETE_FAILED=true
    elif printf '%s' "$lo" | grep -q "image-spike"; then
      echo "WARNING: image-spike still listed — manual deletion required" >&2
      REMOTE_DELETE_FAILED=true
    else
      echo "Cleanup: remote deletion confirmed" >&2; REMOTE_CLEANUP_REQUIRED=false
    fi
  fi
  if [[ "$CONFIG_PATCHED" == "true" ]] \
     || grep -q '\[functions\.image-spike\]' "$CONFIG" 2>/dev/null; then
    python3 - "$CONFIG" <<'PYEOF'
import re, sys
p = sys.argv[1]
with open(p) as f: c = f.read()
with open(p, 'w') as f:
    f.write(re.sub(r'\n\[functions\.image-spike\]\n(?:(?!\[)[^\n]*\n)*', '\n', c))
print('config.toml cleaned', file=sys.stderr)
PYEOF
  fi
  [[ -f "$WASM_DST" ]]  && rm "$WASM_DST"     && echo "Removed: $WASM_DST" >&2
  [[ -d "$SPIKE_DIR" ]] && rm -rf "$SPIKE_DIR" && echo "Removed: $SPIKE_DIR" >&2
  [[ -d "$IMG_DIR" ]]   && rm -rf "$IMG_DIR"   && echo "Removed: $IMG_DIR" >&2
  echo "Evidence preserved in: $RESULTS_DIR" >&2
  [[ "$REMOTE_DELETE_FAILED" == "true" ]] \
    && { echo "CRITICAL: Remote deletion unconfirmed — manual action required." >&2; exit 1; }
}
trap 'cleanup EXIT' EXIT
trap 'GATE2B_PASS=false; FAIL_REASONS+=("INTERRUPTED:INT"); cleanup INT; exit 130' INT
trap 'GATE2B_PASS=false; FAIL_REASONS+=("INTERRUPTED:TERM"); cleanup TERM; exit 143' TERM

# ---------------------------------------------------------------------------
# deploy_function
# ---------------------------------------------------------------------------
deploy_function() {
  local phase="$1"
  echo ""; echo "=== Phase $phase: Deploy image-spike ==="
  local pl pe
  pl=$(supabase functions list --project-ref "$PROJECT_REF" 2>/dev/null); pe=$?
  [[ $pe -eq 0 ]] || { fail "Phase $phase: pre-deploy list failed ($pe)"; return 1; }
  printf '%s' "$pl" | grep -q "image-spike" \
    && { fail "Phase $phase: image-spike already exists on remote"; return 1; }
  REMOTE_CLEANUP_REQUIRED=true
  local dout
  dout=$(supabase functions deploy image-spike \
    --project-ref "$PROJECT_REF" --debug 2>&1)
  local de=$?
  echo "$dout"
  [[ $de -eq 0 ]] || { fail "Phase $phase: deploy failed (exit $de)"; return 1; }
  local braw
  braw=$(python3 - "$dout" <<'PYEOF'
import sys, re
m = re.search(r'(?:script|bundle) size:\s*([0-9]+(?:\.[0-9]+)?)\s*(MiB|MB)\b',
              sys.argv[1], re.IGNORECASE)
if m: print(m.group(1) + " " + m.group(2))
PYEOF
)
  [[ -n "$braw" ]] || {
    fail "Phase $phase: bundle size not found in --debug output"
    results_append "Phase $phase bundle: UNPARSEABLE"; return 1; }
  python3 - "$braw" <<'PYEOF' || { fail "Phase $phase: bundle ${braw} > 20 MB"; return 1; }
import sys, math
p = sys.argv[1].split(); n, u = float(p[0]), p[1].upper()
mb = n * 1.048576 if u == "MIB" else n
if not (math.isfinite(mb) and mb >= 0): print("FAIL"); sys.exit(1)
if mb > 20: print(f"FAIL: {sys.argv[1]} = {mb:.2f} MB > 20 MB"); sys.exit(1)
print(f"bundle: {sys.argv[1]} = {mb:.2f} MB ≤ 20 MB ✓")
PYEOF
  results_append "Phase $phase bundle: ${braw}"
}

# ---------------------------------------------------------------------------
# delete_confirmed
# ---------------------------------------------------------------------------
delete_confirmed() {
  local phase="$1"
  supabase functions delete image-spike --project-ref "$PROJECT_REF" 2>/dev/null || true
  sleep 3
  local lo le
  lo=$(supabase functions list --project-ref "$PROJECT_REF" 2>/dev/null); le=$?
  [[ $le -eq 0 ]] \
    || { fail "Phase $phase: functions list failed ($le)"; REMOTE_DELETE_FAILED=true; return 1; }
  printf '%s' "$lo" | grep -q "image-spike" \
    && { fail "Phase $phase: image-spike still listed after delete"; REMOTE_DELETE_FAILED=true; return 1; }
  echo "Phase $phase deletion: confirmed ✓"; REMOTE_CLEANUP_REQUIRED=false
}

# ---------------------------------------------------------------------------
# invoke_case
# Returns: 0 = completed; 2 = HTTP 546. Never calls fail() on 546.
# ---------------------------------------------------------------------------
invoke_case() {
  LAST_RUN_ID=""
  LAST_INVOKE_546=false

  local label="$1" filename="$2" mime="$3" exp_accepted="$4" exp_reason="$5"
  local exp_w="$6" exp_h="$7" exp_pixels="$8"
  local img="$IMG_DIR/$filename"
  local out="$OUT_DIR/${label}.json" hdr="$OUT_DIR/${label}.headers"
  local webp_out="$OUT_DIR/${label}_output.webp"
  local actual_input_size
  actual_input_size=$(wc -c < "$img" | awk '{print $1}')

  echo ""; echo "--- $label ($filename, $mime) ---"
  local curl_w
  curl_w=$(curl -s -o "$out" -D "$hdr" -w '%{http_code}\t%{time_total}' \
    --max-time 120 -X POST "${FUNC_URL}?label=${label}" \
    -H "Authorization: Bearer $ANON_KEY" \
    -H "Content-Type: $mime" --data-binary "@$img" 2>/dev/null)
  local curl_exit=$?

  local http_status wall_time req_id
  http_status=$(printf '%s' "$curl_w" | awk -F'\t' '{print $1}')
  wall_time=$(printf '%s'   "$curl_w" | awk -F'\t' '{print $2}')
  LAST_WALL_TIME="$wall_time"
  req_id=$(grep -i '^x-request-id:' "$hdr" 2>/dev/null \
    | awk '{print $2}' | tr -d '\r' | head -1 || true)

  echo "  curl_exit=$curl_exit  HTTP=$http_status  wall_time=${wall_time}s"
  results_append ""; results_append "### $label"
  results_append "curl_exit=$curl_exit  HTTP=$http_status  wall_time_s=$wall_time"
  results_append "x-request-id: ${req_id:-<not found>}"

  if [[ $curl_exit -ne 0 ]]; then
    fail "$label: curl exit $curl_exit"; results_append "FAIL: curl transport error"; return 0; fi
  if [[ "$http_status" == "546" ]]; then
    results_append "HTTP 546 — resource limit boundary"
    LAST_INVOKE_546=true; return 2
  fi
  if [[ "$http_status" == "401" || "$http_status" == "403" ]]; then
    fail "$label: HTTP $http_status — authentication failure"
    results_append "HARD FAIL: HTTP $http_status"; exit 1; fi
  if [[ "$http_status" != "200" ]]; then
    fail "$label: HTTP $http_status"; results_append "FAIL: HTTP $http_status"; return 0; fi

  local resp_label
  resp_label=$(jq -r '.label // "MISSING"' "$out" 2>/dev/null || echo "PARSE_ERROR")
  [[ "$resp_label" == "$label" ]] || fail "$label: response label='$resp_label' ≠ '$label'"

  local resp_run_id
  resp_run_id=$(jq -r '.run_id // ""' "$out" 2>/dev/null || echo "")
  LAST_RUN_ID="$resp_run_id"
  results_append "run_id: ${resp_run_id:-MISSING}"
  is_valid_uuid "$resp_run_id" || fail "$label: run_id '${resp_run_id}' not a valid UUID"

  local resp_accepted
  resp_accepted=$(bool_field "$out" "accepted")
  if [[ "$resp_accepted" == "MISSING" || "$resp_accepted" == "PARSE_ERROR" ]]; then
    fail "$label: accepted field missing"
  elif [[ "$resp_accepted" != "$exp_accepted" ]]; then
    fail "$label: accepted=$resp_accepted ≠ $exp_accepted"
  fi

  local resp_w resp_h resp_pixels
  resp_w=$(jq -r '.width // 0'         "$out" 2>/dev/null || echo 0)
  resp_h=$(jq -r '.height // 0'        "$out" 2>/dev/null || echo 0)
  resp_pixels=$(jq -r '.pixel_count // 0' "$out" 2>/dev/null || echo 0)
  [[ "$resp_w" == "$exp_w" && "$resp_h" == "$exp_h" ]] \
    || fail "$label: dimensions ${resp_w}x${resp_h} ≠ ${exp_w}x${exp_h}"
  [[ "$resp_pixels" == "$exp_pixels" ]] \
    || fail "$label: pixel_count=$resp_pixels ≠ $exp_pixels"

  local resp_decode_started
  resp_decode_started=$(bool_field "$out" "image_decode_started")
  if [[ "$resp_decode_started" == "MISSING" || "$resp_decode_started" == "PARSE_ERROR" ]]; then
    fail "$label: image_decode_started missing"
  elif [[ "$exp_accepted" == "false" && "$resp_decode_started" != "false" ]]; then
    fail "$label: image_decode_started=$resp_decode_started ≠ false"
  elif [[ "$exp_accepted" == "true" && "$resp_decode_started" != "true" ]]; then
    fail "$label: image_decode_started=$resp_decode_started ≠ true"
  fi
  results_append "image_decode_started: $resp_decode_started"

  if [[ "$exp_accepted" == "false" ]]; then
    local resp_reason
    resp_reason=$(jq -r '.reason // "MISSING"' "$out" 2>/dev/null || echo "PARSE_ERROR")
    [[ "$resp_reason" == "$exp_reason" ]] \
      || fail "$label: reason='$resp_reason' ≠ '$exp_reason'"
    results_append "accepted=false  reason=$resp_reason"; return 0
  fi

  local resp_input_size
  resp_input_size=$(jq -r '.input_size_bytes // 0' "$out" 2>/dev/null || echo 0)
  [[ "$resp_input_size" == "$actual_input_size" ]] \
    || fail "$label: input_size_bytes=$resp_input_size ≠ $actual_input_size"
  [[ "$(bool_field "$out" "metadata_clean")" == "true" ]] \
    || fail "$label: metadata_clean ≠ true"

  local resp_sha256
  resp_sha256=$(jq -r '.sha256 // ""' "$out" 2>/dev/null || echo "")
  printf '%s' "$resp_sha256" | grep -qE '^[0-9a-f]{64}$' \
    || fail "$label: sha256 format invalid"

  local resp_output_b64
  resp_output_b64=$(jq -r '.output_bytes // ""' "$out" 2>/dev/null || echo "")
  if [[ -z "$resp_output_b64" || "$resp_output_b64" == "null" ]]; then
    fail "$label: output_bytes absent"
  elif printf '%s' "$resp_output_b64" | base64 -d > "$webp_out" 2>/dev/null; then
    local decoded_size header_check actual_sha resp_output_size
    decoded_size=$(wc -c < "$webp_out" | awk '{print $1}')
    header_check=$(python3 -c "
with open('$webp_out','rb') as f: d=f.read(12)
print('valid' if d[:4]==b'RIFF' and d[8:12]==b'WEBP' else 'invalid')
" 2>/dev/null || echo "error")
    [[ "$header_check" == "valid" ]] || fail "$label: decoded output not valid WebP"
    actual_sha=$(shasum -a 256 "$webp_out" | awk '{print $1}')
    [[ "$actual_sha" == "$resp_sha256" ]] \
      || fail "$label: SHA-256 mismatch (recomputed=$actual_sha)"
    resp_output_size=$(jq -r '.output_size_bytes // 0' "$out" 2>/dev/null || echo 0)
    [[ "$resp_output_size" == "$decoded_size" ]] \
      || fail "$label: output_size_bytes=$resp_output_size ≠ $decoded_size"
    python3 "$VERIFY_OUT_PY" "$webp_out" 2>&1 \
      || fail "$label: RIFF parser found metadata or malformed WebP"
  else
    fail "$label: base64 decode failed"
  fi

  results_append "sha256: $resp_sha256  wall_time_s=$wall_time"
  return 0
}

# ---------------------------------------------------------------------------
# Telemetry input capture
# ---------------------------------------------------------------------------
OK_REASONS="EventLoopCompleted EarlyDrop TerminationRequested"
RESOURCE_REASONS="Memory CPUTime WallClockTime"
TELEM_EXEC_ID="" TELEM_CPU="" TELEM_MEM="" TELEM_REASON=""

telemetry_gate() {
  local label="$1" run_id="$2"
  echo ""
  echo "================================================================="
  echo "$label TELEMETRY CAPTURE GATE"
  echo "run_id: ${run_id:-MISSING}"
  echo "STEP 1: Log Explorer → filter function_id='image-spike' → search run_id → record execution_id"
  echo "STEP 2: Search execution_id → find ShutdownEvent → extract:"
  echo "        cpu_time_used (ms), memory_used.total (bytes), reason"
  echo "Enter INCONCLUSIVE for any missing field."
  echo "================================================================="
  read -rp "$label execution_id (UUID or INCONCLUSIVE): " TELEM_EXEC_ID
  read -rp "$label cpu_time_used ms (or INCONCLUSIVE): "  TELEM_CPU
  read -rp "$label memory_used.total bytes (or INCONCLUSIVE): " TELEM_MEM
  read -rp "$label shutdown_reason (or INCONCLUSIVE): "   TELEM_REASON
}

# ---------------------------------------------------------------------------
# survey_telemetry_result — runs in PARENT SHELL (never in $()).
# Sets SURVEY_TELEM_OUTCOME to "pass", "nonviable", or "evidence_fail".
# Calls fail() only on evidence_fail.
# ---------------------------------------------------------------------------
survey_telemetry_result() {
  local label="$1"
  SURVEY_TELEM_OUTCOME=""

  results_append "#### $label Telemetry (survey)"
  results_append "exec_id: $TELEM_EXEC_ID  cpu: $TELEM_CPU  mem: $TELEM_MEM  reason: $TELEM_REASON"

  # Step 1: INCONCLUSIVE check
  if [[ "$TELEM_EXEC_ID" == "INCONCLUSIVE" || "$TELEM_CPU" == "INCONCLUSIVE" \
        || "$TELEM_MEM" == "INCONCLUSIVE" || "$TELEM_REASON" == "INCONCLUSIVE" ]]; then
    fail "$label: survey telemetry INCONCLUSIVE — evidence quality failure"
    SURVEY_TELEM_OUTCOME="evidence_fail"; return
  fi

  # Step 2: UUID validation
  if ! is_valid_uuid "$TELEM_EXEC_ID"; then
    fail "$label: execution_id '${TELEM_EXEC_ID}' not a valid UUID — evidence quality failure"
    SURVEY_TELEM_OUTCOME="evidence_fail"; return
  fi

  # Steps 3 & 4: Numeric validation of CPU and memory BEFORE reason classification
  local numeric_ok
  numeric_ok=$(python3 - "$TELEM_CPU" "$TELEM_MEM" <<'PYEOF'
import sys, math
try:
    cpu = float(sys.argv[1])
    mem = float(sys.argv[2])
except ValueError as e:
    print(f"FAIL:non-numeric:{e}"); sys.exit(0)
if not (math.isfinite(cpu) and cpu >= 0):
    print(f"FAIL:cpu-non-finite:{sys.argv[1]}"); sys.exit(0)
if not (math.isfinite(mem) and mem >= 0):
    print(f"FAIL:mem-non-finite:{sys.argv[2]}"); sys.exit(0)
print("OK")
PYEOF
  )
  if [[ "${numeric_ok%%:*}" != "OK" ]]; then
    fail "$label: telemetry field invalid — ${numeric_ok} — evidence quality failure"
    SURVEY_TELEM_OUTCOME="evidence_fail"; return
  fi

  # Step 5: Reason must be in recognized set (OK ∪ RESOURCE)
  if ! echo "$OK_REASONS $RESOURCE_REASONS" | grep -qw "${TELEM_REASON:-}"; then
    fail "$label: shutdown_reason='$TELEM_REASON' — unrecognized; cannot classify level"
    SURVEY_TELEM_OUTCOME="evidence_fail"; return
  fi

  # Step 6: Classification — all fields valid; now determine viability
  if echo "$RESOURCE_REASONS" | grep -qw "${TELEM_REASON:-}"; then
    results_append "$label: nonviable (resource-limit reason: $TELEM_REASON)"
    SURVEY_TELEM_OUTCOME="nonviable"; return
  fi

  local threshold_result
  threshold_result=$(python3 - "$TELEM_CPU" "$TELEM_MEM" "$MEM_THRESHOLD_MIB" "$CPU_THRESHOLD_MS" <<'PYEOF'
import sys, math
cpu_r, mem_r, mt, ct = sys.argv[1:]
cpu = float(cpu_r); mem = float(mem_r); mt = float(mt); ct = float(ct)
mib = mem / 1_048_576
if cpu > ct or mib > mt:
    print(f"nonviable:cpu={cpu:.0f}ms,mem={mib:.1f}MiB")
else:
    print(f"pass:cpu={cpu:.0f}ms,mem={mib:.1f}MiB")
PYEOF
  )
  if [[ "${threshold_result%%:*}" == "nonviable" ]]; then
    results_append "$label: nonviable — ${threshold_result#*:}"
    SURVEY_TELEM_OUTCOME="nonviable"
  else
    results_append "$label: pass — ${threshold_result#*:}"
    SURVEY_TELEM_OUTCOME="pass"
  fi
}

# ---------------------------------------------------------------------------
# confirmation_telemetry_result — any failure calls fail()
# ---------------------------------------------------------------------------
confirmation_telemetry_result() {
  local label="$1"
  results_append "#### $label Telemetry (confirmation)"
  results_append "exec_id: $TELEM_EXEC_ID  cpu: $TELEM_CPU  mem: $TELEM_MEM  reason: $TELEM_REASON"

  if [[ "$TELEM_EXEC_ID" == "INCONCLUSIVE" || "$TELEM_CPU" == "INCONCLUSIVE" \
        || "$TELEM_MEM" == "INCONCLUSIVE" || "$TELEM_REASON" == "INCONCLUSIVE" ]]; then
    fail "$label: confirmation telemetry INCONCLUSIVE"; return 1; fi
  is_valid_uuid "$TELEM_EXEC_ID" \
    || { fail "$label: execution_id '${TELEM_EXEC_ID}' not valid UUID"; return 1; }

  local numeric_ok
  numeric_ok=$(python3 - "$TELEM_CPU" "$TELEM_MEM" <<'PYEOF'
import sys, math
try:
    cpu = float(sys.argv[1]); mem = float(sys.argv[2])
except ValueError as e:
    print(f"FAIL:{e}"); sys.exit(0)
if not (math.isfinite(cpu) and cpu >= 0) or not (math.isfinite(mem) and mem >= 0):
    print("FAIL:non-finite"); sys.exit(0)
print("OK")
PYEOF
  )
  [[ "${numeric_ok%%:*}" == "OK" ]] \
    || { fail "$label: telemetry numeric invalid — $numeric_ok"; return 1; }

  if echo "$RESOURCE_REASONS" | grep -qw "${TELEM_REASON:-}"; then
    fail "$label: shutdown_reason='$TELEM_REASON' — resource-limit exceeded"; return 1; fi
  if ! echo "$OK_REASONS" | grep -qw "${TELEM_REASON:-}"; then
    fail "$label: shutdown_reason='$TELEM_REASON' — unrecognized"; return 1; fi

  python3 - "$TELEM_CPU" "$TELEM_MEM" "$MEM_THRESHOLD_MIB" "$CPU_THRESHOLD_MS" "$label" <<'PYEOF'
import sys, math
cpu_r, mem_r, mt, ct, lbl = sys.argv[1:]
cpu = float(cpu_r); mem = float(mem_r); mt = float(mt); ct = float(ct)
mib = mem / 1_048_576
print(f"cpu={cpu:.0f}ms ({'≤' if cpu<=ct else '>'}{ct:.0f}) {'✓' if cpu<=ct else 'FAIL'}")
print(f"mem={mib:.1f}MiB ({'≤' if mib<=mt else '>'}{mt:.0f}) {'✓' if mib<=mt else 'FAIL'}")
if cpu > ct or mib > mt: sys.exit(2)
print(f"{lbl}: confirmation telemetry PASS")
PYEOF
  local te=$?
  [[ $te -eq 0 ]] || { fail "$label: confirmation telemetry threshold exceeded"; return 1; }
  results_append "$label: PASS"; return 0
}

# ---------------------------------------------------------------------------
# update_pixel_limit — exactly one substitution
# ---------------------------------------------------------------------------
update_pixel_limit() {
  python3 - "$SPIKE_DIR/index.ts" "$1" <<'PYEOF' \
    || { echo "FATAL: update_pixel_limit failed" >&2; exit 1; }
import sys, re
path, limit = sys.argv[1], sys.argv[2]
with open(path) as f: content = f.read()
new, n = re.subn(r'(CANONICAL_PIXEL_LIMIT\s*=\s*)[\d_]+', rf'\g<1>{limit}', content)
if n != 1:
    print(f"FATAL: expected 1 substitution, got {n}", file=sys.stderr); sys.exit(1)
with open(path, 'w') as f: f.write(new)
print(f"CANONICAL_PIXEL_LIMIT → {limit} (1 substitution ✓)")
PYEOF
}

# ===========================================================================
# PREFLIGHT
# ===========================================================================
echo "=== Gate 2B Rev 14 Preflight ==="
for tool in supabase curl jq python3 shasum deno gitleaks; do
  command -v "$tool" &>/dev/null || { echo "FATAL: $tool not found" >&2; exit 1; }
done

REV9_EVIDENCE="$REPO_ROOT/tools/image-spike/gate2b-evidence-20260814T194105Z/gate2b-results.md"
REV9_SHA="3903f9dc08bb7edc77720911a614a9656ad97b5c9e42a04c9a50d60f3fd1bc4f"
[[ -f "$REV9_EVIDENCE" ]] || { echo "FATAL: Rev 9 evidence missing" >&2; exit 1; }
[[ "$(shasum -a 256 "$REV9_EVIDENCE" | awk '{print $1}')" == "$REV9_SHA" ]] \
  || { echo "FATAL: Rev 9 evidence SHA mismatch" >&2; exit 1; }
echo "Rev 9 evidence SHA: verified ✓"

for f in "$WASM_SRC" "$VERIFY_OUT_PY" "$VERIFY_IN_PY" "$FIXTURES_PY"; do
  [[ -f "$f" ]] || { echo "FATAL: file not found: $f" >&2; exit 1; }
done
[[ -d "$SPIKE_DIR" ]] || { echo "FATAL: spike dir not found" >&2; exit 1; }
[[ -d "$IMG_DIR" ]]     && { echo "FATAL: IMG_DIR exists" >&2; exit 1; }
[[ -d "$RESULTS_DIR" ]] && { echo "FATAL: RESULTS_DIR collision" >&2; exit 1; }
[[ -f "$WASM_DST" ]]    && { echo "FATAL: $WASM_DST exists" >&2; exit 1; }
grep -q '\[functions\.image-spike\]' "$CONFIG" 2>/dev/null \
  && { echo "FATAL: [functions.image-spike] already in config.toml" >&2; exit 1; }

python3 - "$SPIKE_DIR/index.ts" "$SURVEY_PIXEL_LIMIT" <<'PYEOF' \
  || { echo "FATAL: CANONICAL_PIXEL_LIMIT mismatch" >&2; exit 1; }
import sys, re
path, expected = sys.argv[1], sys.argv[2].replace("_", "")
with open(path) as f: content = f.read()
m = re.search(r'CANONICAL_PIXEL_LIMIT\s*=\s*([\d_]+)', content)
if not m: print("FATAL: not found", file=sys.stderr); sys.exit(1)
actual = m.group(1).replace("_", "")
if actual != expected:
    print(f"FATAL: got {actual}, expected {expected}", file=sys.stderr); sys.exit(1)
print(f"CANONICAL_PIXEL_LIMIT={actual} ✓")
PYEOF

mkdir -p "$OUT_DIR"; > "$RESULTS_MD"
results_append "# Gate 2B Results — Rev 14"
results_append "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
results_append "PROJECT_REF: $PROJECT_REF"
results_append "MEM_THRESHOLD_MIB: $MEM_THRESHOLD_MIB  CPU_THRESHOLD_MS: $CPU_THRESHOLD_MS"
echo "Preflight: all checks passed"

# ===========================================================================
# GENERATE + VERIFY SURVEY FIXTURES
# ===========================================================================
echo ""; echo "=== Generating survey fixtures ==="
python3 "$FIXTURES_PY" "$IMG_DIR" || { echo "FATAL: survey fixture gen failed" >&2; exit 1; }

echo ""; echo "=== Verifying survey fixtures ==="
results_append ""; results_append "## Fixture Preflight"
preflight_ok=true
for entry in "${SURVEY_FIXTURES[@]}"; do
  IFS="|" read -r sid filename exp_w exp_h exp_pixels min_bytes max_bytes <<< "$entry"
  img="$IMG_DIR/$filename"
  [[ -f "$img" ]] || { echo "FATAL: $img missing" >&2; exit 1; }
  byte_size=$(wc -c < "$img" | awk '{print $1}')
  sha=$(shasum -a 256 "$img" | awk '{print $1}')
  dims=$(python3 -c "
from PIL import Image
with Image.open('$img') as im: print(im.width, im.height)
" 2>/dev/null) || { echo "FATAL: cannot read dims of $img" >&2; exit 1; }
  actual_w=$(echo "$dims" | awk '{print $1}')
  actual_h=$(echo "$dims" | awk '{print $2}')
  actual_px=$((actual_w * actual_h))
  ok=true
  [[ "$actual_w" == "$exp_w" && "$actual_h" == "$exp_h" ]] \
    || { fail "PREFLIGHT $sid: dims ${actual_w}x${actual_h} ≠ ${exp_w}x${exp_h}"; ok=false; }
  [[ "$actual_px" == "$exp_pixels" ]] \
    || { fail "PREFLIGHT $sid: pixel_count $actual_px ≠ $exp_pixels"; ok=false; }
  python3 -c "import sys; sys.exit(0 if $min_bytes <= $byte_size <= $max_bytes else 1)" \
    || { fail "PREFLIGHT $sid: size $byte_size outside [$min_bytes,$max_bytes]"; ok=false; }
  [[ "$byte_size" -le 10000000 ]] \
    || { fail "PREFLIGHT $sid: size $byte_size > 10 MB upload ceiling"; ok=false; }
  python3 "$VERIFY_IN_PY" jpeg "$img" \
    || { fail "PREFLIGHT $sid: metadata families missing"; ok=false; }
  [[ "$ok" == "true" ]] || preflight_ok=false
  results_append "$sid: $filename ${byte_size}B ${actual_w}x${actual_h} sha256=${sha}"
  echo "PREFLIGHT $sid: ${byte_size}B ${actual_w}x${actual_h} $([[ "$ok" == "true" ]] && echo ✓ || echo FAIL)"
done
[[ "$preflight_ok" == "true" && "$GATE2B_PASS" == "true" ]] \
  || { echo "FATAL: fixture preflight failed" >&2; exit 1; }

# ===========================================================================
# WASM + CONFIG + STATIC CHECKS
# ===========================================================================
cp "$WASM_SRC" "$WASM_DST"
SRC_HASH=$(shasum -a 256 "$WASM_SRC" | awk '{print $1}')
[[ "$(shasum -a 256 "$WASM_DST" | awk '{print $1}')" == "$SRC_HASH" ]] \
  || { echo "FATAL: WASM hash mismatch" >&2; exit 1; }
WASM_COPIED=true
INDEX_HASH=$(shasum -a 256 "$SPIKE_DIR/index.ts" | awk '{print $1}')
results_append ""; results_append "## Hashes"
results_append "magick.wasm sha256: $SRC_HASH"
results_append "index.ts (survey) sha256: $INDEX_HASH"

printf '\n[functions.image-spike]\nstatic_files = ["./functions/_shared/magick.wasm"]\n' >> "$CONFIG"
CONFIG_PATCHED=true

deno fmt --check "$SPIKE_DIR/index.ts" || { fail "deno fmt"; exit 1; }
deno lint "$SPIKE_DIR/index.ts"        || { fail "deno lint"; exit 1; }
deno check "$SPIKE_DIR/index.ts"       || { fail "deno check"; exit 1; }
gitleaks detect --source "$REPO_ROOT" --config "$REPO_ROOT/.gitleaks.toml" 2>/dev/null \
  || { fail "gitleaks"; exit 1; }
echo "Static checks passed"

read -rp "Type YES to confirm pre-deployment three-party approval and proceed: " _confirm
[[ "$_confirm" == "YES" ]] || { echo "Deployment aborted." >&2; exit 1; }

# ===========================================================================
# SURVEY PHASES
# ===========================================================================
results_append ""; results_append "## Survey Phase Results"

for mp in "${SURVEY_MP_ORDER[@]}"; do
  phase_label="S-${mp}MP"
  read -r exp_w exp_h exp_pixels <<< "${SURVEY_DIMS[$mp]}"
  sid="S-${mp}"; filename="test-S-${mp}.jpg"

  results_append ""; results_append "### Phase $phase_label"
  echo ""; echo "=== SURVEY PHASE $phase_label ==="

  deploy_function "$phase_label" || exit 1

  pre_func_fails=${#FAIL_REASONS[@]}

  invoke_case "$sid" "$filename" "image/jpeg" "true" "" "$exp_w" "$exp_h" "$exp_pixels"
  invoke_exit=$?
  phase_run_id="$LAST_RUN_ID"; phase_wall="$LAST_WALL_TIME"

  if [[ $invoke_exit -eq 2 ]]; then
    echo "Phase $phase_label: HTTP 546 — stopping survey ascent"
    results_append "Phase $phase_label: 546 boundary — survey stopped"
    SURVEY_FUNC_PASS[$mp]="false"
    SURVEY_TELEM_OK[$mp]="false"
    SURVEY_CPU[$mp]=""; SURVEY_MEM[$mp]=""; SURVEY_REASON[$mp]="546"
    delete_confirmed "$phase_label" || exit 1
    break
  fi

  python3 -c "import sys; sys.exit(0 if float('$phase_wall') <= 30 else 1)" \
    || fail "$sid: cold wall-clock ${phase_wall}s > 30 s"
  results_append "$sid cold_wall_time_s: $phase_wall"

  post_func_fails=${#FAIL_REASONS[@]}
  if [[ $((post_func_fails - pre_func_fails)) -eq 0 ]]; then
    SURVEY_FUNC_PASS[$mp]="true"
  else
    SURVEY_FUNC_PASS[$mp]="false"
  fi

  delete_confirmed "$phase_label" || exit 1

  telemetry_gate "$sid" "$phase_run_id"

  # Call directly — NOT in $() — so fail() propagates to parent shell
  survey_telemetry_result "$sid"

  SURVEY_CPU[$mp]="${TELEM_CPU}"
  SURVEY_MEM[$mp]="${TELEM_MEM}"
  SURVEY_REASON[$mp]="${TELEM_REASON}"

  if [[ "$SURVEY_TELEM_OUTCOME" == "evidence_fail" ]]; then
    echo "FATAL: survey telemetry evidence failure at $sid — stopping run" >&2
    exit 1
  elif [[ "$SURVEY_TELEM_OUTCOME" == "pass" ]]; then
    SURVEY_TELEM_OK[$mp]="true"
  else
    SURVEY_TELEM_OK[$mp]="false"
  fi
done

# ===========================================================================
# CEILING SELECTION
# ===========================================================================
echo ""; echo "=== CEILING SELECTION ==="
results_append ""; results_append "## Ceiling Selection"

ceiling_output=$(python3 - \
  "${SURVEY_FUNC_PASS[5]:-false}"  "${SURVEY_TELEM_OK[5]:-false}"  "${SURVEY_CPU[5]:-}"  "${SURVEY_MEM[5]:-}"  "${SURVEY_REASON[5]:-}" \
  "${SURVEY_FUNC_PASS[8]:-false}"  "${SURVEY_TELEM_OK[8]:-false}"  "${SURVEY_CPU[8]:-}"  "${SURVEY_MEM[8]:-}"  "${SURVEY_REASON[8]:-}" \
  "${SURVEY_FUNC_PASS[10]:-false}" "${SURVEY_TELEM_OK[10]:-false}" "${SURVEY_CPU[10]:-}" "${SURVEY_MEM[10]:-}" "${SURVEY_REASON[10]:-}" \
  "${SURVEY_FUNC_PASS[12]:-false}" "${SURVEY_TELEM_OK[12]:-false}" "${SURVEY_CPU[12]:-}" "${SURVEY_MEM[12]:-}" "${SURVEY_REASON[12]:-}" \
  "${SURVEY_FUNC_PASS[15]:-false}" "${SURVEY_TELEM_OK[15]:-false}" "${SURVEY_CPU[15]:-}" "${SURVEY_MEM[15]:-}" "${SURVEY_REASON[15]:-}" \
  "$MEM_THRESHOLD_MIB" "$CPU_THRESHOLD_MS" <<'PYEOF'
import sys, math

args = sys.argv[1:]
MP = [5, 8, 10, 12, 15]
OK_REASONS = {"EventLoopCompleted", "EarlyDrop", "TerminationRequested"}
mt, ct = float(args[-2]), float(args[-1])
MIB = 1_048_576

survey = {}
for i, mp in enumerate(MP):
    survey[mp] = (args[i*5], args[i*5+1], args[i*5+2], args[i*5+3], args[i*5+4])

print("\nSurvey Results:")
print(f"{'MP':>4}  {'Func':>5}  {'Telem':>5}  {'CPU ms':>8}  {'Mem MiB':>8}  {'Reason':>22}  {'Viable':>7}")
print("-" * 75)

viable = []
for mp in MP:
    fp, tok, cpu_r, mem_r, reason = survey[mp]
    if fp != "true" or tok != "true":
        print(f"{mp:>4}  {fp:>5}  {tok:>5}  {'—':>8}  {'—':>8}  {reason or '—':>22}  {'NO':>7}")
        continue
    try:
        cpu = float(cpu_r); mem = float(mem_r)
    except (ValueError, TypeError):
        print(f"{mp:>4}  {fp:>5}  {tok:>5}  {'ERR':>8}  {'ERR':>8}  {reason:>22}  {'NO':>7}")
        continue
    mib = mem / MIB
    ok = (reason in OK_REASONS and cpu <= ct and mib <= mt)
    if ok:
        viable.append(mp)
    print(f"{mp:>4}  {fp:>5}  {tok:>5}  {cpu:>8.0f}  {mib:>8.1f}  {reason:>22}  {'YES' if ok else 'NO':>7}")
print("-" * 75)

if viable:
    rec = max(viable)
    print(f"\nRECOMMENDED_CEILING={rec}")
    print(f"VIABLE_LEVELS={' '.join(str(m) for m in viable)}")
else:
    print("\nRECOMMENDED_CEILING=NONE")
    print("VIABLE_LEVELS=")
PYEOF
)

echo "$ceiling_output"
results_append "$ceiling_output"

RECOMMENDED_CEILING=$(echo "$ceiling_output" | grep '^RECOMMENDED_CEILING=' \
  | cut -d= -f2 | tr -d '[:space:]')
VIABLE_LEVELS_STR=$(echo "$ceiling_output" | grep '^VIABLE_LEVELS=' \
  | cut -d= -f2 | tr -d '[:space:]')

if [[ "$RECOMMENDED_CEILING" == "NONE" || -z "$RECOMMENDED_CEILING" ]]; then
  fail "No viable ceiling found"
  results_append "CEILING SELECTION: FAIL — no viable ceiling"
  exit 1
fi

echo ""
echo "Recommended ceiling: ${RECOMMENDED_CEILING} MP  Viable: ${VIABLE_LEVELS_STR}"
read -rp "Enter ceiling MP (press Enter for ${RECOMMENDED_CEILING}): " operator_ceiling
operator_ceiling="${operator_ceiling:-$RECOMMENDED_CEILING}"

[[ "$operator_ceiling" =~ ^[0-9]+$ ]] \
  || { echo "FATAL: ceiling must be a number; got '$operator_ceiling'" >&2; exit 1; }

viable_ok=false
for vl in $VIABLE_LEVELS_STR; do
  [[ "$vl" == "$operator_ceiling" ]] && viable_ok=true
done
[[ "$viable_ok" == "true" ]] \
  || { echo "FATAL: $operator_ceiling not in VIABLE_LEVELS — requires new three-party decision" >&2; exit 1; }
[[ "$operator_ceiling" -le "$RECOMMENDED_CEILING" ]] \
  || { echo "FATAL: $operator_ceiling > recommended — requires new three-party decision" >&2; exit 1; }

CHOSEN_MP="$operator_ceiling"
read -r CHOSEN_W CHOSEN_H CHOSEN_PX <<< "${SURVEY_DIMS[$CHOSEN_MP]}"
read -r CHOSEN_MIN_B CHOSEN_MAX_B <<< "${SURVEY_BANDS[$CHOSEN_MP]}"
REJECT_W=$((CHOSEN_W + 1)); REJECT_PX=$((REJECT_W * CHOSEN_H))
results_append "Confirmed ceiling: ${CHOSEN_MP} MP (${CHOSEN_W}x${CHOSEN_H}, ${CHOSEN_PX} px)"

# ===========================================================================
# GENERATE + VERIFY CONFIRMATION FIXTURES
# ===========================================================================
python3 "$FIXTURES_PY" "$IMG_DIR" confirm \
  "$CHOSEN_W" "$CHOSEN_H" "$CHOSEN_PX" "$CHOSEN_MIN_B" "$CHOSEN_MAX_B" \
  || { echo "FATAL: confirmation fixture gen failed" >&2; exit 1; }

results_append ""; results_append "## Confirmation Fixture Preflight"
conf_ok=true

for i in 1 2 3; do
  cj="$IMG_DIR/test-C-jpeg-${i}.jpg"
  [[ -f "$cj" ]] || { echo "FATAL: $cj missing" >&2; exit 1; }
  sz=$(wc -c < "$cj" | awk '{print $1}')
  dm=$(python3 -c "
from PIL import Image
with Image.open('$cj') as im: print(im.width, im.height)
" 2>/dev/null)
  cw=$(echo "$dm" | awk '{print $1}'); ch=$(echo "$dm" | awk '{print $2}')
  ok=true
  [[ "$cw" == "$CHOSEN_W" && "$ch" == "$CHOSEN_H" ]] \
    || { fail "PREFLIGHT C-JPEG-$i: ${cw}x${ch} ≠ ${CHOSEN_W}x${CHOSEN_H}"; ok=false; }
  python3 -c "import sys; sys.exit(0 if $CHOSEN_MIN_B <= $sz <= $CHOSEN_MAX_B else 1)" \
    || { fail "PREFLIGHT C-JPEG-$i: size $sz outside [$CHOSEN_MIN_B,$CHOSEN_MAX_B]"; ok=false; }
  [[ "$sz" -le 10000000 ]] \
    || { fail "PREFLIGHT C-JPEG-$i: $sz > 10 MB"; ok=false; }
  python3 "$VERIFY_IN_PY" jpeg "$cj" \
    || { fail "PREFLIGHT C-JPEG-$i: metadata families missing"; ok=false; }
  [[ "$ok" == "true" ]] || conf_ok=false
  results_append "C-JPEG-$i: ${sz}B ${cw}x${ch}"
  echo "PREFLIGHT C-JPEG-$i: ${sz}B $([[ "$ok" == "true" ]] && echo ✓ || echo FAIL)"
done

cwebp="$IMG_DIR/test-C-webp.webp"
[[ -f "$cwebp" ]] || { echo "FATAL: $cwebp missing" >&2; exit 1; }
wsz=$(wc -c < "$cwebp" | awk '{print $1}')
wdm=$(python3 -c "
from PIL import Image
with Image.open('$cwebp') as im: print(im.width, im.height)
" 2>/dev/null)
ww=$(echo "$wdm" | awk '{print $1}'); wh=$(echo "$wdm" | awk '{print $2}')
[[ "$ww" == "$CHOSEN_W" && "$wh" == "$CHOSEN_H" ]] \
  || { fail "PREFLIGHT C-WEBP: ${ww}x${wh} ≠ ${CHOSEN_W}x${CHOSEN_H}"; conf_ok=false; }
[[ "$wsz" -le 10000000 ]] \
  || { fail "PREFLIGHT C-WEBP: $wsz > 10 MB"; conf_ok=false; }
python3 "$VERIFY_IN_PY" webp "$cwebp" \
  || { fail "PREFLIGHT C-WEBP: metadata families missing"; conf_ok=false; }
results_append "C-WEBP: ${wsz}B ${ww}x${wh}"; echo "PREFLIGHT C-WEBP: ${wsz}B ✓"

creject="$IMG_DIR/test-C-reject.jpg"
[[ -f "$creject" ]] || { echo "FATAL: $creject missing" >&2; exit 1; }
rdm=$(python3 -c "
from PIL import Image
with Image.open('$creject') as im: print(im.width, im.height)
" 2>/dev/null)
rw=$(echo "$rdm" | awk '{print $1}'); rh=$(echo "$rdm" | awk '{print $2}')
rsz=$(wc -c < "$creject" | awk '{print $1}')
[[ "$rw" == "$REJECT_W" && "$rh" == "$CHOSEN_H" ]] \
  || { fail "PREFLIGHT C-REJECT: ${rw}x${rh} ≠ ${REJECT_W}x${CHOSEN_H}"; conf_ok=false; }
[[ "$rsz" -le 500000 ]] \
  || { fail "PREFLIGHT C-REJECT: ${rsz}B > 500,000B ceiling"; conf_ok=false; }
results_append "C-REJECT: ${rw}x${rh} ${rsz}B"; echo "PREFLIGHT C-REJECT: ${rw}x${rh} ${rsz}B ✓"

[[ "$conf_ok" == "true" ]] \
  || { echo "FATAL: confirmation fixture preflight failed" >&2; exit 1; }

# ===========================================================================
# MID-RUN CEILING APPROVAL GATE
# ===========================================================================
update_pixel_limit "$CHOSEN_PX"
CONFIRM_HASH=$(shasum -a 256 "$SPIKE_DIR/index.ts" | awk '{print $1}')
results_append ""; results_append "## Confirmation Function"
results_append "CANONICAL_PIXEL_LIMIT: $CHOSEN_PX"
results_append "index.ts (confirmation) sha256: $CONFIRM_HASH"

echo ""
echo "=== MID-RUN CONFIRMATION FUNCTION APPROVAL ==="
echo "CANONICAL_PIXEL_LIMIT: $CHOSEN_PX  index.ts sha256: $CONFIRM_HASH"
read -rp "Type YES to confirm three-party approval: " _cc
[[ "$_cc" == "YES" ]] || { echo "Confirmation aborted." >&2; exit 1; }
results_append "Mid-run approval: YES"

# ===========================================================================
# CONFIRMATION PHASES C-1, C-2, C-3
# ===========================================================================
results_append ""; results_append "## Confirmation Phases — JPEG"

for i in 1 2 3; do
  clabel="C-${i}"; cfile="test-C-jpeg-${i}.jpg"; seed=$((41 + i))
  results_append ""; results_append "### Phase $clabel (seed=${seed})"
  echo ""; echo "=== CONFIRMATION PHASE $clabel ==="

  deploy_function "$clabel" || exit 1

  invoke_case "$clabel" "$cfile" "image/jpeg" "true" "" \
    "$CHOSEN_W" "$CHOSEN_H" "$CHOSEN_PX"
  inv_exit=$?
  if [[ $inv_exit -eq 2 ]]; then
    fail "$clabel: HTTP 546 — ceiling selection invalid; gate FAIL"
    delete_confirmed "$clabel" || true; exit 1
  fi
  phase_wall="$LAST_WALL_TIME"; phase_run_id="$LAST_RUN_ID"
  python3 -c "import sys; sys.exit(0 if float('$phase_wall') <= 30 else 1)" \
    || fail "$clabel: cold wall-clock ${phase_wall}s > 30 s"
  results_append "$clabel cold_wall_time_s: $phase_wall"

  delete_confirmed "$clabel" || exit 1

  telemetry_gate "$clabel" "$phase_run_id"
  confirmation_telemetry_result "$clabel" \
    || fail "$clabel: confirmation telemetry gate failed"
done

# ===========================================================================
# CONFIRMATION PHASE C-4 — WebP (cold) + Rejection (warm)
# ===========================================================================
results_append ""; results_append "## Confirmation Phase C-4 (WebP + Rejection)"
echo ""; echo "=== CONFIRMATION PHASE C-4 ==="

deploy_function "C-4" || exit 1

invoke_case "C-WEBP" "test-C-webp.webp" "image/webp" "true" "" \
  "$CHOSEN_W" "$CHOSEN_H" "$CHOSEN_PX"
if [[ $? -eq 2 ]]; then
  fail "C-WEBP: HTTP 546 — ceiling selection invalid"
  delete_confirmed "C-4" || true; exit 1
fi
webp_run_id="$LAST_RUN_ID"; webp_wall="$LAST_WALL_TIME"
python3 -c "import sys; sys.exit(0 if float('$webp_wall') <= 30 else 1)" \
  || fail "C-WEBP: cold wall-clock ${webp_wall}s > 30 s"
results_append "C-WEBP cold_wall_time_s: $webp_wall"

# C-REJECT: capture return code; 546 = hard confirmation failure; exit immediately
invoke_case "C-REJECT" "test-C-reject.jpg" "image/jpeg" "false" "pre_decode_rejected" \
  "$REJECT_W" "$CHOSEN_H" "$REJECT_PX"
reject_exit=$?
if [[ $reject_exit -eq 2 ]]; then
  fail "C-REJECT: HTTP 546 — confirmation failure"
  delete_confirmed "C-4" || true; exit 1
fi
results_append "C-REJECT wall_time_s: $LAST_WALL_TIME"

delete_confirmed "C-4" || exit 1

telemetry_gate "C-WEBP" "$webp_run_id"
confirmation_telemetry_result "C-WEBP" \
  || fail "C-WEBP: confirmation telemetry gate failed"

# ===========================================================================
# FINAL VERDICT
# ===========================================================================
echo ""; echo "================================================================="
results_append ""; results_append "## Final Verdict"
results_append "Chosen ceiling: ${CHOSEN_MP} MP (${CHOSEN_W}x${CHOSEN_H}, ${CHOSEN_PX} px)"

if [[ "$GATE2B_PASS" == "true" ]]; then
  echo "Gate 2B Rev 14: PASS"
  echo "CANONICAL_PIXEL_LIMIT: $CHOSEN_PX (${CHOSEN_MP} MP, ${CHOSEN_W}x${CHOSEN_H})"
  results_append "Verdict: PASS"
  results_append "CANONICAL_PIXEL_LIMIT: $CHOSEN_PX (${CHOSEN_MP} MP)"
else
  echo "Gate 2B Rev 14: FAIL"
  results_append "Verdict: FAIL"
  results_append "Failures:"
  for r in "${FAIL_REASONS[@]}"; do
    echo "  - $r"; results_append "  - $r"
  done
fi
echo "Results: $RESULTS_MD"
echo "================================================================="
[[ "$GATE2B_PASS" == "true" ]] || exit 1
