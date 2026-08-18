# Step 24 Proposal — Rev 2 — Edge Function Architecture and Contracts

**Status:** Pending review (Claude → Codex/GPT → Bill approval)
**Governance gate:** Bill must type `APPROVED: Step 24 — Edge Function Architecture and Contracts` before any Edge Function code is written.

**Scope:** Architecture decisions and binding contracts only. No TypeScript, no Deno code, no deployment. Implementation follows in separate per-function steps.

**Changes from Rev 1:** All six GPT correction categories applied — V1 interface corrections, upload V2 decision, scheduler renamed and corrected, account deletion state machine corrected, auth/visibility tightened, test contracts expanded.

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
| `upload-complete` | Read original from private storage, re-encode, strip EXIF/GPS, write re-encoded copy, delete original, write `public.media_objects` + `private.media_storage_keys`, set `challenges.media_object_id` — all atomically |
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

V1 contains no upload-token table, no upload session state, and no processing-idempotency infrastructure. The `upload-authorize` and `upload-complete` contracts as proposed in Rev 1 cannot be implemented from V1 alone.

**Decision: add a V2 migration** containing upload-session and finalization infrastructure before implementing the upload Edge Functions.

The V2 migration will be a separate governance step (Step 25) covering:
- A table to record upload sessions: `challenge_id`, `uploader_id`, `upload_token`, `storage_path`, `content_type`, `declared_size_bytes`, `expires_at`, `status` (`pending` | `complete` | `failed`)
- A service-role-only function to create an upload session (called by `upload-authorize`)
- A service-role-only function to finalize an upload session (called by `upload-complete`), which atomically: inserts into `public.media_objects`, inserts into `private.media_storage_keys`, sets `challenges.media_object_id`, marks the session complete
- A service-role-only function to expire stale sessions

The V2 migration must go through the full three-party governance cycle before any upload Edge Function is implemented.

---

## Section 3 — Cross-Cutting Contracts

These rules apply to every Edge Function without exception.

### 3.1 Authentication

**`verify_jwt` setting:**
- All Edge Functions except `scheduled-close` deploy with `verify_jwt = true`. When the Supabase gateway rejects a JWT before the function runs, the gateway returns its own `401` response. That response does not follow the Forkensics error envelope — this is expected and documented here. The function's own error envelope applies only to errors the function itself produces.
- `scheduled-close` deploys with `verify_jwt = false`. It uses a separate verified cron credential stored in Supabase Vault (see Section 5).

For functions with `verify_jwt = true`, after gateway JWT verification succeeds:
1. Extract `sub` claim (user UUID). If absent or empty → `401 FK_UNAUTHENTICATED`.
2. Confirm a row exists in `public.profiles` where `id = sub` AND `is_active = true` AND `onboarding_complete = true`. If not → `403 FK_FORBIDDEN`.

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

- A retry of a successfully completed operation returns `200 OK` with the original result and status `"complete"`. It does not return `409`.
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
- `account-delete-complete` partial failure → account remains in `database_prepared` state; user can retry; private photos are never abandoned (see Section 5)

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
1. Profile active + onboarding complete (Section 3.1).
2. `challenge_id` exists and caller is the poster — otherwise `404 FK_NOT_FOUND`.
3. Challenge state is `draft` — otherwise `409 FK_WRONG_STATE`.
4. `content_type` is `image/jpeg` or `image/webp` — otherwise `400 FK_INVALID_CONTENT_TYPE`.
5. `declared_size_bytes` ≤ 10,485,760 — otherwise `400 FK_FILE_TOO_LARGE`. (Actual size is re-validated in `upload-complete`.)

**Action:**
1. Generate a signed upload URL for `challenges/{challenge_id}/original` in `game-media`, 5-minute expiry (service role).
2. Create an upload session row via the V2 finalization function: `challenge_id`, `uploader_id`, `upload_token` (new UUID), `storage_path`, `content_type`, `declared_size_bytes`, `expires_at = now() + 5 minutes`.
3. Any previous pending session for this `challenge_id` is invalidated.

**Response `200 OK`:**
```json
{
  "signed_url": "<url>",
  "upload_token": "<uuid>",
  "expires_at": "<ISO 8601>"
}
```

**Idempotency:** Not idempotent — each call invalidates the previous session and issues a new signed URL.

