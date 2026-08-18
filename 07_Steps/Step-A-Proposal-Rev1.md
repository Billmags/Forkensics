# Step A Proposal — Rev 1 — `upload-authorize` Edge Function

**Status:** DRAFT — Awaiting three-party approval (Claude + Codex + Bill)

**Governance gate:** All three parties must approve before any TypeScript is written.
Magic words: `APPROVED: Step A Rev 1 — upload-authorize`

**Binding contracts:**
- Step 27 Rev 5 (approved 2026-08-12) — §5.1, §6, §7, §8
- Step 24 Rev 10 — §4.1, §5.1 test matrix
- V2 migration (SHA-256: `00892952ce72552995491dbb96ac5ac6394f1db3ea590a68620fb48349e2abd1`)
- V4 migration (applied; `public.challenges → public.cases`; `p_challenge_id → p_case_id`)

---

## Section 1 — Scope

This step covers:
1. Scaffolding of `supabase/functions/_shared/` (shared module — first use)
2. Scaffolding and implementation of `supabase/functions/upload-authorize/index.ts`
3. Test file: `supabase/functions/upload-authorize/upload-authorize.test.ts`
4. `deno.lock` generation (Gate 6 — first function)
5. `deno check`, `deno fmt --check`, `deno lint`, `gitleaks detect` all passing

This step does **not** cover:
- Any cloud deployment (no Supabase hosted operations)
- `upload-complete` or any other function
- Gate 2B (hosted image-processing spike) — separate approval required

**Security constraints carried forward (immutable):**
- Secret key never in client code, never in the repo, never sent to Claude
- No cloud operations authorized under this step
- `private` schema never exposed through PostgREST
- `SUPABASE_DB_URL` direct connection NOT used by Edge Functions
- Raw JWT decoding prohibited; use `createSupabaseContext(req, { auth: 'user' })`
- `createSignedUploadUrl()` prohibited; only S3 Signature V4 with `ExpiresIn: 300`

---

## Section 2 — Pre-conditions

All must be true before implementation begins:

| Pre-condition | Status |
|---|---|
| Gate 5 (Deno + gitleaks) | ✅ Passed — Deno 2.9.5, gitleaks 8.30.1 |
| Gate 4 (local S3 preflight) | ✅ Passed — 2026-08-13 |
| Gate 3 (pg_cron/pg_net local) | ✅ Passed — 2026-08-13 |
| Gate 1 (V2 migration applied) | ✅ Satisfied — V2/V4 applied and regression-tested |
| Three-party approval of this proposal | ⏳ Pending |

Gate 2A is partially passed. `upload-authorize` is independent of image processing and may proceed.

---

## Section 3 — Directory Structure

```
supabase/functions/
  _shared/
    context.ts          ← getAuthContext, withSupabase wrappers
    profile.ts          ← checkActiveProfile, checkProfileExists
    cron.ts             ← validateCronSecret
    s3.ts               ← presignPutUrl
    errors.ts           ← errorEnvelope, FK error codes
    log.ts              ← safeLog
    crypto.ts           ← sha256Hex
  upload-authorize/
    index.ts            ← function handler
    upload-authorize.test.ts
deno.lock               ← generated after first scaffold (Gate 6)
```

---

## Section 4 — Shared Module Specification

**Location:** `supabase/functions/_shared/`

All shared modules: zero side effects on import. No global state. All environment variables read inside function calls via `Deno.env.get()`, never at module level.

### 4.1 `errors.ts`

```typescript
// Error codes used across all Edge Functions.
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
export function errorEnvelope(
  code: FkErrorCode,
  message: string,
  status: number,
): Response
```

### 4.2 `crypto.ts`

```typescript
// Returns lowercase 64-char hex SHA-256 of data.
// Uses Web Crypto API (available in Deno Edge Runtime).
export async function sha256Hex(data: Uint8Array): Promise<string>
```

### 4.3 `log.ts`

```typescript
// Structured log with allowlist enforcement.
// Never logs: paths, tokens, URLs, presigned URLs, secrets, keys, JWTs.
// Allowed fields: function name, status code, error code, duration_ms, case_id (uuid only).
export function safeLog(fields: Record<string, string | number | boolean>): void
```

### 4.4 `context.ts`

