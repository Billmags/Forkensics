# Step A Proposal — Rev 7 — `upload-authorize` Edge Function

**Status:** DRAFT — Awaiting three-party approval (Claude + Codex + Bill)

**Supersedes:** Rev 6 (CHANGES REQUIRED — 5 blockers)

**Governance gate:** All three parties must approve before any TypeScript is written.
Magic words:
- Codex: `APPROVED: Step A Rev 7 — upload-authorize`
- Bill:   `APPROVED: Step A Rev 7 — upload-authorize — Amendment C acknowledged`

**Binding contracts:**
- Step 27 Rev 5 (approved 2026-08-12) — §5.1, §6, §7, §8
- Step 24 Rev 10 (approved 2026-08-07) — §5.1 test matrix
  - **Amendment A** — Session claim window: Step 24 §4.1 5-minute window → 15 minutes. §5.3.
  - **Amendment B** — Local S3 credentials: Step 27's `stub`/`ANON_KEY` → Gate 4 evidence. §7.
  - **Amendment C** — Race A full orchestration deferred to `account-delete-complete` step. §6.13.
- V2 migration SHA-256: `0f9adbb732f671008629854398fb7d5c3962a315338e3eff08b3a45eccea161a`
- V4 migration SHA-256: `0eb78c66878df50f22278fb36f2b089d3f2b81ded2f550a945e9d0dd55dd0f66`
  - V4 applied: `public.challenges → public.cases`; `p_challenge_id → p_case_id`

---

## Section 1 — Scope

This step covers:
1. Scaffolding of `supabase/functions/_shared/` (first use)
2. `supabase/functions/upload-authorize/index.ts`
3. `supabase/functions/upload-authorize/upload-authorize.test.ts`
4. `supabase/functions/upload-authorize/upload-authorize.integration.test.ts`
5. `tools/integration-runner.sh`, `tools/integration-fixtures.sql`, `tools/private_session_check.sh`
6. `deno.lock` — Gate 6, generated before any TypeScript implementation

Not covered: cloud deployment, other functions, `cron.ts`, Gate 2B, Race A full orchestration.

**Security constraints (immutable):** Secret key never in repo or sent to Claude. No cloud operations. `private` schema not exposed through PostgREST. Raw JWT decoding prohibited. `createSignedUploadUrl()` prohibited.

---

## Section 2 — Pre-conditions

| Pre-condition | Status |
|---|---|
| Gate 5 (Deno + gitleaks) | ✅ Passed — Deno 2.9.5, gitleaks 8.30.1 |
| Gate 4 (local S3 preflight) | ✅ Passed — 2026-08-13 |
| Gate 3 (pg_cron/pg_net local) | ✅ Passed — 2026-08-13 |
| Gate 1 (V2 migration applied) | ✅ Satisfied — V2/V4 applied and regression-tested |
| Dependency versions pinned | ✅ All four confirmed — see Section 9 |
| Three-party approval of this proposal | ⏳ Pending |

---

## Section 3 — Directory Structure

```
supabase/functions/
  _shared/
    context.ts
    profile.ts
    s3.ts
    errors.ts
    log.ts
    crypto.ts
  upload-authorize/
    index.ts
    upload-authorize.test.ts
    upload-authorize.integration.test.ts
tools/
  integration-runner.sh
  integration-fixtures.sql
  private_session_check.sh
supabase/functions/
  .env.example     ← key names only; no values; committed
  .env.local       ← generated at runtime; 0600; git-ignored; deleted on cleanup
deno.lock
```

---

## Section 4 — Shared Module Specification

### 4.1 `errors.ts` — unchanged from Rev 6 §4.1

### 4.2 `crypto.ts` — unchanged from Rev 6 §4.2

### 4.3 `log.ts` — unchanged from Rev 6 §4.3

### 4.4 `context.ts`

The wrapper must produce a sanitized 401 response with `Cache-Control: no-store` on all authentication failures, so that the handler can return `authResult.error` directly and the header is always present regardless of the underlying cause. Gateway-short-circuited responses (`verify_jwt = true`) remain outside application control and are not subject to this requirement.

