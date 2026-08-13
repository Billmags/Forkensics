-- =============================================================================
-- V4__case_investigation_schema.sql
-- Step 26: Case / Investigation Schema Split
-- Prerequisite: V3__ugc_safety_moderation.sql must be applied and tagged first.
-- Governance: APPROVED by Bill, Claude, and Codex — Rev 15 (2026-08-08).
-- Corrections: Rev 3 Correction Plan (Gate 3) — all 12 blockers applied.
-- R5 (Codex static-review): 13 blockers + 2 governance fixes applied.
-- R7 (R6 correction plan): 6 blockers applied (B1 role grants, B2 reserve_upload,
--    B3 constraint name, B4 guess policy, B5 trigger disable, B6 lock order).
-- One transaction. Stop immediately on any error; do NOT repair inline.
-- =============================================================================

BEGIN;

-- =============================================================================
-- PHASE 0 — MIGRATION GUARD
-- Verify V3 prerequisite (private.moderators table created by V3).
-- =============================================================================

DO $guard$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'private' AND table_name = 'moderators'
  ) THEN
    RAISE EXCEPTION 'V4 prerequisite not met: V3__ugc_safety_moderation.sql must be applied first';
  END IF;

  -- Also guard against double-application: cases table must NOT yet exist.
  IF EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'public' AND table_name = 'cases'
  ) THEN
    RAISE EXCEPTION 'V4 already applied: public.cases already exists';
  END IF;
END $guard$;


-- =============================================================================
-- PHASE 1 — RENAME TABLES
-- challenges → cases
-- challenge_secrets → case_secrets
-- (All FK references from other tables automatically follow the rename in PG.)
-- =============================================================================

ALTER TABLE public.challenges        RENAME TO cases;
ALTER TABLE public.challenge_secrets RENAME TO case_secrets;

-- Rename named constraints on cases
ALTER TABLE public.cases RENAME CONSTRAINT challenges_state_check        TO cases_state_check_temp;
ALTER TABLE public.cases RENAME CONSTRAINT challenges_duration_check      TO cases_duration_check;
ALTER TABLE public.cases RENAME CONSTRAINT challenges_cancellation_check  TO cases_cancellation_check;
ALTER TABLE public.cases RENAME CONSTRAINT challenges_city_display_check  TO cases_city_display_check;

-- Rename FK column in case_secrets (challenge_id → case_id)
ALTER TABLE public.case_secrets RENAME COLUMN challenge_id TO case_id;


-- =============================================================================
-- PHASE 2 — RENAME challenge_id COLUMNS IN ALL DEPENDENT TABLES
-- =============================================================================

ALTER TABLE public.clues                    RENAME COLUMN challenge_id TO case_id;
ALTER TABLE public.comments                 RENAME COLUMN challenge_id TO case_id;
ALTER TABLE public.reactions                RENAME COLUMN challenge_id TO case_id;
ALTER TABLE public.guess_attempts           RENAME COLUMN challenge_id TO case_id;
ALTER TABLE public.correction_events        RENAME COLUMN challenge_id TO case_id;
ALTER TABLE public.score_runs               RENAME COLUMN challenge_id TO case_id;
ALTER TABLE public.guess_judgments          RENAME COLUMN challenge_id TO case_id;
ALTER TABLE public.score_events             RENAME COLUMN challenge_id TO case_id;
ALTER TABLE public.eligible_participants    RENAME COLUMN challenge_id TO case_id;
ALTER TABLE public.exclusion_events         RENAME COLUMN challenge_id TO case_id;
ALTER TABLE public.challenge_answer_aliases RENAME COLUMN challenge_id TO case_id;

-- Update private.upload_sessions challenge_id → case_id
ALTER TABLE private.upload_sessions RENAME COLUMN challenge_id TO case_id;

-- Path column names in upload_sessions are unchanged (original_storage_path, display_storage_path).
-- No rename needed.

-- Rename the challenge_answer_aliases table
ALTER TABLE public.challenge_answer_aliases RENAME TO case_answer_aliases;

-- Update ce_alias_fk to point to new table name (constraint automatically updated,
-- but name references old table — drop and re-add with correct name for clarity)
ALTER TABLE public.correction_events DROP CONSTRAINT ce_alias_fk;
ALTER TABLE public.correction_events
  ADD CONSTRAINT ce_alias_fk
    FOREIGN KEY (alias_id)
    REFERENCES public.case_answer_aliases(id) ON DELETE RESTRICT;



-- ---- EARLY ROLE GRANTS (R6-B1) ----
-- postgres needs forkensics_executor membership before Phase 2A runs OWNER TO.
-- Supabase postgres is not a superuser; the grant must precede the first OWNER TO.
-- Matching REVOKEs remain at the end of Phase 20 (lines 4300-4305).
GRANT forkensics_executor   TO postgres;
GRANT forkensics_rls_helper  TO postgres;
-- GRANT CREATE ON SCHEMA required for ALTER FUNCTION OWNER TO in PostgreSQL 16+
GRANT CREATE ON SCHEMA private TO forkensics_executor, forkensics_rls_helper;
GRANT CREATE ON SCHEMA public  TO forkensics_executor;

-- =============================================================================
-- PHASE 2A — UPDATE V2 FUNCTIONS AND TRIGGERS FOR CASE/CASE_ID RENAMES
-- Blocker 5B: reserve_upload_session / finalize_upload_session
-- Blocker 5C: check_activation_no_active_upload / check_activation_media_ready
-- Blocker 5D: drop old V2 triggers; create renamed V4 triggers on public.cases
-- Blocker 5E: rename upload_sessions_one_active_per_challenge index
-- =============================================================================

-- ---- 5B.1  reserve_upload_session — V4 (R6-B2: DROP+CREATE, p_case_id throughout) ----
-- PostgreSQL cannot rename existing function input parameters via CREATE OR REPLACE;
-- DROP + CREATE is required to rename p_challenge_id → p_case_id in the catalog.
REVOKE ALL ON FUNCTION public.reserve_upload_session(uuid,uuid,text,text,bigint,timestamptz)
  FROM PUBLIC, anon, authenticated, service_role;
