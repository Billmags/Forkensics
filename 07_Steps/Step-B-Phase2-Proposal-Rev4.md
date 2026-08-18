# Step B Phase 2 — forkensics-dev Deployment Proposal Rev 4

**Requires three-party approval before any deploy command is run.**
Magic word: `APPROVED: Step B Phase 2 Rev 4`

Changes from Rev 3 (Codex blockers 1–4):

1. **Blocker 1 — early-failure session stranding**: `SESSION_ID` is now extracted from the R2 object path immediately after upload-authorize succeeds (before the PUT). DB teardown therefore runs even if the PUT or upload-complete fails. Teardown branches: full guarded transaction when `MEDIA_OBJECT_ID` is set; partial fail-session-only path otherwise.
2. **Blocker 2 — NOT FOUND ambiguity**: Guard DO block and verify DO block both now explicitly check `IF NOT FOUND` after `SELECT INTO`. A missing case row raises an exception and aborts the transaction; it is no longer silently treated as `media_object_id IS NULL`.
3. **Blocker 3 — rollback race**: Rollback §8 reordered: quiesce `upload-authorize` first (prevents new sessions), confirm deletion, wait the approved 420-second drain, enumerate and resolve remaining active sessions, assert zero, then remove completion functions.
4. **Blocker 4 — inaccurate redaction claim**: §5.2 rewritten to accurately distinguish (a) values protected by assertion (`eyJ`, `X-Amz-Signature=`, `X-Amz-Credential=`) from (b) values protected by design (never passed to `log()`), and (c) values intentionally logged (R2 object paths, which are session UUIDs — not credentials).

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

-- 3. Draft case with media_object_id IS NULL.
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
| 1 | POST `upload-authorize` `{ case_id, content_type: "image/jpeg", declared_size_bytes: 13674 }` | HTTP 200; presigned\_url, upload\_token, expires\_at present; key matches `originals/<uuid-v4>`; SESSION\_ID set immediately from key |
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
| `private.upload_sessions` | `session_id` | matches session UUID extracted from R2 key |

**D-3 teardown (EXIT handler — runs unconditionally, pass or fail):**

`SESSION_ID` is extracted from the R2 object path immediately after step 1 succeeds. Teardown therefore runs even if step 2 (PUT) or step 3 (upload-complete) fails.

The teardown distinguishes `TEST PASS/FAIL` (assertions) from `CLEANUP PASS/FAIL` (teardown operations). Any cleanup failure sets the overall result to FAIL.

R2 cleanup: exit code 0 (deleted) and exit code 1 (already absent) are both cleanup success. Only exit code 2 is a cleanup failure. Upload-complete deletes the original from R2 on the happy path, so exit 1 on the original key is expected.

DB teardown branches on whether `MEDIA_OBJECT_ID` is set:

**Full path** (upload-complete succeeded — `MEDIA_OBJECT_ID` is set):

Single guarded transaction:
1. Guard: `SELECT ... FOR UPDATE` — explicitly checks `IF NOT FOUND` (raises if case row is missing); then checks `media_object_id = <test ID>` or NULL (raises if unexpected third value)
2. `UPDATE public.cases SET media_object_id = NULL` (breaks ON DELETE RESTRICT)
3. `DELETE FROM private.media_storage_keys WHERE media_object_id = <test ID>`
4. `UPDATE private.upload_sessions SET media_object_id = NULL, replaced_media_object_id = NULL`
5. `DELETE FROM public.media_objects WHERE id = <test ID>`
6. `UPDATE private.upload_sessions SET status = 'failed', failed_reason = 'FK_INTERNAL'`
7. Verify postconditions: session `status = 'failed'`; `cases.media_object_id IS NULL` (with explicit `IF NOT FOUND` — case row must still exist); `media_objects` row absent; `media_storage_keys` row absent — `ROLLBACK` on any mismatch

COMMIT only if all seven steps and postconditions pass.

**Partial path** (PUT or upload-complete failed — `MEDIA_OBJECT_ID` is empty):

```sql
UPDATE private.upload_sessions
   SET status = 'failed', failed_reason = 'FK_INTERNAL', status_changed_at = now()
 WHERE session_id = '<SESSION_ID>'::uuid
   AND status NOT IN ('complete','failed');
```

No media objects or cases references to unwind.

**Log-redaction assertion (in EXIT handler, before evidence hash):**

The script greps the completed log for:
- `eyJ` — JWT prefix (base64url `{"alg":...}` header); would catch leaked ACCESS\_TOKEN
- `X-Amz-Signature=` or `X-Amz-Credential=` — presigned URL HMAC signature params

Any match sets result to FAIL. Do not use a log that fails this assertion as evidence.

