# Step 24.1 — UGC Safety and Moderation Contracts
## Final Proposal (Rev 8)

**Status:** Pending approval (Claude → Codex/GPT → Bill)
**Governance gate:** Bill must type `APPROVED: Step 24.1 — UGC Safety and Moderation Contracts` before any SQL in this document is written as executable code or applied to any environment.
**Self-contained:** This document is the complete approved contract. No prior revision (Rev 1–7) need be consulted for implementation.

**Changes from Rev 7:**
1. `ON CONFLICT` in `report_content` changed from constraint name to partial-index inference.
2. All new public tables explicitly enable RLS; default privileges revoked; intended access re-granted.
3. Idempotency redesigned: `moderator_removal_action_id` column on `challenges`, `comments`, `clues` — set atomically during first removal; universal Section 7.11 reads it regardless of how removal occurred.
4. RESTRICTIVE SELECT policy on `public.clues` hides rows where `moderator_removed_at IS NOT NULL`.
5. `report_content` comment-target visibility includes challenge poster.
6. `get_poster_media_status` requires `media_objects.uploaded_by = p_uploader_id`; `p_uploader_id` derived from Edge Function JWT. `private.cleanup_expired_evidence` ownership and grant tightened.

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
- `finalize_upload_session`: sets `status = 'pending_review'`, `re_encoded_at = now()`, stores `sha256_hash`; replaces `challenge.media_object_id` atomically when poster re-uploads
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
7. `get_my_reports()` SECURITY DEFINER RPC; direct table SELECT revoked from authenticated.
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
19. Idempotency: `moderator_removal_action_id` column on challenges, comments, and clues; set atomically during first removal; universal idempotency path reuses it.
20. `redeem_group_invite` requires internal suspension guard.
21. `remove_content` and `remove_media` may be called with `p_report_id = NULL` (proactive moderation); fully audited.
22. `moderation_action_reports.report_id` unique — each resolved report has exactly one resolution link.
23. `media-serve` authorization uses `public.get_media_serve_authorization(media_object_id, viewer_id)` — public SECURITY DEFINER wrapper; `p_viewer_id` derived from Edge Function's verified JWT, never from request body.
24. Ownership transfer audit in dedicated `public.group_ownership_history` table.
25. Appeals: V1 — already-removed content returns `FK_NOT_FOUND`; users use published support address.
26. All new public tables have RLS explicitly enabled and default privileges revoked.
27. Moderator-removed clues hidden via RESTRICTIVE SELECT policy (`moderator_removed_at IS NULL`); clue text not replaced (stays in evidence only).
28. `get_poster_media_status` derives `p_uploader_id` from Edge Function JWT; query requires `media_objects.uploaded_by = p_uploader_id`.

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

-- One unresolved report per reporter+target+category.
-- This is a PARTIAL UNIQUE INDEX (not a named constraint).
-- ON CONFLICT must use column-list inference with WHERE status = 'pending'.
CREATE UNIQUE INDEX content_reports_unresolved_dedup
  ON public.content_reports (reporter_id, target_type, target_id, category)
  WHERE status = 'pending';

CREATE INDEX ON public.content_reports (status, created_at);
CREATE INDEX ON public.content_reports (reporter_id);
CREATE INDEX ON public.content_reports (target_type, target_id) WHERE status = 'pending';
```

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

-- Immutability: BEFORE UPDATE OR DELETE → RAISE EXCEPTION 'FK_ACTION_IMMUTABLE'
CREATE INDEX ON public.moderation_actions (target_type, target_id);
CREATE INDEX ON public.moderation_actions (moderator_id, created_at);
```

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
-- Immutability: BEFORE UPDATE OR DELETE → RAISE EXCEPTION 'FK_ACTION_IMMUTABLE'
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

A row is upserted for each profile at account creation. `suspend_user` and `reinstate_user` update both this table and `public.profiles.is_suspended` atomically.

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
-- Moderator removal timestamps
ALTER TABLE public.challenges
  ADD COLUMN IF NOT EXISTS moderator_removed_at timestamptz;

ALTER TABLE public.comments
  ADD COLUMN IF NOT EXISTS moderator_removed_at timestamptz;

ALTER TABLE public.clues
  ADD COLUMN IF NOT EXISTS moderator_removed_at timestamptz;

-- Durable idempotency references: set atomically during first removal; never updated.
-- Enables universal idempotency path regardless of action_type or removal pathway.
ALTER TABLE public.challenges
  ADD COLUMN IF NOT EXISTS moderator_removal_action_id uuid
    REFERENCES public.moderation_actions(id) ON DELETE RESTRICT;

ALTER TABLE public.comments
  ADD COLUMN IF NOT EXISTS moderator_removal_action_id uuid
    REFERENCES public.moderation_actions(id) ON DELETE RESTRICT;

ALTER TABLE public.clues
  ADD COLUMN IF NOT EXISTS moderator_removal_action_id uuid
    REFERENCES public.moderation_actions(id) ON DELETE RESTRICT;

-- Cleanup lease and moderated timestamp on media
ALTER TABLE public.media_objects
  ADD COLUMN IF NOT EXISTS moderated_at                     timestamptz,
  ADD COLUMN IF NOT EXISTS moderation_cleanup_leased_until  timestamptz;

-- media_objects status constraint includes full V2 set
-- New values: pending_review, rejected, removed
-- (replace V1 CHECK constraint by name in migration)
```

### 3.11 `private.media_storage_keys` — SHA-256 column

Two-migration deployment plan:

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

No placeholder or synthetic hashes.

### 3.12 `public.group_ownership_history`

```sql
CREATE TABLE IF NOT EXISTS public.group_ownership_history (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  group_id        uuid        NOT NULL REFERENCES public.groups(id) ON DELETE RESTRICT,
  previous_owner  uuid        NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  new_owner       uuid        NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  transferred_at  timestamptz NOT NULL DEFAULT clock_timestamp()
  -- Immutability: BEFORE UPDATE OR DELETE → RAISE EXCEPTION 'FK_ACTION_IMMUTABLE'
);

