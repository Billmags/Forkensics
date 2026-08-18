# Step A Proposal — Rev 3 — `upload-authorize` Edge Function

**Status:** DRAFT — Awaiting three-party approval (Claude + Codex + Bill)

**Supersedes:** Rev 2 (CHANGES REQUIRED — 5 blockers from Codex review)

**Governance gate:** All three parties must approve before any TypeScript is written.
Magic words: `APPROVED: Step A Rev 3 — upload-authorize`

**Binding contracts:**
- Step 27 Rev 5 (approved 2026-08-12) — §5.1, §6, §7, §8
- Step 24 Rev 10 (approved 2026-08-07) — §5.1 test matrix
  - **Amendment A** — Session claim window: Step 24 §4.1's 5-minute window superseded by 15 minutes for `upload-authorize`. See Section 5.3.
  - **Amendment B** — Local S3 credentials: Step 27's `access_key_id=stub` / `secret=ANON_KEY` superseded by actual local credentials obtained from `supabase status -o env`. See Section 7.
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
    index.ts            ← function handler
    upload-authorize.test.ts
deno.lock               ← all versions pinned
```

`cron.ts` deferred — not scaffolded under this step.

---

## Section 4 — Shared Module Specification

All modules: zero side effects on import. No global state. All env vars read inside calls via `Deno.env.get()`, never at module level.

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

// Returns a Response with JSON body { error: { code, message } } and Cache-Control: no-store.
export function errorEnvelope(
  code: FkErrorCode,
  message: string,
  status: number,
): Response

// Inspects err.message against an anchored allowlist of FK_* prefixes.
// Allowed prefixes: FK_NOT_FOUND, FK_WRONG_STATE, FK_UPLOAD_IN_PROGRESS,
//                   FK_FORBIDDEN, FK_INTERNAL.
// Returns null if no prefix matches (caller maps to FK_INTERNAL).
// Raw database messages never pass through to logs or responses.
export function extractDbErrorCode(err: unknown): FkErrorCode | null
```

### 4.2 `crypto.ts`

```typescript
// Generates 32 cryptographically random bytes via crypto.getRandomValues(new Uint8Array(32)),
// encodes as base64url. Returns a 43-character string (~256 bits of entropy).
export function generateUploadToken(): string

// Returns lowercase 64-char hex SHA-256 of data.
// Token hashing: sha256Hex(new TextEncoder().encode(base64urlToken))
export async function sha256Hex(data: Uint8Array): Promise<string>
```

### 4.3 `log.ts`

Progressive field availability: `user_id` is only included after authentication succeeds; `case_id` is only included after body validation succeeds. Earlier log calls omit fields not yet available.

```typescript
// Structured log with allowlist enforcement.
// Required: fn (function name), status (HTTP status), duration_ms.
// Conditional: error_code (FK_* only), request_id, user_id (UUID — post-auth only),
//              case_id (UUID — post-validation only), outcome (sanitized outcome string).
// NEVER logged: paths, tokens, presigned URLs, secrets, keys, JWTs,
//               raw database error messages, content_type, declared_size_bytes.
export function safeLog(fields: {
  fn: string
  status: number
  duration_ms: number
  error_code?: FkErrorCode
  request_id?: string
  user_id?: string      // only when auth is confirmed
  case_id?: string      // only when body is validated
  outcome?: string      // e.g. 'reserved', 'activated', 'failed_presign', 'failed_activate'
}): void
```

Step 24's content-type and session-activation-outcome logging requirement is amended: `content_type` and `declared_size_bytes` are not logged in any form. The `outcome` field covers activation outcomes.

### 4.4 `context.ts`

```typescript
import { createSupabaseContext } from 'npm:@supabase/server@1.4.1'

// Wraps createSupabaseContext(req, { auth: 'user' }).
// Local dev: runtime auto-provisions from SUPABASE_PUBLISHABLE_KEY (singular)
//            and SUPABASE_SECRET_KEY (singular); not the legacy anon/service-role/JWT trio.
// Never throws. Never decodes JWT manually.
export async function getAuthContext(req: Request): Promise<
  | { ok: true;  ctx: AuthContext; error: null }
  | { ok: false; ctx: null;       error: Response }
>

export interface AuthContext {
  userClaims: { id: string }    // verified user UUID
  supabase:      SupabaseClient  // RLS-scoped (authenticated user)
  supabaseAdmin: SupabaseClient  // service_role (bypasses RLS)
}
```

