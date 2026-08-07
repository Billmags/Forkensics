# Step 2 Proposal — Supabase Project & Database Schema (Revision 2)

**Status:** Pending review (Claude → Codex/GPT → Bill approval)
**Prerequisite:** Step 1 approved ✅
**Supersedes:** Step-02-Proposal.md (Revision 1 — rejected)
**Governance gate:** Bill must type `APPROVED: Step 2 — Supabase Project & Database Schema` before any code is written.

---

## Changes from Revision 1

All 14 GPT blockers addressed except one: **duration remains 1–48 hours, poster selects, default 2 hours** — this was explicitly confirmed by Bill and is recorded in the Decision Log. GPT's 48h/72h/7-day recommendation is noted but overridden.

---

## Objective

Stand up the Supabase project and deploy the full production database schema with Row-Level Security policies, triggers, indexes, and constraints. No Swift code changes in this step. Output: a live Supabase project, version-controlled migration SQL, and automated RLS acceptance tests — all reviewed before remote deployment.

---

## Scope

### 1. Supabase Project Creation

Bill creates the project in the Supabase dashboard. Claude provides exact settings. Project URL and anon key are saved for Step 3. Service role key never enters the iOS app.

---

### 2. Database Schema — 19 Tables

All tables use `uuid` primary keys. `auth.users.id` is the application primary key. Apple `sub` lives only in Supabase's internal identity record.

---

#### `profiles`
Created automatically on first sign-in via `handle_new_user` trigger. `display_name` is nullable until the app saves it post-auth (Apple only returns the name to the native app, not to Supabase).

| Column | Type | Notes |
|---|---|---|
| `id` | `uuid PK` | References `auth.users.id` |
| `display_name` | `text` | Nullable; set by app immediately after Apple auth; player cannot post until set |
| `avatar_color` | `text NOT NULL DEFAULT 'orange'` | CHECK: one of 8 valid values |
| `avatar_image_path` | `text` | Storage path for profile photo; NULL = use color + initials fallback |
| `onboarding_complete` | `boolean NOT NULL DEFAULT false` | True when display_name confirmed; gates game participation |
| `created_at` | `timestamptz NOT NULL DEFAULT now()` | |
| `deleted_at` | `timestamptz` | Soft delete; NULL = active |

**Constraint:** `CHECK (avatar_color IN ('orange','red','blue','green','purple','yellow','pink','teal'))`

**RLS:**
- SELECT: self OR player sharing at least one group
- UPDATE: own row only; `player_id = auth.uid()`; cannot modify `id` or `created_at`
- INSERT: trigger only (SECURITY DEFINER)
- DELETE: never (soft delete via `deleted_at`)

---

#### `groups`
| Column | Type | Notes |
|---|---|---|
| `id` | `uuid PK DEFAULT gen_random_uuid()` | |
| `name` | `text NOT NULL` | CHECK: length 1–100 |
| `created_by` | `uuid NOT NULL` | References `profiles.id` |
| `created_at` | `timestamptz NOT NULL DEFAULT now()` | |
| `archived_at` | `timestamptz` | NULL = active; archived groups are read-only |

**Creation:** Must be done atomically via `create_group(name)` SECURITY DEFINER function that inserts into both `groups` and `group_members` (role='owner') in one transaction. Direct INSERT by client is blocked.

**RLS:**
- SELECT: members of the group only
- INSERT: blocked — use `create_group()` function
- UPDATE: owner only; cannot modify `created_by` or `created_at`
- DELETE: never

---

#### `group_members`
| Column | Type | Notes |
|---|---|---|
| `group_id` | `uuid NOT NULL` | References `groups.id` ON DELETE RESTRICT |
| `player_id` | `uuid NOT NULL` | References `profiles.id` ON DELETE RESTRICT |
| `joined_at` | `timestamptz NOT NULL DEFAULT now()` | |
| `role` | `text NOT NULL DEFAULT 'member'` | CHECK: `IN ('owner','member')`; exactly one owner per group enforced by trigger |
| PRIMARY KEY | `(group_id, player_id)` | |

