-- =============================================================================
-- Forkensics — V1 Migration Acceptance Tests (Rebuilt)
-- Addresses all 13 issues from Codex/GPT review
--
-- Execution (run after applying the migration to a fresh local DB):
--   psql "$DATABASE_URL" \
--        --set ON_ERROR_STOP=on \
--        -f 08_Migration/tests/V1_acceptance_tests.sql
--
-- The migration must already be committed in the same DB before running this.
-- The entire test suite runs inside a single BEGIN/ROLLBACK; no test data
-- persists after this file completes.
--
-- Design rules (GPT review):
--   ✓ \set ON_ERROR_STOP on — psql halts immediately on any statement error
--   ✓ All tests inside BEGIN … ROLLBACK
--   ✓ No ROLLBACK inside DO blocks
--   ✓ Every negative test: complete valid fixture, vary only the tested field,
--     require exact SQLSTATE or constraint; re-raise unexpected exceptions
--   ✓ Permission tests assert has_function_privilege() directly; denied calls
--     require SQLSTATE 42501
--   ✓ Fixtures built through lifecycle functions (triggers still fire)
--   ✓ Scoring tests call reveal_challenge() and inspect persisted tables
-- =============================================================================

\set ON_ERROR_STOP on

BEGIN;

-- ============================================================
-- SECTION 0: FIXTURE HELPERS
-- Schema created FIRST (GPT issue #1), then functions inside it.
-- ============================================================

CREATE SCHEMA IF NOT EXISTS test_helpers;

-- -------------------------------------------------------
-- PREFLIGHT: Verify Section 9B revokes are in effect.
-- These assertions must run BEFORE the re-grants below.
-- They prove that the migration left postgres without
-- membership in the trusted roles at runtime, and that
-- those roles have no inappropriate elevated privileges.
-- -------------------------------------------------------
-- NOTE: test_helpers.assert is not yet defined at this point.
-- Use RAISE EXCEPTION directly.
--
-- IMPORTANT: In local Supabase dev, supabase_admin automatically grants
-- postgres into every user-created role (grantor = supabase_admin). Our
-- migration's REVOKE only removes grants made BY postgres, so supabase_admin's
-- grant survives. This is a local dev artifact that does not exist on production
-- Supabase (where supabase_admin does not auto-grant postgres into user roles).
--
-- We therefore only verify that OUR migration's temporary grants (grantor=postgres)
-- have been properly revoked — not the supabase_admin local-dev grant.
DO $$
BEGIN
  -- Section 9B + Section 12 should have revoked any grant made BY postgres.
  IF EXISTS (
    SELECT 1 FROM pg_auth_members am
    JOIN pg_roles r ON r.oid = am.roleid
    JOIN pg_roles m ON m.oid = am.member
    JOIN pg_roles g ON g.oid = am.grantor
    WHERE r.rolname = 'forkensics_executor'
      AND m.rolname = 'postgres'
      AND g.rolname = 'postgres'
  ) THEN
    RAISE EXCEPTION 'PREFLIGHT FAILED: migration left forkensics_executor→postgres grant with grantor=postgres (Section 9B or Section 12 revoke missing)';
  END IF;

  IF EXISTS (
    SELECT 1 FROM pg_auth_members am
    JOIN pg_roles r ON r.oid = am.roleid
    JOIN pg_roles m ON m.oid = am.member
    JOIN pg_roles g ON g.oid = am.grantor
    WHERE r.rolname = 'forkensics_rls_helper'
      AND m.rolname = 'postgres'
      AND g.rolname = 'postgres'
  ) THEN
    RAISE EXCEPTION 'PREFLIGHT FAILED: migration left forkensics_rls_helper→postgres grant with grantor=postgres (Section 9B or Section 12 revoke missing)';
  END IF;

  -- trusted roles must not have rolcreatedb or rolcreaterole
  IF EXISTS (
    SELECT 1 FROM pg_roles
    WHERE rolname IN ('forkensics_executor','forkensics_rls_helper')
      AND (rolcreatedb OR rolcreaterole)
  ) THEN
    RAISE EXCEPTION 'PREFLIGHT FAILED: trusted roles have CREATE-DB or CREATE-ROLE privilege';
  END IF;

  RAISE NOTICE 'PREFLIGHT PASSED: migration grants revoked (grantor=postgres). Note: supabase_admin local-dev auto-grant is expected and acceptable.';
END;
$$;

-- Re-grant role memberships revoked in migration Section 9B.
-- These are needed for SET LOCAL ROLE forkensics_executor blocks throughout tests.
-- Safe: this entire file runs inside BEGIN...ROLLBACK, so the grants are rolled back.
GRANT forkensics_executor   TO postgres;
GRANT forkensics_rls_helper TO postgres;

-- authenticated role needs USAGE + EXECUTE so that helper calls inside
-- SET LOCAL ROLE authenticated blocks (e.g. clear_auth_uid) don't fail with
-- "permission denied for schema test_helpers". This GRANT is inside the
-- rolled-back transaction so it has no effect on any real database state.
GRANT USAGE ON SCHEMA test_helpers TO authenticated;
-- forkensics_executor needs CREATE on test_helpers to own expire_challenge (PG 16+ enforcement)
GRANT CREATE ON SCHEMA test_helpers TO forkensics_executor;

CREATE OR REPLACE FUNCTION test_helpers.set_auth_uid(p_uid uuid)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config(
    'request.jwt.claims',
    json_build_object('sub', p_uid::text, 'role', 'authenticated')::text,
    true
  );
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

-- Create auth.users row + trigger-created profile; return the new UUID.
CREATE OR REPLACE FUNCTION test_helpers.make_user(p_display_name text DEFAULT 'Test Player')
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE v_uid uuid := gen_random_uuid();
BEGIN
  INSERT INTO auth.users (id, email, raw_user_meta_data, created_at, updated_at)
  VALUES (
    v_uid, v_uid || '@test.invalid',
    json_build_object('display_name', p_display_name)::jsonb,
    now(), now()
  );
  -- handle_new_user trigger creates the profile row; finish onboarding manually
  UPDATE public.profiles
  SET display_name = p_display_name, onboarding_complete = true
  WHERE id = v_uid;
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

CREATE OR REPLACE FUNCTION test_helpers.add_member(p_group_id uuid, p_owner_id uuid, p_member_id uuid)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_token text;
BEGIN
  PERFORM test_helpers.set_auth_uid(p_owner_id);
  v_token := public.create_group_invite(p_group_id);
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.set_auth_uid(p_member_id);
  PERFORM public.redeem_group_invite(v_token);
  PERFORM test_helpers.clear_auth_uid();
END;
$$;

CREATE OR REPLACE FUNCTION test_helpers.make_media_object(p_uploader_id uuid)
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE v_mid uuid := gen_random_uuid();
BEGIN
  INSERT INTO public.media_objects (id, uploader_id, mime_type, file_size_bytes, status)
  VALUES (v_mid, p_uploader_id, 'image/jpeg', 100000, 'ready');
  RETURN v_mid;
END;
$$;

-- Build a draft challenge through authenticated INSERT (triggers fire normally).
-- City is optional context stored on challenges.public_city_display (not a secret).
CREATE OR REPLACE FUNCTION test_helpers.make_draft_challenge(
  p_poster_id  uuid,
  p_group_id   uuid,
  p_dish       text DEFAULT 'Ramen',
  p_restaurant text DEFAULT 'Ichiran',
  p_city       text DEFAULT NULL
)
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE
  v_cid uuid;
  v_mid uuid;
BEGIN
  v_mid := test_helpers.make_media_object(p_poster_id);
  PERFORM test_helpers.set_auth_uid(p_poster_id);

  -- City goes on the challenge row directly; trigger normalizes (trim, whitespace→NULL)
  INSERT INTO public.challenges (group_id, media_object_id, public_city_display)
  VALUES (p_group_id, v_mid, p_city)
  RETURNING id INTO v_cid;

  INSERT INTO public.challenge_secrets (
    challenge_id,
    display_dish,        canonical_dish,
    display_restaurant,  canonical_restaurant
  )
  VALUES (
    v_cid,
    p_dish,       lower(regexp_replace(regexp_replace(p_dish,       '[^a-z0-9 ]','','gi'),'\s+',' ','g')),
    p_restaurant, lower(regexp_replace(regexp_replace(p_restaurant, '[^a-z0-9 ]','','gi'),'\s+',' ','g'))
  );

  PERFORM test_helpers.clear_auth_uid();
  RETURN v_cid;
END;
$$;

CREATE OR REPLACE FUNCTION test_helpers.activate(p_poster_id uuid, p_challenge_id uuid)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM test_helpers.set_auth_uid(p_poster_id);
  PERFORM public.activate_challenge(p_challenge_id);
  PERFORM test_helpers.clear_auth_uid();
END;
$$;

-- Push deadline into the past so reveal/lock may proceed.
-- Must run as forkensics_executor so the authority-field trigger bypasses.
-- SECURITY DEFINER + OWNER TO forkensics_executor achieves this.
CREATE OR REPLACE FUNCTION test_helpers.expire_challenge(p_challenge_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  UPDATE public.challenges
  SET deadline_at = now() - interval '1 second'
  WHERE id = p_challenge_id;
END;
$$;
-- Trigger sees current_user = 'forkensics_executor' and bypasses protect_challenge_authority_fields
ALTER FUNCTION test_helpers.expire_challenge(uuid) OWNER TO forkensics_executor;

CREATE OR REPLACE FUNCTION test_helpers.reveal(p_poster_id uuid, p_challenge_id uuid)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM test_helpers.set_auth_uid(p_poster_id);
  PERFORM public.reveal_challenge(p_challenge_id);
  PERFORM test_helpers.clear_auth_uid();
END;
$$;

CREATE OR REPLACE FUNCTION test_helpers.make_guess(
  p_player_id    uuid,
  p_challenge_id uuid,
  p_race         text,
  p_dish         text DEFAULT NULL,
  p_restaurant   text DEFAULT NULL
)
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE v_id uuid;
BEGIN
  PERFORM test_helpers.set_auth_uid(p_player_id);
  INSERT INTO public.guess_attempts (challenge_id, player_id, race, dish_guess, restaurant_guess)
  VALUES (p_challenge_id, p_player_id, p_race, p_dish, p_restaurant)
  RETURNING id INTO v_id;
  PERFORM test_helpers.clear_auth_uid();
  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION test_helpers.assert(p_condition boolean, p_message text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF NOT p_condition THEN
    RAISE EXCEPTION 'ASSERTION FAILED: %', p_message;
  END IF;
  RAISE NOTICE 'PASS: %', p_message;
END;
$$;

-- Grant EXECUTE on all test helpers to authenticated so that role-switch blocks
-- (where the caller has done SET LOCAL ROLE authenticated) can still call helpers.
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA test_helpers TO authenticated;

\echo ''
\echo '============================================================='
\echo 'Forkensics V1 Acceptance Tests'
\echo '============================================================='

-- =============================================================================
-- GROUP 1: SCHEMA STRUCTURE
-- =============================================================================
\echo ''
\echo '--- GROUP 1: Schema Structure ---'

DO $$
DECLARE
  v_tables text[] := ARRAY[
    'public.profiles','public.rules_versions','public.media_objects',
    'public.groups','public.group_members','public.group_invites',
    'public.challenges','public.challenge_secrets','public.challenge_answer_aliases',
    'public.eligible_participants','public.exclusion_events','public.clues',
    'public.guess_attempts','public.correction_events','public.score_runs',
    'public.guess_judgments','public.score_events','public.comments','public.reactions',
    'private.media_storage_keys','private.profile_archive','private.deletion_log'
  ];
  v_t text; v_schema text; v_table text;
BEGIN
  FOREACH v_t IN ARRAY v_tables LOOP
    v_schema := split_part(v_t, '.', 1);
    v_table  := split_part(v_t, '.', 2);
    IF NOT EXISTS (
      SELECT 1 FROM information_schema.tables
      WHERE table_schema = v_schema AND table_name = v_table
    ) THEN RAISE EXCEPTION 'FAIL 1.1: table % missing', v_t; END IF;
  END LOOP;
  RAISE NOTICE 'PASS 1.1: All 22 tables present';
END;
$$;

DO $$
DECLARE v_table text;
  v_tables text[] := ARRAY[
    'profiles','rules_versions','media_objects','groups','group_members',
    'group_invites','challenges','challenge_secrets','challenge_answer_aliases',
    'eligible_participants','exclusion_events','clues','guess_attempts',
    'correction_events','score_runs','guess_judgments','score_events','comments','reactions'
  ];
BEGIN
  FOREACH v_table IN ARRAY v_tables LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_class
      WHERE relnamespace='public'::regnamespace AND relname=v_table AND relrowsecurity=true)
    THEN RAISE EXCEPTION 'FAIL 1.2: RLS not enabled on public.%', v_table; END IF;
  END LOOP;
  RAISE NOTICE 'PASS 1.2: RLS enabled on all 19 public tables';
END;
$$;

DO $$
BEGIN
  PERFORM test_helpers.assert(
    EXISTS(SELECT 1 FROM pg_sequences WHERE schemaname='public' AND sequencename='guess_receipt_seq'
           AND start_value=1 AND increment_by=1 AND cycle=false),
    '1.3: guess_receipt_seq (start=1, inc=1, no cycle)'
  );
END;
$$;

DO $$
BEGIN
  PERFORM test_helpers.assert(
    EXISTS(SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
           WHERE n.nspname='public' AND c.relname='current_score_events' AND c.relkind='v'
             AND c.reloptions::text LIKE '%security_invoker=true%'),
    '1.4: current_score_events has security_invoker=true'
  );
END;
$$;

-- =============================================================================
-- GROUP 2: ROLE MODEL  (GPT issue #10)
-- =============================================================================
\echo ''
\echo '--- GROUP 2: Role Model ---'

DO $$
BEGIN
  PERFORM test_helpers.assert(NOT(SELECT rolcanlogin FROM pg_roles WHERE rolname='forkensics_executor'),
    '2.1a: forkensics_executor is NOLOGIN');
  PERFORM test_helpers.assert(NOT(SELECT rolcanlogin FROM pg_roles WHERE rolname='forkensics_rls_helper'),
    '2.1b: forkensics_rls_helper is NOLOGIN');
  PERFORM test_helpers.assert((SELECT rolbypassrls FROM pg_roles WHERE rolname='forkensics_executor'),
    '2.2a: forkensics_executor has BYPASSRLS');
  PERFORM test_helpers.assert((SELECT rolbypassrls FROM pg_roles WHERE rolname='forkensics_rls_helper'),
    '2.2b: forkensics_rls_helper has BYPASSRLS');
  PERFORM test_helpers.assert(
    has_table_privilege('forkensics_rls_helper','public.profiles','SELECT'),
    '2.3a: forkensics_rls_helper can SELECT profiles');
  PERFORM test_helpers.assert(
    NOT has_table_privilege('forkensics_rls_helper','public.profiles','INSERT'),
    '2.3b: forkensics_rls_helper cannot INSERT profiles');
  PERFORM test_helpers.assert(
    NOT has_sequence_privilege('authenticated','public.guess_receipt_seq','USAGE'),
    '2.4: authenticated has no USAGE on guess_receipt_seq');
END;
$$;

-- authenticated is not a member of forkensics_executor (GPT issue #10)
-- We check role graph membership directly rather than attempting SET ROLE, because
-- the test session runs as postgres (superuser + executor member for OWNER TO grants)
-- and SET LOCAL ROLE checks session-user membership, not the intermediate role.
DO $$
BEGIN
  PERFORM test_helpers.assert(
    NOT pg_has_role('authenticated', 'forkensics_executor', 'member'),
    '2.5: authenticated is not a member of forkensics_executor'
  );
  PERFORM test_helpers.assert(
    NOT pg_has_role('authenticated', 'forkensics_rls_helper', 'member'),
    '2.5b: authenticated is not a member of forkensics_rls_helper'
  );
END;
$$;

-- =============================================================================
-- GROUP 3: CONSTRAINT ENFORCEMENT  (GPT issue #4 — proper fixtures, exact SQLSTATE)
-- =============================================================================
\echo ''
\echo '--- GROUP 3: Constraint Enforcement ---'

-- 3.1  Duration constraints
DO $$
DECLARE
  v_poster uuid; v_group uuid; v_mid uuid; v_caught boolean;
BEGIN
  v_poster := test_helpers.make_user('DurPoster');
  v_group  := test_helpers.make_group(v_poster);
  v_mid    := test_helpers.make_media_object(v_poster);

  -- Too short
  v_caught := false;
  BEGIN
    PERFORM test_helpers.set_auth_uid(v_poster);
    INSERT INTO public.challenges (group_id, media_object_id, duration_seconds) VALUES (v_group, v_mid, 1800);
  EXCEPTION WHEN check_violation THEN v_caught := true;
  WHEN OTHERS THEN PERFORM test_helpers.clear_auth_uid();
    RAISE EXCEPTION 'FAIL 3.1a: unexpected SQLSTATE % — %', SQLSTATE, SQLERRM;
  END;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_caught, '3.1a: duration 1800 < 3600 rejected (check_violation)');

  -- Non-whole-hour
  v_caught := false;
  BEGIN
    PERFORM test_helpers.set_auth_uid(v_poster);
    INSERT INTO public.challenges (group_id, media_object_id, duration_seconds) VALUES (v_group, v_mid, 5400);
  EXCEPTION WHEN check_violation THEN v_caught := true;
  WHEN OTHERS THEN PERFORM test_helpers.clear_auth_uid();
    RAISE EXCEPTION 'FAIL 3.1b: unexpected SQLSTATE % — %', SQLSTATE, SQLERRM;
  END;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_caught, '3.1b: duration 5400 (non-whole-hour) rejected');

  -- Too long (25 h = 90000 s > 24 h max)
  v_caught := false;
  BEGIN
    PERFORM test_helpers.set_auth_uid(v_poster);
    INSERT INTO public.challenges (group_id, media_object_id, duration_seconds) VALUES (v_group, v_mid, 90000);
  EXCEPTION WHEN check_violation THEN v_caught := true;
  WHEN OTHERS THEN PERFORM test_helpers.clear_auth_uid();
    RAISE EXCEPTION 'FAIL 3.1c: unexpected SQLSTATE % — %', SQLSTATE, SQLERRM;
  END;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_caught, '3.1c: duration 90000 (25 h) > 86400 max rejected');

  -- Exactly at max (24 h = 86400 s) must succeed
  PERFORM test_helpers.set_auth_uid(v_poster);
  INSERT INTO public.challenges (group_id, media_object_id, duration_seconds) VALUES (v_group, v_mid, 86400);
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(true, '3.1d: duration 86400 (24 h) accepted');
END;
$$;

-- 3.2  Story length > 2000 chars
DO $$
DECLARE
  v_poster uuid; v_player uuid; v_group uuid; v_cid uuid; v_caught boolean := false;
BEGIN
  v_poster := test_helpers.make_user('StoryPoster');
  v_player := test_helpers.make_user('StoryPlayer');
  v_group  := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_player);
  v_cid := test_helpers.make_draft_challenge(v_poster, v_group);
  BEGIN
    PERFORM test_helpers.set_auth_uid(v_poster);
    UPDATE public.challenge_secrets SET story = repeat('x',2001) WHERE challenge_id = v_cid;
  EXCEPTION WHEN check_violation THEN v_caught := true;
  WHEN OTHERS THEN PERFORM test_helpers.clear_auth_uid();
    RAISE EXCEPTION 'FAIL 3.2: unexpected SQLSTATE % — %', SQLSTATE, SQLERRM;
  END;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_caught, '3.2: story > 2000 chars rejected (check_violation)');
END;
$$;

-- 3.3  Exclusion: invalid reason rejected
DO $$
DECLARE
  v_poster uuid; v_member uuid; v_group uuid; v_cid uuid; v_caught boolean := false;
BEGIN
  v_poster := test_helpers.make_user('ExclConsPoster');
  v_member := test_helpers.make_user('ExclConsMember');
  v_group  := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_member);
  v_cid := test_helpers.make_draft_challenge(v_poster, v_group);
  PERFORM test_helpers.activate(v_poster, v_cid);
  BEGIN
    PERFORM test_helpers.set_auth_uid(v_member);
    INSERT INTO public.exclusion_events (challenge_id, player_id, reason, excluded_by)
    VALUES (v_cid, v_member, 'banished', v_member);
  EXCEPTION
    WHEN check_violation THEN v_caught := true;   -- CHECK constraint (if reached)
    WHEN SQLSTATE 'P0001' THEN v_caught := true;  -- BEFORE trigger fires first
  WHEN OTHERS THEN PERFORM test_helpers.clear_auth_uid();
    RAISE EXCEPTION 'FAIL 3.3: unexpected SQLSTATE % — %', SQLSTATE, SQLERRM;
  END;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_caught, '3.3: invalid exclusion reason rejected');
END;
$$;

-- 3.4  guess_attempts: what race with restaurant_guess rejected
DO $$
DECLARE
  v_poster uuid; v_player uuid; v_group uuid; v_cid uuid; v_caught boolean := false;
BEGIN
  v_poster := test_helpers.make_user('GuessRacePoster');
  v_player := test_helpers.make_user('GuessRacePlayer');
  v_group  := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_player);
  v_cid := test_helpers.make_draft_challenge(v_poster, v_group);
  PERFORM test_helpers.activate(v_poster, v_cid);
  BEGIN
    PERFORM test_helpers.set_auth_uid(v_player);
    INSERT INTO public.guess_attempts (challenge_id, player_id, race, dish_guess, restaurant_guess)
    VALUES (v_cid, v_player, 'what', 'Ramen', 'Ichiran');
  EXCEPTION WHEN check_violation THEN v_caught := true;
  WHEN OTHERS THEN PERFORM test_helpers.clear_auth_uid();
    RAISE EXCEPTION 'FAIL 3.4: unexpected SQLSTATE % — %', SQLSTATE, SQLERRM;
  END;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_caught, '3.4: what-race guess with restaurant_guess rejected');
END;
$$;

-- =============================================================================
-- GROUP 4: NORMALIZATION
-- =============================================================================
\echo ''
\echo '--- GROUP 4: Normalization ---'

DO $$
DECLARE v text;
BEGIN
  v := private.normalize_answer('  Côte d''Azur!! ');
  PERFORM test_helpers.assert(v = 'cte dazur', '4.1: normalize strips punctuation/accents; got: '||COALESCE(v,'NULL'));
  v := private.normalize_answer('No. 7   Ramen');
  PERFORM test_helpers.assert(v = 'no 7 ramen', '4.2: numbers preserved, spaces collapsed; got: '||COALESCE(v,'NULL'));
  v := private.normalize_answer('');
  PERFORM test_helpers.assert(v = '', '4.3: empty string → empty string; got: '||COALESCE(v,'NULL'));
END;
$$;

-- =============================================================================
-- GROUP 5: GUARD TRIGGERS  (GPT issues #3, #5, #6 — named UUIDs, real assertions)
-- =============================================================================
\echo ''
\echo '--- GROUP 5: Guard Triggers ---'

-- 5.1  challenge_create_fields overwrites poster_id with auth.uid()
DO $$
DECLARE v_poster uuid; v_group uuid; v_mid uuid; v_cid uuid; v_actual uuid;
BEGIN
  v_poster := test_helpers.make_user('TrigPoster');
  v_group  := test_helpers.make_group(v_poster);
  v_mid    := test_helpers.make_media_object(v_poster);
  PERFORM test_helpers.set_auth_uid(v_poster);
  INSERT INTO public.challenges (group_id, media_object_id) VALUES (v_group, v_mid) RETURNING id INTO v_cid;
  PERFORM test_helpers.clear_auth_uid();
  SELECT poster_id INTO v_actual FROM public.challenges WHERE id = v_cid;
  PERFORM test_helpers.assert(v_actual = v_poster, '5.1: poster_id overwritten with auth.uid()');
END;
$$;

-- 5.2  state forced to 'draft' on INSERT
DO $$
DECLARE v_poster uuid; v_group uuid; v_mid uuid; v_cid uuid; v_state text;
BEGIN
  v_poster := test_helpers.make_user('StatePoster');
  v_group  := test_helpers.make_group(v_poster);
  v_mid    := test_helpers.make_media_object(v_poster);
  PERFORM test_helpers.set_auth_uid(v_poster);
  INSERT INTO public.challenges (group_id, media_object_id) VALUES (v_group, v_mid) RETURNING id INTO v_cid;
  PERFORM test_helpers.clear_auth_uid();
  SELECT state INTO v_state FROM public.challenges WHERE id = v_cid;
  PERFORM test_helpers.assert(v_state = 'draft', '5.2: new challenge state forced to draft');
END;
$$;

-- 5.3  authenticated cannot directly SET state  (GPT issue #5 — targeted UUID)
DO $$
DECLARE v_poster uuid; v_group uuid; v_cid uuid; v_caught boolean := false;
BEGIN
  v_poster := test_helpers.make_user('AuthFieldPoster');
  v_group  := test_helpers.make_group(v_poster);
  v_cid    := test_helpers.make_draft_challenge(v_poster, v_group);
  BEGIN
    PERFORM test_helpers.set_auth_uid(v_poster);
    UPDATE public.challenges SET state = 'active' WHERE id = v_cid;
  EXCEPTION
    WHEN raise_exception        THEN v_caught := true;  -- trigger fires (if col-grant exists)
    WHEN insufficient_privilege THEN v_caught := true;  -- col-level grant blocks it first
  WHEN OTHERS THEN PERFORM test_helpers.clear_auth_uid();
    RAISE EXCEPTION 'FAIL 5.3: unexpected SQLSTATE % — %', SQLSTATE, SQLERRM;
  END;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_caught, '5.3: authenticated cannot directly set challenge state');
END;
$$;

-- 5.4  public_city_display: editable in draft, immutable after activation
DO $$
DECLARE
  v_poster uuid; v_player uuid; v_group uuid; v_cid uuid;
  v_display text;
BEGIN
  v_poster := test_helpers.make_user('CityDispPoster');
  v_player := test_helpers.make_user('CityDispPlayer');
  v_group  := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_player);
  v_cid := test_helpers.make_draft_challenge(v_poster, v_group);

  -- 5.4a: poster can set city in draft
  PERFORM test_helpers.set_auth_uid(v_poster);
  UPDATE public.challenges SET public_city_display = 'Austin, Texas' WHERE id = v_cid;
  PERFORM test_helpers.clear_auth_uid();
  SELECT public_city_display INTO v_display FROM public.challenges WHERE id = v_cid;
  PERFORM test_helpers.assert(v_display = 'Austin, Texas', '5.4a: poster can set public_city_display in draft');

  -- 5.4b: public_city_display is immutable after activation
  -- Enforcement: challenges_update_poster RLS requires state='draft'; after activation
  -- the UPDATE silently matches 0 rows (no trigger fires, no exception raised).
  -- We verify immutability by checking the value is unchanged, not by catching an exception.
  PERFORM test_helpers.activate(v_poster, v_cid);
  PERFORM test_helpers.set_auth_uid(v_poster);
  UPDATE public.challenges SET public_city_display = 'Dallas, Texas' WHERE id = v_cid;
  PERFORM test_helpers.clear_auth_uid();
  SELECT public_city_display INTO v_display FROM public.challenges WHERE id = v_cid;
  PERFORM test_helpers.assert(v_display = 'Austin, Texas', '5.4b: public_city_display immutable after activation (value unchanged)');
END;
$$;

