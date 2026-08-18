# Step 26 Proposal — Case / Investigation Schema
**Revision:** 8  
**Status:** DRAFT — awaiting approval from Bill, Claude, and Codex before any code is written  
**Prerequisites:** Step 25 merged (`v0.2.0-upload-sessions`); Step 24.1 merged as `V3__ugc_safety_moderation.sql` and tagged before this migration runs  
**Supersedes:** Rev 7 (rejected — GPT review, 6 blockers)

---

## Changes From Rev 7

| Blocker | Fix |
|---|---|
| 1 | Revealed guess visibility now requires viewer and author to share at least one investigation for the case — not just `is_case_member`. New RLS policy with investigation-sharing JOIN. Cross-Table isolation test added. |
| 2 | `cancel_case()` — poster ONLY; cancels case + all active investigations. New `cancel_investigation()` — poster OR owner of that specific Table's group; cancels one investigation only. When all investigations become cancelled the case remains in its current state; `reveal_case()` scores nothing and still transitions the case to `revealed`. |
| 3 | `submit_guess()` adds `is_suspended = false` guard and bilateral block check with poster. Deadline uses `>=`. Idempotency and state checks reordered: look up existing attempt first; same key + identical payload → return (even after deadline/state change); same key + different race/answer → FK_CONFLICT; different key + existing (case_id, player_id, race) → FK_CONFLICT. State/deadline/block checks only reached if no existing attempt found. |
| 4 | `launch_case()` authorization choice recorded: require `p_actor_id = private.auth_uid()` inside the function. Grant EXECUTE to `authenticated`. Revoke from `service_role`. Forged-actor test added to acceptance criteria. |
| 5 | Phase 7 corrected: `UPDATE upload_sessions SET original_storage_path = replace(original_storage_path, 'challenges/', 'cases/'), display_storage_path = replace(display_storage_path, 'challenges/', 'cases/')`. Phase 1 corrected: after `ALTER TABLE challenges RENAME TO cases`, explicitly `DROP CONSTRAINT challenges_state_check` and `ADD CONSTRAINT cases_state_check` (temporary, includes `'active'`); Phase 15 drops and recreates the final constraint. |
| 6 | `get_media_serve_authorization` exact body: `challenges → cases`, `can_viewer_access_challenge → can_viewer_access_case`. `get_moderation_queue` return: `challenge_id uuid → case_id uuid`. Persisted target type `'challenge'` migrated to `'case'` in all data rows, CHECK constraints, functions, and tests. State matrices for `ready`, `launched`, `retired` defined. |

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
| Own-guess always visible | No state restriction. Bill approved 2026-08-08. |
| Step 24.1 prerequisite | `V3__ugc_safety_moderation.sql` must be tagged before V4 runs |
| `challenge_answer_aliases` final name | `case_answer_aliases` |
| `launch_case()` auth | `p_actor_id = private.auth_uid()` enforced inside function. EXECUTE to `authenticated` only. |
| Moderation target type | `'challenge'` migrated to `'case'` across all data, constraints, and functions |

---

## 3. `public.cases` — Exact Column Set

```sql
CREATE TABLE public.cases (
  id                   uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  -- group_id: kept through Phase 13; DROPPED in Phase 17
  poster_id            uuid        NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  media_object_id      uuid        REFERENCES public.media_objects(id) ON DELETE RESTRICT,
  state                text        NOT NULL DEFAULT 'draft',
                                   -- No inline CHECK on this column; only the named constraint.
  duration_seconds     integer     NOT NULL DEFAULT 7200,
  public_city_display  text,
  rules_version_id     uuid        NOT NULL
                                   DEFAULT 'a0000000-0000-0000-0000-000000000001'
                                   REFERENCES public.rules_versions(id) ON DELETE RESTRICT,
  posted_at            timestamptz,
  deadline_at          timestamptz,
  locked_at            timestamptz,
  revealed_at          timestamptz,
  cancelled_at         timestamptz,
  cancellation_reason  text,
  created_at           timestamptz NOT NULL DEFAULT clock_timestamp(),

  CONSTRAINT cases_state_check
    CHECK (state IN ('draft','ready','launched','locked','revealed','retired','cancelled')),
  CONSTRAINT cases_duration_check
    CHECK (duration_seconds BETWEEN 3600 AND 86400 AND duration_seconds % 3600 = 0),
  CONSTRAINT cases_cancellation_check
    CHECK (cancellation_reason IS NULL OR length(cancellation_reason) <= 500),
  CONSTRAINT cases_city_display_check
    CHECK (public_city_display IS NULL OR length(trim(public_city_display)) BETWEEN 1 AND 100)
);

CREATE UNIQUE INDEX one_active_case_per_poster
  ON public.cases (poster_id)
  WHERE state IN ('draft','ready','launched','locked');
```

---

## 4. `public.case_secrets` (renamed from `challenge_secrets`)

`challenge_id → case_id`. All V1 structure, constraints, trigger names, RLS logic preserved. Updated to reference `cases`.

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

Valid statuses: `active`, `cancelled`, `tombstoned`. No `locked` status on investigations — deadline and locking are tracked on `cases.state`. When all investigations for a case are cancelled, the case remains in its current state; `reveal_case()` will score no investigations but still transitions `cases.state → 'revealed'`.

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
                                            'eligible','excluded','account_deleted'
                                          )),
  added_at                          timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY (investigation_id, player_id)
);
```

Snapshot at `launch_case()`: `is_active=true AND onboarding_complete=true AND is_suspended=false`, no bilateral block with poster.

---

## 7. `public.exclusion_events` — Investigation-Scoped

```sql
-- V3 changes from V1:
--   challenge_id  →  investigation_id uuid NOT NULL FK → investigations
--   case_id uuid NOT NULL FK → cases
--   UNIQUE (investigation_id, player_id)
--   reason CHECK: 'withdrew' | 'removed' | 'account_deleted'
```

State gate per reason (`enforce_exclusion_rules` trigger):
- `withdrew` / `removed`: `investigations.status = 'active' AND cases.state = 'launched'`
- `account_deleted`: `investigations.status = 'active' AND cases.state IN ('launched','locked')` (trusted executor path)

---

## 8. `public.guess_attempts`

```sql
-- V1 columns preserved: id, case_id, player_id, race, dish_guess, restaurant_guess,
--   received_at, receipt_sequence, client_submitted_at,
--   UNIQUE (case_id, receipt_sequence), ga_race_check, ga_race_fields_check
-- V3 additions:
--   idempotency_key uuid NOT NULL
--   UNIQUE (case_id, player_id, race)
-- Migration: idempotency_key nullable → backfill gen_random_uuid() → NOT NULL
```

---

## 9. Scoring Tables

### `score_runs`
`challenge_id → case_id`. `investigation_id uuid NOT NULL` (nullable → backfill → NOT NULL). `UNIQUE (investigation_id, revision_number)`. Cross-record integrity trigger.

### `correction_events`
`challenge_id → case_id`. `resulting_score_run_id` DROPPED.

### `guess_judgments`
`challenge_id → case_id`. `investigation_id uuid NOT NULL` added.

### `score_events`
`challenge_id → case_id`. `investigation_id uuid NOT NULL` added.

### `current_score_events` VIEW
```sql
DROP VIEW IF EXISTS public.current_score_events;
CREATE VIEW public.current_score_events
  WITH (security_invoker = true) AS
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
`challenge_id → case_id`. `investigation_id uuid NOT NULL` (nullable → backfill → NOT NULL). Cross-record integrity trigger. Step 24.1 moderation columns preserved.

