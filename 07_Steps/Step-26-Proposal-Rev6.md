# Step 26 Proposal — Case / Investigation Schema
**Revision:** 6  
**Status:** DRAFT — awaiting approval from Bill, Claude, and Codex before any code is written  
**Prerequisite:** Step 25 merged (`v0.2.0-upload-sessions`); Step 24.1 (UGC Safety) merged and tagged before this migration runs  
**Supersedes:** Rev 5 (rejected — GPT review, 6 blockers)

---

## Changes From Rev 5

| Blocker | Fix |
|---|---|
| 1 | Added Step 24.1 as hard prerequisite. Phase 0 migration guard checks `private.moderators` and `public.content_reports` exist; RAISES EXCEPTION if not. Proposal now states both steps must be applied before V3. |
| 2 | Complete V1 object inventory sourced from actual file. Removed `public.post_challenge` (does not exist in V1). Added all missing functions: `public.lock_challenge`, `public.reveal_challenge`, `private.reveal_challenge_service`, `private.do_reveal_impl`, `private.mark_storage_cleaned`, `private.record_deletion_failure`, `public.soft_delete_comment`, `private.get_storage_keys_for_deletion`. Corrected trigger name `challenge_insert_defaults → challenge_create_fields` (function: `set_challenge_create_fields`). Added missing RLS helper renames: `private.is_challenge_poster`, `private.is_eligible_non_excluded`, `private.caller_has_guessed`. |
| 3 | `private.prepare_account_deletion()` fully rebuilt from V1 source. Step ordering corrected: (1) cancel cases, (2) exclude from active investigations, (3) transfer/archive owned groups, (4) archive profile identity, (5) anonymize profile, (6) tombstone media objects, (7) set `database_prepared`. `v_media_ids[]` removed — not needed; the Edge Function calls `get_storage_keys_for_deletion()` after `database_prepared`. `database_prepared` set only after all steps succeed. |
| 4 | DDL: duplicate inline `CHECK` removed from `state` column — only the named `CONSTRAINT cases_state_check` remains. FK constraint name corrected: PostgreSQL does NOT rename constraints on table rename, so after `ALTER TABLE challenges RENAME TO cases` the FK is still named `challenges_group_id_fkey`; Phase 17 references that name. Trigger/function inventory now uses names from actual V1 source throughout. |
| 5 | `launch_case()` idempotency moved to first check (before `state = 'ready'` validation): if already `launched`, compare group set and duration; return existing rows if identical; raise `FK_WRONG_STATE` if different. Deletion guard expanded: rejects poster with deletion_log `status IN ('pending','database_prepared','auth_deleted','failed')`. |
| 6 | Own-guess visibility: always, no state restriction. Bill approved 2026-08-08: "Let them see the guess. Less testing and there is no downside. It was their guess." No carve-out for cancelled cases. RLS policy simplified accordingly. |

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
| Poster sees guesses | During `launched`, `locked`, and `revealed` |
| Poster sees own guesses | Always — no state restriction. Bill approved 2026-08-08. |
| Step 24.1 prerequisite | Must be merged and tagged BEFORE V3 migration runs |

---

## 3. `public.cases` — Exact Column Set

All columns sourced from V1's `challenges`. Only marked differences.

```sql
CREATE TABLE public.cases (
  id                   uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  -- group_id: kept through Phase 13 for dependent object migration; DROPPED in Phase 17
  poster_id            uuid        NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  media_object_id      uuid        REFERENCES public.media_objects(id) ON DELETE RESTRICT,
                                   -- V1 is ON DELETE RESTRICT; preserved exactly
  state                text        NOT NULL DEFAULT 'draft',
                                   -- No inline CHECK here; the named constraint below is the only state gate
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
    -- Single named constraint; no duplicate inline CHECK on the column.
    -- 'active' is valid through Phase 14 only; final constraint excludes it.
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

**Index: `one_active_case_per_poster`** (replaces `one_active_challenge_per_poster`)
```sql
CREATE UNIQUE INDEX one_active_case_per_poster
  ON public.cases (poster_id)
  WHERE state IN ('draft','ready','launched','locked');
