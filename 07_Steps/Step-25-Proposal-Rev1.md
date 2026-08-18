# Step 25 Proposal — Rev 1 — V2 Migration: Upload Session Infrastructure

**Status:** Pending review (Claude → Codex/GPT → Bill approval)
**Governance gate:** Bill must type `APPROVED: Step 25 — V2 Migration: Upload Session Infrastructure` before `V2__upload_sessions.sql` is written as a deployable file or applied to any environment.
**Prerequisite:** Step 24 approved 2026-08-07.

---

## Section 1 — Objective and Scope

### 1.1 Objective

Deliver `V2__upload_sessions.sql` — the database migration that implements every database-layer contract defined in Step 24 Rev 10. Without this migration, no Edge Function step can begin implementation.

### 1.2 Included Scope

- `private.upload_sessions` table (20 columns, constraints, indexes)
- `private.deletion_recovery_claims` table (5 columns, constraint, index)
- Expansion of `public.media_objects` status constraint to include `'superseded'` and `'cleaned'`
- Partial unique index on `private.upload_sessions(challenge_id)` enforcing at most one active session per challenge
- V2 BEFORE UPDATE trigger on `public.challenges` rejecting `draft → active` while an active upload session exists
- V2 BEFORE UPDATE trigger on `public.challenges` rejecting `draft → active` if `media_object_id` references non-`'ready'` media (defense-in-depth only; V1 `activate_challenge` already checks this)
- All 27 public SECURITY DEFINER functions defined in Step 24 Section 2.7, with full bodies
- Schema grants to `forkensics_executor` for `SELECT` / `INSERT` / `UPDATE` on both private tables
- `EXECUTE` grants on all new public functions to `service_role` only; REVOKE from all other roles
- Ownership of all new public functions transferred to `forkensics_executor`
- Ownership of all new trigger functions transferred to `forkensics_executor`

### 1.3 Excluded Scope

- TypeScript / Deno Edge Function code (separate per-function steps)
- Any V1 function body modification (V1 is frozen)
- RLS policies on `private.upload_sessions` or `private.deletion_recovery_claims` (neither table is accessible through PostgREST; no RLS needed)
- Any new RLS policy on V1 tables
- The cron secret and pg_cron setup (covered in the per-function deployment steps)
- Storage bucket creation (covered in Step 23 deployment; bucket `game-media` already exists)

### 1.4 V1 Freeze Confirmation

`V1__initial_schema.sql` SHA-256: `2581412af146acdaaf9a7139c98a208fa4b1fe1a355ee14e043f9117b6f3afc3` — immutable. This migration is `V2__upload_sessions.sql`. No V1 file is modified.

---

## Section 2 — Table DDL

### 2.1 `private.upload_sessions`

```sql
CREATE TABLE IF NOT EXISTS private.upload_sessions (
  -- Identity
  session_id                       uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  upload_token_hash                text        NOT NULL UNIQUE,

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

  CONSTRAINT upload_sessions_failed_reason_no_paths_check
    CHECK (failed_reason IS NULL OR length(failed_reason) <= 50)
    -- failed_reason stores sanitized error codes only; no storage paths, no raw errors
);
```

**Design notes:**
- `challenge_id` and `uploader_id` use `ON DELETE RESTRICT`, not `ON DELETE CASCADE`. Sessions must outlive challenge cancellation and profile deletion so the cleanup worker can process them. The deletion lifecycle explicitly manages session cleanup before removing any storage.
- `upload_token_hash` is the SHA-256 hex of the secret token; the token itself is never stored.
- `media_object_id` and `replaced_media_object_id` have no FK constraints here; `finalize_upload_session` validates both against `public.media_objects` during the atomic insertion. Adding FK constraints would create a circular dependency (media_objects ← upload_sessions → media_objects).

### 2.2 Indexes on `private.upload_sessions`

```sql
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
```

### 2.3 `private.deletion_recovery_claims`

```sql
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

-- For worker: find expired claims or by scan type
CREATE INDEX IF NOT EXISTS idx_deletion_recovery_scan_type
  ON private.deletion_recovery_claims (scan_type, claim_expires_at);
```

---

## Section 3 — Modify `public.media_objects` Status Constraint

V1 constraint:
```
CONSTRAINT media_objects_status_check CHECK (status IN ('processing','ready','failed','deleted'))
```

V2 adds `'superseded'` and `'cleaned'`:

```sql
ALTER TABLE public.media_objects DROP CONSTRAINT media_objects_status_check;
ALTER TABLE public.media_objects ADD CONSTRAINT media_objects_status_check
  CHECK (status IN ('processing','ready','failed','deleted','superseded','cleaned'));
```

This is an additive change — all existing rows remain valid. The DROP + ADD is safe because no rows currently have the new status values (the old constraint prevented it).

---

## Section 4 — V2 Triggers on `public.challenges`

Both triggers are BEFORE UPDATE, SECURITY INVOKER (default). They run in the context of the calling role. When called from within `activate_challenge` (SECURITY DEFINER owned by `forkensics_executor`), both triggers run as `forkensics_executor`, which has `SELECT` on `private.upload_sessions` and `public.media_objects`.

### 4.1 Trigger function: reject activation while active upload session exists

```sql
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

CREATE OR REPLACE TRIGGER challenge_v2_no_active_upload_on_activate
  BEFORE UPDATE ON public.challenges
  FOR EACH ROW EXECUTE PROCEDURE private.check_activation_no_active_upload();
```

### 4.2 Trigger function: reject activation if media is not ready (defense-in-depth)

V1's `activate_challenge` already verifies `status = 'ready'`; this trigger adds defense-in-depth against direct UPDATE paths and correctly rejects `'superseded'` and `'cleaned'` statuses added in V2.

