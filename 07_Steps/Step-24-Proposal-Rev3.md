# Step 24 Proposal — Rev 3 — Edge Function Architecture and Contracts

**Status:** Pending review (Claude → Codex/GPT → Bill approval)
**Governance gate:** Bill must type `APPROVED: Step 24 — Edge Function Architecture and Contracts` before any Edge Function code is written.

**Scope:** Architecture decisions and binding contracts only. No TypeScript, no Deno code, no deployment. Implementation follows in separate per-function steps.

**Changes from Rev 2:**
1. Upload path scoped per upload attempt (`challenges/{challenge_id}/originals/{upload_token}`) — no fixed path that could collide across retry attempts; `upload-complete` reads path from session record.
2. `media-serve` draft-photo authorization tightened — group members cannot access the image while the challenge is in `draft` state; only the poster may preview during draft.
3. Original deletion ordering in `upload-complete` corrected — original is deleted and confirmed gone before the DB finalization transaction commits; if deletion fails, display.webp is also deleted and the client must retry; "log and continue" removed.
4. Account deletion carve-out resolved — `account-delete-complete` bypasses the `is_active + onboarding_complete` gate; any user with a valid JWT and an existing profile row may delete their own account.

---

## Section 1 — Decision Matrix: Edge Function vs. Direct RPC

The primary rule: if a database executor function can safely perform the operation, no Edge Function is required. Edge Functions are required only when an operation needs the service/secret key, private storage access, or scheduled execution.

### Direct RPC (no Edge Function needed)

These operations are handled by authenticated calls to `forkensics_executor` functions or by direct authenticated INSERT/SELECT. The iOS client calls them via the Supabase Swift SDK using the user's JWT. The database enforces authorization via RLS and SECURITY DEFINER.

| Operation | Mechanism | Notes |
|---|---|---|
| Submit a guess | Authenticated `INSERT` into `public.guess_attempts` | RLS + `set_guess_receipt_fields` trigger enforces eligibility and receipt timestamp |
| Add a clue | Authenticated `INSERT` into `public.clues` | RLS enforces poster-only |
| Activate a challenge | `public.activate_challenge(uuid)` | Poster only; executor enforces |
| Manually reveal a challenge | `public.reveal_challenge(uuid)` | Poster only; executor enforces; canonical answer becomes readable per RLS after reveal |
| Cancel a challenge | `public.cancel_challenge(uuid, text)` | Poster only (not admin); takes mandatory reason text |
| Apply a score correction | `public.apply_correction(uuid, text, text, text, uuid, text)` | Poster only; immutable audit trail |
| Create a group | `public.create_group(text)` | Executor enforces |
| Create a group invite | `public.create_group_invite(uuid)` | Executor enforces |
| Redeem a group invite | `public.redeem_group_invite(text)` | Executor enforces |
| Revoke a group invite | `public.revoke_group_invite(uuid)` | Executor enforces |
| Transfer group ownership | `public.transfer_group_ownership(uuid, uuid)` | Executor enforces |
| Comments and reactions | Direct authenticated INSERT/UPDATE | RLS enforces group membership |
| Leaderboard and score reads | Direct SELECT via RLS | `current_score_events` view |
| Profile reads | Direct SELECT via RLS | `public.profiles` |

**Note — no remove-member function in V1.** Member removal is not implemented in V1. This is a V2 decision.

### Edge Functions Required

| Function | Why the service/secret key is needed |
|---|---|
| `upload-authorize` | Generate signed upload URL for the private `game-media` bucket |
| `upload-complete` | Read original from private storage, re-encode, strip EXIF/GPS, delete original, write re-encoded copy, write `public.media_objects` + `private.media_storage_keys`, set `challenges.media_object_id` — atomically after original is confirmed deleted |
| `media-serve` | Proxy re-encoded image from private storage; never expose storage path or signed URL to client |
| `scheduled-close` | Cron-triggered; locks and reveals challenges past `deadline_at`; no user JWT |
| `account-delete-complete` | Deletes storage objects (service role), calls private deletion functions (service role), deletes `auth.users` (Admin API) |

### Deferred to V2

| Operation | Reason |
|---|---|
| Auto-reveal when all eligible players have submitted | Requires a database trigger on `guess_attempts` — V2 migration |
| Push notifications | External service (APNs); no V1 infrastructure |
| Sign in with Apple provider configuration | Auth provider setting, not an Edge Function |
| Member removal | No V1 function; V2 decision |

