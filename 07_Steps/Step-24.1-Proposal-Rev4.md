# Step 24.1 Proposal — Rev 4 — UGC Safety and Moderation Contracts

**Status:** Pending review (Claude → Codex/GPT → Bill approval)
**Governance gate:** Bill must type `APPROVED: Step 24.1 — UGC Safety and Moderation Contracts` before any moderation schema or functions are written as executable SQL or applied to any environment.
**Changes from Rev 3:**
- Blocker 1: V1 `restrict_comment_updates` trigger replaced with a two-path body; moderator removal path gated by exact conditions; no `current_user` check.
- Blocker 2: `private.can_view_challenge()` canonical helper defined; RESTRICTIVE SELECT policy applied to every challenge-linked child table.
- Blocker 3: Report access verification changed to require actual target visibility, not just group membership.
- Blocker 4: `has_pending_report` boolean removed; cleanup hold is a live subquery; `reviewed` status removed from state model; two-reporters test added.
- Blocker 5: `get_media_key_for_report` split into `get_pending_review_media` and `get_reported_media`; `finalize_upload_session` replacement contract defined here (not deferred to Step 25).
- Blocker 6: Global lock order (report → challenge → media) defined; report row locked before resolution; challenge/media state matrix defined.
- Blocker 7: Complete suspension matrix; unique policy names per table; `apply_correction` and `exclusion_events` covered.
- Blocker 8: SHA-256 computed in re-encoding worker, stored in `private.media_storage_keys`, copied to evidence at moderation time.

---

## Section 1 — Confirmed Decisions

1. Comment removal: public placeholder `[removed by moderator]`; audit metadata in `private.moderation_evidence`.
2. Block on active challenge: existing eligible participants retain read-only visibility; no new interactions allowed between blocked pair on any challenge.
3. Moderation-action immutability: unconditional BEFORE UPDATE OR DELETE rejection.
4. Avatar photos: disabled in V1.
5. Text filter trigger: SECURITY DEFINER, no caller bypass — approved.
6. RESTRICTIVE policy approach — approved once missing paths and child-table visibility are complete.
7. `get_my_reports()`: SECURITY DEFINER RPC with `reporter_id = auth_uid()` guard; direct table SELECT revoked.
8. SHA-256: computed in re-encoding worker, stored in `private.media_storage_keys`.
9. Activation media gate: enforced inside `activate_challenge()` body while challenge row is locked; no additional trigger unless other activation paths exist.
10. `reviewed` report status: **removed** from the V1 state model. Report states are `pending`, `actioned`, `dismissed` only. This eliminates ambiguity in the cleanup hold and the partial unique index.

---

## Section 2 — Schema Changes

### 2.1 `public.content_reports`

```sql
CREATE TABLE IF NOT EXISTS public.content_reports (
  id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  reporter_id  uuid        NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  target_type  text        NOT NULL,
  target_id    uuid        NOT NULL,
  category     text        NOT NULL,
  detail       text,
  status       text        NOT NULL DEFAULT 'pending',
  created_at   timestamptz NOT NULL DEFAULT clock_timestamp(),
  reviewed_at  timestamptz,
  reviewed_by  uuid        REFERENCES public.profiles(id) ON DELETE RESTRICT,

  CONSTRAINT cr_target_type_check
    CHECK (target_type IN ('challenge','comment','clue','profile','media_object')),

  CONSTRAINT cr_category_check
    CHECK (category IN ('inappropriate_image','offensive_content','spam',
                        'harassment','copyright','other')),

  -- 'reviewed' is removed; valid states: pending, actioned, dismissed
  CONSTRAINT cr_status_check
    CHECK (status IN ('pending','actioned','dismissed')),

  CONSTRAINT cr_detail_check
    CHECK (detail IS NULL OR length(detail) <= 500)
);

-- Partial unique index: one unresolved report per reporter+target+category
CREATE UNIQUE INDEX content_reports_unresolved_dedup
  ON public.content_reports (reporter_id, target_type, target_id, category)
  WHERE status = 'pending';

CREATE INDEX ON public.content_reports (status, created_at);
CREATE INDEX ON public.content_reports (reporter_id);
CREATE INDEX ON public.content_reports (target_type, target_id) WHERE status = 'pending';
```

`reviewed_by` is populated by moderation functions but NOT returned to reporters. Access via `get_my_reports()` RPC only (Section 8).

### 2.2 `public.media_objects` — additions

```sql
ALTER TABLE public.media_objects
  ADD COLUMN IF NOT EXISTS moderated_at                     timestamptz,
  ADD COLUMN IF NOT EXISTS moderation_cleanup_leased_until  timestamptz;
-- has_pending_report boolean REMOVED (replaced by live subquery in cleanup; see Section 9)
```

### 2.3 `private.media_storage_keys` — SHA-256 addition

```sql
ALTER TABLE private.media_storage_keys
  ADD COLUMN IF NOT EXISTS sha256_hash text;  -- set by re-encoding worker; never NULL after V2
```

The re-encoding worker computes `SHA-256(re_encoded_bytes)` while the bytes are in memory and stores the hex string here. `private.moderation_evidence.evidence_sha256` copies this value at moderation time. No DB function computes hashes.

### 2.4 `private.moderation_evidence`

