# Step B — `upload-complete` + `upload-cleanup-worker` Proposal Rev 3

**Date:** 2026-08-18  
**Status:** DRAFT — Awaiting three-party approval (Claude + Codex + Bill)

**Supersedes:** Rev 2 (2026-08-18) — addresses all five Codex blockers from Rev 2 review.

**Governance gate:** All three parties must approve Phase 1 before any TypeScript is written.  
All three parties must approve Phase 2 before any forkensics-dev deployment operation.  
All three parties must approve Phase 2B before the pg_cron extension migration is applied.

**Magic words:**
- Phase 1: `APPROVED: Step B Rev 3 — Phase 1`
- Phase 2: `APPROVED: Step B Rev 3 — Phase 2`
- Phase 2B (pg_cron scheduling): `APPROVED: Step B Rev 3 — Phase 2B`

**Security constraints (permanent — inherited):**
- `CF_ACCESS_CLIENT_ID`, `CF_ACCESS_CLIENT_SECRET`: never in client code, never in the repo, **never sent to Claude, Codex, or any AI/chat system**.
- `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`: same constraint.
- Three-party governance: Bill + Claude + Codex must all approve before any TypeScript is written or any cloud operation is performed.

---

## §0 Changes from Rev 2

Five changes, each addressing a Codex blocker:

| # | Blocker | Change |
|---|---|---|
| C-1 | Phase 2B CRON_SECRET mechanism deferred / unresolved | §10.2: Vault-based retrieval fully specified; secret never in migration file; `postgres` permissions documented; Vault pre-condition made explicit |
| C-2 | Cron verification proves SQL ran, not that http POST returned 2xx | §10.2 P2B-V3: verification now captures `net.http_post` request ID and correlates with `net.http_responses.status_code`; credential leak check added |
| C-3 | Rollback used `DROP EXTENSION pg_cron` — unsafe for unrelated jobs | §10.2 rollback now unschedules only `upload-cleanup-worker`; extension removal declared out of scope and requiring separate approval |
| C-4 | Static checks omitted three test files | §8: `deno check`, `deno fmt --check`, `deno lint` rows added for `upload-complete.test.ts`, `upload-complete.integration.test.ts`, `upload-cleanup-worker.test.ts` |
| C-5 | `CF_WORKER_URL` validated only by protocol; arbitrary HTTPS host permitted | §4 URL validation now requires exact hostname `forkensics-image-transform-dev.billmags.workers.dev` and pathname `''` or `'/'` |

---

## §1 Baseline Documents

| Document | Role |
|---|---|
| Step 27 Rev 5 §5.2 | `upload-complete` behavioral contract (authoritative) |
| Step 27 Rev 5 §5.3 | `upload-cleanup-worker` behavioral contract (authoritative) |
| CF-Worker-Prod-Proposal-Rev3 | Image-transform Worker contract; forkensics-dev execution evidence |
| Step 24 Rev 10 §5.1 | Mandatory test requirements |
| Step A Rev 9 | Frozen `upload-authorize` baseline; shared module inventory |

**CF Worker deployment status (confirmed 2026-08-17):**  
`forkensics-image-transform-dev.billmags.workers.dev` — deployed and live.  
Supabase secrets `CF_ACCESS_CLIENT_ID`, `CF_ACCESS_CLIENT_SECRET`, `CF_WORKER_URL` must be present in forkensics-dev before Phase 2 deployment.

---

## §2 Architectural Change: CF Worker Integration

Step 27 Rev 5 was written when `upload-complete` was expected to run magick-wasm inline. The approved architecture delegates image transformation to the `forkensics-image-transform-dev` Cloudflare Worker. This changes the Edge Function's responsibility materially.

**CF Worker contract (from CF-Worker-Prod-Proposal-Rev3 and CF-W-7 probe):**

| Item | Value |
|---|---|
| Endpoint | `POST {CF_WORKER_URL}/transform/originals/{media_uuid}` |
| Auth headers | `CF-Access-Client-Id`, `CF-Access-Client-Secret` |
| Worker reads | `originals/{media_uuid}` from R2 |
| Worker writes | `display/{media_uuid}.webp` to R2 |
| Worker returns (200) | `{"displayKey":"display/{media_uuid}.webp","sha256":"<64 lowercase hex chars>","bytes":<int, 0 < bytes ≤ 5 242 880>}` |
| Worker 404 | Original absent in R2 |
| Worker 422 | Input too large / dimension gate / pixel area gate / transform failed |
| Worker 401/403 | CF Access misconfiguration → treat as FK_INTERNAL |
| Worker 5xx | Transient failure → treat as FK_INTERNAL |

