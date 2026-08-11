-- =============================================================================
-- V3__ugc_safety_moderation.sql
-- Step 24.1 Rev 15 — UGC Safety and Moderation Contracts
-- Governance: Approved by Bill + Codex (Step 24.1 Rev 15 spec)
-- Prerequisites: V1__initial_schema.sql and V2__upload_sessions.sql applied
-- =============================================================================

BEGIN;

-- =============================================================================
-- TEMPORARY ROLE GRANTS (OPEN)
-- Placed here — before the first CREATE OR REPLACE of any executor-owned function.
-- V1 revoked postgres membership in custom roles; restore temporarily for
-- CREATE OR REPLACE (role ownership check) and ALTER FUNCTION OWNER TO.
-- Revoked before COMMIT in Part 5.7.
-- =============================================================================
GRANT forkensics_executor   TO postgres;
GRANT forkensics_rls_helper TO postgres;
GRANT CREATE ON SCHEMA private TO forkensics_executor, forkensics_rls_helper;
GRANT CREATE ON SCHEMA public  TO forkensics_executor;

-- =============================================================================
-- PART 3 — SCHEMA
-- Execution order: schema first, before functions and RLS policies
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 3.1  public.profiles — is_suspended column
-- ---------------------------------------------------------------------------
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS is_suspended boolean NOT NULL DEFAULT false;

-- ---------------------------------------------------------------------------
-- 3.2  public.content_reports
-- ---------------------------------------------------------------------------
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

-- Partial unique index — ON CONFLICT must use column-list inference,
-- NOT constraint name (partial indexes are not named constraints in PG).
CREATE UNIQUE INDEX IF NOT EXISTS content_reports_unresolved_dedup
  ON public.content_reports (reporter_id, target_type, target_id, category)
  WHERE status = 'pending';

CREATE INDEX IF NOT EXISTS idx_content_reports_status_created_at
  ON public.content_reports (status, created_at);
CREATE INDEX IF NOT EXISTS idx_content_reports_reporter_id
  ON public.content_reports (reporter_id);
CREATE INDEX IF NOT EXISTS idx_content_reports_pending_target
  ON public.content_reports (target_type, target_id)
  WHERE status = 'pending';

-- ---------------------------------------------------------------------------
-- 3.3  public.user_blocks
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.user_blocks (
  blocker_id  uuid        NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  blocked_id  uuid        NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  created_at  timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY (blocker_id, blocked_id),
  CONSTRAINT user_blocks_no_self_block CHECK (blocker_id != blocked_id)
);

CREATE INDEX IF NOT EXISTS idx_user_blocks_blocked_id
  ON public.user_blocks (blocked_id);

-- ---------------------------------------------------------------------------
-- 3.4  public.moderation_actions
-- ---------------------------------------------------------------------------
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

CREATE INDEX IF NOT EXISTS idx_moderation_actions_target
  ON public.moderation_actions (target_type, target_id);
CREATE INDEX IF NOT EXISTS idx_moderation_actions_moderator_created_at
  ON public.moderation_actions (moderator_id, created_at);

-- ---------------------------------------------------------------------------
-- 3.5  private.moderation_action_reports
-- ---------------------------------------------------------------------------
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

CREATE INDEX IF NOT EXISTS idx_moderation_action_reports_report_id
  ON private.moderation_action_reports (report_id);

-- ---------------------------------------------------------------------------
-- 3.6  private.blocked_terms
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS private.blocked_terms (
  id        uuid  PRIMARY KEY DEFAULT gen_random_uuid(),
  term      text  NOT NULL UNIQUE,
  added_at  timestamptz NOT NULL DEFAULT clock_timestamp(),
  added_by  text  NOT NULL,
  CONSTRAINT blocked_terms_term_check CHECK (length(trim(term)) BETWEEN 1 AND 100)
);

-- ---------------------------------------------------------------------------
-- 3.7  private.moderators
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS private.moderators (
  profile_id  uuid PRIMARY KEY REFERENCES public.profiles(id) ON DELETE RESTRICT,
  added_at    timestamptz NOT NULL DEFAULT clock_timestamp()
);

-- ---------------------------------------------------------------------------
-- 3.8  private.profile_suspensions
-- ---------------------------------------------------------------------------
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

-- Blocker 7: Backfill existing profiles into profile_suspensions.
-- Must run immediately after table creation so all current profiles have a row.
INSERT INTO private.profile_suspensions (profile_id)
SELECT id FROM public.profiles
ON CONFLICT (profile_id) DO NOTHING;

-- ---------------------------------------------------------------------------
-- 3.9  private.moderation_evidence
-- ---------------------------------------------------------------------------
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

CREATE INDEX IF NOT EXISTS idx_moderation_evidence_retained_until
  ON private.moderation_evidence (retained_until);

-- ---------------------------------------------------------------------------
-- 3.10  Column additions to existing tables
-- ---------------------------------------------------------------------------

-- Moderator removal timestamps
ALTER TABLE public.challenges
  ADD COLUMN IF NOT EXISTS moderator_removed_at timestamptz;
ALTER TABLE public.comments
  ADD COLUMN IF NOT EXISTS moderator_removed_at timestamptz;
ALTER TABLE public.clues
  ADD COLUMN IF NOT EXISTS moderator_removed_at timestamptz;

-- Durable idempotency references (server-owned; forge-protection in Part 6)
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

-- Media cleanup fields (media_objects)
ALTER TABLE public.media_objects
  ADD COLUMN IF NOT EXISTS moderated_at                    timestamptz,
  ADD COLUMN IF NOT EXISTS moderation_cleanup_leased_until timestamptz;

-- ---------------------------------------------------------------------------
-- 3.11  private.media_storage_keys — sha256_hash NOT NULL (V2b enforcement)
-- V2a (add nullable column + format constraint) was done in V2__upload_sessions.sql.
-- This step enforces NOT NULL once all rows are backfilled.
-- Before applying: verify SELECT count(*) FROM private.media_storage_keys
--                  WHERE sha256_hash IS NULL  → must return 0.
-- ---------------------------------------------------------------------------
ALTER TABLE private.media_storage_keys
  ALTER COLUMN sha256_hash SET NOT NULL;

