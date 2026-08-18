# Step 24.1 Proposal — Rev 6 — UGC Safety and Moderation Contracts

**Status:** Pending review (Claude → Codex/GPT → Bill approval)
**Governance gate:** Bill must type `APPROVED: Step 24.1 — UGC Safety and Moderation Contracts` before any moderation schema or functions are written as executable SQL or applied to any environment.
**Changes from Rev 5:**
- Blocker 1: Global lock order reversed to eliminate deadlock: content target → all matching pending reports in UUID order → media. `report_content` locks and rechecks target before inserting.
- Blocker 2: `private.moderation_action_reports` join table added; every bulk-resolved report receives one row; `action_report` requires same-subject prior substantive action.
- Blocker 3: Challenge-removal idempotency corrected: if already removed, find existing action row, link newly discovered pending reports to it, no duplicate action/evidence.
- Blocker 4: `redeem_group_invite()` receives explicit internal suspension guard; `transfer_group_ownership` conditions documented.
- Blocker 5: SHA-256 parameter declared `text` with internal format validation; no placeholder backfill; single controlled migration plan.

---

## Section 1 — Confirmed Decisions (cumulative)

1–15: All prior decisions confirmed unchanged.
16. Global lock order for challenge/media operations: **content target → pending reports (UUID order) → media**.
17. `dismiss_report` acquires only the report lock (no content lock).
18. `report_content` locks and rechecks target row before inserting.
19. `FK_ALREADY_REMOVED` not raised on idempotent challenge removal; existing action is reused for new pending reports.
20. `redeem_group_invite` requires internal suspension guard.
21. `transfer_group_ownership`: permitted for suspended sender; recipient must be active, onboarded, and not suspended; transfer is audited.
22. SHA-256 parameter declared as `text`; format validated inside function; no placeholder backfill.

---

## Section 2 — Schema Additions (Rev 6)

### 2.1 `private.moderation_action_reports`

Immutable join table linking every `moderation_actions` row to every `content_reports` row it resolved. One row per (action, report) pair.

```sql
CREATE TABLE IF NOT EXISTS private.moderation_action_reports (
  moderation_action_id  uuid NOT NULL
                        REFERENCES public.moderation_actions(id) ON DELETE RESTRICT,
  report_id             uuid NOT NULL
                        REFERENCES public.content_reports(id) ON DELETE RESTRICT,
  created_at            timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY (moderation_action_id, report_id)
);

CREATE INDEX ON private.moderation_action_reports (report_id);
```

Immutability: a BEFORE UPDATE OR DELETE trigger raises an exception (same pattern as `moderation_actions`).

### 2.2 `public.moderation_actions` — `prior_action_id` column

```sql
ALTER TABLE public.moderation_actions
  ADD COLUMN IF NOT EXISTS prior_action_id uuid
    REFERENCES public.moderation_actions(id) ON DELETE RESTRICT;
```

Used by standalone `action_report` to record the substantive prior action that motivated closing this report. NULL for primary removal and moderation actions.

### 2.3 `private.media_storage_keys` — SHA-256 column (one controlled migration)

```sql
-- Step 1: add column with format constraint (nullable)
ALTER TABLE private.media_storage_keys
  ADD COLUMN IF NOT EXISTS sha256_hash text
    CONSTRAINT msk_sha256_format
      CHECK (sha256_hash ~ '^[0-9a-f]{64}$');

-- Step 2: before adding NOT NULL, verify zero incompatible rows:
--   SELECT count(*) FROM private.media_storage_keys WHERE sha256_hash IS NULL;
--   Must be zero. Dispose of any pre-V2 development fixtures before this step.

-- Step 3 (second V2 migration file, after verification):
ALTER TABLE private.media_storage_keys
  ALTER COLUMN sha256_hash SET NOT NULL;
```

No placeholder or synthetic hashes. Pre-V2 development media rows must be deleted and re-processed, or environments must be confirmed to contain no media rows.

---

## Section 3 — Global Lock Order (Corrected)

### 3.1 Deadlock analysis

The Rev 5 order (report → challenge → media) caused a cycle:
- Moderator 1 holds Report A, waits for challenge.
- Moderator 2 holds Report B, waits for challenge.
- Both unblock on the challenge but then Moderator 1 waits for Report B during bulk update.
- Deadlock.

