# Step A Proposal — Rev 5 — `upload-authorize` Edge Function

**Status:** DRAFT — Awaiting three-party approval (Claude + Codex + Bill)

**Supersedes:** Rev 4 (CHANGES REQUIRED — 5 blockers from Codex review)

**Governance gate:** All three parties must approve before any TypeScript is written.
Magic words: `APPROVED: Step A Rev 5 — upload-authorize`

**Binding contracts:**
- Step 27 Rev 5 (approved 2026-08-12) — §5.1, §6, §7, §8
- Step 24 Rev 10 (approved 2026-08-07) — §5.1 test matrix
  - **Amendment A** — Session claim window: Step 24 §4.1 5-minute window superseded by 15 minutes. See §5.3.
  - **Amendment B** — Local S3 credentials: Step 27's `access_key_id=stub`/`secret=ANON_KEY` superseded by Gate 4 evidence. See §7.
  - **Amendment C** — Race A orchestration deferral. See §6.9.
- V2 migration SHA-256: `0f9adbb732f671008629854398fb7d5c3962a315338e3eff08b3a45eccea161a`
- V4 migration SHA-256: `0eb78c66878df50f22278fb36f2b089d3f2b81ded2f550a945e9d0dd55dd0f66`
  - V4 applied: `public.challenges → public.cases`; `p_challenge_id → p_case_id`

---

## Section 1 — Scope

This step covers:
1. Scaffolding of `supabase/functions/_shared/` (shared module — first use)
2. Scaffolding and implementation of `supabase/functions/upload-authorize/index.ts`
3. Test file: `supabase/functions/upload-authorize/upload-authorize.test.ts`
4. Integration runner: `tools/integration-runner.sh` and supporting scripts
5. `deno.lock` generation (Gate 6 — first function)
6. `deno check`, `deno fmt --check`, `deno lint`, `gitleaks detect` all passing

This step does **not** cover:
- Any cloud deployment
- `upload-complete` or any other function
- `cron.ts` — deferred
- Gate 2B — separate three-party approval required
- Race A full three-outcome orchestration harness — deferred (Amendment C)

**Security constraints (immutable):**
- Secret key never in client code, never in the repo, never sent to Claude
- No cloud operations authorized under this step
- `private` schema never exposed through PostgREST
- `SUPABASE_DB_URL` direct connection NOT used by Edge Functions
- Raw JWT decoding prohibited; use `createSupabaseContext(req, { auth: 'user' })` from `npm:@supabase/server`
- `createSignedUploadUrl()` prohibited; only S3 Signature V4 with `ExpiresIn: 300`

---

## Section 2 — Pre-conditions

| Pre-condition | Status |
|---|---|
| Gate 5 (Deno + gitleaks) | ✅ Passed — Deno 2.9.5, gitleaks 8.30.1 |
| Gate 4 (local S3 preflight) | ✅ Passed — 2026-08-13 |
| Gate 3 (pg_cron/pg_net local) | ✅ Passed — 2026-08-13 |
| Gate 1 (V2 migration applied) | ✅ Satisfied — V2/V4 applied and regression-tested |
| Dependency versions pinned | ✅ All four pinned — see Section 9 |
| Three-party approval of this proposal | ⏳ Pending |

---

## Section 3 — Directory Structure

```
supabase/functions/
  _shared/
    context.ts          ← getAuthContext
    profile.ts          ← checkActiveProfile, checkProfileExists
    s3.ts               ← presignPutUrl, parseAmzExpiry
    errors.ts           ← errorEnvelope, FkErrorCode, extractDbErrorCode
    log.ts              ← safeLog
    crypto.ts           ← sha256Hex, generateUploadToken
  upload-authorize/
    index.ts            ← makeHandler, bestEffortFail, defaultDeps, handler
    upload-authorize.test.ts
tools/
  integration-runner.sh       ← deterministic local integration runner
  private_session_check.sh    ← boolean hash check + permitted DB state fields
deno.lock
```

---

## Section 4 — Shared Module Specification

### 4.1 `errors.ts`

```typescript
export type FkErrorCode =
  | 'FK_UNAUTHENTICATED'   | 'FK_FORBIDDEN'         | 'FK_NOT_FOUND'
  | 'FK_WRONG_STATE'       | 'FK_UPLOAD_IN_PROGRESS' | 'FK_FILE_TOO_LARGE'
  | 'FK_INVALID_CONTENT_TYPE' | 'FK_INVALID_INPUT'  | 'FK_INVALID_TOKEN'
  | 'FK_INTERNAL'          | 'FK_PROCESSING_FAILED'

// Returns Response with JSON { error: { code, message } } and Cache-Control: no-store.
export function errorEnvelope(code: FkErrorCode, message: string, status: number): Response

// Anchored allowlist check on err.message for FK_* prefixes.
// Returns null if no prefix matches. Raw DB messages never reach logs or responses.
export function extractDbErrorCode(err: unknown): FkErrorCode | null
```

