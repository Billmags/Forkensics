-- V5_postapply_tests.sql
-- Run AFTER applying V5__r2_storage_paths.sql.
-- Test fixtures rolled back; V5 migration remains installed.

\set ON_ERROR_STOP on

BEGIN;

DO $$
DECLARE
  v_uid       uuid;
  v_gid       uuid;
  v_cid       uuid;
  v_sid       uuid;
  v_orig      text;
  v_disp      text;
  v_count     bigint;
  v_prosecdef boolean;
  v_owner     name;
  UUID_V4_RE  constant text :=
    '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$';
BEGIN
  SELECT uid, gid, cid INTO v_uid, v_gid, v_cid
  FROM test_helpers.make_scenario('V5_T2');

  SELECT r.session_id, r.original_storage_path, r.display_storage_path
  INTO   v_sid, v_orig, v_disp
  FROM   public.reserve_upload_session(
           v_cid, v_uid,
           test_helpers.make_token_hash('V5_T2'),
           'image/jpeg', 1048576,
           now() + interval '15 minutes'
         ) AS r(session_id, original_storage_path, display_storage_path);

  PERFORM test_helpers.assert(
    v_orig = 'originals/' || v_sid::text,
    'T-V5-2: original_storage_path = originals/{session_id}');

  PERFORM test_helpers.assert(
    v_disp = 'display/' || v_sid::text || '.webp',
    'T-V5-3: display_storage_path = display/{session_id}.webp');

  PERFORM test_helpers.assert(
    v_sid::text ~ UUID_V4_RE,
    'T-V5-4: session_id is lowercase UUID v4');

  SELECT pd.prosecdef, pr.rolname
  INTO   v_prosecdef, v_owner
  FROM   pg_proc pd
  JOIN   pg_namespace pn ON pn.oid = pd.pronamespace
  JOIN   pg_roles     pr ON pr.oid = pd.proowner
  WHERE  pn.nspname = 'public'
    AND  pd.proname = 'reserve_upload_session';

  PERFORM test_helpers.assert(v_prosecdef = true,
    'T-V5-5a: function is SECURITY DEFINER');
  PERFORM test_helpers.assert(v_owner = 'forkensics_executor',
    'T-V5-5b: owner = forkensics_executor');
  PERFORM test_helpers.assert(
    NOT pg_catalog.has_function_privilege(
      'anon',
      'public.reserve_upload_session(uuid,uuid,text,text,bigint,timestamptz)',
      'execute'),
    'T-V5-5c: anon has no EXECUTE');
  PERFORM test_helpers.assert(
    NOT pg_catalog.has_function_privilege(
      'authenticated',
      'public.reserve_upload_session(uuid,uuid,text,text,bigint,timestamptz)',
      'execute'),
    'T-V5-5d: authenticated has no EXECUTE');
  PERFORM test_helpers.assert(
    pg_catalog.has_function_privilege(
      'service_role',
      'public.reserve_upload_session(uuid,uuid,text,text,bigint,timestamptz)',
      'execute'),
    'T-V5-5e: service_role has EXECUTE');

  INSERT INTO private.upload_sessions (
    session_id, upload_token_hash, case_id, uploader_id,
    original_storage_path, display_storage_path,
    content_type, declared_size_bytes, expires_at,
    storage_upload_expires_at, status, status_changed_at
  ) VALUES (
    gen_random_uuid(),
    encode(sha256(('V5_T6' || gen_random_uuid()::text)::bytea), 'hex'),
    v_cid, v_uid,
    'cases/' || v_cid::text || '/originals/' || gen_random_uuid()::text,
    'cases/' || v_cid::text || '/displays/'  || gen_random_uuid()::text || '.webp',
    'image/jpeg', 1048576,
    now() + interval '15 minutes',
    NULL, 'failed', now()
  );

  SELECT COUNT(*) INTO v_count
  FROM private.upload_sessions
  WHERE status IN ('pending', 'processing', 'sanitized')
    AND (  original_storage_path LIKE 'cases/%'
        OR original_storage_path LIKE 'challenges/%');

  PERFORM test_helpers.assert(
    v_count = 0,
    'T-V5-6: terminal old-format sessions do not block cutover preflight');
END;
$$;

ROLLBACK;  -- test fixtures rolled back; V5 migration remains installed
