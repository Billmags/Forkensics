# Step 2 Proposal — Revision 4.2 Amendment

**Status:** Pending review (Claude → Codex/GPT → Bill approval)
**Amends:** Rev 4 + Rev 4.1 addendum
**Governance gate:** Bill must type `APPROVED: Step 2 — Supabase Project & Database Schema` before SQL is generated.

This amendment resolves the four technical corrections from the Rev 4.1 review, plus two product decisions confirmed during the Rev 4.2 review cycle: city visibility as a poster choice, and the Hints → Clues rename throughout.

---

## Correction 1 — `exclusion_events.reason` Constraint

Replace the existing two-value CHECK with:

```sql
CHECK (reason IN ('withdrew', 'removed', 'account_deleted'))
```

Add a companion CHECK enforcing the `excluded_by` rule:

```sql
CHECK (
  (reason IN ('withdrew', 'removed') AND excluded_by IS NOT NULL)
  OR
  (reason = 'account_deleted'       AND excluded_by IS NULL)
)
```

**Behavioral rules (enforced by the existing exclusion trigger, now updated):**
- `account_deleted` rows may only be inserted by `private.prepare_account_deletion()` (verified via `current_user = 'forkensics_executor'` — see Correction 2)
- Insertion is idempotent: if an `exclusion_events` row already exists for `(challenge_id, player_id)`, the deletion function skips that challenge rather than raising a duplicate-key error (the existing UNIQUE constraint prevents double-exclusion; the function catches the conflict and continues)

---

## Correction 2 — Dedicated Executor Role (replaces `postgres` bypass)

**Remove:** all references to `current_user = 'postgres'` as the guard-trigger bypass.

**Add:** a dedicated non-login role.

```sql
CREATE ROLE forkensics_executor NOLOGIN;
```

**Ownership:**
The following SECURITY DEFINER functions are owned by `forkensics_executor` (not `postgres`):
- `public.apply_correction()`
- `public.activate_challenge()`
- `public.reveal_challenge()`
- `public.cancel_challenge()`
- `public.lock_challenge()`
- `public.transfer_group_ownership()`
- `private.prepare_account_deletion()`

RLS helper functions (`private.is_*`) are owned by a separate least-privileged role `forkensics_rls_helper` (NOLOGIN), which requires only SELECT on the tables it reads. This limits the blast radius if either role's privileges are ever misconfigured.

```sql
CREATE ROLE forkensics_rls_helper NOLOGIN;
```

**Guard trigger bypass:**

```sql
-- In guard_answer_edits and guard_alias_edits trigger bodies:
IF current_user = 'forkensics_executor' THEN
  NEW.updated_at := clock_timestamp();  -- also maintain updated_at
  RETURN NEW;
END IF;
```

`authenticated` clients always execute as the `authenticated` role; they cannot assume `forkensics_executor`. The role has no login privilege and no way for clients to escalate to it.

**Grants to `forkensics_executor`** (only what trusted mutations require):

```sql
GRANT USAGE ON SCHEMA public, private TO forkensics_executor;
GRANT SELECT, INSERT, UPDATE ON
  challenges, challenge_secrets, challenge_answer_aliases,
  eligible_participants, exclusion_events, guess_attempts,
  guess_judgments, score_runs, score_events, correction_events,
  groups, group_members, profiles
TO forkensics_executor;
GRANT USAGE, SELECT ON SEQUENCE guess_receipt_seq TO forkensics_executor;
GRANT ALL ON private.profile_archive, private.deletion_log TO forkensics_executor;
```

**Grants to `forkensics_rls_helper`** (SELECT only on membership tables):

```sql
GRANT USAGE ON SCHEMA public, private TO forkensics_rls_helper;
GRANT SELECT ON profiles, group_members, challenges, eligible_participants,
               exclusion_events TO forkensics_rls_helper;
```

---

## Correction 3 — Deletion Retry State Machine

**`private.deletion_log` — updated schema:**

| Column | Type | Notes |
|---|---|---|
| `profile_id` | `uuid PK` | References `profiles.id` |
| `status` | `text NOT NULL DEFAULT 'pending'` | CHECK: `IN ('pending','database_prepared','auth_deleted','complete','failed')` |
| `db_prepared_at` | `timestamptz` | Set when `prepare_account_deletion()` completes |
| `auth_deleted_at` | `timestamptz` | Set when `auth.admin.deleteUser()` succeeds |
| `completed_at` | `timestamptz` | Set when both steps confirmed |
| `last_attempt_at` | `timestamptz NOT NULL DEFAULT clock_timestamp()` | |
| `error` | `text` | Last error message |

**Edge Function retry logic:**

