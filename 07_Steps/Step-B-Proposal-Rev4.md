# Step B — `upload-complete` + `upload-cleanup-worker` Proposal Rev 4

**Date:** 2026-08-18  
**Status:** DRAFT — Awaiting three-party approval (Claude + Codex + Bill)

**Supersedes:** Rev 3 (2026-08-18) — addresses two Codex blockers from Rev 3 review.

**Governance gate:** All three parties must approve Phase 1 before any TypeScript is written.  
All three parties must approve Phase 2 before any forkensics-dev deployment operation.  
All three parties must approve Phase 2B before the pg_cron extension migration is applied.

**Magic words:**
- Phase 1: `APPROVED: Step B Rev 4 — Phase 1`
- Phase 2: `APPROVED: Step B Rev 4 — Phase 2`
- Phase 2B (pg_cron scheduling): `APPROVED: Step B Rev 4 — Phase 2B`

**Security constraints (permanent — inherited):**
- `CF_ACCESS_CLIENT_ID`, `CF_ACCESS_CLIENT_SECRET`: never in client code, never in the repo, **never sent to Claude, Codex, or any AI/chat system**.
- `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`: same constraint.
- Three-party governance: Bill + Claude + Codex must all approve before any TypeScript is written or any cloud operation is performed.

---

## §0 Changes from Rev 3

Two changes, each addressing a Codex blocker:

| # | Blocker | Change |
|---|---|---|
| D-1 | `CRON_SECRET` stored only in Vault — Edge Function has no matching secret | §10.2 pre-conditions and §10.1 D-0 preflight updated: Bill generates one value and enters it into both Vault and Edge Function Secrets separately; Phase 2 preflight verifies both named entries exist without displaying either value |
| D-2 | P2B-V3 used wrong relation (`net.http_responses`); missing `timed_out`/`error_msg` assertions; no explicit `timeout_milliseconds` | Relation corrected to `net._http_response`; P2B-V3 assertions updated; `timeout_milliseconds := 30000` added to both the scheduled job and the manual verification call; P2B-V0 now uses `has_table_privilege(...)` instead of an unverified assumption |

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

Rationale: CF Access credentials (`CF-Access-Client-Id`, `CF-Access-Client-Secret`) are attached to every request. Pinning to the approved origin prevents credential forwarding to an arbitrary HTTPS host on misconfiguration.

**Timeout and cancellation:** Instantiate `AbortController` before `fetch`. Pass `signal: controller.signal` in fetch options. Set a 50-second timeout via `setTimeout` — explicitly below the Edge Function wall-clock limit (60 s) and far below the processing lease (10 min). Call `clearTimeout` in a `finally` block to prevent timer leaks. Treat `AbortError` the same as any `fetch` throw: `ok: false, fkCode: "FK_INTERNAL"`.

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
- `displayKey` is a non-empty string.
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
- `result.displayKey === session.display_storage_path`.
- `result.sha256` matches `/^[0-9a-f]{64}$/`.
- `Number.isInteger(result.bytes) && result.bytes > 0 && result.bytes <= 5_242_880`.

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
| `sanitized` | Finalization did not commit; map original error code: `FK_INVALID_HASH` → `422 FK_PROCESSING_FAILED`; `FK_WRONG_STATE` (case not draft) → `409 FK_WRONG_STATE`; transport / unknown → `500 FK_INTERNAL` |
| Other state or no row | Fail-closed `500 FK_INTERNAL` |

**Step 9.** Return `200 {"media_object_id":"<uuid>","status":"pending_review"}`.

### §5.4 Sanitized re-entry (fresh invocation — no in-memory buffer)

Entered from the idempotency branch (`sanitized`) or from §5.3 step 6 re-resolve (`sanitized`). The CF Worker wrote `display/{uuid}.webp` to R2 on the prior invocation. The original may still exist in R2.

**SR-1.** Delete original (`originals/{uuid}`) from R2. `DeleteObject` is idempotent (absent = no-op). Retry up to 2 times on a non-404 failure. All attempts fail → delete display (`display/{uuid}.webp`) from R2; `fail_upload_session('FK_PROCESSING_FAILED')`; `422`.

**SR-2.** Download `display/{uuid}.webp` from R2 (path = `session.display_storage_path`). Absent → `fail_upload_session('FK_PROCESSING_FAILED')`; `422`.

**SR-3.** Verify magic bytes are valid WebP (bytes 0–3 = `52 49 46 46`, bytes 8–11 = `57 45 42 50`). Invalid → delete display from R2; `fail_upload_session('FK_PROCESSING_FAILED')`; `422`.

