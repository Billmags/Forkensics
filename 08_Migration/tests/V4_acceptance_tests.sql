-- =============================================================================
-- Forkensics — V4 Migration Acceptance Tests  (Rev 9 — fixes 8 Codex Rev 8 blockers)
-- Source: Step 26 Rev 15; Task #53 per Codex R6 approval
-- Migration under test: V4__case_investigation_schema.sql
-- Input SHA-256 (R7): f2a30a191cbea02fda3ebac34300a6470b3ab036d2c0454a25f1e0439b261047
--
-- Seven requirements covered:
--   REQ-1  Clean V1→V2→V3→V4 migration — schema objects renamed and present
--   REQ-2  Final postgres role memberships AND temporary schema privileges revoked
--   REQ-3  reserve_upload_session catalog parameter is named p_case_id
--   REQ-4  Two investigations for one case can each create score revision 1
--   REQ-5  Cross-investigation guess isolation enforced after reveal (single case)
--   REQ-6  Cases in 'active' state convert to 'launched' (proof in run_v4_suite.sh)
--   REQ-7  Concurrent photo approval/rejection vs reporting/removal/finalization
--          cannot deadlock (see V4_concurrency_harness.sh)
--
-- Execution (after supabase db reset applying V1+V2+V3+V4):
--   psql "$DATABASE_URL" --set ON_ERROR_STOP=on -f tests/V4_acceptance_tests.sql
--
-- All tests run inside a single BEGIN/ROLLBACK — no test data persists.
-- =============================================================================

\set ON_ERROR_STOP on

BEGIN;

-- service_role membership for this transaction only.
-- GRANT TO is transactional DDL in PostgreSQL and is rolled back by the ROLLBACK below.
-- Local Supabase postgres may not be a superuser or a pre-existing service_role member;
-- this grant guarantees SET LOCAL ROLE service_role succeeds in every test block.
GRANT service_role TO postgres;

-- =============================================================================
-- SECTION 0 — PREFLIGHT
-- REQ-1: tables renamed + V4-only objects present
-- REQ-2: postgres role memberships AND schema CREATE privileges revoked
-- REQ-6: no cases remain in 'active' state (V3→V4 conversion proof in runner)
-- =============================================================================
DO $$
BEGIN
  -- ---- REQ-2a/2b/2c/2d: postgres must not be able to inherit or assume BYPASSRLS roles ----
  -- postgres may retain PostgreSQL 17's automatic creator-administration relationship
  -- (ADMIN=true, INHERIT=false, SET=false) recorded with grantor supabase_admin.
  -- That relationship does not convey privilege inheritance or SET ROLE ability.
  -- What matters for security is USAGE (privilege inheritance) and SET (role assumption).

  IF pg_has_role('postgres', 'forkensics_executor', 'USAGE') THEN
    RAISE EXCEPTION
      'PREFLIGHT FAILED (REQ-2a): postgres inherits forkensics_executor privileges';
  END IF;

  IF pg_has_role('postgres', 'forkensics_executor', 'SET') THEN
    RAISE EXCEPTION
      'PREFLIGHT FAILED (REQ-2b): postgres can SET ROLE forkensics_executor';
  END IF;

  IF pg_has_role('postgres', 'forkensics_rls_helper', 'USAGE') THEN
    RAISE EXCEPTION
      'PREFLIGHT FAILED (REQ-2c): postgres inherits forkensics_rls_helper privileges';
  END IF;

  IF pg_has_role('postgres', 'forkensics_rls_helper', 'SET') THEN
    RAISE EXCEPTION
      'PREFLIGHT FAILED (REQ-2d): postgres can SET ROLE forkensics_rls_helper';
  END IF;

  -- ---- REQ-2e/2f/2g: Phase 20C — temporary schema CREATE privileges revoked ----
  IF has_schema_privilege('forkensics_executor', 'public', 'CREATE') THEN
    RAISE EXCEPTION 'PREFLIGHT FAILED (REQ-2e): forkensics_executor still has CREATE on public schema';
  END IF;

  IF has_schema_privilege('forkensics_executor', 'private', 'CREATE') THEN
    RAISE EXCEPTION 'PREFLIGHT FAILED (REQ-2f): forkensics_executor still has CREATE on private schema';
  END IF;

  IF has_schema_privilege('forkensics_rls_helper', 'private', 'CREATE') THEN
    RAISE EXCEPTION 'PREFLIGHT FAILED (REQ-2g): forkensics_rls_helper still has CREATE on private schema';
  END IF;

  -- ---- REQ-1: V4 tables present ----
  IF NOT EXISTS (SELECT 1 FROM information_schema.tables
                 WHERE table_schema='public' AND table_name='cases') THEN
    RAISE EXCEPTION 'PREFLIGHT FAILED (REQ-1): public.cases missing';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.tables
                 WHERE table_schema='public' AND table_name='case_secrets') THEN
    RAISE EXCEPTION 'PREFLIGHT FAILED (REQ-1): public.case_secrets missing';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.tables
                 WHERE table_schema='public' AND table_name='case_answer_aliases') THEN
    RAISE EXCEPTION 'PREFLIGHT FAILED (REQ-1): public.case_answer_aliases missing';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.tables
                 WHERE table_schema='public' AND table_name='investigations') THEN
    RAISE EXCEPTION 'PREFLIGHT FAILED (REQ-1): public.investigations missing';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.tables
                 WHERE table_schema='public' AND table_name='investigation_members') THEN
    RAISE EXCEPTION 'PREFLIGHT FAILED (REQ-1): public.investigation_members missing';
  END IF;

  -- ---- REQ-1: V3 table names must be gone ----
  IF EXISTS (SELECT 1 FROM information_schema.tables
             WHERE table_schema='public' AND table_name='challenges') THEN
    RAISE EXCEPTION 'PREFLIGHT FAILED (REQ-1): public.challenges still present';
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.tables
             WHERE table_schema='public' AND table_name='challenge_secrets') THEN
    RAISE EXCEPTION 'PREFLIGHT FAILED (REQ-1): public.challenge_secrets still present';
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.tables
             WHERE table_schema='public' AND table_name='challenge_answer_aliases') THEN
    RAISE EXCEPTION 'PREFLIGHT FAILED (REQ-1): public.challenge_answer_aliases still present';
  END IF;

  -- ---- REQ-1: group_id column must NOT exist on cases (dropped in Phase 18) ----
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='cases' AND column_name='group_id'
  ) THEN
    RAISE EXCEPTION 'PREFLIGHT FAILED (REQ-1): cases.group_id column still present (should be dropped in Phase 18)';
  END IF;

  -- ---- REQ-1: score_runs per-investigation constraint ----
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'score_runs_inv_revision_unique'
      AND conrelid = 'public.score_runs'::regclass
  ) THEN
    RAISE EXCEPTION 'PREFLIGHT FAILED (REQ-1): score_runs_inv_revision_unique constraint missing';
  END IF;

  IF EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'score_runs_challenge_id_revision_number_key'
      AND conrelid = 'public.score_runs'::regclass
  ) THEN
    RAISE EXCEPTION 'PREFLIGHT FAILED (REQ-1): score_runs_challenge_id_revision_number_key still present';
  END IF;

  -- ---- REQ-1: V4 functions present ----
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'launch_case'
  ) THEN
    RAISE EXCEPTION 'PREFLIGHT FAILED (REQ-1): public.launch_case function missing';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'reveal_case'
  ) THEN
    RAISE EXCEPTION 'PREFLIGHT FAILED (REQ-1): public.reveal_case function missing';
  END IF;

  -- ---- REQ-6: No cases may remain in 'active' state ----
  -- Full proof (create active row in V3, apply V4, verify it became 'launched')
  -- is in run_v4_suite.sh Step 2 (REQ-6 pre-test). This check only confirms
  -- the conversion has not left any residual 'active' rows.
  IF EXISTS (SELECT 1 FROM public.cases WHERE state = 'active' LIMIT 1) THEN
    RAISE EXCEPTION 'PREFLIGHT FAILED (REQ-6): cases in active state found';
  END IF;

  -- Sanity: 'active' must not appear in the V4 state check constraint
  IF EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'cases_state_check'
      AND conrelid = 'public.cases'::regclass
      AND pg_get_constraintdef(oid) LIKE '%active%'
  ) THEN
    RAISE EXCEPTION 'PREFLIGHT FAILED (REQ-6): cases_state_check still permits active state';
  END IF;

  RAISE NOTICE 'PREFLIGHT PASSED: REQ-1, REQ-2, REQ-6 preflight assertions all verified.';
END;
$$;

-- Re-grant role memberships for the test session (rolled back at ROLLBACK)
GRANT forkensics_executor   TO postgres;
GRANT forkensics_rls_helper TO postgres;

-- =============================================================================
-- SECTION 0.5 — HELPERS (V4-aware, all rolled back with the outer transaction)
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS test_helpers;
GRANT USAGE  ON SCHEMA test_helpers TO authenticated;
GRANT CREATE ON SCHEMA test_helpers TO forkensics_executor;

