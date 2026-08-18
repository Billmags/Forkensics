# Step 24 Proposal — Rev 8 — Edge Function Architecture and Contracts

**Status:** Pending review (Claude → Codex/GPT → Bill approval)
**Governance gate:** Bill must type `APPROVED: Step 24 — Edge Function Architecture and Contracts` before any Edge Function code is written.

**Scope:** Architecture decisions and binding contracts only. No TypeScript, no Deno code, no deployment. Implementation follows in separate per-function steps.

**Changes from Rev 7:**
1. Account-deletion retry gap closed: `quiesce_upload_sessions_for_deletion` only touches active sessions (`pending`, `processing`, `sanitized`); previously-stopped sessions become `failed` and were invisible to subsequent deletion attempts. Added `public.get_all_upload_session_paths_for_deletion(user_id uuid)`, which returns storage paths for every session whose status is NOT `complete` or `cleaned`, including `failed` and `expired`. `account-delete-complete` and both deletion-recovery-worker scan paths now call this function after quiescing (when no blocking lease remains) and delete all returned paths before gathering established media keys — guaranteeing that no upload-session storage path survives deletion completion regardless of how many prior attempts occurred. The Step-25-decision deferral language is removed. Tests added for: blocked attempt with pre-quiesced sessions followed by retry; storage failure followed by retry; recovery retry involving a pre-existing `failed` session.
2. Cleanup-vs-finalization race closed with four coordinated changes: (a) `claim_cleanup_sessions` now atomically transitions abandoned `sanitized` sessions to `failed` (not merely claims them in `sanitized` state) before returning; (b) `finalize_upload_session` acquires a row-level lock on the upload-session row and permits only `sanitized → complete` or the idempotent `complete → complete` — any other status raises `FK_WRONG_STATE`; (c) `mark_session_cleaned` verifies the session status is `failed` or `expired` before transitioning to `cleaned` — raises an error if status is `complete`; (d) `fail_upload_session` raises an error if the session is already `complete`. Together these ensure that `claim_cleanup_sessions` and `finalize_upload_session` are mutually exclusive via row-level locking (`SKIP LOCKED` causes the cleanup worker to skip a row held by `finalize_upload_session`; if the cleanup worker committed first, `finalize_upload_session` sees `failed` and raises `FK_WRONG_STATE`). Concurrency test added for cleanup vs. finalization.

---

## Section 1 — Decision Matrix: Edge Function vs. Direct RPC

The primary rule: if a database executor function can safely perform the operation, no Edge Function is required. Edge Functions are required only when an operation needs the service/secret key, private storage access, or scheduled execution.

### Direct RPC (no Edge Function needed)

| Operation | Mechanism | Notes |
|---|---|---|
| Submit a guess | Authenticated `INSERT` into `public.guess_attempts` | RLS + `set_guess_receipt_fields` trigger enforces eligibility and timestamp |
| Add a clue | Authenticated `INSERT` into `public.clues` | RLS enforces poster-only |
| Activate a challenge | `public.activate_challenge(uuid)` | Poster only; executor enforces; V2 adds rejection when active upload session exists |
| Manually reveal a challenge | `public.reveal_challenge(uuid)` | Poster only; executor enforces |
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
| `upload-complete` | Read original, re-encode, strip EXIF/GPS, delete original, write display object, finalize via V2 wrapper |
| `media-serve` | Proxy re-encoded image from private storage; fetch privileged storage key via V2 wrapper |
| `scheduled-close` | Cron-triggered; locks and reveals challenges past `deadline_at`; no user JWT |
| `account-delete-complete` | Quiesce upload sessions, gather and delete all storage, call V2 deletion wrappers, delete `auth.users` |

### Background Workers

| Worker | Purpose |
|---|---|
| `upload-cleanup-worker` | Transition stale sessions, delete orphaned storage, handle superseded media, mark sessions `cleaned` |
| `deletion-recovery-worker` | Resume account deletions after the client JWT is void |

### Deferred to V2

| Operation | Reason |
|---|---|
| Auto-reveal when all eligible players have submitted | Requires a database trigger on `guess_attempts` — V2 migration |
| Push notifications | External service (APNs); no V1 infrastructure |
| Sign in with Apple provider configuration | Auth provider setting, not an Edge Function |
| Member removal | No V1 function; V2 decision |

---

## Section 2 — V2 Migration: Upload Session Infrastructure

V1 contains no upload-session table and no processing-idempotency infrastructure. A V2 migration is required before implementing the upload Edge Functions.

### 2.1 Upload Session State Machine

```
pending → processing → sanitized → complete        (happy path)
pending → expired                                  (cleanup worker: stale past expires_at + 60s)
processing → failed                                (cleanup worker: processing_lease_expires_at elapsed)
sanitized(abandoned) → failed                      (cleanup worker: atomically transitions before cleanup)
pending | processing | sanitized → failed          (error in upload-complete or deletion quiesce)
expired | failed → cleaned                         (cleanup worker: storage confirmed deleted)
complete                                           (terminal; never cleaned or failed)
```

State semantics:

- `pending`: session created, signed URL issued; upload not yet confirmed
- `processing`: `upload-complete` has claimed the session and begun processing
- `sanitized`: re-encoding complete, original confirmed deleted, display object written; DB finalization not yet committed
- `complete`: DB finalization committed; all DB records set; terminal — cannot be transitioned to any other state
- `expired`: stale `pending` session past `expires_at + 60 seconds`; transitioned by cleanup worker
- `failed`: unrecoverable error; not retryable — client must call `upload-authorize` again
- `cleaned`: all associated storage objects confirmed deleted; terminal for all non-`complete` paths

### 2.2 Upload Session Table Schema (`private.upload_sessions`)

Both infrastructure tables are placed in the `private` schema. Public SECURITY DEFINER functions access them under their owner's privileges. No row in either table is accessible through PostgREST or the Data API.

Columns for `private.upload_sessions`:

- `session_id` (UUID, primary key) — generated at creation; used as part of storage paths
- `upload_token_hash` (text, unique) — SHA-256 hex of the secret upload token; token itself never stored
- `challenge_id` (UUID FK → `public.challenges(id)`)
- `uploader_id` (UUID FK → `public.profiles(id)`) — references profiles, not `auth.users`; FK survives auth deletion
- `original_storage_path` (text, not null) — `challenges/{challenge_id}/originals/{session_id}`; set at creation
- `display_storage_path` (text, not null) — `challenges/{challenge_id}/displays/{session_id}.webp`; set at creation; deterministic from `session_id`
- `content_type` (text, not null) — declared content type; actual MIME must match at processing time
- `declared_size_bytes` (bigint, not null)
- `expires_at` (timestamptz, not null) — upload claim window; enforced at `advance_upload_session_processing`
- `processing_lease_expires_at` (timestamptz, nullable) — set when transitioning to `processing`; used to detect stale sessions and to fence concurrent deletion
- `status` (text, not null) — one of the seven states above
- `status_changed_at` (timestamptz, not null) — updated on every status transition
- `failed_reason` (text, nullable) — sanitized error code only; no storage paths, no raw error text
- `media_object_id` (UUID, nullable) — set by `finalize_upload_session` when the session reaches `complete`; returned by `resolve_upload_session` for idempotent retries
- `replaced_media_object_id` (UUID, nullable) — set by `finalize_upload_session` if a prior media object was atomically replaced; null if no replacement occurred
- `cleanup_claim_token` (UUID, nullable) — issued by `claim_cleanup_sessions`; must be presented to `mark_session_cleaned`
- `cleanup_claimed_at` (timestamptz, nullable)
- `cleanup_claim_expires_at` (timestamptz, nullable) — 15 minutes after issue; expired claims may be re-issued
- `cleanup_completed_at` (timestamptz, nullable) — set when transitioning to `cleaned`

