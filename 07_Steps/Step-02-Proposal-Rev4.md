# Step 2 Proposal — Supabase Project & Database Schema (Revision 4)

**Status:** Pending review (Claude → Codex/GPT → Bill approval)
**Prerequisite:** Step 1 approved ✅
**Supersedes:** Step-02-Proposal-Rev3.md
**Governance gate:** Bill must type `APPROVED: Step 2 — Supabase Project & Database Schema` before any code is written.

---

## Changes from Revision 3

All required changes from Rev 3 GPT review incorporated:

1. Views replaced with `security_invoker = true` approach; `profiles` split into public table (client-safe, mutated on deletion) and `private.profile_archive` (audit-only, zero client access)
2. `eligible_participants.snapshot_display_name` removed; display names looked up via `profiles` at query time; poster excluded from snapshot
3. All four lifecycle functions defined: `activate_challenge`, `lock_challenge`, `reveal_challenge`, `cancel_challenge`
4. Challenge row locked before revision calculation in `apply_correction()` and `reveal_challenge()`
5. `correction_events` redesigned with `action`/`target_field`/`alias_id` structure
6. One-active-challenge-per-poster partial unique index added
7. Guess visibility confirmed: poster sees all guesses during active/locked; each player sees own; all see all after reveal
8. `media_storage_keys` moved to private schema
9. All max-length constraints added
10. Function count reconciled: 15 functions listed explicitly
11. `deleted_at` replaced with `is_active` on `profiles`; all mutation policies check `is_active = true`

---

## Duration (Confirmed)

Any whole-hour value from 1–48 hours. Default 2 hours.
```sql
CHECK (duration_seconds BETWEEN 3600 AND 172800 AND duration_seconds % 3600 = 0)
```

## Guess Visibility (Confirmed)

- Poster sees all guesses on their own challenge while state is `active` or `locked`
- Each player sees only their own guesses before reveal
- After reveal, all group members see all guesses

---

## Schema — Tables

19 client-accessible tables + 2 private-schema tables (21 total).

---

### `profiles`
Identity is mutated on deletion (not merely soft-flagged). Original values archived in `private.profile_archive`.

| Column | Type | Notes |
|---|---|---|
| `id` | `uuid PK` | References `auth.users.id` |
| `display_name` | `text` | Nullable until onboarding; set to `'Former Player'` on account deletion |
| `avatar_color` | `text NOT NULL DEFAULT 'orange'` | CHECK: valid color; set to `'gray'` on deletion |
| `avatar_media_object_id` | `uuid` | References `media_objects.id`; NULL on deletion |
| `onboarding_complete` | `boolean NOT NULL DEFAULT false` | Gates game participation; once true, cannot revert |
| `is_active` | `boolean NOT NULL DEFAULT true` | Set to `false` on deletion; all mutation policies require `is_active = true` |
| `created_at` | `timestamptz NOT NULL DEFAULT now()` | |

**Constraints:**
```sql
CHECK (avatar_color IN ('orange','red','blue','green','purple','yellow','pink','teal','gray'))
CHECK (onboarding_complete = false OR (display_name IS NOT NULL AND length(trim(display_name)) BETWEEN 1 AND 50))
```

**Deletion behavior:** Trusted `delete_account()` SECURITY DEFINER function:
1. Archives original `display_name`, `avatar_color`, `avatar_media_object_id` to `private.profile_archive`
2. Sets `display_name = 'Former Player'`, `avatar_color = 'gray'`, `avatar_media_object_id = NULL`, `is_active = false`
3. Soft-deletes the Supabase Auth user record

**RLS:**
- SELECT: `id = auth.uid()` OR shares a group via `private.is_group_member_with(profile_id)`
- UPDATE: `id = auth.uid() AND is_active = true`; `id`, `created_at`, `is_active` immutable by client; `onboarding_complete` locked to true by trigger
- INSERT: trigger only
- DELETE: never (use `delete_account()`)

---

### `private.profile_archive`
No client access of any kind. Stores pre-deletion identity for audit.

| Column | Type | Notes |
|---|---|---|
| `profile_id` | `uuid PK` | References `profiles.id` |
| `original_display_name` | `text` | |
| `original_avatar_color` | `text` | |
| `original_avatar_media_object_id` | `uuid` | |
| `archived_at` | `timestamptz NOT NULL DEFAULT clock_timestamp()` | |

**Access:** Service role only. Zero grants to `anon`, `authenticated`, or `PUBLIC`.

---

### `groups`
| Column | Type | Notes |
|---|---|---|
| `id` | `uuid PK DEFAULT gen_random_uuid()` | |
| `name` | `text NOT NULL` | CHECK: `length(trim(name)) BETWEEN 1 AND 100` |
| `created_by` | `uuid NOT NULL` | References `profiles.id` |
| `created_at` | `timestamptz NOT NULL DEFAULT now()` | |
| `archived_at` | `timestamptz` | NULL = active |

**Creation:** `create_group(name text)` SECURITY DEFINER — atomically INSERTs group and owner membership. Caller must have `is_active = true` and `onboarding_complete = true`.

**RLS:**
- SELECT: group members only
- INSERT: blocked (function only)
- UPDATE: owner only; cannot change `created_by`, `created_at`, `id`
- DELETE: never

---

