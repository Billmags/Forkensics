# Step 26 Proposal — Case / Investigation Schema
**Revision:** 1  
**Status:** DRAFT — awaiting approval from Bill, Claude, and Codex before any code is written  
**Prerequisite:** Step 25 merged and tagged (`v0.2.0-upload-sessions`)  
**Governance gate:** All three parties must approve before V3 migration is written

---

## 1. Purpose

Step 25 built the upload session infrastructure on top of V1's `challenges` table, which binds a single food mystery to a single group. This prevents a poster from sharing one mystery with multiple groups, which is a core product capability.

This step redesigns the schema to separate:

- **Case** — the mystery itself: photo, answers, location, story. Belongs to the poster. Group-agnostic.
- **Investigation** — a group's engagement with a case: eligible players, guesses, table talk, rankings, reveal.

One case → many investigations. Each investigation is independent in its social experience but shares the canonical photo, answers, and reveal deadline.

---

## 2. Decisions Confirmed in Design Review (Bill + Claude + GPT)

| # | Decision | Rationale |
|---|---|---|
| D-1 | One guess per player per case | Requiring per-investigation guesses would be repetitive, allow inconsistent answers, and inflate scoring |
| D-2 | Guess fans out to all eligible investigations automatically | Player submits once; scoring engine applies the guess to every investigation where that player appears |
| D-3 | All investigations from one case share one `reveal_at` deadline | Overlapping group members would learn the answer early if investigations revealed independently |
| D-4 | Rankings, table talk, and scoring remain per-investigation | The social experience (family vs. office) is fully isolated |
| D-5 | Case state machine: `draft → ready → launched → cancelled → retired` | Distinguishes media-approved-but-not-launched from actively live |
| D-6 | `ready` is the media moderation gate; `launched` creates investigations | Posting and launching are separate user actions |
| D-7 | `challenges` renamed to `cases` throughout schema and API | Aligns with product language; group_id removed from cases |
| D-8 | `upload_sessions.challenge_id` → `case_id`; storage paths updated | Consistency; required before Edge Functions reference these identifiers |
| D-9 | Player belonging to two selected groups submits one guess, competes in both | Deduplication at case level; no double notifications |

---

## 3. Schema Changes

### 3.1 Table: `cases` (renamed from `challenges`)

Remove: `group_id`  
Add: `state` machine values extended (see §4)  
Rename: all `challenge_id` references → `case_id`

```sql
CREATE TABLE public.cases (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  poster_id         uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  media_object_id   uuid REFERENCES public.media_objects(id),
  state             text NOT NULL DEFAULT 'draft'
                    CHECK (state IN ('draft','ready','launched','cancelled','retired')),
  reveal_at         timestamptz,        -- set at launch; shared across all investigations
  caption           text,
  created_at        timestamptz NOT NULL DEFAULT now(),
  state_changed_at  timestamptz NOT NULL DEFAULT now()
);
```

**RLS:**
- Poster sees their own cases in all states.
- Any member of a group that has an investigation for this case sees the case in `launched` or later states.
- `anon` and `authenticated` without eligibility: no access.

**Constraint:** `reveal_at` must be set and must be in the future at the moment of `launched` transition.

---

### 3.2 Table: `case_secrets` (renamed from `challenge_secrets`)

```sql
CREATE TABLE private.case_secrets (
  case_id              uuid PRIMARY KEY REFERENCES public.cases(id) ON DELETE CASCADE,
  display_dish         text NOT NULL,
  canonical_dish       text NOT NULL,
  display_restaurant   text NOT NULL,
  canonical_restaurant text NOT NULL,
  location_city        text,
  location_state       text,
  location_country     text
);
```

Never exposed through PostgREST. Accessed only via `SECURITY DEFINER` service functions.

---

### 3.3 Table: `investigations` (new)

