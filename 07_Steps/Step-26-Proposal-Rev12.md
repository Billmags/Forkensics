# Step 26 Proposal — Case / Investigation Schema
**Revision:** 12  
**Status:** DRAFT — awaiting approval from Bill, Claude, and Codex before any code is written  
**Prerequisites:** Step 25 merged (`v0.2.0-upload-sessions`); Step 24.1 merged as `V3__ugc_safety_moderation.sql` and tagged before this migration runs  
**Supersedes:** Rev 11 (rejected — GPT review, 3 blockers)

---

## Changes From Rev 11

| Blocker | Fix |
|---|---|
| 1 | `ALTER TABLE public.investigations ENABLE ROW LEVEL SECURITY` and same for `investigation_members` added to Phase 15. Exact member and poster SELECT policies defined for both tables. Outsider, cross-Table, excluded-member, and poster RLS tests added to §23. |
| 2 | `private.has_block_with_poster(uuid)` and `private.can_view_case(uuid)` added to the RLS helper EXECUTE grants for `authenticated` (both are called from policies). Dropped-and-recreated V2/V3 functions (`reserve_upload_session`, `reveal_case_service_wrapper`, `private.can_view_case`, `private.can_viewer_access_case`) now have explicit grant restoration in Phase 20. Exact `has_function_privilege()` assertions added for all newly required grants. |
| 3 | Media-object branch in `report_content()` corrected to the exact Step 24.1 six-step contract: (1) provisional lookup — missing raises `FK_NOT_FOUND`; (2) lock case `FOR UPDATE`; (3) recheck linkage — mismatch raises `FK_NOT_FOUND`; (4) check cancelled state AND `private.can_view_case()` while lock is held; (5) lock media `FOR UPDATE`; (6) validate `status = 'ready'`. `FOR SHARE` replaced with `FOR UPDATE` on case lock. Two-session race tests retained. |

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
| Poster Table Talk | Read + participate: INSERT comments and reactions; soft-delete/withdraw own. Cannot INSERT scores, judgments, or members. |
| Step 24.1 prerequisite | `V3__ugc_safety_moderation.sql` must be tagged before V4 runs |
| `challenge_answer_aliases` final name | `case_answer_aliases` |
| `launch_case()` auth | `p_actor_id = private.auth_uid()` enforced inside function. EXECUTE to `authenticated` only. |
| Moderation target type | `'challenge'` migrated to `'case'` via two-step constraint replace |
| New reports on cancelled cases | Rejected for all case-linked targets. Profile reports independent. Existing pending reports remain actionable. |
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

`challenge_id → case_id`. All V1 structure preserved.

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

ALTER TABLE public.investigations ENABLE ROW LEVEL SECURITY;
```

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

ALTER TABLE public.investigation_members ENABLE ROW LEVEL SECURITY;
```

The poster (`cases.poster_id`) is never inserted into `investigation_members`. `launch_case()` filters `gm.player_id != poster_id` during the snapshot INSERT.

---

## 7. RLS — `investigations` and `investigation_members`

### `public.investigations` policies

```sql
-- Member: player appears in investigation_members for this investigation
CREATE POLICY investigations_member_view ON public.investigations
  AS PERMISSIVE FOR SELECT
  USING (
    private.is_investigation_member(investigation_id)
    AND EXISTS (SELECT 1 FROM public.profiles
                WHERE id = private.auth_uid() AND is_active = true)
  );

-- Poster: poster of the owning case can see all investigations on their case
CREATE POLICY investigations_poster_view ON public.investigations
  AS PERMISSIVE FOR SELECT
  USING (
    private.is_case_poster_for_investigation(investigation_id)
    AND EXISTS (SELECT 1 FROM public.profiles
                WHERE id = private.auth_uid() AND is_active = true)
  );
```

### `public.investigation_members` policies

```sql
-- Member: player is snapshotted in the investigation (any eligibility_status)
CREATE POLICY investigation_members_member_view ON public.investigation_members
  AS PERMISSIVE FOR SELECT
  USING (
    private.is_investigation_member(investigation_id)
    AND EXISTS (SELECT 1 FROM public.profiles
                WHERE id = private.auth_uid() AND is_active = true)
  );

-- Poster: poster of the owning case sees the full roster
CREATE POLICY investigation_members_poster_view ON public.investigation_members
  AS PERMISSIVE FOR SELECT
  USING (
    private.is_case_poster_for_investigation(investigation_id)
    AND EXISTS (SELECT 1 FROM public.profiles
                WHERE id = private.auth_uid() AND is_active = true)
  );
```

