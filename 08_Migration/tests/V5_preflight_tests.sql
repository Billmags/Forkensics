-- V5_preflight_tests.sql
-- Run BEFORE applying V5__r2_storage_paths.sql.

\set ON_ERROR_STOP on

BEGIN;

DO $$
DECLARE
  v_uid   uuid;
  v_gid   uuid;
  v_cid   uuid;
  v_ok    boolean := false;
  v_count bigint;
BEGIN
  SELECT uid, gid, cid INTO v_uid, v_gid, v_cid
  FROM test_helpers.make_scenario('V5_T1');

  INSERT INTO private.upload_sessions (
    session_id, upload_token_hash, case_id, uploader_id,
    original_storage_path, display_storage_path,
    content_type, declared_size_bytes, expires_at,
    storage_upload_expires_at, status, status_changed_at
  ) VALUES (
    gen_random_uuid(),
    encode(sha256(('V5_T1' || gen_random_uuid()::text)::bytea), 'hex'),
    v_cid, v_uid,
    'cases/' || v_cid::text || '/originals/' || gen_random_uuid()::text,
    'cases/' || v_cid::text || '/displays/'  || gen_random_uuid()::text || '.webp',
    'image/jpeg', 1048576,
    now() + interval '15 minutes',
    NULL, 'pending', now()
  );

  BEGIN
    SELECT COUNT(*) INTO v_count
    FROM private.upload_sessions
    WHERE status IN ('pending', 'processing', 'sanitized')
      AND (  original_storage_path LIKE 'cases/%'
          OR original_storage_path LIKE 'challenges/%');
    IF v_count > 0 THEN
      RAISE EXCEPTION
        'V5 cutover blocked: % session(s) in active state use legacy path format. '
        'Expire or fail them before applying this migration.', v_count;
    END IF;
    RAISE EXCEPTION 'T-V5-1 FAIL: preflight did not raise for nonterminal old-format session';
  EXCEPTION
    WHEN others THEN
      IF SQLERRM LIKE '%V5 cutover blocked%' THEN
        v_ok := true;
      ELSE
        RAISE;
      END IF;
  END;

  IF NOT v_ok THEN
    RAISE EXCEPTION 'T-V5-1 FAIL: unexpected code path';
  END IF;
  RAISE NOTICE 'T-V5-1 PASS: preflight correctly blocks nonterminal old-format session';
END;
$$;

ROLLBACK;  -- test fixtures rolled back; helper schema and prior migrations remain
