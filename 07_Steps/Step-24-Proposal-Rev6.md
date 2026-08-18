# Step 24 Proposal — Rev 6 — Edge Function Architecture and Contracts

**Status:** Pending review (Claude → Codex/GPT → Bill approval)
**Governance gate:** Bill must type `APPROVED: Step 24 — Edge Function Architecture and Contracts` before any Edge Function code is written.

**Scope:** Architecture decisions and binding contracts only. No TypeScript, no Deno code, no deployment. Implementation follows in separate per-function steps.

**Changes from Rev 5:**
1. One active upload enforced per challenge: `create_upload_session` rejects (not supersedes) if any session for the same challenge is in `pending`, `processing`, or `sanitized` state. Photo replacement for challenges already in `draft` with a completed photo is handled atomically in `finalize_upload_session` — the old `media_objects` row is marked `superseded` in the same transaction; the upload-cleanup-worker deletes its storage object. The superseded-upload transition (`pending → superseded`) is removed; `superseded` now applies only to media objects.
2. Worker claims made persistent: upload session table adds `cleanup_claim_token`, `cleanup_claimed_at`, `cleanup_claim_expires_at`, and `status_changed_at`. `claim_cleanup_sessions` issues a claim token and stores it; `mark_session_cleaned` verifies the token before accepting the transition. Stale thresholds bound: `pending` after `expires_at + 60 s`; `processing` after `processing_lease_expires_at`; `sanitized` after `processing_lease_expires_at + 60 minutes`; `failed`/`expired` immediately. Claim expiry is 15 minutes for upload sessions. The deletion-recovery worker gets equivalent protection through a V2 `deletion_recovery_claims` table with `claim_deletion_recovery_records`, `complete_deletion_recovery`, and `fail_deletion_recovery` functions; claim expiry is 10 minutes.
3. Every public wrapper explicitly named: all functions that Edge Functions or workers may call are enumerated in Section 2.3. No direct administrative reads of upload-session or private deletion records are permitted as an undocumented alternative.
4. Unfinished uploads included in account deletion: `account-delete-complete` gathers pending upload session storage paths (via `get_pending_upload_storage_paths`) alongside established media keys; deletes all storage objects in a unified pass; then marks all active sessions failed (`fail_all_pending_sessions_for_user`) before proceeding to auth deletion. Both scans of the deletion-recovery-worker perform the same unified gathering and deletion. New V2 functions added: `get_pending_upload_storage_paths`, `fail_all_pending_sessions_for_user`, `get_superseded_media_to_clean`, `mark_superseded_media_cleaned`.

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
| Manually reveal a challenge | `public.reveal_challenge(uuid)` | Poster only; executor enforces; canonical answer readable per RLS after reveal |
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
| `upload-complete` | Read original from private storage, re-encode, strip EXIF/GPS, delete original, write display object, finalize via V2 wrapper |
| `media-serve` | Proxy re-encoded image from private storage; fetch privileged storage key via V2 wrapper |
| `scheduled-close` | Cron-triggered; locks and reveals challenges past `deadline_at`; no user JWT |
| `account-delete-complete` | Call prepare wrapper, gather and delete all storage, call V2 deletion wrappers, delete `auth.users` via Admin API |

### Background Workers (required; deployed on the schedule in Section 6)