DROP FUNCTION IF EXISTS public.reserve_upload_session(uuid,uuid,text,text,bigint,timestamptz);
CREATE FUNCTION public.reserve_upload_session(
  p_case_id           uuid,
  p_uploader_id       uuid,
  p_token_hash        text,
  p_content_type      text,
  p_declared_size     bigint,
  p_client_expires_at timestamptz
)
RETURNS TABLE (session_id uuid, original_storage_path text, display_storage_path text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_case       record;
  v_session_id uuid := gen_random_uuid();
  v_orig_path  text;
  v_disp_path  text;
BEGIN
  SELECT id, poster_id, state
  INTO v_case
  FROM public.cases
  WHERE id = p_case_id
  FOR UPDATE;

  IF NOT FOUND OR v_case.poster_id != p_uploader_id THEN
    RAISE EXCEPTION 'FK_NOT_FOUND';
  END IF;

  IF v_case.state != 'draft' THEN
    RAISE EXCEPTION 'FK_WRONG_STATE';
  END IF;

  IF EXISTS (
    SELECT 1 FROM private.deletion_log
    WHERE profile_id = p_uploader_id
      AND status IN ('database_prepared', 'auth_deleted')
  ) THEN
    RAISE EXCEPTION 'FK_FORBIDDEN';
  END IF;

  v_orig_path := 'cases/' || p_case_id::text || '/originals/' || v_session_id::text;
  v_disp_path := 'cases/' || p_case_id::text || '/displays/'  || v_session_id::text || '.webp';

  BEGIN
    INSERT INTO private.upload_sessions (
      session_id, upload_token_hash, case_id, uploader_id,
      original_storage_path, display_storage_path,
      content_type, declared_size_bytes, expires_at,
      storage_upload_expires_at, status, status_changed_at
    ) VALUES (
      v_session_id, p_token_hash, p_case_id, p_uploader_id,
      v_orig_path, v_disp_path,
      p_content_type, p_declared_size, p_client_expires_at,
      NULL, 'pending', now()
    );
  EXCEPTION
    WHEN unique_violation THEN
      RAISE EXCEPTION 'FK_UPLOAD_IN_PROGRESS';
  END;

  RETURN QUERY SELECT v_session_id, v_orig_path, v_disp_path;
END;
$$;
ALTER FUNCTION public.reserve_upload_session(uuid,uuid,text,text,bigint,timestamptz)
  OWNER TO forkensics_executor;
GRANT EXECUTE ON FUNCTION public.reserve_upload_session(uuid,uuid,text,text,bigint,timestamptz)
  TO service_role;

-- ---- 5B.2  finalize_upload_session (challenges → cases; challenge_id → case_id) ----
CREATE OR REPLACE FUNCTION public.finalize_upload_session(
  p_session_id  uuid,
  p_sha256_hash text
)
RETURNS TABLE (media_object_id uuid, replaced_media_object_id uuid)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_session              record;
  v_case                 record;
  v_new_media_object_id  uuid;
  v_old_media_object_id  uuid;
BEGIN
  IF p_sha256_hash IS NULL OR p_sha256_hash !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'FK_INVALID_HASH: sha256_hash must be 64 lowercase hex characters';
  END IF;

  SELECT us.session_id, us.uploader_id, us.case_id, us.status,
         us.original_storage_path, us.display_storage_path, us.content_type,
         us.media_object_id, us.replaced_media_object_id
  INTO v_session
  FROM private.upload_sessions us
  WHERE us.session_id = p_session_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'FK_WRONG_STATE: session not found (session_id: %)', p_session_id;
  END IF;

  IF v_session.status = 'complete' THEN
    RETURN QUERY SELECT v_session.media_object_id, v_session.replaced_media_object_id;
    RETURN;
  END IF;

  IF v_session.status != 'sanitized' THEN
    RAISE EXCEPTION 'FK_WRONG_STATE: session is not sanitized (status: %)', v_session.status;
  END IF;

  SELECT c.id, c.state, c.media_object_id
  INTO v_case
  FROM public.cases AS c
  WHERE c.id = v_session.case_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'FK_WRONG_STATE: case not found';
  END IF;

  IF v_case.state != 'draft' THEN
    RAISE EXCEPTION 'FK_WRONG_STATE: case is not in draft state (state: %)', v_case.state;
  END IF;

  v_old_media_object_id := v_case.media_object_id;

  INSERT INTO public.media_objects (uploader_id, mime_type, status, re_encoded_at)
  VALUES (v_session.uploader_id, 'image/webp', 'pending_review', now())
  RETURNING id INTO v_new_media_object_id;

  INSERT INTO private.media_storage_keys (
    media_object_id, storage_key, re_encoded_storage_key, sha256_hash
  ) VALUES (
    v_new_media_object_id,
    v_session.original_storage_path,
    v_session.display_storage_path,
    p_sha256_hash
  );

  IF v_old_media_object_id IS NOT NULL THEN
    UPDATE public.media_objects
    SET status = 'superseded'
    WHERE id = v_old_media_object_id;
  END IF;

  UPDATE public.cases
  SET media_object_id = v_new_media_object_id
  WHERE id = v_session.case_id;

  UPDATE private.upload_sessions
  SET
    status                    = 'complete',
    status_changed_at         = now(),
    media_object_id           = v_new_media_object_id,
    replaced_media_object_id  = v_old_media_object_id
  WHERE session_id = p_session_id;

  RETURN QUERY SELECT v_new_media_object_id, v_old_media_object_id;
END;
$$;

-- ---- 5C  V2 trigger functions: state names ready/launched ----
CREATE OR REPLACE FUNCTION private.check_activation_no_active_upload()
RETURNS trigger LANGUAGE plpgsql SET search_path = ''
AS $$
BEGIN
  IF OLD.state = 'ready' AND NEW.state = 'launched' THEN
    IF EXISTS (
      SELECT 1 FROM private.upload_sessions
      WHERE case_id = NEW.id
        AND status IN ('pending', 'processing', 'sanitized')
    ) THEN
      RAISE EXCEPTION 'case cannot be launched while an active upload session exists (status: pending, processing, or sanitized)';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION private.check_activation_media_ready()
RETURNS trigger LANGUAGE plpgsql SET search_path = ''
AS $$
BEGIN
  IF OLD.state = 'ready' AND NEW.state = 'launched' THEN
    IF NEW.media_object_id IS NULL OR NOT EXISTS (
      SELECT 1 FROM public.media_objects
      WHERE id = NEW.media_object_id AND status = 'ready'
    ) THEN
      RAISE EXCEPTION 'case media object must be present and have status ''ready'' before launch';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

-- ---- 5D  Drop old V2 triggers; create renamed V4 triggers ----
DROP TRIGGER IF EXISTS challenge_v2_no_active_upload_on_activate ON public.cases;
DROP TRIGGER IF EXISTS challenge_v2_media_ready_on_activate      ON public.cases;

CREATE OR REPLACE TRIGGER case_v4_no_active_upload_on_launch
  BEFORE UPDATE ON public.cases
  FOR EACH ROW EXECUTE PROCEDURE private.check_activation_no_active_upload();

CREATE OR REPLACE TRIGGER case_v4_media_ready_on_launch
  BEFORE UPDATE ON public.cases
  FOR EACH ROW EXECUTE PROCEDURE private.check_activation_media_ready();

-- ---- 5E  Rename upload_sessions partial unique index ----
ALTER INDEX IF EXISTS private.upload_sessions_one_active_per_challenge
  RENAME TO upload_sessions_one_active_per_case;

-- =============================================================================

-- ===========================================================================
-- PHASE 2B — EARLY TRIGGER REPAIRS (must precede Phase 10 and Phase 16)
-- B4: restrict_comment_updates fires during Phase 10 comments backfill;
--     V3 body references NEW.challenge_id which no longer exists after Phase 2A.
-- B5: check_text_content_trigger fires when Phase 16 UPDATEs public.cases;
--     V3 body matches 'challenges' not 'cases' — would silently pass unchecked.
-- ===========================================================================

-- ---- 2B.1  check_text_content_trigger — V4 fail-closed body (B5) ----
CREATE OR REPLACE FUNCTION private.check_text_content_trigger()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_col  text;
  v_text text;
BEGIN
  IF TG_NARGS <> 1 THEN
    RAISE EXCEPTION
      'check_text_content_trigger: expected 1 argument (column name), got %', TG_NARGS;
  END IF;
  v_col := TG_ARGV[0];
  IF NOT (
       TG_TABLE_SCHEMA = 'public'
    AND (
         (TG_TABLE_NAME = 'comments'             AND v_col = 'text')
      OR (TG_TABLE_NAME = 'clues'                AND v_col = 'text')
      OR (TG_TABLE_NAME = 'profiles'             AND v_col = 'display_name')
      OR (TG_TABLE_NAME = 'groups'               AND v_col = 'name')
      OR (TG_TABLE_NAME = 'cases'                AND v_col = 'public_city_display')
      OR (TG_TABLE_NAME = 'case_secrets'         AND v_col IN ('display_dish','display_restaurant','story'))
      OR (TG_TABLE_NAME = 'case_answer_aliases'  AND v_col = 'display_value')
    )
  ) THEN
    RAISE EXCEPTION
      'check_text_content_trigger: unauthorized pairing schema=% table=% col=%',
      TG_TABLE_SCHEMA, TG_TABLE_NAME, v_col;
  END IF;
  IF NOT (to_jsonb(NEW) ? v_col) THEN
    RAISE EXCEPTION
      'check_text_content_trigger: column % not found on table %.%',
      v_col, TG_TABLE_SCHEMA, TG_TABLE_NAME;
  END IF;
  v_text := to_jsonb(NEW) ->> v_col;
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
ALTER FUNCTION private.check_text_content_trigger() OWNER TO forkensics_executor;

-- Re-attach triggers with correct column-name arguments (Phase 2B)
DROP TRIGGER IF EXISTS challenge_city_filter        ON public.cases;
DROP TRIGGER IF EXISTS case_city_filter             ON public.cases;
CREATE OR REPLACE TRIGGER case_city_filter
  BEFORE INSERT OR UPDATE ON public.cases FOR EACH ROW
  EXECUTE FUNCTION private.check_text_content_trigger('public_city_display');

DROP TRIGGER IF EXISTS challenge_alias_display_value_filter ON public.case_answer_aliases;
DROP TRIGGER IF EXISTS alias_display_value_filter           ON public.case_answer_aliases;
CREATE OR REPLACE TRIGGER alias_display_value_filter
  BEFORE INSERT OR UPDATE ON public.case_answer_aliases FOR EACH ROW
  EXECUTE FUNCTION private.check_text_content_trigger('display_value');

-- ---- 2B.2  restrict_comment_updates — V4 body with migration backfill path (B4) ----
DROP TRIGGER IF EXISTS comment_update_guard ON public.comments;

CREATE OR REPLACE FUNCTION public.restrict_comment_updates()
RETURNS trigger LANGUAGE plpgsql SECURITY INVOKER SET search_path = ''
AS $$
BEGIN
  -- Path 0 (B4 — migration backfill): postgres may set investigation_id from NULL.
  IF current_user = 'postgres'
     AND OLD.investigation_id IS NULL
     AND NEW.investigation_id IS NOT NULL
     AND NEW.id IS NOT DISTINCT FROM OLD.id
     AND NEW.text IS NOT DISTINCT FROM OLD.text
     AND NEW.author_id IS NOT DISTINCT FROM OLD.author_id
     AND NEW.case_id IS NOT DISTINCT FROM OLD.case_id
     AND NEW.posted_at IS NOT DISTINCT FROM OLD.posted_at
     AND NEW.deleted_at IS NOT DISTINCT FROM OLD.deleted_at
     AND NEW.moderator_removed_at IS NOT DISTINCT FROM OLD.moderator_removed_at
     AND NEW.moderator_removal_action_id IS NOT DISTINCT FROM OLD.moderator_removal_action_id
  THEN RETURN NEW;
  END IF;
  -- Path 1: Moderator removal — only forkensics_executor.
  IF current_user = 'forkensics_executor'
     AND OLD.moderator_removed_at IS NULL
     AND OLD.moderator_removal_action_id IS NULL
     AND NEW.moderator_removed_at IS NOT NULL
     AND NEW.moderator_removal_action_id IS NOT NULL
     AND NEW.text = '[removed by moderator]'
     AND NEW.id IS NOT DISTINCT FROM OLD.id
     AND NEW.author_id IS NOT DISTINCT FROM OLD.author_id
     AND NEW.case_id IS NOT DISTINCT FROM OLD.case_id
     AND NEW.investigation_id IS NOT DISTINCT FROM OLD.investigation_id
     AND NEW.posted_at IS NOT DISTINCT FROM OLD.posted_at
     AND NEW.deleted_at IS NOT DISTINCT FROM OLD.deleted_at
  THEN
    NEW.moderator_removed_at := clock_timestamp();
    RETURN NEW;
  END IF;
  -- Path 2: Author soft-delete.
  IF NEW.author_id = private.auth_uid()
     AND OLD.deleted_at IS NULL
     AND NEW.deleted_at IS NOT NULL
     AND NEW.id IS NOT DISTINCT FROM OLD.id
     AND NEW.text IS NOT DISTINCT FROM OLD.text
     AND NEW.case_id IS NOT DISTINCT FROM OLD.case_id
     AND NEW.investigation_id IS NOT DISTINCT FROM OLD.investigation_id
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
ALTER FUNCTION public.restrict_comment_updates() OWNER TO forkensics_executor;

CREATE OR REPLACE TRIGGER comment_update_guard
  BEFORE UPDATE ON public.comments
  FOR EACH ROW EXECUTE PROCEDURE public.restrict_comment_updates();

-- PHASE 3 — TWO-STEP MODERATION CONSTRAINT: content_reports target_type
-- Step 1: Allow both 'challenge' and 'case' temporarily.
-- Step 2: UPDATE existing rows.
-- Step 3: Drop temp; add final constraint.
-- =============================================================================

ALTER TABLE public.content_reports DROP CONSTRAINT cr_target_type_check;
ALTER TABLE public.content_reports ADD CONSTRAINT cr_target_type_check_temp
  CHECK (target_type IN ('challenge','case','comment','clue','profile','media_object'));

UPDATE public.content_reports SET target_type = 'case' WHERE target_type = 'challenge';

ALTER TABLE public.content_reports DROP CONSTRAINT cr_target_type_check_temp;
ALTER TABLE public.content_reports ADD CONSTRAINT cr_target_type_check
  CHECK (target_type IN ('case','comment','clue','profile','media_object'));


-- =============================================================================
-- PHASE 4 — TWO-STEP MODERATION CONSTRAINT: moderation_actions target_type
-- =============================================================================

ALTER TABLE public.moderation_actions DROP CONSTRAINT ma_target_type_check;
ALTER TABLE public.moderation_actions ADD CONSTRAINT ma_target_type_check_temp
  CHECK (target_type IS NULL OR
         target_type IN ('challenge','case','comment','clue','profile','media_object'));

-- B3: disable immutability trigger for this controlled backfill
ALTER TABLE public.moderation_actions DISABLE TRIGGER moderation_actions_immutable;
UPDATE public.moderation_actions SET target_type = 'case' WHERE target_type = 'challenge';
ALTER TABLE public.moderation_actions ENABLE TRIGGER moderation_actions_immutable;

ALTER TABLE public.moderation_actions DROP CONSTRAINT ma_target_type_check_temp;
ALTER TABLE public.moderation_actions ADD CONSTRAINT ma_target_type_check
  CHECK (target_type IS NULL OR
         target_type IN ('case','comment','clue','profile','media_object'));

-- Also update challenges_removal_consistency constraint name on cases (V3 added this)
-- Column is still moderator_removed_at / moderator_removal_action_id — no change needed.
-- Rename constraint for clarity:
ALTER TABLE public.cases RENAME CONSTRAINT challenges_removal_consistency TO cases_removal_consistency;


-- =============================================================================
-- PHASE 5 — CREATE public.investigations
-- =============================================================================

CREATE TABLE public.investigations (
  investigation_id    uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  case_id             uuid        NOT NULL REFERENCES public.cases(id)   ON DELETE RESTRICT,
  group_id            uuid        NOT NULL REFERENCES public.groups(id)  ON DELETE RESTRICT,
  status              text        NOT NULL DEFAULT 'active',
  cancelled_at        timestamptz,
  cancellation_reason text,
  created_at          timestamptz NOT NULL DEFAULT clock_timestamp(),

  UNIQUE (case_id, group_id),

  CONSTRAINT investigations_status_check
    CHECK (status IN ('active','cancelled','tombstoned')),
  CONSTRAINT investigations_cancellation_check
    CHECK (cancellation_reason IS NULL OR length(cancellation_reason) <= 500)
);


-- =============================================================================
-- PHASE 6 — CREATE public.investigation_members
-- =============================================================================

CREATE TABLE public.investigation_members (
  investigation_id                  uuid  NOT NULL
                                          REFERENCES public.investigations(investigation_id)
                                          ON DELETE RESTRICT,
  player_id                         uuid  NOT NULL
                                          REFERENCES public.profiles(id) ON DELETE RESTRICT,
  snapshot_display_name             text  NOT NULL,
  snapshot_avatar_color             text  NOT NULL,
  snapshot_avatar_media_object_id   uuid  REFERENCES public.media_objects(id) ON DELETE SET NULL,
  eligibility_status                text  NOT NULL DEFAULT 'eligible',
  added_at                          timestamptz NOT NULL DEFAULT clock_timestamp(),

  PRIMARY KEY (investigation_id, player_id),

  CONSTRAINT im_eligibility_check
    CHECK (eligibility_status IN ('eligible','excluded','account_deleted'))
);


-- =============================================================================
-- PHASE 7 — POPULATE public.investigations FROM EXISTING CASES
-- One investigation per launched/active case, using the case's group_id.
-- Draft-only cases (never launched) get no investigation.
-- =============================================================================

INSERT INTO public.investigations (investigation_id, case_id, group_id, status, cancelled_at, created_at)
SELECT
  gen_random_uuid(),
  c.id,
  c.group_id,
  CASE WHEN c.state = 'cancelled' THEN 'cancelled' ELSE 'active' END,
  c.cancelled_at,
  COALESCE(c.posted_at, c.created_at)
FROM public.cases c
WHERE c.state NOT IN ('draft', 'ready')
  AND c.group_id IS NOT NULL;


-- =============================================================================
-- PHASE 8 — POPULATE public.investigation_members FROM eligible_participants
-- Poster is never in eligible_participants (V1 invariant), so no poster filter needed.
-- Eligibility status: account_deleted if profile inactive, excluded if in exclusion_events,
-- else eligible.
-- =============================================================================

INSERT INTO public.investigation_members (
  investigation_id,
  player_id,
  snapshot_display_name,
  snapshot_avatar_color,
  snapshot_avatar_media_object_id,
  eligibility_status,
  added_at
)
SELECT
  i.investigation_id,
  ep.player_id,
  COALESCE(p.display_name, '[deleted]'),
  p.avatar_color,
  p.avatar_media_object_id,
  CASE
    WHEN NOT p.is_active THEN 'account_deleted'
    WHEN EXISTS (
      SELECT 1 FROM public.exclusion_events ee
      WHERE ee.case_id = ep.case_id AND ee.player_id = ep.player_id
    ) THEN 'excluded'
    ELSE 'eligible'
  END,
  ep.added_at
FROM public.eligible_participants ep
JOIN public.investigations i ON i.case_id = ep.case_id
JOIN public.profiles p ON p.id = ep.player_id;


-- =============================================================================
-- PHASE 9 — ADD investigation_id (NULLABLE) TO SCORING / TALK TABLES
-- Populated in Phase 10, then made NOT NULL.
-- =============================================================================

-- Score tables
ALTER TABLE public.score_runs
  ADD COLUMN investigation_id uuid REFERENCES public.investigations(investigation_id) ON DELETE RESTRICT;

ALTER TABLE public.guess_judgments
  ADD COLUMN investigation_id uuid REFERENCES public.investigations(investigation_id) ON DELETE RESTRICT;

ALTER TABLE public.score_events
  ADD COLUMN investigation_id uuid REFERENCES public.investigations(investigation_id) ON DELETE RESTRICT;

-- Table Talk
ALTER TABLE public.comments
  ADD COLUMN investigation_id uuid REFERENCES public.investigations(investigation_id) ON DELETE RESTRICT;

ALTER TABLE public.reactions
  ADD COLUMN investigation_id uuid REFERENCES public.investigations(investigation_id) ON DELETE RESTRICT;

-- Exclusion events (needed by enforce_exclusion_rules trigger V4)
ALTER TABLE public.exclusion_events
  ADD COLUMN investigation_id uuid REFERENCES public.investigations(investigation_id) ON DELETE RESTRICT;


-- =============================================================================
-- PHASE 10 — BACKFILL investigation_id; ADD NOT NULL
-- Each existing case has at most one investigation (one group in V1).
-- =============================================================================

UPDATE public.score_runs sr
SET investigation_id = i.investigation_id
FROM public.investigations i
WHERE i.case_id = sr.case_id;

UPDATE public.guess_judgments gj
SET investigation_id = i.investigation_id
FROM public.score_runs sr
JOIN public.investigations i ON i.investigation_id = sr.investigation_id
WHERE gj.score_run_id = sr.id;

UPDATE public.score_events se
SET investigation_id = i.investigation_id
FROM public.score_runs sr
JOIN public.investigations i ON i.investigation_id = sr.investigation_id
WHERE se.score_run_id = sr.id;

UPDATE public.comments c
SET investigation_id = i.investigation_id
FROM public.investigations i
WHERE i.case_id = c.case_id;

UPDATE public.reactions r
SET investigation_id = i.investigation_id
FROM public.investigations i
WHERE i.case_id = r.case_id;

UPDATE public.exclusion_events ee
SET investigation_id = i.investigation_id
FROM public.investigations i
WHERE i.case_id = ee.case_id;

-- Make NOT NULL (rows with no investigation are from draft cases with no eligible_participants;
-- those tables should have no rows for draft cases, so this is safe).
ALTER TABLE public.score_runs       ALTER COLUMN investigation_id SET NOT NULL;
-- B6: Replace case-scoped unique with investigation-scoped unique.
--     UNIQUE(case_id,revision_number) blocks multiple investigations
--     per case from each having revision 1.
-- R6-B3: V1 auto-named the constraint after the original column (challenge_id);
--        column renames do not rename constraints. Drop the correct name.
ALTER TABLE public.score_runs
  DROP CONSTRAINT IF EXISTS score_runs_challenge_id_revision_number_key;
-- Safety net: also drop the case_id variant in case it ever existed.
ALTER TABLE public.score_runs
  DROP CONSTRAINT IF EXISTS score_runs_case_id_revision_number_key;
ALTER TABLE public.score_runs
  DROP CONSTRAINT IF EXISTS score_runs_inv_revision_unique;
ALTER TABLE public.score_runs
  ADD CONSTRAINT score_runs_inv_revision_unique UNIQUE (investigation_id, revision_number);

ALTER TABLE public.guess_judgments  ALTER COLUMN investigation_id SET NOT NULL;
ALTER TABLE public.score_events     ALTER COLUMN investigation_id SET NOT NULL;
ALTER TABLE public.comments         ALTER COLUMN investigation_id SET NOT NULL;
ALTER TABLE public.reactions        ALTER COLUMN investigation_id SET NOT NULL;
-- exclusion_events: nullable because pre-Phase-7 draft cases had no investigations;
-- but all exclusion_events belong to non-draft cases, so this too is safe.
ALTER TABLE public.exclusion_events ALTER COLUMN investigation_id SET NOT NULL;

-- Blocker 7A: drop old auto-named constraint (from challenge_id, now case_id after Phase 2)
-- Add new unique constraint on (investigation_id, player_id) per V4 semantics
ALTER TABLE public.exclusion_events
  DROP CONSTRAINT IF EXISTS exclusion_events_challenge_id_player_id_key;
ALTER TABLE public.exclusion_events
  ADD CONSTRAINT exclusion_events_inv_player_unique UNIQUE (investigation_id, player_id);


-- =============================================================================
-- PHASE 11 — GUESS ATTEMPTS ENHANCEMENTS
-- Add idempotency_key; add new UNIQUE constraints per Rev 15 §9.
-- =============================================================================

ALTER TABLE public.guess_attempts
  ADD COLUMN idempotency_key text;

-- UNIQUE (case_id, player_id, race) — one locked attempt per player per race
CREATE UNIQUE INDEX IF NOT EXISTS ga_one_per_player_race
  ON public.guess_attempts (case_id, player_id, race);

-- UNIQUE (case_id, player_id, idempotency_key) — client idempotency
CREATE UNIQUE INDEX IF NOT EXISTS ga_idempotency
  ON public.guess_attempts (case_id, player_id, idempotency_key)
  WHERE idempotency_key IS NOT NULL;


-- =============================================================================
-- PHASE 12 — private.upload_sessions: update upload_sessions for case context
-- challenge_id renamed in Phase 2; moderator_removed_at already on cases from V3.
-- No further schema changes needed here; confirm FK points to cases.
-- =============================================================================

-- Verify FK still valid (cases table exists, same physical table post-rename):
-- No DDL needed — PostgreSQL updated the FK target during Phase 1 table rename.


-- =============================================================================
-- PHASE 13 — update correction_events FK name to case_answer_aliases
-- (Already done in Phase 2; capture idx_aliases_challenge rename.)
-- =============================================================================

-- Drop old named indexes that reference 'challenge' (will recreate in Phase 17)
DROP INDEX IF EXISTS idx_challenges_group_id;
DROP INDEX IF EXISTS idx_challenges_state;
DROP INDEX IF EXISTS idx_guess_attempts_challenge;
DROP INDEX IF EXISTS idx_score_events_challenge;
DROP INDEX IF EXISTS idx_clues_challenge;
DROP INDEX IF EXISTS idx_comments_challenge;
DROP INDEX IF EXISTS idx_reactions_challenge;
DROP INDEX IF EXISTS idx_aliases_challenge;
DROP INDEX IF EXISTS idx_aliases_active_unique;
DROP INDEX IF EXISTS idx_correction_challenge;
DROP INDEX IF EXISTS idx_eligible_challenge;
DROP INDEX IF EXISTS idx_exclusion_challenge;
-- Also drop the V1 partial unique index (will recreate in Phase 17 with new name and predicate)
DROP INDEX IF EXISTS one_active_challenge_per_poster;


-- =============================================================================
-- PHASE 13A — DROP STALE V1 LIFECYCLE FUNCTIONS AND V2 WRAPPER
-- Blocker 5A: dependency-safe order; explicit REVOKE before DROP; no CASCADE.
-- =============================================================================

-- Step 1: Drop V2 wrapper first (calls V1 reveal_challenge_service)
DROP FUNCTION IF EXISTS public.reveal_challenge_service_wrapper(uuid);

REVOKE EXECUTE ON FUNCTION public.reveal_challenge(uuid) FROM authenticated;
DROP FUNCTION IF EXISTS public.reveal_challenge(uuid);

REVOKE EXECUTE ON FUNCTION private.reveal_challenge_service(uuid) FROM service_role;
DROP FUNCTION IF EXISTS private.reveal_challenge_service(uuid);

-- Step 2: Drop do_reveal_impl after all callers are gone
DROP FUNCTION IF EXISTS private.do_reveal_impl(uuid);

-- Step 3: Drop remaining V1 lifecycle functions
REVOKE EXECUTE ON FUNCTION public.activate_challenge(uuid) FROM authenticated;
DROP FUNCTION IF EXISTS public.activate_challenge(uuid);

REVOKE EXECUTE ON FUNCTION public.lock_challenge(uuid) FROM service_role;
DROP FUNCTION IF EXISTS public.lock_challenge(uuid);

REVOKE EXECUTE ON FUNCTION public.cancel_challenge(uuid, text) FROM authenticated;
DROP FUNCTION IF EXISTS public.cancel_challenge(uuid, text);


-- =============================================================================
-- PHASE 13B — DROP ALL OLD RLS POLICIES ON AFFECTED TABLES
-- Policies reference column names and function names that are changing.
-- Drop ALL policies on all affected tables; recreate complete set in Phase 15.
-- Using dynamic SQL so we don't need to know exact V1/V3 policy names.
-- =============================================================================

DO $drop_policies$ DECLARE r record; BEGIN
  FOR r IN SELECT policyname, tablename FROM pg_policies WHERE schemaname='public' AND tablename IN (
    'cases','case_secrets','clues','comments','reactions','guess_attempts',
    'eligible_participants','exclusion_events','correction_events',
    'score_runs','guess_judgments','score_events'
  ) LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', r.policyname, r.tablename);
  END LOOP;
END $drop_policies$;

DO $drop_alias_policies$ DECLARE r record; BEGIN
  FOR r IN SELECT policyname FROM pg_policies WHERE schemaname='public' AND tablename='case_answer_aliases' LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.case_answer_aliases', r.policyname);
  END LOOP;
END $drop_alias_policies$;


-- =============================================================================
-- PHASE 13C — NOTE: Role grants moved to before Phase 2A (R6-B1)
-- postgres requires forkensics_executor membership before OWNER TO in Phase 2A/2B.
-- The four GRANT statements that used to live here are now at the top of the
-- migration, immediately before Phase 2A. REVOKEs remain at end of Phase 20.
-- =============================================================================


-- =============================================================================
-- PHASE 14 — DROP OLD RLS HELPER FUNCTIONS; CREATE NEW ONES
-- All helpers: SECURITY DEFINER, OWNER = forkensics_rls_helper.
-- =============================================================================

-- Drop old challenge-specific helpers
DROP FUNCTION IF EXISTS private.is_challenge_group_member(uuid);
DROP FUNCTION IF EXISTS private.is_challenge_poster(uuid);
DROP FUNCTION IF EXISTS private.is_challenge_revealed(uuid);
DROP FUNCTION IF EXISTS private.is_eligible_non_excluded(uuid);

-- caller_has_guessed: update to reference case_id
DROP FUNCTION IF EXISTS private.caller_has_guessed(uuid);
CREATE OR REPLACE FUNCTION private.caller_has_guessed(p_case_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.guess_attempts
    WHERE case_id   = p_case_id
      AND player_id = private.auth_uid()
  );
$$;
ALTER FUNCTION private.caller_has_guessed(uuid) OWNER TO forkensics_rls_helper;

-- has_block_with_poster: update challenges → cases
DROP FUNCTION IF EXISTS private.has_block_with_poster(uuid);
CREATE OR REPLACE FUNCTION private.has_block_with_poster(p_case_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.cases c
    JOIN   public.user_blocks ub
      ON  (ub.blocker_id = private.auth_uid() AND ub.blocked_id = c.poster_id)
       OR (ub.blocker_id = c.poster_id        AND ub.blocked_id = private.auth_uid())
    WHERE c.id = p_case_id
  );
$$;
ALTER FUNCTION private.has_block_with_poster(uuid) OWNER TO forkensics_rls_helper;

-- NEW: is_case_poster
CREATE OR REPLACE FUNCTION private.is_case_poster(p_case_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.cases
    WHERE id        = p_case_id
      AND poster_id = private.auth_uid()
  );
$$;
ALTER FUNCTION private.is_case_poster(uuid) OWNER TO forkensics_rls_helper;

-- NEW: is_case_revealed
CREATE OR REPLACE FUNCTION private.is_case_revealed(p_case_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.cases
    WHERE id    = p_case_id
      AND state = 'revealed'
  );
$$;
ALTER FUNCTION private.is_case_revealed(uuid) OWNER TO forkensics_rls_helper;

-- NEW: is_case_member (caller is a member of any investigation for this case)
CREATE OR REPLACE FUNCTION private.is_case_member(p_case_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.investigations i
    JOIN public.investigation_members im ON im.investigation_id = i.investigation_id
    WHERE i.case_id    = p_case_id
      AND im.player_id = private.auth_uid()
  );
$$;
ALTER FUNCTION private.is_case_member(uuid) OWNER TO forkensics_rls_helper;

-- NEW: is_investigation_member (caller is a member of a specific investigation)
CREATE OR REPLACE FUNCTION private.is_investigation_member(p_investigation_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.investigation_members
    WHERE investigation_id = p_investigation_id
      AND player_id        = private.auth_uid()
  );
$$;
ALTER FUNCTION private.is_investigation_member(uuid) OWNER TO forkensics_rls_helper;

-- NEW: is_case_poster_for_investigation
CREATE OR REPLACE FUNCTION private.is_case_poster_for_investigation(p_investigation_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.investigations i
    JOIN public.cases c ON c.id = i.case_id
    WHERE i.investigation_id = p_investigation_id
      AND c.poster_id        = private.auth_uid()
  );
$$;
ALTER FUNCTION private.is_case_poster_for_investigation(uuid) OWNER TO forkensics_rls_helper;

-- NEW: is_investigation_eligible (member is eligible in a specific investigation)
CREATE OR REPLACE FUNCTION private.is_investigation_eligible(p_investigation_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.investigation_members
    WHERE investigation_id  = p_investigation_id
      AND player_id         = private.auth_uid()
      AND eligibility_status = 'eligible'
  );
$$;
ALTER FUNCTION private.is_investigation_eligible(uuid) OWNER TO forkensics_rls_helper;

-- UPDATE: can_view_case (replaces can_view_challenge)
DROP FUNCTION IF EXISTS private.can_view_challenge(uuid);
CREATE OR REPLACE FUNCTION private.can_view_case(p_case_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  -- Poster always can view their own case
  SELECT
    EXISTS (SELECT 1 FROM public.cases WHERE id = p_case_id AND poster_id = private.auth_uid())
    OR
    -- Any investigation member (active profile) can view
    EXISTS (
      SELECT 1
      FROM public.investigations i
      JOIN public.investigation_members im ON im.investigation_id = i.investigation_id
      WHERE i.case_id    = p_case_id
        AND im.player_id = private.auth_uid()
    );
$$;
ALTER FUNCTION private.can_view_case(uuid) OWNER TO forkensics_rls_helper;

-- UPDATE: can_viewer_access_case (replaces can_viewer_access_challenge)
DROP FUNCTION IF EXISTS private.can_viewer_access_challenge(uuid, uuid);
CREATE OR REPLACE FUNCTION private.can_viewer_access_case(p_case_id uuid, p_viewer_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT
    EXISTS (SELECT 1 FROM public.cases WHERE id = p_case_id AND poster_id = p_viewer_id)
    OR
    EXISTS (
      SELECT 1
      FROM public.investigations i
      JOIN public.investigation_members im ON im.investigation_id = i.investigation_id
      WHERE i.case_id    = p_case_id
        AND im.player_id = p_viewer_id
    );
$$;
ALTER FUNCTION private.can_viewer_access_case(uuid, uuid) OWNER TO forkensics_rls_helper;


-- =============================================================================
-- PHASE 15 — ENABLE RLS ON NEW TABLES; CREATE ALL RLS POLICIES
-- =============================================================================

-- Enable RLS on new tables
ALTER TABLE public.investigations       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.investigation_members ENABLE ROW LEVEL SECURITY;

-- ---- investigations policies ----

CREATE POLICY investigations_member_view ON public.investigations
  AS PERMISSIVE FOR SELECT
  USING (
    private.is_investigation_member(investigation_id)
    AND EXISTS (SELECT 1 FROM public.profiles
                WHERE id = private.auth_uid() AND is_active = true)
  );

CREATE POLICY investigations_poster_view ON public.investigations
  AS PERMISSIVE FOR SELECT
  USING (
    private.is_case_poster_for_investigation(investigation_id)
    AND EXISTS (SELECT 1 FROM public.profiles
                WHERE id = private.auth_uid() AND is_active = true)
  );

-- ---- investigation_members policies ----

CREATE POLICY investigation_members_member_view ON public.investigation_members
  AS PERMISSIVE FOR SELECT
  USING (
    private.is_investigation_member(investigation_id)
    AND EXISTS (SELECT 1 FROM public.profiles
                WHERE id = private.auth_uid() AND is_active = true)
  );

CREATE POLICY investigation_members_poster_view ON public.investigation_members
  AS PERMISSIVE FOR SELECT
  USING (
    private.is_case_poster_for_investigation(investigation_id)
    AND EXISTS (SELECT 1 FROM public.profiles
                WHERE id = private.auth_uid() AND is_active = true)
  );

-- ---- score_runs: add poster policy ----
CREATE POLICY score_runs_poster_view ON public.score_runs
  AS PERMISSIVE FOR SELECT
  USING (
    private.is_case_poster_for_investigation(investigation_id)
    AND EXISTS (SELECT 1 FROM public.profiles
                WHERE id = private.auth_uid() AND is_active = true)
  );

-- ---- guess_judgments: add poster policy ----
CREATE POLICY guess_judgments_poster_view ON public.guess_judgments
  AS PERMISSIVE FOR SELECT
  USING (
    private.is_case_poster_for_investigation(investigation_id)
    AND EXISTS (SELECT 1 FROM public.profiles
                WHERE id = private.auth_uid() AND is_active = true)
  );

-- ---- score_events: add poster policy ----
CREATE POLICY score_events_poster_view ON public.score_events
  AS PERMISSIVE FOR SELECT
  USING (
    private.is_case_poster_for_investigation(investigation_id)
    AND EXISTS (SELECT 1 FROM public.profiles
                WHERE id = private.auth_uid() AND is_active = true)
  );

-- ---- guess_attempts: V4 policies ----
-- Drop old V1 policies if they exist (names may vary; use DROP IF EXISTS pattern)
DROP POLICY IF EXISTS guess_own_view                      ON public.guess_attempts;
DROP POLICY IF EXISTS guess_poster_view                   ON public.guess_attempts;
DROP POLICY IF EXISTS guess_investigation_revealed_view   ON public.guess_attempts;

-- 1. Own guess: always visible, no state restriction
CREATE POLICY guess_own_view ON public.guess_attempts
  AS PERMISSIVE FOR SELECT
  USING (
    player_id = private.auth_uid()
    AND EXISTS (SELECT 1 FROM public.profiles
                WHERE id = private.auth_uid() AND is_active = true)
  );

-- 2. Poster view: launched, locked, revealed
CREATE POLICY guess_poster_view ON public.guess_attempts
  AS PERMISSIVE FOR SELECT
  USING (
    private.is_case_poster(case_id)
    AND EXISTS (
      SELECT 1 FROM public.cases
      WHERE id = case_id AND state IN ('launched','locked','revealed')
    )
    AND EXISTS (SELECT 1 FROM public.profiles
                WHERE id = private.auth_uid() AND is_active = true)
  );

-- 3. Co-investigator: R6-B4 — anchor via investigations.case_id
--    (guess_attempts has no investigation_id column; use case_id instead)
CREATE POLICY guess_investigation_revealed_view ON public.guess_attempts
  AS PERMISSIVE FOR SELECT
  USING (
    private.is_case_revealed(case_id)
    AND EXISTS (
      SELECT 1 FROM public.investigation_members im_viewer
      JOIN public.investigations inv
        ON inv.investigation_id = im_viewer.investigation_id
       AND inv.case_id = guess_attempts.case_id
      JOIN public.investigation_members im_owner
        ON im_owner.investigation_id = im_viewer.investigation_id
       AND im_owner.player_id = guess_attempts.player_id
      WHERE im_viewer.player_id = private.auth_uid()
        AND im_viewer.eligibility_status = 'eligible'
    )
    AND EXISTS (SELECT 1 FROM public.profiles
                WHERE id = private.auth_uid() AND is_active = true)
  );

-- ---- comments: add poster INSERT / UPDATE / DELETE policies ----

CREATE POLICY comments_poster_view ON public.comments AS PERMISSIVE FOR SELECT
  USING (
    deleted_at IS NULL
    AND private.is_case_poster_for_investigation(investigation_id)
    AND EXISTS (SELECT 1 FROM public.profiles WHERE id = private.auth_uid() AND is_active = true)
  );

CREATE POLICY comments_poster_insert ON public.comments AS PERMISSIVE FOR INSERT
  WITH CHECK (
    author_id = private.auth_uid()
    AND deleted_at IS NULL
    AND private.is_case_poster_for_investigation(investigation_id)
    AND EXISTS (SELECT 1 FROM public.profiles WHERE id = private.auth_uid()
                AND is_active = true AND onboarding_complete = true)
  );

CREATE POLICY comments_poster_softdelete ON public.comments AS PERMISSIVE FOR UPDATE
  USING (
    author_id = private.auth_uid()
    AND private.is_case_poster_for_investigation(investigation_id)
  )
  WITH CHECK (author_id = private.auth_uid());

-- ---- cases: complete policy set ----
-- (hide_blocked_cases RESTRICTIVE policy added below)
CREATE POLICY cases_poster_view ON public.cases AS PERMISSIVE FOR SELECT
  USING (
    poster_id = private.auth_uid()
    AND EXISTS (SELECT 1 FROM public.profiles WHERE id = private.auth_uid() AND is_active = true)
  );

CREATE POLICY cases_member_view ON public.cases AS PERMISSIVE FOR SELECT
  USING (
    private.is_case_member(id)
    AND EXISTS (SELECT 1 FROM public.profiles WHERE id = private.auth_uid() AND is_active = true)
  );

-- ---- case_secrets: complete policy set ----
-- (Recreated below after hide_blocked_case_secrets)

-- ---- clues: complete policy set ----
CREATE POLICY clues_member_view ON public.clues AS PERMISSIVE FOR SELECT
  USING (
    private.is_case_member(case_id)
    AND EXISTS (SELECT 1 FROM public.profiles WHERE id = private.auth_uid() AND is_active = true)
  );

CREATE POLICY clues_poster_view ON public.clues AS PERMISSIVE FOR SELECT
  USING (
    private.is_case_poster(case_id)
    AND EXISTS (SELECT 1 FROM public.profiles WHERE id = private.auth_uid() AND is_active = true)
  );

-- ---- comments: base member policies ----
CREATE POLICY comments_member_view ON public.comments AS PERMISSIVE FOR SELECT
  USING (
    deleted_at IS NULL
    AND private.is_investigation_member(investigation_id)
    AND (
      private.is_case_revealed(case_id)
      OR private.caller_has_guessed(case_id)
      OR private.is_case_poster(case_id)
    )
    AND EXISTS (SELECT 1 FROM public.profiles WHERE id = private.auth_uid() AND is_active = true)
  );

CREATE POLICY comments_member_insert ON public.comments AS PERMISSIVE FOR INSERT
  WITH CHECK (
    author_id = private.auth_uid()
    AND deleted_at IS NULL
    AND private.is_investigation_member(investigation_id)
    AND (private.is_case_revealed(case_id) OR private.caller_has_guessed(case_id))
    AND EXISTS (SELECT 1 FROM public.profiles WHERE id = private.auth_uid()
                AND is_active = true AND onboarding_complete = true)
  );

CREATE POLICY comments_member_softdelete ON public.comments AS PERMISSIVE FOR UPDATE
  USING (
    author_id = private.auth_uid()
    AND private.is_investigation_member(investigation_id)
  )
  WITH CHECK (author_id = private.auth_uid());

-- ---- reactions: base member policies ----
CREATE POLICY reactions_member_view ON public.reactions AS PERMISSIVE FOR SELECT
  USING (
    private.is_investigation_member(investigation_id)
    AND (private.is_case_revealed(case_id) OR private.caller_has_guessed(case_id))
    AND EXISTS (SELECT 1 FROM public.profiles WHERE id = private.auth_uid() AND is_active = true)
  );

CREATE POLICY reactions_member_insert ON public.reactions AS PERMISSIVE FOR INSERT
  WITH CHECK (
    player_id = private.auth_uid()
    AND private.is_investigation_member(investigation_id)
    AND (private.is_case_revealed(case_id) OR private.caller_has_guessed(case_id))
    AND EXISTS (SELECT 1 FROM public.profiles WHERE id = private.auth_uid() AND is_active = true)
  );

CREATE POLICY reactions_member_delete ON public.reactions AS PERMISSIVE FOR DELETE
  USING (
    player_id = private.auth_uid()
    AND private.is_investigation_member(investigation_id)
  );

-- ---- score_runs: member view ----
CREATE POLICY score_runs_member_view ON public.score_runs AS PERMISSIVE FOR SELECT
  USING (
    private.is_case_revealed(case_id)
    AND private.is_investigation_member(investigation_id)
    AND EXISTS (SELECT 1 FROM public.profiles WHERE id = private.auth_uid() AND is_active = true)
  );

-- ---- guess_judgments: member view (revealed only) ----
CREATE POLICY guess_judgments_member_view ON public.guess_judgments AS PERMISSIVE FOR SELECT
  USING (
    private.is_case_revealed(case_id)
    AND private.is_investigation_member(investigation_id)
    AND EXISTS (SELECT 1 FROM public.profiles WHERE id = private.auth_uid() AND is_active = true)
  );

-- ---- score_events: member view (revealed only) ----
CREATE POLICY score_events_member_view ON public.score_events AS PERMISSIVE FOR SELECT
  USING (
    private.is_case_revealed(case_id)
    AND private.is_investigation_member(investigation_id)
    AND EXISTS (SELECT 1 FROM public.profiles WHERE id = private.auth_uid() AND is_active = true)
  );

-- ---- eligible_participants: member view ----
CREATE POLICY eligible_participants_member_view ON public.eligible_participants AS PERMISSIVE FOR SELECT
  USING (
    private.is_case_member(case_id)
    AND EXISTS (SELECT 1 FROM public.profiles WHERE id = private.auth_uid() AND is_active = true)
  );

-- ---- exclusion_events: member view ----
CREATE POLICY exclusion_events_member_view ON public.exclusion_events AS PERMISSIVE FOR SELECT
  USING (
    private.is_investigation_member(investigation_id)
    AND EXISTS (SELECT 1 FROM public.profiles WHERE id = private.auth_uid() AND is_active = true)
  );

CREATE POLICY exclusion_events_self_insert ON public.exclusion_events AS PERMISSIVE FOR INSERT
  WITH CHECK (
    reason = 'withdrew'
    AND player_id = private.auth_uid()
    AND private.is_investigation_member(investigation_id)
    AND EXISTS (SELECT 1 FROM public.profiles WHERE id = private.auth_uid() AND is_active = true)
  );

-- ---- case_answer_aliases: member view (revealed) + poster management ----
CREATE POLICY aliases_member_view ON public.case_answer_aliases AS PERMISSIVE FOR SELECT
  USING (
    is_active = true
    AND private.is_case_revealed(case_id)
    AND private.is_case_member(case_id)
    AND EXISTS (SELECT 1 FROM public.profiles WHERE id = private.auth_uid() AND is_active = true)
  );

CREATE POLICY aliases_poster_manage ON public.case_answer_aliases AS PERMISSIVE FOR ALL
  USING (private.is_case_poster(case_id)
         AND EXISTS (SELECT 1 FROM public.profiles WHERE id = private.auth_uid() AND is_active = true))
  WITH CHECK (private.is_case_poster(case_id));

-- ---- Blocker 3 Gap 3A: cases_insert ----
CREATE POLICY cases_insert ON public.cases AS PERMISSIVE FOR INSERT
  WITH CHECK (
    poster_id = private.auth_uid()
    AND EXISTS (SELECT 1 FROM public.profiles WHERE id = private.auth_uid()
                AND is_active = true AND onboarding_complete = true)
  );

-- ---- Blocker 3 Gap 3B: cases_update_poster ----
CREATE POLICY cases_update_poster ON public.cases AS PERMISSIVE FOR UPDATE
  USING (
    poster_id = private.auth_uid()
    AND state = 'draft'
    AND EXISTS (SELECT 1 FROM public.profiles WHERE id = private.auth_uid()
                AND is_active = true AND onboarding_complete = true)
  )
  WITH CHECK (
    poster_id = private.auth_uid()
    AND state = 'draft'
    AND EXISTS (SELECT 1 FROM public.profiles WHERE id = private.auth_uid()
                AND is_active = true AND onboarding_complete = true)
  );

-- ---- Blocker 3 Gap 3C: case_secrets_insert ----
CREATE POLICY case_secrets_insert ON public.case_secrets AS PERMISSIVE FOR INSERT
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.cases c
      WHERE c.id = case_id AND c.poster_id = private.auth_uid()
    )
    AND EXISTS (SELECT 1 FROM public.profiles WHERE id = private.auth_uid()
                AND is_active = true AND onboarding_complete = true)
  );

-- ---- Blocker 3 Gap 3D: case_secrets_update_poster ----
CREATE POLICY case_secrets_update_poster ON public.case_secrets AS PERMISSIVE FOR UPDATE
  USING (
    private.is_case_poster(case_id)
    AND EXISTS (SELECT 1 FROM public.profiles WHERE id = private.auth_uid() AND is_active = true)
  )
  WITH CHECK (private.is_case_poster(case_id));

-- ---- Blocker 3 Gap 3E: case_secrets_member_revealed_view ----
CREATE POLICY case_secrets_member_revealed_view ON public.case_secrets AS PERMISSIVE FOR SELECT
  USING (
    private.is_case_revealed(case_id)
    AND private.is_case_member(case_id)
    AND EXISTS (SELECT 1 FROM public.profiles WHERE id = private.auth_uid() AND is_active = true)
  );

-- ---- Blocker 3 Gap 3F: clues_insert_poster ----
CREATE POLICY clues_insert_poster ON public.clues AS PERMISSIVE FOR INSERT
  WITH CHECK (
    private.is_case_poster(case_id)
    AND EXISTS (
      SELECT 1 FROM public.cases
      WHERE id = case_id AND state = 'launched'
    )
    AND EXISTS (SELECT 1 FROM public.profiles WHERE id = private.auth_uid()
                AND is_active = true AND onboarding_complete = true)
  );

-- ---- Blocker 3 Gap 3G: correction_events permissive SELECT ----
CREATE POLICY correction_events_member_view ON public.correction_events AS PERMISSIVE FOR SELECT
  USING (
    private.is_case_revealed(case_id)
    AND private.is_case_member(case_id)
    AND EXISTS (SELECT 1 FROM public.profiles WHERE id = private.auth_uid() AND is_active = true)
  );

CREATE POLICY correction_events_poster_view ON public.correction_events AS PERMISSIVE FOR SELECT
  USING (
    private.is_case_poster(case_id)
    AND EXISTS (SELECT 1 FROM public.profiles WHERE id = private.auth_uid() AND is_active = true)
  );


-- ---- reactions: add poster policies ----

CREATE POLICY reactions_poster_view ON public.reactions AS PERMISSIVE FOR SELECT
  USING (
    private.is_case_poster_for_investigation(investigation_id)
    AND EXISTS (SELECT 1 FROM public.profiles WHERE id = private.auth_uid() AND is_active = true)
  );

CREATE POLICY reactions_poster_insert ON public.reactions AS PERMISSIVE FOR INSERT
  WITH CHECK (
    player_id = private.auth_uid()
    AND private.is_case_poster_for_investigation(investigation_id)
    AND EXISTS (SELECT 1 FROM public.profiles WHERE id = private.auth_uid() AND is_active = true)
  );

CREATE POLICY reactions_poster_delete ON public.reactions AS PERMISSIVE FOR DELETE
  USING (
    player_id = private.auth_uid()
    AND private.is_case_poster_for_investigation(investigation_id)
  );

-- ---- cases: block policy for blocked poster ----
DROP POLICY IF EXISTS hide_blocked_challenges ON public.cases;
-- B9: Restore enrolled-investigator carve-out (mirrors V3 eligible_participants).
CREATE POLICY hide_blocked_cases ON public.cases
  AS RESTRICTIVE FOR SELECT
  USING (
    poster_id = private.auth_uid()
    OR NOT private.has_block_with_poster(id)
    OR EXISTS (
      SELECT 1 FROM public.investigation_members im
      JOIN public.investigations inv ON inv.investigation_id = im.investigation_id
      WHERE inv.case_id = public.cases.id AND im.player_id = private.auth_uid()
    )
  );

-- ---- case_secrets: poster view via is_case_poster (was challenge_secrets) ----
-- Existing RLS policies on challenge_secrets are now on case_secrets (table rename).
-- The policy functions now use is_case_poster internally.
-- Drop old policies if referencing challenge-named helpers.
DROP POLICY IF EXISTS challenge_secrets_poster_view ON public.case_secrets;
CREATE POLICY case_secrets_poster_view ON public.case_secrets
  AS PERMISSIVE FOR SELECT
  USING (private.is_case_poster(case_id)
         AND EXISTS (SELECT 1 FROM public.profiles WHERE id = private.auth_uid() AND is_active = true));

-- Block policy: hide case_secrets from anyone in a block pair with poster
DROP POLICY IF EXISTS hide_blocked_challenge_secrets ON public.case_secrets;
CREATE POLICY hide_blocked_case_secrets ON public.case_secrets
  AS RESTRICTIVE FOR SELECT
  USING (NOT private.has_block_with_poster(case_id));


-- =============================================================================
-- PHASE 15B — V3 RESTRICTIVE RLS POLICIES (updated for V4 table/column names)
-- Ported from Step 24.1 Rev 15 Part 9, with challenge_id → case_id throughout.
-- =============================================================================

-- ---- 9.1 Suspension enforcement — RESTRICTIVE INSERT (existing tables) ----

CREATE POLICY suspend_block_insert ON public.comments AS RESTRICTIVE
  FOR INSERT TO authenticated
  WITH CHECK (NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = private.auth_uid() AND is_suspended = true));

