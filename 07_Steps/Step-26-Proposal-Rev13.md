# Step 26 Proposal — Case / Investigation Schema
**Revision:** 13  
**Status:** DRAFT — awaiting approval from Bill, Claude, and Codex before any code is written  
**Prerequisites:** Step 25 merged (`v0.2.0-upload-sessions`); Step 24.1 merged as `V3__ugc_safety_moderation.sql` and tagged before this migration runs  
**Supersedes:** Rev 12 (rejected — GPT review, 3 blockers)

---

## Changes From Rev 12

| Blocker | Fix |
|---|---|
| 1 | `forkensics_executor` granted `EXECUTE` on `private.can_view_case(uuid)` and `private.can_viewer_access_case(uuid,uuid)` — both are called inside SECURITY DEFINER functions that run as `forkensics_executor`. Previously approved `authenticated` and `service_role` grants preserved. Placeholder signature replaced with exact: `public.reserve_upload_session(uuid,uuid,text,text,bigint,timestamptz)`. Executor privilege assertions and end-to-end call tests added to §24. |
| 2 | Uniform `FK_NOT_FOUND` for all non-cancelled error paths in the `media_object` branch: no owning case, linkage mismatch, `can_view_case() = false`, media row missing, media status != `'ready'`. Cancelled case retains `FK_INVALID_INPUT` (approved exception). `FOUND` explicitly checked after the media `FOR UPDATE` lock. `FOR SHARE` replaced with `FOR UPDATE` on the `case`, `comment`, and `clue` branches — restoring the original Step 24.1 lock strength on those target rows. |
| 3 | Acceptance test corrected: an `account_deleted` member has `profiles.is_active = false`, so every policy's active-profile guard excludes them — they receive 0 rows. The snapshot row is retained for audit purposes. Excluded-but-active members (`eligibility_status = 'excluded'`, `is_active = true`) retain historical read access as previously specified. |

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
| Poster Table Talk | Read + participate: INSERT comments/reactions; soft-delete/withdraw own. Cannot INSERT scores, judgments, or members. |
| Step 24.1 prerequisite | `V3__ugc_safety_moderation.sql` must be tagged before V4 runs |
| `challenge_answer_aliases` final name | `case_answer_aliases` |
| `launch_case()` auth | `p_actor_id = private.auth_uid()` enforced inside function. EXECUTE to `authenticated` only. |
| Moderation target type | `'challenge'` migrated to `'case'` via two-step constraint replace |
| New reports on cancelled cases | Rejected (FK_INVALID_INPUT) for all case-linked targets. Profile reports independent. Existing pending reports remain actionable. |
| Direct INSERT on guess_attempts | Revoked from `authenticated`, `anon`, `PUBLIC`. Only `forkensics_executor` retains INSERT. |
| `remove_content()` / `remove_media()` | `service_role` only. Not granted to `authenticated`. |
| `report_content()` errors for media | Uniform `FK_NOT_FOUND` for non-existent, inaccessible, detached, removed, or non-ready media. Cancelled case = `FK_INVALID_INPUT` (only exception). |

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

## 4. `public.case_secrets`

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

## 6. `public.investigation_members`

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

The poster is never inserted. `launch_case()` filters `gm.player_id != poster_id` during snapshot.

---

## 7. RLS — `investigations` and `investigation_members`

### `public.investigations`

```sql
CREATE POLICY investigations_member_view ON public.investigations
  AS PERMISSIVE FOR SELECT
  USING (
    private.is_investigation_member(investigation_id)
    AND EXISTS (SELECT 1 FROM public.profiles
                WHERE id = private.auth_uid() AND is_active = true)
  );

CREATE POLICY investigations_poster_view ON public.investigations
  AS PERMISSIVE FOR SELECT
  USING (
    private.is_case_poster_for_investigation(investigation_id)
    AND EXISTS (SELECT 1 FROM public.profiles
                WHERE id = private.auth_uid() AND is_active = true)
  );
```

### `public.investigation_members`