### 4.5 `profile.ts`

```typescript
export type ProfileCheckResult =
  | { status: 'ok' }
  | { status: 'forbidden'; reason: 'absent' | 'inactive' | 'incomplete' | 'suspended' | 'auth_deleted' }
  | { status: 'error' }   // query or transport failure → caller returns 500

// Queries public.profiles for is_active = true AND onboarding_complete = true
// AND is_suspended = false. Returns 'forbidden' only on confirmed disqualifying state.
// Returns 'error' on any query or network failure.
// Distinguishes 'auth_deleted' when the profile has a tombstone/auth_deleted_at marker.
export async function checkActiveProfile(
  supabase: SupabaseClient,
  userId: string,
): Promise<ProfileCheckResult>

// Returns { ok: boolean, error: boolean } — distinguishes absent from infra failure.
// ok: true  = row exists (any status)
// ok: false, error: false = row absent
// ok: false, error: true  = query failure
export async function checkProfileExists(
  supabase: SupabaseClient,
  userId: string,
): Promise<{ ok: boolean; error: boolean }>
```

### 4.6 `s3.ts`

```typescript
// Signs a presigned PUT URL. Returns { url, expiresAt } where expiresAt is parsed
// from the signed URL's own X-Amz-Date (YYYYMMDDTHHmmssZ) and X-Amz-Expires (seconds)
// query parameters — not from the local clock.
//
// Reads S3_ENDPOINT, S3_REGION, S3_ACCESS_KEY_ID, S3_SECRET_ACCESS_KEY, S3_BUCKET at call time.
// forcePathStyle: true. createSignedUploadUrl() prohibited. expiresIn MUST be 300 (literal type).
// Throws on signing failure (caller catches and calls fail_upload_session via inspecting { error }).
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
{
  "presigned_url": "<S3 presigned PUT URL>",
  "upload_token":  "<base64url, 43 chars>",
  "expires_at":    "<ISO 8601 — from signed URL's X-Amz-Date + X-Amz-Expires>"
}
```

**Headers on all responses:** `Cache-Control: no-store`

`session_id` is never present in any response.

### 5.2 `config.toml` entry

```toml
[functions.upload-authorize]
verify_jwt = true
```

### 5.3 Session Timing (Amendment A to Step 24 §4.1)

Step 24 §4.1 specified a 5-minute session claim window. This step amends it to 15 minutes for `upload-authorize`. The claim window and URL expiry serve different purposes: the S3 presigned URL expires in 5 minutes (enforced by S3); the session must remain claimable by `upload-complete` after the full upload duration. 15 minutes is the minimum that prevents spurious `FK_UPLOAD_IN_PROGRESS` errors on slow uploads.

| Window | Value | Source |
|---|---|---|
| `p_client_expires_at` | `now() + 900s` | Handler clock at reservation |
| `ExpiresIn` | `300` (literal) | S3 parameter — never changed |
| `expiresAt` from `presignPutUrl` | Parsed from `X-Amz-Date + X-Amz-Expires` | Authoritative; no clock estimate |
| `p_actual_storage_upload_expires_at` | `expiresAt.toISOString()` | Identical to response `expires_at` |

**Invariant:** response `expires_at`, DB `storage_upload_expires_at`, and the URL's embedded expiry are identical.

### 5.4 Upload Token Pattern

1. `rawToken = deps.generateToken()` → 43-char base64url (256 bits)
2. `tokenHash = await deps.sha256(new TextEncoder().encode(rawToken))` → 64-char hex
3. `reserve_upload_session(... p_token_hash: tokenHash ...)` — hash stored, raw token never stored
4. Return `rawToken` to client as `upload_token`

### 5.5 RPC Error Handling

`supabase.rpc()` returns `{ data, error }` — it does not throw under normal conditions. Every RPC call must inspect `error` before using `data`. The reserve RPC returns a table result; use `.single()` and validate that `data` is non-null before proceeding. Compensation calls (`fail_upload_session`) also inspect `{ error }` and log any failure, then continue (best-effort only).

