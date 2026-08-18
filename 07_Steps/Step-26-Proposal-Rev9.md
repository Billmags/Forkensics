# Step 26 Proposal — Case / Investigation Schema
**Revision:** 9  
**Status:** DRAFT — awaiting approval from Bill, Claude, and Codex before any code is written  
**Prerequisites:** Step 25 merged (`v0.2.0-upload-sessions`); Step 24.1 merged as `V3__ugc_safety_moderation.sql` and tagged before this migration runs  
**Supersedes:** Rev 8 (rejected — GPT review, 6 blockers)

---

## Changes From Rev 8

| Blocker | Fix |
|---|---|
| 1 | Phase 3 constraint migration order corrected: (a) DROP old constraint, (b) ADD temporary constraint allowing both `'challenge'` and `'case'`, (c) UPDATE existing rows to `'case'`, (d) DROP temporary constraint, (e) ADD final constraint allowing `'case'` only. Applied to both `content_reports` and `moderation_actions`. |
| 2 | `submit_guess()` idempotency comparison branched by race: for `'what'` compare only `dish_guess`; for `'where'` compare only `restaurant_guess`. Unrelated answer column is NULL and not compared. |
| 3 | Added `UNIQUE (case_id, player_id, idempotency_key)` to `guess_attempts`. Lookup is now unambiguous (one key = one player = one row for that case). Concurrent identical submissions catch the unique violation, reload the stored row, then return it if race+payload match or raise `FK_CONFLICT` if not. Two-session concurrency test added to acceptance criteria. |
| 4 | `cancel_investigation()` restricted to `cases.state = 'launched'` only — prevents cancelling after reveal. Suspended callers (poster or group owner) are rejected. |
| 5 | `prepare_account_deletion()` Step 2 updated: ALL `eligibility_status = 'eligible'` investigation_members rows for the deleted player are set to `'account_deleted'` regardless of case state. Exclusion events are created only for investigations where the state rules permit (`investigations.status = 'active' AND cases.state IN ('launched','locked')`). Test added: `apply_correction()` on a revealed case cannot award points to a deleted player. |
| 6 | Revealed-guess policy: viewer must have `eligibility_status = 'eligible'` in the shared investigation. `report_content()` for `target_type='case'`: new reports rejected when case is `cancelled`; existing pending reports remain accessible and actionable via `get_moderation_queue`, `action_report`, `dismiss_report`, `remove_content`, `remove_media` regardless of case state. |

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
| Moderation target type | `'challenge'` migrated to `'case'` via two-step constraint replace |
| New reports on cancelled cases | Rejected. Existing pending reports remain actionable. |

---

## 3. `public.cases` — Exact Column Set

```sql
CREATE TABLE public.cases (
  id                   uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  -- group_id: kept through Phase 13; DROPPED in Phase 18
  poster_id            uuid        NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  media_object_id      uuid        REFERENCES public.media_objects(id) ON DELETE RESTRICT,
  state                text        NOT NULL DEFAULT 'draft',
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

`challenge_id → case_id`. All V1 structure, constraints, trigger names, and RLS logic preserved.

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

Valid statuses: `active`, `cancelled`, `tombstoned`. No `locked` status — deadline tracked on `cases.state`. When all investigations are cancelled, the case remains in its current state; `reveal_case()` scores nothing and still transitions `cases.state → 'revealed'`.

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
  snapshot_avatar_media_object_id   uuid  REFERENCES public.media_objects(id) ON DELETE SET NULL,
  eligibility_status                text  NOT NULL DEFAULT 'eligible'
                                          CHECK (eligibility_status IN (
                                            'eligible','excluded','account_deleted'
                                          )),
  added_at                          timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY (investigation_id, player_id)
);
```

---

## 7. `public.exclusion_events` — Investigation-Scoped

```sql
-- V4 changes: challenge_id → investigation_id + case_id; UNIQUE (investigation_id, player_id)
-- reason CHECK: 'withdrew' | 'removed' | 'account_deleted'
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
-- V4 additions:
--   idempotency_key    uuid NOT NULL
--   UNIQUE (case_id, player_id, race)          -- one locked attempt per player per race
--   UNIQUE (case_id, player_id, idempotency_key) -- prevents key reuse across races;
--                                                   makes concurrent lookup unambiguous
-- Migration: idempotency_key nullable → backfill gen_random_uuid() → NOT NULL
--            Both UNIQUE indexes added after backfill.
```

The `UNIQUE (case_id, player_id, idempotency_key)` constraint means a player cannot reuse the same idempotency key for both 'what' and 'where' races in the same case. Each guess submission must carry a fresh key.

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
Investigation-scoped. Migration: add `investigation_id` nullable → backfill → NOT NULL → drop `challenge_id` → add FK → replace UNIQUE index. See Phase 6j.

---

## 11. `public.clues` and `public.case_answer_aliases`

`challenge_id → case_id`. `challenge_answer_aliases` renamed to `case_answer_aliases`. All V1 structure and Step 24.1 moderation columns preserved.

---

## 12. `private.upload_sessions`

