# Decision Log

## Confirmed — 2026-08-15 (Answer Matching)

- Answers are compared through a versioned matcher rather than raw string equality.
- Matching ignores case, diacritics, punctuation, apostrophes, repeated whitespace, and equivalent `&` / `and` / standalone `n` forms.
- Dish matching accepts poster aliases plus curated common equivalents such as Chicken Parmigiana / Chicken Parmesan / Chicken Parm.
- Conservative typo tolerance accepts small spelling errors such as `Chicken Parmagiana` but rejects materially different dishes.
- Restaurant matching uses the same normalization and conservative typo tolerance. City is display context and is not part of the Place score.
- Every activated challenge records its AnswerMatcherVersion so later matcher changes do not silently rescore completed cases.

## Confirmed — 2026-08-15 (Poster Table Participation View)

- From Your Case, the poster can open each recipient table and see its posting-time member roster.
- The poster can see only participation state: Poster, Guess In, or Waiting.
- Guess contents, clue activity, and that case's Table Talk remain hidden from the poster until reveal.

## Confirmed — 2026-08-15 (Clue Privacy and Poster Table Talk)

- A clue is private to the eligible player who reveals it and accepts the 40-point deduction.
- Other detectives cannot see whether that player requested the clue or read its contents.
- The poster cannot view or participate in the challenge's Table Talk while the case is open.
- The poster gains access to that Table Talk only after the case is revealed.

## Confirmed — 2026-08-15 (Scoring and Clue Cost)

- What? and Where?/Place remain independent scoring races.
- For each race, the 1st fully correct eligible player receives 100 points, 2nd receives 80, and 3rd receives 60.
- Fourth and later correct players receive 0 points. Incorrect and missing answers receive 0 points.
- A player can earn at most 200 points on a challenge before clue deductions.
- Each clue revealed by a player deducts 40 points from that player's combined challenge score without changing correct-answer rank.
- This fixed ladder supersedes the earlier eligible-player-count formula and the pending 5–4–3–2–1 proposal.
- The final combined challenge score floors at zero after all clue deductions; it can never be negative.
- Every activated challenge records a RulesVersion. Future point changes apply to newly activated challenges only unless an explicit correction recalculates an older challenge under its recorded version.

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

## Confirmed — 2026-08-07 (Step 24 — Edge Function Architecture and Contracts Approved)

- Step 24 proposal (Rev 10) approved by Claude, GPT/Codex, and Bill on 2026-08-07.
- Approval phrase: `APPROVED: Step 24 — Edge Function Architecture and Contracts`
- Full proposal in `07_Steps/Step-24-Proposal-Rev10.md`
- Reviewed SHA-256: `9e4c552416ac441228e2e8c8ffca38348c354da7fc648a58c6184c1a6612798f` (Codex-reviewed Rev 10)
- No Edge Function code is authorized until a per-function step is approved.
- Step 25 (V2 migration proposal) is now authorized to begin.

**Key decisions recorded in Step 24:**
- `private.upload_sessions` and `private.deletion_recovery_claims` are in the `private` schema; neither is accessible through PostgREST.
- Upload capability issuance uses a two-function handshake: `reserve_upload_session` (locks challenge row `FOR UPDATE`, checks deletion status, inserts with `storage_upload_expires_at = NULL`) and `activate_upload_session` (sets actual URL expiry post-signing; URL only returned to client after this commits).
- `storage_upload_expires_at` is nullable; NULL means no capability was ever issued.
- `get_upload_capability_expiry` excludes NULL-expiry sessions; `claim_cleanup_sessions` does not gate NULL-expiry sessions on URL expiry.
- S3-compatible presigned PUT with 5-minute true expiry replaces Supabase's `createSignedUploadUrl()`. Conditional non-overwrite behavior is not assumed.
- Cleanup worker Part 3 handles post-expiry original-path delete for `complete` sessions.
- All V2 SECURITY DEFINER functions granted EXECUTE only to `service_role`.
- Partial unique index enforces at most one active upload session per challenge at the database level.
- V2 triggers on `public.challenges`: reject activation while active upload session exists; reject activation if `media_object_id` points to non-`ready` media.
- Wording correction (Codex, non-blocking): V1's deletion function directly updates and locks challenge rows; it does not call `cancel_challenge()`. Serialization guarantee is unaffected.

