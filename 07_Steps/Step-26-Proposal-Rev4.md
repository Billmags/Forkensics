# Step 26 Proposal — Case / Investigation Schema
**Revision:** 4  
**Status:** DRAFT — awaiting approval from Bill, Claude, and Codex before any code is written  
**Prerequisite:** Step 25 merged and tagged (`v0.2.0-upload-sessions`)  
**Supersedes:** Rev 3 (rejected — GPT review, 8 blockers)

---

## Changes From Rev 3

| Blocker | Fix |
|---|---|
| 1 | Account deletion investigation exclusions, case cancellation, and media tombstoning moved to `prepare_account_deletion_wrapper()`; `mark_auth_deleted_wrapper()` advances state only |
| 2 | All RLS viewer and mutation policies require `profiles.is_active = true` alongside `auth.uid()` check |
| 3 | `get_superseded_media_to_clean()` and `mark_superseded_media_cleaned()` extended to also handle `rejected` status; renamed to `get_cleanable_media()` and `mark_cleanable_media_cleaned()`; acceptance test groups added |
| 4 | V2 function inventory rebuilt from actual V2 source; only 3 functions directly reference `challenges`/`challenge_id` in their bodies; corrected method column throughout |
| 5 | VIEW recreation uses `WITH (security_invoker = true)`; `guess_attempts.idempotency_key` migration pattern corrected (no `investigations.idempotency_key`); duplicate-attempt guard added before uniqueness constraint; `active→launched` conversion separated from final constraint install; authority trigger disabled for migration update |
| 6 | Poster sees individual guesses after reveal — V1 behavior preserved (Bill confirmed) |
| 7 | `reveal_case()` and correction scoring skip investigations with `status != 'active'` |
| 8 | Duplicate duration constraint removed; `rules_version_id` has no column DEFAULT (trigger-only); `snapshot_avatar_media_object_id` gets FK + `ON DELETE SET NULL`; avatar snapshot contradiction resolved |

---

## 1. Purpose

Separate V1's `challenges` table into two distinct concepts:

- **Case** — the mystery: photo, answers, clues, location. Poster-owned. Group-agnostic.
- **Investigation** — a Table's engagement with a case: frozen participant snapshot, guesses, scoring, Table Talk.

One case → many investigations. Every approved V1 system is preserved and redistributed to the correct scope.

---

## 2. Bill's Confirmed Decisions

| Decision | Answer |
|---|---|
| Maximum Tables per launch | **10 Tables** |
| One locked attempt per player per race | **Yes** — one locked `what` attempt and one locked `where` attempt per player per case; once submitted, cannot be changed |
| Poster guess visibility after reveal | **V1 behavior preserved** — poster can read individual guess attempts submitted to their case after reveal |

---

## 3. All Design Decisions

| # | Decision |
|---|---|
| D-1 | `challenges` → `cases`; `challenge_id` → `case_id` everywhere |
| D-2 | `challenge_secrets` → `case_secrets`; stays in `public` schema with RLS (identical security model to V1); not moved to `private` |
| D-3 | State CHECK extended with `'ready'`, `'launched'`, `'retired'`; `'active'` renamed to `'launched'`; `posted_at` set when state transitions to `launched` |
| D-4 | `duration_seconds NOT NULL DEFAULT 7200`; `rules_version_id NOT NULL` with no column DEFAULT (set by `case_insert_defaults` trigger) — both preserved from V1 |
| D-5 | `story` and `has_first_guess` remain in `case_secrets`, not on `cases` |
| D-6 | `caption` not introduced |
| D-7 | `deadline_at` is the single DB source of truth for the reveal deadline; `reveal_at` is not added |
| D-8 | Case state machine: `draft → ready → launched → locked → revealed → retired`; `cancelled` is a branch from any pre-`revealed` state |
| D-9 | `locked` and `revealed` are separate committed states |
| D-10 | `guess_attempts` structure preserved exactly from V1; `challenge_id → case_id`; `idempotency_key uuid NOT NULL` added; `UNIQUE (case_id, player_id, race)` added (one locked attempt per player per race, Bill-confirmed) |
| D-11 | `exclusion_events` is investigation-scoped (`investigation_id` FK); `case_id` retained with cross-record integrity trigger; UNIQUE becomes `(investigation_id, player_id)` |
| D-12 | `eligible_participants` replaced by `investigation_members`; snapshot fields: `snapshot_display_name` (new), `snapshot_avatar_color` (from V1), `snapshot_avatar_media_object_id uuid REFERENCES public.media_objects(id) ON DELETE SET NULL` (new, optional); no `avatar_url` |
| D-13 | `score_runs`, `guess_judgments`, `score_events` retain V1 structure; `challenge_id → case_id`; `investigation_id NOT NULL` added; uniqueness constraints updated |
| D-14 | `current_score_events` is a VIEW — dropped and recreated using `WITH (security_invoker = true)` syntax |
| D-15 | `correction_events.resulting_score_run_id` dropped; existing `score_runs.triggering_correction_id` FK provides the correct many-to-one reference |
| D-16 | `reactions`: challenge-level emoji model preserved; `challenge_id → investigation_id`; UNIQUE `(investigation_id, player_id, emoji)` |
| D-17 | `comments`: `challenge_id → case_id`; `investigation_id NOT NULL` added; `ON DELETE RESTRICT` |
| D-18 | Account deletion orchestration split: investigation exclusions, case cancellation (draft/ready cases only), poster anonymization, and media tombstoning (`pending_review → removed`) all happen in `prepare_account_deletion_wrapper()`; `mark_auth_deleted_wrapper()` advances deletion state only |
| D-19 | Guess visibility RLS: poster sees individual guesses after reveal (V1 behavior preserved); eligible co-investigators see each other's guesses after reveal; `profiles.is_active = true` required on every policy |
| D-20 | Monthly scoring: per-investigation score for group leaderboard; best score per player per case for monthly personal/friends leaderboard; no monthly table in Step 26 |
| D-21 | `launch_case()` rejects duplicate group IDs; idempotent on identical re-submission via `UNIQUE (case_id, group_id)`; actor validated as poster |
| D-22 | Duration accepted as `duration_seconds`; `deadline_at = posted_at + duration_seconds * interval '1 second'` |
| D-23 | `approve_case_media()` advances case to `ready`; `reject_case_media()` marks media `removed`, clears `media_object_id`, case stays `draft` |
| D-24 | `reserve_upload_session(p_case_id, ...)`: DROP + recreate; named param rename; storage path `challenges/ → cases/`; grants + ownership restored |
| D-25 | `snapshot_avatar_media_object_id`: FK with `ON DELETE SET NULL`; cleared to NULL during account deletion; NOT retained as-is post-deletion (full anonymization) |
| D-26 | `reveal_case()` and correction scoring only create `score_runs` for investigations with `status = 'active'`; cancelled/tombstoned investigations receive no new scoring |