-- V1 had ('draft','active','locked'); 'active'→'launched', 'ready' is new; 'revealed' excluded.
```

The migration drops the V1 index and creates this replacement after Phase 15.

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

`snapshot_avatar_media_object_id ON DELETE SET NULL`: nulled if media object is deleted. Also cleared during account deletion.

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
2. Backfill: `UPDATE reactions r SET investigation_id = (SELECT i.investigation_id FROM investigations i WHERE i.case_id = r.challenge_id)` — unambiguous because Phase 4 creates exactly one investigation per challenge
3. Handle any NULLs after backfill (RAISE EXCEPTION — no valid investigation means data inconsistency)
4. `ALTER TABLE reactions ALTER COLUMN investigation_id SET NOT NULL`
5. `DROP CONSTRAINT reactions_challenge_id_fk`
6. `ALTER TABLE reactions DROP COLUMN challenge_id`
7. `ALTER TABLE reactions ADD CONSTRAINT reactions_investigation_fk FOREIGN KEY (investigation_id) REFERENCES investigations ON DELETE RESTRICT`
8. `DROP INDEX ... (challenge_id, player_id, emoji)` → `CREATE UNIQUE INDEX (investigation_id, player_id, emoji)`

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
| `prepare_account_deletion_wrapper(p_user_id uuid)` | V3 additions (see §16); no body changes for challenge/case rename itself | CREATE OR REPLACE |

### Functions with no body changes (verified from V2 source)
`activate_upload_session`, `resolve_upload_session`, `advance_upload_session_processing`, `check_upload_session_lease`, `advance_upload_session_sanitized`, `fail_upload_session`, `quiesce_upload_sessions_for_deletion`, `get_upload_capability_expiry`, `get_all_upload_session_paths_for_deletion`, `claim_cleanup_sessions`, `mark_session_cleaned`, `mark_original_path_post_expiry_cleaned`, `get_complete_sessions_pending_expiry_cleanup`, `get_superseded_media_to_clean`, `mark_superseded_media_cleaned`, `get_media_storage_key`, `get_deletion_storage_keys`, `record_deletion_failure_wrapper`, `mark_auth_deleted_wrapper`, `mark_storage_cleaned_wrapper`, `claim_deletion_recovery_records`, `complete_deletion_recovery`, `fail_deletion_recovery`

### V2 trigger functions
Both DROP + recreate on `public.cases`:
- `private.check_activation_no_active_upload()` → `private.check_launch_no_active_upload()`: fires on `'ready' → 'launched'`; checks `case_id = NEW.id`
- `private.check_activation_media_ready()` → `private.check_launch_media_ready()`: fires on `'ready' → 'launched'`

---

## 15. Complete V1 + Step 24.1 Object Inventory Requiring Changes

All objects sourced from actual V1 and Step 24.1 files. Objects not listed are unaffected.

### RLS Helper Functions (owned by `forkensics_rls_helper`)

| Function | V3 action |
|---|---|
| `private.auth_uid()` | No change |
| `private.normalize_answer(text)` | No change |
| `private.is_group_member(uuid)` | No change |
| `private.is_group_member_with(uuid)` | No change |
| `private.is_challenge_group_member(uuid)` | DROP + recreate as `private.is_case_investigation_member(uuid)`; body: `cases` JOIN `investigations` JOIN `investigation_members`; update all callers |
| `private.is_challenge_poster(uuid)` | DROP + recreate as `private.is_case_poster(uuid)`; body references `cases`; update all callers |
| `private.is_challenge_revealed(uuid)` | DROP + recreate as `private.is_case_revealed(uuid)`; body references `cases.state = 'revealed'`; update all callers |
| `private.is_eligible_non_excluded(uuid)` | DROP + recreate for `investigation_members` model; replaces `eligible_participants` + `exclusion_events` join; callers: `exclusion_events` RLS INSERT, `guess_attempts` RLS INSERT |
| `private.caller_has_guessed(uuid)` | CREATE OR REPLACE; `guess_attempts.challenge_id → case_id`; update all callers |

### Operational Functions (owned by `forkensics_executor`) — V1 source

| Function | V3 action |
|---|---|
| `public.create_group(text)` | No change |
| `public.transfer_group_ownership(uuid, uuid)` | No change |
| `public.create_group_invite(uuid)` | No change |
| `public.redeem_group_invite(text)` | No change |
| `public.revoke_group_invite(uuid)` | No change |
| `public.activate_challenge(uuid)` | DROPPED — absorbed into `launch_case()` |
| `public.lock_challenge(uuid)` | DROP + recreate as `public.lock_case(uuid)`; checks `status = 'launched'` (was `'active'`); sets `status = 'locked'` |
| `public.reveal_challenge(uuid)` | DROP + recreate as `public.reveal_case(uuid)`; poster entry point; checks `state IN ('launched','locked')`; calls `private.do_reveal_impl_v3` |
| `public.cancel_challenge(uuid, text)` | DROP + recreate as `public.cancel_case(uuid, text)`; also cancels active investigations |
| `public.apply_correction(uuid, text, text, text, uuid, text)` | CREATE OR REPLACE; `challenge_id → case_id`; scores per investigation, skips cancelled/tombstoned |
| `public.soft_delete_comment(uuid)` | CREATE OR REPLACE; no column rename needed in body; trigger `comment_update_guard` rebuilds for `case_id` |
| `private.do_reveal_impl(uuid)` | DROP + recreate as `private.do_reveal_impl_v3(p_case_id uuid, p_investigation_id uuid)`; scoring scoped to investigation; reads `investigation_members` not `eligible_participants`; caller passes investigation_id |
| `private.reveal_challenge_service(uuid)` | DROP + recreate as `private.reveal_case_service(uuid)`; iterates active investigations; calls `private.do_reveal_impl_v3` per investigation |
| `private.prepare_account_deletion(uuid)` | Full rebuild — see §16 |
| `private.get_storage_keys_for_deletion(uuid)` | CREATE OR REPLACE; no challenge_id reference in body; verify and update any upload_sessions join if present |
| `private.mark_auth_deleted(uuid)` | CREATE OR REPLACE; no challenge_id reference; verify clean |
| `private.mark_storage_cleaned(uuid)` | CREATE OR REPLACE; no challenge_id reference; verify clean |
| `private.record_deletion_failure(uuid, text)` | CREATE OR REPLACE; no challenge_id reference; verify clean |

### Functions — Step 24.1 source

| Function | V3 action |
|---|---|
| `private.can_view_challenge(uuid)` | DROP + recreate as `private.can_view_case(uuid)`; update body; update all callers |
| `private.can_viewer_access_challenge(uuid, uuid)` | DROP + recreate as `private.can_viewer_access_case(uuid, uuid)`; update body; update all callers |
| `private.has_block_with_poster(uuid)` | CREATE OR REPLACE; `challenges → cases` |
| `public.approve_photo(uuid, uuid, text)` | CREATE OR REPLACE; add V3 case-state side-effect (§13) |
| `public.reject_photo(uuid, uuid, text)` | CREATE OR REPLACE; add V3 case-state side-effect (§13) |
| `public.claim_moderation_media_cleanup(int)` | CREATE OR REPLACE; `challenges → cases` in pending-report JOIN |
| `public.get_pending_review_media(uuid)` | CREATE OR REPLACE; `challenge_id → case_id` in return |
| `public.get_reported_media(uuid)` | CREATE OR REPLACE; `challenge_id → case_id` in return |
| `public.report_content(text, uuid, text, text)` | CREATE OR REPLACE; `challenges → cases` for target-row locking |
| `public.remove_content(text, uuid, uuid, uuid, text)` | CREATE OR REPLACE; `challenges → cases` |
| `public.remove_media(uuid, uuid, uuid, text)` | CREATE OR REPLACE; `challenges → cases` |

### Triggers requiring changes

Trigger names and function names sourced from actual V1 file.

| Trigger name | Function name | Table | V3 action |
|---|---|---|---|
| `challenge_create_fields` | `public.set_challenge_create_fields()` | `challenges` | DROP trigger; DROP + recreate function as `public.set_case_create_fields()`; recreate as `case_create_fields` on `cases` |
| `challenge_protect_fields` | `public.protect_challenge_authority_fields()` | `challenges` | DROP trigger; recreate as `case_protect_fields` on `cases`; extend state transition table for V3 states; DISABLE during Phase 15 state conversion |
| `challenge_secrets_guard` | `public.guard_answer_edits()` | `challenge_secrets` | Recreate on `case_secrets`; function body references `case_id` |
| `challenge_secrets_timestamps` | `public.set_challenge_secret_timestamps()` | `challenge_secrets` | Recreate on `case_secrets`; rename function `public.set_case_secret_timestamps()` |
| `alias_guard_insert`, `alias_guard_update` | `public.guard_alias_edits()` | `challenge_answer_aliases` | CREATE OR REPLACE function; update body to reference `case_secrets.case_id`; recreate triggers on (same table name → renamed to `case_answer_aliases` if renamed, else kept) |
| `guess_receipt` | `public.set_guess_receipt_fields()` | `guess_attempts` | CREATE OR REPLACE; `challenges.state = 'active' → 'launched'`; `deadline_at` check unchanged |
| `guess_judgment_consistency` | `public.check_judgment_consistency()` | `guess_judgments` | CREATE OR REPLACE; `challenge_id → case_id`; add `investigation_id` check |
| `score_event_consistency` | `public.check_score_event_consistency()` | `score_events` | CREATE OR REPLACE; rebuild for `investigation_members` |
| `exclusion_enforce` | `public.enforce_exclusion_rules()` | `exclusion_events` | CREATE OR REPLACE; `challenges.state IN ('active','locked') → investigations.status IN ('active','locked')`; `eligible_participants → investigation_members` |
| `clues_timestamp`, `comments_timestamp`, `reactions_timestamp`, `exclusion_events_timestamp` | `public.set_append_only_timestamps()` | multiple | No change |
| `comment_update_guard` | `public.restrict_comment_updates()` | `comments` | CREATE OR REPLACE; `challenge_id → case_id`; Step 24.1 extends this trigger — preserve all Step 24.1 additions |
| (Step 24.1 triggers on `challenges`) | `private.force_removal_fields_null()` | `challenges` | Recreate trigger on `cases`; no function body change |
| (Step 24.1 triggers on `challenges`) | `private.restrict_moderation_field_updates()` | `challenges` | Recreate trigger on `cases` |
| `private.check_text_content_trigger()` | (Step 24.1) | (verify attachment) | If attached to any `challenges` column, recreate on `cases` |
| V2 activation triggers | See §14 | `cases` | DROP + recreate per §14 |

### Indexes requiring changes

| V1/V2 Index | V3 replacement |
|---|---|
| `one_active_challenge_per_poster` ON `challenges` | `one_active_case_per_poster` ON `cases` WHERE `state IN ('draft','ready','launched','locked')` |
| `idx_challenges_group_id` | Dropped in Phase 17 when `group_id` is dropped |
| `idx_challenges_state` | Renamed `idx_cases_state` ON `cases (state)` |
| `idx_guess_attempts_challenge` ON `(challenge_id, race, ...)` | Recreated ON `(case_id, race, receipt_sequence)` |
| `idx_guess_attempts_player` ON `(player_id, challenge_id)` | Recreated ON `(player_id, case_id)` |
| `idx_score_events_challenge` ON `(challenge_id)` | Recreated ON `(case_id)` |
| `idx_eligible_challenge` ON `eligible_participants` | Dropped (table replaced by `investigation_members`) |
| `idx_exclusion_challenge` ON `(challenge_id)` | Recreated ON `(investigation_id)` |
| `idx_clues_challenge` ON `(challenge_id)` | Recreated ON `(case_id)` |
| `idx_comments_challenge` ON `(challenge_id, posted_at)` | Recreated ON `(case_id, posted_at)` |
| `idx_reactions_challenge` ON `(challenge_id)` | Recreated ON `(investigation_id)` |
| `idx_aliases_challenge` ON `(challenge_id, field)` | Recreated ON `(case_id, field) WHERE is_active` |
| `idx_aliases_active_unique` ON `(challenge_id, field, normalized_value)` | Recreated ON `(case_id, field, normalized_value) WHERE is_active` |
| `idx_correction_challenge` ON `(challenge_id)` | Recreated ON `(case_id)` |
| `one_qualifying_per_player_race` ON `guess_judgments` | Updated predicate (no column change) |
| `upload_sessions_one_active_per_challenge` | Renamed `upload_sessions_one_active_per_case`; column `case_id` |

### RLS Policies requiring changes

All policies on the following tables must be dropped and recreated:
`challenges`/`cases`, `challenge_secrets`/`case_secrets`, `guess_attempts`, `eligible_participants`/`investigation_members`, `exclusion_events`, `clues`, `comments`, `reactions`, `score_runs`, `guess_judgments`, `score_events`, `correction_events`, `challenge_answer_aliases`/`case_answer_aliases`.

New active-account requirement added to every policy: `AND EXISTS (SELECT 1 FROM public.profiles WHERE id = private.auth_uid() AND is_active = true)`.

### Grants requiring update

| Grant | V3 change |
|---|---|
| `GRANT SELECT ON public.challenges TO forkensics_rls_helper` | → `GRANT SELECT ON public.cases TO forkensics_rls_helper` |
| `GRANT SELECT ON public.eligible_participants TO forkensics_rls_helper` | → `GRANT SELECT ON public.investigation_members TO forkensics_rls_helper` |
| `GRANT UPDATE (moderator_removed_at, moderator_removal_action_id, state, cancellation_reason) ON public.challenges TO forkensics_executor` | → Same columns on `public.cases` |

---

## 16. Account Deletion — `private.prepare_account_deletion()` Full Rebuild

The existing function references `public.challenges`, `eligible_participants`, and `active` state. It is fully rebuilt from V1's step ordering. The wrapper (`prepare_account_deletion_wrapper`) is unchanged.

`quiesce_upload_sessions_for_deletion()` is called separately by the deletion orchestrator before this wrapper. Quiescence is not part of `prepare_account_deletion`.

**Rebuilt `private.prepare_account_deletion(p_profile_id uuid)` — step order (sourced from V1):**

```
Forward-only guard:
  IF deletion_log.status IN ('database_prepared','auth_deleted','complete') THEN RETURN; END IF;
  -- Reset pending/failed to 'pending' via INSERT ... ON CONFLICT DO UPDATE