```typescript
import { createSupabaseContext } from 'npm:@supabase/server@1.4.1'

// Wraps createSupabaseContext(req, { auth: 'user' }).
// Hosted env: SUPABASE_PUBLISHABLE_KEYS / SUPABASE_SECRET_KEYS / SUPABASE_JWKS (plural).
// Local fallbacks: SUPABASE_PUBLISHABLE_KEY / SUPABASE_SECRET_KEY (singular).
//
// On any authentication failure, returns a sanitized 401 Response that includes
// Cache-Control: no-store. The handler returns this Response directly; it never
// needs to add the header itself.
//
// Never throws. Never decodes JWT manually.
export async function getAuthContext(req: Request): Promise<
  | { ok: true;  ctx: AuthContext; error: null }
  | { ok: false; ctx: null;       error: Response }
>

export interface AuthContext {
  userClaims: { id: string }
  supabase:      SupabaseClient
  supabaseAdmin: SupabaseClient
}
```

**Implementation contract:** On any auth failure, the returned `error` Response is constructed as:
```typescript
new Response(
  JSON.stringify({ error: { code: 'FK_UNAUTHENTICATED', message: 'Unauthorized' } }),
  { status: 401, headers: {
      'Content-Type': 'application/json',
      'Cache-Control': 'no-store',
  }},
)
```

### 4.5 `profile.ts` — unchanged from Rev 6 §4.5

### 4.6 `s3.ts` — unchanged from Rev 6 §4.6

---

## Section 5 — `upload-authorize` Implementation

### 5.1 HTTP Contract — unchanged from Rev 6 §5.1

Non-`POST` → 405 with `Allow: POST` and `Cache-Control: no-store`.
All responses (including auth failures returned from `getAuthContext`): `Cache-Control: no-store`.

### 5.2 `config.toml` — unchanged from Rev 6 §5.2

### 5.3 Session Timing (Amendment A) — unchanged from Rev 6 §5.3

### 5.4 Dependency Interface — unchanged from Rev 6 §5.4

### 5.5 `bestEffortFail` Helper — unchanged from Rev 6 §5.5

### 5.6 Implementation Sequence — unchanged from Rev 6 §5.6

The handler returns `authResult.error` directly at Step 1; because `getAuthContext` guarantees `Cache-Control: no-store` on that Response, the handler does not need to add the header.

### 5.7 Error Response Table — unchanged from Rev 6 §5.8

---

## Section 6 — Test Matrix

### 6.1 Unit Test Command — unchanged from Rev 6 §6.1

### 6.2 Integration Runner (`tools/integration-runner.sh`)

All five blockers addressed:
- `set -euo pipefail` with `if deno test … ; then/else` for explicit exit-code capture
- Readiness `curl` uses `|| true` to survive connection failures under `set -e`
- Single `trap cleanup EXIT`; signal traps exit with standard codes (130 = SIGINT, 143 = SIGTERM)
- Cleanup removes `.env.local`; runs only once
- Key extraction supports current names (`PUBLISHABLE_KEY`, `SECRET_KEY`) with legacy fallback (`ANON_KEY`, `SERVICE_ROLE_KEY`)
- S3 endpoint derived from `${SUPABASE_URL}/storage/v1/s3` (not `STORAGE_S3_URL`)
- `.env.local` written with permissions `0600`
- Secrets exported to child process via `env`; never passed as CLI arguments

