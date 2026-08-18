# Step B Phase 2 — forkensics-dev Deployment Proposal Rev 2

**Requires three-party approval before any deploy command is run.**
Magic word: `APPROVED: Step B Phase 2 Rev 2`

Changes from Rev 1:
- PC-8 corrected: terminal migration is `20260807000006`, not `000004`
- D-3 request corrected: `case_id`, `content_type`, `declared_size_bytes` (not `byte_size`)
- D-3 upload-complete corrected: body is `{ upload_token }` only — no sha256 field
- D-3 assertions corrected: `upload_sessions.status='complete'`, `media_objects.status='pending_review'`; storage key and hash are in `private.media_storage_keys.re_encoded_storage_key` and `sha256_hash`
- D-3 teardown added: R2 original (may already be absent), R2 display, DB rows in FK-safe order
- D-4 corrected: all three cases tested (missing → 401, wrong → 401, correct → 200); CRON_SECRET prompted securely, passed via chmod-0600 temp file, never logged
- Smoke scripts written, `bash -n` verified, and hashed (§6) before approval
- Fixture copied to `tools/fixtures/smoke-test.jpg`, SHA-256 recorded

---

## §1 Baseline

| Item | Value |
|---|---|
| Phase 1 baseline | Step B Rev 5, three-party approved 2026-08-18 |
| Phase 1 static check result | PASS: 24, FAIL: 0 |
| Target project | forkensics-dev (`hkfrbdpedrxmbsawnbpr`) |
| Functions to deploy | `upload-complete`, `upload-cleanup-worker` |
| Terminal migration (forkensics-dev) | `20260807000006_revoke_migration_grants.sql` |
| Phase 2B (pg_cron) | Separate approval — not in scope here |

---

## §2 Pre-conditions

All must be true before D-0. Any unmet pre-condition is a hard stop.

| # | Pre-condition | How to verify |
|---|---|---|
| PC-1 | Phase 1 three-party approval recorded in Step B Rev 5 §11 | ✅ Done 2026-08-18 |
| PC-2 | `CF_ACCESS_CLIENT_ID` set in forkensics-dev Edge Function secrets | `supabase secrets list --project-ref hkfrbdpedrxmbsawnbpr` — name appears |
| PC-3 | `CF_ACCESS_CLIENT_SECRET` set | same list — name appears |
| PC-4 | `CF_WORKER_URL` set | same list — name appears |
| PC-5 | `R2_ENDPOINT`, `R2_BUCKET`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY` set | same list — all four names appear |
| PC-6 | `CRON_SECRET` set in Edge Function secrets | same list — name appears |
| PC-7 | `CRON_SECRET` set in Supabase Vault | `SELECT name FROM vault.decrypted_secrets WHERE name = 'CRON_SECRET'` → 1 row |
| PC-8 | All six migrations applied on forkensics-dev | `SELECT version FROM supabase_migrations.schema_migrations ORDER BY version` — six rows ending at `20260807000006` |
| PC-9 | forkensics-dev CF Worker smoke test previously passed | CF-Worker-Prod-Proposal-Rev3 evidence |
| PC-10 | `upload-authorize` previously deployed and smoke-tested on forkensics-dev | Step A Rev 9 evidence |
| PC-11 | `smoketest@forkensics-dev.local` account exists with active profile and draft test case `bef5f781-a661-4ab1-a5c1-be05e1dcbf33` | Confirmed by smoke script preflight |

**Credential constraint (permanent):** Secrets are confirmed by name only. Values are never selected, displayed, logged, or sent to Claude, Codex, or any AI system.

---

## §3 Migration Verification (PC-8)

```sql
SELECT version
FROM supabase_migrations.schema_migrations
ORDER BY version;
```

Expected — exactly these six rows, in order:

```
20260807000000
20260807000001
20260807000002
20260807000003
20260807000004
20260807000005
20260807000006
```

`000006` is the terminal migration (`revoke_migration_grants`). Any divergence from this list is a hard stop.

---

## §4 Deployment Steps

Steps run in order. Each must succeed before the next begins.

### D-0 — Preflight: confirm secrets and migrations

```bash
supabase secrets list --project-ref hkfrbdpedrxmbsawnbpr
```

Expected: all eight names appear (values not shown, not recorded):
`CF_ACCESS_CLIENT_ID`, `CF_ACCESS_CLIENT_SECRET`, `CF_WORKER_URL`,
`R2_ENDPOINT`, `R2_BUCKET`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`,
`CRON_SECRET`