### D-4 — Smoke test: `upload-cleanup-worker` auth gate

| Case | Input | Expected |
|---|---|---|
| D-4a | No `X-Forkensics-Cron-Secret` | HTTP 401 |
| D-4b | Wrong secret value | HTTP 401 |
| D-4c | Correct secret (via curl `--config` file, chmod 0600, registered in `_TEMP_FILES`, deleted before response read) | HTTP 200, `body.status = "ok"` |

CRON\_SECRET is unset after the config file is written. PASS/FAIL logging is exclusive per case. `=== D-4: PASS ===` prints only when all three cases pass.

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

### §5.2 Log redaction

Three tiers of protection:

**Protected by log-redaction assertion** (grep checks in EXIT handler — any match fails the run):
- JWT pattern `eyJ` — would catch a leaked `ACCESS_TOKEN` or other JWT
- `X-Amz-Signature=` / `X-Amz-Credential=` — presigned URL HMAC signature parameters

**Protected by design** (values never passed to `log()`; not checked by assertion):
- `presigned_url` value (URL-embedded HMAC signature)
- `ACCESS_TOKEN` value (JWT — also caught by assertion if leaked)
- `UPLOAD_TOKEN` value (unset immediately after step 3 POST)
- `CRON_SECRET` value (written only to chmod-0600 temp file; deleted before curl exits)
- `R2_ACCESS_KEY_ID` / `R2_SECRET_ACCESS_KEY` values (only their lengths are logged)
- `DB_URL` (contains database password)

**Intentionally logged** (not credentials):
- `ORIG_KEY`, `DISPLAY_KEY` — R2 object paths of the form `originals/<uuid>` and `display/<uuid>.webp`; the UUID is the session identifier, not a secret

---

## §6 Artifact Hash Summary

`bash -n` verified. gitleaks must be run by Bill before approval.

| File | SHA-256 |
|---|---|
| `tools/fixtures/smoke-test.jpg` | `336bbb3e3f88a084d9a19956cda4937a0e9a1c211243ce2c9e2dc09ca3242c33` |
| `tools/run-step-b-phase2-smoke.sh` | `6886be11c403b030d2a195f5339dffe268983f43398a5e6575dcb8d425a7c330` |
| `tools/step-b-phase2-smoke-test.sh` | `4b00159cb40b5c1c5021f87054951614128092e53c24043abc7b7456ce1fe6ac` |

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

If any smoke test fails after D-1/D-2, follow these steps in order. The critical change from Rev 3: quiesce `upload-authorize` **first** to close the window for new sessions before checking active session count.

**Step 1 — Quiesce: delete upload-authorize (prevents all new sessions):**

```bash
supabase functions delete upload-authorize \
  --project-ref hkfrbdpedrxmbsawnbpr
```

**Step 2 — Confirm deletion** (verify the function no longer responds):

```bash
curl -s -o /dev/null -w "%{http_code}" \
  -X POST "https://hkfrbdpedrxmbsawnbpr.supabase.co/functions/v1/upload-authorize" \
  -H "Content-Type: application/json"
# Expected: 404 (function not found) or connection refused
```

**Step 3 — Wait 420 seconds** (approved presigned URL TTL). No new sessions can be created after step 1. Any in-flight `authorize→PUT` sequences will produce presigned URLs that expire within this window.

**Step 4 — Enumerate remaining active sessions:**

```sql
SELECT session_id, status, uploader_id, created_at
FROM private.upload_sessions
WHERE status IN ('pending','processing','sanitized')
ORDER BY created_at;
```

For each row: mark failed manually or wait for the session to expire. Do not proceed to step 5 while any session is active.

**Step 5 — Assert zero active sessions (hard stop if any remain):**

```sql
SELECT COUNT(*) FROM private.upload_sessions
WHERE status IN ('pending','processing','sanitized');
-- Expected: 0
```

**Step 6 — Clean up stranded R2 objects from failed test runs:**

Identify via `private.upload_sessions WHERE status = 'failed'` and delete the corresponding `original_storage_path` and `display_storage_path` keys from R2 using `tools/r2-cleanup-helper.ts` if they still exist.

**Step 7 — Remove the completion functions:**

```bash
supabase functions delete upload-complete \
  --project-ref hkfrbdpedrxmbsawnbpr

supabase functions delete upload-cleanup-worker \
  --project-ref hkfrbdpedrxmbsawnbpr
```

**Step 8 — Redeploy upload-authorize** from the previously passing baseline (Step A Rev 9):

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
| Claude | Step B Phase 2 Rev 4 | Pending |
| Codex | Step B Phase 2 Rev 4 | Pending |
| Bill | Step B Phase 2 Rev 4 | Pending |
