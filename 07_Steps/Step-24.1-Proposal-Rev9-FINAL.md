# Step 24.1 — UGC Safety and Moderation Contracts
## Final Proposal (Rev 9)

**Status:** Pending approval (Claude → Codex/GPT → Bill)
**Governance gate:** Bill must type `APPROVED: Step 24.1 — UGC Safety and Moderation Contracts` before any SQL in this document is written as executable code or applied to any environment.
**Self-contained:** This document is the complete approved contract. No prior revision (Rev 1–8) need be consulted for implementation.

**Changes from Rev 8:**
1. `uploaded_by` corrected to `uploader_id` (V1 column name) in `get_poster_media_status`, tests, success criteria.
2. New Part 5: complete role ownership and privilege grant sequence — temporary grant, ownership assignment, table/function grants, revoke.
3. New Part 6: forge-protection triggers force `moderator_removed_at` and `moderator_removal_action_id` to NULL on INSERT; BEFORE UPDATE guards on challenges and clues; consistency CHECK constraint on all three tables; comment trigger Path 1 updated to include `moderator_removal_action_id`.
4. `hide_blocked_challenges` corrected to use `private.has_block_with(poster_id)` (SECURITY DEFINER, bilateral); `blocks_select_own` on `user_blocks` declared explicitly `AS PERMISSIVE`.
5. `report_content` comment-target visibility: group membership required; predicate matches V1 Table Talk contract (group member AND (poster OR revealed OR guessed)); author branch removed.

---

## Part 1 — Scope and Confirmed Decisions

### 1.1 What this step covers

All database schema, trigger replacements, RLS policy additions, SECURITY DEFINER functions, role ownership and privilege grants, forge-protection triggers, cleanup contracts, and operational procedures required for:

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
- Cleanup worker: Part for `rejected` and `removed` media (using functions in Part 11 below)

### 1.4 Confirmed decisions

1. Comment placeholder: `[removed by moderator]`; evidence is audit metadata only.
2. Block on active challenge: existing eligible participants retain read-only visibility; no new interactions.
3. Moderation-action immutability: unconditional `BEFORE UPDATE OR DELETE` rejection.
4. Avatar photos: disabled in V1. No upload or moderation gate needed.
5. Text-filter trigger: `SECURITY DEFINER` (to access private schema), no caller bypass.
6. RESTRICTIVE RLS policy approach approved (except where noted as PERMISSIVE below).
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
27. Moderator-removed clues hidden via RESTRICTIVE SELECT policy (`moderator_removed_at IS NULL`); clue text not replaced (preserved in evidence only).
28. `get_poster_media_status` derives `p_uploader_id` from Edge Function JWT; query requires `media_objects.uploader_id = p_uploader_id`.
29. V1 revoked postgres membership in both custom roles and revoked future-object grants; migration explicitly re-grants required access using the temporary-grant pattern.
30. `moderator_removed_at` and `moderator_removal_action_id` are server-owned fields; forced to NULL on INSERT by trigger; only forkensics_executor may transition NULL → non-NULL; once set, immutable.
31. `hide_blocked_challenges` uses `private.has_block_with(poster_id)` (SECURITY DEFINER, bilateral) not a direct `user_blocks` query. `blocks_select_own` on the new `user_blocks` table is `AS PERMISSIVE` — without at least one permissive policy a table with RLS enabled returns no rows.
32. `report_content` comment-target visibility matches V1 Table Talk contract: current group member AND (poster OR challenge revealed per `private.is_challenge_revealed()` OR caller has guessed). The author-is-self branch is omitted because self-reporting is already rejected.

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
  -- Both moderator_removed_at and moderator_removal_action_id transition NULL → non-NULL together.
  -- The server-owned moderator_removed_at is overridden to clock_timestamp().
  -- The moderator_removal_action_id value supplied by forkensics_executor passes through (trusted).
  IF current_user = 'forkensics_executor'
     AND OLD.moderator_removed_at IS NULL
     AND OLD.moderator_removal_action_id IS NULL
     AND NEW.moderator_removed_at IS NOT NULL
     AND NEW.moderator_removal_action_id IS NOT NULL
     AND NEW.text = '[removed by moderator]'
     AND NEW.id IS NOT DISTINCT FROM OLD.id
     AND NEW.author_id IS NOT DISTINCT FROM OLD.author_id
     AND NEW.challenge_id IS NOT DISTINCT FROM OLD.challenge_id
     AND NEW.posted_at IS NOT DISTINCT FROM OLD.posted_at
     AND NEW.deleted_at IS NOT DISTINCT FROM OLD.deleted_at
  THEN
    NEW.moderator_removed_at := clock_timestamp();   -- override caller-supplied timestamp
    RETURN NEW;
  END IF;

  -- Path 2: Author soft-delete.
  -- moderator_removal_action_id must remain NULL (author cannot set it).
  IF NEW.author_id = private.auth_uid()
     AND OLD.deleted_at IS NULL
     AND NEW.deleted_at IS NOT NULL
     AND NEW.id IS NOT DISTINCT FROM OLD.id
     AND NEW.text IS NOT DISTINCT FROM OLD.text
     AND NEW.challenge_id IS NOT DISTINCT FROM OLD.challenge_id
     AND NEW.posted_at IS NOT DISTINCT FROM OLD.posted_at
     AND NEW.moderator_removed_at IS NOT DISTINCT FROM OLD.moderator_removed_at
     AND NEW.moderator_removal_action_id IS NOT DISTINCT FROM OLD.moderator_removal_action_id
  THEN
    NEW.deleted_at := clock_timestamp();             -- override caller-supplied timestamp
    RETURN NEW;
  END IF;

  RAISE EXCEPTION 'FK_COMMENT_IMMUTABLE: comment update not permitted';
END;
$$;
```

Column-level GRANTs prevent `authenticated` from supplying `moderator_removed_at` or `moderator_removal_action_id`; the trigger's guards are an independent additional layer.

---

## Part 3 — Schema

### 3.1 `public.profiles` — addition

```sql
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS is_suspended boolean NOT NULL DEFAULT false;
```

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

-- Partial unique index (NOT a named constraint).
-- ON CONFLICT must use column-list inference: ON CONFLICT (...) WHERE status = 'pending'
-- Do NOT use: ON CONFLICT ON CONSTRAINT content_reports_unresolved_dedup
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

### 3.7 `private.moderators`

```sql
CREATE TABLE IF NOT EXISTS private.moderators (
  profile_id  uuid PRIMARY KEY REFERENCES public.profiles(id) ON DELETE RESTRICT,
  added_at    timestamptz NOT NULL DEFAULT clock_timestamp()
);
```

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

### 3.10 Column additions to existing tables

```sql
-- Moderator removal timestamps
ALTER TABLE public.challenges
  ADD COLUMN IF NOT EXISTS moderator_removed_at timestamptz;

ALTER TABLE public.comments
  ADD COLUMN IF NOT EXISTS moderator_removed_at timestamptz;

ALTER TABLE public.clues
  ADD COLUMN IF NOT EXISTS moderator_removed_at timestamptz;

