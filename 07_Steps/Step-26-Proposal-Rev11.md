# Step 26 Proposal — Case / Investigation Schema
**Revision:** 11  
**Status:** DRAFT — awaiting approval from Bill, Claude, and Codex before any code is written  
**Prerequisites:** Step 25 merged (`v0.2.0-upload-sessions`); Step 24.1 merged as `V3__ugc_safety_moderation.sql` and tagged before this migration runs  
**Supersedes:** Rev 10 (rejected — GPT review, 3 blockers)

---

## Changes From Rev 10

| Blocker | Fix |
|---|---|
| 1 | `remove_content()` and `remove_media()` moved to `service_role` only — NOT `authenticated`. RLS helpers in `private` schema require `GRANT USAGE ON SCHEMA private` and explicit `GRANT EXECUTE` to `authenticated` (since policies invoke SECURITY DEFINER functions). `SELECT` grants on `investigations` and `investigation_members` added for `authenticated`, `forkensics_rls_helper`, and `forkensics_executor`. Acceptance suite now includes exact `has_function_privilege()` and `has_table_privilege()` assertions. |
| 2 | Poster Table Talk access updated to read + participate: poster may INSERT comments and reactions, and soft-delete/withdraw their own comments and reactions. Poster still cannot INSERT into `investigation_members`, scoring tables, or judgment tables. `current_score_events` view: no RLS policy created on it — `security_invoker` propagates the poster policy from the underlying `score_events` table. |
| 3 | Cancelled-content guard in `report_content()` made conditional on a resolved `v_case_id`. Guard only executes `IF v_case_id IS NOT NULL`. `media_object` branch follows Step 24.1's exact six-step lock order: (1) provisional case lookup with no lock, (2) lock case, (3) recheck media linkage, (4) check cancelled state, (5) lock media, (6) validate media status. Case is always locked before media. |

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
| Poster in investigation_members | No. Excluded from every snapshot. Cannot score. |
| Poster Table Talk | Read + participate: poster may INSERT comments and reactions; soft-delete or withdraw their own. Cannot INSERT scores, judgments, or members. |
| Step 24.1 prerequisite | `V3__ugc_safety_moderation.sql` must be tagged before V4 runs |
| `challenge_answer_aliases` final name | `case_answer_aliases` |
| `launch_case()` auth | `p_actor_id = private.auth_uid()` enforced inside function. EXECUTE to `authenticated` only. |
| Moderation target type | `'challenge'` migrated to `'case'` via two-step constraint replace |
| New reports on cancelled cases | Rejected for all case-linked targets (`case`, `comment`, `clue`, `media_object`). Profile reports independent. Existing pending reports remain actionable. |
| Direct INSERT on guess_attempts | Revoked from `authenticated`, `anon`, `PUBLIC`. Only `forkensics_executor` retains INSERT. |
| `remove_content()` / `remove_media()` | `service_role` only. Not granted to `authenticated`. |

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

Valid statuses: `active`, `cancelled`, `tombstoned`. Deadline tracked on `cases.state` only. When all investigations are cancelled, `reveal_case()` scores nothing but still transitions `cases.state → 'revealed'`.

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

The poster (`cases.poster_id`) is **never inserted** into `investigation_members`. `launch_case()` filters `gm.player_id != poster_id` during the snapshot INSERT.

---

## 7. `public.exclusion_events` — Investigation-Scoped

State gate per reason (`enforce_exclusion_rules` trigger):
- `withdrew` / `removed`: `investigations.status = 'active' AND cases.state = 'launched'`
- `account_deleted`: `investigations.status = 'active' AND cases.state IN ('launched','locked')` (trusted executor path)

---

## 8. `public.guess_attempts`

```sql
-- V1 columns preserved + V4 additions:
--   idempotency_key    uuid NOT NULL
--   UNIQUE (case_id, player_id, race)
--   UNIQUE (case_id, player_id, idempotency_key)
-- Migration: idempotency_key nullable → backfill gen_random_uuid() → NOT NULL
--            Both UNIQUE indexes added after backfill.

-- GRANTS (Phase 20):
--   REVOKE INSERT ON guess_attempts FROM authenticated, anon, PUBLIC;
--   GRANT INSERT ON guess_attempts TO forkensics_executor;
--   GRANT SELECT ON guess_attempts TO authenticated;
```

---

## 9. Scoring Tables

`score_runs`, `correction_events`, `guess_judgments`, `score_events` — `challenge_id → case_id`; `investigation_id uuid NOT NULL` added to score_runs, guess_judgments, score_events. Unchanged structure otherwise.

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

**No RLS policy is created on `current_score_events`.** PostgreSQL does not support row-level security policies on views. Because the view is defined with `security_invoker = true`, the policies on the underlying `score_events` table — including the poster-access policy — apply automatically when `authenticated` queries the view.

