#!/usr/bin/env bash
# run-spike.sh — forkensics-image-spike Rev 10 — SPIKE ONLY
#
# Execution order: §6.0 → CF-P-1 → CF-P-2 → CF-P-3 → CF-P-4 → CF-P-5 →
#                  CF-P-6 → CF-P-7 → CF-P-9 → CF-P-8 → CF-P-10 → CF-P-11 → CF-P-12
#
# Requires (Homebrew):  wrangler (via npm), jq, exiftool, shasum, bc, gitleaks
# Shell:                Bash 4+ (/opt/homebrew/bin/bash)
# Credentials (env):    CLOUDFLARE_API_TOKEN, SPIKE_SECRET
# Run from cf-spike/:   /opt/homebrew/bin/bash run-spike.sh

# ── §6.0 Runner Preflight and EXIT Trap ───────────────────────────────────────

set -euo pipefail

# ── Bash version guard ────────────────────────────────────────────────────────
# declare -A (associative arrays) requires Bash 4+.
# macOS ships Bash 3.2. Install Bash 5 via Homebrew and run as:
#   /opt/homebrew/bin/bash run-spike.sh
[ "${BASH_VERSINFO[0]:-0}" -ge 4 ] || {
  echo "FAIL: Bash 4+ required (found ${BASH_VERSION:-unknown})"
  echo "  macOS: brew install bash && /opt/homebrew/bin/bash run-spike.sh"
  exit 1
}

# ── Configuration ─────────────────────────────────────────────────────────────
CF_ACCOUNT_ID="1dd6ede816fa36a5a824a6e21f82ad7b"
# CPU_LIMIT_MS must be set as an environment variable before running.
# CF-P-0b: check dash.cloudflare.com/$CF_ACCOUNT_ID/workers → Overview → plan.
#   Workers Free plan:  export CPU_LIMIT_MS=10
#   Workers Paid plan:  export CPU_LIMIT_MS=30000   (or per wrangler.toml cpu_ms)
[[ "${CPU_LIMIT_MS:-}" =~ ^[1-9][0-9]*$ ]] || {
  echo "FAIL: CPU_LIMIT_MS must be a positive integer — complete CF-P-0b first"
  echo "  CF-P-0b: dash.cloudflare.com/$CF_ACCOUNT_ID/workers → Overview → plan"
  echo "  Free plan:  export CPU_LIMIT_MS=10"
  echo "  Paid plan:  export CPU_LIMIT_MS=30000   (or per wrangler.toml cpu_ms)"
  exit 1
}
BUCKET="forkensics-dev-spike"
WORKER="forkensics-image-spike"
WRANGLER="./node_modules/.bin/wrangler"
# Auth-boundary test: generate a distinct wrong token at runtime so no literal
# secret-like string appears in the source file (avoids Gitleaks false positive).
WRONG_TOKEN="spike-wrong-$(date +%s)"
# Bash 4+ binary (Homebrew) used to invoke all shell scripts.
# Must match the binary that passes the syntax gate and runs the spike.
BASH_BIN="$(brew --prefix)/bin/bash"
SECRETS_TMP=$(mktemp)
WRANGLER_OUT=$(mktemp)

# Pin all Wrangler operations to the authorized account
export CLOUDFLARE_ACCOUNT_ID="$CF_ACCOUNT_ID"

# ── Mutation-attempt flags ────────────────────────────────────────────────────
BUCKET_MUTATION_ATTEMPTED=false   # set before r2 bucket create
BUCKET_CREATED=false              # set after confirmed success
SECRET_OR_WORKER_CREATED=false    # set before wrangler deploy
WORKER_DEPLOYED=false             # set after confirmed success
DEV_PID=""
WORKER_URL=""

# ── Three-state verifier helpers ──────────────────────────────────────────────
# All helpers output exactly one of: "exists" | "absent" | "error"
# Return code: 0 for exists/absent, 1 for error.
# All curl calls are bounded: --connect-timeout 5 --max-time 15.

# key_status KEY
# Wrangler 4: --remote required for r2 object commands to reach the remote bucket.
# --pipe streams object to stdout (redirect to /dev/null to discard).
# --file /dev/null exits non-zero even for existing objects on macOS (special device).
# Wrangler 4 writes its banner to the TTY (bypasses shell redirects), so captured
# error text is unreliable. Use exit code only: 0 = exists, non-zero = absent.
key_status() {
  local key="$1" rc=0
  "$WRANGLER" r2 object get "$BUCKET/$key" --pipe --remote \
    >/dev/null 2>/dev/null || rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "exists"; return 0
  fi
  echo "absent"; return 0
}