**Concurrency constraint:**

```sql
CREATE UNIQUE INDEX upload_sessions_one_active_per_challenge
    ON private.upload_sessions (challenge_id)
    WHERE status IN ('pending', 'processing', 'sanitized');
```

This index enforces at the database level that at most one active upload session exists per challenge at any time. Concurrent calls to `create_upload_session` for the same challenge will see a unique constraint violation; only one succeeds. Application-level checks alone are insufficient.

### 2.3 Deletion Recovery Table Schema (`private.deletion_recovery_claims`)

- `user_id` (UUID, primary key, FK → `public.profiles(id)`) — one active claim per user at a time
- `scan_type` (text, not null) — `'database_prepared'` or `'auth_deleted'`; stored at claim time; verified by `complete_deletion_recovery`
- `claim_token` (UUID, not null)
- `claimed_at` (timestamptz, not null)
- `claim_expires_at` (timestamptz, not null) — 10 minutes after `claimed_at`; expired claims may be re-issued

### 2.4 Superseded Media Objects

When a poster replaces a draft photo by completing a new upload, `finalize_upload_session` atomically:
- Sets `challenges.media_object_id` to the new `media_object_id`
- Sets the prior `media_objects.status = 'superseded'`

The upload-cleanup-worker deletes the superseded photo's `re_encoded_storage_key` from storage and calls `mark_superseded_media_cleaned`, which sets `media_objects.status = 'cleaned'`.

V2 must also add `'superseded'` and `'cleaned'` as valid values for `media_objects.status`.

`activate_challenge` must reject a challenge whose `media_object_id` points to a `media_objects` row with `status != 'ready'`. This is enforced by a V2 trigger (Section 2.5).

### 2.5 V2 Database Constraints and Triggers

The V2 migration must add:

**Trigger — one active session on activation:**
A BEFORE UPDATE trigger on `public.challenges` fires when `state` would transition to `active`. It queries `private.upload_sessions` for any row with `challenge_id = NEW.id` and `status IN ('pending', 'processing', 'sanitized')`. If any exists → raise exception. This ensures `activate_challenge` cannot be called while a replacement upload is in progress.

**Trigger — media status on activation:**
The same (or a separate) trigger verifies `media_objects.status = 'ready'` for the challenge's `media_object_id` before allowing activation.

### 2.6 V2 Function Catalog

All functions below are public SECURITY DEFINER functions, granted EXECUTE only to `service_role`. No other role may execute them. They access `private.upload_sessions` and `private.deletion_recovery_claims` under their owner's privileges. No direct administrative reads of either table are permitted outside these functions.

#### Upload session — lifecycle

`public.create_upload_session(challenge_id uuid, uploader_id uuid, token_hash text, content_type text, declared_size bigint, expires_at timestamptz)`
→ `(session_id uuid, original_storage_path text, display_storage_path text)`
Enforces: poster identity, challenge in `draft` state. Attempts INSERT; if the partial unique index raises a unique violation → raises `FK_UPLOAD_IN_PROGRESS`. Does NOT supersede prior sessions. Generates `session_id`; constructs and records both storage paths; sets `status = 'pending'`, `status_changed_at = now()`.

`public.resolve_upload_session(token_hash text, uploader_id uuid)`
→ `(session_id uuid, status text, original_storage_path text, display_storage_path text, content_type text, processing_lease_expires_at timestamptz, media_object_id uuid, replaced_media_object_id uuid)`
Returns session data for the given token hash and uploader. Returns no row if the token does not exist or does not belong to the given uploader. Does not modify state. Returns `media_object_id` and `replaced_media_object_id` for idempotent completed-session retries.

`public.advance_upload_session_processing(session_id uuid, uploader_id uuid, lease_duration interval)`
→ `(original_storage_path text, display_storage_path text)`
Enforces: uploader identity, `status = 'pending'`, `now() < expires_at`; transitions to `processing`; sets `processing_lease_expires_at = now() + lease_duration`; updates `status_changed_at`.

`public.check_upload_session_lease(session_id uuid)`
→ `(is_valid bool)`
Returns true if `status = 'processing'` and `processing_lease_expires_at > now()`. Returns false otherwise. Does not modify state. Called by `upload-complete` before writing the display object to detect lease preemption by deletion or cleanup.

`public.advance_upload_session_sanitized(session_id uuid)`
→ void
Transitions `processing → sanitized`; updates `status_changed_at`. Raises an error if the session is not in `processing` state (e.g., it was failed by the deletion quiesce). The caller (`upload-complete`) must delete the display object if this function raises.

`public.finalize_upload_session(session_id uuid)`
→ `(media_object_id uuid, replaced_media_object_id uuid)`
Acquires a row-level lock on both the upload-session row and the challenge row (`SELECT ... FOR UPDATE` on each). Verifies upload-session status: if `complete` → returns stored `media_object_id` and `replaced_media_object_id` without modification (idempotent); if not `sanitized` → raises `FK_WRONG_STATE` (covers the case where `claim_cleanup_sessions` already transitioned the session to `failed`). Verifies `challenges.state = 'draft'`; if not → raises `FK_WRONG_STATE`. Atomically in a single transaction: inserts `public.media_objects` (`status = 'ready'`); inserts `private.media_storage_keys` (using both storage paths from the session row); if `challenges.media_object_id` is null: sets it to the new `media_object_id`; if already set: atomically updates to new `media_object_id` and sets prior `media_objects.status = 'superseded'`; saves `media_object_id` and `replaced_media_object_id` in the session row; transitions session to `complete`; updates `status_changed_at`. The session row lock ensures mutual exclusion with `claim_cleanup_sessions`, which uses `FOR UPDATE SKIP LOCKED`: if this function holds the lock, the cleanup worker skips the row; if the cleanup worker committed `sanitized → failed` first, this function raises `FK_WRONG_STATE`.

`public.fail_upload_session(session_id uuid, error_code text)`
→ void
Verifies session `status != 'complete'` before transitioning. If `complete` → raises an error (a complete session must never be failed). Otherwise transitions to `failed`; records `failed_reason`; updates `status_changed_at`. Idempotent if already `failed`.

#### Upload session — deletion quiesce

`public.quiesce_upload_sessions_for_deletion(user_id uuid)`
→ `TABLE(session_id uuid, original_storage_path text, display_storage_path text, prior_status text, blocking_lease_expires_at timestamptz)`
Atomically (single transaction):
1. Fails all `pending` sessions owned by `user_id`: transitions to `failed` with `failed_reason = 'FK_ACCOUNT_DELETED'`; updates `status_changed_at`; returns rows with `blocking_lease_expires_at = NULL` and `original_storage_path` set.
2. Fails all `sanitized` sessions owned by `user_id`: same transition; returns rows with `blocking_lease_expires_at = NULL` and `display_storage_path` set (original already deleted).
3. For each `processing` session owned by `user_id`:
   - If `processing_lease_expires_at <= now()` (lease expired): transitions to `failed` with `failed_reason = 'FK_ACCOUNT_DELETED'`; returns row with `blocking_lease_expires_at = NULL` and both paths set.
   - If `processing_lease_expires_at > now()` (lease active): does NOT fail the session; returns row with `blocking_lease_expires_at = processing_lease_expires_at` and both paths set. The deletion caller must not proceed while this lease is valid.