-- ---------------------------------------------------------------------------
-- 3.12  public.group_ownership_history
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.group_ownership_history (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  group_id        uuid        NOT NULL REFERENCES public.groups(id) ON DELETE RESTRICT,
  previous_owner  uuid        NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  new_owner       uuid        NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  transferred_at  timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE INDEX IF NOT EXISTS idx_group_ownership_history_group_id
  ON public.group_ownership_history (group_id);

-- ---------------------------------------------------------------------------
-- 3.13  Immutability trigger function (moderation_actions, moderation_action_reports,
--        group_ownership_history)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.enforce_record_immutability()
RETURNS trigger LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
BEGIN
  RAISE EXCEPTION 'FK_ACTION_IMMUTABLE: this record cannot be modified or deleted';
END;
$$;

CREATE TRIGGER moderation_actions_immutable
  BEFORE UPDATE OR DELETE ON public.moderation_actions
  FOR EACH ROW EXECUTE FUNCTION private.enforce_record_immutability();

CREATE TRIGGER moderation_action_reports_immutable
  BEFORE UPDATE OR DELETE ON private.moderation_action_reports
  FOR EACH ROW EXECUTE FUNCTION private.enforce_record_immutability();

CREATE TRIGGER group_ownership_history_immutable
  BEFORE UPDATE OR DELETE ON public.group_ownership_history
  FOR EACH ROW EXECUTE FUNCTION private.enforce_record_immutability();

-- =============================================================================
-- PART 4 — RLS ENABLEMENT AND TABLE PRIVILEGE GRANTS
-- =============================================================================

ALTER TABLE public.content_reports         ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_blocks             ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.moderation_actions      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.group_ownership_history ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.content_reports         FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.user_blocks             FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.moderation_actions      FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.group_ownership_history FROM PUBLIC, anon, authenticated;

-- user_blocks: authenticated SELECT only (own rows via PERMISSIVE policy)
GRANT SELECT ON public.user_blocks TO authenticated;

-- content_reports, moderation_actions, group_ownership_history:
-- no direct authenticated access; all access via SECURITY DEFINER functions

-- =============================================================================
-- PART 2 — V1 TRIGGER REPLACEMENT
-- =============================================================================

-- 2.1  public.restrict_comment_updates — complete replacement
-- SECURITY INVOKER so current_user reflects the actual caller.
-- Trigger attachment unchanged (BEFORE UPDATE ON public.comments FOR EACH ROW).
CREATE OR REPLACE FUNCTION public.restrict_comment_updates()
RETURNS trigger LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
BEGIN
  -- Path 1: Moderator removal — only forkensics_executor.
  -- Both fields transition NULL → non-NULL together.
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

-- =============================================================================
-- PART 7 — RLS HELPER FUNCTIONS
-- All: SECURITY DEFINER, SET search_path = '', STABLE
-- Ownership set in Part 5.
-- =============================================================================

-- 7.1  private.can_view_challenge(p_challenge_id uuid) → boolean
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

-- 7.2  private.can_viewer_access_challenge(p_challenge_id uuid, p_viewer_id uuid) → boolean
-- For service-role callers where auth_uid() returns NULL.
CREATE OR REPLACE FUNCTION private.can_viewer_access_challenge(
  p_challenge_id uuid,
  p_viewer_id    uuid
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

-- 7.3  private.has_block_with(p_profile_id uuid) → boolean
-- SECURITY DEFINER — sees both block directions regardless of caller's SELECT privileges.
CREATE OR REPLACE FUNCTION private.has_block_with(p_profile_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.user_blocks
    WHERE (blocker_id = private.auth_uid() AND blocked_id = p_profile_id)
       OR (blocker_id = p_profile_id    AND blocked_id = private.auth_uid())
  );
$$;

-- 7.4  private.has_block_with_poster(p_challenge_id uuid) → boolean
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

-- =============================================================================
-- PART 8 — TEXT FILTERING
-- =============================================================================

-- 8.1  private.check_text_content_trigger() — trigger function
-- SECURITY DEFINER to access private.blocked_terms. No caller bypass.
-- Fail-closed TG_ARGV design: every trigger attachment must pass the column name
-- as TG_ARGV[0]. The function rejects any pairing not in the approved list and uses
-- to_jsonb(NEW) for field extraction to avoid compile-time binding issues with
-- polymorphic NEW records across multiple tables.
CREATE OR REPLACE FUNCTION private.check_text_content_trigger()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_col  text;
  v_text text;
BEGIN
  -- Fail closed: exactly one argument (the column name to filter) is required.
  IF TG_NARGS <> 1 THEN
    RAISE EXCEPTION
      'check_text_content_trigger: expected 1 argument (column name), got %', TG_NARGS;
  END IF;

  v_col := TG_ARGV[0];

  -- Fail closed: only approved (schema, table, column) triples are permitted.
  IF NOT (
       TG_TABLE_SCHEMA = 'public'
    AND (
         (TG_TABLE_NAME = 'comments'                 AND v_col = 'text')
      OR (TG_TABLE_NAME = 'clues'                    AND v_col = 'text')
      OR (TG_TABLE_NAME = 'profiles'                 AND v_col = 'display_name')
      OR (TG_TABLE_NAME = 'groups'                   AND v_col = 'name')
      OR (TG_TABLE_NAME = 'challenges'               AND v_col = 'public_city_display')
      OR (TG_TABLE_NAME = 'challenge_secrets'        AND v_col IN ('display_dish','display_restaurant','story'))
      OR (TG_TABLE_NAME = 'challenge_answer_aliases' AND v_col = 'display_value')
    )
  ) THEN
    RAISE EXCEPTION
      'check_text_content_trigger: unauthorized pairing schema=% table=% col=%',
      TG_TABLE_SCHEMA, TG_TABLE_NAME, v_col;
  END IF;

  -- Fail closed: verify the column actually exists on this row type before extracting.
  -- A misconfigured trigger argument would otherwise silently yield NULL and bypass filtering.
  IF NOT (to_jsonb(NEW) ? v_col) THEN
    RAISE EXCEPTION
      'check_text_content_trigger: column % not found on table %.%',
      v_col, TG_TABLE_SCHEMA, TG_TABLE_NAME;
  END IF;

  -- Safely extract the field value via jsonb; avoids NEW.<field> compile-time
  -- binding failure when the trigger fires on tables that lack that column.
  v_text := to_jsonb(NEW) ->> v_col;

  -- NULL passes through (nullable columns are permitted to hold NULL).
  IF v_text IS NULL THEN RETURN NEW; END IF;

  -- Case-insensitive substring match against the blocked-terms list.
  IF EXISTS (
    SELECT 1 FROM private.blocked_terms
    WHERE position(lower(term) IN lower(v_text)) > 0
  ) THEN
    RAISE EXCEPTION 'FK_CONTENT_FILTERED: content contains a blocked term';
  END IF;

  RETURN NEW;
END;
$$;

-- 8.2  public.check_text_content(p_text text) → boolean
-- Early validation for Edge Functions. Returns true if no blocked term found.
-- The trigger is the authoritative enforcement point.
CREATE OR REPLACE FUNCTION public.check_text_content(p_text text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT NOT EXISTS (
    SELECT 1 FROM private.blocked_terms
    WHERE position(lower(term) IN lower(p_text)) > 0
  );
$$;

-- =============================================================================
-- PART 10 — SECURITY DEFINER FUNCTIONS
-- All: owned by forkensics_executor (set in Part 5), SET search_path = ''
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 10.3  public.report_content
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.report_content(
  p_target_type text,
  p_target_id   uuid,
  p_category    text,
  p_detail      text
) RETURNS TABLE(report_id uuid)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_caller_id      uuid;
  v_report_id      uuid;
  v_challenge_id   uuid;
  v_challenge      record;
  v_comment        record;
  v_clue           record;
  v_media          record;
  v_pending_count  integer;
  v_content_author uuid;
BEGIN
  v_caller_id := private.auth_uid();

  -- 1. Verify caller is active and onboarded (suspended callers permitted to report)
  IF NOT EXISTS (
    SELECT 1 FROM public.profiles
    WHERE id = v_caller_id AND is_active = true AND onboarding_complete = true
  ) THEN RAISE EXCEPTION 'FK_UNAUTHORIZED'; END IF;

  -- 2. Validate target_type and category
  IF p_target_type NOT IN ('challenge','comment','clue','profile','media_object') THEN
    RAISE EXCEPTION 'FK_INVALID_INPUT: invalid target_type';
  END IF;
  IF p_category NOT IN ('inappropriate_image','offensive_content','spam',
                         'harassment','copyright','other') THEN
    RAISE EXCEPTION 'FK_INVALID_INPUT: invalid category';
  END IF;

  -- 3. Rate limit: max 10 pending reports per hour
  SELECT count(*) INTO v_pending_count
  FROM public.content_reports
  WHERE reporter_id = v_caller_id
    AND status = 'pending'
    AND created_at > clock_timestamp() - interval '1 hour';
  IF v_pending_count >= 10 THEN
    RAISE EXCEPTION 'FK_RATE_LIMITED';
  END IF;

  -- 4. Lock and recheck target; capture content author for self-report check
  IF p_target_type = 'challenge' THEN
    SELECT id, moderator_removed_at, poster_id INTO v_challenge
    FROM public.challenges WHERE id = p_target_id FOR UPDATE;
    IF NOT FOUND OR v_challenge.moderator_removed_at IS NOT NULL
       OR NOT private.can_view_challenge(p_target_id) THEN
      RAISE EXCEPTION 'FK_NOT_FOUND';
    END IF;
    v_content_author := v_challenge.poster_id;

  ELSIF p_target_type = 'comment' THEN
    SELECT id, challenge_id, moderator_removed_at, author_id INTO v_comment
    FROM public.comments WHERE id = p_target_id FOR UPDATE;
    IF NOT FOUND OR v_comment.moderator_removed_at IS NOT NULL THEN
      RAISE EXCEPTION 'FK_NOT_FOUND';
    END IF;
    -- Check caller is current group member
    SELECT id, group_id, poster_id INTO v_challenge
    FROM public.challenges WHERE id = v_comment.challenge_id;
    IF NOT EXISTS (
      SELECT 1 FROM public.group_members
      WHERE group_id = v_challenge.group_id AND player_id = v_caller_id
    ) THEN RAISE EXCEPTION 'FK_NOT_FOUND'; END IF;
    -- Check Table Talk visibility: poster OR revealed OR guessed
    IF NOT (
      v_challenge.poster_id = v_caller_id
      OR private.is_challenge_revealed(v_comment.challenge_id)
      OR EXISTS (
        SELECT 1 FROM public.guess_attempts
        WHERE challenge_id = v_comment.challenge_id AND player_id = v_caller_id
      )
    ) THEN RAISE EXCEPTION 'FK_NOT_FOUND'; END IF;
    v_content_author := v_comment.author_id;

  ELSIF p_target_type = 'clue' THEN
    SELECT id, challenge_id, moderator_removed_at INTO v_clue
    FROM public.clues WHERE id = p_target_id FOR UPDATE;
    IF NOT FOUND OR v_clue.moderator_removed_at IS NOT NULL
       OR NOT private.can_view_challenge(v_clue.challenge_id) THEN
      RAISE EXCEPTION 'FK_NOT_FOUND';
    END IF;
    SELECT poster_id INTO v_content_author FROM public.challenges
    WHERE id = v_clue.challenge_id;

  ELSIF p_target_type = 'media_object' THEN
    -- Six-step sequence matching remove_media lock order
    -- a. Provisional challenge read
    SELECT id INTO v_challenge_id FROM public.challenges
    WHERE media_object_id = p_target_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'FK_NOT_FOUND'; END IF;
    -- b. Lock challenge
    SELECT id, media_object_id INTO v_challenge
    FROM public.challenges WHERE id = v_challenge_id FOR UPDATE;
    -- c. Re-verify linkage (IS DISTINCT FROM handles NULL safely)
    IF v_challenge.media_object_id IS DISTINCT FROM p_target_id THEN RAISE EXCEPTION 'FK_NOT_FOUND'; END IF;
    -- d. Re-check viewer access
    IF NOT private.can_view_challenge(v_challenge_id) THEN RAISE EXCEPTION 'FK_NOT_FOUND'; END IF;
    -- e. Lock media
    SELECT id, status, uploader_id INTO v_media
    FROM public.media_objects WHERE id = p_target_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'FK_NOT_FOUND'; END IF;
    -- f. Verify ready
    IF v_media.status != 'ready' THEN RAISE EXCEPTION 'FK_NOT_FOUND'; END IF;
    v_content_author := v_media.uploader_id;

  ELSIF p_target_type = 'profile' THEN
    -- Verify target is active
    IF NOT EXISTS (
      SELECT 1 FROM public.profiles WHERE id = p_target_id AND is_active = true
    ) THEN RAISE EXCEPTION 'FK_NOT_FOUND'; END IF;
    -- Verify caller shares at least one group with target (no row lock needed)
    IF NOT EXISTS (
      SELECT 1 FROM public.group_members gm1
      JOIN public.group_members gm2 ON gm1.group_id = gm2.group_id
      WHERE gm1.player_id = v_caller_id AND gm2.player_id = p_target_id
    ) THEN RAISE EXCEPTION 'FK_NOT_FOUND'; END IF;
    v_content_author := p_target_id;
  END IF;

  -- 5. Prevent self-report
  IF v_content_author = v_caller_id THEN
    RAISE EXCEPTION 'FK_SELF_REPORT';
  END IF;

  -- 6. Insert with partial-index dedup
  INSERT INTO public.content_reports
    (reporter_id, target_type, target_id, category, detail)
  VALUES
    (v_caller_id, p_target_type, p_target_id, p_category, p_detail)
  ON CONFLICT (reporter_id, target_type, target_id, category)
  WHERE status = 'pending'
  DO NOTHING
  RETURNING id INTO v_report_id;

  IF v_report_id IS NULL THEN
    SELECT id INTO v_report_id FROM public.content_reports
    WHERE reporter_id = v_caller_id
      AND target_type = p_target_type
      AND target_id   = p_target_id
      AND category    = p_category
      AND status      = 'pending';
  END IF;

  -- 7. Return
  RETURN QUERY SELECT v_report_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- 10.4  public.block_user(p_blocked_id uuid) → void
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.block_user(p_blocked_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
  -- Suspended callers permitted
  IF NOT EXISTS (
    SELECT 1 FROM public.profiles WHERE id = private.auth_uid() AND is_active = true
  ) THEN RAISE EXCEPTION 'FK_UNAUTHORIZED'; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.profiles WHERE id = p_blocked_id
  ) THEN RAISE EXCEPTION 'FK_NOT_FOUND'; END IF;

  IF p_blocked_id = private.auth_uid() THEN
    RAISE EXCEPTION 'FK_SELF_BLOCK';
  END IF;

  INSERT INTO public.user_blocks (blocker_id, blocked_id)
  VALUES (private.auth_uid(), p_blocked_id)
  ON CONFLICT DO NOTHING;
END;
$$;

-- ---------------------------------------------------------------------------
-- 10.5  public.unblock_user(p_blocked_id uuid) → void
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.unblock_user(p_blocked_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
  DELETE FROM public.user_blocks
  WHERE blocker_id = private.auth_uid() AND blocked_id = p_blocked_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- 10.6  public.approve_photo
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.approve_photo(
  p_media_object_id uuid,
  p_moderator_id    uuid,
  p_reason          text
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_media    record;
  v_action_id uuid;
BEGIN
  -- 1. Validate moderator
  IF NOT EXISTS (
    SELECT 1 FROM private.moderators m
    JOIN public.profiles p ON p.id = m.profile_id
    WHERE m.profile_id = p_moderator_id AND p.is_active = true
  ) THEN RAISE EXCEPTION 'FK_UNAUTHORIZED: moderator identity not valid'; END IF;

  -- 2. Lock media
  SELECT id, status INTO v_media
  FROM public.media_objects WHERE id = p_media_object_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'FK_NOT_FOUND'; END IF;
  IF v_media.status != 'pending_review' THEN
    RAISE EXCEPTION 'FK_WRONG_STATE: media is not pending_review (status: %)', v_media.status;
  END IF;

  -- 3. Insert action
  INSERT INTO public.moderation_actions
    (moderator_id, action_type, target_type, target_id, reason)
  VALUES
    (p_moderator_id, 'photo_approved', 'media_object', p_media_object_id, p_reason)
  RETURNING id INTO v_action_id;

  -- 4. Update media
  UPDATE public.media_objects
  SET status = 'ready', moderated_at = clock_timestamp()
  WHERE id = p_media_object_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- 10.7  public.reject_photo
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.reject_photo(
  p_media_object_id uuid,
  p_moderator_id    uuid,
  p_reason          text
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_media      record;
  v_action_id  uuid;
  v_sha256     text;
  v_storage_key text;
BEGIN
  -- 1. Validate moderator
  IF NOT EXISTS (
    SELECT 1 FROM private.moderators m
    JOIN public.profiles p ON p.id = m.profile_id
    WHERE m.profile_id = p_moderator_id AND p.is_active = true
  ) THEN RAISE EXCEPTION 'FK_UNAUTHORIZED: moderator identity not valid'; END IF;

  -- 2. Lock media; verify pending_review
  SELECT id, status INTO v_media
  FROM public.media_objects WHERE id = p_media_object_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'FK_NOT_FOUND'; END IF;
  IF v_media.status != 'pending_review' THEN
    RAISE EXCEPTION 'FK_WRONG_STATE: media is not pending_review (status: %)', v_media.status;
  END IF;

  -- 3. Read SHA-256
  SELECT sha256_hash, re_encoded_storage_key INTO v_sha256, v_storage_key
  FROM private.media_storage_keys WHERE media_object_id = p_media_object_id;
  IF v_sha256 IS NULL THEN RAISE EXCEPTION 'FK_MEDIA_METADATA_INCOMPLETE'; END IF;

  -- 4. Insert action
  INSERT INTO public.moderation_actions
    (moderator_id, action_type, target_type, target_id, reason)
  VALUES
    (p_moderator_id, 'photo_rejected', 'media_object', p_media_object_id, p_reason)
  RETURNING id INTO v_action_id;

  -- 5. Insert evidence
  INSERT INTO private.moderation_evidence
    (moderation_action_id, evidence_type, evidence_storage_key, evidence_sha256)
  VALUES
    (v_action_id, 'media_metadata', v_storage_key, v_sha256);

  -- 6. Update media
  UPDATE public.media_objects
  SET status = 'rejected', moderated_at = clock_timestamp()
  WHERE id = p_media_object_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- 10.8  public.remove_content
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.remove_content(
  p_target_type  text,
  p_target_id    uuid,
  p_moderator_id uuid,
  p_report_id    uuid,
  p_reason       text
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_challenge          record;
  v_comment            record;
  v_clue               record;
  v_media              record;
  v_action_id          uuid;
  v_existing_action_id uuid;
  v_report_ids         uuid[];
  v_new_report_ids     uuid[];
  v_media_object_id    uuid;
  v_sha256             text;
  v_storage_key        text;
BEGIN
  -- Validate moderator (Section 10.1)
  IF NOT EXISTS (
    SELECT 1 FROM private.moderators m
    JOIN public.profiles p ON p.id = m.profile_id
    WHERE m.profile_id = p_moderator_id AND p.is_active = true
  ) THEN RAISE EXCEPTION 'FK_UNAUTHORIZED: moderator identity not valid'; END IF;

  IF p_target_type NOT IN ('challenge','comment','clue') THEN
    RAISE EXCEPTION 'FK_INVALID_INPUT: remove_content target_type must be challenge, comment, or clue';
  END IF;

  -- -------------------------------------------------------------------------
  IF p_target_type = 'challenge' THEN
  -- -------------------------------------------------------------------------

    -- Step 2: Lock challenge
    SELECT id, state, media_object_id, moderator_removed_at, moderator_removal_action_id
    INTO v_challenge
    FROM public.challenges WHERE id = p_target_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'FK_NOT_FOUND'; END IF;

    -- Step 3: Idempotency path (Section 10.11)
    IF v_challenge.moderator_removed_at IS NOT NULL THEN
      v_existing_action_id := v_challenge.moderator_removal_action_id;
      IF v_existing_action_id IS NULL THEN
        RAISE EXCEPTION 'FK_STATE_INCONSISTENCY: target removed but action pointer is NULL';
      END IF;
      -- Lock new pending reports (challenge + media_object scope)
      SELECT array_agg(locked.id ORDER BY locked.id) INTO v_new_report_ids
      FROM (
        SELECT cr.id
        FROM public.content_reports cr
        WHERE cr.status = 'pending'
          AND (
            (cr.target_type = 'challenge' AND cr.target_id = p_target_id)
            OR (cr.target_type = 'media_object'
                AND cr.target_id = v_challenge.media_object_id
                AND v_challenge.media_object_id IS NOT NULL)
          )
        ORDER BY cr.id
        FOR UPDATE
      ) AS locked;
      IF v_new_report_ids IS NOT NULL THEN
        INSERT INTO private.moderation_action_reports (moderation_action_id, report_id)
        SELECT v_existing_action_id, id FROM unnest(v_new_report_ids) AS t(id)
        ON CONFLICT ON CONSTRAINT moderation_action_reports_one_resolution DO NOTHING;
        IF EXISTS (
          SELECT 1 FROM private.moderation_action_reports
          WHERE report_id = ANY(v_new_report_ids)
            AND moderation_action_id != v_existing_action_id
        ) THEN RAISE EXCEPTION 'FK_RESOLUTION_CONFLICT'; END IF;
        UPDATE public.content_reports
        SET status = 'actioned', reviewed_at = clock_timestamp(), reviewed_by = p_moderator_id
        WHERE id = ANY(v_new_report_ids);
      END IF;
      RETURN;
    END IF;

    v_media_object_id := v_challenge.media_object_id;

    -- Step 6: Lock all matching pending reports (ascending UUID)
    SELECT array_agg(locked.id ORDER BY locked.id) INTO v_report_ids
    FROM (
      SELECT cr.id
      FROM public.content_reports cr
      WHERE cr.status = 'pending'
        AND (
          (cr.target_type = 'challenge' AND cr.target_id = p_target_id)
          OR (cr.target_type = 'media_object'
              AND cr.target_id = v_media_object_id
              AND v_media_object_id IS NOT NULL)
        )
      ORDER BY cr.id
      FOR UPDATE
    ) AS locked;

    -- Step 7: Verify p_report_id if supplied
    IF p_report_id IS NOT NULL AND
       NOT (p_report_id = ANY(COALESCE(v_report_ids, ARRAY[]::uuid[]))) THEN
      RAISE EXCEPTION 'FK_REPORT_TARGET_MISMATCH';
    END IF;

    -- Steps 8-9: Lock media, validate state, read SHA-256
    IF v_media_object_id IS NOT NULL THEN
      SELECT id, status INTO v_media
      FROM public.media_objects WHERE id = v_media_object_id FOR UPDATE;
      IF v_media.status IN ('processing','failed') THEN
        RAISE EXCEPTION 'FK_WRONG_STATE: media is in non-actionable state: %', v_media.status;
      END IF;
      IF v_media.status NOT IN ('removed','cleaned') THEN
        SELECT sha256_hash, re_encoded_storage_key INTO v_sha256, v_storage_key
        FROM private.media_storage_keys WHERE media_object_id = v_media_object_id;
        IF v_sha256 IS NULL THEN RAISE EXCEPTION 'FK_MEDIA_METADATA_INCOMPLETE'; END IF;
      END IF;
    END IF;

    -- Step 10: INSERT moderation_actions
    INSERT INTO public.moderation_actions
      (moderator_id, action_type, target_type, target_id, report_id, reason)
    VALUES
      (p_moderator_id, 'content_removed', 'challenge', p_target_id, p_report_id, p_reason)
    RETURNING id INTO v_action_id;

    -- Step 11: INSERT evidence (only if we have media metadata)
    IF v_storage_key IS NOT NULL THEN
      INSERT INTO private.moderation_evidence
        (moderation_action_id, evidence_type, evidence_storage_key, evidence_sha256)
      VALUES
        (v_action_id, 'media_metadata', v_storage_key, v_sha256);
    END IF;

    -- Step 12: UPDATE challenges per state matrix; set action pointer atomically
    IF v_challenge.state IN ('draft','active','locked') THEN
      UPDATE public.challenges
      SET state = 'cancelled',
          cancellation_reason = 'moderation_action',
          moderator_removed_at = clock_timestamp(),
          moderator_removal_action_id = v_action_id
      WHERE id = p_target_id;
    ELSE
      -- revealed or already cancelled
      UPDATE public.challenges
      SET moderator_removed_at = clock_timestamp(),
          moderator_removal_action_id = v_action_id
      WHERE id = p_target_id;
    END IF;

    -- Step 13: UPDATE media per state matrix
    IF v_media_object_id IS NOT NULL AND v_media.status NOT IN ('removed','cleaned') THEN
      UPDATE public.media_objects
      SET status = 'removed', moderated_at = clock_timestamp()
      WHERE id = v_media_object_id;
    END IF;

    -- Steps 14-15: Link and action reports
    IF v_report_ids IS NOT NULL THEN
      INSERT INTO private.moderation_action_reports (moderation_action_id, report_id)
      SELECT v_action_id, id FROM unnest(v_report_ids) AS t(id);
      UPDATE public.content_reports
      SET status = 'actioned', reviewed_at = clock_timestamp(), reviewed_by = p_moderator_id
      WHERE id = ANY(v_report_ids);
    END IF;

  -- -------------------------------------------------------------------------
  ELSIF p_target_type = 'comment' THEN
  -- -------------------------------------------------------------------------

    -- Step 2: Lock comment
    SELECT id, text, challenge_id, moderator_removed_at, moderator_removal_action_id
    INTO v_comment
    FROM public.comments WHERE id = p_target_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'FK_NOT_FOUND'; END IF;

    -- Step 3: Idempotency
    IF v_comment.moderator_removed_at IS NOT NULL THEN
      v_existing_action_id := v_comment.moderator_removal_action_id;
      IF v_existing_action_id IS NULL THEN
        RAISE EXCEPTION 'FK_STATE_INCONSISTENCY: target removed but action pointer is NULL';
      END IF;
      SELECT array_agg(locked.id ORDER BY locked.id) INTO v_new_report_ids
      FROM (
        SELECT cr.id
        FROM public.content_reports cr
        WHERE cr.target_type = 'comment' AND cr.target_id = p_target_id AND cr.status = 'pending'
        ORDER BY cr.id
        FOR UPDATE
      ) AS locked;
      IF v_new_report_ids IS NOT NULL THEN
        INSERT INTO private.moderation_action_reports (moderation_action_id, report_id)
        SELECT v_existing_action_id, id FROM unnest(v_new_report_ids) AS t(id)
        ON CONFLICT ON CONSTRAINT moderation_action_reports_one_resolution DO NOTHING;
        IF EXISTS (
          SELECT 1 FROM private.moderation_action_reports
          WHERE report_id = ANY(v_new_report_ids)
            AND moderation_action_id != v_existing_action_id
        ) THEN RAISE EXCEPTION 'FK_RESOLUTION_CONFLICT'; END IF;
        UPDATE public.content_reports
        SET status = 'actioned', reviewed_at = clock_timestamp(), reviewed_by = p_moderator_id
        WHERE id = ANY(v_new_report_ids);
      END IF;
      RETURN;
    END IF;

    -- Step 3: Lock all matching pending reports
    SELECT array_agg(locked.id ORDER BY locked.id) INTO v_report_ids
    FROM (
      SELECT cr.id
      FROM public.content_reports cr
      WHERE cr.target_type = 'comment' AND cr.target_id = p_target_id AND cr.status = 'pending'
      ORDER BY cr.id
      FOR UPDATE
    ) AS locked;

    -- Step 4: Verify p_report_id
    IF p_report_id IS NOT NULL AND
       NOT (p_report_id = ANY(COALESCE(v_report_ids, ARRAY[]::uuid[]))) THEN
      RAISE EXCEPTION 'FK_REPORT_TARGET_MISMATCH';
    END IF;

    -- Step 5: INSERT moderation_actions
    INSERT INTO public.moderation_actions
      (moderator_id, action_type, target_type, target_id, report_id, reason)
    VALUES
      (p_moderator_id, 'content_removed', 'comment', p_target_id, p_report_id, p_reason)
    RETURNING id INTO v_action_id;

    -- Step 6: INSERT evidence (original text before replacement)
    INSERT INTO private.moderation_evidence
      (moderation_action_id, evidence_type, evidence_text)
    VALUES
      (v_action_id, 'comment_text', v_comment.text);

    -- Step 7: UPDATE comment (trigger enforces server timestamp + path validation)
    UPDATE public.comments
    SET text = '[removed by moderator]',
        moderator_removed_at = clock_timestamp(),
        moderator_removal_action_id = v_action_id
    WHERE id = p_target_id;

    -- Steps 8-9: Link and action reports
    IF v_report_ids IS NOT NULL THEN
      INSERT INTO private.moderation_action_reports (moderation_action_id, report_id)
      SELECT v_action_id, id FROM unnest(v_report_ids) AS t(id);
      UPDATE public.content_reports
      SET status = 'actioned', reviewed_at = clock_timestamp(), reviewed_by = p_moderator_id
      WHERE id = ANY(v_report_ids);
    END IF;

  -- -------------------------------------------------------------------------
  ELSIF p_target_type = 'clue' THEN
  -- -------------------------------------------------------------------------

    -- Step 2: Lock clue
    SELECT id, text, challenge_id, moderator_removed_at, moderator_removal_action_id
    INTO v_clue
    FROM public.clues WHERE id = p_target_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'FK_NOT_FOUND'; END IF;

    -- Step 3: Idempotency
    IF v_clue.moderator_removed_at IS NOT NULL THEN
      v_existing_action_id := v_clue.moderator_removal_action_id;
      IF v_existing_action_id IS NULL THEN
        RAISE EXCEPTION 'FK_STATE_INCONSISTENCY: target removed but action pointer is NULL';
      END IF;
      SELECT array_agg(locked.id ORDER BY locked.id) INTO v_new_report_ids
      FROM (
        SELECT cr.id
        FROM public.content_reports cr
        WHERE cr.target_type = 'clue' AND cr.target_id = p_target_id AND cr.status = 'pending'
        ORDER BY cr.id
        FOR UPDATE
      ) AS locked;
      IF v_new_report_ids IS NOT NULL THEN
        INSERT INTO private.moderation_action_reports (moderation_action_id, report_id)
        SELECT v_existing_action_id, id FROM unnest(v_new_report_ids) AS t(id)
        ON CONFLICT ON CONSTRAINT moderation_action_reports_one_resolution DO NOTHING;
        IF EXISTS (
          SELECT 1 FROM private.moderation_action_reports
          WHERE report_id = ANY(v_new_report_ids)
            AND moderation_action_id != v_existing_action_id
        ) THEN RAISE EXCEPTION 'FK_RESOLUTION_CONFLICT'; END IF;
        UPDATE public.content_reports
        SET status = 'actioned', reviewed_at = clock_timestamp(), reviewed_by = p_moderator_id
        WHERE id = ANY(v_new_report_ids);
      END IF;
      RETURN;
    END IF;

    -- Step 3: Lock pending reports
    SELECT array_agg(locked.id ORDER BY locked.id) INTO v_report_ids
    FROM (
      SELECT cr.id
      FROM public.content_reports cr
      WHERE cr.target_type = 'clue' AND cr.target_id = p_target_id AND cr.status = 'pending'
      ORDER BY cr.id
      FOR UPDATE
    ) AS locked;

    -- Step 4: Verify p_report_id
    IF p_report_id IS NOT NULL AND
       NOT (p_report_id = ANY(COALESCE(v_report_ids, ARRAY[]::uuid[]))) THEN
      RAISE EXCEPTION 'FK_REPORT_TARGET_MISMATCH';
    END IF;

    -- Step 5: INSERT moderation_actions
    INSERT INTO public.moderation_actions
      (moderator_id, action_type, target_type, target_id, report_id, reason)
    VALUES
      (p_moderator_id, 'content_removed', 'clue', p_target_id, p_report_id, p_reason)
    RETURNING id INTO v_action_id;

    -- Step 6: INSERT evidence (original clue text; row text preserved)
    INSERT INTO private.moderation_evidence
      (moderation_action_id, evidence_type, evidence_text)
    VALUES
      (v_action_id, 'clue_text', v_clue.text);

    -- Step 7: UPDATE clue (text preserved in row; RESTRICTIVE policy hides it)
    UPDATE public.clues
    SET moderator_removed_at = clock_timestamp(),
        moderator_removal_action_id = v_action_id
    WHERE id = p_target_id;

    -- Steps 8-9: Link and action reports
    IF v_report_ids IS NOT NULL THEN
      INSERT INTO private.moderation_action_reports (moderation_action_id, report_id)
      SELECT v_action_id, id FROM unnest(v_report_ids) AS t(id);
      UPDATE public.content_reports
      SET status = 'actioned', reviewed_at = clock_timestamp(), reviewed_by = p_moderator_id
      WHERE id = ANY(v_report_ids);
    END IF;

  END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- 10.9  public.remove_media
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.remove_media(
  p_media_object_id uuid,
  p_moderator_id    uuid,
  p_report_id       uuid,
  p_reason          text
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_challenge_id       uuid;
  v_challenge          record;
  v_media              record;
  v_action_id          uuid;
  v_existing_action_id uuid;
  v_report_ids         uuid[];
  v_new_report_ids     uuid[];
  v_sha256             text;
  v_storage_key        text;
BEGIN
  -- 1. Validate moderator
  IF NOT EXISTS (
    SELECT 1 FROM private.moderators m
    JOIN public.profiles p ON p.id = m.profile_id
    WHERE m.profile_id = p_moderator_id AND p.is_active = true
  ) THEN RAISE EXCEPTION 'FK_UNAUTHORIZED: moderator identity not valid'; END IF;

  -- 2. Provisional challenge read (before acquiring any lock)
  SELECT id INTO v_challenge_id FROM public.challenges
  WHERE media_object_id = p_media_object_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'FK_NOT_FOUND'; END IF;

  -- 3. Lock challenge
  SELECT id, state, media_object_id, moderator_removed_at, moderator_removal_action_id
  INTO v_challenge
  FROM public.challenges WHERE id = v_challenge_id FOR UPDATE;

  -- 4. Idempotency path
  IF v_challenge.moderator_removed_at IS NOT NULL THEN
    v_existing_action_id := v_challenge.moderator_removal_action_id;
    IF v_existing_action_id IS NULL THEN
      RAISE EXCEPTION 'FK_STATE_INCONSISTENCY: target removed but action pointer is NULL';
    END IF;
    SELECT array_agg(locked.id ORDER BY locked.id) INTO v_new_report_ids
    FROM (
      SELECT cr.id
      FROM public.content_reports cr
      WHERE cr.status = 'pending'
        AND (
          (cr.target_type = 'media_object' AND cr.target_id = p_media_object_id)
          OR (cr.target_type = 'challenge' AND cr.category = 'inappropriate_image'
              AND cr.target_id = v_challenge_id)
        )
      ORDER BY cr.id
      FOR UPDATE
    ) AS locked;
    IF v_new_report_ids IS NOT NULL THEN
      INSERT INTO private.moderation_action_reports (moderation_action_id, report_id)
      SELECT v_existing_action_id, id FROM unnest(v_new_report_ids) AS t(id)
      ON CONFLICT ON CONSTRAINT moderation_action_reports_one_resolution DO NOTHING;
      IF EXISTS (
        SELECT 1 FROM private.moderation_action_reports
        WHERE report_id = ANY(v_new_report_ids)
          AND moderation_action_id != v_existing_action_id
      ) THEN RAISE EXCEPTION 'FK_RESOLUTION_CONFLICT'; END IF;
      UPDATE public.content_reports
      SET status = 'actioned', reviewed_at = clock_timestamp(), reviewed_by = p_moderator_id
      WHERE id = ANY(v_new_report_ids);
    END IF;
    RETURN;
  END IF;

  -- 5. Re-validate linkage (IS DISTINCT FROM handles NULL safely)
  IF v_challenge.media_object_id IS DISTINCT FROM p_media_object_id THEN
    RAISE EXCEPTION 'FK_LINKAGE_CHANGED';
  END IF;

  -- 6. Lock all matching pending reports (ascending UUID)
  SELECT array_agg(locked.id ORDER BY locked.id) INTO v_report_ids
  FROM (
    SELECT cr.id
    FROM public.content_reports cr
    WHERE cr.status = 'pending'
      AND (
        (cr.target_type = 'media_object' AND cr.target_id = p_media_object_id)
        OR (cr.target_type = 'challenge' AND cr.category = 'inappropriate_image'
            AND cr.target_id = v_challenge_id)
      )
    ORDER BY cr.id
    FOR UPDATE
  ) AS locked;

  -- 7. Verify p_report_id if supplied
  IF p_report_id IS NOT NULL AND
     NOT (p_report_id = ANY(COALESCE(v_report_ids, ARRAY[]::uuid[]))) THEN
    RAISE EXCEPTION 'FK_REPORT_TARGET_MISMATCH';
  END IF;

  -- 8. Lock media; verify status = 'ready'
  SELECT id, status INTO v_media
  FROM public.media_objects WHERE id = p_media_object_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'FK_NOT_FOUND'; END IF;
  IF v_media.status != 'ready' THEN
    RAISE EXCEPTION 'FK_WRONG_STATE: media is not ready (status: %)', v_media.status;
  END IF;

  -- 9. Read SHA-256
  SELECT sha256_hash, re_encoded_storage_key INTO v_sha256, v_storage_key
  FROM private.media_storage_keys WHERE media_object_id = p_media_object_id;
  IF v_sha256 IS NULL THEN RAISE EXCEPTION 'FK_MEDIA_METADATA_INCOMPLETE'; END IF;

  -- 10. INSERT moderation_actions
  INSERT INTO public.moderation_actions
    (moderator_id, action_type, target_type, target_id, report_id, reason)
  VALUES
    (p_moderator_id, 'photo_removed', 'media_object', p_media_object_id, p_report_id, p_reason)
  RETURNING id INTO v_action_id;

  -- 11. INSERT evidence
  INSERT INTO private.moderation_evidence
    (moderation_action_id, evidence_type, evidence_storage_key, evidence_sha256)
  VALUES
    (v_action_id, 'media_metadata', v_storage_key, v_sha256);

  -- 12. UPDATE media_objects
  UPDATE public.media_objects
  SET status = 'removed', moderated_at = clock_timestamp()
  WHERE id = p_media_object_id;

  -- 13. UPDATE challenges per state matrix; set action pointer atomically
  IF v_challenge.state IN ('draft','active','locked') THEN
    UPDATE public.challenges
    SET state = 'cancelled',
        cancellation_reason = 'moderation_action',
        moderator_removed_at = clock_timestamp(),
        moderator_removal_action_id = v_action_id
    WHERE id = v_challenge_id;
  ELSE
    UPDATE public.challenges
    SET moderator_removed_at = clock_timestamp(),
        moderator_removal_action_id = v_action_id
    WHERE id = v_challenge_id;
  END IF;

  -- 14-15: Link and action reports
  IF v_report_ids IS NOT NULL THEN
    INSERT INTO private.moderation_action_reports (moderation_action_id, report_id)
    SELECT v_action_id, id FROM unnest(v_report_ids) AS t(id);
    UPDATE public.content_reports
    SET status = 'actioned', reviewed_at = clock_timestamp(), reviewed_by = p_moderator_id
    WHERE id = ANY(v_report_ids);
  END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- 10.12  public.suspend_user
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.suspend_user(
  p_profile_id   uuid,
  p_moderator_id uuid,
  p_reason       text
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_profile record;
BEGIN
  -- 1. Validate moderator
  IF NOT EXISTS (
    SELECT 1 FROM private.moderators m
    JOIN public.profiles p ON p.id = m.profile_id
    WHERE m.profile_id = p_moderator_id AND p.is_active = true
  ) THEN RAISE EXCEPTION 'FK_UNAUTHORIZED: moderator identity not valid'; END IF;

  -- 2. Lock profile row to prevent concurrent suspend/reinstate races
  SELECT id, is_active, is_suspended INTO v_profile
  FROM public.profiles WHERE id = p_profile_id FOR UPDATE;
  IF NOT FOUND OR NOT v_profile.is_active THEN RAISE EXCEPTION 'FK_NOT_FOUND'; END IF;

  -- 3. Idempotent: already suspended → return without error
  IF v_profile.is_suspended THEN RETURN; END IF;

  -- 4. Atomically update profile + upsert suspension record
  UPDATE public.profiles SET is_suspended = true WHERE id = p_profile_id;

  INSERT INTO private.profile_suspensions
    (profile_id, is_suspended, suspended_at, suspension_reason, suspended_by)
  VALUES
    (p_profile_id, true, clock_timestamp(), p_reason, p_moderator_id)
  ON CONFLICT (profile_id) DO UPDATE
    SET is_suspended      = true,
        suspended_at      = clock_timestamp(),
        suspension_reason = EXCLUDED.suspension_reason,
        suspended_by      = EXCLUDED.suspended_by;

  -- 5. INSERT moderation_actions
  INSERT INTO public.moderation_actions
    (moderator_id, action_type, target_type, target_id, reason)
  VALUES
    (p_moderator_id, 'user_suspended', 'profile', p_profile_id, p_reason);
END;
$$;

-- ---------------------------------------------------------------------------
-- 10.13  public.reinstate_user
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.reinstate_user(
  p_profile_id   uuid,
  p_moderator_id uuid,
  p_reason       text
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_profile record;
BEGIN
  -- 1. Validate moderator
  IF NOT EXISTS (
    SELECT 1 FROM private.moderators m
    JOIN public.profiles p ON p.id = m.profile_id
    WHERE m.profile_id = p_moderator_id AND p.is_active = true
  ) THEN RAISE EXCEPTION 'FK_UNAUTHORIZED: moderator identity not valid'; END IF;

  -- 2. Lock profile row to prevent concurrent suspend/reinstate races
  SELECT id, is_suspended INTO v_profile
  FROM public.profiles WHERE id = p_profile_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'FK_NOT_FOUND'; END IF;
  IF NOT v_profile.is_suspended THEN
    RAISE EXCEPTION 'FK_WRONG_STATE: profile is not suspended';
  END IF;

  -- 3. Atomically update profile + suspension record
  UPDATE public.profiles SET is_suspended = false WHERE id = p_profile_id;

  UPDATE private.profile_suspensions
  SET is_suspended      = false,
      suspended_at      = NULL,
      suspension_reason = NULL,
      suspended_by      = NULL
  WHERE profile_id = p_profile_id;

  -- 4. INSERT moderation_actions
  INSERT INTO public.moderation_actions
    (moderator_id, action_type, target_type, target_id, reason)
  VALUES
    (p_moderator_id, 'user_reinstated', 'profile', p_profile_id, p_reason);
END;
$$;

-- ---------------------------------------------------------------------------
-- 10.14  public.dismiss_report
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.dismiss_report(
  p_report_id    uuid,
  p_moderator_id uuid,
  p_reason       text
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_report    record;
  v_action_id uuid;
BEGIN
  -- 1. Validate moderator
  IF NOT EXISTS (
    SELECT 1 FROM private.moderators m
    JOIN public.profiles p ON p.id = m.profile_id
    WHERE m.profile_id = p_moderator_id AND p.is_active = true
  ) THEN RAISE EXCEPTION 'FK_UNAUTHORIZED: moderator identity not valid'; END IF;

  -- 2. Lock report; verify pending
  SELECT id, status INTO v_report
  FROM public.content_reports WHERE id = p_report_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'FK_NOT_FOUND'; END IF;
  IF v_report.status != 'pending' THEN
    RAISE EXCEPTION 'FK_WRONG_STATE: report is not pending (status: %)', v_report.status;
  END IF;

  -- 3. INSERT moderation_actions
  INSERT INTO public.moderation_actions
    (moderator_id, action_type, report_id, reason)
  VALUES
    (p_moderator_id, 'report_dismissed', p_report_id, p_reason)
  RETURNING id INTO v_action_id;

  -- 4. INSERT moderation_action_reports
  INSERT INTO private.moderation_action_reports (moderation_action_id, report_id)
  VALUES (v_action_id, p_report_id);

  -- 5. UPDATE content_reports
  UPDATE public.content_reports
  SET status = 'dismissed', reviewed_at = clock_timestamp(), reviewed_by = p_moderator_id
  WHERE id = p_report_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- 10.15  public.action_report
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.action_report(
  p_report_id       uuid,
  p_moderator_id    uuid,
  p_prior_action_id uuid,
  p_reason          text
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_prior  record;
  v_report record;
  v_action_id uuid;
BEGIN
  -- 1. Validate moderator
  IF NOT EXISTS (
    SELECT 1 FROM private.moderators m
    JOIN public.profiles p ON p.id = m.profile_id
    WHERE m.profile_id = p_moderator_id AND p.is_active = true
  ) THEN RAISE EXCEPTION 'FK_UNAUTHORIZED: moderator identity not valid'; END IF;

  -- 2. Read prior action; validate it is a qualifying action type
  SELECT action_type, target_type, target_id INTO v_prior
  FROM public.moderation_actions WHERE id = p_prior_action_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'FK_NOT_FOUND'; END IF;
  IF v_prior.action_type IN ('report_dismissed','report_actioned','photo_approved') THEN
    RAISE EXCEPTION 'FK_INVALID_PRIOR_ACTION';
  END IF;

  -- 3. Lock report; verify pending and same subject as prior action
  SELECT target_type, target_id, status INTO v_report
  FROM public.content_reports WHERE id = p_report_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'FK_NOT_FOUND'; END IF;
  IF v_report.status != 'pending' THEN
    RAISE EXCEPTION 'FK_WRONG_STATE: report is not pending';
  END IF;
  IF v_report.target_type != v_prior.target_type OR v_report.target_id != v_prior.target_id THEN
    RAISE EXCEPTION 'FK_REPORT_TARGET_MISMATCH';
  END IF;

  -- 4. INSERT moderation_actions
  INSERT INTO public.moderation_actions
    (moderator_id, action_type, report_id, prior_action_id, reason)
  VALUES
    (p_moderator_id, 'report_actioned', p_report_id, p_prior_action_id, p_reason)
  RETURNING id INTO v_action_id;

  -- 5. INSERT moderation_action_reports
  INSERT INTO private.moderation_action_reports (moderation_action_id, report_id)
  VALUES (v_action_id, p_report_id);

  -- 6. UPDATE content_reports
  UPDATE public.content_reports
  SET status = 'actioned', reviewed_at = clock_timestamp(), reviewed_by = p_moderator_id
  WHERE id = p_report_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- 10.16  public.get_media_serve_authorization
-- ---------------------------------------------------------------------------
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

-- ---------------------------------------------------------------------------
-- 10.17  public.get_moderation_queue
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_moderation_queue()
RETURNS TABLE(
  queue_type  text,
  item_id     uuid,
  created_at  timestamptz,
  target_type text,
  target_id   uuid,
  category    text,
  challenge_id uuid
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT
    'pending_report'::text,
    cr.id,
    cr.created_at,
    cr.target_type,
    cr.target_id,
    cr.category,
    NULL::uuid
  FROM public.content_reports cr
  WHERE cr.status = 'pending'
  UNION ALL
  SELECT
    'pending_review_photo'::text,
    mo.id,
    mo.created_at,
    'media_object'::text,
    mo.id,
    NULL::text,
    c.id
  FROM public.media_objects mo
  JOIN public.challenges c ON c.media_object_id = mo.id
  WHERE mo.status = 'pending_review'
  ORDER BY created_at ASC;
$$;

-- ---------------------------------------------------------------------------
-- 10.18  public.get_pending_review_media
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_pending_review_media(p_media_object_id uuid)
RETURNS TABLE(
  media_object_id       uuid,
  re_encoded_storage_key text,
  challenge_id          uuid,
  uploader_id           uuid,
  re_encoded_at         timestamptz
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT mo.id, msk.re_encoded_storage_key, c.id, mo.uploader_id, mo.re_encoded_at
  FROM public.media_objects mo
  JOIN public.challenges c ON c.media_object_id = mo.id
  JOIN private.media_storage_keys msk ON msk.media_object_id = mo.id
  WHERE mo.id = p_media_object_id
    AND mo.status = 'pending_review';
$$;

-- ---------------------------------------------------------------------------
-- 10.19  public.get_reported_media
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_reported_media(p_report_id uuid)
RETURNS TABLE(
  media_object_id       uuid,
  re_encoded_storage_key text,
  challenge_id          uuid,
  uploader_id           uuid,
  media_status          text,
  report_category       text,
  report_detail         text
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  -- Branch 1: direct media_object report
  SELECT
    mo.id,
    msk.re_encoded_storage_key,
    c.id,
    mo.uploader_id,
    mo.status,
    cr.category,
    cr.detail
  FROM public.content_reports cr
  JOIN public.media_objects mo ON mo.id = cr.target_id
  JOIN public.challenges c ON c.media_object_id = mo.id
  JOIN private.media_storage_keys msk ON msk.media_object_id = mo.id
  WHERE cr.id = p_report_id
    AND cr.target_type = 'media_object'
    AND cr.status = 'pending'
    AND mo.status IN ('ready','pending_review')

  UNION ALL

  -- Branch 2: challenge-level inappropriate_image report (image lives on challenge)
  SELECT
    mo.id,
    msk.re_encoded_storage_key,
    c.id,
    mo.uploader_id,
    mo.status,
    cr.category,
    cr.detail
  FROM public.content_reports cr
  JOIN public.challenges c ON c.id = cr.target_id
  JOIN public.media_objects mo ON mo.id = c.media_object_id
  JOIN private.media_storage_keys msk ON msk.media_object_id = mo.id
  WHERE cr.id = p_report_id
    AND cr.target_type = 'challenge'
    AND cr.category = 'inappropriate_image'
    AND cr.status = 'pending'
    AND mo.status IN ('ready','pending_review');
$$;

-- ---------------------------------------------------------------------------
-- 10.20  public.get_poster_media_status
-- ---------------------------------------------------------------------------
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
    AND mo.uploader_id = p_uploader_id;
$$;

-- ---------------------------------------------------------------------------
-- 10.21  public.get_my_reports
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_my_reports()
RETURNS TABLE(
  id          uuid,
  target_type text,
  target_id   uuid,
  category    text,
  detail      text,
  status      text,
  created_at  timestamptz,
  reviewed_at timestamptz
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT cr.id, cr.target_type, cr.target_id, cr.category,
         cr.detail, cr.status, cr.created_at, cr.reviewed_at
  FROM public.content_reports cr
  WHERE cr.reporter_id = private.auth_uid();
$$;

-- ---------------------------------------------------------------------------
-- 10.22  public.get_report_for_review
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_report_for_review(p_report_id uuid)
RETURNS TABLE(
  report_id      uuid,
  reporter_id    uuid,
  target_type    text,
  target_id      uuid,
  category       text,
  detail         text,
  status         text,
  created_at     timestamptz,
  target_summary text
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT
    cr.id,
    cr.reporter_id,
    cr.target_type,
    cr.target_id,
    cr.category,
    cr.detail,
    cr.status,
    cr.created_at,
    CASE
      WHEN cr.target_type = 'comment' THEN
        (SELECT c.text FROM public.comments c WHERE c.id = cr.target_id)
      WHEN cr.target_type = 'clue' THEN
        (SELECT cl.text FROM public.clues cl WHERE cl.id = cr.target_id)
      ELSE NULL
    END AS target_summary
  FROM public.content_reports cr
  WHERE cr.id = p_report_id;
$$;

-- =============================================================================
-- PART 11 — CLEANUP CONTRACTS
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 11.1  public.claim_moderation_media_cleanup
-- ---------------------------------------------------------------------------
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

-- ---------------------------------------------------------------------------
-- 11.2  public.mark_moderation_media_cleaned
-- ---------------------------------------------------------------------------
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

-- ---------------------------------------------------------------------------
-- 11.4  private.cleanup_expired_evidence
-- Owner: forkensics_executor. EXECUTE granted to service_role only.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.cleanup_expired_evidence()
RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path = ''
AS $$
  DELETE FROM private.moderation_evidence
  WHERE retained_until < clock_timestamp();
$$;

-- =============================================================================
-- V1/V2 FUNCTION UPDATES — SUSPENSION GUARDS AND OWNERSHIP TRANSFER
-- =============================================================================

-- ---------------------------------------------------------------------------
-- handle_new_user — also insert into private.profile_suspensions on signup
-- Blocker 7: new users must have a profile_suspensions row from the moment of
-- account creation; the backfill above covers existing rows.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
  INSERT INTO public.profiles (id, display_name, onboarding_complete, is_active)
  VALUES (NEW.id, NEW.raw_user_meta_data->>'display_name', false, true)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO private.profile_suspensions (profile_id)
  VALUES (NEW.id)
  ON CONFLICT (profile_id) DO NOTHING;

  RETURN NEW;
END;
$$;

-- ---------------------------------------------------------------------------
-- activate_challenge — add suspension guard + block-pair exclusion
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.activate_challenge(p_challenge_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_challenge   record;
  v_secrets     record;
  v_ep_count    integer;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.profiles WHERE id = private.auth_uid() AND is_active = true
  ) THEN RAISE EXCEPTION 'account is inactive'; END IF;

  -- V3: suspension guard
  IF EXISTS (
    SELECT 1 FROM public.profiles WHERE id = private.auth_uid() AND is_suspended = true
  ) THEN RAISE EXCEPTION 'FK_SUSPENDED'; END IF;

  -- Lock challenge row
  SELECT * INTO v_challenge FROM public.challenges
  WHERE id = p_challenge_id FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'challenge not found'; END IF;

  IF v_challenge.poster_id != private.auth_uid() THEN
    RAISE EXCEPTION 'caller is not the poster';
  END IF;

  IF v_challenge.state != 'draft' THEN
    RAISE EXCEPTION 'challenge is not in draft state (current: %)', v_challenge.state;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.groups WHERE id = v_challenge.group_id AND archived_at IS NOT NULL
  ) THEN RAISE EXCEPTION 'group is archived'; END IF;

  SELECT * INTO v_secrets FROM public.challenge_secrets
  WHERE challenge_id = p_challenge_id;

  IF NOT FOUND THEN RAISE EXCEPTION 'challenge_secrets not found'; END IF;

  IF length(trim(v_secrets.canonical_dish)) = 0
     OR length(trim(v_secrets.canonical_restaurant)) = 0 THEN
    RAISE EXCEPTION 'canonical answers must not be empty';
  END IF;

  IF v_challenge.media_object_id IS NULL THEN
    RAISE EXCEPTION 'challenge photo is required';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.media_objects
    WHERE id          = v_challenge.media_object_id
      AND uploader_id = private.auth_uid()
      AND status      = 'ready'
  ) THEN RAISE EXCEPTION 'challenge photo is not ready'; END IF;

  -- V3: Snapshot eligible participants excluding blocked pairs
  INSERT INTO public.eligible_participants (challenge_id, player_id, snapshot_avatar_color)
  SELECT
    p_challenge_id,
    p.id,
    p.avatar_color
  FROM public.group_members gm
  JOIN public.profiles p ON p.id = gm.player_id
  WHERE gm.group_id = v_challenge.group_id
    AND gm.player_id != private.auth_uid()
    AND p.is_active = true
    AND p.onboarding_complete = true
    AND NOT EXISTS (
      SELECT 1 FROM public.user_blocks ub
      WHERE (ub.blocker_id = private.auth_uid() AND ub.blocked_id = gm.player_id)
         OR (ub.blocker_id = gm.player_id    AND ub.blocked_id = private.auth_uid())
    );

  GET DIAGNOSTICS v_ep_count = ROW_COUNT;

  IF v_ep_count = 0 THEN
    RAISE EXCEPTION 'at least one eligible participant is required';
  END IF;

  UPDATE public.challenges
  SET
    state     = 'active',
    posted_at = clock_timestamp()
  WHERE id = p_challenge_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- create_group — add suspension guard
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.create_group(p_name text)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_group_id uuid;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.profiles WHERE id = private.auth_uid() AND is_active = true
  ) THEN RAISE EXCEPTION 'account is inactive'; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.profiles WHERE id = private.auth_uid() AND onboarding_complete = true
  ) THEN RAISE EXCEPTION 'onboarding not complete'; END IF;

  -- V3: suspension guard
  IF EXISTS (
    SELECT 1 FROM public.profiles WHERE id = private.auth_uid() AND is_suspended = true
  ) THEN RAISE EXCEPTION 'FK_SUSPENDED'; END IF;

  IF length(trim(p_name)) < 1 OR length(p_name) > 100 THEN
    RAISE EXCEPTION 'group name must be 1–100 characters';
  END IF;

  INSERT INTO public.groups (name, created_by)
  VALUES (trim(p_name), private.auth_uid())
  RETURNING id INTO v_group_id;

  INSERT INTO public.group_members (group_id, player_id, role)
  VALUES (v_group_id, private.auth_uid(), 'owner');

  RETURN v_group_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- create_group_invite — add suspension guard
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.create_group_invite(p_group_id uuid)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_raw_token  text;
  v_token_hash text;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.profiles WHERE id = private.auth_uid() AND is_active = true
  ) THEN RAISE EXCEPTION 'account is inactive'; END IF;

  -- V3: suspension guard
  IF EXISTS (
    SELECT 1 FROM public.profiles WHERE id = private.auth_uid() AND is_suspended = true
  ) THEN RAISE EXCEPTION 'FK_SUSPENDED'; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.group_members
    WHERE group_id = p_group_id AND player_id = private.auth_uid()
  ) THEN RAISE EXCEPTION 'not a member of this group'; END IF;

  IF EXISTS (
    SELECT 1 FROM public.groups
    WHERE id = p_group_id AND archived_at IS NOT NULL
  ) THEN RAISE EXCEPTION 'group is archived'; END IF;

  v_raw_token  := replace(replace(rtrim(encode(extensions.gen_random_bytes(32), 'base64'), '='), '+', '-'), '/', '_');
  v_token_hash := encode(extensions.digest(v_raw_token, 'sha256'), 'hex');

  INSERT INTO public.group_invites (group_id, created_by, token_hash, expires_at)
  VALUES (p_group_id, private.auth_uid(), v_token_hash, now() + interval '7 days');

  RETURN v_raw_token;
END;
$$;

-- ---------------------------------------------------------------------------
-- redeem_group_invite — add suspension guard (internal, per spec Section 10.23)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.redeem_group_invite(p_raw_token text)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_invite   record;
  v_hash     text;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.profiles WHERE id = private.auth_uid() AND is_active = true
  ) THEN RAISE EXCEPTION 'account is inactive'; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.profiles WHERE id = private.auth_uid() AND onboarding_complete = true
  ) THEN RAISE EXCEPTION 'onboarding must be completed before joining a group'; END IF;

  -- V3: suspension guard
  IF EXISTS (
    SELECT 1 FROM public.profiles WHERE id = private.auth_uid() AND is_suspended = true
  ) THEN RAISE EXCEPTION 'FK_SUSPENDED'; END IF;

  v_hash := encode(extensions.digest(p_raw_token, 'sha256'), 'hex');

  SELECT * INTO v_invite FROM public.group_invites
  WHERE token_hash = v_hash
  FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'invalid invite token'; END IF;
  IF v_invite.revoked_at IS NOT NULL THEN RAISE EXCEPTION 'invite has been revoked'; END IF;
  IF v_invite.accepted_at IS NOT NULL THEN RAISE EXCEPTION 'invite has already been used'; END IF;
  IF v_invite.expires_at < now() THEN RAISE EXCEPTION 'invite has expired'; END IF;

  IF EXISTS (
    SELECT 1 FROM public.groups
    WHERE id = v_invite.group_id AND archived_at IS NOT NULL
  ) THEN RAISE EXCEPTION 'group is archived'; END IF;

  INSERT INTO public.group_members (group_id, player_id, role)
  VALUES (v_invite.group_id, private.auth_uid(), 'member')
  ON CONFLICT (group_id, player_id) DO NOTHING;

  UPDATE public.group_invites
  SET accepted_by = private.auth_uid(), accepted_at = now()
  WHERE id = v_invite.id;

  RETURN v_invite.group_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- apply_correction — add suspension guard
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.apply_correction(
  p_challenge_id      uuid,
  p_action            text,
  p_target_field      text,
  p_new_display_value text,
  p_alias_id          uuid,
  p_reason            text
)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_challenge            record;
  v_secrets              record;
  v_alias                record;
  v_next_revision        integer;
  v_score_run_id         uuid;
  v_correction_id        uuid;
  v_old_display          text;
  v_old_normalized       text;
  v_new_normalized       text;
  v_audit_old_display    text;
  v_audit_old_normalized text;
  v_audit_new_display    text;
  v_audit_new_normalized text;
  v_eligible_count       integer;
  v_attempt              record;
  v_norm_dish            text;
  v_norm_restaurant      text;
  v_norm_canonical_dish  text;
  v_norm_canonical_restaurant text;
  v_what_correct         boolean;
  v_where_correct        boolean;
  v_restaurant_correct   boolean;
BEGIN
  -- Step 1: Active-profile guard + caller authority
  IF NOT EXISTS (
    SELECT 1 FROM public.profiles WHERE id = private.auth_uid() AND is_active = true
  ) THEN RAISE EXCEPTION 'account is inactive'; END IF;

  -- V3: suspension guard
  IF EXISTS (
    SELECT 1 FROM public.profiles WHERE id = private.auth_uid() AND is_suspended = true
  ) THEN RAISE EXCEPTION 'FK_SUSPENDED'; END IF;

  SELECT * INTO v_challenge FROM public.challenges
  WHERE id = p_challenge_id FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'challenge not found'; END IF;

  IF v_challenge.state != 'revealed' THEN
    RAISE EXCEPTION 'corrections can only be applied to revealed challenges';
  END IF;

  IF v_challenge.poster_id != private.auth_uid()
     AND NOT EXISTS (
       SELECT 1 FROM public.group_members
       WHERE group_id  = v_challenge.group_id
         AND player_id = private.auth_uid()
         AND role      = 'owner'
     ) THEN
    RAISE EXCEPTION 'only the poster or group owner can apply corrections';
  END IF;

  -- Step 2: Validate action, field, reason
  IF p_action NOT IN ('answer_changed','alias_added','alias_removed') THEN
    RAISE EXCEPTION 'invalid action: %', p_action;
  END IF;
  IF p_target_field NOT IN ('dish','restaurant') THEN
    RAISE EXCEPTION 'invalid target_field: %', p_target_field;
  END IF;
  IF p_reason IS NULL OR length(trim(p_reason)) < 1 OR length(p_reason) > 500 THEN
    RAISE EXCEPTION 'reason must be 1–500 characters';
  END IF;
  IF p_action IN ('answer_changed','alias_added') AND p_alias_id IS NOT NULL THEN
    RAISE EXCEPTION 'alias_id must be NULL for action: %', p_action;
  END IF;
  IF p_action = 'alias_removed' AND p_new_display_value IS NOT NULL THEN
    RAISE EXCEPTION 'new_display_value must be NULL for alias_removed';
  END IF;

  -- Step 3: Action-specific validation
  IF p_action IN ('answer_changed','alias_added') THEN
    IF p_new_display_value IS NULL OR length(trim(p_new_display_value)) = 0 THEN
      RAISE EXCEPTION 'new_display_value required for action: %', p_action;
    END IF;
    IF p_target_field IN ('dish','restaurant') AND length(p_new_display_value) > 200 THEN
      RAISE EXCEPTION '% display value must be 200 characters or fewer', p_target_field;
    END IF;
    v_new_normalized := private.normalize_answer(p_new_display_value);
    IF length(v_new_normalized) = 0 THEN
      RAISE EXCEPTION 'normalized value is empty after normalization; provide a different display value';
    END IF;
  END IF;

  IF p_action = 'alias_removed' THEN
    IF p_alias_id IS NULL THEN
      RAISE EXCEPTION 'alias_id required for alias_removed action';
    END IF;
    SELECT * INTO v_alias FROM public.challenge_answer_aliases
    WHERE id           = p_alias_id
      AND challenge_id = p_challenge_id
      AND field        = p_target_field
      AND is_active    = true
    FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'alias not found, wrong challenge/field, or already inactive';
    END IF;
  END IF;

  IF p_action = 'alias_added' THEN
    IF EXISTS (
      SELECT 1 FROM public.challenge_answer_aliases
      WHERE challenge_id     = p_challenge_id
        AND field            = p_target_field
        AND is_active        = true
        AND normalized_value = v_new_normalized
    ) THEN
      RAISE EXCEPTION
        'an active alias with this normalized value already exists for this challenge and field';
    END IF;
  END IF;

  -- Step 4: Load secrets + capture canonical old values
  SELECT * INTO v_secrets FROM public.challenge_secrets
  WHERE challenge_id = p_challenge_id;

  IF p_target_field = 'dish' THEN
    v_old_display    := v_secrets.display_dish;
    v_old_normalized := v_secrets.canonical_dish;
  ELSE
    v_old_display    := v_secrets.display_restaurant;
    v_old_normalized := v_secrets.canonical_restaurant;
  END IF;

  IF p_action = 'alias_removed' THEN
    v_audit_old_display    := v_alias.display_value;
    v_audit_old_normalized := v_alias.normalized_value;
    v_audit_new_display    := NULL;
    v_audit_new_normalized := NULL;
  ELSIF p_action = 'alias_added' THEN
    v_audit_old_display    := NULL;
    v_audit_old_normalized := NULL;
    v_audit_new_display    := p_new_display_value;
    v_audit_new_normalized := v_new_normalized;
  ELSE
    v_audit_old_display    := v_old_display;
    v_audit_old_normalized := v_old_normalized;
    v_audit_new_display    := p_new_display_value;
    v_audit_new_normalized := v_new_normalized;
  END IF;

  -- Step 5: Calculate next revision number
  SELECT COALESCE(MAX(revision_number), 0) + 1 INTO v_next_revision
  FROM public.score_runs WHERE challenge_id = p_challenge_id;

  -- Step 6: Apply the correction
  IF p_action = 'answer_changed' THEN
    IF p_target_field = 'dish' THEN
      UPDATE public.challenge_secrets
      SET display_dish = p_new_display_value, canonical_dish = v_new_normalized
      WHERE challenge_id = p_challenge_id;
    ELSE
      UPDATE public.challenge_secrets
      SET display_restaurant = p_new_display_value, canonical_restaurant = v_new_normalized
      WHERE challenge_id = p_challenge_id;
    END IF;
  ELSIF p_action = 'alias_added' THEN
    INSERT INTO public.challenge_answer_aliases (
      challenge_id, field, display_value, normalized_value, created_by, is_active
    )
    VALUES (
      p_challenge_id, p_target_field, p_new_display_value, v_new_normalized, private.auth_uid(), true
    );
  ELSE
    UPDATE public.challenge_answer_aliases SET is_active = false WHERE id = p_alias_id;
  END IF;

  -- Step 7: Insert correction audit record
  INSERT INTO public.correction_events (
    challenge_id, corrected_by, action, target_field, alias_id,
    old_display_value, new_display_value, old_normalized_value, new_normalized_value,
    reason
  )
  VALUES (
    p_challenge_id, private.auth_uid(), p_action, p_target_field, p_alias_id,
    v_audit_old_display, v_audit_new_display,
    v_audit_old_normalized, v_audit_new_normalized,
    p_reason
  )
  RETURNING id INTO v_correction_id;

  -- Step 8: Re-score
  SELECT * INTO v_secrets FROM public.challenge_secrets WHERE challenge_id = p_challenge_id;
  v_norm_canonical_dish       := private.normalize_answer(v_secrets.canonical_dish);
  v_norm_canonical_restaurant := private.normalize_answer(v_secrets.canonical_restaurant);

  SELECT COUNT(*) INTO v_eligible_count
  FROM public.eligible_participants ep
  WHERE ep.challenge_id = p_challenge_id
    AND NOT EXISTS (
      SELECT 1 FROM public.exclusion_events ex
      WHERE ex.challenge_id = p_challenge_id AND ex.player_id = ep.player_id
    );

  INSERT INTO public.score_runs (
    challenge_id, revision_number, rules_version_id,
    effective_eligible_count, triggering_correction_id
  )
  VALUES (
    p_challenge_id, v_next_revision, v_challenge.rules_version_id,
    v_eligible_count, v_correction_id
  )
  RETURNING id INTO v_score_run_id;

  CREATE TEMP TABLE tmp_fc (
    player_id uuid,
    race      text,
    ga_id     uuid,
    seq       bigint
  ) ON COMMIT DROP;

  FOR v_attempt IN
    SELECT ga.*
    FROM public.guess_attempts ga
    JOIN public.eligible_participants ep
      ON ep.challenge_id = ga.challenge_id AND ep.player_id = ga.player_id
    WHERE ga.challenge_id = p_challenge_id
      AND NOT EXISTS (
        SELECT 1 FROM public.exclusion_events ex
        WHERE ex.challenge_id = p_challenge_id AND ex.player_id = ga.player_id
      )
    ORDER BY ga.receipt_sequence
  LOOP
    v_what_correct  := false;
    v_where_correct := false;

    IF v_attempt.race = 'what' THEN
      v_norm_dish := private.normalize_answer(v_attempt.dish_guess);
      v_what_correct :=
        v_norm_dish = v_norm_canonical_dish
        OR EXISTS (
          SELECT 1 FROM public.challenge_answer_aliases
          WHERE challenge_id    = p_challenge_id AND field = 'dish'
            AND is_active = true AND normalized_value = v_norm_dish
        );
      INSERT INTO public.guess_judgments (
        score_run_id, guess_attempt_id, player_id, challenge_id,
        race, rules_version_id, is_correct, is_first_correct_for_player
      )
      VALUES (
        v_score_run_id, v_attempt.id, v_attempt.player_id, p_challenge_id,
        'what', v_challenge.rules_version_id, v_what_correct,
        v_what_correct AND NOT EXISTS (
          SELECT 1 FROM tmp_fc WHERE player_id = v_attempt.player_id AND race = 'what'
        )
      );
      IF v_what_correct AND NOT EXISTS (
        SELECT 1 FROM tmp_fc WHERE player_id = v_attempt.player_id AND race = 'what'
      ) THEN
        INSERT INTO tmp_fc VALUES (v_attempt.player_id, 'what', v_attempt.id, v_attempt.receipt_sequence);
      END IF;
    ELSE
      v_norm_restaurant := private.normalize_answer(v_attempt.restaurant_guess);
      v_restaurant_correct :=
        v_norm_restaurant = v_norm_canonical_restaurant
        OR EXISTS (
          SELECT 1 FROM public.challenge_answer_aliases
          WHERE challenge_id    = p_challenge_id AND field = 'restaurant'
            AND is_active = true AND normalized_value = v_norm_restaurant
        );
      v_where_correct := v_restaurant_correct;
      INSERT INTO public.guess_judgments (
        score_run_id, guess_attempt_id, player_id, challenge_id,
        race, rules_version_id, is_correct, is_first_correct_for_player
      )
      VALUES (
        v_score_run_id, v_attempt.id, v_attempt.player_id, p_challenge_id,
        'where', v_challenge.rules_version_id, v_where_correct,
        v_where_correct AND NOT EXISTS (
          SELECT 1 FROM tmp_fc WHERE player_id = v_attempt.player_id AND race = 'where'
        )
      );
      IF v_where_correct AND NOT EXISTS (
        SELECT 1 FROM tmp_fc WHERE player_id = v_attempt.player_id AND race = 'where'
      ) THEN
        INSERT INTO tmp_fc VALUES (v_attempt.player_id, 'where', v_attempt.id, v_attempt.receipt_sequence);
      END IF;
    END IF;
  END LOOP;

  WITH what_ranked_c AS (
    SELECT player_id, ROW_NUMBER() OVER (ORDER BY seq)::integer AS rnk
    FROM tmp_fc WHERE race = 'what'
  ),
  where_ranked_c AS (
    SELECT player_id, ROW_NUMBER() OVER (ORDER BY seq)::integer AS rnk
    FROM tmp_fc WHERE race = 'where'
  )
  INSERT INTO public.score_events (
    score_run_id, challenge_id, player_id, rules_version_id,
    what_points, where_points, what_rank, where_rank
  )
  SELECT
    v_score_run_id, p_challenge_id, ep.player_id, v_challenge.rules_version_id,
    CASE WHEN wr.rnk  IS NOT NULL THEN GREATEST(1, v_eligible_count - wr.rnk  + 1) ELSE 0 END,
    CASE WHEN whr.rnk IS NOT NULL THEN GREATEST(1, v_eligible_count - whr.rnk + 1) ELSE 0 END,
    wr.rnk,
    whr.rnk
  FROM public.eligible_participants ep
  LEFT JOIN what_ranked_c  wr  ON wr.player_id  = ep.player_id
  LEFT JOIN where_ranked_c whr ON whr.player_id = ep.player_id
  WHERE ep.challenge_id = p_challenge_id
    AND NOT EXISTS (
      SELECT 1 FROM public.exclusion_events ex
      WHERE ex.challenge_id = p_challenge_id AND ex.player_id = ep.player_id
    );

  UPDATE public.correction_events
  SET resulting_score_run_id = v_score_run_id
  WHERE id = v_correction_id;

  DROP TABLE IF EXISTS tmp_fc;

  RETURN v_score_run_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- transfer_group_ownership — complete rewrite with group_ownership_history audit
-- Section 10.23: suspended caller permitted; recipient must be unsuspended.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.transfer_group_ownership(
  p_group_id     uuid,
  p_new_owner_id uuid
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_current_owner_id uuid;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.profiles WHERE id = private.auth_uid() AND is_active = true
  ) THEN RAISE EXCEPTION 'account is inactive'; END IF;

  -- Step 1: Lock the group row
  PERFORM 1 FROM public.groups WHERE id = p_group_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'FK_NOT_FOUND'; END IF;

  -- Step 2: Identify and lock current owner's membership row
  SELECT gm.player_id INTO v_current_owner_id
  FROM public.group_members gm
  WHERE gm.group_id = p_group_id AND gm.role = 'owner'
  FOR UPDATE;

  IF NOT FOUND OR v_current_owner_id != private.auth_uid() THEN
    RAISE EXCEPTION 'FK_UNAUTHORIZED: caller is not the group owner';
  END IF;

  -- Step 3: Lock recipient's membership row
  PERFORM 1
  FROM public.group_members gm
  WHERE gm.group_id = p_group_id AND gm.player_id = p_new_owner_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'FK_NOT_FOUND: recipient must be a group member';
  END IF;

  -- Step 4: Validate recipient
  IF NOT EXISTS (
    SELECT 1 FROM public.profiles
    WHERE id = p_new_owner_id
      AND is_active = true
      AND onboarding_complete = true
      AND is_suspended = false
  ) THEN
    RAISE EXCEPTION 'FK_INVALID_RECIPIENT: recipient must be active, onboarded, and not suspended';
  END IF;

  -- Steps 5-7: Audit + role swaps (atomic within transaction)
  INSERT INTO public.group_ownership_history
    (group_id, previous_owner, new_owner)
  VALUES
    (p_group_id, v_current_owner_id, p_new_owner_id);

  UPDATE public.group_members SET role = 'member'
  WHERE group_id = p_group_id AND player_id = v_current_owner_id;

  UPDATE public.group_members SET role = 'owner'
  WHERE group_id = p_group_id AND player_id = p_new_owner_id;
END;
$$;

-- =============================================================================
-- PART 6 — FORGE-PROTECTION TRIGGERS
-- =============================================================================

-- 6.1  INSERT forge-nulling function
CREATE OR REPLACE FUNCTION private.force_removal_fields_null()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  NEW.moderator_removed_at        := NULL;
  NEW.moderator_removal_action_id := NULL;
  RETURN NEW;
END;
$$;

-- 6.2  INSERT trigger attachments
CREATE TRIGGER force_challenge_removal_null
  BEFORE INSERT ON public.challenges FOR EACH ROW
  EXECUTE FUNCTION private.force_removal_fields_null();

CREATE TRIGGER force_comment_removal_null
  BEFORE INSERT ON public.comments FOR EACH ROW
  EXECUTE FUNCTION private.force_removal_fields_null();

CREATE TRIGGER force_clue_removal_null
  BEFORE INSERT ON public.clues FOR EACH ROW
  EXECUTE FUNCTION private.force_removal_fields_null();

-- 6.3  UPDATE guard for challenges and clues (SECURITY INVOKER)
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

-- =============================================================================
-- PART 8.3 — TEXT-FILTER TRIGGER ATTACHMENTS
-- =============================================================================

CREATE OR REPLACE TRIGGER comment_text_filter
  BEFORE INSERT ON public.comments FOR EACH ROW
  EXECUTE FUNCTION private.check_text_content_trigger('text');

CREATE OR REPLACE TRIGGER clue_text_filter
  BEFORE INSERT ON public.clues FOR EACH ROW
  EXECUTE FUNCTION private.check_text_content_trigger('text');

CREATE OR REPLACE TRIGGER profile_name_filter
  BEFORE INSERT OR UPDATE ON public.profiles FOR EACH ROW
  EXECUTE FUNCTION private.check_text_content_trigger('display_name');

CREATE OR REPLACE TRIGGER group_name_filter
  BEFORE INSERT OR UPDATE ON public.groups FOR EACH ROW
  EXECUTE FUNCTION private.check_text_content_trigger('name');

CREATE OR REPLACE TRIGGER challenge_city_filter
  BEFORE INSERT OR UPDATE ON public.challenges FOR EACH ROW
  EXECUTE FUNCTION private.check_text_content_trigger('public_city_display');

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
  EXECUTE FUNCTION private.check_text_content_trigger('display_value');

-- =============================================================================
-- PART 5 — ROLE OWNERSHIP AND FUNCTION GRANTS
-- Must execute AFTER all function definitions (Parts 2, 6, 7, 8, 10, 11).
-- =============================================================================

-- 5.1  Temporary role grants (open block moved to migration top — before Part 3)
-- See BEGIN block at start of file: GRANT forkensics_executor/rls_helper TO postgres
-- and GRANT CREATE ON SCHEMA private/public.

-- 5.2  Function ownership

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
ALTER FUNCTION private.enforce_record_immutability()          OWNER TO forkensics_executor;

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
-- V1/V2 functions updated in this migration (ownership unchanged; confirm via V1 OWNER TO)
-- activate_challenge, create_group, create_group_invite, redeem_group_invite,
-- apply_correction, transfer_group_ownership already owned by forkensics_executor from V1.

-- 5.3  Table access grants for forkensics_executor

-- New public tables
GRANT SELECT, INSERT, UPDATE ON public.content_reports         TO forkensics_executor;
GRANT SELECT, INSERT, DELETE ON public.user_blocks             TO forkensics_executor;
GRANT SELECT, INSERT         ON public.moderation_actions      TO forkensics_executor;
GRANT SELECT, INSERT         ON public.group_ownership_history TO forkensics_executor;

-- Existing public tables — column-level grants for new columns
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
GRANT SELECT, INSERT                 ON private.moderation_action_reports TO forkensics_executor;
GRANT SELECT, UPDATE (sha256_hash, re_encoded_storage_key)
  ON private.media_storage_keys TO forkensics_executor;

-- 5.4  Table access grants for forkensics_rls_helper
GRANT SELECT ON public.user_blocks           TO forkensics_rls_helper;
GRANT SELECT ON public.challenges            TO forkensics_rls_helper;
GRANT SELECT ON public.group_members         TO forkensics_rls_helper;
GRANT SELECT ON public.eligible_participants TO forkensics_rls_helper;
GRANT SELECT ON public.profiles              TO forkensics_rls_helper;

-- 5.5  EXECUTE grants on helper functions

-- To authenticated (for RLS policy evaluation)
GRANT EXECUTE ON FUNCTION private.can_view_challenge(uuid)        TO authenticated;
GRANT EXECUTE ON FUNCTION private.has_block_with(uuid)            TO authenticated;
GRANT EXECUTE ON FUNCTION private.has_block_with_poster(uuid)     TO authenticated;

-- To forkensics_executor (called at runtime inside executor-owned SECURITY DEFINER functions)
GRANT EXECUTE ON FUNCTION private.can_view_challenge(uuid)              TO forkensics_executor;
GRANT EXECUTE ON FUNCTION private.can_viewer_access_challenge(uuid,uuid) TO forkensics_executor;
GRANT EXECUTE ON FUNCTION private.auth_uid()                            TO forkensics_executor;
GRANT EXECUTE ON FUNCTION private.is_challenge_revealed(uuid)           TO forkensics_executor;

-- To service_role
GRANT EXECUTE ON FUNCTION private.can_viewer_access_challenge(uuid,uuid) TO service_role;

-- 5.6  EXECUTE grants on public functions

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

-- 5.7  Temporary role grant (close) — mirror of the open block at migration top
REVOKE CREATE ON SCHEMA private FROM forkensics_executor, forkensics_rls_helper;
REVOKE CREATE ON SCHEMA public  FROM forkensics_executor;
REVOKE forkensics_executor   FROM postgres;
REVOKE forkensics_rls_helper FROM postgres;

-- =============================================================================
-- PART 9 — RLS POLICY ADDITIONS
-- All on existing V1 tables: AS RESTRICTIVE.
-- On new tables (no V1 permissive baseline): AS PERMISSIVE where required.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 9.1  Suspension enforcement (RESTRICTIVE on existing tables)
-- Predicate: caller is NOT suspended.
-- ---------------------------------------------------------------------------

CREATE POLICY suspend_block_insert ON public.comments AS RESTRICTIVE
  FOR INSERT TO authenticated
  WITH CHECK (
    NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = private.auth_uid() AND is_suspended = true)
  );

CREATE POLICY suspend_block_insert ON public.clues AS RESTRICTIVE
  FOR INSERT TO authenticated
  WITH CHECK (
    NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = private.auth_uid() AND is_suspended = true)
  );

CREATE POLICY suspend_block_insert ON public.reactions AS RESTRICTIVE
  FOR INSERT TO authenticated
  WITH CHECK (
    NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = private.auth_uid() AND is_suspended = true)
  );

CREATE POLICY suspend_block_insert ON public.guess_attempts AS RESTRICTIVE
  FOR INSERT TO authenticated
  WITH CHECK (
    NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = private.auth_uid() AND is_suspended = true)
  );

CREATE POLICY suspend_block_insert ON public.challenges AS RESTRICTIVE
  FOR INSERT TO authenticated
  WITH CHECK (
    NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = private.auth_uid() AND is_suspended = true)
  );

CREATE POLICY suspend_block_update ON public.challenges AS RESTRICTIVE
  FOR UPDATE TO authenticated
  USING (
    NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = private.auth_uid() AND is_suspended = true)
  );

CREATE POLICY suspend_block_insert ON public.challenge_secrets AS RESTRICTIVE
  FOR INSERT TO authenticated
  WITH CHECK (
    NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = private.auth_uid() AND is_suspended = true)
  );

CREATE POLICY suspend_block_update ON public.challenge_secrets AS RESTRICTIVE
  FOR UPDATE TO authenticated
  USING (
    NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = private.auth_uid() AND is_suspended = true)
  );

CREATE POLICY suspend_block_insert ON public.challenge_answer_aliases AS RESTRICTIVE
  FOR INSERT TO authenticated
  WITH CHECK (
    NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = private.auth_uid() AND is_suspended = true)
  );