All INSERT, UPDATE, DELETE on both tables: `forkensics_executor` only, via SECURITY DEFINER functions. No client-facing INSERT/UPDATE/DELETE policies are created on these tables.

---

## 8. `public.exclusion_events` — Investigation-Scoped

State gate per reason (`enforce_exclusion_rules` trigger):
- `withdrew` / `removed`: `investigations.status = 'active' AND cases.state = 'launched'`
- `account_deleted`: `investigations.status = 'active' AND cases.state IN ('launched','locked')`

---

## 9. `public.guess_attempts`

Grants in Phase 20:
```sql
REVOKE INSERT ON public.guess_attempts FROM authenticated, anon, PUBLIC;
GRANT  INSERT ON public.guess_attempts TO forkensics_executor;
GRANT  SELECT ON public.guess_attempts TO authenticated;
```

---

## 10. Scoring Tables and `current_score_events` VIEW

`score_runs`, `correction_events`, `guess_judgments`, `score_events` — `challenge_id → case_id`; `investigation_id uuid NOT NULL` added to score_runs, guess_judgments, score_events.

```sql
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

**No RLS policy on `current_score_events`.** `security_invoker = true` causes the view to execute under the caller's identity; policies on the underlying `score_events` table — including the poster-access policy — apply automatically.

---

## 11. `public.comments` and `public.reactions`

`challenge_id → case_id`. `investigation_id uuid NOT NULL` added.

---

## 12. `public.clues` and `public.case_answer_aliases`

`challenge_id → case_id`. `challenge_answer_aliases` renamed to `case_answer_aliases`.

---

## 13. `private.upload_sessions`

`challenge_id → case_id`. Both `original_storage_path` and `display_storage_path` path-replaced (`'challenges/' → 'cases/'`).

---

## 14. Media Moderation — Step 24.1 Contract Extensions

**`approve_photo()` V4 addition:**
```sql
UPDATE public.cases SET state='ready' WHERE media_object_id=p_media_object_id AND state='draft';
```

**`reject_photo()` V4 addition:**
```sql
UPDATE public.cases SET media_object_id=NULL WHERE media_object_id=p_media_object_id AND state='draft';
```

### Moderation State Matrix

| Case state | New reports accepted | Existing pending reports |
|---|---|---|
| `draft` | No | N/A |
| `ready` | Photo moderation queue only | Actionable |
| `launched` / `locked` / `revealed` / `retired` | Yes — all case-linked targets | Actionable |
| `cancelled` | **No** — all case-linked targets rejected | **Still actionable** |

Profile reports always accepted (independent of case state).

### `report_content()` — cancelled-case guard with exact lock contracts

```sql
v_case_id           uuid   := NULL;
v_case              record;
v_provisional_case_id uuid;
v_media             record;

IF p_target_type = 'case' THEN
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
  -- Step 1: provisional case lookup (no lock); missing → FK_NOT_FOUND
  SELECT id INTO v_provisional_case_id
  FROM public.cases WHERE media_object_id = p_target_id
  LIMIT 1;

  IF v_provisional_case_id IS NULL THEN
    RAISE EXCEPTION 'FK_NOT_FOUND: no case owns this media object';
  END IF;

  -- Step 2: lock case FOR UPDATE
  SELECT id, state INTO v_case
  FROM public.cases WHERE id = v_provisional_case_id
  FOR UPDATE;

  -- Step 3: recheck linkage after lock; mismatch → FK_NOT_FOUND
  IF NOT EXISTS (
    SELECT 1 FROM public.cases
    WHERE id = v_provisional_case_id AND media_object_id = p_target_id
  ) THEN
    RAISE EXCEPTION 'FK_NOT_FOUND: media linkage changed under concurrent update';
  END IF;

  v_case_id := v_provisional_case_id;

  -- Step 4: reject cancelled case AND verify caller can view it (lock held)
  IF v_case.state = 'cancelled' THEN
    RAISE EXCEPTION 'FK_INVALID_INPUT: cannot report content belonging to a cancelled case';
  END IF;
  IF NOT private.can_view_case(v_case_id) THEN
    RAISE EXCEPTION 'FK_FORBIDDEN: caller cannot access this case';
  END IF;

  -- Step 5: lock media FOR UPDATE (case already locked above)
  SELECT id, status INTO v_media
  FROM public.media_objects WHERE id = p_target_id
  FOR UPDATE;

  -- Step 6: validate media status
  IF v_media.status != 'ready' THEN
    RAISE EXCEPTION 'FK_INVALID_INPUT: media object is not in ready state';
  END IF;