CREATE POLICY suspend_block_insert ON public.clues AS RESTRICTIVE
  FOR INSERT TO authenticated
  WITH CHECK (NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = private.auth_uid() AND is_suspended = true));

CREATE POLICY suspend_block_insert ON public.reactions AS RESTRICTIVE
  FOR INSERT TO authenticated
  WITH CHECK (NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = private.auth_uid() AND is_suspended = true));

CREATE POLICY suspend_block_insert ON public.guess_attempts AS RESTRICTIVE
  FOR INSERT TO authenticated
  WITH CHECK (NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = private.auth_uid() AND is_suspended = true));

CREATE POLICY suspend_block_insert ON public.cases AS RESTRICTIVE
  FOR INSERT TO authenticated
  WITH CHECK (NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = private.auth_uid() AND is_suspended = true));

CREATE POLICY suspend_block_insert ON public.case_secrets AS RESTRICTIVE
  FOR INSERT TO authenticated
  WITH CHECK (NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = private.auth_uid() AND is_suspended = true));

CREATE POLICY suspend_block_insert ON public.case_answer_aliases AS RESTRICTIVE
  FOR INSERT TO authenticated
  WITH CHECK (NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = private.auth_uid() AND is_suspended = true));

-- Blocker 2: DROP IF EXISTS guard (V3 already created this policy)
DROP POLICY IF EXISTS suspend_block_insert ON public.group_members;
CREATE POLICY suspend_block_insert ON public.group_members AS RESTRICTIVE
  FOR INSERT TO authenticated
  WITH CHECK (NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = private.auth_uid() AND is_suspended = true));

-- Blocker 2: DROP IF EXISTS guard (V3 already created this policy)
DROP POLICY IF EXISTS suspend_block_insert ON public.groups;
CREATE POLICY suspend_block_insert ON public.groups AS RESTRICTIVE
  FOR INSERT TO authenticated
  WITH CHECK (NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = private.auth_uid() AND is_suspended = true));

-- Tables with UPDATE restriction
CREATE POLICY suspend_block_update ON public.cases AS RESTRICTIVE
  FOR UPDATE TO authenticated
  USING (NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = private.auth_uid() AND is_suspended = true));

CREATE POLICY suspend_block_update ON public.case_secrets AS RESTRICTIVE
  FOR UPDATE TO authenticated
  USING (NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = private.auth_uid() AND is_suspended = true));

CREATE POLICY suspend_block_update ON public.case_answer_aliases AS RESTRICTIVE
  FOR UPDATE TO authenticated
  USING (NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = private.auth_uid() AND is_suspended = true));

-- Blocker 2: DROP IF EXISTS guard (V3 already created this policy)
DROP POLICY IF EXISTS suspend_block_update ON public.groups;
CREATE POLICY suspend_block_update ON public.groups AS RESTRICTIVE
  FOR UPDATE TO authenticated
  USING (NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = private.auth_uid() AND is_suspended = true));

-- Blocker 2: DROP IF EXISTS guard (V3 already created this policy)
DROP POLICY IF EXISTS suspend_block_update ON public.profiles;
CREATE POLICY suspend_block_update ON public.profiles AS RESTRICTIVE
  FOR UPDATE TO authenticated
  USING (NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = private.auth_uid() AND is_suspended = true));

-- ---- 9.2 exclusion_events branched suspension ----
CREATE POLICY suspend_exclusion_insert ON public.exclusion_events AS RESTRICTIVE
  FOR INSERT TO authenticated
  WITH CHECK (
    NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = private.auth_uid() AND is_suspended = true)
    OR (reason = 'withdrew' AND player_id = private.auth_uid())
  );

-- ---- 9.3 Block enforcement — INSERT (RESTRICTIVE) ----
CREATE POLICY enforce_no_block_guess ON public.guess_attempts AS RESTRICTIVE
  FOR INSERT TO authenticated WITH CHECK (NOT private.has_block_with_poster(case_id));
CREATE POLICY enforce_no_block_comment ON public.comments AS RESTRICTIVE
  FOR INSERT TO authenticated WITH CHECK (NOT private.has_block_with_poster(case_id));
CREATE POLICY enforce_no_block_reaction ON public.reactions AS RESTRICTIVE
  FOR INSERT TO authenticated WITH CHECK (NOT private.has_block_with_poster(case_id));

-- ---- 9.4 Block enforcement — SELECT (RESTRICTIVE) ----
-- hide_blocked_cases already created above (in Phase 15).
-- block_aware_comment_visibility: RESTRICTIVE SELECT
DROP POLICY IF EXISTS block_aware_comment_visibility ON public.comments;
CREATE POLICY block_aware_comment_visibility ON public.comments AS RESTRICTIVE
  FOR SELECT TO authenticated
  USING (
    private.can_view_case(case_id)
    AND NOT private.has_block_with(author_id)
  );

DROP POLICY IF EXISTS block_aware_reaction_visibility ON public.reactions;
CREATE POLICY block_aware_reaction_visibility ON public.reactions AS RESTRICTIVE
  FOR SELECT TO authenticated
  USING (
    private.can_view_case(case_id)
    AND NOT private.has_block_with(player_id)
  );

-- ---- 9.5 Moderator-removed clues — hidden (RESTRICTIVE) ----
CREATE POLICY hide_removed_clues ON public.clues AS RESTRICTIVE
  FOR SELECT TO authenticated
  USING (moderator_removed_at IS NULL);

-- ---- 9.6 Block-aware visibility on case-linked child tables (RESTRICTIVE) ----
CREATE POLICY block_aware_visibility ON public.clues AS RESTRICTIVE
  FOR SELECT TO authenticated
  USING (private.can_view_case(case_id));

CREATE POLICY block_aware_visibility ON public.case_secrets AS RESTRICTIVE
  FOR SELECT TO authenticated
  USING (private.can_view_case(case_id));

CREATE POLICY block_aware_visibility ON public.case_answer_aliases AS RESTRICTIVE
  FOR SELECT TO authenticated
  USING (private.can_view_case(case_id));

CREATE POLICY block_aware_visibility ON public.guess_attempts AS RESTRICTIVE
  FOR SELECT TO authenticated
  USING (private.can_view_case(case_id));

CREATE POLICY block_aware_visibility ON public.guess_judgments AS RESTRICTIVE
  FOR SELECT TO authenticated
  USING (private.can_view_case(case_id));

CREATE POLICY block_aware_visibility ON public.score_runs AS RESTRICTIVE
  FOR SELECT TO authenticated
  USING (private.can_view_case(case_id));

CREATE POLICY block_aware_visibility ON public.score_events AS RESTRICTIVE
  FOR SELECT TO authenticated
  USING (private.can_view_case(case_id));

CREATE POLICY block_aware_visibility ON public.correction_events AS RESTRICTIVE
  FOR SELECT TO authenticated
  USING (private.can_view_case(case_id));

CREATE POLICY block_aware_visibility ON public.eligible_participants AS RESTRICTIVE
  FOR SELECT TO authenticated
  USING (private.can_view_case(case_id));

CREATE POLICY block_aware_visibility ON public.exclusion_events AS RESTRICTIVE
  FOR SELECT TO authenticated
  USING (private.can_view_case(case_id));


-- =============================================================================
-- PHASE 16 — STATE CONVERSION: 'active' → 'launched'; FINAL CONSTRAINT
-- Two-step: drop old → add temp (both values) → update → drop temp → add final.
-- =============================================================================

-- Step 1: drop old state constraint (already renamed to cases_state_check_temp in Phase 1)
ALTER TABLE public.cases DROP CONSTRAINT cases_state_check_temp;

-- Step 2: temp constraint allows both old ('active') and all new values
ALTER TABLE public.cases ADD CONSTRAINT cases_state_check_temp
  CHECK (state IN ('draft','ready','active','launched','locked','revealed','retired','cancelled'));

-- Step 3: convert 'active' → 'launched'
-- R6-B5: The V1 trigger challenge_protect_fields rejects state changes unless
--        current_user='forkensics_executor'. Disable it for this controlled
--        migration rename; it will be replaced entirely in Phase 19.2.
ALTER TABLE public.cases DISABLE TRIGGER challenge_protect_fields;
UPDATE public.cases SET state = 'launched' WHERE state = 'active';
ALTER TABLE public.cases ENABLE TRIGGER challenge_protect_fields;

-- Step 4: drop temp; add final (no 'active')
ALTER TABLE public.cases DROP CONSTRAINT cases_state_check_temp;
ALTER TABLE public.cases ADD CONSTRAINT cases_state_check
  CHECK (state IN ('draft','ready','launched','locked','revealed','retired','cancelled'));

-- Also update investigations: convert matching investigation status for 'launched' cases
-- (Investigation status remains 'active' for launched cases — the investigation is active.)

-- Sync the trigger `enforce_exclusion_rules` reference: 'active' → 'launched' in guard.
-- (Done in Phase 19 when trigger functions are recreated.)


-- =============================================================================
-- PHASE 17 — DROP OLD INDEXES; CREATE NEW INDEXES
-- =============================================================================

-- Recreate renamed indexes
CREATE INDEX IF NOT EXISTS idx_cases_state         ON public.cases         (state);
CREATE INDEX IF NOT EXISTS idx_cases_group_id      ON public.cases         (group_id);
CREATE INDEX IF NOT EXISTS idx_guess_attempts_case ON public.guess_attempts (case_id, race, receipt_sequence);
CREATE INDEX IF NOT EXISTS idx_guess_attempts_player ON public.guess_attempts (player_id, case_id);
CREATE INDEX IF NOT EXISTS idx_score_events_case   ON public.score_events  (case_id);
CREATE INDEX IF NOT EXISTS idx_score_events_player ON public.score_events  (player_id);
CREATE INDEX IF NOT EXISTS idx_eligible_case       ON public.eligible_participants (case_id);
CREATE INDEX IF NOT EXISTS idx_exclusion_case      ON public.exclusion_events     (case_id);
CREATE INDEX IF NOT EXISTS idx_clues_case          ON public.clues          (case_id);
CREATE INDEX IF NOT EXISTS idx_comments_case       ON public.comments       (case_id, posted_at);
CREATE INDEX IF NOT EXISTS idx_reactions_case      ON public.reactions      (case_id);
CREATE INDEX IF NOT EXISTS idx_aliases_case
  ON public.case_answer_aliases (case_id, field) WHERE is_active = true;
CREATE UNIQUE INDEX IF NOT EXISTS idx_aliases_active_unique
  ON public.case_answer_aliases (case_id, field, normalized_value)
  WHERE is_active = true;
CREATE INDEX IF NOT EXISTS idx_correction_case     ON public.correction_events (case_id);

-- New indexes for investigation tables
CREATE INDEX IF NOT EXISTS idx_investigations_case    ON public.investigations       (case_id);
CREATE INDEX IF NOT EXISTS idx_investigations_group   ON public.investigations       (group_id);
CREATE INDEX IF NOT EXISTS idx_inv_members_player     ON public.investigation_members (player_id);
CREATE INDEX IF NOT EXISTS idx_score_runs_investigation ON public.score_runs         (investigation_id);
CREATE INDEX IF NOT EXISTS idx_score_events_investigation ON public.score_events     (investigation_id);
CREATE INDEX IF NOT EXISTS idx_comments_investigation ON public.comments             (investigation_id, posted_at);
CREATE INDEX IF NOT EXISTS idx_reactions_investigation ON public.reactions           (investigation_id);
CREATE INDEX IF NOT EXISTS idx_exclusion_investigation ON public.exclusion_events    (investigation_id);

-- New partial unique index for cases: active case per poster
-- Predicate uses new state values: 'draft','ready','launched','locked'
CREATE UNIQUE INDEX one_active_case_per_poster
  ON public.cases (poster_id)
  WHERE state IN ('draft','ready','launched','locked');

-- one_qualifying_per_player_race: already exists on score_run/player/race but references
-- score_runs which now has investigation_id. The existing index is still valid.


-- =============================================================================
-- PHASE 18 — DROP group_id FROM cases (cases becomes group-agnostic)
-- By this point investigations are fully populated with group_id.
-- Drop idx_cases_group_id first.
-- =============================================================================

DROP INDEX IF EXISTS idx_cases_group_id;
ALTER TABLE public.cases DROP COLUMN group_id;


-- =============================================================================
-- PHASE 19 — RECREATE TRIGGER FUNCTIONS AND SERVICE FUNCTIONS
-- All functions reference new column/table names.
-- =============================================================================

