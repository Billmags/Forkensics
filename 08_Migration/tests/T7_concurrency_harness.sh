#!/usr/bin/env bash
# T7 Concurrent Moderation Harness
# ---------------------------------------------------------------------------
# Tests GROUP 7 (T7): concurrent moderation operations.
#
#   T7.1: Two moderators call remove_content on the same challenge concurrently.
#         The function must be idempotent — exactly 1 moderation_actions row;
#         second session takes the idempotency path (no deadlock).
#
#   T7.2: report_content and remove_content race on the same challenge.
#         At least one session must succeed; no 'pending' content_report may
#         remain orphaned.
#
#   T7.3: approve_photo and reject_photo race on the same media_object.
#         One wins the FOR UPDATE lock; the other gets FK_WRONG_STATE (status
#         already changed). Exactly 1 moderation_actions row. The losing
#         session's output is captured and verified to contain FK_WRONG_STATE.
#
#   T7.5: Multiple reporters file concurrent reports on the same challenge;
#         then one remove_content actions all of them. Both reporters must
#         succeed (R_G=0 && R_H=0) and exactly 2 reports must be created
#         before remove_content is called. All reports actioned after.
#
# Usage:
#   PGPASSWORD=$(cat .pgpass) bash T7_concurrency_harness.sh [<connstr>]
#
# Do NOT run against prod. Local dev DB only.
#
# Each subtest uses a unique challenge/media ID so there is no need to delete
# moderation rows between subtests. V3's FK_ACTION_IMMUTABLE trigger prevents
# DELETE from moderation_actions and moderation_action_reports by design.
# Run `supabase db reset` before the next test run to restore a clean state.
# The correct evidence table name is private.moderation_evidence
# (not private.moderation_action_evidences).
# ---------------------------------------------------------------------------
set -euo pipefail

CONNSTR="${1:-postgresql://postgres@localhost:54322/postgres}"
PSQL="psql $CONNSTR -v ON_ERROR_STOP=1"

# ---------------------------------------------------------------------------
# Step 0: Temporarily grant forkensics_executor to postgres for fixture setup.
# V3 revokes this grant; postgres retains grant authority as role creator (V1).
# ---------------------------------------------------------------------------
echo "[T7 harness] Granting forkensics_executor to postgres for fixture setup..."
$PSQL -q -c "GRANT forkensics_executor TO postgres;"
trap "psql $CONNSTR -q -c 'REVOKE forkensics_executor FROM postgres;' 2>/dev/null || true" EXIT

# ---------------------------------------------------------------------------
# Step 1: Create shared profiles, group, and all fixtures.
# Challenge creation uses the two-step approach (JWT + INSERT + UPDATE state):
#   (a) set_config JWT so trigger reads poster_id from auth_uid()
#   (b) INSERT challenges (trigger: poster_id=JWT sub, state='draft')
#   (c) UPDATE state='active' as forkensics_executor (bypasses trigger)
# Three separate challenges are used (one per subtest) to avoid needing to
# delete moderation_actions between subtests (FK_ACTION_IMMUTABLE prevents it).
# ---------------------------------------------------------------------------
echo "[T7 harness] Setting up fixtures..."
$PSQL -q -v ON_ERROR_STOP=1 <<'SQL'
-- Set JWT for challenge trigger (poster = T7H Poster)
SELECT set_config('request.jwt.claims',
  '{"sub":"11000000-0000-0000-0000-000000000001","role":"authenticated"}', false);

INSERT INTO public.profiles (id, display_name, onboarding_complete)
VALUES
  ('11000000-0000-0000-0000-000000000001', 'T7H Poster',    true),
  ('11000000-0000-0000-0000-000000000002', 'T7H ModA',      true),
  ('11000000-0000-0000-0000-000000000003', 'T7H ModB',      true),
  ('11000000-0000-0000-0000-000000000004', 'T7H Member',    true),
  ('11000000-0000-0000-0000-000000000005', 'T7H ReporterA', true),
  ('11000000-0000-0000-0000-000000000006', 'T7H ReporterB', true),
  ('11000000-0000-0000-0000-000000000007', 'T7H Uploader',  true);

INSERT INTO private.profile_suspensions (profile_id, is_suspended)
VALUES
  ('11000000-0000-0000-0000-000000000001', false),
  ('11000000-0000-0000-0000-000000000002', false),
  ('11000000-0000-0000-0000-000000000003', false),
  ('11000000-0000-0000-0000-000000000004', false),
  ('11000000-0000-0000-0000-000000000005', false),
  ('11000000-0000-0000-0000-000000000006', false),
  ('11000000-0000-0000-0000-000000000007', false);