-- 5.5  challenge_secrets locked after first guess (GPT issue #8 — real fixture)
DO $$
DECLARE v_poster uuid; v_player uuid; v_group uuid; v_cid uuid; v_caught boolean := false;
BEGIN
  v_poster := test_helpers.make_user('SecretLockPoster');
  v_player := test_helpers.make_user('SecretLockPlayer');
  v_group  := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_player);
  v_cid := test_helpers.make_draft_challenge(v_poster, v_group);
  PERFORM test_helpers.activate(v_poster, v_cid);
  PERFORM test_helpers.make_guess(v_player, v_cid, 'what', 'Ramen');
  BEGIN
    PERFORM test_helpers.set_auth_uid(v_poster);
    UPDATE public.challenge_secrets SET display_dish = 'Soba' WHERE challenge_id = v_cid;
  EXCEPTION WHEN raise_exception THEN v_caught := true;
  WHEN OTHERS THEN PERFORM test_helpers.clear_auth_uid();
    RAISE EXCEPTION 'FAIL 5.5: unexpected SQLSTATE % — %', SQLSTATE, SQLERRM;
  END;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_caught, '5.5: challenge_secrets locked after first guess');
END;
$$;

-- 5.6  Guess deadline enforcement: guess after deadline_at rejected
DO $$
DECLARE v_poster uuid; v_player uuid; v_group uuid; v_cid uuid; v_caught boolean := false;
BEGIN
  v_poster := test_helpers.make_user('DlPoster');
  v_player := test_helpers.make_user('DlPlayer');
  v_group  := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_player);
  v_cid := test_helpers.make_draft_challenge(v_poster, v_group);
  PERFORM test_helpers.activate(v_poster, v_cid);
  PERFORM test_helpers.expire_challenge(v_cid);
  BEGIN
    PERFORM test_helpers.set_auth_uid(v_player);
    INSERT INTO public.guess_attempts (challenge_id, player_id, race, dish_guess)
    VALUES (v_cid, v_player, 'what', 'Ramen');
  EXCEPTION WHEN raise_exception THEN v_caught := true;
  WHEN OTHERS THEN PERFORM test_helpers.clear_auth_uid();
    RAISE EXCEPTION 'FAIL 5.6: unexpected SQLSTATE % — %', SQLSTATE, SQLERRM;
  END;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_caught, '5.6: guess after deadline rejected by receipt trigger');
END;
$$;

-- 5.7  has_first_guess set to true on first accepted guess
DO $$
DECLARE v_poster uuid; v_player uuid; v_group uuid; v_cid uuid; v_hfg boolean;
BEGIN
  v_poster := test_helpers.make_user('HFGPoster');
  v_player := test_helpers.make_user('HFGPlayer');
  v_group  := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_player);
  v_cid := test_helpers.make_draft_challenge(v_poster, v_group);
  PERFORM test_helpers.activate(v_poster, v_cid);

  SELECT has_first_guess INTO v_hfg FROM public.challenge_secrets WHERE challenge_id = v_cid;
  PERFORM test_helpers.assert(NOT v_hfg, '5.7a: has_first_guess = false before any guess');

  PERFORM test_helpers.make_guess(v_player, v_cid, 'what', 'Ramen');

  SELECT has_first_guess INTO v_hfg FROM public.challenge_secrets WHERE challenge_id = v_cid;
  PERFORM test_helpers.assert(v_hfg, '5.7b: has_first_guess = true after first accepted guess');
END;
$$;

-- 5.8  Client-supplied received_at and receipt_sequence are overwritten
DO $$
DECLARE v_poster uuid; v_player uuid; v_group uuid; v_cid uuid;
        v_seq bigint; v_recv timestamptz;
BEGIN
  v_poster := test_helpers.make_user('OWPoster');
  v_player := test_helpers.make_user('OWPlayer');
  v_group  := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_player);
  v_cid := test_helpers.make_draft_challenge(v_poster, v_group);
  PERFORM test_helpers.activate(v_poster, v_cid);
  PERFORM test_helpers.set_auth_uid(v_player);
  INSERT INTO public.guess_attempts
    (challenge_id, player_id, race, dish_guess, received_at, receipt_sequence)
  VALUES (v_cid, v_player, 'what', 'Ramen', '2000-01-01'::timestamptz, -999)
  RETURNING receipt_sequence, received_at INTO v_seq, v_recv;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_seq > 0,                            '5.8a: receipt_sequence overwritten (>0)');
  PERFORM test_helpers.assert(v_recv > '2001-01-01'::timestamptz,   '5.8b: received_at overwritten to now()');
END;
$$;

-- 5.9  rules_versions are immutable (UPDATE blocked)
DO $$
DECLARE v_caught boolean := false;
BEGIN
  BEGIN
    UPDATE public.rules_versions SET description = 'hacked' WHERE version_tag = 'v1';
  EXCEPTION WHEN raise_exception THEN v_caught := true;
  WHEN OTHERS THEN RAISE EXCEPTION 'FAIL 5.9: unexpected SQLSTATE % — %', SQLSTATE, SQLERRM;
  END;
  PERFORM test_helpers.assert(v_caught, '5.9: rules_versions UPDATE blocked by trigger');
END;
$$;

-- =============================================================================
-- GROUP 6: PRIVILEGE MODEL  (GPT issue #7 — has_function_privilege + SQLSTATE 42501)
-- =============================================================================
\echo ''
\echo '--- GROUP 6: Privilege Model ---'

DO $$
BEGIN
  PERFORM test_helpers.assert(
    NOT has_function_privilege('authenticated','public.lock_challenge(uuid)','EXECUTE'),
    '6.1: authenticated has NO EXECUTE on lock_challenge');
  PERFORM test_helpers.assert(
    has_function_privilege('authenticated','public.reveal_challenge(uuid)','EXECUTE'),
    '6.2: authenticated has EXECUTE on reveal_challenge');
  -- service_role uses private.reveal_challenge_service (Step 19); public.reveal_challenge is for authenticated only
  PERFORM test_helpers.assert(
    NOT has_function_privilege('service_role','public.reveal_challenge(uuid)','EXECUTE'),
    '6.3: service_role has NO EXECUTE on public.reveal_challenge (uses private entry point)');
  PERFORM test_helpers.assert(
    has_function_privilege('service_role','private.reveal_challenge_service(uuid)','EXECUTE'),
    '6.3b: service_role has EXECUTE on private.reveal_challenge_service');
  PERFORM test_helpers.assert(
    has_function_privilege('service_role','public.lock_challenge(uuid)','EXECUTE'),
    '6.4: service_role has EXECUTE on lock_challenge');
  PERFORM test_helpers.assert(
    NOT has_function_privilege('authenticated','private.prepare_account_deletion(uuid)','EXECUTE'),
    '6.5: authenticated has NO EXECUTE on prepare_account_deletion');
  PERFORM test_helpers.assert(
    NOT has_table_privilege('anon','public.profiles','SELECT'),
    '6.6: anon has no SELECT on profiles');
  PERFORM test_helpers.assert(
    has_column_privilege('authenticated','public.challenges','public_city_display','UPDATE'),
    '6.7: authenticated has column UPDATE on public_city_display (city is poster-editable context)');
END;
$$;

-- Confirm 42501 is raised when authenticated calls lock_challenge  (GPT issue #7)
DO $$
DECLARE v_caught boolean := false; v_sqlstate text;
BEGIN
  BEGIN
    EXECUTE 'SET LOCAL ROLE authenticated';
    PERFORM public.lock_challenge(gen_random_uuid());
  EXCEPTION
    WHEN insufficient_privilege THEN v_caught := true; v_sqlstate := SQLSTATE;
    WHEN OTHERS THEN RESET ROLE;
      RAISE EXCEPTION 'FAIL 6.8: expected 42501 but got SQLSTATE % — %', SQLSTATE, SQLERRM;
  END;
  RESET ROLE;
  PERFORM test_helpers.assert(v_caught AND v_sqlstate = '42501',
    '6.8: lock_challenge raises 42501 for authenticated');
END;
$$;

-- =============================================================================
-- GROUP 7: CHALLENGE LIFECYCLE  (GPT issue #11)
-- =============================================================================
\echo ''
\echo '--- GROUP 7: Challenge Lifecycle ---'

-- 7.1  Full path: draft → activate → guess → expire → reveal
DO $$
DECLARE
  v_poster uuid; v_p1 uuid; v_p2 uuid; v_group uuid; v_cid uuid;
  v_state text; v_ep_count integer; v_caught boolean;
BEGIN
  v_poster := test_helpers.make_user('LifecyclePoster');
  v_p1     := test_helpers.make_user('LifecycleP1');
  v_p2     := test_helpers.make_user('LifecycleP2');
  v_group  := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_p1);
  PERFORM test_helpers.add_member(v_group, v_poster, v_p2);
  v_cid := test_helpers.make_draft_challenge(v_poster, v_group, 'Ramen', 'Ichiran', 'Tokyo');

  SELECT state INTO v_state FROM public.challenges WHERE id = v_cid;
  PERFORM test_helpers.assert(v_state = 'draft', '7.1a: challenge starts in draft');

  PERFORM test_helpers.activate(v_poster, v_cid);
  SELECT state INTO v_state FROM public.challenges WHERE id = v_cid;
  PERFORM test_helpers.assert(v_state = 'active', '7.1b: activate → active');

  SELECT COUNT(*) INTO v_ep_count FROM public.eligible_participants WHERE challenge_id = v_cid;
  PERFORM test_helpers.assert(v_ep_count = 2, '7.1c: 2 EPs snapshotted (not poster)');

  -- Poster cannot reveal before deadline
  v_caught := false;
  BEGIN
    PERFORM test_helpers.set_auth_uid(v_poster);
    PERFORM public.reveal_challenge(v_cid);
  EXCEPTION WHEN raise_exception THEN v_caught := true;
  WHEN OTHERS THEN PERFORM test_helpers.clear_auth_uid();
    RAISE EXCEPTION 'FAIL 7.1d: unexpected SQLSTATE % — %', SQLSTATE, SQLERRM;
  END;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_caught, '7.1d: poster cannot reveal before deadline');

  PERFORM test_helpers.expire_challenge(v_cid);
  PERFORM test_helpers.reveal(v_poster, v_cid);
  SELECT state INTO v_state FROM public.challenges WHERE id = v_cid;
  PERFORM test_helpers.assert(v_state = 'revealed', '7.1e: reveal → revealed');
END;
$$;

-- 7.2  Service-role lock path: active → locked
DO $$
DECLARE v_poster uuid; v_player uuid; v_group uuid; v_cid uuid; v_state text;
BEGIN
  v_poster := test_helpers.make_user('LockPoster');
  v_player := test_helpers.make_user('LockPlayer');
  v_group  := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_player);
  v_cid := test_helpers.make_draft_challenge(v_poster, v_group);
  PERFORM test_helpers.activate(v_poster, v_cid);
  PERFORM test_helpers.expire_challenge(v_cid);
  PERFORM public.lock_challenge(v_cid);  -- runs as superuser (≥ service_role privileges)
  SELECT state INTO v_state FROM public.challenges WHERE id = v_cid;
  PERFORM test_helpers.assert(v_state = 'locked', '7.2: lock_challenge → locked');
END;
$$;

-- 7.3  lock_challenge rejects un-expired active challenge
DO $$
DECLARE v_poster uuid; v_player uuid; v_group uuid; v_cid uuid; v_caught boolean := false;
BEGIN
  v_poster := test_helpers.make_user('LockEarlyPoster');
  v_player := test_helpers.make_user('LockEarlyPlayer');
  v_group  := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_player);
  v_cid := test_helpers.make_draft_challenge(v_poster, v_group);
  PERFORM test_helpers.activate(v_poster, v_cid);
  -- do NOT expire the challenge
  BEGIN
    PERFORM public.lock_challenge(v_cid);
  EXCEPTION WHEN raise_exception THEN v_caught := true;
  WHEN OTHERS THEN RAISE EXCEPTION 'FAIL 7.3: unexpected SQLSTATE % — %', SQLSTATE, SQLERRM;
  END;
  PERFORM test_helpers.assert(v_caught, '7.3: lock_challenge rejected before deadline');
END;
$$;

-- 7.4  reveal_challenge cannot run twice on same challenge
DO $$
DECLARE v_poster uuid; v_player uuid; v_group uuid; v_cid uuid; v_caught boolean := false;
BEGIN
  v_poster := test_helpers.make_user('DblRevPoster');
  v_player := test_helpers.make_user('DblRevPlayer');
  v_group  := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_player);
  v_cid := test_helpers.make_draft_challenge(v_poster, v_group);
  PERFORM test_helpers.activate(v_poster, v_cid);
  PERFORM test_helpers.expire_challenge(v_cid);
  PERFORM test_helpers.reveal(v_poster, v_cid);
  BEGIN
    PERFORM test_helpers.set_auth_uid(v_poster);
    PERFORM public.reveal_challenge(v_cid);
  EXCEPTION WHEN raise_exception THEN v_caught := true;
  WHEN OTHERS THEN PERFORM test_helpers.clear_auth_uid();
    RAISE EXCEPTION 'FAIL 7.4: unexpected SQLSTATE % — %', SQLSTATE, SQLERRM;
  END;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_caught, '7.4: reveal_challenge cannot run twice');
END;
$$;

-- =============================================================================
-- GROUP 8: SCORING — END-TO-END  (GPT issue #9 — must call reveal_challenge)
-- =============================================================================
\echo ''
\echo '--- GROUP 8: Scoring (End-to-End via reveal_challenge) ---'

-- 8.1  No guess → 0 points  (catches GREATEST(1,NULL)=1 bug)
DO $$
DECLARE v_poster uuid; v_p1 uuid; v_group uuid; v_cid uuid;
        v_what integer; v_where integer;
BEGIN
  v_poster := test_helpers.make_user('Score1Poster');
  v_p1     := test_helpers.make_user('Score1P1');
  v_group  := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_p1);
  v_cid := test_helpers.make_draft_challenge(v_poster, v_group, 'Ramen', 'Ichiran', 'Tokyo');
  PERFORM test_helpers.activate(v_poster, v_cid);
  -- No guesses at all
  PERFORM test_helpers.expire_challenge(v_cid);
  PERFORM test_helpers.reveal(v_poster, v_cid);

  SELECT what_points, where_points INTO v_what, v_where
  FROM public.current_score_events WHERE challenge_id = v_cid AND player_id = v_p1;

  PERFORM test_helpers.assert(v_what  = 0, '8.1a: no guess → what_points = 0 (was '||COALESCE(v_what::text,'NULL')||')');
  PERFORM test_helpers.assert(v_where = 0, '8.1b: no guess → where_points = 0 (was '||COALESCE(v_where::text,'NULL')||')');
END;
$$;

-- 8.2  Incorrect guesses only → 0 points
DO $$
DECLARE v_poster uuid; v_p1 uuid; v_group uuid; v_cid uuid;
        v_what integer; v_where integer;
BEGIN
  v_poster := test_helpers.make_user('Score2Poster');
  v_p1     := test_helpers.make_user('Score2P1');
  v_group  := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_p1);
  v_cid := test_helpers.make_draft_challenge(v_poster, v_group, 'Ramen', 'Ichiran', 'Tokyo');
  PERFORM test_helpers.activate(v_poster, v_cid);
  PERFORM test_helpers.make_guess(v_p1, v_cid, 'what', 'Sushi');
  PERFORM test_helpers.make_guess(v_p1, v_cid, 'where', NULL, 'Nobu');
  PERFORM test_helpers.expire_challenge(v_cid);
  PERFORM test_helpers.reveal(v_poster, v_cid);

  SELECT what_points, where_points INTO v_what, v_where
  FROM public.current_score_events WHERE challenge_id = v_cid AND player_id = v_p1;

  PERFORM test_helpers.assert(v_what  = 0, '8.2a: wrong dish → 0 what points');
  PERFORM test_helpers.assert(v_where = 0, '8.2b: wrong restaurant → 0 where points');
END;
$$;

-- 8.3  Single eligible player, correct answers → 1 point each (eligible_count=1, rank=1)
DO $$
DECLARE v_poster uuid; v_p1 uuid; v_group uuid; v_cid uuid;
        v_what integer; v_where integer; v_wrank integer; v_whrank integer;
BEGIN
  v_poster := test_helpers.make_user('Score3Poster');
  v_p1     := test_helpers.make_user('Score3P1');
  v_group  := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_p1);
  v_cid := test_helpers.make_draft_challenge(v_poster, v_group, 'Ramen', 'Ichiran', 'Tokyo');
  PERFORM test_helpers.activate(v_poster, v_cid);
  PERFORM test_helpers.make_guess(v_p1, v_cid, 'what', 'Ramen');
  PERFORM test_helpers.make_guess(v_p1, v_cid, 'where', NULL, 'Ichiran');
  PERFORM test_helpers.expire_challenge(v_cid);
  PERFORM test_helpers.reveal(v_poster, v_cid);

  SELECT what_points, where_points, what_rank, where_rank
  INTO v_what, v_where, v_wrank, v_whrank
  FROM public.current_score_events WHERE challenge_id = v_cid AND player_id = v_p1;

  -- eligible_count=1, rank=1: 1-1+1=1
  PERFORM test_helpers.assert(v_what   = 1, '8.3a: 1 eligible, correct what → 1 point');
  PERFORM test_helpers.assert(v_where  = 1, '8.3b: 1 eligible, correct where → 1 point');
  PERFORM test_helpers.assert(v_wrank  = 1, '8.3c: what_rank = 1');
  PERFORM test_helpers.assert(v_whrank = 1, '8.3d: where_rank = 1');
END;
$$;

-- 8.4  Two players, correct answers in order → 2 pts first, 1 pt second
DO $$
DECLARE v_poster uuid; v_p1 uuid; v_p2 uuid; v_group uuid; v_cid uuid;
        v_p1_what integer; v_p2_what integer;
BEGIN
  v_poster := test_helpers.make_user('Score4Poster');
  v_p1     := test_helpers.make_user('Score4P1');
  v_p2     := test_helpers.make_user('Score4P2');
  v_group  := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_p1);
  PERFORM test_helpers.add_member(v_group, v_poster, v_p2);
  v_cid := test_helpers.make_draft_challenge(v_poster, v_group, 'Ramen', 'Ichiran', 'Tokyo');
  PERFORM test_helpers.activate(v_poster, v_cid);
  PERFORM test_helpers.make_guess(v_p1, v_cid, 'what', 'Ramen');  -- first
  PERFORM test_helpers.make_guess(v_p2, v_cid, 'what', 'Ramen');  -- second
  PERFORM test_helpers.expire_challenge(v_cid);
  PERFORM test_helpers.reveal(v_poster, v_cid);

  SELECT what_points INTO v_p1_what FROM public.current_score_events WHERE challenge_id=v_cid AND player_id=v_p1;
  SELECT what_points INTO v_p2_what FROM public.current_score_events WHERE challenge_id=v_cid AND player_id=v_p2;

  -- eligible_count=2: P1 rank=1 → 2pts; P2 rank=2 → 1pt
  PERFORM test_helpers.assert(v_p1_what = 2, '8.4a: P1 first correct → 2 points');
  PERFORM test_helpers.assert(v_p2_what = 1, '8.4b: P2 second correct → 1 point');
END;
$$;

-- 8.5  Restaurant alone scores; correct restaurant → 1 where point (city is context only)
DO $$
DECLARE v_poster uuid; v_p1 uuid; v_group uuid; v_cid uuid; v_where_pts integer;
BEGIN
  v_poster := test_helpers.make_user('RestScorePoster');
  v_p1     := test_helpers.make_user('RestScoreP1');
  v_group  := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_p1);
  v_cid := test_helpers.make_draft_challenge(v_poster, v_group, 'Ramen', 'Ichiran', 'Tokyo');
  PERFORM test_helpers.activate(v_poster, v_cid);
  PERFORM test_helpers.make_guess(v_p1, v_cid, 'where', NULL, 'Ichiran');
  PERFORM test_helpers.expire_challenge(v_cid);
  PERFORM test_helpers.reveal(v_poster, v_cid);

  SELECT where_points INTO v_where_pts
  FROM public.current_score_events WHERE challenge_id=v_cid AND player_id=v_p1;
  PERFORM test_helpers.assert(v_where_pts = 1, '8.5: correct restaurant → 1 where point (city is context only)');
END;
$$;

-- 8.6  Incorrect restaurant → 0 where points regardless of city context
DO $$
DECLARE v_poster uuid; v_p1 uuid; v_group uuid; v_cid uuid; v_where_pts integer;
BEGIN
  v_poster := test_helpers.make_user('WrongRestPoster');
  v_p1     := test_helpers.make_user('WrongRestP1');
  v_group  := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_p1);
  v_cid := test_helpers.make_draft_challenge(v_poster, v_group, 'Ramen', 'Ichiran', 'Tokyo');
  PERFORM test_helpers.activate(v_poster, v_cid);
  PERFORM test_helpers.make_guess(v_p1, v_cid, 'where', NULL, 'Nobu');  -- wrong restaurant
  PERFORM test_helpers.expire_challenge(v_cid);
  PERFORM test_helpers.reveal(v_poster, v_cid);

  SELECT where_points INTO v_where_pts
  FROM public.current_score_events WHERE challenge_id=v_cid AND player_id=v_p1;
  PERFORM test_helpers.assert(v_where_pts = 0, '8.6: wrong restaurant → 0 where points');
END;
$$;

-- 8.7  Alias match awards points
DO $$
DECLARE v_poster uuid; v_p1 uuid; v_group uuid; v_cid uuid; v_what_pts integer;
BEGIN
  v_poster := test_helpers.make_user('AliasPoster');
  v_p1     := test_helpers.make_user('AliasP1');
  v_group  := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_p1);
  v_cid := test_helpers.make_draft_challenge(v_poster, v_group, 'Ramen', 'Ichiran', 'Tokyo');
  PERFORM test_helpers.activate(v_poster, v_cid);

  -- Insert alias BEFORE any guess (no has_first_guess yet)
  PERFORM test_helpers.set_auth_uid(v_poster);
  INSERT INTO public.challenge_answer_aliases (challenge_id, field, display_value, normalized_value, created_by, is_active)
  VALUES (v_cid, 'dish', 'Noodle Soup', private.normalize_answer('Noodle Soup'), v_poster, true);
  PERFORM test_helpers.clear_auth_uid();

  PERFORM test_helpers.make_guess(v_p1, v_cid, 'what', 'Noodle Soup');
  PERFORM test_helpers.expire_challenge(v_cid);
  PERFORM test_helpers.reveal(v_poster, v_cid);

  SELECT what_points INTO v_what_pts
  FROM public.current_score_events WHERE challenge_id=v_cid AND player_id=v_p1;
  PERFORM test_helpers.assert(v_what_pts > 0, '8.7: alias match → what_points > 0');
END;
$$;

-- 8.8  apply_correction rescores; current_score_events reflects new result
DO $$
DECLARE v_poster uuid; v_p1 uuid; v_group uuid; v_cid uuid;
        v_before integer; v_after integer; v_run_count integer;
BEGIN
  v_poster := test_helpers.make_user('CorrPoster');
  v_p1     := test_helpers.make_user('CorrP1');
  v_group  := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_p1);
  v_cid := test_helpers.make_draft_challenge(v_poster, v_group, 'Ramen', 'Ichiran', 'Tokyo');
  PERFORM test_helpers.activate(v_poster, v_cid);
  PERFORM test_helpers.make_guess(v_p1, v_cid, 'what', 'Soba');  -- wrong
  PERFORM test_helpers.expire_challenge(v_cid);
  PERFORM test_helpers.reveal(v_poster, v_cid);

  SELECT what_points INTO v_before
  FROM public.current_score_events WHERE challenge_id=v_cid AND player_id=v_p1;
  PERFORM test_helpers.assert(v_before = 0, '8.8a: pre-correction: wrong guess → 0 what points');

  -- Correct the dish to 'Soba'
  PERFORM test_helpers.set_auth_uid(v_poster);
  PERFORM public.apply_correction(v_cid, 'answer_changed', 'dish', 'Soba', NULL, 'Typo in original');
  PERFORM test_helpers.clear_auth_uid();

  SELECT what_points INTO v_after
  FROM public.current_score_events WHERE challenge_id=v_cid AND player_id=v_p1;
  PERFORM test_helpers.assert(v_after > 0, '8.8b: post-correction: P1 now has what points');

  SELECT COUNT(*) INTO v_run_count FROM public.score_runs WHERE challenge_id=v_cid;
  PERFORM test_helpers.assert(v_run_count = 2, '8.8c: two score runs created');
END;
$$;

-- 8.9  current_score_events shows only latest revision; score_events has all revisions
DO $$
DECLARE v_poster uuid; v_p1 uuid; v_group uuid; v_cid uuid;
        v_view_count integer; v_total_count integer;
BEGIN
  v_poster := test_helpers.make_user('RevViewPoster');
  v_p1     := test_helpers.make_user('RevViewP1');
  v_group  := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_p1);
  v_cid := test_helpers.make_draft_challenge(v_poster, v_group, 'Ramen', 'Ichiran', 'Tokyo');
  PERFORM test_helpers.activate(v_poster, v_cid);
  PERFORM test_helpers.make_guess(v_p1, v_cid, 'what', 'Ramen');
  PERFORM test_helpers.expire_challenge(v_cid);
  PERFORM test_helpers.reveal(v_poster, v_cid);

  PERFORM test_helpers.set_auth_uid(v_poster);
  PERFORM public.apply_correction(v_cid, 'alias_added', 'dish', 'Noodle Soup', NULL, 'Alias');
  PERFORM test_helpers.clear_auth_uid();

  SELECT COUNT(*) INTO v_view_count  FROM public.current_score_events WHERE challenge_id=v_cid;
  SELECT COUNT(*) INTO v_total_count FROM public.score_events           WHERE challenge_id=v_cid;

  PERFORM test_helpers.assert(v_view_count  = 1, '8.9a: current_score_events shows 1 row (latest rev only)');
  PERFORM test_helpers.assert(v_total_count = 2, '8.9b: score_events has 2 rows total (2 revisions)');
END;
$$;

-- =============================================================================
-- GROUP 9: CITY BEHAVIOR — city is optional context on challenges, never scored
-- =============================================================================
\echo ''
\echo '--- GROUP 9: City Behavior ---'

-- 9.1  City supplied by poster is preserved through activation
DO $$
DECLARE v_poster uuid; v_player uuid; v_group uuid; v_cid uuid; v_display text;
BEGIN
  v_poster := test_helpers.make_user('CityCtxPoster');
  v_player := test_helpers.make_user('CityCtxPlayer');
  v_group  := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_player);
  v_cid := test_helpers.make_draft_challenge(v_poster, v_group, 'Ramen', 'Ichiran', 'Austin, Texas');
  PERFORM test_helpers.activate(v_poster, v_cid);
  SELECT public_city_display INTO v_display FROM public.challenges WHERE id = v_cid;
  PERFORM test_helpers.assert(v_display = 'Austin, Texas', '9.1: city preserved through activation');
END;
$$;

-- 9.2  City is trimmed on INSERT (trigger normalizes)
DO $$
DECLARE v_poster uuid; v_group uuid; v_mid uuid; v_cid uuid; v_display text;
BEGIN
  v_poster := test_helpers.make_user('CityTrimPoster');
  v_group  := test_helpers.make_group(v_poster);
  v_mid    := test_helpers.make_media_object(v_poster);
  PERFORM test_helpers.set_auth_uid(v_poster);
  INSERT INTO public.challenges (group_id, media_object_id, public_city_display)
  VALUES (v_group, v_mid, '  Nashville  ') RETURNING id INTO v_cid;
  PERFORM test_helpers.clear_auth_uid();
  SELECT public_city_display INTO v_display FROM public.challenges WHERE id = v_cid;
  PERFORM test_helpers.assert(v_display = 'Nashville', '9.2: city is trimmed on INSERT');
