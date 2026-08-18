# Step 24.1 Proposal — Rev 5 — UGC Safety and Moderation Contracts

**Status:** Pending review (Claude → Codex/GPT → Bill approval)
**Governance gate:** Bill must type `APPROVED: Step 24.1 — UGC Safety and Moderation Contracts` before any moderation schema or functions are written as executable SQL or applied to any environment.
**Changes from Rev 4:**
- Blocker 1: Comment trigger adds `current_user = 'forkensics_executor'` guard; server timestamps assigned in trigger body; trigger declared SECURITY INVOKER.
- Blocker 2: `can_view_challenge()` adds `posted_at IS NOT NULL` for non-poster visibility; `public.guess_judgments` corrected; `challenge_secrets` restrictive policy confirmed required.
- Blocker 3: `private.can_viewer_access_challenge(p_viewer_id)` added for service-role callers (media-serve).
- Blocker 4: All remove functions bulk-action every matching pending report; `action_report` requires a linked prior `moderation_actions` row.
- Blocker 5: Post-lock revalidation added to all moderation function sequences; exact allowed media states defined for challenge removal.
- Blocker 6: `exclusion_events` branched RESTRICTIVE policy; `create_group` SECURITY DEFINER guard; `transfer_group_ownership` and `revoke_group_invite` permitted for suspended users.
- Blocker 7: SHA-256 check constraint with exact hex pattern; two-migration deployment plan; moderation guard for missing hash.

---

## Section 1 — Confirmed Decisions (cumulative)

1. Comment placeholder: `[removed by moderator]`; evidence is audit metadata.
2. Block on active challenge: existing eligible participants read-only carve-out; no new interactions.
3. Moderation-action immutability: unconditional BEFORE UPDATE OR DELETE rejection.
4. Avatar photos: disabled in V1.
5. Text-filter trigger: SECURITY DEFINER, no bypass.
6. RESTRICTIVE policy approach: approved.
7. `get_my_reports()` SECURITY DEFINER RPC; direct table SELECT revoked.
8. SHA-256: computed in re-encoding worker, stored in `private.media_storage_keys`.
9. Activation media gate: enforced inside `activate_challenge()` body.
10. `reviewed` status: removed from state model. States: `pending`, `actioned`, `dismissed`.
11. `challenge_secrets`: RESTRICTIVE block policy required (V1 grants authenticated SELECT).
12. `exclusion_events`: direct authenticated INSERT; branched RESTRICTIVE policy.
13. `apply_correction`: SECURITY DEFINER/`forkensics_executor`; suspension guard inside function.
14. `action_report`: only valid when a linked prior moderation action exists; no-action closures use `dismiss_report`.
15. `transfer_group_ownership` and `revoke_group_invite`: permitted for suspended users (safe administrative/exit actions).

---

## Section 2 — Schema Changes

All unchanged from Rev 4 except:

### 2.1 `private.media_storage_keys` — SHA-256 column

```sql
-- V2 migration step 1: add nullable column with format check
ALTER TABLE private.media_storage_keys
  ADD COLUMN IF NOT EXISTS sha256_hash text
    CONSTRAINT msk_sha256_format CHECK (sha256_hash ~ '^[0-9a-f]{64}$');

-- V2 deployment script: backfill any development fixtures (set a known placeholder or real hash)
-- After backfill is confirmed on all environments:
-- V2 migration step 2 (separate migration file): add NOT NULL
ALTER TABLE private.media_storage_keys
  ALTER COLUMN sha256_hash SET NOT NULL;
```

`finalize_upload_session` receives the hash from the processing worker as a required parameter. The V2 function signature includes `p_sha256_hash text NOT NULL`. The function stores it in `media_storage_keys` atomically with `re_encoded_storage_key`. If the worker omits the hash, `finalize_upload_session` raises `FK_MISSING_HASH` and the session is left in `processing` for retry or failure recovery.

### 2.2 `private.moderation_evidence` — NOT NULL for media evidence SHA-256

```sql
CONSTRAINT me_media_integrity CHECK (
  evidence_type != 'media_metadata'
  OR (evidence_storage_key IS NOT NULL AND evidence_sha256 IS NOT NULL)
)
```