### `reactions`
Investigation-scoped. Migration: add `investigation_id` nullable → backfill → NOT NULL → drop `challenge_id` → add FK → replace UNIQUE index. See Phase 5j.

---

## 11. `public.clues` and `public.case_answer_aliases`

`challenge_id → case_id`. `challenge_answer_aliases` renamed to `case_answer_aliases`. All V1 structure and Step 24.1 moderation columns preserved.

---

## 12. `private.upload_sessions`

`challenge_id → case_id`. FK → `public.cases(id)`. Index renamed `upload_sessions_one_active_per_case`. Storage path columns updated:
```sql
UPDATE private.upload_sessions
SET original_storage_path = replace(original_storage_path, 'challenges/', 'cases/'),
    display_storage_path  = replace(display_storage_path,  'challenges/', 'cases/');
```

---

## 13. Media Moderation — Step 24.1 Contract Extensions

**`approve_photo()` V4 addition:**
```sql
UPDATE public.cases SET state='ready'
WHERE media_object_id = p_media_object_id AND state='draft';
```

**`reject_photo()` V4 addition:**
```sql
UPDATE public.cases SET media_object_id=NULL
WHERE media_object_id = p_media_object_id AND state='draft';
```

### Moderation State Matrix

| Case state | Photo reportable | Clues/comments reportable | Removal actions allowed |
|---|---|---|---|
| `draft` | No (not yet visible to others) | N/A | Moderator may act on internal review |
| `ready` | Photo visible to moderators only; moderation queue entry exists | N/A | Moderator may reject photo |
| `launched` | Yes | Yes | Yes — same as V1 `active` |
| `locked` | Yes | Yes | Yes |
| `revealed` | Yes | Yes | Yes |
| `retired` | Yes (archived; still visible) | Yes | Yes |
| `cancelled` | No new reports (case removed from display) | No | No (content gone) |

### Moderation target type: `'challenge' → 'case'`

Step 24.1 stores `target_type = 'challenge'` in `content_reports` and `moderation_actions` CHECK constraints. V4 migrates this:

```sql
-- 1. Add 'case' to CHECK constraints (temporary, allows both)
ALTER TABLE public.content_reports DROP CONSTRAINT cr_target_type_check;
ALTER TABLE public.content_reports ADD CONSTRAINT cr_target_type_check
  CHECK (target_type IN ('case','comment','clue','profile','media_object'));

ALTER TABLE public.moderation_actions DROP CONSTRAINT ma_target_type_check;
ALTER TABLE public.moderation_actions ADD CONSTRAINT ma_target_type_check
  CHECK (target_type IS NULL OR
         target_type IN ('case','comment','clue','profile','media_object'));

-- 2. Migrate existing rows
UPDATE public.content_reports    SET target_type='case' WHERE target_type='challenge';
UPDATE public.moderation_actions SET target_type='case' WHERE target_type='challenge';
```

All functions that filter `target_type = 'challenge'` updated to `'case'`: `report_content`, `remove_content`, `remove_media`, `action_report`, `get_moderation_queue`, `get_reported_media`, `get_pending_review_media`. V3 `report_content` acceptance tests updated to use `'case'` as the target_type for case-level reports.

### `get_media_serve_authorization` — exact V4 body

```sql
CREATE OR REPLACE FUNCTION public.get_media_serve_authorization(
  p_media_object_id uuid,
  p_viewer_id       uuid
) RETURNS TABLE(re_encoded_storage_key text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT msk.re_encoded_storage_key
  FROM public.media_objects mo
  JOIN public.cases c ON c.media_object_id = mo.id          -- challenges → cases
  JOIN private.media_storage_keys msk ON msk.media_object_id = mo.id
  WHERE mo.id = p_media_object_id
    AND mo.status = 'ready'
    AND c.moderator_removed_at IS NULL
    AND private.can_viewer_access_case(c.id, p_viewer_id);  -- can_viewer_access_challenge → can_viewer_access_case
$$;
```

Signature unchanged: `(p_media_object_id uuid, p_viewer_id uuid)`. Grants unchanged: EXECUTE to `service_role` only.

### `get_moderation_queue` — return contract V4

```
public.get_moderation_queue()
→ TABLE(queue_type text, item_id uuid, created_at timestamptz,
        target_type text, target_id uuid, category text, case_id uuid)
```

`challenge_id uuid` column renamed to `case_id uuid` in the function body and return type. The `target_type` values in the returned rows will be `'case'` post-migration. EXECUTE to `service_role` only; signature (no args) unchanged.

### `get_pending_review_media` / `get_reported_media` — return contracts V4

Both return `case_id uuid` instead of `challenge_id uuid`. Function bodies updated to join on `cases`.

---

## 14. V2 Function Impact

### Functions requiring body changes

| Function | Method |
|---|---|
| `reserve_upload_session(p_challenge_id, ...)` | DROP + recreate as `(p_case_id, ...)`; storage path; restore grants |
| `finalize_upload_session(uuid, text)` | CREATE OR REPLACE; `challenge_id → case_id` |
| `reveal_challenge_service_wrapper(p_challenge_id uuid)` | DROP + recreate as `reveal_case_service_wrapper(p_case_id uuid)` |
| `prepare_account_deletion_wrapper(p_user_id uuid)` | CREATE OR REPLACE; V4 additions |