```sql
CREATE TABLE IF NOT EXISTS private.moderation_evidence (
  id                    uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  moderation_action_id  uuid        NOT NULL
                                    REFERENCES public.moderation_actions(id) ON DELETE RESTRICT,
  evidence_type         text        NOT NULL,
  evidence_text         text,
  evidence_storage_key  text,
  evidence_sha256       text,       -- copied from private.media_storage_keys.sha256_hash; required for media evidence
  retained_until        timestamptz NOT NULL DEFAULT (clock_timestamp() + interval '90 days'),
  created_at            timestamptz NOT NULL DEFAULT clock_timestamp(),

  CONSTRAINT me_evidence_type_check
    CHECK (evidence_type IN ('comment_text','clue_text','media_metadata')),

  CONSTRAINT me_media_fields_check
    CHECK (
      evidence_type != 'media_metadata'
      OR (evidence_storage_key IS NOT NULL AND evidence_sha256 IS NOT NULL)
    )
);

CREATE INDEX ON private.moderation_evidence (retained_until);
```

### 2.5 Other table additions — unchanged from Rev 3

- `public.comments`: `moderator_removed_at timestamptz`
- `public.challenges`: `moderator_removed_at timestamptz`
- `public.clues`: `moderator_removed_at timestamptz`
- `public.media_objects` status constraint (add `pending_review`, `rejected`, `removed`)
- `private.profile_suspensions`, `private.moderators`, `private.blocked_terms` — unchanged

---

## Section 3 — Comment Trigger Replacement (V1 `restrict_comment_updates`)

The frozen V1 trigger body explicitly rejects text changes with `RAISE EXCEPTION 'comment text is immutable'` and rejects non-author updates. The V2 migration replaces the function body with the two-path version below. The trigger attachment (`BEFORE UPDATE ON public.comments FOR EACH ROW`) is unchanged.

```sql
CREATE OR REPLACE FUNCTION public.restrict_comment_updates()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  -- Path 1: Moderator removal
  -- ALL of the following conditions must hold simultaneously.
  -- Any deviation falls through to rejection.
  IF OLD.moderator_removed_at IS NULL
     AND NEW.moderator_removed_at IS NOT NULL
     AND NEW.text = '[removed by moderator]'
     AND NEW.text IS DISTINCT FROM OLD.text        -- text must actually change
     AND NEW.author_id IS NOT DISTINCT FROM OLD.author_id
     AND NEW.challenge_id IS NOT DISTINCT FROM OLD.challenge_id
     AND NEW.posted_at IS NOT DISTINCT FROM OLD.posted_at
     AND NEW.deleted_at IS NOT DISTINCT FROM OLD.deleted_at
  THEN
    RETURN NEW;
  END IF;

  -- Path 2: Author soft-delete (set deleted_at = now())
  -- Only the comment author, only adding deleted_at, no text or structural changes.
  IF NEW.author_id = private.auth_uid()
     AND OLD.deleted_at IS NULL
     AND NEW.deleted_at IS NOT NULL
     AND NEW.text IS NOT DISTINCT FROM OLD.text
     AND NEW.challenge_id IS NOT DISTINCT FROM OLD.challenge_id
     AND NEW.posted_at IS NOT DISTINCT FROM OLD.posted_at
     AND NEW.moderator_removed_at IS NOT DISTINCT FROM OLD.moderator_removed_at
  THEN
    RETURN NEW;
  END IF;

  -- All other updates rejected
  RAISE EXCEPTION 'FK_COMMENT_IMMUTABLE: comment update not permitted';
END;
$$;
```

**Why no `current_user` bypass is needed:** `remove_content('comment')` runs inside a SECURITY DEFINER function as `forkensics_executor`, which has `BYPASSRLS`. However, triggers fire regardless of BYPASSRLS. The trigger checks only the transition conditions — not who is calling. An authenticated user cannot reach the moderator path because:
1. RLS prevents authenticated users from setting `moderator_removed_at` directly (no UPDATE policy covers that column for authenticated users).
2. Even if they tried via a direct statement, the text + transition conditions would need to match exactly, and the challenge remains that `moderator_removed_at` is only settable via executor functions.

**Acceptance tests (Section 11.1).**

---

## Section 4 — Block-Aware Challenge Visibility Helper

### 4.1 `private.can_view_challenge`

This is the single canonical function for block-aware challenge visibility. All child-table SELECT policies reference it.

```sql
CREATE OR REPLACE FUNCTION private.can_view_challenge(p_challenge_id uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.challenges c
    JOIN public.group_members gm
      ON gm.group_id = c.group_id AND gm.player_id = private.auth_uid()
    WHERE c.id = p_challenge_id
      AND (
        -- Poster always sees own challenges
        c.poster_id = private.auth_uid()
        -- No active block between viewer and poster (either direction)
        OR NOT EXISTS (
          SELECT 1 FROM public.user_blocks ub
          WHERE (ub.blocker_id = private.auth_uid() AND ub.blocked_id = c.poster_id)
             OR (ub.blocker_id = c.poster_id    AND ub.blocked_id = private.auth_uid())
        )
        -- Carve-out: existing eligible participant (block set after becoming eligible)
        OR EXISTS (
          SELECT 1 FROM public.eligible_participants ep
          WHERE ep.challenge_id = p_challenge_id AND ep.player_id = private.auth_uid()
        )
      )
  );
$$;
```

