# Step 24.1 Proposal — Rev 2 — UGC Safety and Moderation Contracts

**Status:** Pending review (Claude → Codex/GPT → Bill approval)
**Governance gate:** Bill must type `APPROVED: Step 24.1 — UGC Safety and Moderation Contracts` before any moderation schema or functions are written as executable SQL or applied to any environment.
**Changes from Rev 1:** Eight blockers from Codex/GPT addressed. Text filtering moved to DB triggers. Block enforcement moved to server-side RLS. Suspension details moved to private schema. Moderator identity validated. Comment evidence preserved privately. Challenge moderator-removal state added. Reporting expanded. `re_encoded_at` semantics corrected.

---

## Section 1 — Decisions Confirmed by Codex/GPT

The following open questions from Rev 1 are now decided:

1. **Removed comments:** Public placeholder `'[removed by moderator]'` replaces original text. Original text preserved in `private.moderation_evidence` with a defined retention policy. Evidence is service-only and never readable by the reporter or public.

2. **Rejected-photo UX:** Poster sees the draft challenge in a rejected state: "Photo couldn't be approved — choose another photo." No push notification required for V1.

3. **Block during an active challenge:** Prior guesses and earned scores are preserved. Block immediately prevents new guesses, comments, and reactions between the blocked pair, even for challenges already in progress.

4. **Suspension during an active challenge:** Do not automatically cancel challenges. Block new content creation. Moderators use `remove_content` separately if the challenge's content is the problem. Allow safe close and cancel operations by the suspended user.

---

## Section 2 — Scope (Revised from Rev 1)

### 2.1 Included

All items from Rev 1, plus the following additions and corrections:

- Text filtering enforced in **database triggers**, not only Edge Functions, covering every user-visible text field
- Suspension state enforced in **RLS mutation policies** in addition to SECURITY DEFINER guards
- Block enforcement is **server-side and immediate** via RLS SELECT and INSERT policies
- `user_blocks` SELECT RLS: only the blocker sees their own rows; blocked party cannot query who blocked them
- `private.moderators` table: all moderation functions validate `p_moderator_id` against this table
- `private.profile_suspensions` table: suspension details (reason, timestamps) moved out of public schema
- `is_suspended` is the only suspension-related column on `public.profiles`
- `private.moderation_evidence` table: evidence snapshots (original comment text, rejected media keys) with retention policy
- `moderator_removed_at` column on `public.comments`
- `'removed'` state or `moderator_removed_at` on `public.challenges` (Section 4.8)
- `moderated_at` column on `public.media_objects` (distinct from `re_encoded_at`)
- `re_encoded_at` set at re-encoding time (in `finalize_upload_session`), not at moderation time
- Reporting: access-verified; `clue` and `media_object` added as reportable target types; duplicate constraint restricted to unresolved reports; rate limiting
- New service-only functions: `get_pending_review_media_key`, `get_report_for_review`, `get_poster_media_status`, `get_rejected_media_to_clean`
- Cleanup worker additions for `rejected` media objects
- V1 `restrict_comment_updates` trigger replaced in V2 to allow `forkensics_executor` bypass
- Apple reviewer seed plan made internally testable

### 2.2 Excluded (unchanged from Rev 1)

- Swift/SwiftUI implementation
- Automated ML/hash-based image scanning (V2)
- Push notification suppression between blocked pairs
- Community guidelines and terms of service text
- Age rating questionnaire answers
- Sentry configuration

---

## Section 3 — Effect on Step 25

Step 25 must incorporate these additional changes before going to Codex:

- `finalize_upload_session`: sets `media_objects.status = 'pending_review'` and `re_encoded_at = now()` (not `'ready'`); does not set `moderated_at`
- `media_objects` status constraint: add `'pending_review'`, `'rejected'`, `'removed'`
- `activate_challenge` V2 replacement: add block-pair exclusion (Section 7.1)
- Cleanup worker: add Part for `rejected` and `removed` media objects
- Standard mutation gate for all Edge Functions: add `is_suspended = false` check

---

## Section 4 — Schema

### 4.1 `public.content_reports`

```sql
CREATE TABLE IF NOT EXISTS public.content_reports (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  reporter_id     uuid        NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  target_type     text        NOT NULL,
  target_id       uuid        NOT NULL,
  category        text        NOT NULL,
  detail          text,
  status          text        NOT NULL DEFAULT 'pending',
  created_at      timestamptz NOT NULL DEFAULT clock_timestamp(),
  reviewed_at     timestamptz,
  reviewed_by     uuid        REFERENCES public.profiles(id) ON DELETE RESTRICT,

  CONSTRAINT cr_target_type_check
    CHECK (target_type IN ('challenge','comment','clue','profile','media_object')),

  CONSTRAINT cr_category_check
    CHECK (category IN ('inappropriate_image','offensive_content','spam',
                        'harassment','copyright','other')),

  CONSTRAINT cr_status_check
    CHECK (status IN ('pending','reviewed','actioned','dismissed')),

  CONSTRAINT cr_detail_check
    CHECK (detail IS NULL OR length(detail) <= 500),

  -- Uniqueness scoped to unresolved reports only.
  -- Resolved reports do not block a new report for the same target+category
  -- (e.g., a replacement photo can be reported independently).
  UNIQUE NULLS NOT DISTINCT (reporter_id, target_type, target_id, category)
    WHERE status = 'pending'
);
```

**Note on `reviewed_by` exposure:** This column is visible to the reporter via their SELECT policy. The `reviewed_by` is a `uuid` that references `profiles.id`; the reporter can resolve the name from `profiles`. This is acceptable — attribution to a moderator is not sensitive. The `resolution_note` from Rev 1 is removed entirely from this table; moderator notes are in `private.moderation_evidence`.

**Indexes:**
```sql
CREATE INDEX ON public.content_reports (status, created_at);
CREATE INDEX ON public.content_reports (reporter_id);
CREATE INDEX ON public.content_reports (target_type, target_id) WHERE status = 'pending';
```

