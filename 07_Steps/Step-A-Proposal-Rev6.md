# Step A Proposal — Rev 6 — `upload-authorize` Edge Function

**Status:** DRAFT — Awaiting three-party approval (Claude + Codex + Bill)

**Supersedes:** Rev 5 (CHANGES REQUIRED — 5 blockers)

**Governance gate:** All three parties must approve before any TypeScript is written.
Magic words:
- Codex: `APPROVED: Step A Rev 6 — upload-authorize`
- Bill:   `APPROVED: Step A Rev 6 — upload-authorize — Amendment C acknowledged`

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
    context.ts          ← getAuthContext
    profile.ts          ← checkActiveProfile, checkProfileExists
    s3.ts               ← parseAmzExpiry (exported), presignPutUrl
    errors.ts           ← errorEnvelope, FkErrorCode, extractDbErrorCode
    log.ts              ← safeLog
    crypto.ts           ← sha256Hex, generateUploadToken
  upload-authorize/
    index.ts            ← makeHandler, bestEffortFail, defaultDeps
    upload-authorize.test.ts           ← unit tests
    upload-authorize.integration.test.ts ← integration tests
tools/
  integration-runner.sh
  integration-fixtures.sql
  private_session_check.sh
supabase/functions/
  .env.example          ← documents required keys without values (committed)
  .env.local            ← generated at runtime from supabase status; git-ignored
deno.lock
```

---

## Section 4 — Shared Module Specification

### 4.1 `errors.ts`

```typescript
export type FkErrorCode =
  | 'FK_UNAUTHENTICATED'   | 'FK_FORBIDDEN'          | 'FK_NOT_FOUND'
  | 'FK_WRONG_STATE'       | 'FK_UPLOAD_IN_PROGRESS'  | 'FK_FILE_TOO_LARGE'
  | 'FK_INVALID_CONTENT_TYPE' | 'FK_INVALID_INPUT'   | 'FK_INVALID_TOKEN'
  | 'FK_INTERNAL'          | 'FK_PROCESSING_FAILED'

export function errorEnvelope(code: FkErrorCode, message: string, status: number): Response
export function extractDbErrorCode(err: unknown): FkErrorCode | null
```

### 4.2 `crypto.ts`

```typescript
// 32 random bytes → base64url (43 chars, ~256 bits).
export function generateUploadToken(): string
// SHA-256 → lowercase 64-char hex.
export async function sha256Hex(data: Uint8Array): Promise<string>
```

### 4.3 `log.ts`

```typescript
// status is always a real HTTP status code (never 0).
// user_id: only after auth confirmed. case_id: only after body validated.
// NEVER logged: paths, tokens, presigned URLs, secrets, keys, JWTs,
//               raw DB messages, content_type, declared_size_bytes.
export function safeLog(fields: {
  fn: string; status: number; duration_ms: number;
  error_code?: FkErrorCode; request_id?: string;
  user_id?: string; case_id?: string; outcome?: string
}): void
```

### 4.4 `context.ts`

```typescript
import { createSupabaseContext } from 'npm:@supabase/server@1.4.1'

// Wraps createSupabaseContext(req, { auth: 'user' }).
// Hosted env: SUPABASE_PUBLISHABLE_KEYS / SUPABASE_SECRET_KEYS / SUPABASE_JWKS (plural).
// Local fallbacks: SUPABASE_PUBLISHABLE_KEY / SUPABASE_SECRET_KEY (singular).
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

### 4.5 `profile.ts`

`public.profiles` columns queried: `is_active`, `onboarding_complete`, `is_suspended` (added by V3). No `auth_deleted_at` on `public.profiles`; deletion-prepared accounts have `is_active = false`.

```typescript
export type ProfileCheckResult =
  | { status: 'ok' }
  | { status: 'forbidden'; reason: 'absent' | 'inactive' | 'incomplete' | 'suspended' }
  | { status: 'error' }

export async function checkActiveProfile(supabase: SupabaseClient, userId: string): Promise<ProfileCheckResult>
export async function checkProfileExists(supabase: SupabaseClient, userId: string): Promise<{ ok: boolean; error: boolean }>
```

### 4.6 `s3.ts`

`parseAmzExpiry` is exported as a pure function for direct unit testing.

