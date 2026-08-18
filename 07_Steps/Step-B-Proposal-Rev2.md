# Step B — `upload-complete` + `upload-cleanup-worker` Proposal Rev 2

**Date:** 2026-08-18  
**Status:** DRAFT — Awaiting three-party approval (Claude + Codex + Bill)

**Supersedes:** Rev 1 (2026-08-17) — addresses all five Codex blockers from Rev 1 review.

**Governance gate:** All three parties must approve Phase 1 before any TypeScript is written.  
All three parties must approve Phase 2 before any forkensics-dev deployment operation.  
All three parties must approve Phase 2B before the pg_cron extension migration is applied.

**Magic words:**
- Phase 1: `APPROVED: Step B Rev 2 — Phase 1`
- Phase 2: `APPROVED: Step B Rev 2 — Phase 2`
- Phase 2B (pg_cron scheduling): `APPROVED: Step B Rev 2 — Phase 2B`

**Security constraints (permanent — inherited):**
- `CF_ACCESS_CLIENT_ID`, `CF_ACCESS_CLIENT_SECRET`: never in client code, never in the repo, **never sent to Claude, Codex, or any AI/chat system**.
- `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`: same constraint.
- Three-party governance: Bill + Claude + Codex must all approve before any TypeScript is written or any cloud operation is performed.

---

## §0 Changes from Rev 1

Five changes, each addressing a Codex blocker:

| # | Blocker | Change |
|---|---|---|
| B-1 | CF Worker success response under-validated | §5.3 step 4: added three strict validation assertions on `displayKey`, `sha256`, `bytes` |
| B-2 | Sanitized re-entry skips original deletion; "step 9" reference wrong | §5.4 SR-1 added (original deletion as first step, covers all entry paths); step 6 re-resolve `sanitized` path updated; "step 9" corrected |
| B-3 | `cf.ts` lacks timeout, AbortController, body limit, URL validation | §4 spec updated with all four requirements |
| B-4 | Cleanup worker deployed but never scheduled; pg_cron blocked per Decision Log | Phase 2B added: pg_cron migration + scheduling + verification + rollback, with own magic word |
| B-5 | `_shared/cf.test.ts` missing from §3 inventory, §8 static checks, §9 hash table | Added to all three locations |

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

Step 27 Rev 5 was written when `upload-complete` was expected to run magick-wasm inline. The approved architecture evolved: image transformation is delegated to the `forkensics-image-transform-dev` Cloudflare Worker. This changes the Edge Function's responsibility materially.

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

**URL validation:** `CF_WORKER_URL` must be validated at call time before the request is issued. Validation rules (any failure → `ok: false, fkCode: "FK_INTERNAL"`):
- Parses as a valid URL.
- Protocol is `https:` exactly (no `http:`).
- `username` is empty string.
- `password` is empty string.
- `search` (query string) is empty string.
- `hash` (fragment) is empty string.
- `hostname` is non-empty.

**Timeout and cancellation:** Use `AbortController` to enforce a 50-second timeout on the `fetch` call. The 50-second limit is explicitly below the Edge Function wall-clock limit (60 s) and far below the processing lease (10 min), ensuring the Edge Function retains time for error handling and DB operations after a timeout. Call `clearTimeout` in a `finally` block to prevent timer leaks.

**Bounded response body:** After receiving a non-error HTTP response, read at most 4 096 bytes of the body. If the body exceeds 4 096 bytes, discard and return `ok: false, fkCode: "FK_INTERNAL"`.

**Response-status mapping:**

| Worker HTTP status | Body condition | CfTransformResult |
|---|---|---|
| 200 | `displayKey`, `sha256`, `bytes` present and valid (see validation below) | `ok: true` |
| 200 | Any validation failure | `ok: false, fkCode: "FK_INTERNAL"` |
| 404 | any | `ok: false, fkCode: "FK_NOT_FOUND"` |
| 422 | any | `ok: false, fkCode: "FK_PROCESSING_FAILED"` |
| 401 | any | `ok: false, fkCode: "FK_INTERNAL"` |
| 403 | any | `ok: false, fkCode: "FK_INTERNAL"` |
| any other | any | `ok: false, fkCode: "FK_INTERNAL"` |
| fetch throws / AbortError (timeout) | — | `ok: false, fkCode: "FK_INTERNAL"` |

**200 response-body validation** (all three must pass; any failure → `ok: false, fkCode: "FK_INTERNAL"`):
- `displayKey` is a non-empty string (equality with `session.display_storage_path` is checked by the caller in `upload-complete`, not here, because `cf.ts` has no access to session state).
- `sha256` matches `/^[0-9a-f]{64}$/` exactly (64 lowercase hex characters).
- `bytes` is a finite integer satisfying `0 < bytes <= 5_242_880`.

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
- `result.displayKey === session.display_storage_path` — guards against Worker writing to the wrong R2 key.
- `result.sha256` matches `/^[0-9a-f]{64}$/` — redundant with `cf.ts` validation; belt-and-suspenders.
- `Number.isInteger(result.bytes) && result.bytes > 0 && result.bytes <= 5_242_880` — per CF-Worker-Prod-Proposal-Rev3 CF-W-7 probe specification.

