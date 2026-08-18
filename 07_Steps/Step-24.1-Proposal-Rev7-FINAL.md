# Step 24.1 — UGC Safety and Moderation Contracts
## Final Proposal (Rev 7)

**Status:** Pending approval (Claude → Codex/GPT → Bill)
**Governance gate:** Bill must type `APPROVED: Step 24.1 — UGC Safety and Moderation Contracts` before any SQL in this document is written as executable code or applied to any environment.
**Self-contained:** This document is the complete approved contract. No prior revision (Rev 1–6) need be consulted for implementation.

---

## Part 1 — Scope and Confirmed Decisions

### 1.1 What this step covers

All database schema, trigger replacements, RLS policy additions, SECURITY DEFINER functions, cleanup contracts, and operational procedures required for:

- Text content filtering (blocking objectionable terms in all UGC fields)
- User blocking with server-side immediate enforcement
- Reporting with rate limiting and access verification
- Content moderation (photo approval, content removal, user suspension)
- Upload media moderation gate (`pending_review` before `ready`)
- Apple Guideline 1.2 compliance for invitation-only groups

### 1.2 Excluded from this step

- Swift/SwiftUI implementation
- Automated ML/hash-based image scanning (future)
- Push notification suppression between blocked pairs
- In-app appeals flow (V1: use published support address)
- Community guidelines text, terms of service text
- Age rating questionnaire answers

### 1.3 Effect on Step 25

Step 25 must incorporate these changes before going to Codex:
- `finalize_upload_session`: sets `status = 'pending_review'`, `re_encoded_at = now()`, and stores `sha256_hash`; replaces `challenge.media_object_id` atomically when poster re-uploads
- `media_objects` status constraint includes `'pending_review'`, `'rejected'`, `'removed'`
- `activate_challenge` V2: adds block-pair exclusion and `is_suspended` guard; verifies `media_objects.status = 'ready'` for current `challenges.media_object_id`
- Standard mutation gate in all Edge Functions: add `is_suspended = false` check
- Cleanup worker: Part for `rejected` and `removed` media (using functions in Part 9 below)

### 1.4 Confirmed decisions

1. Comment placeholder: `[removed by moderator]`; evidence is audit metadata only.
2. Block on active challenge: existing eligible participants retain read-only visibility; no new interactions.
3. Moderation-action immutability: unconditional `BEFORE UPDATE OR DELETE` rejection.
4. Avatar photos: disabled in V1. No upload or moderation gate needed.
5. Text-filter trigger: `SECURITY DEFINER` (to access private schema), no caller bypass.
6. RESTRICTIVE RLS policy approach approved.
7. `get_my_reports()` SECURITY DEFINER RPC; direct table SELECT revoked.
8. SHA-256 computed in re-encoding worker; stored in `private.media_storage_keys`; copied to evidence at moderation time.
9. Activation media gate: enforced inside `activate_challenge()` body while challenge row is locked.
10. `reviewed` report status removed. States: `pending`, `actioned`, `dismissed` only.
11. `challenge_secrets`: RESTRICTIVE block policy required.
12. `exclusion_events`: direct authenticated INSERT; branched RESTRICTIVE policy.
13. `apply_correction`: `SECURITY DEFINER`/`forkensics_executor` path; suspension guard inside function.
14. `action_report`: requires same-subject prior substantive action; "no violation" closures use `dismiss_report`.
15. `transfer_group_ownership` and `revoke_group_invite`: permitted for suspended users (safe exit actions); transfer recipient must be active, onboarded, and not suspended; transfer is audited in `group_ownership_history`.
16. Global lock order for challenge/media operations: **content target → all matching pending reports (ascending UUID) → media**.
17. `dismiss_report` acquires only the report lock.
18. `report_content` for removable target types locks the target row before inserting.
19. `FK_ALREADY_REMOVED` not raised on idempotent challenge removal; existing action reused for new pending reports.
20. `redeem_group_invite` requires internal suspension guard.
21. `remove_content` and `remove_media` may be called with `p_report_id = NULL` (proactive moderation); fully audited.
22. `moderation_action_reports.report_id` unique — each resolved report has exactly one resolution link.
23. `media-serve` authorization uses `public.get_media_serve_authorization(media_object_id, viewer_id)` — a public SECURITY DEFINER wrapper; `p_viewer_id` derived from Edge Function's verified JWT, never from request body.
24. Ownership transfer audit in dedicated `public.group_ownership_history` table.
25. Appeals: V1 — already-removed content returns `FK_NOT_FOUND`; users use published support address.

---

## Part 2 — V1 Trigger Replacement

### 2.1 `public.restrict_comment_updates` — complete replacement

The frozen V1 trigger body is replaced in the V2 migration. The trigger attachment (`BEFORE UPDATE ON public.comments FOR EACH ROW`) is unchanged.

The trigger is `SECURITY INVOKER`. Inside a `SECURITY INVOKER` function `current_user` is the actual calling role, making the `forkensics_executor` check safe and meaningful.

```sql
CREATE OR REPLACE FUNCTION public.restrict_comment_updates()
RETURNS trigger
LANGUAGE plpgsql SECURITY INVOKER
SET search_path = ''
AS $$
BEGIN
  -- Path 1: Moderator removal — only forkensics_executor
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
    NEW.moderator_removed_at := clock_timestamp();   -- override caller-supplied value
    RETURN NEW;
  END IF;

  -- Path 2: Author soft-delete
  IF NEW.author_id = private.auth_uid()
     AND OLD.deleted_at IS NULL
     AND NEW.deleted_at IS NOT NULL
     AND NEW.id IS NOT DISTINCT FROM OLD.id
     AND NEW.text IS NOT DISTINCT FROM OLD.text
     AND NEW.challenge_id IS NOT DISTINCT FROM OLD.challenge_id
     AND NEW.posted_at IS NOT DISTINCT FROM OLD.posted_at
     AND NEW.moderator_removed_at IS NOT DISTINCT FROM OLD.moderator_removed_at
  THEN
    NEW.deleted_at := clock_timestamp();             -- override caller-supplied value
    RETURN NEW;
  END IF;

  RAISE EXCEPTION 'FK_COMMENT_IMMUTABLE: comment update not permitted';
END;
$$;
```

Column-level GRANTs prevent `authenticated` from supplying `moderator_removed_at`; the trigger's `current_user` check is an independent additional layer.

---

## Part 3 — Schema

### 3.1 `public.profiles` — addition

```sql
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS is_suspended boolean NOT NULL DEFAULT false;
```

Only `is_suspended` is on `public.profiles`. All suspension details (reason, timestamps, responsible moderator) are in `private.profile_suspensions`.

### 3.2 `public.content_reports`

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
  CONSTRAINT cr_status_check
    CHECK (status IN ('pending','actioned','dismissed')),
  CONSTRAINT cr_detail_check
    CHECK (detail IS NULL OR length(detail) <= 500)
);

-- One unresolved report per reporter+target+category
CREATE UNIQUE INDEX content_reports_unresolved_dedup
  ON public.content_reports (reporter_id, target_type, target_id, category)
  WHERE status = 'pending';

