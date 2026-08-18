# Step 24.1 — UGC Safety and Moderation Contracts
## Final Proposal (Rev 10)

**Status:** Pending approval (Claude → Codex/GPT → Bill)
**Governance gate:** Bill must type `APPROVED: Step 24.1 — UGC Safety and Moderation Contracts` before any SQL in this document is written as executable code or applied to any environment.
**Self-contained:** This document is the complete approved contract. No prior revision (Rev 1–9) need be consulted for implementation.
**Codex Rev 9 hash:** `ebe32cf6e0cf9e09f294f27db76210141033a775112be31fe317f02571f699bc`

**Changes from Rev 9:**
1. Part 5 gains EXECUTE grants to `forkensics_executor` for RLS helpers it calls at runtime (`can_view_challenge`, `can_viewer_access_challenge`, `is_challenge_revealed`, `auth_uid`, and any additional V1 helpers). Part 5 is now explicitly ordered to execute AFTER all functions are defined.
2. `private.moderation_evidence` grant corrected to `SELECT, INSERT, DELETE` (cleanup function runs DELETE).
3. Acceptance tests T1.1, T1.2, T1.6, T16.4, T16.5, T16.6, T17.6 corrected to match actual PostgreSQL enforcement order (column-level privilege or RLS blocks before the trigger fires). T16.6 split into two sub-tests. T16.4/T16.5 guard-trigger direct testing uses a dedicated test role inside a rolled-back transaction. Test T18 added for evidence cleanup.

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
- Cleanup worker for `rejected` and `removed` media (using functions in Part 11)

### 1.4 Confirmed decisions

1. Comment placeholder: `[removed by moderator]`; evidence is audit metadata only.
2. Block on active challenge: existing eligible participants retain read-only visibility; no new interactions.
3. Moderation-action immutability: unconditional `BEFORE UPDATE OR DELETE` rejection.
4. Avatar photos: disabled in V1. No upload or moderation gate needed.
5. Text-filter trigger: `SECURITY DEFINER` (to access private schema), no caller bypass.
6. RESTRICTIVE RLS policy approach approved (except where noted as PERMISSIVE).
7. `get_my_reports()` SECURITY DEFINER RPC; direct table SELECT revoked from authenticated.
8. SHA-256 computed in re-encoding worker; stored in `private.media_storage_keys`; copied to evidence at moderation time.
9. Activation media gate: enforced inside `activate_challenge()` body while challenge row is locked.
10. `reviewed` report status removed. States: `pending`, `actioned`, `dismissed` only.
11. `challenge_secrets`: RESTRICTIVE block policy required.
12. `exclusion_events`: direct authenticated INSERT; branched RESTRICTIVE policy.
13. `apply_correction`: `SECURITY DEFINER`/`forkensics_executor` path; suspension guard inside function.
14. `action_report`: requires same-subject prior substantive action; "no violation" closures use `dismiss_report`.
15. `transfer_group_ownership` and `revoke_group_invite`: permitted for suspended users; transfer recipient must be active, onboarded, not suspended; transfer audited in `group_ownership_history`.
16. Global lock order: **content target → all matching pending reports (ascending UUID) → media**.
17. `dismiss_report` acquires only the report lock.
18. `report_content` for removable target types locks the target row before inserting.
19. Idempotency: `moderator_removal_action_id` column on challenges, comments, and clues; set atomically during first removal; universal idempotency path reuses it.
20. `redeem_group_invite` requires internal suspension guard.
21. `remove_content` and `remove_media` may be called with `p_report_id = NULL` (proactive moderation); fully audited.
22. `moderation_action_reports.report_id` unique — each resolved report has exactly one resolution link.
23. `media-serve` authorization uses `public.get_media_serve_authorization`; `p_viewer_id` from verified JWT only.
24. Ownership transfer audited in `public.group_ownership_history`.
25. Appeals: V1 — `FK_NOT_FOUND`; users use published support address.
26. All new public tables: RLS enabled; default privileges revoked; access re-granted explicitly.
27. Moderator-removed clues hidden via RESTRICTIVE SELECT policy; clue text preserved in evidence.
28. `get_poster_media_status`: `p_uploader_id` from verified JWT; query requires `uploader_id = p_uploader_id`.
29. V1 revoked postgres membership in custom roles; migration uses temporary-grant pattern.
30. `moderator_removed_at` and `moderator_removal_action_id` are server-owned; forced NULL on INSERT; only forkensics_executor may transition NULL → non-NULL; immutable once set.
31. `hide_blocked_challenges` uses `private.has_block_with(poster_id)` (bilateral). `blocks_select_own` on `user_blocks` is `AS PERMISSIVE`.
32. `report_content` comment visibility: current group member AND (poster OR `private.is_challenge_revealed()` OR guessed). No author branch.
33. `forkensics_executor` must have EXECUTE grants on all RLS-helper functions it calls at runtime. `private.moderation_evidence` grant includes DELETE.
34. Column-level privilege and RLS enforcement precede trigger execution; tests reflect actual PostgreSQL enforcement order.

---

## Part 2 — V1 Trigger Replacement

### 2.1 `public.restrict_comment_updates` — complete replacement

Trigger attachment (`BEFORE UPDATE ON public.comments FOR EACH ROW`) unchanged. `SECURITY INVOKER` so `current_user` reflects the actual caller.