Capture `displayKey`, `sha256`, `bytes` for use in subsequent steps. The original (`originals/{uuid}`) remains in R2 at this point — the Worker did not delete it.

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

Entered from the idempotency branch (`sanitized` state) or from §5.3 step 6 re-resolve (`sanitized`). The CF Worker wrote `display/{uuid}.webp` to R2 on the prior invocation. The original (`originals/{uuid}`) may still exist in R2 if step 7 was not reached on the prior invocation.

**SR-1.** Delete original (`originals/{uuid}`) from R2. R2 `DeleteObject` is idempotent (absent = no-op). Retry up to 2 times on failure. All attempts fail with a non-404 error → delete display (`display/{uuid}.webp`) from R2; `fail_upload_session('FK_PROCESSING_FAILED')`; `422`.

**SR-2.** Download `display/{uuid}.webp` from R2 (path = `session.display_storage_path`). Absent → `fail_upload_session('FK_PROCESSING_FAILED')`; `422`.

**SR-3.** Verify magic bytes are valid WebP (`RIFF....WEBP`: bytes 0–3 = `52 49 46 46`, bytes 8–11 = `57 45 42 50`). Invalid → delete display from R2; `fail_upload_session('FK_PROCESSING_FAILED')`; `422`.

**SR-4.** Compute SHA-256 of downloaded bytes (lowercase hex, 64 chars).

**SR-5.** Call `finalize_upload_session(session_id, sha256_hash)`. Apply identical finalization error handling as §5.3 step 8.

**SR-6.** Return `200 {"media_object_id":"<uuid>","status":"pending_review"}`.

---

## §6 `upload-cleanup-worker` — Implementation Plan

**Contract:** Step 27 Rev 5 §5.3 (unchanged). Authentication: constant-time `X-Forkensics-Cron-Secret` check. Deployed simultaneously with `upload-complete` in Phase 2. Scheduling via pg_cron is a separate Phase 2B operation (see §10.2).

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

**CRON_SECRET** — generate a random ≥256-bit secret; store in forkensics-dev Supabase secrets as `CRON_SECRET`. Never commit to repo; never log.

---

## §7 Local Test Plan

### `_shared/cf.ts` unit tests (file: `_shared/cf.test.ts`)

- 200 with valid body → `ok: true`, `displayKey` / `sha256` / `bytes` populated.
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
- `CF_WORKER_URL` contains query string → `ok: false, fkCode: "FK_INTERNAL"`.
- `CF_WORKER_URL` contains fragment → `ok: false, fkCode: "FK_INTERNAL"`.
- `CF_WORKER_URL` contains username or password → `ok: false, fkCode: "FK_INTERNAL"`.

### `upload-complete` unit tests

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
- Sanitized re-entry (idempotency branch): original present in R2, display present and valid WebP → original deleted, SHA-256 computed from display, finalization → `200`.
- Sanitized re-entry: original absent in R2 (already deleted) → no error; continues to download display.
- Sanitized re-entry: original deletion fails (all retries) → display deleted; session failed; `422`.
- Sanitized re-entry: display absent from R2 → `422`.
- Sanitized re-entry: display present but invalid WebP → display deleted; session failed; `422`.
- Lease expiry (step 5) → original deleted; `422 FK_PROCESSING_FAILED`; no `fail_upload_session`; no sanitized advance.
- Original deletion failure in happy path (step 7, 2 retries) → display deleted; `fail_upload_session('FK_PROCESSING_FAILED')`; `422`.
- Step 6 RPC error: re-resolve `sanitized` → original deletion attempted → sanitized re-entry path.
- Step 6 RPC error: re-resolve `processing` → display + original deleted; `fail_upload_session`; `500`.
- Step 6 RPC error: re-resolve `complete` → original deletion attempted (idempotent); return `200` idempotent.
- Finalization commits but response lost (within same invocation): re-resolve → `complete`; return `200` idempotent.
- `FK_INVALID_HASH` from DB → re-resolve → `sanitized` → `422 FK_PROCESSING_FAILED`.
- `FK_WRONG_STATE` (case not draft) → re-resolve → `sanitized` → `409 FK_WRONG_STATE`.
- Transport error from finalization → re-resolve → `sanitized` → `500 FK_INTERNAL`.
- Invalid / expired / failed token → `400 FK_INVALID_TOKEN`.
- Missing CF env vars → `500 FK_INTERNAL` (no credential leak in response).
- Step 24 Rev 10 §5.1 mandatory tests (V4 identifier substitutions applied).