```typescript
// Pure fail-closed parser.
// Throws if:
//   - X-Amz-Date absent or not matching /^\d{8}T\d{6}Z$/
//   - X-Amz-Expires absent, not parseable as integer, or !== 300
//   - constructed Date is invalid (Number.isNaN(result.getTime()) — catches calendar-invalid
//     values such as month 13, day 32, etc.)
// Returns: parseAmzDate(X-Amz-Date) + 300 seconds.
export function parseAmzExpiry(signedUrl: string): Date

// Signs a presigned PUT URL. Calls parseAmzExpiry on the result.
// expiresIn MUST be 300 (literal type). forcePathStyle: true.
// Throws on signing or parse failure (caller compensates).
export async function presignPutUrl(
  objectPath: string, expiresIn: 300,
): Promise<{ url: string; expiresAt: Date }>
```

---

## Section 5 — `upload-authorize` Implementation

### 5.1 HTTP Contract

```
POST /upload-authorize
Authorization: Bearer <user JWT>
Content-Type: application/json
{ "case_id": "<uuid>", "content_type": "image/jpeg"|"image/webp", "declared_size_bytes": <1–10485760> }
```

**Response 200:**
```json
{ "presigned_url": "...", "upload_token": "<base64url, 43 chars>", "expires_at": "<ISO 8601>" }
```

Non-`POST` → 405 with `Allow: POST` and `Cache-Control: no-store`.
All responses: `Cache-Control: no-store`. `session_id` never present.

### 5.2 `config.toml`

```toml
[functions.upload-authorize]
verify_jwt = true
```

### 5.3 Session Timing (Amendment A)

| Window | Value | Source |
|---|---|---|
| `p_client_expires_at` | `now() + 900s` | Handler clock |
| `ExpiresIn` | `300` | Literal S3 parameter |
| `expiresAt` | `parseAmzExpiry(signedUrl)` | Parsed from signed URL — authoritative |
| `p_actual_storage_upload_expires_at` | `expiresAt.toISOString()` | Same `Date` as response |
| Response `expires_at` | `expiresAt.toISOString()` | Same `Date` |

**Invariant:** `X-Amz-Expires = 300`. `parseAmzDate(X-Amz-Date) + 300s = expiresAt = response.expires_at = DB storage_upload_expires_at`. All four encode the same instant.

### 5.4 Dependency Interface

All three RPC adapters are `async` functions returning fully resolved `Promise<{ data, error }>`. `.single()` is applied inside `reserveSession` only. Callers never call `.single()` again.

```typescript
export interface Deps {
  generateToken:   () => string
  sha256:          (data: Uint8Array) => Promise<string>
  getAuth:         (req: Request) => Promise<AuthResult>
  checkProfile:    (supabase: SupabaseClient, userId: string) => Promise<ProfileCheckResult>
  reserveSession:  (admin: SupabaseClient, params: ReserveParams) =>
                     Promise<{ data: ReserveResult | null; error: unknown }>
  activateSession: (admin: SupabaseClient, params: ActivateParams) =>
                     Promise<{ data: null; error: unknown }>
  failSession:     (admin: SupabaseClient, sessionId: string, code: FkErrorCode) =>
                     Promise<{ data: null; error: unknown }>
  presign:         (path: string, expiresIn: 300) => Promise<{ url: string; expiresAt: Date }>
  now:             () => Date
}

export const defaultDeps: Deps = {
  generateToken:   generateUploadToken,
  sha256:          sha256Hex,
  getAuth:         getAuthContext,
  checkProfile:    checkActiveProfile,
  reserveSession:  async (admin, p) =>
    await admin.rpc('reserve_upload_session', p).single(),
  activateSession: async (admin, p) =>
    await admin.rpc('activate_upload_session', p),
  failSession:     async (admin, id, code) =>
    await admin.rpc('fail_upload_session', { p_session_id: id, p_error_code: code }),
  presign:         presignPutUrl,
  now:             () => new Date(),
}

export function makeHandler(deps: Deps = defaultDeps): (req: Request) => Promise<Response>
```

### 5.5 `bestEffortFail` Helper

Called exactly once per failure path. Never throws. Inspects `{ error }` and catches any exception.

```typescript
async function bestEffortFail(
  deps: Deps, admin: SupabaseClient, sessionId: string,
  request_id: string, t0: number,
): Promise<void> {
  try {
    const { error } = await deps.failSession(admin, sessionId, 'FK_INTERNAL')
    if (error) {
      safeLog({ fn: 'upload-authorize', status: 500, duration_ms: elapsed(t0),
                outcome: 'fail_session_error', request_id })
    }
  } catch {
    safeLog({ fn: 'upload-authorize', status: 500, duration_ms: elapsed(t0),
              outcome: 'fail_session_error', request_id })
  }
  // Never throws.
}
```