Moderation functions must read `sha256_hash` from `private.media_storage_keys` before inserting evidence. If the row is missing or `sha256_hash IS NULL` (pre-V2 fixture), the function raises `FK_MEDIA_METADATA_INCOMPLETE` and aborts. The content state is not changed. Moderator must investigate before proceeding.

---

## Section 3 — Comment Trigger Replacement (Corrected)

The trigger is **SECURITY INVOKER**. Inside a SECURITY INVOKER function, `current_user` is the actual calling role, making the `forkensics_executor` check safe and meaningful.

```sql
CREATE OR REPLACE FUNCTION public.restrict_comment_updates()
RETURNS trigger
LANGUAGE plpgsql SECURITY INVOKER
SET search_path = ''
AS $$
BEGIN
  -- Path 1: Moderator removal — only forkensics_executor may take this path
  IF current_user = 'forkensics_executor'
     AND OLD.moderator_removed_at IS NULL
     AND NEW.moderator_removed_at IS NOT NULL
     AND NEW.text = '[removed by moderator]'
     AND NEW.id IS NOT DISTINCT FROM OLD.id
     AND NEW.author_id IS NOT DISTINCT FROM OLD.author_id
     AND NEW.challenge_id IS NOT DISTINCT FROM OLD.challenge_id
     AND NEW.posted_at IS NOT DISTINCT FROM OLD.posted_at
     AND NEW.deleted_at IS NOT DISTINCT FROM OLD.deleted_at
  THEN
    -- Override caller-supplied timestamp with authoritative server time
    NEW.moderator_removed_at := clock_timestamp();
    RETURN NEW;
  END IF;

  -- Path 2: Author soft-delete — only the comment author may delete their own comment
  IF NEW.author_id = private.auth_uid()
     AND OLD.deleted_at IS NULL
     AND NEW.deleted_at IS NOT NULL
     AND NEW.id IS NOT DISTINCT FROM OLD.id
     AND NEW.text IS NOT DISTINCT FROM OLD.text
     AND NEW.challenge_id IS NOT DISTINCT FROM OLD.challenge_id
     AND NEW.posted_at IS NOT DISTINCT FROM OLD.posted_at
     AND NEW.moderator_removed_at IS NOT DISTINCT FROM OLD.moderator_removed_at
  THEN
    -- Override caller-supplied timestamp with authoritative server time
    NEW.deleted_at := clock_timestamp();
    RETURN NEW;
  END IF;

  RAISE EXCEPTION 'FK_COMMENT_IMMUTABLE: comment update not permitted';
END;
$$;
```

**Column-level protection note:** RLS controls row visibility; column-level GRANTs prevent `authenticated` from updating sensitive columns such as `text` and `moderator_removed_at`. Both defenses are complementary. The trigger's `current_user` check is a third, independent layer that is meaningful because the trigger is SECURITY INVOKER.

---

## Section 4 — `private.can_view_challenge()` (Corrected)

The helper now enforces the full baseline V1 visibility contract: poster sees own; non-poster requires group membership AND `posted_at IS NOT NULL`. Block logic and eligible-participant carve-out apply on top.

```sql
CREATE OR REPLACE FUNCTION private.can_view_challenge(p_challenge_id uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.challenges c
    WHERE c.id = p_challenge_id
      AND (
        -- Poster always sees their own challenges (any state)
        c.poster_id = private.auth_uid()
        OR
        -- Non-poster: challenge must be posted; must be group member;
        -- and either no block OR existing eligible participant carve-out
        (
          c.posted_at IS NOT NULL
          AND EXISTS (
            SELECT 1 FROM public.group_members gm
            WHERE gm.group_id = c.group_id
              AND gm.player_id = private.auth_uid()
          )
          AND (
            NOT EXISTS (
              SELECT 1 FROM public.user_blocks ub
              WHERE (ub.blocker_id = private.auth_uid() AND ub.blocked_id = c.poster_id)
                 OR (ub.blocker_id = c.poster_id    AND ub.blocked_id = private.auth_uid())
            )
            OR EXISTS (
              SELECT 1 FROM public.eligible_participants ep
              WHERE ep.challenge_id = p_challenge_id
                AND ep.player_id = private.auth_uid()
            )
          )
        )
      )
  );
$$;
```

**Corrected child-table list** (Section 5.1 RESTRICTIVE policy applies to):