### Functions with no body changes (verified from V2 source)
`activate_upload_session`, `resolve_upload_session`, `advance_upload_session_processing`, `check_upload_session_lease`, `advance_upload_session_sanitized`, `fail_upload_session`, `quiesce_upload_sessions_for_deletion`, `get_upload_capability_expiry`, `get_all_upload_session_paths_for_deletion`, `claim_cleanup_sessions`, `mark_session_cleaned`, `mark_original_path_post_expiry_cleaned`, `get_complete_sessions_pending_expiry_cleanup`, `get_superseded_media_to_clean`, `mark_superseded_media_cleaned`, `get_media_storage_key`, `get_deletion_storage_keys`, `record_deletion_failure_wrapper`, `mark_auth_deleted_wrapper`, `mark_storage_cleaned_wrapper`, `claim_deletion_recovery_records`, `complete_deletion_recovery`, `fail_deletion_recovery`

### V2 trigger functions
- `private.check_activation_no_active_upload()` → `private.check_launch_no_active_upload()`
- `private.check_activation_media_ready()` → `private.check_launch_media_ready()`

---

## 15. Complete V1 + Step 24.1 Object Inventory

### RLS Helper Functions (owned by `forkensics_rls_helper`)

| Function | V4 action |
|---|---|
| `private.auth_uid()` | No change |
| `private.normalize_answer(text)` | No change |
| `private.is_group_member(uuid)`, `private.is_group_member_with(uuid)` | No change |
| `private.is_challenge_group_member(uuid)` | DROP. Replaced by `is_case_member` + `is_investigation_member` |
| `private.is_challenge_poster(uuid)` | DROP + recreate as `private.is_case_poster(case_id uuid)` |
| `private.is_challenge_revealed(uuid)` | DROP + recreate as `private.is_case_revealed(case_id uuid)` |
| `private.is_eligible_non_excluded(uuid)` | DROP + recreate as `private.is_investigation_eligible(investigation_id uuid)` |
| `private.caller_has_guessed(uuid)` | CREATE OR REPLACE; `challenge_id → case_id` |

**New helpers:**

```sql
-- Case-level: viewer is in any investigation for this case.
CREATE OR REPLACE FUNCTION private.is_case_member(p_case_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.investigations i
    JOIN public.investigation_members im ON im.investigation_id = i.investigation_id
    WHERE i.case_id = p_case_id AND im.player_id = private.auth_uid()
  );
$$;

-- Investigation-level: viewer is in this specific investigation.
CREATE OR REPLACE FUNCTION private.is_investigation_member(p_investigation_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.investigation_members
    WHERE investigation_id = p_investigation_id AND player_id = private.auth_uid()
  );
$$;
```

### Operational Functions (owned by `forkensics_executor`) — V1 source

| Function | V4 action |
|---|---|
| Group functions (5) | No change |
| `public.activate_challenge(uuid)` | DROPPED |
| `public.lock_challenge(uuid)` | DROP + recreate as `public.lock_case(uuid)` — see §17 |
| `public.reveal_challenge(uuid)` | DROP + recreate as `public.reveal_case(uuid)` — see §17 |
| `public.cancel_challenge(uuid, text)` | DROP + recreate as `public.cancel_case(uuid, text)` — see §17 |
| `public.apply_correction(...)` | CREATE OR REPLACE; `challenge_id → case_id`; per-investigation scoring |
| `public.soft_delete_comment(uuid)` | CREATE OR REPLACE; trigger `comment_update_guard` updated separately |
| `private.do_reveal_impl(uuid)` | DROP + recreate as `private.do_reveal_impl_v3(p_case_id, p_investigation_id)` — see §17 |
| `private.reveal_challenge_service(uuid)` | DROP + recreate as `private.reveal_case_service(uuid)` — see §17 |
| `private.prepare_account_deletion(uuid)` | Full rebuild — see §16 |
| `private.get_storage_keys_for_deletion(uuid)` | CREATE OR REPLACE; verify upload_sessions join |
| `private.mark_auth_deleted(uuid)` | CREATE OR REPLACE; verify clean |
| `private.mark_storage_cleaned(uuid)` | CREATE OR REPLACE; verify clean |
| `private.record_deletion_failure(uuid, text)` | CREATE OR REPLACE; verify clean |

### Functions — Step 24.1 source

| Function | V4 action |
|---|---|
| `private.can_view_challenge(uuid)` | DROP + recreate as `private.can_view_case(uuid)` |
| `private.can_viewer_access_challenge(uuid, uuid)` | DROP + recreate as `private.can_viewer_access_case(uuid, uuid)` |
| `private.has_block_with_poster(uuid)` | CREATE OR REPLACE; `challenges → cases` |
| `public.approve_photo(uuid, uuid, text)` | CREATE OR REPLACE; V4 case-state extension (§13) |
| `public.reject_photo(uuid, uuid, text)` | CREATE OR REPLACE; V4 case-state extension (§13) |
| `public.claim_moderation_media_cleanup(int)` | CREATE OR REPLACE; `challenges → cases` |
| `public.get_media_serve_authorization(uuid, uuid)` | CREATE OR REPLACE; exact body per §13 |
| `public.get_moderation_queue()` | CREATE OR REPLACE; `challenge_id → case_id` in return; `'challenge' → 'case'` in target_type filter |
| `public.get_pending_review_media(uuid)` | CREATE OR REPLACE; `challenge_id → case_id` in return |
| `public.get_reported_media(uuid)` | CREATE OR REPLACE; `challenge_id → case_id` in return |
| `public.report_content(text, uuid, text, text)` | CREATE OR REPLACE; `target_type 'challenge' → 'case'`; `challenges → cases` |
| `public.remove_content(text, uuid, uuid, uuid, text)` | CREATE OR REPLACE; `'challenge' → 'case'`; `challenges → cases` |
| `public.remove_media(uuid, uuid, uuid, text)` | CREATE OR REPLACE; `challenges → cases` |

### Triggers requiring changes