-- Durable idempotency references — server-owned; see Part 6 for forge-protection triggers
ALTER TABLE public.challenges
  ADD COLUMN IF NOT EXISTS moderator_removal_action_id uuid
    REFERENCES public.moderation_actions(id) ON DELETE RESTRICT;

ALTER TABLE public.comments
  ADD COLUMN IF NOT EXISTS moderator_removal_action_id uuid
    REFERENCES public.moderation_actions(id) ON DELETE RESTRICT;

ALTER TABLE public.clues
  ADD COLUMN IF NOT EXISTS moderator_removal_action_id uuid
    REFERENCES public.moderation_actions(id) ON DELETE RESTRICT;

-- Consistency constraints: both NULL or both non-NULL
ALTER TABLE public.challenges
  ADD CONSTRAINT challenges_removal_consistency CHECK (
    (moderator_removed_at IS NULL) = (moderator_removal_action_id IS NULL)
  );

ALTER TABLE public.comments
  ADD CONSTRAINT comments_removal_consistency CHECK (
    (moderator_removed_at IS NULL) = (moderator_removal_action_id IS NULL)
  );

ALTER TABLE public.clues
  ADD CONSTRAINT clues_removal_consistency CHECK (
    (moderator_removed_at IS NULL) = (moderator_removal_action_id IS NULL)
  );

-- Cleanup lease and moderated timestamp on media
ALTER TABLE public.media_objects
  ADD COLUMN IF NOT EXISTS moderated_at                     timestamptz,
  ADD COLUMN IF NOT EXISTS moderation_cleanup_leased_until  timestamptz;

-- media_objects status constraint: full V2 set (replace V1 CHECK constraint by name)
```

### 3.11 `private.media_storage_keys` — SHA-256 column

```sql
-- Migration V2a: nullable with format constraint
ALTER TABLE private.media_storage_keys
  ADD COLUMN IF NOT EXISTS sha256_hash text
    CONSTRAINT msk_sha256_format CHECK (sha256_hash ~ '^[0-9a-f]{64}$');

-- Before V2b: verify SELECT count(*) FROM private.media_storage_keys WHERE sha256_hash IS NULL = 0

-- Migration V2b: enforce NOT NULL
ALTER TABLE private.media_storage_keys
  ALTER COLUMN sha256_hash SET NOT NULL;
```

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

-- Re-grant only intended direct access:
-- user_blocks: authenticated SELECT only (controlled by PERMISSIVE own-row policy; see Part 9)
GRANT SELECT ON public.user_blocks TO authenticated;

-- content_reports, moderation_actions, group_ownership_history:
-- No direct access for authenticated. All access via SECURITY DEFINER functions.
```

---

## Part 5 — Role Ownership and Function Privilege Grants

V1 revoked `postgres` membership in both custom roles and revoked default future-object privileges. The V2 migration must use a temporary-grant pattern to assign ownership and install explicit grants.

### 5.1 Temporary role grant (open)

```sql
-- Allow postgres to SET ROLE / ALTER OWNER to custom roles during this migration only.
GRANT forkensics_executor   TO postgres;
GRANT forkensics_rls_helper TO postgres;
```

### 5.2 Function ownership

```sql
-- RLS helper functions → forkensics_rls_helper
ALTER FUNCTION private.can_view_challenge(uuid)              OWNER TO forkensics_rls_helper;
ALTER FUNCTION private.can_viewer_access_challenge(uuid,uuid) OWNER TO forkensics_rls_helper;
ALTER FUNCTION private.has_block_with(uuid)                  OWNER TO forkensics_rls_helper;
ALTER FUNCTION private.has_block_with_poster(uuid)           OWNER TO forkensics_rls_helper;

-- Trigger functions → forkensics_executor (accesses private schema or forkensics_executor path)
ALTER FUNCTION private.check_text_content_trigger()          OWNER TO forkensics_executor;
ALTER FUNCTION public.restrict_comment_updates()             OWNER TO forkensics_executor;
ALTER FUNCTION private.force_removal_fields_null()           OWNER TO forkensics_executor;
ALTER FUNCTION private.restrict_moderation_field_updates()   OWNER TO forkensics_executor;

-- All SECURITY DEFINER public functions → forkensics_executor
ALTER FUNCTION public.check_text_content(text)               OWNER TO forkensics_executor;
ALTER FUNCTION public.report_content(text,uuid,text,text)    OWNER TO forkensics_executor;
ALTER FUNCTION public.block_user(uuid)                       OWNER TO forkensics_executor;
ALTER FUNCTION public.unblock_user(uuid)                     OWNER TO forkensics_executor;
ALTER FUNCTION public.approve_photo(uuid,uuid,text)          OWNER TO forkensics_executor;
ALTER FUNCTION public.reject_photo(uuid,uuid,text)           OWNER TO forkensics_executor;
ALTER FUNCTION public.remove_content(text,uuid,uuid,uuid,text) OWNER TO forkensics_executor;
ALTER FUNCTION public.remove_media(uuid,uuid,uuid,text)      OWNER TO forkensics_executor;
ALTER FUNCTION public.suspend_user(uuid,uuid,text)           OWNER TO forkensics_executor;
ALTER FUNCTION public.reinstate_user(uuid,uuid,text)         OWNER TO forkensics_executor;
ALTER FUNCTION public.dismiss_report(uuid,uuid,text)         OWNER TO forkensics_executor;
ALTER FUNCTION public.action_report(uuid,uuid,uuid,text)     OWNER TO forkensics_executor;
ALTER FUNCTION public.get_media_serve_authorization(uuid,uuid) OWNER TO forkensics_executor;
ALTER FUNCTION public.get_moderation_queue()                 OWNER TO forkensics_executor;
ALTER FUNCTION public.get_pending_review_media(uuid)         OWNER TO forkensics_executor;
ALTER FUNCTION public.get_reported_media(uuid)               OWNER TO forkensics_executor;
ALTER FUNCTION public.get_poster_media_status(uuid,uuid)     OWNER TO forkensics_executor;
ALTER FUNCTION public.get_my_reports()                       OWNER TO forkensics_executor;
ALTER FUNCTION public.get_report_for_review(uuid)            OWNER TO forkensics_executor;
ALTER FUNCTION public.claim_moderation_media_cleanup(int)    OWNER TO forkensics_executor;
ALTER FUNCTION public.mark_moderation_media_cleaned(uuid)    OWNER TO forkensics_executor;
ALTER FUNCTION private.cleanup_expired_evidence()            OWNER TO forkensics_executor;
```

### 5.3 Table access grants for `forkensics_executor`

