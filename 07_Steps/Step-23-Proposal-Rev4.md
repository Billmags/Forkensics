# Step 23 Proposal — Rev 4 — Forkensics Supabase Cloud Foundation

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

This step establishes the permanent Supabase cloud infrastructure for Forkensics in the correct order: source control first (with the verifier validated locally before tagging), then cloud projects, then credentials, then migration deployment to dev with full verification, then production.

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

Create a new repository on GitHub. **Confirm it is set to Private before the first push.** Do not use a repository that was used for any prior app.

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

### A4 — Initialize Supabase config (only if not already present)

```bash
test -f supabase/config.toml || supabase init
```

`supabase/config.toml` contains local Supabase configuration — not the cloud project ref. Linking state lives under `supabase/.temp/` which is gitignored. Switching between dev and production does not produce a Git commit.

### A5 — Create the Supabase migrations directory and deployment copy

```bash
mkdir -p supabase/migrations
cp 08_Migration/V1__initial_schema.sql \
   supabase/migrations/20260807000000_v1_initial_schema.sql
```

The timestamp prefix establishes migration ordering. The original frozen file is never modified. The verification file `supabase/verification/prod_schema_verify.sql` is already in place.

Verify the deployment copy matches the frozen artifact (macOS):

```bash
shasum -a 256 08_Migration/V1__initial_schema.sql \
              supabase/migrations/20260807000000_v1_initial_schema.sql
# Both lines must show: 2581412af146acdaaf9a7139c98a208fa4b1fe1a355ee14e043f9117b6f3afc3
```

### A6 — Validate the verification script against the local V1 database

Before tagging, confirm `prod_schema_verify.sql` passes against the running local Supabase instance:

```bash
shasum -a 256 supabase/verification/prod_schema_verify.sql
# Record this hash — it becomes part of the release documentation

psql postgresql://postgres:postgres@127.0.0.1:54322/postgres \
  --set ON_ERROR_STOP=on \
  -f supabase/verification/prod_schema_verify.sql
# Expected: all checks pass, exit code 0
```

If any check fails, the verification script must be corrected before proceeding. Do not tag until exit code is 0.

### A7 — Credential scan, inspect, stage, and commit

Stage all files first, then scan staged content for actual secret patterns:

```bash
git add .
```

Run the credential scan against staged content:

```bash
# Supabase secret keys (sb_secret_...)
git diff --cached | grep -E "\+.*sb_secret_[A-Za-z0-9]+"

# Supabase personal access tokens (sbp_...)
git diff --cached | grep -E "\+.*sbp_[A-Za-z0-9]+"

# JWT-shaped strings — legacy anon/service_role keys (ey...)
git diff --cached | grep -E "\+.*ey[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}"

# Database connection strings with embedded passwords
git diff --cached | grep -E "\+.*://[^/]+:[^@]{6,}@"
```

Expected: no output from any command. If any output appears, unstage and investigate before continuing.

Then inspect the full staged diff:

```bash
git diff --cached --stat
git diff --cached
```

Review the staged diff carefully. Commit only after confirming no credential values are present:

```bash
git commit -m "V1 database baseline — frozen 2026-08-07

Migration SHA-256:    2581412af146acdaaf9a7139c98a208fa4b1fe1a355ee14e043f9117b6f3afc3
Tests SHA-256:        5d1e2e25ccfb232be985c2e08acfeda0966bedf9fee3c8921f58eda7aa8046c3
Verifier SHA-256:     260e8b086563623915163c4b10cf3d225bad1a7f5172b4b4c39a1dc70c31328e
Approved by Bill and GPT/Codex 2026-08-07"

git branch -M main
git tag v1-database-baseline
git push -u origin main --tags
```

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

**Region note:** Supabase projects cannot be migrated to a different region after creation — a new project and data migration would be required. North Virginia is chosen because the pilot group is primarily East Coast.

---

## Phase C — Credentials

For each project: Dashboard → Project Settings → API.