**Owned by:** `forkensics_rls_helper`. Callable by any role that can reference private functions (used inside RLS policies which run as the policy-owning role).

### 4.2 RESTRICTIVE SELECT policies on challenge-linked child tables

The following RESTRICTIVE policy is created on each child table, replacing or augmenting the existing V1 visibility check. Because these are RESTRICTIVE, they AND with all existing V1 permissive policies — they cannot broaden access, only narrow it.

```sql
-- Template (replace <table> and <fk_column>):
CREATE POLICY block_aware_visibility AS RESTRICTIVE ON public.<table>
  FOR SELECT TO authenticated
  USING (private.can_view_challenge(<fk_column>));
```

**Tables covered:**

| Table | FK column |
|---|---|
| `public.clues` | `challenge_id` |
| `public.challenge_secrets` | `challenge_id` |
| `public.challenge_answer_aliases` | `challenge_id` |
| `public.guess_attempts` | `challenge_id` |
| `public.judgments` | `challenge_id` |
| `public.score_runs` | `challenge_id` |
| `public.score_events` | `challenge_id` |
| `public.correction_events` | `challenge_id` |
| `public.eligible_participants` | `challenge_id` |
| `public.exclusion_events` | `challenge_id` |

**Note on `comments` and `reactions`:** These tables have the additional author-level block filter from Section 5.3. Their visibility is: `can_view_challenge(challenge_id)` AND `NOT has_block_with(author_id/player_id)`. Two RESTRICTIVE policies handle this: `block_aware_visibility` (above) and `hide_blocked_author` (below).

**Note on `media-serve`:** The `media-serve` Edge Function calls a service-only function before serving an image. That function must check `private.can_view_challenge(challenge_id)` for the media's linked challenge. If false, return `403 FK_FORBIDDEN`. The check also applies regardless of any block: a poster whose photo is removed cannot be served via direct media-serve call by any blocked user.

### 4.3 RESTRICTIVE SELECT policies for comments and reactions (author-level block filter)

```sql
-- Comments: block-aware challenge visibility + hide comments from blocked authors
CREATE POLICY block_aware_visibility AS RESTRICTIVE ON public.comments
  FOR SELECT TO authenticated
  USING (
    private.can_view_challenge(challenge_id)
    AND NOT EXISTS (
      SELECT 1 FROM public.user_blocks ub
      WHERE (ub.blocker_id = private.auth_uid() AND ub.blocked_id = author_id)
         OR (ub.blocker_id = author_id AND ub.blocked_id = private.auth_uid())
    )
  );

CREATE POLICY block_aware_visibility AS RESTRICTIVE ON public.reactions
  FOR SELECT TO authenticated
  USING (
    private.can_view_challenge(challenge_id)
    AND NOT EXISTS (
      SELECT 1 FROM public.user_blocks ub
      WHERE (ub.blocker_id = private.auth_uid() AND ub.blocked_id = player_id)
         OR (ub.blocker_id = player_id AND ub.blocked_id = private.auth_uid())
    )
  );
```

### 4.4 Challenge-level RESTRICTIVE SELECT policy (unchanged from Rev 3)

```sql
CREATE POLICY hide_blocked_challenges AS RESTRICTIVE ON public.challenges
  FOR SELECT TO authenticated
  USING (
    poster_id = private.auth_uid()
    OR NOT EXISTS (
      SELECT 1 FROM public.user_blocks ub
      WHERE (ub.blocker_id = private.auth_uid() AND ub.blocked_id = poster_id)
         OR (ub.blocker_id = poster_id AND ub.blocked_id = private.auth_uid())
    )
    OR EXISTS (
      SELECT 1 FROM public.eligible_participants ep
      WHERE ep.challenge_id = id AND ep.player_id = private.auth_uid()
    )
  );
```

---

## Section 5 — Report Access Verification (Tightened)

`report_content` must verify the reporter can see the target under the same effective rules as its normal SELECT — not merely that they are a group member.

### 5.1 Verification logic per target type

```
'challenge':
  private.can_view_challenge(target_id) must return true.
  Also: challenge must not have moderator_removed_at IS NOT NULL
        (already-actioned content is not reportable).

'comment':
  The comment must be visible: private.can_view_challenge(comment.challenge_id)
  AND comment.moderator_removed_at IS NULL (not already removed)
  AND comment satisfies the Table Talk visibility predicate
      (challenge.state = 'revealed' OR comment.author_id = auth_uid()
       OR EXISTS prior guess by auth_uid on that challenge).
  Rationale: a user who has not yet guessed cannot see Table Talk and cannot report it.

'clue':
  private.can_view_challenge(clue.challenge_id) must return true.
  clue.moderator_removed_at IS NULL.
  Clue must satisfy V1 clue visibility predicate (revealed or accessible).

'profile':
  Target profile must exist and be active.
  Caller must share at least one group with the target
  (at least one row in group_members for both caller and target in the same group_id).

'media_object':
  media_object.status = 'ready' (not pending_review, rejected, removed, cleaned).
  Linked challenge must satisfy private.can_view_challenge.
  media-serve would return 200 for this object under current rules.
```

