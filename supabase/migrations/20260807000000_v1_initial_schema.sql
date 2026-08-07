-- =============================================================================
-- Forkensics — V1 Initial Schema Migration
-- Covers: Rev 4 + Rev 4.1 + Rev 4.2 + Rev 4.2a + Rev 4.2b (Step 2 approved)
-- Governance: SQL generated after APPROVED: Step 2 — Supabase Project & Database Schema
-- Deployment: NOT authorised for live deployment until separate SQL-security review
--             and Bill's explicit deployment approval.
-- =============================================================================

-- ============================================================
-- SECTION 1 — ROLES
-- ============================================================

DO $$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'forkensics_executor') THEN
    CREATE ROLE forkensics_executor NOLOGIN BYPASSRLS;
  END IF;
END $$;
-- Idempotent: ensures BYPASSRLS even if the role existed before this migration ran
ALTER ROLE forkensics_executor BYPASSRLS;

DO $$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'forkensics_rls_helper') THEN
    CREATE ROLE forkensics_rls_helper NOLOGIN BYPASSRLS;
  END IF;
END $$;
ALTER ROLE forkensics_rls_helper BYPASSRLS;

-- Grant role membership to postgres so it can transfer ownership (required in PG 16+,
-- even for superusers). Safe on hosted Supabase where postgres already has this implicitly.
GRANT forkensics_executor    TO postgres;
GRANT forkensics_rls_helper  TO postgres;


-- ============================================================
-- SECTION 2 — SCHEMAS
-- ============================================================

CREATE SCHEMA IF NOT EXISTS private;

-- Public schema: Supabase sets these at the platform level, but we declare them
-- explicitly so the migration is self-sufficient for local development / CI.
GRANT USAGE ON SCHEMA public TO authenticated, anon, service_role;

-- extensions schema: forkensics_executor uses pgcrypto (gen_random_bytes, digest)
-- for invite token generation. postgres owns extensions and can grant here.
GRANT USAGE ON SCHEMA extensions TO forkensics_executor;
GRANT EXECUTE ON FUNCTION extensions.gen_random_bytes(integer)   TO forkensics_executor;
GRANT EXECUTE ON FUNCTION extensions.digest(bytea, text)         TO forkensics_executor;
GRANT EXECUTE ON FUNCTION extensions.digest(text, text)          TO forkensics_executor;

-- Note: auth schema grants (USAGE, EXECUTE on auth.uid()) are managed by supabase_admin
-- and cannot be granted by postgres. All SECURITY DEFINER functions use
-- private.auth_uid() instead (see Section 6A), which reads JWT claims directly
-- via pg_catalog.current_setting without requiring auth schema access.

REVOKE ALL ON SCHEMA private FROM PUBLIC, anon, authenticated;
GRANT USAGE ON SCHEMA private TO forkensics_executor, forkensics_rls_helper, service_role;
-- CREATE privilege required so each role can own functions in its schema (PG 16+ enforcement).
-- These are NOLOGIN roles; granting CREATE does not open a direct-connection attack surface.
GRANT CREATE ON SCHEMA private TO forkensics_rls_helper, forkensics_executor;
GRANT CREATE ON SCHEMA public  TO forkensics_executor;


-- ============================================================
-- SECTION 3 — SEQUENCE
-- ============================================================

CREATE SEQUENCE IF NOT EXISTS public.guess_receipt_seq
  START 1 INCREMENT 1 NO CYCLE;

-- authenticated cannot touch the sequence directly; trigger runs as forkensics_executor
REVOKE ALL ON SEQUENCE public.guess_receipt_seq FROM PUBLIC, anon, authenticated;
GRANT USAGE, SELECT ON SEQUENCE public.guess_receipt_seq TO forkensics_executor;


-- ============================================================
-- SECTION 4 — TABLES (dependency order)
-- ============================================================

-- ------------------------------------------------------------
-- 4.1  profiles
-- NOTE: avatar_media_object_id FK added after media_objects is created
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.profiles (
  id                       uuid        PRIMARY KEY,
  -- NOTE: No FK to auth.users(id). Profiles intentionally outlive Auth records so that
  -- historical challenges, guesses, and scores retain a stable anonymised player row
  -- after account deletion. The anonymisation step (prepare_account_deletion) runs
  -- before the Auth user is removed; the profile must not be cascade-deleted.
  display_name             text,
  avatar_color             text        NOT NULL DEFAULT 'orange',
  avatar_media_object_id   uuid,       -- FK added below after media_objects
  onboarding_complete      boolean     NOT NULL DEFAULT false,
  is_active                boolean     NOT NULL DEFAULT true,
  created_at               timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT profiles_avatar_color_check CHECK (
    (is_active = true  AND avatar_color IN ('orange','red','blue','green','purple','yellow','pink','teal'))
    OR
    (is_active = false AND avatar_color = 'gray')
  ),
  CONSTRAINT profiles_display_name_check CHECK (
    onboarding_complete = false
    OR (display_name IS NOT NULL AND length(trim(display_name)) BETWEEN 1 AND 50)
  )
);

ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;

