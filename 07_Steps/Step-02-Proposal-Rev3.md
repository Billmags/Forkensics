# Step 2 Proposal — Supabase Project & Database Schema (Revision 3)

**Status:** Pending review (Claude → Codex/GPT → Bill approval)
**Prerequisite:** Step 1 approved ✅
**Supersedes:** Step-02-Proposal-Rev2.md
**Governance gate:** Bill must type `APPROVED: Step 2 — Supabase Project & Database Schema` before any code is written.

---

## Changes from Revision 2

All 10 GPT blockers from Rev 2 review addressed:

1. `media_objects` split into two tables — opaque metadata (client-readable) and `media_storage_keys` (server-only, zero client access)
2. `profiles.avatar_image_path` replaced with `avatar_media_object_id`
3. `duration_seconds` constraint changed to full 1–48 hour range with whole-hour steps; rules config updated
4. Client-controlled field protections made explicit; `clock_timestamp()` specified for authoritative timestamps; profiles policy typo (`player_id` → `id`) fixed; `display_name` non-blank constraint when `onboarding_complete = true`
5. Guess INSERT requires `clock_timestamp() < deadline_at` directly in trigger; whitespace/length constraints added to guess fields
6. Answer-edit lock extended to all display values and aliases after first guess
7. `group_invites` direct INSERT blocked; invite creation via trusted function only
8. Partial unique index replaces trigger for single-owner enforcement; `UNIQUE (challenge_id, player_id)` added to `exclusion_events`; withdrawal rules post-locking defined
9. `is_winning` renamed to `is_first_correct_for_player`; algorithm renamed from `standard_competition_ranking_v1` to `ordinal_ranking_v1`; `is_current` removed from `score_runs` (current run = MAX revision_number); atomic correction transaction defined; circular FK resolved
10. Deleted player identity hidden as "Former Player" via client-facing view
11. Acceptance tests expanded with all items from Rev 2 review

---

## Duration (Confirmed Decision)

Poster chooses any whole-hour value from 1–48 hours. Default 2 hours.

```sql
CHECK (duration_seconds BETWEEN 3600 AND 172800 AND duration_seconds % 3600 = 0)
```

---

## Scope

### 1. Supabase Project Creation

Bill creates the project in the Supabase dashboard. Claude provides exact settings. Project URL and anon key saved for Step 3. Service role key never enters the iOS app.

---

### 2. Database Schema — 20 Tables

---

#### `profiles`
| Column | Type | Notes |
|---|---|---|
| `id` | `uuid PK` | References `auth.users.id` |
| `display_name` | `text` | Nullable; set by app post-Apple-auth; must be non-blank when `onboarding_complete = true` |
| `avatar_color` | `text NOT NULL DEFAULT 'orange'` | CHECK: valid color |
| `avatar_media_object_id` | `uuid` | References `media_objects.id`; NULL = use color + initials |
| `onboarding_complete` | `boolean NOT NULL DEFAULT false` | Gates game participation |
| `created_at` | `timestamptz NOT NULL DEFAULT now()` | |
| `deleted_at` | `timestamptz` | Soft delete |

**Constraints:**
```sql
CHECK (avatar_color IN ('orange','red','blue','green','purple','yellow','pink','teal'))
CHECK (onboarding_complete = false OR (display_name IS NOT NULL AND length(trim(display_name)) > 0))
```

**RLS:**
- SELECT: `id = auth.uid()` OR shares at least one group (via helper function); deleted profiles appear as "Former Player" via client view
- UPDATE: `id = auth.uid()`; cannot change `id`, `created_at`; `onboarding_complete` can only be set true, never back to false (trigger enforced)
- INSERT: trigger only (SECURITY DEFINER `handle_new_user`)
- DELETE: never (soft delete via `deleted_at`)

**Client view `public.player_profiles`:** Exposes all columns except `deleted_at`; substitutes `display_name = 'Former Player'` and `avatar_media_object_id = NULL` and `avatar_color = 'gray'` when `deleted_at IS NOT NULL`. This is the view all client queries use. Underlying table is not directly exposed.

---

#### `groups`
| Column | Type | Notes |
|---|---|---|
| `id` | `uuid PK DEFAULT gen_random_uuid()` | |
| `name` | `text NOT NULL` | CHECK: `length(trim(name)) BETWEEN 1 AND 100` |
| `created_by` | `uuid NOT NULL` | References `profiles.id` |
| `created_at` | `timestamptz NOT NULL DEFAULT now()` | |
| `archived_at` | `timestamptz` | NULL = active |

**Creation:** `create_group(name text)` SECURITY DEFINER function — atomically inserts into `groups` and `group_members` (role='owner') in one transaction. Direct client INSERT blocked.

**RLS:**
- SELECT: group members only
- INSERT: blocked (function only)
- UPDATE: group owner only; cannot change `created_by`, `created_at`, `id`
- DELETE: never

---

#### `group_members`
| Column | Type | Notes |
|---|---|---|
| `group_id` | `uuid NOT NULL` | References `groups.id` ON DELETE CASCADE |
| `player_id` | `uuid NOT NULL` | References `profiles.id` ON DELETE RESTRICT |
| `joined_at` | `timestamptz NOT NULL DEFAULT clock_timestamp()` | Server-assigned |
| `role` | `text NOT NULL DEFAULT 'member'` | CHECK: `IN ('owner','member')` |
| PRIMARY KEY | `(group_id, player_id)` | |