Step 1 — Cancel draft/ready cases where poster is this profile
  UPDATE public.cases
  SET state               = 'cancelled',
      cancelled_at        = clock_timestamp(),
      cancellation_reason = 'Account deleted'
  WHERE poster_id = p_profile_id
    AND state IN ('draft','ready');
  -- V3 adds 'ready'; V1 cancelled 'draft'|'active'

Step 2 — Exclude from active investigations where player was eligible
  FOR each investigation where:
    investigation_members.player_id = p_profile_id
    AND investigation_members.eligibility_status = 'eligible'
    AND investigations.status = 'active'
  DO:
    UPDATE investigation_members
      SET eligibility_status = 'account_deleted'
      WHERE investigation_id = v_inv.investigation_id AND player_id = p_profile_id;
    INSERT INTO exclusion_events (investigation_id, case_id, player_id, reason, excluded_by)
      VALUES (v_inv.investigation_id, v_inv.case_id, p_profile_id, 'account_deleted', NULL)
      ON CONFLICT (investigation_id, player_id) DO NOTHING;

Step 3 — Transfer or archive owned groups (V1 logic preserved exactly)
  FOR each group where gm.player_id = p_profile_id AND gm.role = 'owner' AND g.archived_at IS NULL:
    v_successor_id := SELECT gm2.player_id
      FROM group_members gm2 JOIN profiles p ON p.id = gm2.player_id
      WHERE gm2.group_id = v_group.group_id
        AND gm2.player_id != p_profile_id
        AND p.is_active = true AND p.onboarding_complete = true
      ORDER BY gm2.joined_at ASC LIMIT 1;

    IF v_successor_id IS NOT NULL THEN
      UPDATE group_members SET role = 'member'
        WHERE group_id = v_group.group_id AND player_id = p_profile_id;
      UPDATE group_members SET role = 'owner'
        WHERE group_id = v_group.group_id AND player_id = v_successor_id;
    ELSE
      UPDATE groups SET archived_at = clock_timestamp() WHERE id = v_group.group_id;
    END IF;