```sql
CREATE POLICY investigation_members_member_view ON public.investigation_members
  AS PERMISSIVE FOR SELECT
  USING (
    private.is_investigation_member(investigation_id)
    AND EXISTS (SELECT 1 FROM public.profiles
                WHERE id = private.auth_uid() AND is_active = true)
  );

CREATE POLICY investigation_members_poster_view ON public.investigation_members
  AS PERMISSIVE FOR SELECT
  USING (
    private.is_case_poster_for_investigation(investigation_id)
    AND EXISTS (SELECT 1 FROM public.profiles
                WHERE id = private.auth_uid() AND is_active = true)
  );
```

No client-facing INSERT/UPDATE/DELETE policies on either table.

---

## 8. `public.exclusion_events`

State gate per reason (`enforce_exclusion_rules` trigger):
- `withdrew` / `removed`: `investigations.status = 'active' AND cases.state = 'launched'`
- `account_deleted`: `investigations.status = 'active' AND cases.state IN ('launched','locked')`

---

## 9. `public.guess_attempts`

Phase 20 grants:
```sql
REVOKE INSERT ON public.guess_attempts FROM authenticated, anon, PUBLIC;
GRANT  INSERT ON public.guess_attempts TO forkensics_executor;
GRANT  SELECT ON public.guess_attempts TO authenticated;
```

---

## 10. Scoring Tables and `current_score_events` VIEW

`score_runs`, `correction_events`, `guess_judgments`, `score_events` — `challenge_id → case_id`; `investigation_id uuid NOT NULL` added to `score_runs`, `guess_judgments`, `score_events`.

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

No RLS policy on `current_score_events`. `security_invoker = true` causes policies on `score_events` — including the poster-access policy — to apply automatically.

---

## 11–13. Other Tables

`comments`, `reactions` — `challenge_id → case_id`; `investigation_id uuid NOT NULL` added.  
`clues`, `case_answer_aliases` — `challenge_id → case_id`.  
`private.upload_sessions` — `challenge_id → case_id`; both path columns updated.

---

## 14. Media Moderation — Step 24.1 Contract Extensions and `report_content()` Guard

**`approve_photo()` V4:** `UPDATE cases SET state='ready' WHERE media_object_id=... AND state='draft'`  
**`reject_photo()` V4:** `UPDATE cases SET media_object_id=NULL WHERE media_object_id=... AND state='draft'`

### Moderation State Matrix

| Case state | New reports accepted | Existing pending reports |
|---|---|---|
| `draft` | No | N/A |
| `ready` | Photo moderation queue only | Actionable |
| `launched` / `locked` / `revealed` / `retired` | Yes | Actionable |
| `cancelled` | No — `FK_INVALID_INPUT` for all case-linked targets | Still actionable |

Profile reports always accepted.

### `report_content()` — exact cancelled-case guard with corrected error codes and lock strengths