```typescript
// Pattern for all RPC calls:
const { data, error } = await supabaseAdmin.rpc('reserve_upload_session', { ... }).single()
if (error) { /* map via extractDbErrorCode; goto error handler */ }
if (!data)  { /* unexpected empty result; treat as FK_INTERNAL */ }

// Pattern for compensation calls:
const { error: failErr } = await deps.failSession(supabaseAdmin, sessionId, 'FK_INTERNAL')
if (failErr) {
  safeLog({ fn, status: 0, duration_ms: 0, error_code: 'FK_INTERNAL', outcome: 'fail_session_error', request_id })
  // swallow — best-effort only
}
```

### 5.6 Dependency Injection

All external calls are injectable via a `Deps` interface. This enables deterministic test forcing for auth, profile, reserve, activate, fail, presign, token generation, hash, and clock — without requiring a live Supabase stack for unit tests.

```typescript
export interface Deps {
  // Token generation and hashing
  generateToken: () => string
  sha256:        (data: Uint8Array) => Promise<string>

  // Auth context (wraps createSupabaseContext)
  getAuth: (req: Request) => Promise<
    | { ok: true;  ctx: AuthContext; error: null }
    | { ok: false; ctx: null;       error: Response }
  >

  // Profile check
  checkProfile: (supabase: SupabaseClient, userId: string) => Promise<ProfileCheckResult>

  // RPC adapters — wrap supabaseAdmin.rpc() and return { data, error }
  reserveSession: (
    supabaseAdmin: SupabaseClient,
    params: ReserveParams,
  ) => Promise<{ data: ReserveResult | null; error: unknown }>

  activateSession: (
    supabaseAdmin: SupabaseClient,
    params: ActivateParams,
  ) => Promise<{ data: null; error: unknown }>

  failSession: (
    supabaseAdmin: SupabaseClient,
    sessionId: string,
    errorCode: FkErrorCode,
  ) => Promise<{ data: null; error: unknown }>

  // S3 presigner
  presign: (objectPath: string, expiresIn: 300) => Promise<{ url: string; expiresAt: Date }>

  // Clock
  now: () => Date
}

// Default implementations used in production:
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

// Handler factory for testability:
export function makeHandler(deps: Deps = defaultDeps): (req: Request) => Promise<Response>
```

### 5.7 Implementation Sequence

```
Step 0.  request_id = req.headers.get('X-Request-Id') ?? crypto.randomUUID()
          t0 = performance.now()

Step 1.  { ok, ctx, error } = await deps.getAuth(req)
          if !ok:
            safeLog({ fn, status: 401, duration_ms, error_code: 'FK_UNAUTHENTICATED', request_id })
            return error  // errorEnvelope already set by getAuthContext

Step 2.  result = await deps.checkProfile(ctx.supabase, ctx.userClaims.id)
          if result.status === 'forbidden':
            safeLog({ fn, status: 403, error_code: 'FK_FORBIDDEN', duration_ms, request_id,
                      user_id: ctx.userClaims.id })
            return errorEnvelope('FK_FORBIDDEN', ..., 403)
          if result.status === 'error':
            safeLog({ fn, status: 500, error_code: 'FK_INTERNAL', duration_ms, request_id,
                      user_id: ctx.userClaims.id })
            return errorEnvelope('FK_INTERNAL', ..., 500)

Step 3.  Parse and validate JSON body:
          a. case_id         — required, valid UUID; else 400 FK_INVALID_INPUT
          b. content_type    — required, one of ['image/jpeg','image/webp']; else 400 FK_INVALID_CONTENT_TYPE
          c. declared_size_bytes — required, integer ≥ 1 ≤ 10,485,760
             missing or ≤ 0 → 400 FK_INVALID_INPUT
             > 10,485,760   → 400 FK_FILE_TOO_LARGE
          d. non-JSON body  → 400 FK_INVALID_INPUT
          All: safeLog({ fn, status: 4xx, error_code, duration_ms, request_id, user_id }) then return.

Step 4.  rawToken       = deps.generateToken()
          tokenHash      = await deps.sha256(new TextEncoder().encode(rawToken))
          sessionExpiry  = new Date(deps.now().getTime() + 900_000)

Step 5.  { data: row, error: reserveErr } =
            await deps.reserveSession(ctx.supabaseAdmin, {
              p_case_id:           caseId,
              p_uploader_id:       ctx.userClaims.id,
              p_token_hash:        tokenHash,
              p_content_type:      contentType,
              p_declared_size:     declaredSizeBytes,
              p_client_expires_at: sessionExpiry.toISOString(),
            })
          if reserveErr:
            code = extractDbErrorCode(reserveErr) ?? 'FK_INTERNAL'
            status = { FK_NOT_FOUND: 404, FK_WRONG_STATE: 409, FK_UPLOAD_IN_PROGRESS: 409,
                       FK_FORBIDDEN: 403 }[code] ?? 500
            safeLog({ fn, status, error_code: code, duration_ms, request_id, user_id, case_id })
            return errorEnvelope(code, ..., status)
          if !row:
            safeLog({ fn, status: 500, error_code: 'FK_INTERNAL', duration_ms, request_id, user_id, case_id })
            return errorEnvelope('FK_INTERNAL', ..., 500)
          { session_id: sessionId, original_storage_path: storagePath } = row

Step 6.  try:
            { url: presignedUrl, expiresAt: urlExpiresAt } =
              await deps.presign(storagePath, 300)
          catch:
            const { error: failErr } = await deps.failSession(ctx.supabaseAdmin, sessionId, 'FK_INTERNAL')
            if failErr: safeLog({ ..., outcome: 'fail_session_error' })  // swallow
            safeLog({ fn, status: 500, error_code: 'FK_INTERNAL', outcome: 'failed_presign',
                      duration_ms, request_id, user_id, case_id })
            return errorEnvelope('FK_INTERNAL', ..., 500)

Step 7.  { error: activateErr } =
            await deps.activateSession(ctx.supabaseAdmin, {
              p_session_id:                      sessionId,
              p_actual_storage_upload_expires_at: urlExpiresAt.toISOString(),
            })
          if activateErr:
            const { error: failErr } = await deps.failSession(ctx.supabaseAdmin, sessionId, 'FK_INTERNAL')
            if failErr: safeLog({ ..., outcome: 'fail_session_error' })
            safeLog({ fn, status: 500, error_code: 'FK_INTERNAL', outcome: 'failed_activate',
                      duration_ms, request_id, user_id, case_id })
            return errorEnvelope('FK_INTERNAL', ..., 500)
            // presignedUrl is discarded — never returned to client

Step 8.  safeLog({ fn, status: 200, outcome: 'activated', duration_ms, request_id, user_id, case_id })
          return new Response(JSON.stringify({
            presigned_url: presignedUrl,
            upload_token:  rawToken,
            expires_at:    urlExpiresAt.toISOString(),
          }), {
            status: 200,
            headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' },
          })
```