| Trigger name | Function name | V4 action |
|---|---|---|
| `challenge_create_fields` | `public.set_challenge_create_fields()` | DROP + recreate as `case_create_fields` / `set_case_create_fields()` on `cases` |
| `challenge_protect_fields` | `public.protect_challenge_authority_fields()` | DROP + recreate as `case_protect_fields` / `protect_case_authority_fields()` on `cases`; DISABLE during Phase 15 |
| `challenge_secrets_guard` | `public.guard_answer_edits()` | Recreate on `case_secrets`; `case_id` ref |
| `challenge_secrets_timestamps` | `public.set_challenge_secret_timestamps()` | Recreate on `case_secrets` as `set_case_secret_timestamps()` |
| `alias_guard_insert`, `alias_guard_update` | `public.guard_alias_edits()` | CREATE OR REPLACE; `case_secrets.case_id`; recreate on `case_answer_aliases` |
| `guess_receipt` | `public.set_guess_receipt_fields()` | CREATE OR REPLACE; `'active' → 'launched'` |
| `guess_judgment_consistency` | `public.check_judgment_consistency()` | CREATE OR REPLACE; `challenge_id → case_id`; add `investigation_id` |
| `score_event_consistency` | `public.check_score_event_consistency()` | CREATE OR REPLACE; `investigation_members` |
| `exclusion_enforce` | `public.enforce_exclusion_rules()` | CREATE OR REPLACE; per §7 |
| `clues_timestamp` etc | `public.set_append_only_timestamps()` | No change |
| `comment_update_guard` | `public.restrict_comment_updates()` | CREATE OR REPLACE; `challenge_id → case_id`; Step 24.1 additions preserved |
| Step 24.1 triggers on `challenges` | `force_removal_fields_null`, `restrict_moderation_field_updates` | Recreate on `cases` |
| `check_text_content_trigger` | (Step 24.1) | Recreate on `cases` if attached to any `challenges` column |
| V2 activation triggers | See §14 | DROP + recreate on `cases` |

### Indexes

Constraint drops use verified catalog names. UNIQUE constraint drops: `ALTER TABLE ... DROP CONSTRAINT <name>` — not `DROP INDEX`.

| V1/V2 | V4 replacement |
|---|---|
| `one_active_challenge_per_poster` | `one_active_case_per_poster` WHERE `state IN ('draft','ready','launched','locked')` |
| `idx_challenges_group_id` | Dropped Phase 17 |
| `idx_challenges_state` | Renamed `idx_cases_state` |
| `idx_guess_attempts_challenge` | Recreated ON `(case_id, race, receipt_sequence)` |
| `idx_guess_attempts_player` | Recreated ON `(player_id, case_id)` |
| `idx_score_events_challenge` | Recreated ON `(case_id)` |
| `idx_eligible_challenge` | Dropped |
| `idx_exclusion_challenge` | Recreated ON `(investigation_id)` |
| `idx_clues_challenge` | Recreated ON `(case_id)` |
| `idx_comments_challenge` | Recreated ON `(case_id, posted_at)` |
| `idx_reactions_challenge` | Recreated ON `(investigation_id)` |
| `idx_aliases_challenge` | Recreated ON `(case_id, field) WHERE is_active` |
| `idx_aliases_active_unique` | Recreated ON `(case_id, field, normalized_value) WHERE is_active` |
| `idx_correction_challenge` | Recreated ON `(case_id)` |
| `one_qualifying_per_player_race` | Updated predicate |
| `upload_sessions_one_active_per_challenge` | Renamed `upload_sessions_one_active_per_case` |

### RLS Policies

| Table | Helper |
|---|---|
| `cases`, `case_secrets`, `clues`, `case_answer_aliases`, `correction_events` | `private.is_case_member(case_id)`, `private.is_case_poster(case_id)`, `private.is_case_revealed(case_id)` |
| `guess_attempts` | Own: `player_id = auth_uid()`. Poster: `is_case_poster`. Revealed: investigation-sharing JOIN (see §19). |
| `investigation_members`, `exclusion_events`, `comments`, `reactions`, `score_runs`, `guess_judgments`, `score_events` | `private.is_investigation_member(investigation_id)` |

`profiles.is_active` check everywhere. Grants: `cases`, `investigation_members` to `forkensics_rls_helper`.

---

## 16. Account Deletion — `private.prepare_account_deletion()` Full Rebuild

```
Forward-only guard (database_prepared / auth_deleted / complete → RETURN).
Reset pending/failed to 'pending'.

Step 1 — Cancel draft/ready cases
  UPDATE cases SET state='cancelled', cancelled_at=clock_timestamp(),
    cancellation_reason='Account deleted'
  WHERE poster_id=p_profile_id AND state IN ('draft','ready');

Step 2 — Exclude from active investigations
  FOR each investigation_members row where player_id=p_profile_id,
    eligibility_status='eligible', investigations.status='active',
    cases.state IN ('launched','locked'):
    UPDATE investigation_members SET eligibility_status='account_deleted';
    INSERT INTO exclusion_events ON CONFLICT DO NOTHING;

Step 3 — Transfer or archive owned groups
  FOR each group where owner and not archived:
    Find longest-tenured member where is_active=true AND onboarding_complete=true
      AND is_suspended=false AND player_id != p_profile_id ORDER BY joined_at ASC;
    IF found: demote deleting player to 'member'; promote successor to 'owner';
    ELSE: archive the group.

Step 4 — Archive profile identity
  INSERT INTO private.profile_archive ON CONFLICT DO NOTHING;

Step 5 — Anonymize profile row
  UPDATE profiles SET display_name='Former Player', avatar_color='gray',
    avatar_media_object_id=NULL, is_active=false;

Step 6 — Anonymize ALL investigation_members snapshot fields
  UPDATE investigation_members SET snapshot_display_name='[Deleted]',
    snapshot_avatar_media_object_id=NULL WHERE player_id=p_profile_id;

Step 7 — Tombstone all media objects
  UPDATE media_objects SET status='deleted' WHERE uploader_id=p_profile_id;

Step 8 — Mark DB step complete (only on success of all prior steps)
  UPDATE deletion_log SET status='database_prepared', db_prepared_at=clock_timestamp();
```

---

## 17. Service Function Contracts

### `public.lock_case(p_case_id uuid)` — service-role scheduler only

```
SELECT * FROM cases WHERE id=p_case_id FOR UPDATE;
IF NOT FOUND → EXCEPTION 'case not found';
IF clock_timestamp() < v_case.deadline_at → EXCEPTION 'deadline has not been reached';
  -- Uses cases.state column throughout; no 'status' column.
IF v_case.state != 'launched' → EXCEPTION 'lock requires launched state (current: %)';
UPDATE cases SET state='locked', locked_at=clock_timestamp() WHERE id=p_case_id;
```