### `group_members`
| Column | Type | Notes |
|---|---|---|
| `group_id` | `uuid NOT NULL` | References `groups.id` ON DELETE CASCADE |
| `player_id` | `uuid NOT NULL` | References `profiles.id` ON DELETE RESTRICT |
| `joined_at` | `timestamptz NOT NULL DEFAULT clock_timestamp()` | |
| `role` | `text NOT NULL DEFAULT 'member'` | CHECK: `IN ('owner','member')` |
| PRIMARY KEY | `(group_id, player_id)` | |

**Single-owner guarantee:**
```sql
CREATE UNIQUE INDEX one_owner_per_group ON group_members (group_id) WHERE role = 'owner';
```
Ownership transfer via `transfer_group_ownership(group_id, new_owner_id)` SECURITY DEFINER — locks group row, atomically demotes then promotes in one transaction.

**RLS:** All mutations via SECURITY DEFINER functions. Direct INSERT/UPDATE/DELETE blocked.

---

### `group_invites`
| Column | Type | Notes |
|---|---|---|
| `id` | `uuid PK DEFAULT gen_random_uuid()` | |
| `group_id` | `uuid NOT NULL` | References `groups.id` ON DELETE CASCADE |
| `created_by` | `uuid NOT NULL` | References `profiles.id` |
| `token_hash` | `text NOT NULL UNIQUE` | SHA-256 of raw token; raw token returned once and never stored |
| `created_at` | `timestamptz NOT NULL DEFAULT clock_timestamp()` | Server-assigned |
| `expires_at` | `timestamptz NOT NULL` | `created_at + INTERVAL '7 days'`; server-assigned |
| `accepted_by` | `uuid` | References `profiles.id`; NULL until redeemed |
| `accepted_at` | `timestamptz` | Server-assigned on redemption |
| `revoked_at` | `timestamptz` | Server-assigned on revocation |
| `revoked_by` | `uuid` | References `profiles.id` |

**Functions:**
- `create_group_invite(group_id)` → raw token (text): caller must be active group member; generates high-entropy token server-side; stores only hash; sets expiry server-side
- `redeem_group_invite(raw_token)` → group_id: hashes token; validates not expired/revoked/accepted; checks caller is active and `onboarding_complete = true`; locks invite row; atomically inserts group membership and marks accepted
- `revoke_group_invite(invite_id)`: group owner or invite creator only; locks row; sets revoked fields

**RLS:**
- SELECT: own invites only (`created_by = auth.uid()`)
- INSERT/UPDATE/DELETE: blocked (functions only)

---

### `rules_versions`
Immutable. Trigger prevents all UPDATE/DELETE.

| Column | Type | Notes |
|---|---|---|
| `id` | `uuid PK` | |
| `version_tag` | `text NOT NULL UNIQUE` | e.g. `'v1'` |
| `description` | `text NOT NULL` | |
| `config` | `jsonb NOT NULL` | Machine-readable; see seed below |
| `created_at` | `timestamptz NOT NULL DEFAULT now()` | |

**RLS:** SELECT: any authenticated user. INSERT/UPDATE/DELETE: never.

---

### `media_objects`
Client-facing opaque record. No storage paths.

| Column | Type | Notes |
|---|---|---|
| `id` | `uuid PK DEFAULT gen_random_uuid()` | |
| `uploader_id` | `uuid NOT NULL` | References `profiles.id` |
| `mime_type` | `text NOT NULL` | |
| `file_size_bytes` | `integer` | |
| `status` | `text NOT NULL DEFAULT 'processing'` | CHECK: `IN ('processing','ready','failed')` |
| `re_encoded_at` | `timestamptz` | |
| `created_at` | `timestamptz NOT NULL DEFAULT now()` | |

**Validation:** On `activate_challenge()`, verified that `media_object_id` references an object where `uploader_id = poster_id` and `status = 'ready'`.
Profile avatar: on profile update, verified that `avatar_media_object_id` references an object where `uploader_id = auth.uid()` and `status = 'ready'`.

**RLS:** SELECT: uploader only. INSERT/UPDATE/DELETE: service role only.

---

### `private.media_storage_keys`
Private schema. No client access of any kind.

| Column | Type | Notes |
|---|---|---|
| `media_object_id` | `uuid PK` | References `media_objects.id` ON DELETE CASCADE |
| `storage_key` | `text NOT NULL` | Original upload path |
| `re_encoded_storage_key` | `text` | Server-re-encoded copy; NULL until ready |

**Access:** Service role only. Zero grants to `anon`, `authenticated`, or `PUBLIC`.

---

### `challenges`

| Column | Type | Notes |
|---|---|---|
| `id` | `uuid PK DEFAULT gen_random_uuid()` | |
| `poster_id` | `uuid NOT NULL` | References `profiles.id`; set once at INSERT; immutable |
| `group_id` | `uuid NOT NULL` | References `groups.id` ON DELETE RESTRICT; immutable after creation |
| `state` | `text NOT NULL DEFAULT 'draft'` | CHECK: valid states; changed only by lifecycle functions |
| `media_object_id` | `uuid` | References `media_objects.id`; NULL in draft |
| `duration_seconds` | `integer NOT NULL DEFAULT 7200` | CHECK: BETWEEN 3600 AND 172800 AND % 3600 = 0 |
| `rules_version_id` | `uuid NOT NULL DEFAULT 'a0000000-0000-0000-0000-000000000001'` | Immutable after creation |
| `posted_at` | `timestamptz` | Server-assigned by `activate_challenge()` |
| `deadline_at` | `timestamptz` | Server-assigned by `activate_challenge()` |
| `locked_at` | `timestamptz` | Server-assigned by `lock_challenge()` |
| `revealed_at` | `timestamptz` | Server-assigned by `reveal_challenge()` |
| `cancelled_at` | `timestamptz` | Server-assigned by `cancel_challenge()` |
| `cancellation_reason` | `text` | CHECK: length <= 500 |
| `created_at` | `timestamptz NOT NULL DEFAULT clock_timestamp()` | |