**What the CF Worker does NOT do:** delete the original. Deletion of `originals/{uuid}` from R2 remains the Edge Function's responsibility.

**media_uuid derivation:** `session.original_storage_path` = `originals/{uuid}`. Strip the `originals/` prefix to obtain `{uuid}` for the CF Worker URL path parameter.

---

## §3 New Files

### Phase 1 — TypeScript implementation

| File | Description |
|---|---|
| `supabase/functions/_shared/cf.ts` | CF Worker HTTP client: POST transform, validate response, map errors to FK codes |
| `supabase/functions/_shared/cf.test.ts` | Unit tests for `cf.ts` (Deno) |
| `supabase/functions/upload-complete/index.ts` | Edge Function implementation |
| `supabase/functions/upload-complete/upload-complete.test.ts` | Unit tests (Deno) |
| `supabase/functions/upload-complete/upload-complete.integration.test.ts` | Integration tests (Deno) |
| `supabase/functions/upload-cleanup-worker/index.ts` | Cleanup worker Edge Function |
| `supabase/functions/upload-cleanup-worker/upload-cleanup-worker.test.ts` | Unit tests (Deno) |

Existing `_shared/` modules used without modification: `context.ts`, `crypto.ts`, `dbClient.ts`, `errors.ts`, `log.ts`, `s3.ts`.

---

## §4 `_shared/cf.ts` — CF Worker Client Module

```typescript
// cf.ts — Cloudflare image-transform Worker client
// Reads CF_ACCESS_CLIENT_ID, CF_ACCESS_CLIENT_SECRET, CF_WORKER_URL from env.
// Never logs credential values.
```

**Exports:**

`callImageTransform(mediaUuid: string): Promise<CfTransformResult>`

Where:
```typescript
type CfTransformResult =
  | { ok: true;  displayKey: string; sha256: string; bytes: number }
  | { ok: false; fkCode: FkErrorCode; workerStatus: number };
```

**Env validation:** At call time, if any of `CF_ACCESS_CLIENT_ID`, `CF_ACCESS_CLIENT_SECRET`, or `CF_WORKER_URL` is absent or empty, return `ok: false, fkCode: "FK_INTERNAL"` immediately (never throw).

**URL validation:** `CF_WORKER_URL` is validated at call time before the request is issued. All rules are fail-closed (any failure → `ok: false, fkCode: "FK_INTERNAL"`):

| Rule | Requirement |
|---|---|
| Parseable | `new URL(CF_WORKER_URL)` does not throw |
| Protocol | `parsed.protocol === 'https:'` exactly |
| Hostname | `parsed.hostname === 'forkensics-image-transform-dev.billmags.workers.dev'` exactly |
| Pathname | `parsed.pathname === '' \|\| parsed.pathname === '/'` |
| Username | `parsed.username === ''` |
| Password | `parsed.password === ''` |
| Search (query) | `parsed.search === ''` |
| Hash (fragment) | `parsed.hash === ''` |

Rationale: CF Access credentials (`CF-Access-Client-Id`, `CF-Access-Client-Secret`) are attached to every request. Allowing any HTTPS hostname would forward credentials to an arbitrary origin on misconfiguration. The approved origin is pinned.

**Timeout and cancellation:** Instantiate `AbortController` before `fetch`. Pass `signal: controller.signal` in fetch options. Set a 50-second timeout via `setTimeout` — explicitly below the Edge Function wall-clock limit (60 s) and far below the processing lease (10 min), leaving headroom for error handling and DB operations after a timeout. Call `clearTimeout` in a `finally` block to prevent timer leaks. Treat `AbortError` the same as any `fetch` throw: `ok: false, fkCode: "FK_INTERNAL"`.

**Bounded response body:** After receiving any response, read at most 4 096 bytes. If the body stream returns more than 4 096 bytes, discard and return `ok: false, fkCode: "FK_INTERNAL"`.

**Response-status mapping:**

