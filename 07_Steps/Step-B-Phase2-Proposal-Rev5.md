# Step B Phase 2 — forkensics-dev Deployment Proposal Rev 5

**Requires three-party approval before any deploy command is run.**
Magic word: `APPROVED: Step B Phase 2 Rev 5`

Changes from Rev 4 (Codex blockers 1–2):

1. **Blocker 1 — teardown trusts HTTP response**: DB teardown now re-queries the session from the database (SELECT with uploader\_id, case\_id, and original\_storage\_path validation) before choosing full vs. partial path. The DB's `media_object_id` value is authoritative — the HTTP response value is overridden if they differ. The partial path is wrapped in a transaction that locks the session (FOR UPDATE), explicitly verifies the session is not `complete` (which would require full teardown), marks it failed, then verifies the final status is `'failed'` before committing — a zero-row UPDATE is caught.

2. **Blocker 2a — rollback confirmation not fail-closed**: Step 2 now requires `curl` to exit 0 **and** return HTTP 404. A non-zero curl exit (network failure) or unexpected HTTP status halts rollback for investigation. "Connection refused" no longer qualifies.

3. **Blocker 2b — rollback cleans unrelated R2 objects**: A session manifest (session\_id, original\_storage\_path, display\_storage\_path) is captured from the DB **before** any sessions are marked failed (new step 4). R2 cleanup in step 7 operates only on that manifest — not on the open-ended `WHERE status = 'failed'` query.

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
| `private.upload_sessions` | `session_id` | matches UUID extracted from R2 key |

**D-3 teardown (EXIT handler — runs unconditionally, pass or fail):**

`SESSION_ID` is extracted from the R2 object path immediately after step 1 succeeds. Teardown therefore runs even if step 2 (PUT) or step 3 (upload-complete) fails.

The teardown begins by re-querying the session from the DB:

```sql
SELECT uploader_id, case_id, original_storage_path, media_object_id
  FROM private.upload_sessions
 WHERE session_id = '<SESSION_ID>'::uuid;
```

Ownership is validated before any teardown action: `uploader_id`, `case_id`, and `original_storage_path` must match the values established during preflight and step 1. Any mismatch is a hard cleanup failure — teardown aborts.

The DB's `media_object_id` value is used to choose the teardown path, not the HTTP response value. If the client lost the 200 response but the server committed, the DB field will be non-empty and full teardown runs.

**Full path** (DB `media_object_id` is non-empty):

Single guarded transaction (FOR UPDATE on cases):
1. Guard: `SELECT ... FOR UPDATE` — `IF NOT FOUND` raises; checks `media_object_id = <test ID>` or NULL
2. `UPDATE public.cases SET media_object_id = NULL`
3. `DELETE FROM private.media_storage_keys WHERE media_object_id = <test ID>`
4. `UPDATE private.upload_sessions SET media_object_id = NULL, replaced_media_object_id = NULL`
5. `DELETE FROM public.media_objects WHERE id = <test ID>`
6. `UPDATE private.upload_sessions SET status = 'failed', failed_reason = 'FK_INTERNAL'`
7. Verify postconditions (`IF NOT FOUND` on case is explicit failure); ROLLBACK on any mismatch

COMMIT only if all seven steps and postconditions pass.

**Partial path** (DB `media_object_id` is empty — upload-complete never ran):

Single transaction:
1. `SELECT status ... FOR UPDATE` — `IF NOT FOUND` raises
2. `IF status = 'complete' THEN RAISE` (session is complete but media ID was empty — investigation required)
3. `UPDATE ... SET status = 'failed' WHERE status NOT IN ('complete','failed')`
4. `SELECT status` — verify final status is `'failed'`; raise if not (catches zero-row UPDATE)

COMMIT only if all four steps pass.

**Log-redaction assertion (in EXIT handler, before evidence hash):**

The script greps the completed log for `eyJ` (JWT pattern) and `X-Amz-Signature=` / `X-Amz-Credential=` (presigned URL params). Any match fails the run.

### D-4 — Smoke test: `upload-cleanup-worker` auth gate

