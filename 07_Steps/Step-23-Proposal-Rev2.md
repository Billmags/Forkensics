# Step 23 Proposal — Rev 2 — Forkensics Supabase Cloud Foundation

**Status:** Pending review (Claude → Codex/GPT → Bill approval)
**Governance gate:** Bill must type `APPROVED: Step 23 — Supabase Cloud Foundation` before any cloud resource is created.
**Sub-gates (within this step):**
- `APPROVED: Apply frozen V1 to forkensics-dev`
- `APPROVED: Apply frozen V1 to forkensics-prod`

**Scope boundary — what this step is NOT:**
- No Edge Function code
- No application code
- No production traffic
- No `supabase db reset --linked` (destructive — never run against a cloud project)
- No secrets sent to Claude

---

## Overview

This step establishes the permanent Supabase cloud infrastructure for Forkensics in the correct order: source control first, then cloud projects, then CLI linking, then credentials, then migration deployment to dev, then verification, then production. Each phase is a gate for the next.

---

## Phase A — Source Control

The WhatAndWhere folder is not currently a Git repository. Source control must exist before anything is committed or linked.

### A1 — Initialize a private Git repository

Bill creates a new **private** repository (GitHub or equivalent) named `WhatAndWhere` and initializes it locally:

```bash
cd ~/Desktop/WhatAndWhere
git init
git remote add origin <private-repo-url>
```

### A2 — Add `.gitignore`

Create `~/Desktop/WhatAndWhere/.gitignore` with the following content:

```
# Supabase local state — never commit
supabase/.temp/
supabase/.branches/

# Environment and credentials — never commit
.env
.env.*
*.env
*.pem
*.key
secrets/

# macOS
.DS_Store

# Xcode user state
*.xcuserstate
xcuserdata/
*.xccheckout
*.moved-to-trash/
DerivedData/

# Logs
*.log
```

Supabase explicitly requires committing `supabase/config.toml` and migration files, while `.temp/` and `.branches/` must not be committed.

### A3 — Commit and tag the V1 baseline

```bash
git add .
git commit -m "V1 database baseline — frozen 2026-08-07

Migration SHA-256: 2581412af146acdaaf9a7139c98a208fa4b1fe1a355ee14e043f9117b6f3afc3
Tests SHA-256:     5d1e2e25ccfb232be985c2e08acfeda0966bedf9fee3c8921f58eda7aa8046c3
Approved by Bill and GPT/Codex 2026-08-07"

git tag v1-database-baseline
git push -u origin main --tags
```

### A4 — Create Supabase migration directory

```bash
mkdir -p ~/Desktop/WhatAndWhere/supabase/migrations
```

Create a deployment copy of the frozen migration under the Supabase-tracked path. The filename must use a UTC timestamp prefix so Supabase migration ordering is unambiguous:

```bash
cp 08_Migration/V1__initial_schema.sql \
   supabase/migrations/20260807000000_v1_initial_schema.sql
```

Verify the copy matches the frozen artifact before committing:

```bash
sha256sum 08_Migration/V1__initial_schema.sql \
          supabase/migrations/20260807000000_v1_initial_schema.sql
# Both lines must show: 2581412af146acdaaf9a7139c98a208fa4b1fe1a355ee14e043f9117b6f3afc3
```

The original frozen file is never modified. The copy under `supabase/migrations/` is what Supabase CLI uses for deployment.

Commit the migration copy:

```bash
git add supabase/migrations/20260807000000_v1_initial_schema.sql
git commit -m "Add V1 migration to Supabase migrations directory"
git push
```

---

## Phase B — Project Creation

