#!/opt/homebrew/bin/bash
# tools/image-spike/gate2b-run-r15.sh — Gate 2B Rev 15 hosted test runner
# DISPOSABLE — Gate 2B only. Execute only after three-party §1.2 sign-off.
#
# Sequence: deploy → 30 s propagation → H-1 cold → H-2 warm (+ H-2b retry) → H-3 C-REJECT
#           → best-effort telemetry → delete → verify → verdict
#
# Usage: PROJECT_REF=hkfrbdpedrxmbsawnbpr ANON_KEY=<jwt> \
#          /opt/homebrew/bin/bash tools/image-spike/gate2b-run-r15.sh
#
# ANON_KEY is never written to disk, echoed, or logged.
# Exits 0 on full PASS; exits 1 on any FAIL, INCONCLUSIVE, or cleanup failure.

set -uo pipefail

# ── Bash 5 guard ──────────────────────────────────────────────────────────────
[[ "${BASH_VERSINFO[0]}" -ge 5 ]] \
  || { echo "FATAL: bash 5+ required (run with /opt/homebrew/bin/bash)" >&2; exit 1; }

# ── Environment validation ────────────────────────────────────────────────────
APPROVED_PROJECT_REF="hkfrbdpedrxmbsawnbpr"
[[ -n "${PROJECT_REF:-}" ]] \
  || { echo "FATAL: PROJECT_REF not set" >&2; exit 1; }
[[ "$PROJECT_REF" == "$APPROVED_PROJECT_REF" ]] \
  || { echo "FATAL: PROJECT_REF must be '$APPROVED_PROJECT_REF'" >&2; exit 1; }
[[ -n "${ANON_KEY:-}" ]] \
  || { echo "FATAL: ANON_KEY not set" >&2; exit 1; }

# ── JWT preflight ─────────────────────────────────────────────────────────────
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

# ── Paths ─────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WASM_SRC="$REPO_ROOT/tools/image-spike/magick.wasm"
WASM_DST="$REPO_ROOT/supabase/functions/_shared/magick.wasm"
CONFIG="$REPO_ROOT/supabase/config.toml"
SPIKE_DIR="$REPO_ROOT/supabase/functions/image-spike"
IMG_DIR="$REPO_ROOT/tools/image-spike/test-images-r15"
FIXTURES_PY="$SCRIPT_DIR/gate2b-fixtures-r14.py"
VERIFY_IN_PY="$SCRIPT_DIR/gate2b-verify-input-metadata.py"

TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RESULTS_DIR="$REPO_ROOT/tools/image-spike/gate2b-evidence-r15-${TIMESTAMP}"
OUT_DIR="$RESULTS_DIR/responses"
RESULTS_MD="$RESULTS_DIR/gate2b-results.md"
FUNC_URL="https://${PROJECT_REF}.supabase.co/functions/v1/image-spike"

# ── State ─────────────────────────────────────────────────────────────────────
CLEANUP_RAN=false
REMOTE_CLEANUP_REQUIRED=false
WASM_COPIED=false
CONFIG_PATCHED=false
REMOTE_DELETE_FAILED=false
GATE2B_PASS=true
FAIL_REASONS=()

# ── Helpers ───────────────────────────────────────────────────────────────────
fail() {
  GATE2B_PASS=false
  FAIL_REASONS+=("$*")
  echo "FAILURE: $*" >&2
}

results_append() { printf '%s\n' "$*" >> "$RESULTS_MD"; }

bool_field() {
  # $1 = json file path, $2 = field name
  jq -r --arg f "$2" \
    'if has($f) and (.[$f]|type)=="boolean" then (.[$f]|tostring) else "MISSING" end' \
    "$1" 2>/dev/null || echo "PARSE_ERROR"
}

is_valid_uuid() {
  echo "$1" | grep -qiE \
    '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
}

