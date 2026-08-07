# Open Questions

## Resolved — 2026-08-05

1. **Play style** — Asynchronous. ✓
2. **Round close** — Deadline (poster selects 1–48 hours at posting) OR all eligible players submitted, whichever comes first. Poster may manually reveal after 2+ submissions. ✓
3. **Guess editing** — Yes, editable until round locks. ✓
4. **Where? definition** — Venue name + city (both required, both free-text, no partial credit). Map pin deferred to V2. ✓
5. **What? precision** — Must identify the actual dish. Poster supplies canonical name, accepted alternates, and optional spelling variants. Poster resolves disputes. ✓
6. **Hints** — Allowed, poster-written, broadcast to all eligible players equally. No point penalty. ✓
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

## Still Open

- **Minimum guessers before poster can force-reveal** — Confirmed as 2. Does this mean 2 total submissions or 2 correct submissions? Assumed: 2 total submissions regardless of correctness. Needs explicit confirmation.
- **Notification opt-out granularity** — Can players opt out of specific notification types (e.g., new comment) while keeping others (e.g., new challenge)?
- **Pilot device inventory** — Required before implementation begins. iPhone models and iOS versions in use by family pilot participants.
- **Group deletion** — What happens to challenges and scores when a group is deleted?

## Resolved — 2026-08-05 (GPT Reconciliation)

- **Score correction after reveal** — Poster or admin submits correction with mandatory reason. Original records immutable. Scores recalculated using recorded RulesVersion. CorrectionEvent visible in challenge activity. Affected players notified. ✓
- **Account deletion** — Player becomes "Former Player." Historical data retained without identity. Active guessing rounds treated as withdrawal. Active posted challenges cancelled. Sole admin: transfer to longest-tenured member or archive group. ✓
- **Auto-close timing** — Poster selects 1–48 hours at posting. Default is 2 hours. ✓