**Single-owner enforcement:**
```sql
CREATE UNIQUE INDEX one_owner_per_group ON group_members (group_id) WHERE role = 'owner';
```

Ownership transfer via `transfer_group_ownership(group_id, new_owner_id)` SECURITY DEFINER function — atomically demotes current owner and promotes new owner in one transaction.

**RLS:** All mutations via SECURITY DEFINER helper functions only. Direct INSERT/UPDATE/DELETE blocked to prevent recursive policy loops.

---

#### `group_invites`
Raw token never stored — SHA-256 hash only. All operations via trusted functions.

| Column | Type | Notes |
|---|---|---|
| `id` | `uuid PK DEFAULT gen_random_uuid()` | |
| `group_id` | `uuid NOT NULL` | References `groups.id` ON DELETE CASCADE |
| `created_by` | `uuid NOT NULL` | References `profiles.id` |
| `token_hash` | `text NOT NULL UNIQUE` | SHA-256 of raw token; raw token returned once, never stored |
| `created_at` | `timestamptz NOT NULL DEFAULT clock_timestamp()` | Server-assigned |
| `expires_at` | `timestamptz NOT NULL` | `created_at + INTERVAL '7 days'`; server-assigned |
| `accepted_by` | `uuid` | References `profiles.id`; NULL until redeemed |
| `accepted_at` | `timestamptz` | NULL until redeemed; server-assigned |
| `revoked_at` | `timestamptz` | NULL unless revoked; server-assigned |
| `revoked_by` | `uuid` | References `profiles.id` |

**Functions:**
- `create_group_invite(group_id)` — caller must be group member; generates high-entropy token server-side; stores hash; returns raw token once
- `redeem_group_invite(raw_token)` — hashes token; validates not expired/revoked/already accepted; inserts into `group_members`; marks accepted; atomic
- `revoke_group_invite(invite_id)` — group owner or creator only

**RLS:**
- SELECT: own invites only (`created_by = auth.uid()`)
- INSERT/UPDATE/DELETE: blocked (functions only)

---

#### `rules_versions`
Immutable. Seeded at migration. Trigger prevents all UPDATE/DELETE.

| Column | Type | Notes |
|---|---|---|
| `id` | `uuid PK` | |
| `version_tag` | `text NOT NULL UNIQUE` | e.g. `'v1'` |
| `description` | `text NOT NULL` | Human-readable summary |
| `config` | `jsonb NOT NULL` | Machine-readable structured config |
| `created_at` | `timestamptz NOT NULL DEFAULT now()` | |

**v1 config:**
```json
{
  "algorithm": "ordinal_ranking_v1",
  "minimum_duration_seconds": 3600,
  "maximum_duration_seconds": 172800,
  "duration_step_seconds": 3600,
  "default_duration_seconds": 7200,
  "tiebreak_method": "receipt_sequence_ascending",
  "point_formula": "effective_eligible_count - rank + 1, minimum 1",
  "normalization_version": "v1",
  "normalization_steps": ["lowercase","strip_apostrophes","strip_punctuation","strip_hyphens","collapse_whitespace","trim"],
  "matching_rules": {
    "what": "normalized_equality_against_canonical_dish_or_active_dish_alias",
    "where": "normalized_equality_required_for_both_restaurant_and_city",
    "partial_credit": false,
    "substring_match": false
  }
}
```

**Algorithm note:** `ordinal_ranking_v1` — `receipt_sequence` deterministically resolves all ties, producing unique ordinal ranks (no shared ranks).

**RLS:**
- SELECT: any authenticated user
- INSERT/UPDATE/DELETE: never (trigger enforces immutability)

---

#### `media_objects`
Opaque client-facing record. Contains no storage path information.

| Column | Type | Notes |
|---|---|---|
| `id` | `uuid PK DEFAULT gen_random_uuid()` | Opaque handle given to client |
| `uploader_id` | `uuid NOT NULL` | References `profiles.id` |
| `mime_type` | `text NOT NULL` | e.g. `'image/jpeg'` |
| `file_size_bytes` | `integer` | |
| `status` | `text NOT NULL DEFAULT 'processing'` | CHECK: `IN ('processing','ready','failed')` |
| `re_encoded_at` | `timestamptz` | NULL until server re-encoding complete |
| `created_at` | `timestamptz NOT NULL DEFAULT now()` | |

**RLS:**
- SELECT: uploader only (no storage path in this table)
- INSERT/UPDATE/DELETE: service role only (via Edge Function)

---

#### `media_storage_keys`
Server-only. No client access of any kind. Storage paths never leave this table.

| Column | Type | Notes |
|---|---|---|
| `media_object_id` | `uuid PK` | References `media_objects.id` ON DELETE CASCADE |
| `storage_key` | `text NOT NULL` | Original upload path; internal only |
| `re_encoded_storage_key` | `text` | Server-re-encoded copy path; NULL until ready |

**RLS:** No policies granting any client access. Service role only. Zero rows returned to any authenticated client query.

