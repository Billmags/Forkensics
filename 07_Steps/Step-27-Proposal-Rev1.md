# Step 27 — Edge Function Implementation Plan  (Rev 1)

**Status:** Pending review (Claude → Codex → Bill approval)

**Governance gate:** All three parties must approve before any Edge Function TypeScript/Deno code is written or deployed.

**Depends on:** Step 24 Rev 10 (approved architecture and contracts), V4 committed and passing (`a7a2c54`, tag `v0.4.0-case-investigation-schema`).

**Scope:** Implementation order, shared infrastructure pattern, per-function build plan, local integration test strategy, dev deployment gates, and Swift-facing API surface. No Deno code in this document.

**Schema note:** Step 24 Rev 10 uses the term "challenge" throughout. V4 renamed every "challenge" to "case" at the database level. This document uses the V4 names exclusively. The Step 24 function contracts remain authoritative for behavior; only the identifiers change.

---

## Section 1 — What Is and Is Not in Scope

### In scope for Step 27

- Five Edge Functions: `upload-authorize`, `upload-complete`, `media-serve`, `scheduled-close`, `account-delete-complete`
- Two background workers: `upload-cleanup-worker`, `deletion-recovery-worker`
- Shared Deno module: auth gate, error envelope, admin client, logging

### Out of scope for Step 27

- Direct-RPC operations (guess submission, clue posting, group management, score reads, etc.) — these call database executor functions directly from the Swift client with no Edge Function required, per Step 24 §1.
- Push notifications (APNs) — deferred to a later step.
- Sign in with Apple provider configuration — auth provider setting, not an Edge Function.
- Moderation UI or moderator Edge Functions — moderators call `remove_content`, `report_content`, `approve_photo`, `reject_photo` via Direct RPC using the moderator's JWT.

---

## Section 2 — V4 Schema-to-Step-24 Name Mapping

All function catalog entries from Step 24 §2.7 remain authoritative. The identifier substitutions below apply throughout all Edge Function code.

| Step 24 name | V4 name |
|---|---|
| `challenge_id` | `case_id` |
| `public.challenges` | `public.cases` |
| `public.challenge_secrets` | `public.case_secrets` |
| `public.reveal_challenge_service_wrapper(uuid)` | `public.reveal_case_service_wrapper(uuid)` |
| `public.reserve_upload_session(challenge_id, ...)` | `public.reserve_upload_session(case_id, ...)` |
| Upload session `challenge_id` FK | `case_id` FK → `public.cases(id)` |

Functions not involving cases are unchanged: all `upload_sessions` lifecycle functions, `account_deletion` wrappers, deletion-recovery functions, media lookup, cleanup workers.

---

## Section 3 — Implementation Order

Each unit is independently testable before the next begins. No unit writes code for the next.

| Order | Unit | Rationale |
|---|---|---|
| 1 | Shared module | Every function depends on it; build once, test once |
| 2 | `upload-authorize` | First user-visible capability; unlocks upload testing end-to-end |
| 3 | `upload-complete` | Processes the object that `upload-authorize` authorized |
| 4 | `upload-cleanup-worker` | Needed before any stale session can accumulate |
| 5 | `media-serve` | Serves the display object produced by `upload-complete` |
| 6 | `scheduled-close` | No user JWT; simplest cron function |
| 7 | `account-delete-complete` | Most complex; requires all prior workers |
| 8 | `deletion-recovery-worker` | Guards against `account-delete-complete` partial failures |

Gate before each unit: local integration tests for the previous unit pass cleanly on `supabase db reset`. No unit is deployed to `forkensics-dev` until its local tests pass.

---

## Section 4 — Shared Module (`_shared/`)

All functions import from a single Deno module at `supabase/functions/_shared/`. It is never deployed as a standalone function.

### 4.1 Contents

**`auth.ts`**
- `verifyUserGate(req, supabaseAdmin)` — standard gate (Step 24 §3.1): extract `sub`, confirm `profiles` row with `is_active = true` and `onboarding_complete = true`, return `userId` or throw `FKError`.
- `verifyDeletionGate(req, supabaseAdmin)` — carve-out gate (§3.1): extract `sub`, confirm `profiles` row exists (any `is_active`), return `userId` or throw `FKError`.
- `verifyCronGate(req)` — compare `X-Forkensics-Cron-Secret` header to `CRON_SECRET` env using constant-time equality, throw `FKError` if absent or mismatched.

