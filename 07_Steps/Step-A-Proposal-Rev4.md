# Step A Proposal — Rev 4 — `upload-authorize` Edge Function

**Status:** DRAFT — Awaiting three-party approval (Claude + Codex + Bill)

**Supersedes:** Rev 3 (CHANGES REQUIRED — 7 blockers from Codex review)

**Governance gate:** All three parties must approve before any TypeScript is written.
Magic words: `APPROVED: Step A Rev 4 — upload-authorize`

**Binding contracts:**
- Step 27 Rev 5 (approved 2026-08-12) — §5.1, §6, §7, §8
- Step 24 Rev 10 (approved 2026-08-07) — §5.1 test matrix
  - **Amendment A** — Session claim window: Step 24 §4.1 5-minute window superseded by 15 minutes. See §5.3.
  - **Amendment B** — Local S3 credentials: Step 27's `access_key_id=stub`/`secret=ANON_KEY` superseded by Gate 4 evidence. See §7.
- V2 migration SHA-256: `0f9adbb732f671008629854398fb7d5c3962a315338e3eff08b3a45eccea161a`
- V4 migration SHA-256: `0eb78c66878df50f22278fb36f2b089d3f2b81ded2f550a945e9d0dd55dd0f66`
  - V4 applied: `public.challenges → public.cases`; `p_challenge_id → p_case_id`

---

## Section 1 — Scope

This step covers:
1. Scaffolding of `supabase/functions/_shared/` (shared module — first use)
2. Scaffolding and implementation of `supabase/functions/upload-authorize/index.ts`
3. Test file: `supabase/functions/upload-authorize/upload-authorize.test.ts`
4. `deno.lock` generation (Gate 6 — first function)
5. `deno check`, `deno fmt --check`, `deno lint`, `gitleaks detect` all passing across all scaffolded files

This step does **not** cover:
- Any cloud deployment
- `upload-complete` or any other function
- `cron.ts` — deferred; not scaffolded under this step
- Gate 2B — separate three-party approval required

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

Gate 2A is partially passed. `upload-authorize` is independent of image processing and may proceed.

---

## Section 3 — Directory Structure

```
supabase/functions/
  _shared/
    context.ts          ← getAuthContext
    profile.ts          ← checkActiveProfile, checkProfileExists
    s3.ts               ← presignPutUrl → { url, expiresAt }
    errors.ts           ← errorEnvelope, FkErrorCode, extractDbErrorCode
    log.ts              ← safeLog
    crypto.ts           ← sha256Hex, generateUploadToken
  upload-authorize/
    index.ts            ← function handler + makeHandler
    upload-authorize.test.ts
deno.lock               ← all versions pinned
```

`cron.ts` deferred — not scaffolded under this step.

---

## Section 4 — Shared Module Specification

All modules: zero side effects on import. No global state. All env vars read inside calls via `Deno.env.get()`.

### 4.1 `errors.ts`

```typescript
export type FkErrorCode =
  | 'FK_UNAUTHENTICATED'
  | 'FK_FORBIDDEN'
  | 'FK_NOT_FOUND'
  | 'FK_WRONG_STATE'
  | 'FK_UPLOAD_IN_PROGRESS'
  | 'FK_FILE_TOO_LARGE'
  | 'FK_INVALID_CONTENT_TYPE'
  | 'FK_INVALID_INPUT'
  | 'FK_INVALID_TOKEN'
  | 'FK_INTERNAL'
  | 'FK_PROCESSING_FAILED'

// Returns a Response with JSON { error: { code, message } } and Cache-Control: no-store.
export function errorEnvelope(code: FkErrorCode, message: string, status: number): Response

// Inspects err.message against an anchored allowlist of FK_* prefixes:
// FK_NOT_FOUND, FK_WRONG_STATE, FK_UPLOAD_IN_PROGRESS, FK_FORBIDDEN, FK_INTERNAL.
// Returns null if no prefix matches. Raw DB messages never reach logs or responses.
export function extractDbErrorCode(err: unknown): FkErrorCode | null
```

### 4.2 `crypto.ts`

```typescript
// 32 random bytes via crypto.getRandomValues → base64url (43 chars, ~256 bits).
export function generateUploadToken(): string

// SHA-256 of data → lowercase 64-char hex.
// Upload token: sha256Hex(new TextEncoder().encode(base64urlToken))
export async function sha256Hex(data: Uint8Array): Promise<string>
```

### 4.3 `log.ts`

Fields are logged progressively: `user_id` only after auth confirms, `case_id` only after body validates. `status: 0` is never used — final HTTP status codes only.