```sql
-- New public tables
GRANT SELECT, INSERT, UPDATE ON public.content_reports         TO forkensics_executor;
GRANT SELECT, INSERT, DELETE ON public.user_blocks             TO forkensics_executor;
GRANT SELECT, INSERT         ON public.moderation_actions      TO forkensics_executor;
GRANT SELECT, INSERT         ON public.group_ownership_history TO forkensics_executor;

-- Existing public tables — new columns only where table-level grant may not cover them
-- (defensive; V1 may already have table-level grants; explicit column grants are additive)
GRANT UPDATE (moderator_removed_at, moderator_removal_action_id, state, cancellation_reason)
  ON public.challenges TO forkensics_executor;
GRANT UPDATE (moderator_removed_at, moderator_removal_action_id, text, deleted_at)
  ON public.comments TO forkensics_executor;
GRANT UPDATE (moderator_removed_at, moderator_removal_action_id)
  ON public.clues TO forkensics_executor;
GRANT UPDATE (is_suspended)
  ON public.profiles TO forkensics_executor;
GRANT UPDATE (status, moderated_at, moderation_cleanup_leased_until)
  ON public.media_objects TO forkensics_executor;

-- Private tables
GRANT SELECT, INSERT, UPDATE, DELETE ON private.blocked_terms         TO forkensics_executor;
GRANT SELECT, INSERT                 ON private.moderators            TO forkensics_executor;
GRANT SELECT, INSERT, UPDATE         ON private.profile_suspensions   TO forkensics_executor;
GRANT SELECT, INSERT                 ON private.moderation_evidence   TO forkensics_executor;
GRANT SELECT, INSERT                 ON private.moderation_action_reports TO forkensics_executor;
GRANT SELECT, UPDATE (sha256_hash, re_encoded_storage_key)
  ON private.media_storage_keys TO forkensics_executor;
```

### 5.4 Table access grants for `forkensics_rls_helper`

```sql
-- RLS helper functions call these tables as SECURITY DEFINER
GRANT SELECT ON public.user_blocks           TO forkensics_rls_helper;
GRANT SELECT ON public.challenges            TO forkensics_rls_helper;
GRANT SELECT ON public.group_members         TO forkensics_rls_helper;
GRANT SELECT ON public.eligible_participants TO forkensics_rls_helper;
GRANT SELECT ON public.profiles              TO forkensics_rls_helper;
```

### 5.5 EXECUTE grants on RLS helpers

RLS policy evaluation runs in the context of the calling user. `authenticated` must be able to execute the helper functions invoked by policies.

```sql
GRANT EXECUTE ON FUNCTION private.can_view_challenge(uuid)          TO authenticated;
GRANT EXECUTE ON FUNCTION private.has_block_with(uuid)              TO authenticated;
GRANT EXECUTE ON FUNCTION private.has_block_with_poster(uuid)       TO authenticated;
-- can_viewer_access_challenge is service-role only (not called from authenticated RLS policies)
GRANT EXECUTE ON FUNCTION private.can_viewer_access_challenge(uuid,uuid) TO service_role;
```

### 5.6 EXECUTE grants on public functions

```sql
-- authenticated callers
GRANT EXECUTE ON FUNCTION public.report_content(text,uuid,text,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.block_user(uuid)                    TO authenticated;
GRANT EXECUTE ON FUNCTION public.unblock_user(uuid)                  TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_my_reports()                    TO authenticated;
-- Revoke from PUBLIC (Supabase may grant broad defaults)
REVOKE EXECUTE ON FUNCTION public.report_content(text,uuid,text,text) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.block_user(uuid)                    FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.unblock_user(uuid)                  FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.get_my_reports()                    FROM PUBLIC, anon;

-- service_role only
GRANT EXECUTE ON FUNCTION public.check_text_content(text)               TO service_role;
GRANT EXECUTE ON FUNCTION public.approve_photo(uuid,uuid,text)           TO service_role;
GRANT EXECUTE ON FUNCTION public.reject_photo(uuid,uuid,text)            TO service_role;
GRANT EXECUTE ON FUNCTION public.remove_content(text,uuid,uuid,uuid,text) TO service_role;
GRANT EXECUTE ON FUNCTION public.remove_media(uuid,uuid,uuid,text)       TO service_role;
GRANT EXECUTE ON FUNCTION public.suspend_user(uuid,uuid,text)            TO service_role;
GRANT EXECUTE ON FUNCTION public.reinstate_user(uuid,uuid,text)          TO service_role;
GRANT EXECUTE ON FUNCTION public.dismiss_report(uuid,uuid,text)          TO service_role;
GRANT EXECUTE ON FUNCTION public.action_report(uuid,uuid,uuid,text)      TO service_role;
GRANT EXECUTE ON FUNCTION public.get_media_serve_authorization(uuid,uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.get_moderation_queue()                  TO service_role;
GRANT EXECUTE ON FUNCTION public.get_pending_review_media(uuid)          TO service_role;
GRANT EXECUTE ON FUNCTION public.get_reported_media(uuid)                TO service_role;
GRANT EXECUTE ON FUNCTION public.get_poster_media_status(uuid,uuid)      TO service_role;
GRANT EXECUTE ON FUNCTION public.get_report_for_review(uuid)             TO service_role;
GRANT EXECUTE ON FUNCTION public.claim_moderation_media_cleanup(int)     TO service_role;
GRANT EXECUTE ON FUNCTION public.mark_moderation_media_cleaned(uuid)     TO service_role;
GRANT EXECUTE ON FUNCTION private.cleanup_expired_evidence()             TO service_role;
-- Revoke service-only functions from PUBLIC, anon, authenticated
REVOKE EXECUTE ON FUNCTION public.approve_photo(uuid,uuid,text)           FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.reject_photo(uuid,uuid,text)            FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.remove_content(text,uuid,uuid,uuid,text) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.remove_media(uuid,uuid,uuid,text)       FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.suspend_user(uuid,uuid,text)            FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.reinstate_user(uuid,uuid,text)          FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.dismiss_report(uuid,uuid,text)          FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.action_report(uuid,uuid,uuid,text)      FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.get_media_serve_authorization(uuid,uuid) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.get_moderation_queue()                  FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.get_pending_review_media(uuid)          FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.get_reported_media(uuid)                FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.get_poster_media_status(uuid,uuid)      FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.get_report_for_review(uuid)             FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.claim_moderation_media_cleanup(int)     FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.mark_moderation_media_cleaned(uuid)     FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION private.cleanup_expired_evidence()             FROM PUBLIC, anon, authenticated;
```

### 5.7 Temporary role grant (close)

```sql
-- Revoke temporary membership granted at migration start.
REVOKE forkensics_executor   FROM postgres;
REVOKE forkensics_rls_helper FROM postgres;
```

---

## Part 6 — Forge-Protection Triggers

### 6.1 INSERT forge-nulling trigger

Forces `moderator_removed_at` and `moderator_removal_action_id` to NULL on every INSERT, regardless of what the caller supplies. Applies to challenges, comments, and clues.

```sql
CREATE OR REPLACE FUNCTION private.force_removal_fields_null()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  NEW.moderator_removed_at       := NULL;
  NEW.moderator_removal_action_id := NULL;
  RETURN NEW;
END;
$$;

CREATE TRIGGER force_challenge_removal_null
  BEFORE INSERT ON public.challenges FOR EACH ROW
  EXECUTE FUNCTION private.force_removal_fields_null();

CREATE TRIGGER force_comment_removal_null
  BEFORE INSERT ON public.comments FOR EACH ROW
  EXECUTE FUNCTION private.force_removal_fields_null();

CREATE TRIGGER force_clue_removal_null
  BEFORE INSERT ON public.clues FOR EACH ROW
  EXECUTE FUNCTION private.force_removal_fields_null();
```

