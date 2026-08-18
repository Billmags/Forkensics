# Step 26 Proposal — Case / Investigation Schema
**Revision:** 2  
**Status:** DRAFT — awaiting approval from Bill, Claude, and Codex before any code is written  
**Prerequisite:** Step 25 merged and tagged (`v0.2.0-upload-sessions`)  
**Supersedes:** Rev 1 (rejected — GPT review, 15 blockers)

---

## 1. Purpose

Separate the V1 `challenges` table into two distinct concepts:

- **Case** — the mystery itself: photo, answers, clues, location. Poster-owned. Group-agnostic.
- **Investigation** — a Table's engagement with a case: frozen participant snapshot, guesses, scoring, Table Talk.

One case → many investigations. Every approved V1 system is preserved and redistributed — nothing is replaced with a simplified substitute.

---

## 2. Decisions

| # | Decision | Notes |
|---|---|---|
| D-1 | One `guess_attempt` per player per case per race (`what` / `where`) | Two sequential races preserved; append-only audit trail preserved |
| D-2 | Guess fans out implicitly to all investigations at scoring time | No fan-out write; scoring joins `investigation_members` to `guess_attempts` on `case_id` |
| D-3 | All investigations from one case share one reveal deadline, computed from `duration_seconds` | DB computes `reveal_at = launched_at + duration_seconds * interval '1 second'`; client never supplies `reveal_at` directly |
| D-4 | Duration: min 1 hour, max 24 hours, default 2 hours, 1-hour increments; immutable after launch | OQ-1 resolved |
| D-5 | Rankings, Table Talk, scoring remain per-investigation | Social experience is fully isolated per Table |
| D-6 | Case state machine: `draft → ready → launched → locked → revealed → retired`; `cancelled` is a branch, not a sequential state | Scheduler failure between `locked` and `revealed` must not produce visible results |
| D-7 | `locked`: deadline passed, submissions closed. `revealed`: scoring committed. These are separate committed states. | A case cannot appear revealed merely because `reveal_at` is past |
| D-8 | `challenges` renamed to `cases` throughout; `challenge_id` → `case_id` everywhere | `group_id` removed from cases after all dependencies migrated |
| D-9 | `challenge_secrets` remains in `public` schema with RLS (matching V1); moving it to `private` is a separate security decision not in scope for Step 26 | GPT blocker §5; must not change security model silently |
| D-10 | `eligible_participants` → replaced by `investigation_members` (frozen snapshot per investigation) | Poster excluded; snapshot taken at launch; live `group_members` never substitutes |
| D-11 | `score_runs`, `guess_judgments`, `score_events`, `current_score_events` repointed to `investigation_id`; scoring model otherwise unchanged | Event-sourced scoring preserved; zero-score rows for non-guessing eligible players preserved |
| D-12 | `comments` and `reactions` keep their DB names; `investigation_id` column added; `challenge_id` → `case_id` | `deleted_at`, reaction uniqueness, moderation, RLS preserved |
| D-13 | `clues` are case-scoped (fairness: same clues across all investigations) | `challenge_id → case_id` |
| D-14 | `challenge_answer_aliases` → `case_answer_aliases` (or `challenge_id → case_id` rename); `correction_events` case-scoped; corrections recalculate all affected investigations atomically | Clues and corrections not out of scope |
| D-15 | Account deletion: anonymize retained profile; add `account_deleted` exclusion to active investigations; retain historical attempts and score events | Do not delete `guess_attempts` or `score_events` rows |
| D-16 | `launch_case()` rejects duplicate group IDs in request (not deduplicated silently) | Idempotent on same request against already-launched case |
| D-17 | Guess visibility: viewer and author must share at least one `investigation_members` row for that case | Cannot use case-level access alone |
| D-18 | Ten groups per launch is reasonable for V1 | Requires Bill's explicit approval before implementation |
| D-19 | No late joiners; `investigation_members` frozen at launch | OQ-4 resolved |
| D-20 | OQ-5: DB table stays `comments`; "Table Talk" is product copy only | Confirmed |

---

## 3. V1 Table Inventory — Migration Destination

Every V1 challenge-scoped table, function, trigger, policy, index, and view must have an explicit destination. This section is the contract for the V3 migration plan.

### 3.1 Tables

