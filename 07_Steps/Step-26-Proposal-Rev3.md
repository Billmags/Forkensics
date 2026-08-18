# Step 26 Proposal — Case / Investigation Schema
**Revision:** 3  
**Status:** DRAFT — awaiting approval from Bill, Claude, and Codex before any code is written  
**Prerequisite:** Step 25 merged and tagged (`v0.2.0-upload-sessions`)  
**Supersedes:** Rev 2 (rejected — GPT review, 13 blockers)

---

## 1. Purpose

Separate V1's `challenges` table into two distinct concepts:

- **Case** — the mystery: photo, answers, clues, location. Poster-owned. Group-agnostic.
- **Investigation** — a Table's engagement with a case: frozen participant snapshot, guesses, scoring, Table Talk.

One case → many investigations. Every approved V1 system is preserved and redistributed to the correct scope. Nothing is replaced with a simplified substitute. All changes in this revision are grounded in the actual V1 source (`V1__initial_schema.sql`).

---

## 2. Bill's Confirmed Decisions

| Decision | Answer |
|---|---|
| Maximum Tables per launch | **10 Tables** — approved |
| One locked attempt per player per race | **Yes** — one locked dish attempt and one locked restaurant attempt per player per case; once submitted, cannot be changed |

---

## 3. All Design Decisions

| # | Decision |
|---|---|
| D-1 | `challenges` → `cases`; `challenge_id` → `case_id` everywhere; `group_id` removed after all dependencies migrated |
| D-2 | `challenge_secrets` → `case_secrets`; stays in `public` schema with RLS (identical to V1); not moved to `private` — that is a separate future security decision |
| D-3 | `cases` retains all V1 `challenges` columns exactly; state CHECK extended to include `'ready'`, `'launched'`, `'retired'`; `'active'` renamed to `'launched'`; `posted_at` set when state transitions to `launched` (same trigger behavior as V1 `active`) |
| D-4 | `duration_seconds NOT NULL DEFAULT 7200`; `rules_version_id NOT NULL` with trigger default — both preserved from V1, not made nullable |
| D-5 | `story` and `has_first_guess` remain in `case_secrets`, not on `cases` |
| D-6 | `caption` not introduced — not in V1, not separately approved |
| D-7 | `deadline_at` is the single DB source of truth for the reveal deadline; `reveal_at` is not added |
| D-8 | Case state machine: `draft → ready → launched → locked → revealed → retired`; `cancelled` is a branch from any pre-`revealed` state |
| D-9 | `locked` and `revealed` are separate committed states; a case cannot appear revealed merely because `deadline_at` has passed |
| D-10 | `guess_attempts` structure preserved exactly from V1 (`dish_guess`, `restaurant_guess`, `received_at`, `receipt_sequence`, `client_submitted_at`, `ga_race_check`, `ga_race_fields_check`); only `challenge_id → case_id`; `idempotency_key uuid` added; `UNIQUE (case_id, player_id, race)` added to enforce one locked attempt per player per race |
| D-11 | `exclusion_events` is investigation-scoped (`investigation_id` FK); `case_id` retained with a cross-record integrity trigger; UNIQUE becomes `(investigation_id, player_id)`; account deletion creates one exclusion event per active investigation |
| D-12 | `eligible_participants` replaced by `investigation_members`; snapshot fields: `snapshot_display_name` (new), `snapshot_avatar_color` (from V1), `snapshot_avatar_media_object_id` (optional); no `avatar_url`; poster excluded |
| D-13 | `score_runs`, `guess_judgments`, `score_events`: all retain V1 structure; `challenge_id → case_id`; `investigation_id NOT NULL` added; uniqueness constraints updated |
| D-14 | `current_score_events` is a VIEW — dropped and recreated to add investigation dimension |
| D-15 | `correction_events.resulting_score_run_id` dropped; the existing `score_runs.triggering_correction_id` FK already provides the correct many-to-one back-reference |
| D-16 | `reactions`: challenge-level emoji reaction model preserved (`challenge_id → investigation_id`; UNIQUE `(investigation_id, player_id, emoji)`); no per-comment FK introduced |
| D-17 | `comments`: `challenge_id → case_id`; `investigation_id NOT NULL` added; `ON DELETE RESTRICT`; all V1 behavior preserved |
| D-18 | Account deletion: historical `guess_attempts` and committed `score_events` retained; one `exclusion_events` row per active investigation; `investigation_members` row anonymized; `reveal_case()` skips excluded/account_deleted members — no new score event created for them |
| D-19 | Guess visibility RLS: viewer and author must share at least one `investigation_members` row for that case; viewer must have `eligibility_status = 'eligible'`; poster has a separate explicit policy |
| D-20 | Monthly scoring aggregation: group leaderboard uses per-investigation score; monthly personal/friends count uses one score per player per case (best current investigation score); no monthly table required in Step 26 but contract documented |
| D-21 | `launch_case()` rejects duplicate group IDs; idempotent on identical re-submission; actor validated as poster |
| D-22 | Duration accepted as `duration_seconds`; DB computes `deadline_at = posted_at + duration_seconds * interval '1 second'` |
| D-23 | `approve_case_media()` approves; `reject_case_media()` rejects and triggers replacement flow; both are moderation-only service functions |
| D-24 | `reserve_upload_session(p_challenge_id → p_case_id)`: DROP + recreate with grants restored (named parameter rename not reliably supported via CREATE OR REPLACE) |

