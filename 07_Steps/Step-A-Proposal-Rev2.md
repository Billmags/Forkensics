# Step A Proposal — Rev 2 — `upload-authorize` Edge Function

**Status:** DRAFT — Awaiting three-party approval (Claude + Codex + Bill)

**Supersedes:** Rev 1 (CHANGES REQUIRED — 8 blockers from Codex review)

**Governance gate:** All three parties must approve before any TypeScript is written.
Magic words: `APPROVED: Step A Rev 2 — upload-authorize`

**Binding contracts:**
- Step 27 Rev 5 (approved 2026-08-12) — §5.1, §6, §7, §8
- Step 24 Rev 10 (approved 2026-08-07) — §4.1, §5.1 test matrix
  - **Amendment:** §4.1 session claim window is superseded — see Section 5.3 below
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
- Any cloud deployment (no Supabase hosted operations)
- `upload-complete` or any other function
- `cron.ts` — deferred to the first function that requires it; not scaffolded under this step
- Gate 2B (hosted image-processing spike) — separate approval required

**Security constraints carried forward (immutable):**
- Secret key never in client code, never in the repo, never sent to Claude
- No cloud operations authorized under this step
- `private` schema never exposed through PostgREST
- `SUPABASE_DB_URL` direct connection NOT used by Edge Functions
- Raw JWT decoding prohibited; use `createSupabaseContext` from `npm:@supabase/server`
- `createSignedUploadUrl()` prohibited; only S3 Signature V4 with `ExpiresIn: 300`

---

## Section 2 — Pre-conditions

| Pre-condition | Status |
|---|---|
| Gate 5 (Deno + gitleaks) | ✅ Passed — Deno 2.9.5, gitleaks 8.30.1 |
| Gate 4 (local S3 preflight) | ✅ Passed — 2026-08-13 |
| Gate 3 (pg_cron/pg_net local) | ✅ Passed — 2026-08-13 |
| Gate 1 (V2 migration applied) | ✅ Satisfied — V2/V4 applied and regression-tested |
| Exact dependency versions pinned | ✅ Required before implementation begins — see Section 9 |
| Three-party approval of this proposal | ⏳ Pending |

Gate 2A is partially passed. `upload-authorize` is independent of image processing and may proceed.

---

## Section 3 — Directory Structure

```
supabase/functions/
  _shared/
    context.ts          ← getAuthContext wrapper
    profile.ts          ← checkActiveProfile, checkProfileExists
    s3.ts               ← presignPutUrl → { url, expiresAt }
    errors.ts           ← errorEnvelope, FkErrorCode, extractDbErrorCode
    log.ts              ← safeLog
    crypto.ts           ← sha256Hex, generateUploadToken
  upload-authorize/
    index.ts            ← function handler
    upload-authorize.test.ts
deno.lock               ← generated after scaffold; all versions pinned
```

`cron.ts` is deferred — not scaffolded under this step.

---

## Section 4 — Shared Module Specification

All shared modules: zero side effects on import. No global state. All environment variables read inside function calls via `Deno.env.get()`, never at module level.

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

// Returns a Response with JSON body { error: { code, message } }.
// All error responses include Cache-Control: no-store.
export function errorEnvelope(
  code: FkErrorCode,
  message: string,
  status: number,
): Response

// Extracts an FK_* error code from a database error via an anchored allowlist.
// Raw database error messages are never returned or logged.
// Returns null if the error message matches no allowlisted pattern.
export function extractDbErrorCode(err: unknown): FkErrorCode | null
```

**Allowlist for `extractDbErrorCode`:** inspects the error message for the anchored prefixes
`FK_NOT_FOUND`, `FK_WRONG_STATE`, `FK_UPLOAD_IN_PROGRESS`, `FK_FORBIDDEN`, `FK_INTERNAL`.
Any message not matching an allowlisted prefix returns `null` (caller maps to `FK_INTERNAL`).
Raw database messages never pass through to logs or responses.

### 4.2 `crypto.ts`

```typescript
// Generates a 32-byte cryptographically random token encoded as base64url.
// Uses Web Crypto API: crypto.getRandomValues(new Uint8Array(32)).
// Returns the base64url-encoded string (43 characters, ~256 bits of entropy).
export function generateUploadToken(): string