This trigger is `SECURITY DEFINER` and is owned by `forkensics_executor`. It fires before any V1 INSERT triggers on those tables.

### 6.2 UPDATE guard for challenges and clues

Prevents any role other than `forkensics_executor` from setting `moderator_removed_at` or `moderator_removal_action_id` from NULL to non-NULL; also prevents any modification once either field is set. This is `SECURITY INVOKER` so `current_user` reflects the actual caller.

```sql
CREATE OR REPLACE FUNCTION private.restrict_moderation_field_updates()
RETURNS trigger LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
BEGIN
  -- Once set, both fields are immutable (regardless of caller)
  IF OLD.moderator_removed_at IS NOT NULL THEN
    IF NEW.moderator_removed_at IS DISTINCT FROM OLD.moderator_removed_at OR
       NEW.moderator_removal_action_id IS DISTINCT FROM OLD.moderator_removal_action_id
    THEN
      RAISE EXCEPTION 'FK_REMOVAL_IMMUTABLE: moderation removal fields cannot be changed once set';
    END IF;
  END IF;

  -- Only forkensics_executor may transition NULL → non-NULL
  IF OLD.moderator_removed_at IS NULL AND NEW.moderator_removed_at IS NOT NULL
     AND current_user != 'forkensics_executor'
  THEN
    RAISE EXCEPTION 'FK_REMOVAL_UNAUTHORIZED: only forkensics_executor may set moderator_removed_at';
  END IF;

  IF OLD.moderator_removal_action_id IS NULL AND NEW.moderator_removal_action_id IS NOT NULL
     AND current_user != 'forkensics_executor'
  THEN
    RAISE EXCEPTION 'FK_REMOVAL_UNAUTHORIZED: only forkensics_executor may set moderator_removal_action_id';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER restrict_challenge_removal_fields
  BEFORE UPDATE ON public.challenges FOR EACH ROW
  EXECUTE FUNCTION private.restrict_moderation_field_updates();

CREATE TRIGGER restrict_clue_removal_fields
  BEFORE UPDATE ON public.clues FOR EACH ROW
  EXECUTE FUNCTION private.restrict_moderation_field_updates();
```

For `public.comments`, the same protection is embedded in `restrict_comment_updates` (Path 1 explicitly checks old/new states; all other paths must preserve both fields via `IS NOT DISTINCT FROM` assertions).

---

## Part 7 — RLS Helper Functions

All helpers: owned by `forkensics_rls_helper`, `SECURITY DEFINER`, `SET search_path = ''`, `STABLE`.

### 7.1 `private.can_view_challenge(p_challenge_id uuid) → boolean`

For RLS policies where `auth_uid()` is the viewer.

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

### 7.2 `private.can_viewer_access_challenge(p_challenge_id uuid, p_viewer_id uuid) → boolean`

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

### 7.3 `private.has_block_with(p_profile_id uuid) → boolean`

SECURITY DEFINER — sees both directions of blocks regardless of the calling user's SELECT privileges.

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

### 7.4 `private.has_block_with_poster(p_challenge_id uuid) → boolean`

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

## Part 8 — Text Filtering

### 8.1 Trigger function

`SECURITY DEFINER` to access `private.blocked_terms`. No caller bypass. The moderator placeholder `[removed by moderator]` is not a blocked term and passes naturally.

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

### 8.2 Trigger attachments

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

## Part 9 — RLS Policy Additions

All policies on existing V1 tables are `AS RESTRICTIVE`. Policies on new tables (which have no V1 permissive policies) are `AS PERMISSIVE` where required for any rows to be returned.

### 9.1 Suspension enforcement

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

### 9.2 `exclusion_events` — branched suspension policy

```sql
CREATE POLICY suspend_exclusion_insert AS RESTRICTIVE ON public.exclusion_events
  FOR INSERT TO authenticated
  WITH CHECK (
    NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = private.auth_uid() AND is_suspended = true)
    OR (reason = 'withdrew' AND player_id = private.auth_uid())
  );
```

### 9.3 Block enforcement — INSERT

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

### 9.4 Block enforcement — SELECT

```sql
-- CORRECTED: uses has_block_with() (SECURITY DEFINER, bilateral) not direct user_blocks query.
-- This correctly captures both "viewer blocks poster" and "poster blocks viewer".
CREATE POLICY hide_blocked_challenges AS RESTRICTIVE ON public.challenges
  FOR SELECT TO authenticated
  USING (
    poster_id = private.auth_uid()
    OR NOT private.has_block_with(poster_id)
    OR EXISTS (
      SELECT 1 FROM public.eligible_participants ep
      WHERE ep.challenge_id = id AND ep.player_id = private.auth_uid()
    )
  );

-- Comments: block-aware challenge access + hide blocked authors
CREATE POLICY block_aware_comment_visibility AS RESTRICTIVE ON public.comments
  FOR SELECT TO authenticated
  USING (
    private.can_view_challenge(challenge_id)
    AND NOT private.has_block_with(author_id)
  );

-- Reactions
CREATE POLICY block_aware_reaction_visibility AS RESTRICTIVE ON public.reactions
  FOR SELECT TO authenticated
  USING (
    private.can_view_challenge(challenge_id)
    AND NOT private.has_block_with(player_id)
  );
```

### 9.5 Moderator-removed clues — hidden from authenticated

```sql
CREATE POLICY hide_removed_clues AS RESTRICTIVE ON public.clues
  FOR SELECT TO authenticated
  USING (moderator_removed_at IS NULL);
```

Service role (BYPASSRLS) reads removed clues for evidence. Moderators access removed clue text exclusively via `private.moderation_evidence`.

### 9.6 Block-aware visibility on all challenge-linked child tables

Applied to: `clues`, `challenge_secrets`, `challenge_answer_aliases`, `guess_attempts`, `guess_judgments`, `score_runs`, `score_events`, `correction_events`, `eligible_participants`, `exclusion_events`.

```sql
-- Template (replace <table> and <challenge_fk>):
CREATE POLICY block_aware_visibility AS RESTRICTIVE ON public.<table>
  FOR SELECT TO authenticated
  USING (private.can_view_challenge(<challenge_fk>));
```

### 9.7 `user_blocks` SELECT policy

This is a **PERMISSIVE** policy. `user_blocks` is a new table with RLS enabled and no V1 permissive policies. Without at least one permissive policy the table returns no rows regardless of restrictive policies.

```sql
CREATE POLICY blocks_select_own AS PERMISSIVE ON public.user_blocks
  FOR SELECT TO authenticated
  USING (blocker_id = private.auth_uid());
```

No INSERT, UPDATE, or DELETE policies. All mutations via `block_user` / `unblock_user`.

---

