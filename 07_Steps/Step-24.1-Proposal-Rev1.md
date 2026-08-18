# Step 24.1 Proposal — Rev 1 — UGC Safety and Moderation Contracts

**Status:** Pending review (Claude → Codex/GPT → Bill approval)
**Governance gate:** Bill must type `APPROVED: Step 24.1 — UGC Safety and Moderation Contracts` before any moderation schema or functions are written as executable SQL or applied to any environment.
**Position in sequence:** Between Step 24 (approved) and Step 25 (on hold). Step 25 must incorporate decisions made here before it can be finalized.
**Authority:** Apple App Review Guideline 1.2 applies to invitation-only private-group apps. UGC safety is non-deferrable if photos and Table Talk ship in V1.

---

## Section 1 — Why This Step Is Required

Forkensics V1 ships:
- User-uploaded food photographs (UGC: images)
- Table Talk comments and reactions (UGC: text)
- Clues (UGC: text)
- Display names (UGC: text)

Apple Guideline 1.2 mandates four capabilities for any app containing UGC, regardless of whether groups are private or invitation-only:

1. Filtering objectionable content
2. Reporting mechanisms with timely developer response
3. Blocking abusive users
4. Published contact information

EXIF stripping satisfies metadata privacy. It does not satisfy objectionable-content filtering. These are separate requirements.

This step defines the database schema, function contracts, and architectural constraints for all UGC safety and moderation functionality. The V2 migration (Step 25) will implement both this step's schema and the upload session infrastructure from Step 24.

---

## Section 2 — Scope

### 2.1 Included

- `public.content_reports` table with RLS
- `public.user_blocks` table with RLS
- `public.moderation_actions` table (immutable administrative audit trail)
- `private.blocked_terms` table (text filter word/phrase list; updateable without an app release)
- `is_suspended` column added to `public.profiles`
- `pending_review` and `rejected` added to `public.media_objects` status constraint
- Replacement of V1's `activate_challenge` function to exclude blocked pairs from eligible participants
- Replacement of V1's `finalize_upload_session` contract: photos land in `pending_review` after re-encoding, not `ready`
- SECURITY DEFINER functions for: report, block/unblock, photo approval/rejection, content removal, user suspension/reinstatement, text content check, moderation queue
- RLS policies for `content_reports` and `user_blocks`
- Internal moderation response target: 24 hours
- Published support email (pre-submission requirement, not a DB change)
- Repeatable Apple reviewer seed procedure (pre-submission requirement, not a DB change)

### 2.2 Excluded

- Swift/SwiftUI implementation of report, block, or moderation UI (separate implementation steps)
- Automated image scanning (ML/hash-based) — the `pending_review` gate provides the slot; human review is V1; AI screening is a V2 addition
- Push notification suppression between blocked pairs (push notifications not yet designed)
- Community guidelines and terms of service text (legal document; not a DB change)
- Age rating questionnaire answers (Bill action before submission)
- Sentry configuration (confirmed as the crash-monitoring choice; setup is a separate step when Swift begins)

---

## Section 3 — Effect on Step 25 (Upload Session Infrastructure)

This step changes two contracts from Step 24/25:

**Change A — `finalize_upload_session`:** After completing re-encoding and deleting the original, the function inserts a `media_objects` row with `status = 'pending_review'` (not `'ready'`). The challenge cannot be activated until a moderator calls `approve_photo`, which transitions the media object to `'ready'`.

**Change B — `activate_challenge`:** The eligible-participant snapshot must exclude group members who have a block relationship (either direction) with the poster. V2 replaces the V1 function body to add this exclusion.

**Change C — `media_objects` status constraint:** The constraint in the V2 migration must allow `'pending_review'` and `'rejected'` in addition to the `'superseded'` and `'cleaned'` values already planned.

**Change D — Standard gate for mutation operations:** Edge Functions and executor functions that currently check `is_active = true AND onboarding_complete = true` must additionally check `is_suspended = false` for operations that produce new content (posting, guessing, commenting, uploading).

---

## Section 4 — Schema

### 4.1 `public.content_reports`