---

## 4. `public.cases` — Exact Column Set

Based on V1's `challenges` table. Changes marked.

```sql
CREATE TABLE public.cases (
  id                   uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  -- group_id REMOVED (V3 change; dropped in Phase 11 after all dependencies migrated)
  poster_id            uuid        NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  media_object_id      uuid                 REFERENCES public.media_objects(id),
  state                text        NOT NULL DEFAULT 'draft'
                                   CHECK (state IN (
                                     'draft', 'ready', 'launched',
                                     'locked', 'revealed', 'retired', 'cancelled'
                                   )),
  duration_seconds     integer     NOT NULL DEFAULT 7200,
  public_city_display  text,
  rules_version_id     uuid        NOT NULL REFERENCES public.rules_versions(id) ON DELETE RESTRICT,
                                   -- No column DEFAULT. Set by case_insert_defaults trigger.
  posted_at            timestamptz,
  deadline_at          timestamptz,
  locked_at            timestamptz,
  revealed_at          timestamptz,
  cancelled_at         timestamptz,
  cancellation_reason  text,
  created_at           timestamptz NOT NULL DEFAULT now(),

  -- Named table-level constraints only (no duplicate inline CHECKs)
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

**Trigger `case_insert_defaults`** (replaces `handle_challenge_insert`): sets `poster_id = private.auth_uid()`, `rules_version_id` from current default, clears timestamp fields on INSERT.

**Trigger `case_protect_fields`** (replaces `challenge_protect_fields`): prevents direct writes to `posted_at`, `deadline_at`, `locked_at`, `revealed_at`, `cancelled_at`, `cancellation_reason`, `rules_version_id`; enforces state transitions; immutable after `launched` for `public_city_display`.

Migration note: this trigger must be temporarily disabled during Phase 13 (state conversion `active → launched`) to allow the UPDATE to proceed without triggering the transition guard.

---

## 5. `public.case_secrets` (renamed from `challenge_secrets`)

Stays in `public` schema with RLS. Only `challenge_id → case_id`. All V1 columns, constraints, triggers (`guard_answer_edits`, `case_secrets_guard`, `case_secrets_timestamps`) and RLS policies preserved, updated to reference `cases`.

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

`UNIQUE (case_id, group_id)` serves as the structural idempotency mechanism for `launch_case()` re-submissions. No explicit `idempotency_key` column is added to this table.

---

## 7. `public.investigation_members` (replaces `eligible_participants`)

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

**Snapshot rules:**
- Taken from `profiles` at `launch_case()` execution time; not updated afterward.
- Poster is excluded from all rows (poster ≠ player in investigation context).
- `eligibility_status = 'account_deleted'` is set by `prepare_account_deletion_wrapper()` — not by `mark_auth_deleted_wrapper()`.
- On account deletion: `snapshot_display_name = '[Deleted]'`, `snapshot_avatar_media_object_id = NULL`. `snapshot_avatar_color` is retained (anonymized color is not PII).
- `snapshot_avatar_media_object_id ON DELETE SET NULL`: also nulled if the media object is deleted independently.

---

## 8. `public.exclusion_events` — Investigation-Scoped

```sql
-- V1 columns preserved; changes from V1:
--   challenge_id  →  investigation_id uuid NOT NULL FK → investigations
--   case_id uuid NOT NULL FK → cases    (retained for cross-record integrity)
--   UNIQUE (challenge_id, player_id)  →  UNIQUE (investigation_id, player_id)
--   reason CHECK preserved: 'withdrew' | 'removed' | 'account_deleted'
--   excluded_by CHECK preserved