---

## 4. `public.cases` — Exact Column Set

Every column below is sourced from V1's `challenges` table. Changes from V1 are marked.

```sql
CREATE TABLE public.cases (
  id                   uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  -- group_id removed (V3 change)
  poster_id            uuid        NOT NULL REFERENCES public.profiles(id)       ON DELETE RESTRICT,
  media_object_id      uuid                 REFERENCES public.media_objects(id),
  state                text        NOT NULL DEFAULT 'draft'
                                   CHECK (state IN (
                                     'draft',
                                     'ready',      -- new: media approved, not yet launched
                                     'launched',   -- replaces V1 'active'
                                     'locked',
                                     'revealed',
                                     'retired',    -- new: post-reveal archival
                                     'cancelled'
                                   )),
  duration_seconds     integer     NOT NULL DEFAULT 7200
                                   CHECK (duration_seconds BETWEEN 3600 AND 86400
                                          AND duration_seconds % 3600 = 0),
  public_city_display  text,
  rules_version_id     uuid        NOT NULL
                                   REFERENCES public.rules_versions(id) ON DELETE RESTRICT,
  posted_at            timestamptz,   -- set when state → launched (was 'active' in V1)
  deadline_at          timestamptz,   -- single source of truth; computed at launch
  locked_at            timestamptz,
  revealed_at          timestamptz,
  cancelled_at         timestamptz,
  cancellation_reason  text,
  created_at           timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT cases_duration_check
    CHECK (duration_seconds BETWEEN 3600 AND 86400
           AND duration_seconds % 3600 = 0),
  CONSTRAINT cases_cancellation_reason_check
    CHECK (cancellation_reason IS NULL OR length(cancellation_reason) <= 500),
  CONSTRAINT cases_city_check
    CHECK (public_city_display IS NULL
           OR length(trim(public_city_display)) BETWEEN 1 AND 100)
);
```

**Trigger `case_insert_defaults`** (replaces `handle_challenge_insert`): sets `poster_id = private.auth_uid()`, `rules_version_id` default, clears timestamp fields.

**Trigger `case_protect_fields`** (replaces `challenge_protect_fields`): prevents direct writes to `posted_at`, `deadline_at`, `locked_at`, `revealed_at`, `cancelled_at`, `cancellation_reason`, `rules_version_id`; enforces state transition rules; `public_city_display` editable in `draft`/`ready` states, immutable after `launched`.

---

## 5. `public.case_secrets` (renamed from `challenge_secrets`)

Stays in `public` schema with RLS — identical security model to V1. Column `challenge_id` renamed to `case_id` only.

```sql
-- V1 columns preserved exactly:
-- case_id (PK, FK → cases)
-- display_dish, canonical_dish
-- display_restaurant, canonical_restaurant
-- story
-- has_first_guess
-- All V1 constraints, triggers (guard_answer_edits, case_secrets_guard, case_secrets_timestamps)
-- RLS policies migrated to reference cases not challenges
```

---

## 6. `public.investigations`

```sql
CREATE TABLE public.investigations (
  investigation_id    uuid  PRIMARY KEY DEFAULT gen_random_uuid(),
  case_id             uuid  NOT NULL REFERENCES public.cases(id) ON DELETE RESTRICT,
  group_id            uuid  NOT NULL REFERENCES public.groups(id) ON DELETE RESTRICT,
  status              text  NOT NULL DEFAULT 'active'
                            CHECK (status IN ('active','cancelled','tombstoned')),
  cancelled_at        timestamptz,
  cancellation_reason text,
  created_at          timestamptz NOT NULL DEFAULT now(),
  UNIQUE (case_id, group_id)
);
```

RLS: members of the group (via `investigation_members`) see the investigation. Poster sees investigations for their own cases (separate policy).

---

## 7. `public.investigation_members` (replaces `eligible_participants`)

Frozen snapshot taken at the moment `launch_case()` runs.

```sql
CREATE TABLE public.investigation_members (
  investigation_id              uuid  NOT NULL
                                      REFERENCES public.investigations(investigation_id)
                                      ON DELETE RESTRICT,
  player_id                     uuid  NOT NULL
                                      REFERENCES public.profiles(id) ON DELETE RESTRICT,
  -- Snapshot fields (copied from profiles at launch time)
  snapshot_display_name         text  NOT NULL,
  snapshot_avatar_color         text  NOT NULL,   -- preserved from V1 eligible_participants
  snapshot_avatar_media_object_id uuid,            -- optional; not dereferenced post-deletion
  -- Eligibility
  eligibility_status            text  NOT NULL DEFAULT 'eligible'
                                      CHECK (eligibility_status IN (
                                        'eligible', 'excluded', 'account_deleted'
                                      )),
  added_at                      timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY (investigation_id, player_id)
);
```