| V1 Table | V3 Destination | Key Change |
|---|---|---|
| `public.challenges` | `public.cases` | Rename; remove `group_id`; extend state machine; add `duration_seconds`, `locked_at`, `revealed_at` |
| `public.challenge_secrets` | `public.challenge_secrets` (renamed `case_secrets` or keep and alias) | `challenge_id → case_id`; stays in `public` with RLS — **not moved to private** |
| `public.guess_attempts` | `public.guess_attempts` | `challenge_id → case_id`; structure otherwise unchanged |
| `public.eligible_participants` | Replaced by `public.investigation_members` | investigation-scoped snapshot; see §5 |
| `public.exclusion_events` | `public.exclusion_events` | `challenge_id → case_id` |
| `public.clues` | `public.clues` | `challenge_id → case_id` |
| `public.comments` | `public.comments` | `challenge_id → case_id`; add `investigation_id` NOT NULL |
| `public.reactions` | `public.reactions` | Scope updated to investigation via comment FK |
| `public.challenge_answer_aliases` | `public.challenge_answer_aliases` | `challenge_id → case_id` |
| `public.correction_events` | `public.correction_events` | `challenge_id → case_id` |
| `public.score_runs` | `public.score_runs` | `challenge_id → case_id`; add `investigation_id` NOT NULL |
| `public.guess_judgments` | `public.guess_judgments` | `challenge_id → case_id`; add `investigation_id` NOT NULL |
| `public.score_events` | `public.score_events` | `challenge_id → case_id`; add `investigation_id` NOT NULL |
| `public.current_score_events` | `public.current_score_events` | `challenge_id → case_id`; add `investigation_id` NOT NULL |
| `private.upload_sessions` | `private.upload_sessions` | `challenge_id → case_id` |
| `private.media_storage_keys` | `private.media_storage_keys` | No change |
| `private.deletion_log` | `private.deletion_log` | No change |
| `private.deletion_recovery_claims` | `private.deletion_recovery_claims` | No change |

**New tables:**
- `public.investigations`
- `public.investigation_members`

### 3.2 Functions (V1 + V2)

All functions that reference `challenges`, `challenge_id`, `group_id` through the challenges join path, or challenge state must be inventoried and updated. See §9 for the complete V2 function impact list. V1 function updates follow the same pattern: `CREATE OR REPLACE` with updated table references and column names.

### 3.3 Triggers

| V1 Trigger | Destination |
|---|---|
| `handle_challenge_insert` | `handle_case_insert` (sets `poster_id = auth.uid()`) |
| `challenge_protect_fields` | `case_protect_fields` (updated field list) |
| `challenge_v2_no_active_upload_on_activate` | `case_v2_no_active_upload_on_launch` (fires on `draft/ready → launched`) |
| `challenge_v2_media_ready_on_activate` | `case_v2_media_ready_on_launch` (fires on `ready → launched`) |

### 3.4 RLS Policies

All policies on `challenges` are rewritten for `cases`. Policies on `comments`, `reactions`, `clues`, `guess_attempts`, scoring tables that join through `challenges.group_id` must be rewritten to join through `investigation_members`.

---

## 4. Schema: `public.cases`

```sql
CREATE TABLE public.cases (
  id                   uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  poster_id            uuid        NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  media_object_id      uuid        REFERENCES public.media_objects(id),
  rules_version_id     uuid        REFERENCES public.rules_versions(id),
  state                text        NOT NULL DEFAULT 'draft'
                                   CHECK (state IN ('draft','ready','launched','locked','revealed','retired','cancelled')),
  duration_seconds     int         CHECK (
                                     duration_seconds IS NULL OR (
                                       duration_seconds >= 3600        -- 1 hour minimum
                                       AND duration_seconds <= 86400   -- 24 hour maximum
                                       AND duration_seconds % 3600 = 0 -- 1-hour increments
                                     )
                                   ),
  reveal_at            timestamptz,  -- set by DB at launch: launched_at + duration_seconds
  public_city_display  text,
  story                text,
  caption              text,
  has_first_guess      boolean     NOT NULL DEFAULT false,
  posted_at            timestamptz,
  launched_at          timestamptz,
  deadline_at          timestamptz,  -- alias / human-readable synonym for reveal_at
  locked_at            timestamptz,
  revealed_at          timestamptz,
  cancelled_at         timestamptz,
  cancellation_reason  text,
  created_at           timestamptz NOT NULL DEFAULT now(),
  state_changed_at     timestamptz NOT NULL DEFAULT now()
);
```

