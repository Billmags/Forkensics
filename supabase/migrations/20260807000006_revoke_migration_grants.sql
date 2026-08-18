-- 20260807000006_revoke_migration_grants.sql
-- Least-privilege remediation combining two actions atomically:
--
-- (A) Narrow the profiles SELECT grant to column level.
--     000005 granted table-level SELECT to service_role. The upload-authorize
--     function needs only four columns. REVOKE the table-level grant and replace
--     with a column-level grant.
--
-- (B) Revoke temporary migration capabilities from Phase 2b execution.
--     Grant A (forkensics_executor TO postgres WITH SET TRUE) and
--     Grant B (CREATE ON SCHEMA public TO forkensics_executor) were applied
--     live during Phase 2b to work around a PostgreSQL 16 SET ROLE restriction.
--     They are not runtime requirements. Migration 000004 follows the V2 pattern
--     of self-contained grant/revoke, so these capability grants must not persist.
--
-- MAINTENANCE NOTE: Future migrations that CREATE OR REPLACE a function owned by
-- forkensics_executor must re-grant Grants A and B within the migration transaction
-- (as 000004 does), then revoke them at the end of the same transaction.

BEGIN;

-- (A) Column-level profiles narrowing.
REVOKE SELECT ON public.profiles FROM service_role;
GRANT SELECT (id, is_active, onboarding_complete, is_suspended)
  ON public.profiles TO service_role;

-- (B) Revoke Phase 2b temporary migration capabilities.
REVOKE CREATE ON SCHEMA public FROM forkensics_executor;
REVOKE forkensics_executor FROM postgres;

COMMIT;
