# Step B Phase 2 — forkensics-dev Deployment Proposal Rev 7

**Requires three-party approval before any deploy command is run.**
Magic word: `APPROVED: Step B Phase 2 Rev 7`

Changes from Rev 6 (five §8 corrections):

1. **mktemp path**: Trailing `X`s only — `/tmp/forkensics-rollback-XXXXXX` (no `.tsv` suffix; the suffix prevented macOS `mktemp` from randomizing).
2. **Manifest file validation**: Now checks exact path regex (`^/tmp/forkensics-rollback-[A-Za-z0-9]{6}$`), regular-file status, non-symlink status, ownership (`stat` uid == `id -u`), and mode `0600`.
3. **Key validation**: Changed from prefix matching (`originals/*`, `display/*`) to exact per-session comparison: `originals/${_sid}` and `display/${_sid}.webp`.
4. **r2-cleanup-helper exit codes**: `_r2_rc=0; deno ... || _r2_rc=$?` — the `||` prevents `set -e` from triggering on exit 1; exit code is captured correctly in all shell configurations.
5. **Per-session failed verification**: New step 7a verifies each manifest session has `status='failed'` specifically before any R2 key is deleted. Zero-active-sessions assertion alone (step 6) passes if a session unexpectedly became `complete`; this catches that case.

Script (`tools/step-b-phase2-smoke-test.sh`) is unchanged from Rev 6; hash is identical.

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

**D-3 flow:**

| Step | Action | Pass criterion |
|---|---|---|
| Preflight | Account, profile, case (draft, `media_object_id IS NULL`), active sessions (0) | All four pass |
| 1 | POST `upload-authorize` `{ case_id, content_type: "image/jpeg", declared_size_bytes: 13674 }` | HTTP 200; presigned\_url, upload\_token, expires\_at; key matches `originals/<uuid-v4>`; SESSION\_ID set immediately |
| 2 | PUT `tools/fixtures/smoke-test.jpg` to presigned\_url | HTTP 200 |
| 3 | POST `upload-complete` `{ upload_token }`; token unset immediately | HTTP 200; `body.status = "pending_review"`; `media_object_id` present |
| 4 | DB assertions | All pass |

**D-3 EXIT handler teardown — three ordered phases:**

Phase 1 (DB re-query + ownership validation) runs before any R2 action. `uploader_id`, `case_id`, and `original_storage_path` must match. Failure skips phases 2 and 3. DB `media_object_id` overrides HTTP response value.

Phase 2 (R2 teardown — gated on Phase 1 pass). Exit codes 0 and 1 are both success.

Phase 3 (DB teardown — gated on Phase 1 pass). Full path: single guarded transaction with FOR UPDATE, NOT FOUND checks, postcondition verification before COMMIT. Partial path: transaction with FOR UPDATE, NOT FOUND check, `complete` detection, postcondition verify.

Log-redaction assertion greps for `eyJ` and `X-Amz-Signature=`/`X-Amz-Credential=` before the evidence hash.

### D-4 — Smoke test: `upload-cleanup-worker` auth gate

| Case | Input | Expected |
|---|---|---|
| D-4a | No `X-Forkensics-Cron-Secret` | HTTP 401 |
| D-4b | Wrong secret value | HTTP 401 |
| D-4c | Correct secret (chmod-0600 temp file, `--config`, deleted before response read) | HTTP 200, `body.status = "ok"` |

### D-5 — Record deployment evidence

Paste smoke stdout (no secret values) into §7; record dashboard timestamps and smoke log SHA-256.

---

## §5 Artifacts

### §5.1 New files (Phase 2)

| File | Description |
|---|---|
| `tools/fixtures/smoke-test.jpg` | 1200×900 JPEG, 13,674 bytes; exercises EXIF stripping |
| `tools/run-step-b-phase2-smoke.sh` | Launcher — prompts for all secrets, signs in, calls smoke test |
| `tools/step-b-phase2-smoke-test.sh` | Smoke test — D-3 E2E + D-4 auth gate; ownership-first teardown |

### §5.2 Log redaction

**Assertion-checked**: `eyJ` (JWT); `X-Amz-Signature=`/`X-Amz-Credential=` (presigned URL params).

**Protected by design**: presigned\_url, ACCESS\_TOKEN, UPLOAD\_TOKEN, CRON\_SECRET, R2 credential values, DB\_URL.

**Intentionally logged**: ORIG\_KEY, DISPLAY\_KEY (R2 object paths — session UUIDs, not secrets).

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
| `upload-complete` deploy timestamp | 2026-08-18 |
| `upload-cleanup-worker` deploy timestamp | 2026-08-18 |
| Smoke log file | `08_Migration/tests/step-b-phase2-smoke-20260818-152631.log` |
| Smoke log SHA-256 | `8ff60f825b9c394d5ede2a0a47fdee0dbb808f1ab7092920f9b43b002b23c508` |
| D-3 result | PASS — all 9 assertions green; teardown clean; redaction PASS |
| D-4a result | PASS — missing secret → 401 |
| D-4b result | PASS — wrong secret → 401 |
| D-4c result | PASS — correct secret → 200, body.status = ok |

---

## §8 Rollback

If any smoke test fails after D-1/D-2, follow these steps in strict order.

**Step 1 — Quiesce: delete upload-authorize:**

```bash
supabase functions delete upload-authorize \
  --project-ref hkfrbdpedrxmbsawnbpr
```

**Step 2 — Confirm deletion (explicit exit code capture; both conditions required):**

