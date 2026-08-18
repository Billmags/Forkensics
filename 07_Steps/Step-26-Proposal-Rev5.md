# Step 26 Proposal — Case / Investigation Schema
**Revision:** 5  
**Status:** DRAFT — awaiting approval from Bill, Claude, and Codex before any code is written  
**Prerequisite:** Step 25 merged (`v0.2.0-upload-sessions`); Step 24.1 approved (pending implementation)  
**Supersedes:** Rev 4 (rejected — GPT review, 6 blockers)

---

## Changes From Rev 4

| Blocker | Fix |
|---|---|
| 1 | Removed `approve_case_media()` / `reject_case_media()`. Extended Step 24.1's approved `approve_photo()` and `reject_photo()` with V3 case-state side-effects. Removed `get_cleanable_media()` / `mark_cleanable_media_cleaned()` — cleanup handled by Step 24.1's `claim_moderation_media_cleanup()` (already handles `rejected` + `removed` with pending-report protection). Rejected media status: `'rejected'` (not `'removed'`). |
| 2 | Preserved V2 two-path cleanup separation: display file via `claim_moderation_media_cleanup()`; original file via `get_complete_sessions_pending_expiry_cleanup()`. `get_cleanable_media()` removed entirely. |
| 3 | `private.prepare_account_deletion()` fully rebuilt against cases/investigations. Step ordering fixed: media collection (Step B) before case cancellation (Step A). ALL `investigation_members` rows for the deleted player are anonymized (not just active). Exclusion events inserted only for active investigations where player was eligible. Quiescence workflow preserved as a separate call. |
| 4 | `cases.rules_version_id` column DEFAULT `'a0000000-0000-0000-0000-000000000001'` preserved (not trigger-only). `created_at DEFAULT clock_timestamp()` preserved. `media_object_id ON DELETE RESTRICT` preserved. `one_active_challenge_per_poster` predicate corrected for V3 states. Reactions migration uses add/backfill/FK-replace pattern. Explicit V1+Step 24.1 object inventory provided. |
| 5 | `launch_case()` now: locks case row `FOR UPDATE`; validates poster active/onboarded/not-suspended; rejects archived Tables; snapshots only active/onboarded/non-suspended members excluding blocked pairs; requires ≥ 1 eligible detective per investigation; uses single `v_now := clock_timestamp()` for both `posted_at` and deadline. |
| 6 | Poster sees guesses during `launched`, `locked`, AND `revealed` (V1 behavior; Bill confirmed). |

---

## 1. Purpose

Separate V1's `challenges` into:
- **Case** — the mystery photo, answers, clues, location. Poster-owned. Group-agnostic.
- **Investigation** — a Table's engagement with a case. Frozen participant snapshot, guesses, scoring, Table Talk.

One case → many investigations.

---

## 2. Confirmed Decisions

| Decision | Answer |
|---|---|
| Max Tables per launch | 10 |
| One locked attempt per player per race | Yes |
| Poster sees guesses | During `launched`, `locked`, and `revealed` — V1 behavior |

---

## 3. `public.cases` — Exact Column Set

All columns sourced from V1's `challenges`. Only marked differences.

```sql
CREATE TABLE public.cases (
  id                   uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  -- group_id: REMOVED in Phase 14 (kept through Phase 13 to allow dependent object migration)
  poster_id            uuid        NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  media_object_id      uuid        REFERENCES public.media_objects(id) ON DELETE RESTRICT,
                                   -- V1 is ON DELETE RESTRICT; preserved exactly
  state                text        NOT NULL DEFAULT 'draft'
                                   CHECK (state IN (
                                     'draft', 'ready', 'launched',
                                     'locked', 'revealed', 'retired', 'cancelled'
                                   )),
                                   -- 'active' is REMOVED from valid values after Phase 13
  duration_seconds     integer     NOT NULL DEFAULT 7200,
  public_city_display  text,
  rules_version_id     uuid        NOT NULL
                                   DEFAULT 'a0000000-0000-0000-0000-000000000001'
                                   REFERENCES public.rules_versions(id) ON DELETE RESTRICT,
                                   -- Column-level DEFAULT preserved from V1 challenges
  posted_at            timestamptz,   -- set to v_now when state → launched
  deadline_at          timestamptz,
  locked_at            timestamptz,
  revealed_at          timestamptz,
  cancelled_at         timestamptz,
  cancellation_reason  text,
  created_at           timestamptz NOT NULL DEFAULT clock_timestamp(),
                                   -- V1 uses clock_timestamp(), not now(); preserved

  CONSTRAINT cases_state_check
    CHECK (state IN ('draft','ready','launched','locked','revealed','retired','cancelled')),
  CONSTRAINT cases_duration_check
    CHECK (duration_seconds BETWEEN 3600 AND 86400
           AND duration_seconds % 3600 = 0),
  CONSTRAINT cases_cancellation_check
    CHECK (cancellation_reason IS NULL OR length(cancellation_reason) <= 500),
  CONSTRAINT cases_city_display_check
    CHECK (public_city_display IS NULL
           OR length(trim(public_city_display)) BETWEEN 1 AND 100)
);
```