-- profile: v_case_id remains NULL; guard below is skipped.
END IF;

-- Shared cancelled guard for case, comment, clue targets.
-- media_object already handled inline at Step 4 above; this guard is
-- a safe no-op for that path (state != 'cancelled' since Step 4 already raised).
IF v_case_id IS NOT NULL AND v_case.state = 'cancelled' THEN
  RAISE EXCEPTION 'FK_INVALID_INPUT: cannot report content belonging to a cancelled case';
END IF;
```

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

---

## 15. V2 Function Impact

### Dropped and recreated — require explicit grant restoration in Phase 20

| Function | Old name / signature | New name / signature | Grant |
|---|---|---|---|
| `reserve_upload_session` | `(p_challenge_id uuid, ...)` | `(p_case_id uuid, ...)` | `service_role` EXECUTE |
| `reveal_case_service_wrapper` | `reveal_challenge_service_wrapper(p_challenge_id uuid)` | `reveal_case_service_wrapper(p_case_id uuid)` | `service_role` EXECUTE |

### CREATE OR REPLACE — grants preserved automatically

`finalize_upload_session`, `prepare_account_deletion_wrapper`, and all 21 no-body-change V2 functions.

V2 trigger functions renamed: `check_activation_no_active_upload → check_launch_no_active_upload`; `check_activation_media_ready → check_launch_media_ready`. Recreated with same grant as originals.

---

## 16. Complete V1 + Step 24.1 Object Inventory

### RLS Helper Functions (owned by `forkensics_rls_helper`)

| Function | V4 action |
|---|---|
| `private.auth_uid()` | No change |
| `private.normalize_answer(text)` | No change |
| `private.is_group_member(uuid)` | No change |
| `private.is_group_member_with(uuid)` | No change |
| `private.is_challenge_group_member(uuid)` | DROP → replaced by `is_case_member` + `is_investigation_member` |
| `private.is_challenge_poster(uuid)` | DROP + recreate as `private.is_case_poster(uuid)` |
| `private.is_challenge_revealed(uuid)` | DROP + recreate as `private.is_case_revealed(uuid)` |
| `private.is_eligible_non_excluded(uuid)` | DROP + recreate as `private.is_investigation_eligible(uuid)` |
| `private.caller_has_guessed(uuid)` | CREATE OR REPLACE |
| `private.has_block_with_poster(uuid)` | CREATE OR REPLACE; `challenges → cases`; **EXECUTE to `authenticated`** (called from policies) |
| `private.can_view_challenge(uuid)` | DROP + recreate as `private.can_view_case(uuid)`; **EXECUTE to `authenticated` and `service_role`** (Step 24.1 grants preserved) |
| `private.can_viewer_access_challenge(uuid, uuid)` | DROP + recreate as `private.can_viewer_access_case(uuid, uuid)`; EXECUTE to `service_role` only |

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

---

## 17. Function Privilege Matrix

`REVOKE ALL ON FUNCTION ... FROM PUBLIC` before each selective grant.

### `authenticated` callers — public operational functions

| Function | Granted to |
|---|---|
| `public.launch_case(uuid, uuid, uuid[], integer)` | `authenticated` |
| `public.submit_guess(uuid, uuid, text, text, uuid, timestamptz)` | `authenticated` |
| `public.cancel_case(uuid, text)` | `authenticated` |
| `public.cancel_investigation(uuid, text)` | `authenticated` |
| `public.reveal_case(uuid)` | `authenticated` |
| `public.apply_correction(...)` | `authenticated` |
| `public.soft_delete_comment(uuid)` | `authenticated` |
| `public.report_content(text, uuid, text, text)` | `authenticated` |

### `service_role` only — moderation + scheduler

| Function |
|---|
| `public.lock_case(uuid)` |
| `private.reveal_case_service(uuid)` |
| `public.get_media_serve_authorization(uuid, uuid)` |
| `public.get_moderation_queue()` |
| `public.get_pending_review_media(uuid)` |
| `public.get_reported_media(uuid)` |
| `public.approve_photo(uuid, uuid, text)` |
| `public.reject_photo(uuid, uuid, text)` |
| `public.claim_moderation_media_cleanup(int)` |
| `public.remove_content(text, uuid, uuid, uuid, text)` — NOT `authenticated` |
| `public.remove_media(uuid, uuid, uuid, text)` — NOT `authenticated` |
| `public.reserve_upload_session(uuid, ...)` — restored after DROP+recreate |
| `public.reveal_case_service_wrapper(uuid)` — restored after DROP+recreate |

### Internal — no client grant

`private.do_reveal_impl_v3`, `private.prepare_account_deletion`, `private.mark_auth_deleted`, `private.mark_storage_cleaned`, `private.record_deletion_failure`, `private.get_storage_keys_for_deletion`, `private.can_viewer_access_case` (service_role only).

### RLS helpers — schema USAGE + EXECUTE to `authenticated`

```sql
GRANT USAGE ON SCHEMA private TO authenticated;
GRANT USAGE ON SCHEMA private TO forkensics_rls_helper;
GRANT USAGE ON SCHEMA private TO forkensics_executor;