-- Cross-record integrity trigger (new):
--   BEFORE INSERT: verify investigations.case_id = NEW.case_id
```

Account deletion: `prepare_account_deletion_wrapper()` creates one `exclusion_events` row per `active` investigation where the player's `eligibility_status = 'eligible'` (not already excluded).

---

## 9. `public.guess_attempts` — V1 Structure Preserved

```sql
-- V1 columns preserved exactly:
--   id uuid PK
--   case_id uuid NOT NULL FK → cases      (was challenge_id)
--   player_id uuid NOT NULL FK → profiles
--   race text NOT NULL CHECK ('what','where')
--   dish_guess text
--   restaurant_guess text
--   received_at timestamptz NOT NULL DEFAULT clock_timestamp()
--   receipt_sequence bigint NOT NULL (server-managed, trigger-set)
--   client_submitted_at timestamptz
--   UNIQUE (case_id, receipt_sequence)
--   ga_race_check preserved
--   ga_race_fields_check preserved

-- Two additions (Bill-confirmed):
--   idempotency_key uuid NOT NULL
--   UNIQUE (case_id, player_id, race)     -- one locked attempt per player per race
```

**Migration pattern for `idempotency_key`:**
1. `ALTER TABLE guess_attempts ADD COLUMN idempotency_key uuid` (nullable)
2. `UPDATE guess_attempts SET idempotency_key = gen_random_uuid() WHERE idempotency_key IS NULL`
3. `ALTER TABLE guess_attempts ALTER COLUMN idempotency_key SET NOT NULL`

**Migration pattern for `UNIQUE (case_id, player_id, race)`:**
1. `DO $$ BEGIN IF EXISTS (SELECT 1 FROM guess_attempts GROUP BY case_id, player_id, race HAVING count(*) > 1) THEN RAISE EXCEPTION 'duplicate player/race attempts exist — cannot add uniqueness constraint'; END IF; END $$;`
2. `CREATE UNIQUE INDEX guess_attempts_one_per_player_race ON guess_attempts (case_id, player_id, race);`

---

## 10. Scoring Tables

### 10.1 `score_runs`

```sql
-- V1 columns preserved:
--   id uuid PK
--   case_id uuid NOT NULL FK → cases         (was challenge_id)
--   revision_number integer NOT NULL
--   rules_version_id uuid NOT NULL FK → rules_versions
--   effective_eligible_count integer NOT NULL
--   triggering_correction_id uuid FK → correction_events  (existed in V1)
--   created_at timestamptz NOT NULL DEFAULT now()

-- V3 addition:
--   investigation_id uuid NOT NULL FK → investigations
--   UNIQUE (investigation_id, revision_number)   -- replaces UNIQUE (challenge_id, revision_number)

