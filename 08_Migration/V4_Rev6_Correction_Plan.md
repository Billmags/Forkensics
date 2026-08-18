# V4 Migration — R6 Correction Plan

**Input file:** `V4__case_investigation_schema.sql`
**Input SHA-256:** `ddfcadcf9667e9d7e02d03780a7abb7de8a3eb1f2e1a35b781ac1542f8c9a15b`
**Prepared by:** Claude (static analysis, no SQL executed, no cloud operations)
**Status:** AWAITING THREE-PARTY APPROVAL before any SQL edit

---

## Six Blockers — Summary

| # | Label | Location | Severity |
|---|-------|----------|----------|
| R6-B1 | Role grants too late | Line ~778 vs Phase 2A at line ~91 | Migration fails |
| R6-B2 | `reserve_upload_session` wrong signature | Lines 100–161 | Runtime crash |
| R6-B3 | Wrong constraint name dropped | Line 647 | Old UNIQUE survives |
| R6-B4 | `guess_attempts.investigation_id` nonexistent | Line 1049 | Migration fails |
| R6-B5 | Phase 16 UPDATE blocked by V1 trigger | Line 1519 | Migration fails |
| R6-B6 | Lock order inversion in photo functions | Lines 2266–2365 | Deadlock risk |

---

## R6-B1 — Role grants precede Phase 2A

### Root cause
Phase 13C (line 778) is the first place `GRANT forkensics_executor TO postgres` appears.
Phase 2A (line ~91) and the newly-inserted Phase 2B (line ~306) execute `ALTER FUNCTION … OWNER TO forkensics_executor` before that grant exists.
On Supabase, `postgres` is not a superuser; it requires explicit role membership to change function ownership. The migration will abort on the first `OWNER TO` in Phase 2A/2B.

### Fix
Move the six grant lines from Phase 13C to **immediately before Phase 2A** (above line 91), and keep the matching REVOKEs at lines 4300–4305 unchanged:

```sql
-- ---- EARLY ROLE GRANTS — required for OWNER TO operations in Phase 2A/2B ----
-- (Matching REVOKEs are at the end of Phase 20.)
GRANT forkensics_executor   TO postgres;
GRANT forkensics_rls_helper  TO postgres;
GRANT CREATE ON SCHEMA private TO forkensics_executor, forkensics_rls_helper;
GRANT CREATE ON SCHEMA public  TO forkensics_executor;
```

Leave Phase 13C as a comment-only block explaining that the grants were moved earlier.

---

## R6-B2 — `reserve_upload_session` wrong signature

### Root cause
The Rev 15 contract requires `p_case_id` as the first parameter name and a `GRANT EXECUTE TO service_role`.
The current code at lines 100–161 uses `CREATE OR REPLACE FUNCTION` (cannot rename OUT parameters) and retains `p_challenge_id` as both the parameter name and inside the body.
V2 registered the function as `reserve_upload_session(uuid,uuid,text,text,bigint,timestamptz)` owned by `forkensics_executor`. Merely replacing the body without a DROP leaves the parameter names unchanged in the catalog.

### Fix
Replace the Phase 5B.1 block with REVOKE + DROP + CREATE + GRANT:

```sql
-- ---- 5B.1  reserve_upload_session — V4 version (p_case_id; service_role access) ----
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
```

---

## R6-B3 — Wrong constraint name dropped

### Root cause
V1 created `score_runs` with `UNIQUE(challenge_id, revision_number)`. PostgreSQL auto-named this constraint `score_runs_challenge_id_revision_number_key`. V2 renamed the column to `case_id` via `ALTER TABLE … RENAME COLUMN`, which does **not** rename the constraint. The constraint in the live database is therefore named `score_runs_challenge_id_revision_number_key`, not `score_runs_case_id_revision_number_key`.

The R5 patcher drops `score_runs_case_id_revision_number_key` (line 647), which does nothing (IF EXISTS swallows it silently), leaving the old unique constraint intact. Multiple investigations per case will then share revision 1 — which violates the new B6 contract.

### Fix
Change line 647 to use the correct V1-generated name:

```sql
-- R6-B3: The V1 constraint name uses the original column name challenge_id.
ALTER TABLE public.score_runs
  DROP CONSTRAINT IF EXISTS score_runs_challenge_id_revision_number_key;
```

Keep the `DROP CONSTRAINT IF EXISTS score_runs_case_id_revision_number_key` line as a safety net drop (harmless no-op either way), or remove it to reduce noise.

---

## R6-B4 — `guess_attempts.investigation_id` does not exist

### Root cause
The R5 B8 policy at line 1049 references `guess_attempts.investigation_id`:
```sql
AND im_viewer.investigation_id = guess_attempts.investigation_id
```
`guess_attempts` has no `investigation_id` column. PostgreSQL will reject this at DDL time and abort the migration.

The correct way to anchor the viewer's investigation to the guess row is through `investigations.case_id = guess_attempts.case_id` (case_id **does** exist on guess_attempts).
Only the viewer's eligibility needs to be checked; the guess owner just needs to be in the same investigation.

### Fix — replace the policy body

```sql
-- 3. Co-investigator: viewer must share an investigation with guess owner (R6-B4)
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
```