## Confirmed — 2026-08-12 (Step 27 — Edge Function Implementation Plan Approved)

- Step 27 proposal (Rev 5) approved by Claude, Codex, and Bill on 2026-08-12.
- Approval phrase: `APPROVED: Step 27 Rev 5 — Edge Function Implementation Plan`
- Full proposal in `07_Steps/Step-27-Proposal-Rev5.md`
- **This approval authorizes the plan only. No TypeScript or cloud operations until their respective per-function approved steps.**

**Key decisions recorded in Step 27:**

Implementation sequence: `upload-authorize` → `upload-complete` (+ cleanup worker) → `media-serve` → `scheduled-close` → `account-delete-complete` (+ deletion-recovery worker). `moderation-action` deferred as a hard launch gate.

Pre-implementation gates before any TypeScript:
- Gate 1: V2 migration applied and tested.
- Gate 2A: `magick-wasm` local spike — establishes canonical pre-decode pixel limit; verifies WASM bundle size, `static_files` packaging, CLI ≥ 2.7.0.
- Gate 2B: Hosted spike on forkensics-dev — **must be approved and passed before `upload-complete` TypeScript begins** (separate cloud approval required). Phase A passing alone does not authorize implementation.
- Gate 3: pg_cron/pg_net local preflight (fully local; Docker host gateway IP, not localhost).
- Gate 4: S3 connection — S3 Signature V4, `ExpiresIn: 300` only; `createSignedUploadUrl()` prohibited. Local values: `region=local`, `access_key_id=stub`, `secret_access_key=ANON_KEY`. Production: dashboard-generated keys; `.storage.` hostname for large files; `forcePathStyle: true`.
- Gate 5: Deno toolchain smoke (`deno --version`, `gitleaks version`). `deno check/fmt/lint` and `deno.lock` run after each scaffold.

JWT pattern: `createSupabaseContext(req, { auth: 'user' })` from `npm:@supabase/server`. Raw JWT decoding is prohibited. `ctx.userClaims.id` is the verified user ID. Cron functions use `withSupabase({ auth: 'none' })` + manual `X-Forkensics-Cron-Secret` constant-time check.

WASM deployment: `static_files` in `config.toml`; CLI ≥ 2.7.0; Docker/CLI deploy only (no `--use-api`).

Step 24 Rev 10 §5.1 test matrix is mandatory for all functions with V4 identifier substitutions. Per-function §5.x tests are additive.

`finalize_upload_session(session_id, sha256_hash)` — V4 two-arg signature; media created as `pending_review`. After finalization error: re-resolve session; `complete` → 200 idempotent; `sanitized` → map original error (`FK_INVALID_HASH` → 422, `FK_WRONG_STATE` → 409, transport/unknown → 500). Response-lost scenario resolved within same invocation.

`scheduled-close`: two passes (`launched` → `lock_case`; `locked` → `reveal_case_service_wrapper`); every 2 minutes. Concurrent-worker race loser catches state-mismatch error and classifies as `skipped` (not error).

`moderation-action` deferred: `approve_photo`, `reject_photo`, `remove_content`, `remove_media` are service_role-only in V4. Hard gate: no end-to-end gameplay possible without it. Separate proposal step required.

All V4 RPC parameter names in `07_Steps/Step-27-Proposal-Rev5.md` §9.2 are exact and verified against V4 schema.

---

## Confirmed — 2026-08-13 (Pre-Implementation Gate Results — GPT Verdict)

Gate results reviewed by Codex/GPT on 2026-08-13. Verdict: "Gates 3–5 passed; Gate 2A partially passed with remaining evidence required."

- **Gate 5** (Deno + gitleaks): PASSED — Deno 2.9.5, gitleaks 8.30.1
- **Gate 4** (local S3 preflight): PASSED — presigned PUT, HeadObject, delete confirmed
- **Gate 3** (pg_cron/pg_net local): PASSED — cron fired net.http_post to host.docker.internal
- **Gate 1**: satisfied by completed V2/V4 migration and regression evidence
- **Gate 2A** (magick-wasm local spike): PARTIALLY PASSED — 7 items of additional evidence required:
  1. Full 5 MB/10 MB JPEG and 5 MB WebP file-size matrix
  2. Pre-decode header parsing for JPEG and WebP (not only PNG)
  3. Actual decode tests at and around 20 MP boundary (19/20/21 MP)
  4. Measured peak memory at 20 MP boundary (not only theoretical estimate)
  5. Structural proof of EXIF/GPS/ICC/XMP/IPTC/comments removal from re-encoded output
  6. Full bundled function size (not only 14 MB WASM binary)
  7. `static_files` load verified through `supabase functions serve` (Supabase Edge Runtime), not only standalone Deno