```sh
#!/usr/bin/env bash
set -euo pipefail

LOG="08_Migration/tests/integration-$(date +%Y%m%d-%H%M%S).log"
SERVE_PID=""
TEST_EXIT=1     # default to failure; overwritten by the deno test block

# ── Credential helper ─────────────────────────────────────────────────────────
# Try primary key name; fall back to legacy name if present.
_env() {
  supabase status -o env 2>/dev/null | grep "^${1}=" | cut -d= -f2- | tr -d "\"'" || true
}
_env_fb() {
  # _env_fb PRIMARY LEGACY — returns PRIMARY if set, otherwise LEGACY
  local v
  v=$(_env "$1")
  [[ -z "$v" ]] && v=$(_env "$2")
  echo "$v"
}

# ── Cleanup: runs exactly once on EXIT ───────────────────────────────────────
cleanup() {
  [[ -n "$SERVE_PID" ]] && kill "$SERVE_PID" 2>/dev/null || true
  rm -f supabase/functions/.env.local
  [[ -n "${DB_URL:-}" ]] && \
    psql "$DB_URL" -q -c "SELECT cleanup_integration_fixtures();" 2>/dev/null || true
  unset SUPABASE_URL SUPABASE_PUBLISHABLE_KEY SUPABASE_SECRET_KEY \
        SUPABASE_JWT_SECRET DB_URL \
        S3_ACCESS_KEY_ID S3_SECRET_ACCESS_KEY 2>/dev/null || true
  echo "=== RESULT: $([ "${TEST_EXIT}" -eq 0 ] && echo PASS || echo FAIL) ===" \
    | tee -a "$LOG"
}
trap cleanup EXIT           # runs cleanup on normal exit and on signal-induced exit
trap 'exit 130' INT         # SIGINT  → cleanup via EXIT trap, then exit 130
trap 'exit 143' TERM        # SIGTERM → cleanup via EXIT trap, then exit 143

exec > >(tee -a "$LOG") 2>&1
echo "=== upload-authorize integration suite ==="
echo "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ── 1. Preflight ──────────────────────────────────────────────────────────────
supabase status --output env > /dev/null

# ── 2. Credentials ───────────────────────────────────────────────────────────
SUPABASE_URL=$(_env API_URL)
SUPABASE_PUBLISHABLE_KEY=$(_env_fb PUBLISHABLE_KEY ANON_KEY)   # current name first
SUPABASE_SECRET_KEY=$(_env_fb SECRET_KEY SERVICE_ROLE_KEY)      # current name first
SUPABASE_JWT_SECRET=$(_env JWT_SECRET)
DB_URL=$(_env DB_URL)
S3_ACCESS_KEY_ID=$(_env S3_PROTOCOL_ACCESS_KEY_ID)
S3_SECRET_ACCESS_KEY=$(_env S3_PROTOCOL_ACCESS_KEY_SECRET)

for var in SUPABASE_URL SUPABASE_PUBLISHABLE_KEY SUPABASE_SECRET_KEY \
           SUPABASE_JWT_SECRET DB_URL S3_ACCESS_KEY_ID S3_SECRET_ACCESS_KEY; do
  [[ -z "${!var}" ]] && { echo "FAIL: could not read ${var}"; exit 1; }
done

# Derive S3 endpoint from SUPABASE_URL (STORAGE_S3_URL is not guaranteed in status output)
S3_ENDPOINT="${SUPABASE_URL}/storage/v1/s3"
FUNCTION_URL="${SUPABASE_URL}/functions/v1/upload-authorize"

# ── 3. Generate .env.local (0600; git-ignored; deleted in cleanup) ────────────
touch supabase/functions/.env.local
chmod 0600 supabase/functions/.env.local
cat > supabase/functions/.env.local << ENVEOF
SUPABASE_URL=${SUPABASE_URL}
SUPABASE_PUBLISHABLE_KEY=${SUPABASE_PUBLISHABLE_KEY}
SUPABASE_SECRET_KEY=${SUPABASE_SECRET_KEY}
S3_ENDPOINT=${S3_ENDPOINT}
S3_REGION=local
S3_ACCESS_KEY_ID=${S3_ACCESS_KEY_ID}
S3_SECRET_ACCESS_KEY=${S3_SECRET_ACCESS_KEY}
S3_BUCKET=game-media
ENVEOF

# ── 4. Fixtures ───────────────────────────────────────────────────────────────
psql "$DB_URL" -q -f tools/integration-fixtures.sql

# ── 5. Serve (config.toml supplies verify_jwt; no extra flags needed) ─────────
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
   deno test \
     --allow-net --allow-env --allow-read --allow-run \
     supabase/functions/upload-authorize/upload-authorize.integration.test.ts; then
  TEST_EXIT=0
else
  TEST_EXIT=$?
fi

exit "$TEST_EXIT"
```

