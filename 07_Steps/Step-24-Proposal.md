# Step 24 Proposal — Edge Function Architecture and Contracts

**Status:** Pending review (Claude → Codex/GPT → Bill approval)
**Governance gate:** Bill must type `APPROVED: Step 24 — Edge Function Architecture and Contracts` before any Edge Function code is written.

**Scope:** Architecture decisions and binding contracts only. No TypeScript, no Deno code, no deployment. Implementation follows in separate per-function steps.

---

## Overview

V1 already contains 20 `forkensics_executor` SECURITY DEFINER functions and 9 `forkensics_rls_helper` functions. Many server-side operations are already handled safely at the database layer. This step decides which actions still require Edge Functions (because they need the secret key, storage access, or external services) and specifies the exact contract for each one before any code is written.

---

## Section 1 — Decision Matrix: Edge Function vs. Direct RPC

The primary rule: if a database executor function can safely perform the operation — enforcing RLS, running as BYPASSRLS, returning only what the caller is allowed to see — no Edge Function is needed. Edge Functions are required only when an operation needs the service/secret key, storage access, external APIs, or scheduled execution.

### Direct RPC (no Edge Function needed)

These operations are handled entirely by authenticated calls to `forkensics_executor` or `forkensics_rls_helper` functions. The iOS client calls them via the Supabase Swift SDK using the user's JWT. The database enforces authorization.

| Operation | DB Function | Notes |
|---|---|---|
| Submit a guess | `submit_guess()` | Append-only; executor enforces eligibility |
| Activate a challenge | `activate_challenge()` | Poster only; executor enforces |
| Reveal a challenge manually | `reveal_challenge()` | Poster only; executor enforces; canonical answer visible after reveal per RLS |
| Cancel a challenge | `cancel_challenge()` | Poster or admin; executor enforces |
| Apply a score correction | `apply_correction()` | Poster or admin; executor enforces; immutable audit trail |
| Prepare account deletion | `prepare_account_deletion()` | Returns deletion token; executor enforces |
| Add a clue | `add_clue()` | Poster only; executor enforces |
| Group management (create, invite, remove) | Various executor functions | RLS enforces membership |
| Comments and reactions | Directly via authenticated INSERT | RLS enforces group membership |
| Leaderboard and score reads | Direct SELECT via RLS | `current_score_events` view |
| Profile reads | Direct SELECT via RLS | `profiles` table |

### Edge Functions Required

| Function | Reason secret key is required |
|---|---|
| `upload-authorize` | Generate signed upload URL for private storage bucket |
| `upload-complete` | Read from private storage, re-encode image, write re-encoded copy, optionally delete original |
| `media-serve` | Proxy re-encoded image from private storage without exposing storage path or signed URL to client |
| `scheduled-lock` | Cron-triggered; locks challenges past deadline using service role; no user JWT |
| `account-delete-complete` | Delete files from storage (service role), then call `complete_account_deletion()`, then delete `auth.users` record |

### Deferred to V2

| Operation | Reason deferred |
|---|---|
| Auto-reveal when all eligible players have submitted | Requires a database trigger on `guess_attempts` — V2 migration |
| Push notifications | External service (APNs); no V1 infrastructure |
| Sign in with Apple token verification | Auth provider configuration, not an Edge Function |

---

## Section 2 — Cross-Cutting Contracts

These rules apply to every Edge Function without exception.

### 2.1 Authentication

Every Edge Function (except `scheduled-lock`) requires a valid Supabase JWT in the `Authorization: Bearer <token>` header.

Verification steps (in order):
1. Extract `Authorization` header. If absent or malformed → `401 Unauthorized`.
2. Verify JWT signature using `SUPABASE_JWKS` (auto-injected by Supabase). If invalid or expired → `401 Unauthorized`.
3. Extract `sub` claim (user UUID). If absent or empty → `401 Unauthorized`.
4. Confirm `sub` matches a row in `public.profiles`. If not → `403 Forbidden`.

The `scheduled-lock` function authenticates via the Supabase cron mechanism — no user JWT. It must reject any request that arrives without the internal invocation context.

### 2.2 Authorization

Authorization is enforced at two layers:

- **Database layer**: All DB calls from Edge Functions that act on behalf of a user use a client initialized with the user's JWT (not the service role). This preserves RLS for read operations.
- **Service role layer**: Used only for operations that require BYPASSRLS: storage reads/writes, `auth.users` deletion, and calls to executor functions that cannot be reached by the authenticated role.