Note: `cases_state_check` is defined once as a named table-level constraint — no inline CHECK on the column. The migration does not add `cases_state_check` as a column-level CHECK; the state validity constraint is only the table-level one.

**Index: `one_active_case_per_poster`** (replaces `one_active_challenge_per_poster`)
```sql
CREATE UNIQUE INDEX one_active_case_per_poster
  ON public.cases (poster_id)
  WHERE state IN ('draft','ready','launched','locked');
-- V1 had ('draft','active','locked'); 'active'→'launched', 'ready' is new; 'revealed' excluded.
```

The migration drops the V1 index and creates this replacement after Phase 13.

---

## 4. `public.case_secrets` (renamed from `challenge_secrets`)

`challenge_id → case_id`. Column types, constraints, trigger names, and RLS policy logic all preserved from V1. Updated to reference `cases` table.

---

## 5. `public.investigations`

```sql
CREATE TABLE public.investigations (
  investigation_id    uuid  PRIMARY KEY DEFAULT gen_random_uuid(),
  case_id             uuid  NOT NULL REFERENCES public.cases(id) ON DELETE RESTRICT,
  group_id            uuid  NOT NULL REFERENCES public.groups(id) ON DELETE RESTRICT,
  status              text  NOT NULL DEFAULT 'active'
                            CHECK (status IN ('active','cancelled','tombstoned')),
  cancelled_at        timestamptz,
  cancellation_reason text,
  created_at          timestamptz NOT NULL DEFAULT clock_timestamp(),
  UNIQUE (case_id, group_id)
);
```

`UNIQUE (case_id, group_id)` is the idempotency mechanism for `launch_case()`. No explicit `idempotency_key` column.

---

## 6. `public.investigation_members` (replaces `eligible_participants`)

```sql
CREATE TABLE public.investigation_members (
  investigation_id                  uuid  NOT NULL
                                          REFERENCES public.investigations(investigation_id)
                                          ON DELETE RESTRICT,
  player_id                         uuid  NOT NULL
                                          REFERENCES public.profiles(id) ON DELETE RESTRICT,
  snapshot_display_name             text  NOT NULL,
  snapshot_avatar_color             text  NOT NULL,
  snapshot_avatar_media_object_id   uuid
                                    REFERENCES public.media_objects(id) ON DELETE SET NULL,
  eligibility_status                text  NOT NULL DEFAULT 'eligible'
                                          CHECK (eligibility_status IN (
                                            'eligible', 'excluded', 'account_deleted'
                                          )),
  added_at                          timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY (investigation_id, player_id)
);
```

Snapshot taken at `launch_case()` execution. Only members who are `is_active = true AND onboarding_complete = true AND is_suspended = false` AND do NOT have a block pair with the poster are included. Poster excluded.

`snapshot_avatar_media_object_id ON DELETE SET NULL`: nulled if media object is deleted. Also cleared during account deletion (full anonymization).

---

## 7. `public.exclusion_events` — Investigation-Scoped

```sql
-- V1 columns preserved; V3 changes:
--   challenge_id  →  investigation_id uuid NOT NULL FK → investigations
--   case_id uuid NOT NULL FK → cases  (retained; cross-record integrity trigger verifies
--                                     investigations.case_id = exclusion_events.case_id)
--   UNIQUE (challenge_id, player_id)  →  UNIQUE (investigation_id, player_id)
--   reason CHECK preserved: 'withdrew' | 'removed' | 'account_deleted'
--   ee_excluded_by_check preserved
```

---

## 8. `public.guess_attempts` — V1 Structure Preserved Exactly

```sql
-- V1 columns preserved:
--   id, case_id (was challenge_id), player_id
--   race, dish_guess, restaurant_guess
--   received_at timestamptz NOT NULL DEFAULT clock_timestamp()
--   receipt_sequence bigint NOT NULL
--   client_submitted_at timestamptz
--   UNIQUE (case_id, receipt_sequence)
--   ga_race_check, ga_race_fields_check — PRESERVED EXACTLY

-- Two additions (Bill-confirmed):
--   idempotency_key uuid NOT NULL
--   UNIQUE (case_id, player_id, race)  -- one locked attempt per player per race

-- Migration: idempotency_key added nullable → backfill → NOT NULL
-- Migration: duplicate guard before UNIQUE index (none expected pre-launch)
```

---

## 9. Scoring Tables

### `score_runs`
V1 structure preserved. `challenge_id → case_id`. `investigation_id uuid NOT NULL` added (migration: nullable → backfill → NOT NULL). `UNIQUE (investigation_id, revision_number)` replaces `UNIQUE (challenge_id, revision_number)`. Cross-record integrity trigger: `investigations.case_id = score_runs.case_id`.

### `correction_events`
`challenge_id → case_id`. `resulting_score_run_id` DROPPED. `score_runs.triggering_correction_id` (already in V1) is the back-reference.

### `guess_judgments`
`challenge_id → case_id`. `investigation_id uuid NOT NULL` added. Cross-record integrity trigger.

