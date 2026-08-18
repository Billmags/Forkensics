-- 08_Migration/rollback/V5__r2_storage_paths_rollback.sql
-- Restores reserve_upload_session to its V4 state (cases/{case_id}/... paths).
-- Apply ONLY after ingress has been quiesced and all active originals/ sessions
-- have been resolved (see Phase 2b rollback steps in §11).

BEGIN;

DO $$
DECLARE
  v_count bigint;
BEGIN
  SELECT COUNT(*) INTO v_count
  FROM private.upload_sessions
  WHERE status IN ('pending', 'processing', 'sanitized')
    AND original_storage_path LIKE 'originals/%';
  IF v_count > 0 THEN
    RAISE EXCEPTION
      'V5 rollback blocked: % session(s) in active state use new path format. '
      'Complete or fail them before rolling back.', v_count;
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.reserve_upload_session(
  p_case_id           uuid,
  p_uploader_id       uuid,
  p_token_hash        text,
  p_content_type      text,
  p_declared_size     bigint,
  p_client_expires_at timestamptz
)
RETURNS TABLE (session_id uuid, original_storage_path text, display_storage_path text)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_case       record;
  v_session_id uuid := gen_random_uuid();
  v_orig_path  text;
  v_disp_path  text;
BEGIN
  SELECT id, poster_id, state
  INTO v_case
  FROM public.cases
  WHERE id = p_case_id
  FOR UPDATE;

  IF NOT FOUND OR v_case.poster_id != p_uploader_id THEN
    RAISE EXCEPTION 'FK_NOT_FOUND';
  END IF;

  IF v_case.state != 'draft' THEN
    RAISE EXCEPTION 'FK_WRONG_STATE';
  END IF;

  IF EXISTS (
    SELECT 1 FROM private.deletion_log
    WHERE profile_id = p_uploader_id
      AND status IN ('database_prepared', 'auth_deleted')
  ) THEN
    RAISE EXCEPTION 'FK_FORBIDDEN';
  END IF;

  v_orig_path := 'cases/' || p_case_id::text || '/originals/' || v_session_id::text;
  v_disp_path := 'cases/' || p_case_id::text || '/displays/'  || v_session_id::text || '.webp';

  BEGIN
    INSERT INTO private.upload_sessions (
      session_id, upload_token_hash, case_id, uploader_id,
      original_storage_path, display_storage_path,
      content_type, declared_size_bytes, expires_at,
      storage_upload_expires_at, status, status_changed_at
    ) VALUES (
      v_session_id, p_token_hash, p_case_id, p_uploader_id,
      v_orig_path, v_disp_path,
      p_content_type, p_declared_size, p_client_expires_at,
      NULL, 'pending', now()
    );
  EXCEPTION
    WHEN unique_violation THEN
      RAISE EXCEPTION 'FK_UPLOAD_IN_PROGRESS';
  END;

  RETURN QUERY SELECT v_session_id, v_orig_path, v_disp_path;
END;
$$;

ALTER FUNCTION public.reserve_upload_session(uuid,uuid,text,text,bigint,timestamptz)
  OWNER TO forkensics_executor;
REVOKE ALL ON FUNCTION public.reserve_upload_session(uuid,uuid,text,text,bigint,timestamptz)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.reserve_upload_session(uuid,uuid,text,text,bigint,timestamptz)
  TO service_role;

COMMIT;