### 5.6 Implementation Sequence

`admin`, `sessionId`, and `compensationAttempted` are declared outside `try` so the catch block can reference them. `compensationAttempted` is set to `true` before calling `bestEffortFail` in Steps 6 and 7; the outer catch only compensates when it remains `false`.

```typescript
export function makeHandler(deps: Deps = defaultDeps) {
  return async (req: Request): Promise<Response> => {

    // Step 0 — Method enforcement (outside try)
    if (req.method !== 'POST') {
      return new Response('Method Not Allowed', {
        status: 405,
        headers: { Allow: 'POST', 'Cache-Control': 'no-store' },
      })
    }

    const request_id = req.headers.get('X-Request-Id') ?? crypto.randomUUID()
    const t0 = performance.now()
    let admin: SupabaseClient | null = null
    let sessionId: string | null = null
    let compensationAttempted = false   // prevents double-compensation

    try {

      // Step 1 — Auth
      const authResult = await deps.getAuth(req)
      if (!authResult.ok) {
        safeLog({ fn: 'upload-authorize', status: 401, duration_ms: elapsed(t0),
                  error_code: 'FK_UNAUTHENTICATED', request_id })
        return authResult.error
      }
      admin = authResult.ctx.supabaseAdmin    // assigned for catch block

      // Step 2 — Profile
      const pr = await deps.checkProfile(authResult.ctx.supabase, authResult.ctx.userClaims.id)
      if (pr.status === 'forbidden') {
        safeLog({ fn: 'upload-authorize', status: 403, duration_ms: elapsed(t0),
                  error_code: 'FK_FORBIDDEN', request_id, user_id: authResult.ctx.userClaims.id })
        return errorEnvelope('FK_FORBIDDEN', 'Profile not eligible', 403)
      }
      if (pr.status === 'error') {
        safeLog({ fn: 'upload-authorize', status: 500, duration_ms: elapsed(t0),
                  error_code: 'FK_INTERNAL', request_id, user_id: authResult.ctx.userClaims.id })
        return errorEnvelope('FK_INTERNAL', 'Internal error', 500)
      }

      // Step 3 — Body validation (validateBody is a pure helper)
      const bodyResult = await parseAndValidateBody(req)
      if (!bodyResult.ok) {
        safeLog({ fn: 'upload-authorize', status: bodyResult.status,
                  duration_ms: elapsed(t0), error_code: bodyResult.code,
                  request_id, user_id: authResult.ctx.userClaims.id })
        return errorEnvelope(bodyResult.code, bodyResult.message, bodyResult.status)
      }
      const { caseId, contentType, declaredSizeBytes } = bodyResult

      // Step 4 — Token
      const rawToken     = deps.generateToken()
      const tokenHash    = await deps.sha256(new TextEncoder().encode(rawToken))
      const sessionExpiry = new Date(deps.now().getTime() + 900_000)

      // Step 5 — Reserve
      const { data: row, error: reserveErr } = await deps.reserveSession(
        authResult.ctx.supabaseAdmin, {
          p_case_id: caseId, p_uploader_id: authResult.ctx.userClaims.id,
          p_token_hash: tokenHash, p_content_type: contentType,
          p_declared_size: declaredSizeBytes,
          p_client_expires_at: sessionExpiry.toISOString(),
        })
      if (reserveErr) {
        const code = extractDbErrorCode(reserveErr) ?? 'FK_INTERNAL'
        const status = ({ FK_NOT_FOUND: 404, FK_WRONG_STATE: 409,
                          FK_UPLOAD_IN_PROGRESS: 409, FK_FORBIDDEN: 403
                        } as Record<string, number>)[code] ?? 500
        safeLog({ fn: 'upload-authorize', status, error_code: code as FkErrorCode,
                  duration_ms: elapsed(t0), request_id,
                  user_id: authResult.ctx.userClaims.id, case_id: caseId })
        return errorEnvelope(code as FkErrorCode, 'Reservation failed', status)
      }
      if (!row) {
        safeLog({ fn: 'upload-authorize', status: 500, error_code: 'FK_INTERNAL',
                  duration_ms: elapsed(t0), request_id,
                  user_id: authResult.ctx.userClaims.id, case_id: caseId })
        return errorEnvelope('FK_INTERNAL', 'Internal error', 500)
      }
      sessionId = row.session_id

      // Step 6 — Presign
      let presignedUrl: string, urlExpiresAt: Date
      try {
        ({ url: presignedUrl, expiresAt: urlExpiresAt } =
          await deps.presign(row.original_storage_path, 300))
      } catch {
        compensationAttempted = true
        await bestEffortFail(deps, authResult.ctx.supabaseAdmin, sessionId, request_id, t0)
        safeLog({ fn: 'upload-authorize', status: 500, error_code: 'FK_INTERNAL',
                  outcome: 'failed_presign', duration_ms: elapsed(t0),
                  request_id, user_id: authResult.ctx.userClaims.id, case_id: caseId })
        return errorEnvelope('FK_INTERNAL', 'Internal error', 500)
      }

      // Step 7 — Activate
      const { error: activateErr } = await deps.activateSession(authResult.ctx.supabaseAdmin, {
        p_session_id: sessionId,
        p_actual_storage_upload_expires_at: urlExpiresAt.toISOString(),
      })
      if (activateErr) {
        compensationAttempted = true
        await bestEffortFail(deps, authResult.ctx.supabaseAdmin, sessionId, request_id, t0)
        safeLog({ fn: 'upload-authorize', status: 500, error_code: 'FK_INTERNAL',
                  outcome: 'failed_activate', duration_ms: elapsed(t0),
                  request_id, user_id: authResult.ctx.userClaims.id, case_id: caseId })
        return errorEnvelope('FK_INTERNAL', 'Internal error', 500)
        // presignedUrl discarded — not returned
      }

      // Step 8 — Success
      safeLog({ fn: 'upload-authorize', status: 200, outcome: 'activated',
                duration_ms: elapsed(t0), request_id,
                user_id: authResult.ctx.userClaims.id, case_id: caseId })
      return new Response(JSON.stringify({
        presigned_url: presignedUrl,
        upload_token:  rawToken,
        expires_at:    urlExpiresAt.toISOString(),
      }), {
        status: 200,
        headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' },
      })

    } catch {
      // Unanticipated throw from any adapter.
      // Compensate only if a session was reserved AND compensation has not already been attempted.
      if (admin && sessionId && !compensationAttempted) {
        compensationAttempted = true
        await bestEffortFail(deps, admin, sessionId, request_id, t0)
      }
      safeLog({ fn: 'upload-authorize', status: 500, error_code: 'FK_INTERNAL',
                outcome: 'unexpected_throw', duration_ms: elapsed(t0), request_id })
      return errorEnvelope('FK_INTERNAL', 'Internal error', 500)
    }

  }
}
```