**RLS:**
- `SELECT TO authenticated`: `reporter_id = private.auth_uid()`. Reporters see only their own reports. Columns visible: id, target_type, target_id, category, detail, status, created_at, reviewed_at. `reviewed_by` visible (acceptable; see note above).
- All direct inserts, updates, and deletes blocked for authenticated. Use `report_content` function.

### 4.2 `public.user_blocks`

```sql
CREATE TABLE IF NOT EXISTS public.user_blocks (
  blocker_id  uuid        NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  blocked_id  uuid        NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  created_at  timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY (blocker_id, blocked_id),
  CONSTRAINT user_blocks_no_self_block CHECK (blocker_id != blocked_id)
);

CREATE INDEX ON public.user_blocks (blocked_id);
```

**RLS:**
```sql
-- Blocker sees only blocks they created. Blocked party cannot query who blocked them.
CREATE POLICY blocks_select_own ON public.user_blocks
  FOR SELECT TO authenticated
  USING (blocker_id = private.auth_uid());
```

No direct INSERT, UPDATE, DELETE. Use `block_user` / `unblock_user` functions.

**Server-side block enforcement** applies immediately to new interactions via the RLS INSERT policies described in Section 6.

### 4.3 `public.moderation_actions`

```sql
CREATE TABLE IF NOT EXISTS public.moderation_actions (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  moderator_id    uuid        NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  action_type     text        NOT NULL,
  target_type     text,
  target_id       uuid,
  report_id       uuid        REFERENCES public.content_reports(id) ON DELETE RESTRICT,
  reason          text        NOT NULL,
  created_at      timestamptz NOT NULL DEFAULT clock_timestamp(),

  CONSTRAINT ma_action_type_check
    CHECK (action_type IN (
      'photo_approved','photo_rejected','photo_removed',
      'content_removed',
      'user_suspended','user_reinstated',
      'report_actioned','report_dismissed'
    )),

  CONSTRAINT ma_target_type_check
    CHECK (target_type IS NULL OR
           target_type IN ('challenge','comment','clue','profile','media_object')),

  CONSTRAINT ma_reason_check
    CHECK (length(trim(reason)) BETWEEN 1 AND 500)
);

-- Immutability: BEFORE UPDATE OR DELETE trigger raises exception (same pattern as V1 protect_rules_versions)

CREATE INDEX ON public.moderation_actions (target_type, target_id);
CREATE INDEX ON public.moderation_actions (moderator_id, created_at);
```

No authenticated access. Service role only via SECURITY DEFINER functions.

### 4.4 `private.blocked_terms`

```sql
CREATE TABLE IF NOT EXISTS private.blocked_terms (
  id        uuid  PRIMARY KEY DEFAULT gen_random_uuid(),
  term      text  NOT NULL UNIQUE,
  added_at  timestamptz NOT NULL DEFAULT clock_timestamp(),
  added_by  text  NOT NULL,
  CONSTRAINT blocked_terms_term_check CHECK (length(trim(term)) BETWEEN 1 AND 100)
);
```

Used by DB trigger functions (Section 5). Updates to this table take effect immediately for all subsequent inserts/updates without a migration.

### 4.5 `private.moderators`

```sql
CREATE TABLE IF NOT EXISTS private.moderators (
  profile_id  uuid PRIMARY KEY REFERENCES public.profiles(id) ON DELETE RESTRICT,
  added_at    timestamptz NOT NULL DEFAULT clock_timestamp()
);
```

All SECURITY DEFINER moderation functions validate that `p_moderator_id` exists in this table before proceeding. The developer/admin's profile UUID is inserted at migration time (a separate service-role operation after the migration runs).

### 4.6 `private.profile_suspensions`

Suspension details are private. Only `is_suspended boolean` goes on `public.profiles`.

```sql
CREATE TABLE IF NOT EXISTS private.profile_suspensions (
  profile_id        uuid        PRIMARY KEY REFERENCES public.profiles(id) ON DELETE RESTRICT,
  is_suspended      boolean     NOT NULL DEFAULT false,
  suspended_at      timestamptz,
  suspension_reason text,
  suspended_by      uuid        REFERENCES public.profiles(id) ON DELETE RESTRICT,
  CONSTRAINT ps_consistency_check CHECK (
    (is_suspended = false AND suspended_at IS NULL AND suspension_reason IS NULL AND suspended_by IS NULL)
    OR
    (is_suspended = true  AND suspended_at IS NOT NULL AND suspension_reason IS NOT NULL AND suspended_by IS NOT NULL)
  )
);
```

A row in `private.profile_suspensions` is created (or upserted) for every profile when the profile is created, with `is_suspended = false`. This makes joins simple. The `suspend_user` and `reinstate_user` functions update this row.

**`public.profiles` suspension column:**

```sql
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS is_suspended boolean NOT NULL DEFAULT false;
```

Only `is_suspended` is on `public.profiles`. The `suspend_user` function updates BOTH `public.profiles.is_suspended` AND `private.profile_suspensions` atomically, keeping them in sync. Group members reading a profile see `is_suspended` but never see `suspended_at`, `suspension_reason`, or `suspended_by`.

### 4.7 `private.moderation_evidence`

Evidence snapshots preserved for moderator review with a defined retention period.

```sql
CREATE TABLE IF NOT EXISTS private.moderation_evidence (
  id                    uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  moderation_action_id  uuid        NOT NULL
                                    REFERENCES public.moderation_actions(id) ON DELETE RESTRICT,
  evidence_type         text        NOT NULL,
  evidence_text         text,
  evidence_media_key    text,       -- storage path of the offending photo (for rejected/removed media)
  retained_until        timestamptz NOT NULL DEFAULT (clock_timestamp() + interval '90 days'),
  created_at            timestamptz NOT NULL DEFAULT clock_timestamp(),

  CONSTRAINT me_evidence_type_check
    CHECK (evidence_type IN ('comment_text','clue_text','media_key'))
);

CREATE INDEX ON private.moderation_evidence (retained_until);
```

Retention: 90 days. Evidence rows older than `retained_until` may be deleted by a service-level cleanup job. This is a V1 operational commitment; the cleanup job is out of scope for this step.