| Table | FK column |
|---|---|
| `public.clues` | `challenge_id` |
| `public.challenge_secrets` | `challenge_id` |
| `public.challenge_answer_aliases` | `challenge_id` |
| `public.guess_attempts` | `challenge_id` |
| `public.guess_judgments` | `challenge_id` ← corrected from `judgments` |
| `public.score_runs` | `challenge_id` |
| `public.score_events` | `challenge_id` |
| `public.correction_events` | `challenge_id` |
| `public.eligible_participants` | `challenge_id` |
| `public.exclusion_events` | `challenge_id` |

---

## Section 5 — Service-Role Variant: `private.can_viewer_access_challenge`

`media-serve` calls the DB as service_role. Under a service-role credential, `private.auth_uid()` returns NULL. A separate function accepts the viewer identity explicitly.

```sql
CREATE OR REPLACE FUNCTION private.can_viewer_access_challenge(
  p_challenge_id uuid,
  p_viewer_id    uuid   -- derived from the Edge Function's verified JWT, never from request body
)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.challenges c
    WHERE c.id = p_challenge_id
      AND (
        c.poster_id = p_viewer_id
        OR (
          c.posted_at IS NOT NULL
          AND EXISTS (
            SELECT 1 FROM public.group_members gm
            WHERE gm.group_id = c.group_id AND gm.player_id = p_viewer_id
          )
          AND (
            NOT EXISTS (
              SELECT 1 FROM public.user_blocks ub
              WHERE (ub.blocker_id = p_viewer_id AND ub.blocked_id = c.poster_id)
                 OR (ub.blocker_id = c.poster_id AND ub.blocked_id = p_viewer_id)
            )
            OR EXISTS (
              SELECT 1 FROM public.eligible_participants ep
              WHERE ep.challenge_id = p_challenge_id AND ep.player_id = p_viewer_id
            )
          )
        )
      )
  );
$$;
```

**`media-serve` authorization flow:**
1. Edge Function verifies the requester's JWT via `supabaseClient.auth.getUser()` → extracts `user.id` (UUID). This is `p_viewer_id`. It is never read from the request body.
2. Edge Function calls `private.can_viewer_access_challenge(media_challenge_id, user_id)` (via service-role DB connection).
3. If false → return `403 FK_FORBIDDEN`.
4. Additionally checks `media_objects.status = 'ready'` AND `challenges.moderator_removed_at IS NULL`. If either fails → `403`.

**Acceptance tests (new — Section 12.4).**

---

## Section 6 — Bulk Report Resolution

When content is removed by any moderation function, all matching pending reports are actioned atomically in the same transaction. No pending report is left stranded after removal.

### 6.1 Resolution scope per function

**`remove_content('comment', comment_id)`:**
```sql
UPDATE public.content_reports
SET status = 'actioned', reviewed_at = clock_timestamp(), reviewed_by = p_moderator_id
WHERE target_type = 'comment'
  AND target_id = p_target_id
  AND status = 'pending';
```

**`remove_content('clue', clue_id)`:**
```sql
UPDATE public.content_reports
SET status = 'actioned', reviewed_at = clock_timestamp(), reviewed_by = p_moderator_id
WHERE target_type = 'clue'
  AND target_id = p_target_id
  AND status = 'pending';
```

**`remove_content('challenge', challenge_id)` — also covers media and inappropriate_image reports:**
```sql
UPDATE public.content_reports
SET status = 'actioned', reviewed_at = clock_timestamp(), reviewed_by = p_moderator_id
WHERE status = 'pending'
  AND (
    (target_type = 'challenge' AND target_id = p_target_id)
    OR (target_type = 'media_object' AND target_id = v_media_object_id)
  );
```

**`remove_media(p_media_object_id, linked_challenge_id)`:**
```sql
UPDATE public.content_reports
SET status = 'actioned', reviewed_at = clock_timestamp(), reviewed_by = p_moderator_id
WHERE status = 'pending'
  AND (
    (target_type = 'media_object' AND target_id = p_media_object_id)
    OR (target_type = 'challenge' AND category = 'inappropriate_image'
        AND target_id = v_linked_challenge_id)
  );
```

### 6.2 Initiating report vs. bulk resolution

`p_report_id` is the initiating report. It is validated (locked, status checked) before any action. The bulk UPDATE actions all others. Both paths produce `status = 'actioned'`, `reviewed_at`, and `reviewed_by` on the report rows. The `moderation_actions` row records the content action; the report rows record that each report was resolved.