### 5.8 Error Response Table

| Condition | HTTP | Code |
|---|---|---|
| Missing or invalid JWT (gateway or handler) | 401 | `FK_UNAUTHENTICATED` |
| Profile absent | 403 | `FK_FORBIDDEN` |
| Profile `is_active = false` | 403 | `FK_FORBIDDEN` |
| Profile `onboarding_complete = false` | 403 | `FK_FORBIDDEN` |
| Profile `is_suspended = true` | 403 | `FK_FORBIDDEN` |
| Profile `auth_deleted` marker present | 403 | `FK_FORBIDDEN` |
| Profile check query/transport failure | 500 | `FK_INTERNAL` |
| Invalid/missing `case_id` | 400 | `FK_INVALID_INPUT` |
| `content_type` not in allowlist | 400 | `FK_INVALID_CONTENT_TYPE` |
| `declared_size_bytes` missing or ≤ 0 | 400 | `FK_INVALID_INPUT` |
| `declared_size_bytes` > 10,485,760 | 400 | `FK_FILE_TOO_LARGE` |
| Non-JSON body | 400 | `FK_INVALID_INPUT` |
| Case not found or caller not poster | 404 | `FK_NOT_FOUND` |
| Case not in draft state | 409 | `FK_WRONG_STATE` |
| Active upload session already exists | 409 | `FK_UPLOAD_IN_PROGRESS` |
| Uploader has active deletion record | 403 | `FK_FORBIDDEN` |
| Reserve RPC returns empty result | 500 | `FK_INTERNAL` |
| Presign failure | 500 | `FK_INTERNAL` |
| Activate failure | 500 | `FK_INTERNAL` |

---

## Section 6 — Test Matrix

### 6.1 Test Harness Setup

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

**Private-schema evidence harness (`tools/private_session_check.sh`):**

