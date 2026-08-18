# Step 24.1 Proposal — Rev 3 — UGC Safety and Moderation Contracts

**Status:** Pending review (Claude → Codex/GPT → Bill approval)
**Governance gate:** Bill must type `APPROVED: Step 24.1 — UGC Safety and Moderation Contracts` before any moderation schema or functions are written as executable SQL or applied to any environment.
**Changes from Rev 2:**
- Blocker 1: Removed `forkensics_executor` bypass from text-filter trigger; added story and alias fields; clarified avatar policy.
- Blocker 2: Replaced additive RLS with `AS RESTRICTIVE` policies; all mutation paths enumerated; V1 predicates preserved.
- Blocker 3: Replaced invalid inline UNIQUE syntax with a partial unique index.
- Blocker 4: Corrected moderation function transaction order; `dismiss_report` and `action_report` insert moderation_action rows; report validation added.
- Blocker 5: Added `get_media_key_for_report`; extended `remove_content` / `remove_media` to cover live photos; added moderation hold clarification.
- Blocker 6: Full claim/lease/retry cleanup contract; concurrent-decision locking; poster re-upload path; evidence scope clarified to audit metadata; 90-day cleanup contract defined.
- Blocker 7: `p_moderator_id` source constraint; revocation immediacy; `reviewed_by` removed from reporter-visible fields.
- Blocker 8: Precise block rule for existing active challenges; acceptance test added.

---

## Section 1 — Confirmed Decisions (all parties)

1. **Comment removal evidence:** Replace public text with `[removed by moderator]`; store audit metadata (storage path + SHA-256 hash of the re-encoded object) in `private.moderation_evidence`. This is audit metadata, not a retained image copy. After storage deletion the image is gone; the hash remains.

2. **Block on active challenge:** Block takes effect immediately. Existing guesses and scores are preserved. Existing eligible participants retain read-only visibility of the challenge. No new guesses, comments, or reactions between the blocked pair, even on challenges currently in progress. "Block applies to new challenges only" is explicitly rescinded.

3. **Moderation-action immutability:** Unconditional `BEFORE UPDATE OR DELETE` rejection is approved.

4. **Avatar photos in V1:** Photo avatars are disabled in V1. Profile avatars, if present, are static seeded images not uploadable by users. This is documented here as an explicit V1 constraint.

---

## Section 2 — Schema Changes

Unchanged from Rev 2 except as noted below.

### 2.1 `public.content_reports`

Replace the inline UNIQUE table constraint with a partial unique index (deferred to after table creation):

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
  -- reviewed_by is NOT exposed to reporters. See Section 8.
  reviewed_by     uuid        REFERENCES public.profiles(id) ON DELETE RESTRICT,

  CONSTRAINT cr_target_type_check
    CHECK (target_type IN ('challenge','comment','clue','profile','media_object')),

  CONSTRAINT cr_category_check
    CHECK (category IN ('inappropriate_image','offensive_content','spam',
                        'harassment','copyright','other')),

  CONSTRAINT cr_status_check
    CHECK (status IN ('pending','reviewed','actioned','dismissed')),

  CONSTRAINT cr_detail_check
    CHECK (detail IS NULL OR length(detail) <= 500)
  -- No inline UNIQUE constraint for partial uniqueness; use index below.
);

-- Partial unique index: prevents duplicate pending reports only.
-- A new report is accepted once the prior report on the same target+category is resolved.
CREATE UNIQUE INDEX content_reports_unresolved_dedup
  ON public.content_reports (reporter_id, target_type, target_id, category)
  WHERE status = 'pending';

CREATE INDEX ON public.content_reports (status, created_at);
CREATE INDEX ON public.content_reports (reporter_id);
CREATE INDEX ON public.content_reports (target_type, target_id) WHERE status = 'pending';
```

**Reporter-visible columns via RLS SELECT:** `id`, `target_type`, `target_id`, `category`, `detail`, `status`, `created_at`, `reviewed_at`. **`reviewed_by` is NOT included** — moderator identity and reasoning remain private. Reporter-safe status contains only `status` and `reviewed_at`.

### 2.2 `private.moderation_evidence` — evidence scope clarified

Evidence rows record **audit metadata**, not a retained image copy:

```sql
CREATE TABLE IF NOT EXISTS private.moderation_evidence (
  id                    uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  moderation_action_id  uuid        NOT NULL
                                    REFERENCES public.moderation_actions(id) ON DELETE RESTRICT,
  evidence_type         text        NOT NULL,
  -- For comment/clue removal: the original text
  evidence_text         text,
  -- For media rejection/removal: the storage path and hash at time of moderation
  evidence_storage_key  text,
  evidence_sha256       text,       -- hex SHA-256 of the re-encoded object, recorded at moderation time
  retained_until        timestamptz NOT NULL DEFAULT (clock_timestamp() + interval '90 days'),
  created_at            timestamptz NOT NULL DEFAULT clock_timestamp(),

  CONSTRAINT me_evidence_type_check
    CHECK (evidence_type IN ('comment_text','clue_text','media_metadata'))
);

CREATE INDEX ON private.moderation_evidence (retained_until);
```

`evidence_sha256` is obtained from the stored object before deletion. The 90-day cleanup function is defined in Section 9.5.

### 2.3 `public.media_objects` — cleanup lease and hold columns

```sql
ALTER TABLE public.media_objects
  ADD COLUMN IF NOT EXISTS moderated_at              timestamptz,
  ADD COLUMN IF NOT EXISTS moderation_cleanup_leased_until timestamptz,
  ADD COLUMN IF NOT EXISTS has_pending_report        boolean NOT NULL DEFAULT false;