Step 4 — Archive profile identity
  INSERT INTO private.profile_archive (profile_id, original_display_name, original_avatar_color, original_avatar_media_object_id)
    SELECT id, display_name, avatar_color, avatar_media_object_id
    FROM public.profiles WHERE id = p_profile_id
    ON CONFLICT (profile_id) DO NOTHING;

Step 5 — Anonymize profile row
  UPDATE public.profiles
  SET display_name           = 'Former Player',
      avatar_color           = 'gray',
      avatar_media_object_id = NULL,
      is_active              = false
  WHERE id = p_profile_id;

Step 6 — Anonymize ALL investigation_members snapshot fields for this player
  -- Includes already-excluded and tombstoned investigations — wipe display identity
  UPDATE public.investigation_members
  SET snapshot_display_name           = '[Deleted]',
      snapshot_avatar_media_object_id = NULL
  WHERE player_id = p_profile_id;
  -- eligibility_status NOT changed here for already-excluded rows

Step 7 — Tombstone all media objects owned by this profile
  UPDATE public.media_objects
  SET status = 'deleted'
  WHERE uploader_id = p_profile_id;
  -- Edge Function calls get_storage_keys_for_deletion() after database_prepared to collect keys

Step 8 — Mark DB step complete (ONLY reached if all steps above succeeded)
  UPDATE private.deletion_log
  SET status = 'database_prepared', db_prepared_at = clock_timestamp()
  WHERE profile_id = p_profile_id;