JWT verification via `@supabase/server`. Raw JWT decoding is prohibited.

```typescript
import { createSupabaseContext } from 'npm:@supabase/server'

// Wraps createSupabaseContext(req, { auth: 'user' }).
// Returns verified context or error. Never throws.
export async function getAuthContext(req: Request): Promise<
  | { ok: true;  ctx: AuthContext; error: null }
  | { ok: false; ctx: null;       error: Response }
>

// ctx.userClaims.id  — verified user UUID (never decode JWT manually)
// ctx.supabase       — RLS-scoped client (authenticated user)
// ctx.supabaseAdmin  — service_role client (bypasses RLS)
export interface AuthContext {
  userClaims: { id: string }
  supabase:   SupabaseClient
  supabaseAdmin: SupabaseClient
}
```

### 4.5 `profile.ts`

```typescript
// Returns ok:true if profile exists with is_active=true AND onboarding_complete=true.
// Used by upload-authorize, upload-complete, media-serve.
export async function checkActiveProfile(
  supabase: SupabaseClient,
  userId: string,
): Promise<{ ok: boolean }>

// Returns ok:true if profile row exists (any is_active / onboarding_complete).
// Used by account-delete-complete (deletion carveout).
export async function checkProfileExists(
  supabase: SupabaseClient,
  userId: string,
): Promise<{ ok: boolean }>
```

### 4.6 `s3.ts`

```typescript
// Signs a presigned PUT URL using S3 Signature V4.
// Reads S3_ENDPOINT, S3_REGION, S3_ACCESS_KEY_ID, S3_SECRET_ACCESS_KEY, S3_BUCKET
// from Deno.env. Never logs the URL or credentials.
//
// ONLY permitted value for expiresIn: 300.
// forcePathStyle: true (required for Supabase Storage).
// createSignedUploadUrl() is prohibited.
//
// Returns the presigned URL string.
// Throws on any signing failure (caller must catch and fail gracefully).
export async function presignPutUrl(
  objectPath: string,  // path within S3_BUCKET; e.g. "cases/uuid/originals/uuid"
  expiresIn: 300,      // literal 300 — type enforced; no other value accepted
): Promise<string>
```

### 4.7 `cron.ts`

```typescript
// Reads X-Forkensics-Cron-Secret header; compares to CRON_SECRET env var
// using constant-time comparison (timingSafeEqual).
// Returns { ok: true } or { ok: false }.
export function validateCronSecret(req: Request): { ok: boolean }
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
  "upload_token": "<raw token string>",
  "expires_at": "<ISO 8601 timestamp — URL expiry>"
}
```

`session_id` is internal and is never present in the response.

### 5.2 Upload Token Pattern

The upload token is a secret shared between the Edge Function and the client. Only its SHA-256 hash is stored in the database.

1. Edge Function generates a raw token: `crypto.randomUUID()` (128 bits of entropy; UUID v4 format).
2. Computes `tokenHash = await sha256Hex(new TextEncoder().encode(rawToken))` (64-char lowercase hex).
3. Passes `tokenHash` to `reserve_upload_session` as `p_token_hash`. The raw token is never stored in the DB.
4. Returns `rawToken` to the client as `upload_token`.
5. `upload-complete` receives `rawToken` from the client, recomputes the hash, and calls `resolve_upload_session(tokenHash, userId)`.

### 5.3 Session Timing

| Window | Value | Purpose |
|---|---|---|
| `p_client_expires_at` | `now() + 900s` (15 min) | Session claim window — how long the client has to call `upload-complete` |
| `ExpiresIn` for presigned URL | `300s` (5 min) | S3 URL validity window |
| `p_actual_storage_upload_expires_at` | computed from URL signing time | Passed to `activate_upload_session`; must not exceed session `expires_at` |

The `expires_at` field in the response is the presigned URL expiry timestamp (NOT the session claim window).

### 5.4 Implementation Sequence

