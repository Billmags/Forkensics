# Step 27 Proposal — Rev 2 — Edge Function Implementation Plan

**Status:** Pending review (Claude → Codex → Bill approval)

**Governance gate:** All three parties (Bill + Claude + Codex) must approve before any TypeScript code is written. The magic words are `APPROVED: Step 27 Rev 2 — Edge Function Implementation Plan`.

**Supersedes:** Step 27 Rev 1 (rejected — 10 blockers)

**Rev 2 changes:** All 10 Codex blockers resolved. `finalize_upload_session` V4 signature corrected. `upload-complete` state machine restored in full. `scheduled-close` two-pass with correct state names. Account deletion order fixed. Deletion-recovery worker corrected. Moderation functions explicitly deferred with hard gate. Cleanup worker NULL-expiry and function-naming corrected. Swift contracts restored from Step 24 §4.1. Test toolchain corrected (deno). Image-processing spike added as hard pre-implementation gate. Step 24→V4 behavioral delta table added.

---

## Section 1 — Scope and Authorization Chain

### 1.1 What This Step Covers

This step defines the implementation plan for all Edge Functions described in Step 24. It does not write TypeScript — it defines the pre-implementation gates, per-function build order, local test requirements, deployment gates, and Swift API surface so that implementation can proceed one function at a time.

Step 24 Rev 10 is the binding contract. This step translates it into a verified implementation sequence that accounts for all V4 schema divergences from V3.

### 1.2 What This Step Does Not Cover

- No TypeScript code is written until this plan is approved.
- No Supabase cloud operations until the relevant function step is approved separately.
- Moderation functions (`approve_photo`, `reject_photo`, `remove_content`, `remove_media`) are service_role-only in V4 and require a dedicated Edge Function. That function (`moderation-action`) is **deferred** — see Section 5.8.
- V2 migration functions (`reserve_upload_session`, `activate_upload_session`, etc.) are defined in Step 24 §2.7 and Step 25. This step assumes V2 migration is applied and tested before any Edge Function is deployed.

### 1.3 Security Constraints (Carried Forward — Immutable)

All constraints from the project governance log remain in effect:

- Secret key never in client code, never in the repo, never sent to Claude.
- No cloud operations until the relevant step is explicitly approved by Bill.
- Migration failure stop rule: stop immediately, do not repair, return evidence for review.
- V1 freeze: immutable. All future DB changes are V2__*.sql and beyond.
- PGPASSWORD never stored in `.env.dev` / `.env.prod`; obtained at runtime.
- `private` schema never exposed through PostgREST.
- `SUPABASE_DB_URL` direct connection NOT used by Edge Functions.
- No live Supabase deployment authorized under this step.
- Three-party governance: Bill + Claude + Codex must all approve before any SQL or test edit.

---

## Section 2 — Step 24 → V4 Behavioral Delta Table

Step 24 was written against the V3 schema. V4 renames "challenges" to "cases" and introduces behavioral changes beyond simple identifier renaming. Every Edge Function that touches the database must use the V4 contract column.

| Step 24 term / contract | V4 actual | Impact on Edge Functions |
|---|---|---|
| `public.challenges` table | `public.cases` table | All queries, RLS references |
| `challenge_id` parameter | `case_id` parameter | All RPC calls, path params |
| `challenge_id` FK column | `case_id` FK column | `private.upload_sessions` V2 schema |
| `public.lock_challenge(uuid)` | `public.lock_case(uuid)` | `scheduled-close` Pass 1 |
| `public.reveal_challenge_service_wrapper(uuid)` | `public.reveal_case_service_wrapper(uuid)` | `scheduled-close` Pass 2 |
| Cases use `state = 'active'` (V3) | Cases use `state = 'launched'` (V4) | `scheduled-close` query filter; `lock_case` precondition |
| `state = 'locked'` required for reveal (V3) | `state = 'locked'` required for `reveal_case_service_wrapper` (V4, confirmed) | No change in logic; function name changes |
| `finalize_upload_session(session_id uuid)` — one arg; media `status = 'ready'` | `finalize_upload_session(session_id uuid, sha256_hash text)` — two args; media `status = 'pending_review'` | `upload-complete` must compute SHA-256; response `status` field changes |
| `upload-complete` 200: `"status": "ready"` | `"status": "pending_review"` | Swift must not assume media is immediately servable |
| `media-serve GET /media/{challenge_id}` | `GET /media/{case_id}` path param; `get_media_serve_authorization(media_object_id, viewer_id)` service_role call; requires `mo.status = 'ready'` | Pending-review media returns 404; V4 authorization function replaces `get_media_storage_key` |
| `get_media_storage_key(media_object_id)` — status check only | `get_media_serve_authorization(media_object_id, viewer_id)` — status + case visibility + moderator_removed_at | More restrictive; granted service_role only |
| `submit_guess`: direct authenticated INSERT into `public.guess_attempts` | Must use `supabase.rpc("submit_guess", { case_id, ... })` — direct INSERT revoked in V4 | Swift integration change |
| `launch_case` not in Step 24 direct-RPC table | `public.launch_case(uuid, uuid, uuid[], integer)` — authenticated, callable directly | Add to Swift direct-RPC table |
| `approve_photo`, `reject_photo`: not explicitly categorized | V4: service_role ONLY — not callable with user JWT | Requires `moderation-action` Edge Function; deferred (§5.8) |
| `remove_content`, `remove_media`: not explicitly categorized | V4: service_role ONLY — not callable with user JWT | Same gate |
| `report_content`: Step 24 assumes user-callable | V4: authenticated-callable (confirmed) | No change needed |
| `activate_challenge(uuid)` — V3 | `launch_case(uuid, uuid, uuid[], integer)` — V4 | Different function name and signature |
| `reveal_challenge(uuid)` — V3 (poster manual) | V4 equivalent if it exists; not yet verified — defer to implementation | Verify before implementation |
| `cancel_challenge(uuid, text)` — V3 | V4 equivalent — not yet verified | Verify before implementation |

