# Step 24 Proposal — Rev 4 — Edge Function Architecture and Contracts

**Status:** Pending review (Claude → Codex/GPT → Bill approval)
**Governance gate:** Bill must type `APPROVED: Step 24 — Edge Function Architecture and Contracts` before any Edge Function code is written.

**Scope:** Architecture decisions and binding contracts only. No TypeScript, no Deno code, no deployment. Implementation follows in separate per-function steps.

**Changes from Rev 3:**
1. Direct-RPC table corrected: `cancel_challenge` and `apply_correction` permit poster or group owner; cancellation reason is nullable; comments use `INSERT` + `soft_delete_comment(uuid)`; reactions use `INSERT` + `DELETE`.
2. Upload-session state machine expanded: `pending → processing → sanitized → complete`; `pending → superseded`; `pending → expired`; any non-complete state → `failed`. Session record is created before the signed URL is generated. `session_id` and upload token are separate; only the token hash is stored. Display path is unique per session. Storage cleanup worker required for expired, superseded, failed, and orphaned objects. V2 functions enforce all business rules themselves.
3. Upload recovery corrected: the `sanitized` state records the display path so finalization can retry without the original. Recovery worker can handle abandoned sanitized sessions. Clarified that only database changes are atomic; storage and PostgreSQL require compensating cleanup.
4. Idempotency resolved: `202` while processing; `200 {"status":"ready","already_complete":true}` after completion; `400 FK_INVALID_TOKEN` for expired, superseded, or unknown token. Concurrent requests do not return `409`.
5. `media-serve` simplified: queries challenges using the user-JWT client and lets RLS enforce the `posted_at IS NOT NULL` visibility rule automatically; fetches `re_encoded_storage_key` via privileged wrapper.
6. Privileged database identity resolved: Edge Functions use public, service-role-only V2 wrapper functions called through the administrative Supabase client (PostgREST as `service_role`). `SUPABASE_DB_URL` direct-connection is not used. `private` schema is never exposed through the API.
7. Account deletion corrected: terminal status is `complete`; status naming aligned with V1 function names; recovery worker receives full contract including schedule, authentication, failure cases, and deployment gate; client retry after auth deletion is not possible (JWT void); only sanitized error codes passed to `record_deletion_failure`.
8. Remaining document contradictions fixed: "AI Failure Safety" → "Operational Failure Safety"; `scheduled-close` Pass 2 relies on `WHERE state = 'locked'` (revealed challenges are excluded at query time, not caught per-row); production verification defined as non-mutating reachability/auth checks only.

---

## Section 1 — Decision Matrix: Edge Function vs. Direct RPC

The primary rule: if a database executor function can safely perform the operation, no Edge Function is required. Edge Functions are required only when an operation needs the service/secret key, private storage access, or scheduled execution.

### Direct RPC (no Edge Function needed)

These operations are handled by authenticated calls to `forkensics_executor` functions or by direct authenticated INSERT/SELECT/DELETE. The iOS client calls them via the Supabase Swift SDK using the user's JWT. The database enforces authorization via RLS and SECURITY DEFINER.

| Operation | Mechanism | Notes |
|---|---|---|
| Submit a guess | Authenticated `INSERT` into `public.guess_attempts` | RLS + `set_guess_receipt_fields` trigger enforces eligibility and receipt timestamp |
| Add a clue | Authenticated `INSERT` into `public.clues` | RLS enforces poster-only |
| Activate a challenge | `public.activate_challenge(uuid)` | Poster only; executor enforces |
| Manually reveal a challenge | `public.reveal_challenge(uuid)` | Poster only; executor enforces; canonical answer becomes readable per RLS after reveal |
| Cancel a challenge | `public.cancel_challenge(uuid, text)` | Poster or group owner; executor enforces; reason is nullable |
| Apply a score correction | `public.apply_correction(uuid, text, text, text, uuid, text)` | Poster or group owner; executor enforces; immutable audit trail |
| Create a group | `public.create_group(text)` | Executor enforces |
| Create a group invite | `public.create_group_invite(uuid)` | Executor enforces |
| Redeem a group invite | `public.redeem_group_invite(text)` | Executor enforces |
| Revoke a group invite | `public.revoke_group_invite(uuid)` | Executor enforces |
| Transfer group ownership | `public.transfer_group_ownership(uuid, uuid)` | Executor enforces |
| Post a comment | Authenticated `INSERT` into `public.comments` | RLS enforces group membership |
| Delete a comment | `public.soft_delete_comment(uuid)` | Executor enforces; soft delete only |
| Post a reaction | Authenticated `INSERT` into `public.reactions` | RLS enforces group membership |
| Remove a reaction | Authenticated `DELETE` from `public.reactions` | RLS enforces ownership |
| Leaderboard and score reads | Direct `SELECT` via RLS | `current_score_events` view |
| Profile reads | Direct `SELECT` via RLS | `public.profiles` |

**Note — no remove-member function in V1.** Member removal is not implemented in V1. This is a V2 decision.