In all cases: same response (`FK_NOT_FOUND`) for nonexistent, unauthorized, and already-actioned targets.

### 5.2 `inappropriate_image` category for challenge reports

When `target_type = 'challenge'` and `category = 'inappropriate_image'`, the report places a **media hold** on the challenge's current `media_object_id`. This is implemented at INSERT time in `report_content`:

```sql
IF p_target_type = 'challenge' AND p_category = 'inappropriate_image' THEN
  -- Record the media_object_id for hold tracking (via content_reports join, not has_pending_report)
  NULL; -- the cleanup hold subquery already covers challenge+inappropriate_image via the join below
END IF;
```

The cleanup hold subquery (Section 9) covers both `target_type = 'media_object'` reports and `target_type = 'challenge'` + `inappropriate_image` reports, via a join on `challenges.media_object_id`. No separate boolean flag is needed.

---

## Section 6 — Suspension Matrix

### 6.1 RESTRICTIVE INSERT policies (via table-level policies for authenticated users)

Policy naming convention: `suspend_block_<operation>` per table. For tables needing both INSERT and UPDATE restrictive policies, use distinct names.

```sql
-- Suspension helper (inline for clarity; could be a function):
-- NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = private.auth_uid() AND is_suspended = true)
```

| Table | Policy name | Operation | Note |
|---|---|---|---|
| `public.comments` | `suspend_block_insert` | INSERT | |
| `public.clues` | `suspend_block_insert` | INSERT | |
| `public.reactions` | `suspend_block_insert` | INSERT | |
| `public.guess_attempts` | `suspend_block_insert` | INSERT | |
| `public.challenges` | `suspend_block_insert` | INSERT | Creating a challenge |
| `public.challenges` | `suspend_block_update` | UPDATE | Editing draft |
| `public.challenge_secrets` | `suspend_block_insert` | INSERT | |
| `public.challenge_secrets` | `suspend_block_update` | UPDATE | |
| `public.challenge_answer_aliases` | `suspend_block_insert` | INSERT | |
| `public.challenge_answer_aliases` | `suspend_block_update` | UPDATE (is_active) | Deactivating alias |
| `public.group_members` | `suspend_block_insert` | INSERT | Invite redemption |
| `public.profiles` | `suspend_block_update` | UPDATE | display_name change |
| `public.groups` | `suspend_block_insert` | INSERT | |
| `public.groups` | `suspend_block_update` | UPDATE | |

All use `WITH CHECK (NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = private.auth_uid() AND is_suspended = true))`.

### 6.2 SECURITY DEFINER function guards

Tables where mutation runs through SECURITY DEFINER functions (BYPASSRLS, not affected by table-level RLS):

| Function | Suspended caller allowed? | Required guard |
|---|---|---|
| `apply_correction` | No | IS_SUSPENDED check at function entry |
| Functions adding `exclusion_events` (poster-initiated player removal) | No | IS_SUSPENDED check at function entry |
| `create_group_invite` | No | IS_SUSPENDED check |
| `redeem_group_invite` | No (covered by group_members INSERT RLS, but redundant guard in function) | |
| `activate_challenge` | No | IS_SUSPENDED check |
| `cancel_challenge` | **Yes** | No guard; safe close |
| `reveal_challenge` | **Yes** | No guard; safe close |
| `report_content` | **Yes** | No guard; safety action |
| `block_user` | **Yes** | No guard; safety action |
| `unblock_user` | **Yes** | No guard |
| Account deletion | **Yes** | No guard |
| `remove_content`, `remove_media`, etc. | Moderator-only (service_role); suspension irrelevant | — |

### 6.3 Permitted self-withdrawal actions for suspended users

Suspended users may:
- Set `comments.deleted_at` on their own comments (author soft-delete path in trigger)
- Delete their own reactions (authenticated DELETE policy; no suspension check)
- Call `cancel_challenge` and `reveal_challenge`
- File reports and blocks
- Delete their account

---

## Section 7 — Global Lock Order

To prevent deadlocks, all functions touching multiple rows use the following acquisition order:

**1 → report → 2 → challenge → 3 → media**

Every function locks in this order and never reverses it.

### 7.1 `remove_content('challenge', p_target_id)`

```
1. Validate moderator identity.
2. Lock report (if p_report_id IS NOT NULL):
   SELECT ... FROM content_reports WHERE id = p_report_id FOR UPDATE;
   Verify status = 'pending'; verify target_type = 'challenge' AND target_id = p_target_id.
3. Lock challenge:
   SELECT state, media_object_id, moderator_removed_at
   FROM challenges WHERE id = p_target_id FOR UPDATE;
   Validate state is in accepted matrix (Section 7.5).
4. Lock media:
   SELECT status FROM media_objects WHERE id = media_object_id FOR UPDATE;
   Validate media not already 'removed' or 'cleaned'.
5. INSERT moderation_actions RETURNING id.
6. INSERT moderation_evidence (evidence_storage_key + evidence_sha256 copied from media_storage_keys).
7. UPDATE challenges (moderator_removed_at = now(); state per matrix in Section 7.5).
8. UPDATE media_objects (status = 'removed', moderated_at = now()).
9. Resolve report (UPDATE content_reports status = 'actioned', reviewed_at, reviewed_by).
```