```sql
CREATE OR REPLACE FUNCTION public.restrict_comment_updates()
RETURNS trigger
LANGUAGE plpgsql SECURITY INVOKER
SET search_path = ''
AS $$
BEGIN
  -- Path 1: Moderator removal — only forkensics_executor.
  -- Both moderator_removed_at and moderator_removal_action_id transition NULL → non-NULL together.
  -- The action-pointer value supplied by forkensics_executor passes through (trusted).
  -- Server overrides the timestamp to prevent clock skew.
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
    NEW.moderator_removed_at := clock_timestamp();
    RETURN NEW;
  END IF;

  -- Path 2: Author soft-delete.
  -- Both moderation fields must remain unchanged.
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
    NEW.deleted_at := clock_timestamp();
    RETURN NEW;
  END IF;

  RAISE EXCEPTION 'FK_COMMENT_IMMUTABLE: comment update not permitted';
END;
$$;
```

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
-- ON CONFLICT must use: ON CONFLICT (reporter_id, target_type, target_id, category)
--   WHERE status = 'pending' DO NOTHING
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

No direct INSERT, UPDATE, or DELETE. Use `block_user` / `unblock_user`.

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

-- Durable idempotency references — server-owned; see Part 6 for forge-protection
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

-- Media cleanup fields
ALTER TABLE public.media_objects
  ADD COLUMN IF NOT EXISTS moderated_at                     timestamptz,
  ADD COLUMN IF NOT EXISTS moderation_cleanup_leased_until  timestamptz;

-- media_objects status constraint: replace V1 CHECK with full V2 set
-- (includes 'pending_review', 'rejected', 'removed'; replace constraint by name)
```

### 3.11 `private.media_storage_keys` — SHA-256

```sql
-- V2a: nullable with format constraint
ALTER TABLE private.media_storage_keys
  ADD COLUMN IF NOT EXISTS sha256_hash text
    CONSTRAINT msk_sha256_format CHECK (sha256_hash ~ '^[0-9a-f]{64}$');

-- Verify zero NULL rows before V2b.
-- V2b: NOT NULL
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

## Part 4 — RLS Enablement and Table Privilege Grants

```sql
ALTER TABLE public.content_reports         ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_blocks             ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.moderation_actions      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.group_ownership_history ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.content_reports         FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.user_blocks             FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.moderation_actions      FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.group_ownership_history FROM PUBLIC, anon, authenticated;

-- Re-grant only intended direct access.
-- user_blocks: authenticated SELECT only, controlled by PERMISSIVE own-row policy.
GRANT SELECT ON public.user_blocks TO authenticated;

-- content_reports, moderation_actions, group_ownership_history:
-- No direct access for authenticated. Access via SECURITY DEFINER functions only.
```

---

## Part 5 — Role Ownership and Function Privilege Grants

### Migration execution order

**This part must execute AFTER all functions are created** (Parts 7, 8, 10, 11 in the implementation). The recommended migration order is:

1. Schema (Part 3: tables, columns, constraints, indexes)
2. RLS enablement and table grants (Part 4)
3. Function definitions (Parts 7, 8, 10, 11)
4. Trigger attachments (Parts 6.2, 6.3, 8.2)
5. **Role ownership and function grants (this Part 5)**
6. RLS policy creation (Parts 9)

### 5.1 Temporary role grant (open)

```sql
GRANT forkensics_executor   TO postgres;
GRANT forkensics_rls_helper TO postgres;
```

### 5.2 Function ownership

```sql
-- RLS helper functions → forkensics_rls_helper
ALTER FUNCTION private.can_view_challenge(uuid)               OWNER TO forkensics_rls_helper;
ALTER FUNCTION private.can_viewer_access_challenge(uuid,uuid)  OWNER TO forkensics_rls_helper;
ALTER FUNCTION private.has_block_with(uuid)                   OWNER TO forkensics_rls_helper;
ALTER FUNCTION private.has_block_with_poster(uuid)            OWNER TO forkensics_rls_helper;

-- Trigger functions → forkensics_executor
ALTER FUNCTION private.check_text_content_trigger()           OWNER TO forkensics_executor;
ALTER FUNCTION public.restrict_comment_updates()              OWNER TO forkensics_executor;
ALTER FUNCTION private.force_removal_fields_null()            OWNER TO forkensics_executor;
ALTER FUNCTION private.restrict_moderation_field_updates()    OWNER TO forkensics_executor;

-- SECURITY DEFINER public functions → forkensics_executor
ALTER FUNCTION public.check_text_content(text)                OWNER TO forkensics_executor;
ALTER FUNCTION public.report_content(text,uuid,text,text)     OWNER TO forkensics_executor;
ALTER FUNCTION public.block_user(uuid)                        OWNER TO forkensics_executor;
ALTER FUNCTION public.unblock_user(uuid)                      OWNER TO forkensics_executor;
ALTER FUNCTION public.approve_photo(uuid,uuid,text)           OWNER TO forkensics_executor;
ALTER FUNCTION public.reject_photo(uuid,uuid,text)            OWNER TO forkensics_executor;
ALTER FUNCTION public.remove_content(text,uuid,uuid,uuid,text) OWNER TO forkensics_executor;
ALTER FUNCTION public.remove_media(uuid,uuid,uuid,text)       OWNER TO forkensics_executor;
ALTER FUNCTION public.suspend_user(uuid,uuid,text)            OWNER TO forkensics_executor;
ALTER FUNCTION public.reinstate_user(uuid,uuid,text)          OWNER TO forkensics_executor;
ALTER FUNCTION public.dismiss_report(uuid,uuid,text)          OWNER TO forkensics_executor;
ALTER FUNCTION public.action_report(uuid,uuid,uuid,text)      OWNER TO forkensics_executor;
ALTER FUNCTION public.get_media_serve_authorization(uuid,uuid) OWNER TO forkensics_executor;
ALTER FUNCTION public.get_moderation_queue()                  OWNER TO forkensics_executor;
ALTER FUNCTION public.get_pending_review_media(uuid)          OWNER TO forkensics_executor;
ALTER FUNCTION public.get_reported_media(uuid)                OWNER TO forkensics_executor;
ALTER FUNCTION public.get_poster_media_status(uuid,uuid)      OWNER TO forkensics_executor;
ALTER FUNCTION public.get_my_reports()                        OWNER TO forkensics_executor;
ALTER FUNCTION public.get_report_for_review(uuid)             OWNER TO forkensics_executor;
ALTER FUNCTION public.claim_moderation_media_cleanup(int)     OWNER TO forkensics_executor;
ALTER FUNCTION public.mark_moderation_media_cleaned(uuid)     OWNER TO forkensics_executor;
ALTER FUNCTION private.cleanup_expired_evidence()             OWNER TO forkensics_executor;
```

