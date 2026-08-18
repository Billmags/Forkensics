# Step B — `upload-complete` + `upload-cleanup-worker` Proposal Rev 1

**Date:** 2026-08-17  
**Status:** DRAFT — Awaiting three-party approval (Claude + Codex + Bill)

**Supersedes:** N/A (first revision)

**Governance gate:** All three parties must approve Phase 1 before any TypeScript is written.  
All three parties must approve Phase 2 before any forkensics-dev deployment operation.

**Magic words:**
- Claude: `APPROVED: Step B Rev 1 — Phase 1` / `APPROVED: Step B Rev 1 — Phase 2`
- Codex:  `APPROVED: Step B Rev 1 — Phase 1` / `APPROVED: Step B Rev 1 — Phase 2`
- Bill:   `APPROVED: Step B Rev 1 — Phase 1` / `APPROVED: Step B Rev 1 — Phase 2`

**Security constraints (permanent — inherited):**
- `CF_ACCESS_CLIENT_ID`, `CF_ACCESS_CLIENT_SECRET`: never in client code, never in the repo, **never sent to Claude, Codex, or any AI/chat system**.
- `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`: same constraint.
- Three-party governance: Bill + Claude + Codex must all approve before any TypeScript is written or any cloud operation is performed.

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

**CF Worker contract (from CF-Worker-Prod-Proposal-Rev3):**

| Item | Value |
|---|---|
| Endpoint | `POST {CF_WORKER_URL}/transform/originals/{media_uuid}` |
| Auth headers | `CF-Access-Client-Id`, `CF-Access-Client-Secret` |
| Worker reads | `originals/{media_uuid}` from R2 |
| Worker writes | `display/{media_uuid}.webp` to R2 |
| Worker returns (200) | `{"displayKey":"display/{media_uuid}.webp","sha256":"<64 hex chars>","bytes":<int>}` |
| Worker 404 | Original absent in R2 |
| Worker 422 | Input too large / dimension gate / pixel area gate / transform failed |
| Worker 401/403 | CF Access misconfiguration → treat as FK_INTERNAL |
| Worker 5xx | Transient failure → treat as FK_INTERNAL |

**What the CF Worker does NOT do:** delete the original. Deletion of `originals/{uuid}` from R2 remains the Edge Function's responsibility after a successful transform.

**media_uuid derivation:** `session.original_storage_path` = `originals/{uuid}`. Strip the `originals/` prefix to obtain `{uuid}` for the CF Worker URL path parameter.

---

## §3 New Files

### Phase 1 — TypeScript implementation

| File | Description |
|---|---|
| `supabase/functions/_shared/cf.ts` | CF Worker HTTP client: POST transform, parse response, map errors to FK codes |
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

**Mapping:**

| Worker HTTP status | Body condition | CfTransformResult |
|---|---|---|
| 200 | `displayKey`, `sha256` (64 hex), `bytes` present | `ok: true` |
| 404 | any | `ok: false, fkCode: "FK_NOT_FOUND"` |
| 422 | any | `ok: false, fkCode: "FK_PROCESSING_FAILED"` |
| 401 | any | `ok: false, fkCode: "FK_INTERNAL"` |
| 403 | any | `ok: false, fkCode: "FK_INTERNAL"` |
| any other | any | `ok: false, fkCode: "FK_INTERNAL"` |
| fetch throws | — | `ok: false, fkCode: "FK_INTERNAL"` |

**Env validation:** `cf.ts` must fail fast at call time if any of `CF_ACCESS_CLIENT_ID`, `CF_ACCESS_CLIENT_SECRET`, `CF_WORKER_URL` is absent or empty — returning `ok: false, fkCode: "FK_INTERNAL"` (never throws).

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

### §5.2 Full algorithm

**Idempotency branch (resolve session from upload_token):**

- `complete` → `200 {"status":"pending_review","media_object_id":"<uuid>","replaced_media_object_id":"<uuid|null>","already_complete":true}`
- `processing` → `202 {"status":"processing"}`
- `sanitized` → skip to **Sanitized re-entry** (§5.4)
- `pending` → proceed to **Happy path** (§5.3)
- Any other / no row → `400 FK_INVALID_TOKEN`

