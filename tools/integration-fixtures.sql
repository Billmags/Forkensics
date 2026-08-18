-- integration-fixtures.sql — upload-authorize integration test fixtures
-- Idempotent: safe to run multiple times.
-- Torn down by cleanup_integration_fixtures() called from integration-runner.sh.
--
-- Fixture UUIDs (stable across runs):
--   FIXTURE_POSTER_ID        10000000-0000-0000-0000-000000000001  active poster
--   FIXTURE_INACTIVE_USER_ID 10000000-0000-0000-0000-000000000002  is_active=false
--   FIXTURE_DELETION_USER_ID 10000000-0000-0000-0000-000000000003  deletion-prepared
--   FIXTURE_CASE_ID_1        20000000-0000-0000-0000-000000000001  happy path + DB assertions
--   FIXTURE_CASE_ID_2        20000000-0000-0000-0000-000000000002  Race B isolation
--   FIXTURE_CASE_ID_3        20000000-0000-0000-0000-000000000003  presign-failure compensation
--   FIXTURE_CASE_ID_4        20000000-0000-0000-0000-000000000004  T-A-37: prior failed session
--   FIXTURE_CASE_ID_5        20000000-0000-0000-0000-000000000005  T-A-38: prior complete session
--   FIXTURE_CASE_ID_6        20000000-0000-0000-0000-000000000006  T-A-48: activation failure
--   FIXTURE_CASE_ID_7        20000000-0000-0000-0000-000000000007  T-AMD-1/T-AMD-2: content-type signature verify + valid PUT
--   FIXTURE_CASE_ID_8        20000000-0000-0000-0000-000000000008  T-AMD-3/T-AMD-4: wrong-content-type 403 verification
--
-- Profile strategy:
--   handle_new_user() AFTER INSERT trigger on auth.users auto-creates the profile row.
--   We INSERT into auth.users only; then UPDATE profiles to reach required state.
--   For the deletion-prepared user we call prepare_account_deletion_wrapper() which
--   atomically anonymises the profile and creates the deletion_log record.
--
-- Case strategy:
--   set_challenge_create_fields() BEFORE INSERT trigger reads request.jwt.claim.sub
--   and sets poster_id from it. set_config() is called before each INSERT batch.

-- ── Pre-fixture: drop constraint that limits one active case per poster ───────
-- All 8 fixture cases share FIXTURE_POSTER_ID and must be in 'draft' state,
-- which would violate the partial unique index. We drop it here and recreate it
-- inside cleanup_integration_fixtures() after all fixture cases are removed.
DROP INDEX IF EXISTS one_active_case_per_poster;

BEGIN;

-- ── Auth users ────────────────────────────────────────────────────────────────
-- Trigger handle_new_user() fires after each INSERT and creates the profile row.
INSERT INTO auth.users (
  id, email, email_confirmed_at,
  created_at, updated_at,
  raw_app_meta_data, raw_user_meta_data,
  aud, role
)
VALUES
  (
    '10000000-0000-0000-0000-000000000001',
    'fixture-poster@test.invalid',
    now(), now(), now(),
    '{}', '{}',
    'authenticated', 'authenticated'
  ),
  (
    '10000000-0000-0000-0000-000000000002',
    'fixture-inactive@test.invalid',
    now(), now(), now(),
    '{}', '{}',
    'authenticated', 'authenticated'
  ),
  (
    '10000000-0000-0000-0000-000000000003',
    'fixture-deletion@test.invalid',
    now(), now(), now(),
    '{}', '{}',
    'authenticated', 'authenticated'
  )
ON CONFLICT (id) DO NOTHING;

-- ── Profiles ──────────────────────────────────────────────────────────────────
-- UPDATE (not INSERT): trigger already created the rows.
-- Inactive user must have avatar_color='gray' (CHECK constraint requires it when
-- is_active=false). Set deletion user to active+complete first so the wrapper
-- can proceed without constraint violations.
UPDATE public.profiles
SET
  is_active = true,
  onboarding_complete = true,
  is_suspended = false,
  avatar_color = 'orange',
  display_name = 'Fixture Poster'
WHERE id = '10000000-0000-0000-0000-000000000001';

UPDATE public.profiles
SET
  is_active = false,
  onboarding_complete = true,
  is_suspended = false,
  avatar_color = 'gray',
  display_name = 'Fixture Inactive'
WHERE id = '10000000-0000-0000-0000-000000000002';

-- Deletion-prepared user: make active and onboarded first, then call the
-- wrapper which will anonymise the profile and create the deletion_log record.
UPDATE public.profiles
SET
  is_active = true,
  onboarding_complete = true,
  is_suspended = false,
  avatar_color = 'orange',
  display_name = 'Fixture Deletion'
WHERE id = '10000000-0000-0000-0000-000000000003';

-- ── Cases ─────────────────────────────────────────────────────────────────────
-- set_challenge_create_fields() BEFORE INSERT trigger sets poster_id from the
-- JWT claim. set_config(local=false) keeps it for the duration of this
-- transaction so all six case INSERTs pick up the same poster.
SELECT set_config(
  'request.jwt.claim.sub',
  '10000000-0000-0000-0000-000000000001',
  false
);

