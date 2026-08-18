# Step 26 Proposal — Case / Investigation Schema
**Revision:** 7  
**Status:** DRAFT — awaiting approval from Bill, Claude, and Codex before any code is written  
**Prerequisites:** Step 25 merged (`v0.2.0-upload-sessions`); Step 24.1 merged as `V3__ugc_safety_moderation.sql` and tagged before this migration runs  
**Supersedes:** Rev 6 (rejected — GPT review, 7 blockers)

---

## Changes From Rev 6

| Blocker | Fix |
|---|---|
| 1 | Migration version corrected. Step 24.1 = `V3__ugc_safety_moderation.sql`. Step 26 = `V4__case_investigation_schema.sql`. Phase 0 prerequisite guard updated accordingly. |
| 2 | `launch_case()` validation order corrected: (1) input shape, (2) actor authorization, (3) lock case + ownership, (4) idempotency if already launched, (5) require ready. Non-poster cannot reach idempotency path. Test added. |
| 3 | Full contracts defined for `submit_guess`, `lock_case`, `reveal_case` (both entry points), `cancel_case`. `do_reveal_impl_v3` explicitly does NOT update `cases.state` — callers loop over active investigations then update state. Phase 9 vs Phase 18 duplication fixed: `lock_case` and `reveal_case` appear only in Phase 9; Phase 18 = `launch_case` + `submit_guess` only. |
| 4 | RLS helper split: `private.is_case_investigation_member(uuid)` replaced by `private.is_case_member(case_id)` (any investigation for the case) and `private.is_investigation_member(investigation_id)` (exact investigation). All table policies updated to use the appropriate helper. Cross-Table isolation tests added. |
| 5 | Added `get_media_serve_authorization` and `get_moderation_queue` to Step 24.1 inventory. `challenge_answer_aliases` renamed to `case_answer_aliases` throughout — one final name, applied consistently to functions, triggers, policies, grants, and tests. |
| 6 | `lock_case` references `cases.state` (not `status`). `enforce_exclusion_rules` corrected: `withdrew`/`removed` requires `investigations.status = 'active' AND cases.state = 'launched'`; `account_deleted` requires `investigations.status = 'active' AND cases.state IN ('launched','locked')`. UNIQUE constraint drops use verified constraint names, not index names. |
| 7 | Group ownership successor query adds `AND p.is_suspended = false`. Test added: suspended member skipped; next eligible member becomes owner, or Table archived if none. |

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
| Step 24.1 prerequisite | Must be merged as `V3__ugc_safety_moderation.sql` and tagged before V4 runs |
| `challenge_answer_aliases` final name | `case_answer_aliases` — applied consistently throughout |

---

## 3. `public.cases` — Exact Column Set

All columns sourced from V1's `challenges`. Only marked differences.

```sql
CREATE TABLE public.cases (
  id                   uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  -- group_id: kept through Phase 13 for dependent object migration; DROPPED in Phase 17
  poster_id            uuid        NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  media_object_id      uuid        REFERENCES public.media_objects(id) ON DELETE RESTRICT,
  state                text        NOT NULL DEFAULT 'draft',
                                   -- No inline CHECK on this column. Only the named constraint below.
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
    -- Single named constraint only. 'active' included through Phase 15, excluded in final.
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
```

---

## 4. `public.case_secrets` (renamed from `challenge_secrets`)

`challenge_id → case_id`. All V1 structure, constraints, trigger names, and RLS policy logic preserved. Updated to reference `cases`.

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

Valid investigation statuses: `active`, `cancelled`, `tombstoned` — no `locked` status. Deadline enforcement is on `cases.state`; investigations track lifecycle independently.

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

Snapshot at `launch_case()`: `is_active = true AND onboarding_complete = true AND is_suspended = false`, no block pair with poster. Poster excluded.

---

## 7. `public.exclusion_events` — Investigation-Scoped

```sql
-- V3 changes from V1:
--   challenge_id  →  investigation_id uuid NOT NULL FK → investigations
--   case_id uuid NOT NULL FK → cases  (retained; cross-record integrity trigger verifies
--                                     investigations.case_id = exclusion_events.case_id)
--   UNIQUE (challenge_id, player_id)  →  UNIQUE (investigation_id, player_id)
--   reason CHECK preserved: 'withdrew' | 'removed' | 'account_deleted'
```

State gate for each reason (see §15 trigger rebuild):
- `withdrew` / `removed`: `investigations.status = 'active' AND cases.state = 'launched'`
  (active gameplay; before deadline)
- `account_deleted`: `investigations.status = 'active' AND cases.state IN ('launched','locked')`
  (trusted path; forkensics_executor BYPASSRLS)

---

## 8. `public.guess_attempts`

```sql
-- V1 columns preserved:
--   id, case_id (was challenge_id), player_id
--   race, dish_guess, restaurant_guess
--   received_at timestamptz NOT NULL DEFAULT clock_timestamp()
--   receipt_sequence bigint NOT NULL
--   client_submitted_at timestamptz
--   UNIQUE (case_id, receipt_sequence)
--   ga_race_check, ga_race_fields_check preserved exactly

-- Two V3 additions:
--   idempotency_key uuid NOT NULL
--   UNIQUE (case_id, player_id, race)  -- one locked attempt per player per race

-- Migration: idempotency_key nullable → backfill gen_random_uuid() → NOT NULL
```

---

## 9. Scoring Tables

### `score_runs`
`challenge_id → case_id`. `investigation_id uuid NOT NULL` added (nullable → backfill → NOT NULL). `UNIQUE (investigation_id, revision_number)` replaces `UNIQUE (challenge_id, revision_number)`. Cross-record integrity trigger: `investigations.case_id = score_runs.case_id`.

### `correction_events`
`challenge_id → case_id`. `resulting_score_run_id` DROPPED. `score_runs.triggering_correction_id` is the back-reference.

### `guess_judgments`
`challenge_id → case_id`. `investigation_id uuid NOT NULL` added. Cross-record integrity trigger.

### `score_events`
`challenge_id → case_id`. `investigation_id uuid NOT NULL` added. Cross-record integrity trigger.

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
`challenge_id → case_id`. `investigation_id uuid NOT NULL` added (nullable → backfill → NOT NULL). `ON DELETE RESTRICT`. Cross-record integrity trigger. Step 24.1 moderation columns preserved.