**SR-4.** Compute SHA-256 of downloaded bytes (lowercase hex, 64 chars).

**SR-5.** Call `finalize_upload_session(session_id, sha256_hash)`. Apply identical finalization error handling as §5.3 step 8.

**SR-6.** Return `200 {"media_object_id":"<uuid>","status":"pending_review"}`.

---

## §6 `upload-cleanup-worker` — Implementation Plan

**Contract:** Step 27 Rev 5 §5.3 (unchanged). Authentication: constant-time `X-Forkensics-Cron-Secret` check against `Deno.env.get("CRON_SECRET")`. Deployed simultaneously with `upload-complete` in Phase 2. Scheduling via pg_cron is Phase 2B (see §10.2).

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

**CRON_SECRET** — see §10.2 for the dual-store setup. The Edge Function reads the value via `Deno.env.get("CRON_SECRET")`. Never commit to repo; never log.

---

## §7 Local Test Plan

### `_shared/cf.ts` unit tests (file: `_shared/cf.test.ts`)

- 200 with valid body → `ok: true`, all three fields populated.
- 200: `displayKey` absent → `ok: false, fkCode: "FK_INTERNAL"`.
- 200: `sha256` is 63 hex chars → `ok: false, fkCode: "FK_INTERNAL"`.
- 200: `sha256` is 64 chars but contains uppercase → `ok: false, fkCode: "FK_INTERNAL"`.
- 200: `bytes` = 0 → `ok: false, fkCode: "FK_INTERNAL"`.
- 200: `bytes` = 5 242 881 → `ok: false, fkCode: "FK_INTERNAL"`.
- 200: `bytes` = 5 242 880 → `ok: true`.
- 200: body exceeds 4 096 bytes → `ok: false, fkCode: "FK_INTERNAL"`.
- 404 → `ok: false, fkCode: "FK_NOT_FOUND"`.
- 422 → `ok: false, fkCode: "FK_PROCESSING_FAILED"`.
- 401, 403, 500, unexpected status → `ok: false, fkCode: "FK_INTERNAL"`.
- `fetch` throws → `ok: false, fkCode: "FK_INTERNAL"`.
- `AbortController` fires (simulated timeout) → `ok: false, fkCode: "FK_INTERNAL"`.
- Missing `CF_WORKER_URL` → `ok: false, fkCode: "FK_INTERNAL"` (no throw).
- `CF_WORKER_URL` uses `http:` → `ok: false, fkCode: "FK_INTERNAL"`.
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
- Sanitized re-entry (idempotency branch): original present, display valid WebP → original deleted (SR-1), SHA-256 computed, finalization → `200`.
- Sanitized re-entry: original absent (already deleted) → SR-1 no-op; continues to SR-2.
- Sanitized re-entry: original deletion fails all retries → display deleted; session failed; `422`.
- Sanitized re-entry: display absent → `422`.
- Sanitized re-entry: display invalid WebP → display deleted; session failed; `422`.
- Lease expiry (step 5) → original deleted; `422 FK_PROCESSING_FAILED`; no `fail_upload_session`; no sanitized advance.
- Original deletion failure (step 7, 2 retries) → display deleted; `fail_upload_session('FK_PROCESSING_FAILED')`; `422`.
- Step 6 RPC error: re-resolve `sanitized` → SR-1 attempted → sanitized re-entry path.
- Step 6 RPC error: re-resolve `processing` → display + original deleted; `fail_upload_session`; `500`.
- Step 6 RPC error: re-resolve `complete` → original deletion attempted (idempotent); `200` idempotent.
- Finalization commits, response lost: re-resolve `complete`; `200` idempotent.
- `FK_INVALID_HASH` → re-resolve `sanitized` → `422 FK_PROCESSING_FAILED`.
- `FK_WRONG_STATE` → re-resolve `sanitized` → `409 FK_WRONG_STATE`.
- Transport error from finalization → re-resolve `sanitized` → `500 FK_INTERNAL`.
- Invalid / expired / failed token → `400 FK_INVALID_TOKEN`.
- Missing CF env vars → `500 FK_INTERNAL` (no credential leak).
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

**Pre-conditions before any Phase 2 operation:**
- All Phase 1 static checks PASS.
- All Phase 1 artifact SHA-256 confirmed by all three parties.
- `CF_ACCESS_CLIENT_ID`, `CF_ACCESS_CLIENT_SECRET`, `CF_WORKER_URL` set in forkensics-dev Supabase secrets.
- `CRON_SECRET` entered into **both** Supabase Vault (name = `CRON_SECRET`) and Supabase Edge Function Secrets (name = `CRON_SECRET`) with the same value. See §10.2 for the full setup procedure.