---

## Section 2 — V2 Migration Decision: Upload Session Infrastructure

V1 contains no upload-token table, no upload session state, and no processing-idempotency infrastructure. The `upload-authorize` and `upload-complete` contracts cannot be implemented from V1 alone.

**Decision: add a V2 migration** containing upload-session and finalization infrastructure before implementing the upload Edge Functions.

The V2 migration will be a separate governance step (Step 25) covering:
- A table to record upload sessions: `challenge_id`, `uploader_id`, `upload_token`, `storage_path`, `content_type`, `declared_size_bytes`, `expires_at`, `status` (`pending` | `complete` | `failed`)
- A service-role-only function to create an upload session (called by `upload-authorize`), which records the unique `storage_path` for this attempt
- A service-role-only function to finalize an upload session (called by `upload-complete`), which atomically: inserts into `public.media_objects`, inserts into `private.media_storage_keys`, sets `challenges.media_object_id`, marks the session `complete`
- A service-role-only function to expire stale sessions

The V2 migration must go through the full three-party governance cycle before any upload Edge Function is implemented.

---

## Section 3 — Cross-Cutting Contracts

These rules apply to every Edge Function without exception.

### 3.1 Authentication

**`verify_jwt` setting:**
- All Edge Functions except `scheduled-close` deploy with `verify_jwt = true`. When the Supabase gateway rejects a JWT before the function runs, the gateway returns its own `401` response. That response does not follow the Forkensics error envelope — this is expected and documented here. The function's own error envelope applies only to errors the function itself produces.
- `scheduled-close` deploys with `verify_jwt = false`. It uses a separate verified cron credential stored in Supabase Vault (see Section 4.4).

**Standard gate (applies to all user-facing functions except `account-delete-complete`):**
After gateway JWT verification succeeds:
1. Extract `sub` claim (user UUID). If absent or empty → `401 FK_UNAUTHENTICATED`.
2. Confirm a row exists in `public.profiles` where `id = sub` AND `is_active = true` AND `onboarding_complete = true`. If not → `403 FK_FORBIDDEN`.

**`account-delete-complete` gate (carve-out — see Section 4.5):**
After gateway JWT verification succeeds:
1. Extract `sub` claim (user UUID). If absent or empty → `401 FK_UNAUTHENTICATED`.
2. Confirm a row exists in `public.profiles` where `id = sub`. Any `is_active` or `onboarding_complete` value is permitted — a deactivated or partially-onboarded user must be able to complete their own deletion.

### 3.2 Authorization

Authorization is enforced at two layers:

- **Database layer:** All DB calls that read data on behalf of a user use a client initialized with the user's JWT. RLS applies normally.
- **Service role layer:** Used only for operations the authenticated role cannot perform: storage reads/writes, private schema functions, `auth.users` deletion. Never used for reads the user is not authorized to perform.

### 3.3 Existence and Authorization Probing

For any challenge-scoped operation: if the challenge does not exist OR if the caller is not authorized to see it, return `404 FK_NOT_FOUND` — not `403`. This prevents callers from using error codes to confirm challenge existence.

### 3.4 Error Response Format

All errors produced by Edge Functions return JSON with `Content-Type: application/json`:

```json
{
  "error": {
    "code": "FK_ERROR_CODE",
    "message": "Human-readable description"
  }
}
```

Gateway-produced errors (e.g., JWT rejection by Supabase before function invocation) may not follow this format. That exception is documented here and does not need to be handled by the function.

### 3.5 Standard Error Codes