### Edge Functions Required

| Function | Why service-role access is needed |
|---|---|
| `upload-authorize` | Generate signed upload URL for the private `game-media` bucket; create upload session record |
| `upload-complete` | Read original from private storage, re-encode, strip EXIF/GPS, delete original, write display object to unique path, finalize via V2 wrapper |
| `media-serve` | Proxy re-encoded image from private storage; fetch privileged storage key |
| `scheduled-close` | Cron-triggered; locks and reveals challenges past `deadline_at`; no user JWT |
| `account-delete-complete` | Delete storage objects, call V2 deletion wrappers, delete `auth.users` via Admin API |

### Background Workers (also required; deployed separately)

| Worker | Purpose |
|---|---|
| `upload-cleanup-worker` | Delete storage objects for expired, superseded, failed, and orphaned upload sessions |
| `deletion-recovery-worker` | Resume partially-complete account deletions whose state was advanced server-side before a failure |

### Deferred to V2

| Operation | Reason |
|---|---|
| Auto-reveal when all eligible players have submitted | Requires a database trigger on `guess_attempts` — V2 migration |
| Push notifications | External service (APNs); no V1 infrastructure |
| Sign in with Apple provider configuration | Auth provider setting, not an Edge Function |
| Member removal | No V1 function; V2 decision |

---

## Section 2 — V2 Migration Decision: Upload Session Infrastructure

V1 contains no upload-session table and no processing-idempotency infrastructure. The `upload-authorize` and `upload-complete` contracts cannot be implemented from V1 alone.

**Decision: add a V2 migration** before implementing the upload Edge Functions.

### 2.1 Upload Session State Machine

```
pending → processing → sanitized → complete   (happy path)
pending → superseded                           (new authorize call supersedes prior pending session)
pending → expired                              (cleanup worker; session never picked up)
pending | processing | sanitized → failed      (any step fails unrecoverably)
```

State semantics:

- `pending`: session created, signed URL issued, upload not yet started or not yet confirmed
- `processing`: `upload-complete` has begun processing the uploaded file
- `sanitized`: re-encoding complete, original confirmed deleted, display object written at its unique path, display path recorded in the session row — finalization not yet committed
- `complete`: DB finalization committed; `media_objects`, `media_storage_keys`, and `challenges.media_object_id` all set
- `superseded`: a later `upload-authorize` call was made for the same challenge; this session is abandoned
- `expired`: session reached `expires_at` without progressing to `processing`; cleanup worker will delete its storage object
- `failed`: unrecoverable error at any step; if a display object was written it is recorded in the session row for cleanup worker removal

### 2.2 V2 Table Schema Requirements

The V2 upload session table must record:
- `session_id` (UUID, primary key) — stable identifier for this session
- `upload_token_hash` (text) — SHA-256 hex hash of the secret upload token; the token itself is not stored
- `challenge_id` (UUID FK)
- `uploader_id` (UUID FK → `auth.users.id`)
- `original_storage_path` (text) — `challenges/{challenge_id}/originals/{session_id}`
- `display_storage_path` (text, nullable) — set when status reaches `sanitized`; `challenges/{challenge_id}/displays/{session_id}.webp`
- `content_type` (text)
- `declared_size_bytes` (bigint)
- `expires_at` (timestamptz)
- `status` — one of the seven states above
- `failed_reason` (text, nullable) — sanitized error code only; no storage paths, no raw error text

### 2.3 V2 Function Requirements

The V2 migration must include public SECURITY DEFINER functions, granted EXECUTE only to `service_role`:

- `public.create_upload_session(challenge_id, uploader_id, token_hash, content_type, declared_size, expires_at)` → `session_id, original_storage_path` — enforces: poster identity, draft state, creates session row with status `pending`, supersedes any prior pending session for this challenge (records them as `superseded`)
- `public.advance_upload_session_processing(session_id, uploader_id)` → `original_storage_path` — enforces: uploader identity, status `pending`, not expired; transitions to `processing`
- `public.advance_upload_session_sanitized(session_id, display_storage_path)` → void — transitions to `sanitized`; records `display_storage_path`
- `public.finalize_upload_session(session_id)` → `media_object_id` — atomically in a single transaction: inserts `public.media_objects` (`status = 'ready'`), inserts `private.media_storage_keys` (using `original_storage_path` and `display_storage_path` from the session), sets `challenges.media_object_id`, transitions session to `complete`; idempotent: if already `complete`, returns existing `media_object_id`
- `public.fail_upload_session(session_id, sanitized_error_code text)` → void — transitions to `failed`; records `failed_reason`
- `public.get_resumable_upload_session(session_id, uploader_id)` → session row — returns session if status is `sanitized` and belongs to uploader; used by `upload-complete` for retry path
- `public.get_cleanup_sessions(older_than timestamptz)` → `TABLE(session_id, original_storage_path, display_storage_path, status)` — returns sessions in `expired`, `superseded`, `failed` states for cleanup worker