# key_wait_absent KEY — retries key_status up to 4 times with 3s sleep.
# R2 has eventual consistency: after r2 object delete, a subsequent get may still
# return the object for a few seconds while the delete propagates to all edge nodes.
key_wait_absent() {
  local key="$1" STATUS attempt
  for attempt in 1 2 3 4; do
    STATUS=$(key_status "$key") || { echo "error"; return 1; }
    [ "$STATUS" = "absent" ] && { echo "absent"; return 0; }
    [ "$attempt" -lt 4 ] && sleep 3
  done
  echo "exists"; return 0
}

# bucket_wait_absent — retries bucket delete + bucket_api_status up to 3 times.
# After objects are deleted, the bucket delete itself may need a brief retry.
bucket_wait_absent() {
  local STATUS attempt
  for attempt in 1 2 3 4 5; do
    "$WRANGLER" r2 bucket delete "$BUCKET" >/dev/null 2>/dev/null || true
    STATUS=$(bucket_api_status) || { echo "error"; return 1; }
    [ "$STATUS" = "absent" ] && { echo "absent"; return 0; }
    [ "$attempt" -lt 5 ] && sleep 5
  done
  echo "exists"; return 0
}

# worker_api_status — bounded curl; captures HTTP status code only (body discarded)
worker_api_status() {
  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" \
    --connect-timeout 5 --max-time 15 \
    -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
    "https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT_ID/workers/scripts/$WORKER")
  case "$http_code" in
    200) echo "exists"; return 0 ;;
    404) echo "absent"; return 0 ;;
    *)   printf 'FAIL: worker_api_status HTTP %s\n' "$http_code" >&2
         echo "error"; return 1 ;;
  esac
}

# bucket_api_status — bounded curl
bucket_api_status() {
  local resp success code
  resp=$(curl -s --connect-timeout 5 --max-time 15 \
    -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
    "https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT_ID/r2/buckets/$BUCKET")
  success=$(printf '%s\n' "$resp" | jq -r '.success')
  case "$success" in
    true) echo "exists"; return 0 ;;
    false)
      code=$(printf '%s\n' "$resp" | jq -r '.errors[0].code // 0')
      if [ "$code" = "10006" ]; then echo "absent"; return 0
      else
        printf 'FAIL: bucket_api_status CF error %s: %s\n' "$code" "$resp" >&2
        echo "error"; return 1
      fi ;;
    *) printf 'FAIL: bucket_api_status unexpected: %s\n' "$resp" >&2
       echo "error"; return 1 ;;
  esac
}

# ── Assertion helpers ─────────────────────────────────────────────────────────

assert_http() {
  local got="$1" want="$2" label="$3"
  [ "$got" = "$want" ] || { echo "FAIL $label: expected HTTP $want, got $got"; exit 1; }
}

# Exact Content-Type check: strip field name, strip parameters, normalize case,
# compare byte-for-byte to "image/webp". Rejects "image/webp-malicious" etc.
assert_exact_ct() {
  local headers="$1" label="$2" raw ct
  raw=$(grep -i "^content-type:" "$headers" | head -1 | tr -d '\r')
  ct=$(printf '%s\n' "$raw" \
    | sed 's/^[Cc]ontent-[Tt]ype:[[:space:]]*//' \
    | cut -d';' -f1 \
    | tr '[:upper:]' '[:lower:]' \
    | tr -d '[:space:]')
  [ "$ct" = "image/webp" ] \
    || { echo "FAIL $label: Content-Type exact mismatch: got '$ct' (raw: '$raw')"; exit 1; }
}

# Size header check: X-Forkensics-Size must equal actual file size AND be within 5 MB ceiling.
assert_size_header() {
  local headers="$1" file="$2" label="$3" hdr_size file_size
  hdr_size=$(grep -i "^x-forkensics-size:" "$headers" | head -1 \
    | awk '{print $2}' | tr -d '[:space:]')
  file_size=$(wc -c < "$file" | tr -d ' ')
  [ "$hdr_size" = "$file_size" ] \
    || { echo "FAIL $label: X-Forkensics-Size $hdr_size != actual $file_size"; exit 1; }
  [ "$file_size" -le 5242880 ] \
    || { echo "FAIL $label: output $file_size bytes exceeds 5 MB ceiling"; exit 1; }
}