```sql
CREATE TABLE IF NOT EXISTS public.content_reports (
  id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  reporter_id   uuid        NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,

  -- Polymorphic target: challenge, comment, or profile
  target_type   text        NOT NULL,
  target_id     uuid        NOT NULL,  -- no FK; polymorphic; enforced in function

  category      text        NOT NULL,
  detail        text,                  -- optional additional context from reporter

  status        text        NOT NULL DEFAULT 'pending',
  created_at    timestamptz NOT NULL DEFAULT clock_timestamp(),
  reviewed_at   timestamptz,
  reviewed_by   uuid        REFERENCES public.profiles(id) ON DELETE RESTRICT,
  resolution_note text,               -- moderator note on resolution; not shown to reporter

  CONSTRAINT cr_target_type_check
    CHECK (target_type IN ('challenge', 'comment', 'profile')),

  CONSTRAINT cr_category_check
    CHECK (category IN ('inappropriate_image','offensive_content','spam',
                        'harassment','copyright','other')),

  CONSTRAINT cr_status_check
    CHECK (status IN ('pending','reviewed','actioned','dismissed')),

  CONSTRAINT cr_detail_check
    CHECK (detail IS NULL OR length(detail) <= 500),

  CONSTRAINT cr_resolution_note_check
    CHECK (resolution_note IS NULL OR length(resolution_note) <= 500),

  -- Prevent a reporter from submitting duplicate reports for the same target+category
  UNIQUE (reporter_id, target_type, target_id, category)
);

ALTER TABLE public.content_reports ENABLE ROW LEVEL SECURITY;
```

**RLS:**
- `SELECT`: reporter sees only their own reports (`reporter_id = auth_uid()`).
- `INSERT`: blocked via RLS; use `report_content(...)` function instead.
- `UPDATE` / `DELETE`: blocked for all authenticated callers. Only `service_role` via SECURITY DEFINER functions.

**Index:** `CREATE INDEX ON public.content_reports (status, created_at)` — for moderation queue ordering.
**Index:** `CREATE INDEX ON public.content_reports (reporter_id)` — for RLS SELECT.
**Index:** `CREATE INDEX ON public.content_reports (target_type, target_id)` — for looking up reports by target.

### 4.2 `public.user_blocks`

```sql
CREATE TABLE IF NOT EXISTS public.user_blocks (
  blocker_id  uuid        NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  blocked_id  uuid        NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  created_at  timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY (blocker_id, blocked_id),
  CONSTRAINT user_blocks_no_self_block CHECK (blocker_id != blocked_id)
);

ALTER TABLE public.user_blocks ENABLE ROW LEVEL SECURITY;
```

**RLS:**
- `SELECT`: a user sees only their own block rows (either as blocker or blocked). This allows the client to know who they've blocked and to detect if they've been blocked (for UI suppression). Query: `blocker_id = auth_uid() OR blocked_id = auth_uid()`.
- `INSERT` / `UPDATE` / `DELETE`: blocked via RLS; use `block_user` / `unblock_user` functions.

**Index:** `CREATE INDEX ON public.user_blocks (blocked_id)` — for reverse-direction lookups (who has blocked this user).

**Block semantics (both directions are needed for different queries):**
- To check "does A block B or does B block A": `EXISTS (SELECT 1 FROM public.user_blocks WHERE (blocker_id = A AND blocked_id = B) OR (blocker_id = B AND blocked_id = A))`
- `activate_challenge` uses this to exclude blocked pairs from the eligibility snapshot.
- Client uses this to suppress UI elements.

### 4.3 `public.moderation_actions`

Immutable administrative audit trail. No UPDATE or DELETE is permitted on any row.

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
      'photo_approved','photo_rejected',
      'content_removed',
      'user_suspended','user_reinstated',
      'report_actioned','report_dismissed'
    )),

  CONSTRAINT ma_target_type_check
    CHECK (target_type IS NULL OR target_type IN ('challenge','comment','profile','media_object')),

  CONSTRAINT ma_reason_check
    CHECK (length(trim(reason)) BETWEEN 1 AND 500)
);