CREATE INDEX ON public.content_reports (status, created_at);
CREATE INDEX ON public.content_reports (reporter_id);
CREATE INDEX ON public.content_reports (target_type, target_id) WHERE status = 'pending';
```

`reviewed_by` is populated by moderation functions but NOT returned to reporters. Access via `get_my_reports()` RPC only.

No SELECT policy for `authenticated` on this table. Service role has full access.

### 3.3 `public.user_blocks`

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

**RLS SELECT:** `blocker_id = private.auth_uid()` only. Blocked party cannot query who blocked them.

No direct INSERT, UPDATE, or DELETE. Use `block_user` / `unblock_user` functions.

### 3.4 `public.moderation_actions`

```sql
CREATE TABLE IF NOT EXISTS public.moderation_actions (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  moderator_id    uuid        NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  action_type     text        NOT NULL,
  target_type     text,
  target_id       uuid,
  report_id       uuid        REFERENCES public.content_reports(id) ON DELETE RESTRICT,
  prior_action_id uuid        REFERENCES public.moderation_actions(id) ON DELETE RESTRICT,
  reason          text        NOT NULL,
  created_at      timestamptz NOT NULL DEFAULT clock_timestamp(),

  CONSTRAINT ma_action_type_check
    CHECK (action_type IN (
      'photo_approved','photo_rejected','photo_removed',
      'content_removed','user_suspended','user_reinstated',
      'report_actioned','report_dismissed'
    )),
  CONSTRAINT ma_target_type_check
    CHECK (target_type IS NULL OR
           target_type IN ('challenge','comment','clue','profile','media_object')),
  CONSTRAINT ma_reason_check
    CHECK (length(trim(reason)) BETWEEN 1 AND 500)
);

-- Immutability: BEFORE UPDATE OR DELETE → RAISE EXCEPTION
CREATE INDEX ON public.moderation_actions (target_type, target_id);
CREATE INDEX ON public.moderation_actions (moderator_id, created_at);
```

No SELECT policy for `authenticated`. Service role only via SECURITY DEFINER functions.

### 3.5 `private.moderation_action_reports`

```sql
CREATE TABLE IF NOT EXISTS private.moderation_action_reports (
  moderation_action_id  uuid NOT NULL
    REFERENCES public.moderation_actions(id) ON DELETE RESTRICT,
  report_id             uuid NOT NULL
    REFERENCES public.content_reports(id) ON DELETE RESTRICT,
  created_at            timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY (moderation_action_id, report_id),

  -- Each resolved report must have exactly one resolution link.
  CONSTRAINT moderation_action_reports_one_resolution UNIQUE (report_id)
);

CREATE INDEX ON private.moderation_action_reports (report_id);
-- Immutability: BEFORE UPDATE OR DELETE → RAISE EXCEPTION
```

### 3.6 `private.blocked_terms`

```sql
CREATE TABLE IF NOT EXISTS private.blocked_terms (
  id        uuid  PRIMARY KEY DEFAULT gen_random_uuid(),
  term      text  NOT NULL UNIQUE,
  added_at  timestamptz NOT NULL DEFAULT clock_timestamp(),
  added_by  text  NOT NULL,
  CONSTRAINT blocked_terms_term_check CHECK (length(trim(term)) BETWEEN 1 AND 100)
);
```

Updates take effect immediately for all subsequent inserts/updates without a migration.

### 3.7 `private.moderators`

```sql
CREATE TABLE IF NOT EXISTS private.moderators (
  profile_id  uuid PRIMARY KEY REFERENCES public.profiles(id) ON DELETE RESTRICT,
  added_at    timestamptz NOT NULL DEFAULT clock_timestamp()
);
```

All moderation functions validate `p_moderator_id` against this table AND verify the profile is active. Removing a row immediately revokes access.

### 3.8 `private.profile_suspensions`

```sql
CREATE TABLE IF NOT EXISTS private.profile_suspensions (
  profile_id        uuid        PRIMARY KEY REFERENCES public.profiles(id) ON DELETE RESTRICT,
  is_suspended      boolean     NOT NULL DEFAULT false,
  suspended_at      timestamptz,
  suspension_reason text,
  suspended_by      uuid        REFERENCES public.profiles(id) ON DELETE RESTRICT,
  CONSTRAINT ps_consistency CHECK (
    (is_suspended = false
     AND suspended_at IS NULL AND suspension_reason IS NULL AND suspended_by IS NULL)
    OR
    (is_suspended = true
     AND suspended_at IS NOT NULL AND suspension_reason IS NOT NULL AND suspended_by IS NOT NULL)
  )
);
```

A row is created (upserted) for each profile at account creation. `suspend_user` and `reinstate_user` update both this table and `public.profiles.is_suspended` atomically.

### 3.9 `private.moderation_evidence`

```sql
CREATE TABLE IF NOT EXISTS private.moderation_evidence (
  id                    uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  moderation_action_id  uuid        NOT NULL
    REFERENCES public.moderation_actions(id) ON DELETE RESTRICT,
  evidence_type         text        NOT NULL,
  evidence_text         text,
  evidence_storage_key  text,
  evidence_sha256       text,
  retained_until        timestamptz NOT NULL
    DEFAULT (clock_timestamp() + interval '90 days'),
  created_at            timestamptz NOT NULL DEFAULT clock_timestamp(),

  CONSTRAINT me_evidence_type_check
    CHECK (evidence_type IN ('comment_text','clue_text','media_metadata')),
  -- For media_metadata: both key and hash must be present
  CONSTRAINT me_media_integrity CHECK (
    evidence_type != 'media_metadata'
    OR (evidence_storage_key IS NOT NULL AND evidence_sha256 IS NOT NULL)
  )
);

CREATE INDEX ON private.moderation_evidence (retained_until);
```

`evidence_sha256` copies from `private.media_storage_keys.sha256_hash` at moderation time. If the hash is NULL (pre-V2 fixture), the moderation function raises `FK_MEDIA_METADATA_INCOMPLETE` and aborts.

Retention: 90 days. After expiry, original text and storage metadata are deleted; the immutable `moderation_actions` row remains.

### 3.10 Column additions to existing tables

```sql
-- public.challenges
ALTER TABLE public.challenges
  ADD COLUMN IF NOT EXISTS moderator_removed_at timestamptz;

-- public.comments
ALTER TABLE public.comments
  ADD COLUMN IF NOT EXISTS moderator_removed_at timestamptz;

-- public.clues
ALTER TABLE public.clues
  ADD COLUMN IF NOT EXISTS moderator_removed_at timestamptz;

-- public.media_objects (cleanup lease; moderated timestamp)
ALTER TABLE public.media_objects
  ADD COLUMN IF NOT EXISTS moderated_at                     timestamptz,
  ADD COLUMN IF NOT EXISTS moderation_cleanup_leased_until  timestamptz;

-- public.media_objects status constraint (full V2 set replaces V1 constraint)
-- New values: pending_review, rejected, removed
-- (exact ALTER for CHECK constraint depends on V1 constraint name; replace accordingly)
```

### 3.11 `private.media_storage_keys` — SHA-256 column

Deployment follows a controlled two-migration plan:

```sql
-- Migration V2a: add nullable column with format constraint
ALTER TABLE private.media_storage_keys
  ADD COLUMN IF NOT EXISTS sha256_hash text
    CONSTRAINT msk_sha256_format CHECK (sha256_hash ~ '^[0-9a-f]{64}$');

-- Before Migration V2b: verify zero NULL rows
--   SELECT count(*) FROM private.media_storage_keys WHERE sha256_hash IS NULL;
-- Must be zero. Delete or reprocess any pre-V2 development fixtures.

-- Migration V2b: enforce NOT NULL
ALTER TABLE private.media_storage_keys
  ALTER COLUMN sha256_hash SET NOT NULL;