| Step | Operation |
|---|---|
| D-0 | **Preflight — confirm CRON_SECRET in both stores** (see D-0 procedure below) |
| D-1 | `supabase functions deploy upload-complete --project-ref hkfrbdpedrxmbsawnbpr` |
| D-2 | `supabase functions deploy upload-cleanup-worker --project-ref hkfrbdpedrxmbsawnbpr` |
| D-3 | Smoke test: end-to-end upload flow (authorize → PUT → complete → verify `pending_review`) |
| D-4 | Verify cleanup worker responds correctly to a valid `CRON_SECRET` request |
| D-5 | Record deployment evidence (function hashes, smoke test log SHA-256) |

**D-0 procedure — confirm both stores without displaying values:**

Vault (SQL editor):
```sql
-- Confirms the named entry exists; value is never selected.
SELECT name FROM vault.decrypted_secrets WHERE name = 'CRON_SECRET';
-- Expected: 1 row. If 0 rows, stop — secret not yet added to Vault.
```

Edge Function Secrets (terminal — names only, no values):
```bash
supabase secrets list --project-ref hkfrbdpedrxmbsawnbpr
# Expected: CRON_SECRET appears in the output. If absent, stop.
```

Both must confirm before D-1 proceeds.

Phase 2 smoke test script: `tools/run-step-b-smoke.sh` (written and `bash -n` verified before Phase 2 sign-off).

### §10.2 Phase 2B — pg_cron scheduling (separate three-party approval required)

**Decision Log constraint:** The Decision Log records: *"Cron functions: remain blocked until a three-party-approved migration adds `CREATE EXTENSION IF NOT EXISTS pg_cron`."* Phase 2B approval (`APPROVED: Step B Rev 4 — Phase 2B`) constitutes that three-party approval.

#### CRON_SECRET dual-store setup

The cleanup worker reads `CRON_SECRET` from the Edge Function environment via `Deno.env.get("CRON_SECRET")`. The pg_cron scheduled job reads the same value from Supabase Vault at execution time. Both stores must hold the same value, entered by Bill independently.

**Setup procedure (performed once, before Phase 2):**

1. Generate a single random value locally — for example, using a password manager's secret generator or `openssl rand -hex 32` in a terminal session that is not logged or recorded. The value must never appear in commands that are pasted into chat, shared as evidence, or stored in any file.
2. Enter the value into **Supabase Vault** via the Supabase dashboard: Project Settings → Vault → New secret. Set the name to `CRON_SECRET`. Do not submit the form if any other party is observing the screen.
3. Enter the **same value** into **Supabase Edge Function Secrets** via the Supabase dashboard: Project Settings → Edge Functions → Manage secrets → Add. Set the name to `CRON_SECRET`.

Neither step produces a log, CLI history entry, or evidence record containing the secret value. The two stores are populated in separate dashboard operations; the value is not copied via the clipboard in any observable way.

#### Phase 2B pre-conditions

Before the Phase 2B migration is run, all of the following must be true:

1. Phase 2 complete and deployment evidence confirmed by all three parties.
2. Phase 2B magic word issued by all three parties.
3. `pg_net` extension present (SQL):
   ```sql
   SELECT extname FROM pg_extension WHERE extname = 'pg_net';
   -- must return 1 row
   ```
4. `postgres` role has `SELECT` on `vault.decrypted_secrets` (P2B-V0 — see below).
5. `CRON_SECRET` present in Vault (P2B-V0 — see below).

#### P2B-V0 — fail-closed privilege and secret checks (run before migration)

```sql
-- 1. Verify postgres can read vault.decrypted_secrets (fail-closed privilege check).
SELECT has_table_privilege('postgres', 'vault.decrypted_secrets', 'SELECT') AS vault_readable;
-- Expected: true. If false, the migration must not proceed until the grant is confirmed.

-- 2. Verify CRON_SECRET is present in Vault (name check only; value not selected).
SELECT name FROM vault.decrypted_secrets WHERE name = 'CRON_SECRET';
-- Expected: 1 row. If 0 rows, add the secret to Vault before proceeding.
```

Both checks must pass before applying the Phase 2B migration.

#### Phase 2B migration

Create with: `supabase migration new enable-pg-cron-schedule`

