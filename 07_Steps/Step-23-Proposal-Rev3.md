# Step 23 Proposal — Rev 3 — Forkensics Supabase Cloud Foundation

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
- No manual Dashboard or SQL Editor fixes to migration state
- No secrets sent to Claude

---

## Overview

This step establishes the permanent Supabase cloud infrastructure for Forkensics in the correct order: source control first, then cloud projects, then CLI linking, then migration deployment to dev with full verification, then production. Each phase gates the next.

---

## Confirmed Decisions

| Decision | Value |
|---|---|
| Region | North Virginia (`us-east-1`) — pilot players are primarily East Coast |
| Environment strategy | Two separate Supabase projects: `forkensics-dev` and `forkensics-prod` |
| Object storage | Supabase Storage, one private bucket (`game-media`) per project |

---

## Migration Failure Stop Rule

If `db push`, the hosted acceptance suite, or any verification step fails:

**Stop immediately.** Do not:
- Modify the frozen V1 file (`08_Migration/V1__initial_schema.sql`)
- Repair migration history manually
- Apply fixes through the Supabase Dashboard or SQL Editor

Manual remote changes bypass `supabase_migrations.schema_migrations` and can cause future `db push` operations to diverge. Return all evidence for three-party review before taking any corrective action.

---

## Phase A — Source Control

The WhatAndWhere folder is not currently a Git repository. Source control must exist before anything else.

### A1 — Confirm the remote repository is private

Create a new repository on GitHub (or equivalent). **Confirm it is set to Private before proceeding.** Do not use a repository that was used for any prior app.

### A2 — Initialize Git and add remote

```bash
cd ~/Desktop/WhatAndWhere
git init
git remote add origin <private-repo-url>
```

### A3 — Create `.gitignore`

Create `~/Desktop/WhatAndWhere/.gitignore`:

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

### A4 — Initialize Supabase config

```bash
supabase init
```

This creates `supabase/config.toml` with local Supabase configuration. This file does **not** store the linked cloud project ref — linking state lives under the gitignored `supabase/.temp/`. Switching between dev and production does not produce a Git commit.

### A5 — Create the Supabase migrations directory and deployment copy

```bash
mkdir -p supabase/migrations
mkdir -p supabase/verification

cp 08_Migration/V1__initial_schema.sql \
   supabase/migrations/20260807000000_v1_initial_schema.sql

cp supabase/verification/prod_schema_verify.sql \
   supabase/verification/prod_schema_verify.sql   # already in place if cloned
```

The timestamp prefix (`20260807000000`) establishes migration ordering. The original frozen file is never modified.

Verify the deployment copy matches the frozen artifact (macOS):

```bash
shasum -a 256 08_Migration/V1__initial_schema.sql \
              supabase/migrations/20260807000000_v1_initial_schema.sql
# Both lines must show: 2581412af146acdaaf9a7139c98a208fa4b1fe1a355ee14e043f9117b6f3afc3
```

### A6 — Inspect, scan, and commit

Before the first push, inspect every file that will be committed and confirm no credentials are present:

```bash
git status          # review full file list
git diff --cached   # nothing staged yet — this is a pre-check
grep -r "password\|secret\|key\|token" supabase/ --include="*.toml" --include="*.sql" -l
# Expected: no output (or only references in comments/docs, not values)
```

If the scan finds anything unexpected, resolve it before continuing.

```bash
git add .
git commit -m "V1 database baseline — frozen 2026-08-07

Migration SHA-256: 2581412af146acdaaf9a7139c98a208fa4b1fe1a355ee14e043f9117b6f3afc3
Tests SHA-256:     5d1e2e25ccfb232be985c2e08acfeda0966bedf9fee3c8921f58eda7aa8046c3
Approved by Bill and GPT/Codex 2026-08-07"

git branch -M main
git tag v1-database-baseline
git push -u origin main --tags
```

The `v1-database-baseline` tag now captures the deployable migration copy, the verification SQL, and all governance documents.

---

## Phase B — Project Creation