```sql
CREATE OR REPLACE FUNCTION private.check_activation_media_ready()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  IF OLD.state = 'draft' AND NEW.state = 'active' THEN
    IF NEW.media_object_id IS NOT NULL THEN
      IF NOT EXISTS (
        SELECT 1 FROM public.media_objects
        WHERE id = NEW.media_object_id AND status = 'ready'
      ) THEN
        RAISE EXCEPTION 'challenge media object must have status ''ready'' before activation';
      END IF;
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER challenge_v2_media_ready_on_activate
  BEFORE UPDATE ON public.challenges
  FOR EACH ROW EXECUTE PROCEDURE private.check_activation_media_ready();
```

**Trigger ordering:** PostgreSQL fires BEFORE UPDATE triggers in alphabetical order by trigger name within the same event/timing. The existing V1 trigger is `challenge_protect_fields`. The new triggers are `challenge_v2_media_ready_on_activate` and `challenge_v2_no_active_upload_on_activate`. All three fire on UPDATE of `public.challenges`. The `challenge_protect_fields` trigger bypasses for `forkensics_executor`, then the two V2 triggers check activation preconditions.

**Ownership:** Both trigger functions transferred to `forkensics_executor` after creation.

---

## Section 5 — Upload Session Lifecycle Functions

All functions in this section: `public` schema, `SECURITY DEFINER`, `SET search_path = ''`, fully qualified table references, owned by `forkensics_executor`, EXECUTE granted to `service_role` only (REVOKE from `PUBLIC`, `authenticated`, `anon`).

### 5.1 `public.reserve_upload_session`

```sql
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
  -- This serializes reservation with any concurrent write to public.challenges,
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
      -- Both indicate an in-progress upload for this challenge.
      RAISE EXCEPTION 'FK_UPLOAD_IN_PROGRESS';
  END;

  RETURN QUERY SELECT v_session_id, v_orig_path, v_disp_path;
END;
$$;
```

### 5.2 `public.activate_upload_session`

```sql
CREATE OR REPLACE FUNCTION public.activate_upload_session(
  p_session_id                      uuid,
  p_actual_storage_upload_expires_at timestamptz
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  -- Sets the actual URL expiry captured at signing time.
  -- Only valid on a pending session that has not yet been activated (NULL expiry).
  -- If session is not in the expected state, raises an error so the caller can
  -- fail the session and return 500 without transmitting the URL.
  UPDATE private.upload_sessions
  SET storage_upload_expires_at = p_actual_storage_upload_expires_at
  WHERE session_id = p_session_id
    AND status = 'pending'
    AND storage_upload_expires_at IS NULL;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'FK_WRONG_STATE: session is not pending with NULL expiry (already activated, failed, or not found)';
  END IF;
END;
$$;
```

### 5.3 `public.resolve_upload_session`

```sql
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
    session_id,
    status,
    original_storage_path,
    display_storage_path,
    content_type,
    storage_upload_expires_at,
    processing_lease_expires_at,
    media_object_id,
    replaced_media_object_id
  FROM private.upload_sessions
  WHERE upload_token_hash = p_token_hash
    AND uploader_id       = p_uploader_id;
$$;
```

Returns zero rows if the token does not exist or does not belong to this uploader. Does not modify state.

### 5.4 `public.advance_upload_session_processing`

```sql
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
  SELECT session_id, uploader_id, status, expires_at,
         original_storage_path, display_storage_path
  INTO v_session
  FROM private.upload_sessions
  WHERE session_id = p_session_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'FK_INVALID_TOKEN: session not found';
  END IF;

  IF v_session.uploader_id != p_uploader_id THEN
    RAISE EXCEPTION 'FK_INVALID_TOKEN: uploader mismatch';
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
```

### 5.5 `public.check_upload_session_lease`

```sql
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
```

Returns `true` if the session is still in `processing` with a valid lease. Does not modify state.

### 5.6 `public.advance_upload_session_sanitized`

```sql
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
```

### 5.7 `public.finalize_upload_session`

This function performs the atomic DB finalization: inserts `public.media_objects`, inserts `private.media_storage_keys`, swaps `challenges.media_object_id`, records finalization outputs on the session row, and transitions to `complete`. It acquires row-level locks on both the session and challenge rows to prevent concurrent finalization and activation.

```sql
CREATE OR REPLACE FUNCTION public.finalize_upload_session(p_session_id uuid)
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
  -- Lock the session row (mutual exclusion with claim_cleanup_sessions via FOR UPDATE SKIP LOCKED)
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

  -- Idempotent: if already complete, return stored outputs
  IF v_session.status = 'complete' THEN
    RETURN QUERY SELECT v_session.media_object_id, v_session.replaced_media_object_id;
    RETURN;
  END IF;

  -- Only proceed from sanitized
  IF v_session.status != 'sanitized' THEN
    RAISE EXCEPTION 'FK_WRONG_STATE: session is not sanitized (status: %)', v_session.status;
  END IF;

  -- Lock the challenge row (serializes with activate_challenge and reserve_upload_session)
  SELECT id, state, media_object_id
  INTO v_challenge
  FROM public.challenges
  WHERE id = v_session.challenge_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'FK_WRONG_STATE: challenge not found';
  END IF;

  IF v_challenge.state != 'draft' THEN
    RAISE EXCEPTION 'FK_WRONG_STATE: challenge is not in draft state (state: %)', v_challenge.state;
  END IF;

  -- Record the prior media object (if any) for replacement tracking
  v_old_media_object_id := v_challenge.media_object_id;

  -- Insert new media_objects row (status = 'ready'; re_encoded_at = now())
  INSERT INTO public.media_objects (uploader_id, mime_type, status, re_encoded_at)
  VALUES (v_session.uploader_id, 'image/webp', 'ready', now())
  RETURNING id INTO v_new_media_object_id;

  -- Insert storage key record
  -- storage_key = original path (for reference; object was deleted by upload-complete step 7)
  -- re_encoded_storage_key = display path (the live object in storage)
  INSERT INTO private.media_storage_keys (
    media_object_id, storage_key, re_encoded_storage_key
  ) VALUES (
    v_new_media_object_id,
    v_session.original_storage_path,
    v_session.display_storage_path
  );

  -- If replacing a prior media object, mark it superseded
  IF v_old_media_object_id IS NOT NULL THEN
    UPDATE public.media_objects
    SET status = 'superseded'
    WHERE id = v_old_media_object_id;
  END IF;

  -- Atomically set the challenge's media object to the new one
  UPDATE public.challenges
  SET media_object_id = v_new_media_object_id
  WHERE id = v_session.challenge_id;

  -- Transition session to complete; record finalization outputs
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
```

