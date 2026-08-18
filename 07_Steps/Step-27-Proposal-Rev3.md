# Step 27 Proposal — Rev 3 — Edge Function Implementation Plan

**Status:** Pending review (Claude → Codex → Bill approval)

**Governance gate:** All three parties (Bill + Claude + Codex) must approve before any TypeScript code is written. The magic words are `APPROVED: Step 27 Rev 3 — Edge Function Implementation Plan`.

**Supersedes:** Step 27 Rev 2 (rejected — 8 blockers)

**Rev 3 changes from Rev 2:**
1. `sanitized` re-entry corrected: buffer is not retained across invocations; download display, verify WebP, compute SHA-256, then finalize.
2. `advance_upload_session_sanitized` RPC-error ambiguity resolved: re-resolve session after any RPC failure; handling depends on resolved state.
3. Image spike restructured: two-phase (local functional + hosted on forkensics-dev under separate cloud approval); pre-decode safety enforced; full metadata-stripping checklist; Supabase bundle-size constraints documented.
4. S3 environment-variable contract defined in full; local wiring specified.
5. Cron preflight constraint resolved: fully-local option selected (pg_cron local → local echo server); hosted option deferred to a separate cloud-approval step.
6. Step 24 Rev 10 §5.1 test matrix declared mandatory with V4 identifier substitutions; Rev 3 §5.x tests are additive.
7. `media-serve` HTTP contract made precise: POST via `supabase.functions.invoke` with JSON body; binary WebP returned; GET path-param form removed.
8. Swift RPC parameter names corrected to exact V4 names; `reveal_case` and `cancel_case` added as verified authenticated functions.
9. Gates 5–6 restructured: Deno installation/smoke is the pre-code gate; check/fmt/lint and lockfile generation happen after each scaffold.

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
| `state = 'locked'` required for reveal (V3) | `state = 'locked'` required for `reveal_case_service_wrapper` (V4, confirmed) | No logic change; function name changes |
| `finalize_upload_session(session_id uuid)` — one arg; media `status = 'ready'` | `finalize_upload_session(session_id uuid, sha256_hash text)` — two args; media `status = 'pending_review'` | `upload-complete` must compute SHA-256 of WebP output; response `status` field changes |
| `upload-complete` 200: `"status": "ready"` | `"status": "pending_review"` | Swift must not assume media is immediately servable |
| `media-serve GET /media/{challenge_id}` — streams bytes | `POST /media-serve` via `functions.invoke` with `{ "case_id": "<uuid>" }` body; binary WebP returned | See §5.4 and §9.1 |
| `get_media_storage_key(media_object_id)` — status check only | `get_media_serve_authorization(media_object_id, viewer_id)` — status + case visibility + `moderator_removed_at`; service_role only | Pending-review media returns 404 from media-serve |
| `submit_guess`: direct authenticated INSERT into `public.guess_attempts` | `supabase.rpc("submit_guess", { p_case_id, p_investigation_id, p_race, p_guess_text, p_idempotency_key, p_client_submitted_at })` | Direct INSERT revoked in V4 |
| `activate_challenge(uuid)` — V3 | `launch_case(p_case_id, p_actor_id, p_group_ids, p_duration_seconds)` — V4; authenticated | Different name, different signature |
| `reveal_challenge(uuid)` — V3 | `reveal_case(p_case_id uuid)` — V4; authenticated; poster only; requires `state = 'locked'` | Verified at V4 line 2625; grant at line 3269 |
| `cancel_challenge(uuid, text)` — V3 | `cancel_case(p_case_id uuid, p_reason text)` — V4; authenticated; poster only; valid in `draft`, `ready`, `launched` | Verified at V4 line 2720; grant at line 3267 |
| `approve_photo`, `reject_photo`: not explicitly categorized | V4: service_role ONLY — not callable with user JWT | Requires `moderation-action` Edge Function; deferred (§5.8) |
| `remove_content`, `remove_media`: not explicitly categorized | V4: service_role ONLY — not callable with user JWT | Same gate |
| `report_content`: user-callable | V4: authenticated-callable (confirmed) | No change needed |

**Hard constraint derived from this table:** After `finalize_upload_session`, media is `pending_review`. A case cannot be launched until a moderator calls `approve_photo`. There is no Edge Function for moderation calls in this plan. This is a known launch blocker — see Section 5.8.

---

## Section 3 — Pre-Implementation Gates

### Gate 1 — V2 Migration Applied and Tested

`V2__upload_sessions.sql` must be applied, committed, and the V2 acceptance test suite must pass (Steps 25/26 complete). This step assumes V2 is live locally and in CI.

### Gate 2 — Image Processing Spike (Hard Gate — Two Phases)

**Required before implementing `upload-complete`.**

`magick-wasm` is the Supabase-recommended WASM library for image processing in Edge Functions. Known constraints: Supabase permits up to 20 MB locally bundled or 5 MB server-bundled functions. Supabase warns that image processing above 5 MB can exceed resources in the hosted runtime. The spike must establish whether `upload-complete` (processing inputs up to 10 MB) is viable.

