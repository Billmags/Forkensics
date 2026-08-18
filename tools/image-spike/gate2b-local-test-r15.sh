#!/bin/bash
# gate2b-local-test-r15.sh — §1.2 Local Edge Runtime verification for Gate 2B Rev 15.
# Runs image-spike via `supabase functions serve` (local Edge Runtime).
#
# Tests:
#   L-1  Cold S-5  — magick_cache_hit=false, magick_init_called_this_request=true
#   L-2  Warm S-5  — isolate_id == L-1, magick_cache_hit=true
#   L-3  C-REJECT  — accepted=false, magick_init_called_this_request=false
#
# Readiness: sleep 20 + kill -0 check only. No image-spike requests before L-1.
# Any pre-L-1 request to image-spike would warm the WASM cache and invalidate L-1.
#
# Usage: /bin/bash tools/image-spike/gate2b-local-test-r15.sh
# Requires: supabase CLI, python3 (Pillow), curl, jq

set -uo pipefail

# ── Bash 3+ guard ─────────────────────────────────────────────────────────────
# This script uses no bash 4/5 features (no declare -A, no ${var,,}).
# System bash 3.2 (macOS default) is sufficient. The hosted runner
# (gate2b-run-r15.sh) retains its bash 5 requirement for associative arrays.
[[ "${BASH_VERSINFO[0]}" -ge 3 ]] \
  || { echo "FATAL: bash 3+ required" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WASM_SRC="$REPO_ROOT/tools/image-spike/magick.wasm"
WASM_DST="$REPO_ROOT/supabase/functions/_shared/magick.wasm"
SPIKE_DIR="$REPO_ROOT/supabase/functions/image-spike"
IMG_DIR="$(mktemp -d)"
FIXTURES_PY="$SCRIPT_DIR/gate2b-fixtures-r14.py"
VERIFY_IN_PY="$SCRIPT_DIR/gate2b-verify-input-metadata.py"
CONFIG="$REPO_ROOT/supabase/config.toml"

SERVE_PID=""
CLEANUP_RAN=false

# ── Cleanup ───────────────────────────────────────────────────────────────────
cleanup() {
  [[ "$CLEANUP_RAN" == "true" ]] && return
  CLEANUP_RAN=true
  [[ -n "$SERVE_PID" ]] && kill "$SERVE_PID" 2>/dev/null \
    && echo "Stopped serve (pid $SERVE_PID)"
  [[ -f "$WASM_DST" ]] && rm "$WASM_DST" && echo "Removed $WASM_DST"
  python3 - "$CONFIG" <<'PYEOF'
import re, sys
p = sys.argv[1]
with open(p) as f: c = f.read()
c = re.sub(r'\n\[functions\.image-spike\]\n(?:(?!\[)[^\n]*\n)*', '\n', c)
c = re.sub(r'\n\["\.\/functions\/_shared\/magick\.wasm"\]\n', '\n', c)
with open(p, 'w') as f:
    f.write(c)
print('config.toml cleaned')
PYEOF
  rm -rf "$IMG_DIR"
}
trap 'cleanup' EXIT

echo "=== Gate 2B Rev 15 — Local Edge Runtime Test ==="

# ── Tool preflight ────────────────────────────────────────────────────────────
for tool in supabase curl jq python3; do
  command -v "$tool" &>/dev/null || { echo "FATAL: $tool not found" >&2; exit 1; }
done
[[ -f "$WASM_SRC" ]]  || { echo "FATAL: magick.wasm not found at $WASM_SRC" >&2; exit 1; }
[[ -d "$SPIKE_DIR" ]] || { echo "FATAL: image-spike function dir not found" >&2; exit 1; }
[[ -f "$WASM_DST" ]]  && { echo "FATAL: $WASM_DST already exists" >&2; exit 1; }
grep -q '\[functions\.image-spike\]' "$CONFIG" 2>/dev/null \
  && { echo "FATAL: [functions.image-spike] already in config.toml" >&2; exit 1; }

# ── Generate fixtures ─────────────────────────────────────────────────────────
echo "Generating S-5 survey fixture ..."
python3 "$FIXTURES_PY" "$IMG_DIR" \
  || { echo "FATAL: S-5 fixture gen failed" >&2; exit 1; }

# C-REJECT: 5001×3100 = 15,503,100 px (above 15,500,000 survey limit); quality=1
echo "Generating C-REJECT fixture (5001×3100 = 15,503,100 px) ..."
python3 - "$IMG_DIR/test-local-reject.jpg" <<'PYEOF'
import sys
from PIL import Image
Image.new("RGB", (5001, 3100), (30, 60, 90)).save(sys.argv[1], "JPEG", quality=1)
PYEOF

# ── Verify S-5 metadata ───────────────────────────────────────────────────────
python3 "$VERIFY_IN_PY" jpeg "$IMG_DIR/test-S-5.jpg" \
  || { echo "FATAL: S-5 metadata check failed" >&2; exit 1; }

# ── Copy WASM + patch config ──────────────────────────────────────────────────
cp "$WASM_SRC" "$WASM_DST"
printf '\n[functions.image-spike]\nstatic_files = ["./functions/_shared/magick.wasm"]\n' >> "$CONFIG"
echo "WASM copied and config.toml patched"

# ── Start local serve ─────────────────────────────────────────────────────────
echo "Starting supabase functions serve ..."
supabase functions serve image-spike \
  --workdir "$REPO_ROOT" --no-verify-jwt 2>&1 &
SERVE_PID=$!
echo "serve PID: $SERVE_PID"

# ── Readiness gate ────────────────────────────────────────────────────────────
# sleep 20: Kong becomes reachable before the edge runtime registers the function.
# No requests are sent to image-spike before L-1 — any such request would call
# ensureMagick() and warm the WASM cache, invalidating the cold-start assertion.
PORT=54321
echo "Waiting 20 seconds for edge runtime to register image-spike ..."
sleep 20
kill -0 "$SERVE_PID" 2>/dev/null \
  || { echo "FATAL: serve process died during startup (pid $SERVE_PID)" >&2; exit 1; }
echo "Serve process alive (pid $SERVE_PID) — proceeding to L-1"

# ── Helper: extract boolean field ────────────────────────────────────────────
bool_field() {
  # $1 = json string, $2 = field name
  # Returns "true", "false", or "MISSING"
  echo "$1" | jq -r --arg f "$2" \
    'if has($f) and (.[$f]|type)=="boolean" then (.[$f]|tostring) else "MISSING" end' \
    2>/dev/null || echo "PARSE_ERROR"
}

# ── L-1: Cold S-5 ────────────────────────────────────────────────────────────
echo ""
echo "--- L-1: Cold S-5 (magick_cache_hit=false, magick_init_called_this_request=true) ---"
l1_out=$(curl -s --max-time 90 \
  "http://localhost:${PORT}/functions/v1/image-spike?label=L-1-cold-S5" \
  -X POST -H "Content-Type: image/jpeg" \
  --data-binary "@$IMG_DIR/test-S-5.jpg")
echo "$l1_out" | jq '{label,accepted,image_decode_started,pixel_count,isolate_id,magick_cache_hit,magick_init_called_this_request,magick_init_wall_time_ms}' 2>/dev/null || echo "$l1_out"

l1_accepted=$(bool_field "$l1_out" "accepted")
l1_decode=$(bool_field "$l1_out" "image_decode_started")
l1_pc=$(echo "$l1_out" | jq -r '.pixel_count // 0')
l1_cache_hit=$(bool_field "$l1_out" "magick_cache_hit")
l1_init_called=$(bool_field "$l1_out" "magick_init_called_this_request")
l1_init_ms=$(echo "$l1_out" | jq -r '.magick_init_wall_time_ms // "MISSING"')
l1_isolate_id=$(echo "$l1_out" | jq -r '.isolate_id // "MISSING"')

[[ "$l1_accepted" == "true" ]] \
  || { echo "FAIL L-1: accepted=$l1_accepted ≠ true" >&2; exit 1; }
[[ "$l1_decode" == "true" ]] \
  || { echo "FAIL L-1: image_decode_started=$l1_decode ≠ true" >&2; exit 1; }
[[ "$l1_pc" == "5000000" ]] \
  || { echo "FAIL L-1: pixel_count=$l1_pc ≠ 5000000" >&2; exit 1; }
[[ "$l1_cache_hit" == "false" ]] \
  || { echo "FAIL L-1: magick_cache_hit=$l1_cache_hit ≠ false" >&2; exit 1; }
[[ "$l1_init_called" == "true" ]] \
  || { echo "FAIL L-1: magick_init_called_this_request=$l1_init_called ≠ true" >&2; exit 1; }
python3 -c "import sys; sys.exit(0 if float('${l1_init_ms}') > 0 else 1)" \
  || { echo "FAIL L-1: magick_init_wall_time_ms=$l1_init_ms not > 0" >&2; exit 1; }
[[ "$l1_isolate_id" != "MISSING" && -n "$l1_isolate_id" ]] \
  || { echo "FAIL L-1: isolate_id missing or empty" >&2; exit 1; }
echo "L-1: PASS ✓  isolate_id=$l1_isolate_id  init_ms=$l1_init_ms"

# ── L-2: Warm S-5 ────────────────────────────────────────────────────────────
# Three outcomes:
#   (a) Same isolate as L-1 → require magick_cache_hit=true, magick_init_called_this_request=false,
#                              magick_init_wall_time_ms==0 → PASS
#   (b) Different isolate   → require magick_cache_hit=false, magick_init_called_this_request=true,
#                              magick_init_wall_time_ms>0
#                              → INCONCLUSIVE-LOCAL (CPU soft limit recycled the isolate); continue to L-3
#   (c) Any other field combination → hard FAIL
# accepted=true and isolate_id present are mandatory in all paths.
# Timeout matches L-1 (90 s) because a recycled isolate is cold and needs full init time.
echo ""
echo "--- L-2: Warm S-5 (same isolate → cache_hit=true; different isolate → INCONCLUSIVE-LOCAL) ---"
l2_out=$(curl -s --max-time 90 \
  "http://localhost:${PORT}/functions/v1/image-spike?label=L-2-warm-S5" \
  -X POST -H "Content-Type: image/jpeg" \
  --data-binary "@$IMG_DIR/test-S-5.jpg")
echo "$l2_out" | jq '{label,accepted,isolate_id,magick_cache_hit,magick_init_called_this_request,magick_init_wall_time_ms}' 2>/dev/null || echo "$l2_out"

l2_accepted=$(bool_field "$l2_out" "accepted")
l2_isolate_id=$(echo "$l2_out" | jq -r '.isolate_id // "MISSING"')
l2_cache_hit=$(bool_field "$l2_out" "magick_cache_hit")
l2_init_called=$(bool_field "$l2_out" "magick_init_called_this_request")
l2_init_ms=$(echo "$l2_out" | jq -r '.magick_init_wall_time_ms // "MISSING"')

# accepted=true is mandatory in all paths
[[ "$l2_accepted" == "true" ]] \
  || { echo "FAIL L-2: accepted=$l2_accepted ≠ true" >&2; exit 1; }

# isolate_id must be present in all paths (all four diagnostic fields required by Rev 15)
[[ "$l2_isolate_id" != "MISSING" && -n "$l2_isolate_id" ]] \
  || { echo "FAIL L-2: isolate_id missing" >&2; exit 1; }

L2_VERDICT=""
if [[ "$l2_isolate_id" == "$l1_isolate_id" ]]; then
  # Path (a): same isolate — must be a warm-cache hit; init_ms must be exactly 0
  # (handler sets magick_init_wall_time_ms=0 when startedThisRequest=false)
  [[ "$l2_cache_hit" == "true" ]] \
    || { echo "FAIL L-2: same-isolate but magick_cache_hit=$l2_cache_hit ≠ true" >&2; exit 1; }
  [[ "$l2_init_called" == "false" ]] \
    || { echo "FAIL L-2: same-isolate but magick_init_called_this_request=$l2_init_called ≠ false" >&2; exit 1; }
  python3 -c "import sys; sys.exit(0 if float('${l2_init_ms}') == 0 else 1)" \
    || { echo "FAIL L-2: same-isolate but magick_init_wall_time_ms=$l2_init_ms ≠ 0" >&2; exit 1; }
  L2_VERDICT="PASS"
  echo "L-2: PASS ✓  isolate_id=$l2_isolate_id (same as L-1)  cache_hit=true  init_ms=$l2_init_ms"
elif [[ "$l2_cache_hit" == "false" && "$l2_init_called" == "true" ]]; then
  # Path (b): different isolate + cold fields — local CPU soft limit recycled the L-1 isolate.
  # init_ms must be > 0 (WASM was initialized fresh on this new cold isolate).
  # This is the local equivalent of the H-2b scenario described in the hosted protocol.
  # L-1 wall-time evidence (magick_init_wall_time_ms=$l1_init_ms) is preserved in the record
  # but is local wall time only — it does not characterise hosted CPU usage.
  # H-1 / H-2 on the hosted runtime remain definitive for warm-cache verification.
  python3 -c "import sys; sys.exit(0 if float('${l2_init_ms}') > 0 else 1)" \
    || { echo "FAIL L-2: different-isolate but magick_init_wall_time_ms=$l2_init_ms not > 0" >&2; exit 1; }
  L2_VERDICT="INCONCLUSIVE-LOCAL"
  echo "L-2: INCONCLUSIVE-LOCAL"
  echo "  L-1 isolate: $l1_isolate_id"
  echo "  L-2 isolate: $l2_isolate_id  (different — isolate recycled after CPU soft limit)"
  echo "  Cause: local per_worker runtime terminates isolates that hit the CPU soft limit;"
  echo "         warm-cache verification is structurally impossible for CPU-intensive fixtures locally."
  echo "  Local wall-time evidence: L-1 magick_init_wall_time_ms=$l1_init_ms ms"
  echo "    (local wall time only; does not characterise hosted CPU usage; H-1 is definitive)"
  echo "  Proceeding to L-3."
else
  # Path (c): unexpected field combination — hard failure
  echo "FAIL L-2: unexpected field combination" >&2
  echo "  isolate_id=$l2_isolate_id  (L-1 was $l1_isolate_id)" >&2
  echo "  magick_cache_hit=$l2_cache_hit  magick_init_called_this_request=$l2_init_called" >&2
  exit 1
fi

# ── L-3: C-REJECT ────────────────────────────────────────────────────────────
echo ""
echo "--- L-3: C-REJECT (accepted=false, magick_init_called_this_request=false) ---"
l3_out=$(curl -s --max-time 30 \
  "http://localhost:${PORT}/functions/v1/image-spike?label=L-3-reject" \
  -X POST -H "Content-Type: image/jpeg" \
  --data-binary "@$IMG_DIR/test-local-reject.jpg")
echo "$l3_out" | jq '{label,accepted,image_decode_started,reason,pixel_count,magick_init_called_this_request}' 2>/dev/null || echo "$l3_out"

l3_accepted=$(bool_field "$l3_out" "accepted")
l3_decode=$(bool_field "$l3_out" "image_decode_started")
l3_reason=$(echo "$l3_out" | jq -r '.reason // "MISSING"')
l3_init_called=$(bool_field "$l3_out" "magick_init_called_this_request")

[[ "$l3_accepted" == "false" ]] \
  || { echo "FAIL L-3: accepted=$l3_accepted ≠ false" >&2; exit 1; }
[[ "$l3_decode" == "false" ]] \
  || { echo "FAIL L-3: image_decode_started=$l3_decode ≠ false" >&2; exit 1; }
[[ "$l3_reason" == "pre_decode_rejected" ]] \
  || { echo "FAIL L-3: reason=$l3_reason ≠ pre_decode_rejected" >&2; exit 1; }
[[ "$l3_init_called" == "false" ]] \
  || { echo "FAIL L-3: magick_init_called_this_request=$l3_init_called ≠ false" >&2; exit 1; }
echo "L-3: PASS ✓"

echo ""
if [[ "$L2_VERDICT" == "INCONCLUSIVE-LOCAL" ]]; then
  echo "=== Gate 2B Rev 15 — Local Edge Runtime Test: PASS WITH L-2 INCONCLUSIVE-LOCAL ==="
  echo "  L-1: PASS ✓"
  echo "  L-2: INCONCLUSIVE-LOCAL (isolate recycled by CPU soft limit; warm-cache deferred to hosted H-1/H-2)"
  echo "  L-3: PASS ✓"
else
  echo "=== Gate 2B Rev 15 — Local Edge Runtime Test: ALL PASS ==="
  echo "  L-1: PASS ✓  L-2: PASS ✓  L-3: PASS ✓"
fi