### `reactions`
Investigation-scoped in V3. Migration pattern (§20 Phase 5j): add `investigation_id` nullable → backfill → NOT NULL → drop `challenge_id` FK → drop column → add `investigation_id` FK → replace UNIQUE index.

---

## 11. `public.clues` and `public.case_answer_aliases`

`challenge_id → case_id`. `challenge_answer_aliases` renamed to `case_answer_aliases`. All V1 structure, constraints, triggers preserved. Step 24.1 moderation columns on clues preserved.

---

## 12. `private.upload_sessions`

`challenge_id → case_id`. FK → `public.cases(id)`. Index renamed `upload_sessions_one_active_per_case`. Storage paths `challenges/ → cases/`.

---

## 13. Media Moderation — Using Approved Step 24.1 Contract

`approve_case_media()` and `reject_case_media()` do NOT exist. Approved Step 24.1 functions are extended.

**`approve_photo(p_media_object_id, p_moderator_id, p_reason)` — V3 extension:**
After approved steps, atomically:
```sql
UPDATE public.cases
SET state = 'ready'
WHERE media_object_id = p_media_object_id AND state = 'draft';
```

**`reject_photo(p_media_object_id, p_moderator_id, p_reason)` — V3 extension:**
After approved steps, atomically:
```sql
UPDATE public.cases
SET media_object_id = NULL
WHERE media_object_id = p_media_object_id AND state = 'draft';
-- Case stays 'draft'; poster may initiate a new upload session.
```

Media cleanup for `rejected`: Step 24.1's `claim_moderation_media_cleanup()` already handles `status IN ('rejected','removed')`. Only the re-encoded/display file is returned. Original upload cleaned via V2's `get_complete_sessions_pending_expiry_cleanup()`. Two-path separation preserved.

`claim_moderation_media_cleanup`, `get_pending_review_media`, `get_reported_media`: `public.challenges → public.cases`. CREATE OR REPLACE.

---

## 14. V2 Function Impact

### Functions requiring body changes

| Function | Reason | Method |
|---|---|---|
| `reserve_upload_session(p_challenge_id, ...)` | Param; `challenges` SELECT+UPDATE; storage path | DROP + recreate as `(p_case_id, ...)`; restore grants + owner |
| `finalize_upload_session(uuid, text)` | `v_session.challenge_id`; `challenges` refs | CREATE OR REPLACE |
| `reveal_challenge_service_wrapper(p_challenge_id uuid)` | Name; param; calls `private.reveal_challenge_service` | DROP + recreate as `reveal_case_service_wrapper(p_case_id uuid)` |
| `prepare_account_deletion_wrapper(p_user_id uuid)` | V3 additions (§16) | CREATE OR REPLACE |

### Functions with no body changes (verified from V2 source)
`activate_upload_session`, `resolve_upload_session`, `advance_upload_session_processing`, `check_upload_session_lease`, `advance_upload_session_sanitized`, `fail_upload_session`, `quiesce_upload_sessions_for_deletion`, `get_upload_capability_expiry`, `get_all_upload_session_paths_for_deletion`, `claim_cleanup_sessions`, `mark_session_cleaned`, `mark_original_path_post_expiry_cleaned`, `get_complete_sessions_pending_expiry_cleanup`, `get_superseded_media_to_clean`, `mark_superseded_media_cleaned`, `get_media_storage_key`, `get_deletion_storage_keys`, `record_deletion_failure_wrapper`, `mark_auth_deleted_wrapper`, `mark_storage_cleaned_wrapper`, `claim_deletion_recovery_records`, `complete_deletion_recovery`, `fail_deletion_recovery`

### V2 trigger functions
DROP + recreate on `public.cases`:
- `private.check_activation_no_active_upload()` → `private.check_launch_no_active_upload()`: fires on `'ready' → 'launched'`
- `private.check_activation_media_ready()` → `private.check_launch_media_ready()`: fires on `'ready' → 'launched'`

---

## 15. Complete V1 + Step 24.1 Object Inventory Requiring Changes

Objects not listed are unaffected.

### RLS Helper Functions (owned by `forkensics_rls_helper`)

| Function | V3 action |
|---|---|
| `private.auth_uid()` | No change |
| `private.normalize_answer(text)` | No change |
| `private.is_group_member(uuid)` | No change |
| `private.is_group_member_with(uuid)` | No change |
| `private.is_challenge_group_member(uuid)` | DROP. Replaced by two new helpers (see below) |
| `private.is_challenge_poster(uuid)` | DROP + recreate as `private.is_case_poster(case_id uuid)`; body: `SELECT 1 FROM cases WHERE id = case_id AND poster_id = private.auth_uid()` |
| `private.is_challenge_revealed(uuid)` | DROP + recreate as `private.is_case_revealed(case_id uuid)`; body: `SELECT 1 FROM cases WHERE id = case_id AND state = 'revealed'` |
| `private.is_eligible_non_excluded(uuid)` | DROP + recreate as `private.is_investigation_eligible(investigation_id uuid)`; body: `SELECT 1 FROM investigation_members WHERE investigation_id = $1 AND player_id = private.auth_uid() AND eligibility_status = 'eligible'` |
| `private.caller_has_guessed(uuid)` | CREATE OR REPLACE; `guess_attempts.challenge_id → case_id` |

**New helpers (replace `private.is_challenge_group_member`):**

```sql
-- Case-level: caller is a member of ANY investigation for this case.
-- Used for: cases, case_secrets, clues, case_answer_aliases, correction_events,
--           guess_attempts (revealed view), guess_judgments (via case_id only where needed)
CREATE OR REPLACE FUNCTION private.is_case_member(p_case_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.investigations i
    JOIN public.investigation_members im ON im.investigation_id = i.investigation_id
    WHERE i.case_id = p_case_id
      AND im.player_id = private.auth_uid()
  );
$$;

-- Investigation-level: caller is a member of this SPECIFIC investigation.
-- Used for: investigation_members, exclusion_events, comments, reactions,
--           score_runs, guess_judgments, score_events (where investigation isolation required)
CREATE OR REPLACE FUNCTION private.is_investigation_member(p_investigation_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.investigation_members
    WHERE investigation_id = p_investigation_id
      AND player_id = private.auth_uid()
  );
$$;
```

### Operational Functions (owned by `forkensics_executor`) — V1 source