```sql
v_case_id             uuid   := NULL;
v_case                record;
v_provisional_case_id uuid;
v_media               record;

-- All case, comment, and clue branches use FOR UPDATE to preserve
-- the original Step 24.1 lock strength on the target row.

IF p_target_type = 'case' THEN
  SELECT id, state INTO v_case
  FROM public.cases WHERE id = p_target_id
  FOR UPDATE;
  IF FOUND THEN v_case_id := v_case.id; END IF;

ELSIF p_target_type = 'comment' THEN
  SELECT c.id, c.state INTO v_case
  FROM public.cases c
  JOIN public.comments cm ON cm.case_id = c.id
  WHERE cm.id = p_target_id
  FOR UPDATE OF c;
  IF FOUND THEN v_case_id := v_case.id; END IF;

ELSIF p_target_type = 'clue' THEN
  SELECT c.id, c.state INTO v_case
  FROM public.cases c
  JOIN public.clues cl ON cl.case_id = c.id
  WHERE cl.id = p_target_id
  FOR UPDATE OF c;
  IF FOUND THEN v_case_id := v_case.id; END IF;

ELSIF p_target_type = 'media_object' THEN
  -- Step 1: provisional case lookup (no lock); missing → FK_NOT_FOUND
  SELECT id INTO v_provisional_case_id
  FROM public.cases WHERE media_object_id = p_target_id
  LIMIT 1;
  IF v_provisional_case_id IS NULL THEN
    RAISE EXCEPTION 'FK_NOT_FOUND';
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
    RAISE EXCEPTION 'FK_NOT_FOUND';
  END IF;
  v_case_id := v_provisional_case_id;

  -- Step 4a: reject cancelled case → FK_INVALID_INPUT (approved exception to uniform rule)
  IF v_case.state = 'cancelled' THEN
    RAISE EXCEPTION 'FK_INVALID_INPUT: cannot report content belonging to a cancelled case';
  END IF;

  -- Step 4b: verify caller can view case; non-viewer → FK_NOT_FOUND (uniform, no information leak)
  IF NOT private.can_view_case(v_case_id) THEN
    RAISE EXCEPTION 'FK_NOT_FOUND';
  END IF;

  -- Step 5: lock media FOR UPDATE (case already locked above; case before media always)
  SELECT id, status INTO v_media
  FROM public.media_objects WHERE id = p_target_id
  FOR UPDATE;

  -- Step 6: media missing or not ready → FK_NOT_FOUND (uniform, no information leak)
  IF NOT FOUND OR v_media.status != 'ready' THEN
    RAISE EXCEPTION 'FK_NOT_FOUND';
  END IF;

-- profile: v_case_id remains NULL; shared guard below is skipped.
END IF;

-- Shared cancelled guard for case, comment, clue targets.
-- media_object already handled Steps 4a–6 inline above;
-- this is a safe no-op for that path.
IF v_case_id IS NOT NULL AND v_case.state = 'cancelled' THEN
  RAISE EXCEPTION 'FK_INVALID_INPUT: cannot report content belonging to a cancelled case';
END IF;
```

### `get_media_serve_authorization` — exact V4 body (unchanged from Rev 12)

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

This function is SECURITY DEFINER, OWNER = `forkensics_executor`. It executes as `forkensics_executor`, so `forkensics_executor` must hold EXECUTE on `private.can_viewer_access_case`. EXECUTE granted to `service_role` only (callers invoke the wrapper).

---

## 15. V2 Function Impact

### Dropped and recreated — explicit grant restoration

| Function | Exact new signature | Grant |
|---|---|---|
| `reserve_upload_session` | `public.reserve_upload_session(uuid, uuid, text, text, bigint, timestamptz)` | `service_role` EXECUTE |
| `reveal_case_service_wrapper` | `public.reveal_case_service_wrapper(uuid)` | `service_role` EXECUTE |

### CREATE OR REPLACE — grants preserved

`finalize_upload_session`, `prepare_account_deletion_wrapper`, all 21 no-body-change V2 functions.

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
| `private.has_block_with_poster(uuid)` | CREATE OR REPLACE; `challenges → cases` |
| `private.can_view_challenge(uuid)` | DROP + recreate as `private.can_view_case(uuid)` |
| `private.can_viewer_access_challenge(uuid, uuid)` | DROP + recreate as `private.can_viewer_access_case(uuid, uuid)` |

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

`launch_case`, `submit_guess`, `cancel_case`, `cancel_investigation`, `reveal_case`, `apply_correction`, `soft_delete_comment`, `report_content`.

### `service_role` only

`lock_case`, `private.reveal_case_service`, `get_media_serve_authorization`, `get_moderation_queue`, `get_pending_review_media`, `get_reported_media`, `approve_photo`, `reject_photo`, `claim_moderation_media_cleanup`, `remove_content` (NOT `authenticated`), `remove_media` (NOT `authenticated`), `reserve_upload_session(uuid,uuid,text,text,bigint,timestamptz)`, `reveal_case_service_wrapper`.

### Internal — no client grant

`private.do_reveal_impl_v3`, `private.prepare_account_deletion`, deletion pipeline helpers.

### RLS helpers — schema USAGE + EXECUTE