CREATE POLICY suspend_block_update ON public.challenge_answer_aliases AS RESTRICTIVE
  FOR UPDATE TO authenticated
  USING (
    NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = private.auth_uid() AND is_suspended = true)
  );

CREATE POLICY suspend_block_insert ON public.group_members AS RESTRICTIVE
  FOR INSERT TO authenticated
  WITH CHECK (
    NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = private.auth_uid() AND is_suspended = true)
  );

-- Blocker 4 fix: using a subquery on public.profiles inside a policy on public.profiles
-- causes infinite recursion. Reference the column directly instead — the USING predicate
-- evaluates against the row being updated, so `NOT is_suspended` is unambiguous.
CREATE POLICY suspend_block_update ON public.profiles AS RESTRICTIVE
  FOR UPDATE TO authenticated
  USING (NOT is_suspended);

CREATE POLICY suspend_block_insert ON public.groups AS RESTRICTIVE
  FOR INSERT TO authenticated
  WITH CHECK (
    NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = private.auth_uid() AND is_suspended = true)
  );

CREATE POLICY suspend_block_update ON public.groups AS RESTRICTIVE
  FOR UPDATE TO authenticated
  USING (
    NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = private.auth_uid() AND is_suspended = true)
  );

-- ---------------------------------------------------------------------------
-- 9.2  exclusion_events — branched suspension (RESTRICTIVE)
-- ---------------------------------------------------------------------------
CREATE POLICY suspend_exclusion_insert ON public.exclusion_events AS RESTRICTIVE
  FOR INSERT TO authenticated
  WITH CHECK (
    NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = private.auth_uid() AND is_suspended = true)
    OR (reason = 'withdrew' AND player_id = private.auth_uid())
  );