// Returns lowercase 64-char hex SHA-256 of data.
// The upload token is hashed as: sha256Hex(new TextEncoder().encode(base64urlToken))
export async function sha256Hex(data: Uint8Array): Promise<string>
```

**Entropy note:** `generateUploadToken()` produces 256 bits of entropy from `crypto.getRandomValues(new Uint8Array(32))`, satisfying Step 24's 256-bit requirement. The base64url-encoded string is passed to `sha256Hex` via `new TextEncoder().encode(token)` before storage. The raw token is returned to the client.

### 4.3 `log.ts`

```typescript
// Structured log with allowlist enforcement.
// Required fields: fn (function name), status (HTTP status code), duration_ms.
// Optional allowed fields: error_code (FK_* only), case_id (UUID only, not raw), request_id, user_id (UUID only).
// NEVER logged: paths, tokens, raw upload tokens, presigned URLs, secrets, keys, JWTs,
//               raw database error messages, content_type, declared_size_bytes.
export function safeLog(fields: {
  fn: string
  status: number
  duration_ms: number
  error_code?: FkErrorCode
  case_id?: string
  request_id?: string
  user_id?: string
}): void
```

`request_id` is extracted from the `X-Request-Id` header (or generated if absent) and threaded through the handler. `user_id` is the verified UUID from `ctx.userClaims.id`. `case_id` is the validated UUID from the request body. All three are included in every `safeLog` call.

### 4.4 `context.ts`

JWT verification via `@supabase/server`. Raw JWT decoding is prohibited.

Current `@supabase/server` uses auto-provisioned secrets: `SUPABASE_PUBLISHABLE_KEYS`, `SUPABASE_SECRET_KEYS`, and `SUPABASE_JWKS`. Local development uses singular fallbacks (`SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY`, `SUPABASE_JWT_SECRET`) automatically. The function does not reference these variables explicitly.

```typescript
// Wraps createSupabaseContext(req) from npm:@supabase/server.
// Returns verified context or a ready-to-return 401 Response.
// Never throws. Never decodes the JWT manually.
export async function getAuthContext(req: Request): Promise<
  | { ok: true;  ctx: AuthContext; error: null }
  | { ok: false; ctx: null;       error: Response }
>

export interface AuthContext {
  userClaims: { id: string }    // verified user UUID — from ctx, never decoded manually
  supabase:      SupabaseClient  // RLS-scoped (authenticated user)
  supabaseAdmin: SupabaseClient  // service_role (bypasses RLS)
}
```

### 4.5 `profile.ts`

Profile check returns a three-way result to prevent false 403s on infrastructure failures.

```typescript
export type ProfileCheckResult =
  | { status: 'ok' }
  | { status: 'forbidden' }   // profile absent, is_active=false, or onboarding_complete=false
  | { status: 'error' }       // query, configuration, or transport failure → caller returns 500

// Queries public.profiles (via authenticated RLS-scoped client).
// Returns 'forbidden' only on confirmed absence or inactive/incomplete status.
// Returns 'error' on any query or network failure.
export async function checkActiveProfile(
  supabase: SupabaseClient,
  userId: string,
): Promise<ProfileCheckResult>

// Returns ok:true if profile row exists (any is_active / onboarding_complete).
export async function checkProfileExists(
  supabase: SupabaseClient,
  userId: string,
): Promise<{ ok: boolean }>
```

### 4.6 `s3.ts`

```typescript
// Signs a presigned PUT URL and returns both the URL and the actual expiry
// derived from the signed URL's X-Amz-Date and X-Amz-Expires parameters.
//
// Reads S3_ENDPOINT, S3_REGION, S3_ACCESS_KEY_ID, S3_SECRET_ACCESS_KEY, S3_BUCKET
// from Deno.env at call time. Never logs URL or credentials.
//
// expiresIn MUST be 300 (literal type — enforced at the call site).
// forcePathStyle: true (required for Supabase Storage).
// createSignedUploadUrl() is prohibited.
//
// expiresAt is parsed from the signed URL's X-Amz-Date (YYYYMMDDTHHmmssZ)
// + X-Amz-Expires (seconds). This is the authoritative expiry — not a local
// clock estimate — and is used as p_actual_storage_upload_expires_at.
//
// Throws on any signing failure (caller catches and calls fail_upload_session).
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