```

`has_pending_report = true` is set atomically when a `media_object` report is accepted. It prevents cleanup workers from touching the object while the moderator's review is pending. The flag is cleared when the report is resolved (dismissed or actioned via `remove_media`).

### 2.4 Additions to `public.clues`

```sql
ALTER TABLE public.clues
  ADD COLUMN IF NOT EXISTS moderator_removed_at timestamptz;
```

### 2.5 Additions to `public.challenges`

```sql
ALTER TABLE public.challenges
  ADD COLUMN IF NOT EXISTS moderator_removed_at timestamptz;
```

### 2.6 Additions to `public.comments`

```sql
ALTER TABLE public.comments
  ADD COLUMN IF NOT EXISTS moderator_removed_at timestamptz;
```

### 2.7 Status constraint for `public.media_objects` (full V2 set)

```
('processing','ready','failed','deleted','superseded','cleaned',
 'pending_review','rejected','removed')
```

---

## Section 3 — Text Filtering (Corrected)

### 3.1 Trigger function — SECURITY DEFINER, no caller bypass

The trigger function is `SECURITY DEFINER` so it can query `private.blocked_terms`, which is not accessible to the `authenticated` role. Because it is `SECURITY DEFINER`, `current_user` is always `forkensics_executor` regardless of who fires the trigger. Therefore **no bypass based on `current_user` is used**. Moderator placeholder text (`[removed by moderator]`) is not a blocked term and passes filtering without any bypass.

```sql
CREATE OR REPLACE FUNCTION private.check_text_content_trigger()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_text text;
BEGIN
  -- Determine the field to check from TG_TABLE_NAME and optional TG_ARGV[0]
  v_text := CASE
    WHEN TG_TABLE_NAME = 'comments'              THEN NEW.text
    WHEN TG_TABLE_NAME = 'clues'                 THEN NEW.text
    WHEN TG_TABLE_NAME = 'profiles'              THEN NEW.display_name
    WHEN TG_TABLE_NAME = 'groups'                THEN NEW.name
    WHEN TG_TABLE_NAME = 'challenges'            THEN NEW.public_city_display
    WHEN TG_TABLE_NAME = 'challenge_secrets' AND TG_ARGV[0] = 'display_dish'       THEN NEW.display_dish
    WHEN TG_TABLE_NAME = 'challenge_secrets' AND TG_ARGV[0] = 'display_restaurant' THEN NEW.display_restaurant
    WHEN TG_TABLE_NAME = 'challenge_secrets' AND TG_ARGV[0] = 'story'              THEN NEW.story
    WHEN TG_TABLE_NAME = 'challenge_answer_aliases' THEN NEW.display_value
    ELSE NULL
  END;

  IF v_text IS NULL THEN
    RETURN NEW;
  END IF;

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

### 3.2 Trigger attachments

```sql
CREATE OR REPLACE TRIGGER comment_text_filter
  BEFORE INSERT ON public.comments
  FOR EACH ROW EXECUTE FUNCTION private.check_text_content_trigger();

CREATE OR REPLACE TRIGGER clue_text_filter
  BEFORE INSERT ON public.clues
  FOR EACH ROW EXECUTE FUNCTION private.check_text_content_trigger();

CREATE OR REPLACE TRIGGER profile_name_filter
  BEFORE INSERT OR UPDATE ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION private.check_text_content_trigger();

CREATE OR REPLACE TRIGGER group_name_filter
  BEFORE INSERT OR UPDATE ON public.groups
  FOR EACH ROW EXECUTE FUNCTION private.check_text_content_trigger();

CREATE OR REPLACE TRIGGER challenge_city_filter
  BEFORE INSERT OR UPDATE ON public.challenges
  FOR EACH ROW EXECUTE FUNCTION private.check_text_content_trigger();

CREATE OR REPLACE TRIGGER secret_dish_filter
  BEFORE INSERT OR UPDATE ON public.challenge_secrets
  FOR EACH ROW EXECUTE FUNCTION private.check_text_content_trigger('display_dish');

CREATE OR REPLACE TRIGGER secret_restaurant_filter
  BEFORE INSERT OR UPDATE ON public.challenge_secrets
  FOR EACH ROW EXECUTE FUNCTION private.check_text_content_trigger('display_restaurant');

CREATE OR REPLACE TRIGGER secret_story_filter
  BEFORE INSERT OR UPDATE ON public.challenge_secrets
  FOR EACH ROW EXECUTE FUNCTION private.check_text_content_trigger('story');

CREATE OR REPLACE TRIGGER alias_display_value_filter
  BEFORE INSERT ON public.challenge_answer_aliases
  FOR EACH ROW EXECUTE FUNCTION private.check_text_content_trigger();
```

**Note on challenge_answer_aliases:** Aliases are only inserted by the poster before any guesses are made. The filter trigger fires on each INSERT.

### 3.3 Moderator comment update path

When `remove_content` (running as `forkensics_executor`) UPDATEs `comments.text` to the placeholder:

1. The trigger fires as `SECURITY DEFINER` → `current_user = forkensics_executor`.
2. `[removed by moderator]` is not in `private.blocked_terms` → the check passes naturally.
3. No bypass needed.