**Constraint:** Trigger enforces exactly one `role='owner'` per group at all times.

**RLS:** All operations via SECURITY DEFINER helper functions only (to avoid recursive policy loops). Direct client INSERT/UPDATE/DELETE blocked.

---

#### `group_invites`
Share-sheet invite links. Raw token never stored — only its SHA-256 hash.

| Column | Type | Notes |
|---|---|---|
| `id` | `uuid PK DEFAULT gen_random_uuid()` | |
| `group_id` | `uuid NOT NULL` | References `groups.id` ON DELETE CASCADE |
| `created_by` | `uuid NOT NULL` | References `profiles.id` |
| `token_hash` | `text NOT NULL UNIQUE` | SHA-256 of the raw token; raw token returned once at creation, never stored |
| `created_at` | `timestamptz NOT NULL DEFAULT now()` | |
| `expires_at` | `timestamptz NOT NULL` | 7 days after creation; set server-side |
| `accepted_by` | `uuid` | References `profiles.id`; NULL until redeemed |
| `accepted_at` | `timestamptz` | NULL until redeemed |
| `revoked_at` | `timestamptz` | NULL unless explicitly revoked |
| `revoked_by` | `uuid` | References `profiles.id` |

**Flow:** Any group member generates an invite → raw token returned once to the app → app generates share sheet URL `forkensics://invite/{raw_token}` → recipient taps link → Edge Function hashes token, validates, inserts into `group_members` via service role.

**RLS:**
- SELECT: own invites only (created_by = auth.uid())
- INSERT: any group member (created_by must equal auth.uid())
- UPDATE: never (redemption and revocation via Edge Function / service role)
- DELETE: never

---

#### `rules_versions`
Immutable. Seeded at migration. Protected from UPDATE/DELETE by trigger.

| Column | Type | Notes |
|---|---|---|
| `id` | `uuid PK` | |
| `version_tag` | `text NOT NULL UNIQUE` | e.g. `'v1'` |
| `description` | `text NOT NULL` | Human-readable summary |
| `config` | `jsonb NOT NULL` | Machine-readable structured config (see below) |
| `created_at` | `timestamptz NOT NULL DEFAULT now()` | |

**v1 config JSONB:**
```json
{
  "algorithm": "standard_competition_ranking_v1",
  "allowed_duration_seconds": [3600, 7200, 14400, 28800, 43200, 86400, 172800],
  "default_duration_seconds": 7200,
  "ranking_method": "standard_competition",
  "tiebreak_method": "receipt_sequence_ascending",
  "point_formula": "effective_eligible_count - rank + 1, minimum 1",
  "normalization_version": "v1",
  "normalization_steps": ["lowercase", "strip_apostrophes", "strip_punctuation", "strip_hyphens", "collapse_whitespace", "trim"]
}
```

**Tie-break note:** `receipt_sequence` deterministically resolves identical `received_at` timestamps, producing unique ordinal ranks. Players do not share rank.

**RLS:**
- SELECT: any authenticated user
- INSERT/UPDATE/DELETE: never (trigger enforces immutability)

---

#### `media_objects`
Opaque media references. Storage keys never exposed to clients. Client receives only the `id`; media is delivered via authenticated Edge Function proxy.

| Column | Type | Notes |
|---|---|---|
| `id` | `uuid PK DEFAULT gen_random_uuid()` | Opaque handle given to client |
| `uploader_id` | `uuid NOT NULL` | References `profiles.id` |
| `storage_key` | `text NOT NULL` | Internal Supabase Storage path; never returned to client |
| `re_encoded_storage_key` | `text` | Server-re-encoded copy; NULL until processing complete |
| `mime_type` | `text NOT NULL` | e.g. `'image/jpeg'` |
| `file_size_bytes` | `integer` | |
| `re_encoded_at` | `timestamptz` | NULL until server re-encoding complete |
| `created_at` | `timestamptz NOT NULL DEFAULT now()` | |