Key differences from R5:
- `inv.case_id = guess_attempts.case_id` anchors the investigation to the case (not `guess_attempts.investigation_id`)
- The `im_viewer.investigation_id = guess_attempts.investigation_id` predicate is removed entirely
- Only `im_viewer.eligibility_status = 'eligible'` is checked (not the owner's eligibility)

---

## R6-B5 — Phase 16 `active → launched` UPDATE blocked by V1 trigger

### Root cause
The V1 trigger `challenge_protect_fields` (function `public.protect_challenge_authority_fields`) fires `BEFORE UPDATE` on `public.cases` (renamed from `public.challenges` in Phase 2). Its body rejects all state changes unless `current_user = 'forkensics_executor'`.

Phase 16 (line 1519) runs:
```sql
UPDATE public.cases SET state = 'launched' WHERE state = 'active';
```
as `postgres`. Phase 19.2 is where `protect_case_authority_fields` replaces `protect_challenge_authority_fields` — but that is **after** Phase 16. The trigger therefore rejects the Phase 16 UPDATE.

### Fix
Temporarily disable the trigger around the Phase 16 state conversion. After Phase 13C grants (now moved to the top per R6-B1), postgres has forkensics_executor membership, but `ALTER TABLE DISABLE TRIGGER` is the cleaner migration-safe option:

```sql
-- Step 3: convert 'active' → 'launched'
-- R6-B5: disable the V1 protect_challenge_authority_fields trigger for this
--        controlled state rename; it will be replaced in Phase 19.2.
ALTER TABLE public.cases DISABLE TRIGGER challenge_protect_fields;
UPDATE public.cases SET state = 'launched' WHERE state = 'active';
ALTER TABLE public.cases ENABLE TRIGGER challenge_protect_fields;
```

`challenge_protect_fields` is the trigger name from V1 line 866. The trigger body is replaced in Phase 19.2 immediately after, so the gap is confined to exactly these three statements.

---

## R6-B6 — Lock order inversion in `approve_photo` / `reject_photo`

### Root cause
Every other function that touches both cases and media rows acquires locks in this order:
1. Provisional case lookup (no lock)
2. Case lock (`SELECT … FOR UPDATE`)
3. Linkage revalidation
4. Media lock (`SELECT … FOR UPDATE`)

`approve_photo` and `reject_photo` (introduced in R5 B13) do media lock first, then touch the case row (UPDATE). Concurrent calls to `remove_media`, `report_content`, or `finalize_upload_session` — which all use case-first order — can deadlock against the photo functions.

### Fix — both functions need the same case-first pattern

**`approve_photo` corrected DECLARE + body:**

```sql
DECLARE
  v_case_id   uuid;
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
```

**`reject_photo` corrected DECLARE + body:**

```sql
DECLARE
  v_case_id     uuid;
  v_case        record;
  v_media       record;
  v_action_id   uuid;
  v_sha256      text;
  v_storage_key text;
BEGIN
  -- validate moderator
  IF NOT EXISTS (
    SELECT 1 FROM private.moderators m
    JOIN public.profiles p ON p.id = m.profile_id
    WHERE m.profile_id = p_moderator_id AND p.is_active = true
  ) THEN RAISE EXCEPTION 'FK_UNAUTHORIZED: moderator identity not valid'; END IF;

  -- Step 1: provisional case lookup
  SELECT id INTO v_case_id FROM public.cases
  WHERE media_object_id = p_media_object_id LIMIT 1;
  IF v_case_id IS NULL THEN RAISE EXCEPTION 'FK_NOT_FOUND'; END IF;

  -- Step 2: lock case first
  SELECT id, state, media_object_id INTO v_case
  FROM public.cases WHERE id = v_case_id FOR UPDATE;

  -- Step 3: revalidate linkage
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
```

---

## Changes Excluded from R6

The following R5 fixes are confirmed correct and must **not** be altered:
- GOV-1/GOV-2 (schema-qualify index rename; no CASCADE)
- B1 (all 33 policy orderings)
- B3 (DISABLE/ENABLE TRIGGER around Phase 4 backfill)
- B4 (Phase 2B block + Path 0 in Phase 19.6)
- B5 (fail-closed `check_text_content_trigger` in Phase 2B + 20B.1)
- B7 (`investigation_id` in `v_score_run` SELECT)
- B9 (`hide_blocked_cases` investigation_members carve-out)
- B10 (`is_case_poster` before membership in `report_content`)
- B11 (UNION ALL in `get_reported_media`)
- B12 (all 4 idempotency paths; v_media lock)
- B2/DROP on `get_moderation_queue` and `get_pending_review_media` (column rename)

---

## Proposed Edit Sequence for R7 Patcher

1. **GOV (B1-prefix):** Insert early role grants block before Phase 2A line 91
2. **R6-B2:** Replace lines 99–161 with REVOKE+DROP+CREATE+GRANT for `reserve_upload_session`
3. **R6-B3:** Change `score_runs_case_id_revision_number_key` → `score_runs_challenge_id_revision_number_key` at line 647
4. **R6-B4:** Replace `guess_investigation_revealed_view` policy body (remove `guess_attempts.investigation_id` predicate)
5. **R6-B5:** Wrap Phase 16 UPDATE with DISABLE/ENABLE TRIGGER on `challenge_protect_fields`
6. **R6-B6:** Replace `approve_photo` body (add v_case_id + case-first lock)
7. **R6-B6:** Replace `reject_photo` body (add v_case_id + case-first lock)

---

*This plan is TEXT ONLY. No files were modified. No migration was run. No cloud operations were performed. Awaiting three-party approval (Bill + Claude + Codex) before proceeding to R7 patcher.*
