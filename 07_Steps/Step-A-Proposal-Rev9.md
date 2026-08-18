# Step A Proposal — Rev 9 — `upload-authorize` Edge Function

**Status:** DRAFT — Awaiting three-party approval (Claude + Codex + Bill)

**Supersedes:** Rev 8 (CHANGES REQUIRED — 2 blockers)

**Governance gate:** All three parties must approve before any TypeScript is written.
Magic words:
- Codex: `APPROVED: Step A Rev 9 — upload-authorize`
- Bill:   `APPROVED: Step A Rev 9 — upload-authorize — Amendment C acknowledged`

**Binding contracts:**
- Step 27 Rev 5 (approved 2026-08-12) — §5.1, §6, §7, §8
- Step 24 Rev 10 (approved 2026-08-07) — §5.1 test matrix
  - **Amendment A** — Session claim window: Step 24 §4.1 5-minute window → 15 minutes. §5.3.
  - **Amendment B** — Local S3 credentials: Step 27's `stub`/`ANON_KEY` → Gate 4 evidence. §7.
  - **Amendment C** — Race A full orchestration deferred to `account-delete-complete` step. §6.13.
- V2 migration SHA-256: `0f9adbb732f671008629854398fb7d5c3962a315338e3eff08b3a45eccea161a`
- V4 migration SHA-256: `0eb78c66878df50f22278fb36f2b089d3f2b81ded2f550a945e9d0dd55dd0f66`
  - V4 applied: `public.challenges → public.cases`; `p_challenge_id → p_case_id`

**Rev 9 changes (relative to Rev 8):**
1. §6.2 — `cleanup()`: exit-code capture fixed; `trap - EXIT` + explicit `exit` override the already-selected status
2. §6.8 — T-A-auth-real: body assertion tightened to exact equality

---

## Section 1 — Scope — unchanged from Rev 8 §1

---

## Section 2 — Pre-conditions — unchanged from Rev 8 §2

---

## Section 3 — Directory Structure — unchanged from Rev 8 §3

---

## Section 4 — Shared Module Specification — unchanged from Rev 8 §4

---

## Section 5 — `upload-authorize` Implementation — unchanged from Rev 8 §5

---

## Section 6 — Test Matrix

### 6.1 Unit Test Command — unchanged from Rev 8 §6.1

### 6.2 Integration Runner (`tools/integration-runner.sh`)

**Rev 9 change — `cleanup()` exit-code fix:**

Two bugs corrected:

*Bug A — `$?` inversion.*  In Rev 8: `if ! psql ...; then _teardown_exit=$?`. Because `!` inverts the exit status before the shell evaluates the condition, `$?` inside the `then` branch is always `0`, never the real psql failure code. Fix: remove `!`; capture via `|| _teardown_exit=$?`.

*Bug B — trap cannot modify the already-selected exit status by variable assignment.*  When `exit "$TEST_EXIT"` fires, the shell evaluates `TEST_EXIT` immediately and records that value. The EXIT trap then runs; mutations to `TEST_EXIT` inside the trap have no effect on the recorded value. Fix: at the end of `cleanup`, disable the EXIT trap with `trap - EXIT` (preventing re-entry), then call `exit "${_final_exit}"` explicitly — this overrides the recorded exit status.

