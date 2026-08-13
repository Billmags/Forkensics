#!/usr/bin/env bash
# V4 Concurrency Harness — REQ-7  (Rev 3)
# ---------------------------------------------------------------------------
# Tests that approve_photo / reject_photo / report_content / remove_media /
# finalize_upload_session cannot deadlock under the R6-B6 case-first lock order.
#
# Deterministic synchronization (Rev 3):
#   Session A: sets application_name, BEGINs a transaction, manually acquires
#   the contested case-row FOR UPDATE, polls pg_stat_activity until Session B
#   shows BOTH wait_event_type='Lock' AND pg_backend_pid()=ANY(pg_blocking_pids)
#   — proving A is the actual blocker — then calls its function and COMMITs.
#   Session B: sets application_name, statement_timeout='10s',
#   lock_timeout='5s', calls its function.
#   Both A and B run with statement_timeout='10s'.
#
#   Because A holds the lock before calling its function, and only proceeds
#   after confirming B is genuinely blocked by A, the outcome is PREDETERMINED:
#   A ALWAYS wins. This allows exact DB-state assertions after each test.
#
#   TV4.1  approve_photo vs reject_photo on same pending_review media.
#          A (approve) wins → media='ready', 1 moderation_actions row.
#          B (reject) MUST exit non-zero with FK_WRONG_STATE exactly.
#
#   TV4.2  approve_photo vs report_content('case') on the same case.
#          Both use case-first lock → they serialize. A approves; B reports.
#          Both MUST exit 0. Exact DB state: media2='ready', ≥1 content_report,
#          1 moderation_action for Media2.
#
#   TV4.3  approve_photo vs remove_media on the same pending_review media.
#          A approves → media='ready'; B (remove_media) finds 'ready' → succeeds.
#          Both MUST exit 0. Exact DB state: media3='removed', case3='cancelled',
#          2 moderation_actions for Media3.
#
#   TV4.4  reject_photo vs finalize_upload_session on the same draft case.
#          Lock orders: reject (case→media) vs finalize (upload_session→case).
#          Different first locks → no deadlock cycle.
#          A (reject) wins → media4='rejected', case4.media_object_id=NULL.
#          B (finalize) unblocks → creates new media, sets case4.media_object_id.
#          Both MUST exit 0. Exact DB state: media4='rejected',
#          upload_session='complete', case4.media_object_id ≠ Media4 UUID.
#
# Usage (after supabase db reset applying V1+V2+V3+V4):
#   PGPASSWORD=<pw> bash tests/V4_concurrency_harness.sh [<connstr>]
#
# Do NOT run against production. Local dev DB only.
# Run 'supabase db reset' before each harness run for a clean fixture state.
# ---------------------------------------------------------------------------
set -euo pipefail

CONNSTR="${1:-postgresql://postgres@localhost:54322/postgres}"
PSQL="psql $CONNSTR -v ON_ERROR_STOP=1"

# ---------------------------------------------------------------------------
# Step 0: Grant forkensics_executor to postgres for fixture setup.
# ---------------------------------------------------------------------------
echo "[V4 harness] Granting forkensics_executor to postgres for fixture setup..."
$PSQL -q -c "GRANT forkensics_executor TO postgres;"
trap "psql $CONNSTR -q -c 'REVOKE forkensics_executor FROM postgres;' 2>/dev/null || true" EXIT

# ---------------------------------------------------------------------------
# Step 1: Fixture setup.
#
# V4 drops group_id from cases — cases are created with only media_object_id.
# Group linkage is via investigations. Poster UUIDs must be distinct per case to
# satisfy the one_active_case_per_poster partial UNIQUE INDEX.
#
# Static UUIDs:
#   Poster1-4:  22...001, 22...004, 22...005, 22...006
#   ModA:       22...002
#   ModB:       22...003
#   Reporter:   22...007  (investigation member of Case2 for TV4.2)
#   Group1:     33...001  (used for investigations)
#   Media1-4:   44...001-004 (pending_review)
#   Case1-4:    55...001-004
#   Inv2:       77...001  (investigation for Case2; Reporter is member)
#   UploadSess: 66...001  (TV4.4 upload_session for Case4, status='sanitized')
# ---------------------------------------------------------------------------
echo "[V4 harness] Setting up fixtures..."
$PSQL -q -v ON_ERROR_STOP=1 <<'SQL'
-- ---- profiles ----
INSERT INTO public.profiles (id, display_name, onboarding_complete, is_active)
VALUES
  ('22000000-0000-0000-0000-000000000001', 'TV4H Poster1',   true, true),
  ('22000000-0000-0000-0000-000000000002', 'TV4H ModA',      true, true),
  ('22000000-0000-0000-0000-000000000003', 'TV4H ModB',      true, true),
  ('22000000-0000-0000-0000-000000000004', 'TV4H Poster2',   true, true),
  ('22000000-0000-0000-0000-000000000005', 'TV4H Poster3',   true, true),
  ('22000000-0000-0000-0000-000000000006', 'TV4H Poster4',   true, true),
  ('22000000-0000-0000-0000-000000000007', 'TV4H Reporter',  true, true);

INSERT INTO private.profile_suspensions (profile_id, is_suspended)
VALUES
  ('22000000-0000-0000-0000-000000000001', false),
  ('22000000-0000-0000-0000-000000000002', false),
  ('22000000-0000-0000-0000-000000000003', false),
  ('22000000-0000-0000-0000-000000000004', false),
  ('22000000-0000-0000-0000-000000000005', false),
  ('22000000-0000-0000-0000-000000000006', false),
  ('22000000-0000-0000-0000-000000000007', false);

INSERT INTO private.moderators (profile_id)
VALUES
  ('22000000-0000-0000-0000-000000000002'),  -- ModA
  ('22000000-0000-0000-0000-000000000003');  -- ModB

-- ---- group (used for investigations) ----
INSERT INTO public.groups (id, name, created_by)
VALUES ('33000000-0000-0000-0000-000000000001', 'TV4H Group',
        '22000000-0000-0000-0000-000000000001');
INSERT INTO public.group_members (group_id, player_id, role)
VALUES
  ('33000000-0000-0000-0000-000000000001', '22000000-0000-0000-0000-000000000001', 'owner'),
  ('33000000-0000-0000-0000-000000000001', '22000000-0000-0000-0000-000000000007', 'member');

-- ---- pending_review media (one per test case) ----
INSERT INTO public.media_objects (id, uploader_id, mime_type, status, re_encoded_at)
VALUES
  ('44000000-0000-0000-0000-000000000001',
   '22000000-0000-0000-0000-000000000001', 'image/webp', 'pending_review', now()),
  ('44000000-0000-0000-0000-000000000002',
   '22000000-0000-0000-0000-000000000004', 'image/webp', 'pending_review', now()),
  ('44000000-0000-0000-0000-000000000003',
   '22000000-0000-0000-0000-000000000005', 'image/webp', 'pending_review', now()),
  ('44000000-0000-0000-0000-000000000004',
   '22000000-0000-0000-0000-000000000006', 'image/webp', 'pending_review', now());

INSERT INTO private.media_storage_keys
  (media_object_id, storage_key, sha256_hash, re_encoded_storage_key)
VALUES
  ('44000000-0000-0000-0000-000000000001',
   'uploads/tv4h-1/orig.jpg', repeat('a', 64), 'cases/tv4h/1/display.webp'),
  ('44000000-0000-0000-0000-000000000002',
   'uploads/tv4h-2/orig.jpg', repeat('b', 64), 'cases/tv4h/2/display.webp'),
  ('44000000-0000-0000-0000-000000000003',
   'uploads/tv4h-3/orig.jpg', repeat('c', 64), 'cases/tv4h/3/display.webp'),
  ('44000000-0000-0000-0000-000000000004',
   'uploads/tv4h-4/orig.jpg', repeat('d', 64), 'cases/tv4h/4/display.webp');

-- ---- cases: JWT set per poster; case_create_fields trigger sets poster_id.
--   V4 has no group_id on cases. ----
-- Case1: TV4.1 (approve vs reject)
SELECT set_config('request.jwt.claims',
  '{"sub":"22000000-0000-0000-0000-000000000001","role":"authenticated"}', false);
INSERT INTO public.cases (id, media_object_id)
VALUES ('55000000-0000-0000-0000-000000000001',
        '44000000-0000-0000-0000-000000000001');
INSERT INTO public.case_secrets
  (case_id, display_dish, canonical_dish, display_restaurant, canonical_restaurant)
VALUES ('55000000-0000-0000-0000-000000000001',
        'TV4H Dish1', 'tv4h dish1', 'TV4H Place1', 'tv4h place1');

-- Case2: TV4.2 (approve vs report_content)
SELECT set_config('request.jwt.claims',
  '{"sub":"22000000-0000-0000-0000-000000000004","role":"authenticated"}', false);
INSERT INTO public.cases (id, media_object_id)
VALUES ('55000000-0000-0000-0000-000000000002',
        '44000000-0000-0000-0000-000000000002');
INSERT INTO public.case_secrets
  (case_id, display_dish, canonical_dish, display_restaurant, canonical_restaurant)
VALUES ('55000000-0000-0000-0000-000000000002',
        'TV4H Dish2', 'tv4h dish2', 'TV4H Place2', 'tv4h place2');

-- Case3: TV4.3 (approve vs remove_media)
SELECT set_config('request.jwt.claims',
  '{"sub":"22000000-0000-0000-0000-000000000005","role":"authenticated"}', false);
INSERT INTO public.cases (id, media_object_id)
VALUES ('55000000-0000-0000-0000-000000000003',
        '44000000-0000-0000-0000-000000000003');
INSERT INTO public.case_secrets
  (case_id, display_dish, canonical_dish, display_restaurant, canonical_restaurant)
VALUES ('55000000-0000-0000-0000-000000000003',
        'TV4H Dish3', 'tv4h dish3', 'TV4H Place3', 'tv4h place3');