EXECUTE to `service_role` only. Revoked from `authenticated`.

---

### `public.reveal_case(p_case_id uuid)` — authenticated poster

```
SELECT * FROM cases WHERE id=p_case_id FOR UPDATE;
IF auth_uid() IS NULL → EXCEPTION ERRCODE 42501;
IF profile not active → EXCEPTION;
IF poster_id != auth_uid() → EXCEPTION;
IF clock_timestamp() < deadline_at → EXCEPTION 'deadline has not been reached';
IF state NOT IN ('launched','locked') → EXCEPTION;

FOR v_inv IN (SELECT * FROM investigations WHERE case_id=p_case_id AND status='active') LOOP
  PERFORM private.do_reveal_impl_v3(p_case_id, v_inv.investigation_id);
END LOOP;
-- do_reveal_impl_v3 does NOT update cases.state

UPDATE cases SET state='revealed', revealed_at=clock_timestamp() WHERE id=p_case_id;
```

---

### `private.reveal_case_service(p_case_id uuid)` — service scheduler

```
SELECT * FROM cases WHERE id=p_case_id FOR UPDATE;
IF state != 'locked' → EXCEPTION 'service reveal requires locked state (current: %)';

FOR v_inv IN (SELECT * FROM investigations WHERE case_id=p_case_id AND status='active') LOOP
  PERFORM private.do_reveal_impl_v3(p_case_id, v_inv.investigation_id);
END LOOP;

UPDATE cases SET state='revealed', revealed_at=clock_timestamp() WHERE id=p_case_id;
```

EXECUTE to `service_role` only. Revoked from `authenticated`.

---

### `private.do_reveal_impl_v3(p_case_id uuid, p_investigation_id uuid)`

Shared scoring engine. Caller holds FOR UPDATE on cases; this function does NOT update `cases.state`.

```
-- Read case (plain SELECT; caller holds lock)
-- Read case_secrets; pre-normalize canonical answers
-- Count eligible investigation_members (eligibility_status='eligible') in p_investigation_id
-- INSERT score_run (revision = MAX for this investigation + 1, or 1 if none)
-- FOR each guess_attempt for this case, WHERE player is investigation_member
--   with eligibility_status='eligible' in p_investigation_id,
--   ordered by receipt_sequence:
--   Judge attempt; update tmp_first_correct; INSERT guess_judgment
-- Compute ordinal ranks; INSERT score_events for all eligible members
-- DROP temp table
-- No UPDATE to cases table.
```

---

### `public.cancel_case(p_case_id uuid, p_reason text)` — poster ONLY

```
IF profile not active → EXCEPTION;
SELECT * FROM cases WHERE id=p_case_id FOR UPDATE;
IF poster_id != auth_uid() → EXCEPTION 'only the poster can cancel a case';
  -- Group owners do NOT have authority over the case itself.
IF state NOT IN ('draft','ready','launched') → EXCEPTION 'cannot cancel in state %';

UPDATE cases SET state='cancelled', cancelled_at=clock_timestamp(),
  cancellation_reason=p_reason WHERE id=p_case_id;
UPDATE investigations SET status='cancelled', cancelled_at=clock_timestamp(),
  cancellation_reason='Case cancelled' WHERE case_id=p_case_id AND status='active';
```

---

### `public.cancel_investigation(p_investigation_id uuid, p_reason text)` — poster or Table owner

```
IF profile not active → EXCEPTION;
SELECT i.*, c.poster_id FROM investigations i JOIN cases c ON c.id=i.case_id
  WHERE i.investigation_id=p_investigation_id FOR UPDATE;
IF NOT FOUND → EXCEPTION;

IF v_case.poster_id != auth_uid() AND NOT EXISTS (
  SELECT 1 FROM group_members WHERE group_id=v_inv.group_id
    AND player_id=auth_uid() AND role='owner'
) → EXCEPTION 'only the poster or the Table owner can cancel this investigation';

IF v_inv.status != 'active' → EXCEPTION 'investigation is not active (current: %)';

UPDATE investigations SET status='cancelled', cancelled_at=clock_timestamp(),
  cancellation_reason=p_reason WHERE investigation_id=p_investigation_id;

-- Note: cases.state is NOT changed. When all investigations are cancelled,
-- the case continues in its current state. reveal_case() will score no investigations
-- but still transitions cases.state → 'revealed'.
```

EXECUTE to `authenticated`. Revoked from `service_role`.

---

### `public.submit_guess(p_case_id uuid, p_investigation_id uuid, p_race text, p_guess text, p_idempotency_key uuid, p_client_submitted_at timestamptz)` — detective

**Validation order — idempotency lookup BEFORE state/deadline checks:**

```
Step 1 — Actor authorization
  IF auth_uid() IS NULL → EXCEPTION ERRCODE 42501;
  IF NOT EXISTS (profiles WHERE id=auth_uid() AND is_active=true
                 AND onboarding_complete=true AND is_suspended=false)
    → EXCEPTION 'account not eligible to submit';

Step 2 — Race validation (no DB read needed)
  IF p_race NOT IN ('what','where') → EXCEPTION 'invalid race';

Step 3 — Idempotency lookup (BEFORE state/deadline check)
  v_existing := SELECT * FROM guess_attempts
    WHERE case_id=p_case_id AND player_id=auth_uid() AND idempotency_key=p_idempotency_key;

  IF v_existing.id IS NOT NULL THEN
    -- Same key found; verify payload matches
    IF v_existing.race != p_race
       OR coalesce(v_existing.dish_guess,'') != coalesce(p_guess,'')    -- for 'what'
       OR coalesce(v_existing.restaurant_guess,'') != coalesce(p_guess,'')  -- for 'where'
    THEN
      RAISE EXCEPTION 'FK_CONFLICT: idempotency key reused with different payload';
    END IF;
    RETURN v_existing;  -- Idempotent replay; skip all further checks
  END IF;

  -- Check for any existing attempt for this player + race (different key)
  IF EXISTS (SELECT 1 FROM guess_attempts
             WHERE case_id=p_case_id AND player_id=auth_uid() AND race=p_race)
  THEN RAISE EXCEPTION 'FK_CONFLICT: a guess for this race already exists'; END IF;

Step 4 — Case state and deadline
  SELECT state, deadline_at, poster_id FROM cases WHERE id=p_case_id;
  IF NOT FOUND → EXCEPTION 'case not found';
  IF v_case.state != 'launched' → EXCEPTION 'case is not accepting guesses (state: %)';
  IF clock_timestamp() >= v_case.deadline_at → EXCEPTION 'deadline has passed';
    -- >= matches the set_guess_receipt_fields trigger check

Step 5 — Investigation membership and eligibility
  IF NOT EXISTS (
    SELECT 1 FROM investigation_members
    WHERE investigation_id=p_investigation_id AND player_id=auth_uid()
      AND eligibility_status='eligible'
  ) → EXCEPTION 'caller is not eligible in this investigation';

  IF NOT EXISTS (
    SELECT 1 FROM investigations
    WHERE investigation_id=p_investigation_id AND case_id=p_case_id AND status='active'
  ) → EXCEPTION 'investigation not active for this case';

Step 6 — Bilateral block check with poster (post-launch blocks must prevent guesses)
  IF EXISTS (
    SELECT 1 FROM user_blocks
    WHERE (blocker_id=auth_uid() AND blocked_id=v_case.poster_id)
       OR (blocker_id=v_case.poster_id AND blocked_id=auth_uid())
  ) → EXCEPTION 'FK_FORBIDDEN: blocked user cannot submit guesses';

Step 7 — INSERT
  INSERT INTO guess_attempts (..., idempotency_key, ...);
  -- Trigger set_guess_receipt_fields fires; assigns receipt_sequence
```