```typescript
// Required: fn, status (HTTP status — never 0), duration_ms.
// Conditional: error_code (FK_* only), request_id, user_id (UUID — post-auth only),
//              case_id (UUID — post-validation only), outcome (sanitized string).
// NEVER logged: paths, tokens, presigned URLs, secrets, keys, JWTs,
//               raw DB error messages, content_type, declared_size_bytes.
export function safeLog(fields: {
  fn: string
  status: number       // always a real HTTP status code
  duration_ms: number
  error_code?: FkErrorCode
  request_id?: string
  user_id?: string
  case_id?: string
  outcome?: string
}): void
```

### 4.4 `context.ts`

```typescript
import { createSupabaseContext } from 'npm:@supabase/server@1.4.1'

// Wraps createSupabaseContext(req, { auth: 'user' }).
// Hosted env: SUPABASE_PUBLISHABLE_KEYS (plural), SUPABASE_SECRET_KEYS (plural),
//             SUPABASE_JWKS (plural) — auto-provisioned.
// Local fallbacks: SUPABASE_PUBLISHABLE_KEY (singular), SUPABASE_SECRET_KEY (singular).
// Never throws. Never decodes JWT manually.
export async function getAuthContext(req: Request): Promise<
  | { ok: true;  ctx: AuthContext; error: null }
  | { ok: false; ctx: null;       error: Response }
>

export interface AuthContext {
  userClaims: { id: string }
  supabase:      SupabaseClient  // RLS-scoped
  supabaseAdmin: SupabaseClient  // service_role
}
```

### 4.5 `profile.ts`

`public.profiles` columns queried: `is_active`, `onboarding_complete`, `is_suspended` (added by V3 migration). No `auth_deleted_at` column exists on `public.profiles`; deletion state is reflected by `is_active = false` (set by `prepare_account_deletion_wrapper`).

```typescript
export type ProfileCheckResult =
  | { status: 'ok' }
  | { status: 'forbidden'; reason: 'absent' | 'inactive' | 'incomplete' | 'suspended' }
  | { status: 'error' }     // query or transport failure → caller returns 500

// Returns 'forbidden' on confirmed disqualifying state (absent, is_active=false,
// onboarding_complete=false, or is_suspended=true).
// Returns 'error' on any query or network failure — never a false 403.
export async function checkActiveProfile(
  supabase: SupabaseClient,
  userId: string,
): Promise<ProfileCheckResult>

// Returns { ok: boolean; error: boolean }:
//   ok=true, error=false  — row exists (any status)
//   ok=false, error=false — row absent
//   ok=false, error=true  — query failure
export async function checkProfileExists(
  supabase: SupabaseClient,
  userId: string,
): Promise<{ ok: boolean; error: boolean }>
```

### 4.6 `s3.ts`

```typescript
// Signs a presigned PUT URL. expiresAt is parsed from the signed URL's own
// X-Amz-Date (YYYYMMDDTHHmmssZ) and X-Amz-Expires (seconds) parameters —
// not from the local clock. expiresIn MUST be 300 (literal type). forcePathStyle: true.
// Throws on failure (caller catches and calls fail_upload_session).
export async function presignPutUrl(
  objectPath: string,
  expiresIn: 300,
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

**Method enforcement:** non-`POST` requests receive `405 Method Not Allowed` with `Allow: POST` and `Cache-Control: no-store` before any auth check.

**Headers on all responses (200 and errors):** `Cache-Control: no-store`

`session_id` is never present in any response.

### 5.2 `config.toml` entry

```toml
[functions.upload-authorize]
verify_jwt = true
```

T-A-08–10 (auth failure tests) accept HTTP 401 with either the gateway error body or the `FK_UNAUTHENTICATED` envelope, since `verify_jwt = true` may short-circuit the handler.

### 5.3 Session Timing (Amendment A to Step 24 §4.1)

| Window | Value | Source |
|---|---|---|
| `p_client_expires_at` | `now() + 900s` (15 min) | Handler clock at reservation |
| `ExpiresIn` | `300` (literal) | S3 parameter; never changed |
| `expiresAt` from `presignPutUrl` | Reconstructed from `X-Amz-Date + X-Amz-Expires` | Authoritative |
| `p_actual_storage_upload_expires_at` | `expiresAt.toISOString()` | Same object as response |
| Response `expires_at` | `expiresAt.toISOString()` | Same object — no clock estimate |

**Invariant:** response `expires_at`, DB `storage_upload_expires_at`, and the embedded URL expiry all encode the same instant.

**Reconstruction check (T-A-03/T-A-07 basis):** Given a signed URL's query parameters `X-Amz-Date=YYYYMMDDTHHmmssZ` and `X-Amz-Expires=300`, the embedded expiry is `parseAmzDate(X-Amz-Date) + 300 seconds`. This reconstructed instant must equal `response.expires_at` and DB `storage_upload_expires_at`. `X-Amz-Expires` is a duration integer (300), not a timestamp; it cannot itself equal `expires_at`.

### 5.4 Upload Token Pattern

1. `rawToken = deps.generateToken()` → base64url (256 bits)
2. `tokenHash = await deps.sha256(new TextEncoder().encode(rawToken))` → 64-char hex
3. `reserve_upload_session(... p_token_hash: tokenHash ...)` — hash stored; raw token never stored
4. Return `rawToken` as `upload_token`

### 5.5 RPC Error Handling

`supabase.rpc()` returns `{ data, error }` — it does not throw under normal conditions. Every RPC call inspects `error` before using `data`. Reserve uses `.single()` and validates `data` is non-null. Compensation calls (`fail_upload_session`) also inspect `{ error }` and log any failure, then continue (best-effort only).

```typescript
// Reserve pattern:
const { data: row, error: reserveErr } =
  await deps.reserveSession(ctx.supabaseAdmin, params).single()