**Phase A — Local functional testing (no cloud approval required):**

Create a standalone Deno script (`tools/image-spike/run.ts`) that:

1. Imports `magick-wasm`.
2. For each test input (5 MB JPEG, 8 MB JPEG, 10 MB JPEG, and one WebP):
   a. Parse image header/dimensions without full raster decode. If pixel count exceeds a defined limit (e.g., 100 MP) or if the header cannot be parsed safely → reject with error, do not proceed to decode. This must happen before any full raster decode to prevent decompression exhaustion.
   b. Full decode of images that pass the pre-decode check.
   c. Re-encode to WebP.
   d. Strip metadata: verify removal of EXIF, GPS, ICC, XMP, comments, IPTC, and all other embedded profiles from the output WebP. Verification must be cryptographic or structural (parse output bytes and confirm no metadata blocks remain), not just "magick strips by default."
   e. Compute SHA-256 of the output WebP bytes.
   f. Record: CPU time, memory peak (from Deno process metrics), wall-clock time.
3. Measure bundled size of the resulting Edge Function when `magick-wasm` is included.
4. Document results in `tools/image-spike/results.md`.

Phase A verdict: if WASM bundle exceeds 20 MB (local) or if the functional pipeline fails at 10 MB, the spike fails without needing Phase B.

**Phase B — Hosted runtime validation (requires separate explicit cloud approval before execution):**

If Phase A passes, a disposable hosted spike function is deployed to forkensics-dev to measure:

- Actual memory and CPU under the Supabase hosted runtime (not local Deno).
- Whether the function stays within the resource envelope for 10 MB inputs.
- Wall-clock time vs. the 150-second idle timeout.

Phase B requires a separate three-party approval before any cloud operation. It is NOT authorized under this step.

**Spike verdict is a gate:** If the spike fails at 10 MB in Phase A (bundle too large or pipeline errors), or fails Phase B (resource exhaustion), the team must choose:
- (a) Enforce a 5 MB declared size limit instead of 10 MB, or
- (b) Identify an alternative compute path (separate worker, different library).

No implementation of `upload-complete` proceeds until the spike produces a written Phase A verdict, plus a Phase B verdict if Phase A passes.

### Gate 3 — Cron Preflight (Fully Local)

The preflight must be entirely local — a pg_cron job running in forkensics-dev cannot reach a `localhost` echo server on the developer's machine.