**Hard constraint derived from this table:** After `finalize_upload_session`, media is `pending_review`. A case cannot be `launched` until a moderator calls `approve_photo`. There is no Edge Function for moderation calls in this plan. This is a known launch blocker — see Section 5.8.

---

## Section 3 — Pre-Implementation Gates

All gates in this section must be satisfied before the first line of Edge Function TypeScript is written.

### Gate 1 — V2 Migration Applied and Tested

`V2__upload_sessions.sql` must be applied, committed, and the V2 acceptance test suite must pass (Steps 25/26 complete). This step assumes V2 is live locally and in CI.

### Gate 2 — Image Processing Spike (Hard Gate)

**Required before implementing `upload-complete`.**

The Supabase documentation recommends `magick-wasm` for image processing in Edge Functions. A known risk: Supabase warns of a ~5 MB WASM binary size limit that may conflict with `magick-wasm`. `upload-complete` must process images up to 10 MB.

The spike must:

1. Create a standalone Deno script (not a deployed function) that imports `magick-wasm`.
2. Process test inputs of 5 MB, 8 MB, and 10 MB JPEG/WebP through the pipeline: decode → strip EXIF/GPS/ICC → re-encode to WebP → compute SHA-256 of output bytes.
3. Verify decompression-bomb protection (reject or limit images with extreme pixel dimensions after decode).
4. Record CPU time, memory peak, and wall-clock time on forkensics-dev hardware.
5. Confirm the WASM bundle loads within Supabase's Edge Function size limits.

**Spike verdict is a gate:** If the spike fails at 10 MB or the WASM bundle exceeds limits, the team must choose one of:
- (a) Enforce a 5 MB declared size limit instead of 10 MB, or
- (b) Identify an alternative compute path (separate worker, different library).

No implementation of `upload-complete` proceeds until the spike produces a written verdict.

### Gate 3 — pg_cron / pg_net Preflight

Before `scheduled-close` or any worker is deployed, a local preflight task must verify:
- `pg_cron` extension is enabled on forkensics-dev.
- `pg_net` extension is enabled.
- A test cron job fires a pg_net HTTP request to a local echo server and receives it within the expected window.

This must be documented in the evidence log.

### Gate 4 — S3 Connection Enabled

The Supabase project must have S3 compatibility enabled and tested locally before `upload-authorize` is implemented. A preflight test must:
- Sign a presigned PUT URL for a scratch object using S3 Signature V4 with 5-minute expiry.
- Upload a test object via the signed URL.
- Confirm the object appears in the `game-media` bucket.
- Delete the object.

`createSignedUploadUrl()` is NOT acceptable — it produces 2-hour URLs. S3 Signature V4 with `ExpiresIn: 300` is required.

### Gate 5 — Deno Toolchain Verified

Before writing any function, confirm:
- `deno check supabase/functions/<fn>/index.ts` passes with zero errors.
- `deno fmt --check supabase/functions/<fn>/index.ts` passes.
- `deno lint supabase/functions/<fn>/index.ts` passes.
- `gitleaks detect` (or equivalent high-entropy credential scanner) passes on the repo.

These replace `bash -n` for TypeScript validation. All CI checks must use `deno check`, not Node tooling.

### Gate 6 — Dependency Lockfile Committed