## Part 10 — SECURITY DEFINER Functions

All: owned by `forkensics_executor`, `SET search_path = ''`. EXECUTE grants as specified in Part 5.

### 10.1 Moderator identity validation (internal)

```sql
IF NOT EXISTS (
  SELECT 1 FROM private.moderators m
  JOIN public.profiles p ON p.id = m.profile_id
  WHERE m.profile_id = p_moderator_id AND p.is_active = true
) THEN
  RAISE EXCEPTION 'FK_UNAUTHORIZED: moderator identity not valid';
END IF;
```

### 10.2 Global lock order

**content target → all matching pending reports (ascending `id` UUID) → media**

### 10.3 `public.check_text_content(p_text text) → boolean`

Early validation for Edge Functions. Returns `true` if no blocked term found. The trigger is authoritative enforcement.

### 10.4 `public.report_content`

```
public.report_content(
  p_target_type text,
  p_target_id   uuid,
  p_category    text,
  p_detail      text  -- nullable
) → TABLE(report_id uuid)
```

1. Verify caller is active, onboarded. Suspended callers are permitted to report.
2. Validate `target_type` and `category`.
3. Rate limit: fewer than 10 pending reports in the past hour.
4. **Lock and recheck target:**

   *`'challenge'`:* Lock challenge `FOR UPDATE`. Verify `private.can_view_challenge(p_target_id)`. Verify `moderator_removed_at IS NULL`.

   *`'comment'`:* Lock comment `FOR UPDATE`. Verify `moderator_removed_at IS NULL`. Then verify Table Talk visibility per the V1 contract:

   ```
   a. Read challenge (poster_id, group_id) via comment.challenge_id.
   b. Verify current group membership:
      EXISTS (SELECT 1 FROM group_members WHERE group_id = c.group_id AND player_id = auth_uid())
      If not → FK_NOT_FOUND.
   c. Verify at least one of:
      - c.poster_id = private.auth_uid()                  (challenge poster)
      - private.is_challenge_revealed(comment.challenge_id) (challenge revealed per V1 helper)
      - EXISTS (SELECT 1 FROM guess_attempts
                WHERE challenge_id = comment.challenge_id AND player_id = auth_uid())
      If none → FK_NOT_FOUND.
   ```

   Note: "caller is comment author" is not checked — self-reports are rejected at step 6.

   *`'clue'`:* Lock clue `FOR UPDATE`. Verify `moderator_removed_at IS NULL`. Verify `can_view_challenge(challenge_id)`.

   *`'media_object'`:* Six-step sequence matching `remove_media`'s lock order:
   a. Provisional read: `challenge_id` from `challenges WHERE media_object_id = p_target_id`.
   b. Lock challenge `FOR UPDATE`.
   c. Re-verify `challenges.media_object_id = p_target_id`. If mismatch → FK_NOT_FOUND.
   d. Re-check `private.can_view_challenge(challenge_id)`.
   e. Lock media_object `FOR UPDATE`.
   f. Verify `status = 'ready'`. Otherwise → FK_NOT_FOUND.

   *`'profile'`:* Verify target is active; caller shares at least one group with target. No row lock.

   In all cases: same FK_NOT_FOUND for nonexistent, unauthorized, and already-actioned targets.

5. Prevent self-report.
6. Insert with partial-index dedup:

   ```sql
   INSERT INTO public.content_reports (reporter_id, target_type, target_id, category, detail)
   VALUES (private.auth_uid(), p_target_type, p_target_id, p_category, p_detail)
   ON CONFLICT (reporter_id, target_type, target_id, category)
   WHERE status = 'pending'
   DO NOTHING
   RETURNING id INTO v_report_id;

   -- If dedup conflict:
   IF v_report_id IS NULL THEN
     SELECT id INTO v_report_id FROM public.content_reports
     WHERE reporter_id = private.auth_uid()
       AND target_type = p_target_type AND target_id = p_target_id
       AND category = p_category AND status = 'pending';
   END IF;
   ```

7. Return `report_id`.

### 10.5 `public.block_user(p_blocked_id uuid) → void`

Suspended callers permitted. Idempotent INSERT into `user_blocks`.

### 10.6 `public.unblock_user(p_blocked_id uuid) → void`

Idempotent DELETE where `blocker_id = auth_uid()`.

### 10.7 `public.approve_photo`

```
public.approve_photo(p_media_object_id uuid, p_moderator_id uuid, p_reason text) → void
```

1. Validate moderator.
2. Lock media `FOR UPDATE`. Verify `status = 'pending_review'`.
3. INSERT moderation_actions `(action_type = 'photo_approved')` RETURNING id.
4. UPDATE media_objects: `status = 'ready'`, `moderated_at = clock_timestamp()`.

### 10.8 `public.reject_photo`

```
public.reject_photo(p_media_object_id uuid, p_moderator_id uuid, p_reason text) → void
```

1. Validate moderator.
2. Lock media `FOR UPDATE`. Verify `status = 'pending_review'`.
3. Read `sha256_hash`. Raise `FK_MEDIA_METADATA_INCOMPLETE` if NULL.
4. INSERT moderation_actions RETURNING id → `v_action_id`.
5. INSERT moderation_evidence `(evidence_type = 'media_metadata', ...)`.
6. UPDATE media_objects: `status = 'rejected'`, `moderated_at = clock_timestamp()`.

### 10.9 `public.remove_content`

`p_report_id` is nullable. Lock order: target → reports → media.

```
public.remove_content(
  p_target_type  text,
  p_target_id    uuid,
  p_moderator_id uuid,
  p_report_id    uuid,  -- nullable
  p_reason       text
) → void
```

**For `'challenge'`:**

```
1.  Validate moderator.
2.  Lock challenge FOR UPDATE; read moderator_removed_at, moderator_removal_action_id.
3.  If moderator_removed_at IS NOT NULL → universal idempotency path (Section 10.11).
4.  Validate state per matrix (Section 10.9a).
5.  v_media_object_id := challenges.media_object_id.
6.  Lock all matching pending reports (challenge + linked media_object) ORDER BY id FOR UPDATE
    → v_report_ids[].
7.  If p_report_id IS NOT NULL: verify ∈ v_report_ids. Raise FK_REPORT_TARGET_MISMATCH if absent.
8.  Lock media FOR UPDATE. Validate per media state matrix.
9.  Read sha256_hash. Raise FK_MEDIA_METADATA_INCOMPLETE if NULL.
10. INSERT moderation_actions RETURNING id → v_action_id.
11. INSERT moderation_evidence (media_metadata).
12. UPDATE challenges: moderator_removed_at = clock_timestamp(), state per matrix,
      moderator_removal_action_id = v_action_id.   ← server-set atomically
13. UPDATE media_objects per media state matrix.
14. INSERT moderation_action_reports: one row per id in v_report_ids[].
15. UPDATE content_reports SET status = 'actioned' WHERE id = ANY(v_report_ids).
```

**For `'comment'`:**