| Function | V3 action |
|---|---|
| `public.create_group(text)` | No change |
| `public.transfer_group_ownership(uuid, uuid)` | No change |
| `public.create_group_invite(uuid)` | No change |
| `public.redeem_group_invite(text)` | No change |
| `public.revoke_group_invite(uuid)` | No change |
| `public.activate_challenge(uuid)` | DROPPED — absorbed into `launch_case()` |
| `public.lock_challenge(uuid)` | DROP + recreate as `public.lock_case(uuid)` — see §17 |
| `public.reveal_challenge(uuid)` | DROP + recreate as `public.reveal_case(uuid)` — see §17 |
| `public.cancel_challenge(uuid, text)` | DROP + recreate as `public.cancel_case(uuid, text)` — see §17 |
| `public.apply_correction(uuid, text, text, text, uuid, text)` | CREATE OR REPLACE; `challenge_id → case_id`; per-investigation scoring |
| `public.soft_delete_comment(uuid)` | CREATE OR REPLACE; no column rename in body; trigger `comment_update_guard` updated separately |
| `private.do_reveal_impl(uuid)` | DROP + recreate as `private.do_reveal_impl_v3(p_case_id uuid, p_investigation_id uuid)` — see §17; does NOT update cases.state |
| `private.reveal_challenge_service(uuid)` | DROP + recreate as `private.reveal_case_service(uuid)` — see §17 |
| `private.prepare_account_deletion(uuid)` | Full rebuild — see §16 |
| `private.get_storage_keys_for_deletion(uuid)` | CREATE OR REPLACE; verify any upload_sessions join updated |
| `private.mark_auth_deleted(uuid)` | CREATE OR REPLACE; verify no challenge_id reference |
| `private.mark_storage_cleaned(uuid)` | CREATE OR REPLACE; verify no challenge_id reference |
| `private.record_deletion_failure(uuid, text)` | CREATE OR REPLACE; verify no challenge_id reference |

### Functions — Step 24.1 source

| Function | V3 action |
|---|---|
| `private.can_view_challenge(uuid)` | DROP + recreate as `private.can_view_case(uuid)` |
| `private.can_viewer_access_challenge(uuid, uuid)` | DROP + recreate as `private.can_viewer_access_case(uuid, uuid)` |
| `private.has_block_with_poster(uuid)` | CREATE OR REPLACE; `challenges → cases` |
| `public.approve_photo(uuid, uuid, text)` | CREATE OR REPLACE; V3 case-state side-effect (§13) |
| `public.reject_photo(uuid, uuid, text)` | CREATE OR REPLACE; V3 case-state side-effect (§13) |
| `public.claim_moderation_media_cleanup(int)` | CREATE OR REPLACE; `challenges → cases` |
| `public.get_pending_review_media(uuid)` | CREATE OR REPLACE; `challenge_id → case_id` |
| `public.get_reported_media(uuid)` | CREATE OR REPLACE; `challenge_id → case_id` |
| `public.get_media_serve_authorization(...)` | CREATE OR REPLACE; any `challenges` ref → `cases` |
| `public.get_moderation_queue(...)` | CREATE OR REPLACE; any `challenges` ref → `cases` |
| `public.report_content(text, uuid, text, text)` | CREATE OR REPLACE; `challenges → cases` |
| `public.remove_content(text, uuid, uuid, uuid, text)` | CREATE OR REPLACE; `challenges → cases` |
| `public.remove_media(uuid, uuid, uuid, text)` | CREATE OR REPLACE; `challenges → cases` |

### Triggers requiring changes

Trigger and function names sourced from actual V1 file.

| Trigger name | Function name | Table | V3 action |
|---|---|---|---|
| `challenge_create_fields` | `public.set_challenge_create_fields()` | `challenges` | DROP trigger; recreate function as `public.set_case_create_fields()`; recreate as `case_create_fields` on `cases` |
| `challenge_protect_fields` | `public.protect_challenge_authority_fields()` | `challenges` | DROP trigger; recreate function; recreate as `case_protect_fields` on `cases`; extend state table; DISABLE during Phase 15 |
| `challenge_secrets_guard` | `public.guard_answer_edits()` | `challenge_secrets` | Recreate on `case_secrets`; body updated for `case_id` |
| `challenge_secrets_timestamps` | `public.set_challenge_secret_timestamps()` | `challenge_secrets` | Recreate on `case_secrets`; rename function `public.set_case_secret_timestamps()` |
| `alias_guard_insert`, `alias_guard_update` | `public.guard_alias_edits()` | `challenge_answer_aliases` | CREATE OR REPLACE; body references `case_secrets.case_id`; recreate on `case_answer_aliases` |
| `guess_receipt` | `public.set_guess_receipt_fields()` | `guess_attempts` | CREATE OR REPLACE; `challenges.state = 'active' → 'launched'` |
| `guess_judgment_consistency` | `public.check_judgment_consistency()` | `guess_judgments` | CREATE OR REPLACE; `challenge_id → case_id`; add `investigation_id` check |
| `score_event_consistency` | `public.check_score_event_consistency()` | `score_events` | CREATE OR REPLACE; rebuilt for `investigation_members` |
| `exclusion_enforce` | `public.enforce_exclusion_rules()` | `exclusion_events` | CREATE OR REPLACE; state gates per §7 |
| `clues_timestamp`, `comments_timestamp`, `reactions_timestamp`, `exclusion_events_timestamp` | `public.set_append_only_timestamps()` | multiple | No change |
| `comment_update_guard` | `public.restrict_comment_updates()` | `comments` | CREATE OR REPLACE; `challenge_id → case_id`; Step 24.1 additions preserved |
| (Step 24.1) | `private.force_removal_fields_null()` | `challenges` | Recreate trigger on `cases` |
| (Step 24.1) | `private.restrict_moderation_field_updates()` | `challenges` | Recreate trigger on `cases` |
| `private.check_text_content_trigger()` | (Step 24.1) | (verify attachment) | If on any `challenges` column, recreate on `cases` |
| V2 activation triggers | See §14 | `cases` | DROP + recreate |

### Indexes requiring changes

UNIQUE constraint drops use verified constraint names from the catalog, not index names.