`deno.lock` must be committed at the repo root before any function is merged. All import specifiers must pin exact versions. No floating semver ranges.

---

## Section 4 — Implementation Order

Functions are built and approved one at a time. No function proceeds to implementation until its prerequisites are satisfied and the relevant three-party approval is obtained.

```
Gate 1 (V2 migration)
Gate 2 (magick-wasm spike) ──────────────────────────────┐
Gate 3 (pg_cron preflight)                               │
Gate 4 (S3 connection)                                   │
Gate 5 (deno toolchain)                                  │
Gate 6 (lockfile)                                        │
         │                                               │
         ▼                                               │
Step A: upload-authorize                                 │
Step B: upload-complete ◄────────────────────────────────┘
Step C: upload-cleanup-worker (deploy with Step B)
Step D: media-serve
Step E: scheduled-close
Step F: account-delete-complete
Step G: deletion-recovery-worker (deploy with Step F)
Step H: moderation-action [DEFERRED — see §5.8]
```

Each step produces: implementation, local tests (passing), deno check/lint/fmt clean, gitleaks clean, then waits for three-party approval before the next step.

---

## Section 5 — Per-Function Build Plans

### 5.1 `upload-authorize`

**Contract:** Step 24 §4.1 (no V4 delta).
**V4 identifier changes:** `challenge_id` → `case_id` in all DB calls; `public.challenges` → `public.cases`.

**Response (from Step 24 §4.1 — never deviate):**
```json
{ "presigned_url": "<url>", "upload_token": "<secret token>", "expires_at": "<ISO 8601>" }
```

`session_id`, storage paths, and `storage_upload_expires_at` are internal — never returned.

**Presigned URL requirements:**
- S3 Signature V4.
- `ExpiresIn: 300` (5 minutes).
- `createSignedUploadUrl()` is prohibited — it produces 2-hour URLs.

**Shared module dependencies:** `validateJwt`, `adminClient`, `errorEnvelope`, `cronAuth` (not used here but in shared module), `sha256Hex`.

**Local tests (required before approval):**
- Valid request → 200 with correct response shape; `session_id` absent from response.
- Non-draft case → 409 `FK_WRONG_STATE`.
- Non-poster → 404 `FK_NOT_FOUND`.
- Duplicate active session → 409 `FK_UPLOAD_IN_PROGRESS`.
- Uploader with `database_prepared` deletion record → 403 `FK_FORBIDDEN`.
- Missing JWT → 401; inactive profile → 403.
- `declared_size_bytes` > 10,485,760 → 400 `FK_FILE_TOO_LARGE`.
- Invalid `content_type` → 400 `FK_INVALID_CONTENT_TYPE`.
- URL activation failure: `activate_upload_session` throws → 500 `FK_INTERNAL`; URL not returned; `fail_upload_session` called.

---

### 5.2 `upload-complete`

**Contract:** Step 24 §4.2, with the following V4 corrections.

**V4 correction 1 — `finalize_upload_session` signature:**
V4 function signature: `finalize_upload_session(session_id uuid, sha256_hash text)`.
Before calling finalization, compute SHA-256 of the re-encoded WebP bytes as lowercase hex (64 characters). This is computed in-memory from the WebP output buffer — not from the original. Pass as `sha256_hash` argument.

V4 validation in the DB function: if `sha256_hash` does not match `^[0-9a-f]{64}$` → raises `FK_INVALID_HASH`. Treat as `422 FK_PROCESSING_FAILED` on the Edge Function side.

**V4 correction 2 — media `status` after finalization:**
`finalize_upload_session` creates `media_objects` with `status = 'pending_review'` (not `'ready'`).

**Response `200 OK` (V4):**
```json
{ "media_object_id": "<uuid>", "status": "pending_review" }
```

**Complete state machine (restored from Step 24 §4.2):**

*Idempotency branch — check session status before any action:*
- `complete` → `200 {"status":"pending_review","media_object_id":"<uuid>","replaced_media_object_id":"<uuid or null>","already_complete":true}`.
- `processing` → `202 {"status":"processing"}`.
- `sanitized` → skip to finalization (step 9 below).
- `pending` → proceed to happy path.
- Any other status (`expired`, `failed`, `cleaned`) → `400 FK_INVALID_TOKEN`.

*Happy path (status `pending`):*

