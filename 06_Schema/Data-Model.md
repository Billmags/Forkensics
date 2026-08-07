# Conceptual Data Model — Draft

This is not an executable schema. Claude owns database migrations after approval.

## Identity model

- Application/player primary key: Supabase `auth.users.id` (UUID). This is the value returned by `auth.uid()` and is the anchor for all RLS policies and foreign keys in application tables.
- Apple identity: stored as provider `apple` in Supabase's identity record.
- Apple stable identifier (`sub`): stored as the `provider_id` on that identity record. Not used as a primary key anywhere in the application.
- Email: optional profile information only. Never a primary key. May be a private relay address.
- Display name: captured from `credential.fullName` during first Apple sign-in and stored in Supabase user metadata and the Player profile. If Apple returns no name, player must choose one during onboarding.

## Candidate entities

### Player

Supabase `auth.users.id` as primary key. Display name, optional avatar, notification preferences, lifecycle status.

### Group

Private game circle, creator (player), display name, default auto-close duration, invite state.

### Membership

Player/group relationship, role (member or admin), join date, status.

### Challenge

Poster, group, photo reference (MediaObject id), optional story, posted time, auto-close duration (1–48 hours, poster-selected, default 2 hours), deadline timestamp, lifecycle state, correction metadata.

Lifecycle states (valid transitions only):
- `draft → active`
- `draft → cancelled`
- `active → locked`
- `active → cancelled`
- `locked → revealed`
- `locked → cancelled`
- `revealed` — terminal
- `cancelled` — terminal

Invalid transitions must be rejected at the database level.

### ChallengeSecret

Separate table. Holds canonical dish name, accepted dish aliases, canonical restaurant name, canonical city. Linked to Challenge by id.

RLS policy: readable only by the poster and trusted server functions (service role). Denied to all other authenticated users before reveal. After reveal, answers may be returned through an authorized server operation only.

Canonical answers must never appear in any client-visible Challenge row.

### EligibleParticipant

Immutable snapshot of active group members at the moment a challenge becomes active. Poster excluded. Written once; never modified.

Later removals and withdrawals are represented by a separate ExclusionEvent record. Effective eligibility = posting-time roster minus subsequent exclusions.

### GuessAttempt

Immutable append-only record for every submission or edit. Fields: player, challenge, what-text, where-restaurant, where-city, server receipt timestamp, server-generated monotonic receipt sequence, what-correctness decision (null until reveal), where-correctness decision (null until reveal).

Because What? and Where? are independent races, each has its own first-correct arrival time. "First correct" for each race is the earliest GuessAttempt for that player on that challenge where the respective correctness field is true.

A current-guess summary view may be derived or maintained separately for display purposes.

### Hint

Challenge, poster, hint text, created timestamp. Broadcast equally to all eligible players. No point penalty.

### RulesVersion

Identifier and description of the scoring rules used for a cohort of ScoreEvents. Required for score reproducibility.

### ScoreEvent

Immutable. Player, challenge, race (what or where), points awarded, rank, rules version id, calculated timestamp. Scores are never silently overwritten. Corrections produce a new ScoreEvent linked to a CorrectionEvent.

### CorrectionEvent

Challenge, corrected by (player), correction type, old value, new value, mandatory reason, timestamp. Visible in challenge activity. Affected players notified.

### Reaction and Comment

Post-reveal only. Attached to a challenge. Player, content, timestamp, deleted flag. Players may edit or delete their own. Group admins may remove any.

### Invitation

Group, issuer, expiring shareable link token, expiry timestamp, use limit, status.

### MediaObject

Internal storage path (opaque UUID — no sequential or challenge-linked patterns). Challenge, content type, dimensions, server-re-encoded flag, lifecycle state, deleted timestamp. Do not store expiring signed URLs as permanent identifiers. Delivered only through authenticated Edge Function proxy after group membership verification.

## Important invariants

- All application foreign keys reference Supabase `auth.users.id`, not Apple's sub identifier.
- Only active group members can access a group's challenges.
- Canonical answers live in ChallengeSecret and are inaccessible to non-poster clients before reveal.
- EligibleParticipant is immutable after posting. Removals use ExclusionEvent.
- GuessAttempt records are append-only and never modified.
- Scores are reproducible from versioned rules and immutable ScoreEvents.
- Rank is determined by server receipt timestamp; ties broken by server-generated monotonic receipt sequence. Client timestamps never determine rank.
- Removing a source photo removes or invalidates its derivatives according to the approved retention rule.
- Invalid challenge state transitions are rejected at the database level.

