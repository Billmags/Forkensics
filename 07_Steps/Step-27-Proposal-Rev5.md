# Step 27 Proposal — Rev 5 — Edge Function Implementation Plan

**Status:** APPROVED — 2026-08-12

**Governance gate:** All three parties (Bill + Claude + Codex) must approve before any TypeScript code is written. The magic words are `APPROVED: Step 27 Rev 5 — Edge Function Implementation Plan`.

**Supersedes:** Step 27 Rev 4 (rejected — 2 blockers)

**Rev 5 changes from Rev 4:**
1. Gate 2B sequencing made authoritative: if Phase A passes, Gate 2B must be approved and passed before Step B (upload-complete) TypeScript implementation begins — not merely before deployment. Section 4 diagram updated to reflect this hard sequencing dependency.
2. Finalization error mapping in §5.2 corrected: re-resolve-after-error now branches on the original error code when session is still `sanitized` — `FK_INVALID_HASH` → `422`, `FK_WRONG_STATE` (case not draft) → `409`, transport/unknown → `500`. The "response lost" test is clarified: the transport exception and re-resolve occur within the same function invocation, not on a subsequent call.

---

## Section 1 — Scope and Authorization Chain

### 1.1 What This Step Covers

This step defines the implementation plan for all Edge Functions described in Step 24. It does not write TypeScript — it defines the pre-implementation gates, per-function build order, local test requirements, deployment gates, and Swift API surface so that implementation can proceed one function at a time.

Step 24 Rev 10 is the binding contract. This step translates it into a verified implementation sequence that accounts for all V4 schema divergences from V3.

### 1.2 What This Step Does Not Cover

- No TypeScript code is written until this plan is approved.
- No Supabase cloud operations until the relevant function step is approved separately.
- Moderation functions (`approve_photo`, `reject_photo`, `remove_content`, `remove_media`) are service_role-only in V4 and require a dedicated Edge Function. That function (`moderation-action`) is **deferred** — see Section 5.8.
- V2 migration functions are defined in Step 24 §2.7 and Step 25. This step assumes V2 migration is applied and tested before any Edge Function is deployed.

### 1.3 Security Constraints (Carried Forward — Immutable)

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

| Step 24 term / contract | V4 actual | Impact on Edge Functions |
|---|---|---|
| `public.challenges` table | `public.cases` table | All queries, RLS references |
| `challenge_id` parameter | `case_id` parameter | All RPC calls |
| `challenge_id` FK column | `case_id` FK column | `private.upload_sessions` V2 schema |
| `public.lock_challenge(uuid)` | `public.lock_case(uuid)` | `scheduled-close` Pass 1 |
| `public.reveal_challenge_service_wrapper(uuid)` | `public.reveal_case_service_wrapper(uuid)` | `scheduled-close` Pass 2 |
| `state = 'active'` (V3) | `state = 'launched'` (V4) | `scheduled-close` query filter |
| `finalize_upload_session(session_id uuid)` — one arg; media `status = 'ready'` | `finalize_upload_session(session_id uuid, sha256_hash text)` — two args; media `status = 'pending_review'` | SHA-256 computation required; response field changes |
| `upload-complete` 200: `"status": "ready"` | `"status": "pending_review"` | Swift must not assume media is immediately servable |
| `media-serve GET /media/{challenge_id}` | `POST /media-serve` via `functions.invoke` with `{ "case_id": "<uuid>" }` body; binary WebP returned | See §5.4 and §9.1 |
| `get_media_storage_key(media_object_id)` — status check only | `get_media_serve_authorization(media_object_id, viewer_id)` — status + case visibility + `moderator_removed_at`; service_role only | Pending-review media returns 404 |
| `submit_guess`: direct authenticated INSERT | `supabase.rpc("submit_guess", { p_case_id, p_investigation_id, p_race, p_guess_text, p_idempotency_key, p_client_submitted_at })` | Direct INSERT revoked in V4 |
| `activate_challenge(uuid)` — V3 | `launch_case(p_case_id, p_actor_id, p_group_ids, p_duration_seconds)` — V4 | Different name, different signature |
| `reveal_challenge(uuid)` — V3 | `reveal_case(p_case_id uuid)` — V4; authenticated; poster only; requires `state = 'locked'` | Verified at V4 line 2625; grant at line 3269 |
| `cancel_challenge(uuid, text)` — V3 | `cancel_case(p_case_id uuid, p_reason text)` — V4; authenticated; poster only; valid in `draft`, `ready`, `launched` | Verified at V4 line 2720; grant at line 3267 |
| `approve_photo`, `reject_photo`, `remove_content`, `remove_media` | V4: service_role ONLY | Requires `moderation-action` Edge Function; deferred (§5.8) |
| `report_content` | V4: authenticated-callable (confirmed) | No change needed |

**Hard constraint:** After `finalize_upload_session`, media is `pending_review`. `moderation-action` is a hard prerequisite for end-to-end gameplay — see Section 5.8.

---

## Section 3 — Pre-Implementation Gates

### Gate 1 — V2 Migration Applied and Tested

`V2__upload_sessions.sql` applied, committed, and V2 acceptance test suite passing (Steps 25/26 complete).

### Gate 2 — Image Processing Spike (Hard Gate — Two Phases)

**Required before implementing `upload-complete`.**

**Memory budget context:** Supabase Edge Functions have a 256 MB memory limit. A decoded RGBA image consumes 4 bytes per pixel. At 256 MB budget (before WASM overhead, decode buffers, output buffer, and runtime overhead), the theoretical raw-pixel ceiling is approximately 64 MP. With processing overhead, the practical safe limit is materially lower. The spike must establish the canonical limit experimentally, not theoretically.