### 5.3 Table access grants for `forkensics_executor`

```sql
-- New public tables
GRANT SELECT, INSERT, UPDATE ON public.content_reports         TO forkensics_executor;
GRANT SELECT, INSERT, DELETE ON public.user_blocks             TO forkensics_executor;
GRANT SELECT, INSERT         ON public.moderation_actions      TO forkensics_executor;
GRANT SELECT, INSERT         ON public.group_ownership_history TO forkensics_executor;

-- Existing public tables — new columns (additive; V1 table-level grants remain)
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
GRANT SELECT, INSERT, UPDATE, DELETE ON private.blocked_terms           TO forkensics_executor;
GRANT SELECT, INSERT                 ON private.moderators              TO forkensics_executor;
GRANT SELECT, INSERT, UPDATE         ON private.profile_suspensions     TO forkensics_executor;
GRANT SELECT, INSERT, DELETE         ON private.moderation_evidence     TO forkensics_executor;
-- DELETE required by private.cleanup_expired_evidence()
GRANT SELECT, INSERT                 ON private.moderation_action_reports TO forkensics_executor;
GRANT SELECT, UPDATE (sha256_hash, re_encoded_storage_key)
  ON private.media_storage_keys TO forkensics_executor;
```

### 5.4 Table access grants for `forkensics_rls_helper`

```sql
GRANT SELECT ON public.user_blocks           TO forkensics_rls_helper;
GRANT SELECT ON public.challenges            TO forkensics_rls_helper;
GRANT SELECT ON public.group_members         TO forkensics_rls_helper;
GRANT SELECT ON public.eligible_participants TO forkensics_rls_helper;
GRANT SELECT ON public.profiles              TO forkensics_rls_helper;
```

### 5.5 EXECUTE grants on helper functions

**To `authenticated` (for RLS policy evaluation):**

```sql
GRANT EXECUTE ON FUNCTION private.can_view_challenge(uuid)        TO authenticated;
GRANT EXECUTE ON FUNCTION private.has_block_with(uuid)            TO authenticated;
GRANT EXECUTE ON FUNCTION private.has_block_with_poster(uuid)     TO authenticated;
```

**To `forkensics_executor` (called at runtime inside executor-owned SECURITY DEFINER functions):**

```sql
-- V2 helpers
GRANT EXECUTE ON FUNCTION private.can_view_challenge(uuid)             TO forkensics_executor;
GRANT EXECUTE ON FUNCTION private.can_viewer_access_challenge(uuid,uuid) TO forkensics_executor;

-- V1 helpers called by executor-owned functions (non-exhaustive; audit all call sites)
GRANT EXECUTE ON FUNCTION private.auth_uid()                           TO forkensics_executor;
GRANT EXECUTE ON FUNCTION private.is_challenge_revealed(uuid)          TO forkensics_executor;
-- Add any additional V1 SECURITY DEFINER helpers called from:
--   report_content, remove_content, remove_media, finalize_upload_session,
--   activate_challenge, redeem_group_invite, apply_correction, etc.
-- Pattern: grep executor-owned function bodies for private.* calls; grant each.
```

**To `service_role` (for `can_viewer_access_challenge`, not an authenticated RLS helper):**

```sql
GRANT EXECUTE ON FUNCTION private.can_viewer_access_challenge(uuid,uuid) TO service_role;
```

### 5.6 EXECUTE grants on public functions

```sql
-- authenticated callers
GRANT EXECUTE ON FUNCTION public.report_content(text,uuid,text,text)  TO authenticated;
GRANT EXECUTE ON FUNCTION public.block_user(uuid)                     TO authenticated;
GRANT EXECUTE ON FUNCTION public.unblock_user(uuid)                   TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_my_reports()                     TO authenticated;
REVOKE EXECUTE ON FUNCTION public.report_content(text,uuid,text,text) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.block_user(uuid)                    FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.unblock_user(uuid)                  FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.get_my_reports()                    FROM PUBLIC, anon;

-- service_role only
GRANT EXECUTE ON FUNCTION public.check_text_content(text)                FROM service_role;
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
REVOKE forkensics_executor   FROM postgres;
REVOKE forkensics_rls_helper FROM postgres;
```

---

## Part 6 — Forge-Protection Triggers

### 6.1 INSERT forge-nulling function

Forces both server-owned fields to NULL on every INSERT.

```sql
CREATE OR REPLACE FUNCTION private.force_removal_fields_null()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  NEW.moderator_removed_at        := NULL;
  NEW.moderator_removal_action_id := NULL;
  RETURN NEW;
END;
$$;
```

### 6.2 INSERT trigger attachments

```sql
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

### 6.3 UPDATE guard for challenges and clues

`SECURITY INVOKER` — `current_user` is the actual caller.

```sql
CREATE OR REPLACE FUNCTION private.restrict_moderation_field_updates()
RETURNS trigger LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
BEGIN
  -- Once either field is set, both are immutable for all callers
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