CREATE OR REPLACE FUNCTION test_helpers.assert(p_condition boolean, p_message text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  -- IS DISTINCT FROM true rejects both FALSE and NULL; IF NOT passes NULL silently.
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

-- Creates auth.users + triggers profile (handle_new_user fires if present).
-- Sets is_active=true so that functions that check profiles.is_active
-- (launch_case, submit_guess, cancel_case, reveal_case) work correctly.
CREATE OR REPLACE FUNCTION test_helpers.make_user(p_display_name text DEFAULT 'Test Player')
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE v_uid uuid := gen_random_uuid();
BEGIN
  INSERT INTO auth.users (id, email, raw_user_meta_data, created_at, updated_at)
  VALUES (v_uid, v_uid || '@test.invalid',
          json_build_object('display_name', p_display_name)::jsonb, now(), now());
  -- Ensure profile exists and has required fields.
  -- is_active=true is required by launch_case / submit_guess / cancel_case / reveal_case.
  INSERT INTO public.profiles (id, display_name, onboarding_complete, is_active)
  VALUES (v_uid, p_display_name, true, true)
  ON CONFLICT (id) DO UPDATE
    SET display_name       = p_display_name,
        onboarding_complete = true,
        is_active           = true;
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

-- Creates a media_objects row + matching storage key
CREATE OR REPLACE FUNCTION test_helpers.make_media_with_key(
  p_uploader_id uuid,
  p_sha256      text DEFAULT 'a665a45920422f9d417e4867efdc4fb8a04a1f3fff1fa07e998e86f7f7a27ae3',
  p_status      text DEFAULT 'ready'
)
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE v_mid uuid := gen_random_uuid();
BEGIN
  INSERT INTO public.media_objects (id, uploader_id, mime_type, status, re_encoded_at)
  VALUES (v_mid, p_uploader_id, 'image/webp', p_status, now());
  INSERT INTO private.media_storage_keys (media_object_id, storage_key, sha256_hash, re_encoded_storage_key)
  VALUES (v_mid, 'uploads/' || v_mid::text || '/original.jpg', p_sha256,
          'cases/test/' || v_mid::text || '/display.webp');
  RETURN v_mid;
END;
$$;

-- Creates a draft case (no group_id — V4 dropped that column; group linkage is via investigations).
-- JWT must identify a valid poster; case_create_fields trigger sets poster_id + state='draft'.
-- Returns (case_id, media_id).
CREATE OR REPLACE FUNCTION test_helpers.make_case(p_poster_id uuid)
RETURNS TABLE(case_id uuid, media_id uuid) LANGUAGE plpgsql AS $$
DECLARE
  v_mid uuid;
  v_cid uuid;
BEGIN
  v_mid := test_helpers.make_media_with_key(
    p_poster_id,
    'b665a45920422f9d417e4867efdc4fb8a04a1f3fff1fa07e998e86f7f7a27ae3'
  );
  PERFORM test_helpers.set_auth_uid(p_poster_id);
  -- V4: cases has no group_id column; poster_id set by trigger from JWT
  INSERT INTO public.cases (media_object_id)
  VALUES (v_mid)
  RETURNING id INTO v_cid;
  INSERT INTO public.case_secrets (case_id, display_dish, canonical_dish,
                                    display_restaurant, canonical_restaurant)
  VALUES (v_cid, 'Test Dish', 'test dish', 'Test Place', 'test place');
  PERFORM test_helpers.clear_auth_uid();
  RETURN QUERY SELECT v_cid, v_mid;
END;
$$;

-- Creates an investigation for a case+group.
-- Does NOT add the poster as a member — posters are not investigation participants.
-- To add members, call make_investigation_member separately.
CREATE OR REPLACE FUNCTION test_helpers.make_investigation(
  p_case_id  uuid,
  p_group_id uuid
) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE v_inv_id uuid := gen_random_uuid();
BEGIN
  INSERT INTO public.investigations (investigation_id, case_id, group_id, status)
  VALUES (v_inv_id, p_case_id, p_group_id, 'active');
  RETURN v_inv_id;
END;
$$;

CREATE OR REPLACE FUNCTION test_helpers.make_investigation_member(
  p_inv_id    uuid,
  p_player_id uuid
) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO public.investigation_members
    (investigation_id, player_id, snapshot_display_name, snapshot_avatar_color, eligibility_status)
  VALUES
    (p_inv_id, p_player_id, 'Test Member', 'blue', 'eligible');
END;
$$;

-- Reveals a case for one investigation. SECURITY DEFINER owned by forkensics_executor
-- so the state update bypasses protect_case_authority_fields.
CREATE OR REPLACE FUNCTION test_helpers.do_reveal_v4(p_case_id uuid, p_investigation_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  UPDATE public.cases
  SET state = 'revealed', revealed_at = clock_timestamp()
  WHERE id = p_case_id;
  PERFORM private.do_reveal_impl_v3(p_case_id, p_investigation_id);
END;
$$;
ALTER FUNCTION test_helpers.do_reveal_v4(uuid, uuid) OWNER TO forkensics_executor;

-- Inserts a guess as forkensics_executor (authenticated INSERT is revoked in V4).
-- The set_guess_receipt_fields trigger auto-sets received_at + receipt_sequence.
CREATE OR REPLACE FUNCTION test_helpers.make_guess_v4(
  p_player_id uuid,
  p_case_id   uuid,
  p_race      text DEFAULT 'what',
  p_guess     text DEFAULT 'Test Dish'
) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE v_id uuid := gen_random_uuid();
BEGIN
  SET LOCAL ROLE forkensics_executor;
  INSERT INTO public.guess_attempts (id, case_id, player_id, race, dish_guess, restaurant_guess)
  VALUES (
    v_id, p_case_id, p_player_id, p_race,
    CASE WHEN p_race = 'what'  THEN p_guess ELSE NULL END,
    CASE WHEN p_race = 'where' THEN p_guess ELSE NULL END
  );
  RESET ROLE;
  RETURN v_id;
END;
$$;

GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA test_helpers TO authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA test_helpers TO forkensics_executor;

\echo ''
\echo '============================================================='
\echo 'Forkensics V4 Acceptance Tests'
\echo '============================================================='

-- =============================================================================
-- GROUP 1 — REQ-3: reserve_upload_session catalog parameter is named p_case_id
--
-- Uses to_regprocedure() for an exact overload-safe lookup so that a stale
-- overloaded variant with a different name cannot produce a false PASS.
-- =============================================================================
\echo ''
\echo '--- GROUP 1: REQ-3 — reserve_upload_session catalog parameter name ---'

DO $$
DECLARE
  v_oid      oid;
  v_argnames text[];
  v_first    text;
BEGIN
  -- Exact overload: (p_case_id uuid, p_uploader_id uuid, p_content_type text,
  --                  p_token_hash text, p_declared_size bigint, p_client_expires_at timestamptz)
  v_oid := 'public.reserve_upload_session(uuid,uuid,text,text,bigint,timestamptz)'::regprocedure;

  SELECT proargnames INTO v_argnames FROM pg_proc WHERE oid = v_oid;

  IF v_argnames IS NULL THEN
    RAISE EXCEPTION 'REQ-3 FAIL: proargnames is NULL for reserve_upload_session';
  END IF;

  v_first := v_argnames[1];

  PERFORM test_helpers.assert(
    v_first = 'p_case_id',
    'REQ-3 — first catalog parameter of reserve_upload_session is p_case_id (got: '
      || COALESCE(v_first, 'NULL') || ')');

  PERFORM test_helpers.assert(
    'p_challenge_id' != ALL(v_argnames),
    'REQ-3 — p_challenge_id is absent from the parameter list');
END;
$$;

-- =============================================================================
-- GROUP 2 — REQ-4: Two investigations for one case can each create score rev 1
--
-- The V4 constraint UNIQUE(investigation_id, revision_number) allows this.
-- The old V1 constraint UNIQUE(case_id, revision_number) would have blocked it.
--
-- B10 fix: the poster is NOT added as an investigation member (posters are not
-- investigation participants). Two separate non-poster players are used.
-- =============================================================================
\echo ''
\echo '--- GROUP 2: REQ-4 — per-investigation score_runs uniqueness ---'

DO $$
DECLARE
  v_poster  uuid;
  v_player1 uuid;
  v_player2 uuid;
  v_gid_a   uuid;
  v_gid_b   uuid;
  v_cid     uuid;
  v_mid     uuid;
  v_inv_a   uuid;
  v_inv_b   uuid;
  v_sr_a_id uuid;
  v_sr_b_id uuid;
  v_rev_a   int;
  v_rev_b   int;
BEGIN
  v_poster  := test_helpers.make_user('REQ4 Poster');
  v_player1 := test_helpers.make_user('REQ4 Player1');
  v_player2 := test_helpers.make_user('REQ4 Player2');
  v_gid_a   := test_helpers.make_group(v_poster, 'REQ4 GroupA');
  v_gid_b   := test_helpers.make_group(v_poster, 'REQ4 GroupB');

  SELECT case_id, media_id INTO v_cid, v_mid FROM test_helpers.make_case(v_poster);

  -- Two investigations for the SAME case, different groups.
  -- Poster is NOT a member of either investigation.
  v_inv_a := test_helpers.make_investigation(v_cid, v_gid_a);
  v_inv_b := test_helpers.make_investigation(v_cid, v_gid_b);

  PERFORM test_helpers.make_investigation_member(v_inv_a, v_player1);
  PERFORM test_helpers.make_investigation_member(v_inv_b, v_player2);

  -- Reveal case for investigation A → creates revision_number=1 score_run for inv_a
  PERFORM test_helpers.do_reveal_v4(v_cid, v_inv_a);

  SELECT id INTO v_sr_a_id FROM public.score_runs
  WHERE investigation_id = v_inv_a ORDER BY revision_number DESC LIMIT 1;
  SELECT revision_number INTO v_rev_a FROM public.score_runs WHERE id = v_sr_a_id;

  PERFORM test_helpers.assert(v_rev_a = 1,
    'REQ-4a — investigation A creates score_run revision_number=1');

  -- Reveal case for investigation B → must ALSO create revision_number=1
  -- (UNIQUE(investigation_id, revision_number) allows this; old UNIQUE(case_id, revision_number) would fail)
  PERFORM test_helpers.do_reveal_v4(v_cid, v_inv_b);

  SELECT id INTO v_sr_b_id FROM public.score_runs
  WHERE investigation_id = v_inv_b ORDER BY revision_number DESC LIMIT 1;
  SELECT revision_number INTO v_rev_b FROM public.score_runs WHERE id = v_sr_b_id;

  PERFORM test_helpers.assert(v_rev_b = 1,
    'REQ-4b — investigation B also creates score_run revision_number=1 (same case_id, different investigation_id)');

  PERFORM test_helpers.assert(
    (SELECT COUNT(*) FROM public.score_runs WHERE case_id = v_cid AND revision_number = 1) = 2,
    'REQ-4c — exactly 2 score_run rows with revision_number=1 exist for the same case_id');

  PERFORM test_helpers.assert(v_sr_a_id IS DISTINCT FROM v_sr_b_id,
    'REQ-4d — the two revision-1 score_runs have distinct IDs');
END;
$$;

-- =============================================================================
-- GROUP 3 — REQ-5: Cross-investigation guess isolation (single case, two invs)
--
-- Setup:
--   One case.
--   Investigation A: player P (guesser) and player P2 (co-investigator) are members.
--   Investigation B: player Q is a member. Q has NO membership in Investigation A.
--
-- After revealing Investigation A:
--   POSITIVE: P2 (same investigation as P) CAN see P's guess.
--   NEGATIVE: Q (different investigation, same case) CANNOT see P's guess.
--
-- This tests the `guess_investigation_revealed_view` PERMISSIVE policy which
-- requires the viewer and guesser to share the same investigation row.
-- The RESTRICTIVE `block_aware_visibility` passes for both P2 and Q (both have
-- investigation membership for this case, so can_view_case=true), but Q gets
-- zero rows because no PERMISSIVE policy grants cross-investigation access.
-- =============================================================================
\echo ''
\echo '--- GROUP 3: REQ-5 — cross-investigation isolation (single case) ---'

DO $$
DECLARE
  v_poster  uuid;
  v_player_p   uuid;   -- guesser, in Investigation A
  v_player_p2  uuid;   -- co-investigator, in Investigation A (positive baseline)
  v_player_q   uuid;   -- in Investigation B only (must be isolated)
  v_gid_a      uuid;
  v_gid_b      uuid;
  v_cid        uuid;
  v_mid        uuid;
  v_inv_a      uuid;
  v_inv_b      uuid;
  v_cnt        int;
BEGIN
  -- ---- fixture ----
  v_poster    := test_helpers.make_user('REQ5 Poster');
  v_player_p  := test_helpers.make_user('REQ5 Player-P');
  v_player_p2 := test_helpers.make_user('REQ5 Player-P2');
  v_player_q  := test_helpers.make_user('REQ5 Player-Q');

  v_gid_a := test_helpers.make_group(v_poster, 'REQ5 GroupA');
  v_gid_b := test_helpers.make_group(v_poster, 'REQ5 GroupB');

  SELECT case_id, media_id INTO v_cid, v_mid FROM test_helpers.make_case(v_poster);

  -- Investigation A: P and P2 are members
  v_inv_a := test_helpers.make_investigation(v_cid, v_gid_a);
  PERFORM test_helpers.make_investigation_member(v_inv_a, v_player_p);
  PERFORM test_helpers.make_investigation_member(v_inv_a, v_player_p2);

  -- Investigation B: Q is a member (same case, different investigation)
  v_inv_b := test_helpers.make_investigation(v_cid, v_gid_b);
  PERFORM test_helpers.make_investigation_member(v_inv_b, v_player_q);

  -- P makes a guess on the case
  PERFORM test_helpers.make_guess_v4(v_player_p, v_cid, 'what', 'Test Dish');

  -- Verify the guess row exists in DB (bypassing RLS as postgres)
  PERFORM test_helpers.assert(
    EXISTS (SELECT 1 FROM public.guess_attempts WHERE case_id = v_cid AND player_id = v_player_p),
    'REQ-5 setup — P guess_attempt for the case exists in DB');

  -- Reveal the case (sets state='revealed') for Investigation A
  PERFORM test_helpers.do_reveal_v4(v_cid, v_inv_a);

  -- ---- REQ-5 POSITIVE: P2 (in inv_a) sees P''s guess after reveal ----
  -- guess_investigation_revealed_view: P2 and P share inv_a, case is revealed → GRANTS
  -- block_aware_visibility: can_view_case(case_id) = true (P2 in inv_a) → PASSES
  PERFORM test_helpers.set_auth_uid(v_player_p2);
  SELECT COUNT(*) INTO v_cnt FROM public.guess_attempts
  WHERE case_id = v_cid AND player_id = v_player_p;
  PERFORM test_helpers.clear_auth_uid();

  PERFORM test_helpers.assert(v_cnt = 1,
    'REQ-5 POSITIVE — P2 (Investigation A member) sees P''s guess after reveal');

  -- ---- REQ-5 NEGATIVE: Q (in inv_b only) sees 0 of P''s guess rows ----
  -- guess_investigation_revealed_view: Q in inv_b, P in inv_a → different investigation → DENIES
  -- guess_own_view: not Q''s guess → DENIES
  -- guess_poster_view: Q is not the case poster → DENIES
  -- block_aware_visibility: can_view_case(case_id) = true (Q in inv_b) → PASSES (does not block)
  -- Net: no PERMISSIVE policy grants → 0 rows
  PERFORM test_helpers.set_auth_uid(v_player_q);
  SELECT COUNT(*) INTO v_cnt FROM public.guess_attempts
  WHERE case_id = v_cid AND player_id = v_player_p;
  PERFORM test_helpers.clear_auth_uid();

  PERFORM test_helpers.assert(v_cnt = 0,
    'REQ-5 NEGATIVE — Q (Investigation B only) cannot see P''s guess (cross-investigation isolation)');

  -- ---- REQ-5 NEGATIVE-SELF: Q also sees 0 rows via a broad case query ----
  PERFORM test_helpers.set_auth_uid(v_player_q);
  SELECT COUNT(*) INTO v_cnt FROM public.guess_attempts WHERE case_id = v_cid;
  PERFORM test_helpers.clear_auth_uid();

  PERFORM test_helpers.assert(v_cnt = 0,
    'REQ-5 NEGATIVE-SELF — Q sees 0 guess_attempts for the case via a broad query');
END;
$$;

-- =============================================================================
-- GROUP 4 — launch_case: happy path + poster-only enforcement
--
-- Tests that:
--   GRP4-a  case transitions to 'launched' state
--   GRP4-b  investigation row created for the launched group
--   GRP4-c  exactly one investigation_member (detective, not poster)
--   GRP4-d  non-poster cannot launch (FK_FORBIDDEN)
-- =============================================================================
\echo ''
\echo '--- GROUP 4: launch_case happy path and poster-only enforcement ---'

DO $$
DECLARE
  v_poster    uuid;
  v_poster2   uuid;
  v_detective uuid;
  v_gid       uuid;
  v_gid2      uuid;
  v_cid       uuid;
  v_cid2      uuid;
  v_mid       uuid;
  v_mid2      uuid;
  v_err       text;    -- captures SQLERRM for specific FK_* check
BEGIN
  v_poster    := test_helpers.make_user('GRP4 Poster');
  v_poster2   := test_helpers.make_user('GRP4 Poster2');
  v_detective := test_helpers.make_user('GRP4 Detective');

  -- Group A: poster owns it; detective is a member (satisfies ≥1 detective requirement)
  v_gid := test_helpers.make_group(v_poster, 'GRP4 Group');
  PERFORM test_helpers.add_member(v_gid, v_poster, v_detective);

  -- Draft case with ready media (make_media_with_key defaults to status='ready')
  SELECT case_id, media_id INTO v_cid, v_mid FROM test_helpers.make_case(v_poster);

  -- Advance to 'ready' as executor (approve_photo would normally do this)
  SET LOCAL ROLE forkensics_executor;
  UPDATE public.cases SET state = 'ready' WHERE id = v_cid;
  RESET ROLE;

  -- ---- GRP4 happy path: poster launches ----
  PERFORM test_helpers.set_auth_uid(v_poster);
  PERFORM public.launch_case(v_cid, v_poster, ARRAY[v_gid], 7200);
  PERFORM test_helpers.clear_auth_uid();

  PERFORM test_helpers.assert(
    (SELECT state FROM public.cases WHERE id = v_cid) = 'launched',
    'GRP4-a — launch_case transitions case state to launched');

  PERFORM test_helpers.assert(
    EXISTS (SELECT 1 FROM public.investigations WHERE case_id = v_cid AND group_id = v_gid),
    'GRP4-b — investigation row created for the launched group');

  PERFORM test_helpers.assert(
    (SELECT COUNT(*) FROM public.investigation_members im
     JOIN public.investigations i ON i.investigation_id = im.investigation_id
     WHERE i.case_id = v_cid) = 1,
    'GRP4-c — exactly 1 investigation_member (detective, not poster)');

  -- ---- GRP4 non-poster cannot launch ----
  v_gid2 := test_helpers.make_group(v_poster2, 'GRP4 Group2');
  PERFORM test_helpers.add_member(v_gid2, v_poster2, v_detective);
  SELECT case_id, media_id INTO v_cid2, v_mid2 FROM test_helpers.make_case(v_poster2);
  SET LOCAL ROLE forkensics_executor;
  UPDATE public.cases SET state = 'ready' WHERE id = v_cid2;
  RESET ROLE;

  -- B1 fix: require FK_FORBIDDEN specifically; re-raise any unexpected error
  BEGIN
    PERFORM test_helpers.set_auth_uid(v_detective);
    PERFORM public.launch_case(v_cid2, v_detective, ARRAY[v_gid2], 7200);
    RAISE EXCEPTION 'UNEXPECTED_SUCCESS: launch_case should have raised FK_FORBIDDEN for non-poster';
  EXCEPTION WHEN OTHERS THEN
    v_err := SQLERRM;
    PERFORM test_helpers.clear_auth_uid();
    IF v_err LIKE '%UNEXPECTED_SUCCESS%' THEN RAISE; END IF;
    IF v_err NOT LIKE '%FK_FORBIDDEN%' THEN
      RAISE EXCEPTION 'WRONG_EXCEPTION: expected FK_FORBIDDEN, got: %', v_err;
    END IF;
  END;

  PERFORM test_helpers.assert(true,
    'GRP4-d — non-poster cannot launch case (FK_FORBIDDEN exactly)');
END;
$$;

-- =============================================================================
-- GROUP 5 — submit_guess: member can guess; poster and non-member cannot
--
-- Tests that:
--   GRP5-a  eligible investigation member can submit a guess
--   GRP5-b  guess_attempts row created for the detective
--   GRP5-c  poster cannot submit guess (FK_FORBIDDEN)
--   GRP5-d  non-member cannot submit guess (FK_FORBIDDEN)
-- =============================================================================
\echo ''
\echo '--- GROUP 5: submit_guess eligibility ---'

DO $$
DECLARE
  v_poster    uuid;
  v_detective uuid;
  v_other     uuid;
  v_gid       uuid;
  v_cid       uuid;
  v_mid       uuid;
  v_inv_id    uuid;
  v_guess_id  uuid;
  v_err       text;
BEGIN
  v_poster    := test_helpers.make_user('GRP5 Poster');
  v_detective := test_helpers.make_user('GRP5 Detective');
  v_other     := test_helpers.make_user('GRP5 Other');
  v_gid       := test_helpers.make_group(v_poster, 'GRP5 Group');

  SELECT case_id, media_id INTO v_cid, v_mid FROM test_helpers.make_case(v_poster);

  -- Advance directly to 'launched' (skipping 'ready' state is fine for test setup
  -- since we use executor to bypass protect_case_authority_fields)
  SET LOCAL ROLE forkensics_executor;
  UPDATE public.cases
  SET state       = 'launched',
      posted_at   = clock_timestamp() - interval '1 hour',
      deadline_at = clock_timestamp() + interval '2 hours'
  WHERE id = v_cid;
  RESET ROLE;

  -- Investigation with detective as eligible member
  v_inv_id := test_helpers.make_investigation(v_cid, v_gid);
  PERFORM test_helpers.make_investigation_member(v_inv_id, v_detective);

  -- ---- GRP5 positive: eligible member submits guess ----
  PERFORM test_helpers.set_auth_uid(v_detective);
  v_guess_id := public.submit_guess(v_cid, v_inv_id, 'what', 'Test Dish', NULL, NULL);
  PERFORM test_helpers.clear_auth_uid();

  PERFORM test_helpers.assert(v_guess_id IS NOT NULL,
    'GRP5-a — eligible investigation member can submit a guess');

  PERFORM test_helpers.assert(
    EXISTS (SELECT 1 FROM public.guess_attempts WHERE id = v_guess_id AND player_id = v_detective),
    'GRP5-b — guess_attempts row created for the detective');

  -- ---- GRP5 negative: poster cannot guess (FK_FORBIDDEN exactly) ----
  BEGIN
    PERFORM test_helpers.set_auth_uid(v_poster);
    PERFORM public.submit_guess(v_cid, v_inv_id, 'what', 'Test Dish', NULL, NULL);
    RAISE EXCEPTION 'UNEXPECTED_SUCCESS: submit_guess should have raised FK_FORBIDDEN for poster';
  EXCEPTION WHEN OTHERS THEN
    v_err := SQLERRM;
    PERFORM test_helpers.clear_auth_uid();
    IF v_err LIKE '%UNEXPECTED_SUCCESS%' THEN RAISE; END IF;
    IF v_err NOT LIKE '%FK_FORBIDDEN%' THEN
      RAISE EXCEPTION 'WRONG_EXCEPTION: expected FK_FORBIDDEN, got: %', v_err;
    END IF;
  END;
  PERFORM test_helpers.assert(true,
    'GRP5-c — poster cannot submit guess (FK_FORBIDDEN exactly)');

  -- ---- GRP5 negative: non-member cannot guess (FK_FORBIDDEN exactly) ----
  BEGIN
    PERFORM test_helpers.set_auth_uid(v_other);
    PERFORM public.submit_guess(v_cid, v_inv_id, 'what', 'Test Dish', NULL, NULL);
    RAISE EXCEPTION 'UNEXPECTED_SUCCESS: submit_guess should have raised FK_FORBIDDEN for non-member';
  EXCEPTION WHEN OTHERS THEN
    v_err := SQLERRM;
    PERFORM test_helpers.clear_auth_uid();
    IF v_err LIKE '%UNEXPECTED_SUCCESS%' THEN RAISE; END IF;
    IF v_err NOT LIKE '%FK_FORBIDDEN%' THEN
      RAISE EXCEPTION 'WRONG_EXCEPTION: expected FK_FORBIDDEN, got: %', v_err;
    END IF;
  END;
  PERFORM test_helpers.assert(true,
    'GRP5-d — non-member cannot submit guess (FK_FORBIDDEN exactly)');
END;
$$;

-- =============================================================================
-- GROUP 6 — cancel_case: poster can cancel; non-poster cannot; investigations cancelled
--
-- Tests that:
--   GRP6-a  non-poster cannot cancel (FK_FORBIDDEN)
--   GRP6-b  poster can cancel a launched case; state becomes 'cancelled'
--   GRP6-c  active investigation is cancelled along with the case
-- =============================================================================
\echo ''
\echo '--- GROUP 6: cancel_case poster-only enforcement and investigation cascade ---'

DO $$
DECLARE
  v_poster    uuid;
  v_detective uuid;
  v_gid       uuid;
  v_cid       uuid;
  v_mid       uuid;
  v_inv_id    uuid;
  v_err       text;
BEGIN
  v_poster    := test_helpers.make_user('GRP6 Poster');
  v_detective := test_helpers.make_user('GRP6 Detective');
  v_gid       := test_helpers.make_group(v_poster, 'GRP6 Group');

  SELECT case_id, media_id INTO v_cid, v_mid FROM test_helpers.make_case(v_poster);
  SET LOCAL ROLE forkensics_executor;
  UPDATE public.cases
  SET state       = 'launched',
      posted_at   = clock_timestamp() - interval '1 hour',
      deadline_at = clock_timestamp() + interval '2 hours'
  WHERE id = v_cid;
  RESET ROLE;

  v_inv_id := test_helpers.make_investigation(v_cid, v_gid);
  PERFORM test_helpers.make_investigation_member(v_inv_id, v_detective);

  -- ---- GRP6 negative: non-poster cannot cancel (FK_FORBIDDEN exactly) ----
  BEGIN
    PERFORM test_helpers.set_auth_uid(v_detective);
    PERFORM public.cancel_case(v_cid, 'GRP6 non-poster cancel attempt');
    RAISE EXCEPTION 'UNEXPECTED_SUCCESS: cancel_case should have raised FK_FORBIDDEN for non-poster';
  EXCEPTION WHEN OTHERS THEN
    v_err := SQLERRM;
    PERFORM test_helpers.clear_auth_uid();
    IF v_err LIKE '%UNEXPECTED_SUCCESS%' THEN RAISE; END IF;
    IF v_err NOT LIKE '%FK_FORBIDDEN%' THEN
      RAISE EXCEPTION 'WRONG_EXCEPTION: expected FK_FORBIDDEN, got: %', v_err;
    END IF;
  END;
  PERFORM test_helpers.assert(true,
    'GRP6-a — non-poster cannot cancel case (FK_FORBIDDEN exactly)');

  PERFORM test_helpers.assert(
    (SELECT state FROM public.cases WHERE id = v_cid) = 'launched',
    'GRP6-a-guard — case still launched after rejected cancel attempt');

  -- ---- GRP6 positive: poster cancels launched case ----
  PERFORM test_helpers.set_auth_uid(v_poster);
  PERFORM public.cancel_case(v_cid, 'GRP6 poster cancellation');
  PERFORM test_helpers.clear_auth_uid();

  PERFORM test_helpers.assert(
    (SELECT state FROM public.cases WHERE id = v_cid) = 'cancelled',
    'GRP6-b — poster can cancel launched case; state becomes cancelled');

  PERFORM test_helpers.assert(
    (SELECT status FROM public.investigations WHERE investigation_id = v_inv_id) = 'cancelled',
    'GRP6-c — active investigation is cancelled along with the case');
END;
$$;

-- =============================================================================
-- GROUP 7 — reveal_case: all investigations get score_runs; state becomes 'revealed'
--
-- Tests that:
--   GRP7-a  reveal_case sets case state to 'revealed'
--   GRP7-b  investigation A gets a score_run with revision_number=1
--   GRP7-c  investigation B gets a score_run with revision_number=1
--   GRP7-d  exactly 2 score_runs created (one per investigation)
-- =============================================================================
\echo ''
\echo '--- GROUP 7: reveal_case scores all investigations ---'

DO $$
DECLARE
  v_poster    uuid;
  v_player1   uuid;
  v_player2   uuid;
  v_gid_a     uuid;
  v_gid_b     uuid;
  v_cid       uuid;
  v_mid       uuid;
  v_inv_a     uuid;
  v_inv_b     uuid;
  v_sr_count  bigint;
BEGIN
  v_poster  := test_helpers.make_user('GRP7 Poster');
  v_player1 := test_helpers.make_user('GRP7 Player1');
  v_player2 := test_helpers.make_user('GRP7 Player2');
  v_gid_a   := test_helpers.make_group(v_poster, 'GRP7 GroupA');
  v_gid_b   := test_helpers.make_group(v_poster, 'GRP7 GroupB');

  SELECT case_id, media_id INTO v_cid, v_mid FROM test_helpers.make_case(v_poster);
  v_inv_a := test_helpers.make_investigation(v_cid, v_gid_a);
  v_inv_b := test_helpers.make_investigation(v_cid, v_gid_b);
  PERFORM test_helpers.make_investigation_member(v_inv_a, v_player1);
  PERFORM test_helpers.make_investigation_member(v_inv_b, v_player2);

  -- Advance to 'locked' (reveal_case requires state='locked')
  SET LOCAL ROLE forkensics_executor;
  UPDATE public.cases
  SET state       = 'locked',
      posted_at   = clock_timestamp() - interval '3 hours',
      deadline_at = clock_timestamp() - interval '1 hour'
  WHERE id = v_cid;
  RESET ROLE;

  -- Poster reveals via reveal_case (JWT required; function is SECURITY DEFINER)
  PERFORM test_helpers.set_auth_uid(v_poster);
  PERFORM public.reveal_case(v_cid);
  PERFORM test_helpers.clear_auth_uid();

  PERFORM test_helpers.assert(
    (SELECT state FROM public.cases WHERE id = v_cid) = 'revealed',
    'GRP7-a — reveal_case sets case state to revealed');

  PERFORM test_helpers.assert(
    EXISTS (SELECT 1 FROM public.score_runs
            WHERE investigation_id = v_inv_a AND revision_number = 1),
    'GRP7-b — investigation A gets score_run revision 1 on reveal');

  PERFORM test_helpers.assert(
    EXISTS (SELECT 1 FROM public.score_runs
            WHERE investigation_id = v_inv_b AND revision_number = 1),
    'GRP7-c — investigation B gets score_run revision 1 on reveal');

  SELECT COUNT(*) INTO v_sr_count FROM public.score_runs WHERE case_id = v_cid;
  PERFORM test_helpers.assert(v_sr_count = 2,
    'GRP7-d — exactly 2 score_runs created (one per active investigation)');
END;
$$;

-- =============================================================================
-- GROUP 8 — Grants: authenticated role cannot directly INSERT into guess_attempts
--
-- B2 fix (Rev 4): Three-layer proof:
--   GRP8-a  Privilege catalog: has_table_privilege('authenticated', ..., 'INSERT') = false
--   GRP8-b  Runtime enforcement: INSERT with a VALID fixture is blocked with
--           insufficient_privilege (SQLSTATE 42501); a random nonexistent case_id
--           would mask the real cause via FK violation, so we use a real case.
-- =============================================================================
\echo ''
\echo '--- GROUP 8: grants — authenticated cannot INSERT into guess_attempts ---'

DO $$
DECLARE
  v_poster  uuid;
  v_player  uuid;
  v_cid     uuid;
  v_mid     uuid;
  v_err     text;
BEGIN
  -- ---- GRP8-a: privilege catalog check (no DB row needed) ----
  PERFORM test_helpers.assert(
    NOT has_table_privilege('authenticated', 'public.guess_attempts', 'INSERT'),
    'GRP8-a — INSERT on guess_attempts is NOT granted to authenticated role (catalog check)');

  -- ---- GRP8-b: runtime enforcement with a valid, fully-linked fixture ----
  -- Using a random nonexistent case_id would pass via FK violation regardless of
  -- whether INSERT is granted; we need a real case_id to isolate the privilege check.
  v_poster := test_helpers.make_user('GRP8 Poster');
  v_player := test_helpers.make_user('GRP8 Player');
  SELECT case_id, media_id INTO v_cid, v_mid FROM test_helpers.make_case(v_poster);
  SET LOCAL ROLE forkensics_executor;
  UPDATE public.cases
  SET state       = 'launched',
      posted_at   = clock_timestamp() - interval '1 hour',
      deadline_at = clock_timestamp() + interval '2 hours'
  WHERE id = v_cid;
  RESET ROLE;

  PERFORM test_helpers.set_auth_uid(v_player);
  BEGIN
    INSERT INTO public.guess_attempts (case_id, player_id, race, dish_guess)
    VALUES (v_cid, v_player, 'what', 'Test Dish');
    RAISE EXCEPTION 'UNEXPECTED_SUCCESS: direct INSERT should be blocked with insufficient_privilege';
  EXCEPTION
    WHEN insufficient_privilege THEN              -- SQLSTATE 42501 — correct
      PERFORM test_helpers.clear_auth_uid();
    WHEN OTHERS THEN
      v_err := SQLERRM;
      PERFORM test_helpers.clear_auth_uid();
      IF v_err LIKE '%UNEXPECTED_SUCCESS%' THEN RAISE; END IF;
      RAISE EXCEPTION 'WRONG_EXCEPTION: expected insufficient_privilege (42501), got: %', v_err;
  END;

  PERFORM test_helpers.assert(true,
    'GRP8-b — authenticated direct INSERT into guess_attempts blocked with insufficient_privilege (42501)');
END;
$$;

-- =============================================================================
-- GROUP 9 — Investigation UNIQUE constraint: UNIQUE(case_id, group_id)
--
-- Each (case_id, group_id) pair can have at most one investigation.
-- A second investigation for the same pair must be rejected.
--
-- Tests that:
--   GRP9-a  first investigation for a (case, group) pair succeeds
--   GRP9-b  duplicate (case_id, group_id) investigation is rejected
-- =============================================================================
\echo ''
\echo '--- GROUP 9: investigations UNIQUE(case_id, group_id) constraint ---'

DO $$
DECLARE
  v_poster  uuid;
  v_gid     uuid;
  v_cid     uuid;
  v_mid     uuid;
  v_inv_id  uuid;
BEGIN
  v_poster := test_helpers.make_user('GRP9 Poster');
  v_gid    := test_helpers.make_group(v_poster, 'GRP9 Group');
  SELECT case_id, media_id INTO v_cid, v_mid FROM test_helpers.make_case(v_poster);

  -- First investigation for (case, group): must succeed
  v_inv_id := test_helpers.make_investigation(v_cid, v_gid);
  PERFORM test_helpers.assert(v_inv_id IS NOT NULL,
    'GRP9-a — first investigation for (case, group) pair succeeds');

  -- Second investigation with same (case_id, group_id): must fail with unique_violation.
  -- B3 fix (Rev 4): only unique_violation is accepted; any other exception propagates
  -- (no WHEN OTHERS catch), causing the DO block to fail and exposing the wrong error.
  BEGIN
    PERFORM test_helpers.make_investigation(v_cid, v_gid);
    -- If we reach here, the UNIQUE constraint was not enforced:
    RAISE EXCEPTION 'UNEXPECTED_SUCCESS: duplicate investigation should have been rejected by UNIQUE constraint';
  EXCEPTION
    WHEN unique_violation THEN NULL; -- correct: constraint enforced
    -- All other exceptions (including UNEXPECTED_SUCCESS) propagate automatically
  END;
  PERFORM test_helpers.assert(true,
    'GRP9-b — duplicate (case_id, group_id) investigation is rejected (unique_violation exactly)');
END;
$$;

-- =============================================================================
-- GROUP 10 — Privilege assertions: complete function and table grant matrix
--
-- Confirms that the V4 grant/revoke matrix is correctly applied. Covers:
--   • Functions granted to authenticated (public game functions + private RLS helpers)
--   • Functions NOT granted to authenticated (moderator/service-role only)
--   • Table-level INSERT privileges: granted and withheld
-- =============================================================================
\echo ''
\echo '--- GROUP 10: complete privilege/grant assertions ---'

DO $$
BEGIN
  -- ===== Table privileges =====

  -- GRP10-a: authenticated has no INSERT on guess_attempts (executor only)
  PERFORM test_helpers.assert(
    NOT has_table_privilege('authenticated', 'public.guess_attempts', 'INSERT'),
    'GRP10-a — authenticated has no INSERT on public.guess_attempts');

  -- GRP10-b: authenticated creates draft cases directly; triggers and RLS enforce authority.
  PERFORM test_helpers.assert(
    has_table_privilege('authenticated', 'public.cases', 'INSERT'),
    'GRP10-b — authenticated CAN INSERT draft cases; triggers and RLS enforce access');

  -- GRP10-c: authenticated has no INSERT on public.investigations (SELECT only)
  PERFORM test_helpers.assert(
    NOT has_table_privilege('authenticated', 'public.investigations', 'INSERT'),
    'GRP10-c — authenticated has no INSERT on public.investigations');

  -- GRP10-d: authenticated CAN insert into public.clues (V1 grant; RLS controls access)
  PERFORM test_helpers.assert(
    has_table_privilege('authenticated', 'public.clues', 'INSERT'),
    'GRP10-d — authenticated CAN INSERT on public.clues (V1 grant; RLS enforces access)');

  -- GRP10-e: authenticated CAN insert into public.comments (V1 grant)
  PERFORM test_helpers.assert(
    has_table_privilege('authenticated', 'public.comments', 'INSERT'),
    'GRP10-e — authenticated CAN INSERT on public.comments (V1 grant)');

  -- GRP10-f: authenticated CAN delete from public.reactions (V1 grant)
  PERFORM test_helpers.assert(
    has_table_privilege('authenticated', 'public.reactions', 'DELETE'),
    'GRP10-f — authenticated CAN DELETE from public.reactions (V1 grant)');

  -- ===== Public game functions granted to authenticated =====

  -- GRP10-g: submit_guess
  PERFORM test_helpers.assert(
    has_function_privilege('authenticated',
      'public.submit_guess(uuid,uuid,text,text,text,timestamptz)'::regprocedure, 'EXECUTE'),
    'GRP10-g — authenticated can EXECUTE public.submit_guess');

  -- GRP10-h: launch_case
  PERFORM test_helpers.assert(
    has_function_privilege('authenticated',
      'public.launch_case(uuid,uuid,uuid[],integer)'::regprocedure, 'EXECUTE'),
    'GRP10-h — authenticated can EXECUTE public.launch_case');

  -- GRP10-i: cancel_case
  PERFORM test_helpers.assert(
    has_function_privilege('authenticated',
      'public.cancel_case(uuid,text)'::regprocedure, 'EXECUTE'),
    'GRP10-i — authenticated can EXECUTE public.cancel_case');

  -- GRP10-j: cancel_investigation
  PERFORM test_helpers.assert(
    has_function_privilege('authenticated',
      'public.cancel_investigation(uuid,text)'::regprocedure, 'EXECUTE'),
    'GRP10-j — authenticated can EXECUTE public.cancel_investigation');

  -- GRP10-k: reveal_case
  PERFORM test_helpers.assert(
    has_function_privilege('authenticated',
      'public.reveal_case(uuid)'::regprocedure, 'EXECUTE'),
    'GRP10-k — authenticated can EXECUTE public.reveal_case');

  -- GRP10-l: report_content
  PERFORM test_helpers.assert(
    has_function_privilege('authenticated',
      'public.report_content(text,uuid,text,text)'::regprocedure, 'EXECUTE'),
    'GRP10-l — authenticated can EXECUTE public.report_content');

  -- GRP10-m: block_user
  PERFORM test_helpers.assert(
    has_function_privilege('authenticated',
      'public.block_user(uuid)'::regprocedure, 'EXECUTE'),
    'GRP10-m — authenticated can EXECUTE public.block_user');

  -- GRP10-n: apply_correction
  PERFORM test_helpers.assert(
    has_function_privilege('authenticated',
      'public.apply_correction(uuid,text,text,text,uuid,text)'::regprocedure, 'EXECUTE'),
    'GRP10-n — authenticated can EXECUTE public.apply_correction');

  -- ===== Private RLS helpers granted to authenticated =====

  -- GRP10-o: private.auth_uid() IS granted to authenticated (required by all RLS policies)
  PERFORM test_helpers.assert(
    has_function_privilege('authenticated',
      'private.auth_uid()'::regprocedure, 'EXECUTE'),
    'GRP10-o — authenticated CAN EXECUTE private.auth_uid (required by RLS policies)');

  -- GRP10-p: private.can_view_case() IS granted to authenticated
  PERFORM test_helpers.assert(
    has_function_privilege('authenticated',
      'private.can_view_case(uuid)'::regprocedure, 'EXECUTE'),
    'GRP10-p — authenticated CAN EXECUTE private.can_view_case');

  -- GRP10-q: private.is_case_poster() IS granted to authenticated
  PERFORM test_helpers.assert(
    has_function_privilege('authenticated',
      'private.is_case_poster(uuid)'::regprocedure, 'EXECUTE'),
    'GRP10-q — authenticated CAN EXECUTE private.is_case_poster');

  -- ===== Service-role-only functions NOT granted to authenticated =====

  -- GRP10-r: remove_content is service_role only
  PERFORM test_helpers.assert(
    NOT has_function_privilege('authenticated',
      'public.remove_content(text,uuid,uuid,uuid,text)'::regprocedure, 'EXECUTE'),
    'GRP10-r — authenticated CANNOT EXECUTE public.remove_content (service_role only)');

  -- GRP10-s: approve_photo is service_role only
  PERFORM test_helpers.assert(
    NOT has_function_privilege('authenticated',
      'public.approve_photo(uuid,uuid,text)'::regprocedure, 'EXECUTE'),
    'GRP10-s — authenticated CANNOT EXECUTE public.approve_photo (service_role only)');

  -- GRP10-t: reject_photo is service_role only
  PERFORM test_helpers.assert(
    NOT has_function_privilege('authenticated',
      'public.reject_photo(uuid,uuid,text)'::regprocedure, 'EXECUTE'),
    'GRP10-t — authenticated CANNOT EXECUTE public.reject_photo (service_role only)');

  -- GRP10-u: suspend_user is service_role only
  PERFORM test_helpers.assert(
    NOT has_function_privilege('authenticated',
      'public.suspend_user(uuid,uuid,text)'::regprocedure, 'EXECUTE'),
    'GRP10-u — authenticated CANNOT EXECUTE public.suspend_user (service_role only)');

  -- ===== Table grants: executor INSERT + authenticated SELECT on guess_attempts =====

  -- GRP10-v: forkensics_executor CAN INSERT on guess_attempts (submit_guess SECURITY DEFINER)
  PERFORM test_helpers.assert(
    has_table_privilege('forkensics_executor', 'public.guess_attempts', 'INSERT'),
    'GRP10-v — forkensics_executor CAN INSERT on public.guess_attempts (V4 grant; submit_guess SECURITY DEFINER path)');

  -- GRP10-w: authenticated CAN SELECT from guess_attempts (read-only; INSERT withheld)
  PERFORM test_helpers.assert(
    has_table_privilege('authenticated', 'public.guess_attempts', 'SELECT'),
    'GRP10-w — authenticated CAN SELECT from public.guess_attempts (read-only; INSERT withheld)');

  -- GRP10-x: authenticated CAN SELECT from current_score_events VIEW
  PERFORM test_helpers.assert(
    has_table_privilege('authenticated', 'public.current_score_events', 'SELECT'),
    'GRP10-x — authenticated CAN SELECT from public.current_score_events (V4 GRANT on security_invoker view)');

  -- GRP10-y: authenticated CAN SELECT from investigation_members
  PERFORM test_helpers.assert(
    has_table_privilege('authenticated', 'public.investigation_members', 'SELECT'),
    'GRP10-y — authenticated CAN SELECT from public.investigation_members (V4 grant; RLS controls row visibility)');

  -- ===== Investigation helper functions granted to authenticated =====

  -- GRP10-z: private.normalize_answer — required for guess submission normalization
  PERFORM test_helpers.assert(
    has_function_privilege('authenticated',
      'private.normalize_answer(text)'::regprocedure, 'EXECUTE'),
    'GRP10-z — authenticated CAN EXECUTE private.normalize_answer (V4 grant; normalization in RLS + functions)');

  -- GRP10-aa: private.is_group_member
  PERFORM test_helpers.assert(
    has_function_privilege('authenticated',
      'private.is_group_member(uuid)'::regprocedure, 'EXECUTE'),
    'GRP10-aa — authenticated CAN EXECUTE private.is_group_member (V4 grant; required by RLS policies)');

  -- GRP10-ab: private.is_group_member_with
  PERFORM test_helpers.assert(
    has_function_privilege('authenticated',
      'private.is_group_member_with(uuid)'::regprocedure, 'EXECUTE'),
    'GRP10-ab — authenticated CAN EXECUTE private.is_group_member_with (V4 grant; required by RLS policies)');

  -- GRP10-ac: private.is_case_member
  PERFORM test_helpers.assert(
    has_function_privilege('authenticated',
      'private.is_case_member(uuid)'::regprocedure, 'EXECUTE'),
    'GRP10-ac — authenticated CAN EXECUTE private.is_case_member (V4 grant; required by RLS policies)');

  -- GRP10-ad: private.is_investigation_member
  PERFORM test_helpers.assert(
    has_function_privilege('authenticated',
      'private.is_investigation_member(uuid)'::regprocedure, 'EXECUTE'),
    'GRP10-ad — authenticated CAN EXECUTE private.is_investigation_member (V4 grant; required by RLS policies)');

  -- GRP10-ae: private.is_case_revealed
  PERFORM test_helpers.assert(
    has_function_privilege('authenticated',
      'private.is_case_revealed(uuid)'::regprocedure, 'EXECUTE'),
    'GRP10-ae — authenticated CAN EXECUTE private.is_case_revealed (V4 grant; required by RLS policies)');

  -- GRP10-af: private.is_investigation_eligible
  PERFORM test_helpers.assert(
    has_function_privilege('authenticated',
      'private.is_investigation_eligible(uuid)'::regprocedure, 'EXECUTE'),
    'GRP10-af — authenticated CAN EXECUTE private.is_investigation_eligible (V4 grant; required by RLS policies)');

  -- GRP10-ag: private.is_case_poster_for_investigation
  PERFORM test_helpers.assert(
    has_function_privilege('authenticated',
      'private.is_case_poster_for_investigation(uuid)'::regprocedure, 'EXECUTE'),
    'GRP10-ag — authenticated CAN EXECUTE private.is_case_poster_for_investigation (V4 grant; required by RLS policies)');

  -- GRP10-ah: private.caller_has_guessed
  PERFORM test_helpers.assert(
    has_function_privilege('authenticated',
      'private.caller_has_guessed(uuid)'::regprocedure, 'EXECUTE'),
    'GRP10-ah — authenticated CAN EXECUTE private.caller_has_guessed (V4 grant; required by RLS policies)');

  -- GRP10-ai: private.has_block_with_poster
  PERFORM test_helpers.assert(
    has_function_privilege('authenticated',
      'private.has_block_with_poster(uuid)'::regprocedure, 'EXECUTE'),
    'GRP10-ai — authenticated CAN EXECUTE private.has_block_with_poster (V4 grant; required by RLS policies)');

  -- ===== Service-only: can_viewer_access_case NOT granted to authenticated =====

  -- GRP10-aj: private.can_viewer_access_case — service_role + forkensics_executor ONLY
  -- This function returns sensitive linkage data; authenticated must not call it directly.
  PERFORM test_helpers.assert(
    NOT has_function_privilege('authenticated',
      'private.can_viewer_access_case(uuid,uuid)'::regprocedure, 'EXECUTE'),
    'GRP10-aj — authenticated CANNOT EXECUTE private.can_viewer_access_case (service_role + executor only; V4 lines 3226-3228)');

  -- ===== §17 exact-query assertions from Step-26-Proposal-Rev15.md lines 517–571 =====

  -- GRP10-ak/al: service_role and forkensics_executor CAN EXECUTE private.can_view_case
  PERFORM test_helpers.assert(
    has_function_privilege('service_role',
      'private.can_view_case(uuid)'::regprocedure, 'EXECUTE'),
    'GRP10-ak — service_role CAN EXECUTE private.can_view_case (Rev 15 §17 exact query)');
  PERFORM test_helpers.assert(
    has_function_privilege('forkensics_executor',
      'private.can_view_case(uuid)'::regprocedure, 'EXECUTE'),
    'GRP10-al — forkensics_executor CAN EXECUTE private.can_view_case (Rev 15 §17 exact query)');

  -- GRP10-am/an: forkensics_executor and service_role CAN EXECUTE private.can_viewer_access_case
  PERFORM test_helpers.assert(
    has_function_privilege('forkensics_executor',
      'private.can_viewer_access_case(uuid,uuid)'::regprocedure, 'EXECUTE'),
    'GRP10-am — forkensics_executor CAN EXECUTE private.can_viewer_access_case (Rev 15 §17 exact query)');
  PERFORM test_helpers.assert(
    has_function_privilege('service_role',
      'private.can_viewer_access_case(uuid,uuid)'::regprocedure, 'EXECUTE'),
    'GRP10-an — service_role CAN EXECUTE private.can_viewer_access_case (Rev 15 §17 exact query)');

  -- GRP10-ao: authenticated CAN SELECT from public.investigations
  PERFORM test_helpers.assert(
    has_table_privilege('authenticated', 'public.investigations', 'SELECT'),
    'GRP10-ao — authenticated CAN SELECT from public.investigations (V4 grant; RLS controls row visibility)');

  -- GRP10-ap/aq: forkensics_rls_helper CAN SELECT from investigations and investigation_members
  PERFORM test_helpers.assert(
    has_table_privilege('forkensics_rls_helper', 'public.investigations', 'SELECT'),
    'GRP10-ap — forkensics_rls_helper CAN SELECT from public.investigations (Rev 15 §17; RLS helper read path)');
  PERFORM test_helpers.assert(
    has_table_privilege('forkensics_rls_helper', 'public.investigation_members', 'SELECT'),
    'GRP10-aq — forkensics_rls_helper CAN SELECT from public.investigation_members (Rev 15 §17; RLS helper read path)');

  -- GRP10-ar: authenticated CANNOT INSERT into public.guess_attempts
  PERFORM test_helpers.assert(
    NOT has_table_privilege('authenticated', 'public.guess_attempts', 'INSERT'),
    'GRP10-ar — authenticated CANNOT INSERT into public.guess_attempts (Rev 15 §17; INSERT withheld; executor-only path)');

  -- GRP10-as: service_role CAN EXECUTE public.remove_content (5-arg)
  PERFORM test_helpers.assert(
    has_function_privilege('service_role',
      'public.remove_content(text,uuid,uuid,uuid,text)'::regprocedure, 'EXECUTE'),
    'GRP10-as — service_role CAN EXECUTE public.remove_content(text,uuid,uuid,uuid,text) (Rev 15 §17)');

  -- GRP10-at/au: service_role CAN EXECUTE remove_media; authenticated CANNOT
  PERFORM test_helpers.assert(
    has_function_privilege('service_role',
      'public.remove_media(uuid,uuid,uuid,text)'::regprocedure, 'EXECUTE'),
    'GRP10-at — service_role CAN EXECUTE public.remove_media(uuid,uuid,uuid,text) (Rev 15 §17)');
  PERFORM test_helpers.assert(
    NOT has_function_privilege('authenticated',
      'public.remove_media(uuid,uuid,uuid,text)'::regprocedure, 'EXECUTE'),
    'GRP10-au — authenticated CANNOT EXECUTE public.remove_media(uuid,uuid,uuid,text) (service_role only)');

  -- GRP10-av/aw: service_role CAN EXECUTE lock_case; authenticated CANNOT
  PERFORM test_helpers.assert(
    has_function_privilege('service_role',
      'public.lock_case(uuid)'::regprocedure, 'EXECUTE'),
    'GRP10-av — service_role CAN EXECUTE public.lock_case(uuid) (Rev 15 §17; service-role only path)');
  PERFORM test_helpers.assert(
    NOT has_function_privilege('authenticated',
      'public.lock_case(uuid)'::regprocedure, 'EXECUTE'),
    'GRP10-aw — authenticated CANNOT EXECUTE public.lock_case(uuid) (service_role only)');

  -- GRP10-ax: authenticated CAN EXECUTE public.launch_case
  PERFORM test_helpers.assert(
    has_function_privilege('authenticated',
      'public.launch_case(uuid,uuid,uuid[],integer)'::regprocedure, 'EXECUTE'),
    'GRP10-ax — authenticated CAN EXECUTE public.launch_case(uuid,uuid,uuid[],integer) (Rev 15 §17; poster-initiated)');

  -- GRP10-ay: service_role CAN EXECUTE public.reveal_case_service_wrapper
  PERFORM test_helpers.assert(
    has_function_privilege('service_role',
      'public.reveal_case_service_wrapper(uuid)'::regprocedure, 'EXECUTE'),
    'GRP10-ay — service_role CAN EXECUTE public.reveal_case_service_wrapper(uuid) (Rev 15 §17; service-triggered reveal)');

  -- GRP10-az: service_role CAN EXECUTE public.reserve_upload_session (6-arg)
  PERFORM test_helpers.assert(
    has_function_privilege('service_role',
      'public.reserve_upload_session(uuid,uuid,text,text,bigint,timestamptz)'::regprocedure, 'EXECUTE'),
    'GRP10-az — service_role CAN EXECUTE public.reserve_upload_session(uuid,uuid,text,text,bigint,timestamptz) (Rev 15 §17)');

  -- GRP10-ba/bb/bc/bd: forkensics_executor helper grants (SECURITY DEFINER call-graph)
  PERFORM test_helpers.assert(
    has_function_privilege(
      'forkensics_executor',
      'private.is_group_member(uuid)'::regprocedure,
      'EXECUTE'
    ),
    'GRP10-ba — forkensics_executor can EXECUTE private.is_group_member');

  PERFORM test_helpers.assert(
    has_function_privilege(
      'forkensics_executor',
      'private.has_block_with_poster(uuid)'::regprocedure,
      'EXECUTE'
    ),
    'GRP10-bb — forkensics_executor can EXECUTE private.has_block_with_poster');

  PERFORM test_helpers.assert(
    has_function_privilege(
      'forkensics_executor',
      'private.is_case_poster(uuid)'::regprocedure,
      'EXECUTE'
    ),
    'GRP10-bc — forkensics_executor can EXECUTE private.is_case_poster');

  PERFORM test_helpers.assert(
    has_function_privilege(
      'forkensics_executor',
      'private.is_case_revealed(uuid)'::regprocedure,
      'EXECUTE'
    ),
    'GRP10-bd — forkensics_executor can EXECUTE private.is_case_revealed');

  -- GRP10-be/bf: authenticated CAN INSERT into renamed tables (rename-preserved, intended)
  PERFORM test_helpers.assert(
    has_table_privilege('authenticated', 'public.case_secrets', 'INSERT'),
    'GRP10-be — authenticated CAN INSERT case secrets; RLS restricts them to the poster');

  PERFORM test_helpers.assert(
    has_table_privilege('authenticated', 'public.case_answer_aliases', 'INSERT'),
    'GRP10-bf — authenticated CAN INSERT case aliases; RLS and triggers enforce access');
END;
$$;

-- =============================================================================
-- GROUP 11 — cancel_investigation: poster and group owner can cancel;
--            non-poster/non-owner cannot
--
--   GRP11-a  non-owner/non-poster cannot cancel investigation (FK_FORBIDDEN)
--   GRP11-b  poster can cancel an active investigation; status becomes cancelled
--   GRP11-c  group owner (non-poster) can cancel their group's active investigation
-- =============================================================================
\echo ''
\echo '--- GROUP 11: cancel_investigation authorization ---'

DO $$
DECLARE
  v_poster   uuid;
  v_poster_b uuid;  -- distinct poster for Case B (v_poster has Case A launched)
  v_owner    uuid;
  v_member   uuid;
  v_gid_a    uuid;
  v_gid_b    uuid;
  v_cid_a    uuid;
  v_cid_b    uuid;
  v_mid_a    uuid;
  v_mid_b    uuid;
  v_inv_a    uuid;
  v_inv_b    uuid;
  v_err      text;
BEGIN
  v_poster   := test_helpers.make_user('GRP11 Poster');
  v_poster_b := test_helpers.make_user('GRP11 PosterB');
  v_owner    := test_helpers.make_user('GRP11 Owner');
  v_member   := test_helpers.make_user('GRP11 Member');

  -- Case A: poster will cancel (Group A, owned by v_poster)
  v_gid_a := test_helpers.make_group(v_poster, 'GRP11 GroupA');
  PERFORM test_helpers.add_member(v_gid_a, v_poster, v_member);

  SELECT case_id, media_id INTO v_cid_a, v_mid_a FROM test_helpers.make_case(v_poster);
  SET LOCAL ROLE forkensics_executor;
  UPDATE public.cases SET state='launched',
    posted_at=clock_timestamp()-interval '1 hour', deadline_at=clock_timestamp()+interval '2 hours'
  WHERE id = v_cid_a;
  RESET ROLE;
  v_inv_a := test_helpers.make_investigation(v_cid_a, v_gid_a);
  PERFORM test_helpers.make_investigation_member(v_inv_a, v_member);

  -- Case B: group owner will cancel (Group B, owned by v_owner)
  -- Uses v_poster_b so that v_poster's launched Case A does not violate
  -- the one_active_case_per_poster unique index.
  -- GRP11-c tests that v_owner (group owner, NOT the case poster) can cancel.
  v_gid_b := test_helpers.make_group(v_owner, 'GRP11 GroupB');
  PERFORM test_helpers.add_member(v_gid_b, v_owner, v_member);

  SELECT case_id, media_id INTO v_cid_b, v_mid_b FROM test_helpers.make_case(v_poster_b);
  SET LOCAL ROLE forkensics_executor;
  UPDATE public.cases SET state='launched',
    posted_at=clock_timestamp()-interval '1 hour', deadline_at=clock_timestamp()+interval '2 hours'
  WHERE id = v_cid_b;
  RESET ROLE;
  v_inv_b := test_helpers.make_investigation(v_cid_b, v_gid_b);
  PERFORM test_helpers.make_investigation_member(v_inv_b, v_member);

  -- ---- GRP11-a: member (not poster, not group owner) cannot cancel ----
  BEGIN
    PERFORM test_helpers.set_auth_uid(v_member);
    PERFORM public.cancel_investigation(v_inv_a, 'GRP11 member cancel attempt');
    RAISE EXCEPTION 'UNEXPECTED_SUCCESS: cancel_investigation should raise FK_FORBIDDEN for member';
  EXCEPTION WHEN OTHERS THEN
    v_err := SQLERRM;
    PERFORM test_helpers.clear_auth_uid();
    IF v_err LIKE '%UNEXPECTED_SUCCESS%' THEN RAISE; END IF;
    IF v_err NOT LIKE '%FK_FORBIDDEN%' THEN
      RAISE EXCEPTION 'WRONG_EXCEPTION: expected FK_FORBIDDEN, got: %', v_err;
    END IF;
  END;
  PERFORM test_helpers.assert(true, 'GRP11-a — member cannot cancel investigation (FK_FORBIDDEN)');

  -- ---- GRP11-b: poster can cancel investigation for Case A ----
  PERFORM test_helpers.set_auth_uid(v_poster);
  PERFORM public.cancel_investigation(v_inv_a, 'GRP11 poster cancel');
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(
    (SELECT status FROM public.investigations WHERE investigation_id = v_inv_a) = 'cancelled',
    'GRP11-b — poster can cancel active investigation; status becomes cancelled');

  -- ---- GRP11-c: group owner can cancel investigation for Case B ----
  PERFORM test_helpers.set_auth_uid(v_owner);
  PERFORM public.cancel_investigation(v_inv_b, 'GRP11 owner cancel');
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(
    (SELECT status FROM public.investigations WHERE investigation_id = v_inv_b) = 'cancelled',
    'GRP11-c — group owner can cancel their group''s active investigation');
END;
$$;

-- GRP11-d,e: additional cancel_investigation state guards
-- Each case uses a DISTINCT poster to avoid violating one_active_case_per_poster
-- (the unique index covers draft/ready/launched/locked simultaneously).
DO $$
DECLARE
  v_poster_d uuid;  -- poster for Case D (launched)
  v_poster_e uuid;  -- poster for Case E (draft) — separate to avoid index conflict
  v_det      uuid;
  v_gid      uuid;
  v_cid      uuid;
  v_mid      uuid;
  v_inv_d    uuid;
  v_inv_e    uuid;
  v_err      text;
BEGIN
  v_poster_d := test_helpers.make_user('GRP11d PosterD');
  v_poster_e := test_helpers.make_user('GRP11d PosterE');
  v_det      := test_helpers.make_user('GRP11d Detective');
  v_gid      := test_helpers.make_group(v_poster_d, 'GRP11d Group');
  PERFORM test_helpers.add_member(v_gid, v_poster_d, v_det);

  -- Case D: launched, investigation pre-cancelled
  SELECT case_id, media_id INTO v_cid, v_mid FROM test_helpers.make_case(v_poster_d);
  SET LOCAL ROLE forkensics_executor;
  UPDATE public.cases SET state='launched',
    posted_at=clock_timestamp()-interval '1 hour', deadline_at=clock_timestamp()+interval '2 hours'
  WHERE id = v_cid;
  RESET ROLE;
  v_inv_d := test_helpers.make_investigation(v_cid, v_gid);
  PERFORM test_helpers.make_investigation_member(v_inv_d, v_det);
  -- Pre-cancel the investigation as executor so it's already 'cancelled'
  SET LOCAL ROLE forkensics_executor;
  UPDATE public.investigations SET status='cancelled' WHERE investigation_id = v_inv_d;
  RESET ROLE;

  -- ---- GRP11-d: cancel an already-cancelled investigation → FK_INVALID_INPUT ----
  BEGIN
    PERFORM test_helpers.set_auth_uid(v_poster_d);
    PERFORM public.cancel_investigation(v_inv_d, 'GRP11d re-cancel attempt');
    RAISE EXCEPTION 'UNEXPECTED_SUCCESS: cancelling an already-cancelled investigation should fail';
  EXCEPTION WHEN OTHERS THEN
    v_err := SQLERRM;
    PERFORM test_helpers.clear_auth_uid();
    IF v_err LIKE '%UNEXPECTED_SUCCESS%' THEN RAISE; END IF;
    IF v_err NOT LIKE '%FK_INVALID_INPUT%' THEN
      RAISE EXCEPTION 'WRONG_EXCEPTION: expected FK_INVALID_INPUT, got: %', v_err;
    END IF;
  END;
  PERFORM test_helpers.assert(true,
    'GRP11-d — cancel already-cancelled investigation raises FK_INVALID_INPUT');

  -- Case E: case is in 'draft' state — investigation cannot be cancelled.
  -- v_poster_d has a launched case (Case D), so we use v_poster_e here to
  -- avoid violating one_active_case_per_poster (draft is also an indexed state).
  SELECT case_id, media_id INTO v_cid, v_mid FROM test_helpers.make_case(v_poster_e);
  -- Leave case in 'draft' state (default after make_case)
  v_inv_e := test_helpers.make_investigation(v_cid, v_gid);
  PERFORM test_helpers.make_investigation_member(v_inv_e, v_det);

  -- ---- GRP11-e: case not in 'launched' state → FK_INVALID_INPUT ----
  BEGIN
    PERFORM test_helpers.set_auth_uid(v_poster_e);
    PERFORM public.cancel_investigation(v_inv_e, 'GRP11e draft-case cancel attempt');
    RAISE EXCEPTION 'UNEXPECTED_SUCCESS: cancel on non-launched case investigation should fail';
  EXCEPTION WHEN OTHERS THEN
    v_err := SQLERRM;
    PERFORM test_helpers.clear_auth_uid();
    IF v_err LIKE '%UNEXPECTED_SUCCESS%' THEN RAISE; END IF;
    IF v_err NOT LIKE '%FK_INVALID_INPUT%' THEN
      RAISE EXCEPTION 'WRONG_EXCEPTION: expected FK_INVALID_INPUT, got: %', v_err;
    END IF;
  END;
  PERFORM test_helpers.assert(true,
    'GRP11-e — cancel investigation on non-launched case raises FK_INVALID_INPUT');
END;
$$;

-- GRP11-f,g: deadline and suspension guards on cancel_investigation
DO $$
DECLARE
  v_poster_f uuid;  -- poster for Case F (past-deadline)
  v_poster_g uuid;  -- poster for Case G (suspended)
  v_det      uuid;
  v_gid_f    uuid;
  v_gid_g    uuid;
  v_cid      uuid;
  v_mid      uuid;
  v_inv_f    uuid;
  v_inv_g    uuid;
  v_err      text;
BEGIN
  v_poster_f := test_helpers.make_user('GRP11f PosterF');
  v_poster_g := test_helpers.make_user('GRP11g PosterG');
  v_det      := test_helpers.make_user('GRP11fg Detective');

  -- Case F: launched case whose deadline is already past
  v_gid_f := test_helpers.make_group(v_poster_f, 'GRP11f Group');
  PERFORM test_helpers.add_member(v_gid_f, v_poster_f, v_det);
  SELECT case_id, media_id INTO v_cid, v_mid FROM test_helpers.make_case(v_poster_f);
  SET LOCAL ROLE forkensics_executor;
  UPDATE public.cases SET state = 'launched',
    posted_at   = clock_timestamp() - interval '3 hours',
    deadline_at = clock_timestamp() - interval '1 minute'  -- deadline already past
  WHERE id = v_cid;
  RESET ROLE;
  v_inv_f := test_helpers.make_investigation(v_cid, v_gid_f);
  PERFORM test_helpers.make_investigation_member(v_inv_f, v_det);

  -- ---- GRP11-f: cancel_investigation after deadline → FK_INVALID_INPUT ----
  BEGIN
    PERFORM test_helpers.set_auth_uid(v_poster_f);
    PERFORM public.cancel_investigation(v_inv_f, 'GRP11f past-deadline cancel attempt');
    RAISE EXCEPTION 'UNEXPECTED_SUCCESS: cancel after deadline should raise FK_INVALID_INPUT';
  EXCEPTION WHEN OTHERS THEN
    v_err := SQLERRM;
    PERFORM test_helpers.clear_auth_uid();
    IF v_err LIKE '%UNEXPECTED_SUCCESS%' THEN RAISE; END IF;
    IF v_err NOT LIKE '%FK_INVALID_INPUT%' THEN
      RAISE EXCEPTION 'WRONG_EXCEPTION GRP11-f: expected FK_INVALID_INPUT, got: %', v_err;
    END IF;
  END;
  PERFORM test_helpers.assert(true,
    'GRP11-f — cancel_investigation after deadline raises FK_INVALID_INPUT');

  -- Case G: launched case with active deadline; poster is suspended
  v_gid_g := test_helpers.make_group(v_poster_g, 'GRP11g Group');
  PERFORM test_helpers.add_member(v_gid_g, v_poster_g, v_det);
  SELECT case_id, media_id INTO v_cid, v_mid FROM test_helpers.make_case(v_poster_g);
  SET LOCAL ROLE forkensics_executor;
  UPDATE public.cases SET state = 'launched',
    posted_at   = clock_timestamp() - interval '1 hour',
    deadline_at = clock_timestamp() + interval '2 hours'
  WHERE id = v_cid;
  UPDATE public.profiles SET is_suspended = true WHERE id = v_poster_g;
  RESET ROLE;
  v_inv_g := test_helpers.make_investigation(v_cid, v_gid_g);
  PERFORM test_helpers.make_investigation_member(v_inv_g, v_det);

  -- ---- GRP11-g: suspended poster → FK_FORBIDDEN ----
  BEGIN
    PERFORM test_helpers.set_auth_uid(v_poster_g);
    PERFORM public.cancel_investigation(v_inv_g, 'GRP11g suspended poster cancel attempt');
    RAISE EXCEPTION 'UNEXPECTED_SUCCESS: suspended poster should be blocked from cancel_investigation';
  EXCEPTION WHEN OTHERS THEN
    v_err := SQLERRM;
    PERFORM test_helpers.clear_auth_uid();
    IF v_err LIKE '%UNEXPECTED_SUCCESS%' THEN RAISE; END IF;
    IF v_err NOT LIKE '%FK_FORBIDDEN%' THEN
      RAISE EXCEPTION 'WRONG_EXCEPTION GRP11-g: expected FK_FORBIDDEN, got: %', v_err;
    END IF;
  END;
  PERFORM test_helpers.assert(true,
    'GRP11-g — suspended poster cannot cancel_investigation (FK_FORBIDDEN)');
END;
$$;

-- =============================================================================
-- GROUP 12 — launch_case: zero-detective rejection
--
-- launch_case requires at least one eligible detective (non-poster group member
-- who is active, onboarded, and not suspended). If the poster is the only member,
-- launch must fail with FK_INVALID_INPUT.
--
--   GRP12-a  launch with zero eligible detectives raises FK_INVALID_INPUT
-- =============================================================================
\echo ''
\echo '--- GROUP 12: launch_case zero-detective rejection ---'

DO $$
DECLARE
  v_poster  uuid;
  v_gid     uuid;
  v_cid     uuid;
  v_mid     uuid;
  v_err     text;
BEGIN
  v_poster := test_helpers.make_user('GRP12 Poster');
  -- Solo group: poster is the only member (no detective)
  v_gid    := test_helpers.make_group(v_poster, 'GRP12 Solo Group');
  -- Do NOT call add_member; poster is the sole member

  SELECT case_id, media_id INTO v_cid, v_mid FROM test_helpers.make_case(v_poster);
  SET LOCAL ROLE forkensics_executor;
  UPDATE public.cases SET state = 'ready' WHERE id = v_cid;
  RESET ROLE;

  BEGIN
    PERFORM test_helpers.set_auth_uid(v_poster);
    PERFORM public.launch_case(v_cid, v_poster, ARRAY[v_gid], 7200);
    RAISE EXCEPTION 'UNEXPECTED_SUCCESS: launch with zero detectives should fail FK_INVALID_INPUT';
  EXCEPTION WHEN OTHERS THEN
    v_err := SQLERRM;
    PERFORM test_helpers.clear_auth_uid();
    IF v_err LIKE '%UNEXPECTED_SUCCESS%' THEN RAISE; END IF;
    IF v_err NOT LIKE '%FK_INVALID_INPUT%' THEN
      RAISE EXCEPTION 'WRONG_EXCEPTION: expected FK_INVALID_INPUT, got: %', v_err;
    END IF;
  END;
  PERFORM test_helpers.assert(true,
    'GRP12-a — launch with zero eligible detectives raises FK_INVALID_INPUT');
END;
$$;

-- =============================================================================
-- GROUP 13 — launch_case: suspended poster cannot launch
--
-- launch_case checks profiles.is_suspended. A suspended poster must be rejected
-- with FK_FORBIDDEN before any case state change occurs.
--
--   GRP13-a  suspended poster cannot launch case (FK_FORBIDDEN)
--   GRP13-b  case state is unchanged after the rejected launch
-- =============================================================================
\echo ''
\echo '--- GROUP 13: launch_case suspension enforcement ---'

DO $$
DECLARE
  v_poster    uuid;
  v_detective uuid;
  v_gid       uuid;
  v_cid       uuid;
  v_mid       uuid;
  v_err       text;
BEGIN
  v_poster    := test_helpers.make_user('GRP13 Poster');
  v_detective := test_helpers.make_user('GRP13 Detective');
  v_gid       := test_helpers.make_group(v_poster, 'GRP13 Group');
  PERFORM test_helpers.add_member(v_gid, v_poster, v_detective);

  SELECT case_id, media_id INTO v_cid, v_mid FROM test_helpers.make_case(v_poster);
  SET LOCAL ROLE forkensics_executor;
  UPDATE public.cases SET state = 'ready' WHERE id = v_cid;
  -- Suspend the poster
  UPDATE public.profiles SET is_suspended = true WHERE id = v_poster;
  RESET ROLE;

  BEGIN
    PERFORM test_helpers.set_auth_uid(v_poster);
    PERFORM public.launch_case(v_cid, v_poster, ARRAY[v_gid], 7200);
    RAISE EXCEPTION 'UNEXPECTED_SUCCESS: suspended poster should not be able to launch';
  EXCEPTION WHEN OTHERS THEN
    v_err := SQLERRM;
    PERFORM test_helpers.clear_auth_uid();
    IF v_err LIKE '%UNEXPECTED_SUCCESS%' THEN RAISE; END IF;
    IF v_err NOT LIKE '%FK_FORBIDDEN%' THEN
      RAISE EXCEPTION 'WRONG_EXCEPTION: expected FK_FORBIDDEN, got: %', v_err;
    END IF;
  END;
  PERFORM test_helpers.assert(true,
    'GRP13-a — suspended poster cannot launch case (FK_FORBIDDEN)');

  PERFORM test_helpers.assert(
    (SELECT state FROM public.cases WHERE id = v_cid) = 'ready',
    'GRP13-b — case state unchanged (still ready) after rejected launch');
END;
$$;

-- =============================================================================
-- GROUP 14 — cancel_case: deadline enforcement
--
-- cancel_case on a launched case whose deadline has already passed must fail
-- with FK_INVALID_INPUT. The deadline guard prevents cancellation of expired cases.
--
--   GRP14-a  cancel launched case after deadline raises FK_INVALID_INPUT
--   GRP14-b  case state is unchanged (still launched) after the rejected cancel
-- =============================================================================
\echo ''
\echo '--- GROUP 14: cancel_case deadline enforcement ---'

DO $$
DECLARE
  v_poster    uuid;
  v_detective uuid;
  v_gid       uuid;
  v_cid       uuid;
  v_mid       uuid;
  v_err       text;
BEGIN
  v_poster    := test_helpers.make_user('GRP14 Poster');
  v_detective := test_helpers.make_user('GRP14 Detective');
  v_gid       := test_helpers.make_group(v_poster, 'GRP14 Group');

  SELECT case_id, media_id INTO v_cid, v_mid FROM test_helpers.make_case(v_poster);
  SET LOCAL ROLE forkensics_executor;
  UPDATE public.cases
  SET state       = 'launched',
      posted_at   = clock_timestamp() - interval '4 hours',
      deadline_at = clock_timestamp() - interval '1 hour'   -- deadline already past
  WHERE id = v_cid;
  RESET ROLE;

  BEGIN
    PERFORM test_helpers.set_auth_uid(v_poster);
    PERFORM public.cancel_case(v_cid, 'GRP14 cancel after deadline');
    RAISE EXCEPTION 'UNEXPECTED_SUCCESS: cancel after deadline should fail FK_INVALID_INPUT';
  EXCEPTION WHEN OTHERS THEN
    v_err := SQLERRM;
    PERFORM test_helpers.clear_auth_uid();
    IF v_err LIKE '%UNEXPECTED_SUCCESS%' THEN RAISE; END IF;
    IF v_err NOT LIKE '%FK_INVALID_INPUT%' THEN
      RAISE EXCEPTION 'WRONG_EXCEPTION: expected FK_INVALID_INPUT, got: %', v_err;
    END IF;
  END;
  PERFORM test_helpers.assert(true,
    'GRP14-a — cancel launched case after deadline raises FK_INVALID_INPUT');

  PERFORM test_helpers.assert(
    (SELECT state FROM public.cases WHERE id = v_cid) = 'launched',
    'GRP14-b — case state unchanged (still launched) after rejected cancel');
END;
$$;

-- =============================================================================
-- GROUP 15 — report_content error matrix
--
-- Confirms that report_content enforces: invalid target type, self-report,
-- and non-member access control.
--
--   GRP15-a  unknown target_type raises FK_INVALID_INPUT
--   GRP15-b  poster reporting their own case raises FK_SELF_REPORT
--   GRP15-c  user with no investigation membership cannot report case (FK_NOT_FOUND)
-- =============================================================================
\echo ''
\echo '--- GROUP 15: report_content error matrix ---'

DO $$
DECLARE
  v_poster     uuid;
  v_reporter   uuid;
  v_outsider   uuid;
  v_gid        uuid;
  v_cid        uuid;
  v_mid        uuid;
  v_inv_id     uuid;
  v_err        text;
  v_clue_id    uuid;
  v_comment_id uuid;
  v_report_id  uuid;
  v_mod        uuid;
BEGIN
  v_poster   := test_helpers.make_user('GRP15 Poster');
  v_reporter := test_helpers.make_user('GRP15 Reporter');
  v_outsider := test_helpers.make_user('GRP15 Outsider');
  v_gid      := test_helpers.make_group(v_poster, 'GRP15 Group');

  SELECT case_id, media_id INTO v_cid, v_mid FROM test_helpers.make_case(v_poster);
  SET LOCAL ROLE forkensics_executor;
  UPDATE public.cases SET state='launched',
    posted_at=clock_timestamp()-interval '1 hour', deadline_at=clock_timestamp()+interval '2 hours'
  WHERE id = v_cid;
  RESET ROLE;
  v_inv_id := test_helpers.make_investigation(v_cid, v_gid);
  PERFORM test_helpers.make_investigation_member(v_inv_id, v_reporter);

  -- ---- GRP15-a: invalid target_type ----
  BEGIN
    PERFORM test_helpers.set_auth_uid(v_reporter);
    PERFORM public.report_content('invalid_type', gen_random_uuid(), 'spam', NULL);
    RAISE EXCEPTION 'UNEXPECTED_SUCCESS: invalid target_type should fail';
  EXCEPTION WHEN OTHERS THEN
    v_err := SQLERRM;
    PERFORM test_helpers.clear_auth_uid();
    IF v_err LIKE '%UNEXPECTED_SUCCESS%' THEN RAISE; END IF;
    IF v_err NOT LIKE '%FK_INVALID_INPUT%' THEN
      RAISE EXCEPTION 'WRONG_EXCEPTION: expected FK_INVALID_INPUT, got: %', v_err;
    END IF;
  END;
  PERFORM test_helpers.assert(true, 'GRP15-a — unknown target_type raises FK_INVALID_INPUT');

  -- ---- GRP15-b: poster cannot self-report their own case ----
  BEGIN
    PERFORM test_helpers.set_auth_uid(v_poster);
    PERFORM public.report_content('case', v_cid, 'spam', NULL);
    RAISE EXCEPTION 'UNEXPECTED_SUCCESS: poster self-reporting own case should fail';
  EXCEPTION WHEN OTHERS THEN
    v_err := SQLERRM;
    PERFORM test_helpers.clear_auth_uid();
    IF v_err LIKE '%UNEXPECTED_SUCCESS%' THEN RAISE; END IF;
    IF v_err NOT LIKE '%FK_SELF_REPORT%' THEN
      RAISE EXCEPTION 'WRONG_EXCEPTION: expected FK_SELF_REPORT, got: %', v_err;
    END IF;
  END;
  PERFORM test_helpers.assert(true,
    'GRP15-b — poster reporting own case raises FK_SELF_REPORT');

  -- ---- GRP15-c: user with no investigation membership gets FK_NOT_FOUND ----
  -- can_view_case() returns false for outsider → report_content raises FK_NOT_FOUND exactly
  BEGIN
    PERFORM test_helpers.set_auth_uid(v_outsider);
    PERFORM public.report_content('case', v_cid, 'spam', NULL);
    RAISE EXCEPTION 'UNEXPECTED_SUCCESS: non-member report should fail';
  EXCEPTION WHEN OTHERS THEN
    v_err := SQLERRM;
    PERFORM test_helpers.clear_auth_uid();
    IF v_err LIKE '%UNEXPECTED_SUCCESS%' THEN RAISE; END IF;
    IF v_err NOT LIKE '%FK_NOT_FOUND%' THEN
      RAISE EXCEPTION 'WRONG_EXCEPTION: expected FK_NOT_FOUND exactly, got: %', v_err;
    END IF;
  END;
  PERFORM test_helpers.assert(true,
    'GRP15-c — non-member reporting a case raises FK_NOT_FOUND (can_view_case=false)');

  -- ---- GRP15-d: reporter reports a clue on a launched case (valid path) ----
  -- Insert a clue as poster (using executor to bypass auth_uid() trigger requirement)
  v_clue_id := gen_random_uuid();
  SET LOCAL ROLE forkensics_executor;
  INSERT INTO public.clues (id, case_id, poster_id, text)
  VALUES (v_clue_id, v_cid, v_poster, 'GRP15 test clue content');
  RESET ROLE;

  -- reporter (investigation member, not the clue's poster) reports the clue
  PERFORM test_helpers.set_auth_uid(v_reporter);
  PERFORM public.report_content('clue', v_clue_id, 'spam', 'GRP15 clue report detail');
  PERFORM test_helpers.clear_auth_uid();

  PERFORM test_helpers.assert(
    EXISTS (
      SELECT 1 FROM public.content_reports
      WHERE target_type = 'clue' AND target_id = v_clue_id AND status = 'pending'
    ),
    'GRP15-d — reporter can report a clue; content_report row created with status=pending');

  -- Capture the report ID for use in GRP15-f (moderation action after cancellation).
  SELECT id INTO v_report_id FROM public.content_reports
  WHERE target_type = 'clue' AND target_id = v_clue_id AND status = 'pending'
  ORDER BY created_at DESC LIMIT 1;

  -- ---- GRP15-e: moderator-removed comment cannot be reported (FK_NOT_FOUND) ----
  -- Create moderator once here; reused in GRP15-f.
  -- remove_content() is SECURITY DEFINER owned by forkensics_executor; its internal
  -- UPDATE runs as current_user='forkensics_executor', satisfying restrict_comment_updates.
  v_mod := test_helpers.make_user('GRP15 Moderator');
  SET LOCAL ROLE forkensics_executor;
  INSERT INTO private.moderators (profile_id) VALUES (v_mod);
  RESET ROLE;

  v_comment_id := gen_random_uuid();
  SET LOCAL ROLE forkensics_executor;
  INSERT INTO public.comments (id, case_id, investigation_id, author_id, text)
  VALUES (v_comment_id, v_cid, v_inv_id,
          v_reporter, 'GRP15 removed comment');
  RESET ROLE;

  -- Remove the comment via remove_content() as service_role (canonical moderation path).
  SET LOCAL ROLE service_role;
  PERFORM public.remove_content(
    'comment',
    v_comment_id,
    v_mod,
    NULL,
    'GRP15 moderator-removal fixture'
  );
  RESET ROLE;

  -- Verify comment is properly marked removed.
  PERFORM test_helpers.assert(
    EXISTS (
      SELECT 1 FROM public.comments
      WHERE id = v_comment_id
        AND text = '[removed by moderator]'
        AND moderator_removed_at IS NOT NULL
        AND moderator_removal_action_id IS NOT NULL
    ),
    'GRP15-e setup — comment marked removed by moderator (text, timestamp, action_id set)');

  BEGIN
    PERFORM test_helpers.set_auth_uid(v_reporter);
    PERFORM public.report_content('comment', v_comment_id, 'spam', NULL);
    RAISE EXCEPTION 'UNEXPECTED_SUCCESS: reporting a removed comment should fail FK_NOT_FOUND';
  EXCEPTION WHEN OTHERS THEN
    v_err := SQLERRM;
    PERFORM test_helpers.clear_auth_uid();
    IF v_err LIKE '%UNEXPECTED_SUCCESS%' THEN RAISE; END IF;
    IF v_err NOT LIKE '%FK_NOT_FOUND%' THEN
      RAISE EXCEPTION 'WRONG_EXCEPTION: expected FK_NOT_FOUND, got: %', v_err;
    END IF;
  END;
  PERFORM test_helpers.assert(true,
    'GRP15-e — reporting a moderator-removed comment raises FK_NOT_FOUND');

  -- ---- GRP15-f: pending content_report remains actionable after case cancellation ----
  -- A moderator-actionable report (v_clue_id from GRP15-d, status='pending') must survive
  -- case cancellation in its original state; then a moderator must be able to action it via
  -- remove_content(). This proves the moderation queue stays intact and functions correctly
  -- even when the associated case is no longer active.
  SET LOCAL ROLE forkensics_executor;
  UPDATE public.cases SET state = 'cancelled', cancelled_at = clock_timestamp()
  WHERE id = v_cid;
  RESET ROLE;

  -- Step 1: report still pending immediately after cancellation.
  PERFORM test_helpers.assert(
    EXISTS (
      SELECT 1 FROM public.content_reports
      WHERE id = v_report_id AND status = 'pending'
    ),
    'GRP15-f — pending content_report survives case cancellation and remains status=pending');

  -- Step 2: moderator (v_mod, created in GRP15-e) calls remove_content on cancelled-case content.
  PERFORM public.remove_content('clue', v_clue_id, v_mod, v_report_id, 'GRP15 post-cancellation moderation test');

  -- Step 3: report is no longer pending (actioned by moderator).
  PERFORM test_helpers.assert(
    NOT EXISTS (
      SELECT 1 FROM public.content_reports
      WHERE id = v_report_id AND status = 'pending'
    ),
    'GRP15-f2 — content_report actioned by remove_content after case cancellation; no longer status=pending (moderator queue actionable)');
END;
$$;

-- =============================================================================
-- GROUP 15 (continued) — report_content('media_object', …) error matrix
--
-- The V4 rewrite of public.report_content handles 'media_object' in sequential steps:
--   (a) provisional case lookup  → FK_NOT_FOUND if no case links to media
--   (b) case lock + linkage re-verify  → FK_NOT_FOUND if changed (concurrency harness)
--   (c) can_view_case             → FK_NOT_FOUND if caller cannot view
--   (d) media lock + status check → FK_NOT_FOUND if status != 'ready'
--   (e) cancelled-state check     → FK_INVALID_INPUT if case is cancelled
--   (f) self-report check         → FK_SELF_REPORT if reporter == uploader
--
-- FK_LINKAGE_CHANGED (step b race) requires a concurrent transaction; covered by
-- V4_concurrency_harness.sh.
--
--   GRP15-g  report_content('media_object', detached_uuid, …) → FK_NOT_FOUND (step a)
--   GRP15-h  report_content('media_object', …) on cancelled case → FK_INVALID_INPUT (step e)
--   GRP15-i  report_content('media_object', …) with status≠ready → FK_NOT_FOUND (step d)
-- =============================================================================
\echo ''
\echo '--- GROUP 15 (continued): report_content(media_object) error matrix ---'

DO $$
DECLARE
  v_poster   uuid;
  v_reporter uuid;
  v_gid      uuid;
  v_cid_h    uuid;   -- case for GRP15-h (will be cancelled)
  v_mid_h    uuid;
  v_inv_h    uuid;
  v_cid_i    uuid;   -- case for GRP15-i (media set to processing)
  v_mid_i    uuid;
  v_inv_i    uuid;
  v_err      text;
  -- GRP15-j / GRP15-k / GRP15-l / GRP15-m / GRP15-n additional fixtures
  v_poster2   uuid;   -- separate poster for multi-target tests
  v_outsider2 uuid;   -- non-viewer for GRP15-j
  v_cid_j     uuid;   -- launched case (GRP15-j: media report by non-viewer); cancelled for k/l/m/n
  v_mid_j     uuid;   -- ready media linked to v_cid_j
  v_inv_j     uuid;   -- investigation in v_cid_j (reporter as member, used for k/l/m)
  v_comment_j uuid;   -- comment by v_poster2 in v_cid_j for GRP15-l
  v_clue_j    uuid;   -- clue by v_poster2, not removed, for GRP15-m
  v_clue_j_r  uuid;   -- clue by v_poster2, moderator-removed, for GRP15-n
BEGIN
  v_poster   := test_helpers.make_user('GRP15cont Poster');
  v_reporter := test_helpers.make_user('GRP15cont Reporter');
  v_gid      := test_helpers.make_group(v_poster, 'GRP15cont Group');
  PERFORM test_helpers.add_member(v_gid, v_poster, v_reporter);

  -- ---- GRP15-g: detached media → FK_NOT_FOUND (step a: no case links to random UUID) ----
  -- report_content does: SELECT id INTO v_provisional_case_id FROM public.cases
  --   WHERE media_object_id = p_target_id LIMIT 1;
  -- A random UUID has no case → v_provisional_case_id IS NULL → FK_NOT_FOUND immediately.
  BEGIN
    PERFORM test_helpers.set_auth_uid(v_reporter);
    PERFORM public.report_content('media_object', gen_random_uuid(), 'spam', NULL);
    PERFORM test_helpers.clear_auth_uid();
    RAISE EXCEPTION 'UNEXPECTED_SUCCESS: detached media should raise FK_NOT_FOUND';
  EXCEPTION WHEN OTHERS THEN
    v_err := SQLERRM;
    PERFORM test_helpers.clear_auth_uid();
    IF v_err LIKE '%UNEXPECTED_SUCCESS%' THEN RAISE; END IF;
    IF v_err NOT LIKE '%FK_NOT_FOUND%' THEN
      RAISE EXCEPTION 'WRONG_EXCEPTION GRP15-g: expected FK_NOT_FOUND, got SQLSTATE % : %',
        SQLSTATE, v_err;
    END IF;
  END;
  PERFORM test_helpers.assert(true,
    'GRP15-g — report_content(''media_object'', detached_uuid, ...) raises FK_NOT_FOUND (step a: no case links to media)');

  -- ---- GRP15-h: cancelled case + ready media → FK_INVALID_INPUT (step e) ----
  -- Set up a case with v_reporter as investigation member (so can_view_case = true),
  -- media status = 'ready' (make_case default), then cancel the case.
  -- Steps a-d pass; step e fires: FK_INVALID_INPUT: cannot report content in cancelled case.
  SELECT case_id, media_id INTO v_cid_h, v_mid_h FROM test_helpers.make_case(v_poster);
  v_inv_h := test_helpers.make_investigation(v_cid_h, v_gid);
  PERFORM test_helpers.make_investigation_member(v_inv_h, v_reporter);
  SET LOCAL ROLE forkensics_executor;
  UPDATE public.cases SET state = 'cancelled', cancelled_at = clock_timestamp()
  WHERE id = v_cid_h;
  RESET ROLE;

  BEGIN
    PERFORM test_helpers.set_auth_uid(v_reporter);
    PERFORM public.report_content('media_object', v_mid_h, 'spam', NULL);
    PERFORM test_helpers.clear_auth_uid();
    RAISE EXCEPTION 'UNEXPECTED_SUCCESS: cancelled-case media should raise FK_INVALID_INPUT';
  EXCEPTION WHEN OTHERS THEN
    v_err := SQLERRM;
    PERFORM test_helpers.clear_auth_uid();
    IF v_err LIKE '%UNEXPECTED_SUCCESS%' THEN RAISE; END IF;
    IF v_err NOT LIKE '%FK_INVALID_INPUT%' THEN
      RAISE EXCEPTION 'WRONG_EXCEPTION GRP15-h: expected FK_INVALID_INPUT, got SQLSTATE % : %',
        SQLSTATE, v_err;
    END IF;
  END;
  PERFORM test_helpers.assert(true,
    'GRP15-h — report_content(''media_object'', ...) on cancelled case raises FK_INVALID_INPUT (step e: cannot report cancelled case content)');

  -- ---- GRP15-i: linked case + non-ready media → FK_NOT_FOUND (step d) ----
  -- v_cid_h is cancelled (excluded from one_active_case_per_poster), so a new case can
  -- be created for the same poster. Set media to ''processing'' so step d fails.
  -- Steps a-c pass (case links to media; can_view_case = true via reporter''s membership);
  -- step d fires: FK_NOT_FOUND (media.status != ''ready'').
  SELECT case_id, media_id INTO v_cid_i, v_mid_i FROM test_helpers.make_case(v_poster);
  v_inv_i := test_helpers.make_investigation(v_cid_i, v_gid);
  PERFORM test_helpers.make_investigation_member(v_inv_i, v_reporter);
  SET LOCAL ROLE forkensics_executor;
  UPDATE public.media_objects SET status = 'processing' WHERE id = v_mid_i;
  RESET ROLE;

  BEGIN
    PERFORM test_helpers.set_auth_uid(v_reporter);
    PERFORM public.report_content('media_object', v_mid_i, 'spam', NULL);
    PERFORM test_helpers.clear_auth_uid();
    RAISE EXCEPTION 'UNEXPECTED_SUCCESS: processing-status media should raise FK_NOT_FOUND';
  EXCEPTION WHEN OTHERS THEN
    v_err := SQLERRM;
    PERFORM test_helpers.clear_auth_uid();
    IF v_err LIKE '%UNEXPECTED_SUCCESS%' THEN RAISE; END IF;
    IF v_err NOT LIKE '%FK_NOT_FOUND%' THEN
      RAISE EXCEPTION 'WRONG_EXCEPTION GRP15-i: expected FK_NOT_FOUND, got SQLSTATE % : %',
        SQLSTATE, v_err;
    END IF;
  END;
  PERFORM test_helpers.assert(true,
    'GRP15-i — report_content(''media_object'', ...) with status=processing raises FK_NOT_FOUND (step d: status != ready)');

  -- ---- GRP15-j/k/l/m/n setup ---------------------------------------------------
  -- v_poster2 creates v_cid_j with ready media (make_case default).
  -- v_reporter joins as investigation member so can_view_case(v_cid_j) = true.
  -- v_outsider2 is not poster and not a member → can_view_case = false (for GRP15-j).
  v_poster2   := test_helpers.make_user('GRP15cont Poster2');
  v_outsider2 := test_helpers.make_user('GRP15cont Outsider2');
  SELECT case_id, media_id INTO v_cid_j, v_mid_j FROM test_helpers.make_case(v_poster2);
  SET LOCAL ROLE forkensics_executor;
  UPDATE public.cases SET state       = 'launched',
                          posted_at   = clock_timestamp() - interval '30 minutes',
                          deadline_at = clock_timestamp() + interval '3 hours'
  WHERE id = v_cid_j;
  RESET ROLE;
  v_inv_j := test_helpers.make_investigation(v_cid_j, v_gid);
  PERFORM test_helpers.make_investigation_member(v_inv_j, v_reporter);

  -- Insert comment and clues as forkensics_executor (bypasses RLS).
  SET LOCAL ROLE forkensics_executor;
  INSERT INTO public.comments (case_id, investigation_id, author_id, text)
  VALUES (v_cid_j, v_inv_j, v_poster2, 'GRP15-l test comment')
  RETURNING id INTO v_comment_j;

  INSERT INTO public.clues (case_id, poster_id, text)
  VALUES (v_cid_j, v_poster2, 'GRP15-m test clue (not removed)')
  RETURNING id INTO v_clue_j;

  INSERT INTO public.clues (case_id, poster_id, text)
  VALUES (v_cid_j, v_poster2, 'GRP15-n test clue (will be moderator-removed)')
  RETURNING id INTO v_clue_j_r;
  RESET ROLE;

  -- Moderator-remove v_clue_j_r via replica role (skips trigger + FK; CHECK constraint
  -- passes because both moderator_removed_at and moderator_removal_action_id are non-NULL).
  SET LOCAL session_replication_role = replica;
  UPDATE public.clues
  SET moderator_removed_at       = clock_timestamp(),
      moderator_removal_action_id = gen_random_uuid()
  WHERE id = v_clue_j_r;
  SET LOCAL session_replication_role = origin;

  -- ---- GRP15-j: non-viewer reports linked media → FK_NOT_FOUND (step c: can_view_case) ----
  -- report_content steps a (case found via media_object_id) and b (linkage recheck) pass;
  -- step c fires: can_view_case = false for v_outsider2 (not poster, not inv member) → FK_NOT_FOUND.
  BEGIN
    PERFORM test_helpers.set_auth_uid(v_outsider2);
    PERFORM public.report_content('media_object', v_mid_j, 'spam', NULL);
    PERFORM test_helpers.clear_auth_uid();
    RAISE EXCEPTION 'UNEXPECTED_SUCCESS: non-viewer media report should raise FK_NOT_FOUND';
  EXCEPTION WHEN OTHERS THEN
    v_err := SQLERRM;
    PERFORM test_helpers.clear_auth_uid();
    IF v_err LIKE '%UNEXPECTED_SUCCESS%' THEN RAISE; END IF;
    IF v_err NOT LIKE '%FK_NOT_FOUND%' THEN
      RAISE EXCEPTION 'WRONG_EXCEPTION GRP15-j: expected FK_NOT_FOUND, got SQLSTATE % : %',
        SQLSTATE, v_err;
    END IF;
  END;
  PERFORM test_helpers.assert(true,
    'GRP15-j — report_content(''media_object'', ...) by non-viewer raises FK_NOT_FOUND (step c: can_view_case=false)');

  -- Cancel v_cid_j for tests k/l/m (v_mid_j media stays in place; clues and comment survive).
  SET LOCAL ROLE forkensics_executor;
  UPDATE public.cases SET state = 'cancelled', cancelled_at = clock_timestamp()
  WHERE id = v_cid_j;
  RESET ROLE;

  -- ---- GRP15-k: report_content('case') on cancelled case → FK_INVALID_INPUT ----
  -- v_reporter is investigation member (can_view_case = true); moderator_removed_at IS NULL;
  -- state = 'cancelled' fires FK_INVALID_INPUT before self-report check.
  BEGIN
    PERFORM test_helpers.set_auth_uid(v_reporter);
    PERFORM public.report_content('case', v_cid_j, 'spam', NULL);
    PERFORM test_helpers.clear_auth_uid();
    RAISE EXCEPTION 'UNEXPECTED_SUCCESS: cancelled-case ''case'' report should raise FK_INVALID_INPUT';
  EXCEPTION WHEN OTHERS THEN
    v_err := SQLERRM;
    PERFORM test_helpers.clear_auth_uid();
    IF v_err LIKE '%UNEXPECTED_SUCCESS%' THEN RAISE; END IF;
    IF v_err NOT LIKE '%FK_INVALID_INPUT%' THEN
      RAISE EXCEPTION 'WRONG_EXCEPTION GRP15-k: expected FK_INVALID_INPUT, got SQLSTATE % : %',
        SQLSTATE, v_err;
    END IF;
  END;
  PERFORM test_helpers.assert(true,
    'GRP15-k — report_content(''case'', cancelled_case_id, ...) raises FK_INVALID_INPUT (cancelled check)');

  -- ---- GRP15-l: report_content('comment') in cancelled case → FK_INVALID_INPUT ----
  -- Comment found (not removed); its case is cancelled → FK_INVALID_INPUT.
  -- Cancelled check fires before membership check in the comment branch.
  BEGIN
    PERFORM test_helpers.set_auth_uid(v_reporter);
    PERFORM public.report_content('comment', v_comment_j, 'spam', NULL);
    PERFORM test_helpers.clear_auth_uid();
    RAISE EXCEPTION 'UNEXPECTED_SUCCESS: comment in cancelled case should raise FK_INVALID_INPUT';
  EXCEPTION WHEN OTHERS THEN
    v_err := SQLERRM;
    PERFORM test_helpers.clear_auth_uid();
    IF v_err LIKE '%UNEXPECTED_SUCCESS%' THEN RAISE; END IF;
    IF v_err NOT LIKE '%FK_INVALID_INPUT%' THEN
      RAISE EXCEPTION 'WRONG_EXCEPTION GRP15-l: expected FK_INVALID_INPUT, got SQLSTATE % : %',
        SQLSTATE, v_err;
    END IF;
  END;
  PERFORM test_helpers.assert(true,
    'GRP15-l — report_content(''comment'', ...) in cancelled case raises FK_INVALID_INPUT');

  -- ---- GRP15-m: report_content('clue') in cancelled case → FK_INVALID_INPUT ----
  -- Clue found (not removed); can_view_case = true (v_reporter is investigation member);
  -- case state = 'cancelled' → FK_INVALID_INPUT (step d cancelled check).
  BEGIN
    PERFORM test_helpers.set_auth_uid(v_reporter);
    PERFORM public.report_content('clue', v_clue_j, 'spam', NULL);
    PERFORM test_helpers.clear_auth_uid();
    RAISE EXCEPTION 'UNEXPECTED_SUCCESS: clue in cancelled case should raise FK_INVALID_INPUT';
  EXCEPTION WHEN OTHERS THEN
    v_err := SQLERRM;
    PERFORM test_helpers.clear_auth_uid();
    IF v_err LIKE '%UNEXPECTED_SUCCESS%' THEN RAISE; END IF;
    IF v_err NOT LIKE '%FK_INVALID_INPUT%' THEN
      RAISE EXCEPTION 'WRONG_EXCEPTION GRP15-m: expected FK_INVALID_INPUT, got SQLSTATE % : %',
        SQLSTATE, v_err;
    END IF;
  END;
  PERFORM test_helpers.assert(true,
    'GRP15-m — report_content(''clue'', ...) in cancelled case raises FK_INVALID_INPUT (cancelled check)');

  -- ---- GRP15-n: report_content('clue') with moderator-removed clue → FK_NOT_FOUND ----
  -- v_clue_j_r has moderator_removed_at IS NOT NULL; the clue branch raises FK_NOT_FOUND
  -- immediately (FOUND=true but moderator_removed_at IS NOT NULL → FK_NOT_FOUND).
  -- This check fires before can_view_case and before the cancelled check.
  BEGIN
    PERFORM test_helpers.set_auth_uid(v_reporter);
    PERFORM public.report_content('clue', v_clue_j_r, 'spam', NULL);
    PERFORM test_helpers.clear_auth_uid();
    RAISE EXCEPTION 'UNEXPECTED_SUCCESS: moderator-removed clue should raise FK_NOT_FOUND';
  EXCEPTION WHEN OTHERS THEN
    v_err := SQLERRM;
    PERFORM test_helpers.clear_auth_uid();
    IF v_err LIKE '%UNEXPECTED_SUCCESS%' THEN RAISE; END IF;
    IF v_err NOT LIKE '%FK_NOT_FOUND%' THEN
      RAISE EXCEPTION 'WRONG_EXCEPTION GRP15-n: expected FK_NOT_FOUND, got SQLSTATE % : %',
        SQLSTATE, v_err;
    END IF;
  END;
  PERFORM test_helpers.assert(true,
    'GRP15-n — report_content(''clue'', moderator_removed_clue, ...) raises FK_NOT_FOUND (clue branch: moderator_removed_at IS NOT NULL)');
END;
$$;

-- =============================================================================
-- GROUP 16 — Investigation RLS: member sees own investigation; outsider cannot
--
-- public.investigations has RLS enabled. Authenticated users see only the
-- investigations they belong to (via investigation_members).
--
--   GRP16-a  investigation member sees their own investigation row
--   GRP16-b  outsider with no investigation membership sees 0 rows
--   GRP16-c  case poster can see investigations for their own case
--   GRP16-d  excluded member (eligibility_status=excluded) still sees their row
--   GRP16-e  member of inv1 cannot see inv2 for the same case (cross-roster)
--   GRP16-f  account-deleted member (eligibility_status=account_deleted) still sees their row
-- =============================================================================
\echo ''
\echo '--- GROUP 16: investigation RLS visibility ---'

DO $$
DECLARE
  v_poster   uuid;
  v_member   uuid;
  v_outsider uuid;
  v_gid      uuid;
  v_cid      uuid;
  v_mid      uuid;
  v_inv_id   uuid;
  v_cnt      bigint;
  v_excluded uuid;
  v_gid2     uuid;
  v_inv2     uuid;
BEGIN
  v_poster   := test_helpers.make_user('GRP16 Poster');
  v_member   := test_helpers.make_user('GRP16 Member');
  v_outsider := test_helpers.make_user('GRP16 Outsider');
  v_gid      := test_helpers.make_group(v_poster, 'GRP16 Group');

  SELECT case_id, media_id INTO v_cid, v_mid FROM test_helpers.make_case(v_poster);
  SET LOCAL ROLE forkensics_executor;
  UPDATE public.cases SET state='launched',
    posted_at=clock_timestamp()-interval '1 hour', deadline_at=clock_timestamp()+interval '2 hours'
  WHERE id = v_cid;
  RESET ROLE;
  v_inv_id := test_helpers.make_investigation(v_cid, v_gid);
  PERFORM test_helpers.make_investigation_member(v_inv_id, v_member);

  -- ---- GRP16-a: investigation member sees their investigation ----
  PERFORM test_helpers.set_auth_uid(v_member);
  SELECT COUNT(*) INTO v_cnt FROM public.investigations WHERE investigation_id = v_inv_id;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_cnt = 1,
    'GRP16-a — investigation member sees their own investigation row (RLS passes)');

  -- ---- GRP16-b: outsider sees 0 rows ----
  PERFORM test_helpers.set_auth_uid(v_outsider);
  SELECT COUNT(*) INTO v_cnt FROM public.investigations WHERE investigation_id = v_inv_id;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_cnt = 0,
    'GRP16-b — outsider with no membership sees 0 investigations (RLS blocks)');

  -- ---- GRP16-c: poster sees investigations for their own case ----
  PERFORM test_helpers.set_auth_uid(v_poster);
  SELECT COUNT(*) INTO v_cnt FROM public.investigations WHERE case_id = v_cid;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_cnt = 1,
    'GRP16-c — case poster can see investigations belonging to their case');

  -- ---- GRP16-d: excluded member still sees their investigation row ----
  -- eligibility_status='excluded' means they cannot guess, but they are still a member
  -- and should see the investigation row through RLS.
  v_excluded := test_helpers.make_user('GRP16 Excluded');
  INSERT INTO public.investigation_members
    (investigation_id, player_id, snapshot_display_name, snapshot_avatar_color, eligibility_status)
  VALUES (v_inv_id, v_excluded, 'GRP16 Excluded', 'red', 'excluded');

  PERFORM test_helpers.set_auth_uid(v_excluded);
  SELECT COUNT(*) INTO v_cnt FROM public.investigations WHERE investigation_id = v_inv_id;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_cnt = 1,
    'GRP16-d — excluded member (eligibility_status=excluded) still sees their investigation row');

  -- ---- GRP16-e: cross-roster isolation — member of inv1 cannot see inv2 ----
  -- Create a second investigation for the same case with a different group.
  -- v_member is in inv1; they should NOT be able to see inv2.
  v_gid2 := test_helpers.make_group(v_poster, 'GRP16 Group2');
  v_inv2  := test_helpers.make_investigation(v_cid, v_gid2);

  PERFORM test_helpers.set_auth_uid(v_member);
  SELECT COUNT(*) INTO v_cnt FROM public.investigations WHERE investigation_id = v_inv2;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_cnt = 0,
    'GRP16-e — member of inv1 cannot see inv2 for the same case (cross-roster isolation)');

  -- ---- GRP16-f: account-deleted member (is_active=false) sees 0 rows ----
  -- Rev 15 specifies: once profiles.is_active=false the member is excluded from the RLS
  -- SELECT policies on both investigations and investigation_members. The eligibility_status
  -- change alone is not enough; the profile deactivation is what the RLS gate checks.
  SET LOCAL ROLE forkensics_executor;
  UPDATE public.investigation_members
  SET eligibility_status = 'account_deleted'
  WHERE investigation_id = v_inv_id AND player_id = v_member;
  UPDATE public.profiles SET is_active = false, avatar_color = 'gray' WHERE id = v_member;
  RESET ROLE;

  PERFORM test_helpers.set_auth_uid(v_member);
  SELECT COUNT(*) INTO v_cnt FROM public.investigations WHERE investigation_id = v_inv_id;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_cnt = 0,
    'GRP16-f — account-deleted member (is_active=false) sees 0 investigations rows (RLS blocks inactive profiles)');

  PERFORM test_helpers.set_auth_uid(v_member);
  SELECT COUNT(*) INTO v_cnt
  FROM public.investigation_members
  WHERE investigation_id = v_inv_id AND player_id = v_member;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_cnt = 0,
    'GRP16-f2 — account-deleted member sees 0 investigation_members rows (RLS blocks inactive profiles)');