```

No `v_media_ids[]` array. The Edge Function retrieves storage keys by calling `private.get_storage_keys_for_deletion(p_profile_id)` after `database_prepared` is set. This matches the V1 pattern exactly.

---

## 17. `launch_case()` — Full Contract

```
launch_case(
  p_actor_id         uuid,
  p_case_id          uuid,
  p_group_ids        uuid[],
  p_duration_seconds integer
)
RETURNS TABLE (investigation_id uuid, group_id uuid)
SECURITY DEFINER, SET search_path = ''
```

**Validations (in order — idempotency check FIRST):**

```
v_now := clock_timestamp();

0. Idempotency check (BEFORE state validation):
   SELECT id, state, deadline_at FROM cases WHERE id = p_case_id FOR UPDATE;
   IF v_case.state = 'launched' THEN
     existing_inv_groups := SELECT group_id FROM investigations WHERE case_id = p_case_id
                            ORDER BY group_id;
     IF existing_inv_groups = p_group_ids (sorted) AND v_case.deadline_at - v_case.posted_at = p_duration_seconds THEN
       RETURN QUERY SELECT investigation_id, group_id FROM investigations WHERE case_id = p_case_id;
       RETURN;
     ELSE
       RAISE EXCEPTION 'FK_WRONG_STATE: case already launched with different parameters';
     END IF;
   END IF;