### `score_events`
`challenge_id → case_id`. `investigation_id uuid NOT NULL` added. UNIQUE `(score_run_id, player_id)` preserved. Cross-record integrity trigger.

### `current_score_events` VIEW
```sql
DROP VIEW IF EXISTS public.current_score_events;

CREATE VIEW public.current_score_events
  WITH (security_invoker = true)
  AS
SELECT se.*
FROM public.score_events se
JOIN public.score_runs sr ON sr.id = se.score_run_id
WHERE sr.revision_number = (
  SELECT max(sr2.revision_number)
  FROM public.score_runs sr2
  WHERE sr2.investigation_id = sr.investigation_id
);

GRANT SELECT ON public.current_score_events TO authenticated;
```

---

## 10. `public.comments` and `public.reactions`

### `comments`
`challenge_id → case_id`. `investigation_id uuid NOT NULL` added (migration: nullable → backfill → NOT NULL). `ON DELETE RESTRICT`. Cross-record integrity trigger. Step 24.1 columns (`moderator_removed_at`, `moderator_removal_action_id`) preserved; triggers reference `case_id`.

### `reactions`
V1 model: challenge-level emoji reactions. In V3: investigation-scoped.

**Migration pattern (not a simple column rename):**
1. `ALTER TABLE reactions ADD COLUMN investigation_id uuid` (nullable)
2. Backfill: for each existing reactions row, find the matching investigation via `case_id → investigations(case_id)`. Since V1 challenges each have exactly one group, and Phase 4 creates exactly one investigation per challenge, the join is unambiguous: `UPDATE reactions r SET investigation_id = (SELECT i.investigation_id FROM investigations i WHERE i.case_id = r.challenge_id)`
3. Handle any NULLs after backfill (warn and reject — no valid investigation means data inconsistency)
4. `ALTER TABLE reactions ALTER COLUMN investigation_id SET NOT NULL`
5. `DROP CONSTRAINT reactions_challenge_id_fk` (the FK on challenge_id)
6. `ALTER TABLE reactions DROP COLUMN challenge_id`
7. `ALTER TABLE reactions ADD CONSTRAINT reactions_investigation_fk FOREIGN KEY (investigation_id) REFERENCES investigations ON DELETE RESTRICT`
8. `DROP INDEX IF EXISTS ... (challenge_id, player_id, emoji)` → `CREATE UNIQUE INDEX (investigation_id, player_id, emoji)`

---

## 11. `public.clues` and `public.challenge_answer_aliases`

`challenge_id → case_id`. All V1 structure, constraints, triggers preserved. Step 24.1 columns (`moderator_removed_at`, `moderator_removal_action_id`) on clues preserved.

---

## 12. `private.upload_sessions`

`challenge_id → case_id`. FK updated to `REFERENCES public.cases(id)`. Index renamed `upload_sessions_one_active_per_case`. Storage paths: `challenges/ → cases/` (UPDATE existing rows).

---

## 13. Media Moderation — Using Approved Step 24.1 Contract

### Approved functions (modified in V3, not replaced)

`approve_case_media()` and `reject_case_media()` do NOT exist. The approved Step 24.1 functions are extended:

**`approve_photo(p_media_object_id, p_moderator_id, p_reason)` — V3 extension:**
After the approved steps (validate moderator → lock media → verify `pending_review` → insert `moderation_actions` → set media to `ready`), add atomically:
```sql
-- V3 addition (within same transaction, media row already locked):
UPDATE public.cases
SET state = 'ready'
WHERE media_object_id = p_media_object_id
  AND state = 'draft';
-- No-op if no draft case references this media (media approved without a waiting case).
```

**`reject_photo(p_media_object_id, p_moderator_id, p_reason)` — V3 extension:**
After the approved steps (validate → lock → verify `pending_review` → read SHA-256 → insert `moderation_actions` → set media to `rejected`), add atomically:
```sql
-- V3 addition (media row locked, media now 'rejected'):
UPDATE public.cases
SET media_object_id = NULL
WHERE media_object_id = p_media_object_id
  AND state = 'draft';
-- Case stays 'draft'; poster may initiate a new upload session.
```

Media cleanup for `rejected` media: the existing Step 24.1 `claim_moderation_media_cleanup()` already handles `status IN ('rejected','removed')` with pending-report protection. **Only the display/re-encoded file is returned by this function.** The original upload path is cleaned through the V2 `get_complete_sessions_pending_expiry_cleanup()` path, preserving the replay-safety gate.

**`claim_moderation_media_cleanup(int)` — V3 update:**
The function body contains:
```sql
AND EXISTS (
  SELECT 1 FROM public.challenges c
  WHERE c.id = cr.target_id AND c.media_object_id = m.id
)
```
V3 changes `public.challenges → public.cases`. CREATE OR REPLACE.

**`get_pending_review_media(p_media_object_id)` — V3 update:**
Returns `challenge_id`. V3: return `case_id`. CREATE OR REPLACE.

**`get_reported_media(p_report_id)` — V3 update:**
Returns `challenge_id`. V3: return `case_id`. CREATE OR REPLACE.