{
  "case_id": "<uuid>",
  "content_type": "image/jpeg" | "image/webp",
  "declared_size_bytes": <integer, 1–10485760>
}
```

**Allowed content types (enforced by V2 DB constraint):**
- `image/jpeg`
- `image/webp`

**Response 200:**
```json
{
  "presigned_url": "<S3 presigned PUT URL>",
  "upload_token": "<raw base64url token>",
  "expires_at": "<ISO 8601 — URL expiry, from signed URL's X-Amz-Date + X-Amz-Expires>"
}
```

**Response headers (200 and all error responses):**
```
Cache-Control: no-store
```

`session_id` is internal and is never present in any response.

### 5.2 `config.toml` entry

```toml
[functions.upload-authorize]
verify_jwt = true
```

This ensures the Supabase gateway rejects malformed or missing JWTs before the handler runs. T-A-07–09 (auth failure tests) accept HTTP 401 with either the gateway error body or the application `FK_UNAUTHENTICATED` envelope, since gateway rejection may short-circuit the handler.

### 5.3 Upload Token Pattern (Amendment to Step 24 §4.1)

**Step 24 §4.1 required 256 bits of token entropy.** This step satisfies that requirement using `crypto.getRandomValues(new Uint8Array(32))` (256 bits) encoded as base64url. The alternative from Step 24 (`crypto.randomUUID()`, ~122 bits) is not used.

**Step 24 §4.1 specified a 5-minute session claim window.** This step amends that to a **15-minute session claim window** (`p_client_expires_at = now() + 900s`). The rationale: the claim window and the presigned URL expiry serve different purposes. The URL expires in 5 minutes (enforced by S3); the session claim window gives the client time to complete the upload and call `upload-complete` even if upload takes the full 5 minutes. 15 minutes is the minimum window that reliably prevents spurious `FK_UPLOAD_IN_PROGRESS` errors when an upload is slow. This amendment is recorded here and must be referenced in any future Step 24 amendment log.

**Token generation sequence:**
1. `rawToken = generateUploadToken()` → 32-byte `getRandomValues` → base64url → 43-char string
2. `tokenHash = await sha256Hex(new TextEncoder().encode(rawToken))` → 64-char hex
3. `reserve_upload_session(..., tokenHash, ...)` — hash stored, raw token never stored
4. Return `rawToken` to client as `upload_token`

### 5.4 Session Timing

| Window | Value | Derivation |
|---|---|---|
| `p_client_expires_at` | `now() + 900s` (15 min) | Handler clock at reservation time |
| `ExpiresIn` | `300s` (S3 parameter — literal) | Constant; never changed |
| `expiresAt` (returned from `presignPutUrl`) | `X-Amz-Date + X-Amz-Expires` | Parsed from signed URL — authoritative |
| `p_actual_storage_upload_expires_at` | `expiresAt.toISOString()` | Identical to response `expires_at` |
| Response `expires_at` | `expiresAt.toISOString()` | Identical to DB `storage_upload_expires_at` |

**Invariant:** the `expires_at` in the response, the `storage_upload_expires_at` in the DB, and the `X-Amz-Expires` encoded in the presigned URL are all identical. There are no local clock estimates.

### 5.5 Dependency Injection

All external calls are injectable via a `Deps` parameter to enable deterministic test forcing. Default implementations are the real ones; tests pass stubs.

```typescript
interface Deps {
  generateToken: () => string                                    // default: generateUploadToken
  sha256:        (data: Uint8Array) => Promise<string>          // default: sha256Hex
  presign:       (path: string, expiresIn: 300) => Promise<{ url: string; expiresAt: Date }>
  now:           () => Date                                      // default: () => new Date()
  // RPC calls go through the supabaseAdmin client from context — no separate injectable needed
}
```

### 5.6 Implementation Sequence

```
Step 0.  Extract request_id from X-Request-Id header (or generate UUID if absent).
          Start timer (performance.now()).

Step 1.  getAuthContext(req)
          → error: safeLog({ fn, status: 401, duration_ms, error_code: 'FK_UNAUTHENTICATED', request_id })
                   return error (errorEnvelope with Cache-Control: no-store)