**WASM packaging constraint:** `magick-wasm` requires its `.wasm` binary to be bundled as a static file. This imposes the following mandatory requirements:

- `supabase/config.toml` must include `static_files = ["./functions/upload-complete/magick-wasm/..."]` (or equivalent glob).
- Supabase CLI must be version 2.7.0 or higher.
- Deployment **cannot** use the `--use-api` flag. The function **must** be deployed via Docker/CLI. API-based deployment does not support `static_files`.

These constraints must be confirmed in Gate 2 Phase A before any implementation work begins.

**Phase A — Local functional testing (no cloud approval required):**

Create `tools/image-spike/run.ts` (standalone Deno script). For each test input:

*Dimension and file-size test matrix:*
- 5 MB JPEG, normal dimensions (e.g., 3000×2000)
- 10 MB JPEG, normal dimensions
- 10 MB JPEG, high pixel count (e.g., 8000×5000 — large pixels, moderate file)
- Synthetic PNG-bomb analog: small compressed file, extreme pixel count (e.g., 16000×16000 if magick-wasm can open it; reject expected)
- 5 MB WebP

Tests must vary both compressed file size and decoded pixel count independently. A file within the 10 MB compressed limit can have extreme pixel dimensions — this is the decompression-bomb attack vector.

*Per-input pipeline:*
1. Parse image header to extract width × height without full raster decode. Compute pixel count.
2. If pixel count exceeds the **pre-decode safe limit** (established by Phase A memory measurements; the spike must determine this value) → reject; log dimensions and pixel count; do not decode. This check must occur before any raster decode to prevent decompression exhaustion.
3. Full raster decode of images that pass step 2.
4. Re-encode to WebP.
5. Strip metadata: verify structural removal of EXIF, GPS, ICC, XMP, IPTC, comments, and all other embedded profiles. Verification must parse the output WebP binary and confirm no metadata blocks remain — not rely on default behavior.
6. Compute SHA-256 of output WebP bytes.
7. Measure: CPU time, memory peak (from Deno metrics), wall-clock time.

