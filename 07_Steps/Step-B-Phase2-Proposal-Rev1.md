# Step B Phase 2 — forkensics-dev Deployment Proposal Rev 1

**Requires three-party approval before any deploy command is run.**
Magic word: `APPROVED: Step B Phase 2 Rev 1`

---

## §1 Baseline

| Item | Value |
|---|---|
| Phase 1 baseline | Step B Rev 5, three-party approved 2026-08-18 |
| Phase 1 static check result | PASS: 24, FAIL: 0 |
| Target project | forkensics-dev (`hkfrbdpedrxmbsawnbpr`) |
| Functions to deploy | `upload-complete`, `upload-cleanup-worker` |
| Phase 2B (pg_cron) | Separate approval — not in scope here |

---

## §2 Pre-conditions

All of the following must be confirmed true before D-0 is run. Any unmet pre-condition is a hard stop.

| # | Pre-condition | How to verify |
|---|---|---|
| PC-1 | Phase 1 three-party approval recorded in Step B Rev 5 §11 | ✅ Done 2026-08-18 |
| PC-2 | `CF_ACCESS_CLIENT_ID` set in forkensics-dev Edge Function secrets | `supabase secrets list --project-ref hkfrbdpedrxmbsawnbpr` — name appears |
| PC-3 | `CF_ACCESS_CLIENT_SECRET` set in forkensics-dev Edge Function secrets | same list — name appears |
| PC-4 | `CF_WORKER_URL` set in forkensics-dev Edge Function secrets | same list — name appears |
| PC-5 | `R2_ENDPOINT`, `R2_BUCKET`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY` set | same list — all four names appear |
| PC-6 | `CRON_SECRET` set in Edge Function secrets | same list — name appears |
| PC-7 | `CRON_SECRET` set in Supabase Vault | `SELECT name FROM vault.decrypted_secrets WHERE name = 'CRON_SECRET'` → 1 row |
| PC-8 | V5 migration applied on forkensics-dev | `SELECT version FROM supabase_migrations.schema_migrations ORDER BY version DESC LIMIT 1` — `20260807000004` |
| PC-9 | forkensics-dev CF Worker smoke test previously passed | CF-Worker-Prod-Proposal-Rev3 §evidence |
| PC-10 | `upload-authorize` previously deployed and smoke-tested | Step A Rev 9 evidence |

**Credential constraint:** Secrets are confirmed by name only. Values are never selected, displayed, logged, or sent to Claude, Codex, or any AI system. This constraint is permanent and cannot be overridden.

---

## §3 Deployment Steps

Steps run in order. Each step must succeed before the next begins.

### D-0 — Preflight: confirm secrets

```bash
supabase secrets list --project-ref hkfrbdpedrxmbsawnbpr
```

Expected: the following names all appear (values are not shown or recorded):
`CF_ACCESS_CLIENT_ID`, `CF_ACCESS_CLIENT_SECRET`, `CF_WORKER_URL`,
`R2_ENDPOINT`, `R2_BUCKET`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`,
`CRON_SECRET`

```sql
-- Vault check — name only, value never selected.
SELECT name FROM vault.decrypted_secrets WHERE name = 'CRON_SECRET';
-- Expected: 1 row
```

Both checks must pass. If either fails, stop and resolve before continuing.

### D-1 — Deploy `upload-complete`

```bash
supabase functions deploy upload-complete \
  --project-ref hkfrbdpedrxmbsawnbpr
```

Expected: command exits 0; Supabase dashboard shows `upload-complete` with a new deployment timestamp.

### D-2 — Deploy `upload-cleanup-worker`

```bash
supabase functions deploy upload-cleanup-worker \
  --project-ref hkfrbdpedrxmbsawnbpr
```

Expected: command exits 0; dashboard shows `upload-cleanup-worker` with a new deployment timestamp.

**Note:** `verify_jwt = false` is applied automatically from the committed `supabase/config.toml`. The `--no-verify-jwt` CLI flag is not used.

### D-3 — Smoke test: end-to-end upload flow

Run via `tools/run-step-b-smoke.sh` (written and `bash -n` verified before this step runs — see §5).

The script performs:
1. Call `upload-authorize` with a valid user JWT → receive `upload_token` and `presigned_url`.
2. PUT a fixture JPEG to the presigned R2 URL.
3. POST to `upload-complete` with the `upload_token` and the fixture SHA-256.
4. Poll `upload_sessions` for up to 30 s until `status = 'pending_review'`.
5. Assert `media_objects` row exists with `display_storage_key` set and non-null `sha256`.

Pass criteria: all five steps succeed with no error codes returned.

### D-4 — Smoke test: `upload-cleanup-worker` auth gate

```bash
# Missing header → must return 401 with FK error body
curl -s -o /dev/null -w "%{http_code}" \
  -X POST \
  https://hkfrbdpedrxmbsawnbpr.supabase.co/functions/v1/upload-cleanup-worker

# Wrong secret → must return 401
curl -s -o /dev/null -w "%{http_code}" \
  -X POST \
  -H "X-Forkensics-Cron-Secret: wrongvalue" \
  https://hkfrbdpedrxmbsawnbpr.supabase.co/functions/v1/upload-cleanup-worker
```

Both must return `401`. The correct-secret invocation is performed only via the D-0 Vault SQL path in Phase 2B — it is not tested here with a live secret value in a shell command.

### D-5 — Record deployment evidence

After D-3 and D-4 pass, record:
- SHA-256 of the smoke test run log (stdout captured to file, then `shasum -a 256`).
- Supabase dashboard deployment timestamp for both functions.
- Paste full output into §7 of this document.