if (reserveErr) { /* map via extractDbErrorCode */ }
if (!row) { /* unexpected empty → FK_INTERNAL */ }

// Compensation pattern:
const { error: failErr } = await deps.failSession(supabaseAdmin, sessionId, 'FK_INTERNAL')
if (failErr) { safeLog({ ..., outcome: 'fail_session_error' }) }  // swallow — best-effort
```

### 5.6 Dependency Injection

```typescript
export interface Deps {
  generateToken:   () => string
  sha256:          (data: Uint8Array) => Promise<string>
  getAuth:         (req: Request) => Promise<AuthResult>
  checkProfile:    (supabase: SupabaseClient, userId: string) => Promise<ProfileCheckResult>
  reserveSession:  (admin: SupabaseClient, params: ReserveParams) =>
                     PromiseLike<{ data: ReserveResult | null; error: unknown }>
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
  reserveSession:  (admin, p) => admin.rpc('reserve_upload_session', p).single(),
  activateSession: (admin, p) => admin.rpc('activate_upload_session', p),
  failSession:     (admin, id, code) =>
    admin.rpc('fail_upload_session', { p_session_id: id, p_error_code: code }),
  presign:         presignPutUrl,
  now:             () => new Date(),
}

// Handler factory — the exported default uses defaultDeps:
export function makeHandler(deps: Deps = defaultDeps): (req: Request) => Promise<Response>
```

### 5.7 Implementation Sequence

The outermost layer enforces method and wraps everything in a top-level `try/catch`. `session_id` is tracked in an outer-scope variable so compensation is always possible if a session was reserved.

```
Outer wrapper (not inside try — this is the exported handler):

  Step 0a. If req.method !== 'POST':
             return new Response('Method Not Allowed', {
               status: 405,
               headers: { 'Allow': 'POST', 'Cache-Control': 'no-store' },
             })

  Step 0b. request_id = req.headers.get('X-Request-Id') ?? crypto.randomUUID()
            t0 = performance.now()
            let sessionId: string | null = null   // for compensation

  try {

    Step 1.  { ok, ctx, error } = await deps.getAuth(req)
              if !ok:
                safeLog({ fn, status: 401, duration_ms: elapsed(t0),
                          error_code: 'FK_UNAUTHENTICATED', request_id })
                return error

    Step 2.  result = await deps.checkProfile(ctx.supabase, ctx.userClaims.id)
              if result.status === 'forbidden':
                safeLog({ fn, status: 403, error_code: 'FK_FORBIDDEN',
                          duration_ms: elapsed(t0), request_id, user_id: ctx.userClaims.id })
                return errorEnvelope('FK_FORBIDDEN', ..., 403)
              if result.status === 'error':
                safeLog({ fn, status: 500, error_code: 'FK_INTERNAL',
                          duration_ms: elapsed(t0), request_id, user_id: ctx.userClaims.id })
                return errorEnvelope('FK_INTERNAL', ..., 500)

    Step 3.  Parse and validate JSON body:
              a. case_id           — required, valid UUID; else 400 FK_INVALID_INPUT
              b. content_type      — one of ['image/jpeg','image/webp']; else 400 FK_INVALID_CONTENT_TYPE
              c. declared_size_bytes — integer ≥ 1 ≤ 10,485,760
                 missing or ≤ 0  → 400 FK_INVALID_INPUT
                 > 10,485,760   → 400 FK_FILE_TOO_LARGE
              d. non-JSON body   → 400 FK_INVALID_INPUT
              All: safeLog({ fn, status: 4xx, error_code, duration_ms: elapsed(t0),
                             request_id, user_id }) then return.

    Step 4.  rawToken      = deps.generateToken()
              tokenHash     = await deps.sha256(new TextEncoder().encode(rawToken))
              sessionExpiry = new Date(deps.now().getTime() + 900_000)

    Step 5.  { data: row, error: reserveErr } =
                await deps.reserveSession(ctx.supabaseAdmin, {
                  p_case_id: caseId, p_uploader_id: ctx.userClaims.id,
                  p_token_hash: tokenHash, p_content_type: contentType,
                  p_declared_size: declaredSizeBytes,
                  p_client_expires_at: sessionExpiry.toISOString(),
                })
              if reserveErr:
                code   = extractDbErrorCode(reserveErr) ?? 'FK_INTERNAL'
                status = { FK_NOT_FOUND:404, FK_WRONG_STATE:409,
                           FK_UPLOAD_IN_PROGRESS:409, FK_FORBIDDEN:403 }[code] ?? 500
                safeLog({ fn, status, error_code: code, duration_ms: elapsed(t0),
                          request_id, user_id, case_id })
                return errorEnvelope(code, ..., status)
              if !row:
                safeLog({ fn, status: 500, error_code: 'FK_INTERNAL',
                          duration_ms: elapsed(t0), request_id, user_id, case_id })
                return errorEnvelope('FK_INTERNAL', ..., 500)
              sessionId = row.session_id
              storagePath = row.original_storage_path

    Step 6.  let presignedUrl: string, urlExpiresAt: Date
              try:
                ({ url: presignedUrl, expiresAt: urlExpiresAt } =
                   await deps.presign(storagePath, 300))
              catch (presignErr):
                const { error: failErr } =
                  await deps.failSession(ctx.supabaseAdmin, sessionId, 'FK_INTERNAL')
                if failErr: safeLog({ ..., outcome: 'fail_session_error' })
                safeLog({ fn, status: 500, error_code: 'FK_INTERNAL',
                          outcome: 'failed_presign', duration_ms: elapsed(t0),
                          request_id, user_id, case_id })
                return errorEnvelope('FK_INTERNAL', ..., 500)

    Step 7.  { error: activateErr } =
                await deps.activateSession(ctx.supabaseAdmin, {
                  p_session_id: sessionId,
                  p_actual_storage_upload_expires_at: urlExpiresAt.toISOString(),
                })
              if activateErr:
                const { error: failErr } =
                  await deps.failSession(ctx.supabaseAdmin, sessionId, 'FK_INTERNAL')
                if failErr: safeLog({ ..., outcome: 'fail_session_error' })
                safeLog({ fn, status: 500, error_code: 'FK_INTERNAL',
                          outcome: 'failed_activate', duration_ms: elapsed(t0),
                          request_id, user_id, case_id })
                return errorEnvelope('FK_INTERNAL', ..., 500)
                // presignedUrl is discarded — not returned to client

    Step 8.  safeLog({ fn, status: 200, outcome: 'activated', duration_ms: elapsed(t0),
                       request_id, user_id, case_id })
              return new Response(JSON.stringify({
                presigned_url: presignedUrl,
                upload_token:  rawToken,
                expires_at:    urlExpiresAt.toISOString(),
              }), {
                status: 200,
                headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' },
              })

  } catch (unexpected) {
    // Any unanticipated throw: log, attempt compensation if session was reserved,
    // then return 500. presignedUrl is never returned from the catch block.
    if (sessionId) {
      await deps.failSession(ctx?.supabaseAdmin, sessionId, 'FK_INTERNAL').catch(() => {})
    }
    safeLog({ fn, status: 500, error_code: 'FK_INTERNAL', outcome: 'unexpected_throw',
              duration_ms: elapsed(t0), request_id })
    return errorEnvelope('FK_INTERNAL', 'Internal error', 500)
  }