This must be verified in an acceptance test (Section 11, test 1.7).

### 3.4 Avatar photos

Photo avatars are disabled in V1 (Section 1, decision 4). No profile avatar upload trigger is needed.

---

## Section 4 — Suspension and Block Enforcement via RESTRICTIVE Policies

PostgreSQL permissive policies combine with `OR`. Adding a new permissive policy alongside an existing one does not restrict it. This section uses `AS RESTRICTIVE` policies instead. A `RESTRICTIVE` policy combines with all permissive policies via `AND` — the row must pass at least one permissive policy AND all restrictive policies. V1 permissive policies are unchanged; the restrictive policies add the new conditions.

### 4.1 Suspension enforcement — RESTRICTIVE INSERT/UPDATE policies

The following single restrictive policy is created on each table where suspended users must be prevented from creating new content:

```sql
-- Template: replace <table> and <operation> per table below

CREATE POLICY enforce_not_suspended AS RESTRICTIVE ON public.<table>
  FOR <operation> TO authenticated
  WITH CHECK (
    NOT EXISTS (
      SELECT 1 FROM public.profiles
      WHERE id = private.auth_uid() AND is_suspended = true
    )
  );
```

**Tables and operations covered:**

| Table | Operations |
|---|---|
| `public.comments` | INSERT |
| `public.clues` | INSERT |
| `public.reactions` | INSERT |
| `public.guess_attempts` | INSERT |
| `public.challenges` | INSERT |
| `public.challenge_secrets` | INSERT, UPDATE |
| `public.challenge_answer_aliases` | INSERT |
| `public.group_members` | INSERT (invite redemption) |
| `public.profiles` | UPDATE (display_name change) |
| `public.groups` | INSERT, UPDATE |

**Tables where suspension does NOT restrict (intentional):**
- `public.content_reports` — suspended users may still file safety reports
- `public.user_blocks` — suspended users may still block
- Challenge reveal/cancel functions — suspended users may close their own in-progress challenges

### 4.2 Block enforcement — RESTRICTIVE INSERT policies (new interactions)

```sql
-- Prevents new guesses on challenges where the poster is a blocked pair
CREATE POLICY enforce_no_block_guess AS RESTRICTIVE ON public.guess_attempts
  FOR INSERT TO authenticated
  WITH CHECK (NOT private.has_block_with_poster(challenge_id));

-- Prevents new comments on challenges where the poster is a blocked pair
CREATE POLICY enforce_no_block_comment AS RESTRICTIVE ON public.comments
  FOR INSERT TO authenticated
  WITH CHECK (NOT private.has_block_with_poster(challenge_id));

-- Prevents new reactions on challenges where the poster is a blocked pair
CREATE POLICY enforce_no_block_reaction AS RESTRICTIVE ON public.reactions
  FOR INSERT TO authenticated
  WITH CHECK (NOT private.has_block_with_poster(challenge_id));
```

`private.has_block_with_poster(challenge_id)` checks both directions (caller blocked the poster OR poster blocked the caller). Defined in Rev 2 Section 6.2, unchanged.

### 4.3 Block enforcement — RESTRICTIVE SELECT policies (content visibility)

These hide content from blocked pairs without altering existing V1 SELECT predicates:

```sql
-- Hide comments authored by blocked users (bidirectional)
CREATE POLICY hide_blocked_comments AS RESTRICTIVE ON public.comments
  FOR SELECT TO authenticated
  USING (NOT private.has_block_with(author_id));

-- Hide reactions from blocked users (bidirectional)
CREATE POLICY hide_blocked_reactions AS RESTRICTIVE ON public.reactions
  FOR SELECT TO authenticated
  USING (NOT private.has_block_with(player_id));

-- Hide challenges from blocked posters, with carve-outs
CREATE POLICY hide_blocked_challenges AS RESTRICTIVE ON public.challenges
  FOR SELECT TO authenticated
  USING (
    poster_id = private.auth_uid()
    OR NOT private.has_block_with(poster_id)
    OR EXISTS (
      -- Existing eligible participants retain read-only visibility (Section 1, decision 2)
      SELECT 1 FROM public.eligible_participants
      WHERE challenge_id = id AND player_id = private.auth_uid()
    )
  );
```

### 4.4 V1 policy preservation test requirement

See Section 11, tests 2.x. These tests must confirm that without any block or suspension, all original V1 visibility and mutation behavior is unchanged.

### 4.5 `restrict_comment_updates` trigger — V2 replacement

No `forkensics_executor` bypass is added for this trigger. The trigger is `SECURITY INVOKER` and runs as the calling role. When `remove_content` UPDATEs `comments.text`, it runs as `forkensics_executor` and the trigger runs as `forkensics_executor`. The trigger's check is:

```
IF TG_OP = 'UPDATE' AND NEW.author_id != OLD.author_id THEN RAISE; END IF;
-- And checks that only the author can soft-delete
```

None of these checks fire on a moderator text replacement (author_id is unchanged; text change is by forkensics_executor). Review V1 trigger body to confirm no additional guard blocks this path. Confirm in acceptance test 3.3.

---

## Section 5 — `private.moderators` and Moderator Identity

### 5.1 Table