**Rules:**
- Poster is excluded from all rows.
- Snapshot is taken from `profiles` at launch time; not updated thereafter.
- `eligibility_status = 'excluded'` set when an `exclusion_events` row is recorded (cascade via trigger).
- `eligibility_status = 'account_deleted'` set by `mark_auth_deleted_wrapper()`; `snapshot_display_name` replaced with `'[Deleted]'`; `snapshot_avatar_media_object_id` set to NULL.
- `snapshot_avatar_media_object_id` is retained as-is for anonymized historical tombstones (does not bypass media deletion — media is cleaned by the separate deletion state machine).

---

## 8. `public.exclusion_events` — Investigation-Scoped

Column `challenge_id` replaced by `investigation_id`. `case_id` retained for cross-record integrity.

```sql
-- V1 structure preserved; changes:
--   challenge_id  →  investigation_id uuid NOT NULL FK → investigations
--   case_id uuid NOT NULL FK → cases  (added for integrity cross-check)
--   UNIQUE (challenge_id, player_id)  →  UNIQUE (investigation_id, player_id)
--   reason CHECK preserved: 'withdrew' | 'removed' | 'account_deleted'
--   excluded_by CHECK preserved
--
-- Cross-record integrity trigger (new):
--   BEFORE INSERT: verify investigation.case_id = NEW.case_id
```

Account deletion creates one `exclusion_events` row per active investigation where `eligibility_status != 'account_deleted'` already.

---

## 9. `public.guess_attempts` — V1 Structure Preserved

Only `challenge_id → case_id` plus the two additions approved by Bill.

```sql
-- V1 columns preserved exactly:
--   id uuid PK
--   case_id uuid NOT NULL FK → cases      (was challenge_id)
--   player_id uuid NOT NULL FK → profiles
--   race text NOT NULL CHECK ('what','where')
--   dish_guess text
--   restaurant_guess text
--   received_at timestamptz NOT NULL DEFAULT clock_timestamp()
--   receipt_sequence bigint NOT NULL
--   client_submitted_at timestamptz
--   UNIQUE (case_id, receipt_sequence)    (was challenge_id, receipt_sequence)
--   ga_race_check preserved
--   ga_race_fields_check preserved

-- Two additions (Bill-approved):
--   idempotency_key uuid NOT NULL
--   UNIQUE (case_id, player_id, race)     -- enforces one locked attempt per player per race
```

**Server-controlled `receipt_sequence`** trigger preserved exactly (establishes cross-player race order).

**Idempotency:** same `(case_id, player_id, race)` + same `idempotency_key` + same answer → existing row returned, no error. Same key + different answer → `FK_CONFLICT`. Attempt after unique constraint already satisfied → `FK_CONFLICT`.

---

## 10. Scoring Tables — Exact V1 Structure Plus `investigation_id`

### 10.1 `score_runs`

```sql
-- V1 columns preserved:
--   id uuid PK
--   case_id uuid NOT NULL FK → cases         (was challenge_id)
--   revision_number integer NOT NULL
--   rules_version_id uuid NOT NULL FK → rules_versions
--   effective_eligible_count integer NOT NULL
--   triggering_correction_id uuid FK → correction_events  (already existed in V1)
--   created_at timestamptz NOT NULL DEFAULT now()

-- V3 additions:
--   investigation_id uuid NOT NULL FK → investigations
--   UNIQUE (investigation_id, revision_number)   -- replaces UNIQUE (challenge_id, revision_number)

-- Cross-record integrity trigger (new):
--   BEFORE INSERT: verify investigation.case_id = NEW.case_id
```

### 10.2 `correction_events`

```sql
-- V1 columns preserved:
--   id uuid PK
--   case_id uuid NOT NULL FK → cases         (was challenge_id)
--   corrected_by, action, target_field, alias_id
--   old/new display/normalized values, reason, corrected_at

-- V3 change:
--   resulting_score_run_id DROPPED
--   (back-reference now via score_runs.triggering_correction_id — already existed in V1)
--   Multiple score_runs per correction (one per investigation) all reference the same
--   correction_events.id through their triggering_correction_id FK.
```

### 10.3 `guess_judgments`

```sql
-- V1 columns preserved:
--   id uuid PK
--   score_run_id uuid NOT NULL FK → score_runs
--   guess_attempt_id uuid NOT NULL FK → guess_attempts
--   player_id uuid NOT NULL FK → profiles
--   case_id uuid NOT NULL FK → cases          (was challenge_id)
--   race text NOT NULL
--   rules_version_id uuid NOT NULL FK → rules_versions
--   is_correct boolean NOT NULL
--   is_first_correct_for_player boolean NOT NULL DEFAULT false
--   created_at timestamptz NOT NULL DEFAULT now()
--   UNIQUE (score_run_id, guess_attempt_id)

-- V3 addition:
--   investigation_id uuid NOT NULL FK → investigations
--   Partial unique index preserved: one_qualifying_per_player_race (score_run_id, player_id, race) WHERE is_first_correct_for_player

-- V1 trigger (guard_judgment_insert) updated:
--   Now also validates investigation_id matches score_run.investigation_id
```