Step 2.  checkActiveProfile(ctx.supabase, ctx.userClaims.id)
          → 'forbidden': safeLog({ fn, status: 403, error_code: 'FK_FORBIDDEN', request_id, user_id })
                         return errorEnvelope('FK_FORBIDDEN', ..., 403)
          → 'error':     safeLog({ fn, status: 500, error_code: 'FK_INTERNAL', request_id, user_id })
                         return errorEnvelope('FK_INTERNAL', ..., 500)

Step 3.  Parse and validate request body (JSON).
          a. case_id         — required, valid UUID format; else 400 FK_INVALID_INPUT
          b. content_type    — required, one of ['image/jpeg','image/webp']; else 400 FK_INVALID_CONTENT_TYPE
          c. declared_size_bytes — required, integer ≥ 1 ≤ 10,485,760
             missing or ≤ 0 → 400 FK_INVALID_INPUT
             > 10,485,760   → 400 FK_FILE_TOO_LARGE
          d. non-JSON body  → 400 FK_INVALID_INPUT
          All validation errors: safeLog({ fn, status: 4xx, error_code, request_id }) then return.

Step 4.  Generate token and session expiry:
          rawToken   = deps.generateToken()
          tokenHash  = await deps.sha256(new TextEncoder().encode(rawToken))
          sessionExpiry = new Date(deps.now().getTime() + 900_000)   // 15 min

Step 5.  reserve_upload_session via ctx.supabaseAdmin.rpc:
          reserve_upload_session({
            p_case_id:           caseId,
            p_uploader_id:       ctx.userClaims.id,
            p_token_hash:        tokenHash,
            p_content_type:      contentType,
            p_declared_size:     declaredSizeBytes,
            p_client_expires_at: sessionExpiry.toISOString(),
          })
          Returns: { session_id, original_storage_path, display_storage_path }

          Error mapping (extractDbErrorCode first; null → FK_INTERNAL):
          FK_NOT_FOUND          → 404
          FK_WRONG_STATE        → 409
          FK_UPLOAD_IN_PROGRESS → 409
          FK_FORBIDDEN          → 403
          FK_INTERNAL / null    → 500

Step 6.  Sign presigned PUT URL:
          { url: presignedUrl, expiresAt: urlExpiresAt } = await deps.presign(originalStoragePath, 300)
          → throws: goto Step 6-err

Step 6-err (presign failure):
          await ctx.supabaseAdmin.rpc('fail_upload_session', {
            p_session_id: sessionId,
            p_error_code: 'FK_INTERNAL',
          }).catch(() => { /* best-effort; log failure swallowed */ })
          safeLog({ fn, status: 500, error_code: 'FK_INTERNAL', request_id, user_id, case_id })
          return errorEnvelope('FK_INTERNAL', ..., 500)

Step 7.  activate_upload_session via ctx.supabaseAdmin.rpc:
          activate_upload_session({
            p_session_id:                      sessionId,
            p_actual_storage_upload_expires_at: urlExpiresAt.toISOString(),
          })
          → throws: goto Step 7-err

Step 7-err (activate failure):
          await ctx.supabaseAdmin.rpc('fail_upload_session', {
            p_session_id: sessionId,
            p_error_code: 'FK_INTERNAL',
          }).catch(() => { /* best-effort */ })
          safeLog({ fn, status: 500, error_code: 'FK_INTERNAL', request_id, user_id, case_id })
          return errorEnvelope('FK_INTERNAL', ..., 500)
          // presignedUrl is discarded — not returned to client

Step 8.  safeLog({ fn, status: 200, duration_ms, request_id, user_id, case_id })
          return new Response(JSON.stringify({
            presigned_url: presignedUrl,
            upload_token:  rawToken,
            expires_at:    urlExpiresAt.toISOString(),
          }), {
            status: 200,
            headers: {
              'Content-Type': 'application/json',
              'Cache-Control': 'no-store',
            },
          })
