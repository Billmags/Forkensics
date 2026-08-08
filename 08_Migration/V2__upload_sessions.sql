-- =============================================================================
-- Forkensics — V2 Upload Sessions Migration
-- Source: Step 25 Proposal Rev 7 (Codex-approved SHA-256:
--         00892952ce72552995491dbb96ac5ac6394f1db3ea590a68620fb48349e2abd1)
-- Governance: Generated after APPROVED: Step 25 — V2 Migration: Upload Session Infrastructure
--             by Codex (Rev 7) and Bill (explicit gate, 2026-08-07).
-- V1 freeze:  V1__initial_schema.sql SHA-256:
--             2581412af146acdaaf9a7139c98a208fa4b1fe1a355ee14e043f9117b6f3afc3 — immutable.
-- Failure stop rule: if any statement fails, stop immediately. Do not repair.
--                    Return the PostgreSQL error and migration position for review.
-- Deployment: NOT authorised for deployment until V2_acceptance_tests.sql passes in dev.
-- =============================================================================

BEGIN;

-- =============================================================================
-- SECTION 1 — MIGRATION GUARD
-- Confirm V1 is applied before proceeding.
-- =============================================================================

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'private' AND table_name = 'deletion_log'
  ) THEN
    RAISE EXCEPTION 'V1 migration (private.deletion_log) not found — apply V1 before V2';
  END IF;
END;
$$;


-- =============================================================================
-- SECTION 2 — TABLE DDL: private.upload_sessions
-- =============================================================================

CREATE TABLE IF NOT EXISTS private.upload_sessions (
  -- Identity
  session_id                       uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  upload_token_hash                text        NOT NULL UNIQUE
                                               CONSTRAINT upload_sessions_token_hash_format
                                                 CHECK (upload_token_hash ~ '^[0-9a-f]{64}$'),

  -- Relationships
  challenge_id                     uuid        NOT NULL
                                               REFERENCES public.challenges(id) ON DELETE RESTRICT,
  uploader_id                      uuid        NOT NULL
                                               REFERENCES public.profiles(id)   ON DELETE RESTRICT,

  -- Storage paths (deterministic from session_id; set at creation; immutable)
  original_storage_path            text        NOT NULL,
  display_storage_path             text        NOT NULL,

  -- Upload parameters (declared by client; set at creation; immutable)
  content_type                     text        NOT NULL,
  declared_size_bytes              bigint      NOT NULL,

  -- Session expiry (upload-complete claim window; set at creation)
  expires_at                       timestamptz NOT NULL,

  -- Storage capability (NULL = no URL was ever issued to client;
  --                     non-NULL = actual URL expiry set by activate_upload_session)
  storage_upload_expires_at        timestamptz,

  -- Processing lease (set when transitioning to 'processing')
  processing_lease_expires_at      timestamptz,

  -- State machine
  status                           text        NOT NULL,
  status_changed_at                timestamptz NOT NULL,
  failed_reason                    text,

  -- Finalization outputs (set by finalize_upload_session when reaching 'complete')
  media_object_id                  uuid,
  replaced_media_object_id         uuid,

  -- Post-expiry original-path cleanup tracking (for complete sessions)
  original_path_post_expiry_cleaned boolean    NOT NULL DEFAULT false,

  -- Cleanup claim fields
  cleanup_claim_token              uuid,
  cleanup_claimed_at               timestamptz,
  cleanup_claim_expires_at         timestamptz,
  cleanup_completed_at             timestamptz,

  CONSTRAINT upload_sessions_status_check
    CHECK (status IN ('pending','processing','sanitized','complete','expired','failed','cleaned')),

  CONSTRAINT upload_sessions_content_type_check
    CHECK (content_type IN ('image/jpeg','image/webp')),

  CONSTRAINT upload_sessions_declared_size_check
    CHECK (declared_size_bytes > 0 AND declared_size_bytes <= 10485760),

  CONSTRAINT upload_sessions_failed_reason_format
    CHECK (failed_reason IS NULL OR
           (failed_reason ~ '^FK_[A-Z_]+$' AND length(failed_reason) <= 50))
);


-- =============================================================================
-- SECTION 3 — TABLE DDL: private.deletion_recovery_claims
-- =============================================================================

CREATE TABLE IF NOT EXISTS private.deletion_recovery_claims (
  user_id          uuid        PRIMARY KEY
                               REFERENCES public.profiles(id) ON DELETE RESTRICT,
  scan_type        text        NOT NULL,
  claim_token      uuid        NOT NULL,
  claimed_at       timestamptz NOT NULL,
  claim_expires_at timestamptz NOT NULL,

  CONSTRAINT deletion_recovery_scan_type_check
    CHECK (scan_type IN ('database_prepared', 'auth_deleted'))
);


-- =============================================================================
-- SECTION 4 — MODIFY public.media_objects STATUS CONSTRAINT
-- V1 constraint: ('processing','ready','failed','deleted')
-- V2 adds:       'superseded','pending_review','rejected','removed','cleaned'
-- All existing rows remain valid (old values still in new constraint).
-- DROP + ADD is atomic within the migration transaction.
-- =============================================================================

ALTER TABLE public.media_objects DROP CONSTRAINT media_objects_status_check;
ALTER TABLE public.media_objects ADD CONSTRAINT media_objects_status_check
  CHECK (status IN (
    'processing','ready','failed','deleted',
    'superseded','pending_review','rejected','removed','cleaned'
  ));


-- =============================================================================
-- SECTION 5 — ADD SHA-256 COLUMN TO private.media_storage_keys (V2a — nullable)
-- V2b (separate future migration) will add NOT NULL after hash backfill.
-- =============================================================================

ALTER TABLE private.media_storage_keys
  ADD COLUMN IF NOT EXISTS sha256_hash text
    CONSTRAINT msk_sha256_format CHECK (sha256_hash ~ '^[0-9a-f]{64}$');


-- =============================================================================
-- SECTION 6 — INDEXES
-- =============================================================================

-- One active session per challenge (database-level enforcement)
CREATE UNIQUE INDEX IF NOT EXISTS upload_sessions_one_active_per_challenge
  ON private.upload_sessions (challenge_id)
  WHERE status IN ('pending', 'processing', 'sanitized');