| Worker HTTP status | Body condition | CfTransformResult |
|---|---|---|
| 200 | all three validations pass (see below) | `ok: true` |
| 200 | any validation failure | `ok: false, fkCode: "FK_INTERNAL"` |
| 404 | any | `ok: false, fkCode: "FK_NOT_FOUND"` |
| 422 | any | `ok: false, fkCode: "FK_PROCESSING_FAILED"` |
| 401 | any | `ok: false, fkCode: "FK_INTERNAL"` |
| 403 | any | `ok: false, fkCode: "FK_INTERNAL"` |
| any other | any | `ok: false, fkCode: "FK_INTERNAL"` |
| fetch throws / AbortError (timeout) | — | `ok: false, fkCode: "FK_INTERNAL"` |

**200 response-body validation** (all three must pass; any failure → `ok: false, fkCode: "FK_INTERNAL"`):
- `displayKey` is a non-empty string. (Equality with `session.display_storage_path` is enforced by the caller in `upload-complete`, not here, because `cf.ts` has no session state.)
- `sha256` matches `/^[0-9a-f]{64}$/` exactly.
- `bytes` satisfies `Number.isInteger(bytes) && bytes > 0 && bytes <= 5_242_880`.

**No credential logging:** `CF_ACCESS_CLIENT_ID` and `CF_ACCESS_CLIENT_SECRET` must never appear in any log output, error message, or response body.

---

## §5 `upload-complete` — Implementation Plan

### §5.1 Environment variables

| Variable | Source |
|---|---|
| `CF_ACCESS_CLIENT_ID` | Supabase secret (forkensics-dev) |
| `CF_ACCESS_CLIENT_SECRET` | Supabase secret (forkensics-dev) |
| `CF_WORKER_URL` | Supabase secret (forkensics-dev) |
| `R2_ACCESS_KEY_ID` | Supabase secret (already set — Phase 2b) |
| `R2_SECRET_ACCESS_KEY` | Supabase secret (already set — Phase 2b) |
| `R2_ENDPOINT` | Supabase secret (already set — Phase 2b) |
| `R2_BUCKET` | Supabase secret (already set — Phase 2b) |
| `SUPABASE_URL` | Auto-injected |
| `SUPABASE_SERVICE_ROLE_KEY` | Auto-injected |
| `SUPABASE_ANON_KEY` | Auto-injected |

### §5.2 Idempotency branch (resolve session from upload_token)

| Session state | Action |
|---|---|
| `complete` | `200 {"status":"pending_review","media_object_id":"<uuid>","replaced_media_object_id":"<uuid\|null>","already_complete":true}` |
| `processing` | `202 {"status":"processing"}` |
| `sanitized` | Proceed to **§5.4 Sanitized re-entry** (§5.4 SR-1 handles original deletion) |
| `pending` | Proceed to **§5.3 Happy path** |
| Any other / no row | `400 FK_INVALID_TOKEN` |

### §5.3 Happy path (status `pending`)

**Step 1.** `advance_upload_session_processing(session_id, user_id, '10 minutes')`. Failure → `400 FK_INVALID_TOKEN`.

**Step 2.** Extract `media_uuid` from `session.original_storage_path` (strip `originals/` prefix).

**Step 3.** Call `cf.callImageTransform(media_uuid)`.
- `ok: false, fkCode: "FK_NOT_FOUND"` → `fail_upload_session('FK_NOT_FOUND')`; `404`.
- `ok: false, fkCode: "FK_PROCESSING_FAILED"` → `fail_upload_session('FK_PROCESSING_FAILED')`; `422`.
- `ok: false, fkCode: "FK_INTERNAL"` → `fail_upload_session('FK_INTERNAL')`; `500`.

**Step 4.** CF Worker returned `ok: true`. Validate (all three assertions; any failure → `fail_upload_session('FK_INTERNAL')`; `500`):
- `result.displayKey === session.display_storage_path` — guards against the Worker writing to the wrong R2 key.
- `result.sha256` matches `/^[0-9a-f]{64}$/` — belt-and-suspenders; also checked inside `cf.ts`.
- `Number.isInteger(result.bytes) && result.bytes > 0 && result.bytes <= 5_242_880` — per CF-W-7 probe specification.

Capture `displayKey`, `sha256`, `bytes`. The original (`originals/{uuid}`) remains in R2 — the Worker did not delete it.

**Step 5.** `check_upload_session_lease(session_id)`. Returns false → delete original (`originals/{uuid}`) from R2; `422 FK_PROCESSING_FAILED`. Do NOT call `fail_upload_session`. Do NOT call `advance_upload_session_sanitized`. (Display file `display/{uuid}.webp` exists in R2 — leave for cleanup worker.)