`challenge_id → case_id`. FK → `public.cases(id)`. Index renamed `upload_sessions_one_active_per_case`.

```sql
UPDATE private.upload_sessions
SET original_storage_path = replace(original_storage_path, 'challenges/', 'cases/'),
    display_storage_path  = replace(display_storage_path,  'challenges/', 'cases/');
-- Both columns updated separately. No 'storage_path' column exists.
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

| Case state | New reports accepted | Existing pending reports | Removal actions |
|---|---|---|---|
| `draft` | No (not visible to members) | N/A | Moderator may act on photo review |
| `ready` | Photo in moderation queue; no member-initiated reports | Actionable | Moderator may reject photo |
| `launched` | Yes — all content types | Actionable | Yes |
| `locked` | Yes | Actionable | Yes |
| `revealed` | Yes | Actionable | Yes |
| `retired` | Yes | Actionable | Yes |
| `cancelled` | **No** — `report_content()` rejects new reports for `target_type='case'` | **Still actionable** — `get_moderation_queue`, `action_report`, `dismiss_report`, `remove_content`, `remove_media` work regardless of case state. Step 24.1 explicitly preserves moderation and evidence handling post-cancellation. | Still executable |

### `report_content()` — cancelled case guard (V4 addition)

When `target_type='case'`, after locking the case row:
```sql
IF v_case.state = 'cancelled' THEN
  RAISE EXCEPTION 'FK_INVALID_INPUT: cannot report a cancelled case';
END IF;
```
Pending reports created before cancellation remain in the queue and are fully actionable.

### Moderation target type: two-step constraint migration

See Phase 3 in §21 for the exact DDL sequence. After V4, `target_type IN ('case','comment','clue','profile','media_object')` — no `'challenge'` value.

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
  JOIN public.cases c ON c.media_object_id = mo.id
  JOIN private.media_storage_keys msk ON msk.media_object_id = mo.id
  WHERE mo.id = p_media_object_id
    AND mo.status = 'ready'
    AND c.moderator_removed_at IS NULL
    AND private.can_viewer_access_case(c.id, p_viewer_id);
$$;
```

Signature: `(p_media_object_id uuid, p_viewer_id uuid)`. EXECUTE to `service_role` only.

### `get_moderation_queue` — return contract V4

```
public.get_moderation_queue()
→ TABLE(queue_type text, item_id uuid, created_at timestamptz,
        target_type text, target_id uuid, category text, case_id uuid)
```

`challenge_id → case_id` in return column name and body. `target_type` values in rows will be `'case'` post-migration. EXECUTE to `service_role` only.

### `get_pending_review_media` / `get_reported_media` return V4

Both return `case_id uuid` instead of `challenge_id uuid`. Bodies updated to join on `cases`.

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
| `private.auth_uid()`, `private.normalize_answer(text)`, `private.is_group_member(uuid)`, `private.is_group_member_with(uuid)` | No change |
| `private.is_challenge_group_member(uuid)` | DROP. Replaced by `is_case_member` + `is_investigation_member` |
| `private.is_challenge_poster(uuid)` | DROP + recreate as `private.is_case_poster(case_id uuid)` |
| `private.is_challenge_revealed(uuid)` | DROP + recreate as `private.is_case_revealed(case_id uuid)` |
| `private.is_eligible_non_excluded(uuid)` | DROP + recreate as `private.is_investigation_eligible(investigation_id uuid)` |
| `private.caller_has_guessed(uuid)` | CREATE OR REPLACE; `challenge_id → case_id` |

**New helpers:**
```sql
CREATE OR REPLACE FUNCTION private.is_case_member(p_case_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.investigations i
    JOIN public.investigation_members im ON im.investigation_id = i.investigation_id
    WHERE i.case_id = p_case_id AND im.player_id = private.auth_uid()
  );
$$;

CREATE OR REPLACE FUNCTION private.is_investigation_member(p_investigation_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.investigation_members
    WHERE investigation_id = p_investigation_id AND player_id = private.auth_uid()
  );
$$;
```

### Operational Functions — V1 source (owned by `forkensics_executor`)