-- Case4: TV4.4 (reject vs finalize) — stays 'draft'; finalize requires draft state
SELECT set_config('request.jwt.claims',
  '{"sub":"22000000-0000-0000-0000-000000000006","role":"authenticated"}', false);
INSERT INTO public.cases (id, media_object_id)
VALUES ('55000000-0000-0000-0000-000000000004',
        '44000000-0000-0000-0000-000000000004');
INSERT INTO public.case_secrets
  (case_id, display_dish, canonical_dish, display_restaurant, canonical_restaurant)
VALUES ('55000000-0000-0000-0000-000000000004',
        'TV4H Dish4', 'tv4h dish4', 'TV4H Place4', 'tv4h place4');

-- ---- Advance Case1, Case2, Case3 to 'launched' as forkensics_executor ----
-- protect_case_authority_fields: allows any state change when current_user='forkensics_executor'.
SET ROLE forkensics_executor;
UPDATE public.cases
SET state = 'launched',
    posted_at   = now() - interval '1 hour',
    deadline_at = now() + interval '2 hours'
WHERE id IN (
  '55000000-0000-0000-0000-000000000001',
  '55000000-0000-0000-0000-000000000002',
  '55000000-0000-0000-0000-000000000003'
);
RESET ROLE;

-- ---- TV4.2 investigation: Reporter must be an investigation member of Case2
--   for can_view_case(Case2) to return true (required by report_content). ----
INSERT INTO public.investigations
  (investigation_id, case_id, group_id, status)
VALUES
  ('77000000-0000-0000-0000-000000000001',
   '55000000-0000-0000-0000-000000000002',
   '33000000-0000-0000-0000-000000000001',
   'active');
INSERT INTO public.investigation_members
  (investigation_id, player_id, snapshot_display_name, snapshot_avatar_color, eligibility_status)
VALUES
  ('77000000-0000-0000-0000-000000000001',
   '22000000-0000-0000-0000-000000000007',
   'TV4H Reporter', 'green', 'eligible');

-- ---- TV4.4: upload_session (status='sanitized') for Case4 ----
INSERT INTO private.upload_sessions (
  session_id, upload_token_hash, case_id, uploader_id,
  original_storage_path, display_storage_path,
  content_type, declared_size_bytes, expires_at,
  storage_upload_expires_at, status, status_changed_at
) VALUES (
  '66000000-0000-0000-0000-000000000001',
  repeat('e', 64),
  '55000000-0000-0000-0000-000000000004',
  '22000000-0000-0000-0000-000000000006',
  'cases/55000000-0000-0000-0000-000000000004/originals/66000000-0000-0000-0000-000000000001',
  'cases/55000000-0000-0000-0000-000000000004/displays/66000000-0000-0000-0000-000000000001.webp',
  'image/jpeg',
  1024000,
  now() + interval '1 hour',
  NULL,
  'sanitized',
  now()
);
SQL

# Note: forkensics_executor grant remains active for per-test fixture setup (TV4.5–TV4.9) and
# for concurrent sessions that call remove_content (TV4.5-B, TV4.6-A, TV4.7-B, TV4.8-A) via
# SET LOCAL ROLE forkensics_executor. forkensics_executor owns remove_content and has implicit
# EXECUTE; postgres cannot reliably SET LOCAL ROLE service_role even after a grant (SET=false).
# The EXIT trap revokes the grant on completion or failure.

# ===========================================================================
# TV4.1: approve_photo vs reject_photo on same pending_review media.
#
# Ordering is PREDETERMINED: A holds Case1 FOR UPDATE and only calls
# approve_photo after confirming (via pg_blocking_pids) that B is genuinely
# blocked. A ALWAYS wins.
#
# Expected exact outcomes:
#   Session A (approve): exits 0
#   Session B (reject):  exits non-zero; output MUST contain FK_WRONG_STATE
#   DB after: media1.status='ready'; COUNT(moderation_actions for Media1)=1
# ===========================================================================
echo ""
echo "[V4 harness] === TV4.1: approve_photo vs reject_photo (same media) ==="

TMPFILE_E=$(mktemp)
TMPFILE_F=$(mktemp)

$PSQL >"$TMPFILE_E" 2>&1 <<'SQL' &
SET application_name = 'tv41_a';
SET statement_timeout = '10s';
BEGIN;
-- Hold Case1 FOR UPDATE; approve_photo will re-acquire in the same txn (no contention with self)
SELECT id FROM public.cases WHERE id = '55000000-0000-0000-0000-000000000001' FOR UPDATE;
-- Wait until B is genuinely blocked by A (not just waiting on some other lock)
DO $$
DECLARE deadline timestamptz := clock_timestamp() + interval '8s';
BEGIN
  LOOP
    PERFORM pg_stat_clear_snapshot();
    EXIT WHEN EXISTS (
      SELECT 1 FROM pg_stat_activity b
      WHERE b.application_name = 'tv41_b'
        AND b.wait_event_type = 'Lock'
        AND pg_backend_pid() = ANY(pg_blocking_pids(b.pid))
    );
    IF clock_timestamp() > deadline THEN
      RAISE EXCEPTION 'TV4.1: session B did not reach Lock wait (blocked by A) within 8s';
    END IF;
    PERFORM pg_sleep(0.05);
  END LOOP;
END $$;
SELECT public.approve_photo(
  '44000000-0000-0000-0000-000000000001',
  '22000000-0000-0000-0000-000000000002',
  'TV4.1 ModA approve'
);
COMMIT;
SQL
PID_E=$!

$PSQL >"$TMPFILE_F" 2>&1 <<'SQL' &
SET application_name = 'tv41_b';
SET statement_timeout = '10s';
SET lock_timeout = '5s';
SELECT public.reject_photo(
  '44000000-0000-0000-0000-000000000001',
  '22000000-0000-0000-0000-000000000003',
  'TV4.1 ModB reject'
);
SQL
PID_F=$!

R_E=0; R_F=0
wait $PID_E || R_E=$?
wait $PID_F || R_F=$?

echo "[V4 harness] TV4.1 Approver exit: $R_E  Rejector exit: $R_F"
cat "$TMPFILE_E"
cat "$TMPFILE_F"

# Approver (A) MUST succeed: ordering is predetermined
if [ "$R_E" -ne 0 ]; then
  echo "[V4 harness] FAIL TV4.1: Approver (Session A) exited non-zero — A should always win."
  rm -f "$TMPFILE_E" "$TMPFILE_F"
  exit 1
fi

# Rejector (B) MUST fail with FK_WRONG_STATE exactly
if [ "$R_F" -eq 0 ]; then
  echo "[V4 harness] FAIL TV4.1: Rejector (Session B) exited 0 — expected FK_WRONG_STATE."
  rm -f "$TMPFILE_E" "$TMPFILE_F"
  exit 1
fi
if ! grep -q 'FK_WRONG_STATE' "$TMPFILE_F"; then
  echo "[V4 harness] FAIL TV4.1: Rejector exited non-zero but output lacks FK_WRONG_STATE:"
  cat "$TMPFILE_F"
  rm -f "$TMPFILE_E" "$TMPFILE_F"
  exit 1
fi
echo "[V4 harness] PASS TV4.1 session outcomes: Approver=0, Rejector=FK_WRONG_STATE"
rm -f "$TMPFILE_E" "$TMPFILE_F"

# DB state assertions
MEDIA1_STATUS=$($PSQL -tAc "SELECT status FROM public.media_objects WHERE id = '44000000-0000-0000-0000-000000000001'")
if [ "$MEDIA1_STATUS" != "ready" ]; then
  echo "[V4 harness] FAIL TV4.1 DB: Media1 status='$MEDIA1_STATUS', expected 'ready'."
  exit 1
fi
echo "[V4 harness] PASS TV4.1 DB: Media1 status='ready'"