1. `advance_upload_session_processing(session_id, user_id, '10 minutes')` — transitions to `processing`, sets lease. Failure → `400 FK_INVALID_TOKEN`.
2. Read original from `session.original_storage_path`. Absent → `fail_upload_session(session_id, 'FK_NOT_FOUND')`; return `404 FK_NOT_FOUND`.
3. Sniff actual MIME. Must be `image/jpeg` or `image/webp` AND match `session.content_type`. Failure → delete original; `fail_upload_session('FK_INVALID_CONTENT_TYPE')`; return `400 FK_INVALID_CONTENT_TYPE`.
4. Confirm actual size ≤ 10,485,760 bytes. Over limit → delete original; `fail_upload_session('FK_FILE_TOO_LARGE')`; return `400 FK_FILE_TOO_LARGE`.
5. Re-encode to WebP; strip all EXIF, GPS, ICC metadata. Failure → delete original; `fail_upload_session('FK_PROCESSING_FAILED')`; return `422 FK_PROCESSING_FAILED`.
5.5. `check_upload_session_lease(session_id)`. If false → delete original; return `422 FK_PROCESSING_FAILED`. Do NOT call `fail_upload_session`. Do NOT write display.
6. Write re-encoded WebP to `session.display_storage_path`. Failure → delete original; `fail_upload_session('FK_PROCESSING_FAILED')`; return `422 FK_PROCESSING_FAILED`.
7. Delete original from `session.original_storage_path`. Retry up to 2 times. All attempts fail → delete display; `fail_upload_session('FK_PROCESSING_FAILED')`; return `422 FK_PROCESSING_FAILED`.
8. `advance_upload_session_sanitized(session_id)`. Raises → delete display; return `500 FK_INTERNAL`.

*Finalization (from step 8, or re-entered from `sanitized` branch):*

9. Compute SHA-256 of WebP output bytes (lowercase hex, 64 chars).
10. `finalize_upload_session(session_id, sha256_hash)`. Verifies `sanitized` or idempotent `complete`; verifies case `draft`. Challenge not `draft` → `409 FK_WRONG_STATE`. Session not `sanitized`/`complete` → `409 FK_WRONG_STATE`. `FK_INVALID_HASH` → `422 FK_PROCESSING_FAILED`. Failure with session still `sanitized` → `500 FK_INTERNAL`; client retries.
11. Return `200 {"media_object_id":"<uuid>","status":"pending_review"}`.

**Note on `sanitized` branch re-entry:** The WebP output buffer must be retained in memory across the sanitized-branch path so SHA-256 can be computed before step 10. The buffer is not re-read from storage.

**Local tests (required):**
- Full happy path → 200, `status = "pending_review"`.
- Idempotent `complete` → 200 `already_complete: true`.
- `processing` → 202.
- `sanitized` re-entry → correct finalization without re-processing.
- Lease expiry between steps 5 and 5.5 → 422 (no fail_upload_session, no display write).
- Original deletion failure after 2 retries → display deleted, session failed, 422.
- `FK_INVALID_HASH` from DB → 422.
- `finalize` fails with session still `sanitized` → 500; client can retry.
- Invalid token / expired / failed → 400 `FK_INVALID_TOKEN`.

---

### 5.3 `upload-cleanup-worker`

**Contract:** Step 24 §4.6, with the following V4 corrections.

**V4 correction — function name for complete sessions:**
Part 3 uses `get_complete_sessions_pending_expiry_cleanup()` (confirmed in V2 schema at line 928). Returns `(session_id, original_storage_path)` for complete sessions where `original_path_post_expiry_cleaned = false` AND `storage_upload_expires_at + 30s <= now()`.

**V4 correction — NULL-expiry sessions:**
Sessions with `storage_upload_expires_at IS NULL` (no capability was ever issued) are included in `claim_cleanup_sessions` without the URL-expiry gate (Step 24 §2.7 ¶4). The cleanup worker must attempt to delete their `original_storage_path` as a precaution — the object may or may not exist. Absent = no-op.

**V4 correction — `mark_session_cleaned` is conditional:**
`mark_session_cleaned` is only called if all storage deletions for that session succeed. If any deletion fails → do not mark cleaned; session re-appears after claim expiry.

**Deployment:** Deploy simultaneously with `upload-complete` (Step B → Step C as a single deployment event).

**Part 1 — upload session cleanup:**
1. `claim_cleanup_sessions(worker_id, '15 minutes')`.
2. For each: delete `original_storage_path` and `display_storage_path` (absent = no-op). If all succeed → `mark_session_cleaned(session_id, cleanup_claim_token)`. If any fail → log; do not mark; retry next run.

**Part 2 — superseded media:**
1. `get_superseded_media_to_clean()`. For each: delete `re_encoded_storage_key`. Success → `mark_superseded_media_cleaned`. Failure → log; retry next run.