**State transition rules (enforced by trigger `case_protect_fields`):**
- `draft → ready`: moderation approves media (see §10).
- `ready → launched`: `launch_case()` call; `duration_seconds` must be set; investigations created atomically.
- `launched → locked`: scheduler; `reveal_at` passed; submissions closed.
- `locked → revealed`: `reveal_case()` commits scoring; `revealed_at` set.
- `draft|ready → cancelled`: poster action; no investigations exist.
- `launched|locked → cancelled`: admin only; investigations tombstoned.
- `revealed → retired`: optional archival; out of scope for Step 26.
- `cancelled` and `retired` are terminal; no further transitions.

**`deadline_at`** is kept as a non-null synonym for `reveal_at` (set at same time) to preserve any V1 references. Both columns are updated together.

**`public_city_display`** remains on `cases` (public context, not a secret). GPT blocker §5: city must not be moved into secrets.

---

## 5. Schema: `public.investigations`

```sql
CREATE TABLE public.investigations (
  investigation_id  uuid  PRIMARY KEY DEFAULT gen_random_uuid(),
  case_id           uuid  NOT NULL REFERENCES public.cases(id) ON DELETE RESTRICT,
  group_id          uuid  NOT NULL REFERENCES public.groups(id) ON DELETE RESTRICT,
  status            text  NOT NULL DEFAULT 'active'
                          CHECK (status IN ('active','cancelled','tombstoned')),
  cancelled_at      timestamptz,
  cancellation_reason text,
  created_at        timestamptz NOT NULL DEFAULT now(),
  UNIQUE (case_id, group_id)
);
```

**Investigation display state (derived, not stored):**
- Case `launched`, `reveal_at` in future → investigation active / accepting guesses.
- Case `locked` → submissions closed; scores not yet visible.
- Case `revealed` → scores and answers visible.
- Case `cancelled` / investigation `cancelled` → closed.

**Investigation-specific closure** (§7 of GPT review): `status` field handles group dissolution, moderation tombstoning, and administrative cancellation independently of the case state.

**RLS:** Members of the group (via `investigation_members`) see the investigation.

---

## 6. Schema: `public.investigation_members`

Frozen participant snapshot taken at the moment `launch_case()` runs. Live `group_members` changes after launch do not affect this snapshot.

```sql
CREATE TABLE public.investigation_members (
  investigation_id    uuid  NOT NULL REFERENCES public.investigations(investigation_id) ON DELETE RESTRICT,
  player_id           uuid  NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  -- Snapshot fields (copied from profiles at launch time)
  display_name_snapshot text NOT NULL,
  avatar_url_snapshot   text,
  -- Eligibility
  eligibility_status  text  NOT NULL DEFAULT 'eligible'
                            CHECK (eligibility_status IN ('eligible','excluded','account_deleted')),
  added_at            timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (investigation_id, player_id)
);
```

**Rules:**
- Poster is excluded from all `investigation_members` rows.
- Only members of `group_id` at the time of launch are included.
- `eligibility_status = 'excluded'` covers `exclusion_events`-driven removals.
- `eligibility_status = 'account_deleted'` set when player's account deletion completes (preserves row for scoring history; display_name_snapshot replaced with anonymized value).
- "All guesses in" counts: eligible members who have submitted attempts for both `what` and `where` races, minus excluded and account_deleted members.

---

## 7. `guess_attempts` — Two-Race Model Preserved

No structural change to the `guess_attempts` table beyond `challenge_id → case_id`.

```
guess_attempts (
  id                uuid PK,
  case_id           uuid FK → cases,        -- was challenge_id
  player_id         uuid FK → profiles,
  race              text CHECK (race IN ('what','where')),
  answer_text       text NOT NULL,
  idempotency_key   uuid NOT NULL,
  client_submitted_at timestamptz,
  server_received_at  timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY (id)
  UNIQUE (case_id, player_id, race)          -- one attempt per player per case per race
)
```

**Fan-out is implicit:** At scoring time, `guess_judgments` are produced by joining `investigation_members` for an investigation to `guess_attempts` on `case_id + player_id`.

**Idempotency:** A retry with same `idempotency_key` and same `answer_text` returns the existing row. A retry with the same `idempotency_key` but different `answer_text` is rejected (conflict). A new submission after the unique constraint is satisfied is also rejected.

**Submission gate:** `submit_guess()` validates that `cases.state = 'launched'` and `cases.reveal_at > now()`. Submissions after `locked` are rejected.

---