### 10.4 `score_events`

```sql
-- V1 columns preserved:
--   id uuid PK
--   score_run_id uuid NOT NULL FK → score_runs
--   case_id uuid NOT NULL FK → cases          (was challenge_id)
--   player_id uuid NOT NULL FK → profiles
--   rules_version_id uuid NOT NULL FK → rules_versions
--   what_points integer NOT NULL DEFAULT 0
--   where_points integer NOT NULL DEFAULT 0
--   total_points integer GENERATED ALWAYS AS (what_points + where_points) STORED
--   what_rank integer, where_rank integer
--   scored_at timestamptz NOT NULL DEFAULT now()
--   UNIQUE (score_run_id, player_id)
--   All CHECK constraints preserved

-- V3 addition:
--   investigation_id uuid NOT NULL FK → investigations

-- V1 trigger (guard_score_event_insert) updated:
--   Validates investigation_id matches score_run.investigation_id
```

### 10.5 `current_score_events` VIEW — Recreated

`current_score_events` is a VIEW in V1. It cannot be altered with `ALTER TABLE`. It is dropped and recreated.

```sql
CREATE OR REPLACE VIEW public.current_score_events
  SECURITY INVOKER AS
SELECT se.*
FROM public.score_events se
JOIN public.score_runs sr ON sr.id = se.score_run_id
WHERE sr.revision_number = (
  SELECT max(sr2.revision_number)
  FROM public.score_runs sr2
  WHERE sr2.investigation_id = sr.investigation_id   -- now per-investigation
);
```

GRANT SELECT ON `current_score_events` TO authenticated preserved.

---

## 11. `public.comments` and `public.reactions`

### `comments`

```sql
-- V1 columns preserved:
--   id, case_id (was challenge_id), author_id, text, posted_at, deleted_at
--   V1 constraints preserved

-- V3 addition:
--   investigation_id uuid NOT NULL REFERENCES investigations ON DELETE RESTRICT

-- ON DELETE RESTRICT (not CASCADE): prevents silent erasure of moderation history

-- Cross-record integrity trigger (new):
--   BEFORE INSERT: verify investigation.case_id = NEW.case_id
```

### `reactions`

V1 model: challenge-level emoji reactions with `UNIQUE (challenge_id, player_id, emoji)`. No per-comment FK. Preserved exactly; scope moved to investigation.

```sql
-- V1 columns preserved:
--   id, investigation_id (was challenge_id), player_id, emoji, reacted_at
--   UNIQUE (investigation_id, player_id, emoji)    -- was (challenge_id, player_id, emoji)
--   reactions_emoji_check preserved
--   V1 timestamp trigger preserved
```

No per-comment reaction system introduced. That is a separate future product proposal.

---

## 12. `public.clues` and `public.challenge_answer_aliases`

Both are case-scoped. `challenge_id → case_id` only; all V1 structure, constraints, and triggers preserved.

Clues are case-scoped for fairness: all investigations of a case receive the same clues simultaneously.

---

## 13. `private.upload_sessions` — V2 Column Rename

`challenge_id → case_id`. FK updated to `REFERENCES public.cases(id)`. Storage path prefix changes from `challenges/` to `cases/` (pre-launch; no existing storage objects to migrate).

---

## 14. V2 Function Impact — Sourced From V2 Migration

Functions verified against actual `V2__upload_sessions.sql` source. Named-parameter renames that cannot be done via `CREATE OR REPLACE` require `DROP FUNCTION` + recreate with grants and ownership restored.

| Function | Change | Method |
|---|---|---|
| `reserve_upload_session(p_challenge_id, ...)` | `p_challenge_id → p_case_id`; `public.challenges → public.cases`; storage path `challenges/ → cases/`; state check `draft` unchanged | DROP + recreate; restore grants + owner |
| `activate_upload_session` | `upload_sessions.challenge_id → case_id` internal ref | CREATE OR REPLACE |
| `resolve_upload_session` | `upload_sessions.case_id` column ref | CREATE OR REPLACE |
| `advance_upload_session_processing` | `upload_sessions.case_id` column ref | CREATE OR REPLACE |
| `check_upload_session_lease` | No case/challenge reference | No change |
| `advance_upload_session_sanitized` | No case/challenge reference | No change |
| `finalize_upload_session` | `public.challenges → public.cases`; `challenge_id → case_id`; media approval path updated (see §15) | CREATE OR REPLACE |
| `fail_upload_session` | No case/challenge reference | No change |
| `quiesce_upload_sessions_for_deletion` | `upload_sessions.case_id` column ref | CREATE OR REPLACE |
| `get_upload_capability_expiry` | No case/challenge reference | No change |
| `get_all_upload_session_paths_for_deletion` | `upload_sessions.case_id` column ref | CREATE OR REPLACE |
| `claim_cleanup_sessions` | No case/challenge reference | No change |
| `mark_session_cleaned` | No case/challenge reference | No change |
| `mark_original_path_post_expiry_cleaned` | No case/challenge reference | No change |
| `get_complete_sessions_pending_expiry_cleanup` | No case/challenge reference | No change |
| `get_superseded_media_to_clean` | No case/challenge reference | No change |
| `mark_superseded_media_cleaned` | No case/challenge reference | No change |
| `get_media_storage_key` | No case/challenge reference | No change |
| `reveal_challenge_service_wrapper` | Rename to `reveal_case_service_wrapper`; `challenges → cases` | DROP + recreate; restore grants + owner |
| `prepare_account_deletion_wrapper` | `upload_sessions.case_id` ref | CREATE OR REPLACE |
| `get_deletion_storage_keys` | `upload_sessions.case_id` ref | CREATE OR REPLACE |
| `record_deletion_failure_wrapper` | No case/challenge reference | No change |
| `mark_auth_deleted_wrapper` | `upload_sessions.case_id` ref; also sets `investigation_members.eligibility_status = 'account_deleted'` and anonymizes snapshot | CREATE OR REPLACE |
| `mark_storage_cleaned_wrapper` | No case/challenge reference | No change |
| `claim_deletion_recovery_records` | No case/challenge reference | No change |
| `complete_deletion_recovery` | No case/challenge reference | No change |
| `fail_deletion_recovery` | No case/challenge reference | No change |

