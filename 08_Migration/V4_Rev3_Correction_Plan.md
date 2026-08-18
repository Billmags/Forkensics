# V4 Rev 3 Correction Plan — Rev 3
**Status:** PLAN APPROVED — Gate 2 complete — awaiting final V4 coding authorization (Gate 3)
**Formal approval:** Codex: "APPROVED: V4 Rev 3 Correction Plan — as the governing correction blueprint."  
**Covers:** All nine Codex blockers from the V4 Rev 2 verdict, plus plan corrections from Bill and Codex review rounds, plus three new blockers discovered during Gate 2 V3 inventory  
**V3 status:** COMPLETE. `V3__ugc_safety_moderation.sql` committed as `20260807000002_v3_ugc_safety_moderation.sql`, tagged `v0.3.0-ugc-safety-moderation`, pushed to `github.com/Billmags/Forkensics`. All acceptance and concurrency tests pass. Migration SHA: `1e394903eb0012aa0bed10c68cdf9295598289a7c292a2a18e0d52d07d6562bb`.

**Required sequence — status:**
1. ✅ Implement `V3__ugc_safety_moderation.sql` from Step 24.1 Rev 15 spec
2. ✅ Build and pass V3 acceptance and concurrency tests
3. ✅ Run V1 → V2 → V3 migration chain successfully
4. ✅ Commit and tag V3 (`v0.3.0-ugc-safety-moderation`)
5. ✅ Replace every PROVISIONAL entry in this plan with the actual V3 disposition (this document)
6. ⬜ Return for final V4 coding authorization (Gate 3 — three-party sign-off required)
7. ⬜ Write the corrected V4 migration

---

## Amendment Log

| Rev | Source | Summary |
|---|---|---|
| Plan v1 | Claude | Initial correction plan covering all 9 blockers |
| Plan v2 | Bill review | 10 corrections: upload state stays 'draft', no CASCADE drops, V3 provisional, allowlist roles/signatures, report_content contract, comment deleted_at protection, cases UPDATE policy, case_secrets revealed-member policy, exclusion constraint to Phase 10 |
| Plan v3 | Codex review | 7 corrections: policy column errors (case_secrets/correction_events have no investigation_id), report_content exact signature/dedup/lock-order/error-codes, service wrapper drop order, V3 inventory now enumerates 8 known missing objects, moderation functions need full V3 port not mechanical fixes, allowlist signature corrections, comment INSERT onboarding-complete requirement |
| Plan v4 | Codex conditional approval | 4 corrections + 2 documentation cleanups: moderator statement corrected (V4 does not check profile active), profile-lock SELECT example fixed, allowlist additions (cancel_investigation + get_media_serve_authorization), policy count corrected to 8, NULL-constraint placement note corrected |
| Plan v5 | Codex formal approval | Status updated to APPROVED; V3-first sequence recorded; wording correction: report_content locking sequence is from Step 26 Rev 15 contract, not V4 source |
| Plan v6 (this) | Gate 2 V3 inventory pass | All PROVISIONAL entries replaced with confirmed V3 dispositions; three new blockers discovered from committed V3 source: Blocker 10 (check_text_content_trigger table-name strings), Blocker 11 (restrict_comment_updates column rename), Blocker 12 (claim_moderation_media_cleanup table ref); action_report and dismiss_report confirmed no challenge refs |

---

## Blocker 1 — Schema CREATE grants missing in Phase 13C / 20C

### Problem
PostgreSQL 16+ requires two conditions for `ALTER FUNCTION ... OWNER TO role_x`: membership in the target role (Phase 13C provides this) AND the target role must have CREATE on the schema. V3 ended by revoking `CREATE ON SCHEMA` from both executor roles. V4 Phase 13C restores only role membership.

### Fix — Phase 13C addition (after existing membership grants)
```
GRANT CREATE ON SCHEMA private TO forkensics_executor, forkensics_rls_helper;
GRANT CREATE ON SCHEMA public  TO forkensics_executor;
```

### Fix — Phase 20C addition (before existing membership revokes)
```
REVOKE CREATE ON SCHEMA private FROM forkensics_executor, forkensics_rls_helper;
REVOKE CREATE ON SCHEMA public  FROM forkensics_executor;
```

---

## Blocker 2 — Phase 15B creates duplicate policy names on V3-untouched tables

### Problem
V3 already created these RESTRICTIVE policies. Phase 13B did not drop them (those tables are not in the drop loop). Phase 15B issues bare `CREATE POLICY` → duplicate name error.

| Table | Policy Name |
|---|---|
| `public.groups` | `suspend_block_insert`, `suspend_block_update` |
| `public.group_members` | `suspend_block_insert` |
| `public.profiles` | `suspend_block_update` |

### Fix
Add `DROP POLICY IF EXISTS <name> ON <table>` immediately before each of the four `CREATE POLICY` statements in Phase 15B.

---

## Blocker 3 — Missing permissive RLS policies after Phase 13B wipe

Phase 13B dynamically drops all policies on: `cases`, `case_secrets`, `clues`, `comments`, `reactions`, `guess_attempts`, `eligible_participants`, `exclusion_events`, `correction_events`, `score_runs`, `guess_judgments`, `score_events`, `case_answer_aliases`. The following are confirmed missing from Phase 15.

### Gap 3A — cases: missing INSERT policy
`suspend_block_insert` RESTRICTIVE exists; no permissive INSERT → all case creation fails.

**Fix — `cases_insert` permissive INSERT:**
- `poster_id = private.auth_uid()`
- Profile active and onboarding-complete

### Gap 3B — cases: missing UPDATE policy
V1 had `challenges_update_poster`. No permissive UPDATE → posters cannot edit draft case fields.

**Fix — `cases_update_poster` permissive UPDATE:**
- USING: `poster_id = private.auth_uid() AND state = 'draft'` AND profile active and onboarding-complete
- WITH CHECK: same (poster cannot change poster_id to another user)
- State restricted to `'draft'` matching V1 exactly

### Gap 3C — case_secrets: missing INSERT policy
**Fix — `case_secrets_insert` permissive INSERT:**
- Parent case `poster_id = private.auth_uid()` AND profile active and onboarding-complete

### Gap 3D — case_secrets: missing UPDATE policy
**Fix — `case_secrets_update_poster` permissive UPDATE:**
- `private.is_case_poster(case_id)` AND profile active

### Gap 3E — case_secrets: missing revealed-member SELECT *(corrected — no investigation_id column)*
V1 `challenge_secrets_select` covered poster AND revealed group members. V4 restores only the poster view. `case_secrets` has only `case_id` — it has no `investigation_id` column.

**Fix — `case_secrets_member_revealed_view` permissive SELECT:**
- `private.is_case_revealed(case_id)` AND `private.is_case_member(case_id)` AND profile active

### Gap 3F — clues: missing INSERT policy
**Fix — `clues_insert_poster` permissive INSERT:**
- `private.is_case_poster(case_id)` AND case state is `'launched'` AND profile active and onboarding-complete

### Gap 3G — correction_events: no permissive SELECT *(corrected — no investigation_id column)*
Only a RESTRICTIVE `block_aware_visibility` policy exists; no permissive SELECT → members cannot read correction events. `correction_events` has only `case_id` — it has no `investigation_id` column.

**Fix — two permissive SELECT policies:**

`correction_events_member_view`:
- `private.is_case_revealed(case_id)` AND `private.is_case_member(case_id)` AND profile active

`correction_events_poster_view`:
- `private.is_case_poster(case_id)` AND profile active

### Gap 3H — comments: missing deleted_at protection and onboarding requirement
V4 recreates comment policies but omits two protections from V1.

**Two guards missing from SELECT policies:**
Add `AND deleted_at IS NULL` to the USING clause of `comments_member_view` and `comments_poster_view`. Without this, soft-deleted comments are readable.