**Logging:** `challenge_id`, `user_id`, `content_type`, outcome. NOT signed URL or upload token.

---

### 4.2 `upload-complete`

**Purpose:** Confirm upload, validate the actual stored file, re-encode with EXIF/GPS removal, delete the original, and atomically record the media object.

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
1. Profile active + onboarding complete (Section 3.1).
2. `upload_token` exists, is not expired, belongs to this `challenge_id`, and was created by the authenticated user — otherwise `400 FK_INVALID_TOKEN`.
3. Challenge state is `draft` — otherwise `409 FK_WRONG_STATE`.

**Action (in order):**
1. Read the original file from `challenges/{challenge_id}/original` (service role). If absent → `404 FK_NOT_FOUND`.
2. Sniff actual MIME type from file bytes — do not trust client-declared `content_type`. If not `image/jpeg` or `image/webp` → `400 FK_INVALID_CONTENT_TYPE`.
3. Confirm actual stored size ≤ 10,485,760 bytes. If over → `400 FK_FILE_TOO_LARGE`.
4. Re-encode to WebP; strip all EXIF, GPS, and embedded metadata. If re-encoding fails → `422 FK_PROCESSING_FAILED`.
5. Write re-encoded file to `challenges/{challenge_id}/display.webp` (service role).
6. Call the V2 atomic finalization function (service role, BYPASSRLS) which in a single transaction:
   - Inserts into `public.media_objects` (`uploader_id`, `status = 'ready'`)
   - Inserts into `private.media_storage_keys` (`storage_key = 'challenges/{challenge_id}/original'`, `re_encoded_storage_key = 'challenges/{challenge_id}/display.webp'`)
   - Sets `challenges.media_object_id` to the new `media_objects.id`
   - Marks the upload session as `complete`
   If the transaction fails → `500 FK_INTERNAL`; the re-encoded file may need cleanup.
7. Delete the original file `challenges/{challenge_id}/original` (service role). If deletion fails, log the failure and continue — the original will be collected during account deletion.

**Response `200 OK`:**
```json
{
  "media_object_id": "<uuid>",
  "status": "ready"
}
```

**Idempotency:** If upload session is already `complete` for this `challenge_id`, return `200 OK` with `FK_ALREADY_COMPLETE` in the status field and the existing `media_object_id`. Do not re-encode.

**Concurrent uploads:** If two calls arrive simultaneously for the same `challenge_id`, the finalization transaction serializes them. The second will fail the session lookup (session already marked complete) and return `409 FK_ALREADY_COMPLETE`.

**Logging:** `challenge_id`, `media_object_id`, actual MIME type, actual size, re-encoding outcome, original-deletion outcome. NOT storage paths.

---

### 4.3 `media-serve`

**Purpose:** Proxy the re-encoded challenge image to an authorized viewer. Never expose storage paths or signed URLs to the client.

**Method / Path:** `GET /media/{challenge_id}`

**`verify_jwt`:** `true`

**Authorization checks (in order):**
1. Profile active + onboarding complete (Section 3.1).
2. Use `private.is_challenge_group_member(challenge_id)` — returns true if the caller is a member of the challenge's group. If false or challenge does not exist → `404 FK_NOT_FOUND` (no probing).
3. `challenges.media_object_id` is not null and `media_objects.status = 'ready'`. If not → `404 FK_NOT_FOUND`.

**Action:**
- Read `challenges/{challenge_id}/display.webp` from private `game-media` storage (service role).
- Stream bytes to client with `Content-Type: image/webp`.
- Never read or serve `challenges/{challenge_id}/original`.

**Response `200 OK`:** Binary image stream (`image/webp`)

**Cache headers:** `Cache-Control: private, max-age=3600` — images are stable once re-encoded.

**Idempotency:** Read-only, naturally idempotent.

**Logging:** `challenge_id`, `user_id`, outcome. NOT the storage path.

---

### 4.4 `scheduled-close`

**Purpose:** Lock and then reveal all challenges whose `deadline_at` has passed.

**Trigger:** Supabase pg_cron, every 2 minutes.

**`verify_jwt`:** `false`

**Authentication:** Verified cron credential stored in Supabase Vault. On invocation, the function reads the expected credential from Vault and compares it to the credential in the `Authorization` header. Any request that fails this check → `401` (not the standard error envelope, since this is not a user-facing endpoint). External HTTP requests without the Vault credential are rejected.

