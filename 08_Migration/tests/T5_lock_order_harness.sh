#!/usr/bin/env bash
# T5 Lock-Order Concurrency Harness
# ---------------------------------------------------------------------------
# Tests GROUP 5 (T5): media removal races with report_content.
# Two psql sessions run concurrently:
#   Session A: remove_media (acquires media lock first)
#   Session B: report_content on the same media_object_id
#
# Expected outcome: one of the following, depending on which session wins:
#   - remove_media commits first → report_content sees FK_NOT_FOUND
#   - report_content commits first → remove_media bulk-actions that report (both exit 0)
#
# In neither case should BOTH sessions fail. One must succeed.
# If Session B lost, its error is verified to be an allowed FK_* error.
#
# R19.7 — IS DISTINCT FROM recheck (coordinated two-session race):
#   Session A acquires SELECT ... FOR UPDATE on the challenge row, then sleeps (holding
#   the lock). Session B calls report_content which internally does SELECT ... FOR UPDATE
#   on the same challenge (step b) and blocks. Session A then nulls media_object_id and
#   commits; B resumes, re-reads the challenge (sees NULL), and the IS DISTINCT FROM
#   check raises FK_NOT_FOUND. This exercises the recheck code path at step c.
#
#   A separate poster (T5H Poster2, id 004) owns the R19.7 challenge so that it does
#   not share a poster with the T5.1/T5.2 challenge (poster 001), avoiding a
#   one_active_challenge_per_poster UNIQUE index violation.
#
# Usage:
#   PGPASSWORD=$(cat .pgpass) bash T5_lock_order_harness.sh [<connstr>]
#
# The connection string defaults to the local dev DB. Do NOT run against prod.
#
# NOTE: This harness does NOT clean up after itself. V3's FK_ACTION_IMMUTABLE trigger
# prevents DELETE from moderation_actions and moderation_action_reports (intentional
# immutable audit trail). Run `supabase db reset` between test runs to restore a
# clean state.
# ---------------------------------------------------------------------------
set -euo pipefail

CONNSTR="${1:-postgresql://postgres@localhost:54322/postgres}"
PSQL="psql $CONNSTR -v ON_ERROR_STOP=1"

# ---------------------------------------------------------------------------
# Step 0: Grant forkensics_executor for fixture setup.
# The EXIT trap revokes it if fixture setup fails before the explicit REVOKE below.
# After the explicit REVOKE the trap fires again on exit — that REVOKE is a no-op.
# ---------------------------------------------------------------------------
echo "[T5 harness] Granting forkensics_executor to postgres for fixture setup..."
$PSQL -q -c "GRANT forkensics_executor TO postgres;"
trap "psql $CONNSTR -q -c 'REVOKE forkensics_executor FROM postgres;' 2>/dev/null || true" EXIT

# ---------------------------------------------------------------------------
# Step 1: Create all fixtures in one block.
# Both T5.1/T5.2 and R19.7 data are created here so the GRANT/REVOKE cycle
# only happens once. R19.7 uses a separate poster (004) to avoid the partial
# UNIQUE index one_active_challenge_per_poster (covers state IN ('draft','active','locked')).
# ---------------------------------------------------------------------------
echo "[T5 harness] Setting up fixtures..."
$PSQL -q -v ON_ERROR_STOP=1 <<'SQL'
-- JWT for T5.1 challenge (poster=001); set_challenge_create_fields reads auth_uid from it
SELECT set_config('request.jwt.claims',
  '{"sub":"10000000-0000-0000-0000-000000000001","role":"authenticated"}', false);

INSERT INTO public.profiles (id, display_name, onboarding_complete)
VALUES
  ('10000000-0000-0000-0000-000000000001', 'T5H Poster',   true),
  ('10000000-0000-0000-0000-000000000002', 'T5H Reporter', true),
  ('10000000-0000-0000-0000-000000000003', 'T5H Mod',      true),
  ('10000000-0000-0000-0000-000000000004', 'T5H Poster2',  true);