**Three guards missing from INSERT policies:**
Add `AND deleted_at IS NULL` AND require `onboarding_complete = true` (not just `is_active = true`) to the WITH CHECK of `comments_member_insert` and `comments_poster_insert`. V1's `comments_insert` required active AND onboarding-complete; V4 omits both protections.

The UPDATE soft-delete policies intentionally omit `deleted_at IS NULL` from WITH CHECK (the update that sets `deleted_at` must be allowed — the trigger enforces immutability). Do not change those.

---

## Blocker 4 — report_content (Phase 19.0C)

### Confirmed function signature *(corrected)*
```
public.report_content(p_target_type text, p_target_id uuid, p_category text, p_detail text)
```
Four arguments, confirmed from V4 source (`ALTER FUNCTION public.report_content(text, uuid, text, text)` at line 1731). The plan v1 stated three arguments — that was wrong.

### Deduplication mechanism *(corrected)*
`report_content` has no idempotency key parameter. Deduplication is by partial-index uniqueness on `(reporter_id, target_type, target_id, category) WHERE status = 'pending'`:
```sql
INSERT INTO public.content_reports (...) VALUES (...)
ON CONFLICT (reporter_id, target_type, target_id, category) WHERE status = 'pending'
DO NOTHING
RETURNING id INTO v_report_id;

IF v_report_id IS NULL THEN
  -- Conflict: fetch existing pending report
  SELECT id INTO v_report_id FROM public.content_reports
  WHERE reporter_id = v_actor_id AND target_type = p_target_type
    AND target_id = p_target_id AND category = p_category AND status = 'pending';
END IF;
```
This existing deduplication mechanism is approved V3 behavior. Preserve exactly.

### Correct lock order — target-first *(corrected)*
There is no universal "profile row first" lock. The approved order is target-first:

| Target type | Lock sequence |
|---|---|
| `case` | Lock case FOR UPDATE |
| `comment` | Lock comment FOR UPDATE → lock case FOR UPDATE |
| `clue` | Lock clue FOR UPDATE → lock case FOR UPDATE |
| `media_object` | Provisional unlocked case read → lock case FOR UPDATE → lock media FOR UPDATE |
| `profile` | Lock target profile FOR UPDATE |

This sequence is specified in the approved Step 26 Rev 15 contract. The current V4 body does not fully implement it. The rewrite must match the contract, not the current V4 source.

### Six mechanical bugs to fix

**Bug 4A:** Comment branch: `SELECT id, state, group_id FROM public.cases` fails — `group_id` was dropped in Phase 18. Remove `group_id` from that SELECT.

**Bug 4B:** Comment visibility gate: `v_comment.author_id = v_actor_id` (checks if reporter is the comment author) should be `private.is_case_poster(v_comment.case_id)` (checks if reporter is the case poster).

**Bug 4C:** Self-report check: `p_target_id = v_actor_id` only works for `profile` targets. For other types, compare the reporter against the content owner:
- `case`: `v_case.poster_id = v_actor_id`
- `comment`: `v_comment.author_id = v_actor_id`
- `clue`: `v_clue.poster_id = v_actor_id` (must load `poster_id` from clues)
- `media_object`: `v_media.uploader_id = v_actor_id` (must load `uploader_id` from media_objects)
- `profile`: `p_target_id = v_actor_id` (existing; correct)

**Bug 4D:** Comment membership check: uses any investigation for the case instead of `v_comment.investigation_id`. An actor in one Table group should not report comments from a different group's investigation.

**Bug 4E — corrected error code:** Clue branch: after locking the case, if `v_case.state = 'cancelled'`, raise `FK_INVALID_INPUT: cannot report content in cancelled case`. This matches every other cancelled-content target in the function. The plan v1 said `FK_NOT_FOUND` — that was wrong.

**Bug 4F — new from Codex:** Profile branch: the target profile must be locked `FOR UPDATE`. Current V4 code only does existence and group membership checks without locking the row. Replace the bare existence check with:
```sql
SELECT id, is_active INTO v_profile FROM public.profiles WHERE id = p_target_id FOR UPDATE;
IF NOT FOUND OR NOT v_profile.is_active THEN RAISE EXCEPTION 'FK_NOT_FOUND'; END IF;
```
Note: both `id` and `is_active` must be selected so the subsequent active-check can read from the locked record.

### Full V3 behavioral contract
The six fixes above are surgical. All other V3 behavior — group membership gate for profiles, visibility gates per target type, cancelled-case rejection pattern, deduplication — is preserved exactly. The target-first locking sequence and deduplication pattern are specified in the approved Step 26 Rev 15 contract; the current V4 body does not fully implement that sequence and is not the authoritative reference.

---

## Blocker 5 — Stale V1/V2 functions and triggers not cleaned up

### 5A — New Phase 13A: obsolete V1 functions to DROP

Drop in dependency-safe order. No CASCADE — explicit revokes and dependency-ordered drops only.

**Step 1 — Drop service wrapper and callers of do_reveal_impl first:** *(corrected — wrapper must move here)*

`public.reveal_challenge_service_wrapper(uuid)` calls `private.reveal_challenge_service(uuid)`. The wrapper must be dropped BEFORE the private function, not deferred to Phase 19.14.

```sql
DROP FUNCTION IF EXISTS public.reveal_challenge_service_wrapper(uuid);

REVOKE EXECUTE ON FUNCTION public.reveal_challenge(uuid) FROM authenticated;
DROP FUNCTION IF EXISTS public.reveal_challenge(uuid);

REVOKE EXECUTE ON FUNCTION private.reveal_challenge_service(uuid) FROM service_role;
DROP FUNCTION IF EXISTS private.reveal_challenge_service(uuid);
```

**Step 2 — Drop do_reveal_impl (its callers are now gone):**
```sql
DROP FUNCTION IF EXISTS private.do_reveal_impl(uuid);
```

**Step 3 — Drop remaining lifecycle functions:**
```sql
REVOKE EXECUTE ON FUNCTION public.activate_challenge(uuid) FROM authenticated;
DROP FUNCTION IF EXISTS public.activate_challenge(uuid);

REVOKE EXECUTE ON FUNCTION public.lock_challenge(uuid) FROM service_role;
DROP FUNCTION IF EXISTS public.lock_challenge(uuid);

REVOKE EXECUTE ON FUNCTION public.cancel_challenge(uuid, text) FROM authenticated;
DROP FUNCTION IF EXISTS public.cancel_challenge(uuid, text);
```

Replacements:

| Dropped | V4 replacement |
|---|---|
| `public.activate_challenge(uuid)` | `public.launch_case(uuid, uuid, uuid[], integer)` |
| `public.lock_challenge(uuid)` | `public.lock_case(uuid)` — Phase 19.11 |
| `public.reveal_challenge(uuid)` | `public.reveal_case(uuid)` — Phase 19.13 |
| `public.reveal_challenge_service_wrapper(uuid)` | `public.reveal_case_service_wrapper(uuid)` — Phase 19.14 (create only; drop moved here) |
| `public.cancel_challenge(uuid, text)` | `public.cancel_case(uuid, text)` — Phase 19.15 |
| `private.do_reveal_impl(uuid)` | `private.do_reveal_impl_v3(uuid, uuid)` — Phase 19.12 |
| `private.reveal_challenge_service(uuid)` | `private.reveal_case_service(uuid)` — Phase 19.14 |

### 5B — V2 upload functions: keep state='draft', fix table/column/path only

**Critical:** State check stays `'draft'`. In V4, photo upload happens while case is in `draft` state. Photo approval moves `draft → ready`. Poster launches `ready → launched`. Changing state check to `'ready'` would be circular.