---

#### `challenges`
| Column | Type | Notes |
|---|---|---|
| `id` | `uuid PK DEFAULT gen_random_uuid()` | |
| `poster_id` | `uuid NOT NULL` | References `profiles.id`; set server-side; client cannot supply |
| `group_id` | `uuid NOT NULL` | References `groups.id` ON DELETE RESTRICT |
| `state` | `text NOT NULL DEFAULT 'draft'` | CHECK: valid states; client cannot write directly |
| `media_object_id` | `uuid` | References `media_objects.id`; NULL in draft |
| `duration_seconds` | `integer NOT NULL DEFAULT 7200` | CHECK: BETWEEN 3600 AND 172800 AND % 3600 = 0 |
| `rules_version_id` | `uuid NOT NULL DEFAULT 'a0000000-0000-0000-0000-000000000001'` | References `rules_versions.id`; immutable after creation |
| `posted_at` | `timestamptz` | Server-assigned on state→active; client value overwritten |
| `deadline_at` | `timestamptz` | Server-assigned as `posted_at + duration_seconds * interval '1 second'` |
| `locked_at` | `timestamptz` | Server-assigned on state→locked |
| `revealed_at` | `timestamptz` | Server-assigned on state→revealed |
| `cancelled_at` | `timestamptz` | Server-assigned on state→cancelled |
| `cancellation_reason` | `text` | |
| `created_at` | `timestamptz NOT NULL DEFAULT clock_timestamp()` | |

**State constraint:** `CHECK (state IN ('draft','active','locked','revealed','cancelled'))`

**State machine trigger (BEFORE UPDATE on `challenges`):**
- Validates transition is legal; raises exception otherwise
- On state→active: sets `poster_id = auth.uid()`, `posted_at = clock_timestamp()`, `deadline_at = clock_timestamp() + (duration_seconds || ' seconds')::interval`
- On state→locked: sets `locked_at = clock_timestamp()`
- On state→revealed: sets `revealed_at = clock_timestamp()`
- On state→cancelled: sets `cancelled_at = clock_timestamp()`
- Overwrites all server timestamps regardless of client-supplied values
- Challenge must always start as `draft`; a client INSERT that supplies any other state is rejected

**Column protections (BEFORE INSERT/UPDATE trigger):**
- `poster_id` set to `auth.uid()` on INSERT; cannot be changed after
- `group_id`, `rules_version_id` immutable after creation
- State can only be changed by trusted server operations (state machine trigger validates)

**RLS:**
- SELECT: poster (all states including draft) OR group members (non-draft states only)
- INSERT: group member with `onboarding_complete = true`; state forced to `'draft'` by trigger
- UPDATE: poster only; scoped to editable fields; state changes via trusted functions only
- DELETE: never

---

#### `challenge_secrets`
| Column | Type | Notes |
|---|---|---|
| `challenge_id` | `uuid PK` | References `challenges.id` ON DELETE CASCADE |
| `display_dish` | `text NOT NULL` | CHECK: length > 0 |
| `canonical_dish` | `text NOT NULL` | Normalized; CHECK: length > 0 |
| `display_restaurant` | `text NOT NULL` | CHECK: length > 0 |
| `canonical_restaurant` | `text NOT NULL` | Normalized; CHECK: length > 0 |
| `display_city` | `text NOT NULL` | CHECK: length > 0 |
| `canonical_city` | `text NOT NULL` | Normalized; CHECK: length > 0 |
| `story` | `text` | Shown after reveal only |
| `has_first_guess` | `boolean NOT NULL DEFAULT false` | Convenience; redundantly enforced by trigger |
| `created_at` | `timestamptz NOT NULL DEFAULT now()` | |
| `updated_at` | `timestamptz NOT NULL DEFAULT now()` | |

**Answer-lock trigger (BEFORE UPDATE on `challenge_secrets`):**
After any guess attempt exists for the challenge, raises exception on any attempt to change: `display_dish`, `canonical_dish`, `display_restaurant`, `canonical_restaurant`, `display_city`, `canonical_city`. Also sets `has_first_guess = true` when first guess arrives (via guess_attempts trigger).

**Alias lock:** After first guess, new aliases cannot be added and existing aliases cannot be deactivated by direct client action. Post-reveal corrections go through the trusted `apply_correction()` transaction only.

**RLS:**
- SELECT: poster OR (challenge `state = 'revealed'` AND viewer is group member)
- INSERT: poster; `challenge_id` must reference a challenge where `poster_id = auth.uid()`
- UPDATE: poster only, while `has_first_guess = false`
- DELETE: never

---

#### `challenge_answer_aliases`
| Column | Type | Notes |
|---|---|---|
| `id` | `uuid PK DEFAULT gen_random_uuid()` | |
| `challenge_id` | `uuid NOT NULL` | References `challenges.id` ON DELETE CASCADE |
| `field` | `text NOT NULL` | CHECK: `IN ('dish','restaurant','city')` |
| `display_value` | `text NOT NULL` | CHECK: length > 0 |
| `normalized_value` | `text NOT NULL` | CHECK: length > 0 |
| `created_by` | `uuid NOT NULL` | References `profiles.id` |
| `created_at` | `timestamptz NOT NULL DEFAULT now()` | |
| `is_active` | `boolean NOT NULL DEFAULT true` | |