### 6.3 `action_report` (revised)

Standalone `action_report` is for closing a report whose corresponding content action was already recorded separately (e.g., the moderator suspended a user via `suspend_user`, and now closes the harassment report manually). It requires a linked prior `moderation_actions` row to prevent abuse.

```
public.action_report(
  p_report_id      uuid,
  p_moderator_id   uuid,
  p_prior_action_id uuid,  -- references an existing moderation_actions row
  p_reason         text
) → void
```

1. Validate moderator.
2. Verify `moderation_actions.id = p_prior_action_id` exists.
3. Lock report `FOR UPDATE`. Re-check `status = 'pending'`. Re-check target matches.
4. `INSERT INTO moderation_actions (action_type = 'report_actioned', report_id, reason, moderator_id)`.
5. `UPDATE content_reports SET status = 'actioned', reviewed_at, reviewed_by`.

If the moderator wants to close a report with no corresponding action (investigation found no violation), use `dismiss_report`.

---

## Section 7 — Moderation Function Sequences (Corrected Lock Order and Revalidation)

### 7.1 Global lock order

**report → challenge → media**

Every function acquires locks in this order. Re-validation occurs after each lock.

### 7.2 `remove_content('challenge', p_target_id)` — full sequence

```
1. Validate moderator identity.
2. Lock report (if p_report_id IS NOT NULL):
   SELECT id, status, target_type, target_id
   FROM content_reports WHERE id = p_report_id FOR UPDATE.
   Verify: status = 'pending'; target_type = 'challenge'; target_id = p_target_id.
3. Lock challenge:
   SELECT id, state, media_object_id, moderator_removed_at
   FROM challenges WHERE id = p_target_id FOR UPDATE.
   Validate state per Section 7.5.
4. Resolve media linkage from the locked challenge row (v_media_object_id = media_object_id).
5. Lock media (if v_media_object_id IS NOT NULL):
   SELECT id, status FROM media_objects WHERE id = v_media_object_id FOR UPDATE.
   Validate per Section 7.5.
6. Read sha256_hash FROM media_storage_keys WHERE media_object_id = v_media_object_id.
   If sha256_hash IS NULL → raise FK_MEDIA_METADATA_INCOMPLETE; abort.
7. INSERT moderation_actions (action_type = 'content_removed', ...) RETURNING id.
8. INSERT moderation_evidence (type = 'media_metadata', key, sha256 from step 6).
9. UPDATE challenges per state matrix (Section 7.5).
10. UPDATE media_objects per transition matrix (Section 7.5).
11. Bulk-action all matching pending reports (Section 6.1).
```

### 7.3 `remove_media(p_media_object_id)` — full sequence

```
1. Validate moderator identity.
2. Lock report:
   SELECT ... FROM content_reports WHERE id = p_report_id FOR UPDATE.
   Verify: status = 'pending'; target matches p_media_object_id or linked challenge (see below).
3. Resolve v_challenge_id: SELECT id FROM challenges WHERE media_object_id = p_media_object_id.
   This read is provisional; re-validated after the lock.
4. Lock challenge:
   SELECT id, state, media_object_id, moderator_removed_at
   FROM challenges WHERE id = v_challenge_id FOR UPDATE.
5. Re-validate: challenges.media_object_id = p_media_object_id (linkage may have changed if poster re-uploaded between steps 3 and 4).
   If mismatch → raise FK_LINKAGE_CHANGED; abort.
6. Lock media:
   SELECT id, status FROM media_objects WHERE id = p_media_object_id FOR UPDATE.
   Verify: status = 'ready' (only ready media is reportable; see Section 7.5).
7. Read sha256_hash. Raise FK_MEDIA_METADATA_INCOMPLETE if NULL.
8. INSERT moderation_actions RETURNING id.
9. INSERT moderation_evidence.
10. UPDATE media_objects SET status = 'removed', moderated_at = clock_timestamp().
11. UPDATE challenges per state matrix (Section 7.5).
12. Bulk-action all matching pending reports (Section 6.1).
```

### 7.4 `remove_content('comment')` and `remove_content('clue')` — lock order

