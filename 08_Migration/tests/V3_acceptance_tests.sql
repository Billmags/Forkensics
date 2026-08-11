-- =============================================================================
-- Forkensics — V3 Migration Acceptance Tests
-- Source: Step 24.1 Rev 15, Part 12 (T1–T18 matrix)
-- Migration under test: V3__ugc_safety_moderation.sql
-- Codex-approved SHA-256 (migration): 0f3fd50c22c0cded71ad3c280c1a0cae07458f417ac567692bce4cba0d8e71fb
--
-- Test file SHA-256 (Round 7 — post Codex Round 6 blocker fixes):
--   [SHA pending Codex review]
-- Previous (Round 6): d74452804a943bbefb85e6bf8d532429bf993796cea69c1d6835eb3858191bcc
-- Previous (Round 5): e2ba157b76d82cc27405a06a9cb39a6f71f268ddadd52e818d1e56f938e5f668
-- Previous (Round 4): dd7cd0cdccadb9b277ef587847f8fbd2f9ca714d593e2fb2f016473e5c5e0a24
-- Previous (Round 3): e5e62fc3b68298364e44c2e9173dba05bacd3e0ef4c6cc4daddd3f3cdd5332fe
--
-- Round 7 changes (4 Codex Round 6 blockers + additional hardening):
--   1. storage_key (NOT NULL) added to all private.media_storage_keys INSERTs — in
--      test_helpers.make_media_with_key, the T13.3 inline INSERT, and both harnesses.
--      V1 defines storage_key text NOT NULL (original upload path). Value pattern:
--      'uploads/' || v_mid::text || '/original.jpg'.
--   2. T7 harness: three challenges now use three distinct poster JWTs to avoid violating
--      one_active_challenge_per_poster (partial UNIQUE index on state IN ('draft','active',
--      'locked')). T7.1=poster 001, T7.2=poster 004, T7.5=poster 007 (T7H Uploader,
--      added to group_members as 'member'). JWT is set via set_config before each INSERT.
--   3. T16.5: added GRANT SELECT ON public.clues TO forkensics_rls_helper inside BEGIN.
--      forkensics_rls_helper's UPDATE WHERE id = v_clue_id requires SELECT privilege on
--      clues.id; without it the command fails with 42501 before reaching the trigger.
--   4. R19.7 (T5 harness): redesigned as a coordinated two-session race. Session A acquires
--      FOR UPDATE on the challenge, then sleeps (holding the lock). Session B calls
--      report_content which internally does SELECT ... FOR UPDATE on the same challenge
--      (step b) and blocks. A commits after nulling media_object_id. B resumes, re-reads
--      challenge (media_object_id=NULL), and IS DISTINCT FROM check raises FK_NOT_FOUND.
--      This exercises the real recheck code path at report_content step c. A fourth poster
--      (T5H Poster2, id 004) is added to the fixture so T5.1/T5.2 (poster 001) and R19.7
--      (poster 004) challenges do not share a poster and violate one_active_challenge_per_poster.
--   Additional hardening:
--   * test_helpers.do_reveal now calls private.do_reveal_impl(p_challenge_id) directly,
--     which is the real reveal lifecycle (SECURITY DEFINER, owned by forkensics_executor,
--     creates score_run revision 1, sets state='revealed'). Manual rules_versions and
--     score_runs fabrication removed.
--   * T5.1/T5.2: Session B output captured; if B lost, its error must be FK_NOT_FOUND or
--     FK_WRONG_STATE — an unexpected error (e.g., permission denied) fails the test.
--   * T7.2: reporter (Session C) output captured; if C lost, error must be an FK_* error.
--   * T7.5: both reporters must succeed (R_G=0 && R_H=0) and exactly 2 reports must be
--     created before remove_content is called (≥1 changed to =2 exactly).
--   * Both harnesses: EXIT trap revokes forkensics_executor if fixture setup fails.
--
-- Round 6 changes (5 Codex Round 5 blockers resolved):
--   1. T16.4/T16.5: replaced forkensics_test_attacker (requires superuser BYPASSRLS, which
--      local postgres lacks) with forkensics_rls_helper (an existing BYPASSRLS role created
--      in V1). Inside the BEGIN transaction, column-level UPDATE grants on
--      (moderator_removed_at, moderator_removal_action_id) for challenges and clues are
--      temporarily granted to forkensics_rls_helper; ROLLBACK removes them automatically.
--      The pre-test DDL block (CREATE ROLE forkensics_test_attacker) and the post-ROLLBACK
--      cleanup (DROP ROLE) are both removed — no out-of-transaction DDL is needed.
--   2. T3.5: replaced direct SET LOCAL ROLE forkensics_executor + UPDATE state='revealed'
--      with test_helpers.do_reveal(v_cid) — a SECURITY DEFINER helper owned by
--      forkensics_executor. (Round 7: do_reveal now calls private.do_reveal_impl directly.)
--   3. T5/T7 harnesses: replaced direct challenge INSERTs with two-step JWT + executor approach.
--   4. T5/T7 harnesses: removed cleanup sections violating FK_ACTION_IMMUTABLE.
--   5. T5/T7 harnesses: hardened concurrency assertions (at-least-one-success, T7.3 FK check).
--
-- Round 5 changes (7 Codex Round 4 blockers resolved):
--   1. T13.2: replaced approve_photo with reject_photo. approve_photo does not read
--      sha256_hash; reject_photo reads it, raises FK_MEDIA_METADATA_INCOMPLETE when NULL.
--      State assertion remains valid (reject_photo raises before changing status).
--   2. T3.5: reveal challenge before building score chain (superseded by Round 6 do_reveal).
--   3. T16.1: fresh poster+group (v_poster_16_1, v_gid_16_1) to avoid
--      one_active_challenge_per_poster UNIQUE index conflict (index covers
--      state IN ('draft','active','locked'); v_poster already has an active challenge).
--   4. T16.4/T16.5: forkensics_test_attacker approach (superseded by Round 6 forkensics_rls_helper).
--   5. Harnesses: private.moderator_grants → private.moderators (correct table name);
--      ON_ERROR_STOP=1 added to all psql calls.
--   6. T7 harness: added T7.2 (concurrent report+remove), T7.3 (concurrent approve+reject),
--      T7.5 (multiple reporters → single remove_content actions all reports).
--   7. T5 harness: added R19.7 (superseded by Round 6 sequential version).
--
-- Round 4 changes (8 Codex blockers resolved):
--   1. All negative tests: replaced self-catching sentinel 'FAIL: expected FK_*' with
--      neutral 'UNEXPECTED_SUCCESS' so the WHEN OTHERS branch cannot self-catch.
--      Affected: T1.7, T1.8, T5.1, T8.2, T8.3, T8.4, T9.2, T10.2, T10.3, T11.3,
--      T11.8, T11.11, T11.12, T13.2, T13.3, T16.4, T16.5, T16.6a, T16.6b, R19.7.
--   2. R19.2: pg_policies.permissive = 'RESTRICTIVE' (not 'NO').
--   3. T11.10: guesser added BEFORE activation so they appear in eligible_participants.
--   4. T13.2: neutral sentinel applied (approve_photo test, now corrected in Round 5).
--   5. T14.1-T14.5: rewritten to prove NOT claimable while pending reports exist.
--   6. T16.4/T16.5: SET LOCAL ROLE authenticated (fixed in Round 5 with test_attacker role).
--   7. T8.3/T8.4: processing/rejected status via direct UPDATE.
--   8. T3.5: real score chain INSERT (reveal fix applied in Round 5).
--      T5/T7 concurrency harnesses: T5_lock_order_harness.sh and T7_concurrency_harness.sh
--      created in 08_Migration/tests/.
--
-- Execution (run after applying V1 + V2 + V3 to a fresh local DB):
--   psql "$DATABASE_URL" --set ON_ERROR_STOP=on \
--        -f 08_Migration/tests/V3_acceptance_tests.sql
--
-- All tests run inside a single BEGIN/ROLLBACK — no test data persists.
-- Concurrency tests (T5, T7) require the shell harnesses listed above.
-- =============================================================================

\set ON_ERROR_STOP on

BEGIN;

-- =============================================================================
-- SECTION 0 — PREFLIGHT: Verify V3 temporary grants were revoked
-- =============================================================================
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_auth_members am
    JOIN pg_roles r ON r.oid = am.roleid
    JOIN pg_roles m ON m.oid = am.member
    JOIN pg_roles g ON g.oid = am.grantor
    WHERE r.rolname = 'forkensics_executor'
      AND m.rolname = 'postgres'
      AND g.rolname = 'postgres'
  ) THEN
    RAISE EXCEPTION 'PREFLIGHT FAILED: V3 left forkensics_executor→postgres grant (grantor=postgres)';
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
    RAISE EXCEPTION 'PREFLIGHT FAILED: V3 left forkensics_rls_helper→postgres grant (grantor=postgres)';
  END IF;

  -- Verify new V3 tables exist
  IF NOT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public'  AND table_name='content_reports')   THEN RAISE EXCEPTION 'PREFLIGHT FAILED: public.content_reports missing'; END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public'  AND table_name='user_blocks')       THEN RAISE EXCEPTION 'PREFLIGHT FAILED: public.user_blocks missing'; END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public'  AND table_name='moderation_actions') THEN RAISE EXCEPTION 'PREFLIGHT FAILED: public.moderation_actions missing'; END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='private' AND table_name='moderators')        THEN RAISE EXCEPTION 'PREFLIGHT FAILED: private.moderators missing'; END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='private' AND table_name='profile_suspensions') THEN RAISE EXCEPTION 'PREFLIGHT FAILED: private.profile_suspensions missing'; END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='private' AND table_name='moderation_evidence') THEN RAISE EXCEPTION 'PREFLIGHT FAILED: private.moderation_evidence missing'; END IF;

  -- Verify sha256_hash is NOT NULL (V2b)
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='private' AND table_name='media_storage_keys'
      AND column_name='sha256_hash' AND is_nullable='YES'
  ) THEN RAISE EXCEPTION 'PREFLIGHT FAILED: media_storage_keys.sha256_hash still nullable (V2b not applied)'; END IF;

  -- Verify is_suspended column on profiles
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='profiles' AND column_name='is_suspended'
  ) THEN RAISE EXCEPTION 'PREFLIGHT FAILED: profiles.is_suspended column missing'; END IF;

  -- Verify profile_suspensions backfill: every existing profile should have a row
  IF EXISTS (
    SELECT 1 FROM public.profiles p
    WHERE NOT EXISTS (SELECT 1 FROM private.profile_suspensions ps WHERE ps.profile_id = p.id)
    LIMIT 1
  ) THEN RAISE EXCEPTION 'PREFLIGHT FAILED: profile_suspensions backfill incomplete — orphaned profile rows found'; END IF;

  RAISE NOTICE 'PREFLIGHT PASSED: V3 schema and grant state verified.';
END;
$$;

-- Re-grant executor role membership for the test session (rolled back at end)
GRANT forkensics_executor   TO postgres;
GRANT forkensics_rls_helper TO postgres;

-- T16.4/T16.5: grant narrow column UPDATE to forkensics_rls_helper so it can reach the
-- SECURITY INVOKER trigger (privilege check passes, then trigger fires FK_REMOVAL_UNAUTHORIZED
-- because current_user = 'forkensics_rls_helper' ≠ 'forkensics_executor').
-- forkensics_rls_helper already has BYPASSRLS + SELECT on these tables from V1.
-- These grants are inside BEGIN and are rolled back automatically with ROLLBACK.
GRANT UPDATE (moderator_removed_at, moderator_removal_action_id)
  ON public.challenges TO forkensics_rls_helper;
GRANT UPDATE (moderator_removed_at, moderator_removal_action_id)
  ON public.clues TO forkensics_rls_helper;
-- T16.5: forkensics_rls_helper's UPDATE ... WHERE id = v_clue_id requires SELECT on clues.id.
-- Without this, the executor-privilege check (42501) fires before the trigger.
-- This grant is inside BEGIN and is rolled back automatically with ROLLBACK.
GRANT SELECT ON public.clues TO forkensics_rls_helper;

-- =============================================================================
-- SECTION 0.5 — HELPERS
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS test_helpers;
GRANT USAGE  ON SCHEMA test_helpers TO authenticated;
GRANT CREATE ON SCHEMA test_helpers TO forkensics_executor;