-- Cross-record integrity trigger:
--   BEFORE INSERT: verify investigations.case_id = NEW.case_id
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
--   (back-reference via score_runs.triggering_correction_id — V1 already had this)
```

### 10.3 `guess_judgments`

```sql
-- V1 preserved; investigation_id uuid NOT NULL added
-- Cross-record integrity trigger validates investigation_id matches score_run.investigation_id
```

### 10.4 `score_events`

```sql
-- V1 preserved; investigation_id uuid NOT NULL added
-- UNIQUE (score_run_id, player_id) preserved
-- Guard trigger validates investigation_id matches score_run.investigation_id
```

### 10.5 `current_score_events` VIEW — Dropped and Recreated

`current_score_events` is a VIEW in V1 (`CREATE OR REPLACE VIEW`). It cannot be altered. DROP + recreate.

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

## 11. `public.comments` and `public.reactions`

### `comments`
`challenge_id → case_id`; `investigation_id uuid NOT NULL FK → investigations ON DELETE RESTRICT`; cross-record integrity trigger. All V1 behavior preserved.

### `reactions`
`challenge_id → investigation_id`; UNIQUE `(investigation_id, player_id, emoji)`. Challenge-level emoji reaction model preserved exactly. No per-comment FK.

---

## 12. `public.clues` and `public.challenge_answer_aliases`

`challenge_id → case_id` only. All V1 structure, constraints, triggers preserved.

---

## 13. `private.upload_sessions` — Column Rename

`challenge_id → case_id`. FK updated to `REFERENCES public.cases(id)`. Index `upload_sessions_one_active_per_challenge` → `upload_sessions_one_active_per_case`.

Storage paths in existing rows: no existing storage objects pre-launch; migration includes `UPDATE private.upload_sessions SET original_storage_path = replace(original_storage_path, 'challenges/', 'cases/'), display_storage_path = replace(display_storage_path, 'challenges/', 'cases/')` for completeness.

---

## 14. V2 Function Impact — Sourced From Actual V2 Migration

Functions verified line-by-line against `V2__upload_sessions.sql`. Only functions whose **bodies** directly reference `challenge_id` column, `public.challenges` table, or `challenges/` storage path are marked as requiring changes.

### 14.1 Functions Requiring Changes

| Function | What references challenges/challenge_id | Method |
|---|---|---|
| `reserve_upload_session(p_challenge_id uuid, ...)` | `p_challenge_id` param; `public.challenges` SELECT FOR UPDATE; `private.upload_sessions.challenge_id` INSERT; storage paths `'challenges/'` | DROP + recreate; `p_challenge_id → p_case_id`; `challenges → cases`; update storage paths; restore grants + ownership |
| `finalize_upload_session(uuid, text)` | `v_session.challenge_id` field read; `public.challenges AS ch` SELECT FOR UPDATE; `UPDATE public.challenges`; `private.upload_sessions.challenge_id` via `v_session.challenge_id` | CREATE OR REPLACE; no param name change; rename all internal references |
| `reveal_challenge_service_wrapper(p_challenge_id uuid)` | Function name; `p_challenge_id` param; calls `private.reveal_challenge_service(p_challenge_id)` | DROP + recreate as `reveal_case_service_wrapper(p_case_id uuid)`; update private function call; restore grants + ownership |
| `prepare_account_deletion_wrapper(p_user_id uuid)` | No challenge/case reference in V2 body — **no rename needed**. V3 additions: insert investigation exclusion logic and case cancellation before the `private.prepare_account_deletion(p_user_id)` call. | CREATE OR REPLACE |
| `get_superseded_media_to_clean()` | V2 queries `WHERE mo.status = 'superseded'` only — does not cover `rejected`. Rename and extend. | DROP + recreate as `get_cleanable_media()`; extend to `status IN ('superseded','rejected')` |
| `mark_superseded_media_cleaned(p_media_object_id uuid)` | V2 `WHERE status = 'superseded'` only — does not cover `rejected`. Rename and extend. | DROP + recreate as `mark_cleanable_media_cleaned(p_media_object_id uuid)`; extend to `status IN ('superseded','rejected')` |

### 14.2 Functions With No Body Changes

The following functions reference `private.upload_sessions` by columns other than `challenge_id` (e.g. `session_id`, `uploader_id`, `status`). The column rename from `challenge_id → case_id` on the table does not affect their SQL bodies. No changes required.

`activate_upload_session`, `resolve_upload_session`, `advance_upload_session_processing`, `check_upload_session_lease`, `advance_upload_session_sanitized`, `fail_upload_session`, `quiesce_upload_sessions_for_deletion`, `get_upload_capability_expiry`, `get_all_upload_session_paths_for_deletion`, `claim_cleanup_sessions`, `mark_session_cleaned`, `mark_original_path_post_expiry_cleaned`, `get_complete_sessions_pending_expiry_cleanup`, `get_media_storage_key`, `get_deletion_storage_keys`, `record_deletion_failure_wrapper`, `mark_auth_deleted_wrapper`, `mark_storage_cleaned_wrapper`, `claim_deletion_recovery_records`, `complete_deletion_recovery`, `fail_deletion_recovery`

### 14.3 Trigger Functions Requiring Changes

| V2 Trigger Function | V3 Change | Method |
|---|---|---|
| `private.check_activation_no_active_upload()` on `public.challenges` | Fires on `'draft' → 'active'`; checks `challenge_id = NEW.id`. V3: fire on `'draft' → 'launched'`; check `case_id = NEW.id`. Rename trigger `challenge_v2_no_active_upload_on_activate → case_v2_no_active_upload_on_launch`. | DROP trigger + DROP function; recreate both on `public.cases` |
| `private.check_activation_media_ready()` on `public.challenges` | Same pattern. Rename trigger `challenge_v2_media_ready_on_activate → case_v2_media_ready_on_launch`. | DROP trigger + DROP function; recreate both on `public.cases` |

### 14.4 V2 Acceptance Test Impact

The V2 acceptance tests (`V2_acceptance_tests.sql`) use the `test_helpers.insert_session_direct()` helper which directly inserts into `private.upload_sessions` referencing the `challenge_id` column. After V3, that column is `case_id`. The helper also calls `reserve_upload_session(p_challenge_id, ...)`. All 17 existing test groups require updates:

- `test_helpers.insert_session_direct`: rename `p_challenge_id → p_case_id`, update INSERT column, update `public.challenges → public.cases` references
- `test_helpers.make_bare_draft_challenge`: rename to `make_bare_draft_case`; update INSERT to `public.cases`
- All `reserve_upload_session(p_challenge_id := ...)` calls → `reserve_upload_session(p_case_id := ...)`
- All `public.challenges` references in assertion queries → `public.cases`

The V3 acceptance test file (`V3_acceptance_tests.sql`) extends V2 with new groups covering investigations, launch, and the items in §22.

---

## 15. Media Moderation Functions

### `approve_case_media(p_case_id uuid)`
- Validates: case in `draft` state; `cases.media_object_id NOT NULL`; that media object's status is `pending_review`.
- Atomically: `media_objects.status = 'ready'`; `cases.state = 'ready'`.
- Returns void.
- Idempotent: already-`ready` case + already-`ready` media → no-op, return success.

### `reject_case_media(p_case_id uuid, p_reason text)`
- Validates: case in `draft` state; `cases.media_object_id NOT NULL`; that media object's status is `pending_review`.
- Atomically: `media_objects.status = 'removed'` (not `'rejected'` — `removed` signals moderation-driven removal for cleanup); `cases.media_object_id = NULL`.
- Case stays `draft`; poster may initiate a new upload session.
- The removed `media_objects` row is picked up by `get_cleanable_media()` (new; see §16).

---

## 16. Rejected/Superseded Media Cleanup — Extended Contract

V2's `get_superseded_media_to_clean()` queries `WHERE mo.status = 'superseded'` only. `reject_case_media()` produces `status = 'removed'` rows that the V2 cleanup path never claims. This gap is closed by renaming and extending both functions.

### `get_cleanable_media()` (replaces `get_superseded_media_to_clean`)
```sql
CREATE OR REPLACE FUNCTION public.get_cleanable_media()
RETURNS TABLE (
  media_object_id        uuid,
  storage_key            text,    -- original path
  re_encoded_storage_key text     -- display path
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT mo.id, msk.storage_key, msk.re_encoded_storage_key
  FROM public.media_objects mo
  JOIN private.media_storage_keys msk ON msk.media_object_id = mo.id
  WHERE mo.status IN ('superseded', 'removed');
$$;
```

Both storage keys are returned so the caller can delete both objects.

### `mark_cleanable_media_cleaned(p_media_object_id uuid)` (replaces `mark_superseded_media_cleaned`)
```sql
CREATE OR REPLACE FUNCTION public.mark_cleanable_media_cleaned(p_media_object_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
  UPDATE public.media_objects
  SET status = 'cleaned'
  WHERE id     = p_media_object_id
    AND status IN ('superseded', 'removed');
  -- Idempotent: already 'cleaned' is acceptable (no NOT FOUND check).
END;
$$;
```

Old functions `get_superseded_media_to_clean()` and `mark_superseded_media_cleaned()` are dropped and replaced. All callers updated to new names.

---

## 17. `prepare_account_deletion_wrapper()` — V3 Additions

All investigation-related work happens here, before the Auth user is deleted. `mark_auth_deleted_wrapper()` advances the deletion state only.

**V3 additions to the `prepare_account_deletion_wrapper()` body**, executed before the existing `private.prepare_account_deletion(p_user_id)` call:

```
Step A — Cancel draft/ready cases where this user is the poster
  UPDATE cases SET state = 'cancelled',
    cancelled_at = clock_timestamp(),
    cancellation_reason = 'account_deleted'
  WHERE poster_id = p_user_id
    AND state IN ('draft', 'ready')

  -- launched/locked cases by this poster are left to complete their lifecycle.
  -- The poster's display on those cases is handled by profiles anonymization
  -- in private.prepare_account_deletion (existing V1 step).

Step B — Tombstone pending_review media for this poster's cases
  UPDATE media_objects SET status = 'removed'
  WHERE id IN (
    SELECT media_object_id FROM cases
    WHERE poster_id = p_user_id AND media_object_id IS NOT NULL
      AND state IN ('draft', 'ready')
  ) AND status = 'pending_review'

  -- Also clears cases.media_object_id to NULL for the cancelled cases:
  UPDATE cases SET media_object_id = NULL
  WHERE poster_id = p_user_id AND state = 'cancelled'
    AND cancellation_reason = 'account_deleted'

Step C — Exclude player from all active investigations
  For each row in investigation_members where
    player_id = p_user_id AND eligibility_status = 'eligible'
    AND investigation.status = 'active':

    UPDATE investigation_members
    SET eligibility_status = 'account_deleted',
        snapshot_display_name = '[Deleted]',
        snapshot_avatar_media_object_id = NULL
    WHERE investigation_id = <id> AND player_id = p_user_id

    INSERT INTO exclusion_events
      (investigation_id, case_id, player_id, reason, excluded_by, excluded_at)
    VALUES
      (<id>, <case_id>, p_user_id, 'account_deleted', NULL, clock_timestamp())
    ON CONFLICT DO NOTHING  -- idempotent
```

`mark_auth_deleted_wrapper()` continues to call `private.mark_auth_deleted(p_user_id)` without additional logic. No investigation work.

---

## 18. New Service Functions

### `launch_case(p_actor_id, p_case_id, p_group_ids uuid[], p_duration_seconds integer)`

Validations (in order):
1. Duplicate values in `p_group_ids` → `FK_INVALID_INPUT`
2. `array_length(p_group_ids, 1)` not in 1–10 → `FK_INVALID_INPUT`
3. `p_duration_seconds` not in 3600–86400 or not a multiple of 3600 → `FK_INVALID_INPUT`
4. Actor profile exists, not deletion-pending → `FK_FORBIDDEN`
5. Case exists and `poster_id = p_actor_id` → `FK_NOT_FOUND`
6. Case state is `ready` → `FK_WRONG_STATE`
7. `case_secrets` row exists and all four canonical fields non-null → `FK_WRONG_STATE`
8. `cases.media_object_id IS NOT NULL` and `media_objects.status = 'ready'` → `FK_WRONG_STATE`
9. No active `upload_sessions` (`status IN ('pending','processing','sanitized')`) for this case → `FK_WRONG_STATE`
10. Each group exists, is active, actor is a member → `FK_NOT_FOUND` per invalid group

Writes (atomic):
- `cases.state = 'launched'`, `posted_at = clock_timestamp()`, `deadline_at = clock_timestamp() + p_duration_seconds * interval '1 second'`, `duration_seconds = p_duration_seconds`
- INSERT `investigations` rows per group (V3 triggers handle this; `UNIQUE (case_id, group_id)` prevents duplicates)
- INSERT `investigation_members` rows from current `group_members` for each group (poster excluded); snapshot from `profiles` at execution time

Idempotency: same `(p_case_id, p_group_ids[], p_duration_seconds)` on an already-`launched` case with all matching investigations → return existing rows. Different group set or duration on already-`launched` case → `FK_WRONG_STATE`.

Returns `TABLE (investigation_id uuid, group_id uuid)`.

### `submit_guess(p_player_id, p_case_id, p_race, p_dish_guess, p_restaurant_guess, p_idempotency_key, p_client_submitted_at)`

V1 field structure preserved (`dish_guess`/`restaurant_guess`/`ga_race_fields_check`).

Validations: `p_race IN ('what','where')`; case `launched`; `clock_timestamp() < deadline_at`; player not poster; player appears in at least one `investigation_members` row for this case with `eligibility_status = 'eligible'`.

Returns the `guess_attempts` row (idempotent on same key + same answer; `FK_CONFLICT` on same key + different answer or constraint already satisfied).

### `lock_case(p_case_id uuid)`, `reveal_case(p_case_id uuid)`

Both scheduler-called. `reveal_case()` creates `score_runs` only for investigations where `investigations.status = 'active'`. Cancelled/tombstoned investigations receive no new scoring. Idempotent.

---

## 19. RLS Design

### Active Account Requirement

Every viewer and mutation policy additionally requires:
```sql
AND EXISTS (
  SELECT 1 FROM public.profiles
  WHERE id = auth.uid() AND is_active = true
)
```
This preserves V1's protection: active tokens for inactive accounts cannot access data even before the Auth record is deleted.

### Guess Visibility

| Viewer | Condition | Access |
|---|---|---|
| Author | `player_id = auth.uid()` | Own guess before and after reveal |
| Co-investigator | Case is `revealed` AND viewer and author share at least one `investigation_members` row for this `case_id` AND viewer `eligibility_status = 'eligible'` | See author's guess after reveal |
| Poster | Case is `revealed` AND `cases.poster_id = auth.uid()` | **All guesses** after reveal (V1 behavior, Bill-confirmed) |
| All others | — | No access |

### Poster Access to Investigations

Separate explicit `SELECT` policy: `cases.poster_id = auth.uid()` grants access to `investigations` and `investigation_members` rows for their own cases. Policy gated on `profiles.is_active = true`.

### Cancelled/Tombstoned Investigations

Members retain `SELECT` on their investigation rows and historical Table Talk. `status = 'tombstoned'` hides from active feeds; audit record preserved.

---

## 20. Account Deletion Behavior (Consolidated)

| Phase | Function | Action |
|---|---|---|
| Prepare | `prepare_account_deletion_wrapper()` | Cancel draft/ready cases; tombstone pending media; exclude from active investigations (set `account_deleted`, anonymize snapshot, insert exclusion_events); quiesce upload sessions |
| (Auth deleted out of band) | — | — |
| Mark | `mark_auth_deleted_wrapper()` | `private.mark_auth_deleted()` only — advance deletion state |
| Clean storage | `mark_storage_cleaned_wrapper()` | Mark complete |

Historical `guess_attempts` rows: retained; `player_id` FK preserved.  
Historical committed `score_events` rows: retained.  
`reveal_case()` after deletion: no new `score_events` for `account_deleted` members.

---

## 21. Monthly Scoring Contract

- **Group leaderboard:** per-investigation `score_events` row.
- **Monthly personal/friends:** `max(total_points)` across `current_score_events` for that player and `case_id`. One score per case per player.
- Enforced at query layer. `score_events` has both `case_id` and `investigation_id` to support both joins.

---

## 22. Migration Plan — Dependency-Ordered

`V3__case_investigation_schema.sql`. One `BEGIN`/`COMMIT` block.

```
Phase 1 — Core table rename
  1a. ALTER TABLE public.challenges RENAME TO cases
  1b. Extend state CHECK to include 'ready','launched','retired'
      (keep 'active' temporarily for Phase 13 conversion)
  1c. Remove duplicate inline duration CHECK if present (keep only named cases_duration_check)
  1d. Verify rules_version_id has no DEFAULT in column definition (trigger-managed)

Phase 2 — challenge_secrets → case_secrets
  2a. ALTER TABLE public.challenge_secrets RENAME TO case_secrets
  2b. ALTER TABLE case_secrets RENAME COLUMN challenge_id TO case_id
  2c. Recreate RLS policies, triggers, grants for case_secrets

Phase 3 — Create new tables
  3a. CREATE TABLE public.investigations
  3b. CREATE TABLE public.investigation_members

Phase 4 — Migrate eligible_participants → investigation_members
  4a. INSERT investigations (one per distinct cases.group_id)
  4b. INSERT investigation_members from eligible_participants (snapshot_display_name from profiles)
  4c. DROP public.eligible_participants

Phase 5 — Rename challenge_id on dependent tables
  5a. guess_attempts: RENAME challenge_id → case_id
      ADD idempotency_key (nullable); backfill; SET NOT NULL
      Guard: check for duplicate (case_id, player_id, race) before adding UNIQUE index
      ADD UNIQUE INDEX (case_id, player_id, race)
  5b. exclusion_events: RENAME challenge_id → case_id; ADD investigation_id (nullable); backfill; SET NOT NULL
      DROP old UNIQUE; ADD new UNIQUE (investigation_id, player_id)
      ADD cross-record integrity trigger
  5c. clues: RENAME challenge_id → case_id
  5d. comments: RENAME challenge_id → case_id; ADD investigation_id (nullable); backfill; SET NOT NULL
      ADD cross-record integrity trigger; ON DELETE RESTRICT
  5e. challenge_answer_aliases: RENAME challenge_id → case_id
  5f. correction_events: RENAME challenge_id → case_id; DROP resulting_score_run_id
  5g. score_runs: RENAME challenge_id → case_id; ADD investigation_id (nullable); backfill; SET NOT NULL
      REPLACE UNIQUE (challenge_id, revision_number) → (investigation_id, revision_number)
      ADD cross-record integrity trigger
  5h. guess_judgments: RENAME challenge_id → case_id; ADD investigation_id (nullable); backfill; SET NOT NULL
  5i. score_events: RENAME challenge_id → case_id; ADD investigation_id (nullable); backfill; SET NOT NULL
  5j. reactions: RENAME challenge_id → investigation_id (via case→investigation mapping)

Phase 6 — Rebuild current_score_events VIEW
  6a. DROP VIEW public.current_score_events
  6b. CREATE VIEW public.current_score_events WITH (security_invoker = true) AS [investigation-scoped]
  6c. GRANT SELECT TO authenticated

Phase 7 — Upload sessions
  7a. ALTER TABLE private.upload_sessions RENAME COLUMN challenge_id TO case_id
  7b. DROP INDEX upload_sessions_one_active_per_challenge
  7c. CREATE UNIQUE INDEX upload_sessions_one_active_per_case ... WHERE status IN (...)
  7d. UPDATE storage paths (challenges/ → cases/) in existing rows

Phase 8 — V2 functions: DROP + recreate (named param/name changes)
  8a. DROP FUNCTION public.reserve_upload_session(uuid,uuid,text,text,bigint,timestamptz)
      Recreate as reserve_upload_session(p_case_id uuid, ...)
  8b. DROP FUNCTION public.reveal_challenge_service_wrapper(uuid)
      Recreate as reveal_case_service_wrapper(p_case_id uuid)
  8c. DROP FUNCTION public.get_superseded_media_to_clean()
      Recreate as get_cleanable_media()
  8d. DROP FUNCTION public.mark_superseded_media_cleaned(uuid)
      Recreate as mark_cleanable_media_cleaned(uuid)
  (Restore grants + ownership for all four)

Phase 9 — V2 functions: CREATE OR REPLACE (body changes only)
  9a. finalize_upload_session — update challenges→cases, challenge_id→case_id references
  9b. prepare_account_deletion_wrapper — add V3 investigation exclusion logic

Phase 10 — V2 trigger functions: DROP old, create new
  10a. DROP TRIGGER challenge_v2_no_active_upload_on_activate ON public.cases (was challenges)
       DROP FUNCTION private.check_activation_no_active_upload()
       CREATE FUNCTION private.check_launch_no_active_upload()
       CREATE TRIGGER case_v2_no_active_upload_on_launch ON public.cases
  10b. DROP TRIGGER challenge_v2_media_ready_on_activate
       DROP FUNCTION private.check_activation_media_ready()
       CREATE FUNCTION private.check_launch_media_ready()
       CREATE TRIGGER case_v2_media_ready_on_launch ON public.cases

Phase 11 — V1 functions and triggers updated
  Recreate all V1 functions referencing challenges/challenge_id:
  reveal_challenge_service → reveal_case_service, lock_challenge → lock_case,
  post_challenge → launch_case_internal, cancel_challenge → cancel_case, etc.
  Update state machine references (active → launched)

Phase 12 — RLS policies
  Rewrite all policies:
  - Add profiles.is_active = true requirement to every policy
  - Apply guess visibility rules (§19)
  - Poster explicit SELECT policy for investigations/investigation_members
  - Cancelled/tombstoned investigation visibility

Phase 13 — State value conversion (active → launched)
  13a. TEMPORARILY DISABLE case_protect_fields trigger:
       ALTER TABLE public.cases DISABLE TRIGGER case_protect_fields;
  13b. UPDATE public.cases SET state = 'launched' WHERE state = 'active';
  13c. ALTER TABLE public.cases ENABLE TRIGGER case_protect_fields;
  13d. ALTER TABLE public.cases DROP CONSTRAINT cases_state_check;
       ALTER TABLE public.cases ADD CONSTRAINT cases_state_check
         CHECK (state IN ('draft','ready','launched','locked','revealed','retired','cancelled'));
       -- 'active' now excluded from valid values

Phase 14 — Drop group_id from cases
  14a. Verify: zero functions/triggers/policies still reference cases.group_id
       (pg_depend audit + manual review)
  14b. DROP CONSTRAINT cases_group_id_fk
  14c. ALTER TABLE public.cases DROP COLUMN group_id

Phase 15 — New service functions
  launch_case, submit_guess, lock_case, reveal_case,
  approve_case_media, reject_case_media

Phase 16 — Grants, ownership, completion marker
```

---

## 23. Acceptance Criteria

### 23.1 Schema
- All V1 tables present with renamed columns; no approved tables dropped without replacement.
- `cases` has all V1 `challenges` fields; `rules_version_id` has no column DEFAULT; `duration_seconds NOT NULL DEFAULT 7200`; single named `cases_duration_check` constraint (no duplicate inline CHECK).
- `case_secrets` in `public` schema with RLS; `challenge_secrets` does not exist.
- `investigations` and `investigation_members` exist with correct constraints.
- `investigations` has `UNIQUE (case_id, group_id)` and no `idempotency_key` column.
- `investigation_members.snapshot_avatar_media_object_id` has FK `REFERENCES public.media_objects(id) ON DELETE SET NULL`.
- `score_runs`, `guess_judgments`, `score_events` have `investigation_id NOT NULL`.
- `current_score_events` is a VIEW with `security_invoker = true`.
- `correction_events.resulting_score_run_id` does not exist.
- `exclusion_events` has `investigation_id NOT NULL` and `UNIQUE (investigation_id, player_id)`.
- `reactions` references `investigation_id`; no comment FK.
- `comments` has `investigation_id NOT NULL`.
- `guess_attempts` has `idempotency_key uuid NOT NULL` and `UNIQUE (case_id, player_id, race)`.
- `private.upload_sessions.case_id` exists; `challenge_id` does not.
- `cases.group_id` does not exist.
- Storage paths in `upload_sessions`: `cases/` prefix, not `challenges/`.
- `get_cleanable_media()` exists; `get_superseded_media_to_clean()` does not.
- `mark_cleanable_media_cleaned()` exists; `mark_superseded_media_cleaned()` does not.
- `reveal_case_service_wrapper(uuid)` exists; `reveal_challenge_service_wrapper(uuid)` does not.
- `reserve_upload_session(p_case_id uuid, ...)` exists; `p_challenge_id` parameter does not.

### 23.2 Case State Machine
- `draft → ready` via `approve_case_media()` with `pending_review` media → `cases.state = 'ready'`, media `ready`.
- `ready → launched` via `launch_case()` → `posted_at` set, `deadline_at = posted_at + duration_seconds * interval '1 second'`.
- Direct `UPDATE cases SET state = 'launched'` by `authenticated` → blocked by trigger.
- `state = 'active'` does not exist in any row after migration.
- `CHECK` constraint rejects `'active'`.

### 23.3 Duration
- 3600, 7200, 86400 accepted; 3601, 0, 90000 rejected.
- Duration change after launch → blocked.

### 23.4 Media Moderation
- `approve_case_media()` with `pending_review` media → `ready`; case → `ready`.
- `reject_case_media()` with `pending_review` media → `media_objects.status = 'removed'`; `cases.media_object_id = NULL`; case stays `draft`.
- `get_cleanable_media()` returns rows for both `superseded` and `removed` media.
- `mark_cleanable_media_cleaned()` sets status to `cleaned` for both; idempotent.
- Poster may initiate a new upload session after rejection.

### 23.5 Investigation Members
- At launch: one row per eligible group member per investigation; poster excluded.
- `snapshot_avatar_media_object_id` NULLed on account deletion (Step C of prepare).
- Media deletion NULLs `snapshot_avatar_media_object_id` via FK cascade (`ON DELETE SET NULL`).

### 23.6 Guess Attempts
- `what` and `where` each satisfy uniqueness independently.
- Idempotent retry (same key + answer) → existing row returned.
- Conflicting retry → `FK_CONFLICT`.
- Submit after `locked` → `FK_WRONG_STATE`.
- Poster submits → `FK_FORBIDDEN`.
- Non-member submits → `FK_FORBIDDEN`.

### 23.7 Exclusions Investigation-Scoped
- Exclude in Investigation A → not excluded from Investigation B for same case.
- Account deletion → one exclusion_events row per active investigation.
- `UNIQUE (investigation_id, player_id)` enforced.

### 23.8 Scoring
- `reveal_case()` only creates `score_runs` for `investigations.status = 'active'`.
- Cancelled investigation receives no new `score_runs` after reveal.
- After reveal: every eligible `investigation_members` row has a `score_events` row.
- `account_deleted` members: excluded; no `score_events` row at reveal.
- Correction on case with one cancelled + one active investigation → only active investigation rescored.

### 23.9 RLS Active Account Requirement
- `authenticated` user with `profiles.is_active = false` cannot SELECT from `cases`, `investigations`, `guess_attempts`, or any other protected table, even with a valid JWT.
- Poster with `is_active = false` cannot SELECT from `investigations` for their own cases.

### 23.10 Poster Guess Visibility (V1 Behavior)
- After reveal: poster can SELECT all `guess_attempts` rows for their case.
- Before reveal: poster cannot SELECT any `guess_attempts`.
- Non-member non-poster cannot SELECT `guess_attempts` even after reveal.

### 23.11 `launch_case()` Validations
- Duplicate group IDs → `FK_INVALID_INPUT`.
- Empty / >10 groups → `FK_INVALID_INPUT`.
- Invalid duration → `FK_INVALID_INPUT`.
- Actor not poster → `FK_NOT_FOUND`.
- Case not `ready` → `FK_WRONG_STATE`.
- Incomplete case_secrets → `FK_WRONG_STATE`.
- Media not approved → `FK_WRONG_STATE`.
- Active upload session → `FK_WRONG_STATE`.
- Actor not member of group → `FK_NOT_FOUND`.
- Idempotent resubmit → existing rows returned.

### 23.12 Account Deletion Orchestration
- `prepare_account_deletion_wrapper()`: draft/ready cases cancelled; pending_review media set to `removed`; investigation_members rows set to `account_deleted`; exclusion_events inserted; quiesce sessions.
- `mark_auth_deleted_wrapper()`: advances deletion state only; does NOT modify investigations or cases.
- Historical `guess_attempts` and `score_events` retained.

### 23.13 V2 Unchanged Functions Pass Existing Tests
- All 21 unchanged V2 functions (§14.2) still pass their existing acceptance test groups after migration — no body changes means no behavior changes.
- Updated V2 acceptance tests (§14.4) pass for renamed columns and functions.
- `get_cleanable_media()` covers all cases previously covered by `get_superseded_media_to_clean()`.

---

## 24. Out of Scope for Step 26

- Push notification dispatch.
- Feed / discovery query design.
- Global / monthly leaderboard tables (contract documented in §21).
- Admin moderation UI.
- Edge Function implementations.
- `case_secrets` → `private` schema (separate security decision).
- Orders To Go (backlog FEAT-001).
- Retired state archival logic.
- Per-comment reaction system.

---

*Ready for review by Bill, Claude, and Codex. No migration code written until all three parties approve.*