### 7.2 `remove_media(p_media_object_id)`

```
1. Validate moderator identity.
2. Lock report:
   SELECT ... FROM content_reports WHERE id = p_report_id FOR UPDATE;
   Verify status = 'pending'; verify target_type IN ('media_object','challenge')
   AND (target_id = p_media_object_id
        OR EXISTS (SELECT 1 FROM challenges WHERE id = target_id AND media_object_id = p_media_object_id)).
3. Resolve challenge_id from challenges WHERE media_object_id = p_media_object_id.
4. Lock challenge:
   SELECT state, moderator_removed_at FROM challenges WHERE id = challenge_id FOR UPDATE;
5. Lock media:
   SELECT status FROM media_objects WHERE id = p_media_object_id FOR UPDATE;
   Verify status = 'ready'.
6. INSERT moderation_actions RETURNING id.
7. INSERT moderation_evidence (from media_storage_keys.sha256_hash).
8. UPDATE media_objects (status = 'removed', moderated_at = now()).
9. UPDATE challenges per state matrix (Section 7.5).
10. Resolve report.
```

### 7.3 `remove_content('comment')` and `remove_content('clue')`

No media or challenge state change. Single-row lock on the target row. No deadlock risk.

### 7.4 `dismiss_report` and `action_report`

```
1. Lock report FOR UPDATE.
2. Verify status = 'pending'.
3. INSERT moderation_actions RETURNING id.
4. UPDATE content_reports (actioned or dismissed, reviewed_at, reviewed_by).
-- No media or challenge lock required for report-only actions.
-- action_report is for closing the report without a content action (e.g., deemed unfounded after investigation).
```

### 7.5 Challenge/media state matrix for content removal

| Challenge state | After `remove_content` / `remove_media` |
|---|---|
| `draft` | state → `cancelled`, `cancellation_reason = 'moderation_action'`, `moderator_removed_at = now()` |
| `active` | Same |
| `locked` | Same |
| `revealed` | state unchanged (`revealed`); `moderator_removed_at = now()`. Scores preserved. Challenge shows moderation tombstone to participants. |
| `cancelled` (any reason) | `moderator_removed_at = now()` if not already set; state unchanged. |

Media state after removal: `removed` (immediately unservable). Cleanup worker handles storage deletion.

A revealed challenge whose photo is removed retains all scores, guesses, and leaderboard records. The challenge UI shows a tombstone instead of the photo. This is the minimum viable moderation record consistent with not retroactively invalidating completed gameplay.

---

## Section 8 — Reporter-Visible Report Data

### 8.1 `public.get_my_reports`

```sql
public.get_my_reports() → TABLE(
  id          uuid,
  target_type text,
  target_id   uuid,
  category    text,
  detail      text,
  status      text,
  created_at  timestamptz,
  reviewed_at timestamptz
)
```

SECURITY DEFINER. Owned by `forkensics_executor`. At function entry: verifies caller is authenticated and onboarded. Returns rows WHERE `reporter_id = private.auth_uid()`. EXECUTE granted to `authenticated`.

`reviewed_by` is NOT in the return type. Moderator identity and reasoning are private.

### 8.2 Direct table SELECT revoked

No `SELECT` policy on `public.content_reports` for `authenticated`. All reporter-facing access goes through `get_my_reports()`. The `service_role` retains full access for moderation functions.

---

## Section 9 — Cleanup Hold (Subquery Approach)

`has_pending_report` boolean is removed. The cleanup hold is enforced via a live subquery in `claim_moderation_media_cleanup`:

```sql
CREATE OR REPLACE FUNCTION public.claim_moderation_media_cleanup(p_batch_size int DEFAULT 10)
RETURNS TABLE(media_object_id uuid, storage_key text, status text)
LANGUAGE sql SECURITY DEFINER
SET search_path = ''
AS $$
  UPDATE public.media_objects mo
  SET moderation_cleanup_leased_until = clock_timestamp() + interval '10 minutes'
  WHERE mo.id IN (
    SELECT m.id FROM public.media_objects m
    WHERE m.status IN ('rejected','removed')
      AND (m.moderation_cleanup_leased_until IS NULL
           OR m.moderation_cleanup_leased_until < clock_timestamp())
      -- Hold: any pending report for this media object (direct or via challenge+inappropriate_image)
      AND NOT EXISTS (
        SELECT 1 FROM public.content_reports cr
        WHERE cr.status = 'pending'
          AND (
            (cr.target_type = 'media_object' AND cr.target_id = m.id)
            OR (
              cr.target_type = 'challenge'
              AND cr.category = 'inappropriate_image'
              AND EXISTS (
                SELECT 1 FROM public.challenges c
                WHERE c.id = cr.target_id AND c.media_object_id = m.id
              )
            )
          )
      )
    ORDER BY m.moderated_at ASC
    LIMIT p_batch_size
    FOR UPDATE SKIP LOCKED
  )
  RETURNING
    mo.id,
    (SELECT msk.re_encoded_storage_key
     FROM private.media_storage_keys msk
     WHERE msk.media_object_id = mo.id),
    mo.status;
$$;
```

---

## Section 10 — Media Inspection Functions (Split)

### 10.1 `public.get_pending_review_media`