These functions enforce all business rules themselves. Edge Functions must not re-implement authorization, state checks, or transition logic.

The V2 migration goes through the full three-party governance cycle as a separate step (Step 25) before any upload Edge Function is implemented.

---

## Section 3 — Cross-Cutting Contracts

These rules apply to every Edge Function and worker without exception.

### 3.1 Authentication

**`verify_jwt` setting:**
- All Edge Functions except `scheduled-close` deploy with `verify_jwt = true`. Gateway JWT rejection returns its own `401` before the function runs; that response does not follow the Forkensics error envelope. This is documented here and does not require handling inside the function.
- `scheduled-close` deploys with `verify_jwt = false`. It uses a separate cron credential stored in Supabase Vault.

**Standard gate (all user-facing functions except `account-delete-complete`):**
After gateway JWT verification:
1. Extract `sub` claim (user UUID). If absent or empty → `401 FK_UNAUTHENTICATED`.
2. Confirm a row exists in `public.profiles` where `id = sub` AND `is_active = true` AND `onboarding_complete = true`. If not → `403 FK_FORBIDDEN`.

**`account-delete-complete` gate (carve-out):**
After gateway JWT verification:
1. Extract `sub` claim (user UUID). If absent or empty → `401 FK_UNAUTHENTICATED`.
2. Confirm a row exists in `public.profiles` where `id = sub`. Any `is_active` or `onboarding_complete` value is permitted. Rationale: deactivated or partially-onboarded users must be able to exercise their deletion right.

### 3.2 Authorization

Authorization is enforced at two layers:

- **User-JWT layer:** Reads that act on behalf of a user use a Supabase client initialized with the user's JWT. RLS applies normally.
- **Administrative client layer:** Operations requiring service-role access use the administrative Supabase client (initialized with the service-role key). This client connects through PostgREST as the `service_role` role. It is used only to call public, service-role-only V2 wrapper functions, to generate signed storage URLs, to read/write/delete storage objects, and to call the Admin API for user deletion.

An Edge Function must never use the administrative client to perform a read the user is not authorized to perform.

### 3.3 Privileged Database Access Pattern

Edge Functions that need privileged database operations use public SECURITY DEFINER V2 wrapper functions called via the administrative Supabase client. These functions are GRANT EXECUTE TO service_role only.

`SUPABASE_DB_URL` (direct PostgreSQL connection) is **not** used by Edge Functions. The `private` schema is never exposed through the PostgREST API. Privileged access is mediated exclusively by SECURITY DEFINER wrapper functions that enforce their own invariants.

This resolves the ambiguity of which database role a direct connection would use, and eliminates the need for `SET LOCAL ROLE` or any connection-level privilege escalation in Edge Function code.

### 3.4 Existence and Authorization Probing

For any challenge-scoped operation: if the challenge does not exist or if the caller is not authorized to see it, return `404 FK_NOT_FOUND` — not `403`. This prevents callers from inferring challenge existence from error codes.

### 3.5 Error Response Format

All errors produced by Edge Functions return JSON with `Content-Type: application/json`:

```json
{
  "error": {
    "code": "FK_ERROR_CODE",
    "message": "Human-readable description"
  }
}
```

Gateway-produced errors may not follow this format. That exception is documented here.

### 3.6 Standard Error Codes

| HTTP | Code | Meaning |
|---|---|---|
| 400 | `FK_INVALID_INPUT` | Missing or malformed request field |
| 400 | `FK_INVALID_CONTENT_TYPE` | File type not `image/jpeg` or `image/webp` (MIME-sniffed, not client-declared) |
| 400 | `FK_FILE_TOO_LARGE` | Actual stored file exceeds 10 MB |
| 400 | `FK_INVALID_TOKEN` | Upload token missing, malformed, expired, superseded, or already used |
| 401 | `FK_UNAUTHENTICATED` | Missing or invalid sub claim after gateway verification |
| 403 | `FK_FORBIDDEN` | Valid JWT; caller does not meet `is_active` + `onboarding_complete` requirements |
| 404 | `FK_NOT_FOUND` | Resource does not exist or caller is not authorized to see it |
| 409 | `FK_WRONG_STATE` | Challenge is not in the required state for this operation |
| 422 | `FK_PROCESSING_FAILED` | Re-encoding or storage operation failed unrecoverably |
| 429 | `FK_RATE_LIMITED` | Too many requests |
| 500 | `FK_INTERNAL` | Unexpected server error — no internal detail exposed to caller |

`409 FK_ALREADY_COMPLETE` is not used. A completed idempotent operation returns `200` with `"already_complete": true`.

### 3.7 Idempotency

All functions that write state must be safe to retry.

- A retry of a completed operation returns `200` with the original result and `"already_complete": true`.
- A retry of an in-progress operation returns `202` with `"status": "processing"`.
- A retry of a failed operation re-attempts from the beginning.
- Expired, superseded, or unknown tokens return `400 FK_INVALID_TOKEN` — not `404`.