**Part 3 — post-expiry original-path cleanup (complete sessions):**
1. `get_complete_sessions_pending_expiry_cleanup()`.
2. For each: attempt delete of `original_storage_path`. Absent = no-op (normal case — step 7 of `upload-complete` already deleted it).
3. If delete succeeded or object was absent → `mark_original_path_post_expiry_cleaned(session_id)`.
4. If delete failed and object was present → log; do NOT call `mark_original_path_post_expiry_cleaned`; retry next run.

---

### 5.4 `media-serve`

**Contract:** Step 24 §4.3, with the following V4 corrections.

**V4 correction — path parameter:**
Path: `GET /media/{case_id}` (not `{challenge_id}`).

**V4 correction — authorization function:**
V4 does not use `get_media_storage_key`. Instead:
- Call `get_media_serve_authorization(media_object_id, viewer_id)` with service_role client.
- This function requires `mo.status = 'ready'`, `c.moderator_removed_at IS NULL`, and `can_viewer_access_case(c.id, viewer_id)`.
- If no result → `404 FK_NOT_FOUND` (media pending review, moderator-removed, or not accessible).

**V4 behavioral implication:** Pending-review media (`status = 'pending_review'`) returns 404. This is by design — media is not servable until a moderator approves it.

**Full action sequence:**
1. Standard gate.
2. Query `public.cases` using user-JWT client. No row (not found or not visible) → `404 FK_NOT_FOUND`.
3. `media_object_id` null → `404 FK_NOT_FOUND`.
4. `get_media_serve_authorization(media_object_id, user_id)` via service_role client. No result → `404 FK_NOT_FOUND`.
5. Read file at returned storage key from `game-media`.
6. Stream bytes: `Content-Type: image/webp`, `Cache-Control: private, max-age=3600`.

**Local tests (required):**
- Authorized viewer, `ready` media → 200 WebP bytes.
- `pending_review` media → 404.
- Moderator-removed case → 404.
- Viewer not in group → 404 (same body as not found).
- No media attached → 404.
- Missing JWT → 401.

---

### 5.5 `scheduled-close`

**Contract:** Step 24 §4.4, with the following V4 corrections.

**V4 correction — state names and function names:**
- Pass 1 query: `WHERE state = 'launched' AND deadline_at <= now()` (not `'active'`).
- Pass 1 call: `lock_case(case_id)` (not `lock_challenge`). `lock_case` requires `state = 'launched'` and `deadline_at <= now()`.
- Pass 2 query: `WHERE state = 'locked'`.
- Pass 2 call: `reveal_case_service_wrapper(case_id)` (not `reveal_challenge_service_wrapper`).

**V4 correction — per-row error isolation:**
Each case is processed in isolation. A failure in one row is logged with sanitized code and the function continues to the next. This is unchanged from Step 24 but must be implemented explicitly (not a simple batch RPC).

**Schedule:** Every 2 minutes (pg_cron).

**Cron authentication:** `X-Forkensics-Cron-Secret` header; constant-time comparison to `CRON_SECRET` env var. Absent or mismatch → `401 FK_UNAUTHENTICATED`.

**Full action sequence:**
1. Authenticate cron secret.
2. Pass 1: query `public.cases WHERE state = 'launched' AND deadline_at <= now()` via service_role client. For each row: call `lock_case(case_id)`. Catch per-row errors; log `{ case_id, pass: 'lock', error_code: sanitized }`; continue.
3. Pass 2: query `public.cases WHERE state = 'locked'` via service_role client. For each row: call `reveal_case_service_wrapper(case_id)`. Catch per-row errors; log; continue.

**Note on Pass 2 scope:** Pass 2 queries all `locked` cases, not just those just locked in Pass 1. This ensures cases that failed to reveal in a prior run are retried. `reveal_case_service_wrapper` must be idempotent for already-revealed cases (or the DB function raises a catchable error that the worker logs and skips).

**Response `200 OK`:**
```json
{
  "locked_count": 0, "revealed_count": 0, "skipped_count": 0,
  "errors": []
}
```

**Local tests (required):**
- `launched` case past deadline → locked.
- `locked` case → revealed.
- Two-run scenario: Pass 1 locks, Pass 2 (same run) reveals; next run skips both.
- Per-row error in Pass 1 → logged, Pass 2 still runs for other cases.
- Wrong / missing cron secret → 401.

---

### 5.6 `account-delete-complete`

**Contract:** Step 24 §4.5, with the following V4 corrections.