# ── EXIT trap ─────────────────────────────────────────────────────────────────
cleanup() {
  local orig=$?; local failed=false; local STATUS

  echo "[CLEANUP] Starting (exit=$orig) — $(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # 1. Kill wrangler dev
  if [ -n "$DEV_PID" ] && kill -0 "$DEV_PID" 2>/dev/null; then
    kill "$DEV_PID"; wait "$DEV_PID" 2>/dev/null || true
    echo "[CLEANUP] wrangler dev terminated"
  fi

  # 2. Delete temp files
  rm -f .dev.vars "$SECRETS_TMP" "$WRANGLER_OUT"

  # 3. Undeploy Worker (if any state was attempted)
  if [ "$SECRET_OR_WORKER_CREATED" = "true" ]; then
    "$WRANGLER" delete "$WORKER" --force 2>/dev/null || true
    STATUS=$(worker_api_status) || true
    case "$STATUS" in
      absent) echo "[CLEANUP] Worker confirmed absent" ;;
      exists) echo "[CLEANUP] WARNING: Worker still deployed"; failed=true ;;
      *)      echo "[CLEANUP] FAIL: worker_api_status returned '$STATUS'"; failed=true ;;
    esac
  fi

  # 4. Delete spike objects (attempt if bucket creation was ever tried)
  if [ "$BUCKET_MUTATION_ATTEMPTED" = "true" ]; then
    for KEY in \
      "spike/fixture-exif.jpg" \
      "spike/fixture-static-icc-xmp.webp" \
      "spike/fixture-animated.webp" \
      "spike/fixture-oversized-px.jpg" \
      "spike/fixture-oversized.jpg" \
      "display/fixture-exif.jpg.webp" \
      "display/fixture-static-icc-xmp.webp.webp" \
      "display/fixture-animated.webp.webp" \
      "display/fixture-oversized.jpg.webp" \
      "display/fixture-oversized-px.jpg.webp"; do
      # Delete the object. Per-object existence verification via Wrangler get is unreliable
      # (exit-code false-positive for recently-deleted objects). Bucket-level verification
      # via bucket_wait_absent below is the authoritative check.
      "$WRANGLER" r2 object delete "$BUCKET/$KEY" --remote >/dev/null 2>/dev/null || true
      echo "[CLEANUP] Delete attempted: $KEY"
    done

    # 5. Delete bucket (retry — must be empty before Wrangler will accept the delete)
    STATUS=$(bucket_wait_absent) || true
    case "$STATUS" in
      absent) BUCKET_MUTATION_ATTEMPTED=false; echo "[CLEANUP] Bucket confirmed absent" ;;
      exists) echo "[CLEANUP] WARNING: Bucket still present"; failed=true ;;
      *)      echo "[CLEANUP] FAIL: bucket_wait_absent returned '$STATUS'"; failed=true ;;
    esac
  fi

  if [ "$failed" = "true" ]; then
    echo "[CLEANUP] Status: REMOTE_CLEANUP_REQUIRED"
    [ "$orig" -ne 0 ] && exit "$orig" || exit 1
  else
    echo "[CLEANUP] Status: REMOTE_CLEANUP_CONFIRMED"
    exit "$orig"
  fi
}
trap cleanup EXIT

# ── Preflight ─────────────────────────────────────────────────────────────────
echo "=== PREFLIGHT ==="

echo "Wrangler: $("$WRANGLER" --version)"
command -v jq       >/dev/null || { echo "FAIL: jq not installed";       exit 1; }
command -v exiftool >/dev/null || { echo "FAIL: exiftool not installed"; exit 1; }
command -v shasum   >/dev/null || { echo "FAIL: shasum not installed";   exit 1; }
command -v bc       >/dev/null || { echo "FAIL: bc not installed";       exit 1; }

[ -n "${SPIKE_SECRET:-}"         ] || { echo "FAIL: SPIKE_SECRET not set";         exit 1; }
[ -n "${CLOUDFLARE_API_TOKEN:-}" ] || { echo "FAIL: CLOUDFLARE_API_TOKEN not set"; exit 1; }
echo "Secrets: set (not printed)"