---

## §4 Smoke Test Script

`tools/run-step-b-smoke.sh` must be written, `bash -n` verified, and its SHA-256 recorded in §6 before Phase 2 approval is granted and before D-3 runs.

### Script contract

**Inputs (environment variables set by caller — never hardcoded):**
```
SUPABASE_URL
SUPABASE_PUBLISHABLE_KEY
FUNCTION_URL          # base URL for edge functions
TEST_USER_JWT         # valid JWT for a test user in forkensics-dev
UPLOAD_COMPLETE_URL   # full URL to upload-complete function
```

**Fixture:** a small known JPEG (`tools/fixtures/smoke-test.jpg`) whose SHA-256 is hardcoded in the script for assertion. The fixture must already exist (it was created during Step A integration test work).

**Outputs:** to stdout; final line is either `SMOKE PASS` or `SMOKE FAIL: <reason>`.

**Credential constraint:** `CRON_SECRET`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `CF_ACCESS_CLIENT_ID`, `CF_ACCESS_CLIENT_SECRET` are never read or referenced by the smoke script. The presigned URL is obtained from `upload-authorize` and used directly — R2 credentials are never in the script.

### Script steps (shell pseudocode)

```bash
# Step 1 — authorize
RESPONSE=$(curl -s -X POST "$FUNCTION_URL/upload-authorize" \
  -H "Authorization: Bearer $TEST_USER_JWT" \
  -H "Content-Type: application/json" \
  -d '{"content_type":"image/jpeg","byte_size":FIXTURE_SIZE}')

UPLOAD_TOKEN=$(echo "$RESPONSE" | jq -r '.upload_token')
PRESIGNED_URL=$(echo "$RESPONSE" | jq -r '.presigned_url')
[ "$UPLOAD_TOKEN" = "null" ] && fail "authorize returned no upload_token"

# Step 2 — PUT to R2
curl -s -X PUT "$PRESIGNED_URL" \
  -H "Content-Type: image/jpeg" \
  --data-binary @tools/fixtures/smoke-test.jpg \
  -w "%{http_code}" -o /dev/null | grep -q "^200$" || fail "R2 PUT failed"

# Step 3 — complete
COMPLETE=$(curl -s -X POST "$UPLOAD_COMPLETE_URL" \
  -H "Authorization: Bearer $TEST_USER_JWT" \
  -H "Content-Type: application/json" \
  -d "{\"upload_token\":\"$UPLOAD_TOKEN\",\"sha256\":\"$FIXTURE_SHA256\"}")

CODE=$(echo "$COMPLETE" | jq -r '.error.code // "none"')
[ "$CODE" != "none" ] && fail "upload-complete returned error: $CODE"

# Step 4 — poll for pending_review (max 30 s)
# ... poll logic ...

# Step 5 — assert media_objects row
# ... assert logic ...

echo "SMOKE PASS"
```

---

## §5 New Artifacts in This Phase

| File | Description | Must exist before |
|---|---|---|
| `tools/run-step-b-smoke.sh` | End-to-end smoke test script (D-3) | Phase 2 approval / D-3 |

The script must pass `bash -n` and gitleaks before Phase 2 approval. Its SHA-256 is recorded in §6.

---

## §6 Artifact Hash Summary

Populated after `run-step-b-smoke.sh` is written and verified. Required before Phase 2 sign-off.

| File | SHA-256 |
|---|---|
| `tools/run-step-b-smoke.sh` | TBD |

---

## §7 Deployment Evidence

Populated after D-3 and D-4 pass.

| Item | Value |
|---|---|
| `upload-complete` deploy timestamp | TBD |
| `upload-cleanup-worker` deploy timestamp | TBD |
| D-3 smoke test log SHA-256 | TBD |
| D-4 result (missing header) | TBD |
| D-4 result (wrong secret) | TBD |

---

## §8 Rollback

If any smoke test fails after deployment:

```bash
# Remove the failing function (does not affect upload-authorize or db state)
supabase functions delete upload-complete \
  --project-ref hkfrbdpedrxmbsawnbpr

supabase functions delete upload-cleanup-worker \
  --project-ref hkfrbdpedrxmbsawnbpr
```

Upload sessions that completed the R2 PUT but did not reach `pending_review` remain in `processing` state. They will be resolved manually or by re-deploying a corrected function. No database rollback is required for Phase 2 — no migration is applied.

---

## §9 Out of Scope

The following are explicitly deferred to Phase 2B (separate approval):

- `CREATE EXTENSION IF NOT EXISTS pg_cron`
- `cron.schedule('upload-cleanup-worker', ...)`
- Any Vault read of `CRON_SECRET` by a pg_net call
- V5-related pg_cron migration

---

## §10 Open Questions Before Approval

1. **Smoke test fixture** — does `tools/fixtures/smoke-test.jpg` already exist from Step A integration work, or does it need to be created? If it needs to be created, what are the fixture dimensions/byte-size constraints?
2. **Test user JWT** — is there an existing forkensics-dev test user whose JWT can be used for D-3, or does one need to be minted (and if so, via what method)?
3. **`run-step-b-smoke.sh` write timing** — should the script be written and verified before Codex review of this proposal, or after approval with a separate sign-off on the script hash?

---

## §11 Sign-off Table

| Party | Item | Status |
|---|---|---|
| Claude | Step B Phase 2 Rev 1 | Pending |
| Codex | Step B Phase 2 Rev 1 | Pending |
| Bill | Step B Phase 2 Rev 1 | Pending |