---

## 18. `launch_case()` — Full Contract

```
launch_case(
  p_actor_id         uuid,
  p_case_id          uuid,
  p_group_ids        uuid[],
  p_duration_seconds integer
)
RETURNS TABLE (investigation_id uuid, group_id uuid)
SECURITY DEFINER SET search_path = ''
```

**Authorization choice (recorded):** `p_actor_id = private.auth_uid()` enforced inside the function. EXECUTE granted to `authenticated`. Revoked from `service_role`. The Edge Function supplies the verified JWT subject as `p_actor_id`; the function validates it matches `private.auth_uid()`.

**Validation order:**

```
v_now := clock_timestamp();

Step 1 — Authorization match (first DB-free check)
  IF p_actor_id IS DISTINCT FROM private.auth_uid()
    → RAISE 'FK_FORBIDDEN: p_actor_id does not match authenticated identity';

Step 2 — Input shape
  a. Duplicate values in p_group_ids → RAISE 'FK_INVALID_INPUT'
  b. array_length(p_group_ids, 1) not in 1–10 → RAISE 'FK_INVALID_INPUT'
  c. p_duration_seconds not in 3600–86400 or not % 3600 → RAISE 'FK_INVALID_INPUT'

Step 3 — Actor authorization
  a. profiles: is_active=true, onboarding_complete=true, is_suspended=false → else RAISE 'FK_FORBIDDEN'
  b. deletion_log: status IN ('pending','database_prepared','auth_deleted','failed')
     → RAISE 'FK_FORBIDDEN' (no record or 'complete' = safe)

Step 4 — Lock case and validate ownership
  SELECT id, poster_id, state, posted_at, deadline_at, duration_seconds
  FROM cases WHERE id=p_case_id FOR UPDATE;
  IF NOT FOUND OR poster_id != p_actor_id → RAISE 'FK_NOT_FOUND'

Step 5 — Idempotency (only after ownership confirmed)
  IF v_case.state = 'launched' THEN
    existing_groups := SELECT group_id FROM investigations
                       WHERE case_id=p_case_id ORDER BY group_id;
    IF existing_groups = sort(p_group_ids)
       AND EXTRACT(EPOCH FROM (v_case.deadline_at - v_case.posted_at)) = p_duration_seconds
    THEN RETURN QUERY SELECT investigation_id, group_id FROM investigations WHERE case_id=p_case_id;
         RETURN;
    ELSE RAISE 'FK_WRONG_STATE: case already launched with different parameters'; END IF;
  END IF;

Step 6 — Require ready
  IF v_case.state != 'ready' → RAISE 'FK_WRONG_STATE'

Step 7 — Validate case_secrets
  canonical and display fields for dish + restaurant: NOT NULL and non-empty

Step 8 — Validate media
  media_object_id IS NOT NULL AND media_objects.status='ready'

Step 9 — No active upload sessions

Step 10 — Per-group validation
  Group exists, not archived; p_actor_id is a member
```

**Writes:** same as Rev 7. `investigation_members` snapshot: `is_active=true, onboarding_complete=true, is_suspended=false`, no bilateral block with poster.

---

## 19. RLS — Guess Visibility

### Own-guess — always visible
```sql
CREATE POLICY guess_own_view ON public.guess_attempts AS PERMISSIVE FOR SELECT
USING (
  player_id = private.auth_uid()
  AND EXISTS (SELECT 1 FROM public.profiles WHERE id=private.auth_uid() AND is_active=true)
);
-- No state restriction. Bill approved 2026-08-08.
```

### Poster visibility — launched/locked/revealed
```sql
CREATE POLICY guess_poster_view ON public.guess_attempts AS PERMISSIVE FOR SELECT
USING (
  private.is_case_poster(case_id)
  AND EXISTS (SELECT 1 FROM public.cases WHERE id=guess_attempts.case_id
              AND state IN ('launched','locked','revealed'))
  AND EXISTS (SELECT 1 FROM public.profiles WHERE id=private.auth_uid() AND is_active=true)
);
```

### Co-investigator revealed visibility — shared investigation required
```sql
-- Viewer and author must share at least one investigation for this case.
-- This prevents Table A seeing Table B-only guesses, even when a player
-- belongs to multiple Tables for the same case.
CREATE POLICY guess_investigation_revealed_view ON public.guess_attempts AS PERMISSIVE FOR SELECT
USING (
  private.is_case_revealed(case_id)
  AND EXISTS (
    SELECT 1
    FROM public.investigation_members v_im
    JOIN public.investigation_members a_im
      ON a_im.investigation_id = v_im.investigation_id
    JOIN public.investigations i ON i.investigation_id = v_im.investigation_id
    WHERE v_im.player_id = private.auth_uid()
      AND a_im.player_id = guess_attempts.player_id
      AND i.case_id = guess_attempts.case_id
  )
  AND EXISTS (SELECT 1 FROM public.profiles WHERE id=private.auth_uid() AND is_active=true)
);
```

---

## 20. Scoring — Active Investigations Only

`reveal_case()` and `reveal_case_service()` score only `status='active'` investigations. `cancel_investigation()` does not trigger scoring. `apply_correction()` skips non-active investigations.