```sql
GRANT USAGE ON SCHEMA private TO authenticated, forkensics_rls_helper, forkensics_executor;

-- Helpers called from RLS policies (authenticated needs EXECUTE)
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

-- can_view_case: called from RLS policies (authenticated), service functions (service_role),
-- and SECURITY DEFINER functions that run as forkensics_executor (forkensics_executor)
GRANT EXECUTE ON FUNCTION private.can_view_case(uuid)                    TO authenticated;
GRANT EXECUTE ON FUNCTION private.can_view_case(uuid)                    TO service_role;
GRANT EXECUTE ON FUNCTION private.can_view_case(uuid)                    TO forkensics_executor;

-- can_viewer_access_case: called from get_media_serve_authorization (SECURITY DEFINER,
-- runs as forkensics_executor; outer caller is service_role)
GRANT EXECUTE ON FUNCTION private.can_viewer_access_case(uuid, uuid)     TO service_role;
GRANT EXECUTE ON FUNCTION private.can_viewer_access_case(uuid, uuid)     TO forkensics_executor;
```

Why `forkensics_executor` needs these two grants:
- `report_content()` is SECURITY DEFINER OWNER `forkensics_executor`. When it calls `private.can_view_case()`, PostgreSQL checks `forkensics_executor`'s EXECUTE privilege, not the original caller's.
- `get_media_serve_authorization()` is SECURITY DEFINER OWNER `forkensics_executor`. When it calls `private.can_viewer_access_case()`, same rule applies.

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
-- RLS helpers (authenticated)
SELECT has_function_privilege('authenticated',
  'private.is_case_member(uuid)', 'EXECUTE');                              -- t
SELECT has_function_privilege('authenticated',
  'private.is_investigation_member(uuid)', 'EXECUTE');                     -- t
SELECT has_function_privilege('authenticated',
  'private.is_case_poster_for_investigation(uuid)', 'EXECUTE');            -- t
SELECT has_function_privilege('authenticated',
  'private.has_block_with_poster(uuid)', 'EXECUTE');                       -- t

-- can_view_case: three roles
SELECT has_function_privilege('authenticated',
  'private.can_view_case(uuid)', 'EXECUTE');                               -- t
SELECT has_function_privilege('service_role',
  'private.can_view_case(uuid)', 'EXECUTE');                               -- t
SELECT has_function_privilege('forkensics_executor',
  'private.can_view_case(uuid)', 'EXECUTE');                               -- t

-- can_viewer_access_case: executor + service_role; NOT authenticated
SELECT has_function_privilege('forkensics_executor',
  'private.can_viewer_access_case(uuid,uuid)', 'EXECUTE');                 -- t
SELECT has_function_privilege('service_role',
  'private.can_viewer_access_case(uuid,uuid)', 'EXECUTE');                 -- t
SELECT NOT has_function_privilege('authenticated',
  'private.can_viewer_access_case(uuid,uuid)', 'EXECUTE');                 -- t

-- New tables
SELECT has_table_privilege('authenticated',
  'public.investigations', 'SELECT');                                       -- t
SELECT has_table_privilege('authenticated',
  'public.investigation_members', 'SELECT');                               -- t
SELECT has_table_privilege('forkensics_rls_helper',
  'public.investigations', 'SELECT');                                       -- t
SELECT has_table_privilege('forkensics_rls_helper',
  'public.investigation_members', 'SELECT');                               -- t

-- guess_attempts INSERT locked
SELECT NOT has_table_privilege('authenticated',
  'public.guess_attempts', 'INSERT');                                       -- t
SELECT has_table_privilege('forkensics_executor',
  'public.guess_attempts', 'INSERT');                                       -- t

-- remove_content, remove_media: service_role only
SELECT has_function_privilege('service_role',
  'public.remove_content(text,uuid,uuid,uuid,text)', 'EXECUTE');           -- t
SELECT NOT has_function_privilege('authenticated',
  'public.remove_content(text,uuid,uuid,uuid,text)', 'EXECUTE');           -- t
SELECT has_function_privilege('service_role',
  'public.remove_media(uuid,uuid,uuid,text)', 'EXECUTE');                  -- t
SELECT NOT has_function_privilege('authenticated',
  'public.remove_media(uuid,uuid,uuid,text)', 'EXECUTE');                  -- t