```sql
CREATE TABLE IF NOT EXISTS private.moderators (
  profile_id  uuid PRIMARY KEY REFERENCES public.profiles(id) ON DELETE RESTRICT,
  added_at    timestamptz NOT NULL DEFAULT clock_timestamp()
);
```

### 5.2 Identity source constraint

`p_moderator_id` in all moderation functions **must be derived by the trusted admin backend from the moderator's verified session token**, never from an untrusted request body. This is a backend operational constraint documented here; the DB function cannot itself enforce the source, but it does validate that the ID is in `private.moderators` and that the profile is active (`profiles.is_active = true`).

Validation performed inside every moderation function:

```sql
IF NOT EXISTS (
  SELECT 1 FROM private.moderators m
  JOIN public.profiles p ON p.id = m.profile_id
  WHERE m.profile_id = p_moderator_id
    AND p.is_active = true
) THEN
  RAISE EXCEPTION 'FK_UNAUTHORIZED: moderator identity not valid';
END IF;
```

Revocation: removing a row from `private.moderators` immediately prevents further moderation actions from that profile. No cache invalidation step required — every function call re-validates.

---

## Section 6 — Corrected Moderation Function Transaction Order

All moderation functions that create evidence follow this transaction order:

1. Lock the target row `FOR UPDATE` (prevents concurrent decisions on the same target).
2. Validate preconditions (state, moderator identity, report linkage).
3. `INSERT INTO public.moderation_actions (...) RETURNING id` → `v_action_id`.
4. `INSERT INTO private.moderation_evidence (..., moderation_action_id = v_action_id)`.
5. Update the public target state.
6. If `p_report_id IS NOT NULL`: verify report is `pending` and `target_type + target_id` match the action target; set `status = 'actioned'`, `reviewed_at`, `reviewed_by`.
7. Commit atomically (all in one PL/pgSQL function call — implicit transaction).

**`dismiss_report` and `action_report`** both insert a `moderation_actions` row with the appropriate `action_type` before updating the report row. They are not evidence-free operations.

---

## Section 7 — Function Contracts (Revised)

### 7.1 `public.report_content`

Unchanged from Rev 2 except:

- On conflict with the partial unique index (duplicate pending report), the function returns the existing `report_id` idempotently (uses `ON CONFLICT DO NOTHING RETURNING id` or an explicit pre-check).
- If `target_type = 'media_object'` and the media object exists and is accessible: set `media_objects.has_pending_report = true` atomically in the same INSERT transaction.

### 7.2 `public.approve_photo`

```
public.approve_photo(
  p_media_object_id uuid,
  p_moderator_id    uuid,
  p_reason          text
) → void
```

1. Validate moderator (Section 5.2).
2. `SELECT ... FOR UPDATE` the media_object row.
3. Verify `status = 'pending_review'` → else `FK_WRONG_STATE`.
4. `INSERT INTO moderation_actions RETURNING id`.
5. No evidence needed for approval.
6. `UPDATE media_objects SET status = 'ready', moderated_at = now()`.
7. No report linkage for approval (approval is not triggered by a report).

### 7.3 `public.reject_photo`

```
public.reject_photo(
  p_media_object_id uuid,
  p_moderator_id    uuid,
  p_reason          text
) → void
```

1. Validate moderator.
2. `SELECT ... FOR UPDATE` media_object.
3. Verify `status = 'pending_review'`.
4. Read `re_encoded_storage_key` from `private.media_storage_keys` (and optionally its SHA-256 hash if precomputed — V1 stores the key; hash is best-effort metadata).
5. `INSERT INTO moderation_actions RETURNING id` → `v_action_id`.
6. `INSERT INTO private.moderation_evidence (evidence_type = 'media_metadata', evidence_storage_key, evidence_sha256, moderation_action_id = v_action_id)`.
7. `UPDATE media_objects SET status = 'rejected', moderated_at = now()`.
8. Challenge remains in `draft` state; poster receives rejection state via `get_poster_media_status`.

**Poster re-upload after rejection + cleaning:** The challenge stays in `draft` with `media_object_id` pointing to the now-`cleaned` object. The poster initiates a new upload session through the normal reserve/activate/finalize flow (Step 24). When the new media object is approved, a separate function (to be specified in Step 25) links the new `media_object_id` to the draft challenge and clears the old reference. This linkage function is a Step 25 contract item.

### 7.4 `public.remove_content`

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
1. Validate moderator.
2. If `p_report_id IS NOT NULL`: verify report `status = 'pending'` and `target_type = 'comment'` and `target_id = p_target_id`.
3. `SELECT text, moderator_removed_at FROM public.comments WHERE id = p_target_id FOR UPDATE`.
4. Verify `moderator_removed_at IS NULL` (idempotent guard).
5. `INSERT moderation_actions RETURNING id` → `v_action_id`.
6. `INSERT private.moderation_evidence (evidence_type = 'comment_text', evidence_text = original_text, moderation_action_id = v_action_id)`.
7. `UPDATE comments SET text = '[removed by moderator]', moderator_removed_at = now()`.
8. Action report if provided (step 6 of standard order).

**For `'clue'`:**
Same pattern. Evidence type `'clue_text'`. `UPDATE clues SET moderator_removed_at = now()` (text is preserved in evidence; public RLS hides the clue row).