END;
$$;

-- =============================================================================
-- GROUP 17 — V2+V3+V4 function regression: exact signature, ownership,
--            privilege, and behavioral verification
--
-- Every living function is tested via to_regprocedure() (exact-signature
-- catalog lookup that returns NULL rather than raising if absent), pg_proc
-- ownership, has_function_privilege role checks, and at least one behavioral
-- call. Dropped V4 functions are confirmed absent via to_regproc() IS NULL.
--
-- Signature reference (types, not names):
--   reserve_upload_session(uuid,uuid,text,text,bigint,timestamptz)  — V2/V4 rewrite
--   activate_upload_session(uuid,timestamptz)                        — V2
--   finalize_upload_session(uuid,text)                               — V2/V4 rewrite
--   quiesce_upload_sessions_for_deletion(uuid)                       — V2
--   prepare_account_deletion_wrapper(uuid)                           — V2
--   mark_auth_deleted_wrapper(uuid)                                  — V2
--   report_content(text,uuid,text,text)                              — V3/V4 rewrite
--   approve_photo(uuid,uuid,text)                                    — V3
--   reject_photo(uuid,uuid,text)                                     — V3
--   remove_content(text,uuid,uuid,uuid,text)                         — V3/V4 rewrite
--   remove_media(uuid,uuid,uuid,text)                                — V3
--   get_media_serve_authorization(uuid,uuid)                         — V3
--   apply_correction(uuid,text,text,text,uuid,text)                  — V3/V4 rewrite
--   launch_case(uuid,uuid,uuid[],integer)                            — V4
--   cancel_case(uuid,text)                                           — V4
--   reveal_case(uuid)                                                — V4
--   reveal_case_service_wrapper(uuid)                                — V4
--   cancel_investigation(uuid,text)                                  — V4
--   submit_guess(uuid,uuid,text,text,text,timestamptz)               — V4
--   lock_case(uuid)                                                  — V4
-- =============================================================================
\echo ''
\echo '--- GROUP 17: V2+V3+V4 function regression (signature + owner + privilege + behavior) ---'