### 5.8 `public.fail_upload_session`

```sql
CREATE OR REPLACE FUNCTION public.fail_upload_session(
  p_session_id  uuid,
  p_error_code  text
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  -- Raise an error if the session is complete — fail must never be called on a complete session
  IF EXISTS (
    SELECT 1 FROM private.upload_sessions
    WHERE session_id = p_session_id AND status = 'complete'
  ) THEN
    RAISE EXCEPTION 'FK_WRONG_STATE: fail_upload_session must not be called on a complete session';
  END IF;

  -- Idempotent on already-failed sessions; no-op if session doesn't exist
  UPDATE private.upload_sessions
  SET
    status            = 'failed',
    status_changed_at = now(),
    failed_reason     = substring(p_error_code FROM 1 FOR 50)  -- truncate to constraint limit
  WHERE session_id = p_session_id
    AND status    != 'complete';
  -- Note: no NOT FOUND check here — if session is missing (e.g., concurrent cleanup)
  -- failing silently is correct behavior for compensating cleanup.
END;
$$;
```

---

## Section 6 — Deletion Quiesce, Capability Check, and Cleanup Functions

### 6.1 `public.quiesce_upload_sessions_for_deletion`

```sql
CREATE OR REPLACE FUNCTION public.quiesce_upload_sessions_for_deletion(p_user_id uuid)
RETURNS TABLE (
  session_id               uuid,
  original_storage_path    text,
  display_storage_path     text,
  prior_status             text,
  blocking_lease_expires_at timestamptz
)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  -- Atomically transition pending and sanitized sessions to failed.
  -- Return all non-complete, non-cleaned sessions including processing ones
  -- (which may have an active lease).
  RETURN QUERY
  WITH quiesced AS (
    UPDATE private.upload_sessions us
    SET
      status            = 'failed',
      status_changed_at = now(),
      failed_reason     = 'FK_ACCOUNT_DELETED'
    WHERE us.uploader_id = p_user_id
      AND us.status IN ('pending', 'sanitized')
    RETURNING us.session_id, us.original_storage_path, us.display_storage_path,
              'pending'::text AS prior_status  -- overridden below; used for both statuses
  )
  SELECT
    us.session_id,
    us.original_storage_path,
    us.display_storage_path,
    us.status AS prior_status,  -- actual prior status before this call
    CASE
      WHEN us.status = 'processing' AND us.processing_lease_expires_at > now()
        THEN us.processing_lease_expires_at
      ELSE NULL
    END AS blocking_lease_expires_at
  FROM private.upload_sessions us
  WHERE us.uploader_id = p_user_id
    AND us.status IN ('pending', 'processing', 'sanitized');
  -- Note: this query runs AFTER the CTE has updated pending/sanitized → failed,
  -- so the status seen here for those rows is 'failed'. The CTE result is discarded;
  -- we re-select to get accurate prior state reflection.
  -- Caller checks returned rows for non-NULL blocking_lease_expires_at.
  -- 'processing' rows with active lease are returned but NOT transitioned.
END;
$$;
```

**Correction — revised implementation:** The above CTE approach conflates the quiesce and the return. Let me rewrite this more clearly with explicit steps:

```sql
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
BEGIN
  -- Step 1: Fail all pending sessions
  UPDATE private.upload_sessions
  SET status = 'failed', status_changed_at = now(), failed_reason = 'FK_ACCOUNT_DELETED'
  WHERE uploader_id = p_user_id AND status = 'pending';

  -- Step 2: Fail all sanitized sessions
  UPDATE private.upload_sessions
  SET status = 'failed', status_changed_at = now(), failed_reason = 'FK_ACCOUNT_DELETED'
  WHERE uploader_id = p_user_id AND status = 'sanitized';

  -- Step 3: Return the current state of all non-terminal, non-cleaned sessions
  -- (processing sessions are returned but NOT transitioned — caller checks lease)
  RETURN QUERY
  SELECT
    us.session_id,
    us.original_storage_path,
    us.display_storage_path,
    us.status AS prior_status,
    CASE
      WHEN us.status = 'processing' AND us.processing_lease_expires_at > now()
        THEN us.processing_lease_expires_at
      ELSE NULL::timestamptz
    END AS blocking_lease_expires_at
  FROM private.upload_sessions us
  WHERE us.uploader_id = p_user_id
    AND us.status IN ('failed', 'processing')  -- pending/sanitized now 'failed'; only these remain
    AND us.status NOT IN ('complete', 'expired', 'cleaned');
  -- complete/expired/cleaned are handled separately by get_all_upload_session_paths_for_deletion
END;
$$;
```

**Semantics:** After this function returns:
- All `pending` sessions are now `failed`.
- All `sanitized` sessions are now `failed`.
- `processing` sessions with an active lease are returned with `blocking_lease_expires_at` set; caller must wait.
- `processing` sessions with an expired lease are returned with `blocking_lease_expires_at = NULL`; caller may proceed.
- `complete`, `expired`, `failed` (from prior attempts), and `cleaned` sessions are NOT returned here; `get_all_upload_session_paths_for_deletion` covers them.

### 6.2 `public.get_upload_capability_expiry`