### §5.3 Happy path (status `pending`)

1. `advance_upload_session_processing(session_id, user_id, '10 minutes')`. Failure → `400 FK_INVALID_TOKEN`.
2. Extract `media_uuid` from `session.original_storage_path` (strip `originals/` prefix).
3. Call `cf.callImageTransform(media_uuid)`.
   - `ok: false, fkCode: "FK_NOT_FOUND"` → `fail_upload_session('FK_NOT_FOUND')`; `404`.
   - `ok: false, fkCode: "FK_PROCESSING_FAILED"` → `fail_upload_session('FK_PROCESSING_FAILED')`; `422`.
   - `ok: false, fkCode: "FK_INTERNAL"` → `fail_upload_session('FK_INTERNAL')`; `500`.
4. CF Worker success: `displayKey`, `sha256`, `bytes` captured. Original is still in R2 at this point (Worker did not delete it).
5. `check_upload_session_lease(session_id)`. Returns false → delete original (`originals/{uuid}`) from R2; `422 FK_PROCESSING_FAILED`. Do NOT call `fail_upload_session`. Do NOT call advance_sanitized. (Display file `display/{uuid}.webp` exists in R2 — leave for cleanup worker.)
6. `advance_upload_session_sanitized(session_id)`.

   **Step 6 RPC-error handling:** RPC may have committed while the client received an error. After any error from step 6, re-resolve the session:
   - Resolved `sanitized` → display intact in R2; fall through to **Sanitized re-entry** (§5.4).
   - Resolved `complete` → finalization already committed; proceed to step 9 (delete original), then return `200` idempotent.
   - Resolved `processing` (RPC did not commit) → delete display (`display/{uuid}.webp`) from R2; delete original (`originals/{uuid}`) from R2; `fail_upload_session('FK_INTERNAL')`; `500`.
   - Other state or no row → delete display; delete original; `500 FK_INTERNAL`.

7. Delete original (`originals/{uuid}`) from R2. Retry up to 2 times. All attempts fail → delete display (`display/{uuid}.webp`) from R2; `fail_upload_session('FK_PROCESSING_FAILED')`; `422`.

**Finalization (from step 6 success):**

8. Call `finalize_upload_session(session_id, sha256)` using the `sha256` from the CF Worker response.

   **Finalization error handling:** If `finalize_upload_session` raises, capture the original error code, then re-resolve:
   - Resolved `complete` → finalization committed despite the error; return `200` idempotent.
   - Resolved `sanitized` → finalization did not commit; map original error code:
     - `FK_INVALID_HASH` → `422 FK_PROCESSING_FAILED`.
     - `FK_WRONG_STATE` (case not draft) → `409 FK_WRONG_STATE`.
     - Transport / unknown → `500 FK_INTERNAL`; client retries via sanitized branch.
   - Other state or no row → fail-closed `500 FK_INTERNAL`.

9. Return `200 {"media_object_id":"<uuid>","status":"pending_review"}`.

### §5.4 Sanitized re-entry (new invocation — no in-memory buffer)

The CF Worker wrote `display/{uuid}.webp` to R2 on the prior invocation. The Edge Function downloads it to compute SHA-256.

13. Download `display/{uuid}.webp` from R2 (path = `session.display_storage_path`). Absent → `fail_upload_session('FK_PROCESSING_FAILED')`; `422`.
14. Verify bytes are valid WebP (check magic bytes `52 49 46 46 ... 57 45 42 50`). Invalid → delete display from R2; `fail_upload_session('FK_PROCESSING_FAILED')`; `422`.
15. Compute SHA-256 of downloaded bytes (lowercase hex, 64 chars).
16. Call `finalize_upload_session(session_id, sha256_hash)`. Apply same finalization error handling as step 8.
17. Return `200 {"media_object_id":"<uuid>","status":"pending_review"}`.

---

## §6 `upload-cleanup-worker` — Implementation Plan

**Contract:** Step 27 Rev 5 §5.3 (unchanged). Authentication: constant-time `X-Forkensics-Cron-Secret` check. Deployed simultaneously with `upload-complete`.

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