Never touches `complete`, `failed`, `expired`, or `cleaned` sessions.

`public.get_all_upload_session_paths_for_deletion(user_id uuid)`
→ `TABLE(session_id uuid, original_storage_path text, display_storage_path text, status text)`
Returns one row per upload session owned by `user_id` where `status NOT IN ('complete', 'cleaned')`. Includes sessions in every other state: `pending`, `processing`, `sanitized`, `failed`, `expired`. Does not modify state. Called after quiescing and confirming no blocking lease, to ensure every upload-session storage path is collected for deletion — including paths from sessions stopped by prior quiesce calls that have since become `failed`. Absent paths are no-op deletes in the caller.

#### Upload session — cleanup

`public.claim_cleanup_sessions(worker_id text, claim_duration interval DEFAULT '15 minutes')`
→ `TABLE(session_id uuid, original_storage_path text, display_storage_path text, status text, cleanup_claim_token uuid)`
Atomically (single transaction, `FOR UPDATE SKIP LOCKED` on eligible rows):
1. Transitions stale `pending` (where `expires_at + interval '60 seconds' < now()` and no unexpired claim) → `expired`; updates `status_changed_at`.
2. Transitions stale `processing` (where `processing_lease_expires_at < now()` and no unexpired claim) → `failed`; updates `status_changed_at`.
3. Transitions abandoned `sanitized` (where `processing_lease_expires_at + interval '60 minutes' < now()` and no unexpired claim) → `failed` with `failed_reason = 'FK_ABANDONED_SANITIZED'`; updates `status_changed_at`. This transition happens before the claim is issued, ensuring `finalize_upload_session` cannot commit a `sanitized → complete` transition for a session already committed to `failed` by this function. The `FOR UPDATE SKIP LOCKED` on the session row and the exclusive lock held by `finalize_upload_session` enforce mutual exclusion: if `finalize_upload_session` holds the lock, this function skips the row; if this function commits `failed` first, `finalize_upload_session` wakes to see `failed` and raises `FK_WRONG_STATE`.
4. Selects all `expired` and `failed` sessions where no unexpired claim exists or `cleanup_claim_expires_at < now()`.
5. Issues new `cleanup_claim_token`; sets `cleanup_claimed_at`, `cleanup_claim_expires_at`.
6. Returns claimed rows (all `expired` or `failed` at this point) with tokens. Never returns `complete`, `sanitized`, or `cleaned` sessions.

`public.mark_session_cleaned(session_id uuid, claim_token uuid)`
→ void
Verifies: (1) current session `status IN ('failed', 'expired')` — raises an error if status is `complete` or any other value (a complete session must never be transitioned to `cleaned`); (2) `cleanup_claim_token = claim_token`; (3) `cleanup_claim_expires_at > now()`. If any check fails → raises an error; does not transition. If all pass: transitions to `cleaned`; sets `cleanup_completed_at`, `status_changed_at`. Idempotent if already `cleaned`.

#### Superseded media

`public.get_superseded_media_to_clean()`
→ `TABLE(media_object_id uuid, re_encoded_storage_key text)`
Returns `media_objects` rows with `status = 'superseded'` joined to their `re_encoded_storage_key` from `private.media_storage_keys`.

`public.mark_superseded_media_cleaned(media_object_id uuid)`
→ void
Sets `media_objects.status = 'cleaned'`. Idempotent.

#### Media lookup

`public.get_media_storage_key(media_object_id uuid)`
→ `(re_encoded_storage_key text)`
Returns `re_encoded_storage_key` from `private.media_storage_keys` only if `media_objects.status = 'ready'`. Returns no row otherwise.

#### Challenge operations

`public.reveal_challenge_service_wrapper(challenge_id uuid)`
→ void
Public wrapper for `private.reveal_challenge_service(challenge_id)`. Called by `scheduled-close`.

#### Account deletion — wrappers for private functions

`public.prepare_account_deletion_wrapper(user_id uuid)`
→ `(status text)`
Wrapper for `private.prepare_account_deletion(user_id)`. V1's internal `pending` state is transient — this function does not return until the observable status is `database_prepared`. Returns the resulting status. Idempotent: if already `database_prepared`, returns without modification. If status is `auth_deleted` or `complete`, returns that status without modification.

`public.get_deletion_storage_keys(user_id uuid)`
→ `TABLE(media_object_id uuid, storage_key text)`
Wrapper for `private.get_storage_keys_for_deletion(user_id)`. Returns one distinct row per physical storage key for established `media_objects`. Does not include upload session storage paths; those are gathered separately by `get_all_upload_session_paths_for_deletion`.

`public.record_deletion_failure_wrapper(user_id uuid, error_code text)`
→ void
Wrapper for `private.record_deletion_failure(user_id, error_code)`. Accepts only sanitized error codes.

`public.mark_auth_deleted_wrapper(user_id uuid)`
→ void
Wrapper for `private.mark_auth_deleted(user_id)`. Required because `private.mark_auth_deleted` cannot be called through PostgREST.

`public.mark_storage_cleaned_wrapper(user_id uuid)`
→ void
Wrapper for `private.mark_storage_cleaned(user_id)`. Required because `private.mark_storage_cleaned` cannot be called through PostgREST.

#### Deletion-recovery-worker — claim functions

`public.claim_deletion_recovery_records(worker_id text, scan_age_threshold interval DEFAULT '10 minutes', claim_duration interval DEFAULT '10 minutes')`
→ `TABLE(user_id uuid, scan_type text, claim_token uuid)`
Atomically claims deletion records needing recovery: selects `database_prepared` records older than `scan_age_threshold` and all `auth_deleted` records — where no claim exists in `private.deletion_recovery_claims` or the existing claim has expired. For each: upserts a row with new `claim_token`, `claimed_at`, `claim_expires_at`, and `scan_type`. Returns claimed records with tokens.

`public.complete_deletion_recovery(user_id uuid, claim_token uuid, scan_type text)`
→ void
Verifies: (1) `claim_token` matches the stored `claim_token` in `private.deletion_recovery_claims`; (2) `claim_expires_at > now()`; (3) the stored `scan_type` matches the supplied `scan_type`. If any check fails → raises an error; does not advance state. If all checks pass: for `scan_type = 'database_prepared'`: calls `mark_auth_deleted_wrapper(user_id)` then `mark_storage_cleaned_wrapper(user_id)`; for `scan_type = 'auth_deleted'`: calls `mark_storage_cleaned_wrapper(user_id)`. Removes the claim row.

`public.fail_deletion_recovery(user_id uuid, claim_token uuid, error_code text)`
→ void
Verifies claim token and expiry. Calls `record_deletion_failure_wrapper(user_id, error_code)`. Removes the claim row so the record is re-claimable on the next worker run. If claim is invalid → raises an error.

---

## Section 3 — Cross-Cutting Contracts

### 3.1 Authentication

**`verify_jwt` setting:**
- User-facing functions (`upload-authorize`, `upload-complete`, `media-serve`, `account-delete-complete`) deploy with `verify_jwt = true`. Gateway JWT rejection returns its own `401` before the function runs. That response does not follow the Forkensics error envelope. This exception is documented here.
- Cron-authenticated functions and workers (`scheduled-close`, `upload-cleanup-worker`, `deletion-recovery-worker`) deploy with `verify_jwt = false`. They authenticate via the cron-secret pattern (Section 3.5).

