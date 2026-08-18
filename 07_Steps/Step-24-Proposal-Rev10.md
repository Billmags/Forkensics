# Step 24 Proposal — Rev 10 — Edge Function Architecture and Contracts

**Status:** Pending review (Claude → Codex/GPT → Bill approval)
**Governance gate:** Bill must type `APPROVED: Step 24 — Edge Function Architecture and Contracts` before any Edge Function code is written.

**Scope:** Architecture decisions and binding contracts only. No TypeScript, no Deno code, no deployment. Implementation follows in separate per-function steps.

**Changes from Rev 9:**
Two targeted corrections to the storage-capability lifecycle:

1. **Capability creation serialized with account deletion.** `create_upload_session` is split into a two-function reservation/finalization handshake. `public.reserve_upload_session` locks the challenge row (`SELECT FOR UPDATE`) before verifying ownership and draft state, serializing it with any concurrent write to the same challenge row (including the `cancel_challenge` call inside `prepare_account_deletion_wrapper`). It also verifies the uploader has no deletion record in `database_prepared` or `auth_deleted` state before inserting the session. The session is inserted with `storage_upload_expires_at = NULL`, indicating that no capability has been issued yet. `public.activate_upload_session` is called after the presigned URL is generated, storing the actual URL expiry captured at signing time. The URL is never returned to the client unless `activate_upload_session` commits successfully. If URL generation or activation fails, `fail_upload_session` is called and the Edge Function returns 500; the URL (if generated) is never transmitted. Sessions with `storage_upload_expires_at = NULL` are treated as "no capability issued" by both `get_upload_capability_expiry` (excluded from blocking calculation) and `claim_cleanup_sessions` (no URL-expiry gate required). `storage_upload_expires_at` is therefore nullable in the schema. A concurrency test is added for `upload-authorize` vs `prepare_account_deletion_wrapper`.

2. **Unconfirmed overwrite-prevention claim removed.** Rev 9 stated that the `game-media` bucket has "upsert/overwrite disabled." Supabase's S3 compatibility layer supports `PutObject` but does not document conditional operations that would reject a write to an existing path. This was not verified against `forkensics-dev`. The claim is removed. The design already handles replay correctly through URL expiry (presigned PUTs are rejected after 5 minutes at the storage layer) plus cleanup worker Part 3 (post-expiry original-path delete for complete sessions). No additional overwrite prevention is assumed.

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
| `upload-authorize` | Reserve upload session (with challenge lock), generate S3 presigned PUT URL, activate session with actual expiry |
| `upload-complete` | Read original, re-encode, strip EXIF/GPS, delete original, write display object, finalize via V2 wrapper |
| `media-serve` | Proxy re-encoded image from private storage; fetch privileged storage key via V2 wrapper |
| `scheduled-close` | Cron-triggered; locks and reveals challenges past `deadline_at`; no user JWT |
| `account-delete-complete` | Quiesce upload sessions, wait for storage capabilities to expire, gather and delete all storage, call V2 deletion wrappers, delete `auth.users` |

### Background Workers

