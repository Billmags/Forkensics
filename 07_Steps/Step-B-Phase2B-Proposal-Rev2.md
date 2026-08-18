# Step B Phase 2B — pg_cron Scheduling Proposal Rev 2

**Governing spec:** Step B Rev 5 §10.2 (frozen).  
**Requires three-party approval before the migration is applied.**  
Magic word: `APPROVED: Step B Rev 5 — Phase 2B`

Changes from Rev 1 (four Codex corrections):

1. **P2B-V3 Step A**: Restored frozen Step B Rev 5 `net.http_post` call exactly — `timeout_milliseconds := 30000` added back; `body` cast to `'{}'::jsonb`.
2. **P2B-V3 Step B**: Added `left(content, 300) AS body_preview`; all four required assertions now stated explicitly (row exists, status 2xx, `timed_out = false`, `error_msg IS NULL`); all fields plus request ID recorded in §7 evidence.
3. **Migration fail-closed**: After `CREATE EXTENSION` but before `cron.schedule`, assert zero existing jobs named `upload-cleanup-worker` and raise if any row is found — prevents altering an unknown pre-existing job and ensures rollback only unschedules what this migration created.
4. **§3 wording**: Changed "both queries" to "all three queries".

---

## §1 Baseline

| Item | Value |
|---|---|
| Phase 2 baseline | Step B Phase 2 Rev 7, three-party approved 2026-08-18 |
| Phase 2 smoke evidence | `08_Migration/tests/step-b-phase2-smoke-20260818-152631.log` |
| Phase 2 smoke SHA-256 | `8ff60f825b9c394d5ede2a0a47fdee0dbb808f1ab7092920f9b43b002b23c508` |
| Target project | forkensics-dev (`hkfrbdpedrxmbsawnbpr`) |
| This phase deploys | pg_cron extension + `upload-cleanup-worker` cron job |
| Schedule | `*/15 * * * *` (every 15 minutes) |

---

## §2 Pre-conditions

All must be true before applying the migration. Any unmet pre-condition is a hard stop.

| # | Pre-condition | How to verify |
|---|---|---|
| PC-1 | Phase 2 complete and evidence confirmed | ✅ Done 2026-08-18 |
| PC-2 | Phase 2B three-party magic word issued | Pending |
| PC-3 | `pg_net` extension present | P2B-V0 query 1 |
| PC-4 | `postgres` role can read `vault.decrypted_secrets` | P2B-V0 query 2 |
| PC-5 | `CRON_SECRET` present in Vault | P2B-V0 query 3 — confirmed during Phase 2 D-0 |

---

## §3 P2B-V0 — Fail-closed pre-migration checks

Run all three queries before applying the migration. All three must pass.

```sql
-- 1. pg_net present
SELECT extname FROM pg_extension WHERE extname = 'pg_net';
-- Expected: 1 row

-- 2. postgres can read vault
SELECT has_table_privilege('postgres', 'vault.decrypted_secrets', 'SELECT') AS vault_readable;
-- Expected: true

-- 3. CRON_SECRET in Vault (name only — value never selected)
SELECT name FROM vault.decrypted_secrets WHERE name = 'CRON_SECRET';
-- Expected: 1 row
```

---

## §4 Migration

Create the migration file:

```bash
supabase migration new enable-pg-cron-schedule
```

Contents (paste exactly):