| HTTP | Code | Meaning |
|---|---|---|
| 400 | `FK_INVALID_INPUT` | Missing or malformed request field |
| 400 | `FK_INVALID_CONTENT_TYPE` | File type not `image/jpeg` or `image/webp` (MIME-sniffed, not client-declared) |
| 400 | `FK_FILE_TOO_LARGE` | Actual stored file exceeds 10 MB |
| 400 | `FK_INVALID_TOKEN` | Upload token missing, malformed, expired, or already used |
| 401 | `FK_UNAUTHENTICATED` | Missing or invalid sub claim after gateway verification |
| 403 | `FK_FORBIDDEN` | Valid JWT, caller does not meet `is_active` + `onboarding_complete` requirements |
| 404 | `FK_NOT_FOUND` | Resource does not exist or caller is not authorized to see it (combined, no probing) |
| 409 | `FK_WRONG_STATE` | Challenge is not in the required state |
| 409 | `FK_ALREADY_COMPLETE` | Idempotent operation already completed — returns same result as first call |
| 422 | `FK_PROCESSING_FAILED` | Re-encoding, MIME sniffing, or storage operation failed |
| 429 | `FK_RATE_LIMITED` | Too many requests |
| 500 | `FK_INTERNAL` | Unexpected server error — no internal detail exposed to caller |

### 3.6 Idempotency

All functions that write state must be safe to retry. Idempotency is derived from stable inputs (e.g., `challenge_id`), not from client-supplied idempotency headers.

- A retry of a successfully completed operation returns `200 OK` with the original result. It does not return `409`.
- A retry of a failed operation re-attempts the operation from the beginning.
- `409 FK_WRONG_STATE` and `409 FK_ALREADY_COMPLETE` are distinct: `FK_WRONG_STATE` means the challenge's database state prevents the operation; `FK_ALREADY_COMPLETE` means this specific operation already finished and the caller is receiving the original result.

### 3.7 Logging

Logs must never contain:
- Canonical dish name, restaurant name, or city
- Storage paths or signed URLs
- EXIF or GPS data from any image
- Secret keys, JWTs, upload tokens, or Vault credentials
- Any content from `challenge_secrets`

Logs must contain:
- Timestamp (ISO 8601)
- Function name
- Request ID (generated per invocation)
- User UUID (for authenticated functions)
- Challenge UUID (where applicable)
- Outcome: `success` | `error`
- Error code on failure (not the message)

### 3.8 AI Failure Safety

If any Edge Function fails, ordinary gameplay continues. Specifically:
- `upload-authorize` / `upload-complete` failure → challenge stays in draft; poster retries when ready
- `media-serve` failure → image unavailable; game UI shows placeholder; guessing and scoring unaffected
- `scheduled-close` failure → challenges remain open past `deadline_at` until next successful cron run; no data corruption
- `account-delete-complete` partial storage failure → user can still authenticate and retry; no photos abandoned

### 3.9 Database Access Pattern

Edge Functions that call private schema functions (`private.*`) or need BYPASSRLS use direct PostgreSQL access via `SUPABASE_DB_URL` (auto-injected) with transaction-pooler semantics. They do not route through the Data API. The `private` schema is never exposed through the Data API.

---

## Section 4 — Function Contracts

### 4.1 `upload-authorize`

**Purpose:** Issue a time-limited signed URL so the iOS client can upload a challenge photo directly to the `game-media` private bucket.

**Prerequisite:** V2 upload-session infrastructure (Section 2).

**Method / Path:** `POST /upload-authorize`

**`verify_jwt`:** `true`

**Request body:**
```json
{
  "challenge_id": "<uuid>",
  "content_type": "image/jpeg" | "image/webp",
  "declared_size_bytes": 1234567
}
```

**Authorization checks (in order):**
1. Profile active + onboarding complete (Section 3.1 standard gate).
2. `challenge_id` exists and caller is the poster — otherwise `404 FK_NOT_FOUND`.
3. Challenge state is `draft` — otherwise `409 FK_WRONG_STATE`.
4. `content_type` is `image/jpeg` or `image/webp` — otherwise `400 FK_INVALID_CONTENT_TYPE`.
5. `declared_size_bytes` ≤ 10,485,760 — otherwise `400 FK_FILE_TOO_LARGE`. (Actual size is re-validated server-side in `upload-complete`.)

**Action:**
1. Generate a new `upload_token` (UUID).
2. Construct the storage path: `challenges/{challenge_id}/originals/{upload_token}`. This path is unique per upload attempt — a retry produces a different path at a different token, preventing collision between an abandoned and a retry upload.
3. Generate a signed upload URL for that path in `game-media`, 5-minute expiry (service role).
4. Create an upload session row via the V2 session-creation function (service role): `challenge_id`, `uploader_id`, `upload_token`, `storage_path = challenges/{challenge_id}/originals/{upload_token}`, `content_type`, `declared_size_bytes`, `expires_at = now() + 5 minutes`, `status = pending`.
5. Any previous `pending` session for this `challenge_id` is set to `status = failed` (superseded).