```

No placeholder or synthetic hashes. The re-encoding worker computes and supplies the real hash.

### 3.12 `public.group_ownership_history`

```sql
CREATE TABLE IF NOT EXISTS public.group_ownership_history (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  group_id        uuid        NOT NULL REFERENCES public.groups(id) ON DELETE RESTRICT,
  previous_owner  uuid        NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  new_owner       uuid        NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  transferred_at  timestamptz NOT NULL DEFAULT clock_timestamp()
  -- Immutability: BEFORE UPDATE OR DELETE → RAISE EXCEPTION
);

CREATE INDEX ON public.group_ownership_history (group_id);
```

No SELECT policy for `authenticated`. Service role only.

---

## Part 4 — RLS Helper Functions

All helpers: owned by `forkensics_rls_helper`, `SECURITY DEFINER`, `SET search_path = ''`, `STABLE`.

### 4.1 `private.can_view_challenge(p_challenge_id uuid) → boolean`

For use in RLS policies (where `auth_uid()` is the viewer).

```sql
CREATE OR REPLACE FUNCTION private.can_view_challenge(p_challenge_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.challenges c
    WHERE c.id = p_challenge_id
      AND (
        c.poster_id = private.auth_uid()
        OR (
          c.posted_at IS NOT NULL
          AND EXISTS (
            SELECT 1 FROM public.group_members gm
            WHERE gm.group_id = c.group_id AND gm.player_id = private.auth_uid()
          )
          AND (
            NOT EXISTS (
              SELECT 1 FROM public.user_blocks ub
              WHERE (ub.blocker_id = private.auth_uid() AND ub.blocked_id = c.poster_id)
                 OR (ub.blocker_id = c.poster_id    AND ub.blocked_id = private.auth_uid())
            )
            OR EXISTS (
              SELECT 1 FROM public.eligible_participants ep
              WHERE ep.challenge_id = p_challenge_id AND ep.player_id = private.auth_uid()
            )
          )
        )
      )
  );
$$;
```

### 4.2 `private.can_viewer_access_challenge(p_challenge_id uuid, p_viewer_id uuid) → boolean`

For service-role callers where `auth_uid()` returns NULL.

```sql
CREATE OR REPLACE FUNCTION private.can_viewer_access_challenge(
  p_challenge_id uuid, p_viewer_id uuid
) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
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

### 4.3 `private.has_block_with(p_profile_id uuid) → boolean`

```sql
CREATE OR REPLACE FUNCTION private.has_block_with(p_profile_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.user_blocks
    WHERE (blocker_id = private.auth_uid() AND blocked_id = p_profile_id)
       OR (blocker_id = p_profile_id    AND blocked_id = private.auth_uid())
  );
$$;
```

### 4.4 `private.has_block_with_poster(p_challenge_id uuid) → boolean`

```sql
CREATE OR REPLACE FUNCTION private.has_block_with_poster(p_challenge_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.challenges c
    JOIN public.user_blocks ub
      ON (ub.blocker_id = private.auth_uid() AND ub.blocked_id = c.poster_id)
      OR (ub.blocker_id = c.poster_id AND ub.blocked_id = private.auth_uid())
    WHERE c.id = p_challenge_id
  );
$$;
```

---

## Part 5 — Text Filtering

### 5.1 Trigger function

`SECURITY DEFINER` to access `private.blocked_terms`. No bypass of any kind. Moderator placeholder `[removed by moderator]` is not a blocked term and passes naturally.

```sql
CREATE OR REPLACE FUNCTION private.check_text_content_trigger()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_text text;
BEGIN
  v_text := CASE
    WHEN TG_TABLE_NAME = 'comments'                                          THEN NEW.text
    WHEN TG_TABLE_NAME = 'clues'                                             THEN NEW.text
    WHEN TG_TABLE_NAME = 'profiles'                                          THEN NEW.display_name
    WHEN TG_TABLE_NAME = 'groups'                                            THEN NEW.name
    WHEN TG_TABLE_NAME = 'challenges'                                        THEN NEW.public_city_display
    WHEN TG_TABLE_NAME = 'challenge_secrets' AND TG_ARGV[0] = 'display_dish'       THEN NEW.display_dish
    WHEN TG_TABLE_NAME = 'challenge_secrets' AND TG_ARGV[0] = 'display_restaurant' THEN NEW.display_restaurant
    WHEN TG_TABLE_NAME = 'challenge_secrets' AND TG_ARGV[0] = 'story'              THEN NEW.story
    WHEN TG_TABLE_NAME = 'challenge_answer_aliases'                          THEN NEW.display_value
    ELSE NULL
  END;

  IF v_text IS NULL THEN RETURN NEW; END IF;

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

### 5.2 Trigger attachments

```sql
CREATE OR REPLACE TRIGGER comment_text_filter
  BEFORE INSERT ON public.comments FOR EACH ROW
  EXECUTE FUNCTION private.check_text_content_trigger();

CREATE OR REPLACE TRIGGER clue_text_filter
  BEFORE INSERT ON public.clues FOR EACH ROW
  EXECUTE FUNCTION private.check_text_content_trigger();

CREATE OR REPLACE TRIGGER profile_name_filter
  BEFORE INSERT OR UPDATE ON public.profiles FOR EACH ROW
  EXECUTE FUNCTION private.check_text_content_trigger();

CREATE OR REPLACE TRIGGER group_name_filter
  BEFORE INSERT OR UPDATE ON public.groups FOR EACH ROW
  EXECUTE FUNCTION private.check_text_content_trigger();

CREATE OR REPLACE TRIGGER challenge_city_filter
  BEFORE INSERT OR UPDATE ON public.challenges FOR EACH ROW
  EXECUTE FUNCTION private.check_text_content_trigger();

CREATE OR REPLACE TRIGGER secret_dish_filter
  BEFORE INSERT OR UPDATE ON public.challenge_secrets FOR EACH ROW
  EXECUTE FUNCTION private.check_text_content_trigger('display_dish');

CREATE OR REPLACE TRIGGER secret_restaurant_filter
  BEFORE INSERT OR UPDATE ON public.challenge_secrets FOR EACH ROW
  EXECUTE FUNCTION private.check_text_content_trigger('display_restaurant');

CREATE OR REPLACE TRIGGER secret_story_filter
  BEFORE INSERT OR UPDATE ON public.challenge_secrets FOR EACH ROW
  EXECUTE FUNCTION private.check_text_content_trigger('story');

CREATE OR REPLACE TRIGGER alias_display_value_filter
  BEFORE INSERT ON public.challenge_answer_aliases FOR EACH ROW
  EXECUTE FUNCTION private.check_text_content_trigger();