-- ------------------------------------------------------------
-- 19.1  set_case_create_fields (replaces set_challenge_create_fields)
-- ------------------------------------------------------------
DROP TRIGGER IF EXISTS challenge_create_fields ON public.cases;

CREATE OR REPLACE FUNCTION public.set_case_create_fields()
RETURNS trigger LANGUAGE plpgsql SET search_path = ''
AS $$
BEGIN
  NEW.poster_id           := private.auth_uid();
  NEW.state               := 'draft';
  NEW.created_at          := clock_timestamp();
  NEW.rules_version_id    := 'a0000000-0000-0000-0000-000000000001';
  NEW.posted_at           := NULL;
  NEW.deadline_at         := NULL;
  NEW.locked_at           := NULL;
  NEW.revealed_at         := NULL;
  NEW.cancelled_at        := NULL;
  NEW.cancellation_reason := NULL;
  IF NEW.public_city_display IS NOT NULL THEN
    NEW.public_city_display := NULLIF(trim(NEW.public_city_display), '');
  END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER case_create_fields
  BEFORE INSERT ON public.cases
  FOR EACH ROW EXECUTE PROCEDURE public.set_case_create_fields();

-- ------------------------------------------------------------
-- 19.2  protect_case_authority_fields (replaces protect_challenge_authority_fields)
-- CRITICAL: group_id check is REMOVED (Phase 18 dropped the column).
-- ------------------------------------------------------------
DROP TRIGGER IF EXISTS challenge_protect_fields ON public.cases;

CREATE OR REPLACE FUNCTION public.protect_case_authority_fields()
RETURNS trigger LANGUAGE plpgsql SET search_path = ''
AS $$
BEGIN
  IF current_user = 'forkensics_executor' THEN RETURN NEW; END IF;

  IF NEW.state               IS DISTINCT FROM OLD.state               THEN RAISE EXCEPTION 'state cannot be set directly';                          END IF;
  IF NEW.poster_id           IS DISTINCT FROM OLD.poster_id           THEN RAISE EXCEPTION 'poster_id is immutable';                               END IF;
  IF NEW.posted_at           IS DISTINCT FROM OLD.posted_at           THEN RAISE EXCEPTION 'posted_at cannot be set directly';                      END IF;
  IF NEW.deadline_at         IS DISTINCT FROM OLD.deadline_at         THEN RAISE EXCEPTION 'deadline_at cannot be set directly';                    END IF;
  IF NEW.locked_at           IS DISTINCT FROM OLD.locked_at           THEN RAISE EXCEPTION 'locked_at cannot be set directly';                      END IF;
  IF NEW.revealed_at         IS DISTINCT FROM OLD.revealed_at         THEN RAISE EXCEPTION 'revealed_at cannot be set directly';                    END IF;
  IF NEW.cancelled_at        IS DISTINCT FROM OLD.cancelled_at        THEN RAISE EXCEPTION 'cancelled_at cannot be set directly';                   END IF;
  IF NEW.cancellation_reason IS DISTINCT FROM OLD.cancellation_reason THEN RAISE EXCEPTION 'cancellation_reason cannot be set directly';            END IF;
  IF NEW.rules_version_id    IS DISTINCT FROM OLD.rules_version_id    THEN RAISE EXCEPTION 'rules_version_id is immutable';                        END IF;

  -- public_city_display: editable in draft; immutable after activation
  IF OLD.posted_at IS NULL THEN
    IF NEW.public_city_display IS NOT NULL THEN
      NEW.public_city_display := NULLIF(trim(NEW.public_city_display), '');
    END IF;
  ELSIF NEW.public_city_display IS DISTINCT FROM OLD.public_city_display THEN
    RAISE EXCEPTION 'public_city_display is immutable after activation';
  END IF;

  RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER case_protect_fields
  BEFORE UPDATE ON public.cases
  FOR EACH ROW EXECUTE PROCEDURE public.protect_case_authority_fields();

-- ------------------------------------------------------------
-- 19.3  guard_answer_edits (update to reference case_secrets / case_id)
-- ------------------------------------------------------------
DROP TRIGGER IF EXISTS challenge_secrets_guard ON public.case_secrets;

CREATE OR REPLACE FUNCTION public.guard_answer_edits()
RETURNS trigger LANGUAGE plpgsql SET search_path = ''
AS $$
DECLARE
  v_has_first_guess boolean;
BEGIN
  SELECT has_first_guess INTO v_has_first_guess
  FROM public.case_secrets
  WHERE case_id = NEW.case_id
  FOR UPDATE;

  IF current_user = 'forkensics_executor' THEN
    NEW.updated_at := clock_timestamp();
    RETURN NEW;
  END IF;

  IF v_has_first_guess = true THEN
    RAISE EXCEPTION 'case_secrets cannot be edited after first guess is received';
  END IF;
  NEW.updated_at := clock_timestamp();
  RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER case_secrets_guard
  BEFORE UPDATE ON public.case_secrets
  FOR EACH ROW EXECUTE PROCEDURE public.guard_answer_edits();

-- ------------------------------------------------------------
-- 19.4  set_challenge_secret_timestamps → case_secrets_timestamps
-- ------------------------------------------------------------
DROP TRIGGER IF EXISTS challenge_secrets_timestamps ON public.case_secrets;

CREATE OR REPLACE TRIGGER case_secrets_timestamps
  BEFORE INSERT ON public.case_secrets
  FOR EACH ROW EXECUTE PROCEDURE public.set_challenge_secret_timestamps();

-- ------------------------------------------------------------
-- 19.5  guard_alias_edits (update to reference case_secrets / case_id)
-- ------------------------------------------------------------
DROP TRIGGER IF EXISTS alias_guard_insert ON public.case_answer_aliases;
DROP TRIGGER IF EXISTS alias_guard_update ON public.case_answer_aliases;

CREATE OR REPLACE FUNCTION public.guard_alias_edits()
RETURNS trigger LANGUAGE plpgsql SET search_path = ''
AS $$
DECLARE
  v_has_first_guess boolean;
BEGIN
  SELECT has_first_guess INTO v_has_first_guess
  FROM public.case_secrets
  WHERE case_id = NEW.case_id
  FOR UPDATE;

  IF current_user = 'forkensics_executor' THEN
    RETURN NEW;
  END IF;

  IF v_has_first_guess = true THEN
    RAISE EXCEPTION 'aliases cannot be changed after first guess is received';
  END IF;
  IF TG_OP = 'INSERT' THEN
    NEW.created_at       := clock_timestamp();
    NEW.created_by       := private.auth_uid();
    NEW.normalized_value := private.normalize_answer(NEW.display_value);
    NEW.is_active        := true;
  END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER alias_guard_insert
  BEFORE INSERT ON public.case_answer_aliases
  FOR EACH ROW EXECUTE PROCEDURE public.guard_alias_edits();

CREATE OR REPLACE TRIGGER alias_guard_update
  BEFORE UPDATE ON public.case_answer_aliases
  FOR EACH ROW EXECUTE PROCEDURE public.guard_alias_edits();

-- ------------------------------------------------------------
-- 19.6  restrict_comment_updates (V4: case_id, investigation_id, moderator_removed_at)
-- Full replacement of V3 version for V4 column names.
-- ------------------------------------------------------------
DROP TRIGGER IF EXISTS comment_update_guard ON public.comments;

CREATE OR REPLACE FUNCTION public.restrict_comment_updates()
RETURNS trigger LANGUAGE plpgsql SECURITY INVOKER SET search_path = ''
AS $$
BEGIN
  -- Path 0 (B4 — migration backfill): postgres may set investigation_id from NULL.
  IF current_user = 'postgres'
     AND OLD.investigation_id IS NULL
     AND NEW.investigation_id IS NOT NULL
     AND NEW.id IS NOT DISTINCT FROM OLD.id
     AND NEW.text IS NOT DISTINCT FROM OLD.text
     AND NEW.author_id IS NOT DISTINCT FROM OLD.author_id
     AND NEW.case_id IS NOT DISTINCT FROM OLD.case_id
     AND NEW.posted_at IS NOT DISTINCT FROM OLD.posted_at
     AND NEW.deleted_at IS NOT DISTINCT FROM OLD.deleted_at
     AND NEW.moderator_removed_at IS NOT DISTINCT FROM OLD.moderator_removed_at
     AND NEW.moderator_removal_action_id IS NOT DISTINCT FROM OLD.moderator_removal_action_id
  THEN RETURN NEW;
  END IF;
  -- Path 1: Moderator removal — only forkensics_executor.
  IF current_user = 'forkensics_executor'
     AND OLD.moderator_removed_at IS NULL
     AND OLD.moderator_removal_action_id IS NULL
     AND NEW.moderator_removed_at IS NOT NULL
     AND NEW.moderator_removal_action_id IS NOT NULL
     AND NEW.text = '[removed by moderator]'
     AND NEW.id IS NOT DISTINCT FROM OLD.id
     AND NEW.author_id IS NOT DISTINCT FROM OLD.author_id
     AND NEW.case_id IS NOT DISTINCT FROM OLD.case_id
     AND NEW.investigation_id IS NOT DISTINCT FROM OLD.investigation_id
     AND NEW.posted_at IS NOT DISTINCT FROM OLD.posted_at
     AND NEW.deleted_at IS NOT DISTINCT FROM OLD.deleted_at
  THEN
    NEW.moderator_removed_at := clock_timestamp();
    RETURN NEW;
  END IF;

  -- Path 2: Author soft-delete.
  IF NEW.author_id = private.auth_uid()
     AND OLD.deleted_at IS NULL
     AND NEW.deleted_at IS NOT NULL
     AND NEW.id IS NOT DISTINCT FROM OLD.id
     AND NEW.text IS NOT DISTINCT FROM OLD.text
     AND NEW.case_id IS NOT DISTINCT FROM OLD.case_id
     AND NEW.investigation_id IS NOT DISTINCT FROM OLD.investigation_id
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

CREATE OR REPLACE TRIGGER comment_update_guard
  BEFORE UPDATE ON public.comments
  FOR EACH ROW EXECUTE PROCEDURE public.restrict_comment_updates();

-- ------------------------------------------------------------
-- 19.7  set_guess_receipt_fields (V4: case_id, 'launched' state check)
-- Trigger fires only from forkensics_executor (INSERT revoked from authenticated).
-- Business logic validation is in submit_guess(); trigger stamps timestamps only.
-- ------------------------------------------------------------
DROP TRIGGER IF EXISTS guess_receipt ON public.guess_attempts;

CREATE OR REPLACE FUNCTION public.set_guess_receipt_fields()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
  NEW.received_at         := clock_timestamp();
  NEW.client_submitted_at := NEW.client_submitted_at;
  NEW.receipt_sequence    := nextval('public.guess_receipt_seq');
  RETURN NEW;
END;
$$;
ALTER FUNCTION public.set_guess_receipt_fields() OWNER TO forkensics_executor;

CREATE OR REPLACE TRIGGER guess_receipt
  BEFORE INSERT ON public.guess_attempts
  FOR EACH ROW EXECUTE PROCEDURE public.set_guess_receipt_fields();

-- ------------------------------------------------------------
-- 19.8  enforce_exclusion_rules (V4: case_id, investigation_id, 'launched' state)
-- ------------------------------------------------------------
DROP TRIGGER IF EXISTS exclusion_enforce ON public.exclusion_events;

CREATE OR REPLACE FUNCTION public.enforce_exclusion_rules()
RETURNS trigger LANGUAGE plpgsql SET search_path = ''
AS $$
DECLARE
  v_case_state   text;
  v_inv_status   text;
BEGIN
  -- Load case state and investigation status
  SELECT c.state, i.status
  INTO v_case_state, v_inv_status
  FROM public.cases c
  JOIN public.investigations i ON i.investigation_id = NEW.investigation_id
  WHERE c.id = i.case_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'investigation not found: %', NEW.investigation_id;
  END IF;

  -- All reasons: target must be a member of this investigation
  IF NOT EXISTS (
    SELECT 1 FROM public.investigation_members
    WHERE investigation_id = NEW.investigation_id AND player_id = NEW.player_id
  ) THEN
    RAISE EXCEPTION 'player % is not a member of investigation %',
      NEW.player_id, NEW.investigation_id;
  END IF;

  IF NEW.reason = 'withdrew' THEN
    IF v_inv_status != 'active' OR v_case_state != 'launched' THEN
      RAISE EXCEPTION 'withdrawal only allowed while investigation is active and case is launched (case state: %, investigation status: %)',
        v_case_state, v_inv_status;
    END IF;
    IF NEW.excluded_by IS DISTINCT FROM NEW.player_id THEN
      RAISE EXCEPTION 'withdrew: excluded_by must equal player_id (self-exclude only)';
    END IF;

  ELSIF NEW.reason = 'removed' THEN
    IF v_inv_status != 'active' OR v_case_state != 'launched' THEN
      RAISE EXCEPTION 'removal only allowed while investigation is active and case is launched (case state: %, investigation status: %)',
        v_case_state, v_inv_status;
    END IF;
    IF NEW.excluded_by IS NULL THEN
      RAISE EXCEPTION 'removed: excluded_by must be non-NULL';
    END IF;

  ELSIF NEW.reason = 'account_deleted' THEN
    IF current_user != 'forkensics_executor' THEN
      RAISE EXCEPTION 'account_deleted exclusion must be inserted by trusted function';
    END IF;
    IF v_inv_status != 'active' OR v_case_state NOT IN ('launched','locked') THEN
      RAISE EXCEPTION 'account_deleted exclusion only allowed for active investigations with launched/locked case (case state: %, investigation status: %)',
        v_case_state, v_inv_status;
    END IF;
    IF NEW.excluded_by IS NOT NULL THEN
      RAISE EXCEPTION 'account_deleted: excluded_by must be NULL';
    END IF;

  ELSE
    RAISE EXCEPTION 'unknown exclusion reason: %', NEW.reason;
  END IF;

  -- Verify investigation_id belongs to NEW.case_id
  IF NOT EXISTS (
    SELECT 1 FROM public.investigations
    WHERE investigation_id = NEW.investigation_id AND case_id = NEW.case_id
  ) THEN
    RAISE EXCEPTION 'investigation % does not belong to case %',
      NEW.investigation_id, NEW.case_id;
  END IF;

  -- Sync eligibility_status in investigation_members
  -- 'withdrew' and 'removed' → 'excluded'; 'account_deleted' → 'account_deleted'
  UPDATE public.investigation_members
  SET eligibility_status = CASE
    WHEN NEW.reason = 'account_deleted' THEN 'account_deleted'
    ELSE 'excluded'
  END
  WHERE investigation_id = NEW.investigation_id AND player_id = NEW.player_id;

  RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER exclusion_enforce
  BEFORE INSERT ON public.exclusion_events
  FOR EACH ROW EXECUTE PROCEDURE public.enforce_exclusion_rules();

-- ------------------------------------------------------------
-- 19.8B  check_investigation_case_consistency — BLOCKER 7
-- Verifies that investigation_id belongs to case_id on INSERT for
-- comments, reactions, and exclusion_events (where the trigger isn't
-- already enforcing this).
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.check_investigation_case_consistency()
RETURNS trigger LANGUAGE plpgsql SET search_path = ''
AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.investigations
    WHERE investigation_id = NEW.investigation_id AND case_id = NEW.case_id
  ) THEN
    RAISE EXCEPTION 'investigation % does not belong to case % (table: %)',
      NEW.investigation_id, NEW.case_id, TG_TABLE_NAME;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS comment_investigation_case_check ON public.comments;
CREATE TRIGGER comment_investigation_case_check
  BEFORE INSERT ON public.comments
  FOR EACH ROW EXECUTE FUNCTION public.check_investigation_case_consistency();

DROP TRIGGER IF EXISTS reaction_investigation_case_check ON public.reactions;
CREATE TRIGGER reaction_investigation_case_check
  BEFORE INSERT ON public.reactions
  FOR EACH ROW EXECUTE FUNCTION public.check_investigation_case_consistency();

-- ------------------------------------------------------------
-- 19.9  check_judgment_consistency (V4: case_id)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.check_judgment_consistency()
RETURNS trigger LANGUAGE plpgsql SET search_path = ''
AS $$
DECLARE
  v_attempt   record;
  v_score_run record;
BEGIN
  SELECT case_id, player_id, race INTO v_attempt
  FROM public.guess_attempts WHERE id = NEW.guess_attempt_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'guess attempt not found: %', NEW.guess_attempt_id;
  END IF;

  SELECT case_id, investigation_id, rules_version_id INTO v_score_run  -- B7
  FROM public.score_runs WHERE id = NEW.score_run_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'score run not found: %', NEW.score_run_id;
  END IF;

  IF NEW.case_id != v_attempt.case_id THEN
    RAISE EXCEPTION 'judgment case_id (%) does not match attempt case_id (%)',
      NEW.case_id, v_attempt.case_id;
  END IF;
  IF NEW.player_id != v_attempt.player_id THEN
    RAISE EXCEPTION 'judgment player_id (%) does not match attempt player_id (%)',
      NEW.player_id, v_attempt.player_id;
  END IF;
  IF NEW.race != v_attempt.race THEN
    RAISE EXCEPTION 'judgment race (%) does not match attempt race (%)',
      NEW.race, v_attempt.race;
  END IF;
  IF NEW.case_id != v_score_run.case_id THEN
    RAISE EXCEPTION 'judgment case_id (%) does not match score run case_id (%)',
      NEW.case_id, v_score_run.case_id;
  END IF;
  IF NEW.rules_version_id != v_score_run.rules_version_id THEN
    RAISE EXCEPTION 'judgment rules_version_id (%) does not match score run rules_version_id (%)',
      NEW.rules_version_id, v_score_run.rules_version_id;
  END IF;
  -- Blocker 7: investigation_id must match score run's investigation
  IF NEW.investigation_id IS DISTINCT FROM v_score_run.investigation_id THEN
    RAISE EXCEPTION 'judgment investigation_id (%) does not match score run investigation_id (%)',
      NEW.investigation_id, v_score_run.investigation_id;
  END IF;

  RETURN NEW;
END;
$$;
-- Trigger already named guess_judgment_consistency; no re-attach needed
-- (function is CREATE OR REPLACE; trigger body not re-created)

-- ------------------------------------------------------------
-- 19.10  check_score_event_consistency (V4: case_id, investigation_members)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.check_score_event_consistency()
RETURNS trigger LANGUAGE plpgsql SET search_path = ''
AS $$
DECLARE
  v_score_run record;
BEGIN
  SELECT case_id, investigation_id, rules_version_id INTO v_score_run
  FROM public.score_runs WHERE id = NEW.score_run_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'score run not found: %', NEW.score_run_id;
  END IF;

  IF NEW.case_id != v_score_run.case_id THEN
    RAISE EXCEPTION 'score event case_id (%) does not match score run case_id (%)',
      NEW.case_id, v_score_run.case_id;
  END IF;
  IF NEW.rules_version_id != v_score_run.rules_version_id THEN
    RAISE EXCEPTION 'score event rules_version_id (%) does not match score run rules_version_id (%)',
      NEW.rules_version_id, v_score_run.rules_version_id;
  END IF;

  -- Blocker 7: investigation_id must match score run's investigation
  IF NEW.investigation_id IS DISTINCT FROM v_score_run.investigation_id THEN
    RAISE EXCEPTION 'score event investigation_id (%) does not match score run investigation_id (%)',
      NEW.investigation_id, v_score_run.investigation_id;
  END IF;

  -- Player must be an eligible investigation member (not excluded)
  IF NOT EXISTS (
    SELECT 1 FROM public.investigation_members
    WHERE investigation_id  = v_score_run.investigation_id
      AND player_id         = NEW.player_id
      AND eligibility_status = 'eligible'
  ) THEN
    RAISE EXCEPTION 'score event player % is not an eligible member of investigation %',
      NEW.player_id, v_score_run.investigation_id;
  END IF;

  RETURN NEW;
END;
$$;

-- ------------------------------------------------------------
-- 19.0  CLEANUP: Drop old trigger functions replaced in V4
-- ------------------------------------------------------------
DROP FUNCTION IF EXISTS public.set_challenge_create_fields();
DROP FUNCTION IF EXISTS public.protect_challenge_authority_fields();

