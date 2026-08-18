# Step B Phase 2 — forkensics-dev Deployment Proposal Rev 6

**Requires three-party approval before any deploy command is run.**
Magic word: `APPROVED: Step B Phase 2 Rev 6`

Changes from Rev 5:

1. **Blocker 1 — R2 deleted before ownership confirmed**: The DB re-query and ownership validation (`uploader_id`, `case_id`, `original_storage_path`) now run as Phase 1, before either `r2_teardown` call. R2 teardown (Phase 2) and DB teardown (Phase 3) are both gated on `_td_owner_ok=1`. If the session is missing or ownership fails, no R2 keys are deleted and no DB writes are made.

2. **Blocker 2b — rollback manifest contract**: §8 now specifies a fully fail-closed manifest procedure:
   - `mktemp` file, `chmod 0600`, regular-file/non-symlink/ownership checks before first use
   - Machine-readable tab-separated output (`session_id`, `original_storage_path`, `display_storage_path`)
   - `sort -u` deduplication before validation
   - Strict UUID and key-prefix format validation (`originals/`, `display/`) for every line before any DB update or R2 deletion
   - `r2-cleanup-helper.ts` called per key; exit code checked immediately (0/1 = success, 2 = failure)
   - Manifest preserved until all DB and R2 postconditions pass; removed only on full success
   - Step 2 curl exit code explicitly captured with `|| _confirm_rc=$?`; both curl exit 0 and HTTP 404 are required

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

All four must pass before D-1.

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

**D-3 EXIT handler teardown — three ordered phases:**

**Phase 1 — DB re-query and ownership validation (before any R2 action):**

The session is re-queried from the DB by `SESSION_ID`. `uploader_id`, `case_id`, and `original_storage_path` are validated against the values established during preflight and step 1. Any mismatch, or a missing session row, is a hard cleanup failure that also skips phases 2 and 3. The DB's `media_object_id` overrides the HTTP response value.

**Phase 2 — R2 teardown (only if Phase 1 passes):**

`r2_teardown` is called for `ORIG_KEY` and `DISPLAY_KEY`. Exit code 0 (deleted) and 1 (already absent) are both success. Upload-complete deletes the original on the happy path, so exit 1 on ORIG\_KEY is expected.

**Phase 3 — DB teardown (only if Phase 1 passes):**

Full path (DB `media_object_id` non-empty): single guarded transaction — `FOR UPDATE` + `NOT FOUND` check on case, NULL out `cases.media_object_id`, delete storage keys, clear session FKs, delete media object, mark session failed, verify all postconditions (`NOT FOUND` on case is explicit failure), COMMIT.

Partial path (DB `media_object_id` empty): single transaction — `SELECT ... FOR UPDATE`, `NOT FOUND` check, `IF status = 'complete' THEN RAISE`, UPDATE, postcondition SELECT verifying `status = 'failed'`, COMMIT.

**Log-redaction assertion (in EXIT handler, before evidence hash):**

Greps log for `eyJ` (JWT pattern) and `X-Amz-Signature=` / `X-Amz-Credential=`. Any match fails the run.

### D-4 — Smoke test: `upload-cleanup-worker` auth gate

| Case | Input | Expected |
|---|---|---|
| D-4a | No `X-Forkensics-Cron-Secret` | HTTP 401 |
| D-4b | Wrong secret value | HTTP 401 |
| D-4c | Correct secret (via curl `--config` file, chmod 0600, registered in `_TEMP_FILES`, deleted before response read) | HTTP 200, `body.status = "ok"` |

PASS/FAIL logging is exclusive per case. `=== D-4: PASS ===` prints only when all three cases pass.

### D-5 — Record deployment evidence

After D-3 and D-4 pass: paste smoke stdout (no secret values) into §7, record dashboard timestamps, record smoke log SHA-256.

---

## §5 Artifacts

### §5.1 New files (Phase 2)

| File | Description |
|---|---|
| `tools/fixtures/smoke-test.jpg` | Copy of `fixture-exif.jpg`; 1200×900 JPEG, 13,674 bytes; exercises EXIF stripping |
| `tools/run-step-b-phase2-smoke.sh` | Launcher — prompts for all secrets, signs in, exports env, calls smoke test |
| `tools/step-b-phase2-smoke-test.sh` | Smoke test — D-3 E2E + D-4 auth gate; ownership-first teardown; log-redaction assertion |

### §5.2 Log redaction

**Protected by log-redaction assertion** (grep checks — any match fails the run): JWT pattern `eyJ`; `X-Amz-Signature=` / `X-Amz-Credential=`.

**Protected by design** (never passed to `log()`): presigned\_url, ACCESS\_TOKEN, UPLOAD\_TOKEN, CRON\_SECRET, R2 credential values, DB\_URL.

**Intentionally logged** (not credentials): ORIG\_KEY, DISPLAY\_KEY (R2 object paths — session UUIDs, not secrets).

---

## §6 Artifact Hash Summary

`bash -n` verified. gitleaks must be run by Bill before approval.

| File | SHA-256 |
|---|---|
| `tools/fixtures/smoke-test.jpg` | `336bbb3e3f88a084d9a19956cda4937a0e9a1c211243ce2c9e2dc09ca3242c33` |
| `tools/run-step-b-phase2-smoke.sh` | `6886be11c403b030d2a195f5339dffe268983f43398a5e6575dcb8d425a7c330` |
| `tools/step-b-phase2-smoke-test.sh` | `1b2fc067b57f9d3d97aef6c1269987ef97cf80a91db2f4b0e0ff00656224b77b` |

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