-- ------------------------------------------------------------
-- 4.2  rules_versions
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.rules_versions (
  id           uuid        PRIMARY KEY,
  version_tag  text        NOT NULL UNIQUE,
  description  text        NOT NULL,
  config       jsonb       NOT NULL,
  created_at   timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.rules_versions ENABLE ROW LEVEL SECURITY;

-- BEFORE UPDATE/DELETE guard prevents modification (applied in trigger section)

-- ------------------------------------------------------------
-- 4.3  media_objects
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.media_objects (
  id               uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  uploader_id      uuid        NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  mime_type        text        NOT NULL,
  file_size_bytes  integer,
  status           text        NOT NULL DEFAULT 'processing',
  re_encoded_at    timestamptz,
  created_at       timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT media_objects_status_check CHECK (status IN ('processing','ready','failed','deleted'))
);

ALTER TABLE public.media_objects ENABLE ROW LEVEL SECURITY;

-- Now add the FK from profiles → media_objects
ALTER TABLE public.profiles
  ADD CONSTRAINT profiles_avatar_media_object_fk
    FOREIGN KEY (avatar_media_object_id)
    REFERENCES public.media_objects(id) ON DELETE SET NULL;

-- ------------------------------------------------------------
-- 4.4  private.media_storage_keys  (server-only; no client access)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS private.media_storage_keys (
  media_object_id         uuid  PRIMARY KEY
                                REFERENCES public.media_objects(id) ON DELETE CASCADE,
  storage_key             text  NOT NULL,
  re_encoded_storage_key  text
);

-- ------------------------------------------------------------
-- 4.5  groups
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.groups (
  id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  name         text        NOT NULL,
  created_by   uuid        NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  created_at   timestamptz NOT NULL DEFAULT clock_timestamp(),
  archived_at  timestamptz,
  CONSTRAINT groups_name_check CHECK (length(trim(name)) BETWEEN 1 AND 100)
);

ALTER TABLE public.groups ENABLE ROW LEVEL SECURITY;

-- ------------------------------------------------------------
-- 4.6  group_members
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.group_members (
  group_id   uuid        NOT NULL REFERENCES public.groups(id)   ON DELETE CASCADE,
  player_id  uuid        NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  joined_at  timestamptz NOT NULL DEFAULT clock_timestamp(),
  role       text        NOT NULL DEFAULT 'member',
  PRIMARY KEY (group_id, player_id),
  CONSTRAINT group_members_role_check CHECK (role IN ('owner','member'))
);

ALTER TABLE public.group_members ENABLE ROW LEVEL SECURITY;

-- One owner per group
CREATE UNIQUE INDEX IF NOT EXISTS one_owner_per_group
  ON public.group_members (group_id) WHERE role = 'owner';

-- ------------------------------------------------------------
-- 4.7  group_invites
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.group_invites (
  id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  group_id     uuid        NOT NULL REFERENCES public.groups(id)   ON DELETE CASCADE,
  created_by   uuid        NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  token_hash   text        NOT NULL UNIQUE,
  created_at   timestamptz NOT NULL DEFAULT clock_timestamp(),
  expires_at   timestamptz NOT NULL,
  accepted_by  uuid        REFERENCES public.profiles(id) ON DELETE RESTRICT,
  accepted_at  timestamptz,
  revoked_at   timestamptz,
  revoked_by   uuid        REFERENCES public.profiles(id) ON DELETE RESTRICT
);

ALTER TABLE public.group_invites ENABLE ROW LEVEL SECURITY;

-- ------------------------------------------------------------
-- 4.8  challenges
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.challenges (
  id                   uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  poster_id            uuid        NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  group_id             uuid        NOT NULL REFERENCES public.groups(id)   ON DELETE RESTRICT,
  state                text        NOT NULL DEFAULT 'draft',
  media_object_id      uuid        REFERENCES public.media_objects(id)     ON DELETE RESTRICT,
  duration_seconds     integer     NOT NULL DEFAULT 7200,
  public_city_display  text,
  rules_version_id     uuid        NOT NULL
                                   DEFAULT 'a0000000-0000-0000-0000-000000000001'
                                   REFERENCES public.rules_versions(id) ON DELETE RESTRICT,
  posted_at            timestamptz,
  deadline_at          timestamptz,
  locked_at            timestamptz,
  revealed_at          timestamptz,
  cancelled_at         timestamptz,
  cancellation_reason  text,
  created_at           timestamptz NOT NULL DEFAULT clock_timestamp(),

  CONSTRAINT challenges_state_check
    CHECK (state IN ('draft','active','locked','revealed','cancelled')),

  CONSTRAINT challenges_duration_check
    CHECK (duration_seconds BETWEEN 3600 AND 86400
           AND duration_seconds % 3600 = 0),

  CONSTRAINT challenges_cancellation_check
    CHECK (cancellation_reason IS NULL OR length(cancellation_reason) <= 500),

  -- City is optional context; NULL when omitted, trimmed 1–100 chars when present
  CONSTRAINT challenges_city_display_check CHECK (
    public_city_display IS NULL
    OR length(trim(public_city_display)) BETWEEN 1 AND 100
  )
);

ALTER TABLE public.challenges ENABLE ROW LEVEL SECURITY;

-- One active challenge per poster at a time
CREATE UNIQUE INDEX IF NOT EXISTS one_active_challenge_per_poster
  ON public.challenges (poster_id)
  WHERE state IN ('draft','active','locked');

-- ------------------------------------------------------------
-- 4.9  challenge_secrets
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.challenge_secrets (
  challenge_id          uuid        PRIMARY KEY
                                    REFERENCES public.challenges(id) ON DELETE CASCADE,
  display_dish          text        NOT NULL,
  canonical_dish        text        NOT NULL,
  display_restaurant    text        NOT NULL,
  canonical_restaurant  text        NOT NULL,
  story                 text,
  has_first_guess       boolean     NOT NULL DEFAULT false,
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT cs_display_dish_check      CHECK (length(trim(display_dish))         BETWEEN 1 AND 200),
  CONSTRAINT cs_canonical_dish_check    CHECK (length(canonical_dish)             BETWEEN 1 AND 200),
  CONSTRAINT cs_display_rest_check      CHECK (length(trim(display_restaurant))   BETWEEN 1 AND 200),
  CONSTRAINT cs_canonical_rest_check    CHECK (length(canonical_restaurant)       BETWEEN 1 AND 200),
  CONSTRAINT cs_story_check             CHECK (story IS NULL OR length(story) <= 2000)
);

ALTER TABLE public.challenge_secrets ENABLE ROW LEVEL SECURITY;

-- ------------------------------------------------------------
-- 4.10  challenge_answer_aliases
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.challenge_answer_aliases (
  id                uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  challenge_id      uuid        NOT NULL REFERENCES public.challenges(id) ON DELETE CASCADE,
  field             text        NOT NULL,
  display_value     text        NOT NULL,
  normalized_value  text        NOT NULL,
  created_by        uuid        NOT NULL REFERENCES public.profiles(id)  ON DELETE RESTRICT,
  created_at        timestamptz NOT NULL DEFAULT now(),
  is_active         boolean     NOT NULL DEFAULT true,

  CONSTRAINT caa_field_check
    CHECK (field IN ('dish','restaurant')),
  CONSTRAINT caa_display_check
    CHECK (length(trim(display_value)) BETWEEN 1 AND 200),
  CONSTRAINT caa_normalized_check
    CHECK (length(normalized_value) BETWEEN 1 AND 200)
);

ALTER TABLE public.challenge_answer_aliases ENABLE ROW LEVEL SECURITY;

-- ------------------------------------------------------------
-- 4.11  eligible_participants
-- Immutable snapshot at activation; poster excluded
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.eligible_participants (
  id                    uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  challenge_id          uuid        NOT NULL REFERENCES public.challenges(id) ON DELETE RESTRICT,
  player_id             uuid        NOT NULL REFERENCES public.profiles(id)  ON DELETE RESTRICT,
  snapshot_avatar_color text        NOT NULL,
  added_at              timestamptz NOT NULL DEFAULT clock_timestamp(),
  UNIQUE (challenge_id, player_id)
);

ALTER TABLE public.eligible_participants ENABLE ROW LEVEL SECURITY;

-- ------------------------------------------------------------
-- 4.12  exclusion_events  (append-only)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.exclusion_events (
  id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  challenge_id  uuid        NOT NULL REFERENCES public.challenges(id) ON DELETE RESTRICT,
  player_id     uuid        NOT NULL REFERENCES public.profiles(id)  ON DELETE RESTRICT,
  reason        text        NOT NULL,
  excluded_by   uuid        REFERENCES public.profiles(id) ON DELETE RESTRICT,  -- NULL = system
  excluded_at   timestamptz NOT NULL DEFAULT clock_timestamp(),
  UNIQUE (challenge_id, player_id),

  CONSTRAINT ee_reason_check
    CHECK (reason IN ('withdrew','removed','account_deleted')),

  CONSTRAINT ee_excluded_by_check CHECK (
    (reason IN ('withdrew','removed') AND excluded_by IS NOT NULL)
    OR
    (reason = 'account_deleted'       AND excluded_by IS NULL)
  )
);

ALTER TABLE public.exclusion_events ENABLE ROW LEVEL SECURITY;

-- ------------------------------------------------------------
-- 4.13  clues  (renamed from hints)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.clues (
  id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  challenge_id  uuid        NOT NULL REFERENCES public.challenges(id) ON DELETE RESTRICT,
  poster_id     uuid        NOT NULL REFERENCES public.profiles(id)  ON DELETE RESTRICT,
  text          text        NOT NULL,
  posted_at     timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT clues_text_check CHECK (length(trim(text)) BETWEEN 1 AND 500)
);

ALTER TABLE public.clues ENABLE ROW LEVEL SECURITY;

-- ------------------------------------------------------------
-- 4.14  guess_attempts  (immutable append-only)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.guess_attempts (
  id                   uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  challenge_id         uuid        NOT NULL REFERENCES public.challenges(id) ON DELETE RESTRICT,
  player_id            uuid        NOT NULL REFERENCES public.profiles(id)  ON DELETE RESTRICT,
  race                 text        NOT NULL,
  dish_guess           text,
  restaurant_guess     text,
  received_at          timestamptz NOT NULL DEFAULT clock_timestamp(),
  receipt_sequence     bigint      NOT NULL,
  client_submitted_at  timestamptz,
  UNIQUE (challenge_id, receipt_sequence),

  CONSTRAINT ga_race_check
    CHECK (race IN ('what','where')),

  CONSTRAINT ga_race_fields_check CHECK (
    (race = 'what'
     AND dish_guess IS NOT NULL AND length(trim(dish_guess)) BETWEEN 1 AND 200
     AND restaurant_guess IS NULL)
    OR
    (race = 'where'
     AND dish_guess IS NULL
     AND restaurant_guess IS NOT NULL AND length(trim(restaurant_guess)) BETWEEN 1 AND 200)
  )
);

ALTER TABLE public.guess_attempts ENABLE ROW LEVEL SECURITY;

-- ------------------------------------------------------------
-- 4.15  correction_events
-- Cross-FK to score_runs added after score_runs is created
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.correction_events (
  id                      uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  challenge_id            uuid        NOT NULL REFERENCES public.challenges(id)             ON DELETE RESTRICT,
  corrected_by            uuid        NOT NULL REFERENCES public.profiles(id)               ON DELETE RESTRICT,
  action                  text        NOT NULL,
  target_field            text        NOT NULL,
  alias_id                uuid,       -- FK to challenge_answer_aliases added below
  old_display_value       text,
  new_display_value       text,
  old_normalized_value    text,
  new_normalized_value    text,
  reason                  text        NOT NULL,
  resulting_score_run_id  uuid,       -- FK to score_runs added below
  corrected_at            timestamptz NOT NULL DEFAULT clock_timestamp(),

  CONSTRAINT ce_action_check
    CHECK (action IN ('answer_changed','alias_added','alias_removed')),
  CONSTRAINT ce_target_check
    CHECK (target_field IN ('dish','restaurant')),
  CONSTRAINT ce_reason_check
    CHECK (length(trim(reason)) BETWEEN 1 AND 500),
  CONSTRAINT ce_new_value_check
    CHECK (new_display_value IS NULL OR length(trim(new_display_value)) BETWEEN 1 AND 200)
);

ALTER TABLE public.correction_events ENABLE ROW LEVEL SECURITY;

-- ------------------------------------------------------------
-- 4.16  score_runs
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.score_runs (
  id                        uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  challenge_id              uuid        NOT NULL REFERENCES public.challenges(id)        ON DELETE RESTRICT,
  revision_number           integer     NOT NULL,
  rules_version_id          uuid        NOT NULL REFERENCES public.rules_versions(id)   ON DELETE RESTRICT,
  effective_eligible_count  integer     NOT NULL,
  triggering_correction_id  uuid        REFERENCES public.correction_events(id)         ON DELETE RESTRICT,
  created_at                timestamptz NOT NULL DEFAULT now(),
  UNIQUE (challenge_id, revision_number),
  CONSTRAINT sr_eligible_count_check CHECK (effective_eligible_count >= 0)
);

ALTER TABLE public.score_runs ENABLE ROW LEVEL SECURITY;

-- Now add the cross-FKs from correction_events
ALTER TABLE public.correction_events
  ADD CONSTRAINT ce_score_run_fk
    FOREIGN KEY (resulting_score_run_id)
    REFERENCES public.score_runs(id) ON DELETE RESTRICT;

ALTER TABLE public.correction_events
  ADD CONSTRAINT ce_alias_fk
    FOREIGN KEY (alias_id)
    REFERENCES public.challenge_answer_aliases(id) ON DELETE RESTRICT;

-- ------------------------------------------------------------
-- 4.17  guess_judgments
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.guess_judgments (
  id                          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  score_run_id                uuid        NOT NULL REFERENCES public.score_runs(id)     ON DELETE RESTRICT,
  guess_attempt_id            uuid        NOT NULL REFERENCES public.guess_attempts(id) ON DELETE RESTRICT,
  player_id                   uuid        NOT NULL REFERENCES public.profiles(id)       ON DELETE RESTRICT,
  challenge_id                uuid        NOT NULL REFERENCES public.challenges(id)     ON DELETE RESTRICT,
  race                        text        NOT NULL,
  rules_version_id            uuid        NOT NULL REFERENCES public.rules_versions(id) ON DELETE RESTRICT,
  is_correct                  boolean     NOT NULL,
  is_first_correct_for_player boolean     NOT NULL DEFAULT false,
  created_at                  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (score_run_id, guess_attempt_id),
  CONSTRAINT gj_race_check CHECK (race IN ('what','where'))
);

ALTER TABLE public.guess_judgments ENABLE ROW LEVEL SECURITY;

-- One qualifying attempt per player per race per score run
CREATE UNIQUE INDEX IF NOT EXISTS one_qualifying_per_player_race
  ON public.guess_judgments (score_run_id, player_id, race)
  WHERE is_first_correct_for_player = true;

-- ------------------------------------------------------------
-- 4.18  score_events
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.score_events (
  id               uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  score_run_id     uuid        NOT NULL REFERENCES public.score_runs(id)     ON DELETE RESTRICT,
  challenge_id     uuid        NOT NULL REFERENCES public.challenges(id)     ON DELETE RESTRICT,
  player_id        uuid        NOT NULL REFERENCES public.profiles(id)       ON DELETE RESTRICT,
  rules_version_id uuid        NOT NULL REFERENCES public.rules_versions(id) ON DELETE RESTRICT,
  what_points      integer     NOT NULL DEFAULT 0,
  where_points     integer     NOT NULL DEFAULT 0,
  total_points     integer     NOT NULL GENERATED ALWAYS AS (what_points + where_points) STORED,
  what_rank        integer,
  where_rank       integer,
  scored_at        timestamptz NOT NULL DEFAULT now(),
  UNIQUE (score_run_id, player_id),
  CONSTRAINT se_what_points_check   CHECK (what_points  >= 0),
  CONSTRAINT se_where_points_check  CHECK (where_points >= 0),
  CONSTRAINT se_what_rank_check     CHECK (what_rank  IS NULL OR what_rank  > 0),
  CONSTRAINT se_where_rank_check    CHECK (where_rank IS NULL OR where_rank > 0)
);

ALTER TABLE public.score_events ENABLE ROW LEVEL SECURITY;

-- ------------------------------------------------------------
-- 4.19  comments
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.comments (
  id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  challenge_id  uuid        NOT NULL REFERENCES public.challenges(id) ON DELETE RESTRICT,
  author_id     uuid        NOT NULL REFERENCES public.profiles(id)  ON DELETE RESTRICT,
  text          text        NOT NULL,
  posted_at     timestamptz NOT NULL DEFAULT clock_timestamp(),
  deleted_at    timestamptz,
  CONSTRAINT comments_text_check CHECK (length(trim(text)) BETWEEN 1 AND 1000)
);

ALTER TABLE public.comments ENABLE ROW LEVEL SECURITY;

-- ------------------------------------------------------------
-- 4.20  reactions
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.reactions (
  id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  challenge_id  uuid        NOT NULL REFERENCES public.challenges(id) ON DELETE RESTRICT,
  player_id     uuid        NOT NULL REFERENCES public.profiles(id)  ON DELETE RESTRICT,
  emoji         text        NOT NULL,
  reacted_at    timestamptz NOT NULL DEFAULT clock_timestamp(),
  UNIQUE (challenge_id, player_id, emoji),
  CONSTRAINT reactions_emoji_check CHECK (length(emoji) BETWEEN 1 AND 8)
);

ALTER TABLE public.reactions ENABLE ROW LEVEL SECURITY;

-- ------------------------------------------------------------
-- 4.21  private.profile_archive
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS private.profile_archive (
  profile_id                       uuid        PRIMARY KEY
                                               REFERENCES public.profiles(id) ON DELETE RESTRICT,
  original_display_name            text,
  original_avatar_color            text,
  original_avatar_media_object_id  uuid,
  archived_at                      timestamptz NOT NULL DEFAULT clock_timestamp()
);

-- ------------------------------------------------------------
-- 4.22  private.deletion_log
-- 5-state retry machine for account deletion
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS private.deletion_log (
  profile_id       uuid  PRIMARY KEY
                         REFERENCES public.profiles(id) ON DELETE RESTRICT,
  status           text  NOT NULL DEFAULT 'pending',
  db_prepared_at   timestamptz,
  auth_deleted_at  timestamptz,
  completed_at     timestamptz,
  last_attempt_at  timestamptz NOT NULL DEFAULT clock_timestamp(),
  error            text,
  CONSTRAINT dl_status_check
    CHECK (status IN ('pending','database_prepared','auth_deleted','complete','failed'))
);


-- ============================================================
-- SECTION 5 — ADDITIONAL INDEXES
-- ============================================================

CREATE INDEX IF NOT EXISTS idx_challenges_group_id     ON public.challenges (group_id);
CREATE INDEX IF NOT EXISTS idx_challenges_state        ON public.challenges (state);
CREATE INDEX IF NOT EXISTS idx_guess_attempts_challenge ON public.guess_attempts (challenge_id, race, receipt_sequence);
CREATE INDEX IF NOT EXISTS idx_guess_attempts_player   ON public.guess_attempts (player_id, challenge_id);
CREATE INDEX IF NOT EXISTS idx_score_events_challenge  ON public.score_events (challenge_id);
CREATE INDEX IF NOT EXISTS idx_score_events_player     ON public.score_events (player_id);
CREATE INDEX IF NOT EXISTS idx_eligible_challenge      ON public.eligible_participants (challenge_id);
CREATE INDEX IF NOT EXISTS idx_exclusion_challenge     ON public.exclusion_events (challenge_id);
CREATE INDEX IF NOT EXISTS idx_clues_challenge         ON public.clues (challenge_id);
CREATE INDEX IF NOT EXISTS idx_comments_challenge      ON public.comments (challenge_id, posted_at);
CREATE INDEX IF NOT EXISTS idx_reactions_challenge     ON public.reactions (challenge_id);
CREATE INDEX IF NOT EXISTS idx_aliases_challenge       ON public.challenge_answer_aliases (challenge_id, field) WHERE is_active = true;
-- Prevent duplicate active aliases for the same challenge/field/normalized form
CREATE UNIQUE INDEX IF NOT EXISTS idx_aliases_active_unique
  ON public.challenge_answer_aliases (challenge_id, field, normalized_value)
  WHERE is_active = true;
CREATE INDEX IF NOT EXISTS idx_group_members_player    ON public.group_members (player_id);
CREATE INDEX IF NOT EXISTS idx_correction_challenge    ON public.correction_events (challenge_id);


-- ============================================================
-- SECTION 6 — FUNCTIONS
-- ============================================================

-- All SECURITY DEFINER functions use SET search_path = '' and fully qualified names.

-- ------------------------------------------------------------
-- 6A  Private auth + normalisation helpers
-- ------------------------------------------------------------

-- private.auth_uid(): drop-in replacement for auth.uid() that reads the JWT sub
-- claim via pg_catalog.current_setting, avoiding a dependency on the auth schema.
-- auth schema is owned by supabase_admin and its USAGE cannot be granted to custom
-- NOLOGIN roles by postgres. This function is functionally identical to auth.uid()
-- and is safe to call from SECURITY DEFINER functions, trigger functions, and RLS.
CREATE OR REPLACE FUNCTION private.auth_uid()
RETURNS uuid
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  -- Two guards against a cast-to-uuid failure:
  --   1. NULLIF on jwt.claim.sub: empty-string GUC → NULL (not ''::uuid which throws)
  --   2. NULLIF on the JSON-extracted sub: {"sub":""} → NULL rather than ''::uuid throw
  SELECT NULLIF(
    COALESCE(
      NULLIF(pg_catalog.current_setting('request.jwt.claim.sub', true), ''),
      NULLIF(
        (NULLIF(pg_catalog.current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub'),
        ''
      )
    ),
    ''
  )::uuid;
$$;

CREATE OR REPLACE FUNCTION private.normalize_answer(p_text text)
RETURNS text
LANGUAGE sql IMMUTABLE
SET search_path = ''
AS $$
  -- lowercase → strip non-alphanumeric/space chars → collapse whitespace → trim
  SELECT trim(
    regexp_replace(
      regexp_replace(lower(p_text), '[^a-z0-9 ]', '', 'g'),
      '\s+', ' ', 'g'
    )
  );
$$;

-- ------------------------------------------------------------
-- 6B  Private RLS helper functions
--     Owned by forkensics_rls_helper after creation
-- ------------------------------------------------------------

CREATE OR REPLACE FUNCTION private.is_group_member(p_group_id uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.group_members
    WHERE group_id = p_group_id
      AND player_id = private.auth_uid()
  );
$$;

CREATE OR REPLACE FUNCTION private.is_group_member_with(p_profile_id uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.group_members gm1
    JOIN  public.group_members gm2
      ON  gm1.group_id = gm2.group_id
    WHERE gm1.player_id = private.auth_uid()
      AND gm2.player_id = p_profile_id
  );
$$;

CREATE OR REPLACE FUNCTION private.is_challenge_group_member(p_challenge_id uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.challenges c
    JOIN   public.group_members gm ON gm.group_id = c.group_id
    WHERE  c.id = p_challenge_id
      AND  gm.player_id = private.auth_uid()
  );
$$;

CREATE OR REPLACE FUNCTION private.is_challenge_poster(p_challenge_id uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.challenges
    WHERE id        = p_challenge_id
      AND poster_id = private.auth_uid()
  );
$$;

CREATE OR REPLACE FUNCTION private.is_challenge_revealed(p_challenge_id uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.challenges
    WHERE id    = p_challenge_id
      AND state = 'revealed'
  );
$$;

CREATE OR REPLACE FUNCTION private.is_eligible_non_excluded(p_challenge_id uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT
    EXISTS (
      SELECT 1 FROM public.eligible_participants
      WHERE challenge_id = p_challenge_id AND player_id = private.auth_uid()
    )
    AND NOT EXISTS (
      SELECT 1 FROM public.exclusion_events
      WHERE challenge_id = p_challenge_id AND player_id = private.auth_uid()
    );
$$;

-- Table Talk access helper: true once the caller has locked a guess on this challenge.
-- Used by comments and reactions RLS so players can read/react after guessing,
-- not only after reveal. The poster is excluded from guess_attempts, so
-- is_challenge_poster() is always checked separately in those policies.
CREATE OR REPLACE FUNCTION private.caller_has_guessed(p_challenge_id uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.guess_attempts
    WHERE challenge_id = p_challenge_id
      AND player_id    = private.auth_uid()
  );
$$;

-- normalize_answer is called by executor-owned functions (reveal_challenge, apply_correction)
-- and by the guard_alias_edits trigger which runs as the calling role (not SECURITY DEFINER).
-- Grant to both forkensics_executor and authenticated; the function is pure/immutable with no
-- side-effects so the broad grant is safe.
GRANT EXECUTE ON FUNCTION private.normalize_answer(text) TO forkensics_executor, authenticated;
GRANT EXECUTE ON FUNCTION private.auth_uid()             TO forkensics_executor, forkensics_rls_helper, authenticated, service_role;

-- Transfer ownership to forkensics_rls_helper
ALTER FUNCTION private.auth_uid()                         OWNER TO forkensics_rls_helper;
ALTER FUNCTION private.normalize_answer(text)             OWNER TO forkensics_rls_helper;
ALTER FUNCTION private.is_group_member(uuid)              OWNER TO forkensics_rls_helper;
ALTER FUNCTION private.is_group_member_with(uuid)         OWNER TO forkensics_rls_helper;
ALTER FUNCTION private.is_challenge_group_member(uuid)    OWNER TO forkensics_rls_helper;
ALTER FUNCTION private.is_challenge_poster(uuid)          OWNER TO forkensics_rls_helper;
ALTER FUNCTION private.is_challenge_revealed(uuid)        OWNER TO forkensics_rls_helper;
ALTER FUNCTION private.is_eligible_non_excluded(uuid)     OWNER TO forkensics_rls_helper;
ALTER FUNCTION private.caller_has_guessed(uuid)           OWNER TO forkensics_rls_helper;


-- ============================================================
-- SECTION 7 — TRIGGER FUNCTIONS
-- ============================================================

-- ------------------------------------------------------------
-- 7.1  handle_new_user
-- Creates profiles row when a new auth.users row is inserted
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  INSERT INTO public.profiles (id, display_name, onboarding_complete, is_active)
  VALUES (
    NEW.id,
    NEW.raw_user_meta_data->>'display_name',
    false,
    true
  )
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE PROCEDURE public.handle_new_user();

-- ------------------------------------------------------------
-- 7.2  set_challenge_create_fields
-- Enforces poster_id and created_at on INSERT
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.set_challenge_create_fields()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  -- Server-assigned identity and state
  NEW.poster_id           := private.auth_uid();
  NEW.state               := 'draft';
  NEW.created_at          := clock_timestamp();
  -- Force approved rules version; client-supplied value is ignored
  NEW.rules_version_id    := 'a0000000-0000-0000-0000-000000000001';
  -- Lifecycle timestamps — all NULL on creation; set only by operational functions
  NEW.posted_at           := NULL;
  NEW.deadline_at         := NULL;
  NEW.locked_at           := NULL;
  NEW.revealed_at         := NULL;
  NEW.cancelled_at        := NULL;
  NEW.cancellation_reason := NULL;
  -- City display — optional poster-supplied context; normalize on creation
  IF NEW.public_city_display IS NOT NULL THEN
    NEW.public_city_display := NULLIF(trim(NEW.public_city_display), '');
  END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER challenge_create_fields
  BEFORE INSERT ON public.challenges
  FOR EACH ROW EXECUTE PROCEDURE public.set_challenge_create_fields();

-- ------------------------------------------------------------
-- 7.3  protect_challenge_authority_fields
-- Blocks direct client UPDATE of protected columns
-- Trusted functions run as forkensics_executor and bypass
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.protect_challenge_authority_fields()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  IF current_user = 'forkensics_executor' THEN
    RETURN NEW;
  END IF;
  -- Block all state-machine and authority columns
  IF NEW.state               IS DISTINCT FROM OLD.state               THEN
    RAISE EXCEPTION 'state cannot be set directly';
  END IF;
  IF NEW.poster_id           IS DISTINCT FROM OLD.poster_id           THEN
    RAISE EXCEPTION 'poster_id is immutable';
  END IF;
  IF NEW.group_id            IS DISTINCT FROM OLD.group_id            THEN
    RAISE EXCEPTION 'group_id is immutable';
  END IF;
  IF NEW.posted_at           IS DISTINCT FROM OLD.posted_at           THEN
    RAISE EXCEPTION 'posted_at cannot be set directly';
  END IF;
  IF NEW.deadline_at         IS DISTINCT FROM OLD.deadline_at         THEN
    RAISE EXCEPTION 'deadline_at cannot be set directly';
  END IF;
  IF NEW.locked_at           IS DISTINCT FROM OLD.locked_at           THEN
    RAISE EXCEPTION 'locked_at cannot be set directly';
  END IF;
  IF NEW.revealed_at         IS DISTINCT FROM OLD.revealed_at         THEN
    RAISE EXCEPTION 'revealed_at cannot be set directly';
  END IF;
  IF NEW.cancelled_at        IS DISTINCT FROM OLD.cancelled_at        THEN
    RAISE EXCEPTION 'cancelled_at cannot be set directly';
  END IF;
  IF NEW.cancellation_reason IS DISTINCT FROM OLD.cancellation_reason THEN
    RAISE EXCEPTION 'cancellation_reason cannot be set directly';
  END IF;
  IF NEW.rules_version_id    IS DISTINCT FROM OLD.rules_version_id    THEN
    RAISE EXCEPTION 'rules_version_id is immutable';
  END IF;
  -- public_city_display: poster may set/edit in draft; immutable after activation.
  -- Normalize on draft update (same rules as INSERT: trim, whitespace-only → NULL).
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

CREATE OR REPLACE TRIGGER challenge_protect_fields
  BEFORE UPDATE ON public.challenges
  FOR EACH ROW EXECUTE PROCEDURE public.protect_challenge_authority_fields();

-- ------------------------------------------------------------
-- 7.4  guard_answer_edits  (challenge_secrets)
-- Blocks edits after first guess; trusted executor bypasses
-- Also maintains updated_at
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.guard_answer_edits()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  IF current_user = 'forkensics_executor' THEN
    NEW.updated_at := clock_timestamp();
    RETURN NEW;
  END IF;
  IF OLD.has_first_guess = true THEN
    RAISE EXCEPTION 'challenge_secrets cannot be edited after first guess is received';
  END IF;
  -- Maintain updated_at for legitimate poster edits
  NEW.updated_at := clock_timestamp();
  RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER challenge_secrets_guard
  BEFORE UPDATE ON public.challenge_secrets
  FOR EACH ROW EXECUTE PROCEDURE public.guard_answer_edits();

-- Overwrite created_at on INSERT to prevent client spoofing
CREATE OR REPLACE FUNCTION public.set_challenge_secret_timestamps()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  NEW.created_at := clock_timestamp();
  NEW.updated_at := clock_timestamp();
  RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER challenge_secrets_timestamps
  BEFORE INSERT ON public.challenge_secrets
  FOR EACH ROW EXECUTE PROCEDURE public.set_challenge_secret_timestamps();

-- ------------------------------------------------------------
-- 7.5  guard_alias_edits  (challenge_answer_aliases)
-- Blocks new alias creation and is_active changes after first guess
-- Trusted executor bypasses
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.guard_alias_edits()
RETURNS trigger
LANGUAGE plpgsql
-- SECURITY INVOKER (default): runs as the calling role so that the
-- `current_user = 'forkensics_executor'` bypass check works correctly.
-- With SECURITY DEFINER the function always ran as forkensics_executor,
-- making the bypass unconditional and preventing field overrides from firing.
-- authenticated callers (poster) have SELECT on challenge_secrets via RLS,
-- so the SELECT FOR UPDATE below is safe without DEFINER elevation.
SET search_path = ''
AS $$
DECLARE
  v_has_first_guess boolean;
BEGIN
  -- Lock challenge_secrets row to serialize alias insertions against concurrent
  -- first-guess updates. set_guess_receipt_fields also locks this row when marking
  -- has_first_guess = true, so one of the two will observe the other's committed
  -- state and respond correctly.
  SELECT has_first_guess INTO v_has_first_guess
  FROM public.challenge_secrets
  WHERE challenge_id = NEW.challenge_id
  FOR UPDATE;

  -- forkensics_executor bypasses the post-guess guard (used by apply_correction).
  -- Because the function is now SECURITY INVOKER, current_user correctly reflects
  -- the actual calling role rather than always being forkensics_executor.
  IF current_user = 'forkensics_executor' THEN
    RETURN NEW;
  END IF;

  IF v_has_first_guess = true THEN
    RAISE EXCEPTION 'aliases cannot be changed after first guess is received';
  END IF;
  -- Force all server-owned fields on INSERT
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
  BEFORE INSERT ON public.challenge_answer_aliases
  FOR EACH ROW EXECUTE PROCEDURE public.guard_alias_edits();

CREATE OR REPLACE TRIGGER alias_guard_update
  BEFORE UPDATE ON public.challenge_answer_aliases
  FOR EACH ROW EXECUTE PROCEDURE public.guard_alias_edits();

-- ------------------------------------------------------------
-- 7.6  set_guess_receipt_fields
-- Stamps received_at, receipt_sequence; enforces deadline;
-- sets has_first_guess on challenge_secrets for the first accepted guess
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.set_guess_receipt_fields()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_challenge record;
BEGIN
  -- Stamp server-authoritative timestamps and sequence before any validation
  NEW.received_at         := clock_timestamp();
  NEW.client_submitted_at := NEW.client_submitted_at;  -- pass-through; may be NULL
  NEW.receipt_sequence    := nextval('public.guess_receipt_seq');

  -- Load challenge row (needed for deadline and state)
  SELECT state, deadline_at
  INTO v_challenge
  FROM public.challenges
  WHERE id = NEW.challenge_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'challenge not found';
  END IF;

  -- Enforce active state
  IF v_challenge.state != 'active' THEN
    RAISE EXCEPTION 'guess rejected: challenge is not active (state: %)', v_challenge.state;
  END IF;

  -- Enforce deadline: guess arriving at or after deadline_at is rejected
  IF NEW.received_at >= v_challenge.deadline_at THEN
    RAISE EXCEPTION 'guess rejected: challenge deadline has passed';
  END IF;

  -- Set has_first_guess = true when this is the first guess for this challenge.
  -- The row being inserted is not yet visible in guess_attempts at BEFORE trigger time,
  -- so a count of 0 means this IS the first guess.
  IF NOT EXISTS (
    SELECT 1 FROM public.guess_attempts WHERE challenge_id = NEW.challenge_id
  ) THEN
    UPDATE public.challenge_secrets
    SET has_first_guess = true
    WHERE challenge_id = NEW.challenge_id;
  END IF;

  RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER guess_receipt
  BEFORE INSERT ON public.guess_attempts
  FOR EACH ROW EXECUTE PROCEDURE public.set_guess_receipt_fields();

-- Transfer ownership so nextval runs with right privileges
ALTER FUNCTION public.set_guess_receipt_fields() OWNER TO forkensics_executor;

-- ------------------------------------------------------------
-- 7.12  check_judgment_consistency
-- Cross-column integrity: judgment must agree with its attempt and score run
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.check_judgment_consistency()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_attempt   record;
  v_score_run record;
BEGIN
  SELECT challenge_id, player_id, race
  INTO v_attempt
  FROM public.guess_attempts
  WHERE id = NEW.guess_attempt_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'guess attempt not found: %', NEW.guess_attempt_id;
  END IF;

  SELECT challenge_id, rules_version_id
  INTO v_score_run
  FROM public.score_runs
  WHERE id = NEW.score_run_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'score run not found: %', NEW.score_run_id;
  END IF;

  IF NEW.challenge_id != v_attempt.challenge_id THEN
    RAISE EXCEPTION 'judgment challenge_id (%) does not match attempt challenge_id (%)',
      NEW.challenge_id, v_attempt.challenge_id;
  END IF;
  IF NEW.player_id != v_attempt.player_id THEN
    RAISE EXCEPTION 'judgment player_id (%) does not match attempt player_id (%)',
      NEW.player_id, v_attempt.player_id;
  END IF;
  IF NEW.race != v_attempt.race THEN
    RAISE EXCEPTION 'judgment race (%) does not match attempt race (%)',
      NEW.race, v_attempt.race;
  END IF;
  IF NEW.challenge_id != v_score_run.challenge_id THEN
    RAISE EXCEPTION 'judgment challenge_id (%) does not match score run challenge_id (%)',
      NEW.challenge_id, v_score_run.challenge_id;
  END IF;
  IF NEW.rules_version_id != v_score_run.rules_version_id THEN
    RAISE EXCEPTION 'judgment rules_version_id (%) does not match score run rules_version_id (%)',
      NEW.rules_version_id, v_score_run.rules_version_id;
  END IF;

  RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER guess_judgment_consistency
  BEFORE INSERT ON public.guess_judgments
  FOR EACH ROW EXECUTE PROCEDURE public.check_judgment_consistency();

-- ------------------------------------------------------------
-- 7.13  check_score_event_consistency
-- Cross-column integrity: score event must agree with its score run;
-- player must be an effective eligible (not excluded) participant
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.check_score_event_consistency()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_score_run record;
BEGIN
  SELECT challenge_id, rules_version_id
  INTO v_score_run
  FROM public.score_runs
  WHERE id = NEW.score_run_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'score run not found: %', NEW.score_run_id;
  END IF;

  IF NEW.challenge_id != v_score_run.challenge_id THEN
    RAISE EXCEPTION 'score event challenge_id (%) does not match score run challenge_id (%)',
      NEW.challenge_id, v_score_run.challenge_id;
  END IF;
  IF NEW.rules_version_id != v_score_run.rules_version_id THEN
    RAISE EXCEPTION 'score event rules_version_id (%) does not match score run rules_version_id (%)',
      NEW.rules_version_id, v_score_run.rules_version_id;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.eligible_participants
    WHERE challenge_id = NEW.challenge_id AND player_id = NEW.player_id
  ) THEN
    RAISE EXCEPTION 'score event player % is not an eligible participant in challenge %',
      NEW.player_id, NEW.challenge_id;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.exclusion_events
    WHERE challenge_id = NEW.challenge_id AND player_id = NEW.player_id
  ) THEN
    RAISE EXCEPTION 'score event player % has been excluded from challenge %',
      NEW.player_id, NEW.challenge_id;
  END IF;

  RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER score_event_consistency
  BEFORE INSERT ON public.score_events
  FOR EACH ROW EXECUTE PROCEDURE public.check_score_event_consistency();

-- ------------------------------------------------------------
-- 7.7  protect_rules_versions
-- Immutable reference data — block all mutations
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.protect_rules_versions()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  RAISE EXCEPTION 'rules_versions records are immutable';
END;
$$;

CREATE OR REPLACE TRIGGER rules_versions_immutable
  BEFORE UPDATE OR DELETE ON public.rules_versions
  FOR EACH ROW EXECUTE PROCEDURE public.protect_rules_versions();

-- ------------------------------------------------------------
-- 7.8  restrict_comment_updates
-- Only deleted_at may be set; no other edits allowed
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.restrict_comment_updates()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  -- Immutable fields
  IF NEW.text         IS DISTINCT FROM OLD.text         THEN RAISE EXCEPTION 'comment text is immutable'; END IF;
  IF NEW.author_id    IS DISTINCT FROM OLD.author_id    THEN RAISE EXCEPTION 'author_id is immutable'; END IF;
  IF NEW.posted_at    IS DISTINCT FROM OLD.posted_at    THEN RAISE EXCEPTION 'posted_at is immutable'; END IF;
  IF NEW.challenge_id IS DISTINCT FROM OLD.challenge_id THEN RAISE EXCEPTION 'challenge_id is immutable'; END IF;

  -- Only the author may soft-delete
  IF NEW.author_id != private.auth_uid() THEN
    RAISE EXCEPTION 'only the author can soft-delete a comment';
  END IF;

  -- Author must be active
  IF NOT EXISTS (
    SELECT 1 FROM public.profiles WHERE id = private.auth_uid() AND is_active = true
  ) THEN
    RAISE EXCEPTION 'inactive accounts cannot modify comments';
  END IF;

  -- deleted_at is one-way: once set it cannot be cleared or changed
  IF OLD.deleted_at IS NOT NULL THEN
    RAISE EXCEPTION 'deleted_at is immutable once set (comment already soft-deleted)';
  END IF;

  -- Server assigns the deletion timestamp; override any client-supplied value
  IF NEW.deleted_at IS NOT NULL THEN
    NEW.deleted_at := clock_timestamp();
  END IF;

  RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER comment_update_guard
  BEFORE UPDATE ON public.comments
  FOR EACH ROW EXECUTE PROCEDURE public.restrict_comment_updates();

-- Overwrite timestamps on INSERT
CREATE OR REPLACE FUNCTION public.set_append_only_timestamps()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  IF TG_TABLE_NAME = 'clues'            THEN NEW.posted_at   := clock_timestamp(); END IF;
  IF TG_TABLE_NAME = 'comments'         THEN NEW.posted_at   := clock_timestamp(); END IF;
  IF TG_TABLE_NAME = 'reactions'        THEN NEW.reacted_at  := clock_timestamp(); END IF;
  IF TG_TABLE_NAME = 'exclusion_events' THEN NEW.excluded_at := clock_timestamp(); END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER clues_timestamp
  BEFORE INSERT ON public.clues
  FOR EACH ROW EXECUTE PROCEDURE public.set_append_only_timestamps();

CREATE OR REPLACE TRIGGER comments_timestamp
  BEFORE INSERT ON public.comments
  FOR EACH ROW EXECUTE PROCEDURE public.set_append_only_timestamps();

CREATE OR REPLACE TRIGGER reactions_timestamp
  BEFORE INSERT ON public.reactions
  FOR EACH ROW EXECUTE PROCEDURE public.set_append_only_timestamps();

CREATE OR REPLACE TRIGGER exclusion_events_timestamp
  BEFORE INSERT ON public.exclusion_events
  FOR EACH ROW EXECUTE PROCEDURE public.set_append_only_timestamps();

-- ------------------------------------------------------------
-- 7.9  enforce_exclusion_rules
-- account_deleted path only callable from forkensics_executor
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.enforce_exclusion_rules()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_challenge_state text;
BEGIN
  SELECT state INTO v_challenge_state
  FROM public.challenges WHERE id = NEW.challenge_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'challenge not found: %', NEW.challenge_id;
  END IF;

  -- All reasons: target must be an eligible participant
  IF NOT EXISTS (
    SELECT 1 FROM public.eligible_participants
    WHERE challenge_id = NEW.challenge_id AND player_id = NEW.player_id
  ) THEN
    RAISE EXCEPTION 'player % is not an eligible participant in challenge %',
      NEW.player_id, NEW.challenge_id;
  END IF;

  IF NEW.reason = 'withdrew' THEN
    -- Self-withdrawal: active only; excluded_by must equal player_id
    IF v_challenge_state != 'active' THEN
      RAISE EXCEPTION 'withdrawal only allowed while challenge is active (current state: %)',
        v_challenge_state;
    END IF;
    IF NEW.excluded_by IS DISTINCT FROM NEW.player_id THEN
      RAISE EXCEPTION 'withdrew: excluded_by must equal player_id (self-exclude only)';
    END IF;

  ELSIF NEW.reason = 'removed' THEN
    -- Removal: active only; authority enforced via RLS for authenticated callers
    IF v_challenge_state != 'active' THEN
      RAISE EXCEPTION 'removal only allowed while challenge is active (current state: %)',
        v_challenge_state;
    END IF;
    IF NEW.excluded_by IS NULL THEN
      RAISE EXCEPTION 'removed: excluded_by must be non-NULL';
    END IF;

  ELSIF NEW.reason = 'account_deleted' THEN
    -- account_deleted: trusted executor only; active or locked; excluded_by must be NULL
    IF current_user != 'forkensics_executor' THEN
      RAISE EXCEPTION 'account_deleted exclusion must be inserted by trusted function';
    END IF;
    IF v_challenge_state NOT IN ('active','locked') THEN
      RAISE EXCEPTION 'account_deleted exclusion only allowed for active/locked challenges (state: %)',
        v_challenge_state;
    END IF;
    IF NEW.excluded_by IS NOT NULL THEN
      RAISE EXCEPTION 'account_deleted: excluded_by must be NULL';
    END IF;

  ELSE
    RAISE EXCEPTION 'unknown exclusion reason: %', NEW.reason;
  END IF;

  RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER exclusion_enforce
  BEFORE INSERT ON public.exclusion_events
  FOR EACH ROW EXECUTE PROCEDURE public.enforce_exclusion_rules();

-- ------------------------------------------------------------
-- 7.10  lock_onboarding_complete
-- Once set to true, onboarding_complete cannot be reset to false
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lock_onboarding_complete()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  IF OLD.onboarding_complete = true AND NEW.onboarding_complete = false THEN
    RAISE EXCEPTION 'onboarding_complete cannot be reversed';
  END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER profile_lock_onboarding
  BEFORE UPDATE ON public.profiles
  FOR EACH ROW EXECUTE PROCEDURE public.lock_onboarding_complete();

-- ------------------------------------------------------------
-- 7.11  check_avatar_media_ownership
-- Ensures avatar_media_object_id belongs to this profile and is ready
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.check_avatar_media_ownership()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  IF NEW.avatar_media_object_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.media_objects
      WHERE id          = NEW.avatar_media_object_id
        AND uploader_id = NEW.id
        AND status      = 'ready'
    ) THEN
      RAISE EXCEPTION
        'avatar media object must be owned by this profile and have status ''ready''';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER profile_avatar_ownership
  BEFORE INSERT OR UPDATE ON public.profiles
  FOR EACH ROW EXECUTE PROCEDURE public.check_avatar_media_ownership();

-- ============================================================
-- SECTION 8 — OPERATIONAL FUNCTIONS (forkensics_executor owned)
-- ============================================================

-- All functions: SECURITY DEFINER, SET search_path = '', fully qualified names
-- Active-profile check at the top of every authenticated-caller function

-- Helper macro used inside each function:
-- PERFORM private.assert_active_caller();
-- (inline below since PLpgSQL cannot call macros)

-- ------------------------------------------------------------
-- 8.1  create_group
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.create_group(p_name text)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_group_id uuid;
BEGIN
  -- Active-profile guard
  IF NOT EXISTS (
    SELECT 1 FROM public.profiles WHERE id = private.auth_uid() AND is_active = true
  ) THEN RAISE EXCEPTION 'account is inactive'; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.profiles WHERE id = private.auth_uid() AND onboarding_complete = true
  ) THEN RAISE EXCEPTION 'onboarding not complete'; END IF;

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