-- Correct table: private.moderators (not private.moderator_grants)
INSERT INTO private.moderators (profile_id)
VALUES
  ('11000000-0000-0000-0000-000000000002'),
  ('11000000-0000-0000-0000-000000000003');

INSERT INTO public.groups (id, name, created_by)
VALUES ('21000000-0000-0000-0000-000000000001', 'T7H Group', '11000000-0000-0000-0000-000000000001');

-- 007 (T7H Uploader) is added as 'member' so they can post the T7.5 challenge.
-- Three distinct posters (001, 004, 007) avoid one_active_challenge_per_poster violation.
INSERT INTO public.group_members (group_id, player_id, role)
VALUES
  ('21000000-0000-0000-0000-000000000001', '11000000-0000-0000-0000-000000000001', 'owner'),
  ('21000000-0000-0000-0000-000000000001', '11000000-0000-0000-0000-000000000004', 'member'),
  ('21000000-0000-0000-0000-000000000001', '11000000-0000-0000-0000-000000000005', 'member'),
  ('21000000-0000-0000-0000-000000000001', '11000000-0000-0000-0000-000000000006', 'member'),
  ('21000000-0000-0000-0000-000000000001', '11000000-0000-0000-0000-000000000007', 'member');

-- Ready media objects for T7.1, T7.2, T7.5 challenges (one per challenge).
-- remove_content('challenge') locks, audits, and removes linked media, so each
-- needs complete storage metadata — not merely status='ready'.
-- Media 001 (pending_review) is kept exclusively for T7.3 approve/reject.
INSERT INTO public.media_objects
  (id, uploader_id, mime_type, status, re_encoded_at)
VALUES
  ('31000000-0000-0000-0000-000000000002',
   '11000000-0000-0000-0000-000000000001',
   'image/webp', 'ready', now()),
  ('31000000-0000-0000-0000-000000000003',
   '11000000-0000-0000-0000-000000000004',
   'image/webp', 'ready', now()),
  ('31000000-0000-0000-0000-000000000004',
   '11000000-0000-0000-0000-000000000007',
   'image/webp', 'ready', now());

INSERT INTO private.media_storage_keys
  (media_object_id, storage_key, sha256_hash, re_encoded_storage_key)
VALUES
  ('31000000-0000-0000-0000-000000000002',
   'uploads/T7H-002/original.jpg', repeat('a', 64), 'T7H/ready2'),
  ('31000000-0000-0000-0000-000000000003',
   'uploads/T7H-003/original.jpg', repeat('b', 64), 'T7H/ready3'),
  ('31000000-0000-0000-0000-000000000004',
   'uploads/T7H-004/original.jpg', repeat('c', 64), 'T7H/ready4');

-- T7.1 challenge: poster=001 (JWT already set to sub=001 above)
INSERT INTO public.challenges (id, group_id, media_object_id) VALUES
  ('41000000-0000-0000-0000-000000000001', '21000000-0000-0000-0000-000000000001',
   '31000000-0000-0000-0000-000000000002');

-- T7.2 challenge: poster=004 (T7H Member); switch JWT before INSERT to avoid
-- one_active_challenge_per_poster (partial UNIQUE index on state IN ('draft','active','locked'))
SELECT set_config('request.jwt.claims',
  '{"sub":"11000000-0000-0000-0000-000000000004","role":"authenticated"}', false);
INSERT INTO public.challenges (id, group_id, media_object_id) VALUES
  ('41000000-0000-0000-0000-000000000002', '21000000-0000-0000-0000-000000000001',
   '31000000-0000-0000-0000-000000000003');

-- T7.5 challenge: poster=007 (T7H Uploader, added to group_members above); switch JWT
SELECT set_config('request.jwt.claims',
  '{"sub":"11000000-0000-0000-0000-000000000007","role":"authenticated"}', false);
INSERT INTO public.challenges (id, group_id, media_object_id) VALUES
  ('41000000-0000-0000-0000-000000000003', '21000000-0000-0000-0000-000000000001',
   '31000000-0000-0000-0000-000000000004');

-- Advance all three challenges to 'active' as forkensics_executor
SET ROLE forkensics_executor;
UPDATE public.challenges
SET state      = 'active',
    posted_at  = NOW() - interval '1 hour',
    deadline_at = NOW() + interval '1 hour'
WHERE id IN (
  '41000000-0000-0000-0000-000000000001',
  '41000000-0000-0000-0000-000000000002',
  '41000000-0000-0000-0000-000000000003'
);
RESET ROLE;

