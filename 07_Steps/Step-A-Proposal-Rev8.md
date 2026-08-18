# Step A Proposal — Rev 8 — `upload-authorize` Edge Function

**Status:** DRAFT — Awaiting three-party approval (Claude + Codex + Bill)

**Supersedes:** Rev 7 (CHANGES REQUIRED — 3 blockers + 1 required test addition)

**Governance gate:** All three parties must approve before any TypeScript is written.
Magic words:
- Codex: `APPROVED: Step A Rev 8 — upload-authorize`
- Bill:   `APPROVED: Step A Rev 8 — upload-authorize — Amendment C acknowledged`

**Binding contracts:**
- Step 27 Rev 5 (approved 2026-08-12) — §5.1, §6, §7, §8
- Step 24 Rev 10 (approved 2026-08-07) — §5.1 test matrix
  - **Amendment A** — Session claim window: Step 24 §4.1 5-minute window → 15 minutes. §5.3.
  - **Amendment B** — Local S3 credentials: Step 27's `stub`/`ANON_KEY` → Gate 4 evidence. §7.
  - **Amendment C** — Race A full orchestration deferred to `account-delete-complete` step. §6.13.
- V2 migration SHA-256: `0f9adbb732f671008629854398fb7d5c3962a315338e3eff08b3a45eccea161a`
- V4 migration SHA-256: `0eb78c66878df50f22278fb36f2b089d3f2b81ded2f550a945e9d0dd55dd0f66`
  - V4 applied: `public.challenges → public.cases`; `p_challenge_id → p_case_id`

**Rev 8 changes (relative to Rev 7):**
1. §6.2 — Integration runner: S3 credentials added to `env` block; teardown captures failure and `wait`s for SERVE_PID
2. §4.6 — `parseAmzExpiry` calendar validation: component-level round-trip check replaces `NaN` check
3. §6.5 — `parseAmzExpiry` tests: T-A-P-11 through T-A-P-15 added
4. §6.8 — T-A-auth-real added (real `getAuthContext` implementation, not a stub)

---

## Section 1 — Scope — unchanged from Rev 7 §1

---

## Section 2 — Pre-conditions — unchanged from Rev 7 §2

---

## Section 3 — Directory Structure — unchanged from Rev 7 §3

---

## Section 4 — Shared Module Specification

### 4.1 `errors.ts` — unchanged from Rev 7 §4.1

### 4.2 `crypto.ts` — unchanged from Rev 7 §4.2

### 4.3 `log.ts` — unchanged from Rev 7 §4.3

### 4.4 `context.ts` — unchanged from Rev 7 §4.4

### 4.5 `profile.ts` — unchanged from Rev 7 §4.5

### 4.6 `s3.ts`

**`parseAmzExpiry` — calendar validation updated (Rev 8):**

`Number.isNaN(result.getTime())` alone does not reject every invalid calendar value: JavaScript's `Date.UTC` normalises overflowed field values instead of returning `NaN` (e.g. month-13 → month-1 of the next year; Feb 29 on a non-leap year → Mar 1; Apr 31 → May 1; hour 25 → next-day 01:00). The check must be fail-closed: after constructing the Date from the parsed components, verify that each UTC component of the constructed Date exactly matches the parsed input.

```typescript
// parseAmzExpiry — exported pure function; never throws on missing fields by
// returning undefined; throws on every malformed, invalid, or non-300 value.
//
// Algorithm:
//   1. Extract X-Amz-Date and X-Amz-Expires from the signed URL's query string.
//   2. Verify both are present; throw if either is absent.
//   3. Parse X-Amz-Expires as an integer; throw if not exactly 300.
//   4. Match X-Amz-Date against /^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})Z$/.
//      Throw if the pattern does not match.
//   5. Construct a Date via Date.UTC(year, month-1, day, hour, minute, second).
//   6. Round-trip check: verify that the Date's UTC year/month/day/hour/minute/second
//      exactly equal the parsed values. Throw if any component differs — this is the
//      primary guard against normalised-but-invalid calendar values (non-leap Feb 29,
//      Apr 31, hour 25, minute 60, second 60, etc.).
//   7. Return new Date(date.getTime() + 300_000).
export function parseAmzExpiry(url: string): Date
```

**Implementation contract — component round-trip check:**
```typescript
const date = new Date(Date.UTC(year, month - 1, day, hour, minute, second))

if (
  date.getUTCFullYear()  !== year   ||
  date.getUTCMonth() + 1 !== month  ||
  date.getUTCDate()      !== day    ||
  date.getUTCHours()     !== hour   ||
  date.getUTCMinutes()   !== minute ||
  date.getUTCSeconds()   !== second
) {
  throw new Error(`Calendar-invalid date in X-Amz-Date: ${amzDate}`)
}

return new Date(date.getTime() + 300_000)
```

All other `s3.ts` contracts — `createPresignedPutUrl`, `forcePathStyle: true`, `ExpiresIn: 300` — unchanged from Rev 6 §4.6.

---

## Section 5 — `upload-authorize` Implementation — unchanged from Rev 7 §5

---