```

**Invariant:** the presigned URL is returned to the client only after `activate_upload_session` commits. If activation fails, the URL is discarded and the session is failed.

### 5.7 Error Response Table

| Condition | HTTP | Code |
|---|---|---|
| Missing or invalid JWT (gateway or handler) | 401 | `FK_UNAUTHENTICATED` |
| Profile not active / onboarding incomplete / absent | 403 | `FK_FORBIDDEN` |
| Profile check query/transport failure | 500 | `FK_INTERNAL` |
| Invalid/missing `case_id` | 400 | `FK_INVALID_INPUT` |
| `content_type` not in allowlist | 400 | `FK_INVALID_CONTENT_TYPE` |
| `declared_size_bytes` missing or ≤ 0 | 400 | `FK_INVALID_INPUT` |
| `declared_size_bytes` > 10,485,760 | 400 | `FK_FILE_TOO_LARGE` |
| Non-JSON body | 400 | `FK_INVALID_INPUT` |
| Case not found or caller is not poster | 404 | `FK_NOT_FOUND` |
| Case not in draft state | 409 | `FK_WRONG_STATE` |
| Active upload session already exists | 409 | `FK_UPLOAD_IN_PROGRESS` |
| Uploader has active deletion record | 403 | `FK_FORBIDDEN` |
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

`deno check`, `deno fmt --check`, and `deno lint` are run over all scaffolded files:
```sh
deno check \
  supabase/functions/_shared/context.ts \
  supabase/functions/_shared/profile.ts \
  supabase/functions/_shared/s3.ts \
  supabase/functions/_shared/errors.ts \
  supabase/functions/_shared/log.ts \
  supabase/functions/_shared/crypto.ts \
  supabase/functions/upload-authorize/index.ts \
  supabase/functions/upload-authorize/upload-authorize.test.ts

deno fmt --check supabase/functions/
deno lint supabase/functions/
```

**Private-schema evidence harness:** T-A-04 and T-A-06 verify fields in `private.upload_sessions`, which is not accessible through PostgREST. These tests use a local-only `psql` side-channel:
```sh
PGPASSWORD=$(supabase status -o env | grep DB_PASSWORD | cut -d= -f2) \
  psql "postgresql://postgres@127.0.0.1:54322/postgres" \
  -c "SELECT token_hash, status, storage_upload_expires_at FROM private.upload_sessions WHERE session_id = '<uuid>';"