DO $$
DECLARE
  v_owner      name;
  v_cnt        bigint;
  v_poster_17  uuid;
  v_cid_17     uuid;
  v_mid_17     uuid;
  v_key_17     text;
  v_sess_id    uuid;
BEGIN
  -- ===== PART 1: to_regprocedure() exact-signature existence checks =====
  -- to_regprocedure() matches on full signature and returns NULL (not error) when absent.

  -- V2 upload-session functions (exact signatures; V4 preserves all of these)
  PERFORM test_helpers.assert(
    to_regprocedure('public.reserve_upload_session(uuid,uuid,text,text,bigint,timestamptz)') IS NOT NULL,
    'GRP17-01 — reserve_upload_session(uuid,uuid,text,text,bigint,timestamptz) present (V2; V4 renames p_case_id)');
  PERFORM test_helpers.assert(
    to_regprocedure('public.activate_upload_session(uuid,timestamptz)') IS NOT NULL,
    'GRP17-02 — activate_upload_session(uuid,timestamptz) present (V2)');
  PERFORM test_helpers.assert(
    to_regprocedure('public.finalize_upload_session(uuid,text)') IS NOT NULL,
    'GRP17-03 — finalize_upload_session(uuid,text) present (V2; V4 rewrites body)');
  PERFORM test_helpers.assert(
    to_regprocedure('public.quiesce_upload_sessions_for_deletion(uuid)') IS NOT NULL,
    'GRP17-04 — quiesce_upload_sessions_for_deletion(uuid) present (V2)');
  PERFORM test_helpers.assert(
    to_regprocedure('public.prepare_account_deletion_wrapper(uuid)') IS NOT NULL,
    'GRP17-05 — prepare_account_deletion_wrapper(uuid) present (V2)');
  PERFORM test_helpers.assert(
    to_regprocedure('public.mark_auth_deleted_wrapper(uuid)') IS NOT NULL,
    'GRP17-06 — mark_auth_deleted_wrapper(uuid) present (V2)');
  PERFORM test_helpers.assert(
    to_regprocedure('public.advance_upload_session_processing(uuid,uuid,interval)') IS NOT NULL,
    'GRP17-06a — advance_upload_session_processing(uuid,uuid,interval) present (V2)');
  PERFORM test_helpers.assert(
    to_regprocedure('public.advance_upload_session_sanitized(uuid)') IS NOT NULL,
    'GRP17-06b — advance_upload_session_sanitized(uuid) present (V2)');

  -- V3 moderation/group functions (exact signatures; V4 preserves or rewrites)
  PERFORM test_helpers.assert(
    to_regprocedure('public.report_content(text,uuid,text,text)') IS NOT NULL,
    'GRP17-07 — report_content(text,uuid,text,text) present (V3; V4 rewrites body)');
  PERFORM test_helpers.assert(
    to_regprocedure('public.approve_photo(uuid,uuid,text)') IS NOT NULL,
    'GRP17-08 — approve_photo(uuid,uuid,text) present (V3)');
  PERFORM test_helpers.assert(
    to_regprocedure('public.reject_photo(uuid,uuid,text)') IS NOT NULL,
    'GRP17-09 — reject_photo(uuid,uuid,text) present (V3)');
  PERFORM test_helpers.assert(
    to_regprocedure('public.remove_content(text,uuid,uuid,uuid,text)') IS NOT NULL,
    'GRP17-10 — remove_content(text,uuid,uuid,uuid,text) present (V3; V4 rewrites body)');
  PERFORM test_helpers.assert(
    to_regprocedure('public.remove_media(uuid,uuid,uuid,text)') IS NOT NULL,
    'GRP17-11 — remove_media(uuid,uuid,uuid,text) present (V3)');
  PERFORM test_helpers.assert(
    to_regprocedure('public.get_media_serve_authorization(uuid,uuid)') IS NOT NULL,
    'GRP17-12 — get_media_serve_authorization(uuid,uuid) present (V3)');
  PERFORM test_helpers.assert(
    to_regprocedure('public.apply_correction(uuid,text,text,text,uuid,text)') IS NOT NULL,
    'GRP17-13 — apply_correction(uuid,text,text,text,uuid,text) present (V3; V4 rewrites body)');

  -- V4 new/renamed functions (exact signatures)
  PERFORM test_helpers.assert(
    to_regprocedure('public.launch_case(uuid,uuid,uuid[],integer)') IS NOT NULL,
    'GRP17-14 — launch_case(uuid,uuid,uuid[],integer) present (V4; replaces activate_challenge)');
  PERFORM test_helpers.assert(
    to_regprocedure('public.cancel_case(uuid,text)') IS NOT NULL,
    'GRP17-15 — cancel_case(uuid,text) present (V4; replaces cancel_challenge)');
  PERFORM test_helpers.assert(
    to_regprocedure('public.reveal_case(uuid)') IS NOT NULL,
    'GRP17-16 — reveal_case(uuid) present (V4; replaces reveal_challenge)');
  PERFORM test_helpers.assert(
    to_regprocedure('public.reveal_case_service_wrapper(uuid)') IS NOT NULL,
    'GRP17-17 — reveal_case_service_wrapper(uuid) present (V4; replaces reveal_challenge_service_wrapper)');
  PERFORM test_helpers.assert(
    to_regprocedure('public.cancel_investigation(uuid,text)') IS NOT NULL,
    'GRP17-18 — cancel_investigation(uuid,text) present (V4 new)');
  PERFORM test_helpers.assert(
    to_regprocedure('public.submit_guess(uuid,uuid,text,text,text,timestamptz)') IS NOT NULL,
    'GRP17-19 — submit_guess(uuid,uuid,text,text,text,timestamptz) present (V4 new)');
  PERFORM test_helpers.assert(
    to_regprocedure('public.lock_case(uuid)') IS NOT NULL,
    'GRP17-20 — lock_case(uuid) present (V4; replaces lock_challenge)');

  -- ===== PART 2: ownership checks via pg_proc =====
  -- V4 explicitly ALTERs these functions to be owned by forkensics_executor.

  SELECT r.rolname INTO v_owner
  FROM pg_proc p JOIN pg_roles r ON r.oid = p.proowner
  WHERE p.oid = to_regprocedure('public.reserve_upload_session(uuid,uuid,text,text,bigint,timestamptz)');
  PERFORM test_helpers.assert(
    v_owner = 'forkensics_executor',
    'GRP17-21 — reserve_upload_session owned by forkensics_executor (V4 ALTER FUNCTION)');

  SELECT r.rolname INTO v_owner
  FROM pg_proc p JOIN pg_roles r ON r.oid = p.proowner
  WHERE p.oid = to_regprocedure('public.report_content(text,uuid,text,text)');
  PERFORM test_helpers.assert(
    v_owner = 'forkensics_executor',
    'GRP17-22 — report_content owned by forkensics_executor (V4 ALTER FUNCTION)');

  SELECT r.rolname INTO v_owner
  FROM pg_proc p JOIN pg_roles r ON r.oid = p.proowner
  WHERE p.oid = to_regprocedure('public.launch_case(uuid,uuid,uuid[],integer)');
  PERFORM test_helpers.assert(
    v_owner = 'forkensics_executor',
    'GRP17-23 — launch_case owned by forkensics_executor (V4 ALTER FUNCTION)');

  SELECT r.rolname INTO v_owner
  FROM pg_proc p JOIN pg_roles r ON r.oid = p.proowner
  WHERE p.oid = to_regprocedure('public.cancel_investigation(uuid,text)');
  PERFORM test_helpers.assert(
    v_owner = 'forkensics_executor',
    'GRP17-24 — cancel_investigation owned by forkensics_executor (V4 ALTER FUNCTION)');

  SELECT r.rolname INTO v_owner
  FROM pg_proc p JOIN pg_roles r ON r.oid = p.proowner
  WHERE p.oid = to_regprocedure('public.get_media_serve_authorization(uuid,uuid)');
  PERFORM test_helpers.assert(
    v_owner = 'forkensics_executor',
    'GRP17-25 — get_media_serve_authorization owned by forkensics_executor (V4 ALTER FUNCTION)');

  -- ===== PART 3: EXECUTE privilege checks =====
  -- Functions callable by authenticated
  PERFORM test_helpers.assert(
    has_function_privilege('authenticated',
      to_regprocedure('public.report_content(text,uuid,text,text)'), 'EXECUTE'),
    'GRP17-26 — authenticated CAN EXECUTE report_content (V3/V4 grant)');
  PERFORM test_helpers.assert(
    has_function_privilege('authenticated',
      to_regprocedure('public.cancel_investigation(uuid,text)'), 'EXECUTE'),
    'GRP17-27 — authenticated CAN EXECUTE cancel_investigation (V4 grant)');
  PERFORM test_helpers.assert(
    has_function_privilege('authenticated',
      to_regprocedure('public.launch_case(uuid,uuid,uuid[],integer)'), 'EXECUTE'),
    'GRP17-28 — authenticated CAN EXECUTE launch_case (V4 grant)');
  PERFORM test_helpers.assert(
    has_function_privilege('authenticated',
      to_regprocedure('public.apply_correction(uuid,text,text,text,uuid,text)'), 'EXECUTE'),
    'GRP17-29 — authenticated CAN EXECUTE apply_correction (V3/V4 grant)');

  -- Functions NOT callable by authenticated (service_role only)
  PERFORM test_helpers.assert(
    NOT has_function_privilege('authenticated',
      to_regprocedure('public.approve_photo(uuid,uuid,text)'), 'EXECUTE'),
    'GRP17-30 — authenticated CANNOT EXECUTE approve_photo (service_role only)');
  PERFORM test_helpers.assert(
    NOT has_function_privilege('authenticated',
      to_regprocedure('public.reject_photo(uuid,uuid,text)'), 'EXECUTE'),
    'GRP17-31 — authenticated CANNOT EXECUTE reject_photo (service_role only)');
  PERFORM test_helpers.assert(
    NOT has_function_privilege('authenticated',
      to_regprocedure('public.remove_content(text,uuid,uuid,uuid,text)'), 'EXECUTE'),
    'GRP17-32 — authenticated CANNOT EXECUTE remove_content (service_role only)');
  PERFORM test_helpers.assert(
    NOT has_function_privilege('authenticated',
      to_regprocedure('public.remove_media(uuid,uuid,uuid,text)'), 'EXECUTE'),
    'GRP17-33 — authenticated CANNOT EXECUTE remove_media (service_role only)');
  PERFORM test_helpers.assert(
    NOT has_function_privilege('authenticated',
      to_regprocedure('public.get_media_serve_authorization(uuid,uuid)'), 'EXECUTE'),
    'GRP17-34 — authenticated CANNOT EXECUTE get_media_serve_authorization (service_role only)');

  -- service_role can call the moderation/media functions
  PERFORM test_helpers.assert(
    has_function_privilege('service_role',
      to_regprocedure('public.reserve_upload_session(uuid,uuid,text,text,bigint,timestamptz)'), 'EXECUTE'),
    'GRP17-35 — service_role CAN EXECUTE reserve_upload_session (V4 grant restored)');
  PERFORM test_helpers.assert(
    has_function_privilege('service_role',
      to_regprocedure('public.approve_photo(uuid,uuid,text)'), 'EXECUTE'),
    'GRP17-36 — service_role CAN EXECUTE approve_photo (V3/V4 grant)');
  PERFORM test_helpers.assert(
    has_function_privilege('service_role',
      to_regprocedure('public.remove_content(text,uuid,uuid,uuid,text)'), 'EXECUTE'),
    'GRP17-37 — service_role CAN EXECUTE remove_content (V3/V4 grant)');
  PERFORM test_helpers.assert(
    has_function_privilege('service_role',
      to_regprocedure('public.get_media_serve_authorization(uuid,uuid)'), 'EXECUTE'),
    'GRP17-38 — service_role CAN EXECUTE get_media_serve_authorization (V3/V4 grant)');

  -- ===== PART 4: behavioral verification =====
  -- Build a valid fixture once; use it for both service-role behavioral calls.
  -- make_case creates a media_object (status='ready') and a media_storage_keys row via
  -- test_helpers.make_media_with_key with re_encoded_storage_key =
  -- 'cases/test/' || media_id::text || '/display.webp'.
  -- can_viewer_access_case(case_id, poster_id) returns true → poster is an authorised viewer.
  v_poster_17 := test_helpers.make_user('GRP17 ServeAuth Poster');
  SELECT case_id, media_id INTO v_cid_17, v_mid_17
  FROM test_helpers.make_case(v_poster_17);

  -- 4a: get_media_serve_authorization as service_role with a real fixture.
  -- Proves the approved service-role execution path returns the expected storage key.
  SET LOCAL ROLE service_role;
  SELECT re_encoded_storage_key INTO v_key_17
  FROM public.get_media_serve_authorization(v_mid_17, v_poster_17);
  RESET ROLE;

  PERFORM test_helpers.assert(
    v_key_17 = 'cases/test/' || v_mid_17::text || '/display.webp',
    'GRP17-39 — get_media_serve_authorization returns correct re_encoded_storage_key as service_role (behavioral; V3/V4)');

  -- 4b: reserve_upload_session as service_role with a valid draft case.
  -- p_uploader_id = poster (matches case.poster_id); state = ''draft'' (make_case default).
  -- SECURITY DEFINER runs as forkensics_executor; returns TABLE(session_id, …).
  SET LOCAL ROLE service_role;
  SELECT session_id INTO v_sess_id
  FROM public.reserve_upload_session(
    v_cid_17,
    v_poster_17,
    'deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef',
    'image/jpeg',
    1000000,
    clock_timestamp() + interval '1 hour'
  );
  RESET ROLE;

  PERFORM test_helpers.assert(
    v_sess_id IS NOT NULL,
    'GRP17-39b — reserve_upload_session returns a session_id as service_role for a valid draft case (behavioral; V2/V4)');

  -- ===== PART 5: dropped-function negative checks =====
  -- to_regproc() (name-only) is appropriate here — we want NULL when absent.
  PERFORM test_helpers.assert(
    to_regproc('public.reveal_challenge_service_wrapper') IS NULL,
    'GRP17-40 — reveal_challenge_service_wrapper DROPPED by V4 (absent)');
  PERFORM test_helpers.assert(
    to_regproc('public.activate_challenge') IS NULL,
    'GRP17-41 — activate_challenge DROPPED by V4 (absent)');
  PERFORM test_helpers.assert(
    to_regproc('public.lock_challenge') IS NULL,
    'GRP17-42 — lock_challenge DROPPED by V4 (absent)');
  PERFORM test_helpers.assert(
    to_regproc('public.cancel_challenge') IS NULL,
    'GRP17-43 — cancel_challenge DROPPED by V4 (absent)');
  PERFORM test_helpers.assert(
    to_regproc('public.reveal_challenge') IS NULL,
    'GRP17-44 — reveal_challenge DROPPED by V4 (absent)');