**RLS:**
- SELECT: uploader only (storage_key never returned to client by policy; proxy function uses service role)
- INSERT: uploader via Edge Function (service role)
- UPDATE/DELETE: never

---

#### `challenges`
`story` and image information removed from this table (moved to `challenge_secrets` and `media_objects` respectively).

| Column | Type | Notes |
|---|---|---|
| `id` | `uuid PK DEFAULT gen_random_uuid()` | |
| `poster_id` | `uuid NOT NULL` | References `profiles.id` |
| `group_id` | `uuid NOT NULL` | References `groups.id` ON DELETE RESTRICT |
| `state` | `text NOT NULL DEFAULT 'draft'` | CHECK: valid state values (see constraint below) |
| `media_object_id` | `uuid` | References `media_objects.id`; NULL in draft; opaque handle only |
| `duration_seconds` | `integer NOT NULL DEFAULT 7200` | CHECK: IN (3600,7200,14400,28800,43200,86400,172800) |
| `rules_version_id` | `uuid NOT NULL DEFAULT 'a0000000-0000-0000-0000-000000000001'` | References `rules_versions.id` |
| `posted_at` | `timestamptz` | Set server-side when state→active |
| `deadline_at` | `timestamptz` | Set server-side as posted_at + duration_seconds |
| `locked_at` | `timestamptz` | Set server-side when state→locked |
| `revealed_at` | `timestamptz` | Set server-side when state→revealed |
| `cancelled_at` | `timestamptz` | Set server-side when state→cancelled |
| `cancellation_reason` | `text` | |
| `created_at` | `timestamptz NOT NULL DEFAULT now()` | |

**State constraint:** `CHECK (state IN ('draft','active','locked','revealed','cancelled'))`

**State machine trigger (BEFORE UPDATE):** Enforces valid transitions only:
- `draft → active`
- `draft → cancelled`
- `active → locked`
- `active → cancelled`
- `locked → revealed`
- `locked → cancelled`
- `revealed` and `cancelled` are terminal — any transition raises an exception

**Timestamp guard:** Trigger ensures all state timestamps (`posted_at`, `locked_at`, etc.) are set by trusted server logic only; client-supplied values are overwritten.

**RLS:**
- SELECT: poster (any state including draft) OR group members (non-draft states only)
- INSERT: any group member with onboarding_complete; poster_id must equal auth.uid()
- UPDATE: poster only, draft/active states only; client cannot set state directly (state transitions via Edge Functions)
- DELETE: never

---

#### `challenge_secrets`
Answers, story, and alias metadata. Never readable by non-poster before reveal.

| Column | Type | Notes |
|---|---|---|
| `challenge_id` | `uuid PK` | References `challenges.id` ON DELETE CASCADE |
| `display_dish` | `text NOT NULL` | Human-readable form shown at reveal |
| `canonical_dish` | `text NOT NULL` | Normalized form used for matching |
| `display_restaurant` | `text NOT NULL` | Human-readable form |
| `canonical_restaurant` | `text NOT NULL` | Normalized form |
| `display_city` | `text NOT NULL` | Human-readable form |
| `canonical_city` | `text NOT NULL` | Normalized form |
| `story` | `text` | Shown after reveal only; moved here from challenges |
| `has_first_guess` | `boolean NOT NULL DEFAULT false` | Convenience flag; enforced redundantly by trigger |
| `created_at` | `timestamptz NOT NULL DEFAULT now()` | |
| `updated_at` | `timestamptz NOT NULL DEFAULT now()` | |

**Nonempty constraint:** CHECK on all canonical fields: `length(canonical_dish) > 0`, etc.

**Edit guard trigger (BEFORE UPDATE):** If any row exists in `guess_attempts` for this `challenge_id`, any attempt to change `canonical_dish`, `canonical_restaurant`, or `canonical_city` raises an exception. `has_first_guess` is also set true by trigger when first guess arrives (redundant safety).