CREATE INDEX ON public.group_ownership_history (group_id);
```

---

## Part 4 — RLS Enablement and Privilege Grants

RLS must be explicitly enabled on every new public table. Supabase default privileges are revoked and only intended access is re-granted.

```sql
-- Enable RLS on all new public tables
ALTER TABLE public.content_reports         ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_blocks             ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.moderation_actions      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.group_ownership_history ENABLE ROW LEVEL SECURITY;

-- Revoke all default privileges
REVOKE ALL ON public.content_reports         FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.user_blocks             FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.moderation_actions      FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.group_ownership_history FROM PUBLIC, anon, authenticated;

-- Re-grant only the intended direct access:
-- user_blocks: authenticated SELECT only (controlled by own-row RESTRICTIVE policy below)
GRANT SELECT ON public.user_blocks TO authenticated;

-- content_reports, moderation_actions, group_ownership_history:
-- No direct SELECT/INSERT/UPDATE/DELETE for authenticated.
-- All access via SECURITY DEFINER functions (get_my_reports, etc.).
```

**`private` tables** (`blocked_terms`, `moderators`, `profile_suspensions`, `moderation_evidence`, `moderation_action_reports`, `media_storage_keys`): never exposed via PostgREST; no policy changes needed. Service role and SECURITY DEFINER functions access them directly.

---

## Part 5 — RLS Helper Functions

All helpers: owned by `forkensics_rls_helper`, `SECURITY DEFINER`, `SET search_path = ''`, `STABLE`.

### 5.1 `private.can_view_challenge(p_challenge_id uuid) → boolean`

For RLS policies (where `auth_uid()` is the viewer).

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

### 5.2 `private.can_viewer_access_challenge(p_challenge_id uuid, p_viewer_id uuid) → boolean`

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

### 5.3 `private.has_block_with(p_profile_id uuid) → boolean`

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

### 5.4 `private.has_block_with_poster(p_challenge_id uuid) → boolean`

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

## Part 6 — Text Filtering

### 6.1 Trigger function

`SECURITY DEFINER` to access `private.blocked_terms`. No bypass of any kind. Moderator placeholder `[removed by moderator]` is not a blocked term and passes naturally.

```sql
CREATE OR REPLACE FUNCTION private.check_text_content_trigger()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_text text;
BEGIN
  v_text := CASE
    WHEN TG_TABLE_NAME = 'comments'                                                THEN NEW.text
    WHEN TG_TABLE_NAME = 'clues'                                                   THEN NEW.text
    WHEN TG_TABLE_NAME = 'profiles'                                                THEN NEW.display_name
    WHEN TG_TABLE_NAME = 'groups'                                                  THEN NEW.name
    WHEN TG_TABLE_NAME = 'challenges'                                              THEN NEW.public_city_display
    WHEN TG_TABLE_NAME = 'challenge_secrets' AND TG_ARGV[0] = 'display_dish'       THEN NEW.display_dish
    WHEN TG_TABLE_NAME = 'challenge_secrets' AND TG_ARGV[0] = 'display_restaurant' THEN NEW.display_restaurant
    WHEN TG_TABLE_NAME = 'challenge_secrets' AND TG_ARGV[0] = 'story'              THEN NEW.story
    WHEN TG_TABLE_NAME = 'challenge_answer_aliases'                                THEN NEW.display_value
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

### 6.2 Trigger attachments

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

## Part 7 — RLS Policy Additions

All new policies are `AS RESTRICTIVE` — they AND with existing V1 permissive policies.

### 7.1 Suspension enforcement

Check: `NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = private.auth_uid() AND is_suspended = true)`.

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

### 7.2 `exclusion_events` — branched suspension policy

```sql
CREATE POLICY suspend_exclusion_insert AS RESTRICTIVE ON public.exclusion_events
  FOR INSERT TO authenticated
  WITH CHECK (
    NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = private.auth_uid() AND is_suspended = true)
    OR (reason = 'withdrew' AND player_id = private.auth_uid())
  );
```

### 7.3 Block enforcement — INSERT

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

### 7.4 Block enforcement — SELECT

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

-- Reactions
CREATE POLICY block_aware_visibility AS RESTRICTIVE ON public.reactions
  FOR SELECT TO authenticated
  USING (
    private.can_view_challenge(challenge_id)
    AND NOT private.has_block_with(player_id)
  );
```

### 7.5 Moderator-removed clues — hidden from authenticated

Clue text is preserved (not replaced). Clue rows are hidden after removal via this RESTRICTIVE policy.

```sql
CREATE POLICY hide_removed_clues AS RESTRICTIVE ON public.clues
  FOR SELECT TO authenticated
  USING (moderator_removed_at IS NULL);
```

Service role (`BYPASSRLS`) reads removed clues for evidence capture before invoking `remove_content('clue')`. Moderators access removed clue text exclusively via the evidence snapshot in `private.moderation_evidence`.

### 7.6 Block-aware visibility on child tables

Applied to: `clues`, `challenge_secrets`, `challenge_answer_aliases`, `guess_attempts`, `guess_judgments`, `score_runs`, `score_events`, `correction_events`, `eligible_participants`, `exclusion_events`.

```sql
-- Template (replace <table> and <challenge_fk>):
CREATE POLICY block_aware_visibility AS RESTRICTIVE ON public.<table>
  FOR SELECT TO authenticated
  USING (private.can_view_challenge(<challenge_fk>));