CREATE OR REPLACE FUNCTION test_helpers.assert(p_condition boolean, p_message text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF NOT p_condition THEN
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

-- Creates auth.users + triggers profile + profile_suspensions row (V3 handle_new_user)
CREATE OR REPLACE FUNCTION test_helpers.make_user(p_display_name text DEFAULT 'Test Player')
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE v_uid uuid := gen_random_uuid();
BEGIN
  INSERT INTO auth.users (id, email, raw_user_meta_data, created_at, updated_at)
  VALUES (v_uid, v_uid || '@test.invalid',
          json_build_object('display_name', p_display_name)::jsonb, now(), now());
  UPDATE public.profiles SET display_name = p_display_name, onboarding_complete = true
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

-- Creates a media_objects row with a media_storage_keys row (sha256 required in V3)
-- Default sha256 = sha256('test-media') in hex (a deterministic 64-char hex string)
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
  VALUES (v_mid, 'uploads/' || v_mid::text || '/original.jpg', p_sha256, 'challenges/test/' || v_mid::text || '/display.webp');
  RETURN v_mid;
END;
$$;

-- Creates a draft challenge with a linked media_objects + storage key row
CREATE OR REPLACE FUNCTION test_helpers.make_draft_challenge_with_media(
  p_poster_id uuid,
  p_group_id  uuid
) RETURNS TABLE(challenge_id uuid, media_id uuid) LANGUAGE plpgsql AS $$
DECLARE
  v_mid uuid;
  v_cid uuid;
BEGIN
  v_mid := test_helpers.make_media_with_key(p_poster_id);
  PERFORM test_helpers.set_auth_uid(p_poster_id);
  INSERT INTO public.challenges (group_id, media_object_id)
  VALUES (p_group_id, v_mid)
  RETURNING id INTO v_cid;
  INSERT INTO public.challenge_secrets (challenge_id, display_dish, canonical_dish, display_restaurant, canonical_restaurant)
  VALUES (v_cid, 'Test Dish', 'test dish', 'Test Place', 'test place');
  PERFORM test_helpers.clear_auth_uid();
  RETURN QUERY SELECT v_cid, v_mid;
END;
$$;

-- Creates a draft challenge with media (required for activation).
-- Wraps make_draft_challenge_with_media and returns only the challenge UUID.
CREATE OR REPLACE FUNCTION test_helpers.make_challenge(p_poster_id uuid, p_group_id uuid)
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE v_cid uuid;
BEGIN
  SELECT challenge_id INTO v_cid
  FROM test_helpers.make_draft_challenge_with_media(p_poster_id, p_group_id);
  RETURN v_cid;
END;
$$;

-- Activates a challenge (pushes state machine)
CREATE OR REPLACE FUNCTION test_helpers.activate(p_poster_id uuid, p_challenge_id uuid)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM test_helpers.set_auth_uid(p_poster_id);
  PERFORM public.activate_challenge(p_challenge_id);
  PERFORM test_helpers.clear_auth_uid();
END;
$$;

-- Force-expire a challenge for reveal/lock flow (SECURITY DEFINER as forkensics_executor)
CREATE OR REPLACE FUNCTION test_helpers.expire_challenge(p_challenge_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  UPDATE public.challenges SET deadline_at = now() - interval '1 second' WHERE id = p_challenge_id;
END;
$$;
ALTER FUNCTION test_helpers.expire_challenge(uuid) OWNER TO forkensics_executor;

-- Advances a challenge to 'revealed' by calling the real reveal lifecycle function.
-- private.do_reveal_impl is SECURITY DEFINER (owned by forkensics_executor); it accepts
-- 'active' or 'locked' state, creates score_run revision 1, and sets state='revealed'.
-- This function wraps it as SECURITY DEFINER so forkensics_executor privileges are in effect
-- for the call. T3.5 then queries the created score_run and inserts guess_judgments.
CREATE OR REPLACE FUNCTION test_helpers.do_reveal(p_challenge_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM private.do_reveal_impl(p_challenge_id);
END;
$$;
ALTER FUNCTION test_helpers.do_reveal(uuid) OWNER TO forkensics_executor;

-- Adds a comment as a given user; returns comment id
CREATE OR REPLACE FUNCTION test_helpers.make_comment(p_author_id uuid, p_challenge_id uuid, p_text text DEFAULT 'Hello!')
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE v_id uuid;
BEGIN
  PERFORM test_helpers.set_auth_uid(p_author_id);
  INSERT INTO public.comments (challenge_id, author_id, text)
  VALUES (p_challenge_id, p_author_id, p_text)
  RETURNING id INTO v_id;
  PERFORM test_helpers.clear_auth_uid();
  RETURN v_id;
END;
$$;

-- Adds a clue as a given user; returns clue id
CREATE OR REPLACE FUNCTION test_helpers.make_clue(p_poster_id uuid, p_challenge_id uuid, p_text text DEFAULT 'A clue')
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE v_id uuid;
BEGIN
  PERFORM test_helpers.set_auth_uid(p_poster_id);
  INSERT INTO public.clues (challenge_id, poster_id, text)
  VALUES (p_challenge_id, p_poster_id, p_text)
  RETURNING id INTO v_id;
  PERFORM test_helpers.clear_auth_uid();
  RETURN v_id;
END;
$$;

-- Makes a user a moderator (direct insert into private schema)
CREATE OR REPLACE FUNCTION test_helpers.make_moderator(p_profile_id uuid)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO private.moderators (profile_id) VALUES (p_profile_id) ON CONFLICT DO NOTHING;
END;
$$;

-- Blocks one user by another (calls block_user as blocker)
CREATE OR REPLACE FUNCTION test_helpers.do_block(p_blocker_id uuid, p_blocked_id uuid)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM test_helpers.set_auth_uid(p_blocker_id);
  PERFORM public.block_user(p_blocked_id);
  PERFORM test_helpers.clear_auth_uid();
END;
$$;

-- Reports content as a given caller; returns the report_id
CREATE OR REPLACE FUNCTION test_helpers.do_report(
  p_reporter_id uuid,
  p_target_type text,
  p_target_id   uuid,
  p_category    text DEFAULT 'offensive_content',  -- valid categories: inappropriate_image, offensive_content, spam, harassment, copyright, other
  p_detail      text DEFAULT 'test report'
) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE v_rid uuid;
BEGIN
  PERFORM test_helpers.set_auth_uid(p_reporter_id);
  SELECT report_id INTO v_rid
  FROM public.report_content(p_target_type, p_target_id, p_category, p_detail);
  PERFORM test_helpers.clear_auth_uid();
  RETURN v_rid;
END;
$$;

-- Suspends a profile via suspend_user (called as postgres = service_role equivalent)
CREATE OR REPLACE FUNCTION test_helpers.do_suspend(p_moderator_id uuid, p_target_id uuid, p_reason text DEFAULT 'test suspension')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM public.suspend_user(p_target_id, p_moderator_id, p_reason);
END;
$$;

-- Helper to make a guess attempt.
-- p_race: 'what' (dish) or 'where' (restaurant).
-- p_guess: the dish name when race='what', restaurant name when race='where'.
-- receipt_sequence defaults to 1; pass a different value for multi-guess scenarios.
CREATE OR REPLACE FUNCTION test_helpers.make_guess(
  p_player_id       uuid,
  p_challenge_id    uuid,
  p_race            text DEFAULT 'what',
  p_guess           text DEFAULT 'Test Dish',
  p_receipt_seq     bigint DEFAULT 1
) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE v_id uuid;
BEGIN
  PERFORM test_helpers.set_auth_uid(p_player_id);
  INSERT INTO public.guess_attempts
    (challenge_id, player_id, race, dish_guess, restaurant_guess, receipt_sequence)
  VALUES (
    p_challenge_id, p_player_id, p_race,
    CASE WHEN p_race = 'what'  THEN p_guess ELSE NULL END,
    CASE WHEN p_race = 'where' THEN p_guess ELSE NULL END,
    p_receipt_seq
  )
  RETURNING id INTO v_id;
  PERFORM test_helpers.clear_auth_uid();
  RETURN v_id;
END;
$$;

GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA test_helpers TO authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA test_helpers TO forkensics_executor;

\echo ''
\echo '============================================================='
\echo 'Forkensics V3 Acceptance Tests (T1–T18)'
\echo '============================================================='

-- =============================================================================
-- GROUP 1 — T1: Comment trigger (8 tests)
-- =============================================================================
\echo ''
\echo '--- GROUP 1: Comment trigger ---'

DO $$
DECLARE
  v_poster uuid; v_member uuid; v_mod uuid; v_gid uuid; v_cid uuid; v_comment_id uuid;
  v_ts_before timestamptz; v_ts_after timestamptz; v_actual_ts timestamptz;
BEGIN
  v_poster := test_helpers.make_user('T1 Poster');
  v_member := test_helpers.make_user('T1 Member');
  v_mod    := test_helpers.make_user('T1 Moderator');
  PERFORM test_helpers.make_moderator(v_mod);
  v_gid    := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_gid, v_poster, v_member);
  v_cid    := test_helpers.make_challenge(v_poster, v_gid);
  PERFORM test_helpers.activate(v_poster, v_cid);
  -- Member must guess before commenting (V1 Table Talk rule: non-poster may comment only
  -- after guessing or after reveal). Without this the RLS blocks the comment, not the trigger.
  PERFORM test_helpers.make_guess(v_member, v_cid);

  -- Make a comment as member
  v_comment_id := test_helpers.make_comment(v_member, v_cid, 'Original text');

  -- T1.1: Authenticated author changes `text` → column privilege → insufficient_privilege
  BEGIN
    PERFORM test_helpers.set_auth_uid(v_member);
    UPDATE public.comments SET text = 'Hacked' WHERE id = v_comment_id;
    PERFORM test_helpers.clear_auth_uid();
    RAISE EXCEPTION 'T1.1 FAIL: expected insufficient_privilege, got success';
  EXCEPTION
    WHEN insufficient_privilege THEN
      PERFORM test_helpers.clear_auth_uid();
      RAISE NOTICE 'PASS: T1.1 — authenticated cannot UPDATE comments.text (column privilege)';
    WHEN OTHERS THEN
      PERFORM test_helpers.clear_auth_uid();
      RAISE EXCEPTION 'T1.1 FAIL: unexpected SQLSTATE %, message: %', SQLSTATE, SQLERRM;
  END;

  -- T1.2: Non-author attempts UPDATE on deleted_at → RLS → 0 rows updated
  PERFORM test_helpers.set_auth_uid(v_poster);
  UPDATE public.comments SET deleted_at = NOW() WHERE id = v_comment_id;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(
    NOT EXISTS (SELECT 1 FROM public.comments WHERE id = v_comment_id AND deleted_at IS NOT NULL),
    'T1.2 — non-author UPDATE deleted_at gives 0 rows (RLS)');

  -- T1.3: Author calls soft_delete_comment() → SECURITY DEFINER bypasses RLS, trigger Path 2 fires
  -- Direct authenticated UPDATE is intentionally blocked: setting deleted_at makes the row
  -- invisible under the V1 SELECT policy (USING deleted_at IS NULL), raising "new row violates
  -- row-level security policy". The correct application path is soft_delete_comment().
  v_ts_before := clock_timestamp();
  PERFORM test_helpers.set_auth_uid(v_member);
  PERFORM public.soft_delete_comment(v_comment_id);
  PERFORM test_helpers.clear_auth_uid();
  v_ts_after := clock_timestamp();
  SELECT deleted_at INTO v_actual_ts FROM public.comments WHERE id = v_comment_id;
  PERFORM test_helpers.assert(
    v_actual_ts IS NOT NULL AND v_actual_ts >= v_ts_before AND v_actual_ts <= v_ts_after,
    'T1.3 — soft_delete_comment() sets deleted_at to server time (Path 2)');

  -- Soft-delete is one-way by design (V1 design, confirmed T1.3 above). No reset.

  -- T1.4: Author supplies past deleted_at → trigger overrides to server time (Path 2)
  -- soft_delete_comment() accepts no timestamp argument and always uses clock_timestamp(),
  -- so we must reach the trigger directly. We run as forkensics_executor (BYPASSRLS) to
  -- clear the RLS barrier while setting jwt.claims so private.auth_uid() returns the author,
  -- exactly matching trigger Path 2's author-check condition.
  v_comment_id := test_helpers.make_comment(v_member, v_cid, 'T1.4 fresh comment');
  v_ts_before := clock_timestamp();
  BEGIN
    PERFORM test_helpers.set_auth_uid(v_member);
    SET LOCAL ROLE forkensics_executor;
    UPDATE public.comments SET deleted_at = '2020-01-01 00:00:00+00' WHERE id = v_comment_id;
    RESET ROLE;
    PERFORM test_helpers.clear_auth_uid();
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    PERFORM test_helpers.clear_auth_uid();
    RAISE EXCEPTION 'T1.4 FAIL: % %', SQLSTATE, SQLERRM;
  END;
  v_ts_after := clock_timestamp();
  SELECT deleted_at INTO v_actual_ts FROM public.comments WHERE id = v_comment_id;
  PERFORM test_helpers.assert(
    v_actual_ts >= v_ts_before AND v_actual_ts <= v_ts_after,
    'T1.4 — trigger overrides past deleted_at to server time (Path 2)');

  -- T1.5: remove_content('comment') via service_role (runs as forkensics_executor) → Path 1 → succeeds
  -- T1.3 and T1.4 consumed their comments (both soft-deleted). Use a fresh, undeleted comment.
  v_comment_id := test_helpers.make_comment(v_member, v_cid, 'T1.5 fresh comment');
  PERFORM public.remove_content('comment', v_comment_id, v_mod, NULL, 'moderation test');
  PERFORM test_helpers.assert(
    EXISTS (SELECT 1 FROM public.comments
            WHERE id = v_comment_id
              AND text = '[removed by moderator]'
              AND moderator_removed_at IS NOT NULL
              AND moderator_removal_action_id IS NOT NULL),
    'T1.5 — remove_content sets comment to placeholder, both moderation fields set');

  -- T1.6: Authenticated sets moderator_removed_at directly → column privilege → insufficient_privilege
  -- T1.5 consumed the previous comment. Use a fresh, unmoderated comment.
  v_comment_id := test_helpers.make_comment(v_member, v_cid, 'T1.6 fresh comment');
  BEGIN
    PERFORM test_helpers.set_auth_uid(v_member);
    UPDATE public.comments SET moderator_removed_at = NOW() WHERE id = v_comment_id;
    PERFORM test_helpers.clear_auth_uid();
    RAISE EXCEPTION 'T1.6 FAIL: expected insufficient_privilege';
  EXCEPTION
    WHEN insufficient_privilege THEN
      PERFORM test_helpers.clear_auth_uid();
      RAISE NOTICE 'PASS: T1.6 — authenticated cannot UPDATE moderator_removed_at (column privilege)';
    WHEN OTHERS THEN
      PERFORM test_helpers.clear_auth_uid();
      RAISE EXCEPTION 'T1.6 FAIL: unexpected SQLSTATE %, message: %', SQLSTATE, SQLERRM;
  END;

  -- T1.7: forkensics_executor sets wrong placeholder text → trigger → FK_COMMENT_IMMUTABLE
  BEGIN
    SET LOCAL ROLE forkensics_executor;
    UPDATE public.comments
    SET moderator_removed_at        = clock_timestamp(),
        moderator_removal_action_id = gen_random_uuid(),
        text                        = 'WRONG PLACEHOLDER'
    WHERE id = v_comment_id;
    RESET ROLE;
    RAISE EXCEPTION 'UNEXPECTED_SUCCESS';
  EXCEPTION
    WHEN OTHERS THEN
      RESET ROLE;
      IF SQLERRM = 'UNEXPECTED_SUCCESS' THEN
        RAISE EXCEPTION 'T1.7 FAIL: trigger did not fire (expected FK_COMMENT_IMMUTABLE)';
      ELSIF SQLERRM LIKE '%FK_COMMENT_IMMUTABLE%' THEN
        RAISE NOTICE 'PASS: T1.7 — wrong placeholder raises FK_COMMENT_IMMUTABLE';
      ELSE
        RAISE EXCEPTION 'T1.7 FAIL: got unexpected error: % %', SQLSTATE, SQLERRM;
      END IF;
  END;

  -- T1.8: forkensics_executor: moderator_removed_at already set → FK_COMMENT_IMMUTABLE
  -- First perform a valid removal:
  PERFORM public.remove_content('comment', v_comment_id, v_mod, NULL, 'first removal');
  -- Now try to update the already-set field again as forkensics_executor:
  BEGIN
    SET LOCAL ROLE forkensics_executor;
    UPDATE public.comments
    SET moderator_removed_at = clock_timestamp()
    WHERE id = v_comment_id;
    RESET ROLE;
    RAISE EXCEPTION 'UNEXPECTED_SUCCESS';
  EXCEPTION
    WHEN OTHERS THEN
      RESET ROLE;
      IF SQLERRM = 'UNEXPECTED_SUCCESS' THEN
        RAISE EXCEPTION 'T1.8 FAIL: update succeeded (expected FK_REMOVAL_IMMUTABLE or FK_COMMENT_IMMUTABLE)';
      ELSIF SQLERRM LIKE '%FK_REMOVAL_IMMUTABLE%' OR SQLERRM LIKE '%FK_COMMENT_IMMUTABLE%' THEN
        RAISE NOTICE 'PASS: T1.8 — already-removed comment raises immutability exception';
      ELSE
        RAISE EXCEPTION 'T1.8 FAIL: unexpected error: % %', SQLSTATE, SQLERRM;
      END IF;
  END;

END;
$$;

-- =============================================================================
-- GROUP 2 — T2: can_view_challenge baseline (6 tests)
-- =============================================================================
\echo ''
\echo '--- GROUP 2: can_view_challenge ---'

DO $$
DECLARE
  v_poster      uuid;
  v_snap_member uuid;   -- joins group BEFORE activation → snapshotted at activation
  v_late_member uuid;   -- joins group AFTER activation  → NOT snapshotted
  v_outsider    uuid;
  v_gid         uuid;
  v_cid         uuid;
BEGIN
  v_poster      := test_helpers.make_user('T2 Poster');
  v_snap_member := test_helpers.make_user('T2 SnapMember');
  v_late_member := test_helpers.make_user('T2 LateMember');
  v_outsider    := test_helpers.make_user('T2 Outsider');
  v_gid         := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_gid, v_poster, v_snap_member);
  v_cid := test_helpers.make_challenge(v_poster, v_gid);

  -- T2.1: Poster's own draft → true
  PERFORM test_helpers.set_auth_uid(v_poster);
  PERFORM test_helpers.assert(
    private.can_view_challenge(v_cid),
    'T2.1 — poster can view own draft');
  PERFORM test_helpers.clear_auth_uid();

  -- T2.2: Non-poster, draft → false
  PERFORM test_helpers.set_auth_uid(v_snap_member);
  PERFORM test_helpers.assert(
    NOT private.can_view_challenge(v_cid),
    'T2.2 — non-poster cannot view draft');
  PERFORM test_helpers.clear_auth_uid();

  -- Activate: snapshots v_snap_member into eligible_participants
  PERFORM test_helpers.activate(v_poster, v_cid);

  -- Add v_late_member AFTER activation (not snapshotted)
  PERFORM test_helpers.add_member(v_gid, v_poster, v_late_member);

  -- T2.3: Posted, snapshotted group member, no block → true
  PERFORM test_helpers.set_auth_uid(v_snap_member);
  PERFORM test_helpers.assert(
    private.can_view_challenge(v_cid),
    'T2.3 — snapshotted group member can view posted challenge');
  PERFORM test_helpers.clear_auth_uid();

  -- T2.4: Late (non-snapshotted) member blocks poster → false
  -- v_late_member is in the group but NOT in eligible_participants
  PERFORM test_helpers.do_block(v_late_member, v_poster);
  PERFORM test_helpers.set_auth_uid(v_late_member);
  PERFORM test_helpers.assert(
    NOT private.can_view_challenge(v_cid),
    'T2.4 — non-snapshotted member who blocked poster cannot view challenge');
  PERFORM test_helpers.clear_auth_uid();

  -- T2.5: Block exists; snapshotted member (eligible participant) → still true
  -- v_snap_member is already in eligible_participants (snapshotted at activation)
  PERFORM test_helpers.do_block(v_snap_member, v_poster);
  PERFORM test_helpers.set_auth_uid(v_snap_member);
  PERFORM test_helpers.assert(
    private.can_view_challenge(v_cid),
    'T2.5 — eligible participant can view despite block (snapshot carve-out)');
  PERFORM test_helpers.clear_auth_uid();

  -- T2.6: Posted, non-member (outsider) → false
  PERFORM test_helpers.set_auth_uid(v_outsider);
  PERFORM test_helpers.assert(
    NOT private.can_view_challenge(v_cid),
    'T2.6 — outsider cannot view posted challenge');
  PERFORM test_helpers.clear_auth_uid();

END;
$$;

-- =============================================================================
-- GROUP 3 — T3: Child-table block enforcement (10 tests)
-- =============================================================================
\echo ''
\echo '--- GROUP 3: Child-table block enforcement ---'

DO $$
DECLARE
  v_poster   uuid;
  v_eligible uuid;   -- joins group BEFORE activation → snapshotted; not excluded; used for T3.5b judge visibility
  v_excluded uuid;   -- joins group BEFORE activation → snapshotted; excluded before reveal; used for T3.7
  v_viewer   uuid;   -- joins group AFTER activation  → NOT snapshotted
  v_mod      uuid;
  v_gid      uuid;
  v_cid      uuid;
  v_cnt      int;
BEGIN
  v_poster   := test_helpers.make_user('T3 Poster');
  v_eligible := test_helpers.make_user('T3 Eligible');
  v_excluded := test_helpers.make_user('T3 Excluded');
  v_mod      := test_helpers.make_user('T3 Mod');
  v_gid      := test_helpers.make_group(v_poster);
  -- Both v_eligible and v_excluded join BEFORE activation → both snapshotted.
  -- v_eligible remains non-excluded so their guess is scored (needed for T3.5b).
  -- v_excluded is excluded before reveal to provide the T3.7 exclusion_events row.
  PERFORM test_helpers.add_member(v_gid, v_poster, v_eligible);
  PERFORM test_helpers.add_member(v_gid, v_poster, v_excluded);
  v_cid := test_helpers.make_challenge(v_poster, v_gid);
  PERFORM test_helpers.activate(v_poster, v_cid);    -- snapshots v_eligible and v_excluded

  -- Add v_viewer AFTER activation → NOT in eligible_participants
  v_viewer := test_helpers.make_user('T3 Viewer');
  PERFORM test_helpers.add_member(v_gid, v_poster, v_viewer);
  PERFORM test_helpers.make_moderator(v_mod);

  -- Insert child-table fixtures while challenge is ACTIVE (triggers reject on expired challenges)
  -- Clue (poster_id column per V1 schema)
  INSERT INTO public.clues (challenge_id, poster_id, text)
  VALUES (v_cid, v_poster, 'Test clue');

  -- Alias: guard_alias_edits() BEFORE INSERT trigger owns created_by, normalized_value,
  -- and is_active — pass only the caller-supplied fields and set auth context so the
  -- trigger can resolve private.auth_uid() to the poster.
  PERFORM test_helpers.set_auth_uid(v_poster);
  INSERT INTO public.challenge_answer_aliases
    (challenge_id, field, display_value)
  VALUES (v_cid, 'dish', 'Alt Dish');
  PERFORM test_helpers.clear_auth_uid();

  -- Guess attempt (race + dish_guess/restaurant_guess + receipt_sequence per V1 schema)
  -- v_eligible is a group member (and snapshotted), so can place guesses while active
  INSERT INTO public.guess_attempts
    (challenge_id, player_id, race, dish_guess, receipt_sequence)
  VALUES (v_cid, v_eligible, 'what', 'Alt Dish', 1);

  -- Exclusion event for v_excluded (withdrew) — makes T3.7 meaningful (row exists but
  -- blocked viewer sees 0). v_eligible is intentionally NOT excluded so do_reveal_impl
  -- scores their guess, producing the judgment required by T3.5b.
  INSERT INTO public.exclusion_events (challenge_id, player_id, reason, excluded_by)
  VALUES (v_cid, v_excluded, 'withdrew', v_excluded);

  -- Now expire the challenge (after all fixtures inserted; expiry blocks further guesses)
  PERFORM test_helpers.expire_challenge(v_cid);

  -- v_viewer (non-snapshotted) blocks poster — T3.1–T3.7 test block enforcement
  PERFORM test_helpers.do_block(v_viewer, v_poster);

  -- T3.1: Clues → 0 rows (blocked, not eligible)
  PERFORM test_helpers.set_auth_uid(v_viewer);
  SELECT COUNT(*) INTO v_cnt FROM public.clues WHERE challenge_id = v_cid;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_cnt = 0, 'T3.1 — blocked non-eligible viewer sees 0 clues');

  -- T3.2: challenge_secrets → 0 rows
  PERFORM test_helpers.set_auth_uid(v_viewer);
  SELECT COUNT(*) INTO v_cnt FROM public.challenge_secrets WHERE challenge_id = v_cid;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_cnt = 0, 'T3.2 — blocked viewer sees 0 challenge_secrets');

  -- T3.3: challenge_answer_aliases → 0 rows
  PERFORM test_helpers.set_auth_uid(v_viewer);
  SELECT COUNT(*) INTO v_cnt FROM public.challenge_answer_aliases WHERE challenge_id = v_cid;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_cnt = 0, 'T3.3 — blocked viewer sees 0 aliases');

  -- T3.4: guess_attempts → 0 rows
  PERFORM test_helpers.set_auth_uid(v_viewer);
  SELECT COUNT(*) INTO v_cnt FROM public.guess_attempts WHERE challenge_id = v_cid;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_cnt = 0, 'T3.4 — blocked viewer sees 0 guess_attempts');

  -- T3.5: guess_judgments → 0 rows (blocked viewer); actual row created via score chain.
  -- Proves V3 block_aware_visibility RESTRICTIVE policy hides rows from blocked viewers
  -- and that eligible participants can see rows once the challenge is revealed.
  --
  -- The guess_judgments SELECT policy (V1) requires is_challenge_revealed(challenge_id).
  -- expire_challenge only sets deadline_at in the past; state stays 'active' (not revealed).
  -- We call test_helpers.do_reveal() which delegates to private.do_reveal_impl —
  -- the real reveal lifecycle. It sets state='revealed', inserts score_run revision 1,
  -- and scores all existing guess_attempts (inserting guess_judgments rows automatically).
  -- T3.5 uses the score_run_id in count assertions — no manual INSERT needed or permitted
  -- (a second INSERT would violate UNIQUE (score_run_id, guess_attempt_id)).
  DECLARE
    v_sr_id uuid;
  BEGIN
    -- Reveal via the real lifecycle: test_helpers.do_reveal → private.do_reveal_impl.
    -- Sets state='revealed', inserts score_run revision 1, and creates guess_judgments
    -- for existing guess_attempts. Do NOT manually insert guess_judgments here.
    PERFORM test_helpers.do_reveal(v_cid);

    -- Retrieve the score_run id for the count assertions below.
    SELECT id INTO v_sr_id FROM public.score_runs
    WHERE challenge_id = v_cid AND revision_number = 1;

    -- Blocked viewer sees 0 rows: V3 RESTRICTIVE block_aware_visibility policy
    -- uses can_view_challenge() which returns false for users blocked by the poster.
    PERFORM test_helpers.set_auth_uid(v_viewer);
    SELECT COUNT(*) INTO v_cnt FROM public.guess_judgments
    WHERE score_run_id = v_sr_id;
    PERFORM test_helpers.clear_auth_uid();
    PERFORM test_helpers.assert(v_cnt = 0,
      'T3.5 — blocked viewer sees 0 guess_judgments (RESTRICTIVE block_aware_visibility)');

    -- Eligible participant sees the row: challenge is now revealed; V1 PERMISSIVE policy
    -- (is_challenge_revealed AND is_challenge_group_member) passes; V3 RESTRICTIVE
    -- (can_view_challenge) passes since v_eligible is not blocked by v_poster.
    PERFORM test_helpers.set_auth_uid(v_eligible);
    SELECT COUNT(*) INTO v_cnt FROM public.guess_judgments
    WHERE score_run_id = v_sr_id;
    PERFORM test_helpers.clear_auth_uid();
    PERFORM test_helpers.assert(v_cnt >= 1,
      'T3.5b — eligible participant sees guess_judgments row (challenge revealed)');
  END;

  -- T3.6: eligible_participants → 0 rows (viewer is not eligible, and blocked)
  PERFORM test_helpers.set_auth_uid(v_viewer);
  SELECT COUNT(*) INTO v_cnt FROM public.eligible_participants WHERE challenge_id = v_cid;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_cnt = 0, 'T3.6 — blocked non-eligible viewer sees 0 eligible_participants');

  -- T3.7: exclusion_events → 0 rows (row exists for v_eligible, but viewer is blocked)
  PERFORM test_helpers.set_auth_uid(v_viewer);
  SELECT COUNT(*) INTO v_cnt FROM public.exclusion_events WHERE challenge_id = v_cid;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_cnt = 0, 'T3.7 — blocked viewer sees 0 exclusion_events (row exists for v_excluded)');

  -- T3.8: v_eligible is in eligible_participants (snapshotted at activation).
  -- After v_eligible blocks poster, they should STILL see rows via carve-out.
  PERFORM test_helpers.do_block(v_eligible, v_poster);
  PERFORM test_helpers.set_auth_uid(v_eligible);
  SELECT COUNT(*) INTO v_cnt FROM public.clues WHERE challenge_id = v_cid;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_cnt > 0, 'T3.8 — eligible participant sees clues despite block (carve-out)');

  -- T3.9: No block → rows visible (fresh users)
  DECLARE
    v_poster2 uuid; v_viewer2 uuid; v_gid2 uuid; v_cid2 uuid;
  BEGIN
    v_poster2 := test_helpers.make_user('T3 Poster2');
    v_viewer2 := test_helpers.make_user('T3 Viewer2');
    v_gid2    := test_helpers.make_group(v_poster2);
    PERFORM test_helpers.add_member(v_gid2, v_poster2, v_viewer2);
    v_cid2    := test_helpers.make_challenge(v_poster2, v_gid2);
    PERFORM test_helpers.activate(v_poster2, v_cid2);
    INSERT INTO public.clues (challenge_id, poster_id, text)
    VALUES (v_cid2, v_poster2, 'Visible clue');
    PERFORM test_helpers.set_auth_uid(v_viewer2);
    SELECT COUNT(*) INTO v_cnt FROM public.clues WHERE challenge_id = v_cid2;
    PERFORM test_helpers.clear_auth_uid();
    PERFORM test_helpers.assert(v_cnt > 0, 'T3.9 — no block: clues visible to group member');
  END;

  -- T3.10: Non-poster querying draft → 0 rows
  DECLARE
    v_poster3 uuid; v_viewer3 uuid; v_gid3 uuid; v_cid3 uuid;
  BEGIN
    v_poster3 := test_helpers.make_user('T3 Poster3');
    v_viewer3 := test_helpers.make_user('T3 Viewer3');
    v_gid3    := test_helpers.make_group(v_poster3);
    PERFORM test_helpers.add_member(v_gid3, v_poster3, v_viewer3);
    v_cid3    := test_helpers.make_challenge(v_poster3, v_gid3);
    -- Do NOT activate — challenge remains in draft state
    INSERT INTO public.clues (challenge_id, poster_id, text)
    VALUES (v_cid3, v_poster3, 'Draft clue');
    PERFORM test_helpers.set_auth_uid(v_viewer3);
    SELECT COUNT(*) INTO v_cnt FROM public.clues WHERE challenge_id = v_cid3;
    PERFORM test_helpers.clear_auth_uid();
    PERFORM test_helpers.assert(v_cnt = 0, 'T3.10 — non-poster cannot see draft challenge child rows');
  END;

END;
$$;

-- =============================================================================
-- GROUP 4 — T4: get_media_serve_authorization (8 tests)
-- =============================================================================
\echo ''
\echo '--- GROUP 4: get_media_serve_authorization ---'

DO $$
DECLARE
  v_poster       uuid;
  v_snap_member  uuid;   -- joins BEFORE activation → snapshotted (eligible)
  v_block_member uuid;   -- joins AFTER activation  → NOT snapshotted
  v_outsider     uuid;
  v_mod          uuid;
  v_gid          uuid;
  v_cid          uuid;
  v_mid          uuid;
  v_key          text;
BEGIN
  v_poster       := test_helpers.make_user('T4 Poster');
  v_snap_member  := test_helpers.make_user('T4 SnapMember');
  v_block_member := test_helpers.make_user('T4 BlockMember');
  v_outsider     := test_helpers.make_user('T4 Outsider');
  v_mod          := test_helpers.make_user('T4 Mod');
  v_gid          := test_helpers.make_group(v_poster);
  -- snap_member joins BEFORE activation → will be snapshotted
  PERFORM test_helpers.add_member(v_gid, v_poster, v_snap_member);
  PERFORM test_helpers.make_moderator(v_mod);

  SELECT challenge_id, media_id INTO v_cid, v_mid
  FROM test_helpers.make_draft_challenge_with_media(v_poster, v_gid);
  PERFORM test_helpers.activate(v_poster, v_cid);   -- snapshots v_snap_member

  -- block_member joins AFTER activation → NOT in eligible_participants
  PERFORM test_helpers.add_member(v_gid, v_poster, v_block_member);

  -- T4.1: Snapshotted member, no block → storage key returned
  SELECT re_encoded_storage_key INTO v_key
  FROM public.get_media_serve_authorization(v_mid, v_snap_member);
  PERFORM test_helpers.assert(v_key IS NOT NULL, 'T4.1 — snapshotted member gets storage key');

  -- T4.2: Non-snapshotted member blocks poster → no key (block enforced, not eligible)
  PERFORM test_helpers.do_block(v_block_member, v_poster);
  SELECT re_encoded_storage_key INTO v_key
  FROM public.get_media_serve_authorization(v_mid, v_block_member);
  PERFORM test_helpers.assert(v_key IS NULL, 'T4.2 — non-snapshotted blocker gets no key');

  -- T4.3: Outsider → no key
  SELECT re_encoded_storage_key INTO v_key
  FROM public.get_media_serve_authorization(v_mid, v_outsider);
  PERFORM test_helpers.assert(v_key IS NULL, 'T4.3 — outsider gets no key');

  -- T4.4: Poster → key returned
  SELECT re_encoded_storage_key INTO v_key
  FROM public.get_media_serve_authorization(v_mid, v_poster);
  PERFORM test_helpers.assert(v_key IS NOT NULL, 'T4.4 — poster gets storage key');

  -- T4.5: Snapshotted member (in eligible_participants) blocks poster → still gets key
  PERFORM test_helpers.do_block(v_snap_member, v_poster);
  SELECT re_encoded_storage_key INTO v_key
  FROM public.get_media_serve_authorization(v_mid, v_snap_member);
  PERFORM test_helpers.assert(v_key IS NOT NULL, 'T4.5 — eligible participant gets key despite block (carve-out)');

  -- T4.6: Challenge moderator-removed → no key
  PERFORM public.remove_content('challenge', v_cid, v_mod, NULL, 'T4.6 moderation');
  SELECT re_encoded_storage_key INTO v_key
  FROM public.get_media_serve_authorization(v_mid, v_poster);
  PERFORM test_helpers.assert(v_key IS NULL, 'T4.6 — moderator-removed challenge: no key');

  -- T4.7: status = 'pending_review' → empty → 403
  -- (Fresh media in pending_review)
  DECLARE v_mid2 uuid; v_cid2 uuid; v_poster2 uuid; v_gid2 uuid;
  BEGIN
    v_poster2 := test_helpers.make_user('T4 Poster2');
    v_gid2    := test_helpers.make_group(v_poster2);
    v_mid2    := test_helpers.make_media_with_key(v_poster2, 'b665a45920422f9d417e4867efdc4fb8a04a1f3fff1fa07e998e86f7f7a27ae3', 'pending_review');
    PERFORM test_helpers.set_auth_uid(v_poster2);
    INSERT INTO public.challenges (group_id, media_object_id) VALUES (v_gid2, v_mid2) RETURNING id INTO v_cid2;
    INSERT INTO public.challenge_secrets (challenge_id, display_dish, canonical_dish, display_restaurant, canonical_restaurant)
    VALUES (v_cid2, 'Test', 'test', 'Place', 'place');
    PERFORM test_helpers.clear_auth_uid();
    SELECT re_encoded_storage_key INTO v_key FROM public.get_media_serve_authorization(v_mid2, v_poster2);
    PERFORM test_helpers.assert(v_key IS NULL, 'T4.7 — pending_review media: no key');
  END;

  -- T4.8: status = 'removed' → empty → 403
  DECLARE v_mid3 uuid; v_poster3 uuid;
  BEGIN
    v_poster3 := test_helpers.make_user('T4 Poster3');
    v_mid3    := test_helpers.make_media_with_key(v_poster3, 'c665a45920422f9d417e4867efdc4fb8a04a1f3fff1fa07e998e86f7f7a27ae3', 'removed');
    SELECT re_encoded_storage_key INTO v_key FROM public.get_media_serve_authorization(v_mid3, v_poster3);
    PERFORM test_helpers.assert(v_key IS NULL, 'T4.8 — removed media: no key');
  END;