## Section 6 — Test Matrix

### 6.1 Unit Test Command — unchanged from Rev 7 §6.1

### 6.2 Integration Runner (`tools/integration-runner.sh`)

**Rev 8 changes:**
- All five S3 variables (`S3_ENDPOINT`, `S3_REGION`, `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY`, `S3_BUCKET`) passed through the `env` block to the Deno child. Without these, `defaultDeps.presign` (and therefore Race B) cannot construct a signed URL.
- `S3_REGION` and `S3_BUCKET` are declared as shell variables immediately after `S3_ENDPOINT` is derived.
- `cleanup()`: `wait "$SERVE_PID"` added after kill to reap the child. psql teardown exit code is captured; if teardown fails and `TEST_EXIT` is currently 0, `TEST_EXIT` is updated to the teardown exit code so that a passing test suite is not incorrectly reported as PASS when teardown failed.

```sh
#!/usr/bin/env bash
set -euo pipefail

LOG="08_Migration/tests/integration-$(date +%Y%m%d-%H%M%S).log"
SERVE_PID=""
TEST_EXIT=1     # default to failure; overwritten by the deno test block

# ── Credential helper ─────────────────────────────────────────────────────────
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
  local _teardown_exit=0

  # Kill and reap the function server
  if [[ -n "$SERVE_PID" ]]; then
    kill "$SERVE_PID" 2>/dev/null || true
    wait "$SERVE_PID" 2>/dev/null || true   # reap; ignore the process's own exit code
  fi

  rm -f supabase/functions/.env.local

  # Capture teardown exit code; do not let failure silently pass
  if [[ -n "${DB_URL:-}" ]]; then
    if ! psql "$DB_URL" -q -c "SELECT cleanup_integration_fixtures();" 2>&1; then
      _teardown_exit=$?
      echo "WARN: cleanup_integration_fixtures() failed (exit ${_teardown_exit})"
    fi
  fi

  unset SUPABASE_URL SUPABASE_PUBLISHABLE_KEY SUPABASE_SECRET_KEY \
        SUPABASE_JWT_SECRET DB_URL \
        S3_ENDPOINT S3_REGION S3_ACCESS_KEY_ID S3_SECRET_ACCESS_KEY S3_BUCKET \
        2>/dev/null || true

  # Promote success → failure if teardown itself failed
  if [[ "$_teardown_exit" -ne 0 && "$TEST_EXIT" -eq 0 ]]; then
    TEST_EXIT="$_teardown_exit"
    echo "WARN: tests passed but teardown failed; result is FAIL"
  fi

  echo "=== RESULT: $([ "${TEST_EXIT}" -eq 0 ] && echo PASS || echo FAIL) ===" \
    | tee -a "$LOG"
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

# ── 6. Readiness poll ─────────────────────────────────────────────────────────
READY=false
for _ in $(seq 1 30); do
  http_code=$(curl -s -o /dev/null -w "%{http_code}" "$FUNCTION_URL" 2>/dev/null || true)
  if [[ "$http_code" == "401" || "$http_code" == "400" || "$http_code" == "405" ]]; then
    READY=true; break
  fi
  sleep 1
done
$READY || { echo "FAIL: function not ready after 30 s"; exit 1; }

# ── 7. Run tests ──────────────────────────────────────────────────────────────
# S3 credentials included so defaultDeps.presign (and Race B) can construct
# signed URLs. Secrets passed via env; never as CLI arguments.
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

### 6.3 Private Session Check Script (`tools/private_session_check.sh`) — unchanged from Rev 7 §6.3

### 6.4 Integration Reserve Adapter — unchanged from Rev 7 §6.4

### 6.5 `parseAmzExpiry` Unit Tests (T-A-P-*)

Tests T-A-P-01 through T-A-P-10 unchanged from Rev 6 §6.5.

**New tests (Rev 8) — calendar validation:**

| # | Input `X-Amz-Date` | Reason | Expected |
|---|---|---|---|
| T-A-P-11 | `20260229T120000Z` | 2026 is not a leap year; JS would normalise to Mar 1 | throws |
| T-A-P-12 | `20260431T120000Z` | April has 30 days; JS would normalise to May 1 | throws |
| T-A-P-13 | `20260101T250000Z` | Hour 25 is invalid; JS would normalise to Jan 2 01:00 | throws |
| T-A-P-14 | `20260101T126000Z` | Minute 60 is invalid; JS would normalise to 13:00 | throws |
| T-A-P-15 | `20260101T120060Z` | Second 60 is invalid; JS would normalise to 12:01:00 | throws |

All five must throw regardless of whether `Number.isNaN(result.getTime())` would catch them (it does not, because JS normalises rather than returning NaN). The component round-trip check is the authoritative guard.

**Example test form (same pattern for all five):**
```typescript
Deno.test('T-A-P-11: Feb 29 on non-leap year throws', () => {
  const url = buildTestUrl({ 'X-Amz-Date': '20260229T120000Z', 'X-Amz-Expires': '300' })
  assertThrows(() => parseAmzExpiry(url), Error)
})
```

### 6.6 Happy Path — unchanged from Rev 7 §6.6

### 6.7 Method Enforcement — unchanged from Rev 7 §6.7

### 6.8 Authentication and Profile

**Rev 8 change:** T-A-auth-real added — tests the real `getAuthContext()` implementation with an invalid JWT, not a stub. This test resides in `upload-authorize.integration.test.ts` because it requires `SUPABASE_URL` and `SUPABASE_PUBLISHABLE_KEY` to be set in the process environment, which the integration runner guarantees via the `env` block in step 7. It does not call the live function endpoint; it imports and calls `getAuthContext` directly.

T-A-auth-cc (stub test) is retained as a unit test to confirm handler wiring independently of the shared wrapper.

| # | Description | Type | Expected |
|---|---|---|---|
| T-A-11 | Missing `Authorization` header (live function) | Integration | 401; gateway or `FK_UNAUTHENTICATED`; `Cache-Control` outside application control |
| T-A-12 | Malformed JWT (live function) | Integration | 401 |
| T-A-13 | Expired JWT (live function) | Integration | 401 |
| T-A-auth-cc | `stubAuthFail` returns `authResult.error` (handler wiring) | Unit | 401; `Cache-Control: no-store` |
| T-A-auth-real | Real `getAuthContext()` with invalid JWT token | Integration | `ok: false`; `error.status === 401`; `error.headers.get('Cache-Control') === 'no-store'` |
| T-A-14 | `is_active = false` stub | Unit | 403 `FK_FORBIDDEN`; `Cache-Control: no-store` |
| T-A-15 | Deletion-prepared profile (`is_active=false`) | Integration | 403 `FK_FORBIDDEN` |
| T-A-16 | `onboarding_complete = false` stub | Unit | 403 `FK_FORBIDDEN` |
| T-A-17 | `is_suspended = true` stub | Unit | 403 `FK_FORBIDDEN` |
| T-A-18 | Profile row absent stub | Unit | 403 `FK_FORBIDDEN` |
| T-A-19 | Profile check `'error'` stub | Unit | 500 `FK_INTERNAL` |

**T-A-auth-real implementation:**
```typescript
// In upload-authorize.integration.test.ts
// getAuthContext is imported from _shared/context.ts
// SUPABASE_URL and SUPABASE_PUBLISHABLE_KEY are available in the env block
// supplied by integration-runner.sh — no live function endpoint is contacted.
Deno.test('T-A-auth-real: real getAuthContext returns 401 + Cache-Control: no-store on invalid JWT', async () => {
  const req = new Request('https://example.com/', {
    method: 'POST',
    headers: { 'Authorization': 'Bearer definitely.not.a.valid.jwt' },
  })
  const result = await getAuthContext(req)
  assertEquals(result.ok, false)
  assert(result.error !== null)
  assertEquals(result.error.status, 401)
  assertEquals(result.error.headers.get('Cache-Control'), 'no-store')
  // Body must be valid JSON with an error code (no internal detail)
  const body = await result.error.json()
  assertEquals(typeof body.error.code, 'string')
})
```

**T-A-auth-cc stub (unit, unchanged from Rev 7):**
```typescript
const stubAuthFail: Deps['getAuth'] = async () => ({
  ok: false,
  ctx: null,
  error: new Response(
    JSON.stringify({ error: { code: 'FK_UNAUTHENTICATED', message: 'Unauthorized' } }),
    { status: 401, headers: {
        'Content-Type': 'application/json',
        'Cache-Control': 'no-store',
    }},
  ),
})