**For `'challenge'`:**
1. Validate moderator.
2. Report verification if provided.
3. `SELECT state, media_object_id FROM public.challenges WHERE id = p_target_id FOR UPDATE`.
4. Verify not already cancelled or removed.
5. `INSERT moderation_actions RETURNING id`.
6. Read `re_encoded_storage_key` from `private.media_storage_keys` for the challenge's `media_object_id`. Insert `private.moderation_evidence (evidence_type = 'media_metadata', ...)`.
7. `UPDATE challenges SET state = 'cancelled', cancellation_reason = 'moderation_action', moderator_removed_at = now()`.
8. `UPDATE media_objects SET status = 'removed', has_pending_report = false WHERE id = media_object_id`.
9. Action report.

### 7.5 `public.remove_media`

Handles `media_object` reports: a live `ready` photo that has been reported.

```
public.remove_media(
  p_media_object_id uuid,
  p_moderator_id    uuid,
  p_report_id       uuid,   -- required for media_object reports
  p_reason          text
) → void
```

1. Validate moderator.
2. Verify `p_report_id` is `pending`, `target_type = 'media_object'`, `target_id = p_media_object_id`.
3. `SELECT status, has_pending_report FROM media_objects WHERE id = p_media_object_id FOR UPDATE`.
4. Verify `status = 'ready'`.
5. Find the challenge linked to this media object (via `upload_sessions` or `challenges.media_object_id`).
6. `INSERT moderation_actions RETURNING id`.
7. Read `re_encoded_storage_key`; insert `private.moderation_evidence`.
8. `UPDATE media_objects SET status = 'removed', moderated_at = now(), has_pending_report = false`.
9. `UPDATE challenges SET state = 'cancelled', cancellation_reason = 'moderation_action', moderator_removed_at = now() WHERE media_object_id = p_media_object_id AND state NOT IN ('cancelled','revealed')`.
10. Action report.

**Avatar media:** V1 has no user-uploadable avatar photos (Section 1, decision 4). No avatar removal path needed.

### 7.6 `public.get_media_key_for_report`

Service-only function covering both pending-review and ready media linked to a report.

```
public.get_media_key_for_report(p_report_id uuid)
→ TABLE(
    media_object_id   uuid,
    re_encoded_storage_key text,
    media_status      text,
    challenge_id      uuid,
    uploader_id       uuid
  )
```

Returns the storage key for:
- `pending_review` media objects (regardless of report linkage); and
- `ready` media objects where `target_type = 'media_object'` and `target_id` in the report.

Returns no row if media is not in an inspectable state. Callers: service role. EXECUTE granted to `service_role`.

This replaces `get_pending_review_media_key` from Rev 2.

### 7.7 `public.get_moderation_queue`

Unchanged from Rev 2. Includes:
- `pending_report` rows from `content_reports WHERE status = 'pending'`.
- `pending_review_photo` rows from `media_objects WHERE status = 'pending_review'`.

### 7.8 `public.get_report_for_review`

Unchanged from Rev 2. For `media_object` reports, `target_summary = NULL` (moderator uses `get_media_key_for_report`).

### 7.9 `public.get_poster_media_status`

Unchanged from Rev 2. Reporters see only `status` and `rejection_message`. `reviewed_by` not returned.

### 7.10 `public.suspend_user`

Unchanged from Rev 2. Validates moderator per Section 5.2.

### 7.11 `public.reinstate_user`

Unchanged from Rev 2. Validates moderator.

### 7.12 `public.dismiss_report`

```
public.dismiss_report(p_report_id uuid, p_moderator_id uuid, p_reason text) → void
```

1. Validate moderator.
2. `SELECT status, target_type, target_id FROM content_reports WHERE id = p_report_id FOR UPDATE`.
3. Verify `status = 'pending'`.
4. **`INSERT INTO moderation_actions (action_type = 'report_dismissed', target_type, target_id, report_id = p_report_id, reason = p_reason, moderator_id = p_moderator_id) RETURNING id`.**
5. If `target_type = 'media_object'`: `UPDATE media_objects SET has_pending_report = false WHERE id = target_id`.
6. `UPDATE content_reports SET status = 'dismissed', reviewed_at = now(), reviewed_by = p_moderator_id`.

### 7.13 `public.action_report`

For cases where the corresponding moderation action was recorded separately (e.g., `remove_content` already actions the report inline). When called standalone:

1. Validate moderator.
2. `SELECT status FROM content_reports WHERE id = p_report_id FOR UPDATE`.
3. Verify `status = 'pending'`.
4. `INSERT INTO moderation_actions (action_type = 'report_actioned', ...) RETURNING id`.
5. `UPDATE content_reports SET status = 'actioned', reviewed_at, reviewed_by`.

### 7.14 `public.check_text_content`

Unchanged from Rev 2. Returns `true` if content passes. Edge Function early validation only; trigger is authoritative.

---

## Section 8 — Reporter-Visible Report Data

The RLS SELECT policy on `public.content_reports` must exclude `reviewed_by`. Since PostgreSQL RLS operates at the row level, not the column level, column-level exclusion requires a view or RPC.

**Approach:** Create a `public.get_my_reports() → TABLE(...)` function that returns only the reporter-safe columns. The `content_reports` table's direct SELECT policy for `authenticated` is restricted to a minimal set via a view:

```sql
CREATE VIEW public.my_reports AS
  SELECT id, target_type, target_id, category, detail, status, created_at, reviewed_at
  FROM public.content_reports
  WHERE reporter_id = private.auth_uid();
```

