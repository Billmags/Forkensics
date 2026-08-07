#!/usr/bin/env bash
# =============================================================================
# test_alias_concurrency.sh
# Forkensics — Two-session alias/first-guess concurrency test
#
# Purpose:
#   Verify that guard_alias_edits() (SELECT FOR UPDATE on challenge_secrets)
#   correctly serializes concurrent alias inserts against a concurrent guess.
#
#   The race condition: if Session A holds the FOR UPDATE lock on
#   challenge_secrets while inserting an alias, Session B's guess (which
#   also updates challenge_secrets.has_first_guess) must block until A
#   commits. Once B commits (has_first_guess = true), any subsequent alias
#   insert is rejected.
#
# Requirements:
#   - Supabase CLI running locally: `supabase start`
#   - Migration V1__initial_schema.sql already applied
#   - psql available in PATH
#   - Runs OUTSIDE the test transaction (uses real data; cleans up after)
#
# Usage:
#   chmod +x 08_Migration/tests/test_alias_concurrency.sh
#   ./08_Migration/tests/test_alias_concurrency.sh
# =============================================================================

set -euo pipefail

DB_URL="${SUPABASE_DB_URL:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}"
FAIL=0

echo ""
echo "============================================================="
echo "Alias Concurrency Test (two-session)"
echo "============================================================="
echo ""

# -------------------------------------------------------
# Setup: create test data that persists (not in a TX)
# -------------------------------------------------------
echo "--- Setup: creating test data ---"