```
Step 1.  getAuthContext(req)
          → error: return errorEnvelope('FK_UNAUTHENTICATED', ..., 401)

Step 2.  checkActiveProfile(ctx.supabase, ctx.userClaims.id)
          → !ok: return errorEnvelope('FK_FORBIDDEN', ..., 403)

Step 3.  Parse and validate request body (JSON):
          a. case_id         — required, valid UUID format; else 400 FK_INVALID_INPUT
          b. content_type    — required, one of ['image/jpeg','image/webp']; else 400 FK_INVALID_CONTENT_TYPE
          c. declared_size_bytes — required, integer, 1 ≤ n ≤ 10,485,760; else 400 FK_FILE_TOO_LARGE
             (declared_size_bytes = 0 or missing → 400 FK_INVALID_INPUT)
             (declared_size_bytes > 10,485,760 → 400 FK_FILE_TOO_LARGE)

Step 4.  Generate upload token and hash:
          rawToken  = crypto.randomUUID()
          tokenHash = await sha256Hex(new TextEncoder().encode(rawToken))
          sessionExpiry = new Date(Date.now() + 900_000)   // now + 15 min

Step 5.  Call reserve_upload_session via service_role client (ctx.supabaseAdmin.rpc):
          reserve_upload_session(
            p_case_id:           caseId,
            p_uploader_id:       ctx.userClaims.id,
            p_token_hash:        tokenHash,
            p_content_type:      contentType,
            p_declared_size:     declaredSizeBytes,
            p_client_expires_at: sessionExpiry.toISOString(),
          )
          Returns: { session_id, original_storage_path, display_storage_path }

          Error mapping (inspect error message for FK_* prefix):
          FK_NOT_FOUND         → 404 FK_NOT_FOUND  (case not found, or caller is not poster)
          FK_WRONG_STATE       → 409 FK_WRONG_STATE (case not in draft state)
          FK_UPLOAD_IN_PROGRESS→ 409 FK_UPLOAD_IN_PROGRESS (active session exists)
          FK_FORBIDDEN         → 403 FK_FORBIDDEN  (uploader has database_prepared deletion record)
          any other error      → 500 FK_INTERNAL

Step 6.  Sign presigned PUT URL:
          urlExpiresAt = new Date(Date.now() + 300_000)   // now + 5 min (300s)
          presignedUrl = await presignPutUrl(originalStoragePath, 300)
          → throws: goto Step 6-err

Step 6-err (presign failure):
          await ctx.supabaseAdmin.rpc('fail_upload_session', {
            p_session_id: sessionId,
            p_error_code: 'FK_INTERNAL',
          })
          // fail_upload_session failure: log, swallow (best-effort cleanup only)
          return errorEnvelope('FK_INTERNAL', ..., 500)

Step 7.  Call activate_upload_session via service_role client:
          activate_upload_session(
            p_session_id:                      sessionId,
            p_actual_storage_upload_expires_at: urlExpiresAt.toISOString(),
          )
          → throws: goto Step 7-err

Step 7-err (activate failure):
          // URL was signed but not activated — client must not receive the URL.
          await ctx.supabaseAdmin.rpc('fail_upload_session', {
            p_session_id: sessionId,
            p_error_code: 'FK_INTERNAL',
          })
          return errorEnvelope('FK_INTERNAL', ..., 500)

Step 8.  Return 200:
          {
            presigned_url: presignedUrl,
            upload_token:  rawToken,
            expires_at:    urlExpiresAt.toISOString(),
          }
```

**Invariant:** The presigned URL is returned to the client only after `activate_upload_session` has committed. If activation fails, the URL is discarded and the session is failed.

### 5.5 Error Response Table

| Condition | HTTP | Code |
|---|---|---|
| Missing or invalid JWT | 401 | `FK_UNAUTHENTICATED` |
| Profile not active / onboarding incomplete | 403 | `FK_FORBIDDEN` |
| Invalid/missing `case_id` | 400 | `FK_INVALID_INPUT` |
| `content_type` not in allowlist | 400 | `FK_INVALID_CONTENT_TYPE` |
| `declared_size_bytes` > 10,485,760 | 400 | `FK_FILE_TOO_LARGE` |
| `declared_size_bytes` missing or ≤ 0 | 400 | `FK_INVALID_INPUT` |
| Case not found or caller is not poster | 404 | `FK_NOT_FOUND` |
| Case not in draft state | 409 | `FK_WRONG_STATE` |
| Active upload session already exists | 409 | `FK_UPLOAD_IN_PROGRESS` |
| Uploader has active deletion record | 403 | `FK_FORBIDDEN` |
| Presign failure or activate failure | 500 | `FK_INTERNAL` |