**Step 6.** `advance_upload_session_sanitized(session_id)`.

**Step 6 RPC-error handling:** The RPC may have committed while the client received an error. After any error from step 6, re-resolve the session state:

| Re-resolved state | Action |
|---|---|
| `sanitized` | Proceed to **§5.4 Sanitized re-entry** (§5.4 SR-1 handles original deletion before finalization) |
| `complete` | Finalization already committed by a concurrent invocation. Attempt original deletion from R2 (idempotent — absent = no-op); return `200` idempotent |
| `processing` (RPC did not commit) | Delete display (`display/{uuid}.webp`) from R2; delete original (`originals/{uuid}`) from R2; `fail_upload_session('FK_INTERNAL')`; `500` |
| Other state or no row | Delete display; delete original; `500 FK_INTERNAL` |

**Step 7.** Delete original (`originals/{uuid}`) from R2. Retry up to 2 times. All attempts fail → delete display (`display/{uuid}.webp`) from R2; `fail_upload_session('FK_PROCESSING_FAILED')`; `422`.

**Finalization:**

**Step 8.** Call `finalize_upload_session(session_id, sha256)` using the `sha256` from the CF Worker response.

**Finalization error handling:** If `finalize_upload_session` raises, capture the original error code, then re-resolve the session:

| Re-resolved state | Action |
|---|---|
| `complete` | Finalization committed despite the error; return `200` idempotent |
| `sanitized` | Finalization did not commit; map original error code: `FK_INVALID_HASH` → `422 FK_PROCESSING_FAILED`; `FK_WRONG_STATE` (case not draft) → `409 FK_WRONG_STATE`; transport / unknown → `500 FK_INTERNAL` (client retries via sanitized branch) |
| Other state or no row | Fail-closed `500 FK_INTERNAL` |

**Step 9.** Return `200 {"media_object_id":"<uuid>","status":"pending_review"}`.

### §5.4 Sanitized re-entry (fresh invocation — no in-memory buffer)

Entered from the idempotency branch (`sanitized` state on arrival) or from §5.3 step 6 re-resolve (`sanitized`). The CF Worker wrote `display/{uuid}.webp` to R2 on the prior invocation. The original (`originals/{uuid}`) may still exist in R2 if step 7 was not reached on the prior invocation.

**SR-1.** Delete original (`originals/{uuid}`) from R2. `DeleteObject` is idempotent (absent = no-op). Retry up to 2 times on a non-404 failure. All attempts fail → delete display (`display/{uuid}.webp`) from R2; `fail_upload_session('FK_PROCESSING_FAILED')`; `422`.

**SR-2.** Download `display/{uuid}.webp` from R2 (path = `session.display_storage_path`). Absent → `fail_upload_session('FK_PROCESSING_FAILED')`; `422`.

**SR-3.** Verify magic bytes are valid WebP (`RIFF....WEBP`: bytes 0–3 = `52 49 46 46`, bytes 8–11 = `57 45 42 50`). Invalid → delete display from R2; `fail_upload_session('FK_PROCESSING_FAILED')`; `422`.

**SR-4.** Compute SHA-256 of downloaded bytes (lowercase hex, 64 chars).

**SR-5.** Call `finalize_upload_session(session_id, sha256_hash)`. Apply identical finalization error handling as §5.3 step 8.

**SR-6.** Return `200 {"media_object_id":"<uuid>","status":"pending_review"}`.

---

## §6 `upload-cleanup-worker` — Implementation Plan

**Contract:** Step 27 Rev 5 §5.3 (unchanged). Authentication: constant-time `X-Forkensics-Cron-Secret` check. Deployed simultaneously with `upload-complete` in Phase 2. Scheduling via pg_cron is Phase 2B (see §10.2).

**Three parts:**

**Part 1 — Upload session cleanup:**
1. `claim_cleanup_sessions(worker_id, '15 minutes')`.
2. For each: delete `original_storage_path` and `display_storage_path` from R2 (absent = no-op). Both succeed → `mark_session_cleaned(session_id, cleanup_claim_token)`. Any fail → log; do not mark; retry next run.

**Part 2 — Superseded media:**
1. `get_superseded_media_to_clean()`. For each: delete `re_encoded_storage_key`. Success → `mark_superseded_media_cleaned`. Failure → log; retry.