```sql
CREATE OR REPLACE FUNCTION public.get_upload_capability_expiry(p_user_id uuid)
RETURNS TABLE (blocking_until timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT MAX(storage_upload_expires_at + interval '30 seconds') AS blocking_until
  FROM private.upload_sessions
  WHERE uploader_id = p_user_id
    AND status != 'cleaned'
    AND storage_upload_expires_at IS NOT NULL  -- exclude NULL-expiry (no capability issued)
    AND storage_upload_expires_at + interval '30 seconds' > now();
$$;
```

Returns one row: `blocking_until = NULL` if no non-`cleaned` sessions have a non-NULL expiry still in the future; otherwise `blocking_until` = the latest expiry + 30 seconds.

### 6.3 `public.get_all_upload_session_paths_for_deletion`

```sql
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
    -- For 'complete' sessions: display path is covered by get_deletion_storage_keys
    -- (via private.media_storage_keys re_encoded_storage_key).
    -- Return NULL for display_storage_path on complete sessions to avoid double deletion.
    CASE WHEN us.status = 'complete' THEN NULL ELSE us.display_storage_path END
      AS display_storage_path,
    us.status
  FROM private.upload_sessions us
  WHERE us.uploader_id = p_user_id
    AND us.status != 'cleaned';
$$;
```

**Coverage:** Returns all sessions where `status != 'cleaned'`, including `complete`, `failed`, `expired`, `pending`, `processing`, `sanitized`. Callers must only invoke this after `get_upload_capability_expiry` returns NULL. Sessions with `storage_upload_expires_at = NULL` are included; their `original_storage_path` is deleted as a precaution (the object may or may not exist at that path).

### 6.4 `public.claim_cleanup_sessions`

This is the most complex cleanup function. It atomically transitions stale sessions, then claims eligible sessions for cleanup.

```sql
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
  -- Step 1: Transition stale pending sessions → expired
  UPDATE private.upload_sessions
  SET status = 'expired', status_changed_at = now()
  WHERE status = 'pending'
    AND expires_at + interval '60 seconds' < now()
    AND (cleanup_claim_expires_at IS NULL OR cleanup_claim_expires_at < now());

  -- Step 2: Transition stale processing sessions → failed
  UPDATE private.upload_sessions
  SET status = 'failed', status_changed_at = now(), failed_reason = 'FK_LEASE_EXPIRED'
  WHERE status = 'processing'
    AND processing_lease_expires_at < now()
    AND (cleanup_claim_expires_at IS NULL OR cleanup_claim_expires_at < now());

  -- Step 3: Transition abandoned sanitized sessions → failed
  -- Mutual exclusion with finalize_upload_session via FOR UPDATE SKIP LOCKED (below).
  -- This UPDATE is not SKIP LOCKED; it targets sessions that are not currently locked
  -- by a concurrent finalize call (finalize holds a row lock on the session).
  -- A session locked by finalize will be skipped because it does not exist in the
  -- result set here (the UPDATE will not find a row that is locked FOR UPDATE by another tx).
  -- Note: actually UPDATE does not use SKIP LOCKED by default. We need SKIP LOCKED here too.
  -- Using a CTE to SKIP LOCKED on sanitized rows:
  WITH abandoned_sanitized AS (
    SELECT session_id FROM private.upload_sessions
    WHERE status = 'sanitized'
      AND processing_lease_expires_at + interval '60 minutes' < now()
      AND (cleanup_claim_expires_at IS NULL OR cleanup_claim_expires_at < now())
    FOR UPDATE SKIP LOCKED
  )
  UPDATE private.upload_sessions us
  SET status = 'failed', status_changed_at = now(), failed_reason = 'FK_ABANDONED_SANITIZED'
  FROM abandoned_sanitized a
  WHERE us.session_id = a.session_id;

  -- Step 4: Claim eligible sessions (expired + failed) past their URL-expiry gate.
  -- Returns the claimed rows.
  RETURN QUERY
  WITH eligible AS (
    SELECT session_id FROM private.upload_sessions
    WHERE status IN ('expired', 'failed')
      AND (cleanup_claim_expires_at IS NULL OR cleanup_claim_expires_at < now())
      -- URL-expiry gate: sessions with no issued capability (NULL) have no gate;
      -- sessions with an issued capability must wait until expiry + 30s
      AND (
        storage_upload_expires_at IS NULL
        OR storage_upload_expires_at + interval '30 seconds' <= now()
      )
    FOR UPDATE SKIP LOCKED
  ),
  claimed AS (
    UPDATE private.upload_sessions us
    SET
      cleanup_claim_token     = gen_random_uuid(),
      cleanup_claimed_at      = now(),
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
```

**Mutual exclusion with `finalize_upload_session`:** `finalize_upload_session` acquires `FOR UPDATE` on the session row. `claim_cleanup_sessions` step 3 uses `FOR UPDATE SKIP LOCKED` on `sanitized` rows — any row locked by a concurrent `finalize_upload_session` is skipped. If finalize commits first (session → `complete`), step 3's WHERE clause excludes it (`status = 'sanitized'`). If step 3 wins, it sets session to `failed`; `finalize_upload_session` then sees `FK_WRONG_STATE`.

### 6.5 `public.mark_session_cleaned`

```sql
CREATE OR REPLACE FUNCTION public.mark_session_cleaned(
  p_session_id         uuid,
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

  -- Raise for complete — mark_session_cleaned must never be called on a complete session
  IF v_session.status = 'complete' THEN
    RAISE EXCEPTION 'FK_WRONG_STATE: mark_session_cleaned must not be called on a complete session';
  END IF;

  -- Already cleaned is idempotent
  IF v_session.status = 'cleaned' THEN
    RETURN;
  END IF;

  IF v_session.status NOT IN ('failed', 'expired') THEN
    RAISE EXCEPTION 'FK_WRONG_STATE: session must be failed or expired to be marked cleaned (status: %)', v_session.status;
  END IF;

  -- Verify claim token
  IF v_session.cleanup_claim_token IS DISTINCT FROM p_cleanup_claim_token THEN
    RAISE EXCEPTION 'claim token mismatch';
  END IF;

  -- Verify claim has not expired
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
```