| Worker | Purpose |
|---|---|
| `upload-cleanup-worker` | Transition stale sessions, delete orphaned storage, handle superseded media, mark sessions `cleaned` |
| `deletion-recovery-worker` | Resume partially-complete account deletions after the client JWT is void |

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
pending → processing → sanitized → complete        (happy path)
pending → expired                                  (cleanup worker: stale pending past expires_at + 60s)
processing → failed                                (cleanup worker: processing_lease_expires_at elapsed)
pending | processing | sanitized → failed          (error in upload-complete)
expired | failed | sanitized(abandoned) → cleaned  (cleanup worker: storage confirmed deleted)
complete                                           (terminal; never cleaned)
```

Note: the `superseded` state is removed from upload sessions. `create_upload_session` now rejects rather than supersedes when an active session exists. The term "superseded" applies instead to replaced `media_objects` (Section 2.4).

State semantics:

- `pending`: session created, signed URL issued; upload not yet confirmed by `upload-complete`
- `processing`: `upload-complete` has claimed the session and begun processing
- `sanitized`: re-encoding complete, original confirmed deleted, display object written; DB finalization not yet committed
- `complete`: DB finalization committed; `media_objects`, `media_storage_keys`, and `challenges.media_object_id` all set; terminal
- `expired`: stale `pending` session past `expires_at + 60 seconds`; transitioned by cleanup worker
- `failed`: unrecoverable error; not retryable — client must call `upload-authorize` again
- `cleaned`: all associated storage objects confirmed deleted; terminal for all non-`complete` paths

### 2.2 Upload Session Table Schema

The upload session table must include all of the following columns:

- `session_id` (UUID, primary key) — generated at creation; used as part of storage paths
- `upload_token_hash` (text, unique) — SHA-256 hex of the secret upload token; token itself is never stored
- `challenge_id` (UUID FK → `public.challenges(id)`)
- `uploader_id` (UUID FK → `public.profiles(id)`) — references profiles, not `auth.users`; FK survives auth deletion
- `original_storage_path` (text, not null) — `challenges/{challenge_id}/originals/{session_id}`; set at creation
- `display_storage_path` (text, not null) — `challenges/{challenge_id}/displays/{session_id}.webp`; set at creation; deterministic from `session_id`; enables cleanup even if session never reached `sanitized`
- `content_type` (text, not null) — declared content type; actual MIME must match at processing time
- `declared_size_bytes` (bigint, not null)
- `expires_at` (timestamptz, not null) — session-level expiry for `upload-complete` to claim the session
- `processing_lease_expires_at` (timestamptz, nullable) — set when transitioning to `processing`; cleanup worker uses this to detect stale `processing` and abandoned `sanitized` sessions
- `status` (text, not null) — one of the seven states above
- `status_changed_at` (timestamptz, not null) — updated on every status transition; used for ordering and stale detection
- `failed_reason` (text, nullable) — sanitized error code only; no storage paths, no raw error text
- `cleanup_claim_token` (UUID, nullable) — issued by `claim_cleanup_sessions`; must be presented to `mark_session_cleaned`
- `cleanup_claimed_at` (timestamptz, nullable) — when the current claim was issued
- `cleanup_claim_expires_at` (timestamptz, nullable) — when the current claim expires (15 minutes after claim); expired claims may be re-issued by the next worker run
- `cleanup_completed_at` (timestamptz, nullable) — set when transitioning to `cleaned`

### 2.3 Deletion Recovery Table Schema

The deletion recovery worker must persist claims atomically. A V2 table is required because V1 deletion records cannot be modified:

`deletion_recovery_claims`:
- `user_id` (UUID, primary key, FK → `public.profiles(id)`) — one active claim per user at a time
- `scan_type` (text, not null) — `'database_prepared'` or `'auth_deleted'`; identifies what the worker was doing when it claimed the record
- `claim_token` (UUID, not null)
- `claimed_at` (timestamptz, not null)
- `claim_expires_at` (timestamptz, not null) — 10 minutes after `claimed_at`; expired claims may be re-issued

### 2.4 Superseded Media Objects

When a poster replaces a draft photo by completing a new upload, `finalize_upload_session` atomically:
- Sets `challenges.media_object_id` to the new `media_object_id`
- Sets the prior `media_objects.status = 'superseded'`

The upload-cleanup-worker scans for superseded media objects and deletes their `re_encoded_storage_key` (the display object in storage). The original is already gone — it was deleted during `upload-complete`. After confirming the storage deletion, the worker calls `mark_superseded_media_cleaned` which sets `media_objects.status = 'cleaned'`. This requires a V2 addition of a `'superseded'` and `'cleaned'` status to `media_objects.status`.

No challenge may be activated (`activate_challenge`) while its `media_object_id` points to a `media_objects` row with `status != 'ready'`. This is enforced by the `activate_challenge` executor function (requires a V2 addition to its validation logic).

### 2.5 V2 Function Catalog

The V2 migration must include all of the following public SECURITY DEFINER functions, each granted EXECUTE only to `service_role`. No other roles may execute them. No direct administrative reads of upload session rows or private deletion records are permitted — all access goes through these named wrappers.

#### Upload session — lifecycle

`public.create_upload_session(challenge_id uuid, uploader_id uuid, token_hash text, content_type text, declared_size bigint, expires_at timestamptz)`
→ `(session_id uuid, original_storage_path text, display_storage_path text)`
Enforces: poster identity, challenge in `draft` state, NO existing session in `pending/processing/sanitized` for this challenge (raises `FK_UPLOAD_IN_PROGRESS` if one exists). Generates `session_id`; records both storage paths and all required columns; sets `status_changed_at`. Does NOT supersede prior sessions — the client must wait for the active session to complete or fail.

`public.resolve_upload_session(token_hash text, uploader_id uuid)`
→ `(session_id uuid, status text, original_storage_path text, display_storage_path text, content_type text, processing_lease_expires_at timestamptz)`
Returns session data for the given token hash and uploader. Returns no row if the token does not exist or does not belong to the given uploader. Edge Functions call this to look up session state without constructing raw SQL against upload session rows. Does not modify state.

`public.advance_upload_session_processing(session_id uuid, uploader_id uuid, lease_duration interval)`
→ `(original_storage_path text, display_storage_path text)`
Enforces: uploader identity, `status = 'pending'`, `now() < expires_at`; transitions to `processing`; sets `processing_lease_expires_at = now() + lease_duration`; updates `status_changed_at`; returns both storage paths.

`public.advance_upload_session_sanitized(session_id uuid)`
→ void
Transitions `processing → sanitized`; updates `status_changed_at`. The display path is already recorded from creation — this function only confirms the state.

`public.finalize_upload_session(session_id uuid)`
→ `(media_object_id uuid, replaced_media_object_id uuid)`
Atomically in a single transaction: inserts `public.media_objects` (`status = 'ready'`); inserts `private.media_storage_keys` (using both storage paths from the session row); if `challenges.media_object_id` is null: sets it to the new `media_object_id`; if `challenges.media_object_id` is already set (photo replacement during draft): atomically sets `challenges.media_object_id` to the new `media_object_id` AND sets the prior `media_objects.status = 'superseded'`, returning its ID as `replaced_media_object_id`; transitions session to `complete`; updates `status_changed_at`. Idempotent: if session is already `complete`, returns existing `media_object_id` and `replaced_media_object_id` (null if no replacement occurred).

`public.fail_upload_session(session_id uuid, error_code text)`
→ void
Transitions to `failed`; records `failed_reason = error_code`; updates `status_changed_at`. Idempotent if already `failed`.

#### Upload session — cleanup

`public.claim_cleanup_sessions(worker_id text, claim_duration interval DEFAULT '15 minutes')`
→ `TABLE(session_id uuid, original_storage_path text, display_storage_path text, status text, cleanup_claim_token uuid)`
Atomically (single transaction, using `FOR UPDATE SKIP LOCKED` on eligible rows):
1. Transitions stale `pending` (where `expires_at + interval '60 seconds' < now()` AND not already claimed) → `expired`; updates `status_changed_at`.
2. Transitions stale `processing` (where `processing_lease_expires_at < now()` AND not already claimed) → `failed`; updates `status_changed_at`.
3. Selects all sessions in `expired`, `failed` states, plus `sanitized` sessions where `processing_lease_expires_at + interval '60 minutes' < now()` — where either no claim exists or `cleanup_claim_expires_at < now()`.
4. For each selected row: generates a new `cleanup_claim_token`; sets `cleanup_claimed_at = now()`, `cleanup_claim_expires_at = now() + claim_duration`.
5. Returns all claimed rows with their tokens.
Never selects `complete` or `cleaned` sessions.

`public.mark_session_cleaned(session_id uuid, claim_token uuid)`
→ void
Verifies `cleanup_claim_token = claim_token` and `cleanup_claim_expires_at > now()`. If claim is invalid or expired → raises an error; does not transition. If valid: transitions to `cleaned`; sets `cleanup_completed_at`; updates `status_changed_at`. Idempotent: if already `cleaned`, returns without error.

`public.fail_all_pending_sessions_for_user(user_id uuid)`
→ `TABLE(session_id uuid, original_storage_path text, display_storage_path text)`
Transitions all `pending`, `processing`, and `sanitized` sessions owned by `user_id` to `failed` (with `failed_reason = 'FK_ACCOUNT_DELETED'`). Returns the paths of all sessions transitioned, so the caller can delete their storage objects.

`public.get_pending_upload_storage_paths(user_id uuid)`
→ `TABLE(session_id uuid, original_storage_path text, display_storage_path text, status text)`
Returns `pending`, `processing`, and `sanitized` sessions owned by `user_id`, with their storage paths. Does not modify state. Used by `account-delete-complete` and the deletion-recovery-worker to find storage objects not yet associated with an established `media_objects` row.

#### Superseded media objects

`public.get_superseded_media_to_clean()`
→ `TABLE(media_object_id uuid, re_encoded_storage_key text)`
Returns all `media_objects` rows with `status = 'superseded'` joined to their `re_encoded_storage_key` from `private.media_storage_keys`. The original storage key is already deleted.

`public.mark_superseded_media_cleaned(media_object_id uuid)`
→ void
Sets `media_objects.status = 'cleaned'`. Idempotent.

#### Media lookup

`public.get_media_storage_key(media_object_id uuid)`
→ `(re_encoded_storage_key text)`
Returns `re_encoded_storage_key` from `private.media_storage_keys` for the given `media_object_id`, only if `media_objects.status = 'ready'`. Returns no row otherwise.

#### Challenge operations

`public.reveal_challenge_service_wrapper(challenge_id uuid)`
→ void
Public wrapper for `private.reveal_challenge_service(challenge_id)`. Called by `scheduled-close`.

#### Account deletion — wrappers for private functions

`public.prepare_account_deletion_wrapper(user_id uuid)`
→ `(status text)`
Wrapper for `private.prepare_account_deletion(user_id)`. Anonymizes the profile; creates or updates the deletion record. V1's internal `pending` state is transient — this function does not return until the observable status is `database_prepared`. Returns the resulting status. Idempotent: if the record is already `database_prepared`, returns `'database_prepared'` without modification. If the record is in a later state (`auth_deleted`, `complete`), returns that state without modification.

`public.get_deletion_storage_keys(user_id uuid)`
→ `TABLE(media_object_id uuid, storage_key text)`
Wrapper for `private.get_storage_keys_for_deletion(user_id)`. Returns one distinct row per physical storage key for established `media_objects`. Does NOT include upload session storage paths — those are retrieved separately via `get_pending_upload_storage_paths`.

`public.record_deletion_failure_wrapper(user_id uuid, error_code text)`
→ void
Wrapper for `private.record_deletion_failure(user_id, error_code)`. Accepts only sanitized error codes — no raw storage errors, no paths.

Note: `public.mark_auth_deleted(user_id)` and `public.mark_storage_cleaned(user_id)` are already public functions in V1. No additional wrappers are needed for these — they are called directly via the administrative Supabase client.

#### Deletion-recovery-worker — claim functions

`public.claim_deletion_recovery_records(worker_id text, scan_age_threshold interval DEFAULT '10 minutes', claim_duration interval DEFAULT '10 minutes')`
→ `TABLE(user_id uuid, scan_type text, claim_token uuid)`
Atomically claims deletion records needing recovery: selects `database_prepared` records older than `scan_age_threshold` and all `auth_deleted` records — where no claim exists in `deletion_recovery_claims` or the existing claim has expired. For each: upserts a row in `deletion_recovery_claims` with a new `claim_token`, `claimed_at = now()`, `claim_expires_at = now() + claim_duration`. Returns claimed records with their tokens.

`public.complete_deletion_recovery(user_id uuid, claim_token uuid, scan_type text)`
→ void
Verifies the claim token in `deletion_recovery_claims` matches and has not expired. For `scan_type = 'database_prepared'`: calls `mark_auth_deleted(user_id)` then `mark_storage_cleaned(user_id)`. For `scan_type = 'auth_deleted'`: calls `mark_storage_cleaned(user_id)`. Removes the claim row. If claim is invalid or expired → raises an error.

`public.fail_deletion_recovery(user_id uuid, claim_token uuid, error_code text)`
→ void
Verifies the claim token. Calls `record_deletion_failure_wrapper(user_id, error_code)`. Removes the claim row so the record will be re-claimed on the next worker run. If claim is invalid → raises an error.

---

## Section 3 — Cross-Cutting Contracts

These rules apply to every Edge Function and worker unless explicitly carved out.

### 3.1 Authentication

**`verify_jwt` setting:**
- User-facing Edge Functions (`upload-authorize`, `upload-complete`, `media-serve`, `account-delete-complete`) deploy with `verify_jwt = true`. Gateway JWT rejection returns its own `401` before the function runs. That response does not follow the Forkensics error envelope. This exception is documented here.
- Cron-authenticated functions and workers (`scheduled-close`, `upload-cleanup-worker`, `deletion-recovery-worker`) deploy with `verify_jwt = false`. They authenticate via the cron-secret pattern (Section 3.5).

**Standard gate (upload-authorize, upload-complete, media-serve):**
After gateway JWT verification:
1. Extract `sub` claim (user UUID). If absent or empty → `401 FK_UNAUTHENTICATED`.
2. Confirm a row exists in `public.profiles` where `id = sub` AND `is_active = true` AND `onboarding_complete = true`. If not → `403 FK_FORBIDDEN`.

**`account-delete-complete` gate (carve-out):**
After gateway JWT verification:
1. Extract `sub` claim (user UUID). If absent or empty → `401 FK_UNAUTHENTICATED`.
2. Confirm a row exists in `public.profiles` where `id = sub`. Any `is_active` or `onboarding_complete` value is permitted — deactivated or partially-onboarded users must be able to exercise their deletion right.

### 3.2 Authorization

Authorization is enforced at two layers:

- **User-JWT layer:** Reads that act on behalf of a user use a Supabase client initialized with the user's JWT. RLS applies normally.
- **Administrative client layer:** Operations requiring service-role access use the administrative Supabase client (initialized with the service-role key). This client connects through PostgREST as the `service_role` role. It calls only the V2 SECURITY DEFINER functions listed in Section 2.5, generates signed storage URLs, reads/writes/deletes storage objects, and calls the Admin API for user deletion. It is never used to read data the user is not authorized to see.

### 3.3 Privileged Database Access Pattern

All privileged database operations use the public SECURITY DEFINER functions in Section 2.5, called via the administrative Supabase client. These functions are granted EXECUTE only to `service_role`.

`SUPABASE_DB_URL` (direct PostgreSQL connection) is **not** used by Edge Functions. The `private` schema is never exposed through the PostgREST API. No direct administrative reads of upload-session rows or private deletion records occur outside of named functions.

### 3.4 Existence and Authorization Probing

For any challenge-scoped operation: if the challenge does not exist or if the caller is not authorized to see it, return `404 FK_NOT_FOUND` — not `403`. This prevents callers from inferring challenge existence from error codes.

### 3.5 Cron Authentication

All cron-authenticated functions and workers use the following pattern. Edge Functions do not read from Vault at runtime.

**Setup (once, before deployment):** Generate a cryptographically random secret (256 bits minimum). Store it in two places:
1. Supabase Vault — so pg_cron/pg_net can read it when constructing outbound HTTP requests to invoke the function.
2. Edge Function environment variables as `CRON_SECRET` — so the receiving function can compare against it at runtime without accessing Vault.

**Request construction (database side — pg_cron/pg_net):** The pg_cron job reads the secret from Vault and includes it in every outbound request: `X-Forkensics-Cron-Secret: <secret>`.

**Receiving function:** Reads the `X-Forkensics-Cron-Secret` header. Compares it to `CRON_SECRET` using constant-time equality to prevent timing attacks. If absent or mismatch → `401 FK_UNAUTHENTICATED`. The function never reads Vault.

A separate secret may be used per function, or one secret may be shared across all three cron-authenticated functions — that decision is deferred to implementation. The contract requires the pattern; key management details are documented at setup time.

### 3.6 Error Response Format

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

### 3.7 Standard Error Codes

| HTTP | Code | Meaning |
|---|---|---|
| 400 | `FK_INVALID_INPUT` | Missing or malformed request field |
| 400 | `FK_INVALID_CONTENT_TYPE` | Actual MIME type not allowed, or actual MIME does not match `session.content_type` |
| 400 | `FK_FILE_TOO_LARGE` | Actual stored file exceeds 10 MB |
| 400 | `FK_INVALID_TOKEN` | Upload token missing, malformed, or for an expired/failed/unknown session |
| 401 | `FK_UNAUTHENTICATED` | Missing or invalid sub claim; or missing/mismatched cron secret |
| 403 | `FK_FORBIDDEN` | Valid JWT; caller does not meet `is_active` + `onboarding_complete` requirements |
| 404 | `FK_NOT_FOUND` | Resource does not exist or caller is not authorized to see it |
| 409 | `FK_WRONG_STATE` | Resource is not in the required state for this operation |
| 409 | `FK_UPLOAD_IN_PROGRESS` | A session for this challenge is already `pending`, `processing`, or `sanitized` |
| 422 | `FK_PROCESSING_FAILED` | Re-encoding or storage operation failed unrecoverably |
| 429 | `FK_RATE_LIMITED` | Too many requests |
| 500 | `FK_INTERNAL` | Unexpected server error — no internal detail exposed to caller |

`FK_ALREADY_COMPLETE` is not used. A completed idempotent operation returns `200` with `"already_complete": true`.

### 3.8 Idempotency

Retry behavior is specified per-contract. The general rules:

- A retry of a completed operation returns `200` with the original result and `"already_complete": true`.
- A retry of an in-progress operation returns `202 {"status": "processing"}`.
- **Upload sessions in `failed` or `expired` state are not retryable.** The client must call `upload-authorize` again. `upload-complete` with a token for such a session returns `400 FK_INVALID_TOKEN`.
- Idempotency for non-upload operations is derived from stable inputs (challenge ID, user ID). No client-supplied idempotency headers are required.

### 3.9 Logging

Logs must **never** contain:
- Canonical dish name, restaurant name, or city
- Storage paths, storage keys, or signed URLs
- EXIF or GPS data from any image
- Secret keys, JWTs, upload tokens, token hashes, claim tokens, or cron secrets
- Raw storage error messages
- Any content from `challenge_secrets`

Logs must contain:
- Timestamp (ISO 8601)
- Function or worker name
- Request ID (generated per invocation)
- User UUID (for authenticated functions; omit for workers)
- Challenge UUID (where applicable)
- Outcome: `success` | `error`
- Sanitized error code on failure — not the raw error message

### 3.10 Operational Failure Safety

If any Edge Function or worker fails, ordinary gameplay continues:

- `upload-authorize` / `upload-complete` failure → challenge stays in `draft`; poster retries when ready
- `media-serve` failure → image unavailable; game UI shows placeholder; guessing and scoring unaffected
- `scheduled-close` failure → challenges remain open past `deadline_at` until next successful cron run; no data corruption
- `account-delete-complete` storage failure → user can still authenticate and retry; no storage objects are abandoned
- Worker failure → state is recoverable on next run; no data corruption; claims expire and are re-issued

### 3.11 Atomicity Boundary

Only database operations inside a single PostgreSQL transaction are atomic. Storage operations (S3-compatible) and PostgreSQL operations are not atomic with respect to each other. Any multi-step sequence spanning both requires explicit compensating cleanup on failure, as specified in each function contract below.

---

## Section 4 — Function Contracts

### 4.1 `upload-authorize`

**Purpose:** Record a new upload session in the database and issue a time-limited signed URL so the iOS client can upload directly to the `game-media` private bucket.

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
1. Generate a secret upload token (cryptographically random; 256 bits). Compute its SHA-256 hex hash.
2. Call `public.create_upload_session(challenge_id, user_id, token_hash, content_type, declared_size_bytes, now() + 5 minutes)` via administrative client.
   - If the function raises `FK_NOT_FOUND` → `404 FK_NOT_FOUND`.
   - If the function raises `FK_WRONG_STATE` (challenge not in `draft`) → `409 FK_WRONG_STATE`.
   - If the function raises `FK_UPLOAD_IN_PROGRESS` (active session exists) → `409 FK_UPLOAD_IN_PROGRESS`. The client must wait for the current upload to complete or fail before calling `upload-authorize` again.
3. Generate a signed upload URL for `session.original_storage_path` in `game-media`, 5-minute expiry (administrative client). The signed URL is generated after the session row is committed.
4. Return the signed URL and upload token to the client. `session_id` and storage paths are internal and are never returned to the client.

**Response `200 OK`:**
```json
{
  "signed_url": "<url>",
  "upload_token": "<secret token — not the hash>",
  "expires_at": "<ISO 8601>"
}
```

**Idempotency:** Not idempotent. Each call requires no active session to exist.

**Logging:** `challenge_id`, `user_id`, `content_type`, `session_id` (internal), outcome. NOT the signed URL, upload token, token hash, or storage paths.

---

### 4.2 `upload-complete`

**Purpose:** Validate the uploaded file, re-encode with EXIF/GPS removal, confirm original deleted, atomically finalize the media object.

**Prerequisite:** V2 upload-session infrastructure (Section 2).

**Method / Path:** `POST /upload-complete`

**`verify_jwt`:** `true`

**Request body:**
```json
{
  "upload_token": "<secret token>"
}
```

**Authorization:**
1. Profile active + onboarding complete (Section 3.1 standard gate).
2. Compute SHA-256 hash of `upload_token`. Call `public.resolve_upload_session(token_hash, user_id)` (administrative client). If no row returned (token unknown or belongs to another user) → `400 FK_INVALID_TOKEN`.

**Idempotency branch (check session status before any action):**
- `complete` → `200 {"status":"ready","media_object_id":"<uuid>","already_complete":true}`.
- `processing` → `202 {"status":"processing"}`.
- `sanitized` → skip to finalization (step 8).
- `pending` → proceed to happy path.
- Any other status (`expired`, `failed`, `cleaned`) → `400 FK_INVALID_TOKEN`. Not retryable; client must call `upload-authorize`.

**Happy path (session status `pending`):**

1. Call `public.advance_upload_session_processing(session_id, user_id, '10 minutes')` (administrative client). Verifies identity, `status = 'pending'`, not expired; transitions to `processing`; sets `processing_lease_expires_at`. Returns both storage paths. If transition fails → `400 FK_INVALID_TOKEN`.
2. Read original file from `session.original_storage_path` (administrative client). If absent → `public.fail_upload_session(session_id, 'FK_NOT_FOUND')`; return `404 FK_NOT_FOUND`.
3. Sniff actual MIME type from file bytes. The actual MIME must be `image/jpeg` or `image/webp` AND must match `session.content_type`. If either condition fails → delete original from storage; `public.fail_upload_session(session_id, 'FK_INVALID_CONTENT_TYPE')`; return `400 FK_INVALID_CONTENT_TYPE`.
4. Confirm actual stored size ≤ 10,485,760 bytes. If over → delete original from storage; `public.fail_upload_session(session_id, 'FK_FILE_TOO_LARGE')`; return `400 FK_FILE_TOO_LARGE`.
5. Re-encode to WebP; strip all EXIF, GPS, and embedded metadata. If re-encoding fails → delete original from storage; `public.fail_upload_session(session_id, 'FK_PROCESSING_FAILED')`; return `422 FK_PROCESSING_FAILED`.
6. Write re-encoded file to `session.display_storage_path` (administrative client — path read from session row, not constructed). If write fails → delete original from storage; `public.fail_upload_session(session_id, 'FK_PROCESSING_FAILED')`; return `422 FK_PROCESSING_FAILED`.
7. Delete original from `session.original_storage_path` (administrative client). Retry up to 2 times.
   - If all attempts fail: delete display object from step 6; `public.fail_upload_session(session_id, 'FK_PROCESSING_FAILED')`; return `422 FK_PROCESSING_FAILED`. Client must restart from `upload-authorize`.
8. Call `public.advance_upload_session_sanitized(session_id)` (administrative client). Transitions to `sanitized`. If this call fails: original is already deleted; display object exists at `session.display_storage_path`. `public.fail_upload_session` if possible; log `session_id` for cleanup worker. Return `500 FK_INTERNAL`. The cleanup worker finds the display object at the recorded path and removes it.

**Finalization (step 8 of happy path, or entered from `sanitized` branch):**

9. Call `public.finalize_upload_session(session_id)` (administrative client). Returns `(media_object_id, replaced_media_object_id)`. Atomically: inserts `media_objects`, inserts `media_storage_keys`, sets (or swaps) `challenges.media_object_id`, marks prior media `superseded` if replacing. If already `complete`, returns existing IDs. If finalization fails: session stays `sanitized`; original is already deleted; display object exists. Return `500 FK_INTERNAL`. Client may retry with same token — will enter the `sanitized` branch and retry finalization.

**Response `200 OK`:**
```json
{
  "media_object_id": "<uuid>",
  "status": "ready"
}
```

**Logging:** `challenge_id`, `session_id` (internal), actual MIME type string, actual stored size in bytes, re-encoding outcome, original-deletion outcome. NOT storage paths, upload token, or token hash.

---

### 4.3 `media-serve`

**Purpose:** Proxy the re-encoded challenge image to an authorized viewer. Never expose storage paths or signed URLs to the client.

**Method / Path:** `GET /media/{challenge_id}`

**`verify_jwt`:** `true`

**Authorization:**
1. Profile active + onboarding complete (Section 3.1 standard gate).
2. Query `public.challenges` using the **user-JWT client**: `SELECT id, media_object_id FROM public.challenges WHERE id = $challenge_id`. RLS applies automatically. If no row returned → `404 FK_NOT_FOUND`. This single query enforces all visibility rules, including the `posted_at IS NOT NULL` rule that restricts draft challenges to the poster — no manual state or membership check is needed in function code.
3. If `media_object_id` is null → `404 FK_NOT_FOUND`.

**Action:**
1. Call `public.get_media_storage_key(media_object_id)` (administrative client). Returns `re_encoded_storage_key` if `media_objects.status = 'ready'`. If no result → `404 FK_NOT_FOUND`. The key is read from the database record; the function never constructs a storage path from `challenge_id` or `session_id`.
2. Read the file at `re_encoded_storage_key` from `game-media` (administrative client).
3. Stream bytes to client with `Content-Type: image/webp`.

**Response `200 OK`:** Binary image stream (`image/webp`)

**Cache headers:** `Cache-Control: private, max-age=3600`

**Logging:** `challenge_id`, `user_id`, outcome. NOT the storage key or path.

---

### 4.4 `scheduled-close`

**Purpose:** Lock and reveal all challenges whose `deadline_at` has passed.

**Trigger:** Supabase pg_cron, every 2 minutes.

**`verify_jwt`:** `false`

**Authentication:** Cron-secret pattern (Section 3.5). Compares `X-Forkensics-Cron-Secret` header to `CRON_SECRET` env var using constant-time equality. If absent or mismatch → `401 FK_UNAUTHENTICATED`.

**Action:**

Pass 1 — lock active challenges past deadline:
1. Query `public.challenges WHERE state = 'active' AND deadline_at <= now()` (administrative client).
2. For each: call `public.lock_challenge(uuid)` (administrative client). Raises if not in `active` state — catch per-row, log sanitized error code, continue batch.

Pass 2 — reveal locked challenges:
1. Query `public.challenges WHERE state = 'locked'` (administrative client). Revealed and cancelled challenges are excluded by this predicate; no per-row handling needed.
2. For each: call `public.reveal_challenge_service_wrapper(uuid)` (administrative client). Catch per-row errors — log and continue batch.

**Response `200 OK`:**
```json
{
  "locked_count": 3,
  "revealed_count": 3,
  "skipped_count": 0,
  "errors": [{ "challenge_id": "<uuid>", "pass": "lock" | "reveal", "error_code": "<sanitized>" }]
}
```

**Idempotency:** Both passes are safe to run multiple times. Per-row errors are caught and logged; batch continues.

**Logging:** `locked_count`, `revealed_count`, `skipped_count`, per-row sanitized error codes and challenge IDs. NOT challenge content, canonical answers, or guess data.

---

### 4.5 `account-delete-complete`

**Purpose:** Initiate or complete account deletion. Prepares the deletion record, gathers and deletes ALL storage (established media keys AND pending upload session objects), deletes `auth.users`, and finalizes the deletion record.

**Method / Path:** `POST /account-delete-complete`

**`verify_jwt`:** `true`

**Request body:** *(none)*

**Authentication:** Carve-out gate (Section 3.1). Valid JWT + existing profile row; `is_active` and `onboarding_complete` not checked.

**V1 deletion status states:**
- `pending` — transient; internal to `private.prepare_account_deletion()`. Never the observable state after the wrapper returns.
- `database_prepared` — observable state after `prepare_account_deletion_wrapper` returns; profile is anonymized.
- `auth_deleted` — after `mark_auth_deleted` is called.
- `complete` — terminal; after `mark_storage_cleaned` is called.

**Action (stop at the specified step on failure):**

1. Call `public.prepare_account_deletion_wrapper(user_id)` (administrative client). Returns the resulting status.
   - Returns `'database_prepared'` (new or existing record) → continue.
   - Returns `'auth_deleted'` → recovery worker handles this; return `409 FK_WRONG_STATE`.
   - Returns `'complete'` → JWT should be void at this point; log anomaly; return `500 FK_INTERNAL`.
   - Any error → `500 FK_INTERNAL`.
2. Gather ALL storage to delete (two calls, then merge):
   a. Call `public.get_deletion_storage_keys(user_id)` (administrative client) → established media keys.
   b. Call `public.get_pending_upload_storage_paths(user_id)` (administrative client) → paths for `pending`, `processing`, and `sanitized` sessions.
3. Delete ALL gathered storage objects from `game-media` (administrative client). For pending upload sessions: attempt both `original_storage_path` and `display_storage_path`; an absent object is a no-op success.
4. If any storage deletion fails:
   - Call `public.record_deletion_failure_wrapper(user_id, 'FK_PROCESSING_FAILED')`.
   - Return `422 FK_PROCESSING_FAILED`. User can still authenticate and retry.
   - **Stop here.** Do not delete the auth account.
5. Call `public.fail_all_pending_sessions_for_user(user_id)` (administrative client). Marks any remaining `pending/processing/sanitized` sessions as `failed`. Storage for these sessions has already been deleted in step 3.
6. Delete the `auth.users` row (Admin API, administrative client). If fails → `500 FK_INTERNAL`. User can still authenticate and retry.
7. Call `public.mark_auth_deleted(user_id)` (administrative client). If fails: JWT is now void; client cannot retry. Log for recovery worker. Return `500 FK_INTERNAL`.
8. Call `public.mark_storage_cleaned(user_id)` (administrative client). Transitions record to `complete`. If fails: same. Log for recovery worker. Return `500 FK_INTERNAL`.
9. Return `200 {"status":"complete"}`.

**Client retry:** Once step 6 completes, the JWT is void. The gateway rejects subsequent requests. The client cannot retry steps 7–8 — recovery is handled by the deletion-recovery-worker.

**Idempotency at step 1:** If a record already exists in `database_prepared`, the wrapper is idempotent. Retries resume from step 2.

**Upload sessions at account deletion:** `uploader_id` references `public.profiles(id)`. Deleting `auth.users` does not cascade to upload session rows. Step 5 marks active sessions `failed`; the cleanup worker handles their cleanup.

**Logging:** `user_id` (before deletion), `established_key_count`, `pending_session_count`, `storage_objects_attempted`, `deleted_count`, `failed_count`, deletion record state at each step. NOT storage paths, key values, or file content.

---

### 4.6 `upload-cleanup-worker`

**Purpose:** Transition stale upload sessions to terminal states, delete their orphaned storage objects, clean up superseded media objects, and mark sessions `cleaned`.

**Trigger:** Supabase pg_cron, every 15 minutes.

**`verify_jwt`:** `false`

**Authentication:** Cron-secret pattern (Section 3.5).

**Action:**

Part 1 — upload session cleanup:
1. Call `public.claim_cleanup_sessions(worker_id, '15 minutes')` (administrative client). Atomically: transitions stale `pending` (past `expires_at + 60s`) → `expired`; transitions lease-expired `processing` → `failed`; claims all `expired`, `failed`, and abandoned `sanitized` sessions using `FOR UPDATE SKIP LOCKED`. Returns each claimed session with its `cleanup_claim_token`. Sessions with an unexpired active claim are skipped.
2. For each claimed session:
   a. Attempt to delete `session.original_storage_path` from storage (applicable for `expired` and `failed` sessions — this path may or may not exist). An absent object is a no-op success.
   b. Attempt to delete `session.display_storage_path` from storage (applicable for `sanitized` and `failed` sessions — known from session creation). An absent object is a no-op success.
   c. If all applicable deletions succeeded: call `public.mark_session_cleaned(session_id, cleanup_claim_token)` (administrative client). Verifies the claim token before accepting the transition.
   d. If any deletion failed: log `session_id` and sanitized error code. Do NOT call `mark_session_cleaned`. The session keeps its current status and will be re-claimed on the next run after the current claim expires (15 minutes).

Part 2 — superseded media object cleanup:
1. Call `public.get_superseded_media_to_clean()` (administrative client). Returns `media_objects` rows with `status = 'superseded'` and their `re_encoded_storage_key`.
2. For each: attempt to delete `re_encoded_storage_key` from storage. If success → call `public.mark_superseded_media_cleaned(media_object_id)`. If failure → log sanitized error code; leave status as `superseded`; retry next run.

**Response `200 OK`:**
```json
{
  "sessions_claimed": 5,
  "sessions_cleaned": 4,
  "sessions_cleanup_failed": 1,
  "objects_deleted": 7,
  "objects_absent": 1,
  "objects_failed": 0,
  "superseded_media_cleaned": 2,
  "superseded_media_failed": 0
}
```

**Idempotency:** Absent storage objects are no-op successes. `mark_session_cleaned` verifies the claim token, so stale claims from a prior crashed run cannot complete cleanup. Superseded media cleanup is idempotent.

**Logging:** Counts above. NOT storage paths, session IDs, or claim tokens.

---

### 4.7 `deletion-recovery-worker`

**Purpose:** Resume account deletions that advanced past auth deletion server-side and can no longer be retried by the client.

**Trigger:** Supabase pg_cron, every 5 minutes.

**`verify_jwt`:** `false`

**Authentication:** Cron-secret pattern (Section 3.5).

**Action:**

1. Call `public.claim_deletion_recovery_records(worker_id, '10 minutes', '10 minutes')` (administrative client). Atomically claims `database_prepared` records older than 10 minutes and all `auth_deleted` records — where no unexpired claim exists. Returns claimed records with claim tokens.

2. For each claimed record:

   **If `scan_type = 'database_prepared'`:**
   a. Check whether `auth.users` row still exists (Admin API). If auth still exists → `public.fail_deletion_recovery(user_id, claim_token, 'FK_AUTH_STILL_EXISTS')`; skip. The client can still retry `account-delete-complete`.
   b. Auth is gone. Storage may not have been cleaned. Gather ALL storage:
      - `public.get_deletion_storage_keys(user_id)` → established media keys.
      - `public.get_pending_upload_storage_paths(user_id)` → pending session paths.
   c. Delete all gathered storage objects. Absent objects are no-op successes.
   d. Call `public.fail_all_pending_sessions_for_user(user_id)` — marks active sessions `failed`.
   e. If any storage deletion failed → `public.fail_deletion_recovery(user_id, claim_token, 'FK_PROCESSING_FAILED')`; leave record in `database_prepared`; retry next run.
   f. If all storage deleted → `public.complete_deletion_recovery(user_id, claim_token, 'database_prepared')`. This calls `mark_auth_deleted` then `mark_storage_cleaned` → `complete`.

   **If `scan_type = 'auth_deleted'`:**
   a. Auth is already known to be gone. Gather ALL storage:
      - `public.get_deletion_storage_keys(user_id)` → established media keys.
      - `public.get_pending_upload_storage_paths(user_id)` → pending session paths.
   b. Delete all gathered storage objects. Absent objects are no-op successes.
   c. Call `public.fail_all_pending_sessions_for_user(user_id)` — marks active sessions `failed`.
   d. If any storage deletion failed → `public.fail_deletion_recovery(user_id, claim_token, 'FK_PROCESSING_FAILED')`; leave record in `auth_deleted`; retry next run.
   e. If all storage deleted → `public.complete_deletion_recovery(user_id, claim_token, 'auth_deleted')`. This calls `mark_storage_cleaned` → `complete`.

**Response `200 OK`:**
```json
{
  "records_claimed": 2,
  "database_prepared_scanned": 1,
  "auth_confirmed_still_exists": 0,
  "auth_confirmed_absent": 1,
  "auth_deleted_scanned": 1,
  "completed": 1,
  "storage_cleanup_failures": 0,
  "errors": []
}
```

**Idempotency:** All V1 state-transition functions are idempotent. Claim tokens prevent concurrent duplicate processing. Records already at `complete` are not returned by `claim_deletion_recovery_records`.

**Deployment gate:** `deletion-recovery-worker` must be deployed simultaneously with `account-delete-complete`. A single deployment gate covers both.

**Logging:** Counts only. NOT user IDs, storage paths, claim tokens, or error details.

---

## Section 5 — Contract Test Requirements

### 5.1 Local Contract Tests

**Authentication and authorization:**
- Missing JWT → `401`
- Expired JWT → `401`
- Standard gate: `is_active = false` → `403 FK_FORBIDDEN`
- Standard gate: `onboarding_complete = false` → `403 FK_FORBIDDEN`
- Carve-out (`account-delete-complete`): `is_active = false` → allowed
- Carve-out: `onboarding_complete = false` → allowed
- Cron functions: missing `X-Forkensics-Cron-Secret` → `401`
- Cron functions: incorrect `X-Forkensics-Cron-Secret` → `401`

**Existence and probing:**
- Nonexistent `challenge_id` → `404 FK_NOT_FOUND`
- Valid `challenge_id`, caller not authorized → same `404` body — no probing

**One active session per challenge:**
- `upload-authorize` while another session is `pending` → `409 FK_UPLOAD_IN_PROGRESS`
- `upload-authorize` while another session is `processing` → `409 FK_UPLOAD_IN_PROGRESS`
- `upload-authorize` while another session is `sanitized` → `409 FK_UPLOAD_IN_PROGRESS`
- `upload-authorize` after prior session is `failed` → allowed (creates new session)
- `upload-authorize` after prior session is `complete` (no current active session) → allowed

**Photo replacement:**
- `finalize_upload_session` when challenge already has a `media_object_id` (prior session `complete`, challenge still `draft`) → atomically swaps `media_object_id`, marks prior `media_objects.status = 'superseded'`, returns `replaced_media_object_id`
- Challenge cannot be activated while `media_objects.status = 'superseded'`
- Upload-cleanup-worker deletes `re_encoded_storage_key` of superseded media, then calls `mark_superseded_media_cleaned`

**Upload token lifecycle:**
- Unknown token → `400 FK_INVALID_TOKEN`
- Token for `expired` session → `400 FK_INVALID_TOKEN`
- Token for `failed` session → `400 FK_INVALID_TOKEN`
- Token for `complete` session → `200 {"status":"ready","already_complete":true}`
- Token for `processing` session → `202 {"status":"processing"}`
- Token for `sanitized` session → finalization retried; `200` on success

**MIME validation:**
- JPEG bytes declared `image/jpeg` → allowed
- WebP bytes declared `image/webp` → allowed
- JPEG bytes declared `image/webp` → `400 FK_INVALID_CONTENT_TYPE` (actual ≠ declared)
- WebP bytes declared `image/jpeg` → `400 FK_INVALID_CONTENT_TYPE`
- PNG bytes declared `image/jpeg` → `400 FK_INVALID_CONTENT_TYPE` (actual not allowed)
- Actual size > 10 MB → `400 FK_FILE_TOO_LARGE`

**Storage paths:**
- `original_storage_path` and `display_storage_path` both set at session creation
- `resolve_upload_session` used for all token lookups — no direct row reads
- Paths read from session row by Edge Function — never constructed in Edge Function code

**Persistent cleanup claims:**
- `claim_cleanup_sessions` issues a `cleanup_claim_token` stored in the session row
- `mark_session_cleaned` rejects a mismatched claim token
- `mark_session_cleaned` rejects an expired claim token
- Two concurrent workers claim disjoint sessions (SKIP LOCKED)
- A session with an unexpired active claim is not re-claimed by a second worker
- A session with an expired claim is re-claimed by the next worker run
- Stale `pending` (past `expires_at + 60s`) → transitioned to `expired` by `claim_cleanup_sessions`
- Stale `processing` (past `processing_lease_expires_at`) → transitioned to `failed` by `claim_cleanup_sessions`
- Abandoned `sanitized` (past `processing_lease_expires_at + 60 minutes`) → claimed for cleanup
- Failed and expired sessions: both storage paths attempted; `cleaned` only if all deletions succeed
- `complete` sessions: never returned by `claim_cleanup_sessions`; never cleaned

**Deletion-recovery-worker claims:**
- `claim_deletion_recovery_records` issues a claim token stored in `deletion_recovery_claims`
- `complete_deletion_recovery` rejects a mismatched claim token
- `complete_deletion_recovery` rejects an expired claim (10-minute expiry)
- Two concurrent recovery workers claim disjoint records
- `database_prepared` record, auth still exists → `fail_deletion_recovery` called; record left in `database_prepared`

**Unfinished uploads in account deletion:**
- User has `pending` session when `account-delete-complete` runs → session's `original_storage_path` deleted; session marked `failed`; auth deletion proceeds
- User has `sanitized` session when `account-delete-complete` runs → session's `display_storage_path` deleted; session marked `failed`; auth deletion proceeds
- Storage deletion for a pending session fails → `422`; auth not deleted; user can retry
- Auth deletion succeeds with persistent upload-session rows → `uploader_id` FK to `profiles.id` preserves row; cleanup worker handles eventual cleanup

**Recovery worker with pending sessions:**
- `database_prepared` record, auth absent, pending sessions exist → `get_pending_upload_storage_paths` returns them; storage deleted; `fail_all_pending_sessions_for_user` called; then `complete_deletion_recovery`
- `auth_deleted` record, pending sessions exist → same gathering and deletion before `complete_deletion_recovery`

**`media-serve`:**
- RLS restricts draft challenges to poster; no additional check in function code
- Poster in `draft` → `200`; group member in `draft` → `404`
- Group member in `active` → `200`
- `media_object_id` null → `404`
- `get_media_storage_key` returns `re_encoded_storage_key`; function streams that object

**`scheduled-close`:**
- Challenge in `active` past deadline → locked in Pass 1; revealed in Pass 2
- Already `locked` → not in Pass 1; revealed in Pass 2
- Already `revealed` → excluded by `WHERE state = 'locked'` in Pass 2
- Per-row failure in Pass 1 does not abort Pass 2

**`account-delete-complete`:**
- First-time deletion, no prior record → `prepare_account_deletion_wrapper` creates record → `database_prepared`; flow continues
- Retry when already `database_prepared` → idempotent; flow resumes from step 2
- Storage failure → `422`; auth not deleted; user can retry
- Auth deletion failure → `500`; user can retry
- `mark_auth_deleted` failure after auth deletion → `500`; JWT void; recovery worker handles
- Record already `auth_deleted` → `409 FK_WRONG_STATE`
- `is_active = false` → allowed; `onboarding_complete = false` → allowed

**`deletion-recovery-worker`:**
- `database_prepared`, auth gone, storage present → gathered, deleted, `fail_all_pending_sessions_for_user` called, `complete_deletion_recovery` succeeds → `complete`
- `database_prepared`, auth gone, storage deletion fails → `fail_deletion_recovery` called; stays `database_prepared`; retried
- `auth_deleted`, storage present → same gathering/deletion before `complete_deletion_recovery`
- `auth_deleted`, storage deletion fails → `fail_deletion_recovery`; stays `auth_deleted`; retried
- Worker is idempotent across runs

**Error format:**
- All function-produced errors match `{ "error": { "code": "FK_...", "message": "..." } }`
- Logs contain no storage paths, tokens, or raw error messages

### 5.2 Production Verification

Per-function non-mutating probes (no data created, no state changed):

| Function | Production probe |
|---|---|
| `upload-authorize` | Unauthenticated → `401`; authenticated with missing `challenge_id` → `400` |
| `upload-complete` | Unauthenticated → `401`; authenticated with missing `upload_token` → `400` |
| `media-serve` | Unauthenticated → `401`; authenticated with nonexistent `challenge_id` → `404` |
| `scheduled-close` | Wrong/absent cron secret → `401` |
| `upload-cleanup-worker` | Wrong/absent cron secret → `401` |
| `deletion-recovery-worker` | Wrong/absent cron secret → `401` |
| `account-delete-complete` | Unauthenticated → `401` only (no authenticated probe — authenticated request triggers deletion) |

### 5.3 What Contract Tests Must Never Do

- Call `reveal_challenge` or its wrapper on a real challenge
- Assert on or log canonical answers, restaurant names, or city values
- Leave test data in `forkensics-prod`
- Hard-code credentials
- Pass raw storage errors or paths into any `record_deletion_failure` call

---

## Section 6 — Deployment Sequence

Each function is deployed one at a time. Each deployment is gated on:
1. V2 migration complete and verified (prerequisite for all functions using V2 wrappers)
2. Local contract tests pass
3. GPT review of the implementation
4. Bill approves with `APPROVED: Deploy {function-name}`
5. Deploy to `forkensics-dev`; smoke tests pass against dev
6. Bill approves with `APPROVED: Deploy {function-name} to prod`
7. Deploy to `forkensics-prod`; production verification probes pass (per Section 5.2)

**Cron credential setup** must complete before deploying any cron-authenticated function or worker: generate secret; store in Vault; configure as Edge Function environment variable.

**Deployment order:**
1. V2 migration — separate Step 25
2. Cron credential setup
3. `upload-authorize`
4. `upload-complete` + `upload-cleanup-worker` (deployed together)
5. `media-serve`
6. `scheduled-close`
7. `account-delete-complete` + `deletion-recovery-worker` (deployed simultaneously)

---

## Section 7 — Out of Scope for Step 24

- Any TypeScript or Deno code
- Any `supabase functions deploy` command
- V2 migration SQL content (covered in Step 25)
- Push notifications
- Sign in with Apple configuration
- Any iOS application code
- Member removal (no V1 function)
- Cron credential key management beyond the pattern in Section 3.5

---

## Success Criteria for Step 24

- [ ] Decision matrix agreed: cancel/apply_correction permit poster or group owner; reason nullable; correct V1 mechanisms for comments and reactions
- [ ] One active session per challenge agreed: `create_upload_session` raises `FK_UPLOAD_IN_PROGRESS` for `pending/processing/sanitized`; client must wait for active session to conclude
- [ ] Photo replacement agreed: `finalize_upload_session` atomically swaps `media_object_id` and marks prior `media_objects.status = 'superseded'`; cleanup worker deletes superseded display object; `activate_challenge` rejects while any media is not `ready`
- [ ] Upload session table schema agreed: profiles FK, both paths at creation, processing lease, persistent claim fields, `status_changed_at`, `cleaned` terminal state
- [ ] Deletion recovery claims table agreed: V2 table with claim token and expiry
- [ ] All V2 wrapper functions enumerated and agreed: no direct administrative reads of upload session rows or private deletion records
- [ ] Persistent claim mechanism agreed: `claim_cleanup_sessions` issues token; `mark_session_cleaned` verifies token; stale thresholds bound; deletion-recovery-worker uses equivalent `deletion_recovery_claims` table
- [ ] Upload-authorize agreed: session created before signed URL; `FK_UPLOAD_IN_PROGRESS` when active session exists
- [ ] Upload-complete agreed: MIME must match declared AND be allowed; `resolve_upload_session` for all token lookups; idempotency branches correct; finalization handles photo replacement
- [ ] Cleanup worker agreed: persistent claims, stale thresholds, superseded media cleanup, complete sessions never touched
- [ ] Account deletion agreed: gathers pending upload session paths alongside established media keys; unified deletion pass; `fail_all_pending_sessions_for_user` before auth deletion; recovery worker does same gathering in both scans
- [ ] `media-serve` agreed: RLS enforces visibility; key from `get_media_storage_key`; no path construction
- [ ] Cron authentication agreed: two-location secret; constant-time comparison; Edge Function reads env var, not Vault
- [ ] `scheduled-close` agreed: two-pass; Pass 2 uses `WHERE state = 'locked'`
- [ ] Per-function production probes agreed: account-delete-complete is unauthenticated-only; workers use cron-secret probe only
- [ ] Deployment order agreed: workers deployed with their paired Edge Functions; cron credential prerequisite
- [ ] No Edge Function code written before approval