```
This side-channel is local evidence only; it uses no PostgREST and is never present in Edge Function code.

**Dependency stubs (injected via `Deps`):**
- `fakeClock` — returns a fixed `Date` for reproducible expiry calculations
- `fakeTokenGen` — returns a known base64url string for hash verification
- `presignSuccess` — returns `{ url: 'https://s3.test/...', expiresAt: fixedDate }`
- `presignFailure` — throws `new Error('S3 connection refused')`
- `activateFailure` — stubs `supabaseAdmin.rpc` to throw on `activate_upload_session`

### 6.2 Happy Path

| # | Description | Expected |
|---|---|---|
| T-A-01 | Valid JPEG request, draft case, poster identity, active profile | 200; `presigned_url`, `upload_token`, `expires_at` present; `session_id` absent; `Cache-Control: no-store` header present |
| T-A-02 | Valid WebP request (same conditions) | 200; same shape |
| T-A-03 | `expires_at` in response equals `X-Amz-Date + X-Amz-Expires` from signed URL (not a clock estimate) | Pass — values identical |
| T-A-04 | SHA-256 of response `upload_token` matches `upload_token_hash` in `private.upload_sessions` (psql side-channel) | Pass |
| T-A-05 | `session_id` is absent from the 200 response body | Pass |
| T-A-06 | After 200, `private.upload_sessions.status = 'pending'` and `storage_upload_expires_at = urlExpiresAt` (psql side-channel) | Pass |
| T-A-07 | Response `expires_at`, DB `storage_upload_expires_at`, and signed URL expiry are identical | Pass |

### 6.3 Authentication and Profile

| # | Description | Expected |
|---|---|---|
| T-A-08 | Missing `Authorization` header | HTTP 401; body is gateway error or `FK_UNAUTHENTICATED` envelope (both accepted) |
| T-A-09 | Malformed JWT (invalid signature) | HTTP 401; gateway or application 401 accepted |
| T-A-10 | Expired JWT | HTTP 401; gateway or application 401 accepted |
| T-A-11 | Valid JWT but profile has `is_active = false` | 403 `FK_FORBIDDEN` |
| T-A-12 | Valid JWT but profile has `onboarding_complete = false` | 403 `FK_FORBIDDEN` |
| T-A-13 | Valid JWT but profile row does not exist | 403 `FK_FORBIDDEN` |
| T-A-14 | Valid JWT; `checkActiveProfile` stub returns `'error'` (transport failure) | 500 `FK_INTERNAL` |

### 6.4 Request Validation

| # | Description | Expected |
|---|---|---|
| T-A-15 | Missing `case_id` | 400 `FK_INVALID_INPUT` |
| T-A-16 | `case_id` is not a valid UUID | 400 `FK_INVALID_INPUT` |
| T-A-17 | `content_type = "image/png"` | 400 `FK_INVALID_CONTENT_TYPE` |
| T-A-18 | `content_type = "image/heic"` | 400 `FK_INVALID_CONTENT_TYPE` |
| T-A-19 | Missing `content_type` | 400 `FK_INVALID_CONTENT_TYPE` |
| T-A-20 | Missing `declared_size_bytes` | 400 `FK_INVALID_INPUT` |
| T-A-21 | `declared_size_bytes = 0` | 400 `FK_INVALID_INPUT` |
| T-A-22 | `declared_size_bytes = -1` | 400 `FK_INVALID_INPUT` |
| T-A-23 | `declared_size_bytes = 10,485,760` (at limit) | 200 (accepted by DB constraint) |
| T-A-24 | `declared_size_bytes = 10,485,761` (one over) | 400 `FK_FILE_TOO_LARGE` |
| T-A-25 | Non-JSON body | 400 `FK_INVALID_INPUT` |

### 6.5 DB-Driven Errors

| # | Description | Expected |
|---|---|---|
| T-A-26 | `case_id` does not exist | 404 `FK_NOT_FOUND` |
| T-A-27 | `case_id` exists; caller is not the poster | 404 `FK_NOT_FOUND` |
| T-A-28 | Case exists, poster, but state is `launched` | 409 `FK_WRONG_STATE` |
| T-A-29 | Case exists, draft, active session `status = 'pending'` | 409 `FK_UPLOAD_IN_PROGRESS` |
| T-A-30 | Case exists, draft, active session `status = 'processing'` | 409 `FK_UPLOAD_IN_PROGRESS` |
| T-A-31 | Uploader has `deletion_log` row with `status = 'database_prepared'` | 403 `FK_FORBIDDEN` |

### 6.6 Presign and Activate Failures

| # | Description | Expected |
|---|---|---|
| T-A-32 | `presign` stub throws | 500 `FK_INTERNAL`; DB shows session `status = 'failed'`, `failed_reason = 'FK_INTERNAL'` (psql); no URL returned |
| T-A-33 | `activate_upload_session` stub throws | 500 `FK_INTERNAL`; session `status = 'failed'` (psql); presigned URL NOT present in response |

### 6.7 Mandatory Step 24 Rev 10 §5.1 Race Tests (V4 Substitutions Applied)

Identifier substitutions: `challenge_id → case_id`, `public.challenges → public.cases`, `state = 'active' → state = 'launched'`.

**Race A — Reservation vs. deletion concurrency:**

Two concurrent goroutines: `reserve_upload_session(case_id, user_id, ...)` and `prepare_account_deletion_wrapper(user_id)` for the same user.

Expected outcomes (exactly one of):
- Deletion wins: reservation returns `FK_WRONG_STATE` or `FK_FORBIDDEN`; no URL is issued.
- Reservation wins: `activate_upload_session` succeeds; URL is returned. Deletion then attempts to quiesce the active upload session and is blocked by the live capability until expiry.

A result where both succeed and both a URL is issued and a deletion proceeds concurrently is a failure.

**Race B — Duplicate reservations:**

Two concurrent `upload-authorize` calls for the same `case_id` and same user. Expected: exactly one returns 200; the other returns 409 `FK_UPLOAD_IN_PROGRESS`. No other outcome is acceptable.

---

## Section 7 — Environment Variables

All read at runtime via `Deno.env.get()`. Never logged, never hardcoded, no literal values in source code.

| Variable | Local source | Production source |
|---|---|---|
| `SUPABASE_URL` | Auto-provisioned by `supabase functions serve` | Auto-provisioned |
| `SUPABASE_PUBLISHABLE_KEYS` | Auto-provisioned (local fallback: `SUPABASE_ANON_KEY`) | Auto-provisioned |
| `SUPABASE_SECRET_KEYS` | Auto-provisioned (local fallback: `SUPABASE_SERVICE_ROLE_KEY`) | Auto-provisioned |
| `SUPABASE_JWKS` | Auto-provisioned (local fallback: `SUPABASE_JWT_SECRET`) | Auto-provisioned |
| `S3_ENDPOINT` | `http://127.0.0.1:54321/storage/v1/s3` | `.storage.` hostname |
| `S3_REGION` | `local` | Dashboard value |
| `S3_ACCESS_KEY_ID` | `$(supabase status -o env \| grep S3_PROTOCOL_ACCESS_KEY_ID \| cut -d= -f2)` | Dashboard-generated |
| `S3_SECRET_ACCESS_KEY` | `$(supabase status -o env \| grep S3_PROTOCOL_ACCESS_KEY_SECRET \| cut -d= -f2)` | Dashboard secret |
| `S3_BUCKET` | `game-media` | `game-media` |