-- ---------------------------------------------------------------------------
-- 9.3  Block enforcement — INSERT (RESTRICTIVE)
-- ---------------------------------------------------------------------------
CREATE POLICY enforce_no_block_guess ON public.guess_attempts AS RESTRICTIVE
  FOR INSERT TO authenticated WITH CHECK (NOT private.has_block_with_poster(challenge_id));

CREATE POLICY enforce_no_block_comment ON public.comments AS RESTRICTIVE
  FOR INSERT TO authenticated WITH CHECK (NOT private.has_block_with_poster(challenge_id));

CREATE POLICY enforce_no_block_reaction ON public.reactions AS RESTRICTIVE
  FOR INSERT TO authenticated WITH CHECK (NOT private.has_block_with_poster(challenge_id));

-- ---------------------------------------------------------------------------
-- 9.4  Block enforcement — SELECT (RESTRICTIVE)
-- ---------------------------------------------------------------------------
CREATE POLICY hide_blocked_challenges ON public.challenges AS RESTRICTIVE
  FOR SELECT TO authenticated
  USING (
    poster_id = private.auth_uid()
    OR NOT private.has_block_with(poster_id)
    OR EXISTS (
      SELECT 1 FROM public.eligible_participants ep
      WHERE ep.challenge_id = public.challenges.id AND ep.player_id = private.auth_uid()
    )
  );