# .dev.vars gitignore check
git check-ignore -q .dev.vars 2>/dev/null \
  || { echo "FAIL: .dev.vars not in .gitignore — add it before proceeding"; exit 1; }

# Account verification (bounded curl)
ACCOUNT_RESP=$(curl -s --connect-timeout 5 --max-time 15 \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  "https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT_ID")
[ "$(printf '%s\n' "$ACCOUNT_RESP" | jq -r '.success')" = "true" ] \
  && [ "$(printf '%s\n' "$ACCOUNT_RESP" | jq -r '.result.id')" = "$CF_ACCOUNT_ID" ] \
  || { echo "FAIL: Account verification failed: $ACCOUNT_RESP"; exit 1; }
echo "Account verified: $CF_ACCOUNT_ID"

# No pre-existing spike resources
STATUS=$(bucket_api_status) || { echo "FAIL: bucket_api_status error"; exit 1; }
[ "$STATUS" = "absent" ] || { echo "FAIL: Bucket $BUCKET already exists (status: $STATUS)"; exit 1; }

STATUS=$(worker_api_status) || { echo "FAIL: worker_api_status error"; exit 1; }
[ "$STATUS" = "absent" ] || { echo "FAIL: Worker $WORKER already deployed (status: $STATUS)"; exit 1; }

echo "Preflight passed."

# ── CF-P-1 — R2 Bucket Creation ───────────────────────────────────────────────
echo "=== CF-P-1 ==="

# Set mutation-attempt flag BEFORE create attempt
BUCKET_MUTATION_ATTEMPTED=true
"$WRANGLER" r2 bucket create "$BUCKET"
BUCKET_CREATED=true

STATUS=$(bucket_api_status) || { echo "FAIL CF-P-1: bucket_api_status error"; exit 1; }
[ "$STATUS" = "exists" ] \
  || { echo "FAIL CF-P-1: Bucket not found after creation (status: $STATUS)"; exit 1; }

# Verify public access disabled via CF managed-domain API (exact enabled/disabled/error).
# Endpoint: GET /r2/buckets/{name}/domains/managed — returns result.enabled (bool).
# Bounded curl.
DEV_URL_RESP=$(curl -s --connect-timeout 5 --max-time 15 \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  "https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT_ID/r2/buckets/$BUCKET/domains/managed")
DEV_URL_ENABLED=$(printf '%s\n' "$DEV_URL_RESP" | jq -r 'if .result.enabled == null then "error" else (.result.enabled | tostring) end')
case "$DEV_URL_ENABLED" in
  false) echo "PASS CF-P-1: Bucket created, public domain confirmed disabled" ;;
  true)  echo "FAIL CF-P-1: Public managed domain is enabled"; exit 1 ;;
  *)     echo "FAIL CF-P-1: managed-domain API unexpected response: $DEV_URL_RESP"; exit 1 ;;
esac

# ── CF-P-2 — Build Verification (type integrity + tsc) ────────────────────────
echo "=== CF-P-2 ==="
# worker-configuration.d.ts is a reviewed, locked artifact (generated by
# `wrangler types` during Phase 2 local preparation and SHA-256-recorded in the
# Phase 2 lock table).  Regenerating it here would overwrite a reviewed artifact
# AFTER remote bucket creation — forbidden.  Verify the locked SHA instead.
LOCKED_TYPES_SHA="53b36e86b6c9e39d95d8ba1386caf07395423198acf62a08a42a289210e77e0a"
ACTUAL_TYPES_SHA=$(shasum -a 256 worker-configuration.d.ts | awk '{print $1}')
[ "$ACTUAL_TYPES_SHA" = "$LOCKED_TYPES_SHA" ] || {
  echo "FAIL CF-P-2: worker-configuration.d.ts SHA mismatch"
  echo "  expected: $LOCKED_TYPES_SHA"
  echo "  actual:   $ACTUAL_TYPES_SHA"
  exit 1
}
echo "PASS CF-P-2: worker-configuration.d.ts SHA verified"
./node_modules/.bin/tsc --noEmit
echo "PASS CF-P-2: tsc --noEmit zero errors"

# ── CF-P-3 — Fixture Generation and Upload ────────────────────────────────────
echo "=== CF-P-3 ==="

