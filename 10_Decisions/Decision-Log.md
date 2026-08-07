# Decision Log

## Confirmed — 2026-08-05

- Product is a standalone iPhone app.
- Implementation language/platform direction is Swift for iPhone.
- Reviewers are Bill, Claude, and Codex/GPT.
- Bill is product owner and final decision-maker.
- Claude is the sole application-code author.
- Codex plans and independently reviews; Codex does not write application code.
- Each coding step requires agreement and Bill's explicit approval before implementation.
- Working project and planning-folder name is `WhatAndWhere`.
- Working app name is **Forkensics**. (See 2026-08-05 update below.)
- Project is currently in discovery and planning; no coding step is approved.

## Confirmed — 2026-08-05 (Architecture Corrections from GPT Reconciliation)

### Identity and user key
- Application primary key: Supabase `auth.users.id` (UUID) via `auth.uid()`. Used in all application tables and RLS policies.
- Apple `sub` identifier: stored as `provider_id` on the Apple identity record. Not used as a primary key anywhere in the application.
- Email: optional profile information only. Never a primary key.

### ChallengeSecret — separate protected table
- Canonical dish name, accepted aliases, canonical restaurant, canonical city are stored in a separate `ChallengeSecret` table, not in the `Challenge` row.
- RLS denies pre-reveal access to everyone except the poster and trusted server functions (service role key).
- After reveal, answers returned through authorized server operation only.

### GuessAttempt — immutable append-only
- Every submission or edit produces a new immutable `GuessAttempt` record.
- Fields include: server receipt timestamp and server-generated monotonic receipt sequence.
- First-correct rank for each race is determined independently from GuessAttempt records.

### EligibleParticipant — immutable with ExclusionEvent
- Posting-time roster is immutable.
- Removals and withdrawals produce a separate ExclusionEvent record.
- Effective eligibility = posting-time roster minus exclusion events.

### Challenge state graph
- Valid: `draft→active`, `draft→cancelled`, `active→locked`, `active→cancelled`, `locked→revealed`, `locked→cancelled`.
- `revealed` and `cancelled` are terminal.
- `locked` is server-controlled. Invalid transitions rejected at database level.

### Tie-breaking
- Server receipt timestamp is authoritative for rank.
- If timestamps are identical, server-generated monotonic receipt sequence breaks the tie.
- Client timestamps never determine rank.

### Combined-score tie for Challenge Winner
- Player whose final scoring answer arrived first (by server timestamp) wins.
- If those timestamps match, receipt sequence decides.

### Auto-close timing
- Poster selects 1–48 hours at posting time. Default is 2 hours.
- Group-configurable defaults deferred.

### Account deletion
- Player becomes "Former Player" in historical activity.
- Historical guesses and scores retained without identifying profile information.
- Active challenges where deleted player was guessing: treated as withdrawal.
- Active challenges posted by deleted player: cancelled.
- Sole admin deletion: administration transfers to longest-tenured active member. If none, group archived.

### Post-reveal score correction
- Poster or group admin may submit a correction with a mandatory reason.
- Original GuessAttempt and ScoreEvent records remain immutable.
- Scores recalculated using the recorded RulesVersion.
- A visible CorrectionEvent appears in challenge activity.
- Affected players notified. Leaderboards updated.
- Scores are never silently overwritten.

## Confirmed — 2026-08-05 (Name)

- Working app name is **Forkensics**.
- The folder name `WhatAndWhere` is retained as the project/folder identifier.
- The name is working only; final App Store name requires Bill's approval before submission.

## Confirmed — 2026-08-05 (Gameplay Review)

### Backend
- Supabase is the confirmed preferred backend.
- Responsibilities: Supabase Auth, PostgreSQL, row-level security, private storage, Edge Functions, Realtime (deferred until justified).
- Formal implementation approval still requires Bill's explicit APPROVED step declaration.

### Platform
- Minimum deployment target: iOS 18.
- Build target: current iOS 26 SDK.
- Primary design and testing: iOS 26.
- Claude will flag any iOS 26-specific API used without an iOS 18 fallback at implementation time.

### Authentication
- Sign in with Apple is the confirmed authentication method.
- Invite by expiring shareable link. No contact-list upload required.
- No email magic-link fallback unless a demonstrated need appears.
- CRITICAL: Apple returns the user's name and email only on the first sign-in. The app must capture and persist the player's display name during the first sign-in flow. If missed, it cannot be retrieved from Apple again. The Apple user identifier (sub claim) must be the primary identity key in the database, not the email address.