**Part 3 — Post-expiry original-path cleanup:**
1. `get_complete_sessions_pending_expiry_cleanup()`.
2. Attempt delete of `original_storage_path`. Absent = no-op.
3. Succeeded or absent → `mark_original_path_post_expiry_cleaned(session_id)`.
4. Failed and present → log; do NOT mark; retry next run.

**CRON_SECRET** — generate a random ≥256-bit secret; store in Supabase Vault (not as a plain Supabase secret) under the name `CRON_SECRET` (see §10.2 for the exact mechanism). Never commit to repo; never log.

---

## §7 Local Test Plan

### `_shared/cf.ts` unit tests (file: `_shared/cf.test.ts`)

- 200 with valid body → `ok: true`, all three fields populated.
- 200: `displayKey` absent → `ok: false, fkCode: "FK_INTERNAL"`.
- 200: `sha256` is 63 hex chars (too short) → `ok: false, fkCode: "FK_INTERNAL"`.
- 200: `sha256` is 64 chars but contains uppercase → `ok: false, fkCode: "FK_INTERNAL"`.
- 200: `bytes` = 0 (boundary — must fail) → `ok: false, fkCode: "FK_INTERNAL"`.
- 200: `bytes` = 5 242 881 (boundary — must fail) → `ok: false, fkCode: "FK_INTERNAL"`.
- 200: `bytes` = 5 242 880 (boundary — must pass) → `ok: true`.
- 200: body exceeds 4 096 bytes → `ok: false, fkCode: "FK_INTERNAL"`.
- 404 → `ok: false, fkCode: "FK_NOT_FOUND"`.
- 422 → `ok: false, fkCode: "FK_PROCESSING_FAILED"`.
- 401, 403, 500, unexpected status → `ok: false, fkCode: "FK_INTERNAL"`.
- `fetch` throws (network error) → `ok: false, fkCode: "FK_INTERNAL"`.
- `AbortController` fires (simulated timeout) → `ok: false, fkCode: "FK_INTERNAL"`.
- Missing `CF_WORKER_URL` → `ok: false, fkCode: "FK_INTERNAL"` (no throw).
- `CF_WORKER_URL` uses `http:` (not HTTPS) → `ok: false, fkCode: "FK_INTERNAL"`.
- `CF_WORKER_URL` uses wrong hostname → `ok: false, fkCode: "FK_INTERNAL"`.
- `CF_WORKER_URL` has pathname other than `''` or `'/'` → `ok: false, fkCode: "FK_INTERNAL"`.
- `CF_WORKER_URL` contains query string → `ok: false, fkCode: "FK_INTERNAL"`.
- `CF_WORKER_URL` contains fragment → `ok: false, fkCode: "FK_INTERNAL"`.
- `CF_WORKER_URL` contains username or password → `ok: false, fkCode: "FK_INTERNAL"`.

### `upload-complete` unit tests (file: `upload-complete/upload-complete.test.ts`)

- Happy path → `200`, `status = "pending_review"`, SHA-256 from CF Worker used.
- CF Worker 404 → `fail_upload_session('FK_NOT_FOUND')`; `404`.
- CF Worker 422 → `fail_upload_session('FK_PROCESSING_FAILED')`; `422`.
- CF Worker 5xx → `fail_upload_session('FK_INTERNAL')`; `500`.
- CF Worker fetch throws → `fail_upload_session('FK_INTERNAL')`; `500`.
- CF Worker 200 but `displayKey` ≠ `session.display_storage_path` → `fail_upload_session('FK_INTERNAL')`; `500`.
- CF Worker 200 but `sha256` invalid format → `fail_upload_session('FK_INTERNAL')`; `500`.
- CF Worker 200 but `bytes` out of range → `fail_upload_session('FK_INTERNAL')`; `500`.
- Idempotent `complete` on entry → `200 already_complete: true`.
- `processing` on entry → `202`.
- Sanitized re-entry (idempotency branch): original present in R2, display present and valid WebP → original deleted (SR-1), SHA-256 computed from display, finalization → `200`.
- Sanitized re-entry: original absent in R2 (already deleted by prior run) → SR-1 no-op; continues to SR-2.
- Sanitized re-entry: original deletion fails all retries → display deleted; session failed; `422`.
- Sanitized re-entry: display absent from R2 → `422`.
- Sanitized re-entry: display present but invalid WebP → display deleted; session failed; `422`.
- Lease expiry (step 5) → original deleted; `422 FK_PROCESSING_FAILED`; no `fail_upload_session`; no sanitized advance.
- Original deletion failure in happy path (step 7, 2 retries) → display deleted; `fail_upload_session('FK_PROCESSING_FAILED')`; `422`.
- Step 6 RPC error: re-resolve `sanitized` → SR-1 original deletion attempted → sanitized re-entry path.
- Step 6 RPC error: re-resolve `processing` → display + original deleted; `fail_upload_session`; `500`.
- Step 6 RPC error: re-resolve `complete` → original deletion attempted (idempotent); return `200` idempotent.
- Finalization commits but response lost (same invocation): re-resolve → `complete`; return `200` idempotent.
- `FK_INVALID_HASH` from DB → re-resolve → `sanitized` → `422 FK_PROCESSING_FAILED`.
- `FK_WRONG_STATE` (case not draft) → re-resolve → `sanitized` → `409 FK_WRONG_STATE`.
- Transport error from finalization → re-resolve → `sanitized` → `500 FK_INTERNAL`.
- Invalid / expired / failed token → `400 FK_INVALID_TOKEN`.
- Missing CF env vars → `500 FK_INTERNAL` (no credential leak in response).
- Step 24 Rev 10 §5.1 mandatory tests (V4 identifier substitutions applied).