Changes to `public.reserve_upload_session(uuid, uuid, text, text, bigint, timestamptz)`:
- `SELECT ... FROM public.challenges` → `SELECT ... FROM public.cases`
- `challenge_id` column → `case_id`
- Storage path prefix `'challenges/'` → `'cases/'`
- State check: unchanged (`state != 'draft'`)

Changes to `public.finalize_upload_session(uuid, text)`:
- All `public.challenges` → `public.cases`
- All `challenge_id` → `case_id`
- State check: unchanged (`state != 'draft'`)

### 5C — V2 trigger functions: fix state transition names

`private.check_activation_no_active_upload()` and `private.check_activation_media_ready()`:
- Change `OLD.state = 'draft' AND NEW.state = 'active'` to `OLD.state = 'ready' AND NEW.state = 'launched'`
- Column reference `WHERE challenge_id = NEW.id` should already be `case_id` after Phase 2 rename — verify and keep

### 5D — V2 triggers: drop and recreate on public.cases

| Old name | New name | Fires on |
|---|---|---|
| `challenge_v2_no_active_upload_on_activate` | `case_v4_no_active_upload_on_launch` | BEFORE UPDATE, ready → launched |
| `challenge_v2_media_ready_on_activate` | `case_v4_media_ready_on_launch` | BEFORE UPDATE, ready → launched |

### 5E — V2 index: rename
`upload_sessions_one_active_per_challenge` → `upload_sessions_one_active_per_case` (`ALTER INDEX`)

### 5F — V3 function inventory — CONFIRMED from committed V3 source (tag v0.3.0-ugc-safety-moderation)

All previously UNKNOWN and PROVISIONAL entries are now resolved. Confirmed from direct inspection of `V3__ugc_safety_moderation.sql` SHA `1e394903…`.

**Previously unknown — now confirmed:**

| Object | Exact Signature | Owner | Caller | Challenge Refs? | V4 Disposition |
|---|---|---|---|---|---|
| `public.block_user` | `(p_blocked_id uuid) → void` | forkensics_executor | authenticated | None | Keep unchanged |
| `public.unblock_user` | `(p_blocked_id uuid) → void` | forkensics_executor | authenticated | None | Keep unchanged |
| `public.suspend_user` | `(p_profile_id uuid, p_moderator_id uuid, p_reason text) → void` | forkensics_executor | service_role | None | Keep unchanged |
| `public.reinstate_user` | `(p_profile_id uuid, p_moderator_id uuid, p_reason text) → void` | forkensics_executor | service_role | None | Keep unchanged |
| `public.check_text_content` | `(p_text text) → boolean` STABLE | forkensics_executor | service_role | None | Keep unchanged |
| `public.get_report_for_review` | `(p_report_id uuid) → TABLE(...)` STABLE | forkensics_executor | service_role | None (reads comments.text and clues.text; those columns survive V4) | Keep unchanged |
| `public.get_poster_media_status` | `(p_media_object_id uuid, p_uploader_id uuid) → TABLE(status text, rejection_message text)` STABLE | forkensics_executor | service_role | None | Keep unchanged |
| `public.claim_moderation_media_cleanup` | `(p_batch_size int DEFAULT 10) → TABLE(media_object_id uuid, storage_key text, status text)` | forkensics_executor | service_role | **YES — line 1768: `FROM public.challenges c`** | **Blocker 12 — Phase 20B.9** |
| `public.mark_moderation_media_cleaned` | `(p_media_object_id uuid) → void` | forkensics_executor | service_role | None | Keep unchanged |
| `private.cleanup_expired_evidence` | `() → void` | forkensics_executor | service_role | None | Keep unchanged |

**Previously PROVISIONAL confirmed disposition:**

| Object | Disposition |
|---|---|
| `public.action_report(uuid, uuid, uuid, text)` | **Keep unchanged — confirmed no challenge refs.** Reads `moderation_actions` and `content_reports` only. |
| `public.dismiss_report(uuid, uuid, text)` | **Keep unchanged — confirmed no challenge refs.** Reads `content_reports`, inserts to `moderation_actions` and `moderation_action_reports`. |

**All V3 function dispositions — complete confirmed list:**

| Object | Disposition | Notes |
|---|---|---|
| `private.check_text_content_trigger()` | Recreate Phase 20B.1 + **Blocker 10 fix** | Table-name strings must be updated for V4 renames |
| `public.restrict_comment_updates()` | Recreate after Phase 2 + **Blocker 11 fix** | `challenge_id` column ref → `case_id` |
| `public.apply_correction(uuid, text, text, text, uuid, text)` | Recreate Phase 20B.2 — needs Blocker 6A fix | V3 already has correct normalize_answer calls; port must preserve them |
| `private.prepare_account_deletion(uuid)` | Recreate Phase 20B.3 — needs Blocker 7B–7D fixes | |
| `public.remove_content(text, uuid, uuid, uuid, text)` | Recreate Phase 20B.4 — full V3 source-level port (Blocker 8) | V3 uses WITH locked AS subquery correctly (no array_agg FOR UPDATE bug) |
| `public.remove_media(uuid, uuid, uuid, text)` | Recreate Phase 20B.5 — full V3 source-level port (Blocker 8) + Bug 8B | V3 does NOT set moderator_removed_at on cases UPDATE (Bug 8B) — add it in port |
| `public.get_moderation_queue()` | Recreate Phase 20B.6 — update `public.challenges` → `public.cases` | V3 source references `public.challenges c` and `c.id` as challenge_id |
| `public.get_pending_review_media(uuid)` | Recreate Phase 20B.7 — update `public.challenges` → `public.cases` | V3 joins `public.challenges c` |
| `public.get_reported_media(uuid)` | Recreate Phase 20B.8 — update `public.challenges` → `public.cases` | V3 joins `public.challenges c` in both UNION branches |
| `public.claim_moderation_media_cleanup(int)` | Recreate Phase 20B.9 — update `public.challenges` → `public.cases` | **New phase (Blocker 12)** |
| `public.get_my_reports()` | Keep unchanged | No challenge refs |
| `public.report_content(text, uuid, text, text)` | Recreate Phase 19.0C — full Blocker 4 rewrite | V3 references `public.challenges`, `challenge_id` in comments/clues, `private.is_challenge_revealed` |
| `public.approve_photo(uuid, uuid, text)` | Recreate Phase 19.0D ✓ | No challenge refs |
| `public.reject_photo(uuid, uuid, text)` | Recreate Phase 19.0E ✓ | No challenge refs |
| `public.get_media_serve_authorization(uuid, uuid)` | Recreate Phase 19.0B — update `public.challenges` → `public.cases`, `can_view_challenge` → `can_view_case` | V3 joins `public.challenges c` |
| `public.action_report(uuid, uuid, uuid, text)` | Keep unchanged ✓ | Confirmed no challenge refs |
| `public.dismiss_report(uuid, uuid, text)` | Keep unchanged ✓ | Confirmed no challenge refs |
| `public.block_user(uuid)` | Keep unchanged ✓ | No challenge refs |
| `public.unblock_user(uuid)` | Keep unchanged ✓ | No challenge refs |
| `public.suspend_user(uuid, uuid, text)` | Keep unchanged ✓ | No challenge refs |
| `public.reinstate_user(uuid, uuid, text)` | Keep unchanged ✓ | No challenge refs |
| `public.check_text_content(text)` | Keep unchanged ✓ | No challenge refs |
| `public.get_report_for_review(uuid)` | Keep unchanged ✓ | No challenge refs |
| `public.get_poster_media_status(uuid, uuid)` | Keep unchanged ✓ | No challenge refs |
| `public.mark_moderation_media_cleaned(uuid)` | Keep unchanged ✓ | No challenge refs |
| `private.cleanup_expired_evidence()` | Keep unchanged ✓ | No challenge refs |
| `private.can_view_challenge(uuid)` | Drop Phase 14 — replaced by `private.can_view_case(uuid)` | V3: queries `public.challenges`, `eligible_participants.challenge_id` |
| `private.can_viewer_access_challenge(uuid, uuid)` | Drop Phase 14 — replaced by `private.can_viewer_access_case(uuid, uuid)` | V3: queries `public.challenges`, `eligible_participants.challenge_id` |
| `private.has_block_with(uuid)` | Keep unchanged — no table rename exposure | Queries `public.user_blocks` only |
| `private.has_block_with_poster(uuid)` | Recreate Phase 14 — update `public.challenges` → `public.cases` | V3: queries `public.challenges c WHERE c.id = p_challenge_id` |
| `private.enforce_record_immutability()` | Keep unchanged ✓ | No challenge refs; fires on moderation_actions, moderation_action_reports, group_ownership_history |
| `private.force_removal_fields_null()` | Keep unchanged — trigger follows table rename | Fires on INSERT to challenges/comments/clues; after rename fires on cases/comments/clues; function body has no table-name strings |
| `private.restrict_moderation_field_updates()` | Keep unchanged — trigger follows table rename | Fires on UPDATE to challenges/clues; after rename fires on cases/clues; SECURITY INVOKER; no table-name strings |
| `public.handle_new_user()` | Keep unchanged ✓ | V3 updated to insert into profile_suspensions; no challenge refs |
| `public.activate_challenge(uuid)` | DROP Phase 13A Step 3 ✓ | V3 updated with suspension guard + eligible_participants snapshot; replaced by launch_case |
| `public.create_group(text)` | Keep unchanged ✓ | V3 added suspension guard; no challenge refs |
| `public.create_group_invite(uuid)` | Keep unchanged ✓ | V3 added suspension guard; no challenge refs |
| `public.redeem_group_invite(text)` | Keep unchanged ✓ | V3 added suspension guard; no challenge refs |
| `public.transfer_group_ownership(uuid, uuid)` | Keep unchanged ✓ | V3 rewritten with group_ownership_history audit; no challenge refs |