### 3.2 Corrected order

For all functions touching challenge and/or media:

**content target → all matching pending reports (ascending UUID) → media**

`FOR UPDATE SKIP LOCKED` is NOT used for reports — every matching pending report must be claimed in the same transaction. `FOR UPDATE` with `ORDER BY id` ensures consistent acquisition order across all concurrent transactions, preventing cycles.

`dismiss_report` acquires **only** the report lock (no content lock ever), so it cannot participate in a cycle with the remove functions.

### 3.3 `remove_content('challenge')` — revised sequence

```
1.  Validate moderator identity.
2.  Lock challenge:
      SELECT id, state, media_object_id, moderator_removed_at
      FROM public.challenges WHERE id = p_target_id FOR UPDATE.
3.  Validate challenge state (per Section 7 matrix).
    If moderator_removed_at IS NOT NULL → go to idempotency path (Section 4).
4.  Resolve v_media_object_id from locked challenge row.
5.  Lock all matching pending reports in UUID order:
      SELECT id FROM public.content_reports
      WHERE status = 'pending'
        AND (
          (target_type = 'challenge' AND target_id = p_target_id)
          OR (target_type = 'media_object' AND target_id = v_media_object_id)
        )
      ORDER BY id FOR UPDATE.
    Store the locked report IDs in v_report_ids[].
6.  Lock media:
      SELECT id, status FROM public.media_objects
      WHERE id = v_media_object_id FOR UPDATE.
    Validate media state (per Section 7 matrix).
7.  Read sha256_hash from private.media_storage_keys WHERE media_object_id = v_media_object_id.
    If sha256_hash IS NULL → raise FK_MEDIA_METADATA_INCOMPLETE; abort.
8.  INSERT moderation_actions (action_type = 'content_removed', target_type = 'challenge',
      target_id = p_target_id, ...) RETURNING id → v_action_id.
9.  INSERT private.moderation_action_reports: one row per id in v_report_ids[].
10. INSERT private.moderation_evidence (media_metadata, key, sha256).
11. UPDATE public.challenges (moderator_removed_at, state per matrix).
12. UPDATE public.media_objects (status = 'removed', moderated_at = clock_timestamp()).
13. UPDATE public.content_reports SET status = 'actioned', reviewed_at = clock_timestamp(),
      reviewed_by = p_moderator_id WHERE id = ANY(v_report_ids).
```

### 3.4 `remove_content('comment')` — revised sequence

```
1.  Validate moderator.
2.  Lock comment:
      SELECT id, text, moderator_removed_at, author_id, challenge_id, posted_at, deleted_at
      FROM public.comments WHERE id = p_target_id FOR UPDATE.
    If moderator_removed_at IS NOT NULL → idempotency path (Section 4).
3.  Lock all matching pending reports:
      SELECT id FROM public.content_reports
      WHERE target_type = 'comment' AND target_id = p_target_id AND status = 'pending'
      ORDER BY id FOR UPDATE → v_report_ids[].
4.  INSERT moderation_actions RETURNING id → v_action_id.
5.  INSERT private.moderation_action_reports (one per v_report_ids[]).
6.  INSERT private.moderation_evidence (comment_text = OLD comment text).
7.  UPDATE comments: text = '[removed by moderator]', moderator_removed_at = clock_timestamp().
8.  UPDATE content_reports SET status = 'actioned' WHERE id = ANY(v_report_ids).
```

### 3.5 `remove_content('clue')` — revised sequence

Same pattern as comment. Lock clue → lock reports → action.

### 3.6 `remove_media(p_media_object_id)` — revised sequence