Use Supabase's current key model:

| Key | Where | Used by |
|---|---|---|
| Project URL | API Settings | iOS client configuration |
| Publishable key | API Settings | iOS client (safe to expose in app bundle) |
| Secret key | API Settings | Trusted backend only |

Hosted Edge Functions automatically receive `SUPABASE_PUBLISHABLE_KEYS`, `SUPABASE_SECRET_KEYS`, and `SUPABASE_JWKS` as environment variables (JSON dictionaries). No secrets need to be manually injected during Step 23.

**Storage rules:**
- All keys and both database passwords stored in 1Password
- Secret key never in client code, never in the repo, never sent to Claude
- Do not copy or store the legacy JWT secret — hosted functions receive `SUPABASE_JWKS` automatically

---

## Phase D — CLI Linking

Only one project is actively linked at a time. Explicitly relink and verify before every cloud operation.

```bash
# Link to dev
supabase link --project-ref <dev-project-ref>

# Verify — confirm the expected ref appears
supabase projects list
```

Linking does not produce a Git commit.

**Database connection:** Use separate PostgreSQL environment variables to avoid shell and URL-encoding issues with strong passwords. Obtain the **Session Pooler** connection parameters from Dashboard → Project Settings → Database → Connection string → Session mode.

Create a gitignored `.env.dev` file with connection parameters only — no password:

```bash
# .env.dev  (gitignored — never commit)
export PGHOST=aws-0-us-east-1.pooler.supabase.com
export PGPORT=5432
export PGDATABASE=postgres
export PGUSER=postgres.<dev-project-ref>
# PGPASSWORD is NOT stored here — obtained at runtime
```

Before each psql session, obtain the password securely and unset it afterward:

```bash
# Option A — silent terminal prompt (no password in shell history)
source .env.dev
read -rs -p "Dev DB password: " PGPASSWORD && export PGPASSWORD
psql --set ON_ERROR_STOP=on -f <file>
unset PGPASSWORD

# Option B — 1Password CLI (if op CLI is installed)
source .env.dev
export PGPASSWORD=$(op read "op://Forkensics/forkensics-dev-db/password")
psql --set ON_ERROR_STOP=on -f <file>
unset PGPASSWORD
```

Create a separate `.env.prod` for production (same structure, no password). Neither file is ever committed.

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

After creation, record the bucket ID and confirm Public = false in the dashboard. The bucket remains empty; no storage policies are configured until the media Edge Function step.

---

## Phase F — Apply V1 Migration to Dev

**Gate: Bill types `APPROVED: Apply frozen V1 to forkensics-dev`.**

```bash
source .env.dev

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

If any step fails, apply the Migration Failure Stop Rule.

---

## Phase G — Verify Dev Deployment

**Step 1 — Verify the test and verifier file hashes before running:**

```bash
shasum -a 256 08_Migration/tests/V1_acceptance_tests.sql
# Expected: 5d1e2e25ccfb232be985c2e08acfeda0966bedf9fee3c8921f58eda7aa8046c3

shasum -a 256 supabase/verification/prod_schema_verify.sql
# Expected: 260e8b086563623915163c4b10cf3d225bad1a7f5172b4b4c39a1dc70c31328e
```

**Step 2 — Run the acceptance test suite against dev:**

The SQL test file is transactional — it runs inside `BEGIN … ROLLBACK` and makes no permanent changes. Do **not** run `run_tests_full.sh`; that wrapper calls `supabase db reset` which is destructive.

```bash
source .env.dev
psql --set ON_ERROR_STOP=on \
  -f 08_Migration/tests/V1_acceptance_tests.sql
```

Expected: 240 assertions, all passing, exit code 0.

**Step 3 — Run the schema verification script:**

```bash
psql --set ON_ERROR_STOP=on \
  -f supabase/verification/prod_schema_verify.sql