**Response `200 OK`:**
```json
{
  "signed_url": "<url>",
  "upload_token": "<uuid>",
  "expires_at": "<ISO 8601>"
}
```

**Idempotency:** Not idempotent — each call supersedes the previous session and issues a new signed URL at a new storage path.

**Logging:** `challenge_id`, `user_id`, `content_type`, outcome. NOT signed URL, upload token, or storage path.

---

### 4.2 `upload-complete`

**Purpose:** Validate the uploaded file server-side, re-encode it with EXIF/GPS removal, delete the original before committing the database record, and atomically finalize the media object.

**Prerequisite:** V2 upload-session infrastructure (Section 2).

**Method / Path:** `POST /upload-complete`

**`verify_jwt`:** `true`

**Request body:**
```json
{
  "challenge_id": "<uuid>",
  "upload_token": "<uuid>"
}
```

**Authorization checks (in order):**
1. Profile active + onboarding complete (Section 3.1 standard gate).
2. Look up upload session by `upload_token`. Session must exist, not be expired, have `status = pending`, belong to this `challenge_id`, and have been created by the authenticated user — otherwise `400 FK_INVALID_TOKEN`.
3. Challenge state is `draft` — otherwise `409 FK_WRONG_STATE`.

**Action (in order — abort and clean up on any failure before step 6):**

1. Read the original file from `session.storage_path` (i.e., `challenges/{challenge_id}/originals/{upload_token}`) using service role. If absent → `404 FK_NOT_FOUND`.
2. Sniff actual MIME type from file bytes — do not trust `session.content_type` or any client claim. If not `image/jpeg` or `image/webp` → `400 FK_INVALID_CONTENT_TYPE`. Delete the file from storage; mark session `failed`.
3. Confirm actual stored size ≤ 10,485,760 bytes. If over → `400 FK_FILE_TOO_LARGE`. Delete the file from storage; mark session `failed`.
4. Re-encode to WebP; strip all EXIF, GPS, and embedded metadata. If re-encoding fails → `422 FK_PROCESSING_FAILED`. Delete the original from storage; mark session `failed`.
5. Write re-encoded file to `challenges/{challenge_id}/display.webp` (service role).
6. **Delete the original from `session.storage_path`** (service role). The original must be confirmed deleted before the database record is committed.
   - If deletion fails: attempt up to 2 retries with brief backoff.
   - If all attempts fail: delete the display.webp written in step 5; mark session `failed`; return `422 FK_PROCESSING_FAILED`. The client must call `upload-authorize` again and restart from the beginning. There is no state where the original persists after the DB record is committed.
7. Call the V2 atomic finalization function (service role, BYPASSRLS) in a single transaction:
   - Insert into `public.media_objects` (`uploader_id`, `status = 'ready'`)
   - Insert into `private.media_storage_keys` (`storage_key = session.storage_path`, `re_encoded_storage_key = 'challenges/{challenge_id}/display.webp'`)
   - Set `challenges.media_object_id` to the new `media_objects.id`
   - Mark session `complete`
   If the transaction fails → `500 FK_INTERNAL`. At this point the original has already been deleted and the display.webp exists in storage but has no DB record. The recovery path is: on next retry, `upload-complete` finds session still `pending`, re-reads the original (which no longer exists) → `404 FK_NOT_FOUND` → client must restart from `upload-authorize`. The orphaned display.webp will be cleaned up during storage cleanup on account deletion via `get_storage_keys_for_deletion`. This failure mode is logged with the challenge ID for manual review.

**Response `200 OK`:**
```json
{
  "media_object_id": "<uuid>",
  "status": "ready"
}
```

**Idempotency:** If the upload session for `upload_token` is already `complete`, return `200 OK` with the existing `media_object_id` and `"status": "complete"`. Do not re-encode.

**Concurrent uploads:** If two calls arrive simultaneously with the same `upload_token`, the finalization transaction in step 7 serializes them. The second transaction will find the session already `complete` and receive `409 FK_ALREADY_COMPLETE`.

**Logging:** `challenge_id`, `media_object_id`, actual MIME type, actual stored size, re-encoding outcome, original-deletion outcome (success/failure/attempts). NOT storage paths or upload token.