| Worker | Purpose |
|---|---|
| `upload-cleanup-worker` | Transition stale sessions, delete orphaned storage post-URL-expiry, post-expiry original-path cleanup for complete sessions, handle superseded media, mark sessions `cleaned` |
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
expired | failed → cleaned                         (cleanup worker: post-URL-expiry, storage confirmed deleted)
complete                                           (terminal; never cleaned or failed; original-path post-expiry delete tracked separately)
```

State semantics:

- `pending`: session reserved; presigned PUT URL may or may not have been issued (see `storage_upload_expires_at`)
- `processing`: `upload-complete` has claimed the session and begun processing
- `sanitized`: re-encoding complete, original confirmed deleted, display object written; DB finalization not yet committed
- `complete`: DB finalization committed; all DB records set; terminal — cannot be transitioned to any other state; original path is deleted post-expiry by the cleanup worker without changing this status
- `expired`: stale `pending` session past `expires_at + 60 seconds`; transitioned by cleanup worker
- `failed`: unrecoverable error; not retryable — client must call `upload-authorize` again
- `cleaned`: all associated storage objects confirmed deleted after URL expiry; terminal for all non-`complete` paths

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
- `expires_at` (timestamptz, not null) — upload-complete claim window; enforced at `advance_upload_session_processing`
- `storage_upload_expires_at` (timestamptz, **nullable**) — the actual expiry of the S3 presigned PUT URL, set by `activate_upload_session` after signing; **NULL means no capability was ever successfully issued to the client** (session was reserved but URL generation or activation failed, or session was failed before activation). NULL sessions are excluded from `get_upload_capability_expiry` and from `claim_cleanup_sessions`'s URL-expiry gate.
- `processing_lease_expires_at` (timestamptz, nullable) — set when transitioning to `processing`; used to detect stale sessions and to fence concurrent deletion
- `status` (text, not null) — one of the seven states above
- `status_changed_at` (timestamptz, not null) — updated on every status transition
- `failed_reason` (text, nullable) — sanitized error code only; no storage paths, no raw error text
- `media_object_id` (UUID, nullable) — set by `finalize_upload_session` when the session reaches `complete`; returned by `resolve_upload_session` for idempotent retries
- `replaced_media_object_id` (UUID, nullable) — set by `finalize_upload_session` if a prior media object was atomically replaced; null if no replacement occurred
- `original_path_post_expiry_cleaned` (bool, not null, default false) — set by the cleanup worker's Part 3 after confirming the original-path delete on a `complete` session; prevents repeated cleanup attempts
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

This index enforces at the database level that at most one active upload session exists per challenge at any time. `reserve_upload_session` locks the challenge row before inserting; concurrent reservation attempts serialize on that lock and the first to commit prevents the second via this index.

### 2.3 Deletion Recovery Table Schema (`private.deletion_recovery_claims`)

- `user_id` (UUID, primary key, FK → `public.profiles(id)`) — one active claim per user at a time
- `scan_type` (text, not null) — `'database_prepared'` or `'auth_deleted'`; stored at claim time; verified by `complete_deletion_recovery`
- `claim_token` (UUID, not null)
- `claimed_at` (timestamptz, not null)
- `claim_expires_at` (timestamptz, not null) — 10 minutes after `claimed_at`; expired claims may be re-issued

### 2.4 Bucket Configuration (`game-media`)

- Visibility: private; no public policies
- Max upload size: 10 MB
- Allowed MIME types: `image/jpeg`, `image/webp`
- Upload mechanism: S3-compatible presigned PUT (not Supabase's `createSignedUploadUrl()`); 5-minute expiry baked into the signed URL and enforced by the storage layer independent of database session state. Non-overwrite conditional behavior (`If-None-Match` or equivalent) is not assumed — Supabase's S3 compatibility layer supports `PutObject` but does not document conditional operations. Replay safety is provided entirely by URL expiry (the presigned URL is invalid after 5 minutes) and cleanup worker Part 3 (post-expiry original-path delete for complete sessions handles any re-upload that occurred within the window).

### 2.5 Superseded Media Objects

When a poster replaces a draft photo by completing a new upload, `finalize_upload_session` atomically:
- Sets `challenges.media_object_id` to the new `media_object_id`
- Sets the prior `media_objects.status = 'superseded'`

The upload-cleanup-worker deletes the superseded photo's `re_encoded_storage_key` from storage and calls `mark_superseded_media_cleaned`, which sets `media_objects.status = 'cleaned'`.

V2 must also add `'superseded'` and `'cleaned'` as valid values for `media_objects.status`.

`activate_challenge` must reject a challenge whose `media_object_id` points to a `media_objects` row with `status != 'ready'`. This is enforced by a V2 trigger (Section 2.6).

### 2.6 V2 Database Constraints and Triggers

The V2 migration must add:

**Trigger — one active session on activation:**
A BEFORE UPDATE trigger on `public.challenges` fires when `state` would transition to `active`. It queries `private.upload_sessions` for any row with `challenge_id = NEW.id` and `status IN ('pending', 'processing', 'sanitized')`. If any exists → raise exception.

**Trigger — media status on activation:**
The same (or a separate) trigger verifies `media_objects.status = 'ready'` for the challenge's `media_object_id` before allowing activation.

### 2.7 V2 Function Catalog

All functions below are public SECURITY DEFINER functions, granted EXECUTE only to `service_role`. No other role may execute them. They access `private.upload_sessions` and `private.deletion_recovery_claims` under their owner's privileges. No direct administrative reads of either table are permitted outside these functions.

#### Upload session — lifecycle

`public.reserve_upload_session(challenge_id uuid, uploader_id uuid, token_hash text, content_type text, declared_size bigint, client_expires_at timestamptz)`
→ `(session_id uuid, original_storage_path text, display_storage_path text)`
In a single transaction:
1. Acquires a row-level lock on the challenge (`SELECT id, poster_id, state FROM public.challenges WHERE id = challenge_id FOR UPDATE`). This serializes session reservation with any concurrent write to the same challenge row, including the `cancel_challenge` call inside `prepare_account_deletion_wrapper`. If `prepare_account_deletion_wrapper` wins the lock first, the challenge will be non-draft when this function acquires it and the reservation fails. If this function wins, `prepare_account_deletion_wrapper` waits until the session row is committed before it can cancel the challenge and proceed to the upload-session quiesce.
2. Verifies `challenges.poster_id = uploader_id` → else raises `FK_NOT_FOUND`.
3. Verifies `challenges.state = 'draft'` → else raises `FK_WRONG_STATE`.
4. Verifies the uploader has no deletion record in `database_prepared` or `auth_deleted` state in the `private` schema → else raises `FK_FORBIDDEN`. This prevents issuing a URL to a user who has initiated account deletion.
5. Attempts INSERT into `private.upload_sessions` with `storage_upload_expires_at = NULL` (no capability issued yet), `status = 'pending'`, `status_changed_at = now()`. If the partial unique index raises a unique violation → raises `FK_UPLOAD_IN_PROGRESS`.
6. Returns `(session_id, original_storage_path, display_storage_path)`.
`storage_upload_expires_at` remains NULL until `activate_upload_session` commits. A session with NULL expiry has no issued storage capability.

`public.activate_upload_session(session_id uuid, actual_storage_upload_expires_at timestamptz)`
→ void
Verifies: session `status = 'pending'` AND `storage_upload_expires_at IS NULL` (not yet activated). Sets `storage_upload_expires_at = actual_storage_upload_expires_at`. Does not change `status`. Raises an error if session is not `pending` or if `storage_upload_expires_at` is already set. Called after the presigned URL is generated and before the URL is returned to the client. Once this commits, the storage capability is durably recorded at its actual expiry. If this function raises for any reason, the caller must not return the URL to the client.

`public.resolve_upload_session(token_hash text, uploader_id uuid)`
→ `(session_id uuid, status text, original_storage_path text, display_storage_path text, content_type text, storage_upload_expires_at timestamptz, processing_lease_expires_at timestamptz, media_object_id uuid, replaced_media_object_id uuid)`
Returns session data for the given token hash and uploader. `storage_upload_expires_at` may be NULL if the session was reserved but never activated. Returns no row if the token does not exist or does not belong to the given uploader. Does not modify state.

`public.advance_upload_session_processing(session_id uuid, uploader_id uuid, lease_duration interval)`
→ `(original_storage_path text, display_storage_path text)`
Enforces: uploader identity, `status = 'pending'`, `now() < expires_at`; transitions to `processing`; sets `processing_lease_expires_at = now() + lease_duration`; updates `status_changed_at`.

`public.check_upload_session_lease(session_id uuid)`
→ `(is_valid bool)`
Returns true if `status = 'processing'` and `processing_lease_expires_at > now()`. Returns false otherwise. Does not modify state.

`public.advance_upload_session_sanitized(session_id uuid)`
→ void
Transitions `processing → sanitized`; updates `status_changed_at`. Raises an error if session is not in `processing` state. Caller must delete the display object if this raises.

`public.finalize_upload_session(session_id uuid)`
→ `(media_object_id uuid, replaced_media_object_id uuid)`
Acquires row-level locks on the upload-session row and the challenge row. Verifies upload-session status: if `complete` → returns stored IDs (idempotent); if not `sanitized` → raises `FK_WRONG_STATE`. Verifies `challenges.state = 'draft'`; if not → raises `FK_WRONG_STATE`. Atomically: inserts `public.media_objects` (`status = 'ready'`); inserts `private.media_storage_keys`; sets or swaps `challenges.media_object_id`; saves `media_object_id` and `replaced_media_object_id` in session row; transitions to `complete`; updates `status_changed_at`. Session row lock ensures mutual exclusion with `claim_cleanup_sessions` via `FOR UPDATE SKIP LOCKED`.

`public.fail_upload_session(session_id uuid, error_code text)`
→ void
Verifies session `status != 'complete'`; raises an error if `complete`. Transitions to `failed`; records `failed_reason`; updates `status_changed_at`. Idempotent if already `failed`. May be called with a NULL `storage_upload_expires_at` session (URL generation failed before activation; treated as "no capability issued").

#### Upload session — deletion quiesce and capability check

`public.quiesce_upload_sessions_for_deletion(user_id uuid)`
→ `TABLE(session_id uuid, original_storage_path text, display_storage_path text, prior_status text, blocking_lease_expires_at timestamptz)`
Atomically (single transaction):
1. Fails all `pending` sessions owned by `user_id`: transitions to `failed` with `failed_reason = 'FK_ACCOUNT_DELETED'`; returns rows with `blocking_lease_expires_at = NULL`.
2. Fails all `sanitized` sessions: same transition; returns rows with `blocking_lease_expires_at = NULL` and `display_storage_path` set.
3. For each `processing` session: if lease expired → fails and returns; if lease active → does NOT fail; returns row with `blocking_lease_expires_at = processing_lease_expires_at`.
Never touches `complete`, `failed`, `expired`, or `cleaned` sessions.

`public.get_upload_capability_expiry(user_id uuid)`
→ `(blocking_until timestamptz)`
Returns `MAX(storage_upload_expires_at + interval '30 seconds')` across all sessions owned by `user_id` where **`storage_upload_expires_at IS NOT NULL`** and `status != 'cleaned'` and `storage_upload_expires_at + interval '30 seconds' > now()`. Returns NULL if all issued upload capabilities have expired, no non-`cleaned` sessions with non-NULL expiry exist, or all non-`cleaned` sessions have NULL expiry (no capabilities ever issued). Sessions with `storage_upload_expires_at = NULL` are excluded — NULL means no capability was issued, so no storage-layer replay is possible.

`public.get_all_upload_session_paths_for_deletion(user_id uuid)`
→ `TABLE(session_id uuid, original_storage_path text, display_storage_path text, status text)`
Returns one row per session owned by `user_id` where `status != 'cleaned'`. Includes ALL statuses including `complete`. For `complete` sessions: `display_storage_path = NULL` (display covered by `get_deletion_storage_keys`); `original_storage_path` returned to catch any re-upload within the presigned window. For non-`complete` sessions: both paths returned. Must only be called after `get_upload_capability_expiry` returns NULL. Sessions with `storage_upload_expires_at = NULL` (no capability issued) are included; their `original_storage_path` is deleted as a precaution (it may or may not exist).

#### Upload session — cleanup

`public.claim_cleanup_sessions(worker_id text, claim_duration interval DEFAULT '15 minutes')`
→ `TABLE(session_id uuid, original_storage_path text, display_storage_path text, status text, cleanup_claim_token uuid)`
Atomically (single transaction, `FOR UPDATE SKIP LOCKED` on eligible rows):
1. Transitions stale `pending` (where `expires_at + interval '60 seconds' < now()` and no unexpired claim) → `expired`; updates `status_changed_at`.
2. Transitions stale `processing` (where `processing_lease_expires_at < now()` and no unexpired claim) → `failed`; updates `status_changed_at`.
3. Transitions abandoned `sanitized` (where `processing_lease_expires_at + interval '60 minutes' < now()` and no unexpired claim) → `failed` with `failed_reason = 'FK_ABANDONED_SANITIZED'`; updates `status_changed_at`. Mutual exclusion with `finalize_upload_session` via `FOR UPDATE SKIP LOCKED`.
4. **URL-expiry gate:** Selects `expired` and `failed` sessions where no unexpired claim exists AND **either `storage_upload_expires_at IS NULL` (no capability was ever issued — no gate needed) OR `storage_upload_expires_at + interval '30 seconds' <= now()` (issued capability has expired)**. Sessions with a still-valid issued URL are excluded.
5. Issues new `cleanup_claim_token`; sets `cleanup_claimed_at`, `cleanup_claim_expires_at`.
6. Returns claimed rows with tokens. Never returns `complete`, `sanitized`, or `cleaned` sessions.

`public.mark_session_cleaned(session_id uuid, claim_token uuid)`
→ void
Verifies: (1) current session `status IN ('failed', 'expired')` — raises error for `complete` or any other value; (2) `cleanup_claim_token = claim_token`; (3) `cleanup_claim_expires_at > now()`. If all pass: transitions to `cleaned`; sets `cleanup_completed_at`, `status_changed_at`. Idempotent if already `cleaned`.

`public.mark_original_path_post_expiry_cleaned(session_id uuid)`
→ void
Sets `original_path_post_expiry_cleaned = true` for a `complete` session. Does not change `status`. Raises error if `status != 'complete'`.

#### Superseded media

`public.get_superseded_media_to_clean()`
→ `TABLE(media_object_id uuid, re_encoded_storage_key text)`
Returns `media_objects` rows with `status = 'superseded'` joined to `re_encoded_storage_key`.

`public.mark_superseded_media_cleaned(media_object_id uuid)`
→ void
Sets `media_objects.status = 'cleaned'`. Idempotent.

#### Media lookup

`public.get_media_storage_key(media_object_id uuid)`
→ `(re_encoded_storage_key text)`
Returns `re_encoded_storage_key` if `media_objects.status = 'ready'`. Returns no row otherwise.

#### Challenge operations

`public.reveal_challenge_service_wrapper(challenge_id uuid)`
→ void
Public wrapper for `private.reveal_challenge_service(challenge_id)`. Called by `scheduled-close`.

#### Account deletion — wrappers for private functions

`public.prepare_account_deletion_wrapper(user_id uuid)`
→ `(status text)`
Wrapper for `private.prepare_account_deletion(user_id)`. V1's `cancel_challenge` (called internally) acquires row-level locks on challenge rows; this serializes with any concurrent `reserve_upload_session` that holds a challenge lock. Returns `database_prepared` after the V1 function completes. Idempotent for `database_prepared`; returns existing status for `auth_deleted` or `complete`.

`public.get_deletion_storage_keys(user_id uuid)`
→ `TABLE(media_object_id uuid, storage_key text)`
Wrapper for `private.get_storage_keys_for_deletion(user_id)`. Returns established media keys. Does not include upload session paths.

`public.record_deletion_failure_wrapper(user_id uuid, error_code text)`
→ void
Wrapper for `private.record_deletion_failure(user_id, error_code)`. Accepts only sanitized error codes.

`public.mark_auth_deleted_wrapper(user_id uuid)`
→ void
Wrapper for `private.mark_auth_deleted(user_id)`.

`public.mark_storage_cleaned_wrapper(user_id uuid)`
→ void
Wrapper for `private.mark_storage_cleaned(user_id)`.

#### Deletion-recovery-worker — claim functions

`public.claim_deletion_recovery_records(worker_id text, scan_age_threshold interval DEFAULT '10 minutes', claim_duration interval DEFAULT '10 minutes')`
→ `TABLE(user_id uuid, scan_type text, claim_token uuid)`
Atomically claims `database_prepared` records older than `scan_age_threshold` and all `auth_deleted` records without an unexpired claim. Upserts claim rows with new token and stored `scan_type`.

`public.complete_deletion_recovery(user_id uuid, claim_token uuid, scan_type text)`
→ void
Verifies claim token, expiry, and that stored `scan_type` matches supplied `scan_type`. For `database_prepared`: calls `mark_auth_deleted_wrapper` then `mark_storage_cleaned_wrapper`. For `auth_deleted`: calls `mark_storage_cleaned_wrapper`. Removes claim row.

`public.fail_deletion_recovery(user_id uuid, claim_token uuid, error_code text)`
→ void
Verifies claim token and expiry. Calls `record_deletion_failure_wrapper`. Removes claim row.

---

## Section 3 — Cross-Cutting Contracts

### 3.1 Authentication

**`verify_jwt` setting:**
- User-facing functions (`upload-authorize`, `upload-complete`, `media-serve`, `account-delete-complete`) deploy with `verify_jwt = true`. Gateway JWT rejection returns its own `401` before the function runs and does not follow the Forkensics error envelope. This exception is documented here.
- Cron-authenticated functions and workers (`scheduled-close`, `upload-cleanup-worker`, `deletion-recovery-worker`) deploy with `verify_jwt = false`. They authenticate via the cron-secret pattern (Section 3.5).

**Standard gate (upload-authorize, upload-complete, media-serve):**
After gateway JWT verification:
1. Extract `sub` claim. If absent or empty → `401 FK_UNAUTHENTICATED`.
2. Confirm `public.profiles` row where `id = sub` AND `is_active = true` AND `onboarding_complete = true`. If not → `403 FK_FORBIDDEN`.

**`account-delete-complete` gate (carve-out):**
After gateway JWT verification:
1. Extract `sub` claim. If absent or empty → `401 FK_UNAUTHENTICATED`.
2. Confirm `public.profiles` row where `id = sub`. Any `is_active` or `onboarding_complete` value is permitted.

### 3.2 Authorization

- **User-JWT layer:** Reads acting on behalf of a user use a Supabase client initialized with the user's JWT. RLS applies normally.
- **Administrative client layer:** Service-role operations use the administrative Supabase client (PostgREST as `service_role`). It calls only the V2 SECURITY DEFINER functions in Section 2.7, generates S3 presigned PUT URLs, reads/writes/deletes storage objects, and calls the Admin API for user deletion. Never used to read data the user is not authorized to see.

### 3.3 Privileged Database Access Pattern

All privileged database operations use the public SECURITY DEFINER functions in Section 2.7. These functions are granted EXECUTE only to `service_role`. Both infrastructure tables are in the `private` schema. No direct administrative reads of `private.upload_sessions` or `private.deletion_recovery_claims` are permitted outside named functions.

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
| 403 | `FK_FORBIDDEN` | Valid JWT; caller does not meet access requirements (including deletion in progress) |
| 404 | `FK_NOT_FOUND` | Resource does not exist or caller not authorized to see it |
| 409 | `FK_WRONG_STATE` | Resource is not in the required state for this operation |
| 409 | `FK_UPLOAD_IN_PROGRESS` | An active upload session exists or a presigned URL is still valid; caller must wait |
| 422 | `FK_PROCESSING_FAILED` | Re-encoding or storage operation failed unrecoverably |
| 429 | `FK_RATE_LIMITED` | Too many requests |
| 500 | `FK_INTERNAL` | Unexpected server error — no internal detail exposed |

`FK_ALREADY_COMPLETE` is not used. A completed idempotent operation returns `200` with `"already_complete": true`.

### 3.8 Idempotency

- Completed operations return `200` with the original result and `"already_complete": true`.
- In-progress operations return `202 {"status": "processing"}`.
- Sessions in `failed` or `expired` state are not retryable. Client must call `upload-authorize` again.
- Idempotency for non-upload operations is derived from stable inputs.

### 3.9 Logging

Logs must **never** contain: canonical dish name, restaurant name, or city; storage paths, keys, or signed URLs; EXIF or GPS data; secret keys, JWTs, upload tokens, token hashes, claim tokens, or cron secrets; raw storage error messages; any content from `challenge_secrets`.

Logs must contain: timestamp (ISO 8601), function or worker name, request ID, user UUID (authenticated functions only), challenge UUID (where applicable), sanitized outcome and error code.

### 3.10 Operational Failure Safety

- `upload-authorize` / `upload-complete` failure → challenge stays in `draft`; poster retries
- `media-serve` failure → image unavailable; gameplay unaffected
- `scheduled-close` failure → challenges remain open past deadline until next cron run
- `account-delete-complete` storage or URL-expiry blocking failure → user can still authenticate and retry; no storage permanently abandoned
- Worker failure → state recoverable on next run; claims expire and are re-issued

### 3.11 Atomicity Boundary

Only operations within a single PostgreSQL transaction are atomic. Storage and PostgreSQL are not atomic with respect to each other. Each function contract specifies its compensating cleanup actions.

---

## Section 4 — Function Contracts

### 4.1 `upload-authorize`

**Purpose:** Reserve an upload session (with challenge lock and deletion check), generate a presigned PUT URL, activate the session with the actual URL expiry, then return the URL to the client.

**Method / Path:** `POST /upload-authorize`  **`verify_jwt`:** `true`

**Request body:**
```json
{ "challenge_id": "<uuid>", "content_type": "image/jpeg" | "image/webp", "declared_size_bytes": 1234567 }
```

**Authorization:** Standard gate (Section 3.1). `content_type` must be `image/jpeg` or `image/webp` → else `400 FK_INVALID_CONTENT_TYPE`. `declared_size_bytes` ≤ 10,485,760 → else `400 FK_FILE_TOO_LARGE`.

**Action:**
1. Generate secret upload token (256-bit cryptographically random). Compute SHA-256 hex hash.
2. Call `public.reserve_upload_session(challenge_id, user_id, token_hash, content_type, declared_size_bytes, now() + 5 minutes)` (administrative client). This locks the challenge row, verifies draft state and poster identity, verifies the uploader has no active deletion record, and inserts the session with `storage_upload_expires_at = NULL`.
   - `FK_NOT_FOUND` → `404`.
   - `FK_WRONG_STATE` (challenge not draft) → `409 FK_WRONG_STATE`.
   - `FK_FORBIDDEN` (uploader has deletion in progress) → `403 FK_FORBIDDEN`.
   - `FK_UPLOAD_IN_PROGRESS` (unique index violation) → `409 FK_UPLOAD_IN_PROGRESS`.
3. Generate S3-compatible presigned PUT URL for `session.original_storage_path` in `game-media` with a true 5-minute expiry. Capture the actual expiry timestamp at the moment of signing. If URL generation fails → call `public.fail_upload_session(session_id, 'FK_INTERNAL')`; return `500 FK_INTERNAL`. (Session has NULL expiry; cleanup worker treats as "no capability issued"; no URL-expiry gate.)
4. Call `public.activate_upload_session(session_id, actual_storage_upload_expires_at)` (administrative client). If this fails for any reason → do NOT return the presigned URL to the client; call `public.fail_upload_session(session_id, 'FK_INTERNAL')`; return `500 FK_INTERNAL`. The URL was generated in memory but was never transmitted; it expires within 5 minutes with no client holding it.
5. After step 4 commits: return the presigned URL and upload token to the client. `session_id`, storage paths, and `storage_upload_expires_at` are internal; never returned.

**Invariant:** The client receives the URL only if and only if `activate_upload_session` committed successfully, meaning the database durably records the actual expiry. No capability is ever live without a corresponding database record.

**Response `200 OK`:**
```json
{ "presigned_url": "<url>", "upload_token": "<secret token>", "expires_at": "<ISO 8601>" }
```

**Idempotency:** Not idempotent. Each call requires no active session for the challenge.

**Logging:** `challenge_id`, `user_id`, `content_type`, `session_id` (internal), activation outcome. NOT the presigned URL, token, hash, or paths.

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
- `complete` → `200 {"status":"ready","media_object_id":"<uuid>","replaced_media_object_id":"<uuid or null>","already_complete":true}`.
- `processing` → `202 {"status":"processing"}`.
- `sanitized` → skip to finalization (step 9).
- `pending` → proceed to happy path.
- Any other status (`expired`, `failed`, `cleaned`) → `400 FK_INVALID_TOKEN`.

**Happy path (session status `pending`):**

1. Call `public.advance_upload_session_processing(session_id, user_id, '10 minutes')`. Verifies identity, pending status, not expired; transitions to `processing`; sets lease. Returns both paths. If fails → `400 FK_INVALID_TOKEN`.
2. Read original from `session.original_storage_path`. If absent → `fail_upload_session(session_id, 'FK_NOT_FOUND')`; return `404 FK_NOT_FOUND`.
3. Sniff actual MIME. Must be `image/jpeg` or `image/webp` AND match `session.content_type`. If fails → delete original; `fail_upload_session(session_id, 'FK_INVALID_CONTENT_TYPE')`; return `400 FK_INVALID_CONTENT_TYPE`.
4. Confirm actual size ≤ 10,485,760 bytes. If over → delete original; `fail_upload_session(session_id, 'FK_FILE_TOO_LARGE')`; return `400 FK_FILE_TOO_LARGE`.
5. Re-encode to WebP; strip all EXIF, GPS, metadata. If fails → delete original; `fail_upload_session(session_id, 'FK_PROCESSING_FAILED')`; return `422 FK_PROCESSING_FAILED`.
5.5. Call `public.check_upload_session_lease(session_id)`. If false → delete original; return `422 FK_PROCESSING_FAILED`. Do NOT call `fail_upload_session`. Do NOT write display.
6. Write re-encoded file to `session.display_storage_path`. If fails → delete original; `fail_upload_session(session_id, 'FK_PROCESSING_FAILED')`; return `422 FK_PROCESSING_FAILED`.
7. Delete original from `session.original_storage_path`. Retry up to 2 times. If all fail: delete display; `fail_upload_session(session_id, 'FK_PROCESSING_FAILED')`; return `422 FK_PROCESSING_FAILED`.
8. Call `public.advance_upload_session_sanitized(session_id)`. If raises: delete display; return `500 FK_INTERNAL`.

**Finalization (from step 8, or from `sanitized` branch):**

9. Call `public.finalize_upload_session(session_id)`. Acquires session and challenge row locks; verifies `sanitized` or idempotent `complete`; verifies challenge `draft`. If challenge not `draft` → `409 FK_WRONG_STATE`. If session not `sanitized`/`complete` → `409 FK_WRONG_STATE`. Atomically finalizes. If session remains `sanitized` after failure → `500 FK_INTERNAL`; client retries (re-enters `sanitized` branch).

**Response `200 OK`:**
```json
{ "media_object_id": "<uuid>", "status": "ready" }
```

---

### 4.3 `media-serve`

**Purpose:** Proxy the re-encoded challenge image to an authorized viewer.

**Method / Path:** `GET /media/{challenge_id}`  **`verify_jwt`:** `true`

**Authorization:**
1. Standard gate (Section 3.1).
2. Query `public.challenges` using user-JWT client. RLS enforces visibility including draft-to-poster restriction. No row → `404 FK_NOT_FOUND`.
3. `media_object_id` null → `404 FK_NOT_FOUND`.

**Action:**
1. Call `public.get_media_storage_key(media_object_id)`. Returns `re_encoded_storage_key` if `status = 'ready'`. No result → `404 FK_NOT_FOUND`. Key from database — never constructed from `challenge_id` or `session_id`.
2. Read file at `re_encoded_storage_key` from `game-media`.
3. Stream bytes: `Content-Type: image/webp`, `Cache-Control: private, max-age=3600`.

---

### 4.4 `scheduled-close`

**Purpose:** Lock and reveal challenges whose `deadline_at` has passed.

**Trigger:** pg_cron, every 2 minutes.  **`verify_jwt`:** `false`

**Authentication:** Cron-secret pattern. If absent or mismatch → `401 FK_UNAUTHENTICATED`.

**Action:**

Pass 1: Query `challenges WHERE state = 'active' AND deadline_at <= now()`. For each: call `lock_challenge(uuid)`. Catch per-row errors; log sanitized code; continue.

Pass 2: Query `challenges WHERE state = 'locked'`. For each: call `reveal_challenge_service_wrapper(uuid)`. Catch per-row errors; log; continue.

**Response `200 OK`:**
```json
{
  "locked_count": 3, "revealed_count": 3, "skipped_count": 0,
  "errors": [{ "challenge_id": "<uuid>", "pass": "lock" | "reveal", "error_code": "<sanitized>" }]
}
```

---

### 4.5 `account-delete-complete`

**Purpose:** Initiate or complete account deletion. Quiesces upload sessions, waits for all presigned PUT URLs to expire, gathers and deletes all storage, deletes `auth.users`, finalizes deletion record.

**Method / Path:** `POST /account-delete-complete`  **`verify_jwt`:** `true`

**Request body:** *(none)*

**Authentication:** Carve-out gate. Valid JWT + existing profile row; `is_active` and `onboarding_complete` not checked.

**V1 deletion status states:** `pending` (transient), `database_prepared`, `auth_deleted`, `complete` (terminal).

**Action:**

1. Call `public.prepare_account_deletion_wrapper(user_id)`. Returns status. `database_prepared` → continue. `auth_deleted` → `409 FK_WRONG_STATE`. `complete` → log anomaly; `500 FK_INTERNAL`. Error → `500 FK_INTERNAL`.
2. Call `public.quiesce_upload_sessions_for_deletion(user_id)`. If any row has `blocking_lease_expires_at IS NOT NULL` → `409 FK_UPLOAD_IN_PROGRESS` with `retry_after`; stop.
3. Call `public.get_upload_capability_expiry(user_id)`. If non-NULL → `409 FK_UPLOAD_IN_PROGRESS` with `retry_after = blocking_until`; stop. Maximum additional wait: 5 minutes + 30 seconds. Covers sessions with non-NULL `storage_upload_expires_at` (issued capabilities); sessions with NULL expiry (no capability issued) are excluded and do not block.
4. Call `public.get_all_upload_session_paths_for_deletion(user_id)`. Returns all paths where `status != 'cleaned'`, including `complete` sessions' `original_storage_path`. Only safe to call after step 3 confirms all URLs expired.
5. Delete `original_storage_path` and (where non-null) `display_storage_path` for each row from step 4. Absent = no-op. Track failures.
6. Call `public.get_deletion_storage_keys(user_id)`. Delete all established media storage. Track failures.
7. If any storage deletion from step 5 or 6 fails → `record_deletion_failure_wrapper(user_id, 'FK_PROCESSING_FAILED')`; return `422 FK_PROCESSING_FAILED`; stop.
8. Delete `auth.users` (Admin API). If fails → `500 FK_INTERNAL`.
9. Call `public.mark_auth_deleted_wrapper(user_id)`. If fails → log for recovery worker; `500 FK_INTERNAL`.
10. Call `public.mark_storage_cleaned_wrapper(user_id)`. If fails → log for recovery worker; `500 FK_INTERNAL`.
11. Return `200 {"status":"complete"}`.

**Coverage guarantee:** Deletion reaches `complete` only after all presigned PUT URLs have expired and every upload-session path and established media key has been confirmed deleted.

**Logging:** `user_id`, `quiesced_session_count`, `blocking_session_count`, `url_capability_blocking_until`, `session_paths_attempted`, `established_key_count`, `deleted_count`, `failed_count`, deletion state at each step. NOT storage paths, key values, or file content.

---

### 4.6 `upload-cleanup-worker`

**Purpose:** Transition stale sessions, delete orphaned storage, post-expiry original-path cleanup for complete sessions, clean superseded media, mark sessions `cleaned`.

**Trigger:** pg_cron, every 15 minutes.  **`verify_jwt`:** `false`

**Authentication:** Cron-secret pattern.

**Action:**

Part 1 — upload session cleanup:
1. Call `public.claim_cleanup_sessions(worker_id, '15 minutes')`. Atomically transitions stale sessions (including `sanitized → failed`) and claims `expired`/`failed` rows past URL expiry (or with NULL expiry). Returns rows.
2. For each: attempt to delete `original_storage_path` and `display_storage_path`. Absent = no-op. If all deletions succeeded → `mark_session_cleaned(session_id, cleanup_claim_token)`. If any failed → do NOT mark; session re-appears after claim expires.

Part 2 — superseded media cleanup:
1. Call `public.get_superseded_media_to_clean()`. For each: delete `re_encoded_storage_key`. If success → `mark_superseded_media_cleaned`. If failure → log; retry next run.

Part 3 — post-expiry original-path cleanup for complete sessions:
1. Call `public.get_complete_sessions_pending_expiry_cleanup()` (added to V2 catalog in Step 25): returns `complete` sessions where `storage_upload_expires_at IS NOT NULL AND storage_upload_expires_at + interval '30 seconds' <= now() AND original_path_post_expiry_cleaned = false`. Sessions with NULL expiry (no capability issued) are excluded — no object can exist at their `original_storage_path`.
2. For each: attempt to delete `original_storage_path`. Absent = no-op (step 7 of `upload-complete` already deleted it in the normal case). Object present = re-upload occurred within the presigned window; delete it.
3. Whether absent or present: call `public.mark_original_path_post_expiry_cleaned(session_id)`. Prevents re-processing.
4. If the storage delete failed and the object was confirmed present: log; do NOT call `mark_original_path_post_expiry_cleaned`; retry next run.

**Response `200 OK`:**
```json
{
  "sessions_claimed": 5, "sessions_cleaned": 4, "sessions_cleanup_failed": 1,
  "objects_deleted": 7, "objects_absent": 1, "objects_failed": 0,
  "superseded_media_cleaned": 2, "superseded_media_failed": 0,
  "complete_expiry_cleaned": 3, "complete_expiry_skipped": 0
}
```

---

### 4.7 `deletion-recovery-worker`

**Purpose:** Resume account deletions after the client JWT is void.

**Trigger:** pg_cron, every 5 minutes.  **`verify_jwt`:** `false`

**Authentication:** Cron-secret pattern.

**Action:**

1. Call `public.claim_deletion_recovery_records(worker_id, '10 minutes', '10 minutes')`.

2. For each claimed record:

   **If `scan_type = 'database_prepared'`:**
   a. Check Auth (Admin API). If auth still exists → `fail_deletion_recovery(user_id, claim_token, 'FK_AUTH_STILL_EXISTS')`; skip.
   b. Call `quiesce_upload_sessions_for_deletion(user_id)`. If any blocking lease → `fail_deletion_recovery` with `FK_UPLOAD_IN_PROGRESS`; retry next run.
   c. Call `get_upload_capability_expiry(user_id)`. If non-NULL → `fail_deletion_recovery` with `FK_UPLOAD_IN_PROGRESS`; retry next run. (By the next 5-minute run, the 5-minute URL will have expired.)
   d. Call `get_all_upload_session_paths_for_deletion(user_id)`. Delete all paths. Track failures.
   e. Call `get_deletion_storage_keys(user_id)`. Delete all established media storage. Track failures.
   f. If any storage deletion failed → `fail_deletion_recovery` with `FK_PROCESSING_FAILED`; retry next run.
   g. All deleted → `complete_deletion_recovery(user_id, claim_token, 'database_prepared')`.

   **If `scan_type = 'auth_deleted'`:**
   a. Call `quiesce_upload_sessions_for_deletion`. If blocking lease → `fail_deletion_recovery`; retry.
   b. Call `get_upload_capability_expiry`. If non-NULL → `fail_deletion_recovery`; retry.
   c–f. Same path collection, deletion, and failure handling as above.
   g. All deleted → `complete_deletion_recovery(user_id, claim_token, 'auth_deleted')`.

**Deployment gate:** Must go live simultaneously with `account-delete-complete`.

**Logging:** Counts only. NOT user IDs, paths, or claim tokens.

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

**Session reservation vs. deletion concurrency:**
- Race A: `prepare_account_deletion_wrapper` wins the challenge row lock (or sets deletion record) before `reserve_upload_session` runs → `reserve_upload_session` fails: challenge not `draft` (if cancellation committed) or `FK_FORBIDDEN` (if deletion record exists) → URL never issued; deletion proceeds without URL-expiry block
- Race B: `reserve_upload_session` wins the challenge row lock and commits first → challenge lock blocks `prepare_account_deletion_wrapper`'s `cancel_challenge` until session is committed → deletion sees the committed session, quiesces it, and is blocked by `get_upload_capability_expiry` until the URL expires; after expiry, deletion completes
- Both outcomes leave no permanently orphaned storage and deletion eventually reaches `complete`

**Uploader deletion-in-progress check:**
- `reserve_upload_session` with uploader who has `database_prepared` deletion record → `403 FK_FORBIDDEN`
- `reserve_upload_session` with uploader who has `auth_deleted` deletion record → `403 FK_FORBIDDEN`
- `reserve_upload_session` with uploader who has `complete` deletion record → depends on whether profile still exists; standard gate would reject first

**Two-phase URL issuance:**
- `reserve_upload_session` succeeds, URL generation fails → `fail_upload_session` called with NULL expiry; return 500; URL never issued; session cleaned without URL-expiry gate
- `reserve_upload_session` succeeds, URL generation succeeds, `activate_upload_session` fails → fail session; return 500; URL generated in memory but not returned to client; session cleaned without URL-expiry gate
- `reserve_upload_session` succeeds, `activate_upload_session` succeeds → `storage_upload_expires_at` equals actual URL expiry; URL returned to client
- `activate_upload_session` called twice → second call raises error (expiry already set)
- `activate_upload_session` on non-`pending` session → raises error

**Presigned URL properties:**
- Session row stores actual URL expiry captured at signing time (not an estimate computed before signing)
- A PUT using the presigned URL after `storage_upload_expires_at` is rejected by the storage layer
- `get_upload_capability_expiry` excludes sessions with `storage_upload_expires_at = NULL`
- `claim_cleanup_sessions` does not gate sessions with `storage_upload_expires_at = NULL` on URL expiry

**One active session per challenge:**
- Two concurrent `reserve_upload_session` calls → challenge lock serializes them; unique index prevents both from committing; exactly one succeeds
- `upload-authorize` while session is `pending`, `processing`, or `sanitized` → `409 FK_UPLOAD_IN_PROGRESS`
- After `failed` or `complete` → allowed

**Activation race (challenge lock in `finalize_upload_session`):**
- `activate_challenge` while active session exists → V2 trigger raises error
- `finalize_upload_session` with challenge already `active` → `FK_WRONG_STATE`; idempotent if already `complete`

**Photo replacement:**
- `finalize_upload_session` when `challenges.media_object_id` already set → atomically swaps; prior `media_objects.status = 'superseded'`; `replaced_media_object_id` non-null
- Cleanup worker deletes superseded media; calls `mark_superseded_media_cleaned`

**Completed-session idempotency:**
- `upload-complete` on `complete` session → `200` with `media_object_id` and `replaced_media_object_id` from session row

**MIME validation:**
- JPEG/JPEG, WebP/WebP → allowed
- MIME mismatch (declared ≠ actual) → `400 FK_INVALID_CONTENT_TYPE`
- PNG or other → `400 FK_INVALID_CONTENT_TYPE`
- Actual size > 10 MB → `400 FK_FILE_TOO_LARGE`

**Lease preemption:**
- `check_upload_session_lease` false → original deleted; display NOT written; `422`
- `advance_upload_session_sanitized` raises → display deleted; `500`

**`fail_upload_session` guard:**
- On `complete` → raises error
- On `failed` → idempotent
- On `pending`/`processing`/`sanitized` → transitions to `failed`

**Cleanup-vs-finalization:**
- `claim_cleanup_sessions` skips session row locked by `finalize_upload_session`
- `claim_cleanup_sessions` commits `sanitized → failed` first → `finalize_upload_session` sees `failed` → `FK_WRONG_STATE`
- `mark_session_cleaned` on `complete` → raises error

**Cleanup URL-expiry gate:**
- `claim_cleanup_sessions` does not return sessions with `storage_upload_expires_at IS NOT NULL AND storage_upload_expires_at + 30s > now()`
- `claim_cleanup_sessions` returns sessions with `storage_upload_expires_at IS NULL` without URL-expiry gate (no capability issued)
- `claim_cleanup_sessions` returns sessions with expired non-NULL `storage_upload_expires_at`

**Replay: late upload within presigned window:**
- Session `complete`; original deleted in step 7; URL still valid (within 5 min); client re-uploads to `original_storage_path` → new object exists
- `get_upload_capability_expiry` blocks account deletion until `storage_upload_expires_at + 30s`
- After expiry: `get_all_upload_session_paths_for_deletion` includes `complete` session's `original_storage_path`; deleted
- Cleanup worker Part 3 also handles it (whichever runs first)

**Replay: cleanup blocked by unexpired URL:**
- Session `failed`; `storage_upload_expires_at IS NOT NULL AND + 30s > now()` → not claimed
- After URL expires → claimed; both paths deleted; `mark_session_cleaned`

**Account deletion — URL-expiry blocking:**
- Any session with `storage_upload_expires_at IS NOT NULL AND + 30s > now()` → `get_upload_capability_expiry` non-NULL → `409 FK_UPLOAD_IN_PROGRESS`
- After all non-NULL expiries pass → `get_upload_capability_expiry` returns NULL → deletion proceeds
- `complete` session's `original_storage_path` included in `get_all_upload_session_paths_for_deletion`

**Account deletion — comprehensive path coverage:**
- Blocked attempt → retry picks up previously-quiesced `failed` sessions via `get_all_upload_session_paths_for_deletion`
- Sessions with NULL expiry included in path collection; no URL-expiry block

**Deletion-recovery-worker claims:**
- `complete_deletion_recovery` with wrong `scan_type` → error; state unchanged
- `complete_deletion_recovery` with expired claim → error
- Concurrent workers: claim disjoint records
- URL-expiry block → `fail_deletion_recovery`; re-claimable next run

**`mark_auth_deleted_wrapper` and `mark_storage_cleaned_wrapper`:**
- These wrappers called; not `mark_auth_deleted` / `mark_storage_cleaned` directly
- SECURITY DEFINER; GRANT EXECUTE TO service_role only

**`media-serve`:**
- RLS restricts draft to poster
- Storage key from `get_media_storage_key`; never path-constructed

**`scheduled-close`:**
- Per-row failure in Pass 1 does not abort Pass 2

**Private schema:**
- `private.upload_sessions` and `private.deletion_recovery_claims` not accessible through PostgREST

**Error format:**
- All function errors: `{ "error": { "code": "FK_...", "message": "..." } }`
- Logs contain no paths, tokens, or raw error messages

### 5.2 Production Verification (per-function, non-mutating)

| Function | Production probe |
|---|---|
| `upload-authorize` | Unauthenticated → `401`; authenticated with missing `challenge_id` → `400` |
| `upload-complete` | Unauthenticated → `401`; authenticated with missing `upload_token` → `400` |
| `media-serve` | Unauthenticated → `401`; authenticated with nonexistent `challenge_id` → `404` |
| `scheduled-close` | Wrong/absent cron secret → `401` |
| `upload-cleanup-worker` | Wrong/absent cron secret → `401` |
| `deletion-recovery-worker` | Wrong/absent cron secret → `401` |
| `account-delete-complete` | Unauthenticated → `401` only |

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
7. Deploy to `forkensics-prod`; production probes pass (Section 5.2)

**Cron credential setup** must precede any cron-authenticated deployment.

**Deployment order:**
1. V2 migration (both `private` tables, all wrapper functions including `get_complete_sessions_pending_expiry_cleanup`, partial unique index, V2 triggers) — Step 25
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
- Specific S3 presigned PUT SDK call (implementation detail for the per-function step)
- Verification of Supabase conditional PUT behavior (deferred; not assumed in this contract)

---

## Success Criteria for Step 24

- [ ] Decision matrix agreed: cancel/apply_correction permit poster or group owner; reason nullable; correct V1 mechanisms for comments and reactions
- [ ] Both infrastructure tables in `private` schema agreed
- [ ] Partial unique index agreed: database-level enforcement of one active session per challenge
- [ ] V2 trigger agreed: `activate_challenge` rejects while active upload session exists or media is not `ready`
- [ ] `reserve_upload_session` agreed: locks challenge row before verification; checks poster identity and draft state; verifies uploader has no deletion in progress; inserts with `storage_upload_expires_at = NULL`; partial unique index prevents concurrent reservations
- [ ] `activate_upload_session` agreed: sets actual URL expiry post-signing; URL never returned to client unless this commits; sessions with NULL expiry are treated as "no capability issued"
- [ ] `finalize_upload_session` agreed: acquires session and challenge row locks; verifies `sanitized` or idempotent `complete`; verifies `draft`; handles photo replacement atomically
- [ ] `claim_cleanup_sessions` agreed: transitions `sanitized → failed` before returning; URL-expiry gate excludes sessions with non-NULL non-expired expiry; sessions with NULL expiry are not gated; `FOR UPDATE SKIP LOCKED` mutual exclusion with `finalize_upload_session`
- [ ] `mark_session_cleaned` agreed: verifies `failed` or `expired`; raises for `complete`
- [ ] `fail_upload_session` agreed: raises for `complete`
- [ ] S3 presigned PUT agreed: true 5-minute expiry at storage layer; replaces `createSignedUploadUrl()`; non-overwrite conditional behavior not assumed; replay handled by expiry + Part 3 cleanup
- [ ] `get_upload_capability_expiry` agreed: excludes NULL-expiry sessions; gates deletion on issued-capability expiry
- [ ] `get_all_upload_session_paths_for_deletion` agreed: includes `complete` sessions' `original_storage_path`; called only after URL expiry confirmed; covers re-uploads within the 5-minute window
- [ ] Cleanup worker Part 3 agreed: post-expiry original-path delete for `complete` sessions with non-NULL issued expiry; `mark_original_path_post_expiry_cleaned`; `get_complete_sessions_pending_expiry_cleanup` in V2 catalog
- [ ] `mark_auth_deleted_wrapper` and `mark_storage_cleaned_wrapper` agreed
- [ ] `media_object_id` and `replaced_media_object_id` in upload session table agreed; saved atomically; returned by `resolve_upload_session`
- [ ] `complete_deletion_recovery` scan_type verification agreed
- [ ] Concurrency test for `upload-authorize` vs `prepare_account_deletion_wrapper` agreed
- [ ] All V2 wrapper functions enumerated; no direct administrative reads of private tables outside named functions
- [ ] Persistent claim mechanism agreed for both workers; stale thresholds bound
- [ ] Per-function production probes agreed; `account-delete-complete` is unauthenticated-only
- [ ] Deployment order agreed; workers deployed with paired Edge Functions
- [ ] No Edge Function code written before approval