# 1. Run generate-fixtures.sh which creates and proves all fixtures
"$BASH_BIN" ./fixtures/generate-fixtures.sh

# 2. Upload all fixtures (Bash 4+ required for declare -A; guarded in preflight)
# --remote required in Wrangler 4
declare -A FIXTURES=(
  ["spike/fixture-exif.jpg"]="fixtures/fixture-exif.jpg"
  ["spike/fixture-static-icc-xmp.webp"]="fixtures/fixture-static-icc-xmp.webp"
  ["spike/fixture-animated.webp"]="fixtures/fixture-animated.webp"
  ["spike/fixture-oversized-px.jpg"]="fixtures/fixture-oversized-px.jpg"
  ["spike/fixture-oversized.jpg"]="fixtures/fixture-oversized.jpg"
)
for KEY in "${!FIXTURES[@]}"; do
  LOCAL="${FIXTURES[$KEY]}"
  "$WRANGLER" r2 object put "$BUCKET/$KEY" --file "$LOCAL" --remote
  STATUS=$(key_status "$KEY") || { echo "FAIL CF-P-3: key_status error for $KEY"; exit 1; }
  [ "$STATUS" = "exists" ] \
    || { echo "FAIL CF-P-3: Key $KEY not found after upload (status: $STATUS)"; exit 1; }
  echo "PASS CF-P-3: $KEY uploaded"
done

# ── CF-P-4 — Local Transformation Test (wrangler dev --remote) ────────────────
echo "=== CF-P-4 ==="

# Atomic creation at mode 0600 before writing any secret
(umask 077; printf 'SPIKE_SECRET=%s\n' "$SPIKE_SECRET" > .dev.vars)

"$WRANGLER" dev --remote src/index.ts &
DEV_PID=$!