```
1.  Validate moderator.
2.  Resolve v_challenge_id (provisional read; re-validated after lock).
3.  Lock challenge:
      SELECT id, state, media_object_id, moderator_removed_at
      FROM public.challenges WHERE id = v_challenge_id FOR UPDATE.
4.  Re-validate: challenges.media_object_id = p_media_object_id.
    If mismatch → raise FK_LINKAGE_CHANGED; abort.
5.  Lock all matching pending reports in UUID order:
      SELECT id FROM public.content_reports
      WHERE status = 'pending'
        AND (
          (target_type = 'media_object' AND target_id = p_media_object_id)
          OR (target_type = 'challenge' AND category = 'inappropriate_image'
              AND target_id = v_challenge_id)
        )
      ORDER BY id FOR UPDATE → v_report_ids[].
6.  Lock media:
      SELECT id, status FROM public.media_objects
      WHERE id = p_media_object_id FOR UPDATE.
    Verify: status = 'ready'. Otherwise raise FK_WRONG_STATE; abort.
7.  Read sha256_hash. Raise FK_MEDIA_METADATA_INCOMPLETE if NULL.
8.  INSERT moderation_actions RETURNING id → v_action_id.
9.  INSERT private.moderation_action_reports (one per v_report_ids[]).
10. INSERT private.moderation_evidence.
11. UPDATE media_objects (status = 'removed', moderated_at).
12. UPDATE challenges per state matrix.
13. UPDATE content_reports SET status = 'actioned' WHERE id = ANY(v_report_ids).
```

### 3.7 `dismiss_report` — unchanged lock scope

```
1. Validate moderator.
2. Lock report only:
   SELECT id, status FROM content_reports WHERE id = p_report_id FOR UPDATE.
   Verify status = 'pending'.
3. INSERT moderation_actions (action_type = 'report_dismissed') RETURNING id → v_action_id.
4. INSERT private.moderation_action_reports (one row: v_action_id, p_report_id).
5. UPDATE content_reports SET status = 'dismissed', reviewed_at, reviewed_by.
```

No content lock. Cannot deadlock with remove functions.

### 3.8 `report_content` — lock and recheck target before inserting

For targets that can be content-removed (challenge, comment, clue, media_object), lock the target row and recheck its removal state before inserting the report. This prevents stranded pending reports created just as content removal is committed.

```
For target_type = 'challenge':
  SELECT id, moderator_removed_at, posted_at, state
  FROM public.challenges WHERE id = p_target_id FOR UPDATE.
  If NOT private.can_view_challenge(p_target_id) → FK_NOT_FOUND.
  If moderator_removed_at IS NOT NULL → FK_NOT_FOUND.

For target_type = 'comment':
  SELECT id, moderator_removed_at, challenge_id
  FROM public.comments WHERE id = p_target_id FOR UPDATE.
  If moderator_removed_at IS NOT NULL → FK_NOT_FOUND.
  Recheck Table Talk visibility predicate.

For target_type = 'clue':
  SELECT id, moderator_removed_at, challenge_id
  FROM public.clues WHERE id = p_target_id FOR UPDATE.
  If moderator_removed_at IS NOT NULL → FK_NOT_FOUND.

For target_type = 'media_object':
  SELECT id, status FROM public.media_objects WHERE id = p_target_id FOR UPDATE.
  If status != 'ready' → FK_NOT_FOUND.

For target_type = 'profile':
  No content-removal risk. Verify active status only (no lock needed).
```

After lock-and-recheck: insert the report, set `has_pending_report` logic via subquery (no boolean column). Release locks at commit.

Lock order for `report_content`: only the single target row. It never acquires a challenge lock AND a report lock simultaneously, so it cannot cycle with dismiss_report (which takes only a report lock) or with remove functions (which take challenge first).

---

## Section 4 — Challenge-Removal Idempotency

If `moderator_removed_at IS NOT NULL` is detected after locking the challenge (step 3 of Section 3.3):

```
Idempotency path:
1. Find the existing primary removal action:
   SELECT id FROM public.moderation_actions
   WHERE action_type = 'content_removed'
     AND target_type = 'challenge'
     AND target_id = p_target_id
   ORDER BY created_at ASC LIMIT 1 → v_existing_action_id.
2. Lock any remaining matching pending reports:
   (same report query as step 5, ORDER BY id FOR UPDATE)
   → v_new_report_ids[].
3. INSERT private.moderation_action_reports for each id in v_new_report_ids[]
   using v_existing_action_id (not a new action row).
4. UPDATE content_reports SET status = 'actioned', reviewed_at, reviewed_by
   WHERE id = ANY(v_new_report_ids).
5. Return successfully. No new moderation_actions or moderation_evidence row is created.
```