```

---

## Part 6 — RLS Policy Additions

All new policies are `AS RESTRICTIVE` — they AND with existing V1 permissive policies and cannot broaden access.

### 6.1 Suspension enforcement

The suspension check: `NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = private.auth_uid() AND is_suspended = true)`.

| Table | Policy name | Operations |
|---|---|---|
| `public.comments` | `suspend_block_insert` | INSERT |
| `public.clues` | `suspend_block_insert` | INSERT |
| `public.reactions` | `suspend_block_insert` | INSERT |
| `public.guess_attempts` | `suspend_block_insert` | INSERT |
| `public.challenges` | `suspend_block_insert` | INSERT |
| `public.challenges` | `suspend_block_update` | UPDATE |
| `public.challenge_secrets` | `suspend_block_insert` | INSERT |
| `public.challenge_secrets` | `suspend_block_update` | UPDATE |
| `public.challenge_answer_aliases` | `suspend_block_insert` | INSERT |
| `public.challenge_answer_aliases` | `suspend_block_update` | UPDATE |
| `public.group_members` | `suspend_block_insert` | INSERT |
| `public.profiles` | `suspend_block_update` | UPDATE |
| `public.groups` | `suspend_block_insert` | INSERT |
| `public.groups` | `suspend_block_update` | UPDATE |

### 6.2 `exclusion_events` — branched suspension policy

Suspended users may self-withdraw but may not remove another participant:

```sql
CREATE POLICY suspend_exclusion_insert AS RESTRICTIVE ON public.exclusion_events
  FOR INSERT TO authenticated
  WITH CHECK (
    NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = private.auth_uid() AND is_suspended = true)
    OR (reason = 'withdrew' AND player_id = private.auth_uid())
  );
```

### 6.3 Block enforcement — INSERT (new interactions)

```sql
CREATE POLICY enforce_no_block_guess AS RESTRICTIVE ON public.guess_attempts
  FOR INSERT TO authenticated
  WITH CHECK (NOT private.has_block_with_poster(challenge_id));

CREATE POLICY enforce_no_block_comment AS RESTRICTIVE ON public.comments
  FOR INSERT TO authenticated
  WITH CHECK (NOT private.has_block_with_poster(challenge_id));

CREATE POLICY enforce_no_block_reaction AS RESTRICTIVE ON public.reactions
  FOR INSERT TO authenticated
  WITH CHECK (NOT private.has_block_with_poster(challenge_id));
```

### 6.4 Block enforcement — SELECT (content visibility)

```sql
-- Challenges: hide from blocked poster (with carve-outs)
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

-- Comments: block-aware challenge access + hide blocked authors
CREATE POLICY block_aware_visibility AS RESTRICTIVE ON public.comments
  FOR SELECT TO authenticated
  USING (
    private.can_view_challenge(challenge_id)
    AND NOT private.has_block_with(author_id)
  );

-- Reactions: same pattern
CREATE POLICY block_aware_visibility AS RESTRICTIVE ON public.reactions
  FOR SELECT TO authenticated
  USING (
    private.can_view_challenge(challenge_id)
    AND NOT private.has_block_with(player_id)
  );
```

### 6.5 Block-aware challenge visibility — all challenge-linked child tables

```sql
-- Applied to: clues, challenge_secrets, challenge_answer_aliases, guess_attempts,
--             guess_judgments, score_runs, score_events, correction_events,
--             eligible_participants, exclusion_events

-- Template (replace <table> and <fk>):
CREATE POLICY block_aware_visibility AS RESTRICTIVE ON public.<table>
  FOR SELECT TO authenticated
  USING (private.can_view_challenge(<fk>));
```

### 6.6 `user_blocks` SELECT policy

```sql
CREATE POLICY blocks_select_own ON public.user_blocks
  FOR SELECT TO authenticated
  USING (blocker_id = private.auth_uid());
```

No INSERT, UPDATE, or DELETE policies. Use `block_user` / `unblock_user`.

---

## Part 7 — SECURITY DEFINER Functions

All: owned by `forkensics_executor`, `SET search_path = ''`. EXECUTE grants as specified.

### 7.1 Moderator identity validation (internal)

All moderation functions include this block:

```sql
IF NOT EXISTS (
  SELECT 1 FROM private.moderators m
  JOIN public.profiles p ON p.id = m.profile_id
  WHERE m.profile_id = p_moderator_id AND p.is_active = true
) THEN
  RAISE EXCEPTION 'FK_UNAUTHORIZED: moderator identity not valid';
END IF;
```

### 7.2 Global lock order

For all functions touching challenge and/or media:

**content target → all matching pending reports (ascending `id` UUID) → media**

Every function acquires locks in this order, without exception.

### 7.3 `public.check_text_content(p_text text) → boolean`

Early validation for Edge Functions. Returns `true` if no blocked term found. The trigger is the authoritative enforcement.

EXECUTE granted to `service_role`.

### 7.4 `public.report_content`

EXECUTE granted to `authenticated`.

```
public.report_content(
  p_target_type text,
  p_target_id   uuid,
  p_category    text,
  p_detail      text  -- nullable
) → TABLE(report_id uuid)
```

1. Verify caller is active, onboarded. Suspended callers are permitted.
2. Validate `target_type` and `category` against allowed values.
3. Rate limit: caller must have fewer than 10 pending reports created in the past hour.
4. **Lock and recheck target** (prevents stranded reports racing content removal):

   *`'challenge'`:* `SELECT id, moderator_removed_at FROM challenges WHERE id = p_target_id FOR UPDATE`. Verify `private.can_view_challenge(p_target_id) = true`. Verify `moderator_removed_at IS NULL`.

   *`'comment'`:* `SELECT id, moderator_removed_at, challenge_id FROM comments WHERE id = p_target_id FOR UPDATE`. Verify `moderator_removed_at IS NULL`. Verify Table Talk visibility (challenge revealed, or caller has guessed, or caller is author).

   *`'clue'`:* `SELECT id, moderator_removed_at FROM clues WHERE id = p_target_id FOR UPDATE`. Verify `moderator_removed_at IS NULL`. Verify `can_view_challenge(challenge_id)`.

   *`'media_object'`:* Full lock sequence:
     a. Provisional read: `challenge_id` from `challenges WHERE media_object_id = p_target_id`.
     b. `SELECT id, state, media_object_id FROM challenges WHERE id = challenge_id FOR UPDATE`.
     c. Re-verify `challenges.media_object_id = p_target_id`.
     d. Re-check `private.can_view_challenge(challenge_id)`.
     e. `SELECT id, status FROM media_objects WHERE id = p_target_id FOR UPDATE`.
     f. Verify `status = 'ready'`.

   *`'profile'`:* Verify target is active. Verify caller shares at least one group with target. No lock needed (profiles are not content-removed).

   In all cases: same `FK_NOT_FOUND` response for nonexistent, unauthorized, and already-actioned targets.

5. Prevent self-report.
6. `INSERT INTO content_reports ... ON CONFLICT ON CONSTRAINT content_reports_unresolved_dedup DO NOTHING RETURNING id`.
   If `NOT FOUND` (conflict): `SELECT id FROM content_reports WHERE reporter_id = auth_uid() AND target_type = p_target_type AND target_id = p_target_id AND category = p_category AND status = 'pending'`.
7. Return `report_id`.

### 7.5 `public.block_user(p_blocked_id uuid) → void`

EXECUTE granted to `authenticated`. Suspended callers permitted.

1. Verify caller is active. Target must exist.
2. Self-block prevented.
3. Idempotent INSERT into `user_blocks`.

### 7.6 `public.unblock_user(p_blocked_id uuid) → void`

EXECUTE granted to `authenticated`. Idempotent DELETE where `blocker_id = auth_uid()`.

### 7.7 `public.approve_photo`

EXECUTE granted to `service_role`.

```
public.approve_photo(p_media_object_id uuid, p_moderator_id uuid, p_reason text) → void
```

Lock order: media only (no report involved).

1. Validate moderator.
2. `SELECT status FROM media_objects WHERE id = p_media_object_id FOR UPDATE`. Verify `status = 'pending_review'`.
3. `INSERT moderation_actions (action_type = 'photo_approved') RETURNING id`.
4. `UPDATE media_objects SET status = 'ready', moderated_at = clock_timestamp()`.

### 7.8 `public.reject_photo`

EXECUTE granted to `service_role`.

```
public.reject_photo(p_media_object_id uuid, p_moderator_id uuid, p_reason text) → void
```

Lock order: media only.

1. Validate moderator.
2. `SELECT status FROM media_objects WHERE id = p_media_object_id FOR UPDATE`. Verify `status = 'pending_review'`.
3. Read `sha256_hash` from `private.media_storage_keys`. Raise `FK_MEDIA_METADATA_INCOMPLETE` if NULL.
4. `INSERT moderation_actions (action_type = 'photo_rejected') RETURNING id` → `v_action_id`.
5. `INSERT moderation_evidence (evidence_type = 'media_metadata', evidence_storage_key, evidence_sha256 = sha256_hash, moderation_action_id = v_action_id)`.
6. `UPDATE media_objects SET status = 'rejected', moderated_at = clock_timestamp()`.

Challenge stays in `draft`. Poster retrieves status via `get_poster_media_status`.

### 7.9 `public.remove_content`

EXECUTE granted to `service_role`. `p_report_id` is nullable (proactive moderation allowed).

```
public.remove_content(
  p_target_type  text,   -- 'challenge' | 'comment' | 'clue'
  p_target_id    uuid,
  p_moderator_id uuid,
  p_report_id    uuid,   -- nullable
  p_reason       text
) → void
```

**For `'challenge'`** — full sequence per lock order:

```
1.  Validate moderator.
2.  Lock challenge:
      SELECT id, state, media_object_id, moderator_removed_at
      FROM challenges WHERE id = p_target_id FOR UPDATE.
