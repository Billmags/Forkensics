# Step 2 Proposal — Supabase Project & Database Schema

**Status:** Pending review (Claude → Codex/GPT → Bill approval)
**Prerequisite:** Step 1 approved ✅
**Governance gate:** Bill must type `APPROVED: Step 2 — Supabase Project & Database Schema` before any code is written.

---

## Objective

Stand up the Supabase project and deploy the full production database schema with Row-Level Security (RLS) policies. No Swift code changes in this step. The output is a live Supabase project with correct tables, constraints, RLS, and seed data — ready for Step 3 (Authentication) to connect to.

---

## Scope

### 1. Supabase Project Creation
- Create a new Supabase project (Bill does this in the Supabase dashboard; Claude provides the exact settings)
- Note the project URL and anon key for Step 3

### 2. Database Schema — Tables

All tables use `uuid` primary keys. `auth.users.id` is the application primary key for players; Apple `sub` is stored only in the Supabase identity record.

#### `profiles`
Extends `auth.users`. Created automatically on first sign-in via trigger.

| Column | Type | Notes |
|---|---|---|
| `id` | `uuid` PK | References `auth.users.id` |
| `display_name` | `text NOT NULL` | Captured from `credential.fullName` at first Apple sign-in |
| `avatar_color` | `text NOT NULL DEFAULT 'orange'` | One of 8 color values; fallback when no photo set |
| `avatar_image_path` | `text` | ⚠️ ADDED — Storage path for profile photo; NULL = use avatar color + initials |
| `created_at` | `timestamptz NOT NULL DEFAULT now()` | |
| `deleted_at` | `timestamptz` | Soft delete; NULL = active |

#### `groups`
| Column | Type | Notes |
|---|---|---|
| `id` | `uuid` PK DEFAULT `gen_random_uuid()` | |
| `name` | `text NOT NULL` | |
| `created_by` | `uuid NOT NULL` | References `profiles.id` |
| `created_at` | `timestamptz NOT NULL DEFAULT now()` | |

#### `group_members`
| Column | Type | Notes |
|---|---|---|
| `group_id` | `uuid NOT NULL` | References `groups.id` |
| `player_id` | `uuid NOT NULL` | References `profiles.id` |
| `joined_at` | `timestamptz NOT NULL DEFAULT now()` | |
| `role` | `text NOT NULL DEFAULT 'member'` | `'owner'` or `'member'` |
| PRIMARY KEY | `(group_id, player_id)` | |

#### `rules_versions`
Immutable. Seeded once at migration time.

| Column | Type | Notes |
|---|---|---|
| `id` | `uuid` PK | |
| `version_tag` | `text NOT NULL UNIQUE` | e.g. `'v1'` |
| `scoring_formula` | `text NOT NULL` | Human-readable description |
| `normalization_rules` | `text NOT NULL` | Description of text normalization |
| `created_at` | `timestamptz NOT NULL DEFAULT now()` | |

#### `challenges`
| Column | Type | Notes |
|---|---|---|
| `id` | `uuid` PK DEFAULT `gen_random_uuid()` | |
| `poster_id` | `uuid NOT NULL` | References `profiles.id` |
| `group_id` | `uuid NOT NULL` | References `groups.id` |
| `state` | `text NOT NULL DEFAULT 'draft'` | `draft`, `active`, `locked`, `revealed`, `cancelled` |
| `image_path` | `text` | Storage path; NULL in draft; never served directly |
| `story` | `text` | Shown after reveal only |
| `deadline_at` | `timestamptz` | Set at post time; NULL in draft |
| `duration_seconds` | `integer NOT NULL` | 3600–172800 (1–48 hours) |
| `rules_version_id` | `uuid NOT NULL` | References `rules_versions.id` |
| `posted_at` | `timestamptz` | Set when state→active |
| `locked_at` | `timestamptz` | Set when state→locked |
| `revealed_at` | `timestamptz` | Set when state→revealed |
| `cancelled_at` | `timestamptz` | Set when state→cancelled |
| `cancellation_reason` | `text` | |
| `created_at` | `timestamptz NOT NULL DEFAULT now()` | |