```sh
#!/usr/bin/env bash
# Usage: ./tools/private_session_check.sh <session_uuid>
SESSION_ID="${1:?Usage: $0 <session_uuid>}"
DB_PASS=$(supabase status -o env 2>/dev/null | grep '^DB_PASSWORD=' | cut -d= -f2-)
if [[ -z "$DB_PASS" ]]; then
  echo "ERROR: could not read DB_PASSWORD from supabase status -o env" >&2
  exit 1
fi
PGPASSWORD="$DB_PASS" psql \
  "postgresql://postgres@127.0.0.1:54322/postgres" \
  --no-password \
  -t -A \
  -c "SELECT upload_token_hash, status, storage_upload_expires_at, failed_reason
      FROM private.upload_sessions
      WHERE session_id = '${SESSION_ID}';"
```

This script is used only as local evidence for T-A-04, T-A-06, T-A-38, T-A-39. It never runs in Edge Function code. The `psql` call uses no PostgREST. The session UUID is passed as a CLI argument, never interpolated from untrusted input (tests run locally only).

**Dependency stubs:**
```typescript
// Auth stubs
const stubAuthOk = (userId: string): Deps['getAuth'] =>
  async () => ({ ok: true, ctx: fakeCtx(userId), error: null })
const stubAuthFail: Deps['getAuth'] =
  async () => ({ ok: false, ctx: null, error: errorEnvelope('FK_UNAUTHENTICATED', 'unauth', 401) })

// Profile stubs
const stubProfileOk:        Deps['checkProfile'] = async () => ({ status: 'ok' })
const stubProfileForbidden: Deps['checkProfile'] = async () => ({ status: 'forbidden', reason: 'inactive' })
const stubProfileSuspended: Deps['checkProfile'] = async () => ({ status: 'forbidden', reason: 'suspended' })
const stubProfileError:     Deps['checkProfile'] = async () => ({ status: 'error' })

// RPC stubs
const stubReserveOk = (row: ReserveResult): Deps['reserveSession'] =>
  async () => ({ data: row, error: null })
const stubReserveFail = (code: FkErrorCode): Deps['reserveSession'] =>
  async () => ({ data: null, error: new Error(code) })
const stubActivateOk: Deps['activateSession'] = async () => ({ data: null, error: null })
const stubActivateFail: Deps['activateSession'] = async () => ({ data: null, error: new Error('FK_INTERNAL') })
const stubFailOk:  Deps['failSession'] = async () => ({ data: null, error: null })
const stubFailErr: Deps['failSession'] = async () => ({ data: null, error: new Error('conn refused') })

// Presign stubs
const stubPresignOk = (expiresAt: Date): Deps['presign'] =>
  async () => ({ url: 'https://s3.test/presigned', expiresAt })
const stubPresignFail: Deps['presign'] = async () => { throw new Error('S3 connection refused') }

// Clock and token stubs
const stubClock = (t: Date): Deps['now'] => () => t
const stubToken = (token: string): Deps['generateToken'] => () => token
```

### 6.2 Happy Path

| # | Description | Expected |
|---|---|---|
| T-A-01 | Valid JPEG, draft case, active profile | 200; `presigned_url`, `upload_token`, `expires_at`; `session_id` absent; `Cache-Control: no-store` |
| T-A-02 | Valid WebP, same conditions | 200; same shape |
| T-A-03 | `expires_at` equals `X-Amz-Date + X-Amz-Expires` (not clock estimate); clock stub confirms | Pass |
| T-A-04 | SHA-256(response `upload_token`) matches `upload_token_hash` in `private.upload_sessions` (psql harness) | Pass |
| T-A-05 | `session_id` absent from 200 body | Pass |
| T-A-06 | After 200: `private.upload_sessions.status = 'pending'`, `storage_upload_expires_at = urlExpiresAt` (psql harness) | Pass |
| T-A-07 | Response `expires_at`, DB `storage_upload_expires_at`, and `X-Amz-Expires` in signed URL are identical | Pass |

### 6.3 Authentication and Profile

| # | Description | Expected |
|---|---|---|
| T-A-08 | Missing `Authorization` header | HTTP 401; gateway or `FK_UNAUTHENTICATED` envelope accepted |
| T-A-09 | Malformed JWT | HTTP 401; gateway or application 401 accepted |
| T-A-10 | Expired JWT | HTTP 401; gateway or application 401 accepted |
| T-A-11 | `is_active = false` profile | 403 `FK_FORBIDDEN` |
| T-A-12 | `onboarding_complete = false` | 403 `FK_FORBIDDEN` |
| T-A-13 | Profile row absent | 403 `FK_FORBIDDEN` |
| T-A-14 | `is_suspended = true` profile | 403 `FK_FORBIDDEN` |
| T-A-15 | `auth_deleted` marker on profile | 403 `FK_FORBIDDEN` |
| T-A-16 | Profile check returns `'error'` (transport failure stub) | 500 `FK_INTERNAL` |