---

## Blocker 6 — Canonical normalization and is_first_correct_for_player

### Bug 6A — canonical answer not normalized (both do_reveal_impl_v3 and apply_correction)

`do_reveal_impl_v3` compares `v_norm_dish = v_secrets.canonical_dish` without normalizing the stored value. Same omission in `apply_correction` Phase 20B.2 where `v_norm_canonical_dish := v_secrets.canonical_dish`.

**Fix (both functions):** Before the scoring loop:
```
v_norm_canonical_dish       := private.normalize_answer(v_secrets.canonical_dish);
v_norm_canonical_restaurant := private.normalize_answer(v_secrets.canonical_restaurant);
```

### Bug 6B — is_first_correct_for_player uses global semantics

`do_reveal_impl_v3` marks only the globally-first correct player. V1 semantics: per-player (true whenever this player answers correctly). Since `UNIQUE(case_id, player_id, race)` on `guess_attempts` limits each player to one guess per race, `is_first_correct_for_player = j.is_correct`.

**Fix:** Replace the CASE expression with `j.is_correct AS is_first_correct_for_player`.

`apply_correction` Phase 20B.2 uses per-player `tmp_fc` tracking — semantically correct for rescoring. Needs only the Bug 6A fix.

---

## Blocker 7 — Exclusion uniqueness and account deletion

### Bug 7A — constraint name and columns
V1 UNIQUE constraint `(challenge_id, player_id)` auto-named `exclusion_events_challenge_id_player_id_key`. Column renamed to `case_id` in Phase 2; constraint name unchanged. Must change to `UNIQUE(investigation_id, player_id)`.

**Fix — in Phase 10, after investigation_id backfill:**
```sql
ALTER TABLE public.exclusion_events
  DROP CONSTRAINT IF EXISTS exclusion_events_challenge_id_player_id_key;
ALTER TABLE public.exclusion_events
  ADD CONSTRAINT exclusion_events_inv_player_unique UNIQUE (investigation_id, player_id);
```
Must be placed after the backfill UPDATE in Phase 10. Note: PostgreSQL permits multiple NULL values in a unique constraint (NULLs are never considered equal to each other), so applying this constraint in Phase 9 would not itself fail due to NULL `investigation_id` values. Phase 10 is still the correct location because the constraint must be applied only after all rows have their `investigation_id` backfilled and validated — the constraint should enforce a meaningful invariant, not silently allow unconstrained NULLs.

### Bug 7B — exclusion loop includes revealed cases
`prepare_account_deletion` loops `i.status = 'active'` without filtering by case state. The `enforce_exclusion_rules` trigger rejects `account_deleted` exclusions unless `case.state IN ('launched', 'locked')`.

**Fix:** Join `public.cases`, add `AND c.state IN ('launched', 'locked')`.

### Bug 7C — historical memberships not updated
Members of revealed/cancelled investigations have no exclusion event inserted — their `eligibility_status` stays unchanged after account deletion.

**Fix:** After the exclusion loop:
```sql
UPDATE public.investigation_members SET eligibility_status = 'account_deleted'
WHERE player_id = p_profile_id;
```

### Bug 7D — ON CONFLICT uses wrong columns
Update `ON CONFLICT (case_id, player_id)` → `ON CONFLICT (investigation_id, player_id)`.

---

## Blocker 8 — remove_content and remove_media

### Classification corrected *(from plan v2: "mechanical fixes only" was wrong)*

The current V4 versions of `remove_content` and `remove_media` do not fully preserve the approved V3 contract. These functions require a **full source-level port from V3**, not mechanical fixes applied to the existing V4 bodies. The port must verify and preserve:

- **Moderator validation:** moderator row exists in `private.moderators` AND the moderator's profile is active in `public.profiles`. **Current V4 only checks existence in `private.moderators` — it does not check `profiles.is_active`.** The V3 port must explicitly add the profile-active check.
- **Exact lock ordering:** confirmed from V4 source — must match V3's ordering precisely
- **Idempotency-pointer validation:** universal check that the action pointer is valid on both the initial and retry execution paths
- **Report-target validation:** on both initial insertion and retry/idempotent paths, all target-existence and target-state checks must run
- **Correct report-resolution linking:** `private.moderation_action_reports` insertions with `ON CONFLICT ON CONSTRAINT moderation_action_reports_one_resolution DO NOTHING` (confirmed present in V4) — verify against V3

The two mechanical defects identified as Blockers 8A and 8B still apply and must be fixed in the port:

**Bug 8A — array_agg with FOR UPDATE is invalid:**
Replace all occurrences of `SELECT array_agg(...) ... FOR UPDATE` with:
```sql
WITH locked AS (
  SELECT id FROM public.content_reports WHERE ... ORDER BY id FOR UPDATE
)
SELECT array_agg(id) INTO v_report_ids FROM locked;
```

**Bug 8B — remove_media missing moderator_removed_at:**
The UPDATE on `public.cases` in `remove_media` sets `moderator_removal_action_id` but not `moderator_removed_at`, violating the `cases_removal_consistency` constraint and breaking the idempotency check. Add `moderator_removed_at = clock_timestamp()`.

---

## Blocker 9 — submit_guess concurrent recovery path

### Problem
`EXCEPTION WHEN unique_violation` re-queries by `(case_id, player_id, race)`. A concurrent request with a different idempotency key gets the first request's row and its ID.