```

### 7.7 `user_blocks` SELECT policy

```sql
CREATE POLICY blocks_select_own ON public.user_blocks
  FOR SELECT TO authenticated
  USING (blocker_id = private.auth_uid());
```

No INSERT, UPDATE, or DELETE policies. Use `block_user` / `unblock_user`.

---

## Part 8 — SECURITY DEFINER Functions

All: owned by `forkensics_executor`, `SET search_path = ''`. EXECUTE grants as specified.

### 8.1 Moderator identity validation (internal, in all moderation functions)

```sql
IF NOT EXISTS (
  SELECT 1 FROM private.moderators m
  JOIN public.profiles p ON p.id = m.profile_id
  WHERE m.profile_id = p_moderator_id AND p.is_active = true
) THEN
  RAISE EXCEPTION 'FK_UNAUTHORIZED: moderator identity not valid';
END IF;
```

### 8.2 Global lock order

**content target → all matching pending reports (ascending `id` UUID) → media**

Every function acquires locks in this order, without exception.

### 8.3 `public.check_text_content(p_text text) → boolean`

Early validation for Edge Functions. Returns `true` if no blocked term found. The trigger is the authoritative enforcement. EXECUTE granted to `service_role`.

### 8.4 `public.report_content`

EXECUTE granted to `authenticated`.

```
public.report_content(
  p_target_type text,
  p_target_id   uuid,
  p_category    text,
  p_detail      text  -- nullable
) → TABLE(report_id uuid)
```

1. Verify caller is active, onboarded. Suspended callers are permitted to report.
2. Validate `target_type` and `category` against allowed values.
3. Rate limit: fewer than 10 pending reports in the past hour.
4. **Lock and recheck target** (prevents stranded reports racing content removal):

   *`'challenge'`:* Lock challenge `FOR UPDATE`. Verify `private.can_view_challenge(p_target_id) = true`. Verify `moderator_removed_at IS NULL`.

   *`'comment'`:* Lock comment `FOR UPDATE`. Verify `moderator_removed_at IS NULL`. Verify Table Talk visibility — caller must satisfy at least one of:
   - `c.poster_id = private.auth_uid()` (poster can report comments on their own challenge)
   - challenge `revealed = true`
   - caller has at least one `guess_attempts` row for this challenge
   - caller is `comments.author_id`

   *`'clue'`:* Lock clue `FOR UPDATE`. Verify `moderator_removed_at IS NULL`. Verify `can_view_challenge(challenge_id)`.

   *`'media_object'`:* Full lock sequence matching `remove_media`'s lock order:
   a. Provisional read: `challenge_id` from `challenges WHERE media_object_id = p_target_id`.
   b. Lock challenge `FOR UPDATE`.
   c. Re-verify `challenges.media_object_id = p_target_id`. If mismatch → `FK_NOT_FOUND`.
   d. Re-check `private.can_view_challenge(challenge_id)`.
   e. Lock media_object `FOR UPDATE`.
   f. Verify `status = 'ready'`. Otherwise → `FK_NOT_FOUND`.
   g. Insert report (after both locks held).

   *`'profile'`:* Verify target is active. Verify caller shares at least one group with target. No row lock needed.

   In all cases: same `FK_NOT_FOUND` for nonexistent, unauthorized, and already-actioned targets. Self-report rejected.

5. Insert with partial-index dedup:

   ```sql
   INSERT INTO public.content_reports (reporter_id, target_type, target_id, category, detail)
   VALUES (private.auth_uid(), p_target_type, p_target_id, p_category, p_detail)
   ON CONFLICT (reporter_id, target_type, target_id, category)
   WHERE status = 'pending'
   DO NOTHING
   RETURNING id INTO v_report_id;
   ```

   If `v_report_id IS NULL` (conflict, dedup): read existing report id:
   ```sql
   SELECT id INTO v_report_id FROM public.content_reports
   WHERE reporter_id = private.auth_uid()
     AND target_type = p_target_type
     AND target_id = p_target_id
     AND category = p_category
     AND status = 'pending';
   ```

6. Return `report_id`.

### 8.5 `public.block_user(p_blocked_id uuid) → void`

EXECUTE granted to `authenticated`. Suspended callers permitted. Idempotent INSERT into `user_blocks`.

### 8.6 `public.unblock_user(p_blocked_id uuid) → void`

EXECUTE granted to `authenticated`. Idempotent DELETE where `blocker_id = auth_uid()`.

### 8.7 `public.approve_photo`

EXECUTE granted to `service_role`.

```
public.approve_photo(p_media_object_id uuid, p_moderator_id uuid, p_reason text) → void
```

1. Validate moderator.
2. Lock media `FOR UPDATE`. Verify `status = 'pending_review'`.
3. INSERT moderation_actions `(action_type = 'photo_approved')` RETURNING id.
4. UPDATE media_objects: `status = 'ready'`, `moderated_at = clock_timestamp()`.

### 8.8 `public.reject_photo`

EXECUTE granted to `service_role`.

```
public.reject_photo(p_media_object_id uuid, p_moderator_id uuid, p_reason text) → void
```

1. Validate moderator.
2. Lock media `FOR UPDATE`. Verify `status = 'pending_review'`.
3. Read `sha256_hash`. Raise `FK_MEDIA_METADATA_INCOMPLETE` if NULL.
4. INSERT moderation_actions RETURNING id → `v_action_id`.
5. INSERT moderation_evidence `(evidence_type = 'media_metadata', evidence_storage_key, evidence_sha256 = sha256_hash)`.
6. UPDATE media_objects: `status = 'rejected'`, `moderated_at = clock_timestamp()`.

### 8.9 `public.remove_content`

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

**For `'challenge'`** — lock sequence:

```
1.  Validate moderator.
2.  Lock challenge:
      SELECT id, state, media_object_id, moderator_removed_at, moderator_removal_action_id
      FROM challenges WHERE id = p_target_id FOR UPDATE.
