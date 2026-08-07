# Step 23 Proposal — Forkensics Supabase Cloud Foundation

**Status:** Pending review (Claude → Codex/GPT → Bill approval)
**Governance gate:** Bill must type `APPROVED: Step 23 — Supabase Cloud Foundation` before any cloud resource is created.

**Scope boundary — what this step is NOT:**
- No Edge Function code
- No application code
- No production traffic
- No destructive tests against any cloud database
- No migration applied until explicitly approved within this step

---

## Overview

This step establishes the permanent Supabase cloud infrastructure for Forkensics: two projects (development and production), a linked CLI, correctly scoped credentials, and the V1 migration applied to the development project only. Production receives the migration only after successful development verification.

---

## Decision 1 — Region

**Confirmed: `us-east-1` (US East — N. Virginia)**

Both projects (dev and prod) use the same region. For a family-scale app, region choice has no meaningful gameplay impact — latency differences between US regions are imperceptible and no data-residency requirements apply.

---

## Decision 2 — Environment Strategy

**Recommendation: Two separate Supabase projects**

| Project | Purpose |
|---|---|
| `forkensics-dev` | Development, integration testing, schema iteration |
| `forkensics-prod` | Production — pilot family group |

Why not Supabase branching:
- Supabase branching (database branches per git branch) is designed for teams doing frequent schema iteration. V1 is frozen. Branching adds complexity without benefit for a solo-owner app at this stage.
- Two projects keeps dev/prod isolation explicit and operationally simple.

Both projects:
- Same region
- Same Supabase plan (Free initially; upgrade to Pro before first real pilot user)
- Same V1 migration applied — dev first, prod after dev verification

---

## Decision 3 — Storage

Confirmed: **Supabase Storage, one private bucket per project.**

- Bucket name: `game-media`
- Access: private (no public URLs)
- Authenticated delivery: Edge Function proxy (Step N — not this step)
- Object keys: opaque server-generated UUIDs (matching `media_objects.id` pattern in V1 schema)
- No public bucket, no presigned URLs exposed to clients

Storage bucket is created in this step but remains empty until the media Edge Function is implemented.

---

## Step 23 Implementation Checklist

All actions performed by Bill (Claude provides exact commands to run; Claude does not hold credentials).

### Phase A — Project Creation