No new moderation functions are introduced. `get_cleanable_media()` and `mark_cleanable_media_cleaned()` are NOT created.

---

## 14. V2 Function Impact — Exact Inventory

### Functions requiring body changes

| Function | Reason | Method |
|---|---|---|
| `reserve_upload_session(p_challenge_id, ...)` | Param; `public.challenges` SELECT+UPDATE; storage path `challenges/` | DROP + recreate as `(p_case_id, ...)`; restore grants + owner |
| `finalize_upload_session(uuid, text)` | `v_session.challenge_id`; `public.challenges AS ch`; `UPDATE challenges` | CREATE OR REPLACE |
| `reveal_challenge_service_wrapper(p_challenge_id uuid)` | Function name; param; calls `private.reveal_challenge_service` | DROP + recreate as `reveal_case_service_wrapper(p_case_id uuid)`; restore grants + owner |
| `prepare_account_deletion_wrapper(p_user_id uuid)` | V3 additions (see §15); no body changes for challenge/case rename itself | CREATE OR REPLACE |

### Functions with no body changes
`activate_upload_session`, `resolve_upload_session`, `advance_upload_session_processing`, `check_upload_session_lease`, `advance_upload_session_sanitized`, `fail_upload_session`, `quiesce_upload_sessions_for_deletion`, `get_upload_capability_expiry`, `get_all_upload_session_paths_for_deletion`, `claim_cleanup_sessions`, `mark_session_cleaned`, `mark_original_path_post_expiry_cleaned`, `get_complete_sessions_pending_expiry_cleanup`, `get_superseded_media_to_clean`, `mark_superseded_media_cleaned`, `get_media_storage_key`, `get_deletion_storage_keys`, `record_deletion_failure_wrapper`, `mark_auth_deleted_wrapper`, `mark_storage_cleaned_wrapper`, `claim_deletion_recovery_records`, `complete_deletion_recovery`, `fail_deletion_recovery`

### V2 trigger functions
Both DROP + recreate on `public.cases`:
- `private.check_activation_no_active_upload()` → `private.check_launch_no_active_upload()`: fires on `'draft' → 'launched'`; checks `case_id = NEW.id`
- `private.check_activation_media_ready()` → `private.check_launch_media_ready()`: fires on `'ready' → 'launched'`

---

## 15. V1 + Step 24.1 Object Inventory Requiring Changes

All objects in this section must be migrated in V3. Objects not listed here are unaffected.

### Functions — V1 source

| Function | V3 action |
|---|---|
| `private.is_challenge_revealed(uuid)` | Rename → `private.is_case_revealed(uuid)`; update body to reference `cases`; update all callers |
| `private.reveal_challenge_service(uuid)` | Rename → `private.reveal_case_service(uuid)`; rebuild for per-investigation `score_runs`; skip cancelled/tombstoned investigations |
| `private.prepare_account_deletion(uuid)` | Full rebuild — see §16 |
| `private.mark_auth_deleted(uuid)` | CREATE OR REPLACE; audit reference to `challenges` if present |
| `private.get_storage_keys_for_deletion(uuid)` | CREATE OR REPLACE; `upload_sessions.case_id` column ref |
| `public.activate_challenge(...)` | Renamed → V3 service function concept absorbed by `launch_case()`; original `activate_challenge` DROPPED |
| `public.post_challenge(...)` | Dropped; replaced by `launch_case()` |
| `public.cancel_challenge(uuid)` | Renamed → `cancel_case(uuid)`; update references |
| `public.apply_correction(...)` | References `challenge_id`; CREATE OR REPLACE; update to `case_id` and add investigation-scoped score_run creation |

### Functions — Step 24.1 source

| Function | V3 action |
|---|---|
| `private.can_view_challenge(uuid)` | Rename → `private.can_view_case(uuid)`; update body; update all callers (RLS policies, report_content) |
| `private.can_viewer_access_challenge(uuid, uuid)` | Rename → `private.can_viewer_access_case(uuid, uuid)`; update body; update all callers |
| `private.has_block_with_poster(uuid)` | References `challenges`; CREATE OR REPLACE; update to `cases` |
| `public.approve_photo(uuid, uuid, text)` | CREATE OR REPLACE; add V3 case-state side-effect (§13) |
| `public.reject_photo(uuid, uuid, text)` | CREATE OR REPLACE; add V3 case-state side-effect (§13) |
| `public.claim_moderation_media_cleanup(int)` | CREATE OR REPLACE; `challenges → cases` in pending-report JOIN |
| `public.get_pending_review_media(uuid)` | CREATE OR REPLACE; `challenge_id → case_id` in return |
| `public.get_reported_media(uuid)` | CREATE OR REPLACE; `challenge_id → case_id` in return |
| `public.report_content(text, uuid, text, text)` | CREATE OR REPLACE; `challenges → cases` for target-row locking |
| `public.remove_content(text, uuid, uuid, uuid, text)` | CREATE OR REPLACE; `challenges → cases` |
| `public.remove_media(uuid, uuid, uuid, text)` | CREATE OR REPLACE; `challenges → cases` |

### Triggers requiring changes