```sql
CREATE TABLE public.investigations (
  investigation_id   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  case_id            uuid NOT NULL REFERENCES public.cases(id) ON DELETE RESTRICT,
  group_id           uuid NOT NULL REFERENCES public.groups(id) ON DELETE RESTRICT,
  created_at         timestamptz NOT NULL DEFAULT now(),
  UNIQUE (case_id, group_id)   -- one investigation per (case, group) pair
);
```

**Notes:**
- Investigation has no independent `reveal_at` — it inherits `cases.reveal_at`.
- Investigation has no independent state field. Its display state is derived:
  - Case `draft`/`ready` → investigation does not exist yet.
  - Case `launched`, `reveal_at` in future → investigation active.
  - Case `launched`, `reveal_at` in past → investigation revealed.
  - Case `cancelled`/`retired` → investigation closed.
- Derived field `all_guesses_in` (for "Everyone's in" UI) is computed: `count(guesses where case_id = X) = count(investigation_members where investigation_id = Y)`.

**RLS:** Members of the group see investigations for their group.

---

### 3.4 Table: `guesses` (restructured)

Current V1 `guesses` table has `challenge_id`. This becomes `case_id`. The row is unique per `(case_id, player_id)`.

```sql
CREATE TABLE public.guesses (
  case_id          uuid NOT NULL REFERENCES public.cases(id) ON DELETE RESTRICT,
  player_id        uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  dish_answer      text NOT NULL,
  restaurant_answer text NOT NULL,
  submitted_at     timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (case_id, player_id)
);
```

**Fan-out is implicit:** when scoring is computed for an investigation, the query joins `guesses` on `case_id` filtered to players who are members of that investigation's group. No fan-out write is needed — the single guess row is read in the context of each investigation.

**RLS:** Player sees their own guess. After reveal, all members of any shared investigation see all guesses within that investigation.

---

### 3.5 Table: `scores` (new, or restructured from existing scoring)

Stores computed results per `(investigation_id, player_id)` after reveal.

```sql
CREATE TABLE public.scores (
  investigation_id  uuid NOT NULL REFERENCES public.investigations(investigation_id),
  player_id         uuid NOT NULL REFERENCES public.profiles(id),
  dish_correct      boolean NOT NULL,
  restaurant_correct boolean NOT NULL,
  time_rank         int,   -- rank within investigation by submitted_at
  score_value       numeric,
  PRIMARY KEY (investigation_id, player_id)
);
```

One player in two investigations receives two `scores` rows (one per investigation), both derived from the single `guesses` row.

---

### 3.6 Table: `table_talk` (scoped to investigation)

```sql
CREATE TABLE public.table_talk (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  investigation_id  uuid NOT NULL REFERENCES public.investigations(investigation_id) ON DELETE CASCADE,
  author_id         uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  body              text NOT NULL,
  created_at        timestamptz NOT NULL DEFAULT now()
);
```

Table talk is group-scoped. The same player's comment in Family investigation is not visible in Office investigation.

---

### 3.7 V2 Upload Session Table Changes

`private.upload_sessions`:
- Column `challenge_id` → `case_id`
- Storage path templates change: `challenges/{case_id}/originals/{session_id}` → `cases/{case_id}/originals/{session_id}`
- FK: `REFERENCES public.cases(id)`

`private.deletion_recovery_claims` — no change needed (keyed by user_id).

---

## 4. Case State Machine

```
draft
  │
  │  (media approved by moderation)
  ▼
ready
  │
  │  (poster selects groups + reveal_at, taps Launch Cases)
  ▼
launched ────────────── (all investigations exist, detectives playing)
  │
  │  (reveal_at passes — automatic transition or service trigger)
  ▼
retired
  │
  └──── (at any stage before launched: poster cancels)
cancelled
```

**Transition rules:**
- `draft → ready`: moderation sets `media_objects.status = 'ready'`; trigger or service function advances case.
- `ready → launched`: poster action; `reveal_at` must be set and future; investigations created atomically.
- `launched → retired`: `reveal_at` passes; service function runs scoring, sets state.
- `draft|ready → cancelled`: poster action; no investigations exist yet; upload sessions cleaned up.
- `launched → cancelled`: restricted; requires admin action; investigations must be tombstoned.