### Scoring
- What? and Where? are separate scoring races.
- Only fully correct answers score points. No partial credit.
- Points = eligible guessers − correct-answer rank + 1. Minimum 1 point for any correct answer.
- Ranking is determined by server-recorded timestamp at submission receipt. Client timestamps are not used.
- Editing an incorrect answer does not preserve the earlier timestamp. The timestamp that matters is when the first fully-correct answer is submitted.
- Ties: both players receive the higher rank; next rank skips the occupied position.
- A Challenge Winner is determined by highest combined score across both races.
- Poster does not score on their own challenge.

### Round Lifecycle
- No partial credit for either What? or Where?.
- Round closes on deadline. Poster selects 1–48 hours at posting time. Default is 2 hours.
- Round also auto-reveals when every eligible player has submitted.
- Poster may manually reveal after at least two eligible players have submitted.
- Poster may post group-wide hints while the round is open. Hints carry no point penalty.
- If the round has not closed after 7 days, the app privately reminds the poster (hint, reveal, cancel, or leave open).
- A second reminder at 14 days; a third at 30 days with group admin also notified.
- No auto-close beyond the poster-selected deadline.
- Cancelled rounds award no points. A Cancelled state is shown in round history.

### Canonical Answer and Correction Window
- The poster may change the canonical dish and location after posting, until the first guess is received.
- Once the first guess is received, the canonical answer is locked.
- After lock, the poster may proceed with the existing answer or withdraw the round completely.
- Withdrawing after the first guess awards no points to any player.

### Participant Snapshot
- Active group members at challenge posting become the eligible set for that round. Immutable after posting.
- The poster is excluded from the eligible set.
- Members joining after posting are not eligible for that round.
- Both voluntary withdrawal and admin removal apply the same rule: excluded from ranking and scoring, no longer blocks auto-reveal, submission preserved in audit log only.

### Media
- Client-side EXIF/GPS stripping required before upload.
- Server-side re-encoding required as defense in depth. Stored game copy is the server-re-encoded version.
- Private media delivery via authenticated Edge Function proxy. Client never sees raw storage paths or signed URLs.
- Storage bucket is private. No public access.

### Groups and Identity
- One account may belong to multiple groups.
- Group creator becomes the first administrator.
- Administrators may invite, remove, and promote members.
- Pilot: adults only. Child account design deferred.
- Multiple simultaneous active challenges allowed, one per poster at a time.
- A poster must reveal, cancel, or archive their current challenge before posting another.

### Standings
- All-time standings required. Weekly standings as secondary view.

### Post-Reveal
- Reactions and comments required in MVP.
- Revealed restaurant links to Apple Maps.
- Poster's optional story appears only after reveal.

### Prototype
- Candidate Step 1 is a local fake-data SwiftUI prototype — no backend, no auth, no real photos.
- Mock data must include edge cases: simultaneous challenges, revealed and unrevealed rounds, tied timestamps, a hint mid-round, a cancelled challenge.
- SwiftUI views built in Step 1 should be written for reuse. Only the data layer is replaced in subsequent steps.
- Not yet approved. Codex to prepare the formal step proposal.

## Confirmed — 2026-08-07 (App Store Pricing and Family Sharing)

- App Store price: **$2.99** (paid download, no free tier).
- Family Sharing: **on**. Broader adoption matters more than per-seat revenue. One household purchase covering a family is an acceptable trade-off at $2.99.

## Confirmed — 2026-08-07 (Step 23 — Supabase Cloud Foundation Approved)

- Step 23 proposal (Rev 5) approved by Claude, GPT/Codex, and Bill on 2026-08-07.
- Approval phrase: `APPROVED: Step 23 — Supabase Cloud Foundation`
- No cloud resources may be created until Bill also provides:
  - `APPROVED: Apply frozen V1 to forkensics-dev` (before Phase F)
  - `APPROVED: Apply frozen V1 to forkensics-prod` (before Phase H)
- Full proposal in `07_Steps/Step-23-Proposal-Rev5.md`

## Confirmed — 2026-08-07 (V1 Database Baseline Freeze)

- `V1__initial_schema.sql` is frozen. The file is read-only historical record.
- All future database changes must be delivered as `V2__*.sql` (or higher) migrations.
- City (`public_city_display`) is optional poster-supplied context: stored on `challenges`, normalized (trim, whitespace → NULL) on both INSERT and draft UPDATE, immutable after activation, and never scored. Restaurant alone determines `where_correct`.
- `get_storage_keys_for_deletion` uses `UNION` (not `UNION ALL`) to return one distinct row per physical storage key, including `re_encoded_storage_key`.
- Approved by Bill and GPT/Codex on 2026-08-07. Full record in `12_Releases/V1_Database_Baseline.md`.
- Migration SHA-256: `2581412af146acdaaf9a7139c98a208fa4b1fe1a355ee14e043f9117b6f3afc3`
- Tests SHA-256: `5d1e2e25ccfb232be985c2e08acfeda0966bedf9fee3c8921f58eda7aa8046c3`