---

## Section 6 — Test Matrix

### 6.1 Happy Path

| # | Description | Expected |
|---|---|---|
| T-A-01 | Valid JPEG request, draft case, poster identity, active profile | 200; `presigned_url`, `upload_token`, `expires_at` in response; `session_id` absent |
| T-A-02 | Valid WebP request (same conditions) | 200; same shape |
| T-A-03 | `expires_at` in response is approximately `now + 300s` (within 5s tolerance) | Pass |
| T-A-04 | `upload_token` SHA-256 matches `upload_token_hash` in `private.upload_sessions` | Pass (verify via direct DB query in test) |
| T-A-05 | `session_id` is NOT present in the 200 response body | Pass |
| T-A-06 | After 200, `private.upload_sessions.status = 'pending'` and `storage_upload_expires_at IS NOT NULL` | Pass |

### 6.2 Authentication and Profile

| # | Description | Expected |
|---|---|---|
| T-A-07 | Missing `Authorization` header | 401 `FK_UNAUTHENTICATED` |
| T-A-08 | Malformed JWT (invalid signature) | 401 `FK_UNAUTHENTICATED` |
| T-A-09 | Expired JWT | 401 `FK_UNAUTHENTICATED` |
| T-A-10 | Valid JWT but profile has `is_active = false` | 403 `FK_FORBIDDEN` |
| T-A-11 | Valid JWT but profile has `onboarding_complete = false` | 403 `FK_FORBIDDEN` |
| T-A-12 | Valid JWT but profile row does not exist | 403 `FK_FORBIDDEN` |

### 6.3 Request Validation

| # | Description | Expected |
|---|---|---|
| T-A-13 | Missing `case_id` | 400 `FK_INVALID_INPUT` |
| T-A-14 | `case_id` is not a valid UUID | 400 `FK_INVALID_INPUT` |
| T-A-15 | `content_type = "image/png"` (not in allowlist) | 400 `FK_INVALID_CONTENT_TYPE` |
| T-A-16 | `content_type = "image/heic"` (not in allowlist) | 400 `FK_INVALID_CONTENT_TYPE` |
| T-A-17 | Missing `content_type` | 400 `FK_INVALID_CONTENT_TYPE` |
| T-A-18 | Missing `declared_size_bytes` | 400 `FK_INVALID_INPUT` |
| T-A-19 | `declared_size_bytes = 0` | 400 `FK_INVALID_INPUT` |
| T-A-20 | `declared_size_bytes = 10,485,760` (exactly at limit) | 200 (at-limit is accepted by DB constraint) |
| T-A-21 | `declared_size_bytes = 10,485,761` (one over) | 400 `FK_FILE_TOO_LARGE` |
| T-A-22 | Non-JSON body | 400 `FK_INVALID_INPUT` |

### 6.4 DB-Driven Errors

| # | Description | Expected |
|---|---|---|
| T-A-23 | `case_id` does not exist | 404 `FK_NOT_FOUND` |
| T-A-24 | `case_id` exists but authenticated user is not the poster | 404 `FK_NOT_FOUND` |
| T-A-25 | Case exists, user is poster, but case state is `launched` (not draft) | 409 `FK_WRONG_STATE` |
| T-A-26 | Case exists, draft state, but an active `upload_session` already exists (`status = 'pending'`) | 409 `FK_UPLOAD_IN_PROGRESS` |
| T-A-27 | Case exists, draft state, but an active `upload_session` already exists (`status = 'processing'`) | 409 `FK_UPLOAD_IN_PROGRESS` |
| T-A-28 | User has a `deletion_log` row with `status = 'database_prepared'` | 403 `FK_FORBIDDEN` |

### 6.5 Presign and Activate Failures

| # | Description | Expected |
|---|---|---|
| T-A-29 | `presignPutUrl` throws (simulated by injecting a bad endpoint) | 500 `FK_INTERNAL`; session transitioned to `failed`; `failed_reason = 'FK_INTERNAL'` in DB |
| T-A-30 | `activate_upload_session` throws (simulated by calling with stale expiry) | 500 `FK_INTERNAL`; session transitioned to `failed`; presigned URL NOT returned to client |

