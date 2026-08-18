# Step B Phase 2 — forkensics-dev Deployment Proposal Rev 3

**Requires three-party approval before any deploy command is run.**
Magic word: `APPROVED: Step B Phase 2 Rev 3`

Changes from Rev 2:
1. §2/§3 corrected: seven migrations (000000–000006), not six.
2. PC-11 removed; account/profile/case/session checks moved into D-0 as manual SQL steps with `cases.media_object_id IS NULL` guard.
3. Teardown corrected: `cases.media_object_id` NULLed before deleting `media_objects` (ON DELETE RESTRICT); all six DB steps wrapped in a single guarded transaction with postcondition verification before COMMIT.
4. R2 teardown wrapper: exit codes 0 (deleted) and 1 (already absent) are both cleanup success; only exit 2 is cleanup failure.
5. D-4c: `_d4c_cfg` registered in `_TEMP_FILES` immediately after creation; CRON_SECRET unset before curl response is read.
6. D-4 reporting fixed: PASS/FAIL log lines are exclusive; `=== D-4: PASS/FAIL ===` reflects actual assertion results.
7. Log-redaction assertion added to EXIT handler before evidence hash.
8. Rollback corrected: drain active sessions and quiesce upload-authorize before removing functions.

---

## §1 Baseline

| Item | Value |
|---|---|
| Phase 1 baseline | Step B Rev 5, three-party approved 2026-08-18 |
| Phase 1 static check result | PASS: 24, FAIL: 0 |
| Target project | forkensics-dev (`hkfrbdpedrxmbsawnbpr`) |
| Functions to deploy | `upload-complete`, `upload-cleanup-worker` |
| Terminal migration | `20260807000006_revoke_migration_grants.sql` |
| Phase 2B (pg_cron) | Separate approval — not in scope here |

---

## §2 Pre-conditions

All must be true before D-0. Any unmet pre-condition is a hard stop.

| # | Pre-condition | How to verify |
|---|---|---|
| PC-1 | Phase 1 three-party approval in Step B Rev 5 §11 | ✅ Done 2026-08-18 |
| PC-2 | `CF_ACCESS_CLIENT_ID` set in forkensics-dev Edge Function secrets | `supabase secrets list --project-ref hkfrbdpedrxmbsawnbpr` — name appears |
| PC-3 | `CF_ACCESS_CLIENT_SECRET` set | same list |
| PC-4 | `CF_WORKER_URL` set | same list |
| PC-5 | `R2_ENDPOINT`, `R2_BUCKET`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY` set | same list — all four names appear |
| PC-6 | `CRON_SECRET` set in Edge Function secrets | same list |
| PC-7 | `CRON_SECRET` set in Supabase Vault | `SELECT name FROM vault.decrypted_secrets WHERE name = 'CRON_SECRET'` → 1 row |
| PC-8 | All seven migrations applied | §3 query → seven rows ending at `20260807000006` |
| PC-9 | CF Worker smoke test previously passed | CF-Worker-Prod-Proposal-Rev3 evidence |
| PC-10 | `upload-authorize` deployed and smoke-tested on forkensics-dev | Step A Rev 9 evidence |

**Credential constraint (permanent):** Secrets confirmed by name only. Values never selected, displayed, logged, or sent to Claude, Codex, or any AI system.

---

## §3 Migration Verification (PC-8)

```sql
SELECT version
FROM supabase_migrations.schema_migrations
ORDER BY version;
```

Expected — exactly seven rows:

```
20260807000000
20260807000001
20260807000002
20260807000003
20260807000004
20260807000005
20260807000006
```

Any divergence is a hard stop before D-0.

---

## §4 Deployment Steps

### D-0 — Preflight

**D-0a: Secrets**

```bash
supabase secrets list --project-ref hkfrbdpedrxmbsawnbpr
```

All eight names must appear: `CF_ACCESS_CLIENT_ID`, `CF_ACCESS_CLIENT_SECRET`, `CF_WORKER_URL`, `R2_ENDPOINT`, `R2_BUCKET`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `CRON_SECRET`.

```sql
-- Vault: name only, value never selected.
SELECT name FROM vault.decrypted_secrets WHERE name = 'CRON_SECRET';
-- Expected: 1 row
```

**D-0b: Migrations** — run §3 query; confirm seven rows ending at `20260807000006`.

**D-0c: Account, profile, case, and session preflight**

These checks must pass before D-1. The smoke script repeats them as a guard; running them here catches issues before wasted deployment work.

```sql
-- 1. Smoke account exists
SELECT id FROM auth.users
WHERE email = 'smoketest@forkensics-dev.local'
LIMIT 1;
-- Expected: 1 row

-- 2. Active, onboarded, non-suspended profile
SELECT is_active FROM public.profiles
WHERE id = '<uploader_id from step 1>'::uuid
  AND onboarding_complete = true
  AND is_suspended = false
LIMIT 1;
-- Expected: 1 row, is_active = true