For proactive moderation queue review (no report needed):

```
public.get_pending_review_media(p_media_object_id uuid)
→ TABLE(
    media_object_id    uuid,
    re_encoded_storage_key text,
    challenge_id       uuid,
    uploader_id        uuid,
    re_encoded_at      timestamptz
  )
```

Returns a row if `media_objects.status = 'pending_review'`. Returns no row otherwise. Callers: service role. EXECUTE granted to `service_role`.

### 10.2 `public.get_reported_media`

For moderator review of a live `ready` photo that has a pending report:

```
public.get_reported_media(p_report_id uuid)
→ TABLE(
    media_object_id    uuid,
    re_encoded_storage_key text,
    challenge_id       uuid,
    uploader_id        uuid,
    media_status       text,
    report_category    text,
    report_detail      text
  )
```

Returns a row if:
- `content_reports.status = 'pending'`
- `target_type IN ('media_object','challenge')` with the appropriate linkage
- The linked media object is in a serviceable state (`ready` or `pending_review`)

Returns no row otherwise. Callers: service role. EXECUTE granted to `service_role`.

---

## Section 11 — `finalize_upload_session` Replacement Contract

This is a contract addition to Step 24.1, not deferred to Step 25. Step 25 must implement it.

**When the poster uploads a replacement photo after rejection:**

1. `reserve_upload_session` is called with the same `challenge_id` (which is in `draft` state with `media_object_id` pointing to a `rejected` or `cleaned` object).
2. `reserve_upload_session` locks the challenge row `FOR UPDATE`. It must succeed even if `media_object_id` points to a `rejected` or `cleaned` media object. The existing lock checks (deletion status) still apply.
3. `activate_upload_session` proceeds normally.
4. On upload complete, `finalize_upload_session`:
   a. Locks the draft challenge `FOR UPDATE`.
   b. Creates the new `media_object` with `status = 'pending_review'` and `re_encoded_at = now()`.
   c. **Atomically sets `challenges.media_object_id = new_media_object_id`** — even if the prior value was `rejected` or `cleaned`.
   d. The old `media_object_id` (rejected/cleaned) is NOT transitioned; it stays as-is.
   e. Returns the new `media_object_id`.
5. When the new media object is approved via `approve_photo`, `media_objects.status` → `'ready'`. The challenge `media_object_id` already points to the new object. No separate linkage step is required.
6. The poster calls `activate_challenge` after approval; the function reads the current `media_object_id` and verifies its status is `ready`.

**Acceptance test (replacement after cleanup):**
- Poster uploads photo → pending_review → rejected → cleanup runs → status = 'cleaned'
- Poster initiates new upload → finalize_upload_session → challenge.media_object_id → new media_object
- New media approved → challenge can now activate
- Old cleaned object is not touched

---

## Section 12 — Moderation Function Contracts (Revised)

### 12.1 `public.report_content`

Unchanged from Rev 3 except:
- Access verification per Section 5.1 (actual visibility, not just group membership)
- `inappropriate_image` on `challenge` target: no separate `has_pending_report` flag; cleanup hold handles via subquery
- On duplicate pending report conflict (partial unique index): return existing `report_id` idempotently

### 12.2 `public.approve_photo`

Lock order: media only (no challenge or report involved).

```
1. Validate moderator.
2. SELECT media FOR UPDATE. Verify status = 'pending_review'.
3. INSERT moderation_actions RETURNING id.
4. UPDATE media_objects SET status = 'ready', moderated_at = now().
```

`activate_challenge` (inside the function body, while challenge row is locked): verifies `media_objects.status = 'ready'` for the current `challenges.media_object_id`. If not `ready`, raises `FK_MEDIA_NOT_READY`.

### 12.3 `public.reject_photo`

Lock order: media only.

```
1. Validate moderator.
2. SELECT media FOR UPDATE. Verify status = 'pending_review'.
3. Read sha256_hash from private.media_storage_keys.
4. INSERT moderation_actions RETURNING id.
5. INSERT moderation_evidence (evidence_type = 'media_metadata',
   evidence_storage_key, evidence_sha256 = sha256_hash).
6. UPDATE media_objects SET status = 'rejected', moderated_at = now().
```

### 12.4 `public.remove_content`

Lock order: report → challenge → media. Per Section 7.1 and 7.3.

Accepts `target_type IN ('challenge','comment','clue')`. For `'comment'` and `'clue'`: single-row lock only.

For `'comment'`: locks and updates comment row. The V2 trigger allows this transition (Section 3). Evidence: `evidence_type = 'comment_text'`.

For `'challenge'`: per Section 7.1.

### 12.5 `public.remove_media`

Per Section 7.2. Lock order: report → challenge → media.

### 12.6 `public.suspend_user` and `public.reinstate_user`

Unchanged from Rev 3. Validate moderator. Atomically update `public.profiles.is_suspended` and `private.profile_suspensions`.

### 12.7 `public.dismiss_report`

Per Section 7.4. Inserts immutable `moderation_actions` row (action_type = 'report_dismissed').

Does NOT need to unset `has_pending_report` (boolean removed). Cleanup hold is recomputed at claim time via subquery.

### 12.8 `public.action_report`