-- ------------------------------------------------------------
-- 19.0B  UPDATE V3 FUNCTION: public.get_media_serve_authorization
-- Exact V4 body per Rev 15 §14. SECURITY DEFINER; owner = forkensics_executor.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_media_serve_authorization(
  p_media_object_id uuid,
  p_viewer_id       uuid
) RETURNS TABLE(re_encoded_storage_key text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT msk.re_encoded_storage_key
  FROM public.media_objects mo
  JOIN public.cases c ON c.media_object_id = mo.id
  JOIN private.media_storage_keys msk ON msk.media_object_id = mo.id
  WHERE mo.id = p_media_object_id
    AND mo.status = 'ready'
    AND c.moderator_removed_at IS NULL
    AND private.can_viewer_access_case(c.id, p_viewer_id);
$$;
ALTER FUNCTION public.get_media_serve_authorization(uuid, uuid) OWNER TO forkensics_executor;

-- ------------------------------------------------------------
-- 19.0C  UPDATE V3 FUNCTION: public.report_content
-- 4-arg signature per Step 24.1 Rev 15 §10.3 contract.
-- Blocker 4: full rewrite fixing Bugs 4A-4F.
-- SECURITY DEFINER; owner = forkensics_executor.
-- ------------------------------------------------------------

-- Drop 5-arg overload introduced by V4 Rev 1 (wrong signature)
DROP FUNCTION IF EXISTS public.report_content(text, uuid, uuid, text, text);

CREATE OR REPLACE FUNCTION public.report_content(
  p_target_type text,
  p_target_id   uuid,
  p_category    text,
  p_detail      text DEFAULT NULL
) RETURNS TABLE(report_id uuid)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_actor_id            uuid;
  v_case                record;
  v_comment             record;
  v_clue                record;
  v_profile             record;
  v_provisional_case_id uuid;
  v_media               record;
  v_report_id           uuid;
BEGIN
  v_actor_id := private.auth_uid();

  IF NOT EXISTS (
    SELECT 1 FROM public.profiles
    WHERE id = v_actor_id AND is_active = true AND onboarding_complete = true
  ) THEN
    RAISE EXCEPTION 'FK_FORBIDDEN: account not eligible to report';
  END IF;

  IF p_target_type NOT IN ('case','comment','clue','media_object','profile') THEN
    RAISE EXCEPTION 'FK_INVALID_INPUT: unknown target_type %', p_target_type;
  END IF;

  IF p_category NOT IN ('inappropriate_image','offensive_content','spam','harassment','copyright','other') THEN
    RAISE EXCEPTION 'FK_INVALID_INPUT: invalid category';
  END IF;

  IF (SELECT count(*) FROM public.content_reports
      WHERE reporter_id = v_actor_id
        AND status = 'pending'
        AND created_at > clock_timestamp() - interval '1 hour') >= 10 THEN
    RAISE EXCEPTION 'FK_RATE_LIMITED: too many reports submitted this hour';
  END IF;

  -- Target-first locking order per Step 26 Rev 15 §10.3

  IF p_target_type = 'case' THEN
    SELECT id, state, poster_id, moderator_removed_at INTO v_case
    FROM public.cases WHERE id = p_target_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'FK_NOT_FOUND'; END IF;
    IF NOT private.can_view_case(p_target_id) THEN RAISE EXCEPTION 'FK_NOT_FOUND'; END IF;
    IF v_case.moderator_removed_at IS NOT NULL THEN RAISE EXCEPTION 'FK_NOT_FOUND'; END IF;
    IF v_case.state = 'cancelled' THEN
      RAISE EXCEPTION 'FK_INVALID_INPUT: cannot report cancelled case';
    END IF;
    -- Bug 4C: compare reporter against case owner
    IF v_case.poster_id = v_actor_id THEN
      RAISE EXCEPTION 'FK_SELF_REPORT: cannot report your own case';
    END IF;

  ELSIF p_target_type = 'comment' THEN
    SELECT id, case_id, investigation_id, author_id, moderator_removed_at INTO v_comment
    FROM public.comments WHERE id = p_target_id FOR UPDATE;
    IF NOT FOUND OR v_comment.moderator_removed_at IS NOT NULL THEN
      RAISE EXCEPTION 'FK_NOT_FOUND';
    END IF;
    -- Bug 4A: no group_id on cases after Phase 18
    SELECT id, state INTO v_case
    FROM public.cases WHERE id = v_comment.case_id FOR UPDATE;
    IF v_case.state = 'cancelled' THEN
      RAISE EXCEPTION 'FK_INVALID_INPUT: cannot report content in cancelled case';
    END IF;
    -- B10: Check is_case_poster FIRST (posters are not investigation members)
    IF private.is_case_poster(v_comment.case_id) THEN
      NULL; -- poster can see all comments; skip membership check
    ELSE
      -- check membership in the comment''s specific investigation
      IF NOT EXISTS (
        SELECT 1 FROM public.investigation_members
        WHERE investigation_id = v_comment.investigation_id AND player_id = v_actor_id
      ) THEN RAISE EXCEPTION 'FK_NOT_FOUND'; END IF;
      -- Caller must have guessed OR case must be revealed
      IF NOT (
        private.is_case_revealed(v_comment.case_id)
        OR EXISTS (SELECT 1 FROM public.guess_attempts
                   WHERE case_id = v_comment.case_id AND player_id = v_actor_id)
      ) THEN RAISE EXCEPTION 'FK_NOT_FOUND'; END IF;
    END IF;
    -- Bug 4C: compare reporter against comment author
    IF v_comment.author_id = v_actor_id THEN
      RAISE EXCEPTION 'FK_SELF_REPORT: cannot report your own comment';
    END IF;

  ELSIF p_target_type = 'clue' THEN
    SELECT id, case_id, poster_id, moderator_removed_at INTO v_clue
    FROM public.clues WHERE id = p_target_id FOR UPDATE;
    IF NOT FOUND OR v_clue.moderator_removed_at IS NOT NULL THEN
      RAISE EXCEPTION 'FK_NOT_FOUND';
    END IF;
    IF NOT private.can_view_case(v_clue.case_id) THEN RAISE EXCEPTION 'FK_NOT_FOUND'; END IF;
    SELECT id, state INTO v_case FROM public.cases WHERE id = v_clue.case_id FOR UPDATE;
    -- Bug 4E: cancelled check in clue branch
    IF v_case.state = 'cancelled' THEN
      RAISE EXCEPTION 'FK_INVALID_INPUT: cannot report content in cancelled case';
    END IF;
    -- Bug 4C: compare reporter against clue poster
    IF v_clue.poster_id = v_actor_id THEN
      RAISE EXCEPTION 'FK_SELF_REPORT: cannot report your own clue';
    END IF;

  ELSIF p_target_type = 'media_object' THEN
    SELECT id INTO v_provisional_case_id FROM public.cases
    WHERE media_object_id = p_target_id LIMIT 1;
    IF v_provisional_case_id IS NULL THEN RAISE EXCEPTION 'FK_NOT_FOUND'; END IF;
    SELECT id, state, poster_id, media_object_id INTO v_case
    FROM public.cases WHERE id = v_provisional_case_id FOR UPDATE;
    IF v_case.media_object_id IS DISTINCT FROM p_target_id THEN
      RAISE EXCEPTION 'FK_NOT_FOUND';
    END IF;
    IF NOT private.can_view_case(v_provisional_case_id) THEN RAISE EXCEPTION 'FK_NOT_FOUND'; END IF;
    SELECT id, status, uploader_id INTO v_media FROM public.media_objects WHERE id = p_target_id FOR UPDATE;
    IF NOT FOUND OR v_media.status != 'ready' THEN RAISE EXCEPTION 'FK_NOT_FOUND'; END IF;
    IF v_case.state = 'cancelled' THEN
      RAISE EXCEPTION 'FK_INVALID_INPUT: cannot report content in cancelled case';
    END IF;
    -- Bug 4C: compare reporter against media uploader
    IF v_media.uploader_id = v_actor_id THEN
      RAISE EXCEPTION 'FK_SELF_REPORT: cannot report your own media';
    END IF;

  ELSIF p_target_type = 'profile' THEN
    -- Bug 4F: lock target profile FOR UPDATE
    SELECT id, is_active INTO v_profile FROM public.profiles WHERE id = p_target_id FOR UPDATE;
    IF NOT FOUND OR NOT v_profile.is_active THEN
      RAISE EXCEPTION 'FK_NOT_FOUND';
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM public.group_members gm1
      JOIN public.group_members gm2 ON gm1.group_id = gm2.group_id
      WHERE gm1.player_id = v_actor_id AND gm2.player_id = p_target_id
    ) THEN RAISE EXCEPTION 'FK_NOT_FOUND'; END IF;
    -- Bug 4C: self-report (profile target)
    IF p_target_id = v_actor_id THEN
      RAISE EXCEPTION 'FK_SELF_REPORT: cannot report yourself';
    END IF;
  END IF;

  INSERT INTO public.content_reports (
    reporter_id, target_type, target_id, category, detail, status
  ) VALUES (
    v_actor_id, p_target_type, p_target_id, p_category, p_detail, 'pending'
  )
  ON CONFLICT (reporter_id, target_type, target_id, category) WHERE status = 'pending'
  DO NOTHING
  RETURNING id INTO v_report_id;

  IF v_report_id IS NULL THEN
    SELECT id INTO v_report_id FROM public.content_reports
    WHERE reporter_id = v_actor_id
      AND target_type = p_target_type
      AND target_id   = p_target_id
      AND category    = p_category
      AND status      = 'pending';
  END IF;

  RETURN QUERY SELECT v_report_id;
END;
$$;
ALTER FUNCTION public.report_content(text, uuid, text, text) OWNER TO forkensics_executor;