### 4.8 Additions to `public.challenges`

```sql
ALTER TABLE public.challenges
  ADD COLUMN IF NOT EXISTS moderator_removed_at timestamptz;
```

When a moderator removes a challenge, `moderator_removed_at = now()` is set and the challenge state transitions to `'cancelled'` with `cancellation_reason = 'moderation_action'`. The `media-serve` Edge Function checks both `media_objects.status` and `challenges.moderator_removed_at IS NOT NULL`. If either condition fails, it returns `403 FK_FORBIDDEN`.

The `protect_challenge_authority_fields` trigger currently blocks direct UPDATE of `cancellation_reason`. The `remove_content` function runs as `forkensics_executor`, which bypasses that trigger.

### 4.9 Additions to `public.comments`

```sql
ALTER TABLE public.comments
  ADD COLUMN IF NOT EXISTS moderator_removed_at timestamptz;
```

When a moderator removes a comment, `moderator_removed_at = now()` and `text = '[removed by moderator]'`. The original text is stored in `private.moderation_evidence` before being overwritten. The `text` field remains `NOT NULL`; the placeholder satisfies the constraint and existing length check (28 characters, well within 1–1000).

The V2 migration replaces the `restrict_comment_updates` trigger function body to add a `forkensics_executor` bypass at the top (same pattern as other V1 trigger functions). This allows `remove_content` to update both `text` and `moderator_removed_at`.

### 4.10 Additions to `public.media_objects`

```sql
-- Add moderated_at (set when photo is approved or rejected, distinct from re_encoded_at)
ALTER TABLE public.media_objects
  ADD COLUMN IF NOT EXISTS moderated_at timestamptz;
```

`re_encoded_at` is set when re-encoding completes (in `finalize_upload_session`). `moderated_at` is set when `approve_photo` or `reject_photo` is called.

**Status constraint (full set for V2 migration):**
```
('processing','ready','failed','deleted','superseded','cleaned','pending_review','rejected','removed')
```

- `pending_review`: set by `finalize_upload_session`; challenge cannot activate
- `rejected`: set by `reject_photo`; cleanup worker handles storage deletion
- `removed`: set by `remove_content` when a challenge is moderator-removed; unservable immediately; cleanup worker handles storage deletion

### 4.11 `private.blocked_terms` and text filtering

Section 5 (text filter trigger) describes the enforcement mechanism.

---

## Section 5 — Text Filtering (DB Trigger)

### 5.1 Trigger function

```sql
CREATE OR REPLACE FUNCTION private.check_text_content_trigger()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_text text;
BEGIN
  -- Determine which field to check based on table and column context
  -- This trigger is attached per-table with a named column parameter via TG_ARGV
  v_text := CASE TG_TABLE_NAME
    WHEN 'comments'       THEN NEW.text
    WHEN 'clues'          THEN NEW.text
    WHEN 'profiles'       THEN NEW.display_name
    WHEN 'groups'         THEN NEW.name
    WHEN 'challenge_secrets' THEN
      CASE TG_ARGV[0]
        WHEN 'display_dish'       THEN NEW.display_dish
        WHEN 'display_restaurant' THEN NEW.display_restaurant
        ELSE NULL
      END
    WHEN 'challenges'     THEN NEW.public_city_display
    ELSE NULL
  END;

  IF v_text IS NULL THEN
    RETURN NEW;
  END IF;

  -- Case-insensitive substring search against blocked_terms
  IF EXISTS (
    SELECT 1 FROM private.blocked_terms
    WHERE position(lower(term) IN lower(v_text)) > 0
  ) THEN
    RAISE EXCEPTION 'FK_CONTENT_FILTERED: content contains a blocked term';
  END IF;

  RETURN NEW;
END;
$$;
```

**Note on `TG_ARGV`:** PostgreSQL trigger functions can receive arguments via `TG_ARGV` when triggers are created with arguments (`EXECUTE FUNCTION private.check_text_content_trigger('display_dish')`). This allows the same function to inspect different fields on `challenge_secrets`.

**Owned by:** `forkensics_executor`. This function accesses `private.blocked_terms`; `forkensics_executor` has SELECT on `private.blocked_terms`.

### 5.2 Trigger attachments

```sql
-- comments (INSERT only; moderator replacement of text is via forkensics_executor bypass)
CREATE OR REPLACE TRIGGER comment_text_filter
  BEFORE INSERT ON public.comments
  FOR EACH ROW EXECUTE FUNCTION private.check_text_content_trigger();

-- clues
CREATE OR REPLACE TRIGGER clue_text_filter
  BEFORE INSERT ON public.clues
  FOR EACH ROW EXECUTE FUNCTION private.check_text_content_trigger();

-- profiles (display_name; INSERT and UPDATE)
CREATE OR REPLACE TRIGGER profile_name_filter
  BEFORE INSERT OR UPDATE ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION private.check_text_content_trigger();

-- groups (name; INSERT and UPDATE)
CREATE OR REPLACE TRIGGER group_name_filter
  BEFORE INSERT OR UPDATE ON public.groups
  FOR EACH ROW EXECUTE FUNCTION private.check_text_content_trigger();

-- challenge_secrets (display_dish on INSERT and UPDATE before first guess)
CREATE OR REPLACE TRIGGER secret_dish_filter
  BEFORE INSERT OR UPDATE ON public.challenge_secrets
  FOR EACH ROW EXECUTE FUNCTION private.check_text_content_trigger('display_dish');

-- challenge_secrets (display_restaurant)
CREATE OR REPLACE TRIGGER secret_restaurant_filter
  BEFORE INSERT OR UPDATE ON public.challenge_secrets
  FOR EACH ROW EXECUTE FUNCTION private.check_text_content_trigger('display_restaurant');

-- challenges (public_city_display)
CREATE OR REPLACE TRIGGER challenge_city_filter
  BEFORE INSERT OR UPDATE ON public.challenges
  FOR EACH ROW EXECUTE FUNCTION private.check_text_content_trigger();
```

