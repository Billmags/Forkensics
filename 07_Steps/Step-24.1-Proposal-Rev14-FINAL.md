# Step 24.1 — UGC Safety and Moderation Contracts
## Final Proposal (Rev 15)

**Status:** Pending approval (Claude → Codex/GPT → Bill)
**Governance gate:** Bill must type `APPROVED: Step 24.1 — UGC Safety and Moderation Contracts` before any SQL in this document is written as executable code or applied to any environment.
**Self-contained:** This document is the complete approved contract. No prior revision (Rev 1–14) need be consulted for implementation.
**Codex Rev 10 hash:** `d5117dc69273a231c844fe0911eda4e8d06870e066cee8d328cae8741e155f10`

**Changes from Rev 14:**
1. `transfer_group_ownership` steps 5 and 6 corrected: `current_owner_id` → `v_current_owner_id` throughout (must match the variable declared and populated in step 2).
2. `DECLARE v_current_owner_id uuid;` added explicitly to the function pseudocode so the declaration is unambiguous.

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
- `activate_challenge` V2: block-pair exclusion, `is_suspended` guard, verifies `media_objects.status = 'ready'`
- Standard mutation gate in all Edge Functions: `is_suspended = false` check
- Cleanup worker for `rejected` and `removed` media (using functions in Part 11)

### 1.4 Confirmed decisions

1. Comment placeholder: `[removed by moderator]`; evidence is audit metadata only.
2. Block on active challenge: existing eligible participants retain read-only visibility; no new interactions.
3. Moderation-action immutability: unconditional `BEFORE UPDATE OR DELETE` rejection.
4. Avatar photos: disabled in V1.
5. Text-filter trigger: `SECURITY DEFINER`, no caller bypass.
6. RESTRICTIVE RLS policy approach approved (except where noted as PERMISSIVE).
7. `get_my_reports()` SECURITY DEFINER RPC; direct table SELECT revoked from authenticated.
8. SHA-256 computed in re-encoding worker; stored in `private.media_storage_keys`; copied to evidence at moderation time.
9. Activation media gate: inside `activate_challenge()` while challenge row is locked.
10. Report status states: `pending`, `actioned`, `dismissed` only.
11. `challenge_secrets`: RESTRICTIVE block policy required.
12. `exclusion_events`: direct authenticated INSERT; branched RESTRICTIVE policy.
13. `apply_correction`: `SECURITY DEFINER`/`forkensics_executor` path; suspension guard inside function.
14. `action_report`: requires same-subject prior substantive action; "no violation" closures use `dismiss_report`.
15. `transfer_group_ownership` and `revoke_group_invite`: permitted for suspended users; transfer recipient must be active, onboarded, not suspended; transfer audited in `group_ownership_history`.
16. Global lock order: **content target → all matching pending reports (ascending UUID) → media**.
17. `dismiss_report` acquires only the report lock.
18. `report_content` for removable target types locks the target row before inserting.
19. Idempotency: `moderator_removal_action_id` on challenges, comments, and clues; set atomically during first removal; universal idempotency path reuses it.
20. `redeem_group_invite` requires internal suspension guard.
21. `remove_content` and `remove_media` may be called with `p_report_id = NULL` (proactive moderation); fully audited.
22. `moderation_action_reports.report_id` unique — each resolved report has exactly one resolution link.
23. `media-serve` authorization uses `public.get_media_serve_authorization`; `p_viewer_id` from verified JWT only.
24. Ownership transfer audited in `public.group_ownership_history`.
25. Appeals: V1 — `FK_NOT_FOUND`; users use published support address.
26. All new public tables: RLS enabled; default privileges revoked; access re-granted explicitly.
27. Moderator-removed clues hidden via RESTRICTIVE SELECT policy; clue text preserved in evidence only.
28. `get_poster_media_status`: `p_uploader_id` from verified JWT; query requires `uploader_id = p_uploader_id`.
29. V1 revoked postgres membership in custom roles; migration uses temporary-grant pattern.
30. `moderator_removed_at` and `moderator_removal_action_id` are server-owned; forced NULL on INSERT; only forkensics_executor may transition NULL → non-NULL; immutable once set.
31. `hide_blocked_challenges` uses `private.has_block_with(poster_id)` (bilateral SECURITY DEFINER). `blocks_select_own` on `user_blocks` is `AS PERMISSIVE`.
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

Column-level GRANTs prevent `authenticated` from supplying `moderator_removed_at` or `moderator_removal_action_id`; the trigger guards are an independent additional layer.

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
-- ON CONFLICT must use column-list inference:
--   ON CONFLICT (reporter_id, target_type, target_id, category) WHERE status = 'pending' DO NOTHING
-- Do NOT use: ON CONFLICT ON CONSTRAINT content_reports_unresolved_dedup
CREATE UNIQUE INDEX content_reports_unresolved_dedup
  ON public.content_reports (reporter_id, target_type, target_id, category)
  WHERE status = 'pending';

CREATE INDEX ON public.content_reports (status, created_at);
CREATE INDEX ON public.content_reports (reporter_id);
CREATE INDEX ON public.content_reports (target_type, target_id) WHERE status = 'pending';
```

`reviewed_by` is populated by moderation functions but is never returned to reporters. Access via `get_my_reports()` RPC only.

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

-- Immutability enforced by BEFORE UPDATE OR DELETE trigger:
--   RAISE EXCEPTION 'FK_ACTION_IMMUTABLE'
CREATE INDEX ON public.moderation_actions (target_type, target_id);
CREATE INDEX ON public.moderation_actions (moderator_id, created_at);
```

No SELECT policy for `authenticated`. Service role via SECURITY DEFINER functions only.

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

A row is upserted for each profile at account creation time (inside the function that creates the profile). `suspend_user` and `reinstate_user` update both this table and `public.profiles.is_suspended` atomically within the same transaction.

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

`evidence_sha256` copies from `private.media_storage_keys.sha256_hash` at moderation time. If the hash is NULL (pre-V2 fixture), the moderation function raises `FK_MEDIA_METADATA_INCOMPLETE` and aborts. After 90-day retention expiry: `evidence_text` and `evidence_storage_key` rows are deleted; the immutable `moderation_actions` row remains.

### 3.10 Column additions to existing tables

```sql
-- Moderator removal timestamps
ALTER TABLE public.challenges
  ADD COLUMN IF NOT EXISTS moderator_removed_at timestamptz;
ALTER TABLE public.comments
  ADD COLUMN IF NOT EXISTS moderator_removed_at timestamptz;
ALTER TABLE public.clues
  ADD COLUMN IF NOT EXISTS moderator_removed_at timestamptz;

-- Durable idempotency references — server-owned; forge-protection in Part 6
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
  ADD COLUMN IF NOT EXISTS moderated_at                    timestamptz,
  ADD COLUMN IF NOT EXISTS moderation_cleanup_leased_until timestamptz;

-- media_objects status constraint: replace V1 CHECK with full V2 set
-- V2 values: 'processing','ready','failed','superseded','pending_review','rejected','removed','cleaned'
-- (replace V1 constraint by name in migration)
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
-- Must return 0. Delete or reprocess any pre-V2 development fixtures first.

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
  -- Immutability: BEFORE UPDATE OR DELETE → RAISE EXCEPTION 'FK_ACTION_IMMUTABLE'
);

CREATE INDEX ON public.group_ownership_history (group_id);
```

No SELECT policy for `authenticated`. Service role only.

---

## Part 4 — RLS Enablement and Table Privilege Grants

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

-- Re-grant only intended direct access.
-- user_blocks: authenticated SELECT only, controlled by PERMISSIVE own-row policy.
GRANT SELECT ON public.user_blocks TO authenticated;