END;
$$;

-- 9.3  Whitespace-only city becomes NULL (trigger normalizes)
DO $$
DECLARE v_poster uuid; v_group uuid; v_mid uuid; v_cid uuid; v_display text;
BEGIN
  v_poster := test_helpers.make_user('CityWSPoster');
  v_group  := test_helpers.make_group(v_poster);
  v_mid    := test_helpers.make_media_object(v_poster);
  PERFORM test_helpers.set_auth_uid(v_poster);
  INSERT INTO public.challenges (group_id, media_object_id, public_city_display)
  VALUES (v_group, v_mid, '   ') RETURNING id INTO v_cid;
  PERFORM test_helpers.clear_auth_uid();
  SELECT public_city_display INTO v_display FROM public.challenges WHERE id = v_cid;
  PERFORM test_helpers.assert(v_display IS NULL, '9.3: whitespace-only city becomes NULL');
END;
$$;

-- 9.4  City > 100 characters is rejected by constraint
DO $$
DECLARE v_poster uuid; v_group uuid; v_mid uuid; v_cid uuid; v_caught boolean := false;
BEGIN
  v_poster := test_helpers.make_user('CityLongPoster');
  v_group  := test_helpers.make_group(v_poster);
  v_mid    := test_helpers.make_media_object(v_poster);
  BEGIN
    PERFORM test_helpers.set_auth_uid(v_poster);
    INSERT INTO public.challenges (group_id, media_object_id, public_city_display)
    VALUES (v_group, v_mid, repeat('x', 101)) RETURNING id INTO v_cid;
  EXCEPTION
    WHEN check_violation     THEN v_caught := true;  -- 23514
    WHEN OTHERS THEN PERFORM test_helpers.clear_auth_uid();
      RAISE EXCEPTION 'unexpected SQLSTATE % — %', SQLSTATE, SQLERRM;
  END;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_caught, '9.4: city > 100 chars rejected (check_violation)');
END;
$$;

-- 9.5  Poster can edit city in draft
DO $$
DECLARE v_poster uuid; v_group uuid; v_cid uuid; v_display text;
BEGIN
  v_poster := test_helpers.make_user('CityEditPoster');
  v_group  := test_helpers.make_group(v_poster);
  v_cid    := test_helpers.make_draft_challenge(v_poster, v_group, 'Ramen', 'Ichiran', 'Chicago');
  PERFORM test_helpers.set_auth_uid(v_poster);
  UPDATE public.challenges SET public_city_display = 'Denver' WHERE id = v_cid;
  PERFORM test_helpers.clear_auth_uid();
  SELECT public_city_display INTO v_display FROM public.challenges WHERE id = v_cid;
  PERFORM test_helpers.assert(v_display = 'Denver', '9.5: poster can edit city in draft');
END;
$$;

-- 9.6  public_city_display immutable after activation
-- RLS (state='draft') silently returns 0 rows after activation; verify value unchanged.
DO $$
DECLARE v_poster uuid; v_player uuid; v_group uuid; v_cid uuid; v_display text;
BEGIN
  v_poster := test_helpers.make_user('CityImmPoster');
  v_player := test_helpers.make_user('CityImmPlayer');
  v_group  := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_player);
  v_cid := test_helpers.make_draft_challenge(v_poster, v_group, 'Ramen', 'Ichiran', 'Seattle');
  PERFORM test_helpers.activate(v_poster, v_cid);
  PERFORM test_helpers.set_auth_uid(v_poster);
  UPDATE public.challenges SET public_city_display = 'Portland' WHERE id = v_cid;
  PERFORM test_helpers.clear_auth_uid();
  SELECT public_city_display INTO v_display FROM public.challenges WHERE id = v_cid;
  PERFORM test_helpers.assert(v_display = 'Seattle', '9.6: public_city_display immutable after activation (value unchanged)');
END;
$$;

-- 9.7  Group member sees city immediately after activation
DO $$
DECLARE v_poster uuid; v_player uuid; v_group uuid; v_cid uuid; v_display text;
BEGIN
  v_poster := test_helpers.make_user('CitySeesPoster');
  v_player := test_helpers.make_user('CitySeesPlayer');
  v_group  := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_player);
  v_cid := test_helpers.make_draft_challenge(v_poster, v_group, 'Ramen', 'Ichiran', 'New Orleans');
  PERFORM test_helpers.activate(v_poster, v_cid);
  PERFORM test_helpers.set_auth_uid(v_player);
  SELECT public_city_display INTO v_display FROM public.challenges WHERE id = v_cid;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_display = 'New Orleans', '9.7: group member sees city after activation');
END;
$$;

-- 9.8  Blank city absent through activation and reveal
DO $$
DECLARE v_poster uuid; v_player uuid; v_group uuid; v_cid uuid; v_display text;
BEGIN
  v_poster := test_helpers.make_user('CityNullPoster');
  v_player := test_helpers.make_user('CityNullPlayer');
  v_group  := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_player);
  v_cid := test_helpers.make_draft_challenge(v_poster, v_group);  -- no city
  PERFORM test_helpers.activate(v_poster, v_cid);
  SELECT public_city_display INTO v_display FROM public.challenges WHERE id = v_cid;
  PERFORM test_helpers.assert(v_display IS NULL, '9.8a: no city after activation');
  PERFORM test_helpers.make_guess(v_player, v_cid, 'what', 'Ramen');
  PERFORM test_helpers.expire_challenge(v_cid);
  PERFORM test_helpers.reveal(v_poster, v_cid);
  SELECT public_city_display INTO v_display FROM public.challenges WHERE id = v_cid;
  PERFORM test_helpers.assert(v_display IS NULL, '9.8b: no city after reveal');
END;
$$;

-- 9.9  Correct restaurant scores even with no city supplied
DO $$
DECLARE v_poster uuid; v_player uuid; v_group uuid; v_cid uuid; v_where_pts integer;
BEGIN
  v_poster := test_helpers.make_user('CityNoScorePoster');
  v_player := test_helpers.make_user('CityNoScorePlayer');
  v_group  := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_player);
  v_cid := test_helpers.make_draft_challenge(v_poster, v_group, 'Ramen', 'Ichiran');  -- no city
  PERFORM test_helpers.activate(v_poster, v_cid);
  PERFORM test_helpers.make_guess(v_player, v_cid, 'where', NULL, 'Ichiran');
  PERFORM test_helpers.expire_challenge(v_cid);
  PERFORM test_helpers.reveal(v_poster, v_cid);
  SELECT where_points INTO v_where_pts
  FROM public.current_score_events WHERE challenge_id=v_cid AND player_id=v_player;
  PERFORM test_helpers.assert(v_where_pts = 1, '9.9: correct restaurant scores with no city supplied');
END;
$$;

-- 9.10  Incorrect restaurant remains incorrect regardless of city context
DO $$
DECLARE v_poster uuid; v_player uuid; v_group uuid; v_cid uuid; v_where_pts integer;
BEGIN
  v_poster := test_helpers.make_user('CityNoHelpPoster');
  v_player := test_helpers.make_user('CityNoHelpPlayer');
  v_group  := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_player);
  v_cid := test_helpers.make_draft_challenge(v_poster, v_group, 'Ramen', 'Ichiran', 'Tokyo');
  PERFORM test_helpers.activate(v_poster, v_cid);
  PERFORM test_helpers.make_guess(v_player, v_cid, 'where', NULL, 'Nobu');  -- wrong restaurant
  PERFORM test_helpers.expire_challenge(v_cid);
  PERFORM test_helpers.reveal(v_poster, v_cid);
  SELECT where_points INTO v_where_pts
  FROM public.current_score_events WHERE challenge_id=v_cid AND player_id=v_player;
  PERFORM test_helpers.assert(v_where_pts = 0, '9.10: wrong restaurant stays incorrect regardless of city context');
END;
$$;

-- 9.11  Draft city update is trimmed
DO $$
DECLARE v_poster uuid; v_group uuid; v_cid uuid; v_display text;
BEGIN
  v_poster := test_helpers.make_user('CityTrimUpdPoster');
  v_group  := test_helpers.make_group(v_poster);
  v_cid    := test_helpers.make_draft_challenge(v_poster, v_group, 'Ramen', 'Ichiran', 'Chicago');
  PERFORM test_helpers.set_auth_uid(v_poster);
  UPDATE public.challenges SET public_city_display = '  Denver  ' WHERE id = v_cid;
  PERFORM test_helpers.clear_auth_uid();
  SELECT public_city_display INTO v_display FROM public.challenges WHERE id = v_cid;
  PERFORM test_helpers.assert(v_display = 'Denver', '9.11: draft city update is trimmed');
END;
$$;

-- 9.12  Draft city update with whitespace-only becomes NULL
DO $$
DECLARE v_poster uuid; v_group uuid; v_cid uuid; v_display text;
BEGIN
  v_poster := test_helpers.make_user('CityWsUpdPoster');
  v_group  := test_helpers.make_group(v_poster);
  v_cid    := test_helpers.make_draft_challenge(v_poster, v_group, 'Ramen', 'Ichiran', 'Chicago');
  PERFORM test_helpers.set_auth_uid(v_poster);
  UPDATE public.challenges SET public_city_display = '   ' WHERE id = v_cid;
  PERFORM test_helpers.clear_auth_uid();
  SELECT public_city_display INTO v_display FROM public.challenges WHERE id = v_cid;
  PERFORM test_helpers.assert(v_display IS NULL, '9.12: whitespace-only draft city update becomes NULL');
END;
$$;

-- =============================================================================
-- GROUP 10: EXCLUSIONS  (GPT issue #11)
-- =============================================================================
\echo ''
\echo '--- GROUP 10: Exclusions ---'

-- 10.1  Player self-withdrawal while active
DO $$
DECLARE v_poster uuid; v_player uuid; v_group uuid; v_cid uuid; v_count integer;
BEGIN
  v_poster := test_helpers.make_user('WithdrawPoster');
  v_player := test_helpers.make_user('WithdrawPlayer');
  v_group  := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_player);
  v_cid := test_helpers.make_draft_challenge(v_poster, v_group);
  PERFORM test_helpers.activate(v_poster, v_cid);
  PERFORM test_helpers.set_auth_uid(v_player);
  INSERT INTO public.exclusion_events (challenge_id, player_id, reason, excluded_by)
  VALUES (v_cid, v_player, 'withdrew', v_player);
  PERFORM test_helpers.clear_auth_uid();
  SELECT COUNT(*) INTO v_count FROM public.exclusion_events WHERE challenge_id=v_cid;
  PERFORM test_helpers.assert(v_count = 1, '10.1: player self-withdrawal from active challenge accepted');
END;
$$;

-- 10.2  Exclusion from revealed challenge rejected
DO $$
DECLARE v_poster uuid; v_player uuid; v_group uuid; v_cid uuid; v_caught boolean := false;
BEGIN
  v_poster := test_helpers.make_user('ExclRevPoster');
  v_player := test_helpers.make_user('ExclRevPlayer');
  v_group  := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_player);
  v_cid := test_helpers.make_draft_challenge(v_poster, v_group);
  PERFORM test_helpers.activate(v_poster, v_cid);
  PERFORM test_helpers.expire_challenge(v_cid);
  PERFORM test_helpers.reveal(v_poster, v_cid);
  BEGIN
    PERFORM test_helpers.set_auth_uid(v_player);
    INSERT INTO public.exclusion_events (challenge_id, player_id, reason, excluded_by)
    VALUES (v_cid, v_player, 'withdrew', v_player);
  EXCEPTION WHEN raise_exception THEN v_caught := true;
  WHEN OTHERS THEN PERFORM test_helpers.clear_auth_uid();
    RAISE EXCEPTION 'FAIL 10.2: unexpected SQLSTATE % — %', SQLSTATE, SQLERRM;
  END;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_caught, '10.2: exclusion from revealed challenge rejected');
END;
$$;

-- 10.3  account_deleted exclusion accepted from forkensics_executor
DO $$
DECLARE v_poster uuid; v_player uuid; v_group uuid; v_cid uuid; v_count integer;
BEGIN
  v_poster := test_helpers.make_user('AccDelPoster');
  v_player := test_helpers.make_user('AccDelPlayer');
  v_group  := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_player);
  v_cid := test_helpers.make_draft_challenge(v_poster, v_group);
  PERFORM test_helpers.activate(v_poster, v_cid);
  SET LOCAL ROLE forkensics_executor;
  INSERT INTO public.exclusion_events (challenge_id, player_id, reason, excluded_by)
  VALUES (v_cid, v_player, 'account_deleted', NULL);
  RESET ROLE;
  SELECT COUNT(*) INTO v_count FROM public.exclusion_events WHERE challenge_id=v_cid;
  PERFORM test_helpers.assert(v_count = 1, '10.3: account_deleted exclusion accepted from executor');
END;
$$;

-- 10.4  account_deleted exclusion blocked for authenticated
DO $$
DECLARE v_poster uuid; v_player uuid; v_group uuid; v_cid uuid; v_caught boolean := false;
BEGIN
  v_poster := test_helpers.make_user('AccDelAuthPoster');
  v_player := test_helpers.make_user('AccDelAuthPlayer');
  v_group  := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_player);
  v_cid := test_helpers.make_draft_challenge(v_poster, v_group);
  PERFORM test_helpers.activate(v_poster, v_cid);
  BEGIN
    PERFORM test_helpers.set_auth_uid(v_poster);
    INSERT INTO public.exclusion_events (challenge_id, player_id, reason, excluded_by)
    VALUES (v_cid, v_player, 'account_deleted', NULL);
  EXCEPTION WHEN raise_exception THEN v_caught := true;
  WHEN OTHERS THEN PERFORM test_helpers.clear_auth_uid();
    RAISE EXCEPTION 'FAIL 10.4: unexpected SQLSTATE % — %', SQLSTATE, SQLERRM;
  END;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_caught, '10.4: account_deleted exclusion blocked for authenticated');
END;
$$;

-- =============================================================================
-- GROUP 11: VISIBILITY / RLS  (GPT issue #11)
-- =============================================================================
\echo ''
\echo '--- GROUP 11: Visibility (RLS) ---'

-- 11.1  Outsider cannot see group row
DO $$
DECLARE v_owner uuid; v_outsider uuid; v_group uuid; v_count integer;
BEGIN
  v_owner    := test_helpers.make_user('RLSOwner');
  v_outsider := test_helpers.make_user('RLSOutsider');
  v_group    := test_helpers.make_group(v_owner);
  PERFORM test_helpers.set_auth_uid(v_outsider);
  SELECT COUNT(*) INTO v_count FROM public.groups WHERE id=v_group;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_count = 0, '11.1: outsider cannot read group row');
END;
$$;

-- 11.2  Non-poster cannot read challenge_secrets before reveal
DO $$
DECLARE v_poster uuid; v_player uuid; v_group uuid; v_cid uuid; v_count integer;
BEGIN
  v_poster := test_helpers.make_user('SecRLSPoster');
  v_player := test_helpers.make_user('SecRLSPlayer');
  v_group  := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_player);
  v_cid := test_helpers.make_draft_challenge(v_poster, v_group);
  PERFORM test_helpers.activate(v_poster, v_cid);
  PERFORM test_helpers.set_auth_uid(v_player);
  SELECT COUNT(*) INTO v_count FROM public.challenge_secrets WHERE challenge_id=v_cid;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_count = 0, '11.2: non-poster cannot read challenge_secrets before reveal');
END;
$$;

-- 11.3  Group member can read challenge_secrets after reveal
DO $$
DECLARE v_poster uuid; v_player uuid; v_group uuid; v_cid uuid; v_count integer;
BEGIN
  v_poster := test_helpers.make_user('PostRevPoster');
  v_player := test_helpers.make_user('PostRevPlayer');
  v_group  := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_player);
  v_cid := test_helpers.make_draft_challenge(v_poster, v_group);
  PERFORM test_helpers.activate(v_poster, v_cid);
  PERFORM test_helpers.expire_challenge(v_cid);
  PERFORM test_helpers.reveal(v_poster, v_cid);
  PERFORM test_helpers.set_auth_uid(v_player);
  SELECT COUNT(*) INTO v_count FROM public.challenge_secrets WHERE challenge_id=v_cid;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_count = 1, '11.3: group member can read challenge_secrets after reveal');
END;
$$;

-- 11.4  Draft challenge invisible to non-poster group member
DO $$
DECLARE v_poster uuid; v_player uuid; v_group uuid; v_cid uuid; v_count integer;
BEGIN
  v_poster := test_helpers.make_user('DraftVisPoster');
  v_player := test_helpers.make_user('DraftVisPlayer');
  v_group  := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_player);
  v_cid := test_helpers.make_draft_challenge(v_poster, v_group);
  PERFORM test_helpers.set_auth_uid(v_player);
  SELECT COUNT(*) INTO v_count FROM public.challenges WHERE id=v_cid;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_count = 0, '11.4: draft challenge invisible to non-poster group member');
END;
$$;

-- =============================================================================
-- GROUP 12: TRUSTED EXECUTION  (GPT issue #11)
-- =============================================================================
\echo ''
\echo '--- GROUP 12: Trusted Execution ---'

-- 12.1  create_group through SECURITY DEFINER executor path
DO $$
DECLARE v_user uuid; v_group uuid;
BEGIN
  v_user  := test_helpers.make_user('TrustUser');
  v_group := test_helpers.make_group(v_user, 'TrustGroup');
  PERFORM test_helpers.assert(v_group IS NOT NULL, '12.1: create_group succeeds via executor SECURITY DEFINER');
END;
$$;

-- 12.2  activate_challenge inserts eligible_participants despite RLS
DO $$
DECLARE v_poster uuid; v_player uuid; v_group uuid; v_cid uuid; v_ep_count integer;
BEGIN
  v_poster := test_helpers.make_user('EPPoster');
  v_player := test_helpers.make_user('EPPlayer');
  v_group  := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_player);
  v_cid := test_helpers.make_draft_challenge(v_poster, v_group);
  PERFORM test_helpers.activate(v_poster, v_cid);
  SELECT COUNT(*) INTO v_ep_count FROM public.eligible_participants WHERE challenge_id=v_cid;
  PERFORM test_helpers.assert(v_ep_count = 1, '12.2: activate inserts EP despite RLS');
END;
$$;

-- 12.3  reveal_challenge creates score_run and score_events despite RLS
DO $$
DECLARE v_poster uuid; v_player uuid; v_group uuid; v_cid uuid;
        v_sr integer; v_se integer;
BEGIN
  v_poster := test_helpers.make_user('RevScorePoster');
  v_player := test_helpers.make_user('RevScorePlayer');
  v_group  := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_player);
  v_cid := test_helpers.make_draft_challenge(v_poster, v_group);
  PERFORM test_helpers.activate(v_poster, v_cid);
  PERFORM test_helpers.expire_challenge(v_cid);
  PERFORM test_helpers.reveal(v_poster, v_cid);
  SELECT COUNT(*) INTO v_sr FROM public.score_runs   WHERE challenge_id=v_cid;
  SELECT COUNT(*) INTO v_se FROM public.score_events WHERE challenge_id=v_cid;
  PERFORM test_helpers.assert(v_sr = 1, '12.3a: reveal creates 1 score_run');
  PERFORM test_helpers.assert(v_se = 1, '12.3b: reveal creates 1 score_event');
END;
$$;

-- 12.4  normalize_answer callable by forkensics_executor after revocations
DO $$
DECLARE v_result text;
BEGIN
  SET LOCAL ROLE forkensics_executor;
  v_result := private.normalize_answer('Ramen');
  RESET ROLE;
  PERFORM test_helpers.assert(v_result = 'ramen', '12.4: normalize_answer callable by forkensics_executor');
END;
$$;

-- 12.5  pgcrypto invite create+redeem round-trip
DO $$
DECLARE v_owner uuid; v_member uuid; v_group uuid; v_token text; v_gid uuid;
BEGIN
  v_owner  := test_helpers.make_user('InvOwner');
  v_member := test_helpers.make_user('InvMember');
  v_group  := test_helpers.make_group(v_owner);
  PERFORM test_helpers.set_auth_uid(v_owner);
  v_token := public.create_group_invite(v_group);
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.set_auth_uid(v_member);
  v_gid := public.redeem_group_invite(v_token);
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_gid = v_group, '12.5: pgcrypto invite create+redeem succeeds');
END;
$$;

-- =============================================================================
-- GROUP 13: INVITES  (GPT issue #11)
-- =============================================================================
\echo ''
\echo '--- GROUP 13: Invites ---'

-- 13.1  Expired invite rejected
DO $$
DECLARE v_owner uuid; v_member uuid; v_group uuid; v_token text; v_inv_id uuid; v_caught boolean := false;
BEGIN
  v_owner  := test_helpers.make_user('ExpOwner');
  v_member := test_helpers.make_user('ExpMember');
  v_group  := test_helpers.make_group(v_owner);
  PERFORM test_helpers.set_auth_uid(v_owner);
  v_token := public.create_group_invite(v_group);
  PERFORM test_helpers.clear_auth_uid();
  SELECT id INTO v_inv_id FROM public.group_invites WHERE created_by=v_owner AND group_id=v_group;
  UPDATE public.group_invites SET expires_at = now() - interval '1 second' WHERE id=v_inv_id;
  BEGIN
    PERFORM test_helpers.set_auth_uid(v_member);
    PERFORM public.redeem_group_invite(v_token);
  EXCEPTION WHEN raise_exception THEN v_caught := true;
  WHEN OTHERS THEN PERFORM test_helpers.clear_auth_uid();
    RAISE EXCEPTION 'FAIL 13.1: unexpected SQLSTATE % — %', SQLSTATE, SQLERRM;
  END;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_caught, '13.1: expired invite rejected');
END;
$$;

-- 13.2  Revoked invite rejected
DO $$
DECLARE v_owner uuid; v_member uuid; v_group uuid; v_token text; v_inv_id uuid; v_caught boolean := false;
BEGIN
  v_owner  := test_helpers.make_user('RevOwner');
  v_member := test_helpers.make_user('RevMember');
  v_group  := test_helpers.make_group(v_owner);
  PERFORM test_helpers.set_auth_uid(v_owner);
  v_token := public.create_group_invite(v_group);
  SELECT id INTO v_inv_id FROM public.group_invites WHERE created_by=v_owner AND group_id=v_group;
  PERFORM public.revoke_group_invite(v_inv_id);
  PERFORM test_helpers.clear_auth_uid();
  BEGIN
    PERFORM test_helpers.set_auth_uid(v_member);
    PERFORM public.redeem_group_invite(v_token);
  EXCEPTION WHEN raise_exception THEN v_caught := true;
  WHEN OTHERS THEN PERFORM test_helpers.clear_auth_uid();
    RAISE EXCEPTION 'FAIL 13.2: unexpected SQLSTATE % — %', SQLSTATE, SQLERRM;
  END;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_caught, '13.2: revoked invite rejected');
END;
$$;

-- 13.3  Non-owner member cannot revoke invite
DO $$
DECLARE v_owner uuid; v_member uuid; v_group uuid; v_inv_id uuid; v_caught boolean := false;
BEGIN
  v_owner  := test_helpers.make_user('RevAuthOwner');
  v_member := test_helpers.make_user('RevAuthMember');
  v_group  := test_helpers.make_group(v_owner);
  PERFORM test_helpers.add_member(v_group, v_owner, v_member);
  PERFORM test_helpers.set_auth_uid(v_owner);
  PERFORM public.create_group_invite(v_group);
  PERFORM test_helpers.clear_auth_uid();
  SELECT id INTO v_inv_id FROM public.group_invites WHERE created_by=v_owner AND group_id=v_group;
  BEGIN
    PERFORM test_helpers.set_auth_uid(v_member);
    PERFORM public.revoke_group_invite(v_inv_id);
  EXCEPTION WHEN raise_exception THEN v_caught := true;
  WHEN OTHERS THEN PERFORM test_helpers.clear_auth_uid();
    RAISE EXCEPTION 'FAIL 13.3: unexpected SQLSTATE % — %', SQLSTATE, SQLERRM;
  END;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_caught, '13.3: non-owner member cannot revoke invite');
END;
$$;

-- =============================================================================
-- GROUP 14: SEED DATA — COMPLETE CONFIG  (GPT issue #12)
-- =============================================================================
\echo ''
\echo '--- GROUP 14: Seed Data — Complete Config Coverage ---'

DO $$
DECLARE v jsonb;
BEGIN
  SELECT config INTO v FROM public.rules_versions WHERE version_tag = 'v1';
  IF v IS NULL THEN RAISE EXCEPTION 'v1 rules_version not found'; END IF;

  PERFORM test_helpers.assert((v->>'scoring_algorithm')         = 'ordinal_ranking_v1',         '14.1: scoring_algorithm');
  PERFORM test_helpers.assert((v->>'points_formula')            IS NOT NULL,                     '14.2: points_formula present');
  PERFORM test_helpers.assert((v->>'min_points')::int           = 1,                             '14.3: min_points = 1');
  PERFORM test_helpers.assert((v->>'no_correct_answer_points')::int = 0,                        '14.4: no_correct_answer_points = 0');
  PERFORM test_helpers.assert((v->>'partial_credit')::boolean   = false,                         '14.5: partial_credit = false');
  PERFORM test_helpers.assert((v->>'tie_breaking')              = 'receipt_sequence_ascending',  '14.6: tie_breaking');
  PERFORM test_helpers.assert((v->>'alias_aware_matching')::boolean = true,                      '14.7: alias_aware_matching = true');
  PERFORM test_helpers.assert((v->>'default_duration_seconds')::int = 7200,                      '14.8: default_duration_seconds = 7200');
  PERFORM test_helpers.assert((v->>'min_duration_seconds')::int = 3600,                          '14.9: min_duration_seconds = 3600');
  PERFORM test_helpers.assert((v->>'max_duration_seconds')::int = 86400,                         '14.10: max_duration_seconds = 86400');
  PERFORM test_helpers.assert((v->>'duration_step_seconds')::int = 3600,                         '14.11: duration_step_seconds = 3600');
  PERFORM test_helpers.assert((v->>'normalization_version')     = 'v1',                          '14.12: normalization_version = v1');
  PERFORM test_helpers.assert((v->'normalization_steps')        IS NOT NULL,                     '14.13: normalization_steps present');
  PERFORM test_helpers.assert((v->'where_race_fields') = '["restaurant"]'::jsonb,               '14.14: where_race_fields = ["restaurant"] (city not scored)');
END;
$$;

-- =============================================================================
-- GROUP 15: EXCLUSION STATE MATRIX
-- withdrew: active only, self-exclude
-- removed:  active only, poster/owner only, target must be eligible
-- account_deleted: active or locked, executor only
-- =============================================================================
\echo ''
\echo '--- GROUP 15: Exclusion State Matrix ---'

-- 15.1: withdrew accepted while active
DO $$
DECLARE
  v_poster uuid; v_player uuid; v_group uuid; v_cid uuid;
BEGIN
  v_poster := test_helpers.make_user('WdPoster');
  v_player := test_helpers.make_user('WdPlayer');
  v_group  := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_player);
  v_cid := test_helpers.make_draft_challenge(v_poster, v_group);
  PERFORM test_helpers.activate(v_poster, v_cid);

  PERFORM test_helpers.set_auth_uid(v_player);
  INSERT INTO public.exclusion_events (challenge_id, player_id, reason, excluded_by)
  VALUES (v_cid, v_player, 'withdrew', v_player);
  PERFORM test_helpers.clear_auth_uid();

  PERFORM test_helpers.assert(
    EXISTS(SELECT 1 FROM public.exclusion_events
           WHERE challenge_id = v_cid AND player_id = v_player AND reason = 'withdrew'),
    '15.1: withdrew accepted while challenge active'
  );