**V4 correction — deletion order is strict:**
Step 24 §4.5 defines the authoritative order. The order is:
1. `prepare_account_deletion_wrapper(user_id)` → `database_prepared` to continue; `auth_deleted` → `409 FK_WRONG_STATE`; `complete` → log anomaly + `500 FK_INTERNAL`.
2. `quiesce_upload_sessions_for_deletion(user_id)`. If any `blocking_lease_expires_at IS NOT NULL` → `409 FK_UPLOAD_IN_PROGRESS`; return immediately (no waiting in function).
3. `get_upload_capability_expiry(user_id)`. If non-NULL → `409 FK_UPLOAD_IN_PROGRESS` with `retry_after`; return immediately.
4. `get_all_upload_session_paths_for_deletion(user_id)`. Delete all paths.
5. `get_deletion_storage_keys(user_id)`. Delete all established media storage.
6. If any deletion from steps 4–5 failed → `record_deletion_failure_wrapper(user_id, 'FK_PROCESSING_FAILED')`; return `422 FK_PROCESSING_FAILED`.
7. Delete `auth.users` via Admin API. Failure → `500 FK_INTERNAL`.
8. `mark_auth_deleted_wrapper(user_id)`. Failure → log for recovery worker; `500 FK_INTERNAL`.
9. `mark_storage_cleaned_wrapper(user_id)`. Failure → log for recovery worker; `500 FK_INTERNAL`.
10. Return `200 {"status":"complete"}`.

**Critical ordering rule:** `mark_auth_deleted_wrapper` (step 8) is called BEFORE `mark_storage_cleaned_wrapper` (step 9). Auth is deleted before storage is marked cleaned. Inverting this order corrupts the state machine.

**No waiting in function:** The Edge Function must never sleep or poll for URL expiry. If `get_upload_capability_expiry` returns non-NULL, return `409` immediately. The client retries after `retry_after`. The maximum additional wait is 5 minutes + 30 seconds (URL expiry + buffer).

**Deployment gate:** `deletion-recovery-worker` must be deployed simultaneously.

**Local tests (required):**
- Happy path: full sequence → 200 `complete`.
- `auth_deleted` state on entry → 409 `FK_WRONG_STATE`.
- `complete` state on entry → log anomaly + 500.
- Active processing lease → 409 `FK_UPLOAD_IN_PROGRESS`.
- Active URL capability → 409 with correct `retry_after`.
- Storage deletion failure → 422; recovery worker resumes.
- Auth deletion failure → 500; recovery worker resumes.
- `mark_auth_deleted` called before `mark_storage_cleaned` (order verified in test).

---

### 5.7 `deletion-recovery-worker`

**Contract:** Step 24 §4.7, with the following V4 corrections.

**V4 correction — `database_prepared` scan: verify Auth absent first.**
For `scan_type = 'database_prepared'`: the worker must confirm the auth user no longer exists (Admin API `getUser(user_id)` returns 404) before proceeding. If auth user still exists → `fail_deletion_recovery` with `FK_AUTH_STILL_EXISTS`; skip. The primary deletion path (`account-delete-complete`) must have run and succeeded through the auth deletion step.

**V4 correction — `complete_deletion_recovery` is the only state-transition call.**
`complete_deletion_recovery(user_id, claim_token, scan_type)` handles all state transitions internally. The worker must NOT call `mark_auth_deleted_wrapper` or `mark_storage_cleaned_wrapper` separately. Those calls are inside `complete_deletion_recovery`.

**V4 correction — `fail_deletion_recovery` semantics.**
`fail_deletion_recovery` records the failure and removes the claim row. The next cron run will re-issue a claim (if the underlying record still exists) and retry. The worker should not retry within the same invocation.

**Full action sequence:**

1. `claim_deletion_recovery_records(worker_id, '10 minutes', '10 minutes')`.

2. For each claimed record:

   **If `scan_type = 'database_prepared'`:**
   a. Admin API: confirm auth user absent. Present → `fail_deletion_recovery(user_id, claim_token, 'FK_AUTH_STILL_EXISTS')`; skip.
   b. `quiesce_upload_sessions_for_deletion(user_id)`. If any blocking lease → `fail_deletion_recovery(user_id, claim_token, 'FK_UPLOAD_IN_PROGRESS')`; skip.
   c. `get_upload_capability_expiry(user_id)`. If non-NULL → `fail_deletion_recovery(user_id, claim_token, 'FK_UPLOAD_IN_PROGRESS')`; skip.
   d. `get_all_upload_session_paths_for_deletion(user_id)`. Delete all paths.
   e. `get_deletion_storage_keys(user_id)`. Delete all established media storage.
   f. If any deletion failed → `fail_deletion_recovery(user_id, claim_token, 'FK_PROCESSING_FAILED')`; skip.
   g. All deleted → `complete_deletion_recovery(user_id, claim_token, 'database_prepared')`.

   **If `scan_type = 'auth_deleted'`:**
   a. `quiesce_upload_sessions_for_deletion(user_id)`. If blocking lease → `fail_deletion_recovery`; skip.
   b. `get_upload_capability_expiry(user_id)`. If non-NULL → `fail_deletion_recovery`; skip.
   c–f. Same path collection, deletion, and failure handling as `database_prepared` steps d–f.
   g. `complete_deletion_recovery(user_id, claim_token, 'auth_deleted')`.