**State constraint:** `CHECK (state IN ('draft','active','locked','revealed','cancelled'))`

**One-active-challenge-per-poster:**
```sql
CREATE UNIQUE INDEX one_active_challenge_per_poster
ON challenges (poster_id)
WHERE state IN ('draft','active','locked');
```

**Trigger `protect_challenge_authority_fields` (BEFORE INSERT/UPDATE):**
- INSERT: forces `state = 'draft'`; sets `poster_id = auth.uid()`; rejects client-supplied `posted_at`, `deadline_at`, `locked_at`, `revealed_at`, `cancelled_at`
- UPDATE: blocks direct changes to `poster_id`, `group_id`, `rules_version_id`, and all server timestamps; state changes only via lifecycle functions

**RLS:**
- SELECT: poster (all states) OR group members (non-draft only)
- INSERT: active, onboarded group member; `group_id` must be a group the caller belongs to
- UPDATE: poster only; limited to editable fields (media, duration, cancellation_reason in draft); state transitions via lifecycle functions only
- DELETE: never

---

### `challenge_secrets`
| Column | Type | Notes |
|---|---|---|
| `challenge_id` | `uuid PK` | References `challenges.id` ON DELETE CASCADE |
| `display_dish` | `text NOT NULL` | CHECK: `length(trim(display_dish)) BETWEEN 1 AND 200` |
| `canonical_dish` | `text NOT NULL` | CHECK: `length(canonical_dish) BETWEEN 1 AND 200` |
| `display_restaurant` | `text NOT NULL` | CHECK: `length(trim(display_restaurant)) BETWEEN 1 AND 200` |
| `canonical_restaurant` | `text NOT NULL` | CHECK: `length(canonical_restaurant) BETWEEN 1 AND 200` |
| `display_city` | `text NOT NULL` | CHECK: `length(trim(display_city)) BETWEEN 1 AND 100` |
| `canonical_city` | `text NOT NULL` | CHECK: `length(canonical_city) BETWEEN 1 AND 100` |
| `story` | `text` | Shown after reveal only |
| `has_first_guess` | `boolean NOT NULL DEFAULT false` | Convenience flag; also enforced structurally by trigger |
| `created_at` | `timestamptz NOT NULL DEFAULT now()` | |
| `updated_at` | `timestamptz NOT NULL DEFAULT now()` | |

**Answer-lock trigger (BEFORE UPDATE):** Raises exception if any row exists in `guess_attempts` for this `challenge_id` and the caller is not the trusted `apply_correction()` function. Covers all display and canonical fields.

**RLS:**
- SELECT: poster OR (state = 'revealed' AND group member)
- INSERT: poster; `challenge_id` verified via challenges join
- UPDATE: poster only, while `has_first_guess = false`; post-reveal changes via `apply_correction()` only
- DELETE: never

---

### `challenge_answer_aliases`
| Column | Type | Notes |
|---|---|---|
| `id` | `uuid PK DEFAULT gen_random_uuid()` | |
| `challenge_id` | `uuid NOT NULL` | References `challenges.id` ON DELETE CASCADE |
| `field` | `text NOT NULL` | CHECK: `IN ('dish','restaurant','city')` |
| `display_value` | `text NOT NULL` | CHECK: `length(trim(display_value)) BETWEEN 1 AND 200` |
| `normalized_value` | `text NOT NULL` | CHECK: `length(normalized_value) BETWEEN 1 AND 200` |
| `created_by` | `uuid NOT NULL` | References `profiles.id` |
| `created_at` | `timestamptz NOT NULL DEFAULT now()` | |
| `is_active` | `boolean NOT NULL DEFAULT true` | |

**Alias-lock trigger:** After first guess, rejects INSERT and UPDATE unless called by trusted `apply_correction()` transaction.

**RLS:** Same as `challenge_secrets`.

---

### `eligible_participants`
Poster excluded from snapshot. `snapshot_display_name` removed — names looked up via `profiles` at query time.

| Column | Type | Notes |
|---|---|---|
| `id` | `uuid PK DEFAULT gen_random_uuid()` | |
| `challenge_id` | `uuid NOT NULL` | References `challenges.id` ON DELETE RESTRICT |
| `player_id` | `uuid NOT NULL` | References `profiles.id` ON DELETE RESTRICT |
| `snapshot_avatar_color` | `text NOT NULL` | Non-PII; color at time of posting |
| `added_at` | `timestamptz NOT NULL DEFAULT clock_timestamp()` | |
| UNIQUE | `(challenge_id, player_id)` | |

**Populated by `activate_challenge()`:** Snapshots all active, onboarded, non-poster group members at the moment of activation.

**`effective_eligible_count`** in `score_runs` = COUNT of `eligible_participants` for the challenge MINUS COUNT of non-overlapping `exclusion_events`. The poster is never in this table and never subtracted separately.