| Function | V4 action |
|---|---|
| Group functions (5) | No change |
| `public.activate_challenge(uuid)` | DROPPED |
| `public.lock_challenge(uuid)` | DROP + recreate as `public.lock_case(uuid)` — §17 |
| `public.reveal_challenge(uuid)` | DROP + recreate as `public.reveal_case(uuid)` — §17 |
| `public.cancel_challenge(uuid, text)` | DROP + recreate as `public.cancel_case(uuid, text)` — §17 |
| `public.apply_correction(...)` | CREATE OR REPLACE; `challenge_id → case_id`; per-investigation scoring |
| `public.soft_delete_comment(uuid)` | CREATE OR REPLACE; trigger updated separately |
| `private.do_reveal_impl(uuid)` | DROP + recreate as `private.do_reveal_impl_v3(p_case_id, p_investigation_id)` — §17 |
| `private.reveal_challenge_service(uuid)` | DROP + recreate as `private.reveal_case_service(uuid)` — §17 |
| `private.prepare_account_deletion(uuid)` | Full rebuild — §16 |
| `private.get_storage_keys_for_deletion(uuid)` | CREATE OR REPLACE; verify upload_sessions join |
| `private.mark_auth_deleted(uuid)`, `private.mark_storage_cleaned(uuid)`, `private.record_deletion_failure(uuid, text)` | CREATE OR REPLACE; verify clean |

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
| `public.get_moderation_queue()` | CREATE OR REPLACE; `challenge_id → case_id`; `'challenge' → 'case'` filter |
| `public.get_pending_review_media(uuid)` | CREATE OR REPLACE; `challenge_id → case_id` |
| `public.get_reported_media(uuid)` | CREATE OR REPLACE; `challenge_id → case_id` |
| `public.report_content(text, uuid, text, text)` | CREATE OR REPLACE; `'challenge' → 'case'`; cancelled-case guard (§13) |
| `public.remove_content(text, uuid, uuid, uuid, text)` | CREATE OR REPLACE; `'challenge' → 'case'` |
| `public.remove_media(uuid, uuid, uuid, text)` | CREATE OR REPLACE; `challenges → cases` |

### Triggers

| Trigger name | Function name | V4 action |
|---|---|---|
| `challenge_create_fields` | `public.set_challenge_create_fields()` | DROP + recreate as `case_create_fields` / `set_case_create_fields()` on `cases` |
| `challenge_protect_fields` | `public.protect_challenge_authority_fields()` | DROP + recreate as `case_protect_fields` / `protect_case_authority_fields()` on `cases`; DISABLE during Phase 16 |
| `challenge_secrets_guard` | `public.guard_answer_edits()` | Recreate on `case_secrets`; `case_id` ref |
| `challenge_secrets_timestamps` | `public.set_challenge_secret_timestamps()` | Recreate on `case_secrets`; renamed `set_case_secret_timestamps()` |
| `alias_guard_insert`, `alias_guard_update` | `public.guard_alias_edits()` | CREATE OR REPLACE; recreate on `case_answer_aliases` |
| `guess_receipt` | `public.set_guess_receipt_fields()` | CREATE OR REPLACE; `'active' → 'launched'` |
| `guess_judgment_consistency` | `public.check_judgment_consistency()` | CREATE OR REPLACE; `challenge_id → case_id`; add `investigation_id` |
| `score_event_consistency` | `public.check_score_event_consistency()` | CREATE OR REPLACE; `investigation_members` |
| `exclusion_enforce` | `public.enforce_exclusion_rules()` | CREATE OR REPLACE; state gates per §7 |
| `clues_timestamp` etc. | `public.set_append_only_timestamps()` | No change |
| `comment_update_guard` | `public.restrict_comment_updates()` | CREATE OR REPLACE; `challenge_id → case_id`; Step 24.1 additions preserved |
| Step 24.1 triggers on `challenges` | `force_removal_fields_null`, `restrict_moderation_field_updates` | Recreate on `cases` |
| `check_text_content_trigger` | (Step 24.1) | Recreate on `cases` if attached to any `challenges` column |
| V2 activation triggers | See §14 | DROP + recreate on `cases` |

### Indexes
UNIQUE constraint drops use verified catalog names.

| V1/V2 | V4 replacement |
|---|---|
| `one_active_challenge_per_poster` | `one_active_case_per_poster` WHERE `state IN ('draft','ready','launched','locked')` |
| `idx_challenges_group_id` | Dropped Phase 18 |
| `idx_challenges_state` | `idx_cases_state` |
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
| `upload_sessions_one_active_per_challenge` | `upload_sessions_one_active_per_case` |

### RLS Policies

| Table | Helper |
|---|---|
| `cases`, `case_secrets`, `clues`, `case_answer_aliases`, `correction_events` | `private.is_case_member`, `private.is_case_poster`, `private.is_case_revealed` |
| `guess_attempts` | Own: `player_id = auth_uid()`. Poster: `is_case_poster`. Revealed: investigation-sharing JOIN with eligibility check (§19). |
| `investigation_members`, `exclusion_events`, `comments`, `reactions`, `score_runs`, `guess_judgments`, `score_events` | `private.is_investigation_member(investigation_id)` |

`profiles.is_active` check on every policy.

---

## 16. Account Deletion — `private.prepare_account_deletion()` Full Rebuild