```
1. Validate moderator identity.
2. Lock report (if p_report_id IS NOT NULL):
   SELECT ... FOR UPDATE. Verify status = 'pending'; target matches.
3. Lock target row (comment or clue):
   SELECT ... FROM comments/clues WHERE id = p_target_id FOR UPDATE.
   Verify moderator_removed_at IS NULL (idempotent guard).
4. INSERT moderation_actions RETURNING id.
5. INSERT moderation_evidence (evidence_text).
6. UPDATE comments/clues (text replacement and/or moderator_removed_at).
7. Bulk-action all matching pending reports.
```

### 7.5 Challenge and media state matrix for removal

**Allowed challenge states for moderator removal:**

| Challenge state | After `remove_content` or `remove_media` |
|---|---|
| `draft` | state → `cancelled`; `cancellation_reason = 'moderation_action'`; `moderator_removed_at = clock_timestamp()` |
| `active` | Same |
| `locked` | Same |
| `revealed` | state unchanged; `moderator_removed_at = clock_timestamp()`. Scores preserved. |
| `cancelled` (any reason) | `moderator_removed_at = clock_timestamp()` if not already set; state unchanged. |

If `moderator_removed_at` is already set → idempotent; skip challenge UPDATE; proceed to media and report steps.

**Allowed media states for removal (from the locked media row):**

| Media status | Action during challenge or media removal |
|---|---|
| `ready` | Set `status = 'removed'`, `moderated_at = clock_timestamp()` |
| `pending_review` | Set `status = 'removed'`, `moderated_at = clock_timestamp()` |
| `rejected` | Set `status = 'removed'`, `moderated_at = clock_timestamp()` |
| `removed` | Already removed; skip media UPDATE; proceed |
| `cleaned` | Already deleted from storage; skip media UPDATE; proceed |
| `superseded` | Set `status = 'removed'` (the superseding chain may still have a live object; flag for manual review) |
| `processing` | Raise `FK_WRONG_STATE`; abort. Media is actively being processed; removal must wait. |
| `failed` | Raise `FK_WRONG_STATE`; abort. Media state is inconsistent; requires investigation. |

For `remove_media`: only `ready` media is a valid entry point (only `ready` media is reportable). Any other status raises `FK_WRONG_STATE` at step 6.

---

## Section 8 — Suspension Matrix (Corrected)

### 8.1 `exclusion_events` — branched RESTRICTIVE policy

`exclusion_events` inserts are direct authenticated INSERTs in V1. The V2 RESTRICTIVE policy allows self-withdrawal for suspended users but blocks removing another participant:

```sql
CREATE POLICY suspend_exclusion_insert AS RESTRICTIVE ON public.exclusion_events
  FOR INSERT TO authenticated
  WITH CHECK (
    -- Not suspended: let V1 permissive policy handle full authorization
    NOT EXISTS (
      SELECT 1 FROM public.profiles WHERE id = private.auth_uid() AND is_suspended = true
    )
    OR
    -- Suspended: only self-withdrawal is permitted
    (reason = 'withdrew' AND player_id = private.auth_uid())
  );
```

### 8.2 `create_group` SECURITY DEFINER guard

```sql
IF EXISTS (SELECT 1 FROM public.profiles WHERE id = private.auth_uid() AND is_suspended = true) THEN
  RAISE EXCEPTION 'FK_SUSPENDED: suspended accounts cannot create groups';
END IF;
```

Added at function entry in `create_group`. Runs as `forkensics_executor` (BYPASSRLS); table-level RESTRICTIVE policy on `groups` INSERT also covers the direct INSERT path (defense in depth).

### 8.3 `apply_correction` SECURITY DEFINER guard

```sql
IF EXISTS (SELECT 1 FROM public.profiles WHERE id = private.auth_uid() AND is_suspended = true) THEN
  RAISE EXCEPTION 'FK_SUSPENDED: suspended accounts cannot apply corrections';
END IF;
```

Added at function entry. Runs as `forkensics_executor`.

### 8.4 Permitted actions for suspended users (complete list)