### 6.4 Request Validation

| # | Description | Expected |
|---|---|---|
| T-A-17 | Missing `case_id` | 400 `FK_INVALID_INPUT` |
| T-A-18 | `case_id` not a valid UUID | 400 `FK_INVALID_INPUT` |
| T-A-19 | `content_type = "image/png"` | 400 `FK_INVALID_CONTENT_TYPE` |
| T-A-20 | `content_type = "image/heic"` | 400 `FK_INVALID_CONTENT_TYPE` |
| T-A-21 | Missing `content_type` | 400 `FK_INVALID_CONTENT_TYPE` |
| T-A-22 | Missing `declared_size_bytes` | 400 `FK_INVALID_INPUT` |
| T-A-23 | `declared_size_bytes = 0` | 400 `FK_INVALID_INPUT` |
| T-A-24 | `declared_size_bytes = -1` | 400 `FK_INVALID_INPUT` |
| T-A-25 | `declared_size_bytes = 10,485,760` (at limit) | 200 |
| T-A-26 | `declared_size_bytes = 10,485,761` (one over) | 400 `FK_FILE_TOO_LARGE` |
| T-A-27 | Non-JSON body | 400 `FK_INVALID_INPUT` |

### 6.5 DB-Driven Errors

| # | Description | Expected |
|---|---|---|
| T-A-28 | `case_id` does not exist | 404 `FK_NOT_FOUND` |
| T-A-29 | Caller is not poster | 404 `FK_NOT_FOUND` |
| T-A-30 | Case state is `launched` | 409 `FK_WRONG_STATE` |
| T-A-31 | Active session with `status = 'pending'` | 409 `FK_UPLOAD_IN_PROGRESS` |
| T-A-32 | Active session with `status = 'processing'` | 409 `FK_UPLOAD_IN_PROGRESS` |
| T-A-33 | Active session with `status = 'sanitized'` | 200 (sanitized sessions do not block reservation; DB constraint permits new reservation) |
| T-A-34 | Prior session with `status = 'failed'` | 200 (failed sessions do not block reservation) |
| T-A-35 | Prior session with `status = 'complete'` | 200 (complete sessions do not block reservation) |
| T-A-36 | Uploader has `deletion_log` row with `status = 'database_prepared'` | 403 `FK_FORBIDDEN` |
| T-A-37 | Reserve RPC returns `data = null` with no error (unexpected empty) | 500 `FK_INTERNAL` |

### 6.6 Presign and Activate Failures

| # | Description | Expected |
|---|---|---|
| T-A-38 | `presign` stub throws | 500 `FK_INTERNAL`; DB shows `status = 'failed'`, `failed_reason = 'FK_INTERNAL'` (psql); no URL in response |
| T-A-39 | `activateSession` stub returns `{ error }` | 500 `FK_INTERNAL`; DB shows `status = 'failed'` (psql); `presigned_url` NOT in response |
| T-A-40 | Presign fails; `failSession` stub also returns `{ error }` | 500 `FK_INTERNAL`; outer error returned; fail-session error logged and swallowed |

### 6.7 Race Tests (Step 24 Rev 10 §5.1, V4 Substitutions Applied)

Identifier substitutions: `challenge_id → case_id`, `public.challenges → public.cases`, `state = 'active' → state = 'launched'`.

**Race A — Full Authorization Orchestration vs. Account Deletion:**

Two concurrent full flows run simultaneously:
- Flow A: complete `upload-authorize` handler (Steps 1–8) for `case_id`, `user_id`
- Flow B: `prepare_account_deletion_wrapper(user_id)` (service_role, marks deletion `database_prepared`)

Three and only three valid outcomes:

1. **Deletion wins before reservation:** Flow A's `reserve_upload_session` returns `FK_FORBIDDEN` or `FK_WRONG_STATE`. No URL is issued. Flow B completes normally. `fail_upload_session` is not called (no session was created).