RLS on `public.content_reports` for `authenticated`: **no SELECT policy** (table is not directly queryable by authenticated users). Access is only through `public.my_reports` view. The view inherits the `WHERE reporter_id = auth_uid()` filter and exposes no `reviewed_by` column.

Alternatively, `report_content` could return the columns the reporter needs at INSERT time, and future status checks use an RPC. Either approach is acceptable; the view is simpler. Codex to confirm preferred approach.

---

## Section 9 — Cleanup Contracts

### 9.1 State machine for rejected/removed media

```
pending_review → rejected  (via reject_photo; cleanup needed)
pending_review → ready     (via approve_photo; no cleanup)
ready          → removed   (via remove_content/remove_media; cleanup needed)
rejected       → cleaned   (after storage deletion)
removed        → cleaned   (after storage deletion)
```

No transition from `rejected` or `removed` to any other state.

### 9.2 `public.claim_moderation_media_cleanup`

```
public.claim_moderation_media_cleanup(p_batch_size int DEFAULT 10)
→ TABLE(
    media_object_id    uuid,
    storage_key        text,
    status             text   -- 'rejected' or 'removed'
  )
```

Claims rows for cleanup using a lease:

```sql
UPDATE public.media_objects
SET moderation_cleanup_leased_until = now() + interval '10 minutes'
WHERE id IN (
  SELECT id FROM public.media_objects
  WHERE status IN ('rejected','removed')
    AND has_pending_report = false  -- never clean while a report is pending
    AND (moderation_cleanup_leased_until IS NULL
         OR moderation_cleanup_leased_until < now())
  ORDER BY moderated_at ASC
  LIMIT p_batch_size
  FOR UPDATE SKIP LOCKED
)
RETURNING id, (SELECT re_encoded_storage_key FROM private.media_storage_keys WHERE media_object_id = id), status;
```

Callers: service role (cleanup worker). EXECUTE granted to `service_role`.

### 9.3 `public.mark_moderation_media_cleaned`

```
public.mark_moderation_media_cleaned(p_media_object_id uuid) → void
```

Transitions `rejected` or `removed` → `cleaned`. Must verify current status is one of the expected states before updating.

```sql
UPDATE public.media_objects
SET status = 'cleaned', moderation_cleanup_leased_until = NULL
WHERE id = p_media_object_id AND status IN ('rejected','removed');

IF NOT FOUND THEN
  RAISE EXCEPTION 'FK_WRONG_STATE';
END IF;
```

Callers: service role. EXECUTE granted to `service_role`.

### 9.4 Cleanup worker procedure for rejected/removed media

```
Part N — Moderation media cleanup:
1. Call claim_moderation_media_cleanup(batch_size := 10).
2. For each claimed row:
   a. Attempt storage deletion of storage_key.
   b. On success: call mark_moderation_media_cleaned(media_object_id).
   c. On storage 404 (already gone): call mark_moderation_media_cleaned (treat as success).
   d. On other error: log failure; do not call mark_moderation_media_cleaned; lease expires and row is re-claimable.
3. Log results.
```

The `has_pending_report = false` guard in `claim_moderation_media_cleanup` ensures that moderation review can proceed before cleanup. When `dismiss_report` or `action_report` / `remove_media` resolves the report, `has_pending_report` is set to `false`, and the object becomes eligible for cleanup on the next worker pass.

### 9.5 Evidence retention cleanup — 90-day contract

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

This function is called by a scheduled job (daily cadence). The scheduled job setup is a deployment operational item — the function definition is part of V2 migration. After cleanup, the original text and storage metadata are gone; the `moderation_actions` row (immutable) remains as the record that the action occurred.

### 9.6 Concurrent moderation decision prevention

`approve_photo`, `reject_photo`, `remove_media`, and `remove_content` (for challenge) all begin with:

```sql
SELECT ... FROM public.media_objects WHERE id = p_media_object_id FOR UPDATE;
```

This row-level lock prevents two concurrent moderator decisions on the same object from both succeeding. The second caller blocks until the first commits, then reads the updated `status` and fails the state check.

---

## Section 10 — Block Eligibility at `activate_challenge`

From Rev 2 Section 7.1, unchanged. `activate_challenge` V2 excludes blocked pairs from the eligibility snapshot. This applies to **future activations only**. For challenges already active when a block is set:

- The eligible_participants rows already exist and are not removed.
- The carve-out in `hide_blocked_challenges` (Section 4.3) allows existing eligible participants to still see the challenge (read-only).
- The RESTRICTIVE INSERT policies (Section 4.2) prevent new guesses/comments/reactions between the pair.
- No modification to `eligible_participants` is made when a block is set.

---

## Section 11 — Acceptance Criteria and Test Matrix (Revised)

### 11.1 Text filtering