| V1/V2 Index | V3 replacement |
|---|---|
| `one_active_challenge_per_poster` ON `challenges` | `one_active_case_per_poster` ON `cases` WHERE `state IN ('draft','ready','launched','locked')` |
| `idx_challenges_group_id` | Dropped in Phase 17 |
| `idx_challenges_state` | Renamed `idx_cases_state` |
| `idx_guess_attempts_challenge` ON `(challenge_id, race, ...)` | Recreated ON `(case_id, race, receipt_sequence)` |
| `idx_guess_attempts_player` ON `(player_id, challenge_id)` | Recreated ON `(player_id, case_id)` |
| `idx_score_events_challenge` ON `(challenge_id)` | Recreated ON `(case_id)` |
| `idx_eligible_challenge` ON `eligible_participants` | Dropped (table replaced) |
| `idx_exclusion_challenge` ON `(challenge_id)` | Recreated ON `(investigation_id)` |
| `idx_clues_challenge` ON `(challenge_id)` | Recreated ON `(case_id)` |
| `idx_comments_challenge` ON `(challenge_id, posted_at)` | Recreated ON `(case_id, posted_at)` |
| `idx_reactions_challenge` ON `(challenge_id)` | Recreated ON `(investigation_id)` |
| `idx_aliases_challenge` ON `(challenge_id, field)` | Recreated ON `(case_id, field) WHERE is_active` |
| `idx_aliases_active_unique` ON `(challenge_id, field, normalized_value)` | Recreated ON `(case_id, field, normalized_value) WHERE is_active` |
| `idx_correction_challenge` ON `(challenge_id)` | Recreated ON `(case_id)` |
| `one_qualifying_per_player_race` ON `guess_judgments` | Updated predicate |
| `upload_sessions_one_active_per_challenge` | Renamed `upload_sessions_one_active_per_case` |

### RLS Policies requiring changes

All policies on affected tables dropped and recreated. Helper assignment:

| Table | Use |
|---|---|
| `cases` | `private.is_case_member(id)` |
| `case_secrets` | `private.is_case_member(case_id)`, `private.is_case_revealed(case_id)`, `private.is_case_poster(case_id)` |
| `clues` | `private.is_case_member(case_id)` |
| `case_answer_aliases` | `private.is_case_member(case_id)`, `private.is_case_revealed(case_id)` |
| `correction_events` | `private.is_case_member(case_id)`, `private.is_case_revealed(case_id)` |
| `guess_attempts` | Own: `player_id = auth_uid()`. Poster: `is_case_poster`. Revealed: `is_case_member + is_case_revealed`. (Guesses are case-scoped; player belongs to exactly one investigation per case.) |
| `investigation_members` | `private.is_investigation_member(investigation_id)` |
| `exclusion_events` | `private.is_investigation_member(investigation_id)` |
| `comments` | `private.is_investigation_member(investigation_id)` |
| `reactions` | `private.is_investigation_member(investigation_id)` |
| `score_runs` | `private.is_investigation_member(investigation_id)`, `private.is_case_revealed(case_id)` |
| `guess_judgments` | `private.is_investigation_member(investigation_id)`, `private.is_case_revealed(case_id)` |
| `score_events` | `private.is_investigation_member(investigation_id)`, `private.is_case_revealed(case_id)` |

`profiles.is_active` check added to every policy. Poster guess visibility (§18). Own-guess always-visible (§18). Grants updated: `cases`, `investigation_members` to `forkensics_rls_helper`.

---

## 16. Account Deletion — `private.prepare_account_deletion()` Full Rebuild

Step ordering sourced from V1. `quiesce_upload_sessions_for_deletion()` called separately before this function. No `v_media_ids[]` array.

```
Forward-only guard:
  IF deletion_log.status IN ('database_prepared','auth_deleted','complete') THEN RETURN; END IF;
  INSERT ... ON CONFLICT DO UPDATE SET status='pending', last_attempt_at=clock_timestamp(), error=NULL;

Step 1 — Cancel draft/ready cases
  UPDATE public.cases
  SET state='cancelled', cancelled_at=clock_timestamp(), cancellation_reason='Account deleted'
  WHERE poster_id = p_profile_id AND state IN ('draft','ready');

Step 2 — Exclude from active investigations (trusted forkensics_executor path)
  FOR each row WHERE investigation_members.player_id = p_profile_id
    AND eligibility_status = 'eligible'
    AND investigations.status = 'active'
    AND cases.state IN ('launched','locked'):
    UPDATE investigation_members SET eligibility_status = 'account_deleted'
      WHERE investigation_id = v_inv.investigation_id AND player_id = p_profile_id;
    INSERT INTO exclusion_events (investigation_id, case_id, player_id, reason, excluded_by)
      VALUES (v_inv.investigation_id, v_inv.case_id, p_profile_id, 'account_deleted', NULL)
      ON CONFLICT (investigation_id, player_id) DO NOTHING;

Step 3 — Transfer or archive owned groups
  FOR each group where gm.player_id = p_profile_id AND gm.role = 'owner' AND g.archived_at IS NULL:
    v_successor_id := SELECT gm2.player_id
      FROM group_members gm2 JOIN profiles p ON p.id = gm2.player_id
      WHERE gm2.group_id = v_group.group_id
        AND gm2.player_id != p_profile_id
        AND p.is_active = true
        AND p.onboarding_complete = true
        AND p.is_suspended = false      -- V3 addition: Step 24.1 adds suspension
      ORDER BY gm2.joined_at ASC LIMIT 1;

    IF v_successor_id IS NOT NULL THEN
      UPDATE group_members SET role = 'member' WHERE group_id = v_group.group_id AND player_id = p_profile_id;
      UPDATE group_members SET role = 'owner'  WHERE group_id = v_group.group_id AND player_id = v_successor_id;
    ELSE
      UPDATE groups SET archived_at = clock_timestamp() WHERE id = v_group.group_id;
    END IF;

Step 4 — Archive profile identity
  INSERT INTO private.profile_archive (...) SELECT ... FROM public.profiles WHERE id = p_profile_id
  ON CONFLICT (profile_id) DO NOTHING;

Step 5 — Anonymize profile row
  UPDATE public.profiles
  SET display_name='Former Player', avatar_color='gray', avatar_media_object_id=NULL, is_active=false
  WHERE id = p_profile_id;

Step 6 — Anonymize ALL investigation_members snapshot fields
  UPDATE public.investigation_members
  SET snapshot_display_name='[Deleted]', snapshot_avatar_media_object_id=NULL
  WHERE player_id = p_profile_id;
  -- eligibility_status unchanged for already-excluded rows

Step 7 — Tombstone all media objects
  UPDATE public.media_objects SET status='deleted' WHERE uploader_id = p_profile_id;

Step 8 — Mark DB step complete (only reached if all prior steps succeed)
  UPDATE private.deletion_log
  SET status='database_prepared', db_prepared_at=clock_timestamp()
  WHERE profile_id = p_profile_id;
```