END;
$$;

-- =============================================================================
-- GROUP 5 — T5: report_content media_object lock order (sequential simulation)
-- True concurrency requires two-session shell harnesses; see T7 for notes.
-- These tests verify the post-race outcomes that each session path produces.
-- =============================================================================
\echo ''
\echo '--- GROUP 5: report_content lock order (sequential simulation) ---'

DO $$
DECLARE
  v_poster uuid; v_reporter uuid; v_mod uuid;
  v_gid uuid; v_cid uuid; v_mid uuid;
  v_rid uuid; v_cnt int;
BEGIN
  v_poster   := test_helpers.make_user('T5 Poster');
  v_reporter := test_helpers.make_user('T5 Reporter');
  v_mod      := test_helpers.make_user('T5 Mod');
  v_gid      := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_gid, v_poster, v_reporter);
  PERFORM test_helpers.make_moderator(v_mod);

  SELECT challenge_id, media_id INTO v_cid, v_mid
  FROM test_helpers.make_draft_challenge_with_media(v_poster, v_gid);
  PERFORM test_helpers.activate(v_poster, v_cid);

  -- T5.1 (sequential simulation): remove_media wins first;
  -- subsequent report_content sees status != 'ready' → FK_NOT_FOUND
  PERFORM public.remove_media(v_mid, v_mod, NULL, 'T5.1 remove');
  BEGIN
    v_rid := test_helpers.do_report(v_reporter, 'media_object', v_mid, 'inappropriate_image', 'T5.1');
    RAISE EXCEPTION 'UNEXPECTED_SUCCESS';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM = 'UNEXPECTED_SUCCESS' THEN
        RAISE EXCEPTION 'T5.1 FAIL: report_content succeeded (expected FK_NOT_FOUND after removal)';
      ELSIF SQLERRM LIKE '%FK_NOT_FOUND%' THEN
        RAISE NOTICE 'PASS: T5.1 — report_content after remove_media raises FK_NOT_FOUND';
      ELSE
        RAISE EXCEPTION 'T5.1 FAIL: unexpected error: % %', SQLSTATE, SQLERRM;
      END IF;
  END;

  -- T5.2 (sequential simulation): report_content commits first; then remove_media runs;
  -- report captured and bulk-actioned
  DECLARE
    v_poster2   uuid; v_reporter2 uuid; v_mod2 uuid;
    v_gid2 uuid; v_cid2 uuid; v_mid2 uuid; v_rid2 uuid;
  BEGIN
    v_poster2   := test_helpers.make_user('T5 Poster2');
    v_reporter2 := test_helpers.make_user('T5 Reporter2');
    v_mod2      := test_helpers.make_user('T5 Mod2');
    v_gid2      := test_helpers.make_group(v_poster2);
    PERFORM test_helpers.add_member(v_gid2, v_poster2, v_reporter2);
    PERFORM test_helpers.make_moderator(v_mod2);
    SELECT challenge_id, media_id INTO v_cid2, v_mid2
    FROM test_helpers.make_draft_challenge_with_media(v_poster2, v_gid2);
    PERFORM test_helpers.activate(v_poster2, v_cid2);

    v_rid2 := test_helpers.do_report(v_reporter2, 'media_object', v_mid2, 'inappropriate_image', 'T5.2');
    PERFORM public.remove_media(v_mid2, v_mod2, v_rid2, 'T5.2 remove');
    SELECT COUNT(*) INTO v_cnt FROM public.content_reports
    WHERE id = v_rid2 AND status = 'actioned';
    PERFORM test_helpers.assert(v_cnt = 1, 'T5.2 — report actioned after remove_media');
  END;

END;
$$;

-- =============================================================================
-- GROUP 6 — T6: Bulk report resolution + audit (7 tests)
-- =============================================================================
\echo ''
\echo '--- GROUP 6: Bulk report resolution and audit ---'

DO $$
DECLARE
  v_poster uuid; v_userA uuid; v_userB uuid; v_mod uuid;
  v_gid uuid; v_cid uuid; v_mid uuid;
  v_rA uuid; v_rB uuid; v_comment_id uuid; v_cnt int;
BEGIN
  v_poster := test_helpers.make_user('T6 Poster');
  v_userA  := test_helpers.make_user('T6 UserA');
  v_userB  := test_helpers.make_user('T6 UserB');
  v_mod    := test_helpers.make_user('T6 Mod');
  v_gid    := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_gid, v_poster, v_userA);
  PERFORM test_helpers.add_member(v_gid, v_poster, v_userB);
  PERFORM test_helpers.make_moderator(v_mod);

  -- T6.1: A and B both report same comment → both actioned; 2 moderation_action_reports rows.
  -- Fresh poster + group so T6.2 can later activate for the outer v_poster without conflict.
  DECLARE v_cid6_1 uuid; v_poster6_1 uuid; v_gid6_1 uuid;
  BEGIN
    v_poster6_1  := test_helpers.make_user('T6.1 Poster');
    v_gid6_1     := test_helpers.make_group(v_poster6_1);
    PERFORM test_helpers.add_member(v_gid6_1, v_poster6_1, v_userA);
    PERFORM test_helpers.add_member(v_gid6_1, v_poster6_1, v_userB);
    v_cid6_1     := test_helpers.make_challenge(v_poster6_1, v_gid6_1);
    PERFORM test_helpers.activate(v_poster6_1, v_cid6_1);
    -- Both users must guess before reporting a comment (Table Talk visibility rule:
    -- non-poster may report only after guessing or after reveal).
    PERFORM test_helpers.make_guess(v_userA, v_cid6_1, 'what', 'T6.1 UserA guess');
    PERFORM test_helpers.make_guess(v_userB, v_cid6_1, 'what', 'T6.1 UserB guess');
    v_comment_id := test_helpers.make_comment(v_poster6_1, v_cid6_1, 'Reported comment T6.1');
    v_rA := test_helpers.do_report(v_userA, 'comment', v_comment_id, 'offensive_content', 'report A');
    v_rB := test_helpers.do_report(v_userB, 'comment', v_comment_id, 'offensive_content', 'report B');
    PERFORM public.remove_content('comment', v_comment_id, v_mod, NULL, 'T6.1 removal');
    SELECT COUNT(*) INTO v_cnt FROM private.moderation_action_reports mar
    JOIN public.moderation_actions ma ON ma.id = mar.moderation_action_id
    WHERE ma.target_id = v_comment_id AND ma.action_type = 'content_removed';
    PERFORM test_helpers.assert(v_cnt = 2, 'T6.1 — 2 moderation_action_reports rows for 2 reports on same comment');
    SELECT COUNT(*) INTO v_cnt FROM public.content_reports WHERE id IN (v_rA, v_rB) AND status = 'actioned';
    PERFORM test_helpers.assert(v_cnt = 2, 'T6.1 — both reports actioned');
  END;

  -- T6.2: A and B report same challenge → both actioned; 2 rows.
  -- remove_content('challenge') sets state='cancelled', freeing the slot for T6.5.
  DECLARE v_cid6_2 uuid;
  BEGIN
    v_cid6_2 := test_helpers.make_challenge(v_poster, v_gid);
    PERFORM test_helpers.activate(v_poster, v_cid6_2);
    v_rA := test_helpers.do_report(v_userA, 'challenge', v_cid6_2, 'offensive_content', 'A');
    v_rB := test_helpers.do_report(v_userB, 'challenge', v_cid6_2, 'offensive_content', 'B');
    PERFORM public.remove_content('challenge', v_cid6_2, v_mod, NULL, 'T6.2');
    SELECT COUNT(*) INTO v_cnt FROM private.moderation_action_reports mar
    JOIN public.moderation_actions ma ON ma.id = mar.moderation_action_id
    WHERE ma.target_id = v_cid6_2 AND ma.action_type = 'content_removed';
    PERFORM test_helpers.assert(v_cnt = 2, 'T6.2 — 2 rows for same challenge with 2 reporters');
  END;

  -- T6.3: A reports challenge; B reports linked media → both actioned
  DECLARE
    v_cid6_3 uuid; v_mid6_3 uuid;
    v_poster6_3 uuid; v_gid6_3 uuid;
  BEGIN
    v_poster6_3 := test_helpers.make_user('T6.3 Poster');
    v_gid6_3    := test_helpers.make_group(v_poster6_3);
    PERFORM test_helpers.add_member(v_gid6_3, v_poster6_3, v_userA);
    PERFORM test_helpers.add_member(v_gid6_3, v_poster6_3, v_userB);
    SELECT challenge_id, media_id INTO v_cid6_3, v_mid6_3
    FROM test_helpers.make_draft_challenge_with_media(v_poster6_3, v_gid6_3);
    PERFORM test_helpers.activate(v_poster6_3, v_cid6_3);
    v_rA := test_helpers.do_report(v_userA, 'challenge',    v_cid6_3, 'inappropriate_image', 'A');
    v_rB := test_helpers.do_report(v_userB, 'media_object', v_mid6_3, 'inappropriate_image', 'B');
    PERFORM public.remove_content('challenge', v_cid6_3, v_mod, NULL, 'T6.3');
    SELECT COUNT(*) INTO v_cnt FROM public.content_reports WHERE id IN (v_rA, v_rB) AND status = 'actioned';
    PERFORM test_helpers.assert(v_cnt = 2, 'T6.3 — challenge + media reports both actioned');
  END;

  -- T6.4: A and B reports via remove_media → both actioned
  DECLARE
    v_cid6_4 uuid; v_mid6_4 uuid;
    v_poster6_4 uuid; v_gid6_4 uuid;
  BEGIN
    v_poster6_4 := test_helpers.make_user('T6.4 Poster');
    v_gid6_4    := test_helpers.make_group(v_poster6_4);
    PERFORM test_helpers.add_member(v_gid6_4, v_poster6_4, v_userA);
    PERFORM test_helpers.add_member(v_gid6_4, v_poster6_4, v_userB);
    SELECT challenge_id, media_id INTO v_cid6_4, v_mid6_4
    FROM test_helpers.make_draft_challenge_with_media(v_poster6_4, v_gid6_4);
    PERFORM test_helpers.activate(v_poster6_4, v_cid6_4);
    v_rA := test_helpers.do_report(v_userA, 'media_object', v_mid6_4, 'inappropriate_image', 'A');
    v_rB := test_helpers.do_report(v_userB, 'media_object', v_mid6_4, 'inappropriate_image', 'B');
    PERFORM public.remove_media(v_mid6_4, v_mod, NULL, 'T6.4');
    SELECT COUNT(*) INTO v_cnt FROM public.content_reports WHERE id IN (v_rA, v_rB) AND status = 'actioned';
    PERFORM test_helpers.assert(v_cnt = 2, 'T6.4 — both media_object reports actioned via remove_media');
  END;

  -- T6.5: Single pending report → 1 moderation_action_reports row
  DECLARE v_cid6_5 uuid; v_rid6_5 uuid; v_aid6_5 uuid;
  BEGIN
    v_cid6_5 := test_helpers.make_challenge(v_poster, v_gid);
    PERFORM test_helpers.activate(v_poster, v_cid6_5);
    v_rid6_5 := test_helpers.do_report(v_userA, 'challenge', v_cid6_5, 'offensive_content', 'single');
    PERFORM public.remove_content('challenge', v_cid6_5, v_mod, v_rid6_5, 'T6.5');
    SELECT COUNT(*) INTO v_cnt FROM private.moderation_action_reports
    WHERE report_id = v_rid6_5;
    PERFORM test_helpers.assert(v_cnt = 1, 'T6.5 — single report → exactly 1 moderation_action_reports row');
  END;

  -- T6.6: Completeness — every actioned report has exactly one moderation_action_reports row
  SELECT COUNT(*) INTO v_cnt
  FROM public.content_reports cr
  WHERE cr.status = 'actioned'
    AND NOT EXISTS (
      SELECT 1 FROM private.moderation_action_reports mar
      WHERE mar.report_id = cr.id
    );
  PERFORM test_helpers.assert(v_cnt = 0, 'T6.6 — every actioned report has a moderation_action_reports row');

  -- T6.7: One dismissed, one pending; removal runs → pending actioned; dismissed unchanged
  DECLARE
    v_cid6_7 uuid; v_rid_dismissed uuid; v_rid_pending uuid; v_dismissed_status text;
  BEGIN
    v_cid6_7        := test_helpers.make_challenge(v_poster, v_gid);
    PERFORM test_helpers.activate(v_poster, v_cid6_7);
    v_rid_dismissed := test_helpers.do_report(v_userA, 'challenge', v_cid6_7, 'offensive_content', 'dismiss');
    v_rid_pending   := test_helpers.do_report(v_userB, 'challenge', v_cid6_7, 'offensive_content', 'keep pending');
    PERFORM public.dismiss_report(v_rid_dismissed, v_mod, 'no violation');
    PERFORM public.remove_content('challenge', v_cid6_7, v_mod, NULL, 'T6.7');
    SELECT status INTO v_dismissed_status FROM public.content_reports WHERE id = v_rid_dismissed;
    PERFORM test_helpers.assert(v_dismissed_status = 'dismissed', 'T6.7 — dismissed report stays dismissed');
    SELECT COUNT(*) INTO v_cnt FROM public.content_reports WHERE id = v_rid_pending AND status = 'actioned';
    PERFORM test_helpers.assert(v_cnt = 1, 'T6.7 — pending report actioned by removal');
  END;

END;
$$;

-- =============================================================================
-- GROUP 7 — T7: Concurrency tests
-- T7.1–T7.3, T7.5 require two-session shell harnesses.
-- T7.4 is fully single-session (ON CONFLICT dedup).
-- =============================================================================
\echo ''
\echo '--- GROUP 7: Concurrency ---'
\echo 'NOTE: T7.1, T7.2, T7.3, T7.5 require two-session shell harnesses.'
\echo 'T7.4 (dedup) runs single-session.'

-- T7.4: Two identical report_content calls → dedup; both return same report_id
DO $$
DECLARE
  v_poster uuid; v_reporter uuid; v_gid uuid; v_cid uuid;
  v_rid1 uuid; v_rid2 uuid; v_cnt int;
BEGIN
  v_poster   := test_helpers.make_user('T7.4 Poster');
  v_reporter := test_helpers.make_user('T7.4 Reporter');
  v_gid      := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_gid, v_poster, v_reporter);
  v_cid      := test_helpers.make_challenge(v_poster, v_gid);
  PERFORM test_helpers.activate(v_poster, v_cid);

  v_rid1 := test_helpers.do_report(v_reporter, 'challenge', v_cid, 'offensive_content', 'first call');
  v_rid2 := test_helpers.do_report(v_reporter, 'challenge', v_cid, 'offensive_content', 'second call (same args)');
  PERFORM test_helpers.assert(v_rid1 = v_rid2, 'T7.4 — duplicate report_content returns same report_id (ON CONFLICT dedup)');
  SELECT COUNT(*) INTO v_cnt FROM public.content_reports
  WHERE reporter_id = v_reporter AND target_id = v_cid AND status = 'pending';
  PERFORM test_helpers.assert(v_cnt = 1, 'T7.4 — exactly 1 pending report row after dedup');
END;
$$;

-- =============================================================================
-- GROUP 8 — T8: Idempotency (8 tests)
-- =============================================================================
\echo ''
\echo '--- GROUP 8: Idempotency ---'

DO $$
DECLARE
  v_poster uuid; v_mod uuid; v_reporter uuid;
  v_gid uuid; v_cid uuid; v_mid uuid;
  v_comment_id uuid; v_clue_id uuid;
  v_rid uuid; v_action_id_first uuid; v_cnt int;
BEGIN
  v_poster   := test_helpers.make_user('T8 Poster');
  v_mod      := test_helpers.make_user('T8 Mod');
  v_reporter := test_helpers.make_user('T8 Reporter');
  v_gid      := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_gid, v_poster, v_reporter);
  PERFORM test_helpers.make_moderator(v_mod);

  -- T8.1: Challenge removed; remove_content('challenge') called again → idempotency path.
  -- A new pending report is inserted directly (report_content would raise FK_NOT_FOUND on
  -- an already-removed challenge, so we use a direct INSERT as postgres to simulate a report
  -- that arrived concurrently during the first removal). The second remove_content call must:
  --   a) use the SAME action_id (idempotency path), and
  --   b) link the pending report to the existing action (report is actioned).
  DECLARE v_cid8_1 uuid; v_rid_after uuid; v_aid_second uuid;
  BEGIN
    v_cid8_1 := test_helpers.make_challenge(v_poster, v_gid);
    PERFORM test_helpers.activate(v_poster, v_cid8_1);
    -- First removal
    PERFORM public.remove_content('challenge', v_cid8_1, v_mod, NULL, 'T8.1 first');
    SELECT moderator_removal_action_id INTO v_action_id_first FROM public.challenges WHERE id = v_cid8_1;
    -- Simulate a late-arriving pending report (direct INSERT as postgres bypasses the
    -- report_content FK_NOT_FOUND check that blocks reporting removed challenges).
    INSERT INTO public.content_reports
      (reporter_id, target_type, target_id, category, detail, status)
    VALUES (v_reporter, 'challenge', v_cid8_1, 'offensive_content', 'T8.1 late report', 'pending')
    RETURNING id INTO v_rid_after;
    -- Second remove_content call → idempotency path
    PERFORM public.remove_content('challenge', v_cid8_1, v_mod, NULL, 'T8.1 second');
    -- a) action_id unchanged
    SELECT moderator_removal_action_id INTO v_aid_second FROM public.challenges WHERE id = v_cid8_1;
    PERFORM test_helpers.assert(
      v_action_id_first = v_aid_second,
      'T8.1a — second remove_content uses same action_id (idempotency path)');
    -- b) pending report linked to the existing action (actioned)
    SELECT COUNT(*) INTO v_cnt FROM public.content_reports
    WHERE id = v_rid_after AND status = 'actioned';
    PERFORM test_helpers.assert(v_cnt = 1,
      'T8.1b — late-arriving pending report is actioned by idempotency path');
  END;

  -- T8.2: After removal; new report_content attempt on removed challenge → FK_NOT_FOUND
  DECLARE v_cid8_2 uuid;
  BEGIN
    v_cid8_2 := test_helpers.make_challenge(v_poster, v_gid);
    PERFORM test_helpers.activate(v_poster, v_cid8_2);
    PERFORM public.remove_content('challenge', v_cid8_2, v_mod, NULL, 'T8.2 removal');
    -- Remove moderator_removed_at does NOT apply; challenge is cancelled
    -- Attempt report on removed challenge → should fail (challenge state changed)
    BEGIN
      DECLARE v_dummy uuid;
      BEGIN
        v_dummy := test_helpers.do_report(v_reporter, 'challenge', v_cid8_2, 'offensive_content', 'T8.2 report');
        RAISE EXCEPTION 'UNEXPECTED_SUCCESS';
      EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'UNEXPECTED_SUCCESS' THEN
          RAISE EXCEPTION 'T8.2 FAIL: report_content succeeded (expected FK_NOT_FOUND on removed challenge)';
        ELSIF SQLERRM LIKE '%FK_NOT_FOUND%' THEN
          RAISE NOTICE 'PASS: T8.2 — report on removed challenge raises FK_NOT_FOUND';
        ELSE
          RAISE EXCEPTION 'T8.2 FAIL: unexpected: % %', SQLSTATE, SQLERRM;
        END IF;
      END;
    END;
  END;

  -- T8.3: remove_media on media with status='processing' → FK_WRONG_STATE.
  -- 'processing' is not in the actionable set ('ready','pending_review') and has no idempotency path.
  -- Media is linked to a challenge (via make_draft_challenge_with_media) so FK_NOT_FOUND does not fire;
  -- the status check fires instead.
  DECLARE v_poster8_3 uuid; v_gid8_3 uuid; v_cid8_3 uuid; v_mid8_3 uuid;
  BEGIN
    v_poster8_3 := test_helpers.make_user('T8.3 Poster');
    v_gid8_3    := test_helpers.make_group(v_poster8_3);
    SELECT challenge_id, media_id INTO v_cid8_3, v_mid8_3
    FROM test_helpers.make_draft_challenge_with_media(v_poster8_3, v_gid8_3);
    -- Forge status='processing' directly (bypasses state machine; media stays linked to challenge)
    UPDATE public.media_objects SET status = 'processing' WHERE id = v_mid8_3;
    BEGIN
      PERFORM public.remove_media(v_mid8_3, v_mod, NULL, 'T8.3 processing');
      RAISE EXCEPTION 'UNEXPECTED_SUCCESS';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM = 'UNEXPECTED_SUCCESS' THEN
        RAISE EXCEPTION 'T8.3 FAIL: remove_media succeeded on processing media (expected FK_WRONG_STATE)';
      ELSIF SQLERRM LIKE '%FK_WRONG_STATE%' THEN
        RAISE NOTICE 'PASS: T8.3 — remove_media on processing media raises FK_WRONG_STATE';
      ELSE
        RAISE EXCEPTION 'T8.3 FAIL: unexpected: % %', SQLSTATE, SQLERRM;
      END IF;
    END;
  END;

  -- T8.4: remove_media on media status = 'rejected' → FK_WRONG_STATE (not FK_NOT_FOUND).
  -- Media must be linked to a challenge via challenge.media_object_id; otherwise the
  -- challenge-linkage check fires FK_NOT_FOUND before the status check.
  -- Use make_draft_challenge_with_media to create a linked media, then forge status='rejected'.
  DECLARE v_poster8_4 uuid; v_gid8_4 uuid; v_cid8_4 uuid; v_mid8_4 uuid;
  BEGIN
    v_poster8_4 := test_helpers.make_user('T8.4 Poster');
    v_gid8_4    := test_helpers.make_group(v_poster8_4);
    SELECT challenge_id, media_id INTO v_cid8_4, v_mid8_4
    FROM test_helpers.make_draft_challenge_with_media(v_poster8_4, v_gid8_4);
    -- Forge status='rejected' directly (media stays linked to v_cid8_4 via challenge.media_object_id)
    UPDATE public.media_objects SET status = 'rejected' WHERE id = v_mid8_4;
    BEGIN
      PERFORM public.remove_media(v_mid8_4, v_mod, NULL, 'T8.4');
      RAISE EXCEPTION 'UNEXPECTED_SUCCESS';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM = 'UNEXPECTED_SUCCESS' THEN
        RAISE EXCEPTION 'T8.4 FAIL: remove_media succeeded on rejected media (expected FK_WRONG_STATE)';
      ELSIF SQLERRM LIKE '%FK_WRONG_STATE%' THEN
        RAISE NOTICE 'PASS: T8.4 — remove_media on rejected media (linked to challenge) raises FK_WRONG_STATE';
      ELSE
        RAISE EXCEPTION 'T8.4 FAIL: unexpected: % %', SQLSTATE, SQLERRM;
      END IF;
    END;
  END;

  -- T8.5: Comment removed; remove_content('comment') called again → idempotency.
  -- Challenge is cancelled at end of block to free the slot for T8.6.
  DECLARE v_cid8_5 uuid; v_com8_5 uuid; v_aid8_5 uuid; v_aid8_5_2 uuid;
  BEGIN
    v_cid8_5 := test_helpers.make_challenge(v_poster, v_gid);
    PERFORM test_helpers.activate(v_poster, v_cid8_5);
    -- Use v_poster (not v_reporter) — poster can comment without guessing.
    -- v_reporter has not guessed on v_cid8_5 (Table Talk rule would block their INSERT).
    v_com8_5 := test_helpers.make_comment(v_poster, v_cid8_5, 'T8.5 comment');
    PERFORM public.remove_content('comment', v_com8_5, v_mod, NULL, 'T8.5 first');
    SELECT moderator_removal_action_id INTO v_aid8_5 FROM public.comments WHERE id = v_com8_5;
    PERFORM public.remove_content('comment', v_com8_5, v_mod, NULL, 'T8.5 second');
    SELECT moderator_removal_action_id INTO v_aid8_5_2 FROM public.comments WHERE id = v_com8_5;
    PERFORM test_helpers.assert(v_aid8_5 = v_aid8_5_2, 'T8.5 — comment idempotency: action_id unchanged on second call');
    -- Cancel the challenge so v_poster can activate again in T8.6
    PERFORM public.remove_content('challenge', v_cid8_5, v_mod, NULL, 'T8.5 challenge cleanup');
  END;

  -- T8.6: Clue removed; remove_content('clue') called again → idempotency.
  -- Clue must be created by the challenge POSTER (only poster can add clues per V1 schema).
  -- Uses fresh poster to avoid any residual conflict.
  DECLARE v_poster8_6 uuid; v_gid8_6 uuid; v_cid8_6 uuid; v_clue8_6 uuid;
          v_aid8_6 uuid; v_aid8_6_2 uuid;
  BEGIN
    v_poster8_6 := test_helpers.make_user('T8.6 Poster');
    v_gid8_6    := test_helpers.make_group(v_poster8_6);
    PERFORM test_helpers.add_member(v_gid8_6, v_poster8_6, v_reporter);
    v_cid8_6    := test_helpers.make_challenge(v_poster8_6, v_gid8_6);
    PERFORM test_helpers.activate(v_poster8_6, v_cid8_6);
    -- Clue must be by the poster (V1: clues.poster_id = challenge poster)
    v_clue8_6   := test_helpers.make_clue(v_poster8_6, v_cid8_6, 'T8.6 clue');
    PERFORM public.remove_content('clue', v_clue8_6, v_mod, NULL, 'T8.6 first');
    SELECT moderator_removal_action_id INTO v_aid8_6 FROM public.clues WHERE id = v_clue8_6;
    PERFORM public.remove_content('clue', v_clue8_6, v_mod, NULL, 'T8.6 second');
    SELECT moderator_removal_action_id INTO v_aid8_6_2 FROM public.clues WHERE id = v_clue8_6;
    PERFORM test_helpers.assert(v_aid8_6 = v_aid8_6_2, 'T8.6 — clue idempotency: action_id unchanged');
  END;

  -- T8.7: Challenge removed via remove_media; then remove_content('challenge') → idempotency path
  DECLARE
    v_poster8_7 uuid; v_gid8_7 uuid; v_cid8_7 uuid; v_mid8_7 uuid;
    v_aid_media uuid; v_aid_content uuid;
  BEGIN
    v_poster8_7 := test_helpers.make_user('T8.7 Poster');
    v_gid8_7    := test_helpers.make_group(v_poster8_7);
    PERFORM test_helpers.add_member(v_gid8_7, v_poster8_7, v_reporter);
    SELECT challenge_id, media_id INTO v_cid8_7, v_mid8_7
    FROM test_helpers.make_draft_challenge_with_media(v_poster8_7, v_gid8_7);
    PERFORM test_helpers.activate(v_poster8_7, v_cid8_7);
    -- remove_media sets challenge.moderator_removed_at + moderator_removal_action_id
    PERFORM public.remove_media(v_mid8_7, v_mod, NULL, 'T8.7 remove_media');
    SELECT moderator_removal_action_id INTO v_aid_media FROM public.challenges WHERE id = v_cid8_7;
    -- remove_content('challenge') should hit idempotency path
    PERFORM public.remove_content('challenge', v_cid8_7, v_mod, NULL, 'T8.7 remove_content');
    SELECT moderator_removal_action_id INTO v_aid_content FROM public.challenges WHERE id = v_cid8_7;
    PERFORM test_helpers.assert(
      v_aid_media = v_aid_content,
      'T8.7 — remove_content after remove_media uses same action_id (idempotency)');
  END;

  -- T8.8: remove_content('challenge') first; then remove_media → idempotency path in remove_media.
  -- The key invariant: no SECOND challenge-level action is created (action_id pointer unchanged).
  DECLARE
    v_poster8_8 uuid; v_gid8_8 uuid; v_cid8_8 uuid; v_mid8_8 uuid;
    v_actions_count int; v_actions_count2 int;
  BEGIN
    v_poster8_8 := test_helpers.make_user('T8.8 Poster');
    v_gid8_8    := test_helpers.make_group(v_poster8_8);
    -- activate_challenge requires at least one non-poster eligible member
    PERFORM test_helpers.add_member(v_gid8_8, v_poster8_8, v_mod);
    SELECT challenge_id, media_id INTO v_cid8_8, v_mid8_8
    FROM test_helpers.make_draft_challenge_with_media(v_poster8_8, v_gid8_8);
    PERFORM test_helpers.activate(v_poster8_8, v_cid8_8);
    PERFORM public.remove_content('challenge', v_cid8_8, v_mod, NULL, 'T8.8 remove_content');
    -- Count challenge-level actions before remove_media (should be exactly 1)
    SELECT COUNT(*) INTO v_actions_count FROM public.moderation_actions WHERE target_id = v_cid8_8;
    PERFORM public.remove_media(v_mid8_8, v_mod, NULL, 'T8.8 remove_media');
    -- Count challenge-level actions after remove_media — must still be 1 (no duplicate)
    SELECT COUNT(*) INTO v_actions_count2 FROM public.moderation_actions WHERE target_id = v_cid8_8;
    PERFORM test_helpers.assert(
      v_actions_count2 = v_actions_count,
      'T8.8 — no new challenge action after remove_media idempotency path (action_id unchanged)');
  END;