| Case | Input | Expected |
|---|---|---|
| D-4a | No `X-Forkensics-Cron-Secret` | HTTP 401 |
| D-4b | Wrong secret value | HTTP 401 |
| D-4c | Correct secret (via curl `--config` file, chmod 0600, registered in `_TEMP_FILES`, deleted before response read) | HTTP 200, `body.status = "ok"` |

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
| `tools/step-b-phase2-smoke-test.sh` | Smoke test — D-3 E2E + D-4 auth gate; DB-authoritative teardown; log-redaction assertion |

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
| `tools/step-b-phase2-smoke-test.sh` | `4a693baffc6fc02e2f4d3836b5f3d60ca7fa31dba93450fc09cbde62cdcf7232` |

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

If any smoke test fails after D-1/D-2, follow these steps in strict order.

**Step 1 — Quiesce: delete upload-authorize (prevents all new sessions):**

```bash
supabase functions delete upload-authorize \
  --project-ref hkfrbdpedrxmbsawnbpr
```

**Step 2 — Confirm deletion (curl must exit 0 AND return HTTP 404):**

```bash
_confirm=$(curl -s -o /dev/null -w "%{http_code}" \
  -X POST "https://hkfrbdpedrxmbsawnbpr.supabase.co/functions/v1/upload-authorize" \
  -H "Content-Type: application/json")
echo "Confirmation status: ${_confirm}"
```

Required outcome: `curl` exits 0 **and** `_confirm` is `404`. Any other result — including a non-zero curl exit (network failure) or an unexpected HTTP status — is a hard stop. Do not proceed; investigate whether the function was actually deleted before continuing.

**Step 3 — Wait 420 seconds** (approved presigned URL TTL). No new sessions can be created after step 1. Any in-flight `authorize→PUT` sequences will produce presigned URLs that expire within this window.

**Step 4 — Capture session manifest** (before marking any sessions failed):

```sql
-- Capture the exact set of sessions active at quiesce time.
-- Save full output to a local file for use in steps 5 and 7.
SELECT session_id,
       original_storage_path,
       display_storage_path,
       status
  FROM private.upload_sessions
 WHERE status IN ('pending','processing','sanitized')
 ORDER BY created_at;
```

Save this output to `rollback-manifest-<timestamp>.txt`. This file defines the exact scope of sessions to resolve and R2 keys to clean — no other sessions or keys will be touched.

**Step 5 — Resolve each session in the manifest:**

For each `session_id` in the manifest: mark it failed via direct UPDATE, or wait for it to reach a terminal state naturally. Do not proceed to step 6 while any manifest session remains active.

```sql
-- Mark all manifest sessions failed (run for each session_id, or in bulk):
UPDATE private.upload_sessions
   SET status = 'failed',
       failed_reason = 'FK_INTERNAL',
       status_changed_at = now()
 WHERE session_id = '<session_id_from_manifest>'::uuid
   AND status NOT IN ('complete','failed');
```

**Step 6 — Assert zero active sessions (hard stop if any remain):**

```sql
SELECT COUNT(*) FROM private.upload_sessions
WHERE status IN ('pending','processing','sanitized');
-- Expected: 0
```

**Step 7 — Clean R2 objects for manifest sessions only:**

For each row in `rollback-manifest-<timestamp>.txt`: delete the `original_storage_path` and `display_storage_path` keys from R2 using `tools/r2-cleanup-helper.ts`. Exit code 0 (deleted) and exit code 1 (already absent) are both success. Do not run an open-ended query against `upload_sessions WHERE status = 'failed'` — clean only the manifest.

**Step 8 — Remove the completion functions:**

```bash
supabase functions delete upload-complete \
  --project-ref hkfrbdpedrxmbsawnbpr

supabase functions delete upload-cleanup-worker \
  --project-ref hkfrbdpedrxmbsawnbpr
```

**Step 9 — Redeploy upload-authorize** from the previously passing baseline (Step A Rev 9):

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
| Claude | Step B Phase 2 Rev 5 | Pending |
| Codex | Step B Phase 2 Rev 5 | Pending |
| Bill | Step B Phase 2 Rev 5 | Pending |
