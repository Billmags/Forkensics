# Forkensics Guide Audit

Date: 2026-08-15

## Audit basis

This audit compares the active SwiftUI wireframe flow with:

- `01_Product/MVP-Scope.md`
- `01_Product/PB-APPSTORE-001.md`
- `01_Product/PB-UI-001.md`
- `01_Product/Product-Brief.md`
- `04_UX/User-Flows.md`
- `10_Decisions/Decision-Log.md`
- `10_Decisions/Open-Questions.md`

When sources disagree, the newest explicit decision in `Decision-Log.md` is treated as authoritative. The current app is intentionally a local wireframe, so several items below are expected implementation gaps rather than regressions.

## Aligned now

- The main journey is connected from onboarding through case inspection, guessing, lock-in, Table Talk, reveal, and score breakdown.
- Case creation accepts a real library or camera photo, validates the required answer fields, selects one or more tables, previews the case, and confirms sending.
- Reveal duration supports every whole hour from 1 through 48, defaults to 2 hours, and is preserved through review, confirmation, the posted-case list, and the poster detail screen.
- A newly posted case appears under **Posted by You** and opens into a poster-facing case detail screen with the private answer, selected tables, and a live countdown.
- Incoming unrevealed cases use mystery-safe titles rather than exposing the dish answer.
- Table Talk messages identify their sender and the composer sends from both Return and the arrow button.
- The reveal has a celebratory state, score breakdown, food-first visual hierarchy, haptics, and Reduce Motion handling.
- City/location is optional in the posting UI, matching the latest `Decision-Log.md` decision that `public_city_display` is optional context and is not scored.
- A persistent local multiplayer harness now exercises the core loop on one simulator or phone: switch personas, post a case, receive it as eligible detectives, reveal a clue privately, lock independent guesses, update the poster’s participation-only table status, exchange per-case Table Talk messages, reveal, match answers, and calculate the 100/80/60 ranks with the 40-point clue deduction and zero floor.
- The main Table Talk tab now follows live privacy state: an eligible detective gains access after locking in; the poster gains access only after reveal.
- Posters provide a required, non-spoiler Case Title separate from the private Dish answer; that title identifies the case throughout the live loop without exposing what detectives must guess.

## P0 — core gameplay needed next

1. **Replace the local harness with shared backend state.** Local cases and activity now survive relaunch and support multi-persona testing on one installation, but they are not yet delivered across real accounts or devices and are not authoritative server state.
2. **Implement the complete poster-control rules.** The Debug harness provides forced reveal for testing, but production still needs answer editing until the first guess, answer locking after the first guess, the approved manual-reveal threshold, group-wide clue delivery while open, and cancel/withdraw with no points.
3. **Snapshot eligible players on the backend.** The local harness uses a deterministic hard-coded table directory. Production posting must snapshot participants, exclude the poster, prevent late joiners from changing the active race, and stop withdrawn/removed players from blocking auto-reveal.
4. **Make scoring authoritative and tie-safe on the server.** The local harness performs normalized answer matching and 100/80/60 ranking by lock time, including private clue deductions and the zero floor. Production must calculate ranks transactionally, define ties, persist versioned score events, and update standings.

## P1 — required for the documented MVP

1. Enforce one active challenge per poster before allowing another post.
2. Make Table Talk visibility depend on the actual player lock state; preserve each challenge’s conversation; add reactions, comment deletion, reporting, and blocking.
3. Add real push notifications for a new case, reveal, deadline reminder, new clue, and post-reveal comment, with spoiler-safe lock-screen text.
4. Complete post-reveal behavior: persistent results, standings, comments/reactions, poster story, and an Apple Maps link for the restaurant.
5. Add table creation/join/invite/admin flows and meaningful empty/error/offline/loading states.
6. Add correction events and audit history without mutating the original guess records.
7. Connect the media privacy pipeline: re-encode uploads, strip EXIF/GPS and other metadata, use private delivery, and enforce file/type/size limits.
8. Add the required safety/account operations: report, block, delete content/account, leave a table, and handle active challenges during deletion or withdrawal.
9. Exercise the required edge-state fixtures: simultaneous challenges, revealed and unrevealed cases, tied timestamps, a clue sent mid-round, and a cancelled case.

## P2 — validation and polish after the loop works

- Make Cases, leaderboard, and alert filter tabs interactive rather than decorative.
- Audit Dynamic Type, VoiceOver order/labels, contrast, touch targets, compact devices, landscape policy, and physical-device haptics.
- Add loading, retry, offline, upload-progress, and destructive-action confirmation states.
- Run a final copy, spacing, safe-area, animation, and screenshot pass only after P0 interactions use one shared source of truth.

## Product conflicts — resolved 2026-08-18

1. **City/location:** ✅ RESOLVED — City is optional display and discovery context only, never scored. Current UI is correct. Older planning documents that treat city as scored are superseded; preserve as historical rather than silently rewrite.
2. **Submit versus lock:** ✅ RESOLVED — Lock In is irreversible after a clear confirmation prompt. Detectives may edit freely until they confirm. Once locked, that detective immediately gains access to Table Talk. Deadline auto-locks unfinished guesses per existing game rules.
3. **Clue versus hint terminology:** ✅ RESOLVED — Use “Clues” in all user-facing copy. Backend column names are not renamed; the Swift/domain layer maps them to “Clues.” A schema rename requires a separate reviewed migration.

## Recommended implementation order

1. Introduce one shared challenge/participant/guess state model and persist it.
2. Wire the poster case detail controls and authoritative close/reveal transitions.
3. Wire the detective guess/lock path to the same model.
4. Calculate results and standings from that state.
5. Connect Table Talk, notifications, and post-reveal social behavior.
6. Finish edge states, accessibility, and visual polish.