**`errors.ts`**
- `FKError` class: `{ code: string, httpStatus: number, message: string }`
- `errorResponse(e)` → `Response` with `Content-Type: application/json`, correct status, body `{ "error": { "code": "...", "message": "..." } }`.
- Standard code constants matching Step 24 §3.7 exactly.

**`clients.ts`**
- `adminClient()` → Supabase client using `SUPABASE_SERVICE_ROLE_KEY`. Used for all privileged database calls and storage operations.
- `userClient(jwt)` → Supabase client using the user's JWT. Used only for reads that should be RLS-scoped.

**`logging.ts`**
- `log(fn, event, fields)` — structured JSON log. Allowed fields: timestamp, function name, request ID, user UUID, case UUID, sanitized outcome/code. Denied fields: canonical dish/restaurant/city, storage paths, signed URLs, EXIF data, secrets, raw error messages, `case_secrets` contents. Violations are compile-time lint errors where possible, otherwise stripped at runtime.

**`storage.ts`**
- `presignPut(path, expiresInSeconds, contentType)` → `{ url: string, expiresAt: Date }` — generates S3 presigned PUT URL. Uses AWS SDK v3 `S3RequestPresigner` or Supabase Storage admin API. Expiry: 300 seconds (5 minutes).
- `deleteObject(path)` → `void` — idempotent, swallows 404.
- `getObject(path)` → `ReadableStream | null`.
- `reencode(stream, contentType)` → `{ webpStream: ReadableStream, detectedMime: string }` — strips EXIF/GPS, re-encodes to WebP using `@cf-media/image-transform` or equivalent Deno-compatible library. Raises `FK_PROCESSING_FAILED` if input is not a valid JPEG or WebP.

### 4.2 Environment Variables

| Variable | Used by | Source |
|---|---|---|
| `SUPABASE_URL` | All | Automatically injected |
| `SUPABASE_ANON_KEY` | All (gateway) | Automatically injected |
| `SUPABASE_SERVICE_ROLE_KEY` | All (admin client) | Supabase secret |
| `CRON_SECRET` | Workers, `scheduled-close` | Supabase secret |
| `AWS_REGION` | `storage.ts` presign | Supabase secret (or derived from project ref) |
| `AWS_ACCESS_KEY_ID` | `storage.ts` presign | Supabase secret |
| `AWS_SECRET_ACCESS_KEY` | `storage.ts` presign | Supabase secret |
| `STORAGE_BUCKET` | `storage.ts` | `game-media` |

`SUPABASE_DB_URL` is never used in any Edge Function (Step 24 §3.3).

---

## Section 5 — Per-Function Build Plans

### 5.1 `upload-authorize`

**Step 24 §4.1 is the behavioral contract.** This section adds implementation steps only.

**Build steps:**
1. Validate request body: `case_id` (UUID), `content_type` (`image/jpeg` | `image/webp`), `declared_size_bytes` (positive integer ≤ 10485760). Missing or invalid → `400 FK_INVALID_INPUT`.
2. Run `verifyUserGate`. Extract `userId`.
3. Generate `uploadToken` (32 random bytes, hex). Compute `tokenHash = SHA-256(uploadToken)`.
4. Call `reserve_upload_session(case_id, userId, tokenHash, content_type, declared_size_bytes, expiresAt)`. Map DB errors to HTTP: `FK_NOT_FOUND` → 404, `FK_WRONG_STATE` → 409, `FK_FORBIDDEN` → 403, `FK_UPLOAD_IN_PROGRESS` → 409.
5. Call `presignPut(original_storage_path, 300, content_type)` → `{ url, expiresAt }`.
6. If presign fails: call `fail_upload_session(session_id, 'FK_PROCESSING_FAILED')`. Return `500 FK_INTERNAL`. **Do not return the URL.**
7. Call `activate_upload_session(session_id, expiresAt)`. If this fails: call `fail_upload_session`. Return `500 FK_INTERNAL`. **Do not return the URL.**
8. Return `200`:
```json
{
  "session_id": "<uuid>",
  "upload_token": "<hex>",
  "upload_url": "<presigned PUT URL>",
  "upload_url_expires_at": "<ISO 8601>",
  "session_expires_at": "<ISO 8601>"
}
```