ALTER TABLE public.moderation_actions ENABLE ROW LEVEL SECURITY;
-- No authenticated access to moderation_actions. Service role only via SECURITY DEFINER functions.
```

**Immutability trigger:** BEFORE UPDATE OR DELETE → raise exception. Identical to `protect_rules_versions` in V1.

**No RLS policies granting SELECT to authenticated.** The table is only queried via service_role.

**Index:** `CREATE INDEX ON public.moderation_actions (target_type, target_id)` — for audit lookups.
**Index:** `CREATE INDEX ON public.moderation_actions (moderator_id, created_at)` — for moderator activity log.

### 4.4 `private.blocked_terms`

Stores the text filter word and phrase list. Updateable without an app release by inserting/deleting rows via service_role. Not accessible through PostgREST.

```sql
CREATE TABLE IF NOT EXISTS private.blocked_terms (
  id          uuid  PRIMARY KEY DEFAULT gen_random_uuid(),
  term        text  NOT NULL UNIQUE,
  added_at    timestamptz NOT NULL DEFAULT clock_timestamp(),
  added_by    text  NOT NULL,  -- moderator identifier (email or name); not a FK
  CONSTRAINT blocked_terms_term_check CHECK (length(trim(term)) BETWEEN 1 AND 100)
);
```

The text filter function (Section 5.7) performs a case-insensitive substring search: if the input text contains any term from this table, the content is flagged. Edge Functions call this function; it is not called from DB triggers (the list must be updateable without a migration, and trigger execution overhead would affect every INSERT on comments/clues).

### 4.5 Additions to `public.profiles`

V2 migration adds:

```sql
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS is_suspended     boolean     NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS suspended_at     timestamptz,
  ADD COLUMN IF NOT EXISTS suspension_reason text;

ALTER TABLE public.profiles
  ADD CONSTRAINT profiles_suspension_check CHECK (
    (is_suspended = false AND suspended_at IS NULL AND suspension_reason IS NULL)
    OR
    (is_suspended = true  AND suspended_at IS NOT NULL AND suspension_reason IS NOT NULL)
  );