Idempotency is derived from stable inputs (session ID, challenge ID, user ID). No client-supplied idempotency headers are required.

### 3.8 Logging

Logs must **never** contain:
- Canonical dish name, restaurant name, or city
- Storage paths, storage keys, or signed URLs
- EXIF or GPS data from any image
- Secret keys, JWTs, upload tokens, or Vault credentials
- Raw storage error messages
- Any content from `challenge_secrets`

Logs must contain:
- Timestamp (ISO 8601)
- Function name
- Request ID (generated per invocation)
- User UUID (for authenticated functions)
- Challenge UUID (where applicable)
- Outcome: `success` | `error`
- Sanitized error code on failure — not the raw error message and not storage paths

### 3.9 Operational Failure Safety

If any Edge Function or worker fails, ordinary gameplay continues:

- `upload-authorize` / `upload-complete` failure → challenge stays in `draft`; poster retries when ready
- `media-serve` failure → image unavailable; game UI shows placeholder; guessing and scoring unaffected
- `scheduled-close` failure → challenges remain open past `deadline_at` until next successful cron run; no data corruption; a challenge that misses one window is locked and revealed on the next successful run
- `account-delete-complete` storage failure → user can still authenticate and retry; storage objects are not abandoned
- Worker failure → state is recoverable on next run; no data corruption

### 3.10 Atomicity Boundary

Only database operations inside a single PostgreSQL transaction are atomic. Storage operations (S3-compatible) and PostgreSQL operations are not atomic with respect to each other. Any multi-step sequence that spans both storage and the database requires explicit compensating cleanup on failure. Each function contract below specifies its compensating actions.

---

## Section 4 — Function Contracts

### 4.1 `upload-authorize`

**Purpose:** Record a new upload session and issue a time-limited signed URL so the iOS client can upload directly to the `game-media` private bucket.

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
2. `content_type` is `image/jpeg` or `image/webp` — otherwise `400 FK_INVALID_CONTENT_TYPE`.
3. `declared_size_bytes` ≤ 10,485,760 — otherwise `400 FK_FILE_TOO_LARGE`.

**Action:**
1. Generate a secret upload token (cryptographically random; 128 bits minimum). Compute its SHA-256 hash.
2. Call `public.create_upload_session(challenge_id, user_id, token_hash, content_type, declared_size_bytes, now() + 5 minutes)` via administrative client. This function: verifies poster identity and draft state; generates a `session_id`; records `original_storage_path = challenges/{challenge_id}/originals/{session_id}`; supersedes any prior `pending` session for this challenge; returns `session_id` and `original_storage_path`. If the function raises → `409 FK_WRONG_STATE` or `404 FK_NOT_FOUND` as appropriate.
3. Generate a signed upload URL for `session.original_storage_path` in `game-media`, 5-minute expiry (administrative client). The signed URL is generated after the session row is committed.
4. Return the signed URL and upload token to the client. The `session_id` is not returned to the client — it is an internal identifier.

**Response `200 OK`:**
```json
{
  "signed_url": "<url>",
  "upload_token": "<secret token — not the hash>",
  "expires_at": "<ISO 8601>"
}
```

**Idempotency:** Not idempotent. Each call supersedes the prior pending session and produces a new `session_id`, storage path, and signed URL.

**Logging:** `challenge_id`, `user_id`, `content_type`, `session_id` (internal only), outcome. NOT the signed URL, upload token, or storage path.

---

### 4.2 `upload-complete`

**Purpose:** Validate the uploaded file, re-encode with EXIF/GPS removal, delete the original before recording, atomically finalize the media object via V2 wrapper.

**Prerequisite:** V2 upload-session infrastructure (Section 2).

**Method / Path:** `POST /upload-complete`

**`verify_jwt`:** `true`

**Request body:**
```json
{
  "upload_token": "<secret token>"
}
```

**Authorization checks (in order):**
1. Profile active + onboarding complete (Section 3.1 standard gate).
2. Compute SHA-256 hash of `upload_token`. Look up session by `token_hash`. Session must exist, belong to the authenticated user, not be expired, and be in `pending` or `sanitized` state — otherwise `400 FK_INVALID_TOKEN`.

**Idempotency branch:**
- Session status `sanitized`: skip to step 7 (finalization retry path).
- Session status `processing`: return `202 {"status": "processing"}` — another request is in progress.
- Session status `complete`: return `200 {"status": "ready", "media_object_id": "<uuid>", "already_complete": true}`.
- Any other status: `400 FK_INVALID_TOKEN`.

**Happy path (session status `pending`):**