-- For deletion quiesce: find all sessions for a given uploader
CREATE INDEX IF NOT EXISTS idx_upload_sessions_uploader_status
  ON private.upload_sessions (uploader_id, status);

-- For cleanup worker: find stale/claimable sessions efficiently
CREATE INDEX IF NOT EXISTS idx_upload_sessions_cleanup_candidates
  ON private.upload_sessions (status, storage_upload_expires_at)
  WHERE status IN ('pending', 'processing', 'sanitized', 'expired', 'failed');

-- For capability expiry check: non-NULL issued capabilities by uploader
CREATE INDEX IF NOT EXISTS idx_upload_sessions_capability_expiry
  ON private.upload_sessions (uploader_id, storage_upload_expires_at)
  WHERE storage_upload_expires_at IS NOT NULL AND status != 'cleaned';

-- For Part 3 cleanup: complete sessions awaiting original-path delete
CREATE INDEX IF NOT EXISTS idx_upload_sessions_expiry_cleanup
  ON private.upload_sessions (storage_upload_expires_at)
  WHERE status = 'complete' AND original_path_post_expiry_cleaned = false;

-- For deletion recovery worker: by scan type and claim expiry
CREATE INDEX IF NOT EXISTS idx_deletion_recovery_scan_type
  ON private.deletion_recovery_claims (scan_type, claim_expires_at);


-- =============================================================================
-- SECTION 7 — TRIGGER FUNCTIONS
-- Both are SECURITY INVOKER (default), SET search_path = ''.
-- Ownership transferred to forkensics_executor in Section 10.
-- =============================================================================

-- 7.1 Reject draft→active while an active upload session exists
CREATE OR REPLACE FUNCTION private.check_activation_no_active_upload()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  IF OLD.state = 'draft' AND NEW.state = 'active' THEN
    IF EXISTS (
      SELECT 1 FROM private.upload_sessions
      WHERE challenge_id = NEW.id
        AND status IN ('pending', 'processing', 'sanitized')
    ) THEN
      RAISE EXCEPTION 'challenge cannot be activated while an active upload session exists (status: pending, processing, or sanitized)';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

-- 7.2 Reject draft→active if media_object_id is NULL or not 'ready' (defense-in-depth)
-- Correctly rejects pending_review, rejected, removed, superseded, cleaned, and NULL.
CREATE OR REPLACE FUNCTION private.check_activation_media_ready()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  IF OLD.state = 'draft' AND NEW.state = 'active' THEN
    IF NEW.media_object_id IS NULL OR NOT EXISTS (
      SELECT 1 FROM public.media_objects
      WHERE id = NEW.media_object_id AND status = 'ready'
    ) THEN
      RAISE EXCEPTION 'challenge media object must be present and have status ''ready'' before activation';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;