```

**Suspension semantics:** A suspended user:
- Can authenticate (JWT remains valid; profile row still readable).
- Cannot post, guess, comment, upload, or create invites.
- Is visible to other users (their profile and past activity remain visible).
- Is NOT deleted. `is_active` remains `true`. Suspension is distinct from deletion.

All SECURITY DEFINER mutation functions that currently check `is_active = true` must additionally check `is_suspended = false` in V2.

### 4.6 `media_objects` Status Expansion

The V2 migration constraint includes the two moderation statuses in addition to those planned in Step 25:

```
('processing','ready','failed','deleted','superseded','cleaned','pending_review','rejected')
```

Status flow for challenge photos:
```
processing → pending_review  (upload-complete re-encoding succeeds; awaiting moderator)
pending_review → ready        (approve_photo)
pending_review → rejected     (reject_photo; challenge remains in draft; poster must upload again)
ready → superseded            (finalize_upload_session when replacing existing media)
superseded → cleaned          (cleanup worker)
```

---

## Section 5 — Function Contracts

All functions in Section 5: `public` schema, `SECURITY DEFINER`, `SET search_path = ''`, owned by `forkensics_executor`.

### 5.1 `public.report_content`

**Callers:** Authenticated users. EXECUTE granted to `authenticated`.

```
public.report_content(
  p_target_type text,   -- 'challenge' | 'comment' | 'profile'
  p_target_id   uuid,
  p_category    text,
  p_detail      text    -- nullable
) → (report_id uuid)
```

Behavior:
1. Standard gate: active, onboarded caller. Suspended users may still report.
2. Validates `target_type` is one of the three allowed values.
3. Validates the target exists (challenge: `public.challenges`; comment: `public.comments`; profile: `public.profiles`). If not found → raises `FK_NOT_FOUND`.
4. Prevents self-report (profile reports: `target_id != auth_uid()`). If self-report → raises `FK_FORBIDDEN`.
5. Inserts `content_reports` row with `status = 'pending'`. If duplicate (same reporter/target/category) → idempotent; returns existing `report_id`.
6. Returns `report_id`.

### 5.2 `public.block_user`

**Callers:** Authenticated users. EXECUTE granted to `authenticated`.

```
public.block_user(p_blocked_id uuid) → void
```

Behavior:
1. Active, onboarded caller required. Suspended users may still block.
2. Prevents self-block (`p_blocked_id != auth_uid()`) → raises `FK_FORBIDDEN`.
3. Verifies `p_blocked_id` exists in `public.profiles` → else `FK_NOT_FOUND`.
4. INSERTs `user_blocks (blocker_id = auth_uid(), blocked_id = p_blocked_id)`. Idempotent on conflict.

**Note:** Block does not remove the blocked user from any existing group or rewrite any scores. It only affects future eligibility (via `activate_challenge`) and client-side visibility suppression.

### 5.3 `public.unblock_user`

**Callers:** Authenticated users. EXECUTE granted to `authenticated`.

```
public.unblock_user(p_blocked_id uuid) → void
```

Behavior:
1. Active caller required.
2. DELETEs `user_blocks WHERE blocker_id = auth_uid() AND blocked_id = p_blocked_id`. Idempotent if no row exists.

### 5.4 `public.approve_photo`

**Callers:** Service role only (moderator action). EXECUTE granted to `service_role`.

```
public.approve_photo(p_media_object_id uuid, p_moderator_id uuid, p_reason text) → void
```

Behavior:
1. Verifies `media_objects.status = 'pending_review'` → else raises `FK_WRONG_STATE`.
2. Sets `media_objects.status = 'ready'`, `re_encoded_at = now()`.
3. Inserts `moderation_actions (action_type = 'photo_approved', target_type = 'media_object', target_id = p_media_object_id, moderator_id = p_moderator_id, reason = p_reason)`.

### 5.5 `public.reject_photo`

**Callers:** Service role only. EXECUTE granted to `service_role`.

```
public.reject_photo(p_media_object_id uuid, p_moderator_id uuid, p_reason text) → void
```

Behavior:
1. Verifies `media_objects.status = 'pending_review'` → else raises `FK_WRONG_STATE`.
2. Sets `media_objects.status = 'rejected'`.
3. Inserts `moderation_actions (action_type = 'photo_rejected', ...)`.

**Effect:** The challenge's `media_object_id` still points to this rejected media object, but `activate_challenge` checks `status = 'ready'` and will block activation. The poster must call `upload-authorize` again to upload a new photo; `finalize_upload_session` on the new session will atomically replace `media_object_id` (setting the old rejected one to `'superseded'`; cleanup worker handles deletion).

### 5.6 `public.remove_content`

**Callers:** Service role only. EXECUTE granted to `service_role`.

```
public.remove_content(
  p_target_type  text,   -- 'challenge' | 'comment'
  p_target_id    uuid,
  p_moderator_id uuid,
  p_report_id    uuid,   -- nullable; link to triggering report
  p_reason       text
) → void
```

Behavior:
- For `'comment'`: soft-deletes by setting `comments.deleted_at = now()` (same field as the existing soft-delete; this runs as `forkensics_executor` bypassing the `restrict_comment_updates` trigger's author check). The deleted comment text is cleared to `'[removed by moderator]'` or left NULL — TBD in implementation.
- For `'challenge'`: calls `private.cancel_challenge_service(p_target_id, 'removed_by_moderator')` — a new V2 private function that cancels a challenge with a moderator reason, bypassing the poster-or-owner check. Cancellation prevents new guesses; the challenge state becomes `'cancelled'` and is visible to group members.
- Inserts `moderation_actions (action_type = 'content_removed', ...)`.
- If `p_report_id` is non-NULL, sets `content_reports.status = 'actioned'`, `reviewed_at = now()`, `reviewed_by = p_moderator_id`.

### 5.7 `public.check_text_content`

**Callers:** Edge Functions. EXECUTE granted to `service_role`.

```
public.check_text_content(p_text text) → boolean
```

Returns `true` if the text passes the filter (no blocked terms found). Returns `false` if a blocked term is detected.

Implementation: case-insensitive substring search against `private.blocked_terms`. Edge Functions call this before writing comments, clues, or display names. If `false` → return `400 FK_CONTENT_FILTERED` to the client.

**V1 function unchanged:** The `private.normalize_answer` function is a separate concern (scoring normalization, not content filtering).

### 5.8 `public.suspend_user`

**Callers:** Service role only. EXECUTE granted to `service_role`.

```
public.suspend_user(p_profile_id uuid, p_moderator_id uuid, p_reason text) → void
```

Behavior:
1. Verifies profile exists and `is_active = true` → else raises.
2. Verifies `is_suspended = false` (idempotent if already suspended).
3. Sets `profiles.is_suspended = true`, `suspended_at = now()`, `suspension_reason = p_reason`.
4. Inserts `moderation_actions (action_type = 'user_suspended', target_type = 'profile', target_id = p_profile_id, ...)`.

### 5.9 `public.reinstate_user`

**Callers:** Service role only. EXECUTE granted to `service_role`.

```
public.reinstate_user(p_profile_id uuid, p_moderator_id uuid, p_reason text) → void
```

Behavior:
1. Verifies `is_suspended = true` → else raises.
2. Sets `profiles.is_suspended = false`, `suspended_at = NULL`, `suspension_reason = NULL`.
3. Inserts `moderation_actions (action_type = 'user_reinstated', ...)`.

### 5.10 `public.dismiss_report`

**Callers:** Service role only. EXECUTE granted to `service_role`.

```
public.dismiss_report(p_report_id uuid, p_moderator_id uuid, p_reason text) → void
```

Sets `content_reports.status = 'dismissed'`, `reviewed_at = now()`, `reviewed_by = p_moderator_id`, `resolution_note = p_reason`.

### 5.11 `public.action_report`

**Callers:** Service role only. EXECUTE granted to `service_role`.

```
public.action_report(p_report_id uuid, p_moderator_id uuid, p_reason text) → void
```

Sets `content_reports.status = 'actioned'`, `reviewed_at = now()`, `reviewed_by = p_moderator_id`, `resolution_note = p_reason`. Used when the moderation action (content removal, suspension) is recorded separately.

### 5.12 `public.get_moderation_queue`

**Callers:** Service role only. EXECUTE granted to `service_role`.

```
public.get_moderation_queue() → TABLE(
  queue_type        text,   -- 'pending_report' | 'pending_review_photo'
  id                uuid,
  created_at        timestamptz,
  reporter_id       uuid,   -- NULL for photo queue
  target_type       text,   -- NULL for photo queue
  target_id         uuid,
  category          text,   -- NULL for photo queue
  challenge_id      uuid    -- NULL for report queue items that are not challenge-related
)
```

Returns:
- All `content_reports WHERE status = 'pending'`, ordered by `created_at`.
- All `media_objects WHERE status = 'pending_review'`, ordered by `created_at` (joined to `upload_sessions` to get `challenge_id`).

---

## Section 6 — Changes to V1 Functions

### 6.1 `activate_challenge` — V2 replacement

The V2 migration replaces `public.activate_challenge` with a new body. The only change is in the eligible-participant snapshot:

**Current V1 behavior:**
```sql
INSERT INTO public.eligible_participants (challenge_id, player_id, snapshot_avatar_color)
SELECT p_challenge_id, p.id, p.avatar_color
FROM public.group_members gm
JOIN public.profiles p ON p.id = gm.player_id
WHERE gm.group_id = v_challenge.group_id
  AND gm.player_id != private.auth_uid()  -- exclude poster
  AND p.is_active = true
  AND p.onboarding_complete = true;