Per Section 7.4. For standalone use when action was not inline (e.g., investigating and concluding no action needed but closing the report with action type). Inserts `moderation_actions` row (action_type = 'report_actioned').

### 12.9 `public.get_moderation_queue`

Unchanged from Rev 3.

### 12.10 `public.get_my_reports`

Per Section 8.1.

### 12.11 `public.get_poster_media_status`

Unchanged from Rev 3. Returns `status` and `rejection_message` (no `reviewed_by`).

### 12.12 `private.cleanup_expired_evidence`

```sql
CREATE OR REPLACE FUNCTION private.cleanup_expired_evidence()
RETURNS void
LANGUAGE sql SECURITY DEFINER
SET search_path = ''
AS $$
  DELETE FROM private.moderation_evidence
  WHERE retained_until < clock_timestamp();
$$;
```

Scheduled daily. After cleanup: original text and storage metadata deleted. Immutable `moderation_actions` row remains.

---

## Section 13 — Acceptance Criteria and Test Matrix

### 13.1 Comment trigger replacement

| # | Setup | Action | Expected |
|---|---|---|---|
| 1.1 | Authenticated author owns comment | Author UPDATEs text | `FK_COMMENT_IMMUTABLE` raised |
| 1.2 | Authenticated non-author | Any UPDATE | `FK_COMMENT_IMMUTABLE` |
| 1.3 | Authenticated author | Sets `deleted_at = now()`, text unchanged | Allowed (Path 2) |
| 1.4 | `remove_content('comment')` (executor) | Sets placeholder + moderator_removed_at, all immutable fields unchanged | Allowed (Path 1) |
| 1.5 | Forged: `moderator_removed_at` set but text NOT placeholder | UPDATE attempt | `FK_COMMENT_IMMUTABLE` |
| 1.6 | Forged: placeholder text but `moderator_removed_at` stays NULL | UPDATE attempt | `FK_COMMENT_IMMUTABLE` |
| 1.7 | Moderator removal: immutable field (author_id) changed | UPDATE attempt | `FK_COMMENT_IMMUTABLE` |
| 1.8 | `moderator_removed_at` already set (re-removal attempt) | UPDATE attempt | `FK_COMMENT_IMMUTABLE` (OLD.moderator_removed_at IS NOT NULL fails Path 1 entry) |

### 13.2 Block-aware child table visibility

| # | Setup | Action | Expected |
|---|---|---|---|
| 2.1 | A blocks B; B knows a challenge UUID posted by A | B directly queries `clues` WHERE challenge_id = hidden_uuid | 0 rows returned |
| 2.2 | Same | B queries `challenge_secrets` | 0 rows |
| 2.3 | Same | B queries `guess_attempts` | 0 rows |
| 2.4 | Same | B queries `eligible_participants` | 0 rows |
| 2.5 | Same | B queries `score_runs` | 0 rows |
| 2.6 | Same | B queries `correction_events` | 0 rows |
| 2.7 | Same | B calls `media-serve` with photo path from A's challenge | 403 FK_FORBIDDEN |
| 2.8 | A blocks B; B is eligible participant in A's active challenge | B queries `clues` | Returns clues (carve-out via eligible_participants) |
| 2.9 | No block | All above queries | Return normally |
| 2.10 | A blocks B; A queries B's child tables (own challenges) | A queries B's clues | 0 rows (bidirectional) |

### 13.3 Report access verification

| # | Setup | Action | Expected |
|---|---|---|---|
| 3.1 | Reporter has NOT guessed on challenge | Reports a comment on that challenge | FK_NOT_FOUND (not visible via Table Talk rules) |
| 3.2 | A blocks B (poster) | A tries to report B's challenge | FK_NOT_FOUND (challenge hidden by block) |
| 3.3 | Moderator-removed clue | Reporter tries to report it | FK_NOT_FOUND (moderator_removed_at IS NOT NULL) |
| 3.4 | `pending_review` media object | Reporter tries to report it (target_type = media_object) | FK_NOT_FOUND (status != 'ready') |
| 3.5 | Draft challenge by another poster | Reporter tries to report | FK_NOT_FOUND (draft not visible to non-poster) |
| 3.6 | Reporter has guessed; challenge revealed | Reports a comment on that challenge | Report accepted |
| 3.7 | Valid profile target; shared group | Reporter reports profile | Report accepted |

### 13.4 Cleanup hold — multiple reporters

| # | Setup | Action | Expected |
|---|---|---|---|
| 4.1 | A and B both report same media object | Both reports pending | Cleanup claim returns 0 rows for that object |
| 4.2 | A's report dismissed | Cleanup claim runs | 0 rows returned (B's report still pending) |
| 4.3 | B's report also dismissed | Cleanup claim runs | Object now claimable |
| 4.4 | Challenge report with inappropriate_image category | Cleanup claim runs | Object NOT claimed (hold via challenge+category join) |
| 4.5 | That challenge report dismissed | Cleanup claim runs | Object now claimable |

### 13.5 Media inspection

| # | Setup | Action | Expected |
|---|---|---|---|
| 5.1 | Media in pending_review | `get_pending_review_media(media_object_id)` | Returns storage key |
| 5.2 | Media in ready | `get_pending_review_media(media_object_id)` | Returns no row |
| 5.3 | Report against ready media | `get_reported_media(report_id)` | Returns storage key |
| 5.4 | Report against pending_review media (unusual) | `get_reported_media(report_id)` | Returns row (links correctly) |
| 5.5 | Report against removed media | `get_reported_media(report_id)` | Returns no row (unservable) |