**RLS:**
- SELECT: group members
- INSERT/UPDATE/DELETE: service role only

---

### `exclusion_events`
| Column | Type | Notes |
|---|---|---|
| `id` | `uuid PK DEFAULT gen_random_uuid()` | |
| `challenge_id` | `uuid NOT NULL` | References `challenges.id` ON DELETE RESTRICT |
| `player_id` | `uuid NOT NULL` | References `profiles.id` |
| `reason` | `text NOT NULL` | CHECK: `IN ('withdrew','removed')` |
| `excluded_by` | `uuid NOT NULL` | References `profiles.id` |
| `excluded_at` | `timestamptz NOT NULL DEFAULT clock_timestamp()` | Server-assigned |
| UNIQUE | `(challenge_id, player_id)` | One exclusion per player per challenge |

**Rules (enforced by trigger):**
- Player must be in `eligible_participants` for the challenge
- Player must not already be excluded
- Challenge must be `active` (not locked, revealed, or cancelled)
- `withdrew`: caller must be the excluded player themselves
- `removed`: caller must be poster or group owner
- `excluded_by` must equal `auth.uid()`

**RLS:**
- SELECT: group members
- INSERT: self (withdrew) or poster/group-owner (removed); trigger enforces all rules
- UPDATE/DELETE: never

---

### `hints`
| Column | Type | Notes |
|---|---|---|
| `id` | `uuid PK DEFAULT gen_random_uuid()` | |
| `challenge_id` | `uuid NOT NULL` | References `challenges.id` ON DELETE RESTRICT |
| `poster_id` | `uuid NOT NULL` | References `profiles.id` |
| `text` | `text NOT NULL` | CHECK: `length(trim(text)) BETWEEN 1 AND 500` |
| `posted_at` | `timestamptz NOT NULL DEFAULT clock_timestamp()` | Server-assigned; client value overwritten |

**RLS:**
- SELECT: group members; challenge must be `active` or later
- INSERT: poster only; `poster_id = auth.uid()`; challenge must be `active`
- UPDATE/DELETE: never

---

### `guess_attempts`
Immutable. Split by race. No correctness fields.

| Column | Type | Notes |
|---|---|---|
| `id` | `uuid PK DEFAULT gen_random_uuid()` | |
| `challenge_id` | `uuid NOT NULL` | References `challenges.id` ON DELETE RESTRICT |
| `player_id` | `uuid NOT NULL` | References `profiles.id` |
| `race` | `text NOT NULL` | CHECK: `IN ('what','where')` |
| `dish_guess` | `text` | Required when `race='what'`; CHECK: `length(trim(dish_guess)) BETWEEN 1 AND 200` when not null |
| `restaurant_guess` | `text` | Required when `race='where'`; CHECK: `length(trim(restaurant_guess)) BETWEEN 1 AND 200` when not null |
| `city_guess` | `text` | Required when `race='where'`; CHECK: `length(trim(city_guess)) BETWEEN 1 AND 100` when not null |
| `received_at` | `timestamptz NOT NULL` | Set to `clock_timestamp()` by BEFORE INSERT trigger; overwrites client value |
| `receipt_sequence` | `bigint NOT NULL` | Set to `nextval('guess_receipt_seq')` by trigger; overwrites client value |
| `client_submitted_at` | `timestamptz` | Display only; never used for ranking |
| UNIQUE | `(challenge_id, receipt_sequence)` | |

**Race constraint:**
```sql
CHECK (
  (race = 'what'  AND dish_guess IS NOT NULL
                  AND restaurant_guess IS NULL AND city_guess IS NULL)
  OR
  (race = 'where' AND dish_guess IS NULL
                  AND restaurant_guess IS NOT NULL AND city_guess IS NOT NULL)
)
```

**BEFORE INSERT trigger `set_guess_receipt_fields`:**
1. Overwrites `received_at = clock_timestamp()`
2. Overwrites `receipt_sequence = nextval('guess_receipt_seq')`
3. Verifies `clock_timestamp() < challenges.deadline_at`; raises exception if at or past deadline
4. Verifies `player_id = auth.uid()`
5. Sets `challenge_secrets.has_first_guess = true` for this challenge

**RLS INSERT:** player is `is_active = true` AND `onboarding_complete = true` AND in `eligible_participants` AND not in `exclusion_events` AND not the poster AND challenge is `active` AND `player_id = auth.uid()`

**RLS SELECT:**
```
player_id = auth.uid()                                          -- own guesses always
OR (poster is auth.uid() AND state IN ('active','locked'))      -- poster sees all during game
OR (state = 'revealed' AND is_challenge_group_member)           -- all see all after reveal
```

**UPDATE/DELETE: never**

---

### `guess_judgments`
Immutable. Written by `reveal_challenge()` and `apply_correction()`.

| Column | Type | Notes |
|---|---|---|
| `id` | `uuid PK DEFAULT gen_random_uuid()` | |
| `score_run_id` | `uuid NOT NULL` | References `score_runs.id` |
| `guess_attempt_id` | `uuid NOT NULL` | References `guess_attempts.id` |
| `player_id` | `uuid NOT NULL` | References `profiles.id`; trigger verifies matches guess_attempt |
| `challenge_id` | `uuid NOT NULL` | References `challenges.id`; trigger verifies matches guess_attempt |
| `race` | `text NOT NULL` | CHECK: `IN ('what','where')`; trigger verifies matches guess_attempt |
| `rules_version_id` | `uuid NOT NULL` | References `rules_versions.id`; trigger verifies matches score_run |
| `is_correct` | `boolean NOT NULL` | |
| `is_first_correct_for_player` | `boolean NOT NULL DEFAULT false` | True = this player's earliest correct attempt for this race in this score run |
| `created_at` | `timestamptz NOT NULL DEFAULT now()` | |
| UNIQUE | `(score_run_id, guess_attempt_id)` | |