**Action:**

Pass 1 — lock active challenges past deadline:
1. Query `public.challenges WHERE state = 'active' AND deadline_at <= now()`.
2. For each: call `public.lock_challenge(uuid)` (service role). `lock_challenge` raises if the challenge is already locked — catch this per-row, log the challenge ID and error code, continue.

Pass 2 — reveal locked challenges:
1. Query `public.challenges WHERE state = 'locked'` (these are challenges locked in Pass 1 or in a previous run that were not yet revealed).
2. For each: call `private.reveal_challenge_service(uuid)` (service role). Catch per-row errors — log and continue.

The two-pass structure ensures that challenges locked in a previous failed run are caught and revealed in the next run.

**Response `200 OK`:**
```json
{
  "locked_count": 3,
  "revealed_count": 3,
  "skipped_count": 0,
  "errors": [
    { "challenge_id": "<uuid>", "pass": "lock"|"reveal", "error_code": "..." }
  ]
}
```

**Idempotency:** Pass 1 will raise on already-locked challenges (caught per-row). Pass 2 handles already-revealed challenges the same way. Safe to run multiple times.

**Logging:** `locked_count`, `revealed_count`, `skipped_count`, any error codes and challenge IDs. NOT challenge content, canonical answers, or any guess data.

---

### 4.5 `account-delete-complete`

**Purpose:** Complete account deletion after the user provides final confirmation — delete storage objects, delete the auth account, and finalize the database deletion record.

**Method / Path:** `POST /account-delete-complete`

**`verify_jwt`:** `true`

**Request body:** *(none — caller identity comes from the JWT)*

**Authentication:** The authenticated user deletes their own account. No additional token.

**Authorization check:**
1. Profile active + onboarding complete (Section 3.1). (A user can still delete their account even if `is_active = false` — reconsider: a deactivated user should still be able to complete deletion. This edge case is flagged for three-party review.)

**Action (in order — stop on failure as specified):**

1. Call `private.prepare_account_deletion(user_id)` (service role). This anonymizes the profile and marks the deletion record as `database_prepared`. If it fails → `500 FK_INTERNAL`.
2. Call `private.get_storage_keys_for_deletion(user_id)` (service role). Returns `TABLE(media_object_id uuid, storage_key text)`.
3. For each storage key: delete the object from `game-media` (service role). Track successes and failures.
4. If **any** storage deletion fails:
   - Call `private.record_deletion_failure(user_id, error_text)` (service role).
   - Return `422 FK_PROCESSING_FAILED` with body `{ "error": { "code": "FK_PROCESSING_FAILED", "message": "Storage cleanup incomplete. Retry to continue deletion." } }`.
   - **Stop here.** Do not delete the auth account. The user can still authenticate and retry.
5. Delete the `auth.users` row for this user (Admin API, service role).
6. Call `private.mark_auth_deleted(user_id)` (service role).
7. Call `private.mark_storage_cleaned(user_id)` (service role).
8. Return `200 OK`.

**Response `200 OK`:**
```json
{ "status": "complete" }
```

**Recovery worker (required before this function is deployed):** A separate recovery mechanism is needed for the rare case where step 5 (auth deletion) succeeds but steps 6–7 fail. In this state, the user no longer exists in `auth.users` and cannot authenticate to retry. The recovery worker runs on a schedule, finds deletion records in `auth_deleted` state whose `mark_auth_deleted` was not called, and completes steps 6–7 using service role. This worker is part of the `account-delete-complete` deployment, not a separate step.

**Idempotency:** If the deletion record is already in `auth_deleted` or `storage_cleaned` state, return `200 FK_ALREADY_COMPLETE`. Do not re-attempt auth deletion.

**Logging:** `user_id`, `storage_key_count`, `deleted_count`, `failed_count`, deletion record status at each step. NOT storage paths or file content.

---

## Section 5 — Contract Test Requirements

### 5.1 Local Contract Tests

Each function gets a dedicated contract test file. Tests must cover:

**Authentication and authorization (all functions):**
- Missing JWT → `401` (or gateway 401 — document which)
- Expired JWT → `401`
- Valid JWT, `is_active = false` → `403 FK_FORBIDDEN`
- Valid JWT, `onboarding_complete = false` → `403 FK_FORBIDDEN`

