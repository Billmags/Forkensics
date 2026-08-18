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