-- =============================================================================
-- SECTION 8 — TRIGGER ATTACHMENTS
-- Fires alphabetically: challenge_v2_media_ready_on_activate,
--                       challenge_v2_no_active_upload_on_activate
-- (after V1's challenge_protect_fields, which bypasses for forkensics_executor)
-- =============================================================================

CREATE OR REPLACE TRIGGER challenge_v2_no_active_upload_on_activate
  BEFORE UPDATE ON public.challenges
  FOR EACH ROW EXECUTE PROCEDURE private.check_activation_no_active_upload();

CREATE OR REPLACE TRIGGER challenge_v2_media_ready_on_activate
  BEFORE UPDATE ON public.challenges
  FOR EACH ROW EXECUTE PROCEDURE private.check_activation_media_ready();


-- =============================================================================
-- SECTION 9 — PUBLIC SECURITY DEFINER FUNCTIONS (27 total)
-- All: public schema, SECURITY DEFINER, SET search_path = '', fully qualified refs.
-- Ownership and EXECUTE grants applied in Section 10.
-- =============================================================================

-- --------------------------------------------------------------------
-- 9.1  reserve_upload_session  (Section 5.1)
-- --------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.reserve_upload_session(
  p_challenge_id      uuid,
  p_uploader_id       uuid,
  p_token_hash        text,
  p_content_type      text,
  p_declared_size     bigint,
  p_client_expires_at timestamptz
)
RETURNS TABLE (session_id uuid, original_storage_path text, display_storage_path text)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_challenge    record;
  v_session_id   uuid := gen_random_uuid();
  v_orig_path    text;
  v_disp_path    text;
BEGIN
  -- Step 1: Lock the challenge row.
  -- Serializes reservation with any concurrent write to public.challenges,
  -- including the direct row-level UPDATE inside private.prepare_account_deletion.
  SELECT id, poster_id, state
  INTO v_challenge
  FROM public.challenges
  WHERE id = p_challenge_id
  FOR UPDATE;

  -- Step 2: Verify poster identity.
  IF NOT FOUND OR v_challenge.poster_id != p_uploader_id THEN
    RAISE EXCEPTION 'FK_NOT_FOUND';
  END IF;

  -- Step 3: Verify draft state.
  IF v_challenge.state != 'draft' THEN
    RAISE EXCEPTION 'FK_WRONG_STATE';
  END IF;

  -- Step 4: Verify uploader has no active deletion in progress.
  IF EXISTS (
    SELECT 1 FROM private.deletion_log
    WHERE profile_id = p_uploader_id
      AND status IN ('database_prepared', 'auth_deleted')
  ) THEN
    RAISE EXCEPTION 'FK_FORBIDDEN';
  END IF;

  -- Step 5: Construct storage paths (deterministic from challenge_id and session_id).
  v_orig_path := 'challenges/' || p_challenge_id::text || '/originals/' || v_session_id::text;
  v_disp_path := 'challenges/' || p_challenge_id::text || '/displays/'  || v_session_id::text || '.webp';

  -- Step 6: Insert session with NULL storage_upload_expires_at (no capability issued yet).
  -- The partial unique index upload_sessions_one_active_per_challenge prevents two
  -- concurrent active sessions for the same challenge.
  BEGIN
    INSERT INTO private.upload_sessions (
      session_id, upload_token_hash, challenge_id, uploader_id,
      original_storage_path, display_storage_path,
      content_type, declared_size_bytes, expires_at,
      storage_upload_expires_at, status, status_changed_at
    ) VALUES (
      v_session_id, p_token_hash, p_challenge_id, p_uploader_id,
      v_orig_path, v_disp_path,
      p_content_type, p_declared_size, p_client_expires_at,
      NULL, 'pending', now()
    );
  EXCEPTION
    WHEN unique_violation THEN
      -- Either upload_sessions_one_active_per_challenge or upload_token_hash violated.
      RAISE EXCEPTION 'FK_UPLOAD_IN_PROGRESS';
  END;

  RETURN QUERY SELECT v_session_id, v_orig_path, v_disp_path;
END;
$$;


-- --------------------------------------------------------------------
-- 9.2  activate_upload_session  (Section 5.2)
-- --------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.activate_upload_session(
  p_session_id                      uuid,
  p_actual_storage_upload_expires_at timestamptz
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_session record;
BEGIN
  -- Fast-path input validation: reject before acquiring any row lock.
  IF p_actual_storage_upload_expires_at IS NULL
     OR p_actual_storage_upload_expires_at <= clock_timestamp()
  THEN
    RAISE EXCEPTION 'FK_INVALID_INPUT: storage_upload_expires_at must be a non-NULL future timestamp';
  END IF;

  -- Enforce approved 5-minute signing window (30 seconds clock tolerance documented).
  IF p_actual_storage_upload_expires_at
       > clock_timestamp() + interval '5 minutes' + interval '30 seconds'
  THEN
    RAISE EXCEPTION 'FK_INVALID_INPUT: capability expiry exceeds approved 5-minute signing window (max 5m30s from clock_timestamp())';
  END IF;

  -- Lock the session row before validating its state.
  SELECT session_id, status, expires_at, storage_upload_expires_at
  INTO v_session
  FROM private.upload_sessions
  WHERE session_id = p_session_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'FK_WRONG_STATE: session not found';
  END IF;

  -- Verify the session claim window has not expired.
  IF v_session.expires_at <= clock_timestamp() THEN
    RAISE EXCEPTION 'FK_WRONG_STATE: session claim window has expired';
  END IF;

  -- Verify session is still pending and has not already been activated.
  IF v_session.status != 'pending' OR v_session.storage_upload_expires_at IS NOT NULL THEN
    RAISE EXCEPTION 'FK_WRONG_STATE: session is not pending with NULL expiry (already activated, failed, or not found)';
  END IF;

  -- Verify capability expiry does not outlast the session window.
  IF p_actual_storage_upload_expires_at > v_session.expires_at THEN
    RAISE EXCEPTION 'FK_INVALID_INPUT: capability expiry exceeds session expiry';
  END IF;

  -- Post-lock expiry recheck: lock acquisition may have blocked; verify still future.
  IF p_actual_storage_upload_expires_at <= clock_timestamp() THEN
    RAISE EXCEPTION 'FK_INVALID_INPUT: storage_upload_expires_at became stale during lock acquisition';
  END IF;

  UPDATE private.upload_sessions
  SET storage_upload_expires_at = p_actual_storage_upload_expires_at
  WHERE session_id = p_session_id;
END;
$$;


-- --------------------------------------------------------------------
-- 9.3  resolve_upload_session  (Section 5.3)
-- --------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.resolve_upload_session(
  p_token_hash  text,
  p_uploader_id uuid
)
RETURNS TABLE (
  session_id                    uuid,
  status                        text,
  original_storage_path         text,
  display_storage_path          text,
  content_type                  text,
  storage_upload_expires_at     timestamptz,
  processing_lease_expires_at   timestamptz,
  media_object_id               uuid,
  replaced_media_object_id      uuid
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT
    us.session_id,
    us.status,
    us.original_storage_path,
    us.display_storage_path,
    us.content_type,
    us.storage_upload_expires_at,
    us.processing_lease_expires_at,
    us.media_object_id,
    us.replaced_media_object_id
  FROM private.upload_sessions AS us
  WHERE us.upload_token_hash = p_token_hash
    AND us.uploader_id       = p_uploader_id;
$$;


-- --------------------------------------------------------------------
-- 9.4  advance_upload_session_processing  (Section 5.4)
-- --------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.advance_upload_session_processing(
  p_session_id    uuid,
  p_uploader_id   uuid,
  p_lease_duration interval
)
RETURNS TABLE (original_storage_path text, display_storage_path text)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_session record;
BEGIN
  SELECT us.session_id, us.uploader_id, us.status, us.expires_at,
         us.original_storage_path, us.display_storage_path, us.storage_upload_expires_at
  INTO v_session
  FROM private.upload_sessions AS us
  WHERE us.session_id = p_session_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'FK_INVALID_TOKEN: session not found';
  END IF;

  IF v_session.uploader_id != p_uploader_id THEN
    RAISE EXCEPTION 'FK_INVALID_TOKEN: uploader mismatch';
  END IF;

  -- Require activate_upload_session was called (upload URL was legitimately issued).
  IF v_session.storage_upload_expires_at IS NULL THEN
    RAISE EXCEPTION 'FK_WRONG_STATE: upload capability not issued — activate_upload_session must be called before processing';
  END IF;

  IF v_session.status != 'pending' THEN
    RAISE EXCEPTION 'FK_INVALID_TOKEN: session is not pending (status: %)', v_session.status;
  END IF;

  IF now() >= v_session.expires_at THEN
    RAISE EXCEPTION 'FK_INVALID_TOKEN: session has expired';
  END IF;

  UPDATE private.upload_sessions
  SET
    status                       = 'processing',
    status_changed_at            = now(),
    processing_lease_expires_at  = now() + p_lease_duration
  WHERE session_id = p_session_id;

  RETURN QUERY SELECT v_session.original_storage_path, v_session.display_storage_path;
END;
$$;


-- --------------------------------------------------------------------
-- 9.5  check_upload_session_lease  (Section 5.5)
-- --------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.check_upload_session_lease(p_session_id uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1 FROM private.upload_sessions
    WHERE session_id = p_session_id
      AND status     = 'processing'
      AND processing_lease_expires_at > now()
  );
$$;


-- --------------------------------------------------------------------
-- 9.6  advance_upload_session_sanitized  (Section 5.6)
-- --------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.advance_upload_session_sanitized(p_session_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  UPDATE private.upload_sessions
  SET status = 'sanitized', status_changed_at = now()
  WHERE session_id = p_session_id
    AND status     = 'processing';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'FK_WRONG_STATE: session is not in processing state (session_id: %)', p_session_id;
  END IF;
END;
$$;


-- --------------------------------------------------------------------
-- 9.7  finalize_upload_session  (Section 5.7)
-- --------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.finalize_upload_session(
  p_session_id  uuid,
  p_sha256_hash text
)
RETURNS TABLE (media_object_id uuid, replaced_media_object_id uuid)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_session              record;
  v_challenge            record;
  v_new_media_object_id  uuid;
  v_old_media_object_id  uuid;
BEGIN
  -- Validate SHA-256 hash format before acquiring any locks.
  IF p_sha256_hash IS NULL OR p_sha256_hash !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'FK_INVALID_HASH: sha256_hash must be 64 lowercase hex characters';
  END IF;

  -- Lock the session row (mutual exclusion with claim_cleanup_sessions via FOR UPDATE SKIP LOCKED).
  SELECT us.session_id, us.uploader_id, us.challenge_id, us.status,
         us.original_storage_path, us.display_storage_path, us.content_type,
         us.media_object_id, us.replaced_media_object_id
  INTO v_session
  FROM private.upload_sessions us
  WHERE us.session_id = p_session_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'FK_WRONG_STATE: session not found (session_id: %)', p_session_id;
  END IF;

  -- Idempotent: if already complete, return stored outputs.
  IF v_session.status = 'complete' THEN
    RETURN QUERY SELECT v_session.media_object_id, v_session.replaced_media_object_id;
    RETURN;
  END IF;

  -- Only proceed from sanitized.
  IF v_session.status != 'sanitized' THEN
    RAISE EXCEPTION 'FK_WRONG_STATE: session is not sanitized (status: %)', v_session.status;
  END IF;

  -- Lock the challenge row (serializes with activate_challenge and reserve_upload_session).
  SELECT ch.id, ch.state, ch.media_object_id
  INTO v_challenge
  FROM public.challenges AS ch
  WHERE ch.id = v_session.challenge_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'FK_WRONG_STATE: challenge not found';
  END IF;

  IF v_challenge.state != 'draft' THEN
    RAISE EXCEPTION 'FK_WRONG_STATE: challenge is not in draft state (state: %)', v_challenge.state;
  END IF;

  -- Record the prior media object for replacement tracking.
  v_old_media_object_id := v_challenge.media_object_id;

  -- Insert new media_objects row (status = 'pending_review': moderator approval required).
  INSERT INTO public.media_objects (uploader_id, mime_type, status, re_encoded_at)
  VALUES (v_session.uploader_id, 'image/webp', 'pending_review', now())
  RETURNING id INTO v_new_media_object_id;

  -- Insert storage key record including SHA-256 hash.
  INSERT INTO private.media_storage_keys (
    media_object_id, storage_key, re_encoded_storage_key, sha256_hash
  ) VALUES (
    v_new_media_object_id,
    v_session.original_storage_path,
    v_session.display_storage_path,
    p_sha256_hash
  );

  -- Supersede the prior media object (covers pending_review, rejected, and any other status).
  IF v_old_media_object_id IS NOT NULL THEN
    UPDATE public.media_objects
    SET status = 'superseded'
    WHERE id = v_old_media_object_id;
  END IF;

  -- Atomically set the challenge's media object to the new one.
  UPDATE public.challenges
  SET media_object_id = v_new_media_object_id
  WHERE id = v_session.challenge_id;

  -- Transition session to complete; record finalization outputs.
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


-- --------------------------------------------------------------------
-- 9.8  fail_upload_session  (Section 5.8)
-- State machine: pending/processing/sanitized → failed (idempotent if already failed).
-- complete/expired/cleaned raise FK_WRONG_STATE. Not found is a safe no-op.
-- --------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fail_upload_session(
  p_session_id  uuid,
  p_error_code  text
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_status text;
BEGIN
  SELECT status INTO v_status
  FROM private.upload_sessions
  WHERE session_id = p_session_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN;  -- safe no-op (compensating cleanup path)
  END IF;

  IF v_status = 'failed' THEN
    RETURN;  -- idempotent; do not change timestamp or reason
  END IF;

  IF v_status IN ('complete', 'expired', 'cleaned') THEN
    RAISE EXCEPTION 'FK_WRONG_STATE: fail_upload_session cannot transition status=% to failed', v_status;
  END IF;

  -- Valid transitions: pending, processing, sanitized → failed
  UPDATE private.upload_sessions
  SET
    status            = 'failed',
    status_changed_at = now(),
    failed_reason     = p_error_code   -- CHECK constraint enforces FK_[A-Z_]+ format, max 50 chars
  WHERE session_id = p_session_id;
END;
$$;


-- --------------------------------------------------------------------
-- 9.9  quiesce_upload_sessions_for_deletion  (Section 6.1)
-- --------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.quiesce_upload_sessions_for_deletion(p_user_id uuid)
RETURNS TABLE (
  session_id                uuid,
  original_storage_path     text,
  display_storage_path      text,
  prior_status              text,
  blocking_lease_expires_at timestamptz
)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_rec record;
BEGIN
  -- Lock all in-flight sessions in consistent order (prevents deadlock with concurrent workers).
  FOR v_rec IN
    SELECT us.session_id,
           us.original_storage_path,
           us.display_storage_path,
           us.status                        AS prior_status,
           us.processing_lease_expires_at
    FROM private.upload_sessions us
    WHERE us.uploader_id = p_user_id
      AND us.status IN ('pending', 'processing', 'sanitized')
    ORDER BY us.session_id
    FOR UPDATE
  LOOP
    IF v_rec.prior_status = 'processing'
       AND v_rec.processing_lease_expires_at > clock_timestamp()
    THEN
      -- Active lease: return to caller to wait; do NOT transition.
      session_id                := v_rec.session_id;
      original_storage_path     := v_rec.original_storage_path;
      display_storage_path      := v_rec.display_storage_path;
      prior_status              := v_rec.prior_status;
      blocking_lease_expires_at := v_rec.processing_lease_expires_at;
      RETURN NEXT;
    ELSE
      -- Transition: pending, sanitized, or processing with expired lease → failed.
      UPDATE private.upload_sessions AS us
      SET status            = 'failed',
          status_changed_at = clock_timestamp(),
          failed_reason     = 'FK_ACCOUNT_DELETED'
      WHERE us.session_id = v_rec.session_id;

      session_id                := v_rec.session_id;
      original_storage_path     := v_rec.original_storage_path;
      display_storage_path      := v_rec.display_storage_path;
      prior_status              := v_rec.prior_status;
      blocking_lease_expires_at := NULL;
      RETURN NEXT;
    END IF;
  END LOOP;
END;
$$;


-- --------------------------------------------------------------------
-- 9.10  get_upload_capability_expiry  (Section 6.2)
-- --------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_upload_capability_expiry(p_user_id uuid)
RETURNS TABLE (blocking_until timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT MAX(storage_upload_expires_at + interval '30 seconds') AS blocking_until
  FROM private.upload_sessions
  WHERE uploader_id = p_user_id
    AND status != 'cleaned'
    AND storage_upload_expires_at IS NOT NULL
    AND storage_upload_expires_at + interval '30 seconds' > now();
$$;


-- --------------------------------------------------------------------
-- 9.11  get_all_upload_session_paths_for_deletion  (Section 6.3)
-- --------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_all_upload_session_paths_for_deletion(p_user_id uuid)
RETURNS TABLE (
  session_id            uuid,
  original_storage_path text,
  display_storage_path  text,
  status                text
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT
    us.session_id,
    us.original_storage_path,
    CASE WHEN us.status = 'complete' THEN NULL ELSE us.display_storage_path END
      AS display_storage_path,
    us.status
  FROM private.upload_sessions us
  WHERE us.uploader_id = p_user_id
    AND us.status != 'cleaned';
$$;


-- --------------------------------------------------------------------
-- 9.12  claim_cleanup_sessions  (Section 6.4)
-- --------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.claim_cleanup_sessions(
  p_worker_id     text,
  p_claim_duration interval DEFAULT interval '15 minutes'
)
RETURNS TABLE (
  session_id            uuid,
  original_storage_path text,
  display_storage_path  text,
  status                text,
  cleanup_claim_token   uuid
)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_claim_token uuid;
BEGIN
  -- Step 1: Transition stale pending sessions → expired.
  UPDATE private.upload_sessions AS us
  SET status = 'expired', status_changed_at = now()
  WHERE us.status = 'pending'
    AND us.expires_at + interval '60 seconds' < now()
    AND (us.cleanup_claim_expires_at IS NULL OR us.cleanup_claim_expires_at < now());

  -- Step 2: Transition stale processing sessions → failed.
  UPDATE private.upload_sessions AS us
  SET status = 'failed', status_changed_at = now(), failed_reason = 'FK_LEASE_EXPIRED'
  WHERE us.status = 'processing'
    AND us.processing_lease_expires_at < now()
    AND (us.cleanup_claim_expires_at IS NULL OR us.cleanup_claim_expires_at < now());

  -- Step 3: Transition abandoned sanitized sessions → failed.
  -- FOR UPDATE SKIP LOCKED: skips rows locked by a concurrent finalize_upload_session.
  WITH abandoned_sanitized AS (
    SELECT us.session_id FROM private.upload_sessions AS us
    WHERE us.status = 'sanitized'
      AND us.processing_lease_expires_at + interval '60 minutes' < now()
      AND (us.cleanup_claim_expires_at IS NULL OR us.cleanup_claim_expires_at < now())
    FOR UPDATE SKIP LOCKED
  )
  UPDATE private.upload_sessions AS us
  SET status = 'failed', status_changed_at = now(), failed_reason = 'FK_ABANDONED_SANITIZED'
  FROM abandoned_sanitized a
  WHERE us.session_id = a.session_id;

  -- Step 4: Claim eligible sessions (expired + failed) past their URL-expiry gate.
  RETURN QUERY
  WITH eligible AS (
    SELECT us.session_id FROM private.upload_sessions AS us
    WHERE us.status IN ('expired', 'failed')
      AND (us.cleanup_claim_expires_at IS NULL OR us.cleanup_claim_expires_at < now())
      AND (
        us.storage_upload_expires_at IS NULL
        OR us.storage_upload_expires_at + interval '30 seconds' <= now()
      )
    FOR UPDATE SKIP LOCKED
  ),
  claimed AS (
    UPDATE private.upload_sessions AS us
    SET
      cleanup_claim_token      = gen_random_uuid(),
      cleanup_claimed_at       = now(),
      cleanup_claim_expires_at = now() + p_claim_duration
    FROM eligible e
    WHERE us.session_id = e.session_id
    RETURNING us.session_id, us.original_storage_path, us.display_storage_path,
              us.status, us.cleanup_claim_token
  )
  SELECT c.session_id, c.original_storage_path, c.display_storage_path,
         c.status, c.cleanup_claim_token
  FROM claimed c;
END;
$$;


-- --------------------------------------------------------------------
-- 9.13  mark_session_cleaned  (Section 6.5)
-- --------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.mark_session_cleaned(
  p_session_id          uuid,
  p_cleanup_claim_token uuid
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_session record;
BEGIN
  SELECT status, cleanup_claim_token, cleanup_claim_expires_at
  INTO v_session
  FROM private.upload_sessions
  WHERE session_id = p_session_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'session not found (session_id: %)', p_session_id;
  END IF;

  IF v_session.status = 'complete' THEN
    RAISE EXCEPTION 'FK_WRONG_STATE: mark_session_cleaned must not be called on a complete session';
  END IF;

  IF v_session.status = 'cleaned' THEN
    RETURN;  -- idempotent
  END IF;

  IF v_session.status NOT IN ('failed', 'expired') THEN
    RAISE EXCEPTION 'FK_WRONG_STATE: session must be failed or expired to be marked cleaned (status: %)', v_session.status;
  END IF;

  IF v_session.cleanup_claim_token IS DISTINCT FROM p_cleanup_claim_token THEN
    RAISE EXCEPTION 'claim token mismatch';
  END IF;

  IF v_session.cleanup_claim_expires_at IS NULL OR v_session.cleanup_claim_expires_at < now() THEN
    RAISE EXCEPTION 'cleanup claim has expired';
  END IF;

  UPDATE private.upload_sessions
  SET
    status               = 'cleaned',
    status_changed_at    = now(),
    cleanup_completed_at = now()
  WHERE session_id = p_session_id;
END;
$$;


-- --------------------------------------------------------------------
-- 9.14  mark_original_path_post_expiry_cleaned  (Section 6.6)
-- --------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.mark_original_path_post_expiry_cleaned(p_session_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  UPDATE private.upload_sessions
  SET original_path_post_expiry_cleaned = true
  WHERE session_id = p_session_id
    AND status     = 'complete';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'FK_WRONG_STATE: session is not complete or not found (session_id: %)', p_session_id;
  END IF;
END;
$$;


-- --------------------------------------------------------------------
-- 9.15  get_complete_sessions_pending_expiry_cleanup  (Section 6.7)
-- --------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_complete_sessions_pending_expiry_cleanup()
RETURNS TABLE (session_id uuid, original_storage_path text)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT us.session_id, us.original_storage_path
  FROM private.upload_sessions AS us
  WHERE us.status = 'complete'
    AND us.original_path_post_expiry_cleaned = false
    AND us.storage_upload_expires_at IS NOT NULL
    AND us.storage_upload_expires_at + interval '30 seconds' <= now();
$$;


-- --------------------------------------------------------------------
-- 9.16  get_superseded_media_to_clean  (Section 7.1)
-- --------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_superseded_media_to_clean()
RETURNS TABLE (media_object_id uuid, re_encoded_storage_key text)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT mo.id, msk.re_encoded_storage_key
  FROM public.media_objects mo
  JOIN private.media_storage_keys msk ON msk.media_object_id = mo.id
  WHERE mo.status = 'superseded';
$$;


-- --------------------------------------------------------------------
-- 9.17  mark_superseded_media_cleaned  (Section 7.2)
-- --------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.mark_superseded_media_cleaned(p_media_object_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  UPDATE public.media_objects
  SET status = 'cleaned'
  WHERE id     = p_media_object_id
    AND status = 'superseded';
  -- Idempotent: no NOT FOUND check (already cleaned is acceptable)
END;
$$;


-- --------------------------------------------------------------------
-- 9.18  get_media_storage_key  (Section 7.3)
-- --------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_media_storage_key(p_media_object_id uuid)
RETURNS TABLE (re_encoded_storage_key text)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT msk.re_encoded_storage_key
  FROM public.media_objects mo
  JOIN private.media_storage_keys msk ON msk.media_object_id = mo.id
  WHERE mo.id     = p_media_object_id
    AND mo.status = 'ready';
$$;


-- --------------------------------------------------------------------
-- 9.19  reveal_challenge_service_wrapper  (Section 8.1)
-- --------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.reveal_challenge_service_wrapper(p_challenge_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM private.reveal_challenge_service(p_challenge_id);
END;
$$;


-- --------------------------------------------------------------------
-- 9.20  prepare_account_deletion_wrapper  (Section 9.1)
-- --------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.prepare_account_deletion_wrapper(p_user_id uuid)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_status text;
BEGIN
  -- Check current deletion state for idempotency
  SELECT status INTO v_status
  FROM private.deletion_log
  WHERE profile_id = p_user_id;

  IF v_status = 'database_prepared' THEN
    RETURN 'database_prepared';
  ELSIF v_status = 'auth_deleted' THEN
    RETURN 'auth_deleted';
  ELSIF v_status = 'complete' THEN
    RETURN 'complete';
  END IF;

  -- No record, 'pending', or 'failed' — proceed with preparation.
  -- V1 private function; parameter is p_profile_id (passed positionally).
  PERFORM private.prepare_account_deletion(p_user_id);

  RETURN 'database_prepared';
END;
$$;


-- --------------------------------------------------------------------
-- 9.21  get_deletion_storage_keys  (Section 9.2)
-- --------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_deletion_storage_keys(p_user_id uuid)
RETURNS TABLE (media_object_id uuid, storage_key text)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT * FROM private.get_storage_keys_for_deletion(p_user_id);
$$;


-- --------------------------------------------------------------------
-- 9.22  record_deletion_failure_wrapper  (Section 9.3)
-- --------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.record_deletion_failure_wrapper(
  p_user_id    uuid,
  p_error_code text
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  -- Enforce FK_* format and length limit (max 50 chars consistent with failed_reason constraint).
  IF p_error_code IS NULL
     OR p_error_code !~ '^FK_[A-Z_]+$'
     OR length(p_error_code) > 50
  THEN
    RAISE EXCEPTION 'FK_INVALID_INPUT: error_code must match FK_[A-Z_]+ format, max 50 chars';
  END IF;
  PERFORM private.record_deletion_failure(p_user_id, p_error_code);
END;
$$;


-- --------------------------------------------------------------------
-- 9.23  mark_auth_deleted_wrapper  (Section 9.4)
-- --------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.mark_auth_deleted_wrapper(p_user_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM private.mark_auth_deleted(p_user_id);
END;
$$;


-- --------------------------------------------------------------------
-- 9.24  mark_storage_cleaned_wrapper  (Section 9.5)
-- --------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.mark_storage_cleaned_wrapper(p_user_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM private.mark_storage_cleaned(p_user_id);
END;
$$;


-- --------------------------------------------------------------------
-- 9.25  claim_deletion_recovery_records  (Section 10.1)
-- Uses FOR UPDATE SKIP LOCKED per branch to prevent concurrent worker races.
-- --------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.claim_deletion_recovery_records(
  p_worker_id          text,
  p_scan_age_threshold interval DEFAULT interval '10 minutes',
  p_claim_duration     interval DEFAULT interval '10 minutes'
)
RETURNS TABLE (user_id uuid, scan_type text, claim_token uuid)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_rec   record;
  v_token uuid;
BEGIN
  -- Branch 1: 'database_prepared' records older than threshold.
  FOR v_rec IN
    SELECT dl.profile_id
    FROM private.deletion_log dl
    WHERE dl.status = 'database_prepared'
      AND dl.db_prepared_at < now() - p_scan_age_threshold
      AND NOT EXISTS (
        SELECT 1 FROM private.deletion_recovery_claims drc
        WHERE drc.user_id = dl.profile_id AND drc.claim_expires_at > now()
      )
    FOR UPDATE SKIP LOCKED
  LOOP
    v_token := gen_random_uuid();
    INSERT INTO private.deletion_recovery_claims
      (user_id, scan_type, claim_token, claimed_at, claim_expires_at)
    VALUES
      (v_rec.profile_id, 'database_prepared', v_token, now(), now() + p_claim_duration)
    ON CONFLICT ON CONSTRAINT deletion_recovery_claims_pkey DO UPDATE
      SET scan_type        = EXCLUDED.scan_type,
          claim_token      = EXCLUDED.claim_token,
          claimed_at       = EXCLUDED.claimed_at,
          claim_expires_at = EXCLUDED.claim_expires_at;

    user_id     := v_rec.profile_id;
    scan_type   := 'database_prepared';
    claim_token := v_token;
    RETURN NEXT;
  END LOOP;

  -- Branch 2: 'auth_deleted' records without an unexpired claim.
  FOR v_rec IN
    SELECT dl.profile_id
    FROM private.deletion_log dl
    WHERE dl.status = 'auth_deleted'
      AND NOT EXISTS (
        SELECT 1 FROM private.deletion_recovery_claims drc
        WHERE drc.user_id = dl.profile_id AND drc.claim_expires_at > now()
      )
    FOR UPDATE SKIP LOCKED
  LOOP
    v_token := gen_random_uuid();
    INSERT INTO private.deletion_recovery_claims
      (user_id, scan_type, claim_token, claimed_at, claim_expires_at)
    VALUES
      (v_rec.profile_id, 'auth_deleted', v_token, now(), now() + p_claim_duration)
    ON CONFLICT ON CONSTRAINT deletion_recovery_claims_pkey DO UPDATE
      SET scan_type        = EXCLUDED.scan_type,
          claim_token      = EXCLUDED.claim_token,
          claimed_at       = EXCLUDED.claimed_at,
          claim_expires_at = EXCLUDED.claim_expires_at;

    user_id     := v_rec.profile_id;
    scan_type   := 'auth_deleted';
    claim_token := v_token;
    RETURN NEXT;
  END LOOP;
END;
$$;


-- --------------------------------------------------------------------
-- 9.26  complete_deletion_recovery  (Section 10.2)
-- --------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.complete_deletion_recovery(
  p_user_id    uuid,
  p_claim_token uuid,
  p_scan_type  text
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_claim record;
BEGIN
  SELECT user_id, scan_type, claim_token, claim_expires_at
  INTO v_claim
  FROM private.deletion_recovery_claims
  WHERE user_id = p_user_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'deletion recovery claim not found for user %', p_user_id;
  END IF;

  IF v_claim.claim_token IS DISTINCT FROM p_claim_token THEN
    RAISE EXCEPTION 'claim token mismatch for user %', p_user_id;
  END IF;

  IF v_claim.claim_expires_at < now() THEN
    RAISE EXCEPTION 'claim has expired for user %', p_user_id;
  END IF;

  IF v_claim.scan_type IS DISTINCT FROM p_scan_type THEN
    RAISE EXCEPTION 'scan_type mismatch: expected %, got %', v_claim.scan_type, p_scan_type;
  END IF;

  IF p_scan_type = 'database_prepared' THEN
    PERFORM private.mark_auth_deleted(p_user_id);
    PERFORM private.mark_storage_cleaned(p_user_id);
  ELSIF p_scan_type = 'auth_deleted' THEN
    PERFORM private.mark_storage_cleaned(p_user_id);
  ELSE
    RAISE EXCEPTION 'unrecognized scan_type: %', p_scan_type;
  END IF;

  DELETE FROM private.deletion_recovery_claims WHERE user_id = p_user_id;
END;
$$;


-- --------------------------------------------------------------------
-- 9.27  fail_deletion_recovery  (Section 10.3)
-- --------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fail_deletion_recovery(
  p_user_id     uuid,
  p_claim_token uuid,
  p_error_code  text
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_claim record;
BEGIN
  SELECT claim_token, claim_expires_at
  INTO v_claim
  FROM private.deletion_recovery_claims
  WHERE user_id = p_user_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'deletion recovery claim not found for user %', p_user_id;
  END IF;

  IF v_claim.claim_token IS DISTINCT FROM p_claim_token THEN
    RAISE EXCEPTION 'claim token mismatch for user %', p_user_id;
  END IF;

  IF v_claim.claim_expires_at < now() THEN
    RAISE EXCEPTION 'claim has expired for user %', p_user_id;
  END IF;

  -- Validate error code format before storing.
  IF p_error_code IS NULL
     OR p_error_code !~ '^FK_[A-Z_]+$'
     OR length(p_error_code) > 50
  THEN
    RAISE EXCEPTION 'FK_INVALID_INPUT: error_code must match FK_[A-Z_]+ format, max 50 chars';
  END IF;

  PERFORM private.record_deletion_failure(p_user_id, p_error_code);

  DELETE FROM private.deletion_recovery_claims WHERE user_id = p_user_id;
END;
$$;


-- =============================================================================
-- SECTION 10 — SCHEMA GRANTS AND OWNERSHIP
-- V1 revoked postgres's membership from forkensics_executor and revoked CREATE
-- on public/private schemas. Temporary-grant pattern required for ownership transfers.
-- =============================================================================

-- ── Temporary role grant (open) ──────────────────────────────────────────────
GRANT forkensics_executor TO postgres;
GRANT CREATE ON SCHEMA private TO forkensics_executor;
GRANT CREATE ON SCHEMA public  TO forkensics_executor;

-- ── Table access grants ───────────────────────────────────────────────────────
GRANT SELECT, INSERT, UPDATE                   ON private.upload_sessions           TO forkensics_executor;
GRANT SELECT, INSERT, UPDATE, DELETE           ON private.deletion_recovery_claims  TO forkensics_executor;

-- ── Transfer ownership of trigger functions ───────────────────────────────────
ALTER FUNCTION private.check_activation_no_active_upload() OWNER TO forkensics_executor;
ALTER FUNCTION private.check_activation_media_ready()      OWNER TO forkensics_executor;

-- ── EXECUTE grants and PUBLIC revokes for all 27 new public functions ─────────
DO $$
DECLARE
  fn text;
BEGIN
  FOR fn IN SELECT unnest(ARRAY[
    'public.reserve_upload_session(uuid,uuid,text,text,bigint,timestamptz)',
    'public.activate_upload_session(uuid,timestamptz)',
    'public.resolve_upload_session(text,uuid)',
    'public.advance_upload_session_processing(uuid,uuid,interval)',
    'public.check_upload_session_lease(uuid)',
    'public.advance_upload_session_sanitized(uuid)',
    'public.finalize_upload_session(uuid,text)',
    'public.fail_upload_session(uuid,text)',
    'public.quiesce_upload_sessions_for_deletion(uuid)',
    'public.get_upload_capability_expiry(uuid)',
    'public.get_all_upload_session_paths_for_deletion(uuid)',
    'public.claim_cleanup_sessions(text,interval)',
    'public.mark_session_cleaned(uuid,uuid)',
    'public.mark_original_path_post_expiry_cleaned(uuid)',
    'public.get_complete_sessions_pending_expiry_cleanup()',
    'public.get_superseded_media_to_clean()',
    'public.mark_superseded_media_cleaned(uuid)',
    'public.get_media_storage_key(uuid)',
    'public.reveal_challenge_service_wrapper(uuid)',
    'public.prepare_account_deletion_wrapper(uuid)',
    'public.get_deletion_storage_keys(uuid)',
    'public.record_deletion_failure_wrapper(uuid,text)',
    'public.mark_auth_deleted_wrapper(uuid)',
    'public.mark_storage_cleaned_wrapper(uuid)',
    'public.claim_deletion_recovery_records(text,interval,interval)',
    'public.complete_deletion_recovery(uuid,uuid,text)',
    'public.fail_deletion_recovery(uuid,uuid,text)'
  ])
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated', fn);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role', fn);
  END LOOP;
END;
$$;

-- ── Transfer ownership of all 27 new public functions ────────────────────────
ALTER FUNCTION public.reserve_upload_session(uuid,uuid,text,text,bigint,timestamptz)  OWNER TO forkensics_executor;
ALTER FUNCTION public.activate_upload_session(uuid,timestamptz)                        OWNER TO forkensics_executor;
ALTER FUNCTION public.resolve_upload_session(text,uuid)                                OWNER TO forkensics_executor;
ALTER FUNCTION public.advance_upload_session_processing(uuid,uuid,interval)            OWNER TO forkensics_executor;
ALTER FUNCTION public.check_upload_session_lease(uuid)                                 OWNER TO forkensics_executor;
ALTER FUNCTION public.advance_upload_session_sanitized(uuid)                           OWNER TO forkensics_executor;
ALTER FUNCTION public.finalize_upload_session(uuid,text)                               OWNER TO forkensics_executor;
ALTER FUNCTION public.fail_upload_session(uuid,text)                                   OWNER TO forkensics_executor;
ALTER FUNCTION public.quiesce_upload_sessions_for_deletion(uuid)                       OWNER TO forkensics_executor;
ALTER FUNCTION public.get_upload_capability_expiry(uuid)                               OWNER TO forkensics_executor;
ALTER FUNCTION public.get_all_upload_session_paths_for_deletion(uuid)                  OWNER TO forkensics_executor;
ALTER FUNCTION public.claim_cleanup_sessions(text,interval)                            OWNER TO forkensics_executor;
ALTER FUNCTION public.mark_session_cleaned(uuid,uuid)                                  OWNER TO forkensics_executor;
ALTER FUNCTION public.mark_original_path_post_expiry_cleaned(uuid)                     OWNER TO forkensics_executor;
ALTER FUNCTION public.get_complete_sessions_pending_expiry_cleanup()                   OWNER TO forkensics_executor;
ALTER FUNCTION public.get_superseded_media_to_clean()                                  OWNER TO forkensics_executor;
ALTER FUNCTION public.mark_superseded_media_cleaned(uuid)                              OWNER TO forkensics_executor;
ALTER FUNCTION public.get_media_storage_key(uuid)                                      OWNER TO forkensics_executor;
ALTER FUNCTION public.reveal_challenge_service_wrapper(uuid)                           OWNER TO forkensics_executor;
ALTER FUNCTION public.prepare_account_deletion_wrapper(uuid)                           OWNER TO forkensics_executor;
ALTER FUNCTION public.get_deletion_storage_keys(uuid)                                  OWNER TO forkensics_executor;
ALTER FUNCTION public.record_deletion_failure_wrapper(uuid,text)                       OWNER TO forkensics_executor;
ALTER FUNCTION public.mark_auth_deleted_wrapper(uuid)                                  OWNER TO forkensics_executor;
ALTER FUNCTION public.mark_storage_cleaned_wrapper(uuid)                               OWNER TO forkensics_executor;
ALTER FUNCTION public.claim_deletion_recovery_records(text,interval,interval)          OWNER TO forkensics_executor;
ALTER FUNCTION public.complete_deletion_recovery(uuid,uuid,text)                       OWNER TO forkensics_executor;
ALTER FUNCTION public.fail_deletion_recovery(uuid,uuid,text)                           OWNER TO forkensics_executor;

-- ── Temporary role grant (close) ─────────────────────────────────────────────
REVOKE CREATE ON SCHEMA private FROM forkensics_executor;
REVOKE CREATE ON SCHEMA public  FROM forkensics_executor;
REVOKE forkensics_executor FROM postgres;


-- =============================================================================
-- SECTION 11 — COMPLETION MARKER
-- =============================================================================

-- V2__upload_sessions.sql applied successfully.
-- Tables:     private.upload_sessions (21 columns), private.deletion_recovery_claims (5 columns)
-- Modified:   public.media_objects status constraint (+ superseded, pending_review, rejected, removed, cleaned)
--             private.media_storage_keys.sha256_hash (nullable; V2b will add NOT NULL after backfill)
-- Indexes:    upload_sessions_one_active_per_challenge (partial unique),
--             idx_upload_sessions_uploader_status, idx_upload_sessions_cleanup_candidates,
--             idx_upload_sessions_capability_expiry, idx_upload_sessions_expiry_cleanup,
--             idx_deletion_recovery_scan_type
-- Triggers:   challenge_v2_no_active_upload_on_activate, challenge_v2_media_ready_on_activate
-- Functions:  27 SECURITY DEFINER public functions (Sections 9.1–9.27)
-- Next step:  Run V2_acceptance_tests.sql in dev before any deployment.

COMMIT;