### `upload-cleanup-worker` unit tests (file: `upload-cleanup-worker/upload-cleanup-worker.test.ts`)

- Valid `CRON_SECRET` → runs all three parts.
- Invalid / missing `CRON_SECRET` → `401`; no DB access.
- Part 1: deletion succeeds → `mark_session_cleaned` called.
- Part 1: deletion fails → no mark; next run retries.
- Part 2: superseded key deletion → `mark_superseded_media_cleaned`.
- Part 3: original-path deletion → `mark_original_path_post_expiry_cleaned`.
- Part 3: deletion fails → no mark.

---

## §8 Static Checks (Phase 1 gate)

All must pass before Phase 1 is declared complete:

| Check | Command | Requirement |
|---|---|---|
| Type-check | `deno check supabase/functions/_shared/cf.ts` | 0 errors |
| Type-check | `deno check supabase/functions/_shared/cf.test.ts` | 0 errors |
| Type-check | `deno check supabase/functions/upload-complete/index.ts` | 0 errors |
| Type-check | `deno check supabase/functions/upload-complete/upload-complete.test.ts` | 0 errors |
| Type-check | `deno check supabase/functions/upload-complete/upload-complete.integration.test.ts` | 0 errors |
| Type-check | `deno check supabase/functions/upload-cleanup-worker/index.ts` | 0 errors |
| Type-check | `deno check supabase/functions/upload-cleanup-worker/upload-cleanup-worker.test.ts` | 0 errors |
| Format | `deno fmt --check supabase/functions/_shared/cf.ts` | 0 diff |
| Format | `deno fmt --check supabase/functions/_shared/cf.test.ts` | 0 diff |
| Format | `deno fmt --check supabase/functions/upload-complete/index.ts` | 0 diff |
| Format | `deno fmt --check supabase/functions/upload-complete/upload-complete.test.ts` | 0 diff |
| Format | `deno fmt --check supabase/functions/upload-complete/upload-complete.integration.test.ts` | 0 diff |
| Format | `deno fmt --check supabase/functions/upload-cleanup-worker/index.ts` | 0 diff |
| Format | `deno fmt --check supabase/functions/upload-cleanup-worker/upload-cleanup-worker.test.ts` | 0 diff |
| Lint | `deno lint supabase/functions/_shared/cf.ts` | 0 warnings |
| Lint | `deno lint supabase/functions/_shared/cf.test.ts` | 0 warnings |
| Lint | `deno lint supabase/functions/upload-complete/index.ts` | 0 warnings |
| Lint | `deno lint supabase/functions/upload-complete/upload-complete.test.ts` | 0 warnings |
| Lint | `deno lint supabase/functions/upload-complete/upload-complete.integration.test.ts` | 0 warnings |
| Lint | `deno lint supabase/functions/upload-cleanup-worker/index.ts` | 0 warnings |
| Lint | `deno lint supabase/functions/upload-cleanup-worker/upload-cleanup-worker.test.ts` | 0 warnings |
| Credential scan | `gitleaks detect --source . --no-git` | 0 findings |
| Shell syntax | `bash -n` on any new `.sh` files | PASS |
| Lockfile | `deno.lock` regenerated after any import change | committed |
| SHA-256 | All new files hashed | recorded in §9 |