---

## Section 6 — Test Matrix

### 6.1 Unit Test Command

```sh
deno test --allow-net --allow-env --allow-read \
  supabase/functions/upload-authorize/upload-authorize.test.ts
```

Scaffold quality checks run over all files in `_shared/` and `upload-authorize/`.

### 6.2 Integration Runner (`tools/integration-runner.sh`)

```sh
#!/usr/bin/env bash
set -uo pipefail

LOG="08_Migration/tests/integration-$(date +%Y%m%d-%H%M%S).log"
SERVE_PID=""
TEST_EXIT=1

# ── Helper: extract and strip quotes from supabase status env ────────────────
_env() { supabase status -o env 2>/dev/null | grep "^${1}=" | cut -d= -f2- | tr -d "\"'"; }

# ── Cleanup: always runs on EXIT, INT, TERM ──────────────────────────────────
cleanup() {
  [[ -n "$SERVE_PID" ]] && kill "$SERVE_PID" 2>/dev/null || true
  # Fixture teardown — uses DB_URL captured before unset
  [[ -n "${DB_URL:-}" ]] && \
    psql "$DB_URL" -q -c "SELECT cleanup_integration_fixtures();" 2>/dev/null || true
  unset SUPABASE_URL SUPABASE_PUBLISHABLE_KEY SUPABASE_SECRET_KEY \
        SUPABASE_JWT_SECRET DB_URL \
        S3_ACCESS_KEY_ID S3_SECRET_ACCESS_KEY 2>/dev/null || true
  echo "=== RESULT: $([ "$TEST_EXIT" -eq 0 ] && echo PASS || echo FAIL) ===" \
    | tee -a "$LOG"
}
trap cleanup EXIT INT TERM

exec > >(tee -a "$LOG") 2>&1
echo "=== upload-authorize integration suite ==="
echo "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ── 1. Preflight ──────────────────────────────────────────────────────────────
supabase status --output env > /dev/null 2>&1 || { echo "FAIL: supabase not running"; exit 1; }

# ── 2. Credentials (exported to child env; never passed as CLI args) ─────────
SUPABASE_URL=$(_env API_URL)
SUPABASE_PUBLISHABLE_KEY=$(_env ANON_KEY)         # local singular fallback
SUPABASE_SECRET_KEY=$(_env SERVICE_ROLE_KEY)       # local singular fallback
SUPABASE_JWT_SECRET=$(_env JWT_SECRET)
DB_URL=$(_env DB_URL)
S3_ACCESS_KEY_ID=$(_env S3_PROTOCOL_ACCESS_KEY_ID)
S3_SECRET_ACCESS_KEY=$(_env S3_PROTOCOL_ACCESS_KEY_SECRET)
FUNCTION_URL="${SUPABASE_URL}/functions/v1/upload-authorize"

for var in SUPABASE_URL SUPABASE_PUBLISHABLE_KEY SUPABASE_SECRET_KEY \
           SUPABASE_JWT_SECRET DB_URL S3_ACCESS_KEY_ID S3_SECRET_ACCESS_KEY; do
  [[ -z "${!var}" ]] && { echo "FAIL: could not read ${var}"; exit 1; }
done

# Generate .env.local from live status (git-ignored; never committed)
cat > supabase/functions/.env.local << ENVEOF
SUPABASE_URL=${SUPABASE_URL}
SUPABASE_PUBLISHABLE_KEY=${SUPABASE_PUBLISHABLE_KEY}
SUPABASE_SECRET_KEY=${SUPABASE_SECRET_KEY}
S3_ENDPOINT=$(_env STORAGE_S3_URL)
S3_REGION=local
S3_ACCESS_KEY_ID=${S3_ACCESS_KEY_ID}
S3_SECRET_ACCESS_KEY=${S3_SECRET_ACCESS_KEY}
S3_BUCKET=game-media
ENVEOF

# ── 3. Fixtures ───────────────────────────────────────────────────────────────
psql "$DB_URL" -q -f tools/integration-fixtures.sql

# ── 4. Serve function (no extra JWT flags — config.toml controls verify_jwt) ─
supabase functions serve upload-authorize \
  --env-file supabase/functions/.env.local &
SERVE_PID=$!

# ── 5. Readiness poll (bounded, 30 attempts × 1 s) ───────────────────────────
READY=false
for _ in $(seq 1 30); do
  http_code=$(curl -s -o /dev/null -w "%{http_code}" "$FUNCTION_URL" 2>/dev/null)
  if [[ "$http_code" == "401" || "$http_code" == "400" || "$http_code" == "405" ]]; then
    READY=true; break
  fi
  sleep 1
done
$READY || { echo "FAIL: function not ready after 30 s"; exit 1; }

# ── 6. Run tests (secrets via env, not CLI args) ─────────────────────────────
env \
  SUPABASE_URL="$SUPABASE_URL" \
  SUPABASE_PUBLISHABLE_KEY="$SUPABASE_PUBLISHABLE_KEY" \
  SUPABASE_SECRET_KEY="$SUPABASE_SECRET_KEY" \
  SUPABASE_JWT_SECRET="$SUPABASE_JWT_SECRET" \
  DB_URL="$DB_URL" \
  FUNCTION_URL="$FUNCTION_URL" \
  deno test \
    --allow-net --allow-env --allow-read --allow-run \
    supabase/functions/upload-authorize/upload-authorize.integration.test.ts
TEST_EXIT=$?
```