An Edge Function must never use the service role client for a read that the user is not authorized to perform.

### 2.3 Error Response Format

All errors return JSON with `Content-Type: application/json`:

```json
{
  "error": {
    "code": "FORKENSICS_ERROR_CODE",
    "message": "Human-readable description"
  }
}
```

Standard HTTP status codes apply. Error codes are uppercase snake-case prefixed `FK_`.

### 2.4 Standard Error Codes

| HTTP | Code | Meaning |
|---|---|---|
| 400 | `FK_INVALID_INPUT` | Missing or malformed request field |
| 400 | `FK_INVALID_CONTENT_TYPE` | File type not `image/jpeg` or `image/webp` |
| 400 | `FK_FILE_TOO_LARGE` | File exceeds 10 MB |
| 400 | `FK_INVALID_TOKEN` | Upload token missing, malformed, or expired |
| 401 | `FK_UNAUTHENTICATED` | Missing or invalid JWT |
| 403 | `FK_FORBIDDEN` | Valid JWT but caller is not authorized for this action |
| 404 | `FK_NOT_FOUND` | Resource does not exist or caller cannot see it |
| 409 | `FK_WRONG_STATE` | Challenge is not in the required state for this operation |
| 409 | `FK_ALREADY_COMPLETE` | Idempotent operation already completed successfully |
| 422 | `FK_PROCESSING_FAILED` | Re-encoding or storage operation failed |
| 429 | `FK_RATE_LIMITED` | Too many requests |
| 500 | `FK_INTERNAL` | Unexpected server error — no internal details exposed |

### 2.5 Retry and Idempotency

- All functions that write state must be safe to retry.
- A second identical call while an operation is in progress returns `202 Accepted` with `status: "processing"`.
- A second identical call after success returns `200 OK` with the same result as the first call.
- Idempotency keys are derived from stable inputs (e.g., `challenge_id` for upload operations) — no client-supplied idempotency headers required.

### 2.6 Logging

Logs must never contain:
- Canonical dish name, restaurant name, or city
- Storage paths or signed URLs
- User-provided photo data or EXIF content
- Secret keys, JWTs, or tokens

Logs must contain:
- Timestamp (ISO 8601)
- Function name
- Request ID (generated per invocation)
- User UUID (for authenticated functions)
- Challenge UUID (where applicable)
- Outcome (`success` / `error`)
- Error code (on failure) — not the error message

### 2.7 AI Failure Safety

If any Edge Function fails, ordinary gameplay must remain possible. Specifically:
- `upload-authorize` failure → poster cannot upload a new photo, but existing challenges continue unaffected
- `upload-complete` failure → photo upload must be retried; challenge remains in draft
- `media-serve` failure → image is unavailable; game UI shows placeholder; guessing and scoring continue
- `scheduled-lock` failure → challenges remain open past deadline until the next successful cron run; no data corruption
- `account-delete-complete` failure → account remains in "prepare" state; user can retry; no partial deletion

---

## Section 3 — Function Contracts

### 3.1 `upload-authorize`

**Purpose:** Issue a time-limited signed URL so the iOS client can upload a challenge photo directly to the `game-media` private bucket.

**Trigger:** iOS client, before uploading a photo.

**Method / Path:** `POST /upload-authorize`

**Authentication:** Required (user JWT)

**Request body:**
```json
{
  "challenge_id": "<uuid>",
  "content_type": "image/jpeg" | "image/webp",
  "file_size_bytes": 1234567
}
```

**Authorization checks (in order):**
1. `challenge_id` exists in `public.challenges`.
2. Caller is the poster (`created_by = auth_uid`).
3. Challenge is in `draft` state.
4. `content_type` is `image/jpeg` or `image/webp`.
5. `file_size_bytes` ≤ 10,485,760 (10 MB).

**Action:**
- Generate a signed upload URL for path `challenges/{challenge_id}/original` in the `game-media` bucket, with 5-minute expiry.
- Generate an opaque `upload_token` (UUID stored server-side with `challenge_id` and expiry).

**Response `200 OK`:**
```json
{
  "signed_url": "<url>",
  "upload_token": "<uuid>",
  "expires_at": "<ISO 8601>"
}
```

**Errors:** `FK_INVALID_INPUT`, `FK_UNAUTHENTICATED`, `FK_FORBIDDEN`, `FK_NOT_FOUND`, `FK_WRONG_STATE`, `FK_INVALID_CONTENT_TYPE`, `FK_FILE_TOO_LARGE`