## 8. Scoring System Preserved

`score_runs`, `guess_judgments`, `score_events`, `current_score_events` retain their structure and are repointed to `investigation_id`.

```sql
-- Illustrative column additions (not full table definitions)
ALTER TABLE public.score_runs      ADD COLUMN investigation_id uuid NOT NULL REFERENCES public.investigations;
ALTER TABLE public.guess_judgments ADD COLUMN investigation_id uuid NOT NULL REFERENCES public.investigations;
ALTER TABLE public.score_events    ADD COLUMN investigation_id uuid NOT NULL REFERENCES public.investigations;
ALTER TABLE public.current_score_events ADD COLUMN investigation_id uuid NOT NULL REFERENCES public.investigations;
```

**Behavioral rules (unchanged from V1):**
- Zero-point `score_events` are written for eligible players who did not guess. No player disappears from scoring history.
- Corrections trigger a new `score_run` for every investigation of the corrected case atomically.
- `current_score_events` holds the latest revision per `(investigation_id, player_id)`.
- Rankings are per-investigation.

---

## 9. V2 Upload Session Function Impact — Exact Inventory

| Function | Change Required | Nature |
|---|---|---|
| `reserve_upload_session` | `p_challenge_id → p_case_id`; `public.challenges → public.cases`; storage path `challenges/ → cases/`; state check `draft` unchanged | Parameter + table ref + path |
| `activate_upload_session` | Internal `challenge_id` column ref → `case_id` | Column ref |
| `resolve_upload_session` | `upload_sessions.challenge_id → case_id` in SELECT | Column ref |
| `advance_upload_session_processing` | `upload_sessions.challenge_id → case_id` | Column ref |
| `check_upload_session_lease` | No challenge/case reference; no change | None |
| `advance_upload_session_sanitized` | No challenge/case reference; no change | None |
| `finalize_upload_session` | `public.challenges → public.cases`; `challenge_id → case_id`; moderation gate: after finalize, a separate moderation call advances `media_objects.status = 'ready'` and `cases.state = 'ready'` atomically (see §10) | Table ref + new moderation hook |
| `fail_upload_session` | No challenge/case reference; no change | None |
| `quiesce_upload_sessions_for_deletion` | `upload_sessions.challenge_id → case_id` in JOIN/WHERE | Column ref |
| `get_upload_capability_expiry` | No challenge/case reference; no change | None |
| `get_all_upload_session_paths_for_deletion` | `upload_sessions.challenge_id → case_id` | Column ref |
| `claim_cleanup_sessions` | No challenge/case reference; no change | None |
| `mark_session_cleaned` | No challenge/case reference; no change | None |
| `mark_original_path_post_expiry_cleaned` | No challenge/case reference; no change | None |
| `get_complete_sessions_pending_expiry_cleanup` | No challenge/case reference; no change | None |
| `get_superseded_media_to_clean` | No challenge/case reference; no change | None |
| `mark_superseded_media_cleaned` | No challenge/case reference; no change | None |
| `get_media_storage_key` | No challenge/case reference; no change | None |
| `reveal_challenge_service_wrapper` | Rename to `reveal_case_service_wrapper`; `challenges → cases` | Rename + table ref |
| `prepare_account_deletion_wrapper` | Joins through `upload_sessions.case_id` | Column ref |
| `get_deletion_storage_keys` | `upload_sessions.case_id` | Column ref |
| `record_deletion_failure_wrapper` | No challenge/case reference; no change | None |
| `mark_auth_deleted_wrapper` | Must also set `investigation_members.eligibility_status = 'account_deleted'` for all active investigations | New behavior |
| `mark_storage_cleaned_wrapper` | No challenge/case reference; no change | None |
| `claim_deletion_recovery_records` | No challenge/case reference; no change | None |
| `complete_deletion_recovery` | No challenge/case reference; no change | None |
| `fail_deletion_recovery` | No challenge/case reference; no change | None |

**Summary:** 10 of 27 functions require changes; 17 are unaffected beyond the column rename in `upload_sessions`.

---

## 10. Media Moderation → Case `ready` Transition

`finalize_upload_session()` currently creates a `media_objects` row with `status = 'pending_review'`. The transition from `pending_review` to `ready` must now also advance `cases.state` from `draft` to `ready`.

New function: `approve_case_media(p_case_id uuid)` — service-role only, owned by `forkensics_executor`.