**Immutability after `launched`:** photo, canonical answers, location, initial clue are frozen. Correction requires an approved correction process (out of scope for Step 26).

---

## 5. V2 Upload Session Function Changes

All 27 functions written in Step 25 require the following updates:

| Change | Scope |
|---|---|
| Parameter `p_challenge_id uuid` → `p_case_id uuid` | `reserve_upload_session` and all callers |
| Internal variable `v_challenge_id` / `v_session.challenge_id` → `case_id` | All functions that read the session |
| FK check: `SELECT FROM public.challenges` → `SELECT FROM public.cases` | `reserve_upload_session` |
| State check: `state = 'draft'` remains semantically correct | `reserve_upload_session` |
| Storage path: `'challenges/' || p_case_id || '/originals/' || ...` → `'cases/' || p_case_id || ...` | `reserve_upload_session` |
| Trigger names: `challenge_v2_*` → `case_v2_*` | Two triggers on `cases` table |
| Trigger logic: `challenge_v2_media_ready_on_activate` fires on `ready` transition (not `active`) | Trigger function rewrite |
| Trigger logic: `challenge_v2_no_active_upload_on_activate` fires on `launched` transition | Trigger function rewrite |
| `get_all_upload_session_paths_for_deletion` — table reference unchanged (private) | `case_id` column rename only |
| `quiesce_upload_sessions_for_deletion` — `challenge_id` ref → `case_id` | Internal query |

These are accomplished with `CREATE OR REPLACE FUNCTION` (parameter name changes are permitted without signature change in PostgreSQL) and `ALTER TABLE private.upload_sessions RENAME COLUMN challenge_id TO case_id`.

**Storage path migration note:** existing objects in Supabase Storage under `challenges/` paths must be migrated to `cases/` paths before the upload functions are deployed. Since this is pre-launch (no real user data), a one-time rename script is sufficient.

---

## 6. Investigation Creation at Launch

`launch_case(p_case_id uuid, p_group_ids uuid[], p_reveal_at timestamptz)` — new service function.

**Contract:**
- Caller: `service_role` only.
- Validates: case in `ready` state, poster exists and not deletion-pending, each `group_id` valid, `p_reveal_at` at least 1 hour in the future (TBD — minimum window subject to product decision), array non-empty, no duplicate group IDs.
- Atomically: sets `cases.state = 'launched'`, sets `cases.reveal_at = p_reveal_at`, inserts one `investigations` row per group.
- Returns: `TABLE (investigation_id uuid, group_id uuid)`.
- Idempotent for groups already having an investigation for this case (skip, no error).

---

## 7. Guess Submission

`submit_guess(p_case_id uuid, p_dish_answer text, p_restaurant_answer text)` — new service function.

**Contract:**
- Validates: case in `launched` state, `reveal_at` in future, caller is member of at least one investigation for this case, caller is not the poster.
- Inserts into `guesses(case_id, player_id, ...)` — unique constraint enforces one guess per player per case.
- Idempotent: if guess already exists, returns existing row without error (late submission path).
- Does **not** write to investigations or scores — scoring runs at reveal.

---

## 8. Synchronized Reveal

`reveal_case(p_case_id uuid)` — new service function, called by scheduled Edge Function after `reveal_at` passes.

**Contract:**
- Validates: case in `launched` state, `now() >= reveal_at`.
- For each investigation of this case: computes and inserts `scores` rows for all players who submitted a guess.
- Sets `cases.state = 'retired'`.
- All investigations simultaneously become "revealed" (derived from case state).
- Returns summary: investigation count, total guesses scored.

---

## 9. Overlapping Group Membership

A player belonging to two groups both investigating the same case:

- Sees the mystery once in their feed (deduplication in query layer — `DISTINCT ON (case_id)`).
- Submits one guess — stored once in `guesses`.
- Receives one new-case notification (deduplicated at notification dispatch time).
- Appears in rankings for both investigations with the same answer and timestamp.
- Sees separate Table Talk threads (one per investigation).