END;
$$;

-- =============================================================================
-- GROUP 18 — submit_guess: suspension, past-deadline, and idempotency
--
--   GRP18-a  suspended player cannot submit guess (FK_FORBIDDEN)
--   GRP18-b  player cannot submit after deadline (FK_INVALID_INPUT)
--   GRP18-c  idempotency — second call with same key does not insert duplicate row
-- =============================================================================
\echo ''
\echo '--- GROUP 18: submit_guess suspension / deadline / idempotency ---'

DO $$
DECLARE
  v_poster    uuid;
  v_detective uuid;
  v_susp_det  uuid;
  v_gid       uuid;
  v_cid       uuid;
  v_mid       uuid;
  v_inv_id    uuid;
  v_ikey      text := 'GRP18-idem-key-' || gen_random_uuid();
  v_cnt       bigint;
  v_err       text;
BEGIN
  v_poster    := test_helpers.make_user('GRP18 Poster');
  v_detective := test_helpers.make_user('GRP18 Detective');
  v_susp_det  := test_helpers.make_user('GRP18 Suspended Det');
  v_gid       := test_helpers.make_group(v_poster, 'GRP18 Group');
  PERFORM test_helpers.add_member(v_gid, v_poster, v_detective);
  PERFORM test_helpers.add_member(v_gid, v_poster, v_susp_det);

  SELECT case_id, media_id INTO v_cid, v_mid FROM test_helpers.make_case(v_poster);

  -- Launched case with active deadline
  SET LOCAL ROLE forkensics_executor;
  UPDATE public.cases SET state='launched',
    posted_at=clock_timestamp()-interval '1 hour', deadline_at=clock_timestamp()+interval '2 hours'
  WHERE id = v_cid;
  -- Suspend v_susp_det
  UPDATE public.profiles SET is_suspended = true WHERE id = v_susp_det;
  RESET ROLE;

  v_inv_id := test_helpers.make_investigation(v_cid, v_gid);
  PERFORM test_helpers.make_investigation_member(v_inv_id, v_detective);
  PERFORM test_helpers.make_investigation_member(v_inv_id, v_susp_det);

  -- ---- GRP18-a: suspended player cannot submit guess ----
  BEGIN
    PERFORM test_helpers.set_auth_uid(v_susp_det);
    PERFORM public.submit_guess(v_cid, v_inv_id, 'what', 'Paella',
      'GRP18-susp-key', clock_timestamp());
    RAISE EXCEPTION 'UNEXPECTED_SUCCESS: suspended player should be blocked from submitting';
  EXCEPTION WHEN OTHERS THEN
    v_err := SQLERRM;
    PERFORM test_helpers.clear_auth_uid();
    IF v_err LIKE '%UNEXPECTED_SUCCESS%' THEN RAISE; END IF;
    IF v_err NOT LIKE '%FK_FORBIDDEN%' THEN
      RAISE EXCEPTION 'WRONG_EXCEPTION: expected FK_FORBIDDEN, got: %', v_err;
    END IF;
  END;
  PERFORM test_helpers.assert(true, 'GRP18-a — suspended player blocked from submit_guess (FK_FORBIDDEN)');

  -- ---- GRP18-b: player cannot submit after deadline ----
  -- Advance the case deadline into the past
  SET LOCAL ROLE forkensics_executor;
  UPDATE public.cases SET deadline_at = clock_timestamp() - interval '1 minute'
  WHERE id = v_cid;
  RESET ROLE;

  BEGIN
    PERFORM test_helpers.set_auth_uid(v_detective);
    PERFORM public.submit_guess(v_cid, v_inv_id, 'what', 'Paella',
      'GRP18-dead-key', clock_timestamp());
    RAISE EXCEPTION 'UNEXPECTED_SUCCESS: submit after deadline should fail';
  EXCEPTION WHEN OTHERS THEN
    v_err := SQLERRM;
    PERFORM test_helpers.clear_auth_uid();
    IF v_err LIKE '%UNEXPECTED_SUCCESS%' THEN RAISE; END IF;
    IF v_err NOT LIKE '%FK_INVALID_INPUT%' THEN
      RAISE EXCEPTION 'WRONG_EXCEPTION: expected FK_INVALID_INPUT, got: %', v_err;
    END IF;
  END;
  PERFORM test_helpers.assert(true, 'GRP18-b — submit_guess after deadline raises FK_INVALID_INPUT');

  -- ---- GRP18-c: idempotency — restore deadline, submit twice with same key ----
  SET LOCAL ROLE forkensics_executor;
  UPDATE public.cases SET deadline_at = clock_timestamp() + interval '2 hours'
  WHERE id = v_cid;
  RESET ROLE;

  PERFORM test_helpers.set_auth_uid(v_detective);
  PERFORM public.submit_guess(v_cid, v_inv_id, 'what', 'Paella', v_ikey, clock_timestamp());
  PERFORM public.submit_guess(v_cid, v_inv_id, 'what', 'Paella', v_ikey, clock_timestamp());
  PERFORM test_helpers.clear_auth_uid();

  SELECT COUNT(*) INTO v_cnt
  FROM public.guess_attempts
  WHERE case_id = v_cid
    AND player_id = v_detective
    AND idempotency_key = v_ikey;

  PERFORM test_helpers.assert(v_cnt = 1,
    'GRP18-c — idempotency: duplicate submit_guess with same key does not create extra row');