-- ------------------------------------------------------------
-- 19.0D  UPDATE V3 FUNCTION: public.approve_photo — cases table
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.approve_photo(
  p_media_object_id uuid,
  p_moderator_id    uuid,
  p_reason          text
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_case_id   uuid;       -- R6-B6: case-first lock
  v_case      record;
  v_media     record;
  v_action_id uuid;
BEGIN
  -- validate moderator (V3 join pattern)
  IF NOT EXISTS (
    SELECT 1 FROM private.moderators m
    JOIN public.profiles p ON p.id = m.profile_id
    WHERE m.profile_id = p_moderator_id AND p.is_active = true
  ) THEN RAISE EXCEPTION 'FK_UNAUTHORIZED: moderator identity not valid'; END IF;

  -- Step 1: provisional case lookup (no lock)
  SELECT id INTO v_case_id FROM public.cases
  WHERE media_object_id = p_media_object_id LIMIT 1;
  IF v_case_id IS NULL THEN RAISE EXCEPTION 'FK_NOT_FOUND'; END IF;

  -- Step 2: lock case first (consistent with remove_media / report_content)
  SELECT id, state, media_object_id INTO v_case
  FROM public.cases WHERE id = v_case_id FOR UPDATE;

  -- Step 3: revalidate linkage after lock
  IF v_case.media_object_id IS DISTINCT FROM p_media_object_id THEN
    RAISE EXCEPTION 'FK_LINKAGE_CHANGED';
  END IF;

  -- Step 4: lock media row
  SELECT id, status INTO v_media
  FROM public.media_objects WHERE id = p_media_object_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'FK_NOT_FOUND'; END IF;
  IF v_media.status != 'pending_review' THEN
    RAISE EXCEPTION 'FK_WRONG_STATE: media not pending_review (status: %)', v_media.status;
  END IF;

  -- Step 5: insert action first
  INSERT INTO public.moderation_actions (
    moderator_id, action_type, target_type, target_id, reason
  ) VALUES (p_moderator_id, 'photo_approved', 'media_object', p_media_object_id, p_reason)
  RETURNING id INTO v_action_id;

  -- Step 6: advance case draft → ready
  UPDATE public.cases SET state = 'ready'
  WHERE id = v_case_id AND state = 'draft';

  -- Step 7: update media
  UPDATE public.media_objects
  SET status = 'ready', moderated_at = clock_timestamp()
  WHERE id = p_media_object_id;
END;
$$;
ALTER FUNCTION public.approve_photo(uuid, uuid, text) OWNER TO forkensics_executor;

-- ------------------------------------------------------------
-- 19.0E  UPDATE V3 FUNCTION: public.reject_photo — cases table
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.reject_photo(
  p_media_object_id uuid,
  p_moderator_id    uuid,
  p_reason          text
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_case_id     uuid;       -- R6-B6: case-first lock
  v_case        record;
  v_media       record;
  v_action_id   uuid;
  v_sha256      text;
  v_storage_key text;
BEGIN
  -- validate moderator (V3 join pattern)
  IF NOT EXISTS (
    SELECT 1 FROM private.moderators m
    JOIN public.profiles p ON p.id = m.profile_id
    WHERE m.profile_id = p_moderator_id AND p.is_active = true
  ) THEN RAISE EXCEPTION 'FK_UNAUTHORIZED: moderator identity not valid'; END IF;

  -- Step 1: provisional case lookup (no lock)
  SELECT id INTO v_case_id FROM public.cases
  WHERE media_object_id = p_media_object_id LIMIT 1;
  IF v_case_id IS NULL THEN RAISE EXCEPTION 'FK_NOT_FOUND'; END IF;

  -- Step 2: lock case first
  SELECT id, state, media_object_id INTO v_case
  FROM public.cases WHERE id = v_case_id FOR UPDATE;

  -- Step 3: revalidate linkage after lock
  IF v_case.media_object_id IS DISTINCT FROM p_media_object_id THEN
    RAISE EXCEPTION 'FK_LINKAGE_CHANGED';
  END IF;

  -- Step 4: lock media row
  SELECT id, status INTO v_media
  FROM public.media_objects WHERE id = p_media_object_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'FK_NOT_FOUND'; END IF;
  IF v_media.status != 'pending_review' THEN
    RAISE EXCEPTION 'FK_WRONG_STATE: media not pending_review (status: %)', v_media.status;
  END IF;

  -- Step 5: read SHA-256 for evidence
  SELECT sha256_hash, re_encoded_storage_key INTO v_sha256, v_storage_key
  FROM private.media_storage_keys WHERE media_object_id = p_media_object_id;
  IF v_sha256 IS NULL THEN RAISE EXCEPTION 'FK_MEDIA_METADATA_INCOMPLETE'; END IF;

  -- Step 6: insert action
  INSERT INTO public.moderation_actions (
    moderator_id, action_type, target_type, target_id, reason
  ) VALUES (p_moderator_id, 'photo_rejected', 'media_object', p_media_object_id, p_reason)
  RETURNING id INTO v_action_id;

  -- Step 7: insert evidence
  INSERT INTO private.moderation_evidence
    (moderation_action_id, evidence_type, evidence_storage_key, evidence_sha256)
  VALUES (v_action_id, 'media_metadata', v_storage_key, v_sha256);

  -- Step 8: update media
  UPDATE public.media_objects
  SET status = 'rejected', moderated_at = clock_timestamp()
  WHERE id = p_media_object_id;

  -- Step 9: detach from case (draft only)
  UPDATE public.cases SET media_object_id = NULL
  WHERE id = v_case_id AND state = 'draft';
END;
$$;
ALTER FUNCTION public.reject_photo(uuid, uuid, text) OWNER TO forkensics_executor;

-- ------------------------------------------------------------
-- 19.11  SERVICE FUNCTION: public.lock_case(p_case_id uuid) — service_role only
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lock_case(p_case_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_case record;
BEGIN
  SELECT id, state, deadline_at INTO v_case
  FROM public.cases WHERE id = p_case_id FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'FK_NOT_FOUND: case not found';
  END IF;

  IF v_case.state != 'launched' THEN
    RAISE EXCEPTION 'FK_INVALID_INPUT: case must be in launched state to lock (current: %)', v_case.state;
  END IF;

  IF clock_timestamp() < v_case.deadline_at THEN
    RAISE EXCEPTION 'FK_INVALID_INPUT: deadline has not yet passed';
  END IF;

  UPDATE public.cases
  SET state = 'locked', locked_at = clock_timestamp()
  WHERE id = p_case_id;
END;
$$;
ALTER FUNCTION public.lock_case(uuid) OWNER TO forkensics_executor;

-- ------------------------------------------------------------
-- 19.12  SERVICE FUNCTION: private.do_reveal_impl_v3
-- Scores eligible members of one investigation. Caller holds FOR UPDATE on cases.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.do_reveal_impl_v3(
  p_case_id          uuid,
  p_investigation_id uuid
)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_rules_version_id   uuid;
  v_score_run_id       uuid;
  v_eligible_count     integer;
  v_secrets            record;
  v_attempt            record;
  v_norm_dish          text;
  v_norm_restaurant    text;
  v_what_correct       boolean;
  v_where_correct      boolean;
  v_revision_number    integer;
  -- Temp tables built during loop
  v_norm_canonical_dish        text;
  v_norm_canonical_restaurant  text;
  v_what_first_player  uuid := NULL;   -- player_id of first correct what
  v_where_first_player uuid := NULL;   -- player_id of first correct where
BEGIN
  -- Get canonical answers
  SELECT cs.canonical_dish, cs.canonical_restaurant
  INTO v_secrets
  FROM public.case_secrets cs
  WHERE cs.case_id = p_case_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'case_secrets not found for case %', p_case_id;
  END IF;

  -- Blocker 6A: normalize canonical answers before comparison loop
  v_norm_canonical_dish       := private.normalize_answer(v_secrets.canonical_dish);
  v_norm_canonical_restaurant := private.normalize_answer(v_secrets.canonical_restaurant);

  SELECT rules_version_id INTO v_rules_version_id
  FROM public.cases WHERE id = p_case_id;

  SELECT count(*) INTO v_eligible_count
  FROM public.investigation_members
  WHERE investigation_id  = p_investigation_id
    AND eligibility_status = 'eligible';

  SELECT COALESCE(max(revision_number), 0) + 1 INTO v_revision_number
  FROM public.score_runs WHERE investigation_id = p_investigation_id;

  INSERT INTO public.score_runs (
    case_id, investigation_id, revision_number, rules_version_id,
    effective_eligible_count, triggering_correction_id
  )
  VALUES (
    p_case_id, p_investigation_id, v_revision_number,
    v_rules_version_id, v_eligible_count, NULL
  )
  RETURNING id INTO v_score_run_id;

  -- Build tmp_judgments: ordered by receipt_sequence to determine first-correct
  CREATE TEMP TABLE tmp_judgments (
    player_id        uuid,
    race             text,
    ga_id            uuid,
    receipt_seq      bigint,
    is_correct       boolean
  ) ON COMMIT DROP;

  -- Evaluate all eligible members' attempts in receipt_sequence order
  -- so the FIRST inserted row per (race, correct=true) is truly the first submitter.
  FOR v_attempt IN
    SELECT ga.id, ga.player_id, ga.race, ga.receipt_sequence,
           ga.dish_guess, ga.restaurant_guess
    FROM public.guess_attempts ga
    JOIN public.investigation_members im
      ON im.investigation_id = p_investigation_id
     AND im.player_id        = ga.player_id
     AND im.eligibility_status = 'eligible'
    WHERE ga.case_id = p_case_id
    ORDER BY ga.receipt_sequence ASC
  LOOP
    IF v_attempt.race = 'what' THEN
      v_norm_dish    := private.normalize_answer(v_attempt.dish_guess);
      -- Blocker 6A: use pre-normalized canonical
      v_what_correct := (v_norm_dish = v_norm_canonical_dish)
        OR EXISTS (
          SELECT 1 FROM public.case_answer_aliases
          WHERE case_id = p_case_id AND field = 'dish'
            AND normalized_value = v_norm_dish AND is_active = true
        );
      INSERT INTO tmp_judgments VALUES
        (v_attempt.player_id, 'what', v_attempt.id, v_attempt.receipt_sequence, v_what_correct);
    ELSE  -- 'where'
      v_norm_restaurant := private.normalize_answer(v_attempt.restaurant_guess);
      -- Blocker 6A: use pre-normalized canonical
      v_where_correct   := (v_norm_restaurant = v_norm_canonical_restaurant)
        OR EXISTS (
          SELECT 1 FROM public.case_answer_aliases
          WHERE case_id = p_case_id AND field = 'restaurant'
            AND normalized_value = v_norm_restaurant AND is_active = true
        );
      INSERT INTO tmp_judgments VALUES
        (v_attempt.player_id, 'where', v_attempt.id, v_attempt.receipt_sequence, v_where_correct);
    END IF;
  END LOOP;

  -- Determine first correct per race (lowest receipt_sequence among is_correct=true)
  SELECT player_id INTO v_what_first_player
  FROM tmp_judgments WHERE race = 'what' AND is_correct = true
  ORDER BY receipt_seq ASC LIMIT 1;

  SELECT player_id INTO v_where_first_player
  FROM tmp_judgments WHERE race = 'where' AND is_correct = true
  ORDER BY receipt_seq ASC LIMIT 1;

  -- Insert guess_judgments
  INSERT INTO public.guess_judgments (
    score_run_id, guess_attempt_id, player_id, case_id, investigation_id,
    race, rules_version_id, is_correct, is_first_correct_for_player
  )
  SELECT
    v_score_run_id, j.ga_id, j.player_id, p_case_id, p_investigation_id,
    j.race, v_rules_version_id, j.is_correct,
    -- Blocker 6B: per-player semantics (UNIQUE(case_id,player_id,race) = one guess per race)
    j.is_correct
  FROM tmp_judgments j;

  -- Insert score_events using formula: eligible_count − rank + 1
  WITH what_ranked AS (
    SELECT player_id, row_number() OVER (ORDER BY receipt_seq)::integer AS rnk
    FROM tmp_judgments WHERE race = 'what' AND is_correct = true
  ),
  where_ranked AS (
    SELECT player_id, row_number() OVER (ORDER BY receipt_seq)::integer AS rnk
    FROM tmp_judgments WHERE race = 'where' AND is_correct = true
  )
  INSERT INTO public.score_events (
    score_run_id, case_id, investigation_id, player_id, rules_version_id,
    what_points, where_points, what_rank, where_rank
  )
  SELECT
    v_score_run_id, p_case_id, p_investigation_id, im.player_id, v_rules_version_id,
    CASE WHEN wr.rnk  IS NOT NULL THEN GREATEST(1, v_eligible_count - wr.rnk  + 1) ELSE 0 END,
    CASE WHEN whr.rnk IS NOT NULL THEN GREATEST(1, v_eligible_count - whr.rnk + 1) ELSE 0 END,
    wr.rnk,
    whr.rnk
  FROM public.investigation_members im
  LEFT JOIN what_ranked  wr  ON wr.player_id  = im.player_id
  LEFT JOIN where_ranked whr ON whr.player_id = im.player_id
  WHERE im.investigation_id  = p_investigation_id
    AND im.eligibility_status = 'eligible';

  DROP TABLE IF EXISTS tmp_judgments;
END;
$$;
ALTER FUNCTION private.do_reveal_impl_v3(uuid, uuid) OWNER TO forkensics_executor;
-- Blocker 8: prevent authenticated from calling internal reveal function
REVOKE ALL ON FUNCTION private.do_reveal_impl_v3(uuid, uuid) FROM PUBLIC;

-- ------------------------------------------------------------
-- 19.13  SERVICE FUNCTION: public.reveal_case — authenticated poster
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.reveal_case(p_case_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_case          record;
  v_investigation record;
  v_actor_id      uuid;
BEGIN
  v_actor_id := private.auth_uid();

  -- Active profile check
  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = v_actor_id AND is_active = true) THEN
    RAISE EXCEPTION 'FK_FORBIDDEN: inactive account';
  END IF;

  -- Lock case
  SELECT id, state, poster_id, deadline_at INTO v_case
  FROM public.cases WHERE id = p_case_id FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'FK_NOT_FOUND';
  END IF;

  IF v_case.poster_id != v_actor_id THEN
    RAISE EXCEPTION 'FK_FORBIDDEN: only the poster can reveal';
  END IF;

  IF v_case.state != 'locked' THEN
    RAISE EXCEPTION 'FK_INVALID_INPUT: case must be locked to reveal (current: %)', v_case.state;
  END IF;

  -- Score each active investigation
  FOR v_investigation IN
    SELECT investigation_id FROM public.investigations
    WHERE case_id = p_case_id AND status = 'active'
  LOOP
    PERFORM private.do_reveal_impl_v3(p_case_id, v_investigation.investigation_id);
  END LOOP;

  UPDATE public.cases
  SET state = 'revealed', revealed_at = clock_timestamp()
  WHERE id = p_case_id;
END;
$$;
ALTER FUNCTION public.reveal_case(uuid) OWNER TO forkensics_executor;

-- ------------------------------------------------------------
-- 19.14  SERVICE FUNCTION: private.reveal_case_service — service_role only
-- Requires state='locked'.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.reveal_case_service(p_case_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_case          record;
  v_investigation record;
BEGIN
  SELECT id, state INTO v_case
  FROM public.cases WHERE id = p_case_id FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'FK_NOT_FOUND';
  END IF;

  IF v_case.state != 'locked' THEN
    RAISE EXCEPTION 'FK_INVALID_INPUT: case must be locked for service reveal (current: %)', v_case.state;
  END IF;

  FOR v_investigation IN
    SELECT investigation_id FROM public.investigations
    WHERE case_id = p_case_id AND status = 'active'
  LOOP
    PERFORM private.do_reveal_impl_v3(p_case_id, v_investigation.investigation_id);
  END LOOP;

  UPDATE public.cases
  SET state = 'revealed', revealed_at = clock_timestamp()
  WHERE id = p_case_id;
END;
$$;
ALTER FUNCTION private.reveal_case_service(uuid) OWNER TO forkensics_executor;

-- Create reveal_case_service_wrapper (DROP moved to Phase 13A; grant restored in Phase 20)
CREATE OR REPLACE FUNCTION public.reveal_case_service_wrapper(p_case_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
  PERFORM private.reveal_case_service(p_case_id);
END;
$$;
ALTER FUNCTION public.reveal_case_service_wrapper(uuid) OWNER TO forkensics_executor;

-- ------------------------------------------------------------
-- 19.15  SERVICE FUNCTION: public.cancel_case — poster only
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cancel_case(p_case_id uuid, p_reason text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_case     record;
  v_actor_id uuid;
BEGIN
  v_actor_id := private.auth_uid();

  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = v_actor_id AND is_active = true) THEN
    RAISE EXCEPTION 'FK_FORBIDDEN: inactive account';
  END IF;

  SELECT id, state, poster_id, deadline_at INTO v_case
  FROM public.cases WHERE id = p_case_id FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'FK_NOT_FOUND';
  END IF;

  IF v_case.poster_id != v_actor_id THEN
    RAISE EXCEPTION 'FK_FORBIDDEN: only the poster can cancel';
  END IF;

  IF v_case.state NOT IN ('draft','ready','launched') THEN
    RAISE EXCEPTION 'FK_INVALID_INPUT: case cannot be cancelled in state %', v_case.state;
  END IF;

  -- Deadline guard: cannot cancel a launched case after deadline
  IF v_case.state = 'launched' AND clock_timestamp() >= v_case.deadline_at THEN
    RAISE EXCEPTION 'FK_INVALID_INPUT: deadline has passed; case cannot be cancelled';
  END IF;

  UPDATE public.cases
  SET state = 'cancelled', cancelled_at = clock_timestamp(), cancellation_reason = p_reason
  WHERE id = p_case_id;

  -- Cancel all active investigations
  UPDATE public.investigations
  SET status = 'cancelled', cancelled_at = clock_timestamp(), cancellation_reason = p_reason
  WHERE case_id = p_case_id AND status = 'active';
END;
$$;
ALTER FUNCTION public.cancel_case(uuid, text) OWNER TO forkensics_executor;

-- ------------------------------------------------------------
-- 19.16  SERVICE FUNCTION: public.cancel_investigation — poster or Table owner
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cancel_investigation(
  p_investigation_id uuid,
  p_reason           text
)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_inv    record;
  v_case   record;
  v_actor_id uuid;
BEGIN
  v_actor_id := private.auth_uid();

  -- Suspended / inactive check
  IF NOT EXISTS (
    SELECT 1 FROM public.profiles WHERE id = v_actor_id AND is_active = true
  ) THEN
    RAISE EXCEPTION 'FK_FORBIDDEN: inactive account';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.profiles WHERE id = v_actor_id AND is_suspended = true
  ) THEN
    RAISE EXCEPTION 'FK_FORBIDDEN: suspended account';
  END IF;

  -- Lock investigation + case
  SELECT i.investigation_id, i.status, i.case_id, i.group_id INTO v_inv
  FROM public.investigations i WHERE i.investigation_id = p_investigation_id FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'FK_NOT_FOUND';
  END IF;

  SELECT c.id, c.state, c.poster_id, c.deadline_at INTO v_case
  FROM public.cases c WHERE c.id = v_inv.case_id FOR UPDATE;

  IF v_case.state != 'launched' THEN
    RAISE EXCEPTION 'FK_INVALID_INPUT: investigation can only be cancelled while case is launched (current: %)', v_case.state;
  END IF;

  -- Deadline guard
  IF clock_timestamp() >= v_case.deadline_at THEN
    RAISE EXCEPTION 'FK_INVALID_INPUT: deadline has passed; investigation cannot be cancelled';
  END IF;

  -- Authorization: poster or Table owner
  IF v_case.poster_id != v_actor_id AND NOT EXISTS (
    SELECT 1 FROM public.group_members
    WHERE group_id = v_inv.group_id AND player_id = v_actor_id AND role = 'owner'
  ) THEN
    RAISE EXCEPTION 'FK_FORBIDDEN: only the case poster or Table owner can cancel an investigation';
  END IF;

  IF v_inv.status != 'active' THEN
    RAISE EXCEPTION 'FK_INVALID_INPUT: investigation is not active (current: %)', v_inv.status;
  END IF;

  UPDATE public.investigations
  SET status = 'cancelled', cancelled_at = clock_timestamp(), cancellation_reason = p_reason
  WHERE investigation_id = p_investigation_id;
END;
$$;
ALTER FUNCTION public.cancel_investigation(uuid, text) OWNER TO forkensics_executor;

-- ------------------------------------------------------------
-- 19.17  SERVICE FUNCTION: public.submit_guess — detective only
-- Steps 1-7 per Rev 15 §18.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.submit_guess(
  p_case_id          uuid,
  p_investigation_id uuid,
  p_race             text,
  p_guess_text       text,
  p_idempotency_key  text,
  p_client_submitted_at timestamptz DEFAULT NULL
)
RETURNS uuid  -- returns guess_attempt id
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_actor_id         uuid;
  v_case             record;
  v_inv              record;
  v_member           record;
  v_existing         record;
  v_new_id           uuid;
  v_dish_guess       text := NULL;
  v_restaurant_guess text := NULL;
BEGIN
  -- Step 1: active + onboarded + not suspended
  v_actor_id := private.auth_uid();

  IF NOT EXISTS (
    SELECT 1 FROM public.profiles
    WHERE id = v_actor_id AND is_active = true AND onboarding_complete = true
  ) THEN
    RAISE EXCEPTION 'FK_FORBIDDEN: account not eligible to submit guesses';
  END IF;

  IF EXISTS (SELECT 1 FROM public.profiles WHERE id = v_actor_id AND is_suspended = true) THEN
    RAISE EXCEPTION 'FK_FORBIDDEN: suspended account';
  END IF;

  -- Step 1b: fast-path poster reject
  IF EXISTS (SELECT 1 FROM public.cases WHERE id = p_case_id AND poster_id = v_actor_id) THEN
    RAISE EXCEPTION 'FK_FORBIDDEN: poster cannot submit a guess';
  END IF;

  -- Step 2: race validation
  IF p_race NOT IN ('what','where') THEN
    RAISE EXCEPTION 'FK_INVALID_INPUT: race must be ''what'' or ''where''';
  END IF;

  IF p_race = 'what' THEN
    IF p_guess_text IS NULL OR length(trim(p_guess_text)) NOT BETWEEN 1 AND 200 THEN
      RAISE EXCEPTION 'FK_INVALID_INPUT: invalid guess text length for what race';
    END IF;
    v_dish_guess := p_guess_text;
  ELSE
    IF p_guess_text IS NULL OR length(trim(p_guess_text)) NOT BETWEEN 1 AND 200 THEN
      RAISE EXCEPTION 'FK_INVALID_INPUT: invalid guess text length for where race';
    END IF;
    v_restaurant_guess := p_guess_text;
  END IF;

  -- Blocker 5: verify investigation belongs to case (prevent cross-case injection)
  IF NOT EXISTS (
    SELECT 1 FROM public.investigations
    WHERE investigation_id = p_investigation_id AND case_id = p_case_id
  ) THEN
    RAISE EXCEPTION 'FK_NOT_FOUND: investigation % does not belong to case %',
      p_investigation_id, p_case_id;
  END IF;

  -- Step 3: idempotency lookup
  IF p_idempotency_key IS NOT NULL THEN
    SELECT id, race, dish_guess, restaurant_guess
    INTO v_existing
    FROM public.guess_attempts
    WHERE case_id = p_case_id AND player_id = v_actor_id AND idempotency_key = p_idempotency_key;

    IF FOUND THEN
      IF v_existing.race != p_race THEN
        RAISE EXCEPTION 'FK_CONFLICT: idempotency key used for different race';
      END IF;
      -- Compare payload text to detect reuse with different content
      IF p_race = 'what' THEN
        IF v_existing.dish_guess IS DISTINCT FROM p_guess_text THEN
          RAISE EXCEPTION 'FK_CONFLICT: idempotency key reused with different guess text';
        END IF;
      ELSE
        IF v_existing.restaurant_guess IS DISTINCT FROM p_guess_text THEN
          RAISE EXCEPTION 'FK_CONFLICT: idempotency key reused with different guess text';
        END IF;
      END IF;
      -- Identical payload: idempotent return
      RETURN v_existing.id;
    END IF;
  END IF;

  -- Check if player already has a locked guess for this race (one per race)
  IF EXISTS (
    SELECT 1 FROM public.guess_attempts
    WHERE case_id = p_case_id AND player_id = v_actor_id AND race = p_race
  ) THEN
    RAISE EXCEPTION 'FK_CONFLICT: player already has a locked guess for race %', p_race;
  END IF;

  -- Step 4: FOR SHARE case lock; validate state and deadline
  SELECT id, state, poster_id, deadline_at INTO v_case
  FROM public.cases WHERE id = p_case_id FOR SHARE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'FK_NOT_FOUND';
  END IF;

  -- Poster re-check with locked row
  IF v_case.poster_id = v_actor_id THEN
    RAISE EXCEPTION 'FK_FORBIDDEN: poster cannot submit a guess';
  END IF;

  IF v_case.state != 'launched' THEN
    RAISE EXCEPTION 'FK_INVALID_INPUT: guesses only accepted in launched state (current: %)', v_case.state;
  END IF;

  IF clock_timestamp() >= v_case.deadline_at THEN
    RAISE EXCEPTION 'FK_INVALID_INPUT: deadline has passed';
  END IF;

  -- Step 5: investigation membership + eligibility
  SELECT gm.investigation_id, gm.eligibility_status INTO v_member
  FROM public.investigation_members gm
  WHERE gm.investigation_id = p_investigation_id AND gm.player_id = v_actor_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'FK_FORBIDDEN: not a member of this investigation';
  END IF;

  IF v_member.eligibility_status != 'eligible' THEN
    RAISE EXCEPTION 'FK_FORBIDDEN: member is not eligible (status: %)', v_member.eligibility_status;
  END IF;

  SELECT status INTO v_inv
  FROM public.investigations WHERE investigation_id = p_investigation_id;

  IF NOT FOUND OR v_inv.status != 'active' THEN
    RAISE EXCEPTION 'FK_INVALID_INPUT: investigation is not active';
  END IF;

  -- Step 6: bilateral block check
  IF private.has_block_with_poster(p_case_id) THEN
    RAISE EXCEPTION 'FK_FORBIDDEN: block relationship with poster';
  END IF;

  -- Step 7: INSERT; handle concurrent duplicate via unique violation
  BEGIN
    INSERT INTO public.guess_attempts (
      case_id, player_id, race, dish_guess, restaurant_guess,
      idempotency_key, client_submitted_at
    ) VALUES (
      p_case_id, v_actor_id, p_race, v_dish_guess, v_restaurant_guess,
      p_idempotency_key, p_client_submitted_at
    )
    RETURNING id INTO v_new_id;

    -- Set has_first_guess on case_secrets if first guess ever for this case
    IF NOT EXISTS (
      SELECT 1 FROM public.guess_attempts
      WHERE case_id = p_case_id AND id != v_new_id
    ) THEN
      UPDATE public.case_secrets SET has_first_guess = true WHERE case_id = p_case_id;
    END IF;

    RETURN v_new_id;

  EXCEPTION WHEN unique_violation THEN
    -- Blocker 9: key-first concurrent recovery
    IF p_idempotency_key IS NOT NULL THEN
      SELECT id, race, dish_guess, restaurant_guess INTO v_existing
      FROM public.guess_attempts
      WHERE case_id = p_case_id AND player_id = v_actor_id
        AND idempotency_key = p_idempotency_key;

      IF FOUND THEN
        IF v_existing.race != p_race THEN
          RAISE EXCEPTION 'FK_CONFLICT: idempotency key used for different race';
        END IF;
        IF p_race = 'what' AND v_existing.dish_guess IS DISTINCT FROM p_guess_text THEN
          RAISE EXCEPTION 'FK_CONFLICT: idempotency key reused with different guess text';
        END IF;
        IF p_race = 'where' AND v_existing.restaurant_guess IS DISTINCT FROM p_guess_text THEN
          RAISE EXCEPTION 'FK_CONFLICT: idempotency key reused with different guess text';
        END IF;
        RETURN v_existing.id;
      ELSE
        RAISE EXCEPTION 'FK_CONFLICT: player already has a locked guess for race % (concurrent, different key)', p_race;
      END IF;

    ELSE
      IF EXISTS (SELECT 1 FROM public.guess_attempts
                 WHERE case_id = p_case_id AND player_id = v_actor_id AND race = p_race)
      THEN RAISE EXCEPTION 'FK_CONFLICT: player already has a locked guess for race %', p_race;
      END IF;
      RAISE;
    END IF;
  END;
END;
$$;
ALTER FUNCTION public.submit_guess(uuid, uuid, text, text, text, timestamptz) OWNER TO forkensics_executor;

-- ------------------------------------------------------------
-- 19.18  SERVICE FUNCTION: public.launch_case — authenticated poster
-- Rev 15 §19: Step 11 filters gm.player_id != p_actor_id (poster excluded).
-- Zero detectives after filtering → FK_INVALID_INPUT.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.launch_case(
  p_case_id         uuid,
  p_actor_id        uuid,
  p_group_ids       uuid[],
  p_duration_seconds integer
)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_actor_id         uuid;
  v_case             record;
  v_group_id         uuid;
  v_investigation_id uuid;
  v_member           record;
  v_detective_count  integer;
  v_deadline_at      timestamptz;
BEGIN
  -- Step 1: enforce actor identity from JWT
  v_actor_id := private.auth_uid();
  IF v_actor_id != p_actor_id THEN
    RAISE EXCEPTION 'FK_FORBIDDEN: p_actor_id must match authenticated caller';
  END IF;

  -- Step 2: active + onboarded + not suspended
  IF NOT EXISTS (
    SELECT 1 FROM public.profiles
    WHERE id = v_actor_id AND is_active = true AND onboarding_complete = true
  ) THEN
    RAISE EXCEPTION 'FK_FORBIDDEN: account not eligible to launch';
  END IF;

  IF EXISTS (SELECT 1 FROM public.profiles WHERE id = v_actor_id AND is_suspended = true) THEN
    RAISE EXCEPTION 'FK_FORBIDDEN: suspended account cannot launch';
  END IF;

  -- Step 3: lock case
  SELECT id, state, poster_id, media_object_id, duration_seconds INTO v_case
  FROM public.cases WHERE id = p_case_id FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'FK_NOT_FOUND';
  END IF;

  IF v_case.poster_id != v_actor_id THEN
    RAISE EXCEPTION 'FK_FORBIDDEN: only the poster can launch';
  END IF;

  IF v_case.state != 'ready' THEN
    RAISE EXCEPTION 'FK_INVALID_INPUT: case must be in ready state to launch (current: %)', v_case.state;
  END IF;

  -- Step 4: media must be ready
  IF v_case.media_object_id IS NULL THEN
    RAISE EXCEPTION 'FK_INVALID_INPUT: case has no photo';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.media_objects
    WHERE id = v_case.media_object_id AND status = 'ready'
  ) THEN
    RAISE EXCEPTION 'FK_INVALID_INPUT: case photo is not ready';
  END IF;

  -- Step 5: duration validation
  IF p_duration_seconds IS NOT NULL THEN
    IF p_duration_seconds NOT BETWEEN 3600 AND 86400 OR p_duration_seconds % 3600 != 0 THEN
      RAISE EXCEPTION 'FK_INVALID_INPUT: invalid duration_seconds';
    END IF;
  END IF;

  -- Step 6: group count validation (max 10)
  IF array_length(p_group_ids, 1) IS NULL OR array_length(p_group_ids, 1) = 0 THEN
    RAISE EXCEPTION 'FK_INVALID_INPUT: at least one group required';
  END IF;
  IF array_length(p_group_ids, 1) > 10 THEN
    RAISE EXCEPTION 'FK_INVALID_INPUT: maximum 10 groups per launch';
  END IF;

  -- Compute deadline
  v_deadline_at := clock_timestamp() + (COALESCE(p_duration_seconds, v_case.duration_seconds) * interval '1 second');

  -- Step 7: update case to launched
  UPDATE public.cases
  SET state = 'launched',
      posted_at = clock_timestamp(),
      deadline_at = v_deadline_at,
      duration_seconds = COALESCE(p_duration_seconds, v_case.duration_seconds)
  WHERE id = p_case_id;

  -- Steps 8–11: create investigations + member snapshots for each group
  FOREACH v_group_id IN ARRAY p_group_ids LOOP
    -- Verify actor is a member of this group
    IF NOT private.is_group_member(v_group_id) THEN
      RAISE EXCEPTION 'FK_FORBIDDEN: actor is not a member of group %', v_group_id;
    END IF;

    -- Create investigation
    INSERT INTO public.investigations (case_id, group_id, status, created_at)
    VALUES (p_case_id, v_group_id, 'active', clock_timestamp())
    RETURNING investigation_id INTO v_investigation_id;

    -- Count detectives: group members excluding poster, active + onboarded + not suspended
    -- Blocker 10: must exclude suspended and non-onboarded members from snapshot
    SELECT count(*) INTO v_detective_count
    FROM public.group_members gm
    JOIN public.profiles p ON p.id = gm.player_id
    WHERE gm.group_id = v_group_id
      AND gm.player_id != v_actor_id
      AND p.is_active = true
      AND p.is_suspended = false
      AND p.onboarding_complete = true;

    IF v_detective_count = 0 THEN
      RAISE EXCEPTION 'FK_INVALID_INPUT: no eligible detectives in group % after excluding poster', v_group_id;
    END IF;

    -- Step 11: snapshot members (exclude poster; only active, onboarded, non-suspended)
    FOR v_member IN
      SELECT gm.player_id, p.display_name, p.avatar_color, p.avatar_media_object_id
      FROM public.group_members gm
      JOIN public.profiles p ON p.id = gm.player_id
      WHERE gm.group_id  = v_group_id
        AND gm.player_id != v_actor_id
        AND p.is_active  = true
        AND p.is_suspended = false
        AND p.onboarding_complete = true
    LOOP
      INSERT INTO public.investigation_members (
        investigation_id, player_id,
        snapshot_display_name, snapshot_avatar_color, snapshot_avatar_media_object_id,
        eligibility_status, added_at
      ) VALUES (
        v_investigation_id, v_member.player_id,
        v_member.display_name, v_member.avatar_color, v_member.avatar_media_object_id,
        'eligible', clock_timestamp()
      );
    END LOOP;
  END LOOP;
END;
$$;
ALTER FUNCTION public.launch_case(uuid, uuid, uuid[], integer) OWNER TO forkensics_executor;


-- =============================================================================
-- PHASE 20 — GRANTS AND PRIVILEGE HARDENING
-- =============================================================================

-- ---- Schema USAGE ----
GRANT USAGE ON SCHEMA private TO authenticated, forkensics_rls_helper, forkensics_executor;

-- ---- RLS helper function grants ----
REVOKE ALL ON FUNCTION private.auth_uid()                              FROM PUBLIC;
REVOKE ALL ON FUNCTION private.normalize_answer(text)                  FROM PUBLIC;
REVOKE ALL ON FUNCTION private.is_group_member(uuid)                   FROM PUBLIC;
REVOKE ALL ON FUNCTION private.is_group_member_with(uuid)              FROM PUBLIC;
REVOKE ALL ON FUNCTION private.is_case_member(uuid)                    FROM PUBLIC;
REVOKE ALL ON FUNCTION private.is_investigation_member(uuid)           FROM PUBLIC;
REVOKE ALL ON FUNCTION private.is_case_poster(uuid)                    FROM PUBLIC;
REVOKE ALL ON FUNCTION private.is_case_revealed(uuid)                  FROM PUBLIC;
REVOKE ALL ON FUNCTION private.is_investigation_eligible(uuid)         FROM PUBLIC;
REVOKE ALL ON FUNCTION private.is_case_poster_for_investigation(uuid)  FROM PUBLIC;
REVOKE ALL ON FUNCTION private.caller_has_guessed(uuid)                FROM PUBLIC;
REVOKE ALL ON FUNCTION private.has_block_with_poster(uuid)             FROM PUBLIC;
REVOKE ALL ON FUNCTION private.can_view_case(uuid)                     FROM PUBLIC;
REVOKE ALL ON FUNCTION private.can_viewer_access_case(uuid, uuid)      FROM PUBLIC;

GRANT EXECUTE ON FUNCTION private.auth_uid()                             TO authenticated;
GRANT EXECUTE ON FUNCTION private.normalize_answer(text)                 TO authenticated;
GRANT EXECUTE ON FUNCTION private.is_group_member(uuid)                  TO authenticated;
GRANT EXECUTE ON FUNCTION private.is_group_member_with(uuid)             TO authenticated;
GRANT EXECUTE ON FUNCTION private.is_case_member(uuid)                   TO authenticated;
GRANT EXECUTE ON FUNCTION private.is_investigation_member(uuid)          TO authenticated;
GRANT EXECUTE ON FUNCTION private.is_case_poster(uuid)                   TO authenticated;
GRANT EXECUTE ON FUNCTION private.is_case_revealed(uuid)                 TO authenticated;
GRANT EXECUTE ON FUNCTION private.is_investigation_eligible(uuid)        TO authenticated;
GRANT EXECUTE ON FUNCTION private.is_case_poster_for_investigation(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION private.caller_has_guessed(uuid)               TO authenticated;
GRANT EXECUTE ON FUNCTION private.has_block_with_poster(uuid)            TO authenticated;

-- can_view_case: authenticated (RLS), service_role (service path), forkensics_executor (SECURITY DEFINER)
GRANT EXECUTE ON FUNCTION private.can_view_case(uuid)                    TO authenticated;
GRANT EXECUTE ON FUNCTION private.can_view_case(uuid)                    TO service_role;
GRANT EXECUTE ON FUNCTION private.can_view_case(uuid)                    TO forkensics_executor;

-- can_viewer_access_case: service_role and forkensics_executor only; NOT authenticated
GRANT EXECUTE ON FUNCTION private.can_viewer_access_case(uuid, uuid)     TO service_role;
GRANT EXECUTE ON FUNCTION private.can_viewer_access_case(uuid, uuid)     TO forkensics_executor;

-- Helpers called by forkensics_executor-owned SECURITY DEFINER functions
GRANT EXECUTE ON FUNCTION private.is_group_member(uuid)      TO forkensics_executor;
GRANT EXECUTE ON FUNCTION private.has_block_with_poster(uuid) TO forkensics_executor;
GRANT EXECUTE ON FUNCTION private.is_case_poster(uuid)        TO forkensics_executor;
GRANT EXECUTE ON FUNCTION private.is_case_revealed(uuid)      TO forkensics_executor;

-- ---- Table grants ----
GRANT SELECT ON public.cases                  TO authenticated, forkensics_rls_helper;
GRANT UPDATE (state, media_object_id, posted_at, deadline_at, locked_at,
              revealed_at, cancelled_at, cancellation_reason, duration_seconds,
              public_city_display, moderator_removed_at, moderator_removal_action_id)
              ON public.cases                 TO forkensics_executor;

GRANT SELECT ON public.investigations         TO authenticated, forkensics_rls_helper;
GRANT SELECT, INSERT, UPDATE, DELETE
  ON public.investigations                    TO forkensics_executor;

GRANT SELECT ON public.investigation_members  TO authenticated, forkensics_rls_helper;
GRANT SELECT, INSERT, UPDATE
  ON public.investigation_members             TO forkensics_executor;

-- Harden guess_attempts: revoke direct INSERT from authenticated; only executor may INSERT
REVOKE INSERT ON public.guess_attempts FROM authenticated, anon, PUBLIC;
GRANT  INSERT ON public.guess_attempts TO forkensics_executor;
GRANT  SELECT ON public.guess_attempts TO authenticated;

-- ---- Authenticated-callable service functions ----
REVOKE ALL ON FUNCTION public.launch_case(uuid, uuid, uuid[], integer)     FROM PUBLIC;
REVOKE ALL ON FUNCTION public.submit_guess(uuid, uuid, text, text, text, timestamptz) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.cancel_case(uuid, text)                       FROM PUBLIC;
REVOKE ALL ON FUNCTION public.cancel_investigation(uuid, text)              FROM PUBLIC;
REVOKE ALL ON FUNCTION public.reveal_case(uuid)                             FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.launch_case(uuid, uuid, uuid[], integer)     TO authenticated;
GRANT EXECUTE ON FUNCTION public.submit_guess(uuid, uuid, text, text, text, timestamptz) TO authenticated;
GRANT EXECUTE ON FUNCTION public.cancel_case(uuid, text)                       TO authenticated;
GRANT EXECUTE ON FUNCTION public.cancel_investigation(uuid, text)              TO authenticated;
GRANT EXECUTE ON FUNCTION public.reveal_case(uuid)                             TO authenticated;

-- ---- Service-role-only functions ----
REVOKE ALL ON FUNCTION public.lock_case(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.lock_case(uuid) TO service_role;

REVOKE ALL ON FUNCTION private.reveal_case_service(uuid)            FROM PUBLIC;
-- No direct grant to service_role for internal function; accessed via wrapper.

REVOKE ALL ON FUNCTION public.reveal_case_service_wrapper(uuid)     FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.reveal_case_service_wrapper(uuid) TO service_role;

-- reserve_upload_session: drop and recreate with restored grant (V2 function; exact signature)
-- Grant restoration for V2-dropped-and-recreated function:
REVOKE ALL ON FUNCTION public.reserve_upload_session(uuid, uuid, text, text, bigint, timestamptz) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.reserve_upload_session(uuid, uuid, text, text, bigint, timestamptz) TO service_role;

-- remove_content / remove_media: service_role only; NOT authenticated
REVOKE ALL ON FUNCTION public.remove_content(text, uuid, uuid, uuid, text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.remove_content(text, uuid, uuid, uuid, text) TO service_role;

REVOKE ALL ON FUNCTION public.remove_media(uuid, uuid, uuid, text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.remove_media(uuid, uuid, uuid, text) TO service_role;

-- ---- current_score_events VIEW (security_invoker — NO RLS policy on view itself) ----
DROP VIEW IF EXISTS public.current_score_events;
CREATE VIEW public.current_score_events
  WITH (security_invoker = true) AS
SELECT se.*
FROM public.score_events se
JOIN public.score_runs sr ON sr.id = se.score_run_id
WHERE sr.revision_number = (
  SELECT max(sr2.revision_number)
  FROM public.score_runs sr2
  WHERE sr2.investigation_id = sr.investigation_id
);

GRANT SELECT ON public.current_score_events TO authenticated;

-- ---- Grant report_content to authenticated (4-arg signature) ----
REVOKE ALL ON FUNCTION public.report_content(text, uuid, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.report_content(text, uuid, text, text) TO authenticated;

-- ---- Grant get_media_serve_authorization to service_role ----
REVOKE ALL ON FUNCTION public.get_media_serve_authorization(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_media_serve_authorization(uuid, uuid) TO service_role;

-- ---- Grant approve_photo / reject_photo to service_role ----
REVOKE ALL ON FUNCTION public.approve_photo(uuid, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.approve_photo(uuid, uuid, text) TO service_role;
REVOKE ALL ON FUNCTION public.reject_photo(uuid, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.reject_photo(uuid, uuid, text) TO service_role;

-- =============================================================================
-- PHASE 20B — UPDATE V3 FUNCTIONS WITH STALE BODIES
-- All V3 functions that reference challenges/challenge_id/challenge_secrets/
-- challenge_answer_aliases are recreated here with V4 names.
-- Blocker 2: these functions will fail at runtime if not updated.
-- =============================================================================

-- ---- 20B.1 check_text_content_trigger — V4 fail-closed body (B5 cement) ----
-- Same body as Phase 2B.1; repeated here so Phase 20B is authoritative.
CREATE OR REPLACE FUNCTION private.check_text_content_trigger()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_col  text;
  v_text text;
BEGIN
  IF TG_NARGS <> 1 THEN
    RAISE EXCEPTION
      'check_text_content_trigger: expected 1 argument (column name), got %', TG_NARGS;
  END IF;
  v_col := TG_ARGV[0];
  IF NOT (
       TG_TABLE_SCHEMA = 'public'
    AND (
         (TG_TABLE_NAME = 'comments'             AND v_col = 'text')
      OR (TG_TABLE_NAME = 'clues'                AND v_col = 'text')
      OR (TG_TABLE_NAME = 'profiles'             AND v_col = 'display_name')
      OR (TG_TABLE_NAME = 'groups'               AND v_col = 'name')
      OR (TG_TABLE_NAME = 'cases'                AND v_col = 'public_city_display')
      OR (TG_TABLE_NAME = 'case_secrets'         AND v_col IN ('display_dish','display_restaurant','story'))
      OR (TG_TABLE_NAME = 'case_answer_aliases'  AND v_col = 'display_value')
    )
  ) THEN
    RAISE EXCEPTION
      'check_text_content_trigger: unauthorized pairing schema=% table=% col=%',
      TG_TABLE_SCHEMA, TG_TABLE_NAME, v_col;
  END IF;
  IF NOT (to_jsonb(NEW) ? v_col) THEN
    RAISE EXCEPTION
      'check_text_content_trigger: column % not found on table %.%',
      v_col, TG_TABLE_SCHEMA, TG_TABLE_NAME;
  END IF;
  v_text := to_jsonb(NEW) ->> v_col;
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
ALTER FUNCTION private.check_text_content_trigger() OWNER TO forkensics_executor;

-- Re-attach triggers with correct column-name arguments (B5)
DROP TRIGGER IF EXISTS challenge_city_filter    ON public.cases;
DROP TRIGGER IF EXISTS case_city_filter         ON public.cases;
CREATE OR REPLACE TRIGGER case_city_filter
  BEFORE INSERT OR UPDATE ON public.cases FOR EACH ROW
  EXECUTE FUNCTION private.check_text_content_trigger('public_city_display');

DROP TRIGGER IF EXISTS secret_dish_filter       ON public.case_secrets;
DROP TRIGGER IF EXISTS secret_restaurant_filter ON public.case_secrets;
DROP TRIGGER IF EXISTS secret_story_filter      ON public.case_secrets;
CREATE OR REPLACE TRIGGER secret_dish_filter
  BEFORE INSERT OR UPDATE ON public.case_secrets FOR EACH ROW
  EXECUTE FUNCTION private.check_text_content_trigger('display_dish');
CREATE OR REPLACE TRIGGER secret_restaurant_filter
  BEFORE INSERT OR UPDATE ON public.case_secrets FOR EACH ROW
  EXECUTE FUNCTION private.check_text_content_trigger('display_restaurant');
CREATE OR REPLACE TRIGGER secret_story_filter
  BEFORE INSERT OR UPDATE ON public.case_secrets FOR EACH ROW
  EXECUTE FUNCTION private.check_text_content_trigger('story');

DROP TRIGGER IF EXISTS alias_display_value_filter ON public.case_answer_aliases;
CREATE OR REPLACE TRIGGER alias_display_value_filter
  BEFORE INSERT OR UPDATE ON public.case_answer_aliases FOR EACH ROW
  EXECUTE FUNCTION private.check_text_content_trigger('display_value');

-- Re-attach forge-protection triggers to renamed tables
DROP TRIGGER IF EXISTS force_challenge_removal_null ON public.cases;
DROP TRIGGER IF EXISTS force_case_removal_null      ON public.cases;
CREATE TRIGGER force_case_removal_null
  BEFORE INSERT ON public.cases FOR EACH ROW
  EXECUTE FUNCTION private.force_removal_fields_null();

DROP TRIGGER IF EXISTS restrict_challenge_removal_fields ON public.cases;
DROP TRIGGER IF EXISTS restrict_case_removal_fields      ON public.cases;
CREATE TRIGGER restrict_case_removal_fields
  BEFORE UPDATE ON public.cases FOR EACH ROW
  EXECUTE FUNCTION private.restrict_moderation_field_updates();


-- ---- 20B.2 public.apply_correction — V4 version ----
-- V4 changes: case_id instead of challenge_id; loops all active investigations;
-- uses investigation_members instead of eligible_participants; includes investigation_id.
DROP FUNCTION IF EXISTS public.apply_correction(
  uuid, text, text, text, uuid, text
);
CREATE OR REPLACE FUNCTION public.apply_correction(
  p_case_id           uuid,
  p_action            text,   -- 'answer_changed' | 'alias_added' | 'alias_removed'
  p_target_field      text,   -- 'dish' | 'restaurant'
  p_new_display_value text,   -- new display value; NULL for alias_removed
  p_alias_id          uuid,   -- for alias_removed; NULL otherwise
  p_reason            text
)
RETURNS uuid  -- the first score_run_id created (one per investigation)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_case              record;
  v_secrets           record;
  v_alias             record;
  v_inv               record;
  v_next_revision     integer;
  v_score_run_id      uuid;
  v_first_run_id      uuid := NULL;
  v_correction_id     uuid;
  v_old_display       text;
  v_old_normalized    text;
  v_new_normalized    text;
  v_audit_old_display    text;
  v_audit_old_normalized text;
  v_audit_new_display    text;
  v_audit_new_normalized text;
  v_eligible_count    integer;
  v_attempt           record;
  v_norm_dish         text;
  v_norm_restaurant   text;
  v_norm_canonical_dish        text;
  v_norm_canonical_restaurant  text;
  v_what_correct      boolean;
  v_where_correct     boolean;
BEGIN
  -- Suspension guard (per Step 24.1 §10.23)
  IF EXISTS (SELECT 1 FROM public.profiles WHERE id = private.auth_uid() AND is_suspended = true) THEN
    RAISE EXCEPTION 'FK_SUSPENDED';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.profiles WHERE id = private.auth_uid() AND is_active = true
  ) THEN RAISE EXCEPTION 'FK_FORBIDDEN: inactive account'; END IF;

  -- Lock case
  SELECT * INTO v_case FROM public.cases WHERE id = p_case_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'FK_NOT_FOUND: case not found'; END IF;

  IF v_case.state != 'revealed' THEN
    RAISE EXCEPTION 'FK_WRONG_STATE: corrections only allowed on revealed cases';
  END IF;

  -- Poster OR any investigation group-owner may apply corrections
  IF v_case.poster_id != private.auth_uid() AND NOT EXISTS (
    SELECT 1 FROM public.investigations i
    JOIN public.group_members gm ON gm.group_id = i.group_id
    WHERE i.case_id = p_case_id AND gm.player_id = private.auth_uid() AND gm.role = 'owner'
  ) THEN
    RAISE EXCEPTION 'FK_FORBIDDEN: only poster or group owner can apply corrections';
  END IF;

  -- Validate action, field, reason
  IF p_action NOT IN ('answer_changed','alias_added','alias_removed') THEN
    RAISE EXCEPTION 'FK_INVALID_INPUT: invalid action: %', p_action;
  END IF;
  IF p_target_field NOT IN ('dish','restaurant') THEN
    RAISE EXCEPTION 'FK_INVALID_INPUT: invalid target_field: %', p_target_field;
  END IF;
  IF p_reason IS NULL OR length(trim(p_reason)) < 1 OR length(p_reason) > 500 THEN
    RAISE EXCEPTION 'FK_INVALID_INPUT: reason must be 1–500 characters';
  END IF;
  IF p_action IN ('answer_changed','alias_added') AND p_alias_id IS NOT NULL THEN
    RAISE EXCEPTION 'FK_INVALID_INPUT: alias_id must be NULL for action: %', p_action;
  END IF;
  IF p_action = 'alias_removed' AND p_new_display_value IS NOT NULL THEN
    RAISE EXCEPTION 'FK_INVALID_INPUT: new_display_value must be NULL for alias_removed';
  END IF;

  IF p_action IN ('answer_changed','alias_added') THEN
    IF p_new_display_value IS NULL OR length(trim(p_new_display_value)) = 0 THEN
      RAISE EXCEPTION 'FK_INVALID_INPUT: new_display_value required';
    END IF;
    IF length(p_new_display_value) > 200 THEN
      RAISE EXCEPTION 'FK_INVALID_INPUT: display value must be ≤200 characters';
    END IF;
    v_new_normalized := private.normalize_answer(p_new_display_value);
    IF length(v_new_normalized) = 0 THEN
      RAISE EXCEPTION 'FK_INVALID_INPUT: normalized value is empty';
    END IF;
  END IF;

  IF p_action = 'alias_removed' THEN
    IF p_alias_id IS NULL THEN
      RAISE EXCEPTION 'FK_INVALID_INPUT: alias_id required for alias_removed';
    END IF;
    SELECT * INTO v_alias FROM public.case_answer_aliases
    WHERE id = p_alias_id AND case_id = p_case_id AND field = p_target_field AND is_active = true
    FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'FK_NOT_FOUND: alias not found or already inactive';
    END IF;
  END IF;

  IF p_action = 'alias_added' THEN
    IF EXISTS (
      SELECT 1 FROM public.case_answer_aliases
      WHERE case_id = p_case_id AND field = p_target_field
        AND is_active = true AND normalized_value = v_new_normalized
    ) THEN
      RAISE EXCEPTION 'FK_CONFLICT: active alias with this normalized value already exists';
    END IF;
  END IF;

  -- Load secrets + audit values
  SELECT * INTO v_secrets FROM public.case_secrets WHERE case_id = p_case_id;

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
  ELSE -- answer_changed
    v_audit_old_display    := v_old_display;
    v_audit_old_normalized := v_old_normalized;
    v_audit_new_display    := p_new_display_value;
    v_audit_new_normalized := v_new_normalized;
  END IF;

  -- Apply the correction
  IF p_action = 'answer_changed' THEN
    IF p_target_field = 'dish' THEN
      UPDATE public.case_secrets
      SET display_dish = p_new_display_value, canonical_dish = v_new_normalized
      WHERE case_id = p_case_id;
    ELSE
      UPDATE public.case_secrets
      SET display_restaurant = p_new_display_value, canonical_restaurant = v_new_normalized
      WHERE case_id = p_case_id;
    END IF;
  ELSIF p_action = 'alias_added' THEN
    INSERT INTO public.case_answer_aliases (
      case_id, field, display_value, normalized_value, created_by, is_active
    ) VALUES (
      p_case_id, p_target_field, p_new_display_value, v_new_normalized, private.auth_uid(), true
    );
  ELSE -- alias_removed
    UPDATE public.case_answer_aliases SET is_active = false WHERE id = p_alias_id;
  END IF;

  -- Insert correction audit record
  INSERT INTO public.correction_events (
    case_id, corrected_by, action, target_field, alias_id,
    old_display_value, new_display_value, old_normalized_value, new_normalized_value, reason
  ) VALUES (
    p_case_id, private.auth_uid(), p_action, p_target_field, p_alias_id,
    v_audit_old_display, v_audit_new_display,
    v_audit_old_normalized, v_audit_new_normalized, p_reason
  ) RETURNING id INTO v_correction_id;

  -- Re-read secrets after update
  SELECT * INTO v_secrets FROM public.case_secrets WHERE case_id = p_case_id;
  -- Blocker 6A: normalize canonical answers for correct comparison
  v_norm_canonical_dish       := private.normalize_answer(v_secrets.canonical_dish);
  v_norm_canonical_restaurant := private.normalize_answer(v_secrets.canonical_restaurant);

  -- Re-score each investigation for this case
  FOR v_inv IN
    SELECT investigation_id FROM public.investigations
    WHERE case_id = p_case_id AND status = 'active'
  LOOP
    SELECT COALESCE(MAX(revision_number), 0) + 1 INTO v_next_revision
    FROM public.score_runs WHERE investigation_id = v_inv.investigation_id;

    SELECT count(*) INTO v_eligible_count
    FROM public.investigation_members
    WHERE investigation_id = v_inv.investigation_id AND eligibility_status = 'eligible';

    INSERT INTO public.score_runs (
      case_id, investigation_id, revision_number, rules_version_id,
      effective_eligible_count, triggering_correction_id
    ) VALUES (
      p_case_id, v_inv.investigation_id, v_next_revision, v_case.rules_version_id,
      v_eligible_count, v_correction_id
    ) RETURNING id INTO v_score_run_id;

    IF v_first_run_id IS NULL THEN v_first_run_id := v_score_run_id; END IF;

    CREATE TEMP TABLE tmp_fc (
      player_id uuid, race text, ga_id uuid, seq bigint
    ) ON COMMIT DROP;

    FOR v_attempt IN
      SELECT ga.*
      FROM public.guess_attempts ga
      JOIN public.investigation_members im
        ON im.investigation_id = v_inv.investigation_id
       AND im.player_id = ga.player_id
       AND im.eligibility_status = 'eligible'
      WHERE ga.case_id = p_case_id
      ORDER BY ga.receipt_sequence
    LOOP
      IF v_attempt.race = 'what' THEN
        v_norm_dish    := private.normalize_answer(v_attempt.dish_guess);
        v_what_correct := v_norm_dish = v_norm_canonical_dish
          OR EXISTS (
            SELECT 1 FROM public.case_answer_aliases
            WHERE case_id = p_case_id AND field = 'dish'
              AND is_active = true AND normalized_value = v_norm_dish
          );

        INSERT INTO public.guess_judgments (
          score_run_id, guess_attempt_id, player_id, case_id, investigation_id,
          race, rules_version_id, is_correct, is_first_correct_for_player
        ) VALUES (
          v_score_run_id, v_attempt.id, v_attempt.player_id, p_case_id, v_inv.investigation_id,
          'what', v_case.rules_version_id, v_what_correct,
          v_what_correct AND NOT EXISTS (
            SELECT 1 FROM tmp_fc WHERE player_id = v_attempt.player_id AND race = 'what'
          )
        );

        IF v_what_correct AND NOT EXISTS (
          SELECT 1 FROM tmp_fc WHERE player_id = v_attempt.player_id AND race = 'what'
        ) THEN
          INSERT INTO tmp_fc VALUES
            (v_attempt.player_id, 'what', v_attempt.id, v_attempt.receipt_sequence);
        END IF;

      ELSE -- 'where'
        v_norm_restaurant := private.normalize_answer(v_attempt.restaurant_guess);
        v_where_correct   := v_norm_restaurant = v_norm_canonical_restaurant
          OR EXISTS (
            SELECT 1 FROM public.case_answer_aliases
            WHERE case_id = p_case_id AND field = 'restaurant'
              AND is_active = true AND normalized_value = v_norm_restaurant
          );

        INSERT INTO public.guess_judgments (
          score_run_id, guess_attempt_id, player_id, case_id, investigation_id,
          race, rules_version_id, is_correct, is_first_correct_for_player
        ) VALUES (
          v_score_run_id, v_attempt.id, v_attempt.player_id, p_case_id, v_inv.investigation_id,
          'where', v_case.rules_version_id, v_where_correct,
          v_where_correct AND NOT EXISTS (
            SELECT 1 FROM tmp_fc WHERE player_id = v_attempt.player_id AND race = 'where'
          )
        );

        IF v_where_correct AND NOT EXISTS (
          SELECT 1 FROM tmp_fc WHERE player_id = v_attempt.player_id AND race = 'where'
        ) THEN
          INSERT INTO tmp_fc VALUES
            (v_attempt.player_id, 'where', v_attempt.id, v_attempt.receipt_sequence);
        END IF;
      END IF;
    END LOOP;

    -- Insert score_events for this investigation
    WITH what_ranked AS (
      SELECT player_id, row_number() OVER (ORDER BY seq)::integer AS rnk FROM tmp_fc WHERE race = 'what'
    ),
    where_ranked AS (
      SELECT player_id, row_number() OVER (ORDER BY seq)::integer AS rnk FROM tmp_fc WHERE race = 'where'
    )
    INSERT INTO public.score_events (
      score_run_id, case_id, investigation_id, player_id, rules_version_id,
      what_points, where_points, what_rank, where_rank
    )
    SELECT
      v_score_run_id, p_case_id, v_inv.investigation_id, im.player_id, v_case.rules_version_id,
      CASE WHEN wr.rnk  IS NOT NULL THEN GREATEST(1, v_eligible_count - wr.rnk  + 1) ELSE 0 END,
      CASE WHEN whr.rnk IS NOT NULL THEN GREATEST(1, v_eligible_count - whr.rnk + 1) ELSE 0 END,
      wr.rnk, whr.rnk
    FROM public.investigation_members im
    LEFT JOIN what_ranked  wr  ON wr.player_id  = im.player_id
    LEFT JOIN where_ranked whr ON whr.player_id = im.player_id
    WHERE im.investigation_id = v_inv.investigation_id AND im.eligibility_status = 'eligible';

    DROP TABLE IF EXISTS tmp_fc;

    -- Link correction to first score run created
    UPDATE public.correction_events
    SET resulting_score_run_id = v_score_run_id
    WHERE id = v_correction_id
      AND resulting_score_run_id IS NULL;

  END LOOP;

  RETURN v_first_run_id;
END;
$$;
ALTER FUNCTION public.apply_correction(uuid, text, text, text, uuid, text) OWNER TO forkensics_executor;


-- ---- 20B.3 private.prepare_account_deletion — V4 version ----
CREATE OR REPLACE FUNCTION private.prepare_account_deletion(p_profile_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_inv       record;
  v_group     record;
  v_successor uuid;
BEGIN
  -- Idempotency guard
  IF EXISTS (
    SELECT 1 FROM private.deletion_log
    WHERE profile_id = p_profile_id
      AND status IN ('database_prepared', 'auth_deleted', 'complete')
  ) THEN RETURN; END IF;

  INSERT INTO private.deletion_log (profile_id, status, last_attempt_at)
  VALUES (p_profile_id, 'pending', clock_timestamp())
  ON CONFLICT (profile_id) DO UPDATE
    SET status = 'pending', last_attempt_at = clock_timestamp(), error = NULL;

  -- 1. Cancel draft/ready cases (pre-launch states)
  UPDATE public.cases
  SET state = 'cancelled',
      cancelled_at = clock_timestamp(),
      cancellation_reason = 'Account deleted'
  WHERE poster_id = p_profile_id AND state IN ('draft','ready');

  -- 2. Exclude from active investigations in launched/locked cases only (Blocker 7B)
  FOR v_inv IN
    SELECT i.investigation_id, i.case_id
    FROM public.investigations i
    JOIN public.investigation_members im ON im.investigation_id = i.investigation_id
    JOIN public.cases c ON c.id = i.case_id
    WHERE im.player_id = p_profile_id
      AND i.status = 'active'
      AND c.state IN ('launched', 'locked')
  LOOP
    INSERT INTO public.exclusion_events (
      case_id, investigation_id, player_id, reason, excluded_by
    ) VALUES (v_inv.case_id, v_inv.investigation_id, p_profile_id, 'account_deleted', NULL)
    ON CONFLICT (investigation_id, player_id) DO NOTHING;  -- Blocker 7D: correct columns
  END LOOP;

  -- Blocker 7C: update all investigation_members (including historical revealed/cancelled)
  UPDATE public.investigation_members
  SET eligibility_status = 'account_deleted'
  WHERE player_id = p_profile_id;

  -- 3. Transfer or archive owned groups
  FOR v_group IN
    SELECT g.id AS group_id
    FROM public.groups g
    JOIN public.group_members gm ON gm.group_id = g.id
    WHERE gm.player_id = p_profile_id AND gm.role = 'owner' AND g.archived_at IS NULL
  LOOP
    SELECT gm.player_id INTO v_successor
    FROM public.group_members gm
    JOIN public.profiles p ON p.id = gm.player_id
    WHERE gm.group_id = v_group.group_id AND gm.player_id != p_profile_id
      AND p.is_active = true AND p.onboarding_complete = true
    ORDER BY gm.joined_at ASC LIMIT 1;

    IF v_successor IS NOT NULL THEN
      UPDATE public.group_members SET role = 'member'
      WHERE group_id = v_group.group_id AND player_id = p_profile_id;
      UPDATE public.group_members SET role = 'owner'
      WHERE group_id = v_group.group_id AND player_id = v_successor;
    ELSE
      UPDATE public.groups SET archived_at = clock_timestamp() WHERE id = v_group.group_id;
    END IF;
  END LOOP;

  -- 4. Archive + anonymise profile
  INSERT INTO private.profile_archive (
    profile_id, original_display_name, original_avatar_color, original_avatar_media_object_id
  )
  SELECT id, display_name, avatar_color, avatar_media_object_id
  FROM public.profiles WHERE id = p_profile_id
  ON CONFLICT (profile_id) DO NOTHING;

  UPDATE public.profiles
  SET display_name = 'Former Player', avatar_color = 'gray',
      avatar_media_object_id = NULL, is_active = false
  WHERE id = p_profile_id;

  -- 5. Tombstone media objects
  UPDATE public.media_objects SET status = 'deleted' WHERE uploader_id = p_profile_id;

  UPDATE private.deletion_log
  SET status = 'database_prepared', db_prepared_at = clock_timestamp()
  WHERE profile_id = p_profile_id;
END;
$$;
ALTER FUNCTION private.prepare_account_deletion(uuid) OWNER TO forkensics_executor;


-- ---- 20B.4 public.remove_content — V4 version (cases instead of challenges) ----
CREATE OR REPLACE FUNCTION public.remove_content(
  p_target_type  text,
  p_target_id    uuid,
  p_moderator_id uuid,
  p_report_id    uuid,
  p_reason       text
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_case            record;
  v_comment         record;
  v_clue            record;
  v_action_id       uuid;
  v_media_object_id uuid;
  v_sha256          text;
  v_storage_key     text;
  v_report_ids      uuid[];
  v_new_case_state  text;
  v_media           record;  -- B12: for media state check
BEGIN
  -- Validate moderator (existence + active profile per V3 behavioral contract)
  IF NOT EXISTS (SELECT 1 FROM private.moderators WHERE profile_id = p_moderator_id) THEN
    RAISE EXCEPTION 'FK_FORBIDDEN: not a moderator';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = p_moderator_id AND is_active = true) THEN
    RAISE EXCEPTION 'FK_FORBIDDEN: moderator account not active';
  END IF;

  IF p_target_type = 'case' THEN
    -- Lock case
    SELECT id, state, media_object_id, moderator_removed_at, moderator_removal_action_id
    INTO v_case FROM public.cases WHERE id = p_target_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'FK_NOT_FOUND'; END IF;

    -- Idempotency (B12: full V3 contract)
    IF v_case.moderator_removed_at IS NOT NULL THEN
      IF v_case.moderator_removal_action_id IS NULL THEN
        RAISE EXCEPTION 'FK_STATE_INCONSISTENCY: removed but action pointer is NULL';
      END IF;
      WITH locked AS (
        SELECT id FROM public.content_reports
        WHERE status = 'pending' AND (
          (target_type = 'case' AND target_id = p_target_id) OR
          (target_type = 'media_object' AND target_id = v_case.media_object_id)
        ) ORDER BY id FOR UPDATE
      )
      SELECT array_agg(id) INTO v_report_ids FROM locked;
      IF v_report_ids IS NOT NULL THEN
        INSERT INTO private.moderation_action_reports (moderation_action_id, report_id)
        SELECT v_case.moderator_removal_action_id, id FROM unnest(v_report_ids) AS t(id)
        ON CONFLICT ON CONSTRAINT moderation_action_reports_one_resolution DO NOTHING;
        IF EXISTS (
          SELECT 1 FROM private.moderation_action_reports
          WHERE report_id = ANY(v_report_ids)
            AND moderation_action_id != v_case.moderator_removal_action_id
        ) THEN RAISE EXCEPTION 'FK_RESOLUTION_CONFLICT'; END IF;
        UPDATE public.content_reports SET status='actioned',
          reviewed_at=clock_timestamp(), reviewed_by=p_moderator_id
        WHERE id = ANY(v_report_ids);
      END IF;
      RETURN;
    END IF;

    v_media_object_id := v_case.media_object_id;

    -- Lock pending reports (Blocker 8A: WITH locked subquery)
    WITH locked AS (
      SELECT id FROM public.content_reports
      WHERE status = 'pending' AND (
        (target_type = 'case' AND target_id = p_target_id) OR
        (target_type = 'media_object' AND target_id = v_media_object_id)
      ) ORDER BY id FOR UPDATE
    )
    SELECT array_agg(id) INTO v_report_ids FROM locked;
    IF p_report_id IS NOT NULL AND NOT (p_report_id = ANY(COALESCE(v_report_ids,'{}'))) THEN
      RAISE EXCEPTION 'FK_REPORT_TARGET_MISMATCH';
    END IF;

    -- Lock media + validate state (B12: V3 steps 8-9)
    IF v_media_object_id IS NOT NULL THEN
      SELECT id, status INTO v_media
      FROM public.media_objects WHERE id = v_media_object_id FOR UPDATE;
      IF v_media.status NOT IN ('removed','cleaned') THEN
        SELECT sha256_hash, re_encoded_storage_key INTO v_sha256, v_storage_key
        FROM private.media_storage_keys WHERE media_object_id = v_media_object_id;
        IF v_sha256 IS NULL THEN RAISE EXCEPTION 'FK_MEDIA_METADATA_INCOMPLETE'; END IF;
      END IF;
    END IF;

    -- Determine new case state per state matrix
    v_new_case_state := CASE WHEN v_case.state IN ('draft','ready','launched','locked')
      THEN 'cancelled' ELSE v_case.state END;

    INSERT INTO public.moderation_actions (
      moderator_id, action_type, target_type, target_id, report_id, reason
    ) VALUES (p_moderator_id, 'content_removed', 'case', p_target_id, p_report_id, p_reason)
    RETURNING id INTO v_action_id;

    IF v_sha256 IS NOT NULL THEN
      INSERT INTO private.moderation_evidence (
        moderation_action_id, evidence_type, evidence_storage_key, evidence_sha256
      ) VALUES (v_action_id, 'media_metadata', v_storage_key, v_sha256);
    END IF;

    UPDATE public.cases SET
      state = v_new_case_state,
      cancellation_reason = CASE WHEN v_new_case_state = 'cancelled' THEN 'moderation_action' ELSE cancellation_reason END,
      cancelled_at = CASE WHEN v_new_case_state = 'cancelled' THEN clock_timestamp() ELSE cancelled_at END,
      moderator_removed_at = clock_timestamp(),
      moderator_removal_action_id = v_action_id
    WHERE id = p_target_id;

    IF v_media_object_id IS NOT NULL THEN
      UPDATE public.media_objects SET status = 'removed', moderated_at = clock_timestamp()
      WHERE id = v_media_object_id AND status NOT IN ('removed','cleaned');
    END IF;

  ELSIF p_target_type = 'comment' THEN
    SELECT id, text, case_id, moderator_removed_at, moderator_removal_action_id
    INTO v_comment FROM public.comments WHERE id = p_target_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'FK_NOT_FOUND'; END IF;

    IF v_comment.moderator_removed_at IS NOT NULL THEN
      -- B12: NULL pointer + resolution-conflict check
      IF v_comment.moderator_removal_action_id IS NULL THEN
        RAISE EXCEPTION 'FK_STATE_INCONSISTENCY: removed but action pointer is NULL';
      END IF;
      WITH locked AS (
        SELECT id FROM public.content_reports
        WHERE target_type = 'comment' AND target_id = p_target_id AND status = 'pending'
        ORDER BY id FOR UPDATE
      )
      SELECT array_agg(id) INTO v_report_ids FROM locked;
      IF v_report_ids IS NOT NULL THEN
        INSERT INTO private.moderation_action_reports (moderation_action_id, report_id)
        SELECT v_comment.moderator_removal_action_id, id FROM unnest(v_report_ids) AS t(id)
        ON CONFLICT ON CONSTRAINT moderation_action_reports_one_resolution DO NOTHING;
        IF EXISTS (
          SELECT 1 FROM private.moderation_action_reports
          WHERE report_id = ANY(v_report_ids)
            AND moderation_action_id != v_comment.moderator_removal_action_id
        ) THEN RAISE EXCEPTION 'FK_RESOLUTION_CONFLICT'; END IF;
        UPDATE public.content_reports SET status='actioned',
          reviewed_at=clock_timestamp(), reviewed_by=p_moderator_id
        WHERE id = ANY(v_report_ids);
      END IF;
      RETURN;
    END IF;

    -- Blocker 8A: WITH locked subquery
    WITH locked AS (
      SELECT id FROM public.content_reports
      WHERE target_type = 'comment' AND target_id = p_target_id AND status = 'pending'
      ORDER BY id FOR UPDATE
    )
    SELECT array_agg(id) INTO v_report_ids FROM locked;
    IF p_report_id IS NOT NULL AND NOT (p_report_id = ANY(COALESCE(v_report_ids,'{}'))) THEN
      RAISE EXCEPTION 'FK_REPORT_TARGET_MISMATCH';
    END IF;

    INSERT INTO public.moderation_actions (
      moderator_id, action_type, target_type, target_id, report_id, reason
    ) VALUES (p_moderator_id, 'content_removed', 'comment', p_target_id, p_report_id, p_reason)
    RETURNING id INTO v_action_id;

    INSERT INTO private.moderation_evidence (moderation_action_id, evidence_type, evidence_text)
    VALUES (v_action_id, 'comment_text', v_comment.text);

    UPDATE public.comments SET
      text = '[removed by moderator]',
      moderator_removed_at = clock_timestamp(),
      moderator_removal_action_id = v_action_id
    WHERE id = p_target_id;

  ELSIF p_target_type = 'clue' THEN
    SELECT id, text, case_id, moderator_removed_at, moderator_removal_action_id
    INTO v_clue FROM public.clues WHERE id = p_target_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'FK_NOT_FOUND'; END IF;

    IF v_clue.moderator_removed_at IS NOT NULL THEN
      -- B12: NULL pointer + resolution-conflict check
      IF v_clue.moderator_removal_action_id IS NULL THEN
        RAISE EXCEPTION 'FK_STATE_INCONSISTENCY: removed but action pointer is NULL';
      END IF;
      WITH locked AS (
        SELECT id FROM public.content_reports
        WHERE target_type = 'clue' AND target_id = p_target_id AND status = 'pending'
        ORDER BY id FOR UPDATE
      )
      SELECT array_agg(id) INTO v_report_ids FROM locked;
      IF v_report_ids IS NOT NULL THEN
        INSERT INTO private.moderation_action_reports (moderation_action_id, report_id)
        SELECT v_clue.moderator_removal_action_id, id FROM unnest(v_report_ids) AS t(id)
        ON CONFLICT ON CONSTRAINT moderation_action_reports_one_resolution DO NOTHING;
        IF EXISTS (
          SELECT 1 FROM private.moderation_action_reports
          WHERE report_id = ANY(v_report_ids)
            AND moderation_action_id != v_clue.moderator_removal_action_id
        ) THEN RAISE EXCEPTION 'FK_RESOLUTION_CONFLICT'; END IF;
        UPDATE public.content_reports SET status='actioned',
          reviewed_at=clock_timestamp(), reviewed_by=p_moderator_id
        WHERE id = ANY(v_report_ids);
      END IF;
      RETURN;
    END IF;

    -- Blocker 8A: WITH locked subquery
    WITH locked AS (
      SELECT id FROM public.content_reports
      WHERE target_type = 'clue' AND target_id = p_target_id AND status = 'pending'
      ORDER BY id FOR UPDATE
    )
    SELECT array_agg(id) INTO v_report_ids FROM locked;
    IF p_report_id IS NOT NULL AND NOT (p_report_id = ANY(COALESCE(v_report_ids,'{}'))) THEN
      RAISE EXCEPTION 'FK_REPORT_TARGET_MISMATCH';
    END IF;

    INSERT INTO public.moderation_actions (
      moderator_id, action_type, target_type, target_id, report_id, reason
    ) VALUES (p_moderator_id, 'content_removed', 'clue', p_target_id, p_report_id, p_reason)
    RETURNING id INTO v_action_id;

    INSERT INTO private.moderation_evidence (moderation_action_id, evidence_type, evidence_text)
    VALUES (v_action_id, 'clue_text', v_clue.text);

    UPDATE public.clues SET
      moderator_removed_at = clock_timestamp(),
      moderator_removal_action_id = v_action_id
    WHERE id = p_target_id;

  ELSE
    RAISE EXCEPTION 'FK_INVALID_INPUT: invalid target_type %', p_target_type;
  END IF;

  -- Resolve all locked reports
  INSERT INTO private.moderation_action_reports (moderation_action_id, report_id)
  SELECT v_action_id, unnest(v_report_ids)
  ON CONFLICT ON CONSTRAINT moderation_action_reports_one_resolution DO NOTHING;

  UPDATE public.content_reports SET status='actioned',
    reviewed_at=clock_timestamp(), reviewed_by=p_moderator_id
  WHERE id = ANY(v_report_ids);
END;
$$;
ALTER FUNCTION public.remove_content(text, uuid, uuid, uuid, text) OWNER TO forkensics_executor;


-- ---- 20B.5 public.remove_media — V4 version (cases instead of challenges) ----
CREATE OR REPLACE FUNCTION public.remove_media(
  p_media_object_id uuid,
  p_moderator_id    uuid,
  p_report_id       uuid,
  p_reason          text
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_case_id     uuid;
  v_case        record;
  v_media       record;  -- B12
  v_action_id   uuid;
  v_sha256      text;
  v_storage_key text;
  v_report_ids  uuid[];
BEGIN
  IF NOT EXISTS (SELECT 1 FROM private.moderators WHERE profile_id = p_moderator_id) THEN
    RAISE EXCEPTION 'FK_FORBIDDEN: not a moderator';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = p_moderator_id AND is_active = true) THEN
    RAISE EXCEPTION 'FK_FORBIDDEN: moderator account not active';
  END IF;

  -- a. Provisional case read (no lock)
  SELECT id INTO v_case_id FROM public.cases WHERE media_object_id = p_media_object_id LIMIT 1;
  IF v_case_id IS NULL THEN RAISE EXCEPTION 'FK_NOT_FOUND'; END IF;

  -- b. Lock case
  SELECT id, state, media_object_id, moderator_removed_at, moderator_removal_action_id
  INTO v_case FROM public.cases WHERE id = v_case_id FOR UPDATE;

  -- Idempotency (B12: full V3 contract)
  IF v_case.moderator_removed_at IS NOT NULL THEN
    IF v_case.moderator_removal_action_id IS NULL THEN
      RAISE EXCEPTION 'FK_STATE_INCONSISTENCY: removed but action pointer is NULL';
    END IF;
    WITH locked AS (
      SELECT id FROM public.content_reports WHERE status = 'pending' AND (
        (target_type = 'media_object' AND target_id = p_media_object_id) OR
        (target_type = 'case' AND category = 'inappropriate_image' AND target_id = v_case_id)
      ) ORDER BY id FOR UPDATE
    )
    SELECT array_agg(id) INTO v_report_ids FROM locked;
    IF v_report_ids IS NOT NULL THEN
      INSERT INTO private.moderation_action_reports (moderation_action_id, report_id)
      SELECT v_case.moderator_removal_action_id, id FROM unnest(v_report_ids) AS t(id)
      ON CONFLICT ON CONSTRAINT moderation_action_reports_one_resolution DO NOTHING;
      IF EXISTS (
        SELECT 1 FROM private.moderation_action_reports
        WHERE report_id = ANY(v_report_ids)
          AND moderation_action_id != v_case.moderator_removal_action_id
      ) THEN RAISE EXCEPTION 'FK_RESOLUTION_CONFLICT'; END IF;
      UPDATE public.content_reports SET status='actioned',
        reviewed_at=clock_timestamp(), reviewed_by=p_moderator_id
      WHERE id = ANY(v_report_ids);
    END IF;
    RETURN;
  END IF;

  -- B12: Re-validate media linkage (V3 step 5)
  IF v_case.media_object_id IS DISTINCT FROM p_media_object_id THEN
    RAISE EXCEPTION 'FK_LINKAGE_CHANGED';
  END IF;

  -- Lock reports
  WITH locked AS (
    SELECT id FROM public.content_reports WHERE status = 'pending' AND (
      (target_type = 'media_object' AND target_id = p_media_object_id) OR
      (target_type = 'case' AND category = 'inappropriate_image' AND target_id = v_case_id)
    ) ORDER BY id FOR UPDATE
  )
  SELECT array_agg(id) INTO v_report_ids FROM locked;
  IF p_report_id IS NOT NULL AND NOT (p_report_id = ANY(COALESCE(v_report_ids,'{}'))) THEN
    RAISE EXCEPTION 'FK_REPORT_TARGET_MISMATCH';
  END IF;

  -- B12: Lock media + verify status='ready' (V3 step 8) + read SHA-256
  SELECT id, status INTO v_media FROM public.media_objects
  WHERE id = p_media_object_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'FK_NOT_FOUND'; END IF;
  IF v_media.status != 'ready' THEN
    RAISE EXCEPTION 'FK_WRONG_STATE: media not ready (status: %)', v_media.status;
  END IF;
  SELECT sha256_hash, re_encoded_storage_key INTO v_sha256, v_storage_key
  FROM private.media_storage_keys WHERE media_object_id = p_media_object_id;
  IF v_sha256 IS NULL THEN RAISE EXCEPTION 'FK_MEDIA_METADATA_INCOMPLETE'; END IF;

  INSERT INTO public.moderation_actions (
    moderator_id, action_type, target_type, target_id, report_id, reason
  ) VALUES (p_moderator_id, 'photo_removed', 'media_object', p_media_object_id, p_report_id, p_reason)
  RETURNING id INTO v_action_id;

  INSERT INTO private.moderation_evidence (
    moderation_action_id, evidence_type, evidence_storage_key, evidence_sha256
  ) VALUES (v_action_id, 'media_metadata', v_storage_key, v_sha256);

  UPDATE public.media_objects SET status = 'removed', moderated_at = clock_timestamp()
  WHERE id = p_media_object_id;

  -- Update case per state matrix (Blocker 8B: add moderator_removed_at)
  UPDATE public.cases SET
    state = CASE WHEN state IN ('draft','ready','launched','locked') THEN 'cancelled' ELSE state END,
    cancellation_reason = CASE WHEN state IN ('draft','ready','launched','locked') THEN 'moderation_action' ELSE cancellation_reason END,
    cancelled_at = CASE WHEN state IN ('draft','ready','launched','locked') THEN clock_timestamp() ELSE cancelled_at END,
    moderator_removed_at = clock_timestamp(),
    moderator_removal_action_id = v_action_id
  WHERE id = v_case_id;

  INSERT INTO private.moderation_action_reports (moderation_action_id, report_id)
  SELECT v_action_id, unnest(v_report_ids)
  ON CONFLICT ON CONSTRAINT moderation_action_reports_one_resolution DO NOTHING;

  UPDATE public.content_reports SET status='actioned',
    reviewed_at=clock_timestamp(), reviewed_by=p_moderator_id
  WHERE id = ANY(v_report_ids);
END;
$$;
ALTER FUNCTION public.remove_media(uuid, uuid, uuid, text) OWNER TO forkensics_executor;


-- ---- 20B.6 public.get_moderation_queue — V4 version ----
-- B2: DROP required; RETURNS TABLE column renamed challenge_id→case_id since V3.
REVOKE ALL ON FUNCTION public.get_moderation_queue() FROM PUBLIC, anon, authenticated, service_role;
DROP FUNCTION IF EXISTS public.get_moderation_queue();
CREATE FUNCTION public.get_moderation_queue()
RETURNS TABLE(queue_type text, item_id uuid, created_at timestamptz,
              target_type text, target_id uuid, category text, case_id uuid)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  -- Pending reports
  SELECT
    'pending_report'::text,
    cr.id,
    cr.created_at,
    cr.target_type,
    cr.target_id,
    cr.category,
    CASE
      WHEN cr.target_type = 'case'         THEN cr.target_id
      WHEN cr.target_type = 'comment'      THEN (SELECT c2.case_id FROM public.comments c2 WHERE c2.id = cr.target_id)
      WHEN cr.target_type = 'clue'         THEN (SELECT cl.case_id FROM public.clues cl WHERE cl.id = cr.target_id)
      WHEN cr.target_type = 'media_object' THEN (SELECT c3.id FROM public.cases c3 WHERE c3.media_object_id = cr.target_id)
      ELSE NULL
    END AS case_id
  FROM public.content_reports cr
  WHERE cr.status = 'pending'

  UNION ALL

  -- Pending review photos
  SELECT
    'pending_review_photo'::text,
    mo.id,
    mo.created_at,
    'media_object'::text,
    mo.id,
    NULL::text,
    (SELECT c4.id FROM public.cases c4 WHERE c4.media_object_id = mo.id LIMIT 1)
  FROM public.media_objects mo
  WHERE mo.status = 'pending_review'

  ORDER BY 3 ASC;  -- order by created_at
$$;
ALTER FUNCTION public.get_moderation_queue() OWNER TO forkensics_executor;


-- ---- 20B.7 public.get_pending_review_media — V4 version ----
-- B2: DROP required; RETURNS TABLE column renamed challenge_id→case_id since V3.
REVOKE ALL ON FUNCTION public.get_pending_review_media(uuid) FROM PUBLIC, anon, authenticated, service_role;
DROP FUNCTION IF EXISTS public.get_pending_review_media(uuid);
CREATE FUNCTION public.get_pending_review_media(p_media_object_id uuid)
RETURNS TABLE(media_object_id uuid, re_encoded_storage_key text,
              case_id uuid, uploader_id uuid, re_encoded_at timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT
    mo.id,
    msk.re_encoded_storage_key,
    c.id,
    mo.uploader_id,
    mo.re_encoded_at
  FROM public.media_objects mo
  JOIN private.media_storage_keys msk ON msk.media_object_id = mo.id
  JOIN public.cases c ON c.media_object_id = mo.id
  WHERE mo.id = p_media_object_id
    AND mo.status = 'pending_review';
$$;
ALTER FUNCTION public.get_pending_review_media(uuid) OWNER TO forkensics_executor;


-- ---- 20B.8 public.get_reported_media — V4 version ----
-- B2+B11: DROP required; RETURNS TABLE column renamed; add UNION ALL branch.
REVOKE ALL ON FUNCTION public.get_reported_media(uuid) FROM PUBLIC, anon, authenticated, service_role;
DROP FUNCTION IF EXISTS public.get_reported_media(uuid);
CREATE FUNCTION public.get_reported_media(p_report_id uuid)
RETURNS TABLE(media_object_id uuid, re_encoded_storage_key text,
              case_id uuid, uploader_id uuid, media_status text,
              report_category text, report_detail text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  -- Branch 1: direct media_object report
  SELECT mo.id, msk.re_encoded_storage_key, c.id, mo.uploader_id,
         mo.status, cr.category, cr.detail
  FROM public.content_reports cr
  JOIN public.media_objects mo ON mo.id = cr.target_id
  JOIN private.media_storage_keys msk ON msk.media_object_id = mo.id
  JOIN public.cases c ON c.media_object_id = mo.id
  WHERE cr.id = p_report_id
    AND cr.target_type = 'media_object'
    AND cr.status = 'pending'
    AND mo.status IN ('ready','pending_review')

  UNION ALL

  -- Branch 2 (B11): case-level inappropriate_image report
  SELECT mo.id, msk.re_encoded_storage_key, c.id, mo.uploader_id,
         mo.status, cr.category, cr.detail
  FROM public.content_reports cr
  JOIN public.cases c ON c.id = cr.target_id
  JOIN public.media_objects mo ON mo.id = c.media_object_id
  JOIN private.media_storage_keys msk ON msk.media_object_id = mo.id
  WHERE cr.id = p_report_id
    AND cr.target_type = 'case'
    AND cr.category = 'inappropriate_image'
    AND cr.status = 'pending'
    AND mo.status IN ('ready','pending_review');
$$;
ALTER FUNCTION public.get_reported_media(uuid) OWNER TO forkensics_executor;


-- ---- 20B.9 public.claim_moderation_media_cleanup — V4 version (Blocker 12) ----
-- public.challenges c → public.cases c; target_type 'challenge' → 'case'
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
              cr.target_type = 'case'
              AND cr.category = 'inappropriate_image'
              AND EXISTS (
                SELECT 1 FROM public.cases c
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
ALTER FUNCTION public.claim_moderation_media_cleanup(int) OWNER TO forkensics_executor;


-- ---- 20B.9 Grant all newly-recreated V3 functions ----
REVOKE ALL ON FUNCTION public.apply_correction(uuid, text, text, text, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.apply_correction(uuid, text, text, text, uuid, text) TO authenticated;

REVOKE ALL ON FUNCTION private.prepare_account_deletion(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.prepare_account_deletion(uuid) TO service_role;

REVOKE ALL ON FUNCTION public.remove_content(text, uuid, uuid, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.remove_content(text, uuid, uuid, uuid, text) TO service_role;

REVOKE ALL ON FUNCTION public.remove_media(uuid, uuid, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.remove_media(uuid, uuid, uuid, text) TO service_role;

REVOKE ALL ON FUNCTION public.get_moderation_queue() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_moderation_queue() TO service_role;

REVOKE ALL ON FUNCTION public.get_pending_review_media(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_pending_review_media(uuid) TO service_role;

REVOKE ALL ON FUNCTION public.get_reported_media(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_reported_media(uuid) TO service_role;


-- ---- 20C — REVOKE postgres temporary role memberships ----
-- Blocker 1: REVOKE CREATE ON SCHEMA (granted in Phase 13C)
REVOKE CREATE ON SCHEMA private FROM forkensics_executor, forkensics_rls_helper;
REVOKE CREATE ON SCHEMA public  FROM forkensics_executor;
-- Restores the post-V3 state where postgres is not a member of executor/helper roles.
REVOKE forkensics_executor   FROM postgres;
REVOKE forkensics_rls_helper FROM postgres;


-- ---- Completion marker ----
DO $done$ BEGIN
  RAISE NOTICE 'V4__case_investigation_schema.sql complete';
END $done$;

COMMIT;