### 6.3 Private Session Check Script (`tools/private_session_check.sh`) — unchanged from Rev 6 §6.3

### 6.4 Integration Reserve Adapter — unchanged from Rev 6 §6.4

### 6.5 `parseAmzExpiry` Unit Tests (T-A-P-*) — unchanged from Rev 6 §6.5, including T-A-P-10 (month 13)

### 6.6 Happy Path — unchanged from Rev 6 §6.6

### 6.7 Method Enforcement — unchanged from Rev 6 §6.7

### 6.8 Authentication and Profile

All tests unchanged except one addition: T-A-auth-cc verifies the handler-level auth failure carries `Cache-Control: no-store` (via stub; not a gateway test).

| # | Description | Type | Expected |
|---|---|---|---|
| T-A-11 | Missing `Authorization` header (live function) | Integration | 401; gateway or `FK_UNAUTHENTICATED`; `Cache-Control` outside application control |
| T-A-12 | Malformed JWT (live function) | Integration | 401 |
| T-A-13 | Expired JWT (live function) | Integration | 401 |
| T-A-auth-cc | `stubAuthFail` (unit stub, not gateway) returns `authResult.error` | Unit | 401; response headers include `Cache-Control: no-store` |
| T-A-14 | `is_active = false` stub | Unit | 403 `FK_FORBIDDEN`; `Cache-Control: no-store` |
| T-A-15 | Deletion-prepared profile (`is_active=false`) | Integration | 403 `FK_FORBIDDEN` |
| T-A-16 | `onboarding_complete = false` stub | Unit | 403 `FK_FORBIDDEN` |
| T-A-17 | `is_suspended = true` stub | Unit | 403 `FK_FORBIDDEN` |
| T-A-18 | Profile row absent stub | Unit | 403 `FK_FORBIDDEN` |
| T-A-19 | Profile check `'error'` stub | Unit | 500 `FK_INTERNAL` |

**`stubAuthFail` for T-A-auth-cc:**
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

// T-A-auth-cc assertion:
const res = await makeHandler({ ...defaultDeps, getAuth: stubAuthFail })(fakePostRequest())
assertEquals(res.status, 401)
assertEquals(res.headers.get('Cache-Control'), 'no-store')
```

### 6.9 Request Validation (T-A-20 to T-A-30) — unchanged from Rev 6 §6.9

### 6.10 DB-Driven Errors (T-A-31 to T-A-40) — unchanged from Rev 6 §6.10

### 6.11 Presign, Activate, and Unexpected Failures (T-A-41 to T-A-48) — unchanged from Rev 6 §6.11

### 6.12 Race B — Concurrent Duplicate Reservations

Updated to record both `p_token_hash` values **before** the barrier, proving both distinct hashes entered the reservation path.

**Latch pattern** — unchanged from Rev 6.

**Hash-recording latch adapter:**
```typescript
const attemptedHashes: string[] = []
const latchedReserve: Deps['reserveSession'] = async (admin, params) => {
  // Record the attempted hash BEFORE the barrier — proves both reached reservation
  attemptedHashes.push(params.p_token_hash)
  await latch.wait()    // hold until both have arrived
  return defaultDeps.reserveSession(admin, params)
}

// Both handler instances use distinct token stubs and the same poster/case
const handlerA = makeHandler({
  ...defaultDeps,
  generateToken:   () => tokenA,  // pre-chosen base64url string
  sha256:          fixedSha256Map, // deterministic: tokenA → hashA, tokenB → hashB
  reserveSession:  latchedReserve,
  activateSession: defaultDeps.activateSession,
  presign:         defaultDeps.presign,
})
const handlerB = makeHandler({
  ...defaultDeps,
  generateToken:   () => tokenB,
  sha256:          fixedSha256Map,
  reserveSession:  latchedReserve,
  activateSession: defaultDeps.activateSession,
  presign:         defaultDeps.presign,
})
```

**Assertion sequence:**
```typescript
const [resA, resB] = await Promise.all([
  handlerA(makePostRequest(posterJwt, caseId, 'image/jpeg', 1024)),
  handlerB(makePostRequest(posterJwt, caseId, 'image/jpeg', 1024)),
])