END;
$$;

-- =============================================================================
-- GROUP 19 — Table Talk: behavioral end-to-end (comment + reaction lifecycle)
--            + V4 privilege behavioral assertions
--
-- Actually performs Table Talk operations as the authenticated role to confirm
-- that column-level grants, RLS, and triggers all work together correctly.
-- Uses the case poster (comments_poster_insert RLS path) so no guess/reveal
-- state is required.
--
--   GRP19-a  authenticated (poster) can INSERT a comment
--   GRP19-b  authenticated can soft-delete their comment (UPDATE deleted_at)
--   GRP19-c  authenticated CANNOT UPDATE comment.text (42501: column privilege)
--   GRP19-d  authenticated (poster) can INSERT a reaction (emoji)
--   GRP19-e  authenticated can DELETE their own reaction
--   GRP19-f  authenticated (poster) CAN SELECT from current_score_events and receives rows
--            (behavioral: reveal case, call apply_correction, count >= 1)
--   GRP19-g  authenticated CANNOT INSERT into public.investigation_members (42501)
--   GRP19-h  authenticated CANNOT INSERT into public.score_events (42501)
-- =============================================================================
\echo ''
\echo '--- GROUP 19: Table Talk behavioral (INSERT/soft-delete/blocked-UPDATE/reaction) ---'

DO $$
DECLARE
  v_poster      uuid;
  v_gid         uuid;
  v_cid         uuid;
  v_mid         uuid;
  v_inv_id      uuid;
  v_comment_id  uuid;
  v_reaction_id uuid;
  v_detective   uuid;
  v_cnt         bigint;
  v_err         text;