- **Gate 2B**: blocked on Gate 2A completion + separate three-party approval
- **Step A (upload-authorize)**: drafting may proceed — independent of image processing
- **Step B (upload-complete)**: remains blocked (Gate 2A incomplete, Gate 2B not started)
- **Cron functions**: remain blocked until a three-party-approved migration adds `CREATE EXTENSION IF NOT EXISTS pg_cron`

Canonical pixel limit (20 MP) is proposed but not yet approved — pending completion of Gate 2A evidence items 3 and 4.

---

## Confirmed — 2026-08-15 (Gate 2B Rev 14 — Pixel Ceiling Discovery Spike Approved)

- Gate 2B Rev 14 proposal approved by Claude, Codex, and Bill on 2026-08-15.
- Approval phrase: `APPROVED: Gate 2B Rev 14 — Pixel Ceiling Discovery Spike`
- Full proposal in `07_Steps/Gate-2B-Proposal-Rev14.md`

**Verification evidence (Codex-confirmed before approval):**
- S-15 fixture corrected: `q_start=72 → 79`; verified output 9,802,741 bytes, all 6 metadata families pass.
- All five survey fixtures satisfy their size bands and metadata requirements.
- Confirmation fixtures pass at every selectable ceiling: 5, 8, 10, 12, and 15 MP.
- Runner passes `bash -n`; all embedded Python scripts compile.
- All Rev 13 telemetry and control-flow findings confirmed resolved.
- No cloud operation was performed during any revision.

**What is now authorized:**
- The Rev 14 runner (`gate2b-run-r14.sh`) may be executed on `hkfrbdpedrxmbsawnbpr` (forkensics-dev) only after the separate §1.2 pre-deployment artifact review and three-party sign-off are complete.
- Deployment remains blocked until §1.2 is satisfied.
- `upload-complete` TypeScript implementation remains blocked until Gate 2B produces a PASS result and `CANONICAL_PIXEL_LIMIT` is established.

**Design decisions recorded in Gate 2B Rev 14:**
- Ascending cold-start survey at 5/8/10/12/15 MP; dual thresholds: memory ≤ 200 MiB AND cpu ≤ 1,500 ms.
- Survey telemetry evidence failures (malformed, inconclusive, unrecognized reason) stop the run immediately and propagate to the parent shell via global `SURVEY_TELEM_OUTCOME` (not command substitution).
- Survey threshold failures (resource-limit or exceeded) mark a level nonviable without poisoning `GATE2B_PASS`; confirmation failures are hard gate failures.
- Ceiling selector requires `shutdown_reason` in positive allowlist `{EventLoopCompleted, EarlyDrop, TerminationRequested}`.
- Operator ceiling constrained to VIABLE_LEVELS ≤ RECOMMENDED_CEILING; any deviation requires new three-party decision.
- RIFF parser requires exact size: `declared_size + 8 == len(data)`.
- iOS client must downscale before upload if `width × height > CANONICAL_PIXEL_LIMIT`.

---

## Confirmed — 2026-08-07 (V1 Database Baseline Freeze)

- `V1__initial_schema.sql` is frozen. The file is read-only historical record.
- All future database changes must be delivered as `V2__*.sql` (or higher) migrations.
- City (`public_city_display`) is optional poster-supplied context: stored on `challenges`, normalized (trim, whitespace → NULL) on both INSERT and draft UPDATE, immutable after activation, and never scored. Restaurant alone determines `where_correct`.
- `get_storage_keys_for_deletion` uses `UNION` (not `UNION ALL`) to return one distinct row per physical storage key, including `re_encoded_storage_key`.
- Approved by Bill and GPT/Codex on 2026-08-07. Full record in `12_Releases/V1_Database_Baseline.md`.
- Migration SHA-256: `2581412af146acdaaf9a7139c98a208fa4b1fe1a355ee14e043f9117b6f3afc3`
- Tests SHA-256: `5d1e2e25ccfb232be985c2e08acfeda0966bedf9fee3c8921f58eda7aa8046c3`