END;
$$;

-- 15.2: withdrew rejected when challenge is locked (not active)
DO $$
DECLARE
  v_poster uuid; v_player uuid; v_group uuid; v_cid uuid; v_caught boolean := false;
BEGIN
  v_poster := test_helpers.make_user('WdLPoster');
  v_player := test_helpers.make_user('WdLPlayer');
  v_group  := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_player);
  v_cid := test_helpers.make_draft_challenge(v_poster, v_group);
  PERFORM test_helpers.activate(v_poster, v_cid);
  PERFORM test_helpers.expire_challenge(v_cid);
  -- Lock the challenge (service-role path)
  SET LOCAL ROLE forkensics_executor;
  PERFORM public.lock_challenge(v_cid);
  RESET ROLE;

  BEGIN
    PERFORM test_helpers.set_auth_uid(v_player);
    INSERT INTO public.exclusion_events (challenge_id, player_id, reason, excluded_by)
    VALUES (v_cid, v_player, 'withdrew', v_player);
  EXCEPTION
    WHEN raise_exception THEN v_caught := true;  -- enforce_exclusion_rules BEFORE trigger fires before RLS (P0001)
    WHEN OTHERS THEN RAISE EXCEPTION 'unexpected SQLSTATE % — %', SQLSTATE, SQLERRM;
  END;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_caught, '15.2: withdrew rejected when challenge locked');
END;
$$;

-- 15.3: withdrew rejected when excluded_by != player_id (not self-exclude)
DO $$
DECLARE
  v_poster uuid; v_player uuid; v_group uuid; v_cid uuid; v_caught boolean := false;
BEGIN
  v_poster := test_helpers.make_user('WdSPoster');
  v_player := test_helpers.make_user('WdSPlayer');
  v_group  := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_player);
  v_cid := test_helpers.make_draft_challenge(v_poster, v_group);
  PERFORM test_helpers.activate(v_poster, v_cid);

  BEGIN
    PERFORM test_helpers.set_auth_uid(v_poster);
    INSERT INTO public.exclusion_events (challenge_id, player_id, reason, excluded_by)
    VALUES (v_cid, v_player, 'withdrew', v_poster);  -- poster trying to insert withdrew for player
  EXCEPTION
    WHEN raise_exception THEN v_caught := true;  -- enforce_exclusion_rules BEFORE trigger fires before RLS (P0001)
    WHEN OTHERS THEN RAISE EXCEPTION 'unexpected SQLSTATE % — %', SQLSTATE, SQLERRM;
  END;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_caught, '15.3: withdrew rejected when excluded_by != player_id');
END;
$$;

-- 15.4: removed accepted while active, by poster
DO $$
DECLARE
  v_poster uuid; v_player uuid; v_group uuid; v_cid uuid;
BEGIN
  v_poster := test_helpers.make_user('RmPoster');
  v_player := test_helpers.make_user('RmPlayer');
  v_group  := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_player);
  v_cid := test_helpers.make_draft_challenge(v_poster, v_group);
  PERFORM test_helpers.activate(v_poster, v_cid);

  PERFORM test_helpers.set_auth_uid(v_poster);
  INSERT INTO public.exclusion_events (challenge_id, player_id, reason, excluded_by)
  VALUES (v_cid, v_player, 'removed', v_poster);
  PERFORM test_helpers.clear_auth_uid();

  PERFORM test_helpers.assert(
    EXISTS(SELECT 1 FROM public.exclusion_events
           WHERE challenge_id = v_cid AND player_id = v_player AND reason = 'removed'),
    '15.4: removed accepted while active, by poster'
  );
END;
$$;

-- 15.5: removed rejected when challenge is locked
DO $$
DECLARE
  v_poster uuid; v_player uuid; v_group uuid; v_cid uuid; v_caught boolean := false;
BEGIN
  v_poster := test_helpers.make_user('RmLPoster');
  v_player := test_helpers.make_user('RmLPlayer');
  v_group  := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_player);
  v_cid := test_helpers.make_draft_challenge(v_poster, v_group);
  PERFORM test_helpers.activate(v_poster, v_cid);
  PERFORM test_helpers.expire_challenge(v_cid);
  SET LOCAL ROLE forkensics_executor;
  PERFORM public.lock_challenge(v_cid);
  RESET ROLE;

  BEGIN
    PERFORM test_helpers.set_auth_uid(v_poster);
    INSERT INTO public.exclusion_events (challenge_id, player_id, reason, excluded_by)
    VALUES (v_cid, v_player, 'removed', v_poster);
  EXCEPTION
    WHEN raise_exception THEN v_caught := true;  -- enforce_exclusion_rules BEFORE trigger fires before RLS (P0001)
    WHEN OTHERS THEN RAISE EXCEPTION 'unexpected SQLSTATE % — %', SQLSTATE, SQLERRM;
  END;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_caught, '15.5: removed rejected when challenge locked');
END;
$$;

-- 15.6: removed rejected for non-eligible target
DO $$
DECLARE
  v_poster uuid; v_outsider uuid; v_group uuid; v_cid uuid; v_caught boolean := false;
BEGIN
  v_poster   := test_helpers.make_user('RmNEPoster');
  v_outsider := test_helpers.make_user('RmNEOutsider');
  v_group    := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_outsider);
  v_cid := test_helpers.make_draft_challenge(v_poster, v_group);
  PERFORM test_helpers.activate(v_poster, v_cid);
  -- v_outsider is a group member but NOT in eligible_participants (joined after activation snapshot? no)
  -- Actually for this test, activate includes all members. Let's test non-member instead.
  -- Remove outsider from group first (before activation), so they won't be eligible.
  -- Simpler: create a second user who is NOT a member at all.
  DECLARE v_nonmember uuid;
  BEGIN
    v_nonmember := test_helpers.make_user('RmNonMember');
    BEGIN
      PERFORM test_helpers.set_auth_uid(v_poster);
      INSERT INTO public.exclusion_events (challenge_id, player_id, reason, excluded_by)
      VALUES (v_cid, v_nonmember, 'removed', v_poster);
    EXCEPTION
      WHEN raise_exception THEN v_caught := true;  -- enforce_exclusion_rules BEFORE trigger: player not eligible (P0001)
      WHEN OTHERS THEN RAISE EXCEPTION 'unexpected SQLSTATE % — %', SQLSTATE, SQLERRM;
    END;
    PERFORM test_helpers.clear_auth_uid();
  END;
  PERFORM test_helpers.assert(v_caught, '15.6: removed rejected for non-eligible player');
END;
$$;

-- 15.7: account_deleted accepted while active (executor path)
DO $$
DECLARE
  v_poster uuid; v_player uuid; v_group uuid; v_cid uuid;
BEGIN
  v_poster := test_helpers.make_user('AdPoster');
  v_player := test_helpers.make_user('AdPlayer');
  v_group  := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_player);
  v_cid := test_helpers.make_draft_challenge(v_poster, v_group);
  PERFORM test_helpers.activate(v_poster, v_cid);

  SET LOCAL ROLE forkensics_executor;
  INSERT INTO public.exclusion_events (challenge_id, player_id, reason, excluded_by)
  VALUES (v_cid, v_player, 'account_deleted', NULL)
  ON CONFLICT (challenge_id, player_id) DO NOTHING;
  RESET ROLE;

  PERFORM test_helpers.assert(
    EXISTS(SELECT 1 FROM public.exclusion_events
           WHERE challenge_id = v_cid AND player_id = v_player AND reason = 'account_deleted'),
    '15.7: account_deleted accepted while active (executor)'
  );
END;
$$;

-- 15.8: account_deleted accepted while locked (executor path)
DO $$
DECLARE
  v_poster uuid; v_player uuid; v_group uuid; v_cid uuid;
BEGIN
  v_poster := test_helpers.make_user('AdLPoster');
  v_player := test_helpers.make_user('AdLPlayer');
  v_group  := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_player);
  v_cid := test_helpers.make_draft_challenge(v_poster, v_group);
  PERFORM test_helpers.activate(v_poster, v_cid);
  PERFORM test_helpers.expire_challenge(v_cid);
  SET LOCAL ROLE forkensics_executor;
  PERFORM public.lock_challenge(v_cid);
  INSERT INTO public.exclusion_events (challenge_id, player_id, reason, excluded_by)
  VALUES (v_cid, v_player, 'account_deleted', NULL)
  ON CONFLICT (challenge_id, player_id) DO NOTHING;
  RESET ROLE;

  PERFORM test_helpers.assert(
    EXISTS(SELECT 1 FROM public.exclusion_events
           WHERE challenge_id = v_cid AND player_id = v_player AND reason = 'account_deleted'),
    '15.8: account_deleted accepted while locked (executor)'
  );
END;
$$;

-- 15.9: account_deleted rejected from authenticated (not executor)
DO $$
DECLARE
  v_poster uuid; v_player uuid; v_group uuid; v_cid uuid; v_caught boolean := false;
BEGIN
  v_poster := test_helpers.make_user('AdRPoster');
  v_player := test_helpers.make_user('AdRPlayer');
  v_group  := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_player);
  v_cid := test_helpers.make_draft_challenge(v_poster, v_group);
  PERFORM test_helpers.activate(v_poster, v_cid);

  BEGIN
    PERFORM test_helpers.set_auth_uid(v_poster);
    INSERT INTO public.exclusion_events (challenge_id, player_id, reason, excluded_by)
    VALUES (v_cid, v_player, 'account_deleted', NULL);
  EXCEPTION
    WHEN raise_exception THEN v_caught := true;  -- enforce_exclusion_rules BEFORE trigger: not forkensics_executor (P0001)
    WHEN OTHERS THEN RAISE EXCEPTION 'unexpected SQLSTATE % — %', SQLSTATE, SQLERRM;
  END;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_caught, '15.9: account_deleted rejected from authenticated caller');
END;
$$;

-- 15.10: account_deleted is idempotent (ON CONFLICT DO NOTHING)
DO $$
DECLARE
  v_poster uuid; v_player uuid; v_group uuid; v_cid uuid; v_count int;
BEGIN
  v_poster := test_helpers.make_user('AdIPoster');
  v_player := test_helpers.make_user('AdIPlayer');
  v_group  := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_player);
  v_cid := test_helpers.make_draft_challenge(v_poster, v_group);
  PERFORM test_helpers.activate(v_poster, v_cid);

  SET LOCAL ROLE forkensics_executor;
  INSERT INTO public.exclusion_events (challenge_id, player_id, reason, excluded_by)
  VALUES (v_cid, v_player, 'account_deleted', NULL)
  ON CONFLICT (challenge_id, player_id) DO NOTHING;
  INSERT INTO public.exclusion_events (challenge_id, player_id, reason, excluded_by)
  VALUES (v_cid, v_player, 'account_deleted', NULL)
  ON CONFLICT (challenge_id, player_id) DO NOTHING;
  RESET ROLE;

  SELECT COUNT(*) INTO v_count FROM public.exclusion_events
  WHERE challenge_id = v_cid AND player_id = v_player;
  PERFORM test_helpers.assert(v_count = 1, '15.10: account_deleted idempotent (one row only)');
END;
$$;

-- =============================================================================
-- GROUP 16: CROSS-RECORD INTEGRITY TRIGGERS
-- =============================================================================
\echo ''
\echo '--- GROUP 16: Cross-Record Integrity ---'

-- 16.1: avatar media owned by same profile and ready — accepted
DO $$
DECLARE
  v_user uuid; v_mid uuid;
BEGIN
  v_user := test_helpers.make_user('AvOwnUser');
  v_mid  := test_helpers.make_media_object(v_user);  -- uploader_id = v_user, status = ready

  UPDATE public.profiles
  SET avatar_media_object_id = v_mid
  WHERE id = v_user;

  PERFORM test_helpers.assert(
    EXISTS(SELECT 1 FROM public.profiles WHERE id = v_user AND avatar_media_object_id = v_mid),
    '16.1: avatar media owned by this profile and ready — accepted'
  );
END;
$$;

-- 16.2: avatar media owned by different profile — rejected
DO $$
DECLARE
  v_user1 uuid; v_user2 uuid; v_mid uuid; v_caught boolean := false;
BEGIN
  v_user1 := test_helpers.make_user('AvOwn1');
  v_user2 := test_helpers.make_user('AvOwn2');
  v_mid   := test_helpers.make_media_object(v_user1);  -- owned by user1

  BEGIN
    UPDATE public.profiles
    SET avatar_media_object_id = v_mid
    WHERE id = v_user2;  -- user2 trying to use user1's media
  EXCEPTION
    WHEN raise_exception THEN v_caught := true;  -- check_avatar_media_ownership trigger (P0001)
    WHEN OTHERS THEN RAISE EXCEPTION 'unexpected SQLSTATE % — %', SQLSTATE, SQLERRM;
  END;
  PERFORM test_helpers.assert(v_caught, '16.2: avatar media owned by other profile — rejected');
END;
$$;

-- 16.3: avatar media with status != ready — rejected
DO $$
DECLARE
  v_user uuid; v_mid uuid; v_caught boolean := false;
BEGIN
  v_user := test_helpers.make_user('AvNotReady');
  INSERT INTO public.media_objects (id, uploader_id, mime_type, status)
  VALUES (gen_random_uuid(), v_user, 'image/jpeg', 'processing')
  RETURNING id INTO v_mid;

  BEGIN
    UPDATE public.profiles
    SET avatar_media_object_id = v_mid
    WHERE id = v_user;
  EXCEPTION
    WHEN raise_exception THEN v_caught := true;  -- check_avatar_media_ownership trigger (P0001)
    WHEN OTHERS THEN RAISE EXCEPTION 'unexpected SQLSTATE % — %', SQLSTATE, SQLERRM;
  END;
  PERFORM test_helpers.assert(v_caught, '16.3: avatar media not ready — rejected');
END;
$$;

-- 16.4: judgment challenge_id mismatch — rejected
DO $$
DECLARE
  v_poster  uuid; v_player  uuid; v_group   uuid;
  v_cid1    uuid; v_cid2    uuid; v_run_id  uuid;
  v_ga_id   uuid; v_caught  boolean := false;
BEGIN
  v_poster := test_helpers.make_user('JCMPoster');
  v_player := test_helpers.make_user('JCMPlayer');
  v_group  := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_player);

  -- Fully reveal cid1 first so poster can create cid2 (one_active_challenge_per_poster constraint)
  v_cid1   := test_helpers.make_draft_challenge(v_poster, v_group);
  PERFORM test_helpers.activate(v_poster, v_cid1);
  v_ga_id  := test_helpers.make_guess(v_player, v_cid1, 'what', 'Ramen');
  PERFORM test_helpers.expire_challenge(v_cid1);
  PERFORM test_helpers.reveal(v_poster, v_cid1);  -- cid1 now 'revealed'; constraint clears

  -- Create a score_run for cid2 to have something to mismatch against
  v_cid2   := test_helpers.make_draft_challenge(v_poster, v_group);
  PERFORM test_helpers.activate(v_poster, v_cid2);
  PERFORM test_helpers.expire_challenge(v_cid2);

  SET LOCAL ROLE forkensics_executor;
  INSERT INTO public.score_runs (challenge_id, revision_number, rules_version_id, effective_eligible_count)
  VALUES (v_cid2, 1, 'a0000000-0000-0000-0000-000000000001', 1)
  RETURNING id INTO v_run_id;

  BEGIN
    INSERT INTO public.guess_judgments (
      score_run_id, guess_attempt_id, player_id, challenge_id,
      race, rules_version_id, is_correct, is_first_correct_for_player
    ) VALUES (
      v_run_id, v_ga_id, v_player, v_cid2,  -- challenge_id mismatches guess_attempt's cid1
      'what', 'a0000000-0000-0000-0000-000000000001', false, false
    );
  EXCEPTION
    WHEN raise_exception THEN v_caught := true;  -- check_judgment_consistency BEFORE trigger (P0001)
    WHEN OTHERS THEN RAISE EXCEPTION 'unexpected SQLSTATE % — %', SQLSTATE, SQLERRM;
  END;
  RESET ROLE;
  PERFORM test_helpers.assert(v_caught, '16.4: judgment challenge_id mismatch — rejected');
END;
$$;

-- 16.5: judgment player_id mismatch — rejected
DO $$
DECLARE
  v_poster uuid; v_player1 uuid; v_player2 uuid; v_group uuid;
  v_cid uuid; v_run_id uuid; v_ga_id uuid; v_caught boolean := false;
BEGIN
  v_poster  := test_helpers.make_user('JPMPoster');
  v_player1 := test_helpers.make_user('JPMPlayer1');
  v_player2 := test_helpers.make_user('JPMPlayer2');
  v_group   := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_player1);
  PERFORM test_helpers.add_member(v_group, v_poster, v_player2);
  v_cid    := test_helpers.make_draft_challenge(v_poster, v_group);
  PERFORM test_helpers.activate(v_poster, v_cid);
  v_ga_id  := test_helpers.make_guess(v_player1, v_cid, 'what', 'Ramen');
  PERFORM test_helpers.expire_challenge(v_cid);

  SET LOCAL ROLE forkensics_executor;
  INSERT INTO public.score_runs (challenge_id, revision_number, rules_version_id, effective_eligible_count)
  VALUES (v_cid, 1, 'a0000000-0000-0000-0000-000000000001', 2)
  RETURNING id INTO v_run_id;

  BEGIN
    INSERT INTO public.guess_judgments (
      score_run_id, guess_attempt_id, player_id, challenge_id,
      race, rules_version_id, is_correct, is_first_correct_for_player
    ) VALUES (
      v_run_id, v_ga_id, v_player2, v_cid,  -- player_id mismatches guess_attempt's player1
      'what', 'a0000000-0000-0000-0000-000000000001', false, false
    );
  EXCEPTION
    WHEN raise_exception THEN v_caught := true;  -- check_judgment_consistency BEFORE trigger (P0001)
    WHEN OTHERS THEN RAISE EXCEPTION 'unexpected SQLSTATE % — %', SQLSTATE, SQLERRM;
  END;
  RESET ROLE;
  PERFORM test_helpers.assert(v_caught, '16.5: judgment player_id mismatch — rejected');
END;
$$;

-- 16.6: score event for excluded player — rejected
DO $$
DECLARE
  v_poster uuid; v_player uuid; v_group uuid; v_cid uuid;
  v_run_id uuid; v_caught boolean := false;
BEGIN
  v_poster := test_helpers.make_user('SEExclPoster');
  v_player := test_helpers.make_user('SEExclPlayer');
  v_group  := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_player);
  v_cid := test_helpers.make_draft_challenge(v_poster, v_group);
  PERFORM test_helpers.activate(v_poster, v_cid);

  -- Exclude player
  PERFORM test_helpers.set_auth_uid(v_player);
  INSERT INTO public.exclusion_events (challenge_id, player_id, reason, excluded_by)
  VALUES (v_cid, v_player, 'withdrew', v_player);
  PERFORM test_helpers.clear_auth_uid();

  PERFORM test_helpers.expire_challenge(v_cid);

  SET LOCAL ROLE forkensics_executor;
  INSERT INTO public.score_runs (challenge_id, revision_number, rules_version_id, effective_eligible_count)
  VALUES (v_cid, 1, 'a0000000-0000-0000-0000-000000000001', 0)
  RETURNING id INTO v_run_id;

  BEGIN
    INSERT INTO public.score_events (
      score_run_id, challenge_id, player_id, rules_version_id, what_points, where_points
    ) VALUES (
      v_run_id, v_cid, v_player, 'a0000000-0000-0000-0000-000000000001', 0, 0
    );
  EXCEPTION
    WHEN raise_exception THEN v_caught := true;  -- check_score_event_consistency BEFORE trigger (P0001)
    WHEN OTHERS THEN RAISE EXCEPTION 'unexpected SQLSTATE % — %', SQLSTATE, SQLERRM;
  END;
  RESET ROLE;
  PERFORM test_helpers.assert(v_caught, '16.6: score event for excluded player — rejected');
END;
$$;

-- 16.7: score event challenge_id mismatch with score_run — rejected
DO $$
DECLARE
  v_poster uuid; v_player uuid; v_group uuid;
  v_cid1 uuid; v_cid2 uuid; v_run_id uuid; v_caught boolean := false;
BEGIN
  v_poster := test_helpers.make_user('SECMPoster');
  v_player := test_helpers.make_user('SECMPlayer');
  v_group  := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_player);
  -- Fully reveal cid1 first so poster can create cid2 (one_active_challenge_per_poster)
  v_cid1 := test_helpers.make_draft_challenge(v_poster, v_group);
  PERFORM test_helpers.activate(v_poster, v_cid1);
  PERFORM test_helpers.expire_challenge(v_cid1);
  PERFORM test_helpers.reveal(v_poster, v_cid1);  -- cid1 now 'revealed'; constraint clears
  v_cid2 := test_helpers.make_draft_challenge(v_poster, v_group);

  SET LOCAL ROLE forkensics_executor;
  -- revision 1 was created by reveal_challenge; use revision 2 to avoid conflict
  INSERT INTO public.score_runs (challenge_id, revision_number, rules_version_id, effective_eligible_count)
  VALUES (v_cid1, 2, 'a0000000-0000-0000-0000-000000000001', 1)
  RETURNING id INTO v_run_id;

  BEGIN
    INSERT INTO public.score_events (
      score_run_id, challenge_id, player_id, rules_version_id, what_points, where_points
    ) VALUES (
      v_run_id, v_cid2, v_player, 'a0000000-0000-0000-0000-000000000001', 0, 0  -- cid2 mismatches run's cid1
    );
  EXCEPTION
    WHEN raise_exception THEN v_caught := true;  -- check_score_event_consistency BEFORE trigger (P0001)
    WHEN OTHERS THEN RAISE EXCEPTION 'unexpected SQLSTATE % — %', SQLSTATE, SQLERRM;
  END;
  RESET ROLE;
  PERFORM test_helpers.assert(v_caught, '16.7: score event challenge_id mismatches score_run — rejected');
END;
$$;

-- 16.8: valid positive judgment INSERT succeeds
DO $$
DECLARE
  v_poster uuid; v_player uuid; v_group uuid; v_cid uuid;
  v_run_id uuid; v_ga_id uuid;
BEGIN
  v_poster := test_helpers.make_user('JVPoster');
  v_player := test_helpers.make_user('JVPlayer');
  v_group  := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_player);
  v_cid   := test_helpers.make_draft_challenge(v_poster, v_group);
  PERFORM test_helpers.activate(v_poster, v_cid);
  v_ga_id := test_helpers.make_guess(v_player, v_cid, 'what', 'Ramen');
  PERFORM test_helpers.expire_challenge(v_cid);

  SET LOCAL ROLE forkensics_executor;
  INSERT INTO public.score_runs (challenge_id, revision_number, rules_version_id, effective_eligible_count)
  VALUES (v_cid, 1, 'a0000000-0000-0000-0000-000000000001', 1)
  RETURNING id INTO v_run_id;
  INSERT INTO public.guess_judgments (
    score_run_id, guess_attempt_id, player_id, challenge_id,
    race, rules_version_id, is_correct, is_first_correct_for_player
  ) VALUES (
    v_run_id, v_ga_id, v_player, v_cid,
    'what', 'a0000000-0000-0000-0000-000000000001', false, false
  );
  RESET ROLE;
  PERFORM test_helpers.assert(true, '16.8: valid judgment INSERT succeeds');
END;
$$;

-- 16.9: valid positive score_event INSERT succeeds
DO $$
DECLARE
  v_poster uuid; v_player uuid; v_group uuid; v_cid uuid; v_run_id uuid;
BEGIN
  v_poster := test_helpers.make_user('SEVPoster');
  v_player := test_helpers.make_user('SEVPlayer');
  v_group  := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_player);
  v_cid := test_helpers.make_draft_challenge(v_poster, v_group);
  PERFORM test_helpers.activate(v_poster, v_cid);  -- creates eligible_participants
  PERFORM test_helpers.expire_challenge(v_cid);

  SET LOCAL ROLE forkensics_executor;
  INSERT INTO public.score_runs (challenge_id, revision_number, rules_version_id, effective_eligible_count)
  VALUES (v_cid, 1, 'a0000000-0000-0000-0000-000000000001', 1)
  RETURNING id INTO v_run_id;
  INSERT INTO public.score_events (
    score_run_id, challenge_id, player_id, rules_version_id, what_points, where_points
  ) VALUES (
    v_run_id, v_cid, v_player, 'a0000000-0000-0000-0000-000000000001', 10, 5
  );
  RESET ROLE;
  PERFORM test_helpers.assert(true, '16.9: valid score_event INSERT succeeds');
END;
$$;

-- 16.10: judgment race mismatch with guess_attempt — rejected
DO $$
DECLARE
  v_poster uuid; v_player uuid; v_group uuid; v_cid uuid;
  v_run_id uuid; v_ga_id uuid; v_caught boolean := false;
BEGIN
  v_poster := test_helpers.make_user('JRacePoster');
  v_player := test_helpers.make_user('JRacePlayer');
  v_group  := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_player);
  v_cid   := test_helpers.make_draft_challenge(v_poster, v_group);
  PERFORM test_helpers.activate(v_poster, v_cid);
  v_ga_id := test_helpers.make_guess(v_player, v_cid, 'what', 'Ramen');  -- race = 'what'
  PERFORM test_helpers.expire_challenge(v_cid);

  SET LOCAL ROLE forkensics_executor;
  INSERT INTO public.score_runs (challenge_id, revision_number, rules_version_id, effective_eligible_count)
  VALUES (v_cid, 1, 'a0000000-0000-0000-0000-000000000001', 1)
  RETURNING id INTO v_run_id;
  BEGIN
    INSERT INTO public.guess_judgments (
      score_run_id, guess_attempt_id, player_id, challenge_id,
      race, rules_version_id, is_correct, is_first_correct_for_player
    ) VALUES (
      v_run_id, v_ga_id, v_player, v_cid,
      'where', 'a0000000-0000-0000-0000-000000000001', false, false  -- race mismatch: 'where' vs 'what'
    );
  EXCEPTION
    WHEN raise_exception THEN v_caught := true;  -- check_judgment_consistency BEFORE trigger (P0001)
    WHEN OTHERS THEN RAISE EXCEPTION 'unexpected SQLSTATE % — %', SQLSTATE, SQLERRM;
  END;
  RESET ROLE;
  PERFORM test_helpers.assert(v_caught, '16.10: judgment race mismatch — rejected');
END;
$$;

-- 16.11: judgment rules_version_id mismatch with score_run — rejected
-- BEFORE trigger fires before FK check; mismatched UUID never reaches constraint
DO $$
DECLARE
  v_poster uuid; v_player uuid; v_group uuid; v_cid uuid;
  v_run_id uuid; v_ga_id uuid; v_caught boolean := false;
BEGIN
  v_poster := test_helpers.make_user('JRVPoster');
  v_player := test_helpers.make_user('JRVPlayer');
  v_group  := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_player);
  v_cid   := test_helpers.make_draft_challenge(v_poster, v_group);
  PERFORM test_helpers.activate(v_poster, v_cid);
  v_ga_id := test_helpers.make_guess(v_player, v_cid, 'what', 'Ramen');
  PERFORM test_helpers.expire_challenge(v_cid);

  SET LOCAL ROLE forkensics_executor;
  INSERT INTO public.score_runs (challenge_id, revision_number, rules_version_id, effective_eligible_count)
  VALUES (v_cid, 1, 'a0000000-0000-0000-0000-000000000001', 1)
  RETURNING id INTO v_run_id;
  BEGIN
    INSERT INTO public.guess_judgments (
      score_run_id, guess_attempt_id, player_id, challenge_id,
      race, rules_version_id, is_correct, is_first_correct_for_player
    ) VALUES (
      v_run_id, v_ga_id, v_player, v_cid,
      'what', 'b0000000-0000-0000-0000-000000000001', false, false  -- rules_version mismatch
    );
  EXCEPTION
    WHEN raise_exception THEN v_caught := true;  -- check_judgment_consistency catches mismatch (P0001)
    WHEN OTHERS THEN RAISE EXCEPTION 'unexpected SQLSTATE % — %', SQLSTATE, SQLERRM;
  END;
  RESET ROLE;
  PERFORM test_helpers.assert(v_caught, '16.11: judgment rules_version_id mismatch — rejected');