**Standard gate (upload-authorize, upload-complete, media-serve):**
After gateway JWT verification:
1. Extract `sub` claim (user UUID). If absent or empty → `401 FK_UNAUTHENTICATED`.
2. Confirm `public.profiles` row where `id = sub` AND `is_active = true` AND `onboarding_complete = true`. If not → `403 FK_FORBIDDEN`.

**`account-delete-complete` gate (carve-out):**
After gateway JWT verification:
1. Extract `sub` claim. If absent or empty → `401 FK_UNAUTHENTICATED`.
2. Confirm `public.profiles` row where `id = sub`. Any `is_active` or `onboarding_complete` value is permitted.

### 3.2 Authorization

- **User-JWT layer:** Reads acting on behalf of a user use a Supabase client initialized with the user's JWT. RLS applies normally.
- **Administrative client layer:** Service-role operations use the administrative Supabase client (PostgREST as `service_role`). It calls only the V2 SECURITY DEFINER functions in Section 2.6, generates signed storage URLs, reads/writes/deletes storage objects, and calls the Admin API for user deletion. Never used to read data the user is not authorized to see.

### 3.3 Privileged Database Access Pattern

All privileged database operations use the public SECURITY DEFINER functions in Section 2.6. These functions are granted EXECUTE only to `service_role`. Both infrastructure tables are in the `private` schema. No direct administrative reads of `private.upload_sessions` or `private.deletion_recovery_claims` are permitted outside named functions.

`SUPABASE_DB_URL` is not used by Edge Functions. The `private` schema is never exposed through PostgREST.

### 3.4 Existence and Authorization Probing

For any challenge-scoped operation: if the challenge does not exist or if the caller is not authorized to see it, return `404 FK_NOT_FOUND` — not `403`.

### 3.5 Cron Authentication

Edge Functions do not read from Vault at runtime.

**Setup (once, before deployment):** Generate a cryptographically random secret (256 bits minimum). Store in two places:
1. Supabase Vault — read by pg_cron/pg_net to construct outbound requests.
2. Edge Function environment variables as `CRON_SECRET`.

**Request construction:** pg_cron reads the secret from Vault and sends it as `X-Forkensics-Cron-Secret: <secret>`.

**Receiving function:** Reads `X-Forkensics-Cron-Secret` header. Compares to `CRON_SECRET` using constant-time equality. If absent or mismatch → `401 FK_UNAUTHENTICATED`.

### 3.6 Error Response Format

All function-produced errors return JSON with `Content-Type: application/json`:

```json
{ "error": { "code": "FK_ERROR_CODE", "message": "Human-readable description" } }
```

Gateway-produced errors may not follow this format. That exception is documented here.

### 3.7 Standard Error Codes

| HTTP | Code | Meaning |
|---|---|---|
| 400 | `FK_INVALID_INPUT` | Missing or malformed request field |
| 400 | `FK_INVALID_CONTENT_TYPE` | Actual MIME not allowed, or actual MIME does not match `session.content_type` |
| 400 | `FK_FILE_TOO_LARGE` | Actual stored file exceeds 10 MB |
| 400 | `FK_INVALID_TOKEN` | Upload token missing, malformed, expired, or for a failed/unknown session |
| 401 | `FK_UNAUTHENTICATED` | Missing/invalid sub claim; or missing/mismatched cron secret |
| 403 | `FK_FORBIDDEN` | Valid JWT; caller does not meet `is_active` + `onboarding_complete` requirements |
| 404 | `FK_NOT_FOUND` | Resource does not exist or caller not authorized to see it |
| 409 | `FK_WRONG_STATE` | Resource is not in the required state for this operation |
| 409 | `FK_UPLOAD_IN_PROGRESS` | An active upload session exists; caller must wait |
| 422 | `FK_PROCESSING_FAILED` | Re-encoding or storage operation failed unrecoverably |
| 429 | `FK_RATE_LIMITED` | Too many requests |
| 500 | `FK_INTERNAL` | Unexpected server error — no internal detail exposed |

`FK_ALREADY_COMPLETE` is not used. A completed idempotent operation returns `200` with `"already_complete": true`.

### 3.8 Idempotency

- Completed operations return `200` with the original result and `"already_complete": true`.
- In-progress operations return `202 {"status": "processing"}`.
- Sessions in `failed` or `expired` state are not retryable. Client must call `upload-authorize` again. `upload-complete` with such a token returns `400 FK_INVALID_TOKEN`.
- Idempotency for non-upload operations is derived from stable inputs. No client-supplied idempotency headers required.

### 3.9 Logging

Logs must **never** contain: canonical dish name, restaurant name, or city; storage paths, keys, or signed URLs; EXIF or GPS data; secret keys, JWTs, upload tokens, token hashes, claim tokens, or cron secrets; raw storage error messages; any content from `challenge_secrets`.

Logs must contain: timestamp (ISO 8601), function or worker name, request ID, user UUID (authenticated functions only), challenge UUID (where applicable), sanitized outcome and error code.

### 3.10 Operational Failure Safety

- `upload-authorize` / `upload-complete` failure → challenge stays in `draft`; poster retries
- `media-serve` failure → image unavailable; gameplay unaffected
- `scheduled-close` failure → challenges remain open past deadline until next cron run
- `account-delete-complete` storage or quiesce-blocking failure → user can still authenticate and retry; no storage permanently abandoned
- Worker failure → state recoverable on next run; claims expire and are re-issued

### 3.11 Atomicity Boundary

Only operations within a single PostgreSQL transaction are atomic. Storage and PostgreSQL are not atomic with respect to each other. Each function contract specifies its compensating cleanup actions.

---

## Section 4 — Function Contracts

### 4.1 `upload-authorize`

**Purpose:** Record a new upload session and issue a time-limited signed URL.

**Method / Path:** `POST /upload-authorize`  **`verify_jwt`:** `true`

**Request body:**
```json
{ "challenge_id": "<uuid>", "content_type": "image/jpeg" | "image/webp", "declared_size_bytes": 1234567 }
```

**Authorization:** Standard gate (Section 3.1). `content_type` must be `image/jpeg` or `image/webp` → else `400 FK_INVALID_CONTENT_TYPE`. `declared_size_bytes` ≤ 10,485,760 → else `400 FK_FILE_TOO_LARGE`.

**Action:**
1. Generate secret upload token (256-bit cryptographically random). Compute SHA-256 hex hash.
2. Call `public.create_upload_session(challenge_id, user_id, token_hash, content_type, declared_size_bytes, now() + 5 minutes)`.
   - `FK_NOT_FOUND` → `404`.
   - `FK_WRONG_STATE` (not `draft`) → `409 FK_WRONG_STATE`.
   - `FK_UPLOAD_IN_PROGRESS` (unique index violation) → `409 FK_UPLOAD_IN_PROGRESS`. Client must wait.
3. Generate signed upload URL for `session.original_storage_path` in `game-media`, 5-minute expiry (administrative client). Generated after session row is committed.
4. Return signed URL and upload token. `session_id` and storage paths are internal; never returned to client.

**Response `200 OK`:**
```json
{ "signed_url": "<url>", "upload_token": "<secret token>", "expires_at": "<ISO 8601>" }
```

**Idempotency:** Not idempotent. Each call requires no active session for the challenge.

**Logging:** `challenge_id`, `user_id`, `content_type`, `session_id` (internal), outcome. NOT signed URL, token, hash, or paths.