-- 3. Draft case owned by smoke account with media_object_id IS NULL.
--    If media_object_id is NOT NULL, a previous smoke run's teardown was
--    incomplete. Resolve manually before proceeding.
SELECT state, media_object_id FROM public.cases
WHERE id = 'bef5f781-a661-4ab1-a5c1-be05e1dcbf33'::uuid
  AND poster_id = '<uploader_id>'::uuid
LIMIT 1;
-- Expected: state = 'draft', media_object_id = NULL

-- 4. Zero active upload sessions for smoke account
SELECT COUNT(*) FROM private.upload_sessions
WHERE uploader_id = '<uploader_id>'::uuid
  AND status IN ('pending','processing','sanitized');
-- Expected: 0
```

All four must pass before D-1. If `cases.media_object_id IS NOT NULL`, a previous teardown failed; do not proceed until resolved.

### D-1 — Deploy `upload-complete`

```bash
supabase functions deploy upload-complete \
  --project-ref hkfrbdpedrxmbsawnbpr
```

Expected: exit 0; dashboard shows new deployment timestamp.

### D-2 — Deploy `upload-cleanup-worker`

```bash
supabase functions deploy upload-cleanup-worker \
  --project-ref hkfrbdpedrxmbsawnbpr
```

Expected: exit 0; dashboard shows new deployment timestamp.

**Note:** `verify_jwt = false` applied automatically from committed `supabase/config.toml`. The `--no-verify-jwt` CLI flag is not used.

### D-3 — Smoke test: E2E upload flow

```bash
bash tools/run-step-b-phase2-smoke.sh
```

The launcher prompts for: smoke account password, DB password, CRON\_SECRET, R2 endpoint, R2 access key ID, R2 secret, R2 bucket. Signs in via Supabase Auth (password unset immediately), exports secrets, calls `tools/step-b-phase2-smoke-test.sh`.

**D-3 flow:**

| Step | Action | Pass criterion |
|---|---|---|
| Preflight | Account, profile, case (draft, `media_object_id IS NULL`), active sessions (0) | All four pass |
| 1 | POST `upload-authorize` `{ case_id, content_type: "image/jpeg", declared_size_bytes: 13674 }` | HTTP 200; presigned\_url, upload\_token, expires\_at present; key matches `originals/<uuid-v4>` |
| 2 | PUT `tools/fixtures/smoke-test.jpg` to presigned\_url | HTTP 200 |
| 3 | POST `upload-complete` `{ upload_token }` (no sha256 field); token unset immediately after | HTTP 200; `body.status = "pending_review"`; `media_object_id` present |
| 4 | DB assertions (table below) | All pass |

**D-3 DB assertions:**

| Table | Column | Expected value |
|---|---|---|
| `private.upload_sessions` | `status` | `complete` |
| `public.media_objects` | `status` | `pending_review` |
| `public.cases` | `media_object_id` | `= media_object_id from step 3` |
| `private.media_storage_keys` | `re_encoded_storage_key` | `display/<session_uuid>.webp` |
| `private.media_storage_keys` | `sha256_hash` | 64 lowercase hex chars (non-null) |

**D-3 teardown (EXIT handler — runs unconditionally, pass or fail):**

The teardown distinguishes `TEST PASS/FAIL` (assertions) from `CLEANUP PASS/FAIL` (teardown). Any cleanup failure sets overall result to FAIL.

R2 cleanup uses `tools/r2-cleanup-helper.ts`. Exit code 0 (deleted) and exit code 1 (already absent — upload-complete deletes the original on the happy path) are both cleanup success. Only exit code 2 is a cleanup failure.

DB teardown runs as a single guarded transaction:

1. Guard: confirm `cases.media_object_id = <test media ID>` or `NULL` (FOR UPDATE); raise if unexpected value
2. `UPDATE public.cases SET media_object_id = NULL` (breaks ON DELETE RESTRICT)
3. `DELETE FROM private.media_storage_keys WHERE media_object_id = <test ID>`
4. `UPDATE private.upload_sessions SET media_object_id = NULL, replaced_media_object_id = NULL`
5. `DELETE FROM public.media_objects WHERE id = <test ID>`
6. `UPDATE private.upload_sessions SET status = 'failed', failed_reason = 'FK_INTERNAL', status_changed_at = now()`
7. Verify postconditions (session `status = 'failed'`, `cases.media_object_id IS NULL`, media\_objects row absent, media\_storage\_keys row absent) — `ROLLBACK` on any mismatch

COMMIT only if all seven steps and all postconditions pass.

**Log-redaction assertion (in EXIT handler, before evidence hash):**

The script greps the log for forbidden patterns before printing the SHA-256:
- `eyJ` — JWT prefix (base64url-encoded header)
- `X-Amz-Signature=` or `X-Amz-Credential=` — presigned URL signature params

Any match sets result to FAIL and annotates the log. Do not use a log that fails the redaction assertion as evidence.

### D-4 — Smoke test: `upload-cleanup-worker` auth gate

Runs inside `step-b-phase2-smoke-test.sh` immediately after D-3.

| Case | Input | Expected |
|---|---|---|
| D-4a | No `X-Forkensics-Cron-Secret` | HTTP 401 |
| D-4b | Wrong secret value | HTTP 401 |
| D-4c | Correct secret (via curl `--config` file, chmod 0600, registered in `_TEMP_FILES`, deleted before response read) | HTTP 200, `body.status = "ok"` |

CRON\_SECRET is unset after the config file is written. The config file is registered in `_TEMP_FILES` immediately after creation so the EXIT handler removes it on any early exit. The value never appears in process arguments or log output.

PASS/FAIL logging is exclusive per case. `=== D-4: PASS ===` prints only when all three cases pass.

### D-5 — Record deployment evidence

After D-3 and D-4 pass:
- Paste smoke script stdout (no secret values) into §7.
- Record dashboard deployment timestamps for both functions.
- Record the SHA-256 printed at the end of the smoke log.

---

## §5 Artifacts

### §5.1 New files (Phase 2)

| File | Description |
|---|---|
| `tools/fixtures/smoke-test.jpg` | Copy of `fixture-exif.jpg`; 1200×900 JPEG, 13,674 bytes; exercises EXIF stripping |
| `tools/run-step-b-phase2-smoke.sh` | Launcher — prompts for all secrets, signs in, exports env, calls smoke test |
| `tools/step-b-phase2-smoke-test.sh` | Smoke test — D-3 E2E + D-4 auth gate; guarded transaction teardown; log-redaction assertion |

### §5.2 Log redaction rules

The smoke log must never contain: presigned\_url value, ACCESS\_TOKEN, UPLOAD\_TOKEN, CRON\_SECRET, R2 key values, DB\_URL. Enforced in the script and verified by the redaction assertion in the EXIT handler.

---

## §6 Artifact Hash Summary

`bash -n` verified. gitleaks must be run by Bill before approval.

| File | SHA-256 |
|---|---|
| `tools/fixtures/smoke-test.jpg` | `336bbb3e3f88a084d9a19956cda4937a0e9a1c211243ce2c9e2dc09ca3242c33` |
| `tools/run-step-b-phase2-smoke.sh` | `6886be11c403b030d2a195f5339dffe268983f43398a5e6575dcb8d425a7c330` |
| `tools/step-b-phase2-smoke-test.sh` | `8b7696e15127b9c8666f4839449956889d895390b01cc4322577bf54d4bc4081` |

---

## §7 Deployment Evidence

Populated after D-3 and D-4 pass.

| Item | Value |
|---|---|
| `upload-complete` deploy timestamp | TBD |
| `upload-cleanup-worker` deploy timestamp | TBD |
| Smoke log file | TBD |
| Smoke log SHA-256 | TBD |
| D-4a result | TBD |
| D-4b result | TBD |
| D-4c result | TBD |

---

## §8 Rollback

If any smoke test fails after D-1/D-2:

**Step 1 — Check for active sessions (hard stop if any exist):**

```sql
SELECT session_id, status, uploader_id, created_at
FROM private.upload_sessions
WHERE status IN ('pending','processing','sanitized')
ORDER BY created_at;
```

If rows are returned: resolve each session (fail or wait for expiry) before proceeding. Do not delete functions while sessions are in-flight — new uploads would have no completion path.

**Step 2 — Remove upload-authorize to prevent new sessions:**

```bash
supabase functions delete upload-authorize \
  --project-ref hkfrbdpedrxmbsawnbpr