**V2 trigger renames:**
- `challenge_v2_no_active_upload_on_activate` → `case_v2_no_active_upload_on_launch` (fires on `ready → launched` transition)
- `challenge_v2_media_ready_on_activate` → `case_v2_media_ready_on_launch` (fires on `ready → launched` transition)

---

## 15. Media Moderation Functions

`finalize_upload_session()` produces a `media_objects` row with `status = 'pending_review'`. Two new service functions manage the moderation decision:

**`approve_case_media(p_case_id uuid)`** — service-role only, owned by `forkensics_executor`:
- Validates: case in `draft` state; `cases.media_object_id` is not NULL; that media object's status is `pending_review`.
- Atomically: `media_objects.status = 'ready'`; `cases.state = 'ready'`.
- Returns void.

**`reject_case_media(p_case_id uuid, p_reason text)`** — service-role only:
- Validates: case in `draft` state; `cases.media_object_id` is not NULL; that media object's status is `pending_review`.
- Atomically: `media_objects.status = 'rejected'`; `cases.state = 'draft'` (unchanged — still draft, awaiting replacement); `cases.media_object_id` set to NULL.
- The rejected `media_objects` row is cleaned up by the existing `get_superseded_media_to_clean` / `mark_superseded_media_cleaned` path.
- Poster may then initiate a new upload session (case is `draft` with no active media object).
- `approve_case_media()` may only be called when the currently attached media object is `pending_review`; a previously rejected object cannot be re-approved.

---

## 16. New Service Functions

### `launch_case(p_actor_id, p_case_id, p_group_ids[], p_duration_seconds)`

Validations (in order):
1. No duplicate values in `p_group_ids` → `FK_INVALID_INPUT`.
2. Array length 1–10 → `FK_INVALID_INPUT`.
3. `p_duration_seconds` satisfies constraint (3600–86400, multiple of 3600) → `FK_INVALID_INPUT`.
4. Actor profile exists, `onboarding_complete = true`, not deletion-pending → `FK_FORBIDDEN`.
5. Case exists and `poster_id = p_actor_id` → `FK_NOT_FOUND`.
6. Case state is `ready` → `FK_WRONG_STATE`.
7. `case_secrets` row exists and all canonical fields non-null → `FK_WRONG_STATE`.
8. `cases.media_object_id` is not NULL and `media_objects.status = 'ready'` → `FK_WRONG_STATE`.
9. No active `upload_sessions` (`status IN ('pending','processing','sanitized')`) for this case → `FK_WRONG_STATE`.
10. Each group exists, is active, and actor is a member → `FK_NOT_FOUND` per invalid group.

Writes (atomic):
- `cases.state = 'launched'`, `posted_at = clock_timestamp()`, `deadline_at = clock_timestamp() + p_duration_seconds * interval '1 second'`, `duration_seconds = p_duration_seconds`.
- INSERT `investigations` row per group.
- INSERT `investigation_members` rows from current `group_members` for each group (poster excluded); snapshot `display_name`, `avatar_color`, `avatar_media_object_id` from `profiles`.

Idempotency: same request against already-`launched` case → return existing investigation rows, no error. Different group set or duration → `FK_WRONG_STATE`.

Returns `TABLE (investigation_id uuid, group_id uuid)`.

### `submit_guess(p_player_id, p_case_id, p_race, p_dish_guess, p_restaurant_guess, p_idempotency_key, p_client_submitted_at)`

Preserves V1 field structure (`dish_guess` / `restaurant_guess` / `ga_race_fields_check`).

Validations: `p_race IN ('what','where')`; case `launched`; `deadline_at > clock_timestamp()`; player not poster; player appears in at least one `investigation_members` row for this case with `eligibility_status = 'eligible'`.

### `lock_case(p_case_id uuid)`