-- ------------------------------------------------------------
-- 8.2  transfer_group_ownership
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.transfer_group_ownership(
  p_group_id     uuid,
  p_new_owner_id uuid
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.profiles WHERE id = private.auth_uid() AND is_active = true
  ) THEN RAISE EXCEPTION 'account is inactive'; END IF;

  -- Caller must be current owner
  IF NOT EXISTS (
    SELECT 1 FROM public.group_members
    WHERE group_id = p_group_id AND player_id = private.auth_uid() AND role = 'owner'
  ) THEN RAISE EXCEPTION 'caller is not the group owner'; END IF;

  -- New owner must be active, onboarded, and a current member
  IF NOT EXISTS (
    SELECT 1 FROM public.profiles WHERE id = p_new_owner_id
      AND is_active = true AND onboarding_complete = true
  ) THEN RAISE EXCEPTION 'new owner is not active or has not completed onboarding'; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.group_members
    WHERE group_id = p_group_id AND player_id = p_new_owner_id
  ) THEN RAISE EXCEPTION 'new owner is not a member of this group'; END IF;

  UPDATE public.group_members
    SET role = 'member'
  WHERE group_id = p_group_id AND player_id = private.auth_uid();

  UPDATE public.group_members
    SET role = 'owner'
  WHERE group_id = p_group_id AND player_id = p_new_owner_id;