### Fix — key-first recovery
```
EXCEPTION WHEN unique_violation THEN
  IF p_idempotency_key IS NOT NULL THEN
    SELECT id, race, dish_guess, restaurant_guess INTO v_existing
    FROM public.guess_attempts
    WHERE case_id = p_case_id AND player_id = v_actor_id
      AND idempotency_key = p_idempotency_key;

    IF FOUND THEN
      IF v_existing.race != p_race THEN
        RAISE EXCEPTION 'FK_CONFLICT: idempotency key used for different race';
      END IF;
      IF p_race = 'what'  AND v_existing.dish_guess IS DISTINCT FROM p_guess_text THEN
        RAISE EXCEPTION 'FK_CONFLICT: idempotency key reused with different guess text';
      END IF;
      IF p_race = 'where' AND v_existing.restaurant_guess IS DISTINCT FROM p_guess_text THEN
        RAISE EXCEPTION 'FK_CONFLICT: idempotency key reused with different guess text';
      END IF;
      RETURN v_existing.id;
    ELSE
      RAISE EXCEPTION 'FK_CONFLICT: player already has a locked guess for race % (concurrent, different key)', p_race;
    END IF;

  ELSE
    IF EXISTS (SELECT 1 FROM public.guess_attempts
               WHERE case_id = p_case_id AND player_id = v_actor_id AND race = p_race)
    THEN RAISE EXCEPTION 'FK_CONFLICT: player already has a locked guess for race %', p_race;
    END IF;
    RAISE;
  END IF;
```

---

## Blocker 10 — check_text_content_trigger table-name strings *(new — discovered Gate 2)*

### Problem
`private.check_text_content_trigger()` contains a fail-closed allowlist that compares `TG_TABLE_NAME` against hardcoded strings:
```sql
OR (TG_TABLE_NAME = 'challenges'               AND v_col = 'public_city_display')
OR (TG_TABLE_NAME = 'challenge_secrets'        AND v_col IN ('display_dish','display_restaurant','story'))
OR (TG_TABLE_NAME = 'challenge_answer_aliases' AND v_col = 'display_value')
```
After V4 Phase 1 renames `challenges → cases` and `challenge_secrets → case_secrets`, and after Phase 2 renames `challenge_answer_aliases → case_answer_aliases`, `TG_TABLE_NAME` returns the new table names. The allowlist check fails for every INSERT/UPDATE on these tables, raising `FK_CONTENT_FILTERED: unauthorized pairing` and blocking all challenge-city, secret-field, and alias-display-value inserts.

### Fix — after Phase 2 (all column renames complete)
`CREATE OR REPLACE FUNCTION private.check_text_content_trigger()` with the three stale table-name strings replaced:
- `'challenges'` → `'cases'`
- `'challenge_secrets'` → `'case_secrets'`
- `'challenge_answer_aliases'` → `'case_answer_aliases'`

All other logic (fail-closed TG_NARGS check, jsonb extraction, blocked-terms match) unchanged.

---

## Blocker 11 — restrict_comment_updates column reference *(new — discovered Gate 2)*

### Problem
`public.restrict_comment_updates()` is a BEFORE UPDATE trigger on `public.comments`. V3 body references `NEW.challenge_id` and `OLD.challenge_id` at two points:
```sql
-- Path 1 (line 336):
AND NEW.challenge_id IS NOT DISTINCT FROM OLD.challenge_id
-- Path 2 (line 351):
AND NEW.challenge_id IS NOT DISTINCT FROM OLD.challenge_id
```
After V4 Phase 2 renames `public.comments.challenge_id → case_id`, PL/pgSQL will raise a runtime error when this trigger fires because `challenge_id` no longer exists on the `comments` row type.

### Fix — after Phase 2
`CREATE OR REPLACE FUNCTION public.restrict_comment_updates()` with both occurrences of `challenge_id` replaced by `case_id`. All other logic (path 1 moderator removal guard, path 2 author soft-delete guard, immutability exception) unchanged.

---

## Blocker 12 — claim_moderation_media_cleanup table reference *(new — discovered Gate 2)*

### Problem
`public.claim_moderation_media_cleanup(p_batch_size int DEFAULT 10)` contains (V3 line 1768):
```sql
AND EXISTS (
  SELECT 1 FROM public.challenges c
  WHERE c.id = cr.target_id AND c.media_object_id = m.id
)
```
After V4 Phase 1 renames `public.challenges → public.cases`, this reference becomes invalid.

### Fix — Phase 20B.9 (new phase, after Phase 1)
`CREATE OR REPLACE FUNCTION public.claim_moderation_media_cleanup(p_batch_size int DEFAULT 10)` with `public.challenges c` replaced by `public.cases c`. All other logic (lease acquisition, batch ordering, FOR UPDATE SKIP LOCKED, RETURNING clause) unchanged.

---

## Complete Object Disposition Table

### V1 Private Functions

| Object | Disposition | Notes |
|---|---|---|
| `private.auth_uid()` | Keep unchanged | No stale refs |
| `private.normalize_answer(text)` | Keep unchanged | No stale refs |
| `private.is_group_member(uuid)` | Keep unchanged | No stale refs |
| `private.is_group_member_with(uuid)` | Keep unchanged | No stale refs |
| `private.has_block_with(uuid)` | Keep unchanged | Used by V3 RESTRICTIVE policies |
| `private.is_challenge_group_member(uuid)` | Drop — Phase 14 | Replaced by is_investigation_member |
| `private.is_challenge_poster(uuid)` | Drop — Phase 14 | Replaced by is_case_poster |
| `private.is_challenge_revealed(uuid)` | Drop — Phase 14 | Replaced by is_case_revealed |
| `private.is_eligible_non_excluded(uuid)` | Drop — Phase 14 | Replaced by V4 equivalents |
| `private.caller_has_guessed(uuid)` | Recreated Phase 14 | ✓ |
| `private.has_block_with_poster(uuid)` | Recreated Phase 14 | ✓ |
| `private.can_view_challenge(uuid)` | Drop — Phase 14 | V3: queries public.challenges + eligible_participants.challenge_id; replaced by can_view_case |
| `private.can_viewer_access_challenge(uuid,uuid)` | Drop — Phase 14 | V3: queries public.challenges + eligible_participants.challenge_id; replaced by can_viewer_access_case |
| `private.do_reveal_impl(uuid)` | **DROP — Phase 13A Step 2** | After callers dropped; no CASCADE |
| `private.reveal_challenge_service(uuid)` | **DROP — Phase 13A Step 1** | After wrapper dropped; no CASCADE |
| `private.check_activation_no_active_upload()` | **Recreate — Blocker 5C** | State: ready/launched |
| `private.check_activation_media_ready()` | **Recreate — Blocker 5C** | State: ready/launched |
| `private.check_text_content_trigger()` | **Recreate — Blocker 10** | Table-name strings: challenges/challenge_secrets/challenge_answer_aliases → cases/case_secrets/case_answer_aliases |
| `private.force_removal_fields_null()` | Keep unchanged — follows table rename | No table-name strings; fires on INSERT to cases/comments/clues after rename |
| `private.restrict_moderation_field_updates()` | Keep unchanged — follows table rename | No table-name strings; SECURITY INVOKER; fires on UPDATE to cases/clues after rename |
| `private.enforce_record_immutability()` | Keep unchanged ✓ | Fires on moderation_actions, moderation_action_reports, group_ownership_history |
| `private.prepare_account_deletion(uuid)` | Recreated Phase 20B.3 | Needs Blocker 7B–7D fixes |
| `private.get_storage_keys_for_deletion(uuid)` | Keep unchanged | No stale refs |
| `private.mark_auth_deleted(uuid)` | Keep unchanged | No stale refs |
| `private.mark_storage_cleaned(uuid)` | Keep unchanged | No stale refs |
| `private.record_deletion_failure(uuid, text)` | Keep unchanged | No stale refs |

### V1 Public Functions