INSERT INTO public.eligible_participants (challenge_id, player_id, snapshot_avatar_color)
VALUES
  ('41000000-0000-0000-0000-000000000001', '11000000-0000-0000-0000-000000000004', 'red'),
  ('41000000-0000-0000-0000-000000000001', '11000000-0000-0000-0000-000000000005', 'blue'),
  ('41000000-0000-0000-0000-000000000002', '11000000-0000-0000-0000-000000000005', 'blue'),
  ('41000000-0000-0000-0000-000000000003', '11000000-0000-0000-0000-000000000005', 'blue'),
  ('41000000-0000-0000-0000-000000000003', '11000000-0000-0000-0000-000000000006', 'green');

-- T7.3 media (pending_review with storage key for approve/reject to work)
INSERT INTO public.media_objects (id, uploader_id, mime_type, status, re_encoded_at)
VALUES ('31000000-0000-0000-0000-000000000001', '11000000-0000-0000-0000-000000000007',
        'image/webp', 'pending_review', now());

INSERT INTO private.media_storage_keys (media_object_id, storage_key, sha256_hash, re_encoded_storage_key)
VALUES ('31000000-0000-0000-0000-000000000001',
        'uploads/T7H-media/original.jpg',
        'b94f5a69a2e6ef9ad3f7d03ba5f7d82b1111111111111111111111111111111a',
        'T7H/photo');
SQL

# Revoke before concurrent sessions — they only call public functions
echo "[T7 harness] Revoking forkensics_executor (concurrent sessions use public functions only)..."
$PSQL -q -c "REVOKE forkensics_executor FROM postgres;"

# ---------------------------------------------------------------------------
# T7.1: Two moderators calling remove_content on the same challenge concurrently
# ---------------------------------------------------------------------------
echo ""
echo "[T7 harness] === T7.1: Two concurrent remove_content calls ==="

$PSQL -q -v ON_ERROR_STOP=1 <<'SQL' &
SELECT public.remove_content(
  'challenge',
  '41000000-0000-0000-0000-000000000001',
  '11000000-0000-0000-0000-000000000002',
  NULL,
  'T7.1 ModA removal'
);
SQL
PID_A=$!

$PSQL -q -v ON_ERROR_STOP=1 <<'SQL' &
SELECT pg_sleep(0.02);
SELECT public.remove_content(
  'challenge',
  '41000000-0000-0000-0000-000000000001',
  '11000000-0000-0000-0000-000000000003',
  NULL,
  'T7.1 ModB removal'
);
SQL
PID_B=$!

R_A=0; R_B=0
wait $PID_A || R_A=$?
wait $PID_B || R_B=$?

echo "[T7 harness] T7.1 ModA exit: $R_A  ModB exit: $R_B"

if [ "$R_A" -ne 0 ] || [ "$R_B" -ne 0 ]; then
  echo "[T7 harness] FAIL T7.1: one or both sessions errored (possible deadlock)."
  exit 1
fi