### 13.6 Replacement after rejection + cleanup

| # | Setup | Action | Expected |
|---|---|---|---|
| 6.1 | Media rejected, cleanup runs → cleaned | Poster calls reserve_upload_session on same challenge | Succeeds |
| 6.2 | Finalize second upload | challenges.media_object_id | Updated to new media_object_id |
| 6.3 | Old media_object (cleaned) | Status | Still 'cleaned'; not modified |
| 6.4 | New media approved | activate_challenge | Succeeds |

### 13.7 Lock order — no deadlock

| # | Setup | Action | Expected |
|---|---|---|---|
| 7.1 | Concurrent `remove_content('challenge')` and `remove_media` on same challenge | Both called simultaneously | One succeeds; second fails FK_WRONG_STATE after acquiring locks |
| 7.2 | Concurrent `dismiss_report` + `remove_media` on same report | Both called simultaneously | One succeeds; second fails (report no longer pending) |

### 13.8 Revealed challenge removal

| # | Setup | Action | Expected |
|---|---|---|---|
| 8.1 | Challenge in `revealed` state | `remove_content('challenge', ...)` | state stays 'revealed'; moderator_removed_at set; media → 'removed' |
| 8.2 | Post-removal | All participant scores | Unchanged |
| 8.3 | Post-removal | media-serve for that challenge | 403 FK_FORBIDDEN |

### 13.9 Suspension (selected tests)

| # | Setup | Action | Expected |
|---|---|---|---|
| 9.1 | User suspended | INSERT challenge | Restrictive policy rejects |
| 9.2 | User suspended | UPDATE challenge (draft edit) | `suspend_block_update` restrictive policy rejects |
| 9.3 | User suspended | UPDATE challenge_answer_aliases.is_active | `suspend_block_update` rejects |
| 9.4 | User suspended | `apply_correction` | Function guard raises |
| 9.5 | User suspended | `cancel_challenge` | Allowed |
| 9.6 | User suspended | Author soft-deletes own comment | Allowed (trigger Path 2; no suspension check there) |
| 9.7 | User suspended | `report_content` | Allowed |
| 9.8 | User reinstated | All above inserts | Succeed |

---

## Section 14 — Open Questions for Codex/GPT Review

1. **`challenge_secrets` RLS:** V1 may have no direct SELECT policy on `challenge_secrets` for `authenticated` (access may be via SECURITY DEFINER function only). If `challenge_secrets` is not directly queryable by authenticated users, the RESTRICTIVE policy on it is a no-op for PostgREST but does not harm anything. Confirm whether `block_aware_visibility` on `challenge_secrets` is needed or redundant.

2. **`exclusion_events` INSERT path:** V1 may have a SECURITY DEFINER function for poster-initiated player exclusion (not a direct INSERT). If so, the suspension check belongs in that function, not in a table-level RESTRICTIVE policy. Confirm the V1 path for exclusion.

3. **`apply_correction` suspension guard:** Confirm `apply_correction` runs as `forkensics_executor` (BYPASSRLS). If so, the suspension check must be in the function body and cannot be a table-level RESTRICTIVE policy. Confirm.

4. **`action_report()` semantics:** With `reviewed` removed, `action_report` means "the report is closed but the associated content action was taken separately (or not at all)." Is this the intended use, or should `action_report` only be called when `remove_content` or `remove_media` did NOT already inline-resolve the report?

---

## Section 15 — Success Criteria for Step 24.1

- [ ] Comment trigger: V2 body with two-path approach; no `current_user` check; all 8 trigger tests pass
- [ ] `private.can_view_challenge()` defined; applies to all child tables in Section 4.2
- [ ] `media-serve` block check via `can_view_challenge` confirmed
- [ ] Report access verification: target visibility required, not just group membership; all Section 13.3 tests pass
- [ ] `has_pending_report` boolean removed; cleanup hold is live subquery covering both `media_object` and `challenge+inappropriate_image` reports
- [ ] `reviewed` status removed from `content_reports` state model; partial unique index covers only `pending`
- [ ] Two-reporters test (Section 13.4) passes
- [ ] `get_pending_review_media` and `get_reported_media` as two separate functions
- [ ] `finalize_upload_session` replacement contract defined (Section 11); replacement-after-cleanup test passes
- [ ] Global lock order (report → challenge → media) applied consistently in all moderation functions
- [ ] Report row locked FOR UPDATE before resolution; post-lock status re-check
- [ ] Challenge/media state matrix defined; revealed-challenge removal covered
- [ ] Complete suspension matrix (Section 6.1 and 6.2); unique policy names per table per operation
- [ ] `apply_correction` and `exclusion_events` suspension guards confirmed (via open questions)
- [ ] SHA-256 computed in re-encoding worker; stored in `private.media_storage_keys.sha256_hash`; copied to `moderation_evidence` at moderation time; `evidence_sha256 IS NOT NULL` constraint for media_metadata rows
- [ ] Open questions answered by Codex/GPT
- [ ] No executable SQL written until governance approval