This allows a second moderator who arrives via a different report to resolve their report without creating duplicate audit rows.

`remove_media` against non-`ready` media raises `FK_WRONG_STATE` (no idempotency path — only `ready` media is a valid entry point).

---

## Section 5 — `action_report` (Revised Contract)

```
public.action_report(
  p_report_id       uuid,
  p_moderator_id    uuid,
  p_prior_action_id uuid,   -- references an existing substantive moderation_actions row
  p_reason          text
) → void
```

1. Validate moderator identity.
2. Verify `p_prior_action_id`:
   - Row exists in `moderation_actions`.
   - `action_type` is substantive: must NOT be `'report_dismissed'` or `'report_actioned'`. Must NOT be an approval-only action for unrelated content.
   - `target_type` and `target_id` match the report's `target_type` and `target_id` (same subject).
3. Lock report `FOR UPDATE`. Re-check `status = 'pending'`.
4. `INSERT INTO moderation_actions (action_type = 'report_actioned', target_type, target_id, report_id = p_report_id, prior_action_id = p_prior_action_id, reason = p_reason, moderator_id = p_moderator_id) RETURNING id` → v_action_id.
5. `INSERT INTO private.moderation_action_reports (moderation_action_id = v_action_id, report_id = p_report_id)`.
6. `UPDATE content_reports SET status = 'actioned', reviewed_at = clock_timestamp(), reviewed_by = p_moderator_id WHERE id = p_report_id`.

---

## Section 6 — `redeem_group_invite` Internal Guard

`redeem_group_invite()` runs as `forkensics_executor` (BYPASSRLS). The RESTRICTIVE `group_members INSERT` policy does not apply. Internal guard required:

```sql
IF EXISTS (
  SELECT 1 FROM public.profiles
  WHERE id = private.auth_uid() AND is_suspended = true
) THEN
  RAISE EXCEPTION 'FK_SUSPENDED: suspended accounts cannot join groups';
END IF;
```

Added at function entry, before any group or invite validation.

---

## Section 7 — `transfer_group_ownership` Conditions

`transfer_group_ownership` is permitted for suspended senders (safe exit action) with the following conditions enforced inside the function:

```
1. Sender is authenticated and the current group owner.
2. Recipient (p_recipient_id):
   - Must exist and be active (is_active = true).
   - Must be onboarded (has completed onboarding).
   - Must NOT be suspended (is_suspended = false).
   - Must be a member of the group.
3. Transfer is audited:
   INSERT INTO public.moderation_actions (or a designated ownership_transfer_events table)
   recording sender, recipient, group_id, and clock_timestamp().
   (The exact audit mechanism is a Step 25 decision; the contract must define it.)
4. After transfer, the suspended sender retains group membership (if they were a member)
   but loses owner-level privileges. No new posting or administrative capabilities are granted.
```

`revoke_group_invite` (permitted for suspended users): no conditions beyond existing V1 authorization checks. Suspended inviter may revoke their own pending invites.

---

## Section 8 — `finalize_upload_session` — SHA-256 Parameter Validation

PostgreSQL function parameters cannot be declared `NOT NULL`. Validation is performed inside the function body before any state changes:

```sql
CREATE OR REPLACE FUNCTION public.finalize_upload_session(
  p_upload_session_id uuid,
  p_re_encoded_storage_key text,
  p_sha256_hash text          -- required; validated below
  -- ... other parameters
) RETURNS ...
AS $$
BEGIN
  -- Validate hash before any writes
  IF p_sha256_hash IS NULL OR p_sha256_hash !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'FK_INVALID_HASH: sha256_hash must be 64 lowercase hex characters';
  END IF;

  -- ... proceed with session finalization and media_object creation
  -- Store p_sha256_hash into private.media_storage_keys.sha256_hash atomically
  -- with re_encoded_storage_key
END;
$$;
```

The error is raised before any upload_session, media_object, or challenge state changes. The processing worker must retry with the correct hash, or the upload session transitions to `failed` per the existing failure recovery path.

---

## Section 9 — Full Acceptance Test Matrix

### 9.1 Comment trigger (unchanged from Rev 5 — 8 tests)

As specified in Rev 5 Section 9.1. No changes.