| Object | Disposition | Notes |
|---|---|---|
| `public.create_group(text)` | Keep unchanged | |
| `public.transfer_group_ownership(uuid, uuid)` | Keep unchanged | |
| `public.create_group_invite(uuid)` | Keep unchanged | |
| `public.redeem_group_invite(text)` | Keep unchanged | |
| `public.revoke_group_invite(uuid)` | Keep unchanged | |
| `public.soft_delete_comment(uuid)` | Keep unchanged | |
| `public.activate_challenge(uuid)` | **DROP — Phase 13A Step 3** | Authenticated grant revoked first |
| `public.lock_challenge(uuid)` | **DROP — Phase 13A Step 3** | service_role grant revoked first |
| `public.reveal_challenge(uuid)` | **DROP — Phase 13A Step 1** | Authenticated grant revoked first |
| `public.cancel_challenge(uuid, text)` | **DROP — Phase 13A Step 3** | Authenticated grant revoked first |
| `public.apply_correction(uuid, text, text, text, uuid, text)` | Recreated Phase 20B.2 | Needs Blocker 6A fix |
| `public.guard_answer_edits()` | Recreated Phase 19.3 | ✓ |
| `public.guard_alias_edits()` | Recreated Phase 19.5 | ✓ |
| `public.report_content(text, uuid, text, text)` | Recreated Phase 19.0C | Needs full Blocker 4 rewrite |

### V2 Public Functions — all service_role only (confirmed from V2 grant loop)

| Object | Disposition | Notes |
|---|---|---|
| `public.reserve_upload_session(uuid, uuid, text, text, bigint, timestamptz)` | **Recreate — Blocker 5B** | Fix table/col/path; keep state='draft' |
| `public.finalize_upload_session(uuid, text)` | **Recreate — Blocker 5B** | Fix table/col; keep state='draft' |
| `public.reveal_challenge_service_wrapper(uuid)` | **DROP — Phase 13A Step 1** | Callee being dropped; create replacement in Phase 19.14 |
| All other 24 V2 public functions | Keep unchanged | No challenge refs; confirmed from V2 source |

### V2 Private Trigger Functions

| Object | Disposition | Notes |
|---|---|---|
| `private.check_activation_no_active_upload()` | **Recreate — Blocker 5C** | State names: ready/launched |
| `private.check_activation_media_ready()` | **Recreate — Blocker 5C** | State names: ready/launched |

### V2 Triggers

| Object | Disposition | Notes |
|---|---|---|
| `challenge_v2_no_active_upload_on_activate` | **Drop + recreate as `case_v4_no_active_upload_on_launch`** | |
| `challenge_v2_media_ready_on_activate` | **Drop + recreate as `case_v4_media_ready_on_launch`** | |

### V2 Indexes

| Object | Disposition |
|---|---|
| `upload_sessions_one_active_per_challenge` | **Rename → `upload_sessions_one_active_per_case`** |

### V3 Trigger Functions — CONFIRMED

| Object | Disposition | Notes |
|---|---|---|
| `private.check_text_content_trigger()` | **Recreate — Blocker 10** | Table-name strings updated for V4 renames |
| `public.restrict_comment_updates()` | **Recreate — Blocker 11** | `challenge_id` → `case_id` in body |
| `private.force_removal_fields_null()` | Keep unchanged — follows rename | No table-name strings in body |
| `private.restrict_moderation_field_updates()` | Keep unchanged — follows rename | SECURITY INVOKER; no table-name strings |
| `private.enforce_record_immutability()` | Keep unchanged ✓ | No challenge refs |

### V3 Trigger Attachments — CONFIRMED

These V3 triggers follow their tables through V4 renames automatically. No DROP/recreate needed unless the function body is being updated (Blockers 10/11).

| Trigger Name | Table | Event | Function | V4 Action |
|---|---|---|---|---|
| `force_challenge_removal_null` | challenges → cases | BEFORE INSERT | force_removal_fields_null | Follows rename — no action needed |
| `force_comment_removal_null` | comments | BEFORE INSERT | force_removal_fields_null | No action needed |
| `force_clue_removal_null` | clues | BEFORE INSERT | force_removal_fields_null | No action needed |
| `restrict_challenge_removal_fields` | challenges → cases | BEFORE UPDATE | restrict_moderation_field_updates | Follows rename — no action needed |
| `restrict_clue_removal_fields` | clues | BEFORE UPDATE | restrict_moderation_field_updates | No action needed |
| `moderation_actions_immutable` | moderation_actions | BEFORE UPDATE OR DELETE | enforce_record_immutability | No action needed |
| `moderation_action_reports_immutable` | moderation_action_reports | BEFORE UPDATE OR DELETE | enforce_record_immutability | No action needed |
| `group_ownership_history_immutable` | group_ownership_history | BEFORE UPDATE OR DELETE | enforce_record_immutability | No action needed |
| `comment_text_filter` | comments | BEFORE INSERT | check_text_content_trigger('text') | No separate action (function replaced by Blocker 10) |
| `clue_text_filter` | clues | BEFORE INSERT | check_text_content_trigger('text') | No separate action |
| `profile_name_filter` | profiles | BEFORE INSERT OR UPDATE | check_text_content_trigger('display_name') | No separate action |
| `group_name_filter` | groups | BEFORE INSERT OR UPDATE | check_text_content_trigger('name') | No separate action |
| `challenge_city_filter` | challenges → cases | BEFORE INSERT OR UPDATE | check_text_content_trigger('public_city_display') | Follows rename; function fixed by Blocker 10 |
| `secret_dish_filter` | challenge_secrets → case_secrets | BEFORE INSERT OR UPDATE | check_text_content_trigger('display_dish') | Follows rename; function fixed by Blocker 10 |
| `secret_restaurant_filter` | challenge_secrets → case_secrets | BEFORE INSERT OR UPDATE | check_text_content_trigger('display_restaurant') | Follows rename; function fixed by Blocker 10 |
| `secret_story_filter` | challenge_secrets → case_secrets | BEFORE INSERT OR UPDATE | check_text_content_trigger('story') | Follows rename; function fixed by Blocker 10 |
| `alias_display_value_filter` | challenge_answer_aliases → case_answer_aliases | BEFORE INSERT | check_text_content_trigger('display_value') | Follows rename; function fixed by Blocker 10 |
| V1 `comments_restrict_update` trigger | comments | BEFORE UPDATE | restrict_comment_updates() | Function replaced by Blocker 11; trigger attachment unchanged |

### V3 RLS Policies — CONFIRMED

All 33 V3 RLS policies cataloged. Phase 13B drops all policies on: cases, case_secrets, clues, comments, reactions, guess_attempts, eligible_participants, exclusion_events, correction_events, score_runs, guess_judgments, score_events, case_answer_aliases. V3 RESTRICTIVE policies on tables NOT in that drop list require DROP IF EXISTS guards.

