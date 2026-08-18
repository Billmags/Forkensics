#!/usr/bin/env bash
# gate2b-local-test-r14.sh — §1.3 Local Edge Runtime verification for Gate 2B Rev 14.
# Runs image-spike via `supabase functions serve` (local Edge Runtime).
# Tests: S-5 accepted (image_decode_started=true) + C-REJECT rejected (image_decode_started=false).
# Usage: bash tools/image-spike/gate2b-local-test-r14.sh
# Requires: supabase CLI, python3 (Pillow, piexif, numpy), curl, jq

set -uo pipefail

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

cleanup() {
  [[ "$CLEANUP_RAN" == "true" ]] && return
  CLEANUP_RAN=true
  [[ -n "$SERVE_PID" ]] && kill "$SERVE_PID" 2>/dev/null && echo "Stopped serve (pid $SERVE_PID)"
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

echo "=== Gate 2B Rev 14 — Local Edge Runtime Test ==="

for tool in supabase curl jq python3; do
  command -v "$tool" &>/dev/null || { echo "FATAL: $tool not found" >&2; exit 1; }
done
[[ -f "$WASM_SRC" ]]  || { echo "FATAL: magick.wasm not found at $WASM_SRC" >&2; exit 1; }
[[ -d "$SPIKE_DIR" ]] || { echo "FATAL: image-spike function dir not found" >&2; exit 1; }
[[ -f "$WASM_DST" ]]  && { echo "FATAL: $WASM_DST already exists" >&2; exit 1; }

echo "Generating S-5 survey fixture and C-REJECT fixture ..."
python3 "$FIXTURES_PY" "$IMG_DIR" || { echo "FATAL: survey fixture gen failed" >&2; exit 1; }

# Build a minimal C-REJECT: over the survey CANONICAL_PIXEL_LIMIT (15,500,000), quality=1
# Use 5001×3100 = 15,503,100 px; solid color at quality=1 → ~237 KB
python3 - "$IMG_DIR/test-local-reject.jpg" <<'PYEOF'
import sys
from PIL import Image
Image.new("RGB", (5001, 3100), (30, 60, 90)).save(sys.argv[1], "JPEG", quality=1)
PYEOF
echo "C-REJECT fixture: 5001x3100 = 15,503,100 px (over 15,500,000 survey limit)"

# Verify S-5 metadata
python3 "$VERIFY_IN_PY" jpeg "$IMG_DIR/test-S-5.jpg" || { echo "FATAL: S-5 metadata check failed" >&2; exit 1; }

# Copy WASM, patch config
cp "$WASM_SRC" "$WASM_DST"
printf '\n[functions.image-spike]\nstatic_files = ["./functions/_shared/magick.wasm"]\n' >> "$CONFIG"
echo "WASM copied and config.toml patched"

# Start local serve
echo "Starting supabase functions serve ..."
supabase functions serve image-spike \
  --workdir "$REPO_ROOT" --no-verify-jwt 2>&1 &
SERVE_PID=$!
echo "serve PID: $SERVE_PID"

# Wait for serve to be ready.
# sleep 20 first: Kong becomes reachable immediately but returns HTTP errors before
# the edge runtime registers the function. Without this pause the readiness curl
# exits 0 on a 502/503 and the test fires before the function is live.
PORT=54321
ready=false
sleep 20
for i in $(seq 1 30); do
  if curl -s --max-time 1 "http://localhost:${PORT}/functions/v1/image-spike?label=ping" \
     -X POST -H "Content-Type: application/octet-stream" \
     --data-binary "" -o /dev/null 2>/dev/null; then
    ready=true; break
  fi
  sleep 1
done
[[ "$ready" == "true" ]] || { echo "FATAL: serve did not become ready in 30s" >&2; exit 1; }
echo "serve ready on port $PORT"

echo ""
echo "--- Test 1: S-5 (accepted, image_decode_started=true) ---"
s5_out=$(curl -s --max-time 60 \
  "http://localhost:${PORT}/functions/v1/image-spike?label=S-5" \
  -X POST -H "Content-Type: image/jpeg" \
  --data-binary "@$IMG_DIR/test-S-5.jpg")
echo "$s5_out" | jq '{label,accepted,image_decode_started,pixel_count,width,height,metadata_clean}'

s5_accepted=$(echo "$s5_out" | jq -r '.accepted // "MISSING"')
s5_decode=$(echo "$s5_out" | jq -r '.image_decode_started // "MISSING"')
s5_pc=$(echo "$s5_out" | jq -r '.pixel_count // 0')

[[ "$s5_accepted" == "true" ]]        || { echo "FAIL: S-5 accepted=$s5_accepted ≠ true" >&2; exit 1; }
[[ "$s5_decode" == "true" ]]          || { echo "FAIL: S-5 image_decode_started=$s5_decode ≠ true" >&2; exit 1; }
[[ "$s5_pc" == "5000000" ]]           || { echo "FAIL: S-5 pixel_count=$s5_pc ≠ 5000000" >&2; exit 1; }
echo "Test 1: PASS ✓"

echo ""
echo "--- Test 2: C-REJECT (accepted=false, image_decode_started=false) ---"
rej_out=$(curl -s --max-time 30 \
  "http://localhost:${PORT}/functions/v1/image-spike?label=C-REJECT-local" \
  -X POST -H "Content-Type: image/jpeg" \
  --data-binary "@$IMG_DIR/test-local-reject.jpg")
echo "$rej_out" | jq '{label,accepted,image_decode_started,reason,pixel_count}'

rej_accepted=$(echo "$rej_out" | jq -r '.accepted // "MISSING"')
rej_decode=$(echo "$rej_out" | jq -r '.image_decode_started // "MISSING"')
rej_reason=$(echo "$rej_out" | jq -r '.reason // "MISSING"')

[[ "$rej_accepted" == "false" ]]               || { echo "FAIL: C-REJECT accepted=$rej_accepted ≠ false" >&2; exit 1; }
[[ "$rej_decode" == "false" ]]                 || { echo "FAIL: C-REJECT image_decode_started=$rej_decode ≠ false" >&2; exit 1; }
[[ "$rej_reason" == "pre_decode_rejected" ]]   || { echo "FAIL: C-REJECT reason=$rej_reason ≠ pre_decode_rejected" >&2; exit 1; }
echo "Test 2: PASS ✓"

echo ""
echo "=== Gate 2B Rev 14 — Local Edge Runtime Test: ALL PASS ==="