CREATE POLICY block_aware_comment_visibility ON public.comments AS RESTRICTIVE
  FOR SELECT TO authenticated
  USING (
    private.can_view_challenge(challenge_id)
    AND NOT private.has_block_with(author_id)
  );

CREATE POLICY block_aware_reaction_visibility ON public.reactions AS RESTRICTIVE
  FOR SELECT TO authenticated
  USING (
    private.can_view_challenge(challenge_id)
    AND NOT private.has_block_with(player_id)
  );

-- ---------------------------------------------------------------------------
-- 9.5  Moderator-removed clues — hidden (RESTRICTIVE)
-- ---------------------------------------------------------------------------
CREATE POLICY hide_removed_clues ON public.clues AS RESTRICTIVE
  FOR SELECT TO authenticated
  USING (moderator_removed_at IS NULL);

-- ---------------------------------------------------------------------------
-- 9.6  Block-aware visibility on challenge-linked child tables (RESTRICTIVE)
-- Applied to: clues, challenge_secrets, challenge_answer_aliases, guess_attempts,
--             guess_judgments, score_runs, score_events, correction_events,
--             eligible_participants, exclusion_events
-- ---------------------------------------------------------------------------
CREATE POLICY block_aware_visibility ON public.clues AS RESTRICTIVE
  FOR SELECT TO authenticated
  USING (private.can_view_challenge(challenge_id));