---

## 17. Service Function Contracts

### `public.lock_case(p_case_id uuid)` — service-role scheduler only

```
SECURITY DEFINER, SET search_path = ''
-- No private.auth_uid() check; service-role caller path.

SELECT * FROM cases WHERE id = p_case_id FOR UPDATE;
IF NOT FOUND → RAISE EXCEPTION 'case not found';
IF clock_timestamp() < v_case.deadline_at → RAISE EXCEPTION 'deadline has not been reached';
  -- Rejects calls before deadline_at. clock_timestamp() must exceed deadline_at.
IF v_case.state != 'launched' → RAISE EXCEPTION 'lock requires launched state (current: %)', v_case.state;
  -- Uses cases.state column, not any status column.

UPDATE cases SET state='locked', locked_at=clock_timestamp() WHERE id=p_case_id;
```

Owned by `forkensics_executor`. Granted to `service_role` only. Revoked from `authenticated`.

---

### `public.reveal_case(p_case_id uuid)` — authenticated poster entry point

```
SECURITY DEFINER, SET search_path = ''

SELECT * FROM cases WHERE id = p_case_id FOR UPDATE;
IF NOT FOUND → RAISE EXCEPTION 'case not found';
IF private.auth_uid() IS NULL → RAISE EXCEPTION 'caller identity required' ERRCODE 42501;
IF NOT EXISTS (profiles WHERE id=auth_uid() AND is_active=true) → RAISE EXCEPTION 'account is inactive';
IF v_case.poster_id != private.auth_uid() → RAISE EXCEPTION 'caller is not the poster';
IF clock_timestamp() < v_case.deadline_at → RAISE EXCEPTION 'deadline has not been reached';
IF v_case.state NOT IN ('launched','locked') → RAISE EXCEPTION 'invalid state for poster reveal: %', v_case.state;

-- Score each active investigation independently
FOR v_inv IN SELECT * FROM investigations WHERE case_id=p_case_id AND status='active' LOOP
  PERFORM private.do_reveal_impl_v3(p_case_id, v_inv.investigation_id);
END LOOP;

-- Mark case revealed ONLY after all investigations scored
UPDATE cases SET state='revealed', revealed_at=clock_timestamp() WHERE id=p_case_id;
```

---

### `private.reveal_case_service(p_case_id uuid)` — service-scheduler entry point

```
SECURITY DEFINER, SET search_path = ''

SELECT * FROM cases WHERE id = p_case_id FOR UPDATE;
IF NOT FOUND → RAISE EXCEPTION 'case not found';
IF v_case.state != 'locked' → RAISE EXCEPTION 'service reveal requires locked state (current: %)', v_case.state;

FOR v_inv IN SELECT * FROM investigations WHERE case_id=p_case_id AND status='active' LOOP
  PERFORM private.do_reveal_impl_v3(p_case_id, v_inv.investigation_id);
END LOOP;

UPDATE cases SET state='revealed', revealed_at=clock_timestamp() WHERE id=p_case_id;
```

Granted to `service_role` only. Revoked from `authenticated`.

---

### `private.do_reveal_impl_v3(p_case_id uuid, p_investigation_id uuid)` — shared scoring engine

```
SECURITY DEFINER, SET search_path = ''
-- Caller holds FOR UPDATE lock on cases. This function does NOT update cases.state.
-- Caller is responsible for setting state='revealed' after iterating all investigations.

-- Read case (already locked by caller; plain SELECT)
-- Read case_secrets
-- Pre-normalize canonical answers
-- Count effective eligible investigation_members (eligibility_status = 'eligible' in this investigation)
-- Create score_run (revision = MAX revision for this investigation + 1 OR 1 if none)
-- Create temp table tmp_first_correct (player_id, race, ga_id, seq)
-- FOR each guess_attempt in this case ordered by receipt_sequence:
--   Filter: only players who are investigation_members with eligibility_status = 'eligible'
--           in p_investigation_id
--   Judge attempt (what/where); update tmp_first_correct
--   INSERT guess_judgment (with score_run_id, investigation_id)
-- Compute ordinal ranks; INSERT score_events for all eligible members
-- DROP temp table
-- No UPDATE to cases table.
```

---

### `public.cancel_case(p_case_id uuid, p_reason text)` — poster or group owner

```
SECURITY DEFINER, SET search_path = ''

IF NOT EXISTS (profiles WHERE id=auth_uid() AND is_active=true) → RAISE EXCEPTION 'account is inactive';
SELECT * FROM cases WHERE id=p_case_id FOR UPDATE;
IF NOT FOUND → RAISE EXCEPTION 'case not found';

IF v_case.poster_id != auth_uid() AND NOT EXISTS (
  SELECT 1 FROM group_members gm
  JOIN investigations i ON i.group_id = gm.group_id
  WHERE i.case_id = p_case_id AND gm.player_id = auth_uid() AND gm.role = 'owner'
) → RAISE EXCEPTION 'only the poster or a group owner can cancel a case';

IF v_case.state NOT IN ('draft','ready','launched') →
  RAISE EXCEPTION 'case cannot be cancelled in state %', v_case.state;
  -- locked and revealed are terminal; cancelled is already done

UPDATE cases
SET state='cancelled', cancelled_at=clock_timestamp(), cancellation_reason=p_reason
WHERE id=p_case_id;

-- Cancel all active investigations for this case
UPDATE investigations
SET status='cancelled', cancelled_at=clock_timestamp(), cancellation_reason='Case cancelled'
WHERE case_id=p_case_id AND status='active';
```

---

### `public.submit_guess(p_case_id uuid, p_investigation_id uuid, p_race text, p_guess text, p_idempotency_key uuid, p_client_submitted_at timestamptz)` — detective

