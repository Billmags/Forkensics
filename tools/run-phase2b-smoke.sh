#!/usr/bin/env bash
# run-phase2b-smoke.sh — DEV-ONLY interactive launcher for phase2b-smoke-test.sh.
#
# WARNING: This script is specific to forkensics-dev. It hardcodes the anon key,
# project reference, smoke-test email, and case ID for that environment. It is
# NOT a reusable tool for other environments. Do not use for forkensics-prod.
#
# Prompts for all secrets (passwords, R2 keys); never hardcodes them.
# Run from repo root: bash tools/run-phase2b-smoke.sh
set -euo pipefail
{ set +x; } 2>/dev/null

ANON_KEY="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImhrZnJiZHBlZHJ4bWJzYXduYnByIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODYxMjMwMDUsImV4cCI6MjEwMTY5OTAwNX0.7d2-q365HnLFervz6w4p-EcBdy5rLxWDEiX03ZE7N5c"
PROJECT_REF="hkfrbdpedrxmbsawnbpr"
SMOKE_EMAIL="smoketest@forkensics-dev.local"
CASE_ID="bef5f781-a661-4ab1-a5c1-be05e1dcbf33"

echo "=== Phase 2b Smoke Test Launcher ==="
echo ""

printf "Smoke test user password: " && read -s SMOKE_PASS && echo
printf "DB password: "              && read -s DB_PASS    && echo
printf "R2 endpoint URL: "          && read    R2_ENDPOINT && echo
printf "R2 access key ID (32 chars): "  && read -s R2_ACCESS_KEY_ID    && echo
printf "R2 secret access key (64 chars): " && read -s R2_SECRET_ACCESS_KEY && echo
printf "R2 bucket name [forkensics-dev-media]: " && read R2_BUCKET_INPUT && echo
R2_BUCKET="${R2_BUCKET_INPUT:-forkensics-dev-media}"

echo ""
echo "Signing in as ${SMOKE_EMAIL}..."

_token_resp=$(curl -s -X POST \
  "https://${PROJECT_REF}.supabase.co/auth/v1/token?grant_type=password" \
  -H "apikey: ${ANON_KEY}" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"${SMOKE_EMAIL}\",\"password\":\"${SMOKE_PASS}\"}")

ACCESS_TOKEN=$(echo "${_token_resp}" | python3 -c \
  "import sys,json; d=json.load(sys.stdin); print(d['access_token'])" 2>/dev/null || true)
unset SMOKE_PASS

if [[ -z "${ACCESS_TOKEN}" ]]; then
  echo "FAIL: could not obtain access_token — check email/password"
  echo "Response: $(echo "${_token_resp}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('error_description', d.get('error','unknown')))" 2>/dev/null || echo "${_token_resp}")"
  exit 1
fi
echo "Sign-in: OK"

export FUNCTION_URL="https://${PROJECT_REF}.supabase.co/functions/v1/upload-authorize"
export ACCESS_TOKEN
export CASE_ID
export DB_URL="postgresql://postgres.${PROJECT_REF}:${DB_PASS}@aws-0-us-east-1.pooler.supabase.com:5432/postgres"
export R2_ENDPOINT
export R2_ACCESS_KEY_ID
export R2_SECRET_ACCESS_KEY
export R2_BUCKET
unset DB_PASS

echo ""
bash tools/phase2b-smoke-test.sh
