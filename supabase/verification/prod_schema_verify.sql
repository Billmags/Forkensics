-- =============================================================================
-- prod_schema_verify.sql
-- Forkensics V1 — Read-only schema verification
--
-- Rebuilt directly from V1__initial_schema.sql (frozen 2026-08-07).
-- Every DO block raises an exception on mismatch; psql --set ON_ERROR_STOP=on
-- aborts on the first failure. No data is written or deleted.
--
-- Usage:
--   psql --set ON_ERROR_STOP=on -f supabase/verification/prod_schema_verify.sql
--   (connection via PG* environment variables — no password embedded in command)
-- =============================================================================

\echo '=== Forkensics V1 Schema Verification ==='

-- -----------------------------------------------------------------------------
-- 1. Migration history
-- -----------------------------------------------------------------------------
\echo '1. Migration history'
DO $$
DECLARE v_count int;
BEGIN
  -- supabase_migrations schema only exists when Supabase tooling (db push / db reset)
  -- was used to apply the migration. Local manual installs via psql skip this check.
  -- On cloud deployments the schema MUST exist and contain the V1 entry.
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.schemata
    WHERE schema_name = 'supabase_migrations'
  ) THEN
    RAISE NOTICE 'SKIP: supabase_migrations schema absent — manually applied database. Confirm with supabase migration list after db push.';
    RETURN;
  END IF;

  SELECT COUNT(*) INTO v_count
  FROM supabase_migrations.schema_migrations
  WHERE version = '20260807000000';
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'FAIL: V1 migration not recorded in supabase_migrations.schema_migrations';
  END IF;
  RAISE NOTICE 'PASS: V1 migration recorded in schema_migrations';
END;
$$;

-- -----------------------------------------------------------------------------
-- 2. Tables (public schema)
-- -----------------------------------------------------------------------------
\echo '2. Tables — public schema'
DO $$
DECLARE missing text;
BEGIN
  SELECT string_agg(tbl, ', ' ORDER BY tbl) INTO missing
  FROM (VALUES
    ('profiles'), ('rules_versions'), ('media_objects'),
    ('groups'), ('group_members'), ('group_invites'),
    ('challenges'), ('challenge_secrets'), ('challenge_answer_aliases'),
    ('eligible_participants'), ('exclusion_events'), ('clues'),
    ('guess_attempts'), ('correction_events'),
    ('score_runs'), ('guess_judgments'), ('score_events'),
    ('comments'), ('reactions')
  ) AS e(tbl)
  WHERE NOT EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'public' AND table_name = e.tbl
  );
  IF missing IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL: Missing public tables: %', missing;
  END IF;
  RAISE NOTICE 'PASS: All 19 public tables present';
END;
$$;

-- -----------------------------------------------------------------------------
-- 3. Tables (private schema)
-- -----------------------------------------------------------------------------
\echo '3. Tables — private schema'
DO $$
DECLARE missing text;
BEGIN
  SELECT string_agg(tbl, ', ' ORDER BY tbl) INTO missing
  FROM (VALUES
    ('media_storage_keys'), ('profile_archive'), ('deletion_log')
  ) AS e(tbl)
  WHERE NOT EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'private' AND table_name = e.tbl
  );
  IF missing IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL: Missing private tables: %', missing;
  END IF;
  RAISE NOTICE 'PASS: All 3 private tables present';
END;
$$;

-- -----------------------------------------------------------------------------
-- 4. View
-- -----------------------------------------------------------------------------
\echo '4. View'
DO $$
DECLARE v_count int;
BEGIN
  SELECT COUNT(*) INTO v_count
  FROM information_schema.views
  WHERE table_schema = 'public' AND table_name = 'current_score_events';
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'FAIL: View public.current_score_events not found';
  END IF;
  RAISE NOTICE 'PASS: View current_score_events present';
END;
$$;

