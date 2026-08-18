# Step 24 Proposal — Rev 5 — Edge Function Architecture and Contracts

**Status:** Pending review (Claude → Codex/GPT → Bill approval)
**Governance gate:** Bill must type `APPROVED: Step 24 — Edge Function Architecture and Contracts` before any Edge Function code is written.

**Scope:** Architecture decisions and binding contracts only. No TypeScript, no Deno code, no deployment. Implementation follows in separate per-function steps.

**Changes from Rev 4:**
1. Upload-session schema corrected: `uploader_id` references `public.profiles(id)`, not `auth.users(id)`; `display_storage_path` set at session creation (deterministic from `session_id`); `processing_lease_expires_at` added to detect and recover crashed processing sessions; `cleanup_completed_at` and terminal `cleaned` state added; `advance_upload_session_sanitized` no longer needs to record the path (path is already in the row).
2. Cleanup state machine completed: `claim_cleanup_sessions` atomically transitions stale `pending` → `expired` and lease-expired `processing` → `failed`, then claims all sessions needing cleanup using `FOR UPDATE SKIP LOCKED` to prevent concurrent worker conflicts; after storage objects confirmed deleted, `mark_session_cleaned` transitions to `cleaned`; `complete` sessions are never claimed; explicit state transitions for all paths.
3. MIME and retry contract fixed: actual MIME must be allowed (JPEG or WebP) AND must match `session.content_type` — declared type mismatch is an error. Cross-cutting retry rule corrected: failed upload sessions are invalid; the client must call `upload-authorize` again. Other operations have their own retry rules specified per-contract.
4. Cron authentication corrected: the cron secret is stored in two places — Supabase Vault (read by pg_cron/pg_net to inject into outbound requests) and Edge Function environment variables (`CRON_SECRET`, read at runtime by the receiving function). Edge Functions do not read from Vault. The comparison uses constant-time equality. `X-Forkensics-Cron-Secret` header carries the secret. Pattern applies to `scheduled-close`, `upload-cleanup-worker`, and `deletion-recovery-worker`.
5. Account deletion corrected: `account-delete-complete` calls `prepare_account_deletion` as its first step (creating the deletion record if none exists); V1's internal `pending` state is transient — after the function returns, the observable state is always `database_prepared`. Recovery worker corrected: both Scan 1 (`database_prepared` with auth absent) and Scan 2 (`auth_deleted`) must retrieve storage keys and delete physical objects before advancing state — they do not assume storage was previously cleaned.
6. Required test additions incorporated: auth deletion with persistent upload-session rows; stale processing lease recovery; cleanup claiming concurrency; `cleaned` terminal state; abandoned `sanitized` object deletion; `complete` sessions never cleaned; first-time deletion with no prior record; recovery with `database_prepared`, auth absent, and storage present; authentication failure for both workers; per-function production probes (account deletion and workers do not use the generic authenticated-400 probe).

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
| `media-serve` | Proxy re-encoded image from private storage; fetch privileged storage key via V2 wrapper |
| `scheduled-close` | Cron-triggered; locks and reveals challenges past `deadline_at`; no user JWT |
| `account-delete-complete` | Call prepare_account_deletion wrapper, delete storage objects, call V2 deletion wrappers, delete `auth.users` via Admin API |

### Background Workers (required; deployed on the schedule below)