**Contract:**
- Validates: case in `draft` state; `media_object_id` is not NULL; `media_objects.status = 'pending_review'`.
- Atomically: sets `media_objects.status = 'ready'`; sets `cases.state = 'ready'`.
- Returns: void.
- Called by: moderation Edge Function or admin tool; never by client.

---

## 11. `launch_case()` — Revised Contract

```sql
CREATE OR REPLACE FUNCTION public.launch_case(
  p_actor_id       uuid,       -- poster identity; validated against cases.poster_id
  p_case_id        uuid,
  p_group_ids      uuid[],     -- must have 1–10 elements; no duplicates
  p_duration_seconds int       -- must satisfy duration constraint (§4)
) RETURNS TABLE (investigation_id uuid, group_id uuid)
```

**Validations (in order, all before any write):**
1. `p_group_ids` has no duplicate values → `FK_INVALID_INPUT` if duplicates found.
2. `p_group_ids` length between 1 and 10 → `FK_INVALID_INPUT` if violated.
3. `p_duration_seconds` satisfies constraint → `FK_INVALID_INPUT` if violated.
4. `p_actor_id` profile exists, `onboarding_complete = true`, not deletion-pending → `FK_NOT_FOUND` / `FK_FORBIDDEN`.
5. Case exists, `poster_id = p_actor_id` → `FK_NOT_FOUND`.
6. Case in `ready` state → `FK_WRONG_STATE`.
7. `case_secrets` row is complete (all required answer fields non-null) → `FK_WRONG_STATE`.
8. `media_objects.status = 'ready'` → `FK_WRONG_STATE`.
9. No active `upload_sessions` for this case (pending/processing/sanitized) → `FK_WRONG_STATE`.
10. Each `group_id` in `p_group_ids` exists, is active, and `p_actor_id` is a member → `FK_NOT_FOUND` per invalid group.

**Writes (atomic):**
- Set `cases.state = 'launched'`, `cases.launched_at = clock_timestamp()`.
- Compute and set `cases.reveal_at = cases.launched_at + p_duration_seconds * interval '1 second'`.
- Set `cases.deadline_at = cases.reveal_at`.
- Set `cases.duration_seconds = p_duration_seconds`.
- For each `group_id`: INSERT into `investigations(case_id, group_id)`.
- For each investigation: INSERT into `investigation_members` for every current `group_members` row for that group (excluding poster); snapshot `display_name` and `avatar_url` from `profiles`.

**Idempotency:** If case is already `launched` and the exact same `(p_case_id, p_group_ids sorted, p_duration_seconds)` is re-submitted, return existing investigation rows without error. If case is `launched` with a different group set or duration, return `FK_WRONG_STATE`.

---

## 12. `submit_guess()` — Revised Contract

```sql
CREATE OR REPLACE FUNCTION public.submit_guess(
  p_player_id        uuid,
  p_case_id          uuid,
  p_race             text,    -- 'what' or 'where'
  p_answer_text      text,
  p_idempotency_key  uuid,
  p_client_submitted_at timestamptz DEFAULT NULL
) RETURNS TABLE (attempt_id uuid, is_new boolean)
```

**Validations:**
- `p_race IN ('what','where')` → `FK_INVALID_INPUT`.
- Case in `launched` state and `reveal_at > clock_timestamp()` → `FK_WRONG_STATE`.
- Player is not the poster → `FK_FORBIDDEN`.
- Player appears in at least one `investigation_members` row for this case with `eligibility_status = 'eligible'` → `FK_FORBIDDEN`.

**Idempotency:** existing row with same `(case_id, player_id, race)` and matching `idempotency_key` + `answer_text` → returns existing row, `is_new = false`. Conflicting `answer_text` for same key → `FK_CONFLICT`. Attempt after unique constraint satisfied with different key → `FK_CONFLICT`.

---

## 13. `lock_case()` and `reveal_case()`

**`lock_case(p_case_id uuid)`** — called by scheduler Edge Function when `reveal_at` passes.
- Validates: case in `launched` state, `clock_timestamp() >= reveal_at`.
- Sets `cases.state = 'locked'`, `cases.locked_at = clock_timestamp()`.
- Returns void.
- After this call, `submit_guess()` rejects new submissions.