### 6.6 `public.mark_original_path_post_expiry_cleaned`

```sql
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
```

### 6.7 `public.get_complete_sessions_pending_expiry_cleanup`

```sql
CREATE OR REPLACE FUNCTION public.get_complete_sessions_pending_expiry_cleanup()
RETURNS TABLE (session_id uuid, original_storage_path text)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT session_id, original_storage_path
  FROM private.upload_sessions
  WHERE status = 'complete'
    AND original_path_post_expiry_cleaned = false
    AND storage_upload_expires_at IS NOT NULL  -- exclude sessions where no URL was ever issued
    AND storage_upload_expires_at + interval '30 seconds' <= now();
$$;
```

Returns `complete` sessions where an upload capability was issued and has expired, and the original-path post-expiry cleanup has not yet been confirmed. The cleanup worker's Part 3 calls this, attempts to delete `original_storage_path` (absent = no-op), then calls `mark_original_path_post_expiry_cleaned`.

---

## Section 7 — Superseded Media and Media Lookup

### 7.1 `public.get_superseded_media_to_clean`

```sql
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
```

### 7.2 `public.mark_superseded_media_cleaned`

```sql
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
  -- Idempotent: no NOT FOUND check (already cleaned is fine)
END;
$$;
```

### 7.3 `public.get_media_storage_key`

```sql
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
```

Returns zero rows if the media object does not exist or `status != 'ready'`.

---

## Section 8 — Challenge Wrapper Function

### 8.1 `public.reveal_challenge_service_wrapper`

```sql
CREATE OR REPLACE FUNCTION public.reveal_challenge_service_wrapper(p_challenge_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM private.reveal_challenge_service(p_challenge_id);
END;
$$;
```

Wraps V1's `private.reveal_challenge_service` (service-role reveal entry point). Called by `scheduled-close`.

---

## Section 9 — Account Deletion Wrapper Functions

These wrappers call V1's `private` deletion functions, which are not directly accessible through PostgREST or via service_role RPC.

### 9.1 `public.prepare_account_deletion_wrapper`

```sql
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

  -- No record, 'pending', or 'failed' — proceed with preparation
  PERFORM private.prepare_account_deletion(p_user_id);

  RETURN 'database_prepared';
END;
$$;
```

### 9.2 `public.get_deletion_storage_keys`

```sql
CREATE OR REPLACE FUNCTION public.get_deletion_storage_keys(p_user_id uuid)
RETURNS TABLE (media_object_id uuid, storage_key text)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT * FROM private.get_storage_keys_for_deletion(p_user_id);
$$;
```

Wraps V1's `private.get_storage_keys_for_deletion`. Returns established media storage keys (both `storage_key` and `re_encoded_storage_key` via UNION in V1's implementation).

### 9.3 `public.record_deletion_failure_wrapper`

```sql
CREATE OR REPLACE FUNCTION public.record_deletion_failure_wrapper(
  p_user_id    uuid,
  p_error_code text
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM private.record_deletion_failure(p_user_id, substring(p_error_code FROM 1 FOR 100));
END;
$$;
```

### 9.4 `public.mark_auth_deleted_wrapper`

```sql
CREATE OR REPLACE FUNCTION public.mark_auth_deleted_wrapper(p_user_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM private.mark_auth_deleted(p_user_id);
END;
$$;
```

### 9.5 `public.mark_storage_cleaned_wrapper`

```sql
CREATE OR REPLACE FUNCTION public.mark_storage_cleaned_wrapper(p_user_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM private.mark_storage_cleaned(p_user_id);
END;
$$;
```

---

## Section 10 — Deletion Recovery Worker Functions

### 10.1 `public.claim_deletion_recovery_records`

```sql
CREATE OR REPLACE FUNCTION public.claim_deletion_recovery_records(
  p_worker_id          text,
  p_scan_age_threshold interval DEFAULT interval '10 minutes',
  p_claim_duration     interval DEFAULT interval '10 minutes'
)
RETURNS TABLE (user_id uuid, scan_type text, claim_token uuid)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  RETURN QUERY
  WITH claimable AS (
    -- 'database_prepared' records older than scan_age_threshold
    SELECT dl.profile_id, 'database_prepared'::text AS scan_type
    FROM private.deletion_log dl
    WHERE dl.status = 'database_prepared'
      AND dl.db_prepared_at < now() - p_scan_age_threshold
      AND NOT EXISTS (
        SELECT 1 FROM private.deletion_recovery_claims drc
        WHERE drc.user_id = dl.profile_id
          AND drc.claim_expires_at > now()
      )
    UNION ALL
    -- all 'auth_deleted' records without an unexpired claim
    SELECT dl.profile_id, 'auth_deleted'::text AS scan_type
    FROM private.deletion_log dl
    WHERE dl.status = 'auth_deleted'
      AND NOT EXISTS (
        SELECT 1 FROM private.deletion_recovery_claims drc
        WHERE drc.user_id = dl.profile_id
          AND drc.claim_expires_at > now()
      )
  ),
  upserted AS (
    INSERT INTO private.deletion_recovery_claims (
      user_id, scan_type, claim_token, claimed_at, claim_expires_at
    )
    SELECT
      c.profile_id,
      c.scan_type,
      gen_random_uuid(),
      now(),
      now() + p_claim_duration
    FROM claimable c
    ON CONFLICT (user_id) DO UPDATE
      SET scan_type        = EXCLUDED.scan_type,
          claim_token      = EXCLUDED.claim_token,
          claimed_at       = EXCLUDED.claimed_at,
          claim_expires_at = EXCLUDED.claim_expires_at
    RETURNING user_id, scan_type, claim_token
  )
  SELECT u.user_id, u.scan_type, u.claim_token FROM upserted u;
END;
$$;
```

### 10.2 `public.complete_deletion_recovery`