-- content_reports, moderation_actions, group_ownership_history:
-- No direct access for authenticated. All access via SECURITY DEFINER functions.
```

`private` tables (`blocked_terms`, `moderators`, `profile_suspensions`, `moderation_evidence`, `moderation_action_reports`, `media_storage_keys`): never exposed via PostgREST. Service role and SECURITY DEFINER functions access them directly.

---

## Part 5 — Role Ownership and Function Privilege Grants

### Migration execution order

**This part must execute AFTER all functions are created** (Parts 7, 8, 10, 11). The recommended migration order is:

1. Schema — Part 3 (tables, columns, constraints, indexes)
2. RLS enablement and table grants — Part 4
3. Function definitions — Parts 7, 8, 10, 11
4. Forge-protection triggers — Part 6
5. Text-filter trigger attachments — Part 8.2
6. **Role ownership and function grants — this Part 5**
7. RLS policy creation — Part 9

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

-- SECURITY DEFINER public and private functions → forkensics_executor
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
GRANT SELECT, INSERT, UPDATE, DELETE ON private.blocked_terms             TO forkensics_executor;
GRANT SELECT, INSERT                 ON private.moderators                TO forkensics_executor;
GRANT SELECT, INSERT, UPDATE         ON private.profile_suspensions       TO forkensics_executor;
GRANT SELECT, INSERT, DELETE         ON private.moderation_evidence       TO forkensics_executor;
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
-- V2 RLS helpers called by report_content, get_media_serve_authorization, remove_content
GRANT EXECUTE ON FUNCTION private.can_view_challenge(uuid)              TO forkensics_executor;
GRANT EXECUTE ON FUNCTION private.can_viewer_access_challenge(uuid,uuid) TO forkensics_executor;

-- V1 helpers called by executor-owned functions
GRANT EXECUTE ON FUNCTION private.auth_uid()                            TO forkensics_executor;
GRANT EXECUTE ON FUNCTION private.is_challenge_revealed(uuid)           TO forkensics_executor;
-- Implementation note: grep every executor-owned function body for private.* calls.
-- Grant EXECUTE for each such function. The list above covers known call sites;
-- additional V1 helpers (e.g., called from activate_challenge, finalize_upload_session,
-- redeem_group_invite, apply_correction) must be identified and granted similarly.
```