3.  If moderator_removed_at IS NOT NULL → idempotency path (Section 7.11).
4.  Validate state (see state matrix below).
5.  Resolve v_media_object_id.
6.  Lock all matching pending reports in UUID order:
      SELECT id FROM content_reports
      WHERE status = 'pending'
        AND (
          (target_type = 'challenge' AND target_id = p_target_id)
          OR (target_type = 'media_object' AND target_id = v_media_object_id)
        )
      ORDER BY id FOR UPDATE → v_report_ids[].
7.  If p_report_id IS NOT NULL:
      Verify p_report_id ∈ v_report_ids. Raise FK_REPORT_TARGET_MISMATCH if absent.
8.  Lock media:
      SELECT id, status FROM media_objects
      WHERE id = v_media_object_id FOR UPDATE.
    Validate per media state matrix below.
9.  Read sha256_hash. Raise FK_MEDIA_METADATA_INCOMPLETE if NULL.
10. INSERT moderation_actions (action_type = 'content_removed', target_type = 'challenge',
      target_id = p_target_id, report_id = p_report_id, reason, moderator_id) RETURNING id
      → v_action_id.
11. INSERT moderation_evidence (media_metadata, key, sha256).
12. UPDATE challenges (moderator_removed_at, state per matrix).
13. UPDATE media_objects (status = 'removed', moderated_at).
14. INSERT moderation_action_reports: one row per id in v_report_ids[].
15. UPDATE content_reports SET status = 'actioned', reviewed_at, reviewed_by
      WHERE id = ANY(v_report_ids).
```

**For `'comment'`**:

```
1.  Validate moderator.
2.  Lock comment:
      SELECT id, text, moderator_removed_at FROM comments WHERE id = p_target_id FOR UPDATE.
    If moderator_removed_at IS NOT NULL → idempotency path (Section 7.11).
3.  Lock all matching pending reports:
      SELECT id FROM content_reports
      WHERE target_type = 'comment' AND target_id = p_target_id AND status = 'pending'
      ORDER BY id FOR UPDATE → v_report_ids[].
4.  If p_report_id IS NOT NULL: verify ∈ v_report_ids.
5.  INSERT moderation_actions RETURNING id → v_action_id.
6.  INSERT moderation_evidence (comment_text = original comment.text).
7.  UPDATE comments: text = '[removed by moderator]', moderator_removed_at = clock_timestamp().
8.  INSERT moderation_action_reports per v_report_ids[].
9.  UPDATE content_reports SET status = 'actioned' WHERE id = ANY(v_report_ids).
```

**For `'clue'`**: same as comment. Evidence type `'clue_text'`. UPDATE sets `moderator_removed_at`; clue text not changed (hidden via RLS `WHERE moderator_removed_at IS NULL`).

**Challenge/media state matrix:**

| Challenge state | After removal |
|---|---|
| `draft` | state → `cancelled`, `cancellation_reason = 'moderation_action'`, `moderator_removed_at = clock_timestamp()` |
| `active` | Same |
| `locked` | Same |
| `revealed` | state unchanged; `moderator_removed_at = clock_timestamp()`. Scores preserved. |
| `cancelled` (any) | `moderator_removed_at = clock_timestamp()` if not set; state unchanged. |

| Media status | Action during challenge removal |
|---|---|
| `ready`, `pending_review`, `rejected`, `superseded` | `status = 'removed'`, `moderated_at = clock_timestamp()` |
| `removed`, `cleaned` | Skip media UPDATE (already removed) |
| `processing`, `failed` | Raise `FK_WRONG_STATE`; abort |

### 7.10 `public.remove_media`

EXECUTE granted to `service_role`. `p_report_id` is nullable.

```
public.remove_media(p_media_object_id uuid, p_moderator_id uuid,
                    p_report_id uuid, p_reason text) → void
```

```
1.  Validate moderator.
2.  Provisional read: v_challenge_id from challenges WHERE media_object_id = p_media_object_id.
3.  Lock challenge:
      SELECT id, state, media_object_id, moderator_removed_at
      FROM challenges WHERE id = v_challenge_id FOR UPDATE.
4.  Re-validate challenges.media_object_id = p_media_object_id. Raise FK_LINKAGE_CHANGED if not.
5.  Lock all matching pending reports:
      SELECT id FROM content_reports
      WHERE status = 'pending'
        AND (
          (target_type = 'media_object' AND target_id = p_media_object_id)
          OR (target_type = 'challenge' AND category = 'inappropriate_image'
              AND target_id = v_challenge_id)
        )
      ORDER BY id FOR UPDATE → v_report_ids[].
6.  If p_report_id IS NOT NULL: verify ∈ v_report_ids. Raise FK_REPORT_TARGET_MISMATCH if absent.
7.  Lock media:
      SELECT id, status FROM media_objects WHERE id = p_media_object_id FOR UPDATE.
    Verify status = 'ready'. Otherwise raise FK_WRONG_STATE.
8.  Read sha256_hash. Raise FK_MEDIA_METADATA_INCOMPLETE if NULL.
9.  INSERT moderation_actions (action_type = 'photo_removed', target_type = 'media_object',
      target_id = p_media_object_id, report_id = p_report_id, ...) RETURNING id → v_action_id.
10. INSERT moderation_evidence.
11. UPDATE media_objects SET status = 'removed', moderated_at = clock_timestamp().
12. UPDATE challenges per state matrix (challenge moderator_removed_at, state).
13. INSERT moderation_action_reports per v_report_ids[].
14. UPDATE content_reports SET status = 'actioned' WHERE id = ANY(v_report_ids).
```

### 7.11 Idempotency path (challenge already removed)

Entered when `moderator_removed_at IS NOT NULL` is detected after locking the challenge:

```
1. Find existing action:
   SELECT id FROM moderation_actions
   WHERE action_type = 'content_removed' AND target_type = 'challenge'
     AND target_id = p_target_id
   ORDER BY created_at ASC LIMIT 1 → v_existing_action_id.