```

**Step 3 — Wait for any in-flight authorize→PUT→complete sequences to resolve** (presigned URLs expire within their TTL; no new sessions can be created after step 2).

**Step 4 — Clean up any stranded R2 objects from failed test runs:**

Identify via `private.upload_sessions WHERE status = 'failed'` and delete corresponding `original_storage_path` and `display_storage_path` keys from R2 if they still exist.

**Step 5 — Remove the new functions:**

```bash
supabase functions delete upload-complete \
  --project-ref hkfrbdpedrxmbsawnbpr

supabase functions delete upload-cleanup-worker \
  --project-ref hkfrbdpedrxmbsawnbpr
```

**Step 6 — Redeploy upload-authorize** from the previously passing baseline (Step A Rev 9):

```bash
supabase functions deploy upload-authorize \
  --project-ref hkfrbdpedrxmbsawnbpr
```

No database rollback is required — Phase 2 applies no migration.

---

## §9 Out of Scope

Deferred to Phase 2B (separate approval):

- `CREATE EXTENSION IF NOT EXISTS pg_cron`
- `cron.schedule('upload-cleanup-worker', ...)`
- Vault reads of `CRON_SECRET` by pg\_net
- Phase 2B migration and verification (documented in Step B Rev 5 §10.2)

---

## §10 Sign-off Table

| Party | Item | Status |
|---|---|---|
| Claude | Step B Phase 2 Rev 3 | Pending |
| Codex | Step B Phase 2 Rev 3 | Pending |
| Bill | Step B Phase 2 Rev 3 | Pending |