END;
$$;

-- 16.12: score event rules_version_id mismatch with score_run — rejected
DO $$
DECLARE
  v_poster uuid; v_player uuid; v_group uuid; v_cid uuid;
  v_run_id uuid; v_caught boolean := false;
BEGIN
  v_poster := test_helpers.make_user('SERVPoster');
  v_player := test_helpers.make_user('SERVPlayer');
  v_group  := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_player);
  v_cid := test_helpers.make_draft_challenge(v_poster, v_group);
  PERFORM test_helpers.activate(v_poster, v_cid);
  PERFORM test_helpers.expire_challenge(v_cid);

  SET LOCAL ROLE forkensics_executor;
  INSERT INTO public.score_runs (challenge_id, revision_number, rules_version_id, effective_eligible_count)
  VALUES (v_cid, 1, 'a0000000-0000-0000-0000-000000000001', 1)
  RETURNING id INTO v_run_id;
  BEGIN
    INSERT INTO public.score_events (
      score_run_id, challenge_id, player_id, rules_version_id, what_points, where_points
    ) VALUES (
      v_run_id, v_cid, v_player, 'b0000000-0000-0000-0000-000000000001', 0, 0  -- rules_version mismatch
    );
  EXCEPTION
    WHEN raise_exception THEN v_caught := true;  -- check_score_event_consistency catches mismatch (P0001)
    WHEN OTHERS THEN RAISE EXCEPTION 'unexpected SQLSTATE % — %', SQLSTATE, SQLERRM;
  END;
  RESET ROLE;
  PERFORM test_helpers.assert(v_caught, '16.12: score event rules_version_id mismatch — rejected');
END;
$$;

-- 16.13: score event for player not in eligible_participants — rejected
DO $$
DECLARE
  v_poster  uuid; v_player uuid; v_stranger uuid; v_group uuid; v_cid uuid;
  v_run_id  uuid; v_caught boolean := false;
BEGIN
  v_poster   := test_helpers.make_user('SENEPoster');
  v_player   := test_helpers.make_user('SENEPlayer');
  v_stranger := test_helpers.make_user('SENEStranger');  -- never added to group
  v_group    := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_player);
  -- v_stranger is NOT added → not in eligible_participants after activation
  v_cid := test_helpers.make_draft_challenge(v_poster, v_group);
  PERFORM test_helpers.activate(v_poster, v_cid);
  PERFORM test_helpers.expire_challenge(v_cid);

  SET LOCAL ROLE forkensics_executor;
  INSERT INTO public.score_runs (challenge_id, revision_number, rules_version_id, effective_eligible_count)
  VALUES (v_cid, 1, 'a0000000-0000-0000-0000-000000000001', 1)
  RETURNING id INTO v_run_id;
  BEGIN
    INSERT INTO public.score_events (
      score_run_id, challenge_id, player_id, rules_version_id, what_points, where_points
    ) VALUES (
      v_run_id, v_cid, v_stranger, 'a0000000-0000-0000-0000-000000000001', 0, 0
    );
  EXCEPTION
    WHEN raise_exception THEN v_caught := true;  -- check_score_event_consistency: not eligible (P0001)
    WHEN OTHERS THEN RAISE EXCEPTION 'unexpected SQLSTATE % — %', SQLSTATE, SQLERRM;
  END;
  RESET ROLE;
  PERFORM test_helpers.assert(v_caught, '16.13: score event for non-eligible player — rejected');
END;
$$;

-- =============================================================================
-- GROUP 17: apply_correction() PARAMETER CONTRACT
-- =============================================================================
\echo ''
\echo '--- GROUP 17: apply_correction() Contract ---'

-- 17.1: alias_id supplied for answer_changed — rejected
DO $$
DECLARE
  v_poster uuid; v_player uuid; v_group uuid; v_cid uuid;
  v_alias_id uuid; v_caught boolean := false;
BEGIN
  v_poster := test_helpers.make_user('ACACPoster');
  v_player := test_helpers.make_user('ACACPlayer');
  v_group  := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_player);
  v_cid := test_helpers.make_draft_challenge(v_poster, v_group);
  PERFORM test_helpers.activate(v_poster, v_cid);
  PERFORM test_helpers.make_guess(v_player, v_cid, 'what', 'Ramen');
  PERFORM test_helpers.expire_challenge(v_cid);
  PERFORM test_helpers.reveal(v_poster, v_cid);

  -- Add an alias so we have a valid UUID to pass
  PERFORM test_helpers.set_auth_uid(v_poster);
  BEGIN
    PERFORM public.apply_correction(v_cid, 'answer_changed', 'dish', 'New Ramen', gen_random_uuid(), 'test');
  EXCEPTION
    WHEN raise_exception THEN v_caught := true;  -- apply_correction parameter validation (P0001)
    WHEN OTHERS THEN RAISE EXCEPTION 'unexpected SQLSTATE % — %', SQLSTATE, SQLERRM;
  END;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_caught, '17.1: alias_id non-NULL for answer_changed — rejected');
END;
$$;

-- 17.2: new_display_value supplied for alias_removed — rejected
DO $$
DECLARE
  v_poster uuid; v_player uuid; v_group uuid; v_cid uuid;
  v_alias_id uuid; v_caught boolean := false;
BEGIN
  v_poster := test_helpers.make_user('ACARPoster');
  v_player := test_helpers.make_user('ACARPlayer');
  v_group  := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_player);
  v_cid := test_helpers.make_draft_challenge(v_poster, v_group);
  PERFORM test_helpers.activate(v_poster, v_cid);
  PERFORM test_helpers.make_guess(v_player, v_cid, 'what', 'Ramen');
  PERFORM test_helpers.expire_challenge(v_cid);
  PERFORM test_helpers.reveal(v_poster, v_cid);

  -- Add an alias to remove
  PERFORM test_helpers.set_auth_uid(v_poster);
  PERFORM public.apply_correction(v_cid, 'alias_added', 'dish', 'Noodle Soup', NULL, 'add alias');
  SELECT id INTO v_alias_id FROM public.challenge_answer_aliases
  WHERE challenge_id = v_cid AND field = 'dish' AND is_active = true LIMIT 1;

  BEGIN
    PERFORM public.apply_correction(v_cid, 'alias_removed', 'dish', 'Some Value', v_alias_id, 'remove');
  EXCEPTION
    WHEN raise_exception THEN v_caught := true;  -- apply_correction parameter validation (P0001)
    WHEN OTHERS THEN RAISE EXCEPTION 'unexpected SQLSTATE % — %', SQLSTATE, SQLERRM;
  END;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_caught, '17.2: new_display_value non-NULL for alias_removed — rejected');
END;
$$;

-- 17.3: 'city' is no longer a valid target_field for apply_correction — rejected
DO $$
DECLARE
  v_poster uuid; v_player uuid; v_group uuid; v_cid uuid; v_caught boolean := false;
BEGIN
  v_poster := test_helpers.make_user('ACCityPoster');
  v_player := test_helpers.make_user('ACCityPlayer');
  v_group  := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_player);
  v_cid := test_helpers.make_draft_challenge(v_poster, v_group);
  PERFORM test_helpers.activate(v_poster, v_cid);
  PERFORM test_helpers.make_guess(v_player, v_cid, 'where', NULL, 'Ichiran');
  PERFORM test_helpers.expire_challenge(v_cid);
  PERFORM test_helpers.reveal(v_poster, v_cid);

  PERFORM test_helpers.set_auth_uid(v_poster);
  BEGIN
    PERFORM public.apply_correction(v_cid, 'answer_changed', 'city', 'Tokyo', NULL, 'city not a scored field');
  EXCEPTION
    WHEN raise_exception THEN v_caught := true;  -- invalid target_field (P0001)
    WHEN OTHERS THEN RAISE EXCEPTION 'unexpected SQLSTATE % — %', SQLSTATE, SQLERRM;
  END;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_caught, '17.3: city target_field rejected by apply_correction (P0001)');
END;
$$;

-- 17.4: duplicate active alias same normalized value — rejected
DO $$
DECLARE
  v_poster uuid; v_player uuid; v_group uuid; v_cid uuid; v_caught boolean := false;
BEGIN
  v_poster := test_helpers.make_user('ACDupPoster');
  v_player := test_helpers.make_user('ACDupPlayer');
  v_group  := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_player);
  v_cid := test_helpers.make_draft_challenge(v_poster, v_group);
  PERFORM test_helpers.activate(v_poster, v_cid);
  PERFORM test_helpers.make_guess(v_player, v_cid, 'what', 'Ramen');
  PERFORM test_helpers.expire_challenge(v_cid);
  PERFORM test_helpers.reveal(v_poster, v_cid);

  PERFORM test_helpers.set_auth_uid(v_poster);
  PERFORM public.apply_correction(v_cid, 'alias_added', 'dish', 'Noodle Soup', NULL, 'first alias');
  BEGIN
    -- Same text but with punctuation that normalizes to same value
    PERFORM public.apply_correction(v_cid, 'alias_added', 'dish', 'Noodle Soup!', NULL, 'dup alias');
  EXCEPTION
    WHEN raise_exception THEN v_caught := true;  -- apply_correction duplicate check (P0001)
    WHEN OTHERS THEN RAISE EXCEPTION 'unexpected SQLSTATE % — %', SQLSTATE, SQLERRM;
  END;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_caught, '17.4: duplicate active alias (same normalized) — rejected');
END;
$$;

-- 17.5: alias_removed audit records alias values, not canonical answer values
DO $$
DECLARE
  v_poster uuid; v_player uuid; v_group uuid; v_cid uuid;
  v_alias_id uuid; v_ce record;
BEGIN
  v_poster := test_helpers.make_user('ACAuditPoster');
  v_player := test_helpers.make_user('ACAuditPlayer');
  v_group  := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_player);
  v_cid := test_helpers.make_draft_challenge(v_poster, v_group, 'Ramen', 'Ichiran', 'Tokyo');
  PERFORM test_helpers.activate(v_poster, v_cid);
  PERFORM test_helpers.make_guess(v_player, v_cid, 'what', 'Ramen');
  PERFORM test_helpers.expire_challenge(v_cid);
  PERFORM test_helpers.reveal(v_poster, v_cid);

  PERFORM test_helpers.set_auth_uid(v_poster);
  -- Add an alias with a distinct display value
  PERFORM public.apply_correction(v_cid, 'alias_added', 'dish', 'Japanese Noodles', NULL, 'add alias');
  SELECT id INTO v_alias_id FROM public.challenge_answer_aliases
  WHERE challenge_id = v_cid AND field = 'dish' AND is_active = true LIMIT 1;

  -- Remove the alias
  PERFORM public.apply_correction(v_cid, 'alias_removed', 'dish', NULL, v_alias_id, 'remove alias');
  PERFORM test_helpers.clear_auth_uid();

  -- Verify correction event records the alias's display value, not 'Ramen' (canonical)
  SELECT * INTO v_ce FROM public.correction_events
  WHERE challenge_id = v_cid AND action = 'alias_removed'
  ORDER BY corrected_at DESC LIMIT 1;

  PERFORM test_helpers.assert(
    v_ce.old_display_value = 'Japanese Noodles',
    '17.5a: alias_removed audit records alias display_value (not canonical)'
  );
  PERFORM test_helpers.assert(
    v_ce.new_display_value IS NULL,
    '17.5b: alias_removed audit new_display_value is NULL'
  );
  PERFORM test_helpers.assert(
    v_ce.old_normalized_value = 'japanese noodles',
    '17.5c: alias_removed audit records alias normalized_value'
  );
END;
$$;

-- 17.6: alias_id supplied for alias_added — rejected
DO $$
DECLARE
  v_poster uuid; v_player uuid; v_group uuid; v_cid uuid; v_caught boolean := false;
BEGIN
  v_poster := test_helpers.make_user('ACAAddPoster');
  v_player := test_helpers.make_user('ACAAddPlayer');
  v_group  := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_player);
  v_cid := test_helpers.make_draft_challenge(v_poster, v_group);
  PERFORM test_helpers.activate(v_poster, v_cid);
  PERFORM test_helpers.make_guess(v_player, v_cid, 'what', 'Ramen');
  PERFORM test_helpers.expire_challenge(v_cid);
  PERFORM test_helpers.reveal(v_poster, v_cid);

  PERFORM test_helpers.set_auth_uid(v_poster);
  BEGIN
    PERFORM public.apply_correction(v_cid, 'alias_added', 'dish', 'Noodle', gen_random_uuid(), 'test');
  EXCEPTION
    WHEN raise_exception THEN v_caught := true;
    WHEN OTHERS THEN RAISE EXCEPTION 'unexpected SQLSTATE % — %', SQLSTATE, SQLERRM;
  END;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_caught, '17.6: alias_id non-NULL for alias_added — rejected');
END;
$$;

-- 17.7: alias_id missing for alias_removed — rejected
DO $$
DECLARE
  v_poster uuid; v_player uuid; v_group uuid; v_cid uuid; v_caught boolean := false;
BEGIN
  v_poster := test_helpers.make_user('ACARemMPoster');
  v_player := test_helpers.make_user('ACARemMPlayer');
  v_group  := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_player);
  v_cid := test_helpers.make_draft_challenge(v_poster, v_group);
  PERFORM test_helpers.activate(v_poster, v_cid);
  PERFORM test_helpers.make_guess(v_player, v_cid, 'what', 'Ramen');
  PERFORM test_helpers.expire_challenge(v_cid);
  PERFORM test_helpers.reveal(v_poster, v_cid);

  PERFORM test_helpers.set_auth_uid(v_poster);
  BEGIN
    PERFORM public.apply_correction(v_cid, 'alias_removed', 'dish', NULL, NULL, 'test');  -- no alias_id
  EXCEPTION
    WHEN raise_exception THEN v_caught := true;
    WHEN OTHERS THEN RAISE EXCEPTION 'unexpected SQLSTATE % — %', SQLSTATE, SQLERRM;
  END;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_caught, '17.7: alias_id NULL for alias_removed — rejected');
END;
$$;

-- 17.8: missing display_value for answer_changed — rejected
DO $$
DECLARE
  v_poster uuid; v_player uuid; v_group uuid; v_cid uuid; v_caught boolean := false;
BEGIN
  v_poster := test_helpers.make_user('ACMDVPoster');
  v_player := test_helpers.make_user('ACMDVPlayer');
  v_group  := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_player);
  v_cid := test_helpers.make_draft_challenge(v_poster, v_group);
  PERFORM test_helpers.activate(v_poster, v_cid);
  PERFORM test_helpers.make_guess(v_player, v_cid, 'what', 'Ramen');
  PERFORM test_helpers.expire_challenge(v_cid);
  PERFORM test_helpers.reveal(v_poster, v_cid);

  PERFORM test_helpers.set_auth_uid(v_poster);
  BEGIN
    PERFORM public.apply_correction(v_cid, 'answer_changed', 'dish', NULL, NULL, 'test');  -- NULL display_value
  EXCEPTION
    WHEN raise_exception THEN v_caught := true;
    WHEN OTHERS THEN RAISE EXCEPTION 'unexpected SQLSTATE % — %', SQLSTATE, SQLERRM;
  END;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_caught, '17.8: NULL display_value for answer_changed — rejected');
END;
$$;

-- 17.9: missing display_value for alias_added — rejected
DO $$
DECLARE
  v_poster uuid; v_player uuid; v_group uuid; v_cid uuid; v_caught boolean := false;
BEGIN
  v_poster := test_helpers.make_user('ACMDVAPoster');
  v_player := test_helpers.make_user('ACMDVAPlayer');
  v_group  := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_player);
  v_cid := test_helpers.make_draft_challenge(v_poster, v_group);
  PERFORM test_helpers.activate(v_poster, v_cid);
  PERFORM test_helpers.make_guess(v_player, v_cid, 'what', 'Ramen');
  PERFORM test_helpers.expire_challenge(v_cid);
  PERFORM test_helpers.reveal(v_poster, v_cid);

  PERFORM test_helpers.set_auth_uid(v_poster);
  BEGIN
    PERFORM public.apply_correction(v_cid, 'alias_added', 'dish', NULL, NULL, 'test');  -- NULL display_value
  EXCEPTION
    WHEN raise_exception THEN v_caught := true;
    WHEN OTHERS THEN RAISE EXCEPTION 'unexpected SQLSTATE % — %', SQLSTATE, SQLERRM;
  END;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_caught, '17.9: NULL display_value for alias_added — rejected');
END;
$$;

-- 17.10: empty normalized result — rejected
-- A display_value that normalizes to empty string (e.g. pure punctuation)
DO $$
DECLARE
  v_poster uuid; v_player uuid; v_group uuid; v_cid uuid; v_caught boolean := false;
BEGIN
  v_poster := test_helpers.make_user('ACENPoster');
  v_player := test_helpers.make_user('ACENPlayer');
  v_group  := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_player);
  v_cid := test_helpers.make_draft_challenge(v_poster, v_group);
  PERFORM test_helpers.activate(v_poster, v_cid);
  PERFORM test_helpers.make_guess(v_player, v_cid, 'what', 'Ramen');
  PERFORM test_helpers.expire_challenge(v_cid);
  PERFORM test_helpers.reveal(v_poster, v_cid);

  PERFORM test_helpers.set_auth_uid(v_poster);
  BEGIN
    -- Pure punctuation normalizes to '' (empty after stripping non-alphanumeric)
    PERFORM public.apply_correction(v_cid, 'answer_changed', 'dish', '!!! ---', NULL, 'test');
  EXCEPTION
    WHEN raise_exception THEN v_caught := true;
    WHEN OTHERS THEN RAISE EXCEPTION 'unexpected SQLSTATE % — %', SQLSTATE, SQLERRM;
  END;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_caught, '17.10: empty normalized result — rejected');
END;
$$;

-- 17.11: dish display_value > 200 chars — rejected
DO $$
DECLARE
  v_poster uuid; v_player uuid; v_group uuid; v_cid uuid; v_caught boolean := false;
BEGIN
  v_poster := test_helpers.make_user('ACMaxPoster');
  v_player := test_helpers.make_user('ACMaxPlayer');
  v_group  := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_player);
  v_cid := test_helpers.make_draft_challenge(v_poster, v_group);
  PERFORM test_helpers.activate(v_poster, v_cid);
  PERFORM test_helpers.make_guess(v_player, v_cid, 'what', 'Ramen');
  PERFORM test_helpers.expire_challenge(v_cid);
  PERFORM test_helpers.reveal(v_poster, v_cid);

  PERFORM test_helpers.set_auth_uid(v_poster);
  BEGIN
    PERFORM public.apply_correction(v_cid, 'answer_changed', 'dish', repeat('a', 201), NULL, 'too long');
  EXCEPTION
    WHEN raise_exception THEN v_caught := true;
    WHEN OTHERS THEN RAISE EXCEPTION 'unexpected SQLSTATE % — %', SQLSTATE, SQLERRM;
  END;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_caught, '17.11: dish display_value > 200 chars — rejected');
END;
$$;

-- 17.12: alias_removed for alias belonging to wrong challenge — rejected
DO $$
DECLARE
  v_poster uuid; v_player uuid; v_group uuid;
  v_cid1 uuid; v_cid2 uuid; v_alias_id uuid; v_caught boolean := false;
BEGIN
  v_poster := test_helpers.make_user('ACWCPoster');
  v_player := test_helpers.make_user('ACWCPlayer');
  v_group  := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_player);

  -- Reveal cid1, add alias to it
  v_cid1 := test_helpers.make_draft_challenge(v_poster, v_group);
  PERFORM test_helpers.activate(v_poster, v_cid1);
  PERFORM test_helpers.make_guess(v_player, v_cid1, 'what', 'Ramen');
  PERFORM test_helpers.expire_challenge(v_cid1);
  PERFORM test_helpers.reveal(v_poster, v_cid1);

  PERFORM test_helpers.set_auth_uid(v_poster);
  PERFORM public.apply_correction(v_cid1, 'alias_added', 'dish', 'Noodle Soup', NULL, 'add');
  SELECT id INTO v_alias_id FROM public.challenge_answer_aliases
  WHERE challenge_id = v_cid1 AND field = 'dish' AND is_active = true LIMIT 1;
  PERFORM test_helpers.clear_auth_uid();

  -- Create and reveal cid2 (clears one_active_challenge_per_poster)
  v_cid2 := test_helpers.make_draft_challenge(v_poster, v_group);
  PERFORM test_helpers.activate(v_poster, v_cid2);
  PERFORM test_helpers.make_guess(v_player, v_cid2, 'what', 'Ramen');
  PERFORM test_helpers.expire_challenge(v_cid2);
  PERFORM test_helpers.reveal(v_poster, v_cid2);

  -- Try to remove cid1's alias via cid2 context
  PERFORM test_helpers.set_auth_uid(v_poster);
  BEGIN
    PERFORM public.apply_correction(v_cid2, 'alias_removed', 'dish', NULL, v_alias_id, 'wrong challenge');
  EXCEPTION
    WHEN raise_exception THEN v_caught := true;  -- alias not found for cid2
    WHEN OTHERS THEN RAISE EXCEPTION 'unexpected SQLSTATE % — %', SQLSTATE, SQLERRM;
  END;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_caught, '17.12: alias_removed for alias on wrong challenge — rejected');
END;
$$;

-- 17.13: alias_removed for alias with wrong field — rejected
DO $$
DECLARE
  v_poster uuid; v_player uuid; v_group uuid; v_cid uuid;
  v_alias_id uuid; v_caught boolean := false;
BEGIN
  v_poster := test_helpers.make_user('ACWFPoster');
  v_player := test_helpers.make_user('ACWFPlayer');
  v_group  := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_player);
  v_cid := test_helpers.make_draft_challenge(v_poster, v_group, 'Ramen', 'Ichiran', 'Tokyo');
  PERFORM test_helpers.activate(v_poster, v_cid);
  PERFORM test_helpers.make_guess(v_player, v_cid, 'what', 'Ramen');
  PERFORM test_helpers.expire_challenge(v_cid);
  PERFORM test_helpers.reveal(v_poster, v_cid);

  PERFORM test_helpers.set_auth_uid(v_poster);
  -- Add alias for 'dish' field
  PERFORM public.apply_correction(v_cid, 'alias_added', 'dish', 'Noodle', NULL, 'add');
  SELECT id INTO v_alias_id FROM public.challenge_answer_aliases
  WHERE challenge_id = v_cid AND field = 'dish' AND is_active = true LIMIT 1;

  BEGIN
    -- Try to remove it using wrong field ('restaurant' instead of 'dish')
    PERFORM public.apply_correction(v_cid, 'alias_removed', 'restaurant', NULL, v_alias_id, 'wrong field');
  EXCEPTION
    WHEN raise_exception THEN v_caught := true;  -- alias not found for this field
    WHEN OTHERS THEN RAISE EXCEPTION 'unexpected SQLSTATE % — %', SQLSTATE, SQLERRM;
  END;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_caught, '17.13: alias_removed with wrong field — rejected');
END;
$$;

-- 17.14: already-inactive alias removal — rejected
DO $$
DECLARE
  v_poster uuid; v_player uuid; v_group uuid; v_cid uuid;
  v_alias_id uuid; v_caught boolean := false;
BEGIN
  v_poster := test_helpers.make_user('ACIALPoster');
  v_player := test_helpers.make_user('ACIALPlayer');
  v_group  := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_player);
  v_cid := test_helpers.make_draft_challenge(v_poster, v_group);
  PERFORM test_helpers.activate(v_poster, v_cid);
  PERFORM test_helpers.make_guess(v_player, v_cid, 'what', 'Ramen');
  PERFORM test_helpers.expire_challenge(v_cid);
  PERFORM test_helpers.reveal(v_poster, v_cid);

  PERFORM test_helpers.set_auth_uid(v_poster);
  -- Add and immediately remove an alias
  PERFORM public.apply_correction(v_cid, 'alias_added', 'dish', 'Noodle Soup', NULL, 'add');
  SELECT id INTO v_alias_id FROM public.challenge_answer_aliases
  WHERE challenge_id = v_cid AND field = 'dish' AND is_active = true LIMIT 1;
  PERFORM public.apply_correction(v_cid, 'alias_removed', 'dish', NULL, v_alias_id, 'first remove');

  -- Try to remove it AGAIN (now is_active = false)
  BEGIN
    PERFORM public.apply_correction(v_cid, 'alias_removed', 'dish', NULL, v_alias_id, 'second remove');
  EXCEPTION
    WHEN raise_exception THEN v_caught := true;  -- alias not found (is_active = false)
    WHEN OTHERS THEN RAISE EXCEPTION 'unexpected SQLSTATE % — %', SQLSTATE, SQLERRM;
  END;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_caught, '17.14: removing already-inactive alias — rejected');
END;
$$;

-- 17.15: atomic rollback — failed correction leaves no extra correction_event
-- A failed apply_correction (duplicate alias) must not persist a partial correction_event.
DO $$
DECLARE
  v_poster uuid; v_player uuid; v_group uuid; v_cid uuid;
  v_count_before int; v_count_after int; v_caught boolean := false;
BEGIN
  v_poster := test_helpers.make_user('ACAtomPoster');
  v_player := test_helpers.make_user('ACAtomPlayer');
  v_group  := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_player);
  v_cid := test_helpers.make_draft_challenge(v_poster, v_group);
  PERFORM test_helpers.activate(v_poster, v_cid);
  PERFORM test_helpers.make_guess(v_player, v_cid, 'what', 'Ramen');
  PERFORM test_helpers.expire_challenge(v_cid);
  PERFORM test_helpers.reveal(v_poster, v_cid);

  PERFORM test_helpers.set_auth_uid(v_poster);
  -- First correction succeeds: adds alias
  PERFORM public.apply_correction(v_cid, 'alias_added', 'dish', 'Noodle Soup', NULL, 'add');
  SELECT COUNT(*) INTO v_count_before FROM public.correction_events WHERE challenge_id = v_cid;

  -- Second call fails: duplicate normalized value (caught inside apply_correction before any INSERT)
  BEGIN
    PERFORM public.apply_correction(v_cid, 'alias_added', 'dish', 'Noodle Soup!', NULL, 'dup');
  EXCEPTION
    WHEN raise_exception THEN v_caught := true;
    WHEN OTHERS THEN RAISE EXCEPTION 'unexpected SQLSTATE % — %', SQLSTATE, SQLERRM;
  END;
  PERFORM test_helpers.clear_auth_uid();

  SELECT COUNT(*) INTO v_count_after FROM public.correction_events WHERE challenge_id = v_cid;
  PERFORM test_helpers.assert(v_caught, '17.15a: failed apply_correction raises (expected)');
  PERFORM test_helpers.assert(
    v_count_after = v_count_before,
    '17.15b: failed correction left no partial correction_event'
  );
END;
$$;

-- =============================================================================
-- GROUP 18: ACCOUNT-DELETION LIFECYCLE
-- =============================================================================
\echo ''
\echo '--- GROUP 18: Account-Deletion Lifecycle ---'