**To `service_role`:**

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
GRANT EXECUTE ON FUNCTION public.check_text_content(text)                TO service_role;
REVOKE EXECUTE ON FUNCTION public.check_text_content(text)               FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.approve_photo(uuid,uuid,text)           TO service_role;
REVOKE EXECUTE ON FUNCTION public.approve_photo(uuid,uuid,text)          FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.reject_photo(uuid,uuid,text)            TO service_role;
REVOKE EXECUTE ON FUNCTION public.reject_photo(uuid,uuid,text)           FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.remove_content(text,uuid,uuid,uuid,text) TO service_role;
REVOKE EXECUTE ON FUNCTION public.remove_content(text,uuid,uuid,uuid,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.remove_media(uuid,uuid,uuid,text)       TO service_role;
REVOKE EXECUTE ON FUNCTION public.remove_media(uuid,uuid,uuid,text)      FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.suspend_user(uuid,uuid,text)            TO service_role;
REVOKE EXECUTE ON FUNCTION public.suspend_user(uuid,uuid,text)           FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.reinstate_user(uuid,uuid,text)          TO service_role;
REVOKE EXECUTE ON FUNCTION public.reinstate_user(uuid,uuid,text)         FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.dismiss_report(uuid,uuid,text)          TO service_role;
REVOKE EXECUTE ON FUNCTION public.dismiss_report(uuid,uuid,text)         FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.action_report(uuid,uuid,uuid,text)      TO service_role;
REVOKE EXECUTE ON FUNCTION public.action_report(uuid,uuid,uuid,text)     FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_media_serve_authorization(uuid,uuid) TO service_role;
REVOKE EXECUTE ON FUNCTION public.get_media_serve_authorization(uuid,uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_moderation_queue()                  TO service_role;
REVOKE EXECUTE ON FUNCTION public.get_moderation_queue()                 FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_pending_review_media(uuid)          TO service_role;
REVOKE EXECUTE ON FUNCTION public.get_pending_review_media(uuid)         FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_reported_media(uuid)                TO service_role;
REVOKE EXECUTE ON FUNCTION public.get_reported_media(uuid)               FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_poster_media_status(uuid,uuid)      TO service_role;
REVOKE EXECUTE ON FUNCTION public.get_poster_media_status(uuid,uuid)     FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_report_for_review(uuid)             TO service_role;
REVOKE EXECUTE ON FUNCTION public.get_report_for_review(uuid)            FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.claim_moderation_media_cleanup(int)     TO service_role;
REVOKE EXECUTE ON FUNCTION public.claim_moderation_media_cleanup(int)    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.mark_moderation_media_cleaned(uuid)     TO service_role;
REVOKE EXECUTE ON FUNCTION public.mark_moderation_media_cleaned(uuid)    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.cleanup_expired_evidence()             TO service_role;
REVOKE EXECUTE ON FUNCTION private.cleanup_expired_evidence()            FROM PUBLIC, anon, authenticated;
```

### 5.7 Temporary role grant (close)

```sql
REVOKE forkensics_executor   FROM postgres;
REVOKE forkensics_rls_helper FROM postgres;
```

---

## Part 6 — Forge-Protection Triggers

### 6.1 INSERT forge-nulling function

Forces both server-owned fields to NULL on every INSERT, regardless of what the caller supplies.

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

`SECURITY INVOKER` — `current_user` is the actual caller. For comments, equivalent protection is embedded in `restrict_comment_updates`.

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

---

## Part 7 — RLS Helper Functions

All: owned by `forkensics_rls_helper`, `SECURITY DEFINER`, `SET search_path = ''`, `STABLE`.

### 7.1 `private.can_view_challenge(p_challenge_id uuid) → boolean`

For RLS policies where `private.auth_uid()` is the viewer.

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

SECURITY DEFINER — sees both block directions regardless of caller's SELECT privileges.

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

### 8.2 `public.check_text_content(p_text text) → boolean`

Early validation for Edge Functions. Returns `true` if no blocked term found. The trigger is the authoritative enforcement point. EXECUTE granted to `service_role` only.

```sql
CREATE OR REPLACE FUNCTION public.check_text_content(p_text text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT NOT EXISTS (
    SELECT 1 FROM private.blocked_terms
    WHERE position(lower(term) IN lower(p_text)) > 0
  );
$$;
```

### 8.3 Trigger attachments

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

All policies on existing V1 tables: `AS RESTRICTIVE`. Policies on new tables (no V1 permissive baseline): `AS PERMISSIVE` where required.

### 9.1 Suspension enforcement (RESTRICTIVE on existing tables)

Predicate: `NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = private.auth_uid() AND is_suspended = true)`.

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

### 9.2 `exclusion_events` — branched suspension (RESTRICTIVE)

```sql
CREATE POLICY suspend_exclusion_insert AS RESTRICTIVE ON public.exclusion_events
  FOR INSERT TO authenticated
  WITH CHECK (
    NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = private.auth_uid() AND is_suspended = true)
    OR (reason = 'withdrew' AND player_id = private.auth_uid())
  );
```

### 9.3 Block enforcement — INSERT (RESTRICTIVE)

```sql
CREATE POLICY enforce_no_block_guess    AS RESTRICTIVE ON public.guess_attempts
  FOR INSERT TO authenticated WITH CHECK (NOT private.has_block_with_poster(challenge_id));
CREATE POLICY enforce_no_block_comment  AS RESTRICTIVE ON public.comments
  FOR INSERT TO authenticated WITH CHECK (NOT private.has_block_with_poster(challenge_id));
CREATE POLICY enforce_no_block_reaction AS RESTRICTIVE ON public.reactions
  FOR INSERT TO authenticated WITH CHECK (NOT private.has_block_with_poster(challenge_id));
```

### 9.4 Block enforcement — SELECT (RESTRICTIVE)

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

### 9.5 Moderator-removed clues — hidden (RESTRICTIVE)

```sql
CREATE POLICY hide_removed_clues AS RESTRICTIVE ON public.clues
  FOR SELECT TO authenticated
  USING (moderator_removed_at IS NULL);
```

Service role (BYPASSRLS) reads removed clues for evidence. Moderators access removed clue text exclusively via `private.moderation_evidence`.

### 9.6 Block-aware visibility on challenge-linked child tables (RESTRICTIVE)

Applied to: `clues`, `challenge_secrets`, `challenge_answer_aliases`, `guess_attempts`, `guess_judgments`, `score_runs`, `score_events`, `correction_events`, `eligible_participants`, `exclusion_events`.

```sql
-- Template (replace <table> and <challenge_fk>):
CREATE POLICY block_aware_visibility AS RESTRICTIVE ON public.<table>
  FOR SELECT TO authenticated
  USING (private.can_view_challenge(<challenge_fk>));
```

### 9.7 `user_blocks` SELECT policy (PERMISSIVE — new table, no V1 baseline)

```sql
-- PERMISSIVE required: a new table with only RESTRICTIVE policies returns no rows.
CREATE POLICY blocks_select_own AS PERMISSIVE ON public.user_blocks
  FOR SELECT TO authenticated
  USING (blocker_id = private.auth_uid());
```

No INSERT, UPDATE, or DELETE policies. All mutations via `block_user` / `unblock_user`.

---

## Part 10 — SECURITY DEFINER Functions

All: owned by `forkensics_executor`, `SET search_path = ''`. EXECUTE grants per Part 5.

### 10.1 Moderator identity validation (internal, all moderation functions)

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

Every function acquires locks in this order, without exception.

### 10.3 `public.report_content`

```
public.report_content(
  p_target_type text,   -- 'challenge'|'comment'|'clue'|'profile'|'media_object'
  p_target_id   uuid,
  p_category    text,
  p_detail      text    -- nullable; max 500 chars
) → TABLE(report_id uuid)
```

EXECUTE granted to `authenticated`.

1. Verify caller is active and onboarded. Suspended callers are permitted to report.
2. Validate `target_type` ∈ allowed values; validate `category` ∈ allowed values. Raise `FK_INVALID_INPUT` if not.
3. Rate limit: `SELECT count(*) FROM content_reports WHERE reporter_id = auth_uid() AND status = 'pending' AND created_at > clock_timestamp() - interval '1 hour'`. If ≥ 10 → raise `FK_RATE_LIMITED`.
4. Lock and recheck target:

   **`'challenge'`:**
   ```sql
   SELECT id, moderator_removed_at FROM public.challenges
   WHERE id = p_target_id FOR UPDATE;
   ```
   Verify `private.can_view_challenge(p_target_id) = true`. If not → `FK_NOT_FOUND`.
   Verify `moderator_removed_at IS NULL`. If not → `FK_NOT_FOUND`.

   **`'comment'`:**
   ```sql
   SELECT id, challenge_id, moderator_removed_at FROM public.comments
   WHERE id = p_target_id FOR UPDATE;
   ```
   Verify `moderator_removed_at IS NULL`. If not → `FK_NOT_FOUND`.
   Read `c.poster_id`, `c.group_id` from the linked challenge.
   Check current group membership:
   ```sql
   SELECT 1 FROM public.group_members
   WHERE group_id = c.group_id AND player_id = private.auth_uid()
   ```
   If not a current member → `FK_NOT_FOUND`.
   Check Table Talk visibility — at least one must be true:
   - `c.poster_id = private.auth_uid()`
   - `private.is_challenge_revealed(comment.challenge_id)`
   - `EXISTS (SELECT 1 FROM public.guess_attempts WHERE challenge_id = comment.challenge_id AND player_id = private.auth_uid())`
   If none → `FK_NOT_FOUND`. ("Caller is comment author" is not checked — self-reports are rejected at step 5.)

   **`'clue'`:**
   ```sql
   SELECT id, challenge_id, moderator_removed_at FROM public.clues
   WHERE id = p_target_id FOR UPDATE;
   ```
   Verify `moderator_removed_at IS NULL`. If not → `FK_NOT_FOUND`.
   Verify `private.can_view_challenge(challenge_id) = true`. If not → `FK_NOT_FOUND`.

   **`'media_object'` — six-step sequence matching `remove_media` lock order:**
   ```sql
   -- a. Provisional challenge read
   SELECT id INTO v_challenge_id FROM public.challenges
   WHERE media_object_id = p_target_id;
   IF NOT FOUND → FK_NOT_FOUND.

   -- b. Lock challenge
   SELECT id, media_object_id FROM public.challenges
   WHERE id = v_challenge_id FOR UPDATE;

   -- c. Re-verify linkage
   IF challenges.media_object_id != p_target_id → FK_NOT_FOUND.

   -- d. Re-check viewer access
   IF NOT private.can_view_challenge(v_challenge_id) → FK_NOT_FOUND.

   -- e. Lock media
   SELECT id, status FROM public.media_objects
   WHERE id = p_target_id FOR UPDATE;

   -- f. Verify ready
   IF status != 'ready' → FK_NOT_FOUND.
   ```

   **`'profile'`:**
   Verify target is active (`is_active = true`). Verify caller shares at least one group with target:
   ```sql
   SELECT 1 FROM public.group_members gm1
   JOIN public.group_members gm2 ON gm1.group_id = gm2.group_id
   WHERE gm1.player_id = private.auth_uid() AND gm2.player_id = p_target_id
   ```
   If no shared group → `FK_NOT_FOUND`. No row lock needed.

   In all cases: `FK_NOT_FOUND` is the uniform response for nonexistent, unauthorized, and already-actioned targets (no information leakage).

5. Prevent self-report: `IF p_target_id = private.auth_uid() THEN RAISE EXCEPTION 'FK_SELF_REPORT'; END IF;` (and for non-profile targets, verify `reporter_id` is not the content author where applicable).

6. Insert with partial-index dedup:
   ```sql
   INSERT INTO public.content_reports
     (reporter_id, target_type, target_id, category, detail)
   VALUES
     (private.auth_uid(), p_target_type, p_target_id, p_category, p_detail)
   ON CONFLICT (reporter_id, target_type, target_id, category)
   WHERE status = 'pending'
   DO NOTHING
   RETURNING id INTO v_report_id;

   IF v_report_id IS NULL THEN   -- conflict: return existing report
     SELECT id INTO v_report_id FROM public.content_reports
     WHERE reporter_id = private.auth_uid()
       AND target_type = p_target_type
       AND target_id = p_target_id
       AND category = p_category
       AND status = 'pending';
   END IF;
   ```

7. Return `TABLE(report_id uuid)` containing `v_report_id`.

### 10.4 `public.block_user(p_blocked_id uuid) → void`

EXECUTE granted to `authenticated`. Suspended callers permitted.

1. Verify caller is active. Verify `p_blocked_id` exists.
2. Prevent self-block: `IF p_blocked_id = private.auth_uid() THEN RAISE EXCEPTION 'FK_SELF_BLOCK'; END IF;`
3. Idempotent insert:
   ```sql
   INSERT INTO public.user_blocks (blocker_id, blocked_id)
   VALUES (private.auth_uid(), p_blocked_id)
   ON CONFLICT DO NOTHING;
   ```

### 10.5 `public.unblock_user(p_blocked_id uuid) → void`

EXECUTE granted to `authenticated`. Idempotent:
```sql
DELETE FROM public.user_blocks
WHERE blocker_id = private.auth_uid() AND blocked_id = p_blocked_id;
```

### 10.6 `public.approve_photo`

```
public.approve_photo(
  p_media_object_id uuid,
  p_moderator_id    uuid,
  p_reason          text
) → void
```

EXECUTE granted to `service_role`.

1. Validate moderator (Section 10.1).
2. Lock media:
   ```sql
   SELECT id, status FROM public.media_objects
   WHERE id = p_media_object_id FOR UPDATE;
   ```
   Verify `status = 'pending_review'`. If not → `FK_WRONG_STATE`.
3. Insert action:
   ```sql
   INSERT INTO public.moderation_actions
     (moderator_id, action_type, target_type, target_id, reason)
   VALUES
     (p_moderator_id, 'photo_approved', 'media_object', p_media_object_id, p_reason)
   RETURNING id INTO v_action_id;
   ```
4. Update media:
   ```sql
   UPDATE public.media_objects
   SET status = 'ready', moderated_at = clock_timestamp()
   WHERE id = p_media_object_id;
   ```

### 10.7 `public.reject_photo`

```
public.reject_photo(
  p_media_object_id uuid,
  p_moderator_id    uuid,
  p_reason          text
) → void
```

EXECUTE granted to `service_role`.

1. Validate moderator.
2. Lock media. Verify `status = 'pending_review'`.
3. Read SHA-256:
   ```sql
   SELECT sha256_hash, re_encoded_storage_key INTO v_sha256, v_storage_key
   FROM private.media_storage_keys WHERE media_object_id = p_media_object_id;
   ```
   If `v_sha256 IS NULL` → raise `FK_MEDIA_METADATA_INCOMPLETE`.
4. Insert action:
   ```sql
   INSERT INTO public.moderation_actions
     (moderator_id, action_type, target_type, target_id, reason)
   VALUES
     (p_moderator_id, 'photo_rejected', 'media_object', p_media_object_id, p_reason)
   RETURNING id INTO v_action_id;
   ```
5. Insert evidence:
   ```sql
   INSERT INTO private.moderation_evidence
     (moderation_action_id, evidence_type, evidence_storage_key, evidence_sha256)
   VALUES
     (v_action_id, 'media_metadata', v_storage_key, v_sha256);
   ```
6. Update media:
   ```sql
   UPDATE public.media_objects
   SET status = 'rejected', moderated_at = clock_timestamp()
   WHERE id = p_media_object_id;
   ```

Challenge stays in `draft`. Poster retrieves status via `get_poster_media_status`.

### 10.8 `public.remove_content`

```
public.remove_content(
  p_target_type  text,   -- 'challenge' | 'comment' | 'clue'
  p_target_id    uuid,
  p_moderator_id uuid,
  p_report_id    uuid,   -- nullable; NULL for proactive moderation
  p_reason       text
) → void
```

EXECUTE granted to `service_role`.

**For `'challenge'`:**

```
1.  Validate moderator (Section 10.1).
2.  Lock challenge:
      SELECT id, state, media_object_id, moderator_removed_at, moderator_removal_action_id
      FROM public.challenges WHERE id = p_target_id FOR UPDATE;
    If NOT FOUND → FK_NOT_FOUND.
3.  If moderator_removed_at IS NOT NULL → universal idempotency path (Section 10.11).
4.  Validate challenge state — any state is actionable (see state matrix Section 10.10).
5.  v_media_object_id := challenges.media_object_id.
6.  Lock all matching pending reports in ascending UUID order:
      SELECT id FROM public.content_reports
      WHERE status = 'pending'
        AND (
          (target_type = 'challenge' AND target_id = p_target_id)
          OR (target_type = 'media_object' AND target_id = v_media_object_id)
        )
      ORDER BY id FOR UPDATE
      → v_report_ids uuid[].
7.  If p_report_id IS NOT NULL:
      Verify p_report_id = ANY(v_report_ids). If not → FK_REPORT_TARGET_MISMATCH.
8.  Lock media:
      SELECT id, status FROM public.media_objects
      WHERE id = v_media_object_id FOR UPDATE;
    Validate per media state matrix (Section 10.10).
9.  Read SHA-256:
      SELECT sha256_hash, re_encoded_storage_key INTO v_sha256, v_storage_key
      FROM private.media_storage_keys WHERE media_object_id = v_media_object_id;
    If v_sha256 IS NULL → FK_MEDIA_METADATA_INCOMPLETE.
10. INSERT moderation_actions:
      (moderator_id = p_moderator_id, action_type = 'content_removed',
       target_type = 'challenge', target_id = p_target_id,
       report_id = p_report_id, reason = p_reason)
    RETURNING id → v_action_id.
11. INSERT moderation_evidence:
      (moderation_action_id = v_action_id, evidence_type = 'media_metadata',
       evidence_storage_key = v_storage_key, evidence_sha256 = v_sha256).
12. UPDATE public.challenges per state matrix;
    also SET moderator_removal_action_id = v_action_id.  ← set atomically in same UPDATE
13. UPDATE public.media_objects per media state matrix.
14. INSERT one moderation_action_reports row per id in v_report_ids[]:
      INSERT INTO private.moderation_action_reports (moderation_action_id, report_id)
      SELECT v_action_id, id FROM unnest(v_report_ids) AS t(id).
15. UPDATE public.content_reports SET status = 'actioned',
      reviewed_at = clock_timestamp(), reviewed_by = p_moderator_id
    WHERE id = ANY(v_report_ids).
```

**For `'comment'`:**

```
1.  Validate moderator.
2.  Lock comment:
      SELECT id, text, challenge_id, moderator_removed_at, moderator_removal_action_id
      FROM public.comments WHERE id = p_target_id FOR UPDATE;
    If NOT FOUND → FK_NOT_FOUND.
    If moderator_removed_at IS NOT NULL → universal idempotency path (Section 10.11).
3.  Lock all matching pending reports in ascending UUID order:
      SELECT id FROM public.content_reports
      WHERE target_type = 'comment' AND target_id = p_target_id AND status = 'pending'
      ORDER BY id FOR UPDATE
      → v_report_ids uuid[].
4.  If p_report_id IS NOT NULL: verify p_report_id = ANY(v_report_ids). If not → FK_REPORT_TARGET_MISMATCH.
5.  INSERT moderation_actions:
      (moderator_id = p_moderator_id, action_type = 'content_removed',
       target_type = 'comment', target_id = p_target_id,
       report_id = p_report_id, reason = p_reason)
    RETURNING id → v_action_id.
6.  INSERT moderation_evidence:
      (moderation_action_id = v_action_id, evidence_type = 'comment_text',
       evidence_text = comment.text).   ← original text before replacement
7.  UPDATE public.comments:
      SET text = '[removed by moderator]',
          moderator_removed_at = clock_timestamp(),   ← trigger also enforces this
          moderator_removal_action_id = v_action_id
      WHERE id = p_target_id.
8.  INSERT moderation_action_reports per v_report_ids[].
9.  UPDATE content_reports SET status = 'actioned', reviewed_at, reviewed_by
    WHERE id = ANY(v_report_ids).
```

**For `'clue'`:**

```
1.  Validate moderator.
2.  Lock clue:
      SELECT id, text, challenge_id, moderator_removed_at, moderator_removal_action_id
      FROM public.clues WHERE id = p_target_id FOR UPDATE;
    If NOT FOUND → FK_NOT_FOUND.
    If moderator_removed_at IS NOT NULL → universal idempotency path (Section 10.11).
3.  Lock all matching pending reports in ascending UUID order:
      SELECT id FROM public.content_reports
      WHERE target_type = 'clue' AND target_id = p_target_id AND status = 'pending'
      ORDER BY id FOR UPDATE
      → v_report_ids uuid[].
4.  If p_report_id IS NOT NULL: verify p_report_id = ANY(v_report_ids). If not → FK_REPORT_TARGET_MISMATCH.
5.  INSERT moderation_actions:
      (moderator_id = p_moderator_id, action_type = 'content_removed',
       target_type = 'clue', target_id = p_target_id,
       report_id = p_report_id, reason = p_reason)
    RETURNING id → v_action_id.
6.  INSERT moderation_evidence:
      (moderation_action_id = v_action_id, evidence_type = 'clue_text',
       evidence_text = clue.text).   ← original text; clue row text is NOT changed
7.  UPDATE public.clues:
      SET moderator_removed_at = clock_timestamp(),
          moderator_removal_action_id = v_action_id
      WHERE id = p_target_id.
    Clue text is preserved in the row. The RESTRICTIVE SELECT policy hides the row from authenticated.
8.  INSERT moderation_action_reports per v_report_ids[].
9.  UPDATE content_reports SET status = 'actioned', reviewed_at, reviewed_by
    WHERE id = ANY(v_report_ids).
```

### 10.9 `public.remove_media`

```
public.remove_media(
  p_media_object_id uuid,
  p_moderator_id    uuid,
  p_report_id       uuid,  -- nullable
  p_reason          text
) → void
```

EXECUTE granted to `service_role`.

```
1.  Validate moderator.
2.  Provisional challenge read (before acquiring any lock):
      SELECT id INTO v_challenge_id FROM public.challenges
      WHERE media_object_id = p_media_object_id;
    If NOT FOUND → FK_NOT_FOUND.
3.  Lock challenge:
      SELECT id, state, media_object_id, moderator_removed_at, moderator_removal_action_id
      FROM public.challenges WHERE id = v_challenge_id FOR UPDATE;
4.  If moderator_removed_at IS NOT NULL → universal idempotency path (Section 10.11).
5.  Re-validate linkage:
      If challenges.media_object_id != p_media_object_id → FK_LINKAGE_CHANGED.
6.  Lock all matching pending reports in ascending UUID order:
      SELECT id FROM public.content_reports
      WHERE status = 'pending'
        AND (
          (target_type = 'media_object' AND target_id = p_media_object_id)
          OR (target_type = 'challenge' AND category = 'inappropriate_image'
              AND target_id = v_challenge_id)
        )
      ORDER BY id FOR UPDATE
      → v_report_ids uuid[].
7.  If p_report_id IS NOT NULL: verify p_report_id = ANY(v_report_ids). If not → FK_REPORT_TARGET_MISMATCH.
8.  Lock media:
      SELECT id, status FROM public.media_objects
      WHERE id = p_media_object_id FOR UPDATE;
    Verify status = 'ready'. If not → FK_WRONG_STATE.
9.  Read SHA-256:
      SELECT sha256_hash, re_encoded_storage_key INTO v_sha256, v_storage_key
      FROM private.media_storage_keys WHERE media_object_id = p_media_object_id;
    If v_sha256 IS NULL → FK_MEDIA_METADATA_INCOMPLETE.
10. INSERT moderation_actions:
      (moderator_id = p_moderator_id, action_type = 'photo_removed',
       target_type = 'media_object', target_id = p_media_object_id,
       report_id = p_report_id, reason = p_reason)
    RETURNING id → v_action_id.
11. INSERT moderation_evidence:
      (moderation_action_id = v_action_id, evidence_type = 'media_metadata',
       evidence_storage_key = v_storage_key, evidence_sha256 = v_sha256).
12. UPDATE public.media_objects:
      SET status = 'removed', moderated_at = clock_timestamp()
      WHERE id = p_media_object_id.
13. UPDATE public.challenges per state matrix (Section 10.10);
    also SET moderator_removal_action_id = v_action_id.  ← set atomically
14. INSERT moderation_action_reports per v_report_ids[].
15. UPDATE content_reports SET status = 'actioned', reviewed_at, reviewed_by
    WHERE id = ANY(v_report_ids).
```

### 10.10 State matrices

**Challenge state → outcome (applied in `remove_content('challenge')` and `remove_media`):**

| Challenge state | Outcome |
|---|---|
| `draft` | state → `cancelled`, `cancellation_reason = 'moderation_action'`, `moderator_removed_at = clock_timestamp()` |
| `active` | Same |
| `locked` | Same |
| `revealed` | state unchanged; `moderator_removed_at = clock_timestamp()`. Scores preserved. |
| `cancelled` (any reason) | `moderator_removed_at = clock_timestamp()` if not already set; state unchanged. |

**Media status → action during challenge/media removal:**

| Media status | Action |
|---|---|
| `ready`, `pending_review`, `rejected`, `superseded` | `status = 'removed'`, `moderated_at = clock_timestamp()` |
| `removed`, `cleaned` | Skip media UPDATE (already removed; not an error) |
| `processing`, `failed` | Raise `FK_WRONG_STATE`; abort entire transaction |

### 10.11 Universal idempotency path

Entered when `moderator_removed_at IS NOT NULL` is detected after acquiring the target lock (challenge, comment, or clue). `moderator_removal_action_id` is the durable server-controlled pointer set atomically during the first removal — correct regardless of whether the original removal was via `remove_content` or `remove_media`.

```
1. v_existing_action_id := target_row.moderator_removal_action_id.
   If NULL → RAISE EXCEPTION 'FK_STATE_INCONSISTENCY: target removed but action pointer is NULL'.

2. Lock all new matching pending reports (same report query per target type, ORDER BY id FOR UPDATE)
   → v_new_report_ids uuid[].
   For challenges: query includes both challenge and linked media_object reports.
   For comments: query covers comment reports only.
   For clues: query covers clue reports only.

3. INSERT INTO private.moderation_action_reports (moderation_action_id, report_id)
   SELECT v_existing_action_id, id FROM unnest(v_new_report_ids) AS t(id)
   ON CONFLICT ON CONSTRAINT moderation_action_reports_one_resolution DO NOTHING.

4. Verify no newly-discovered report is linked to a different action:
   IF EXISTS (
     SELECT 1 FROM private.moderation_action_reports mar
     WHERE mar.report_id = ANY(v_new_report_ids)
       AND mar.moderation_action_id != v_existing_action_id
   ) THEN RAISE EXCEPTION 'FK_RESOLUTION_CONFLICT'; END IF.

5. UPDATE public.content_reports
   SET status = 'actioned', reviewed_at = clock_timestamp(), reviewed_by = p_moderator_id
   WHERE id = ANY(v_new_report_ids).

6. Return. (No new moderation_actions or moderation_evidence rows created.)
```

### 10.12 `public.suspend_user`

```
public.suspend_user(
  p_profile_id   uuid,
  p_moderator_id uuid,
  p_reason       text
) → void
```

EXECUTE granted to `service_role`.

1. Validate moderator.
2. Verify profile exists and is active (`is_active = true`).
3. Idempotent: if already suspended, return without error.
4. Atomically within the same transaction:
   ```sql
   UPDATE public.profiles SET is_suspended = true WHERE id = p_profile_id;

   INSERT INTO private.profile_suspensions
     (profile_id, is_suspended, suspended_at, suspension_reason, suspended_by)
   VALUES
     (p_profile_id, true, clock_timestamp(), p_reason, p_moderator_id)
   ON CONFLICT (profile_id) DO UPDATE
     SET is_suspended = true,
         suspended_at = clock_timestamp(),
         suspension_reason = EXCLUDED.suspension_reason,
         suspended_by = EXCLUDED.suspended_by;
   ```
5. INSERT moderation_actions `(action_type = 'user_suspended', target_type = 'profile', target_id = p_profile_id, ...)`.

### 10.13 `public.reinstate_user`

```
public.reinstate_user(
  p_profile_id   uuid,
  p_moderator_id uuid,
  p_reason       text
) → void
```

EXECUTE granted to `service_role`.

1. Validate moderator.
2. Verify `profiles.is_suspended = true`. If not → FK_WRONG_STATE.
3. Atomically:
   ```sql
   UPDATE public.profiles SET is_suspended = false WHERE id = p_profile_id;

   UPDATE private.profile_suspensions
   SET is_suspended = false, suspended_at = NULL,
       suspension_reason = NULL, suspended_by = NULL
   WHERE profile_id = p_profile_id;
   ```
4. INSERT moderation_actions `(action_type = 'user_reinstated', target_type = 'profile', target_id = p_profile_id, ...)`.

### 10.14 `public.dismiss_report`

```
public.dismiss_report(
  p_report_id    uuid,
  p_moderator_id uuid,
  p_reason       text
) → void
```

EXECUTE granted to `service_role`. Acquires only the report row lock.

```
1. Validate moderator.
2. SELECT id, status FROM public.content_reports WHERE id = p_report_id FOR UPDATE;
   If NOT FOUND → FK_NOT_FOUND.
   Verify status = 'pending'. If not → FK_WRONG_STATE.
3. INSERT moderation_actions:
     (moderator_id = p_moderator_id, action_type = 'report_dismissed',
      report_id = p_report_id, reason = p_reason)
   RETURNING id → v_action_id.
4. INSERT private.moderation_action_reports:
     (moderation_action_id = v_action_id, report_id = p_report_id).
5. UPDATE public.content_reports
   SET status = 'dismissed', reviewed_at = clock_timestamp(), reviewed_by = p_moderator_id
   WHERE id = p_report_id.
```

### 10.15 `public.action_report`

```
public.action_report(
  p_report_id       uuid,
  p_moderator_id    uuid,
  p_prior_action_id uuid,  -- required
  p_reason          text
) → void
```

EXECUTE granted to `service_role`. Closes a report where the corresponding substantive moderation action was recorded separately.

```
1. Validate moderator.
2. Read prior action:
   SELECT action_type, target_type, target_id FROM public.moderation_actions
   WHERE id = p_prior_action_id;
   If NOT FOUND → FK_NOT_FOUND.
   Verify action_type NOT IN ('report_dismissed','report_actioned','photo_approved').
   If non-qualifying → FK_INVALID_PRIOR_ACTION.
3. Lock report:
   SELECT target_type, target_id, status FROM public.content_reports
   WHERE id = p_report_id FOR UPDATE;
   Verify status = 'pending'. If not → FK_WRONG_STATE.
   Verify report.target_type = prior.target_type AND report.target_id = prior.target_id.
   If mismatch → FK_REPORT_TARGET_MISMATCH.
4. INSERT moderation_actions:
     (moderator_id = p_moderator_id, action_type = 'report_actioned',
      report_id = p_report_id, prior_action_id = p_prior_action_id, reason = p_reason)
   RETURNING id → v_action_id.
5. INSERT private.moderation_action_reports:
     (moderation_action_id = v_action_id, report_id = p_report_id).
6. UPDATE public.content_reports
   SET status = 'actioned', reviewed_at = clock_timestamp(), reviewed_by = p_moderator_id
   WHERE id = p_report_id.
```

### 10.16 `public.get_media_serve_authorization`

```
public.get_media_serve_authorization(
  p_media_object_id uuid,
  p_viewer_id       uuid   -- from Edge Function verified JWT only; never from request body
) → TABLE(re_encoded_storage_key text)
```

EXECUTE granted to `service_role` only. Revoked from PUBLIC, anon, authenticated.

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

Returns empty set if any condition fails. The Edge Function treats empty set = 403 `FK_FORBIDDEN`. Combining authorization and key retrieval in one atomic RPC eliminates a check/use gap.

**Edge Function `media-serve` flow:**
1. Extract `user_id` from verified JWT via `supabaseClient.auth.getUser()`. Never from request body.
2. Call `get_media_serve_authorization(p_media_object_id, user_id)` using service-role connection.
3. Empty set → 403.
4. Use returned `re_encoded_storage_key` to generate a signed URL via service role.

### 10.17 `public.get_moderation_queue`

```
public.get_moderation_queue()
→ TABLE(queue_type text, item_id uuid, created_at timestamptz,
        target_type text, target_id uuid, category text, challenge_id uuid)
```

EXECUTE granted to `service_role`. Returns two types:
- `'pending_report'`: from `content_reports WHERE status = 'pending'`
- `'pending_review_photo'`: from `media_objects WHERE status = 'pending_review'`

Ordered by `created_at ASC` (oldest first).

### 10.18 `public.get_pending_review_media`

```
public.get_pending_review_media(p_media_object_id uuid)
→ TABLE(media_object_id uuid, re_encoded_storage_key text,
        challenge_id uuid, uploader_id uuid, re_encoded_at timestamptz)
```

EXECUTE granted to `service_role`. Returns row only if `media_objects.status = 'pending_review'`. No row otherwise.

### 10.19 `public.get_reported_media`

```
public.get_reported_media(p_report_id uuid)
→ TABLE(media_object_id uuid, re_encoded_storage_key text,
        challenge_id uuid, uploader_id uuid, media_status text,
        report_category text, report_detail text)
```

EXECUTE granted to `service_role`. Returns row if report `status = 'pending'` and linked media is `'ready'` or `'pending_review'`.

### 10.20 `public.get_poster_media_status`

```
public.get_poster_media_status(
  p_media_object_id uuid,
  p_uploader_id     uuid   -- from verified JWT only; never from request body
) → TABLE(status text, rejection_message text)
```

EXECUTE granted to `service_role` only.

```sql
CREATE OR REPLACE FUNCTION public.get_poster_media_status(
  p_media_object_id uuid,
  p_uploader_id     uuid
) RETURNS TABLE(status text, rejection_message text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT
    mo.status,
    CASE WHEN mo.status = 'rejected'
         THEN 'Photo couldn''t be approved — choose another photo.'
         ELSE NULL
    END AS rejection_message
  FROM public.media_objects mo
  WHERE mo.id = p_media_object_id
    AND mo.uploader_id = p_uploader_id;   -- V1 column name; wrong uploader → no row
$$;
```

No moderator notes, `reviewed_by`, or internal status details returned.

### 10.21 `public.get_my_reports`

```
public.get_my_reports()
→ TABLE(id uuid, target_type text, target_id uuid, category text,
        detail text, status text, created_at timestamptz, reviewed_at timestamptz)
```

EXECUTE granted to `authenticated`. `reviewed_by` intentionally excluded.

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

### 10.22 `public.get_report_for_review`

```
public.get_report_for_review(p_report_id uuid)
→ TABLE(report_id uuid, reporter_id uuid, target_type text, target_id uuid,
        category text, detail text, status text, created_at timestamptz,
        target_summary text)
```

EXECUTE granted to `service_role`. `target_summary`: the comment or clue text for those target types; NULL for challenge, media_object, or profile (use `get_moderation_queue` + `get_reported_media` for media).

### 10.23 Suspension-gated SECURITY DEFINER functions

The following executor-owned functions add this guard at entry:

```sql
IF EXISTS (
  SELECT 1 FROM public.profiles
  WHERE id = private.auth_uid() AND is_suspended = true
) THEN RAISE EXCEPTION 'FK_SUSPENDED'; END IF;
```

| Function |
|---|
| `activate_challenge` |
| `create_group` |
| `create_group_invite` |
| `redeem_group_invite` |
| `apply_correction` |

`transfer_group_ownership`: suspended poster permitted (safe exit action). V1 ownership is represented by `group_members.role = 'owner'` (enforced by a partial unique index `one_owner_per_group`); there is no `groups.owner_id` column. The function must:

```
DECLARE v_current_owner_id uuid;
BEGIN
1. Lock the group row: PERFORM 1 FROM public.groups WHERE id = p_group_id FOR UPDATE;
2. Identify the current owner:
     SELECT gm.player_id INTO v_current_owner_id
     FROM public.group_members gm
     WHERE gm.group_id = p_group_id AND gm.role = 'owner'
     FOR UPDATE;
   Verify that v_current_owner_id = private.auth_uid() (or the verified caller).
   If NOT FOUND or mismatch → FK_UNAUTHORIZED.
3. Lock the recipient's membership row:
     PERFORM 1
     FROM public.group_members gm
     WHERE gm.group_id = p_group_id AND gm.player_id = p_new_owner_id
     FOR UPDATE;
   If NOT FOUND → FK_NOT_FOUND (recipient must be a group member).
4. Validate recipient: active (is_active = true), onboarded, is_suspended = false.
   If any guard fails → FK_INVALID_RECIPIENT.
5. INSERT INTO public.group_ownership_history
     (group_id, previous_owner, new_owner)
   VALUES
     (p_group_id, v_current_owner_id, p_new_owner_id);
6. UPDATE public.group_members SET role = 'member'
   WHERE group_id = p_group_id AND player_id = v_current_owner_id;
7. UPDATE public.group_members SET role = 'owner'
   WHERE group_id = p_group_id AND player_id = p_new_owner_id;
```

Steps 5, 6, and 7 execute atomically within the same transaction. After commit: exactly one `group_members` row has `role = 'owner'`; the previous owner has `role = 'member'`; one `group_ownership_history` row records the transfer.

### 10.24 SHA-256 validation in `finalize_upload_session`

```sql
IF p_sha256_hash IS NULL OR p_sha256_hash !~ '^[0-9a-f]{64}$' THEN
  RAISE EXCEPTION 'FK_INVALID_HASH: sha256_hash must be 64 lowercase hex characters';
END IF;
```

Parameter declared as `p_sha256_hash text`. Stores hash in `private.media_storage_keys.sha256_hash` atomically with `re_encoded_storage_key`.

**Replacement media pointer (re-upload after rejection):**
1. Lock draft challenge `FOR UPDATE`.
2. Create new media_object with `status = 'pending_review'`, `re_encoded_at = clock_timestamp()`.
3. `UPDATE challenges SET media_object_id = new_id WHERE id = challenge_id AND state = 'draft'`.
4. `activate_challenge` reads the current pointer and verifies `status = 'ready'`.

---

## Part 11 — Cleanup Contracts

### 11.1 `public.claim_moderation_media_cleanup`

```
public.claim_moderation_media_cleanup(p_batch_size int DEFAULT 10)
→ TABLE(media_object_id uuid, storage_key text, status text)
```

EXECUTE granted to `service_role`. Claims `rejected` or `removed` media objects that have no live pending report (covering both `target_type = 'media_object'` and challenge-level `inappropriate_image` reports), using `FOR UPDATE SKIP LOCKED` and a 10-minute lease:

```sql
CREATE OR REPLACE FUNCTION public.claim_moderation_media_cleanup(p_batch_size int DEFAULT 10)
RETURNS TABLE(media_object_id uuid, storage_key text, status text)
LANGUAGE sql SECURITY DEFINER SET search_path = ''
AS $$
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
  RETURNING
    mo.id AS media_object_id,
    (SELECT msk.re_encoded_storage_key
     FROM private.media_storage_keys msk
     WHERE msk.media_object_id = mo.id) AS storage_key,
    mo.status;
$$;
```

### 11.2 `public.mark_moderation_media_cleaned`

```
public.mark_moderation_media_cleaned(p_media_object_id uuid) → void
```

EXECUTE granted to `service_role`.

```sql
CREATE OR REPLACE FUNCTION public.mark_moderation_media_cleaned(p_media_object_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
  UPDATE public.media_objects
  SET status = 'cleaned', moderation_cleanup_leased_until = NULL
  WHERE id = p_media_object_id AND status IN ('rejected','removed');

  IF NOT FOUND THEN
    RAISE EXCEPTION 'FK_WRONG_STATE: media object not in a cleanable state';
  END IF;
END;
$$;
```

### 11.3 Cleanup worker procedure

```
1. Call claim_moderation_media_cleanup(10).
2. For each returned row:
   a. Delete storage object at storage_key from Supabase Storage.
   b. HTTP 200/204 response: call mark_moderation_media_cleaned(media_object_id).
   c. HTTP 404 (already gone): call mark_moderation_media_cleaned (treat as success).
   d. Any other error: log error; do not call mark_moderation_media_cleaned;
      lease expires after 10 minutes and row becomes re-claimable.
```

### 11.4 `private.cleanup_expired_evidence`

Owner: `forkensics_executor`. EXECUTE granted to `service_role` only. Scheduled daily.

```sql
CREATE OR REPLACE FUNCTION private.cleanup_expired_evidence()
RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path = ''
AS $$
  DELETE FROM private.moderation_evidence
  WHERE retained_until < clock_timestamp();
$$;
```

After expiry: `evidence_text` and `evidence_storage_key` values are deleted; the immutable `moderation_actions` row is retained permanently.

---

## Part 12 — Acceptance Test Matrix

### Note on enforcement order

PostgreSQL evaluates in this order: **column/table privilege check → RLS → triggers**. Tests reflect this:
- If the calling role lacks column-level UPDATE privilege, the result is `insufficient_privilege`. The trigger never fires.
- If the calling role has table UPDATE privilege but the row is blocked by RLS, the result is 0 rows updated. No exception is raised.
- Trigger exceptions (FK_COMMENT_IMMUTABLE, FK_REMOVAL_IMMUTABLE, etc.) are only reachable by a role with both the required column privilege and a row visible through RLS.
- To test trigger behavior directly when a role would normally be blocked by column privilege (T16.4, T16.5, T16.6b), use a dedicated `test_moderator_role` that is granted only the specific column inside a rolled-back transaction.

### T1 — Comment trigger (8 tests)

| # | Action | Enforcement layer | Expected |
|---|---|---|---|
| T1.1 | Authenticated author changes `text` | Column privilege | `insufficient_privilege` (authenticated lacks UPDATE on `text` column) |
| T1.2 | Non-author attempts UPDATE on `deleted_at` | RLS | 0 rows updated (non-author row not visible for UPDATE) |
| T1.3 | Author sets `deleted_at` (text, moderation fields unchanged) | Trigger Path 2 | Succeeds; `deleted_at` = server time |
| T1.4 | Author supplies past `deleted_at` value | Trigger Path 2 | `deleted_at` overridden to server time |
| T1.5 | `remove_content('comment')` via forkensics_executor | Trigger Path 1 | Succeeds; both moderator fields set atomically; `moderator_removed_at` = server time |
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

T3.1–T3.7: A blocks B; B queries clues/secrets/aliases/guess_attempts/guess_judgments/eligible_participants/exclusion_events for A's challenge → 0 rows each.
T3.8: B is eligible participant (carve-out) → rows returned.
T3.9: No block → returns normally.
T3.10: Non-poster querying draft → 0 rows.

### T4 — `media-serve` authorization (8 tests)

T4.1: Group member, no block → storage key → 200.
T4.2: A blocks B (poster) → empty set → 403.
T4.3: Outsider → empty → 403.
T4.4: Poster → key → 200.
T4.5: B eligible participant despite block → key → 200.
T4.6: Challenge moderator-removed → empty → 403.
T4.7: status = 'pending_review' → empty → 403.
T4.8: status = 'removed' → empty → 403.

### T5 — `report_content` media_object lock order (2 tests)

T5.1: `remove_media` holds challenge lock; concurrent `report_content('media_object')` → blocks on challenge lock; after remove commits: either linkage changed or status ≠ 'ready' → FK_NOT_FOUND.
T5.2: `report_content('media_object')` commits first; then `remove_media` runs → report captured in v_report_ids, bulk-actioned.

### T6 — Bulk report resolution + audit (7 tests)

T6.1: A and B report same comment → both actioned; 2 moderation_action_reports rows.
T6.2: A and B report same challenge → both actioned; 2 rows.
T6.3: A reports challenge; B reports linked media_object → both actioned; 2 rows.
T6.4: A and B reports via `remove_media` → both actioned; 2 rows.
T6.5: Single pending report → 1 row.
T6.6: Completeness — every actioned report has exactly one moderation_action_reports row.
T6.7: One dismissed, one pending; removal runs → pending actioned; dismissed unchanged; 1 new row.

### T7 — Concurrency (5 tests)

T7.1: Two moderators, same challenge, each holds one report → one full action; second takes idempotency path; no duplicate action/evidence; both reports actioned.
T7.2: Concurrent dismiss + remove_content for same report → lock serializes; clean outcome.
T7.3: `report_content` races `remove_content` on challenge → FK_NOT_FOUND if remove wins first; report actioned if report wins first; no stranded reports.
T7.4: Two identical `report_content` calls → dedup; both return same report_id.
T7.5: `remove_media`; poster re-uploaded between provisional read and challenge lock → FK_LINKAGE_CHANGED.

### T8 — Idempotency (8 tests)

T8.1: Challenge removed; `remove_content('challenge')` called again → idempotency path; new pending reports linked via `challenges.moderator_removal_action_id`.
T8.2: After removal; new `report_content` attempt → FK_NOT_FOUND.
T8.3: `remove_media` on media `status = 'removed'` → FK_WRONG_STATE.
T8.4: `remove_media` on media `status = 'rejected'` → FK_WRONG_STATE.
T8.5: Comment removed; `remove_content('comment')` called again → idempotency via `comments.moderator_removal_action_id`.
T8.6: Clue removed; `remove_content('clue')` called again → idempotency via `clues.moderator_removal_action_id`.
T8.7: Challenge removed via `remove_media`; then `remove_content('challenge')` called → `challenges.moderator_removed_at IS NOT NULL`; idempotency path reads `moderator_removal_action_id` (set by `remove_media`); links new pending reports to photo_removed action.
T8.8: `remove_content('challenge')` first; then `remove_media` on same challenge → `remove_media` locks challenge; idempotency path triggered; no new action.

### T9 — `p_report_id` validation (3 tests)

T9.1: Valid pending report targeting the exact subject → succeeds; `moderation_actions.report_id = p_report_id`.
T9.2: `p_report_id` targets a different challenge → FK_REPORT_TARGET_MISMATCH.
T9.3: `p_report_id = NULL` → proactive removal; NULL `moderation_actions.report_id`.

### T10 — `action_report` (4 tests)

T10.1: Valid substantive prior action, same subject → report actioned; moderation_action_reports row inserted.
T10.2: Prior action = 'report_dismissed' → FK_INVALID_PRIOR_ACTION.
T10.3: Prior action targets different challenge → FK_REPORT_TARGET_MISMATCH.
T10.4: No violation, no prior action → use `dismiss_report` instead.

### T11 — Suspension and comment-reporting visibility (12 tests)

T11.1: Suspended INSERT comment → RESTRICTIVE rejects.
T11.2: Suspended UPDATE challenge (draft) → RESTRICTIVE rejects.
T11.3: Suspended `redeem_group_invite` → FK_SUSPENDED.
T11.4: Suspended `cancel_challenge` → allowed.
T11.5: Suspended author soft-deletes own comment → allowed (trigger Path 2).
T11.6: Suspended exclusion `reason='removed'` → RESTRICTIVE rejects.
T11.7: Suspended exclusion `reason='withdrew'` → allowed.
T11.8: `transfer_group_ownership` to suspended recipient → FK_INVALID_RECIPIENT.
T11.8a: `transfer_group_ownership` happy path — caller is current owner; recipient is active, onboarded, unsuspended group member. After commit: caller's `group_members.role = 'member'`; recipient's `group_members.role = 'owner'`; exactly one `group_ownership_history` row exists with `previous_owner = caller_id` and `new_owner = recipient_id`; the `one_owner_per_group` partial unique index is satisfied (no two `role = 'owner'` rows for the group).
T11.9: Challenge poster reports a comment during active challenge → succeeds (poster branch).
T11.10: Current group member who has guessed reports a comment → succeeds.
T11.11: Former group member (no longer in group) attempts to report → FK_NOT_FOUND.
T11.12: Non-member who previously guessed → FK_NOT_FOUND.

### T12 — Block direction (4 tests)

T12.1: Viewer A blocks poster B → A cannot see B's challenges (viewer-blocks-poster direction).
T12.2: Poster B blocks viewer A → A cannot see B's challenges (poster-blocks-viewer direction; `has_block_with` catches this).
T12.3: A queries `user_blocks` for rows where they are `blocked_id` → 0 rows.
T12.4: A queries `user_blocks` for rows where they are `blocker_id` → own rows returned.

### T13 — SHA-256 integrity (4 tests)

T13.1: Valid 64-char lowercase hex → stored; constraint passes.
T13.2: NULL → FK_INVALID_HASH; no state change.
T13.3: Uppercase hex → FK_INVALID_HASH.
T13.4: Pre-V2 row with `sha256_hash IS NULL` → FK_MEDIA_METADATA_INCOMPLETE on moderation attempt.

### T14 — Cleanup hold (7 tests)

T14.1: A and B have pending reports on same media → not claimable.
T14.2: A's report dismissed → still not claimable (B's pending).
T14.3: B's report also dismissed → now claimable.
T14.4: Challenge `inappropriate_image` report pending → linked media not claimable.
T14.5: That report dismissed → media now claimable.
T14.6: `get_poster_media_status` with wrong `uploader_id` → no row returned.
T14.7: Correct `uploader_id`, status = 'rejected' → row with status and rejection_message.

### T15 — Clue visibility after removal (3 tests)

T15.1: `remove_content('clue')` → `clue.moderator_removed_at IS NOT NULL`; `moderator_removal_action_id` set.
T15.2: Authenticated queries removed clue → 0 rows (RESTRICTIVE policy).
T15.3: Service role (BYPASSRLS) queries removed clue → row returned; text preserved.

### T16 — Forge protection (7 tests)

| # | Role | Action | Enforcement layer | Expected |
|---|---|---|---|---|
| T16.1 | authenticated | INSERT challenge with `moderator_removed_at` set | INSERT forge-null trigger | Stored as NULL |
| T16.2 | authenticated | INSERT comment with `moderator_removal_action_id` set | INSERT forge-null trigger | Stored as NULL |
| T16.3 | authenticated | INSERT clue with both fields set | INSERT forge-null trigger | Both stored as NULL |
| T16.4 | test_moderator_role (granted UPDATE on `moderator_removed_at` in rolled-back txn) | UPDATE challenge: set `moderator_removed_at` | UPDATE guard trigger | FK_REMOVAL_UNAUTHORIZED |
| T16.5 | test_moderator_role (granted UPDATE on `moderator_removal_action_id` in rolled-back txn) | UPDATE clue: set `moderator_removal_action_id` | UPDATE guard trigger | FK_REMOVAL_UNAUTHORIZED |
| T16.6a | forkensics_executor | UPDATE challenge: set only `moderator_removed_at` (not `moderator_removal_action_id`) | CHECK constraint | check constraint violation (removes_consistency) |
| T16.6b | forkensics_executor | After valid first removal (both fields set); attempt to change `moderator_removed_at` | UPDATE guard trigger | FK_REMOVAL_IMMUTABLE |

### T17 — Role privilege isolation (8 tests)

| # | Role | Action | Expected |
|---|---|---|---|
| T17.1 | authenticated | `approve_photo(...)` | `insufficient_privilege` |
| T17.2 | authenticated | `remove_content(...)` | `insufficient_privilege` |
| T17.3 | authenticated | `get_media_serve_authorization(...)` | `insufficient_privilege` |
| T17.4 | anon | `report_content(...)` | `insufficient_privilege` |
| T17.5 | authenticated | `report_content(...)` (active, visible target) | Succeeds; returns report_id |
| T17.6 | authenticated | `SELECT * FROM public.content_reports` | `insufficient_privilege` (no SELECT grant) |
| T17.7 | authenticated | `SELECT * FROM public.user_blocks` (own rows) | Own rows returned |
| T17.8 | authenticated | `SELECT * FROM public.user_blocks WHERE blocked_id = auth_uid()` | 0 rows |

### T18 — Evidence cleanup (2 tests)

T18.1: Two evidence rows: one expired (`retained_until` in past), one unexpired; service_role calls `cleanup_expired_evidence()` → expired row deleted; unexpired row retained.
T18.2: authenticated calls `cleanup_expired_evidence()` → `insufficient_privilege`.

---

## Part 13 — Success Criteria

- [ ] Comment trigger: SECURITY INVOKER; Path 1 requires OLD/NEW.moderator_removal_action_id validation; server timestamp overrides; T1.x pass with correct enforcement-layer expectations
- [ ] `can_view_challenge()` enforces `posted_at IS NOT NULL` for non-posters; T2.x pass
- [ ] `private.can_viewer_access_challenge(uuid, uuid)` defined for service-role callers
- [ ] All new public tables: RLS enabled; ALL revoked from PUBLIC/anon/authenticated; SELECT on user_blocks re-granted to authenticated; content_reports/moderation_actions/group_ownership_history via functions only
- [ ] Migration execution order: schema → functions → triggers → Part 5 grants → RLS policies (Part 5 runs after all functions defined)
- [ ] forkensics_executor has EXECUTE on `can_view_challenge`, `can_viewer_access_challenge`, `auth_uid`, `is_challenge_revealed`, and all other V1 helpers called at runtime; T17.5 passes end-to-end
- [ ] forkensics_executor has SELECT, INSERT, DELETE on `private.moderation_evidence`; T18.x pass
- [ ] forkensics_rls_helper has SELECT on user_blocks and all challenge-linked tables
- [ ] authenticated has EXECUTE on approved RLS helpers and public functions only; T17.1–T17.4 pass
- [ ] service_role has EXECUTE on all service-only functions; authenticated explicitly revoked; T17.1–T17.3 pass
- [ ] `GRANT EXECUTE ON FUNCTION public.check_text_content(text) TO service_role` uses `TO` (not `FROM`); REVOKE from PUBLIC, anon, authenticated present
- [ ] `get_media_serve_authorization`: EXECUTE to service_role only; T4.x pass
- [ ] `media_object` target in `report_content`: challenge → media lock order with 6-step sequence; T5.x pass
- [ ] `report_content` ON CONFLICT uses column-list inference with `WHERE status = 'pending'` (not constraint name)
- [ ] `report_content` comment visibility: current group member AND (poster OR `private.is_challenge_revealed()` OR guessed); T11.9–T11.12 pass
- [ ] Removal functions: target → reports (ascending UUID) → media; exact pending-report queries per target type per Section 10.8/10.9
- [ ] `moderator_removal_action_id` set atomically in all removal functions; T8.5–T8.8 pass
- [ ] Universal idempotency path reads `moderator_removal_action_id`; `FK_STATE_INCONSISTENCY` if NULL; T8.1–T8.8 pass
- [ ] Consistency CHECK on challenges, comments, clues; T16.6a passes
- [ ] INSERT forge-null triggers on challenges, comments, clues; T16.1–T16.3 pass
- [ ] UPDATE guard on challenges and clues; T16.4–T16.5 tested via `test_moderator_role` in rolled-back txn
- [ ] T16.6b: `forkensics_executor` (or test role) verifies `FK_REMOVAL_IMMUTABLE` after valid removal
- [ ] `moderation_action_reports` UNIQUE(report_id); T6.6 passes
- [ ] `hide_blocked_challenges` uses `has_block_with(poster_id)` not direct query; T12.1–T12.2 pass
- [ ] `blocks_select_own` is `AS PERMISSIVE`; T12.3–T12.4 pass
- [ ] RESTRICTIVE SELECT on `public.clues`: `moderator_removed_at IS NULL`; T15.x pass
- [ ] `get_poster_media_status` requires `uploader_id = p_uploader_id` (V1 column name); T14.6–T14.7 pass
- [ ] `private.cleanup_expired_evidence`: owned by forkensics_executor; EXECUTE to service_role only; T18.x pass
- [ ] Deadlock-free; T7.x pass
- [ ] `redeem_group_invite` internal suspension guard; T11.3 passes
- [ ] `transfer_group_ownership` uses `group_members.role = 'owner'` (no `groups.owner_id`); group row locked first; INSERT into `group_ownership_history` before role swaps; both role UPDATEs in same transaction; T11.8 (suspended recipient rejected) and T11.8a (happy path: roles swap correctly, audit row correct, unique index satisfied) pass
- [ ] SHA-256 two-migration plan; T13.x pass
- [ ] Text-filter triggers on all UGC fields including `story`, `alias display_value`
- [ ] Cleanup hold covers both `media_object` and `inappropriate_image` report types; T14.1–T14.5 pass
- [ ] No executable SQL written until governance approval
