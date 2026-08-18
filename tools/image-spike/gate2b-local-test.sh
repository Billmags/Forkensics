#!/usr/bin/env bash
# tools/image-spike/gate2b-local-test.sh — Rev 9 (unchanged from Rev 7)
# Gate 2A Item 7: supabase functions serve compatibility verification.
# Starts local Edge Runtime, sends B-01 (accepted) and B-04 (rejected),
# verifies the 'accepted' field through Supabase Edge Runtime (not standalone Deno).
# Required outcome: B-01 accepted=true, B-04 accepted=false.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMG_DIR="$SCRIPT_DIR/test-images"
LOCAL_URL="http://localhost:54321/functions/v1/image-spike"
SERVE_PID=""

cleanup_serve() {
  if [[ -n "$SERVE_PID" ]]; then
    kill "$SERVE_PID" 2>/dev/null || true
    wait "$SERVE_PID" 2>/dev/null
    echo "supabase functions serve exit: $?"
  fi
}
trap 'cleanup_serve; exit' EXIT
trap 'cleanup_serve; exit 130' INT
trap 'cleanup_serve; exit 143' TERM

[[ -d "$IMG_DIR" ]] || { echo "FATAL: generate fixtures first (gate2b-fixtures.py)" >&2; exit 1; }

supabase functions serve image-spike --no-verify-jwt &
SERVE_PID=$!
echo "serve PID: $SERVE_PID"
sleep 6

PASS=true

bool_field_local() {
  jq -r --arg f "$2" \
    'if has($f) and (.[$f] | type)=="boolean" then (.[$f]|tostring) else "MISSING" end' \
    "$1" 2>/dev/null || echo "PARSE_ERROR"
}

run_local_case() {
  local label="$1" img="$2" mime="$3" exp_accepted="$4"
  echo ""; echo "--- LOCAL $label ---"
  local out="/tmp/local-gate2b-${label}.json"
  local curl_w
  curl_w=$(curl -s -o "$out" -w '%{http_code}\t%{time_total}' \
    --max-time 60 -X POST "${LOCAL_URL}?label=${label}" \
    -H "Content-Type: $mime" --data-binary "@$img" 2>/dev/null)
  local curl_exit=$? http_status wall_time resp_accepted
  http_status=$(printf '%s' "$curl_w" | awk -F'\t' '{print $1}')
  wall_time=$(printf '%s' "$curl_w" | awk -F'\t' '{print $2}')
  echo "  curl_exit=$curl_exit  HTTP=$http_status  wall_time=${wall_time}s"
  if [[ $curl_exit -ne 0 ]]; then echo "  FAIL: curl transport error"; PASS=false; return; fi
  if [[ "$http_status" != "200" ]]; then echo "  FAIL: HTTP $http_status"; PASS=false; return; fi
  resp_accepted=$(bool_field_local "$out" "accepted")
  echo "  accepted=$resp_accepted (expected $exp_accepted)"
  [[ "$resp_accepted" == "$exp_accepted" ]] || { echo "  FAIL: accepted mismatch"; PASS=false; }
  echo "  response: $(head -c 300 "$out")"
}

run_local_case "local-B-01" "$IMG_DIR/test-B-01.jpg" "image/jpeg" "true"
run_local_case "local-B-04" "$IMG_DIR/test-B-04.jpg" "image/jpeg" "false"

echo ""
if [[ "$PASS" == "true" ]]; then echo "LOCAL TEST: PASS"
else echo "LOCAL TEST: FAIL"; exit 1; fi