### 9.2 `can_view_challenge()` baseline (unchanged from Rev 5 — 6 tests)

As specified in Rev 5 Section 9.2. No changes.

### 9.3 Child-table block enforcement (unchanged — 10 tests)

As specified in Rev 5 Section 9.3. No changes.

### 9.4 `media-serve` block enforcement (unchanged — 7 tests)

As specified in Rev 5 Section 9.4. No changes.

### 9.5 Bulk report resolution + audit relationship

| # | Setup | Action | Expected |
|---|---|---|---|
| 5.1 | A and B both have pending reports on same comment | `remove_content('comment')` (any report_id) | Both reports `actioned`; 2 rows in moderation_action_reports |
| 5.2 | A and B both report same challenge | `remove_content('challenge')` | Both reports actioned; 2 rows in moderation_action_reports |
| 5.3 | A reports challenge; B reports linked media_object | `remove_content('challenge')` | Both actioned; 2 rows in moderation_action_reports |
| 5.4 | A and B both report same media via `remove_media` | `remove_media()` | Both actioned; 2 rows |
| 5.5 | Only one pending report | Any remove function | 1 row in moderation_action_reports |
| 5.6 | Verify audit completeness | SELECT from moderation_action_reports | Every actioned report has exactly one row |
| 5.7 | Dismiss one report; second report pending | `remove_content` via second report | Second report actioned; dismissed report unchanged; 1 row in moderation_action_reports |

### 9.6 Concurrency — two moderators, same target

| # | Setup | Action | Expected |
|---|---|---|---|
| 6.1 | Moderator 1 has Report A; Moderator 2 has Report B; same challenge | Both call `remove_content('challenge')` concurrently | One succeeds with full action; second acquires challenge lock, finds moderator_removed_at IS NOT NULL, takes idempotency path, links own report to existing action; no duplicate moderation_actions |
| 6.2 | Moderator 1 is in dismiss_report; Moderator 2 is in remove_content for same report | Concurrent calls | One acquires report lock first; second waits; post-lock status re-check catches changed state; second either proceeds (if dismiss was first) or report already actioned (if remove was first) |
| 6.3 | User creates report; concurrent remove_content on same target | Report creation races removal | If remove_content locks target first: remove commits, report_content sees moderator_removed_at IS NOT NULL → FK_NOT_FOUND; if report_content locks first: report inserted, then remove_content locks target and report, actions all pending |
| 6.4 | Two users submit identical report simultaneously | Concurrent report_content calls | Partial unique index prevents duplicate; one INSERT succeeds; one gets idempotent return with existing report_id |
| 6.5 | dismiss_report races bulk removal for same report | Concurrent calls | Lock serializes; second call finds status != 'pending' → raises FK_WRONG_STATE or returns no-op |

### 9.7 Challenge-removal idempotency

| # | Setup | Action | Expected |
|---|---|---|---|
| 7.1 | Challenge already moderator-removed | Second `remove_content('challenge')` call | Idempotency path: no new moderation_actions; any remaining pending reports linked to existing action |
| 7.2 | First removal actioned Report A; third reporter C files after removal | `remove_content` call using C's report | `report_content` locks challenge, sees moderator_removed_at IS NOT NULL → FK_NOT_FOUND; C cannot file a report |
| 7.3 | `remove_media` on media that is status = 'removed' | Call | FK_WRONG_STATE |
| 7.4 | `remove_media` on media that is status = 'rejected' | Call | FK_WRONG_STATE (only 'ready' is valid entry for remove_media) |

### 9.8 `redeem_group_invite` suspension guard

| # | Setup | Action | Expected |
|---|---|---|---|
| 8.1 | Suspended user | Calls `redeem_group_invite` with valid invite | FK_SUSPENDED raised; no group_members row inserted |
| 8.2 | Unsuspended user | Same call | Succeeds per V1 behavior |

### 9.9 `action_report` validation

| # | Setup | Action | Expected |
|---|---|---|---|
| 9.1 | Valid p_prior_action_id targeting same subject | `action_report(...)` | Report actioned; moderation_action_reports row inserted |
| 9.2 | p_prior_action_id is a 'report_dismissed' action | Call | FK_INVALID_PRIOR_ACTION |
| 9.3 | p_prior_action_id targets a different challenge | Call | FK_INVALID_PRIOR_ACTION (subject mismatch) |
| 9.4 | No prior action; moderator wants "no violation" | Use dismiss_report | Report dismissed correctly |