```
Forward-only guard → reset pending/failed to 'pending'.

Step 1 — Cancel draft/ready cases
  UPDATE cases SET state='cancelled', cancelled_at=clock_timestamp(),
    cancellation_reason='Account deleted'
  WHERE poster_id=p_profile_id AND state IN ('draft','ready');

Step 2 — Exclude eligible investigation_members (all case states)
  -- Set eligibility_status='account_deleted' for ALL remaining 'eligible' rows,
  -- regardless of case state (including revealed). This prevents apply_correction()
  -- from awarding points to a deleted player.

  FOR each row WHERE investigation_members.player_id=p_profile_id
    AND eligibility_status='eligible':

    UPDATE investigation_members
      SET eligibility_status='account_deleted'
      WHERE investigation_id=v_im.investigation_id AND player_id=p_profile_id;

    -- Create exclusion_event only where state rules permit the record
    IF investigations.status='active'
       AND cases.state IN ('launched','locked') THEN
      INSERT INTO exclusion_events (investigation_id, case_id, player_id, reason, excluded_by)
        VALUES (v_im.investigation_id, v_im.case_id, p_profile_id, 'account_deleted', NULL)
        ON CONFLICT (investigation_id, player_id) DO NOTHING;
    END IF;

Step 3 — Transfer or archive owned groups
  FOR each group where gm.player_id=p_profile_id, role='owner', not archived:
    Find longest-tenured: is_active=true, onboarding_complete=true, is_suspended=false,
      player_id != p_profile_id ORDER BY joined_at ASC;
    IF found: demote deleting player → 'member'; promote successor → 'owner';
    ELSE: archive the group;

Step 4 — Archive profile identity
  INSERT INTO private.profile_archive ON CONFLICT DO NOTHING;

Step 5 — Anonymize profile row
  UPDATE profiles SET display_name='Former Player', avatar_color='gray',
    avatar_media_object_id=NULL, is_active=false;

Step 6 — Anonymize ALL investigation_members snapshot fields
  UPDATE investigation_members SET snapshot_display_name='[Deleted]',
    snapshot_avatar_media_object_id=NULL WHERE player_id=p_profile_id;
  -- eligibility_status not changed here; Step 2 already handled it.

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
IF NOT FOUND → EXCEPTION;
IF clock_timestamp() < deadline_at → EXCEPTION 'deadline has not been reached';
IF v_case.state != 'launched' → EXCEPTION 'lock requires launched state (current: %)';
  -- Uses cases.state column; no 'status' column on cases.
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
IF clock_timestamp() < deadline_at → EXCEPTION;
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
IF state != 'locked' → EXCEPTION;

FOR v_inv IN (SELECT * FROM investigations WHERE case_id=p_case_id AND status='active') LOOP
  PERFORM private.do_reveal_impl_v3(p_case_id, v_inv.investigation_id);
END LOOP;

UPDATE cases SET state='revealed', revealed_at=clock_timestamp() WHERE id=p_case_id;
```

EXECUTE to `service_role` only.

---

### `private.do_reveal_impl_v3(p_case_id uuid, p_investigation_id uuid)`

Caller holds FOR UPDATE on cases. Does NOT update `cases.state`.

Scores only players with `eligibility_status = 'eligible'` in the specified investigation. Deleted players (set to `'account_deleted'` in Step 2 of deletion) are excluded from scoring automatically.

---

### `public.cancel_case(p_case_id uuid, p_reason text)` — poster ONLY

```
IF profile not active → EXCEPTION;
SELECT * FROM cases WHERE id=p_case_id FOR UPDATE;
IF poster_id != auth_uid() → EXCEPTION 'only the poster can cancel a case';
  -- Group owners do NOT have authority over the case itself.
IF state NOT IN ('draft','ready','launched') → EXCEPTION;

UPDATE cases SET state='cancelled', cancelled_at=clock_timestamp(),
  cancellation_reason=p_reason WHERE id=p_case_id;
UPDATE investigations SET status='cancelled', cancelled_at=clock_timestamp(),
  cancellation_reason='Case cancelled' WHERE case_id=p_case_id AND status='active';
```

---

### `public.cancel_investigation(p_investigation_id uuid, p_reason text)` — poster or Table owner

```
IF NOT EXISTS (profiles WHERE id=auth_uid() AND is_active=true AND is_suspended=false)
  → EXCEPTION 'suspended or inactive account';
  -- Both poster and group owner callers must pass this check.

SELECT i.*, c.poster_id, c.state AS case_state
FROM investigations i JOIN cases c ON c.id=i.case_id
WHERE i.investigation_id=p_investigation_id FOR UPDATE;
IF NOT FOUND → EXCEPTION;

-- Require cases.state = 'launched' — cannot cancel after deadline, reveal, or cancellation
IF v_case_state != 'launched' → EXCEPTION
  'investigation can only be cancelled while case is launched (current case state: %)';

IF v_case.poster_id != auth_uid() AND NOT EXISTS (
  SELECT 1 FROM group_members
  WHERE group_id=v_inv.group_id AND player_id=auth_uid() AND role='owner'
) → EXCEPTION 'only the poster or the Table owner can cancel this investigation';

IF v_inv.status != 'active' → EXCEPTION 'investigation is not active (current: %)';

UPDATE investigations SET status='cancelled', cancelled_at=clock_timestamp(),
  cancellation_reason=p_reason WHERE investigation_id=p_investigation_id;

-- cases.state is NOT changed.
```

EXECUTE to `authenticated`.

---

### `public.submit_guess(...)` — detective

**Full contract with corrected ordering and race-branched idempotency:**