END;
$$;

-- ------------------------------------------------------------
-- 8.3  create_group_invite
-- ------------------------------------------------------------
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

  -- Must be owner or member to create invite
  IF NOT EXISTS (
    SELECT 1 FROM public.group_members
    WHERE group_id = p_group_id AND player_id = private.auth_uid()
  ) THEN RAISE EXCEPTION 'not a member of this group'; END IF;

  -- Reject archived group
  IF EXISTS (
    SELECT 1 FROM public.groups
    WHERE id = p_group_id AND archived_at IS NOT NULL
  ) THEN RAISE EXCEPTION 'group is archived'; END IF;

  -- pgcrypto lives in the extensions schema; must be fully qualified when search_path = ''
  -- base64 → strip padding → replace + and / for URL-safety (base64url per RFC 4648 §5)
  v_raw_token  := replace(replace(rtrim(encode(extensions.gen_random_bytes(32), 'base64'), '='), '+', '-'), '/', '_');
  v_token_hash := encode(extensions.digest(v_raw_token, 'sha256'), 'hex');

  INSERT INTO public.group_invites (group_id, created_by, token_hash, expires_at)
  VALUES (p_group_id, private.auth_uid(), v_token_hash, now() + interval '7 days');

  RETURN v_raw_token;
END;
$$;

-- ------------------------------------------------------------
-- 8.4  redeem_group_invite
-- ------------------------------------------------------------
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

  v_hash := encode(extensions.digest(p_raw_token, 'sha256'), 'hex');

  SELECT * INTO v_invite FROM public.group_invites
  WHERE token_hash = v_hash
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'invalid invite token';
  END IF;

  IF v_invite.revoked_at IS NOT NULL THEN
    RAISE EXCEPTION 'invite has been revoked';
  END IF;

  IF v_invite.accepted_at IS NOT NULL THEN
    RAISE EXCEPTION 'invite has already been used';
  END IF;

  IF v_invite.expires_at < now() THEN
    RAISE EXCEPTION 'invite has expired';
  END IF;

  -- Reject archived group
  IF EXISTS (
    SELECT 1 FROM public.groups
    WHERE id = v_invite.group_id AND archived_at IS NOT NULL
  ) THEN RAISE EXCEPTION 'group is archived'; END IF;

  -- Idempotent: already a member is fine
  INSERT INTO public.group_members (group_id, player_id, role)
  VALUES (v_invite.group_id, private.auth_uid(), 'member')
  ON CONFLICT (group_id, player_id) DO NOTHING;

  UPDATE public.group_invites
  SET accepted_by = private.auth_uid(), accepted_at = now()
  WHERE id = v_invite.id;

  RETURN v_invite.group_id;
END;
$$;