**Alias lock trigger:** Rejects INSERT and UPDATE when `challenge_secrets.has_first_guess = true` for the challenge (unless called by trusted correction transaction).

**RLS:** Same visibility as `challenge_secrets`.

---

#### `eligible_participants`
| Column | Type | Notes |
|---|---|---|
| `id` | `uuid PK DEFAULT gen_random_uuid()` | |
| `challenge_id` | `uuid NOT NULL` | References `challenges.id` ON DELETE RESTRICT |
| `player_id` | `uuid NOT NULL` | References `profiles.id` ON DELETE RESTRICT |
| `snapshot_display_name` | `text NOT NULL` | Locked at post time |
| `snapshot_avatar_color` | `text NOT NULL` | Locked at post time |
| `added_at` | `timestamptz NOT NULL DEFAULT clock_timestamp()` | |
| UNIQUE | `(challenge_id, player_id)` | |

**Note:** Poster is included in `eligible_participants` (for scoring count purposes) but is explicitly excluded from guessing by RLS on `guess_attempts`. The `effective_eligible_count` in `score_runs` is the count of eligible participants minus the poster.

**RLS:**
- SELECT: group members of the challenge's group
- INSERT/UPDATE/DELETE: service role only

---

#### `exclusion_events`
| Column | Type | Notes |
|---|---|---|
| `id` | `uuid PK DEFAULT gen_random_uuid()` | |
| `challenge_id` | `uuid NOT NULL` | References `challenges.id` ON DELETE RESTRICT |
| `player_id` | `uuid NOT NULL` | References `profiles.id` |
| `reason` | `text NOT NULL` | CHECK: `IN ('withdrew','removed')` |
| `excluded_by` | `uuid NOT NULL` | References `profiles.id` |
| `excluded_at` | `timestamptz NOT NULL DEFAULT clock_timestamp()` | Server-assigned |
| UNIQUE | `(challenge_id, player_id)` | A player may be excluded only once per challenge |

**Rules:**
- Withdrawal (`reason='withdrew'`): self only; allowed only when challenge `state = 'active'`
- Removal (`reason='removed'`): poster or group owner only; allowed only when challenge `state = 'active'`
- Neither withdrawal nor removal is permitted when challenge is `locked`, `revealed`, or `cancelled`
- Trigger validates player was in `eligible_participants` and is not already excluded
- `excluded_by` must equal `auth.uid()`

**RLS:**
- SELECT: group members
- INSERT: self (withdrew, active only) OR poster/group-owner (removed, active only); trigger enforces
- UPDATE/DELETE: never

---

#### `hints`
| Column | Type | Notes |
|---|---|---|
| `id` | `uuid PK DEFAULT gen_random_uuid()` | |
| `challenge_id` | `uuid NOT NULL` | References `challenges.id` ON DELETE RESTRICT |
| `poster_id` | `uuid NOT NULL` | References `profiles.id` |
| `text` | `text NOT NULL` | CHECK: `length(trim(text)) BETWEEN 1 AND 500` |
| `posted_at` | `timestamptz NOT NULL DEFAULT clock_timestamp()` | Server-assigned; client value overwritten |

**RLS:**
- SELECT: group members; challenge must be active or later
- INSERT: poster only (`poster_id = auth.uid()`); challenge must be `active`
- UPDATE/DELETE: never

---

#### `guess_attempts`
Immutable append-only. Split by race. No correctness fields.

| Column | Type | Notes |
|---|---|---|
| `id` | `uuid PK DEFAULT gen_random_uuid()` | |
| `challenge_id` | `uuid NOT NULL` | References `challenges.id` ON DELETE RESTRICT |
| `player_id` | `uuid NOT NULL` | References `profiles.id` |
| `race` | `text NOT NULL` | CHECK: `IN ('what','where')` |
| `dish_guess` | `text` | Required for `race='what'`; CHECK: non-whitespace when not null |
| `restaurant_guess` | `text` | Required for `race='where'`; CHECK: non-whitespace when not null |
| `city_guess` | `text` | Required for `race='where'`; CHECK: non-whitespace when not null |
| `received_at` | `timestamptz NOT NULL` | Set to `clock_timestamp()` by BEFORE INSERT trigger; overwrites client value |
| `receipt_sequence` | `bigint NOT NULL` | Set to `nextval('guess_receipt_seq')` by BEFORE INSERT trigger; overwrites client value |
| `client_submitted_at` | `timestamptz` | For display only; never used for ranking |
| UNIQUE | `(challenge_id, receipt_sequence)` | |

**Race field constraint:**
```sql
CHECK (
  (race = 'what'  AND dish_guess IS NOT NULL AND length(trim(dish_guess)) > 0
                  AND restaurant_guess IS NULL AND city_guess IS NULL)
  OR
  (race = 'where' AND dish_guess IS NULL
                  AND restaurant_guess IS NOT NULL AND length(trim(restaurant_guess)) > 0
                  AND city_guess IS NOT NULL AND length(trim(city_guess)) > 0)
)
```