-- -----------------------------------------------------------------------------
-- 5. Triggers
-- -----------------------------------------------------------------------------
\echo '5. Triggers'
DO $$
DECLARE missing text;
BEGIN
  -- Triggers on public schema tables (queryable via information_schema)
  SELECT string_agg(e.trg || ' ON ' || e.tbl, ', ' ORDER BY e.tbl, e.trg) INTO missing
  FROM (VALUES
    ('challenges',              'challenge_create_fields'),
    ('challenges',              'challenge_protect_fields'),
    ('challenge_secrets',       'challenge_secrets_guard'),
    ('challenge_secrets',       'challenge_secrets_timestamps'),
    ('challenge_answer_aliases','alias_guard_insert'),
    ('challenge_answer_aliases','alias_guard_update'),
    ('guess_attempts',          'guess_receipt'),
    ('guess_judgments',         'guess_judgment_consistency'),
    ('score_events',            'score_event_consistency'),
    ('rules_versions',          'rules_versions_immutable'),
    ('comments',                'comment_update_guard'),
    ('comments',                'comments_timestamp'),
    ('clues',                   'clues_timestamp'),
    ('reactions',               'reactions_timestamp'),
    ('exclusion_events',        'exclusion_events_timestamp'),
    ('exclusion_events',        'exclusion_enforce'),
    ('profiles',                'profile_lock_onboarding'),
    ('profiles',                'profile_avatar_ownership')
  ) AS e(tbl, trg)
  WHERE NOT EXISTS (
    SELECT 1 FROM information_schema.triggers t
    WHERE t.event_object_schema = 'public'
      AND t.event_object_table  = e.tbl
      AND t.trigger_name        = e.trg
  );
  IF missing IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL: Missing triggers: %', missing;
  END IF;
  RAISE NOTICE 'PASS: All 18 public-table triggers present';
END;
$$;

-- auth.users trigger (not in information_schema for auth schema)
DO $$
DECLARE v_count int;
BEGIN
  SELECT COUNT(*) INTO v_count
  FROM pg_trigger t
  JOIN pg_class c ON c.oid = t.tgrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'auth'
    AND c.relname = 'users'
    AND t.tgname  = 'on_auth_user_created'
    AND NOT t.tgisinternal;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'FAIL: Trigger on_auth_user_created on auth.users not found';
  END IF;
  RAISE NOTICE 'PASS: Trigger on_auth_user_created on auth.users present';
END;
$$;

-- -----------------------------------------------------------------------------
-- 6. RLS enabled
-- -----------------------------------------------------------------------------
\echo '6. Row-level security'
DO $$
DECLARE missing text;
BEGIN
  SELECT string_agg(e.tbl, ', ' ORDER BY e.tbl) INTO missing
  FROM (VALUES
    ('profiles'), ('rules_versions'), ('media_objects'),
    ('groups'), ('group_members'), ('group_invites'),
    ('challenges'), ('challenge_secrets'), ('challenge_answer_aliases'),
    ('eligible_participants'), ('exclusion_events'), ('clues'),
    ('guess_attempts'), ('correction_events'),
    ('score_runs'), ('guess_judgments'), ('score_events'),
    ('comments'), ('reactions')
  ) AS e(tbl)
  WHERE NOT EXISTS (
    SELECT 1 FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relname = e.tbl
      AND c.relrowsecurity = true
  );
  IF missing IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL: RLS not enabled on: %', missing;
  END IF;
  RAISE NOTICE 'PASS: RLS enabled on all 19 public tables';
END;
$$;

-- At least one policy on each key table
DO $$
DECLARE missing text;
BEGIN
  SELECT string_agg(tbl, ', ' ORDER BY tbl) INTO missing
  FROM (VALUES
    ('profiles'), ('groups'), ('group_members'), ('group_invites'),
    ('challenges'), ('challenge_secrets'), ('challenge_answer_aliases'),
    ('eligible_participants'), ('exclusion_events'), ('clues'),
    ('guess_attempts'), ('guess_judgments'), ('score_runs'),
    ('score_events'), ('correction_events'), ('comments'), ('reactions')
  ) AS e(tbl)
  WHERE NOT EXISTS (
    SELECT 1 FROM pg_policies p
    WHERE p.schemaname = 'public' AND p.tablename = e.tbl
  );
  IF missing IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL: No RLS policies on: %', missing;
  END IF;
  RAISE NOTICE 'PASS: RLS policies present on all key tables';
END;
$$;