1. Call `public.advance_upload_session_processing(session_id, user_id)` (administrative client). Function verifies identity, checks not expired, transitions to `processing`. Returns `original_storage_path`. If transition fails → `400 FK_INVALID_TOKEN`.
2. Read original file from `session.original_storage_path` (administrative client). If absent → call `public.fail_upload_session(session_id, 'FK_NOT_FOUND')`; return `404 FK_NOT_FOUND`.
3. Sniff actual MIME type from file bytes — do not trust `session.content_type` or any client claim. If not `image/jpeg` or `image/webp` → delete original from storage; call `public.fail_upload_session(session_id, 'FK_INVALID_CONTENT_TYPE')`; return `400 FK_INVALID_CONTENT_TYPE`.
4. Confirm actual stored size ≤ 10,485,760 bytes. If over → delete original from storage; call `public.fail_upload_session(session_id, 'FK_FILE_TOO_LARGE')`; return `400 FK_FILE_TOO_LARGE`.
5. Re-encode to WebP; strip all EXIF, GPS, and embedded metadata. If re-encoding fails → delete original from storage; call `public.fail_upload_session(session_id, 'FK_PROCESSING_FAILED')`; return `422 FK_PROCESSING_FAILED`.
6. Write re-encoded file to `challenges/{challenge_id}/displays/{session_id}.webp` (administrative client). If write fails → delete original from storage; call `public.fail_upload_session(session_id, 'FK_PROCESSING_FAILED')`; return `422 FK_PROCESSING_FAILED`.
7. Delete original from `session.original_storage_path` (administrative client). Retry up to 2 times with brief backoff.
   - If all attempts fail: delete the display object from step 6; call `public.fail_upload_session(session_id, 'FK_PROCESSING_FAILED')`; return `422 FK_PROCESSING_FAILED`.
8. Call `public.advance_upload_session_sanitized(session_id, 'challenges/{challenge_id}/displays/{session_id}.webp')` (administrative client). This records the display path in the session row and transitions to `sanitized`. If this call fails: the original has already been deleted and the display object exists. Call `public.fail_upload_session` if possible; log `session_id` for recovery worker. Return `500 FK_INTERNAL`.

**Finalization (step 7 of happy path, or retry from `sanitized`):**

9. Call `public.finalize_upload_session(session_id)` (administrative client). This atomically: inserts `public.media_objects`, inserts `private.media_storage_keys` (using `original_storage_path` and `display_storage_path` from the session row), sets `challenges.media_object_id`, transitions session to `complete`. Returns `media_object_id`. If already `complete`, returns existing `media_object_id` (idempotent).
   - If finalization fails: session remains `sanitized`. Original is already deleted; display object exists at `session.display_storage_path`. Return `500 FK_INTERNAL`. Client may retry `upload-complete` with the same token — next attempt will reach the `sanitized` branch and retry finalization directly without needing the original.

**Response `200 OK`:**
```json
{
  "media_object_id": "<uuid>",
  "status": "ready"
}
```

**Abandoned sanitized sessions:** The upload-cleanup-worker (Section 4.6) scans for sessions in `sanitized` state older than a threshold, deletes their display objects from storage, and marks them `failed`. This handles cases where the client never retried.

**Logging:** `challenge_id`, `session_id` (internal), actual MIME type, actual stored size, re-encoding outcome, original-deletion outcome. NOT storage paths, upload token, or token hash.

---

### 4.3 `media-serve`

**Purpose:** Proxy the re-encoded challenge image to an authorized viewer. Never expose storage paths or signed URLs to the client.

**Method / Path:** `GET /media/{challenge_id}`

**`verify_jwt`:** `true`

**Authorization:**
1. Profile active + onboarding complete (Section 3.1 standard gate).
2. Query `public.challenges` using the **user-JWT client**: `SELECT id, media_object_id FROM public.challenges WHERE id = $challenge_id`. RLS applies automatically. If no row is returned → `404 FK_NOT_FOUND`. This single query enforces all visibility rules, including the `posted_at IS NOT NULL` rule that restricts draft challenges to the poster. No manual state or membership check is required in function code.
3. If `media_object_id` is null → `404 FK_NOT_FOUND`.

**Action:**
1. Call `public.get_media_storage_key(media_object_id)` via administrative client. This V2 wrapper returns `re_encoded_storage_key` from `private.media_storage_keys` for the given `media_object_id`, only if `media_objects.status = 'ready'`. If no result → `404 FK_NOT_FOUND`.
2. Read the file at `re_encoded_storage_key` from `game-media` (administrative client). Never construct a storage path from `challenge_id` — use the key as recorded.
3. Stream bytes to client with `Content-Type: image/webp`.

**Response `200 OK`:** Binary image stream (`image/webp`)

**Cache headers:** `Cache-Control: private, max-age=3600`

**Logging:** `challenge_id`, `user_id`, outcome. NOT the storage key or path.

---

### 4.4 `scheduled-close`

**Purpose:** Lock and reveal all challenges whose `deadline_at` has passed.

**Trigger:** Supabase pg_cron, every 2 minutes.

**`verify_jwt`:** `false`

**Authentication:** A cron-specific credential stored in Supabase Vault. On each invocation, the function reads the credential and compares it to the `Authorization` header value. Any request without the matching credential → `401`. This credential is separate from all user-facing keys.

**Action:**