```sh
#!/usr/bin/env bash
set -euo pipefail

LOG="08_Migration/tests/integration-$(date +%Y%m%d-%H%M%S).log"
SERVE_PID=""
TEST_EXIT=1     # default to failure; overwritten by the deno test block

# ── Credential helpers ────────────────────────────────────────────────────────
_env() {
  supabase status -o env 2>/dev/null | grep "^${1}=" | cut -d= -f2- | tr -d "\"'" || true
}
_env_fb() {
  local v
  v=$(_env "$1")
  [[ -z "$v" ]] && v=$(_env "$2")
  echo "$v"
}

# ── Cleanup: runs exactly once on EXIT ───────────────────────────────────────
cleanup() {
  local _incoming_exit="${TEST_EXIT}"
  local _teardown_exit=0

  # Kill and reap the function server
  if [[ -n "$SERVE_PID" ]]; then
    kill "$SERVE_PID" 2>/dev/null || true
    wait "$SERVE_PID" 2>/dev/null || true   # reap; ignore server's own exit code
  fi

  rm -f supabase/functions/.env.local

  # Capture teardown exit code directly — no '!' inversion
  if [[ -n "${DB_URL:-}" ]]; then
    psql "$DB_URL" -q -c "SELECT cleanup_integration_fixtures();" 2>&1 \
      || _teardown_exit=$?
    if [[ "$_teardown_exit" -ne 0 ]]; then
      echo "WARN: cleanup_integration_fixtures() failed (exit ${_teardown_exit})"
    fi
  fi

  unset SUPABASE_URL SUPABASE_PUBLISHABLE_KEY SUPABASE_SECRET_KEY \
        SUPABASE_JWT_SECRET DB_URL \
        S3_ENDPOINT S3_REGION S3_ACCESS_KEY_ID S3_SECRET_ACCESS_KEY S3_BUCKET \
        2>/dev/null || true

  # Determine final exit code: promote success → failure if teardown itself failed
  local _final_exit="${_incoming_exit}"
  if [[ "$_teardown_exit" -ne 0 && "${_final_exit}" -eq 0 ]]; then
    _final_exit="${_teardown_exit}"
    echo "WARN: tests passed but teardown failed; result is FAIL"
  fi

  echo "=== RESULT: $([ "${_final_exit}" -eq 0 ] && echo PASS || echo FAIL) ===" \
    | tee -a "$LOG"

  # Disable the EXIT trap to prevent re-entry, then override the exit status.
  # Without this, exit "$TEST_EXIT" at the bottom of the script already selected
  # a status; variable assignments inside the trap cannot change it. Calling
  # exit here explicitly replaces that selected status.
  trap - EXIT
  exit "${_final_exit}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

exec > >(tee -a "$LOG") 2>&1
echo "=== upload-authorize integration suite ==="
echo "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ── 1. Preflight ──────────────────────────────────────────────────────────────
supabase status --output env > /dev/null

# ── 2. Credentials ───────────────────────────────────────────────────────────
SUPABASE_URL=$(_env API_URL)
SUPABASE_PUBLISHABLE_KEY=$(_env_fb PUBLISHABLE_KEY ANON_KEY)
SUPABASE_SECRET_KEY=$(_env_fb SECRET_KEY SERVICE_ROLE_KEY)
SUPABASE_JWT_SECRET=$(_env JWT_SECRET)
DB_URL=$(_env DB_URL)
S3_ACCESS_KEY_ID=$(_env S3_PROTOCOL_ACCESS_KEY_ID)
S3_SECRET_ACCESS_KEY=$(_env S3_PROTOCOL_ACCESS_KEY_SECRET)

for var in SUPABASE_URL SUPABASE_PUBLISHABLE_KEY SUPABASE_SECRET_KEY \
           SUPABASE_JWT_SECRET DB_URL S3_ACCESS_KEY_ID S3_SECRET_ACCESS_KEY; do
  [[ -z "${!var}" ]] && { echo "FAIL: could not read ${var}"; exit 1; }
done

S3_ENDPOINT="${SUPABASE_URL}/storage/v1/s3"
S3_REGION="local"
S3_BUCKET="game-media"
FUNCTION_URL="${SUPABASE_URL}/functions/v1/upload-authorize"

# ── 3. Generate .env.local (0600; git-ignored; deleted in cleanup) ────────────
touch supabase/functions/.env.local
chmod 0600 supabase/functions/.env.local
cat > supabase/functions/.env.local << ENVEOF
SUPABASE_URL=${SUPABASE_URL}
SUPABASE_PUBLISHABLE_KEY=${SUPABASE_PUBLISHABLE_KEY}
SUPABASE_SECRET_KEY=${SUPABASE_SECRET_KEY}
S3_ENDPOINT=${S3_ENDPOINT}
S3_REGION=${S3_REGION}
S3_ACCESS_KEY_ID=${S3_ACCESS_KEY_ID}
S3_SECRET_ACCESS_KEY=${S3_SECRET_ACCESS_KEY}
S3_BUCKET=${S3_BUCKET}
ENVEOF

# ── 4. Fixtures ───────────────────────────────────────────────────────────────
psql "$DB_URL" -q -f tools/integration-fixtures.sql

# ── 5. Serve ──────────────────────────────────────────────────────────────────
supabase functions serve upload-authorize \
  --env-file supabase/functions/.env.local &
SERVE_PID=$!

# ── 6. Readiness poll (|| true so connection errors don't trigger set -e) ─────
READY=false
for _ in $(seq 1 30); do
  http_code=$(curl -s -o /dev/null -w "%{http_code}" "$FUNCTION_URL" 2>/dev/null || true)
  if [[ "$http_code" == "401" || "$http_code" == "400" || "$http_code" == "405" ]]; then
    READY=true; break
  fi
  sleep 1
done
$READY || { echo "FAIL: function not ready after 30 s"; exit 1; }

# ── 7. Run tests (secrets via env; not CLI args) ──────────────────────────────
if env \
     SUPABASE_URL="$SUPABASE_URL" \
     SUPABASE_PUBLISHABLE_KEY="$SUPABASE_PUBLISHABLE_KEY" \
     SUPABASE_SECRET_KEY="$SUPABASE_SECRET_KEY" \
     SUPABASE_JWT_SECRET="$SUPABASE_JWT_SECRET" \
     DB_URL="$DB_URL" \
     FUNCTION_URL="$FUNCTION_URL" \
     S3_ENDPOINT="$S3_ENDPOINT" \
     S3_REGION="$S3_REGION" \
     S3_ACCESS_KEY_ID="$S3_ACCESS_KEY_ID" \
     S3_SECRET_ACCESS_KEY="$S3_SECRET_ACCESS_KEY" \
     S3_BUCKET="$S3_BUCKET" \
   deno test \
     --allow-net --allow-env --allow-read --allow-run \
     supabase/functions/upload-authorize/upload-authorize.integration.test.ts; then
  TEST_EXIT=0
else
  TEST_EXIT=$?
fi

exit "$TEST_EXIT"
```