INSERT INTO private.profile_suspensions (profile_id, is_suspended)
VALUES
  ('10000000-0000-0000-0000-000000000001', false),
  ('10000000-0000-0000-0000-000000000002', false),
  ('10000000-0000-0000-0000-000000000003', false),
  ('10000000-0000-0000-0000-000000000004', false);

INSERT INTO private.moderators (profile_id) VALUES ('10000000-0000-0000-0000-000000000003');

INSERT INTO public.groups (id, name, created_by)
VALUES ('20000000-0000-0000-0000-000000000001', 'T5H Group', '10000000-0000-0000-0000-000000000001');

INSERT INTO public.group_members (group_id, player_id, role)
VALUES
  ('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'owner'),
  ('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000002', 'member'),
  ('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000004', 'member');

-- T5.1/T5.2 media (storage_key is NOT NULL in V1 schema)
INSERT INTO public.media_objects (id, uploader_id, mime_type, status, re_encoded_at)
VALUES ('30000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001',
        'image/webp', 'ready', now());
INSERT INTO private.media_storage_keys (media_object_id, storage_key, sha256_hash, re_encoded_storage_key)
VALUES ('30000000-0000-0000-0000-000000000001',
        'uploads/T5H-001/original.jpg',
        'a665a45920422f9d417e4867efdc4fb8a04a1f3fff1fa07e998e86f7f7a27ae3',
        'T5H/key1');

-- R19.7 media (uploaded by poster2=004)
INSERT INTO public.media_objects (id, uploader_id, mime_type, status, re_encoded_at)
VALUES ('30000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000004',
        'image/webp', 'ready', now());
INSERT INTO private.media_storage_keys (media_object_id, storage_key, sha256_hash, re_encoded_storage_key)
VALUES ('30000000-0000-0000-0000-000000000002',
        'uploads/T5H-002/original.jpg',
        'b94f5a69f8e3a99af7a9fcd5434ad4e2e2b7aa39c3a3e2e5b8c6f4d8a1f7e9c2',
        'T5H/key2');

-- T5.1/T5.2 challenge: poster=001 (JWT already set above)
INSERT INTO public.challenges (id, group_id, media_object_id)
VALUES ('40000000-0000-0000-0000-000000000001',
        '20000000-0000-0000-0000-000000000001',
        '30000000-0000-0000-0000-000000000001');

-- R19.7 challenge: poster=004 (switch JWT before INSERT)
SELECT set_config('request.jwt.claims',
  '{"sub":"10000000-0000-0000-0000-000000000004","role":"authenticated"}', false);
INSERT INTO public.challenges (id, group_id, media_object_id)
VALUES ('40000000-0000-0000-0000-000000000002',
        '20000000-0000-0000-0000-000000000001',
        '30000000-0000-0000-0000-000000000002');

-- Advance both challenges to 'active' as forkensics_executor
-- (bypasses protect_challenge_authority_fields which allows all ops for executor)
SET ROLE forkensics_executor;
UPDATE public.challenges
SET state      = 'active',
    posted_at  = NOW() - interval '1 hour',
    deadline_at = NOW() + interval '1 hour'
WHERE id IN (
  '40000000-0000-0000-0000-000000000001',
  '40000000-0000-0000-0000-000000000002'
);
RESET ROLE;

INSERT INTO public.eligible_participants (challenge_id, player_id, snapshot_avatar_color)
VALUES
  ('40000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000002', 'blue'),
  ('40000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000002', 'blue');
SQL

# Revoke before concurrent sessions — they only call public SECURITY DEFINER functions
echo "[T5 harness] Revoking forkensics_executor (concurrent sessions use public functions only)..."
$PSQL -q -c "REVOKE forkensics_executor FROM postgres;"

echo ""
echo "[T5 harness] === T5.1/T5.2: Concurrent remove_media + report_content ==="
echo "[T5 harness] Launching concurrent sessions..."

# Session A: remove_media — acquires lock on the media object first.
# Small sleep lets Session B start before A commits, increasing concurrency coverage.
$PSQL -q -v ON_ERROR_STOP=1 <<'SQL' &
BEGIN;
SELECT pg_sleep(0.05);
SELECT public.remove_media(
  '30000000-0000-0000-0000-000000000001',
  '10000000-0000-0000-0000-000000000003',
  NULL,
  'T5 harness remove'
);
COMMIT;
SQL
PID_A=$!

# Session B: report_content — receives FK_NOT_FOUND if remove_media wins the race.
# Output is captured so we can verify the error type if B loses.
SESSION_B_OUT=$(mktemp)
( $PSQL -q -v ON_ERROR_STOP=1 <<'SQL'
BEGIN;
SELECT set_config('request.jwt.claims',
  '{"sub":"10000000-0000-0000-0000-000000000002","role":"authenticated"}', true);
SELECT public.report_content(
  'media_object',
  '30000000-0000-0000-0000-000000000001',
  'inappropriate_image',
  'T5 harness report'
);
COMMIT;
SQL
) >"$SESSION_B_OUT" 2>&1 &
PID_B=$!

RESULT_A=0; RESULT_B=0
wait $PID_A || RESULT_A=$?
wait $PID_B || RESULT_B=$?

echo "[T5 harness] Session A (remove_media) exit: $RESULT_A"
echo "[T5 harness] Session B (report_content) exit: $RESULT_B"

# Both failing is not a valid race outcome — indicates an unexpected error.
if [ "$RESULT_A" -ne 0 ] && [ "$RESULT_B" -ne 0 ]; then
  echo "[T5 harness] FAIL T5.1/T5.2: Both sessions failed — expected at least one to succeed."
  cat "$SESSION_B_OUT"
  rm -f "$SESSION_B_OUT"
  exit 1
fi

# If Session B (reporter) lost, its error must be FK_NOT_FOUND.
# report_content returns FK_NOT_FOUND when the challenge or media is no longer reportable
# (already removed or no longer linked). Accepting FK_WRONG_STATE would hide regressions
# in the public error contract.
if [ "$RESULT_B" -ne 0 ]; then
  if grep -q 'FK_NOT_FOUND' "$SESSION_B_OUT"; then
    echo "[T5 harness] PASS T5.1: remove_media won; report_content received FK_NOT_FOUND."
  else
    echo "[T5 harness] FAIL T5.1: report_content failed with unexpected error:"
    cat "$SESSION_B_OUT"
    rm -f "$SESSION_B_OUT"
    exit 1
  fi
fi
rm -f "$SESSION_B_OUT"

$PSQL -c "
SELECT status FROM public.media_objects WHERE id = '30000000-0000-0000-0000-000000000001';
SELECT id, status FROM public.content_reports WHERE target_id = '30000000-0000-0000-0000-000000000001';
"

PENDING=$($PSQL -tAc "
  SELECT COUNT(*) FROM public.content_reports
  WHERE target_id = '30000000-0000-0000-0000-000000000001' AND status = 'pending'
")

if [ "$PENDING" -eq 0 ]; then
  echo "[T5 harness] PASS T5.1/T5.2: No orphan pending reports after race."
else
  echo "[T5 harness] FAIL T5.1/T5.2: $PENDING pending report(s) left unactioned after race."
  exit 1
fi

echo ""
echo "[T5 harness] === R19.7: IS DISTINCT FROM recheck — coordinated two-session race ==="
echo "[T5 harness] A acquires FOR UPDATE on challenge, B calls report_content and blocks."
echo "[T5 harness] A unlinks media_object_id and commits; B resumes → IS DISTINCT FROM → FK_NOT_FOUND."

# Session A: acquire FOR UPDATE on the challenge row, then poll pg_stat_activity until
# Session B (identified by application_name='forkensics_r197_b') is in a Lock wait AND
# pg_blocking_pids(B.pid) includes our own PID. This proves B's provisional lookup
# (step a) succeeded before B blocked at step b — guaranteeing IS DISTINCT FROM at step c.
# postgres has BYPASSRLS and owns challenges; media_object_id is NOT in
# protect_challenge_authority_fields protected list → UPDATE proceeds without executor role.
$PSQL -q -v ON_ERROR_STOP=1 <<'SQL' &
BEGIN;
SELECT id FROM public.challenges
WHERE id = '40000000-0000-0000-0000-000000000002' FOR UPDATE;

-- Poll pg_stat_activity until Session B (application_name='forkensics_r197_b') is in a
-- Lock wait AND this session (pg_backend_pid()) is its blocker. This is immune to
-- PostgreSQL's internal lock-type representation (tuple vs transactionid).
DO $$
DECLARE v_waited int := 0;
BEGIN
  LOOP
    -- Refresh transaction-scoped statistics before every observation.
    PERFORM pg_stat_clear_snapshot();

    EXIT WHEN EXISTS (
      SELECT 1
      FROM   pg_stat_activity a
      WHERE  a.application_name  = 'forkensics_r197_b'
        AND  a.wait_event_type   = 'Lock'
        AND  pg_backend_pid()   = ANY(pg_blocking_pids(a.pid))
    );
    v_waited := v_waited + 1;
    IF v_waited > 100 THEN
      RAISE EXCEPTION 'R19.7 timeout: Session B did not block on row lock within 10 s';
    END IF;
    PERFORM pg_sleep(0.1);
  END LOOP;
END;
$$;

UPDATE public.challenges SET media_object_id = NULL
WHERE id = '40000000-0000-0000-0000-000000000002';
COMMIT;
SQL
PID_R197_A=$!

# Brief pause to give Session A time to acquire the row lock before B connects.
# The pg_locks poll inside Session A then handles the actual synchronization.
sleep 0.1

# Session B: reporter calls report_content on the linked media.
# Step a (provisional): finds challenge WHERE media_object_id = target → found (before A commits).
# Step b (lock):        SELECT ... FOR UPDATE on challenge → BLOCKS on A's lock.
# A commits (media_object_id = NULL); B unblocks.
# Step c (recheck):     NULL IS DISTINCT FROM target_id → TRUE → raises FK_NOT_FOUND.
R197_B_OUT=$(mktemp)
( $PSQL -q -v ON_ERROR_STOP=1 <<'SQL'
-- Name this session so Session A's pg_stat_activity poll can identify it.
SET application_name = 'forkensics_r197_b';
BEGIN;
SELECT set_config('request.jwt.claims',
  '{"sub":"10000000-0000-0000-0000-000000000002","role":"authenticated"}', true);
SELECT public.report_content(
  'media_object',
  '30000000-0000-0000-0000-000000000002',
  'inappropriate_image',
  'R19.7 race — IS DISTINCT FROM recheck'
);
COMMIT;
SQL
) >"$R197_B_OUT" 2>&1 &
PID_R197_B=$!

R197_A=0; R197_B=0
wait $PID_R197_A || R197_A=$?
wait $PID_R197_B || R197_B=$?

echo "[T5 harness] R19.7 Session A (lock+unlink) exit: $R197_A"
echo "[T5 harness] R19.7 Session B (report_content) exit: $R197_B"

if [ "$R197_A" -ne 0 ]; then
  echo "[T5 harness] FAIL R19.7: Session A (lock+unlink) failed unexpectedly."
  rm -f "$R197_B_OUT"
  exit 1
fi

if [ "$R197_B" -eq 0 ]; then
  echo "[T5 harness] FAIL R19.7: Session B succeeded — expected FK_NOT_FOUND from IS DISTINCT FROM recheck."
  rm -f "$R197_B_OUT"
  exit 1
fi

if grep -q 'FK_NOT_FOUND' "$R197_B_OUT"; then
  echo "[T5 harness] PASS R19.7: IS DISTINCT FROM recheck raised FK_NOT_FOUND as expected."
else
  echo "[T5 harness] FAIL R19.7: Session B failed but output does not contain FK_NOT_FOUND:"
  cat "$R197_B_OUT"
  rm -f "$R197_B_OUT"
  exit 1
fi
rm -f "$R197_B_OUT"

echo ""
echo "[T5 harness] DONE. All T5 / R19.7 assertions passed."
echo ""
echo "NOTE: Fixture rows remain in the database (moderation_actions and"
echo "moderation_action_reports are immutable per V3 FK_ACTION_IMMUTABLE trigger)."
echo "Run 'supabase db reset' before the next test run."