| Trigger / Function | V3 action |
|---|---|
| `challenge_insert_defaults` trigger on `challenges` | Recreate as `case_insert_defaults` on `cases`; update function body |
| `challenge_protect_fields` trigger on `challenges` | Recreate as `case_protect_fields` on `cases`; extend state transition table; disable temporarily in Phase 13 |
| `private.force_removal_fields_null()` (Step 24.1) on `challenges` | Recreate trigger on `cases`; no function body change |
| `private.restrict_moderation_field_updates()` (Step 24.1) on `challenges` | Recreate trigger on `cases` |
| `public.restrict_comment_updates()` (Step 24.1) on `comments` | CREATE OR REPLACE; `challenge_id → case_id` in body |
| `private.check_text_content_trigger()` | Verify: if attached to any challenges column, recreate on cases |
| V2 activation triggers | See §14 |

### Indexes requiring changes

| V1/V2 Index | V3 replacement |
|---|---|
| `one_active_challenge_per_poster` ON challenges | `one_active_case_per_poster` ON cases WHERE state IN ('draft','ready','launched','locked') |
| `idx_challenges_group_id` | Dropped in Phase 14 when `group_id` is dropped |
| `idx_challenges_state` | Renamed `idx_cases_state` ON cases (state) |
| `idx_guess_attempts_challenge` ON (challenge_id, race, ...) | Recreated ON (case_id, race, receipt_sequence) |
| `idx_guess_attempts_player` ON (player_id, challenge_id) | Recreated ON (player_id, case_id) |
| `idx_score_events_challenge` ON (challenge_id) | Recreated ON (case_id) |
| `idx_eligible_challenge` ON eligible_participants | Dropped (table replaced) |
| `idx_exclusion_challenge` ON (challenge_id) | Recreated ON (investigation_id) |
| `idx_clues_challenge` ON (challenge_id) | Recreated ON (case_id) |
| `idx_comments_challenge` ON (challenge_id, posted_at) | Recreated ON (case_id, posted_at) |
| `idx_reactions_challenge` ON (challenge_id) | Recreated ON (investigation_id) |
| `idx_aliases_challenge` ON (challenge_id, field) | Recreated ON (case_id, field) WHERE is_active |
| `idx_aliases_active_unique` ON (challenge_id, field, normalized_value) | Recreated ON (case_id, field, normalized_value) WHERE is_active |
| `idx_correction_challenge` ON (challenge_id) | Recreated ON (case_id) |
| `one_qualifying_per_player_race` ON guess_judgments | Updated predicate (no column change) |
| `upload_sessions_one_active_per_challenge` | Renamed `upload_sessions_one_active_per_case`; column `case_id` |

### RLS Policies requiring changes

All policies on the following tables must be dropped and recreated:
`challenges`/`cases`, `challenge_secrets`/`case_secrets`, `guess_attempts`, `eligible_participants`/`investigation_members`, `exclusion_events`, `clues`, `comments`, `reactions`, `score_runs`, `guess_judgments`, `score_events`, `correction_events`, `challenge_answer_aliases`.

New active-account requirement added to every policy: `AND EXISTS (SELECT 1 FROM public.profiles WHERE id = private.auth_uid() AND is_active = true)`.

### Grants requiring update

| Grant | V3 change |
|---|---|
| `GRANT SELECT ON public.challenges TO forkensics_rls_helper` | → `GRANT SELECT ON public.cases TO forkensics_rls_helper` |
| `GRANT SELECT ON public.eligible_participants TO forkensics_rls_helper` | → `GRANT SELECT ON public.investigation_members TO forkensics_rls_helper` |
| `GRANT UPDATE (moderator_removed_at, moderator_removal_action_id, state, cancellation_reason) ON public.challenges TO forkensics_executor` | → Same columns on `public.cases` |

---

## 16. Account Deletion — `private.prepare_account_deletion()` Full Rebuild

The existing function references `public.challenges`, `eligible_participants`, `active` state, and the old exclusion structure. It is fully rebuilt. The wrapper (`prepare_account_deletion_wrapper`) is unchanged; it calls the private function as before.

`quiesce_upload_sessions_for_deletion()` is called separately by the deletion orchestrator before this wrapper. Quiescence is not part of `prepare_account_deletion`.

**Rebuilt `private.prepare_account_deletion(p_profile_id uuid)` — step order:**