### 6.3 Private Session Check Script — unchanged from Rev 8 §6.3

### 6.4 Integration Reserve Adapter — unchanged from Rev 8 §6.4

### 6.5 `parseAmzExpiry` Unit Tests (T-A-P-*) — unchanged from Rev 8 §6.5

### 6.6 Happy Path — unchanged from Rev 8 §6.6

### 6.7 Method Enforcement — unchanged from Rev 8 §6.7

### 6.8 Authentication and Profile

**Rev 9 change — T-A-auth-real body assertion:**

`assertEquals(typeof body.error.code, 'string')` only proves a string key exists; a response carrying internal detail, a stack trace, or a wrong public code passes that assertion. The assertion is replaced with exact structural equality, proving the real `getAuthContext` wrapper returns the identical sanitized body shape that `context.ts` §4.4 specifies on auth failure.

All other rows unchanged from Rev 8 §6.8.

| # | Description | Type | Expected |
|---|---|---|---|
| T-A-11 | Missing `Authorization` header (live function) | Integration | 401; `Cache-Control` outside application control |
| T-A-12 | Malformed JWT (live function) | Integration | 401 |
| T-A-13 | Expired JWT (live function) | Integration | 401 |
| T-A-auth-cc | `stubAuthFail` — handler wiring (unit stub) | Unit | 401; `Cache-Control: no-store` |
| T-A-auth-real | Real `getAuthContext()` with invalid JWT | Integration | `ok: false`; 401; `Cache-Control: no-store`; exact body |
| T-A-14 | `is_active = false` stub | Unit | 403 `FK_FORBIDDEN`; `Cache-Control: no-store` |
| T-A-15 | Deletion-prepared profile (`is_active=false`) | Integration | 403 `FK_FORBIDDEN` |
| T-A-16 | `onboarding_complete = false` stub | Unit | 403 `FK_FORBIDDEN` |
| T-A-17 | `is_suspended = true` stub | Unit | 403 `FK_FORBIDDEN` |
| T-A-18 | Profile row absent stub | Unit | 403 `FK_FORBIDDEN` |
| T-A-19 | Profile check `'error'` stub | Unit | 500 `FK_INTERNAL` |