---

## §9 Artifact Hash Summary

Populated after Phase 1 implementation. Required before Phase 1 sign-off.

| File | SHA-256 |
|---|---|
| `supabase/functions/_shared/cf.ts` | TBD |
| `supabase/functions/_shared/cf.test.ts` | TBD |
| `supabase/functions/upload-complete/index.ts` | TBD |
| `supabase/functions/upload-complete/upload-complete.test.ts` | TBD |
| `supabase/functions/upload-complete/upload-complete.integration.test.ts` | TBD |
| `supabase/functions/upload-cleanup-worker/index.ts` | TBD |
| `supabase/functions/upload-cleanup-worker/upload-cleanup-worker.test.ts` | TBD |

---

## §10 Deployment Phases

### §10.1 Phase 2 — forkensics-dev deployment

Pre-conditions before any Phase 2 operation:
- All Phase 1 static checks PASS.
- All Phase 1 artifact SHA-256 confirmed by all three parties.
- `CF_ACCESS_CLIENT_ID`, `CF_ACCESS_CLIENT_SECRET`, `CF_WORKER_URL` set in forkensics-dev Supabase secrets.
- `CRON_SECRET` stored in Supabase Vault under name `CRON_SECRET` (see §10.2 pre-conditions).

| Step | Operation |
|---|---|
| D-1 | `supabase functions deploy upload-complete --project-ref hkfrbdpedrxmbsawnbpr` |
| D-2 | `supabase functions deploy upload-cleanup-worker --project-ref hkfrbdpedrxmbsawnbpr` |
| D-3 | Smoke test: end-to-end upload flow (authorize → PUT → complete → verify `pending_review`) |
| D-4 | Verify cleanup worker responds correctly to a valid `CRON_SECRET` request |
| D-5 | Record deployment evidence (function hashes, smoke test log SHA-256) |

Phase 2 smoke test script: `tools/run-step-b-smoke.sh` (written and `bash -n` verified before Phase 2 sign-off).

### §10.2 Phase 2B — pg_cron scheduling (separate three-party approval required)

**Decision Log constraint:** The Decision Log records: *"Cron functions: remain blocked until a three-party-approved migration adds `CREATE EXTENSION IF NOT EXISTS pg_cron`."* Phase 2B approval (`APPROVED: Step B Rev 3 — Phase 2B`) constitutes that three-party approval.

#### Pre-conditions

Before the Phase 2B migration is run, all of the following must be true:

1. Phase 2 complete and deployment evidence confirmed by all three parties.
2. Phase 2B magic word issued by all three parties.
3. `pg_net` extension present in forkensics-dev:
   ```sql
   SELECT extname FROM pg_extension WHERE extname = 'pg_net';
   -- must return 1 row
   ```
4. `CRON_SECRET` stored in Supabase Vault via the Supabase dashboard (`Project Settings → Vault → New secret`, name = `CRON_SECRET`). The secret value is never committed to the repository, never inserted via migration SQL, and never shared with Claude, Codex, or any AI/chat system.

#### Vault-based CRON_SECRET retrieval

`pg_cron` jobs run as the `postgres` role. On Supabase, `postgres` already holds `SELECT` on `vault.decrypted_secrets` by default. The scheduled SQL reads the secret at execution time:

```sql
(SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'CRON_SECRET' LIMIT 1)
```

If the Vault secret is absent at execution time, this subquery returns `NULL`, and the Edge Function returns `401` (constant-time check fails). No credentials are exposed. The Phase 2B verification steps confirm the secret is present before the migration runs.

No additional `GRANT` statements are required because `postgres` already has full Vault access on Supabase. If that assumption is invalidated by a Supabase version change, the migration must be revised before Phase 2B proceeds.

#### Phase 2B migration

Create with: `supabase migration new enable-pg-cron-schedule`