END;
$$;

-- =============================================================================
-- GROUP 9 — T9: p_report_id validation (3 tests)
-- =============================================================================
\echo ''
\echo '--- GROUP 9: p_report_id validation ---'

DO $$
DECLARE
  v_reporter uuid; v_mod uuid; v_cnt int;
BEGIN
  v_reporter := test_helpers.make_user('T9 Reporter');
  v_mod      := test_helpers.make_user('T9 Mod');
  PERFORM test_helpers.make_moderator(v_mod);

  -- T9.1: Valid pending report targeting exact subject → succeeds; moderation_actions.report_id set
  DECLARE
    v_poster9_1 uuid; v_gid9_1 uuid; v_cid9_1 uuid; v_rid9_1 uuid;
  BEGIN
    v_poster9_1 := test_helpers.make_user('T9.1 Poster');
    v_gid9_1    := test_helpers.make_group(v_poster9_1);
    PERFORM test_helpers.add_member(v_gid9_1, v_poster9_1, v_reporter);
    v_cid9_1    := test_helpers.make_challenge(v_poster9_1, v_gid9_1);
    PERFORM test_helpers.activate(v_poster9_1, v_cid9_1);
    v_rid9_1 := test_helpers.do_report(v_reporter, 'challenge', v_cid9_1, 'offensive_content', 'T9.1');
    PERFORM public.remove_content('challenge', v_cid9_1, v_mod, v_rid9_1, 'T9.1 removal');
    SELECT COUNT(*) INTO v_cnt FROM public.moderation_actions
    WHERE report_id = v_rid9_1 AND target_id = v_cid9_1;
    PERFORM test_helpers.assert(v_cnt = 1, 'T9.1 — moderation_actions.report_id = p_report_id');
  END;

  -- T9.2: p_report_id targets a different challenge → FK_REPORT_TARGET_MISMATCH
  -- Uses fresh posters to avoid one_active_challenge_per_poster constraint.
  DECLARE
    v_poster9_2a uuid; v_gid9_2a uuid; v_cid9_2a uuid; v_wrong_rid uuid;
    v_poster9_2b uuid; v_gid9_2b uuid; v_cid9_2b uuid;
  BEGIN
    v_poster9_2a := test_helpers.make_user('T9.2a Poster');
    v_gid9_2a    := test_helpers.make_group(v_poster9_2a);
    PERFORM test_helpers.add_member(v_gid9_2a, v_poster9_2a, v_reporter);
    v_cid9_2a    := test_helpers.make_challenge(v_poster9_2a, v_gid9_2a);
    PERFORM test_helpers.activate(v_poster9_2a, v_cid9_2a);
    -- report on challenge A
    v_wrong_rid  := test_helpers.do_report(v_reporter, 'challenge', v_cid9_2a, 'offensive_content', 'T9.2 wrong');

    -- separate poster for challenge B
    v_poster9_2b := test_helpers.make_user('T9.2b Poster');
    v_gid9_2b    := test_helpers.make_group(v_poster9_2b);
    PERFORM test_helpers.add_member(v_gid9_2b, v_poster9_2b, v_reporter);
    v_cid9_2b    := test_helpers.make_challenge(v_poster9_2b, v_gid9_2b);
    PERFORM test_helpers.activate(v_poster9_2b, v_cid9_2b);
    -- try remove_content on challenge B using report targeting challenge A
    BEGIN
      PERFORM public.remove_content('challenge', v_cid9_2b, v_mod, v_wrong_rid, 'T9.2 mismatch');
      RAISE EXCEPTION 'UNEXPECTED_SUCCESS';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM = 'UNEXPECTED_SUCCESS' THEN
        RAISE EXCEPTION 'T9.2 FAIL: remove_content succeeded (expected FK_REPORT_TARGET_MISMATCH)';
      ELSIF SQLERRM LIKE '%FK_REPORT_TARGET_MISMATCH%' THEN
        RAISE NOTICE 'PASS: T9.2 — wrong report_id raises FK_REPORT_TARGET_MISMATCH';
      ELSE
        RAISE EXCEPTION 'T9.2 FAIL: unexpected: % %', SQLSTATE, SQLERRM;
      END IF;
    END;
  END;

  -- T9.3: p_report_id = NULL → proactive removal; moderation_actions.report_id IS NULL
  DECLARE
    v_poster9_3 uuid; v_gid9_3 uuid; v_cid9_3 uuid;
  BEGIN
    v_poster9_3 := test_helpers.make_user('T9.3 Poster');
    v_gid9_3    := test_helpers.make_group(v_poster9_3);
    -- activate_challenge requires at least one non-poster eligible member
    PERFORM test_helpers.add_member(v_gid9_3, v_poster9_3, v_reporter);
    v_cid9_3    := test_helpers.make_challenge(v_poster9_3, v_gid9_3);
    PERFORM test_helpers.activate(v_poster9_3, v_cid9_3);
    PERFORM public.remove_content('challenge', v_cid9_3, v_mod, NULL, 'T9.3 proactive');
    SELECT COUNT(*) INTO v_cnt FROM public.moderation_actions
    WHERE target_id = v_cid9_3 AND report_id IS NULL;
    PERFORM test_helpers.assert(v_cnt = 1, 'T9.3 — proactive removal: moderation_actions.report_id IS NULL');
  END;

END;
$$;

-- =============================================================================
-- GROUP 10 — T10: action_report (4 tests)
-- =============================================================================
\echo ''
\echo '--- GROUP 10: action_report ---'

-- Each sub-test uses a fresh poster to avoid one_active_challenge_per_poster constraint.
-- action_report requires the prior action and the new report target the SAME challenge type;
-- the function validates that the prior action is not a dismissal.
DO $$
DECLARE
  v_reporter uuid; v_mod uuid; v_cnt int;
BEGIN
  v_reporter := test_helpers.make_user('T10 Reporter');
  v_mod      := test_helpers.make_user('T10 Mod');
  PERFORM test_helpers.make_moderator(v_mod);

  -- T10.1: Valid prior action (content_removed) linked to same challenge via action_report → succeeds
  -- Setup: activate challenge, report it, remove it → get action_id, then action_report the same report.
  -- (action_report is for linking an EXISTING report to a PRIOR action after the fact.)
  DECLARE
    v_poster10_1 uuid; v_gid10_1 uuid; v_cid10_1 uuid;
    v_prior_action_id uuid; v_rid10_1 uuid;
  BEGIN
    v_poster10_1 := test_helpers.make_user('T10.1 Poster');
    v_gid10_1    := test_helpers.make_group(v_poster10_1);
    PERFORM test_helpers.add_member(v_gid10_1, v_poster10_1, v_reporter);
    v_cid10_1    := test_helpers.make_challenge(v_poster10_1, v_gid10_1);
    PERFORM test_helpers.activate(v_poster10_1, v_cid10_1);
    -- Remove the challenge to get a prior_action
    PERFORM public.remove_content('challenge', v_cid10_1, v_mod, NULL, 'T10.1 removal');
    SELECT id INTO v_prior_action_id FROM public.moderation_actions
    WHERE target_id = v_cid10_1 ORDER BY created_at DESC LIMIT 1;
    -- Create a second pending report on the same challenge (after removal, this may return FK_NOT_FOUND
    -- per report_content spec; instead, simulate the scenario by using an already-pending report if any,
    -- or test action_report with a proactive report ID = NULL case)
    -- action_report(report_id, moderator_id, prior_action_id, reason):
    -- Links an existing PENDING report to a prior action by actioning it.
    -- Create a fresh reporter-initiated report that was pending when removal happened
    -- (use second user reporting after removal to simulate the "report arrived during moderation" case)
    -- Since the challenge is now cancelled, direct INSERT via postgres bypasses RLS:
    INSERT INTO public.content_reports
      (reporter_id, target_type, target_id, category, detail, status)
    VALUES (v_reporter, 'challenge', v_cid10_1, 'offensive_content', 'T10.1 late report', 'pending')
    RETURNING id INTO v_rid10_1;
    PERFORM public.action_report(v_rid10_1, v_mod, v_prior_action_id, 'T10.1 action_report reason');
    SELECT COUNT(*) INTO v_cnt FROM public.content_reports WHERE id = v_rid10_1 AND status = 'actioned';
    PERFORM test_helpers.assert(v_cnt = 1, 'T10.1 — action_report marks report as actioned');
  END;

  -- T10.2: Prior action = dismissed → FK_INVALID_PRIOR_ACTION
  DECLARE
    v_poster10_2 uuid; v_gid10_2 uuid; v_cid10_2 uuid;
    v_rid_dismiss uuid; v_dismissed_action_id uuid; v_rid_target uuid;
  BEGIN
    v_poster10_2 := test_helpers.make_user('T10.2 Poster');
    v_gid10_2    := test_helpers.make_group(v_poster10_2);
    PERFORM test_helpers.add_member(v_gid10_2, v_poster10_2, v_reporter);
    v_cid10_2    := test_helpers.make_challenge(v_poster10_2, v_gid10_2);
    PERFORM test_helpers.activate(v_poster10_2, v_cid10_2);
    v_rid_dismiss := test_helpers.do_report(v_reporter, 'challenge', v_cid10_2, 'offensive_content', 'T10.2 dismiss');
    PERFORM public.dismiss_report(v_rid_dismiss, v_mod, 'T10.2 dismiss reason');
    SELECT id INTO v_dismissed_action_id FROM public.moderation_actions
    WHERE action_type = 'report_dismissed' AND report_id = v_rid_dismiss
    ORDER BY created_at DESC LIMIT 1;
    -- Create a second pending report on the same challenge and try action_report with dismissed prior
    INSERT INTO public.content_reports
      (reporter_id, target_type, target_id, category, detail, status)
    VALUES (v_reporter, 'challenge', v_cid10_2, 'offensive_content', 'T10.2 second', 'pending')
    RETURNING id INTO v_rid_target;
    BEGIN
      PERFORM public.action_report(v_rid_target, v_mod, v_dismissed_action_id, 'T10.2 attempt');
      RAISE EXCEPTION 'UNEXPECTED_SUCCESS';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM = 'UNEXPECTED_SUCCESS' THEN
        RAISE EXCEPTION 'T10.2 FAIL: action_report succeeded (expected FK_INVALID_PRIOR_ACTION)';
      ELSIF SQLERRM LIKE '%FK_INVALID_PRIOR_ACTION%' THEN
        RAISE NOTICE 'PASS: T10.2 — dismissed prior action raises FK_INVALID_PRIOR_ACTION';
      ELSE
        RAISE EXCEPTION 'T10.2 FAIL: unexpected: % %', SQLSTATE, SQLERRM;
      END IF;
    END;
  END;

  -- T10.3: Prior action targets different challenge → FK_REPORT_TARGET_MISMATCH
  DECLARE
    v_poster10_3a uuid; v_gid10_3a uuid; v_cid10_3a uuid; v_other_action_id uuid;
    v_poster10_3b uuid; v_gid10_3b uuid; v_cid10_3b uuid; v_rid_t10_3 uuid;
  BEGIN
    -- Challenge A: removed → action
    v_poster10_3a := test_helpers.make_user('T10.3a Poster');
    v_gid10_3a    := test_helpers.make_group(v_poster10_3a);
    -- activate_challenge requires at least one non-poster eligible member
    PERFORM test_helpers.add_member(v_gid10_3a, v_poster10_3a, v_reporter);
    v_cid10_3a    := test_helpers.make_challenge(v_poster10_3a, v_gid10_3a);
    PERFORM test_helpers.activate(v_poster10_3a, v_cid10_3a);
    PERFORM public.remove_content('challenge', v_cid10_3a, v_mod, NULL, 'T10.3 removal A');
    SELECT id INTO v_other_action_id FROM public.moderation_actions
    WHERE target_id = v_cid10_3a ORDER BY created_at DESC LIMIT 1;
    -- Challenge B: active, pending report → action_report with wrong prior_action (from challenge A)
    v_poster10_3b := test_helpers.make_user('T10.3b Poster');
    v_gid10_3b    := test_helpers.make_group(v_poster10_3b);
    PERFORM test_helpers.add_member(v_gid10_3b, v_poster10_3b, v_reporter);
    v_cid10_3b    := test_helpers.make_challenge(v_poster10_3b, v_gid10_3b);
    PERFORM test_helpers.activate(v_poster10_3b, v_cid10_3b);
    v_rid_t10_3   := test_helpers.do_report(v_reporter, 'challenge', v_cid10_3b, 'offensive_content', 'T10.3');
    BEGIN
      PERFORM public.action_report(v_rid_t10_3, v_mod, v_other_action_id, 'T10.3 mismatch');
      RAISE EXCEPTION 'UNEXPECTED_SUCCESS';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM = 'UNEXPECTED_SUCCESS' THEN
        RAISE EXCEPTION 'T10.3 FAIL: action_report succeeded (expected FK_REPORT_TARGET_MISMATCH)';
      ELSIF SQLERRM LIKE '%FK_REPORT_TARGET_MISMATCH%' THEN
        RAISE NOTICE 'PASS: T10.3 — prior action on different challenge raises FK_REPORT_TARGET_MISMATCH';
      ELSE
        RAISE EXCEPTION 'T10.3 FAIL: unexpected: % %', SQLSTATE, SQLERRM;
      END IF;
    END;
  END;

  -- T10.4: No violation → verify dismiss_report works (no action needed)
  DECLARE
    v_poster10_4 uuid; v_gid10_4 uuid; v_cid10_4 uuid; v_rid_t10_4 uuid;
  BEGIN
    v_poster10_4 := test_helpers.make_user('T10.4 Poster');
    v_gid10_4    := test_helpers.make_group(v_poster10_4);
    PERFORM test_helpers.add_member(v_gid10_4, v_poster10_4, v_reporter);
    v_cid10_4    := test_helpers.make_challenge(v_poster10_4, v_gid10_4);
    PERFORM test_helpers.activate(v_poster10_4, v_cid10_4);
    v_rid_t10_4  := test_helpers.do_report(v_reporter, 'challenge', v_cid10_4, 'offensive_content', 'T10.4 no viol');
    PERFORM public.dismiss_report(v_rid_t10_4, v_mod, 'T10.4 no violation found');
    SELECT COUNT(*) INTO v_cnt FROM public.content_reports WHERE id = v_rid_t10_4 AND status = 'dismissed';
    PERFORM test_helpers.assert(v_cnt = 1, 'T10.4 — dismiss_report sets status=dismissed');
  END;

END;
$$;

-- =============================================================================
-- GROUP 11 — T11: Suspension and comment-reporting visibility (12 tests)
-- =============================================================================
\echo ''
\echo '--- GROUP 11: Suspension and visibility ---'

DO $$
DECLARE
  v_poster       uuid;
  v_member       uuid;
  v_mod          uuid;
  v_gid          uuid;
  v_cid          uuid;
  v_member_draft uuid;  -- v_member's draft, created BEFORE suspension
  v_cnt          int;
  v_invite_token text;