-- All helpers called from RLS policies
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
GRANT EXECUTE ON FUNCTION private.has_block_with_poster(uuid)            TO authenticated;

-- can_view_case: Step 24.1 grants preserved (called from policies + service functions)
GRANT EXECUTE ON FUNCTION private.can_view_case(uuid)                    TO authenticated;
GRANT EXECUTE ON FUNCTION private.can_view_case(uuid)                    TO service_role;

-- can_viewer_access_case: service_role only (called from get_media_serve_authorization)
GRANT EXECUTE ON FUNCTION private.can_viewer_access_case(uuid, uuid)     TO service_role;
```

### Table grants

```sql
-- cases
GRANT SELECT ON public.cases TO authenticated, forkensics_rls_helper;
GRANT UPDATE (...) ON public.cases TO forkensics_executor;

-- investigations (new)
GRANT SELECT ON public.investigations TO authenticated, forkensics_rls_helper;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.investigations TO forkensics_executor;

-- investigation_members (new)
GRANT SELECT ON public.investigation_members TO authenticated, forkensics_rls_helper;
GRANT SELECT, INSERT, UPDATE ON public.investigation_members TO forkensics_executor;

-- guess_attempts
REVOKE INSERT ON public.guess_attempts FROM authenticated, anon, PUBLIC;
GRANT  INSERT ON public.guess_attempts TO forkensics_executor;
GRANT  SELECT ON public.guess_attempts TO authenticated;
```

### Acceptance assertions — exact queries

```sql
-- RLS helpers callable by authenticated
SELECT has_function_privilege('authenticated',
  'private.is_case_member(uuid)', 'EXECUTE');                              -- expect t
SELECT has_function_privilege('authenticated',
  'private.is_investigation_member(uuid)', 'EXECUTE');                     -- expect t
SELECT has_function_privilege('authenticated',
  'private.is_case_poster_for_investigation(uuid)', 'EXECUTE');            -- expect t
SELECT has_function_privilege('authenticated',
  'private.has_block_with_poster(uuid)', 'EXECUTE');                       -- expect t
SELECT has_function_privilege('authenticated',
  'private.can_view_case(uuid)', 'EXECUTE');                               -- expect t
SELECT has_function_privilege('service_role',
  'private.can_view_case(uuid)', 'EXECUTE');                               -- expect t
SELECT has_function_privilege('service_role',
  'private.can_viewer_access_case(uuid,uuid)', 'EXECUTE');                 -- expect t
SELECT NOT has_function_privilege('authenticated',
  'private.can_viewer_access_case(uuid,uuid)', 'EXECUTE');                 -- expect t

-- New tables readable by authenticated
SELECT has_table_privilege('authenticated',
  'public.investigations', 'SELECT');                                       -- expect t
SELECT has_table_privilege('authenticated',
  'public.investigation_members', 'SELECT');                               -- expect t
SELECT has_table_privilege('forkensics_rls_helper',
  'public.investigations', 'SELECT');                                       -- expect t
SELECT has_table_privilege('forkensics_rls_helper',
  'public.investigation_members', 'SELECT');                               -- expect t

-- guess_attempts INSERT locked
SELECT NOT has_table_privilege('authenticated',
  'public.guess_attempts', 'INSERT');                                       -- expect t
SELECT has_table_privilege('forkensics_executor',
  'public.guess_attempts', 'INSERT');                                       -- expect t