| Policy Name | Table | Type | V4 Fate |
|---|---|---|---|
| `suspend_block_insert` | challenges → **cases** | RESTRICTIVE INSERT | Dropped by Phase 13B; V4 Phase 15 recreates as `cases_suspend_block_insert` |
| `suspend_block_update` | challenges → **cases** | RESTRICTIVE UPDATE | Dropped by Phase 13B; V4 Phase 15 recreates |
| `suspend_block_insert` | challenge_secrets → **case_secrets** | RESTRICTIVE INSERT | Dropped by Phase 13B |
| `suspend_block_update` | challenge_secrets → **case_secrets** | RESTRICTIVE UPDATE | Dropped by Phase 13B |
| `suspend_block_insert` | challenge_answer_aliases → **case_answer_aliases** | RESTRICTIVE INSERT | Dropped by Phase 13B |
| `suspend_block_update` | challenge_answer_aliases → **case_answer_aliases** | RESTRICTIVE UPDATE | Dropped by Phase 13B |
| `suspend_block_insert` | **comments** | RESTRICTIVE INSERT | Dropped by Phase 13B |
| `suspend_block_insert` | **clues** | RESTRICTIVE INSERT | Dropped by Phase 13B |
| `suspend_block_insert` | **reactions** | RESTRICTIVE INSERT | Dropped by Phase 13B |
| `suspend_block_insert` | **guess_attempts** | RESTRICTIVE INSERT | Dropped by Phase 13B |
| `suspend_exclusion_insert` | **exclusion_events** | RESTRICTIVE INSERT | Dropped by Phase 13B |
| `enforce_no_block_guess` | **guess_attempts** | RESTRICTIVE INSERT | Dropped by Phase 13B |
| `enforce_no_block_comment` | **comments** | RESTRICTIVE INSERT | Dropped by Phase 13B |
| `enforce_no_block_reaction` | **reactions** | RESTRICTIVE INSERT | Dropped by Phase 13B |
| `hide_blocked_challenges` | challenges → **cases** | RESTRICTIVE SELECT | Dropped by Phase 13B; V4 Phase 15 recreates as `hide_blocked_cases` referencing `eligible_participants.case_id` |
| `block_aware_comment_visibility` | **comments** | RESTRICTIVE SELECT | Dropped by Phase 13B; V4 Phase 15 recreates with `can_view_case(case_id)` |
| `block_aware_reaction_visibility` | **reactions** | RESTRICTIVE SELECT | Dropped by Phase 13B |
| `hide_removed_clues` | **clues** | RESTRICTIVE SELECT | Dropped by Phase 13B |
| `block_aware_visibility` | **clues** | RESTRICTIVE SELECT | Dropped by Phase 13B |
| `block_aware_visibility` | challenge_secrets → **case_secrets** | RESTRICTIVE SELECT | Dropped by Phase 13B |
| `block_aware_visibility` | challenge_answer_aliases → **case_answer_aliases** | RESTRICTIVE SELECT | Dropped by Phase 13B |
| `block_aware_visibility` | **guess_attempts** | RESTRICTIVE SELECT | Dropped by Phase 13B |
| `block_aware_visibility` | **guess_judgments** | RESTRICTIVE SELECT | Dropped by Phase 13B |
| `block_aware_visibility` | **score_runs** | RESTRICTIVE SELECT | Dropped by Phase 13B |
| `block_aware_visibility` | **score_events** | RESTRICTIVE SELECT | Dropped by Phase 13B |
| `block_aware_visibility` | **correction_events** | RESTRICTIVE SELECT | Dropped by Phase 13B |
| `block_aware_visibility` | **eligible_participants** | RESTRICTIVE SELECT | Dropped by Phase 13B |
| `block_aware_visibility` | **exclusion_events** | RESTRICTIVE SELECT | Dropped by Phase 13B |
| `suspend_block_insert` | **group_members** | RESTRICTIVE INSERT | **NOT in Phase 13B** — survives; Phase 15B adds DROP IF EXISTS guard before recreate |
| `suspend_block_update` | **profiles** | RESTRICTIVE UPDATE (`USING (NOT is_suspended)`) | **NOT in Phase 13B** — survives; Phase 15B adds DROP IF EXISTS guard before recreate |
| `suspend_block_insert` | **groups** | RESTRICTIVE INSERT | **NOT in Phase 13B** — survives; Phase 15B adds DROP IF EXISTS guard before recreate |
| `suspend_block_update` | **groups** | RESTRICTIVE UPDATE | **NOT in Phase 13B** — survives; Phase 15B adds DROP IF EXISTS guard before recreate |
| `blocks_select_own` | **user_blocks** | PERMISSIVE SELECT (`blocker_id = private.auth_uid()`) | Not in Phase 13B; user_blocks untouched by V4; policy survives unchanged |

### V3 Functions — CONFIRMED

See Blocker 5F for the complete confirmed inventory from committed V3 source. Summary of V4 actions required:

| Object | V4 Action |
|---|---|
| `private.check_text_content_trigger()` | Recreate (Blocker 10 — table-name strings) |
| `public.restrict_comment_updates()` | Recreate (Blocker 11 — column rename) |
| `public.claim_moderation_media_cleanup(int)` | Recreate Phase 20B.9 (Blocker 12 — table ref) |
| `public.get_moderation_queue()` | Recreate Phase 20B.6 (challenges → cases) |
| `public.get_pending_review_media(uuid)` | Recreate Phase 20B.7 (challenges → cases) |
| `public.get_reported_media(uuid)` | Recreate Phase 20B.8 (challenges → cases) |
| `public.get_media_serve_authorization(uuid, uuid)` | Recreate Phase 19.0B (challenges → cases + helper rename) |
| `public.report_content(text, uuid, text, text)` | Recreate Phase 19.0C (full Blocker 4 rewrite) |
| `public.remove_content(text, uuid, uuid, uuid, text)` | Recreate Phase 20B.4 (full V3 port, Blocker 8) |
| `public.remove_media(uuid, uuid, uuid, text)` | Recreate Phase 20B.5 (full V3 port + Bug 8B) |
| `public.apply_correction(uuid, text, text, text, uuid, text)` | Recreate Phase 20B.2 (Blocker 6A — preserve V3 normalize_answer) |
| `private.has_block_with_poster(uuid)` | Recreate Phase 14 (challenges → cases) |
| `private.can_view_challenge(uuid)` | Drop Phase 14 → replaced by `can_view_case` |
| `private.can_viewer_access_challenge(uuid, uuid)` | Drop Phase 14 → replaced by `can_viewer_access_case` |
| All other V3 functions (18 objects) | Keep unchanged — no challenge/column refs |

### Constraints

| Object | Disposition | Phase |
|---|---|---|
| `exclusion_events_challenge_id_player_id_key` | Drop + replace with `exclusion_events_inv_player_unique UNIQUE(investigation_id, player_id)` | Phase 10 (after backfill) |

### RLS Policies — Changes Required

| Table | Policy | Action | Phase |
|---|---|---|---|
| `public.cases` | `cases_insert` permissive INSERT | Add | 15 |
| `public.cases` | `cases_update_poster` permissive UPDATE (state='draft') | Add | 15 |
| `public.case_secrets` | `case_secrets_insert` permissive INSERT | Add | 15 |
| `public.case_secrets` | `case_secrets_update_poster` permissive UPDATE | Add | 15 |
| `public.case_secrets` | `case_secrets_member_revealed_view` permissive SELECT (is_case_revealed + is_case_member) | Add | 15 |
| `public.clues` | `clues_insert_poster` permissive INSERT (state='launched') | Add | 15 |
| `public.correction_events` | `correction_events_member_view` permissive SELECT (is_case_revealed + is_case_member) | Add | 15 |
| `public.correction_events` | `correction_events_poster_view` permissive SELECT (is_case_poster) | Add | 15 |
| `public.comments` | `comments_member_view` — add `deleted_at IS NULL` to USING | Fix | 15 |
| `public.comments` | `comments_poster_view` — add `deleted_at IS NULL` to USING | Fix | 15 |
| `public.comments` | `comments_member_insert` — add `deleted_at IS NULL` + `onboarding_complete = true` to WITH CHECK | Fix | 15 |
| `public.comments` | `comments_poster_insert` — add `deleted_at IS NULL` + `onboarding_complete = true` to WITH CHECK | Fix | 15 |
| `public.groups` | `suspend_block_insert` — add DROP IF EXISTS guard | Fix | 15B |
| `public.groups` | `suspend_block_update` — add DROP IF EXISTS guard | Fix | 15B |
| `public.group_members` | `suspend_block_insert` — add DROP IF EXISTS guard | Fix | 15B |
| `public.profiles` | `suspend_block_update` — add DROP IF EXISTS guard | Fix | 15B |

---

## Explicit Allowlist — Callable Functions After V4

### Callable by `authenticated` — confirmed