**RLS:**
- SELECT: poster OR (challenge state = 'revealed' AND viewer is group member)
- INSERT: poster at challenge creation; poster_id verified via challenges join
- UPDATE: poster only, while `has_first_guess = false`
- DELETE: never

---

#### `challenge_answer_aliases`
Accepted alternate answer forms. Replaces `dish_aliases text[]`. Supports normalization, corrections, and auditing.

| Column | Type | Notes |
|---|---|---|
| `id` | `uuid PK DEFAULT gen_random_uuid()` | |
| `challenge_id` | `uuid NOT NULL` | References `challenges.id` ON DELETE CASCADE |
| `field` | `text NOT NULL` | CHECK: `IN ('dish','restaurant','city')` |
| `display_value` | `text NOT NULL` | Human-readable alternate |
| `normalized_value` | `text NOT NULL` | Normalized for matching |
| `created_by` | `uuid NOT NULL` | References `profiles.id` |
| `created_at` | `timestamptz NOT NULL DEFAULT now()` | |
| `is_active` | `boolean NOT NULL DEFAULT true` | Soft-removed via correction_events |

**RLS:** Same as `challenge_secrets` — poster or revealed group member.

---

#### `eligible_participants`
Immutable posting-time snapshot. One row per player per challenge. Written by Edge Function at state→active.

| Column | Type | Notes |
|---|---|---|
| `id` | `uuid PK DEFAULT gen_random_uuid()` | |
| `challenge_id` | `uuid NOT NULL` | References `challenges.id` ON DELETE RESTRICT |
| `player_id` | `uuid NOT NULL` | References `profiles.id` ON DELETE RESTRICT |
| `snapshot_display_name` | `text NOT NULL` | Locked at post time |
| `snapshot_avatar_color` | `text NOT NULL` | Locked at post time |
| `added_at` | `timestamptz NOT NULL DEFAULT now()` | |
| UNIQUE | `(challenge_id, player_id)` | |

**RLS:**
- SELECT: group members of the challenge's group
- INSERT: service role only
- UPDATE/DELETE: never

---

#### `exclusion_events`
Append-only. Records voluntary withdrawals and poster removals.

| Column | Type | Notes |
|---|---|---|
| `id` | `uuid PK DEFAULT gen_random_uuid()` | |
| `challenge_id` | `uuid NOT NULL` | References `challenges.id` ON DELETE RESTRICT |
| `player_id` | `uuid NOT NULL` | References `profiles.id` |
| `reason` | `text NOT NULL` | CHECK: `IN ('withdrew','removed')` |
| `excluded_by` | `uuid NOT NULL` | References `profiles.id` |
| `excluded_at` | `timestamptz NOT NULL DEFAULT now()` | Server-set |

**RLS:**
- SELECT: group members
- INSERT: self (withdrew) or poster (removed); player_id/excluded_by verified
- UPDATE/DELETE: never

---

#### `hints`
| Column | Type | Notes |
|---|---|---|
| `id` | `uuid PK DEFAULT gen_random_uuid()` | |
| `challenge_id` | `uuid NOT NULL` | References `challenges.id` ON DELETE RESTRICT |
| `poster_id` | `uuid NOT NULL` | References `profiles.id` |
| `text` | `text NOT NULL` | CHECK: length 1–500 |
| `posted_at` | `timestamptz NOT NULL DEFAULT now()` | Server-set |

**RLS:**
- SELECT: group members (active challenge or later)
- INSERT: poster only, challenge must be active; poster_id must equal auth.uid()
- UPDATE/DELETE: never

---

#### `guess_attempts`
Immutable append-only. **Split by race** — What? and Where? are independent submissions with independent timestamps. No correctness fields (moved to `guess_judgments`). No withdrawal flag (exclusions handle participation).

