#!/usr/bin/env bash
# run-step-b-phase2-smoke.sh — Step B Phase 2 interactive smoke launcher.
#
# WARNING: Specific to forkensics-dev. Hardcodes anon key, project reference,
# smoke account email, and case ID for that environment. NOT reusable for
# forkensics-prod or other environments.
#
# Prompts for all secrets (password, CRON_SECRET, R2 keys, DB password).
# Never hardcodes any secret. Clears secrets from env after use.
#
# Run from repo root: bash tools/run-step-b-phase2-smoke.sh
# Three-party approved per Step B Phase 2 Rev 2.
set -euo pipefail
{ set +x; } 2>/dev/null

ANON_KEY="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImhrZnJiZHBlZHJ4bWJzYXduYnByIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODYxMjMwMDUsImV4cCI6MjEwMTY5OTAwNX0.7d2-q365HnLFervz6w4p-EcBdy5rLxWDEiX03ZE7N5c"
PROJECT_REF="hkfrbdpedrxmbsawnbpr"
SMOKE_EMAIL="smoketest@forkensics-dev.local"
CASE_ID="bef5f781-a661-4ab1-a5c1-be05e1dcbf33"

echo "=== Step B Phase 2 Smoke Launcher ==="
echo ""
echo "Smoke account : ${SMOKE_EMAIL}"
echo "Case ID       : ${CASE_ID}"
echo "Project       : ${PROJECT_REF}"
echo ""

printf "Smoke test user password: "          && read -s SMOKE_PASS         && echo
printf "DB password: "                        && read -s DB_PASS            && echo
printf "Cron secret: "                        && read -s CRON_SECRET        && echo
printf "R2 endpoint URL: "                    && read    R2_ENDPOINT        && echo
printf "R2 access key ID (32 chars): "        && read -s R2_ACCESS_KEY_ID   && echo
printf "R2 secret access key (64 chars): "    && read -s R2_SECRET_ACCESS_KEY && echo
printf "R2 bucket name [forkensics-dev-media]: " && read R2_BUCKET_INPUT   && echo
R2_BUCKET="${R2_BUCKET_INPUT:-forkensics-dev-media}"

echo ""
echo "Signing in as ${SMOKE_EMAIL}..."

_token_resp=$(curl -s -X POST \
  "https://${PROJECT_REF}.supabase.co/auth/v1/token?grant_type=password" \
  -H "apikey: ${ANON_KEY}" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"${SMOKE_EMAIL}\",\"password\":\"${SMOKE_PASS}\"}")

ACCESS_TOKEN=$(echo "${_token_resp}" | python3 -c \
  "import sys,json; d=json.load(sys.stdin); print(d['access_token'])" \
  2>/dev/null || true)
unset SMOKE_PASS

if [[ -z "${ACCESS_TOKEN}" ]]; then
  echo "FAIL: could not obtain access_token — check email/password"
  echo "Response error: $(echo "${_token_resp}" | python3 -c \
    "import sys,json; d=json.load(sys.stdin); print(d.get('error_description', d.get('error','unknown')))" \
    2>/dev/null || echo "(non-JSON)")"
  exit 1
fi
echo "Sign-in: OK"
echo ""

export ACCESS_TOKEN
export CASE_ID
export DB_URL="postgresql://postgres.${PROJECT_REF}:${DB_PASS}@aws-0-us-east-1.pooler.supabase.com:5432/postgres"
export CRON_SECRET
export R2_ENDPOINT
export R2_ACCESS_KEY_ID
export R2_SECRET_ACCESS_KEY
export R2_BUCKET
unset DB_PASS

bash tools/step-b-phase2-smoke-test.sh