---

## Confirmed — 2026-08-16 (Gate 2B Design Decisions — OQ-1 through OQ-4)

All four open questions from Gate-2B-CF-Proposal-Rev10.md §9 resolved by Bill on 2026-08-16.

### OQ-1 — Production upload path: presign direct to R2

- `upload-authorize` returns a pre-signed R2 PUT URL; the iOS client uploads directly to Cloudflare R2.
- Expiration: 5 minutes.
- Object key: server-generated unique key (not client-supplied).
- Pre-signed URL scopes the expected `Content-Type`; client must send that exact type.
- `upload-complete` re-validates actual type and size server-side as a second gate.
- The presigned URL is treated as an ephemeral bearer credential and is never stored.

### OQ-2 — Display key format: deterministic, UUID-derived

- Display key: `display/{media_id}.webp` where `media_id` is the existing media object UUID.
- Idempotent: re-encoding the same media always produces the same key, overwriting the previous result.
- No double-extension: avoids the `display/foo.webp.webp` artifact from basename derivation.
- No additional database field required — key is derivable from `media_id` at runtime.

### OQ-3 — Production Worker auth: Cloudflare Access service token

- The Cloudflare Worker hostname is protected by a Cloudflare Access Service Auth policy.
- `upload-complete` sends two headers:
  - `CF-Access-Client-Id: <client-id>`
  - `CF-Access-Client-Secret: <client-secret>`
- `CF_ACCESS_CLIENT_ID` and `CF_ACCESS_CLIENT_SECRET` stored as Supabase secrets.
- No custom HMAC or replay-validation code in the Worker.
- Tokens can be rotated with an overlap period before revoking the old token.

### OQ-4 — Per-dimension limit: 8,192 px per side

- Worker rejects when `width > 8192` OR `height > 8192` OR `width × height > 15,500,000`.
- All three gates must pass; any single failure returns 422.
- 8,192 px is an intentional application safety limit, not a Cloudflare product requirement.
- Accommodates sensible mobile imagery; rejects extreme panoramas and pathological dimensions.

---

## Confirmed — 2026-08-16 (Gate 2B CF Spike — Cloudflare R2 + Images Binding PASS)

- Gate 2B Cloudflare R2 + Images Binding feasibility spike (Rev 10) passed all probes on 2026-08-16.
- Full proposal, run history, and probe table: `tools/image-spike/Gate-2B-CF-Proposal-Rev10.md`
- `run-spike.sh` final SHA-256: `61c952d746b33807d30bc18be832af3514ef78b82d1995d20512889f3db4fa9f`
- Overall verdict: **PASS (CF-P-8 INCONCLUSIVE)** — architecture viable.

**What was confirmed:**

- Cloudflare Worker + R2 bucket + Images Binding is viable for server-side re-encoding and defense-in-depth metadata stripping.
- Input gates: 10 MB byte limit and 15.5 MP pixel-area limit enforced in the Worker before transform.
- Output: WebP, `anim:false`, max 5 MB bounded stream.
- Metadata stripping: confirmed absent — EXIF, XMP, GPS, ICC all stripped from output WebP by Cloudflare Images.
- CPU budget: Free plan 10 ms limit; CF-P-9 returned 200 OK on the hosted Worker (Error 1102 would have fired if the limit were exceeded). CF-P-8 metric was INCONCLUSIVE due to Free plan analytics lag (~5 min).
- Supabase `upload-complete` Edge Function will call the Cloudflare Worker after R2 upload; Cloudflare is not a Supabase component.
- Display key format: `display/{basename}.webp` — deterministic, double extension produced for WebP-source inputs (e.g., `display/fixture.webp.webp`); production key format TBD per OQ-2.

**`upload-complete` implementation status:**

- Unblocked from Gate 2B perspective.
- Remains blocked pending: (1) Step 27 production Worker proposal cycle (separate three-party approval required for production infrastructure); (2) resolution of OQ-1 through OQ-4.

**Open questions resolved — see 2026-08-16 (Gate 2B Design Decisions) entry below.**