**Partial unique index:**
```sql
CREATE UNIQUE INDEX one_qualifying_attempt_per_player_race
ON guess_judgments (score_run_id, player_id, race)
WHERE is_first_correct_for_player = true;
```

**RLS:** SELECT: group members after reveal. INSERT/UPDATE/DELETE: service role only.

---

### `score_runs`
Current run = MAX(`revision_number`) per challenge.

| Column | Type | Notes |
|---|---|---|
| `id` | `uuid PK DEFAULT gen_random_uuid()` | |
| `challenge_id` | `uuid NOT NULL` | References `challenges.id` ON DELETE RESTRICT |
| `revision_number` | `integer NOT NULL` | 1 for initial reveal |
| `rules_version_id` | `uuid NOT NULL` | References `rules_versions.id` |
| `effective_eligible_count` | `integer NOT NULL` | CHECK: `>= 0` |
| `triggering_correction_id` | `uuid` | References `correction_events.id`; NULL for initial |
| `created_at` | `timestamptz NOT NULL DEFAULT now()` | |
| UNIQUE | `(challenge_id, revision_number)` | Also prevents concurrent-correction collision |

**Concurrency:** `reveal_challenge()` and `apply_correction()` both lock the challenge row with `SELECT ... FOR UPDATE` before calculating next revision. Concurrent calls block until the lock is released; one succeeds, the next sees the updated MAX and increments correctly. Simultaneous corrections are serialized, not rejected.

**`current_score_events` view:**
```sql
CREATE VIEW current_score_events
WITH (security_invoker = true) AS
SELECT se.*
FROM score_events se
JOIN score_runs sr ON sr.id = se.score_run_id
WHERE sr.revision_number = (
  SELECT MAX(revision_number)
  FROM score_runs
  WHERE challenge_id = sr.challenge_id
);

GRANT SELECT ON current_score_events TO authenticated;
REVOKE INSERT, UPDATE, DELETE ON current_score_events FROM PUBLIC;
```

**RLS:** SELECT: group members after reveal. INSERT/UPDATE/DELETE: service role only.

---

### `score_events`
| Column | Type | Notes |
|---|---|---|
| `id` | `uuid PK DEFAULT gen_random_uuid()` | |
| `score_run_id` | `uuid NOT NULL` | References `score_runs.id` |
| `challenge_id` | `uuid NOT NULL` | Denormalized; trigger verifies matches score_run |
| `player_id` | `uuid NOT NULL` | References `profiles.id` |
| `rules_version_id` | `uuid NOT NULL` | Denormalized; trigger verifies matches score_run |
| `what_points` | `integer NOT NULL DEFAULT 0` | CHECK: `>= 0` |
| `where_points` | `integer NOT NULL DEFAULT 0` | CHECK: `>= 0` |
| `total_points` | `integer NOT NULL GENERATED ALWAYS AS (what_points + where_points) STORED` | |
| `what_rank` | `integer` | NULL = no correct answer; CHECK: `> 0` when not null |
| `where_rank` | `integer` | NULL = no correct answer; CHECK: `> 0` when not null |
| `scored_at` | `timestamptz NOT NULL DEFAULT now()` | |
| UNIQUE | `(score_run_id, player_id)` | |

**RLS:** SELECT: group members after reveal (via `current_score_events` view for app queries). INSERT: service role only. UPDATE/DELETE: never.

---

### `correction_events`
Redesigned with structured `action`/`target_field` instead of free-form `field`/`old_value`/`new_value`.

| Column | Type | Notes |
|---|---|---|
| `id` | `uuid PK DEFAULT gen_random_uuid()` | |
| `challenge_id` | `uuid NOT NULL` | References `challenges.id` ON DELETE RESTRICT |
| `corrected_by` | `uuid NOT NULL` | References `profiles.id`; must be poster or group owner |
| `action` | `text NOT NULL` | CHECK: `IN ('answer_changed','alias_added','alias_removed')` |
| `target_field` | `text NOT NULL` | CHECK: `IN ('dish','restaurant','city')` |
| `alias_id` | `uuid` | References `challenge_answer_aliases.id`; required when `action='alias_removed'` |
| `old_display_value` | `text` | Previous value for `answer_changed` or removed alias |
| `new_display_value` | `text` | CHECK: `length(trim(new_display_value)) BETWEEN 1 AND 200`; required for `answer_changed` and `alias_added` |
| `old_normalized_value` | `text` | |
| `new_normalized_value` | `text` | Server-computed normalization of `new_display_value` |
| `reason` | `text NOT NULL` | CHECK: `length(trim(reason)) BETWEEN 1 AND 500` |
| `resulting_score_run_id` | `uuid` | References `score_runs.id`; set by `apply_correction()` after score run created |
| `corrected_at` | `timestamptz NOT NULL DEFAULT clock_timestamp()` | Server-assigned |