**BEFORE INSERT trigger `set_guess_receipt_fields`:**
1. Overwrites `received_at = clock_timestamp()`
2. Overwrites `receipt_sequence = nextval('guess_receipt_seq')`
3. Verifies `clock_timestamp() < challenges.deadline_at` for the challenge; raises exception if at or past deadline
4. Verifies `player_id = auth.uid()` (anti-spoof)
5. Sets `challenge_secrets.has_first_guess = true` if not already set

**RLS INSERT policy:**
```
player_id = auth.uid()
AND challenge is 'active'
AND clock_timestamp() < deadline_at
AND player is in eligible_participants
AND player is not in exclusion_events
AND player is not the poster
AND player has onboarding_complete = true
```

**RLS SELECT:**
- Before reveal: own rows only
- After reveal (`state = 'revealed'`): all group members

**UPDATE/DELETE: never**

---

#### `guess_judgments`
Immutable. Written by trusted `reveal_challenge()` or `apply_correction()` functions.

| Column | Type | Notes |
|---|---|---|
| `id` | `uuid PK DEFAULT gen_random_uuid()` | |
| `score_run_id` | `uuid NOT NULL` | References `score_runs.id` |
| `guess_attempt_id` | `uuid NOT NULL` | References `guess_attempts.id` |
| `player_id` | `uuid NOT NULL` | References `profiles.id` — must match guess_attempt's player_id (trigger enforced) |
| `challenge_id` | `uuid NOT NULL` | References `challenges.id` — must match guess_attempt's challenge_id (trigger enforced) |
| `race` | `text NOT NULL` | CHECK: `IN ('what','where')` — must match guess_attempt's race (trigger enforced) |
| `rules_version_id` | `uuid NOT NULL` | References `rules_versions.id` — must match score_run's rules_version_id (trigger enforced) |
| `is_correct` | `boolean NOT NULL` | |
| `is_first_correct_for_player` | `boolean NOT NULL DEFAULT false` | True = this player's earliest correct attempt for this race in this score run; at most one qualifying attempt per (score_run, player, race) |
| `created_at` | `timestamptz NOT NULL DEFAULT now()` | |
| UNIQUE | `(score_run_id, guess_attempt_id)` | |
| UNIQUE | `(score_run_id, player_id, race) WHERE is_first_correct_for_player = true` | Enforces at most one qualifying attempt per player per race per run |

**RLS:**
- SELECT: group members (after reveal)
- INSERT/UPDATE/DELETE: service role only

---

#### `score_runs`
One row per scoring event. Current run = MAX(`revision_number`) for a given challenge.

| Column | Type | Notes |
|---|---|---|
| `id` | `uuid PK DEFAULT gen_random_uuid()` | |
| `challenge_id` | `uuid NOT NULL` | References `challenges.id` ON DELETE RESTRICT |
| `revision_number` | `integer NOT NULL` | 1 for initial reveal; increments per correction |
| `rules_version_id` | `uuid NOT NULL` | References `rules_versions.id` |
| `effective_eligible_count` | `integer NOT NULL` | CHECK: `>= 0`; count of eligible non-poster participants; may be 0 |
| `triggering_correction_id` | `uuid` | References `correction_events.id`; NULL for initial scoring |
| `created_at` | `timestamptz NOT NULL DEFAULT now()` | |
| UNIQUE | `(challenge_id, revision_number)` | |

**Current run:** Defined as `MAX(revision_number)` per challenge. No `is_current` column — eliminates concurrent-correction race condition.

**`current_score_events` view:** Exposes only `score_events` joined to the MAX-revision `score_runs` per challenge. Client leaderboard queries use this view; cannot accidentally sum all revisions. View inherits underlying RLS.

**RLS:**
- SELECT: group members (after reveal)
- INSERT: service role only
- UPDATE/DELETE: never

---

#### `score_events`
One row per player per score run.

| Column | Type | Notes |
|---|---|---|
| `id` | `uuid PK DEFAULT gen_random_uuid()` | |
| `score_run_id` | `uuid NOT NULL` | References `score_runs.id` |
| `challenge_id` | `uuid NOT NULL` | References `challenges.id` (denormalized for RLS; trigger verifies match) |
| `player_id` | `uuid NOT NULL` | References `profiles.id` |
| `rules_version_id` | `uuid NOT NULL` | References `rules_versions.id` (trigger verifies match to score_run) |
| `what_points` | `integer NOT NULL DEFAULT 0` | CHECK: `>= 0` |
| `where_points` | `integer NOT NULL DEFAULT 0` | CHECK: `>= 0` |
| `total_points` | `integer NOT NULL GENERATED ALWAYS AS (what_points + where_points) STORED` | |
| `what_rank` | `integer` | NULL = no correct What? answer; CHECK: `> 0` when not null |
| `where_rank` | `integer` | NULL = no correct Where? answer; CHECK: `> 0` when not null |
| `scored_at` | `timestamptz NOT NULL DEFAULT now()` | |
| UNIQUE | `(score_run_id, player_id)` | |

**RLS:**
- SELECT: group members (after reveal); leaderboard queries use `current_score_events` view
- INSERT: service role only
- UPDATE/DELETE: never

---

#### `correction_events`
Append-only audit trail. `resulting_score_run_id` is set by the atomic `apply_correction()` transaction after the score run is created.