2. Lock any remaining matching pending reports (same query, ORDER BY id FOR UPDATE)
   → v_new_report_ids[].

3. INSERT INTO private.moderation_action_reports (moderation_action_id, report_id)
   SELECT v_existing_action_id, id FROM unnest(v_new_report_ids) AS id
   ON CONFLICT ON CONSTRAINT moderation_action_reports_one_resolution DO NOTHING.

4. After INSERT: verify no newly-discovered report is linked to a different action:
   IF EXISTS (
     SELECT 1 FROM private.moderation_action_reports mar
     WHERE mar.report_id = ANY(v_new_report_ids)
       AND mar.moderation_action_id != v_existing_action_id
   ) THEN RAISE EXCEPTION 'FK_RESOLUTION_CONFLICT'; END IF.

5. UPDATE content_reports SET status = 'actioned', reviewed_at, reviewed_by
   WHERE id = ANY(v_new_report_ids).

6. Return (no new moderation_actions or moderation_evidence).
```

### 7.12 `public.suspend_user`

EXECUTE granted to `service_role`.

1. Validate moderator.
2. Verify profile active.
3. Idempotent if already suspended.
4. Atomically: `UPDATE public.profiles SET is_suspended = true WHERE id = p_profile_id`; upsert `private.profile_suspensions`.
5. `INSERT moderation_actions (action_type = 'user_suspended')`.

### 7.13 `public.reinstate_user`

EXECUTE granted to `service_role`.

1. Validate moderator.
2. Verify `is_suspended = true`.
3. Atomically: `UPDATE public.profiles SET is_suspended = false`; update `private.profile_suspensions`.
4. `INSERT moderation_actions (action_type = 'user_reinstated')`.

### 7.14 `public.dismiss_report`

EXECUTE granted to `service_role`. Acquires only the report lock.

```
1. Validate moderator.
2. SELECT id, status FROM content_reports WHERE id = p_report_id FOR UPDATE.
   Verify status = 'pending'.