```
On DELETE /account request:
  caller = authenticated user from JWT

  IF caller profile is_active = true:
    → Proceed as new deletion (status = 'pending')

  ELSE IF caller profile is_active = false:
    → Look up deletion_log for this profile_id
    IF deletion_log.status IN ('database_prepared', 'failed'):
      → Retry from Auth API step only (DB already prepared)
    ELSE IF deletion_log.status = 'auth_deleted':
      → Mark complete (idempotent finish)
    ELSE IF deletion_log.status = 'complete':
      → Return success (already done)
    ELSE:
      → Reject (inactive account with no deletion record — unexpected state)

  → Never restore is_active = true due to Auth API failure
```

**Service-role reconciliation** (for cases where the client can no longer retry):
- Supabase cron job or admin Edge Function queries `deletion_log WHERE status = 'database_prepared'`
- For each: calls `auth.admin.deleteUser(profile_id)`
- "User not found" is treated as success (already deleted)
- Updates `deletion_log.status` accordingly

---

## Correction 4 — `reveal_challenge()` Dual Path and Column-Specific Grants

### `reveal_challenge()` — two caller paths

```sql
-- Inside reveal_challenge():

IF auth.uid() IS NOT NULL THEN
  -- Authenticated poster path
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND is_active = true) THEN
    RAISE EXCEPTION 'account is inactive';
  END IF;
  IF challenge.poster_id != auth.uid() THEN
    RAISE EXCEPTION 'caller is not the poster';
  END IF;
  IF clock_timestamp() < challenge.deadline_at THEN
    RAISE EXCEPTION 'deadline has not been reached';
  END IF;
  IF challenge.state NOT IN ('active','locked') THEN
    RAISE EXCEPTION 'invalid state for poster reveal: %', challenge.state;
  END IF;

ELSE
  -- Service scheduler path (no JWT / service role context)
  IF challenge.state != 'locked' THEN
    RAISE EXCEPTION 'service reveal requires locked state';
  END IF;
END IF;
```

The active-profile check is applied to every public operational function **except** `reveal_challenge()` and `lock_challenge()`, which have explicit dual-path caller validation above.

### Column-specific UPDATE grants

Replace all "limited columns" language with explicit column-level grants:

```sql
-- profiles
GRANT UPDATE (display_name, avatar_color, avatar_media_object_id, onboarding_complete)
  ON profiles TO authenticated;

-- groups
GRANT UPDATE (name, archived_at)
  ON groups TO authenticated;

-- challenges
GRANT UPDATE (media_object_id, duration_seconds)
  ON challenges TO authenticated;

-- challenge_secrets
GRANT UPDATE (display_dish, canonical_dish, display_restaurant, canonical_restaurant,
              display_city, canonical_city, story)
  ON challenge_secrets TO authenticated;

-- challenge_answer_aliases
GRANT UPDATE (is_active)
  ON challenge_answer_aliases TO authenticated;

-- comments
GRANT UPDATE (deleted_at)
  ON comments TO authenticated;

-- All other tables: no UPDATE granted to authenticated
-- (group_members, group_invites, exclusion_events, hints,
--  guess_attempts, guess_judgments, score_runs, score_events,
--  correction_events, reactions, eligible_participants,
--  rules_versions, media_objects — no UPDATE to authenticated)
```

No UPDATE privilege on: `state`, `poster_id`, `group_id`, `rules_version_id`, `is_active`, `cancellation_reason`, `posted_at`, `deadline_at`, `locked_at`, `revealed_at`, `cancelled_at`, `created_at`, or any other protected field.

### Service-role function grants

```sql
-- Explicitly grant service_role execution of scheduler/deletion functions
GRANT EXECUTE ON FUNCTION public.lock_challenge(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION private.prepare_account_deletion(uuid) TO service_role;

-- Explicitly revoke those same functions from all client roles
REVOKE EXECUTE ON FUNCTION public.lock_challenge(uuid) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION private.prepare_account_deletion(uuid) FROM PUBLIC, anon, authenticated;
```

---

## Correction 5 — City Visibility as Poster Choice (confirmed product decision)

The poster controls whether city is hidden or revealed at challenge creation time.

**`challenges` table — new column:**
```sql
city_revealed boolean NOT NULL DEFAULT false
```

- `city_revealed = false` (default): players must guess both restaurant AND city for the Where? race
- `city_revealed = true`: city is pre-displayed to all eligible participants; players guess restaurant only
- Immutable after `activate_challenge()` runs (protected by `protect_challenge_authority_fields` trigger)
- Displayed in the guess UI: city field shown with label "Clue: [city]" when revealed; hidden text field when not

**Where? matching logic update:**
- `city_revealed = false`: normalized restaurant AND normalized city must both match
- `city_revealed = true`: normalized restaurant must match; city match is not evaluated (pre-revealed)
- Point formula and race structure unchanged in both cases

**Column grant addition:**
```sql
GRANT UPDATE (media_object_id, duration_seconds, city_revealed)
  ON challenges TO authenticated;
-- city_revealed editable by poster only while state = 'draft' (RLS + trigger enforced)
```