```sql
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

  -- Verify scan_type matches what was recorded when the claim was issued
  IF v_claim.scan_type IS DISTINCT FROM p_scan_type THEN
    RAISE EXCEPTION 'scan_type mismatch: expected %, got %', v_claim.scan_type, p_scan_type;
  END IF;

  -- Advance deletion state based on scan_type
  IF p_scan_type = 'database_prepared' THEN
    PERFORM private.mark_auth_deleted(p_user_id);
    PERFORM private.mark_storage_cleaned(p_user_id);
  ELSIF p_scan_type = 'auth_deleted' THEN
    PERFORM private.mark_storage_cleaned(p_user_id);
  ELSE
    RAISE EXCEPTION 'unrecognized scan_type: %', p_scan_type;
  END IF;

  -- Remove the claim record
  DELETE FROM private.deletion_recovery_claims WHERE user_id = p_user_id;
END;
$$;
```

### 10.3 `public.fail_deletion_recovery`

```sql
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

  -- Record the failure
  PERFORM private.record_deletion_failure(p_user_id, substring(p_error_code FROM 1 FOR 100));

  -- Remove the claim (allow re-claiming on next worker run)
  DELETE FROM private.deletion_recovery_claims WHERE user_id = p_user_id;
END;
$$;
```

---

## Section 11 — Schema Grants and Ownership

```sql
-- Grant forkensics_executor read/write access to the new private tables.
-- (Schema USAGE and CREATE already granted to forkensics_executor in V1.)
GRANT SELECT, INSERT, UPDATE ON private.upload_sessions           TO forkensics_executor;
GRANT SELECT, INSERT, UPDATE, DELETE ON private.deletion_recovery_claims TO forkensics_executor;

-- Transfer ownership of both new trigger functions
ALTER FUNCTION private.check_activation_no_active_upload()  OWNER TO forkensics_executor;
ALTER FUNCTION private.check_activation_media_ready()       OWNER TO forkensics_executor;

-- All new public SECURITY DEFINER functions: revoke from PUBLIC, grant only to service_role
-- (repeated for every function listed in Sections 5–10)
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
    'public.finalize_upload_session(uuid)',
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

-- Transfer ownership of all new public functions to forkensics_executor
ALTER FUNCTION public.reserve_upload_session(uuid,uuid,text,text,bigint,timestamptz)   OWNER TO forkensics_executor;
ALTER FUNCTION public.activate_upload_session(uuid,timestamptz)                         OWNER TO forkensics_executor;
ALTER FUNCTION public.resolve_upload_session(text,uuid)                                 OWNER TO forkensics_executor;
ALTER FUNCTION public.advance_upload_session_processing(uuid,uuid,interval)             OWNER TO forkensics_executor;
ALTER FUNCTION public.check_upload_session_lease(uuid)                                  OWNER TO forkensics_executor;
ALTER FUNCTION public.advance_upload_session_sanitized(uuid)                            OWNER TO forkensics_executor;
ALTER FUNCTION public.finalize_upload_session(uuid)                                     OWNER TO forkensics_executor;
ALTER FUNCTION public.fail_upload_session(uuid,text)                                    OWNER TO forkensics_executor;
ALTER FUNCTION public.quiesce_upload_sessions_for_deletion(uuid)                        OWNER TO forkensics_executor;
ALTER FUNCTION public.get_upload_capability_expiry(uuid)                                OWNER TO forkensics_executor;
ALTER FUNCTION public.get_all_upload_session_paths_for_deletion(uuid)                   OWNER TO forkensics_executor;
ALTER FUNCTION public.claim_cleanup_sessions(text,interval)                             OWNER TO forkensics_executor;
ALTER FUNCTION public.mark_session_cleaned(uuid,uuid)                                   OWNER TO forkensics_executor;
ALTER FUNCTION public.mark_original_path_post_expiry_cleaned(uuid)                      OWNER TO forkensics_executor;
ALTER FUNCTION public.get_complete_sessions_pending_expiry_cleanup()                    OWNER TO forkensics_executor;
ALTER FUNCTION public.get_superseded_media_to_clean()                                   OWNER TO forkensics_executor;
ALTER FUNCTION public.mark_superseded_media_cleaned(uuid)                               OWNER TO forkensics_executor;
ALTER FUNCTION public.get_media_storage_key(uuid)                                       OWNER TO forkensics_executor;
ALTER FUNCTION public.reveal_challenge_service_wrapper(uuid)                            OWNER TO forkensics_executor;
ALTER FUNCTION public.prepare_account_deletion_wrapper(uuid)                            OWNER TO forkensics_executor;
ALTER FUNCTION public.get_deletion_storage_keys(uuid)                                   OWNER TO forkensics_executor;
ALTER FUNCTION public.record_deletion_failure_wrapper(uuid,text)                        OWNER TO forkensics_executor;
ALTER FUNCTION public.mark_auth_deleted_wrapper(uuid)                                   OWNER TO forkensics_executor;
ALTER FUNCTION public.mark_storage_cleaned_wrapper(uuid)                                OWNER TO forkensics_executor;
ALTER FUNCTION public.claim_deletion_recovery_records(text,interval,interval)           OWNER TO forkensics_executor;
ALTER FUNCTION public.complete_deletion_recovery(uuid,uuid,text)                        OWNER TO forkensics_executor;
ALTER FUNCTION public.fail_deletion_recovery(uuid,uuid,text)                            OWNER TO forkensics_executor;
```

---

## Section 12 — Migration Structure

The executable `V2__upload_sessions.sql` will have the following sections, in order:

```
1. Migration guard: confirm V1 is applied (check existence of private.deletion_log)
2. Table DDL: private.upload_sessions
3. Table DDL: private.deletion_recovery_claims
4. Constraint modification: public.media_objects status check
5. Indexes: all named indexes from Section 2.2 and 2.3
6. Trigger functions: check_activation_no_active_upload, check_activation_media_ready
7. Trigger attachments: challenge_v2_no_active_upload_on_activate, challenge_v2_media_ready_on_activate
8. Functions: Sections 5–10 (27 functions, in dependency order)
9. Grants and ownership: Section 11
10. Completion marker comment
```