**Existence and probing (challenge-scoped functions):**
- Nonexistent `challenge_id` → `404 FK_NOT_FOUND`
- Valid `challenge_id`, caller not authorized → same `404 FK_NOT_FOUND` (verify codes are identical)

**Input validation (`upload-authorize`, `upload-complete`):**
- Missing `challenge_id` → `400 FK_INVALID_INPUT`
- Invalid `content_type` → `400 FK_INVALID_CONTENT_TYPE`
- MIME type sniffed from bytes does not match declared type → `400 FK_INVALID_CONTENT_TYPE`
- Actual stored file size exceeds 10 MB → `400 FK_FILE_TOO_LARGE`
- Expired upload token → `400 FK_INVALID_TOKEN`
- Already-used upload token → `400 FK_INVALID_TOKEN`

**State machine (`upload-authorize`, `upload-complete`, `media-serve`):**
- Challenge not in `draft` state → `409 FK_WRONG_STATE`
- `media_objects.status != 'ready'` → `404 FK_NOT_FOUND`

**Idempotency:**
- Second `upload-complete` for same `challenge_id` after success → `200 FK_ALREADY_COMPLETE` with same `media_object_id`
- Concurrent `upload-complete` for same `challenge_id` → one succeeds, one returns `409 FK_ALREADY_COMPLETE`

**Storage behavior (`upload-complete`):**
- Re-encoding produces WebP output
- Original file is deleted after successful re-encoding
- `public.media_objects`, `private.media_storage_keys`, and `challenges.media_object_id` are set atomically

**Draft-photo access (`media-serve`):**
- Group member who is not the poster cannot access image while challenge is in `draft` state → `404 FK_NOT_FOUND`

**Scheduler (`scheduled-close`):**
- Request without Vault credential → `401`
- Challenge with `deadline_at` in the past and `state = 'active'` is locked and then revealed
- Challenge already in `locked` state (locked in a prior run) is revealed without error
- Challenge already in `revealed` state is skipped without error
- Per-row error does not abort the batch

**Account deletion (`account-delete-complete`):**
- Happy path: all storage deleted, auth deleted, records updated → `200 complete`
- Storage deletion failure for one object → `422 FK_PROCESSING_FAILED`, auth account not deleted
- Retry after storage failure: storage re-attempted, continues to auth deletion on success
- Retry after auth deletion (already complete): → `200 FK_ALREADY_COMPLETE`
- Recovery worker: deletion record in `auth_deleted` state without `mark_auth_deleted` → worker completes steps 6–7

**Error format (all functions):**
- All function-produced errors match `{ "error": { "code": "FK_...", "message": "..." } }`

### 5.2 Hosted Smoke Tests (dev only — never prod)

After each function is deployed to `forkensics-dev`:
- Function is reachable and returns a response
- Unauthenticated request → `401`
- Authenticated request with invalid input → `400`
- Happy path → expected status code

Smoke tests must not create permanent data. Any test challenge or media object created during smoke testing is cleaned up within the same test run.

### 5.3 What Contract Tests Must Never Do

- Call `reveal_challenge()` or `private.reveal_challenge_service()` on a real challenge
- Assert on or log canonical answers, canonical restaurant names, or canonical city
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

## Section 7 — Open Question Flagged for Three-Party Review

**Account deletion and `is_active = false`:** Should a user whose `is_active` flag is `false` (but whose account still exists) be permitted to call `account-delete-complete`? If `is_active = false` blocks `FK_FORBIDDEN` unconditionally, a deactivated user could never complete their own deletion. The current check in Section 3.1 applies this restriction uniformly — but account deletion may need a carve-out. This must be resolved before implementing `account-delete-complete`.

---

## Section 8 — Out of Scope for Step 24

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
- [ ] V2 migration decision agreed (upload-session infrastructure)
- [ ] All five function contracts agreed: method, auth, request, action, response, error codes, idempotency, logging
- [ ] `scheduled-close` two-pass design agreed
- [ ] Account deletion state machine and stop-on-storage-failure rule agreed
- [ ] Recovery worker requirement agreed
- [ ] `is_active` carve-out question resolved
- [ ] Cross-cutting rules agreed: auth, error envelope, existence probing, logging prohibitions, AI failure safety
- [ ] Contract test coverage list agreed
- [ ] Deployment sequence agreed
- [ ] No Edge Function code written before approval
