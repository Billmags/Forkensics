-- =============================================================================
-- Forkensics — V4-Compatible Port of V2 Regression Tests  (Rev 2)
-- ---------------------------------------------------------------------------
-- V4 changes from V2 (targeted only):
--   • public.challenges → public.cases  (no group_id)
--   • public.challenge_secrets → public.case_secrets
--   • private.upload_sessions.challenge_id → .case_id
--   • Storage paths: 'challenges/' → 'cases/'
--   • Index: upload_sessions_one_active_per_challenge → upload_sessions_one_active_per_case
--   • Triggers (on public.cases, fire on OLD.state='ready' AND NEW.state='launched'):
--       challenge_v2_no_active_upload_on_activate → case_v4_no_active_upload_on_launch
--       challenge_v2_media_ready_on_activate      → case_v4_media_ready_on_launch
--   • Function: reveal_challenge_service_wrapper → reveal_case_service_wrapper
--   • State 'active' removed; Groups 9.8/9.9 and 16 adapted to ready→launched
--
-- All other tests are verbatim V2 (error codes, column names, calling conventions).
-- All tests run inside a single BEGIN/ROLLBACK — no test data persists.
-- =============================================================================

\set ON_ERROR_STOP on

BEGIN;

-- =============================================================================
-- SECTION 0 — PREFLIGHT  (V4 schema verification)
-- =============================================================================
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.tables
                 WHERE table_schema='public' AND table_name='cases') THEN
    RAISE EXCEPTION 'PREFLIGHT FAILED: public.cases missing (V4 not applied)';
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.tables
             WHERE table_schema='public' AND table_name='challenges') THEN
    RAISE EXCEPTION 'PREFLIGHT FAILED: public.challenges still present (V4 not applied)';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.tables
                 WHERE table_schema='private' AND table_name='upload_sessions') THEN
    RAISE EXCEPTION 'PREFLIGHT FAILED: private.upload_sessions missing';
  END IF;
  RAISE NOTICE 'PREFLIGHT PASSED: V4 schema verified for V2 regression suite.';
END;
$$;

GRANT forkensics_executor TO postgres;

-- =============================================================================
-- SECTION 0.5 — HELPERS  (V4-compatible)
-- =============================================================================
CREATE SCHEMA IF NOT EXISTS test_helpers;
GRANT CREATE ON SCHEMA test_helpers TO forkensics_executor;