```
SECURITY DEFINER, SET search_path = ''

IF NOT EXISTS (profiles WHERE id=auth_uid() AND is_active=true AND onboarding_complete=true)
  → RAISE EXCEPTION 'account not eligible';

-- Read case (no FOR UPDATE; receipt_sequence trigger handles ordering)
SELECT state, deadline_at FROM cases WHERE id=p_case_id;
IF NOT FOUND → RAISE EXCEPTION 'case not found';
IF v_case.state != 'launched' → RAISE EXCEPTION 'case is not accepting guesses (state: %)', v_case.state;
IF clock_timestamp() > v_case.deadline_at → RAISE EXCEPTION 'deadline has passed';

-- Validate caller is eligible member of this investigation
IF NOT EXISTS (
  SELECT 1 FROM investigation_members
  WHERE investigation_id = p_investigation_id
    AND player_id = auth_uid()
    AND eligibility_status = 'eligible'
) → RAISE EXCEPTION 'caller is not an eligible member of this investigation';

-- Verify investigation belongs to this case
IF NOT EXISTS (
  SELECT 1 FROM investigations
  WHERE investigation_id = p_investigation_id AND case_id = p_case_id AND status = 'active'
) → RAISE EXCEPTION 'investigation not found or not active for this case';

-- Race validation
IF p_race NOT IN ('what','where') → RAISE EXCEPTION 'invalid race';

-- Idempotency check
IF EXISTS (
  SELECT 1 FROM guess_attempts
  WHERE case_id = p_case_id AND player_id = auth_uid() AND race = p_race
    AND idempotency_key = p_idempotency_key
) → RETURN (existing row); -- same key: safe replay

-- Conflict check (same player+case+race, different key)
IF EXISTS (
  SELECT 1 FROM guess_attempts
  WHERE case_id = p_case_id AND player_id = auth_uid() AND race = p_race
) → RAISE EXCEPTION 'a guess for this race has already been submitted';
  -- The UNIQUE(case_id, player_id, race) constraint also enforces this at the DB level

-- INSERT guess_attempts
-- Trigger set_guess_receipt_fields fires: assigns receipt_sequence, validates state='launched'
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
SECURITY DEFINER, SET search_path = ''
```

**Validation order — authorization before idempotency:**

```
v_now := clock_timestamp();

Step 1 — Input shape (no DB reads)
  a. Duplicate values in p_group_ids → RAISE 'FK_INVALID_INPUT'
  b. array_length(p_group_ids, 1) not in 1–10 → RAISE 'FK_INVALID_INPUT'
  c. p_duration_seconds not in 3600–86400 or not % 3600 → RAISE 'FK_INVALID_INPUT'

Step 2 — Actor authorization
  a. profiles: is_active=true, onboarding_complete=true, is_suspended=false → else RAISE 'FK_FORBIDDEN'
  b. deletion_log: status IN ('pending','database_prepared','auth_deleted','failed') → RAISE 'FK_FORBIDDEN'
     (no deletion_log row = safe; status='complete' = safe)

Step 3 — Lock case and validate ownership
  SELECT id, poster_id, state, deadline_at FROM cases WHERE id=p_case_id FOR UPDATE;
  IF NOT FOUND OR poster_id != p_actor_id → RAISE 'FK_NOT_FOUND'

Step 4 — Idempotency (ONLY reached after ownership confirmed)
  IF v_case.state = 'launched' THEN
    existing_groups := SELECT group_id FROM investigations WHERE case_id=p_case_id ORDER BY group_id;
    existing_duration := EXTRACT(EPOCH FROM (v_case.deadline_at - v_case.posted_at));
    IF existing_groups = p_group_ids sorted AND existing_duration = p_duration_seconds THEN
      RETURN QUERY SELECT investigation_id, group_id FROM investigations WHERE case_id=p_case_id;
      RETURN;
    ELSE
      RAISE EXCEPTION 'FK_WRONG_STATE: case already launched with different parameters';
    END IF;
  END IF;

Step 5 — Require ready
  IF v_case.state != 'ready' → RAISE 'FK_WRONG_STATE'

Step 6 — Validate case_secrets
  case_secrets: canonical_dish, canonical_restaurant, display_dish, display_restaurant
                all NOT NULL and non-empty → else RAISE 'FK_WRONG_STATE'

Step 7 — Validate media
  cases.media_object_id IS NOT NULL AND media_objects.status = 'ready' → else RAISE 'FK_WRONG_STATE'

Step 8 — No active upload sessions
  upload_sessions: status IN ('pending','processing','sanitized') for this case_id → RAISE 'FK_WRONG_STATE'

Step 9 — Per-group validation
  For each group_id in p_group_ids:
    group exists, archived_at IS NULL → else RAISE 'FK_NOT_FOUND'
    actor is a group_member → else RAISE 'FK_NOT_FOUND'
```

**Writes (atomic):**

```
UPDATE cases SET state='launched', posted_at=v_now,
  deadline_at = v_now + (p_duration_seconds || ' seconds')::interval,
  duration_seconds = p_duration_seconds
WHERE id=p_case_id;

For each group_id in p_group_ids:
  INSERT INTO investigations (case_id, group_id) VALUES (p_case_id, group_id)
  ON CONFLICT (case_id, group_id) DO NOTHING RETURNING investigation_id → v_inv_id

  INSERT INTO investigation_members (investigation_id, player_id,
    snapshot_display_name, snapshot_avatar_color, snapshot_avatar_media_object_id)
  SELECT v_inv_id, gm.player_id, p.display_name, p.avatar_color, p.avatar_media_object_id
  FROM group_members gm JOIN profiles p ON p.id = gm.player_id
  WHERE gm.group_id = group_id
    AND gm.player_id != p_actor_id
    AND p.is_active = true AND p.onboarding_complete = true AND p.is_suspended = false
    AND NOT EXISTS (SELECT 1 FROM user_blocks ub
      WHERE (ub.blocker_id=p_actor_id AND ub.blocked_id=gm.player_id)
         OR (ub.blocker_id=gm.player_id AND ub.blocked_id=p_actor_id))
  ON CONFLICT DO NOTHING;

  IF (SELECT count(*) FROM investigation_members WHERE investigation_id=v_inv_id) < 1 THEN
    RAISE EXCEPTION 'FK_NO_ELIGIBLE_DETECTIVES: group % has no eligible members', group_id;
  END IF;

RETURN QUERY SELECT investigation_id, group_id FROM investigations WHERE case_id=p_case_id;
```

---

## 19. RLS — Guess Visibility

### Poster visibility
```sql
CREATE POLICY guess_poster_view ON public.guess_attempts AS PERMISSIVE FOR SELECT
USING (
  private.is_case_poster(case_id)
  AND EXISTS (SELECT 1 FROM public.cases WHERE id=guess_attempts.case_id
              AND state IN ('launched','locked','revealed'))
  AND EXISTS (SELECT 1 FROM public.profiles WHERE id=private.auth_uid() AND is_active=true)
);
```