**`apply_correction(p_challenge_id, p_action, p_target_field, p_new_display_value, p_alias_id, p_reason)` atomic transaction:**
1. `SELECT ... FOR UPDATE` on challenges row (serializes concurrent corrections)
2. Validates caller is poster or group owner; challenge is `revealed`
3. Validates parameters match action type
4. Server-normalizes `p_new_display_value`
5. INSERTs `correction_events` row (without `resulting_score_run_id`)
6. Applies change: updates `challenge_secrets` canonical/display field OR inserts/deactivates `challenge_answer_aliases`
7. Calculates `next_revision = MAX(revision_number) + 1` for challenge
8. INSERTs `score_runs` (revision = next_revision, triggering_correction_id = new correction id)
9. Re-judges all non-excluded guess attempts against updated answers
10. INSERTs `guess_judgments`
11. INSERTs `score_events`
12. UPDATEs `correction_events.resulting_score_run_id`
13. Full rollback on any failure

**RLS:**
- SELECT: group members after reveal
- All mutations: via `apply_correction()` function only; direct access blocked
- DELETE: never

---

### `comments`
| Column | Type | Notes |
|---|---|---|
| `id` | `uuid PK DEFAULT gen_random_uuid()` | |
| `challenge_id` | `uuid NOT NULL` | References `challenges.id` ON DELETE RESTRICT |
| `author_id` | `uuid NOT NULL` | References `profiles.id` |
| `text` | `text NOT NULL` | CHECK: `length(trim(text)) BETWEEN 1 AND 1000` |
| `posted_at` | `timestamptz NOT NULL DEFAULT clock_timestamp()` | Server-assigned |
| `deleted_at` | `timestamptz` | Soft delete |

**Allowed states:** `revealed` only.

**Update trigger:** Permits only setting `deleted_at`; all other column changes raise exception.

**RLS:**
- SELECT: group members; challenge must be `revealed`
- INSERT: active, onboarded group member; `author_id = auth.uid()`; challenge must be `revealed`; `posted_at` overwritten
- UPDATE: own rows only; restricted to `deleted_at` by trigger
- DELETE: never

---

### `reactions`
| Column | Type | Notes |
|---|---|---|
| `id` | `uuid PK DEFAULT gen_random_uuid()` | |
| `challenge_id` | `uuid NOT NULL` | References `challenges.id` ON DELETE RESTRICT |
| `player_id` | `uuid NOT NULL` | References `profiles.id` |
| `emoji` | `text NOT NULL` | CHECK: `length(emoji) BETWEEN 1 AND 8` |
| `reacted_at` | `timestamptz NOT NULL DEFAULT clock_timestamp()` | Server-assigned |
| UNIQUE | `(challenge_id, player_id, emoji)` | |

**Allowed states:** `revealed` only.

**RLS:**
- SELECT: group members; challenge must be `revealed`
- INSERT: active, onboarded group member; `player_id = auth.uid()`; challenge must be `revealed`
- DELETE: own rows only (`player_id = auth.uid()`)
- UPDATE: never

---

## Lifecycle Functions

All SECURITY DEFINER, `SET search_path = ''`, `EXECUTE` revoked from `PUBLIC`.

### `activate_challenge(p_challenge_id uuid)`
Callable by: poster (authenticated)
1. `SELECT ... FOR UPDATE` on challenge row
2. Verify `auth.uid() = poster_id` AND `is_active = true`
3. Verify `state = 'draft'`
4. Verify group is not archived
5. Verify `challenge_secrets` exists with non-empty canonical fields
6. Verify `media_object_id` is not null; media belongs to poster; `status = 'ready'`
7. Snapshot non-poster, active, onboarded group members into `eligible_participants`
8. Verify at least 1 eligible participant exists; raise exception otherwise
9. Set `posted_at = clock_timestamp()`, `deadline_at = clock_timestamp() + (duration_seconds || ' seconds')::interval`
10. Set `state = 'active'`

### `lock_challenge(p_challenge_id uuid)`
Callable by: service role only (scheduled job at deadline)
1. Verify `state = 'active'`
2. Set `locked_at = clock_timestamp()`, `state = 'locked'`

### `reveal_challenge(p_challenge_id uuid)`
Callable by: poster (early reveal) or service role (auto after locking)
1. `SELECT ... FOR UPDATE` on challenge row
2. Verify state = `'locked'` OR (poster is caller AND state = `'active'` AND `clock_timestamp() >= deadline_at`)
3. Verify no `score_runs` with `revision_number = 1` already exists for this challenge
4. Calculate `effective_eligible_count` = eligible_participants count minus exclusion_events count
5. Judge all non-excluded guess attempts: normalize and match against canonical answers and active aliases
6. Identify each player's `is_first_correct_for_player` attempt per race (earliest by `receipt_sequence`)
7. Rank qualifying attempts by `receipt_sequence` ascending; assign ordinal ranks
8. Calculate points: `effective_eligible_count - rank + 1`, minimum 1
9. INSERT `score_runs` (revision_number = 1)
10. INSERT `guess_judgments`
11. INSERT `score_events`
12. Set `revealed_at = clock_timestamp()`, `state = 'revealed'`

### `cancel_challenge(p_challenge_id uuid, p_reason text)`
Callable by: poster (authenticated)
1. Verify `auth.uid() = poster_id`
2. Verify `state IN ('draft','active')`
3. Set `cancelled_at = clock_timestamp()`, `cancellation_reason = p_reason`, `state = 'cancelled'`

---