// 1. Exactly one 200 and one 409
const statuses = [resA.status, resB.status].sort()
assertEquals(statuses, [200, 409])

// 2. 409 body contains FK_UPLOAD_IN_PROGRESS
const loser = resA.status === 409 ? resA : resB
assertEquals((await loser.json()).error.code, 'FK_UPLOAD_IN_PROGRESS')

// 3. Exactly one active session row in DB
const rows = await psqlQuery(
  "SELECT status FROM private.upload_sessions " +
  "WHERE case_id = $1 AND status IN ('pending','processing','sanitized')",
  [caseId],
)
assertEquals(rows.length, 1)

// 4. Both distinct hashes reached the reservation path
assertEquals(attemptedHashes.length, 2,
  'exactly two reserve calls must have recorded a hash before the barrier')
const hashSet = new Set(attemptedHashes)
assertEquals(hashSet.size, 2, 'both hashes must be distinct')
assert(hashSet.has(hashA) && hashSet.has(hashB),
  'attempted set must equal {hashA, hashB}')
```

### 6.13 Race A — Formal Deferral (Amendment C) — unchanged from Rev 6 §6.13

---

## Section 7 — Environment Variables — unchanged from Rev 6 §7

S3 endpoint note updated: endpoint is always derived as `${SUPABASE_URL}/storage/v1/s3` in the runner; `STORAGE_S3_URL` is not used because it is not guaranteed to appear in `supabase status -o env`.

---

## Section 8 — Scaffold and Quality Gates

### Gate 6

```sh
deno check supabase/functions/_shared/*.ts supabase/functions/upload-authorize/*.ts
deno fmt --check supabase/functions/
deno lint supabase/functions/
gitleaks detect --source . --no-git
```

### deno.lock

Integration test file added to ensure its scoped dependencies are covered by the lock:

```sh
deno cache --lock=deno.lock \
  supabase/functions/_shared/{context,profile,s3,errors,log,crypto}.ts \
  supabase/functions/upload-authorize/index.ts \
  supabase/functions/upload-authorize/upload-authorize.test.ts \
  supabase/functions/upload-authorize/upload-authorize.integration.test.ts
```

`deno.lock` is committed and is the authoritative version source. If `deno cache` resolves any direct dependency differently from Section 9, the Section 9 entry is corrected to match the lock file before implementation proceeds.

### `config.toml`

```toml
[functions.upload-authorize]
verify_jwt = true
```

---

## Section 9 — Dependency Versions

All four versions confirmed present on npm (HTTP 200, 2026-08-13). The prior Codex review saw older versions because the 2026-08-11/12 publications postdated the review. `deno cache` at Gate 6 is the final confirmation.

| Import specifier | Pinned version | npm publish date |
|---|---|---|
| `npm:@supabase/server@1.4.1` | **1.4.1** | 2026-07-22 |
| `npm:@supabase/supabase-js@2.112.3` | **2.112.3** | 2026-08-11 |
| `npm:@aws-sdk/client-s3@3.1109.0` | **3.1109.0** | 2026-08-12 |
| `npm:@aws-sdk/s3-request-presigner@3.1109.0` | **3.1109.0** | 2026-08-12 |

---

## Section 10 — Amendments Summary

| Amendment | Supersedes | Content |
|---|---|---|
| A — Session claim window | Step 24 §4.1 | 5 min → 15 min; §5.3 |
| B — Local S3 credentials | Step 27 §8 | Gate 4 evidence supersedes stub values; §7 |
| C — Race A orchestration deferral | Step 24 §5.1 | Deferred to `account-delete-complete` step; §6.13 |

---

## Section 11 — Approval Record

| Party | Status | Required phrase |
|---|---|---|
| Claude | Approved | Rev 7; all 5 Rev 6 blockers resolved; Amendment C acknowledged |
| Codex | Pending | `APPROVED: Step A Rev 7 — upload-authorize` |
| Bill | Pending | `APPROVED: Step A Rev 7 — upload-authorize — Amendment C acknowledged` |

**This approval authorizes TypeScript implementation only. No cloud deployment authorized.**