```
p_case_id uuid, p_investigation_id uuid, p_race text, p_guess text,
p_idempotency_key uuid, p_client_submitted_at timestamptz

Step 1 — Actor authorization
  IF auth_uid() IS NULL → EXCEPTION ERRCODE 42501;
  IF NOT EXISTS (profiles WHERE id=auth_uid() AND is_active=true
                 AND onboarding_complete=true AND is_suspended=false)
    → EXCEPTION 'account not eligible';

Step 2 — Race validation (no DB read)
  IF p_race NOT IN ('what','where') → EXCEPTION 'invalid race';

Step 3 — Idempotency lookup (BEFORE state/deadline/eligibility checks)
  -- UNIQUE (case_id, player_id, idempotency_key) makes this lookup unambiguous.
  -- On concurrent identical submission, the second thread will hit the unique violation
  -- on INSERT; it catches, reloads the stored row, and applies the same logic below.

  v_existing := SELECT * FROM guess_attempts
    WHERE case_id=p_case_id AND player_id=auth_uid()
      AND idempotency_key=p_idempotency_key;

  IF v_existing.id IS NOT NULL THEN
    -- Compare race first
    IF v_existing.race != p_race THEN
      RAISE EXCEPTION 'FK_CONFLICT: idempotency key reused with different race';
    END IF;
    -- Compare only the relevant answer column (branch by race)
    IF p_race = 'what' THEN
      IF v_existing.dish_guess IS DISTINCT FROM p_guess THEN
        RAISE EXCEPTION 'FK_CONFLICT: idempotency key reused with different answer';
      END IF;
    ELSE  -- 'where'
      IF v_existing.restaurant_guess IS DISTINCT FROM p_guess THEN
        RAISE EXCEPTION 'FK_CONFLICT: idempotency key reused with different answer';
      END IF;
    END IF;
    RETURN v_existing;  -- Identical payload; idempotent replay — skip all further checks
  END IF;

  -- Check for existing attempt for this player + race with a different key
  IF EXISTS (SELECT 1 FROM guess_attempts
             WHERE case_id=p_case_id AND player_id=auth_uid() AND race=p_race) THEN
    RAISE EXCEPTION 'FK_CONFLICT: a guess for this race already exists';
  END IF;

Step 4 — Case state and deadline
  SELECT state, deadline_at, poster_id FROM cases WHERE id=p_case_id;
  IF NOT FOUND → EXCEPTION 'case not found';
  IF v_case.state != 'launched' → EXCEPTION 'case is not accepting guesses (state: %)';
  IF clock_timestamp() >= v_case.deadline_at → EXCEPTION 'deadline has passed';
    -- >= matches the set_guess_receipt_fields trigger deadline check

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

Step 6 — Bilateral block check with poster (post-launch blocks prevent guesses)
  IF EXISTS (
    SELECT 1 FROM user_blocks
    WHERE (blocker_id=auth_uid() AND blocked_id=v_case.poster_id)
       OR (blocker_id=v_case.poster_id AND blocked_id=auth_uid())
  ) → EXCEPTION 'FK_FORBIDDEN: blocked user cannot submit guesses';

Step 7 — INSERT
  INSERT INTO guess_attempts (..., idempotency_key, ...);
  -- Trigger set_guess_receipt_fields fires; assigns receipt_sequence.
  -- UNIQUE (case_id, player_id, idempotency_key) and UNIQUE (case_id, player_id, race)
  -- both enforced at DB level; concurrent duplicate → catch unique violation → reload → re-apply Step 3 logic
```

---

## 18. `launch_case()` — Full Contract

```
launch_case(p_actor_id uuid, p_case_id uuid, p_group_ids uuid[], p_duration_seconds integer)
RETURNS TABLE (investigation_id uuid, group_id uuid)
SECURITY DEFINER SET search_path = ''
```

EXECUTE to `authenticated`. Revoked from `service_role`.

```
v_now := clock_timestamp();

Step 1 — Authorization match (no DB read)
  IF p_actor_id IS DISTINCT FROM private.auth_uid()
    → RAISE 'FK_FORBIDDEN: p_actor_id does not match authenticated identity';

Step 2 — Input shape
  Duplicate group_ids → FK_INVALID_INPUT
  array_length not 1–10 → FK_INVALID_INPUT
  duration not 3600–86400 or not % 3600 → FK_INVALID_INPUT

Step 3 — Actor authorization
  profiles: is_active=true, onboarding_complete=true, is_suspended=false → else FK_FORBIDDEN
  deletion_log: status IN ('pending','database_prepared','auth_deleted','failed') → FK_FORBIDDEN

Step 4 — Lock case + validate ownership
  SELECT ... FROM cases WHERE id=p_case_id FOR UPDATE;
  NOT FOUND OR poster_id != p_actor_id → FK_NOT_FOUND

Step 5 — Idempotency (only after ownership confirmed)
  IF state='launched':
    existing_groups = SELECT group_id FROM investigations WHERE case_id=p_case_id ORDER BY group_id;
    IF existing_groups = sort(p_group_ids)
       AND EXTRACT(EPOCH FROM (deadline_at - posted_at)) = p_duration_seconds
    THEN RETURN existing rows; ELSE raise FK_WRONG_STATE; END IF;

Step 6 — Require ready
  state != 'ready' → FK_WRONG_STATE

Step 7 — Validate case_secrets (all four canonical/display fields non-null and non-empty)
Step 8 — Validate media (media_object_id NOT NULL AND status='ready')
Step 9 — No active upload_sessions
Step 10 — Per-group: exists, not archived; p_actor_id is a member

Writes: UPDATE cases; per group: INSERT investigation ON CONFLICT DO NOTHING;
  INSERT investigation_members (is_active, onboarding_complete, is_suspended=false,
  no bilateral block with poster; ON CONFLICT DO NOTHING);
  Require ≥1 detective per investigation.
RETURN QUERY SELECT investigation_id, group_id FROM investigations WHERE case_id=p_case_id;
```