### 9.10 SHA-256 validation in `finalize_upload_session`

| # | Setup | Action | Expected |
|---|---|---|---|
| 10.1 | Worker provides valid lowercase 64-char hex | `finalize_upload_session` | Stored; constraint passes |
| 10.2 | Worker provides NULL hash | `finalize_upload_session` | FK_INVALID_HASH; no state changes |
| 10.3 | Worker provides uppercase hash | `finalize_upload_session` | FK_INVALID_HASH (fails `'^[0-9a-f]{64}$'` check) |
| 10.4 | Pre-V2 row with NULL sha256_hash | `reject_photo` | FK_MEDIA_METADATA_INCOMPLETE; no moderation state change |

### 9.11 Cleanup hold (unchanged from Rev 5 Section 9.8) — 5 tests

As specified. No changes.

### 9.12 Suspension matrix (unchanged from Rev 5 Section 9.10) — 3 tests

As specified. No changes. Also adds:

| # | Setup | Action | Expected |
|---|---|---|---|
| 12.4 | Suspended user | `transfer_group_ownership` to active, onboarded, unsuspended recipient | Succeeds; sender retains membership but loses owner privileges |
| 12.5 | Suspended user | `transfer_group_ownership` to suspended recipient | Fails (recipient is suspended) |

---

## Section 10 — Open Questions for Codex/GPT Review

1. **`transfer_group_ownership` audit mechanism:** Should this be recorded in `public.moderation_actions` (action_type = 'ownership_transferred') or a separate, dedicated `group_ownership_history` table? The former reuses existing infrastructure; the latter keeps ownership audit independent of moderation. No strong preference; either is implementable.

2. **Report filing after removal (test 7.2):** A reporter who tries to report already-removed content receives `FK_NOT_FOUND`. This means users cannot flag moderator-removed content for review (e.g., if they believe the removal was unjust). Is this acceptable for V1, or should there be a separate appeals mechanism? Proposed: acceptable for V1; appeals are out of scope.

3. **`moderation_action_reports` idempotency path record:** In the idempotency path (Section 4), the existing `v_existing_action_id` is used for new moderation_action_reports rows. If the existing moderation_actions row already has a corresponding `moderation_action_reports` row for one of the newly discovered reports (unlikely but possible if the report was previously linked in an earlier idempotency pass), the PRIMARY KEY constraint prevents a duplicate. Confirm this is the correct behavior (skip duplicate silently via INSERT ... ON CONFLICT DO NOTHING).

---

## Section 11 — Success Criteria for Step 24.1

- [ ] Global lock order: content target → pending reports (UUID) → media; verified deadlock-free in Section 9.6 tests
- [ ] `report_content` locks and rechecks target before insert; race with content removal produces FK_NOT_FOUND (test 6.3)
- [ ] `dismiss_report` acquires only report lock; cannot deadlock with remove functions
- [ ] `private.moderation_action_reports` table defined; every bulk-resolved report has exactly one row (test 5.6)
- [ ] `action_report` requires same-subject substantive prior action; FK_INVALID_PRIOR_ACTION on non-qualifying prior actions
- [ ] Challenge-removal idempotency: no duplicate moderation_actions/evidence on second call; new pending reports linked to existing action (test 7.1)
- [ ] `remove_media` on non-ready media raises FK_WRONG_STATE (test 7.3, 7.4)
- [ ] `redeem_group_invite` has internal suspension guard; test 8.1 passes
- [ ] `transfer_group_ownership` recipient must be active, onboarded, unsuspended; transfer is audited
- [ ] SHA-256 parameter is `text`; format validated in function body before writes; FK_INVALID_HASH on NULL or wrong format; FK_MEDIA_METADATA_INCOMPLETE on NULL hash at moderation time
- [ ] Single controlled migration plan: add nullable → verify zero nulls → add NOT NULL; no placeholder backfill
- [ ] All prior success criteria from Rev 5 still met
- [ ] Open questions answered by Codex/GPT
- [ ] No executable SQL written until governance approval