| Action | Permitted | Basis |
|---|---|---|
| INSERT comment/clue/reaction/guess | No | RESTRICTIVE table policy |
| INSERT/UPDATE challenge | No | RESTRICTIVE table policy |
| UPDATE challenge_secrets/aliases | No | RESTRICTIVE table policy |
| INSERT group / UPDATE group | No | RESTRICTIVE table policy + function guard |
| INSERT group_members (invite redemption) | No | RESTRICTIVE table policy |
| UPDATE profiles (display_name) | No | RESTRICTIVE table policy |
| INSERT exclusion_events (reason = 'removed') | No | Branched RESTRICTIVE policy |
| `apply_correction` | No | Function guard |
| `create_group` | No | Function guard |
| `create_group_invite` | No | Function guard |
| `activate_challenge` | No | Function guard |
| `redeem_group_invite` | No | RESTRICTIVE policy on group_members INSERT |
| `report_content` | **Yes** | Safety action |
| `block_user` / `unblock_user` | **Yes** | Safety action |
| `cancel_challenge` / `reveal_challenge` | **Yes** | Safe close |
| Author soft-delete own comment | **Yes** | Trigger Path 2 (no suspension check) |
| Delete own reaction | **Yes** | No suspension check on DELETE policy |
| INSERT exclusion_events (reason = 'withdrew') | **Yes** | Self-withdrawal; branched RESTRICTIVE policy |
| `transfer_group_ownership` | **Yes** | Safe administrative action |
| `revoke_group_invite` | **Yes** | Safe administrative/exit action |
| Delete account | **Yes** | Always permitted |

### 8.5 Policy naming — unique per table per operation

Tables with both INSERT and UPDATE RESTRICTIVE suspension policies use distinct names:

| Table | INSERT policy name | UPDATE policy name |
|---|---|---|
| `public.challenges` | `suspend_block_insert` | `suspend_block_update` |
| `public.challenge_secrets` | `suspend_block_insert` | `suspend_block_update` |
| `public.challenge_answer_aliases` | `suspend_block_insert` | `suspend_block_update` |
| `public.groups` | `suspend_block_insert` | `suspend_block_update` |
| `public.profiles` | — | `suspend_block_update` |
| All other tables | `suspend_block_insert` | — |

---

## Section 9 — Full Acceptance Test Matrix

### 9.1 Comment trigger (7 tests → 8 with Path 1 repeat)

| # | Setup | Action | Expected |
|---|---|---|---|
| 1.1 | Authenticated author | UPDATEs `text` directly | `FK_COMMENT_IMMUTABLE` |
| 1.2 | Non-author authenticated | Any UPDATE | `FK_COMMENT_IMMUTABLE` |
| 1.3 | Authenticated author | Sets `deleted_at`, text unchanged | `deleted_at` overridden with `clock_timestamp()`; allowed |
| 1.4 | Author sets deleted_at with past timestamp | UPDATE | Timestamp overridden with server time |
| 1.5 | `remove_content('comment')` (executor) | All Path 1 conditions met | `moderator_removed_at` set to server time; `text = '[removed by moderator]'`; allowed |
| 1.6 | Forged: sets `moderator_removed_at` as authenticated user | UPDATE | `FK_COMMENT_IMMUTABLE` (current_user ≠ forkensics_executor) |
| 1.7 | Executor: placeholder wrong (`[REMOVED]`) | UPDATE | `FK_COMMENT_IMMUTABLE` |
| 1.8 | Executor: `moderator_removed_at` already set | Re-attempt removal | `FK_COMMENT_IMMUTABLE` (OLD.moderator_removed_at IS NOT NULL) |

### 9.2 `can_view_challenge()` baseline — draft visibility

| # | Setup | Action | Expected |
|---|---|---|---|
| 2.1 | Poster's own draft (posted_at IS NULL) | Poster queries via helper | `true` |
| 2.2 | Another poster's draft (posted_at IS NULL) | Group member queries via helper | `false` (posted_at IS NOT NULL required) |
| 2.3 | Posted challenge; no block | Group member queries | `true` |
| 2.4 | Posted challenge; A blocks B (poster) | B queries | `false` |
| 2.5 | Posted challenge; A blocks B; B was eligible before block | B queries | `true` (carve-out) |
| 2.6 | Posted challenge; B in no shared group | B queries | `false` |

### 9.3 Child-table block enforcement

| # | Setup | Action | Expected |
|---|---|---|---|
| 3.1 | A blocks B; B knows A's challenge UUID | B queries `clues` by challenge_id | 0 rows |
| 3.2 | Same | B queries `challenge_secrets` | 0 rows |
| 3.3 | Same | B queries `challenge_answer_aliases` | 0 rows |
| 3.4 | Same | B queries `guess_attempts` | 0 rows |
| 3.5 | Same | B queries `guess_judgments` | 0 rows |
| 3.6 | Same | B queries `eligible_participants` | 0 rows |
| 3.7 | Same | B queries `exclusion_events` | 0 rows |
| 3.8 | B is existing eligible participant (carve-out) | B queries `clues` | Returns clues |
| 3.9 | No block | All above | Return normally |
| 3.10 | Draft challenge by another poster | B queries any child table | 0 rows (posted_at IS NULL → can_view_challenge false) |