### 6.3 Private Session Check Script (`tools/private_session_check.sh`)

Returns boolean hash comparison and permitted state fields. The actual `upload_token_hash` value is never printed.

```sh
#!/usr/bin/env bash
set -euo pipefail
# Usage: ./tools/private_session_check.sh <session_uuid> <expected_hash>
SESSION_ID="${1:?Usage: $0 <session_uuid> <expected_hash>}"
EXPECTED_HASH="${2:?Usage: $0 <session_uuid> <expected_hash>}"

DB_URL=$(supabase status -o env 2>/dev/null | grep '^DB_URL=' | cut -d= -f2- | tr -d "\"'")
[[ -z "$DB_URL" ]] && { echo "ERROR: DB_URL not found" >&2; exit 1; }

# psql named variables — no shell interpolation into SQL
psql "$DB_URL" --no-password -t -A \
  -v "sid=${SESSION_ID}" \
  -v "expected_hash=${EXPECTED_HASH}" \
  -c "SELECT
        (upload_token_hash = :'expected_hash') AS hash_match,
        status,
        storage_upload_expires_at,
        failed_reason
      FROM private.upload_sessions
      WHERE session_id = :'sid';"
```

### 6.4 Integration Reserve Adapter

```typescript
// Wraps defaultDeps.reserveSession; captures session_id for psql assertions.
let capturedSessionId: string | null = null
const realReserveWithCapture: Deps['reserveSession'] = async (admin, params) => {
  const result = await defaultDeps.reserveSession(admin, params)
  if (result.data?.session_id) capturedSessionId = result.data.session_id
  return result
}
```