**State constraint:** `CHECK (state IN ('draft','active','locked','revealed','cancelled'))`

#### `challenge_secrets`
RLS: readable only by poster and service role; never by other authenticated users before reveal.

| Column | Type | Notes |
|---|---|---|
| `challenge_id` | `uuid` PK | References `challenges.id` |
| `canonical_dish` | `text NOT NULL` | Normalized form |
| `dish_aliases` | `text[] NOT NULL DEFAULT '{}'` | Additional accepted forms |
| `canonical_restaurant` | `text NOT NULL` | Normalized form |
| `canonical_city` | `text NOT NULL` | Normalized form |
| `has_first_guess` | `boolean NOT NULL DEFAULT false` | Locks poster editing once true |
| `created_at` | `timestamptz NOT NULL DEFAULT now()` | |
| `updated_at` | `timestamptz NOT NULL DEFAULT now()` | |

#### `eligible_participants`
Immutable snapshot taken at post time (state→active). One row per player per challenge.

| Column | Type | Notes |
|---|---|---|
| `id` | `uuid` PK DEFAULT `gen_random_uuid()` | |
| `challenge_id` | `uuid NOT NULL` | References `challenges.id` |
| `player_id` | `uuid NOT NULL` | References `profiles.id` |
| `snapshot_display_name` | `text NOT NULL` | Locked at post time |
| `snapshot_avatar_color` | `text NOT NULL` | Locked at post time |
| `added_at` | `timestamptz NOT NULL DEFAULT now()` | |
| UNIQUE | `(challenge_id, player_id)` | |

#### `exclusion_events`
Append-only. Records withdrawals and removals.

| Column | Type | Notes |
|---|---|---|
| `id` | `uuid` PK DEFAULT `gen_random_uuid()` | |
| `challenge_id` | `uuid NOT NULL` | References `challenges.id` |
| `player_id` | `uuid NOT NULL` | References `profiles.id` |
| `reason` | `text NOT NULL` | `'withdrew'` or `'removed'` |
| `excluded_by` | `uuid NOT NULL` | References `profiles.id` |
| `excluded_at` | `timestamptz NOT NULL DEFAULT now()` | |

#### `hints`
| Column | Type | Notes |
|---|---|---|
| `id` | `uuid` PK DEFAULT `gen_random_uuid()` | |
| `challenge_id` | `uuid NOT NULL` | References `challenges.id` |
| `poster_id` | `uuid NOT NULL` | References `profiles.id` |
| `text` | `text NOT NULL` | |
| `posted_at` | `timestamptz NOT NULL DEFAULT now()` | |

#### `guess_attempts`
Immutable append-only. Every submission or edit creates a new row. Server receipt timestamp + monotonic sequence determine rank.

| Column | Type | Notes |
|---|---|---|
| `id` | `uuid` PK DEFAULT `gen_random_uuid()` | |
| `challenge_id` | `uuid NOT NULL` | References `challenges.id` |
| `player_id` | `uuid NOT NULL` | References `profiles.id` |
| `dish_guess` | `text NOT NULL` | Raw text from player |
| `restaurant_guess` | `text NOT NULL` | Raw text from player |
| `city_guess` | `text NOT NULL` | Raw text from player |
| `received_at` | `timestamptz NOT NULL DEFAULT now()` | Server-generated; never trust client |
| `receipt_sequence` | `bigint NOT NULL` | Monotonic per-challenge; set by trigger |
| `what_correct` | `boolean` | NULL until revealed |
| `where_correct` | `boolean` | NULL until revealed |
| `is_withdrawn` | `boolean NOT NULL DEFAULT false` | Soft-withdraw |
| `client_submitted_at` | `timestamptz` | For display only; never used for ranking |

**Constraint:** `CHECK (receipt_sequence > 0)`

#### `score_events`
Immutable. Written by server (Edge Function) during reveal.

