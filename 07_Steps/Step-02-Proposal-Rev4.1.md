# Step 2 Proposal — Revision 4.1 Addendum

**Status:** Pending review (Claude → Codex/GPT → Bill approval)
**Amends:** Step-02-Proposal-Rev4.md (core architecture approved)
**Governance gate:** Bill must type `APPROVED: Step 2 — Supabase Project & Database Schema` before SQL is generated.

This addendum resolves the five remaining contradictions from the Rev 4 review. It does not restate the full schema — it overrides or extends specific items only.

---

## 1. Account Deletion — Edge Function Architecture

`public.delete_account()` is removed from the database function list. Account deletion requires a service-role credential and cannot be completed by an authenticated PostgreSQL function alone.

**Replacement architecture:**

```
iOS app
  └─→ DELETE /account  (authenticated Edge Function)
        ├─ Verifies caller's JWT and active status
        ├─ Calls private.prepare_account_deletion(caller_id)
        │    ├─ Cancels all draft/active challenges (cancel_challenge logic)
        │    ├─ Appends exclusion_events (reason='account_deleted', excluded_by=NULL)
        │    │    for every active challenge where caller is an eligible participant
        │    ├─ Transfers group ownership for each owned group
        │    │    └─ If no active onboarded replacement member: archives the group
        │    ├─ Archives identity to private.profile_archive
        │    └─ Overwrites profiles row: display_name='Former Player', avatar_color='gray',
        │         avatar_media_object_id=NULL, is_active=false
        ├─ Calls auth.admin.deleteUser(caller_id)  [service-role, Auth API]
        └─ Records deletion_log row for retry safety (see below)
```

**`private.prepare_account_deletion(p_profile_id uuid)`**
- Service-role only; not callable by `authenticated`
- Idempotent: safe to retry if Edge Function fails between DB step and Auth API step

**`private.deletion_log`** (private schema, no client access)

| Column | Type | Notes |
|---|---|---|
| `profile_id` | `uuid PK` | References `profiles.id` |
| `db_step_completed_at` | `timestamptz` | Set when prepare_account_deletion succeeds |
| `auth_step_completed_at` | `timestamptz` | Set when auth.admin.deleteUser succeeds |
| `last_attempt_at` | `timestamptz` | |
| `error` | `text` | Last error if incomplete |

**`exclusion_events` schema change:** `excluded_by` becomes nullable to support system exclusions:
```sql
-- excluded_by NULL means system-initiated (account_deleted)
excluded_by uuid REFERENCES profiles(id)  -- NULL allowed
```

Trigger updated: when `excluded_by IS NULL`, reason must be `'account_deleted'`; this path is only callable from `private.prepare_account_deletion()` (service-role context verified via `current_user`).

**Foreign key compatibility:** `profiles.id` references `auth.users.id`. Supabase's soft-delete (`auth.admin.deleteUser`) retains the auth record, so the FK remains valid. Addendum acceptance test: verify the chosen deletion mode does not violate this constraint.

---

## 2. Private Helper Privilege Model — Correction and Complete Function List

**Privilege model for private schema:**

```sql
-- Private schema: not in Supabase exposed Data API schemas (not in search_path)
REVOKE CREATE ON SCHEMA private FROM PUBLIC, anon, authenticated;

-- Client roles need USAGE on private schema + EXECUTE on helper functions
-- only so that RLS policies referencing those helpers can be evaluated.
-- They do NOT get access to private tables.
GRANT USAGE ON SCHEMA private TO authenticated;
GRANT EXECUTE ON FUNCTION
  private.is_group_member(uuid),
  private.is_group_member_with(uuid),
  private.is_challenge_group_member(uuid),
  private.is_challenge_poster(uuid),
  private.is_challenge_revealed(uuid),
  private.is_eligible_non_excluded(uuid)
TO authenticated;

-- Private tables: service role only
REVOKE ALL ON private.profile_archive FROM PUBLIC, anon, authenticated;
REVOKE ALL ON private.media_storage_keys FROM PUBLIC, anon, authenticated;
REVOKE ALL ON private.deletion_log FROM PUBLIC, anon, authenticated;
GRANT ALL ON private.profile_archive, private.media_storage_keys, private.deletion_log
TO service_role;
```

**Complete function list (17 total):**