-- ------------------------------------------------------------
-- 8.5  revoke_group_invite
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.revoke_group_invite(p_invite_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_invite record;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.profiles WHERE id = private.auth_uid() AND is_active = true
  ) THEN RAISE EXCEPTION 'account is inactive'; END IF;

  -- Lock the invite row to prevent race with concurrent redemption
  SELECT * INTO v_invite FROM public.group_invites
  WHERE id = p_invite_id FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'invite not found';
  END IF;

  -- Caller must be the group owner OR the original invite creator
  IF NOT EXISTS (
    SELECT 1 FROM public.group_members
    WHERE group_id  = v_invite.group_id
      AND player_id = private.auth_uid()
      AND role      = 'owner'
  ) AND v_invite.created_by != private.auth_uid() THEN
    RAISE EXCEPTION 'only the group owner or invite creator may revoke this invite';
  END IF;

  IF v_invite.revoked_at IS NOT NULL THEN
    RAISE EXCEPTION 'invite is already revoked';
  END IF;

  IF v_invite.accepted_at IS NOT NULL THEN
    RAISE EXCEPTION 'invite has already been used and cannot be revoked';
  END IF;

  UPDATE public.group_invites
  SET revoked_at = now(), revoked_by = private.auth_uid()
  WHERE id = p_invite_id;
END;
$$;

-- ------------------------------------------------------------
-- 8.6  activate_challenge
-- Draft → Active; snapshots eligible participants
-- ------------------------------------------------------------
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

  -- Verify group is not archived
  IF EXISTS (
    SELECT 1 FROM public.groups WHERE id = v_challenge.group_id AND archived_at IS NOT NULL
  ) THEN RAISE EXCEPTION 'group is archived'; END IF;

  -- Verify challenge_secrets exists with non-empty canonical fields
  SELECT * INTO v_secrets FROM public.challenge_secrets
  WHERE challenge_id = p_challenge_id;

  IF NOT FOUND THEN RAISE EXCEPTION 'challenge_secrets not found'; END IF;

  IF length(trim(v_secrets.canonical_dish)) = 0
     OR length(trim(v_secrets.canonical_restaurant)) = 0 THEN
    RAISE EXCEPTION 'canonical answers must not be empty';
  END IF;

  -- Verify photo is present and ready
  IF v_challenge.media_object_id IS NULL THEN
    RAISE EXCEPTION 'challenge photo is required';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.media_objects
    WHERE id          = v_challenge.media_object_id
      AND uploader_id = private.auth_uid()
      AND status      = 'ready'
  ) THEN RAISE EXCEPTION 'challenge photo is not ready'; END IF;

  -- Snapshot eligible participants: active, onboarded group members excluding poster
  INSERT INTO public.eligible_participants (challenge_id, player_id, snapshot_avatar_color)
  SELECT
    p_challenge_id,
    p.id,
    p.avatar_color
  FROM public.group_members gm
  JOIN public.profiles p ON p.id = gm.player_id
  WHERE gm.group_id = v_challenge.group_id
    AND gm.player_id != private.auth_uid()        -- exclude poster
    AND p.is_active = true
    AND p.onboarding_complete = true;

  GET DIAGNOSTICS v_ep_count = ROW_COUNT;

  IF v_ep_count = 0 THEN
    RAISE EXCEPTION 'at least one eligible participant is required';
  END IF;

  -- Atomic transition; public_city_display already set by poster on the draft row
  UPDATE public.challenges
  SET
    state     = 'active',
    posted_at = clock_timestamp(),
    deadline_at = clock_timestamp() + (v_challenge.duration_seconds || ' seconds')::interval
  WHERE id = p_challenge_id;
END;
$$;