SETUP_RAW=$(psql "$DB_URL" -t -A -c "
DO \$\$
DECLARE
  v_poster uuid := gen_random_uuid();
  v_player uuid := gen_random_uuid();
  v_group  uuid;
  v_cid    uuid;
  v_mid    uuid;
  v_token  text;
BEGIN
  -- Poster
  INSERT INTO auth.users (id, email, raw_user_meta_data, created_at, updated_at)
  VALUES (v_poster, v_poster||'@conc.test',
          json_build_object('display_name','ConcPoster')::jsonb, now(), now());
  UPDATE public.profiles SET display_name = 'ConcPoster', onboarding_complete = true
  WHERE id = v_poster;

  -- Player
  INSERT INTO auth.users (id, email, raw_user_meta_data, created_at, updated_at)
  VALUES (v_player, v_player||'@conc.test',
          json_build_object('display_name','ConcPlayer')::jsonb, now(), now());
  UPDATE public.profiles SET display_name = 'ConcPlayer', onboarding_complete = true
  WHERE id = v_player;

  -- Group + member
  PERFORM set_config('request.jwt.claims', json_build_object('sub',v_poster::text,'role','authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  v_group := public.create_group('ConcGroup');
  v_token := public.create_group_invite(v_group);
  RESET ROLE; PERFORM set_config('request.jwt.claims','',true);

  PERFORM set_config('request.jwt.claims', json_build_object('sub',v_player::text,'role','authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  PERFORM public.redeem_group_invite(v_token);
  RESET ROLE; PERFORM set_config('request.jwt.claims','',true);

  -- Draft challenge
  v_mid := gen_random_uuid();
  INSERT INTO public.media_objects (id, uploader_id, mime_type, file_size_bytes, status)
  VALUES (v_mid, v_poster, 'image/jpeg', 100000, 'ready');
  PERFORM set_config('request.jwt.claims', json_build_object('sub',v_poster::text,'role','authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  INSERT INTO public.challenges (group_id, media_object_id) VALUES (v_group, v_mid) RETURNING id INTO v_cid;
  INSERT INTO public.challenge_secrets (challenge_id, display_dish, canonical_dish,
    display_restaurant, canonical_restaurant)
  VALUES (v_cid, 'Ramen','ramen','Ichiran','ichiran');
  PERFORM public.activate_challenge(v_cid);
  RESET ROLE; PERFORM set_config('request.jwt.claims','',true);

  -- Include group and media IDs so cleanup can run in correct dependency order
  -- without querying through already-deleted join paths.
  RAISE NOTICE 'SETUP_IDS:%:%:%:%:%', v_poster, v_player, v_cid, v_group, v_mid;
END;
\$\$;
" 2>&1) || true

IDS=$(echo "$SETUP_RAW" | grep 'SETUP_IDS' | sed 's/.*SETUP_IDS://') || true

POSTER_ID=$(echo "$IDS" | cut -d: -f1)
PLAYER_ID=$(echo "$IDS" | cut -d: -f2)
CID=$(echo "$IDS"       | cut -d: -f3)
GROUP_ID=$(echo "$IDS"  | cut -d: -f4)
MID=$(echo "$IDS"       | cut -d: -f5)

if [[ -z "$POSTER_ID" || -z "$PLAYER_ID" || -z "$CID" || -z "$GROUP_ID" || -z "$MID" ]]; then
  echo "FAIL: Could not extract setup IDs."
  echo "--- Raw setup output ---"
  echo "$SETUP_RAW"
  echo "--- End raw output ---"
  exit 1
fi

echo "  Poster:    $POSTER_ID"
echo "  Player:    $PLAYER_ID"
echo "  Challenge: $CID"
echo "  Group:     $GROUP_ID"
echo "  Media:     $MID"
echo ""

# -------------------------------------------------------
# Test 1: Session A inserts alias (holds lock), Session B
#         submits guess (blocks), A commits, B unblocks.
#         Verify: alias exists AND has_first_guess = true,
#         AND Session B's elapsed time proves it blocked.
# -------------------------------------------------------
echo "--- Test: Session A alias + Session B guess (concurrent) ---"

# Session A: BEGIN, INSERT alias, sleep 2s to hold the FOR UPDATE lock, COMMIT
psql "$DB_URL" -c "
BEGIN;
SELECT set_config('request.jwt.claims',
  json_build_object('sub','$POSTER_ID','role','authenticated')::text, true);
SET LOCAL ROLE authenticated;
INSERT INTO public.challenge_answer_aliases (challenge_id, field, display_value, created_by)
VALUES ('$CID', 'dish', 'Concurrent Alias', '$POSTER_ID');
RESET ROLE;
SELECT pg_sleep(2);
COMMIT;
" &
SESSION_A_PID=$!

# Give Session A time to take the FOR UPDATE lock (the alias INSERT fires guard_alias_edits
# which does SELECT FOR UPDATE on challenge_secrets)
sleep 0.5

# Session B: INSERT guess (triggers set_guess_receipt_fields which UPDATEs challenge_secrets)
# This UPDATE blocks on the same row until Session A commits (~1.5 s wait expected).
SESSION_B_START_MS=$(python3 -c "import time; print(int(time.time()*1000))")
SESSION_B_OUTPUT=$(psql "$DB_URL" -c "
SELECT set_config('request.jwt.claims',
  json_build_object('sub','$PLAYER_ID','role','authenticated')::text, true);
SET LOCAL ROLE authenticated;
INSERT INTO public.guess_attempts (challenge_id, player_id, race, dish_guess)
VALUES ('$CID', '$PLAYER_ID', 'what', 'Ramen');
RESET ROLE;
" 2>&1)
SESSION_B_EXIT=$?
SESSION_B_END_MS=$(python3 -c "import time; print(int(time.time()*1000))")
SESSION_B_ELAPSED=$(( SESSION_B_END_MS - SESSION_B_START_MS ))

# Wait for Session A to finish and capture its exit code
wait $SESSION_A_PID
SESSION_A_EXIT=$?

echo "  Session A exit: $SESSION_A_EXIT  Session B exit: $SESSION_B_EXIT  Session B elapsed: ${SESSION_B_ELAPSED}ms"

if [[ $SESSION_A_EXIT -ne 0 ]]; then
  echo "FAIL: Session A exited with code $SESSION_A_EXIT"
  FAIL=1
fi
if [[ $SESSION_B_EXIT -ne 0 ]]; then
  echo "FAIL: Session B exited with code $SESSION_B_EXIT — output: $SESSION_B_OUTPUT"
  FAIL=1
fi

# Session B should have waited for Session A's FOR UPDATE lock (~1.5 s minimum).
# If it completed faster than 1000ms, the lock did not actually block it.
if [[ $SESSION_B_ELAPSED -lt 1000 ]]; then
  echo "FAIL: Session B completed in ${SESSION_B_ELAPSED}ms — did not block on Session A's FOR UPDATE lock"
  FAIL=1
fi

# Verify end state
RESULT=$(psql "$DB_URL" -t -A -c "
SELECT a.display_value, cs.has_first_guess
FROM public.challenge_answer_aliases a
JOIN public.challenge_secrets cs ON cs.challenge_id = a.challenge_id
WHERE a.challenge_id = '$CID' AND a.display_value = 'Concurrent Alias';
")

ALIAS_DISPLAY=$(echo "$RESULT" | cut -d'|' -f1)
HAS_FIRST=$(echo "$RESULT" | cut -d'|' -f2)

if [[ "$ALIAS_DISPLAY" == "Concurrent Alias" && "$HAS_FIRST" == "t" ]]; then
  echo "PASS: alias exists AND has_first_guess = true AND Session B blocked (${SESSION_B_ELAPSED}ms)"
else
  echo "FAIL: Expected alias='Concurrent Alias' and has_first_guess=true, got: $RESULT"
  FAIL=1
fi

# -------------------------------------------------------
# Test 2: After first guess, new alias insert must be rejected
# -------------------------------------------------------
echo ""
echo "--- Test: alias insert rejected after first guess ---"

ALIAS_REJECT=$(psql "$DB_URL" -c "
SELECT set_config('request.jwt.claims',
  json_build_object('sub','$POSTER_ID','role','authenticated')::text, true);
SET LOCAL ROLE authenticated;
INSERT INTO public.challenge_answer_aliases (challenge_id, field, display_value, created_by)
VALUES ('$CID', 'dish', 'Post-Guess Alias', '$POSTER_ID');
RESET ROLE;
" 2>&1) || true

if echo "$ALIAS_REJECT" | grep -q "aliases cannot be changed after first guess"; then
  echo "PASS: post-guess alias insert rejected with expected error"
else
  echo "FAIL: Expected rejection, got: $ALIAS_REJECT"
  FAIL=1
fi

# -------------------------------------------------------
# Cleanup: delete in dependency order using pre-captured IDs.
# Do NOT suppress errors — a cleanup failure means leaked fixtures.
# -------------------------------------------------------
echo ""
echo "--- Cleanup ---"
psql "$DB_URL" -c "
DELETE FROM public.guess_attempts           WHERE challenge_id = '$CID';
DELETE FROM public.challenge_answer_aliases WHERE challenge_id = '$CID';
DELETE FROM public.challenge_secrets        WHERE challenge_id = '$CID';
DELETE FROM public.eligible_participants    WHERE challenge_id = '$CID';
DELETE FROM public.challenges               WHERE id           = '$CID';
DELETE FROM public.group_members            WHERE group_id     = '$GROUP_ID';
DELETE FROM public.groups                   WHERE id           = '$GROUP_ID';
DELETE FROM public.media_objects            WHERE id           = '$MID';
DELETE FROM public.profiles                 WHERE id IN ('$POSTER_ID','$PLAYER_ID');
DELETE FROM auth.users                      WHERE id IN ('$POSTER_ID','$PLAYER_ID');
"

# Verify zero fixtures remain
REMAINING=$(psql "$DB_URL" -t -A -c "
SELECT
  (SELECT COUNT(*) FROM public.challenges WHERE id = '$CID') +
  (SELECT COUNT(*) FROM public.groups     WHERE id = '$GROUP_ID') +
  (SELECT COUNT(*) FROM public.profiles   WHERE id IN ('$POSTER_ID','$PLAYER_ID')) +
  (SELECT COUNT(*) FROM auth.users        WHERE id IN ('$POSTER_ID','$PLAYER_ID'));
")

if [[ "$REMAINING" -eq 0 ]]; then
  echo "  Cleanup verified: 0 fixture rows remain"
else
  echo "  WARN: $REMAINING fixture row(s) remain after cleanup"
  FAIL=1
fi
echo ""

# -------------------------------------------------------
# Result
# -------------------------------------------------------
echo "============================================================="
if [[ $FAIL -eq 0 ]]; then
  echo "ALL CONCURRENCY TESTS PASSED"
else
  echo "CONCURRENCY TESTS FAILED (see above)"
fi
echo "============================================================="
echo ""
exit $FAIL