1. Duplicate values in p_group_ids → RAISE 'FK_INVALID_INPUT'
2. array_length(p_group_ids, 1) not in 1–10 → RAISE 'FK_INVALID_INPUT'
3. p_duration_seconds not in 3600–86400 or not multiple of 3600 → RAISE 'FK_INVALID_INPUT'
4. Actor profile active guard:
   - profiles: is_active = true, onboarding_complete = true, is_suspended = false → RAISE 'FK_FORBIDDEN'
   - deletion_log: status IN ('pending','database_prepared','auth_deleted','failed') → RAISE 'FK_FORBIDDEN'
     (status = 'complete' is the only safe state; no deletion_log row at all = safe)
5. Case row (already locked in step 0):
   - Case not found OR poster_id != p_actor_id → RAISE 'FK_NOT_FOUND'
6. Case state != 'ready' → RAISE 'FK_WRONG_STATE'
7. case_secrets row exists; canonical_dish, canonical_restaurant, display_dish, display_restaurant all NOT NULL and non-empty → RAISE 'FK_WRONG_STATE'
8. cases.media_object_id IS NOT NULL AND media_objects.status = 'ready' → RAISE 'FK_WRONG_STATE'
9. No active upload_sessions (status IN ('pending','processing','sanitized')) for this case_id → RAISE 'FK_WRONG_STATE'
10. For each group_id in p_group_ids:
    - Group exists, archived_at IS NULL → RAISE 'FK_NOT_FOUND'
    - Actor is a member (group_members) → RAISE 'FK_NOT_FOUND'
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

  IF (SELECT count(*) FROM investigation_members WHERE investigation_id = v_inv_id) < 1 THEN
    RAISE EXCEPTION 'FK_NO_ELIGIBLE_DETECTIVES: investigation for group % has no eligible members', group_id;
  END IF;

RETURN QUERY SELECT investigation_id, group_id FROM investigations WHERE case_id = p_case_id;
```

---

## 18. RLS — Guess Visibility

### Poster visibility (during case)
Poster sees all `guess_attempts` for their case during `launched`, `locked`, and `revealed`:

```sql
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

### Own-guess visibility
**Always visible, no state restriction. Bill approved 2026-08-08: "Let them see the guess. Less testing and there is no downside. It was their guess."**

```sql
CREATE POLICY guess_own_view ON public.guess_attempts
  AS PERMISSIVE FOR SELECT
  USING (
    player_id = private.auth_uid()
    AND EXISTS (
      SELECT 1 FROM public.profiles p
      WHERE p.id = private.auth_uid() AND p.is_active = true
    )
  );
-- No case state restriction. Includes cancelled cases.
```

### Co-investigator visibility (after reveal only)
Viewer and author share at least one `investigation_members` row for the case; viewer `eligibility_status = 'eligible'`; case `state = 'revealed'`.

---

## 19. Scoring — Active Investigations Only

`reveal_case(p_case_id uuid)` and `apply_correction(...)` create `score_runs` only for investigations where `investigations.status = 'active'`. Cancelled/tombstoned investigations receive no new `score_runs`.

---

## 20. Migration Plan — Dependency-Ordered

`V3__case_investigation_schema.sql`. One `BEGIN`/`COMMIT`.