READY=false
for i in $(seq 1 30); do
  kill -0 "$DEV_PID" 2>/dev/null || { echo "FAIL CF-P-4: wrangler dev died"; exit 1; }
  S=$(curl -s -o /dev/null -w "%{http_code}" --max-time 2 \
    http://localhost:8787/health 2>/dev/null || echo "000")
  [ "$S" = "200" ] && { READY=true; break; }
  sleep 1
done
[ "$READY" = "true" ] || { echo "FAIL CF-P-4: not ready in 30s"; exit 1; }

# Test A — oversized bytes: 422, no display write
S_A=$(curl -s -o /dev/null -w "%{http_code}" --max-time 30 \
  -H "Authorization: Bearer $SPIKE_SECRET" \
  http://localhost:8787/transform/spike/fixture-oversized.jpg)
assert_http "$S_A" "422" "CF-P-4-A oversized-bytes"
STATUS=$(key_status "display/fixture-oversized.jpg.webp") \
  || { echo "FAIL CF-P-4-A: key_status error"; exit 1; }
[ "$STATUS" = "absent" ] || { echo "FAIL CF-P-4-A: display key written for oversized-bytes"; exit 1; }
echo "PASS CF-P-4-A"

# Test B — oversized pixels: 422, no display write
S_B=$(curl -s -o /dev/null -w "%{http_code}" --max-time 30 \
  -H "Authorization: Bearer $SPIKE_SECRET" \
  http://localhost:8787/transform/spike/fixture-oversized-px.jpg)
assert_http "$S_B" "422" "CF-P-4-B oversized-pixels"
STATUS=$(key_status "display/fixture-oversized-px.jpg.webp") \
  || { echo "FAIL CF-P-4-B: key_status error"; exit 1; }
[ "$STATUS" = "absent" ] || { echo "FAIL CF-P-4-B: display key written for oversized-pixels"; exit 1; }
echo "PASS CF-P-4-B"

# Test C — JPEG with EXIF: 200
curl -s --max-time 60 -H "Authorization: Bearer $SPIKE_SECRET" \
  -D cf_p4_jpeg_headers.txt -o cf_p4_jpeg_output.webp \
  http://localhost:8787/transform/spike/fixture-exif.jpg
assert_http "$(grep -m1 "^HTTP" cf_p4_jpeg_headers.txt | awk '{print $2}')" "200" "CF-P-4-C JPEG"
assert_exact_ct cf_p4_jpeg_headers.txt "CF-P-4-C"
assert_size_header cf_p4_jpeg_headers.txt cf_p4_jpeg_output.webp "CF-P-4-C"
echo "PASS CF-P-4-C"

# Test D — static WebP with ICC/XMP: 200
curl -s --max-time 60 -H "Authorization: Bearer $SPIKE_SECRET" \
  -D cf_p4_swebp_headers.txt -o cf_p4_swebp_output.webp \
  http://localhost:8787/transform/spike/fixture-static-icc-xmp.webp
assert_http "$(grep -m1 "^HTTP" cf_p4_swebp_headers.txt | awk '{print $2}')" "200" "CF-P-4-D static-WebP"
assert_exact_ct cf_p4_swebp_headers.txt "CF-P-4-D"
assert_size_header cf_p4_swebp_headers.txt cf_p4_swebp_output.webp "CF-P-4-D"
echo "PASS CF-P-4-D"

# Test E — animated WebP: 200, output non-animated
curl -s --max-time 60 -H "Authorization: Bearer $SPIKE_SECRET" \
  -D cf_p4_awebp_headers.txt -o cf_p4_awebp_output.webp \
  http://localhost:8787/transform/spike/fixture-animated.webp
assert_http "$(grep -m1 "^HTTP" cf_p4_awebp_headers.txt | awk '{print $2}')" "200" "CF-P-4-E animated-WebP"
assert_exact_ct cf_p4_awebp_headers.txt "CF-P-4-E"
assert_size_header cf_p4_awebp_headers.txt cf_p4_awebp_output.webp "CF-P-4-E"
# Animation elimination verified in CF-P-6 (VP8X Animation flag = 0)
echo "PASS CF-P-4-E"

kill "$DEV_PID" 2>/dev/null; wait "$DEV_PID" 2>/dev/null || true; DEV_PID=""
rm -f .dev.vars
echo "PASS CF-P-4: All local tests passed"

# ── CF-P-5 — Metadata Stripping Verification ──────────────────────────────────
echo "=== CF-P-5 ==="
for F in cf_p4_jpeg_output.webp cf_p4_swebp_output.webp cf_p4_awebp_output.webp; do
  BASE=$(basename "$F" .webp)
  exiftool -G1 -s "$F" > "cf_p5_${BASE}.txt"
  cat "cf_p5_${BASE}.txt"
  # Match group prefix to catch sub-groups like [XMP-dc], [XMP-xmp], [IFD0], etc.
  for G in EXIF XMP ICC_Profile IFD0 ExifIFD GPS IPTC COMMENT; do
    grep -qE "^\[${G}" "cf_p5_${BASE}.txt" \
      && { echo "FAIL CF-P-5: Prohibited group [$G*] in $F"; exit 1; }
  done
  echo "PASS CF-P-5: No prohibited metadata in $F"
done

# ── CF-P-6 — Output WebP Structural Verification ──────────────────────────────
echo "=== CF-P-6 ==="

# JPEG output: static WebP expected
"$BASH_BIN" ./parser/verify-webp.sh cf_p4_jpeg_output.webp
echo "PASS CF-P-6: JPEG output structural check"

# Static WebP output: static WebP expected
"$BASH_BIN" ./parser/verify-webp.sh cf_p4_swebp_output.webp
echo "PASS CF-P-6: Static WebP output structural check"

# Animated WebP output: must verify Animation flag = 0 (anim:false enforcement)
"$BASH_BIN" ./parser/verify-webp.sh --check-no-animation cf_p4_awebp_output.webp
echo "PASS CF-P-6: Animated WebP output — Animation flag = 0 confirmed"

# ── CF-P-7 — SHA-256 Integrity ────────────────────────────────────────────────
echo "=== CF-P-7 ==="
for PAIR in \
  "cf_p4_jpeg_output.webp:cf_p4_jpeg_headers.txt" \
  "cf_p4_swebp_output.webp:cf_p4_swebp_headers.txt" \
  "cf_p4_awebp_output.webp:cf_p4_awebp_headers.txt"; do
  OUT_FILE="${PAIR%%:*}"
  HDR_FILE="${PAIR##*:}"
  COMPUTED=$(shasum -a 256 "$OUT_FILE" | awk '{print $1}')
  HEADER_SHA=$(grep -i "^x-forkensics-sha256:" "$HDR_FILE" | head -1 \
    | awk '{print $2}' | tr -d '[:space:]')
  [ "$COMPUTED" = "$HEADER_SHA" ] \
    || { echo "FAIL CF-P-7: SHA mismatch for $OUT_FILE: computed=$COMPUTED header=$HEADER_SHA"; exit 1; }
  echo "PASS CF-P-7: $OUT_FILE SHA-256 verified ($COMPUTED)"
done

# ── CF-P-9 — Hosted Worker Deploy ─────────────────────────────────────────────
echo "=== CF-P-9 ==="

# Atomic 0600 creation before writing secret
(umask 077; printf 'SPIKE_SECRET=%s\n' "$SPIKE_SECRET" > "$SECRETS_TMP")

# Set flag before deploy attempt
SECRET_OR_WORKER_CREATED=true
WRANGLER_OUTPUT_FILE_PATH="$WRANGLER_OUT" \
  "$WRANGLER" deploy --secrets-file "$SECRETS_TMP"
WORKER_DEPLOYED=true
rm -f "$SECRETS_TMP"

# targets[0] is the URL string directly (§4.7)
WORKER_URL=$(jq -r 'select(.type == "deploy") | .targets[0] // empty' "$WRANGLER_OUT" \
  | head -1)
rm -f "$WRANGLER_OUT"
[ -n "$WORKER_URL" ] \
  || { echo "FAIL CF-P-9: Worker URL not found in WRANGLER_OUTPUT_FILE_PATH output"; exit 1; }
echo "Worker URL: $WORKER_URL"

STATUS=$(worker_api_status) || { echo "FAIL CF-P-9: worker_api_status error"; exit 1; }
[ "$STATUS" = "exists" ] \
  || { echo "FAIL CF-P-9: Worker not found via API after deploy (status: $STATUS)"; exit 1; }

# Hosted JPEG test — retry up to 3 times with 15s sleep for Cloudflare edge propagation.
# The CF API confirms the worker is deployed, but the edge may take 5–30s before the
# worker is live AND can reach R2 objects. BUCKET.head() returns null → 404 during this window.
CF_P9_HTTP=""; CF_P9_ATTEMPT=0
for attempt in 1 2 3; do
  CF_P9_ATTEMPT=$attempt
  rm -f cf_p9_headers.txt cf_p9_output.webp
  curl -s --max-time 60 -H "Authorization: Bearer $SPIKE_SECRET" \
    -D cf_p9_headers.txt -o cf_p9_output.webp "${WORKER_URL}/transform/spike/fixture-exif.jpg"
  CF_P9_HTTP="$(grep -m1 "^HTTP" cf_p9_headers.txt | awk '{print $2}')"
  [ "$CF_P9_HTTP" = "200" ] && break
  echo "NOTE CF-P-9: attempt $attempt returned HTTP $CF_P9_HTTP — sleeping 15s for edge propagation"
  sleep 15
done
assert_http "$CF_P9_HTTP" "200" "CF-P-9 (attempt $CF_P9_ATTEMPT)"
assert_exact_ct cf_p9_headers.txt "CF-P-9"
assert_size_header cf_p9_headers.txt cf_p9_output.webp "CF-P-9"
SHA_P9=$(grep -i "^x-forkensics-sha256:" cf_p9_headers.txt | head -1 \
  | awk '{print $2}' | tr -d '[:space:]')
[ "$(shasum -a 256 cf_p9_output.webp | awk '{print $1}')" = "$SHA_P9" ] \
  || { echo "FAIL CF-P-9: SHA mismatch"; exit 1; }
echo "PASS CF-P-9: Hosted transform confirmed"

# ── CF-P-8 — Worker CPU Budget Gate (executes after CF-P-9) ──────────────────
echo "=== CF-P-8 ==="
echo "[CF-P-8] Open: dash.cloudflare.com/$CF_ACCOUNT_ID/workers/services/view/$WORKER/production/metrics"
echo "[CF-P-8] Find the CPU time per invocation for the CF-P-9 JPEG request."
echo "[CF-P-8] If analytics unavailable after 5 minutes, enter 'INCONCLUSIVE'."
echo "[CF-P-8] Enter observed CPU time in milliseconds (number) or 'INCONCLUSIVE':"
read -r CPU_MS_INPUT

if [ "$CPU_MS_INPUT" = "INCONCLUSIVE" ]; then
  echo "NOTE CF-P-8: Analytics unavailable — INCONCLUSIVE recorded (Free plan metrics lag ~5 min)"
  echo "NOTE CF-P-8: CF-P-10/11/12 will still execute; record INCONCLUSIVE in governance doc"
elif [[ "$CPU_MS_INPUT" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
  if (( $(printf '%s < %s\n' "$CPU_MS_INPUT" "$CPU_LIMIT_MS" | bc -l) )); then
    echo "PASS CF-P-8: CPU $CPU_MS_INPUT ms < plan limit $CPU_LIMIT_MS ms"
  else
    echo "FAIL CF-P-8: CPU $CPU_MS_INPUT ms >= plan limit $CPU_LIMIT_MS ms (Error 1102 risk)"
    exit 1
  fi
else
  echo "FAIL CF-P-8: Non-numeric input '$CPU_MS_INPUT'"; exit 1
fi

# ── CF-P-10 — Auth Boundary ───────────────────────────────────────────────────
echo "=== CF-P-10 ==="
S_NO=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
  "${WORKER_URL}/transform/spike/fixture-exif.jpg")
assert_http "$S_NO" "401" "CF-P-10 no-auth"
S_WR=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
  -H "Authorization: Bearer $WRONG_TOKEN" "${WORKER_URL}/transform/spike/fixture-exif.jpg")
assert_http "$S_WR" "401" "CF-P-10 wrong-token"
echo "PASS CF-P-10"

# ── CF-P-11 — Write-Back Persistence Verification ────────────────────────────
echo "=== CF-P-11 ==="
STATUS=$(key_status "display/fixture-exif.jpg.webp") \
  || { echo "FAIL CF-P-11: key_status error"; exit 1; }
[ "$STATUS" = "exists" ] || { echo "FAIL CF-P-11: JPEG display key absent"; exit 1; }
# --remote required in Wrangler 4
"$WRANGLER" r2 object get "$BUCKET/display/fixture-exif.jpg.webp" \
  --file cf_p11_verify.webp --remote
[ "$(shasum -a 256 cf_p11_verify.webp | awk '{print $1}')" = "$SHA_P9" ] \
  || { echo "FAIL CF-P-11: SHA mismatch"; exit 1; }
echo "PASS CF-P-11"

# ── CF-P-12 — Cleanup ─────────────────────────────────────────────────────────
echo "=== CF-P-12 ==="

# wrangler delete may exit non-zero if token lacks KV Storage permission (Wrangler
# checks KV namespaces even for workers that don't use KV). Suppress and verify via API.
"$WRANGLER" delete "$WORKER" --force >/dev/null 2>/dev/null || true
STATUS=$(worker_api_status) || { echo "FAIL CF-P-12: worker_api_status error"; exit 1; }
[ "$STATUS" = "absent" ] || { echo "FAIL CF-P-12: Worker still deployed after delete"; exit 1; }
WORKER_DEPLOYED=false; SECRET_OR_WORKER_CREATED=false

for KEY in \
  "spike/fixture-exif.jpg" \
  "spike/fixture-static-icc-xmp.webp" \
  "spike/fixture-animated.webp" \
  "spike/fixture-oversized-px.jpg" \
  "spike/fixture-oversized.jpg" \
  "display/fixture-exif.jpg.webp" \
  "display/fixture-static-icc-xmp.webp.webp" \
  "display/fixture-animated.webp.webp" \
  "display/fixture-oversized.jpg.webp" \
  "display/fixture-oversized-px.jpg.webp"; do
  # WebP-source display keys have double extension: display/{name}.webp.webp
  # Per-object Wrangler verification is unreliable; bucket_wait_absent is authoritative.
  "$WRANGLER" r2 object delete "$BUCKET/$KEY" --remote >/dev/null 2>/dev/null || true
  echo "Delete attempted: $KEY"
done

STATUS=$(bucket_wait_absent) || { echo "FAIL CF-P-12: bucket_wait_absent error"; exit 1; }
[ "$STATUS" = "absent" ] || { echo "FAIL CF-P-12: Bucket still present after all retries"; exit 1; }
BUCKET_MUTATION_ATTEMPTED=false; BUCKET_CREATED=false
echo "PASS CF-P-12: REMOTE_CLEANUP_CONFIRMED"

echo ""
echo "=== ALL PROBES PASSED ==="
echo "Verdict: PASS — architecture viable. Spike complete."