| Column | Type | Notes |
|---|---|---|
| `id` | `uuid PK DEFAULT gen_random_uuid()` | |
| `challenge_id` | `uuid NOT NULL` | References `challenges.id` ON DELETE RESTRICT |
| `player_id` | `uuid NOT NULL` | References `profiles.id` |
| `race` | `text NOT NULL` | CHECK: `IN ('what','where')` |
| `dish_guess` | `text` | Required when race='what'; NULL when race='where' |
| `restaurant_guess` | `text` | Required when race='where'; NULL when race='what' |
| `city_guess` | `text` | Required when race='where'; NULL when race='what' |
| `received_at` | `timestamptz NOT NULL DEFAULT now()` | Server-generated; trigger overwrites any client value |
| `receipt_sequence` | `bigint NOT NULL` | Global PostgreSQL sequence; trigger assigns; unique per challenge |
| `client_submitted_at` | `timestamptz` | For display only; never used for ranking |

**Race field constraint:**
```sql
CHECK (
  (race = 'what'  AND dish_guess IS NOT NULL AND restaurant_guess IS NULL AND city_guess IS NULL)
  OR
  (race = 'where' AND dish_guess IS NULL AND restaurant_guess IS NOT NULL AND city_guess IS NOT NULL)
)
```

**Sequence:** A single global PostgreSQL `SEQUENCE` (`guess_receipt_seq`) assigns `receipt_sequence`. A BEFORE INSERT trigger sets `received_at = now()` and `receipt_sequence = nextval('guess_receipt_seq')`, overwriting any client-supplied values. UNIQUE constraint on `(challenge_id, receipt_sequence)`.

**RLS:**
- SELECT: own rows (before reveal) OR all group members (after reveal, state='revealed')
- INSERT: player must be eligible, non-excluded, non-poster; challenge must be active; player_id must equal auth.uid()
- UPDATE/DELETE: never

---

#### `guess_judgments`
Immutable. Written by Edge Function during reveal scoring run. Records per-attempt correctness evaluation.

| Column | Type | Notes |
|---|---|---|
| `id` | `uuid PK DEFAULT gen_random_uuid()` | |
| `score_run_id` | `uuid NOT NULL` | References `score_runs.id` |
| `guess_attempt_id` | `uuid NOT NULL` | References `guess_attempts.id` |
| `player_id` | `uuid NOT NULL` | References `profiles.id` (denormalized for RLS) |
| `challenge_id` | `uuid NOT NULL` | References `challenges.id` (denormalized for RLS) |
| `race` | `text NOT NULL` | CHECK: `IN ('what','where')` |
| `is_correct` | `boolean NOT NULL` | |
| `is_winning` | `boolean NOT NULL DEFAULT false` | True = first correct for this race in this score run |
| `created_at` | `timestamptz NOT NULL DEFAULT now()` | |
| UNIQUE | `(score_run_id, guess_attempt_id)` | |

**RLS:**
- SELECT: group members (after reveal)
- INSERT/UPDATE/DELETE: service role only

---

#### `score_runs`
One row per scoring event (initial reveal + each correction). Only one `is_current = true` per challenge at a time.

| Column | Type | Notes |
|---|---|---|
| `id` | `uuid PK DEFAULT gen_random_uuid()` | |
| `challenge_id` | `uuid NOT NULL` | References `challenges.id` ON DELETE RESTRICT |
| `revision_number` | `integer NOT NULL` | 1 for initial; increments per correction |
| `rules_version_id` | `uuid NOT NULL` | References `rules_versions.id` |
| `effective_eligible_count` | `integer NOT NULL` | CHECK > 0 |
| `triggering_correction_id` | `uuid` | References `correction_events.id`; NULL for initial scoring |
| `is_current` | `boolean NOT NULL DEFAULT true` | Trigger sets previous runs to false when new run created |
| `created_at` | `timestamptz NOT NULL DEFAULT now()` | |
| UNIQUE | `(challenge_id, revision_number)` | |

**RLS:**
- SELECT: group members (after reveal)
- INSERT/UPDATE: service role only
- DELETE: never

---

#### `score_events`
One row per player per score run. Points generated; total is a computed column.