**T-A-auth-real — updated implementation:**
```typescript
// In upload-authorize.integration.test.ts
// Calls the real getAuthContext implementation (not a stub) with a deliberately
// invalid token. SUPABASE_URL and SUPABASE_PUBLISHABLE_KEY are set in the process
// environment by integration-runner.sh step 7. No live function endpoint is used.
Deno.test('T-A-auth-real: real getAuthContext returns sanitized 401 + Cache-Control: no-store', async () => {
  const req = new Request('https://example.com/', {
    method: 'POST',
    headers: { 'Authorization': 'Bearer definitely.not.a.valid.jwt' },
  })
  const result = await getAuthContext(req)

  assertEquals(result.ok, false)
  assert(result.error !== null)
  assertEquals(result.error.status, 401)
  assertEquals(result.error.headers.get('Cache-Control'), 'no-store')

  // Prove the body is exactly the sanitized shape — no internal detail, stack
  // trace, or wrong public code can slip through.
  const body = await result.error.json()
  assertEquals(body, {
    error: {
      code: 'FK_UNAUTHENTICATED',
      message: 'Unauthorized',
    },
  })
})
```

**T-A-auth-cc — unchanged from Rev 8:**
```typescript
const stubAuthFail: Deps['getAuth'] = async () => ({
  ok: false, ctx: null,
  error: new Response(
    JSON.stringify({ error: { code: 'FK_UNAUTHENTICATED', message: 'Unauthorized' } }),
    { status: 401, headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' } },
  ),
})

const res = await makeHandler({ ...defaultDeps, getAuth: stubAuthFail })(fakePostRequest())
assertEquals(res.status, 401)
assertEquals(res.headers.get('Cache-Control'), 'no-store')
```

### 6.9 Request Validation (T-A-20 to T-A-30) — unchanged from Rev 8 §6.9

### 6.10 DB-Driven Errors (T-A-31 to T-A-40) — unchanged from Rev 8 §6.10

### 6.11 Presign, Activate, and Unexpected Failures (T-A-41 to T-A-48) — unchanged from Rev 8 §6.11

### 6.12 Race B — Concurrent Duplicate Reservations — unchanged from Rev 8 §6.12

### 6.13 Race A — Formal Deferral (Amendment C) — unchanged from Rev 8 §6.13

---

## Section 7 — Environment Variables — unchanged from Rev 8 §7

---

## Section 8 — Scaffold and Quality Gates — unchanged from Rev 8 §8

---

## Section 9 — Dependency Versions — unchanged from Rev 8 §9

---

## Section 10 — Amendments Summary — unchanged from Rev 8 §10

---

## Section 11 — Approval Record

| Party | Status | Required phrase |
|---|---|---|
| Claude | Approved | Rev 9; both Rev 8 blockers resolved; Amendment C acknowledged |
| Codex | Pending | `APPROVED: Step A Rev 9 — upload-authorize` |
| Bill | Pending | `APPROVED: Step A Rev 9 — upload-authorize — Amendment C acknowledged` |

**This approval authorizes TypeScript implementation only. No cloud deployment authorized.**