The local preflight:
1. Confirm `pg_cron` extension is enabled in the local Supabase instance (`supabase start`).
2. Confirm `pg_net` extension is enabled.
3. Start a local HTTP echo server (e.g., `deno run --allow-net tools/echo-server.ts`) on a port reachable from the local Supabase Docker network (typically the host's Docker gateway IP, not `127.0.0.1`).
4. Register a test cron job that fires a pg_net HTTP POST to the echo server's Docker-accessible address.
5. Confirm the request arrives at the echo server within the expected interval.
6. Remove the test job.

Results documented in the evidence log. If forkensics-dev pg_cron/pg_net behavior must also be validated, that is a separate hosted preflight step requiring its own cloud approval.

### Gate 4 — S3 Connection and Environment Variables

**Environment variable contract (canonical list):**

| Variable | Description | Example |
|---|---|---|
| `SUPABASE_URL` | Project URL | `https://<ref>.supabase.co` |
| `SUPABASE_SERVICE_ROLE_KEY` | Service role key | (never in repo; injected at deploy) |
| `CRON_SECRET` | Cron authentication secret (≥256 bits) | (never in repo; injected at deploy) |
| `S3_ENDPOINT` | Supabase Storage S3 endpoint | `https://<ref>.supabase.co/storage/v1/s3` |
| `S3_REGION` | Region as configured in Supabase | (from project settings) |
| `S3_ACCESS_KEY_ID` | S3-compatible access key ID | (from project settings; not in repo) |
| `S3_SECRET_ACCESS_KEY` | S3-compatible secret key | (never in repo; injected at deploy) |
| `S3_BUCKET` | Storage bucket name | `game-media` |

Path-style addressing: Supabase Storage S3 compatibility requires path-style requests (`https://<endpoint>/<bucket>/<key>`), not virtual-hosted-style. The `presignPutUrl` shared module function must configure path-style = `true`.

Local wiring: For the local Supabase instance, `S3_ENDPOINT` is `http://127.0.0.1:54321/storage/v1/s3` (or the equivalent Docker host address). Local access key ID and secret key are obtained from `supabase status` or the local Supabase config file. These values are set in `supabase/functions/.env` (git-ignored) for local development only.

**Preflight test:**
1. Configure all S3 env vars for the local instance.
2. Sign a presigned PUT URL for `game-media/preflight-test/object.bin` using S3 Signature V4 with `ExpiresIn: 300`.
3. Upload a 1-byte object via the signed URL (`curl -X PUT --data-binary @/dev/null <url>`).
4. Confirm the object appears in the `game-media` bucket via the service-role client.
5. Delete the object.
6. Confirm deletion.

`createSignedUploadUrl()` is NOT acceptable — it produces 2-hour URLs. Only S3 Signature V4 with `ExpiresIn: 300` is permitted.

### Gate 5 — Deno Toolchain Installation and Smoke Validation

This gate runs before any scaffold is created. It verifies the toolchain is present and functional, not that any function file passes linting (there are no function files yet).

Smoke validation:
```sh
deno --version                       # must print a version
deno eval "console.log('ok')"        # must print ok
gitleaks version                     # must print a version
```

After each function scaffold is created (index.ts + imports):
- `deno check supabase/functions/<fn>/index.ts` — zero errors
- `deno fmt --check supabase/functions/<fn>/index.ts` — zero diff
- `deno lint supabase/functions/<fn>/index.ts` — zero warnings

### Gate 6 — Dependency Lockfile

`deno.lock` must be generated and committed after the first function scaffold is created:
```sh
deno cache --lock=deno.lock supabase/functions/<fn>/index.ts
```

All import specifiers must pin exact versions. No floating semver ranges. `deno.lock` must be regenerated and re-committed whenever imports change.

---

## Section 4 — Implementation Order

```
Gate 1 (V2 migration)
Gate 2A (magick-wasm local spike) ───────────────────────────┐
Gate 3 (pg_cron local preflight)                             │
Gate 4 (S3 env vars + preflight)                             │
Gate 5 (Deno installation smoke)                             │
         │                                                   │
         ▼                                                   │
Step A: upload-authorize ──► Gate 6 (lockfile generated)     │
Step B: upload-complete ◄────────────────────────────────────┘
         + Gate 2B (hosted spike, separate cloud approval)
Step C: upload-cleanup-worker (deploy simultaneously with B)
Step D: media-serve
Step E: scheduled-close
Step F: account-delete-complete
Step G: deletion-recovery-worker (deploy simultaneously with F)
Step H: moderation-action [DEFERRED — see §5.8]
```

Each step: implementation → check/fmt/lint → gitleaks → local tests → three-party approval → next step.

---

## Section 5 — Per-Function Build Plans

### 5.1 `upload-authorize`

**Contract:** Step 24 §4.1 (no V4 behavioral delta; identifier substitutions only).
**V4 identifier changes:** `challenge_id` → `case_id`; `public.challenges` → `public.cases`.

**Response (from Step 24 §4.1 — never deviate):**
```json
{ "presigned_url": "<url>", "upload_token": "<secret token>", "expires_at": "<ISO 8601>" }
```

`session_id`, storage paths, and `storage_upload_expires_at` are internal — never returned.

**Presigned URL:** S3 Signature V4, `ExpiresIn: 300`. `createSignedUploadUrl()` is prohibited.

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
- Step 24 Rev 10 §5.1 mandatory tests (V4 identifier substitutions applied).

---

### 5.2 `upload-complete`

**Contract:** Step 24 §4.2, with V4 corrections below. Step 24 Rev 10 §5.1 test requirements remain mandatory.

**V4 correction 1 — `finalize_upload_session` signature:**
`finalize_upload_session(session_id uuid, sha256_hash text)`. SHA-256 is computed from the WebP output bytes (lowercase hex, 64 characters). V4 DB function rejects inputs not matching `^[0-9a-f]{64}$` with `FK_INVALID_HASH` → treat as `422 FK_PROCESSING_FAILED`.

**V4 correction 2 — media status:**
`finalize_upload_session` creates `media_objects` with `status = 'pending_review'` (not `'ready'`).

**Response `200 OK` (V4):**
```json
{ "media_object_id": "<uuid>", "status": "pending_review" }
```

**Complete state machine (restored from Step 24 §4.2 with V4 corrections):**

*Idempotency branch — check session status before any action:*
- `complete` → `200 {"status":"pending_review","media_object_id":"<uuid>","replaced_media_object_id":"<uuid or null>","already_complete":true}`.
- `processing` → `202 {"status":"processing"}`.
- `sanitized` → skip to sanitized re-entry procedure (below).
- `pending` → proceed to happy path.
- Any other status (`expired`, `failed`, `cleaned`) → `400 FK_INVALID_TOKEN`.

*Happy path (status `pending`):*

1. `advance_upload_session_processing(session_id, user_id, '10 minutes')` — transitions to `processing`, sets lease. Failure → `400 FK_INVALID_TOKEN`.
2. Read original from `session.original_storage_path`. Absent → `fail_upload_session(session_id, 'FK_NOT_FOUND')`; return `404 FK_NOT_FOUND`.
3. Sniff actual MIME. Must be `image/jpeg` or `image/webp` AND match `session.content_type`. Failure → delete original; `fail_upload_session('FK_INVALID_CONTENT_TYPE')`; return `400 FK_INVALID_CONTENT_TYPE`.
4. Confirm actual size ≤ 10,485,760 bytes. Over limit → delete original; `fail_upload_session('FK_FILE_TOO_LARGE')`; return `400 FK_FILE_TOO_LARGE`.
5. **Pre-decode safety check:** Parse image header to extract pixel dimensions without performing a full raster decode. If pixel count exceeds defined limit (e.g., 100 megapixels) or if the header cannot be safely parsed → delete original; `fail_upload_session('FK_PROCESSING_FAILED')`; return `422 FK_PROCESSING_FAILED`. Do not attempt full decode on images that fail this check.
6. Re-encode to WebP; strip all EXIF, GPS, ICC, XMP, comments, IPTC, and embedded profiles. Failure → delete original; `fail_upload_session('FK_PROCESSING_FAILED')`; return `422 FK_PROCESSING_FAILED`.
6.5. `check_upload_session_lease(session_id)`. If false → delete original; return `422 FK_PROCESSING_FAILED`. Do NOT call `fail_upload_session`. Do NOT write display.
7. Write re-encoded WebP to `session.display_storage_path`. Failure → delete original; `fail_upload_session('FK_PROCESSING_FAILED')`; return `422 FK_PROCESSING_FAILED`.
8. Delete original from `session.original_storage_path`. Retry up to 2 times. All attempts fail → delete display; `fail_upload_session('FK_PROCESSING_FAILED')`; return `422 FK_PROCESSING_FAILED`.
9. Call `advance_upload_session_sanitized(session_id)`.

   **Step 9 RPC-error handling (ambiguity resolution):** The RPC call may have committed on the server while the client received an error (network partition, timeout). A naive "delete display and fail" response may corrupt a valid `sanitized` session. After any error from step 9:
   a. Re-resolve the session: call `resolve_upload_session(token_hash, user_id)`.
   b. Resolved status `sanitized` → display is intact; fall through to sanitized re-entry (below).
   c. Resolved status `complete` → finalization already committed; return idempotent `200`.
   d. Resolved status `processing` (RPC definitely did not commit) → delete display; `fail_upload_session('FK_INTERNAL')`; return `500 FK_INTERNAL`.
   e. Any other status or no row → delete display; return `500 FK_INTERNAL`.

*Sanitized re-entry (entered from idempotency branch or from step 9 re-resolution):*

**Note: There is no in-memory WebP buffer on a sanitized re-entry.** The original processing invocation has ended. The re-entry is a new Edge Function invocation with no shared memory. SHA-256 must be derived from storage, not from a prior buffer.

10. Download `session.display_storage_path` from storage. Absent → `fail_upload_session('FK_PROCESSING_FAILED')`; return `422 FK_PROCESSING_FAILED`.
11. Verify the downloaded bytes are a valid WebP. Invalid → delete display; `fail_upload_session('FK_PROCESSING_FAILED')`; return `422 FK_PROCESSING_FAILED`.
12. Compute SHA-256 of the downloaded WebP bytes (lowercase hex, 64 chars).
13. Call `finalize_upload_session(session_id, sha256_hash)`.

*Finalization (from step 13 or from happy path step 9):*

For the happy-path finalization path, compute SHA-256 from the in-memory WebP buffer (step 6) before calling finalize:

- `finalize_upload_session(session_id, sha256_hash)` — verifies `sanitized` or idempotent `complete`; verifies case `draft`. Challenge not `draft` → `409 FK_WRONG_STATE`. `FK_INVALID_HASH` → `422 FK_PROCESSING_FAILED`. Failure with session still `sanitized` → `500 FK_INTERNAL`; client retries (re-enters sanitized branch).
- Return `200 {"media_object_id":"<uuid>","status":"pending_review"}`.

**Local tests (required):**
- Full happy path → 200, `status = "pending_review"`.
- Idempotent `complete` → 200 `already_complete: true`.
- `processing` → 202.
- Sanitized re-entry: display present, valid WebP → correct SHA-256 computed from storage; finalization succeeds.
- Sanitized re-entry: display absent → 422.
- Sanitized re-entry: display present but invalid WebP → display deleted; session failed; 422.
- Lease expiry between steps 6 and 6.5 → 422 (no `fail_upload_session`, no display write).
- Original deletion failure after 2 retries → display deleted; session failed; 422.
- Step 9 error, re-resolve → `sanitized` → sanitized re-entry path taken; not double-failing.
- Step 9 error, re-resolve → `processing` → display deleted; `fail_upload_session`; 500.
- `FK_INVALID_HASH` from DB → 422.
- `finalize` fails with session still `sanitized` → 500; client can retry via sanitized branch.
- Invalid token / expired / failed → 400 `FK_INVALID_TOKEN`.
- Step 24 Rev 10 §5.1 mandatory tests (V4 identifier substitutions applied).

---

### 5.3 `upload-cleanup-worker`

**Contract:** Step 24 §4.6 with V4 corrections.

**V4 correction — function for complete sessions:** `get_complete_sessions_pending_expiry_cleanup()` (confirmed V2 schema, line 928). Returns `(session_id, original_storage_path)` for complete sessions where `original_path_post_expiry_cleaned = false` AND `storage_upload_expires_at + 30s <= now()`.

**V4 correction — NULL-expiry sessions:** Sessions with `storage_upload_expires_at IS NULL` pass the URL-expiry gate in `claim_cleanup_sessions` (no capability was ever issued). The cleanup worker must attempt deletion of `original_storage_path` as a precaution — the object may or may not exist. Absent = no-op.

**V4 correction — `mark_session_cleaned` is conditional:** Only called if all storage deletions for that session succeed. If any fail → do not mark cleaned; session re-appears after claim expiry for retry.

**Parts:**

Part 1 — upload session cleanup:
1. `claim_cleanup_sessions(worker_id, '15 minutes')`.
2. For each: delete `original_storage_path` and `display_storage_path` (absent = no-op). If all succeed → `mark_session_cleaned(session_id, cleanup_claim_token)`. If any fail → log; do not mark; retry next run.

Part 2 — superseded media:
1. `get_superseded_media_to_clean()`. For each: delete `re_encoded_storage_key`. Success → `mark_superseded_media_cleaned`. Failure → log; retry next run.

Part 3 — post-expiry original-path cleanup:
1. `get_complete_sessions_pending_expiry_cleanup()`.
2. For each: attempt delete of `original_storage_path`. Absent = no-op.
3. Delete succeeded or object absent → `mark_original_path_post_expiry_cleaned(session_id)`.
4. Delete failed and object was present → log; do NOT call `mark_original_path_post_expiry_cleaned`; retry next run.

**Deployment:** Simultaneously with `upload-complete`.

---

### 5.4 `media-serve`

**Contract:** Step 24 §4.3, with the following V4 corrections and HTTP contract clarification.

**V4 correction — authorization function:**
`get_media_serve_authorization(media_object_id, viewer_id)` via service_role client (not `get_media_storage_key`). Requires `mo.status = 'ready'`, `c.moderator_removed_at IS NULL`, `can_viewer_access_case(c.id, viewer_id)`. No result → `404 FK_NOT_FOUND`.

**HTTP contract (authoritative — resolves Rev 2 ambiguity):**

`media-serve` is invoked via POST (using `supabase.functions.invoke` from Swift). There is no GET path parameter form. The Supabase Swift SDK's `functions.invoke` sends POST by default; binary response data is returned directly.

- **Method / Path:** `POST /media-serve`  **`verify_jwt`:** `true`
- **Request body:** `{ "case_id": "<uuid>" }`
- **Response:** Binary WebP bytes with `Content-Type: image/webp` and `Cache-Control: private, max-age=3600`.

The function does not expose a `GET /media/{case_id}` endpoint. All references to GET path-style invocation in prior revisions are superseded by this definition.

**Full action sequence:**
1. Standard gate.
2. Parse `case_id` from request body. Missing or malformed → `400 FK_INVALID_INPUT`.
3. Query `public.cases WHERE id = case_id` using user-JWT client. RLS enforces visibility. No row → `404 FK_NOT_FOUND`.
4. `media_object_id` null → `404 FK_NOT_FOUND`.
5. `get_media_serve_authorization(media_object_id, user_id)` via service_role client. No result → `404 FK_NOT_FOUND` (covers pending-review, moderator-removed, and not-accessible cases).
6. Read file at returned storage key from `game-media`.
7. Return binary bytes: `Content-Type: image/webp`, `Cache-Control: private, max-age=3600`.

**Local tests (required):**
- Authorized viewer, `ready` media → 200 WebP bytes.
- `pending_review` media → 404.
- Moderator-removed case → 404.
- Viewer not in group → 404 (same body as not found).
- No media attached → 404.
- Missing JWT → 401.
- Missing `case_id` in body → 400 `FK_INVALID_INPUT`.
- Step 24 Rev 10 §5.1 mandatory tests (V4 identifier substitutions applied).

---

### 5.5 `scheduled-close`

**Contract:** Step 24 §4.4 with V4 corrections.

**V4 corrections:**
- Pass 1 query: `WHERE state = 'launched' AND deadline_at <= now()`.
- Pass 1 call: `lock_case(p_case_id)`.
- Pass 2 query: `WHERE state = 'locked'`.
- Pass 2 call: `reveal_case_service_wrapper(p_case_id)`.

Pass 2 queries all `locked` cases (not just those locked in the current run) to retry cases that failed in prior runs. `reveal_case_service_wrapper` is expected to be idempotent or raise a catchable error for already-revealed cases.

**Schedule:** Every 2 minutes (pg_cron).
**Authentication:** `X-Forkensics-Cron-Secret` header; constant-time comparison; absent or mismatch → `401 FK_UNAUTHENTICATED`.

**Response `200 OK`:**
```json
{ "locked_count": 0, "revealed_count": 0, "skipped_count": 0, "errors": [] }
```

**Local tests (required):**
- `launched` case past deadline → locked.
- `locked` case → revealed.
- Two-run scenario: Pass 1 locks, Pass 2 reveals; next run skips both (no double-reveal error).
- Per-row error in Pass 1 → logged; Pass 2 still runs.
- Wrong / missing cron secret → 401.
- Step 24 Rev 10 §5.1 mandatory tests (V4 identifier substitutions applied).

---

### 5.6 `account-delete-complete`

**Contract:** Step 24 §4.5.

**Critical ordering rule:** `mark_auth_deleted_wrapper` (step 8) is called BEFORE `mark_storage_cleaned_wrapper` (step 9). Inverting this order corrupts the state machine.

**No waiting in function:** Returns 409 immediately if URL capability is live. The client retries after `retry_after`. Maximum additional client wait: 5 minutes + 30 seconds.

**Full sequence (from Step 24 §4.5):**
1. `prepare_account_deletion_wrapper(user_id)` → `database_prepared`: continue. `auth_deleted`: `409 FK_WRONG_STATE`. `complete`: log anomaly + `500 FK_INTERNAL`.
2. `quiesce_upload_sessions_for_deletion(user_id)`. If any `blocking_lease_expires_at IS NOT NULL` → `409 FK_UPLOAD_IN_PROGRESS`; return immediately.
3. `get_upload_capability_expiry(user_id)`. If non-NULL → `409 FK_UPLOAD_IN_PROGRESS` with `retry_after`; return immediately.
4. `get_all_upload_session_paths_for_deletion(user_id)`. Delete all paths.
5. `get_deletion_storage_keys(user_id)`. Delete all established media storage.
6. Any deletion failure from steps 4–5 → `record_deletion_failure_wrapper(user_id, 'FK_PROCESSING_FAILED')`; return `422 FK_PROCESSING_FAILED`.
7. Delete `auth.users` via Admin API. Failure → `500 FK_INTERNAL`.
8. `mark_auth_deleted_wrapper(user_id)`. Failure → log for recovery worker; `500 FK_INTERNAL`.
9. `mark_storage_cleaned_wrapper(user_id)`. Failure → log for recovery worker; `500 FK_INTERNAL`.
10. Return `200 {"status":"complete"}`.

**Deployment gate:** `deletion-recovery-worker` must be deployed simultaneously.

**Local tests (required):**
- Happy path → 200 `complete`.
- `auth_deleted` state on entry → 409 `FK_WRONG_STATE`.
- `complete` state on entry → log anomaly + 500.
- Active processing lease → 409 `FK_UPLOAD_IN_PROGRESS`.
- Active URL capability → 409 with correct `retry_after`.
- Storage deletion failure → 422.
- Auth deletion failure → 500.
- Test verifies `mark_auth_deleted` called before `mark_storage_cleaned` (order enforced).
- Step 24 Rev 10 §5.1 mandatory tests (V4 identifier substitutions applied).

---

### 5.7 `deletion-recovery-worker`

**Contract:** Step 24 §4.7 with V4 corrections.

**V4 correction — auth check first for `database_prepared`:** Check that the auth user is absent (Admin API `getUser` returns 404) before proceeding. If still present → `fail_deletion_recovery(user_id, claim_token, 'FK_AUTH_STILL_EXISTS')`; skip.

**V4 correction — `complete_deletion_recovery` only:** `complete_deletion_recovery(user_id, claim_token, scan_type)` handles all state transitions internally. Do NOT call `mark_auth_deleted_wrapper` or `mark_storage_cleaned_wrapper` separately.

**Full sequence:**

1. `claim_deletion_recovery_records(worker_id, '10 minutes', '10 minutes')`.

2. For `scan_type = 'database_prepared'`:
   a. Admin API: confirm auth absent. Present → `fail_deletion_recovery(user_id, claim_token, 'FK_AUTH_STILL_EXISTS')`; skip.
   b. `quiesce_upload_sessions_for_deletion`. Blocking lease → `fail_deletion_recovery('FK_UPLOAD_IN_PROGRESS')`; skip.
   c. `get_upload_capability_expiry`. Non-NULL → `fail_deletion_recovery('FK_UPLOAD_IN_PROGRESS')`; skip.
   d. Collect and delete all paths and media keys.
   e. Any failure → `fail_deletion_recovery('FK_PROCESSING_FAILED')`; skip.
   f. `complete_deletion_recovery(user_id, claim_token, 'database_prepared')`.

3. For `scan_type = 'auth_deleted'`:
   a–e. Same as steps b–e above (no auth check needed — auth is already deleted).
   f. `complete_deletion_recovery(user_id, claim_token, 'auth_deleted')`.

**Schedule:** Every 5 minutes. **Deployment:** Simultaneously with `account-delete-complete`.

---

### 5.8 `moderation-action` — DEFERRED (Hard Launch Gate)

**Why deferred:** `approve_photo`, `reject_photo`, `remove_content`, and `remove_media` are granted EXECUTE to `service_role` only in V4. They cannot be called with a user JWT.

**Hard launch blocker:** After `upload-complete`, media is `pending_review`. No case can reach `launched` state without `approve_photo` being called. Without `moderation-action`, `launch_case`, `scheduled-close`, `media-serve`, and all gameplay are blocked. `moderation-action` must be planned, approved, and implemented before the app is testable end-to-end.

**This step does not define the contract for `moderation-action`.** That requires a separate proposal step with its own three-party approval.

---

## Section 6 — Shared Module

**Location:** `supabase/functions/_shared/`

| Export | Description |
|---|---|
| `validateJwt(req)` | Extracts and verifies `sub` claim; confirms active profile; returns `{ userId, error }` |
| `validateJwtCarveout(req)` | `account-delete-complete` variant: any profile state accepted |
| `validateCronSecret(req)` | Constant-time compare of `X-Forkensics-Cron-Secret` to `CRON_SECRET` |
| `adminClient()` | Service-role Supabase client (reads `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`) |
| `userClient(jwt)` | User-JWT Supabase client for RLS-scoped reads |
| `errorEnvelope(code, message, status)` | Returns `Response` with JSON `{ error: { code, message } }` |
| `sha256Hex(data: Uint8Array)` | SHA-256 of bytes → lowercase hex string |
| `presignPutUrl(path, expiresIn)` | S3 Signature V4 presigned PUT for `game-media`; path-style addressing; reads S3 env vars; never uses `createSignedUploadUrl` |
| `safeLog(fields)` | Structured log; enforces allowlist (never logs paths, tokens, URLs, secrets, keys) |

All environment variables read from `Deno.env.get()`. No environment variable is logged. No secret appears in source code or the lockfile.

---

## Section 7 — Test Requirements

### 7.1 Mandatory Baseline

**Step 24 Rev 10 §5.1 is mandatory.** All tests listed there apply, with V4 identifier substitutions:
- `challenge_id` → `case_id`
- `public.challenges` → `public.cases`
- `state = 'active'` → `state = 'launched'`
- Function names updated per the delta table in Section 2.

The §5.x subsections in this step (Rev 3) are additive. They do not replace Step 24 §5.1.

Binding Step 24 §5.1 test categories that must be covered (not listed in Rev 3 §5.x but still required):
- Reservation vs. deletion concurrency races (Race A and Race B)
- Late PUT replay (post-URL-expiry write to original path)
- Cleanup worker vs. finalization races (SKIP LOCKED behavior)
- `fail_upload_session` transition coverage (all states)
- Recovery claim failures and re-issue
- Additional storage-failure paths from Step 24 §5.1

### 7.2 Test Toolchain

- TypeScript validation: `deno check supabase/functions/<fn>/index.ts`
- Formatting: `deno fmt --check supabase/functions/<fn>/index.ts`
- Linting: `deno lint supabase/functions/<fn>/index.ts`
- Credential scan: `gitleaks detect` — must cover high-entropy patterns (base64, hex, JWT, high-entropy tokens), not just keyword matching.

`bash -n` is not a TypeScript validator and must not be used for this purpose.

### 7.3 No Live Supabase Required

All local tests run against `supabase start`. No cloud operations under this step.

### 7.4 Test File Locations

- `supabase/functions/<fn>/<fn>.test.ts`
- `supabase/functions/_shared/test-helpers.ts`

---

## Section 8 — Deployment Gates

### 8.1 Per-Function Deployment Checklist

Before any function is deployed to a cloud environment (future step — requires separate approval):

1. `deno check`, `deno fmt --check`, `deno lint` — zero output.
2. `gitleaks detect` — no findings.
3. `deno.lock` committed; all imports pinned.
4. All §5.x local tests and Step 24 §5.1 mandatory tests passing.
5. Three-party approval obtained for the specific function.
6. No secrets in source, lockfile, or git history.

### 8.2 Rollback Semantics

Rollback = redeploy the last-known-good artifact. The prior version artifact must be retained in CI/CD until the new version is proven stable.

### 8.3 No Deployment Under This Step

No deployment to any cloud environment is authorized under Step 27. Deployment is a future step requiring a separate three-party approval.

---

## Section 9 — Swift API Surface

### 9.1 Operations Requiring Edge Function Calls (`supabase.functions.invoke`)

All invocations use POST (Supabase Swift SDK default).

| Operation | Function Name | Request Body | Response |
|---|---|---|---|
| Request upload URL | `upload-authorize` | `{ "case_id": "...", "content_type": "...", "declared_size_bytes": 1234 }` | JSON (§9.3) |
| Complete upload | `upload-complete` | `{ "upload_token": "..." }` | JSON (§9.4) |
| Serve image | `media-serve` | `{ "case_id": "..." }` | Binary WebP bytes |
| Delete account | `account-delete-complete` | *(empty)* | JSON `{"status":"complete"}` |

### 9.2 Operations Using Direct RPC (`supabase.rpc`)

All use the authenticated user's JWT. Parameter names are the exact V4 PostgreSQL function parameter names.

| Operation | V4 RPC Name | Parameters |
|---|---|---|
| Submit a guess | `submit_guess` | `p_case_id: UUID, p_investigation_id: UUID, p_race: String, p_guess_text: String, p_idempotency_key: String, p_client_submitted_at: Date?` |
| Launch a case | `launch_case` | `p_case_id: UUID, p_actor_id: UUID, p_group_ids: [UUID], p_duration_seconds: Int` |
| Reveal a case (poster) | `reveal_case` | `p_case_id: UUID` |
| Cancel a case (poster) | `cancel_case` | `p_case_id: UUID, p_reason: String?` |
| Add a clue | Direct INSERT into `public.clues` | RLS enforces poster-only |
| Create a group | `create_group` | (per V4 signature) |
| Create invite | `create_group_invite` | (per V4 signature) |
| Redeem invite | `redeem_group_invite` | (per V4 signature) |
| Revoke invite | `revoke_group_invite` | (per V4 signature) |
| Transfer ownership | `transfer_group_ownership` | (per V4 signature) |
| Post comment | Direct INSERT into `public.comments` | RLS enforces group membership |
| Soft-delete comment | `soft_delete_comment` | (per V4 signature) |
| Post reaction | Direct INSERT into `public.reactions` | RLS enforces group membership |
| Remove reaction | Direct DELETE from `public.reactions` | RLS enforces ownership |
| Report content | `report_content` | (per V4 signature; authenticated) |

**Notes:**
- `reveal_case(p_case_id)` — authenticated; poster only; requires `state = 'locked'`. Verified in V4 at line 2625; grant at line 3269.
- `cancel_case(p_case_id, p_reason)` — authenticated; poster only; valid in `draft`, `ready`, `launched`. Verified in V4 at line 2720; grant at line 3267.
- `submit_guess` returns a UUID (the new `guess_attempt` ID).
- `launch_case` takes `p_actor_id` explicitly (V4 verifies it matches the JWT sub claim internally).

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

### 9.5 Media-Serve Swift Invocation

```swift
let response = try await supabase.functions.invoke(
    "media-serve",
    options: FunctionInvokeOptions(body: ["case_id": caseId.uuidString])
)
// response.data contains raw WebP bytes
```

`case_id` is in the POST body, not a URL path parameter.

### 9.6 Error Handling

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
| S3 env var contract | Defined in Gate 4: `S3_ENDPOINT`, `S3_REGION`, `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY`, `S3_BUCKET`. Path-style = true. |
| S3 connection on forkensics-dev | Gate 4 preflight test required before Step A. |
| pg_cron / pg_net availability | Gate 3 preflight (fully local). Hosted validation is a separate step. |
| `magick-wasm` viability at 10 MB | Gate 2: Phase A (local functional) + Phase B (hosted, separate cloud approval). |
| Decompression-bomb protection | Pre-decode header parse (pixel count check) before full raster decode. Defined in §5.2 step 5. |
| Metadata stripping verification | Structural parse of output WebP bytes; not assumption-based. Defined in §5.2 step 6. |
| `get_media_serve_authorization` grant | Confirmed service_role only (V4 line 3313–3314). |
| `submit_guess` mechanism | `supabase.rpc("submit_guess", ...)` with exact V4 parameter names. Direct INSERT revoked in V4. |
| `launch_case` in Swift table | Added to §9.2 with exact parameter names. |
| `reveal_case` / `cancel_case` V4 status | Both verified in V4. Added to §9.2. |
| Moderation endpoint | Deferred; hard gate documented in §5.8. |
| `media-serve` GET vs POST | Resolved: POST via `functions.invoke`; `case_id` in JSON body; binary WebP response. |
| Idle timeout vs URL expiry | `account-delete-complete` never waits; returns 409 immediately. |
| Sanitized re-entry buffer | No in-memory buffer on re-entry. Download display from storage; verify WebP; compute SHA-256 from storage bytes. |
| `advance_upload_session_sanitized` RPC ambiguity | Re-resolve session after error; branch on resolved state. Defined in §5.2 step 9. |

---

## Section 11 — Approval Record

| Party | Status | Notes |
|---|---|---|
| Claude | Approved | Rev 3 authored by Claude; all 8 Rev 2 blockers addressed |
| Codex | Pending | |
| Bill | Pending | |

To approve: reply with `APPROVED: Step 27 Rev 3 — Edge Function Implementation Plan`.

Implementation does not begin until all three parties have approved.