```sql
-- Vault check — name only, value never selected.
SELECT name FROM vault.decrypted_secrets WHERE name = 'CRON_SECRET';
-- Expected: 1 row
```

Run §3 migration verification. All must pass before D-1.

### D-1 — Deploy `upload-complete`

```bash
supabase functions deploy upload-complete \
  --project-ref hkfrbdpedrxmbsawnbpr
```

Expected: exit 0; dashboard shows `upload-complete` with a new deployment timestamp.

### D-2 — Deploy `upload-cleanup-worker`

```bash
supabase functions deploy upload-cleanup-worker \
  --project-ref hkfrbdpedrxmbsawnbpr
```

Expected: exit 0; dashboard shows `upload-cleanup-worker` with a new deployment timestamp.

**Note:** `verify_jwt = false` is applied automatically from committed `supabase/config.toml`. The `--no-verify-jwt` CLI flag is not used.

### D-3 — Smoke test: E2E upload flow

```bash
bash tools/run-step-b-phase2-smoke.sh
```

The launcher prompts for: smoke account password, DB password, CRON_SECRET, R2 endpoint, R2 access key ID, R2 secret access key, R2 bucket. It signs in via Supabase Auth (password cleared immediately after), exports secrets, and delegates to `tools/step-b-phase2-smoke-test.sh`.

**D-3 preflight (in smoke script):** Confirms smoke account exists with active profile, draft test case owned by smoke account, and zero active upload sessions.

**D-3 flow (steps 1–4):**

| Step | Action | Expected |
|---|---|---|
| 1 | POST `upload-authorize` with `{ case_id, content_type: "image/jpeg", declared_size_bytes: 13674 }` | HTTP 200; presigned_url, upload_token, expires_at present |
| 2 | PUT `tools/fixtures/smoke-test.jpg` to presigned_url | HTTP 200 |
| 3 | POST `upload-complete` with `{ upload_token }` (no sha256 field) | HTTP 200; body `{ status: "pending_review", media_object_id: <uuid> }` |
| 4 | DB assertions (see below) | All four pass |

**D-3 DB assertions:**

| Table | Column | Expected |
|---|---|---|
| `private.upload_sessions` | `status` | `complete` |
| `public.media_objects` | `status` | `pending_review` |
| `private.media_storage_keys` | `re_encoded_storage_key` | `display/<session_uuid>.webp` |
| `private.media_storage_keys` | `sha256_hash` | 64 lowercase hex chars (non-null) |

**D-3 teardown (in EXIT handler):** Runs unconditionally after each test run, pass or fail. Order:

1. Delete R2 original key (`originals/<session_uuid>`) — may already be absent (upload-complete deletes it at step 7 on the happy path); treated as success
2. Delete R2 display key (`display/<session_uuid>.webp`)
3. `DELETE FROM private.media_storage_keys WHERE media_object_id = ...`
4. `UPDATE private.upload_sessions SET media_object_id = NULL ...` (clears FK to media_objects)
5. `DELETE FROM public.media_objects WHERE id = ...`
6. `UPDATE private.upload_sessions SET status = 'failed', ...` (prevents cleanup-worker interaction)

Log output distinguishes test PASS/FAIL from CLEANUP PASS/FAIL. Any cleanup failure sets the overall result to FAIL.

### D-4 — Smoke test: `upload-cleanup-worker` auth gate

D-4 runs inside the same smoke script immediately after D-3.

| Case | Input | Expected |
|---|---|---|
| D-4a | No `X-Forkensics-Cron-Secret` header | HTTP 401 |
| D-4b | Wrong secret value | HTTP 401 |
| D-4c | Correct secret (prompted at launch, passed via chmod-0600 temp config file) | HTTP 200, body `{ status: "ok" }` |