*Private helpers — USAGE+EXECUTE granted to `authenticated` for RLS only:*
1. `private.is_group_member(p_group_id uuid) → boolean`
2. `private.is_group_member_with(p_profile_id uuid) → boolean` ← previously missing
3. `private.is_challenge_group_member(p_challenge_id uuid) → boolean`
4. `private.is_challenge_poster(p_challenge_id uuid) → boolean`
5. `private.is_challenge_revealed(p_challenge_id uuid) → boolean`
6. `private.is_eligible_non_excluded(p_challenge_id uuid) → boolean`

*Public operational — EXECUTE granted to `authenticated`:*
7. `public.create_group(p_name text) → uuid`
8. `public.transfer_group_ownership(p_group_id uuid, p_new_owner_id uuid) → void`
9. `public.create_group_invite(p_group_id uuid) → text`
10. `public.redeem_group_invite(p_raw_token text) → uuid`
11. `public.revoke_group_invite(p_invite_id uuid) → void`
12. `public.activate_challenge(p_challenge_id uuid) → void`
13. `public.reveal_challenge(p_challenge_id uuid) → void`
14. `public.cancel_challenge(p_challenge_id uuid, p_reason text) → void`
15. `public.apply_correction(p_challenge_id uuid, p_action text, p_target_field text, p_new_display_value text, p_alias_id uuid, p_reason text) → uuid`

*Service-role only — no `authenticated` EXECUTE grant:*
16. `public.lock_challenge(p_challenge_id uuid) → void`
17. `private.prepare_account_deletion(p_profile_id uuid) → void`

All functions: `SET search_path = ''`; fully qualified object names.

---

## 3. Concurrency Safety — All State-Changing Functions

Every function that changes challenge state now follows this pattern:

```
1. SELECT ... FOR UPDATE on the challenge row
2. Re-read and verify current state after lock acquired
3. Validate caller (is_active, authorization)
4. Execute transition and set all timestamps
```

**`lock_challenge()` addition:**
```sql
-- Verify deadline has been reached before locking
IF clock_timestamp() < challenges.deadline_at THEN
  RAISE EXCEPTION 'challenge deadline has not been reached';
END IF;
-- Then verify state = 'active'
```

**`cancel_challenge()` addition:**
```sql
-- Lock row first, then recheck state
SELECT ... FOR UPDATE;
IF state NOT IN ('draft','active') THEN
  RAISE EXCEPTION 'challenge cannot be cancelled in state %', state;
END IF;
-- cancellation_reason set only here; blocked in ordinary UPDATE by trigger
```

**`reveal_challenge()` — clarified caller rules:**
- Poster may call only when `clock_timestamp() >= deadline_at` (at or after deadline; no early reveal)
- Service role (scheduler) calls after `lock_challenge()` transitions state to `locked`
- Both paths verify state ∈ {`'active'` with deadline reached, `'locked'`}

**`activate_challenge()` addition:**
- After locking row, re-verify `state = 'draft'` before any writes

---

## 4. Exact Privilege Matrix

Replace the blanket grant in Rev 4 with this table-by-table model. Applied after `REVOKE ALL ON ALL TABLES IN SCHEMA public FROM PUBLIC, anon, authenticated`:

| Table | authenticated grants |
|---|---|
| `profiles` | SELECT; UPDATE (limited columns via trigger — not id, created_at, is_active) |
| `groups` | SELECT; UPDATE (name, archived_at — owner only via RLS; not created_by, created_at, id) |
| `group_members` | SELECT only — all mutations via functions |
| `group_invites` | SELECT only — all mutations via functions |
| `rules_versions` | SELECT only |
| `media_objects` | SELECT only — INSERT/UPDATE via service-role Edge Function |
| `challenges` | SELECT; INSERT (trigger forces draft + sets poster_id); UPDATE (limited columns, no state/timestamps) |
| `challenge_secrets` | SELECT; INSERT; UPDATE (while !has_first_guess, limited columns) |
| `challenge_answer_aliases` | SELECT; INSERT; UPDATE (is_active while !has_first_guess) |
| `eligible_participants` | SELECT only |
| `exclusion_events` | SELECT; INSERT (trigger enforces all rules) |
| `hints` | SELECT; INSERT |
| `guess_attempts` | SELECT; INSERT |
| `guess_judgments` | SELECT only |
| `score_runs` | SELECT only |
| `score_events` | SELECT only |
| `correction_events` | SELECT only — INSERT/UPDATE via apply_correction() function |
| `comments` | SELECT; INSERT; UPDATE (own rows; trigger restricts to deleted_at only) |
| `reactions` | SELECT; INSERT; DELETE (own rows) |

**Views:**
```sql
GRANT SELECT ON current_score_events TO authenticated;
REVOKE INSERT, UPDATE, DELETE ON current_score_events FROM PUBLIC, anon, authenticated;
```