```sql
-- Phase 2B: enable pg_cron and schedule upload-cleanup-worker.
-- Three-party approved per Step B Rev 4 §10.2.
-- Pre-conditions: P2B-V0 must pass before this migration is applied.

BEGIN;

CREATE EXTENSION IF NOT EXISTS pg_cron;

DO $$
DECLARE
  v_job_id bigint;
BEGIN
  SELECT cron.schedule(
    'upload-cleanup-worker',
    '*/15 * * * *',
    $job$
    SELECT net.http_post(
      url                  := 'https://hkfrbdpedrxmbsawnbpr.supabase.co/functions/v1/upload-cleanup-worker',
      headers              := jsonb_build_object(
        'Content-Type',             'application/json',
        'X-Forkensics-Cron-Secret', (
          SELECT decrypted_secret
          FROM vault.decrypted_secrets
          WHERE name = 'CRON_SECRET'
          LIMIT 1
        )
      ),
      body                 := '{}'::jsonb,
      timeout_milliseconds := 30000
    );
    $job$
  ) INTO v_job_id;

  IF v_job_id IS NULL THEN
    RAISE EXCEPTION 'cron.schedule returned NULL — job not created';
  END IF;
END;
$$;

COMMIT;
```

`timeout_milliseconds := 30000` (30 s): comfortably below the Edge Function wall-clock limit (60 s), sufficient for a cleanup batch under normal load.

#### Phase 2B verification steps

Run in order after the migration is applied:

**P2B-V1 — job created:**
```sql
SELECT jobname, schedule FROM cron.job WHERE jobname = 'upload-cleanup-worker';
-- Expected: 1 row; schedule = '*/15 * * * *'
```

**P2B-V2 — extension present:**
```sql
SELECT extname FROM pg_extension WHERE extname = 'pg_cron';
-- Expected: 1 row
```

**P2B-V3 — end-to-end HTTP correlation:**

Step A — dispatch a manual HTTP request and capture the request ID. The secret is embedded in the subquery and never displayed.

```sql
-- Returns a bigint request ID. Record this value for Step B.
SELECT net.http_post(
  url                  := 'https://hkfrbdpedrxmbsawnbpr.supabase.co/functions/v1/upload-cleanup-worker',
  headers              := jsonb_build_object(
    'Content-Type',             'application/json',
    'X-Forkensics-Cron-Secret', (
      SELECT decrypted_secret FROM vault.decrypted_secrets
      WHERE name = 'CRON_SECRET' LIMIT 1
    )
  ),
  body                 := '{}'::jsonb,
  timeout_milliseconds := 30000
) AS request_id;
```

Step B — wait 5–10 seconds, then query `net._http_response` for that request ID. Display only `status_code`, `timed_out`, `error_msg`, and a truncated body preview — never display request headers.

```sql
SELECT
  status_code,
  timed_out,
  error_msg,
  left(content, 300) AS body_preview
FROM net._http_response
WHERE id = <request_id from Step A>;
```

Pass criteria (all four must hold):
- A row is returned for the captured request ID.
- `status_code BETWEEN 200 AND 299`.
- `timed_out = false`.
- `error_msg IS NULL`.

Security: `body_preview` must not contain any credential value. Request headers are not displayed (not selected in Step B).

If `status_code = 401`, the `CRON_SECRET` in Vault does not match the Edge Function secret. Re-verify both stores and re-run P2B-V3.

#### Phase 2B rollback

Rollback unschedules only the job created by this phase. The `pg_cron` extension is **not** dropped — dropping it would remove all scheduled jobs and requires a separate three-party inventory and approval.

```sql
-- Remove only the upload-cleanup-worker schedule.
SELECT cron.unschedule('upload-cleanup-worker');
```

Confirm:
```sql
SELECT jobname FROM cron.job WHERE jobname = 'upload-cleanup-worker';
-- Expected: 0 rows
```

---

## §11 Sign-off Table

| Party | Item | Status |
|---|---|---|
| Claude | Step B Rev 4 — Phase 1 | Pending |
| Codex | Step B Rev 4 — Phase 1 | Pending |
| Bill | Step B Rev 4 — Phase 1 | Pending |
| Claude | Step B Rev 4 — Phase 2 | Pending (requires Phase 1 complete) |
| Codex | Step B Rev 4 — Phase 2 | Pending |
| Bill | Step B Rev 4 — Phase 2 | Pending |
| Claude | Step B Rev 4 — Phase 2B | Pending (requires Phase 2 complete) |
| Codex | Step B Rev 4 — Phase 2B | Pending |
| Bill | Step B Rev 4 — Phase 2B | Pending |