```

### 5.8 Error Response Table

| Condition | HTTP | Code |
|---|---|---|
| Non-POST method | 405 | — (plain body; `Allow: POST` header) |
| Missing or invalid JWT (gateway or handler) | 401 | `FK_UNAUTHENTICATED` |
| Profile absent | 403 | `FK_FORBIDDEN` |
| `is_active = false` | 403 | `FK_FORBIDDEN` |
| `onboarding_complete = false` | 403 | `FK_FORBIDDEN` |
| `is_suspended = true` | 403 | `FK_FORBIDDEN` |
| Profile check query/transport failure | 500 | `FK_INTERNAL` |
| Invalid/missing `case_id` | 400 | `FK_INVALID_INPUT` |
| `content_type` not in allowlist | 400 | `FK_INVALID_CONTENT_TYPE` |
| `declared_size_bytes` missing or ≤ 0 | 400 | `FK_INVALID_INPUT` |
| `declared_size_bytes` > 10,485,760 | 400 | `FK_FILE_TOO_LARGE` |
| Non-JSON body | 400 | `FK_INVALID_INPUT` |
| Case not found or caller not poster | 404 | `FK_NOT_FOUND` |
| Case not in draft state | 409 | `FK_WRONG_STATE` |
| Active session (pending / processing / sanitized) | 409 | `FK_UPLOAD_IN_PROGRESS` |
| Uploader has active deletion record | 403 | `FK_FORBIDDEN` |
| Reserve RPC returns null data | 500 | `FK_INTERNAL` |
| Presign failure | 500 | `FK_INTERNAL` |
| Activate failure | 500 | `FK_INTERNAL` |
| Unexpected throw (top-level catch) | 500 | `FK_INTERNAL` |

---

## Section 6 — Test Matrix

### 6.1 Unit Test Harness

**Run command:**
```sh
deno test --allow-net --allow-env --allow-read \
  supabase/functions/upload-authorize/upload-authorize.test.ts