# ── Cleanup ───────────────────────────────────────────────────────────────────
cleanup() {
  [[ "$CLEANUP_RAN" == "true" ]] && return
  CLEANUP_RAN=true
  local trigger="${1:-EXIT}"
  echo "" >&2; echo "=== Gate 2B Rev 15 Cleanup (trigger: $trigger) ===" >&2
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
c = re.sub(r'\n\[functions\.image-spike\]\n(?:(?!\[)[^\n]*\n)*', '\n', c)
c = re.sub(r'\n\["\.\/functions\/_shared\/magick\.wasm"\]\n', '\n', c)
with open(p, 'w') as f:
    f.write(c)
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

# ── delete_confirmed ──────────────────────────────────────────────────────────
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

# ── invoke_r15 ────────────────────────────────────────────────────────────────
# Sends one request; records response to OUT_DIR.
# Outputs: LAST_HTTP LAST_JSON_FILE LAST_ISOLATE_ID
# Returns: 0 = HTTP 200, 2 = HTTP 546, 1 = other error
LAST_HTTP=""
LAST_JSON_FILE=""
LAST_ISOLATE_ID=""

invoke_r15() {
  local label="$1" img_file="$2" content_type="$3"
  local out="$OUT_DIR/${label}.json"
  local hdr="$OUT_DIR/${label}.headers"
  LAST_HTTP=""; LAST_JSON_FILE="$out"; LAST_ISOLATE_ID=""

  echo ""; echo "--- $label ---"
  local curl_w
  curl_w=$(curl -s -o "$out" -D "$hdr" -w '%{http_code}' \
    --max-time 120 -X POST "${FUNC_URL}?label=${label}" \
    -H "Authorization: Bearer $ANON_KEY" \
    -H "Content-Type: $content_type" \
    --data-binary "@$img_file" 2>/dev/null)
  local curl_exit=$?
  LAST_HTTP="$curl_w"

  echo "  curl_exit=$curl_exit  HTTP=$LAST_HTTP"
  results_append ""; results_append "### $label"
  results_append "HTTP=$LAST_HTTP  curl_exit=$curl_exit"

  if [[ $curl_exit -ne 0 ]]; then
    fail "$label: curl exit $curl_exit"; return 1; fi

  if [[ "$LAST_HTTP" == "546" ]]; then
    local exec_id
    exec_id=$(grep -i '^x-deno-execution-id:' "$hdr" 2>/dev/null \
      | awk '{print $2}' | tr -d '\r' | head -1 || true)
    results_append "x-deno-execution-id: ${exec_id:-not found}"
    results_append "sb-error-code: $(grep -i '^sb-error-code:' "$hdr" 2>/dev/null | awk '{print $2}' | tr -d '\r' || echo 'not found')"
    echo "  x-deno-execution-id: ${exec_id:-not found}"
    return 2
  fi

  if [[ "$LAST_HTTP" == "401" || "$LAST_HTTP" == "403" ]]; then
    fail "$label: HTTP $LAST_HTTP — authentication failure"; exit 1; fi

  if [[ "$LAST_HTTP" != "200" ]]; then
    fail "$label: HTTP $LAST_HTTP"; return 1; fi

  LAST_ISOLATE_ID=$(jq -r '.isolate_id // "MISSING"' "$out" 2>/dev/null || echo "MISSING")
  results_append "isolate_id: $LAST_ISOLATE_ID"
  cat "$out" | jq '{label,accepted,image_decode_started,pixel_count,isolate_id,magick_cache_hit,magick_init_called_this_request,magick_init_wall_time_ms}' 2>/dev/null || cat "$out"
  return 0
}

# ── telemetry_gate ────────────────────────────────────────────────────────────
TELEM_EXEC_ID="" TELEM_CPU="" TELEM_MEM="" TELEM_REASON=""

telemetry_gate() {
  local label="$1"
  echo ""
  echo "================================================================="
  echo "$label TELEMETRY CAPTURE"
  echo "STEP 1: Log Explorer → filter image-spike → find execution_id"
  echo "STEP 2: Search execution_id → find ShutdownEvent → extract:"
  echo "        cpu_time_used (ms), memory_used.total (bytes), reason"
  echo "Enter INCONCLUSIVE for any missing field."
  echo "================================================================="
  read -rp "$label execution_id (UUID or INCONCLUSIVE): " TELEM_EXEC_ID
  read -rp "$label cpu_time_used ms (or INCONCLUSIVE):  " TELEM_CPU
  read -rp "$label memory_used.total bytes (or INCONCLUSIVE): " TELEM_MEM
  read -rp "$label shutdown_reason (or INCONCLUSIVE):   " TELEM_REASON
  results_append "#### $label Telemetry"
  results_append "exec_id=$TELEM_EXEC_ID  cpu=${TELEM_CPU}ms  mem=${TELEM_MEM}B  reason=$TELEM_REASON"
}

# ── PREFLIGHT ─────────────────────────────────────────────────────────────────
echo "=== Gate 2B Rev 15 Preflight ==="
for tool in supabase curl jq python3 shasum deno gitleaks; do
  command -v "$tool" &>/dev/null || { echo "FATAL: $tool not found" >&2; exit 1; }
done
for f in "$WASM_SRC" "$VERIFY_IN_PY" "$FIXTURES_PY"; do
  [[ -f "$f" ]] || { echo "FATAL: file not found: $f" >&2; exit 1; }
done
[[ -d "$SPIKE_DIR" ]] || { echo "FATAL: spike dir not found: $SPIKE_DIR" >&2; exit 1; }
[[ -d "$IMG_DIR" ]]     && { echo "FATAL: IMG_DIR already exists" >&2; exit 1; }
[[ -d "$RESULTS_DIR" ]] && { echo "FATAL: RESULTS_DIR collision" >&2; exit 1; }
[[ -f "$WASM_DST" ]]    && { echo "FATAL: $WASM_DST already exists" >&2; exit 1; }
grep -q '\[functions\.image-spike\]' "$CONFIG" 2>/dev/null \
  && { echo "FATAL: [functions.image-spike] already in config.toml" >&2; exit 1; }

# Verify CANONICAL_PIXEL_LIMIT = 15500000 in index.ts
python3 - "$SPIKE_DIR/index.ts" "15500000" <<'PYEOF' \
  || { echo "FATAL: CANONICAL_PIXEL_LIMIT mismatch" >&2; exit 1; }
import sys, re
path, expected = sys.argv[1], sys.argv[2]
with open(path) as f: content = f.read()
m = re.search(r'CANONICAL_PIXEL_LIMIT\s*=\s*([\d_]+)', content)
if not m: print("FATAL: not found", file=sys.stderr); sys.exit(1)
actual = m.group(1).replace("_", "")
if actual != expected:
    print(f"FATAL: got {actual}, expected {expected}", file=sys.stderr); sys.exit(1)
print(f"CANONICAL_PIXEL_LIMIT={actual} ✓")
PYEOF

mkdir -p "$OUT_DIR"
> "$RESULTS_MD"
results_append "# Gate 2B Results — Rev 15"
results_append "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
results_append "PROJECT_REF: $PROJECT_REF"
echo "Preflight: all checks passed"

# ── GENERATE + VERIFY FIXTURES ────────────────────────────────────────────────
echo ""; echo "=== Generating fixtures ==="
mkdir -p "$IMG_DIR"
python3 "$FIXTURES_PY" "$IMG_DIR" \
  || { echo "FATAL: S-5 fixture gen failed" >&2; exit 1; }

# C-REJECT: 5001×3100 = 15,503,100 px (above 15,500,000 limit); quality=1 → small file
python3 - "$IMG_DIR/test-reject.jpg" <<'PYEOF'
import sys
from PIL import Image
Image.new("RGB", (5001, 3100), (30, 60, 90)).save(sys.argv[1], "JPEG", quality=1)
PYEOF
echo "C-REJECT fixture: 5001×3100 = 15,503,100 px"

echo ""; echo "=== Verifying fixtures ==="
results_append ""; results_append "## Fixture Preflight"

# S-5 fixture verification
s5_img="$IMG_DIR/test-S-5.jpg"
[[ -f "$s5_img" ]] || { echo "FATAL: S-5 fixture missing" >&2; exit 1; }
s5_dims=$(python3 -c "
from PIL import Image
with Image.open('$s5_img') as im: print(im.width, im.height)
" 2>/dev/null) || { echo "FATAL: cannot read S-5 dims" >&2; exit 1; }
s5_w=$(echo "$s5_dims" | awk '{print $1}')
s5_h=$(echo "$s5_dims" | awk '{print $2}')
[[ "$s5_w" == "2500" && "$s5_h" == "2000" ]] \
  || { echo "FATAL: S-5 dims ${s5_w}x${s5_h} ≠ 2500x2000" >&2; exit 1; }
s5_px=$((s5_w * s5_h))
[[ "$s5_px" == "5000000" ]] \
  || { echo "FATAL: S-5 pixel_count=$s5_px ≠ 5000000" >&2; exit 1; }
s5_sha=$(shasum -a 256 "$s5_img" | awk '{print $1}')
python3 "$VERIFY_IN_PY" jpeg "$s5_img" \
  || { echo "FATAL: S-5 metadata check failed" >&2; exit 1; }
results_append "S-5: test-S-5.jpg ${s5_w}x${s5_h}=${s5_px}px sha256=${s5_sha} ✓"
echo "PREFLIGHT S-5: ${s5_w}x${s5_h} sha256=${s5_sha} ✓"

# C-REJECT fixture verification
rej_img="$IMG_DIR/test-reject.jpg"
[[ -f "$rej_img" ]] || { echo "FATAL: C-REJECT fixture missing" >&2; exit 1; }
rej_dims=$(python3 -c "
from PIL import Image
with Image.open('$rej_img') as im: print(im.width, im.height)
" 2>/dev/null) || { echo "FATAL: cannot read C-REJECT dims" >&2; exit 1; }
rej_w=$(echo "$rej_dims" | awk '{print $1}')
rej_h=$(echo "$rej_dims" | awk '{print $2}')
rej_px=$((rej_w * rej_h))
[[ "$rej_w" == "5001" && "$rej_h" == "3100" ]] \
  || { echo "FATAL: C-REJECT dims ${rej_w}x${rej_h} ≠ 5001x3100" >&2; exit 1; }
[[ "$rej_px" -gt "15500000" ]] \
  || { echo "FATAL: C-REJECT px=$rej_px not > 15,500,000" >&2; exit 1; }
rej_sha=$(shasum -a 256 "$rej_img" | awk '{print $1}')
results_append "C-REJECT: test-reject.jpg ${rej_w}x${rej_h}=${rej_px}px sha256=${rej_sha} ✓"
echo "PREFLIGHT C-REJECT: ${rej_w}x${rej_h}=${rej_px}px ✓"

# ── WASM + CONFIG + STATIC CHECKS ────────────────────────────────────────────
cp "$WASM_SRC" "$WASM_DST"
wasm_sha=$(shasum -a 256 "$WASM_SRC" | awk '{print $1}')
[[ "$(shasum -a 256 "$WASM_DST" | awk '{print $1}')" == "$wasm_sha" ]] \
  || { echo "FATAL: WASM hash mismatch after copy" >&2; exit 1; }
WASM_COPIED=true
index_sha=$(shasum -a 256 "$SPIKE_DIR/index.ts" | awk '{print $1}')
results_append ""; results_append "## Artifact Hashes"
results_append "magick.wasm sha256: $wasm_sha"
results_append "index.ts sha256: $index_sha"

printf '\n[functions.image-spike]\nstatic_files = ["./functions/_shared/magick.wasm"]\n' >> "$CONFIG"
CONFIG_PATCHED=true

echo ""; echo "=== Static checks ==="
deno fmt --check "$SPIKE_DIR/index.ts"  || { fail "deno fmt"; exit 1; }
deno lint "$SPIKE_DIR/index.ts"         || { fail "deno lint"; exit 1; }
deno check "$SPIKE_DIR/index.ts"        || { fail "deno check"; exit 1; }
gitleaks detect --source "$REPO_ROOT" --config "$REPO_ROOT/.gitleaks.toml" 2>/dev/null \
  || { fail "gitleaks"; exit 1; }
echo "Static checks: all passed"
results_append "Static checks: deno fmt ✓  deno lint ✓  deno check ✓  gitleaks ✓"

# ── THREE-PARTY APPROVAL GATE ─────────────────────────────────────────────────
echo ""
echo "================================================================="
echo "THREE-PARTY APPROVAL GATE"
echo "index.ts sha256: $index_sha"
echo "Deployment target: $PROJECT_REF (forkensics-dev)"
echo "This will deploy image-spike to the hosted Edge Runtime."
echo "================================================================="
read -rp "Type YES to confirm three-party §1.2 approval and proceed: " _confirm
[[ "$_confirm" == "YES" ]] || { echo "Deployment aborted." >&2; exit 1; }
results_append "Three-party approval: YES"

# ── DEPLOY ────────────────────────────────────────────────────────────────────
echo ""; echo "=== Deploying image-spike ==="
lo=$(supabase functions list --project-ref "$PROJECT_REF" 2>/dev/null); le=$?
[[ $le -eq 0 ]] || { fail "pre-deploy list failed ($le)"; exit 1; }
printf '%s' "$lo" | grep -q "image-spike" \
  && { fail "image-spike already exists on remote"; exit 1; }
REMOTE_CLEANUP_REQUIRED=true
dout=$(supabase functions deploy image-spike \
  --project-ref "$PROJECT_REF" --debug 2>&1)
de=$?
echo "$dout"
[[ $de -eq 0 ]] || { fail "deploy failed (exit $de)"; exit 1; }
results_append ""; results_append "## Deploy"
results_append "deploy exit: $de"
# Extract bundle size from --debug output
braw=$(python3 - "$dout" <<'PYEOF'
import sys, re
m = re.search(r'(?:script|bundle) size:\s*([0-9]+(?:\.[0-9]+)?)\s*(MiB|MB)\b',
              sys.argv[1], re.IGNORECASE)
if m: print(m.group(1) + " " + m.group(2))
PYEOF
)
[[ -n "$braw" ]] || { fail "bundle size not found in --debug output"; exit 1; }
python3 - "$braw" <<'PYEOF' || { fail "bundle $braw > 20 MB"; exit 1; }
import sys, math
p = sys.argv[1].split(); n, u = float(p[0]), p[1].upper()
mb = n * 1.048576 if u == "MIB" else n
if not (math.isfinite(mb) and mb >= 0): print("FAIL"); sys.exit(1)
if mb > 20: print(f"FAIL: {sys.argv[1]} = {mb:.2f} MB > 20 MB"); sys.exit(1)
print(f"bundle: {sys.argv[1]} = {mb:.2f} MB ≤ 20 MB ✓")
PYEOF
results_append "bundle: $braw"
echo "Deploy: complete"

# ── PRE-H-1 PROPAGATION DELAY ─────────────────────────────────────────────────
# 30-second fixed delay: no requests to image-spike during this window.
# Allows the hosted runtime to finish registering the deployment before H-1.
echo ""; echo "Waiting 30 seconds for deployment propagation (no image-spike requests) ..."
sleep 30
echo "Propagation delay complete — proceeding to H-1"

# ── H-1: Cold S-5 ────────────────────────────────────────────────────────────
echo ""; echo "=== H-1: Cold S-5 ==="
results_append ""; results_append "## H-1: Cold S-5"
invoke_r15 "H-1" "$s5_img" "image/jpeg"
h1_exit=$?
if [[ $h1_exit -eq 2 ]]; then
  fail "H-1: HTTP 546 — lazy init insufficient; WASM initialization still exceeds hosted CPU budget"
  results_append "H-1: FAIL — 546"
  echo ""
  echo "H-1 returned 546. Mandatory telemetry capture:"
  telemetry_gate "H-1"
  exit 1
fi
[[ $h1_exit -eq 0 ]] || { fail "H-1: non-200 response"; exit 1; }

# Assertions
h1_accepted=$(bool_field "$LAST_JSON_FILE" "accepted")
h1_decode=$(bool_field "$LAST_JSON_FILE" "image_decode_started")
h1_pc=$(jq -r '.pixel_count // 0' "$LAST_JSON_FILE" 2>/dev/null)
h1_cache_hit=$(bool_field "$LAST_JSON_FILE" "magick_cache_hit")
h1_init_called=$(bool_field "$LAST_JSON_FILE" "magick_init_called_this_request")
h1_init_ms=$(jq -r '.magick_init_wall_time_ms // "MISSING"' "$LAST_JSON_FILE" 2>/dev/null)
isolate_id_h1="$LAST_ISOLATE_ID"

[[ "$h1_accepted" == "true" ]] \
  || { fail "H-1: accepted=$h1_accepted ≠ true"; }
[[ "$h1_decode" == "true" ]] \
  || { fail "H-1: image_decode_started=$h1_decode ≠ true"; }
[[ "$h1_pc" == "5000000" ]] \
  || { fail "H-1: pixel_count=$h1_pc ≠ 5000000"; }
[[ "$h1_cache_hit" == "false" ]] \
  || { fail "H-1: magick_cache_hit=$h1_cache_hit ≠ false"; }
[[ "$h1_init_called" == "true" ]] \
  || { fail "H-1: magick_init_called_this_request=$h1_init_called ≠ true"; }
is_valid_uuid "$isolate_id_h1" \
  || { fail "H-1: isolate_id '$isolate_id_h1' not a valid UUID"; }

results_append "H-1: accepted=$h1_accepted  cache_hit=$h1_cache_hit  init_called=$h1_init_called  init_ms=$h1_init_ms  isolate_id=$isolate_id_h1"
[[ "$GATE2B_PASS" == "true" ]] && echo "H-1: PASS ✓  isolate_id=$isolate_id_h1  init_ms=$h1_init_ms"

# ── H-1 OPERATOR CONFIRMATION — handler_invoked log (Rev 15 §4.3) ─────────────
# §4.3 requires explicit confirmation that the handler_invoked log entry is
# visible in the Dashboard for the H-1 request. This gate is mandatory.
echo ""
echo "=== H-1 Operator Confirmation Required (Rev 15 §4.3) ==="
echo "Open Supabase Dashboard → Edge Functions → image-spike → Logs."
echo "Locate the H-1 invocation (isolate_id=$isolate_id_h1) and confirm:"
echo "  1. Log entry for H-1 is present"
echo "  2. The 'handler_invoked' message is visible"
echo "  3. No WORKER_RESOURCE_LIMIT error is logged for H-1"
echo "Record the execution_time_ms displayed in the dashboard as evidence."
echo ""
read -r -p "Is 'handler_invoked' visible in the H-1 dashboard log? [y/N]: " _h1_log_confirm
[[ "$_h1_log_confirm" =~ ^[Yy]$ ]] \
  || { fail "H-1: operator did not confirm handler_invoked log visibility (Rev 15 §4.3)"; exit 1; }
results_append "H-1 operator confirmation (Rev 15 §4.3): handler_invoked log visible — YES"
echo "H-1 log confirmation: OK ✓"

# ── H-2: Warm S-5 (with H-2b retry) ─────────────────────────────────────────
echo ""; echo "=== H-2: Warm S-5 ==="
results_append ""; results_append "## H-2: Warm S-5"
invoke_r15 "H-2" "$s5_img" "image/jpeg"
h2_exit=$?
if [[ $h2_exit -eq 2 ]]; then
  fail "H-2: HTTP 546 — warm pass failed; production is not viable"
  results_append "H-2: FAIL — 546"
  echo ""
  echo "H-2 returned 546. Mandatory telemetry capture:"
  telemetry_gate "H-2"
  exit 1
fi
[[ $h2_exit -eq 0 ]] || { fail "H-2: non-200 response"; exit 1; }

h2_accepted=$(bool_field "$LAST_JSON_FILE" "accepted")
[[ "$h2_accepted" == "true" ]] \
  || { fail "H-2: accepted=$h2_accepted ≠ true"; }

h2_cache_hit=$(bool_field "$LAST_JSON_FILE" "magick_cache_hit")
h2_init_called=$(bool_field "$LAST_JSON_FILE" "magick_init_called_this_request")
isolate_id_h2="$LAST_ISOLATE_ID"
results_append "H-2: isolate_id=$isolate_id_h2  cache_hit=$h2_cache_hit  init_called=$h2_init_called"

if [[ "$isolate_id_h2" == "$isolate_id_h1" ]]; then
  # Same isolate — must have cache hit
  [[ "$h2_cache_hit" == "true" ]] \
    || { fail "H-2: same isolate but magick_cache_hit=$h2_cache_hit ≠ true"; }
  [[ "$h2_init_called" == "false" ]] \
    || { fail "H-2: magick_init_called_this_request=$h2_init_called ≠ false"; }
  results_append "H-2: PASS (path a — same isolate, cache hit confirmed)"
  [[ "$GATE2B_PASS" == "true" ]] && echo "H-2: PASS ✓ (path a — same isolate)"
else
  # Different isolate — retry as H-2b
  echo ""
  echo "H-2 landed on a different isolate (H-2 $isolate_id_h2 ≠ H-1 $isolate_id_h1)."
  echo "Executing H-2b retry on the new isolate ..."
  results_append "H-2: different isolate from H-1 — executing H-2b retry"

  invoke_r15 "H-2b" "$s5_img" "image/jpeg"
  h2b_exit=$?
  if [[ $h2b_exit -eq 2 ]]; then
    fail "H-2b: HTTP 546"
    results_append "H-2b: FAIL — 546"
    echo ""; echo "H-2b returned 546. Mandatory telemetry capture:"
    telemetry_gate "H-2b"
    exit 1
  fi
  [[ $h2b_exit -eq 0 ]] || { fail "H-2b: non-200 response"; exit 1; }

  h2b_accepted=$(bool_field "$LAST_JSON_FILE" "accepted")
  [[ "$h2b_accepted" == "true" ]] \
    || { fail "H-2b: accepted=$h2b_accepted ≠ true"; }

  h2b_cache_hit=$(bool_field "$LAST_JSON_FILE" "magick_cache_hit")
  h2b_init_called=$(bool_field "$LAST_JSON_FILE" "magick_init_called_this_request")
  isolate_id_h2b="$LAST_ISOLATE_ID"
  results_append "H-2b: isolate_id=$isolate_id_h2b  cache_hit=$h2b_cache_hit  init_called=$h2b_init_called"

  if [[ "$isolate_id_h2b" == "$isolate_id_h2" && "$h2b_cache_hit" == "true" ]]; then
    [[ "$h2b_init_called" == "false" ]] \
      || { fail "H-2b: magick_init_called_this_request=$h2b_init_called ≠ false"; }
    results_append "H-2b: PASS (path b — new isolate cache hit confirmed)"
    [[ "$GATE2B_PASS" == "true" ]] && echo "H-2b: PASS ✓ (path b — new isolate warmed)"
  else
    # INCONCLUSIVE — isolate routing outside function control
    results_append "H-2b: INCONCLUSIVE — isolate routing prevented cache verification"
    results_append "  (isolate_id_h2b=$isolate_id_h2b  isolate_id_h2=$isolate_id_h2  cache_hit=$h2b_cache_hit)"
    echo ""
    echo "H-2b: INCONCLUSIVE — isolate routing prevented cache verification."
    echo "This is outside the function's control; not recorded as architectural FAIL."
    GATE2B_PASS=false
    FAIL_REASONS+=("H-2/H-2b: INCONCLUSIVE — isolate routing prevented cache verification")
  fi
fi

# ── H-3: C-REJECT ────────────────────────────────────────────────────────────
echo ""; echo "=== H-3: C-REJECT ==="
results_append ""; results_append "## H-3: C-REJECT"
invoke_r15 "H-3" "$rej_img" "image/jpeg"
h3_exit=$?
if [[ $h3_exit -eq 2 ]]; then
  fail "H-3: HTTP 546 — C-REJECT should not reach WASM; something is wrong"
  results_append "H-3: FAIL — 546"
  echo ""; echo "H-3 returned 546. Mandatory telemetry capture:"
  telemetry_gate "H-3"
  exit 1
fi
[[ $h3_exit -eq 0 ]] || { fail "H-3: non-200 response"; exit 1; }

h3_accepted=$(bool_field "$LAST_JSON_FILE" "accepted")
h3_decode=$(bool_field "$LAST_JSON_FILE" "image_decode_started")
h3_reason=$(jq -r '.reason // "MISSING"' "$LAST_JSON_FILE" 2>/dev/null)
h3_init_called=$(bool_field "$LAST_JSON_FILE" "magick_init_called_this_request")

[[ "$h3_accepted" == "false" ]] \
  || { fail "H-3: accepted=$h3_accepted ≠ false"; }
[[ "$h3_decode" == "false" ]] \
  || { fail "H-3: image_decode_started=$h3_decode ≠ false"; }
[[ "$h3_reason" == "pre_decode_rejected" ]] \
  || { fail "H-3: reason=$h3_reason ≠ pre_decode_rejected"; }
[[ "$h3_init_called" == "false" ]] \
  || { fail "H-3: magick_init_called_this_request=$h3_init_called ≠ false"; }

results_append "H-3: accepted=$h3_accepted  reason=$h3_reason  init_called=$h3_init_called ✓"
[[ "$GATE2B_PASS" == "true" || "$h3_init_called" == "false" ]] \
  && echo "H-3: PASS ✓  (magick_init_called_this_request=false confirmed)"

# ── TELEMETRY — H-1 best-effort ──────────────────────────────────────────────
echo ""
echo "================================================================="
echo "H-1 TELEMETRY (best-effort — ShutdownEvent may not yet be available)"
echo "If isolate has not yet recycled, enter INCONCLUSIVE for all fields."
echo "Telemetry informs whether cold-start init+processing fits 2 s CPU budget."
echo "================================================================="
read -rp "Capture H-1 telemetry now? [y/N]: " _telem_yn
if [[ "${_telem_yn,,}" == "y" ]]; then
  telemetry_gate "H-1"
  results_append "H-1 best-effort telemetry: exec_id=$TELEM_EXEC_ID  cpu=$TELEM_CPU  mem=$TELEM_MEM  reason=$TELEM_REASON"
else
  echo "H-1 telemetry deferred (retrieve from Log Explorer manually if needed)."
  results_append "H-1 best-effort telemetry: deferred"
fi

# ── DELETE + VERIFY ───────────────────────────────────────────────────────────
echo ""; echo "=== Deleting image-spike ==="
delete_confirmed "final" || exit 1

# ── FINAL VERDICT ─────────────────────────────────────────────────────────────
echo ""; echo "================================================================="
results_append ""; results_append "## Final Verdict"
results_append "isolate_id_h1: $isolate_id_h1"

if [[ "$GATE2B_PASS" == "true" ]]; then
  echo "Gate 2B Rev 15: PASS"
  results_append "Verdict: PASS"
  results_append "H-1 cold init confirmed (magick_cache_hit=false, magick_init_called_this_request=true)"
  results_append "Warm cache confirmed (path a or b per H-2/H-2b retry protocol)"
  results_append "C-REJECT pre-decode path confirmed (magick_init_called_this_request=false)"
else
  echo "Gate 2B Rev 15: FAIL"
  results_append "Verdict: FAIL"
  results_append "Failures:"
  for r in "${FAIL_REASONS[@]}"; do
    echo "  - $r"; results_append "  - $r"
  done
fi
echo "Results: $RESULTS_MD"
echo "================================================================="
[[ "$GATE2B_PASS" == "true" ]] || exit 1