| Column | Type | Notes |
|---|---|---|
| `id` | `uuid PK DEFAULT gen_random_uuid()` | |
| `challenge_id` | `uuid NOT NULL` | References `challenges.id` ON DELETE RESTRICT |
| `corrected_by` | `uuid NOT NULL` | References `profiles.id`; must be poster or group owner |
| `field` | `text NOT NULL` | CHECK: `IN ('dish','restaurant','city','alias_added','alias_removed')` |
| `old_value` | `text` | |
| `new_value` | `text` | |
| `reason` | `text NOT NULL` | CHECK: `length(trim(reason)) > 0` |
| `resulting_score_run_id` | `uuid` | References `score_runs.id`; set by `apply_correction()` after score run created |
| `corrected_at` | `timestamptz NOT NULL DEFAULT clock_timestamp()` | Server-assigned |

**`apply_correction()` atomic transaction (SECURITY DEFINER):**
1. Validates caller is poster or group owner; challenge is revealed
2. INSERTs `correction_events` row (without `resulting_score_run_id`)
3. Updates `challenge_secrets` or `challenge_answer_aliases` with corrected value
4. Creates new `score_runs` row (revision_number = MAX + 1, triggering_correction_id = correction id)
5. Re-evaluates all non-withdrawn guess attempts against corrected answers
6. INSERTs `guess_judgments` for this run
7. INSERTs `score_events` for this run
8. UPDATEs `correction_events.resulting_score_run_id` = new score run id
9. All steps in a single transaction; any failure rolls back entirely

**RLS:**
- SELECT: group members (after reveal)
- INSERT/UPDATE: via `apply_correction()` function only; direct access blocked
- DELETE: never

---

#### `comments`
| Column | Type | Notes |
|---|---|---|
| `id` | `uuid PK DEFAULT gen_random_uuid()` | |
| `challenge_id` | `uuid NOT NULL` | References `challenges.id` ON DELETE RESTRICT |
| `author_id` | `uuid NOT NULL` | References `profiles.id` |
| `text` | `text NOT NULL` | CHECK: `length(trim(text)) BETWEEN 1 AND 1000` |
| `posted_at` | `timestamptz NOT NULL DEFAULT clock_timestamp()` | Server-assigned |
| `deleted_at` | `timestamptz` | Soft delete |

**Allowed challenge states for comments:** `'revealed'` only (comments are a post-reveal conversation feature).

**Soft-delete trigger (BEFORE UPDATE):** Permits only setting `deleted_at`; any attempt to change `text`, `author_id`, `challenge_id`, or `posted_at` raises exception.

**RLS:**
- SELECT: group members; challenge must be revealed
- INSERT: group members; `author_id = auth.uid()`; challenge must be revealed; `posted_at` overwritten by trigger
- UPDATE: own rows only (`author_id = auth.uid()`); restricted to `deleted_at` only by trigger
- DELETE: never (soft delete only)

---

#### `reactions`
| Column | Type | Notes |
|---|---|---|
| `id` | `uuid PK DEFAULT gen_random_uuid()` | |
| `challenge_id` | `uuid NOT NULL` | References `challenges.id` ON DELETE RESTRICT |
| `player_id` | `uuid NOT NULL` | References `profiles.id` |
| `emoji` | `text NOT NULL` | CHECK: `length(emoji) BETWEEN 1 AND 8` |
| `reacted_at` | `timestamptz NOT NULL DEFAULT clock_timestamp()` | Server-assigned |
| UNIQUE | `(challenge_id, player_id, emoji)` | |

**Allowed challenge states for reactions:** `'revealed'` only.

**RLS:**
- SELECT: group members; challenge must be revealed
- INSERT: group members; `player_id = auth.uid()`; challenge must be revealed
- DELETE: own rows only (`player_id = auth.uid()`)
- UPDATE: never

---

### 3. Triggers Summary

| Trigger | Table | Event | Purpose |
|---|---|---|---|
| `handle_new_user` | `auth.users` | AFTER INSERT | Creates profile (nullable display_name); SECURITY DEFINER; fixed search_path |
| `enforce_challenge_state_machine` | `challenges` | BEFORE UPDATE | Validates transitions; assigns server timestamps via clock_timestamp() |
| `protect_challenge_authority_fields` | `challenges` | BEFORE INSERT/UPDATE | Sets poster_id=auth.uid(); forces initial state='draft'; blocks client changes to authority fields |
| `set_guess_receipt_fields` | `guess_attempts` | BEFORE INSERT | Sets received_at=clock_timestamp(), receipt_sequence=nextval(); enforces deadline; sets has_first_guess |
| `guard_answer_edits_after_first_guess` | `challenge_secrets` | BEFORE UPDATE | Blocks canonical/display field changes after any guess exists |
| `guard_alias_edits_after_first_guess` | `challenge_answer_aliases` | BEFORE INSERT/UPDATE | Blocks changes when has_first_guess=true (unless trusted context) |
| `protect_rules_versions` | `rules_versions` | BEFORE UPDATE/DELETE | Always raises exception |
| `restrict_comment_updates` | `comments` | BEFORE UPDATE | Permits only deleted_at change; blocks text modification |
| `enforce_exclusion_rules` | `exclusion_events` | BEFORE INSERT | Validates player is eligible, not already excluded, challenge is active |
| `lock_onboarding_complete` | `profiles` | BEFORE UPDATE | Prevents onboarding_complete being set back to false |