-- 18.1: prepare_account_deletion cancels draft challenges
DO $$
DECLARE
  v_user uuid; v_group uuid; v_member uuid; v_cid uuid;
BEGIN
  v_user   := test_helpers.make_user('DelDraftUser');
  v_member := test_helpers.make_user('DelDraftMember');
  v_group  := test_helpers.make_group(v_user);
  PERFORM test_helpers.add_member(v_group, v_user, v_member);
  v_cid := test_helpers.make_draft_challenge(v_user, v_group);  -- draft, not yet active

  SET LOCAL ROLE forkensics_executor;
  PERFORM private.prepare_account_deletion(v_user);
  RESET ROLE;

  PERFORM test_helpers.assert(
    EXISTS(SELECT 1 FROM public.challenges WHERE id = v_cid AND state = 'cancelled'),
    '18.1: draft challenge cancelled by prepare_account_deletion'
  );
END;
$$;

-- 18.2: prepare_account_deletion cancels active challenges
DO $$
DECLARE
  v_user uuid; v_member uuid; v_group uuid; v_cid uuid;
BEGIN
  v_user   := test_helpers.make_user('DelActiveUser');
  v_member := test_helpers.make_user('DelActiveMember');
  v_group  := test_helpers.make_group(v_user);
  PERFORM test_helpers.add_member(v_group, v_user, v_member);
  v_cid := test_helpers.make_draft_challenge(v_user, v_group);
  PERFORM test_helpers.activate(v_user, v_cid);

  SET LOCAL ROLE forkensics_executor;
  PERFORM private.prepare_account_deletion(v_user);
  RESET ROLE;

  PERFORM test_helpers.assert(
    EXISTS(SELECT 1 FROM public.challenges WHERE id = v_cid AND state = 'cancelled'),
    '18.2: active challenge cancelled by prepare_account_deletion'
  );
END;
$$;

-- 18.3: prepare_account_deletion adds account_deleted exclusions for active participations
DO $$
DECLARE
  v_poster uuid; v_player uuid; v_group uuid; v_cid uuid;
BEGIN
  v_poster := test_helpers.make_user('DelExclPoster');
  v_player := test_helpers.make_user('DelExclPlayer');
  v_group  := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_player);
  v_cid := test_helpers.make_draft_challenge(v_poster, v_group);
  PERFORM test_helpers.activate(v_poster, v_cid);

  SET LOCAL ROLE forkensics_executor;
  PERFORM private.prepare_account_deletion(v_player);
  RESET ROLE;

  PERFORM test_helpers.assert(
    EXISTS(SELECT 1 FROM public.exclusion_events
           WHERE challenge_id = v_cid AND player_id = v_player AND reason = 'account_deleted'),
    '18.3: account_deleted exclusion inserted for active participation'
  );
END;
$$;

-- 18.4: prepare_account_deletion transfers group ownership to longest-tenured member
DO $$
DECLARE
  v_owner uuid; v_member uuid; v_group uuid;
BEGIN
  v_owner  := test_helpers.make_user('DelOwnUser');
  v_member := test_helpers.make_user('DelOwnMember');
  v_group  := test_helpers.make_group(v_owner);
  PERFORM test_helpers.add_member(v_group, v_owner, v_member);

  SET LOCAL ROLE forkensics_executor;
  PERFORM private.prepare_account_deletion(v_owner);
  RESET ROLE;

  PERFORM test_helpers.assert(
    EXISTS(SELECT 1 FROM public.group_members
           WHERE group_id = v_group AND player_id = v_member AND role = 'owner'),
    '18.4: group ownership transferred to longest-tenured active member'
  );
END;
$$;

-- 18.5: prepare_account_deletion archives group when no eligible successor
DO $$
DECLARE
  v_owner uuid; v_group uuid;
BEGIN
  v_owner := test_helpers.make_user('DelArchUser');
  v_group := test_helpers.make_group(v_owner);  -- owner is the only member

  SET LOCAL ROLE forkensics_executor;
  PERFORM private.prepare_account_deletion(v_owner);
  RESET ROLE;

  PERFORM test_helpers.assert(
    EXISTS(SELECT 1 FROM public.groups WHERE id = v_group AND archived_at IS NOT NULL),
    '18.5: group archived when no successor available'
  );
END;
$$;

-- 18.6: prepare_account_deletion anonymises profile (Former Player, gray, inactive)
DO $$
DECLARE
  v_user uuid; v_group uuid; v_profile record;
BEGIN
  v_user  := test_helpers.make_user('DelAnonUser');
  v_group := test_helpers.make_group(v_user);

  SET LOCAL ROLE forkensics_executor;
  PERFORM private.prepare_account_deletion(v_user);
  RESET ROLE;

  SELECT * INTO v_profile FROM public.profiles WHERE id = v_user;
  PERFORM test_helpers.assert(v_profile.display_name = 'Former Player', '18.6a: display_name = Former Player');
  PERFORM test_helpers.assert(v_profile.avatar_color = 'gray',          '18.6b: avatar_color = gray');
  PERFORM test_helpers.assert(v_profile.is_active    = false,           '18.6c: is_active = false');
  PERFORM test_helpers.assert(v_profile.avatar_media_object_id IS NULL, '18.6d: avatar cleared');
END;
$$;

-- 18.7: prepare_account_deletion tombstones media objects (status = deleted)
DO $$
DECLARE
  v_user uuid; v_mid uuid;
BEGIN
  v_user := test_helpers.make_user('DelMediaUser');
  v_mid  := test_helpers.make_media_object(v_user);

  SET LOCAL ROLE forkensics_executor;
  PERFORM private.prepare_account_deletion(v_user);
  RESET ROLE;

  PERFORM test_helpers.assert(
    EXISTS(SELECT 1 FROM public.media_objects WHERE id = v_mid AND status = 'deleted'),
    '18.7: media object tombstoned (status = deleted) after prepare_account_deletion'
  );
END;
$$;

-- 18.8: prepare_account_deletion sets deletion_log to database_prepared
DO $$
DECLARE
  v_user uuid;
BEGIN
  v_user := test_helpers.make_user('DelLogUser');

  SET LOCAL ROLE forkensics_executor;
  PERFORM private.prepare_account_deletion(v_user);
  RESET ROLE;

  PERFORM test_helpers.assert(
    EXISTS(SELECT 1 FROM private.deletion_log
           WHERE profile_id = v_user AND status = 'database_prepared'
             AND db_prepared_at IS NOT NULL),
    '18.8: deletion_log advanced to database_prepared'
  );
END;
$$;

-- 18.9: prepare_account_deletion archives identity in profile_archive
DO $$
DECLARE
  v_user uuid;
BEGIN
  v_user := test_helpers.make_user('DelArchiveUser');

  SET LOCAL ROLE forkensics_executor;
  PERFORM private.prepare_account_deletion(v_user);
  RESET ROLE;

  PERFORM test_helpers.assert(
    EXISTS(SELECT 1 FROM private.profile_archive
           WHERE profile_id = v_user AND original_display_name = 'DelArchiveUser'),
    '18.9: original identity archived in private.profile_archive'
  );
END;
$$;

-- 18.10: prepare_account_deletion is idempotent (can run twice)
DO $$
DECLARE
  v_user uuid; v_count int;
BEGIN
  v_user := test_helpers.make_user('DelIdempUser');

  SET LOCAL ROLE forkensics_executor;
  PERFORM private.prepare_account_deletion(v_user);
  PERFORM private.prepare_account_deletion(v_user);
  RESET ROLE;

  SELECT COUNT(*) INTO v_count FROM private.deletion_log WHERE profile_id = v_user;
  PERFORM test_helpers.assert(v_count = 1, '18.10: prepare_account_deletion idempotent (one log row)');
END;
$$;

-- =============================================================================
-- GROUP 19: VISIBILITY (posted_at IS NOT NULL predicate)
-- =============================================================================
\echo ''
\echo '--- GROUP 19: Visibility ---'

-- 19.1: draft challenge invisible to group members (posted_at IS NULL)
DO $$
DECLARE
  v_poster uuid; v_member uuid; v_group uuid; v_cid uuid; v_count int;
BEGIN
  v_poster := test_helpers.make_user('VisDraftPoster');
  v_member := test_helpers.make_user('VisDraftMember');
  v_group  := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_member);
  v_cid := test_helpers.make_draft_challenge(v_poster, v_group);  -- posted_at = NULL

  PERFORM test_helpers.set_auth_uid(v_member);
  SELECT COUNT(*) INTO v_count FROM public.challenges WHERE id = v_cid;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_count = 0, '19.1: draft challenge invisible to group member');
END;
$$;

-- 19.2: draft challenge visible to the poster
DO $$
DECLARE
  v_poster uuid; v_group uuid; v_cid uuid; v_count int;
BEGIN
  v_poster := test_helpers.make_user('VisDraftVis');
  v_group  := test_helpers.make_group(v_poster);
  v_cid    := test_helpers.make_draft_challenge(v_poster, v_group);

  PERFORM test_helpers.set_auth_uid(v_poster);
  SELECT COUNT(*) INTO v_count FROM public.challenges WHERE id = v_cid;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_count = 1, '19.2: draft challenge visible to poster');
END;
$$;

-- 19.3: active challenge (posted) visible to group members
DO $$
DECLARE
  v_poster uuid; v_member uuid; v_group uuid; v_cid uuid; v_count int;
BEGIN
  v_poster := test_helpers.make_user('VisActivePoster');
  v_member := test_helpers.make_user('VisActiveMember');
  v_group  := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_member);
  v_cid := test_helpers.make_draft_challenge(v_poster, v_group);
  PERFORM test_helpers.activate(v_poster, v_cid);  -- sets posted_at

  PERFORM test_helpers.set_auth_uid(v_member);
  SELECT COUNT(*) INTO v_count FROM public.challenges WHERE id = v_cid;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_count = 1, '19.3: active challenge visible to group member');
END;
$$;

-- 19.4: own guesses always visible; others' guesses hidden before reveal
DO $$
DECLARE
  v_poster uuid; v_player1 uuid; v_player2 uuid; v_group uuid; v_cid uuid;
  v_ga_id1 uuid; v_ga_id2 uuid; v_count int;
BEGIN
  v_poster  := test_helpers.make_user('VisGuessPoster');
  v_player1 := test_helpers.make_user('VisGuessP1');
  v_player2 := test_helpers.make_user('VisGuessP2');
  v_group   := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_player1);
  PERFORM test_helpers.add_member(v_group, v_poster, v_player2);
  v_cid    := test_helpers.make_draft_challenge(v_poster, v_group);
  PERFORM test_helpers.activate(v_poster, v_cid);
  v_ga_id1 := test_helpers.make_guess(v_player1, v_cid, 'what', 'Ramen');
  v_ga_id2 := test_helpers.make_guess(v_player2, v_cid, 'what', 'Sushi');

  -- player1 can see own guess but not player2's
  PERFORM test_helpers.set_auth_uid(v_player1);
  SELECT COUNT(*) INTO v_count FROM public.guess_attempts WHERE challenge_id = v_cid;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_count = 1, '19.4: player sees only own guess before reveal');
END;
$$;

-- 19.5: comment soft-deletion is one-way (trigger rejects repeat soft-delete)
-- Testing via soft_delete_comment twice: the second call bypasses RLS (SECURITY DEFINER)
-- so the row is always found, and comment_update_guard fires with OLD.deleted_at IS NOT NULL
-- → raises P0001.  This is equivalent to testing that deleted_at cannot be cleared:
-- once set, any further update attempt (set-again or clear) is rejected by the same trigger.
DO $$
DECLARE
  v_poster uuid; v_member uuid; v_group uuid; v_cid uuid;
  v_comment_id uuid; v_caught boolean := false;
BEGIN
  v_poster := test_helpers.make_user('ComDelPoster');
  v_member := test_helpers.make_user('ComDelMember');
  v_group  := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_member);
  v_cid := test_helpers.make_draft_challenge(v_poster, v_group);
  PERFORM test_helpers.activate(v_poster, v_cid);
  PERFORM test_helpers.make_guess(v_member, v_cid, 'what', 'Ramen');
  PERFORM test_helpers.expire_challenge(v_cid);
  PERFORM test_helpers.reveal(v_poster, v_cid);

  -- Post a comment
  PERFORM test_helpers.set_auth_uid(v_member);
  INSERT INTO public.comments (challenge_id, author_id, text)
  VALUES (v_cid, v_member, 'Nice challenge!')
  RETURNING id INTO v_comment_id;

  -- First soft-delete succeeds
  PERFORM public.soft_delete_comment(v_comment_id);

  -- Second soft-delete fails: trigger sees OLD.deleted_at IS NOT NULL → P0001
  BEGIN
    PERFORM public.soft_delete_comment(v_comment_id);
  EXCEPTION
    WHEN raise_exception THEN v_caught := true;  -- 'deleted_at is immutable once set'
    WHEN OTHERS THEN RAISE EXCEPTION 'unexpected SQLSTATE % — %', SQLSTATE, SQLERRM;
  END;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_caught, '19.5: soft-delete is one-way (repeat call rejected)');
END;
$$;

-- 19.6: inactive player cannot soft-delete a comment
-- Note: soft_delete_comment is SECURITY DEFINER (bypasses RLS), so authorization is
-- enforced by the comment_update_guard BEFORE trigger: "inactive accounts cannot
-- modify comments" (P0001).  The trigger fires before any data changes.
DO $$
DECLARE
  v_poster uuid; v_member uuid; v_group uuid; v_cid uuid;
  v_comment_id uuid; v_del_at timestamptz; v_caught boolean := false;
BEGIN
  v_poster := test_helpers.make_user('ComInactPoster');
  v_member := test_helpers.make_user('ComInactMember');
  v_group  := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_member);
  v_cid := test_helpers.make_draft_challenge(v_poster, v_group);
  PERFORM test_helpers.activate(v_poster, v_cid);
  PERFORM test_helpers.make_guess(v_member, v_cid, 'what', 'Ramen');
  PERFORM test_helpers.expire_challenge(v_cid);
  PERFORM test_helpers.reveal(v_poster, v_cid);

  PERFORM test_helpers.set_auth_uid(v_member);
  INSERT INTO public.comments (challenge_id, author_id, text)
  VALUES (v_cid, v_member, 'Great one!')
  RETURNING id INTO v_comment_id;
  PERFORM test_helpers.clear_auth_uid();

  -- Deactivate the member via account deletion prep
  SET LOCAL ROLE forkensics_executor;
  PERFORM private.prepare_account_deletion(v_member);
  RESET ROLE;

  -- Inactive user: soft_delete_comment triggers comment_update_guard which
  -- raises "inactive accounts cannot modify comments" (P0001)
  BEGIN
    PERFORM test_helpers.set_auth_uid(v_member);
    PERFORM public.soft_delete_comment(v_comment_id);
    PERFORM test_helpers.clear_auth_uid();
  EXCEPTION
    WHEN raise_exception THEN
      PERFORM test_helpers.clear_auth_uid();
      v_caught := true;  -- expected: trigger rejects inactive user
    WHEN OTHERS THEN RAISE EXCEPTION 'unexpected SQLSTATE % — %', SQLSTATE, SQLERRM;
  END;
  PERFORM test_helpers.assert(v_caught, '19.6a: inactive player soft-delete rejected by trigger');

  -- Verify the comment was NOT soft-deleted
  SELECT deleted_at INTO v_del_at FROM public.comments WHERE id = v_comment_id;
  PERFORM test_helpers.assert(v_del_at IS NULL, '19.6b: comment remains undeleted after inactive attempt');
END;
$$;

-- 19.7: cancelled-before-activation challenge is hidden from group members
DO $$
DECLARE
  v_poster uuid; v_member uuid; v_group uuid; v_cid uuid; v_count int;
BEGIN
  v_poster := test_helpers.make_user('VisCancPrePoster');
  v_member := test_helpers.make_user('VisCancPreMember');
  v_group  := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_member);
  v_cid := test_helpers.make_draft_challenge(v_poster, v_group);  -- posted_at = NULL

  PERFORM test_helpers.set_auth_uid(v_poster);
  PERFORM public.cancel_challenge(v_cid, 'test');
  PERFORM test_helpers.clear_auth_uid();

  PERFORM test_helpers.set_auth_uid(v_member);
  SELECT COUNT(*) INTO v_count FROM public.challenges WHERE id = v_cid;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_count = 0, '19.7: cancelled-before-activation challenge hidden from members');
END;
$$;

-- 19.8: poster sees all guesses (both races) before reveal
DO $$
DECLARE
  v_poster uuid; v_player1 uuid; v_player2 uuid; v_group uuid; v_cid uuid; v_count int;
BEGIN
  v_poster  := test_helpers.make_user('VisPosterGuess1');
  v_player1 := test_helpers.make_user('VisPGP1');
  v_player2 := test_helpers.make_user('VisPGP2');
  v_group   := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_player1);
  PERFORM test_helpers.add_member(v_group, v_poster, v_player2);
  v_cid := test_helpers.make_draft_challenge(v_poster, v_group);
  PERFORM test_helpers.activate(v_poster, v_cid);
  PERFORM test_helpers.make_guess(v_player1, v_cid, 'what', 'Ramen');
  PERFORM test_helpers.make_guess(v_player2, v_cid, 'where', NULL, 'Ichiran');

  PERFORM test_helpers.set_auth_uid(v_poster);
  SELECT COUNT(*) INTO v_count FROM public.guess_attempts WHERE challenge_id = v_cid;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_count = 2, '19.8: poster sees all guesses before reveal');
END;
$$;

-- 19.9: all group guesses visible after reveal
DO $$
DECLARE
  v_poster uuid; v_player1 uuid; v_player2 uuid; v_group uuid; v_cid uuid; v_count int;
BEGIN
  v_poster  := test_helpers.make_user('VisRevGuess1');
  v_player1 := test_helpers.make_user('VisRGP1');
  v_player2 := test_helpers.make_user('VisRGP2');
  v_group   := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_player1);
  PERFORM test_helpers.add_member(v_group, v_poster, v_player2);
  v_cid := test_helpers.make_draft_challenge(v_poster, v_group);
  PERFORM test_helpers.activate(v_poster, v_cid);
  PERFORM test_helpers.make_guess(v_player1, v_cid, 'what', 'Ramen');
  PERFORM test_helpers.make_guess(v_player2, v_cid, 'what', 'Sushi');
  PERFORM test_helpers.expire_challenge(v_cid);
  PERFORM test_helpers.reveal(v_poster, v_cid);

  PERFORM test_helpers.set_auth_uid(v_player1);
  SELECT COUNT(*) INTO v_count FROM public.guess_attempts WHERE challenge_id = v_cid;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_count = 2, '19.9: all guesses visible to members after reveal');
END;
$$;

-- 19.10: guesses remain private after challenge cancellation
DO $$
DECLARE
  v_poster uuid; v_player1 uuid; v_player2 uuid; v_group uuid; v_cid uuid; v_count int;
BEGIN
  v_poster  := test_helpers.make_user('VisCancGuessPoster');
  v_player1 := test_helpers.make_user('VisCGP1');
  v_player2 := test_helpers.make_user('VisCGP2');
  v_group   := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_player1);
  PERFORM test_helpers.add_member(v_group, v_poster, v_player2);
  v_cid := test_helpers.make_draft_challenge(v_poster, v_group);
  PERFORM test_helpers.activate(v_poster, v_cid);
  PERFORM test_helpers.make_guess(v_player1, v_cid, 'what', 'Ramen');
  PERFORM test_helpers.make_guess(v_player2, v_cid, 'what', 'Sushi');

  PERFORM test_helpers.set_auth_uid(v_poster);
  PERFORM public.cancel_challenge(v_cid, 'test');
  PERFORM test_helpers.clear_auth_uid();

  -- player1 sees only their own guess (not revealed state)
  PERFORM test_helpers.set_auth_uid(v_player1);
  SELECT COUNT(*) INTO v_count FROM public.guess_attempts WHERE challenge_id = v_cid;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_count = 1, '19.10: guesses private after cancellation');
END;
$$;

-- 19.11: outsider (non-member) cannot see active challenge
DO $$
DECLARE
  v_poster uuid; v_member uuid; v_outsider uuid; v_group uuid; v_cid uuid; v_count int;
BEGIN
  v_poster   := test_helpers.make_user('VisOutPoster');
  v_member   := test_helpers.make_user('VisOutMember');  -- needed to satisfy activate's eligible-participant guard
  v_outsider := test_helpers.make_user('VisOutOther');
  v_group    := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_member);
  -- outsider NOT added to the group
  v_cid := test_helpers.make_draft_challenge(v_poster, v_group);
  PERFORM test_helpers.activate(v_poster, v_cid);

  PERFORM test_helpers.set_auth_uid(v_outsider);
  SELECT COUNT(*) INTO v_count FROM public.challenges WHERE id = v_cid;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_count = 0, '19.11: outsider cannot see active challenge');
END;
$$;

-- 19.12: challenge_secrets hidden from non-poster (dish/restaurant privacy pre-reveal)
DO $$
DECLARE
  v_poster uuid; v_player uuid; v_group uuid; v_cid uuid; v_count int;
BEGIN
  v_poster := test_helpers.make_user('VisCityPoster');
  v_player := test_helpers.make_user('VisCityPlayer');
  v_group  := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_player);
  v_cid := test_helpers.make_draft_challenge(v_poster, v_group, 'Ramen', 'Ichiran', 'Tokyo');
  PERFORM test_helpers.activate(v_poster, v_cid);

  -- challenge_secrets is poster-only + service_role; player must see 0 rows
  PERFORM test_helpers.set_auth_uid(v_player);
  SELECT COUNT(*) INTO v_count FROM public.challenge_secrets WHERE challenge_id = v_cid;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_count = 0, '19.12: challenge_secrets hidden from non-poster before reveal');
END;
$$;

-- =============================================================================
-- GROUP 20: INACTIVE-ACCOUNT MUTATION PROTECTION
-- =============================================================================
\echo ''
\echo '--- GROUP 20: Inactive-Account Mutation Protection ---'

-- Helper: deactivate a user via prepare_account_deletion
-- This is used across multiple tests below.

-- 20.1: inactive player cannot insert a challenge
DO $$
DECLARE
  v_user uuid; v_group uuid; v_mid uuid; v_caught boolean := false;
BEGIN
  v_user  := test_helpers.make_user('InactChallUser');
  v_group := test_helpers.make_group(v_user);
  v_mid   := test_helpers.make_media_object(v_user);

  SET LOCAL ROLE forkensics_executor;
  PERFORM private.prepare_account_deletion(v_user);
  RESET ROLE;

  BEGIN
    PERFORM test_helpers.set_auth_uid(v_user);
    INSERT INTO public.challenges (group_id, media_object_id) VALUES (v_group, v_mid);
  EXCEPTION
    WHEN insufficient_privilege THEN v_caught := true;  -- RLS challenges_insert WITH CHECK fails (42501)
    WHEN OTHERS THEN RAISE EXCEPTION 'unexpected SQLSTATE % — %', SQLSTATE, SQLERRM;
  END;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_caught, '20.1: inactive player cannot insert challenge');
END;
$$;

-- 20.2: inactive player cannot insert a guess
DO $$
DECLARE
  v_poster uuid; v_player uuid; v_group uuid; v_cid uuid; v_caught boolean := false;
BEGIN
  v_poster := test_helpers.make_user('InactGuessPoster');
  v_player := test_helpers.make_user('InactGuessPlayer');
  v_group  := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_player);
  v_cid := test_helpers.make_draft_challenge(v_poster, v_group);
  PERFORM test_helpers.activate(v_poster, v_cid);

  SET LOCAL ROLE forkensics_executor;
  PERFORM private.prepare_account_deletion(v_player);
  RESET ROLE;

  BEGIN
    PERFORM test_helpers.set_auth_uid(v_player);
    INSERT INTO public.guess_attempts (challenge_id, player_id, race, dish_guess)
    VALUES (v_cid, v_player, 'what', 'Ramen');
  EXCEPTION
    WHEN insufficient_privilege THEN v_caught := true;  -- RLS guess_attempts INSERT WITH CHECK fails (42501)
    WHEN OTHERS THEN RAISE EXCEPTION 'unexpected SQLSTATE % — %', SQLSTATE, SQLERRM;
  END;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_caught, '20.2: inactive player cannot insert guess');
END;
$$;

-- 20.3: inactive player cannot insert a comment
DO $$
DECLARE
  v_poster uuid; v_player uuid; v_group uuid; v_cid uuid; v_caught boolean := false;
BEGIN
  v_poster := test_helpers.make_user('InactComPoster');
  v_player := test_helpers.make_user('InactComPlayer');
  v_group  := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_player);
  v_cid := test_helpers.make_draft_challenge(v_poster, v_group);
  PERFORM test_helpers.activate(v_poster, v_cid);
  PERFORM test_helpers.make_guess(v_player, v_cid, 'what', 'Ramen');
  PERFORM test_helpers.expire_challenge(v_cid);
  PERFORM test_helpers.reveal(v_poster, v_cid);

  SET LOCAL ROLE forkensics_executor;
  PERFORM private.prepare_account_deletion(v_player);
  RESET ROLE;

  BEGIN
    PERFORM test_helpers.set_auth_uid(v_player);
    INSERT INTO public.comments (challenge_id, author_id, text)
    VALUES (v_cid, v_player, 'Should not work');
  EXCEPTION
    WHEN insufficient_privilege THEN v_caught := true;  -- RLS comments INSERT WITH CHECK fails (42501)
    WHEN OTHERS THEN RAISE EXCEPTION 'unexpected SQLSTATE % — %', SQLSTATE, SQLERRM;
  END;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_caught, '20.3: inactive player cannot insert comment');
END;
$$;

-- 20.4: inactive player cannot insert a reaction
DO $$
DECLARE
  v_poster uuid; v_player uuid; v_group uuid; v_cid uuid; v_caught boolean := false;
BEGIN
  v_poster := test_helpers.make_user('InactReacPoster');
  v_player := test_helpers.make_user('InactReacPlayer');
  v_group  := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_player);
  v_cid := test_helpers.make_draft_challenge(v_poster, v_group);
  PERFORM test_helpers.activate(v_poster, v_cid);
  PERFORM test_helpers.make_guess(v_player, v_cid, 'what', 'Ramen');
  PERFORM test_helpers.expire_challenge(v_cid);
  PERFORM test_helpers.reveal(v_poster, v_cid);

  SET LOCAL ROLE forkensics_executor;
  PERFORM private.prepare_account_deletion(v_player);
  RESET ROLE;

  BEGIN
    PERFORM test_helpers.set_auth_uid(v_player);
    INSERT INTO public.reactions (challenge_id, player_id, emoji)
    VALUES (v_cid, v_player, '🍜');
  EXCEPTION
    WHEN insufficient_privilege THEN v_caught := true;  -- RLS reactions INSERT WITH CHECK fails (42501)
    WHEN OTHERS THEN RAISE EXCEPTION 'unexpected SQLSTATE % — %', SQLSTATE, SQLERRM;
  END;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_caught, '20.4: inactive player cannot insert reaction');
END;
$$;

-- 20.5: inactive player cannot withdraw from a challenge
DO $$
DECLARE
  v_poster uuid; v_player uuid; v_group uuid; v_cid uuid; v_caught boolean := false;