-- remove_content and remove_media: service_role only
SELECT has_function_privilege('service_role',
  'public.remove_content(text,uuid,uuid,uuid,text)', 'EXECUTE');           -- expect t
SELECT NOT has_function_privilege('authenticated',
  'public.remove_content(text,uuid,uuid,uuid,text)', 'EXECUTE');           -- expect t
SELECT has_function_privilege('service_role',
  'public.remove_media(uuid,uuid,uuid,text)', 'EXECUTE');                  -- expect t
SELECT NOT has_function_privilege('authenticated',
  'public.remove_media(uuid,uuid,uuid,text)', 'EXECUTE');                  -- expect t

-- lock_case: service_role only
SELECT has_function_privilege('service_role',
  'public.lock_case(uuid)', 'EXECUTE');                                     -- expect t
SELECT NOT has_function_privilege('authenticated',
  'public.lock_case(uuid)', 'EXECUTE');                                     -- expect t

-- launch_case: authenticated only
SELECT has_function_privilege('authenticated',
  'public.launch_case(uuid,uuid,uuid[],integer)', 'EXECUTE');              -- expect t

-- Restored V2 grants after DROP+recreate
SELECT has_function_privilege('service_role',
  'public.reveal_case_service_wrapper(uuid)', 'EXECUTE');                  -- expect t
-- reserve_upload_session — replace (...) with exact parameter list from V2 source
SELECT has_function_privilege('service_role',
  'public.reserve_upload_session(uuid,...)', 'EXECUTE');                   -- expect t
```

---

## 18. Service Function Contracts

### `public.lock_case(p_case_id uuid)` — service-role only

```
FOR UPDATE lock on cases; deadline check; state = 'launched' check;
UPDATE cases SET state='locked', locked_at=clock_timestamp();
```

### `public.reveal_case(p_case_id uuid)` — authenticated poster

```
FOR UPDATE lock; auth_uid check; poster check; deadline check; state IN ('launched','locked');
Loop active investigations → do_reveal_impl_v3 (does NOT update cases.state);
UPDATE cases SET state='revealed', revealed_at=clock_timestamp();
```

### `private.reveal_case_service(p_case_id uuid)` — service-role only

Same loop; requires `state = 'locked'`.

### `private.do_reveal_impl_v3(p_case_id uuid, p_investigation_id uuid)`

Caller holds FOR UPDATE on cases. Does NOT update `cases.state`. Scores only `eligibility_status = 'eligible'` members.

### `public.cancel_case(p_case_id uuid, p_reason text)` — poster ONLY

```
Active profile check;
FOR UPDATE lock; poster_id = auth_uid() check; state IN ('draft','ready','launched') check;
IF state = 'launched' AND clock_timestamp() >= deadline_at → EXCEPTION;
UPDATE cases state='cancelled'; UPDATE investigations status='cancelled' (active only);
```

### `public.cancel_investigation(p_investigation_id uuid, p_reason text)` — poster or Table owner

```
Suspended/inactive check;
FOR UPDATE lock (investigation + case join); state = 'launched' check;
clock_timestamp() >= deadline_at → EXCEPTION;
Poster or group owner check; status = 'active' check;
UPDATE investigations status='cancelled';
```

### `public.submit_guess(...)` — detective only

```
Step 1  — Active, onboarding_complete, not suspended
Step 1b — Fast-path poster reject (case lookup, no lock)
Step 2  — Race validation ('what' or 'where')
Step 3  — Idempotency lookup; if found: branch by race for comparison (dish_guess vs restaurant_guess);
           return or FK_CONFLICT; if new key but existing race → FK_CONFLICT
Step 4  — FOR SHARE lock on case; poster re-check (locked); state='launched'; clock < deadline_at
Step 5  — investigation_members eligibility='eligible'; investigation active for case
Step 6  — Bilateral block check with poster
Step 7  — INSERT; concurrent duplicate → catch unique violation → reload → re-apply Step 3
```

---

## 19. `launch_case()` — Full Contract

```
Steps 1–10 unchanged from Rev 11.

Step 11 — Snapshot (poster excluded):
  INSERT INTO investigation_members (player_id, ...)
  SELECT gm.player_id, p.display_name, ...
  FROM group_members gm JOIN profiles p ON p.id=gm.player_id
  WHERE gm.group_id=v_group_id
    AND gm.player_id != p_actor_id       -- EXCLUDE POSTER
    AND p.is_active=true AND p.onboarding_complete=true AND p.is_suspended=false
    AND no bilateral block with poster
  ON CONFLICT DO NOTHING;

  IF count(investigation_members for v_inv_id) = 0 THEN
    RAISE FK_INVALID_INPUT 'group has no eligible detectives after excluding poster';
  END IF;