**Sequence:**
```sql
-- guess_receipt_seq: EXECUTE on nextval granted to the trigger owner (postgres/service role).
-- authenticated role does NOT receive USAGE or SELECT on the sequence.
-- The BEFORE INSERT trigger runs as a SECURITY DEFINER function owned by postgres,
-- so nextval() is called under the owner's privileges, not the client's.
REVOKE ALL ON SEQUENCE guess_receipt_seq FROM PUBLIC, anon, authenticated;
```

**Default privileges for future objects:**
```sql
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  REVOKE ALL ON TABLES FROM PUBLIC, anon, authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  REVOKE ALL ON SEQUENCES FROM PUBLIC, anon, authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  REVOKE ALL ON FUNCTIONS FROM PUBLIC, anon, authenticated;
```

**State column protection:** The `protect_challenge_authority_fields` BEFORE UPDATE trigger raises an exception if the UPDATE includes the `state` column (outside of lifecycle functions running as the function owner). Direct state UPDATE by `authenticated` is also denied at the privilege level — `state` is not in any UPDATE column list granted above, and the trigger provides defense in depth.

---

## 5. Remaining Smaller Gaps

**5a. Active-profile check in every public SECURITY DEFINER function**

Every public operational function (functions 7–15 above) begins with:
```sql
IF NOT EXISTS (
  SELECT 1 FROM profiles
  WHERE id = auth.uid() AND is_active = true
) THEN
  RAISE EXCEPTION 'account is inactive';
END IF;
```
This runs inside the function body, not relying solely on RLS, because SECURITY DEFINER functions bypass the caller's RLS context.

**5b. `transfer_group_ownership()` guard**

Before transferring, verify:
- New owner `is_active = true` AND `onboarding_complete = true`
- New owner is currently a `group_members` member of the group (not just any profile)

**5c. Invite operations reject archived groups**

`create_group_invite()` and `redeem_group_invite()` both verify `groups.archived_at IS NULL` before proceeding. Archived group returns a specific error.

**5d. `apply_correction()` alias validation**

Before removing an alias:
```sql
-- Verify alias exists, belongs to the correct challenge and target_field, and is active
SELECT 1 FROM challenge_answer_aliases
WHERE id = p_alias_id
  AND challenge_id = p_challenge_id
  AND field = p_target_field
  AND is_active = true
FOR UPDATE;
-- Raises exception if not found
```

**5e. `cancellation_reason` — draft edit protection**

`protect_challenge_authority_fields` BEFORE UPDATE trigger adds `cancellation_reason` to the list of fields blocked from ordinary client UPDATE. It is set only inside `cancel_challenge()` (trusted SECURITY DEFINER context).

**5f. `challenge_secrets.story` max length**
```sql
-- Add to challenge_secrets
story text CHECK (story IS NULL OR length(story) <= 2000)
```

**5g. Trusted bypass for answer/alias guard triggers**

Guard triggers (`guard_answer_edits`, `guard_alias_edits`) determine trusted context using `current_user`:

```sql
-- In trigger function body:
IF current_user = 'postgres' THEN
  -- Called from a SECURITY DEFINER function owned by postgres (apply_correction)
  RETURN NEW;
END IF;
-- Otherwise apply the lock check
```

All SECURITY DEFINER functions are owned by the `postgres` superuser role. When `apply_correction()` executes, `current_user = 'postgres'`, so the guard trigger recognizes the trusted context. Authenticated clients always execute as their own role (`current_user = 'authenticated'`), so they can never spoof this check. No client-settable session variable is used.

**5h. Client-supplied timestamps blocked on all write paths**

Added to the relevant BEFORE INSERT triggers (or trigger-like column enforcement):

| Table | Timestamp columns overwritten by trigger |
|---|---|
| `hints` | `posted_at = clock_timestamp()` |
| `comments` | `posted_at = clock_timestamp()` |
| `reactions` | `reacted_at = clock_timestamp()` |
| `exclusion_events` | `excluded_at = clock_timestamp()` |
| `challenge_secrets` | `created_at = clock_timestamp()` on INSERT; `updated_at = clock_timestamp()` on UPDATE |
| `challenge_answer_aliases` | `created_at = clock_timestamp()` on INSERT |
| `challenges` | `created_at = clock_timestamp()` on INSERT (join with existing state-machine trigger) |

**5i. Active profiles cannot select `'gray'` avatar color**