3.  If moderator_removed_at IS NOT NULL → idempotency path (Section 8.11).
4.  Validate state per state matrix (Section 8.9a).
5.  Resolve v_media_object_id := challenges.media_object_id.
6.  Lock all matching pending reports (challenge + linked media_object) in UUID order:
      SELECT id FROM content_reports
      WHERE status = 'pending'
        AND (
          (target_type = 'challenge' AND target_id = p_target_id)
          OR (target_type = 'media_object' AND target_id = v_media_object_id)
        )
      ORDER BY id FOR UPDATE → v_report_ids[].
7.  If p_report_id IS NOT NULL: verify p_report_id ∈ v_report_ids. Raise FK_REPORT_TARGET_MISMATCH if absent.
8.  Lock media:
      SELECT id, status FROM media_objects WHERE id = v_media_object_id FOR UPDATE.
    Validate per media state matrix.
9.  Read sha256_hash from private.media_storage_keys. Raise FK_MEDIA_METADATA_INCOMPLETE if NULL.
10. INSERT moderation_actions (action_type = 'content_removed', target_type = 'challenge',
      target_id = p_target_id, report_id = p_report_id, reason, moderator_id) RETURNING id → v_action_id.
11. INSERT moderation_evidence (media_metadata).
12. UPDATE challenges: moderator_removed_at = clock_timestamp(), state per matrix,
      moderator_removal_action_id = v_action_id.      ← set atomically
13. UPDATE media_objects per media state matrix.
14. INSERT moderation_action_reports: one row per id in v_report_ids[].
15. UPDATE content_reports SET status = 'actioned', reviewed_at, reviewed_by WHERE id = ANY(v_report_ids).
```

**For `'comment'`**:

```
1.  Validate moderator.
2.  Lock comment:
      SELECT id, text, moderator_removed_at, moderator_removal_action_id
      FROM comments WHERE id = p_target_id FOR UPDATE.
    If moderator_removed_at IS NOT NULL → idempotency path (Section 8.11).
3.  Lock all matching pending reports ORDER BY id FOR UPDATE → v_report_ids[].
4.  If p_report_id IS NOT NULL: verify ∈ v_report_ids.
5.  INSERT moderation_actions (action_type = 'content_removed', target_type = 'comment') RETURNING id → v_action_id.
6.  INSERT moderation_evidence (evidence_type = 'comment_text', evidence_text = original text).
7.  UPDATE comments: text = '[removed by moderator]', moderator_removed_at = clock_timestamp(),
      moderator_removal_action_id = v_action_id.      ← set atomically
8.  INSERT moderation_action_reports per v_report_ids[].
9.  UPDATE content_reports SET status = 'actioned' WHERE id = ANY(v_report_ids).
```

**For `'clue'`**:

```
1.  Validate moderator.
2.  Lock clue:
      SELECT id, text, moderator_removed_at, moderator_removal_action_id
      FROM clues WHERE id = p_target_id FOR UPDATE.
    If moderator_removed_at IS NOT NULL → idempotency path (Section 8.11).
3.  Lock all matching pending reports ORDER BY id FOR UPDATE → v_report_ids[].
4.  If p_report_id IS NOT NULL: verify ∈ v_report_ids.
5.  INSERT moderation_actions (action_type = 'content_removed', target_type = 'clue') RETURNING id → v_action_id.
6.  INSERT moderation_evidence (evidence_type = 'clue_text', evidence_text = clue.text).
7.  UPDATE clues: moderator_removed_at = clock_timestamp(),
      moderator_removal_action_id = v_action_id.      ← set atomically; clue text not changed
8.  INSERT moderation_action_reports per v_report_ids[].
9.  UPDATE content_reports SET status = 'actioned' WHERE id = ANY(v_report_ids).
```

### 8.9a State matrix

**Challenge state → outcome:**

| Challenge state | Outcome |
|---|---|
| `draft` | state → `cancelled`, `cancellation_reason = 'moderation_action'`, `moderator_removed_at = clock_timestamp()` |
| `active` | Same |
| `locked` | Same |
| `revealed` | state unchanged; `moderator_removed_at = clock_timestamp()`. Scores preserved. |
| `cancelled` (any) | `moderator_removed_at = clock_timestamp()` if not set; state unchanged. |

**Media status → action:**

| Media status | Action during challenge removal |
|---|---|
| `ready`, `pending_review`, `rejected`, `superseded` | `status = 'removed'`, `moderated_at = clock_timestamp()` |
| `removed`, `cleaned` | Skip media UPDATE |
| `processing`, `failed` | Raise `FK_WRONG_STATE`; abort |

### 8.10 `public.remove_media`

EXECUTE granted to `service_role`. `p_report_id` is nullable.

```
public.remove_media(p_media_object_id uuid, p_moderator_id uuid,
                    p_report_id uuid, p_reason text) → void
```

```
1.  Validate moderator.
2.  Provisional read: v_challenge_id from challenges WHERE media_object_id = p_media_object_id.
3.  Lock challenge:
      SELECT id, state, media_object_id, moderator_removed_at, moderator_removal_action_id
      FROM challenges WHERE id = v_challenge_id FOR UPDATE.
4.  If moderator_removed_at IS NOT NULL → idempotency path (Section 8.11).
5.  Re-validate challenges.media_object_id = p_media_object_id. Raise FK_LINKAGE_CHANGED if not.
6.  Lock all matching pending reports in UUID order:
      SELECT id FROM content_reports
      WHERE status = 'pending'
        AND (
          (target_type = 'media_object' AND target_id = p_media_object_id)
          OR (target_type = 'challenge' AND category = 'inappropriate_image'
              AND target_id = v_challenge_id)
        )
      ORDER BY id FOR UPDATE → v_report_ids[].