For `public.comments`: the same protection is embedded in `restrict_comment_updates` — Path 1 explicitly validates old/new states for both fields; all other paths assert `IS NOT DISTINCT FROM` on both fields.

---

## Part 7 — RLS Helper Functions

All: owned by `forkensics_rls_helper`, `SECURITY DEFINER`, `SET search_path = ''`, `STABLE`.

### 7.1 `private.can_view_challenge(p_challenge_id uuid) → boolean`

For RLS policies (auth_uid() is the viewer).

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

For service-role callers.

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

SECURITY DEFINER — sees both block directions.

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

All policies on existing V1 tables: `AS RESTRICTIVE`. Policies on new tables with no V1 permissive baseline: `AS PERMISSIVE` where required.

### 9.1 Suspension enforcement (RESTRICTIVE on existing tables)

Predicate: `NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = private.auth_uid() AND is_suspended = true)`.

Applies to: comments (INSERT), clues (INSERT), reactions (INSERT), guess_attempts (INSERT), challenges (INSERT + UPDATE), challenge_secrets (INSERT + UPDATE), challenge_answer_aliases (INSERT + UPDATE), group_members (INSERT), profiles (UPDATE), groups (INSERT + UPDATE).

### 9.2 `exclusion_events` — branched suspension (RESTRICTIVE)

```sql
CREATE POLICY suspend_exclusion_insert AS RESTRICTIVE ON public.exclusion_events
  FOR INSERT TO authenticated
  WITH CHECK (
    NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = private.auth_uid() AND is_suspended = true)
    OR (reason = 'withdrew' AND player_id = private.auth_uid())
  );
```

### 9.3 Block enforcement — INSERT (RESTRICTIVE on existing tables)

```sql
CREATE POLICY enforce_no_block_guess    AS RESTRICTIVE ON public.guess_attempts
  FOR INSERT TO authenticated WITH CHECK (NOT private.has_block_with_poster(challenge_id));
CREATE POLICY enforce_no_block_comment  AS RESTRICTIVE ON public.comments
  FOR INSERT TO authenticated WITH CHECK (NOT private.has_block_with_poster(challenge_id));
CREATE POLICY enforce_no_block_reaction AS RESTRICTIVE ON public.reactions
  FOR INSERT TO authenticated WITH CHECK (NOT private.has_block_with_poster(challenge_id));
```

### 9.4 Block enforcement — SELECT (RESTRICTIVE on existing tables)

```sql
-- Uses has_block_with() — SECURITY DEFINER, sees both directions.
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

CREATE POLICY block_aware_comment_visibility AS RESTRICTIVE ON public.comments
  FOR SELECT TO authenticated
  USING (
    private.can_view_challenge(challenge_id)
    AND NOT private.has_block_with(author_id)
  );

CREATE POLICY block_aware_reaction_visibility AS RESTRICTIVE ON public.reactions
  FOR SELECT TO authenticated
  USING (
    private.can_view_challenge(challenge_id)
    AND NOT private.has_block_with(player_id)
  );
```

### 9.5 Moderator-removed clues — hidden (RESTRICTIVE on existing table)

```sql
CREATE POLICY hide_removed_clues AS RESTRICTIVE ON public.clues
  FOR SELECT TO authenticated
  USING (moderator_removed_at IS NULL);
```

### 9.6 Block-aware visibility on challenge-linked child tables (RESTRICTIVE on existing tables)

Applies to: `clues`, `challenge_secrets`, `challenge_answer_aliases`, `guess_attempts`, `guess_judgments`, `score_runs`, `score_events`, `correction_events`, `eligible_participants`, `exclusion_events`.

```sql
-- Template: CREATE POLICY block_aware_visibility AS RESTRICTIVE ON public.<table>
--   FOR SELECT TO authenticated USING (private.can_view_challenge(<challenge_fk>));
```

### 9.7 `user_blocks` SELECT policy (PERMISSIVE — new table, no V1 baseline)

```sql
-- PERMISSIVE is required. A new table with only RESTRICTIVE policies returns no rows.
CREATE POLICY blocks_select_own AS PERMISSIVE ON public.user_blocks
  FOR SELECT TO authenticated
  USING (blocker_id = private.auth_uid());
```

No INSERT, UPDATE, or DELETE policies. All mutations via functions.

---

## Part 10 — SECURITY DEFINER Functions

All owned by `forkensics_executor`, `SET search_path = ''`.

### 10.1 Moderator identity validation (internal)

```sql
IF NOT EXISTS (
  SELECT 1 FROM private.moderators m
  JOIN public.profiles p ON p.id = m.profile_id
  WHERE m.profile_id = p_moderator_id AND p.is_active = true
) THEN RAISE EXCEPTION 'FK_UNAUTHORIZED'; END IF;
```

### 10.2 `public.report_content`

EXECUTE granted to `authenticated`.

```
public.report_content(p_target_type text, p_target_id uuid,
                       p_category text, p_detail text) → TABLE(report_id uuid)
```