---

### 4.3 `media-serve`

**Purpose:** Proxy the re-encoded challenge image to an authorized viewer. Never expose storage paths or signed URLs to the client.

**Method / Path:** `GET /media/{challenge_id}`

**`verify_jwt`:** `true`

**Authorization checks (in order):**
1. Profile active + onboarding complete (Section 3.1 standard gate).
2. Look up the challenge. If it does not exist → `404 FK_NOT_FOUND`.
3. Use `private.is_challenge_group_member(challenge_id)` to confirm the caller is a member of the challenge's group. If not → `404 FK_NOT_FOUND` (no probing).
4. **Draft-state restriction:** If challenge state is `draft`, additionally confirm the caller is the poster using `private.is_challenge_poster(challenge_id)`. If not the poster → `404 FK_NOT_FOUND`. Group members other than the poster cannot see the image while the challenge is in `draft`.
5. `challenges.media_object_id` is not null and `media_objects.status = 'ready'`. If not → `404 FK_NOT_FOUND`.

**Action:**
- Read `challenges/{challenge_id}/display.webp` from private `game-media` storage (service role).
- Stream bytes to client with `Content-Type: image/webp`.
- Never read or serve the original at any storage path.

**Response `200 OK`:** Binary image stream (`image/webp`)

**Cache headers:** `Cache-Control: private, max-age=3600` — re-encoded images are stable.

**Idempotency:** Read-only, naturally idempotent.

**Logging:** `challenge_id`, `user_id`, challenge state at time of request, outcome. NOT the storage path.

---

### 4.4 `scheduled-close`

**Purpose:** Lock and then reveal all challenges whose `deadline_at` has passed.

**Trigger:** Supabase pg_cron, every 2 minutes.

**`verify_jwt`:** `false`

**Authentication:** A cron-specific credential is stored in Supabase Vault. On each invocation, the function reads the credential from Vault and compares it to the value in the `Authorization` header. Any request that does not supply the matching credential → `401`. External HTTP requests are rejected. This credential is separate from all user-facing keys.

**Action:**

Pass 1 — lock active challenges past deadline:
1. Query `public.challenges WHERE state = 'active' AND deadline_at <= now()`.
2. For each: call `public.lock_challenge(uuid)` (service role). `lock_challenge` raises if the challenge is not in `active` state — catch per-row, log challenge ID and error code, continue batch.

Pass 2 — reveal all locked challenges:
1. Query `public.challenges WHERE state = 'locked'`. This catches challenges locked in Pass 1 as well as any challenge that was locked in a prior cron run but not yet revealed (due to a prior failure).
2. For each: call `private.reveal_challenge_service(uuid)` (service role). Catch per-row errors — log and continue batch.

The two-pass structure ensures no locked challenge is permanently stranded if a prior cron run failed mid-batch.

**Response `200 OK`:**
```json
{
  "locked_count": 3,
  "revealed_count": 3,
  "skipped_count": 0,
  "errors": [
    { "challenge_id": "<uuid>", "pass": "lock" | "reveal", "error_code": "..." }
  ]
}
```

**Idempotency:** Both passes are safe to run multiple times. `lock_challenge` raises on non-`active` challenges (caught per-row). `reveal_challenge_service` raises on non-`locked` challenges (caught per-row).

**Logging:** `locked_count`, `revealed_count`, `skipped_count`, any per-row error codes and challenge IDs. NOT challenge content, canonical answers, or guess data.

---

### 4.5 `account-delete-complete`

**Purpose:** Complete account deletion after the user provides final confirmation — delete storage objects, delete the auth account, and finalize the database deletion record.

**Method / Path:** `POST /account-delete-complete`

**`verify_jwt`:** `true`

**Request body:** *(none — caller identity comes from the JWT)*

**Authentication:** The carve-out gate (Section 3.1) applies. Requires only:
1. Valid JWT with non-empty `sub`.
2. A row in `public.profiles` where `id = sub`. Any `is_active` or `onboarding_complete` value is permitted. Rationale: a user whose account has been deactivated or who did not complete onboarding must still be able to exercise their right to delete their account. Blocking on `is_active = false` would permanently prevent self-deletion for deactivated users.

**Action (stop on failure as specified):**