**Migration guard (step 1):**
```sql
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
```

**Failure stop rule:** If any statement in the migration fails, stop immediately. Do not attempt to repair. Return the PostgreSQL error and the position in the migration for review. The migration will be wrapped in a single transaction where possible (DDL in PostgreSQL is transactional except for some operations like `CREATE INDEX CONCURRENTLY`; all operations here are compatible with transaction wrapping).

---

## Section 13 — Acceptance Criteria and Test Plan

The V2 migration will be accompanied by `V2_acceptance_tests.sql`, written after approval and run before deployment. Tests follow the same pattern as `V1_acceptance_tests.sql`.

### 13.1 Schema verification

- `private.upload_sessions` exists with all 20 columns and correct types
- `private.deletion_recovery_claims` exists with all 5 columns
- `upload_sessions_one_active_per_challenge` partial unique index is present and enforced
- All 5 named indexes on `upload_sessions` exist
- `media_objects_status_check` constraint allows 'superseded' and 'cleaned'
- Both V2 triggers exist on `public.challenges`
- All 27 functions exist with correct signatures

### 13.2 Partial unique index enforcement

- INSERT two `pending` sessions for the same `challenge_id` → second INSERT violates unique index
- INSERT `pending` then `complete` session for same challenge → allowed (complete excluded from index)
- INSERT `failed` then `pending` session for same challenge → allowed (failed excluded)

### 13.3 reserve_upload_session

- Challenge not found → `FK_NOT_FOUND`
- Challenge found but poster_id mismatch → `FK_NOT_FOUND`
- Challenge in `active` state → `FK_WRONG_STATE`
- Uploader has `database_prepared` deletion record → `FK_FORBIDDEN`
- Uploader has `auth_deleted` deletion record → `FK_FORBIDDEN`
- Active session already exists → `FK_UPLOAD_IN_PROGRESS` (unique index violation)
- Happy path → returns `(session_id, original_storage_path, display_storage_path)`; `storage_upload_expires_at = NULL`; `status = 'pending'`
- Storage paths follow format `challenges/{challenge_id}/originals/{session_id}` and `challenges/{challenge_id}/displays/{session_id}.webp`

### 13.4 activate_upload_session

- `status = 'pending'`, `storage_upload_expires_at = NULL` → sets expiry; returns void
- `status = 'pending'`, `storage_upload_expires_at` already set → raises `FK_WRONG_STATE`
- `status = 'failed'` → raises `FK_WRONG_STATE`
- `status = 'complete'` → raises `FK_WRONG_STATE`
- Session not found → raises (NOT FOUND, since UPDATE with no match)

### 13.5 fail_upload_session

- `status = 'complete'` → raises `FK_WRONG_STATE`
- `status = 'pending'` (NULL expiry) → transitions to `failed`; `failed_reason` set
- `status = 'pending'` (non-NULL expiry) → transitions to `failed`
- `status = 'failed'` → idempotent; no error
- `status = 'processing'` → transitions to `failed`

### 13.6 advance_upload_session_processing

- Uploader mismatch → `FK_INVALID_TOKEN`
- Not pending → `FK_INVALID_TOKEN`
- Expired (expires_at in past) → `FK_INVALID_TOKEN`
- Happy path → transitions to `processing`; sets `processing_lease_expires_at`; returns paths

### 13.7 check_upload_session_lease

- `processing` with future lease → true
- `processing` with expired lease → false
- `pending` → false
- `complete` → false

### 13.8 advance_upload_session_sanitized

- `status = 'processing'` → transitions to `sanitized`
- `status != 'processing'` → raises `FK_WRONG_STATE`

### 13.9 finalize_upload_session

- `status = 'sanitized'`, `challenge.state = 'draft'` → inserts media_objects, media_storage_keys; sets challenge.media_object_id; transitions to `complete`; returns IDs
- `status = 'complete'` → idempotent; returns stored IDs
- `status = 'failed'` → raises `FK_WRONG_STATE`
- `challenge.state = 'active'` → raises `FK_WRONG_STATE`
- Replacing existing media_object_id → old media_objects.status = 'superseded'; `replaced_media_object_id` non-NULL
- New media_objects row has `mime_type = 'image/webp'`, `status = 'ready'`, `re_encoded_at` set
- `media_storage_keys.storage_key = original_path`; `re_encoded_storage_key = display_path`

### 13.10 claim_cleanup_sessions

- Stale pending (expires_at + 60s past) → transitions to `expired` and claims
- Stale processing (lease expired) → transitions to `failed` and claims
- Abandoned sanitized (lease + 60min past) → transitions to `failed` and claims; skips if locked by concurrent finalize
- Session with `storage_upload_expires_at IS NULL` → claimed without URL-expiry gate
- Session with `storage_upload_expires_at + 30s > now()` (URL still valid) → NOT claimed
- Session with `storage_upload_expires_at + 30s <= now()` (URL expired) → claimed
- `complete` sessions → never returned

### 13.11 mark_session_cleaned

- Valid claim, `status = 'failed'` → transitions to `cleaned`
- Valid claim, `status = 'expired'` → transitions to `cleaned`
- `status = 'complete'` → raises `FK_WRONG_STATE`
- `status = 'cleaned'` → idempotent
- Token mismatch → raises
- Claim expired → raises

### 13.12 get_upload_capability_expiry

- Sessions with `storage_upload_expires_at IS NOT NULL` and `+ 30s > now()` → returns max
- Sessions with `storage_upload_expires_at IS NULL` → excluded from calculation
- All non-NULL expiries past → returns NULL
- No non-cleaned sessions → returns NULL

### 13.13 quiesce_upload_sessions_for_deletion