-- -----------------------------------------------------------------------------
-- 7. Key functions
-- -----------------------------------------------------------------------------
\echo '7. Functions'
DO $$
DECLARE missing text;
BEGIN
  SELECT string_agg(fn, ', ' ORDER BY fn) INTO missing
  FROM (VALUES
    ('public',  'create_group'),
    ('public',  'create_group_invite'),
    ('public',  'redeem_group_invite'),
    ('public',  'revoke_group_invite'),
    ('public',  'transfer_group_ownership'),
    ('public',  'activate_challenge'),
    ('public',  'lock_challenge'),
    ('public',  'reveal_challenge'),
    ('public',  'cancel_challenge'),
    ('public',  'apply_correction'),
    ('public',  'soft_delete_comment'),
    ('private', 'auth_uid'),
    ('private', 'normalize_answer'),
    ('private', 'is_group_member'),
    ('private', 'is_group_member_with'),
    ('private', 'is_challenge_group_member'),
    ('private', 'is_challenge_poster'),
    ('private', 'is_challenge_revealed'),
    ('private', 'is_eligible_non_excluded'),
    ('private', 'caller_has_guessed'),
    ('private', 'do_reveal_impl'),
    ('private', 'reveal_challenge_service'),
    ('private', 'prepare_account_deletion'),
    ('private', 'get_storage_keys_for_deletion'),
    ('private', 'mark_auth_deleted'),
    ('private', 'mark_storage_cleaned'),
    ('private', 'record_deletion_failure')
  ) AS e(ns, fn)
  WHERE NOT EXISTS (
    SELECT 1 FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = e.ns AND p.proname = e.fn
  );
  IF missing IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL: Missing functions: %', missing;
  END IF;
  RAISE NOTICE 'PASS: All 27 expected functions present';
END;
$$;

-- Exact signature-and-owner: forkensics_executor (uses to_regprocedure for full sig match)
DO $$
DECLARE missing text;
BEGIN
  SELECT string_agg(e.sig, ', ' ORDER BY e.sig) INTO missing
  FROM (VALUES
    ('public.set_guess_receipt_fields()'),
    ('public.guard_alias_edits()'),
    ('public.create_group(text)'),
    ('public.transfer_group_ownership(uuid,uuid)'),
    ('public.create_group_invite(uuid)'),
    ('public.redeem_group_invite(text)'),
    ('public.revoke_group_invite(uuid)'),
    ('public.activate_challenge(uuid)'),
    ('public.lock_challenge(uuid)'),
    ('public.reveal_challenge(uuid)'),
    ('public.cancel_challenge(uuid,text)'),
    ('public.apply_correction(uuid,text,text,text,uuid,text)'),
    ('public.soft_delete_comment(uuid)'),
    ('private.prepare_account_deletion(uuid)'),
    ('private.do_reveal_impl(uuid)'),
    ('private.reveal_challenge_service(uuid)'),
    ('private.get_storage_keys_for_deletion(uuid)'),
    ('private.mark_auth_deleted(uuid)'),
    ('private.mark_storage_cleaned(uuid)'),
    ('private.record_deletion_failure(uuid,text)')
  ) AS e(sig)
  WHERE to_regprocedure(e.sig) IS NULL
     OR (SELECT r.rolname FROM pg_proc p
         JOIN pg_roles r ON r.oid = p.proowner
         WHERE p.oid = to_regprocedure(e.sig)) IS DISTINCT FROM 'forkensics_executor';

  IF missing IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL: Missing or wrong owner (expected forkensics_executor): %', missing;
  END IF;
  RAISE NOTICE 'PASS: All 20 forkensics_executor function signatures verified';
END;
$$;

-- Exact signature-and-owner: forkensics_rls_helper
DO $$
DECLARE missing text;
BEGIN
  SELECT string_agg(e.sig, ', ' ORDER BY e.sig) INTO missing
  FROM (VALUES
    ('private.auth_uid()'),
    ('private.normalize_answer(text)'),
    ('private.is_group_member(uuid)'),
    ('private.is_group_member_with(uuid)'),
    ('private.is_challenge_group_member(uuid)'),
    ('private.is_challenge_poster(uuid)'),
    ('private.is_challenge_revealed(uuid)'),
    ('private.is_eligible_non_excluded(uuid)'),
    ('private.caller_has_guessed(uuid)')
  ) AS e(sig)
  WHERE to_regprocedure(e.sig) IS NULL
     OR (SELECT r.rolname FROM pg_proc p
         JOIN pg_roles r ON r.oid = p.proowner
         WHERE p.oid = to_regprocedure(e.sig)) IS DISTINCT FROM 'forkensics_rls_helper';

  IF missing IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL: Missing or wrong owner (expected forkensics_rls_helper): %', missing;
  END IF;
  RAISE NOTICE 'PASS: All 9 forkensics_rls_helper function signatures verified';
END;
$$;

-- -----------------------------------------------------------------------------
-- 8. Grants — authenticated role
-- -----------------------------------------------------------------------------
\echo '8. Grants'
DO $$
DECLARE v_count int;
BEGIN
  -- SELECT on profiles
  SELECT COUNT(*) INTO v_count
  FROM information_schema.role_table_grants
  WHERE grantee = 'authenticated' AND table_schema = 'public'
    AND table_name = 'profiles' AND privilege_type = 'SELECT';
  IF v_count = 0 THEN
    RAISE EXCEPTION 'FAIL: authenticated lacks SELECT on public.profiles';
  END IF;
  RAISE NOTICE 'PASS: authenticated SELECT on profiles';