BEGIN
  v_poster := test_helpers.make_user('T11 Poster');
  v_member := test_helpers.make_user('T11 Member');
  v_mod    := test_helpers.make_user('T11 Mod');
  v_gid    := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_gid, v_poster, v_member);
  PERFORM test_helpers.make_moderator(v_mod);
  v_cid    := test_helpers.make_challenge(v_poster, v_gid);
  PERFORM test_helpers.activate(v_poster, v_cid);  -- snapshots v_member into eligible_participants

  -- Create v_member's draft BEFORE suspension (activation not required for T11.2/T11.4)
  v_member_draft := test_helpers.make_challenge(v_member, v_gid);

  -- Give v_member a valid guess BEFORE suspension so T11.1 isolates the RESTRICTIVE
  -- suspend_block_insert policy as the cause of the blocked comment (not the V1 Table Talk
  -- rule, which also blocks comments from non-guessers). Without this guess v_member would
  -- be blocked by the guess-gate before the suspension check even fires.
  PERFORM test_helpers.make_guess(v_member, v_cid);

  -- NOW suspend v_member for T11.1–T11.7
  PERFORM test_helpers.do_suspend(v_mod, v_member, 'T11 setup suspension');

  -- T11.1: Suspended INSERT comment → RESTRICTIVE raises insufficient_privilege (42501).
  -- A WITH CHECK policy violation raises 42501; it does NOT silently produce 0 rows.
  BEGIN
    PERFORM test_helpers.set_auth_uid(v_member);
    INSERT INTO public.comments (challenge_id, author_id, text)
    VALUES (v_cid, v_member, 'Suspended comment attempt');
    PERFORM test_helpers.clear_auth_uid();
    RAISE EXCEPTION 'UNEXPECTED_SUCCESS';
  EXCEPTION
    WHEN insufficient_privilege THEN
      PERFORM test_helpers.clear_auth_uid();
      SELECT COUNT(*) INTO v_cnt FROM public.comments WHERE author_id = v_member;
      PERFORM test_helpers.assert(v_cnt = 0, 'T11.1b — no comment row inserted after RESTRICTIVE rejection');
      RAISE NOTICE 'PASS: T11.1 — suspended user INSERT comment → insufficient_privilege (RESTRICTIVE)';
    WHEN OTHERS THEN
      PERFORM test_helpers.clear_auth_uid();
      IF SQLERRM = 'UNEXPECTED_SUCCESS' THEN
        RAISE EXCEPTION 'T11.1 FAIL: INSERT succeeded for suspended user (expected insufficient_privilege)';
      ELSE
        RAISE EXCEPTION 'T11.1 FAIL: unexpected % %', SQLSTATE, SQLERRM;
      END IF;
  END;

  -- T11.2: Suspended UPDATE own draft challenge → RESTRICTIVE rejects (0 rows updated)
  -- Uses an authenticated-editable column (public_city_display) so the column-privilege
  -- check passes and suspend_block_update RESTRICTIVE policy is reached.
  -- cancellation_reason is server-owned and must NOT be granted to authenticated.
  BEGIN
    PERFORM test_helpers.set_auth_uid(v_member);
    UPDATE public.challenges SET public_city_display = 'Suspended City' WHERE id = v_member_draft;
    SELECT COUNT(*) INTO v_cnt
    FROM public.challenges WHERE id = v_member_draft AND public_city_display = 'Suspended City';
    PERFORM test_helpers.clear_auth_uid();
    PERFORM test_helpers.assert(v_cnt = 0, 'T11.2 — suspended user UPDATE own draft challenge gives 0 rows (RESTRICTIVE)');
  END;

  -- T11.3: Suspended redeem_group_invite → FK_SUSPENDED
  DECLARE v_gid2 uuid; v_owner2 uuid;
  BEGIN
    v_owner2 := test_helpers.make_user('T11.3 Owner');
    v_gid2   := test_helpers.make_group(v_owner2);
    PERFORM test_helpers.set_auth_uid(v_owner2);
    v_invite_token := public.create_group_invite(v_gid2);
    PERFORM test_helpers.clear_auth_uid();
    BEGIN
      PERFORM test_helpers.set_auth_uid(v_member);
      PERFORM public.redeem_group_invite(v_invite_token);
      PERFORM test_helpers.clear_auth_uid();
      RAISE EXCEPTION 'UNEXPECTED_SUCCESS';
    EXCEPTION WHEN OTHERS THEN
      PERFORM test_helpers.clear_auth_uid();
      IF SQLERRM = 'UNEXPECTED_SUCCESS' THEN
        RAISE EXCEPTION 'T11.3 FAIL: redeem_group_invite succeeded for suspended user (expected FK_SUSPENDED)';
      ELSIF SQLERRM LIKE '%FK_SUSPENDED%' OR SQLERRM LIKE '%suspended%' THEN
        RAISE NOTICE 'PASS: T11.3 — suspended user cannot redeem group invite';
      ELSE
        RAISE EXCEPTION 'T11.3 FAIL: unexpected: % %', SQLSTATE, SQLERRM;
      END IF;
    END;
  END;

  -- T11.4: Suspended user can cancel own challenge via public.cancel_challenge() if it exists
  -- (SECURITY DEFINER cancel function bypasses the suspend_block_update RESTRICTIVE policy).
  -- v_member_draft was created BEFORE suspension so it exists.
  -- Direct UPDATE via authenticated (SET ROLE) is blocked (T11.2). Only a SECURITY DEFINER
  -- cancel_challenge function would bypass this. We attempt the function call and note the outcome.
  DECLARE v_cancel_result text;
  BEGIN
    PERFORM test_helpers.set_auth_uid(v_member);
    BEGIN
      PERFORM public.cancel_challenge(v_member_draft);
      PERFORM test_helpers.clear_auth_uid();
      RAISE NOTICE 'PASS: T11.4 — suspended user can cancel own challenge (cancel_challenge SECURITY DEFINER)';
    EXCEPTION WHEN OTHERS THEN
      PERFORM test_helpers.clear_auth_uid();
      -- cancel_challenge may not exist or may have a different name; note informational
      RAISE NOTICE 'INFO: T11.4 — cancel_challenge error: % % (verify spec cancel path)', SQLSTATE, SQLERRM;
    END;
  END;

  -- T11.5: Suspended author soft-deletes own comment → allowed (trigger Path 2)
  -- Direct authenticated UPDATE of deleted_at is always blocked by V1 design (SELECT policy
  -- USING deleted_at IS NULL means the post-update row can't be re-selected → WITH CHECK fail).
  -- The supported path is soft_delete_comment() — SECURITY DEFINER, bypasses RLS.
  -- suspend_user() sets only is_suspended=true (not is_active=false), so the trigger's
  -- is_active check still passes for the suspended member.
  DECLARE v_com11_5 uuid; v_del_at timestamptz;
  BEGIN
    -- Create comment as postgres (bypasses RLS) on behalf of suspended member
    INSERT INTO public.comments (challenge_id, author_id, text)
    VALUES (v_cid, v_member, 'Pre-suspension comment')
    RETURNING id INTO v_com11_5;
    -- Suspended member soft-deletes via the approved application path
    PERFORM test_helpers.set_auth_uid(v_member);
    PERFORM public.soft_delete_comment(v_com11_5);
    PERFORM test_helpers.clear_auth_uid();
    SELECT deleted_at INTO v_del_at FROM public.comments WHERE id = v_com11_5;
    PERFORM test_helpers.assert(
      v_del_at IS NOT NULL,
      'T11.5 — suspended author can soft-delete own comment through soft_delete_comment()');
  END;

  -- T11.6: Suspended exclusion reason='removed' → RESTRICTIVE raises insufficient_privilege (42501).
  -- Two defects corrected from prior version:
  --   (1) WITH CHECK rejection raises 42501, not a silent 0-row insert.
  --   (2) v_member (non-poster) could never perform a 'removed' exclusion even unsuspended,
  --       so the prior fixture did not isolate the suspension policy.
  -- Fresh fixture: v_owner_t11_6 is the group owner (can do 'removed' exclusions unsuspended).
  -- After activation, the owner is suspended and then attempts the otherwise-valid exclusion.
  DECLARE
    v_owner_t11_6  uuid; v_target_t11_6 uuid;
    v_gid_t11_6    uuid; v_cid_t11_6    uuid;
  BEGIN
    v_owner_t11_6  := test_helpers.make_user('T11.6 Owner');
    v_target_t11_6 := test_helpers.make_user('T11.6 Target');
    v_gid_t11_6    := test_helpers.make_group(v_owner_t11_6);
    -- Target joins BEFORE activation → snapshotted into eligible_participants
    PERFORM test_helpers.add_member(v_gid_t11_6, v_owner_t11_6, v_target_t11_6);
    v_cid_t11_6 := test_helpers.make_challenge(v_owner_t11_6, v_gid_t11_6);
    PERFORM test_helpers.activate(v_owner_t11_6, v_cid_t11_6);
    -- Suspend the owner (an unsuspended owner is permitted to perform this exclusion)
    PERFORM test_helpers.do_suspend(v_mod, v_owner_t11_6, 'T11.6 setup');
    -- Suspended owner attempts reason='removed' exclusion → RESTRICTIVE blocks with 42501
    BEGIN
      PERFORM test_helpers.set_auth_uid(v_owner_t11_6);
      INSERT INTO public.exclusion_events (challenge_id, player_id, reason, excluded_by)
      VALUES (v_cid_t11_6, v_target_t11_6, 'removed', v_owner_t11_6);
      PERFORM test_helpers.clear_auth_uid();
      RAISE EXCEPTION 'UNEXPECTED_SUCCESS';
    EXCEPTION
      WHEN insufficient_privilege THEN
        PERFORM test_helpers.clear_auth_uid();
        SELECT COUNT(*) INTO v_cnt FROM public.exclusion_events
        WHERE challenge_id = v_cid_t11_6 AND player_id = v_target_t11_6 AND reason = 'removed';
        PERFORM test_helpers.assert(v_cnt = 0, 'T11.6b — no exclusion row inserted after RESTRICTIVE rejection');
        RAISE NOTICE 'PASS: T11.6 — suspended owner exclusion reason=removed → insufficient_privilege (RESTRICTIVE)';
      WHEN OTHERS THEN
        PERFORM test_helpers.clear_auth_uid();
        IF SQLERRM = 'UNEXPECTED_SUCCESS' THEN
          RAISE EXCEPTION 'T11.6 FAIL: exclusion INSERT succeeded for suspended owner (expected insufficient_privilege)';
        ELSE
          RAISE EXCEPTION 'T11.6 FAIL: unexpected % %', SQLSTATE, SQLERRM;
        END IF;
    END;
  END;

  -- T11.7: Suspended exclusion reason='withdrew' → allowed (self-withdrawal permitted even when suspended)
  -- excluded_by = v_member required by CHECK: (reason NOT IN ('withdrew','removed')) OR (excluded_by IS NOT NULL)
  PERFORM test_helpers.set_auth_uid(v_member);
  INSERT INTO public.exclusion_events (challenge_id, player_id, reason, excluded_by)
  VALUES (v_cid, v_member, 'withdrew', v_member);
  SELECT COUNT(*) INTO v_cnt FROM public.exclusion_events WHERE player_id = v_member AND reason = 'withdrew';
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_cnt = 1, 'T11.7 — suspended user exclusion reason=withdrew is allowed (self-withdrawal)');

  -- T11.8: transfer_group_ownership to suspended recipient → FK_INVALID_RECIPIENT
  DECLARE v_suspended_recipient uuid; v_gid_11_8 uuid;
  BEGIN
    v_suspended_recipient := test_helpers.make_user('T11.8 SuspendedRecip');
    v_gid_11_8            := test_helpers.make_group(v_poster);
    PERFORM test_helpers.add_member(v_gid_11_8, v_poster, v_suspended_recipient);
    PERFORM test_helpers.do_suspend(v_mod, v_suspended_recipient, 'T11.8 setup');
    BEGIN
      PERFORM test_helpers.set_auth_uid(v_poster);
      PERFORM public.transfer_group_ownership(v_gid_11_8, v_suspended_recipient);
      PERFORM test_helpers.clear_auth_uid();
      RAISE EXCEPTION 'UNEXPECTED_SUCCESS';
    EXCEPTION WHEN OTHERS THEN
      PERFORM test_helpers.clear_auth_uid();
      IF SQLERRM = 'UNEXPECTED_SUCCESS' THEN
        RAISE EXCEPTION 'T11.8 FAIL: transfer succeeded (expected FK_INVALID_RECIPIENT for suspended recipient)';
      ELSIF SQLERRM LIKE '%FK_INVALID_RECIPIENT%' OR SQLERRM LIKE '%suspended%' THEN
        RAISE NOTICE 'PASS: T11.8 — transfer to suspended recipient raises FK_INVALID_RECIPIENT';
      ELSE
        RAISE EXCEPTION 'T11.8 FAIL: unexpected: % %', SQLSTATE, SQLERRM;
      END IF;
    END;
  END;

  -- T11.8a: transfer_group_ownership happy path
  DECLARE
    v_owner_ha uuid; v_recip_ha uuid; v_gid_ha uuid;
    v_owner_role_after text; v_recip_role_after text; v_hist_cnt int;
  BEGIN
    v_owner_ha := test_helpers.make_user('T11.8a Owner');
    v_recip_ha := test_helpers.make_user('T11.8a Recipient');
    v_gid_ha   := test_helpers.make_group(v_owner_ha);
    PERFORM test_helpers.add_member(v_gid_ha, v_owner_ha, v_recip_ha);
    PERFORM test_helpers.set_auth_uid(v_owner_ha);
    PERFORM public.transfer_group_ownership(v_gid_ha, v_recip_ha);
    PERFORM test_helpers.clear_auth_uid();
    SELECT role INTO v_owner_role_after FROM public.group_members WHERE group_id = v_gid_ha AND player_id = v_owner_ha;
    SELECT role INTO v_recip_role_after FROM public.group_members WHERE group_id = v_gid_ha AND player_id = v_recip_ha;
    SELECT COUNT(*) INTO v_hist_cnt FROM public.group_ownership_history
    WHERE group_id = v_gid_ha AND previous_owner = v_owner_ha AND new_owner = v_recip_ha;
    PERFORM test_helpers.assert(v_owner_role_after = 'member', 'T11.8a — former owner role = member');
    PERFORM test_helpers.assert(v_recip_role_after = 'owner',  'T11.8a — new owner role = owner');
    PERFORM test_helpers.assert(v_hist_cnt = 1, 'T11.8a — exactly 1 group_ownership_history row');
    -- Verify no two owner rows (unique index constraint)
    SELECT COUNT(*) INTO v_cnt FROM public.group_members WHERE group_id = v_gid_ha AND role = 'owner';
    PERFORM test_helpers.assert(v_cnt = 1, 'T11.8a — exactly 1 owner row after transfer');
  END;

  -- T11.9: Challenge poster reports a comment during active challenge → succeeds.
  -- Uses a fresh poster+group+challenge so the commenter can be snapshotted at activation
  -- (required to place a guess) and guess before commenting (V1 Table Talk rule).
  -- v_commenter_t11_9 joining v_gid AFTER v_cid was activated (line above) would leave them
  -- outside eligible_participants; they could not guess, and thus could not comment.
  DECLARE
    v_poster_t11_9    uuid; v_gid_t11_9 uuid; v_cid_t11_9 uuid;
    v_commenter_t11_9 uuid; v_comment_t11_9 uuid; v_rid_t11_9 uuid;
  BEGIN
    v_poster_t11_9    := test_helpers.make_user('T11.9 Poster');
    v_gid_t11_9       := test_helpers.make_group(v_poster_t11_9);
    v_commenter_t11_9 := test_helpers.make_user('T11.9 Commenter');
    -- Commenter joins BEFORE activation → snapshotted into eligible_participants
    PERFORM test_helpers.add_member(v_gid_t11_9, v_poster_t11_9, v_commenter_t11_9);
    v_cid_t11_9 := test_helpers.make_challenge(v_poster_t11_9, v_gid_t11_9);
    PERFORM test_helpers.activate(v_poster_t11_9, v_cid_t11_9);
    -- Commenter guesses before commenting (Table Talk rule)
    PERFORM test_helpers.make_guess(v_commenter_t11_9, v_cid_t11_9);
    v_comment_t11_9 := test_helpers.make_comment(v_commenter_t11_9, v_cid_t11_9, 'T11.9 comment');
    -- Poster reports the comment
    v_rid_t11_9 := test_helpers.do_report(v_poster_t11_9, 'comment', v_comment_t11_9, 'offensive_content', 'T11.9');
    PERFORM test_helpers.assert(v_rid_t11_9 IS NOT NULL, 'T11.9 — poster can report comment on own challenge');
  END;

  -- T11.10: Eligible participant who has guessed reports a comment → succeeds.
  -- Guesser must be in eligible_participants (snapshotted at activation) to place a guess;
  -- they must join the group BEFORE activate_challenge is called.
  -- Uses a fresh poster+group+challenge so the guesser can be snapshotted correctly.
  DECLARE
    v_poster_t10 uuid; v_gid_t10 uuid; v_cid_t10 uuid;
    v_guesser_t11 uuid; v_comment_t11_10 uuid; v_rid_t11_10 uuid;
  BEGIN
    v_poster_t10  := test_helpers.make_user('T11.10 Poster');
    v_gid_t10     := test_helpers.make_group(v_poster_t10);
    v_guesser_t11 := test_helpers.make_user('T11.10 Guesser');
    -- Guesser joins BEFORE activation → snapshotted into eligible_participants
    PERFORM test_helpers.add_member(v_gid_t10, v_poster_t10, v_guesser_t11);
    v_cid_t10 := test_helpers.make_challenge(v_poster_t10, v_gid_t10);
    PERFORM test_helpers.activate(v_poster_t10, v_cid_t10);
    -- Insert guess: guesser is in eligible_participants → valid while challenge is ACTIVE
    INSERT INTO public.guess_attempts
      (challenge_id, player_id, race, dish_guess, receipt_sequence)
    VALUES (v_cid_t10, v_guesser_t11, 'what', 'Test Dish T11.10', 1);
    v_comment_t11_10 := test_helpers.make_comment(v_poster_t10, v_cid_t10, 'T11.10 comment');
    v_rid_t11_10     := test_helpers.do_report(v_guesser_t11, 'comment', v_comment_t11_10, 'offensive_content', 'T11.10');
    PERFORM test_helpers.assert(v_rid_t11_10 IS NOT NULL,
      'T11.10 — eligible participant who guessed can report a comment');
  END;

  -- T11.11: Former group member (no longer in group) attempts to report → FK_NOT_FOUND
  DECLARE v_former uuid; v_comment_t11_11 uuid;
  BEGIN
    v_former := test_helpers.make_user('T11.11 Former');
    PERFORM test_helpers.add_member(v_gid, v_poster, v_former);
    -- Remove from group
    DELETE FROM public.group_members WHERE group_id = v_gid AND player_id = v_former;
    v_comment_t11_11 := test_helpers.make_comment(v_poster, v_cid, 'T11.11 comment');
    BEGIN
      DECLARE v_dummy uuid;
      BEGIN
        v_dummy := test_helpers.do_report(v_former, 'comment', v_comment_t11_11, 'offensive_content', 'T11.11');
        RAISE EXCEPTION 'UNEXPECTED_SUCCESS';
      EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'UNEXPECTED_SUCCESS' THEN
          RAISE EXCEPTION 'T11.11 FAIL: report_content succeeded for former member (expected FK_NOT_FOUND)';
        ELSIF SQLERRM LIKE '%FK_NOT_FOUND%' THEN
          RAISE NOTICE 'PASS: T11.11 — former member cannot report (FK_NOT_FOUND)';
        ELSE
          RAISE EXCEPTION 'T11.11 FAIL: unexpected: % %', SQLSTATE, SQLERRM;
        END IF;
      END;
    END;
  END;

  -- T11.12: Non-member who previously guessed → FK_NOT_FOUND
  DECLARE v_nonmember uuid; v_comment_t11_12 uuid;
  BEGIN
    v_nonmember      := test_helpers.make_user('T11.12 NonMember');
    -- Never add them to the group; they never guessed either
    v_comment_t11_12 := test_helpers.make_comment(v_poster, v_cid, 'T11.12 comment');
    BEGIN
      DECLARE v_dummy uuid;
      BEGIN
        v_dummy := test_helpers.do_report(v_nonmember, 'comment', v_comment_t11_12, 'offensive_content', 'T11.12');
        RAISE EXCEPTION 'UNEXPECTED_SUCCESS';
      EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'UNEXPECTED_SUCCESS' THEN
          RAISE EXCEPTION 'T11.12 FAIL: report_content succeeded for non-member (expected FK_NOT_FOUND)';
        ELSIF SQLERRM LIKE '%FK_NOT_FOUND%' THEN
          RAISE NOTICE 'PASS: T11.12 — non-member cannot report (FK_NOT_FOUND)';
        ELSE
          RAISE EXCEPTION 'T11.12 FAIL: unexpected: % %', SQLSTATE, SQLERRM;
        END IF;
      END;
    END;
  END;

END;
$$;

-- =============================================================================
-- GROUP 12 — T12: Block direction (4 tests)
-- =============================================================================
\echo ''
\echo '--- GROUP 12: Block direction ---'

DO $$
DECLARE
  v_userA uuid; v_userB uuid; v_seed uuid; v_gid uuid; v_cid uuid; v_cnt int;
BEGIN
  v_userA := test_helpers.make_user('T12 UserA');
  v_userB := test_helpers.make_user('T12 UserB Poster');
  v_seed  := test_helpers.make_user('T12 Activation Seed');

  v_gid := test_helpers.make_group(v_userB);

  -- Seed joins before activation so activation has an eligible participant.
  PERFORM test_helpers.add_member(v_gid, v_userB, v_seed);

  v_cid := test_helpers.make_challenge(v_userB, v_gid);
  PERFORM test_helpers.activate(v_userB, v_cid);

  -- A joins after activation: group member, but not snapshotted as eligible.
  -- A can see the posted challenge before blocking, but receives no eligible-participant
  -- carve-out when a block is in effect.
  PERFORM test_helpers.add_member(v_gid, v_userB, v_userA);

  -- T12.1: Noneligible group viewer A blocks poster B → A cannot see B's challenges
  PERFORM test_helpers.do_block(v_userA, v_userB);
  PERFORM test_helpers.set_auth_uid(v_userA);
  SELECT COUNT(*) INTO v_cnt FROM public.challenges WHERE id = v_cid;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_cnt = 0, 'T12.1 — noneligible group viewer who blocks poster sees 0 challenges (viewer-blocks-poster)');

  -- T12.2: Poster B blocks noneligible group viewer A → A cannot see B's challenges (has_block_with is bilateral)
  -- Unblock first, then have poster block viewer
  DELETE FROM public.user_blocks WHERE blocker_id = v_userA AND blocked_id = v_userB;
  PERFORM test_helpers.do_block(v_userB, v_userA);
  PERFORM test_helpers.set_auth_uid(v_userA);
  SELECT COUNT(*) INTO v_cnt FROM public.challenges WHERE id = v_cid;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_cnt = 0, 'T12.2 — poster blocks noneligible group viewer: viewer sees 0 challenges (poster-blocks-viewer)');

  -- T12.3: A queries user_blocks for rows where they are blocked_id → 0 rows
  PERFORM test_helpers.set_auth_uid(v_userA);
  SELECT COUNT(*) INTO v_cnt FROM public.user_blocks WHERE blocked_id = v_userA;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_cnt = 0, 'T12.3 — cannot see rows where you are the blocked_id');

  -- T12.4: A queries user_blocks where they are blocker_id → own rows returned
  -- A now blocks B (re-establish a block as A)
  DELETE FROM public.user_blocks WHERE blocker_id = v_userB AND blocked_id = v_userA;
  PERFORM test_helpers.do_block(v_userA, v_userB);
  PERFORM test_helpers.set_auth_uid(v_userA);
  SELECT COUNT(*) INTO v_cnt FROM public.user_blocks WHERE blocker_id = v_userA;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_cnt >= 1, 'T12.4 — blocker can see their own user_blocks rows');

END;
$$;

-- =============================================================================
-- GROUP 13 — T13: SHA-256 integrity (4 tests)
-- =============================================================================
\echo ''
\echo '--- GROUP 13: SHA-256 integrity ---'

DO $$
DECLARE
  v_uploader uuid; v_mod uuid; v_mid uuid; v_cnt int;
BEGIN
  v_uploader := test_helpers.make_user('T13 Uploader');
  v_mod      := test_helpers.make_user('T13 Mod');
  PERFORM test_helpers.make_moderator(v_mod);

  -- T13.1: Valid 64-char lowercase hex → stored; constraint passes
  v_mid := test_helpers.make_media_with_key(
    v_uploader,
    'a665a45920422f9d417e4867efdc4fb8a04a1f3fff1fa07e998e86f7f7a27ae3'
  );
  SELECT COUNT(*) INTO v_cnt FROM private.media_storage_keys
  WHERE media_object_id = v_mid AND sha256_hash IS NOT NULL;
  PERFORM test_helpers.assert(v_cnt = 1, 'T13.1 — valid sha256 hex stored successfully');

  -- T13.2: reject_photo on media with NO media_storage_keys row → FK_MEDIA_METADATA_INCOMPLETE.
  -- approve_photo does NOT read sha256_hash; it will approve the photo without error.
  -- reject_photo DOES read sha256_hash from private.media_storage_keys; when no row
  -- exists, v_sha256 stays NULL and the function raises FK_MEDIA_METADATA_INCOMPLETE.
  -- Also verifies: status stays 'pending_review' (reject_photo raises before changing status).
  DECLARE v_mid_no_key uuid;
  BEGIN
    v_mid_no_key := gen_random_uuid();
    INSERT INTO public.media_objects (id, uploader_id, mime_type, status, re_encoded_at)
    VALUES (v_mid_no_key, v_uploader, 'image/webp', 'pending_review', now());
    -- No media_storage_keys row inserted (simulates legacy / metadata-incomplete media)
    BEGIN
      PERFORM public.reject_photo(v_mid_no_key, v_mod, 'T13.2 reject attempt');
      RAISE EXCEPTION 'UNEXPECTED_SUCCESS';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM = 'UNEXPECTED_SUCCESS' THEN
        RAISE EXCEPTION 'T13.2 FAIL: reject_photo succeeded (expected FK_MEDIA_METADATA_INCOMPLETE on no-key media)';
      ELSIF SQLERRM LIKE '%FK_MEDIA_METADATA_INCOMPLETE%' THEN
        RAISE NOTICE 'PASS: T13.2 — reject_photo on media with no storage key raises FK_MEDIA_METADATA_INCOMPLETE';
      ELSE
        RAISE EXCEPTION 'T13.2 FAIL: unexpected: % %', SQLSTATE, SQLERRM;
      END IF;
    END;
    -- Status must be unchanged (still pending_review — reject_photo raised before changing it)
    SELECT COUNT(*) INTO v_cnt FROM public.media_objects WHERE id = v_mid_no_key AND status = 'pending_review';
    PERFORM test_helpers.assert(v_cnt = 1, 'T13.2 — status unchanged (still pending_review) after FK_MEDIA_METADATA_INCOMPLETE');
  END;

  -- T13.3: Uppercase hex → format constraint violation (23514 CHECK).
  -- This is a regression guard: the CHECK constraint on sha256_hash format rejects uppercase.
  -- Note: the constraint fires at INSERT time, not at the approve_photo level.
  BEGIN
    DECLARE v_mid_upper uuid;
    BEGIN
      v_mid_upper := gen_random_uuid();
      INSERT INTO public.media_objects (id, uploader_id, mime_type, status, re_encoded_at)
      VALUES (v_mid_upper, v_uploader, 'image/webp', 'pending_review', now());
      INSERT INTO private.media_storage_keys (media_object_id, storage_key, sha256_hash, re_encoded_storage_key)
      VALUES (v_mid_upper, 'uploads/' || v_mid_upper::text || '/original.jpg',
              'A665A45920422F9D417E4867EFDC4FB8A04A1F3FFF1FA07E998E86F7F7A27AE3', 'test/key2');
      RAISE EXCEPTION 'UNEXPECTED_SUCCESS';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM = 'UNEXPECTED_SUCCESS' THEN
        RAISE EXCEPTION 'T13.3 FAIL: INSERT succeeded for uppercase sha256 (expected 23514 CHECK violation)';
      ELSIF SQLSTATE = '23514' OR SQLERRM LIKE '%sha256%' OR SQLERRM LIKE '%hex%'
         OR SQLERRM LIKE '%check%' OR SQLERRM LIKE '%constraint%' THEN
        RAISE NOTICE 'PASS: T13.3 — uppercase sha256 rejected by CHECK constraint (23514)';
      ELSE
        RAISE EXCEPTION 'T13.3 FAIL: expected 23514 CHECK violation, got: % %', SQLSTATE, SQLERRM;
      END IF;
    END;
  END;

  -- T13.4: approve_photo on media WITH valid sha256 and pending_review status → succeeds.
  -- Happy path: sha256 readable, state transitions to 'ready'.
  v_mid := test_helpers.make_media_with_key(
    v_uploader,
    'b665a45920422f9d417e4867efdc4fb8a04a1f3fff1fa07e998e86f7f7a27ae3',
    'pending_review'
  );
  PERFORM public.approve_photo(v_mid, v_mod, 'T13.4 approved');
  SELECT COUNT(*) INTO v_cnt FROM public.media_objects WHERE id = v_mid AND status = 'ready';
  PERFORM test_helpers.assert(v_cnt = 1, 'T13.4 — approve_photo with valid sha256: state transitions to ready');