Local values set in `supabase/functions/.env` (git-ignored, never committed). `S3_ACCESS_KEY_ID` and `S3_SECRET_ACCESS_KEY` are obtained from `supabase status -o env` at runtime; no literal key values appear in any source file or proposal document.

---

## Section 8 — Scaffold and Quality Gates

### Gate 6: First-function scaffold

After scaffolding, before any tests:
```sh
deno check supabase/functions/_shared/*.ts supabase/functions/upload-authorize/*.ts
deno fmt --check supabase/functions/
deno lint supabase/functions/
gitleaks detect --source . --no-git
```

All must pass with zero output before implementation proceeds.

### deno.lock generation

After scaffold is clean:
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

`deno.lock` is committed. All import specifiers pin exact versions.

### `config.toml` addition

```toml
[functions.upload-authorize]
verify_jwt = true
```

---

## Section 9 — Dependency Versions

Exact versions must be resolved and recorded here before implementation begins. This section is a placeholder to be filled by running `deno cache` against each import and recording the pinned version from `deno.lock`.

| Import specifier | Pinned version (to fill at scaffold time) | Purpose |
|---|---|---|
| `npm:@supabase/server@X.Y.Z` | TBD | JWT verification; auto-provisions env secrets |
| `npm:@supabase/supabase-js@X.Y.Z` | TBD | Supabase client |
| `npm:@aws-sdk/client-s3@X.Y.Z` | TBD | S3 client |
| `npm:@aws-sdk/s3-request-presigner@X.Y.Z` | TBD | Presigned URL generation |

**Protocol:** run `deno cache --lock=deno.lock <imports>`, read resolved versions from `deno.lock`, record exact version strings above. No package is used at an unresolved or floating version.

---

## Section 10 — Open Questions Resolved

| Item | Resolution |
|---|---|
| Token entropy | 256 bits: `crypto.getRandomValues(new Uint8Array(32))` → base64url |
| URL expiry source | Parsed from signed URL's `X-Amz-Date + X-Amz-Expires` — not local clock |
| 15-minute session window | Recorded as explicit amendment superseding Step 24 §4.1 |
| Race A deletion outcome | Deletion wins → `FK_WRONG_STATE` or `FK_FORBIDDEN`; reservation wins → deletion quiesces after capability expires |
| V2 SHA | `0f9adbb732f671008629854398fb7d5c3962a315338e3eff08b3a45eccea161a` |
| V4 SHA | `0eb78c66878df50f22278fb36f2b089d3f2b81ded2f550a945e9d0dd55dd0f66` |
| S3 key in proposal | Removed — obtained at runtime only |
| `@supabase/server` env contract | Auto-provisioned `SUPABASE_PUBLISHABLE_KEYS`/`SECRET_KEYS`/`JWKS`; no explicit env references |
| Profile check ambiguity | Three-way `ProfileCheckResult` distinguishes absent/inactive from infrastructure failure |
| Private schema test access | Local `psql` side-channel for T-A-04, T-A-06, T-A-32, T-A-33 |
| JWT gateway behavior | T-A-08–10 accept gateway or application 401 |
| `cron.ts` | Deferred; not scaffolded under this step |
| `safeLog` fields | `fn`, `status`, `duration_ms`, `request_id`, `user_id`, `case_id` |
| `Cache-Control` | `no-store` on all responses (200 and errors) |

---

## Section 11 — Approval Record

| Party | Status | Notes |
|---|---|---|
| Claude | Approved | Rev 2 authored incorporating all 8 Codex blockers |
| Codex | Pending | — |
| Bill | Pending | — |

**This approval authorizes TypeScript implementation only. No cloud deployment authorized.**