- `pending` sessions → transitioned to `failed`; returned with `blocking_lease_expires_at = NULL`
- `sanitized` sessions → transitioned to `failed`; returned
- `processing` with active lease → returned with `blocking_lease_expires_at` set; NOT transitioned
- `processing` with expired lease → returned with `blocking_lease_expires_at = NULL`
- `complete` / `expired` / `failed` (prior) / `cleaned` → NOT returned

### 13.14 get_all_upload_session_paths_for_deletion

- Returns all sessions where `status != 'cleaned'` for given user
- `complete` sessions: `display_storage_path = NULL`; `original_storage_path` included
- `failed` / `expired` sessions: both paths included
- NULL-expiry sessions included
- `cleaned` sessions excluded

### 13.15 V2 triggers on challenges

- `reserve_upload_session` inserts session; then attempt `activate_challenge` (via direct UPDATE to simulate) → trigger raises exception
- Session transitions to `complete` → `activate_challenge` trigger no longer blocks
- Session transitions to `failed` → `activate_challenge` trigger no longer blocks
- `media_object_id` pointing to `status = 'superseded'` → trigger raises
- `media_object_id` pointing to `status = 'ready'` → trigger passes

### 13.16 Permission verification

- Service role can execute all 27 new functions
- Authenticated role cannot execute any of the 27 new functions
- `private.upload_sessions` is not accessible through PostgREST (no RLS policy; schema not exposed)
- `private.deletion_recovery_claims` is not accessible through PostgREST

### 13.17 Concurrent safety (advisory)

These cannot be verified in a single-session SQL test runner; they are documented for manual verification and are covered by the contract tests in Step 24 Section 5:

- `reserve_upload_session` holding challenge lock blocks concurrent `prepare_account_deletion_wrapper` that writes to the same challenge row
- `finalize_upload_session` holding session lock prevents concurrent `claim_cleanup_sessions` from transitioning the same session
- `claim_cleanup_sessions` `SKIP LOCKED` on sanitized rows does not block a concurrent `finalize_upload_session` — it skips the locked row

---

## Section 14 — Risks

**Risk 1: `prepare_account_deletion` private function signature.** The wrapper in Section 9.1 calls `private.prepare_account_deletion(p_user_id)`. This function exists in V1 but its exact signature must be confirmed against V1's migration before the V2 file is finalized. If the signature differs (e.g., returns a value, takes additional arguments), the wrapper must be adjusted.

**Mitigation:** Verify with `\df private.prepare_account_deletion` in dev before writing the executable migration.

**Risk 2: `private.reveal_challenge_service` existence.** Section 8.1 wraps this V1 function. Same verification step applies.

**Mitigation:** Same — confirm via `\df` before finalizing.

**Risk 3: `private.record_deletion_failure`, `private.mark_auth_deleted`, `private.mark_storage_cleaned` signatures.** All three are called from Sections 9.3–9.5 and Section 10.2–10.3. Confirm each before writing executable SQL.

**Mitigation:** Same.

**Risk 4: media_objects.status constraint DROP + ADD.** If any V1 code path sets `status` to a value not in the new constraint (e.g., `NULL`) during the microsecond between DROP and ADD, the migration could fail. In practice, `status` has `NOT NULL DEFAULT 'processing'` so this is not a concern; the DROP/ADD is atomic within the migration transaction.

**Risk 5: Trigger ordering.** The three BEFORE UPDATE triggers on `public.challenges` fire alphabetically (`challenge_protect_fields`, `challenge_v2_media_ready_on_activate`, `challenge_v2_no_active_upload_on_activate`). `challenge_protect_fields` bypasses for `forkensics_executor`. The two V2 triggers fire after and perform their checks. This ordering is correct.

**Risk 6: `claim_cleanup_sessions` step 3 race with `finalize_upload_session`.** The `FOR UPDATE SKIP LOCKED` on sanitized rows in step 3 skips rows locked by a concurrent `finalize_upload_session`. However, `finalize_upload_session` does a `FOR UPDATE` on the session row, which is a plain `SELECT ... FOR UPDATE` (not SKIP LOCKED). If `claim_cleanup_sessions` acquires the lock on the sanitized row first (step 3), then `finalize_upload_session` will wait, eventually see `status = 'failed'`, and raise `FK_WRONG_STATE`. If `finalize_upload_session` acquires the lock first, step 3's SKIP LOCKED skips the row; finalize completes; the session is now `complete` and step 4's WHERE clause (`status IN ('expired','failed')`) excludes it. Both orderings are safe.

---

## Section 15 — Out of Scope for Step 25

- Executable `V2__upload_sessions.sql` file (created after approval)
- `V2_acceptance_tests.sql` (created after approval, run before deployment)
- Git commit and tag (separate step following acceptance test pass)
- Deployment to forkensics-dev or forkensics-prod (requires separate deployment approvals)
- Edge Function implementation (separate per-function steps)

---

## Success Criteria for Step 25

- [ ] Both private tables agreed with all columns, types, and constraints
- [ ] Partial unique index agreed
- [ ] `media_objects` status expansion agreed
- [ ] Both V2 triggers on `public.challenges` agreed including ordering
- [ ] All 27 SECURITY DEFINER function bodies reviewed and agreed
- [ ] `reserve_upload_session` challenge lock and deletion check agreed
- [ ] `activate_upload_session` atomicity guarantee agreed
- [ ] `finalize_upload_session` media_objects insertion, storage key insertion, and supersession swap agreed
- [ ] `claim_cleanup_sessions` SKIP LOCKED mutual exclusion agreed
- [ ] `get_upload_capability_expiry` NULL-exclusion agreed
- [ ] All deletion and recovery wrapper functions agreed
- [ ] Grant strategy (service_role only; REVOKE from PUBLIC/authenticated/anon) agreed
- [ ] Migration guard and failure stop rule agreed
- [ ] V1 private function signatures to be confirmed before executable SQL is written
- [ ] No executable migration written until governance approval