### 9.4 `media-serve` block enforcement

| # | Setup | Action | Expected |
|---|---|---|---|
| 4.1 | Allowed group member, no block | media-serve request | 200 with image |
| 4.2 | A blocks B (poster) | B's media-serve request | 403 FK_FORBIDDEN |
| 4.3 | Outsider (no group membership) | media-serve request | 403 FK_FORBIDDEN |
| 4.4 | Poster (own challenge) | media-serve request | 200 |
| 4.5 | B is existing eligible participant; A blocks B later | B's media-serve request | 200 (carve-out applies) |
| 4.6 | Moderator-removed challenge | Any member's media-serve request | 403 FK_FORBIDDEN |
| 4.7 | `p_viewer_id` derived from request body (not JWT) | media-serve | Not applicable (Edge Function must derive from verified JWT) |

### 9.5 Bulk report resolution

| # | Setup | Action | Expected |
|---|---|---|---|
| 5.1 | A and B both report same comment | `remove_content('comment')` called with A's report_id | Both A's and B's reports set to `actioned` |
| 5.2 | A and B both report same clue | `remove_content('clue')` | Both reports actioned |
| 5.3 | A reports challenge; B reports media_object (same challenge) | `remove_content('challenge')` | Both reports actioned |
| 5.4 | A reports challenge as inappropriate_image; B reports media_object | `remove_media()` | Both reports actioned |
| 5.5 | Only one pending report at removal time | Any remove function | Single report actioned; no error |
| 5.6 | After bulk action | Cleanup claim for the media | Object now claimable (no pending reports) |

### 9.6 `action_report` validation

| # | Setup | Action | Expected |
|---|---|---|---|
| 6.1 | Valid p_prior_action_id | `action_report(report_id, mod_id, action_id, reason)` | Report actioned |
| 6.2 | Invalid/nonexistent p_prior_action_id | `action_report(...)` | FK_NOT_FOUND or FK_UNAUTHORIZED |
| 6.3 | No prior action; moderator wants "no violation found" | Use `dismiss_report` | Report dismissed |

### 9.7 Report access verification (repeated from Rev 4 Section 13.3)

| # | Setup | Action | Expected |
|---|---|---|---|
| 7.1 | Reporter has NOT guessed; challenge unrevealed | Reports comment | FK_NOT_FOUND |
| 7.2 | A blocks B (poster) | A tries to report B's challenge | FK_NOT_FOUND |
| 7.3 | Moderator-removed clue | Reporter tries to report | FK_NOT_FOUND |
| 7.4 | `pending_review` media | Reporter tries to report media_object | FK_NOT_FOUND |
| 7.5 | Draft challenge by another poster | Reporter tries to report | FK_NOT_FOUND |
| 7.6 | Reporter has guessed; challenge revealed | Reports comment | Accepted |

### 9.8 Cleanup hold with multiple reporters

| # | Setup | Action | Expected |
|---|---|---|---|
| 8.1 | A and B both have pending reports on same media | Cleanup claim runs | Object not claimable |
| 8.2 | A's report dismissed; B's still pending | Cleanup claim | Still not claimable |
| 8.3 | B's report also dismissed | Cleanup claim | Object now claimable |
| 8.4 | Challenge inappropriate_image report pending | Cleanup claim for linked media | Not claimable |
| 8.5 | That report dismissed | Cleanup claim | Claimable |

### 9.9 SHA-256 integrity

| # | Setup | Action | Expected |
|---|---|---|---|
| 9.1 | Worker provides valid lowercase 64-char hex hash | `finalize_upload_session` | Stored; constraint passes |
| 9.2 | Worker provides uppercase hash | `finalize_upload_session` | Constraint violation (format check) |
| 9.3 | Worker omits hash (NULL) | `finalize_upload_session` | FK_MISSING_HASH raised |
| 9.4 | Pre-V2 row with NULL sha256_hash | `reject_photo` or `remove_content` | FK_MEDIA_METADATA_INCOMPLETE; no state change |