1. Call `private.prepare_account_deletion(user_id)` (service role). Anonymizes the profile and marks deletion record as `database_prepared`. If it raises → `500 FK_INTERNAL`.
2. Call `private.get_storage_keys_for_deletion(user_id)` (service role). Returns `TABLE(media_object_id uuid, storage_key text)` — one row per distinct physical storage key.
3. For each storage key: delete the object from `game-media` (service role). Track per-key success and failure.
4. If **any** storage deletion fails:
   - Call `private.record_deletion_failure(user_id, error_text)` (service role).
   - Return `422 FK_PROCESSING_FAILED`. Body: `{ "error": { "code": "FK_PROCESSING_FAILED", "message": "Storage cleanup incomplete. Retry to continue." } }`.
   - **Stop here.** Do not delete the auth account. The user can still authenticate and retry. Private photos are not abandoned.
5. Delete the `auth.users` row for this user (Supabase Admin API, service role).
6. Call `private.mark_auth_deleted(user_id)` (service role).
7. Call `private.mark_storage_cleaned(user_id)` (service role).
8. Return `200 OK`.

**Response `200 OK`:**
```json
{ "status": "complete" }
```

**Idempotency:** If the deletion record is already in `auth_deleted` or `storage_cleaned` state → return `200 OK` with `"status": "already_complete"`. Do not re-attempt auth deletion.

**Recovery worker (required before this function is deployed):** If step 5 succeeds but step 6 or 7 fails, the user no longer exists in `auth.users` and cannot authenticate to retry. A scheduled recovery worker finds deletion records in a state indicating auth was deleted but database finalization was not completed, and calls `mark_auth_deleted` and `mark_storage_cleaned` using service role. This worker is deployed together with `account-delete-complete`, not separately.

**Logging:** `user_id`, `storage_key_count`, `deleted_count`, `failed_count`, deletion record state at each step. NOT storage paths, key values, or file content.

---

## Section 5 — Contract Test Requirements

### 5.1 Local Contract Tests

Each function gets a dedicated contract test file. Tests must cover:

**Authentication and authorization (all functions):**
- Missing JWT → `401` (gateway or function — document which for each)
- Expired JWT → `401`
- Standard gate: valid JWT, `is_active = false` → `403 FK_FORBIDDEN`
- Standard gate: valid JWT, `onboarding_complete = false` → `403 FK_FORBIDDEN`
- Carve-out gate (`account-delete-complete`): valid JWT, `is_active = false` → allowed (not `403`)
- Carve-out gate: valid JWT, `onboarding_complete = false` → allowed (not `403`)

**Existence and probing (challenge-scoped functions):**
- Nonexistent `challenge_id` → `404 FK_NOT_FOUND`
- Valid `challenge_id`, caller not in group → same `404 FK_NOT_FOUND` (response body identical)

**Input validation (`upload-authorize`, `upload-complete`):**
- Missing required field → `400 FK_INVALID_INPUT`
- Client-declared `content_type` is valid but MIME-sniffed bytes are a different type → `400 FK_INVALID_CONTENT_TYPE`
- Valid JPEG bytes with a WebP content_type declaration → `400 FK_INVALID_CONTENT_TYPE` (sniffed type wins)
- Actual stored file size exceeds 10 MB → `400 FK_FILE_TOO_LARGE`
- Expired upload token → `400 FK_INVALID_TOKEN`
- Already-used (`complete`) upload token → `400 FK_INVALID_TOKEN`

**State machine:**
- `upload-authorize` / `upload-complete`: challenge not in `draft` → `409 FK_WRONG_STATE`
- `media-serve`: `media_objects.status != 'ready'` → `404 FK_NOT_FOUND`
- `media-serve`: challenge in `draft`, caller is poster → `200 OK`
- `media-serve`: challenge in `draft`, caller is group member (not poster) → `404 FK_NOT_FOUND`
- `media-serve`: challenge in `active`, caller is group member → `200 OK`

**Upload path and storage (`upload-complete`):**
- Each `upload-authorize` call produces a unique storage path (`originals/{token1}` vs `originals/{token2}`)
- `upload-complete` reads path from session record, not from a hard-coded pattern
- Re-encoding produces valid WebP output
- Original at `session.storage_path` is deleted and confirmed absent before DB finalization commits
- Original deletion failure: display.webp is also deleted; session marked `failed`; `422 FK_PROCESSING_FAILED` returned
- `public.media_objects`, `private.media_storage_keys`, and `challenges.media_object_id` are all set atomically