| Column | Type | Notes |
|---|---|---|
| `id` | `uuid PK DEFAULT gen_random_uuid()` | |
| `score_run_id` | `uuid NOT NULL` | References `score_runs.id` |
| `challenge_id` | `uuid NOT NULL` | References `challenges.id` (denormalized for RLS) |
| `player_id` | `uuid NOT NULL` | References `profiles.id` |
| `rules_version_id` | `uuid NOT NULL` | References `rules_versions.id` |
| `what_points` | `integer NOT NULL DEFAULT 0` | CHECK >= 0 |
| `where_points` | `integer NOT NULL DEFAULT 0` | CHECK >= 0 |
| `total_points` | `integer NOT NULL GENERATED ALWAYS AS (what_points + where_points) STORED` | |
| `what_rank` | `integer` | NULL = no correct What? answer; CHECK > 0 when not null |
| `where_rank` | `integer` | NULL = no correct Where? answer; CHECK > 0 when not null |
| `scored_at` | `timestamptz NOT NULL DEFAULT now()` | |
| UNIQUE | `(score_run_id, player_id)` | One row per player per scoring run |

**RLS:**
- SELECT: group members (after reveal)
- INSERT: service role only
- UPDATE/DELETE: never

---

#### `correction_events`
Append-only audit trail of poster corrections after reveal.

| Column | Type | Notes |
|---|---|---|
| `id` | `uuid PK DEFAULT gen_random_uuid()` | |
| `challenge_id` | `uuid NOT NULL` | References `challenges.id` ON DELETE RESTRICT |
| `corrected_by` | `uuid NOT NULL` | References `profiles.id`; must be poster or group owner |
| `field` | `text NOT NULL` | CHECK: `IN ('dish','restaurant','city','alias_added','alias_removed')` |
| `old_value` | `text` | |
| `new_value` | `text` | |
| `reason` | `text NOT NULL` | Required human-readable justification |
| `resulting_score_run_id` | `uuid` | References `score_runs.id`; set after rescoring |
| `corrected_at` | `timestamptz NOT NULL DEFAULT now()` | |

**RLS:**
- SELECT: group members (after reveal)
- INSERT: poster or group owner; challenge must be revealed; corrected_by must equal auth.uid()
- UPDATE/DELETE: never

---

#### `comments`
| Column | Type | Notes |
|---|---|---|
| `id` | `uuid PK DEFAULT gen_random_uuid()` | |
| `challenge_id` | `uuid NOT NULL` | References `challenges.id` ON DELETE RESTRICT |
| `author_id` | `uuid NOT NULL` | References `profiles.id` |
| `text` | `text NOT NULL` | CHECK: length 1–1000 |
| `posted_at` | `timestamptz NOT NULL DEFAULT now()` | |
| `deleted_at` | `timestamptz` | Soft delete |

**RLS:**
- SELECT: group members
- INSERT: group members; author_id must equal auth.uid(); challenge must be active or revealed
- UPDATE: own rows only; trigger restricts to setting `deleted_at` only (text may not change)
- DELETE: never (soft delete only)

---

#### `reactions`
| Column | Type | Notes |
|---|---|---|
| `id` | `uuid PK DEFAULT gen_random_uuid()` | |
| `challenge_id` | `uuid NOT NULL` | References `challenges.id` ON DELETE RESTRICT |
| `player_id` | `uuid NOT NULL` | References `profiles.id` |
| `emoji` | `text NOT NULL` | CHECK: length 1–8 |
| `reacted_at` | `timestamptz NOT NULL DEFAULT now()` | |
| UNIQUE | `(challenge_id, player_id, emoji)` | One per emoji per player per challenge |

**RLS:**
- SELECT: group members
- INSERT: group members; player_id must equal auth.uid()
- DELETE: own rows only (player_id = auth.uid())
- UPDATE: never

---

### 3. Triggers