## SECURITY DEFINER Functions — Complete List (15)

**Private membership helpers (not directly callable by clients):**
1. `private.is_group_member(p_group_id uuid) → boolean`
2. `private.is_challenge_group_member(p_challenge_id uuid) → boolean`
3. `private.is_challenge_poster(p_challenge_id uuid) → boolean`
4. `private.is_challenge_revealed(p_challenge_id uuid) → boolean`
5. `private.is_eligible_non_excluded(p_challenge_id uuid) → boolean`

**Public operational (callable by authenticated):**
6. `public.create_group(p_name text) → uuid`
7. `public.transfer_group_ownership(p_group_id uuid, p_new_owner_id uuid) → void`
8. `public.create_group_invite(p_group_id uuid) → text`
9. `public.redeem_group_invite(p_raw_token text) → uuid`
10. `public.revoke_group_invite(p_invite_id uuid) → void`
11. `public.activate_challenge(p_challenge_id uuid) → void`
12. `public.reveal_challenge(p_challenge_id uuid) → void`
13. `public.cancel_challenge(p_challenge_id uuid, p_reason text) → void`
14. `public.apply_correction(p_challenge_id uuid, p_action text, p_target_field text, p_new_display_value text, p_alias_id uuid, p_reason text) → uuid`
15. `public.delete_account() → void`

**Service role only (not callable by authenticated):**
- `public.lock_challenge(p_challenge_id uuid) → void`

---

## Triggers — Complete List (12)

| Trigger | Table | Event | Purpose |
|---|---|---|---|
| `handle_new_user` | `auth.users` | AFTER INSERT | Creates profile (nullable display_name, is_active=true) |
| `protect_challenge_authority_fields` | `challenges` | BEFORE INSERT/UPDATE | Forces draft state on insert; blocks authority field changes |
| `set_guess_receipt_fields` | `guess_attempts` | BEFORE INSERT | Sets received_at, receipt_sequence, has_first_guess; enforces deadline |
| `guard_answer_edits` | `challenge_secrets` | BEFORE UPDATE | Blocks field changes after first guess (outside trusted context) |
| `guard_alias_edits` | `challenge_answer_aliases` | BEFORE INSERT/UPDATE | Blocks changes when has_first_guess=true outside trusted context |
| `protect_rules_versions` | `rules_versions` | BEFORE UPDATE/DELETE | Always raises exception |
| `restrict_comment_updates` | `comments` | BEFORE UPDATE | Permits only deleted_at; blocks text changes |
| `enforce_exclusion_rules` | `exclusion_events` | BEFORE INSERT | Validates eligibility, no duplicate, active challenge |
| `lock_onboarding_complete` | `profiles` | BEFORE UPDATE | Prevents onboarding_complete reverting to false |
| `verify_judgment_references` | `guess_judgments` | BEFORE INSERT | Validates denormalized fields match referenced records |
| `verify_score_event_references` | `score_events` | BEFORE INSERT | Validates denormalized fields match referenced records |
| `validate_avatar_media_ownership` | `profiles` | BEFORE UPDATE | Verifies avatar_media_object_id belongs to profile owner and is ready |

---

## Indexes — Complete List

| Table | Columns | Reason |
|---|---|---|
| `challenges` | `(poster_id) WHERE state IN ('draft','active','locked')` | One-active-challenge-per-poster (unique) |
| `group_members` | `(group_id) WHERE role = 'owner'` | One-owner-per-group (unique) |
| `group_members` | `player_id` | Membership checks |
| `group_members` | `group_id` | Group lookups |
| `challenges` | `(group_id, state)` | Feed queries |
| `challenges` | `poster_id` | Poster views |
| `challenges` | `deadline_at` | Scheduler |
| `challenge_answer_aliases` | `(challenge_id, field, is_active)` | Matching |
| `guess_attempts` | `(challenge_id, race, player_id)` | Per-player per-race |
| `guess_attempts` | `(challenge_id, receipt_sequence)` | Rank ordering |
| `guess_judgments` | `score_run_id` | Scoring joins |
| `guess_judgments` | `(score_run_id, player_id, race) WHERE is_first_correct_for_player = true` | Qualifying attempt (unique) |
| `score_events` | `(challenge_id, player_id)` | Leaderboard |
| `score_runs` | `(challenge_id, revision_number DESC)` | Current run |
| `exclusion_events` | `(challenge_id, player_id)` | Eligibility |
| `eligible_participants` | `(challenge_id, player_id)` | Eligibility |
| `group_invites` | `token_hash` | Redemption |
| `group_invites` | `group_id` | Management |

All foreign key columns indexed.

---

## Privilege Model

```
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM PUBLIC, anon;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM PUBLIC, anon;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC;

-- Grant minimums to authenticated role (RLS then further restricts)
GRANT SELECT, INSERT, UPDATE, DELETE ON [client tables] TO authenticated;
GRANT SELECT ON current_score_events TO authenticated;
GRANT EXECUTE ON [public operational functions 6–15] TO authenticated;

-- Private schema: no grants outside service role
REVOKE ALL ON SCHEMA private FROM PUBLIC, anon, authenticated;
```

---

## Seed Data

