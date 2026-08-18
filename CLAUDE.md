# Forkensics — Claude Code Handoff

## Work order

1. Finish the backend work described below.
2. Only after the backend is complete, return to the SwiftUI prototype using `@Forkensics/IOS_HANDOFF.md` and `@Forkensics/GUIDE_AUDIT.md`.

Preserve the existing dirty worktree. Do not reset, discard, or broadly rewrite existing changes. Never request, display, store, or commit Supabase, Cloudflare, R2, APNs, or Apple credentials. Do not perform a cloud operation unless its governing document explicitly records the required approval.

## Backend documents to read

Read in this order:

1. `@README.md` — governance and repository map.
2. `@07_Steps/Step-A-Amendment-D.md` — current active backend proposal: R2 presigning. Rev 7 is awaiting three-party approval; Step A Rev 9 is the frozen implemented baseline.
3. `@07_Steps/Step-A-Proposal-Rev9.md` — frozen `upload-authorize` baseline.
4. `@07_Steps/CF-Worker-Prod-Proposal-Rev3.md` — image-transform Worker contract and forkensics-dev execution evidence.
5. `@07_Steps/Step-27-Proposal-Rev5.md` — approved Edge Function implementation sequence.
6. `@05_Architecture/Architecture.md` — system boundaries and security architecture.
7. `@08_Security-and-Privacy/Privacy-Model.md` — privacy and credential constraints.

Do not use superseded proposal revisions when a latest revision is identified above.

## Backend implementation locations

- `supabase/functions/upload-authorize/` — current Edge Function and unit/integration tests.
- `supabase/functions/_shared/` — shared authentication, errors, logging, profile, crypto, and S3 helpers.
- `supabase/functions/.env.example` — variable names only; no real secrets belong in the repository.
- `tools/image-transform/` — Cloudflare image-transform Worker, fixtures, configuration, and package files.
- `supabase/migrations/` — frozen V1–V4 database migrations. Never edit an already-applied migration.
- `08_Migration/tests/` — database acceptance, regression, and concurrency tests.
- `supabase/config.toml` — local Supabase configuration.
- `tools/` — backend verification and integration harnesses.

Current database baseline is commit/tag `a7a2c54` / `v0.4.0-case-investigation-schema`; V1–V4 are applied and passing. Start by reviewing the current git diff and the approval/status section of `Step-A-Amendment-D.md`. Do not implement Amendment D while it remains unapproved.

## Swift locations for the later phase

- `Forkensics/Forkensics.xcodeproj`
- `Forkensics/Forkensics/`
- `Forkensics/Forkensics/Wireframes/`
- `Forkensics/IOS_HANDOFF.md`
- `Forkensics/GUIDE_AUDIT.md`

The Swift stopping point is Create Table → in-app detective picker → Review Table. Do not restart completed screens from scratch.