| Column | Type | Notes |
|---|---|---|
| `id` | `uuid` PK DEFAULT `gen_random_uuid()` | |
| `challenge_id` | `uuid NOT NULL` | References `challenges.id` |
| `player_id` | `uuid NOT NULL` | References `profiles.id` |
| `rules_version_id` | `uuid NOT NULL` | References `rules_versions.id` |
| `what_points` | `integer NOT NULL DEFAULT 0` | |
| `where_points` | `integer NOT NULL DEFAULT 0` | |
| `total_points` | `integer NOT NULL DEFAULT 0` | |
| `what_rank` | `integer` | NULL = did not answer correctly |
| `where_rank` | `integer` | NULL = did not answer correctly |
| `scored_at` | `timestamptz NOT NULL DEFAULT now()` | |

#### `correction_events`
Append-only. Poster corrections after reveal.

| Column | Type | Notes |
|---|---|---|
| `id` | `uuid` PK DEFAULT `gen_random_uuid()` | |
| `challenge_id` | `uuid NOT NULL` | References `challenges.id` |
| `corrected_by` | `uuid NOT NULL` | References `profiles.id` |
| `field` | `text NOT NULL` | `'dish'`, `'restaurant'`, `'city'`, `'alias_added'`, `'alias_removed'` |
| `old_value` | `text` | |
| `new_value` | `text` | |
| `corrected_at` | `timestamptz NOT NULL DEFAULT now()` | |

#### `comments`
| Column | Type | Notes |
|---|---|---|
| `id` | `uuid` PK DEFAULT `gen_random_uuid()` | |
| `challenge_id` | `uuid NOT NULL` | References `challenges.id` |
| `author_id` | `uuid NOT NULL` | References `profiles.id` |
| `text` | `text NOT NULL` | |
| `posted_at` | `timestamptz NOT NULL DEFAULT now()` | |
| `deleted_at` | `timestamptz` | Soft delete |

#### `reactions`
| Column | Type | Notes |
|---|---|---|
| `id` | `uuid` PK DEFAULT `gen_random_uuid()` | |
| `challenge_id` | `uuid NOT NULL` | References `challenges.id` |
| `player_id` | `uuid NOT NULL` | References `profiles.id` |
| `emoji` | `text NOT NULL` | |
| `reacted_at` | `timestamptz NOT NULL DEFAULT now()` | |
| UNIQUE | `(challenge_id, player_id, emoji)` | One per emoji per player per challenge |

#### `invites` ⚠️ ADDED — flag for Codex/GPT review
Share-sheet group invite links. Anyone in a group can generate one; recipient taps link, app opens (or App Store if not installed), they join immediately with no approval step.

| Column | Type | Notes |
|---|---|---|
| `id` | `uuid` PK DEFAULT `gen_random_uuid()` | |
| `group_id` | `uuid NOT NULL` | References `groups.id` |
| `created_by` | `uuid NOT NULL` | References `profiles.id` |
| `code` | `text NOT NULL UNIQUE` | Short random token used in deep link URL |
| `created_at` | `timestamptz NOT NULL DEFAULT now()` | |
| `expires_at` | `timestamptz NOT NULL` | 7 days after creation |
| `accepted_by` | `uuid` | References `profiles.id`; NULL until redeemed |
| `accepted_at` | `timestamptz` | NULL until redeemed |

**Decisions baked in:**
- Anyone in the group can invite (not just the owner) — family app, low friction
- No pending/approval state — accepting the link adds you immediately
- Link expires after 7 days
- Deep link format: `forkensics://invite/{code}`
- If app not installed: redirect to App Store; code survives in the URL and is redeemed on first launch

---

### 3. Triggers

#### `handle_new_user` (on `auth.users` INSERT)
Creates a `profiles` row automatically when Supabase Auth creates a new user. `display_name` is populated from the user's metadata (captured by the iOS app from `credential.fullName` and passed to Supabase during sign-up).