### `upload-complete` unit tests

- Happy path → `200`, `status = "pending_review"`, SHA-256 from CF Worker used.
- CF Worker 404 → `fail_upload_session('FK_NOT_FOUND')`; `404`.
- CF Worker 422 → `fail_upload_session('FK_PROCESSING_FAILED')`; `422`.
- CF Worker 5xx → `fail_upload_session('FK_INTERNAL')`; `500`.
- CF Worker fetch throws → `fail_upload_session('FK_INTERNAL')`; `500`.
- Idempotent `complete` on entry → `200 already_complete: true`.
- `processing` on entry → `202`.
- Sanitized re-entry: display in R2, valid WebP → SHA-256 computed from storage; finalization → `200`.
- Sanitized re-entry: display absent from R2 → `422`.
- Sanitized re-entry: display present but invalid WebP → display deleted; session failed; `422`.
- Lease expiry (step 5) → original deleted; `422 FK_PROCESSING_FAILED`; no `fail_upload_session`; no sanitized advance.
- Original deletion failure (2 retries) → display deleted; `fail_upload_session('FK_PROCESSING_FAILED')`; `422`.
- Step 6 RPC error: re-resolve `sanitized` → sanitized re-entry path.
- Step 6 RPC error: re-resolve `processing` → display + original deleted; `fail_upload_session`; `500`.
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

### `_shared/cf.ts` unit tests

- 200 with valid body → `ok: true`, fields populated.
- 200 with malformed body (missing sha256) → `ok: false, fkCode: "FK_INTERNAL"`.
- 404 → `ok: false, fkCode: "FK_NOT_FOUND"`.
- 422 → `ok: false, fkCode: "FK_PROCESSING_FAILED"`.
- 401, 403, 500, unexpected status → `ok: false, fkCode: "FK_INTERNAL"`.
- fetch throws → `ok: false, fkCode: "FK_INTERNAL"`.
- Missing env var → `ok: false, fkCode: "FK_INTERNAL"` (no throw).

---

## §8 Static Checks (Phase 1 gate)

All must pass before Phase 1 is declared complete:

| Check | Command | Requirement |
|---|---|---|
| Type-check | `deno check supabase/functions/upload-complete/index.ts` | 0 errors |
| Type-check | `deno check supabase/functions/upload-cleanup-worker/index.ts` | 0 errors |
| Type-check | `deno check supabase/functions/_shared/cf.ts` | 0 errors |
| Format | `deno fmt --check supabase/functions/upload-complete/index.ts` | 0 diff |
| Format | `deno fmt --check supabase/functions/upload-cleanup-worker/index.ts` | 0 diff |
| Format | `deno fmt --check supabase/functions/_shared/cf.ts` | 0 diff |
| Lint | `deno lint supabase/functions/upload-complete/index.ts` | 0 warnings |
| Lint | `deno lint supabase/functions/upload-cleanup-worker/index.ts` | 0 warnings |
| Lint | `deno lint supabase/functions/_shared/cf.ts` | 0 warnings |
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
| `supabase/functions/upload-complete/index.ts` | TBD |
| `supabase/functions/upload-complete/upload-complete.test.ts` | TBD |
| `supabase/functions/upload-complete/upload-complete.integration.test.ts` | TBD |
| `supabase/functions/upload-cleanup-worker/index.ts` | TBD |
| `supabase/functions/upload-cleanup-worker/upload-cleanup-worker.test.ts` | TBD |

---

## §10 Phase 2 — Deployment (forkensics-dev)

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

---

## §11 Sign-off Table

| Party | Item | Status |
|---|---|---|
| Claude | Step B Rev 1 — Phase 1 | APPROVED: Step B Rev 1 — Phase 1 |
| Codex | Step B Rev 1 — Phase 1 | Pending |
| Bill | Step B Rev 1 — Phase 1 | Pending |
| Claude | Step B Rev 1 — Phase 2 | Pending (requires Phase 1 complete) |
| Codex | Step B Rev 1 — Phase 2 | Pending |
| Bill | Step B Rev 1 — Phase 2 | Pending |