```sql
-- Phase 2B: enable pg_cron and schedule upload-cleanup-worker.
-- Three-party approved per Step B Rev 5 §10.2.
-- Pre-condition: P2B-V0 must pass before this migration is applied.

BEGIN;

CREATE EXTENSION IF NOT EXISTS pg_cron;

-- Fail-closed: assert no pre-existing job with this name exists.
-- cron.schedule on a duplicate name would alter an unknown job;
-- rollback would then unschedule something this migration did not create.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM cron.job WHERE jobname = 'upload-cleanup-worker'
  ) THEN
    RAISE EXCEPTION
      'upload-cleanup-worker job already exists — manual inspection required before Phase 2B can proceed';
  END IF;
END;
$$;

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
                               'Content-Type',              'application/json',
                               'X-Forkensics-Cron-Secret',  (
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

Apply the migration:

```bash
supabase db push --project-ref hkfrbdpedrxmbsawnbpr
```

Expected: exit 0; migration `enable-pg-cron-schedule` appears in dashboard migration history.

---

## §5 Verification

### P2B-V1 — Job created

```sql
SELECT jobname, schedule FROM cron.job WHERE jobname = 'upload-cleanup-worker';
-- Expected: 1 row; schedule = '*/15 * * * *'
```

### P2B-V2 — Extension present

```sql
SELECT extname FROM pg_extension WHERE extname = 'pg_cron';
-- Expected: 1 row
```

### P2B-V3 — End-to-end HTTP correlation

**Step A — dispatch a manual HTTP request and capture the request ID:**

```sql
SELECT net.http_post(
  url                  := 'https://hkfrbdpedrxmbsawnbpr.supabase.co/functions/v1/upload-cleanup-worker',
  headers              := jsonb_build_object(
                           'Content-Type',              'application/json',
                           'X-Forkensics-Cron-Secret',  (
                             SELECT decrypted_secret
                             FROM vault.decrypted_secrets
                             WHERE name = 'CRON_SECRET'
                             LIMIT 1
                           )
                         ),
  body                 := '{}'::jsonb,
  timeout_milliseconds := 30000
) AS request_id;
```

Note the returned `request_id`.

**Step B — wait 10 seconds, then verify the response:**

```sql
SELECT
  id,
  status_code,
  timed_out,
  error_msg,
  left(content, 300) AS body_preview
FROM net._http_response
WHERE id = <request_id from Step A>;
```

All four assertions must hold — any failure is a hard stop:

1. **Row exists** — the query returns exactly 1 row for the captured request ID.
2. **HTTP status is 2xx** — `status_code BETWEEN 200 AND 299`.
3. **Not timed out** — `timed_out = false`.
4. **No error** — `error_msg IS NULL`.

If `status_code = 401`: the Vault and Edge Function CRON_SECRET values do not match — re-verify both stores and re-run P2B-V3.

Record all five fields (`id`, `status_code`, `timed_out`, `error_msg`, `body_preview`) in §7.

---

## §6 Rollback

If any verification step fails after the migration is applied:

```sql
-- Unschedule the job only. Extension removal is out of scope.
SELECT cron.unschedule('upload-cleanup-worker');
```

Verify removal:

```sql
SELECT jobname FROM cron.job WHERE jobname = 'upload-cleanup-worker';
-- Expected: 0 rows
```

No TypeScript changes required — `upload-cleanup-worker` remains deployed and callable manually.

---

## §7 Deployment Evidence

Populated after all verification steps pass.

| Item | Value |
|---|---|
| Migration timestamp | 20260818194407 |
| P2B-V1 jobname | `upload-cleanup-worker` |
| P2B-V1 schedule | `*/15 * * * *` |
| P2B-V2 extname | `pg_cron` |
| P2B-V3 request_id | 1 |
| P2B-V3 status_code | 200 |
| P2B-V3 timed_out | false |
| P2B-V3 error_msg | NULL |
| P2B-V3 body_preview | `{"status":"ok"}` |

---

## §8 Sign-off Table

| Party | Item | Status |
|---|---|---|
| Claude | Step B Rev 5 — Phase 2B | ✅ APPROVED 2026-08-18 |
| Codex | Step B Rev 5 — Phase 2B | ✅ APPROVED 2026-08-18 |
| Bill | Step B Rev 5 — Phase 2B | ✅ APPROVED 2026-08-18 |

Three-party approval complete. Migration authorized to proceed per §4.