```

---

## 20. RLS — Full Policy Set

### `public.guess_attempts`

Three policies (unchanged from Rev 11):
1. `guess_own_view` — own guess, always visible, no state restriction
2. `guess_poster_view` — poster, launched/locked/revealed
3. `guess_investigation_revealed_view` — co-investigator, revealed, eligibility_status='eligible' required

### `public.investigations` — see §7

### `public.investigation_members` — see §7

### Poster access to investigation-scoped tables (read + participate)

**SELECT only (poster reads but cannot write):**
- `score_runs`, `score_events` (view propagates via security_invoker), `guess_judgments`
- Poster policy on `investigation_members` already defined in §7.

```sql
-- Pattern for each read-only table:
CREATE POLICY {table}_poster_view ON public.{table} AS PERMISSIVE FOR SELECT
USING (
  private.is_case_poster_for_investigation(investigation_id)
  AND EXISTS (SELECT 1 FROM public.profiles WHERE id=private.auth_uid() AND is_active=true)
);
-- Applied to: score_runs, guess_judgments, score_events
-- NOT applied to current_score_events (view; no RLS policy created)
```

**SELECT + INSERT + DELETE/UPDATE for Table Talk:**

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

-- comments: poster soft-delete own (soft_delete_comment() sets deleted_at)
CREATE POLICY comments_poster_softdelete ON public.comments AS PERMISSIVE FOR UPDATE
USING (
  author_id = private.auth_uid()
  AND private.is_case_poster_for_investigation(investigation_id)
)
WITH CHECK (author_id = private.auth_uid());

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

-- reactions: poster DELETE own
CREATE POLICY reactions_poster_delete ON public.reactions AS PERMISSIVE FOR DELETE
USING (
  player_id = private.auth_uid()
  AND private.is_case_poster_for_investigation(investigation_id)
);
```

**Poster cannot INSERT into:** `investigation_members`, `exclusion_events`, `score_runs`, `guess_judgments`, `score_events`, `correction_events`. No INSERT policies for the poster role on these tables.

---

## 21. Scoring — Active Investigations Only

`reveal_case()` and `reveal_case_service()` loop over `status='active'` investigations only. `do_reveal_impl_v3()` scores only `eligibility_status='eligible'` members. `apply_correction()` skips non-active investigations and non-eligible members.

---

## 22. Account Deletion — `private.prepare_account_deletion()`

Eight steps (unchanged from Rev 11). Key: Step 2 marks `eligibility_status='account_deleted'` for ALL investigations regardless of case state; exclusion_events inserted only for active investigations in launched/locked cases.

---

## 23. Migration Plan — Dependency-Ordered

`V4__case_investigation_schema.sql`. One `BEGIN`/`COMMIT`.

**Phase 0** — Prerequisite guard (V3 tables must exist)

**Phase 1** — Rename `challenges → cases`; replace `challenges_state_check` with temporary `cases_state_check` (includes `'active'`)

**Phase 2** — `challenge_secrets → case_secrets`; rename `challenge_id → case_id`; recreate triggers, RLS, grants

**Phase 3** — Moderation target type two-step constraint migration:
- 3a: DROP `cr_target_type_check`; ADD `cr_target_type_check_tmp` (both `'challenge'` + `'case'`)
- 3b: DROP `ma_target_type_check`; ADD `ma_target_type_check_tmp`
- 3c: `UPDATE content_reports SET target_type='case' WHERE target_type='challenge'`
- 3d: `UPDATE moderation_actions SET target_type='case' WHERE target_type='challenge'`
- 3e: DROP tmp; ADD final `cr_target_type_check` (`'case'` only)
- 3f: DROP tmp; ADD final `ma_target_type_check` (`'case'` only)

**Phase 4** — Create `investigations` and `investigation_members`; `ENABLE ROW LEVEL SECURITY` on both

**Phase 5** — Migrate `eligible_participants → investigation_members`; DROP `eligible_participants`