### 6.5 `parseAmzExpiry` Unit Tests (T-A-P-*)

| # | Input | Expected |
|---|---|---|
| T-A-P-01 | `?X-Amz-Date=20260813T120000Z&X-Amz-Expires=300` | `Date(2026-08-13T12:05:00Z)` |
| T-A-P-02 | Missing `X-Amz-Date` | Throws |
| T-A-P-03 | Missing `X-Amz-Expires` | Throws |
| T-A-P-04 | `X-Amz-Date=20260813T1200` (missing seconds/Z) | Throws |
| T-A-P-05 | `X-Amz-Date=XXXXXXXXTXXXXXXZ` (non-numeric) | Throws |
| T-A-P-06 | `X-Amz-Expires=600` | Throws (fail-closed; any value ≠ 300) |
| T-A-P-07 | `X-Amz-Expires=0` | Throws |
| T-A-P-08 | `X-Amz-Expires=299` | Throws |
| T-A-P-09 | Valid URL: returned `Date.getTime()` equals `parseAmzDate(X-Amz-Date).getTime() + 300_000` | Pass |
| T-A-P-10 | `X-Amz-Date=20261399T120000Z` (month 13 — calendar-invalid) | Throws (`Number.isNaN(result.getTime())` guard) |

### 6.6 Happy Path

| # | Description | Type | Expected |
|---|---|---|---|
| T-A-01 | Valid JPEG, draft case, active profile | Unit | 200; `presigned_url`, `upload_token`, `expires_at`; `session_id` absent; `Cache-Control: no-store` |
| T-A-02 | Valid WebP, same conditions | Unit | 200 |
| T-A-03 | `expires_at` = `parseAmzDate(X-Amz-Date) + 300s`; not a local clock estimate | Unit | Pass |
| T-A-04 | SHA-256(response `upload_token`) → `hash_match=true` (psql script with captured UUID) | Integration | Pass |
| T-A-05 | `session_id` absent from 200 body | Unit | Pass |
| T-A-06 | After 200: DB `status='pending'`, `storage_upload_expires_at=expires_at` | Integration | Pass |
| T-A-07 | `X-Amz-Expires=300` (integer duration); `parseAmzDate(X-Amz-Date) + 300s = response.expires_at = DB value` | Unit | Pass |

### 6.7 Method Enforcement

| # | Description | Type | Expected |
|---|---|---|---|
| T-A-08 | `GET /upload-authorize` | Unit | 405; `Allow: POST`; `Cache-Control: no-store` |
| T-A-09 | `PUT /upload-authorize` | Unit | 405 |
| T-A-10 | `DELETE /upload-authorize` | Unit | 405 |

### 6.8 Authentication and Profile

| # | Description | Type | Expected |
|---|---|---|---|
| T-A-11 | Missing `Authorization` header (live function) | Integration | 401; gateway or `FK_UNAUTHENTICATED` |
| T-A-12 | Malformed JWT (live function) | Integration | 401 |
| T-A-13 | Expired JWT (live function) | Integration | 401 |
| T-A-14 | `is_active = false` stub | Unit | 403 `FK_FORBIDDEN` |
| T-A-15 | Deletion-prepared profile (`is_active=false` via `prepare_account_deletion_wrapper`) | Integration | 403 `FK_FORBIDDEN` |
| T-A-16 | `onboarding_complete = false` stub | Unit | 403 `FK_FORBIDDEN` |
| T-A-17 | `is_suspended = true` stub | Unit | 403 `FK_FORBIDDEN` |
| T-A-18 | Profile row absent stub | Unit | 403 `FK_FORBIDDEN` |
| T-A-19 | Profile check `'error'` stub (transport failure) | Unit | 500 `FK_INTERNAL` |