```sql
-- Phase 2B: enable pg_cron and schedule upload-cleanup-worker.
-- Three-party approved per Step B Rev 3 §10.2.
-- Pre-condition: CRON_SECRET must already exist in vault.decrypted_secrets
-- before this job executes. Verify with P2B-V0 before applying.

BEGIN;

CREATE EXTENSION IF NOT EXISTS pg_cron;

-- Capture the job ID for verification and rollback.
-- cron.schedule returns the job ID as bigint.
DO $$
DECLARE
  v_job_id bigint;
BEGIN
  SELECT cron.schedule(
    'upload-cleanup-worker',
    '*/15 * * * *',
    $job$
    SELECT net.http_post(
      url     := 'https://hkfrbdpedrxmbsawnbpr.supabase.co/functions/v1/upload-cleanup-worker',
      headers := jsonb_build_object(
        'Content-Type',             'application/json',
        'X-Forkensics-Cron-Secret', (
          SELECT decrypted_secret
          FROM vault.decrypted_secrets
          WHERE name = 'CRON_SECRET'
          LIMIT 1
        )
      ),
      body    := '{}'::jsonb
    );
    $job$
  ) INTO v_job_id;

  -- Sanity check: job must have been created.
  IF v_job_id IS NULL THEN
    RAISE EXCEPTION 'cron.schedule returned NULL — job not created';
  END IF;
END;
$$;

COMMIT;
```

#### Phase 2B verification steps

| Step | Query / Action | Pass criterion |
|---|---|---|
| P2B-V0 (pre-migration) | `SELECT name FROM vault.decrypted_secrets WHERE name = 'CRON_SECRET'` | 1 row returned — secret present before migration runs |
| P2B-V1 | `SELECT jobname, schedule FROM cron.job WHERE jobname = 'upload-cleanup-worker'` | 1 row; `schedule = '*/15 * * * *'` |
| P2B-V2 | `SELECT extname FROM pg_extension WHERE extname = 'pg_cron'` | 1 row |
| P2B-V3 (live HTTP test) | See P2B-V3 procedure below | Status code 2xx; no credential in body |

**P2B-V3 procedure — end-to-end HTTP correlation:**

Run the cron job SQL manually (in the Supabase SQL editor) to obtain a `net` request ID:

```sql
-- Step A: dispatch the HTTP request and capture the pg_net request ID.
-- Do NOT display the secret value — the subquery is embedded only.
SELECT net.http_post(
  url     := 'https://hkfrbdpedrxmbsawnbpr.supabase.co/functions/v1/upload-cleanup-worker',
  headers := jsonb_build_object(
    'Content-Type',             'application/json',
    'X-Forkensics-Cron-Secret', (
      SELECT decrypted_secret FROM vault.decrypted_secrets
      WHERE name = 'CRON_SECRET' LIMIT 1
    )
  ),
  body    := '{}'::jsonb
) AS request_id;
```

Record the returned `request_id`. Wait 5–10 seconds, then run:

```sql
-- Step B: verify the HTTP response. Display only status_code and a
-- truncated body preview — never display request headers.
SELECT
  status_code,
  left(content::text, 300) AS body_preview
FROM net.http_responses
WHERE id = <request_id from Step A>;
```

Pass criteria:
- `status_code` is in the range 200–299.
- `body_preview` does not contain the literal value of `CRON_SECRET` (visually confirmed; the value was never displayed in this session).

If `status_code` is 401, the Vault secret is absent or mismatched — check P2B-V0 result and re-verify the Vault entry before re-running.

#### Phase 2B rollback

Rollback unschedules only the job created by this phase. The `pg_cron` extension is NOT dropped — dropping the extension would remove all scheduled jobs, including any added independently, and requires a separate three-party inventory and approval.

```sql
-- Rollback Phase 2B: remove only the upload-cleanup-worker schedule.
-- Extension removal is out of scope and requires separate approval.
SELECT cron.unschedule('upload-cleanup-worker');
```

Confirm with:
```sql
SELECT jobname FROM cron.job WHERE jobname = 'upload-cleanup-worker';
-- must return 0 rows
```

---

## §11 Sign-off Table

| Party | Item | Status |
|---|---|---|
| Claude | Step B Rev 3 — Phase 1 | Pending |
| Codex | Step B Rev 3 — Phase 1 | Pending |
| Bill | Step B Rev 3 — Phase 1 | Pending |
| Claude | Step B Rev 3 — Phase 2 | Pending (requires Phase 1 complete) |
| Codex | Step B Rev 3 — Phase 2 | Pending |
| Bill | Step B Rev 3 — Phase 2 | Pending |
| Claude | Step B Rev 3 — Phase 2B | Pending (requires Phase 2 complete) |
| Codex | Step B Rev 3 — Phase 2B | Pending |
| Bill | Step B Rev 3 — Phase 2B | Pending |