CREATE POLICY block_aware_visibility ON public.challenge_secrets AS RESTRICTIVE
  FOR SELECT TO authenticated
  USING (private.can_view_challenge(challenge_id));

CREATE POLICY block_aware_visibility ON public.challenge_answer_aliases AS RESTRICTIVE
  FOR SELECT TO authenticated
  USING (private.can_view_challenge(challenge_id));

CREATE POLICY block_aware_visibility ON public.guess_attempts AS RESTRICTIVE
  FOR SELECT TO authenticated
  USING (private.can_view_challenge(challenge_id));

CREATE POLICY block_aware_visibility ON public.guess_judgments AS RESTRICTIVE
  FOR SELECT TO authenticated
  USING (private.can_view_challenge(challenge_id));

CREATE POLICY block_aware_visibility ON public.score_runs AS RESTRICTIVE
  FOR SELECT TO authenticated
  USING (private.can_view_challenge(challenge_id));

CREATE POLICY block_aware_visibility ON public.score_events AS RESTRICTIVE
  FOR SELECT TO authenticated
  USING (private.can_view_challenge(challenge_id));

CREATE POLICY block_aware_visibility ON public.correction_events AS RESTRICTIVE
  FOR SELECT TO authenticated
  USING (private.can_view_challenge(challenge_id));