### 6.9 Request Validation (T-A-20 to T-A-30) — unchanged from Rev 5 §6.10

### 6.10 DB-Driven Errors (T-A-31 to T-A-40) — unchanged from Rev 5 §6.11; T-A-36 confirms `sanitized` → 409

### 6.11 Presign, Activate, and Unexpected Failures

| # | Description | Type | Expected |
|---|---|---|---|
| T-A-41 | `presign` stub throws | Unit | 500; `compensationAttempted=true`; `bestEffortFail` called **exactly once** (`failSession` called exactly once total); URL absent |
| T-A-42 | `activateSession` returns `{ error }` | Unit | 500; `compensationAttempted=true`; **exactly one** `failSession` call; URL absent |
| T-A-43 | `reserveSession` stub throws (unexpected) | Unit | Top-level catch; 500; `sessionId=null` so `bestEffortFail` NOT called; `compensationAttempted=false` |
| T-A-44 | `activateSession` stub throws (unexpected) | Unit | Top-level catch; `compensationAttempted=false` so `bestEffortFail` called exactly once |
| T-A-45 | `failSession` returns `{ error }` after presign failure | Unit | 500; fail-session error logged; `failSession` called **exactly once** total (outer catch sees `compensationAttempted=true`, does not call again) |
| T-A-46 | `failSession` throws after presign failure | Unit | 500; `bestEffortFail` catches throw; **exactly one** `failSession` call; no rethrow; outer catch sees `compensationAttempted=true` |
| T-A-47 | Presign failure; DB verification | Integration | `status='failed'`, `failed_reason='FK_INTERNAL'` (psql); URL absent |
| T-A-48 | Activate failure; DB verification | Integration | `status='failed'` (psql); URL absent |

### 6.12 Race B — Concurrent Duplicate Reservations

Both calls use the same authorized poster (`user_id`) and same `case_id`, with distinct tokens (`token-a` and `token-b` via stubs). A countdown-latch barrier ensures both reserve calls reach the RPC critical section concurrently before either insert proceeds.

**Latch pattern:**

```typescript
// Countdown latch: holds all callers until n have arrived, then releases all together.
function makeLatch(n: number): { wait(): Promise<void> } {
  let arrived = 0
  let release!: () => void
  const gate = new Promise<void>(resolve => { release = resolve })
  return {
    wait() {
      if (++arrived >= n) release()
      return gate
    },
  }
}

// Latch-wrapped reserve adapter (injected into both handler instances)
const latch = makeLatch(2)
const latchedReserve: Deps['reserveSession'] = async (admin, params) => {
  await latch.wait()                          // hold until both are here
  return defaultDeps.reserveSession(admin, params)
}

// Distinct-token handler instances — same poster, same case, different tokens
const handlerA = makeHandler({
  ...defaultDeps,
  generateToken:  () => tokenA,   // base64url string, sha256 pre-computed as hashA
  sha256:         fixedSha256Map,
  reserveSession: latchedReserve,
  activateSession: defaultDeps.activateSession,
  presign: defaultDeps.presign,
})
const handlerB = makeHandler({
  ...defaultDeps,
  generateToken:  () => tokenB,   // different base64url string, hashB
  sha256:         fixedSha256Map,
  reserveSession: latchedReserve,
  activateSession: defaultDeps.activateSession,
  presign: defaultDeps.presign,
})
```

**Assertion sequence:**

```typescript
const [resA, resB] = await Promise.all([
  handlerA(makePostRequest(posterJwt, caseId, 'image/jpeg', 1024)),
  handlerB(makePostRequest(posterJwt, caseId, 'image/jpeg', 1024)),
])
const statuses = [resA.status, resB.status].sort()
assertEquals(statuses, [200, 409])           // exactly one 200, one 409

// Verify 409 body
const loser = resA.status === 409 ? resA : resB
const loserBody = await loser.json()
assertEquals(loserBody.error.code, 'FK_UPLOAD_IN_PROGRESS')

// Verify exactly one active session in DB
const rows = await psqlQuery(
  `SELECT upload_token_hash, status FROM private.upload_sessions
   WHERE case_id = $1 AND status IN ('pending','processing','sanitized')`,
  [caseId],
)
assertEquals(rows.length, 1)                 // exactly one active session

// Verify the winning hash is one of the two that were attempted (not some other token)
const winnerHash = rows[0].upload_token_hash
assert(winnerHash === hashA || winnerHash === hashB)

// Verify two distinct token hashes were attempted (proven by knowing both were submitted)
assertNotEquals(hashA, hashB)
```