**Idempotency:** Not idempotent — each call issues a new signed URL. Previous upload tokens are invalidated.

**Logging:** `challenge_id`, `user_id`, `content_type`, outcome. NOT the signed URL or upload token.

---

### 3.2 `upload-complete`

**Purpose:** Confirm upload, trigger server-side re-encoding and EXIF removal, and record the media object.

**Trigger:** iOS client, after a successful PUT to the signed URL.

**Method / Path:** `POST /upload-complete`

**Authentication:** Required (user JWT)

**Request body:**
```json
{
  "challenge_id": "<uuid>",
  "upload_token": "<uuid>"
}
```

**Authorization checks (in order):**
1. `upload_token` exists, is not expired, and matches `challenge_id`.
2. Caller is the poster of `challenge_id`.
3. Challenge is in `draft` state.
4. Original file exists at `challenges/{challenge_id}/original` in `game-media`.

**Action:**
1. Read original file from private storage (service role).
2. Re-encode to WebP, strip all EXIF/GPS metadata. If re-encoding fails → `422 FK_PROCESSING_FAILED`.
3. Write re-encoded file to `challenges/{challenge_id}/display.webp` in `game-media`.
4. Insert or update row in `public.media_objects` with `storage_key = challenges/{challenge_id}/original` and `re_encoded_storage_key = challenges/{challenge_id}/display.webp`.
5. Invalidate `upload_token`.

**Response `200 OK`:**
```json
{
  "media_object_id": "<uuid>",
  "status": "ready"
}
```

**Idempotency:** If `media_object_id` already exists and `status = ready`, return `200 FK_ALREADY_COMPLETE` with existing `media_object_id`. Do not re-encode.

**Errors:** `FK_INVALID_INPUT`, `FK_UNAUTHENTICATED`, `FK_FORBIDDEN`, `FK_INVALID_TOKEN`, `FK_NOT_FOUND`, `FK_WRONG_STATE`, `FK_PROCESSING_FAILED`

**Logging:** `challenge_id`, `media_object_id`, outcome. NOT storage paths.

---

### 3.3 `media-serve`

**Purpose:** Proxy the re-encoded challenge image to an authorized viewer without exposing storage paths or signed URLs.

**Trigger:** iOS client, when displaying a challenge image.

**Method / Path:** `GET /media/{challenge_id}`

**Authentication:** Required (user JWT)

**Authorization checks (in order):**
1. `challenge_id` exists in `public.challenges`.
2. Caller is a member of the challenge's group (via `private.is_group_member_with`).
3. Re-encoded file exists at `challenges/{challenge_id}/display.webp`. If not yet ready → `404 FK_NOT_FOUND`.

**Action:**
- Read `challenges/{challenge_id}/display.webp` from private storage (service role).
- Stream bytes to client with `Content-Type: image/webp` and appropriate `Cache-Control` headers.
- Never read or serve `challenges/{challenge_id}/original`.

**Response `200 OK`:** Binary image stream (`image/webp`)

**Cache-Control:** `private, max-age=3600` — images are stable once re-encoded.

**Errors:** `FK_UNAUTHENTICATED`, `FK_FORBIDDEN`, `FK_NOT_FOUND`

**Idempotency:** Read-only, naturally idempotent.

**Logging:** `challenge_id`, `user_id`, outcome. NOT the storage path.

---

### 3.4 `scheduled-lock`

**Purpose:** Lock all challenges whose `closes_at` deadline has passed and whose state is still `active`.

**Trigger:** Supabase cron, every 2 minutes.

**Authentication:** Internal cron invocation only — no user JWT. Must reject external HTTP requests.

**Action:**
1. Query `public.challenges WHERE state = 'active' AND closes_at <= now()`.
2. For each: call `public.lock_challenge(challenge_id)` using service role.
3. Catch per-row errors (challenge already locked, cancelled, etc.) — log and continue; do not fail the batch.
4. Return summary.

**Response `200 OK`:**
```json
{
  "locked_count": 3,
  "skipped_count": 0,
  "errors": []
}
```

**Idempotency:** `lock_challenge()` is a no-op if the challenge is already locked. Safe to run multiple times.

**Logging:** `locked_count`, `skipped_count`, any error codes. NOT challenge content or canonical answers.

**AI failure safety:** If the cron fails, challenges remain open past deadline until the next run. No data corruption. A challenge that misses one lock window will be locked on the next successful run.

---

### 3.5 `account-delete-complete`