---

### 4. SECURITY DEFINER Functions (private schema, fixed search_path, restricted EXECUTE grants)

**Membership helpers (used in RLS policies):**
- `private.is_group_member(group_id uuid) → boolean`
- `private.is_challenge_group_member(challenge_id uuid) → boolean`
- `private.is_challenge_poster(challenge_id uuid) → boolean`
- `private.is_challenge_revealed(challenge_id uuid) → boolean`
- `private.is_eligible_non_excluded_non_poster(challenge_id uuid) → boolean`

**Operational functions:**
- `public.create_group(name text) → uuid` — atomic group + owner membership creation
- `public.transfer_group_ownership(group_id uuid, new_owner_id uuid) → void`
- `public.create_group_invite(group_id uuid) → text` — returns raw token once
- `public.redeem_group_invite(raw_token text) → uuid` — returns group_id; atomic
- `public.revoke_group_invite(invite_id uuid) → void`
- `public.apply_correction(challenge_id uuid, field text, new_value text, reason text) → uuid` — returns new score_run_id; atomic 8-step transaction

All functions: `SET search_path = ''`; `EXECUTE` revoked from `PUBLIC`; granted only to `authenticated` role where appropriate.

---

### 5. Indexes

| Table | Columns | Reason |
|---|---|---|
| `group_members` | `player_id` | RLS membership checks |
| `group_members` | `group_id` | Group member lookups |
| `challenges` | `(group_id, state)` | Feed queries |
| `challenges` | `poster_id` | Poster-specific views |
| `challenges` | `deadline_at` | Auto-close scheduler |
| `challenge_answer_aliases` | `(challenge_id, field, is_active)` | Matching lookups |
| `guess_attempts` | `(challenge_id, race, player_id)` | Per-player per-race lookups |
| `guess_attempts` | `(challenge_id, receipt_sequence)` | Rank ordering |
| `guess_judgments` | `score_run_id` | Scoring joins |
| `guess_judgments` | `(score_run_id, player_id, race)` | Qualifying-attempt lookups |
| `score_events` | `(challenge_id, player_id)` | Leaderboard queries |
| `score_runs` | `(challenge_id, revision_number DESC)` | Current-run lookups |
| `exclusion_events` | `(challenge_id, player_id)` | Eligibility checks |
| `eligible_participants` | `(challenge_id, player_id)` | RLS eligibility checks |
| `group_invites` | `token_hash` | Invite redemption |
| `group_invites` | `group_id` | Group invite management |

All foreign key columns indexed.

---

### 6. Foreign Key ON DELETE Behavior

| Referencing table | ON DELETE |
|---|---|
| `profiles.id` (most tables) | RESTRICT |
| `groups.id` → `group_members` | CASCADE |
| `groups.id` → `challenges` | RESTRICT |
| `groups.id` → `group_invites` | CASCADE |
| `challenges.id` → `challenge_secrets` | CASCADE |
| `challenges.id` → `challenge_answer_aliases` | CASCADE |
| `challenges.id` → `guess_attempts` | RESTRICT |
| `challenges.id` → `eligible_participants` | RESTRICT |
| `media_objects.id` → `media_storage_keys` | CASCADE |
| `score_runs.id` → `score_events` | RESTRICT |
| `score_runs.id` → `guess_judgments` | RESTRICT |

---

### 7. Seed Data

```sql
INSERT INTO rules_versions (id, version_tag, description, config) VALUES (
  'a0000000-0000-0000-0000-000000000001',
  'v1',
  'Ordinal ranking. receipt_sequence deterministically resolves all timestamp ties; all ranks are unique.',
  '{
    "algorithm": "ordinal_ranking_v1",
    "minimum_duration_seconds": 3600,
    "maximum_duration_seconds": 172800,
    "duration_step_seconds": 3600,
    "default_duration_seconds": 7200,
    "tiebreak_method": "receipt_sequence_ascending",
    "point_formula": "effective_eligible_count - rank + 1, minimum 1",
    "normalization_version": "v1",
    "normalization_steps": ["lowercase","strip_apostrophes","strip_punctuation","strip_hyphens","collapse_whitespace","trim"],
    "matching_rules": {
      "what": "normalized_equality_against_canonical_dish_or_active_dish_alias",
      "where": "normalized_equality_required_for_both_restaurant_and_city",
      "partial_credit": false,
      "substring_match": false
    }
  }'
);
```

---

### 8. Account Deletion

On deletion request: `profiles.deleted_at` set; `auth.users` record retained (Supabase soft delete). All RESTRICT foreign keys preserve game history. Client view `public.player_profiles` substitutes `'Former Player'` display name and NULL avatar for deleted accounts. Internal `profiles` table retains true values for audit purposes.

---

### 9. Nonblocking Roadmap (explicitly deferred to later steps)

- Push-notification device registration
- Universal invite links (in addition to custom URL scheme)
- Rate limiting (guessing, commenting, reactions, invites, uploads)
- Reporting/blocking and moderation
- Rules for archived groups