No special schema support is needed. The fan-out is implicit in how scores are computed.

---

## 10. Moderation Scope

| Subject | Scope | Table |
|---|---|---|
| Photo / re-encoded display | Case | `media_objects`, `media_storage_keys` |
| Dish / restaurant answers | Case | `case_secrets` |
| Table Talk comments | Investigation | `table_talk` |
| Player guesses | Case (private until reveal) | `guesses` |

A moderation action on the case photo (removal) affects all investigations. A moderation action on a table talk comment affects only that investigation.

---

## 11. Account Deletion Interaction

The V2 deletion lifecycle (`quiesce_upload_sessions_for_deletion`, `get_all_upload_session_paths_for_deletion`) handles upload asset cleanup at the case level. No change to that logic beyond the `challenge_id → case_id` column rename.

Additional deletion considerations for Step 26:

- **Poster deletes account, case in `draft`/`ready`:** case cancelled, upload sessions cleaned up via existing V2 path.
- **Poster deletes account, case in `launched`:** case must be retired (not cancelled); poster's identity anonymized; investigations and guesses retained for other players' experience. Scoring proceeds normally at `reveal_at`.
- **Player (non-poster) deletes account:** player's guess row deleted from `guesses`; player removed from investigation eligibility; scores for that player across all investigations deleted. Other players' experience unaffected.
- **Group owner deletes account:** handled by existing group ownership transfer / dissolution logic (V1).

---

## 12. Migration Plan

This is a **V3 migration** (`V3__case_investigation_schema.sql`). It runs after V1 and V2 on a clean local DB and on forkensics-dev.

**Migration phases (all in one atomic transaction):**

1. Rename `public.challenges` → `public.cases`; rename `challenge_id` column where it is the PK; update all FKs.
2. Rename `private.challenge_secrets` → `private.case_secrets`; rename `challenge_id` → `case_id`.
3. Add `state` values `ready`, `launched`, `retired` to the cases CHECK constraint; drop `active` (replaced by `launched`).
4. Remove `group_id` from `public.cases`.
5. Rename `private.upload_sessions.challenge_id` → `case_id`; update FK.
6. Create `public.investigations` table.
7. Restructure `public.guesses` — rename `challenge_id` → `case_id`; add unique constraint `(case_id, player_id)`; drop per-investigation FK if present.
8. Create `public.scores` table.
9. Create `public.table_talk` table (if not already present).
10. Drop and recreate all 27 V2 upload session functions with updated parameter names, storage paths, and table references.
11. Drop and recreate V2 triggers on `public.cases` with updated names and transition logic.
12. Create new service functions: `launch_case`, `submit_guess`, `reveal_case`.
13. Grant / revoke / ownership assignments.
14. Update migration guard and completion marker.

**No data migration needed** — this is pre-launch; all tables are empty on forkensics-dev.

---

## 13. Acceptance Criteria

### 13.1 Schema Verification
- `public.cases` exists with correct columns; no `group_id`; state CHECK includes all 5 values.
- `private.case_secrets` exists; `challenge_secrets` does not.
- `public.investigations` exists with `UNIQUE(case_id, group_id)`.
- `public.guesses` PK is `(case_id, player_id)`.
- `public.scores` exists.
- `private.upload_sessions.case_id` column exists; `challenge_id` does not.
- All 27 V2 functions exist with updated parameter names.
- Both V2 triggers exist on `public.cases` with updated names.
- New functions `launch_case`, `submit_guess`, `reveal_case` exist.

### 13.2 Case State Machine
- `draft → ready` transition (via media approval) succeeds.
- `ready → launched` with valid groups and future `reveal_at` succeeds; investigations created.
- `ready → launched` with empty group list → error.
- `ready → launched` with `reveal_at` in the past → error.
- `launched → launched` with overlapping group (idempotent) → no duplicate investigation.
- `draft → cancelled` succeeds; no investigations created.
- `launched → retired` via `reveal_case` after `reveal_at` succeeds.
- `launched → cancelled` without admin flag → error.
- Immutability: UPDATE on `cases.reveal_at` after `launched` → trigger blocks.