| Trigger | Table | Event | Action |
|---|---|---|---|
| `handle_new_user` | `auth.users` | INSERT | Creates `profiles` row; display_name nullable; SECURITY DEFINER; empty search_path |
| `enforce_challenge_state_machine` | `challenges` | BEFORE UPDATE | Rejects invalid state transitions; overwrites state timestamps with now() |
| `set_guess_receipt_fields` | `guess_attempts` | BEFORE INSERT | Sets `received_at = now()` and `receipt_sequence = nextval('guess_receipt_seq')`; overwrites client values |
| `set_has_first_guess` | `challenge_secrets` | (via guess_attempts trigger) | Sets `has_first_guess = true` on first guess insert for challenge |
| `guard_canonical_answer_edits` | `challenge_secrets` | BEFORE UPDATE | Raises exception if canonical fields change after any guess exists for challenge |
| `enforce_single_group_owner` | `group_members` | BEFORE INSERT/UPDATE | Ensures exactly one role='owner' per group |
| `invalidate_prior_score_runs` | `score_runs` | BEFORE INSERT | Sets `is_current = false` on all prior runs for the same challenge |
| `protect_rules_versions` | `rules_versions` | BEFORE UPDATE/DELETE | Always raises exception |

---

### 4. Indexes

| Table | Index columns | Reason |
|---|---|---|
| `group_members` | `player_id` | RLS membership checks |
| `group_members` | `group_id` | Group member lookups |
| `challenges` | `group_id, state` | Feed queries |
| `challenges` | `poster_id` | Poster-specific views |
| `challenges` | `deadline_at` | Auto-close scheduler |
| `guess_attempts` | `challenge_id, race, player_id` | Per-player per-race queries |
| `guess_attempts` | `challenge_id, receipt_sequence` | Rank ordering |
| `guess_judgments` | `score_run_id` | Scoring joins |
| `score_events` | `challenge_id, player_id` | Leaderboard queries |
| `score_runs` | `challenge_id, is_current` | Current-run lookups |
| `exclusion_events` | `challenge_id, player_id` | Eligibility checks |
| `eligible_participants` | `challenge_id, player_id` | RLS eligibility checks |
| `group_invites` | `token_hash` | Invite redemption lookups |
| `group_invites` | `group_id` | Group invite management |

All foreign key columns also have indexes.

---

### 5. Foreign Key ON DELETE Behavior

| Referencing column | ON DELETE |
|---|---|
| `profiles.id` (in most tables) | RESTRICT |
| `groups.id` (in group_members) | CASCADE |
| `groups.id` (in challenges) | RESTRICT |
| `challenges.id` (in challenge_secrets) | CASCADE |
| `challenges.id` (in eligible_participants) | RESTRICT |
| `challenges.id` (in guess_attempts) | RESTRICT |
| `score_runs.id` (in score_events) | RESTRICT |
| `groups.id` (in group_invites) | CASCADE |

RESTRICT on game-history tables preserves audit integrity even if a profile is soft-deleted.

---

### 6. RLS Helper Functions (SECURITY DEFINER, private schema)

To avoid recursive membership policy loops, the following helper functions live in a non-public schema with controlled `search_path`:

- `is_group_member(group_id uuid) → boolean`
- `is_challenge_group_member(challenge_id uuid) → boolean`
- `is_challenge_poster(challenge_id uuid) → boolean`
- `is_challenge_revealed(challenge_id uuid) → boolean`
- `is_eligible_non_excluded(challenge_id uuid) → boolean`

---

### 7. Seed Data

```sql
INSERT INTO rules_versions (id, version_tag, description, config)
VALUES (
  'a0000000-0000-0000-0000-000000000001',
  'v1',
  'Standard competition ranking. Receipt sequence deterministically resolves identical timestamps producing unique ordinal ranks.',
  '{
    "algorithm": "standard_competition_ranking_v1",
    "allowed_duration_seconds": [3600,7200,14400,28800,43200,86400,172800],
    "default_duration_seconds": 7200,
    "ranking_method": "standard_competition",
    "tiebreak_method": "receipt_sequence_ascending",
    "point_formula": "effective_eligible_count - rank + 1, minimum 1",
    "normalization_version": "v1",
    "normalization_steps": ["lowercase","strip_apostrophes","strip_punctuation","strip_hyphens","collapse_whitespace","trim"]
  }'
);
```