```bash
_confirm_rc=0
_confirm_status=$(curl -s -o /dev/null -w "%{http_code}" \
  -X POST "https://hkfrbdpedrxmbsawnbpr.supabase.co/functions/v1/upload-authorize" \
  -H "Content-Type: application/json") || _confirm_rc=$?
echo "curl exit: ${_confirm_rc}  HTTP: ${_confirm_status}"
```

Required: `_confirm_rc` is `0` **and** `_confirm_status` is `404`. Any other combination — non-zero curl exit (network failure) or unexpected HTTP status — is a hard stop; investigate before proceeding.

**Step 3 — Wait 420 seconds:**

```bash
sleep 420
```

**Step 4 — Capture session manifest (before marking anything failed):**

```bash
# Trailing X's only — no suffix. macOS mktemp requires trailing X's.
_manifest=$(mktemp /tmp/forkensics-rollback-XXXXXX)
chmod 0600 "${_manifest}"

# Validate path, type, ownership, and mode before first use.
[[ "${_manifest}" =~ ^/tmp/forkensics-rollback-[A-Za-z0-9]{6}$ ]] \
  || { echo "FAIL: unexpected manifest path '${_manifest}'"; exit 1; }
[[ -f "${_manifest}" ]] \
  || { echo "FAIL: manifest is not a regular file"; exit 1; }
[[ ! -L "${_manifest}" ]] \
  || { echo "FAIL: manifest is a symlink"; exit 1; }
[[ "$(stat -c%u "${_manifest}" 2>/dev/null || stat -f%u "${_manifest}")" == "$(id -u)" ]] \
  || { echo "FAIL: manifest not owned by current user"; exit 1; }
_mmode=$(stat -c%a "${_manifest}" 2>/dev/null || stat -f%Lp "${_manifest}")
[[ "${_mmode}" == "600" ]] \
  || { echo "FAIL: manifest mode is ${_mmode}, expected 600"; exit 1; }

# Write machine-readable tab-separated output.
psql "${DB_URL}" -t -A -F $'\t' -c "
SELECT session_id::text,
       COALESCE(original_storage_path, ''),
       COALESCE(display_storage_path,  '')
  FROM private.upload_sessions
 WHERE status IN ('pending','processing','sanitized')
 ORDER BY created_at;" > "${_manifest}"

# Deduplicate exact lines.
sort -u "${_manifest}" -o "${_manifest}"

echo "Manifest: $(wc -l < "${_manifest}") session(s) — preserve until step 10."
```

**Step 4a — Validate every manifest line (exact key format) before any update or deletion:**

```bash
_uuid_re='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
while IFS=$'\t' read -r _sid _orig _disp; do
  # Validate session UUID format.
  [[ "${_sid}" =~ ${_uuid_re} ]] \
    || { echo "FAIL: invalid session_id '${_sid}'"; exit 1; }
  # Validate original key is exactly originals/<sid> (or empty if not yet uploaded).
  [[ -z "${_orig}" || "${_orig}" == "originals/${_sid}" ]] \
    || { echo "FAIL: original_storage_path '${_orig}' != 'originals/${_sid}'"; exit 1; }
  # Validate display key is exactly display/<sid>.webp (or empty if worker never ran).
  [[ -z "${_disp}" || "${_disp}" == "display/${_sid}.webp" ]] \
    || { echo "FAIL: display_storage_path '${_disp}' != 'display/${_sid}.webp'"; exit 1; }
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

**Step 6 — Assert zero active sessions:**

```sql
SELECT COUNT(*) FROM private.upload_sessions
WHERE status IN ('pending','processing','sanitized');
-- Expected: 0. Hard stop if non-zero.
```

**Step 7a — Verify every manifest session is specifically `failed` (not `complete`):**

This check is distinct from step 6. Zero active sessions also passes if a session became `complete`; this catches that case before any R2 key is deleted.

```bash
while IFS=$'\t' read -r _sid _ _; do
  _sess_status=$(psql "${DB_URL}" -t -A -c \
    "SELECT status FROM private.upload_sessions \
      WHERE session_id = '${_sid}'::uuid;")
  [[ "${_sess_status}" == "failed" ]] \
    || { echo "FAIL: session ${_sid} status='${_sess_status}', expected 'failed'"; exit 1; }
done < "${_manifest}"
echo "Per-session failed verification: PASS"
```

**Step 7b — Clean R2 keys for manifest sessions only:**

`_r2_rc=0; deno ... || _r2_rc=$?` — the `||` prevents `set -e` from aborting on non-zero exit; the exit code is captured explicitly.

```bash
while IFS=$'\t' read -r _sid _orig _disp; do
  for _key in "${_orig}" "${_disp}"; do
    [[ -z "${_key}" ]] && continue
    _r2_rc=0
    deno run --allow-net --allow-env --allow-sys \
      tools/r2-cleanup-helper.ts "${_key}" || _r2_rc=$?
    # 0 = deleted and confirmed absent; 1 = already absent; 2 = error
    if [[ "${_r2_rc}" -le 1 ]]; then
      echo "R2 OK: ${_key} (exit ${_r2_rc})"
    else
      echo "FAIL: r2-cleanup-helper exited ${_r2_rc} for ${_key}"
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
rm -f "${_manifest}"
echo "Manifest removed. Rollback complete."
```

If any step fails before step 10, preserve `${_manifest}` for investigation. Do not delete it on failure.

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
| Claude | Step B Phase 2 Rev 7 | ✅ APPROVED 2026-08-18 |
| Codex | Step B Phase 2 Rev 7 | ✅ APPROVED 2026-08-18 |
| Bill | Step B Phase 2 Rev 7 | ✅ APPROVED 2026-08-18 |

Three-party approval complete. Deployment authorized to proceed per §4.