---

## 19. RLS — Guess Visibility

### Own-guess — always visible, no state restriction
```sql
CREATE POLICY guess_own_view ON public.guess_attempts AS PERMISSIVE FOR SELECT
USING (
  player_id = private.auth_uid()
  AND EXISTS (SELECT 1 FROM public.profiles WHERE id=private.auth_uid() AND is_active=true)
);
```

### Poster visibility — launched/locked/revealed
```sql
CREATE POLICY guess_poster_view ON public.guess_attempts AS PERMISSIVE FOR SELECT
USING (
  private.is_case_poster(case_id)
  AND EXISTS (SELECT 1 FROM public.cases
              WHERE id=guess_attempts.case_id AND state IN ('launched','locked','revealed'))
  AND EXISTS (SELECT 1 FROM public.profiles WHERE id=private.auth_uid() AND is_active=true)
);
```

### Co-investigator revealed visibility — shared investigation + eligibility required
```sql
-- Viewer and author must share at least one investigation for this case.
-- Viewer must have eligibility_status = 'eligible' in that shared investigation.
-- Prevents removed/excluded/deleted members from seeing revealed guesses.
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
      AND v_im.eligibility_status = 'eligible'   -- viewer must be eligible
      AND a_im.player_id = guess_attempts.player_id
      AND i.case_id = guess_attempts.case_id
  )
  AND EXISTS (SELECT 1 FROM public.profiles WHERE id=private.auth_uid() AND is_active=true)
);
```

---

## 20. Scoring — Active Investigations Only

`reveal_case()` and `reveal_case_service()` score only `status='active'` investigations. `do_reveal_impl_v3()` scores only `eligibility_status='eligible'` members. `apply_correction()` skips non-active investigations and non-eligible members.

---

## 21. Migration Plan — Dependency-Ordered

`V4__case_investigation_schema.sql`. One `BEGIN`/`COMMIT`.