**`rules_versions.config` update** — add to v1 config JSONB:
```json
"city_visibility": "poster_choice"
```

---

## Correction 6 — Hints → Clues Rename (confirmed product decision)

"Hints" renamed to "Clues" throughout the app and schema for brand consistency ("detective" terminology matches Forkensics identity).

**Schema renames:**
```sql
ALTER TABLE hints RENAME TO clues;
-- All references updated: foreign keys, indexes, triggers, RLS policies, functions
```

**Column/function references updated:**
- `hints.poster_id` → `clues.poster_id`
- `hints.text` → `clues.text`
- `hints.posted_at` → `clues.posted_at`
- `private.is_challenge_group_member()` and all lifecycle functions updated to reference `clues`
- `hintsByChallenge` in Swift → `cluesByChallenge` (Step 3+ only; no Swift changes in Step 2)

**UI language (Step 3+):**
- "Get a Clue" (action button)
- "Reveal a Clue" (alternative)
- "1 Clue Available"
- "Add a Clue" (poster posting flow)

**Table grants updated:**
```sql
-- (hints reference in privilege matrix replaced with clues)
GRANT SELECT, INSERT ON clues TO authenticated;
```

---

## Acceptance Tests — Additions for Rev 4.2

**Exclusion constraint:**
- [ ] `reason = 'account_deleted'` with `excluded_by IS NOT NULL` raises constraint violation
- [ ] `reason = 'withdrew'` with `excluded_by IS NULL` raises constraint violation
- [ ] Duplicate `account_deleted` exclusion for same player/challenge is handled idempotently

**Executor role:**
- [ ] `authenticated` role cannot assume `forkensics_executor`
- [ ] Direct `SET ROLE forkensics_executor` by `authenticated` raises permission error
- [ ] Guard trigger allows edit when `current_user = 'forkensics_executor'`
- [ ] Guard trigger blocks edit when `current_user = 'authenticated'`
- [ ] `forkensics_rls_helper` cannot INSERT, UPDATE, or DELETE any table

**Deletion retry:**
- [ ] Inactive profile with `status = 'database_prepared'` can retry deletion endpoint
- [ ] Inactive profile with no deletion_log record is rejected
- [ ] Auth "user not found" during reconciliation is treated as success
- [ ] Profile `is_active` is never restored to `true` after a failed Auth API step
- [ ] `deletion_log.status` transitions: `pending → database_prepared → auth_deleted → complete`

**`reveal_challenge()` dual path:**
- [ ] Poster can reveal at or after deadline (`state = 'active'` or `'locked'`)
- [ ] Poster cannot reveal before deadline
- [ ] Service role can reveal when `state = 'locked'`
- [ ] Service role call with `state = 'active'` raises exception
- [ ] Non-poster authenticated user cannot call `reveal_challenge()`
- [ ] `reveal_challenge()` does not apply active-profile check on service path

**Column-level grants:**
- [ ] `authenticated` cannot UPDATE `challenges.state` directly
- [ ] `authenticated` cannot UPDATE `profiles.is_active`
- [ ] `authenticated` cannot UPDATE `challenges.cancellation_reason` directly
- [ ] `authenticated` cannot UPDATE `challenges.posted_at`
- [ ] `authenticated` cannot EXECUTE `lock_challenge()`
- [ ] `authenticated` cannot EXECUTE `private.prepare_account_deletion()`
- [ ] `service_role` can EXECUTE `lock_challenge()`
- [ ] `service_role` can EXECUTE `private.prepare_account_deletion()`

**City visibility:**
- [ ] `city_revealed = true` causes city to be pre-displayed in guess UI; restaurant-only matching applies
- [ ] `city_revealed = false` (default) requires both restaurant and city to match
- [ ] `city_revealed` cannot be changed after `activate_challenge()` runs
- [ ] `city_revealed` is included in column-level UPDATE grant for `challenges`

**Clues rename:**
- [ ] Table `clues` exists (not `hints`)
- [ ] All foreign key references, indexes, triggers, RLS policies, and functions reference `clues`
- [ ] No remaining references to `hints` in the schema

---

## Review Checklist (for Codex/GPT — Rev 4.2)

1. Is the updated `exclusion_events` CHECK constraint correct and complete?
2. Is `forkensics_executor` (NOLOGIN) a sound replacement for the `postgres` bypass? Any Supabase-specific concern with custom NOLOGIN roles owning SECURITY DEFINER functions?
3. Is the deletion retry state machine complete and safe? Is reconciliation sufficient for the unretryable case?
4. Is the `reveal_challenge()` dual-path caller validation correct for both poster and service-scheduler paths?
5. Are the column-specific UPDATE grants complete and minimally permissive?
6. Are the service-role EXECUTE grants and revocations complete?
7. Is the `city_revealed` field and its matching-logic impact on Where? correctness correct and complete?
8. Is the `hints → clues` rename complete with no orphaned references?
9. Is anything still missing before SQL generation can begin?