CREATE OR REPLACE FUNCTION test_helpers.assert(p_condition boolean, p_message text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF p_condition IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'ASSERTION FAILED: %', p_message;
  END IF;
  RAISE NOTICE 'PASS: %', p_message;
END;
$$;

CREATE OR REPLACE FUNCTION test_helpers.set_auth_uid(p_uid uuid)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', p_uid::text, 'role', 'authenticated')::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
END;
$$;

CREATE OR REPLACE FUNCTION test_helpers.clear_auth_uid()
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  RESET ROLE;
  PERFORM set_config('request.jwt.claims', '', true);
END;
$$;

-- V4-compatible: is_active=true + profile_suspensions row required by V4 schema.
CREATE OR REPLACE FUNCTION test_helpers.make_user(p_display_name text DEFAULT 'Test Player')
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE v_uid uuid := gen_random_uuid();
BEGIN
  INSERT INTO auth.users (id, email, raw_user_meta_data, created_at, updated_at)
  VALUES (v_uid, v_uid || '@test.invalid',
          json_build_object('display_name', p_display_name)::jsonb, now(), now());
  INSERT INTO public.profiles (id, display_name, onboarding_complete, is_active)
  VALUES (v_uid, p_display_name, true, true)
  ON CONFLICT (id) DO UPDATE
    SET display_name = p_display_name, onboarding_complete = true, is_active = true;
  INSERT INTO private.profile_suspensions (profile_id, is_suspended)
  VALUES (v_uid, false) ON CONFLICT (profile_id) DO NOTHING;
  RETURN v_uid;
END;
$$;

CREATE OR REPLACE FUNCTION test_helpers.make_group(p_owner_id uuid, p_name text DEFAULT 'Test Group')
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE v_gid uuid;
BEGIN
  PERFORM test_helpers.set_auth_uid(p_owner_id);
  v_gid := public.create_group(p_name);
  PERFORM test_helpers.clear_auth_uid();
  RETURN v_gid;
END;
$$;

-- V4: cases have no group_id; inserts into public.cases + public.case_secrets.
CREATE OR REPLACE FUNCTION test_helpers.make_bare_draft_case(p_poster_id uuid)
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE v_cid uuid;
BEGIN
  PERFORM test_helpers.set_auth_uid(p_poster_id);
  INSERT INTO public.cases DEFAULT VALUES RETURNING id INTO v_cid;
  INSERT INTO public.case_secrets (
    case_id, display_dish, canonical_dish, display_restaurant, canonical_restaurant
  ) VALUES (v_cid, 'Test Dish', 'test dish', 'Test Place', 'test place');
  PERFORM test_helpers.clear_auth_uid();
  RETURN v_cid;
END;
$$;

-- V4: gid returned for callers that still need a group; case has no group_id.
CREATE OR REPLACE FUNCTION test_helpers.make_scenario(p_label text)
RETURNS TABLE (uid uuid, gid uuid, cid uuid) LANGUAGE plpgsql AS $$
DECLARE v_uid uuid; v_gid uuid; v_cid uuid;
BEGIN
  v_uid := test_helpers.make_user(p_label);
  v_gid := test_helpers.make_group(v_uid, p_label || ' Group');
  v_cid := test_helpers.make_bare_draft_case(v_uid);
  RETURN QUERY SELECT v_uid, v_gid, v_cid;
END;
$$;

CREATE OR REPLACE FUNCTION test_helpers.make_token_hash(p_seed text DEFAULT 'default')
RETURNS text LANGUAGE sql AS $$
  SELECT encode(sha256(p_seed::bytea), 'hex');
$$;

-- V4: case_id column (renamed from challenge_id); cases/ storage paths.
CREATE OR REPLACE FUNCTION test_helpers.insert_session_direct(
  p_case_id                     uuid,
  p_uploader_id                 uuid,
  p_status                      text,
  p_token_seed                  text          DEFAULT 'direct',
  p_expires_at                  timestamptz   DEFAULT NULL,
  p_storage_upload_expires_at   timestamptz   DEFAULT NULL,
  p_processing_lease_expires_at timestamptz   DEFAULT NULL
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_sid  uuid := gen_random_uuid();
  v_orig text;
  v_disp text;
BEGIN
  v_orig := 'cases/' || p_case_id::text || '/originals/' || v_sid::text;
  v_disp := 'cases/' || p_case_id::text || '/displays/'  || v_sid::text || '.webp';
  INSERT INTO private.upload_sessions (
    session_id, upload_token_hash, case_id, uploader_id,
    original_storage_path, display_storage_path,
    content_type, declared_size_bytes, expires_at,
    storage_upload_expires_at, processing_lease_expires_at,
    status, status_changed_at
  ) VALUES (
    v_sid,
    encode(sha256((p_token_seed || v_sid::text)::bytea), 'hex'),
    p_case_id, p_uploader_id,
    v_orig, v_disp,
    'image/jpeg', 1048576,
    COALESCE(p_expires_at, now() + interval '10 minutes'),
    p_storage_upload_expires_at,
    p_processing_lease_expires_at,
    p_status, now()
  );
  RETURN v_sid;
END;
$$;
ALTER FUNCTION test_helpers.insert_session_direct(uuid,uuid,text,text,timestamptz,timestamptz,timestamptz)
  OWNER TO forkensics_executor;

CREATE OR REPLACE FUNCTION test_helpers.insert_media_object(p_uploader_id uuid, p_status text DEFAULT 'ready')
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE v_mid uuid := gen_random_uuid();
BEGIN
  INSERT INTO public.media_objects (id, uploader_id, mime_type, status, re_encoded_at)
  VALUES (v_mid, p_uploader_id, 'image/webp', p_status, now());
  RETURN v_mid;
END;
$$;

GRANT USAGE ON SCHEMA test_helpers TO authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA test_helpers TO authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA test_helpers TO forkensics_executor;

\echo ''
\echo '============================================================='
\echo 'Forkensics V4-Compatible V2 Regression Tests'
\echo '============================================================='

-- =============================================================================
-- GROUP 1: SCHEMA VERIFICATION  (V4 names)
-- =============================================================================
\echo ''
\echo '--- GROUP 1: Schema Verification (V4 names) ---'

DO $$
BEGIN
  PERFORM test_helpers.assert(
    EXISTS(SELECT 1 FROM information_schema.tables WHERE table_schema='private' AND table_name='upload_sessions'),
    '1.1a: private.upload_sessions exists');
  PERFORM test_helpers.assert(
    EXISTS(SELECT 1 FROM information_schema.tables WHERE table_schema='private' AND table_name='deletion_recovery_claims'),
    '1.1b: private.deletion_recovery_claims exists');
END;
$$;

DO $$
DECLARE v_count int;
BEGIN
  SELECT count(*) INTO v_count FROM information_schema.columns
  WHERE table_schema='private' AND table_name='upload_sessions';
  -- V4: challenge_id renamed to case_id; column count unchanged at 21.
  PERFORM test_helpers.assert(v_count = 21, '1.2: private.upload_sessions has 21 columns (got ' || v_count || ')');
END;
$$;

DO $$
DECLARE v_count int;
BEGIN
  SELECT count(*) INTO v_count FROM information_schema.columns
  WHERE table_schema='private' AND table_name='deletion_recovery_claims';
  PERFORM test_helpers.assert(v_count = 5, '1.3: private.deletion_recovery_claims has 5 columns (got ' || v_count || ')');
END;
$$;

DO $$
BEGIN
  PERFORM test_helpers.assert(
    EXISTS(SELECT 1 FROM information_schema.columns
           WHERE table_schema='private' AND table_name='media_storage_keys' AND column_name='sha256_hash'),
    '1.4: private.media_storage_keys.sha256_hash column exists');
END;
$$;

DO $$
DECLARE
  v_idx  text;
  -- V4: upload_sessions_one_active_per_challenge → upload_sessions_one_active_per_case
  v_idxs text[] := ARRAY[
    'upload_sessions_one_active_per_case',
    'idx_upload_sessions_uploader_status',
    'idx_upload_sessions_cleanup_candidates',
    'idx_upload_sessions_capability_expiry',
    'idx_upload_sessions_expiry_cleanup',
    'idx_deletion_recovery_scan_type'
  ];
BEGIN
  FOREACH v_idx IN ARRAY v_idxs LOOP
    PERFORM test_helpers.assert(
      EXISTS(SELECT 1 FROM pg_indexes WHERE indexname = v_idx),
      '1.5: index ' || v_idx || ' exists');
  END LOOP;
END;
$$;

DO $$
DECLARE v_fn text;
  -- V4: reveal_challenge_service_wrapper → reveal_case_service_wrapper
  v_fns text[] := ARRAY[
    'reserve_upload_session','activate_upload_session','resolve_upload_session',
    'advance_upload_session_processing','check_upload_session_lease','advance_upload_session_sanitized',
    'finalize_upload_session','fail_upload_session','quiesce_upload_sessions_for_deletion',
    'get_upload_capability_expiry','get_all_upload_session_paths_for_deletion','claim_cleanup_sessions',
    'mark_session_cleaned','mark_original_path_post_expiry_cleaned',
    'get_complete_sessions_pending_expiry_cleanup','get_superseded_media_to_clean',
    'mark_superseded_media_cleaned','get_media_storage_key','reveal_case_service_wrapper',
    'prepare_account_deletion_wrapper','get_deletion_storage_keys','record_deletion_failure_wrapper',
    'mark_auth_deleted_wrapper','mark_storage_cleaned_wrapper','claim_deletion_recovery_records',
    'complete_deletion_recovery','fail_deletion_recovery'
  ];
BEGIN
  FOREACH v_fn IN ARRAY v_fns LOOP
    PERFORM test_helpers.assert(
      EXISTS(SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
             WHERE n.nspname='public' AND p.proname=v_fn),
      '1.6: public.' || v_fn || ' exists');
  END LOOP;
END;
$$;

DO $$
BEGIN
  -- V4: triggers renamed on public.cases; fire on OLD.state='ready' AND NEW.state='launched'
  PERFORM test_helpers.assert(
    EXISTS(SELECT 1 FROM information_schema.triggers
           WHERE event_object_schema='public' AND event_object_table='cases'
             AND trigger_name='case_v4_no_active_upload_on_launch'),
    '1.7a: case_v4_no_active_upload_on_launch trigger exists on public.cases');
  PERFORM test_helpers.assert(
    EXISTS(SELECT 1 FROM information_schema.triggers
           WHERE event_object_schema='public' AND event_object_table='cases'
             AND trigger_name='case_v4_media_ready_on_launch'),
    '1.7b: case_v4_media_ready_on_launch trigger exists on public.cases');
END;
$$;


-- =============================================================================
-- GROUP 2: PARTIAL UNIQUE INDEX
-- =============================================================================
\echo ''
\echo '--- GROUP 2: Partial Unique Index (upload_sessions_one_active_per_case) ---'

-- 2.1  Two pending sessions for same case → unique violation
DO $$
DECLARE
  v_uid uuid; v_gid uuid; v_cid uuid;
  v_caught boolean := false;
BEGIN
  SELECT uid,gid,cid INTO v_uid,v_gid,v_cid FROM test_helpers.make_scenario('Idx2_1');
  PERFORM test_helpers.insert_session_direct(v_cid, v_uid, 'pending', 'seed_a');
  BEGIN
    PERFORM test_helpers.insert_session_direct(v_cid, v_uid, 'pending', 'seed_b');
  EXCEPTION
    WHEN unique_violation   THEN v_caught := true;
    WHEN SQLSTATE 'P0001'   THEN v_caught := true;
    WHEN OTHERS THEN RAISE EXCEPTION 'FAIL 2.1: % (%)', SQLERRM, SQLSTATE;
  END;
  PERFORM test_helpers.assert(v_caught, '2.1: two pending sessions → unique violation');
END;
$$;

-- 2.2  Pending + complete for same case → allowed
DO $$
DECLARE v_uid uuid; v_gid uuid; v_cid uuid; v_s2 uuid;
BEGIN
  SELECT uid,gid,cid INTO v_uid,v_gid,v_cid FROM test_helpers.make_scenario('Idx2_2');
  PERFORM test_helpers.insert_session_direct(v_cid, v_uid, 'pending',  'seed_c');
  v_s2 := test_helpers.insert_session_direct(v_cid, v_uid, 'complete', 'seed_d');
  PERFORM test_helpers.assert(v_s2 IS NOT NULL, '2.2: pending + complete → allowed');
END;
$$;

-- 2.3  Failed + pending for same case → allowed
DO $$
DECLARE v_uid uuid; v_gid uuid; v_cid uuid; v_s2 uuid;
BEGIN
  SELECT uid,gid,cid INTO v_uid,v_gid,v_cid FROM test_helpers.make_scenario('Idx2_3');
  PERFORM test_helpers.insert_session_direct(v_cid, v_uid, 'failed',  'seed_e');
  v_s2 := test_helpers.insert_session_direct(v_cid, v_uid, 'pending', 'seed_f');
  PERFORM test_helpers.assert(v_s2 IS NOT NULL, '2.3: failed + pending → allowed');
END;
$$;


-- =============================================================================
-- GROUP 3: reserve_upload_session
-- =============================================================================
\echo ''
\echo '--- GROUP 3: reserve_upload_session ---'

-- 3.1  Case not found → FK_NOT_FOUND
DO $$
DECLARE v_uid uuid; v_gid uuid; v_cid uuid; v_caught boolean := false;
BEGIN
  SELECT uid,gid,cid INTO v_uid,v_gid,v_cid FROM test_helpers.make_scenario('Rsv3_1');
  BEGIN
    PERFORM public.reserve_upload_session(gen_random_uuid(), v_uid,
      test_helpers.make_token_hash('missing'), 'image/jpeg', 1048576, now()+interval '10 minutes');
  EXCEPTION
    WHEN SQLSTATE 'P0001' THEN
      IF SQLERRM LIKE '%FK_NOT_FOUND%' THEN v_caught := true;
      ELSE RAISE EXCEPTION 'FAIL 3.1: wrong message: %', SQLERRM; END IF;
    WHEN OTHERS THEN RAISE EXCEPTION 'FAIL 3.1: % (%)', SQLERRM, SQLSTATE;
  END;
  PERFORM test_helpers.assert(v_caught, '3.1: case not found → FK_NOT_FOUND');
END;
$$;

-- 3.2  Poster mismatch → FK_NOT_FOUND
DO $$
DECLARE
  v_uid uuid; v_gid uuid; v_cid uuid;
  v_other uuid;
  v_caught boolean := false;
BEGIN
  SELECT uid,gid,cid INTO v_uid,v_gid,v_cid FROM test_helpers.make_scenario('Rsv3_2');
  v_other := test_helpers.make_user('Rsv3_2_other');
  BEGIN
    PERFORM public.reserve_upload_session(v_cid, v_other,
      test_helpers.make_token_hash('mismatch'), 'image/jpeg', 1048576, now()+interval '10 minutes');
  EXCEPTION
    WHEN SQLSTATE 'P0001' THEN
      IF SQLERRM LIKE '%FK_NOT_FOUND%' THEN v_caught := true;
      ELSE RAISE EXCEPTION 'FAIL 3.2: wrong message: %', SQLERRM; END IF;
    WHEN OTHERS THEN RAISE EXCEPTION 'FAIL 3.2: % (%)', SQLERRM, SQLSTATE;
  END;
  PERFORM test_helpers.assert(v_caught, '3.2: poster mismatch → FK_NOT_FOUND');
END;
$$;

-- 3.3  Case in wrong state → FK_WRONG_STATE  (V4: public.cases; 'cancelled' removed; use 'ready')
DO $$
DECLARE v_uid uuid; v_gid uuid; v_cid uuid; v_caught boolean := false;
BEGIN
  SELECT uid,gid,cid INTO v_uid,v_gid,v_cid FROM test_helpers.make_scenario('Rsv3_3');
  SET LOCAL ROLE forkensics_executor;
  UPDATE public.cases SET state = 'ready' WHERE id = v_cid;  -- V4: no 'cancelled' state
  RESET ROLE;
  BEGIN
    PERFORM public.reserve_upload_session(v_cid, v_uid,
      test_helpers.make_token_hash('wrongstate'), 'image/jpeg', 1048576, now()+interval '10 minutes');
  EXCEPTION
    WHEN SQLSTATE 'P0001' THEN
      IF SQLERRM LIKE '%FK_WRONG_STATE%' THEN v_caught := true;
      ELSE RAISE EXCEPTION 'FAIL 3.3: wrong message: %', SQLERRM; END IF;
    WHEN OTHERS THEN RAISE EXCEPTION 'FAIL 3.3: % (%)', SQLERRM, SQLSTATE;
  END;
  PERFORM test_helpers.assert(v_caught, '3.3: non-draft case → FK_WRONG_STATE (V4: public.cases)');
END;
$$;

-- 3.4  Uploader has database_prepared deletion → FK_FORBIDDEN
DO $$
DECLARE v_uid uuid; v_gid uuid; v_cid uuid; v_caught boolean := false;
BEGIN
  SELECT uid,gid,cid INTO v_uid,v_gid,v_cid FROM test_helpers.make_scenario('Rsv3_4');
  INSERT INTO private.deletion_log (profile_id, status, db_prepared_at)
  VALUES (v_uid, 'database_prepared', now());
  BEGIN
    PERFORM public.reserve_upload_session(v_cid, v_uid,
      test_helpers.make_token_hash('deluser'), 'image/jpeg', 1048576, now()+interval '10 minutes');
  EXCEPTION
    WHEN SQLSTATE 'P0001' THEN
      IF SQLERRM LIKE '%FK_FORBIDDEN%' THEN v_caught := true;
      ELSE RAISE EXCEPTION 'FAIL 3.4: wrong message: %', SQLERRM; END IF;
    WHEN OTHERS THEN RAISE EXCEPTION 'FAIL 3.4: % (%)', SQLERRM, SQLSTATE;
  END;
  PERFORM test_helpers.assert(v_caught, '3.4: database_prepared deletion → FK_FORBIDDEN');
END;
$$;

-- 3.5  Active session exists → FK_UPLOAD_IN_PROGRESS
DO $$
DECLARE v_uid uuid; v_gid uuid; v_cid uuid; v_caught boolean := false;
BEGIN
  SELECT uid,gid,cid INTO v_uid,v_gid,v_cid FROM test_helpers.make_scenario('Rsv3_5');
  PERFORM test_helpers.insert_session_direct(v_cid, v_uid, 'pending', 'existing');
  BEGIN
    PERFORM public.reserve_upload_session(v_cid, v_uid,
      test_helpers.make_token_hash('second'), 'image/jpeg', 1048576, now()+interval '10 minutes');
  EXCEPTION
    WHEN SQLSTATE 'P0001' THEN
      IF SQLERRM LIKE '%FK_UPLOAD_IN_PROGRESS%' THEN v_caught := true;
      ELSE RAISE EXCEPTION 'FAIL 3.5: wrong message: %', SQLERRM; END IF;
    WHEN OTHERS THEN RAISE EXCEPTION 'FAIL 3.5: % (%)', SQLERRM, SQLSTATE;
  END;
  PERFORM test_helpers.assert(v_caught, '3.5: active session exists → FK_UPLOAD_IN_PROGRESS');
END;
$$;

-- 3.6  Happy path  (V4: storage paths use 'cases/' prefix)
DO $$
DECLARE
  v_uid uuid; v_gid uuid; v_cid uuid;
  v_sid uuid; v_orig text; v_disp text;
BEGIN
  SELECT uid,gid,cid INTO v_uid,v_gid,v_cid FROM test_helpers.make_scenario('Rsv3_6');
  SELECT r.session_id, r.original_storage_path, r.display_storage_path
  INTO v_sid, v_orig, v_disp
  FROM public.reserve_upload_session(v_cid, v_uid,
    test_helpers.make_token_hash('happy'), 'image/jpeg', 1048576, now()+interval '10 minutes') r;
  PERFORM test_helpers.assert(v_sid IS NOT NULL, '3.6a: reserve returns session_id');
  -- V4: 'cases/' prefix (V2 used 'challenges/')
  PERFORM test_helpers.assert(
    v_orig = 'cases/' || v_cid::text || '/originals/' || v_sid::text,
    '3.6b: original_storage_path format correct (V4: cases/ prefix)');
  PERFORM test_helpers.assert(
    v_disp = 'cases/' || v_cid::text || '/displays/' || v_sid::text || '.webp',
    '3.6c: display_storage_path format correct (V4: cases/ prefix)');
  PERFORM test_helpers.assert(
    EXISTS(SELECT 1 FROM private.upload_sessions
           WHERE session_id=v_sid AND status='pending' AND storage_upload_expires_at IS NULL),
    '3.6d: session=pending, storage_upload_expires_at=NULL');
END;
$$;


-- =============================================================================
-- GROUP 4: activate_upload_session
-- =============================================================================
\echo ''
\echo '--- GROUP 4: activate_upload_session ---'

-- 4.1  NULL expiry → FK_INVALID_INPUT
DO $$
DECLARE v_uid uuid; v_gid uuid; v_cid uuid; v_sid uuid; v_caught boolean := false;
BEGIN
  SELECT uid,gid,cid INTO v_uid,v_gid,v_cid FROM test_helpers.make_scenario('Act4_1');
  SELECT r.session_id INTO v_sid FROM public.reserve_upload_session(v_cid, v_uid,
    test_helpers.make_token_hash('a4_1'), 'image/jpeg', 1048576, now()+interval '10 minutes') r;
  BEGIN
    PERFORM public.activate_upload_session(v_sid, NULL);
  EXCEPTION
    WHEN SQLSTATE 'P0001' THEN
      IF SQLERRM LIKE '%FK_INVALID_INPUT%' THEN v_caught := true;
      ELSE RAISE EXCEPTION 'FAIL 4.1: %', SQLERRM; END IF;
    WHEN OTHERS THEN RAISE EXCEPTION 'FAIL 4.1: % (%)', SQLERRM, SQLSTATE;
  END;
  PERFORM test_helpers.assert(v_caught, '4.1: NULL expiry → FK_INVALID_INPUT');
END;
$$;

-- 4.2  Past expiry → FK_INVALID_INPUT
DO $$
DECLARE v_uid uuid; v_gid uuid; v_cid uuid; v_sid uuid; v_caught boolean := false;
BEGIN
  SELECT uid,gid,cid INTO v_uid,v_gid,v_cid FROM test_helpers.make_scenario('Act4_2');
  SELECT r.session_id INTO v_sid FROM public.reserve_upload_session(v_cid, v_uid,
    test_helpers.make_token_hash('a4_2'), 'image/jpeg', 1048576, now()+interval '10 minutes') r;
  BEGIN
    PERFORM public.activate_upload_session(v_sid, clock_timestamp() - interval '1 second');
  EXCEPTION
    WHEN SQLSTATE 'P0001' THEN
      IF SQLERRM LIKE '%FK_INVALID_INPUT%' THEN v_caught := true;
      ELSE RAISE EXCEPTION 'FAIL 4.2: %', SQLERRM; END IF;
    WHEN OTHERS THEN RAISE EXCEPTION 'FAIL 4.2: % (%)', SQLERRM, SQLSTATE;
  END;
  PERFORM test_helpers.assert(v_caught, '4.2: past expiry → FK_INVALID_INPUT');
END;
$$;

-- 4.3  Exceeds 5m30s cap → FK_INVALID_INPUT
DO $$
DECLARE v_uid uuid; v_gid uuid; v_cid uuid; v_sid uuid; v_caught boolean := false;
BEGIN
  SELECT uid,gid,cid INTO v_uid,v_gid,v_cid FROM test_helpers.make_scenario('Act4_3');
  SELECT r.session_id INTO v_sid FROM public.reserve_upload_session(v_cid, v_uid,
    test_helpers.make_token_hash('a4_3'), 'image/jpeg', 1048576, now()+interval '10 minutes') r;
  BEGIN
    PERFORM public.activate_upload_session(v_sid, clock_timestamp() + interval '10 minutes');
  EXCEPTION
    WHEN SQLSTATE 'P0001' THEN
      IF SQLERRM LIKE '%FK_INVALID_INPUT%' THEN v_caught := true;
      ELSE RAISE EXCEPTION 'FAIL 4.3: %', SQLERRM; END IF;
    WHEN OTHERS THEN RAISE EXCEPTION 'FAIL 4.3: % (%)', SQLERRM, SQLSTATE;
  END;
  PERFORM test_helpers.assert(v_caught, '4.3: expiry > 5m30s cap → FK_INVALID_INPUT');
END;
$$;

-- 4.4  Happy path
DO $$
DECLARE v_uid uuid; v_gid uuid; v_cid uuid; v_sid uuid;
BEGIN
  SELECT uid,gid,cid INTO v_uid,v_gid,v_cid FROM test_helpers.make_scenario('Act4_4');
  SELECT r.session_id INTO v_sid FROM public.reserve_upload_session(v_cid, v_uid,
    test_helpers.make_token_hash('a4_4'), 'image/jpeg', 1048576, now()+interval '10 minutes') r;
  PERFORM public.activate_upload_session(v_sid, clock_timestamp() + interval '4 minutes');
  PERFORM test_helpers.assert(
    EXISTS(SELECT 1 FROM private.upload_sessions WHERE session_id=v_sid AND storage_upload_expires_at IS NOT NULL),
    '4.4: happy path → storage_upload_expires_at set');
END;
$$;

-- 4.5  Capability > session.expires_at → FK_INVALID_INPUT
DO $$
DECLARE v_uid uuid; v_gid uuid; v_cid uuid; v_sid uuid; v_caught boolean := false;
BEGIN
  SELECT uid,gid,cid INTO v_uid,v_gid,v_cid FROM test_helpers.make_scenario('Act4_5');
  v_sid := test_helpers.insert_session_direct(v_cid, v_uid, 'pending', 'a4_5',
    now() + interval '3 minutes', NULL);
  BEGIN
    PERFORM public.activate_upload_session(v_sid, clock_timestamp() + interval '4 minutes');
  EXCEPTION
    WHEN SQLSTATE 'P0001' THEN
      IF SQLERRM LIKE '%FK_INVALID_INPUT%' THEN v_caught := true;
      ELSE RAISE EXCEPTION 'FAIL 4.5: %', SQLERRM; END IF;
    WHEN OTHERS THEN RAISE EXCEPTION 'FAIL 4.5: % (%)', SQLERRM, SQLSTATE;
  END;
  PERFORM test_helpers.assert(v_caught, '4.5: capability > session expiry → FK_INVALID_INPUT');
END;
$$;

-- 4.6  Session claim window expired → FK_WRONG_STATE
DO $$
DECLARE v_uid uuid; v_gid uuid; v_cid uuid; v_sid uuid; v_caught boolean := false;
BEGIN
  SELECT uid,gid,cid INTO v_uid,v_gid,v_cid FROM test_helpers.make_scenario('Act4_6');
  v_sid := test_helpers.insert_session_direct(v_cid, v_uid, 'pending', 'a4_6',
    now() - interval '1 minute');
  BEGIN
    PERFORM public.activate_upload_session(v_sid, clock_timestamp() + interval '4 minutes');
  EXCEPTION
    WHEN SQLSTATE 'P0001' THEN
      IF SQLERRM LIKE '%FK_WRONG_STATE%' THEN v_caught := true;
      ELSE RAISE EXCEPTION 'FAIL 4.6: %', SQLERRM; END IF;
    WHEN OTHERS THEN RAISE EXCEPTION 'FAIL 4.6: % (%)', SQLERRM, SQLSTATE;
  END;
  PERFORM test_helpers.assert(v_caught, '4.6: session window expired → FK_WRONG_STATE');
END;
$$;

-- 4.7  Already activated → FK_WRONG_STATE
DO $$
DECLARE v_uid uuid; v_gid uuid; v_cid uuid; v_sid uuid; v_caught boolean := false;
BEGIN
  SELECT uid,gid,cid INTO v_uid,v_gid,v_cid FROM test_helpers.make_scenario('Act4_7');
  SELECT r.session_id INTO v_sid FROM public.reserve_upload_session(v_cid, v_uid,
    test_helpers.make_token_hash('a4_7'), 'image/jpeg', 1048576, now()+interval '10 minutes') r;
  PERFORM public.activate_upload_session(v_sid, clock_timestamp() + interval '4 minutes');
  BEGIN
    PERFORM public.activate_upload_session(v_sid, clock_timestamp() + interval '4 minutes');
  EXCEPTION
    WHEN SQLSTATE 'P0001' THEN
      IF SQLERRM LIKE '%FK_WRONG_STATE%' THEN v_caught := true;
      ELSE RAISE EXCEPTION 'FAIL 4.7: %', SQLERRM; END IF;
    WHEN OTHERS THEN RAISE EXCEPTION 'FAIL 4.7: % (%)', SQLERRM, SQLSTATE;
  END;
  PERFORM test_helpers.assert(v_caught, '4.7: already activated → FK_WRONG_STATE');
END;
$$;

-- 4.8  Not found → FK_WRONG_STATE
DO $$
DECLARE v_caught boolean := false;
BEGIN
  BEGIN
    PERFORM public.activate_upload_session(gen_random_uuid(), clock_timestamp() + interval '4 minutes');
  EXCEPTION
    WHEN SQLSTATE 'P0001' THEN
      IF SQLERRM LIKE '%FK_WRONG_STATE%' THEN v_caught := true;
      ELSE RAISE EXCEPTION 'FAIL 4.8: %', SQLERRM; END IF;
    WHEN OTHERS THEN RAISE EXCEPTION 'FAIL 4.8: % (%)', SQLERRM, SQLSTATE;
  END;
  PERFORM test_helpers.assert(v_caught, '4.8: not found → FK_WRONG_STATE');
END;
$$;

-- 4.9  status=failed → FK_WRONG_STATE
DO $$
DECLARE v_uid uuid; v_gid uuid; v_cid uuid; v_sid uuid; v_caught boolean := false;
BEGIN
  SELECT uid,gid,cid INTO v_uid,v_gid,v_cid FROM test_helpers.make_scenario('Act4_9');
  v_sid := test_helpers.insert_session_direct(v_cid, v_uid, 'failed', 'a4_9');
  BEGIN
    PERFORM public.activate_upload_session(v_sid, clock_timestamp() + interval '4 minutes');
  EXCEPTION
    WHEN SQLSTATE 'P0001' THEN
      IF SQLERRM LIKE '%FK_WRONG_STATE%' THEN v_caught := true;
      ELSE RAISE EXCEPTION 'FAIL 4.9: %', SQLERRM; END IF;
    WHEN OTHERS THEN RAISE EXCEPTION 'FAIL 4.9: % (%)', SQLERRM, SQLSTATE;
  END;
  PERFORM test_helpers.assert(v_caught, '4.9: status=failed → FK_WRONG_STATE');
END;
$$;


-- =============================================================================
-- GROUP 5: fail_upload_session
-- =============================================================================
\echo ''
\echo '--- GROUP 5: fail_upload_session ---'

-- 5.1  complete → FK_WRONG_STATE
DO $$
DECLARE v_uid uuid; v_gid uuid; v_cid uuid; v_sid uuid; v_caught boolean := false;
BEGIN
  SELECT uid,gid,cid INTO v_uid,v_gid,v_cid FROM test_helpers.make_scenario('Fail5_1');
  v_sid := test_helpers.insert_session_direct(v_cid, v_uid, 'complete', 'f5_1');
  BEGIN PERFORM public.fail_upload_session(v_sid, 'FK_TEST_ERROR');
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    IF SQLERRM LIKE '%FK_WRONG_STATE%' THEN v_caught := true;
    ELSE RAISE EXCEPTION 'FAIL 5.1: %', SQLERRM; END IF;
  WHEN OTHERS THEN RAISE EXCEPTION 'FAIL 5.1: % (%)', SQLERRM, SQLSTATE;
  END;
  PERFORM test_helpers.assert(v_caught, '5.1: complete → FK_WRONG_STATE');
END;
$$;

-- 5.2  expired → FK_WRONG_STATE
DO $$
DECLARE v_uid uuid; v_gid uuid; v_cid uuid; v_sid uuid; v_caught boolean := false;
BEGIN
  SELECT uid,gid,cid INTO v_uid,v_gid,v_cid FROM test_helpers.make_scenario('Fail5_2');
  v_sid := test_helpers.insert_session_direct(v_cid, v_uid, 'expired', 'f5_2');
  BEGIN PERFORM public.fail_upload_session(v_sid, 'FK_TEST_ERROR');
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    IF SQLERRM LIKE '%FK_WRONG_STATE%' THEN v_caught := true;
    ELSE RAISE EXCEPTION 'FAIL 5.2: %', SQLERRM; END IF;
  WHEN OTHERS THEN RAISE EXCEPTION 'FAIL 5.2: % (%)', SQLERRM, SQLSTATE;
  END;
  PERFORM test_helpers.assert(v_caught, '5.2: expired → FK_WRONG_STATE');
END;
$$;

-- 5.3  cleaned → FK_WRONG_STATE
DO $$
DECLARE v_uid uuid; v_gid uuid; v_cid uuid; v_sid uuid; v_caught boolean := false;
BEGIN
  SELECT uid,gid,cid INTO v_uid,v_gid,v_cid FROM test_helpers.make_scenario('Fail5_3');
  v_sid := test_helpers.insert_session_direct(v_cid, v_uid, 'cleaned', 'f5_3');
  BEGIN PERFORM public.fail_upload_session(v_sid, 'FK_TEST_ERROR');
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    IF SQLERRM LIKE '%FK_WRONG_STATE%' THEN v_caught := true;
    ELSE RAISE EXCEPTION 'FAIL 5.3: %', SQLERRM; END IF;
  WHEN OTHERS THEN RAISE EXCEPTION 'FAIL 5.3: % (%)', SQLERRM, SQLSTATE;
  END;
  PERFORM test_helpers.assert(v_caught, '5.3: cleaned → FK_WRONG_STATE');
END;
$$;

-- 5.4  pending → failed (with reason stored)
DO $$
DECLARE v_uid uuid; v_gid uuid; v_cid uuid; v_sid uuid;
BEGIN
  SELECT uid,gid,cid INTO v_uid,v_gid,v_cid FROM test_helpers.make_scenario('Fail5_4');
  v_sid := test_helpers.insert_session_direct(v_cid, v_uid, 'pending', 'f5_4');
  PERFORM public.fail_upload_session(v_sid, 'FK_TEST_PENDING');
  PERFORM test_helpers.assert(
    EXISTS(SELECT 1 FROM private.upload_sessions
           WHERE session_id=v_sid AND status='failed' AND failed_reason='FK_TEST_PENDING'),
    '5.4: pending → failed with reason');
END;
$$;

-- 5.5  processing → failed
DO $$
DECLARE v_uid uuid; v_gid uuid; v_cid uuid; v_sid uuid;
BEGIN
  SELECT uid,gid,cid INTO v_uid,v_gid,v_cid FROM test_helpers.make_scenario('Fail5_5');
  v_sid := test_helpers.insert_session_direct(v_cid, v_uid, 'processing', 'f5_5',
    NULL, now()-interval '1 hour', now()+interval '30 minutes');
  PERFORM public.fail_upload_session(v_sid, 'FK_TEST_PROC');
  PERFORM test_helpers.assert(
    EXISTS(SELECT 1 FROM private.upload_sessions WHERE session_id=v_sid AND status='failed'),
    '5.5: processing → failed');
END;
$$;

-- 5.6  sanitized → failed
DO $$
DECLARE v_uid uuid; v_gid uuid; v_cid uuid; v_sid uuid;
BEGIN
  SELECT uid,gid,cid INTO v_uid,v_gid,v_cid FROM test_helpers.make_scenario('Fail5_6');
  v_sid := test_helpers.insert_session_direct(v_cid, v_uid, 'sanitized', 'f5_6');
  PERFORM public.fail_upload_session(v_sid, 'FK_TEST_SANIT');
  PERFORM test_helpers.assert(
    EXISTS(SELECT 1 FROM private.upload_sessions WHERE session_id=v_sid AND status='failed'),
    '5.6: sanitized → failed');
END;
$$;

-- 5.7  already failed → idempotent (reason + timestamp unchanged)
DO $$
DECLARE
  v_uid uuid; v_gid uuid; v_cid uuid; v_sid uuid;
  v_before_ts timestamptz; v_before_reason text;
BEGIN
  SELECT uid,gid,cid INTO v_uid,v_gid,v_cid FROM test_helpers.make_scenario('Fail5_7');
  v_sid := test_helpers.insert_session_direct(v_cid, v_uid, 'pending', 'f5_7');
  PERFORM public.fail_upload_session(v_sid, 'FK_FIRST_REASON');
  SELECT status_changed_at, failed_reason INTO v_before_ts, v_before_reason
  FROM private.upload_sessions WHERE session_id=v_sid;
  PERFORM pg_sleep(0.02);
  PERFORM public.fail_upload_session(v_sid, 'FK_SECOND_REASON');
  PERFORM test_helpers.assert(
    EXISTS(SELECT 1 FROM private.upload_sessions
           WHERE session_id=v_sid AND failed_reason='FK_FIRST_REASON'
             AND status_changed_at=v_before_ts),
    '5.7: already failed → idempotent (reason+timestamp unchanged)');
END;
$$;

-- 5.8  not found → no-op
DO $$
BEGIN
  PERFORM public.fail_upload_session(gen_random_uuid(), 'FK_TEST_NOOP');
  PERFORM test_helpers.assert(true, '5.8: not found → no-op');
END;
$$;

-- 5.9  bad error_code → check_violation
DO $$
DECLARE v_uid uuid; v_gid uuid; v_cid uuid; v_sid uuid; v_caught boolean := false;
BEGIN
  SELECT uid,gid,cid INTO v_uid,v_gid,v_cid FROM test_helpers.make_scenario('Fail5_9');
  v_sid := test_helpers.insert_session_direct(v_cid, v_uid, 'pending', 'f5_9');
  BEGIN PERFORM public.fail_upload_session(v_sid, 'not_a_fk_code');
  EXCEPTION WHEN check_violation THEN v_caught := true;
  WHEN OTHERS THEN RAISE EXCEPTION 'FAIL 5.9: % (%)', SQLERRM, SQLSTATE;
  END;
  PERFORM test_helpers.assert(v_caught, '5.9: invalid error_code → check_violation');
END;
$$;


-- =============================================================================
-- GROUP 6: advance_upload_session_processing
-- =============================================================================
\echo ''
\echo '--- GROUP 6: advance_upload_session_processing ---'

-- 6.1  Not activated (NULL storage_upload_expires_at) → FK_WRONG_STATE
DO $$
DECLARE v_uid uuid; v_gid uuid; v_cid uuid; v_sid uuid; v_caught boolean := false;
BEGIN
  SELECT uid,gid,cid INTO v_uid,v_gid,v_cid FROM test_helpers.make_scenario('Proc6_1');
  SELECT r.session_id INTO v_sid FROM public.reserve_upload_session(v_cid, v_uid,
    test_helpers.make_token_hash('p6_1'), 'image/jpeg', 1048576, now()+interval '10 minutes') r;
  BEGIN PERFORM public.advance_upload_session_processing(v_sid, v_uid, interval '30 minutes');
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    IF SQLERRM LIKE '%FK_WRONG_STATE%' THEN v_caught := true;
    ELSE RAISE EXCEPTION 'FAIL 6.1: %', SQLERRM; END IF;
  WHEN OTHERS THEN RAISE EXCEPTION 'FAIL 6.1: % (%)', SQLERRM, SQLSTATE;
  END;
  PERFORM test_helpers.assert(v_caught, '6.1: not activated → FK_WRONG_STATE');
END;
$$;

-- 6.2  Uploader mismatch → FK_INVALID_TOKEN
DO $$
DECLARE v_uid uuid; v_gid uuid; v_cid uuid; v_sid uuid; v_other uuid; v_caught boolean := false;
BEGIN
  SELECT uid,gid,cid INTO v_uid,v_gid,v_cid FROM test_helpers.make_scenario('Proc6_2');
  v_other := test_helpers.make_user('Proc6_2_other');
  v_sid := test_helpers.insert_session_direct(v_cid, v_uid, 'pending', 'p6_2',
    NULL, now()+interval '4 minutes');
  BEGIN PERFORM public.advance_upload_session_processing(v_sid, v_other, interval '30 minutes');
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    IF SQLERRM LIKE '%FK_INVALID_TOKEN%' THEN v_caught := true;
    ELSE RAISE EXCEPTION 'FAIL 6.2: %', SQLERRM; END IF;
  WHEN OTHERS THEN RAISE EXCEPTION 'FAIL 6.2: % (%)', SQLERRM, SQLSTATE;
  END;
  PERFORM test_helpers.assert(v_caught, '6.2: uploader mismatch → FK_INVALID_TOKEN');
END;
$$;

-- 6.3  Happy path
DO $$
DECLARE v_uid uuid; v_gid uuid; v_cid uuid; v_sid uuid; v_orig text; v_disp text;
BEGIN
  SELECT uid,gid,cid INTO v_uid,v_gid,v_cid FROM test_helpers.make_scenario('Proc6_3');
  v_sid := test_helpers.insert_session_direct(v_cid, v_uid, 'pending', 'p6_3',
    NULL, now()+interval '4 minutes');
  SELECT original_storage_path, display_storage_path INTO v_orig, v_disp
  FROM public.advance_upload_session_processing(v_sid, v_uid, interval '30 minutes');
  PERFORM test_helpers.assert(v_orig IS NOT NULL, '6.3a: returns original_storage_path');
  PERFORM test_helpers.assert(v_disp IS NOT NULL, '6.3b: returns display_storage_path');
  PERFORM test_helpers.assert(
    EXISTS(SELECT 1 FROM private.upload_sessions
           WHERE session_id=v_sid AND status='processing' AND processing_lease_expires_at > now()),
    '6.3c: session=processing with future lease');
END;
$$;

-- 6.4  Already processing → FK_INVALID_TOKEN
DO $$
DECLARE v_uid uuid; v_gid uuid; v_cid uuid; v_sid uuid; v_caught boolean := false;
BEGIN
  SELECT uid,gid,cid INTO v_uid,v_gid,v_cid FROM test_helpers.make_scenario('Proc6_4');
  v_sid := test_helpers.insert_session_direct(v_cid, v_uid, 'processing', 'p6_4',
    NULL, now()+interval '4 minutes', now()+interval '30 minutes');
  BEGIN PERFORM public.advance_upload_session_processing(v_sid, v_uid, interval '30 minutes');
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    IF SQLERRM LIKE '%FK_INVALID_TOKEN%' THEN v_caught := true;
    ELSE RAISE EXCEPTION 'FAIL 6.4: %', SQLERRM; END IF;
  WHEN OTHERS THEN RAISE EXCEPTION 'FAIL 6.4: % (%)', SQLERRM, SQLSTATE;
  END;
  PERFORM test_helpers.assert(v_caught, '6.4: already processing → FK_INVALID_TOKEN');
END;
$$;

-- 6.5  Expired session → FK_INVALID_TOKEN
DO $$
DECLARE v_uid uuid; v_gid uuid; v_cid uuid; v_sid uuid; v_caught boolean := false;
BEGIN
  SELECT uid,gid,cid INTO v_uid,v_gid,v_cid FROM test_helpers.make_scenario('Proc6_5');
  v_sid := test_helpers.insert_session_direct(v_cid, v_uid, 'pending', 'p6_5',
    now()-interval '5 minutes', now()+interval '4 minutes');
  BEGIN PERFORM public.advance_upload_session_processing(v_sid, v_uid, interval '30 minutes');
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    IF SQLERRM LIKE '%FK_INVALID_TOKEN%' THEN v_caught := true;
    ELSE RAISE EXCEPTION 'FAIL 6.5: %', SQLERRM; END IF;
  WHEN OTHERS THEN RAISE EXCEPTION 'FAIL 6.5: % (%)', SQLERRM, SQLSTATE;
  END;
  PERFORM test_helpers.assert(v_caught, '6.5: expired session → FK_INVALID_TOKEN');
END;
$$;


-- =============================================================================
-- GROUP 7: check_upload_session_lease
-- =============================================================================
\echo ''
\echo '--- GROUP 7: check_upload_session_lease ---'

DO $$
DECLARE v_uid uuid; v_gid uuid; v_cid uuid; v_sid uuid;
BEGIN
  SELECT uid,gid,cid INTO v_uid,v_gid,v_cid FROM test_helpers.make_scenario('Lease7_1');
  v_sid := test_helpers.insert_session_direct(v_cid, v_uid, 'processing', 'l7_1',
    NULL, now()-interval '1 hour', now()+interval '30 minutes');
  PERFORM test_helpers.assert(public.check_upload_session_lease(v_sid)=true, '7.1: future lease → true');
END;
$$;

DO $$
DECLARE v_uid uuid; v_gid uuid; v_cid uuid; v_sid uuid;
BEGIN
  SELECT uid,gid,cid INTO v_uid,v_gid,v_cid FROM test_helpers.make_scenario('Lease7_2');
  v_sid := test_helpers.insert_session_direct(v_cid, v_uid, 'processing', 'l7_2',
    NULL, now()-interval '1 hour', now()-interval '1 minute');
  PERFORM test_helpers.assert(public.check_upload_session_lease(v_sid)=false, '7.2: expired lease → false');
END;
$$;

DO $$
DECLARE v_uid uuid; v_gid uuid; v_cid uuid; v_sid uuid;
BEGIN
  SELECT uid,gid,cid INTO v_uid,v_gid,v_cid FROM test_helpers.make_scenario('Lease7_3');
  v_sid := test_helpers.insert_session_direct(v_cid, v_uid, 'pending', 'l7_3');
  PERFORM test_helpers.assert(public.check_upload_session_lease(v_sid)=false, '7.3: pending → false');
END;
$$;

DO $$
DECLARE v_uid uuid; v_gid uuid; v_cid uuid; v_sid uuid;
BEGIN
  SELECT uid,gid,cid INTO v_uid,v_gid,v_cid FROM test_helpers.make_scenario('Lease7_4');
  v_sid := test_helpers.insert_session_direct(v_cid, v_uid, 'complete', 'l7_4');
  PERFORM test_helpers.assert(public.check_upload_session_lease(v_sid)=false, '7.4: complete → false');
END;
$$;


-- =============================================================================
-- GROUP 8: advance_upload_session_sanitized
-- =============================================================================
\echo ''
\echo '--- GROUP 8: advance_upload_session_sanitized ---'

DO $$
DECLARE v_uid uuid; v_gid uuid; v_cid uuid; v_sid uuid;
BEGIN
  SELECT uid,gid,cid INTO v_uid,v_gid,v_cid FROM test_helpers.make_scenario('Sanit8_1');
  v_sid := test_helpers.insert_session_direct(v_cid, v_uid, 'processing', 's8_1',
    NULL, now()-interval '1 hour', now()+interval '30 minutes');
  PERFORM public.advance_upload_session_sanitized(v_sid);
  PERFORM test_helpers.assert(
    EXISTS(SELECT 1 FROM private.upload_sessions WHERE session_id=v_sid AND status='sanitized'),
    '8.1: processing → sanitized');
END;
$$;

DO $$
DECLARE v_uid uuid; v_gid uuid; v_cid uuid; v_sid uuid; v_caught boolean := false;
BEGIN
  SELECT uid,gid,cid INTO v_uid,v_gid,v_cid FROM test_helpers.make_scenario('Sanit8_2');
  v_sid := test_helpers.insert_session_direct(v_cid, v_uid, 'pending', 's8_2');
  BEGIN PERFORM public.advance_upload_session_sanitized(v_sid);
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    IF SQLERRM LIKE '%FK_WRONG_STATE%' THEN v_caught := true;
    ELSE RAISE EXCEPTION 'FAIL 8.2: %', SQLERRM; END IF;
  WHEN OTHERS THEN RAISE EXCEPTION 'FAIL 8.2: % (%)', SQLERRM, SQLSTATE;
  END;
  PERFORM test_helpers.assert(v_caught, '8.2: not processing → FK_WRONG_STATE');
END;
$$;


-- =============================================================================
-- GROUP 9: finalize_upload_session  (V4: FK_INVALID_HASH; cases/ paths; public.cases)
-- =============================================================================
\echo ''
\echo '--- GROUP 9: finalize_upload_session ---'

-- 9.1  NULL hash → FK_INVALID_HASH
DO $$
DECLARE v_uid uuid; v_gid uuid; v_cid uuid; v_sid uuid; v_caught boolean := false;
BEGIN
  SELECT uid,gid,cid INTO v_uid,v_gid,v_cid FROM test_helpers.make_scenario('Fin9_1');
  v_sid := test_helpers.insert_session_direct(v_cid, v_uid, 'sanitized', 'f9_1');
  BEGIN PERFORM public.finalize_upload_session(v_sid, NULL);
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    IF SQLERRM LIKE '%FK_INVALID_HASH%' THEN v_caught := true;
    ELSE RAISE EXCEPTION 'FAIL 9.1: %', SQLERRM; END IF;
  WHEN OTHERS THEN RAISE EXCEPTION 'FAIL 9.1: % (%)', SQLERRM, SQLSTATE;
  END;
  PERFORM test_helpers.assert(v_caught, '9.1: NULL hash → FK_INVALID_HASH');
END;
$$;

-- 9.2  Uppercase hex → FK_INVALID_HASH
DO $$
DECLARE v_uid uuid; v_gid uuid; v_cid uuid; v_sid uuid; v_caught boolean := false;
BEGIN
  SELECT uid,gid,cid INTO v_uid,v_gid,v_cid FROM test_helpers.make_scenario('Fin9_2');
  v_sid := test_helpers.insert_session_direct(v_cid, v_uid, 'sanitized', 'f9_2');
  BEGIN PERFORM public.finalize_upload_session(v_sid, repeat('A', 64));
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    IF SQLERRM LIKE '%FK_INVALID_HASH%' THEN v_caught := true;
    ELSE RAISE EXCEPTION 'FAIL 9.2: %', SQLERRM; END IF;
  WHEN OTHERS THEN RAISE EXCEPTION 'FAIL 9.2: % (%)', SQLERRM, SQLSTATE;
  END;
  PERFORM test_helpers.assert(v_caught, '9.2: uppercase hex → FK_INVALID_HASH');
END;
$$;

-- 9.3  63-char hash → FK_INVALID_HASH
DO $$
DECLARE v_uid uuid; v_gid uuid; v_cid uuid; v_sid uuid; v_caught boolean := false;
BEGIN
  SELECT uid,gid,cid INTO v_uid,v_gid,v_cid FROM test_helpers.make_scenario('Fin9_3');
  v_sid := test_helpers.insert_session_direct(v_cid, v_uid, 'sanitized', 'f9_3');
  BEGIN PERFORM public.finalize_upload_session(v_sid, repeat('a', 63));
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    IF SQLERRM LIKE '%FK_INVALID_HASH%' THEN v_caught := true;
    ELSE RAISE EXCEPTION 'FAIL 9.3: %', SQLERRM; END IF;
  WHEN OTHERS THEN RAISE EXCEPTION 'FAIL 9.3: % (%)', SQLERRM, SQLSTATE;
  END;
  PERFORM test_helpers.assert(v_caught, '9.3: 63-char hash → FK_INVALID_HASH');
END;
$$;

-- 9.4  status=failed → FK_WRONG_STATE
DO $$
DECLARE v_uid uuid; v_gid uuid; v_cid uuid; v_sid uuid; v_caught boolean := false;
BEGIN
  SELECT uid,gid,cid INTO v_uid,v_gid,v_cid FROM test_helpers.make_scenario('Fin9_4');
  v_sid := test_helpers.insert_session_direct(v_cid, v_uid, 'failed', 'f9_4');
  BEGIN PERFORM public.finalize_upload_session(v_sid, repeat('a',64));
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    IF SQLERRM LIKE '%FK_WRONG_STATE%' THEN v_caught := true;
    ELSE RAISE EXCEPTION 'FAIL 9.4: %', SQLERRM; END IF;
  WHEN OTHERS THEN RAISE EXCEPTION 'FAIL 9.4: % (%)', SQLERRM, SQLSTATE;
  END;
  PERFORM test_helpers.assert(v_caught, '9.4: status=failed → FK_WRONG_STATE');
END;
$$;

-- 9.5  Happy path  (V4: public.cases)
DO $$
DECLARE
  v_uid uuid; v_gid uuid; v_cid uuid; v_sid uuid;
  v_mid uuid; v_old_mid uuid;
  v_hash text := repeat('a', 64);
BEGIN
  SELECT uid,gid,cid INTO v_uid,v_gid,v_cid FROM test_helpers.make_scenario('Fin9_5');
  v_sid := test_helpers.insert_session_direct(v_cid, v_uid, 'sanitized', 'f9_5');
  SELECT r.media_object_id, r.replaced_media_object_id INTO v_mid, v_old_mid
  FROM public.finalize_upload_session(v_sid, v_hash) r;
  PERFORM test_helpers.assert(v_mid IS NOT NULL, '9.5a: returns media_object_id');
  PERFORM test_helpers.assert(v_old_mid IS NULL,  '9.5b: first upload → replaced_media_object_id NULL');
  PERFORM test_helpers.assert(
    EXISTS(SELECT 1 FROM public.media_objects WHERE id=v_mid AND status='pending_review' AND mime_type='image/webp'),
    '9.5c: media_objects row status=pending_review, mime_type=image/webp');
  PERFORM test_helpers.assert(
    EXISTS(SELECT 1 FROM private.media_storage_keys WHERE media_object_id=v_mid AND sha256_hash=v_hash),
    '9.5d: media_storage_keys row has sha256_hash');
  -- V4: public.cases (not public.challenges)
  PERFORM test_helpers.assert(
    EXISTS(SELECT 1 FROM public.cases WHERE id=v_cid AND media_object_id=v_mid),
    '9.5e: case.media_object_id updated (V4: public.cases)');
  PERFORM test_helpers.assert(
    EXISTS(SELECT 1 FROM private.upload_sessions WHERE session_id=v_sid AND status='complete'),
    '9.5f: session=complete');
END;
$$;

-- 9.6  Idempotent
DO $$
DECLARE
  v_uid uuid; v_gid uuid; v_cid uuid; v_sid uuid;
  v_mid uuid; v_mid2 uuid; v_cnt_before int; v_cnt_after int;
  v_hash text := repeat('b', 64);
BEGIN
  SELECT uid,gid,cid INTO v_uid,v_gid,v_cid FROM test_helpers.make_scenario('Fin9_6');
  v_sid := test_helpers.insert_session_direct(v_cid, v_uid, 'sanitized', 'f9_6');
  SELECT r.media_object_id INTO v_mid FROM public.finalize_upload_session(v_sid, v_hash) r;
  SELECT count(*) INTO v_cnt_before FROM public.media_objects WHERE uploader_id=v_uid;
  SELECT r.media_object_id INTO v_mid2 FROM public.finalize_upload_session(v_sid, v_hash) r;
  SELECT count(*) INTO v_cnt_after FROM public.media_objects WHERE uploader_id=v_uid;
  PERFORM test_helpers.assert(v_mid2=v_mid, '9.6a: idempotent → same media_object_id');
  PERFORM test_helpers.assert(v_cnt_before=v_cnt_after, '9.6b: idempotent → no new row');
END;
$$;

-- 9.7  Re-upload supersedes pending_review media
DO $$
DECLARE
  v_uid uuid; v_gid uuid; v_cid uuid;
  v_sid_a uuid; v_sid_b uuid;
  v_mid_a uuid; v_mid_b uuid; v_rep_mid uuid;
  v_hash text := repeat('c', 64);
BEGIN
  SELECT uid,gid,cid INTO v_uid,v_gid,v_cid FROM test_helpers.make_scenario('Fin9_7');
  v_sid_a := test_helpers.insert_session_direct(v_cid, v_uid, 'sanitized', 'f9_7a');
  SELECT r.media_object_id INTO v_mid_a FROM public.finalize_upload_session(v_sid_a, v_hash) r;
  v_sid_b := test_helpers.insert_session_direct(v_cid, v_uid, 'sanitized', 'f9_7b');
  SELECT r.media_object_id, r.replaced_media_object_id INTO v_mid_b, v_rep_mid
  FROM public.finalize_upload_session(v_sid_b, v_hash) r;
  PERFORM test_helpers.assert(v_rep_mid=v_mid_a, '9.7a: replaced_media_object_id = prior');
  PERFORM test_helpers.assert(
    EXISTS(SELECT 1 FROM public.media_objects WHERE id=v_mid_a AND status='superseded'),
    '9.7b: prior media → superseded');
END;
$$;

-- 9.8  pending_review media blocks launch
-- V4: triggers fire on OLD.state='ready' AND NEW.state='launched'.
-- Advance to 'ready' first (draft→ready, no trigger), then try ready→launched.
DO $$
DECLARE
  v_uid uuid; v_gid uuid; v_cid uuid; v_sid uuid; v_mid uuid;
  v_hash text := repeat('d', 64);
  v_caught boolean := false;
BEGIN
  SELECT uid,gid,cid INTO v_uid,v_gid,v_cid FROM test_helpers.make_scenario('Fin9_8');
  v_sid := test_helpers.insert_session_direct(v_cid, v_uid, 'sanitized', 'f9_8');
  SELECT r.media_object_id INTO v_mid FROM public.finalize_upload_session(v_sid, v_hash) r;
  -- media is pending_review; advance to 'ready' (no trigger for draft→ready)
  SET LOCAL ROLE forkensics_executor;
  UPDATE public.cases SET state = 'ready' WHERE id = v_cid;
  RESET ROLE;
  -- try ready→launched → case_v4_media_ready_on_launch fires: media=pending_review → raises
  BEGIN
    SET LOCAL ROLE forkensics_executor;
    UPDATE public.cases SET state       = 'launched',
                             posted_at   = now() - interval '1 hour',
                             deadline_at = now() + interval '2 hours'
    WHERE id = v_cid;
    RESET ROLE;
  EXCEPTION WHEN OTHERS THEN RESET ROLE; v_caught := true;
  END;
  PERFORM test_helpers.assert(v_caught,
    '9.8: pending_review media → case_v4_media_ready_on_launch blocks launch (V4: ready→launched)');
END;
$$;

-- 9.9  Launch passes after media=ready
DO $$
DECLARE
  v_uid uuid; v_gid uuid; v_cid uuid; v_sid uuid; v_mid uuid;
  v_hash text := repeat('e', 64);
BEGIN
  SELECT uid,gid,cid INTO v_uid,v_gid,v_cid FROM test_helpers.make_scenario('Fin9_9');
  v_sid := test_helpers.insert_session_direct(v_cid, v_uid, 'sanitized', 'f9_9');
  SELECT r.media_object_id INTO v_mid FROM public.finalize_upload_session(v_sid, v_hash) r;
  SET LOCAL ROLE forkensics_executor;
  UPDATE public.media_objects SET status='ready' WHERE id=v_mid;
  -- advance to 'ready', then launch
  UPDATE public.cases SET state = 'ready' WHERE id = v_cid;
  UPDATE public.cases SET state       = 'launched',
                          posted_at   = now() - interval '1 hour',
                          deadline_at = now() + interval '2 hours'
  WHERE id = v_cid;
  RESET ROLE;
  PERFORM test_helpers.assert(
    EXISTS(SELECT 1 FROM public.cases WHERE id=v_cid AND state='launched'),
    '9.9: media=ready → triggers pass, case launched (V4: state=launched)');
END;
$$;


-- =============================================================================
-- GROUP 10: claim_cleanup_sessions
-- =============================================================================
\echo ''
\echo '--- GROUP 10: claim_cleanup_sessions ---'

-- 10.1  Stale pending → expired then claimed; cleanup_claim_token set
DO $$
DECLARE v_uid uuid; v_gid uuid; v_cid uuid; v_sid uuid; v_found boolean; v_has_tok boolean;
BEGIN
  SELECT uid,gid,cid INTO v_uid,v_gid,v_cid FROM test_helpers.make_scenario('CCS10_1');
  v_sid := test_helpers.insert_session_direct(v_cid, v_uid, 'pending', 'c10_1',
    now()-interval '5 minutes');
  SELECT (c.session_id=v_sid), (c.cleanup_claim_token IS NOT NULL)
  INTO v_found, v_has_tok
  FROM public.claim_cleanup_sessions('worker-test') c WHERE c.session_id=v_sid;
  PERFORM test_helpers.assert(v_found,   '10.1a: stale pending returned');
  PERFORM test_helpers.assert(v_has_tok, '10.1b: cleanup_claim_token set');
END;
$$;

-- 10.2  Stale processing (lease expired) → failed then claimed
DO $$
DECLARE v_uid uuid; v_gid uuid; v_cid uuid; v_sid uuid; v_found boolean;
BEGIN
  SELECT uid,gid,cid INTO v_uid,v_gid,v_cid FROM test_helpers.make_scenario('CCS10_2');
  v_sid := test_helpers.insert_session_direct(v_cid, v_uid, 'processing', 'c10_2',
    NULL, now()-interval '2 hours', now()-interval '60 minutes');
  SELECT (c.session_id=v_sid) INTO v_found
  FROM public.claim_cleanup_sessions('worker-test') c WHERE c.session_id=v_sid;
  PERFORM test_helpers.assert(v_found, '10.2: stale processing → claimed');
END;
$$;

-- 10.3  Abandoned sanitized (lease + 60 min past) → failed then claimed
DO $$
DECLARE v_uid uuid; v_gid uuid; v_cid uuid; v_sid uuid; v_found boolean;
BEGIN
  SELECT uid,gid,cid INTO v_uid,v_gid,v_cid FROM test_helpers.make_scenario('CCS10_3');
  v_sid := test_helpers.insert_session_direct(v_cid, v_uid, 'sanitized', 'c10_3',
    NULL, now()-interval '2 hours', now()-interval '70 minutes');
  SELECT (c.session_id=v_sid) INTO v_found
  FROM public.claim_cleanup_sessions('worker-test') c WHERE c.session_id=v_sid;
  PERFORM test_helpers.assert(v_found, '10.3: abandoned sanitized → claimed');
END;
$$;

-- 10.4  NULL storage_upload_expires_at → claimed immediately
DO $$
DECLARE v_uid uuid; v_gid uuid; v_cid uuid; v_sid uuid; v_found boolean;
BEGIN
  SELECT uid,gid,cid INTO v_uid,v_gid,v_cid FROM test_helpers.make_scenario('CCS10_4');
  v_sid := test_helpers.insert_session_direct(v_cid, v_uid, 'failed', 'c10_4',
    now()-interval '1 hour', NULL);
  SELECT (c.session_id=v_sid) INTO v_found
  FROM public.claim_cleanup_sessions('worker-test') c WHERE c.session_id=v_sid;
  PERFORM test_helpers.assert(v_found, '10.4: NULL storage_upload_expires_at → claimed immediately');
END;
$$;

-- 10.5  URL + 30s still in future → NOT claimed
DO $$
DECLARE v_uid uuid; v_gid uuid; v_cid uuid; v_sid uuid;
BEGIN
  SELECT uid,gid,cid INTO v_uid,v_gid,v_cid FROM test_helpers.make_scenario('CCS10_5');
  v_sid := test_helpers.insert_session_direct(v_cid, v_uid, 'failed', 'c10_5',
    now()-interval '1 hour', now()+interval '5 minutes');
  PERFORM test_helpers.assert(
    NOT EXISTS(SELECT 1 FROM public.claim_cleanup_sessions('worker-test') c WHERE c.session_id=v_sid),
    '10.5: URL still valid → NOT claimed');
END;
$$;

-- 10.6  complete → never returned
DO $$
DECLARE v_uid uuid; v_gid uuid; v_cid uuid; v_sid uuid;
BEGIN
  SELECT uid,gid,cid INTO v_uid,v_gid,v_cid FROM test_helpers.make_scenario('CCS10_6');
  v_sid := test_helpers.insert_session_direct(v_cid, v_uid, 'complete', 'c10_6');
  PERFORM test_helpers.assert(
    NOT EXISTS(SELECT 1 FROM public.claim_cleanup_sessions('worker-test') c WHERE c.session_id=v_sid),
    '10.6: complete → never returned');
END;
$$;


-- =============================================================================
-- GROUP 11: mark_session_cleaned
-- =============================================================================
\echo ''
\echo '--- GROUP 11: mark_session_cleaned ---'

-- 11.1  failed with valid claim → cleaned
DO $$
DECLARE v_uid uuid; v_gid uuid; v_cid uuid; v_sid uuid; v_token uuid;
BEGIN
  SELECT uid,gid,cid INTO v_uid,v_gid,v_cid FROM test_helpers.make_scenario('MSC11_1');
  v_sid := test_helpers.insert_session_direct(v_cid, v_uid, 'failed', 'm11_1',
    now()-interval '1 hour', NULL);
  UPDATE private.upload_sessions
  SET cleanup_claim_token=gen_random_uuid(), cleanup_claimed_at=now(),
      cleanup_claim_expires_at=now()+interval '15 minutes'
  WHERE session_id=v_sid RETURNING cleanup_claim_token INTO v_token;
  PERFORM public.mark_session_cleaned(v_sid, v_token);
  PERFORM test_helpers.assert(
    EXISTS(SELECT 1 FROM private.upload_sessions WHERE session_id=v_sid AND status='cleaned'),
    '11.1: failed → cleaned');
END;
$$;

-- 11.2  already cleaned → idempotent
DO $$
DECLARE v_uid uuid; v_gid uuid; v_cid uuid; v_sid uuid; v_token uuid;
BEGIN
  SELECT uid,gid,cid INTO v_uid,v_gid,v_cid FROM test_helpers.make_scenario('MSC11_2');
  v_sid := test_helpers.insert_session_direct(v_cid, v_uid, 'failed', 'm11_2',
    now()-interval '1 hour', NULL);
  UPDATE private.upload_sessions
  SET cleanup_claim_token=gen_random_uuid(), cleanup_claimed_at=now(),
      cleanup_claim_expires_at=now()+interval '15 minutes'
  WHERE session_id=v_sid RETURNING cleanup_claim_token INTO v_token;
  PERFORM public.mark_session_cleaned(v_sid, v_token);
  PERFORM public.mark_session_cleaned(v_sid, v_token);
  PERFORM test_helpers.assert(true, '11.2: already cleaned → idempotent');
END;
$$;

-- 11.3  complete → FK_WRONG_STATE
DO $$
DECLARE v_uid uuid; v_gid uuid; v_cid uuid; v_sid uuid; v_token uuid; v_caught boolean := false;
BEGIN
  SELECT uid,gid,cid INTO v_uid,v_gid,v_cid FROM test_helpers.make_scenario('MSC11_3');
  v_sid := test_helpers.insert_session_direct(v_cid, v_uid, 'complete', 'm11_3');
  UPDATE private.upload_sessions
  SET cleanup_claim_token=gen_random_uuid(), cleanup_claimed_at=now(),
      cleanup_claim_expires_at=now()+interval '15 minutes'
  WHERE session_id=v_sid RETURNING cleanup_claim_token INTO v_token;
  BEGIN PERFORM public.mark_session_cleaned(v_sid, v_token);
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    IF SQLERRM LIKE '%FK_WRONG_STATE%' THEN v_caught := true;
    ELSE RAISE EXCEPTION 'FAIL 11.3: %', SQLERRM; END IF;
  WHEN OTHERS THEN RAISE EXCEPTION 'FAIL 11.3: % (%)', SQLERRM, SQLSTATE;
  END;
  PERFORM test_helpers.assert(v_caught, '11.3: complete → FK_WRONG_STATE');
END;
$$;

-- 11.4  Token mismatch → raises
DO $$
DECLARE v_uid uuid; v_gid uuid; v_cid uuid; v_sid uuid; v_caught boolean := false;
BEGIN
  SELECT uid,gid,cid INTO v_uid,v_gid,v_cid FROM test_helpers.make_scenario('MSC11_4');
  v_sid := test_helpers.insert_session_direct(v_cid, v_uid, 'expired', 'm11_4');
  UPDATE private.upload_sessions
  SET cleanup_claim_token=gen_random_uuid(), cleanup_claimed_at=now(),
      cleanup_claim_expires_at=now()+interval '15 minutes'
  WHERE session_id=v_sid;
  BEGIN PERFORM public.mark_session_cleaned(v_sid, gen_random_uuid());
  EXCEPTION WHEN SQLSTATE 'P0001' THEN v_caught := true;
  WHEN OTHERS THEN RAISE EXCEPTION 'FAIL 11.4: % (%)', SQLERRM, SQLSTATE;
  END;
  PERFORM test_helpers.assert(v_caught, '11.4: token mismatch → raises');
END;
$$;

-- 11.5  Claim expired → raises
DO $$
DECLARE v_uid uuid; v_gid uuid; v_cid uuid; v_sid uuid; v_token uuid; v_caught boolean := false;
BEGIN
  SELECT uid,gid,cid INTO v_uid,v_gid,v_cid FROM test_helpers.make_scenario('MSC11_5');
  v_sid := test_helpers.insert_session_direct(v_cid, v_uid, 'failed', 'm11_5',
    now()-interval '1 hour', NULL);
  UPDATE private.upload_sessions
  SET cleanup_claim_token=gen_random_uuid(),
      cleanup_claimed_at=now()-interval '20 minutes',
      cleanup_claim_expires_at=now()-interval '5 minutes'
  WHERE session_id=v_sid RETURNING cleanup_claim_token INTO v_token;
  BEGIN PERFORM public.mark_session_cleaned(v_sid, v_token);
  EXCEPTION WHEN SQLSTATE 'P0001' THEN v_caught := true;
  WHEN OTHERS THEN RAISE EXCEPTION 'FAIL 11.5: % (%)', SQLERRM, SQLSTATE;
  END;
  PERFORM test_helpers.assert(v_caught, '11.5: expired claim → raises');
END;
$$;


-- =============================================================================
-- GROUP 12: get_upload_capability_expiry
-- =============================================================================
\echo ''
\echo '--- GROUP 12: get_upload_capability_expiry ---'

-- 12.1  Non-NULL future storage_upload_expires_at → blocking_until set
DO $$
DECLARE v_uid uuid; v_gid uuid; v_cid uuid; v_blocking timestamptz;
BEGIN
  SELECT uid,gid,cid INTO v_uid,v_gid,v_cid FROM test_helpers.make_scenario('Cap12_1');
  PERFORM test_helpers.insert_session_direct(v_cid, v_uid, 'pending', 'cap12_1',
    NULL, now()+interval '3 minutes');
  SELECT blocking_until INTO v_blocking FROM public.get_upload_capability_expiry(v_uid);
  PERFORM test_helpers.assert(v_blocking IS NOT NULL, '12.1a: future expiry → non-NULL');
  PERFORM test_helpers.assert(v_blocking > now(), '12.1b: blocking_until in future');
END;
$$;

-- 12.2  NULL storage_upload_expires_at → excluded → blocking_until NULL
DO $$
DECLARE v_uid uuid; v_gid uuid; v_cid uuid; v_blocking timestamptz;
BEGIN
  SELECT uid,gid,cid INTO v_uid,v_gid,v_cid FROM test_helpers.make_scenario('Cap12_2');
  PERFORM test_helpers.insert_session_direct(v_cid, v_uid, 'pending', 'cap12_2', NULL, NULL);
  SELECT blocking_until INTO v_blocking FROM public.get_upload_capability_expiry(v_uid);
  PERFORM test_helpers.assert(v_blocking IS NULL, '12.2: only NULL expiries → blocking_until NULL');
END;
$$;

-- 12.3  All expiries past → NULL
DO $$
DECLARE v_uid uuid; v_gid uuid; v_cid uuid; v_blocking timestamptz;
BEGIN
  SELECT uid,gid,cid INTO v_uid,v_gid,v_cid FROM test_helpers.make_scenario('Cap12_3');
  PERFORM test_helpers.insert_session_direct(v_cid, v_uid, 'failed', 'cap12_3',
    NULL, now()-interval '1 hour');
  SELECT blocking_until INTO v_blocking FROM public.get_upload_capability_expiry(v_uid);
  PERFORM test_helpers.assert(v_blocking IS NULL, '12.3: all expiries past → NULL');
END;
$$;


-- =============================================================================
-- GROUP 13: quiesce_upload_sessions_for_deletion
-- =============================================================================
\echo ''
\echo '--- GROUP 13: quiesce_upload_sessions_for_deletion ---'

-- 13.1  pending → failed, returned, blocking_lease_expires_at NULL
DO $$
DECLARE v_uid uuid; v_gid uuid; v_cid uuid; v_sid uuid; v_row record;
BEGIN
  SELECT uid,gid,cid INTO v_uid,v_gid,v_cid FROM test_helpers.make_scenario('Qsc13_1');
  v_sid := test_helpers.insert_session_direct(v_cid, v_uid, 'pending', 'q13_1');
  SELECT session_id, prior_status, blocking_lease_expires_at INTO v_row
  FROM public.quiesce_upload_sessions_for_deletion(v_uid) WHERE session_id=v_sid;
  PERFORM test_helpers.assert(v_row.session_id IS NOT NULL,            '13.1a: pending returned');
  PERFORM test_helpers.assert(v_row.prior_status='pending',             '13.1b: prior_status=pending');
  PERFORM test_helpers.assert(v_row.blocking_lease_expires_at IS NULL,  '13.1c: blocking_lease NULL');
  PERFORM test_helpers.assert(
    EXISTS(SELECT 1 FROM private.upload_sessions WHERE session_id=v_sid AND status='failed'),
    '13.1d: pending → failed');
END;
$$;

-- 13.2  sanitized → failed, returned
DO $$
DECLARE v_uid uuid; v_gid uuid; v_cid uuid; v_sid uuid; v_row record;
BEGIN
  SELECT uid,gid,cid INTO v_uid,v_gid,v_cid FROM test_helpers.make_scenario('Qsc13_2');
  v_sid := test_helpers.insert_session_direct(v_cid, v_uid, 'sanitized', 'q13_2');
  SELECT session_id, prior_status INTO v_row
  FROM public.quiesce_upload_sessions_for_deletion(v_uid) WHERE session_id=v_sid;
  PERFORM test_helpers.assert(v_row.session_id IS NOT NULL,  '13.2a: sanitized returned');
  PERFORM test_helpers.assert(v_row.prior_status='sanitized', '13.2b: prior_status=sanitized');
  PERFORM test_helpers.assert(
    EXISTS(SELECT 1 FROM private.upload_sessions WHERE session_id=v_sid AND status='failed'),
    '13.2c: sanitized → failed');
END;
$$;

-- 13.3  processing with active lease → returned, NOT transitioned, blocking_lease set
DO $$
DECLARE v_uid uuid; v_gid uuid; v_cid uuid; v_sid uuid; v_row record;
BEGIN
  SELECT uid,gid,cid INTO v_uid,v_gid,v_cid FROM test_helpers.make_scenario('Qsc13_3');
  v_sid := test_helpers.insert_session_direct(v_cid, v_uid, 'processing', 'q13_3',
    NULL, NULL, now()+interval '30 minutes');
  SELECT session_id, blocking_lease_expires_at INTO v_row
  FROM public.quiesce_upload_sessions_for_deletion(v_uid) WHERE session_id=v_sid;
  PERFORM test_helpers.assert(v_row.session_id IS NOT NULL,                '13.3a: active-lease returned');
  PERFORM test_helpers.assert(v_row.blocking_lease_expires_at IS NOT NULL,  '13.3b: blocking_lease set');
  PERFORM test_helpers.assert(
    EXISTS(SELECT 1 FROM private.upload_sessions WHERE session_id=v_sid AND status='processing'),
    '13.3c: active-lease NOT transitioned');
END;
$$;

-- 13.4  processing with expired lease → failed, returned
DO $$
DECLARE v_uid uuid; v_gid uuid; v_cid uuid; v_sid uuid; v_row record;
BEGIN
  SELECT uid,gid,cid INTO v_uid,v_gid,v_cid FROM test_helpers.make_scenario('Qsc13_4');
  v_sid := test_helpers.insert_session_direct(v_cid, v_uid, 'processing', 'q13_4',
    NULL, NULL, now()-interval '5 minutes');
  SELECT session_id, blocking_lease_expires_at INTO v_row
  FROM public.quiesce_upload_sessions_for_deletion(v_uid) WHERE session_id=v_sid;
  PERFORM test_helpers.assert(v_row.session_id IS NOT NULL,           '13.4a: expired-lease returned');
  PERFORM test_helpers.assert(v_row.blocking_lease_expires_at IS NULL, '13.4b: blocking_lease NULL');
  PERFORM test_helpers.assert(
    EXISTS(SELECT 1 FROM private.upload_sessions WHERE session_id=v_sid AND status='failed'),
    '13.4c: expired-lease → failed');
END;
$$;

-- 13.5  complete/failed/cleaned → NOT returned
DO $$
DECLARE
  v_u1 uuid; v_g1 uuid; v_c1 uuid;
  v_u2 uuid; v_g2 uuid; v_c2 uuid;
  v_u3 uuid; v_g3 uuid; v_c3 uuid;
BEGIN
  SELECT uid,gid,cid INTO v_u1,v_g1,v_c1 FROM test_helpers.make_scenario('Qsc13_5a');
  SELECT uid,gid,cid INTO v_u2,v_g2,v_c2 FROM test_helpers.make_scenario('Qsc13_5b');
  SELECT uid,gid,cid INTO v_u3,v_g3,v_c3 FROM test_helpers.make_scenario('Qsc13_5c');
  PERFORM test_helpers.insert_session_direct(v_c1, v_u1, 'complete', 'q13_5a');
  PERFORM test_helpers.insert_session_direct(v_c2, v_u2, 'failed',   'q13_5b');
  PERFORM test_helpers.insert_session_direct(v_c3, v_u3, 'cleaned',  'q13_5c');
  PERFORM test_helpers.assert(NOT EXISTS(SELECT 1 FROM public.quiesce_upload_sessions_for_deletion(v_u1)), '13.5a: complete not returned');
  PERFORM test_helpers.assert(NOT EXISTS(SELECT 1 FROM public.quiesce_upload_sessions_for_deletion(v_u2)), '13.5b: failed not returned');
  PERFORM test_helpers.assert(NOT EXISTS(SELECT 1 FROM public.quiesce_upload_sessions_for_deletion(v_u3)), '13.5c: cleaned not returned');
END;
$$;


-- =============================================================================
-- GROUP 14: get_all_upload_session_paths_for_deletion
-- =============================================================================
\echo ''
\echo '--- GROUP 14: get_all_upload_session_paths_for_deletion ---'

DO $$
DECLARE
  v_u1 uuid; v_g1 uuid; v_c1 uuid;
  v_u2 uuid; v_g2 uuid; v_c2 uuid;
  v_u3 uuid; v_g3 uuid; v_c3 uuid;
  v_s1 uuid; v_s2 uuid; v_s3 uuid;
  v_row record;
BEGIN
  SELECT uid,gid,cid INTO v_u1,v_g1,v_c1 FROM test_helpers.make_scenario('Paths14_cmp');
  SELECT uid,gid,cid INTO v_u2,v_g2,v_c2 FROM test_helpers.make_scenario('Paths14_fld');
  SELECT uid,gid,cid INTO v_u3,v_g3,v_c3 FROM test_helpers.make_scenario('Paths14_cln');
  v_s1 := test_helpers.insert_session_direct(v_c1, v_u1, 'complete', 'p14_cmp');
  v_s2 := test_helpers.insert_session_direct(v_c2, v_u2, 'failed',   'p14_fld');
  v_s3 := test_helpers.insert_session_direct(v_c3, v_u3, 'cleaned',  'p14_cln');

  -- complete: original included, display NULL
  SELECT original_storage_path, display_storage_path INTO v_row
  FROM public.get_all_upload_session_paths_for_deletion(v_u1) WHERE session_id=v_s1;
  PERFORM test_helpers.assert(v_row.original_storage_path IS NOT NULL, '14.1a: complete: original included');
  PERFORM test_helpers.assert(v_row.display_storage_path IS NULL,       '14.1b: complete: display NULL');

  -- failed: both paths
  SELECT original_storage_path, display_storage_path INTO v_row
  FROM public.get_all_upload_session_paths_for_deletion(v_u2) WHERE session_id=v_s2;
  PERFORM test_helpers.assert(v_row.original_storage_path IS NOT NULL, '14.2a: failed: original included');
  PERFORM test_helpers.assert(v_row.display_storage_path  IS NOT NULL, '14.2b: failed: display included');

  -- cleaned: excluded
  PERFORM test_helpers.assert(
    NOT EXISTS(SELECT 1 FROM public.get_all_upload_session_paths_for_deletion(v_u3) WHERE session_id=v_s3),
    '14.3: cleaned excluded');
END;
$$;


-- =============================================================================
-- GROUP 15: record_deletion_failure_wrapper
-- =============================================================================
\echo ''
\echo '--- GROUP 15: record_deletion_failure_wrapper ---'

DO $$
DECLARE v_uid uuid; v_gid uuid; v_cid uuid; v_caught boolean;
BEGIN
  SELECT uid,gid,cid INTO v_uid,v_gid,v_cid FROM test_helpers.make_scenario('RDF15');
  INSERT INTO private.deletion_log (profile_id, status, db_prepared_at)
  VALUES (v_uid, 'database_prepared', now());

  -- 15.1  NULL → FK_INVALID_INPUT
  v_caught := false;
  BEGIN PERFORM public.record_deletion_failure_wrapper(v_uid, NULL);
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    IF SQLERRM LIKE '%FK_INVALID_INPUT%' THEN v_caught := true;
    ELSE RAISE EXCEPTION 'FAIL 15.1: %', SQLERRM; END IF;
  WHEN OTHERS THEN RAISE EXCEPTION 'FAIL 15.1: % (%)', SQLERRM, SQLSTATE;
  END;
  PERFORM test_helpers.assert(v_caught, '15.1: NULL → FK_INVALID_INPUT');

  -- 15.2  No FK_ prefix → FK_INVALID_INPUT
  v_caught := false;
  BEGIN PERFORM public.record_deletion_failure_wrapper(v_uid, 'not_matching');
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    IF SQLERRM LIKE '%FK_INVALID_INPUT%' THEN v_caught := true;
    ELSE RAISE EXCEPTION 'FAIL 15.2: %', SQLERRM; END IF;
  WHEN OTHERS THEN RAISE EXCEPTION 'FAIL 15.2: % (%)', SQLERRM, SQLSTATE;
  END;
  PERFORM test_helpers.assert(v_caught, '15.2: no FK_ prefix → FK_INVALID_INPUT');

  -- 15.3  51 chars → FK_INVALID_INPUT
  v_caught := false;
  BEGIN PERFORM public.record_deletion_failure_wrapper(v_uid, 'FK_' || repeat('A', 48));
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    IF SQLERRM LIKE '%FK_INVALID_INPUT%' THEN v_caught := true;
    ELSE RAISE EXCEPTION 'FAIL 15.3: %', SQLERRM; END IF;
  WHEN OTHERS THEN RAISE EXCEPTION 'FAIL 15.3: % (%)', SQLERRM, SQLSTATE;
  END;
  PERFORM test_helpers.assert(v_caught, '15.3: >50 chars → FK_INVALID_INPUT');

  -- 15.4  Valid → succeeds
  PERFORM public.record_deletion_failure_wrapper(v_uid, 'FK_DELETION_FAILED');
  PERFORM test_helpers.assert(true, '15.4: FK_DELETION_FAILED → succeeds');
END;
$$;


-- =============================================================================
-- GROUP 16: V4 TRIGGERS ON CASES
-- V2 triggers fired on draft→active; V4 triggers fire on ready→launched.
-- Tests advance case to 'ready' first, then test the ready→launched transition.
-- Group 16 verifies both the error message and the resulting case state.
-- =============================================================================
\echo ''
\echo '--- GROUP 16: V4 Triggers on Cases (ported from V2 challenge triggers) ---'

-- 16.1  Active upload session → case_v4_no_active_upload_on_launch blocks launch
DO $$
DECLARE v_uid uuid; v_gid uuid; v_cid uuid; v_mid uuid; v_caught boolean := false; v_err text;
BEGIN
  SELECT uid,gid,cid INTO v_uid,v_gid,v_cid FROM test_helpers.make_scenario('Trig16_1');
  PERFORM test_helpers.insert_session_direct(v_cid, v_uid, 'pending', 't16_1');
  v_mid := test_helpers.insert_media_object(v_uid, 'ready');
  -- advance to 'ready' with ready media attached (media gate passes; upload-session gate is the target)
  SET LOCAL ROLE forkensics_executor;
  UPDATE public.cases SET media_object_id = v_mid, state = 'ready' WHERE id = v_cid;
  RESET ROLE;
  -- try ready→launched → no_active_upload trigger fires
  BEGIN
    SET LOCAL ROLE forkensics_executor;
    UPDATE public.cases SET state       = 'launched',
                             posted_at   = now() - interval '1 hour',
                             deadline_at = now() + interval '2 hours'
    WHERE id = v_cid;
    RESET ROLE;
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE; v_caught := true; v_err := SQLERRM;
  END;
  PERFORM test_helpers.assert(v_caught, '16.1a: pending session → launch blocked');
  PERFORM test_helpers.assert(
    v_err LIKE '%active upload session%',
    '16.1b: error from no_active_upload trigger (got: ' || COALESCE(v_err,'NULL') || ')');
  PERFORM test_helpers.assert(
    EXISTS(SELECT 1 FROM public.cases WHERE id=v_cid AND state='ready'),
    '16.1c: case remains in ready state (not launched)');
END;
$$;

-- 16.2  Complete session clears upload trigger; NULL media still fires media trigger
DO $$
DECLARE v_uid uuid; v_gid uuid; v_cid uuid; v_sid uuid;
        v_caught boolean := false; v_err text;
BEGIN
  SELECT uid,gid,cid INTO v_uid,v_gid,v_cid FROM test_helpers.make_scenario('Trig16_2');
  v_sid := test_helpers.insert_session_direct(v_cid, v_uid, 'pending', 't16_2');
  UPDATE private.upload_sessions SET status='complete', status_changed_at=now() WHERE session_id=v_sid;
  -- advance to 'ready'
  SET LOCAL ROLE forkensics_executor;
  UPDATE public.cases SET state = 'ready' WHERE id = v_cid;
  RESET ROLE;
  -- try ready→launched: no-active-upload trigger passes (no active sessions);
  -- media-ready trigger fires (media_object_id IS NULL)
  BEGIN
    SET LOCAL ROLE forkensics_executor;
    UPDATE public.cases SET state       = 'launched',
                             posted_at   = now() - interval '1 hour',
                             deadline_at = now() + interval '2 hours'
    WHERE id = v_cid;
    RESET ROLE;
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE; v_caught := true; v_err := SQLERRM;
  END;
  PERFORM test_helpers.assert(v_caught, '16.2a: NULL media → launch blocked');
  -- Error must come from the media trigger, not the upload trigger
  PERFORM test_helpers.assert(
    v_err LIKE '%media object%',
    '16.2b: error is from media_ready trigger (not upload trigger) — message: ' || COALESCE(v_err,'NULL'));
  PERFORM test_helpers.assert(
    v_err NOT LIKE '%active upload session%',
    '16.2c: upload trigger did NOT block (complete session is inactive)');
  PERFORM test_helpers.assert(
    EXISTS(SELECT 1 FROM public.cases WHERE id=v_cid AND state='ready'),
    '16.2d: case remains in ready state');
END;
$$;

-- 16.3  NULL media_object_id → case_v4_media_ready_on_launch raises
DO $$
DECLARE v_uid uuid; v_gid uuid; v_cid uuid; v_caught boolean := false; v_err text;
BEGIN
  SELECT uid,gid,cid INTO v_uid,v_gid,v_cid FROM test_helpers.make_scenario('Trig16_3');
  SET LOCAL ROLE forkensics_executor;
  UPDATE public.cases SET state = 'ready' WHERE id = v_cid;
  RESET ROLE;
  BEGIN
    SET LOCAL ROLE forkensics_executor;
    UPDATE public.cases SET state       = 'launched',
                             posted_at   = now() - interval '1 hour',
                             deadline_at = now() + interval '2 hours'
    WHERE id = v_cid;
    RESET ROLE;
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE; v_caught := true; v_err := SQLERRM;
  END;
  PERFORM test_helpers.assert(v_caught, '16.3a: NULL media → launch blocked');
  PERFORM test_helpers.assert(
    v_err LIKE '%media object%',
    '16.3b: error from media_ready trigger (got: ' || COALESCE(v_err,'NULL') || ')');
  PERFORM test_helpers.assert(
    EXISTS(SELECT 1 FROM public.cases WHERE id=v_cid AND state='ready'),
    '16.3c: case remains in ready state');
END;
$$;

-- 16.4–16.7  Non-ready media statuses block launch
DO $$
DECLARE
  v_uid uuid; v_gid uuid; v_cid uuid; v_mid uuid;
  v_status text; v_statuses text[] := ARRAY['pending_review','rejected','superseded','removed'];
  v_caught boolean; v_err text;
BEGIN
  FOREACH v_status IN ARRAY v_statuses LOOP
    SELECT uid,gid,cid INTO v_uid,v_gid,v_cid FROM test_helpers.make_scenario('Trig16_' || v_status);
    v_mid := test_helpers.insert_media_object(v_uid, v_status);
    SET LOCAL ROLE forkensics_executor;
    UPDATE public.cases SET media_object_id = v_mid WHERE id = v_cid;
    UPDATE public.cases SET state = 'ready' WHERE id = v_cid;
    RESET ROLE;
    v_caught := false; v_err := NULL;
    BEGIN
      SET LOCAL ROLE forkensics_executor;
      UPDATE public.cases SET state       = 'launched',
                               posted_at   = now() - interval '1 hour',
                               deadline_at = now() + interval '2 hours'
      WHERE id = v_cid;
      RESET ROLE;
    EXCEPTION WHEN OTHERS THEN
      RESET ROLE; v_caught := true; v_err := SQLERRM;
    END;
    PERFORM test_helpers.assert(v_caught,
      '16.4-7a: status=' || v_status || ' → launch blocked');
    PERFORM test_helpers.assert(
      v_err LIKE '%media object%',
      '16.4-7b: status=' || v_status || ' → media_ready trigger fired (got: ' || COALESCE(v_err,'NULL') || ')');
    PERFORM test_helpers.assert(
      EXISTS(SELECT 1 FROM public.cases WHERE id=v_cid AND state='ready'),
      '16.4-7c: status=' || v_status || ' → case still ready');
  END LOOP;
END;
$$;

-- 16.8  media=ready → both triggers pass; case launched
DO $$
DECLARE v_uid uuid; v_gid uuid; v_cid uuid; v_mid uuid;
BEGIN
  SELECT uid,gid,cid INTO v_uid,v_gid,v_cid FROM test_helpers.make_scenario('Trig16_8');
  v_mid := test_helpers.insert_media_object(v_uid, 'ready');
  SET LOCAL ROLE forkensics_executor;
  UPDATE public.cases SET media_object_id = v_mid WHERE id = v_cid;
  UPDATE public.cases SET state = 'ready' WHERE id = v_cid;
  UPDATE public.cases SET state       = 'launched',
                          posted_at   = now() - interval '1 hour',
                          deadline_at = now() + interval '2 hours'
  WHERE id = v_cid;
  RESET ROLE;
  PERFORM test_helpers.assert(
    EXISTS(SELECT 1 FROM public.cases WHERE id=v_cid AND state='launched'),
    '16.8: media=ready → case launched (V4: state=launched)');
END;
$$;


-- =============================================================================
-- GROUP 17: PERMISSION VERIFICATION  (V4: reveal_case_service_wrapper)
-- =============================================================================
\echo ''
\echo '--- GROUP 17: Permission Verification (V4: reveal_case_service_wrapper) ---'

DO $$
DECLARE
  v_fn text;
  -- V4: reveal_challenge_service_wrapper → reveal_case_service_wrapper
  v_sigs text[] := ARRAY[
    'public.reserve_upload_session(uuid,uuid,text,text,bigint,timestamp with time zone)',
    'public.activate_upload_session(uuid,timestamp with time zone)',
    'public.resolve_upload_session(text,uuid)',
    'public.advance_upload_session_processing(uuid,uuid,interval)',
    'public.check_upload_session_lease(uuid)',
    'public.advance_upload_session_sanitized(uuid)',
    'public.finalize_upload_session(uuid,text)',
    'public.fail_upload_session(uuid,text)',
    'public.quiesce_upload_sessions_for_deletion(uuid)',
    'public.get_upload_capability_expiry(uuid)',
    'public.get_all_upload_session_paths_for_deletion(uuid)',
    'public.claim_cleanup_sessions(text,interval)',
    'public.mark_session_cleaned(uuid,uuid)',
    'public.mark_original_path_post_expiry_cleaned(uuid)',
    'public.get_complete_sessions_pending_expiry_cleanup()',
    'public.get_superseded_media_to_clean()',
    'public.mark_superseded_media_cleaned(uuid)',
    'public.get_media_storage_key(uuid)',
    'public.reveal_case_service_wrapper(uuid)',
    'public.prepare_account_deletion_wrapper(uuid)',
    'public.get_deletion_storage_keys(uuid)',
    'public.record_deletion_failure_wrapper(uuid,text)',
    'public.mark_auth_deleted_wrapper(uuid)',
    'public.mark_storage_cleaned_wrapper(uuid)',
    'public.claim_deletion_recovery_records(text,interval,interval)',
    'public.complete_deletion_recovery(uuid,uuid,text)',
    'public.fail_deletion_recovery(uuid,uuid,text)'
  ];
BEGIN
  FOREACH v_fn IN ARRAY v_sigs LOOP
    PERFORM test_helpers.assert(
      has_function_privilege('service_role', v_fn, 'EXECUTE'),
      '17.1: service_role EXECUTE on ' || v_fn);
    PERFORM test_helpers.assert(
      NOT has_function_privilege('authenticated', v_fn, 'EXECUTE'),
      '17.2: authenticated cannot EXECUTE ' || v_fn);
    PERFORM test_helpers.assert(
      NOT has_function_privilege('anon', v_fn, 'EXECUTE'),
      '17.3: anon cannot EXECUTE ' || v_fn);
  END LOOP;
END;
$$;

DO $$
DECLARE v_fn text; v_owner name;
  -- V4: reveal_challenge_service_wrapper → reveal_case_service_wrapper
  v_fns text[] := ARRAY[
    'reserve_upload_session','activate_upload_session','resolve_upload_session',
    'advance_upload_session_processing','check_upload_session_lease','advance_upload_session_sanitized',
    'finalize_upload_session','fail_upload_session','quiesce_upload_sessions_for_deletion',
    'get_upload_capability_expiry','get_all_upload_session_paths_for_deletion','claim_cleanup_sessions',
    'mark_session_cleaned','mark_original_path_post_expiry_cleaned','get_complete_sessions_pending_expiry_cleanup',
    'get_superseded_media_to_clean','mark_superseded_media_cleaned','get_media_storage_key',
    'reveal_case_service_wrapper',
    'prepare_account_deletion_wrapper','get_deletion_storage_keys',
    'record_deletion_failure_wrapper','mark_auth_deleted_wrapper','mark_storage_cleaned_wrapper',
    'claim_deletion_recovery_records','complete_deletion_recovery','fail_deletion_recovery'
  ];
BEGIN
  FOREACH v_fn IN ARRAY v_fns LOOP
    SELECT r.rolname INTO v_owner FROM pg_proc p
    JOIN pg_namespace n ON n.oid=p.pronamespace
    JOIN pg_roles r ON r.oid=p.proowner
    WHERE n.nspname='public' AND p.proname=v_fn LIMIT 1;
    PERFORM test_helpers.assert(
      v_owner='forkensics_executor',
      '17.4: public.' || v_fn || ' owned by forkensics_executor (got: ' || COALESCE(v_owner,'NULL') || ')');
  END LOOP;
END;
$$;

DO $$
BEGIN
  PERFORM test_helpers.assert(
    NOT EXISTS(SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
               WHERE n.nspname='private'
                 AND c.relname IN ('upload_sessions','deletion_recovery_claims')
                 AND c.relrowsecurity=true),
    '17.5: private tables have no RLS (not accessible through PostgREST)');
END;
$$;


-- =============================================================================
\echo ''
\echo '============================================================='
\echo 'All V4-compatible V2 regression tests passed. Rolling back test data.'
\echo '============================================================='

ROLLBACK;