`forkensics_executor` bypasses all these triggers (SECURITY DEFINER bypass pattern is in the trigger function itself via `current_user = 'forkensics_executor'` check — add this to the function body). This ensures moderation actions (which run as `forkensics_executor`) can set `'[removed by moderator]'` without being blocked.

**Updated trigger function with bypass:**
```sql
-- Add at the top of private.check_text_content_trigger, before the text extraction:
IF current_user = 'forkensics_executor' THEN
  RETURN NEW;
END IF;
```

### 5.3 Edge Function `check_text_content` function

The `public.check_text_content(text) → boolean` function from Rev 1 is retained for Edge Functions that want to validate text before attempting an INSERT (for better error messaging to the client). The trigger is the authoritative enforcement; the function provides an early check.

---

## Section 6 — Suspension and Block Enforcement in RLS

### 6.1 Suspension in RLS

For every table where authenticated users can INSERT or UPDATE content, the RLS policy adds a suspension check. Pattern:

```sql
-- Example: comments INSERT policy (existing V1 policy is SELECT-only for inserts via trigger)
-- The existing comments INSERT policy is currently open (rely on triggers + group membership).
-- V2 adds suspension enforcement:
CREATE POLICY comments_insert_not_suspended ON public.comments
  FOR INSERT TO authenticated
  WITH CHECK (
    private.is_challenge_group_member(challenge_id)
    AND NOT EXISTS (
      SELECT 1 FROM public.profiles
      WHERE id = private.auth_uid() AND is_suspended = true
    )
  );
```

Applied to: `comments`, `clues`, `reactions`, `guess_attempts`, `group_members` (invite redemption), `challenge_answer_aliases`.

Note: The `set_guess_receipt_fields` trigger already enforces challenge state; the RLS adds the suspension layer. The combination is defense-in-depth.

### 6.2 Block enforcement in RLS — new interactions

When A has blocked B or B has blocked A, neither may submit new interactions on each other's content. Implemented via RLS INSERT policies that check `user_blocks` in both directions.

Helper function (added to `forkensics_rls_helper`):

```sql
CREATE OR REPLACE FUNCTION private.has_block_with_poster(p_challenge_id uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.challenges c
    JOIN public.user_blocks ub
      ON (ub.blocker_id = private.auth_uid() AND ub.blocked_id = c.poster_id)
      OR (ub.blocker_id = c.poster_id AND ub.blocked_id = private.auth_uid())
    WHERE c.id = p_challenge_id
  );
$$;
```

```sql
CREATE OR REPLACE FUNCTION private.has_block_with(p_profile_id uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.user_blocks
    WHERE (blocker_id = private.auth_uid() AND blocked_id = p_profile_id)
       OR (blocker_id = p_profile_id    AND blocked_id = private.auth_uid())
  );
$$;
```

**INSERT policies for blocked-pair prevention:**

```sql
-- guess_attempts: no new guesses on a challenge where the poster is a blocked pair
CREATE POLICY guess_attempts_no_block ON public.guess_attempts
  FOR INSERT TO authenticated
  WITH CHECK (
    NOT private.has_block_with_poster(challenge_id)
  );

-- comments: no new comments on a challenge where poster is a blocked pair
CREATE POLICY comments_no_block ON public.comments
  FOR INSERT TO authenticated
  WITH CHECK (
    NOT private.has_block_with_poster(challenge_id)
  );

-- reactions: same
CREATE POLICY reactions_no_block ON public.reactions
  FOR INSERT TO authenticated
  WITH CHECK (
    NOT private.has_block_with_poster(challenge_id)
  );

-- clues: the poster is always the clue author; blocked participants cannot
-- interact with the challenge (handled by guess/comment/reaction policies above)
-- No additional clue INSERT block needed (poster posts clues, not participants)
```

### 6.3 Block enforcement in RLS — content visibility

When A blocks B, A does not see B's comments or reactions on shared challenges. This applies bidirectionally.

```sql
-- Comments SELECT: hide comments from blocked authors (either direction)
-- This replaces/augments the existing V1 comments SELECT policy
-- V2 policy adds the block check:
CREATE POLICY comments_select_no_block ON public.comments
  FOR SELECT TO authenticated
  USING (
    private.is_challenge_group_member(challenge_id)
    AND NOT private.has_block_with(author_id)
    AND (deleted_at IS NULL OR author_id = private.auth_uid())  -- own deleted comments still visible
  );

-- Reactions SELECT: hide reactions from blocked users
CREATE POLICY reactions_select_no_block ON public.reactions
  FOR SELECT TO authenticated
  USING (
    private.is_challenge_group_member(challenge_id)
    AND NOT private.has_block_with(player_id)
  );
```

**Challenge visibility and blocks:**

New challenges (posted after the block is set) do not appear to the blocked pair. Existing active challenges that both parties are already participating in remain visible; the block prevents only new interactions.

```sql
-- Challenges SELECT: hide challenges where poster is a blocked pair
-- (applies to all states including active; existing participants retain visibility via a carve-out)
-- Proposed policy addition:
CREATE POLICY challenges_select_no_block ON public.challenges
  FOR SELECT TO authenticated
  USING (
    (
      private.is_group_member(group_id)
      AND NOT private.has_block_with(poster_id)
    )
    OR
    -- Carve-out: eligible participants in an active/locked challenge retain visibility
    -- even if a block was set after they became eligible
    EXISTS (
      SELECT 1 FROM public.eligible_participants
      WHERE challenge_id = id AND player_id = private.auth_uid()
    )
    OR
    -- Poster always sees their own challenges
    poster_id = private.auth_uid()
  );
```

### 6.4 V1 `restrict_comment_updates` trigger replacement

V2 replaces the function body to add the `forkensics_executor` bypass:

```sql
CREATE OR REPLACE FUNCTION public.restrict_comment_updates()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  -- forkensics_executor bypass: allows moderator removal of comment text
  IF current_user = 'forkensics_executor' THEN
    RETURN NEW;
  END IF;

  -- ... remainder of V1 body unchanged ...
END;
$$;
```

---

## Section 7 — Changes to V1 Functions

### 7.1 `activate_challenge` — V2 replacement (block exclusion)