### 13.3 Investigation Creation
- `launch_case` creates exactly N investigation rows for N distinct groups.
- Duplicate group in array → deduplicated; single investigation created.
- Non-member group (poster not in group) → error.
- Case not in `ready` state → error.

### 13.4 Guess Submission and Fan-out
- Player submits guess against a case they are eligible for → row inserted in `guesses`.
- Player submits guess for a case they have no investigation in → error.
- Poster cannot submit guess against their own case → error.
- Player in two groups both investigating same case → one `guesses` row; appears in scoring for both investigations at reveal.
- Idempotent: second submit returns existing guess without error.
- Submit after `reveal_at` → error.

### 13.5 Synchronized Reveal
- `reveal_case` before `reveal_at` → error.
- `reveal_case` after `reveal_at` → case → `retired`; `scores` rows created for all guessing players across all investigations.
- Player in two investigations: two `scores` rows created (one per investigation), both correct.
- Player who did not guess: no `scores` row created.
- `reveal_case` called twice → idempotent; no duplicate scores.

### 13.6 Overlapping Membership
- Query for "cases I should see" with player in two groups → case appears once.
- Rankings in Investigation A reflect only group A members; rankings in Investigation B reflect only group B members.
- Table talk in Investigation A not visible in Investigation B.

### 13.7 V2 Upload Session Functions (renamed)
- `reserve_upload_session(p_case_id, ...)` → storage path `cases/{case_id}/originals/{session_id}`.
- All 26 other V2 functions behave identically to V2 acceptance tests (Section 13 criteria apply with `case_id` substituted for `challenge_id`).
- `challenge_id` parameter name rejected (function does not exist with old signature).

### 13.8 Trigger Verification
- `case_v2_no_active_upload_on_activate` blocks `draft → launched` when upload session is pending/processing/sanitized.
- `case_v2_media_ready_on_activate` blocks `ready → launched` when `media_object_id` is NULL or not `ready`.
- Both triggers pass when session is complete and media is ready.

### 13.9 Permission Verification
- `service_role` has EXECUTE on all new functions.
- `authenticated` and `anon` cannot execute any new function.
- `public.investigations` RLS: member of group sees investigation; non-member does not.
- `public.guesses` RLS: player sees own guess; after reveal, group members see all guesses within their investigation.
- `private.case_secrets` not accessible through PostgREST.

### 13.10 Account Deletion
- Case in `draft`, poster deletes → upload sessions cleaned up; case cancelled.
- Case in `launched`, poster deletes → case advances to `retired` after `reveal_at`; poster identity anonymized; other players' guesses and scores intact.
- Non-poster player deletes → guess removed; scores removed; other players unaffected.

---

## 14. Out of Scope for Step 26

- Push notification dispatch logic.
- Feed / discovery query design.
- Global leaderboard.
- Case correction process (edit after launch).
- Clue system (initial clue vs. freeform clues during investigation).
- Admin moderation tooling UI.
- Edge Function implementations (depend on this schema; written after Step 26 is merged).

---

## 15. Open Questions (Require Resolution Before Code)

| # | Question | Default if unresolved |
|---|---|---|
| OQ-1 | Minimum `reveal_at` window from launch (e.g. 1 hour? 24 hours?) | 1 hour |
| OQ-2 | Maximum number of groups per launch | 10 |
| OQ-3 | Can poster change `reveal_at` after launch (with restrictions)? | No (immutable after launch) |
| OQ-4 | Does a player who joins a group *after* launch become eligible for ongoing investigations? | No (eligibility frozen at launch) |
| OQ-5 | What name does `table_talk` use in the DB — `table_talk`, `messages`, `comments`? | `table_talk` |

---

*Ready for review by Bill, Claude, and Codex (GPT). No migration code will be written until all three parties approve this document.*