### Own-guess — always visible, no state restriction
**Bill approved 2026-08-08: "Let them see the guess. Less testing and there is no downside. It was their guess."**
```sql
CREATE POLICY guess_own_view ON public.guess_attempts AS PERMISSIVE FOR SELECT
USING (
  player_id = private.auth_uid()
  AND EXISTS (SELECT 1 FROM public.profiles WHERE id=private.auth_uid() AND is_active=true)
);
-- No case state restriction. Includes cancelled cases.
```

### Co-investigator visibility (after reveal, same investigation)
```sql
CREATE POLICY guess_investigation_revealed_view ON public.guess_attempts AS PERMISSIVE FOR SELECT
USING (
  private.is_case_revealed(case_id)
  AND private.is_case_member(case_id)
  AND EXISTS (SELECT 1 FROM public.profiles WHERE id=private.auth_uid() AND is_active=true)
);
-- Guess attempts are case-scoped; player belongs to exactly one investigation per case.
```

---

## 20. Scoring — Active Investigations Only

`reveal_case()` and `reveal_case_service()` iterate only investigations where `status = 'active'`. Cancelled/tombstoned investigations receive no `score_runs`. `apply_correction()` similarly skips non-active investigations.

---

## 21. Migration Plan — Dependency-Ordered

`V4__case_investigation_schema.sql`. One `BEGIN`/`COMMIT`.

Step 24.1 = `V3__ugc_safety_moderation.sql` — must be applied and tagged first.

```
Phase 0 — Prerequisite guard
  DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.tables
      WHERE table_schema='private' AND table_name='moderators')
    THEN RAISE EXCEPTION 'V4 prerequisite failed: V3 (UGC Safety) must be applied first.'; END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.tables
      WHERE table_schema='public' AND table_name='content_reports')
    THEN RAISE EXCEPTION 'V4 prerequisite failed: V3 (UGC Safety) must be applied first.'; END IF;
  END $$;

Phase 1 — Rename challenges → cases
  1a. ALTER TABLE public.challenges RENAME TO cases
  1b. Extend state CHECK: add 'ready','launched','retired' (keep 'active' through Phase 15)
  1c. Verify rules_version_id DEFAULT = 'a0000000-0000-0000-0000-000000000001'
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
  4c. DROP TABLE public.eligible_participants

Phase 5 — Rename challenge_id on dependent tables
  5a. guess_attempts: RENAME → case_id; ADD idempotency_key nullable→backfill→NOT NULL;
      ADD UNIQUE (case_id, player_id, race)
  5b. exclusion_events: RENAME → case_id; ADD investigation_id nullable→backfill→NOT NULL;
      DROP CONSTRAINT (by name from catalog); ADD UNIQUE (investigation_id, player_id);
      ADD cross-record integrity trigger
  5c. clues: RENAME → case_id
  5d. comments: RENAME → case_id; ADD investigation_id nullable→backfill→NOT NULL;
      ADD cross-record integrity trigger
  5e. challenge_answer_aliases → case_answer_aliases: RENAME TABLE; RENAME COLUMN → case_id
  5f. correction_events: RENAME → case_id; DROP resulting_score_run_id column
  5g. score_runs: RENAME → case_id; ADD investigation_id nullable→backfill→NOT NULL;
      DROP CONSTRAINT (by name); ADD UNIQUE (investigation_id, revision_number);
      ADD cross-record integrity trigger
  5h. guess_judgments: RENAME → case_id; ADD investigation_id nullable→backfill→NOT NULL
  5i. score_events: RENAME → case_id; ADD investigation_id nullable→backfill→NOT NULL
  5j. reactions: ADD investigation_id nullable; backfill via investigations.case_id;
      RAISE EXCEPTION if any NULL remains post-backfill; NOT NULL;
      DROP old challenge_id FK (by constraint name); DROP challenge_id column;
      ADD investigation_id FK; DROP old UNIQUE (by constraint name);
      CREATE UNIQUE (investigation_id, player_id, emoji)

Phase 6 — current_score_events VIEW
  6a. DROP VIEW public.current_score_events
  6b. CREATE VIEW WITH (security_invoker = true) — investigation-scoped
  6c. GRANT SELECT TO authenticated

Phase 7 — Upload sessions
  7a. RENAME COLUMN challenge_id → case_id; update FK to cases
  7b. DROP INDEX upload_sessions_one_active_per_challenge
  7c. CREATE UNIQUE INDEX upload_sessions_one_active_per_case
  7d. UPDATE upload_sessions SET storage_path = replace(storage_path, 'challenges/', 'cases/')

Phase 8 — RLS helper function rebuilds
  private.is_challenge_group_member: DROP (replaced by two new helpers below)
  private.is_case_member (CREATE — case-level helper)
  private.is_investigation_member (CREATE — investigation-level helper)
  private.is_case_poster: DROP old, recreate (from is_challenge_poster)
  private.is_case_revealed: DROP old, recreate (from is_challenge_revealed)
  private.is_investigation_eligible: DROP old, recreate (from is_eligible_non_excluded)
  private.caller_has_guessed: CREATE OR REPLACE

Phase 9 — Operational function rebuilds
  private.prepare_account_deletion: full rebuild per §16
  private.mark_auth_deleted: CREATE OR REPLACE
  private.mark_storage_cleaned: CREATE OR REPLACE
  private.record_deletion_failure: CREATE OR REPLACE
  private.get_storage_keys_for_deletion: CREATE OR REPLACE
  private.do_reveal_impl_v3: DROP do_reveal_impl + CREATE do_reveal_impl_v3
  private.reveal_case_service: DROP reveal_challenge_service + CREATE reveal_case_service
  public.lock_case: DROP lock_challenge + CREATE lock_case
  public.reveal_case: DROP reveal_challenge + CREATE reveal_case
  public.cancel_case: DROP cancel_challenge + CREATE cancel_case
  public.apply_correction: CREATE OR REPLACE
  public.soft_delete_comment: CREATE OR REPLACE
  DROP public.activate_challenge

Phase 10 — Step 24.1 function updates
  approve_photo, reject_photo: CREATE OR REPLACE with V3 extensions (§13)
  claim_moderation_media_cleanup, get_pending_review_media, get_reported_media: CREATE OR REPLACE
  get_media_serve_authorization, get_moderation_queue: CREATE OR REPLACE
  report_content, remove_content, remove_media: CREATE OR REPLACE
  private.can_view_case: DROP can_view_challenge + CREATE can_view_case
  private.can_viewer_access_case: DROP + CREATE
  private.has_block_with_poster: CREATE OR REPLACE

Phase 11 — V2 function updates
  reserve_upload_session: DROP + recreate as (p_case_id, ...)
  finalize_upload_session: CREATE OR REPLACE
  reveal_case_service_wrapper: DROP reveal_challenge_service_wrapper + CREATE reveal_case_service_wrapper
  prepare_account_deletion_wrapper: CREATE OR REPLACE

Phase 12 — Trigger rebuilds (see §15)
  Drop all old challenge-named triggers and functions
  Recreate all on cases/case_secrets/case_answer_aliases with updated names and state values
  -- challenge_create_fields → case_create_fields (function: set_case_create_fields)
  -- challenge_protect_fields → case_protect_fields (function: protect_case_authority_fields)
  -- challenge_secrets_guard → case_secrets_guard (guard_answer_edits updated)
  -- challenge_secrets_timestamps → case_secrets_timestamps (set_case_secret_timestamps)
  -- alias_guard_insert/alias_guard_update → recreate on case_answer_aliases (guard_alias_edits)
  -- guess_receipt → recreate (set_guess_receipt_fields: 'active' → 'launched')
  -- guess_judgment_consistency, score_event_consistency, exclusion_enforce: rebuilt
  -- comment_update_guard: CREATE OR REPLACE
  -- Step 24.1 triggers: recreate force_removal_fields_null, restrict_moderation_field_updates on cases
  -- V2 triggers: recreate check_launch_no_active_upload, check_launch_media_ready

Phase 13 — Index rebuilds (see §15)
  DROP old challenge-named indexes
  CREATE new case/investigation-named replacements

Phase 14 — RLS policies (see §15 + §19)
  Drop and recreate all policies on all affected tables
  Use is_case_member for case-level tables; is_investigation_member for investigation-level tables
  Apply profiles.is_active requirement everywhere
  Apply poster/own-guess/co-investigator visibility (§19)
  Update grants

Phase 15 — State conversion: active → launched
  15a. DISABLE TRIGGER case_protect_fields ON public.cases
  15b. UPDATE public.cases SET state='launched' WHERE state='active'
  15c. ENABLE TRIGGER case_protect_fields ON public.cases
  15d. ALTER TABLE cases DROP CONSTRAINT cases_state_check;
       ALTER TABLE cases ADD CONSTRAINT cases_state_check
         CHECK (state IN ('draft','ready','launched','locked','revealed','retired','cancelled'));

Phase 16 — Partial index update
  16a. DROP INDEX one_active_challenge_per_poster
  16b. CREATE UNIQUE INDEX one_active_case_per_poster ON cases (poster_id)
       WHERE state IN ('draft','ready','launched','locked')

Phase 17 — Remove group_id from cases
  17a. pg_depend audit: zero objects reference cases.group_id
  17b. ALTER TABLE cases DROP CONSTRAINT challenges_group_id_fkey;
       -- PG does NOT rename constraints on table rename; actual catalog name is challenges_group_id_fkey
  17c. DROP INDEX idx_challenges_group_id
  17d. ALTER TABLE cases DROP COLUMN group_id

Phase 18 — New service functions (launch_case and submit_guess only)
  launch_case (per §18)
  submit_guess (per §17)
  -- lock_case and reveal_case were rebuilt in Phase 9; NOT repeated here.

Phase 19 — Grants, ownership, completion marker
  GRANT SELECT ON public.cases TO forkensics_rls_helper
  GRANT SELECT ON public.investigation_members TO forkensics_rls_helper
  GRANT UPDATE (moderator_removed_at, moderator_removal_action_id, state, cancellation_reason)
    ON public.cases TO forkensics_executor
  GRANT INSERT, UPDATE, DELETE ON public.investigations TO forkensics_executor
  GRANT INSERT, UPDATE ON public.investigation_members TO forkensics_executor
  All new/renamed function OWNER TO forkensics_executor assignments
  REVOKE temporary build-time privileges (pattern from V1 §9B)
  INSERT INTO schema_migrations marker
```