If any smoke test fails after D-1/D-2, follow these steps in strict order. Steps may not be reordered.

**Step 1 — Quiesce: delete upload-authorize (prevents all new sessions):**

```bash
supabase functions delete upload-authorize \
  --project-ref hkfrbdpedrxmbsawnbpr
```

**Step 2 — Confirm deletion (explicit exit code; both conditions required):**

```bash
_confirm_rc=0
_confirm_status=$(curl -s -o /dev/null -w "%{http_code}" \
  -X POST "https://hkfrbdpedrxmbsawnbpr.supabase.co/functions/v1/upload-authorize" \
  -H "Content-Type: application/json") || _confirm_rc=$?
echo "curl exit: ${_confirm_rc}  HTTP: ${_confirm_status}"
```

Required: `_confirm_rc` is 0 **and** `_confirm_status` is `404`. Any other combination — including non-zero curl exit (network failure) or unexpected HTTP status — is a hard stop. Investigate before proceeding.

**Step 3 — Wait 420 seconds:**

```bash
sleep 420
```

No new sessions can be created after step 1. Any in-flight `authorize→PUT` sequences will have presigned URLs that expire within this window.

**Step 4 — Capture session manifest before marking anything failed:**

```bash
# Create manifest file: mode 0600, regular file, owned by current user.
_manifest=$(mktemp /tmp/forkensics-rollback-XXXXXX.tsv)
chmod 0600 "${_manifest}"

# Validate manifest file properties before use.
[[ -f "${_manifest}" && ! -L "${_manifest}" ]] \
  || { echo "FAIL: manifest is not a regular non-symlink file"; exit 1; }
[[ "$(stat -c%u "${_manifest}" 2>/dev/null || stat -f%u "${_manifest}")" == "$(id -u)" ]] \
  || { echo "FAIL: manifest not owned by current user"; exit 1; }

# Write machine-readable tab-separated output.
psql "${DB_URL}" -t -A -F $'\t' -c "
SELECT session_id::text,
       COALESCE(original_storage_path, ''),
       COALESCE(display_storage_path,  '')
  FROM private.upload_sessions
 WHERE status IN ('pending','processing','sanitized')
 ORDER BY created_at;" > "${_manifest}"

# Deduplicate (exact-line).
sort -u "${_manifest}" -o "${_manifest}"

echo "Manifest: $(wc -l < "${_manifest}") session(s) at ${_manifest}"
echo "DO NOT delete ${_manifest} until all postconditions pass."
```

**Step 4a — Validate every manifest line before any update or deletion:**

```bash
_uuid_re='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
while IFS=$'\t' read -r _sid _orig _disp; do
  [[ "${_sid}" =~ ${_uuid_re} ]] \
    || { echo "FAIL: invalid session_id '${_sid}'"; exit 1; }
  [[ -z "${_orig}" || "${_orig}" == originals/* ]] \
    || { echo "FAIL: invalid original_storage_path '${_orig}'"; exit 1; }
  [[ -z "${_disp}" || "${_disp}" == display/* ]] \
    || { echo "FAIL: invalid display_storage_path '${_disp}'"; exit 1; }
done < "${_manifest}"
echo "Manifest validation: PASS"
```

**Step 5 — Mark manifest sessions failed:**

```bash
while IFS=$'\t' read -r _sid _ _; do
  psql "${DB_URL}" -c "
    UPDATE private.upload_sessions
       SET status = 'failed', failed_reason = 'FK_INTERNAL', status_changed_at = now()
     WHERE session_id = '${_sid}'::uuid
       AND status NOT IN ('complete','failed');"
done < "${_manifest}"
```

**Step 6 — Assert zero active sessions (hard stop if any remain):**

```sql
SELECT COUNT(*) FROM private.upload_sessions
WHERE status IN ('pending','processing','sanitized');
-- Expected: 0
```

**Step 7 — Clean R2 keys for manifest sessions only; verify absence after each deletion:**

```bash
while IFS=$'\t' read -r _sid _orig _disp; do
  for _key in "${_orig}" "${_disp}"; do
    [[ -z "${_key}" ]] && continue
    deno run --allow-net --allow-env --allow-sys \
      tools/r2-cleanup-helper.ts "${_key}"
    _r2_rc=$?
    # 0 = deleted and confirmed absent; 1 = already absent; 2 = error
    if [[ "${_r2_rc}" -le 1 ]]; then
      echo "R2 CLEANUP OK: ${_key} (exit ${_r2_rc})"
    else
      echo "R2 CLEANUP FAIL: ${_key} — r2-cleanup-helper exited ${_r2_rc}"
      exit 1
    fi
  done
done < "${_manifest}"
```

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

**Step 10 — Remove manifest only after all postconditions pass:**

```bash
# Run only after steps 5–9 have all succeeded without error.
rm -f "${_manifest}"
echo "Manifest removed: rollback complete."
```

If any step fails before step 10, preserve `${_manifest}` for investigation.

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
| Claude | Step B Phase 2 Rev 6 | Pending |
| Codex | Step B Phase 2 Rev 6 | Pending |
| Bill | Step B Phase 2 Rev 6 | Pending |