| # | Setup | Action | Expected |
|---|---|---|---|
| 1.1 | Term "badword" in blocked_terms | Authenticated user INSERTs comment with "badword" | `FK_CONTENT_FILTERED` raised by trigger |
| 1.2 | Term in blocked_terms | Authenticated user INSERTs clue with blocked term | Trigger raises |
| 1.3 | Term in blocked_terms | Authenticated user UPDATEs profile display_name with blocked term | Trigger raises |
| 1.4 | Term in blocked_terms | Authenticated user INSERTs group with blocked term in name | Trigger raises |
| 1.5 | Term in blocked_terms | Authenticated user INSERTs alias with blocked term in display_value | Trigger raises |
| 1.6 | Term in blocked_terms | challenge_secrets INSERT with blocked term in story | Trigger raises |
| 1.7 | Comment with blocked text | `remove_content('comment', ...)` runs (forkensics_executor context) | Sets text to `'[removed by moderator]'`; trigger passes (placeholder not a blocked term) |
| 1.8 | No blocked terms | All INSERT/UPDATE paths above | All succeed |
| 1.9 | New term added to blocked_terms | Subsequent INSERT with that term | Blocked immediately (no migration required) |
| 1.10 | Service role direct INSERT | Service role inserts comment bypassing RLS | Text filter trigger still fires (triggers fire regardless of RLS bypass) |

### 11.2 RESTRICTIVE policy composition — V1 behavior unchanged

| # | Setup | Action | Expected |
|---|---|---|---|
| 2.1 | No block, no suspension | Authenticated member INSERTs comment on group challenge | Succeeds (permissive policy passes; no restrictive policy rejects) |
| 2.2 | No block, no suspension | Authenticated member SELECTs comments on shared challenge | All comments visible; V1 Table Talk visibility rules apply unchanged |
| 2.3 | No block, no suspension | Authenticated member SELECTs challenges in their group | All challenges visible; V1 visibility rules apply unchanged |
| 2.4 | No block, no suspension | Authenticated member INSERTs guess on active challenge | Succeeds |
| 2.5 | No block, no suspension | Authenticated non-member attempts to INSERT comment | Fails (V1 permissive policy guard; restrictive policies do not widen access) |

### 11.3 Suspension enforcement

| # | Setup | Action | Expected |
|---|---|---|---|
| 3.1 | User A suspended | A attempts INSERT comment | Restrictive policy `enforce_not_suspended` fails; error returned |
| 3.2 | User A suspended | A attempts INSERT guess | Fails |
| 3.3 | User A suspended | A calls `report_content` | Permitted |
| 3.4 | User A suspended | A calls `block_user` | Permitted |
| 3.5 | User A suspended | A calls `reveal_challenge` or `cancel_challenge` on own challenge | Permitted |
| 3.6 | User A reinstated | A attempts INSERT comment | Succeeds |

### 11.4 Block enforcement — new interactions

| # | Setup | Action | Expected |
|---|---|---|---|
| 4.1 | A blocks B | B attempts INSERT guess on A's challenge | `enforce_no_block_guess` restrictive policy fails |
| 4.2 | A blocks B | A attempts INSERT comment on B's challenge | `enforce_no_block_comment` fails |
| 4.3 | A blocks B | B attempts INSERT reaction on A's challenge | `enforce_no_block_reaction` fails |
| 4.4 | B blocks A (reverse direction) | B attempts INSERT guess on A's challenge | Fails (has_block_with_poster checks both directions) |
| 4.5 | No block | All above actions | Succeed |

### 11.5 Block enforcement — content visibility

| # | Setup | Action | Expected |
|---|---|---|---|
| 5.1 | A blocks B | A SELECTs comments on shared challenge | B's comments not returned |
| 5.2 | A blocks B | B SELECTs comments on shared challenge | A's comments not returned (bidirectional via has_block_with) |
| 5.3 | A blocks B | A SELECTs challenges | B's challenges (posted after block) not returned |
| 5.4 | A blocks B; B is eligible participant in A's active challenge | B SELECTs challenges | A's challenge returned (carve-out applies; eligible_participants row exists) |
| 5.5 | A blocks B; B is eligible participant in A's active challenge | B attempts INSERT new guess | Fails (INSERT restrictive policy; carve-out only affects SELECT) |
| 5.6 | A blocks B | B queries user_blocks | A's block row NOT returned (blocker_id = auth_uid() only) |
| 5.7 | No block | A SELECTs all comments | All comments visible |

### 11.6 Moderation — photo lifecycle

| # | Setup | Action | Expected |
|---|---|---|---|
| 6.1 | finalize_upload_session completes | Check media_objects | status = 'pending_review'; re_encoded_at set |
| 6.2 | Media in pending_review | activate_challenge | Trigger raises (media not ready) |
| 6.3 | Media in pending_review | media-serve request | 404 FK_NOT_FOUND |
| 6.4 | approve_photo called | Check media_objects | status = 'ready'; moderated_at set |
| 6.5 | After approval | media-serve request | 200 with image |
| 6.6 | reject_photo called | Check media_objects | status = 'rejected'; moderation_evidence row inserted |
| 6.7 | After rejection | media-serve request | 404 |
| 6.8 | Cleanup worker runs | After rejection, storage deleted | status = 'cleaned' |
| 6.9 | Two concurrent approve_photo + reject_photo calls | Race | Second call fails FK_WRONG_STATE (row lock prevents both succeeding) |

### 11.7 Moderation — comment removal

| # | Setup | Action | Expected |
|---|---|---|---|
| 7.1 | remove_content('comment', ...) | Check comments | text = '[removed by moderator]'; moderator_removed_at set |
| 7.2 | Post-removal | SELECT comment | Placeholder text returned |
| 7.3 | Post-removal | Check private.moderation_evidence | Original text present with correct moderation_action_id |
| 7.4 | Post-removal | Attempt to access moderation_evidence via PostgREST | 404 or 401 (private schema) |

### 11.8 Moderation — challenge removal