```
1.  Validate moderator.
2.  Lock comment FOR UPDATE; read moderator_removed_at, moderator_removal_action_id.
    If moderator_removed_at IS NOT NULL → universal idempotency path.
3.  Lock matching pending reports ORDER BY id FOR UPDATE → v_report_ids[].
4.  If p_report_id IS NOT NULL: verify ∈ v_report_ids.
5.  INSERT moderation_actions RETURNING id → v_action_id.
6.  INSERT moderation_evidence (comment_text = original text).
7.  UPDATE comments: text = '[removed by moderator]', moderator_removed_at = clock_timestamp(),
      moderator_removal_action_id = v_action_id.   ← server-set atomically
8.  INSERT moderation_action_reports per v_report_ids[].
9.  UPDATE content_reports SET status = 'actioned'.
```

**For `'clue'`:**

```
1.  Validate moderator.
2.  Lock clue FOR UPDATE; read moderator_removed_at, moderator_removal_action_id.
    If moderator_removed_at IS NOT NULL → universal idempotency path.
3.  Lock matching pending reports ORDER BY id FOR UPDATE → v_report_ids[].
4.  If p_report_id IS NOT NULL: verify ∈ v_report_ids.
5.  INSERT moderation_actions RETURNING id → v_action_id.
6.  INSERT moderation_evidence (clue_text = clue.text).
7.  UPDATE clues: moderator_removed_at = clock_timestamp(),
      moderator_removal_action_id = v_action_id.   ← server-set atomically; clue text not changed
8.  INSERT moderation_action_reports per v_report_ids[].
9.  UPDATE content_reports SET status = 'actioned'.
```

### 10.9a State matrix

**Challenge state → outcome:**

| State | Outcome |
|---|---|
| `draft`, `active`, `locked` | state → `cancelled`, `cancellation_reason = 'moderation_action'`, `moderator_removed_at = clock_timestamp()` |
| `revealed` | state unchanged; `moderator_removed_at = clock_timestamp()`. Scores preserved. |
| `cancelled` (any) | `moderator_removed_at = clock_timestamp()` if not set; state unchanged. |

**Media status → action during challenge removal:**

| Status | Action |
|---|---|
| `ready`, `pending_review`, `rejected`, `superseded` | `status = 'removed'`, `moderated_at = clock_timestamp()` |
| `removed`, `cleaned` | Skip media UPDATE |
| `processing`, `failed` | Raise `FK_WRONG_STATE`; abort |

### 10.10 `public.remove_media`

`p_report_id` is nullable.

```
public.remove_media(p_media_object_id uuid, p_moderator_id uuid,
                    p_report_id uuid, p_reason text) → void
```

```
1.  Validate moderator.
2.  Provisional read: v_challenge_id from challenges WHERE media_object_id = p_media_object_id.
3.  Lock challenge FOR UPDATE; read moderator_removed_at, moderator_removal_action_id.
4.  If moderator_removed_at IS NOT NULL → universal idempotency path (Section 10.11).
5.  Re-validate challenges.media_object_id = p_media_object_id. Raise FK_LINKAGE_CHANGED if not.
6.  Lock all matching pending reports ORDER BY id FOR UPDATE → v_report_ids[].
7.  If p_report_id IS NOT NULL: verify ∈ v_report_ids. Raise FK_REPORT_TARGET_MISMATCH if absent.
8.  Lock media FOR UPDATE. Verify status = 'ready'. Otherwise FK_WRONG_STATE.
9.  Read sha256_hash. Raise FK_MEDIA_METADATA_INCOMPLETE if NULL.
10. INSERT moderation_actions (action_type = 'photo_removed') RETURNING id → v_action_id.
11. INSERT moderation_evidence.
12. UPDATE media_objects: status = 'removed', moderated_at = clock_timestamp().
13. UPDATE challenges per state matrix; set moderator_removal_action_id = v_action_id.  ← server-set
14. INSERT moderation_action_reports per v_report_ids[].
15. UPDATE content_reports SET status = 'actioned'.
```

### 10.11 Universal idempotency path

Entered when `moderator_removed_at IS NOT NULL` is detected after locking the target. `moderator_removal_action_id` is a durable server-controlled pointer to the original action — correct regardless of pathway (remove_content or remove_media).