-- ------------------------------------------------------------
-- 8.7  lock_challenge  (service role only — called by scheduler)
-- Active → Locked
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lock_challenge(p_challenge_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_challenge record;
BEGIN
  -- No auth.uid() check — service role path only
  SELECT * INTO v_challenge FROM public.challenges
  WHERE id = p_challenge_id FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'challenge not found'; END IF;

  IF clock_timestamp() < v_challenge.deadline_at THEN
    RAISE EXCEPTION 'challenge deadline has not been reached';
  END IF;

  IF v_challenge.state != 'active' THEN
    RAISE EXCEPTION 'lock requires active state (current: %)', v_challenge.state;
  END IF;

  UPDATE public.challenges
  SET state = 'locked', locked_at = clock_timestamp()
  WHERE id = p_challenge_id;
END;
$$;

-- ------------------------------------------------------------
-- 8.8  private.do_reveal_impl
-- Shared scoring implementation called by both reveal entry points.
-- Assumes the challenges row is already locked by the caller.
-- Active/Locked → Revealed; creates score_run revision 1.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.do_reveal_impl(p_challenge_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_challenge          record;
  v_secrets            record;
  v_eligible_count     integer;
  v_score_run_id       uuid;
  v_attempt            record;
  v_norm_dish                   text;
  v_norm_restaurant             text;
  v_norm_canonical_dish         text;
  v_norm_canonical_restaurant   text;
  v_what_correct                boolean;
  v_where_correct               boolean;
  v_restaurant_correct          boolean;
  v_what_first_seq              bigint;
  v_where_first_seq    bigint;
BEGIN
  -- Row already locked by caller; plain SELECT to read current state
  SELECT * INTO v_challenge FROM public.challenges WHERE id = p_challenge_id;

  -- Fetch secrets
  SELECT * INTO v_secrets FROM public.challenge_secrets
  WHERE challenge_id = p_challenge_id;

  -- Pre-normalise canonical answers
  v_norm_canonical_dish       := private.normalize_answer(v_secrets.canonical_dish);
  v_norm_canonical_restaurant := private.normalize_answer(v_secrets.canonical_restaurant);

  -- Count effective eligible participants (non-excluded)
  SELECT COUNT(*) INTO v_eligible_count
  FROM public.eligible_participants ep
  WHERE ep.challenge_id = p_challenge_id
    AND NOT EXISTS (
      SELECT 1 FROM public.exclusion_events ex
      WHERE ex.challenge_id = p_challenge_id AND ex.player_id = ep.player_id
    );

  -- Create score_run (revision 1)
  INSERT INTO public.score_runs (
    challenge_id, revision_number, rules_version_id,
    effective_eligible_count, triggering_correction_id
  )
  VALUES (
    p_challenge_id, 1, v_challenge.rules_version_id, v_eligible_count, NULL
  )
  RETURNING id INTO v_score_run_id;

  -- Temporary table to accumulate per-player per-race first-correct tracking
  CREATE TEMP TABLE tmp_first_correct (
    player_id uuid,
    race      text,
    ga_id     uuid,
    seq       bigint
  ) ON COMMIT DROP;

  -- Judge every non-excluded eligible attempt, ordered by receipt_sequence
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
      v_norm_dish   := private.normalize_answer(v_attempt.dish_guess);
      v_what_correct :=
        v_norm_dish = v_norm_canonical_dish
        OR EXISTS (
          SELECT 1 FROM public.challenge_answer_aliases
          WHERE challenge_id    = p_challenge_id
            AND field           = 'dish'
            AND is_active       = true
            AND normalized_value = v_norm_dish
        );

      INSERT INTO public.guess_judgments (
        score_run_id, guess_attempt_id, player_id, challenge_id,
        race, rules_version_id, is_correct, is_first_correct_for_player
      )
      VALUES (
        v_score_run_id, v_attempt.id, v_attempt.player_id, p_challenge_id,
        'what', v_challenge.rules_version_id, v_what_correct,
        v_what_correct
        AND NOT EXISTS (
          SELECT 1 FROM tmp_first_correct
          WHERE player_id = v_attempt.player_id AND race = 'what'
        )
      );

      IF v_what_correct
         AND NOT EXISTS (
           SELECT 1 FROM tmp_first_correct
           WHERE player_id = v_attempt.player_id AND race = 'what'
         ) THEN
        INSERT INTO tmp_first_correct VALUES
          (v_attempt.player_id, 'what', v_attempt.id, v_attempt.receipt_sequence);
      END IF;

    ELSE  -- 'where'
      v_norm_restaurant := private.normalize_answer(v_attempt.restaurant_guess);

      v_restaurant_correct :=
        v_norm_restaurant = v_norm_canonical_restaurant
        OR EXISTS (
          SELECT 1 FROM public.challenge_answer_aliases
          WHERE challenge_id    = p_challenge_id
            AND field           = 'restaurant'
            AND is_active       = true
            AND normalized_value = v_norm_restaurant
        );

      -- Restaurant alone determines where correctness; city is optional context only
      v_where_correct := v_restaurant_correct;

      INSERT INTO public.guess_judgments (
        score_run_id, guess_attempt_id, player_id, challenge_id,
        race, rules_version_id, is_correct, is_first_correct_for_player
      )
      VALUES (
        v_score_run_id, v_attempt.id, v_attempt.player_id, p_challenge_id,
        'where', v_challenge.rules_version_id, v_where_correct,
        v_where_correct
        AND NOT EXISTS (
          SELECT 1 FROM tmp_first_correct
          WHERE player_id = v_attempt.player_id AND race = 'where'
        )
      );

      IF v_where_correct
         AND NOT EXISTS (
           SELECT 1 FROM tmp_first_correct
           WHERE player_id = v_attempt.player_id AND race = 'where'
         ) THEN
        INSERT INTO tmp_first_correct VALUES
          (v_attempt.player_id, 'where', v_attempt.id, v_attempt.receipt_sequence);
      END IF;
    END IF;
  END LOOP;

  -- Calculate ordinal ranks by receipt_sequence and insert score_events
  -- for every eligible non-excluded participant
  -- CTE computes rank only among players with a first-correct answer per race
  WITH what_ranked AS (
    SELECT player_id, ROW_NUMBER() OVER (ORDER BY seq)::integer AS rnk
    FROM tmp_first_correct WHERE race = 'what'
  ),
  where_ranked AS (
    SELECT player_id, ROW_NUMBER() OVER (ORDER BY seq)::integer AS rnk
    FROM tmp_first_correct WHERE race = 'where'
  )
  INSERT INTO public.score_events (
    score_run_id, challenge_id, player_id, rules_version_id,
    what_points, where_points, what_rank, where_rank
  )
  SELECT
    v_score_run_id,
    p_challenge_id,
    ep.player_id,
    v_challenge.rules_version_id,
    -- IMPORTANT: PostgreSQL GREATEST(1, NULL) = 1, not NULL.
    -- Using COALESCE(GREATEST(...), 0) would award 1 point to every player
    -- regardless of whether they answered correctly.  Use CASE to gate on rank presence.
    CASE WHEN wr.rnk  IS NOT NULL THEN GREATEST(1, v_eligible_count - wr.rnk  + 1) ELSE 0 END AS what_points,
    CASE WHEN whr.rnk IS NOT NULL THEN GREATEST(1, v_eligible_count - whr.rnk + 1) ELSE 0 END AS where_points,
    wr.rnk  AS what_rank,
    whr.rnk AS where_rank
  FROM public.eligible_participants ep
  LEFT JOIN what_ranked  wr  ON wr.player_id  = ep.player_id
  LEFT JOIN where_ranked whr ON whr.player_id = ep.player_id
  WHERE ep.challenge_id = p_challenge_id
    AND NOT EXISTS (
      SELECT 1 FROM public.exclusion_events ex
      WHERE ex.challenge_id = p_challenge_id AND ex.player_id = ep.player_id
    );

  -- Mark challenge as revealed
  UPDATE public.challenges
  SET state = 'revealed', revealed_at = clock_timestamp()
  WHERE id = p_challenge_id;

  DROP TABLE IF EXISTS tmp_first_correct;
END;
$$;

-- ------------------------------------------------------------
-- 8.8a  public.reveal_challenge — authenticated poster entry point
-- Requires: valid auth_uid, active profile, poster ownership, elapsed deadline.
-- State: active or locked → calls private.do_reveal_impl.
-- Granted to authenticated only; explicitly revoked from service_role.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.reveal_challenge(p_challenge_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_challenge record;
BEGIN
  SELECT * INTO v_challenge FROM public.challenges
  WHERE id = p_challenge_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'challenge not found'; END IF;

  -- Must have an authenticated identity; a missing UID is not service authority
  IF private.auth_uid() IS NULL THEN
    RAISE EXCEPTION 'caller identity required' USING ERRCODE = '42501';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.profiles WHERE id = private.auth_uid() AND is_active = true
  ) THEN RAISE EXCEPTION 'account is inactive'; END IF;

  IF v_challenge.poster_id != private.auth_uid() THEN
    RAISE EXCEPTION 'caller is not the poster';
  END IF;

  IF clock_timestamp() < v_challenge.deadline_at THEN
    RAISE EXCEPTION 'deadline has not been reached';
  END IF;

  IF v_challenge.state NOT IN ('active','locked') THEN
    RAISE EXCEPTION 'invalid state for poster reveal: %', v_challenge.state;
  END IF;

  PERFORM private.do_reveal_impl(p_challenge_id);
END;
$$;

-- ------------------------------------------------------------
-- 8.8b  private.reveal_challenge_service — service-scheduler entry point
-- Requires: challenge must be locked.
-- Granted to service_role only; not accessible to authenticated.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.reveal_challenge_service(p_challenge_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_challenge record;
BEGIN
  SELECT * INTO v_challenge FROM public.challenges
  WHERE id = p_challenge_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'challenge not found'; END IF;

  IF v_challenge.state != 'locked' THEN
    RAISE EXCEPTION 'service reveal requires locked state (current: %)', v_challenge.state;
  END IF;

  PERFORM private.do_reveal_impl(p_challenge_id);
END;
$$;

-- ------------------------------------------------------------
-- 8.9  cancel_challenge
-- Draft/Active → Cancelled
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cancel_challenge(
  p_challenge_id uuid,
  p_reason       text
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_challenge record;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.profiles WHERE id = private.auth_uid() AND is_active = true
  ) THEN RAISE EXCEPTION 'account is inactive'; END IF;

  SELECT * INTO v_challenge FROM public.challenges
  WHERE id = p_challenge_id FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'challenge not found'; END IF;

  -- Poster or group owner may cancel
  IF v_challenge.poster_id != private.auth_uid()
     AND NOT EXISTS (
       SELECT 1 FROM public.group_members
       WHERE group_id  = v_challenge.group_id
         AND player_id = private.auth_uid()
         AND role      = 'owner'
     ) THEN
    RAISE EXCEPTION 'only the poster or group owner can cancel a challenge';
  END IF;

  -- Re-check state after lock
  IF v_challenge.state NOT IN ('draft','active') THEN
    RAISE EXCEPTION 'challenge cannot be cancelled in state %', v_challenge.state;
  END IF;

  UPDATE public.challenges
  SET
    state               = 'cancelled',
    cancelled_at        = clock_timestamp(),
    cancellation_reason = p_reason
  WHERE id = p_challenge_id;
END;
$$;

-- ------------------------------------------------------------
-- 8.10  apply_correction
-- 8-step atomic transaction: lock → validate → correct → rescore
-- Returns the new score_run id
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.apply_correction(
  p_challenge_id      uuid,
  p_action            text,   -- 'answer_changed' | 'alias_added' | 'alias_removed'
  p_target_field      text,   -- 'dish' | 'restaurant'
  p_new_display_value text,   -- new display value (answer_changed/alias_added); NULL for alias_removed
  p_alias_id          uuid,   -- for alias_removed; NULL for answer_changed/alias_added
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
  v_attempt                     record;
  v_norm_dish                   text;
  v_norm_restaurant             text;
  v_norm_canonical_dish         text;
  v_norm_canonical_restaurant   text;
  v_what_correct                boolean;
  v_where_correct               boolean;
  v_restaurant_correct          boolean;
BEGIN
  -- Step 1: Active-profile guard + caller authority
  IF NOT EXISTS (
    SELECT 1 FROM public.profiles WHERE id = private.auth_uid() AND is_active = true
  ) THEN RAISE EXCEPTION 'account is inactive'; END IF;

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

  -- Mutually exclusive parameter contract
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
    -- Field-specific max length
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
    -- Lock the alias row; capture its values for the audit record
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
    -- Reject duplicate active alias by normalized value for same challenge + field
    IF EXISTS (
      SELECT 1 FROM public.challenge_answer_aliases
      WHERE challenge_id    = p_challenge_id
        AND field           = p_target_field
        AND is_active       = true
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

  -- Build audit values per action
  -- alias_removed: record the alias's own values, not the canonical answer's
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

  -- Step 5: Calculate next revision number (challenge locked from step 1)
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

  ELSE -- alias_removed
    UPDATE public.challenge_answer_aliases
    SET is_active = false
    WHERE id = p_alias_id;
  END IF;

  -- Step 7: Insert correction audit record with per-action audit values
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

  -- Step 8: Re-score — re-read secrets after update
  SELECT * INTO v_secrets FROM public.challenge_secrets
  WHERE challenge_id = p_challenge_id;

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

  -- Re-judge all non-excluded eligible attempts
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

    ELSE  -- 'where'
      v_norm_restaurant := private.normalize_answer(v_attempt.restaurant_guess);

      v_restaurant_correct :=
        v_norm_restaurant = v_norm_canonical_restaurant
        OR EXISTS (
          SELECT 1 FROM public.challenge_answer_aliases
          WHERE challenge_id    = p_challenge_id AND field = 'restaurant'
            AND is_active = true AND normalized_value = v_norm_restaurant
        );

      -- Restaurant alone determines where correctness; city is optional context only
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

  -- Insert score_events for this revision
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
    -- Same CASE fix: GREATEST(1, NULL) = 1 in PostgreSQL; must gate on rank presence
    CASE WHEN wr.rnk  IS NOT NULL THEN GREATEST(1, v_eligible_count - wr.rnk  + 1) ELSE 0 END AS what_points,
    CASE WHEN whr.rnk IS NOT NULL THEN GREATEST(1, v_eligible_count - whr.rnk + 1) ELSE 0 END AS where_points,
    wr.rnk  AS what_rank,
    whr.rnk AS where_rank
  FROM public.eligible_participants ep
  LEFT JOIN what_ranked_c  wr  ON wr.player_id  = ep.player_id
  LEFT JOIN where_ranked_c whr ON whr.player_id = ep.player_id
  WHERE ep.challenge_id = p_challenge_id
    AND NOT EXISTS (
      SELECT 1 FROM public.exclusion_events ex
      WHERE ex.challenge_id = p_challenge_id AND ex.player_id = ep.player_id
    );

  -- Link correction to score run
  UPDATE public.correction_events
  SET resulting_score_run_id = v_score_run_id
  WHERE id = v_correction_id;

  DROP TABLE IF EXISTS tmp_fc;

  RETURN v_score_run_id;
END;
$$;

-- ------------------------------------------------------------
-- 8.11  private.prepare_account_deletion
-- Service-role only; called from Edge Function
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.prepare_account_deletion(p_profile_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_challenge    record;
  v_group        record;
  v_successor_id uuid;
BEGIN
  -- Forward-only: do nothing if preparation is already complete or in progress
  IF EXISTS (
    SELECT 1 FROM private.deletion_log
    WHERE profile_id = p_profile_id
      AND status IN ('database_prepared', 'auth_deleted', 'complete')
  ) THEN
    RETURN;
  END IF;

  -- Create or reset a pending/failed record to 'pending' for a fresh attempt
  INSERT INTO private.deletion_log (profile_id, status, last_attempt_at)
  VALUES (p_profile_id, 'pending', clock_timestamp())
  ON CONFLICT (profile_id) DO UPDATE
    SET status          = 'pending',
        last_attempt_at = clock_timestamp(),
        error           = NULL;

  -- 1. Cancel draft/active challenges
  UPDATE public.challenges
  SET
    state               = 'cancelled',
    cancelled_at        = clock_timestamp(),
    cancellation_reason = 'Account deleted'
  WHERE poster_id = p_profile_id
    AND state IN ('draft','active');

  -- 2. Exclude from active participations (idempotent via ON CONFLICT DO NOTHING)
  FOR v_challenge IN
    SELECT c.id AS challenge_id
    FROM public.challenges c
    JOIN public.eligible_participants ep ON ep.challenge_id = c.id
    WHERE ep.player_id = p_profile_id
      AND c.state IN ('active','locked')
  LOOP
    INSERT INTO public.exclusion_events (
      challenge_id, player_id, reason, excluded_by
    )
    VALUES (v_challenge.challenge_id, p_profile_id, 'account_deleted', NULL)
    ON CONFLICT (challenge_id, player_id) DO NOTHING;
  END LOOP;

  -- 3. Transfer or archive owned groups
  FOR v_group IN
    SELECT g.id AS group_id
    FROM public.groups g
    JOIN public.group_members gm ON gm.group_id = g.id
    WHERE gm.player_id = p_profile_id
      AND gm.role      = 'owner'
      AND g.archived_at IS NULL
  LOOP
    -- Find longest-tenured active onboarded non-deleted member
    SELECT gm.player_id INTO v_successor_id
    FROM public.group_members gm
    JOIN public.profiles p ON p.id = gm.player_id
    WHERE gm.group_id  = v_group.group_id
      AND gm.player_id != p_profile_id
      AND p.is_active  = true
      AND p.onboarding_complete = true
    ORDER BY gm.joined_at ASC
    LIMIT 1;

    IF v_successor_id IS NOT NULL THEN
      UPDATE public.group_members
      SET role = 'member' WHERE group_id = v_group.group_id AND player_id = p_profile_id;
      UPDATE public.group_members
      SET role = 'owner'  WHERE group_id = v_group.group_id AND player_id = v_successor_id;
    ELSE
      UPDATE public.groups
      SET archived_at = clock_timestamp()
      WHERE id = v_group.group_id;
    END IF;
  END LOOP;

  -- 4. Archive profile identity
  INSERT INTO private.profile_archive (
    profile_id, original_display_name, original_avatar_color, original_avatar_media_object_id
  )
  SELECT id, display_name, avatar_color, avatar_media_object_id
  FROM public.profiles WHERE id = p_profile_id
  ON CONFLICT (profile_id) DO NOTHING;

  -- 5. Anonymise profiles row
  UPDATE public.profiles
  SET
    display_name           = 'Former Player',
    avatar_color           = 'gray',
    avatar_media_object_id = NULL,
    is_active              = false
  WHERE id = p_profile_id;

  -- 6. Tombstone all media objects owned by this profile.
  --    Sets status = 'deleted' so the DB row (and its FK references) remains intact.
  --    The Edge Function handles actual file removal from storage and advances
  --    the deletion_log to 'complete' after confirming storage cleanup.
  UPDATE public.media_objects
  SET status = 'deleted'
  WHERE uploader_id = p_profile_id;

  -- Mark DB step complete
  UPDATE private.deletion_log
  SET status = 'database_prepared', db_prepared_at = clock_timestamp()
  WHERE profile_id = p_profile_id;
END;
$$;


-- ------------------------------------------------------------
-- 8.12  private.get_storage_keys_for_deletion
-- Returns storage keys for media owned by the profile.
-- Only callable once status is database_prepared or auth_deleted.
-- Service-role only.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.get_storage_keys_for_deletion(p_profile_id uuid)
RETURNS TABLE(media_object_id uuid, storage_key text)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM private.deletion_log
    WHERE profile_id = p_profile_id
      AND status IN ('database_prepared', 'auth_deleted')
  ) THEN
    RAISE EXCEPTION 'deletion not in a valid state for storage key retrieval (profile %)',
      p_profile_id;
  END IF;
  -- Return one row per physical file; excludes NULL/blank keys.
  -- The deletion worker iterates the flat list and deletes each key independently.
  RETURN QUERY
  SELECT msk.media_object_id, msk.storage_key
  FROM private.media_storage_keys msk
  JOIN public.media_objects mo ON mo.id = msk.media_object_id
  WHERE mo.uploader_id = p_profile_id
    AND mo.status = 'deleted'
    AND msk.storage_key IS NOT NULL
    AND trim(msk.storage_key) != ''
  UNION
  SELECT msk.media_object_id, msk.re_encoded_storage_key
  FROM private.media_storage_keys msk
  JOIN public.media_objects mo ON mo.id = msk.media_object_id
  WHERE mo.uploader_id = p_profile_id
    AND mo.status = 'deleted'
    AND msk.re_encoded_storage_key IS NOT NULL
    AND trim(msk.re_encoded_storage_key) != '';
END;
$$;

-- ------------------------------------------------------------
-- 8.13  private.mark_auth_deleted
-- Forward-only transition: database_prepared → auth_deleted.
-- Idempotent if already auth_deleted or complete.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.mark_auth_deleted(p_profile_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_status text;
BEGIN
  SELECT status INTO v_status
  FROM private.deletion_log WHERE profile_id = p_profile_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'no deletion record for profile %', p_profile_id;
  END IF;
  IF v_status IN ('auth_deleted', 'complete') THEN RETURN; END IF;  -- idempotent
  IF v_status != 'database_prepared' THEN
    RAISE EXCEPTION 'mark_auth_deleted requires database_prepared state (current: %)', v_status;
  END IF;
  UPDATE private.deletion_log
  SET status = 'auth_deleted', auth_deleted_at = clock_timestamp()
  WHERE profile_id = p_profile_id;
END;
$$;

-- ------------------------------------------------------------
-- 8.14  private.mark_storage_cleaned
-- Forward-only transition: auth_deleted → complete.
-- Deletes storage key records. Idempotent if already complete.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.mark_storage_cleaned(p_profile_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_status text;
BEGIN
  SELECT status INTO v_status
  FROM private.deletion_log WHERE profile_id = p_profile_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'no deletion record for profile %', p_profile_id;
  END IF;
  IF v_status = 'complete' THEN RETURN; END IF;  -- idempotent
  IF v_status != 'auth_deleted' THEN
    RAISE EXCEPTION 'mark_storage_cleaned requires auth_deleted state (current: %)', v_status;
  END IF;
  DELETE FROM private.media_storage_keys
  WHERE media_object_id IN (
    SELECT id FROM public.media_objects WHERE uploader_id = p_profile_id
  );
  UPDATE private.deletion_log
  SET status = 'complete', completed_at = clock_timestamp()
  WHERE profile_id = p_profile_id;
END;
$$;

-- ------------------------------------------------------------
-- 8.15  private.record_deletion_failure
-- Records an error against the current deletion record without
-- advancing or regressing the status (status is preserved).
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.record_deletion_failure(p_profile_id uuid, p_error text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  UPDATE private.deletion_log
  SET error = p_error, last_attempt_at = clock_timestamp()
  WHERE profile_id = p_profile_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'no deletion record for profile %', p_profile_id;
  END IF;
END;
$$;


-- ------------------------------------------------------------
-- 8.16  soft_delete_comment
-- Sets deleted_at (soft-delete) for a comment authored by the caller.
-- Direct authenticated UPDATE is blocked by PostgreSQL's rule: "the system
-- will still prevent the case in which the new row can not be selected by
-- the SELECT policies." Our SELECT policy requires deleted_at IS NULL, so
-- any direct UPDATE that sets deleted_at fails the SELECT visibility check
-- on the new row.  This SECURITY DEFINER function (owner: forkensics_executor,
-- BYPASSRLS) performs the UPDATE outside RLS.  The comment_update_guard
-- BEFORE trigger still fires and enforces:
--   • caller is the author (author_id = private.auth_uid())
--   • caller is active (is_active = true)
--   • deleted_at is not already set (one-way tombstone)
--   • server assigns clock_timestamp() for deleted_at
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.soft_delete_comment(p_comment_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF private.auth_uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = '42501';
  END IF;

  -- Trigger (comment_update_guard) validates author, active status,
  -- and deleted_at immutability; no need to duplicate those checks here.
  UPDATE public.comments
  SET deleted_at = clock_timestamp()
  WHERE id = p_comment_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Comment % not found', p_comment_id USING ERRCODE = 'P0002';
  END IF;
END;
$$;


-- ============================================================
-- SECTION 9 — OWNERSHIP ASSIGNMENTS
-- ============================================================

-- Operational functions owned by forkensics_executor
ALTER FUNCTION public.create_group(text)                                         OWNER TO forkensics_executor;
ALTER FUNCTION public.transfer_group_ownership(uuid, uuid)                       OWNER TO forkensics_executor;
ALTER FUNCTION public.create_group_invite(uuid)                                  OWNER TO forkensics_executor;
ALTER FUNCTION public.redeem_group_invite(text)                                  OWNER TO forkensics_executor;
ALTER FUNCTION public.revoke_group_invite(uuid)                                  OWNER TO forkensics_executor;
ALTER FUNCTION public.activate_challenge(uuid)                                   OWNER TO forkensics_executor;
ALTER FUNCTION public.lock_challenge(uuid)                                       OWNER TO forkensics_executor;
ALTER FUNCTION public.reveal_challenge(uuid)                                     OWNER TO forkensics_executor;
ALTER FUNCTION public.cancel_challenge(uuid, text)                               OWNER TO forkensics_executor;
ALTER FUNCTION public.apply_correction(uuid, text, text, text, uuid, text)       OWNER TO forkensics_executor;
ALTER FUNCTION private.prepare_account_deletion(uuid)                            OWNER TO forkensics_executor;
ALTER FUNCTION private.do_reveal_impl(uuid)                                      OWNER TO forkensics_executor;
ALTER FUNCTION private.reveal_challenge_service(uuid)                            OWNER TO forkensics_executor;
ALTER FUNCTION public.guard_alias_edits()                                        OWNER TO forkensics_executor;
ALTER FUNCTION private.get_storage_keys_for_deletion(uuid)                      OWNER TO forkensics_executor;
ALTER FUNCTION private.mark_auth_deleted(uuid)                                   OWNER TO forkensics_executor;
ALTER FUNCTION private.mark_storage_cleaned(uuid)                                OWNER TO forkensics_executor;
ALTER FUNCTION private.record_deletion_failure(uuid, text)                       OWNER TO forkensics_executor;
ALTER FUNCTION public.soft_delete_comment(uuid)                                  OWNER TO forkensics_executor;


-- ============================================================
-- SECTION 9B — REVOKE TEMPORARY BUILD-TIME PRIVILEGES
-- ============================================================
-- GRANT CREATE on schemas was required only for OWNER TO assignments (PG 16+
-- enforces that the grantor is a member of the target role AND the target role
-- has CREATE on the relevant schema). Role memberships were likewise temporary.
-- Neither privilege is needed during normal application operation.
-- Future migrations that need OWNER TO may re-grant these temporarily.
REVOKE CREATE ON SCHEMA private FROM forkensics_executor, forkensics_rls_helper;
REVOKE CREATE ON SCHEMA public  FROM forkensics_executor;
REVOKE forkensics_executor   FROM postgres;
REVOKE forkensics_rls_helper FROM postgres;


-- ============================================================
-- SECTION 10 — VIEW
-- ============================================================

-- current_score_events: always the latest revision per challenge
CREATE OR REPLACE VIEW public.current_score_events
  WITH (security_invoker = true)
AS
SELECT se.*
FROM public.score_events se
JOIN (
  SELECT challenge_id, MAX(revision_number) AS max_rev
  FROM public.score_runs
  GROUP BY challenge_id
) latest ON latest.challenge_id = se.challenge_id
JOIN public.score_runs sr
  ON sr.challenge_id = se.challenge_id
  AND sr.revision_number = latest.max_rev
  AND sr.id = se.score_run_id;


-- ============================================================
-- SECTION 11 — ROW LEVEL SECURITY POLICIES
-- ============================================================

-- ---- profiles ------------------------------------------------
CREATE POLICY "profiles_select_own_or_shared_group"
  ON public.profiles FOR SELECT
  USING (id = private.auth_uid() OR private.is_group_member_with(id));

CREATE POLICY "profiles_update_own"
  ON public.profiles FOR UPDATE
  USING (id = private.auth_uid() AND is_active = true);

-- INSERT handled by handle_new_user trigger; no RLS INSERT policy needed

-- ---- rules_versions ------------------------------------------
CREATE POLICY "rules_versions_select_authenticated"
  ON public.rules_versions FOR SELECT
  USING (private.auth_uid() IS NOT NULL);

-- No INSERT/UPDATE/DELETE (protect_rules_versions trigger handles this)

-- ---- media_objects -------------------------------------------
CREATE POLICY "media_objects_select_own"
  ON public.media_objects FOR SELECT
  USING (uploader_id = private.auth_uid());

-- INSERT/UPDATE: service-role Edge Function only (no authenticated policy)

-- ---- groups --------------------------------------------------
CREATE POLICY "groups_select_member"
  ON public.groups FOR SELECT
  USING (private.is_group_member(id));

CREATE POLICY "groups_update_owner"
  ON public.groups FOR UPDATE
  USING (
    EXISTS (
      SELECT 1 FROM public.group_members
      WHERE group_id  = id
        AND player_id = private.auth_uid()
        AND role      = 'owner'
    )
    AND EXISTS (
      SELECT 1 FROM public.profiles
      WHERE id                  = private.auth_uid()
        AND is_active           = true
        AND onboarding_complete = true
    )
  );

-- INSERT: create_group() function only (no direct INSERT policy)

-- ---- group_members -------------------------------------------
CREATE POLICY "group_members_select_member"
  ON public.group_members FOR SELECT
  USING (private.is_group_member(group_id));

-- All mutations via functions only

-- ---- group_invites -------------------------------------------
CREATE POLICY "group_invites_select_creator"
  ON public.group_invites FOR SELECT
  USING (created_by = private.auth_uid());

-- Mutations via functions only

-- ---- challenges ----------------------------------------------
CREATE POLICY "challenges_select"
  ON public.challenges FOR SELECT
  USING (
    poster_id = private.auth_uid()
    OR (posted_at IS NOT NULL AND private.is_challenge_group_member(id))
  );

CREATE POLICY "challenges_insert"
  ON public.challenges FOR INSERT
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.group_members gm
      WHERE gm.group_id  = challenges.group_id
        AND gm.player_id = private.auth_uid()
    )
    AND EXISTS (
      SELECT 1 FROM public.profiles
      WHERE id               = private.auth_uid()
        AND is_active        = true
        AND onboarding_complete = true
    )
  );

CREATE POLICY "challenges_update_poster"
  ON public.challenges FOR UPDATE
  USING (
    poster_id = private.auth_uid()
    AND state = 'draft'
    AND EXISTS (
      SELECT 1 FROM public.profiles
      WHERE id = private.auth_uid() AND is_active = true AND onboarding_complete = true
    )
  );

-- ---- challenge_secrets ---------------------------------------
CREATE POLICY "challenge_secrets_select"
  ON public.challenge_secrets FOR SELECT
  USING (
    private.is_challenge_poster(challenge_id)
    OR (
      private.is_challenge_revealed(challenge_id)
      AND private.is_challenge_group_member(challenge_id)
    )
  );

CREATE POLICY "challenge_secrets_insert"
  ON public.challenge_secrets FOR INSERT
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.challenges
      WHERE id = challenge_secrets.challenge_id AND poster_id = private.auth_uid()
    )
    AND EXISTS (
      SELECT 1 FROM public.profiles
      WHERE id = private.auth_uid() AND is_active = true AND onboarding_complete = true
    )
  );

CREATE POLICY "challenge_secrets_update_poster"
  ON public.challenge_secrets FOR UPDATE
  USING (
    private.is_challenge_poster(challenge_id)
    AND EXISTS (
      SELECT 1 FROM public.profiles
      WHERE id = private.auth_uid() AND is_active = true
    )
  );

-- ---- challenge_answer_aliases --------------------------------
CREATE POLICY "aliases_select_poster_or_revealed"
  ON public.challenge_answer_aliases FOR SELECT
  USING (
    private.is_challenge_poster(challenge_id)
    OR (
      private.is_challenge_revealed(challenge_id)
      AND private.is_challenge_group_member(challenge_id)
    )
  );

CREATE POLICY "aliases_insert_poster"
  ON public.challenge_answer_aliases FOR INSERT
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.challenges c
      JOIN public.challenge_secrets cs ON cs.challenge_id = c.id
      WHERE c.id = challenge_answer_aliases.challenge_id
        AND c.poster_id = private.auth_uid()
        AND c.state IN ('draft', 'active')
        AND NOT cs.has_first_guess
    )
    AND EXISTS (
      SELECT 1 FROM public.profiles
      WHERE id = private.auth_uid() AND is_active = true AND onboarding_complete = true
    )
  );

CREATE POLICY "aliases_update_is_active"
  ON public.challenge_answer_aliases FOR UPDATE
  USING (
    private.is_challenge_poster(challenge_id)
    AND EXISTS (
      SELECT 1 FROM public.profiles
      WHERE id = private.auth_uid() AND is_active = true
    )
  );

-- ---- eligible_participants -----------------------------------
CREATE POLICY "eligible_participants_select_group"
  ON public.eligible_participants FOR SELECT
  USING (private.is_challenge_group_member(challenge_id));

-- INSERT: activate_challenge() only (forkensics_executor)

-- ---- exclusion_events ----------------------------------------
CREATE POLICY "exclusion_events_select_group"
  ON public.exclusion_events FOR SELECT
  USING (private.is_challenge_group_member(challenge_id));

CREATE POLICY "exclusion_events_insert"
  ON public.exclusion_events FOR INSERT
  WITH CHECK (
    -- Self withdrawal: active challenges only; caller must be active and onboarded
    (reason = 'withdrew'
     AND player_id   = private.auth_uid()
     AND excluded_by = private.auth_uid()
     AND private.is_eligible_non_excluded(challenge_id)
     AND EXISTS (
       SELECT 1 FROM public.challenges
       WHERE id = challenge_id AND state = 'active'
     )
     AND EXISTS (
       SELECT 1 FROM public.profiles
       WHERE id = private.auth_uid() AND is_active = true AND onboarding_complete = true
     ))
    OR
    -- Poster or group owner removal: active challenges only; target must be eligible
    (reason = 'removed'
     AND excluded_by = private.auth_uid()
     AND EXISTS (
       SELECT 1 FROM public.profiles
       WHERE id = private.auth_uid() AND is_active = true AND onboarding_complete = true
     )
     AND EXISTS (
       SELECT 1 FROM public.eligible_participants
       WHERE challenge_id = exclusion_events.challenge_id AND player_id = exclusion_events.player_id
     )
     AND EXISTS (
       SELECT 1 FROM public.challenges c
       WHERE c.id = challenge_id AND c.state = 'active'
         AND (
           c.poster_id = private.auth_uid()
           OR EXISTS (
             SELECT 1 FROM public.group_members
             WHERE group_id  = c.group_id
               AND player_id = private.auth_uid()
               AND role      = 'owner'
           )
         )
     ))
    -- account_deleted: handled by forkensics_executor; enforce_exclusion_rules trigger blocks direct insert
  );

-- ---- clues ---------------------------------------------------
CREATE POLICY "clues_select_active_group"
  ON public.clues FOR SELECT
  USING (
    private.is_challenge_group_member(challenge_id)
    AND EXISTS (
      SELECT 1 FROM public.challenges
      WHERE id = challenge_id AND state IN ('active','locked','revealed','cancelled')
    )
  );

CREATE POLICY "clues_insert_poster"
  ON public.clues FOR INSERT
  WITH CHECK (
    poster_id = private.auth_uid()
    AND private.is_challenge_poster(challenge_id)
    AND EXISTS (
      SELECT 1 FROM public.challenges
      WHERE id = challenge_id AND state = 'active'
    )
    AND EXISTS (
      SELECT 1 FROM public.profiles
      WHERE id = private.auth_uid() AND is_active = true AND onboarding_complete = true
    )
  );

-- ---- guess_attempts ------------------------------------------
CREATE POLICY "guess_attempts_select"
  ON public.guess_attempts FOR SELECT
  USING (
    player_id = private.auth_uid()
    OR (
      private.is_challenge_poster(challenge_id)
      AND EXISTS (
        SELECT 1 FROM public.challenges
        WHERE id = challenge_id AND state IN ('active','locked')
      )
    )
    OR (
      private.is_challenge_revealed(challenge_id)
      AND private.is_challenge_group_member(challenge_id)
    )
  );

CREATE POLICY "guess_attempts_insert"
  ON public.guess_attempts FOR INSERT
  WITH CHECK (
    player_id = private.auth_uid()
    AND private.is_eligible_non_excluded(challenge_id)
    AND EXISTS (
      SELECT 1 FROM public.challenges
      WHERE id = challenge_id AND state = 'active'
    )
    AND EXISTS (
      SELECT 1 FROM public.profiles
      WHERE id = private.auth_uid() AND is_active = true AND onboarding_complete = true
    )
  );

-- ---- guess_judgments -----------------------------------------
CREATE POLICY "guess_judgments_select_revealed_group"
  ON public.guess_judgments FOR SELECT
  USING (
    private.is_challenge_revealed(challenge_id)
    AND private.is_challenge_group_member(challenge_id)
  );

-- ---- score_runs ----------------------------------------------
CREATE POLICY "score_runs_select_revealed_group"
  ON public.score_runs FOR SELECT
  USING (
    private.is_challenge_revealed(challenge_id)
    AND private.is_challenge_group_member(challenge_id)
  );

-- ---- score_events --------------------------------------------
CREATE POLICY "score_events_select_revealed_group"
  ON public.score_events FOR SELECT
  USING (
    private.is_challenge_revealed(challenge_id)
    AND private.is_challenge_group_member(challenge_id)
  );

-- ---- correction_events ---------------------------------------
CREATE POLICY "correction_events_select_revealed_group"
  ON public.correction_events FOR SELECT
  USING (
    private.is_challenge_revealed(challenge_id)
    AND private.is_challenge_group_member(challenge_id)
  );

-- ---- comments ------------------------------------------------
-- Table Talk access rule (approved V1 behavior):
--   • Poster can always see and comment (they know the answer).
--   • Eligible member can see/comment once they have locked in a guess.
--   • All eligible members can see once the challenge is revealed.
--   • Soft-deleted rows (deleted_at IS NOT NULL) are hidden from all readers.
CREATE POLICY "comments_select_post_guess_group"
  ON public.comments FOR SELECT
  USING (
    deleted_at IS NULL
    AND private.is_challenge_group_member(challenge_id)
    AND (
      private.is_challenge_poster(challenge_id)
      OR private.is_challenge_revealed(challenge_id)
      OR private.caller_has_guessed(challenge_id)
    )
  );

CREATE POLICY "comments_insert"
  ON public.comments FOR INSERT
  WITH CHECK (
    author_id  = private.auth_uid()
    AND deleted_at IS NULL   -- prevent inserting a pre-deleted comment
    AND private.is_challenge_group_member(challenge_id)
    AND (
      private.is_challenge_poster(challenge_id)
      OR private.is_challenge_revealed(challenge_id)
      OR private.caller_has_guessed(challenge_id)
    )
    AND EXISTS (
      SELECT 1 FROM public.profiles
      WHERE id = private.auth_uid() AND is_active = true AND onboarding_complete = true
    )
  );

CREATE POLICY "comments_update_own"
  ON public.comments FOR UPDATE
  USING (
    author_id = private.auth_uid()
    AND EXISTS (
      SELECT 1 FROM public.profiles
      WHERE id = private.auth_uid() AND is_active = true
    )
  )
  -- Explicit WITH CHECK so PostgreSQL does NOT fall back to the SELECT policy's
  -- USING clause (which requires deleted_at IS NULL).  We must allow the UPDATE
  -- that sets deleted_at (soft-delete), so the WITH CHECK mirrors USING exactly
  -- but omits deleted_at IS NULL.
  WITH CHECK (
    author_id = private.auth_uid()
    AND EXISTS (
      SELECT 1 FROM public.profiles
      WHERE id = private.auth_uid() AND is_active = true
    )
  );

-- ---- reactions -----------------------------------------------
-- Same Table Talk access rule as comments.
CREATE POLICY "reactions_select_post_guess_group"
  ON public.reactions FOR SELECT
  USING (
    private.is_challenge_group_member(challenge_id)
    AND (
      private.is_challenge_poster(challenge_id)
      OR private.is_challenge_revealed(challenge_id)
      OR private.caller_has_guessed(challenge_id)
    )
  );

CREATE POLICY "reactions_insert"
  ON public.reactions FOR INSERT
  WITH CHECK (
    player_id = private.auth_uid()
    AND private.is_challenge_group_member(challenge_id)
    AND (
      private.is_challenge_poster(challenge_id)
      OR private.is_challenge_revealed(challenge_id)
      OR private.caller_has_guessed(challenge_id)
    )
    AND EXISTS (
      SELECT 1 FROM public.profiles WHERE id = private.auth_uid() AND is_active = true
    )
  );

CREATE POLICY "reactions_delete_own"
  ON public.reactions FOR DELETE
  USING (
    player_id = private.auth_uid()
    AND EXISTS (
      SELECT 1 FROM public.profiles
      WHERE id = private.auth_uid() AND is_active = true
    )
  );


-- ============================================================
-- SECTION 12 — PRIVILEGE MODEL
-- ============================================================

-- Revoke table and sequence defaults first (postgres owns these objects so no
-- special role membership is required here).
-- NOTE: Function privilege management is handled in the block below, where role
-- memberships are temporarily re-granted. Supabase's local postgres is not a
-- superuser (rolsuper=false), so it cannot GRANT/REVOKE on functions owned by
-- forkensics_executor or forkensics_rls_helper without active membership.
REVOKE ALL ON ALL TABLES    IN SCHEMA public  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON ALL TABLES    IN SCHEMA private FROM PUBLIC, anon, authenticated;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA private FROM PUBLIC, anon, authenticated;

-- ---- authenticated table grants ------------------------------
GRANT SELECT ON public.profiles TO authenticated;
GRANT UPDATE (display_name, avatar_color, avatar_media_object_id, onboarding_complete)
  ON public.profiles TO authenticated;

GRANT SELECT ON public.rules_versions TO authenticated;

GRANT SELECT ON public.media_objects TO authenticated;

GRANT SELECT ON public.groups TO authenticated;
GRANT UPDATE (name, archived_at) ON public.groups TO authenticated;

GRANT SELECT ON public.group_members TO authenticated;

GRANT SELECT ON public.group_invites TO authenticated;

GRANT SELECT, INSERT ON public.challenges TO authenticated;
GRANT UPDATE (media_object_id, duration_seconds, public_city_display)
  ON public.challenges TO authenticated;

GRANT SELECT, INSERT ON public.challenge_secrets TO authenticated;
GRANT UPDATE (display_dish, canonical_dish, display_restaurant,
              canonical_restaurant, story)
  ON public.challenge_secrets TO authenticated;

GRANT SELECT, INSERT ON public.challenge_answer_aliases TO authenticated;
GRANT UPDATE (is_active) ON public.challenge_answer_aliases TO authenticated;

GRANT SELECT ON public.eligible_participants TO authenticated;

GRANT SELECT, INSERT ON public.exclusion_events TO authenticated;

GRANT SELECT, INSERT ON public.clues TO authenticated;

GRANT SELECT, INSERT ON public.guess_attempts TO authenticated;

GRANT SELECT ON public.guess_judgments  TO authenticated;
GRANT SELECT ON public.score_runs       TO authenticated;
GRANT SELECT ON public.score_events     TO authenticated;
GRANT SELECT ON public.correction_events TO authenticated;

GRANT SELECT, INSERT ON public.comments TO authenticated;
GRANT UPDATE (deleted_at) ON public.comments TO authenticated;

GRANT SELECT, INSERT, DELETE ON public.reactions TO authenticated;

GRANT SELECT ON public.current_score_events TO authenticated;

-- ---- Function privilege management ---------------------------
-- Temporarily re-grant forkensics_executor and forkensics_rls_helper to postgres.
-- postgres (rolsuper=false in Supabase) cannot GRANT/REVOKE on functions owned by
-- these roles without membership. Section 9B revoked these memberships for runtime
-- safety; we re-grant here for function privilege management only, then revoke
-- again at the end of this block (below the specific revokes).
GRANT forkensics_executor   TO postgres;
GRANT forkensics_rls_helper TO postgres;

-- Wipe default PUBLIC EXECUTE from all functions in both schemas
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA public  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA private FROM PUBLIC, anon, authenticated;

-- ---- authenticated function grants ---------------------------
GRANT EXECUTE ON FUNCTION public.create_group(text)                               TO authenticated;
GRANT EXECUTE ON FUNCTION public.transfer_group_ownership(uuid, uuid)             TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_group_invite(uuid)                        TO authenticated;
GRANT EXECUTE ON FUNCTION public.redeem_group_invite(text)                        TO authenticated;
GRANT EXECUTE ON FUNCTION public.revoke_group_invite(uuid)                        TO authenticated;
GRANT EXECUTE ON FUNCTION public.activate_challenge(uuid)                         TO authenticated;
GRANT EXECUTE ON FUNCTION public.reveal_challenge(uuid)                           TO authenticated;
GRANT EXECUTE ON FUNCTION public.cancel_challenge(uuid, text)                     TO authenticated;
GRANT EXECUTE ON FUNCTION public.apply_correction(uuid, text, text, text, uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.soft_delete_comment(uuid)                        TO authenticated;

-- RLS helper access for authenticated
GRANT USAGE ON SCHEMA private TO authenticated;
GRANT EXECUTE ON FUNCTION private.is_group_member(uuid)           TO authenticated;
GRANT EXECUTE ON FUNCTION private.is_group_member_with(uuid)      TO authenticated;
GRANT EXECUTE ON FUNCTION private.is_challenge_group_member(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION private.is_challenge_poster(uuid)       TO authenticated;
GRANT EXECUTE ON FUNCTION private.is_challenge_revealed(uuid)     TO authenticated;
GRANT EXECUTE ON FUNCTION private.is_eligible_non_excluded(uuid)  TO authenticated;
GRANT EXECUTE ON FUNCTION private.caller_has_guessed(uuid)        TO authenticated;
-- normalize_answer is called from the guard_alias_edits trigger which runs as the
-- caller (not SECURITY DEFINER), so authenticated needs EXECUTE here as well.
-- The function is IMMUTABLE/pure (text→text) with no side-effects.
GRANT EXECUTE ON FUNCTION private.normalize_answer(text)          TO authenticated;
-- auth_uid() is called from SECURITY DEFINER functions and RLS policies; all
-- non-public roles need EXECUTE so the post-REVOKE wipe doesn't break them.
GRANT EXECUTE ON FUNCTION private.auth_uid()                      TO authenticated, forkensics_executor, forkensics_rls_helper, service_role;

-- ---- service_role function grants ----------------------------
GRANT EXECUTE ON FUNCTION public.lock_challenge(uuid)                      TO service_role;
GRANT EXECUTE ON FUNCTION private.reveal_challenge_service(uuid)           TO service_role;
GRANT EXECUTE ON FUNCTION private.prepare_account_deletion(uuid)           TO service_role;
GRANT EXECUTE ON FUNCTION private.get_storage_keys_for_deletion(uuid)     TO service_role;
GRANT EXECUTE ON FUNCTION private.mark_auth_deleted(uuid)                  TO service_role;
GRANT EXECUTE ON FUNCTION private.mark_storage_cleaned(uuid)               TO service_role;
GRANT EXECUTE ON FUNCTION private.record_deletion_failure(uuid, text)      TO service_role;

-- Explicitly revoke service-only and deletion functions from non-service clients
REVOKE EXECUTE ON FUNCTION public.lock_challenge(uuid)                    FROM PUBLIC, anon, authenticated;
-- public.reveal_challenge is authenticated-only; revoke from service_role (uses private entry point)
REVOKE EXECUTE ON FUNCTION public.reveal_challenge(uuid)                  FROM PUBLIC, anon, service_role;
REVOKE EXECUTE ON FUNCTION private.reveal_challenge_service(uuid)         FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION private.do_reveal_impl(uuid)                   FROM PUBLIC, anon, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION private.prepare_account_deletion(uuid)         FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION private.get_storage_keys_for_deletion(uuid)   FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION private.mark_auth_deleted(uuid)                FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION private.mark_storage_cleaned(uuid)             FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION private.record_deletion_failure(uuid, text)    FROM PUBLIC, anon, authenticated;

-- Restore Section 9B state: remove temporary role memberships from postgres.
REVOKE forkensics_executor   FROM postgres;
REVOKE forkensics_rls_helper FROM postgres;

-- ---- forkensics_executor table grants ------------------------
GRANT USAGE ON SCHEMA public, private TO forkensics_executor;
GRANT SELECT, INSERT, UPDATE ON
  public.challenges, public.challenge_secrets, public.challenge_answer_aliases,
  public.eligible_participants, public.exclusion_events, public.guess_attempts,
  public.guess_judgments, public.score_runs, public.score_events,
  public.correction_events, public.groups, public.group_members,
  public.group_invites, public.profiles, public.clues, public.comments,
  public.reactions, public.media_objects, public.rules_versions
TO forkensics_executor;

GRANT ALL ON private.profile_archive, private.media_storage_keys, private.deletion_log
  TO forkensics_executor;

-- Sequence: executor only
GRANT USAGE, SELECT ON SEQUENCE public.guess_receipt_seq TO forkensics_executor;

-- ---- forkensics_rls_helper grants ----------------------------
GRANT USAGE ON SCHEMA public, private TO forkensics_rls_helper;
GRANT SELECT ON
  public.profiles, public.group_members, public.challenges,
  public.eligible_participants, public.exclusion_events,
  public.guess_attempts   -- required by private.caller_has_guessed (Table Talk RLS helper)
TO forkensics_rls_helper;

-- ---- Default privileges (future objects) ---------------------
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  REVOKE ALL ON TABLES FROM PUBLIC, anon, authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  REVOKE ALL ON SEQUENCES FROM PUBLIC, anon, authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  REVOKE ALL ON FUNCTIONS FROM PUBLIC, anon, authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA private
  REVOKE ALL ON TABLES FROM PUBLIC, anon, authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA private
  REVOKE ALL ON FUNCTIONS FROM PUBLIC, anon, authenticated;


-- ============================================================
-- SECTION 13 — SEED DATA
-- ============================================================

INSERT INTO public.rules_versions (id, version_tag, description, config)
VALUES (
  'a0000000-0000-0000-0000-000000000001',
  'v1',
  'Forkensics v1 rules: ordinal_ranking, dual-race (what/where), city is optional context',
  '{
    "scoring_algorithm":              "ordinal_ranking_v1",
    "races":                          ["what", "where"],
    "what_race_field":                "dish",
    "where_race_fields":              ["restaurant"],
    "points_formula":                 "effective_eligible_count - rank + 1",
    "min_points":                     1,
    "no_correct_answer_points":       0,
    "partial_credit":                 false,
    "tie_breaking":                   "receipt_sequence_ascending",
    "alias_aware_matching":           true,
    "default_duration_seconds":       7200,
    "min_duration_seconds":           3600,
    "max_duration_seconds":           86400,
    "duration_step_seconds":          3600,
    "normalization_version":          "v1",
    "normalization_steps":            ["lowercase", "remove_non_alphanumeric_non_space", "collapse_whitespace", "trim"]
  }'::jsonb
)
ON CONFLICT (id) DO NOTHING;


-- ============================================================
-- END OF MIGRATION
-- ============================================================
-- Tables:    profiles, rules_versions, media_objects, groups, group_members,
--            group_invites, challenges, challenge_secrets, challenge_answer_aliases,
--            eligible_participants, exclusion_events, clues, guess_attempts,
--            correction_events, score_runs, guess_judgments, score_events,
--            comments, reactions (19 public)
--            + private.media_storage_keys, private.profile_archive,
--              private.deletion_log (3 private)
-- Views:     current_score_events (security_invoker=true)
-- Functions: 6 private RLS helpers + 11 public operational + 1 private operational = 17
-- Triggers:  on_auth_user_created, challenge_create_fields, challenge_protect_fields,
--            challenge_secrets_guard, challenge_secrets_timestamps,
--            alias_guard_insert, alias_guard_update, guess_receipt,
--            rules_versions_immutable, comment_update_guard,
--            clues/comments/reactions/exclusion_events timestamp triggers (4),
--            exclusion_enforce, profile_lock_onboarding, profile_avatar_ownership,
--            guess_judgment_consistency, score_event_consistency = 20 triggers
-- Roles:     forkensics_executor (NOLOGIN), forkensics_rls_helper (NOLOGIN)
-- Sequence:  guess_receipt_seq
-- =============================================================================