---

## 10. `public.comments` and `public.reactions`

`challenge_id → case_id`. `investigation_id uuid NOT NULL` added (nullable → backfill → NOT NULL). Cross-record integrity triggers preserved. Step 24.1 moderation columns preserved.

---

## 11. `public.clues` and `public.case_answer_aliases`

`challenge_id → case_id`. `challenge_answer_aliases` renamed to `case_answer_aliases`.

---

## 12. `private.upload_sessions`

`challenge_id → case_id`. Both `original_storage_path` and `display_storage_path` updated (replace `'challenges/'` → `'cases/'`). No `storage_path` column exists.

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

| Case state | New reports accepted | Existing pending reports |
|---|---|---|
| `draft` | No | N/A |
| `ready` | Photo moderation queue only | Actionable |
| `launched` / `locked` / `revealed` / `retired` | Yes — all case-linked target types | Actionable |
| `cancelled` | **No** — all case-linked targets rejected | **Still actionable** |

Profile reports (`target_type = 'profile'`) are independent of case state. Always accepted.

### `report_content()` — cancelled case guard (V4, all case-linked targets)

Declare `v_case_id uuid := NULL` and `v_case record` before the target-type branch. Each branch sets `v_case_id` only if it resolves an owning case. The guard is conditional on `v_case_id IS NOT NULL`.

```sql
v_case_id uuid := NULL;
v_case    record;

IF p_target_type = 'case' THEN
  -- Lock case directly
  SELECT id, state INTO v_case
  FROM public.cases WHERE id = p_target_id FOR SHARE;
  IF FOUND THEN v_case_id := v_case.id; END IF;

ELSIF p_target_type = 'comment' THEN
  SELECT c.id, c.state INTO v_case
  FROM public.cases c
  JOIN public.comments cm ON cm.case_id = c.id
  WHERE cm.id = p_target_id FOR SHARE OF c;
  IF FOUND THEN v_case_id := v_case.id; END IF;

ELSIF p_target_type = 'clue' THEN
  SELECT c.id, c.state INTO v_case
  FROM public.cases c
  JOIN public.clues cl ON cl.case_id = c.id
  WHERE cl.id = p_target_id FOR SHARE OF c;
  IF FOUND THEN v_case_id := v_case.id; END IF;

ELSIF p_target_type = 'media_object' THEN
  -- Six-step lock order from Step 24.1 — case BEFORE media
  DECLARE v_provisional_case_id uuid;
  BEGIN
    -- Step 1: provisional case lookup (no lock)
    SELECT c.id INTO v_provisional_case_id
    FROM public.cases c
    WHERE c.media_object_id = p_target_id
    LIMIT 1;

    IF v_provisional_case_id IS NOT NULL THEN
      -- Step 2: lock case
      SELECT id, state INTO v_case
      FROM public.cases WHERE id = v_provisional_case_id FOR SHARE;

      -- Step 3: recheck media linkage after case lock
      IF EXISTS (
        SELECT 1 FROM public.cases
        WHERE id = v_provisional_case_id AND media_object_id = p_target_id
      ) THEN
        v_case_id := v_provisional_case_id;
        -- Step 4: cancelled state check (handled below, after this branch)
        -- Step 5: lock media (after cancelled check passes)
        -- Step 6: validate media status (continues in existing media report flow)
      END IF;
      -- If linkage check fails (media detached between steps 1 and 3),
      -- v_case_id remains NULL and the guard is skipped.
    END IF;
  END;

-- ELSIF p_target_type = 'profile': v_case_id remains NULL; guard skipped.
END IF;

-- Cancelled guard (conditional — only runs when owning case was resolved)
IF v_case_id IS NOT NULL AND v_case.state = 'cancelled' THEN
  RAISE EXCEPTION 'FK_INVALID_INPUT: cannot report content belonging to a cancelled case';
END IF;

-- For media_object: Step 5 (lock media) and Step 6 (validate media status)
-- continue here, within the broader report_content() flow, exactly as specified
-- in Step 24.1. The case lock acquired in Step 2 above is held for the
-- remainder of the transaction.
```

Pending reports created before cancellation remain in the queue and are fully actionable.

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

EXECUTE to `service_role` only.

### `get_moderation_queue` return contract V4

Returns `case_id uuid` (was `challenge_id`). `target_type` values `= 'case'` post-migration. EXECUTE to `service_role` only.

---

## 14. V2 Function Impact

Functions requiring body changes: `reserve_upload_session`, `finalize_upload_session`, `reveal_case_service_wrapper`, `prepare_account_deletion_wrapper`. All 21 other V2 functions: no body changes (verified from source).

V2 trigger functions renamed: `check_activation_no_active_upload → check_launch_no_active_upload`; `check_activation_media_ready → check_launch_media_ready`.