**Phase 6** — Rename `challenge_id` on all dependent tables:
- 6a `guess_attempts`: rename; add `idempotency_key` (nullable→backfill→NOT NULL); add both UNIQUE indexes
- 6b `exclusion_events`: rename; add `investigation_id` (nullable→backfill→NOT NULL); new UNIQUE; cross-record trigger
- 6c `clues`: rename
- 6d `comments`: rename; add `investigation_id` (nullable→backfill→NOT NULL); cross-record trigger
- 6e `challenge_answer_aliases → case_answer_aliases`: rename table + column
- 6f `correction_events`: rename; DROP `resulting_score_run_id`
- 6g `score_runs`: rename; add `investigation_id` (nullable→backfill→NOT NULL); new UNIQUE; cross-record trigger
- 6h `guess_judgments`: rename; add `investigation_id` (nullable→backfill→NOT NULL)
- 6i `score_events`: rename; add `investigation_id` (nullable→backfill→NOT NULL)
- 6j `reactions`: add `investigation_id` (nullable→backfill→NOT NULL); DROP `challenge_id`; new UNIQUE

**Phase 7** — `current_score_events` VIEW: DROP + CREATE with `security_invoker=true`; GRANT SELECT TO authenticated

**Phase 8** — Upload sessions: rename column; update FK; drop/create index; UPDATE both path columns

**Phase 9** — RLS helper rebuilds: DROP old challenge-named helpers; CREATE new case/investigation helpers; CREATE OR REPLACE preserved helpers

**Phase 10** — Operational function rebuilds (V1 source):
`do_reveal_impl_v3`, `reveal_case_service`, `lock_case`, `reveal_case`, `cancel_case`, `cancel_investigation`, `apply_correction`, `soft_delete_comment`; DROP `activate_challenge`; rebuild deletion pipeline helpers

**Phase 11** — Step 24.1 function updates (all per §16):
DROP+recreate: `can_view_case`, `can_viewer_access_case`; CREATE OR REPLACE all others

**Phase 12** — V2 function updates:
DROP+recreate: `reserve_upload_session` (new p_case_id signature), `reveal_case_service_wrapper`;
CREATE OR REPLACE: `finalize_upload_session`, `prepare_account_deletion_wrapper`

**Phase 13** — Trigger rebuilds (all challenge-named triggers dropped; recreated with case names and corrected state values; V2 activation triggers renamed)

**Phase 14** — Index rebuilds (all challenge-named indexes dropped; case/investigation-named replacements created)

**Phase 15** — RLS policies on all tables:
- `investigations`: member policy + poster policy (§7)
- `investigation_members`: member policy + poster policy (§7)
- All other tables: per §20
- `ALTER TABLE public.investigations ENABLE ROW LEVEL SECURITY;`
- `ALTER TABLE public.investigation_members ENABLE ROW LEVEL SECURITY;`

**Phase 16** — State conversion: `active → launched`; replace temporary `cases_state_check` with final (no `'active'`)

**Phase 17** — Partial index update: `one_active_case_per_poster` with new predicate

**Phase 18** — Remove `group_id` from `cases`

**Phase 19** — New service functions: `launch_case`, `submit_guess`

**Phase 20** — Grants, privilege hardening, completion marker (per §17):
```sql
GRANT USAGE ON SCHEMA private TO authenticated, forkensics_rls_helper, forkensics_executor;

-- All RLS helper EXECUTE grants (per §17)
-- ... (full list in §17)

-- can_view_case: Step 24.1 grants restored after DROP+recreate
GRANT EXECUTE ON FUNCTION private.can_view_case(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION private.can_view_case(uuid) TO service_role;

-- can_viewer_access_case: service_role only
GRANT EXECUTE ON FUNCTION private.can_viewer_access_case(uuid,uuid) TO service_role;

-- New table grants (per §17)
GRANT SELECT ON public.investigations TO authenticated, forkensics_rls_helper;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.investigations TO forkensics_executor;
GRANT SELECT ON public.investigation_members TO authenticated, forkensics_rls_helper;
GRANT SELECT, INSERT, UPDATE ON public.investigation_members TO forkensics_executor;

-- guess_attempts INSERT lock
REVOKE INSERT ON public.guess_attempts FROM authenticated, anon, PUBLIC;
GRANT  INSERT ON public.guess_attempts TO forkensics_executor;
GRANT  SELECT ON public.guess_attempts TO authenticated;

-- remove_content, remove_media: service_role only
REVOKE EXECUTE ON FUNCTION public.remove_content(text,uuid,uuid,uuid,text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.remove_media(uuid,uuid,uuid,text) FROM authenticated;
GRANT  EXECUTE ON FUNCTION public.remove_content(text,uuid,uuid,uuid,text) TO service_role;
GRANT  EXECUTE ON FUNCTION public.remove_media(uuid,uuid,uuid,text) TO service_role;

-- lock_case: service_role only
REVOKE EXECUTE ON FUNCTION public.lock_case(uuid) FROM authenticated;
GRANT  EXECUTE ON FUNCTION public.lock_case(uuid) TO service_role;

-- Restored V2 grants after DROP+recreate
GRANT EXECUTE ON FUNCTION public.reveal_case_service_wrapper(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.reserve_upload_session(uuid,...) TO service_role;

INSERT schema_migrations marker;
```