Pass 1 — lock active challenges past deadline:
1. Query `public.challenges WHERE state = 'active' AND deadline_at <= now()` using administrative client.
2. For each: call `public.lock_challenge(uuid)` (administrative client). `lock_challenge` raises if the challenge is not in `active` state — catch per-row, log challenge ID and sanitized error code, continue batch.

Pass 2 — reveal locked challenges:
1. Query `public.challenges WHERE state = 'locked'` (administrative client). Revealed and cancelled challenges are excluded by the `WHERE state = 'locked'` predicate — they are never returned and require no per-row handling.
2. For each: call `private.reveal_challenge_service(uuid)` via its V2 public wrapper (administrative client). Catch per-row errors — log and continue batch.

The two-pass structure ensures no locked challenge is stranded if a prior cron run failed mid-batch.

**Response `200 OK`:**
```json
{
  "locked_count": 3,
  "revealed_count": 3,
  "skipped_count": 0,
  "errors": [
    { "challenge_id": "<uuid>", "pass": "lock" | "reveal", "error_code": "<sanitized>" }
  ]
}
```

**Idempotency:** Both passes are safe to run multiple times. `lock_challenge` raises on non-`active` challenges (caught per-row). The reveal wrapper raises on non-`locked` challenges (caught per-row). A previously locked-and-revealed challenge does not re-appear in either pass.

**Logging:** `locked_count`, `revealed_count`, `skipped_count`, per-row error codes and challenge IDs. NOT challenge content, canonical answers, or guess data.

---

### 4.5 `account-delete-complete`

**Purpose:** Complete account deletion by removing storage objects, finalizing the database deletion record, and deleting the `auth.users` entry.

**Method / Path:** `POST /account-delete-complete`

**`verify_jwt`:** `true`

**Request body:** *(none — caller identity comes from the JWT)*

**Authentication:** Carve-out gate (Section 3.1). Valid JWT + existing profile row required; `is_active` and `onboarding_complete` are not checked.

**V1 deletion status states (from V1 functions):**
- `pending` — initial state after `prepare_account_deletion` is called and profile is anonymized
- `database_prepared` — after profile anonymization is confirmed; this is the state in which `account-delete-complete` operates
- `auth_deleted` — after `mark_auth_deleted` is called
- `complete` — terminal; after `mark_storage_cleaned` transitions the record to final state

**Action (in order):**

1. Confirm deletion record for this user is in `database_prepared` state via `public.get_deletion_status(user_id)` (V2 wrapper, administrative client). If already `complete` → cannot return `200 already_complete` because the user's JWT is already void if auth was deleted; log anomaly and return `500 FK_INTERNAL`. If state is `auth_deleted` → the recovery worker handles this; return `409 FK_WRONG_STATE`.
2. Call `private.get_storage_keys_for_deletion(user_id)` via its V2 public wrapper (administrative client). Returns one distinct row per physical storage key (`media_object_id`, `storage_key`).
3. For each storage key: delete the object from `game-media` (administrative client). Track per-key success and failure.
4. If any storage deletion fails:
   - Call `private.record_deletion_failure(user_id, 'FK_PROCESSING_FAILED')` via V2 wrapper. Only the sanitized error code is passed — not raw storage errors or paths.
   - Return `422 FK_PROCESSING_FAILED`. User can still authenticate and retry.
   - **Stop here.** Do not delete the auth account.
5. Delete the `auth.users` row for this user (Admin API, administrative client). If this fails → return `500 FK_INTERNAL`. The user can still authenticate and retry.
6. Call `public.mark_auth_deleted(user_id)` via administrative client. If this fails: the auth user has already been deleted and the JWT is now void. The client cannot retry. Log `session_id` and `user_id` for recovery worker. Return `500 FK_INTERNAL`.
7. Call `public.mark_storage_cleaned(user_id)` via administrative client. This transitions the deletion record to `complete`. If this fails: same situation as step 6. Log for recovery worker. Return `500 FK_INTERNAL`.
8. Return `200 OK`.

**Response `200 OK`:**
```json
{ "status": "complete" }
```

**Client retry after auth deletion:** Once step 5 (auth deletion) completes, the user's JWT is void. The gateway will reject any subsequent request with `401` before the function runs. The client cannot retry steps 6 or 7 — that recovery is handled exclusively by the deletion-recovery-worker (Section 4.7).

**Logging:** `user_id` (before deletion), `storage_key_count`, `deleted_count`, `failed_count`, deletion record state at each step. NOT storage paths, key values, or file content.

---

### 4.6 `upload-cleanup-worker`

**Purpose:** Delete orphaned storage objects for upload sessions that will never reach `complete`, and transition their session records to `failed`.

**Trigger:** Supabase pg_cron, every 15 minutes.

**Authentication:** Same pattern as `scheduled-close` — cron credential from Vault.