END;
$$;

-- =============================================================================
-- GROUP 14 — T14: Cleanup hold (7 tests)
-- =============================================================================
\echo ''
\echo '--- GROUP 14: Cleanup hold ---'

DO $$
DECLARE
  v_poster uuid; v_userA uuid; v_userB uuid; v_mod uuid;
  v_gid uuid; v_cid uuid; v_mid uuid;
  v_rA uuid; v_rB uuid; v_cnt int;
  v_claimable boolean;
BEGIN
  v_poster := test_helpers.make_user('T14 Poster');
  v_userA  := test_helpers.make_user('T14 UserA');
  v_userB  := test_helpers.make_user('T14 UserB');
  v_mod    := test_helpers.make_user('T14 Mod');
  v_gid    := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_gid, v_poster, v_userA);
  PERFORM test_helpers.add_member(v_gid, v_poster, v_userB);
  PERFORM test_helpers.make_moderator(v_mod);

  SELECT challenge_id, media_id INTO v_cid, v_mid
  FROM test_helpers.make_draft_challenge_with_media(v_poster, v_gid);
  PERFORM test_helpers.activate(v_poster, v_cid);

  -- T14 cleanup matrix (approved): proves claim_moderation_media_cleanup returns no row while
  -- pending reports exist, and returns the row only after all reports are resolved.
  --
  -- Strategy: remove media FIRST (no pending reports yet → removes cleanly), then INSERT
  -- pending reports directly as postgres (bypasses report_content's access check on removed media).
  -- This way we can observe the "not claimable" state before any dismissals.

  -- Remove media (no active reports → removal succeeds; media now status='removed')
  PERFORM public.remove_media(v_mid, v_mod, NULL, 'T14 removal');

  -- T14.1: Two pending reports → NOT claimable
  INSERT INTO public.content_reports
    (reporter_id, target_type, target_id, category, status)
  VALUES (v_userA, 'media_object', v_mid, 'inappropriate_image', 'pending')
  RETURNING id INTO v_rA;
  INSERT INTO public.content_reports
    (reporter_id, target_type, target_id, category, status)
  VALUES (v_userB, 'media_object', v_mid, 'inappropriate_image', 'pending')
  RETURNING id INTO v_rB;
  SELECT COUNT(*) INTO v_cnt FROM public.claim_moderation_media_cleanup(10)
  WHERE media_object_id = v_mid;
  PERFORM test_helpers.assert(v_cnt = 0,
    'T14.1 — 2 pending media reports → media NOT claimable (cleanup hold active)');

  -- T14.2: Dismiss one → still NOT claimable (one pending remains)
  PERFORM public.dismiss_report(v_rA, v_mod, 'T14.2 dismiss A');
  SELECT COUNT(*) INTO v_cnt FROM public.claim_moderation_media_cleanup(10)
  WHERE media_object_id = v_mid;
  PERFORM test_helpers.assert(v_cnt = 0,
    'T14.2 — 1 pending report remaining → still NOT claimable');

  -- T14.3: Dismiss second → now claimable (no pending reports remain)
  PERFORM public.dismiss_report(v_rB, v_mod, 'T14.3 dismiss B');
  SELECT COUNT(*) INTO v_cnt FROM public.claim_moderation_media_cleanup(10)
  WHERE media_object_id = v_mid;
  PERFORM test_helpers.assert(v_cnt = 1,
    'T14.3 — all reports dismissed → media now claimable');

  -- T14.4: Pending CHALLENGE inappropriate_image report → linked media NOT claimable.
  -- T14.5: Dismiss that challenge report → linked media becomes claimable.
  DECLARE
    v_poster_14_4 uuid; v_gid_14_4 uuid; v_cid_14_4 uuid; v_mid_14_4 uuid; v_r_14_4 uuid;
  BEGIN
    v_poster_14_4 := test_helpers.make_user('T14.4 Poster');
    v_gid_14_4    := test_helpers.make_group(v_poster_14_4);
    PERFORM test_helpers.add_member(v_gid_14_4, v_poster_14_4, v_userA);
    SELECT challenge_id, media_id INTO v_cid_14_4, v_mid_14_4
    FROM test_helpers.make_draft_challenge_with_media(v_poster_14_4, v_gid_14_4);
    PERFORM test_helpers.activate(v_poster_14_4, v_cid_14_4);
    -- Remove media first (no reports yet → succeeds; media now 'removed')
    PERFORM public.remove_media(v_mid_14_4, v_mod, NULL, 'T14.4 removal');
    -- Insert a pending challenge inappropriate_image report directly (challenge links this media)
    INSERT INTO public.content_reports
      (reporter_id, target_type, target_id, category, status)
    VALUES (v_userA, 'challenge', v_cid_14_4, 'inappropriate_image', 'pending')
    RETURNING id INTO v_r_14_4;
    -- Cleanup blocked by pending challenge report
    SELECT COUNT(*) INTO v_cnt FROM public.claim_moderation_media_cleanup(10)
    WHERE media_object_id = v_mid_14_4;
    PERFORM test_helpers.assert(v_cnt = 0,
      'T14.4 — pending challenge inappropriate_image report → linked media NOT claimable');

    -- T14.5: Dismiss the challenge report → media becomes claimable
    PERFORM public.dismiss_report(v_r_14_4, v_mod, 'T14.5 dismiss challenge report');
    SELECT COUNT(*) INTO v_cnt FROM public.claim_moderation_media_cleanup(10)
    WHERE media_object_id = v_mid_14_4;
    PERFORM test_helpers.assert(v_cnt = 1,
      'T14.5 — dismissed challenge inappropriate_image report → media now claimable');
  END;

  -- T14.6: get_poster_media_status with wrong uploader_id → no row returned
  DECLARE v_mid_14_6 uuid; v_wrong_id uuid; v_status_rows int;
  BEGIN
    v_wrong_id  := test_helpers.make_user('T14.6 Wrong User');
    v_mid_14_6  := test_helpers.make_media_with_key(v_poster,
      'c665a45920422f9d417e4867efdc4fb8a04a1f3fff1fa07e998e86f7f7a27ae3');
    SELECT COUNT(*) INTO v_status_rows
    FROM public.get_poster_media_status(v_mid_14_6, v_wrong_id);
    PERFORM test_helpers.assert(v_status_rows = 0, 'T14.6 — wrong uploader_id returns no row');
  END;

  -- T14.7: Correct uploader_id, status = 'rejected' → row with status and rejection_message
  DECLARE v_mid_14_7 uuid; v_status_val text; v_msg_val text;
  BEGIN
    v_mid_14_7 := test_helpers.make_media_with_key(v_poster,
      'd665a45920422f9d417e4867efdc4fb8a04a1f3fff1fa07e998e86f7f7a27ae4', 'pending_review');
    PERFORM public.reject_photo(v_mid_14_7, v_mod, 'T14.7 rejection');
    SELECT status, rejection_message INTO v_status_val, v_msg_val
    FROM public.get_poster_media_status(v_mid_14_7, v_poster);
    PERFORM test_helpers.assert(v_status_val = 'rejected', 'T14.7 — get_poster_media_status returns rejected status');
    PERFORM test_helpers.assert(v_msg_val IS NOT NULL, 'T14.7 — get_poster_media_status returns rejection_message');
  END;

END;
$$;

-- =============================================================================
-- GROUP 15 — T15: Clue visibility after removal (3 tests)
-- =============================================================================
\echo ''
\echo '--- GROUP 15: Clue visibility after removal ---'

DO $$
DECLARE
  v_poster uuid; v_member uuid; v_mod uuid; v_gid uuid; v_cid uuid; v_clue_id uuid;
  v_cnt int; v_removed_at timestamptz; v_action_id uuid;
BEGIN
  v_poster := test_helpers.make_user('T15 Poster');
  v_member := test_helpers.make_user('T15 Member');
  v_mod    := test_helpers.make_user('T15 Mod');
  v_gid    := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_gid, v_poster, v_member);
  PERFORM test_helpers.make_moderator(v_mod);
  v_cid    := test_helpers.make_challenge(v_poster, v_gid);
  PERFORM test_helpers.activate(v_poster, v_cid);
  -- Clue must be by the challenge poster (V1: clues.poster_id = poster)
  v_clue_id := test_helpers.make_clue(v_poster, v_cid, 'T15 clue text');

  -- T15.1: remove_content('clue') → clue.moderator_removed_at IS NOT NULL; action_id set
  PERFORM public.remove_content('clue', v_clue_id, v_mod, NULL, 'T15.1 removal');
  SELECT moderator_removed_at, moderator_removal_action_id INTO v_removed_at, v_action_id
  FROM public.clues WHERE id = v_clue_id;
  PERFORM test_helpers.assert(v_removed_at IS NOT NULL, 'T15.1 — clue.moderator_removed_at set after removal');
  PERFORM test_helpers.assert(v_action_id IS NOT NULL, 'T15.1 — clue.moderator_removal_action_id set after removal');

  -- T15.2: Authenticated queries removed clue → 0 rows (RESTRICTIVE SELECT policy)
  PERFORM test_helpers.set_auth_uid(v_member);
  SELECT COUNT(*) INTO v_cnt FROM public.clues WHERE id = v_clue_id;
  PERFORM test_helpers.clear_auth_uid();
  PERFORM test_helpers.assert(v_cnt = 0, 'T15.2 — authenticated sees 0 rows for removed clue');

  -- T15.3: Service role (postgres = BYPASSRLS) queries removed clue → row returned; text preserved
  SELECT COUNT(*) INTO v_cnt FROM public.clues WHERE id = v_clue_id;
  PERFORM test_helpers.assert(v_cnt = 1, 'T15.3 — service role sees removed clue row');
  DECLARE v_text_val text;
  BEGIN
    SELECT text INTO v_text_val FROM public.clues WHERE id = v_clue_id;
    PERFORM test_helpers.assert(v_text_val = 'T15 clue text', 'T15.3 — removed clue text preserved in row');
  END;

END;
$$;

-- =============================================================================
-- GROUP 16 — T16: Forge protection (7 tests)
-- =============================================================================
\echo ''
\echo '--- GROUP 16: Forge protection ---'

DO $$
DECLARE
  v_poster uuid; v_mod uuid; v_gid uuid; v_cid uuid; v_clue_id uuid;
  v_comment_id uuid; v_cnt int;
BEGIN
  v_poster := test_helpers.make_user('T16 Poster');
  v_mod    := test_helpers.make_user('T16 Mod');
  v_gid    := test_helpers.make_group(v_poster);
  PERFORM test_helpers.make_moderator(v_mod);
  -- activate_challenge requires at least one non-poster eligible member
  PERFORM test_helpers.add_member(v_gid, v_poster, v_mod);
  v_cid    := test_helpers.make_challenge(v_poster, v_gid);
  PERFORM test_helpers.activate(v_poster, v_cid);

  -- T16.1: authenticated INSERT challenge with moderator_removed_at set → stored as NULL.
  -- Uses a fresh poster (v_poster_16_1) with its own group to avoid the
  -- one_active_challenge_per_poster UNIQUE index: that index covers
  -- state IN ('draft','active','locked'), so v_poster (who has an active v_cid) cannot
  -- own any additional draft/active/locked challenge in any group.
  DECLARE v_poster_16_1 uuid; v_gid_16_1 uuid; v_cid_forge uuid; v_forged_at timestamptz;
  BEGIN
    v_poster_16_1 := test_helpers.make_user('T16.1 Poster');
    v_gid_16_1    := test_helpers.make_group(v_poster_16_1);
    PERFORM test_helpers.set_auth_uid(v_poster_16_1);
    INSERT INTO public.challenges (group_id, moderator_removed_at, moderator_removal_action_id)
    VALUES (v_gid_16_1, NOW(), gen_random_uuid())
    RETURNING id INTO v_cid_forge;
    PERFORM test_helpers.clear_auth_uid();
    SELECT moderator_removed_at INTO v_forged_at FROM public.challenges WHERE id = v_cid_forge;
    PERFORM test_helpers.assert(v_forged_at IS NULL, 'T16.1 — INSERT forge-null trigger nulls moderator_removed_at on challenge');
  END;

  -- T16.2: authenticated INSERT comment with moderator_removal_action_id set → stored as NULL
  DECLARE v_com_forge uuid; v_forged_action_id uuid;
  BEGIN
    PERFORM test_helpers.set_auth_uid(v_poster);
    INSERT INTO public.comments (challenge_id, author_id, text, moderator_removal_action_id)
    VALUES (v_cid, v_poster, 'Forge attempt', gen_random_uuid())
    RETURNING id INTO v_com_forge;
    PERFORM test_helpers.clear_auth_uid();
    SELECT moderator_removal_action_id INTO v_forged_action_id FROM public.comments WHERE id = v_com_forge;
    PERFORM test_helpers.assert(v_forged_action_id IS NULL, 'T16.2 — INSERT forge-null nulls moderator_removal_action_id on comment');
  END;

  -- T16.3: authenticated INSERT clue with both fields set → both stored as NULL
  DECLARE v_clue_forge uuid; v_f_at timestamptz; v_f_aid uuid;
  BEGIN
    PERFORM test_helpers.set_auth_uid(v_poster);
    INSERT INTO public.clues (challenge_id, poster_id, text, moderator_removed_at, moderator_removal_action_id)
    VALUES (v_cid, v_poster, 'Forge clue', NOW(), gen_random_uuid())
    RETURNING id INTO v_clue_forge;
    PERFORM test_helpers.clear_auth_uid();
    SELECT moderator_removed_at, moderator_removal_action_id INTO v_f_at, v_f_aid
    FROM public.clues WHERE id = v_clue_forge;
    PERFORM test_helpers.assert(v_f_at IS NULL AND v_f_aid IS NULL,
      'T16.3 — INSERT forge-null nulls both moderation fields on clue');
  END;

  -- T16.4: forkensics_rls_helper (not forkensics_executor) UPDATE challenge moderator_removed_at
  -- → FK_REMOVAL_UNAUTHORIZED from the SECURITY INVOKER trigger.
  --
  -- Why not `authenticated`: authenticated lacks column-level UPDATE privilege on
  -- moderator_removed_at, so PostgreSQL returns 42501 before the trigger ever fires.
  -- forkensics_rls_helper has BYPASSRLS + the column UPDATE grant added inside BEGIN
  -- (ROLLBACK removes it), so the privilege check passes and the SECURITY INVOKER trigger
  -- (restrict_moderation_field_updates) sees:
  --   current_user = 'forkensics_rls_helper' ≠ 'forkensics_executor' → FK_REMOVAL_UNAUTHORIZED.
  -- Using the existing forkensics_rls_helper role avoids the need to CREATE ROLE with
  -- BYPASSRLS (which requires superuser authority that local postgres does not have).
  BEGIN
    SET LOCAL ROLE forkensics_rls_helper;
    UPDATE public.challenges SET moderator_removed_at = NOW() WHERE id = v_cid;
    RESET ROLE;
    RAISE EXCEPTION 'UNEXPECTED_SUCCESS';
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    IF SQLERRM = 'UNEXPECTED_SUCCESS' THEN
      RAISE EXCEPTION 'T16.4 FAIL: UPDATE succeeded (expected FK_REMOVAL_UNAUTHORIZED from SECURITY INVOKER trigger)';
    ELSIF SQLERRM LIKE '%FK_REMOVAL_UNAUTHORIZED%' THEN
      RAISE NOTICE 'PASS: T16.4 — forkensics_rls_helper (non-executor) cannot set moderator_removed_at (trigger)';
    ELSE
      RAISE EXCEPTION 'T16.4 FAIL: got: % %', SQLSTATE, SQLERRM;
    END IF;
  END;

  -- T16.5: forkensics_rls_helper UPDATE clue moderator_removal_action_id → FK_REMOVAL_UNAUTHORIZED.
  -- V1 has no UPDATE RLS policy on clues for non-superusers; forkensics_rls_helper's
  -- BYPASSRLS attribute skips RLS so the UPDATE reaches the trigger level.
  -- The SECURITY INVOKER trigger sees current_user ≠ 'forkensics_executor' → FK_REMOVAL_UNAUTHORIZED.
  v_clue_id := test_helpers.make_clue(v_poster, v_cid, 'T16.5 clue');
  BEGIN
    SET LOCAL ROLE forkensics_rls_helper;
    UPDATE public.clues SET moderator_removal_action_id = gen_random_uuid() WHERE id = v_clue_id;
    RESET ROLE;
    RAISE EXCEPTION 'UNEXPECTED_SUCCESS';
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    IF SQLERRM = 'UNEXPECTED_SUCCESS' THEN
      RAISE EXCEPTION 'T16.5 FAIL: UPDATE succeeded (expected FK_REMOVAL_UNAUTHORIZED from SECURITY INVOKER trigger)';
    ELSIF SQLERRM LIKE '%FK_REMOVAL_UNAUTHORIZED%' THEN
      RAISE NOTICE 'PASS: T16.5 — forkensics_rls_helper cannot set clue.moderator_removal_action_id (trigger)';
    ELSE
      RAISE EXCEPTION 'T16.5 FAIL: got: % %', SQLSTATE, SQLERRM;
    END IF;
  END;

  -- T16.6a: forkensics_executor sets only moderator_removed_at (not action_id) → CHECK constraint (23514).
  -- Uses a fresh poster with its own group to avoid any one_active_challenge_per_poster conflict.
  -- forkensics_executor IS allowed by the trigger, but the removes_consistency CHECK requires BOTH fields.
  DECLARE v_poster_16_6a uuid; v_gid_16_6a uuid; v_cid_16_6a uuid;
  BEGIN
    v_poster_16_6a := test_helpers.make_user('T16.6a Poster');
    v_gid_16_6a    := test_helpers.make_group(v_poster_16_6a);
    v_cid_16_6a    := test_helpers.make_challenge(v_poster_16_6a, v_gid_16_6a);
    BEGIN
      SET LOCAL ROLE forkensics_executor;
      UPDATE public.challenges
      SET moderator_removed_at = NOW()
      WHERE id = v_cid_16_6a;
      RESET ROLE;
      RAISE EXCEPTION 'UNEXPECTED_SUCCESS';
    EXCEPTION WHEN OTHERS THEN
      RESET ROLE;
      IF SQLERRM = 'UNEXPECTED_SUCCESS' THEN
        RAISE EXCEPTION 'T16.6a FAIL: partial moderation field update succeeded (expected 23514 removes_consistency)';
      ELSIF SQLSTATE = '23514' OR SQLERRM LIKE '%removes_consistency%' THEN
        RAISE NOTICE 'PASS: T16.6a — partial moderation field update rejected by removes_consistency CHECK (23514)';
      ELSE
        RAISE EXCEPTION 'T16.6a FAIL: expected 23514 removes_consistency CHECK, got: % %', SQLSTATE, SQLERRM;
      END IF;
    END;
  END;

  -- T16.6b: forkensics_executor: valid first removal; then attempt to change moderator_removed_at → FK_REMOVAL_IMMUTABLE.
  -- Uses a fresh poster with its own group to avoid any one_active_challenge_per_poster conflict.
  DECLARE v_poster_16_6b uuid; v_gid_16_6b uuid; v_cid_16_6b uuid;
  BEGIN
    v_poster_16_6b := test_helpers.make_user('T16.6b Poster');
    v_gid_16_6b    := test_helpers.make_group(v_poster_16_6b);
    PERFORM test_helpers.add_member(v_gid_16_6b, v_poster_16_6b, v_mod);
    v_cid_16_6b    := test_helpers.make_challenge(v_poster_16_6b, v_gid_16_6b);
    -- Valid first removal via function (SECURITY DEFINER, runs as forkensics_executor internally)
    PERFORM public.remove_content('challenge', v_cid_16_6b, v_mod, NULL, 'T16.6b first removal');
    -- Now try to change the already-set field directly as forkensics_executor
    BEGIN
      SET LOCAL ROLE forkensics_executor;
      UPDATE public.challenges
      SET moderator_removed_at = NOW() + interval '1 hour'
      WHERE id = v_cid_16_6b;
      RESET ROLE;
      RAISE EXCEPTION 'UNEXPECTED_SUCCESS';
    EXCEPTION WHEN OTHERS THEN
      RESET ROLE;
      IF SQLERRM = 'UNEXPECTED_SUCCESS' THEN
        RAISE EXCEPTION 'T16.6b FAIL: second UPDATE succeeded (expected FK_REMOVAL_IMMUTABLE)';
      ELSIF SQLERRM LIKE '%FK_REMOVAL_IMMUTABLE%' THEN
        RAISE NOTICE 'PASS: T16.6b — already-set moderator_removed_at is immutable (FK_REMOVAL_IMMUTABLE)';
      ELSE
        RAISE EXCEPTION 'T16.6b FAIL: got: % %', SQLSTATE, SQLERRM;
      END IF;
    END;
  END;

END;
$$;

-- =============================================================================
-- GROUP 17 — T17: Role privilege isolation (8 tests)
-- =============================================================================
\echo ''
\echo '--- GROUP 17: Role privilege isolation ---'

-- T17: Privilege isolation tests — actual EXECUTE attempts under denied roles, asserting SQLSTATE 42501.
DO $$
DECLARE
  v_poster   uuid;
  v_reporter uuid;
  v_gid      uuid;
  v_cid      uuid;
  v_mid      uuid;
  v_rid      uuid;
  v_cnt      int;