7.  If p_report_id IS NOT NULL: verify ∈ v_report_ids. Raise FK_REPORT_TARGET_MISMATCH if absent.
8.  Lock media:
      SELECT id, status FROM media_objects WHERE id = p_media_object_id FOR UPDATE.
    Verify status = 'ready'. Otherwise raise FK_WRONG_STATE.
9.  Read sha256_hash. Raise FK_MEDIA_METADATA_INCOMPLETE if NULL.
10. INSERT moderation_actions (action_type = 'photo_removed', target_type = 'media_object',
      target_id = p_media_object_id, report_id = p_report_id) RETURNING id → v_action_id.
11. INSERT moderation_evidence.
12. UPDATE media_objects: status = 'removed', moderated_at = clock_timestamp().
13. UPDATE challenges per state matrix; also set moderator_removal_action_id = v_action_id.  ← set atomically
14. INSERT moderation_action_reports per v_report_ids[].
15. UPDATE content_reports SET status = 'actioned' WHERE id = ANY(v_report_ids).
```

### 8.11 Universal idempotency path

Entered when `moderator_removed_at IS NOT NULL` is detected after locking the target (challenge, comment, or clue). `moderator_removal_action_id` is the durable pointer set atomically during the first removal — it is correct regardless of which function or pathway performed the original removal.

```
1. v_existing_action_id := target_row.moderator_removal_action_id.
   If NULL: RAISE EXCEPTION 'FK_STATE_INCONSISTENCY: target removed but no action recorded'.

2. Lock all new matching pending reports (same query, ORDER BY id FOR UPDATE) → v_new_report_ids[].
   (For challenges: include linked media_object reports in the query.)

3. INSERT INTO private.moderation_action_reports (moderation_action_id, report_id)
   SELECT v_existing_action_id, id FROM unnest(v_new_report_ids) AS id
   ON CONFLICT ON CONSTRAINT moderation_action_reports_one_resolution DO NOTHING.

4. Verify no newly-discovered report is linked to a different action:
   IF EXISTS (
     SELECT 1 FROM private.moderation_action_reports mar
     WHERE mar.report_id = ANY(v_new_report_ids)
       AND mar.moderation_action_id != v_existing_action_id
   ) THEN RAISE EXCEPTION 'FK_RESOLUTION_CONFLICT'; END IF.

5. UPDATE content_reports SET status = 'actioned', reviewed_at = clock_timestamp(),
   reviewed_by = p_moderator_id WHERE id = ANY(v_new_report_ids).

6. Return. (No new moderation_actions or moderation_evidence rows.)
```

### 8.12 `public.suspend_user`

EXECUTE granted to `service_role`.

1. Validate moderator. Verify profile active. Idempotent if already suspended.
2. Atomically: `UPDATE public.profiles SET is_suspended = true`; upsert `private.profile_suspensions`.
3. INSERT moderation_actions `(action_type = 'user_suspended')`.

### 8.13 `public.reinstate_user`

EXECUTE granted to `service_role`.

1. Validate moderator. Verify `is_suspended = true`.
2. Atomically: `UPDATE public.profiles SET is_suspended = false`; update `private.profile_suspensions`.
3. INSERT moderation_actions `(action_type = 'user_reinstated')`.

### 8.14 `public.dismiss_report`

EXECUTE granted to `service_role`. Acquires only the report lock.

```
1. Validate moderator.
2. SELECT id, status FROM content_reports WHERE id = p_report_id FOR UPDATE.
   Verify status = 'pending'.
3. INSERT moderation_actions (action_type = 'report_dismissed', report_id = p_report_id)
   RETURNING id → v_action_id.
4. INSERT moderation_action_reports (moderation_action_id = v_action_id, report_id = p_report_id).
5. UPDATE content_reports SET status = 'dismissed', reviewed_at, reviewed_by = p_moderator_id.
```

### 8.15 `public.action_report`

EXECUTE granted to `service_role`. Closes a report after the corresponding moderation action was recorded separately.

```
public.action_report(
  p_report_id       uuid,
  p_moderator_id    uuid,
  p_prior_action_id uuid,  -- required; must be a substantive prior action
  p_reason          text
) → void
```

1. Validate moderator.
2. Read prior action. Verify `action_type NOT IN ('report_dismissed','report_actioned','photo_approved')`. Raise `FK_INVALID_PRIOR_ACTION` if non-qualifying.
3. Lock report `FOR UPDATE`. Verify `status = 'pending'`. Verify `target_type` and `target_id` match prior action. Raise `FK_REPORT_TARGET_MISMATCH` if mismatch.
4. INSERT moderation_actions `(action_type = 'report_actioned', prior_action_id = p_prior_action_id)` RETURNING id → `v_action_id`.
5. INSERT moderation_action_reports.
6. UPDATE content_reports SET `status = 'actioned'`.

### 8.16 `public.get_media_serve_authorization`

EXECUTE granted to `service_role` only. EXECUTE explicitly revoked from PUBLIC, `anon`, and `authenticated`.

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

Returns empty set if any condition fails. The Edge Function treats empty = 403.

**Edge Function `media-serve` flow:**
1. Extract `user_id` from verified JWT via `supabaseClient.auth.getUser()`. Never from request body.
2. Call `get_media_serve_authorization(p_media_object_id, user_id)` via service-role connection.
3. Empty row → 403 `FK_FORBIDDEN`.
4. Use returned `re_encoded_storage_key` to generate a signed URL via service role.

### 8.17 `public.get_moderation_queue`

EXECUTE granted to `service_role`. Returns pending reports and pending-review photos, oldest first.

```
→ TABLE(queue_type text, item_id uuid, created_at timestamptz,
        target_type text, target_id uuid, category text, challenge_id uuid)