| # | Setup | Action | Expected |
|---|---|---|---|
| 8.1 | remove_content('challenge', ...) | Check challenges | state = 'cancelled'; cancellation_reason = 'moderation_action'; moderator_removed_at set |
| 8.2 | Post-removal | media-serve | 403 FK_FORBIDDEN |
| 8.3 | Post-removal | Check media_objects | status = 'removed' |
| 8.4 | Cleanup runs | Storage deletion | status = 'cleaned' |

### 11.9 Reporting

| # | Setup | Action | Expected |
|---|---|---|---|
| 9.1 | Valid accessible target | report_content called | Report inserted; report_id returned |
| 9.2 | Inaccessible target | report_content called | FK_NOT_FOUND (same response for nonexistent and unauthorized) |
| 9.3 | Duplicate pending report | Second report_content call | Idempotent; returns existing report_id |
| 9.4 | Prior report resolved | New report_content call | New report created |
| 9.5 | More than 10 reports in 1 hour | 11th call | FK_RATE_LIMITED |
| 9.6 | media_object report | report_content called | has_pending_report = true on media_objects |
| 9.7 | media_object with pending report | Cleanup worker claim | Not claimed (has_pending_report = true) |
| 9.8 | Report dismissed | Check media_objects | has_pending_report = false |

### 11.10 Moderator identity

| # | Setup | Action | Expected |
|---|---|---|---|
| 10.1 | p_moderator_id not in private.moderators | approve_photo | FK_UNAUTHORIZED raised |
| 10.2 | p_moderator_id valid moderator | approve_photo | Succeeds |
| 10.3 | Moderator removed from private.moderators | approve_photo called immediately after | FK_UNAUTHORIZED (no cache; re-validated per call) |
| 10.4 | Inactive profile in private.moderators | approve_photo | FK_UNAUTHORIZED (is_active check) |

### 11.11 Block + active challenge (Codex confirmed decision)

| # | Setup | Action | Expected |
|---|---|---|---|
| 11.1 | B is eligible_participant in A's active challenge; then A blocks B | B queries the challenge | Challenge visible to B (carve-out) |
| 11.2 | Same setup | B attempts new guess | Fails (enforce_no_block_guess restrictive policy) |
| 11.3 | Same setup | B attempts new comment | Fails |
| 11.4 | Same setup | B's existing guess_attempts rows | Still present; score unchanged |

---

## Section 12 — Open Questions for Codex/GPT Review

1. **Reporter-visible report data (Section 8):** Is the view approach (`public.my_reports`) preferred, or should reporters use an RPC (`get_my_reports()`)? The view is simpler; the RPC is consistent with the rest of the moderation surface. Either is acceptable.

2. **`evidence_sha256` in `private.moderation_evidence`:** Should the hash of the re-encoded object be computed at moderation time inside the DB function (using `pgcrypto` or an external call), or is the storage key alone sufficient as audit metadata for V1?

3. **`activate_challenge` trigger check for `pending_review` media:** Rev 2 states "V2 trigger on public.challenges." This should be a `BEFORE INSERT` trigger on `public.eligible_participants` or a guard in the `activate_challenge` function body, not a table trigger on `challenges`. Confirm the preferred enforcement point.

---

## Section 13 — Success Criteria for Step 24.1

- [ ] Text filter is SECURITY DEFINER with no caller bypass; filtering is applied to all UGC fields including story, alias display_value
- [ ] Avatar photos explicitly disabled in V1
- [ ] `[removed by moderator]` placeholder passes filtering without bypass; confirmed by test 1.7
- [ ] RESTRICTIVE policies confirmed as correct approach for suspension and block enforcement
- [ ] All mutation paths from Section 4.1 covered by suspension restrictive policy
- [ ] Block INSERT restrictive policies cover guess_attempts, comments, reactions
- [ ] Block SELECT restrictive policies cover comments, reactions, challenges with carve-out
- [ ] V1 visibility behavior confirmed unchanged by tests 2.x
- [ ] Partial unique index replaces invalid inline UNIQUE syntax
- [ ] `report_content` handles duplicate pending reports idempotently
- [ ] `report_content` sets `has_pending_report = true` for media_object reports
- [ ] Moderation transaction order corrected (moderation_action first; evidence second; target update third)
- [ ] `dismiss_report` and `action_report` both insert moderation_action rows
- [ ] Report linkage validation (p_report_id target must match action target)
- [ ] `get_media_key_for_report` covers both pending_review and ready media
- [ ] `remove_media` function handles live ready photos and cancels linked challenge
- [ ] `has_pending_report` prevents cleanup before moderator review
- [ ] `claim_moderation_media_cleanup` uses claim/lease/retry pattern
- [ ] `mark_moderation_media_cleaned` transitions state correctly
- [ ] Concurrent moderation decisions prevented by `FOR UPDATE` locks
- [ ] Poster re-upload path after rejection defined (linkage function flagged for Step 25)
- [ ] `private.cleanup_expired_evidence()` defined as a scheduled function
- [ ] Evidence scope: audit metadata (path + hash), not retained image copy
- [ ] `p_moderator_id` source constraint documented; revocation is immediate
- [ ] `reviewed_by` not exposed to reporters; access via `my_reports` view or equivalent
- [ ] Block on active challenge: read-only carve-out; new interactions blocked; test 11.x passes
- [ ] Open questions answered by Codex/GPT
- [ ] No executable SQL written until governance approval