Scheduler-called. Validates case `launched` and `clock_timestamp() >= deadline_at`. Sets `state = 'locked'`, `locked_at = clock_timestamp()`. After this, `submit_guess()` rejects new submissions.

### `reveal_case(p_case_id uuid)`

Scheduler-called. Validates case `locked`. Atomically per investigation: creates `score_run`, produces `guess_judgments` (joining `investigation_members` where `eligibility_status = 'eligible'` to `guess_attempts` on `case_id + player_id`), writes `score_events` (zero-point rows for eligible non-guessers), updates `current_score_events` view. Sets `cases.state = 'revealed'`, `revealed_at = clock_timestamp()`. Excludes `account_deleted` members from all scoring — no new score events created for them. Idempotent. Returns summary.

---

## 17. RLS Design

**Guess visibility:** Viewer may see a `guess_attempts` row if:
- The viewer is the author (`player_id = auth.uid()`), OR
- Case is `revealed` AND the viewer and author share at least one `investigation_members` row for this `case_id` where the viewer's `eligibility_status = 'eligible'`.

Account-deleted authors' rows remain visible to eligible co-investigators after reveal (historical record), but the display uses the anonymized snapshot.

**Poster access:** Poster is not in `investigation_members`. A separate explicit policy grants the poster SELECT on `investigations` and `investigation_members` for their own cases (for launch confirmation only). After reveal, poster sees aggregate results, not individual guess content (product decision to be formalized in UX step).

**Cancelled/tombstoned investigations:** Members retain SELECT on their investigation rows and historical Table Talk. `status = 'tombstoned'` hides the investigation from active feeds but preserves the audit record.

**Account-deleted viewers:** A user whose account is deleted is not a valid viewer. RLS policies check `auth.uid()` which is NULL for deleted sessions.

---

## 18. Account Deletion Behavior

1. `quiesce_upload_sessions_for_deletion()` — unchanged from V2.
2. `mark_auth_deleted_wrapper()` additionally:
   a. For each `investigation_members` row where `player_id = p_profile_id` and `eligibility_status = 'eligible'` and the investigation's case is `launched` or `locked`:
      - Set `eligibility_status = 'account_deleted'`.
      - Set `snapshot_display_name = '[Deleted]'`, `snapshot_avatar_media_object_id = NULL`.
      - INSERT one `exclusion_events` row (`reason = 'account_deleted'`, `excluded_by = NULL`).
3. Historical `guess_attempts` rows: retained; `player_id` FK preserved (profile row anonymized by existing V1 deletion state machine, not deleted).
4. Historical committed `score_events` rows: retained without change.
5. `reveal_case()` after deletion: the deleted player is excluded from scoring. No new `score_events` row created. `effective_eligible_count` in the `score_run` reflects the reduced count.

---

## 19. Monthly Scoring Aggregation Contract

No monthly leaderboard table is created in Step 26. The following rules are documented now to ensure the Step 26 schema does not accidentally permit duplicate scoring.

- **Group leaderboard:** uses the `score_events` row for `(investigation_id, player_id)`. Scoped to one investigation.
- **Personal / friends leaderboard (monthly):** counts each case once per player. Where a player competed in multiple investigations for the same case, the score used is their **best current investigation score** (`max(total_points)` across all `current_score_events` for that player and case). Not summed.
- This rule must be enforced in the scoring query layer, not in the schema. The schema supports it because `score_events` has both `case_id` and `investigation_id`.

---

## 20. Migration Plan — Dependency-Ordered

V3 migration file: `V3__case_investigation_schema.sql`. One `BEGIN` / `COMMIT` block.

`group_id` must remain on `cases` until Phase 10. Every function, trigger, policy, and index that joins through `challenges.group_id` must be replaced before that column is dropped.

`investigation_id NOT NULL` columns cannot be added directly to populated tables. Pattern: add nullable → backfill → verify → set NOT NULL.