```

Two result types: `'pending_report'` and `'pending_review_photo'`.

### 8.18 `public.get_pending_review_media`

EXECUTE granted to `service_role`.

```
public.get_pending_review_media(p_media_object_id uuid)
→ TABLE(media_object_id uuid, re_encoded_storage_key text,
        challenge_id uuid, uploader_id uuid, re_encoded_at timestamptz)
```

Returns row if `status = 'pending_review'`. No row otherwise.

### 8.19 `public.get_reported_media`

EXECUTE granted to `service_role`.

```
public.get_reported_media(p_report_id uuid)
→ TABLE(media_object_id uuid, re_encoded_storage_key text,
        challenge_id uuid, uploader_id uuid, media_status text,
        report_category text, report_detail text)
```

Returns row if report status = 'pending' and linked media is `ready` or `pending_review`.

### 8.20 `public.get_poster_media_status`

EXECUTE granted to `service_role`. `p_uploader_id` is derived from Edge Function JWT — never from request body.

```
public.get_poster_media_status(p_media_object_id uuid, p_uploader_id uuid)
→ TABLE(status text, rejection_message text)
```

Query requires `media_objects.uploaded_by = p_uploader_id`. A different uploader receives no row (same as non-existent media — indistinguishable).

```sql
CREATE OR REPLACE FUNCTION public.get_poster_media_status(
  p_media_object_id uuid,
  p_uploader_id     uuid
) RETURNS TABLE(status text, rejection_message text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT
    mo.status,
    CASE WHEN mo.status = 'rejected'
         THEN 'Photo couldn''t be approved — choose another photo.'
         ELSE NULL
    END AS rejection_message
  FROM public.media_objects mo
  WHERE mo.id = p_media_object_id
    AND mo.uploaded_by = p_uploader_id;
$$;
```

No moderator notes or `reviewed_by` returned.

### 8.21 `public.get_my_reports`

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

### 8.22 `public.get_report_for_review`

EXECUTE granted to `service_role`.

```
→ TABLE(report_id uuid, reporter_id uuid, target_type text, target_id uuid,
        category text, detail text, status text, created_at timestamptz,
        target_summary text)
```

`target_summary`: comment text or clue text for those types; NULL for challenge/media/profile.

### 8.23 Suspension-gated SECURITY DEFINER functions

Internal guard at entry: `IF is_suspended THEN RAISE EXCEPTION 'FK_SUSPENDED'; END IF;`

| Function | Note |
|---|---|
| `activate_challenge` | |
| `create_group` | |
| `create_group_invite` | |
| `redeem_group_invite` | |
| `apply_correction` | |

`transfer_group_ownership`: suspended poster permitted; recipient must be active, onboarded, `is_suspended = false`. INSERT into `group_ownership_history`.

### 8.24 SHA-256 parameter validation in `finalize_upload_session`

```sql
IF p_sha256_hash IS NULL OR p_sha256_hash !~ '^[0-9a-f]{64}$' THEN
  RAISE EXCEPTION 'FK_INVALID_HASH: sha256_hash must be 64 lowercase hex characters';
END IF;
```

Declared as `p_sha256_hash text`. Stores hash in `private.media_storage_keys.sha256_hash` atomically with `re_encoded_storage_key`.

### 8.25 `finalize_upload_session` — replacement media pointer

When poster re-uploads after rejection:
1. Lock draft challenge `FOR UPDATE`.
2. Create new media_object with `status = 'pending_review'`, `re_encoded_at = clock_timestamp()`.
3. `UPDATE challenges SET media_object_id = new_id WHERE id = challenge_id AND state = 'draft'`.
4. `activate_challenge` reads current pointer and verifies `status = 'ready'`.

---

## Part 9 — Cleanup Contracts

### 9.1 `public.claim_moderation_media_cleanup`

EXECUTE granted to `service_role`.

```sql
public.claim_moderation_media_cleanup(p_batch_size int DEFAULT 10)
→ TABLE(media_object_id uuid, storage_key text, status text)
```

Claims `rejected` or `removed` media objects with no live pending report (covering both `target_type = 'media_object'` and challenge-level `inappropriate_image` reports):

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

### 9.2 `public.mark_moderation_media_cleaned`

EXECUTE granted to `service_role`.

```sql
UPDATE public.media_objects
SET status = 'cleaned', moderation_cleanup_leased_until = NULL
WHERE id = p_media_object_id AND status IN ('rejected','removed');

IF NOT FOUND THEN RAISE EXCEPTION 'FK_WRONG_STATE'; END IF;
```

### 9.3 Cleanup worker procedure

```
1. Call claim_moderation_media_cleanup(10).
2. For each claimed row:
   a. Delete storage object at storage_key.
   b. 200/204: call mark_moderation_media_cleaned.
   c. 404 (already gone): call mark_moderation_media_cleaned (success).
   d. Other error: log; do not mark cleaned; lease expires and row becomes re-claimable.
```

### 9.4 `private.cleanup_expired_evidence`

Owned by `forkensics_executor`. EXECUTE revoked from PUBLIC, `anon`, and `authenticated`. EXECUTE granted to `service_role` only (for the scheduled worker).

```sql
CREATE OR REPLACE FUNCTION private.cleanup_expired_evidence()
RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$
  DELETE FROM private.moderation_evidence WHERE retained_until < clock_timestamp();
$$;

REVOKE EXECUTE ON FUNCTION private.cleanup_expired_evidence() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.cleanup_expired_evidence() TO service_role;
```

Scheduled daily. After expiry: `evidence_text` and `evidence_storage_key` rows deleted; immutable `moderation_actions` row remains.

---

## Part 10 — Acceptance Test Matrix

### T1 — Comment trigger (8 tests)

| # | Action | Expected |
|---|---|---|
| T1.1 | Author changes `text` | `FK_COMMENT_IMMUTABLE` |
| T1.2 | Non-author any UPDATE | `FK_COMMENT_IMMUTABLE` |
| T1.3 | Author sets `deleted_at` (text unchanged) | Succeeds; `deleted_at` = server time |
| T1.4 | Author supplies past `deleted_at` | Overridden to server time |
| T1.5 | `remove_content('comment')` — all Path 1 conditions met | Succeeds; `moderator_removed_at` = server time |
| T1.6 | Authenticated user sets `moderator_removed_at` directly | `FK_COMMENT_IMMUTABLE` |
| T1.7 | Executor: wrong placeholder text | `FK_COMMENT_IMMUTABLE` |
| T1.8 | Executor: `moderator_removed_at` already set | `FK_COMMENT_IMMUTABLE` |

### T2 — `can_view_challenge` baseline (6 tests)

| # | Setup | Expected |
|---|---|---|
| T2.1 | Poster's own draft | `true` |
| T2.2 | Non-poster, draft (`posted_at IS NULL`) | `false` |
| T2.3 | Posted, group member, no block | `true` |
| T2.4 | Posted, group member, A blocks B (poster) | `false` |
| T2.5 | Block exists; B is eligible participant | `true` (carve-out) |
| T2.6 | Posted, non-member | `false` |

### T3 — Child-table block enforcement (10 tests)

| # | Action | Expected |
|---|---|---|
| T3.1–T3.7 | A blocks B; B queries clues/secrets/aliases/guess_attempts/guess_judgments/eligible_participants/exclusion_events for A's challenge | 0 rows each |
| T3.8 | B is eligible participant (carve-out) | Rows returned |
| T3.9 | No block | Returns normally |
| T3.10 | Non-poster querying draft | 0 rows |

### T4 — `media-serve` authorization (8 tests)

| # | Setup | Expected |
|---|---|---|
| T4.1 | Group member, no block | Returns storage key → 200 |
| T4.2 | A blocks B (poster) | Empty set → 403 |
| T4.3 | Outsider | Empty set → 403 |
| T4.4 | Poster | Returns key → 200 |
| T4.5 | B was eligible participant before block | Returns key (carve-out) → 200 |
| T4.6 | Challenge moderator-removed | Empty set → 403 |
| T4.7 | `media_object.status = 'pending_review'` | Empty set → 403 |
| T4.8 | `remove_media` ran; status = 'removed' | Empty set → 403 |

### T5 — `report_content` media_object lock order (2 tests)

| # | Setup | Expected |
|---|---|---|
| T5.1 | `remove_media` holds challenge lock; concurrent `report_content('media_object')` | Blocks on challenge; after remove commits: linkage changed OR status ≠ 'ready' → FK_NOT_FOUND |
| T5.2 | `report_content('media_object')` commits first; then `remove_media` runs | `remove_media` captures and actions the new report |

### T6 — Bulk report resolution + audit (7 tests)

| # | Setup | Expected |
|---|---|---|
| T6.1 | A and B report same comment | Both actioned; 2 moderation_action_reports rows |
| T6.2 | A and B report same challenge | Both actioned; 2 rows |
| T6.3 | A reports challenge; B reports linked media_object | Both actioned; 2 rows |
| T6.4 | A and B via `remove_media` | Both actioned; 2 rows |
| T6.5 | Single pending report | 1 row |
| T6.6 | Completeness check | Every actioned report has exactly one moderation_action_reports row |
| T6.7 | One dismissed, one pending; removal runs | Pending actioned; dismissed unchanged; 1 new row |

### T7 — Concurrency (5 tests)

| # | Setup | Expected |
|---|---|---|
| T7.1 | Two moderators, same challenge, each holds one report | One full action; second takes idempotency path; both reports actioned; no duplicate evidence |
| T7.2 | Concurrent dismiss + remove_content on same report | Lock serializes; second sees status ≠ 'pending' → no-op or FK_WRONG_STATE |
| T7.3 | `report_content` races `remove_content` on challenge | If remove wins: FK_NOT_FOUND for reporter. If report wins: removal actions it |
| T7.4 | Two identical `report_content` calls | Dedup: both return same report_id |
| T7.5 | `remove_media` where poster re-uploaded between provisional read and lock | FK_LINKAGE_CHANGED |

### T8 — Idempotency (8 tests)

| # | Setup | Expected |
|---|---|---|
| T8.1 | Challenge removed; `remove_content('challenge')` called again | Idempotency path; new pending reports linked to existing action via moderator_removal_action_id |
| T8.2 | After removal; new reporter files | FK_NOT_FOUND (challenge.moderator_removed_at IS NOT NULL) |
| T8.3 | `remove_media` on media status = 'removed' | FK_WRONG_STATE |
| T8.4 | `remove_media` on media status = 'rejected' | FK_WRONG_STATE |
| T8.5 | Comment removed; `remove_content('comment')` called again | Idempotency path via comment.moderator_removal_action_id; new reports linked and actioned |
| T8.6 | Clue removed; `remove_content('clue')` called again | Idempotency path via clue.moderator_removal_action_id; new reports linked and actioned |
| T8.7 | Challenge removed via `remove_media`; then `remove_content('challenge')` called | challenge.moderator_removed_at IS NOT NULL; idempotency path reads moderator_removal_action_id (set by `remove_media`); links new pending reports to photo_removed action |
| T8.8 | `remove_content('challenge')` then `remove_media` on same challenge | `remove_media` locks challenge; idempotency path triggered; no new action |

### T9 — `p_report_id` validation (3 tests)

| # | Setup | Expected |
|---|---|---|
| T9.1 | Valid pending report against target | Succeeds; moderation_actions.report_id = p_report_id |
| T9.2 | p_report_id targets a different challenge | FK_REPORT_TARGET_MISMATCH |
| T9.3 | p_report_id = NULL | Proactive removal; NULL moderation_actions.report_id |

### T10 — `action_report` validation (4 tests)

| # | Setup | Expected |
|---|---|---|
| T10.1 | Valid prior action, same subject | Report actioned; row in moderation_action_reports |
| T10.2 | Prior action = 'report_dismissed' | FK_INVALID_PRIOR_ACTION |
| T10.3 | Prior action targets different challenge | FK_REPORT_TARGET_MISMATCH |
| T10.4 | No violation; no prior action | Use dismiss_report |

### T11 — Suspension (10 tests)

| # | Setup | Expected |
|---|---|---|
| T11.1 | Suspended INSERT comment | RESTRICTIVE rejects |
| T11.2 | Suspended UPDATE challenge (draft) | RESTRICTIVE rejects |
| T11.3 | Suspended `redeem_group_invite` | FK_SUSPENDED |
| T11.4 | Suspended cancel_challenge | Allowed |
| T11.5 | Suspended author soft-deletes own comment | Allowed (trigger Path 2) |
| T11.6 | Suspended exclusion reason='removed' | RESTRICTIVE rejects |
| T11.7 | Suspended exclusion reason='withdrew' | Allowed |
| T11.8 | Transfer to suspended recipient | Function guard rejects |
| T11.9 | Poster reports an active comment on their own challenge | Succeeds (poster_id check in comment visibility) |
| T11.10 | Non-group-member attempts to report a profile | FK_NOT_FOUND |

### T12 — SHA-256 integrity (4 tests)

| # | Setup | Expected |
|---|---|---|
| T12.1 | Valid lowercase 64-char hex | Stored; constraint passes |
| T12.2 | NULL | FK_INVALID_HASH |
| T12.3 | Uppercase hex | FK_INVALID_HASH |
| T12.4 | Pre-V2 row; sha256_hash IS NULL | FK_MEDIA_METADATA_INCOMPLETE on moderation attempt |

### T13 — Cleanup hold (7 tests)

| # | Setup | Expected |
|---|---|---|
| T13.1 | A and B have pending reports on same media | Not claimable |
| T13.2 | A's report dismissed | Still not claimable |
| T13.3 | B's report also dismissed | Now claimable |
| T13.4 | Challenge inappropriate_image report pending | Linked media not claimable |
| T13.5 | That report dismissed | Media now claimable |
| T13.6 | `get_poster_media_status` called with wrong uploader_id | No row returned |
| T13.7 | `get_poster_media_status` called with correct uploader_id; status = 'rejected' | Returns status + rejection_message |

### T14 — Clue visibility after removal (3 tests)

| # | Setup | Expected |
|---|---|---|
| T14.1 | `remove_content('clue')` executes | clue.moderator_removed_at IS NOT NULL |
| T14.2 | Authenticated user queries removed clue | 0 rows (RESTRICTIVE policy) |
| T14.3 | Service role (BYPASSRLS) queries removed clue | Row returned; text preserved for evidence |

---

## Part 11 — Success Criteria

- [ ] Comment trigger: SECURITY INVOKER; server timestamps in both paths; T1.x pass
- [ ] `can_view_challenge()` enforces `posted_at IS NOT NULL` for non-posters; T2.x pass
- [ ] `private.can_viewer_access_challenge(viewer_id)` defined for service-role callers
- [ ] All new public tables: RLS enabled; PUBLIC/anon/authenticated revoked; access re-granted per Part 4
- [ ] `public.get_media_serve_authorization`: EXECUTE to service_role only; combines authorization + key; T4.x pass
- [ ] `media_object` target in `report_content`: challenge → media lock order; T5.x pass
- [ ] `report_content` ON CONFLICT uses column-list inference with `WHERE status = 'pending'` (not constraint name)
- [ ] `report_content` comment visibility includes `c.poster_id = private.auth_uid()`; T11.9 passes
- [ ] Removal functions: content target → reports (UUID order) → media
- [ ] `p_report_id` validated in lock set; FK_REPORT_TARGET_MISMATCH if absent; T9.x pass
- [ ] `moderator_removal_action_id` column on challenges, comments, clues; set atomically during first removal
- [ ] Idempotency path reads `moderator_removal_action_id`; correct for all removal pathways; T8.5–T8.8 pass
- [ ] `moderation_action_reports` UNIQUE(report_id); every resolved report has exactly one row; T6.6 passes
- [ ] `action_report` requires same-subject substantive prior action; T10.x pass
- [ ] RESTRICTIVE SELECT on `public.clues`: `WHERE moderator_removed_at IS NULL`; T14.x pass
- [ ] `get_poster_media_status` requires `uploaded_by = p_uploader_id`; p_uploader_id from JWT; T13.6–T13.7 pass
- [ ] `private.cleanup_expired_evidence`: owned by forkensics_executor; EXECUTE revoked from PUBLIC/anon/authenticated; EXECUTE granted to service_role; scheduled daily
- [ ] Deadlock-free; T7.x pass
- [ ] `redeem_group_invite` internal suspension guard; T11.3 passes
- [ ] `transfer_group_ownership`: recipient unsuspended; audited in group_ownership_history; T11.8 passes
- [ ] SHA-256 two-migration plan; T12.x pass
- [ ] Text-filter triggers on all UGC fields
- [ ] RESTRICTIVE suspension policies; T11.x pass
- [ ] RESTRICTIVE block policies; T3.x pass
- [ ] Cleanup hold covers both media_object and inappropriate_image report types; T13.x pass
- [ ] No executable SQL written until governance approval