---

## 24. Acceptance Criteria (Complete)

### Schema
- No `challenge_id` in any listed table; `'active'` state rejected; `one_active_case_per_poster` correct
- `guess_attempts`: both UNIQUE constraints present
- `investigation_members`: `SELECT count(*) ... WHERE cases.poster_id = im.player_id AND i.case_id = c.id` → 0
- `ALTER TABLE ... ENABLE ROW LEVEL SECURITY` confirmed in pg_catalog for `investigations` and `investigation_members`

### Privilege hardening
All `has_function_privilege()` and `has_table_privilege()` assertions in §17 pass.

Additional:
- `has_function_privilege('authenticated', 'private.has_block_with_poster(uuid)', 'EXECUTE')` → t
- `has_function_privilege('authenticated', 'private.can_view_case(uuid)', 'EXECUTE')` → t
- `has_function_privilege('service_role', 'private.can_view_case(uuid)', 'EXECUTE')` → t
- `has_function_privilege('service_role', 'public.reveal_case_service_wrapper(uuid)', 'EXECUTE')` → t
- Direct `INSERT INTO guess_attempts` by `authenticated` → `SQLSTATE 42501`

### RLS on `investigations` and `investigation_members`

- **Outsider** (player with no membership in the investigation): SELECT returns 0 rows on both tables
- **Cross-Table**: Table A member cannot see Table B's investigation row or any of its members
- **Excluded member** (`eligibility_status='excluded'`): still in `investigation_members` — can see the roster and Table Talk (is still a member; only guess submission and scoring are blocked)
- **Account-deleted member** (`eligibility_status='account_deleted'`): same as excluded — still in the table, can see
- **Poster**: sees all investigations and rosters for their case via `is_case_poster_for_investigation`; returns 0 rows for cases they don't own

### `report_content()` media lock
- Orphaned media (no owning case) → `FK_NOT_FOUND`
- Media detached between provisional lookup and lock recheck → `FK_NOT_FOUND`
- Cancelled case → `FK_INVALID_INPUT`
- Non-viewer (blocked, not a member) → `FK_FORBIDDEN` from `can_view_case()` check
- Two-session removal/reporting race: session 1 removes case media; concurrent session 2 reports it → `FK_NOT_FOUND` (linkage recheck fails at step 3)
- Confirmed: case lock (`FOR UPDATE`) acquired before media lock (`FOR UPDATE`)

### Poster Table Talk
- Poster INSERT comment in their case's investigation → success; visible in SELECT
- Poster INSERT reaction → success; visible in SELECT
- Poster soft-delete own comment → success
- Poster DELETE own reaction → success
- Poster SELECT `current_score_events` (via view) → sees investigation scores
- Poster SELECT `investigation_members` → sees full roster
- Poster `INSERT INTO investigation_members` → rejected (no INSERT policy)
- Poster `INSERT INTO score_events` → rejected

### Core function tests (unchanged from Rev 11)
- `cancel_case`: poster only; past-deadline launched → rejected
- `cancel_investigation`: non-launched state → rejected; past-deadline → rejected; suspended → rejected; cancel-after-reveal → rejected
- All-investigations-cancelled: reveal scores nothing; case → `'revealed'`
- Solo-poster group → launch fails with zero-detectives error

### Account deletion
- All investigations marked `'account_deleted'` regardless of case state
- `apply_correction()` after deletion → player gets 0 points
- `database_prepared` set after all 8 steps succeed

### V2 regression
- All 21 unchanged V2 functions pass existing test groups

---

## 25. Out of Scope

Push notifications, feed queries, monthly leaderboard tables, admin UI, Edge Function implementations, `case_secrets → private` schema, Orders To Go (FEAT-001), retired-state archival, per-comment reactions.

---

*Ready for review by Bill, Claude, and Codex. No migration code written until all three parties approve.*