---

## 22. Acceptance Criteria (Summary — Key Items)

- Schema integrity: renamed columns present; no `challenge_id` in listed tables; `cases.rules_version_id` column DEFAULT present; `created_at` uses `clock_timestamp()`; `media_object_id ON DELETE RESTRICT`; `one_active_case_per_poster` predicate correct; single named state constraint only (no inline CHECK on column)
- `state = 'active'` rejected by CHECK post-migration
- `approve_photo()`: media → ready; case draft → ready atomically
- `reject_photo()`: media → rejected; `cases.media_object_id` cleared; case stays draft
- `claim_moderation_media_cleanup()`: returns rejected/removed; original key not returned
- `lock_case()`: rejects before `deadline_at`; rejects non-launched; uses `cases.state` column
- `reveal_case()` poster: deadline restriction enforced; scores all active investigations; updates case state after last investigation
- `reveal_case_service()`: locked state only; same scoring loop
- `do_reveal_impl_v3()`: does NOT update cases.state
- `launch_case()` auth-before-idempotency: non-poster cannot reach idempotency path; test required
- `launch_case()` idempotency: same poster, same groups + duration → return existing rows; different params → FK_WRONG_STATE
- `launch_case()` deletion guard: `status IN ('pending','database_prepared','auth_deleted','failed')` → rejected
- `submit_guess()`: same idempotency_key → existing row; different key, same race → rejected; past deadline → rejected; non-eligible → rejected
- `cancel_case()`: cancels case + all active investigations; rejected for locked/revealed states
- RLS cross-Table isolation: member of Table A cannot read Table B's comments, reactions, members, or scores for the same case — test required
- Poster sees guesses during launched/locked/revealed; not before
- Own-guess always visible (including cancelled cases) — no state restriction
- Account deletion: suspended member skipped in group successor query; test required; `database_prepared` set only after all 8 steps succeed
- `current_score_events` VIEW: `WITH (security_invoker = true)`; investigation-scoped
- Phase 0 guard: EXCEPTION if V3 tables absent
- All 21 unchanged V2 functions pass existing test groups after migration

---

## 23. Out of Scope

Push notifications, feed queries, monthly leaderboard tables, admin UI, Edge Function implementations, `case_secrets → private` schema, Orders To Go (FEAT-001), retired-state archival, per-comment reactions.

---

*Ready for review by Bill, Claude, and Codex. No migration code written until all three parties approve.*