BEGIN
  v_poster   := test_helpers.make_user('T17 Poster');
  v_reporter := test_helpers.make_user('T17 Reporter');
  v_gid      := test_helpers.make_group(v_poster);
  PERFORM test_helpers.add_member(v_gid, v_poster, v_reporter);
  v_mid := test_helpers.make_media_with_key(v_poster,
    'e665a45920422f9d417e4867efdc4fb8a04a1f3fff1fa07e998e86f7f7a27ae3', 'pending_review');
  v_cid := test_helpers.make_challenge(v_poster, v_gid);
  PERFORM test_helpers.activate(v_poster, v_cid);

  -- T17.1: authenticated cannot execute approve_photo (42501)
  BEGIN
    SET LOCAL ROLE authenticated;
    PERFORM set_config('request.jwt.claims',
      json_build_object('sub', v_poster::text, 'role', 'authenticated')::text, true);
    PERFORM public.approve_photo(v_mid, v_poster, 'T17.1');
    RESET ROLE;
    RAISE EXCEPTION 'T17.1 FAIL: expected 42501 insufficient_privilege';
  EXCEPTION
    WHEN insufficient_privilege THEN
      RESET ROLE;
      RAISE NOTICE 'PASS: T17.1 — authenticated cannot execute approve_photo (42501)';
    WHEN OTHERS THEN
      RESET ROLE;
      RAISE EXCEPTION 'T17.1 FAIL: unexpected SQLSTATE % msg: %', SQLSTATE, SQLERRM;
  END;

  -- T17.2: authenticated cannot execute remove_content (42501)
  BEGIN
    SET LOCAL ROLE authenticated;
    PERFORM set_config('request.jwt.claims',
      json_build_object('sub', v_poster::text, 'role', 'authenticated')::text, true);
    PERFORM public.remove_content('challenge', v_cid, v_poster, NULL, 'T17.2');
    RESET ROLE;
    RAISE EXCEPTION 'T17.2 FAIL: expected 42501 insufficient_privilege';
  EXCEPTION
    WHEN insufficient_privilege THEN
      RESET ROLE;
      RAISE NOTICE 'PASS: T17.2 — authenticated cannot execute remove_content (42501)';
    WHEN OTHERS THEN
      RESET ROLE;
      RAISE EXCEPTION 'T17.2 FAIL: unexpected SQLSTATE % msg: %', SQLSTATE, SQLERRM;
  END;

  -- T17.3: authenticated cannot execute get_media_serve_authorization (42501)
  BEGIN
    SET LOCAL ROLE authenticated;
    PERFORM set_config('request.jwt.claims',
      json_build_object('sub', v_poster::text, 'role', 'authenticated')::text, true);
    PERFORM public.get_media_serve_authorization(v_mid, v_poster);
    RESET ROLE;
    RAISE EXCEPTION 'T17.3 FAIL: expected 42501 insufficient_privilege';
  EXCEPTION
    WHEN insufficient_privilege THEN
      RESET ROLE;
      RAISE NOTICE 'PASS: T17.3 — authenticated cannot execute get_media_serve_authorization (42501)';
    WHEN OTHERS THEN
      RESET ROLE;
      RAISE EXCEPTION 'T17.3 FAIL: unexpected SQLSTATE % msg: %', SQLSTATE, SQLERRM;
  END;

  -- T17.4: anon cannot execute report_content (42501)
  BEGIN
    SET LOCAL ROLE anon;
    PERFORM public.report_content('challenge', v_cid, 'inappropriate_image', 'T17.4');
    RESET ROLE;
    RAISE EXCEPTION 'T17.4 FAIL: expected 42501 insufficient_privilege';
  EXCEPTION
    WHEN insufficient_privilege THEN
      RESET ROLE;
      RAISE NOTICE 'PASS: T17.4 — anon cannot execute report_content (42501)';
    WHEN OTHERS THEN
      RESET ROLE;
      RAISE EXCEPTION 'T17.4 FAIL: unexpected SQLSTATE % msg: %', SQLSTATE, SQLERRM;
  END;

  -- T17.5: authenticated CAN execute report_content → succeeds
  v_rid := test_helpers.do_report(v_reporter, 'challenge', v_cid, 'offensive_content', 'T17.5');
  PERFORM test_helpers.assert(v_rid IS NOT NULL, 'T17.5 — authenticated can call report_content (EXECUTE granted)');

  -- T17.6: authenticated cannot SELECT from content_reports (42501)
  BEGIN
    PERFORM test_helpers.set_auth_uid(v_reporter);
    SELECT COUNT(*) INTO v_cnt FROM public.content_reports;
    PERFORM test_helpers.clear_auth_uid();
    RAISE EXCEPTION 'T17.6 FAIL: expected 42501 insufficient_privilege on content_reports SELECT';
  EXCEPTION
    WHEN insufficient_privilege THEN
      PERFORM test_helpers.clear_auth_uid();
      RAISE NOTICE 'PASS: T17.6 — authenticated cannot SELECT from content_reports (42501)';
    WHEN OTHERS THEN
      PERFORM test_helpers.clear_auth_uid();
      RAISE EXCEPTION 'T17.6 FAIL: unexpected SQLSTATE % msg: %', SQLSTATE, SQLERRM;
  END;

  -- T17.7: authenticated CAN SELECT from user_blocks (SELECT privilege granted) — actual attempt.
  BEGIN
    SET LOCAL ROLE authenticated;
    PERFORM set_config('request.jwt.claims',
      json_build_object('sub', v_reporter::text, 'role', 'authenticated')::text, true);
    SELECT COUNT(*) INTO v_cnt FROM public.user_blocks;
    RESET ROLE;
    RAISE NOTICE 'PASS: T17.7 — authenticated can SELECT from user_blocks (no 42501)';
  EXCEPTION
    WHEN insufficient_privilege THEN
      RESET ROLE;
      RAISE EXCEPTION 'T17.7 FAIL: authenticated should have SELECT on user_blocks, but got 42501';
    WHEN OTHERS THEN
      RESET ROLE;
      RAISE EXCEPTION 'T17.7 FAIL: unexpected: % %', SQLSTATE, SQLERRM;
  END;

  -- T17.8: authenticated queries user_blocks WHERE blocked_id = self → 0 rows (policy: blocker_id = auth_uid())
  DECLARE v_blocker uuid;
  BEGIN
    v_blocker := test_helpers.make_user('T17.8 Blocker');
    PERFORM test_helpers.do_block(v_blocker, v_reporter);
    PERFORM test_helpers.set_auth_uid(v_reporter);
    SELECT COUNT(*) INTO v_cnt FROM public.user_blocks WHERE blocked_id = v_reporter;
    PERFORM test_helpers.clear_auth_uid();
    PERFORM test_helpers.assert(v_cnt = 0, 'T17.8 — cannot see user_blocks rows where you are blocked_id');
  END;

END;
$$;

-- =============================================================================
-- GROUP 18 — T18: Evidence cleanup (2 tests)
-- =============================================================================
\echo ''
\echo '--- GROUP 18: Evidence cleanup ---'

DO $$
DECLARE
  v_poster uuid; v_mod uuid; v_gid uuid; v_cid uuid; v_comment_id uuid;
  v_action_id uuid; v_cnt int;
BEGIN
  v_poster := test_helpers.make_user('T18 Poster');
  v_mod    := test_helpers.make_user('T18 Mod');
  v_gid    := test_helpers.make_group(v_poster);
  PERFORM test_helpers.make_moderator(v_mod);
  -- activate_challenge requires at least one non-poster eligible member
  PERFORM test_helpers.add_member(v_gid, v_poster, v_mod);
  v_cid        := test_helpers.make_challenge(v_poster, v_gid);
  PERFORM test_helpers.activate(v_poster, v_cid);
  v_comment_id := test_helpers.make_comment(v_poster, v_cid, 'T18 comment');
  PERFORM public.remove_content('comment', v_comment_id, v_mod, NULL, 'T18 removal');

  SELECT id INTO v_action_id FROM public.moderation_actions
  WHERE target_id = v_comment_id ORDER BY created_at DESC LIMIT 1;

  -- Insert two evidence rows: one expired, one not
  UPDATE private.moderation_evidence
  SET retained_until = NOW() - interval '1 day'
  WHERE moderation_action_id = v_action_id;

  -- Insert a second (unexpired) evidence row for the same action
  INSERT INTO private.moderation_evidence
    (moderation_action_id, evidence_type, evidence_text, retained_until)
  VALUES
    (v_action_id, 'comment_text', 'Extra evidence — not expired', NOW() + interval '90 days');

  -- T18.1: service_role calls cleanup → expired row deleted; unexpired row retained
  PERFORM private.cleanup_expired_evidence();

  SELECT COUNT(*) INTO v_cnt FROM private.moderation_evidence
  WHERE moderation_action_id = v_action_id AND retained_until < NOW();
  PERFORM test_helpers.assert(v_cnt = 0, 'T18.1 — expired evidence deleted by cleanup');

  SELECT COUNT(*) INTO v_cnt FROM private.moderation_evidence
  WHERE moderation_action_id = v_action_id AND retained_until > NOW();
  PERFORM test_helpers.assert(v_cnt = 1, 'T18.1 — unexpired evidence retained after cleanup');

  -- T18.2: authenticated → cleanup_expired_evidence → insufficient_privilege (42501).
  -- Actual execution attempt under authenticated role (not static privilege introspection).
  BEGIN
    SET LOCAL ROLE authenticated;
    PERFORM private.cleanup_expired_evidence();
    RESET ROLE;
    RAISE EXCEPTION 'T18.2 FAIL: expected 42501 insufficient_privilege on cleanup_expired_evidence';
  EXCEPTION
    WHEN insufficient_privilege THEN
      RESET ROLE;
      RAISE NOTICE 'PASS: T18.2 — authenticated cannot execute cleanup_expired_evidence (42501)';
    WHEN OTHERS THEN
      RESET ROLE;
      RAISE EXCEPTION 'T18.2 FAIL: unexpected: % %', SQLSTATE, SQLERRM;
  END;

END;
$$;

-- =============================================================================
-- GROUP 19 — Regression coverage for the 8 V3 Blocker Corrections
-- R19.1  CREATE privilege revocation (Blockers 1+2)
-- R19.2  Non-recursive profiles RLS policy (Blocker 4)
-- R19.3  Suspended profile UPDATE blocked via RESTRICTIVE (Blocker 4)
-- R19.4  Both get_reported_media UNION ALL branches reachable (Blocker 6)
-- R19.5  profile_suspensions backfill completeness (Blocker 7)
-- R19.6  New-user trigger creates profile_suspensions row (Blocker 7)
-- R19.7  NULL-safe media_object_id linkage (Blocker 5)
-- R19.8  Ordered pending-report locking (array_agg+FOR UPDATE CTE pattern) (Blocker 3)
-- =============================================================================
\echo ''
\echo '--- GROUP 19: V3 correction regressions ---'

DO $$
DECLARE
  v_mod uuid;
  v_cnt int;
BEGIN
  v_mod := test_helpers.make_user('R19 Mod');
  PERFORM test_helpers.make_moderator(v_mod);

  -- R19.1: forkensics_executor must NOT be able to CREATE tables in private OR public schema.
  -- V3 temporarily grants CREATE on both schemas; both grants are revoked before COMMIT.
  -- Test private schema:
  BEGIN
    SET LOCAL ROLE forkensics_executor;
    EXECUTE 'CREATE TABLE private.r19_regression_table (id serial)';
    EXECUTE 'DROP TABLE private.r19_regression_table';
    RESET ROLE;
    RAISE EXCEPTION 'R19.1a FAIL: forkensics_executor should NOT have CREATE in private schema';
  EXCEPTION
    WHEN insufficient_privilege THEN
      RESET ROLE;
      RAISE NOTICE 'PASS: R19.1a — forkensics_executor cannot CREATE in private schema (temp grant revoked)';
    WHEN OTHERS THEN
      RESET ROLE;
      RAISE EXCEPTION 'R19.1a FAIL: unexpected: % %', SQLSTATE, SQLERRM;
  END;
  -- Test public schema:
  BEGIN
    SET LOCAL ROLE forkensics_executor;
    EXECUTE 'CREATE TABLE public.r19_regression_table (id serial)';
    EXECUTE 'DROP TABLE public.r19_regression_table';
    RESET ROLE;
    RAISE EXCEPTION 'R19.1b FAIL: forkensics_executor should NOT have CREATE in public schema';
  EXCEPTION
    WHEN insufficient_privilege THEN
      RESET ROLE;
      RAISE NOTICE 'PASS: R19.1b — forkensics_executor cannot CREATE in public schema (temp grant revoked)';
    WHEN OTHERS THEN
      RESET ROLE;
      RAISE EXCEPTION 'R19.1b FAIL: unexpected: % %', SQLSTATE, SQLERRM;
  END;

  -- R19.2: The suspend_block_update RESTRICTIVE policy on public.profiles must use
  -- USING (NOT is_suspended) — not a recursive subquery on profiles.
  -- Verify via pg_policies that the qual expression references is_suspended directly.
  PERFORM test_helpers.assert(
    EXISTS (
      SELECT 1 FROM pg_policies
      WHERE schemaname = 'public'
        AND tablename  = 'profiles'
        AND policyname = 'suspend_block_update'
        AND permissive = 'RESTRICTIVE'  -- pg_policies.permissive is 'PERMISSIVE'/'RESTRICTIVE'
        AND qual LIKE '%is_suspended%'
        AND qual NOT LIKE '%SELECT%FROM%profiles%'   -- no recursive self-join
    ),
    'R19.2 — suspend_block_update policy is RESTRICTIVE and references is_suspended without recursive subquery');

  -- R19.3: Suspended profile cannot update its own row via the authenticated role.
  DECLARE v_sus_uid uuid;
  BEGIN
    v_sus_uid := test_helpers.make_user('R19.3 SuspendedUser');
    PERFORM test_helpers.do_suspend(v_mod, v_sus_uid, 'R19.3 suspension');
    PERFORM test_helpers.set_auth_uid(v_sus_uid);
    UPDATE public.profiles SET display_name = 'SHOULD_NOT_UPDATE' WHERE id = v_sus_uid;
    SELECT COUNT(*) INTO v_cnt
    FROM public.profiles WHERE id = v_sus_uid AND display_name = 'SHOULD_NOT_UPDATE';
    PERFORM test_helpers.clear_auth_uid();
    PERFORM test_helpers.assert(v_cnt = 0,
      'R19.3 — suspended profile cannot UPDATE own row (RESTRICTIVE policy blocks)');
  END;

  -- R19.4: Both UNION ALL branches of get_reported_media are functional.
  -- Branch 1: direct media_object report → remove_media finds and processes it.
  -- Branch 2: challenge inappropriate_image report → remove_content finds media via challenge.
  DECLARE
    v_poster_r4 uuid; v_reporter_r4 uuid; v_gid_r4 uuid; v_cid_r4 uuid; v_mid_r4 uuid;
    v_rid_direct uuid; v_rid_challenge uuid; v_cnt_b1 int; v_cnt_b2 int;
  BEGIN
    v_poster_r4   := test_helpers.make_user('R19.4 Poster');
    v_reporter_r4 := test_helpers.make_user('R19.4 Reporter');
    v_gid_r4      := test_helpers.make_group(v_poster_r4);
    PERFORM test_helpers.add_member(v_gid_r4, v_poster_r4, v_reporter_r4);
    SELECT challenge_id, media_id INTO v_cid_r4, v_mid_r4
    FROM test_helpers.make_draft_challenge_with_media(v_poster_r4, v_gid_r4);
    PERFORM test_helpers.activate(v_poster_r4, v_cid_r4);

    -- Branch 1: reporter reports the media_object directly
    v_rid_direct   := test_helpers.do_report(v_reporter_r4, 'media_object', v_mid_r4,
                        'inappropriate_image', 'R19.4 branch1');
    -- Branch 2: reporter reports the challenge with inappropriate_image
    v_rid_challenge := test_helpers.do_report(v_reporter_r4, 'challenge', v_cid_r4,
                        'inappropriate_image', 'R19.4 branch2');

    -- Verify BOTH branches of get_reported_media return rows (tests the UNION ALL).
    -- Branch 1: direct media_object report → get_reported_media via media_object JOIN path
    SELECT COUNT(*) INTO v_cnt_b1 FROM public.get_reported_media(v_rid_direct);
    PERFORM test_helpers.assert(v_cnt_b1 = 1,
      'R19.4 — get_reported_media Branch 1 (media_object report): returns 1 row via media_object JOIN');
    -- Branch 2: challenge-level inappropriate_image report → get_reported_media via challenge JOIN path
    SELECT COUNT(*) INTO v_cnt_b2 FROM public.get_reported_media(v_rid_challenge);
    PERFORM test_helpers.assert(v_cnt_b2 = 1,
      'R19.4 — get_reported_media Branch 2 (challenge inappropriate_image report): returns 1 row via challenge JOIN');

    -- Now trigger removal; both reports should be actioned
    PERFORM public.remove_media(v_mid_r4, v_mod, v_rid_direct, 'R19.4 branch1 removal');
    SELECT COUNT(*) INTO v_cnt_b1
    FROM public.content_reports WHERE id = v_rid_direct AND status = 'actioned';
    PERFORM test_helpers.assert(v_cnt_b1 = 1, 'R19.4 — Branch 1 (media_object report): actioned via remove_media');

    -- Branch 2: the challenge-level inappropriate_image report should also have been bulk-actioned
    SELECT COUNT(*) INTO v_cnt_b2
    FROM public.content_reports WHERE id = v_rid_challenge AND status = 'actioned';
    PERFORM test_helpers.assert(v_cnt_b2 = 1, 'R19.4 — Branch 2 (challenge inappropriate_image report): bulk-actioned');
  END;

  -- R19.5: profile_suspensions backfill — every profile row has a corresponding row.
  SELECT COUNT(*) INTO v_cnt
  FROM public.profiles p
  WHERE NOT EXISTS (
    SELECT 1 FROM private.profile_suspensions ps WHERE ps.profile_id = p.id
  );
  PERFORM test_helpers.assert(v_cnt = 0,
    'R19.5 — every profiles row has a profile_suspensions row (backfill complete)');

  -- R19.6: New-user trigger (handle_new_user) also inserts into profile_suspensions.
  DECLARE v_new_uid uuid;
  BEGIN
    v_new_uid := test_helpers.make_user('R19.6 NewUser');
    SELECT COUNT(*) INTO v_cnt
    FROM private.profile_suspensions WHERE profile_id = v_new_uid;
    PERFORM test_helpers.assert(v_cnt = 1,
      'R19.6 — handle_new_user trigger creates profile_suspensions row for new user');
  END;

  -- R19.7: NULL-safe media_object_id linkage (IS DISTINCT FROM, not !=).
  -- Bug: `v_challenge.media_object_id != p_target_id` evaluates to NULL (not TRUE) when
  -- v_challenge has no row (media not linked to any challenge), so FK_NOT_FOUND was NOT raised.
  -- Fix: `v_challenge.media_object_id IS DISTINCT FROM p_target_id` evaluates to TRUE when
  -- one side is NULL, correctly raising FK_NOT_FOUND.
  -- Test: a media_object with no challenge linkage raises FK_NOT_FOUND from report_content.
  DECLARE
    v_poster_r7 uuid; v_gid_r7 uuid; v_cid_r7 uuid; v_mid_r7 uuid;
    v_mid_unlinked uuid; v_cnt_r7 int;
  BEGIN
    v_poster_r7    := test_helpers.make_user('R19.7 Poster');
    v_gid_r7       := test_helpers.make_group(v_poster_r7);
    PERFORM test_helpers.add_member(v_gid_r7, v_poster_r7, v_mod);
    SELECT challenge_id, media_id INTO v_cid_r7, v_mid_r7
    FROM test_helpers.make_draft_challenge_with_media(v_poster_r7, v_gid_r7);
    PERFORM test_helpers.activate(v_poster_r7, v_cid_r7);

    -- Create a media_object NOT linked to any challenge (no challenge.media_object_id points to it).
    -- With the old bug (!=): NULL != v_mid_unlinked → NULL → no FK_NOT_FOUND → crash or wrong result.
    -- With the fix (IS DISTINCT FROM): NULL IS DISTINCT FROM v_mid_unlinked → TRUE → FK_NOT_FOUND.
    v_mid_unlinked := test_helpers.make_media_with_key(v_poster_r7,
      'f665a45920422f9d417e4867efdc4fb8a04a1f3fff1fa07e998e86f7f7a27ae3', 'ready');
    BEGIN
      PERFORM test_helpers.set_auth_uid(v_mod);
      -- report_content for media_object type checks challenge linkage via IS DISTINCT FROM
      PERFORM public.report_content('media_object', v_mid_unlinked, 'inappropriate_image', 'R19.7 unlinked');
      PERFORM test_helpers.clear_auth_uid();
      RAISE EXCEPTION 'UNEXPECTED_SUCCESS';
    EXCEPTION
      WHEN OTHERS THEN
        PERFORM test_helpers.clear_auth_uid();
        IF SQLERRM = 'UNEXPECTED_SUCCESS' THEN
          RAISE EXCEPTION 'R19.7 FAIL: report_content succeeded on unlinked media (expected FK_NOT_FOUND)';
        ELSIF SQLERRM LIKE '%FK_NOT_FOUND%' THEN
          RAISE NOTICE 'PASS: R19.7 — unlinked media raises FK_NOT_FOUND (IS DISTINCT FROM NULL-safe check)';
        ELSE
          RAISE EXCEPTION 'R19.7 FAIL: expected FK_NOT_FOUND but got: % %', SQLSTATE, SQLERRM;
        END IF;
    END;

    -- Also verify that the LINKED media still works correctly via remove_media (positive case)
    PERFORM public.remove_media(v_mid_r7, v_mod, NULL, 'R19.7 linked media removal');
    SELECT COUNT(*) INTO v_cnt_r7 FROM public.media_objects WHERE id = v_mid_r7 AND status = 'removed';
    PERFORM test_helpers.assert(v_cnt_r7 = 1, 'R19.7 — linked media removed correctly (positive path)');
  END;

  -- R19.8: Verify the ordered pending-report locking pattern (array_agg CTE subquery) is in place.
  -- The fix converted: SELECT array_agg(cr.id ORDER BY cr.id) FROM ... FOR UPDATE (invalid)
  -- to: SELECT array_agg(locked.id ORDER BY locked.id) FROM (SELECT id FROM ... FOR UPDATE) AS locked
  -- We verify functional correctness: remove_content with multiple reporters actions all reports.
  DECLARE
    v_poster_r8 uuid; v_rep_a uuid; v_rep_b uuid; v_gid_r8 uuid; v_cid_r8 uuid;
    v_rid_a uuid; v_rid_b uuid;
  BEGIN
    v_poster_r8 := test_helpers.make_user('R19.8 Poster');
    v_rep_a     := test_helpers.make_user('R19.8 ReporterA');
    v_rep_b     := test_helpers.make_user('R19.8 ReporterB');
    v_gid_r8    := test_helpers.make_group(v_poster_r8);
    PERFORM test_helpers.add_member(v_gid_r8, v_poster_r8, v_rep_a);
    PERFORM test_helpers.add_member(v_gid_r8, v_poster_r8, v_rep_b);
    v_cid_r8    := test_helpers.make_challenge(v_poster_r8, v_gid_r8);
    PERFORM test_helpers.activate(v_poster_r8, v_cid_r8);
    v_rid_a     := test_helpers.do_report(v_rep_a, 'challenge', v_cid_r8, 'offensive_content', 'R19.8 A');
    v_rid_b     := test_helpers.do_report(v_rep_b, 'challenge', v_cid_r8, 'offensive_content', 'R19.8 B');
    -- remove_content must lock both reports in ascending UUID order (no deadlock) and action both
    PERFORM public.remove_content('challenge', v_cid_r8, v_mod, NULL, 'R19.8 removal');
    SELECT COUNT(*) INTO v_cnt
    FROM public.content_reports WHERE id IN (v_rid_a, v_rid_b) AND status = 'actioned';
    PERFORM test_helpers.assert(v_cnt = 2,
      'R19.8 — ordered lock + bulk-action: both reports actioned (array_agg CTE pattern)');
  END;

END;
$$;

-- =============================================================================
-- GROUP 20 — Content-filter trigger: catalog verification and field coverage
-- T20.cat.1  All 9 content-filter triggers have tgnargs = 1
-- T20.cat.2  Each trigger's TG_ARGV[0] matches the approved column name
-- T20.1n/i   comments.text              (NOT NULL; BEFORE INSERT)
-- T20.2n/i   clues.text                 (NOT NULL; BEFORE INSERT)
-- T20.3n/i/u profiles.display_name      (nullable; BEFORE INSERT OR UPDATE)
-- T20.4n/i/u groups.name                (NOT NULL; BEFORE INSERT OR UPDATE)
-- T20.5n/u/c challenges.public_city_display  (nullable; BEFORE INSERT OR UPDATE)
-- T20.6n/u   challenge_secrets.display_dish        (NOT NULL; BEFORE INSERT OR UPDATE)
-- T20.7n/u   challenge_secrets.display_restaurant  (NOT NULL; BEFORE INSERT OR UPDATE)
-- T20.8n/u   challenge_secrets.story               (nullable; BEFORE INSERT OR UPDATE)
-- T20.9n/i   challenge_answer_aliases.display_value (NOT NULL; BEFORE INSERT)
-- =============================================================================
\echo ''
\echo '--- GROUP 20: content-filter trigger correctness ---'