```
Step 1 — Existing V1 steps (unchanged):
  Lock deletion_log row FOR UPDATE
  Set profile to inactive (profiles.is_active = false, avatar_color = 'gray', etc.)
  Archive profile to private.profile_archive
  Set avatar_media_object_id = NULL on profiles
  Record db_prepared_at on deletion_log; set status = 'database_prepared'

Step 2 — V3 NEW: Collect pending media for draft/ready cases
  -- Must run BEFORE cancelling cases so the WHERE clause still finds them
  SELECT media_object_id
  INTO v_media_ids[]
  FROM public.cases
  WHERE poster_id = p_profile_id
    AND state IN ('draft', 'ready')
    AND media_object_id IS NOT NULL

Step 3 — V3 NEW: Cancel draft/ready cases
  UPDATE public.cases
  SET state = 'cancelled',
      cancelled_at = clock_timestamp(),
      cancellation_reason = 'account_deleted',
      media_object_id = NULL
  WHERE poster_id = p_profile_id
    AND state IN ('draft', 'ready')

Step 4 — Existing V1 steps (updated for V3):
  Set all media_objects owned by this profile to status = 'deleted'
  (includes the pending_review media collected in Step 2 — consistent
  with existing deletion cleanup path; does not use moderation cleanup)

Step 5 — V3 NEW: Anonymize ALL investigation_members rows for this player
  -- Includes prior exclusions ('excluded') and cancelled/tombstoned investigations
  UPDATE public.investigation_members
  SET snapshot_display_name           = '[Deleted]',
      snapshot_avatar_media_object_id = NULL
      -- eligibility_status NOT changed here for already-excluded rows
  WHERE player_id = p_profile_id

Step 6 — V3 NEW: For ACTIVE investigations where player was 'eligible' — exclude and record
  FOR each row WHERE player_id = p_profile_id
    AND eligibility_status = 'eligible'
    AND investigation.status = 'active':

    UPDATE investigation_members
    SET eligibility_status = 'account_deleted'
    WHERE investigation_id = <id> AND player_id = p_profile_id

    INSERT INTO exclusion_events
      (investigation_id, case_id, player_id, reason, excluded_by, excluded_at)
    VALUES (<id>, <case_id>, p_profile_id, 'account_deleted', NULL, clock_timestamp())
    ON CONFLICT DO NOTHING  -- idempotent
```

`mark_auth_deleted_wrapper()` continues to call `private.mark_auth_deleted(p_user_id)` only — no investigation logic.

---

## 17. `launch_case()` — Full Contract

```
launch_case(
  p_actor_id       uuid,
  p_case_id        uuid,
  p_group_ids      uuid[],
  p_duration_seconds integer
)
RETURNS TABLE (investigation_id uuid, group_id uuid)
SECURITY DEFINER, SET search_path = ''
```

**Validations (in order):**

```
v_now := clock_timestamp();   -- captured once; used for posted_at and deadline_at

1. Duplicate values in p_group_ids → FK_INVALID_INPUT
2. array_length(p_group_ids, 1) not in 1–10 → FK_INVALID_INPUT
3. p_duration_seconds not in 3600–86400 or not multiple of 3600 → FK_INVALID_INPUT
4. Actor profile: is_active = true, onboarding_complete = true, is_suspended = false;
   not deletion-pending (deletion_log.status IN ('database_prepared','auth_deleted'))
   → FK_FORBIDDEN
5. Lock case FOR UPDATE:
   SELECT id, poster_id, state, media_object_id FROM cases WHERE id = p_case_id FOR UPDATE
   Case exists and poster_id = p_actor_id → FK_NOT_FOUND if missing or wrong poster
6. Case state = 'ready' → FK_WRONG_STATE
7. case_secrets row exists; all four canonical fields NOT NULL → FK_WRONG_STATE
8. cases.media_object_id IS NOT NULL AND media_objects.status = 'ready' → FK_WRONG_STATE
9. No active upload_sessions (status IN ('pending','processing','sanitized'))
   for this case_id → FK_WRONG_STATE
10. For each group_id in p_group_ids:
    - Group exists, archived_at IS NULL → FK_NOT_FOUND
    - Actor is a member (group_members) → FK_NOT_FOUND
```

**Writes (atomic):**

```
UPDATE cases SET state = 'launched', posted_at = v_now,
  deadline_at = v_now + (p_duration_seconds || ' seconds')::interval,
  duration_seconds = p_duration_seconds
WHERE id = p_case_id;

For each group_id in p_group_ids:
  INSERT INTO investigations (case_id, group_id)
  VALUES (p_case_id, group_id)
  ON CONFLICT (case_id, group_id) DO NOTHING
  RETURNING investigation_id → v_inv_id

  -- Snapshot eligible members (member must be active, onboarded, not suspended,
  -- not in a block pair with the poster)
  INSERT INTO investigation_members (
    investigation_id, player_id,
    snapshot_display_name, snapshot_avatar_color, snapshot_avatar_media_object_id
  )
  SELECT v_inv_id, gm.player_id,
         p.display_name, p.avatar_color, p.avatar_media_object_id
  FROM group_members gm
  JOIN profiles p ON p.id = gm.player_id
  WHERE gm.group_id = group_id
    AND gm.player_id != p_actor_id   -- exclude poster
    AND p.is_active = true
    AND p.onboarding_complete = true
    AND p.is_suspended = false
    AND NOT EXISTS (
      SELECT 1 FROM user_blocks ub
      WHERE (ub.blocker_id = p_actor_id AND ub.blocked_id = gm.player_id)
         OR (ub.blocker_id = gm.player_id AND ub.blocked_id = p_actor_id)
    )
  ON CONFLICT DO NOTHING;

  -- Require at least one eligible detective
  IF (SELECT count(*) FROM investigation_members
      WHERE investigation_id = v_inv_id) < 1 THEN
    RAISE EXCEPTION 'FK_NO_ELIGIBLE_DETECTIVES: investigation for group % has no eligible members', group_id;
  END IF;
```