### 4.2 `crypto.ts`

```typescript
// 32 random bytes via crypto.getRandomValues → base64url (43 chars, ~256 bits).
export function generateUploadToken(): string

// SHA-256 → lowercase 64-char hex.
export async function sha256Hex(data: Uint8Array): Promise<string>
```

### 4.3 `log.ts`

```typescript
// Required: fn (string), status (real HTTP status — never 0), duration_ms (number).
// Conditional: error_code, request_id, user_id (post-auth), case_id (post-validation), outcome.
// NEVER logged: paths, tokens, presigned URLs, secrets, keys, JWTs, raw DB messages,
//               content_type, declared_size_bytes, upload_token_hash values.
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
// Hosted: SUPABASE_PUBLISHABLE_KEYS / SUPABASE_SECRET_KEYS / SUPABASE_JWKS (plural, auto-provisioned).
// Local: SUPABASE_PUBLISHABLE_KEY / SUPABASE_SECRET_KEY (singular fallbacks).
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

`public.profiles` columns: `is_active` (V1), `onboarding_complete` (V1), `is_suspended` (V3).
No `auth_deleted_at` exists on `public.profiles`. Deletion-prepared accounts have `is_active = false`.

```typescript
export type ProfileCheckResult =
  | { status: 'ok' }
  | { status: 'forbidden'; reason: 'absent' | 'inactive' | 'incomplete' | 'suspended' }
  | { status: 'error' }

export async function checkActiveProfile(
  supabase: SupabaseClient, userId: string,
): Promise<ProfileCheckResult>

// { ok: true, error: false }  — row exists
// { ok: false, error: false } — row absent
// { ok: false, error: true }  — query failure
export async function checkProfileExists(
  supabase: SupabaseClient, userId: string,
): Promise<{ ok: boolean; error: boolean }>
```

### 4.6 `s3.ts`

Two exported functions: `parseAmzExpiry` (pure, testable) and `presignPutUrl` (uses it).

```typescript
// Pure fail-closed parser. Extracts X-Amz-Date and X-Amz-Expires from a signed URL.
// Throws with a descriptive message if either parameter is:
//   - absent from the URL
//   - malformed (X-Amz-Date not matching /^\d{8}T\d{6}Z$/)
//   - X-Amz-Expires !== 300 (fail-closed: rejects any non-300 expiry)
// Returns the reconstructed expiry: parseAmzDate(X-Amz-Date) + X-Amz-Expires seconds.
export function parseAmzExpiry(signedUrl: string): Date

// Signs a presigned PUT URL. Calls parseAmzExpiry on the result to derive expiresAt.
// expiresIn MUST be 300 (literal type). forcePathStyle: true.
// Throws on signing failure or on parseAmzExpiry failure (caller compensates).
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

Non-`POST` → `405 Method Not Allowed` with `Allow: POST` and `Cache-Control: no-store`.
All responses include `Cache-Control: no-store`. `session_id` never present.

### 5.2 `config.toml`

```toml
[functions.upload-authorize]
verify_jwt = true
```

### 5.3 Session Timing (Amendment A)

| Window | Value | Source |
|---|---|---|
| `p_client_expires_at` | `now() + 900s` | Handler clock |
| `ExpiresIn` | `300` (literal) | S3 parameter |
| `expiresAt` (from `presignPutUrl`) | `parseAmzExpiry(signedUrl)` | Parsed from signed URL |
| `p_actual_storage_upload_expires_at` | `expiresAt.toISOString()` | Same `Date` object as response |
| Response `expires_at` | `expiresAt.toISOString()` | Same `Date` object — no clock estimate |

**Invariant:** `X-Amz-Expires = 300`. `parseAmzDate(X-Amz-Date) + 300s = expiresAt = response.expires_at = DB storage_upload_expires_at`. All four are the same instant.

### 5.4 Upload Token Pattern

1. `rawToken = deps.generateToken()` → base64url (256 bits)
2. `tokenHash = await deps.sha256(new TextEncoder().encode(rawToken))` → 64-char hex
3. `reserve_upload_session(... p_token_hash: tokenHash ...)` — hash stored; raw token never stored
4. Return `rawToken` as `upload_token`

### 5.5 Dependency Interface

All three default RPC adapters are `async` and `await` the RPC builder internally, returning fully resolved `Promise<{ data, error }>`. The `reserveSession` adapter applies `.single()` internally. The caller never calls `.single()` again.