**What never appears in logs:** `upload_url`, `tokenHash`, `uploadToken`, `original_storage_path`.

---

### 5.2 `upload-complete`

**Step 24 §4.2 is the behavioral contract.**

**Build steps:**
1. Validate request body: `upload_token` (hex string). Missing → `400 FK_INVALID_INPUT`.
2. Run `verifyUserGate`. Extract `userId`.
3. Compute `tokenHash = SHA-256(upload_token)`. Call `resolve_upload_session(tokenHash, userId)`. If no row → `400 FK_INVALID_TOKEN`. If `status = 'complete'` → return `200 { "already_complete": true, "media_object_id": "...", "replaced_media_object_id": "..." | null }`. If `status` is `failed` / `expired` → `400 FK_INVALID_TOKEN`.
4. Call `advance_upload_session_processing(session_id, userId, '10 minutes')`. Maps: `FK_WRONG_STATE` → 409, `FK_NOT_FOUND` → 404.
5. Read original from storage at `original_storage_path`. If not found: call `fail_upload_session(session_id, 'FK_PROCESSING_FAILED')`. Return `422 FK_PROCESSING_FAILED`.
6. Verify actual file size ≤ 10 MB → else fail session, return `400 FK_FILE_TOO_LARGE`.
7. Verify actual MIME matches `session.content_type` → else fail session, return `400 FK_INVALID_CONTENT_TYPE`.
8. Call `reencode(stream, content_type)`. If fails: fail session, delete display if partially written, return `422 FK_PROCESSING_FAILED`.
9. Write WebP to `display_storage_path`. If write fails: fail session, return `422 FK_PROCESSING_FAILED`.
10. Delete `original_storage_path`. If delete fails: log warning, continue (original will be cleaned post-expiry by worker).
11. Call `advance_upload_session_sanitized(session_id)`. If fails: fail session, delete display object, return `500 FK_INTERNAL`.
12. Call `finalize_upload_session(session_id)` → `{ media_object_id, replaced_media_object_id }`. If fails: call `fail_upload_session`, delete display object, return `500 FK_INTERNAL`.
13. Return `200`:
```json
{
  "media_object_id": "<uuid>",
  "replaced_media_object_id": "<uuid>" | null,
  "already_complete": false
}
```

---

### 5.3 `upload-cleanup-worker`

**Step 24 §4.5 (worker spec) is the behavioral contract.**

**Build steps:**
1. Run `verifyCronGate`.
2. Call `claim_cleanup_sessions(worker_id, '15 minutes')` → array of sessions.
3. For each claimed session:
   - If `status = 'expired'` or `'failed'` and `storage_upload_expires_at IS NOT NULL`: delete `original_storage_path` (idempotent). Delete `display_storage_path` (idempotent, may not exist). Call `mark_session_cleaned(session_id, claim_token)`.
   - If `storage_upload_expires_at IS NULL`: no storage to delete. Call `mark_session_cleaned`.
4. Call `get_superseded_media_to_clean()`. For each: delete `re_encoded_storage_key`. Call `mark_superseded_media_cleaned(media_object_id)`.
5. For `complete` sessions with `original_path_post_expiry_cleaned = false` and `storage_upload_expires_at + 30s ≤ now()`: delete `original_storage_path` (idempotent). Call `mark_original_path_post_expiry_cleaned(session_id)`.
6. Return `200 { "cleaned": N, "superseded_cleaned": M }`.

**Scheduling:** Every 5 minutes via pg_cron + pg_net.

---

### 5.4 `media-serve`

**Step 24 §4.3 is the behavioral contract.**

**Build steps:**
1. Parse path: `GET /media-serve/:media_object_id`. Validate UUID format → else `400 FK_INVALID_INPUT`.
2. Run `verifyUserGate`. Extract `userId`.
3. Call `get_media_serve_authorization(media_object_id, userId)` — V4 SECURITY DEFINER function that checks the caller can view the case associated with this media object and returns `re_encoded_storage_key`. If no row → `404 FK_NOT_FOUND`.
4. Fetch object from private storage at `re_encoded_storage_key`. If not found → `404 FK_NOT_FOUND`.
5. Stream response with `Content-Type: image/webp`, `Cache-Control: private, max-age=3600`, `Content-Length` if known.

