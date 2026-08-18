-- test_helpers_bootstrap.sql
-- Creates test_helpers schema and functions idempotently on a clean V1–V4 migrated database.
-- Not wrapped in a transaction — helper objects persist after execution.

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

-- make_user: auth.users + active/onboarded profile + profile_suspensions row.
-- V4 requires is_active=true, onboarding_complete=true, and a profile_suspensions row.
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

-- make_group: creates a group via public.create_group with JWT context established,
-- so create_group can record the owner correctly.
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

-- make_bare_draft_case: sets JWT context, then INSERT DEFAULT VALUES so the
-- case_create_fields trigger reads private.auth_uid() for poster_id.
-- Also inserts the required case_secrets row.
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

-- make_scenario: composes make_user + make_group + make_bare_draft_case.
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

GRANT USAGE ON SCHEMA test_helpers TO authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA test_helpers TO authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA test_helpers TO forkensics_executor;