ACTION_COUNT_TV41=$($PSQL -tAc "
  SELECT COUNT(*) FROM public.moderation_actions
  WHERE target_id = '44000000-0000-0000-0000-000000000001'
")
if [ "$ACTION_COUNT_TV41" -ne 1 ]; then
  echo "[V4 harness] FAIL TV4.1 DB: Expected 1 moderation_actions row for Media1, found $ACTION_COUNT_TV41."
  exit 1
fi
echo "[V4 harness] PASS TV4.1 DB: Exactly 1 moderation_actions row for Media1."

# ===========================================================================
# TV4.2: approve_photo vs report_content('case') on same case.
#
# Both functions use case-first lock order → they serialize, no deadlock.
# A holds Case2 lock; B (reporter) blocks; A approves; B reports.
# Ordering is PREDETERMINED: A always completes first.
#
# Expected exact outcomes:
#   Session A (approve): exits 0
#   Session B (report):  exits 0
#   DB after: media2.status='ready';
#             COUNT(content_reports for Case2) >= 1;
#             COUNT(moderation_actions for Media2) = 1
# ===========================================================================
echo ""
echo "[V4 harness] === TV4.2: approve_photo vs report_content('case') ==="

TMPFILE_G=$(mktemp)
TMPFILE_H=$(mktemp)

$PSQL >"$TMPFILE_G" 2>&1 <<'SQL' &
SET application_name = 'tv42_a';
SET statement_timeout = '10s';
BEGIN;
SELECT id FROM public.cases WHERE id = '55000000-0000-0000-0000-000000000002' FOR UPDATE;
DO $$
DECLARE deadline timestamptz := clock_timestamp() + interval '8s';
BEGIN
  LOOP
    PERFORM pg_stat_clear_snapshot();
    EXIT WHEN EXISTS (
      SELECT 1 FROM pg_stat_activity b
      WHERE b.application_name = 'tv42_b'
        AND b.wait_event_type = 'Lock'
        AND pg_backend_pid() = ANY(pg_blocking_pids(b.pid))
    );
    IF clock_timestamp() > deadline THEN
      RAISE EXCEPTION 'TV4.2: session B did not reach Lock wait (blocked by A) within 8s';
    END IF;
    PERFORM pg_sleep(0.05);
  END LOOP;
END $$;
SELECT public.approve_photo(
  '44000000-0000-0000-0000-000000000002',
  '22000000-0000-0000-0000-000000000002',
  'TV4.2 ModA approve'
);
COMMIT;
SQL
PID_G=$!

$PSQL >"$TMPFILE_H" 2>&1 <<'SQL' &
SET application_name = 'tv42_b';
SET statement_timeout = '10s';
SET lock_timeout = '5s';
-- Set JWT so report_content can identify the reporter via auth_uid()
SELECT set_config('request.jwt.claims',
  '{"sub":"22000000-0000-0000-0000-000000000007","role":"authenticated"}', false);
SELECT report_id FROM public.report_content(
  'case',
  '55000000-0000-0000-0000-000000000002',
  'offensive_content',
  'TV4.2 concurrent report'
);
SQL
PID_H=$!

R_G=0; R_H=0
wait $PID_G || R_G=$?
wait $PID_H || R_H=$?

echo "[V4 harness] TV4.2 Approver exit: $R_G  Reporter exit: $R_H"
cat "$TMPFILE_G"
cat "$TMPFILE_H"

# Both MUST exit 0: A approves first (serialized by lock), B reports after A commits
if [ "$R_G" -ne 0 ]; then
  echo "[V4 harness] FAIL TV4.2: Approver (Session A) exited non-zero — expected 0."
  rm -f "$TMPFILE_G" "$TMPFILE_H"
  exit 1
fi
if [ "$R_H" -ne 0 ]; then
  echo "[V4 harness] FAIL TV4.2: Reporter (Session B) exited non-zero — expected 0."
  cat "$TMPFILE_H"
  rm -f "$TMPFILE_G" "$TMPFILE_H"
  exit 1
fi
echo "[V4 harness] PASS TV4.2 session outcomes: both exited 0."
rm -f "$TMPFILE_G" "$TMPFILE_H"

# DB state assertions
MEDIA2_STATUS=$($PSQL -tAc "SELECT status FROM public.media_objects WHERE id = '44000000-0000-0000-0000-000000000002'")
if [ "$MEDIA2_STATUS" != "ready" ]; then
  echo "[V4 harness] FAIL TV4.2 DB: Media2 status='$MEDIA2_STATUS', expected 'ready'."
  exit 1
fi
echo "[V4 harness] PASS TV4.2 DB: Media2 status='ready'"

REPORT_COUNT_TV42=$($PSQL -tAc "
  SELECT COUNT(*) FROM public.content_reports
  WHERE target_type='case' AND target_id='55000000-0000-0000-0000-000000000002'
")
if [ "$REPORT_COUNT_TV42" -lt 1 ]; then
  echo "[V4 harness] FAIL TV4.2 DB: Expected ≥1 content_report for Case2, found $REPORT_COUNT_TV42."
  exit 1
fi
echo "[V4 harness] PASS TV4.2 DB: $REPORT_COUNT_TV42 content_report(s) for Case2."

ACTION_COUNT_TV42=$($PSQL -tAc "
  SELECT COUNT(*) FROM public.moderation_actions
  WHERE target_id = '44000000-0000-0000-0000-000000000002'
")
if [ "$ACTION_COUNT_TV42" -ne 1 ]; then
  echo "[V4 harness] FAIL TV4.2 DB: Expected 1 moderation_actions row for Media2, found $ACTION_COUNT_TV42."
  exit 1
fi
echo "[V4 harness] PASS TV4.2 DB: Exactly 1 moderation_actions row for Media2."

# ===========================================================================
# TV4.3: approve_photo vs remove_media on same pending_review media.
#
# Both use case-first lock order (R6-B6). Ordering is PREDETERMINED: A wins.
# A approves → media3='ready'; B (remove_media) finds 'ready' → removes it.
# remove_media cancels launched cases → Case3 becomes 'cancelled'.
#
# Expected exact outcomes:
#   Session A (approve):      exits 0
#   Session B (remove_media): exits 0
#   DB after: media3.status='removed'; case3.state='cancelled';
#             COUNT(moderation_actions for Media3) = 2
# ===========================================================================
echo ""
echo "[V4 harness] === TV4.3: approve_photo vs remove_media (same media) ==="

TMPFILE_I=$(mktemp)
TMPFILE_J=$(mktemp)

$PSQL >"$TMPFILE_I" 2>&1 <<'SQL' &
SET application_name = 'tv43_a';
SET statement_timeout = '10s';
BEGIN;
SELECT id FROM public.cases WHERE id = '55000000-0000-0000-0000-000000000003' FOR UPDATE;
DO $$
DECLARE deadline timestamptz := clock_timestamp() + interval '8s';
BEGIN
  LOOP
    PERFORM pg_stat_clear_snapshot();
    EXIT WHEN EXISTS (
      SELECT 1 FROM pg_stat_activity b
      WHERE b.application_name = 'tv43_b'
        AND b.wait_event_type = 'Lock'
        AND pg_backend_pid() = ANY(pg_blocking_pids(b.pid))
    );
    IF clock_timestamp() > deadline THEN
      RAISE EXCEPTION 'TV4.3: session B did not reach Lock wait (blocked by A) within 8s';
    END IF;
    PERFORM pg_sleep(0.05);
  END LOOP;
END $$;
SELECT public.approve_photo(
  '44000000-0000-0000-0000-000000000003',
  '22000000-0000-0000-0000-000000000002',
  'TV4.3 ModA approve'
);
COMMIT;
SQL
PID_I=$!

$PSQL >"$TMPFILE_J" 2>&1 <<'SQL' &
SET application_name = 'tv43_b';
SET statement_timeout = '10s';
SET lock_timeout = '5s';
SELECT public.remove_media(
  '44000000-0000-0000-0000-000000000003',
  '22000000-0000-0000-0000-000000000003',
  NULL,
  'TV4.3 ModB remove_media concurrent'
);
SQL
PID_J=$!

R_I=0; R_J=0
wait $PID_I || R_I=$?
wait $PID_J || R_J=$?

echo "[V4 harness] TV4.3 Approver exit: $R_I  Remover exit: $R_J"
cat "$TMPFILE_I"
cat "$TMPFILE_J"

# Both MUST exit 0: A approves → media becomes 'ready'; B then removes 'ready' media → both succeed
if [ "$R_I" -ne 0 ]; then
  echo "[V4 harness] FAIL TV4.3: Approver (Session A) exited non-zero — expected 0."
  rm -f "$TMPFILE_I" "$TMPFILE_J"
  exit 1
fi
if [ "$R_J" -ne 0 ]; then
  echo "[V4 harness] FAIL TV4.3: Remover (Session B) exited non-zero — expected 0."
  cat "$TMPFILE_J"
  rm -f "$TMPFILE_I" "$TMPFILE_J"
  exit 1
fi
echo "[V4 harness] PASS TV4.3 session outcomes: both exited 0."
rm -f "$TMPFILE_I" "$TMPFILE_J"

# DB state assertions
MEDIA3_STATUS=$($PSQL -tAc "SELECT status FROM public.media_objects WHERE id = '44000000-0000-0000-0000-000000000003'")
if [ "$MEDIA3_STATUS" != "removed" ]; then
  echo "[V4 harness] FAIL TV4.3 DB: Media3 status='$MEDIA3_STATUS', expected 'removed'."
  exit 1
fi
echo "[V4 harness] PASS TV4.3 DB: Media3 status='removed'"

CASE3_STATE=$($PSQL -tAc "SELECT state FROM public.cases WHERE id = '55000000-0000-0000-0000-000000000003'")
if [ "$CASE3_STATE" != "cancelled" ]; then
  echo "[V4 harness] FAIL TV4.3 DB: Case3 state='$CASE3_STATE', expected 'cancelled'."
  exit 1
fi
echo "[V4 harness] PASS TV4.3 DB: Case3 state='cancelled'"

ACTION_COUNT_TV43=$($PSQL -tAc "
  SELECT COUNT(*) FROM public.moderation_actions
  WHERE target_id = '44000000-0000-0000-0000-000000000003'
")
if [ "$ACTION_COUNT_TV43" -ne 2 ]; then
  echo "[V4 harness] FAIL TV4.3 DB: Expected 2 moderation_actions for Media3, found $ACTION_COUNT_TV43."
  exit 1
fi
echo "[V4 harness] PASS TV4.3 DB: Exactly 2 moderation_actions for Media3 (approve + remove)."

# ===========================================================================
# TV4.4: reject_photo vs finalize_upload_session on same draft case.
#
# Lock orders:
#   reject_photo:            case FOR UPDATE → media FOR UPDATE
#   finalize_upload_session: upload_session FOR UPDATE → case FOR UPDATE
#
# Different first locks → no deadlock cycle possible.
# A holds Case4 FOR UPDATE; B's finalize acquires upload_session FOR UPDATE
# then blocks on Case4 → A confirms B is blocked → A calls reject_photo.
#
# reject_photo side effects on draft cases: media4→'rejected', cases.media_object_id→NULL.
# finalize_upload_session then unblocks: case4.media_object_id is NULL, so no
# 'superseded' update on old media; creates new media row; links it to case4;
# upload_session→'complete'. Both sessions succeed.
#
# Expected exact outcomes:
#   Session A (reject):    exits 0
#   Session B (finalize):  exits 0
#   DB after: media4.status='rejected';
#             upload_session 66...001 status='complete';
#             case4.media_object_id IS NOT NULL;
#             case4.media_object_id != '44000000-0000-0000-0000-000000000004'
# ===========================================================================
echo ""
echo "[V4 harness] === TV4.4: reject_photo vs finalize_upload_session ==="

TMPFILE_K=$(mktemp)
TMPFILE_L=$(mktemp)

$PSQL >"$TMPFILE_K" 2>&1 <<'SQL' &
SET application_name = 'tv44_a';
SET statement_timeout = '10s';
BEGIN;
SELECT id FROM public.cases WHERE id = '55000000-0000-0000-0000-000000000004' FOR UPDATE;
-- Wait until B's finalize has acquired upload_session lock and is now blocked on Case4
DO $$
DECLARE deadline timestamptz := clock_timestamp() + interval '8s';
BEGIN
  LOOP
    PERFORM pg_stat_clear_snapshot();
    EXIT WHEN EXISTS (
      SELECT 1 FROM pg_stat_activity b
      WHERE b.application_name = 'tv44_b'
        AND b.wait_event_type = 'Lock'
        AND pg_backend_pid() = ANY(pg_blocking_pids(b.pid))
    );
    IF clock_timestamp() > deadline THEN
      RAISE EXCEPTION 'TV4.4: session B did not reach Lock wait (blocked by A) within 8s';
    END IF;
    PERFORM pg_sleep(0.05);
  END LOOP;
END $$;
SELECT public.reject_photo(
  '44000000-0000-0000-0000-000000000004',
  '22000000-0000-0000-0000-000000000002',
  'TV4.4 ModA reject'
);
COMMIT;
SQL
PID_K=$!

$PSQL >"$TMPFILE_L" 2>&1 <<'SQL' &
SET application_name = 'tv44_b';
SET statement_timeout = '10s';
SET lock_timeout = '5s';
-- finalize_upload_session: upload_session FOR UPDATE → case FOR UPDATE
-- B will hold upload_session lock, then block on Case4 lock held by A.
SELECT media_object_id, replaced_media_object_id
FROM public.finalize_upload_session(
  '66000000-0000-0000-0000-000000000001',
  'f1d2d2f924e986ac86fdf7b36c94bcdf32beec153c1a6c0d05a1b6b9c68d5311'
);
SQL
PID_L=$!

R_K=0; R_L=0
wait $PID_K || R_K=$?
wait $PID_L || R_L=$?

echo "[V4 harness] TV4.4 Rejector exit: $R_K  Finalizer exit: $R_L"
cat "$TMPFILE_K"
cat "$TMPFILE_L"

# Both MUST exit 0: reject wins → media4='rejected', case4.media_object_id=NULL;
# finalize then unblocks, case4 is still 'draft', creates new media, links it, succeeds.
if [ "$R_K" -ne 0 ]; then
  echo "[V4 harness] FAIL TV4.4: Rejector (Session A) exited non-zero — expected 0."
  rm -f "$TMPFILE_K" "$TMPFILE_L"
  exit 1
fi
if [ "$R_L" -ne 0 ]; then
  echo "[V4 harness] FAIL TV4.4: Finalizer (Session B) exited non-zero — expected 0."
  cat "$TMPFILE_L"
  rm -f "$TMPFILE_K" "$TMPFILE_L"
  exit 1
fi
echo "[V4 harness] PASS TV4.4 session outcomes: both exited 0."
rm -f "$TMPFILE_K" "$TMPFILE_L"

# DB state assertions
MEDIA4_STATUS=$($PSQL -tAc "SELECT status FROM public.media_objects WHERE id = '44000000-0000-0000-0000-000000000004'")
if [ "$MEDIA4_STATUS" != "rejected" ]; then
  echo "[V4 harness] FAIL TV4.4 DB: Media4 status='$MEDIA4_STATUS', expected 'rejected'."
  exit 1
fi
echo "[V4 harness] PASS TV4.4 DB: Media4 status='rejected'"

SESS_STATUS=$($PSQL -tAc "SELECT status FROM private.upload_sessions WHERE session_id = '66000000-0000-0000-0000-000000000001'")
if [ "$SESS_STATUS" != "complete" ]; then
  echo "[V4 harness] FAIL TV4.4 DB: upload_session status='$SESS_STATUS', expected 'complete'."
  exit 1
fi
echo "[V4 harness] PASS TV4.4 DB: upload_session status='complete'"

CASE4_MEDIA=$($PSQL -tAc "SELECT COALESCE(media_object_id::text, 'NULL') FROM public.cases WHERE id = '55000000-0000-0000-0000-000000000004'")
if [ "$CASE4_MEDIA" = "NULL" ]; then
  echo "[V4 harness] FAIL TV4.4 DB: Case4.media_object_id is NULL — finalize should have linked new media."
  exit 1
fi
if [ "$CASE4_MEDIA" = "44000000-0000-0000-0000-000000000004" ]; then
  echo "[V4 harness] FAIL TV4.4 DB: Case4.media_object_id still points to rejected Media4 — finalize should have linked new media."
  exit 1
fi
echo "[V4 harness] PASS TV4.4 DB: Case4.media_object_id='$CASE4_MEDIA' (new media linked by finalize, != original Media4)."

echo ""

echo ""

# =============================================================================
# TV4.5 — report_content('comment') races remove_content('comment')
#         Session A (reporter) wins; B (remover) unblocks after A commits.
#
# Lock order:
#   report_content('comment'): comment FOR UPDATE → case FOR UPDATE
#   remove_content('comment'): comment FOR UPDATE → content_reports FOR UPDATE
#
# Both grab comment first → A wins (pg_blocking_pids poll confirms).
# A records the report. B unblocks, removes the comment, and resolves the
# pending report (sets status='actioned').
#
# Expected outcomes:
#   A exits 0 (report recorded)
#   B exits 0 (comment removed, report actioned)
#   DB: comment5.moderator_removed_at IS NOT NULL; report status='actioned'
# =============================================================================
echo "--- TV4.5: report_content vs remove_content on comment5 (report wins) ---"

# ---- Fixture setup for TV4.5 ----
$PSQL -v ON_ERROR_STOP=1 -q <<'FIXTURE_TV45'
-- Poster5 (also Mod5 — inserted into private.moderators)
INSERT INTO public.profiles (id, display_name, onboarding_complete)
VALUES ('22000000-0000-0000-0000-000000000008','TV45 Poster5',true)
ON CONFLICT DO NOTHING;
INSERT INTO private.profile_suspensions (profile_id, is_suspended)
VALUES ('22000000-0000-0000-0000-000000000008', false)
ON CONFLICT DO NOTHING;
INSERT INTO private.moderators (profile_id)
VALUES ('22000000-0000-0000-0000-000000000008')
ON CONFLICT DO NOTHING;

-- Author5
INSERT INTO public.profiles (id, display_name, onboarding_complete)
VALUES ('22000000-0000-0000-0000-000000000010','TV45 Author5',true)
ON CONFLICT DO NOTHING;
INSERT INTO private.profile_suspensions (profile_id, is_suspended)
VALUES ('22000000-0000-0000-0000-000000000010', false)
ON CONFLICT DO NOTHING;

-- Reporter5
INSERT INTO public.profiles (id, display_name, onboarding_complete)
VALUES ('22000000-0000-0000-0000-000000000013','TV45 Reporter5',true)
ON CONFLICT DO NOTHING;
INSERT INTO private.profile_suspensions (profile_id, is_suspended)
VALUES ('22000000-0000-0000-0000-000000000013', false)
ON CONFLICT DO NOTHING;

-- Group5
INSERT INTO public.groups (id, name, created_by)
VALUES ('33000000-0000-0000-0000-000000000002','TV45 Group5',
        '22000000-0000-0000-0000-000000000008')
ON CONFLICT DO NOTHING;
INSERT INTO public.group_members (group_id, player_id, role)
VALUES ('33000000-0000-0000-0000-000000000002',
        '22000000-0000-0000-0000-000000000008','owner')
ON CONFLICT DO NOTHING;
INSERT INTO public.group_members (group_id, player_id, role)
VALUES ('33000000-0000-0000-0000-000000000002',
        '22000000-0000-0000-0000-000000000010','member')
ON CONFLICT DO NOTHING;
INSERT INTO public.group_members (group_id, player_id, role)
VALUES ('33000000-0000-0000-0000-000000000002',
        '22000000-0000-0000-0000-000000000013','member')
ON CONFLICT DO NOTHING;

-- Media5
INSERT INTO public.media_objects (id, uploader_id, mime_type, status, re_encoded_at)
VALUES ('44000000-0000-0000-0000-000000000005',
        '22000000-0000-0000-0000-000000000008',
        'image/webp','ready',now())
ON CONFLICT DO NOTHING;
INSERT INTO private.media_storage_keys
  (media_object_id, storage_key, sha256_hash, re_encoded_storage_key)
VALUES ('44000000-0000-0000-0000-000000000005',
        'uploads/tv45/orig.jpg', repeat('5',64), 'cases/tv45/display.webp')
ON CONFLICT DO NOTHING;

-- Case5 — state='revealed'
SELECT set_config('request.jwt.claims',
  '{"sub":"22000000-0000-0000-0000-000000000008","role":"authenticated"}', false);
INSERT INTO public.cases (id, media_object_id)
VALUES ('55000000-0000-0000-0000-000000000005',
        '44000000-0000-0000-0000-000000000005')
ON CONFLICT DO NOTHING;

SET ROLE forkensics_executor;
UPDATE public.cases SET state='revealed',
  posted_at=now()-interval '3 hours', deadline_at=now()-interval '1 hour',
  revealed_at=now()-interval '30 minutes'
WHERE id='55000000-0000-0000-0000-000000000005';
RESET ROLE;

-- Investigation5
INSERT INTO public.investigations
  (investigation_id, case_id, group_id, status)
VALUES ('77000000-0000-0000-0000-000000000002',
        '55000000-0000-0000-0000-000000000005',
        '33000000-0000-0000-0000-000000000002','active')
ON CONFLICT DO NOTHING;

-- investigation_members: snapshot columns required
INSERT INTO public.investigation_members
  (investigation_id, player_id, snapshot_display_name, snapshot_avatar_color, eligibility_status)
VALUES ('77000000-0000-0000-0000-000000000002',
        '22000000-0000-0000-0000-000000000010',
        'TV45 Author5', 'blue', 'eligible')
ON CONFLICT DO NOTHING;
INSERT INTO public.investigation_members
  (investigation_id, player_id, snapshot_display_name, snapshot_avatar_color, eligibility_status)
VALUES ('77000000-0000-0000-0000-000000000002',
        '22000000-0000-0000-0000-000000000013',
        'TV45 Reporter5', 'green', 'eligible')
ON CONFLICT DO NOTHING;

-- Comment5 (investigation_id NOT NULL)
INSERT INTO public.comments
  (id, case_id, investigation_id, author_id, text)
VALUES ('cc000000-0000-0000-0000-000000000001',
        '55000000-0000-0000-0000-000000000005',
        '77000000-0000-0000-0000-000000000002',
        '22000000-0000-0000-0000-000000000010',
        'TV4.5 test comment')
ON CONFLICT DO NOTHING;
FIXTURE_TV45
echo "[V4 harness] TV4.5 fixture inserted."

# ---- Session A: report_content('comment', Comment5) ----
TMPFILE_M=$(mktemp)
(
$PSQL -v ON_ERROR_STOP=1 -q <<'SESSION_A_TV45'
SET application_name = 'tv45_a';
SET statement_timeout = '20s';
BEGIN;
SELECT id FROM public.comments WHERE id = 'cc000000-0000-0000-0000-000000000001' FOR UPDATE;
SET application_name = 'tv45_a_locked';
DO $$
DECLARE deadline timestamptz := clock_timestamp() + interval '8 seconds';
BEGIN
  LOOP
    PERFORM pg_stat_clear_snapshot();
    EXIT WHEN EXISTS (
      SELECT 1 FROM pg_stat_activity b
      WHERE b.application_name = 'tv45_b'
        AND b.wait_event_type = 'Lock'
        AND pg_backend_pid() = ANY(pg_blocking_pids(b.pid))
    );
    IF clock_timestamp() > deadline THEN
      RAISE EXCEPTION 'TV4.5: Session B did not reach lock wait within 8 seconds';
    END IF;
    PERFORM pg_sleep(0.05);
  END LOOP;
END $$;
SELECT set_config('request.jwt.claims',
  '{"sub":"22000000-0000-0000-0000-000000000013","role":"authenticated"}', false);
SELECT public.report_content('comment',
  'cc000000-0000-0000-0000-000000000001', 'spam', NULL);
COMMIT;
SESSION_A_TV45
) > "$TMPFILE_M" 2>&1 &
PID_M=$!

# ---- Session B: remove_content('comment', Comment5) — Mod = Poster5 ----
TMPFILE_N=$(mktemp)
(
sleep 0.1
$PSQL -v ON_ERROR_STOP=1 -q <<'SESSION_B_TV45'
SET application_name = 'tv45_b';
SET statement_timeout = '20s';
BEGIN;
SELECT set_config('request.jwt.claims',
  '{"sub":"22000000-0000-0000-0000-000000000008","role":"authenticated"}', false);
DO $$
DECLARE deadline timestamptz := clock_timestamp() + interval '8 seconds';
BEGIN
  LOOP
    PERFORM pg_stat_clear_snapshot();
    EXIT WHEN EXISTS (
      SELECT 1 FROM pg_stat_activity
      WHERE application_name = 'tv45_a_locked'
    );
    IF clock_timestamp() > deadline THEN
      RAISE EXCEPTION 'TV4.5 B: Session A did not signal lock-ready within 8 seconds';
    END IF;
    PERFORM pg_sleep(0.05);
  END LOOP;
END $$;
SET LOCAL ROLE forkensics_executor;
SELECT public.remove_content('comment',
  'cc000000-0000-0000-0000-000000000001',
  '22000000-0000-0000-0000-000000000008',
  NULL, 'TV4.5 moderator removal');
COMMIT;
SESSION_B_TV45
) > "$TMPFILE_N" 2>&1 &
PID_N=$!

R_M=0; R_N=0
wait "$PID_M" || R_M=$?
wait "$PID_N" || R_N=$?

if [ "$R_M" -ne 0 ]; then
  echo "[V4 harness] FAIL TV4.5: Reporter (A) exited non-zero ($R_M)."
  echo "--- Session A output ---"; cat "$TMPFILE_M"
  echo "--- Session B output ---"; cat "$TMPFILE_N"
  rm -f "$TMPFILE_M" "$TMPFILE_N"; exit 1
fi
if [ "$R_N" -ne 0 ]; then
  echo "[V4 harness] FAIL TV4.5: Remover (B) exited non-zero ($R_N)."
  echo "--- Session A output ---"; cat "$TMPFILE_M"
  echo "--- Session B output ---"; cat "$TMPFILE_N"
  rm -f "$TMPFILE_M" "$TMPFILE_N"; exit 1
fi
echo "[V4 harness] PASS TV4.5 session outcomes: both exited 0."
rm -f "$TMPFILE_M" "$TMPFILE_N"

COMMENT5_REMOVED=$($PSQL -tAc \
  "SELECT moderator_removed_at IS NOT NULL FROM public.comments WHERE id='cc000000-0000-0000-0000-000000000001'")
[ "$COMMENT5_REMOVED" = "t" ] || { echo "[V4 harness] FAIL TV4.5 DB: comment5.moderator_removed_at NULL."; exit 1; }
echo "[V4 harness] PASS TV4.5 DB: comment5.moderator_removed_at IS NOT NULL"

REPORT5_STATUS=$($PSQL -tAc \
  "SELECT status FROM public.content_reports WHERE target_type='comment' AND target_id='cc000000-0000-0000-0000-000000000001' ORDER BY created_at DESC LIMIT 1")
[ "$REPORT5_STATUS" = "actioned" ] || { echo "[V4 harness] FAIL TV4.5 DB: report5 status='$REPORT5_STATUS', expected 'actioned'."; exit 1; }
echo "[V4 harness] PASS TV4.5 DB: content_report for comment5 status='actioned'"

echo ""

# =============================================================================
# TV4.6 — remove_content('comment') races report_content('comment')
#         Session A (remover) wins; B (reporter) finds comment already removed.
#   A exits 0; B exits non-zero (FK_NOT_FOUND)
#   DB: comment6.moderator_removed_at IS NOT NULL; no content_report for comment6
# =============================================================================
echo "--- TV4.6: remove_content vs report_content on comment6 (remove wins) ---"

$PSQL -v ON_ERROR_STOP=1 -q <<'FIXTURE_TV46'
-- Poster6 (also Mod6)
INSERT INTO public.profiles (id, display_name, onboarding_complete)
VALUES ('22000000-0000-0000-0000-000000000009','TV46 Poster6',true)
ON CONFLICT DO NOTHING;
INSERT INTO private.profile_suspensions (profile_id, is_suspended)
VALUES ('22000000-0000-0000-0000-000000000009', false)
ON CONFLICT DO NOTHING;
INSERT INTO private.moderators (profile_id)
VALUES ('22000000-0000-0000-0000-000000000009')
ON CONFLICT DO NOTHING;

-- Author6
INSERT INTO public.profiles (id, display_name, onboarding_complete)
VALUES ('22000000-0000-0000-0000-000000000011','TV46 Author6',true)
ON CONFLICT DO NOTHING;
INSERT INTO private.profile_suspensions (profile_id, is_suspended)
VALUES ('22000000-0000-0000-0000-000000000011', false)
ON CONFLICT DO NOTHING;

-- Reporter6
INSERT INTO public.profiles (id, display_name, onboarding_complete)
VALUES ('22000000-0000-0000-0000-000000000014','TV46 Reporter6',true)
ON CONFLICT DO NOTHING;
INSERT INTO private.profile_suspensions (profile_id, is_suspended)
VALUES ('22000000-0000-0000-0000-000000000014', false)
ON CONFLICT DO NOTHING;

-- Group6
INSERT INTO public.groups (id, name, created_by)
VALUES ('33000000-0000-0000-0000-000000000003','TV46 Group6',
        '22000000-0000-0000-0000-000000000009')
ON CONFLICT DO NOTHING;
INSERT INTO public.group_members (group_id, player_id, role)
VALUES ('33000000-0000-0000-0000-000000000003',
        '22000000-0000-0000-0000-000000000009','owner')
ON CONFLICT DO NOTHING;
INSERT INTO public.group_members (group_id, player_id, role)
VALUES ('33000000-0000-0000-0000-000000000003',
        '22000000-0000-0000-0000-000000000011','member')
ON CONFLICT DO NOTHING;
INSERT INTO public.group_members (group_id, player_id, role)
VALUES ('33000000-0000-0000-0000-000000000003',
        '22000000-0000-0000-0000-000000000014','member')
ON CONFLICT DO NOTHING;

-- Media6
INSERT INTO public.media_objects (id, uploader_id, mime_type, status, re_encoded_at)
VALUES ('44000000-0000-0000-0000-000000000006',
        '22000000-0000-0000-0000-000000000009',
        'image/webp','ready',now())
ON CONFLICT DO NOTHING;
INSERT INTO private.media_storage_keys
  (media_object_id, storage_key, sha256_hash, re_encoded_storage_key)
VALUES ('44000000-0000-0000-0000-000000000006',
        'uploads/tv46/orig.jpg', repeat('6',64), 'cases/tv46/display.webp')
ON CONFLICT DO NOTHING;

-- Case6 — state='revealed'
SELECT set_config('request.jwt.claims',
  '{"sub":"22000000-0000-0000-0000-000000000009","role":"authenticated"}', false);
INSERT INTO public.cases (id, media_object_id)
VALUES ('55000000-0000-0000-0000-000000000006',
        '44000000-0000-0000-0000-000000000006')
ON CONFLICT DO NOTHING;

SET ROLE forkensics_executor;
UPDATE public.cases SET state='revealed',
  posted_at=now()-interval '3 hours', deadline_at=now()-interval '1 hour',
  revealed_at=now()-interval '30 minutes'
WHERE id='55000000-0000-0000-0000-000000000006';
RESET ROLE;

-- Investigation6
INSERT INTO public.investigations
  (investigation_id, case_id, group_id, status)
VALUES ('77000000-0000-0000-0000-000000000003',
        '55000000-0000-0000-0000-000000000006',
        '33000000-0000-0000-0000-000000000003','active')
ON CONFLICT DO NOTHING;

INSERT INTO public.investigation_members
  (investigation_id, player_id, snapshot_display_name, snapshot_avatar_color, eligibility_status)
VALUES ('77000000-0000-0000-0000-000000000003',
        '22000000-0000-0000-0000-000000000011',
        'TV46 Author6', 'purple', 'eligible')
ON CONFLICT DO NOTHING;
INSERT INTO public.investigation_members
  (investigation_id, player_id, snapshot_display_name, snapshot_avatar_color, eligibility_status)
VALUES ('77000000-0000-0000-0000-000000000003',
        '22000000-0000-0000-0000-000000000014',
        'TV46 Reporter6', 'orange', 'eligible')
ON CONFLICT DO NOTHING;

-- Comment6 (investigation_id NOT NULL)
INSERT INTO public.comments
  (id, case_id, investigation_id, author_id, text)
VALUES ('cc000000-0000-0000-0000-000000000002',
        '55000000-0000-0000-0000-000000000006',
        '77000000-0000-0000-0000-000000000003',
        '22000000-0000-0000-0000-000000000011',
        'TV4.6 test comment')
ON CONFLICT DO NOTHING;
FIXTURE_TV46
echo "[V4 harness] TV4.6 fixture inserted."

# ---- Session A: remove_content('comment', Comment6) — wins ----
TMPFILE_O=$(mktemp)
(
$PSQL -v ON_ERROR_STOP=1 -q <<'SESSION_A_TV46'
SET application_name = 'tv46_a';
SET statement_timeout = '20s';
BEGIN;
SELECT id FROM public.comments WHERE id = 'cc000000-0000-0000-0000-000000000002' FOR UPDATE;
SET application_name = 'tv46_a_locked';
DO $$
DECLARE deadline timestamptz := clock_timestamp() + interval '8 seconds';
BEGIN
  LOOP
    PERFORM pg_stat_clear_snapshot();
    EXIT WHEN EXISTS (
      SELECT 1 FROM pg_stat_activity b
      WHERE b.application_name = 'tv46_b'
        AND b.wait_event_type = 'Lock'
        AND pg_backend_pid() = ANY(pg_blocking_pids(b.pid))
    );
    IF clock_timestamp() > deadline THEN
      RAISE EXCEPTION 'TV4.6: Session B did not reach lock wait within 8 seconds';
    END IF;
    PERFORM pg_sleep(0.05);
  END LOOP;
END $$;
SELECT set_config('request.jwt.claims',
  '{"sub":"22000000-0000-0000-0000-000000000009","role":"authenticated"}', false);
SET LOCAL ROLE forkensics_executor;
SELECT public.remove_content('comment',
  'cc000000-0000-0000-0000-000000000002',
  '22000000-0000-0000-0000-000000000009',
  NULL, 'TV4.6 moderator removal');
COMMIT;
SESSION_A_TV46
) > "$TMPFILE_O" 2>&1 &
PID_O=$!

# ---- Session B: report_content — loses (FK_NOT_FOUND) ----
TMPFILE_P=$(mktemp)
(
sleep 0.1
$PSQL -q <<'SESSION_B_TV46'
SET application_name = 'tv46_b';
SET statement_timeout = '20s';
BEGIN;
SELECT set_config('request.jwt.claims',
  '{"sub":"22000000-0000-0000-0000-000000000014","role":"authenticated"}', false);
DO $$
DECLARE deadline timestamptz := clock_timestamp() + interval '8 seconds';
BEGIN
  LOOP
    PERFORM pg_stat_clear_snapshot();
    EXIT WHEN EXISTS (
      SELECT 1 FROM pg_stat_activity
      WHERE application_name = 'tv46_a_locked'
    );
    IF clock_timestamp() > deadline THEN
      RAISE EXCEPTION 'TV4.6 B: Session A did not signal lock-ready within 8 seconds';
    END IF;
    PERFORM pg_sleep(0.05);
  END LOOP;
END $$;
SELECT public.report_content('comment',
  'cc000000-0000-0000-0000-000000000002', 'spam', NULL);
COMMIT;
SESSION_B_TV46
) > "$TMPFILE_P" 2>&1 &
PID_P=$!

R_O=0; R_P=0
wait "$PID_O" || R_O=$?
wait "$PID_P" || R_P=$?

if [ "$R_O" -ne 0 ]; then
  echo "[V4 harness] FAIL TV4.6: Remover (A) exited non-zero ($R_O)."
  echo "--- Session A output ---"; cat "$TMPFILE_O"
  echo "--- Session B output ---"; cat "$TMPFILE_P"
  rm -f "$TMPFILE_O" "$TMPFILE_P"; exit 1
fi
echo "[V4 harness] PASS TV4.6: Remover (A) exited 0."

if [ "$R_P" -eq 0 ]; then
  echo "[V4 harness] FAIL TV4.6: Reporter (B) exited 0 — expected FK_NOT_FOUND."
  echo "--- Session A output ---"; cat "$TMPFILE_O"
  echo "--- Session B output ---"; cat "$TMPFILE_P"
  rm -f "$TMPFILE_O" "$TMPFILE_P"; exit 1
fi
grep -q 'FK_NOT_FOUND' "$TMPFILE_P" || {
  echo "[V4 harness] FAIL TV4.6: Reporter (B) non-zero but no FK_NOT_FOUND in output."
  echo "--- Session A output ---"; cat "$TMPFILE_O"
  echo "--- Session B output ---"; cat "$TMPFILE_P"
  rm -f "$TMPFILE_O" "$TMPFILE_P"; exit 1
}
echo "[V4 harness] PASS TV4.6: Reporter (B) failed with FK_NOT_FOUND."
rm -f "$TMPFILE_O" "$TMPFILE_P"

COMMENT6_REMOVED=$($PSQL -tAc \
  "SELECT moderator_removed_at IS NOT NULL FROM public.comments WHERE id='cc000000-0000-0000-0000-000000000002'")
[ "$COMMENT6_REMOVED" = "t" ] || { echo "[V4 harness] FAIL TV4.6 DB: comment6.moderator_removed_at NULL."; exit 1; }
echo "[V4 harness] PASS TV4.6 DB: comment6.moderator_removed_at IS NOT NULL"

REPORT6_COUNT=$($PSQL -tAc \
  "SELECT COUNT(*) FROM public.content_reports WHERE target_type='comment' AND target_id='cc000000-0000-0000-0000-000000000002'")
[ "$REPORT6_COUNT" = "0" ] || { echo "[V4 harness] FAIL TV4.6 DB: report6 count=$REPORT6_COUNT, expected 0."; exit 1; }
echo "[V4 harness] PASS TV4.6 DB: content_reports for comment6 = 0 (reporter rolled back)"

echo ""

# =============================================================================
# TV4.7 — report_content('clue') races remove_content('clue')
#         Session A (reporter) wins; B (remover) unblocks after A commits.
#
# Lock order:
#   report_content('clue'): clue FOR UPDATE → case FOR UPDATE
#   remove_content('clue'): clue FOR UPDATE → content_reports FOR UPDATE
#
# Both take clue lock first → A wins deterministically.
#   A exits 0 (report recorded); B exits 0 (clue removed, report actioned)
#   DB: clue7.moderator_removed_at IS NOT NULL; report status='actioned'
# =============================================================================
echo "--- TV4.7: report_content vs remove_content on clue7 (report wins) ---"

# Reuses Poster5/Group5/Case5/Inv5 — all already inserted
$PSQL -v ON_ERROR_STOP=1 -q <<'FIXTURE_TV47'
INSERT INTO public.clues (id, case_id, poster_id, text)
VALUES ('dd000000-0000-0000-0000-000000000001',
        '55000000-0000-0000-0000-000000000005',
        '22000000-0000-0000-0000-000000000008',
        'TV4.7 test clue content')
ON CONFLICT DO NOTHING;
FIXTURE_TV47
echo "[V4 harness] TV4.7 fixture inserted."

TMPFILE_Q=$(mktemp)
(
$PSQL -v ON_ERROR_STOP=1 -q <<'SESSION_A_TV47'
SET application_name = 'tv47_a';
SET statement_timeout = '20s';
BEGIN;
SELECT id FROM public.clues WHERE id = 'dd000000-0000-0000-0000-000000000001' FOR UPDATE;
SET application_name = 'tv47_a_locked';
DO $$
DECLARE deadline timestamptz := clock_timestamp() + interval '8 seconds';
BEGIN
  LOOP
    PERFORM pg_stat_clear_snapshot();
    EXIT WHEN EXISTS (
      SELECT 1 FROM pg_stat_activity b
      WHERE b.application_name = 'tv47_b'
        AND b.wait_event_type = 'Lock'
        AND pg_backend_pid() = ANY(pg_blocking_pids(b.pid))
    );
    IF clock_timestamp() > deadline THEN
      RAISE EXCEPTION 'TV4.7: Session B did not reach lock wait within 8 seconds';
    END IF;
    PERFORM pg_sleep(0.05);
  END LOOP;
END $$;
SELECT set_config('request.jwt.claims',
  '{"sub":"22000000-0000-0000-0000-000000000013","role":"authenticated"}', false);
SELECT public.report_content('clue',
  'dd000000-0000-0000-0000-000000000001', 'spam', NULL);
COMMIT;
SESSION_A_TV47
) > "$TMPFILE_Q" 2>&1 &
PID_Q=$!

TMPFILE_R=$(mktemp)
(
sleep 0.1
$PSQL -v ON_ERROR_STOP=1 -q <<'SESSION_B_TV47'
SET application_name = 'tv47_b';
SET statement_timeout = '20s';
BEGIN;
SELECT set_config('request.jwt.claims',
  '{"sub":"22000000-0000-0000-0000-000000000008","role":"authenticated"}', false);
DO $$
DECLARE deadline timestamptz := clock_timestamp() + interval '8 seconds';
BEGIN
  LOOP
    PERFORM pg_stat_clear_snapshot();
    EXIT WHEN EXISTS (
      SELECT 1 FROM pg_stat_activity
      WHERE application_name = 'tv47_a_locked'
    );
    IF clock_timestamp() > deadline THEN
      RAISE EXCEPTION 'TV4.7 B: Session A did not signal lock-ready within 8 seconds';
    END IF;
    PERFORM pg_sleep(0.05);
  END LOOP;
END $$;
SET LOCAL ROLE forkensics_executor;
SELECT public.remove_content('clue',
  'dd000000-0000-0000-0000-000000000001',
  '22000000-0000-0000-0000-000000000008',
  NULL, 'TV4.7 moderator clue removal');
COMMIT;
SESSION_B_TV47
) > "$TMPFILE_R" 2>&1 &
PID_R=$!

R_Q=0; R_R=0
wait "$PID_Q" || R_Q=$?
wait "$PID_R" || R_R=$?

if [ "$R_Q" -ne 0 ]; then
  echo "[V4 harness] FAIL TV4.7: Reporter (A) exited non-zero ($R_Q)."
  echo "--- Session A output ---"; cat "$TMPFILE_Q"
  echo "--- Session B output ---"; cat "$TMPFILE_R"
  rm -f "$TMPFILE_Q" "$TMPFILE_R"; exit 1
fi
if [ "$R_R" -ne 0 ]; then
  echo "[V4 harness] FAIL TV4.7: Remover (B) exited non-zero ($R_R)."
  echo "--- Session A output ---"; cat "$TMPFILE_Q"
  echo "--- Session B output ---"; cat "$TMPFILE_R"
  rm -f "$TMPFILE_Q" "$TMPFILE_R"; exit 1
fi
echo "[V4 harness] PASS TV4.7 session outcomes: both exited 0."
rm -f "$TMPFILE_Q" "$TMPFILE_R"

CLUE7_REMOVED=$($PSQL -tAc \
  "SELECT moderator_removed_at IS NOT NULL FROM public.clues WHERE id='dd000000-0000-0000-0000-000000000001'")
[ "$CLUE7_REMOVED" = "t" ] || { echo "[V4 harness] FAIL TV4.7 DB: clue7.moderator_removed_at NULL."; exit 1; }
echo "[V4 harness] PASS TV4.7 DB: clue7.moderator_removed_at IS NOT NULL"

REPORT7_STATUS=$($PSQL -tAc \
  "SELECT status FROM public.content_reports WHERE target_type='clue' AND target_id='dd000000-0000-0000-0000-000000000001' ORDER BY created_at DESC LIMIT 1")
[ "$REPORT7_STATUS" = "actioned" ] || { echo "[V4 harness] FAIL TV4.7 DB: report7 status='$REPORT7_STATUS', expected 'actioned'."; exit 1; }
echo "[V4 harness] PASS TV4.7 DB: content_report for clue7 status='actioned'"

echo ""

# =============================================================================
# TV4.8 — remove_content('clue') races report_content('clue')
#         Session A (remover) wins; B (reporter) finds clue already removed.
#   A exits 0; B exits non-zero (FK_NOT_FOUND)
#   DB: clue8.moderator_removed_at IS NOT NULL; no content_report for clue8
# =============================================================================
echo "--- TV4.8: remove_content vs report_content on clue8 (remove wins) ---"

$PSQL -v ON_ERROR_STOP=1 -q <<'FIXTURE_TV48'
INSERT INTO public.clues (id, case_id, poster_id, text)
VALUES ('dd000000-0000-0000-0000-000000000002',
        '55000000-0000-0000-0000-000000000005',
        '22000000-0000-0000-0000-000000000008',
        'TV4.8 test clue content')
ON CONFLICT DO NOTHING;
FIXTURE_TV48
echo "[V4 harness] TV4.8 fixture inserted."

TMPFILE_S=$(mktemp)
(
$PSQL -v ON_ERROR_STOP=1 -q <<'SESSION_A_TV48'
SET application_name = 'tv48_a';
SET statement_timeout = '20s';
BEGIN;
SELECT id FROM public.clues WHERE id = 'dd000000-0000-0000-0000-000000000002' FOR UPDATE;
SET application_name = 'tv48_a_locked';
DO $$
DECLARE deadline timestamptz := clock_timestamp() + interval '8 seconds';
BEGIN
  LOOP
    PERFORM pg_stat_clear_snapshot();
    EXIT WHEN EXISTS (
      SELECT 1 FROM pg_stat_activity b
      WHERE b.application_name = 'tv48_b'
        AND b.wait_event_type = 'Lock'
        AND pg_backend_pid() = ANY(pg_blocking_pids(b.pid))
    );
    IF clock_timestamp() > deadline THEN
      RAISE EXCEPTION 'TV4.8: Session B did not reach lock wait within 8 seconds';
    END IF;
    PERFORM pg_sleep(0.05);
  END LOOP;
END $$;
SELECT set_config('request.jwt.claims',
  '{"sub":"22000000-0000-0000-0000-000000000008","role":"authenticated"}', false);
SET LOCAL ROLE forkensics_executor;
SELECT public.remove_content('clue',
  'dd000000-0000-0000-0000-000000000002',
  '22000000-0000-0000-0000-000000000008',
  NULL, 'TV4.8 moderator clue removal');
COMMIT;
SESSION_A_TV48
) > "$TMPFILE_S" 2>&1 &
PID_S=$!

TMPFILE_T=$(mktemp)
(
sleep 0.1
$PSQL -q <<'SESSION_B_TV48'
SET application_name = 'tv48_b';
SET statement_timeout = '20s';
BEGIN;
SELECT set_config('request.jwt.claims',
  '{"sub":"22000000-0000-0000-0000-000000000013","role":"authenticated"}', false);
DO $$
DECLARE deadline timestamptz := clock_timestamp() + interval '8 seconds';
BEGIN
  LOOP
    PERFORM pg_stat_clear_snapshot();
    EXIT WHEN EXISTS (
      SELECT 1 FROM pg_stat_activity
      WHERE application_name = 'tv48_a_locked'
    );
    IF clock_timestamp() > deadline THEN
      RAISE EXCEPTION 'TV4.8 B: Session A did not signal lock-ready within 8 seconds';
    END IF;
    PERFORM pg_sleep(0.05);
  END LOOP;
END $$;
SELECT public.report_content('clue',
  'dd000000-0000-0000-0000-000000000002', 'spam', NULL);
COMMIT;
SESSION_B_TV48
) > "$TMPFILE_T" 2>&1 &
PID_T=$!

R_S=0; R_T=0
wait "$PID_S" || R_S=$?
wait "$PID_T" || R_T=$?

if [ "$R_S" -ne 0 ]; then
  echo "[V4 harness] FAIL TV4.8: Remover (A) exited non-zero ($R_S)."
  echo "--- Session A output ---"; cat "$TMPFILE_S"
  echo "--- Session B output ---"; cat "$TMPFILE_T"
  rm -f "$TMPFILE_S" "$TMPFILE_T"; exit 1
fi
echo "[V4 harness] PASS TV4.8: Remover (A) exited 0."

if [ "$R_T" -eq 0 ]; then
  echo "[V4 harness] FAIL TV4.8: Reporter (B) exited 0 — expected FK_NOT_FOUND."
  echo "--- Session A output ---"; cat "$TMPFILE_S"
  echo "--- Session B output ---"; cat "$TMPFILE_T"
  rm -f "$TMPFILE_S" "$TMPFILE_T"; exit 1
fi
grep -q 'FK_NOT_FOUND' "$TMPFILE_T" || {
  echo "[V4 harness] FAIL TV4.8: Reporter (B) non-zero but no FK_NOT_FOUND."
  echo "--- Session A output ---"; cat "$TMPFILE_S"
  echo "--- Session B output ---"; cat "$TMPFILE_T"
  rm -f "$TMPFILE_S" "$TMPFILE_T"; exit 1
}
echo "[V4 harness] PASS TV4.8: Reporter (B) failed with FK_NOT_FOUND."
rm -f "$TMPFILE_S" "$TMPFILE_T"

CLUE8_REMOVED=$($PSQL -tAc \
  "SELECT moderator_removed_at IS NOT NULL FROM public.clues WHERE id='dd000000-0000-0000-0000-000000000002'")
[ "$CLUE8_REMOVED" = "t" ] || { echo "[V4 harness] FAIL TV4.8 DB: clue8.moderator_removed_at NULL."; exit 1; }
echo "[V4 harness] PASS TV4.8 DB: clue8.moderator_removed_at IS NOT NULL"

REPORT8_COUNT=$($PSQL -tAc \
  "SELECT COUNT(*) FROM public.content_reports WHERE target_type='clue' AND target_id='dd000000-0000-0000-0000-000000000002'")
[ "$REPORT8_COUNT" = "0" ] || { echo "[V4 harness] FAIL TV4.8 DB: report8 count=$REPORT8_COUNT, expected 0."; exit 1; }
echo "[V4 harness] PASS TV4.8 DB: content_reports for clue8 = 0 (reporter rolled back)"

echo ""

# =============================================================================
# TV4.9 — report_content('media_object') linkage race:
#         media_object_id changed on the case between step-a (provisional lookup)
#         and step-b (FOR UPDATE recheck) → FK_NOT_FOUND.
#
# Lock order in report_content('media_object'):
#   step a: SELECT id FROM cases WHERE media_object_id=Media9 LIMIT 1
#           (plain SELECT — NOT blocked by another session's FOR UPDATE on the row)
#   step b: SELECT ... FROM cases WHERE id=Case9 FOR UPDATE
#           (blocked by B's lock; unblocks with new committed value)
#
# Scenario:
#   Session B (replacer) acquires Case9 FOR UPDATE, then polls until A's step b
#   is confirmed blocked, then changes media_object_id to Media9b and commits.
#   Session A (reporter) calls report_content: step a finds Case9 (B's lock doesn't
#   block plain SELECTs); step b blocks on Case9; unblocks after B commits and sees
#   media_object_id=Media9b ≠ Media9 → FK_NOT_FOUND.
#
# Expected outcomes:
#   Session A (reporter): exits non-zero with FK_NOT_FOUND
#   Session B (replacer): exits 0
#   DB: Case9.media_object_id = Media9b, 0 content_reports for Media9
# =============================================================================
echo "--- TV4.9: report_content('media_object') linkage race (media_object_id changed under lock) ---"

# ---- Fixture setup for TV4.9 ----
$PSQL -v ON_ERROR_STOP=1 -q <<'FIXTURE_TV49'
-- Poster9
INSERT INTO public.profiles (id, display_name, onboarding_complete, is_active)
VALUES ('22000000-0000-0000-0000-000000000015', 'TV49 Poster9', true, true)
ON CONFLICT DO NOTHING;
INSERT INTO private.profile_suspensions (profile_id, is_suspended)
VALUES ('22000000-0000-0000-0000-000000000015', false)
ON CONFLICT DO NOTHING;

-- Reporter9 (will call report_content; is_active=true required by FK_FORBIDDEN guard)
INSERT INTO public.profiles (id, display_name, onboarding_complete, is_active)
VALUES ('22000000-0000-0000-0000-000000000016', 'TV49 Reporter9', true, true)
ON CONFLICT DO NOTHING;
INSERT INTO private.profile_suspensions (profile_id, is_suspended)
VALUES ('22000000-0000-0000-0000-000000000016', false)
ON CONFLICT DO NOTHING;

-- Group9 (needed for Investigation9 → can_view_case check)
INSERT INTO public.groups (id, name, created_by)
VALUES ('33000000-0000-0000-0000-000000000009', 'TV49 Group9',
        '22000000-0000-0000-0000-000000000015')
ON CONFLICT DO NOTHING;
INSERT INTO public.group_members (group_id, player_id, role)
VALUES ('33000000-0000-0000-0000-000000000009',
        '22000000-0000-0000-0000-000000000015', 'owner')
ON CONFLICT DO NOTHING;
INSERT INTO public.group_members (group_id, player_id, role)
VALUES ('33000000-0000-0000-0000-000000000009',
        '22000000-0000-0000-0000-000000000016', 'member')
ON CONFLICT DO NOTHING;

-- Media9 (status='ready'; initially linked to Case9)
INSERT INTO public.media_objects (id, uploader_id, mime_type, status, re_encoded_at)
VALUES ('44000000-0000-0000-0000-000000000009',
        '22000000-0000-0000-0000-000000000015', 'image/webp', 'ready', now())
ON CONFLICT DO NOTHING;
INSERT INTO private.media_storage_keys
  (media_object_id, storage_key, sha256_hash, re_encoded_storage_key)
VALUES ('44000000-0000-0000-0000-000000000009',
        'uploads/tv49/orig9.jpg', repeat('9', 64), 'cases/tv49/9/display.webp')
ON CONFLICT DO NOTHING;

-- Media9b (status='ready'; replacer swaps Case9.media_object_id to this UUID)
-- Must exist in media_objects to satisfy the cases.media_object_id FK constraint.
INSERT INTO public.media_objects (id, uploader_id, mime_type, status, re_encoded_at)
VALUES ('44000000-0000-0000-0000-000000000010',
        '22000000-0000-0000-0000-000000000015', 'image/webp', 'ready', now())
ON CONFLICT DO NOTHING;

-- Case9 — launched, media_object_id=Media9
SELECT set_config('request.jwt.claims',
  '{"sub":"22000000-0000-0000-0000-000000000015","role":"authenticated"}', false);
INSERT INTO public.cases (id, media_object_id)
VALUES ('55000000-0000-0000-0000-000000000009',
        '44000000-0000-0000-0000-000000000009')
ON CONFLICT DO NOTHING;
INSERT INTO public.case_secrets
  (case_id, display_dish, canonical_dish, display_restaurant, canonical_restaurant)
VALUES ('55000000-0000-0000-0000-000000000009',
        'TV49 Dish9', 'tv49 dish9', 'TV49 Place9', 'tv49 place9')
ON CONFLICT DO NOTHING;
SET ROLE forkensics_executor;
UPDATE public.cases SET state = 'launched',
  posted_at   = now() - interval '1 hour',
  deadline_at = now() + interval '2 hours'
WHERE id = '55000000-0000-0000-0000-000000000009';
RESET ROLE;

-- Investigation9 + Reporter9 as member (can_view_case(Case9)=true for Reporter9)
INSERT INTO public.investigations
  (investigation_id, case_id, group_id, status)
VALUES ('77000000-0000-0000-0000-000000000009',
        '55000000-0000-0000-0000-000000000009',
        '33000000-0000-0000-0000-000000000009', 'active')
ON CONFLICT DO NOTHING;
INSERT INTO public.investigation_members
  (investigation_id, player_id, snapshot_display_name, snapshot_avatar_color, eligibility_status)
VALUES ('77000000-0000-0000-0000-000000000009',
        '22000000-0000-0000-0000-000000000016',
        'TV49 Reporter9', 'purple', 'eligible')
ON CONFLICT DO NOTHING;
FIXTURE_TV49
echo "[V4 harness] TV4.9 fixtures inserted."

# Session B (replacer) starts first: acquires Case9 FOR UPDATE, polls until A is
# confirmed blocked on Case9, then replaces media_object_id with Media9b.
TMPFILE_U=$(mktemp)
(
$PSQL <<"SESSION_B_TV49"
SET application_name = 'tv49_b';
SET statement_timeout = '10s';
BEGIN;
SELECT id FROM public.cases
WHERE id = '55000000-0000-0000-0000-000000000009' FOR UPDATE;
DO $$
DECLARE deadline timestamptz := clock_timestamp() + interval '8s';
BEGIN
  LOOP
    PERFORM pg_stat_clear_snapshot();
    EXIT WHEN EXISTS (
      SELECT 1 FROM pg_stat_activity b
      WHERE b.application_name = 'tv49_a'
        AND b.wait_event_type = 'Lock'
        AND pg_backend_pid() = ANY(pg_blocking_pids(b.pid))
    );
    IF clock_timestamp() > deadline THEN
      RAISE EXCEPTION 'TV4.9: Session A (reporter) did not reach Lock wait within 8s';
    END IF;
    PERFORM pg_sleep(0.05);
  END LOOP;
END $$;
-- Unlink Media9: point Case9 to Media9b; reporter's step-b recheck will see the change.
UPDATE public.cases
SET media_object_id = '44000000-0000-0000-0000-000000000010'
WHERE id = '55000000-0000-0000-0000-000000000009';
COMMIT;
SESSION_B_TV49
) > "$TMPFILE_U" 2>&1 &
PID_U=$!

# Session A (reporter) starts 0.1s later.
# report_content step-a: plain SELECT finds Case9 via Media9 (not blocked by B's lock).
# report_content step-b: SELECT Case9 FOR UPDATE → blocked by B.
# After B commits: re-read sees media_object_id=Media9b ≠ Media9 → FK_NOT_FOUND.
TMPFILE_V=$(mktemp)
(
sleep 0.1
$PSQL <<"SESSION_A_TV49"
SET application_name = 'tv49_a';
SET statement_timeout = '10s';
SET lock_timeout = '5s';
SELECT set_config('request.jwt.claims',
  '{"sub":"22000000-0000-0000-0000-000000000016","role":"authenticated"}', false);
SELECT * FROM public.report_content('media_object',
  '44000000-0000-0000-0000-000000000009', 'spam', NULL);
SESSION_A_TV49
) > "$TMPFILE_V" 2>&1 &
PID_V=$!

R_U=0; R_V=0
wait "$PID_U" || R_U=$?
wait "$PID_V" || R_V=$?

if [ "$R_U" -ne 0 ]; then
  echo "[V4 harness] FAIL TV4.9: Replacer (B) exited non-zero ($R_U)."
  cat "$TMPFILE_U"; rm -f "$TMPFILE_U" "$TMPFILE_V"; exit 1
fi
echo "[V4 harness] PASS TV4.9: Replacer (B) exited 0."

if [ "$R_V" -eq 0 ]; then
  echo "[V4 harness] FAIL TV4.9: Reporter (A) exited 0 — expected FK_NOT_FOUND."
  rm -f "$TMPFILE_U" "$TMPFILE_V"; exit 1
fi
grep -q 'FK_NOT_FOUND' "$TMPFILE_V" || {
  echo "[V4 harness] FAIL TV4.9: Reporter (A) non-zero but no FK_NOT_FOUND in output."
  cat "$TMPFILE_V"; rm -f "$TMPFILE_U" "$TMPFILE_V"; exit 1
}
echo "[V4 harness] PASS TV4.9: Reporter (A) failed with FK_NOT_FOUND (linkage race: step-b recheck caught media_object_id change)."
rm -f "$TMPFILE_U" "$TMPFILE_V"

CASE9_MEDIA=$($PSQL -tAc \
  "SELECT media_object_id FROM public.cases WHERE id='55000000-0000-0000-0000-000000000009'")
[ "$CASE9_MEDIA" = "44000000-0000-0000-0000-000000000010" ] || {
  echo "[V4 harness] FAIL TV4.9 DB: Case9.media_object_id='$CASE9_MEDIA', expected Media9b (44...010)."; exit 1
}
echo "[V4 harness] PASS TV4.9 DB: Case9.media_object_id=Media9b (replacer committed successfully)"

REPORT9_COUNT=$($PSQL -tAc \
  "SELECT COUNT(*) FROM public.content_reports WHERE target_type='media_object' AND target_id='44000000-0000-0000-0000-000000000009'")
[ "$REPORT9_COUNT" = "0" ] || {
  echo "[V4 harness] FAIL TV4.9 DB: content_report for Media9 count=$REPORT9_COUNT, expected 0."; exit 1
}
echo "[V4 harness] PASS TV4.9 DB: 0 content_reports for Media9 (reporter rolled back before INSERT)"

echo ""
echo "[V4 harness] DONE. All TV4.1 – TV4.9 assertions passed."
echo ""
echo "NOTE: Fixture rows remain in the database."
echo "Run 'supabase db reset' before the next test run."