The eligible-participant snapshot adds exclusion of blocked pairs:

```sql
-- Block pair exclusion added to the INSERT in activate_challenge:
AND NOT EXISTS (
  SELECT 1 FROM public.user_blocks ub
  WHERE (ub.blocker_id = private.auth_uid() AND ub.blocked_id = gm.player_id)
     OR (ub.blocker_id = gm.player_id AND ub.blocked_id = private.auth_uid())
)
-- Suspension check added to caller guard:
-- (already checked by is_active; add is_suspended check)
AND p.is_suspended = false  -- suspended members excluded from eligible participants
```

Also adds suspension guard for the poster (suspended user cannot activate a challenge):

```sql
IF EXISTS (
  SELECT 1 FROM public.profiles WHERE id = private.auth_uid() AND is_suspended = true
) THEN RAISE EXCEPTION 'suspended account cannot activate a challenge'; END IF;
```

### 7.2 Suspension guard additions to other V1 executor functions

V2 replaces the active-profile guard in the following functions to add `is_suspended = false`:
- `create_group_invite` (suspended users cannot create invites)
- `redeem_group_invite` (suspended users cannot join new groups)
- `create_group` (suspended users cannot create groups)

Suspended users **may still call:**
- `report_content`, `block_user`, `unblock_user` (safety actions; always permitted)
- `reveal_challenge`, `cancel_challenge` (close their own in-progress challenges)
- Account deletion flow

---

## Section 8 — Function Contracts

All new public SECURITY DEFINER functions: owned by `forkensics_executor`, `SET search_path = ''`, EXECUTE granted as specified.

### 8.1 `public.report_content`

**Callers:** Authenticated. EXECUTE granted to `authenticated`.

```
public.report_content(
  p_target_type text,
  p_target_id   uuid,
  p_category    text,
  p_detail      text   -- nullable
) → (report_id uuid)
```

Behavior:
1. Active, onboarded caller. Suspended users may report.
2. Validates `target_type` IN ('challenge','comment','clue','profile','media_object').
3. **Access verification** (returns `FK_NOT_FOUND` for both nonexistent and unauthorized targets):
   - `'challenge'`: target must exist and caller must be a group member (`private.is_challenge_group_member`)
   - `'comment'`: target comment must exist; challenge must be accessible to caller
   - `'clue'`: target clue must exist; challenge must be accessible to caller
   - `'profile'`: target profile must exist; caller must share at least one group with the target (using `private.is_group_member_with`)
   - `'media_object'`: associated challenge must be accessible to caller
4. Prevents self-report.
5. **Rate limiting:** Caller must not have submitted more than 10 reports in the past hour. Raises `FK_RATE_LIMITED` if exceeded.
6. Inserts `content_reports` row. Uniqueness constraint is scoped to `status = 'pending'` only — a new report is accepted if the prior report on the same target+category was already resolved.
7. Returns `report_id`.

### 8.2 `public.block_user`

**Callers:** Authenticated. EXECUTE granted to `authenticated`.

```
public.block_user(p_blocked_id uuid) → void
```

Behavior:
1. Active caller. Suspended users may block.
2. Self-block prevented.
3. Target profile must exist.
4. Idempotent INSERT.

**Immediate effect:** The INSERT into `user_blocks` takes effect immediately. All subsequent RLS-guarded queries that call `private.has_block_with` or `private.has_block_with_poster` will reflect the new block. No additional state transitions are needed.

### 8.3 `public.unblock_user`

**Callers:** Authenticated. EXECUTE granted to `authenticated`.

```
public.unblock_user(p_blocked_id uuid) → void
```

DELETEs the block row where `blocker_id = auth_uid()`. Idempotent.

### 8.4 `public.approve_photo`

**Callers:** Service role. EXECUTE granted to `service_role`.

```
public.approve_photo(
  p_media_object_id uuid,
  p_moderator_id    uuid,
  p_reason          text
) → void
```

Behavior:
1. Validates `p_moderator_id` is in `private.moderators`.
2. Verifies `media_objects.status = 'pending_review'` → else raises `FK_WRONG_STATE`.
3. Sets `media_objects.status = 'ready'`, `moderated_at = now()`. (`re_encoded_at` was already set by `finalize_upload_session`.)
4. Inserts `moderation_actions`.

### 8.5 `public.reject_photo`

**Callers:** Service role. EXECUTE granted to `service_role`.

```
public.reject_photo(
  p_media_object_id uuid,
  p_moderator_id    uuid,
  p_reason          text
) → void
```

Behavior:
1. Validates moderator.
2. Verifies `status = 'pending_review'`.
3. Sets `media_objects.status = 'rejected'`, `moderated_at = now()`.
4. Stores `private.media_storage_keys.re_encoded_storage_key` in `private.moderation_evidence` (evidence_type = 'media_key') before the storage object is enqueued for deletion.
5. Inserts `moderation_actions`.

The cleanup worker's `get_rejected_media_to_clean` (Section 8.14) handles storage deletion after rejection.

**Poster-facing status:** The poster calls `get_poster_media_status` (Section 8.13) to learn the state. They see `status = 'rejected'` and a sanitized reason. They do not see moderator notes.

### 8.6 `public.remove_content`

**Callers:** Service role. EXECUTE granted to `service_role`.

```
public.remove_content(
  p_target_type  text,   -- 'challenge' | 'comment' | 'clue'
  p_target_id    uuid,
  p_moderator_id uuid,
  p_report_id    uuid,   -- nullable
  p_reason       text
) → void
```

**For `'comment'`:**
1. Validates moderator.
2. Reads and stores original `text` into `private.moderation_evidence` (evidence_type = 'comment_text').
3. Updates `comments` SET `text = '[removed by moderator]'`, `moderator_removed_at = now()`. (Runs as `forkensics_executor`; `restrict_comment_updates` bypass applies.)
4. Inserts `moderation_actions`.
5. If `p_report_id` non-NULL, sets `content_reports.status = 'actioned'`, `reviewed_at = now()`, `reviewed_by = p_moderator_id`.