**`reveal_case(p_case_id uuid)`** — called by scheduler Edge Function after scoring is computed.
- Validates: case in `locked` state.
- Atomically: creates `score_run` per investigation; produces `guess_judgments` for each investigation by joining `investigation_members` to `guess_attempts`; writes `score_events` (including zero-point rows for eligible non-guessers); updates `current_score_events`; sets `cases.state = 'revealed'`, `cases.revealed_at = clock_timestamp()`.
- Returns: summary (investigation count, total judgments, total score events).
- Idempotent: if already `revealed`, returns existing summary.

**Why two steps:** If the scheduler crashes between `lock_case()` and `reveal_case()`, the case is visibly locked (no new guesses accepted) but not yet revealed (scores hidden). The system is never in an ambiguous state where `reveal_at` is past but the scoring transaction has not committed.

---

## 14. Table Talk — `comments` and `reactions`

DB table names `comments` and `reactions` are preserved. `investigation_id` column added.

```sql
ALTER TABLE public.comments ADD COLUMN investigation_id uuid NOT NULL
  REFERENCES public.investigations(investigation_id) ON DELETE RESTRICT;

-- challenge_id column renamed to case_id
ALTER TABLE public.comments RENAME COLUMN challenge_id TO case_id;
```

Existing behavior preserved: `deleted_at`, reaction uniqueness per `(comment_id, player_id, reaction_type)`, moderation flags, post-guess visibility rules.

`ON DELETE RESTRICT` (not CASCADE) on `investigation_id` — prevents silent erasure of Table Talk moderation history if an investigation is administratively cancelled.

**RLS:** Viewer must appear in `investigation_members` for the comment's `investigation_id`.

---

## 15. Clues and Corrections

**`clues`:** Case-scoped. All investigations of a case receive the same clues simultaneously. Fairness: overlapping members cannot get different clues in different investigations.

```sql
ALTER TABLE public.clues RENAME COLUMN challenge_id TO case_id;
```

**`challenge_answer_aliases`:** Renamed to `case_answer_aliases` (or column renamed); `challenge_id → case_id`. Used by scoring judgment to accept alternative correct answers.

**`correction_events`:** `challenge_id → case_id`. When a correction is recorded, `reveal_case()` (or a correction rerun function) recalculates `score_runs` for **every** investigation of the corrected case atomically.

---

## 16. RLS Design

**Guess visibility (GPT blocker §10):** A viewer may see a `guess_attempts` row if and only if:
1. The viewer is the author (`player_id = auth.uid()`), OR
2. `cases.state = 'revealed'` AND the viewer and the author share at least one `investigation_members` row for that `case_id` where both have `eligibility_status != 'excluded'`.

Checking only case-level access is insufficient: a Family member must not see guesses from Office-only players.

**`investigation_members` RLS:** Player sees their own rows. Poster can see all members of their own case's investigations (for launch confirmation only).

---

## 17. Account Deletion Behavior (Revised)

The approved V1 deletion lifecycle is preserved. Changes for V3:

1. **`mark_auth_deleted_wrapper(p_profile_id)`** additionally: for each `investigation_members` row where `player_id = p_profile_id` and the investigation's case is in `launched` or `locked` state, set `eligibility_status = 'account_deleted'` and replace `display_name_snapshot` with an anonymized value (e.g. `'[Deleted]'`).
2. Historical `guess_attempts` and `score_events` rows are retained without identifying display data.
3. `exclusion_events` record is added per active investigation (audit trail).
4. Future `reveal_case()` scoring skips `account_deleted` members when computing "all guesses in" but still produces zero-point score events for audit completeness.

**Case poster deletes, case in `draft`/`ready`:** Case cancelled; upload sessions cleaned via V2 path.
**Case poster deletes, case in `launched`/`locked`:** Case proceeds to `revealed` normally; poster display anonymized; poster excluded from all future interactions. Canonical answers are retained.

---

## 18. Migration Plan — Dependency-Ordered

This is a **V3 migration** (`V3__case_investigation_schema.sql`). All phases run in one atomic `BEGIN` / `COMMIT` block.

**Phase ordering is mandatory.** `group_id` must not be removed from `cases` until all functions, triggers, policies, and views that join through `challenges.group_id` are replaced.