**Idempotency:**
- Second `upload-complete` with same `upload_token` after success → `200 OK` with same `media_object_id`
- Concurrent `upload-complete` with same `upload_token` → one succeeds, one returns `409 FK_ALREADY_COMPLETE`

**Scheduler (`scheduled-close`):**
- Request without Vault credential → `401`
- Challenge past `deadline_at` in `active` state → locked then revealed across two passes
- Challenge already `locked` (prior run) → revealed in Pass 2 without error
- Challenge already `revealed` → caught per-row in Pass 2, logged, batch continues
- Per-row failure in Pass 1 does not abort Pass 2

**Account deletion (`account-delete-complete`):**
- Happy path: all storage deleted, auth deleted, records finalized → `200 complete`
- Storage deletion failure for any object → `422 FK_PROCESSING_FAILED`; auth account not deleted; user can still authenticate and retry
- Retry after storage failure → storage re-attempted; if now successful, continues to auth deletion
- Retry after auth deletion already complete → `200 already_complete`
- `is_active = false` → allowed (carve-out confirmed)
- `onboarding_complete = false` → allowed (carve-out confirmed)
- Recovery worker: deletion record in partially-finalized state after auth deletion → worker completes steps 6–7

**Error format (all functions):**
- All function-produced errors match `{ "error": { "code": "FK_...", "message": "..." } }`

### 5.2 Hosted Smoke Tests (dev only — never prod)

After each function is deployed to `forkensics-dev`:
- Function is reachable and returns a response
- Unauthenticated request → `401`
- Authenticated request with invalid input → appropriate `400`
- Happy path → expected status code

Smoke tests must not create permanent data. Any test challenge or media object is cleaned up within the same test run. Smoke tests are never run against `forkensics-prod`.

### 5.3 What Contract Tests Must Never Do

- Call `reveal_challenge()` or `private.reveal_challenge_service()` on a real challenge
- Assert on or log canonical answers, restaurant names, or city values
- Leave test data in `forkensics-prod`
- Hard-code credentials — use environment variables or test-only Vault entries

---

## Section 6 — Deployment Sequence

Each function is deployed one at a time. Each deployment is gated on:
1. V2 migration complete and verified (for upload functions)
2. Local contract tests pass
3. GPT review of the implementation
4. Bill approves with `APPROVED: Deploy {function-name}`
5. Deploy to `forkensics-dev`; hosted smoke tests pass
6. Bill approves with `APPROVED: Deploy {function-name} to prod`
7. Deploy to `forkensics-prod`; smoke tests pass

**Order:**
1. V2 migration (upload-session infrastructure) — separate Step 25
2. `upload-authorize`
3. `upload-complete`
4. `media-serve`
5. `scheduled-close` (requires Vault setup first)
6. `account-delete-complete` (requires recovery worker implementation)

---

## Section 7 — Out of Scope for Step 24

- Any TypeScript or Deno code
- Any `supabase functions deploy` command
- V2 migration content (covered in Step 25)
- Push notifications
- Sign in with Apple configuration
- Any iOS application code
- Member removal (no V1 function)

---

## Success Criteria for Step 24

- [ ] Decision matrix agreed: which operations are Edge Functions, which are direct RPCs
- [ ] V2 migration decision agreed (upload-session infrastructure required before upload functions)
- [ ] Upload storage path design agreed (per-attempt unique path via `upload_token`)
- [ ] All five function contracts agreed: method, auth gate, request, action, response, error codes, idempotency, logging
- [ ] `media-serve` draft-state restriction agreed (poster-only during draft)
- [ ] Original deletion ordering agreed (original confirmed deleted before DB finalization)
- [ ] `scheduled-close` two-pass design and Vault authentication agreed
- [ ] Account deletion state machine and stop-on-storage-failure rule agreed
- [ ] Account deletion carve-out resolved (`is_active` and `onboarding_complete` not required)
- [ ] Recovery worker requirement agreed
- [ ] Cross-cutting rules agreed: auth gates, error envelope, existence probing, logging prohibitions, AI failure safety
- [ ] Contract test coverage agreed
- [ ] Deployment sequence agreed
- [ ] No Edge Function code written before approval