**CRON_SECRET handling in D-4c:** The secret is never expanded in process arguments, never appears in log output, and is not echoed to stdout. It is written to a `mktemp` file with `chmod 0600`, passed to curl via `--config`, and deleted before the response is read.

### D-5 — Record deployment evidence

After D-3 and D-4 pass:
- Paste smoke script output (stdout only — log contains no secret values) into §7.
- Record dashboard deployment timestamps for both functions.
- Record the SHA-256 printed at the end of the smoke log.

---

## §5 Artifacts

### §5.1 New files (Phase 2)

| File | Description |
|---|---|
| `tools/fixtures/smoke-test.jpg` | Smoke test fixture (copy of `tools/image-spike/cf-spike/fixtures/fixture-exif.jpg`); 1200×900 JPEG, 13,674 bytes; exercises EXIF stripping |
| `tools/run-step-b-phase2-smoke.sh` | Interactive launcher — prompts for all secrets, signs in, exports env, delegates to smoke test |
| `tools/step-b-phase2-smoke-test.sh` | Smoke test — D-3 E2E flow + D-4 auth gate; EXIT-handler teardown |

### §5.2 Log redaction rules

The smoke test log (`08_Migration/tests/step-b-phase2-smoke-*.log`) must never contain:

- `presigned_url` value (URL-embedded HMAC signature)
- `ACCESS_TOKEN` value (JWT)
- `UPLOAD_TOKEN` value (upload session token)
- `CRON_SECRET` value
- `R2_ACCESS_KEY_ID` or `R2_SECRET_ACCESS_KEY` values
- `DB_URL` (contains database password)

These constraints are enforced in the script and must be verified before the log SHA-256 is recorded in §7.

---

## §6 Artifact Hash Summary

`bash -n` verified for both shell scripts. gitleaks must be run by Bill before approval.

| File | SHA-256 |
|---|---|
| `tools/fixtures/smoke-test.jpg` | `336bbb3e3f88a084d9a19956cda4937a0e9a1c211243ce2c9e2dc09ca3242c33` |
| `tools/run-step-b-phase2-smoke.sh` | `6886be11c403b030d2a195f5339dffe268983f43398a5e6575dcb8d425a7c330` |
| `tools/step-b-phase2-smoke-test.sh` | `04e35672862bd4faec7a69f296859e78bfd27205b3515100f46e5b0b93c2c816` |

---

## §7 Deployment Evidence

Populated after D-3 and D-4 pass.

| Item | Value |
|---|---|
| `upload-complete` deploy timestamp | TBD |
| `upload-cleanup-worker` deploy timestamp | TBD |
| Smoke log file | TBD (path printed by script) |
| Smoke log SHA-256 | TBD (printed by script) |
| D-4a result (missing header) | TBD |
| D-4b result (wrong secret) | TBD |
| D-4c result (correct secret) | TBD |

---

## §8 Rollback

If any smoke test fails after deployment:

```bash
supabase functions delete upload-complete \
  --project-ref hkfrbdpedrxmbsawnbpr

supabase functions delete upload-cleanup-worker \
  --project-ref hkfrbdpedrxmbsawnbpr
```

Upload sessions that completed the R2 PUT but did not reach `complete` state remain in `processing` or `failed` state. No database rollback is required — Phase 2 applies no migration.

---

## §9 Out of Scope

The following are explicitly deferred to Phase 2B (separate approval):

- `CREATE EXTENSION IF NOT EXISTS pg_cron`
- `cron.schedule('upload-cleanup-worker', ...)`
- Any Vault read of `CRON_SECRET` by a pg_net call
- Phase 2B migration and verification steps (documented in Step B Rev 5 §10.2)

---

## §10 Sign-off Table

| Party | Item | Status |
|---|---|---|
| Claude | Step B Phase 2 Rev 2 | Pending |
| Codex | Step B Phase 2 Rev 2 | Pending |
| Bill | Step B Phase 2 Rev 2 | Pending |