**No signed URL is returned.** The function proxies the bytes directly. The storage key never appears in the response or headers.

---

### 5.5 `scheduled-close`

**Step 24 §4.4 is the behavioral contract.**

**Build steps:**
1. Run `verifyCronGate`.
2. Query `public.cases` where `state = 'launched'` AND `deadline_at <= now()`. For each:
   - Call `reveal_case_service_wrapper(case_id)`. If fails with a known FK code: log and continue (do not abort the run). If fails with unexpected error: log and continue.
3. Return `200 { "revealed": N, "failed": M }`.

**Scheduling:** Every minute via pg_cron + pg_net. Re-entrant safe: `reveal_case_service_wrapper` is idempotent for already-revealed cases.

---

### 5.6 `account-delete-complete`

**Step 24 §4.5 is the behavioral contract.**

**Build steps:**
1. Run `verifyDeletionGate`. Extract `userId`. Validate `userId` present → else `401 FK_UNAUTHENTICATED`.
2. Call `prepare_account_deletion_wrapper(userId)`. If `database_prepared` or `auth_deleted` → continue. If fails → `500 FK_INTERNAL`.
3. Quiesce active upload sessions: call `quiesce_upload_sessions_for_deletion(userId)`. For each returned session with `prior_status = 'sanitized'`: delete `display_storage_path` (idempotent). For any `processing` session with active lease: wait for `blocking_lease_expires_at` (up to 10 minutes total budget), re-poll `get_upload_capability_expiry(userId)`.
4. Wait for all issued upload capabilities to expire: poll `get_upload_capability_expiry(userId)` every 30 seconds until NULL or until 15-minute timeout. If timeout: call `record_deletion_failure_wrapper(userId, 'FK_CAPABILITY_TIMEOUT')`. Return `202 { "status": "pending", "retry_after": 60 }`.
5. Gather and delete storage: call `get_all_upload_session_paths_for_deletion(userId)` and `get_deletion_storage_keys(userId)`. Delete all paths (idempotent). Call `mark_storage_cleaned_wrapper(userId)`.
6. Delete auth user: call Supabase Admin API `deleteUser(userId)`. If fails: call `record_deletion_failure_wrapper(userId, 'FK_AUTH_DELETE_FAILED')`. Return `500 FK_INTERNAL`.
7. Call `mark_auth_deleted_wrapper(userId)`.
8. Return `200 { "status": "complete" }`.

**Idempotency:** If the function is called again on a `database_prepared` record, it resumes from step 3. If called on an `auth_deleted` record, it resumes from step 5.

---

### 5.7 `deletion-recovery-worker`

**Step 24 §4.6 is the behavioral contract.**

**Build steps:**
1. Run `verifyCronGate`.
2. Call `claim_deletion_recovery_records(worker_id, '10 minutes', '10 minutes')` → array of `{ user_id, scan_type, claim_token }`.
3. For each:
   - If `scan_type = 'database_prepared'`: check `get_upload_capability_expiry(user_id)`. If not NULL: call `fail_deletion_recovery` with `FK_CAPABILITY_NOT_EXPIRED`. Continue.
   - Delete storage: call `get_all_upload_session_paths_for_deletion`, `get_deletion_storage_keys`. Delete all paths.
   - Call `mark_storage_cleaned_wrapper(user_id)`.
   - Delete auth user via Admin API.
   - Call `complete_deletion_recovery(user_id, claim_token, scan_type)`.
4. Return `200 { "recovered": N, "failed": M }`.

**Scheduling:** Every 10 minutes via pg_cron + pg_net.

---

## Section 6 — Local Integration Tests

### 6.1 Test environment

- `supabase start` with all four migrations applied.
- `supabase functions serve` with `--env-file .env.local` for secrets.
- `.env.local` is git-ignored. Contains only local dev values (never service-role key for production).
- Tests call the Edge Function HTTP endpoints directly using `fetch`.

### 6.2 Test structure

Each function gets a test file at `supabase/functions/<name>/tests/<name>.test.ts`. Tests use Deno's built-in `Deno.test` + `assertEquals`. No external test framework.