```typescript
export interface ReserveParams {
  p_case_id: string; p_uploader_id: string; p_token_hash: string;
  p_content_type: string; p_declared_size: number; p_client_expires_at: string;
}
export interface ReserveResult {
  session_id: string; original_storage_path: string; display_storage_path: string;
}
export interface ActivateParams {
  p_session_id: string; p_actual_storage_upload_expires_at: string;
}
export type AuthResult =
  | { ok: true;  ctx: AuthContext; error: null }
  | { ok: false; ctx: null;       error: Response }

export interface Deps {
  generateToken:   () => string
  sha256:          (data: Uint8Array) => Promise<string>
  getAuth:         (req: Request) => Promise<AuthResult>
  checkProfile:    (supabase: SupabaseClient, userId: string) => Promise<ProfileCheckResult>
  // All three RPC adapters return fully resolved Promise (not PromiseLike builder).
  // .single() is applied inside reserveSession; callers never call it again.
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
  reserveSession:  async (admin, p) => {
    // .single() applied here; caller receives resolved { data, error }
    return await admin.rpc('reserve_upload_session', p).single()
  },
  activateSession: async (admin, p) => {
    return await admin.rpc('activate_upload_session', p)
  },
  failSession:     async (admin, id, code) => {
    return await admin.rpc('fail_upload_session', { p_session_id: id, p_error_code: code })
  },
  presign:         presignPutUrl,
  now:             () => new Date(),
}

export function makeHandler(deps: Deps = defaultDeps): (req: Request) => Promise<Response>
```

### 5.6 `bestEffortFail` Helper

Called exactly once per failure path. Never throws. Inspects `{ error }` and catches any exception from `deps.failSession`. Logs `fail_session_error` on either condition.