1. Verify caller active, onboarded. Suspended callers may report.
2. Validate target_type and category.
3. Rate limit: fewer than 10 pending reports in the past hour.
4. Lock and recheck target:

   *`'challenge'`:* Lock `FOR UPDATE`. Verify `can_view_challenge`. Verify `moderator_removed_at IS NULL`.

   *`'comment'`:* Lock `FOR UPDATE`. Verify `moderator_removed_at IS NULL`. Verify Table Talk visibility per V1 contract:
   - Read challenge (poster_id, group_id).
   - Current group member required: `EXISTS (SELECT 1 FROM group_members WHERE group_id = c.group_id AND player_id = auth_uid())`. If not → FK_NOT_FOUND.
   - Then at least one of: `c.poster_id = auth_uid()` OR `private.is_challenge_revealed(challenge_id)` OR `EXISTS (SELECT 1 FROM guess_attempts WHERE challenge_id = ... AND player_id = auth_uid())`. If none → FK_NOT_FOUND.
   - "Caller is comment author" not checked — self-reports rejected at step 5.

   *`'clue'`:* Lock `FOR UPDATE`. Verify `moderator_removed_at IS NULL`. Verify `can_view_challenge`.

   *`'media_object'`:* Six-step challenge-first lock (matches remove_media order):
   a. Provisional challenge read.
   b. Lock challenge `FOR UPDATE`.
   c. Re-verify `challenges.media_object_id = p_target_id`.
   d. Re-check `can_view_challenge`.
   e. Lock media `FOR UPDATE`.
   f. Verify `status = 'ready'`.

   *`'profile'`:* Verify target active; caller shares a group; no row lock.

   FK_NOT_FOUND for nonexistent, unauthorized, already-actioned targets.

5. Prevent self-report.
6. Insert:
   ```sql
   INSERT INTO public.content_reports (reporter_id, target_type, target_id, category, detail)
   VALUES (private.auth_uid(), p_target_type, p_target_id, p_category, p_detail)
   ON CONFLICT (reporter_id, target_type, target_id, category)
   WHERE status = 'pending'
   DO NOTHING
   RETURNING id INTO v_report_id;

   IF v_report_id IS NULL THEN
     SELECT id INTO v_report_id FROM public.content_reports
     WHERE reporter_id = private.auth_uid()
       AND target_type = p_target_type AND target_id = p_target_id
       AND category = p_category AND status = 'pending';
   END IF;
   ```
7. Return report_id.

### 10.3 `public.block_user` / `public.unblock_user`

block_user: idempotent INSERT. unblock_user: idempotent DELETE. Both suspended-permitted.

### 10.4 `public.approve_photo`

Lock media `FOR UPDATE`. Verify `status = 'pending_review'`. INSERT action `'photo_approved'`. UPDATE status → `'ready'`.

### 10.5 `public.reject_photo`

Lock media. Verify `'pending_review'`. Read sha256_hash (FK_MEDIA_METADATA_INCOMPLETE if NULL). INSERT action `'photo_rejected'`. INSERT evidence. UPDATE status → `'rejected'`.

### 10.6 `public.remove_content`

`p_report_id` nullable. Lock order: target → reports (UUID) → media.

**`'challenge'`:** Lock challenge + idempotency check → validate state → lock reports → validate p_report_id if non-NULL → lock media → validate media → read sha256_hash → INSERT action → INSERT evidence → UPDATE challenge (state, moderator_removed_at, moderator_removal_action_id) → UPDATE media → INSERT moderation_action_reports → UPDATE content_reports actioned.

**`'comment'`:** Lock comment + idempotency check → lock reports → validate p_report_id → INSERT action → INSERT evidence (original text) → UPDATE comment (placeholder, moderator_removed_at, moderator_removal_action_id) → INSERT moderation_action_reports → UPDATE content_reports.

**`'clue'`:** Lock clue + idempotency check → lock reports → validate p_report_id → INSERT action → INSERT evidence (clue text) → UPDATE clue (moderator_removed_at, moderator_removal_action_id; text preserved) → INSERT moderation_action_reports → UPDATE content_reports.

### 10.6a State matrix

**Challenge:**

| State | Outcome |
|---|---|
| `draft`, `active`, `locked` | state → `cancelled`, `cancellation_reason = 'moderation_action'`, `moderator_removed_at = clock_timestamp()` |
| `revealed` | state unchanged; `moderator_removed_at = clock_timestamp()` |
| `cancelled` | `moderator_removed_at = clock_timestamp()` if not set |

**Media:**

| Status | Action |
|---|---|
| `ready`, `pending_review`, `rejected`, `superseded` | `status = 'removed'`, `moderated_at = clock_timestamp()` |
| `removed`, `cleaned` | Skip UPDATE |
| `processing`, `failed` | FK_WRONG_STATE; abort |

### 10.7 `public.remove_media`

`p_report_id` nullable. Provisional challenge read → lock challenge + idempotency check → re-validate linkage → lock reports → validate p_report_id → lock media (verify `'ready'`) → read sha256_hash → INSERT action `'photo_removed'` → INSERT evidence → UPDATE media → UPDATE challenge (state matrix + moderator_removal_action_id) → INSERT moderation_action_reports → UPDATE content_reports.

### 10.8 Universal idempotency path

Entered when `moderator_removed_at IS NOT NULL` after locking the target.

```
1. v_existing_action_id := target_row.moderator_removal_action_id.
   If NULL → RAISE EXCEPTION 'FK_STATE_INCONSISTENCY'.

2. Lock new pending reports → v_new_report_ids[].

3. INSERT INTO private.moderation_action_reports (moderation_action_id, report_id)
   SELECT v_existing_action_id, id FROM unnest(v_new_report_ids) AS id
   ON CONFLICT ON CONSTRAINT moderation_action_reports_one_resolution DO NOTHING.

4. Verify no newly-discovered report is linked to a different action.
   If found → RAISE EXCEPTION 'FK_RESOLUTION_CONFLICT'.

5. UPDATE content_reports actioned WHERE id = ANY(v_new_report_ids).

6. Return. (No new moderation_actions or moderation_evidence.)
```