---

### 8. Account Deletion Policy

On account deletion request: `profiles.deleted_at` is set; `auth.users` record is retained (Supabase soft delete via `auth.admin`). All foreign key relationships use RESTRICT, so game history is preserved. Player's display name in `eligible_participants` snapshots and `guess_attempts` remains intact for historical challenge integrity.

---

## What This Step Does NOT Include

- No Swift code changes
- No authentication (Step 3)
- No Storage bucket setup (Step 5)
- No Edge Functions (Step 6)
- No Realtime subscriptions (Step 7)
- No profile photo or group creation UI

---

## Deployment Gate

Before applying migration to the live Supabase project:
1. Claude presents complete migration SQL and automated test results
2. Codex/GPT reviews the security-sensitive SQL
3. Bill explicitly approves remote deployment

---

## Acceptance Criteria

- [ ] All 19 tables created with correct columns, types, constraints
- [ ] All foreign key relationships enforced with correct ON DELETE behavior
- [ ] Global sequence `guess_receipt_seq` created
- [ ] All 8 triggers in place and tested
- [ ] All indexes created
- [ ] All SECURITY DEFINER helper functions deployed to private schema
- [ ] RLS enabled on all tables
- [ ] `rules_versions` seeded with v1 row (machine-readable config)
- [ ] Migration is version-controlled SQL

**RLS Acceptance Tests (must all pass before remote deployment):**
- [ ] Anonymous user denied on all tables
- [ ] Authenticated non-member denied on all group-scoped tables
- [ ] Member of a different group denied
- [ ] Draft challenge visible only to poster; invisible to group members
- [ ] Poster can read `challenge_secrets` before reveal
- [ ] Non-poster cannot read `challenge_secrets` before reveal
- [ ] Group members can read `challenge_secrets` after reveal
- [ ] Client-supplied `received_at` and `receipt_sequence` are overwritten
- [ ] Client cannot supply correctness values to `guess_attempts`
- [ ] Client cannot spoof `player_id`, `author_id`, or `poster_id`
- [ ] What? and Where? submit independently with independent timestamps
- [ ] Simultaneous guesses receive distinct `receipt_sequence` values
- [ ] Invalid state transitions (e.g. draft→revealed) fail
- [ ] Canonical answer edits fail after first guess received
- [ ] Excluded participant cannot insert a guess
- [ ] Poster cannot insert a guess on own challenge
- [ ] `score_events.total_points` equals `what_points + where_points`
- [ ] Prior score run marked `is_current = false` when new run created
- [ ] Soft comment deletion works; text cannot be updated, only `deleted_at`
- [ ] `media_objects.storage_key` never returned to client
- [ ] Invite token hash stored; raw token not recoverable from DB
- [ ] Expired or revoked invite rejected at redemption
- [ ] All policies cover SELECT, INSERT, UPDATE, and DELETE

---

## Review Checklist (for Codex/GPT)

1. Are all columns, types, and constraints correct?
2. Are all 8 triggers correct, sufficient, and safe?
3. Are the RLS helper functions adequate to avoid recursive policy loops?
4. Are the RLS policies complete and correctly restrictive — especially `challenge_secrets`, `guess_attempts`, and `media_objects`?
5. Is the race-split `guess_attempts` design correct for independent What?/Where? races?
6. Is the `score_runs` + `score_events` + `guess_judgments` structure correct for handling corrections without double-counting?
7. Is the `group_invites` token-hash approach sufficient for security?
8. Is the deployment gate sufficient before remote apply?
9. Is anything missing given the full game mechanics?
10. Is the duration decision (1–48 hours, default 2 hours) flagged as a confirmed Bill decision rather than a schema error?