```

Lint, format, and type-check all scaffolded files:
```sh
deno check supabase/functions/_shared/*.ts supabase/functions/upload-authorize/*.ts
deno fmt --check supabase/functions/
deno lint supabase/functions/
```

Unit tests use injected stubs throughout. They assert calls, arguments, ordering, compensation, and response contents. No live DB connection required.

**Stub library:**
```typescript
// Auth
const stubAuthOk = (userId: string): Deps['getAuth'] =>
  async () => ({ ok: true, ctx: fakeCtx(userId), error: null })
const stubAuthFail: Deps['getAuth'] =
  async () => ({ ok: false, ctx: null,
                 error: errorEnvelope('FK_UNAUTHENTICATED', 'unauth', 401) })

// Profile
const stubProfileOk:        Deps['checkProfile'] = async () => ({ status: 'ok' })
const stubProfileForbidden: Deps['checkProfile'] = async () =>
  ({ status: 'forbidden', reason: 'inactive' })
const stubProfileSuspended: Deps['checkProfile'] = async () =>
  ({ status: 'forbidden', reason: 'suspended' })
const stubProfileError:     Deps['checkProfile'] = async () => ({ status: 'error' })

// RPC — normal returns
const stubReserveOk = (row: ReserveResult): Deps['reserveSession'] =>
  async () => ({ data: row, error: null })
const stubReserveNull: Deps['reserveSession'] = async () => ({ data: null, error: null })
const stubReserveFail = (code: FkErrorCode): Deps['reserveSession'] =>
  async () => ({ data: null, error: new Error(code) })
const stubReserveThrow: Deps['reserveSession'] = async () => {
  throw new Error('adapter threw') }
const stubActivateOk:    Deps['activateSession'] = async () => ({ data: null, error: null })
const stubActivateFail:  Deps['activateSession'] = async () =>
  ({ data: null, error: new Error('FK_INTERNAL') })
const stubActivateThrow: Deps['activateSession'] = async () => {
  throw new Error('adapter threw') }
const stubFailOk:  Deps['failSession'] = async () => ({ data: null, error: null })
const stubFailErr: Deps['failSession'] = async () =>
  ({ data: null, error: new Error('conn refused') })
const stubFailThrow: Deps['failSession'] = async () => { throw new Error('adapter threw') }

// Presign
const stubPresignOk = (expiresAt: Date): Deps['presign'] =>
  async () => ({ url: 'https://s3.test/presigned', expiresAt })
const stubPresignFail: Deps['presign'] = async () => {
  throw new Error('S3 connection refused') }

// Clock and token
const stubClock  = (t: Date): Deps['now'] => () => t
const stubToken  = (token: string): Deps['generateToken'] => () => token
```

### 6.2 Local Integration Test Harness

Integration tests use real RPC adapters against the local Supabase stack. The reserve adapter is wrapped to capture the internal `session_id`, which is then used to query `private.upload_sessions` via the local database.

**Private-schema query script (`tools/private_session_check.sh`):**
```sh
#!/usr/bin/env bash
# Usage: ./tools/private_session_check.sh <session_uuid>
SESSION_ID="${1:?Usage: $0 <session_uuid>}"
DB_URL=$(supabase status -o env 2>/dev/null | grep '^DB_URL=' | cut -d= -f2-)
if [[ -z "$DB_URL" ]]; then
  echo "ERROR: could not read DB_URL from supabase status -o env" >&2
  exit 1
fi
psql "$DB_URL" \
  --no-password \
  -t -A \
  -v "sid=${SESSION_ID}" \
  -c "SELECT upload_token_hash, status, storage_upload_expires_at, failed_reason
      FROM private.upload_sessions WHERE session_id = :'sid';"
```

Session UUID is passed as a `psql` variable (`:sid`), not interpolated into the query string. The DB_URL is read from `supabase status -o env`, not hard-coded.

**Integration reserve adapter (wraps real RPC; captures session_id for assertions):**
```typescript
let capturedSessionId: string | null = null
const realReserveWithCapture: Deps['reserveSession'] = async (admin, params) => {
  const result = await admin.rpc('reserve_upload_session', params).single()
  if (result.data?.session_id) capturedSessionId = result.data.session_id
  return result
}
```

Integration tests for T-A-04, T-A-06, T-A-38, T-A-39 call the script with `capturedSessionId` after the handler returns.

### 6.3 Happy Path

| # | Description | Type | Expected |
|---|---|---|---|
| T-A-01 | Valid JPEG, draft case, active profile | Unit | 200; `presigned_url`, `upload_token`, `expires_at`; `session_id` absent; `Cache-Control: no-store` |
| T-A-02 | Valid WebP, same conditions | Unit | 200; same shape |
| T-A-03 | `expires_at` = `parseAmzDate(X-Amz-Date) + 300s` (not local clock); clock stub verifies | Unit | Pass |
| T-A-04 | SHA-256(response `upload_token`) matches `upload_token_hash` in `private.upload_sessions` | Integration | Pass (psql script with capturedSessionId) |
| T-A-05 | `session_id` absent from 200 body | Unit | Pass |
| T-A-06 | After 200: DB `status = 'pending'` and `storage_upload_expires_at` equals `expires_at` | Integration | Pass (psql script) |
| T-A-07 | `X-Amz-Expires = 300` (integer duration, not timestamp); reconstructed `X-Amz-Date + X-Amz-Expires` equals `response.expires_at` and DB `storage_upload_expires_at` | Unit+Integration | Pass |

### 6.4 Method Enforcement

| # | Description | Type | Expected |
|---|---|---|---|
| T-A-08 | `GET /upload-authorize` | Unit | 405; `Allow: POST` header; `Cache-Control: no-store` |
| T-A-09 | `PUT /upload-authorize` | Unit | 405 |
| T-A-10 | `DELETE /upload-authorize` | Unit | 405 |

### 6.5 Authentication and Profile

| # | Description | Type | Expected |
|---|---|---|---|
| T-A-11 | Missing `Authorization` header | Integration | HTTP 401; gateway or `FK_UNAUTHENTICATED` envelope |
| T-A-12 | Malformed JWT | Integration | HTTP 401; gateway or application 401 |
| T-A-13 | Expired JWT | Integration | HTTP 401; gateway or application 401 |
| T-A-14 | `is_active = false` profile | Unit | 403 `FK_FORBIDDEN` |
| T-A-15 | Deletion-prepared profile (`is_active = false` set by `prepare_account_deletion_wrapper`) | Integration | 403 `FK_FORBIDDEN` |
| T-A-16 | `onboarding_complete = false` | Unit | 403 `FK_FORBIDDEN` |
| T-A-17 | `is_suspended = true` profile | Unit | 403 `FK_FORBIDDEN` |
| T-A-18 | Profile row absent | Unit | 403 `FK_FORBIDDEN` |
| T-A-19 | Profile check returns `'error'` (transport failure stub) | Unit | 500 `FK_INTERNAL` |

### 6.6 Request Validation

| # | Description | Type | Expected |
|---|---|---|---|
| T-A-20 | Missing `case_id` | Unit | 400 `FK_INVALID_INPUT` |
| T-A-21 | `case_id` not a valid UUID | Unit | 400 `FK_INVALID_INPUT` |
| T-A-22 | `content_type = "image/png"` | Unit | 400 `FK_INVALID_CONTENT_TYPE` |
| T-A-23 | `content_type = "image/heic"` | Unit | 400 `FK_INVALID_CONTENT_TYPE` |
| T-A-24 | Missing `content_type` | Unit | 400 `FK_INVALID_CONTENT_TYPE` |
| T-A-25 | Missing `declared_size_bytes` | Unit | 400 `FK_INVALID_INPUT` |
| T-A-26 | `declared_size_bytes = 0` | Unit | 400 `FK_INVALID_INPUT` |
| T-A-27 | `declared_size_bytes = -1` | Unit | 400 `FK_INVALID_INPUT` |
| T-A-28 | `declared_size_bytes = 10,485,760` (at limit) | Unit | 200 |
| T-A-29 | `declared_size_bytes = 10,485,761` (one over) | Unit | 400 `FK_FILE_TOO_LARGE` |
| T-A-30 | Non-JSON body | Unit | 400 `FK_INVALID_INPUT` |

### 6.7 DB-Driven Errors

| # | Description | Type | Expected |
|---|---|---|---|
| T-A-31 | `case_id` does not exist | Unit | 404 `FK_NOT_FOUND` |
| T-A-32 | Caller is not poster | Unit | 404 `FK_NOT_FOUND` |
| T-A-33 | Case state is `launched` | Unit | 409 `FK_WRONG_STATE` |
| T-A-34 | Active session `status = 'pending'` | Unit | 409 `FK_UPLOAD_IN_PROGRESS` |
| T-A-35 | Active session `status = 'processing'` | Unit | 409 `FK_UPLOAD_IN_PROGRESS` |
| T-A-36 | Active session `status = 'sanitized'` | Unit | 409 `FK_UPLOAD_IN_PROGRESS` (index covers pending/processing/sanitized) |
| T-A-37 | Prior session `status = 'failed'` | Integration | 200 (failed sessions do not block) |
| T-A-38 | Prior session `status = 'complete'` | Integration | 200 (complete sessions do not block) |
| T-A-39 | Uploader has deletion record `status = 'database_prepared'` | Unit | 403 `FK_FORBIDDEN` |
| T-A-40 | Reserve returns `data = null`, `error = null` | Unit | 500 `FK_INTERNAL` |

### 6.8 Presign, Activate, and Unexpected Failures

| # | Description | Type | Expected |
|---|---|---|---|
| T-A-41 | `presign` stub throws | Unit | 500 `FK_INTERNAL`; `failSession` called once with `sessionId`; URL absent |
| T-A-42 | `activateSession` returns `{ error }` | Unit | 500 `FK_INTERNAL`; `failSession` called; URL absent |
| T-A-43 | `reserveSession` stub throws (unexpected) | Unit | Top-level catch; 500 `FK_INTERNAL`; `sessionId = null` so `failSession` NOT called |
| T-A-44 | `activateSession` stub throws (unexpected) | Unit | Top-level catch; 500 `FK_INTERNAL`; `failSession` called with captured `sessionId` |
| T-A-45 | `failSession` stub returns `{ error }` after presign failure | Unit | 500 `FK_INTERNAL`; fail-session error logged and swallowed; no second throw |
| T-A-46 | `failSession` stub throws after presign failure | Unit | Top-level catch handles; 500 `FK_INTERNAL`; URL not returned |
| T-A-47 | Presign failure; verify DB `status = 'failed'`, `failed_reason = 'FK_INTERNAL'` | Integration | Pass (psql script with capturedSessionId) |
| T-A-48 | Activate failure; verify DB `status = 'failed'`; URL absent from response | Integration | Pass (psql script with capturedSessionId) |

### 6.9 Race Tests (Step 24 Rev 10 §5.1, V4 Substitutions Applied)

Identifier substitutions: `challenge_id → case_id`, `public.challenges → public.cases`, `state = 'active' → state = 'launched'`.

**Race A — Full Authorization Orchestration vs. Account Deletion:**

Flow A: complete `upload-authorize` handler (all steps).
Flow B (complete deletion sequence):
1. `prepare_account_deletion_wrapper(user_id)` — anonymises profile, sets `is_active = false`, records `database_prepared` in `deletion_log`
2. `quiesce_upload_sessions_for_deletion(user_id)` — transitions `pending`/`sanitized`/expired-`processing` sessions to `failed`; returns rows with active processing leases for caller to wait on
3. `get_upload_capability_expiry(user_id)` — returns `MAX(storage_upload_expires_at + 30s)` for non-cleaned sessions with active windows; caller waits until this value passes
4. Only after unblocked: physical storage deletion, Auth user deletion, terminal `complete` status

`database_prepared` is reached at step 1, before quiescing or expiry checks. It is not deletion completion.

Three and only three valid outcomes:

1. **Deletion wins before reservation:** Flow B step 1 completes before Flow A's `reserve_upload_session`. Flow A's reserve returns `FK_FORBIDDEN` or `FK_WRONG_STATE`. No URL issued. No session created. No compensation needed.

2. **Reservation wins; deletion quiesces before activation:** Flow A's `reserve_upload_session` succeeds (session created, `sessionId` captured). Flow B's step 2 (`quiesce_upload_sessions_for_deletion`) transitions the session to `failed` before Flow A calls `activate_upload_session`. `activate_upload_session` returns an error. Flow A calls `fail_upload_session` (no-op if already failed, idempotent) and returns 500 `FK_INTERNAL`. URL not returned. Flow B continues: step 3 checks capability expiry (none active), proceeds to storage/auth deletion.

3. **Activation commits before quiescing:** `activate_upload_session` commits. URL returned to client (200). Flow B's step 2 finds the session in `sanitized` or `pending` state and transitions it to `failed`. Flow B's step 3 (`get_upload_capability_expiry`) returns a non-null `blocking_until = storage_upload_expires_at + 30s`. Flow B must not proceed to physical storage deletion, Auth deletion, or terminal `complete` until `blocking_until` has passed.

**Failure condition:** a URL is returned AND terminal deletion `complete` occurs before `storage_upload_expires_at + 30 seconds`. This is the invariant enforced by `get_upload_capability_expiry`.

**Race B — Concurrent Duplicate Reservations:**

Two simultaneous `upload-authorize` calls, same `case_id`, same `user_id`. The partial unique index `upload_sessions_one_active_per_challenge WHERE status IN ('pending', 'processing', 'sanitized')` enforces exactly one succeeds. Expected: one returns 200; the other returns 409 `FK_UPLOAD_IN_PROGRESS`. No other outcome is acceptable.

---

## Section 7 — Environment Variables

All read at runtime via `Deno.env.get()`. No literal values in source code or this document.

**Amendment B to Step 27 §8:** Step 27 recorded local S3 values as `access_key_id=stub` and `secret=ANON_KEY`. Gate 4 evidence (2026-08-13) established that actual local credentials come from `supabase status -o env` as `S3_PROTOCOL_ACCESS_KEY_ID` and `S3_PROTOCOL_ACCESS_KEY_SECRET`. Step 27's stub values are superseded.

| Variable | Hosted source | Local fallback |
|---|---|---|
| `SUPABASE_URL` | Auto-provisioned | Auto-provisioned |
| `SUPABASE_PUBLISHABLE_KEYS` | Auto-provisioned (plural) | `SUPABASE_PUBLISHABLE_KEY` (singular) |
| `SUPABASE_SECRET_KEYS` | Auto-provisioned (plural) | `SUPABASE_SECRET_KEY` (singular) |
| `SUPABASE_JWKS` | Auto-provisioned (hosted only) | Not present locally; `@supabase/server` falls back |
| `S3_ENDPOINT` | `.storage.` hostname | `http://127.0.0.1:54321/storage/v1/s3` |
| `S3_REGION` | Dashboard value | `local` |
| `S3_ACCESS_KEY_ID` | Dashboard-generated | From `supabase status -o env` → `S3_PROTOCOL_ACCESS_KEY_ID` |
| `S3_SECRET_ACCESS_KEY` | Dashboard secret | From `supabase status -o env` → `S3_PROTOCOL_ACCESS_KEY_SECRET` |
| `S3_BUCKET` | `game-media` | `game-media` |

Local S3 values set in `supabase/functions/.env` (git-ignored). Keys obtained from `supabase status -o env` at setup time — never committed.

`@supabase/server@1.4.1` auto-provisions auth secrets from the hosted plural variables; locally it falls back to the singular variants. The handler does not reference these variables explicitly.

---

## Section 8 — Scaffold and Quality Gates

### Gate 6: Scaffold

```sh
deno check supabase/functions/_shared/*.ts supabase/functions/upload-authorize/*.ts
deno fmt --check supabase/functions/
deno lint supabase/functions/
gitleaks detect --source . --no-git
```

All must pass with zero output.

### deno.lock

```sh
deno cache --lock=deno.lock \
  supabase/functions/_shared/context.ts \
  supabase/functions/_shared/profile.ts \
  supabase/functions/_shared/s3.ts \
  supabase/functions/_shared/errors.ts \
  supabase/functions/_shared/log.ts \
  supabase/functions/_shared/crypto.ts \
  supabase/functions/upload-authorize/index.ts \
  supabase/functions/upload-authorize/upload-authorize.test.ts
```

`deno.lock` committed.

### `config.toml`

```toml
[functions.upload-authorize]
verify_jwt = true
```

---

## Section 9 — Dependency Versions (Pinned)

All confirmed from npm registry on 2026-08-13:

| Import specifier | Pinned version | Purpose |
|---|---|---|
| `npm:@supabase/server@1.4.1` | **1.4.1** | JWT verification; auto-provisions auth secrets |
| `npm:@supabase/supabase-js@2.112.3` | **2.112.3** | Supabase client |
| `npm:@aws-sdk/client-s3@3.1109.0` | **3.1109.0** | S3 client |
| `npm:@aws-sdk/s3-request-presigner@3.1109.0` | **3.1109.0** | Presigned URL generation |

If `deno.lock` resolves any direct dependency to a different version, it must be reported before implementation proceeds.

---

## Section 10 — Amendments Summary

| Amendment | Supersedes | Content |
|---|---|---|
| A — Session claim window | Step 24 §4.1 | 5 min → 15 min for `upload-authorize`; see §5.3 |
| B — Local S3 credentials | Step 27 §8 | `stub`/`ANON_KEY` → `S3_PROTOCOL_*` from `supabase status -o env`; Gate 4 evidence |

---

## Section 11 — Approval Record

| Party | Status | Notes |
|---|---|---|
| Claude | Approved | Rev 4; all 7 Codex blockers resolved |
| Codex | Pending | — |
| Bill | Pending | — |

**This approval authorizes TypeScript implementation only. No cloud deployment authorized.**