*Additional Phase A measurements:*
- Bundle size of the Edge Function when `magick-wasm` is included. Must be below 20 MB (local) and ideally below 5 MB server-side (Supabase's hosted warning threshold).
- Confirm `static_files` config works with local `supabase start`.
- Confirm CLI version ≥ 2.7.0.

*Phase A verdict output:* `tools/image-spike/results.md` must record:
- Canonical max pixel count (pre-decode rejection threshold)
- Canonical max width and height (if asymmetric limits are needed)
- Peak memory at the canonical limit
- Bundle size
- Whether Supabase's 5 MB server-bundled warning applies
- Packaging method confirmed (static_files, Docker/CLI deploy)

If Phase A fails (bundle > 20 MB, pipeline errors at 10 MB, or memory budget exceeded) → decision point: enforce 5 MB limit or identify alternative compute path. No `upload-complete` implementation proceeds without a written Phase A verdict.

**Phase B — Hosted runtime validation (separate explicit cloud approval required — hard sequencing gate):**

**If Phase A passes, Gate 2B must be approved and passed before Step B (`upload-complete`) TypeScript implementation begins.** This is not a deployment-only gate. The implementation may not start until the hosted runtime has validated the canonical pixel and resource limits established in Phase A.

Rationale: Supabase specifically warns that complex image processing above 5 MB can exceed hosted resource limits. A local Phase A passing does not guarantee the hosted 256 MB memory and CPU envelope will accept the same limits. Building `upload-complete` TypeScript against a pixel limit that Phase B later rejects forces a code change, a new approval cycle, and potential re-testing.

Phase B deploys a disposable hosted spike function to forkensics-dev and measures actual hosted-runtime memory and CPU for the canonical limits from Phase A. Phase B requires its own three-party approval. It is NOT authorized under this step.

### Gate 3 — Cron Preflight (Fully Local)

The preflight must be entirely local. A pg_cron job in forkensics-dev cannot reach a `localhost` echo server on the developer's machine.

1. Confirm `pg_cron` enabled in local Supabase instance (`supabase start`).
2. Confirm `pg_net` enabled.
3. Start a local HTTP echo server on a port reachable from the local Supabase Docker network (use the Docker host gateway IP — typically `172.17.0.1` or equivalent — not `127.0.0.1`).
4. Register a test cron job via `pg_cron` that fires a `pg_net` HTTP POST to the Docker-accessible address.
5. Confirm request received at echo server within expected interval.
6. Remove the test job.

Results documented in evidence log. Hosted forkensics-dev pg_cron validation is a separate future step requiring cloud approval.

### Gate 4 — S3 Connection and Environment Variables

**Production environment variable contract:**

| Variable | Description |
|---|---|
| `SUPABASE_URL` | Project URL |
| `SUPABASE_SERVICE_ROLE_KEY` | Service role key (never in repo; injected at deploy) |
| `CRON_SECRET` | Cron authentication secret (≥256 bits; never in repo) |
| `S3_ENDPOINT` | `https://<project-ref>.storage.supabase.co/storage/v1/s3` (use `.storage.` hostname for large-file performance) |
| `S3_REGION` | As shown in Storage → S3 configuration in Supabase dashboard |
| `S3_ACCESS_KEY_ID` | Generated S3 access key ID from dashboard (not anon key; not in repo) |
| `S3_SECRET_ACCESS_KEY` | Generated S3 secret key from dashboard (never in repo; injected at deploy) |
| `S3_BUCKET` | `game-media` |

Path-style addressing (`forcePathStyle: true`) is required for all S3 operations.

**Local development values (from Supabase documentation):**

| Variable | Local value |
|---|---|
| `S3_REGION` | `local` |
| `S3_ENDPOINT` | `http://127.0.0.1:54321/storage/v1/s3` |
| `S3_ACCESS_KEY_ID` | `stub` |
| `S3_SECRET_ACCESS_KEY` | Value of `ANON_KEY` from `supabase status -o env` |

Local values are set in `supabase/functions/.env` (git-ignored). `S3_SECRET_ACCESS_KEY` is never stored in any committed file; developers obtain it at runtime via `supabase status -o env`.

**Preflight test:**
1. Configure local S3 env vars as above.
2. Sign a presigned PUT URL for `game-media/preflight-test/object.bin` using S3 Signature V4, `ExpiresIn: 300`.
3. Upload a zero-byte object via the signed URL (`curl -X PUT --data-binary "" <url>` or equivalent empty-body PUT).
4. Confirm the object appears in the `game-media` bucket via the service-role client.
5. Delete the object. Confirm deletion.

`createSignedUploadUrl()` is prohibited everywhere — it produces 2-hour URLs. Only S3 Signature V4 with `ExpiresIn: 300` is permitted.

### Gate 5 — Deno Toolchain Installation and Smoke Validation

Runs before any scaffold is created. Verifies toolchain is present:

```sh
deno --version               # must print a version
deno eval "console.log('ok')" # must print ok
gitleaks version             # must print a version
```

After each function scaffold (index.ts + imports) is created:
- `deno check supabase/functions/<fn>/index.ts` — zero errors
- `deno fmt --check supabase/functions/<fn>/index.ts` — zero diff
- `deno lint supabase/functions/<fn>/index.ts` — zero warnings

### Gate 6 — Dependency Lockfile

Generated after first function scaffold:
```sh
deno cache --lock=deno.lock supabase/functions/<fn>/index.ts
```

All import specifiers must pin exact versions. `deno.lock` regenerated and re-committed on any import change.

---

## Section 4 — Implementation Order

```
Gate 1 (V2 migration)
Gate 2A (magick-wasm local spike) ────────────────────────────────────────────────────────┐
Gate 3 (pg_cron local preflight)                                                          │
Gate 4 (S3 env vars + preflight)                                                          │
Gate 5 (Deno installation smoke)                                                          │
         │                                                            Phase A verdict      │
         ▼                                                                  │              │
Step A: upload-authorize → Gate 6 (lockfile)          Gate 2B (hosted spike, separate     │
                                                       cloud approval) ◄──────────────────┘
                                                                │
                                                                │ Phase B passing verdict
                                                                ▼
Step B: upload-complete ◄───────────────────────────────────────
Step C: upload-cleanup-worker (deploy simultaneously with B)
Step D: media-serve
Step E: scheduled-close
Step F: account-delete-complete
Step G: deletion-recovery-worker (deploy simultaneously with F)
Step H: moderation-action [DEFERRED — see §5.8]
```

**Rule:** Step B TypeScript implementation does not begin until Gate 2B produces a passing verdict with its own three-party approval. Step A is independent and may proceed while Gate 2B approval is sought.

---

## Section 5 — Per-Function Build Plans

### 5.1 `upload-authorize`

**Contract:** Step 24 §4.1 (identifier substitutions only).

**Response (from Step 24 §4.1):**
```json
{ "presigned_url": "<url>", "upload_token": "<secret token>", "expires_at": "<ISO 8601>" }
```
`session_id`, storage paths, and `storage_upload_expires_at` are internal — never returned.

**Presigned URL:** S3 Signature V4, `ExpiresIn: 300`.

**Authentication pattern:** `createSupabaseContext(req, { auth: 'user' })`. If error → `401 FK_UNAUTHENTICATED`. `ctx.userClaims.id` is the verified user ID. Profile check (active, onboarding complete) follows after verified identity is established. Raw JWT decoding is prohibited.

**Local tests (required):**
- Valid request → 200 with correct response shape; `session_id` absent from response.
- Non-draft case → 409 `FK_WRONG_STATE`.
- Non-poster → 404 `FK_NOT_FOUND`.
- Duplicate active session → 409 `FK_UPLOAD_IN_PROGRESS`.
- Uploader with `database_prepared` deletion record → 403 `FK_FORBIDDEN`.
- Missing / invalid JWT → 401; inactive profile → 403.
- `declared_size_bytes` > 10,485,760 → 400 `FK_FILE_TOO_LARGE`.
- Invalid `content_type` → 400 `FK_INVALID_CONTENT_TYPE`.
- URL activation failure → 500 `FK_INTERNAL`; URL not returned; `fail_upload_session` called.
- Step 24 Rev 10 §5.1 mandatory tests (V4 identifier substitutions applied).

---

### 5.2 `upload-complete`

**Contract:** Step 24 §4.2 with V4 corrections. Step 24 Rev 10 §5.1 test requirements mandatory.

**Authentication pattern:** `createSupabaseContext(req, { auth: 'user' })`.

**V4 corrections:**
- `finalize_upload_session(session_id, sha256_hash)` — two-arg signature.
- Media created as `pending_review`.
- Response 200: `"status": "pending_review"`.

**Idempotency branch:**
- `complete` → `200 {"status":"pending_review","media_object_id":"<uuid>","replaced_media_object_id":"<uuid or null>","already_complete":true}`.
- `processing` → `202 {"status":"processing"}`.
- `sanitized` → skip to sanitized re-entry (below).
- `pending` → proceed to happy path.
- Other → `400 FK_INVALID_TOKEN`.

**Happy path (status `pending`):**

1. `advance_upload_session_processing(session_id, user_id, '10 minutes')`. Failure → `400 FK_INVALID_TOKEN`.
2. Read original from `session.original_storage_path`. Absent → `fail_upload_session('FK_NOT_FOUND')`; `404`.
3. Sniff MIME; confirm matches `session.content_type`. Failure → delete original; `fail_upload_session('FK_INVALID_CONTENT_TYPE')`; `400`.
4. Confirm actual size ≤ 10,485,760. Failure → delete original; `fail_upload_session('FK_FILE_TOO_LARGE')`; `400`.
5. Parse header for width × height. If pixel count exceeds the canonical pre-decode limit established in Gate 2 → delete original; `fail_upload_session('FK_PROCESSING_FAILED')`; `422`. No full decode on images that fail this check.
6. Re-encode to WebP; strip all EXIF, GPS, ICC, XMP, IPTC, comments, and embedded profiles. Failure → delete original; `fail_upload_session('FK_PROCESSING_FAILED')`; `422`.
6.5. `check_upload_session_lease(session_id)`. False → delete original; `422 FK_PROCESSING_FAILED`. Do NOT call `fail_upload_session`. Do NOT write display.
7. Write re-encoded WebP to `session.display_storage_path`. Failure → delete original; `fail_upload_session('FK_PROCESSING_FAILED')`; `422`.
8. Delete original. Retry up to 2 times. All fail → delete display; `fail_upload_session('FK_PROCESSING_FAILED')`; `422`.
9. `advance_upload_session_sanitized(session_id)`.

   **Step 9 RPC-error handling:** RPC may have committed while the client received an error. After any error from step 9, re-resolve the session:
   - Resolved `sanitized` → display intact; fall through to sanitized re-entry.
   - Resolved `complete` → finalization already committed; return `200` idempotent.
   - Resolved `processing` (RPC did not commit) → delete display; `fail_upload_session('FK_INTERNAL')`; `500`.
   - Other state or no row → delete display; `500 FK_INTERNAL`.

**Finalization — happy path (entering from step 9 success):**

10. Compute SHA-256 of the in-memory WebP buffer from step 6 (lowercase hex, 64 chars).
11. Call `finalize_upload_session(session_id, sha256_hash)`.

   **Finalization error handling:** If `finalize_upload_session` raises, capture the original error code, then re-resolve the session:
   - Resolved `complete` → finalization committed despite the error; return `200` idempotent.
   - Resolved `sanitized` → finalization did not commit; map the original error code:
     - `FK_INVALID_HASH` → return `422 FK_PROCESSING_FAILED`.
     - `FK_WRONG_STATE` (case is not `draft`) → return `409 FK_WRONG_STATE`.
     - Transport error, timeout, or unknown error → return `500 FK_INTERNAL`; client retries via sanitized branch.
   - Other state or no row → fail-closed `500 FK_INTERNAL`.

12. Return `200 {"media_object_id":"<uuid>","status":"pending_review"}`.

**Sanitized re-entry (new invocation — no in-memory buffer):**

On re-entry from the `sanitized` idempotency branch, there is no in-memory WebP buffer — the prior invocation ended. SHA-256 must be derived from storage.

13. Download `session.display_storage_path`. Absent → `fail_upload_session('FK_PROCESSING_FAILED')`; `422`.
14. Verify bytes are valid WebP. Invalid → delete display; `fail_upload_session('FK_PROCESSING_FAILED')`; `422`.
15. Compute SHA-256 of downloaded bytes (lowercase hex, 64 chars).
16. Call `finalize_upload_session(session_id, sha256_hash)`. Apply the same finalization error handling as step 11 above: capture original error; re-resolve; `complete` → 200 idempotent; `sanitized` → map `FK_INVALID_HASH` → 422, `FK_WRONG_STATE` → 409, unknown → 500; other → 500.
17. Return `200 {"media_object_id":"<uuid>","status":"pending_review"}`.

**Local tests (required):**
- Full happy path → 200, `status = "pending_review"`.
- Idempotent `complete` on entry → 200 `already_complete: true`.
- `processing` on entry → 202.
- Sanitized re-entry: valid display in storage → hash computed from storage; finalization succeeds → 200.
- Sanitized re-entry: display absent → 422.
- Sanitized re-entry: display present but invalid WebP → display deleted; session failed; 422.
- Lease expiry (step 6.5) → 422; no `fail_upload_session`; no display written.
- Original deletion failure (2 retries) → display deleted; session failed; 422.
- Step 9 error: re-resolve `sanitized` → sanitized re-entry path; no double-fail.
- Step 9 error: re-resolve `processing` → display deleted; `fail_upload_session`; 500.
- **Finalization commits but response is lost (within same invocation):** Simulate: finalization commits on server; adapter throws a transport exception within the same invocation; that same invocation captures the error, re-resolves → `complete`; returns `200` idempotent. This is not a subsequent call — the error-handling branch and re-resolve occur inside the same function execution.
- `FK_INVALID_HASH` from DB → re-resolve → `sanitized` → `422 FK_PROCESSING_FAILED`.
- `FK_WRONG_STATE` (case not draft) from DB → re-resolve → `sanitized` → `409 FK_WRONG_STATE`.
- Transport error from finalization → re-resolve → `complete` → `200` idempotent.
- Transport error from finalization → re-resolve → `sanitized` → `500 FK_INTERNAL`; client retries via sanitized branch.
- Invalid / expired / failed token → 400 `FK_INVALID_TOKEN`.
- Pre-decode pixel limit exceeded → 422; no full decode attempted.
- Step 24 Rev 10 §5.1 mandatory tests (V4 identifier substitutions applied).

---

### 5.3 `upload-cleanup-worker`

**Contract:** Step 24 §4.6 with V4 corrections.

**Authentication pattern:** `withSupabase({ auth: 'none' }, ...)` + manual constant-time `X-Forkensics-Cron-Secret` check.

**V4 corrections:**
- Part 3 uses `get_complete_sessions_pending_expiry_cleanup()` (confirmed V2 schema line 928).
- NULL-expiry sessions included (no URL-expiry gate); delete `original_storage_path` as precaution.
- `mark_session_cleaned` only called if all storage deletions for that session succeed.

**Part 1 — upload session cleanup:**
1. `claim_cleanup_sessions(worker_id, '15 minutes')`.
2. For each: delete `original_storage_path` and `display_storage_path` (absent = no-op). All succeed → `mark_session_cleaned(session_id, cleanup_claim_token)`. Any fail → log; do not mark; retry next run.

**Part 2 — superseded media:**
1. `get_superseded_media_to_clean()`. For each: delete `re_encoded_storage_key`. Success → `mark_superseded_media_cleaned`. Failure → log; retry.

**Part 3 — post-expiry original-path cleanup:**
1. `get_complete_sessions_pending_expiry_cleanup()`.
2. Attempt delete of `original_storage_path`. Absent = no-op.
3. Succeeded or absent → `mark_original_path_post_expiry_cleaned(session_id)`.
4. Failed and present → log; do NOT mark; retry next run.

**Deployment:** Simultaneously with `upload-complete`.

---

### 5.4 `media-serve`

**Contract:** Step 24 §4.3 with V4 corrections.

**Authentication pattern:** `createSupabaseContext(req, { auth: 'user' })`.

**HTTP contract (authoritative):** `POST /media-serve` via `functions.invoke`. `case_id` in JSON body. Binary WebP bytes returned. No GET path-parameter form.

**V4 authorization:** `get_media_serve_authorization(media_object_id, user_id)` via service_role client (not `get_media_storage_key`). Requires `mo.status = 'ready'`, `c.moderator_removed_at IS NULL`, `can_viewer_access_case`. No result → `404 FK_NOT_FOUND`.

**Full action sequence:**
1. `createSupabaseContext(req, { auth: 'user' })`. Error → 401.
2. Parse `case_id` from body. Missing/malformed → `400 FK_INVALID_INPUT`.
3. Query `public.cases WHERE id = case_id` via user-JWT client. No row → `404 FK_NOT_FOUND`.
4. `media_object_id` null → `404 FK_NOT_FOUND`.
5. `get_media_serve_authorization(media_object_id, user_id)` via service_role client. No result → `404 FK_NOT_FOUND`.
6. Read file at returned storage key from `game-media`.
7. Return binary bytes: `Content-Type: image/webp`, `Cache-Control: private, max-age=3600`.

**Local tests (required):**
- Authorized viewer, `ready` media → 200 WebP bytes.
- `pending_review` media → 404.
- Moderator-removed case → 404.
- Viewer not in group → 404.
- No media attached → 404.
- Missing JWT → 401; missing `case_id` → 400.
- Step 24 Rev 10 §5.1 mandatory tests (V4 identifier substitutions applied).

---

### 5.5 `scheduled-close`

**Contract:** Step 24 §4.4 with V4 corrections.

**Authentication pattern:** `withSupabase({ auth: 'none' }, ...)` + manual constant-time `X-Forkensics-Cron-Secret` check inside the handler.

**V4 corrections:**
- Pass 1 query: `WHERE state = 'launched' AND deadline_at <= now()`.
- Pass 1 call: `lock_case(p_case_id)`.
- Pass 2 query: `WHERE state = 'locked'`.
- Pass 2 call: `reveal_case_service_wrapper(p_case_id)`.

**Concurrent worker race specification:**

`reveal_case_service_wrapper` is **not idempotent** on already-revealed cases. It internally requires `state = 'locked'` and raises an error if the case has already been revealed (state is `revealed`, not `locked`). This is not a data corruption risk — a case can only be revealed once — but concurrent cron invocations can race on Pass 2.

Specified behavior when two workers overlap on Pass 2:
- The winner calls `reveal_case_service_wrapper` first. Scoring executes once. Case transitions to `revealed`.
- The loser subsequently calls `reveal_case_service_wrapper` on the same case. The DB function raises because `state != 'locked'`. This error is a **known catchable outcome**.
- The loser catches the error, inspects the error code, determines it is the known `FK_INVALID_INPUT` / wrong-state error, and classifies the case as **skipped** (not a failure). It does NOT log this as an error.
- The response counts this case in `skipped_count`, not `errors`.

Exactly one scoring execution is guaranteed by the DB-level lock inside `reveal_case_service_wrapper`.

**Local concurrency test (required):**
- Spin two concurrent invocations of `scheduled-close` with a `locked` case in scope.
- Assert: exactly one `revealed` state transition occurs.
- Assert: no duplicate `score_events` or `investigation` state changes.
- Assert: the loser invocation produces `skipped_count: 1` (not an error entry).

**Schedule:** Every 2 minutes.

**Response `200 OK`:**
```json
{ "locked_count": 0, "revealed_count": 0, "skipped_count": 0, "errors": [] }
```

**Local tests (required):**
- `launched` case past deadline → locked.
- `locked` case → revealed.
- Two-run scenario: Pass 1 locks, Pass 2 reveals; next run skips both.
- Per-row error in Pass 1 → logged; Pass 2 still runs.
- Concurrent invocations → exactly one reveal; loser shows skipped (see concurrent test above).
- Wrong / missing cron secret → 401.
- Step 24 Rev 10 §5.1 mandatory tests (V4 identifier substitutions applied).

---

### 5.6 `account-delete-complete`

**Contract:** Step 24 §4.5.

**Authentication pattern:** `createSupabaseContext(req, { auth: 'user' })`. Error → 401. Profile existence check: row must exist; `is_active` and `onboarding_complete` are NOT checked (deletion carveout). `ctx.userClaims.id` is the verified user ID.

**Critical ordering:** `mark_auth_deleted_wrapper` called BEFORE `mark_storage_cleaned_wrapper`. No waiting in function — returns 409 immediately if URL capability is live.

**Full sequence (Step 24 §4.5):**
1. `prepare_account_deletion_wrapper(user_id)` → `database_prepared`: continue. `auth_deleted` → `409 FK_WRONG_STATE`. `complete` → log anomaly + `500`.
2. `quiesce_upload_sessions_for_deletion`. Any `blocking_lease_expires_at IS NOT NULL` → `409 FK_UPLOAD_IN_PROGRESS`; return immediately.
3. `get_upload_capability_expiry`. Non-NULL → `409 FK_UPLOAD_IN_PROGRESS` with `retry_after`; return immediately.
4. `get_all_upload_session_paths_for_deletion`. Delete all paths.
5. `get_deletion_storage_keys`. Delete all established media storage.
6. Any deletion failure → `record_deletion_failure_wrapper('FK_PROCESSING_FAILED')`; `422`.
7. Delete `auth.users` via Admin API. Failure → `500`.
8. `mark_auth_deleted_wrapper`. Failure → log for recovery worker; `500`.
9. `mark_storage_cleaned_wrapper`. Failure → log for recovery worker; `500`.
10. `200 {"status":"complete"}`.

**Deployment gate:** `deletion-recovery-worker` deployed simultaneously.

**Local tests (required):**
- Happy path → 200 `complete`.
- `auth_deleted` on entry → 409 `FK_WRONG_STATE`.
- `complete` on entry → 500.
- Active processing lease → 409.
- Active URL capability → 409 with `retry_after`.
- Storage deletion failure → 422.
- Auth deletion failure → 500.
- Test enforces `mark_auth_deleted` called before `mark_storage_cleaned`.
- Step 24 Rev 10 §5.1 mandatory tests (V4 identifier substitutions applied).

---

### 5.7 `deletion-recovery-worker`

**Contract:** Step 24 §4.7 with V4 corrections.

**Authentication pattern:** `withSupabase({ auth: 'none' }, ...)` + manual cron-secret check.

**V4 corrections:**
- `database_prepared`: confirm auth user absent first (Admin API → 404). Present → `fail_deletion_recovery('FK_AUTH_STILL_EXISTS')`; skip.
- `complete_deletion_recovery` handles all transitions. Do NOT call `mark_auth_deleted_wrapper` or `mark_storage_cleaned_wrapper` separately.
- `fail_deletion_recovery` removes the claim row. Next run re-issues and retries.

**Sequence for `database_prepared`:**
a. Auth absent check. Present → fail; skip.
b. `quiesce_upload_sessions_for_deletion`. Blocking lease → fail; skip.
c. `get_upload_capability_expiry`. Non-NULL → fail; skip.
d. Collect and delete all paths + media keys.
e. Any failure → `fail_deletion_recovery('FK_PROCESSING_FAILED')`; skip.
f. `complete_deletion_recovery(user_id, claim_token, 'database_prepared')`.

**Sequence for `auth_deleted`:** Steps b–f above (no auth check needed).

**Schedule:** Every 5 minutes. **Deployment:** Simultaneously with `account-delete-complete`.

---

### 5.8 `moderation-action` — DEFERRED (Hard Launch Gate)

`approve_photo`, `reject_photo`, `remove_content`, `remove_media` — service_role ONLY in V4. Cannot be called with a user JWT. `moderation-action` Edge Function is required before end-to-end gameplay.

After `upload-complete`, media is `pending_review`. Without `moderation-action`, no case can ever be launched. This is a documented hard gate before any end-to-end gameplay testing.

A separate proposal step with its own three-party approval is required before `moderation-action` is designed or implemented.

---

## Section 6 — Shared Module

**Location:** `supabase/functions/_shared/`

**JWT and auth pattern:** The module wraps `@supabase/server`. Raw JWT decoding is prohibited. Verified claims come only from `createSupabaseContext` or `withSupabase`.

| Export | Description |
|---|---|
| `getAuthContext(req)` | Wraps `createSupabaseContext(req, { auth: 'user' })`; returns `{ ctx, error }`; `ctx.userClaims.id` is the verified user ID; `ctx.supabase` is RLS-scoped; `ctx.supabaseAdmin` bypasses RLS |
| `checkActiveProfile(supabase, userId)` | Confirms `public.profiles` row with `is_active = true AND onboarding_complete = true`; returns `{ ok, error }` |
| `checkProfileExists(supabase, userId)` | Confirms profile row exists (any `is_active` / `onboarding_complete` value); used by deletion carveout |
| `validateCronSecret(req)` | Reads `X-Forkensics-Cron-Secret`; constant-time comparison to `CRON_SECRET`; returns `{ ok }` |
| `adminClient()` | Service-role Supabase client (`ctx.supabaseAdmin` equivalent for non-`withSupabase` contexts) |
| `errorEnvelope(code, message, status)` | Returns `Response` with JSON `{ error: { code, message } }` |
| `sha256Hex(data: Uint8Array)` | SHA-256 → lowercase hex |
| `presignPutUrl(path, expiresIn)` | S3 Signature V4 presigned PUT; `forcePathStyle: true`; reads `S3_*` env vars; `ExpiresIn: 300` only |
| `safeLog(fields)` | Structured log; allowlist enforced; never logs paths, tokens, URLs, secrets, keys |

**Standard gate (upload-authorize, upload-complete, media-serve):**
```typescript
const { ctx, error } = await getAuthContext(req)
if (error) return errorEnvelope('FK_UNAUTHENTICATED', '...', 401)
const profileCheck = await checkActiveProfile(ctx.supabase, ctx.userClaims.id)
if (!profileCheck.ok) return errorEnvelope('FK_FORBIDDEN', '...', 403)
```

**Deletion carveout gate (account-delete-complete):**
```typescript
const { ctx, error } = await getAuthContext(req)
if (error) return errorEnvelope('FK_UNAUTHENTICATED', '...', 401)
const profileCheck = await checkProfileExists(ctx.supabase, ctx.userClaims.id)
if (!profileCheck.ok) return errorEnvelope('FK_UNAUTHENTICATED', '...', 401)
```

**Cron gate (scheduled-close, upload-cleanup-worker, deletion-recovery-worker):**
```typescript
export default {
  fetch: withSupabase({ auth: 'none' }, async (req, ctx) => {
    const { ok } = validateCronSecret(req)
    if (!ok) return errorEnvelope('FK_UNAUTHENTICATED', '...', 401)
    // ctx.supabaseAdmin available for privileged work
  })
}
```

All environment variables read from `Deno.env.get()`. Never logged.

---

## Section 7 — Test Requirements

### 7.1 Mandatory Baseline

**Step 24 Rev 10 §5.1 is mandatory.** All tests listed there apply with V4 identifier substitutions:
- `challenge_id` → `case_id`, `public.challenges` → `public.cases`, `state = 'active'` → `state = 'launched'`, function names per Section 2 delta table.

Section 5.x tests in this step are additive. Binding Step 24 §5.1 categories that must be covered:
- Reservation vs. deletion concurrency races (Race A and Race B)
- Late PUT replay (post-URL-expiry write to original path)
- Cleanup worker vs. finalization races (SKIP LOCKED behavior)
- `fail_upload_session` transition coverage (all states)
- Recovery claim failures and re-issue
- Additional storage-failure paths

### 7.2 Test Toolchain

- `deno check` — zero errors
- `deno fmt --check` — zero diff
- `deno lint` — zero warnings
- `gitleaks detect` — covers high-entropy patterns (base64, hex, JWT, high-entropy random); not keyword-only

`bash -n` is not a TypeScript validator and must not be used.

### 7.3 No Live Supabase Required

All local tests run against `supabase start`. No cloud operations under this step.

### 7.4 Test File Locations

- `supabase/functions/<fn>/<fn>.test.ts`
- `supabase/functions/_shared/test-helpers.ts`

---

## Section 8 — Deployment Gates

### 8.1 Per-Function Deployment Checklist

Before any cloud deployment (future step — requires separate approval):
1. `deno check`, `deno fmt --check`, `deno lint` — zero output.
2. `gitleaks detect` — no findings.
3. `deno.lock` committed; all imports pinned.
4. All §5.x local tests + Step 24 §5.1 mandatory tests passing.
5. Three-party approval for the specific function.
6. `upload-complete`: Gate 2B hosted spike approved and passed.
7. `upload-complete` and `upload-cleanup-worker` deployed simultaneously.
8. `account-delete-complete` and `deletion-recovery-worker` deployed simultaneously.
9. `static_files` in `config.toml` configured for WASM; CLI ≥ 2.7.0; Docker/CLI deploy used (no `--use-api`).

### 8.2 Rollback

Rollback = redeploy last-known-good artifact. Prior version retained in CI/CD until new version is proven stable.

### 8.3 No Deployment Under This Step

No cloud deployment authorized under Step 27.

---

## Section 9 — Swift API Surface

### 9.1 Operations Requiring Edge Function Calls (`supabase.functions.invoke`)

All invocations use POST.

| Operation | Function Name | Request Body | Response |
|---|---|---|---|
| Request upload URL | `upload-authorize` | `{ "case_id": "...", "content_type": "...", "declared_size_bytes": 1234 }` | JSON (§9.3) |
| Complete upload | `upload-complete` | `{ "upload_token": "..." }` | JSON (§9.4) |
| Serve image | `media-serve` | `{ "case_id": "..." }` | Binary WebP (§9.5) |
| Delete account | `account-delete-complete` | *(empty)* | JSON `{"status":"complete"}` |

### 9.2 Operations Using Direct RPC (`supabase.rpc`)

All use the authenticated user JWT. Parameter names are exact V4 PostgreSQL function parameter names.

| Operation | V4 RPC Name | Parameters |
|---|---|---|
| Submit a guess | `submit_guess` | `p_case_id: UUID, p_investigation_id: UUID, p_race: String, p_guess_text: String, p_idempotency_key: String, p_client_submitted_at: Date?` |
| Launch a case | `launch_case` | `p_case_id: UUID, p_actor_id: UUID, p_group_ids: [UUID], p_duration_seconds: Int` |
| Reveal a case (poster) | `reveal_case` | `p_case_id: UUID` |
| Cancel a case (poster) | `cancel_case` | `p_case_id: UUID, p_reason: String?` |
| Create a group | `create_group` | `p_name: String` |
| Create group invite | `create_group_invite` | `p_group_id: UUID` |
| Redeem group invite | `redeem_group_invite` | `p_raw_token: String` |
| Revoke group invite | `revoke_group_invite` | `p_invite_id: UUID` |
| Transfer group ownership | `transfer_group_ownership` | `p_group_id: UUID, p_new_owner_id: UUID` |
| Soft-delete comment | `soft_delete_comment` | `p_comment_id: UUID` |
| Report content | `report_content` | `p_target_type: String, p_target_id: UUID, p_category: String, p_detail: String?` |
| Add a clue | Direct INSERT into `public.clues` | RLS enforces poster-only |
| Post comment | Direct INSERT into `public.comments` | RLS enforces group membership |
| Post reaction | Direct INSERT into `public.reactions` | RLS enforces group membership |
| Remove reaction | Direct DELETE from `public.reactions` | RLS enforces ownership |

**Notes:**
- `reveal_case(p_case_id)` — authenticated; poster only; requires `state = 'locked'`. Verified V4 line 2625; grant line 3269.
- `cancel_case(p_case_id, p_reason)` — authenticated; poster only; valid in `draft`, `ready`, `launched`. Verified V4 line 2720; grant line 3267.
- `submit_guess` returns a UUID (the new `guess_attempt` ID).
- `launch_case` takes `p_actor_id` explicitly; V4 verifies it matches the JWT `sub` claim internally.
- `report_content` returns `TABLE(report_id uuid)`; `p_detail` is optional (default NULL).

### 9.3 Upload-Authorize Response Shape

```swift
struct UploadAuthorizeResponse: Decodable {
    let presignedUrl: String      // "presigned_url"
    let uploadToken: String       // "upload_token"
    let expiresAt: Date           // "expires_at" ISO 8601
}
```

`sessionId` is NOT in the response.

### 9.4 Upload-Complete Response Shape (V4)

```swift
struct UploadCompleteResponse: Decodable {
    let mediaObjectId: UUID           // "media_object_id"
    let status: String                // "pending_review" — not "ready"
    let alreadyComplete: Bool?        // "already_complete" — present on idempotent calls only
    let replacedMediaObjectId: UUID?  // "replaced_media_object_id"
}
```

Media is `pending_review` after upload. `media-serve` returns 404 for pending-review media.

### 9.5 Media-Serve Swift Invocation (Corrected)

```swift
let imageData: Data = try await supabase.functions.invoke(
    "media-serve",
    options: FunctionInvokeOptions(
        body: ["case_id": caseId.uuidString]
    ),
    decode: { data, _ in data }
)
```

The `decode: { data, _ in data }` closure returns raw `Data` instead of attempting JSON decoding. There is no `response.data` property contract; the raw bytes are returned via the custom decoder.

### 9.6 Error Handling

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
| S3 env var contract | Defined in Gate 4. Local: `region=local`, `access_key_id=stub`, `secret=ANON_KEY`. Production: dashboard-generated keys. |
| WASM packaging | `static_files` in `config.toml`; CLI ≥ 2.7.0; Docker/CLI deploy only (no `--use-api`). |
| pg_cron / pg_net | Gate 3 (local only). Hosted validation is a separate step. |
| `magick-wasm` at 10 MB | Gate 2: Phase A (local) establishes pixel budget → Gate 2B (hosted, separate cloud approval) must pass before Step B TypeScript implementation begins. |
| Pre-decode safety | Header parse before raster decode; pixel-count threshold from Gate 2 Phase A. |
| Metadata stripping | Structural parse of output WebP; exact fields: EXIF, GPS, ICC, XMP, IPTC, comments, all embedded profiles. |
| `get_media_serve_authorization` grant | service_role only (V4 line 3313–3314). |
| `submit_guess` mechanism | `supabase.rpc("submit_guess", ...)` with exact V4 parameter names. |
| `reveal_case` / `cancel_case` V4 status | Both verified; exact signatures added to §9.2. |
| `media-serve` HTTP contract | POST via `functions.invoke`; `case_id` in JSON body; binary WebP via `decode: { data, _ in data }`. |
| `scheduled-close` race | Specified: loser catches state-mismatch error; classifies as skipped; not logged as error. |
| Finalization error mapping | Re-resolve after every finalization error; `complete` → 200 idempotent; `sanitized` → map original error code (`FK_INVALID_HASH` → 422, `FK_WRONG_STATE` → 409, transport/unknown → 500); other → 500. Response-lost test occurs within same invocation. |
| Sanitized re-entry SHA-256 | Download display from storage; validate WebP; compute hash from downloaded bytes. No in-memory buffer on re-entry. |
| JWT verification | `createSupabaseContext(req, { auth: 'user' })` from `@supabase/server`. Raw JWT decoding prohibited. |
| Moderation | Deferred; hard gate documented in §5.8. |

---

## Section 11 — Approval Record

| Party | Status | Notes |
|---|---|---|
| Claude | Approved | Rev 5 authored by Claude; both Rev 4 blockers addressed |
| Codex | Approved | 2026-08-12 — "No new blockers found." |
| Bill | Approved | 2026-08-12 — "Approved - Bill" |

**This approval authorizes the plan only. No TypeScript or cloud operations until their respective approved steps.**

Implementation sequence:
- Next: Execute pre-implementation Gates 1–5 and open Gate 2B approval request (separate step).
- Step A (`upload-authorize`) implementation requires its own three-party step approval.
- Each subsequent function step requires its own three-party approval before implementation begins.