BEGIN
  v_poster := test_helpers.make_user('InactWdPoster');
  v_player := test_helpers.make_user('InactWdPlayer');
  v_group  := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_player);
  v_cid := test_helpers.make_draft_challenge(v_poster, v_group);
  PERFORM test_helpers.activate(v_poster, v_cid);

  SET LOCAL ROLE forkensics_executor;
  PERFORM private.prepare_account_deletion(v_player);
  RESET ROLE;

  BEGIN
    PERFORM test_helpers.set_auth_uid(v_player);
    INSERT INTO public.exclusion_events (challenge_id, player_id, reason, excluded_by)
    VALUES (v_cid, v_player, 'withdrew', v_player);
  EXCEPTION
    WHEN insufficient_privilege THEN v_caught := true;  -- RLS exclusion_events INSERT fails (42501)
    WHEN OTHERS THEN RAISE EXCEPTION 'unexpected SQLSTATE % — %', SQLSTATE, SQLERRM;
  END;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_caught, '20.5: inactive player cannot withdraw from challenge');
END;
$$;

-- 20.6: inactive player cannot create a group invite
DO $$
DECLARE
  v_user uuid; v_group uuid; v_caught boolean := false;
BEGIN
  v_user  := test_helpers.make_user('InactInvUser');
  v_group := test_helpers.make_group(v_user);

  SET LOCAL ROLE forkensics_executor;
  PERFORM private.prepare_account_deletion(v_user);
  RESET ROLE;

  BEGIN
    PERFORM test_helpers.set_auth_uid(v_user);
    PERFORM public.create_group_invite(v_group);
  EXCEPTION
    WHEN raise_exception THEN v_caught := true;  -- create_group_invite checks is_active (P0001)
    WHEN OTHERS THEN RAISE EXCEPTION 'unexpected SQLSTATE % — %', SQLSTATE, SQLERRM;
  END;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_caught, '20.6: inactive player cannot create group invite');
END;
$$;

-- 20.7: inactive group owner cannot UPDATE group name (RLS USING filters out the row → 0 rows)
DO $$
DECLARE
  v_owner uuid; v_group uuid; v_rows_updated int;
BEGIN
  v_owner := test_helpers.make_user('InactGrpOwner');
  v_group := test_helpers.make_group(v_owner);

  SET LOCAL ROLE forkensics_executor;
  PERFORM private.prepare_account_deletion(v_owner);
  RESET ROLE;

  PERFORM test_helpers.set_auth_uid(v_owner);
  UPDATE public.groups SET name = 'Hijacked Name' WHERE id = v_group;
  GET DIAGNOSTICS v_rows_updated = ROW_COUNT;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_rows_updated = 0, '20.7: inactive owner cannot UPDATE group (0 rows updated)');
END;
$$;

-- 20.8: inactive poster cannot call apply_correction
DO $$
DECLARE
  v_poster uuid; v_player uuid; v_group uuid; v_cid uuid; v_caught boolean := false;
BEGIN
  v_poster := test_helpers.make_user('InactACPoster');
  v_player := test_helpers.make_user('InactACPlayer');
  v_group  := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_player);
  v_cid := test_helpers.make_draft_challenge(v_poster, v_group);
  PERFORM test_helpers.activate(v_poster, v_cid);
  PERFORM test_helpers.make_guess(v_player, v_cid, 'what', 'Ramen');
  PERFORM test_helpers.expire_challenge(v_cid);
  PERFORM test_helpers.reveal(v_poster, v_cid);

  SET LOCAL ROLE forkensics_executor;
  PERFORM private.prepare_account_deletion(v_poster);
  RESET ROLE;

  BEGIN
    PERFORM test_helpers.set_auth_uid(v_poster);
    PERFORM public.apply_correction(v_cid, 'answer_changed', 'dish', 'New Dish', NULL, 'test');
  EXCEPTION
    WHEN raise_exception THEN v_caught := true;  -- apply_correction checks is_active (P0001)
    WHEN OTHERS THEN RAISE EXCEPTION 'unexpected SQLSTATE % — %', SQLSTATE, SQLERRM;
  END;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_caught, '20.8: inactive poster cannot call apply_correction');
END;
$$;

-- 20.9: inactive poster cannot call reveal_challenge
DO $$
DECLARE
  v_poster uuid; v_player uuid; v_group uuid; v_cid uuid; v_caught boolean := false;
BEGIN
  v_poster := test_helpers.make_user('InactRevPoster');
  v_player := test_helpers.make_user('InactRevPlayer');
  v_group  := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_player);
  v_cid := test_helpers.make_draft_challenge(v_poster, v_group);
  PERFORM test_helpers.activate(v_poster, v_cid);
  PERFORM test_helpers.make_guess(v_player, v_cid, 'what', 'Ramen');
  PERFORM test_helpers.expire_challenge(v_cid);

  SET LOCAL ROLE forkensics_executor;
  PERFORM private.prepare_account_deletion(v_poster);
  RESET ROLE;

  BEGIN
    PERFORM test_helpers.set_auth_uid(v_poster);
    PERFORM public.reveal_challenge(v_cid);
  EXCEPTION
    WHEN raise_exception THEN v_caught := true;  -- reveal_challenge checks is_active (P0001)
    WHEN OTHERS THEN RAISE EXCEPTION 'unexpected SQLSTATE % — %', SQLSTATE, SQLERRM;
  END;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_caught, '20.9: inactive poster cannot call reveal_challenge');
END;
$$;

-- 20.10: inactive player cannot create a group
DO $$
DECLARE
  v_user uuid; v_caught boolean := false;
BEGIN
  v_user := test_helpers.make_user('InactCGUser');

  SET LOCAL ROLE forkensics_executor;
  PERFORM private.prepare_account_deletion(v_user);
  RESET ROLE;

  BEGIN
    PERFORM test_helpers.set_auth_uid(v_user);
    PERFORM public.create_group('Should Fail');
  EXCEPTION
    WHEN raise_exception THEN v_caught := true;  -- create_group checks is_active (P0001)
    WHEN OTHERS THEN RAISE EXCEPTION 'unexpected SQLSTATE % — %', SQLSTATE, SQLERRM;
  END;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_caught, '20.10: inactive player cannot create group');
END;
$$;

-- 20.11: inactive poster cannot insert a clue
DO $$
DECLARE
  v_poster uuid; v_player uuid; v_group uuid; v_cid uuid; v_caught boolean := false;
BEGIN
  v_poster := test_helpers.make_user('InactCluePoster');
  v_player := test_helpers.make_user('InactCluePlayer');
  v_group  := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_player);
  v_cid := test_helpers.make_draft_challenge(v_poster, v_group);
  PERFORM test_helpers.activate(v_poster, v_cid);

  SET LOCAL ROLE forkensics_executor;
  PERFORM private.prepare_account_deletion(v_poster);
  RESET ROLE;

  BEGIN
    PERFORM test_helpers.set_auth_uid(v_poster);
    INSERT INTO public.clues (challenge_id, poster_id, text)
    VALUES (v_cid, v_poster, 'This is a clue');
  EXCEPTION
    WHEN insufficient_privilege THEN v_caught := true;  -- RLS clues INSERT WITH CHECK fails (42501)
    WHEN OTHERS THEN RAISE EXCEPTION 'unexpected SQLSTATE % — %', SQLSTATE, SQLERRM;
  END;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_caught, '20.11: inactive poster cannot insert clue');
END;
$$;

-- 20.12: inactive player cannot UPDATE their own profile (RLS USING filters → 0 rows)
DO $$
DECLARE
  v_user uuid; v_rows int;
BEGIN
  v_user := test_helpers.make_user('InactProfUser');

  SET LOCAL ROLE forkensics_executor;
  PERFORM private.prepare_account_deletion(v_user);
  RESET ROLE;

  PERFORM test_helpers.set_auth_uid(v_user);
  UPDATE public.profiles SET display_name = 'ShouldFail' WHERE id = v_user;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_rows = 0, '20.12: inactive player cannot UPDATE profile (0 rows)');
END;
$$;

-- 20.13: inactive poster cannot UPDATE draft challenge (RLS USING filters → 0 rows)
DO $$
DECLARE
  v_poster uuid; v_player uuid; v_group uuid; v_cid uuid; v_rows int;
BEGIN
  v_poster := test_helpers.make_user('InactChalUpPoster');
  v_player := test_helpers.make_user('InactChalUpPlayer');
  v_group  := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_player);
  v_cid    := test_helpers.make_draft_challenge(v_poster, v_group);

  SET LOCAL ROLE forkensics_executor;
  PERFORM private.prepare_account_deletion(v_poster);
  RESET ROLE;

  PERFORM test_helpers.set_auth_uid(v_poster);
  UPDATE public.challenges SET duration_seconds = 7200 WHERE id = v_cid;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_rows = 0, '20.13: inactive poster cannot UPDATE draft challenge (0 rows)');
END;
$$;

-- 20.14: inactive poster cannot UPDATE challenge_secrets (RLS USING filters → 0 rows)
DO $$
DECLARE
  v_poster uuid; v_player uuid; v_group uuid; v_cid uuid; v_rows int;
BEGIN
  v_poster := test_helpers.make_user('InactSecUpPoster');
  v_player := test_helpers.make_user('InactSecUpPlayer');
  v_group  := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_player);
  v_cid    := test_helpers.make_draft_challenge(v_poster, v_group);

  SET LOCAL ROLE forkensics_executor;
  PERFORM private.prepare_account_deletion(v_poster);
  RESET ROLE;

  PERFORM test_helpers.set_auth_uid(v_poster);
  UPDATE public.challenge_secrets SET story = 'New story' WHERE challenge_id = v_cid;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_rows = 0, '20.14: inactive poster cannot UPDATE challenge_secrets (0 rows)');
END;
$$;

-- 20.15: inactive poster cannot INSERT alias (RLS WITH CHECK → 42501)
DO $$
DECLARE
  v_poster uuid; v_player uuid; v_group uuid; v_cid uuid; v_caught boolean := false;
BEGIN
  v_poster := test_helpers.make_user('InactAliInsPoster');
  v_player := test_helpers.make_user('InactAliInsPlayer');
  v_group  := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_player);
  v_cid    := test_helpers.make_draft_challenge(v_poster, v_group);
  PERFORM test_helpers.activate(v_poster, v_cid);

  SET LOCAL ROLE forkensics_executor;
  PERFORM private.prepare_account_deletion(v_poster);
  RESET ROLE;

  BEGIN
    PERFORM test_helpers.set_auth_uid(v_poster);
    INSERT INTO public.challenge_answer_aliases (challenge_id, field, display_value, created_by)
    VALUES (v_cid, 'dish', 'Should Fail', v_poster);
  EXCEPTION
    WHEN insufficient_privilege THEN v_caught := true;  -- aliases_insert_poster WITH CHECK (42501)
    WHEN OTHERS THEN RAISE EXCEPTION 'unexpected SQLSTATE % — %', SQLSTATE, SQLERRM;
  END;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_caught, '20.15: inactive poster cannot INSERT alias (42501)');
END;
$$;

-- 20.16: inactive poster cannot UPDATE alias (RLS USING filters → 0 rows)
DO $$
DECLARE
  v_poster uuid; v_player uuid; v_group uuid; v_cid uuid; v_rows int;
BEGIN
  v_poster := test_helpers.make_user('InactAliUpPoster');
  v_player := test_helpers.make_user('InactAliUpPlayer');
  v_group  := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_player);
  v_cid    := test_helpers.make_draft_challenge(v_poster, v_group);
  PERFORM test_helpers.activate(v_poster, v_cid);

  -- Insert alias as executor before deactivating poster
  SET LOCAL ROLE forkensics_executor;
  INSERT INTO public.challenge_answer_aliases (challenge_id, field, display_value, normalized_value, created_by, is_active)
  VALUES (v_cid, 'dish', 'Soup', 'soup', v_poster, true);
  PERFORM private.prepare_account_deletion(v_poster);
  RESET ROLE;

  PERFORM test_helpers.set_auth_uid(v_poster);
  UPDATE public.challenge_answer_aliases SET is_active = false WHERE challenge_id = v_cid AND field = 'dish';
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_rows = 0, '20.16: inactive poster cannot UPDATE alias (0 rows)');
END;
$$;

-- 20.17: inactive player cannot DELETE own reaction (RLS USING filters → 0 rows)
DO $$
DECLARE
  v_poster uuid; v_player uuid; v_group uuid; v_cid uuid; v_rows int;
BEGIN
  v_poster := test_helpers.make_user('InactReactDelPoster');
  v_player := test_helpers.make_user('InactReactDelPlayer');
  v_group  := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_player);
  v_cid    := test_helpers.make_draft_challenge(v_poster, v_group);
  PERFORM test_helpers.activate(v_poster, v_cid);
  PERFORM test_helpers.make_guess(v_player, v_cid, 'what', 'Ramen');
  PERFORM test_helpers.expire_challenge(v_cid);
  PERFORM test_helpers.reveal(v_poster, v_cid);

  -- Player inserts a reaction while active
  PERFORM test_helpers.set_auth_uid(v_player);
  INSERT INTO public.reactions (challenge_id, player_id, emoji) VALUES (v_cid, v_player, '❤️');
  PERFORM test_helpers.clear_auth_uid();

  -- Deactivate player
  SET LOCAL ROLE forkensics_executor;
  PERFORM private.prepare_account_deletion(v_player);
  RESET ROLE;

  -- Now try to delete
  PERFORM test_helpers.set_auth_uid(v_player);
  DELETE FROM public.reactions WHERE challenge_id = v_cid AND player_id = v_player;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_rows = 0, '20.17: inactive player cannot DELETE own reaction (0 rows)');
END;
$$;

-- 20.18: inactive poster cannot activate challenge (function raises P0001)
DO $$
DECLARE
  v_poster uuid; v_player uuid; v_group uuid; v_cid uuid; v_caught boolean := false;
BEGIN
  v_poster := test_helpers.make_user('InactActPoster');
  v_player := test_helpers.make_user('InactActPlayer');
  v_group  := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_player);
  v_cid    := test_helpers.make_draft_challenge(v_poster, v_group);

  SET LOCAL ROLE forkensics_executor;
  PERFORM private.prepare_account_deletion(v_poster);
  RESET ROLE;

  BEGIN
    PERFORM test_helpers.set_auth_uid(v_poster);
    PERFORM public.activate_challenge(v_cid);
  EXCEPTION
    WHEN raise_exception THEN v_caught := true;  -- activate_challenge checks is_active (P0001)
    WHEN OTHERS THEN RAISE EXCEPTION 'unexpected SQLSTATE % — %', SQLSTATE, SQLERRM;
  END;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_caught, '20.18: inactive poster cannot activate challenge (P0001)');
END;
$$;

-- 20.19: inactive player cannot redeem group invite (function raises P0001)
DO $$
DECLARE
  v_owner  uuid; v_player uuid; v_group uuid; v_token text; v_caught boolean := false;
BEGIN
  v_owner  := test_helpers.make_user('InactRedeemOwner');
  v_player := test_helpers.make_user('InactRedeemPlayer');
  v_group  := test_helpers.make_group(v_owner);

  -- Create invite as owner
  PERFORM test_helpers.set_auth_uid(v_owner);
  v_token := public.create_group_invite(v_group);
  PERFORM test_helpers.clear_auth_uid();

  -- Deactivate the player before they redeem
  SET LOCAL ROLE forkensics_executor;
  PERFORM private.prepare_account_deletion(v_player);
  RESET ROLE;

  BEGIN
    PERFORM test_helpers.set_auth_uid(v_player);
    PERFORM public.redeem_group_invite(v_token);
  EXCEPTION
    WHEN raise_exception THEN v_caught := true;  -- redeem_group_invite checks is_active (P0001)
    WHEN OTHERS THEN RAISE EXCEPTION 'unexpected SQLSTATE % — %', SQLSTATE, SQLERRM;
  END;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_caught, '20.19: inactive player cannot redeem invite (P0001)');
END;
$$;

-- =============================================================================
-- GROUP 21: private.auth_uid() EDGE CASES
-- =============================================================================
\echo ''
\echo '--- GROUP 21: auth_uid() Edge Cases ---'

-- 21.1: no JWT claims set → auth_uid() returns NULL
DO $$
DECLARE v_uid uuid;
BEGIN
  SET LOCAL ROLE authenticated;
  PERFORM set_config('request.jwt.claim.sub', '', true);
  PERFORM set_config('request.jwt.claims', '', true);
  SELECT private.auth_uid() INTO v_uid;
  RESET ROLE;
  PERFORM test_helpers.assert(v_uid IS NULL, '21.1: absent JWT sub → auth_uid = NULL');
END;
$$;

-- 21.2: valid UUID sub → auth_uid() returns that UUID
DO $$
DECLARE v_user uuid; v_uid uuid;
BEGIN
  v_user := test_helpers.make_user('AuthUIDValid');
  SET LOCAL ROLE authenticated;
  PERFORM set_config('request.jwt.claim.sub', v_user::text, true);
  PERFORM set_config('request.jwt.claims', '', true);
  SELECT private.auth_uid() INTO v_uid;
  RESET ROLE;
  PERFORM test_helpers.assert(v_uid = v_user, '21.2: valid sub → auth_uid = UUID');
END;
$$;

-- 21.3: JWT present with empty-string sub {"sub":""} → auth_uid() returns NULL (not a cast throw)
-- This is a DISTINCT condition from 21.1 (no JWT at all):
-- the GUC jwt.claims is non-empty, but the extracted sub value is "".
-- Without the inner NULLIF on the JSON extraction, ''::uuid would throw an error.
DO $$
DECLARE v_uid uuid;
BEGIN
  SET LOCAL ROLE authenticated;
  PERFORM set_config('request.jwt.claim.sub', '', true);  -- primary path: empty
  PERFORM set_config('request.jwt.claims', '{"sub":""}', true);  -- JSON sub is empty string
  SELECT private.auth_uid() INTO v_uid;
  RESET ROLE;
  PERFORM test_helpers.assert(v_uid IS NULL, '21.3: JWT with empty-string sub {"sub":""} → auth_uid = NULL (no cast throw)');
END;
$$;

-- 21.4: sub absent from request.jwt.claim.sub but present in request.jwt.claims JSON fallback
DO $$
DECLARE v_user uuid; v_uid uuid;
BEGIN
  v_user := test_helpers.make_user('AuthUIDJSON');
  SET LOCAL ROLE authenticated;
  PERFORM set_config('request.jwt.claim.sub', '', true);  -- primary path empty
  PERFORM set_config(
    'request.jwt.claims',
    json_build_object('sub', v_user::text)::text,
    true
  );
  SELECT private.auth_uid() INTO v_uid;
  RESET ROLE;
  PERFORM test_helpers.assert(v_uid = v_user, '21.4: sub from jwt.claims JSON fallback → correct UUID');
END;
$$;

-- =============================================================================
-- GROUP 22: reveal_challenge ENTRY POINTS
-- =============================================================================
\echo ''
\echo '--- GROUP 22: reveal_challenge Entry Points ---'

-- 22.1: poster can reveal their own challenge via public.reveal_challenge
DO $$
DECLARE
  v_poster uuid; v_player uuid; v_group uuid; v_cid uuid; v_state text;
BEGIN
  v_poster := test_helpers.make_user('RevPosterOK');
  v_player := test_helpers.make_user('RevPOKPlayer');
  v_group  := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_player);
  v_cid := test_helpers.make_draft_challenge(v_poster, v_group);
  PERFORM test_helpers.activate(v_poster, v_cid);
  PERFORM test_helpers.make_guess(v_player, v_cid, 'what', 'Ramen');
  PERFORM test_helpers.expire_challenge(v_cid);
  PERFORM test_helpers.reveal(v_poster, v_cid);

  SELECT state INTO v_state FROM public.challenges WHERE id = v_cid;
  PERFORM test_helpers.assert(v_state = 'revealed', '22.1: poster reveal via public.reveal_challenge → state = revealed');
END;
$$;

-- 22.2: caller with NULL auth_uid rejected with insufficient_privilege (ERRCODE 42501)
DO $$
DECLARE
  v_poster uuid; v_player uuid; v_group uuid; v_cid uuid; v_caught boolean := false;
BEGIN
  v_poster := test_helpers.make_user('RevNullUIDPoster');
  v_player := test_helpers.make_user('RevNUPlayer');
  v_group  := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_player);
  v_cid := test_helpers.make_draft_challenge(v_poster, v_group);
  PERFORM test_helpers.activate(v_poster, v_cid);
  PERFORM test_helpers.make_guess(v_player, v_cid, 'what', 'Ramen');
  PERFORM test_helpers.expire_challenge(v_cid);

  -- Call as authenticated with no JWT sub → auth_uid() = NULL
  SET LOCAL ROLE authenticated;
  PERFORM set_config('request.jwt.claim.sub', '', true);
  PERFORM set_config('request.jwt.claims', '', true);
  BEGIN
    PERFORM public.reveal_challenge(v_cid);
  EXCEPTION
    WHEN insufficient_privilege THEN v_caught := true;  -- ERRCODE 42501 from function
    WHEN OTHERS THEN RAISE EXCEPTION 'unexpected SQLSTATE % — %', SQLSTATE, SQLERRM;
  END;
  RESET ROLE;
  PERFORM test_helpers.assert(v_caught, '22.2: null auth_uid → reveal_challenge raises 42501');
END;
$$;

-- 22.3: authenticated non-poster is rejected
DO $$
DECLARE
  v_poster uuid; v_player uuid; v_group uuid; v_cid uuid; v_caught boolean := false;
BEGIN
  v_poster := test_helpers.make_user('RevNonPoster');
  v_player := test_helpers.make_user('RevNPPlayer');
  v_group  := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_player);
  v_cid := test_helpers.make_draft_challenge(v_poster, v_group);
  PERFORM test_helpers.activate(v_poster, v_cid);
  PERFORM test_helpers.make_guess(v_player, v_cid, 'what', 'Ramen');
  PERFORM test_helpers.expire_challenge(v_cid);

  BEGIN
    PERFORM test_helpers.set_auth_uid(v_player);  -- player, not poster
    PERFORM public.reveal_challenge(v_cid);
  EXCEPTION
    WHEN raise_exception THEN v_caught := true;  -- 'caller is not the poster' (P0001)
    WHEN OTHERS THEN RAISE EXCEPTION 'unexpected SQLSTATE % — %', SQLSTATE, SQLERRM;
  END;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_caught, '22.3: non-poster cannot call reveal_challenge');
END;
$$;

-- 22.4: service_role reveal via private.reveal_challenge_service (requires locked state)
DO $$
DECLARE
  v_poster uuid; v_player uuid; v_group uuid; v_cid uuid; v_state text;
BEGIN
  v_poster := test_helpers.make_user('RevSvcPoster');
  v_player := test_helpers.make_user('RevSvcPlayer');
  v_group  := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_player);
  v_cid := test_helpers.make_draft_challenge(v_poster, v_group);
  PERFORM test_helpers.activate(v_poster, v_cid);
  PERFORM test_helpers.make_guess(v_player, v_cid, 'what', 'Ramen');
  PERFORM test_helpers.expire_challenge(v_cid);

  -- Lock the challenge (postgres superuser bypasses privilege checks)
  PERFORM public.lock_challenge(v_cid);

  -- Service path: SET ROLE service_role → call private.reveal_challenge_service
  SET LOCAL ROLE service_role;
  PERFORM private.reveal_challenge_service(v_cid);
  RESET ROLE;

  SELECT state INTO v_state FROM public.challenges WHERE id = v_cid;
  PERFORM test_helpers.assert(v_state = 'revealed', '22.4: service_role reveal via reveal_challenge_service → state = revealed');
END;
$$;

-- =============================================================================
-- GROUP 23: ALIAS UNIQUENESS, SERVER FIELD OVERRIDE, SEQUENTIAL LOCK TEST
-- =============================================================================
\echo ''
\echo '--- GROUP 23: Alias Uniqueness + Guard ---'

-- 23.1: unique index blocks duplicate active alias (same normalized value)
-- Tests idx_aliases_active_unique directly via forkensics_executor INSERT.
DO $$
DECLARE
  v_poster uuid; v_player uuid; v_group uuid; v_cid uuid;
  v_caught boolean := false;
BEGIN
  v_poster := test_helpers.make_user('AliUniqPoster');
  v_player := test_helpers.make_user('AliUniqPlayer');
  v_group  := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_player);
  v_cid := test_helpers.make_draft_challenge(v_poster, v_group);
  PERFORM test_helpers.activate(v_poster, v_cid);
  PERFORM test_helpers.expire_challenge(v_cid);

  SET LOCAL ROLE forkensics_executor;
  -- First alias (executor bypasses trigger guard; supply fields manually)
  INSERT INTO public.challenge_answer_aliases
    (challenge_id, field, display_value, normalized_value, created_by, is_active)
  VALUES (v_cid, 'dish', 'Noodle Soup', 'noodle soup', v_poster, true);
  -- Duplicate normalized value → idx_aliases_active_unique fires
  BEGIN
    INSERT INTO public.challenge_answer_aliases
      (challenge_id, field, display_value, normalized_value, created_by, is_active)
    VALUES (v_cid, 'dish', 'Noodle Soup!', 'noodle soup', v_poster, true);
  EXCEPTION
    WHEN unique_violation THEN v_caught := true;  -- idx_aliases_active_unique (23505)
    WHEN OTHERS THEN RAISE EXCEPTION 'unexpected SQLSTATE % — %', SQLSTATE, SQLERRM;
  END;
  RESET ROLE;
  PERFORM test_helpers.assert(v_caught, '23.1: duplicate active alias (unique index) — rejected');
END;
$$;

-- 23.2: guard_alias_edits trigger overrides caller-supplied normalized_value, created_by, and is_active
DO $$
DECLARE
  v_poster  uuid; v_player uuid; v_impostor uuid;
  v_group   uuid; v_cid uuid;
  v_norm    text; v_creator uuid; v_active boolean;
BEGIN
  v_poster   := test_helpers.make_user('AliNormPoster');
  v_player   := test_helpers.make_user('AliNormPlayer');  -- needed to satisfy activate's eligible-participant guard
  v_impostor := test_helpers.make_user('AliNormImpostor');
  v_group    := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_player);
  v_cid      := test_helpers.make_draft_challenge(v_poster, v_group);
  PERFORM test_helpers.activate(v_poster, v_cid);

  -- Supply wrong values for all three guarded fields
  PERFORM test_helpers.set_auth_uid(v_poster);
  INSERT INTO public.challenge_answer_aliases
    (challenge_id, field, display_value, normalized_value, created_by, is_active)
  VALUES (v_cid, 'dish', 'Noodle Soup', 'WRONG_VALUE', v_impostor, false);
  PERFORM test_helpers.clear_auth_uid();

  SELECT normalized_value, created_by, is_active
  INTO   v_norm, v_creator, v_active
  FROM   public.challenge_answer_aliases
  WHERE  challenge_id = v_cid AND field = 'dish';

  PERFORM test_helpers.assert(v_norm    = 'noodle soup', '23.2a: trigger overrides normalized_value');
  PERFORM test_helpers.assert(v_creator = v_poster,      '23.2b: trigger overrides created_by with auth_uid');
  PERFORM test_helpers.assert(v_active  = true,          '23.2c: trigger overrides is_active to true');
END;
$$;

-- 23.3: alias insert rejected after first guess sets has_first_guess = true
DO $$
DECLARE
  v_poster uuid; v_player uuid; v_group uuid; v_cid uuid; v_caught boolean := false;
BEGIN
  v_poster := test_helpers.make_user('AliGrdPoster');
  v_player := test_helpers.make_user('AliGrdPlayer');
  v_group  := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_player);
  v_cid := test_helpers.make_draft_challenge(v_poster, v_group);
  PERFORM test_helpers.activate(v_poster, v_cid);

  -- Guess arrives → has_first_guess = true
  PERFORM test_helpers.make_guess(v_player, v_cid, 'what', 'Ramen');

  PERFORM test_helpers.set_auth_uid(v_poster);
  BEGIN
    INSERT INTO public.challenge_answer_aliases
      (challenge_id, field, display_value, created_by)
    VALUES (v_cid, 'dish', 'New Alias', v_poster);
  EXCEPTION
    WHEN raise_exception THEN v_caught := true;  -- guard_alias_edits: has_first_guess = true (P0001)
    WHEN OTHERS THEN RAISE EXCEPTION 'unexpected SQLSTATE % — %', SQLSTATE, SQLERRM;
  END;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_caught, '23.3: alias insert rejected after first guess');