### `upload-cleanup-worker` unit tests

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
| Type-check | `deno check supabase/functions/upload-cleanup-worker/index.ts` | 0 errors |
| Format | `deno fmt --check supabase/functions/_shared/cf.ts` | 0 diff |
| Format | `deno fmt --check supabase/functions/_shared/cf.test.ts` | 0 diff |
| Format | `deno fmt --check supabase/functions/upload-complete/index.ts` | 0 diff |
| Format | `deno fmt --check supabase/functions/upload-cleanup-worker/index.ts` | 0 diff |
| Lint | `deno lint supabase/functions/_shared/cf.ts` | 0 warnings |
| Lint | `deno lint supabase/functions/_shared/cf.test.ts` | 0 warnings |
| Lint | `deno lint supabase/functions/upload-complete/index.ts` | 0 warnings |
| Lint | `deno lint supabase/functions/upload-cleanup-worker/index.ts` | 0 warnings |
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
- `CRON_SECRET` generated and set in forkensics-dev Supabase secrets.

| Step | Operation |
|---|---|
| D-1 | `supabase functions deploy upload-complete --project-ref hkfrbdpedrxmbsawnbpr` |
| D-2 | `supabase functions deploy upload-cleanup-worker --project-ref hkfrbdpedrxmbsawnbpr` |
| D-3 | Smoke test: end-to-end upload flow (authorize → PUT → complete → verify `pending_review`) |
| D-4 | Verify cleanup worker responds correctly to a valid `CRON_SECRET` request |
| D-5 | Record deployment evidence (function hashes, smoke test log SHA-256) |

Phase 2 smoke test script: `tools/run-step-b-smoke.sh` (written and `bash -n` verified before Phase 2 sign-off).

### §10.2 Phase 2B — pg_cron scheduling (separate three-party approval required)

**Decision Log constraint:** The Decision Log records: *"Cron functions: remain blocked until a three-party-approved migration adds `CREATE EXTENSION IF NOT EXISTS pg_cron`."* Phase 2B approval (`APPROVED: Step B Rev 2 — Phase 2B`) constitutes the three-party approval required by the Decision Log.

**Phase 2B pre-conditions:**
- Phase 2 complete and deployment evidence confirmed.
- All three parties have issued the Phase 2B magic word.
- `pg_net` extension verified present in forkensics-dev (built-in on Supabase; confirm via `SELECT * FROM pg_extension WHERE extname = 'pg_net'`).

**Phase 2B migration** (new migration file — create with `supabase migration new enable-pg-cron-schedule`):

```sql
-- Phase 2B: enable pg_cron and schedule upload-cleanup-worker
-- Three-party approved per Step B Rev 2 §10.2

BEGIN;

CREATE EXTENSION IF NOT EXISTS pg_cron;

-- Schedule: every 15 minutes, POST to upload-cleanup-worker
-- Requires CRON_SECRET stored as a Supabase secret.
-- The scheduled SQL calls net.http_post (pg_net) with the secret
-- retrieved at execution time from the Supabase vault / app.settings.
-- The exact secret-retrieval mechanism (vault vs. app.settings) is
-- confirmed at implementation time; the migration placeholder below
-- uses app.settings — replace if vault is used instead.

SELECT cron.schedule(
  'upload-cleanup-worker',
  '*/15 * * * *',
  $$
  SELECT net.http_post(
    url    := 'https://hkfrbdpedrxmbsawnbpr.supabase.co/functions/v1/upload-cleanup-worker',
    headers := jsonb_build_object(
      'Content-Type',               'application/json',
      'X-Forkensics-Cron-Secret',   current_setting('app.cron_secret', true)
    ),
    body   := '{}'::jsonb
  );
  $$
);

COMMIT;
```

**Phase 2B verification steps:**

| Step | Command | Expected |
|---|---|---|
| P2B-V1 | `SELECT * FROM cron.job WHERE jobname = 'upload-cleanup-worker'` | 1 row, `schedule = '*/15 * * * *'` |
| P2B-V2 | Confirm `pg_cron` extension present | `SELECT extname FROM pg_extension WHERE extname = 'pg_cron'` returns 1 row |
| P2B-V3 | Wait for next scheduled run; check `cron.job_run_details` | At least 1 `succeeded` entry for `upload-cleanup-worker` |

**Rollback plan:**

```sql
-- Rollback Phase 2B (run only if Phase 2B is being reverted)
BEGIN;
SELECT cron.unschedule('upload-cleanup-worker');
DROP EXTENSION IF EXISTS pg_cron;
COMMIT;
```

Note: dropping `pg_cron` removes all scheduled jobs. Apply rollback only if Phase 2B is explicitly reverted by three-party agreement.

---

## §11 Sign-off Table

| Party | Item | Status |
|---|---|---|
| Claude | Step B Rev 2 — Phase 1 | Pending |
| Codex | Step B Rev 2 — Phase 1 | Pending |
| Bill | Step B Rev 2 — Phase 1 | Pending |
| Claude | Step B Rev 2 — Phase 2 | Pending (requires Phase 1 complete) |
| Codex | Step B Rev 2 — Phase 2 | Pending |
| Bill | Step B Rev 2 — Phase 2 | Pending |
| Claude | Step B Rev 2 — Phase 2B | Pending (requires Phase 2 complete) |
| Codex | Step B Rev 2 — Phase 2B | Pending |
| Bill | Step B Rev 2 — Phase 2B | Pending |