```
Phase 1 — Core table rename
  1a. ALTER TABLE public.challenges RENAME TO cases
  1b. ALTER TABLE public.case rename column group_id kept for now
  1c. Extend state CHECK constraint on cases to include 'ready','launched','retired'
      ('active' kept valid; migration updates existing 'active' rows to 'launched' later)
  1d. DO NOT add new columns that already exist after rename

Phase 2 — Rename challenge_secrets
  2a. ALTER TABLE public.challenge_secrets RENAME TO case_secrets
  2b. ALTER TABLE public.case_secrets RENAME COLUMN challenge_id TO case_id
  2c. RLS policies, triggers, grants recreated referencing case_secrets

Phase 3 — Create new tables
  3a. CREATE TABLE public.investigations
  3b. CREATE TABLE public.investigation_members

Phase 4 — Migrate eligible_participants → investigation_members
  4a. INSERT investigations rows (one per existing cases row, using cases.group_id)
  4b. INSERT investigation_members from eligible_participants joined to new investigations
      (snapshot_display_name from profiles.display_name at migration time)
  4c. DROP public.eligible_participants

Phase 5 — Rename challenge_id on dependent tables (add nullable investigation_id first)
  5a. guess_attempts: RENAME challenge_id → case_id; ADD idempotency_key; ADD UNIQUE (case_id, player_id, race)
  5b. exclusion_events: RENAME challenge_id → case_id; ADD investigation_id (nullable); backfill; SET NOT NULL; ADD case_id cross-check trigger
  5c. clues: RENAME challenge_id → case_id
  5d. comments: RENAME challenge_id → case_id; ADD investigation_id (nullable); backfill; SET NOT NULL; ADD case_id cross-check trigger
  5e. challenge_answer_aliases: RENAME challenge_id → case_id
  5f. correction_events: RENAME challenge_id → case_id; DROP resulting_score_run_id
  5g. score_runs: RENAME challenge_id → case_id; ADD investigation_id (nullable); backfill; SET NOT NULL; REPLACE UNIQUE (case_id, revision_number) → (investigation_id, revision_number)
  5h. guess_judgments: RENAME challenge_id → case_id; ADD investigation_id (nullable); backfill; SET NOT NULL
  5i. score_events: RENAME challenge_id → case_id; ADD investigation_id (nullable); backfill; SET NOT NULL
  5j. reactions: RENAME challenge_id → investigation_id (via case → investigation mapping)

Phase 6 — Update current_score_events VIEW
  6a. DROP VIEW public.current_score_events
  6b. CREATE OR REPLACE VIEW public.current_score_events (investigation-scoped)
  6c. GRANT SELECT re-applied

Phase 7 — Update all V1 functions (CREATE OR REPLACE)
  All functions referencing challenges, case_secrets (was challenge_secrets), group_id via challenges join.
  V1 state machine functions (post_challenge → launch_case, lock_challenge, reveal_challenge, cancel_challenge)
  updated to match new state names and case/investigation structure.

Phase 8 — Update V2 functions
  DROP reserve_upload_session + reveal_challenge_service_wrapper (named param changes)
  CREATE OR REPLACE remaining 8 affected functions
  Restore grants and ownership

Phase 9 — Update triggers
  Drop and recreate all challenge-referencing triggers.
  V2 triggers renamed: challenge_v2_* → case_v2_*.

Phase 10 — Update RLS policies
  All policies rewritten for cases, case_secrets, guess_attempts, comments,
  exclusion_events, scoring tables, reactions.
  Guess visibility rule (§17) applied.
  Poster explicit policy added.

Phase 11 — Remove group_id from cases
  11a. Verify (pg_depend + manual audit) zero functions/triggers/policies still reference cases.group_id
  11b. DROP CONSTRAINT cases_group_id_fk
  11c. ALTER TABLE public.cases DROP COLUMN group_id

Phase 12 — Create new service functions
  launch_case, submit_guess, lock_case, reveal_case,
  approve_case_media, reject_case_media

Phase 13 — Update existing 'active' state values
  UPDATE public.cases SET state = 'launched' WHERE state = 'active'
  (Pre-launch: zero rows expected; included for correctness)

Phase 14 — Grants, ownership, completion marker
```

---

## 21. Acceptance Criteria

### 21.1 Schema
- All V1 tables present with renamed columns; no approved tables dropped without replacement.
- `cases` has all V1 `challenges` fields; `story` and `has_first_guess` are on `case_secrets` not `cases`; `rules_version_id NOT NULL`; `duration_seconds NOT NULL DEFAULT 7200`.
- `case_secrets` in `public` schema with RLS; `challenge_secrets` does not exist.
- `investigations` and `investigation_members` exist with correct constraints.
- `score_runs`, `guess_judgments`, `score_events` have `investigation_id NOT NULL`.
- `current_score_events` is a VIEW selecting latest revision per investigation.
- `correction_events.resulting_score_run_id` column does not exist.
- `exclusion_events` references `investigation_id`, not `case_id` only.
- `reactions` references `investigation_id`; no comment FK.
- `comments` has `investigation_id NOT NULL`.
- `guess_attempts` has `idempotency_key` and `UNIQUE (case_id, player_id, race)`.
- `private.upload_sessions.case_id` exists; `challenge_id` does not.
- `cases.group_id` does not exist.

### 21.2 Case State Machine
- `draft → ready` via `approve_case_media()` succeeds; media `pending_review` → `ready` atomically.
- `draft → ready` via direct UPDATE by `authenticated` → blocked by trigger.
- `ready → launched` via `launch_case()` with valid inputs → `cases.state = 'launched'`, `posted_at` set, `deadline_at` computed correctly.
- `launched → locked` via `lock_case()` after `deadline_at` → submissions rejected after.
- `locked → revealed` via `reveal_case()` → scoring committed; `revealed_at` set.
- `draft|ready → cancelled` → succeeds; no investigations exist.
- `launched → cancelled` without admin flag → rejected.

### 21.3 Duration
- 3600 (1h), 7200 (2h), 86400 (24h) accepted; 3601 (not increment), 0, 90000 rejected.
- `deadline_at = posted_at + duration_seconds` verified after launch.
- Duration change after launch → rejected by trigger.