---

## 15. Complete V1 + Step 24.1 Object Inventory

### RLS Helper Functions (owned by `forkensics_rls_helper`)

| Function | V4 action |
|---|---|
| `private.auth_uid()`, `private.normalize_answer(text)`, `private.is_group_member(uuid)`, `private.is_group_member_with(uuid)` | No change |
| `private.is_challenge_group_member(uuid)` | DROP → replaced by `is_case_member` + `is_investigation_member` |
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

CREATE OR REPLACE FUNCTION private.is_case_poster_for_investigation(p_investigation_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.investigations i
    JOIN public.cases c ON c.id = i.case_id
    WHERE i.investigation_id = p_investigation_id
      AND c.poster_id = private.auth_uid()
  );
$$;
```

All `private` schema helpers: SECURITY DEFINER, OWNER = `forkensics_rls_helper`.

### Operational Functions (owned by `forkensics_executor`) — unchanged from Rev 10

See §17 (service contracts) and §21 (account deletion).

### Functions — Step 24.1 source

| Function | V4 action |
|---|---|
| `private.can_view_challenge(uuid)` | DROP + recreate as `private.can_view_case(uuid)` |
| `private.can_viewer_access_challenge(uuid, uuid)` | DROP + recreate as `private.can_viewer_access_case(uuid, uuid)` |
| `private.has_block_with_poster(uuid)` | CREATE OR REPLACE; `challenges → cases` |
| `public.approve_photo(uuid, uuid, text)` | CREATE OR REPLACE; V4 case-state extension |
| `public.reject_photo(uuid, uuid, text)` | CREATE OR REPLACE; V4 case-state extension |
| `public.claim_moderation_media_cleanup(int)` | CREATE OR REPLACE; `challenges → cases` |
| `public.get_media_serve_authorization(uuid, uuid)` | CREATE OR REPLACE; exact body per §13 |
| `public.get_moderation_queue()` | CREATE OR REPLACE; `challenge_id → case_id` |
| `public.get_pending_review_media(uuid)` | CREATE OR REPLACE; `challenge_id → case_id` |
| `public.get_reported_media(uuid)` | CREATE OR REPLACE; `challenge_id → case_id` |
| `public.report_content(text, uuid, text, text)` | CREATE OR REPLACE; exact guard per §13 |
| `public.remove_content(text, uuid, uuid, uuid, text)` | CREATE OR REPLACE; `'challenge' → 'case'`; **`service_role` only** |
| `public.remove_media(uuid, uuid, uuid, text)` | CREATE OR REPLACE; `challenges → cases`; **`service_role` only** |

---

## 16. Function Privilege Matrix

`REVOKE ALL ON FUNCTION ... FROM PUBLIC` before each selective grant.

### Public surface — `authenticated` callers

| Function | Granted to |
|---|---|
| `public.launch_case(uuid, uuid, uuid[], int)` | `authenticated` |
| `public.submit_guess(uuid, uuid, text, text, uuid, timestamptz)` | `authenticated` |
| `public.cancel_case(uuid, text)` | `authenticated` |
| `public.cancel_investigation(uuid, text)` | `authenticated` |
| `public.reveal_case(uuid)` | `authenticated` |
| `public.apply_correction(...)` | `authenticated` |
| `public.soft_delete_comment(uuid)` | `authenticated` |
| `public.report_content(text, uuid, text, text)` | `authenticated` |

### `service_role` only (NOT `authenticated`)

| Function | Notes |
|---|---|
| `public.lock_case(uuid)` | Scheduler |
| `private.reveal_case_service(uuid)` | Scheduler |
| `public.get_media_serve_authorization(uuid, uuid)` | Step 24.1 |
| `public.get_moderation_queue()` | Step 24.1 |
| `public.get_pending_review_media(uuid)` | Step 24.1 |
| `public.get_reported_media(uuid)` | Step 24.1 |
| `public.approve_photo(uuid, uuid, text)` | Step 24.1 |
| `public.reject_photo(uuid, uuid, text)` | Step 24.1 |
| `public.claim_moderation_media_cleanup(int)` | Step 24.1 |
| `public.remove_content(text, uuid, uuid, uuid, text)` | Step 24.1 — NOT `authenticated` |
| `public.remove_media(uuid, uuid, uuid, text)` | Step 24.1 — NOT `authenticated` |

### Internal — no client grant (executor path only)

`private.do_reveal_impl_v3`, `private.prepare_account_deletion`, `private.mark_auth_deleted`, `private.mark_storage_cleaned`, `private.record_deletion_failure`, `private.get_storage_keys_for_deletion`, `private.can_view_case`, `private.can_viewer_access_case`, `private.has_block_with_poster`.

### RLS helpers — schema usage + EXECUTE to `authenticated`

Because RLS policies invoke these SECURITY DEFINER functions, `authenticated` must hold `EXECUTE` (the DEFINER elevation handles the underlying data access, but the caller still needs invocation rights):

```sql
GRANT USAGE ON SCHEMA private TO authenticated;
GRANT USAGE ON SCHEMA private TO forkensics_rls_helper;
GRANT USAGE ON SCHEMA private TO forkensics_executor;