#### `set_receipt_sequence` (on `guess_attempts` INSERT)
Sets `receipt_sequence` to `MAX(receipt_sequence) + 1` for the challenge, or 1 if first guess. Runs server-side; client cannot set this value.

#### `update_has_first_guess` (on `guess_attempts` INSERT)
Sets `challenge_secrets.has_first_guess = true` for the challenge if not already set.

---

### 4. Row-Level Security Policies

All tables have RLS enabled. Service role bypasses all policies (used by Edge Functions only).

| Table | SELECT | INSERT | UPDATE | DELETE |
|---|---|---|---|---|
| `profiles` | Any authenticated user | Auth trigger only | Own row | Never |
| `groups` | Members of the group | Any authenticated user | Owner only | Never |
| `group_members` | Members of the group | Owner of group | Never | Owner of group |
| `challenges` | Members of group | Members of group (as poster) | Poster (draft/active only) | Never |
| `challenge_secrets` | **Poster only** (before reveal); any member after reveal | Poster at creation | Poster (while !has_first_guess) | Never |
| `eligible_participants` | Members of challenge's group | Service role only (set at post time) | Never | Never |
| `exclusion_events` | Members of challenge's group | Poster or self (withdraw) | Never | Never |
| `hints` | Members of challenge's group | Poster only | Never | Never |
| `guess_attempts` | Own rows (before reveal); all members after reveal | Eligible, non-excluded players | Never (immutable) | Never |
| `score_events` | Members of challenge's group | Service role only | Never | Never |
| `correction_events` | Members of challenge's group | Poster (after reveal) | Never | Never |
| `comments` | Members of challenge's group | Members of challenge's group | Never | Never (soft delete via `deleted_at`) |
| `reactions` | Members of challenge's group | Members of challenge's group | Never | Own row only |
| `rules_versions` | Any authenticated user | Never (seeded at migration) | Never | Never |
| `invites` ⚠️ | Group members (own invites only) | Any group member | Never | Creator only (before accepted) |

---

### 5. Seed Data

One `rules_versions` row inserted at migration time:

```sql
INSERT INTO rules_versions (id, version_tag, scoring_formula, normalization_rules)
VALUES (
  'a0000000-0000-0000-0000-000000000001',
  'v1',
  'Points = effectiveEligibleCount - rank + 1 (minimum 1). Standard competition ranking. Ties share rank; broken by receipt_sequence.',
  'Lowercase. Strip apostrophes, punctuation, hyphens. Collapse whitespace. Trim.'
);
```

---

## What This Step Does NOT Include

- No Swift code changes
- No authentication (Step 3)
- No Storage bucket setup (Step 5)
- No Edge Functions (Step 6)
- No Realtime subscriptions (Step 7)
- No group creation UI or invite flow

---

## Acceptance Criteria

- [ ] Supabase project exists and is accessible
- [ ] All 13 tables created with correct columns, types, and constraints
- [ ] All foreign key relationships enforced
- [ ] RLS enabled on all tables with correct policies
- [ ] `handle_new_user` trigger in place
- [ ] `set_receipt_sequence` trigger in place
- [ ] `update_has_first_guess` trigger in place
- [ ] `rules_versions` seeded with v1 row
- [ ] Supabase Table Editor confirms schema matches this document
- [ ] No data accessible without authentication (RLS confirmed via anon key test)

---

## Review Checklist (for Codex/GPT)

Please confirm or flag:
1. Are all columns, types, and constraints correct given the architecture decisions?
2. Are the RLS policies complete and correctly restrictive — especially `challenge_secrets`?
3. Are the triggers correct and sufficient?
4. Is anything missing from the schema given the full game mechanics?
5. Any concerns about the seed data or `rules_versions` approach?
6. ⚠️ NEW: `invites` table — is the schema correct for share-sheet deep-link invites? Any concerns with the no-approval-step join flow or the 7-day expiry?
7. ⚠️ NEW: `avatar_image_path` on `profiles` — anything needed alongside this (e.g. a separate Storage bucket policy note)?