```typescript
async function bestEffortFail(
  deps:       Deps,
  admin:      SupabaseClient,
  sessionId:  string,
  request_id: string,
  t0:         number,
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

### 5.7 Implementation Sequence

`admin` is declared outside `try` so the `catch` block can reference it for compensation.

```typescript
export function makeHandler(deps: Deps = defaultDeps) {
  return async (req: Request): Promise<Response> => {
    // Step 0 — Method enforcement (outside try)
    if (req.method !== 'POST') {
      return new Response('Method Not Allowed', {
        status: 405,
        headers: { 'Allow': 'POST', 'Cache-Control': 'no-store' },
      })
    }

    const request_id = req.headers.get('X-Request-Id') ?? crypto.randomUUID()
    const t0 = performance.now()
    let admin: SupabaseClient | null = null   // assigned after auth; used in catch
    let sessionId: string | null = null       // assigned after reserve; used in compensation

    try {
      // Step 1 — Auth
      const authResult = await deps.getAuth(req)
      if (!authResult.ok) {
        safeLog({ fn: 'upload-authorize', status: 401, duration_ms: elapsed(t0),
                  error_code: 'FK_UNAUTHENTICATED', request_id })
        return authResult.error
      }
      const { ctx } = authResult
      admin = ctx.supabaseAdmin      // assigned for use in catch

      // Step 2 — Profile
      const profileResult = await deps.checkProfile(ctx.supabase, ctx.userClaims.id)
      if (profileResult.status === 'forbidden') {
        safeLog({ fn: 'upload-authorize', status: 403, duration_ms: elapsed(t0),
                  error_code: 'FK_FORBIDDEN', request_id, user_id: ctx.userClaims.id })
        return errorEnvelope('FK_FORBIDDEN', 'Profile not eligible', 403)
      }
      if (profileResult.status === 'error') {
        safeLog({ fn: 'upload-authorize', status: 500, duration_ms: elapsed(t0),
                  error_code: 'FK_INTERNAL', request_id, user_id: ctx.userClaims.id })
        return errorEnvelope('FK_INTERNAL', 'Internal error', 500)
      }

      // Step 3 — Body validation
      let body: unknown
      try { body = await req.json() } catch {
        safeLog({ fn: 'upload-authorize', status: 400, duration_ms: elapsed(t0),
                  error_code: 'FK_INVALID_INPUT', request_id, user_id: ctx.userClaims.id })
        return errorEnvelope('FK_INVALID_INPUT', 'Invalid JSON', 400)
      }
      const { caseId, contentType, declaredSizeBytes, validationError } = validateBody(body)
      if (validationError) {
        safeLog({ fn: 'upload-authorize', status: validationError.status,
                  duration_ms: elapsed(t0), error_code: validationError.code,
                  request_id, user_id: ctx.userClaims.id })
        return errorEnvelope(validationError.code, validationError.message, validationError.status)
      }

      // Step 4 — Token generation
      const rawToken     = deps.generateToken()
      const tokenHash    = await deps.sha256(new TextEncoder().encode(rawToken))
      const sessionExpiry = new Date(deps.now().getTime() + 900_000)

      // Step 5 — Reserve
      const { data: row, error: reserveErr } = await deps.reserveSession(ctx.supabaseAdmin, {
        p_case_id:           caseId,
        p_uploader_id:       ctx.userClaims.id,
        p_token_hash:        tokenHash,
        p_content_type:      contentType,
        p_declared_size:     declaredSizeBytes,
        p_client_expires_at: sessionExpiry.toISOString(),
      })
      if (reserveErr) {
        const code = extractDbErrorCode(reserveErr) ?? 'FK_INTERNAL'
        const status = ({ FK_NOT_FOUND: 404, FK_WRONG_STATE: 409,
                          FK_UPLOAD_IN_PROGRESS: 409, FK_FORBIDDEN: 403 } as Record<string,number>)[code] ?? 500
        safeLog({ fn: 'upload-authorize', status, error_code: code,
                  duration_ms: elapsed(t0), request_id, user_id: ctx.userClaims.id, case_id: caseId })
        return errorEnvelope(code as FkErrorCode, 'Reservation failed', status)
      }
      if (!row) {
        safeLog({ fn: 'upload-authorize', status: 500, error_code: 'FK_INTERNAL',
                  duration_ms: elapsed(t0), request_id, user_id: ctx.userClaims.id, case_id: caseId })
        return errorEnvelope('FK_INTERNAL', 'Internal error', 500)
      }
      sessionId = row.session_id      // captured for compensation

      // Step 6 — Presign
      let presignedUrl: string, urlExpiresAt: Date
      try {
        ({ url: presignedUrl, expiresAt: urlExpiresAt } =
          await deps.presign(row.original_storage_path, 300))
      } catch {
        await bestEffortFail(deps, ctx.supabaseAdmin, sessionId, request_id, t0)
        safeLog({ fn: 'upload-authorize', status: 500, error_code: 'FK_INTERNAL',
                  outcome: 'failed_presign', duration_ms: elapsed(t0),
                  request_id, user_id: ctx.userClaims.id, case_id: caseId })
        return errorEnvelope('FK_INTERNAL', 'Internal error', 500)
      }

      // Step 7 — Activate
      const { error: activateErr } = await deps.activateSession(ctx.supabaseAdmin, {
        p_session_id:                      sessionId,
        p_actual_storage_upload_expires_at: urlExpiresAt.toISOString(),
      })
      if (activateErr) {
        await bestEffortFail(deps, ctx.supabaseAdmin, sessionId, request_id, t0)
        safeLog({ fn: 'upload-authorize', status: 500, error_code: 'FK_INTERNAL',
                  outcome: 'failed_activate', duration_ms: elapsed(t0),
                  request_id, user_id: ctx.userClaims.id, case_id: caseId })
        return errorEnvelope('FK_INTERNAL', 'Internal error', 500)
        // presignedUrl is discarded — never returned
      }

      // Step 8 — Success
      safeLog({ fn: 'upload-authorize', status: 200, outcome: 'activated',
                duration_ms: elapsed(t0), request_id, user_id: ctx.userClaims.id, case_id: caseId })
      return new Response(JSON.stringify({
        presigned_url: presignedUrl,
        upload_token:  rawToken,
        expires_at:    urlExpiresAt.toISOString(),
      }), {
        status: 200,
        headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' },
      })

    } catch {
      // Top-level catch: unanticipated throw from any adapter.
      // admin and sessionId assigned only after their respective steps — may be null.
      if (admin && sessionId) {
        await bestEffortFail(deps, admin, sessionId, request_id, t0)
      }
      safeLog({ fn: 'upload-authorize', status: 500, error_code: 'FK_INTERNAL',
                outcome: 'unexpected_throw', duration_ms: elapsed(t0), request_id })
      return errorEnvelope('FK_INTERNAL', 'Internal error', 500)
    }
  }
}
```

### 5.8 Error Response Table

| Condition | HTTP | Code |
|---|---|---|
| Non-POST method | 405 | — (`Allow: POST` header) |
| Missing or invalid JWT | 401 | `FK_UNAUTHENTICATED` |
| Profile absent / `is_active=false` / `onboarding_complete=false` / `is_suspended=true` | 403 | `FK_FORBIDDEN` |
| Profile check failure | 500 | `FK_INTERNAL` |
| Invalid JSON | 400 | `FK_INVALID_INPUT` |
| Invalid/missing `case_id` | 400 | `FK_INVALID_INPUT` |
| `content_type` not in allowlist | 400 | `FK_INVALID_CONTENT_TYPE` |
| `declared_size_bytes` missing or ≤ 0 | 400 | `FK_INVALID_INPUT` |
| `declared_size_bytes` > 10,485,760 | 400 | `FK_FILE_TOO_LARGE` |
| Case not found or caller not poster | 404 | `FK_NOT_FOUND` |
| Case not in draft state | 409 | `FK_WRONG_STATE` |
| Active session (pending/processing/sanitized) | 409 | `FK_UPLOAD_IN_PROGRESS` |
| Uploader has deletion record | 403 | `FK_FORBIDDEN` |
| Reserve returns null data | 500 | `FK_INTERNAL` |
| Presign failure | 500 | `FK_INTERNAL` |
| Activate failure | 500 | `FK_INTERNAL` |
| Unexpected throw (top-level catch) | 500 | `FK_INTERNAL` |

---

## Section 6 — Test Matrix

### 6.1 Unit Test Command

```sh
deno test --allow-net --allow-env --allow-read \
  supabase/functions/upload-authorize/upload-authorize.test.ts