```
Phase 1 — Rename core table and column
  1a. Rename public.challenges → public.cases
  1b. Rename challenges.id references to case_id (column alias, not PK rename—PK stays uuid)
      Note: FK columns in other tables named challenge_id are renamed in their respective phases.
  1c. Extend cases.state CHECK to include 'ready', 'locked', 'revealed', 'retired'
      (draft/active/cancelled already exist; 'active' replaced by 'launched')
  1d. Add cases.duration_seconds, launched_at, locked_at, revealed_at columns
  1e. DO NOT remove group_id yet.

Phase 2 — Rename challenge_secrets
  2a. Rename public.challenge_secrets → public.case_secrets (or keep; column challenge_id → case_id)
  2b. RLS preserved exactly as V1; no schema move.

Phase 3 — Create new tables
  3a. CREATE TABLE public.investigations
  3b. CREATE TABLE public.investigation_members

Phase 4 — Migrate eligible_participants → investigation_members
  4a. For each existing cases row: INSERT one investigations row
      (case_id = cases.id, group_id = cases.group_id)
  4b. INSERT investigation_members from eligible_participants joined to investigations
  4c. DROP public.eligible_participants (after verification)

Phase 5 — Rename challenge_id columns in dependent tables
  5a. guess_attempts.challenge_id → case_id
  5b. exclusion_events.challenge_id → case_id
  5c. clues.challenge_id → case_id
  5d. comments.challenge_id → case_id; add investigation_id NOT NULL
  5e. challenge_answer_aliases → column rename or table rename
  5f. correction_events.challenge_id → case_id
  5g. score_runs.challenge_id → case_id; add investigation_id NOT NULL
  5h. guess_judgments.challenge_id → case_id; add investigation_id NOT NULL
  5i. score_events.challenge_id → case_id; add investigation_id NOT NULL
  5j. current_score_events.challenge_id → case_id; add investigation_id NOT NULL
  5k. upload_sessions.challenge_id → case_id

Phase 6 — Update all V1 functions (CREATE OR REPLACE)
  All functions referencing challenges, challenge_id, group_id via challenges join.
  Must be updated before triggers and policies.

Phase 7 — Update all V2 functions (CREATE OR REPLACE)
  10 functions from §9 inventory; 17 unchanged.

Phase 8 — Update triggers
  Drop and recreate all challenge-referencing triggers with case-aware logic.

Phase 9 — Update RLS policies
  All policies on cases, case_secrets, guess_attempts, comments, scoring tables.
  Apply guess visibility rule from §16.

Phase 10 — Remove group_id from cases
  10a. Verify zero functions/triggers/policies still reference cases.group_id
  10b. DROP COLUMN public.cases.group_id

Phase 11 — Create new functions
  launch_case, submit_guess, lock_case, reveal_case, approve_case_media

Phase 12 — Update storage paths
  No existing storage data (pre-launch); document that path prefix changes to cases/.

Phase 13 — Grants, ownership, completion marker
```

---

## 19. Acceptance Criteria

### 19.1 Schema
- All V1 tables present with renamed columns; no tables dropped without replacement.
- `public.cases` has all fields from §4; no `group_id`; state CHECK includes all 7 values.
- `public.investigations` and `public.investigation_members` exist with correct constraints.
- `public.challenge_secrets` (or `case_secrets`) stays in `public` schema with RLS.
- `score_runs`, `guess_judgments`, `score_events`, `current_score_events` all have `investigation_id` NOT NULL.
- `comments` has `investigation_id` NOT NULL.
- `private.upload_sessions.case_id` exists; `challenge_id` does not.

### 19.2 Case State Machine
- `draft → ready` via `approve_case_media()`: media set to `ready`, case advanced atomically.
- `ready → launched` via `launch_case()` with valid inputs: investigations + members created.
- `launched → locked` via `lock_case()` after `reveal_at`: submissions rejected after.
- `locked → revealed` via `reveal_case()`: scoring committed; `revealed_at` set.
- `draft|ready → cancelled`: succeeds; no investigations.
- `launched → cancelled` without admin flag: rejected.
- Direct write of `cases.state` by `authenticated` role: rejected by trigger.

### 19.3 Duration
- `duration_seconds = 3600` (1 hour) → accepted.
- `duration_seconds = 86400` (24 hours) → accepted.
- `duration_seconds = 7200` (2 hours) → accepted (default).
- `duration_seconds = 3601` (not 1-hour increment) → rejected.
- `duration_seconds = 0` → rejected.
- `duration_seconds = 90000` (>24 hours) → rejected.
- `reveal_at` computed by DB: equals `launched_at + duration_seconds`.

### 19.4 Investigation Members
- At launch: one `investigation_members` row per eligible group member per investigation; poster excluded.
- Member added to group after launch: NOT in `investigation_members`.
- Member removed from group after launch: still in `investigation_members`.
- Account deletion: `eligibility_status = 'account_deleted'`; `display_name_snapshot` anonymized; row retained.