---

## Deployment Gate

Before applying migration to live Supabase project:
1. Claude presents complete migration SQL and automated test results
2. Codex/GPT reviews security-sensitive SQL
3. Bill explicitly approves remote deployment

---

## Acceptance Criteria

- [ ] All 20 tables created with correct columns, types, and constraints
- [ ] All 16 SECURITY DEFINER functions deployed; EXECUTE revoked from PUBLIC; correctly re-granted
- [ ] All 10 triggers in place
- [ ] `guess_receipt_seq` PostgreSQL sequence created
- [ ] All indexes created
- [ ] `rules_versions` seeded with v1 row
- [ ] `current_score_events` view created with correct RLS inheritance
- [ ] `public.player_profiles` view substitutes "Former Player" correctly
- [ ] Migration is version-controlled SQL

**RLS and Logic Acceptance Tests:**

Duration:
- [ ] Every whole-hour value 1–48 accepted
- [ ] Sub-1-hour, over-48-hour, and non-whole-hour values rejected

Authentication and visibility:
- [ ] Anonymous user denied on all tables
- [ ] Authenticated non-member denied on all group-scoped tables
- [ ] Member of a different group denied
- [ ] Draft challenge visible to poster only; invisible to group members
- [ ] `SELECT *` on `media_objects` returns no storage path columns (none exist in table)
- [ ] `SELECT *` on `media_storage_keys` returns zero rows to any authenticated client
- [ ] Poster can read `challenge_secrets` before reveal
- [ ] Non-poster cannot read `challenge_secrets` before reveal
- [ ] Group members can read `challenge_secrets` after reveal

Challenge authority:
- [ ] Client cannot create a non-draft challenge
- [ ] Client cannot directly set or change state, poster_id, group_id, rules_version_id
- [ ] Client-supplied `posted_at`, `deadline_at`, and other server timestamps are overwritten
- [ ] Invalid state transitions (e.g. draft→revealed) fail

Guessing:
- [ ] Client-supplied `received_at` and `receipt_sequence` are overwritten
- [ ] Client cannot supply correctness values
- [ ] Client cannot spoof `player_id`
- [ ] Poster cannot insert a guess on own challenge
- [ ] Excluded participant cannot insert a guess
- [ ] Guess submitted at or after `deadline_at` is rejected even if `state = 'active'`
- [ ] Whitespace-only guess fields are rejected
- [ ] What? and Where? submit independently with independent timestamps
- [ ] Concurrent guesses receive distinct `receipt_sequence` values

Answers and aliases:
- [ ] Answer display/canonical values cannot change after first guess received
- [ ] New aliases cannot be added after first guess received
- [ ] Existing aliases cannot be deactivated after first guess received
- [ ] Post-reveal corrections require `apply_correction()` function

Scoring:
- [ ] `total_points = what_points + where_points` enforced as generated column
- [ ] At most one `is_first_correct_for_player = true` per (score_run, player, race)
- [ ] Leaderboard via `current_score_events` view reflects only MAX revision
- [ ] Concurrent corrections cannot create two score runs with the same revision_number
- [ ] Poster excluded from eligible count

Exclusions:
- [ ] Duplicate exclusions for same player/challenge fail
- [ ] Withdrawal not permitted when challenge is locked, revealed, or cancelled
- [ ] Removal not permitted when challenge is locked, revealed, or cancelled

Comments and reactions:
- [ ] Comments and reactions only allowed when challenge is revealed
- [ ] Comment text cannot be updated; only deleted_at can be set
- [ ] Reaction player_id cannot be spoofed

Invites:
- [ ] Direct INSERT into `group_invites` blocked
- [ ] Invite expiry cannot be set by client
- [ ] Raw token not recoverable from database
- [ ] Expired invite rejected at redemption
- [ ] Revoked invite rejected at redemption
- [ ] Already-accepted invite rejected at redemption
- [ ] Already-a-member redemption handled gracefully

Account deletion:
- [ ] Deleted player appears as "Former Player" in `public.player_profiles` view

Functions:
- [ ] Anonymous and authenticated roles cannot EXECUTE private helper functions directly
- [ ] `apply_correction()` rolls back entirely on any step failure

---

## Review Checklist (for Codex/GPT)

1. Does the `media_storage_keys` separation fully prevent client access to storage paths, including `SELECT *`?
2. Are all authority-field column protections in triggers sufficient, or are column-level privileges also required?
3. Is `clock_timestamp()` used correctly everywhere a server-authoritative time is needed?
4. Is the `apply_correction()` 8-step atomic transaction complete and correctly ordered?
5. Is removing `is_current` and deriving current run from MAX(revision_number) safe under concurrent corrections?
6. Is the `current_score_events` view definition correct and does it inherit RLS properly?
7. Is the `player_profiles` view approach sufficient for hiding deleted identity?
8. Are the SECURITY DEFINER function grants and search_path specifications complete?
9. Is the partial unique index for single group owner sufficient given all creation and transfer scenarios?
10. Is anything missing given the full game mechanics?
11. Duration (1–48 hours, whole-hour steps, default 2 hours) is a confirmed Bill decision — please confirm schema reflects it correctly rather than flagging it as an error.