**Schedule:** Every 5 minutes.

**Deployment gate:** Deploy simultaneously with `account-delete-complete`.

---

### 5.8 `moderation-action` — DEFERRED (Hard Launch Gate)

**Why deferred:** `approve_photo`, `reject_photo`, `remove_content`, and `remove_media` are all granted EXECUTE to `service_role` only in V4. They cannot be called with a user JWT. A moderator Edge Function (`moderation-action`) is required to expose these capabilities to authorized moderators.

**Hard launch blocker:** After `upload-complete`, media is `pending_review`. A case cannot progress until `approve_photo` is called. Without `moderation-action`, no case can ever reach `launched` state from a photo submission. This makes `launch_case`, `scheduled-close`, `media-serve`, and all gameplay impossible.

**`moderation-action` is a hard prerequisite for any end-to-end gameplay.** It must be planned, approved, and implemented before the app is testable beyond the upload flow.

**This step does not define the contract for `moderation-action`.** That requires a separate proposal step with its own three-party approval. The contract must specify: moderator authentication (how moderators are identified — a separate role, a flag on `profiles`, or a separate table), which functions are callable, rate limiting, and audit logging.

**In the meantime:** The implementation sequence in Section 4 proceeds up to and including `media-serve`, with the explicit acknowledgement that end-to-end gameplay is not testable until `moderation-action` is implemented and approved.

---

## Section 6 — Shared Module

All functions share a single `supabase/functions/_shared/` module. This module is the only location for cross-function utilities. No function duplicates any shared logic.

**Required exports:**

| Export | Description |
|---|---|
| `validateJwt(req)` | Extracts and verifies `sub` claim; confirms active profile; returns `{ userId, error }` |
| `validateJwtCarveout(req)` | `account-delete-complete` variant: any profile state accepted |
| `validateCronSecret(req)` | Constant-time compare of `X-Forkensics-Cron-Secret` to `CRON_SECRET` |
| `adminClient()` | Service-role Supabase client (reads `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`) |
| `userClient(jwt)` | User-JWT Supabase client for RLS-scoped reads |
| `errorEnvelope(code, message, status)` | Returns `Response` with JSON `{ error: { code, message } }` |
| `sha256Hex(data: Uint8Array)` | SHA-256 of bytes → lowercase hex string |
| `presignPutUrl(path, expiresIn)` | S3 Signature V4 presigned PUT for `game-media`; never uses `createSignedUploadUrl` |
| `safeLog(fields)` | Structured log; enforces allowlist (never logs paths, tokens, URLs, secrets) |