### 21.4 Media Moderation
- `approve_case_media()` with `pending_review` media → `ready`; case → `ready`; atomic.
- `approve_case_media()` with non-`pending_review` media → error.
- `reject_case_media()` with `pending_review` media → media `rejected`; case stays `draft`; `media_object_id` = NULL.
- Poster may then run a new upload session; new media goes through `pending_review` flow.

### 21.5 Investigation Members
- At launch: one row per eligible group member per investigation; poster excluded.
- Post-launch join: not included.
- Post-launch removal: row still present (`eligibility_status = 'eligible'`).
- Account deletion: `eligibility_status = 'account_deleted'`, display anonymized, row retained.

### 21.6 Guess Attempts
- `what` submitted → `where` still outstanding → "all guesses in" false.
- Both submitted → "all guesses in" true for that player.
- Poster submits → `FK_FORBIDDEN`.
- Non-member submits → `FK_FORBIDDEN`.
- Submit after `locked` → `FK_WRONG_STATE`.
- Idempotent retry (same key + answer) → existing row returned.
- Conflicting retry → `FK_CONFLICT`.
- Player in two investigations: one `guess_attempts` row each for `what` and `where`; both investigations score them.

### 21.7 Exclusions Investigation-Scoped
- Exclude player from Investigation A → not excluded from Investigation B for same case.
- Account deletion → one `exclusion_events` row per active investigation.
- `UNIQUE (investigation_id, player_id)` enforced.

### 21.8 Scoring
- After `reveal_case()`: every eligible `investigation_members` row has a `score_events` row (zero-point for non-guessers).
- Account-deleted members: excluded from scoring; NO `score_events` row created at reveal.
- Player in two investigations: two `score_events` rows (one per investigation).
- `current_score_events` VIEW returns latest revision per investigation.
- Correction: new `score_run` per investigation; all rescored atomically; `correction_events.triggering_correction_id` used; no `resulting_score_run_id`.
- `reveal_case()` twice: idempotent.

### 21.9 Table Talk
- `comments` INSERT without `investigation_id` → rejected.
- `reactions` INSERT without `investigation_id` → rejected.
- RLS: viewer not in `investigation_members` cannot see comment or reaction.
- Investigation A Table Talk not visible from Investigation B for shared player.
- `deleted_at` preserved; reaction UNIQUE `(investigation_id, player_id, emoji)` enforced.

### 21.10 RLS Guess Visibility
- Before reveal: player sees own guess only.
- After reveal: player sees guesses from co-members of shared investigations only.
- Office-only player's guess not visible to Family-only viewer after reveal.
- Account-deleted viewer cannot authenticate; RLS NULL check blocks all access.

### 21.11 `launch_case()` Validations
- Duplicate group IDs → `FK_INVALID_INPUT`.
- Empty / >10 groups → `FK_INVALID_INPUT`.
- Invalid duration → `FK_INVALID_INPUT`.
- Actor not poster → `FK_NOT_FOUND`.
- Case not `ready` → `FK_WRONG_STATE`.
- Incomplete case_secrets → `FK_WRONG_STATE`.
- Media not approved → `FK_WRONG_STATE`.
- Active upload session → `FK_WRONG_STATE`.
- Group actor not member of → `FK_NOT_FOUND`.
- Idempotent resubmit → existing rows returned.

### 21.12 V2 Upload Functions
- `reserve_upload_session(p_case_id, ...)` generates path `cases/{case_id}/originals/{session_id}`.
- `p_challenge_id` parameter does not exist.
- All 17 unchanged V2 functions pass existing V2 acceptance tests verbatim.
- `reveal_challenge_service_wrapper` does not exist; `reveal_case_service_wrapper` does.

### 21.13 Account Deletion
- `mark_auth_deleted_wrapper()` sets `eligibility_status = 'account_deleted'` for all active investigation_members rows.
- Historical `guess_attempts` and `score_events` retained.
- `reveal_case()` after deletion: no new score event for deleted player.

### 21.14 Permissions
- `service_role` executes all new functions.
- `authenticated` cannot execute any new function directly.
- `public.case_secrets` RLS unchanged from V1.
- `current_score_events` VIEW accessible to `authenticated` with SELECT.

---

## 22. Open Questions — All Resolved

| # | Question | Resolution |
|---|---|---|
| OQ-1 | Duration | 1–24 hours, default 2 hours, 1-hour increments |
| OQ-2 | Max Tables per launch | **10 — approved by Bill** |
| OQ-3 | Deadline change after launch | No |
| OQ-4 | Late joiners | No |
| OQ-5 | DB table name for Table Talk | `comments` / `reactions` (DB); "Table Talk" (product copy) |

---

## 23. Out of Scope for Step 26

- Push notification dispatch.
- Feed / discovery query design.
- Global / monthly leaderboard tables (contract documented in §19).
- Admin moderation UI.
- Edge Function implementations.
- `challenge_secrets` / `case_secrets` → `private` schema (separate security decision).
- Orders To Go (backlog FEAT-001).
- Retired state archival logic.
- Per-comment reaction system.

---

*Ready for review by Bill, Claude, and Codex. No migration code written until all three parties approve.*