---

### 4.2 `upload-complete`

**Purpose:** Validate the uploaded file, re-encode, confirm original deleted, atomically finalize.

**Method / Path:** `POST /upload-complete`  **`verify_jwt`:** `true`

**Request body:**
```json
{ "upload_token": "<secret token>" }
```

**Authorization:**
1. Standard gate (Section 3.1).
2. Compute SHA-256 hash of `upload_token`. Call `public.resolve_upload_session(token_hash, user_id)`. If no row → `400 FK_INVALID_TOKEN`.

**Idempotency branch (check session status before any action):**
- `complete` → `200 {"status":"ready","media_object_id":"<uuid>","replaced_media_object_id":"<uuid or null>","already_complete":true}`. Values come from `session.media_object_id` and `session.replaced_media_object_id` returned by `resolve_upload_session`.
- `processing` → `202 {"status":"processing"}`.
- `sanitized` → skip to finalization (step 9).
- `pending` → proceed to happy path.
- Any other status (`expired`, `failed`, `cleaned`) → `400 FK_INVALID_TOKEN`. Not retryable; client must call `upload-authorize`.

**Happy path (session status `pending`):**

1. Call `public.advance_upload_session_processing(session_id, user_id, '10 minutes')`. Verifies identity, pending status, not expired; transitions to `processing`; sets lease. Returns both paths. If fails → `400 FK_INVALID_TOKEN`.
2. Read original from `session.original_storage_path` (administrative client). If absent → `public.fail_upload_session(session_id, 'FK_NOT_FOUND')`; return `404 FK_NOT_FOUND`.
3. Sniff actual MIME from file bytes. Actual MIME must be `image/jpeg` or `image/webp` AND must match `session.content_type`. If either condition fails → delete original from storage; `public.fail_upload_session(session_id, 'FK_INVALID_CONTENT_TYPE')`; return `400 FK_INVALID_CONTENT_TYPE`.
4. Confirm actual stored size ≤ 10,485,760 bytes. If over → delete original from storage; `public.fail_upload_session(session_id, 'FK_FILE_TOO_LARGE')`; return `400 FK_FILE_TOO_LARGE`.
5. Re-encode to WebP; strip all EXIF, GPS, and embedded metadata. If re-encoding fails → delete original from storage; `public.fail_upload_session(session_id, 'FK_PROCESSING_FAILED')`; return `422 FK_PROCESSING_FAILED`.
5.5. Call `public.check_upload_session_lease(session_id)`. If returns false (session was failed by deletion quiesce or cleanup worker, or lease expired) → delete original from storage; return `422 FK_PROCESSING_FAILED`. Do NOT call `fail_upload_session` — the session has already been transitioned by another process. Do NOT proceed to write the display object.
6. Write re-encoded file to `session.display_storage_path` (administrative client — path read from session row). If write fails → delete original from storage; `public.fail_upload_session(session_id, 'FK_PROCESSING_FAILED')`; return `422 FK_PROCESSING_FAILED`.
7. Delete original from `session.original_storage_path`. Retry up to 2 times with brief backoff. If all attempts fail: delete display object (just written at `session.display_storage_path`); `public.fail_upload_session(session_id, 'FK_PROCESSING_FAILED')`; return `422 FK_PROCESSING_FAILED`.
8. Call `public.advance_upload_session_sanitized(session_id)`. If this raises for any reason (including the session having been failed by a concurrent deletion quiesce): delete display object (just written at `session.display_storage_path`); return `500 FK_INTERNAL`. Do not retry — the session is no longer in `processing` state. The display object at `session.display_storage_path` is a deterministic path; the cleanup worker will also delete it on its next run.

**Finalization (entered from step 8 of happy path, or from `sanitized` branch):**

9. Call `public.finalize_upload_session(session_id)`. Returns `(media_object_id, replaced_media_object_id)`. Acquires row-level locks on the upload-session row and the challenge row; verifies session status is `sanitized` (or idempotently `complete`); verifies challenge state is still `draft`. If challenge not `draft` → return `409 FK_WRONG_STATE`. If session not `sanitized` or `complete` (e.g., cleanup worker committed `failed` first) → return `409 FK_WRONG_STATE`; session is not retryable. Atomically: inserts `media_objects`, `media_storage_keys`; sets or swaps `challenges.media_object_id`; saves result IDs in session row; transitions to `complete`. If already `complete`, returns stored IDs. If finalization fails for other reasons and session remains `sanitized`: return `500 FK_INTERNAL`. Client retries with same token — re-enters `sanitized` branch.

**Response `200 OK`:**
```json
{ "media_object_id": "<uuid>", "status": "ready" }
```

**Logging:** `challenge_id`, `session_id` (internal), actual MIME string, actual stored size, outcomes of each major step. NOT storage paths, token, or hash.

---

### 4.3 `media-serve`

**Purpose:** Proxy the re-encoded challenge image to an authorized viewer.

**Method / Path:** `GET /media/{challenge_id}`  **`verify_jwt`:** `true`

**Authorization:**
1. Standard gate (Section 3.1).
2. Query `public.challenges` using user-JWT client: `SELECT id, media_object_id FROM public.challenges WHERE id = $challenge_id`. RLS enforces all visibility rules including `posted_at IS NOT NULL` (restricts draft to poster). No row returned → `404 FK_NOT_FOUND`.
3. `media_object_id` null → `404 FK_NOT_FOUND`.

**Action:**
1. Call `public.get_media_storage_key(media_object_id)` (administrative client). Returns `re_encoded_storage_key` if `media_objects.status = 'ready'`. No result → `404 FK_NOT_FOUND`. Key comes from the database — never constructed from `challenge_id` or `session_id`.
2. Read the file at `re_encoded_storage_key` from `game-media` (administrative client).
3. Stream bytes to client with `Content-Type: image/webp`, `Cache-Control: private, max-age=3600`.

**Logging:** `challenge_id`, `user_id`, outcome. NOT the storage key.

---

### 4.4 `scheduled-close`

**Purpose:** Lock and reveal challenges whose `deadline_at` has passed.

**Trigger:** Supabase pg_cron, every 2 minutes.  **`verify_jwt`:** `false`

**Authentication:** Cron-secret pattern (Section 3.5). If absent or mismatch → `401 FK_UNAUTHENTICATED`.

**Action:**

Pass 1: Query `challenges WHERE state = 'active' AND deadline_at <= now()` (administrative client). For each: call `public.lock_challenge(uuid)`. Catch per-row errors — log sanitized code, continue batch.

Pass 2: Query `challenges WHERE state = 'locked'` (administrative client). Revealed/cancelled excluded by predicate. For each: call `public.reveal_challenge_service_wrapper(uuid)`. Catch per-row errors — log, continue.

**Response `200 OK`:**
```json
{
  "locked_count": 3, "revealed_count": 3, "skipped_count": 0,
  "errors": [{ "challenge_id": "<uuid>", "pass": "lock" | "reveal", "error_code": "<sanitized>" }]
}
```

**Logging:** Counts and per-row sanitized error codes. NOT challenge content or canonical answers.

---

### 4.5 `account-delete-complete`

**Purpose:** Initiate or complete account deletion. Quiesces upload sessions, gathers and deletes all storage including upload-session paths, deletes `auth.users`, finalizes deletion record.

**Method / Path:** `POST /account-delete-complete`  **`verify_jwt`:** `true`

**Request body:** *(none)*