**Purpose:** Complete a two-phase account deletion by removing storage files, finalizing the database record, and deleting the `auth.users` entry.

**Trigger:** iOS client, after the user confirms deletion (phase 2 of the two-phase flow initiated by `prepare_account_deletion()`).

**Method / Path:** `POST /account-delete-complete`

**Authentication:** Required (user JWT — last authenticated action before deletion)

**Request body:**
```json
{
  "deletion_token": "<uuid>"
}
```

**Authorization checks (in order):**
1. `deletion_token` exists in the deletion log, is not expired (24-hour window), and belongs to the authenticated user.
2. `prepare_account_deletion()` was previously called for this user.

**Action (in order — each step logged before execution):**
1. Call `public.get_storage_keys_for_deletion(user_id)` to retrieve all storage keys for this user's media.
2. Delete each storage object from the `game-media` bucket (service role). Log each deletion by key hash — NOT the key itself.
3. Call `public.complete_account_deletion(user_id)` (service role, BYPASSRLS) to tombstone the profile and anonymize records.
4. Delete the `auth.users` row for this user (service role — Admin API).
5. Invalidate `deletion_token`.

**Response `200 OK`:**
```json
{
  "status": "complete"
}
```

**Idempotency:** If `auth.users` is already deleted, steps 3–4 are skipped and `200 FK_ALREADY_COMPLETE` is returned. Storage deletions in step 2 are retried safely (delete of nonexistent object is a no-op).

**Partial failure handling:** If storage deletion fails for one or more objects, log the failure and continue. Do not abort the entire deletion. Flag the user's deletion record for manual follow-up. Do NOT leave the database record intact because storage cleanup failed.

**Errors:** `FK_UNAUTHENTICATED`, `FK_FORBIDDEN`, `FK_INVALID_TOKEN`, `FK_INTERNAL`

**Logging:** `user_id` (before deletion), `storage_object_count`, `deleted_count`, `failed_count`, outcome. NOT storage paths.

---

## Section 4 — Contract Test Requirements

Before any Edge Function is deployed to hosted dev, it must pass a local contract test suite. Before it is deployed to prod, it must pass the same suite against the hosted dev environment.

### 4.1 Local Contract Tests

Each function gets a test file at `supabase/functions/{name}/contract_test.ts` (or equivalent). Tests must cover:

- Happy path: valid input, correct auth → expected response and status code
- Auth failure: missing token → `401`
- Auth failure: expired token → `401`
- Auth failure: valid token, wrong user → `403`
- State violation: challenge in wrong state → `409 FK_WRONG_STATE`
- Input validation: missing required field → `400 FK_INVALID_INPUT`
- Idempotency: second call with same input → `200` or `409 FK_ALREADY_COMPLETE` as specified
- Error format: all error responses match the standard `{ "error": { "code", "message" } }` shape

### 4.2 Hosted Contract Tests

A lightweight smoke test script runs against `forkensics-dev` after each deployment to confirm:
- Function is reachable
- Unauthenticated request returns `401`
- Authenticated request with invalid input returns `400`
- Happy path returns expected status code

Hosted contract tests must not create permanent data — they use a test challenge that is cleaned up after the run.

### 4.3 What Contract Tests Must Not Do

- Never call `reveal_challenge()` on a real challenge
- Never expose canonical answers in test assertions or logs
- Never leave test data in `forkensics-prod`
- Never hard-code credentials — use environment variables

---

## Section 5 — Deployment Sequence

Edge Functions are deployed one at a time, in this order, each gated on its own `APPROVED: Deploy {name}` phrase from Bill:

1. `upload-authorize`
2. `upload-complete`
3. `media-serve`
4. `scheduled-lock`
5. `account-delete-complete`

Each deployment follows: local contract tests pass → GPT review → Bill approves → deploy to dev → hosted smoke test passes → deploy to prod → smoke test passes.

---

## Section 6 — Out of Scope for Step 24

- Any TypeScript or Deno code
- Any `supabase functions deploy` command
- Push notifications
- Sign in with Apple configuration
- Any iOS application code
- V2 database migrations (auto-reveal trigger)

---

## Success Criteria for Step 24

- [ ] Decision matrix reviewed and agreed: which operations are Edge Functions, which are direct RPCs
- [ ] All five function contracts reviewed and approved (GPT + Bill)
- [ ] Cross-cutting auth, error, logging, retry, and idempotency rules agreed
- [ ] Contract test requirements agreed
- [ ] Deployment sequence agreed
- [ ] No Edge Function code written before approval