BEGIN
  v_poster := test_helpers.make_user('GRP19 Poster');
  v_gid    := test_helpers.make_group(v_poster, 'GRP19 Group');
  SELECT case_id, media_id INTO v_cid, v_mid FROM test_helpers.make_case(v_poster);

  SET LOCAL ROLE forkensics_executor;
  UPDATE public.cases SET state = 'launched',
    posted_at    = clock_timestamp() - interval '1 hour',
    deadline_at  = clock_timestamp() + interval '2 hours'
  WHERE id = v_cid;
  RESET ROLE;

  v_inv_id := test_helpers.make_investigation(v_cid, v_gid);

  -- ---- GRP19-a: authenticated (poster) can INSERT a comment ----
  -- Uses the comments_poster_insert RLS policy (poster of the case's investigation).
  v_comment_id := gen_random_uuid();
  PERFORM test_helpers.set_auth_uid(v_poster);
  SET LOCAL ROLE authenticated;
  INSERT INTO public.comments (id, case_id, investigation_id, author_id, text)
  VALUES (v_comment_id, v_cid, v_inv_id, v_poster, 'GRP19 test comment');
  RESET ROLE;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(
    EXISTS (SELECT 1 FROM public.comments WHERE id = v_comment_id),
    'GRP19-a — authenticated (poster) CAN INSERT a comment into public.comments');

  -- ---- GRP19-b: authenticated can soft-delete via soft_delete_comment() (SECURITY DEFINER) ----
  -- Direct UPDATE as authenticated fails: the updated row becomes invisible under the
  -- comments SELECT policy (it checks deleted_at IS NULL), so the UPDATE sees 0 rows.
  -- The correct path is public.soft_delete_comment(), a SECURITY DEFINER function owned by
  -- forkensics_executor (defined in V1), which bypasses the policy and sets deleted_at.
  -- It is granted EXECUTE to authenticated; it validates author via private.auth_uid().
  PERFORM test_helpers.set_auth_uid(v_poster);
  PERFORM public.soft_delete_comment(v_comment_id);
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(
    (SELECT deleted_at IS NOT NULL FROM public.comments WHERE id = v_comment_id),
    'GRP19-b — authenticated CAN soft-delete a comment via soft_delete_comment() (SECURITY DEFINER; trigger Path 2)');

  -- ---- GRP19-c: authenticated CANNOT UPDATE comment.text (42501) ----
  -- authenticated has UPDATE(deleted_at) only — not UPDATE(text). PostgreSQL enforces
  -- column-level grants before the trigger fires, so this raises SQLSTATE 42501.
  BEGIN
    PERFORM test_helpers.set_auth_uid(v_poster);
    SET LOCAL ROLE authenticated;
    UPDATE public.comments SET text = 'GRP19 mutated text' WHERE id = v_comment_id;
    RESET ROLE;
    PERFORM test_helpers.clear_auth_uid();
    RAISE EXCEPTION 'UNEXPECTED_SUCCESS: UPDATE comments.text as authenticated should fail 42501';
  EXCEPTION WHEN OTHERS THEN
    v_err := SQLERRM;
    RESET ROLE;
    PERFORM test_helpers.clear_auth_uid();
    IF v_err LIKE '%UNEXPECTED_SUCCESS%' THEN RAISE; END IF;
    IF SQLSTATE != '42501' THEN
      RAISE EXCEPTION 'WRONG_EXCEPTION GRP19-c: expected 42501 (column privilege), got SQLSTATE % : %',
        SQLSTATE, v_err;
    END IF;
  END;
  PERFORM test_helpers.assert(true,
    'GRP19-c — authenticated CANNOT UPDATE comments.text (42501: no column UPDATE privilege on text)');

  -- ---- GRP19-d: authenticated (poster) can INSERT a reaction ----
  -- Uses reactions_poster_insert RLS (poster of the case for this investigation).
  v_reaction_id := gen_random_uuid();
  PERFORM test_helpers.set_auth_uid(v_poster);
  SET LOCAL ROLE authenticated;
  INSERT INTO public.reactions (id, case_id, investigation_id, player_id, emoji)
  VALUES (v_reaction_id, v_cid, v_inv_id, v_poster, E'\U0001F44D');
  RESET ROLE;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(
    EXISTS (SELECT 1 FROM public.reactions WHERE id = v_reaction_id),
    'GRP19-d — authenticated CAN INSERT a reaction into public.reactions');

  -- ---- GRP19-e: authenticated can DELETE their own reaction ----
  -- Uses reactions_poster_delete RLS (player_id = auth_uid AND poster for investigation).
  PERFORM test_helpers.set_auth_uid(v_poster);
  SET LOCAL ROLE authenticated;
  DELETE FROM public.reactions WHERE id = v_reaction_id;
  RESET ROLE;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(
    NOT EXISTS (SELECT 1 FROM public.reactions WHERE id = v_reaction_id),
    'GRP19-e — authenticated CAN DELETE their own reaction from public.reactions');

  -- ---- GRP19-f: authenticated (poster) CAN SELECT from current_score_events and receives rows ----
  -- Behavioral: add a detective, reveal the case, call apply_correction to generate a score_event,
  -- then SELECT from current_score_events as authenticated poster and assert count >= 1.
  -- current_score_events is a security_invoker VIEW; score_events_poster_view RLS allows the
  -- poster to see score_events for their own cases.
  v_detective := test_helpers.make_user('GRP19f Detective');
  PERFORM test_helpers.add_member(v_gid, v_poster, v_detective);
  PERFORM test_helpers.make_investigation_member(v_inv_id, v_detective);

  -- Reveal case via executor (bypasses state-machine trigger; investigation stays 'active'
  -- so apply_correction's FOR LOOP over active investigations finds v_inv_id)
  SET LOCAL ROLE forkensics_executor;
  UPDATE public.cases
  SET state       = 'revealed',
      posted_at   = clock_timestamp() - interval '3 hours',
      deadline_at = clock_timestamp() - interval '2 hours'
  WHERE id = v_cid;
  RESET ROLE;

  -- Generate a score_run + score_event for v_detective (eligible member)
  PERFORM test_helpers.set_auth_uid(v_poster);
  PERFORM public.apply_correction(
    v_cid, 'answer_changed', 'dish', 'GRP19f Dish Answer', NULL,
    'GRP19-f score generation for current_score_events behavioral test');
  PERFORM test_helpers.clear_auth_uid();

  -- As authenticated poster, SELECT from current_score_events
  PERFORM test_helpers.set_auth_uid(v_poster);
  SET LOCAL ROLE authenticated;
  SELECT COUNT(*) INTO v_cnt FROM public.current_score_events WHERE investigation_id = v_inv_id;
  RESET ROLE;
  PERFORM test_helpers.clear_auth_uid();

  PERFORM test_helpers.assert(v_cnt >= 1,
    'GRP19-f — authenticated (poster) CAN SELECT from current_score_events and receives score rows (behavioral: count >= 1 after apply_correction)');

  -- ---- GRP19-g: authenticated CANNOT INSERT into investigation_members (42501) ----
  -- Behavioral: attempt INSERT as authenticated with auth_uid=v_poster; must raise 42501
  -- (no INSERT privilege; authenticated has SELECT only per V4 grant matrix).
  BEGIN
    PERFORM test_helpers.set_auth_uid(v_poster);
    SET LOCAL ROLE authenticated;
    INSERT INTO public.investigation_members (investigation_id, player_id, eligibility_status)
    VALUES (v_inv_id, gen_random_uuid(), 'eligible');
    RESET ROLE;
    PERFORM test_helpers.clear_auth_uid();
    RAISE EXCEPTION 'UNEXPECTED_SUCCESS: INSERT into investigation_members as authenticated should fail 42501';
  EXCEPTION WHEN OTHERS THEN
    v_err := SQLERRM;
    RESET ROLE;
    PERFORM test_helpers.clear_auth_uid();
    IF v_err LIKE '%UNEXPECTED_SUCCESS%' THEN RAISE; END IF;
    IF SQLSTATE != '42501' THEN
      RAISE EXCEPTION 'WRONG_EXCEPTION GRP19-g: expected 42501, got SQLSTATE % : %', SQLSTATE, v_err;
    END IF;
  END;
  PERFORM test_helpers.assert(true,
    'GRP19-g — authenticated CANNOT INSERT into public.investigation_members (42501: INSERT privilege withheld; no self-enroll path)');

  -- ---- GRP19-h: authenticated CANNOT INSERT into score_events (42501) ----
  -- Behavioral: attempt INSERT as authenticated; must raise 42501 (INSERT withheld;
  -- score rows written exclusively by apply_correction SECURITY DEFINER).
  BEGIN
    PERFORM test_helpers.set_auth_uid(v_poster);
    SET LOCAL ROLE authenticated;
    INSERT INTO public.score_events (score_run_id, case_id, investigation_id, player_id, rules_version_id, what_points, where_points)
    VALUES (gen_random_uuid(), v_cid, v_inv_id, v_poster, gen_random_uuid(), 0, 0);
    RESET ROLE;
    PERFORM test_helpers.clear_auth_uid();
    RAISE EXCEPTION 'UNEXPECTED_SUCCESS: INSERT into score_events as authenticated should fail 42501';
  EXCEPTION WHEN OTHERS THEN
    v_err := SQLERRM;
    RESET ROLE;
    PERFORM test_helpers.clear_auth_uid();
    IF v_err LIKE '%UNEXPECTED_SUCCESS%' THEN RAISE; END IF;
    IF SQLSTATE != '42501' THEN
      RAISE EXCEPTION 'WRONG_EXCEPTION GRP19-h: expected 42501, got SQLSTATE % : %', SQLSTATE, v_err;
    END IF;
  END;
  PERFORM test_helpers.assert(true,
    'GRP19-h — authenticated CANNOT INSERT into public.score_events (42501: INSERT withheld; written by apply_correction SECURITY DEFINER only)');
END;
$$;

-- =============================================================================
-- GROUP 20 — Account deletion pipeline: behavioral exercise
--
-- Calls the deletion pipeline functions against a transient test user to
-- verify the V4 rewrite of private.prepare_account_deletion works end-to-end.
-- All state is rolled back at the end of the test transaction.
--
--   GRP20-a  quiesce_upload_sessions_for_deletion callable; returns 0 rows
--            for user with no sessions (no-op)
--   GRP20-b  prepare_account_deletion_wrapper transitions user to
--            database_prepared and returns that status string
--   GRP20-c  prepare_account_deletion_wrapper is idempotent on re-call
--   GRP20-d  authenticated CANNOT EXECUTE prepare_account_deletion_wrapper
--   GRP20-e  authenticated CANNOT EXECUTE mark_auth_deleted_wrapper
--   GRP20-f  user with investigations in launched + draft states: wrapper returns database_prepared
--   GRP20-g  investigation_members.eligibility_status → account_deleted for all memberships
--   GRP20-h  profiles.is_active=false after deletion
--   GRP20-i  deleted account sees 0 investigations rows (RLS blocks inactive profile)
--   GRP20-j  mark_auth_deleted_wrapper executes without error (V2 behavioral)
-- =============================================================================
\echo ''
\echo '--- GROUP 20: account deletion pipeline behavioral exercise ---'

DO $grp20$
DECLARE
  v_user      uuid;
  v_status    text;
  v_cnt       bigint;
  v_poster_20  uuid;
  v_poster_20b uuid;
  v_gid_20     uuid;
  v_gid_20b    uuid;
  v_cid_20     uuid;
  v_cid_20b    uuid;
  v_mid_20     uuid;
  v_mid_20b    uuid;
  v_inv_20     uuid;
  v_inv_20b    uuid;
  v_del_user   uuid;
  v_eligible   text;
  v_is_active  boolean;
  -- GRP20-k: apply_correction zero-points test fixtures
  v_pk_poster  uuid;
  v_pk_player  uuid;
  v_pk_gid     uuid;
  v_pk_cid     uuid;
  v_pk_mid     uuid;
  v_pk_inv     uuid;
  -- GRP20-l: atomicity proof + extended fixture variables
  v_ghost_del    uuid;   -- subject of deletion
  v_err          text;   -- exception message caught from probe trigger
  v_ghost_gid    uuid;   -- owned group (exercises step 5: group archive)
  v_ghost_cid    uuid;   -- draft case by ghost (exercises step 2: cancel)
  v_ghost_media  uuid;   -- media for ghost's case (exercises step 7: tombstone)
  v_other_poster uuid;
  v_other_gid    uuid;
  v_other_cid    uuid;   -- launched case (exercises step 3: exclusion; step 4: inv_member)
  v_other_inv    uuid;
BEGIN
  v_user := test_helpers.make_user('GRP20 DeletionSubject');

  -- ---- GRP20-a: quiesce_upload_sessions_for_deletion returns 0 rows (no sessions) ----
  -- Owned by forkensics_executor; the executor is its own owner so can call it.
  SET LOCAL ROLE forkensics_executor;
  SELECT COUNT(*) INTO v_cnt FROM public.quiesce_upload_sessions_for_deletion(v_user);
  RESET ROLE;
  PERFORM test_helpers.assert(
    v_cnt = 0,
    'GRP20-a — quiesce_upload_sessions_for_deletion returns 0 rows for user with no sessions (no-op)');

  -- ---- GRP20-b: prepare_account_deletion_wrapper → database_prepared ----
  -- Called as postgres (superuser); triggers the V4 rewrite of
  -- private.prepare_account_deletion which uses public.cases (not public.challenges).
  v_status := public.prepare_account_deletion_wrapper(v_user);
  PERFORM test_helpers.assert(
    v_status = 'database_prepared',
    'GRP20-b — prepare_account_deletion_wrapper returns ''database_prepared'' for a new user (V4 rewrite exercised)');

  -- Verify the deletion_log row was created with the correct status
  PERFORM test_helpers.assert(
    EXISTS (
      SELECT 1 FROM private.deletion_log
      WHERE profile_id = v_user AND status = 'database_prepared'
    ),
    'GRP20-b2 — deletion_log row created with status=database_prepared after wrapper call');

  -- ---- GRP20-c: idempotency — second call returns same status ----
  v_status := public.prepare_account_deletion_wrapper(v_user);
  PERFORM test_helpers.assert(
    v_status = 'database_prepared',
    'GRP20-c — prepare_account_deletion_wrapper is idempotent (second call returns database_prepared)');

  -- ---- GRP20-d: authenticated CANNOT EXECUTE prepare_account_deletion_wrapper ----
  PERFORM test_helpers.assert(
    NOT has_function_privilege('authenticated',
      to_regprocedure('public.prepare_account_deletion_wrapper(uuid)'), 'EXECUTE'),
    'GRP20-d — authenticated CANNOT EXECUTE prepare_account_deletion_wrapper (service_role only)');

  -- ---- GRP20-e: authenticated CANNOT EXECUTE mark_auth_deleted_wrapper ----
  PERFORM test_helpers.assert(
    NOT has_function_privilege('authenticated',
      to_regprocedure('public.mark_auth_deleted_wrapper(uuid)'), 'EXECUTE'),
    'GRP20-e — authenticated CANNOT EXECUTE mark_auth_deleted_wrapper (service_role only)');

  -- ---- GRP20-f/g/h/i: deletion with investigations across two case states ----
  -- V4 private.prepare_account_deletion updates ALL investigation_members rows to
  -- eligibility_status='account_deleted' regardless of case state, and sets
  -- profiles.is_active=false so RLS blocks the deleted account's SELECT visibility.
  --
  -- Case 1 (launched): v_poster_20 owns it; v_del_user is a member.
  -- Case 2 (draft):    v_poster_20b owns it; v_del_user is also a member.
  -- Separate posters avoid one_active_case_per_poster index violation.
  v_poster_20  := test_helpers.make_user('GRP20 PosterA');
  v_poster_20b := test_helpers.make_user('GRP20 PosterB');
  v_del_user   := test_helpers.make_user('GRP20 DelUser');

  v_gid_20  := test_helpers.make_group(v_poster_20,  'GRP20 GroupA');
  v_gid_20b := test_helpers.make_group(v_poster_20b, 'GRP20 GroupB');

  -- Case 1: launched state
  SELECT case_id, media_id INTO v_cid_20, v_mid_20
  FROM test_helpers.make_case(v_poster_20);
  SET LOCAL ROLE forkensics_executor;
  UPDATE public.cases SET state = 'launched',
    posted_at   = clock_timestamp() - interval '1 hour',
    deadline_at = clock_timestamp() + interval '2 hours'
  WHERE id = v_cid_20;
  RESET ROLE;
  v_inv_20 := test_helpers.make_investigation(v_cid_20, v_gid_20);
  PERFORM test_helpers.make_investigation_member(v_inv_20, v_del_user);

  -- Case 2: draft state (make_case default — no UPDATE needed)
  SELECT case_id, media_id INTO v_cid_20b, v_mid_20b
  FROM test_helpers.make_case(v_poster_20b);
  v_inv_20b := test_helpers.make_investigation(v_cid_20b, v_gid_20b);
  PERFORM test_helpers.make_investigation_member(v_inv_20b, v_del_user);

  -- Run deletion pipeline
  v_status := public.prepare_account_deletion_wrapper(v_del_user);
  PERFORM test_helpers.assert(
    v_status = 'database_prepared',
    'GRP20-f — prepare_account_deletion_wrapper returns database_prepared for user with investigations in multiple case states');

  -- GRP20-g: both investigation_members rows are account_deleted (regardless of case state)
  SELECT eligibility_status INTO v_eligible
  FROM public.investigation_members
  WHERE investigation_id = v_inv_20 AND player_id = v_del_user;
  PERFORM test_helpers.assert(v_eligible = 'account_deleted',
    'GRP20-g — investigation_members.eligibility_status=account_deleted for launched-case membership (V4 V4 private.prepare_account_deletion)');

  SELECT eligibility_status INTO v_eligible
  FROM public.investigation_members
  WHERE investigation_id = v_inv_20b AND player_id = v_del_user;
  PERFORM test_helpers.assert(v_eligible = 'account_deleted',
    'GRP20-g2 — investigation_members.eligibility_status=account_deleted for draft-case membership (all states covered)');

  -- GRP20-h: profile.is_active=false after deletion
  SELECT is_active INTO v_is_active FROM public.profiles WHERE id = v_del_user;
  PERFORM test_helpers.assert(v_is_active = false,
    'GRP20-h — profiles.is_active=false after prepare_account_deletion_wrapper (account deactivated)');

  -- GRP20-i: deleted account''s RLS visibility is 0 rows on investigations
  PERFORM test_helpers.set_auth_uid(v_del_user);
  SELECT COUNT(*) INTO v_cnt FROM public.investigations WHERE investigation_id = v_inv_20;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_cnt = 0,
    'GRP20-i — deleted account (is_active=false) sees 0 investigations rows (RLS blocks inactive profiles)');

  -- ---- GRP20-j: mark_auth_deleted_wrapper behavioral call ----
  -- mark_auth_deleted_wrapper wraps private.mark_auth_deleted (V2). Call it for a separate
  -- user (v_user, who was deletion-prepared in GRP20-b) to verify the function runs without
  -- error. It progresses the deletion log past database_prepared.
  PERFORM public.mark_auth_deleted_wrapper(v_user);
  PERFORM test_helpers.assert(true,
    'GRP20-j — mark_auth_deleted_wrapper executes without error for a database_prepared user (V2 behavioral)');

  -- ---- GRP20-k: apply_correction() after account deletion → 0 score_events for deleted player ----
  -- apply_correction loops over investigation_members WHERE eligibility_status = 'eligible'
  -- (line 3621) and inserts score_events only for eligible members (line 3700).
  -- After account deletion, eligibility_status = 'account_deleted' → player is excluded from
  -- both the guess_judgment loop and the score_events INSERT → 0 rows for deleted player.
  v_pk_poster := test_helpers.make_user('GRP20k Poster');
  v_pk_player := test_helpers.make_user('GRP20k Player');
  v_pk_gid    := test_helpers.make_group(v_pk_poster, 'GRP20k Group');
  PERFORM test_helpers.add_member(v_pk_gid, v_pk_poster, v_pk_player);
  SELECT case_id, media_id INTO v_pk_cid, v_pk_mid FROM test_helpers.make_case(v_pk_poster);
  v_pk_inv := test_helpers.make_investigation(v_pk_cid, v_pk_gid);
  PERFORM test_helpers.make_investigation_member(v_pk_inv, v_pk_player);

  -- Insert a guess_attempt for the player-to-delete (executor bypasses RLS)
  SET LOCAL ROLE forkensics_executor;
  INSERT INTO public.guess_attempts
    (case_id, player_id, race, dish_guess, restaurant_guess, receipt_sequence)
  VALUES
    (v_pk_cid, v_pk_player, 'what', 'guessed dish', NULL, 1);
  RESET ROLE;

  -- Delete the player
  PERFORM public.prepare_account_deletion_wrapper(v_pk_player);

  -- Set case to 'revealed' (required by apply_correction) and keep investigation 'active'
  SET LOCAL ROLE forkensics_executor;
  UPDATE public.cases
  SET state = 'revealed',
      posted_at   = clock_timestamp() - interval '3 hours',
      deadline_at = clock_timestamp() - interval '2 hours'
  WHERE id = v_pk_cid;
  RESET ROLE;

  -- Call apply_correction as the poster (has authority; case is revealed)
  PERFORM test_helpers.set_auth_uid(v_pk_poster);
  PERFORM public.apply_correction(
    v_pk_cid, 'answer_changed', 'dish', 'Updated Dish Answer', NULL,
    'GRP20k zero-points test correction');
  PERFORM test_helpers.clear_auth_uid();

  -- Assert: deleted player has 0 score_events rows (excluded by eligibility_status filter)
  SELECT COUNT(*) INTO v_cnt
  FROM public.score_events
  WHERE player_id = v_pk_player AND investigation_id = v_pk_inv;
  PERFORM test_helpers.assert(v_cnt = 0,
    'GRP20-k — apply_correction excludes account_deleted members: 0 score_events for deleted player (eligibility_status filter)');

  -- ---- GRP20-l: atomicity proof via probe trigger intercepting the final step ----
  -- private.prepare_account_deletion executes 8 steps in sequence:
  --   step 1: INSERT deletion_log status='pending'
  --   step 2: UPDATE cases SET state='cancelled' WHERE poster_id=ghost AND state IN ('draft','ready')
  --   step 3: INSERT exclusion_events for investigation_members in launched/locked cases
  --   step 4: UPDATE investigation_members SET eligibility_status='account_deleted' WHERE player_id=ghost
  --   step 5: archive or transfer owned groups (no active successor → archived_at set)
  --   step 6: INSERT private.profile_archive + UPDATE profiles SET display_name='Former Player', is_active=false
  --   step 7: UPDATE media_objects SET status='deleted' WHERE uploader_id=ghost
  --   step 8: UPDATE deletion_log SET status='database_prepared'  ← PROBE FIRES HERE
  --
  -- Proof strategy: a BEFORE UPDATE trigger on private.deletion_log raises
  -- TEST_ATOMICITY_PROBE when status is about to become 'database_prepared'.
  -- This forces a failure at step 8. The PL/pgSQL EXCEPTION handler's implicit
  -- savepoint rolls back ALL writes since the inner BEGIN (steps 1-7), proving
  -- the function shares the caller's transaction with no autonomous commits.
  --
  -- Extended fixtures exercise steps 2-7 so ALL stage rollbacks are verified:
  --   v_ghost_cid  (draft, poster=ghost_del) → exercises step 2 cancel
  --   v_other_cid  (launched) + ghost as inv member → exercises step 3 exclusion events
  --   v_other_inv member row for ghost → exercises step 4 eligibility update
  --   v_ghost_gid  (owned group, no other active owner) → exercises step 5 archive
  --   profile_archive + is_active → exercises step 6
  --   v_ghost_media (uploader=ghost_del) → exercises step 7

  -- Install the probe trigger.
  -- B1 fix (Rev 13): use $ddl$...$ddl$ delimiter to avoid prematurely terminating
  -- the outer DO $$...$$; block when the parser encounters the first bare $$.
  EXECUTE $ddl$CREATE OR REPLACE FUNCTION private.grp20l_atomicity_probe()
    RETURNS trigger LANGUAGE plpgsql AS $tf$
  BEGIN
    IF NEW.status = 'database_prepared' THEN
      RAISE EXCEPTION 'TEST_ATOMICITY_PROBE: intercepted database_prepared at step 8 (forced failure)';
    END IF;
    RETURN NEW;
  END;
  $tf$$ddl$;
  EXECUTE 'CREATE TRIGGER grp20l_atomicity_probe_trg
    BEFORE UPDATE ON private.deletion_log
    FOR EACH ROW EXECUTE FUNCTION private.grp20l_atomicity_probe()';

  -- Create all fixtures BEFORE the inner BEGIN so they survive implicit-savepoint rollback.
  v_ghost_del    := test_helpers.make_user('GRP20l AtomicProof');
  v_ghost_gid    := test_helpers.make_group(v_ghost_del, 'GRP20l Ghost Group');

  -- Draft case owned by ghost (exercises step 2: cancel; step 7: media tombstone via uploader_id)
  SELECT case_id, media_id INTO v_ghost_cid, v_ghost_media
  FROM test_helpers.make_case(v_ghost_del);

  -- Launched case by a separate poster, with ghost as an investigation member
  -- (exercises step 3: exclusion_events; step 4: investigation_members eligibility)
  v_other_poster := test_helpers.make_user('GRP20l OtherPoster');
  v_other_gid    := test_helpers.make_group(v_other_poster, 'GRP20l Other Group');
  SELECT case_id INTO v_other_cid FROM test_helpers.make_case(v_other_poster);
  SET LOCAL ROLE forkensics_executor;
  UPDATE public.cases
  SET state       = 'launched',
      posted_at   = clock_timestamp() - interval '1 hour',
      deadline_at = clock_timestamp() + interval '2 hours'
  WHERE id = v_other_cid;
  RESET ROLE;
  v_other_inv := test_helpers.make_investigation(v_other_cid, v_other_gid);
  PERFORM test_helpers.make_investigation_member(v_other_inv, v_ghost_del);

  BEGIN
    -- Probe fires at step 8 (UPDATE deletion_log SET status='database_prepared').
    -- Steps 1-7 execute and write data; step 8 raises TEST_ATOMICITY_PROBE.
    -- The EXCEPTION clause's implicit savepoint rolls back all writes from steps 1-7.
    PERFORM public.prepare_account_deletion_wrapper(v_ghost_del);
    RAISE EXCEPTION 'UNEXPECTED_SUCCESS: probe trigger should have intercepted step 8';
  EXCEPTION WHEN OTHERS THEN
    v_err := SQLERRM;
    IF v_err LIKE '%UNEXPECTED_SUCCESS%' THEN RAISE; END IF;
    IF v_err NOT LIKE '%TEST_ATOMICITY_PROBE%' THEN
      RAISE EXCEPTION 'WRONG_EXCEPTION GRP20-l: expected TEST_ATOMICITY_PROBE, got SQLSTATE % : %',
        SQLSTATE, v_err;
    END IF;
    -- Probe exception caught — inner block rolled back to implicit savepoint.
  END;

  -- Post-failure: assert ALL function writes are absent (atomicity proven across all 7 stages)
  PERFORM test_helpers.assert(
    NOT EXISTS (SELECT 1 FROM private.deletion_log WHERE profile_id = v_ghost_del),
    'GRP20-l — step-8 failure rolls back deletion_log ''pending'' write (step 1 rolled back)');
  PERFORM test_helpers.assert(
    (SELECT state FROM public.cases WHERE id = v_ghost_cid) = 'draft',
    'GRP20-l2 — step-8 failure: ghost''s draft case state still ''draft'' (step 2 cancel rolled back)');
  PERFORM test_helpers.assert(
    NOT EXISTS (SELECT 1 FROM public.exclusion_events WHERE player_id = v_ghost_del),
    'GRP20-l3 — step-8 failure: no exclusion_events inserted for ghost (step 3 rolled back)');
  PERFORM test_helpers.assert(
    (SELECT eligibility_status FROM public.investigation_members
     WHERE investigation_id = v_other_inv AND player_id = v_ghost_del) = 'eligible',
    'GRP20-l4 — step-8 failure: investigation_member eligibility still ''eligible'' (step 4 rolled back)');
  PERFORM test_helpers.assert(
    (SELECT archived_at FROM public.groups WHERE id = v_ghost_gid) IS NULL,
    'GRP20-l5 — step-8 failure: ghost''s owned group not archived (step 5 rolled back)');
  PERFORM test_helpers.assert(
    NOT EXISTS (SELECT 1 FROM private.profile_archive WHERE profile_id = v_ghost_del),
    'GRP20-l6 — step-8 failure: no profile_archive row for ghost (step 6a rolled back)');
  PERFORM test_helpers.assert(
    EXISTS (SELECT 1 FROM public.profiles WHERE id = v_ghost_del AND is_active = true),
    'GRP20-l7 — step-8 failure: profiles.is_active still true (step 6b rolled back)');
  PERFORM test_helpers.assert(
    (SELECT status FROM public.media_objects WHERE id = v_ghost_media) != 'deleted',
    'GRP20-l8 — step-8 failure: ghost''s media not tombstoned (step 7 rolled back)');

  -- Remove probe artifacts
  EXECUTE 'DROP TRIGGER IF EXISTS grp20l_atomicity_probe_trg ON private.deletion_log';
  EXECUTE 'DROP FUNCTION IF EXISTS private.grp20l_atomicity_probe()';
END;
$grp20$;

-- =============================================================================
-- GROUP 21 — reveal_case when all investigations are cancelled
--
-- REQ-5 cross-investigation design: if every investigation is cancelled before
-- the case is locked, reveal_case must still transition the case to 'revealed'
-- (the FOR LOOP over active investigations is simply empty) and must NOT create
-- any score_run rows for the cancelled investigations.
--
--   GRP21-a  reveal_case succeeds; state transitions to 'revealed'
--   GRP21-b  no score_run rows created for the cancelled investigation
-- =============================================================================
\echo ''
\echo '--- GROUP 21: reveal_case with all investigations cancelled ---'

DO $$
DECLARE
  v_poster uuid;
  v_det    uuid;
  v_gid    uuid;
  v_cid    uuid;
  v_mid    uuid;
  v_inv    uuid;
  v_state  text;
  v_cnt    bigint;
BEGIN
  v_poster := test_helpers.make_user('GRP21 Poster');
  v_det    := test_helpers.make_user('GRP21 Detective');
  v_gid    := test_helpers.make_group(v_poster, 'GRP21 Group');
  PERFORM test_helpers.add_member(v_gid, v_poster, v_det);
  SELECT case_id, media_id INTO v_cid, v_mid FROM test_helpers.make_case(v_poster);

  -- Launch the case with a deadline already in the past so lock_case will accept it
  SET LOCAL ROLE forkensics_executor;
  UPDATE public.cases SET state = 'launched',
    posted_at   = clock_timestamp() - interval '3 hours',
    deadline_at = clock_timestamp() - interval '1 minute'
  WHERE id = v_cid;
  RESET ROLE;

  -- Create an investigation and immediately cancel it
  v_inv := test_helpers.make_investigation(v_cid, v_gid);
  PERFORM test_helpers.make_investigation_member(v_inv, v_det);
  SET LOCAL ROLE forkensics_executor;
  UPDATE public.investigations SET status = 'cancelled', cancelled_at = clock_timestamp()
  WHERE investigation_id = v_inv;
  RESET ROLE;

  -- Lock the case (deadline has passed; state must be 'launched' → becomes 'locked')
  PERFORM public.lock_case(v_cid);

  SELECT state INTO v_state FROM public.cases WHERE id = v_cid;
  PERFORM test_helpers.assert(v_state = 'locked',
    'GRP21 setup — case locked after deadline (prerequisite for reveal)');

  -- Reveal as the poster; the active-investigation loop has zero rows → no scoring
  PERFORM test_helpers.set_auth_uid(v_poster);
  PERFORM public.reveal_case(v_cid);
  PERFORM test_helpers.clear_auth_uid();

  -- ---- GRP21-a: state = 'revealed' ----
  SELECT state INTO v_state FROM public.cases WHERE id = v_cid;
  PERFORM test_helpers.assert(
    v_state = 'revealed',
    'GRP21-a — reveal_case succeeds and sets state=revealed even when all investigations are cancelled');

  -- ---- GRP21-b: no score_runs for the cancelled investigation ----
  SELECT COUNT(*) INTO v_cnt FROM public.score_runs WHERE investigation_id = v_inv;
  PERFORM test_helpers.assert(
    v_cnt = 0,
    'GRP21-b — no score_run rows created for cancelled investigations during reveal');
END;
$$;

-- =============================================================================
-- GROUP 22 — V2 upload-session pipeline: full 5-step lifecycle
--
-- Exercises all five V2 state-transition functions in sequence against
-- private.upload_sessions. Proves the V2 behavioral regression passes after V4.
--
-- Correct lifecycle (from V2 spec):
--   reserve   → status='pending', storage_upload_expires_at=NULL
--   activate  → status='pending', storage_upload_expires_at SET (capability expiry stored)
--   advance_processing → status='processing'
--   advance_sanitized  → status='sanitized'
--   finalize  → status='complete'
--
--   GRP22-a  reserve_upload_session returns non-null session_id (service_role)
--   GRP22-b  activate_upload_session stores capability expiry; status stays pending
--   GRP22-c  advance_upload_session_processing → status=processing
--   GRP22-d  advance_upload_session_sanitized  → status=sanitized
--   GRP22-e  finalize_upload_session           → status=complete
-- =============================================================================
\echo ''
\echo '--- GROUP 22: V2 upload-session full 5-step pipeline (reserve→activate→processing→sanitized→complete) ---'

DO $$
DECLARE
  v_poster    uuid;
  v_cid       uuid;
  v_mid       uuid;
  v_sess_id   uuid;
  v_orig_path text;
  v_disp_path text;
  v_expiry    timestamptz;
  v_status    text;
BEGIN
  v_poster := test_helpers.make_user('GRP22 Poster');
  SELECT case_id, media_id INTO v_cid, v_mid FROM test_helpers.make_case(v_poster);

  -- ---- GRP22-a: reserve_upload_session → session_id ----
  -- token_hash must be exactly 64 lowercase hex characters (CHECK constraint).
  -- p_case_id is the V4 rename of V2's p_challenge_id; draft-state case required.
  -- Session expires_at = clock_timestamp() + 1 hour.
  SET LOCAL ROLE service_role;
  SELECT session_id, original_storage_path, display_storage_path
  INTO v_sess_id, v_orig_path, v_disp_path
  FROM public.reserve_upload_session(
    v_cid,
    v_poster,
    'cafebabecafebabecafebabecafebabecafebabecafebabecafebabecafebabe',
    'image/jpeg',
    750000,
    clock_timestamp() + interval '1 hour'
  );
  RESET ROLE;
  PERFORM test_helpers.assert(
    v_sess_id IS NOT NULL,
    'GRP22-a — reserve_upload_session returns non-null session_id as service_role (V2/V4 pipeline step 1)');

  -- ---- GRP22-b: activate_upload_session → storage_upload_expires_at stored ----
  -- Activation stores the upload capability expiry; it does NOT advance status.
  -- V2 activate enforces three constraints on p_actual_storage_upload_expires_at:
  --   (a) strictly future (> clock_timestamp())
  --   (b) <= session expires_at (≤ 1 hour from now)
  --   (c) <= clock_timestamp() + 5m30s (5-minute signing window + 30s clock tolerance)
  -- Passing 5 minutes satisfies all three; 30 minutes would RAISE FK_INVALID_INPUT.
  SET LOCAL ROLE service_role;
  PERFORM public.activate_upload_session(
    v_sess_id,
    clock_timestamp() + interval '5 minutes'
  );
  RESET ROLE;

  SELECT storage_upload_expires_at INTO v_expiry
  FROM private.upload_sessions WHERE session_id = v_sess_id;
  PERFORM test_helpers.assert(
    v_expiry IS NOT NULL,
    'GRP22-b — activate_upload_session stores storage_upload_expires_at; status remains pending (V2 pipeline step 2)');

  -- ---- GRP22-c: advance_upload_session_processing → status=processing ----
  -- Requires activate to have been called (storage_upload_expires_at IS NOT NULL).
  -- p_uploader_id must match the session's uploader_id; p_lease_duration sets the
  -- processing_lease_expires_at ceiling.
  SET LOCAL ROLE service_role;
  PERFORM public.advance_upload_session_processing(
    v_sess_id,
    v_poster,
    interval '5 minutes'
  );
  RESET ROLE;

  SELECT status INTO v_status FROM private.upload_sessions WHERE session_id = v_sess_id;
  PERFORM test_helpers.assert(
    v_status = 'processing',
    'GRP22-c — advance_upload_session_processing → status=processing (V2 pipeline step 3)');

  -- ---- GRP22-d: advance_upload_session_sanitized → status=sanitized ----
  SET LOCAL ROLE service_role;
  PERFORM public.advance_upload_session_sanitized(v_sess_id);
  RESET ROLE;

  SELECT status INTO v_status FROM private.upload_sessions WHERE session_id = v_sess_id;
  PERFORM test_helpers.assert(
    v_status = 'sanitized',
    'GRP22-d — advance_upload_session_sanitized → status=sanitized (V2 pipeline step 4)');

  -- ---- GRP22-e: finalize_upload_session → status=complete ----
  -- V4 rewrites the body (challenge_id → case_id) but the signature and status
  -- transitions are unchanged. sha256_hash must be 64 lowercase hex characters.
  SET LOCAL ROLE service_role;
  PERFORM public.finalize_upload_session(
    v_sess_id,
    'a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2'
  );
  RESET ROLE;

  SELECT status INTO v_status FROM private.upload_sessions WHERE session_id = v_sess_id;
  PERFORM test_helpers.assert(
    v_status = 'complete',
    'GRP22-e — finalize_upload_session → status=complete (V2/V4 pipeline step 5; behavioral V2 regression)');
END;
$$;

-- =============================================================================
-- GROUP 23 — Schema structural assertions: V4 rename proof, constraint existence,
--            partial index predicate, and RLS-enabled flags
--
-- These assertions query the system catalog (information_schema, pg_indexes,
-- pg_class) to verify structural contracts that no behavioral test can confirm:
-- column-level renames, constraint names, index WHERE predicates, and RLS flags.
--
--   GRP23-a  No legacy challenge_id column remains in cases, investigations,
--            comments, reactions, clues, score_runs, or content_reports
--   GRP23-b  case_id column is present in six representative V4 tables
--   GRP23-c  one_active_case_per_poster partial index has the correct predicate
--            covering draft, ready, launched, and locked states
--   GRP23-d  score_runs UNIQUE(investigation_id, revision_number) constraint exists
--   GRP23-e  investigations UNIQUE(case_id, group_id) constraint exists
--   GRP23-f  RLS is enabled on public.investigations and public.investigation_members
-- =============================================================================
\echo ''
\echo '--- GROUP 23: schema structural assertions (renames, constraints, indexes, RLS flags) ---'

DO $$
DECLARE
  v_cnt     bigint;
  v_predicate text;
BEGIN
  -- ---- GRP23-a: no legacy challenge_id column in any public or private table ----
  -- Covers ALL 12+ tables renamed in V4 (clues, comments, reactions, guess_attempts,
  -- correction_events, score_runs, guess_judgments, score_events, eligible_participants,
  -- exclusion_events, case_answer_aliases, case_secrets) plus private.upload_sessions.
  -- No IN() restriction — a rename omission on ANY table is caught.
  SELECT COUNT(*) INTO v_cnt
  FROM information_schema.columns
  WHERE column_name  = 'challenge_id'
    AND table_schema IN ('public', 'private');
  PERFORM test_helpers.assert(v_cnt = 0,
    'GRP23-a — no legacy challenge_id column exists in any public or private table (complete V4 rename; all 12+ tables covered)');

  -- ---- GRP23-b: case_id column is present in key V4 tables ----
  SELECT COUNT(DISTINCT table_name) INTO v_cnt
  FROM information_schema.columns
  WHERE table_schema = 'public'
    AND column_name  = 'case_id'
    AND table_name IN ('investigations', 'comments', 'reactions', 'clues', 'score_runs', 'guess_attempts');
  PERFORM test_helpers.assert(v_cnt = 6,
    'GRP23-b — case_id column present in all 6 key V4 tables (investigations, comments, reactions, clues, score_runs, guess_attempts)');

  -- ---- GRP23-c: one_active_case_per_poster partial index predicate ----
  -- Must cover exactly: draft, ready, launched, locked.
  -- Must NOT include old V3 state 'active' (replaced by 'launched'), 'cancelled', or 'revealed'.
  -- CRITICAL: the index NAME 'one_active_case_per_poster' contains the bare word 'active',
  -- so NOT LIKE '%active%' would always fail on the correct index.
  -- Instead we use NOT LIKE '%''active''%' which matches the single-quoted string 'active'
  -- as it appears in the WHERE-clause predicate (e.g. 'active'::text in ARRAY deparse form)
  -- but does NOT match the unquoted index name.  PostgreSQL always uses individual quoted
  -- literals ('draft'::text, ...) when decompiling IN(...) predicates in pg_indexes.indexdef.
  SELECT indexdef INTO v_predicate
  FROM pg_indexes
  WHERE schemaname = 'public' AND indexname = 'one_active_case_per_poster';
  PERFORM test_helpers.assert(
    v_predicate LIKE '%draft%' AND v_predicate LIKE '%ready%'
      AND v_predicate LIKE '%launched%' AND v_predicate LIKE '%locked%'
      AND v_predicate NOT LIKE '%''active''%'
      AND v_predicate NOT LIKE '%cancelled%'
      AND v_predicate NOT LIKE '%revealed%',
    'GRP23-c — one_active_case_per_poster predicate covers draft/ready/launched/locked only; excludes active, cancelled, revealed');

  -- ---- GRP23-d: score_runs UNIQUE(investigation_id, revision_number) — exact 2-column constraint ----
  -- V4 adds: ADD CONSTRAINT score_runs_inv_revision_unique UNIQUE (investigation_id, revision_number).
  -- Assertions: (a) both columns exist under the same UNIQUE constraint, (b) in the correct
  -- ordinal positions (investigation_id=1, revision_number=2), (c) EXACTLY 2 columns total
  -- (a 3-column superset constraint would also satisfy the double-join without the COUNT check).
  PERFORM test_helpers.assert(
    EXISTS (
      SELECT 1
      FROM information_schema.table_constraints tc
      JOIN information_schema.key_column_usage kcu1
        ON kcu1.constraint_name  = tc.constraint_name
       AND kcu1.table_schema     = tc.table_schema
       AND kcu1.column_name      = 'investigation_id'
       AND kcu1.ordinal_position = 1
      JOIN information_schema.key_column_usage kcu2
        ON kcu2.constraint_name  = tc.constraint_name
       AND kcu2.table_schema     = tc.table_schema
       AND kcu2.column_name      = 'revision_number'
       AND kcu2.ordinal_position = 2
      WHERE tc.table_schema    = 'public'
        AND tc.table_name      = 'score_runs'
        AND tc.constraint_type = 'UNIQUE'
        AND 2 = (
          SELECT COUNT(*) FROM information_schema.key_column_usage
          WHERE constraint_name = tc.constraint_name
            AND table_schema    = tc.table_schema
        )
    ),
    'GRP23-d — score_runs UNIQUE(investigation_id[1], revision_number[2]) — exactly 2 columns, correct order (score_runs_inv_revision_unique)');

  -- ---- GRP23-e: investigations UNIQUE(case_id, group_id) — exact 2-column constraint ----
  -- V4 CREATE TABLE public.investigations includes inline UNIQUE (case_id, group_id).
  -- Same rigor as GRP23-d: verify ordinal positions and exactly 2 columns total.
  PERFORM test_helpers.assert(
    EXISTS (
      SELECT 1
      FROM information_schema.table_constraints tc
      JOIN information_schema.key_column_usage kcu1
        ON kcu1.constraint_name  = tc.constraint_name
       AND kcu1.table_schema     = tc.table_schema
       AND kcu1.column_name      = 'case_id'
       AND kcu1.ordinal_position = 1
      JOIN information_schema.key_column_usage kcu2
        ON kcu2.constraint_name  = tc.constraint_name
       AND kcu2.table_schema     = tc.table_schema
       AND kcu2.column_name      = 'group_id'
       AND kcu2.ordinal_position = 2
      WHERE tc.table_schema    = 'public'
        AND tc.table_name      = 'investigations'
        AND tc.constraint_type = 'UNIQUE'
        AND 2 = (
          SELECT COUNT(*) FROM information_schema.key_column_usage
          WHERE constraint_name = tc.constraint_name
            AND table_schema    = tc.table_schema
        )
    ),
    'GRP23-e — investigations UNIQUE(case_id[1], group_id[2]) — exactly 2 columns, correct order (V4 inline constraint)');

  -- ---- GRP23-f: RLS enabled on investigations and investigation_members ----
  SELECT COUNT(*) INTO v_cnt
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public'
    AND c.relname IN ('investigations', 'investigation_members')
    AND c.relrowsecurity = true;
  PERFORM test_helpers.assert(v_cnt = 2,
    'GRP23-f — RLS enabled on both public.investigations and public.investigation_members');

  -- ---- GRP23-g: ga_one_per_player_race — UNIQUE(case_id, player_id, race), no partial predicate ----
  -- Rev 15 §: prevents more than one locked guess attempt per player per race per case.
  -- Verify: (a) index exists, (b) is UNIQUE, (c) exact column sequence in correct order,
  -- (d) no WHERE clause (unconditional — not a partial index).
  -- NOTE: position('race' IN indexdef) would match inside the index NAME 'ga_one_per_player_race'
  -- before reaching the column list — so we use an exact substring pattern instead.
  PERFORM test_helpers.assert(
    EXISTS (
      SELECT 1 FROM pg_indexes
      WHERE schemaname = 'public'
        AND tablename  = 'guess_attempts'
        AND indexname  = 'ga_one_per_player_race'
        AND indexdef   LIKE '%UNIQUE%'
        AND indexdef   LIKE '%(case_id, player_id, race)%'
        AND indexdef   NOT LIKE '%WHERE%'
    ),
    'GRP23-g — ga_one_per_player_race is a non-partial UNIQUE index on public.guess_attempts with columns (case_id, player_id, race) in order');

  -- ---- GRP23-h: ga_idempotency — UNIQUE partial index (case_id, player_id, idempotency_key) WHERE idempotency_key IS NOT NULL ----
  -- Rev 15 §: client-side idempotency guard prevents duplicate guess submissions.
  -- Verify: (a) index exists, (b) is UNIQUE, (c) exact column sequence in correct order,
  -- (d) has WHERE clause, (e) partial predicate is idempotency_key IS NOT NULL.
  -- Exact column-sequence LIKE avoids position() matching 'idempotency_key' in the WHERE clause
  -- instead of the column list.
  PERFORM test_helpers.assert(
    EXISTS (
      SELECT 1 FROM pg_indexes
      WHERE schemaname = 'public'
        AND tablename  = 'guess_attempts'
        AND indexname  = 'ga_idempotency'
        AND indexdef   LIKE '%UNIQUE%'
        AND indexdef   LIKE '%(case_id, player_id, idempotency_key)%'
        AND indexdef   LIKE '%WHERE%'
        AND indexdef   LIKE '%idempotency_key IS NOT NULL%'
    ),
    'GRP23-h — ga_idempotency is a UNIQUE partial index on public.guess_attempts with columns (case_id, player_id, idempotency_key) in order WHERE idempotency_key IS NOT NULL');
END;
$$;

\echo ''
\echo '============================================================='
\echo 'REQ-7 concurrency tests: run V4_concurrency_harness.sh'
\echo 'REQ-6 V3→V4 state-conversion proof: see run_v4_suite.sh Step 1'
\echo '============================================================='

ROLLBACK;

\echo ''
\echo 'V4 acceptance tests complete (BEGIN/ROLLBACK — no data persisted).'