INSERT INTO public.cases (id, state)
VALUES ('20000000-0000-0000-0000-000000000001', 'draft')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.cases (id, state)
VALUES ('20000000-0000-0000-0000-000000000002', 'draft')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.cases (id, state)
VALUES ('20000000-0000-0000-0000-000000000003', 'draft')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.cases (id, state)
VALUES ('20000000-0000-0000-0000-000000000004', 'draft')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.cases (id, state)
VALUES ('20000000-0000-0000-0000-000000000005', 'draft')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.cases (id, state)
VALUES ('20000000-0000-0000-0000-000000000006', 'draft')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.cases (id, state)
VALUES ('20000000-0000-0000-0000-000000000007', 'draft')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.cases (id, state)
VALUES ('20000000-0000-0000-0000-000000000008', 'draft')
ON CONFLICT (id) DO NOTHING;

COMMIT;

-- ── Deletion-prepared user ────────────────────────────────────────────────────
-- Runs outside the main transaction so it can observe the committed profile row.
--
-- True idempotency: if a previous partial run left deletion_log with
-- status='database_prepared', the wrapper would return early without
-- re-running, leaving the profile in an inconsistent state (is_active=true
-- from the UPDATE above but deletion_log already set). We prevent this by
-- explicitly clearing all deletion-related records for this user before
-- calling the wrapper.
--
-- Role: prepare_account_deletion_wrapper() EXECUTE is granted only to
-- service_role (its owner is forkensics_executor; SECURITY DEFINER means it
-- executes as that owner). We switch to service_role explicitly rather than
-- relying on postgres superuser privilege bypass.
DELETE FROM private.deletion_log
WHERE profile_id = '10000000-0000-0000-0000-000000000003';

DELETE FROM private.profile_archive
WHERE profile_id = '10000000-0000-0000-0000-000000000003';

-- Ensure the profile is in a clean active state before the wrapper runs.
UPDATE public.profiles
SET
  is_active          = true,
  onboarding_complete = true,
  is_suspended       = false,
  avatar_color       = 'orange',
  display_name       = 'Fixture Deletion'
WHERE id = '10000000-0000-0000-0000-000000000003';

-- Call via the explicitly granted role.
-- postgres does not hold service_role membership by default; GRANT it for this
-- transaction only. SET LOCAL ROLE takes effect within the transaction;
-- RESET ROLE restores the session role before REVOKE so no privilege leaks out.
BEGIN;
GRANT service_role TO postgres;
SET LOCAL ROLE service_role;
SELECT public.prepare_account_deletion_wrapper(
  '10000000-0000-0000-0000-000000000003'
);
RESET ROLE;
REVOKE service_role FROM postgres;
COMMIT;

-- ── Cleanup function ──────────────────────────────────────────────────────────
-- Created outside all transactions. REVOKE from PUBLIC prevents accidental
-- invocation. The runner DROPs this function after teardown.
CREATE OR REPLACE FUNCTION public.cleanup_integration_fixtures()
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  -- Remove upload sessions for all fixture cases (must precede cases deletion)
  DELETE FROM private.upload_sessions
  WHERE case_id IN (
    '20000000-0000-0000-0000-000000000001',
    '20000000-0000-0000-0000-000000000002',
    '20000000-0000-0000-0000-000000000003',
    '20000000-0000-0000-0000-000000000004',
    '20000000-0000-0000-0000-000000000005',
    '20000000-0000-0000-0000-000000000006',
    '20000000-0000-0000-0000-000000000007',
    '20000000-0000-0000-0000-000000000008'
  );

  -- Remove fixture cases
  DELETE FROM public.cases
  WHERE id IN (
    '20000000-0000-0000-0000-000000000001',
    '20000000-0000-0000-0000-000000000002',
    '20000000-0000-0000-0000-000000000003',
    '20000000-0000-0000-0000-000000000004',
    '20000000-0000-0000-0000-000000000005',
    '20000000-0000-0000-0000-000000000006',
    '20000000-0000-0000-0000-000000000007',
    '20000000-0000-0000-0000-000000000008'
  );

  -- Remove tables that FK → public.profiles before deleting profiles
  -- (all are idempotent no-ops if rows do not exist)
  DELETE FROM private.deletion_log
  WHERE profile_id IN (
    '10000000-0000-0000-0000-000000000001',
    '10000000-0000-0000-0000-000000000002',
    '10000000-0000-0000-0000-000000000003'
  );

  DELETE FROM private.profile_archive
  WHERE profile_id IN (
    '10000000-0000-0000-0000-000000000001',
    '10000000-0000-0000-0000-000000000002',
    '10000000-0000-0000-0000-000000000003'
  );

  DELETE FROM private.profile_suspensions
  WHERE profile_id IN (
    '10000000-0000-0000-0000-000000000001',
    '10000000-0000-0000-0000-000000000002',
    '10000000-0000-0000-0000-000000000003'
  );

  -- Remove fixture profiles
  DELETE FROM public.profiles
  WHERE id IN (
    '10000000-0000-0000-0000-000000000001',
    '10000000-0000-0000-0000-000000000002',
    '10000000-0000-0000-0000-000000000003'
  );

  -- Remove fixture auth users
  DELETE FROM auth.users
  WHERE id IN (
    '10000000-0000-0000-0000-000000000001',
    '10000000-0000-0000-0000-000000000002',
    '10000000-0000-0000-0000-000000000003'
  );

  -- Recreate the partial unique index dropped before fixture load.
  -- All fixture cases are removed above, so the index will build cleanly.
  EXECUTE $idx$
    CREATE UNIQUE INDEX IF NOT EXISTS one_active_case_per_poster
      ON public.cases (poster_id)
      WHERE state IN ('draft','ready','launched','locked')
  $idx$;
END;
$$;

-- Revoke public execute privilege immediately after creation
REVOKE ALL ON FUNCTION public.cleanup_integration_fixtures() FROM PUBLIC;