1. Log in to [supabase.com](https://supabase.com) as the Forkensics account owner (Bill).
2. Create `forkensics-dev`:
   - Organization: Forkensics (create new org if needed — do not use a personal org)
   - Project name: `forkensics-dev`
   - Region: confirmed region from Decision 1
   - Database password: strong random password — save to 1Password / secure vault immediately
3. Create `forkensics-prod`:
   - Same org, same region
   - Project name: `forkensics-prod`
   - Database password: different strong random password — save to vault

**Do not reuse any project, org, or credential from prior apps.**

### Phase B — CLI Linking

Supabase CLI is already installed (used for local dev). Link each project:

```bash
# Link dev
supabase link --project-ref <dev-project-ref>

# Link prod (switch when needed)
supabase link --project-ref <prod-project-ref>
```

Project ref is visible in the Supabase dashboard URL: `https://supabase.com/dashboard/project/<ref>`.

The CLI stores the linked ref in `.supabase/config.toml`. This file is committed to the repo — it contains only the project ref, not credentials.

**Never commit service role keys, JWT secrets, or database passwords.**

### Phase C — Credentials and Secrets

For each project, note and store securely (1Password or equivalent):

| Secret | Where to find it | Who uses it |
|---|---|---|
| Database password | Set at creation | Direct psql access, migrations |
| `anon` key | Project → API Settings | iOS client (safe to expose) |
| `service_role` key | Project → API Settings | Edge Functions only — never in client |
| JWT secret | Project → API Settings | Signing/verifying tokens |

**Access ownership rule:** Bill holds all production credentials. Claude never receives production service role keys or database passwords. Claude receives only the `anon` key (already public by design) when needed for reference.

### Phase D — Storage Bucket Creation

In each project (Supabase dashboard → Storage → New bucket):

- Name: `game-media`
- Public: **off**
- File size limit: 10 MB (sufficient for re-encoded game-copy images; revisit at media step)
- Allowed MIME types: `image/jpeg`, `image/webp` (re-encoded formats only)

No storage policies configured in this step — that is the media Edge Function's responsibility.

### Phase E — Apply V1 Migration to Dev

**Gate: only after Phases A–D are complete and Bill confirms ready.**

```bash
# Confirm you are linked to dev
supabase status

# Apply migration
psql "$DEV_DB_URL" --set ON_ERROR_STOP=on \
  -f 08_Migration/V1__initial_schema.sql
```

Where `DEV_DB_URL` is the dev project's connection string (Session Pooler recommended; available in Project → Settings → Database → Connection string).

After applying, verify the migration hash matches the frozen artifact:

```bash
sha256sum 08_Migration/V1__initial_schema.sql
# Expected: 2581412af146acdaaf9a7139c98a208fa4b1fe1a355ee14e043f9117b6f3afc3
```

### Phase F — Non-Destructive Schema Verification (Dev Only)

Run a targeted read-only check against the cloud dev project to confirm the schema deployed correctly. This is NOT the full acceptance test suite (which uses `supabase db reset` and is destructive):

```bash
psql "$DEV_DB_URL" --set ON_ERROR_STOP=on -c "
SELECT table_schema, table_name
FROM information_schema.tables
WHERE table_schema IN ('public','private')
ORDER BY table_schema, table_name;
"
```

Expected tables present: all objects listed in `12_Releases/V1_Database_Baseline.md` under "Schema objects."

Also verify the custom roles exist:

```bash
psql "$DEV_DB_URL" -c "
SELECT rolname FROM pg_roles
WHERE rolname IN ('forkensics_executor','forkensics_rls_helper')
ORDER BY rolname;
"
```

Expected: both rows returned.

**No acceptance test suite is run against the cloud database.** The suite uses `supabase db reset` which would wipe the project. Local testing against the local Supabase stack remains the test environment.

### Phase G — Apply V1 Migration to Prod

**Gate: only after Phase F passes cleanly.**

Identical command as Phase E, substituting `$PROD_DB_URL`. Same hash verification.

No acceptance tests against prod. Schema presence check only (Phase F pattern, against prod URL).

---

## Out of Scope for Step 23

The following are explicitly deferred to later steps:

- Edge Function deployment (any function)
- Storage RLS policies and upload authorization
- Auth configuration (Sign in with Apple provider setup)
- Email templates
- Any iOS application code
- Push notification configuration
- Realtime configuration
- Any data seeding beyond the `rules_versions` row included in the V1 migration

---

## Open Architecture Question — Flagged for Resolution Before Edge Function Step

The Deno/WASM image processing library for server-side re-encoding is not yet confirmed. This must be resolved before the media Edge Function step is approved. It does not block Step 23.

---

## Success Criteria for Step 23

- [ ] Two Supabase projects created in `us-east-1` under the Forkensics org
- [ ] Both projects linked to the CLI
- [ ] All credentials stored in vault; none committed to the repo
- [ ] `game-media` storage bucket created (private) in both projects
- [ ] V1 migration applied to dev; hash verified
- [ ] Schema presence check passes on dev (all tables and roles present)
- [ ] V1 migration applied to prod; hash verified
- [ ] Schema presence check passes on prod
- [ ] `.supabase/config.toml` updated and committed (project refs only — no secrets)

---

## What Comes After Step 23

Per the approved sequence:

- **Next:** Local SwiftUI prototype (core screens with fake data, no backend)
- **Then:** Edge Function contracts defined and approved
- **Then:** Edge Function implementation, one function at a time