Updated CHECK on `profiles`:
```sql
CHECK (
  (is_active = true  AND avatar_color IN ('orange','red','blue','green','purple','yellow','pink','teal'))
  OR
  (is_active = false AND avatar_color = 'gray')
)
```

**5j. `challenge_secrets.updated_at` maintained**

Existing `guard_answer_edits` trigger already fires BEFORE UPDATE on `challenge_secrets`. Add to its body (when allowing the update):
```sql
NEW.updated_at := clock_timestamp();
```

**5k. `transfer_group_ownership()` in account deletion**

Inside `private.prepare_account_deletion()`, group ownership transfer for each group where the deleted user is the owner:
1. Find the longest-tenured active onboarded non-deleted member (`joined_at` ASC)
2. If found: call ownership-transfer logic (same as `transfer_group_ownership()`)
3. If none found: set `groups.archived_at = clock_timestamp()`

---

## Acceptance Tests — Additions

Add to Rev 4 acceptance criteria:

**Account deletion:**
- [ ] `public.delete_account()` no longer exists as a callable DB function
- [ ] `private.prepare_account_deletion()` cannot be called by `authenticated` role
- [ ] Post-deletion profile shows 'Former Player'; `is_active = false`; `avatar_color = 'gray'`
- [ ] Deleted user's draft/active challenges are cancelled
- [ ] Deleted user's active participations have system exclusion appended
- [ ] Deleted user's owned groups transferred or archived correctly
- [ ] Soft-deleted auth user does not violate `profiles.id → auth.users.id` FK
- [ ] Partial deletion (DB done, Auth API not yet) can be safely retried
- [ ] Expired JWT from deleted profile cannot call any public operational function (verified via active-profile guard in each function)

**Concurrency:**
- [ ] `lock_challenge()` rejects call if `clock_timestamp() < deadline_at`
- [ ] `cancel_challenge()` re-reads and re-checks state after row lock acquired
- [ ] `reveal_challenge()` by poster requires `clock_timestamp() >= deadline_at`
- [ ] `reveal_challenge()` by service role requires `state = 'locked'`

**Privileges:**
- [ ] `authenticated` role cannot call `lock_challenge()`
- [ ] `authenticated` role cannot call `private.prepare_account_deletion()`
- [ ] `authenticated` role cannot UPDATE `challenge.state` directly
- [ ] `authenticated` role cannot UPDATE protected profile columns (`id`, `created_at`, `is_active`)
- [ ] `authenticated` role cannot read or write `private.deletion_log`
- [ ] `authenticated` role cannot use `nextval('guess_receipt_seq')` directly
- [ ] Every RLS policy evaluates correctly through authenticated client role
- [ ] Default privilege settings prevent future tables from being auto-exposed

**Small-gap items:**
- [ ] Active profile setting `avatar_color = 'gray'` is rejected by CHECK constraint
- [ ] `gray` avatar color accepted only when `is_active = false`
- [ ] `apply_correction()` with wrong `alias_id` (wrong challenge or target_field) raises exception
- [ ] `apply_correction()` on already-inactive alias raises exception
- [ ] Invite creation on archived group rejected
- [ ] Invite redemption on archived group rejected
- [ ] `transfer_group_ownership()` to non-member or inactive profile rejected
- [ ] `challenge_secrets.updated_at` advances on legitimate poster edit
- [ ] `challenge_secrets.story` rejects values exceeding 2000 characters
- [ ] `cancellation_reason` cannot be set via direct challenge UPDATE
- [ ] Client-supplied `posted_at` on hints, comments, reactions, exclusions overwritten by trigger

---

## Review Checklist (for Codex/GPT — Rev 4.1)

1. Is the Edge Function + `private.prepare_account_deletion()` architecture correct for Supabase Auth deletion?
2. Is `private.deletion_log` sufficient for retry safety?
3. Is the `GRANT USAGE ON SCHEMA private TO authenticated` + selective EXECUTE correct for RLS helper evaluation without exposing private tables?
4. Is the `current_user = 'postgres'` guard trigger bypass approach sound? Any concern about the superuser role name varying across Supabase projects?
5. Is the privilege matrix complete and minimally permissive?
6. Is `lock_challenge()` deadline check sufficient to prevent early game closure?
7. Is the `reveal_challenge()` at-or-after-deadline rule correctly specified for the poster path?
8. Is the account deletion cascade (challenges, exclusions, group ownership) complete?
9. Is anything still missing before SQL generation can begin?
10. Duration (1–48 hours, whole-hour steps, default 2 hours) confirmed implemented correctly in Rev 4.