| Worker | Purpose |
|---|---|
| `upload-cleanup-worker` | Transition stale sessions to `expired`/`failed`, delete orphaned storage objects, mark sessions `cleaned` |
| `deletion-recovery-worker` | Resume partially-complete account deletions after client JWT has become void |

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
pending → superseded                               (new authorize call for same challenge)
pending → expired                                  (cleanup worker: stale pending past expires_at)
processing → failed                                (cleanup worker: lease expired without progress)
pending | processing | sanitized → failed          (error in upload-complete)
expired | superseded | failed | sanitized(abandoned) → cleaned   (cleanup worker: storage confirmed deleted)
complete                                           (terminal; never cleaned)
```

State semantics:

- `pending`: session created, signed URL issued; upload not yet confirmed
- `processing`: `upload-complete` has claimed the session and begun processing
- `sanitized`: re-encoding complete, original confirmed deleted, display object written; finalization not yet committed
- `complete`: DB finalization committed; `media_objects`, `media_storage_keys`, and `challenges.media_object_id` all set; terminal
- `superseded`: a later `upload-authorize` call superseded this session for the same challenge
- `expired`: stale `pending` session past `expires_at`; transitioned by cleanup worker
- `failed`: unrecoverable error; not retryable by the client — client must call `upload-authorize` again
- `cleaned`: all associated storage objects confirmed deleted; terminal for all non-`complete` paths

### 2.2 V2 Table Schema Requirements

The upload session table must include:

- `session_id` (UUID, primary key) — generated at creation; used as part of storage paths
- `upload_token_hash` (text, unique) — SHA-256 hex of the secret upload token; token itself not stored
- `challenge_id` (UUID FK → `public.challenges(id)`)
- `uploader_id` (UUID FK → `public.profiles(id)`) — references profiles, not `auth.users`; FK preserved after auth deletion
- `original_storage_path` (text) — `challenges/{challenge_id}/originals/{session_id}`; set at creation
- `display_storage_path` (text) — `challenges/{challenge_id}/displays/{session_id}.webp`; set at creation; deterministic from `session_id`; allows cleanup worker to delete the display object even if the session never reached `sanitized`
- `content_type` (text) — the declared content type; actual MIME must match this value at processing time
- `declared_size_bytes` (bigint)
- `expires_at` (timestamptz) — session-level expiry; enforced at `advance_upload_session_processing`
- `processing_lease_expires_at` (timestamptz, nullable) — set when transitioning to `processing`; cleanup worker uses this to detect and recover stale `processing` sessions
- `status` (text) — one of the eight states above
- `failed_reason` (text, nullable) — sanitized error code only; no storage paths, no raw error text
- `cleanup_completed_at` (timestamptz, nullable) — set when transitioning to `cleaned`

### 2.3 V2 Function Requirements

The V2 migration must include public SECURITY DEFINER functions, granted EXECUTE only to `service_role`. Functions must enforce all business rules themselves — Edge Functions and workers must not re-implement authorization, state checks, or transition logic.

**Session lifecycle functions:**

- `public.create_upload_session(challenge_id uuid, uploader_id uuid, token_hash text, content_type text, declared_size bigint, expires_at timestamptz)` → `(session_id uuid, original_storage_path text, display_storage_path text)` — enforces poster identity, draft state; generates `session_id`; constructs and records both storage paths; supersedes any prior `pending` session for this challenge (transitions them to `superseded`); returns both paths (known at creation from `session_id`)

- `public.advance_upload_session_processing(session_id uuid, uploader_id uuid, lease_duration interval)` → `(original_storage_path text, display_storage_path text)` — enforces uploader identity, `status = 'pending'`, not expired; transitions to `processing`; sets `processing_lease_expires_at = now() + lease_duration`; returns both paths from the session row

- `public.advance_upload_session_sanitized(session_id uuid)` → void — transitions `processing` → `sanitized`; `display_storage_path` is already recorded from creation; this function only confirms the state transition

- `public.finalize_upload_session(session_id uuid)` → `(media_object_id uuid)` — atomically in a single transaction: inserts `public.media_objects` (`status = 'ready'`), inserts `private.media_storage_keys` (using `original_storage_path` and `display_storage_path` from the session row), sets `challenges.media_object_id`, transitions session to `complete`; idempotent: if already `complete`, returns existing `media_object_id`

- `public.fail_upload_session(session_id uuid, error_code text)` → void — transitions to `failed`; records `failed_reason = error_code`; idempotent if already `failed`

**Cleanup functions:**

- `public.claim_cleanup_sessions(worker_id text, processing_lease_timeout interval, pending_expiry_grace interval)` → `TABLE(session_id uuid, original_storage_path text, display_storage_path text, status text)` — atomically (using `FOR UPDATE SKIP LOCKED`): transitions stale `pending` (past `expires_at + pending_expiry_grace`) → `expired`; transitions `processing` with expired `processing_lease_expires_at` → `failed`; then claims and returns all sessions in `expired`, `superseded`, `failed`, and `sanitized` (older than a threshold) states that have not yet been `cleaned`; never returns `complete` sessions; sets a claim marker so concurrent workers do not double-process

- `public.mark_session_cleaned(session_id uuid)` → void — transitions to `cleaned`; sets `cleanup_completed_at`; idempotent if already `cleaned`

**Media lookup:**

- `public.get_media_storage_key(media_object_id uuid)` → `(re_encoded_storage_key text)` — returns `re_encoded_storage_key` from `private.media_storage_keys` for the given `media_object_id`, only if `media_objects.status = 'ready'`; returns no row if not found or not ready

The V2 migration goes through the full three-party governance cycle as a separate step (Step 25) before any upload Edge Function is implemented.

---

## Section 3 — Cross-Cutting Contracts

These rules apply to every Edge Function and worker without exception unless explicitly carved out.

### 3.1 Authentication

**`verify_jwt` setting:**
- User-facing Edge Functions (`upload-authorize`, `upload-complete`, `media-serve`, `account-delete-complete`) deploy with `verify_jwt = true`. Gateway JWT rejection returns its own `401` before the function runs; that response does not follow the Forkensics error envelope. This exception is documented here.
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
- **Administrative client layer:** Operations requiring service-role access use the administrative Supabase client (initialized with the service-role key). This client connects through PostgREST as the `service_role` role. It is used only to call public V2 SECURITY DEFINER functions, generate signed storage URLs, read/write/delete storage objects, and call the Admin API for user deletion.

An Edge Function must never use the administrative client to perform a read the user is not authorized to perform.

### 3.3 Privileged Database Access Pattern

All privileged database operations use public SECURITY DEFINER V2 wrapper functions called via the administrative Supabase client. These functions are granted EXECUTE only to `service_role`.

`SUPABASE_DB_URL` (direct PostgreSQL connection) is **not** used by Edge Functions. The `private` schema is never exposed through the PostgREST API. Privileged access is mediated exclusively by SECURITY DEFINER functions that enforce their own invariants.

### 3.4 Existence and Authorization Probing

For any challenge-scoped operation: if the challenge does not exist or if the caller is not authorized to see it, return `404 FK_NOT_FOUND` — not `403`. This prevents callers from inferring challenge existence from error codes.

### 3.5 Cron Authentication

All cron-authenticated functions and workers use the following pattern. This pattern does not use Vault at runtime in the Edge Function.

**Setup (performed once, before deployment):** Generate a cryptographically random secret (256 bits minimum). Store it in two places:
1. Supabase Vault — so pg_cron/pg_net can read it when constructing outbound HTTP requests.
2. Edge Function environment variables as `CRON_SECRET` — so the receiving function can compare against it at runtime.

**Request construction (database side — pg_cron/pg_net):** The pg_cron job reads the secret from Vault and injects it as an HTTP header: `X-Forkensics-Cron-Secret: <secret>`.

**Receiving function:** Reads the `X-Forkensics-Cron-Secret` header. Compares it to `CRON_SECRET` using constant-time equality (to prevent timing attacks). If absent or mismatch → `401`. The function never reads Vault.

A separate secret may be used per function, or one secret may be shared across all cron-authenticated functions — that decision is deferred to implementation. The contract requires the pattern; the specific key management is documented at setup time.

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
| 400 | `FK_INVALID_CONTENT_TYPE` | Actual MIME type not allowed, or actual MIME type does not match `session.content_type` |
| 400 | `FK_FILE_TOO_LARGE` | Actual stored file exceeds 10 MB |
| 400 | `FK_INVALID_TOKEN` | Upload token missing, malformed, expired, superseded, or for a failed session |
| 401 | `FK_UNAUTHENTICATED` | Missing or invalid sub claim; or missing/mismatched cron secret |
| 403 | `FK_FORBIDDEN` | Valid JWT; caller does not meet `is_active` + `onboarding_complete` requirements |
| 404 | `FK_NOT_FOUND` | Resource does not exist or caller is not authorized to see it |
| 409 | `FK_WRONG_STATE` | Resource is not in the required state for this operation |
| 422 | `FK_PROCESSING_FAILED` | Re-encoding or storage operation failed unrecoverably |
| 429 | `FK_RATE_LIMITED` | Too many requests |
| 500 | `FK_INTERNAL` | Unexpected server error — no internal detail exposed to caller |

`409 FK_ALREADY_COMPLETE` is not used. A completed idempotent operation returns `200` with `"already_complete": true`.

### 3.8 Idempotency

Retry behavior is specified per-contract. The general rules:

- A retry of a completed operation returns `200` with the original result and `"already_complete": true`.
- A retry of an in-progress operation returns `202` with `"status": "processing"`.
- **Upload sessions that reached `failed` are not retryable.** The client must call `upload-authorize` again to get a new session. `upload-complete` with a token for a `failed` session returns `400 FK_INVALID_TOKEN`.
- Expired, superseded, unknown, or failed tokens return `400 FK_INVALID_TOKEN`.
- Idempotency for other operations is derived from stable inputs (challenge ID, user ID). No client-supplied idempotency headers are required.

### 3.9 Logging

Logs must **never** contain:
- Canonical dish name, restaurant name, or city
- Storage paths, storage keys, or signed URLs
- EXIF or GPS data from any image
- Secret keys, JWTs, upload tokens, token hashes, or cron secrets
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
- `account-delete-complete` storage failure → user can still authenticate and retry; storage objects are not abandoned
- Worker failure → state is recoverable on next run; no data corruption

### 3.11 Atomicity Boundary

Only database operations inside a single PostgreSQL transaction are atomic. Storage operations and PostgreSQL are not atomic with respect to each other. Any multi-step sequence spanning both requires explicit compensating cleanup. Each function contract specifies its compensating actions.

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
2. Call `public.create_upload_session(challenge_id, user_id, token_hash, content_type, declared_size_bytes, now() + 5 minutes)` via administrative client. This function enforces poster identity and draft state; generates `session_id`; constructs and records both `original_storage_path` and `display_storage_path` from `session_id`; supersedes any prior `pending` session for this challenge; returns `session_id`, `original_storage_path`, and `display_storage_path`. If the function raises `FK_NOT_FOUND` → `404 FK_NOT_FOUND`. If it raises `FK_WRONG_STATE` → `409 FK_WRONG_STATE`.
3. Generate a signed upload URL for `session.original_storage_path` in `game-media`, 5-minute expiry (administrative client). The signed URL is generated after the session row is committed.
4. Return the signed URL and upload token to the client. `session_id` and storage paths are internal identifiers and are not returned to the client.

**Response `200 OK`:**
```json
{
  "signed_url": "<url>",
  "upload_token": "<secret token — not the hash>",
  "expires_at": "<ISO 8601>"
}
```

**Idempotency:** Not idempotent. Each call supersedes the prior pending session for this challenge and produces a new session.

**Logging:** `challenge_id`, `user_id`, `content_type`, `session_id` (internal only), outcome. NOT the signed URL, upload token, token hash, or storage paths.

---

### 4.2 `upload-complete`

**Purpose:** Validate the uploaded file, re-encode with EXIF/GPS removal, confirm the original is deleted before recording, and atomically finalize the media object.

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
2. Compute SHA-256 hash of `upload_token`. Look up session by `token_hash`. Session must exist and belong to the authenticated user — otherwise `400 FK_INVALID_TOKEN`.

**Idempotency branch (check session status before any action):**
- `complete` → return `200 {"status": "ready", "media_object_id": "<uuid>", "already_complete": true}`.
- `processing` → return `202 {"status": "processing"}`.
- `sanitized` → skip to finalization (step 8).
- `pending` → proceed to happy path.
- Any other status (`expired`, `superseded`, `failed`, `cleaned`) → `400 FK_INVALID_TOKEN`. Failed sessions are not retryable; client must call `upload-authorize` again.

**Happy path (session status `pending`):**

1. Call `public.advance_upload_session_processing(session_id, user_id, lease_duration := '10 minutes')` (administrative client). Verifies uploader identity, `status = 'pending'`, not expired; transitions to `processing`; sets `processing_lease_expires_at`; returns both storage paths. If transition fails → `400 FK_INVALID_TOKEN`.
2. Read original file from `session.original_storage_path` (administrative client). If absent → call `public.fail_upload_session(session_id, 'FK_NOT_FOUND')`; return `404 FK_NOT_FOUND`.
3. Sniff actual MIME type from file bytes. Do not trust `session.content_type` or any client claim. The actual MIME type must be `image/jpeg` or `image/webp` AND must match `session.content_type`. If either condition fails → delete original from storage; call `public.fail_upload_session(session_id, 'FK_INVALID_CONTENT_TYPE')`; return `400 FK_INVALID_CONTENT_TYPE`.
4. Confirm actual stored size ≤ 10,485,760 bytes. If over → delete original from storage; call `public.fail_upload_session(session_id, 'FK_FILE_TOO_LARGE')`; return `400 FK_FILE_TOO_LARGE`.
5. Re-encode to WebP; strip all EXIF, GPS, and embedded metadata. If re-encoding fails → delete original from storage; call `public.fail_upload_session(session_id, 'FK_PROCESSING_FAILED')`; return `422 FK_PROCESSING_FAILED`.
6. Write re-encoded file to `session.display_storage_path` (administrative client). The path is already known from the session row — it is not constructed in the Edge Function. If write fails → delete original from storage; call `public.fail_upload_session(session_id, 'FK_PROCESSING_FAILED')`; return `422 FK_PROCESSING_FAILED`.
7. Delete original from `session.original_storage_path` (administrative client). Retry up to 2 times with brief backoff.
   - If all attempts fail: delete the display object written in step 6; call `public.fail_upload_session(session_id, 'FK_PROCESSING_FAILED')`; return `422 FK_PROCESSING_FAILED`. Session is `failed`; client must restart from `upload-authorize`.
8. Call `public.advance_upload_session_sanitized(session_id)` (administrative client). Transitions `processing` → `sanitized`. The display path is already in the session row from creation; this function only confirms the state. If this call fails: original is already deleted; display object exists at `session.display_storage_path`. Call `public.fail_upload_session` if possible; log `session_id` for the cleanup worker. Return `500 FK_INTERNAL`. The cleanup worker will find the abandoned display object at the recorded path and remove it.

**Finalization (step 8 of happy path, or when branch enters at `sanitized`):**

9. Call `public.finalize_upload_session(session_id)` (administrative client). Atomically: inserts `public.media_objects`, inserts `private.media_storage_keys` (using both storage paths from the session row), sets `challenges.media_object_id`, transitions session to `complete`. Returns `media_object_id`. If already `complete`, returns existing `media_object_id` (idempotent). If finalization fails: session remains `sanitized`; original is already deleted; display object is at `session.display_storage_path`. Return `500 FK_INTERNAL`. Client may retry `upload-complete` with the same token — the next attempt enters the `sanitized` branch and retries finalization without needing the original.

**Response `200 OK`:**
```json
{
  "media_object_id": "<uuid>",
  "status": "ready"
}
```

**Abandoned sanitized sessions:** The upload-cleanup-worker claims sessions in `sanitized` state older than the processing lease timeout, deletes their display objects (using the path recorded at session creation), and marks them `cleaned`.

**Logging:** `challenge_id`, `session_id` (internal), actual MIME type (the type string, not the bytes), actual stored size, re-encoding outcome, original-deletion outcome. NOT storage paths, upload token, or token hash.

---

### 4.3 `media-serve`

**Purpose:** Proxy the re-encoded challenge image to an authorized viewer. Never expose storage paths or signed URLs to the client.

**Method / Path:** `GET /media/{challenge_id}`

**`verify_jwt`:** `true`

**Authorization:**
1. Profile active + onboarding complete (Section 3.1 standard gate).
2. Query `public.challenges` using the **user-JWT client**: `SELECT id, media_object_id FROM public.challenges WHERE id = $challenge_id`. RLS applies automatically. If no row is returned → `404 FK_NOT_FOUND`. This single query enforces all visibility rules, including the `posted_at IS NOT NULL` rule that restricts draft-state challenges to the poster — no additional state or membership check is needed in function code.
3. If `media_object_id` is null → `404 FK_NOT_FOUND`.

**Action:**
1. Call `public.get_media_storage_key(media_object_id)` via administrative client. Returns `re_encoded_storage_key` from `private.media_storage_keys`, only if `media_objects.status = 'ready'`. If no result → `404 FK_NOT_FOUND`.
2. Read the file at `re_encoded_storage_key` from `game-media` (administrative client). The key comes from the database record — never construct a storage path from `challenge_id` or `session_id`.
3. Stream bytes to client with `Content-Type: image/webp`.

**Response `200 OK`:** Binary image stream (`image/webp`)

**Cache headers:** `Cache-Control: private, max-age=3600`

**Logging:** `challenge_id`, `user_id`, outcome. NOT the storage key or path.

---

### 4.4 `scheduled-close`

**Purpose:** Lock and reveal all challenges whose `deadline_at` has passed.

**Trigger:** Supabase pg_cron, every 2 minutes.

**`verify_jwt`:** `false`

**Authentication:** Cron-secret pattern (Section 3.5). Checks `X-Forkensics-Cron-Secret` against `CRON_SECRET` env var using constant-time comparison. If absent or mismatch → `401 FK_UNAUTHENTICATED`.

**Action:**

Pass 1 — lock active challenges past deadline:
1. Query `public.challenges WHERE state = 'active' AND deadline_at <= now()` using administrative client.
2. For each: call `public.lock_challenge(uuid)` (administrative client). `lock_challenge` raises if the challenge is not in `active` state — catch per-row, log challenge ID and sanitized error code, continue batch.

Pass 2 — reveal locked challenges:
1. Query `public.challenges WHERE state = 'locked'` (administrative client). Revealed and cancelled challenges are excluded by the `WHERE state = 'locked'` predicate and do not require per-row handling.
2. For each: call the V2 public wrapper for `private.reveal_challenge_service(uuid)` (administrative client). Catch per-row errors — log and continue batch.

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

**Idempotency:** Both passes are safe to run multiple times. `lock_challenge` raises on non-`active` challenges (caught per-row). The reveal wrapper raises on non-`locked` challenges (caught per-row).

**Logging:** `locked_count`, `revealed_count`, `skipped_count`, per-row sanitized error codes and challenge IDs. NOT challenge content, canonical answers, or guess data.

---

### 4.5 `account-delete-complete`

**Purpose:** Initiate or complete account deletion. Calls `prepare_account_deletion` if no deletion record exists, then removes storage objects, deletes `auth.users`, and finalizes the deletion record.

**Method / Path:** `POST /account-delete-complete`

**`verify_jwt`:** `true`

**Request body:** *(none — caller identity comes from the JWT)*

**Authentication:** Carve-out gate (Section 3.1). Valid JWT + existing profile row; `is_active` and `onboarding_complete` are not checked.

**V1 deletion status states:**
- `pending` — transient; internal to `private.prepare_account_deletion()`. The function does not return until the record advances beyond this state.
- `database_prepared` — the observable state after `prepare_account_deletion()` returns; profile is anonymized.
- `auth_deleted` — after `mark_auth_deleted()` is called.
- `complete` — terminal; after `mark_storage_cleaned()` advances the record to final state.

**Action (in order — stop at the specified step on failure):**

1. Call `public.prepare_account_deletion_wrapper(user_id)` via administrative client. This V2 wrapper calls `private.prepare_account_deletion(user_id)`, which anonymizes the profile and creates or updates the deletion record. V1's internal `pending` state is transient — after this function returns, the observable status is `database_prepared`. If the wrapper raises:
   - Status is `auth_deleted`: recovery worker handles this; the client cannot proceed. Return `409 FK_WRONG_STATE`.
   - Status is `complete`: JWT should be void; log anomaly; return `500 FK_INTERNAL`.
   - Any other error: return `500 FK_INTERNAL`.
2. Call `public.get_storage_keys_for_deletion_wrapper(user_id)` via administrative client. Returns one distinct row per physical storage key.
3. For each storage key: delete the object from `game-media` (administrative client). Track per-key success and failure.
4. If any storage deletion fails:
   - Call `public.record_deletion_failure_wrapper(user_id, 'FK_PROCESSING_FAILED')`. Only the sanitized error code is passed — no raw storage errors or paths.
   - Return `422 FK_PROCESSING_FAILED`. User can still authenticate and retry.
   - **Stop here.** Do not delete the auth account.
5. Delete the `auth.users` row for this user via Admin API (administrative client). If this fails → return `500 FK_INTERNAL`. User can still authenticate and retry.
6. Call `public.mark_auth_deleted(user_id)` via administrative client. If this fails: auth has already been deleted; JWT is now void; client cannot retry. Log `user_id` and `request_id` for the recovery worker. Return `500 FK_INTERNAL`.
7. Call `public.mark_storage_cleaned(user_id)` via administrative client. Transitions deletion record to `complete`. If this fails: same situation as step 6. Log for recovery worker. Return `500 FK_INTERNAL`.
8. Return `200 {"status": "complete"}`.

**Client retry after step 5 (auth deletion):** Once auth is deleted, the JWT is void. The gateway rejects subsequent requests. The client cannot retry steps 6–7 — that recovery is handled exclusively by the deletion-recovery-worker.

**Idempotency at step 1:** If a deletion record is already `database_prepared`, `prepare_account_deletion_wrapper` is idempotent and returns normally. Subsequent retries continue from step 2.

**Upload sessions at account deletion:** Upload sessions reference `public.profiles(id)`, not `auth.users(id)`. Deleting the `auth.users` row does not cascade to or conflict with upload session rows. Upload sessions in `processing` or `sanitized` state will be cleaned up by the upload-cleanup-worker on its next run.

**Response `200 OK`:**
```json
{ "status": "complete" }
```

**Logging:** `user_id` (before deletion), `storage_key_count`, `deleted_count`, `failed_count`, deletion record state at each step. NOT storage paths, key values, or file content.

---

### 4.6 `upload-cleanup-worker`

**Purpose:** Transition stale upload sessions to terminal states, delete their orphaned storage objects, and mark sessions `cleaned`.

**Trigger:** Supabase pg_cron, every 15 minutes.

**`verify_jwt`:** `false`

**Authentication:** Cron-secret pattern (Section 3.5). Checks `X-Forkensics-Cron-Secret` against `CRON_SECRET` env var using constant-time comparison. If absent or mismatch → `401 FK_UNAUTHENTICATED`.

**Action:**
1. Call `public.claim_cleanup_sessions(worker_id, processing_lease_timeout := '10 minutes', pending_expiry_grace := '1 minute')` (administrative client). This atomically: transitions stale `pending` sessions → `expired`; transitions lease-expired `processing` sessions → `failed`; claims and returns all sessions needing cleanup (`expired`, `superseded`, `failed`, and abandoned `sanitized`); uses `FOR UPDATE SKIP LOCKED` to prevent concurrent workers from processing the same session. Never returns `complete` sessions.
2. For each claimed session:
   a. If status was `expired` or `superseded`: attempt to delete `session.original_storage_path` from storage (administrative client). Log outcome.
   b. If status was `processing` (now `failed`) or `sanitized`: attempt to delete `session.display_storage_path` from storage; also attempt `original_storage_path` if status was `processing`. Since `display_storage_path` is recorded at session creation, it is always available — even if the session never reached `sanitized`. Log outcome.
   c. If status was `failed`: attempt to delete both paths (either may exist). Log outcome.
   d. If all applicable storage deletions succeeded: call `public.mark_session_cleaned(session_id)` (administrative client). Transitions to `cleaned`; sets `cleanup_completed_at`.
   e. If any storage deletion failed: leave the session in its current terminal state (not `cleaned`). Log `session_id` and sanitized error code. The session will be returned again on the next cleanup run.
3. Return summary.

**Idempotency:** Deletion of an already-absent storage object returns success (no-op). `mark_session_cleaned` is idempotent. Claimed sessions not yet marked `cleaned` are re-claimed on the next run.

**Response `200 OK`:**
```json
{
  "sessions_claimed": 5,
  "sessions_cleaned": 4,
  "sessions_failed_cleanup": 1,
  "objects_deleted": 7,
  "objects_not_found": 1,
  "objects_failed": 0
}
```

**Logging:** Counts above. NOT storage paths or session IDs.

---

### 4.7 `deletion-recovery-worker`

**Purpose:** Resume account deletions that advanced past auth deletion server-side and can no longer be retried by the client.

**Trigger:** Supabase pg_cron, every 5 minutes.

**`verify_jwt`:** `false`

**Authentication:** Cron-secret pattern (Section 3.5). Checks `X-Forkensics-Cron-Secret` against `CRON_SECRET` env var using constant-time comparison. If absent or mismatch → `401 FK_UNAUTHENTICATED`.

**Action:**

Scan 1 — `database_prepared` records where auth has been deleted externally:
1. Query deletion records in `database_prepared` state older than 10 minutes (administrative client).
2. For each: check whether `auth.users` row still exists (Admin API). If auth still exists → skip; the client can still retry `account-delete-complete`.
3. If auth is gone — storage may never have been cleaned. Before advancing state:
   a. Call `public.get_storage_keys_for_deletion_wrapper(user_id)` (administrative client). Returns one distinct row per physical storage key.
   b. Attempt to delete each storage object from `game-media`. Deletion of an already-absent object is a no-op success.
   c. If any deletion fails → call `public.record_deletion_failure_wrapper(user_id, 'FK_PROCESSING_FAILED')`; leave record in `database_prepared`; log; retry next run.
   d. If all storage deleted (or no keys): call `public.mark_auth_deleted(user_id)` (administrative client); then call `public.mark_storage_cleaned(user_id)` (administrative client). Record is now `complete`.

Scan 2 — `auth_deleted` records awaiting final cleanup:
1. Query deletion records in `auth_deleted` state (administrative client).
2. For each — storage may not have been cleaned. Before advancing state:
   a. Call `public.get_storage_keys_for_deletion_wrapper(user_id)` (administrative client).
   b. Attempt to delete each storage object. Absent objects are no-op successes.
   c. If any deletion fails → call `public.record_deletion_failure_wrapper(user_id, 'FK_PROCESSING_FAILED')`; leave record in `auth_deleted`; log; retry next run.
   d. If all storage deleted (or no keys): call `public.mark_storage_cleaned(user_id)` (administrative client). Record is now `complete`.

**Response `200 OK`:**
```json
{
  "database_prepared_scanned": 0,
  "auth_confirmed_absent": 0,
  "storage_cleaned_and_advanced": 0,
  "auth_deleted_scanned": 0,
  "auth_deleted_completed": 0,
  "storage_cleanup_failures": 0,
  "errors": []
}
```

**Idempotency:** All V1 deletion state-transition functions are idempotent for their target state. A record already at `complete` is not returned by either scan.

**Deployment gate:** `deletion-recovery-worker` must be deployed together with `account-delete-complete` — not separately. A single deployment gate covers both.

**Logging:** Counts only. NOT user IDs, storage paths, or error details.

---

## Section 5 — Contract Test Requirements

### 5.1 Local Contract Tests

Each function gets a dedicated contract test file. Tests must cover:

**Authentication and authorization:**
- Missing JWT → `401` (gateway or function — document which for each function)
- Expired JWT → `401`
- Standard gate: valid JWT, `is_active = false` → `403 FK_FORBIDDEN`
- Standard gate: valid JWT, `onboarding_complete = false` → `403 FK_FORBIDDEN`
- Carve-out gate (`account-delete-complete`): `is_active = false` → allowed
- Carve-out gate: `onboarding_complete = false` → allowed
- Cron functions: missing `X-Forkensics-Cron-Secret` → `401`
- Cron functions: incorrect `X-Forkensics-Cron-Secret` → `401`

**Existence and probing:**
- Nonexistent `challenge_id` → `404 FK_NOT_FOUND`
- Valid `challenge_id`, caller not authorized → same `404 FK_NOT_FOUND` (body identical — no probing)

**Upload token lifecycle:**
- Expired token → `400 FK_INVALID_TOKEN`
- Superseded token → `400 FK_INVALID_TOKEN`
- Unknown token → `400 FK_INVALID_TOKEN`
- Token for `failed` session → `400 FK_INVALID_TOKEN` (failed sessions are not retryable)
- Token for `complete` session → `200 {"status":"ready","already_complete":true}`
- Token for `processing` session → `202 {"status":"processing"}`
- Token for `sanitized` session → finalization retried; `200` on success

**MIME and content validation:**
- JPEG bytes, declared `image/jpeg` → allowed
- WebP bytes, declared `image/webp` → allowed
- JPEG bytes, declared `image/webp` → `400 FK_INVALID_CONTENT_TYPE` (actual does not match declared)
- WebP bytes, declared `image/jpeg` → `400 FK_INVALID_CONTENT_TYPE` (actual does not match declared)
- PNG bytes, declared `image/jpeg` → `400 FK_INVALID_CONTENT_TYPE` (actual not allowed)
- Actual stored file exceeds 10 MB → `400 FK_FILE_TOO_LARGE`

**Upload path and storage:**
- Two `upload-authorize` calls produce different `session_id` values and different storage paths
- Both `original_storage_path` and `display_storage_path` are recorded in the session row at creation
- `upload-complete` reads both paths from the session row — never constructs them in Edge Function code
- Original confirmed absent before `sanitized` state is set
- `advance_upload_session_sanitized` does not modify the display path (already set at creation)

**Sanitized state and finalization:**
- Session in `sanitized` state: finalization can proceed without the original
- `finalize_upload_session` is atomic: all three DB operations commit together or none do
- `finalize_upload_session` is idempotent for `complete` sessions

**Cleanup worker:**
- Worker finds stale `pending` session past `expires_at` → transitions to `expired`; storage at `original_storage_path` deleted; session marked `cleaned`
- Worker finds lease-expired `processing` session → transitions to `failed`; attempts deletion at both storage paths; marks `cleaned` if all deletions succeed
- Worker finds abandoned `sanitized` session → deletes at `display_storage_path` (path is in session row from creation, even though original is gone); marks `cleaned`
- Worker finds `failed` session → attempts both paths; marks `cleaned` if all deletions succeed
- `complete` sessions: never returned by `claim_cleanup_sessions`; never cleaned
- Concurrent workers: `FOR UPDATE SKIP LOCKED` prevents double-processing; each session is claimed by at most one worker per run
- Cleanup failure: session not marked `cleaned`; reappears in next run
- Cleanup completion marker: `cleanup_completed_at` set when transitioning to `cleaned`
- Auth deletion with persistent upload sessions: `uploader_id` references `public.profiles(id)`; deleting `auth.users` row does not cascade to upload_sessions; sessions remain visible to cleanup worker

**`media-serve`:**
- RLS on `public.challenges` restricts draft challenges to the poster; no additional check in function code
- Challenge in `active` state, group member → `200`
- Challenge in `draft` state, poster → `200`
- Challenge in `draft` state, group member (not poster) → `404`
- `media_object_id` null → `404`
- Storage key served is `re_encoded_storage_key` from `private.media_storage_keys` — not a reconstructed path

**`scheduled-close`:**
- Challenge past `deadline_at` in `active` → locked in Pass 1; revealed in Pass 2
- Challenge already `locked` (prior run) → not selected in Pass 1; revealed in Pass 2
- Challenge already `revealed` → excluded by `WHERE state = 'locked'` in Pass 2; no per-row error
- Per-row failure in Pass 1 does not abort Pass 2

**`account-delete-complete`:**
- First-time deletion, no prior deletion record: `prepare_account_deletion_wrapper` called → record created → `database_prepared`; flow proceeds normally
- Retry when record already `database_prepared`: `prepare_account_deletion_wrapper` is idempotent; flow proceeds from step 2
- Storage failure → `422`; auth account not deleted; user can still authenticate and retry
- Auth deletion failure → `500`; user can authenticate and retry
- `mark_auth_deleted` failure after auth deletion → `500`; JWT void; recovery worker handles
- `is_active = false` → allowed (carve-out)
- `onboarding_complete = false` → allowed (carve-out)
- Only sanitized error code passed to `record_deletion_failure_wrapper`
- Record already `auth_deleted` at step 1 → `409 FK_WRONG_STATE`

**`deletion-recovery-worker`:**
- Scan 1: `database_prepared` record, auth still exists → skipped
- Scan 1: `database_prepared` record, auth gone, storage objects present → storage deleted first; then `mark_auth_deleted` + `mark_storage_cleaned` → `complete`
- Scan 1: `database_prepared` record, auth gone, storage deletion fails → `record_deletion_failure` called; record stays `database_prepared`; retried next run
- Scan 2: `auth_deleted` record, storage objects present → storage deleted first; then `mark_storage_cleaned` → `complete`
- Scan 2: `auth_deleted` record, storage deletion fails → `record_deletion_failure` called; record stays `auth_deleted`; retried next run
- All V1 transition functions are idempotent; running worker twice produces the same result
- Authentication failure → `401`

**Error format:**
- All function-produced errors match `{ "error": { "code": "FK_...", "message": "..." } }`
- Logs contain no storage paths, upload tokens, or raw error messages

### 5.2 Production Verification

After each function is deployed to `forkensics-prod`, per-function non-mutating probes confirm deployment succeeded. Generic probes do not apply to all functions:

| Function | Production probe |
|---|---|
| `upload-authorize` | Unauthenticated request → `401`; authenticated with missing `challenge_id` → `400` |
| `upload-complete` | Unauthenticated request → `401`; authenticated with missing `upload_token` → `400` |
| `media-serve` | Unauthenticated request → `401`; authenticated with nonexistent `challenge_id` → `404` |
| `scheduled-close` | Request without cron secret → `401` |
| `upload-cleanup-worker` | Request without cron secret → `401` |
| `deletion-recovery-worker` | Request without cron secret → `401` |
| `account-delete-complete` | Unauthenticated request → `401`. No authenticated probe — an authenticated request would trigger the deletion flow. |

These probes create no data and make no state changes. The local smoke test suite runs only against `forkensics-dev`.

### 5.3 What Contract Tests Must Never Do

- Call `reveal_challenge` or its service wrapper on a real challenge
- Assert on or log canonical answers, restaurant names, or city values
- Leave test data in `forkensics-prod`
- Hard-code credentials — use environment variables or test-only Vault entries
- Pass raw storage errors or storage paths into any `record_deletion_failure` call

---

## Section 6 — Deployment Sequence

Each function is deployed one at a time. Each deployment is gated on:
1. V2 migration complete and verified (for all functions using V2 wrappers)
2. Local contract tests pass
3. GPT review of the implementation
4. Bill approves with `APPROVED: Deploy {function-name}`
5. Deploy to `forkensics-dev`; local smoke tests pass against dev
6. Bill approves with `APPROVED: Deploy {function-name} to prod`
7. Deploy to `forkensics-prod`; per-function production probes pass (non-mutating; per table in Section 5.2)

**Cron credential setup** must complete before deploying any cron-authenticated function or worker. Setup: generate secret; store in Vault; configure as Edge Function environment variable. This is a prerequisite for `scheduled-close`, `upload-cleanup-worker`, and `deletion-recovery-worker`.

**Deployment order:**
1. V2 migration (upload-session infrastructure + all V2 public wrapper functions) — separate Step 25
2. Cron credential setup
3. `upload-authorize`
4. `upload-complete` + `upload-cleanup-worker` (deployed together)
5. `media-serve`
6. `scheduled-close`
7. `account-delete-complete` + `deletion-recovery-worker` (deployed together; recovery worker must go live simultaneously)

---

## Section 7 — Out of Scope for Step 24

- Any TypeScript or Deno code
- Any `supabase functions deploy` command
- V2 migration content (covered in Step 25)
- Push notifications
- Sign in with Apple configuration
- Any iOS application code
- Member removal (no V1 function)
- Cron credential key management beyond the pattern defined in Section 3.5

---

## Success Criteria for Step 24

- [ ] Decision matrix agreed: cancel/apply_correction permit poster or group owner; reason nullable; comments use INSERT + soft_delete_comment; reactions use INSERT + DELETE
- [ ] V2 upload session table agreed: `uploader_id` → `public.profiles(id)`; both storage paths at creation; processing lease; cleanup_completed_at; `cleaned` terminal state
- [ ] V2 function set agreed: create, advance_processing, advance_sanitized, finalize, fail, claim_cleanup, mark_cleaned, get_media_storage_key, all deletion wrappers; V2 functions enforce own invariants
- [ ] Upload-authorize agreed: session created before signed URL; both paths returned and recorded at creation; `session_id` internal only; token hash stored, not token
- [ ] Upload-complete agreed: MIME must match declared type AND be allowed; failed sessions are not retryable; processing → sanitized → complete flow; display path read from session row, not constructed; idempotency branches correct
- [ ] Cleanup worker agreed: claim atomically with SKIP LOCKED; stale pending → expired; lease-expired processing → failed; abandoned sanitized included; cleaned after storage confirmed deleted; complete sessions never touched
- [ ] `media-serve` agreed: RLS enforces visibility; re_encoded_storage_key from V2 wrapper; no path reconstruction
- [ ] Cron authentication agreed: secret in Vault (for pg_cron) and in Edge Function env var (for comparison); constant-time comparison; applies to all three cron-authenticated functions
- [ ] `scheduled-close` agreed: two-pass design; Pass 2 uses WHERE state = 'locked'
- [ ] Account deletion agreed: `prepare_account_deletion_wrapper` called first; storage deleted before auth; recovery worker does its own storage deletion in both scans; only sanitized codes to record_deletion_failure
- [ ] Recovery worker agreed: both scans retrieve and delete storage before advancing state; storage failure leaves record in current state; idempotent
- [ ] Per-function production probes agreed: account-delete-complete probe is unauthenticated-only; workers use cron-secret probe only
- [ ] Deployment order agreed: workers deployed together with their corresponding Edge Functions; cron credential setup prerequisite
- [ ] No Edge Function code written before approval