**Action:**
1. Call `public.get_cleanup_sessions(older_than = now() - 15 minutes)` (administrative client). Returns sessions in `expired`, `superseded`, `failed`, and `sanitized` (abandoned) states, with their `original_storage_path` and `display_storage_path`.
2. For each session:
   a. If `original_storage_path` is set and status indicates the original may still exist (`expired`, `superseded`): attempt to delete from storage (administrative client). Log outcome.
   b. If `display_storage_path` is set (status is `sanitized` or `failed` with a display path): attempt to delete from storage. Log outcome.
   c. Call `public.fail_upload_session(session_id, 'FK_EXPIRED')` or appropriate code to mark the record (if not already `failed`).
3. Return summary.

**Idempotency:** Deletion of an already-deleted storage object returns success (no-op). Session records already in `failed` are excluded by the V2 function.

**Logging:** `session_count`, `objects_deleted`, `objects_failed`. NOT storage paths.

---

### 4.7 `deletion-recovery-worker`

**Purpose:** Resume account deletions that were partially completed server-side and cannot be retried by the client because the auth account has been deleted.

**Trigger:** Supabase pg_cron, every 5 minutes.

**Authentication:** Cron credential from Vault (same pattern).

**Action:**

Scan 1 — `database_prepared` records where auth may have been deleted externally:
1. Query deletion records in `database_prepared` state older than 10 minutes (administrative client).
2. For each: check whether `auth.users` row still exists (Admin API). If auth still exists → skip (client can still retry). If auth is gone: call `public.mark_auth_deleted(user_id)` → status becomes `auth_deleted`. Continue to Scan 2 for these records.

Scan 2 — `auth_deleted` records awaiting storage cleanup:
1. Query deletion records in `auth_deleted` state (administrative client).
2. For each: call `public.mark_storage_cleaned(user_id)` (V2 wrapper). This transitions record to `complete`.
3. If `mark_storage_cleaned` fails → log sanitized error, leave record in `auth_deleted`, will retry next run.

**Response `200 OK`:**
```json
{
  "database_prepared_scanned": 0,
  "auth_confirmed_deleted": 0,
  "auth_deleted_completed": 0,
  "errors": []
}
```

**Idempotency:** All V1 deletion state-transition functions are idempotent for their target state.

**Deployment gate:** `deletion-recovery-worker` must be deployed together with `account-delete-complete`, not after. A deployment gate covers both.

**Logging:** Counts only. NOT user IDs, storage paths, or error details.

---

## Section 5 — Contract Test Requirements

### 5.1 Local Contract Tests

Each function gets a dedicated contract test file. Tests must cover:

**Authentication and authorization:**
- Missing JWT → `401` (gateway or function — document which for each)
- Expired JWT → `401`
- Standard gate: valid JWT, `is_active = false` → `403 FK_FORBIDDEN`
- Standard gate: valid JWT, `onboarding_complete = false` → `403 FK_FORBIDDEN`
- Carve-out gate (`account-delete-complete`): `is_active = false` → allowed
- Carve-out gate: `onboarding_complete = false` → allowed

**Existence and probing:**
- Nonexistent `challenge_id` → `404 FK_NOT_FOUND`
- Valid `challenge_id`, caller not in group → same `404 FK_NOT_FOUND` (body identical — no probing)

**Input validation:**
- Missing required field → `400 FK_INVALID_INPUT`
- Client-declared `content_type` valid but MIME-sniffed bytes are different → `400 FK_INVALID_CONTENT_TYPE`
- Actual stored file exceeds 10 MB → `400 FK_FILE_TOO_LARGE`

**Upload token lifecycle:**
- Expired upload token → `400 FK_INVALID_TOKEN`
- Superseded token (new `upload-authorize` issued) → `400 FK_INVALID_TOKEN`
- Unknown token → `400 FK_INVALID_TOKEN`
- Token for already-`complete` session → `200 {"status":"ready","already_complete":true}`
- Token for `processing` session → `202 {"status":"processing"}`
- Token for `sanitized` session → finalization retried; `200` on success

**Upload path uniqueness:**
- Two `upload-authorize` calls produce different `session_id` values and different storage paths
- `upload-complete` reads `original_storage_path` from session row; does not construct path from `challenge_id`
- Display path is unique per session (`challenges/{challenge_id}/displays/{session_id}.webp`)

**Original deletion and sanitized state:**
- Re-encoding produces valid WebP output
- Original is deleted and confirmed absent before `sanitized` state is set
- Original deletion failure: display object also deleted; session marked `failed`; `422` returned
- Sanitized state records display path; finalization reads path from session, not from a constructed pattern

**V2 function authority:**
- `create_upload_session` rejects non-poster callers (not just Edge Function pre-check)
- `create_upload_session` rejects non-`draft` challenge state
- `advance_upload_session_processing` rejects expired sessions
- `finalize_upload_session` is atomic and idempotent

**`media-serve`:**
- RLS on `public.challenges` restricts draft challenges to the poster — no additional check in function code
- Challenge in `active` state, group member → `200`
- Challenge in `draft` state, poster → `200`
- Challenge in `draft` state, group member (not poster) → `404` (RLS excludes the row)
- `media_object_id` null → `404`
- `re_encoded_storage_key` served — not a reconstructed `display.webp` path