ACTION_COUNT=$($PSQL -tAc "
  SELECT COUNT(*) FROM public.moderation_actions
  WHERE target_id = '41000000-0000-0000-0000-000000000001'
    AND action_type = 'content_removed'
")
if [ "$ACTION_COUNT" -eq 1 ]; then
  echo "[T7 harness] PASS T7.1: Exactly 1 moderation_actions row (idempotency enforced)."
else
  echo "[T7 harness] FAIL T7.1: Expected 1 moderation_actions row, found $ACTION_COUNT."
  exit 1
fi

# ---------------------------------------------------------------------------
# T7.2: Concurrent report_content + remove_content race (separate challenge)
# ---------------------------------------------------------------------------
echo ""
echo "[T7 harness] === T7.2: Concurrent report_content + remove_content ==="

# Session C (reporter) output is captured so we can verify the error type if C loses.
T72_C_OUT=$(mktemp)
( $PSQL -q -v ON_ERROR_STOP=1 <<'SQL'
BEGIN;
SELECT set_config('request.jwt.claims',
  '{"sub":"11000000-0000-0000-0000-000000000005","role":"authenticated"}', true);
SELECT public.report_content(
  'challenge',
  '41000000-0000-0000-0000-000000000002',
  'offensive_content',
  'T7.2 reporter concurrent'
);
COMMIT;
SQL
) >"$T72_C_OUT" 2>&1 &
PID_C=$!

$PSQL -q -v ON_ERROR_STOP=1 <<'SQL' &
BEGIN;
SELECT pg_sleep(0.015);
SELECT public.remove_content(
  'challenge',
  '41000000-0000-0000-0000-000000000002',
  '11000000-0000-0000-0000-000000000002',
  NULL,
  'T7.2 remove_content concurrent'
);
COMMIT;
SQL
PID_D=$!

R_C=0; R_D=0
wait $PID_C || R_C=$?
wait $PID_D || R_D=$?

echo "[T7 harness] T7.2 Reporter exit: $R_C  Remover exit: $R_D"

# Both failing is not a valid race outcome — indicates an unexpected error.
if [ "$R_C" -ne 0 ] && [ "$R_D" -ne 0 ]; then
  echo "[T7 harness] FAIL T7.2: Both sessions failed — expected at least one to succeed."
  cat "$T72_C_OUT"
  rm -f "$T72_C_OUT"
  exit 1
fi

# If reporter (C) lost, it must have received FK_NOT_FOUND — the error report_content
# returns when the challenge is no longer reportable. FK_WRONG_STATE is not an allowed
# outcome here; accepting it would hide a regression in the public error contract.
if [ "$R_C" -ne 0 ]; then
  if grep -q 'FK_NOT_FOUND' "$T72_C_OUT"; then
    echo "[T7 harness] PASS T7.2 (C lost): reporter received FK_NOT_FOUND (remove_content won race)."
  else
    echo "[T7 harness] FAIL T7.2: reporter failed with unexpected error:"
    cat "$T72_C_OUT"
    rm -f "$T72_C_OUT"
    exit 1
  fi
fi
rm -f "$T72_C_OUT"

PENDING_72=$($PSQL -tAc "
  SELECT COUNT(*) FROM public.content_reports
  WHERE target_id = '41000000-0000-0000-0000-000000000002' AND status = 'pending'
")
if [ "$PENDING_72" -eq 0 ]; then
  echo "[T7 harness] PASS T7.2: No orphan pending reports after report+remove race."
else
  echo "[T7 harness] FAIL T7.2: $PENDING_72 pending report(s) not actioned."
  exit 1
fi

# ---------------------------------------------------------------------------
# T7.3: Concurrent approve_photo + reject_photo on the same media
# ---------------------------------------------------------------------------
echo ""
echo "[T7 harness] === T7.3: Concurrent approve_photo + reject_photo ==="

TMPFILE_E=$(mktemp)
TMPFILE_F=$(mktemp)

# Capture output to temp files so we can verify FK_WRONG_STATE in the loser's output
$PSQL >"$TMPFILE_E" 2>&1 <<'SQL' &
SELECT public.approve_photo(
  '31000000-0000-0000-0000-000000000001',
  '11000000-0000-0000-0000-000000000002',
  'T7.3 ModA approve'
);
SQL
PID_E=$!

$PSQL >"$TMPFILE_F" 2>&1 <<'SQL' &
SELECT pg_sleep(0.01);
SELECT public.reject_photo(
  '31000000-0000-0000-0000-000000000001',
  '11000000-0000-0000-0000-000000000003',
  'T7.3 ModB reject'
);
SQL
PID_F=$!

R_E=0; R_F=0
wait $PID_E || R_E=$?
wait $PID_F || R_F=$?

echo "[T7 harness] T7.3 Approver exit: $R_E  Rejector exit: $R_F"
cat "$TMPFILE_E"
cat "$TMPFILE_F"

# Both failing is unexpected (deadlock or double error — not a valid race outcome)
if [ "$R_E" -ne 0 ] && [ "$R_F" -ne 0 ]; then
  echo "[T7 harness] FAIL T7.3: Both sessions failed (expected exactly one to get FK_WRONG_STATE)."
  rm -f "$TMPFILE_E" "$TMPFILE_F"
  exit 1
fi

# The losing session (whichever exited non-zero) must have FK_WRONG_STATE in its output
if [ "$R_E" -ne 0 ]; then
  LOSER_FILE="$TMPFILE_E"; LOSER_LABEL="Approver"
elif [ "$R_F" -ne 0 ]; then
  LOSER_FILE="$TMPFILE_F"; LOSER_LABEL="Rejector"
else
  # Both exited 0 — idempotency or sequential commit; still valid if exactly 1 action row
  LOSER_FILE=""; LOSER_LABEL=""
fi

if [ -n "$LOSER_FILE" ]; then
  if grep -q 'FK_WRONG_STATE' "$LOSER_FILE"; then
    echo "[T7 harness] PASS T7.3 (FK_WRONG_STATE): $LOSER_LABEL received FK_WRONG_STATE as expected."
  else
    echo "[T7 harness] FAIL T7.3: $LOSER_LABEL exited non-zero but output does not contain FK_WRONG_STATE."
    rm -f "$TMPFILE_E" "$TMPFILE_F"
    exit 1
  fi
fi
rm -f "$TMPFILE_E" "$TMPFILE_F"

# Exactly 1 moderation_actions row for this media
ACTION_COUNT_73=$($PSQL -tAc "
  SELECT COUNT(*) FROM public.moderation_actions
  WHERE target_id = '31000000-0000-0000-0000-000000000001'
")
if [ "$ACTION_COUNT_73" -eq 1 ]; then
  echo "[T7 harness] PASS T7.3: Exactly 1 moderation_actions row (approve/reject race resolved cleanly)."
else
  echo "[T7 harness] FAIL T7.3: Expected 1 moderation_actions row, found $ACTION_COUNT_73."
  exit 1
fi

# ---------------------------------------------------------------------------
# T7.5: Multiple concurrent reporters → single remove_content actions all
# Uses separate challenge '41000000-...-3' (no reset needed from T7.1/T7.2)
# ---------------------------------------------------------------------------
echo ""
echo "[T7 harness] === T7.5: Multiple concurrent reporters → single remove_content ==="

$PSQL -q -v ON_ERROR_STOP=1 <<'SQL' &
BEGIN;
SELECT set_config('request.jwt.claims',
  '{"sub":"11000000-0000-0000-0000-000000000005","role":"authenticated"}', true);
SELECT public.report_content(
  'challenge', '41000000-0000-0000-0000-000000000003',
  'offensive_content', 'T7.5 ReporterA'
);
COMMIT;
SQL
PID_G=$!

$PSQL -q -v ON_ERROR_STOP=1 <<'SQL' &
BEGIN;
SELECT set_config('request.jwt.claims',
  '{"sub":"11000000-0000-0000-0000-000000000006","role":"authenticated"}', true);
SELECT public.report_content(
  'challenge', '41000000-0000-0000-0000-000000000003',
  'offensive_content', 'T7.5 ReporterB'
);
COMMIT;
SQL
PID_H=$!

R_G=0; R_H=0
wait $PID_G || R_G=$?
wait $PID_H || R_H=$?

echo "[T7 harness] T7.5 ReporterA exit: $R_G  ReporterB exit: $R_H"

# Both reporters must succeed. ReporterA and ReporterB are different users filing
# separate content_reports rows — there is no uniqueness constraint between them.
# If either fails, the test is invalid (remove_content would action fewer than 2 reports).
if [ "$R_G" -ne 0 ] || [ "$R_H" -ne 0 ]; then
  echo "[T7 harness] FAIL T7.5: One or both reporters failed (expected both to succeed)."
  exit 1
fi

# Exactly 2 reports must exist before calling remove_content.
REPORT_COUNT=$($PSQL -tAc "
  SELECT COUNT(*) FROM public.content_reports
  WHERE target_id = '41000000-0000-0000-0000-000000000003'
")
echo "[T7 harness] T7.5: $REPORT_COUNT report(s) filed before remove_content."

if [ "$REPORT_COUNT" -ne 2 ]; then
  echo "[T7 harness] FAIL T7.5: Expected exactly 2 reports, got $REPORT_COUNT."
  exit 1
fi

# One moderator calls remove_content — should action ALL pending reports
$PSQL -q -v ON_ERROR_STOP=1 <<'SQL'
SELECT public.remove_content(
  'challenge',
  '41000000-0000-0000-0000-000000000003',
  '11000000-0000-0000-0000-000000000002',
  NULL,
  'T7.5 single remove_content'
);
SQL

PENDING_75=$($PSQL -tAc "
  SELECT COUNT(*) FROM public.content_reports
  WHERE target_id = '41000000-0000-0000-0000-000000000003' AND status = 'pending'
")
if [ "$PENDING_75" -eq 0 ]; then
  echo "[T7 harness] PASS T7.5: All $REPORT_COUNT concurrent report(s) actioned by single remove_content."
else
  echo "[T7 harness] FAIL T7.5: $PENDING_75 pending report(s) not actioned by remove_content."
  exit 1
fi

echo ""
echo "[T7 harness] DONE. All T7.1 / T7.2 / T7.3 / T7.5 assertions passed."
echo ""
echo "NOTE: Fixture rows remain in the database (moderation_actions and"
echo "moderation_action_reports are immutable per V3 FK_ACTION_IMMUTABLE trigger)."
echo "Run 'supabase db reset' before the next test run."