END;
$$;

DO $$
DECLARE v_count int;
BEGIN
  -- INSERT on guess_attempts
  SELECT COUNT(*) INTO v_count
  FROM information_schema.role_table_grants
  WHERE grantee = 'authenticated' AND table_schema = 'public'
    AND table_name = 'guess_attempts' AND privilege_type = 'INSERT';
  IF v_count = 0 THEN
    RAISE EXCEPTION 'FAIL: authenticated lacks INSERT on public.guess_attempts';
  END IF;
  RAISE NOTICE 'PASS: authenticated INSERT on guess_attempts';
END;
$$;

DO $$
BEGIN
  -- USAGE on private schema (information_schema.role_usage_grants covers sequences/domains
  -- only; schema privileges require has_schema_privilege)
  IF NOT has_schema_privilege('authenticated', 'private', 'USAGE') THEN
    RAISE EXCEPTION 'FAIL: authenticated lacks USAGE on private schema';
  END IF;
  RAISE NOTICE 'PASS: authenticated USAGE on private schema';
END;
$$;

-- -----------------------------------------------------------------------------
-- 9. Trusted role attributes
-- -----------------------------------------------------------------------------
\echo '9. Trusted roles'
DO $$
DECLARE r record;
BEGIN
  SELECT rolcanlogin, rolbypassrls INTO r
  FROM pg_roles WHERE rolname = 'forkensics_executor';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'FAIL: role forkensics_executor does not exist';
  END IF;
  IF r.rolcanlogin THEN
    RAISE EXCEPTION 'FAIL: forkensics_executor must be NOLOGIN';
  END IF;
  IF NOT r.rolbypassrls THEN
    RAISE EXCEPTION 'FAIL: forkensics_executor must have BYPASSRLS';
  END IF;
  RAISE NOTICE 'PASS: forkensics_executor is NOLOGIN BYPASSRLS';
END;
$$;

DO $$
DECLARE r record;
BEGIN
  SELECT rolcanlogin, rolbypassrls INTO r
  FROM pg_roles WHERE rolname = 'forkensics_rls_helper';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'FAIL: role forkensics_rls_helper does not exist';
  END IF;
  IF r.rolcanlogin THEN
    RAISE EXCEPTION 'FAIL: forkensics_rls_helper must be NOLOGIN';
  END IF;
  IF NOT r.rolbypassrls THEN
    RAISE EXCEPTION 'FAIL: forkensics_rls_helper must have BYPASSRLS';
  END IF;
  RAISE NOTICE 'PASS: forkensics_rls_helper is NOLOGIN BYPASSRLS';
END;
$$;

-- -----------------------------------------------------------------------------
-- 10. Seeded rules_versions row
-- -----------------------------------------------------------------------------
\echo '10. rules_versions seed'
DO $$
DECLARE rv record;
BEGIN
  SELECT id, version_tag, config INTO rv
  FROM public.rules_versions
  WHERE id = 'a0000000-0000-0000-0000-000000000001';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'FAIL: rules_versions seed row not found (id=a0000000-0000-0000-0000-000000000001)';
  END IF;
  IF rv.version_tag IS DISTINCT FROM 'v1' THEN
    RAISE EXCEPTION 'FAIL: rules_versions version_tag = % (expected v1)', rv.version_tag;
  END IF;
  IF (rv.config->>'scoring_algorithm') IS DISTINCT FROM 'ordinal_ranking_v1' THEN
    RAISE EXCEPTION 'FAIL: rules_versions config.scoring_algorithm mismatch';
  END IF;
  IF (rv.config->'races') IS DISTINCT FROM '["what","where"]'::jsonb THEN
    RAISE EXCEPTION 'FAIL: rules_versions config.races mismatch';
  END IF;
  IF (rv.config->'where_race_fields') IS DISTINCT FROM '["restaurant"]'::jsonb THEN
    RAISE EXCEPTION 'FAIL: rules_versions config.where_race_fields mismatch (city must not be scored)';
  END IF;
  IF (rv.config->>'partial_credit')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL: rules_versions config.partial_credit should be false';
  END IF;
  IF (rv.config->>'alias_aware_matching')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL: rules_versions config.alias_aware_matching should be true';
  END IF;

  RAISE NOTICE 'PASS: rules_versions seed row verified';
END;
$$;

\echo '=== All V1 verification checks passed ==='