All environment variables (`SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, `CRON_SECRET`) are read from Deno's `Deno.env.get()`. No environment variable is logged. No secret appears in source code or the lockfile.

---

## Section 7 — Local Test Requirements

### 7.1 Test Toolchain

- TypeScript validation: `deno check supabase/functions/<fn>/index.ts`
- Formatting: `deno fmt --check`
- Linting: `deno lint`
- Credential scan: `gitleaks detect` (or equivalent: high-entropy pattern scanner, not just keyword search)
- Secret scan must cover: base64-encoded strings, hex strings, JWTs, and high-entropy tokens — not just known patterns.

`bash -n` is not a TypeScript validator and must not be used for this purpose.

### 7.2 Per-Function Test Matrix

Each function must pass all tests listed in its §5.x build plan before three-party approval is requested.

### 7.3 No Live Supabase Required

All local tests run against the local Supabase instance (`supabase start`). No cloud operations occur under this step.

### 7.4 Test File Naming

Test files: `supabase/functions/<fn>/<fn>.test.ts`. Integration test helper: `supabase/functions/_shared/test-helpers.ts`.

---

## Section 8 — Deployment Gates

### 8.1 Per-Function Deployment Checklist

Before any function is deployed to a cloud environment (future step, requires separate approval):

1. `deno check`, `deno fmt --check`, `deno lint` — all pass with zero output.
2. `gitleaks detect` — no findings.
3. `deno.lock` committed; all imports pinned.
4. All §5.x local tests passing.
5. Three-party approval obtained for the specific function.
6. No secrets in source, lockfile, or git history.

### 8.2 Rollback Semantics

Rollback = redeploy the last-known-good artifact. There is no "undo" for a deployed Edge Function; rollback requires a new deploy of the prior version. The prior version artifact must be retained in CI/CD until the new version is proven stable.

### 8.3 No Deployment Under This Step

No deployment to any cloud environment is authorized under Step 27. Deployment is a future step requiring a separate three-party approval.

---

## Section 9 — Swift API Surface

### 9.1 Operations Requiring Edge Function Calls (POST via `supabase.functions.invoke`)

| Operation | Function | Auth |
|---|---|---|
| Request upload URL | `upload-authorize` | User JWT |
| Complete upload | `upload-complete` | User JWT |
| Serve image | `media-serve` | User JWT |
| Delete account | `account-delete-complete` | User JWT |

### 9.2 Operations Using Direct RPC (Updated for V4)

These call `supabase.rpc(...)` directly with the user JWT. RLS and executor enforce authorization.

| Operation | V4 RPC Name | Notes |
|---|---|---|
| Submit a guess | `submit_guess` | **Must use `supabase.rpc("submit_guess", { case_id, ... })`** — direct INSERT into `guess_attempts` is revoked in V4 |
| Launch a case | `launch_case` | New in V4; `supabase.rpc("launch_case", { ... })` |
| Add a clue | Direct INSERT into `public.clues` | RLS enforces poster-only |
| Create a group | `create_group` | |
| Create invite | `create_group_invite` | |
| Redeem invite | `redeem_group_invite` | |
| Revoke invite | `revoke_group_invite` | |
| Transfer ownership | `transfer_group_ownership` | |
| Post comment | Direct INSERT into `public.comments` | |
| Soft-delete comment | `soft_delete_comment` | |
| Post reaction | Direct INSERT into `public.reactions` | |
| Remove reaction | Direct DELETE from `public.reactions` | |
| Report content | `report_content` | Authenticated; V4 confirmed |

**Note:** `reveal_case` (poster manual reveal) and `cancel_case` V4 equivalents must be verified against V4 schema before Swift integration is implemented. If the V3 function names changed, the Swift client must be updated accordingly.

### 9.3 Upload-Authorize Response Shape

```swift
struct UploadAuthorizeResponse: Decodable {
    let presignedUrl: String      // "presigned_url"
    let uploadToken: String       // "upload_token"
    let expiresAt: Date           // "expires_at" ISO 8601
}
```

`sessionId` is NOT in the response. Do not attempt to decode or store it.

### 9.4 Upload-Complete Response Shape (V4)

```swift
struct UploadCompleteResponse: Decodable {
    let mediaObjectId: UUID        // "media_object_id"
    let status: String             // "pending_review" (not "ready")
    let alreadyComplete: Bool?     // "already_complete" — present only on idempotent calls
    let replacedMediaObjectId: UUID?  // "replaced_media_object_id"
}
```

The Swift client must not assume the media is immediately displayable after `upload-complete`. The media is in `pending_review` state. `media-serve` returns 404 for pending-review media.

### 9.5 Error Handling

All function errors return:
```swift
struct ForkensicsError: Decodable {
    struct ErrorBody: Decodable {
        let code: String
        let message: String
    }
    let error: ErrorBody
}
```

Gateway errors (401 from JWT rejection) may not follow this envelope.

---

## Section 10 — Open Questions and Resolutions

| Question | Resolution |
|---|---|
| Presigned URL mechanism | S3 Signature V4, `ExpiresIn: 300`. `createSignedUploadUrl()` prohibited. |
| S3 connection on forkensics-dev | Must be enabled and tested (Gate 4). |
| pg_cron / pg_net availability | Must be verified with preflight task (Gate 3). |
| `magick-wasm` viability at 10 MB | Requires spike (Gate 2). Decision point if spike fails. |
| `get_media_serve_authorization` grant | Confirmed service_role only (V4 line 3313-3314). |
| `submit_guess` mechanism | `supabase.rpc("submit_guess", ...)` — direct INSERT revoked in V4 (line 3266). |
| `launch_case` in Swift table | Added to §9.2. |
| Moderation endpoint | Deferred; explicit hard gate documented in §5.8. |
| `reveal_case` / `cancel_case` function names in V4 | Not yet verified. Must be confirmed before Swift integration of those operations. |
| Idle timeout (150 s) vs URL expiry (5 min) | `account-delete-complete` never waits for URL expiry in-function; returns 409 immediately if not expired. |

---

## Section 11 — Approval Record

| Party | Status | Notes |
|---|---|---|
| Claude | Approved | Rev 2 authored by Claude; all 10 blockers addressed |
| Codex | Pending | |
| Bill | Pending | |

To approve: reply with `APPROVED: Step 27 Rev 2 — Edge Function Implementation Plan`.

Implementation does not begin until all three parties have approved.