3. INSERT moderation_actions (action_type = 'report_dismissed', report_id = p_report_id) RETURNING id → v_action_id.
4. INSERT moderation_action_reports (moderation_action_id = v_action_id, report_id = p_report_id).
5. UPDATE content_reports SET status = 'dismissed', reviewed_at = clock_timestamp(), reviewed_by = p_moderator_id.
```

### 7.15 `public.action_report`

EXECUTE granted to `service_role`. For closing a report when the corresponding moderation action was recorded separately.

```
public.action_report(
  p_report_id       uuid,
  p_moderator_id    uuid,
  p_prior_action_id uuid,   -- required; must be a substantive prior action
  p_reason          text
) → void
```

1. Validate moderator.
2. Read prior action: `SELECT action_type, target_type, target_id FROM moderation_actions WHERE id = p_prior_action_id`. Raise `FK_NOT_FOUND` if absent. Verify `action_type NOT IN ('report_dismissed','report_actioned','photo_approved')` — must be a substantive action. Raise `FK_INVALID_PRIOR_ACTION` if non-qualifying.
3. `SELECT target_type, target_id FROM content_reports WHERE id = p_report_id FOR UPDATE`. Verify `status = 'pending'`. Verify `target_type` and `target_id` match the prior action's `target_type` and `target_id`. Raise `FK_REPORT_TARGET_MISMATCH` if mismatch.
4. `INSERT moderation_actions (action_type = 'report_actioned', report_id = p_report_id, prior_action_id = p_prior_action_id) RETURNING id` → `v_action_id`.
5. `INSERT moderation_action_reports (moderation_action_id = v_action_id, report_id = p_report_id)`.
6. `UPDATE content_reports SET status = 'actioned', reviewed_at, reviewed_by`.

### 7.16 `public.get_media_serve_authorization`

EXECUTE granted to `service_role` only. EXECUTE revoked from PUBLIC, `anon`, and `authenticated`.

```
public.get_media_serve_authorization(
  p_media_object_id uuid,
  p_viewer_id       uuid    -- derived from Edge Function's verified JWT; never from request body
) → TABLE(re_encoded_storage_key text)
```

Atomically verifies all conditions and returns the storage key only when all pass:

```sql
CREATE OR REPLACE FUNCTION public.get_media_serve_authorization(
  p_media_object_id uuid,
  p_viewer_id       uuid
) RETURNS TABLE(re_encoded_storage_key text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT msk.re_encoded_storage_key
  FROM public.media_objects mo
  JOIN public.challenges c ON c.media_object_id = mo.id
  JOIN private.media_storage_keys msk ON msk.media_object_id = mo.id
  WHERE mo.id = p_media_object_id
    AND mo.status = 'ready'
    AND c.moderator_removed_at IS NULL
    AND private.can_viewer_access_challenge(c.id, p_viewer_id);
$$;
```

Returns empty set (no row) if any condition fails. The Edge Function treats empty = 403.

Combining authorization and storage-key retrieval in one RPC eliminates a check/use gap.

**Edge Function `media-serve` flow:**
1. Extract `user_id` from verified JWT via `supabaseClient.auth.getUser()`. Never from request body.
2. Call `get_media_serve_authorization(p_media_object_id, user_id)` via service-role connection.
3. If no row returned → 403 FK_FORBIDDEN.
4. Use returned `re_encoded_storage_key` to generate a signed URL via service role.
5. Return signed URL or streamed response.

### 7.17 `public.get_moderation_queue`

EXECUTE granted to `service_role`.

Returns pending reports and pending-review photos ordered by oldest first:

```
→ TABLE(queue_type text, item_id uuid, created_at timestamptz, target_type text,
        target_id uuid, category text, challenge_id uuid)
```

Two result types: `'pending_report'` (from content_reports WHERE status = 'pending') and `'pending_review_photo'` (from media_objects WHERE status = 'pending_review').

### 7.18 `public.get_pending_review_media`

EXECUTE granted to `service_role`.

```
public.get_pending_review_media(p_media_object_id uuid)
→ TABLE(media_object_id uuid, re_encoded_storage_key text,
        challenge_id uuid, uploader_id uuid, re_encoded_at timestamptz)
```

Returns row if `status = 'pending_review'`. No row otherwise.

### 7.19 `public.get_reported_media`

EXECUTE granted to `service_role`.

```
public.get_reported_media(p_report_id uuid)
→ TABLE(media_object_id uuid, re_encoded_storage_key text,
        challenge_id uuid, uploader_id uuid, media_status text,
        report_category text, report_detail text)
```

Returns row if report status = 'pending' and the linked media is in a reviewable state (`ready` or `pending_review`).

### 7.20 `public.get_poster_media_status`

EXECUTE granted to `service_role`.

```
public.get_poster_media_status(p_media_object_id uuid, p_uploader_id uuid)
→ TABLE(status text, rejection_message text)
```

Returns `status` and, if `'rejected'`, the message: "Photo couldn't be approved — choose another photo." No moderator notes or `reviewed_by` returned.

### 7.21 `public.get_my_reports`

EXECUTE granted to `authenticated`. SECURITY DEFINER.

```sql
CREATE OR REPLACE FUNCTION public.get_my_reports()
RETURNS TABLE(id uuid, target_type text, target_id uuid, category text,
              detail text, status text, created_at timestamptz, reviewed_at timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT cr.id, cr.target_type, cr.target_id, cr.category,
         cr.detail, cr.status, cr.created_at, cr.reviewed_at
  FROM public.content_reports cr
  WHERE cr.reporter_id = private.auth_uid();
$$;
```

`reviewed_by` intentionally excluded.

### 7.22 `public.get_report_for_review`

EXECUTE granted to `service_role`.

```
public.get_report_for_review(p_report_id uuid)
→ TABLE(report_id uuid, reporter_id uuid, target_type text, target_id uuid,
        category text, detail text, status text, created_at timestamptz,
        target_summary text)
```

`target_summary`: comment text (for comment targets), clue text (for clue targets), NULL for challenge or media (use get_moderation_queue + get_reported_media for those).

### 7.23 Suspension-gated SECURITY DEFINER functions

The following functions add an `is_suspended` check at entry:

| Function | Note |
|---|---|
| `activate_challenge` | New content creation |
| `create_group` | New content creation |
| `create_group_invite` | New invite |
| `redeem_group_invite` | Group join |
| `apply_correction` | Scoring mutation |

All check: `IF EXISTS (SELECT 1 FROM public.profiles WHERE id = private.auth_uid() AND is_suspended = true) THEN RAISE EXCEPTION 'FK_SUSPENDED'; END IF;` before any other logic.

`transfer_group_ownership` additional guard: verify recipient is active, onboarded, and `is_suspended = false`. Insert into `group_ownership_history`.

### 7.24 `finalize_upload_session` — SHA-256 validation

```sql
-- Inside finalize_upload_session, before any state changes:
IF p_sha256_hash IS NULL OR p_sha256_hash !~ '^[0-9a-f]{64}$' THEN
  RAISE EXCEPTION 'FK_INVALID_HASH: sha256_hash must be 64 lowercase hex characters';
END IF;
```

Parameter declared as `p_sha256_hash text` (PostgreSQL does not support NOT NULL on function parameters). The validation substitutes. Stores hash in `private.media_storage_keys.sha256_hash` atomically with `re_encoded_storage_key`.

### 7.25 `finalize_upload_session` — replacement media pointer

When poster re-uploads after rejection:

1. Function locks the draft challenge `FOR UPDATE`.
2. Creates new `media_object` with `status = 'pending_review'`, `re_encoded_at = clock_timestamp()`.
3. Atomically: `UPDATE challenges SET media_object_id = new_media_object_id WHERE id = challenge_id AND state = 'draft'`. Succeeds even if prior `media_object_id` was `rejected` or `cleaned`.
4. Old rejected/cleaned media object is not modified.
5. After `approve_photo` sets `status = 'ready'` on the new object, `activate_challenge` reads the current pointer and verifies it is `ready`. No separate linkage step.

---

## Part 8 — Cleanup Contracts

### 8.1 `public.claim_moderation_media_cleanup`

EXECUTE granted to `service_role`.

```sql
public.claim_moderation_media_cleanup(p_batch_size int DEFAULT 10)
→ TABLE(media_object_id uuid, storage_key text, status text)
```

Claims `rejected` or `removed` media objects not held by a pending report:

```sql
UPDATE public.media_objects mo
SET moderation_cleanup_leased_until = clock_timestamp() + interval '10 minutes'
WHERE mo.id IN (
  SELECT m.id FROM public.media_objects m
  WHERE m.status IN ('rejected','removed')
    AND (m.moderation_cleanup_leased_until IS NULL
         OR m.moderation_cleanup_leased_until < clock_timestamp())
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
RETURNING mo.id, (
  SELECT msk.re_encoded_storage_key
  FROM private.media_storage_keys msk WHERE msk.media_object_id = mo.id
), mo.status;
```

### 8.2 `public.mark_moderation_media_cleaned`

EXECUTE granted to `service_role`.

```sql
UPDATE public.media_objects
SET status = 'cleaned', moderation_cleanup_leased_until = NULL
WHERE id = p_media_object_id AND status IN ('rejected','removed');

IF NOT FOUND THEN RAISE EXCEPTION 'FK_WRONG_STATE'; END IF;
```

### 8.3 Cleanup worker procedure (Part N of the upload-cleanup-worker)

```
1. Call claim_moderation_media_cleanup(10).
2. For each claimed row:
   a. Delete storage object at storage_key.
   b. 200/204: call mark_moderation_media_cleaned.
   c. 404 (already gone): call mark_moderation_media_cleaned (treat as success).
   d. Other error: log; do not mark cleaned; lease expires; row re-claimable.
```

### 8.4 `private.cleanup_expired_evidence`

```sql
CREATE OR REPLACE FUNCTION private.cleanup_expired_evidence()
RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$
  DELETE FROM private.moderation_evidence WHERE retained_until < clock_timestamp();
$$;
```

Scheduled daily. After expiry: original text and storage paths deleted; immutable `moderation_actions` row remains.

---

## Part 9 — Acceptance Test Matrix

### 9.1 Comment trigger (8 tests)

| # | Action | Expected |
|---|---|---|
| T1.1 | Authenticated author changes `text` | `FK_COMMENT_IMMUTABLE` |
| T1.2 | Non-author any UPDATE | `FK_COMMENT_IMMUTABLE` |
| T1.3 | Author sets `deleted_at` (text unchanged) | Succeeds; `deleted_at` = server time |
| T1.4 | Author sets past `deleted_at` | `deleted_at` overridden to server time |
| T1.5 | `remove_content('comment')` — all Path 1 conditions met | Succeeds; `moderator_removed_at` = server time |
| T1.6 | Authenticated user sets `moderator_removed_at` directly | `FK_COMMENT_IMMUTABLE` (current_user ≠ forkensics_executor) |
| T1.7 | Executor: wrong placeholder text | `FK_COMMENT_IMMUTABLE` |
| T1.8 | Executor: `moderator_removed_at` already set | `FK_COMMENT_IMMUTABLE` |

### 9.2 `can_view_challenge` baseline (6 tests)

| # | Setup | Expected |
|---|---|---|
| T2.1 | Poster's own draft (posted_at IS NULL) | `true` |
| T2.2 | Non-poster, draft (posted_at IS NULL) | `false` |
| T2.3 | Posted, group member, no block | `true` |
| T2.4 | Posted, group member, A blocks B (poster) | `false` |
| T2.5 | Posted, block exists, but B is eligible participant | `true` (carve-out) |
| T2.6 | Posted, non-member | `false` |

### 9.3 Child-table block enforcement (10 tests)

| # | Action | Expected |
|---|---|---|
| T3.1–T3.7 | A blocks B; B queries clues/secrets/aliases/guess_attempts/guess_judgments/eligible_participants/exclusion_events by challenge UUID | 0 rows each |
| T3.8 | B is eligible participant (carve-out) | Rows returned |
| T3.9 | No block | All return normally |
| T3.10 | Another poster's draft | 0 rows (posted_at IS NULL) |

### 9.4 `media-serve` block enforcement (6 tests)

| # | Setup | Expected |
|---|---|---|
| T4.1 | Group member, no block | `get_media_serve_authorization` returns storage key → 200 |
| T4.2 | A blocks B (poster) | Returns empty set → 403 |
| T4.3 | Outsider (no group) | Returns empty set → 403 |
| T4.4 | Poster | Returns key → 200 |
| T4.5 | B was eligible participant before block | Returns key (carve-out) → 200 |
| T4.6 | Moderator-removed challenge | Returns empty set → 403 |

### 9.5 `report_content` — media_object target lock order (2 tests)

| # | Setup | Expected |
|---|---|---|
| T5.1 | `remove_media` locks challenge; concurrent `report_content('media_object')` | `report_content` blocks on challenge lock; after `remove_media` commits: `report_content` reads `challenges.media_object_id` mismatch OR sees status ≠ 'ready' → FK_NOT_FOUND |
| T5.2 | `report_content('media_object')` commits first; then `remove_media` runs | `remove_media` captures the new report in its lock set; report is bulk-actioned |

### 9.6 Bulk report resolution + audit relationship (7 tests)

| # | Setup | Expected |
|---|---|---|
| T6.1 | A and B both report same comment | Both actioned; 2 rows in moderation_action_reports |
| T6.2 | A and B both report same challenge | Both actioned; 2 rows |
| T6.3 | A reports challenge; B reports linked media_object | Both actioned; 2 rows |
| T6.4 | A and B via `remove_media` | Both actioned; 2 rows |
| T6.5 | Single pending report | 1 row in moderation_action_reports |
| T6.6 | Verify completeness | Every actioned report has exactly one moderation_action_reports row |
| T6.7 | Dismiss one report; second still pending; removal runs | Second report actioned; dismissed report unchanged; 1 new row |

### 9.7 Concurrency — two moderators, same target (5 tests)

| # | Setup | Expected |
|---|---|---|
| T7.1 | Mod1 has Report A; Mod2 has Report B; same challenge; both call remove_content | One wins full action; second takes idempotency path; no duplicate action/evidence; both reports actioned |
| T7.2 | Concurrent dismiss + remove_content for same report | Lock serializes; second reads status ≠ 'pending' post-lock; fails cleanly |
| T7.3 | report_content races remove_content on challenge | If remove wins: report_content sees moderator_removed_at IS NOT NULL → FK_NOT_FOUND. If report wins: removal bulk-actions it |
| T7.4 | Two identical report_content calls | Partial unique index: one succeeds; one gets existing report_id |
| T7.5 | `remove_media` where poster re-uploaded between provisional read and lock | FK_LINKAGE_CHANGED |

### 9.8 Idempotency — challenge already removed (4 tests)

| # | Setup | Expected |
|---|---|---|
| T8.1 | Challenge already removed | Second remove_content call | No new moderation_actions; new pending reports linked to existing action |
| T8.2 | After first removal; third reporter tries to file | report_content locks challenge, sees moderator_removed_at IS NOT NULL → FK_NOT_FOUND |
| T8.3 | `remove_media` on media status = 'removed' | FK_WRONG_STATE |
| T8.4 | `remove_media` on media status = 'rejected' | FK_WRONG_STATE |

### 9.9 `p_report_id` validation in remove functions (3 tests)

| # | Setup | Expected |
|---|---|---|
| T9.1 | p_report_id matches a pending report against the target | Succeeds; moderation_actions.report_id = p_report_id |
| T9.2 | p_report_id targets a different challenge | FK_REPORT_TARGET_MISMATCH |
| T9.3 | p_report_id = NULL | Proactive removal; succeeds with NULL moderation_actions.report_id |

### 9.10 `action_report` validation (4 tests)

| # | Setup | Expected |
|---|---|---|
| T10.1 | Valid prior action, same subject | Report actioned; moderation_action_reports row inserted |
| T10.2 | Prior action is 'report_dismissed' | FK_INVALID_PRIOR_ACTION |
| T10.3 | Prior action targets different challenge | FK_REPORT_TARGET_MISMATCH |
| T10.4 | No prior action; no violation | Use dismiss_report |

### 9.11 Suspension enforcement (selected tests)

| # | Setup | Expected |
|---|---|---|
| T11.1 | Suspended INSERT comment | RESTRICTIVE policy rejects |
| T11.2 | Suspended UPDATE challenge (draft) | `suspend_block_update` rejects |
| T11.3 | Suspended redeem_group_invite | FK_SUSPENDED from internal guard |
| T11.4 | Suspended cancel_challenge | Allowed |
| T11.5 | Suspended author soft-delete own comment | Allowed (trigger Path 2) |
| T11.6 | Suspended exclusion reason='removed' | Branched RESTRICTIVE rejects |
| T11.7 | Suspended exclusion reason='withdrew' | Allowed |
| T11.8 | transfer_group_ownership to suspended recipient | Function guard rejects |

### 9.12 SHA-256 integrity (4 tests)

| # | Setup | Expected |
|---|---|---|
| T12.1 | Worker supplies valid lowercase 64-char hex | Stored; constraint passes |
| T12.2 | Worker supplies NULL | FK_INVALID_HASH; no state change |
| T12.3 | Worker supplies uppercase | FK_INVALID_HASH |
| T12.4 | Pre-V2 row with NULL sha256_hash | FK_MEDIA_METADATA_INCOMPLETE on moderation attempt |

### 9.13 Cleanup hold — multiple reporters (5 tests)

| # | Setup | Expected |
|---|---|---|
| T13.1 | A and B have pending reports on same media | Cleanup not claimable |
| T13.2 | A's report dismissed | Still not claimable (B's pending) |
| T13.3 | B's report also dismissed | Now claimable |
| T13.4 | Challenge inappropriate_image report pending | Linked media not claimable |
| T13.5 | That report dismissed | Media now claimable |

---

## Part 10 — Success Criteria

- [ ] Comment trigger: SECURITY INVOKER; Path 1 gated by `current_user = 'forkensics_executor'`; server timestamps in both paths; tests T1.x pass
- [ ] `can_view_challenge()` enforces `posted_at IS NOT NULL` for non-posters; tests T2.x pass
- [ ] `private.can_viewer_access_challenge(viewer_id)` defined for service-role callers
- [ ] `public.get_media_serve_authorization` defined; EXECUTE to service_role only; combines authorization and key retrieval; tests T4.x pass
- [ ] `media_object` target in `report_content` follows challenge → media lock order; tests T5.x pass
- [ ] All removal functions: correct content target → reports (UUID order) → media lock sequence
- [ ] `p_report_id` validated in lock set when supplied; FK_REPORT_TARGET_MISMATCH if absent; tests T9.x pass
- [ ] `moderation_action_reports` table with UNIQUE(report_id) constraint; every bulk-resolved report gets exactly one row; test T6.6 passes
- [ ] `action_report` requires same-subject substantive prior action; tests T10.x pass
- [ ] Idempotency path: no duplicate action/evidence; new pending reports linked to existing action; tests T8.x pass
- [ ] Deadlock-free: tests T7.1–T7.5 pass
- [ ] `report_content` locks removable targets before insert; tests T5.x and T7.3 pass
- [ ] `redeem_group_invite` internal suspension guard; test T11.3 passes
- [ ] `transfer_group_ownership`: recipient active, onboarded, unsuspended; audited in `group_ownership_history`; test T11.8 passes
- [ ] SHA-256: `text` parameter with internal format validation; two-migration plan; tests T12.x pass
- [ ] Text filtering triggers attached to all UGC fields including story, alias display_value
- [ ] RESTRICTIVE suspension policies with unique names per table per operation
- [ ] `exclusion_events` branched RESTRICTIVE policy; tests T11.6–T11.7 pass
- [ ] RESTRICTIVE block policies on all child tables; tests T3.x pass
- [ ] Cleanup hold uses live subquery covering both media_object and challenge+inappropriate_image reports; tests T13.x pass
- [ ] `private.cleanup_expired_evidence()` defined; scheduled daily
- [ ] No executable SQL written until governance approval