```

Scaffold quality checks:
```sh
deno check supabase/functions/_shared/*.ts supabase/functions/upload-authorize/*.ts
deno fmt --check supabase/functions/
deno lint supabase/functions/
```

### 6.2 Integration Runner (`tools/integration-runner.sh`)

Deterministic, fail-fast, produces a timestamped evidence log.

```sh
#!/usr/bin/env bash
set -euo pipefail
LOG="08_Migration/tests/integration-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1

echo "=== upload-authorize integration suite ==="
echo "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"

# 1. Preflight — local Supabase must be running
supabase status --output env > /dev/null || { echo "FAIL: supabase not running"; exit 1; }

# 2. Read local credentials (strip surrounding quotes from DB_URL)
DB_URL=$(supabase status -o env | grep '^DB_URL=' | cut -d= -f2- | tr -d "\"'")
ANON_KEY=$(supabase status -o env | grep '^ANON_KEY=' | cut -d= -f2- | tr -d "\"'")
SERVICE_KEY=$(supabase status -o env | grep '^SERVICE_ROLE_KEY=' | cut -d= -f2- | tr -d "\"'")
FUNCTION_URL="http://127.0.0.1:54321/functions/v1/upload-authorize"
[[ -z "$DB_URL" || -z "$ANON_KEY" || -z "$SERVICE_KEY" ]] && {
  echo "FAIL: could not read required env from supabase status"; exit 1; }

# 3. Reset fixtures (idempotent)
PGPASSWORD="" psql "$DB_URL" -q -f tools/integration-fixtures.sql

# 4. Load function env
cp supabase/functions/.env.example supabase/functions/.env.local
# (Operator populates .env.example with local S3 values; .env.local is git-ignored)

# 5. Serve function in background
supabase functions serve upload-authorize \
  --env-file supabase/functions/.env.local \
  --no-verify-jwt=false &
SERVE_PID=$!
sleep 3  # wait for Edge Runtime to be ready

# 6. Run integration test file
deno test \
  --allow-net --allow-env --allow-read --allow-run \
  supabase/functions/upload-authorize/upload-authorize.integration.test.ts \
  -- --db-url="$DB_URL" --function-url="$FUNCTION_URL" \
     --anon-key="$ANON_KEY" --service-key="$SERVICE_KEY"
TEST_EXIT=$?

# 7. Teardown
kill $SERVE_PID 2>/dev/null || true
PGPASSWORD="" psql "$DB_URL" -q -c "SELECT cleanup_integration_fixtures();"

echo "=== RESULT: $([ $TEST_EXIT -eq 0 ] && echo PASS || echo FAIL) ==="
exit $TEST_EXIT
```

**`tools/integration-fixtures.sql`** — creates deterministic test users, profiles, and cases, callable multiple times without side effects (idempotent upsert pattern).

**Test users provisioned by fixture:**
- `user_active` — `is_active=true`, `onboarding_complete=true`, `is_suspended=false`
- `user_inactive` — `is_active=false`
- `user_suspended` — `is_suspended=true`
- `user_deletion_prepared` — `is_active=false` (set by calling `prepare_account_deletion_wrapper`)
- `user_no_profile` — auth user with no profile row

**JWTs** — generated from local `SUPABASE_JWT_SECRET` using a fixture helper; scoped to each test user. Gateway tests T-A-11–13 send requests to the live function URL with manipulated or absent auth headers.

### 6.3 Private Session Check Script (`tools/private_session_check.sh`)

Returns boolean hash comparison and permitted state fields only. Never prints the actual `upload_token_hash` value.

```sh
#!/usr/bin/env bash
set -euo pipefail
# Usage: ./tools/private_session_check.sh <session_uuid> <expected_hash>
SESSION_ID="${1:?Usage: $0 <session_uuid> <expected_hash>}"
EXPECTED_HASH="${2:?Usage: $0 <session_uuid> <expected_hash>}"

DB_URL=$(supabase status -o env 2>/dev/null | grep '^DB_URL=' | cut -d= -f2- | tr -d "\"'")
[[ -z "$DB_URL" ]] && { echo "ERROR: DB_URL not found" >&2; exit 1; }

# Uses psql named variables — no SQL interpolation of shell values
psql "$DB_URL" --no-password -t -A \
  -v "sid=${SESSION_ID}" \
  -v "expected_hash=${EXPECTED_HASH}" \
  -c "SELECT
        (upload_token_hash = :'expected_hash')   AS hash_match,
        status,
        storage_upload_expires_at,
        failed_reason
      FROM private.upload_sessions
      WHERE session_id = :'sid';"
```

The `upload_token_hash` column value is never printed — only the boolean comparison result `hash_match`.

### 6.4 Integration Reserve Adapter (Captures session_id)

```typescript
let capturedSessionId: string | null = null
const realReserveWithCapture: Deps['reserveSession'] = async (admin, params) => {
  const result = await admin.rpc('reserve_upload_session', params).single()
  if (result.data?.session_id) capturedSessionId = result.data.session_id
  return result
}
```

Integration tests pass this adapter via `makeHandler({ ...defaultDeps, reserveSession: realReserveWithCapture })`. After the handler returns, tests call `tools/private_session_check.sh $capturedSessionId $expectedHash` via `Deno.Command`.

### 6.5 Unit Stub Library

```typescript
const stubAuthOk = (userId: string): Deps['getAuth'] =>
  async () => ({ ok: true, ctx: fakeCtx(userId), error: null })
const stubAuthFail: Deps['getAuth'] =
  async () => ({ ok: false, ctx: null,
                 error: errorEnvelope('FK_UNAUTHENTICATED', 'unauth', 401) })
const stubProfileOk:        Deps['checkProfile'] = async () => ({ status: 'ok' })
const stubProfileForbidden: Deps['checkProfile'] = async () =>
  ({ status: 'forbidden', reason: 'inactive' })
const stubProfileSuspended: Deps['checkProfile'] = async () =>
  ({ status: 'forbidden', reason: 'suspended' })
const stubProfileError:     Deps['checkProfile'] = async () => ({ status: 'error' })
const stubReserveOk  = (r: ReserveResult): Deps['reserveSession'] => async () => ({ data: r, error: null })
const stubReserveNull: Deps['reserveSession'] = async () => ({ data: null, error: null })
const stubReserveFail = (c: FkErrorCode): Deps['reserveSession'] => async () =>
  ({ data: null, error: new Error(c) })
const stubReserveThrow: Deps['reserveSession'] = async () => { throw new Error('adapter threw') }
const stubActivateOk:    Deps['activateSession'] = async () => ({ data: null, error: null })
const stubActivateFail:  Deps['activateSession'] = async () =>
  ({ data: null, error: new Error('FK_INTERNAL') })
const stubActivateThrow: Deps['activateSession'] = async () => { throw new Error('adapter threw') }
const stubFailOk:    Deps['failSession'] = async () => ({ data: null, error: null })
const stubFailErr:   Deps['failSession'] = async () =>
  ({ data: null, error: new Error('conn refused') })
const stubFailThrow: Deps['failSession'] = async () => { throw new Error('adapter threw') }
const stubPresignOk  = (at: Date): Deps['presign'] =>
  async () => ({ url: 'https://s3.test/presigned', expiresAt: at })
const stubPresignFail: Deps['presign'] = async () => { throw new Error('S3 refused') }
const stubClock = (t: Date): Deps['now'] => () => t
const stubToken = (t: string): Deps['generateToken'] => () => t
```

### 6.6 `parseAmzExpiry` Unit Tests (T-A-P-*)

These tests target `parseAmzExpiry` directly as a pure function, independent of the handler.

| # | Input URL | Expected |
|---|---|---|
| T-A-P-01 | Valid URL with `X-Amz-Date=20260813T120000Z&X-Amz-Expires=300` | Returns `Date(2026-08-13T12:05:00Z)` |
| T-A-P-02 | Missing `X-Amz-Date` parameter | Throws |
| T-A-P-03 | Missing `X-Amz-Expires` parameter | Throws |
| T-A-P-04 | `X-Amz-Date` malformed (`20260813T1200` — missing seconds/Z) | Throws |
| T-A-P-05 | `X-Amz-Date` non-numeric (`XXXXXXXXTXXXXXXZ`) | Throws |
| T-A-P-06 | `X-Amz-Expires=600` (not 300) | Throws (fail-closed) |
| T-A-P-07 | `X-Amz-Expires=0` | Throws |
| T-A-P-08 | `X-Amz-Expires=299` | Throws |
| T-A-P-09 | Valid URL: returned `Date` equals `parseAmzDate(X-Amz-Date) + 300s` (arithmetic check) | Pass |

### 6.7 Happy Path

| # | Description | Type | Expected |
|---|---|---|---|
| T-A-01 | Valid JPEG, draft case, active profile | Unit | 200; `presigned_url`, `upload_token`, `expires_at`; `Cache-Control: no-store` |
| T-A-02 | Valid WebP, same conditions | Unit | 200 |
| T-A-03 | `expires_at` = `parseAmzDate(X-Amz-Date) + 300s`; not a clock estimate; clock stub verifies | Unit | Pass |
| T-A-04 | SHA-256(response `upload_token`) == `hash_match=true` from psql script | Integration | Pass |
| T-A-05 | `session_id` absent from 200 body | Unit | Pass |
| T-A-06 | After 200: DB `status='pending'`, `storage_upload_expires_at = expires_at` | Integration | Pass (psql script) |
| T-A-07 | `X-Amz-Expires = 300` (integer, not timestamp); reconstructed expiry equals `response.expires_at` and DB value | Unit | Pass |

### 6.8 Method Enforcement

| # | Description | Type | Expected |
|---|---|---|---|
| T-A-08 | `GET /upload-authorize` | Unit | 405; `Allow: POST`; `Cache-Control: no-store` |
| T-A-09 | `PUT /upload-authorize` | Unit | 405 |
| T-A-10 | `DELETE /upload-authorize` | Unit | 405 |

### 6.9 Authentication and Profile

| # | Description | Type | Expected |
|---|---|---|---|
| T-A-11 | Missing `Authorization` header (live function) | Integration | HTTP 401; gateway or `FK_UNAUTHENTICATED` |
| T-A-12 | Malformed JWT (live function) | Integration | HTTP 401 |
| T-A-13 | Expired JWT (live function) | Integration | HTTP 401 |
| T-A-14 | `is_active = false` profile stub | Unit | 403 `FK_FORBIDDEN` |
| T-A-15 | Deletion-prepared profile (`is_active=false` via `prepare_account_deletion_wrapper`) | Integration | 403 `FK_FORBIDDEN` |
| T-A-16 | `onboarding_complete = false` stub | Unit | 403 `FK_FORBIDDEN` |
| T-A-17 | `is_suspended = true` stub | Unit | 403 `FK_FORBIDDEN` |
| T-A-18 | Profile row absent stub | Unit | 403 `FK_FORBIDDEN` |
| T-A-19 | Profile check `'error'` stub (transport failure) | Unit | 500 `FK_INTERNAL` |

### 6.10 Request Validation

| # | Description | Type | Expected |
|---|---|---|---|
| T-A-20–30 | (unchanged from Rev 4 §6.6) | Unit | As specified |

### 6.11 DB-Driven Errors

| # | Description | Type | Expected |
|---|---|---|---|
| T-A-31–40 | (unchanged from Rev 4 §6.7, with T-A-36 confirming `sanitized` → 409) | Unit/Integration | As specified |

### 6.12 Presign, Activate, and Unexpected Failures

| # | Description | Type | Expected |
|---|---|---|---|
| T-A-41 | `presign` stub throws | Unit | 500; `bestEffortFail` called **exactly once**; URL absent |
| T-A-42 | `activateSession` returns `{ error }` | Unit | 500; `bestEffortFail` called **exactly once**; URL absent |
| T-A-43 | `reserveSession` stub throws (unexpected) | Unit | Top-level catch; 500; `sessionId = null` so `bestEffortFail` NOT called |
| T-A-44 | `activateSession` stub throws (unexpected) | Unit | Top-level catch; 500; `bestEffortFail` called once with captured `sessionId` |
| T-A-45 | `failSession` returns `{ error }` after presign failure | Unit | 500; fail-session error logged; **exactly one** `failSession` call total |
| T-A-46 | `failSession` throws after presign failure | Unit | 500; fail-session throw caught by `bestEffortFail`; **exactly one** attempt; no rethrow |
| T-A-47 | Presign failure + DB verification | Integration | `status='failed'`, `failed_reason='FK_INTERNAL'` (psql script); URL absent |
| T-A-48 | Activate failure + DB verification | Integration | `status='failed'` (psql script); URL absent |

### 6.13 Race Tests (Step 24 Rev 10 §5.1, V4 Substitutions Applied)

**Race A — Authorization vs. Account Deletion (Amendment C):**

The full three-outcome Race A harness (Outcomes 1, 2, 3) requires the complete account-deletion orchestrator (`prepare_account_deletion_wrapper`, `quiesce_upload_sessions_for_deletion`, `get_upload_capability_expiry`, storage/auth deletion), which is not implemented in this step. The orchestration timing involves real S3 URL expiry (5 minutes), making an automated in-process test impractical at this stage.

**Amendment C — Formal deferral:** Race A's full three-outcome harness is hereby formally deferred to the step that implements `account-delete-complete` (or the account-deletion worker). This deferral is acknowledged by all three parties in the approval record below.

**Race A coverage within Step A scope:**
- Outcome 1 (deletion wins before reserve): covered by T-A-15 (integration) — deletion-prepared profile → 403.
- Compensation path (session reserved but later failed): covered by T-A-47/T-A-48 (integration) — verify `fail_upload_session` produces correct DB state.
- Outcome 2 and 3 full orchestration: deferred.

**Race B — Concurrent Duplicate Reservations:**

Two concurrent `POST /upload-authorize` requests for the same `case_id` and same `user_id`. Each generates an independent token from `crypto.getRandomValues` (different base64url values). The unique index `upload_sessions_one_active_per_challenge WHERE status IN ('pending', 'processing', 'sanitized')` enforces at most one active session per case — this is the mechanism under test, not token-hash uniqueness.

Synchronization barrier: both requests are fired concurrently using `Promise.all`. The case is in `draft` state with no prior active session. Both reservations race to insert.

Expected: exactly one returns 200; the other returns 409 `FK_UPLOAD_IN_PROGRESS`. The index, not any application-level check, enforces this. No other outcome is acceptable.

Implementation: local integration test using `realReserveWithCapture` for both requests, with distinct `user_id` stub overrides if needed for parallel execution in Deno.

---

## Section 7 — Environment Variables

**Amendment B to Step 27 §8:** Gate 4 evidence supersedes `stub`/`ANON_KEY`.

| Variable | Hosted | Local fallback |
|---|---|---|
| `SUPABASE_URL` | Auto-provisioned | Auto-provisioned |
| `SUPABASE_PUBLISHABLE_KEYS` | Auto-provisioned (plural) | `SUPABASE_PUBLISHABLE_KEY` (singular) |
| `SUPABASE_SECRET_KEYS` | Auto-provisioned (plural) | `SUPABASE_SECRET_KEY` (singular) |
| `SUPABASE_JWKS` | Auto-provisioned (hosted only) | Not present locally |
| `S3_ENDPOINT` | `.storage.` hostname | `http://127.0.0.1:54321/storage/v1/s3` |
| `S3_REGION` | Dashboard value | `local` |
| `S3_ACCESS_KEY_ID` | Dashboard-generated | `S3_PROTOCOL_ACCESS_KEY_ID` from `supabase status -o env` |
| `S3_SECRET_ACCESS_KEY` | Dashboard secret | `S3_PROTOCOL_ACCESS_KEY_SECRET` from `supabase status -o env` |
| `S3_BUCKET` | `game-media` | `game-media` |

Local values in `supabase/functions/.env.local` (git-ignored). `supabase/functions/.env.example` documents required keys without values (committed).

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

### `config.toml`

```toml
[functions.upload-authorize]
verify_jwt = true
```

---

## Section 9 — Dependency Versions (Pinned)

Confirmed from npm registry on 2026-08-13:

| Import specifier | Pinned version | Purpose |
|---|---|---|
| `npm:@supabase/server@1.4.1` | **1.4.1** | JWT verification |
| `npm:@supabase/supabase-js@2.112.3` | **2.112.3** | Supabase client |
| `npm:@aws-sdk/client-s3@3.1109.0` | **3.1109.0** | S3 client |
| `npm:@aws-sdk/s3-request-presigner@3.1109.0` | **3.1109.0** | Presigned URL generation |

---

## Section 10 — Amendments Summary

| Amendment | Supersedes | Content |
|---|---|---|
| A — Session claim window | Step 24 §4.1 | 5 min → 15 min; see §5.3 |
| B — Local S3 credentials | Step 27 §8 | `stub`/`ANON_KEY` → `S3_PROTOCOL_*` from `supabase status -o env`; Gate 4 evidence |
| C — Race A orchestration deferral | Step 24 §5.1 Race A | Full three-outcome harness deferred to `account-delete-complete` step; see §6.13 |

---

## Section 11 — Approval Record

| Party | Status | Notes |
|---|---|---|
| Claude | Approved | Rev 5; all 5 Rev 4 blockers resolved; Amendment C (Race A deferral) acknowledged |
| Codex | Pending | Must acknowledge Amendment C in approval |
| Bill | Pending | Must acknowledge Amendment C in approval |

**This approval authorizes TypeScript implementation only. No cloud deployment authorized.**