-- lock_case: service_role only
SELECT has_function_privilege('service_role',
  'public.lock_case(uuid)', 'EXECUTE');                                     -- t
SELECT NOT has_function_privilege('authenticated',
  'public.lock_case(uuid)', 'EXECUTE');                                     -- t

-- launch_case: authenticated only
SELECT has_function_privilege('authenticated',
  'public.launch_case(uuid,uuid,uuid[],integer)', 'EXECUTE');              -- t

-- Restored V2 grants after DROP+recreate
SELECT has_function_privilege('service_role',
  'public.reveal_case_service_wrapper(uuid)', 'EXECUTE');                  -- t
SELECT has_function_privilege('service_role',
  'public.reserve_upload_session(uuid,uuid,text,text,bigint,timestamptz)',
  'EXECUTE');                                                               -- t

-- End-to-end SECURITY DEFINER path tests
-- (1) service_role calls get_media_serve_authorization → internally calls
--     can_viewer_access_case as forkensics_executor → returns row or empty set,
--     no privilege error raised.
-- (2) authenticated calls report_content with media_object target → internally calls
--     can_view_case as forkensics_executor → returns FK_NOT_FOUND for non-viewer,
--     no privilege error raised.
-- Both tests confirm that the executor's EXECUTE grants eliminate the privilege error
-- that would otherwise surface as a generic internal error to the client.
```

---

## 18. Service Function Contracts

### `public.lock_case(p_case_id uuid)` — service-role only
FOR UPDATE on cases; deadline check; state='launched' check; UPDATE state='locked'.

### `public.reveal_case(p_case_id uuid)` — authenticated poster
FOR UPDATE; auth check; poster check; deadline check; state IN ('launched','locked');
loop active investigations → `do_reveal_impl_v3`; UPDATE state='revealed'.

### `private.reveal_case_service(p_case_id uuid)` — service-role only
Same loop; requires state='locked'.

### `private.do_reveal_impl_v3(p_case_id uuid, p_investigation_id uuid)`
Caller holds FOR UPDATE on cases. Does NOT update `cases.state`. Scores only `eligibility_status='eligible'` members.

### `public.cancel_case(p_case_id uuid, p_reason text)` — poster ONLY
Active profile check; FOR UPDATE lock; poster check; state IN ('draft','ready','launched') check;
IF state='launched' AND clock_timestamp() >= deadline_at → EXCEPTION;
UPDATE cases state='cancelled'; UPDATE active investigations status='cancelled'.

### `public.cancel_investigation(p_investigation_id uuid, p_reason text)` — poster or Table owner
Suspended/inactive check; FOR UPDATE lock (investigation + case join); state='launched' check;
clock_timestamp() >= deadline_at → EXCEPTION; poster or group owner check; status='active' check;
UPDATE investigations status='cancelled'.

### `public.submit_guess(...)` — detective only
Step 1: active/onboarding/not-suspended check.
Step 1b: fast-path poster reject.
Step 2: race validation.
Step 3: idempotency lookup; branch by race for comparison (dish_guess vs restaurant_guess); return or FK_CONFLICT.
Step 4: FOR SHARE case lock; poster re-check; state='launched'; deadline check.
Step 5: investigation_members eligibility + investigation active.
Step 6: bilateral block check.
Step 7: INSERT; concurrent duplicate → catch unique violation → reload → re-apply Step 3.

---

## 19. `launch_case()` — Full Contract

Steps 1–10 unchanged. Step 11 snapshot filters `gm.player_id != p_actor_id`. Zero detectives after filtering → FK_INVALID_INPUT.

---

## 20. RLS — Full Policy Set

### `public.guess_attempts`
1. `guess_own_view` — own guess, always visible, no state restriction, active profile required
2. `guess_poster_view` — poster, launched/locked/revealed, active profile required
3. `guess_investigation_revealed_view` — co-investigator, revealed, `eligibility_status='eligible'` required, active profile required

### `public.investigations` — §7
### `public.investigation_members` — §7

### Poster access — investigation-scoped tables

**SELECT only (no INSERT):** `score_runs`, `guess_judgments`, `score_events` — poster policy via `is_case_poster_for_investigation`. `current_score_events` view: no policy created; `security_invoker` propagates `score_events` policy.

**SELECT + INSERT + DELETE/UPDATE for Table Talk:**

```sql
-- comments
CREATE POLICY comments_poster_view ON public.comments AS PERMISSIVE FOR SELECT
USING (
  private.is_case_poster_for_investigation(investigation_id)
  AND EXISTS (SELECT 1 FROM public.profiles WHERE id=private.auth_uid() AND is_active=true)
);
CREATE POLICY comments_poster_insert ON public.comments AS PERMISSIVE FOR INSERT
WITH CHECK (
  author_id = private.auth_uid()
  AND private.is_case_poster_for_investigation(investigation_id)
  AND EXISTS (SELECT 1 FROM public.profiles WHERE id=private.auth_uid() AND is_active=true)
);
CREATE POLICY comments_poster_softdelete ON public.comments AS PERMISSIVE FOR UPDATE
USING (
  author_id = private.auth_uid()
  AND private.is_case_poster_for_investigation(investigation_id)
)
WITH CHECK (author_id = private.auth_uid());