```
Phase 0 — Prerequisite guard
  DO $$ BEGIN
    IF NOT EXISTS (
      SELECT 1 FROM information_schema.tables
      WHERE table_schema = 'private' AND table_name = 'moderators'
    ) THEN
      RAISE EXCEPTION 'V3 prerequisite failed: Step 24.1 (UGC Safety) must be applied first. private.moderators not found.';
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM information_schema.tables
      WHERE table_schema = 'public' AND table_name = 'content_reports'
    ) THEN
      RAISE EXCEPTION 'V3 prerequisite failed: Step 24.1 (UGC Safety) must be applied first. public.content_reports not found.';
    END IF;
  END $$;

Phase 1 — Rename challenges → cases
  1a. ALTER TABLE public.challenges RENAME TO cases
  1b. Extend state CHECK: add 'ready','launched','retired' (keep 'active' through Phase 15)
      -- Phase 15 will do the final DROP + ADD to exclude 'active'
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

Phase 8 — RLS Helper function rebuilds (owned by forkensics_rls_helper)
  private.is_challenge_group_member → private.is_case_investigation_member (DROP + recreate)
  private.is_challenge_poster → private.is_case_poster (DROP + recreate)
  private.is_challenge_revealed → private.is_case_revealed (DROP + recreate)
  private.is_eligible_non_excluded (DROP + recreate; investigation_members model)
  private.caller_has_guessed (CREATE OR REPLACE; case_id)

Phase 9 — V1 operational function rebuilds (owned by forkensics_executor)
  private.prepare_account_deletion (full rebuild per §16)
  private.mark_auth_deleted (CREATE OR REPLACE; verify clean)
  private.mark_storage_cleaned (CREATE OR REPLACE; verify clean)
  private.record_deletion_failure (CREATE OR REPLACE; verify clean)
  private.get_storage_keys_for_deletion (CREATE OR REPLACE; verify upload_sessions ref)
  private.do_reveal_impl → private.do_reveal_impl_v3 (DROP + recreate; investigation-scoped)
  private.reveal_challenge_service → private.reveal_case_service (DROP + recreate)
  public.lock_challenge → public.lock_case (DROP + recreate; 'launched' state)
  public.reveal_challenge → public.reveal_case (DROP + recreate; calls do_reveal_impl_v3)
  public.cancel_challenge → public.cancel_case (DROP + recreate; also cancels investigations)
  public.apply_correction (CREATE OR REPLACE; case_id; investigation-scoped scoring)
  public.soft_delete_comment (CREATE OR REPLACE; verify trigger still fires)
  DROP public.activate_challenge (no V3 equivalent; absorbed into launch_case)

Phase 10 — Step 24.1 function updates
  approve_photo (CREATE OR REPLACE; V3 extension per §13)
  reject_photo (CREATE OR REPLACE; V3 extension per §13)
  claim_moderation_media_cleanup (CREATE OR REPLACE; challenges → cases)
  get_pending_review_media (CREATE OR REPLACE; challenge_id → case_id)
  get_reported_media (CREATE OR REPLACE; challenge_id → case_id)
  report_content (CREATE OR REPLACE; challenges → cases)
  remove_content (CREATE OR REPLACE; challenges → cases)
  remove_media (CREATE OR REPLACE; challenges → cases)
  private.can_view_challenge → private.can_view_case (DROP + recreate)
  private.can_viewer_access_challenge → private.can_viewer_access_case (DROP + recreate)
  private.has_block_with_poster (CREATE OR REPLACE; challenges → cases)

Phase 11 — V2 function updates (see §14)
  reserve_upload_session: DROP + recreate as (p_case_id, ...)
  finalize_upload_session: CREATE OR REPLACE
  reveal_challenge_service_wrapper → reveal_case_service_wrapper: DROP + recreate
  prepare_account_deletion_wrapper: CREATE OR REPLACE

Phase 12 — V1 + Step 24.1 trigger rebuilds (see §15)
  Drop all old challenge-named triggers
  Recreate all on cases/case_secrets with updated function references and state values
  -- Trigger names verified against actual V1 source:
  --   challenge_create_fields → case_create_fields (function: set_case_create_fields)
  --   challenge_protect_fields → case_protect_fields (function: protect_case_authority_fields)
  --   challenge_secrets_guard → case_secrets_guard (function: guard_answer_edits, updated)
  --   challenge_secrets_timestamps → case_secrets_timestamps (function: set_case_secret_timestamps)
  --   alias_guard_insert, alias_guard_update: function guard_alias_edits updated for case_id
  --   guess_receipt: function set_guess_receipt_fields updated: 'active' → 'launched'
  --   guess_judgment_consistency: function updated for case_id + investigation_id
  --   score_event_consistency: function rebuilt for investigation_members
  --   exclusion_enforce: function updated for investigations.status, investigation_members
  --   comment_update_guard: function restrict_comment_updates updated for case_id
  --   Step 24.1 triggers: force_removal_fields_null, restrict_moderation_field_updates recreated on cases
  --   V2 triggers: check_launch_no_active_upload, check_launch_media_ready recreated on cases

Phase 13 — Index rebuilds (see §15)
  DROP old challenge-named indexes
  CREATE new case/investigation-named replacements

Phase 14 — RLS policies (see §15 + §18)
  Drop and recreate all policies on all affected tables
  Apply profiles.is_active requirement everywhere
  Apply poster guess visibility rule (launched/locked/revealed)
  Apply own-guess always-visible rule (no state restriction)
  Apply co-investigator visibility rule (revealed only)
  Update forkensics_rls_helper and forkensics_executor grants

Phase 15 — State conversion: active → launched
  15a. DISABLE TRIGGER case_protect_fields ON public.cases
  15b. UPDATE public.cases SET state = 'launched' WHERE state = 'active'
  15c. ENABLE TRIGGER case_protect_fields ON public.cases
  15d. DROP CONSTRAINT cases_state_check
       ADD CONSTRAINT cases_state_check CHECK (state IN ('draft','ready','launched','locked','revealed','retired','cancelled'))
       -- This is the final constraint; 'active' is now excluded

Phase 16 — Partial index update
  16a. DROP INDEX one_active_challenge_per_poster
  16b. CREATE UNIQUE INDEX one_active_case_per_poster ON cases (poster_id)
       WHERE state IN ('draft','ready','launched','locked')

Phase 17 — Remove group_id from cases
  17a. Audit: zero objects still reference cases.group_id (pg_depend check)
  17b. DROP CONSTRAINT challenges_group_id_fkey
       -- IMPORTANT: PostgreSQL does NOT rename constraints on table rename.
       -- After 'ALTER TABLE challenges RENAME TO cases' the constraint retains its original name.
       -- The actual constraint name in catalog is 'challenges_group_id_fkey'.
  17c. DROP INDEX idx_challenges_group_id
  17d. ALTER TABLE cases DROP COLUMN group_id

Phase 18 — New service functions
  launch_case (per §17)
  submit_guess
  lock_case
  reveal_case

Phase 19 — Grants, ownership, completion marker
  GRANT SELECT ON public.cases TO forkensics_rls_helper
  GRANT SELECT ON public.investigation_members TO forkensics_rls_helper
  GRANT UPDATE (moderator_removed_at, moderator_removal_action_id, state, cancellation_reason)
    ON public.cases TO forkensics_executor
  GRANT INSERT, UPDATE, DELETE ON public.investigations TO forkensics_executor
  GRANT INSERT, UPDATE ON public.investigation_members TO forkensics_executor
  [All new function OWNER TO forkensics_executor assignments]
  REVOKE temporary build-time privileges (pattern from V1 §9B)
  INSERT INTO schema_migrations marker
```