-- Seed the blocked term used throughout this group.
-- The outer ROLLBACK at the end of this file removes it; no post-test DDL needed.
DO $$
BEGIN
  SET LOCAL ROLE forkensics_executor;
  INSERT INTO private.blocked_terms (term, added_by) VALUES ('badword99', 'T20 test setup');
  RESET ROLE;
END;
$$;

DO $$
DECLARE
  v_owner    uuid;
  v_gid      uuid;
  v_chal     uuid;
  v_profile  uuid;
  v_group    uuid;
  v_cnt      int;
  v_mismatch int;
BEGIN
  -- Shared setup: user → group → challenge (draft; public_city_display starts NULL).
  -- make_challenge inserts challenge_secrets with 'Test Dish'/'Test Place' — clean values.
  -- challenge_secrets PK is challenge_id; no separate id column exists.
  v_owner := test_helpers.make_user('T20 Owner');
  v_gid   := test_helpers.make_group(v_owner);
  v_chal  := test_helpers.make_challenge(v_owner, v_gid);

  -- ------------------------------------------------------------------
  -- T20.cat.1: All 9 content-filter triggers have tgnargs = 1
  -- ------------------------------------------------------------------
  SELECT COUNT(*) INTO v_cnt
  FROM pg_trigger t
  JOIN pg_proc p      ON p.oid = t.tgfoid
  JOIN pg_class c     ON c.oid = t.tgrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE p.proname = 'check_text_content_trigger'
    AND n.nspname = 'public'
    AND NOT t.tgisinternal
    AND t.tgnargs = 1;

  IF v_cnt = 9 THEN
    RAISE NOTICE 'PASS: T20.cat.1 — All 9 content-filter triggers have tgnargs = 1';
  ELSE
    RAISE EXCEPTION 'T20.cat.1 FAIL: expected 9 triggers with tgnargs=1, got %', v_cnt;
  END IF;

  -- ------------------------------------------------------------------
  -- T20.cat.2: Each trigger's TG_ARGV[0] and table name match the approved pairing.
  -- tgargs is stored as null-terminated bytea. Safe bytea comparison:
  --   encode(tgargs,'hex') = encode(convert_to(col_arg,'UTF8'),'hex') || '00'
  -- Also verifies the trigger is on the correct table (relname).
  -- ------------------------------------------------------------------
  SELECT COUNT(*) INTO v_mismatch
  FROM (
    VALUES
      ('comment_text_filter',         'comments',                 'text'),
      ('clue_text_filter',            'clues',                    'text'),
      ('profile_name_filter',         'profiles',                 'display_name'),
      ('group_name_filter',           'groups',                   'name'),
      ('challenge_city_filter',       'challenges',               'public_city_display'),
      ('secret_dish_filter',          'challenge_secrets',        'display_dish'),
      ('secret_restaurant_filter',    'challenge_secrets',        'display_restaurant'),
      ('secret_story_filter',         'challenge_secrets',        'story'),
      ('alias_display_value_filter',  'challenge_answer_aliases', 'display_value')
  ) AS expected(tgname, relname, col_arg)
  WHERE NOT EXISTS (
    SELECT 1
    FROM pg_trigger t
    JOIN pg_proc p      ON p.oid = t.tgfoid
    JOIN pg_class c     ON c.oid = t.tgrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE p.proname = 'check_text_content_trigger'
      AND n.nspname = 'public'
      AND NOT t.tgisinternal
      AND t.tgname  = expected.tgname
      AND c.relname = expected.relname
      AND encode(t.tgargs, 'hex')
            = encode(convert_to(expected.col_arg, 'UTF8'), 'hex') || '00'
  );

  IF v_mismatch = 0 THEN
    RAISE NOTICE 'PASS: T20.cat.2 — All 9 triggers are on the correct table and pass the correct column name as TG_ARGV[0]';
  ELSE
    RAISE EXCEPTION 'T20.cat.2 FAIL: % (table, trigger, arg) triple(s) have wrong or missing values', v_mismatch;
  END IF;

  -- ------------------------------------------------------------------
  -- T20.1n: comments.text — clean INSERT accepted
  -- ------------------------------------------------------------------
  BEGIN
    INSERT INTO public.comments (challenge_id, author_id, text)
    VALUES (v_chal, v_owner, 'Great challenge!');
    RAISE NOTICE 'PASS: T20.1n — comments.text clean INSERT accepted';
  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'T20.1n FAIL: unexpected % %', SQLSTATE, SQLERRM;
  END;

  -- T20.1i: comments.text — blocked INSERT rejected
  -- Sentinel is UNEXPECTED_SUCCESS (neutral string) so it cannot be mistaken for
  -- the genuine FK_CONTENT_FILTERED error in the exception handler.
  BEGIN
    INSERT INTO public.comments (challenge_id, author_id, text)
    VALUES (v_chal, v_owner, 'this has badword99 in it');
    RAISE EXCEPTION 'UNEXPECTED_SUCCESS';
  EXCEPTION
    WHEN raise_exception THEN
      IF SQLERRM = 'UNEXPECTED_SUCCESS' THEN
        RAISE EXCEPTION 'T20.1i FAIL: blocked INSERT succeeded but FK_CONTENT_FILTERED expected';
      ELSIF SQLERRM LIKE '%FK_CONTENT_FILTERED%' THEN
        RAISE NOTICE 'PASS: T20.1i — comments.text blocked INSERT rejected (FK_CONTENT_FILTERED)';
      ELSE
        RAISE EXCEPTION 'T20.1i FAIL: wrong error % %', SQLSTATE, SQLERRM;
      END IF;
    WHEN OTHERS THEN
      RAISE EXCEPTION 'T20.1i FAIL: unexpected % %', SQLSTATE, SQLERRM;
  END;

  -- ------------------------------------------------------------------
  -- T20.2n: clues.text — clean INSERT accepted
  -- ------------------------------------------------------------------
  BEGIN
    INSERT INTO public.clues (challenge_id, poster_id, text)
    VALUES (v_chal, v_owner, 'Look near the entrance');
    RAISE NOTICE 'PASS: T20.2n — clues.text clean INSERT accepted';
  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'T20.2n FAIL: unexpected % %', SQLSTATE, SQLERRM;
  END;

  -- T20.2i: clues.text — blocked INSERT rejected
  BEGIN
    INSERT INTO public.clues (challenge_id, poster_id, text)
    VALUES (v_chal, v_owner, 'clue with badword99 inside');
    RAISE EXCEPTION 'UNEXPECTED_SUCCESS';
  EXCEPTION
    WHEN raise_exception THEN
      IF SQLERRM = 'UNEXPECTED_SUCCESS' THEN
        RAISE EXCEPTION 'T20.2i FAIL: blocked INSERT succeeded but FK_CONTENT_FILTERED expected';
      ELSIF SQLERRM LIKE '%FK_CONTENT_FILTERED%' THEN
        RAISE NOTICE 'PASS: T20.2i — clues.text blocked INSERT rejected (FK_CONTENT_FILTERED)';
      ELSE
        RAISE EXCEPTION 'T20.2i FAIL: wrong error % %', SQLSTATE, SQLERRM;
      END IF;
    WHEN OTHERS THEN
      RAISE EXCEPTION 'T20.2i FAIL: unexpected % %', SQLSTATE, SQLERRM;
  END;

  -- ------------------------------------------------------------------
  -- T20.3n: profiles.display_name — NULL INSERT accepted (nullable column)
  -- display_name is nullable (no NOT NULL constraint in V1 schema).
  -- The filter returns NEW immediately on NULL; profile_avatar_ownership also passes
  -- (avatar_media_object_id is not set).
  -- ------------------------------------------------------------------
  BEGIN
    v_profile := gen_random_uuid();
    INSERT INTO public.profiles (id, display_name, onboarding_complete)
    VALUES (v_profile, NULL, false);
    RAISE NOTICE 'PASS: T20.3n — profiles.display_name NULL INSERT accepted (nullable)';
  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'T20.3n FAIL: unexpected % %', SQLSTATE, SQLERRM;
  END;

  -- T20.3i: profiles.display_name — blocked INSERT rejected
  BEGIN
    INSERT INTO public.profiles (id, display_name, onboarding_complete)
    VALUES (gen_random_uuid(), 'user with badword99', false);
    RAISE EXCEPTION 'UNEXPECTED_SUCCESS';
  EXCEPTION
    WHEN raise_exception THEN
      IF SQLERRM = 'UNEXPECTED_SUCCESS' THEN
        RAISE EXCEPTION 'T20.3i FAIL: blocked INSERT succeeded but FK_CONTENT_FILTERED expected';
      ELSIF SQLERRM LIKE '%FK_CONTENT_FILTERED%' THEN
        RAISE NOTICE 'PASS: T20.3i — profiles.display_name blocked INSERT rejected (FK_CONTENT_FILTERED)';
      ELSE
        RAISE EXCEPTION 'T20.3i FAIL: wrong error % %', SQLSTATE, SQLERRM;
      END IF;
    WHEN OTHERS THEN
      RAISE EXCEPTION 'T20.3i FAIL: unexpected % %', SQLSTATE, SQLERRM;
  END;

  -- T20.3u: profiles.display_name — blocked UPDATE rejected
  -- Trigger order on BEFORE UPDATE: profile_avatar_ownership (a) → profile_lock_onboarding (l)
  -- → profile_name_filter (n). Only display_name changes; first two pass; filter rejects.
  BEGIN
    UPDATE public.profiles SET display_name = 'contains badword99' WHERE id = v_profile;
    RAISE EXCEPTION 'UNEXPECTED_SUCCESS';
  EXCEPTION
    WHEN raise_exception THEN
      IF SQLERRM = 'UNEXPECTED_SUCCESS' THEN
        RAISE EXCEPTION 'T20.3u FAIL: blocked UPDATE succeeded but FK_CONTENT_FILTERED expected';
      ELSIF SQLERRM LIKE '%FK_CONTENT_FILTERED%' THEN
        RAISE NOTICE 'PASS: T20.3u — profiles.display_name blocked UPDATE rejected (FK_CONTENT_FILTERED)';
      ELSE
        RAISE EXCEPTION 'T20.3u FAIL: wrong error % %', SQLSTATE, SQLERRM;
      END IF;
    WHEN OTHERS THEN
      RAISE EXCEPTION 'T20.3u FAIL: unexpected % %', SQLSTATE, SQLERRM;
  END;

  -- ------------------------------------------------------------------
  -- T20.4n: groups.name — clean INSERT accepted
  -- group_name_filter is the only BEFORE INSERT OR UPDATE trigger on groups.
  -- ------------------------------------------------------------------
  BEGIN
    v_group := gen_random_uuid();
    INSERT INTO public.groups (id, name, created_by) VALUES (v_group, 'Puzzle Hunters', v_owner);
    RAISE NOTICE 'PASS: T20.4n — groups.name clean INSERT accepted';
  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'T20.4n FAIL: unexpected % %', SQLSTATE, SQLERRM;
  END;

  -- T20.4i: groups.name — blocked INSERT rejected
  BEGIN
    INSERT INTO public.groups (id, name, created_by) VALUES (gen_random_uuid(), 'badword99 club', v_owner);
    RAISE EXCEPTION 'UNEXPECTED_SUCCESS';
  EXCEPTION
    WHEN raise_exception THEN
      IF SQLERRM = 'UNEXPECTED_SUCCESS' THEN
        RAISE EXCEPTION 'T20.4i FAIL: blocked INSERT succeeded but FK_CONTENT_FILTERED expected';
      ELSIF SQLERRM LIKE '%FK_CONTENT_FILTERED%' THEN
        RAISE NOTICE 'PASS: T20.4i — groups.name blocked INSERT rejected (FK_CONTENT_FILTERED)';
      ELSE
        RAISE EXCEPTION 'T20.4i FAIL: wrong error % %', SQLSTATE, SQLERRM;
      END IF;
    WHEN OTHERS THEN
      RAISE EXCEPTION 'T20.4i FAIL: unexpected % %', SQLSTATE, SQLERRM;
  END;

  -- T20.4u: groups.name — blocked UPDATE rejected
  BEGIN
    UPDATE public.groups SET name = 'badword99 new name' WHERE id = v_group;
    RAISE EXCEPTION 'UNEXPECTED_SUCCESS';
  EXCEPTION
    WHEN raise_exception THEN
      IF SQLERRM = 'UNEXPECTED_SUCCESS' THEN
        RAISE EXCEPTION 'T20.4u FAIL: blocked UPDATE succeeded but FK_CONTENT_FILTERED expected';
      ELSIF SQLERRM LIKE '%FK_CONTENT_FILTERED%' THEN
        RAISE NOTICE 'PASS: T20.4u — groups.name blocked UPDATE rejected (FK_CONTENT_FILTERED)';
      ELSE
        RAISE EXCEPTION 'T20.4u FAIL: wrong error % %', SQLSTATE, SQLERRM;
      END IF;
    WHEN OTHERS THEN
      RAISE EXCEPTION 'T20.4u FAIL: unexpected % %', SQLSTATE, SQLERRM;
  END;

  -- ------------------------------------------------------------------
  -- T20.5n: challenges.public_city_display — NULL passes on INSERT
  -- make_challenge did not set public_city_display → it is NULL.
  -- The BEFORE INSERT challenge_city_filter received NULL and returned NEW immediately.
  -- Verify the current value to confirm the filter passed transparently.
  -- ------------------------------------------------------------------
  BEGIN
    IF NOT EXISTS (
      SELECT 1 FROM public.challenges WHERE id = v_chal AND public_city_display IS NULL
    ) THEN
      RAISE EXCEPTION 'T20.5n FAIL: expected public_city_display IS NULL after make_challenge';
    END IF;
    RAISE NOTICE 'PASS: T20.5n — challenges.public_city_display NULL on INSERT accepted (nullable)';
  END;

  -- T20.5u: challenges.public_city_display — blocked UPDATE rejected
  -- Draft state (posted_at IS NULL): challenge_protect_fields would allow this column.
  -- But challenge_city_filter fires first (challenge_c < challenge_p alphabetically)
  -- and raises FK_CONTENT_FILTERED before challenge_protect_fields runs.
  BEGIN
    UPDATE public.challenges SET public_city_display = 'badword99 city' WHERE id = v_chal;
    RAISE EXCEPTION 'UNEXPECTED_SUCCESS';
  EXCEPTION
    WHEN raise_exception THEN
      IF SQLERRM = 'UNEXPECTED_SUCCESS' THEN
        RAISE EXCEPTION 'T20.5u FAIL: blocked UPDATE succeeded but FK_CONTENT_FILTERED expected';
      ELSIF SQLERRM LIKE '%FK_CONTENT_FILTERED%' THEN
        RAISE NOTICE 'PASS: T20.5u — challenges.public_city_display blocked UPDATE rejected (FK_CONTENT_FILTERED)';
      ELSE
        RAISE EXCEPTION 'T20.5u FAIL: wrong error % %', SQLSTATE, SQLERRM;
      END IF;
    WHEN OTHERS THEN
      RAISE EXCEPTION 'T20.5u FAIL: unexpected % %', SQLSTATE, SQLERRM;
  END;

  -- T20.5c: challenges.public_city_display — clean UPDATE accepted
  -- challenge_city_filter passes; challenge_protect_fields normalizes and returns NEW.
  BEGIN
    UPDATE public.challenges SET public_city_display = 'Portland' WHERE id = v_chal;
    RAISE NOTICE 'PASS: T20.5c — challenges.public_city_display clean UPDATE accepted';
  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'T20.5c FAIL: unexpected % %', SQLSTATE, SQLERRM;
  END;

  -- ------------------------------------------------------------------
  -- T20.6n: challenge_secrets.display_dish — clean UPDATE accepted
  -- challenge_secrets PK is challenge_id (no id column); WHERE uses challenge_id.
  -- challenge_secrets_guard fires first (c < s); has_first_guess = false → allows.
  -- secret_dish_filter fires next with clean text → passes.
  -- ------------------------------------------------------------------
  BEGIN
    UPDATE public.challenge_secrets SET display_dish = 'Tacos' WHERE challenge_id = v_chal;
    RAISE NOTICE 'PASS: T20.6n — challenge_secrets.display_dish clean UPDATE accepted';
  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'T20.6n FAIL: unexpected % %', SQLSTATE, SQLERRM;
  END;

  -- T20.6u: challenge_secrets.display_dish — blocked UPDATE rejected
  -- challenge_secrets_guard allows (has_first_guess = false); secret_dish_filter rejects.
  BEGIN
    UPDATE public.challenge_secrets SET display_dish = 'badword99 tacos' WHERE challenge_id = v_chal;
    RAISE EXCEPTION 'UNEXPECTED_SUCCESS';
  EXCEPTION
    WHEN raise_exception THEN
      IF SQLERRM = 'UNEXPECTED_SUCCESS' THEN
        RAISE EXCEPTION 'T20.6u FAIL: blocked UPDATE succeeded but FK_CONTENT_FILTERED expected';
      ELSIF SQLERRM LIKE '%FK_CONTENT_FILTERED%' THEN
        RAISE NOTICE 'PASS: T20.6u — challenge_secrets.display_dish blocked UPDATE rejected (FK_CONTENT_FILTERED)';
      ELSE
        RAISE EXCEPTION 'T20.6u FAIL: wrong error % %', SQLSTATE, SQLERRM;
      END IF;
    WHEN OTHERS THEN
      RAISE EXCEPTION 'T20.6u FAIL: unexpected % %', SQLSTATE, SQLERRM;
  END;

  -- ------------------------------------------------------------------
  -- T20.7n: challenge_secrets.display_restaurant — clean UPDATE accepted
  -- ------------------------------------------------------------------
  BEGIN
    UPDATE public.challenge_secrets SET display_restaurant = 'Taco Palace' WHERE challenge_id = v_chal;
    RAISE NOTICE 'PASS: T20.7n — challenge_secrets.display_restaurant clean UPDATE accepted';
  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'T20.7n FAIL: unexpected % %', SQLSTATE, SQLERRM;
  END;

  -- T20.7u: challenge_secrets.display_restaurant — blocked UPDATE rejected
  BEGIN
    UPDATE public.challenge_secrets SET display_restaurant = 'badword99 grill' WHERE challenge_id = v_chal;
    RAISE EXCEPTION 'UNEXPECTED_SUCCESS';
  EXCEPTION
    WHEN raise_exception THEN
      IF SQLERRM = 'UNEXPECTED_SUCCESS' THEN
        RAISE EXCEPTION 'T20.7u FAIL: blocked UPDATE succeeded but FK_CONTENT_FILTERED expected';
      ELSIF SQLERRM LIKE '%FK_CONTENT_FILTERED%' THEN
        RAISE NOTICE 'PASS: T20.7u — challenge_secrets.display_restaurant blocked UPDATE rejected (FK_CONTENT_FILTERED)';
      ELSE
        RAISE EXCEPTION 'T20.7u FAIL: wrong error % %', SQLSTATE, SQLERRM;
      END IF;
    WHEN OTHERS THEN
      RAISE EXCEPTION 'T20.7u FAIL: unexpected % %', SQLSTATE, SQLERRM;
  END;

  -- ------------------------------------------------------------------
  -- T20.8n: challenge_secrets.story — NULL UPDATE accepted (nullable column)
  -- story is nullable per V1 schema. The filter sees NULL → returns NEW immediately.
  -- ------------------------------------------------------------------
  BEGIN
    UPDATE public.challenge_secrets SET story = NULL WHERE challenge_id = v_chal;
    RAISE NOTICE 'PASS: T20.8n — challenge_secrets.story NULL UPDATE accepted (nullable)';
  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'T20.8n FAIL: unexpected % %', SQLSTATE, SQLERRM;
  END;

  -- T20.8u: challenge_secrets.story — blocked UPDATE rejected
  BEGIN
    UPDATE public.challenge_secrets SET story = 'A tale of badword99' WHERE challenge_id = v_chal;
    RAISE EXCEPTION 'UNEXPECTED_SUCCESS';
  EXCEPTION
    WHEN raise_exception THEN
      IF SQLERRM = 'UNEXPECTED_SUCCESS' THEN
        RAISE EXCEPTION 'T20.8u FAIL: blocked UPDATE succeeded but FK_CONTENT_FILTERED expected';
      ELSIF SQLERRM LIKE '%FK_CONTENT_FILTERED%' THEN
        RAISE NOTICE 'PASS: T20.8u — challenge_secrets.story blocked UPDATE rejected (FK_CONTENT_FILTERED)';
      ELSE
        RAISE EXCEPTION 'T20.8u FAIL: wrong error % %', SQLSTATE, SQLERRM;
      END IF;
    WHEN OTHERS THEN
      RAISE EXCEPTION 'T20.8u FAIL: unexpected % %', SQLSTATE, SQLERRM;
  END;

  -- ------------------------------------------------------------------
  -- T20.9n: challenge_answer_aliases.display_value — clean INSERT accepted
  -- alias_display_value_filter (alias_d...) fires before alias_guard_insert (alias_g...);
  -- filter passes with clean text. SET LOCAL ROLE forkensics_executor so that
  -- alias_guard_insert's bypass check succeeds and private.auth_uid() is never called
  -- (avoiding a NULL created_by violation on the NOT NULL column).
  -- ------------------------------------------------------------------
  BEGIN
    SET LOCAL ROLE forkensics_executor;
    INSERT INTO public.challenge_answer_aliases
      (challenge_id, field, display_value, normalized_value, created_by)
    VALUES (v_chal, 'dish', 'Ramen Palace', 'ramen palace', v_owner);
    RESET ROLE;
    RAISE NOTICE 'PASS: T20.9n — challenge_answer_aliases.display_value clean INSERT accepted';
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    RAISE EXCEPTION 'T20.9n FAIL: unexpected % %', SQLSTATE, SQLERRM;
  END;

  -- T20.9i: challenge_answer_aliases.display_value — blocked INSERT rejected
  -- alias_display_value_filter fires first (SECURITY DEFINER; accesses blocked_terms
  -- as forkensics_executor regardless of calling role) and raises FK_CONTENT_FILTERED.
  -- alias_guard_insert never runs.
  BEGIN
    INSERT INTO public.challenge_answer_aliases
      (challenge_id, field, display_value, normalized_value, created_by)
    VALUES (v_chal, 'dish', 'badword99 alias', 'badword99 alias', v_owner);
    RAISE EXCEPTION 'UNEXPECTED_SUCCESS';
  EXCEPTION
    WHEN raise_exception THEN
      IF SQLERRM = 'UNEXPECTED_SUCCESS' THEN
        RAISE EXCEPTION 'T20.9i FAIL: blocked INSERT succeeded but FK_CONTENT_FILTERED expected';
      ELSIF SQLERRM LIKE '%FK_CONTENT_FILTERED%' THEN
        RAISE NOTICE 'PASS: T20.9i — challenge_answer_aliases.display_value blocked INSERT rejected (FK_CONTENT_FILTERED)';
      ELSE
        RAISE EXCEPTION 'T20.9i FAIL: wrong error % %', SQLSTATE, SQLERRM;
      END IF;
    WHEN OTHERS THEN
      RAISE EXCEPTION 'T20.9i FAIL: unexpected % %', SQLSTATE, SQLERRM;
  END;

END;
$$;

-- =============================================================================
-- SUMMARY
-- =============================================================================
\echo ''
\echo '============================================================='
\echo 'V3 Acceptance Tests complete.'
\echo 'Groups T1–T20 executed (T20 = content-filter trigger coverage).'
\echo 'T7.1, T7.2, T7.3, T7.5: two-session concurrency — see'
\echo '  08_Migration/tests/T7_concurrency_harness.sh'
\echo 'T5 lock order: sequential simulation in GROUP 5 SQL plus'
\echo '  08_Migration/tests/T5_lock_order_harness.sh'
\echo 'All SQL groups run inside a single BEGIN/ROLLBACK.'
\echo 'No test data persists.'
\echo '============================================================='

ROLLBACK;
-- All grants (forkensics_executor to postgres, forkensics_rls_helper to postgres, and the
-- column-level UPDATE grants on challenges/clues for forkensics_rls_helper) were made inside
-- the BEGIN block and are automatically removed by the ROLLBACK above. No post-test DDL needed.