```
1. v_existing_action_id := target_row.moderator_removal_action_id.
   If NULL: RAISE EXCEPTION 'FK_STATE_INCONSISTENCY: target removed but action pointer missing'.

2. Lock all new matching pending reports (same report query, ORDER BY id FOR UPDATE)
   → v_new_report_ids[].
   (For challenges: include linked media_object reports.)

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

### 10.12 `public.suspend_user`

Atomically updates `public.profiles.is_suspended` and `private.profile_suspensions`. INSERT moderation_actions `(action_type = 'user_suspended')`.

### 10.13 `public.reinstate_user`

Reverse of suspend_user. INSERT moderation_actions `(action_type = 'user_reinstated')`.

### 10.14 `public.dismiss_report`

Acquires only the report lock. INSERT moderation_actions + moderation_action_reports + UPDATE content_reports.

### 10.15 `public.action_report`

Closes a report after a separately-recorded substantive action. Requires `action_type NOT IN ('report_dismissed','report_actioned','photo_approved')`. Raises FK_INVALID_PRIOR_ACTION for non-qualifying prior actions. Raises FK_REPORT_TARGET_MISMATCH if prior action and report targets differ.

### 10.16 `public.get_media_serve_authorization`

EXECUTE granted to `service_role` only. Explicitly revoked from PUBLIC, anon, authenticated.

```sql
CREATE OR REPLACE FUNCTION public.get_media_serve_authorization(
  p_media_object_id uuid,
  p_viewer_id       uuid  -- from Edge Function verified JWT; never from request body
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

Empty set = 403. Combines authorization and key retrieval in one atomic RPC.

### 10.17 `public.get_poster_media_status`

EXECUTE granted to `service_role` only. `p_uploader_id` derived from Edge Function JWT.

```sql
CREATE OR REPLACE FUNCTION public.get_poster_media_status(
  p_media_object_id uuid,
  p_uploader_id     uuid   -- from verified JWT; never from request body
) RETURNS TABLE(status text, rejection_message text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT
    mo.status,
    CASE WHEN mo.status = 'rejected'
         THEN 'Photo couldn''t be approved — choose another photo.'
         ELSE NULL
    END
  FROM public.media_objects mo
  WHERE mo.id = p_media_object_id
    AND mo.uploader_id = p_uploader_id;   -- V1 column name; different uploader → no row
$$;
```

### 10.18 `public.get_my_reports`

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

### 10.19 Other service-role query functions

- `get_moderation_queue()`: pending reports + pending-review photos, oldest first.
- `get_pending_review_media(uuid)`: media row if status = 'pending_review'.
- `get_reported_media(uuid)`: report + linked media if status = 'pending' and media is viewable.
- `get_report_for_review(uuid)`: report row with target_summary (text for comment/clue, NULL for others).

### 10.20 Suspension-gated functions

Internal guard: `IF is_suspended THEN RAISE EXCEPTION 'FK_SUSPENDED'; END IF;`

Applies to: `activate_challenge`, `create_group`, `create_group_invite`, `redeem_group_invite`, `apply_correction`.

`transfer_group_ownership`: suspended poster permitted; recipient must be active, onboarded, `is_suspended = false`; INSERT into `group_ownership_history`.

### 10.21 SHA-256 parameter validation in `finalize_upload_session`

```sql
IF p_sha256_hash IS NULL OR p_sha256_hash !~ '^[0-9a-f]{64}$' THEN
  RAISE EXCEPTION 'FK_INVALID_HASH';
END IF;
```

---

## Part 11 — Cleanup Contracts

### 11.1 `public.claim_moderation_media_cleanup`

Claims `rejected` or `removed` media with no live pending report (covering both `target_type = 'media_object'` and challenge-level `inappropriate_image` reports). Uses `FOR UPDATE SKIP LOCKED` with 10-minute lease.

### 11.2 `public.mark_moderation_media_cleaned`

Sets `status = 'cleaned'` and clears lease. Raises `FK_WRONG_STATE` if media is not in a claimable state.

### 11.3 Cleanup worker procedure

1. Claim batch via `claim_moderation_media_cleanup`.
2. Delete storage object.
3. 200/204 or 404: call `mark_moderation_media_cleaned`.
4. Other error: log; do not mark; lease expires and row becomes re-claimable.

### 11.4 `private.cleanup_expired_evidence`

Owned by `forkensics_executor`. EXECUTE revoked from PUBLIC, anon, authenticated. EXECUTE granted to `service_role` only (grants in Part 5.6).

```sql
CREATE OR REPLACE FUNCTION private.cleanup_expired_evidence()
RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$
  DELETE FROM private.moderation_evidence WHERE retained_until < clock_timestamp();
$$;
```

Scheduled daily.

---

## Part 12 — Acceptance Test Matrix

### T1 — Comment trigger (8 tests)

| # | Action | Expected |
|---|---|---|
| T1.1 | Author changes `text` | FK_COMMENT_IMMUTABLE |
| T1.2 | Non-author any UPDATE | FK_COMMENT_IMMUTABLE |
| T1.3 | Author sets `deleted_at` (text, moderator fields unchanged) | Succeeds; deleted_at = server time |
| T1.4 | Author supplies past `deleted_at` | Overridden to server time |
| T1.5 | remove_content('comment') — forkensics_executor, all Path 1 conditions met | Succeeds; both fields set atomically |
| T1.6 | Authenticated sets moderator_removed_at directly | FK_COMMENT_IMMUTABLE |
| T1.7 | forkensics_executor: wrong placeholder text | FK_COMMENT_IMMUTABLE |
| T1.8 | forkensics_executor: moderator_removed_at already set | FK_COMMENT_IMMUTABLE |

### T2 — `can_view_challenge` baseline (6 tests)

| # | Setup | Expected |
|---|---|---|
| T2.1 | Poster's own draft | true |
| T2.2 | Non-poster, draft | false |
| T2.3 | Posted, group member, no block | true |
| T2.4 | Posted, group member, A blocks B (poster) | false |
| T2.5 | Block exists; B is eligible participant | true |
| T2.6 | Posted, non-member | false |

### T3 — Child-table block enforcement (10 tests)

T3.1–T3.7: A blocks B; B queries clues/secrets/aliases/guess_attempts/guess_judgments/eligible_participants/exclusion_events → 0 rows each.
T3.8: B is eligible participant → rows returned.
T3.9: No block → returns normally.
T3.10: Non-poster querying draft → 0 rows.

### T4 — `media-serve` authorization (8 tests)

| # | Setup | Expected |
|---|---|---|
| T4.1 | Group member, no block | Returns storage key → 200 |
| T4.2 | A blocks B (poster) | Empty → 403 |
| T4.3 | Outsider | Empty → 403 |
| T4.4 | Poster | Key → 200 |
| T4.5 | B eligible participant despite block | Key → 200 |
| T4.6 | Challenge moderator-removed | Empty → 403 |
| T4.7 | status = 'pending_review' | Empty → 403 |
| T4.8 | status = 'removed' | Empty → 403 |

### T5 — media_object report lock order (2 tests)

| # | Setup | Expected |
|---|---|---|
| T5.1 | remove_media holds challenge lock; concurrent report_content('media_object') | Blocks on challenge; after remove commits: FK_NOT_FOUND |
| T5.2 | report_content('media_object') commits first | remove_media captures and actions the report |

### T6 — Bulk report resolution + audit (7 tests)

T6.1–T6.4: Multiple reporters against same target via various pathways → all actioned, correct moderation_action_reports rows.
T6.5: Single pending report → 1 row.
T6.6: Completeness — every actioned report has exactly one moderation_action_reports row.
T6.7: One dismissed, one pending; removal runs → pending actioned; dismissed unchanged.

### T7 — Concurrency (5 tests)

T7.1: Two moderators, same challenge → one action; second idempotency path; both reports actioned.
T7.2: Concurrent dismiss + remove_content for same report → lock serializes; clean outcome.
T7.3: report_content races remove_content → FK_NOT_FOUND if remove wins; report actioned if report wins.
T7.4: Two identical report_content calls → dedup; both return same report_id.
T7.5: remove_media; poster re-uploaded between provisional read and lock → FK_LINKAGE_CHANGED.

### T8 — Idempotency (8 tests)

| # | Setup | Expected |
|---|---|---|
| T8.1 | Challenge removed; remove_content called again | Idempotency path; new reports linked via moderator_removal_action_id |
| T8.2 | After removal; new report_content attempt | FK_NOT_FOUND |
| T8.3 | remove_media on status = 'removed' | FK_WRONG_STATE |
| T8.4 | remove_media on status = 'rejected' | FK_WRONG_STATE |
| T8.5 | Comment removed; remove_content called again | Idempotency via comment.moderator_removal_action_id |
| T8.6 | Clue removed; remove_content called again | Idempotency via clue.moderator_removal_action_id |
| T8.7 | Challenge removed via remove_media; remove_content called | challenge.moderator_removal_action_id present; idempotency path links new reports |
| T8.8 | remove_content first; then remove_media | remove_media hits idempotency path |

### T9 — `p_report_id` validation (3 tests)

T9.1: Valid pending report → succeeds.
T9.2: p_report_id targets different subject → FK_REPORT_TARGET_MISMATCH.
T9.3: p_report_id = NULL → proactive; NULL in moderation_actions.report_id.

### T10 — `action_report` validation (4 tests)

T10.1: Valid substantive prior action, same subject → actioned.
T10.2: Prior = 'report_dismissed' → FK_INVALID_PRIOR_ACTION.
T10.3: Prior targets different challenge → FK_REPORT_TARGET_MISMATCH.
T10.4: No violation → use dismiss_report.

### T11 — Suspension and comment-reporting visibility (12 tests)

| # | Setup | Expected |
|---|---|---|
| T11.1 | Suspended INSERT comment | RESTRICTIVE rejects |
| T11.2 | Suspended UPDATE challenge (draft) | RESTRICTIVE rejects |
| T11.3 | Suspended redeem_group_invite | FK_SUSPENDED |
| T11.4 | Suspended cancel_challenge | Allowed |
| T11.5 | Suspended author soft-deletes own comment | Allowed (trigger Path 2) |
| T11.6 | Suspended exclusion reason='removed' | RESTRICTIVE rejects |
| T11.7 | Suspended exclusion reason='withdrew' | Allowed |
| T11.8 | Transfer to suspended recipient | Function guard rejects |
| T11.9 | Challenge poster reports a comment during active challenge | Succeeds (poster branch) |
| T11.10 | Current group member who guessed reports a comment | Succeeds |
| T11.11 | Former group member (no longer in group) attempts to report | FK_NOT_FOUND (group membership required) |
| T11.12 | Non-group-member who previously guessed | FK_NOT_FOUND (group membership required) |

### T12 — Block direction (4 tests)

| # | Setup | Expected |
|---|---|---|
| T12.1 | Viewer A blocks poster B | A cannot see B's challenges |
| T12.2 | Poster B blocks viewer A | A cannot see B's challenges (has_block_with catches reverse direction) |
| T12.3 | A queries user_blocks for rows where they are blocked_id | 0 rows (own-row policy) |
| T12.4 | A queries user_blocks for rows where they are blocker_id | Own rows returned |

### T13 — SHA-256 integrity (4 tests)

T13.1: Valid 64-char lowercase hex → stored.
T13.2: NULL → FK_INVALID_HASH.
T13.3: Uppercase → FK_INVALID_HASH.
T13.4: Pre-V2 row; sha256_hash IS NULL → FK_MEDIA_METADATA_INCOMPLETE on moderation.

### T14 — Cleanup hold (7 tests)

T14.1–T14.5: Pending report holds prevent cleanup; dismissal releases hold.
T14.6: `get_poster_media_status` with wrong `uploader_id` → no row.
T14.7: Correct `uploader_id`, status = 'rejected' → status + rejection_message.

### T15 — Clue visibility after removal (3 tests)

T15.1: `remove_content('clue')` executes → `moderator_removed_at IS NOT NULL`.
T15.2: Authenticated queries removed clue → 0 rows (RESTRICTIVE policy).
T15.3: Service role (BYPASSRLS) queries removed clue → row returned; text preserved for evidence.

### T16 — Forge protection (6 tests)

| # | Setup | Expected |
|---|---|---|
| T16.1 | INSERT challenge with moderator_removed_at populated | Force-null trigger: stored as NULL |
| T16.2 | INSERT comment with moderator_removal_action_id populated | Stored as NULL |
| T16.3 | INSERT clue with both fields populated | Both stored as NULL |
| T16.4 | Authenticated UPDATE challenge: set moderator_removed_at | FK_REMOVAL_UNAUTHORIZED |
| T16.5 | Authenticated UPDATE clue: set moderator_removal_action_id | FK_REMOVAL_UNAUTHORIZED |
| T16.6 | forkensics_executor sets moderator_removed_at; then any role changes it | FK_REMOVAL_IMMUTABLE |

### T17 — Role privilege isolation (8 tests)

| # | Setup | Expected |
|---|---|---|
| T17.1 | authenticated calls approve_photo | Permission denied |
| T17.2 | authenticated calls remove_content | Permission denied |
| T17.3 | authenticated calls get_media_serve_authorization | Permission denied |
| T17.4 | anon calls report_content | Permission denied |
| T17.5 | authenticated calls report_content (active target) | Succeeds |
| T17.6 | authenticated SELECT from content_reports | 0 rows (RLS + no permissive policy) |
| T17.7 | authenticated SELECT from user_blocks (own rows) | Own rows returned (PERMISSIVE policy) |
| T17.8 | authenticated SELECT from user_blocks (rows where they are blocked) | 0 rows (own-row policy) |

---

## Part 13 — Success Criteria

- [ ] Comment trigger: SECURITY INVOKER; Path 1 requires OLD.moderator_removal_action_id IS NULL and NEW.moderator_removal_action_id IS NOT NULL; server timestamp on moderator_removed_at; action pointer passes through; T1.x pass
- [ ] `can_view_challenge()` enforces `posted_at IS NOT NULL` for non-posters; T2.x pass
- [ ] `private.can_viewer_access_challenge(viewer_id)` defined for service-role callers
- [ ] All new public tables: RLS enabled; PUBLIC/anon/authenticated revoked; access re-granted per Part 4
- [ ] Role privilege sequence: temporary grant → ownership → table/function grants → revoke; T17.x pass
- [ ] forkensics_executor has explicit grants on all new public and private tables
- [ ] forkensics_rls_helper has SELECT on user_blocks and challenge-linked tables
- [ ] authenticated has EXECUTE on RLS helper functions and approved public functions only
- [ ] service_role has EXECUTE on service-only functions; authenticated explicitly revoked from those
- [ ] `get_media_serve_authorization`: EXECUTE to service_role only; T4.x pass
- [ ] media_object target in report_content: challenge → media lock order; T5.x pass
- [ ] report_content ON CONFLICT uses column-list inference with `WHERE status = 'pending'`
- [ ] report_content comment visibility: current group member AND (poster OR is_challenge_revealed() OR guessed); T11.9–T11.12 pass
- [ ] Removal functions: target → reports (UUID order) → media
- [ ] moderator_removal_action_id set atomically in all removal functions (remove_content challenge/comment/clue, remove_media challenge)
- [ ] Universal idempotency path reads moderator_removal_action_id; T8.5–T8.8 pass
- [ ] Consistency CHECK constraint on challenges, comments, clues (both NULL or both non-NULL)
- [ ] INSERT forge-null trigger on challenges, comments, clues; T16.1–T16.3 pass
- [ ] UPDATE guard on challenges, clues (forkensics_executor only for NULL→non-NULL; immutable once set); T16.4–T16.6 pass
- [ ] moderation_action_reports UNIQUE(report_id); T6.6 passes
- [ ] hide_blocked_challenges uses has_block_with() not direct query; T12.1–T12.2 pass
- [ ] blocks_select_own is AS PERMISSIVE; T12.3–T12.4 pass
- [ ] RESTRICTIVE SELECT on clues: moderator_removed_at IS NULL; T15.x pass
- [ ] get_poster_media_status requires uploader_id = p_uploader_id (V1 column name); T14.6–T14.7 pass
- [ ] private.cleanup_expired_evidence: owned by forkensics_executor; EXECUTE revoked from PUBLIC/anon/authenticated; EXECUTE to service_role
- [ ] Deadlock-free; T7.x pass
- [ ] redeem_group_invite internal suspension guard; T11.3 passes
- [ ] transfer_group_ownership recipient guard; group_ownership_history; T11.8 passes
- [ ] SHA-256 two-migration plan; T13.x pass
- [ ] Text-filter triggers on all UGC fields
- [ ] Cleanup hold covers both media_object and inappropriate_image report types; T14.1–T14.5 pass
- [ ] No executable SQL written until governance approval