Each test file:
1. Inserts fixture rows directly into the local DB via the `postgres` role (using `PGPASSWORD` from env).
2. Calls the function endpoint.
3. Asserts response status and body.
4. Cleans up (or relies on `supabase db reset` between suites).

### 6.3 Required test cases per function

**`upload-authorize`:**
- Happy path: valid JWT + draft case → 200 with URL
- Missing JWT → 401
- Non-existent case → 404
- Case not in draft state → 409 `FK_WRONG_STATE`
- Active upload session already exists → 409 `FK_UPLOAD_IN_PROGRESS`
- Declared size > 10 MB → 400 `FK_INVALID_INPUT`

**`upload-complete`:**
- Happy path: valid token + stored JPEG → 200 with `media_object_id`
- Already complete (idempotent) → 200 with `already_complete: true`
- Invalid token → 400 `FK_INVALID_TOKEN`
- MIME mismatch → 400 `FK_INVALID_CONTENT_TYPE`
- File > 10 MB → 400 `FK_FILE_TOO_LARGE`
- Storage object absent → 422 `FK_PROCESSING_FAILED`

**`media-serve`:**
- Happy path: authorized caller + ready media → 200 stream
- Unauthorized caller → 404
- Non-existent media → 404

**`scheduled-close`:**
- Happy path: one launched + past-deadline case → revealed after run
- Already-revealed case → idempotent, no error
- Missing cron secret → 401

**`account-delete-complete`:**
- Happy path: no active sessions → storage deleted, auth user deleted, 200
- Active processing lease → 202 with `retry_after`
- Idempotent resume from `database_prepared` → completes

**`upload-cleanup-worker`:**
- Stale pending session → transitions to expired, storage deleted, `cleaned`
- Failed session with NULL `storage_upload_expires_at` → `cleaned` immediately (no URL expiry gate)
- `complete` session original-path post-expiry cleanup

**`deletion-recovery-worker`:**
- `database_prepared` record with expired capability → storage deleted, auth deleted, recovered
- `auth_deleted` record → storage deleted, recovered

### 6.4 Integration test runner

```bash
supabase/functions/tests/run_integration_tests.sh
```

Runs `supabase db reset`, then `deno test --allow-all` across all test files. Exits non-zero on any failure. Log written to `functions_integration_<timestamp>.log` (git-ignored).

---

## Section 7 — Dev Deployment Gates

A function is deployed to `forkensics-dev` only after ALL of the following pass for that function unit:

1. **Local integration tests pass** on a fresh `supabase db reset` with the current V4 schema.
2. **`bash -n` syntax check** on all TypeScript files (via `deno check`).
3. **No secrets in source**: `git log --all -p | grep -i 'service_role\|secret\|password'` returns no hits for new lines.
4. **Governance approval**: Bill explicitly types `APPROVED: deploy <function-name> to forkensics-dev`. No implicit approval.
5. **Post-deploy smoke test**: after deployment, call the function endpoint once with a valid fixture and verify the response shape. If the smoke test fails, roll back (`supabase functions delete <name> --project-ref <ref>`).

No function is deployed to production (Supabase cloud outside forkensics-dev) within scope of Step 27.

---

## Section 8 — Swift-Facing API Surface

These are the HTTP contracts the iOS app calls. All endpoints are under `https://<project-ref>.supabase.co/functions/v1/`.

### 8.1 `POST /upload-authorize`

**Headers:** `Authorization: Bearer <user JWT>`, `Content-Type: application/json`

**Request:**
```json
{ "case_id": "uuid", "content_type": "image/jpeg", "declared_size_bytes": 1048576 }
```

**Response 200:**
```json
{
  "session_id": "uuid",
  "upload_token": "64-hex-char string",
  "upload_url": "https://...",
  "upload_url_expires_at": "2026-08-12T20:30:00Z",
  "session_expires_at": "2026-08-12T20:35:00Z"
}
```

**Swift usage:** Store `upload_token` in memory (never persist). PUT the file bytes directly to `upload_url` with the declared `Content-Type`. Call `upload-complete` after the PUT succeeds.

---

### 8.2 `POST /upload-complete`

**Headers:** `Authorization: Bearer <user JWT>`, `Content-Type: application/json`