**For `'clue'`:**
1. Validates moderator.
2. Stores original `text` in `private.moderation_evidence`.
3. Clues are not editable in V1. Proposed handling: add `moderator_removed_at timestamptz` to `public.clues` in the V2 migration. RLS SELECT for clues excludes rows with `moderator_removed_at IS NOT NULL`.
4. Inserts `moderation_actions`.
5. Actions report if provided.

**For `'challenge'`:**
1. Validates moderator.
2. Sets `challenges.moderator_removed_at = now()`, `state = 'cancelled'`, `cancellation_reason = 'moderation_action'`.
3. Sets `media_objects.status = 'removed'` for the challenge's `media_object_id` (immediately unservable).
4. Stores the `re_encoded_storage_key` in `private.moderation_evidence` (evidence_type = 'media_key').
5. Inserts `moderation_actions`.
6. Actions report if provided.

The cleanup worker handles deletion of `removed` media objects.

### 8.7 `public.suspend_user`

**Callers:** Service role. EXECUTE granted to `service_role`.

```
public.suspend_user(p_profile_id uuid, p_moderator_id uuid, p_reason text) → void
```

Behavior:
1. Validates moderator.
2. Verifies profile exists and `is_active = true`.
3. Idempotent if already suspended.
4. Atomically:
   - Sets `public.profiles.is_suspended = true`
   - Upserts `private.profile_suspensions` with `is_suspended = true`, `suspended_at = now()`, `suspension_reason = p_reason`, `suspended_by = p_moderator_id`
5. Inserts `moderation_actions`.

### 8.8 `public.reinstate_user`

**Callers:** Service role. EXECUTE granted to `service_role`.

```
public.reinstate_user(p_profile_id uuid, p_moderator_id uuid, p_reason text) → void
```

Behavior:
1. Validates moderator.
2. Verifies `is_suspended = true`.
3. Atomically:
   - Sets `public.profiles.is_suspended = false`
   - Updates `private.profile_suspensions` (is_suspended = false, clears reason/timestamps)
4. Inserts `moderation_actions`.

### 8.9 `public.dismiss_report`

**Callers:** Service role. EXECUTE granted to `service_role`.

```
public.dismiss_report(p_report_id uuid, p_moderator_id uuid, p_reason text) → void
```

Validates moderator. Sets `content_reports.status = 'dismissed'`, `reviewed_at = now()`, `reviewed_by = p_moderator_id`. No `resolution_note` stored on the public record; moderator reasoning is recorded in `moderation_actions.reason`.

### 8.10 `public.action_report`

**Callers:** Service role. EXECUTE granted to `service_role`.

```
public.action_report(p_report_id uuid, p_moderator_id uuid, p_reason text) → void
```

Sets `content_reports.status = 'actioned'`, `reviewed_at`, `reviewed_by`. Used when the moderation action is recorded separately (e.g., `remove_content` already actions the report inline).

### 8.11 `public.get_moderation_queue`

**Callers:** Service role. EXECUTE granted to `service_role`.

```
public.get_moderation_queue() → TABLE(
  queue_type        text,
  item_id           uuid,
  created_at        timestamptz,
  reporter_id       uuid,
  target_type       text,
  target_id         uuid,
  category          text,
  challenge_id      uuid
)
```

Returns:
- `queue_type = 'pending_report'`: all `content_reports WHERE status = 'pending'`
- `queue_type = 'pending_review_photo'`: all `media_objects WHERE status = 'pending_review'` (joined to upload_sessions for challenge_id)

Ordered by `created_at ASC` (oldest first).

### 8.12 `public.get_pending_review_media_key`

**Callers:** Service role. EXECUTE granted to `service_role`.

```
public.get_pending_review_media_key(p_media_object_id uuid)
→ TABLE(re_encoded_storage_key text, challenge_id uuid, uploader_id uuid)
```

Returns the storage key for a `pending_review` media object so the moderator can view it. Returns no row if `status != 'pending_review'`. The moderator retrieves the image using a service-role signed URL generated externally; this function provides the key.

Normal `media-serve` returns `404 FK_NOT_FOUND` for `pending_review` objects (it checks `status = 'ready'`).

### 8.13 `public.get_report_for_review`

**Callers:** Service role. EXECUTE granted to `service_role`.

```
public.get_report_for_review(p_report_id uuid)
→ TABLE(
    report_id         uuid,
    reporter_id       uuid,
    target_type       text,
    target_id         uuid,
    category          text,
    detail            text,
    status            text,
    created_at        timestamptz,
    target_summary    text    -- extracted from target: comment text, clue text, or NULL for challenges/media
  )
```

Fetches the full report plus a content summary of the target for moderator review. For `'comment'` targets, `target_summary = comments.text`. For `'clue'` targets, `target_summary = clues.text`. For `'challenge'` targets, returns challenge display metadata (no secrets). For `'media_object'` targets, returns NULL summary (moderator uses `get_pending_review_media_key`).

### 8.14 `public.get_poster_media_status`

**Callers:** Service role (called by Edge Function on behalf of poster). EXECUTE granted to `service_role`.

```
public.get_poster_media_status(p_media_object_id uuid, p_uploader_id uuid)
→ TABLE(status text, rejection_message text)
```

Returns the media object's status and, if `'rejected'`, a sanitized user-facing message ("Photo couldn't be approved — choose another photo."). Does not return moderator notes, `moderated_at`, or `private.moderation_evidence` content. Returns no row if the media object does not belong to `p_uploader_id`.

### 8.15 `public.get_rejected_media_to_clean`

**Callers:** Service role (cleanup worker). EXECUTE granted to `service_role`.

```
public.get_rejected_media_to_clean()
→ TABLE(media_object_id uuid, re_encoded_storage_key text)
```

Returns `media_objects WHERE status IN ('rejected','removed')` joined to `media_storage_keys`. The cleanup worker deletes these storage objects and then calls `mark_superseded_media_cleaned` (or a new `mark_media_removed_cleaned` function) to set `status = 'cleaned'`.

### 8.16 `public.check_text_content`

**Callers:** Edge Functions (early validation). EXECUTE granted to `service_role`.