2. **Reservation wins; deletion quiesces before activation:** Flow A's `reserve_upload_session` succeeds (session created). Flow B's deletion quiesce runs and marks the session before `activate_upload_session` is called. `activate_upload_session` fails (session quiesced); Flow A calls `fail_upload_session` and returns 500 `FK_INTERNAL`. No URL is returned. Flow B deletion proceeds.

3. **Activation commits before quiescing:** `activate_upload_session` commits. URL is returned to client. Flow B's deletion must not reach completion (`database_prepared` marking complete) until the session's `storage_upload_expires_at` + a minimum 30-second buffer has elapsed. The live upload capability blocks deletion completion during its active window.

Any outcome where both a URL is returned and deletion reaches `database_prepared` within the URL's validity window is a failure.

**Race B — Concurrent Duplicate Reservations:**

Two simultaneous `upload-authorize` calls, same `case_id`, same `user_id`. Exactly one returns 200; the other returns 409 `FK_UPLOAD_IN_PROGRESS`. No other outcome is acceptable.

---

## Section 7 — Environment Variables

All read at runtime via `Deno.env.get()`. No literal values in source code or this document.

**Amendment B to Step 27 §8:** Step 27 recorded local S3 values as `access_key_id=stub` and `secret=ANON_KEY`. Gate 4 evidence (2026-08-13) established that actual local Supabase S3 credentials come from `supabase status -o env` as `S3_PROTOCOL_ACCESS_KEY_ID` and `S3_PROTOCOL_ACCESS_KEY_SECRET`. Step 27's stub values are superseded by Gate 4 evidence. Production credentials remain dashboard-generated and are never recorded here.

| Variable | Local source | Production |
|---|---|---|
| `SUPABASE_URL` | Auto-provisioned | Auto-provisioned |
| `SUPABASE_PUBLISHABLE_KEY` | Auto-provisioned (singular — not the legacy anon-key trio) | Auto-provisioned |
| `SUPABASE_SECRET_KEY` | Auto-provisioned (singular — not the legacy service-role trio) | Auto-provisioned |
| `S3_ENDPOINT` | `http://127.0.0.1:54321/storage/v1/s3` | `.storage.` hostname |
| `S3_REGION` | `local` | Dashboard value |
| `S3_ACCESS_KEY_ID` | From `supabase status -o env` → `S3_PROTOCOL_ACCESS_KEY_ID` | Dashboard-generated |
| `S3_SECRET_ACCESS_KEY` | From `supabase status -o env` → `S3_PROTOCOL_ACCESS_KEY_SECRET` | Dashboard secret |
| `S3_BUCKET` | `game-media` | `game-media` |

Local values set in `supabase/functions/.env` (git-ignored). Keys obtained from `supabase status -o env` at setup time; never committed.

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

`deno.lock` committed. All import specifiers pin exact versions.

### `config.toml`

```toml
[functions.upload-authorize]
verify_jwt = true
```

---

## Section 9 — Dependency Versions (Pinned)

All four versions confirmed from npm registry (2026-08-13):

| Import specifier | Pinned version | Purpose |
|---|---|---|
| `npm:@supabase/server@1.4.1` | **1.4.1** | JWT verification; auto-provisions `SUPABASE_PUBLISHABLE_KEY` / `SUPABASE_SECRET_KEY` |
| `npm:@supabase/supabase-js@2.112.3` | **2.112.3** | Supabase client |
| `npm:@aws-sdk/client-s3@3.1109.0` | **3.1109.0** | S3 client |
| `npm:@aws-sdk/s3-request-presigner@3.1109.0` | **3.1109.0** | Presigned URL generation |

These versions are confirmed prior to implementation. `deno.lock` will lock the full transitive graph after `deno cache`. If `deno.lock` records a different resolved version for any direct dependency, it must be reported before proceeding.

---

## Section 10 — Amendments Summary

| Amendment | Supersedes | Content |
|---|---|---|
| A — Session claim window | Step 24 §4.1 | 5 min → 15 min for `upload-authorize`; rationale in §5.3 |
| B — Local S3 credentials | Step 27 §8 | `stub`/`ANON_KEY` → actual `S3_PROTOCOL_*` from `supabase status -o env`; Gate 4 evidence |

---

## Section 11 — Approval Record

| Party | Status | Notes |
|---|---|---|
| Claude | Approved | Rev 3; all 5 Codex blockers resolved |
| Codex | Pending | — |
| Bill | Pending | — |

**This approval authorizes TypeScript implementation only. No cloud deployment authorized.**