CREATE POLICY block_aware_visibility ON public.eligible_participants AS RESTRICTIVE
  FOR SELECT TO authenticated
  USING (private.can_view_challenge(challenge_id));

CREATE POLICY block_aware_visibility ON public.exclusion_events AS RESTRICTIVE
  FOR SELECT TO authenticated
  USING (private.can_view_challenge(challenge_id));

-- ---------------------------------------------------------------------------
-- 9.7  user_blocks SELECT policy (PERMISSIVE — new table, no V1 baseline)
-- ---------------------------------------------------------------------------
CREATE POLICY blocks_select_own ON public.user_blocks AS PERMISSIVE
  FOR SELECT TO authenticated
  USING (blocker_id = private.auth_uid());

-- =============================================================================
-- V3__ugc_safety_moderation.sql applied successfully.
-- Tables:     public.content_reports, public.user_blocks, public.moderation_actions,
--             public.group_ownership_history
--             private.moderation_action_reports, private.blocked_terms,
--             private.moderators, private.profile_suspensions,
--             private.moderation_evidence
-- Columns:    profiles.is_suspended, challenges/comments/clues.moderator_removed_at,
--             challenges/comments/clues.moderator_removal_action_id,
--             media_objects.moderated_at, media_objects.moderation_cleanup_leased_until,
--             media_storage_keys.sha256_hash (NOT NULL enforcement, V2b)
-- Constraints: *_removal_consistency checks on challenges/comments/clues;
--              moderation_action_reports_one_resolution UNIQUE(report_id)
-- Functions:  24 new public/private functions; 5 V1 functions updated (suspension guards);
--             transfer_group_ownership rewritten with group_ownership_history audit
-- Triggers:   force_*_removal_null (INSERT forge-null × 3),
--             restrict_*_removal_fields (UPDATE guard × 2),
--             *_immutable (immutability × 3),
--             *_text_filter (*_filter × 9 UGC fields),
--             comment_updates trigger replaced (Part 2)
-- RLS:        14 new RESTRICTIVE policies on existing tables;
--             1 PERMISSIVE policy on user_blocks;
--             user_blocks SELECT re-granted to authenticated
-- Grants:     forkensics_executor column-level and table-level;
--             forkensics_rls_helper table-level;
--             authenticated EXECUTE on report_content, block_user, unblock_user, get_my_reports;
--             service_role EXECUTE on all moderation/admin functions
-- =============================================================================

COMMIT;