```

**V2 addition:** Also exclude players who have a block relationship (either direction) with the poster:

```sql
INSERT INTO public.eligible_participants (challenge_id, player_id, snapshot_avatar_color)
SELECT p_challenge_id, p.id, p.avatar_color
FROM public.group_members gm
JOIN public.profiles p ON p.id = gm.player_id
WHERE gm.group_id = v_challenge.group_id
  AND gm.player_id != private.auth_uid()  -- exclude poster
  AND p.is_active = true
  AND p.onboarding_complete = true
  AND NOT EXISTS (                         -- exclude blocked pairs
    SELECT 1 FROM public.user_blocks ub
    WHERE (ub.blocker_id = private.auth_uid() AND ub.blocked_id = gm.player_id)
       OR (ub.blocker_id = gm.player_id AND ub.blocked_id = private.auth_uid())
  );
```

**Also add suspension check on the caller (poster):** Add `AND NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = private.auth_uid() AND is_suspended = true)` to the caller guard at the top of the function. A suspended user cannot activate a challenge.

No other changes to `activate_challenge`.

### 6.2 `finalize_upload_session` — updated contract

The function body in Step 25 must set `media_objects.status = 'pending_review'` (not `'ready'`) and must NOT set `re_encoded_at` (that is set by `approve_photo` when the photo is cleared). The Step 25 proposal will be revised to reflect this before it is sent for review.

### 6.3 Suspension guard in other executor functions

The following V1 executor functions must have `is_suspended = false` added to their active-profile guard in the V2 replacement:
- `create_group_invite` (suspended users cannot invite)
- `redeem_group_invite` (suspended users cannot join groups)

Functions that suspended users **may still call:**
- `report_content` (see Section 5.1)
- `block_user`, `unblock_user`
- Account deletion (suspended users must still be able to delete their account)

V1 functions `reveal_challenge`, `cancel_challenge`, `apply_correction` — if any of these are reachable by a suspended user, add the guard. Reveal and cancel are poster actions; posting is blocked by suspension; a challenge posted before suspension could still be in-flight. Recommendation: allow reveal/cancel for suspended users (they should be able to close their own in-progress challenges). Do not add suspension guard to reveal/cancel/apply_correction.

---

## Section 7 — RLS Policies

### 7.1 `public.content_reports`

```sql
-- Reporters see only their own reports
CREATE POLICY reports_select_own ON public.content_reports
  FOR SELECT TO authenticated
  USING (reporter_id = private.auth_uid());