---

## 21. Migration Plan — Dependency-Ordered

`V4__case_investigation_schema.sql`. One `BEGIN`/`COMMIT`.

```
Phase 0 — Prerequisite guard
  DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.tables
      WHERE table_schema='private' AND table_name='moderators')
    THEN RAISE EXCEPTION 'V4 failed: apply V3 (UGC Safety) first'; END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.tables
      WHERE table_schema='public' AND table_name='content_reports')
    THEN RAISE EXCEPTION 'V4 failed: apply V3 (UGC Safety) first'; END IF;
  END $$;

Phase 1 — Rename challenges → cases
  1a. ALTER TABLE public.challenges RENAME TO cases
  1b. -- PostgreSQL keeps constraint name 'challenges_state_check' after table rename.
      -- Must explicitly drop and replace:
      ALTER TABLE public.cases DROP CONSTRAINT challenges_state_check;
      ALTER TABLE public.cases ADD CONSTRAINT cases_state_check
        CHECK (state IN ('draft','active','ready','launched','locked','revealed','retired','cancelled'));
      -- Temporary: includes 'active' through Phase 15.
  1c. Verify rules_version_id DEFAULT = 'a0000000-0000-0000-0000-000000000001'
  1d. Verify created_at DEFAULT = clock_timestamp()
  1e. Verify media_object_id FK ON DELETE RESTRICT

Phase 2 — challenge_secrets → case_secrets
  2a. RENAME TABLE; RENAME COLUMN challenge_id → case_id
  2b. Recreate triggers, RLS policies, grants

Phase 3 — Migrate moderation target type
  3a. ALTER TABLE public.content_reports DROP CONSTRAINT cr_target_type_check;
      ALTER TABLE public.content_reports ADD CONSTRAINT cr_target_type_check
        CHECK (target_type IN ('case','comment','clue','profile','media_object'));
  3b. ALTER TABLE public.moderation_actions DROP CONSTRAINT ma_target_type_check;
      ALTER TABLE public.moderation_actions ADD CONSTRAINT ma_target_type_check
        CHECK (target_type IS NULL OR
               target_type IN ('case','comment','clue','profile','media_object'));
  3c. UPDATE public.content_reports    SET target_type='case' WHERE target_type='challenge';
  3d. UPDATE public.moderation_actions SET target_type='case' WHERE target_type='challenge';

Phase 4 — Create new tables
  4a. CREATE TABLE investigations
  4b. CREATE TABLE investigation_members

Phase 5 — Migrate eligible_participants → investigation_members
  5a. INSERT investigations (one per cases row, using cases.group_id)
  5b. INSERT investigation_members from eligible_participants
  5c. DROP TABLE public.eligible_participants

Phase 6 — Rename challenge_id on dependent tables
  6a. guess_attempts: RENAME → case_id; ADD idempotency_key nullable→backfill→NOT NULL;
      ADD UNIQUE (case_id, player_id, race)
  6b. exclusion_events: RENAME → case_id; ADD investigation_id nullable→backfill→NOT NULL;
      DROP CONSTRAINT (catalog name); ADD UNIQUE (investigation_id, player_id);
      ADD cross-record integrity trigger
  6c. clues: RENAME → case_id
  6d. comments: RENAME → case_id; ADD investigation_id nullable→backfill→NOT NULL;
      ADD cross-record integrity trigger
  6e. challenge_answer_aliases → case_answer_aliases: RENAME TABLE; RENAME COLUMN → case_id
  6f. correction_events: RENAME → case_id; DROP resulting_score_run_id
  6g. score_runs: RENAME → case_id; ADD investigation_id nullable→backfill→NOT NULL;
      DROP CONSTRAINT (catalog name); ADD UNIQUE (investigation_id, revision_number);
      ADD cross-record integrity trigger
  6h. guess_judgments: RENAME → case_id; ADD investigation_id nullable→backfill→NOT NULL
  6i. score_events: RENAME → case_id; ADD investigation_id nullable→backfill→NOT NULL
  6j. reactions: ADD investigation_id nullable; backfill via investigations.case_id;
      RAISE EXCEPTION if any NULL remains; NOT NULL;
      DROP challenge_id FK (DROP CONSTRAINT by catalog name); DROP challenge_id column;
      ADD investigation_id FK; DROP old UNIQUE (by catalog name);
      CREATE UNIQUE (investigation_id, player_id, emoji)

Phase 7 — current_score_events VIEW
  DROP + CREATE WITH (security_invoker=true); GRANT SELECT TO authenticated

Phase 8 — Upload sessions
  8a. RENAME COLUMN challenge_id → case_id; update FK
  8b. DROP INDEX upload_sessions_one_active_per_challenge
  8c. CREATE UNIQUE INDEX upload_sessions_one_active_per_case
  8d. UPDATE private.upload_sessions
      SET original_storage_path = replace(original_storage_path, 'challenges/', 'cases/'),
          display_storage_path  = replace(display_storage_path,  'challenges/', 'cases/');
      -- Both columns updated separately; no 'storage_path' column exists.

Phase 9 — RLS helper rebuilds
  is_challenge_group_member: DROP
  is_case_member: CREATE
  is_investigation_member: CREATE
  is_case_poster: DROP old + CREATE (from is_challenge_poster)
  is_case_revealed: DROP old + CREATE (from is_challenge_revealed)
  is_investigation_eligible: DROP old + CREATE (from is_eligible_non_excluded)
  caller_has_guessed: CREATE OR REPLACE

Phase 10 — Operational function rebuilds
  private.prepare_account_deletion: full rebuild per §16
  private.mark_auth_deleted, mark_storage_cleaned, record_deletion_failure: CREATE OR REPLACE
  private.get_storage_keys_for_deletion: CREATE OR REPLACE
  private.do_reveal_impl_v3: DROP do_reveal_impl + CREATE do_reveal_impl_v3
  private.reveal_case_service: DROP reveal_challenge_service + CREATE reveal_case_service
  public.lock_case: DROP lock_challenge + CREATE lock_case
  public.reveal_case: DROP reveal_challenge + CREATE reveal_case
  public.cancel_case: DROP cancel_challenge + CREATE cancel_case
  public.cancel_investigation: CREATE (new function)
  public.apply_correction: CREATE OR REPLACE
  public.soft_delete_comment: CREATE OR REPLACE
  DROP public.activate_challenge

Phase 11 — Step 24.1 function updates
  approve_photo, reject_photo: CREATE OR REPLACE with V4 extensions
  claim_moderation_media_cleanup, get_media_serve_authorization: CREATE OR REPLACE per §13
  get_moderation_queue, get_pending_review_media, get_reported_media: CREATE OR REPLACE per §13
  report_content, remove_content, remove_media: CREATE OR REPLACE ('challenge'→'case')
  private.can_view_case: DROP can_view_challenge + CREATE
  private.can_viewer_access_case: DROP can_viewer_access_challenge + CREATE
  private.has_block_with_poster: CREATE OR REPLACE

Phase 12 — V2 function updates
  reserve_upload_session: DROP + recreate as (p_case_id, ...)
  finalize_upload_session: CREATE OR REPLACE
  reveal_case_service_wrapper: DROP + recreate
  prepare_account_deletion_wrapper: CREATE OR REPLACE

Phase 13 — Trigger rebuilds (see §15)
  Drop old triggers; recreate all on cases/case_secrets/case_answer_aliases
  -- Note: challenge_create_fields (not challenge_insert_defaults)
  -- V2 triggers: check_launch_no_active_upload, check_launch_media_ready

Phase 14 — Index rebuilds (see §15)
  DROP old; CREATE new case/investigation-named replacements

Phase 15 — RLS policies (see §15 + §19)
  Drop and recreate all; cross-Table isolation for guess visibility (§19)

Phase 16 — State conversion: active → launched
  16a. DISABLE TRIGGER case_protect_fields ON public.cases
  16b. UPDATE public.cases SET state='launched' WHERE state='active'
  16c. ENABLE TRIGGER case_protect_fields ON public.cases
  16d. ALTER TABLE cases DROP CONSTRAINT cases_state_check;
       ALTER TABLE cases ADD CONSTRAINT cases_state_check
         CHECK (state IN ('draft','ready','launched','locked','revealed','retired','cancelled'));
       -- Final constraint; 'active' excluded.

Phase 17 — Partial index update
  DROP INDEX one_active_challenge_per_poster;
  CREATE UNIQUE INDEX one_active_case_per_poster ON cases (poster_id)
    WHERE state IN ('draft','ready','launched','locked');

Phase 18 — Remove group_id from cases
  18a. pg_depend audit
  18b. ALTER TABLE cases DROP CONSTRAINT challenges_group_id_fkey;
       -- PG does not rename constraints on table rename; name preserved from V1.
  18c. DROP INDEX idx_challenges_group_id
  18d. ALTER TABLE cases DROP COLUMN group_id

Phase 19 — New service functions (launch_case and submit_guess only)
  launch_case per §18 — lock_case and reveal_case were rebuilt in Phase 10
  submit_guess per §17

Phase 20 — Grants, ownership, completion marker
  GRANT SELECT ON cases TO forkensics_rls_helper
  GRANT SELECT ON investigation_members TO forkensics_rls_helper
  GRANT UPDATE (...) ON cases TO forkensics_executor
  GRANT INSERT, UPDATE, DELETE ON investigations TO forkensics_executor
  GRANT INSERT, UPDATE ON investigation_members TO forkensics_executor
  All new/renamed function OWNER TO forkensics_executor
  REVOKE temporary build-time privileges
  INSERT schema_migrations marker
```