### 10.9 `public.suspend_user` / `public.reinstate_user`

Atomically update `public.profiles.is_suspended` and `private.profile_suspensions`. INSERT moderation_actions.

### 10.10 `public.dismiss_report`

Report lock only. INSERT moderation_actions + moderation_action_reports. UPDATE content_reports `'dismissed'`.

### 10.11 `public.action_report`

Requires substantive prior action (not `'report_dismissed'`, `'report_actioned'`, `'photo_approved'`). Verifies prior action and report share subject. INSERT moderation_actions + moderation_action_reports. UPDATE content_reports `'actioned'`.

### 10.12 `public.get_media_serve_authorization`

```sql
CREATE OR REPLACE FUNCTION public.get_media_serve_authorization(
  p_media_object_id uuid,
  p_viewer_id       uuid   -- from Edge Function verified JWT only
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

Empty set = 403.

### 10.13 `public.get_poster_media_status`

```sql
CREATE OR REPLACE FUNCTION public.get_poster_media_status(
  p_media_object_id uuid,
  p_uploader_id     uuid   -- from verified JWT only
) RETURNS TABLE(status text, rejection_message text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT
    mo.status,
    CASE WHEN mo.status = 'rejected'
         THEN 'Photo couldn''t be approved — choose another photo.'
         ELSE NULL END
  FROM public.media_objects mo
  WHERE mo.id = p_media_object_id
    AND mo.uploader_id = p_uploader_id;   -- V1 column name; wrong uploader → no row
$$;
```

### 10.14 `public.get_my_reports`

SECURITY DEFINER. Returns caller's own reports excluding `reviewed_by`. EXECUTE granted to `authenticated`.

### 10.15 Other service-role query functions

- `get_moderation_queue()`: pending reports + pending-review photos.
- `get_pending_review_media(uuid)`: row if status = 'pending_review'.
- `get_reported_media(uuid)`: report + media if reviewable.
- `get_report_for_review(uuid)`: report row with target_summary.

### 10.16 Suspension-gated functions

Guard: `IF is_suspended THEN RAISE EXCEPTION 'FK_SUSPENDED'; END IF;`

Applies to: `activate_challenge`, `create_group`, `create_group_invite`, `redeem_group_invite`, `apply_correction`.

`transfer_group_ownership`: recipient must be active, onboarded, `is_suspended = false`. INSERT into `group_ownership_history`.

### 10.17 SHA-256 validation in `finalize_upload_session`

```sql
IF p_sha256_hash IS NULL OR p_sha256_hash !~ '^[0-9a-f]{64}$' THEN
  RAISE EXCEPTION 'FK_INVALID_HASH';
END IF;
```

---

## Part 11 — Cleanup Contracts

### 11.1 `public.claim_moderation_media_cleanup`

Claims `rejected` or `removed` media with no live pending report (including challenge-level `inappropriate_image` reports). `FOR UPDATE SKIP LOCKED`; 10-minute lease.

### 11.2 `public.mark_moderation_media_cleaned`

Sets `status = 'cleaned'`; clears lease. FK_WRONG_STATE if not claimable.

### 11.3 Cleanup worker

Claim → delete storage → 200/204 or 404: mark cleaned; other errors: log, let lease expire.

### 11.4 `private.cleanup_expired_evidence`

```sql
CREATE OR REPLACE FUNCTION private.cleanup_expired_evidence()
RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$
  DELETE FROM private.moderation_evidence WHERE retained_until < clock_timestamp();
$$;
```

Owner: `forkensics_executor`. EXECUTE: `service_role` only (per Part 5.6). Scheduled daily.

---

## Part 12 — Acceptance Test Matrix

### Note on enforcement order

PostgreSQL evaluates in this order: **privilege check → RLS → triggers**. Tests reflect this:
- If the calling role lacks column-level UPDATE privilege, the result is `insufficient_privilege`. The trigger never fires.
- If the calling role has table-level UPDATE but the row is blocked by RLS, the result is 0 rows updated. No exception.
- Trigger exceptions (`FK_COMMENT_IMMUTABLE`, `FK_REMOVAL_IMMUTABLE`, etc.) are only reachable by a role that has both the required privilege and passes RLS.
- To test trigger behavior in isolation (e.g., T16.4/T16.5), grant a dedicated test role the required column privilege inside a rolled-back transaction.

### T1 — Comment trigger

| # | Action | Enforcement layer | Expected |
|---|---|---|---|
| T1.1 | Authenticated author changes `text` | Column privilege | `insufficient_privilege` (authenticated lacks UPDATE on `text` column) |
| T1.2 | Non-author attempts UPDATE on `deleted_at` | RLS | 0 rows updated (non-author row not visible to UPDATE) |
| T1.3 | Author sets `deleted_at` (all other fields unchanged) | Trigger Path 2 | Succeeds; `deleted_at` = server time |
| T1.4 | Author supplies past `deleted_at` | Trigger Path 2 | Overridden to server time |
| T1.5 | `remove_content('comment')` via forkensics_executor | Trigger Path 1 | Succeeds; both moderator fields set atomically |
| T1.6 | Authenticated sets `moderator_removed_at` directly | Column privilege | `insufficient_privilege` |
| T1.7 | forkensics_executor: wrong placeholder text | Trigger | FK_COMMENT_IMMUTABLE |
| T1.8 | forkensics_executor: `moderator_removed_at` already set | Trigger | FK_COMMENT_IMMUTABLE |

### T2 — `can_view_challenge` baseline (6 tests)

T2.1: Poster's own draft → true.
T2.2: Non-poster, draft → false.
T2.3: Posted, group member, no block → true.
T2.4: Posted, group member, A blocks B (poster) → false.
T2.5: Block exists; B is eligible participant → true.
T2.6: Posted, non-member → false.

### T3 — Child-table block enforcement (10 tests)

T3.1–T3.7: A blocks B; B queries clues/secrets/aliases/guess_attempts/guess_judgments/eligible_participants/exclusion_events → 0 rows each.
T3.8: B is eligible participant → rows returned.
T3.9: No block → normal.
T3.10: Non-poster querying draft → 0 rows.

### T4 — `media-serve` authorization (8 tests)

T4.1: Group member, no block → key → 200.
T4.2: A blocks B (poster) → empty → 403.
T4.3: Outsider → empty → 403.
T4.4: Poster → key → 200.
T4.5: B eligible participant despite block → key → 200.
T4.6: Challenge moderator-removed → empty → 403.
T4.7: status = 'pending_review' → empty → 403.
T4.8: status = 'removed' → empty → 403.

### T5 — media_object report lock order (2 tests)

T5.1: remove_media holds challenge lock; concurrent report_content('media_object') → blocks on challenge; after commit → FK_NOT_FOUND.
T5.2: report_content commits first → remove_media captures and actions the report.

### T6 — Bulk report resolution (7 tests)

T6.1–T6.4: Multiple reporters, various pathways → all actioned, correct moderation_action_reports rows.
T6.5: Single report → 1 row.
T6.6: Every actioned report has exactly one moderation_action_reports row.
T6.7: One dismissed, one pending; removal → pending actioned; dismissed unchanged.

### T7 — Concurrency (5 tests)

T7.1: Two moderators, same challenge → one action; second idempotency path; both reports actioned.
T7.2: Concurrent dismiss + remove_content → clean serialized outcome.
T7.3: report_content races remove_content → FK_NOT_FOUND or actioned, never stranded.
T7.4: Two identical report_content calls → dedup; same report_id.
T7.5: remove_media; poster re-uploaded between provisional read and lock → FK_LINKAGE_CHANGED.

### T8 — Idempotency (8 tests)

T8.1: Challenge removed; remove_content again → idempotency path; new reports linked.
T8.2: After removal; new report_content → FK_NOT_FOUND.
T8.3: remove_media on status = 'removed' → FK_WRONG_STATE.
T8.4: remove_media on status = 'rejected' → FK_WRONG_STATE.
T8.5: Comment removed; remove_content again → idempotency via comment.moderator_removal_action_id.
T8.6: Clue removed; remove_content again → idempotency via clue.moderator_removal_action_id.
T8.7: Challenge removed via remove_media; remove_content called → idempotency path; new reports linked to photo_removed action.
T8.8: remove_content first; then remove_media → remove_media hits idempotency path.

### T9 — `p_report_id` validation (3 tests)

T9.1: Valid pending report → succeeds; moderation_actions.report_id = p_report_id.
T9.2: p_report_id targets different subject → FK_REPORT_TARGET_MISMATCH.
T9.3: p_report_id = NULL → proactive; NULL moderation_actions.report_id.

### T10 — `action_report` (4 tests)

T10.1: Valid substantive prior action, same subject → actioned.
T10.2: Prior = 'report_dismissed' → FK_INVALID_PRIOR_ACTION.
T10.3: Prior targets different challenge → FK_REPORT_TARGET_MISMATCH.
T10.4: No violation → use dismiss_report.

### T11 — Suspension and comment-reporting visibility (12 tests)

T11.1: Suspended INSERT comment → RESTRICTIVE rejects.
T11.2: Suspended UPDATE challenge → RESTRICTIVE rejects.
T11.3: Suspended redeem_group_invite → FK_SUSPENDED.
T11.4: Suspended cancel_challenge → allowed.
T11.5: Suspended author soft-deletes own comment → allowed (trigger Path 2).
T11.6: Suspended exclusion reason='removed' → RESTRICTIVE rejects.
T11.7: Suspended exclusion reason='withdrew' → allowed.
T11.8: Transfer to suspended recipient → function guard rejects.
T11.9: Poster reports comment on active challenge → succeeds (poster branch).
T11.10: Current group member who guessed reports comment → succeeds.
T11.11: Former group member (no longer in group) attempts to report → FK_NOT_FOUND.
T11.12: Non-member who previously guessed → FK_NOT_FOUND.

### T12 — Block direction (4 tests)

T12.1: Viewer A blocks poster B → A cannot see B's challenges (viewer-blocks-poster direction).
T12.2: Poster B blocks viewer A → A cannot see B's challenges (poster-blocks-viewer direction; has_block_with catches this).
T12.3: A queries user_blocks for rows where they are blocked_id → 0 rows.
T12.4: A queries user_blocks for rows where they are blocker_id → own rows returned.

### T13 — SHA-256 integrity (4 tests)

T13.1: Valid 64-char lowercase hex → stored.
T13.2: NULL → FK_INVALID_HASH.
T13.3: Uppercase hex → FK_INVALID_HASH.
T13.4: Pre-V2 row sha256_hash IS NULL → FK_MEDIA_METADATA_INCOMPLETE on moderation.

### T14 — Cleanup hold (7 tests)

T14.1–T14.5: Pending reports hold media; dismissal releases hold (both media_object and inappropriate_image report types).
T14.6: `get_poster_media_status` with wrong uploader_id → no row.
T14.7: Correct uploader_id, status = 'rejected' → status + rejection_message.

### T15 — Clue visibility after removal (3 tests)

T15.1: remove_content('clue') → moderator_removed_at IS NOT NULL.
T15.2: Authenticated queries removed clue → 0 rows (RESTRICTIVE policy).
T15.3: Service role (BYPASSRLS) → row returned; text preserved.

### T16 — Forge protection

| # | Enforcement layer | Expected |
|---|---|---|
| T16.1 | INSERT challenge with moderator_removed_at populated | INSERT forge-null trigger | Stored as NULL |
| T16.2 | INSERT comment with moderator_removal_action_id populated | INSERT forge-null trigger | Stored as NULL |
| T16.3 | INSERT clue with both fields populated | INSERT forge-null trigger | Both stored as NULL |
| T16.4 | Authenticated UPDATE challenge.moderator_removed_at (using dedicated test role granted that column inside rolled-back txn) | UPDATE guard trigger | FK_REMOVAL_UNAUTHORIZED |
| T16.5 | Same for clue.moderator_removal_action_id | UPDATE guard trigger | FK_REMOVAL_UNAUTHORIZED |
| T16.6a | forkensics_executor sets only moderator_removed_at (not the action_id, or vice versa) | CHECK constraint | check constraint violation |
| T16.6b | After valid dual-field removal, any role attempts to change moderator_removed_at | UPDATE guard trigger | FK_REMOVAL_IMMUTABLE |

### T17 — Role privilege isolation (8 tests)

| # | Action | Expected |
|---|---|---|
| T17.1 | authenticated calls approve_photo | `insufficient_privilege` |
| T17.2 | authenticated calls remove_content | `insufficient_privilege` |
| T17.3 | authenticated calls get_media_serve_authorization | `insufficient_privilege` |
| T17.4 | anon calls report_content | `insufficient_privilege` |
| T17.5 | authenticated calls report_content (active target) | Succeeds |
| T17.6 | authenticated SELECT from content_reports | `insufficient_privilege` (no SELECT grant on table) |
| T17.7 | authenticated SELECT from user_blocks (own rows) | Own rows returned |
| T17.8 | authenticated SELECT from user_blocks (rows where they are blocked) | 0 rows |

### T18 — Evidence cleanup (2 tests)

| # | Setup | Expected |
|---|---|---|
| T18.1 | Two evidence rows: one expired (retained_until in past), one unexpired; service_role calls cleanup_expired_evidence() | Expired row deleted; unexpired row retained |
| T18.2 | authenticated calls cleanup_expired_evidence() | `insufficient_privilege` |

---

## Part 13 — Success Criteria

- [ ] Comment trigger: SECURITY INVOKER; Path 1 validates OLD.moderator_removal_action_id IS NULL and NEW.moderator_removal_action_id IS NOT NULL; T1.x pass with correct enforcement-layer expectations
- [ ] can_view_challenge enforces posted_at IS NOT NULL for non-posters; T2.x pass
- [ ] private.can_viewer_access_challenge defined for service-role callers
- [ ] All new public tables: RLS enabled; privileges revoked; re-granted per Part 4
- [ ] Migration execution order: schema → functions → triggers → Part 5 grants → RLS policies
- [ ] forkensics_executor has EXECUTE on can_view_challenge, can_viewer_access_challenge, auth_uid, is_challenge_revealed, and all other V1 helpers called at runtime; T17.5 passes end-to-end
- [ ] forkensics_executor has SELECT, INSERT, DELETE on private.moderation_evidence; T18.x pass
- [ ] forkensics_rls_helper has SELECT on user_blocks and challenge-linked tables
- [ ] authenticated has EXECUTE on RLS helpers and approved public functions only; T17.1–T17.4 pass
- [ ] service_role has EXECUTE on service-only functions; authenticated explicitly revoked; T17.1–T17.3 pass
- [ ] get_media_serve_authorization: EXECUTE to service_role only; T4.x pass
- [ ] media_object target in report_content: challenge → media lock order; T5.x pass
- [ ] report_content ON CONFLICT uses column-list inference with WHERE status = 'pending'
- [ ] report_content comment visibility: current group member AND (poster OR is_challenge_revealed() OR guessed); T11.9–T11.12 pass
- [ ] Removal functions: target → reports (UUID order) → media
- [ ] moderator_removal_action_id set atomically in all removal functions; T8.5–T8.8 pass
- [ ] Universal idempotency path reads moderator_removal_action_id; correct for all pathways
- [ ] Consistency CHECK on challenges, comments, clues; T16.6a passes
- [ ] INSERT forge-null triggers on challenges, comments, clues; T16.1–T16.3 pass
- [ ] UPDATE guard on challenges and clues; T16.4–T16.5 (tested via dedicated test role in rolled-back txn)
- [ ] T16.6b: immutability after first removal verified
- [ ] moderation_action_reports UNIQUE(report_id); T6.6 passes
- [ ] hide_blocked_challenges uses has_block_with(); T12.1–T12.2 pass (both directions)
- [ ] blocks_select_own is AS PERMISSIVE; T12.3–T12.4 pass
- [ ] RESTRICTIVE SELECT on clues: moderator_removed_at IS NULL; T15.x pass
- [ ] get_poster_media_status requires uploader_id = p_uploader_id (V1 column name); T14.6–T14.7 pass
- [ ] private.cleanup_expired_evidence: owned by forkensics_executor; EXECUTE to service_role only; T18.x pass
- [ ] Deadlock-free; T7.x pass
- [ ] redeem_group_invite internal suspension guard; T11.3 passes
- [ ] transfer_group_ownership recipient guard; group_ownership_history insert; T11.8 passes
- [ ] SHA-256 two-migration plan; T13.x pass
- [ ] Text-filter triggers on all UGC fields
- [ ] Cleanup hold covers both media_object and inappropriate_image report types; T14.1–T14.5 pass
- [ ] No executable SQL written until governance approval