---

## 21. Acceptance Criteria (Summary — Key Items)

Full test groups mirror the list below. Each group is independent via a `make_scenario()` helper.

- Schema integrity: all renamed columns exist; no `challenge_id` in any of the listed tables; `cases.rules_version_id` has column DEFAULT; `created_at` uses `clock_timestamp()`; `media_object_id ON DELETE RESTRICT`; `one_active_case_per_poster` predicate correct; no inline state CHECK on column (only named constraint)
- `state = 'active'` is not a valid value post-migration; CHECK constraint rejects it
- `approve_photo()`: media `→ ready`; case `draft → ready` atomically
- `reject_photo()`: media `→ rejected`; `cases.media_object_id` cleared; case stays `draft`
- `claim_moderation_media_cleanup()`: returns rows for `rejected` and `removed`; original key not returned
- `launch_case()` idempotency: if case already `launched` with same groups + duration → returns existing rows, no error; different params → `FK_WRONG_STATE`
- `launch_case()` deletion guard: poster with `deletion_log.status IN ('pending','database_prepared','auth_deleted','failed')` → rejected
- `launch_case()`: ALL other validation guards (active/onboarded/not-suspended poster; archived group; blocked pairs excluded; ≥ 1 detective; `FOR UPDATE` on case; single timestamp)
- Poster guesses: visible during `launched`, `locked`, `revealed`; not visible before launch
- Own-guess: visible in ALL states including `cancelled` — no restriction
- `reveal_case()`: only creates `score_runs` for `active` investigations
- Account deletion step ordering: group ownership transfer before profile anonymization; `database_prepared` set only after all 7 steps succeed; no `v_media_ids[]` variable
- `investigation_members` snapshot: blocked pair excluded; suspended member excluded
- `mark_auth_deleted_wrapper()`: no investigation changes (only deletion_log state advance)
- `current_score_events` VIEW: `WITH (security_invoker = true)` syntax; investigation-scoped
- All 21 unchanged V2 functions pass existing test groups after migration
- Phase 0 guard: migration raises exception if `private.moderators` or `public.content_reports` absent

---

## 22. Out of Scope

Push notifications, feed queries, monthly leaderboard tables, admin UI, Edge Function implementations, `case_secrets → private` schema, Orders To Go (FEAT-001), retired-state archival, per-comment reactions.

---

*Ready for review by Bill, Claude, and Codex. No migration code written until all three parties approve.*