GRANT EXECUTE ON FUNCTION private.auth_uid()                             TO authenticated;
GRANT EXECUTE ON FUNCTION private.normalize_answer(text)                 TO authenticated;
GRANT EXECUTE ON FUNCTION private.is_group_member(uuid)                  TO authenticated;
GRANT EXECUTE ON FUNCTION private.is_group_member_with(uuid)             TO authenticated;
GRANT EXECUTE ON FUNCTION private.is_case_member(uuid)                   TO authenticated;
GRANT EXECUTE ON FUNCTION private.is_investigation_member(uuid)          TO authenticated;
GRANT EXECUTE ON FUNCTION private.is_case_poster(uuid)                   TO authenticated;
GRANT EXECUTE ON FUNCTION private.is_case_revealed(uuid)                 TO authenticated;
GRANT EXECUTE ON FUNCTION private.is_investigation_eligible(uuid)        TO authenticated;
GRANT EXECUTE ON FUNCTION private.is_case_poster_for_investigation(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION private.caller_has_guessed(uuid)               TO authenticated;
```

### Table grants — `investigations` and `investigation_members`

```sql
-- authenticated: SELECT for RLS policies and direct reads
GRANT SELECT ON public.investigations         TO authenticated;
GRANT SELECT ON public.investigation_members  TO authenticated;

-- forkensics_rls_helper: SELECT for helper function bodies
GRANT SELECT ON public.investigations         TO forkensics_rls_helper;
GRANT SELECT ON public.investigation_members  TO forkensics_rls_helper;

-- forkensics_executor: SELECT for function bodies; INSERT/UPDATE for mutation functions
GRANT SELECT, INSERT, UPDATE, DELETE ON public.investigations        TO forkensics_executor;
GRANT SELECT, INSERT, UPDATE         ON public.investigation_members TO forkensics_executor;

-- guess_attempts: INSERT revoked from clients
REVOKE INSERT ON public.guess_attempts FROM authenticated, anon, PUBLIC;
GRANT  INSERT ON public.guess_attempts TO forkensics_executor;
GRANT  SELECT ON public.guess_attempts TO authenticated;
```

### Acceptance assertions (exact queries)

```sql
-- Helpers callable from policies
SELECT has_function_privilege('authenticated',
  'private.is_case_member(uuid)', 'EXECUTE');                    -- expect t
SELECT has_function_privilege('authenticated',
  'private.is_investigation_member(uuid)', 'EXECUTE');           -- expect t
SELECT has_function_privilege('authenticated',
  'private.is_case_poster_for_investigation(uuid)', 'EXECUTE');  -- expect t
SELECT has_function_privilege('authenticated',
  'private.auth_uid()', 'EXECUTE');                              -- expect t

-- New tables readable by authenticated
SELECT has_table_privilege('authenticated',
  'public.investigations', 'SELECT');                            -- expect t
SELECT has_table_privilege('authenticated',
  'public.investigation_members', 'SELECT');                     -- expect t

-- guess_attempts INSERT locked
SELECT NOT has_table_privilege('authenticated',
  'public.guess_attempts', 'INSERT');                            -- expect t
-- executor can insert
SELECT has_table_privilege('forkensics_executor',
  'public.guess_attempts', 'INSERT');                            -- expect t

-- remove_content and remove_media: service_role only
SELECT has_function_privilege('service_role',
  'public.remove_content(text,uuid,uuid,uuid,text)', 'EXECUTE'); -- expect t
SELECT NOT has_function_privilege('authenticated',
  'public.remove_content(text,uuid,uuid,uuid,text)', 'EXECUTE'); -- expect t
SELECT has_function_privilege('service_role',
  'public.remove_media(uuid,uuid,uuid,text)', 'EXECUTE');        -- expect t
SELECT NOT has_function_privilege('authenticated',
  'public.remove_media(uuid,uuid,uuid,text)', 'EXECUTE');        -- expect t

-- lock_case: service_role only
SELECT has_function_privilege('service_role',
  'public.lock_case(uuid)', 'EXECUTE');                          -- expect t
SELECT NOT has_function_privilege('authenticated',
  'public.lock_case(uuid)', 'EXECUTE');                          -- expect t

-- launch_case: authenticated only (not service_role)
SELECT has_function_privilege('authenticated',
  'public.launch_case(uuid,uuid,uuid[],integer)', 'EXECUTE');    -- expect t
```

---

## 17. Service Function Contracts

### `public.lock_case(p_case_id uuid)` — service-role only

```
SELECT * FROM cases WHERE id=p_case_id FOR UPDATE;
IF NOT FOUND → EXCEPTION;
IF clock_timestamp() < deadline_at → EXCEPTION 'deadline has not been reached';
IF v_case.state != 'launched' → EXCEPTION 'lock requires launched state';
UPDATE cases SET state='locked', locked_at=clock_timestamp() WHERE id=p_case_id;
```

### `public.reveal_case(p_case_id uuid)` — authenticated poster

```
SELECT * FROM cases WHERE id=p_case_id FOR UPDATE;
IF auth_uid() IS NULL → EXCEPTION ERRCODE 42501;
IF profile not active → EXCEPTION;
IF poster_id != auth_uid() → EXCEPTION;
IF clock_timestamp() < deadline_at → EXCEPTION;
IF state NOT IN ('launched','locked') → EXCEPTION;

FOR v_inv IN (active investigations) LOOP
  PERFORM private.do_reveal_impl_v3(p_case_id, v_inv.investigation_id);
END LOOP;
-- do_reveal_impl_v3 does NOT update cases.state

UPDATE cases SET state='revealed', revealed_at=clock_timestamp() WHERE id=p_case_id;
```

### `private.reveal_case_service(p_case_id uuid)` — service-role only

Same loop; requires `state = 'locked'`.

### `private.do_reveal_impl_v3(p_case_id uuid, p_investigation_id uuid)`

Caller holds FOR UPDATE on cases. Does NOT update `cases.state`. Scores only `eligibility_status = 'eligible'` members.

### `public.cancel_case(p_case_id uuid, p_reason text)` — poster ONLY

```
IF profile not active → EXCEPTION;
SELECT * FROM cases WHERE id=p_case_id FOR UPDATE;
IF poster_id != auth_uid() → EXCEPTION 'only the poster can cancel a case';
IF state NOT IN ('draft','ready','launched') → EXCEPTION;

-- Deadline guard: prevent cancellation after guesses have closed
IF state = 'launched' AND clock_timestamp() >= deadline_at THEN
  RAISE EXCEPTION 'cancellation deadline has passed';
END IF;

UPDATE cases SET state='cancelled', cancelled_at=clock_timestamp(),
  cancellation_reason=p_reason WHERE id=p_case_id;
UPDATE investigations SET status='cancelled', cancelled_at=clock_timestamp(),
  cancellation_reason='Case cancelled' WHERE case_id=p_case_id AND status='active';
```

### `public.cancel_investigation(p_investigation_id uuid, p_reason text)` — poster or Table owner

```
IF NOT EXISTS (profiles WHERE id=auth_uid() AND is_active=true AND is_suspended=false)
  → EXCEPTION 'suspended or inactive account';

SELECT i.*, c.poster_id, c.state AS case_state, c.deadline_at
FROM investigations i JOIN cases c ON c.id=i.case_id
WHERE i.investigation_id=p_investigation_id FOR UPDATE;
IF NOT FOUND → EXCEPTION;

IF v_case_state != 'launched' → EXCEPTION 'investigation can only be cancelled while case is launched';

-- Deadline guard
IF clock_timestamp() >= v_deadline_at THEN
  RAISE EXCEPTION 'cancellation deadline has passed';
END IF;

IF v_case.poster_id != auth_uid() AND NOT EXISTS (
  SELECT 1 FROM group_members
  WHERE group_id=v_inv.group_id AND player_id=auth_uid() AND role='owner'
) → EXCEPTION 'only the poster or Table owner can cancel this investigation';

IF v_inv.status != 'active' → EXCEPTION 'investigation is not active';

UPDATE investigations SET status='cancelled', cancelled_at=clock_timestamp(),
  cancellation_reason=p_reason WHERE investigation_id=p_investigation_id;
```

### `public.submit_guess(...)` — detective only

Full contract (unchanged from Rev 10, reproduced for completeness):

```
Step 1  — Actor authorization (is_active, onboarding_complete, is_suspended=false)
Step 1b — Poster rejection fast-path:
           IF EXISTS (cases WHERE id=p_case_id AND poster_id=auth_uid())
             → FK_FORBIDDEN
Step 2  — Race validation
Step 3  — Idempotency lookup (BEFORE state checks):
           Branch by race for comparison: 'what' checks dish_guess; 'where' checks restaurant_guess
Step 4  — Case lock; poster check (again, locked); state='launched'; clock < deadline_at
Step 5  — investigation_members eligibility + investigation active
Step 6  — Bilateral block check
Step 7  — INSERT (UNIQUE constraints enforced; concurrent duplicate → catch → reload → re-apply Step 3)
```

---

## 18. `launch_case()` — Full Contract

```
launch_case(p_actor_id uuid, p_case_id uuid, p_group_ids uuid[], p_duration_seconds integer)
RETURNS TABLE (investigation_id uuid, group_id uuid)
SECURITY DEFINER SET search_path = ''
```

EXECUTE to `authenticated`. Steps 1–10 unchanged from Rev 10.

**Step 11 — Snapshot (poster excluded):**
```sql
INSERT INTO investigation_members (...)
SELECT gm.player_id, p.display_name, p.avatar_color, p.avatar_media_object_id
FROM group_members gm JOIN profiles p ON p.id = gm.player_id
WHERE gm.group_id = v_group_id
  AND gm.player_id != p_actor_id   -- EXCLUDE POSTER
  AND p.is_active = true
  AND p.onboarding_complete = true
  AND p.is_suspended = false
  AND NOT EXISTS (
    SELECT 1 FROM user_blocks
    WHERE (blocker_id = p_actor_id AND blocked_id = gm.player_id)
       OR (blocker_id = gm.player_id AND blocked_id = p_actor_id)
  )
ON CONFLICT (investigation_id, player_id) DO NOTHING;

-- Require at least one detective per investigation
IF (SELECT count(*) FROM investigation_members WHERE investigation_id = v_inv_id) = 0 THEN
  RAISE EXCEPTION 'FK_INVALID_INPUT: group has no eligible detectives after excluding poster';
END IF;
```

---

## 19. RLS — Guess Visibility, Poster Access, and Table Talk Participation

### Own-guess — always visible
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

### Co-investigator revealed visibility — shared investigation + eligibility
```sql
CREATE POLICY guess_investigation_revealed_view ON public.guess_attempts AS PERMISSIVE FOR SELECT
USING (
  private.is_case_revealed(case_id)
  AND EXISTS (
    SELECT 1
    FROM public.investigation_members v_im
    JOIN public.investigation_members a_im ON a_im.investigation_id = v_im.investigation_id
    JOIN public.investigations i ON i.investigation_id = v_im.investigation_id
    WHERE v_im.player_id = private.auth_uid()
      AND v_im.eligibility_status = 'eligible'
      AND a_im.player_id = guess_attempts.player_id
      AND i.case_id = guess_attempts.case_id
  )
  AND EXISTS (SELECT 1 FROM public.profiles WHERE id=private.auth_uid() AND is_active=true)
);
```

### Poster investigation access — read + Table Talk participation

The poster is not in `investigation_members` but has approved access to Table Talk (read + participate) and read access to progress and revealed results for all investigations on their case.

**Read-only tables (poster can SELECT):**
`investigation_members` (roster), `score_runs`, `score_events`, `guess_judgments`

```sql
-- Example: score_events
CREATE POLICY score_events_poster_view ON public.score_events AS PERMISSIVE FOR SELECT
USING (
  private.is_case_poster_for_investigation(investigation_id)
  AND EXISTS (SELECT 1 FROM public.profiles WHERE id=private.auth_uid() AND is_active=true)
);
-- Same pattern for: investigation_members (SELECT only), score_runs, guess_judgments
```

Note: `current_score_events` is a view with `security_invoker = true` — the poster policy on `score_events` applies automatically. No separate policy is created on the view.

**Table Talk — poster participates (SELECT + INSERT + DELETE own):**

```sql
-- comments: poster SELECT
CREATE POLICY comments_poster_view ON public.comments AS PERMISSIVE FOR SELECT
USING (
  private.is_case_poster_for_investigation(investigation_id)
  AND EXISTS (SELECT 1 FROM public.profiles WHERE id=private.auth_uid() AND is_active=true)
);

-- comments: poster INSERT (Table Talk participation)
CREATE POLICY comments_poster_insert ON public.comments AS PERMISSIVE FOR INSERT
WITH CHECK (
  author_id = private.auth_uid()
  AND private.is_case_poster_for_investigation(investigation_id)
  AND EXISTS (SELECT 1 FROM public.profiles WHERE id=private.auth_uid() AND is_active=true)
);

-- comments: poster soft-delete their own (soft_delete_comment() sets deleted_at)
CREATE POLICY comments_poster_softdelete ON public.comments AS PERMISSIVE FOR UPDATE
USING (
  author_id = private.auth_uid()
  AND private.is_case_poster_for_investigation(investigation_id)
)
WITH CHECK (
  author_id = private.auth_uid()
);

-- reactions: poster SELECT
CREATE POLICY reactions_poster_view ON public.reactions AS PERMISSIVE FOR SELECT
USING (
  private.is_case_poster_for_investigation(investigation_id)
  AND EXISTS (SELECT 1 FROM public.profiles WHERE id=private.auth_uid() AND is_active=true)
);

-- reactions: poster INSERT
CREATE POLICY reactions_poster_insert ON public.reactions AS PERMISSIVE FOR INSERT
WITH CHECK (
  player_id = private.auth_uid()
  AND private.is_case_poster_for_investigation(investigation_id)
  AND EXISTS (SELECT 1 FROM public.profiles WHERE id=private.auth_uid() AND is_active=true)
);

-- reactions: poster DELETE their own
CREATE POLICY reactions_poster_delete ON public.reactions AS PERMISSIVE FOR DELETE
USING (
  player_id = private.auth_uid()
  AND private.is_case_poster_for_investigation(investigation_id)
);
```

**Poster cannot INSERT into:** `investigation_members`, `score_runs`, `guess_judgments`, `score_events`, `exclusion_events`, `correction_events`. No INSERT policies are created for these tables targeting the poster role.

---

## 20. Scoring — Active Investigations Only

`reveal_case()` / `reveal_case_service()` score only `status='active'` investigations. `do_reveal_impl_v3()` scores only `eligibility_status='eligible'` members. `apply_correction()` skips non-active investigations and non-eligible members.

---

## 21. Account Deletion — `private.prepare_account_deletion()` Full Rebuild

```
Forward-only guard.

Step 1 — Cancel draft/ready cases
  UPDATE cases SET state='cancelled', cancelled_at=clock_timestamp(),
    cancellation_reason='Account deleted'
  WHERE poster_id=p_profile_id AND state IN ('draft','ready');

Step 2 — Exclude eligible investigation_members (ALL case states)
  FOR each row WHERE player_id=p_profile_id AND eligibility_status='eligible':
    UPDATE investigation_members SET eligibility_status='account_deleted';
    IF investigations.status='active' AND cases.state IN ('launched','locked') THEN
      INSERT INTO exclusion_events (..., reason='account_deleted')
        ON CONFLICT DO NOTHING;
    END IF;

Step 3 — Transfer or archive owned groups
  Successor: is_active, onboarding_complete, not suspended, != p_profile_id, ORDER BY joined_at;
  IF found: demote → 'member', promote → 'owner'; ELSE archive group.

Step 4 — Archive profile identity
  INSERT INTO private.profile_archive ON CONFLICT DO NOTHING;

Step 5 — Anonymize profile row

Step 6 — Anonymize ALL investigation_members snapshot fields for this player

Step 7 — Tombstone all media objects

Step 8 — Mark DB step complete (only on success of all prior steps)
```

---

## 22. Migration Plan — Dependency-Ordered

`V4__case_investigation_schema.sql`. One `BEGIN`/`COMMIT`. Phases 0–18 unchanged from Rev 10.

**Phase 19 — New service functions:** `launch_case` (§18), `submit_guess` (§17).

**Phase 20 — Grants, privilege hardening, completion marker:**

```sql
-- Schema access
GRANT USAGE ON SCHEMA private TO authenticated, forkensics_rls_helper, forkensics_executor;

-- RLS helper EXECUTE grants (per §16)
GRANT EXECUTE ON FUNCTION private.auth_uid()                             TO authenticated;
GRANT EXECUTE ON FUNCTION private.normalize_answer(text)                 TO authenticated;
GRANT EXECUTE ON FUNCTION private.is_group_member(uuid)                  TO authenticated;
GRANT EXECUTE ON FUNCTION private.is_group_member_with(uuid)             TO authenticated;
GRANT EXECUTE ON FUNCTION private.is_case_member(uuid)                   TO authenticated;
GRANT EXECUTE ON FUNCTION private.is_investigation_member(uuid)          TO authenticated;
GRANT EXECUTE ON FUNCTION private.is_case_poster(uuid)                   TO authenticated;
GRANT EXECUTE ON FUNCTION private.is_case_revealed(uuid)                 TO authenticated;
GRANT EXECUTE ON FUNCTION private.is_investigation_eligible(uuid)        TO authenticated;
GRANT EXECUTE ON FUNCTION private.is_case_poster_for_investigation(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION private.caller_has_guessed(uuid)               TO authenticated;

-- New table grants (per §16)
GRANT SELECT ON public.investigations         TO authenticated, forkensics_rls_helper;
GRANT SELECT ON public.investigation_members  TO authenticated, forkensics_rls_helper;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.investigations        TO forkensics_executor;
GRANT SELECT, INSERT, UPDATE         ON public.investigation_members TO forkensics_executor;

-- guess_attempts INSERT lock
REVOKE INSERT ON public.guess_attempts FROM authenticated, anon, PUBLIC;
GRANT  INSERT ON public.guess_attempts TO forkensics_executor;
GRANT  SELECT ON public.guess_attempts TO authenticated;

-- cases
GRANT SELECT ON public.cases TO authenticated, forkensics_rls_helper;
GRANT UPDATE (...) ON public.cases TO forkensics_executor;

-- remove_content and remove_media: service_role only (revoke authenticated)
REVOKE EXECUTE ON FUNCTION public.remove_content(text,uuid,uuid,uuid,text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.remove_media(uuid,uuid,uuid,text)        FROM authenticated;
GRANT  EXECUTE ON FUNCTION public.remove_content(text,uuid,uuid,uuid,text) TO service_role;
GRANT  EXECUTE ON FUNCTION public.remove_media(uuid,uuid,uuid,text)        TO service_role;

-- lock_case: service_role only
REVOKE EXECUTE ON FUNCTION public.lock_case(uuid) FROM authenticated;
GRANT  EXECUTE ON FUNCTION public.lock_case(uuid) TO service_role;

-- Function OWNER assignments and remaining EXECUTE grants (per §16 full matrix)

INSERT schema_migrations marker;
```

---

## 23. Acceptance Criteria (Complete)

**Schema:**
- No `challenge_id` in any listed table; `one_active_case_per_poster` predicate correct; `'active'` state rejected post-migration
- `guess_attempts`: `UNIQUE (case_id, player_id, race)` and `UNIQUE (case_id, player_id, idempotency_key)` both present
- `investigation_members`: `SELECT count(*) FROM investigation_members im JOIN cases c ON c.poster_id = im.player_id JOIN investigations i ON i.investigation_id = im.investigation_id WHERE i.case_id = c.id` → 0 rows

**Privilege hardening (exact `has_*_privilege()` queries per §16):**
- All `GRANT EXECUTE` assertions for RLS helpers → `t`
- `has_table_privilege('authenticated', 'public.investigations', 'SELECT')` → `t`
- `has_table_privilege('authenticated', 'public.investigation_members', 'SELECT')` → `t`
- `NOT has_table_privilege('authenticated', 'public.guess_attempts', 'INSERT')` → `t`
- `has_table_privilege('forkensics_executor', 'public.guess_attempts', 'INSERT')` → `t`
- `NOT has_function_privilege('authenticated', 'public.remove_content(...)', 'EXECUTE')` → `t`
- `NOT has_function_privilege('authenticated', 'public.remove_media(...)', 'EXECUTE')` → `t`
- `NOT has_function_privilege('authenticated', 'public.lock_case(uuid)', 'EXECUTE')` → `t`
- `has_function_privilege('service_role', 'public.lock_case(uuid)', 'EXECUTE')` → `t`
- Direct `INSERT INTO guess_attempts` by `authenticated` user → `SQLSTATE 42501`

**Moderation:**
- New report on cancelled case (any case-linked target type) → rejected
- `media_object` branch: case locked before media (verified by step order in §13)
- Profile report → accepted regardless of case state
- `v_case_id IS NOT NULL` guard: profile target never triggers cancelled check
- Existing pending report on cancelled target → still actionable

**Poster:**
- Not in `investigation_members` (count = 0)
- `submit_guess()` → `FK_FORBIDDEN` at Step 1b and Step 4
- Solo-poster group → launch fails with zero-detectives exception
- Poster can INSERT comment in Table Talk; comment appears in SELECT
- Poster can INSERT reaction; reaction appears in SELECT
- Poster can soft-delete own comment (`soft_delete_comment()`)
- Poster cannot INSERT into `investigation_members`, `score_events`, `guess_judgments`
- `current_score_events` view: poster sees scores (via `security_invoker` + `score_events` policy); no policy created on the view itself

**Core function tests:** (unchanged from Rev 10)
- `cancel_case`: poster only; past-deadline launched → rejected
- `cancel_investigation`: `state != 'launched'` → rejected; past-deadline → rejected; suspended caller → rejected
- `reveal_case`: active investigations scored; `do_reveal_impl_v3` does NOT update `cases.state`
- All-investigations-cancelled: reveal still transitions to `'revealed'`

**Account deletion:**
- `eligibility_status = 'eligible'` → `'account_deleted'` for ALL investigations regardless of case state
- `apply_correction()` after player deleted → player gets 0 points
- `database_prepared` set only after all 8 steps succeed

**RLS:**
- Revealed-guess: excluded viewer cannot see (eligibility_status = 'eligible' required)
- Cross-Table isolation verified
- Poster policy on `score_events` propagates to `current_score_events` view (test: poster queries view, receives rows)

**V2:**
- All 21 unchanged V2 functions pass existing test groups after migration

---

## 24. Out of Scope

Push notifications, feed queries, monthly leaderboard tables, admin UI, Edge Function implementations, `case_secrets → private` schema, Orders To Go (FEAT-001), retired-state archival, per-comment reactions.

---

*Ready for review by Bill, Claude, and Codex. No migration code written until all three parties approve.*