```
public.check_text_content(p_text text) → boolean
```

Returns `true` if content passes (no blocked terms). Edge Functions call this for early rejection before attempting INSERT. The DB trigger is the authoritative enforcement.

---

## Section 9 — Additions to `public.clues`

```sql
ALTER TABLE public.clues
  ADD COLUMN IF NOT EXISTS moderator_removed_at timestamptz;
```

RLS SELECT for clues (V2 replacement): adds `AND moderator_removed_at IS NULL` to the existing visibility check. Moderator-removed clues are hidden from all authenticated users.

---

## Section 10 — V1 RLS Policy Replacements

The following V1 RLS policies are replaced in the V2 migration. For each, the V1 policy is dropped and the V2 policy is created.

| Table | Policy | V2 addition |
|---|---|---|
| `public.comments` | SELECT | Exclude comments from blocked authors; exclude moderator-removed comments from non-posters |
| `public.comments` | INSERT | Require `is_suspended = false`; require no block with challenge poster |
| `public.reactions` | SELECT | Exclude reactions from blocked users |
| `public.reactions` | INSERT | Require `is_suspended = false`; require no block with challenge poster |
| `public.guess_attempts` | INSERT | Require `is_suspended = false`; require no block with challenge poster |
| `public.clues` | SELECT | Exclude moderator-removed clues |
| `public.clues` | INSERT | Require `is_suspended = false` |
| `public.challenges` | SELECT | Hide challenges where poster is a blocked pair (with carve-out for existing eligible participants) |
| `public.group_members` | INSERT | Require `is_suspended = false` (invite redemption) |

---

## Section 11 — Cleanup Worker Additions

The upload-cleanup-worker (Step 24 Section 4.6) gains two new parts:

**Part 4 — Rejected and removed media cleanup:**
1. Call `get_rejected_media_to_clean()`.
2. For each: delete `re_encoded_storage_key` from storage. Absent = no-op.
3. If deleted: call `mark_superseded_media_cleaned(media_object_id)` (which sets `status = 'cleaned'`). The existing function handles any terminal-to-cleaned transition; or create `mark_media_cleaned(uuid)` as a generalized version.

**Part 5 — Moderation evidence retention cleanup (V1 operational; not in this step):** Defined as a future service-level job.

---

## Section 12 — Apple Reviewer Seed Procedure

The seed must be internally testable by the reviewer account — the reviewer must be able to demonstrate reporting, blocking, and gameplay within their own account.

**Seed contents:**

| Item | Detail |
|---|---|
| Reviewer account (`reviewer@forkensics.review`) | Active, onboarded, member of review group |
| Player 2 (`player2@forkensics.review`) | Active; has posted a mystery (photo pre-approved) |
| Player 3 (`player3@forkensics.review`) | Active; reviewer has already blocked Player 3 in seed data |
| Mystery 1 (Player 2) | **Active**; reviewer can submit a guess immediately; photo already `approved` |
| Mystery 2 (Player 2) | **Revealed**; scores and Table Talk comments visible |
| Mystery 3 (Player 2) | **Revealed with Clue**; clue flow demonstrated |
| Mystery 4 (Player 2) | **Revealed**; leaderboard result visible |
| Block example | Reviewer has blocked Player 3 (seed data); reviewer can also unblock and re-block in-app |
| Report example | A seeded comment from Player 2 that reviewer can report; confirmation UI shown after report submitted |

**Photo approval plan during App Review:** All seeded mysteries use pre-approved photos. If the reviewer submits a new mystery via the posting flow, the photo will land in `pending_review`. Review Notes must state: "If you post a mystery, the photo requires moderation approval before the challenge can go live. Please email [support address] and we will approve it within [N] hours." An active moderation process must be running during the App Review window.

**Seed procedure requirements:**
- Repeatable: runnable against a clean dev environment
- Production-safe: uses only fictional players and stock/synthetic food photos
- Idempotent: a second run produces no errors and no duplicate data
- Documented: a written procedure checked into the repo (not applied automatically)

---

## Section 13 — Acceptance Criteria and Test Matrix

### 13.1 Text filtering

- INSERT comment with blocked term → trigger raises `FK_CONTENT_FILTERED`
- INSERT clue with blocked term → trigger raises
- UPDATE profile display_name with blocked term → trigger raises
- INSERT group name with blocked term → trigger raises
- Adding a new term to `private.blocked_terms` → next INSERT with that term is blocked (no migration required)
- `forkensics_executor` INSERT with blocked term → trigger bypasses; INSERT succeeds
- Comment with no blocked terms → INSERT succeeds

### 13.2 Suspension

- Suspended user INSERT into comments → RLS WITH CHECK fails
- Suspended user INSERT into clues → fails
- Suspended user INSERT into reactions → fails
- Suspended user INSERT into guess_attempts → fails
- Suspended user calls `create_group_invite` → SECURITY DEFINER guard raises
- Suspended user calls `block_user` → allowed (safety action)
- Suspended user calls `report_content` → allowed
- Suspended user calls account deletion → allowed
- Unsuspended user after `reinstate_user` → all INSERT policies pass

### 13.3 Blocking — content prevention (bidirectional)

- A blocks B; B attempts INSERT into `guess_attempts` on A's challenge → RLS WITH CHECK fails (block in both directions checked)
- A blocks B; A attempts INSERT into `comments` on B's challenge → RLS WITH CHECK fails
- A blocks B; B attempts INSERT into `reactions` on A's challenge → fails
- No block; all above actions succeed

### 13.4 Blocking — content visibility

- A blocks B; A queries `comments` on a shared challenge → B's comments not returned
- A blocks B; B queries `comments` → A's comments not returned (bidirectional hiding)
- A blocks B; A queries `reactions` → B's reactions not returned
- A blocks B; A queries `challenges` → B's new challenges (posted after block) not returned
- A blocks B; A is already an eligible participant in B's active challenge → challenge still visible (carve-out applies)
- A blocks B; B queries `user_blocks` → A's block row NOT returned (blocker_id = auth_uid() only)

### 13.5 Blocking — eligibility