**Authentication:** Carve-out gate (Section 3.1). Valid JWT + existing profile row; `is_active` and `onboarding_complete` not checked.

**V1 deletion status states:**
- `pending` — transient; internal to `private.prepare_account_deletion()`. Never the observable state after the wrapper returns.
- `database_prepared` — observable state after `prepare_account_deletion_wrapper` returns.
- `auth_deleted` — after `mark_auth_deleted_wrapper` is called.
- `complete` — terminal; after `mark_storage_cleaned_wrapper` is called.

**Action:**

1. Call `public.prepare_account_deletion_wrapper(user_id)` (administrative client). Returns status.
   - `'database_prepared'` (new or existing) → continue.
   - `'auth_deleted'` → recovery worker handles; return `409 FK_WRONG_STATE`.
   - `'complete'` → log anomaly (JWT should be void); return `500 FK_INTERNAL`.
   - Error → `500 FK_INTERNAL`.
2. Call `public.quiesce_upload_sessions_for_deletion(user_id)` (administrative client). Atomically stops `pending`, `sanitized`, and expired-`processing` sessions; returns their paths and any still-active `processing` lease.
3. If any returned row has `blocking_lease_expires_at IS NOT NULL` (active processing session):
   - Return `409 FK_UPLOAD_IN_PROGRESS` with body `{"error":{"code":"FK_UPLOAD_IN_PROGRESS","message":"..."},"retry_after":"<ISO 8601 of MAX(blocking_lease_expires_at)>"}`.
   - **Stop here.** On the next retry: step 2 is called again; the blocking session's lease will have expired and the session will be stopped; all upload-session paths (including those stopped in this attempt) are collected in step 4.
4. Call `public.get_all_upload_session_paths_for_deletion(user_id)` (administrative client). Returns paths for every session with `status NOT IN ('complete', 'cleaned')` — includes the sessions just stopped by quiesce (now `failed`) plus any previously-stopped sessions from prior attempts that were `failed` or `expired` before this call.
5. Attempt to delete `original_storage_path` and `display_storage_path` for each row returned in step 4. Both paths are attempted per session; absent objects are no-op successes. Track failures.
6. Call `public.get_deletion_storage_keys(user_id)` (administrative client). Returns established media keys.
7. Delete all established media storage objects from `game-media`. Track failures.
8. If any storage deletion from step 5 or step 7 fails:
   - Call `public.record_deletion_failure_wrapper(user_id, 'FK_PROCESSING_FAILED')`.
   - Return `422 FK_PROCESSING_FAILED`. User can still authenticate and retry.
   - **Stop here.**
9. Delete the `auth.users` row (Admin API, administrative client). If fails → `500 FK_INTERNAL`. User can retry.
10. Call `public.mark_auth_deleted_wrapper(user_id)`. If fails: JWT is now void; client cannot retry. Log for recovery worker. Return `500 FK_INTERNAL`.
11. Call `public.mark_storage_cleaned_wrapper(user_id)`. Transitions to `complete`. If fails: same. Log for recovery worker. Return `500 FK_INTERNAL`.
12. Return `200 {"status":"complete"}`.

**Coverage guarantee:** Deletion reaches `complete` only after every storage path for every upload session (`get_all_upload_session_paths_for_deletion`) and every established media key (`get_deletion_storage_keys`) has been confirmed deleted. The cleanup worker does not need to complete before deletion can finish. Sessions that exist but whose storage is already absent (objects previously deleted) count as successes.

**Logging:** `user_id`, `quiesced_pending_count`, `quiesced_sanitized_count`, `blocking_session_count`, `session_paths_attempted`, `established_key_count`, `storage_objects_attempted`, `deleted_count`, `failed_count`, deletion record state at each step. NOT storage paths, key values, or file content.

---

### 4.6 `upload-cleanup-worker`

**Purpose:** Transition stale sessions, delete orphaned storage, clean superseded media, mark sessions `cleaned`.

**Trigger:** pg_cron, every 15 minutes.  **`verify_jwt`:** `false`

**Authentication:** Cron-secret pattern (Section 3.5).

**Action:**

Part 1 — upload session cleanup:
1. Call `public.claim_cleanup_sessions(worker_id, '15 minutes')`. Atomically transitions stale sessions — including abandoned `sanitized` → `failed` — and claims `expired` and `failed` rows. Returns sessions with `cleanup_claim_token`; all returned rows are in `expired` or `failed` state.
2. For each:
   a. Attempt to delete `original_storage_path`. May or may not exist depending on how far processing progressed. Absent = no-op.
   b. Attempt to delete `display_storage_path`. May or may not exist. Absent = no-op.
   c. If all applicable deletions succeeded: call `public.mark_session_cleaned(session_id, cleanup_claim_token)`. Verifies token and that status is still `failed` or `expired` before transitioning.
   d. If any deletion failed: do NOT call `mark_session_cleaned`. Session re-appears after claim expires.

Part 2 — superseded media cleanup:
1. Call `public.get_superseded_media_to_clean()`. Returns superseded media objects with `re_encoded_storage_key`.
2. For each: attempt to delete `re_encoded_storage_key`. If success → `public.mark_superseded_media_cleaned(media_object_id)`. If failure → log, retry next run.

**Response `200 OK`:**
```json
{
  "sessions_claimed": 5, "sessions_cleaned": 4, "sessions_cleanup_failed": 1,
  "objects_deleted": 7, "objects_absent": 1, "objects_failed": 0,
  "superseded_media_cleaned": 2, "superseded_media_failed": 0
}
```

**Logging:** Counts only. NOT storage paths, session IDs, or claim tokens.

---

### 4.7 `deletion-recovery-worker`

**Purpose:** Resume account deletions after the client JWT is void.

**Trigger:** pg_cron, every 5 minutes.  **`verify_jwt`:** `false`

**Authentication:** Cron-secret pattern (Section 3.5).

**Action:**

1. Call `public.claim_deletion_recovery_records(worker_id, '10 minutes', '10 minutes')`. Atomically claims `database_prepared` records older than 10 minutes and all `auth_deleted` records where no unexpired claim exists. Returns claimed records with claim tokens.

2. For each claimed record:

   **If `scan_type = 'database_prepared'`:**
   a. Check Auth (Admin API). If auth still exists → `public.fail_deletion_recovery(user_id, claim_token, 'FK_AUTH_STILL_EXISTS')`; skip.
   b. Auth is gone. Call `public.quiesce_upload_sessions_for_deletion(user_id)`.
   c. If any row has `blocking_lease_expires_at IS NOT NULL` → `public.fail_deletion_recovery(user_id, claim_token, 'FK_UPLOAD_IN_PROGRESS')`; leave in `database_prepared`; retry next run (lease will have expired).
   d. Call `public.get_all_upload_session_paths_for_deletion(user_id)`. Returns paths for all sessions with status not `complete` or `cleaned`, including `failed` and `expired` from prior attempts.
   e. Delete all returned session paths (both `original_storage_path` and `display_storage_path` per row). Absent = no-op. Track failures.
   f. Call `public.get_deletion_storage_keys(user_id)`. Delete all established media storage. Absent = no-op. Track failures.
   g. If any storage deletion failed → `public.fail_deletion_recovery(user_id, claim_token, 'FK_PROCESSING_FAILED')`; leave in `database_prepared`; retry next run.
   h. If all storage deleted → `public.complete_deletion_recovery(user_id, claim_token, 'database_prepared')`. Calls `mark_auth_deleted_wrapper` then `mark_storage_cleaned_wrapper` → `complete`.

   **If `scan_type = 'auth_deleted'`:**
   a. Call `public.quiesce_upload_sessions_for_deletion(user_id)`.
   b. If any blocking session → `public.fail_deletion_recovery(user_id, claim_token, 'FK_UPLOAD_IN_PROGRESS')`; retry next run.
   c. Call `public.get_all_upload_session_paths_for_deletion(user_id)`. Delete all returned session paths. Absent = no-op. Track failures.
   d. Call `public.get_deletion_storage_keys(user_id)`. Delete all established media storage. Absent = no-op. Track failures.
   e. If any storage deletion failed → `public.fail_deletion_recovery(user_id, claim_token, 'FK_PROCESSING_FAILED')`; retry next run.
   f. If all deleted → `public.complete_deletion_recovery(user_id, claim_token, 'auth_deleted')`. Calls `mark_storage_cleaned_wrapper` → `complete`.