**`scheduled-close`:**
- Request without Vault credential → `401`
- Challenge past `deadline_at` in `active` → locked in Pass 1; revealed in Pass 2
- Challenge already `locked` (prior run) → does not appear in Pass 1; revealed in Pass 2
- Challenge already `revealed` → excluded by `WHERE state = 'locked'` in Pass 2; no per-row handling needed
- Per-row failure in Pass 1 does not abort Pass 2

**`account-delete-complete`:**
- Happy path: all storage deleted, auth deleted, record reaches `complete` → `200`
- Storage failure: `422`; auth account not deleted; user can still authenticate and retry
- Auth deletion failure: `500`; user can authenticate and retry
- `mark_auth_deleted` failure after auth deletion: `500`; JWT now void; recovery worker handles
- `is_active = false` → allowed (carve-out)
- `onboarding_complete = false` → allowed (carve-out)
- Only sanitized code passed to `record_deletion_failure` — no raw error text

**`deletion-recovery-worker`:**
- `database_prepared` record, auth still exists → skipped
- `database_prepared` record, auth gone → `mark_auth_deleted` called; transitions to `auth_deleted`
- `auth_deleted` record → `mark_storage_cleaned` called; transitions to `complete`
- Worker is idempotent across runs

**Error format:**
- All function-produced errors match `{ "error": { "code": "FK_...", "message": "..." } }`
- Logs contain no storage paths, upload tokens, or raw error messages

### 5.2 Production Verification

After each function is deployed to `forkensics-prod`, non-mutating verification checks confirm:
- Function endpoint is reachable
- Unauthenticated request → `401`
- Authenticated request with intentionally invalid input → appropriate `400`

These checks create no data and make no state changes. They are not the same as the local smoke test suite. The local smoke test suite is run only against `forkensics-dev`.

### 5.3 What Contract Tests Must Never Do

- Call `reveal_challenge` or its service wrapper on a real challenge
- Assert on or log canonical answers, restaurant names, or city values
- Leave test data in `forkensics-prod`
- Hard-code credentials — use environment variables or test-only Vault entries
- Pass raw storage errors or paths into `record_deletion_failure`

---

## Section 6 — Deployment Sequence

Each function is deployed one at a time. Each deployment is gated on:
1. V2 migration complete and verified (for upload functions and any function using V2 wrappers)
2. Local contract tests pass
3. GPT review of the implementation
4. Bill approves with `APPROVED: Deploy {function-name}`
5. Deploy to `forkensics-dev`; local smoke tests pass against dev
6. Bill approves with `APPROVED: Deploy {function-name} to prod`
7. Deploy to `forkensics-prod`; production verification checks pass (non-mutating only)

**Order:**
1. V2 migration (upload-session infrastructure + all service-role-only V2 wrappers) — separate Step 25
2. `upload-authorize`
3. `upload-complete` + `upload-cleanup-worker` (deployed together)
4. `media-serve`
5. `scheduled-close` (requires Vault cron credential setup first)
6. `account-delete-complete` + `deletion-recovery-worker` (deployed together; recovery worker must be deployed before or simultaneously)

---

## Section 7 — Out of Scope for Step 24

- Any TypeScript or Deno code
- Any `supabase functions deploy` command
- V2 migration content (covered in Step 25)
- Push notifications
- Sign in with Apple configuration
- Any iOS application code
- Member removal (no V1 function)
- Full worker contracts beyond what is specified in Sections 4.6 and 4.7

---

## Success Criteria for Step 24

- [ ] Decision matrix agreed: cancel/apply_correction permit poster or group owner; reason nullable; comments and reactions use correct V1 mechanisms
- [ ] V2 migration decision agreed: upload-session state machine, per-session storage paths, token hash storage, V2 functions enforce own invariants, cleanup worker required
- [ ] Upload-authorize contract agreed: session created before signed URL; `session_id` internal only; token never stored
- [ ] Upload-complete contract agreed: processing → sanitized → complete states; display path unique per session; original confirmed deleted before sanitized state; finalization retryable from sanitized; correct idempotency responses
- [ ] `media-serve` contract agreed: RLS enforces visibility automatically; `re_encoded_storage_key` fetched via V2 wrapper; no path reconstruction
- [ ] Privileged access pattern agreed: administrative Supabase client only; V2 public wrappers; no `SUPABASE_DB_URL` direct connection; `private` schema not exposed
- [ ] `scheduled-close` contract agreed: two-pass design; Pass 2 uses `WHERE state = 'locked'`; per-row errors logged and batch continues
- [ ] Account deletion contract agreed: correct V1 status names; recovery worker has full contract; client retry not possible after auth deletion; only sanitized codes to `record_deletion_failure`
- [ ] Cleanup worker and recovery worker deployment gating agreed
- [ ] Operational failure safety agreed (not "AI failure safety")
- [ ] Production verification defined as non-mutating reachability/auth checks only
- [ ] No Edge Function code written before approval