### 9.10 Suspension — exclusion_events

| # | Setup | Action | Expected |
|---|---|---|---|
| 10.1 | Suspended user | INSERT exclusion reason = 'withdrew', player_id = own | Allowed |
| 10.2 | Suspended poster | INSERT exclusion reason = 'removed', player_id = another | RESTRICTIVE policy rejects |
| 10.3 | Unsuspended poster | INSERT exclusion reason = 'removed' | Allowed (V1 permissive policy handles authorization) |

### 9.11 Lock order / deadlock

| # | Setup | Action | Expected |
|---|---|---|---|
| 11.1 | Concurrent `remove_content('challenge')` + `remove_media` on same challenge | Both called simultaneously | One succeeds; second reads updated state after acquiring locks; fails FK_WRONG_STATE or detects already-removed |
| 11.2 | Concurrent `dismiss_report` + `remove_content('challenge')` with same report_id | Both called simultaneously | One acquires report lock first; second reads `status = 'pending'` then `status = 'actioned'`; second fails |
| 11.3 | `remove_media` where poster re-uploaded between challenge read and lock | Challenge.media_object_id differs from p_media_object_id at re-validate step | FK_LINKAGE_CHANGED raised |

---

## Section 10 — Open Questions for Codex/GPT Review

1. **`remove_media` and already-removed challenge:** If a challenge is in `cancelled` or `revealed` state and `remove_media` is called, the challenge state matrix is clear. However, if the challenge was already moderation-cancelled with `moderator_removed_at` set, and a second `remove_media` call arrives (e.g., two moderators acting simultaneously after the hold is released), step 5 of Section 7.3 will raise `FK_WRONG_STATE` (media is `removed` not `ready`). This is correct behavior. Confirm.

2. **`reject_photo` and already-rejected media hold:** If a report arrives for a `pending_review` photo, the report is accepted (media is not yet `ready`; Section 5.1 says `ready` is required for `media_object` reports). But `pending_review` photos cannot be reported as `media_object` type currently. Should reporters be able to report a photo that a moderator has already seen (still pending their decision)? Proposed: no — reporters can only report `ready` media. Pending photos are already in the moderation queue. Confirm.

3. **`transfer_group_ownership` suspension behavior:** Listed as permitted. If the suspended user transfers ownership, the receiving member can then manage the group normally. Is this the desired behavior, or should transfer be blocked to prevent circumvention of suspension effects on group administration?

---

## Section 11 — Success Criteria for Step 24.1

- [ ] Comment trigger: SECURITY INVOKER; `current_user = 'forkensics_executor'` in Path 1; server timestamps in both paths; `id` preserved; all 8 trigger tests pass
- [ ] `can_view_challenge()` includes `posted_at IS NOT NULL` for non-poster; draft challenge hidden from group members; tests 2.x pass
- [ ] `private.can_viewer_access_challenge(p_viewer_id)` defined for service-role callers; `media-serve` uses it with `p_viewer_id` from verified JWT
- [ ] `media-serve` tests (Section 9.4) pass
- [ ] Bulk report resolution in all remove functions; all matching pending reports actioned atomically; tests 5.x pass
- [ ] `action_report` requires `p_prior_action_id`; dismiss_report handles "no violation" closures
- [ ] Post-lock revalidation in `remove_media` (re-check challenge.media_object_id linkage)
- [ ] Media state matrix defined; `processing` and `failed` raise FK_WRONG_STATE; `removed`/`cleaned` skipped; `remove_media` accepts only `ready`
- [ ] `exclusion_events` branched RESTRICTIVE policy: suspended users may self-withdraw but not remove others; tests 10.x pass
- [ ] `create_group` and `apply_correction` SECURITY DEFINER guards confirmed
- [ ] `transfer_group_ownership` and `revoke_group_invite` permitted for suspended users
- [ ] `sha256_hash` column: format check constraint `'^[0-9a-f]{64}$'`; two-migration deployment plan
- [ ] `finalize_upload_session` requires hash parameter; FK_MISSING_HASH if absent
- [ ] Moderation functions raise FK_MEDIA_METADATA_INCOMPLETE if hash NULL at action time
- [ ] Open questions answered by Codex/GPT
- [ ] No executable SQL written until governance approval