- A blocks B; A posts a new challenge and calls `activate_challenge` → B not included in `eligible_participants`
- No block; all group members included (existing V1 test still passes)

### 13.6 Reporting — access verification

- Reporter tries to report a challenge in a group they don't belong to → `FK_NOT_FOUND`
- Reporter tries to report a profile with whom they share no group → `FK_NOT_FOUND`
- Reporter reports a valid accessible target → report created
- Same reporter submits the same target+category report twice while first is pending → idempotent; returns existing report_id
- Same reporter submits after prior report is resolved (actioned/dismissed) → new report created
- Reporter submits 11 reports in one hour → 11th raises `FK_RATE_LIMITED`

### 13.7 Moderator identity validation

- `approve_photo` with `p_moderator_id` not in `private.moderators` → raises
- `reject_photo` with valid moderator → succeeds
- `suspend_user` with invalid moderator → raises
- `remove_content` with invalid moderator → raises

### 13.8 Photo gate

- `finalize_upload_session` → `media_objects.status = 'pending_review'`; `re_encoded_at` set
- `activate_challenge` with `media_object_id` pointing to `pending_review` → V2 trigger raises
- `approve_photo` → `status = 'ready'`; `moderated_at` set; `activate_challenge` now succeeds
- `reject_photo` → `status = 'rejected'`; evidence stored in `private.moderation_evidence`
- `media-serve` with `pending_review` media → 404 FK_NOT_FOUND
- `media-serve` with `rejected` media → 404 FK_NOT_FOUND
- `media-serve` with `ready` media → 200 with image

### 13.9 Comment removal

- `remove_content('comment', ...)` → `comments.text = '[removed by moderator]'`; `moderator_removed_at` set; original text in `private.moderation_evidence`
- Subsequent SELECT of the comment → placeholder text returned, not original
- `private.moderation_evidence` row not accessible via PostgREST

### 13.10 Challenge removal

- `remove_content('challenge', ...)` → `challenges.state = 'cancelled'`; `moderator_removed_at` set; `media_objects.status = 'removed'`
- `media-serve` after removal → 403 FK_FORBIDDEN
- `get_rejected_media_to_clean` → returns `removed` media; cleanup worker deletes from storage

### 13.11 Suspension and private schema separation

- SELECT `public.profiles` for a suspended user → `is_suspended = true` visible; NO `suspended_at`, `suspension_reason`, `suspended_by` column visible
- `private.profile_suspensions` not accessible through PostgREST
- `public.moderation_actions` not accessible to authenticated users (no SELECT policy)

### 13.12 Reviewer seed testability

- Reviewer account can submit a guess on Mystery 1 and see a result
- Reviewer account can report a seeded comment and receive confirmation
- Reviewer account can unblock Player 3 and re-block them
- Reviewer account can observe a revealed mystery with Table Talk
- Photo approval plan documented in Review Notes

---

## Section 14 — Open Questions for Codex/GPT Review

1. **`comments.text` NOT NULL + placeholder:** The current V1 constraint `CHECK (length(trim(text)) BETWEEN 1 AND 1000)` allows `'[removed by moderator]'` (28 characters). No ALTER needed for the text field itself. Confirm this is the correct approach, or should `moderator_removed_at IS NOT NULL` signal removal and the text field remain unchanged (leaving original text in the DB alongside the moderator timestamp)?

   **Proposal:** Clear text to placeholder. Keeps public table clean; original text in private evidence.

2. **Block carve-out for existing eligible participants:** The proposed challenge SELECT carve-out allows B to continue seeing A's active challenge if B was already eligible when the block was set. Is this the right balance, or should the challenge become hidden immediately and B's in-progress participation be suspended?

   **Proposal:** Carve-out is correct. Retroactive removal is disruptive and creates confusing gameplay states. Block applies to new challenges only.

3. **`moderation_actions` immutability trigger:** Identical to V1's `protect_rules_versions` trigger. Confirm the same pattern (BEFORE UPDATE OR DELETE → raise exception) is sufficient.

---

## Section 15 — Success Criteria for Step 24.1

- [ ] Text filtering via DB triggers agreed; all covered fields confirmed
- [ ] `forkensics_executor` bypass in text filter trigger agreed
- [ ] `private.blocked_terms` updateable without migration confirmed
- [ ] Suspension in RLS mutation policies agreed; `private.profile_suspensions` schema agreed
- [ ] `is_suspended` only column on `public.profiles` agreed
- [ ] Block enforcement server-side and immediate via RLS agreed
- [ ] `user_blocks` SELECT shows only blocker's own rows agreed
- [ ] Block bidirectional content hiding agreed (comments, reactions, challenges with carve-out)
- [ ] Block prevents new interactions (guess, comment, reaction) between blocked pairs agreed
- [ ] Block applies to future eligibility only; no retroactive removal from active challenges agreed
- [ ] `private.moderators` table and validation in all moderation functions agreed
- [ ] `private.moderation_evidence` schema and 90-day retention agreed
- [ ] Comment text replaced with placeholder; original in evidence agreed
- [ ] `moderator_removed_at` on challenges, comments, clues agreed
- [ ] `media_objects` status: `pending_review`, `rejected`, `removed` agreed
- [ ] `re_encoded_at` set at re-encoding time; `moderated_at` at moderation time agreed
- [ ] Challenge SELECT carve-out for existing eligible participants agreed
- [ ] `remove_content` for challenges: `state = 'cancelled'`, `media_objects.status = 'removed'` agreed
- [ ] `get_pending_review_media_key`, `get_report_for_review`, `get_poster_media_status`, `get_rejected_media_to_clean` agreed
- [ ] Report rate limiting (10 per hour) agreed
- [ ] Report access verification agreed
- [ ] `clue` and `media_object` as reportable target types agreed
- [ ] Duplicate report constraint scoped to unresolved reports only agreed
- [ ] Reviewer seed plan with testable reporting and blocking agreed
- [ ] Photo approval plan during App Review window agreed
- [ ] Open questions answered by Codex/GPT
- [ ] No executable SQL written until governance approval