---

## 22. Acceptance Criteria (Summary — Key Items)

**Schema:**
- No `challenge_id` in any listed table; no inline state CHECK on column; `one_active_case_per_poster` predicate correct; `cases_state_check` constraint name correct (not `challenges_state_check`) post-migration; `'active'` rejected by final constraint

**Moderation:**
- `content_reports.target_type` and `moderation_actions.target_type`: no `'challenge'` rows post-migration; CHECK constraint no longer accepts `'challenge'`
- `get_media_serve_authorization`: returns key when viewer has case access; empty for non-member; `can_viewer_access_case` called (not `can_viewer_access_challenge`)
- `get_moderation_queue`: returns `case_id` column; target_type = `'case'` for case reports
- `approve_photo()`: case `draft → ready`; `reject_photo()`: `media_object_id` cleared

**Core functions:**
- `lock_case`: rejects before deadline_at; rejects non-`launched` state; uses `cases.state`
- `reveal_case` poster: deadline enforced; all active investigations scored; case → `revealed` after loop
- `do_reveal_impl_v3`: does NOT update `cases.state`
- `cancel_case`: poster only; cancels case + all active investigations; rejected for `locked`/`revealed`
- `cancel_investigation`: poster OR Table owner of that specific group; cancels one investigation; case state unchanged
- All-investigations-cancelled: case stays in current state; reveal scores nothing; case still → `revealed`

**`launch_case()`:**
- `p_actor_id != auth_uid()` → `FK_FORBIDDEN` (forged-actor test)
- Auth validated before idempotency; non-poster fails at Step 4 (ownership check), before Step 5
- Idempotency: same poster + same params → return existing; different params → `FK_WRONG_STATE`
- Deletion guard: `status IN ('pending','database_prepared','auth_deleted','failed')` → rejected

**`submit_guess()`:**
- Suspended caller → rejected
- Bilateral block with poster → rejected (even post-launch block)
- `clock_timestamp() >= deadline_at` → rejected
- Same key + identical payload → existing row returned (even after state transition or deadline)
- Same key + different race/answer → `FK_CONFLICT`
- Different key + existing race attempt → `FK_CONFLICT`
- Idempotency check before state/deadline check

**RLS cross-Table isolation:**
- Member of Table A cannot see Table B-only guesses at reveal — tested
- Member of Table A cannot read Table B's comments, reactions, members, or scores — tested
- Poster sees all guesses during launched/locked/revealed
- Own-guess always visible including after cancellation

**Account deletion:**
- Suspended member skipped in group successor query (tested: suspended skipped → next eligible OR archive)
- `database_prepared` set only after all 8 steps succeed

**Upload sessions:**
- `original_storage_path` and `display_storage_path` both updated to `cases/`; no `storage_path` column touched

**V2:**
- All 21 unchanged V2 functions pass existing test groups after migration

---

## 23. Out of Scope

Push notifications, feed queries, monthly leaderboard tables, admin UI, Edge Function implementations, `case_secrets → private` schema, Orders To Go (FEAT-001), retired-state archival, per-comment reactions.

---

*Ready for review by Bill, Claude, and Codex. No migration code written until all three parties approve.*