END;
$$;

-- 23.4: sequential lock test — alias succeeds before guess; second alias blocked after guess
-- For true concurrent serialization testing, see companion script test_alias_concurrency.sh.
DO $$
DECLARE
  v_poster uuid; v_player uuid; v_group uuid; v_cid uuid;
  v_alias_id uuid; v_has_first_guess boolean; v_caught boolean := false;
BEGIN
  v_poster := test_helpers.make_user('AliSeqPoster');
  v_player := test_helpers.make_user('AliSeqPlayer');
  v_group  := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_player);
  v_cid := test_helpers.make_draft_challenge(v_poster, v_group);
  PERFORM test_helpers.activate(v_poster, v_cid);

  -- Step 1: alias insert succeeds (no guess yet)
  PERFORM test_helpers.set_auth_uid(v_poster);
  INSERT INTO public.challenge_answer_aliases (challenge_id, field, display_value, created_by)
  VALUES (v_cid, 'dish', 'First Alias', v_poster)
  RETURNING id INTO v_alias_id;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_alias_id IS NOT NULL, '23.4a: alias insert before first guess succeeds');

  -- Step 2: guess arrives → has_first_guess = true
  PERFORM test_helpers.make_guess(v_player, v_cid, 'what', 'Ramen');
  SELECT has_first_guess INTO v_has_first_guess
  FROM public.challenge_secrets WHERE challenge_id = v_cid;
  PERFORM test_helpers.assert(v_has_first_guess, '23.4b: has_first_guess = true after guess arrives');

  -- Step 3: subsequent alias insert blocked
  PERFORM test_helpers.set_auth_uid(v_poster);
  BEGIN
    INSERT INTO public.challenge_answer_aliases (challenge_id, field, display_value, created_by)
    VALUES (v_cid, 'dish', 'Second Alias', v_poster);
  EXCEPTION
    WHEN raise_exception THEN v_caught := true;
    WHEN OTHERS THEN RAISE EXCEPTION 'unexpected SQLSTATE % — %', SQLSTATE, SQLERRM;
  END;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_caught, '23.4c: second alias blocked after first guess');
END;
$$;

-- =============================================================================
-- GROUP 24: DELETION LIFECYCLE FUNCTIONS
-- =============================================================================
\echo ''
\echo '--- GROUP 24: Deletion Lifecycle Functions ---'

-- 24.1: mark_auth_deleted advances database_prepared → auth_deleted
DO $$
DECLARE v_user uuid; v_status text;
BEGIN
  v_user := test_helpers.make_user('DLAuthDelUser');

  SET LOCAL ROLE forkensics_executor;
  PERFORM private.prepare_account_deletion(v_user);
  PERFORM private.mark_auth_deleted(v_user);
  RESET ROLE;

  SELECT status INTO v_status FROM private.deletion_log WHERE profile_id = v_user;
  PERFORM test_helpers.assert(v_status = 'auth_deleted', '24.1: mark_auth_deleted → status = auth_deleted');
END;
$$;

-- 24.2: mark_auth_deleted is idempotent if already auth_deleted
DO $$
DECLARE v_user uuid; v_status text;
BEGIN
  v_user := test_helpers.make_user('DLAuthDelIdem');

  SET LOCAL ROLE forkensics_executor;
  PERFORM private.prepare_account_deletion(v_user);
  PERFORM private.mark_auth_deleted(v_user);
  PERFORM private.mark_auth_deleted(v_user);  -- second call: idempotent
  RESET ROLE;

  SELECT status INTO v_status FROM private.deletion_log WHERE profile_id = v_user;
  PERFORM test_helpers.assert(v_status = 'auth_deleted', '24.2: mark_auth_deleted idempotent if already auth_deleted');
END;
$$;

-- 24.3: mark_auth_deleted rejects wrong precondition (status = pending, not database_prepared)
DO $$
DECLARE v_user uuid; v_caught boolean := false;
BEGIN
  v_user := test_helpers.make_user('DLAuthDelWrong');

  SET LOCAL ROLE forkensics_executor;
  -- Insert a pending log row (skipping prepare_account_deletion)
  INSERT INTO private.deletion_log (profile_id, status, last_attempt_at)
  VALUES (v_user, 'pending', clock_timestamp());
  BEGIN
    PERFORM private.mark_auth_deleted(v_user);  -- requires database_prepared, not pending
  EXCEPTION
    WHEN raise_exception THEN v_caught := true;
    WHEN OTHERS THEN RAISE EXCEPTION 'unexpected SQLSTATE % — %', SQLSTATE, SQLERRM;
  END;
  RESET ROLE;
  PERFORM test_helpers.assert(v_caught, '24.3: mark_auth_deleted rejects non-database_prepared status');
END;
$$;

-- 24.4: get_storage_keys_for_deletion returns one row per physical file
DO $$
DECLARE
  v_user uuid; v_mid uuid;
  v_row_count int;
  v_keys text[];
  v_orig_key  text := 'uploads/' || gen_random_uuid()::text || '/original.jpg';
  v_reenc_key text := 'uploads/' || gen_random_uuid()::text || '/re_encoded.mp4';
BEGIN
  v_user := test_helpers.make_user('DLKeysUser');
  v_mid  := test_helpers.make_media_object(v_user);

  SET LOCAL ROLE forkensics_executor;
  PERFORM private.prepare_account_deletion(v_user);
  INSERT INTO private.media_storage_keys (media_object_id, storage_key, re_encoded_storage_key)
  VALUES (v_mid, v_orig_key, v_reenc_key);

  SELECT COUNT(*) INTO v_row_count
  FROM private.get_storage_keys_for_deletion(v_user);

  SELECT ARRAY_AGG(storage_key ORDER BY storage_key) INTO v_keys
  FROM private.get_storage_keys_for_deletion(v_user);
  RESET ROLE;

  PERFORM test_helpers.assert(v_row_count = 2,
    '24.4a: get_storage_keys_for_deletion returns 2 rows (one per physical file)');
  PERFORM test_helpers.assert(v_orig_key  = ANY(v_keys),
    '24.4b: original storage_key returned');
  PERFORM test_helpers.assert(v_reenc_key = ANY(v_keys),
    '24.4c: re_encoded_storage_key returned as separate row');
END;
$$;

-- 24.4d: same path in both columns yields exactly one row (deduplication via UNION)
DO $$
DECLARE
  v_user uuid; v_mid uuid;
  v_row_count int;
  v_same_key text := 'uploads/' || gen_random_uuid()::text || '/same.jpg';
BEGIN
  v_user := test_helpers.make_user('DLDedupUser');
  v_mid  := test_helpers.make_media_object(v_user);

  SET LOCAL ROLE forkensics_executor;
  PERFORM private.prepare_account_deletion(v_user);
  INSERT INTO private.media_storage_keys (media_object_id, storage_key, re_encoded_storage_key)
  VALUES (v_mid, v_same_key, v_same_key);

  SELECT COUNT(*) INTO v_row_count
  FROM private.get_storage_keys_for_deletion(v_user);
  RESET ROLE;

  PERFORM test_helpers.assert(v_row_count = 1,
    '24.4d: same path in both columns returns exactly 1 row (UNION deduplicates)');
END;
$$;

-- 24.5: mark_storage_cleaned advances auth_deleted → complete and deletes storage keys
DO $$
DECLARE
  v_user uuid; v_mid uuid; v_status text; v_key_count int;
BEGIN
  v_user := test_helpers.make_user('DLStorCleanUser');
  v_mid  := test_helpers.make_media_object(v_user);

  SET LOCAL ROLE forkensics_executor;
  PERFORM private.prepare_account_deletion(v_user);
  INSERT INTO private.media_storage_keys (media_object_id, storage_key)
  VALUES (v_mid, 'uploads/' || v_mid::text || '/original.jpg');
  PERFORM private.mark_auth_deleted(v_user);
  PERFORM private.mark_storage_cleaned(v_user);
  RESET ROLE;

  SELECT status INTO v_status FROM private.deletion_log WHERE profile_id = v_user;
  SELECT COUNT(*) INTO v_key_count FROM private.media_storage_keys
  WHERE media_object_id = v_mid;
  PERFORM test_helpers.assert(v_status = 'complete', '24.5a: mark_storage_cleaned → status = complete');
  PERFORM test_helpers.assert(v_key_count = 0, '24.5b: storage keys deleted after mark_storage_cleaned');
END;
$$;

-- 24.6: mark_storage_cleaned is idempotent if already complete
DO $$
DECLARE v_user uuid; v_status text;
BEGIN
  v_user := test_helpers.make_user('DLStorCleanIdem');

  SET LOCAL ROLE forkensics_executor;
  PERFORM private.prepare_account_deletion(v_user);
  PERFORM private.mark_auth_deleted(v_user);
  PERFORM private.mark_storage_cleaned(v_user);
  PERFORM private.mark_storage_cleaned(v_user);  -- second call: idempotent
  RESET ROLE;

  SELECT status INTO v_status FROM private.deletion_log WHERE profile_id = v_user;
  PERFORM test_helpers.assert(v_status = 'complete', '24.6: mark_storage_cleaned idempotent if already complete');
END;
$$;

-- 24.7: record_deletion_failure records error without changing status
DO $$
DECLARE v_user uuid; v_status text; v_error text;
BEGIN
  v_user := test_helpers.make_user('DLFailUser');

  SET LOCAL ROLE forkensics_executor;
  PERFORM private.prepare_account_deletion(v_user);
  PERFORM private.record_deletion_failure(v_user, 'Supabase Auth API timeout');
  RESET ROLE;

  SELECT status, error INTO v_status, v_error FROM private.deletion_log WHERE profile_id = v_user;
  PERFORM test_helpers.assert(v_status = 'database_prepared', '24.7a: record_deletion_failure does not change status');
  PERFORM test_helpers.assert(v_error = 'Supabase Auth API timeout', '24.7b: error text recorded correctly');
END;
$$;

-- 24.8: forward-only guard — prepare_account_deletion when already auth_deleted does not regress
DO $$
DECLARE v_user uuid; v_status text; v_count int;
BEGIN
  v_user := test_helpers.make_user('DLFwdOnlyUser');

  SET LOCAL ROLE forkensics_executor;
  PERFORM private.prepare_account_deletion(v_user);  -- → database_prepared
  PERFORM private.mark_auth_deleted(v_user);          -- → auth_deleted
  PERFORM private.prepare_account_deletion(v_user);  -- should not regress
  RESET ROLE;

  SELECT status INTO v_status FROM private.deletion_log WHERE profile_id = v_user;
  SELECT COUNT(*) INTO v_count FROM private.deletion_log WHERE profile_id = v_user;
  PERFORM test_helpers.assert(v_status = 'auth_deleted', '24.8a: forward-only: status not regressed from auth_deleted');
  PERFORM test_helpers.assert(v_count = 1, '24.8b: no duplicate deletion_log rows');
END;
$$;

-- 24.9: full pipeline — prepare → mark_auth_deleted → mark_storage_cleaned → complete
DO $$
DECLARE
  v_user uuid; v_mid uuid; v_status text;
BEGIN
  v_user := test_helpers.make_user('DLFullPipe');
  v_mid  := test_helpers.make_media_object(v_user);

  SET LOCAL ROLE forkensics_executor;
  PERFORM private.prepare_account_deletion(v_user);
  INSERT INTO private.media_storage_keys (media_object_id, storage_key)
  VALUES (v_mid, 'uploads/' || v_mid::text || '/photo.jpg');
  PERFORM private.mark_auth_deleted(v_user);
  PERFORM private.mark_storage_cleaned(v_user);
  RESET ROLE;

  SELECT status INTO v_status FROM private.deletion_log WHERE profile_id = v_user;
  PERFORM test_helpers.assert(v_status = 'complete', '24.9: full deletion pipeline reaches complete');
END;
$$;

-- =============================================================================
-- GROUP 25: TABLE TALK VISIBILITY (post-guess RLS + tombstone)
-- =============================================================================
\echo ''
\echo '--- GROUP 25: Table Talk Visibility ---'

-- 25.1: player who has NOT guessed cannot read comments (pre-guess)
DO $$
DECLARE
  v_poster uuid; v_guesser uuid; v_reader uuid; v_group uuid; v_cid uuid; v_count int;
BEGIN
  v_poster  := test_helpers.make_user('TTPrePoster');
  v_guesser := test_helpers.make_user('TTPreGuesser');
  v_reader  := test_helpers.make_user('TTPreReader');
  v_group   := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_guesser);
  PERFORM test_helpers.add_member(v_group, v_poster, v_reader);
  v_cid := test_helpers.make_draft_challenge(v_poster, v_group);
  PERFORM test_helpers.activate(v_poster, v_cid);

  -- Guesser submits a guess and posts a comment
  PERFORM test_helpers.make_guess(v_guesser, v_cid, 'what', 'Ramen');
  PERFORM test_helpers.set_auth_uid(v_guesser);
  INSERT INTO public.comments (challenge_id, author_id, text) VALUES (v_cid, v_guesser, 'I thought it was ramen!');
  PERFORM test_helpers.clear_auth_uid();

  -- Reader (no guess yet) cannot see the comment
  PERFORM test_helpers.set_auth_uid(v_reader);
  SELECT COUNT(*) INTO v_count FROM public.comments WHERE challenge_id = v_cid;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_count = 0, '25.1: player without guess cannot read comments (0 rows)');
END;
$$;

-- 25.2: player who HAS guessed can read comments (post-guess, pre-reveal)
DO $$
DECLARE
  v_poster uuid; v_guesser uuid; v_reader uuid; v_group uuid; v_cid uuid; v_count int;
BEGIN
  v_poster  := test_helpers.make_user('TTPostPoster');
  v_guesser := test_helpers.make_user('TTPostGuesser');
  v_reader  := test_helpers.make_user('TTPostReader');
  v_group   := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_guesser);
  PERFORM test_helpers.add_member(v_group, v_poster, v_reader);
  v_cid := test_helpers.make_draft_challenge(v_poster, v_group);
  PERFORM test_helpers.activate(v_poster, v_cid);

  -- Guesser posts a comment after guessing
  PERFORM test_helpers.make_guess(v_guesser, v_cid, 'what', 'Ramen');
  PERFORM test_helpers.set_auth_uid(v_guesser);
  INSERT INTO public.comments (challenge_id, author_id, text) VALUES (v_cid, v_guesser, 'Nice one!');
  PERFORM test_helpers.clear_auth_uid();

  -- Reader also submits guess, then can see the comment
  PERFORM test_helpers.make_guess(v_reader, v_cid, 'what', 'Soba');
  PERFORM test_helpers.set_auth_uid(v_reader);
  SELECT COUNT(*) INTO v_count FROM public.comments WHERE challenge_id = v_cid;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_count = 1, '25.2: player with guess can read comments (1 row)');
END;
$$;

-- 25.3: poster can read comments before any guesses
DO $$
DECLARE
  v_poster uuid; v_player uuid; v_group uuid; v_cid uuid; v_count int;
BEGIN
  v_poster := test_helpers.make_user('TTPosterRead');
  v_player := test_helpers.make_user('TTPosterPlayer');
  v_group  := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_player);
  v_cid := test_helpers.make_draft_challenge(v_poster, v_group);
  PERFORM test_helpers.activate(v_poster, v_cid);

  -- Player guesses and comments
  PERFORM test_helpers.make_guess(v_player, v_cid, 'what', 'Ramen');
  PERFORM test_helpers.set_auth_uid(v_player);
  INSERT INTO public.comments (challenge_id, author_id, text) VALUES (v_cid, v_player, 'Good one!');
  PERFORM test_helpers.clear_auth_uid();

  -- Poster sees comment (no guess required for poster)
  PERFORM test_helpers.set_auth_uid(v_poster);
  SELECT COUNT(*) INTO v_count FROM public.comments WHERE challenge_id = v_cid;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_count = 1, '25.3: poster can always read comments (1 row)');
END;
$$;

-- 25.4: soft-deleted comments are not visible to any reader
DO $$
DECLARE
  v_poster uuid; v_player uuid; v_group uuid; v_cid uuid; v_count int; v_cmt_id uuid;
BEGIN
  v_poster := test_helpers.make_user('TTDelPoster');
  v_player := test_helpers.make_user('TTDelPlayer');
  v_group  := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_player);
  v_cid := test_helpers.make_draft_challenge(v_poster, v_group);
  PERFORM test_helpers.activate(v_poster, v_cid);
  PERFORM test_helpers.make_guess(v_player, v_cid, 'what', 'Ramen');
  PERFORM test_helpers.expire_challenge(v_cid);
  PERFORM test_helpers.reveal(v_poster, v_cid);

  -- Player posts a comment then soft-deletes it via SECURITY DEFINER function
  PERFORM test_helpers.set_auth_uid(v_player);
  INSERT INTO public.comments (challenge_id, author_id, text) VALUES (v_cid, v_player, 'Will delete this') RETURNING id INTO v_cmt_id;
  PERFORM public.soft_delete_comment(v_cmt_id);
  PERFORM test_helpers.clear_auth_uid();

  -- Poster reads — deleted comment must be invisible
  PERFORM test_helpers.set_auth_uid(v_poster);
  SELECT COUNT(*) INTO v_count FROM public.comments WHERE challenge_id = v_cid;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_count = 0, '25.4: soft-deleted comment is not visible (deleted_at IS NULL filter)');
END;
$$;

-- 25.5: INSERT cannot supply a non-NULL deleted_at (WITH CHECK blocks pre-deleted inserts)
DO $$
DECLARE
  v_poster uuid; v_player uuid; v_group uuid; v_cid uuid; v_caught boolean := false;
BEGIN
  v_poster := test_helpers.make_user('TTPreDelInsPoster');
  v_player := test_helpers.make_user('TTPreDelInsPlayer');
  v_group  := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_player);
  v_cid := test_helpers.make_draft_challenge(v_poster, v_group);
  PERFORM test_helpers.activate(v_poster, v_cid);
  PERFORM test_helpers.make_guess(v_player, v_cid, 'what', 'Ramen');

  BEGIN
    PERFORM test_helpers.set_auth_uid(v_player);
    INSERT INTO public.comments (challenge_id, author_id, text, deleted_at)
    VALUES (v_cid, v_player, 'Pre-deleted insert', now());
  EXCEPTION
    WHEN insufficient_privilege THEN v_caught := true;  -- WITH CHECK: deleted_at IS NULL (42501)
    WHEN OTHERS THEN RAISE EXCEPTION 'unexpected SQLSTATE % — %', SQLSTATE, SQLERRM;
  END;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_caught, '25.5: INSERT with non-NULL deleted_at rejected (42501)');
END;
$$;

-- 25.6: player who has NOT guessed cannot INSERT a comment (pre-guess)
DO $$
DECLARE
  v_poster uuid; v_player uuid; v_group uuid; v_cid uuid; v_caught boolean := false;
BEGIN
  v_poster := test_helpers.make_user('TTNGInsertPoster');
  v_player := test_helpers.make_user('TTNGInsertPlayer');
  v_group  := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_player);
  v_cid := test_helpers.make_draft_challenge(v_poster, v_group);
  PERFORM test_helpers.activate(v_poster, v_cid);

  BEGIN
    PERFORM test_helpers.set_auth_uid(v_player);
    INSERT INTO public.comments (challenge_id, author_id, text)
    VALUES (v_cid, v_player, 'Spoiler comment');
  EXCEPTION
    WHEN insufficient_privilege THEN v_caught := true;  -- comments_insert WITH CHECK (42501)
    WHEN OTHERS THEN RAISE EXCEPTION 'unexpected SQLSTATE % — %', SQLSTATE, SQLERRM;
  END;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_caught, '25.6: player without guess cannot INSERT comment (42501)');
END;
$$;

-- =============================================================================
-- GROUP 26: ADDITIONAL TIGHTENING (Round 4)
-- =============================================================================
\echo ''
\echo '--- GROUP 26: Additional Tightening ---'

-- 26.1: service_role can call private deletion functions
DO $$
DECLARE
  v_user uuid; v_status text;
BEGIN
  v_user := test_helpers.make_user('SvcRoleDel');

  -- Call as service_role (not forkensics_executor)
  SET LOCAL ROLE service_role;
  PERFORM private.prepare_account_deletion(v_user);
  PERFORM private.mark_auth_deleted(v_user);
  PERFORM private.mark_storage_cleaned(v_user);
  RESET ROLE;

  SELECT status INTO v_status FROM private.deletion_log WHERE profile_id = v_user;
  PERFORM test_helpers.assert(v_status = 'complete', '26.1: service_role can drive deletion pipeline to complete');
END;
$$;

-- 26.2: authenticated cannot call private.prepare_account_deletion (42501)
DO $$
DECLARE
  v_user uuid; v_caught boolean := false;
BEGIN
  v_user := test_helpers.make_user('PrivDelAuthUser');
  BEGIN
    PERFORM test_helpers.set_auth_uid(v_user);
    PERFORM private.prepare_account_deletion(v_user);
  EXCEPTION
    WHEN insufficient_privilege THEN v_caught := true;  -- no EXECUTE grant to authenticated (42501)
    WHEN OTHERS THEN RAISE EXCEPTION 'unexpected SQLSTATE % — %', SQLSTATE, SQLERRM;
  END;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_caught, '26.2: authenticated cannot call private.prepare_account_deletion (42501)');
END;
$$;

-- 26.3: authenticated cannot call private.reveal_challenge_service (42501)
DO $$
DECLARE
  v_poster uuid; v_player uuid; v_group uuid; v_cid uuid; v_caught boolean := false;
BEGIN
  v_poster := test_helpers.make_user('PrivRevAuthPoster');
  v_player := test_helpers.make_user('PrivRevAuthPlayer');
  v_group  := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_group, v_poster, v_player);
  v_cid := test_helpers.make_draft_challenge(v_poster, v_group);
  PERFORM test_helpers.activate(v_poster, v_cid);
  PERFORM test_helpers.make_guess(v_player, v_cid, 'what', 'Ramen');
  PERFORM test_helpers.expire_challenge(v_cid);

  BEGIN
    PERFORM test_helpers.set_auth_uid(v_poster);
    PERFORM private.reveal_challenge_service(v_cid);
  EXCEPTION
    WHEN insufficient_privilege THEN v_caught := true;  -- no EXECUTE grant to authenticated (42501)
    WHEN OTHERS THEN RAISE EXCEPTION 'unexpected SQLSTATE % — %', SQLSTATE, SQLERRM;
  END;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_caught, '26.3: authenticated cannot call private.reveal_challenge_service (42501)');
END;
$$;

-- 26.4: prepare_account_deletion is a no-op (does not raise) if already at complete state
DO $$
DECLARE
  v_user uuid; v_status text; v_count int;
BEGIN
  v_user := test_helpers.make_user('DelCompleteGuard');

  SET LOCAL ROLE forkensics_executor;
  PERFORM private.prepare_account_deletion(v_user);
  PERFORM private.mark_auth_deleted(v_user);
  PERFORM private.mark_storage_cleaned(v_user);  -- now at 'complete'
  -- Call again — must not raise or regress status
  PERFORM private.prepare_account_deletion(v_user);
  RESET ROLE;

  SELECT status INTO v_status FROM private.deletion_log WHERE profile_id = v_user;
  SELECT COUNT(*) INTO v_count FROM private.deletion_log WHERE profile_id = v_user;
  PERFORM test_helpers.assert(v_status = 'complete', '26.4a: prepare_account_deletion after complete does not regress');
  PERFORM test_helpers.assert(v_count = 1,           '26.4b: no duplicate deletion_log rows after redundant call');
END;
$$;

-- =============================================================================
-- DONE
-- =============================================================================

\echo ''
\echo '============================================================='
\echo 'ALL TESTS PASSED'
\echo '============================================================='
\echo ''
\echo 'Traceability — GPT Review Issues → Test Groups:'
\echo '  Issue  1 (schema order, test_helpers)    → Section 0: schema created before functions'
\echo '  Issue  2 (ON_ERROR_STOP, transaction)    → \set ON_ERROR_STOP on + BEGIN...ROLLBACK'
\echo '  Issue  3 (ROLLBACK in DO blocks)          → No ROLLBACK in any DO block'
\echo '  Issue  4 (WHEN OTHERS = success)          → Group 3: exact SQLSTATE; unexpected re-raised'
\echo '  Issue  5 (UPDATE...LIMIT syntax)          → Group 5: named UUIDs; no UPDATE...LIMIT'
\echo '  Issue  6 (no real assertions)             → Every test has explicit assert() call'
\echo '  Issue  7 (permission wrong reason)        → Group 6: has_function_privilege + 42501'
\echo '  Issue  8 (trigger bypass)                 → Group 5: fixtures via lifecycle functions'
\echo '  Issue  9 (arithmetic-only scoring)        → Group 8: end-to-end via reveal_challenge()'
\echo '  Issue 10 (BYPASSRLS missing)              → Group 2: rolbypassrls assertions'
\echo '  Issue 11 (missing lifecycle coverage)     → Groups 7, 9, 10, 11, 12, 13'
\echo '  Issue 12 (seed config incomplete)         → Group 14: all 14 config keys'
\echo '  Issue 13 (migration blockers)             → Fixed in V1__initial_schema.sql'
\echo ''
\echo 'Traceability — Round 2 Design Decisions → Test Groups:'
\echo '  Decision 1 (exclusion state matrix)       → Group 15: tests 15.1–15.10'
\echo '  Decision 2 (cross-record integrity)       → Group 16: tests 16.1–16.13'
\echo '  Decision 3 (apply_correction contract)    → Group 17: tests 17.1–17.15'
\echo '  Decision 4 (account-deletion lifecycle)   → Group 18: tests 18.1–18.10'
\echo '  Decision 5 (posted_at predicate)          → Group 19: tests 19.1–19.12'
\echo '  Decision 6 (inactive-account protection)  → Group 20: tests 20.1–20.19'
\echo ''
\echo 'Traceability — Step 19 (Closure Pass) → Test Groups:'
\echo '  auth_uid NULLIF fix                        → Group 21: tests 21.1–21.4'
\echo '  reveal_challenge entry points              → Group 22: tests 22.1–22.4'
\echo '  alias uniqueness + guard_alias_edits       → Group 23: tests 23.1–23.4'
\echo '  deletion lifecycle functions               → Group 24: tests 24.1–24.9'
\echo '  WHEN OTHERS → specific SQLSTATE            → All groups 15–20 (inline fix)'
\echo '  Two-session concurrency                    → companion script test_alias_concurrency.sh'
\echo ''
\echo 'Traceability — Round 4 Blockers → Test Groups:'
\echo '  B1 (24h max)                               → Group 3: test 3.1c/3.1d; Group 14: test 14.10'
\echo '  B2 (auth_uid JSON sub NULLIF)              → Group 21: test 21.3 (distinct JSON empty-sub case)'
\echo '  B5 (privilege preflight)                   → Section 0: PREFLIGHT assertions before re-grants'
\echo '  B6 (inactive-account coverage)             → Group 20: tests 20.12–20.19'
\echo '  B7 (Table Talk RLS + tombstone)            → Group 25: tests 25.1–25.6'
\echo '  Additional tightening (svc_role, priv fn)  → Group 26: tests 26.1–26.4'

ROLLBACK;