```

This checks (read-only, non-destructive):
- Migration history entry in `supabase_migrations.schema_migrations`
- All 19 public tables and 3 private tables
- View `current_score_events`
- 18 public-table triggers plus `on_auth_user_created` on `auth.users`
- RLS enabled on all 19 public tables; policies present on all key tables
- 26 expected functions present; `forkensics_executor` ownership confirmed
- `authenticated` grants: SELECT on profiles, INSERT on guess_attempts, USAGE on private schema
- `forkensics_executor` and `forkensics_rls_helper` are NOLOGIN BYPASSRLS
- `rules_versions` seed row: exact `id`, `version_tag = 'v1'`, and key config fields

Expected: all checks pass, exit code 0.

---

## Phase H — Apply V1 Migration to Prod

**Gate: Phase G passes cleanly. Bill types `APPROVED: Apply frozen V1 to forkensics-prod`.**

```bash
# Relink to prod — always verify before a production operation
supabase link --project-ref <prod-project-ref>
supabase projects list   # confirm prod ref is active

source .env.prod

# Dry run
supabase db push --dry-run

# Apply
supabase db push

# Confirm
supabase migration list
# Expected: one entry — 20260807000000_v1_initial_schema
```

**Prod verification — schema verification script only, no acceptance suite:**

```bash
shasum -a 256 supabase/verification/prod_schema_verify.sql
# Confirm hash matches committed value

psql --set ON_ERROR_STOP=on \
  -f supabase/verification/prod_schema_verify.sql
```

Expected: all checks pass, exit code 0. The full acceptance test suite is never run against the production project.

---

## Out of Scope for Step 23

- Edge Function deployment (any function)
- Storage RLS policies and upload authorization
- Auth configuration (Sign in with Apple provider setup)
- Any iOS application code
- Push notification configuration
- Realtime configuration
- Any data seeding beyond the `rules_versions` row in the V1 migration

---

## Success Criteria for Step 23

- [ ] Private GitHub repository confirmed private before first push
- [ ] `.gitignore` in place; `supabase/.temp/` and credentials excluded
- [ ] `supabase/config.toml` present (created by `supabase init` if needed)
- [ ] `supabase/migrations/20260807000000_v1_initial_schema.sql` created; both `shasum` outputs match
- [ ] `supabase/verification/prod_schema_verify.sql` passes locally against clean V1 (exit 0); hash recorded
- [ ] Credential scan clean (both grep patterns return no output)
- [ ] Staged diff reviewed; no credential values present
- [ ] V1 baseline committed; `git branch -M main`; tagged `v1-database-baseline`; pushed with tags
- [ ] `forkensics-dev` created in `us-east-1` under Forkensics org
- [ ] `forkensics-prod` created in `us-east-1` under Forkensics org; separate database password
- [ ] All credentials (passwords, publishable key, secret key, project URLs) in 1Password; none in repo
- [ ] `game-media` bucket (private, 10 MB limit) created in both projects; bucket ID recorded
- [ ] CLI linked to dev; confirmed with `supabase projects list`
- [ ] `.env.dev` created locally (gitignored); PGPASSWORD used; Session Pooler params confirmed
- [ ] `APPROVED: Apply frozen V1 to forkensics-dev` received
- [ ] `supabase db push` (with dry-run first) applied to dev; `supabase migration list` confirms entry
- [ ] Acceptance test suite passes against dev (240 assertions, exit 0)
- [ ] Schema verifier passes against dev (all checks, exit 0)
- [ ] `APPROVED: Apply frozen V1 to forkensics-prod` received
- [ ] CLI relinked to prod; confirmed with `supabase projects list`
- [ ] `.env.prod` created locally (gitignored)
- [ ] `supabase db push` (with dry-run first) applied to prod; `supabase migration list` confirms entry
- [ ] Schema verifier passes against prod (all checks, exit 0)

---

## What Comes After Step 23

Per the approved sequence:

- **Next:** Local SwiftUI prototype (core screens with fake data, no backend)
- **Then:** Edge Function contracts defined and approved
- **Then:** Edge Function implementation, one function at a time