```
Phase 0 — Prerequisite guard
  DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.tables
      WHERE table_schema='private' AND table_name='moderators')
    THEN RAISE EXCEPTION 'V4: apply V3 (UGC Safety) first'; END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.tables
      WHERE table_schema='public' AND table_name='content_reports')
    THEN RAISE EXCEPTION 'V4: apply V3 (UGC Safety) first'; END IF;
  END $$;

Phase 1 — Rename challenges → cases
  1a. ALTER TABLE public.challenges RENAME TO cases
  1b. -- Constraint 'challenges_state_check' retains its name post-rename.
      ALTER TABLE public.cases DROP CONSTRAINT challenges_state_check;
      ALTER TABLE public.cases ADD CONSTRAINT cases_state_check
        CHECK (state IN ('draft','active','ready','launched','locked','revealed','retired','cancelled'));
      -- Temporary: includes 'active' through Phase 16.
  1c. Verify rules_version_id DEFAULT, created_at DEFAULT, media_object_id FK

Phase 2 — challenge_secrets → case_secrets
  RENAME TABLE; RENAME COLUMN challenge_id → case_id; recreate triggers, RLS, grants

Phase 3 — Moderation target type migration (two-step constraint replace)
  -- Step A: replace old constraint with temporary one allowing both values
  ALTER TABLE public.content_reports DROP CONSTRAINT cr_target_type_check;
  ALTER TABLE public.content_reports ADD CONSTRAINT cr_target_type_check_tmp
    CHECK (target_type IN ('challenge','case','comment','clue','profile','media_object'));

  ALTER TABLE public.moderation_actions DROP CONSTRAINT ma_target_type_check;
  ALTER TABLE public.moderation_actions ADD CONSTRAINT ma_target_type_check_tmp
    CHECK (target_type IS NULL OR
           target_type IN ('challenge','case','comment','clue','profile','media_object'));

  -- Step B: migrate rows
  UPDATE public.content_reports    SET target_type='case' WHERE target_type='challenge';
  UPDATE public.moderation_actions SET target_type='case' WHERE target_type='challenge';

  -- Step C: install final constraints (case-only; 'challenge' now excluded)
  ALTER TABLE public.content_reports DROP CONSTRAINT cr_target_type_check_tmp;
  ALTER TABLE public.content_reports ADD CONSTRAINT cr_target_type_check
    CHECK (target_type IN ('case','comment','clue','profile','media_object'));

  ALTER TABLE public.moderation_actions DROP CONSTRAINT ma_target_type_check_tmp;
  ALTER TABLE public.moderation_actions ADD CONSTRAINT ma_target_type_check
    CHECK (target_type IS NULL OR
           target_type IN ('case','comment','clue','profile','media_object'));

Phase 4 — Create new tables
  CREATE TABLE investigations; CREATE TABLE investigation_members

Phase 5 — Migrate eligible_participants → investigation_members
  INSERT investigations; INSERT investigation_members; DROP eligible_participants

Phase 6 — Rename challenge_id on dependent tables
  6a. guess_attempts: RENAME → case_id; ADD idempotency_key nullable→backfill→NOT NULL;
      ADD UNIQUE (case_id, player_id, race);
      ADD UNIQUE (case_id, player_id, idempotency_key)  -- both added after backfill
  6b. exclusion_events: RENAME → case_id; ADD investigation_id nullable→backfill→NOT NULL;
      DROP old UNIQUE (catalog name); ADD UNIQUE (investigation_id, player_id);
      ADD cross-record integrity trigger
  6c. clues: RENAME → case_id
  6d. comments: RENAME → case_id; ADD investigation_id nullable→backfill→NOT NULL;
      ADD cross-record integrity trigger
  6e. challenge_answer_aliases → case_answer_aliases: RENAME TABLE + RENAME COLUMN → case_id
  6f. correction_events: RENAME → case_id; DROP resulting_score_run_id
  6g. score_runs: RENAME → case_id; ADD investigation_id nullable→backfill→NOT NULL;
      DROP old UNIQUE (catalog name); ADD UNIQUE (investigation_id, revision_number);
      ADD cross-record integrity trigger
  6h. guess_judgments: RENAME → case_id; ADD investigation_id nullable→backfill→NOT NULL
  6i. score_events: RENAME → case_id; ADD investigation_id nullable→backfill→NOT NULL
  6j. reactions: ADD investigation_id nullable; backfill; NOT NULL check; NOT NULL;
      DROP challenge_id FK (catalog name); DROP challenge_id;
      ADD investigation_id FK; DROP old UNIQUE (catalog name);
      CREATE UNIQUE (investigation_id, player_id, emoji)

Phase 7 — current_score_events VIEW
  DROP + CREATE WITH (security_invoker=true); GRANT SELECT TO authenticated

Phase 8 — Upload sessions
  RENAME COLUMN challenge_id → case_id; update FK; drop/create index;
  UPDATE original_storage_path + display_storage_path separately (replace 'challenges/' → 'cases/')

Phase 9 — RLS helper rebuilds
  DROP is_challenge_group_member; CREATE is_case_member + is_investigation_member;
  DROP old + recreate: is_case_poster, is_case_revealed, is_investigation_eligible;
  CREATE OR REPLACE caller_has_guessed

Phase 10 — Operational function rebuilds
  private.prepare_account_deletion: full rebuild per §16
  private.mark_auth_deleted, mark_storage_cleaned, record_deletion_failure: CREATE OR REPLACE
  private.get_storage_keys_for_deletion: CREATE OR REPLACE
  private.do_reveal_impl_v3: DROP + CREATE
  private.reveal_case_service: DROP + CREATE
  public.lock_case: DROP lock_challenge + CREATE
  public.reveal_case: DROP reveal_challenge + CREATE
  public.cancel_case: DROP cancel_challenge + CREATE
  public.cancel_investigation: CREATE (new)
  public.apply_correction: CREATE OR REPLACE
  public.soft_delete_comment: CREATE OR REPLACE
  DROP public.activate_challenge

Phase 11 — Step 24.1 function updates
  approve_photo, reject_photo (with V4 case-state extensions)
  claim_moderation_media_cleanup, get_media_serve_authorization (per §13)
  get_moderation_queue, get_pending_review_media, get_reported_media (per §13)
  report_content (cancelled-case guard per §13), remove_content, remove_media
  private.can_view_case: DROP + CREATE; private.can_viewer_access_case: DROP + CREATE
  private.has_block_with_poster: CREATE OR REPLACE

Phase 12 — V2 function updates
  reserve_upload_session: DROP + recreate; finalize_upload_session: CREATE OR REPLACE;
  reveal_case_service_wrapper: DROP + recreate; prepare_account_deletion_wrapper: CREATE OR REPLACE

Phase 13 — Trigger rebuilds (see §15)
  Drop old triggers (challenge_create_fields, challenge_protect_fields, etc.)
  Recreate on cases/case_secrets/case_answer_aliases with corrected names and state values
  V2 triggers: check_launch_no_active_upload, check_launch_media_ready

Phase 14 — Index rebuilds (see §15)
  DROP old challenge-named indexes; CREATE new case/investigation-named replacements

Phase 15 — RLS policies (see §15 + §19)
  Drop and recreate all policies; apply eligibility requirement on revealed-guess policy

Phase 16 — State conversion: active → launched
  16a. DISABLE TRIGGER case_protect_fields ON public.cases
  16b. UPDATE public.cases SET state='launched' WHERE state='active'
  16c. ENABLE TRIGGER case_protect_fields ON public.cases
  16d. ALTER TABLE cases DROP CONSTRAINT cases_state_check;
       ALTER TABLE cases ADD CONSTRAINT cases_state_check
         CHECK (state IN ('draft','ready','launched','locked','revealed','retired','cancelled'));

Phase 17 — Partial index update
  DROP INDEX one_active_challenge_per_poster;
  CREATE UNIQUE INDEX one_active_case_per_poster ON cases (poster_id)
    WHERE state IN ('draft','ready','launched','locked');

Phase 18 — Remove group_id from cases
  pg_depend audit; ALTER TABLE cases DROP CONSTRAINT challenges_group_id_fkey;
  DROP INDEX idx_challenges_group_id; ALTER TABLE cases DROP COLUMN group_id;

Phase 19 — New service functions (launch_case and submit_guess only)
  launch_case per §18; submit_guess per §17
  -- lock_case and reveal_case were rebuilt in Phase 10; NOT repeated here.

Phase 20 — Grants, ownership, completion marker
  GRANT SELECT ON cases TO forkensics_rls_helper
  GRANT SELECT ON investigation_members TO forkensics_rls_helper
  GRANT UPDATE (...) ON cases TO forkensics_executor
  GRANT INSERT, UPDATE, DELETE ON investigations TO forkensics_executor
  GRANT INSERT, UPDATE ON investigation_members TO forkensics_executor
  All new/renamed functions: OWNER TO forkensics_executor
  REVOKE temporary build-time privileges
  INSERT schema_migrations marker
```