-- No direct INSERT, UPDATE, DELETE for authenticated users
-- (use report_content function)
```

### 7.2 `public.user_blocks`

```sql
-- Users see their own block rows (as blocker or blocked)
CREATE POLICY blocks_select_own ON public.user_blocks
  FOR SELECT TO authenticated
  USING (blocker_id = private.auth_uid() OR blocked_id = private.auth_uid());

-- No direct INSERT, UPDATE, DELETE (use block_user / unblock_user functions)
```

### 7.3 `public.moderation_actions`

No RLS policy granting SELECT to `authenticated`. Service role only.

### 7.4 Suspension visibility in `public.profiles`

The existing profiles RLS allows group members to SELECT each other's profiles. `is_suspended` is a column on `public.profiles`; it will be readable by anyone who can SELECT the profile row. This is intentional — the client can display a "suspended" badge or suppress interaction affordances for suspended users.

---

## Section 8 — Internal Moderation Procedure

This section defines operational expectations, not database schema.

**Response target:** Within 24 hours of a report being filed. This is an internal service-level target, not a contract enforced by the database.

**Moderation workflow (V1, manual):**
1. `get_moderation_queue()` is called by a moderation tool or script (service_role access).
2. Moderator reviews pending reports and pending-review photos.
3. For photos: `approve_photo` or `reject_photo`.
4. For content reports: `remove_content`, `suspend_user`, or `dismiss_report`.
5. Every action is recorded in `moderation_actions` (immutable audit trail).

**Photo gate SLA:** Because `activate_challenge` requires `media_object_id.status = 'ready'`, a photo cannot go live until approved. This introduces a moderation delay between upload completion and challenge activation. For a family app with low content volume, this is acceptable. Target: clear photo queue within 4 hours during active play periods.

**Published support contact:** A real support email must be live before App Store submission. It must be listed in the app's Settings/Help screen and in the App Store metadata. Placeholder emails are not acceptable.

---

## Section 9 — Apple Reviewer Seed Procedure

A repeatable, production-safe seed procedure must be created before submission. It must not use real family accounts or personal photographs.

**Required seed state for reviewer account:**

| Item | Seed content |
|---|---|
| Reviewer account | `reviewer@forkensics.review` or similar; pre-populated |
| Player 2 | Fictional profile; has submitted guesses |
| Player 3 | Fictional profile; has blocked Player 2 (to demonstrate block) |
| Mystery 1 | Active challenge; reviewer can guess |
| Mystery 2 | Revealed challenge; scores and Table Talk visible |
| Mystery 3 | Revealed challenge with a Clue; shows clue flow |
| Mystery 4 | Revealed challenge with a leaderboard-worth result |
| Reports | At least one example pending report visible to moderator |
| Block | Player 3 has blocked Player 2; block visible in reviewer account |

Photos must be non-copyrighted stock food images or synthetic placeholder photos generated specifically for review. No restaurant names, addresses, or real personal photographs.

The seed procedure must be runnable against a clean dev environment and against production with no side effects on real user data.

---

## Section 10 — Additional Pre-Submission Requirements

These items are non-schema but are tracked here as Apple readiness requirements:

**Camera and Photo permissions:**
- Use the photo picker (`PHPickerViewController`) by default — does not require broad Photos library access.
- Request camera permission only when the user explicitly chooses to take a photo.
- Include `NSCameraUsageDescription` and `NSPhotoLibraryUsageDescription` (if applicable) with clear, truthful explanations.

**Privacy policy and App Privacy disclosures:**
- Privacy policy must be live at a public URL before submission.
- App Store Connect privacy disclosures must match what the app actually collects (including Sentry).
- Do not guess. Audit every SDK (Sentry, Supabase client, any analytics) for data collection behavior before completing the questionnaire.

**Age rating questionnaire:**
- Run the questionnaire now, not at submission time. Apple has added social-media interaction questions for apps with UGC, effective September 2026.
- Table Talk qualifies as social-media-style interaction even in private groups.
- Do not select "Made for Kids" because families play together.

**Crash monitoring (Sentry — confirmed):**
- Default PII collection disabled.
- No session replay, no screenshots.
- Scrub from events: JWTs, storage paths, food answers, Table Talk text, upload tokens.
- Xcode Organizer crash reports retained as the first-party backup.
- Configure for both Swift and Edge Functions.

---

## Section 11 — Open Questions for Codex/GPT Review

1. **Comment text on removal:** When `remove_content` is called for a `'comment'`, should the text be cleared to a placeholder string (e.g., `'[removed by moderator]'`) or should `deleted_at` alone indicate removal? The existing `restrict_comment_updates` trigger only allows `deleted_at` to be set and makes text immutable. If we need to clear text, the V2 replacement of `remove_content` must bypass the trigger via `forkensics_executor`.

   **Recommendation:** Clear text to `NULL` when moderator-removed. The `restrict_comment_updates` trigger is SECURITY INVOKER; when `remove_content` runs as `forkensics_executor`, the trigger's `current_user` check bypasses the author guard (same pattern as `apply_correction` with alias edits). The text field would need to allow NULL — currently `text text NOT NULL`. A V2 ALTER to allow NULL, or a separate `moderator_removed boolean DEFAULT false` column, is needed.

2. **Rejection UX:** When a photo is rejected, the poster currently has no DB-level notification. The challenge stays in `draft` with `media_object_id` pointing to the rejected media object. Poster must call `upload-authorize` again. Is there an in-app notification or just a visible "photo rejected — upload a new one" state on the draft challenge screen? This is a UX decision for the Swift implementation steps.

3. **Block and existing active challenges:** If Player A blocks Player B while an active challenge is in progress (A is the poster, B is an eligible participant), B is already in `eligible_participants`. The block does not retroactively remove B from eligibility for that challenge. B can still guess; their score is recorded. Is this acceptable? **Recommendation: yes** — blocks apply to future challenges only (at `activate_challenge` time). This avoids complex retroactive exclusion logic and is consistent with the principle that `eligible_participants` is immutable after posting.

4. **Suspension and in-progress challenges:** If A is suspended while A has an active challenge, should that challenge be automatically cancelled? **Recommendation: no** — allow the challenge to continue and auto-close at deadline. Cancellation is a separate moderation action if needed (`remove_content` for the challenge). This avoids surprising other players.

---

## Section 12 — Success Criteria for Step 24.1

- [ ] `content_reports`, `user_blocks`, `moderation_actions`, `blocked_terms` schemas agreed
- [ ] `is_suspended` column addition to `public.profiles` agreed
- [ ] `pending_review` and `rejected` media_objects statuses agreed
- [ ] Photo gate flow agreed: `pending_review → ready` via `approve_photo`; no auto-ready
- [ ] Block behavior agreed: two-way, eligibility-only at DB layer, no retroactive exclusion
- [ ] `activate_challenge` block-pair exclusion agreed
- [ ] `finalize_upload_session` updated contract agreed (sets `pending_review`, not `ready`)
- [ ] Suspension semantics agreed: mutation operations blocked; read access retained; not deletion
- [ ] `check_text_content` called from Edge Functions, not from DB triggers
- [ ] Moderation functions grant strategy agreed (user-callable: report_content, block_user, unblock_user; service_role only: everything else)
- [ ] Open questions (comment text on removal; rejection UX; block mid-challenge) answered
- [ ] Step 25 proposal will be revised before submission to Codex to incorporate all decisions from this step