Log in to [supabase.com](https://supabase.com) as the Forkensics account owner (Bill). **Do not reuse any project, org, or credential from a prior app.**

Create a new **Forkensics** organization if one does not exist. Do not use a personal org.

### B1 — Create `forkensics-dev`

- Organization: Forkensics
- Project name: `forkensics-dev`
- Region: **North Virginia (us-east-1)**
- Database password: strong random password — save to 1Password immediately

### B2 — Create `forkensics-prod`

- Organization: Forkensics
- Project name: `forkensics-prod`
- Region: **North Virginia (us-east-1)**
- Database password: different strong random password — save to 1Password

---

## Phase C — Credentials

For each project: Dashboard → Project Settings → API.

Use Supabase's current key model:

| Key | Where | Used by |
|---|---|---|
| Publishable key | API Settings | iOS client (safe to expose in app bundle) |
| Secret key | API Settings | Trusted backend only — hosted Edge Functions receive `SUPABASE_SECRET_KEYS` automatically |
| Project JWKS | auto-provided | JWT verification in hosted Edge Functions via `SUPABASE_JWKS` |

Hosted Edge Functions automatically receive `SUPABASE_PUBLISHABLE_KEYS`, `SUPABASE_SECRET_KEYS`, and `SUPABASE_JWKS` as environment variables (JSON dictionaries). No secret needs to be manually injected during Step 23.

**Storage rules:**
- All keys and both database passwords stored in 1Password
- Secret key never in client code, never in the repo, never sent to Claude
- Do not copy or store the legacy JWT secret — it is not needed; hosted functions receive `SUPABASE_JWKS` automatically

Also note the **project URL** for each project (Dashboard → Project Settings → API → Project URL). The iOS client uses the project URL and publishable key.

---

## Phase D — CLI Linking

Only one project is actively linked at a time. Explicitly relink and verify before every cloud operation.

```bash
# Link to dev
supabase link --project-ref <dev-project-ref>

# Verify — confirm the expected ref appears in the list
supabase projects list
```

Linking does not produce a Git commit. `supabase/config.toml` is already committed (Phase A). The link state is stored in `supabase/.temp/` which is gitignored.

Store connection strings securely. Use the **Session Pooler** connection string (Dashboard → Project Settings → Database → Connection string → Session mode) for psql operations. Load it from a gitignored `.env.dev` file — do not paste database passwords directly into shell commands:

```bash
# .env.dev (gitignored — never commit)
DEV_DB_URL=postgresql://postgres.<project-ref>:<password>@aws-0-us-east-1.pooler.supabase.com:5432/postgres

# Load before any psql operation
source .env.dev
```

---

## Phase E — Storage Bucket Creation

Create the private storage bucket through the Supabase Dashboard (Storage → New bucket) for each project. Do not modify the `storage` schema directly.

**For both `forkensics-dev` and `forkensics-prod`:**

| Setting | Value |
|---|---|
| Bucket name | `game-media` |
| Public | Off |
| File size limit | 10 MB |
| Allowed MIME types | `image/jpeg`, `image/webp` |

After creation, verify and record bucket ID and settings from the dashboard. The bucket remains empty; no storage policies are configured until the media Edge Function step.

---

## Phase F — Apply V1 Migration to Dev

**Gate: Bill types `APPROVED: Apply frozen V1 to forkensics-dev`.**

```bash
# Confirm linked to dev
supabase projects list   # visually confirm dev project ref

# Dry run — shows what would be applied, makes no changes
supabase db push --dry-run

# Apply
supabase db push

# Confirm migration is recorded
supabase migration list
# Expected: one entry — 20260807000000_v1_initial_schema
```

If any step fails, apply the Migration Failure Stop Rule above.

---

## Phase G — Verify Dev Deployment

**Step 1 — Verify the test file hash before running:**

```bash
shasum -a 256 08_Migration/tests/V1_acceptance_tests.sql
# Expected: 5d1e2e25ccfb232be985c2e08acfeda0966bedf9fee3c8921f58eda7aa8046c3
```

**Step 2 — Run the acceptance test suite against dev:**

The SQL test file wraps all tests in `BEGIN … ROLLBACK`. It is transactional and non-destructive — it does not reset or modify the database. Do **not** run `run_tests_full.sh`; that wrapper calls `supabase db reset` which is destructive and must never be run against a cloud project.

```bash
source .env.dev
psql "$DEV_DB_URL" \
  --set ON_ERROR_STOP=on \
  -f 08_Migration/tests/V1_acceptance_tests.sql
```

Expected: 240 assertions, all passing, exit code 0.

**Step 3 — Run the production verification script:**

```bash
psql "$DEV_DB_URL" \
  --set ON_ERROR_STOP=on \
  -f supabase/verification/prod_schema_verify.sql
```

This script checks (read-only, non-destructive):
- Migration history entry in `supabase_migrations.schema_migrations`
- All expected tables and views
- Key function names and ownership
- Triggers on covered tables
- RLS enabled on all required tables
- RLS policies present on key tables
- Required grants to `authenticated`
- `forkensics_executor` and `forkensics_rls_helper` are NOLOGIN BYPASSRLS
- `rules_versions` seed row: exact `id`, `version_tag = 'v1'`, and key config fields

Expected: all checks pass, exit code 0.

---

## Phase H — Apply V1 Migration to Prod

**Gate: Phase G passes cleanly (all assertions pass, exit 0). Bill types `APPROVED: Apply frozen V1 to forkensics-prod`.**

```bash
# Relink to prod — always verify before a production operation
supabase link --project-ref <prod-project-ref>
supabase projects list   # confirm prod ref is active

# Load prod connection string
source .env.prod   # separate gitignored file for prod credentials

# Dry run
supabase db push --dry-run

# Apply
supabase db push

# Confirm
supabase migration list
# Expected: one entry — 20260807000000_v1_initial_schema
```

**Prod verification — verification script only, no acceptance suite:**

```bash
shasum -a 256 supabase/verification/prod_schema_verify.sql
# Verify hash matches committed file before running

psql "$PROD_DB_URL" \
  --set ON_ERROR_STOP=on \
  -f supabase/verification/prod_schema_verify.sql
```

Expected: all checks pass, exit code 0.

The full acceptance test suite is never run against the production project.

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

- [ ] Private Git repository confirmed private before first push
- [ ] `.gitignore` in place; `supabase/.temp/` and credentials excluded
- [ ] `supabase init` run; `supabase/config.toml` present
- [ ] `supabase/migrations/20260807000000_v1_initial_schema.sql` created; both SHA-256 hashes match
- [ ] `supabase/verification/prod_schema_verify.sql` committed
- [ ] Credential scan clean before first push
- [ ] V1 baseline committed, `git branch -M main`, tagged `v1-database-baseline`, pushed
- [ ] `forkensics-dev` created in `us-east-1` under Forkensics org
- [ ] `forkensics-prod` created in `us-east-1` under Forkensics org; separate database password
- [ ] All credentials (passwords, publishable key, secret key, project URLs) in 1Password; none in repo
- [ ] `game-media` bucket (private, 10 MB limit) created in both projects
- [ ] CLI linked to dev; linking state confirmed with `supabase projects list`
- [ ] `.env.dev` created locally (gitignored); Session Pooler URL used for all dev psql
- [ ] `APPROVED: Apply frozen V1 to forkensics-dev` received
- [ ] `supabase db push` applied to dev; `supabase migration list` confirms V1 recorded
- [ ] Acceptance test suite passes against dev (240 assertions, exit 0)
- [ ] `prod_schema_verify.sql` passes against dev (all checks, exit 0)
- [ ] `APPROVED: Apply frozen V1 to forkensics-prod` received
- [ ] CLI relinked to prod; confirmed with `supabase projects list`
- [ ] `.env.prod` created locally (gitignored); Session Pooler URL used for all prod psql
- [ ] `supabase db push` applied to prod; `supabase migration list` confirms V1 recorded
- [ ] `prod_schema_verify.sql` passes against prod (all checks, exit 0)

---

## What Comes After Step 23

Per the approved sequence:

- **Next:** Local SwiftUI prototype (core screens with fake data, no backend)
- **Then:** Edge Function contracts defined and approved
- **Then:** Edge Function implementation, one function at a time