---

## 22. Acceptance Criteria (Summary — Key Items)

**Schema:**
- No `challenge_id` in any listed table; single named state constraint; `one_active_case_per_poster` predicate correct; `'active'` rejected post-migration
- `guess_attempts`: both `UNIQUE (case_id, player_id, race)` and `UNIQUE (case_id, player_id, idempotency_key)` present

**Moderation:**
- `content_reports` and `moderation_actions`: no `'challenge'` rows post-migration; final constraints reject `'challenge'`; two-step DDL sequence verifiable
- New report on cancelled case → rejected; existing pending report on cancelled case → still in queue; `action_report`, `dismiss_report`, `remove_content`, `remove_media` succeed on cancelled-case targets
- `get_media_serve_authorization`: `can_viewer_access_case` called; empty set for non-member
- `get_moderation_queue`: returns `case_id`; `target_type = 'case'`

**Core functions:**
- `lock_case`: rejects before `deadline_at`; rejects non-`launched` state; uses `cases.state`
- `reveal_case`: poster deadline enforced; all active investigations scored; case → `revealed` after loop; `do_reveal_impl_v3` does NOT update `cases.state`
- `cancel_case`: poster only; no group owner authority; cancels case + all active investigations
- `cancel_investigation`: rejected when `cases.state != 'launched'`; suspended caller rejected; case state unchanged; test: cancel after reveal fails
- All-investigations-cancelled: case stays in current state; reveal scores nothing; case still → `revealed`

**`launch_case()`:**
- `p_actor_id != auth_uid()` → `FK_FORBIDDEN` (forged-actor test)
- Non-poster rejected at Step 4 before idempotency
- Deletion guard: `status IN ('pending','database_prepared','auth_deleted','failed')` → rejected

**`submit_guess()`:**
- Suspended caller → rejected
- Bilateral block with poster → rejected (post-launch block tested)
- `clock_timestamp() >= deadline_at` → rejected
- Idempotency: same key + identical payload (race-branched comparison) → existing row returned before state/deadline check
- Same key + different race → `FK_CONFLICT`; same key + different answer (correct column only) → `FK_CONFLICT`
- Different key + existing race → `FK_CONFLICT`
- Concurrency test: two sessions submit identical guess simultaneously; exactly one row created; both return correctly (two-session test)

**RLS:**
- Revealed-guess: excluded/removed viewer cannot see — eligibility_status='eligible' required; test added
- Cross-Table isolation: Table A cannot see Table B-only guesses at reveal; Table A cannot read Table B's comments, reactions, members, or scores

**Account deletion:**
- `eligibility_status='eligible'` set to `'account_deleted'` for ALL investigations regardless of case state
- `apply_correction()` on revealed case after player deleted → player gets 0 points (test required)
- Suspended successor skipped in group transfer (tested)
- `database_prepared` set only after all 8 steps succeed

**Upload sessions:**
- Both `original_storage_path` and `display_storage_path` updated; no `storage_path` column touched

**V2:**
- All 21 unchanged V2 functions pass existing test groups after migration

---

## 23. Out of Scope

Push notifications, feed queries, monthly leaderboard tables, admin UI, Edge Function implementations, `case_secrets → private` schema, Orders To Go (FEAT-001), retired-state archival, per-comment reactions.

---

*Ready for review by Bill, Claude, and Codex. No migration code written until all three parties approve.*
