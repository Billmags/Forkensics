# Open Questions

## Resolved — 2026-08-05

1. **Play style** — Asynchronous. ✓
2. **Round close** — Deadline (poster selects 1–48 hours at posting) OR all eligible players submitted, whichever comes first. Poster may manually reveal after 2+ submissions. ✓
3. **Guess editing** — Yes, editable until round locks. ✓
4. **Where? definition** — Venue name + city (both required, both free-text, no partial credit). Map pin deferred to V2. ✓
5. **What? precision** — Must identify the actual dish. Poster supplies canonical name, accepted alternates, and optional spelling variants. Poster resolves disputes. ✓
6. **Clues** — Private to the requesting eligible player. Each revealed clue deducts 40 points from that player's combined case score. Other detectives and the poster cannot see the request or clue before reveal. ✓ (superseded 2026-08-15)
7. **Poster scoring** — Poster is excluded from scoring on their own challenge. ✓
8. **Food vs. location weight** — Equal weight. Separate races. ✓
9. **Location scoring** — Binary: venue name correct + city correct. Map distance scoring deferred to V2. ✓
10. **Standings** — All-time (required) + weekly (secondary). ✓
11. **Score corrections** — Admin may correct with mandatory written reason. Shown in round history with admin note and timestamp. ✓
12. **Pilot audience** — Adults only. Child account design deferred. ✓
13. **Multiple groups** — One account may belong to multiple groups. ✓
14. **Member management** — Group creator is first admin. Admins may invite, remove, and promote others to admin. Invite by expiring shareable link. ✓
15. **Photos per challenge** — One photograph per challenge for MVP. Multiple angles deferred to V2. ✓
16. **Poster story** — Optional story appears only after reveal. ✓
17. **Reactions and comments** — Required in MVP. ✓
18. **Apple Maps link** — Yes, after reveal. ✓
19. **Minimum iOS version** — iOS 18. ✓
20. **Authentication** — Sign in with Apple. ✓
21. **Backend** — Supabase (preferred, not yet approved for implementation). ✓
22. **Push notifications** — Required for: new challenge posted, round revealed, deadline reminder, new hint, new comment after reveal. Safe notification text must not reveal dish or location on lock screen. ✓
23. **Pricing** — Free for the family pilot. Monetization undecided and excluded from V1 architecture. ✓
24. **Family pilot distribution** — TestFlight. ✓

## Resolved — 2026-08-18

25. **iOS deployment target** — iOS 18.0 minimum, iPhone only, portrait-only for initial release. Landscape is unsupported. ✓
26. **City/location scoring** — City is optional display and discovery context only. It is never part of answer matching or scoring. Older planning documents that treat city as scored are superseded; historical records are preserved as superseded rather than silently rewritten. ✓
27. **Lock In behavior** — Lock In is irreversible after a clear confirmation prompt. Detectives may edit freely until they confirm. Once locked, that detective immediately gains access to Table Talk; other detectives cannot see their answers. The deadline automatically locks or closes any unfinished guesses per existing game rules. ✓
28. **Clue vs hint terminology** — Use "Clues" consistently in all user-facing copy. Do not rename existing backend columns; map backend field names to "Clues" in the Swift/domain layer unless a separately reviewed migration is genuinely necessary. ✓

## Still Open

- **Minimum guessers before poster can force-reveal** — Confirmed as 2. Does this mean 2 total submissions or 2 correct submissions? Assumed: 2 total submissions regardless of correctness. Needs explicit confirmation.
- **Notification opt-out granularity** — Can players opt out of specific notification types (e.g., new comment) while keeping others (e.g., new challenge)?
- **Pilot device inventory** — Required before implementation begins. iPhone models and iOS versions in use by family pilot participants.
- **Group deletion** — What happens to challenges and scores when a group is deleted?

### Pre-V4 Schema Decisions (must resolve before V4 migration is written)

- **Invite pause during active challenge** — Currently `eligible_participants` snapshots at activation, but group invite tokens remain valid. A late joiner can still join the group, see the active challenge (as a group member), and place a guess. Decision needed: should `activate_challenge` pause the group's active invite token (setting e.g. `paused = true`) and unpause it on challenge expiry/cancellation? Or should a different mechanism prevent late joiners from participating mid-game? This also interacts with whether a non-eligible group member can place a `guess_attempt` at all (current triggers check group membership, not `eligible_participants`).

- **Per-player private clues — schema** — Approved behavior: clues are private, optional, and per-player. Poster enters one optional clue per race at challenge creation. A player who requests a clue sees it only for themselves; other players and the poster cannot see the request or clue before reveal. The server records the request before revealing the clue and locks the confirmed 40-point deduction server-side. One clue per race in V1. Two schema decisions required:
  1. **Clue text storage**: Add a `race` column (`'what'|'where'`) to the existing `clues` table with a UNIQUE constraint on `(challenge_id, race)` — one clue per race per challenge — OR move clue text directly onto `challenges` as `dish_clue_text text` and `restaurant_clue_text text` nullable columns. The `clues` table approach is more normalized; the `challenges` columns approach is simpler for V1.
  2. **Penalty storage**: Add a `clue_requests` table with `(challenge_id, player_id, race)` UNIQUE constraint. The confirmed -40 point deduction is either a stored integer column (flexible if penalty becomes configurable later) or derived from the recorded RulesVersion. Stored integer recommended. RLS: players see only their own rows. Button suppressed client-side when no clue exists for that race.


## Resolved — 2026-08-05 (GPT Reconciliation)

- **Score correction after reveal** — Poster or admin submits correction with mandatory reason. Original records immutable. Scores recalculated using recorded RulesVersion. CorrectionEvent visible in challenge activity. Affected players notified. ✓
- **Account deletion** — Player becomes "Former Player." Historical data retained without identity. Active guessing rounds treated as withdrawal. Active posted challenges cancelled. Sole admin: transfer to longest-tenured member or archive group. ✓
- **Auto-close timing** — Poster selects 1–48 hours at posting. Default is 2 hours. ✓