-- reactions
CREATE POLICY reactions_poster_view ON public.reactions AS PERMISSIVE FOR SELECT
USING (
  private.is_case_poster_for_investigation(investigation_id)
  AND EXISTS (SELECT 1 FROM public.profiles WHERE id=private.auth_uid() AND is_active=true)
);
CREATE POLICY reactions_poster_insert ON public.reactions AS PERMISSIVE FOR INSERT
WITH CHECK (
  player_id = private.auth_uid()
  AND private.is_case_poster_for_investigation(investigation_id)
  AND EXISTS (SELECT 1 FROM public.profiles WHERE id=private.auth_uid() AND is_active=true)
);
CREATE POLICY reactions_poster_delete ON public.reactions AS PERMISSIVE FOR DELETE
USING (
  player_id = private.auth_uid()
  AND private.is_case_poster_for_investigation(investigation_id)
);
```

Poster cannot INSERT into `investigation_members`, `exclusion_events`, `score_runs`, `guess_judgments`, `score_events`, `correction_events`.

---

## 21. Scoring — Active Investigations Only

`reveal_case()` / `reveal_case_service()` loop over `status='active'` only. `do_reveal_impl_v3()` scores `eligibility_status='eligible'` members only. `apply_correction()` skips non-active investigations and non-eligible members.

---

## 22. Account Deletion

Eight steps unchanged. Step 2 marks ALL `eligibility_status='eligible'` rows as `'account_deleted'` regardless of case state; exclusion_events created only for active investigations in launched/locked cases. Step 5 sets `profiles.is_active = false`.

---

## 23. Migration Plan — Dependency-Ordered

`V4__case_investigation_schema.sql`. One `BEGIN`/`COMMIT`.

Phases 0–14 unchanged from Rev 12.

**Phase 15** — RLS policies on all tables, including:
```sql
ALTER TABLE public.investigations      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.investigation_members ENABLE ROW LEVEL SECURITY;
```
Plus member and poster policies per §7 and all other policies per §20.

**Phase 16** — State conversion: `active → launched`; replace temporary constraint with final (no `'active'`).

**Phase 17** — Partial index update: `one_active_case_per_poster` WHERE clause updated.

**Phase 18** — Remove `group_id` from `cases`.

**Phase 19** — New service functions: `launch_case`, `submit_guess`.

**Phase 20** — Grants, privilege hardening, completion marker:
- Full RLS helper EXECUTE grants per §17
- `can_view_case` EXECUTE to `authenticated`, `service_role`, `forkensics_executor`
- `can_viewer_access_case` EXECUTE to `service_role`, `forkensics_executor`
- Table grants for `investigations`, `investigation_members`, `guess_attempts` per §17
- REVOKE/GRANT for `remove_content`, `remove_media`, `lock_case` per §17
- Restored V2 grants for `reserve_upload_session(uuid,uuid,text,text,bigint,timestamptz)` and `reveal_case_service_wrapper(uuid)`
- `INSERT schema_migrations` marker

---

## 24. Acceptance Criteria (Complete)

### Schema
- No `challenge_id` in any listed table; `'active'` state rejected; `one_active_case_per_poster` predicate correct
- `guess_attempts`: UNIQUE `(case_id, player_id, race)` and UNIQUE `(case_id, player_id, idempotency_key)` both present
- `investigation_members` has no row where `player_id = cases.poster_id`
- `pg_class.relrowsecurity = true` for `investigations` and `investigation_members`

### Privilege hardening
All `has_function_privilege()` and `has_table_privilege()` assertions in §17 pass.

### End-to-end SECURITY DEFINER paths
- `service_role` calls `get_media_serve_authorization(p_media_object_id, p_viewer_id)` → returns row or empty set; no internal privilege error
- `authenticated` calls `report_content('media_object', p_target_id, ...)` where caller is not a viewer of the owning case → `FK_NOT_FOUND`; no internal privilege error
- These two tests confirm `forkensics_executor`'s EXECUTE grants on the private helpers are effective

### RLS on `investigations` and `investigation_members`

| Caller | Expected |
|---|---|
| Outsider (no investigation membership) | 0 rows on both tables |
| Cross-Table: Table A member | Cannot see Table B's investigation row or members |
| Excluded member (`eligibility_status='excluded'`, `profiles.is_active=true`) | CAN see roster and Table Talk — still snapshotted; is_active guard passes |
| Account-deleted member (`eligibility_status='account_deleted'`, `profiles.is_active=false`) | 0 rows — `is_active=false` fails the active-profile guard; snapshot row retained for audit |
| Poster | Sees all investigations and rosters for their case; 0 rows for cases they do not own |

### `report_content()` error codes

| Scenario | Expected exception |
|---|---|
| No owning case for media | `FK_NOT_FOUND` |
| Media linkage changed under concurrent update | `FK_NOT_FOUND` |
| `can_view_case() = false` | `FK_NOT_FOUND` (no information leak) |
| Media row missing after FOR UPDATE lock | `FK_NOT_FOUND` |
| Media status != 'ready' | `FK_NOT_FOUND` (no information leak) |
| Owning case is cancelled | `FK_INVALID_INPUT` |
| New report on cancelled case (other target types) | `FK_INVALID_INPUT` |
| Existing pending report on cancelled target | Still actionable |
| Two-session race: session 1 removes media; session 2 reports it concurrently | `FK_NOT_FOUND` (linkage recheck at Step 3 fails) |
| Lock order: case acquired before media | Confirmed by instrumented test |

### Poster Table Talk
- Poster INSERT comment → success; visible in SELECT
- Poster INSERT reaction → success; visible in SELECT
- Poster soft-delete own comment → success
- Poster DELETE own reaction → success
- Poster SELECT `current_score_events` view → receives investigation scores (policy propagated from `score_events`)
- Poster INSERT into `investigation_members` → rejected (no policy)
- Poster INSERT into `score_events` → rejected (no policy)

### Core function tests (unchanged from Rev 12)
- `cancel_case`: poster only; past-deadline launched → rejected
- `cancel_investigation`: non-launched → rejected; past-deadline → rejected; suspended → rejected
- All-investigations-cancelled: reveal scores nothing; case still → `'revealed'`
- Solo-poster group → launch rejected with zero-detectives error

### Account deletion
- ALL investigations marked `'account_deleted'` regardless of case state
- `apply_correction()` after deletion → player receives 0 points
- `database_prepared` set only after all 8 steps succeed

### V2 regression
All 21 unchanged V2 functions pass existing test groups after migration.

---

## 25. Out of Scope

Push notifications, feed queries, monthly leaderboard tables, admin UI, Edge Function implementations, `case_secrets → private` schema, Orders To Go (FEAT-001), retired-state archival, per-comment reactions.

---

*Ready for review by Bill, Claude, and Codex. No migration code written until all three parties approve.*