**Response `200 OK`:**
```json
{
  "records_claimed": 2, "database_prepared_scanned": 1, "auth_deleted_scanned": 1,
  "completed": 1, "blocked_by_upload": 0, "storage_failures": 0, "errors": []
}
```

**Idempotency:** All V1 transition functions are idempotent. Claim tokens prevent concurrent duplicate processing. `complete_deletion_recovery` verifies both the claim token and the stored `scan_type`.

**Deployment gate:** `deletion-recovery-worker` must go live simultaneously with `account-delete-complete`.

**Logging:** Counts only. NOT user IDs, storage paths, claim tokens, or error details.

---

## Section 5 — Contract Test Requirements

### 5.1 Local Contract Tests

**Authentication and authorization:**
- Missing JWT → `401`; expired JWT → `401`
- Standard gate: `is_active = false` → `403`; `onboarding_complete = false` → `403`
- Carve-out: both conditions allowed for `account-delete-complete`
- Cron: missing or wrong `X-Forkensics-Cron-Secret` → `401`

**Existence and probing:**
- Nonexistent `challenge_id` → `404`; authorized caller not in group → same `404` body

**One active session per challenge (database enforcement):**
- Two concurrent `create_upload_session` calls for the same challenge → unique index violation; exactly one succeeds
- `upload-authorize` while session is `pending` → `409 FK_UPLOAD_IN_PROGRESS`
- `upload-authorize` while session is `processing` → `409 FK_UPLOAD_IN_PROGRESS`
- `upload-authorize` while session is `sanitized` → `409 FK_UPLOAD_IN_PROGRESS`
- `upload-authorize` after session is `failed` → allowed
- `upload-authorize` after session is `complete` (no active session) → allowed

**Activation race:**
- `activate_challenge` while active upload session exists → V2 trigger raises error
- `finalize_upload_session` acquires challenge lock; challenge transitions to `active` concurrently → `FK_WRONG_STATE`
- `finalize_upload_session` after challenge is `active` → `FK_WRONG_STATE`; idempotent if already `complete`

**Photo replacement:**
- `finalize_upload_session` when `challenges.media_object_id` already set (draft, prior session complete) → atomically swaps; prior `media_objects.status = 'superseded'`; `replaced_media_object_id` non-null in session row and response
- `activate_challenge` while any `media_objects.status != 'ready'` → V2 trigger raises error
- Cleanup worker deletes `re_encoded_storage_key` of superseded media; calls `mark_superseded_media_cleaned`

**Completed-session idempotency:**
- `upload-complete` on `complete` session → `200` with `media_object_id` and `replaced_media_object_id` from `session.media_object_id` and `session.replaced_media_object_id`
- `resolve_upload_session` returns both IDs for completed sessions

**MIME validation:**
- JPEG bytes declared `image/jpeg` → allowed
- WebP bytes declared `image/webp` → allowed
- JPEG bytes declared `image/webp` → `400 FK_INVALID_CONTENT_TYPE` (actual ≠ declared)
- WebP bytes declared `image/jpeg` → `400 FK_INVALID_CONTENT_TYPE`
- PNG bytes declared `image/jpeg` → `400 FK_INVALID_CONTENT_TYPE` (actual not allowed)
- Actual size > 10 MB → `400 FK_FILE_TOO_LARGE`

**Lease preemption in upload-complete:**
- Session failed by deletion quiesce between step 5 and step 5.5 → `check_upload_session_lease` returns false → original deleted from storage; display NOT written; `422 FK_PROCESSING_FAILED`
- `advance_upload_session_sanitized` raises (session failed by quiesce after display written) → display object deleted from storage; `500 FK_INTERNAL`
- Normal `advance_upload_session_sanitized` success → continues to finalization

**`fail_upload_session` guard:**
- `fail_upload_session` on `complete` session → raises error; session remains `complete`
- `fail_upload_session` on `failed` session → idempotent
- `fail_upload_session` on `pending`, `processing`, `sanitized` → transitions to `failed`

**Cleanup-vs-finalization mutual exclusion:**
- `claim_cleanup_sessions` acquires session row lock (`FOR UPDATE SKIP LOCKED`); simultaneously `finalize_upload_session` holds the same row lock → cleanup worker skips the row; finalization completes to `complete`; session is never returned by subsequent `claim_cleanup_sessions` calls (status is `complete`, excluded)
- `claim_cleanup_sessions` commits `sanitized → failed` first; `finalize_upload_session` subsequently sees `failed` → raises `FK_WRONG_STATE`; session is not finalized
- `mark_session_cleaned` on a `complete` session → raises error; session remains `complete`
- `mark_session_cleaned` on `failed` session with valid claim → transitions to `cleaned`
- `mark_session_cleaned` on `expired` session with valid claim → transitions to `cleaned`
- `claim_cleanup_sessions` never returns sessions in `sanitized` state (abandoned `sanitized` are transitioned to `failed` first)

**Account deletion — comprehensive path coverage:**
- Attempt 1: `pending` session quiesced to `failed`; `processing` session blocks; returns `409 FK_UPLOAD_IN_PROGRESS` — storage for the stopped `pending` session is NOT yet deleted; session is `failed`
- Attempt 2 (after processing lease expires): quiesce fails the expired `processing` session; `get_all_upload_session_paths_for_deletion` returns BOTH the prior `failed` (`pending`) session AND the newly-failed (`processing`) session; all paths deleted before proceeding — no paths orphaned
- Storage failure on attempt N → `422`; retry (attempt N+1) calls `get_all_upload_session_paths_for_deletion` again; previously-failed paths are retried
- Recovery worker retry involving a pre-existing `failed` session: `get_all_upload_session_paths_for_deletion` returns the `failed` session's paths alongside any newly quiesced paths; all deleted before `complete_deletion_recovery`
- `get_all_upload_session_paths_for_deletion` returns no rows for `complete` or `cleaned` sessions
- `get_all_upload_session_paths_for_deletion` returns rows for `pending`, `processing`, `sanitized`, `failed`, `expired` sessions