**Request:**
```json
{ "upload_token": "64-hex-char string" }
```

**Response 200:**
```json
{
  "media_object_id": "uuid",
  "replaced_media_object_id": "uuid" | null,
  "already_complete": false
}
```

**Swift usage:** Call after a successful PUT to `upload_url`. If `replaced_media_object_id` is non-null, the old draft photo is gone — update local state accordingly.

---

### 8.3 `GET /media-serve/:media_object_id`

**Headers:** `Authorization: Bearer <user JWT>`

**Response 200:** Raw WebP bytes, `Content-Type: image/webp`, `Cache-Control: private, max-age=3600`

**Swift usage:** Use as an image URL with `URLSession` and the user's JWT in the `Authorization` header. Cache locally using `URLCache` with `private` cache policy. The `media_object_id` is the cache key.

---

### 8.4 `POST /account-delete-complete`

**Headers:** `Authorization: Bearer <user JWT>`, `Content-Type: application/json`

**Request:** `{}` (empty body; user is identified by JWT `sub`)

**Response 200:**
```json
{ "status": "complete" }
```

**Response 202** (upload capability not yet expired):
```json
{ "status": "pending", "retry_after": 60 }
```

**Swift usage:** Call after confirming with the user. On 202, wait `retry_after` seconds and retry. On 200, sign out locally and present account-deleted confirmation screen.

---

### 8.5 Direct-RPC operations (no Edge Function)

The Swift client calls these directly using the Supabase Swift SDK's `.rpc()` or authenticated `.from().insert()` methods. No custom endpoint required.

| Operation | SDK call |
|---|---|
| Submit guess | `supabase.from("guess_attempts").insert(...)` |
| Add clue | `supabase.from("clues").insert(...)` |
| Post comment | `supabase.from("comments").insert(...)` |
| Report content | `supabase.rpc("report_content", ...)` |
| Cancel case | `supabase.rpc("cancel_case", ...)` |
| Create group | `supabase.rpc("create_group", ...)` |
| Group invites | `supabase.rpc("create_group_invite", ...)` / `.rpc("redeem_group_invite", ...)` |
| Score/leaderboard | `supabase.from("current_score_events").select(...)` |
| Profile reads | `supabase.from("profiles").select(...)` |

---

## Section 9 — Open Questions for Codex Review

The following questions must be resolved before or during approval:

1. **Re-encoding library:** Which Deno-compatible EXIF-stripping + WebP re-encoding library is approved? Options: `@cf-media/image-transform` (Cloudflare Workers compatible, may work in Deno Deploy), native `ImageMagick` Deno binding, or a WASM-based library. This choice affects `storage.ts` in the shared module.

2. **Presigned URL generation:** Does the `forkensics-dev` Supabase Storage instance support S3-compatible presigned PUTs via `@aws-sdk/s3-request-presigner`? Or should `supabase.storage.from(bucket).createSignedUploadUrl()` be used instead? Step 24 Rev 10 §2.4 removed the assumption about non-overwrite conditional behavior but left the presign mechanism open.

3. **pg_cron + pg_net availability:** Are `pg_cron` and `pg_net` enabled on `forkensics-dev`? If not, `scheduled-close` and the two workers require a scheduled job via an external cron (e.g., GitHub Actions `schedule`) hitting the function endpoints directly with `CRON_SECRET`.

4. **`get_media_serve_authorization` signature:** V4 defines `public.get_media_serve_authorization(media_object_id uuid, viewer_id uuid)`. Confirm the function checks `can_view_case` (investigation membership or case poster) for the case linked to this media object, and returns `re_encoded_storage_key` if authorized. The Step 27 `media-serve` implementation depends on this contract.

---

## Section 10 — Approval Block

**For Codex:** Please verify:
- Section 2 name mapping is complete and consistent with V4 `20260807000003`.
- Section 5 build steps do not deviate from Step 24 §4 behavioral contracts.
- Open Questions (Section 9) are either answered or explicitly deferred with reasoning.
- No security regression versus Step 24 §3 cross-cutting contracts.

**For Bill:** Please confirm implementation order (Section 3) and that the Swift-facing API surface (Section 8) matches your integration expectations.

Approval phrase: `APPROVED: Step 27 Rev 1 — Edge Function Implementation Plan`