```sql
INSERT INTO rules_versions (id, version_tag, description, config) VALUES (
  'a0000000-0000-0000-0000-000000000001',
  'v1',
  'Ordinal ranking. receipt_sequence deterministically resolves all ties; all ranks unique.',
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

## Nonblocking Roadmap (deferred)

- Push-notification device token registration
- Universal invite links
- Rate limiting
- Reporting/blocking/moderation
- Archived group rules

---

## Deployment Gate

Before applying migration to live Supabase project:
1. Claude presents complete migration SQL and automated test results
2. Codex/GPT reviews security-sensitive SQL
3. Bill explicitly approves remote deployment

---

## Acceptance Criteria

**Schema:**
- [ ] 19 client-accessible tables + 2 private-schema tables created
- [ ] 15 SECURITY DEFINER functions deployed; EXECUTE revoked from PUBLIC; correct grants
- [ ] 12 triggers in place
- [ ] `guess_receipt_seq` global sequence created
- [ ] All indexes created (including 3 partial unique indexes)
- [ ] `rules_versions` seeded with v1
- [ ] `current_score_events` view created with `security_invoker = true`
- [ ] RLS explicitly enabled on all client-accessible tables
- [ ] Privilege model applied

**Duration:**
- [ ] Every whole-hour value 1–48 hours accepted
- [ ] Values below 1h, above 48h, non-whole-hour rejected

**Authentication and visibility:**
- [ ] Anonymous denied on all tables
- [ ] Non-member authenticated user denied on group-scoped tables
- [ ] Different-group member denied
- [ ] Draft visible to poster only
- [ ] `current_score_events` view does not bypass underlying RLS
- [ ] Direct `SELECT *` on `media_objects` returns no storage path column
- [ ] Direct `SELECT *` on `private.media_storage_keys` returns no rows to any client
- [ ] Direct `SELECT *` on `private.profile_archive` returns no rows to any client
- [ ] Direct `SELECT display_name` on `profiles` for deleted player shows 'Former Player'
- [ ] `eligible_participants` query returns no deleted player names
- [ ] Deleted profile with unexpired JWT cannot INSERT, UPDATE, or DELETE any application data

**Challenge lifecycle:**
- [ ] Client cannot create non-draft challenge
- [ ] Client cannot directly set state or server timestamps
- [ ] `activate_challenge()` fails without ready poster-owned media
- [ ] `activate_challenge()` fails without complete canonical answers
- [ ] `activate_challenge()` fails with zero eligible participants
- [ ] Activation atomically creates eligibility snapshot excluding poster
- [ ] Poster does not appear in `eligible_participants`
- [ ] `reveal_challenge()` cannot run twice (revision 1 already exists check)
- [ ] Invalid state transitions rejected
- [ ] Poster cannot have two draft/active/locked challenges simultaneously

**Guessing:**
- [ ] Client-supplied `received_at` and `receipt_sequence` are overwritten
- [ ] Guess at or after `deadline_at` rejected even if state is `active`
- [ ] Whitespace-only guess fields rejected
- [ ] Poster cannot insert guess on own challenge
- [ ] Excluded participant cannot insert guess
- [ ] Concurrent guesses receive distinct `receipt_sequence` values
- [ ] What? and Where? submit independently with independent timestamps
- [ ] Poster sees all guesses during active/locked; own player sees own only; all see all after reveal

**Answers:**
- [ ] Canonical and display fields locked after first guess
- [ ] Aliases locked after first guess
- [ ] Post-reveal correction via `apply_correction()` succeeds
- [ ] `alias_removed` correction requires `alias_id`; `target_field` correctly recorded
- [ ] Concurrent corrections receive serialized revision numbers (not duplicates)

**Scoring:**
- [ ] `total_points = what_points + where_points`
- [ ] At most one `is_first_correct_for_player = true` per (score_run, player, race)
- [ ] Leaderboard via `current_score_events` reflects MAX revision only
- [ ] Withdrawn and removed players both excluded from scoring
- [ ] `effective_eligible_count` excludes poster

**Other:**
- [ ] Duplicate exclusion for same player/challenge fails
- [ ] Withdrawal/removal blocked after locking
- [ ] Comment text cannot be changed; only `deleted_at` settable
- [ ] Reactions limited to revealed challenges
- [ ] Invite expiry, token value, and created_at cannot be set by client
- [ ] Expired/revoked/accepted invite rejected at redemption
- [ ] Unauthorized users cannot invoke lifecycle or correction functions
- [ ] `apply_correction()` rolls back entirely on any step failure

---

## Review Checklist (for Codex/GPT)

1. Is `security_invoker = true` on `current_score_events` correctly configured and tested?
2. Is the `profiles` mutation-on-deletion approach (no `deleted_at` column; identity overwritten; archive in private schema) sufficient to prevent identity leakage?
3. Is the `eligible_participants` change (poster excluded; `snapshot_display_name` removed) correct and complete?
4. Are the four lifecycle functions complete and atomically safe?
5. Is challenge-row locking in `reveal_challenge()` and `apply_correction()` sufficient to serialize revision numbers?
6. Is the `correction_events` redesign (`action`/`target_field`/`alias_id`) complete for all correction scenarios?
7. Is the partial unique index for one-active-challenge-per-poster correct?
8. Is the guess visibility RLS (poster sees all during active/locked; player sees own; all see all after reveal) correctly specified?
9. Is the privilege model (`REVOKE ALL` then minimal grants) complete?
10. Is anything missing given the full game mechanics?
11. Duration (1–48 hours, whole-hour steps, default 2 hours) is a confirmed Bill decision — confirm schema implements it correctly.