Log in to [supabase.com](https://supabase.com) as the Forkensics account owner (Bill).

**Do not reuse any project, org, or credential from prior apps.**

Create a new organization if needed. Do not use a personal org.

### B1 — Create `forkensics-dev`

- Organization: Forkensics
- Project name: `forkensics-dev`
- Region: **North Virginia (us-east-1)** — pilot players are primarily East Coast
- Database password: strong random password — save to 1Password immediately

### B2 — Create `forkensics-prod`

- Organization: Forkensics
- Project name: `forkensics-prod`
- Region: same — **North Virginia (us-east-1)**
- Database password: different strong random password — save to 1Password

**Region note:** Supabase projects cannot be migrated to a different region after creation. Creating a project in a different region later requires a new project and data migration. North Virginia is chosen because the pilot group is primarily East Coast. For most projects Supabase recommends a general region selection based on user geography; no region offers earlier feature access or better support coverage than another.

---

## Phase C — Credentials

For each project: Dashboard → Project Settings → API.

Use Supabase's current key model. Legacy `anon` and `service_role` keys are being deprecated.

| Key | Name | Used by |
|---|---|---|
| Publishable key | `SUPABASE_PUBLISHABLE_KEY` | iOS client |
| Secret key | `SUPABASE_SECRET_KEY` | Trusted backend (Edge Functions) only |
| Project JWKS | auto-provided to hosted functions | JWT verification in Edge Functions |

**Storage rules:**
- All keys stored in 1Password (or equivalent vault)
- Secret key never in client code, never in the repo, never sent to Claude
- Publishable key is safe to expose (it is designed to be public) but not needed by Claude during this infrastructure step
- Do not copy or store the legacy JWT secret unless a later approved design proves it necessary — hosted Edge Functions receive the appropriate keys as environment variables automatically

---

## Phase D — CLI Linking

Only one project is actively linked at a time. Explicitly relink before every dev or production operation to prevent accidentally deploying to the wrong project.

```bash
# Initialize Supabase config if not already present
supabase init   # creates supabase/config.toml if it doesn't exist

# Link to dev
supabase link --project-ref <dev-project-ref>

# Confirm which project is linked
supabase projects list
# Look for your dev project ref — verify it matches before any push
```

**`supabase/config.toml` path** (the committed file) is at `supabase/config.toml`, not `.supabase/config.toml`. The linked state is stored under `supabase/.temp/` which is gitignored and must not be committed.

**`supabase status` shows the local stack**, not which cloud project is linked. Always use `supabase projects list` and visually confirm the project ref before a cloud operation.

Commit `supabase/config.toml` (project ref only — no credentials):

```bash
git add supabase/config.toml
git commit -m "Link Supabase CLI to forkensics-dev"
git push
```

---

## Phase E — Storage Bucket Creation

Create the private storage bucket through the Supabase Dashboard (Storage → New bucket) for each project. Do not modify the `storage` schema directly.

**For `forkensics-dev` and `forkensics-prod`:**

| Setting | Value |
|---|---|
| Bucket name | `game-media` |
| Public | Off |
| File size limit | 10 MB |
| Allowed MIME types | `image/jpeg`, `image/webp` |

After creation, verify and record:
- Bucket ID (from dashboard)
- Public: false
- Size limit: 10 MB

No storage policies are configured in this step — that is the media Edge Function's responsibility. The bucket remains empty until the media step.

---

## Phase F — Apply V1 Migration to Dev

**Gate: Bill types `APPROVED: Apply frozen V1 to forkensics-dev` before running.**

```bash
# Confirm linked to dev
supabase projects list   # verify dev project ref is active

# Dry run first — shows what would be applied, makes no changes
supabase db push --dry-run

# Apply
supabase db push

# Confirm migration is recorded in Supabase's migration history
supabase migration list
# Expected: one entry — 20260807000000_v1_initial_schema
```

If `db push` reports the migration is already applied (unlikely on a fresh project), do not force. Investigate before proceeding.

---

## Phase G — Verify Dev Deployment

Run the frozen acceptance test suite directly against the dev project. This verifies the hosted schema matches V1 exactly.

**First, verify the test file hash:**

```bash
sha256sum 08_Migration/tests/V1_acceptance_tests.sql
# Expected: 5d1e2e25ccfb232be985c2e08acfeda0966bedf9fee3c8921f58eda7aa8046c3
```

**Run the acceptance tests** (the SQL file itself wraps everything in `BEGIN … ROLLBACK` — it is transactional and non-destructive; it does not reset the database):

```bash
psql "$DEV_DB_URL" \
  --set ON_ERROR_STOP=on \
  -f 08_Migration/tests/V1_acceptance_tests.sql
```

Do not run the `run_tests_full.sh` wrapper — that script calls `supabase db reset` which is destructive and must never be run against a cloud project.

**Verification also confirms:**
- Migration history entry exists (`supabase migration list`)
- Tables and views: all objects in `12_Releases/V1_Database_Baseline.md`
- Functions and ownership: `forkensics_executor`, `forkensics_rls_helper`
- Triggers: present on covered tables
- RLS policies: enabled on all tables that require them
- Grants: `authenticated` role has the correct column-level grants
- Seeded `rules_versions` row present

The acceptance test suite covers all of the above as assertions. A clean run (240 assertions, all passing) is sufficient evidence.

---

## Phase H — Apply V1 Migration to Prod

**Gate: Phase G passes cleanly. Bill types `APPROVED: Apply frozen V1 to forkensics-prod`.**

```bash
# Relink to prod
supabase link --project-ref <prod-project-ref>
supabase projects list   # confirm prod ref

# Dry run
supabase db push --dry-run

# Apply
supabase db push

# Confirm
supabase migration list
```

**Prod verification:** Read-only catalog checks only — no acceptance suite against production.

```bash
psql "$PROD_DB_URL" --set ON_ERROR_STOP=on -c "
SELECT table_schema, table_name
FROM information_schema.tables
WHERE table_schema IN ('public','private')
ORDER BY table_schema, table_name;
"

psql "$PROD_DB_URL" -c "
SELECT rolname FROM pg_roles
WHERE rolname IN ('forkensics_executor','forkensics_rls_helper')
ORDER BY rolname;
"

psql "$PROD_DB_URL" -c "
SELECT version FROM public.rules_versions LIMIT 1;
"
```

All three queries must return the expected results. No data mutation, no test transactions against prod.

---

## Out of Scope for Step 23

- Edge Function deployment (any function)
- Storage RLS policies and upload authorization
- Auth configuration (Sign in with Apple provider setup)
- Email templates
- Any iOS application code
- Push notification configuration
- Realtime configuration
- Any data seeding beyond the `rules_versions` row in the V1 migration

---

## Success Criteria for Step 23

- [ ] Private Git repository created and linked
- [ ] `.gitignore` in place; `supabase/.temp/` and credentials excluded
- [ ] V1 baseline committed and tagged `v1-database-baseline`
- [ ] `supabase/migrations/20260807000000_v1_initial_schema.sql` added; SHA-256 verified against frozen original
- [ ] `forkensics-dev` created in `us-east-1` under Forkensics org
- [ ] `forkensics-prod` created in `us-east-1` under Forkensics org; separate database password
- [ ] All credentials in 1Password; none in repo; secret key never sent to Claude
- [ ] `game-media` bucket (private, 10 MB limit) created in both projects
- [ ] CLI linked to dev; `supabase/config.toml` committed
- [ ] `APPROVED: Apply frozen V1 to forkensics-dev` received
- [ ] `supabase db push` applied to dev; `supabase migration list` confirms V1 recorded
- [ ] Acceptance tests pass against dev (240 assertions, exit 0)
- [ ] `APPROVED: Apply frozen V1 to forkensics-prod` received
- [ ] `supabase db push` applied to prod; `supabase migration list` confirms V1 recorded
- [ ] Read-only catalog verification passes against prod

---

## What Comes After Step 23

Per the approved sequence:

- **Next:** Local SwiftUI prototype (core screens with fake data, no backend)
- **Then:** Edge Function contracts defined and approved
- **Then:** Edge Function implementation, one function at a time