Idempotency: case already `launched` with matching investigations → return existing rows, no error. Case `launched` with different group set → `FK_WRONG_STATE`.

---

## 18. RLS — Poster Guess Visibility (V1 Behavior)

Poster sees individual `guess_attempts` for their case during `launched`, `locked`, and `revealed`:

```sql
-- Poster visibility (PERMISSIVE policy on guess_attempts)
CREATE POLICY guess_poster_view ON public.guess_attempts
  AS PERMISSIVE FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.cases c
      WHERE c.id = guess_attempts.case_id
        AND c.poster_id = private.auth_uid()
        AND c.state IN ('launched', 'locked', 'revealed')
    )
    AND EXISTS (
      SELECT 1 FROM public.profiles p
      WHERE p.id = private.auth_uid() AND p.is_active = true
    )
  );
```

Co-investigator visibility (after reveal only): viewer and author share at least one `investigation_members` row for the case, viewer `eligibility_status = 'eligible'`, case `revealed`.

Own-guess visibility: always (author `player_id = private.auth_uid()`, case not `cancelled`).

---

## 19. Scoring — Active Investigations Only

`reveal_case(p_case_id uuid)` and `apply_correction(...)` create `score_runs` only for investigations where `investigations.status = 'active'`. Cancelled/tombstoned investigations receive no new `score_runs`.

---

## 20. Migration Plan — Dependency-Ordered

`V3__case_investigation_schema.sql`. One `BEGIN`/`COMMIT`.

```
Phase 1 — Rename challenges → cases
  1a. ALTER TABLE public.challenges RENAME TO cases
  1b. Extend state CHECK: add 'ready','launched','retired' (keep 'active' through Phase 13)
  1c. Verify rules_version_id column DEFAULT = 'a0000000-0000-0000-0000-000000000001'
  1d. Verify created_at DEFAULT = clock_timestamp()
  1e. Verify media_object_id FK ON DELETE RESTRICT

Phase 2 — challenge_secrets → case_secrets
  2a. RENAME TABLE; RENAME COLUMN challenge_id → case_id
  2b. Recreate triggers, RLS policies, grants

Phase 3 — Create new tables
  3a. CREATE TABLE investigations
  3b. CREATE TABLE investigation_members

Phase 4 — Migrate eligible_participants → investigation_members
  4a. INSERT investigations (one per existing cases row, using cases.group_id)
  4b. INSERT investigation_members from eligible_participants
      (snapshot_display_name from profiles.display_name at migration time)
  4c. DROP TABLE public.eligible_participants (after verifying all rows migrated)

Phase 5 — Rename challenge_id on dependent tables
  5a. guess_attempts: RENAME → case_id; ADD idempotency_key (nullable→backfill→NOT NULL);
      duplicate guard; ADD UNIQUE INDEX (case_id, player_id, race)
  5b. exclusion_events: RENAME → case_id; ADD investigation_id (nullable→backfill→NOT NULL);
      DROP UNIQUE (challenge_id, player_id); ADD UNIQUE (investigation_id, player_id);
      ADD cross-record integrity trigger
  5c. clues: RENAME → case_id
  5d. comments: RENAME → case_id; ADD investigation_id (nullable→backfill→NOT NULL);
      ADD cross-record integrity trigger
  5e. challenge_answer_aliases: RENAME → case_id
  5f. correction_events: RENAME → case_id; DROP resulting_score_run_id column
  5g. score_runs: RENAME → case_id; ADD investigation_id (nullable→backfill→NOT NULL);
      DROP UNIQUE (challenge_id, revision_number);
      ADD UNIQUE (investigation_id, revision_number);
      ADD cross-record integrity trigger
  5h. guess_judgments: RENAME → case_id; ADD investigation_id (nullable→backfill→NOT NULL)
  5i. score_events: RENAME → case_id; ADD investigation_id (nullable→backfill→NOT NULL)
  5j. reactions: ADD investigation_id (nullable); backfill via investigations.case_id mapping;
      NOT NULL; DROP challenge_id FK; DROP challenge_id column; ADD investigation_id FK;
      DROP old UNIQUE; CREATE UNIQUE (investigation_id, player_id, emoji)

Phase 6 — current_score_events VIEW
  6a. DROP VIEW public.current_score_events
  6b. CREATE VIEW WITH (security_invoker = true) — investigation-scoped
  6c. GRANT SELECT TO authenticated

Phase 7 — Upload sessions
  7a. RENAME COLUMN challenge_id → case_id; update FK to cases
  7b. DROP INDEX upload_sessions_one_active_per_challenge
  7c. CREATE UNIQUE INDEX upload_sessions_one_active_per_case
  7d. UPDATE storage paths (challenges/ → cases/)

Phase 8 — V1 function rebuilds (private)
  private.prepare_account_deletion (full rebuild per §16)
  private.mark_auth_deleted (CREATE OR REPLACE)
  private.get_storage_keys_for_deletion (CREATE OR REPLACE)
  private.is_challenge_revealed → private.is_case_revealed (DROP + recreate)
  private.reveal_challenge_service → private.reveal_case_service (DROP + recreate)
  private.can_view_challenge → private.can_view_case (DROP + recreate; update all callers)
  private.can_viewer_access_challenge → private.can_viewer_access_case (DROP + recreate)
  private.has_block_with_poster (CREATE OR REPLACE; challenges → cases)

Phase 9 — V1 function rebuilds (public)
  public.cancel_challenge → public.cancel_case (DROP + recreate)
  public.apply_correction (CREATE OR REPLACE; add investigation-scoped scoring)
  DROP public.activate_challenge, public.post_challenge (absorbed by launch_case)

Phase 10 — Step 24.1 function updates
  approve_photo (CREATE OR REPLACE; V3 extension)
  reject_photo (CREATE OR REPLACE; V3 extension)
  claim_moderation_media_cleanup (CREATE OR REPLACE; challenges → cases)
  get_pending_review_media (CREATE OR REPLACE; challenge_id → case_id)
  get_reported_media (CREATE OR REPLACE; challenge_id → case_id)
  report_content (CREATE OR REPLACE; challenges → cases)
  remove_content (CREATE OR REPLACE; challenges → cases)
  remove_media (CREATE OR REPLACE; challenges → cases)

Phase 11 — V2 function updates (see §14)

Phase 12 — V1 trigger rebuilds (see §15)
  Drop old triggers on challenges (now renamed to cases)
  Recreate all on cases with updated function references and state values
  Update restrict_comment_updates for case_id
  Verify check_text_content_trigger attachment

Phase 13 — Index rebuilds (see §15)
  DROP old challenge-named indexes
  CREATE new case/investigation-named replacements

Phase 14 — RLS policies (see §15)
  Drop and recreate all policies on all affected tables
  Add profiles.is_active requirement everywhere
  Apply poster visibility rule (§18)
  Apply active-account requirement
  Update forkensics_rls_helper and forkensics_executor grants

Phase 15 — State conversion: active → launched
  15a. DISABLE TRIGGER case_protect_fields ON public.cases
  15b. UPDATE public.cases SET state = 'launched' WHERE state = 'active'
  15c. ENABLE TRIGGER case_protect_fields ON public.cases
  15d. DROP CONSTRAINT cases_state_check (current, includes 'active')
       ADD CONSTRAINT cases_state_check (final, excludes 'active')

Phase 16 — Partial index update
  16a. DROP INDEX one_active_challenge_per_poster
  16b. CREATE UNIQUE INDEX one_active_case_per_poster ON cases (poster_id)
       WHERE state IN ('draft','ready','launched','locked')

Phase 17 — Remove group_id from cases
  17a. Audit: zero objects still reference cases.group_id (pg_depend check)
  17b. DROP CONSTRAINT cases_group_id_fk
  17c. DROP INDEX idx_challenges_group_id
  17d. ALTER TABLE cases DROP COLUMN group_id

Phase 18 — New service functions
  launch_case, submit_guess, lock_case, reveal_case

Phase 19 — Grants, ownership, completion marker
```