### 6.6 Mandatory Step 24 Rev 10 §5.1 Tests (V4 Substitutions Applied)

The full §5.1 test matrix from Step 24 Rev 10 must be executed with these identifier substitutions:
- `challenge_id` → `case_id`
- `public.challenges` → `public.cases`
- `state = 'active'` → `state = 'launched'`

The §5.1 categories relevant to `upload-authorize`:
- **Race A** — Reservation vs. deletion concurrency: concurrent `reserve_upload_session` and `prepare_account_deletion_wrapper` for the same user; assert exactly one succeeds with `FK_FORBIDDEN` on the other.
- **Race B** — Duplicate reservation: two concurrent calls with same `case_id`; assert exactly one gets `FK_UPLOAD_IN_PROGRESS`.

---

## Section 7 — Environment Variables

All read at runtime via `Deno.env.get()`. Never logged, never hardcoded.

| Variable | Local value (from `supabase status -o env`) | Production |
|---|---|---|
| `SUPABASE_URL` | `http://127.0.0.1:54321` | Project URL |
| `SUPABASE_SERVICE_ROLE_KEY` | From `supabase status -o env` | Dashboard secret |
| `S3_ENDPOINT` | `http://127.0.0.1:54321/storage/v1/s3` | `.storage.` hostname |
| `S3_REGION` | `local` | Dashboard value |
| `S3_ACCESS_KEY_ID` | `625729a08b95bf1b7ff351a663f3a23c` (local S3 key from `supabase status`) | Dashboard-generated key |
| `S3_SECRET_ACCESS_KEY` | From `supabase status -o env` (git-ignored) | Dashboard secret |
| `S3_BUCKET` | `game-media` | `game-media` |

Local values set in `supabase/functions/.env` (git-ignored). `S3_SECRET_ACCESS_KEY` and `SUPABASE_SERVICE_ROLE_KEY` never stored in any committed file.

---

## Section 8 — Scaffold and Quality Gates

After scaffolding (before any local tests), these must pass with zero output:

```sh
deno check supabase/functions/upload-authorize/index.ts
deno fmt --check supabase/functions/upload-authorize/index.ts
deno lint supabase/functions/upload-authorize/index.ts
gitleaks detect --source . --no-git
```

After scaffold is clean, generate `deno.lock` (Gate 6 — first function):
```sh
deno cache --lock=deno.lock \
  supabase/functions/upload-authorize/index.ts \
  supabase/functions/upload-authorize/upload-authorize.test.ts
```

`deno.lock` committed. All import specifiers pin exact versions.

---

## Section 9 — npm Imports

All npm packages pinned to exact versions:

| Import | Package | Purpose |
|---|---|---|
| `npm:@supabase/server@...` | `@supabase/server` | JWT verification (`createSupabaseContext`) |
| `npm:@supabase/supabase-js@...` | `@supabase/supabase-js` | Supabase client |
| `npm:@aws-sdk/client-s3@...` | `@aws-sdk/client-s3` | S3 client |
| `npm:@aws-sdk/s3-request-presigner@...` | `@aws-sdk/s3-request-presigner` | Presigned URL generation |

Exact version strings to be resolved at scaffold time via `deno cache` and pinned in `deno.lock`.

---

## Section 10 — Open Questions

| Question | Resolution |
|---|---|
| `@supabase/server` exact package path for `createSupabaseContext` | To be resolved at scaffold time; use `npm:@supabase/server` — same pattern confirmed in Gate 4 |
| Token entropy sufficient? | `crypto.randomUUID()` = 122 bits of entropy. Sufficient; no change needed. |
| `declared_size_bytes = 10,485,760` at-limit behavior | DB constraint is `<= 10485760`; at-limit is accepted. Edge Function passes through to DB; no additional check needed at that boundary. |
| `supabase/functions/.env` format | Standard `KEY=VALUE` per line; consumed by `supabase functions serve` locally |

---

## Section 11 — Approval Record

| Party | Status | Notes |
|---|---|---|
| Claude | Approved | Rev 1 authored by Claude; V2/V4 schema verified before writing |
| Codex | Pending | — |
| Bill | Pending | — |

**This approval authorizes TypeScript implementation only. No cloud deployment authorized.**