const res = await makeHandler({ ...defaultDeps, getAuth: stubAuthFail })(fakePostRequest())
assertEquals(res.status, 401)
assertEquals(res.headers.get('Cache-Control'), 'no-store')
```

### 6.9 Request Validation (T-A-20 to T-A-30) — unchanged from Rev 7 §6.9

### 6.10 DB-Driven Errors (T-A-31 to T-A-40) — unchanged from Rev 7 §6.10

### 6.11 Presign, Activate, and Unexpected Failures (T-A-41 to T-A-48) — unchanged from Rev 7 §6.11

### 6.12 Race B — Concurrent Duplicate Reservations — unchanged from Rev 7 §6.12

### 6.13 Race A — Formal Deferral (Amendment C) — unchanged from Rev 7 §6.13

---

## Section 7 — Environment Variables — unchanged from Rev 7 §7

---

## Section 8 — Scaffold and Quality Gates — unchanged from Rev 7 §8

---

## Section 9 — Dependency Versions — unchanged from Rev 7 §9

---

## Section 10 — Amendments Summary — unchanged from Rev 7 §10

---

## Section 11 — Approval Record

| Party | Status | Required phrase |
|---|---|---|
| Claude | Approved | Rev 8; all 3 Rev 7 blockers + 1 required test resolved; Amendment C acknowledged |
| Codex | Pending | `APPROVED: Step A Rev 8 — upload-authorize` |
| Bill | Pending | `APPROVED: Step A Rev 8 — upload-authorize — Amendment C acknowledged` |

**This approval authorizes TypeScript implementation only. No cloud deployment authorized.**