### 19.5 Guess Submission (Two Races)
- `race = 'what'` submitted → row inserted; `race = 'where'` not yet submitted → "all guesses in" = false.
- Both races submitted → "all guesses in" = true for that player.
- Poster submits → `FK_FORBIDDEN`.
- Non-member submits → `FK_FORBIDDEN`.
- Submit after `locked` → `FK_WRONG_STATE`.
- Idempotent retry (same key + answer) → existing row, no error.
- Conflicting retry (same key, different answer) → `FK_CONFLICT`.
- Player in two investigations: one `guess_attempts` row; both investigations score it at reveal.

### 19.6 Scoring
- After `reveal_case()`: every eligible `investigation_members` row has a `score_events` row (including zero-point for non-guessers).
- Player in two investigations: two `score_events` rows (one per investigation).
- `current_score_events` holds latest per `(investigation_id, player_id)`.
- Correction: new `score_run` created; all investigations rescored atomically; `current_score_events` updated.
- `reveal_case()` twice: idempotent; no duplicate scoring rows.

### 19.7 Table Talk
- `comments` row requires `investigation_id` in V3; INSERT without it rejected.
- RLS: viewer not in `investigation_members` cannot see comment.
- Family investigation Table Talk not visible in Office investigation for shared player.
- `deleted_at` preserved; reaction uniqueness preserved.

### 19.8 Guess Visibility (RLS)
- Before reveal: player sees own guess only.
- After reveal: player sees guesses from members of shared investigations only.
- Office-only player's guess not visible to Family-only viewer after reveal.

### 19.9 `launch_case()` Validations
- Duplicate `group_ids` in array → `FK_INVALID_INPUT`.
- Empty array → `FK_INVALID_INPUT`.
- More than 10 groups → `FK_INVALID_INPUT`.
- Actor not poster → `FK_NOT_FOUND`.
- Case not in `ready` state → `FK_WRONG_STATE`.
- Media not approved → `FK_WRONG_STATE`.
- Active upload session exists → `FK_WRONG_STATE`.
- Group actor is not a member of → `FK_NOT_FOUND`.
- Idempotent resubmit (same inputs, already launched) → existing rows returned.
- Different group set after launch → `FK_WRONG_STATE`.

### 19.10 V2 Upload Functions
- `reserve_upload_session(p_case_id, ...)` generates path `cases/{case_id}/originals/{session_id}`.
- `p_challenge_id` parameter does not exist on any function.
- All 17 unchanged functions pass their existing V2 acceptance tests verbatim.
- `finalize_upload_session()` behavior unchanged; case state does not advance at finalize (advance happens via `approve_case_media()`).

### 19.11 Account Deletion
- `mark_auth_deleted_wrapper()` sets `investigation_members.eligibility_status = 'account_deleted'` for all active investigations.
- Historical `guess_attempts` rows retained; player FK preserved (profile row anonymized not deleted).
- Historical `score_events` retained.
- `reveal_case()` after deletion: zero-point score event produced for deleted player; display uses anonymized snapshot.

### 19.12 Permissions
- `service_role` executes all new functions.
- `authenticated` cannot execute any new function directly.
- `public.investigations` RLS: member of group (via `investigation_members`) sees investigation.
- `public.case_secrets` / `challenge_secrets` RLS unchanged from V1.

---

## 20. Open Questions — Resolved

| # | Question | Resolution |
|---|---|---|
| OQ-1 | Duration window | 1–24 hours, default 2 hours, 1-hour increments. Immutable after launch. |
| OQ-2 | Max groups per launch | 10 — requires Bill's explicit approval |
| OQ-3 | Can poster change `reveal_at` after launch? | No — immutable |
| OQ-4 | Late joiners eligible? | No — frozen at launch |
| OQ-5 | DB table name for Table Talk | `comments` (DB); "Table Talk" (product copy only) |

---

## 21. Out of Scope for Step 26

- Push notification dispatch.
- Feed / discovery query design.
- Global leaderboard.
- Admin moderation UI.
- Edge Function implementations (depend on this schema).
- `challenge_secrets` → `private` schema move (separate security decision).
- `orders_to_go` feature (backlog FEAT-001).
- Archival / `retired` state transition logic.

---

*Ready for review by Bill, Claude, and Codex. No migration code will be written until all three parties approve.*