```
public.create_group(text)
public.transfer_group_ownership(uuid, uuid)
public.create_group_invite(uuid)
public.redeem_group_invite(text)
public.revoke_group_invite(uuid)
public.soft_delete_comment(uuid)
public.reveal_case(uuid)
public.cancel_case(uuid, text)
public.cancel_investigation(uuid, text)
public.apply_correction(uuid, text, text, text, uuid, text)
public.launch_case(uuid, uuid, uuid[], integer)
public.submit_guess(uuid, uuid, text, text, text, timestamptz)
public.report_content(text, uuid, text, text)
public.get_my_reports()
```

### Callable by `service_role` only — confirmed from V1 source

```
public.lock_case(uuid)
public.reveal_case_service_wrapper(uuid)
public.prepare_account_deletion_wrapper(uuid)
public.get_deletion_storage_keys(uuid)
public.record_deletion_failure_wrapper(uuid, text)
public.mark_auth_deleted_wrapper(uuid)
public.mark_storage_cleaned_wrapper(uuid)
```

### Callable by `service_role` only — confirmed from V2 grant loop

```
public.reserve_upload_session(uuid, uuid, text, text, bigint, timestamptz)
public.activate_upload_session(uuid, timestamptz)
public.resolve_upload_session(text, uuid)
public.advance_upload_session_processing(uuid, uuid, interval)
public.check_upload_session_lease(uuid)
public.advance_upload_session_sanitized(uuid)
public.finalize_upload_session(uuid, text)
public.fail_upload_session(uuid, text)
public.quiesce_upload_sessions_for_deletion(uuid)
public.get_upload_capability_expiry(uuid)
public.get_all_upload_session_paths_for_deletion(uuid)
public.claim_cleanup_sessions(text, interval)
public.mark_session_cleaned(uuid, uuid)
public.mark_original_path_post_expiry_cleaned(uuid)
public.get_complete_sessions_pending_expiry_cleanup()
public.get_superseded_media_to_clean()
public.mark_superseded_media_cleaned(uuid)
public.get_media_storage_key(uuid)
public.claim_deletion_recovery_records(text, interval, interval)
public.complete_deletion_recovery(uuid, uuid, text)
public.fail_deletion_recovery(uuid, uuid, text)
```

### Callable by `authenticated` — confirmed from V3 source

```
public.block_user(uuid)
public.unblock_user(uuid)
```

### Callable by `service_role` only — confirmed from V3 source (complete list)

```
public.remove_content(text, uuid, uuid, uuid, text)
public.remove_media(uuid, uuid, uuid, text)
public.approve_photo(uuid, uuid, text)
public.reject_photo(uuid, uuid, text)
public.get_media_serve_authorization(uuid, uuid)
public.get_moderation_queue()
public.get_pending_review_media(uuid)
public.get_reported_media(uuid)
public.action_report(uuid, uuid, uuid, text)
public.dismiss_report(uuid, uuid, text)
public.suspend_user(uuid, uuid, text)
public.reinstate_user(uuid, uuid, text)
public.check_text_content(text)
public.get_report_for_review(uuid)
public.get_poster_media_status(uuid, uuid)
public.claim_moderation_media_cleanup(int)    — default p_batch_size = 10
public.mark_moderation_media_cleaned(uuid)
private.cleanup_expired_evidence()            — private schema; not exposed through PostgREST
```

### Explicitly not callable — dropped or schema-restricted

```
public.activate_challenge(uuid)               — DROPPED Phase 13A
public.lock_challenge(uuid)                   — DROPPED Phase 13A
public.reveal_challenge(uuid)                 — DROPPED Phase 13A
public.cancel_challenge(uuid, text)           — DROPPED Phase 13A
public.reveal_challenge_service_wrapper(uuid) — DROPPED Phase 13A
```

**Note on the private schema:** The `private` schema is not exposed through PostgREST and therefore cannot be called by API clients. However, authenticated and trusted roles do receive explicit `EXECUTE` grants on selected private helper functions (e.g., `private.auth_uid()`, `private.normalize_answer()`, and all V4 RLS helpers) per V1 and V4 grant sections. "Not callable via API" and "no EXECUTE grants" are not the same thing.

---

## Phase Change Summary

| Phase | Action |
|---|---|
| New Phase 13A | REVOKE + DROP 6 V1 functions + 1 V2 wrapper in dependency-safe order; no CASCADE |
| Phase 13C | Add `GRANT CREATE ON SCHEMA` to forkensics roles |
| Phase 15 | Add 8 new policies; fix 4 comment policies (deleted_at guards + onboarding-complete) |
| Phase 15B | Add DROP IF EXISTS guards before 4 duplicate RESTRICTIVE policy CREATEs |
| After Phase 2 — Blocker 11 | `CREATE OR REPLACE` restrict_comment_updates: `challenge_id → case_id` |
| After Phase 2 — Blocker 10 | `CREATE OR REPLACE` check_text_content_trigger: table-name strings updated for renames |
| Phase 19.0B | Recreate get_media_serve_authorization: `public.challenges → public.cases`, `can_view_challenge → can_view_case` |
| Phase 19.0C | Full rewrite of report_content — fix 6 bugs; preserve full V3 behavioral contract |
| Phase 19.12 | Fix canonical normalization + is_first_correct_for_player in do_reveal_impl_v3 |
| Phase 19.14 | CREATE reveal_case_service_wrapper only (DROP moved to Phase 13A) |
| Phase 19.17 | Restructure unique_violation recovery in submit_guess |
| Phase 20B.2 | Full V3 source-level port of apply_correction + Blocker 6A normalization fix |
| Phase 20B.3 | Fix prepare_account_deletion: case state filter + ON CONFLICT + bulk UPDATE |
| Phase 20B.4 | Full V3 source-level port of remove_content; fix Bugs 8A (WITH locked subquery) |
| Phase 20B.5 | Full V3 source-level port of remove_media; fix Bugs 8A + 8B (add moderator_removed_at) |
| Phase 20B.6 | Recreate get_moderation_queue: `public.challenges → public.cases` |
| Phase 20B.7 | Recreate get_pending_review_media: `public.challenges → public.cases` |
| Phase 20B.8 | Recreate get_reported_media: `public.challenges → public.cases` (both UNION branches) |
| **Phase 20B.9 — new** | Recreate claim_moderation_media_cleanup: `public.challenges → public.cases` (Blocker 12) |
| Phase 20C | Add `REVOKE CREATE ON SCHEMA` from forkensics roles |
| Phase 10 | After backfill: drop old exclusion unique constraint; add UNIQUE(investigation_id, player_id) |
| Blocker 5C/5D | Recreate V2 trigger functions; drop + recreate V2 triggers; rename V2 index |

---

## Prerequisites Before V4 SQL Can Be Written

**Gate 1 — Implement V3 ✅ COMPLETE**  
`V3__ugc_safety_moderation.sql` written, tested (V3 acceptance + T5 lock order + T7 concurrency harnesses all passing), run as part of the V1 → V2 → V3 chain, committed (SHA `1e394903…`), tagged `v0.3.0-ugc-safety-moderation`, and pushed to `github.com/Billmags/Forkensics`.

**Gate 2 — Complete V4 plan inventory from V3 source ✅ COMPLETE**  
All PROVISIONAL entries replaced with confirmed dispositions from direct inspection of committed V3 SQL. Three new blockers discovered and documented (Blockers 10, 11, 12). All 10 previously unknown function signatures and caller roles confirmed. Action_report and dismiss_report confirmed no challenge refs.

**Gate 3 — Final V4 coding authorization ⬜ REQUIRED**  
Three-party sign-off (Bill + Claude + Codex) on this completed plan before V4 SQL may be written.

---

*Plan formally approved by Codex (Plan v5). Gate 2 inventory complete (Plan v6). V4 SQL implementation requires Gate 3 three-party authorization.*