### 6.13 Race A — Formal Deferral (Amendment C)

The full three-outcome Race A orchestration requires `prepare_account_deletion_wrapper`, `quiesce_upload_sessions_for_deletion`, `get_upload_capability_expiry`, and a 5-minute URL expiry window — none of which are implemented in this step.

**Amendment C — Formally deferred:** Race A's full harness is deferred to the step implementing `account-delete-complete`. Bill's approval phrase must include "Amendment C acknowledged."

**Race A coverage within Step A scope:**
- Outcome 1 (deletion wins before reserve): T-A-15 (integration).
- Compensation path: T-A-47/T-A-48 (integration).
- Outcomes 2 and 3 full orchestration: deferred.

---

## Section 7 — Environment Variables

**Amendment B:** Step 27's `stub`/`ANON_KEY` → Gate 4 evidence.

| Variable | Hosted | Local fallback |
|---|---|---|
| `SUPABASE_URL` | Auto-provisioned | Auto-provisioned |
| `SUPABASE_PUBLISHABLE_KEYS` | Auto-provisioned (plural) | `SUPABASE_PUBLISHABLE_KEY` (singular) |
| `SUPABASE_SECRET_KEYS` | Auto-provisioned (plural) | `SUPABASE_SECRET_KEY` (singular) |
| `SUPABASE_JWKS` | Auto-provisioned | Not present locally |
| `S3_ENDPOINT` | `.storage.` hostname | `$(_env STORAGE_S3_URL)` |
| `S3_REGION` | Dashboard | `local` |
| `S3_ACCESS_KEY_ID` | Dashboard-generated | `$(_env S3_PROTOCOL_ACCESS_KEY_ID)` |
| `S3_SECRET_ACCESS_KEY` | Dashboard secret | `$(_env S3_PROTOCOL_ACCESS_KEY_SECRET)` |
| `S3_BUCKET` | `game-media` | `game-media` |

`.env.local` is generated at runner time from `supabase status -o env`. `.env.example` documents key names without values (committed). Secrets passed to child process via `env` (not CLI args); unset during cleanup.

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

```sh
deno cache --lock=deno.lock \
  supabase/functions/_shared/{context,profile,s3,errors,log,crypto}.ts \
  supabase/functions/upload-authorize/index.ts \
  supabase/functions/upload-authorize/upload-authorize.test.ts
```

`deno.lock` is committed and is the authoritative source for all resolved versions. If `deno cache` resolves any direct dependency to a version different from Section 9, the Section 9 entry is updated to match the lock file before implementation proceeds.

### `config.toml`

```toml
[functions.upload-authorize]
verify_jwt = true
```

---

## Section 9 — Dependency Versions

All four versions confirmed to exist on npm registry via HTTP 200 (2026-08-13):

| Import specifier | Pinned version | npm publish date | Purpose |
|---|---|---|---|
| `npm:@supabase/server@1.4.1` | **1.4.1** | 2026-07-22 | JWT verification |
| `npm:@supabase/supabase-js@2.112.3` | **2.112.3** | 2026-08-11 | Supabase client |
| `npm:@aws-sdk/client-s3@3.1109.0` | **3.1109.0** | 2026-08-12 | S3 client |
| `npm:@aws-sdk/s3-request-presigner@3.1109.0` | **3.1109.0** | 2026-08-12 | Presigned URL generation |

These versions postdate the prior Codex review (which found `@supabase/supabase-js@2.110.8` and AWS at `3.1098.0`), explaining the earlier mismatch. `deno cache` generating `deno.lock` at Gate 6 is the final confirmation. If resolution fails for any pin, the version is corrected to the nearest available before implementation begins.

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
| Claude | Approved | Rev 6; all 5 Rev 5 blockers resolved; Amendment C acknowledged |
| Codex | Pending | `APPROVED: Step A Rev 6 — upload-authorize` |
| Bill | Pending | `APPROVED: Step A Rev 6 — upload-authorize — Amendment C acknowledged` |

**This approval authorizes TypeScript implementation only. No cloud deployment authorized.**