---

## 21. Acceptance Criteria (Summary — Key Items)

Full test groups mirror the list below. Each group is independent via a `make_scenario()` helper.

- Schema integrity: all renamed columns exist; no `challenge_id` in any of the listed tables; `cases.rules_version_id` has column DEFAULT; `created_at` uses `clock_timestamp()`; `media_object_id ON DELETE RESTRICT`; `one_active_case_per_poster` predicate correct
- `state = 'active'` is not a valid value post-migration; `CHECK` constraint rejects it
- `approve_photo()`: media `→ ready`; case `draft → ready` atomically
- `reject_photo()`: media `→ rejected`; `cases.media_object_id` cleared; case stays `draft`
- `claim_moderation_media_cleanup()`: returns rows for `rejected` and `removed`; original key not returned
- `launch_case()`: ALL validation guards (active/onboarded/not-suspended poster; archived group; blocked pairs excluded; ≥ 1 detective; `FOR UPDATE` on case; single timestamp)
- Poster guesses: visible during `launched`, `locked`, `revealed`; not before launch
- `reveal_case()`: only creates `score_runs` for `active` investigations
- Account deletion: Step 2 collects media before Step 3 cancels cases; ALL investigation_members rows anonymized; exclusion_events only for active+eligible investigations
- `investigation_members` snapshot: blocked pair excluded from snapshot; suspended member excluded
- `mark_auth_deleted_wrapper()`: no investigation changes (only state advance)
- `current_score_events` VIEW: `WITH (security_invoker = true)` syntax; investigation-scoped
- All 21 unchanged V2 functions pass existing test groups after migration

---

## 22. Out of Scope

Push notifications, feed queries, monthly leaderboard tables, admin UI, Edge Function implementations, `case_secrets → private` schema, Orders To Go (FEAT-001), retired-state archival, per-comment reactions.

---

*Ready for review by Bill, Claude, and Codex. No migration code written until all three parties approve.*