**Account deletion — quiescing:**
- `account-delete-complete` with `processing` session having valid lease → `409 FK_UPLOAD_IN_PROGRESS` with `retry_after`; established media not deleted; auth not deleted
- `account-delete-complete` after processing lease expires (retry) → quiesce fails the expired session; deletion proceeds
- `account-delete-complete` with `pending` session → quiesce fails it; `get_all_upload_session_paths_for_deletion` returns its paths; deleted before established media
- `account-delete-complete` with `sanitized` session → quiesce fails it; `get_all_upload_session_paths_for_deletion` returns its `display_storage_path`; deleted before established media
- Storage failure after quiesce → `422`; auth not deleted; user can retry
- Recovery worker: same quiescing + `get_all_upload_session_paths_for_deletion` pattern in both scans
- Recovery worker: `database_prepared`, auth gone, blocking session → `fail_deletion_recovery`; retried next run
- Recovery worker: `auth_deleted`, blocking session → same
- `complete_deletion_recovery('database_prepared')` calls `mark_auth_deleted_wrapper` then `mark_storage_cleaned_wrapper`
- `complete_deletion_recovery('auth_deleted')` calls only `mark_storage_cleaned_wrapper`

**Deletion-recovery-worker claims:**
- `claim_deletion_recovery_records` stores `scan_type` in `deletion_recovery_claims`
- `complete_deletion_recovery` with wrong `scan_type` → error; state not advanced
- `complete_deletion_recovery` with expired claim → error
- Concurrent recovery workers: claim disjoint records

**`mark_auth_deleted_wrapper` and `mark_storage_cleaned_wrapper`:**
- These wrappers are called; not `mark_auth_deleted` or `mark_storage_cleaned` directly
- Both are SECURITY DEFINER; GRANT EXECUTE TO service_role only

**`media-serve`:**
- RLS restricts draft to poster; no additional check in function code
- Poster in draft → `200`; group member in draft → `404`
- `media_object_id` null → `404`; status not `ready` → `404`
- Storage key served from `get_media_storage_key`; never path-constructed

**`scheduled-close`:**
- Active challenge past deadline → locked in Pass 1; revealed in Pass 2
- Already `locked` → not in Pass 1; revealed in Pass 2
- Already `revealed` → excluded by `WHERE state = 'locked'`; no per-row handling
- Per-row failure in Pass 1 does not abort Pass 2

**`account-delete-complete`:**
- First-time deletion, no prior record → `prepare_account_deletion_wrapper` creates → `database_prepared`
- Existing `database_prepared` → idempotent; continues from step 2
- Record `auth_deleted` → `409 FK_WRONG_STATE`
- `is_active = false` → allowed; `onboarding_complete = false` → allowed
- `mark_auth_deleted_wrapper` failure after auth deletion → `500`; recovery worker handles
- Only sanitized codes to `record_deletion_failure_wrapper`

**Private schema:**
- `private.upload_sessions` and `private.deletion_recovery_claims` not accessible through PostgREST
- Only named SECURITY DEFINER functions access either table

**Error format:**
- All function errors: `{ "error": { "code": "FK_...", "message": "..." } }`
- Logs contain no storage paths, tokens, or raw error messages

### 5.2 Production Verification (per-function, non-mutating)

| Function | Production probe |
|---|---|
| `upload-authorize` | Unauthenticated → `401`; authenticated with missing `challenge_id` → `400` |
| `upload-complete` | Unauthenticated → `401`; authenticated with missing `upload_token` → `400` |
| `media-serve` | Unauthenticated → `401`; authenticated with nonexistent `challenge_id` → `404` |
| `scheduled-close` | Wrong/absent cron secret → `401` |
| `upload-cleanup-worker` | Wrong/absent cron secret → `401` |
| `deletion-recovery-worker` | Wrong/absent cron secret → `401` |
| `account-delete-complete` | Unauthenticated → `401` only (authenticated probe would trigger deletion) |

### 5.3 What Contract Tests Must Never Do

- Call `reveal_challenge` or its wrapper on a real challenge
- Assert on or log canonical answers, restaurant names, or city values
- Leave test data in `forkensics-prod`
- Hard-code credentials
- Pass raw storage errors or paths to any `record_deletion_failure_wrapper` call

---

## Section 6 — Deployment Sequence

Gates for each deployment:
1. V2 migration complete and verified
2. Local contract tests pass
3. GPT implementation review
4. `APPROVED: Deploy {function-name}` from Bill
5. Deploy to `forkensics-dev`; smoke tests pass
6. `APPROVED: Deploy {function-name} to prod` from Bill
7. Deploy to `forkensics-prod`; per-function production probes pass (Section 5.2)

**Cron credential setup** must precede any cron-authenticated deployment.

**Deployment order:**
1. V2 migration (both `private` tables, all wrapper functions, partial unique index, V2 triggers) — Step 25
2. Cron credential setup
3. `upload-authorize`
4. `upload-complete` + `upload-cleanup-worker` (together)
5. `media-serve`
6. `scheduled-close`
7. `account-delete-complete` + `deletion-recovery-worker` (simultaneously)

---

## Section 7 — Out of Scope for Step 24

- Any TypeScript or Deno code
- Any `supabase functions deploy` command
- V2 migration SQL (covered in Step 25)
- Push notifications; Sign in with Apple configuration; iOS application code; Member removal
- Cron credential key management beyond Section 3.5

---

## Success Criteria for Step 24

- [ ] Decision matrix agreed: cancel/apply_correction permit poster or group owner; reason nullable; correct V1 mechanisms for comments and reactions
- [ ] Both infrastructure tables in `private` schema agreed
- [ ] Partial unique index agreed: database-level enforcement of one active session per challenge
- [ ] V2 trigger agreed: `activate_challenge` rejects while active upload session exists or media is not `ready`
- [ ] `finalize_upload_session` agreed: acquires session row lock; verifies `sanitized` or idempotent `complete`; acquires challenge row lock; verifies `draft` state; handles photo replacement atomically; raises `FK_WRONG_STATE` for any other session or challenge state
- [ ] `claim_cleanup_sessions` agreed: atomically transitions abandoned `sanitized → failed` before claiming; returns only `expired` or `failed` rows; `FOR UPDATE SKIP LOCKED` ensures mutual exclusion with `finalize_upload_session`
- [ ] `mark_session_cleaned` agreed: verifies status is `failed` or `expired` before transitioning; raises error for `complete`
- [ ] `fail_upload_session` agreed: raises error for `complete`; idempotent for `failed`
- [ ] `get_all_upload_session_paths_for_deletion` agreed: returns all session paths excluding `complete` and `cleaned`; used by both `account-delete-complete` and deletion-recovery-worker after quiescing to cover paths from prior attempts
- [ ] `mark_auth_deleted_wrapper` and `mark_storage_cleaned_wrapper` agreed: private schema functions require explicit public wrappers; no direct calls to private schema through PostgREST
- [ ] `media_object_id` and `replaced_media_object_id` in upload session table agreed; `finalize_upload_session` saves both; `resolve_upload_session` returns both
- [ ] Quiescing agreed: `quiesce_upload_sessions_for_deletion` atomically stops `pending`/`sanitized` and flags active `processing`; `account-delete-complete` returns `409 FK_UPLOAD_IN_PROGRESS` with `retry_after` when blocked
- [ ] `check_upload_session_lease` agreed: `upload-complete` verifies lease before writing display (step 5.5); deletes display if `advance_upload_session_sanitized` rejected
- [ ] `complete_deletion_recovery` scan_type verification agreed
- [ ] All V2 wrapper functions enumerated; no direct administrative reads of private tables outside named functions
- [ ] Persistent claim mechanism agreed for both workers; stale thresholds bound
- [ ] Per-function production probes agreed; `account-delete-complete` is unauthenticated-only
- [ ] Deployment order agreed; workers deployed with paired Edge Functions
- [ ] No Edge Function code written before approval
