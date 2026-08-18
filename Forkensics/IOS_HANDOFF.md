# Forkensics iOS Handoff

## Scope boundary

- SwiftUI wireframes and local fake data only.
- Recreate approved mockups and the approved navigation flow.
- Do not add Supabase integration, networking, uploads, authentication, or production data models.
- Do not modify migrations, Edge Functions, backend configuration, schema, or backend files.
- Keep all iOS work inside this `Forkensics/` Xcode project directory.
- Treat architecture choices as provisional until reviewed.
- Keep the project compiling after every implementation stage.

## Planning sources inspected

- `../02_Roadmap/Roadmap.md`
- `../04_UX/User-Flows.md`
- `../07_Steps/`
- `/Users/billschroeder/Downloads/Forkensics_Master_Screen_Inventory_WITH_MOCKUPS_v57.docx`

The master inventory contains 59 embedded visuals spanning 46 numbered destinations, state variants, and four authentication screens. Its physical document order is not treated as navigation order.

## Existing project baseline

- Existing project: `Forkensics.xcodeproj`
- SwiftUI app entry point: `Forkensics/ForkensicsApp.swift`
- Current deployment target: iOS 18.0
- Current bundle identifier: `com.forkensics.prototype`
- Current Swift language setting: Swift 5.0
- Existing local service seam: `DataServiceProtocol` with `MockDataService`
- Existing screens include feed, challenge creation/detail/guessing, reveal, conversation, and leaderboard views.
- No Supabase or networking integration was observed in the iOS project inventory.
- No prior `IOS_HANDOFF.md` was present.
- The visible app now enters the isolated `Forkensics/Wireframes/` layer. The earlier prototype models, service, and views remain in the project for reference but are not used by the wireframe app entry flow.
- The official no-text Forkensics mark is stored in `Assets.xcassets/ForkensicsLogoNoText.imageset`. The app copy removes only the source file's off-center transparent canvas; the logo artwork, colors, and proportions are unchanged.
- The approved Chicken Parmigiana photo is stored in `Assets.xcassets/ChickenParmigiana.imageset` and is used throughout the matching sample/active-case journey. Unrelated dishes retain placeholders until their own approved images are supplied.
- The initial app icon master is stored in `Assets.xcassets/AppIcon.appiconset/ForkensicsAppIcon.png`: approved orange fork/location-pin and pale magnifying-glass mark, optically centered on solid black, with no text or baked-in corner mask. This is a provisional generated composition pending final brand approval.

## Provisional architecture decisions

1. Preserve a single SwiftUI application target until the approved screen inventory requires otherwise.
2. Keep all new work in a separate `Wireframes/` layer using local, deterministic fake data.
3. Use typed `WireframeRoute` values for the signed-in navigation stack.
4. Centralize colors, spacing, buttons, cards, fields, headers, avatars, and the bottom navigation component.
5. Do not treat the existing prototype models or views as production architecture.
6. Lock the bottom navigation to exactly five destinations in this order: Cases, Table Talk, Post, Leaderboard, Profile. Individual screens do not define or vary this component.
7. Use the black/near-black, white/soft-gray, and Forkensics orange visual system. The clue-revealed state does not introduce blue.
8. Scoring uses independent Dish and Place races: 1st correct earns 100 points, 2nd earns 80, 3rd earns 60, and later correct answers earn zero. Each clue use deducts 40 points from the combined case score.
9. Treat “Home” as the Cases destination.
10. Review-required mockups may be used for layout reference, but exploratory copy or mechanics are not promoted into product behavior.
11. The sample reveal omits the circular unlock graphic to keep the complete reveal and CTA visible without unnecessary scrolling.
12. The sample guess fields fill sequentially with a typewriter animation: Dish, then a 900 ms pause, then Restaurant. Reduce Motion fills both immediately. The reveal screen is static so the result reads decisively without delay.
13. Signed-in screens use one notification bell in the shared brand header. Cases does not add a second bell; the shared bell opens Alerts.
14. The app icon uses the no-text Forkensics mark on solid black. It contains no shadow, gradient, border, or pre-rounded corners; iOS applies the platform mask.
15. The welcome/sample photo container is width-constrained independently of the source image's aspect ratio so the 330-point hero stays large without widening the screen. The three sample-flow primary buttons provide light impact feedback on physical devices.
16. Table Talk sends trimmed, non-empty local messages from either the keyboard Send key or the arrow button, clears the composer, scrolls to the new bubble, and provides light impact feedback.
17. Sample and real case reveals share an orange-on-black celebration hero with a one-shot confetti burst, spring motion, success haptic, and animated point count. Reduce Motion keeps the result static and immediate; answer rows never wait for the celebration.
18. The celebration hero uses a compact 198-point presentation, and the sample reveal tightens spacing and photo height slightly so its primary CTA is fully visible on the iPhone 17 Pro rather than peeking below the fold.
19. The Active Case title is a compact 23-point section heading so the case photo and playable content remain the screen's visual focus.
20. The Locked In screen uses the tabletop itself as the confirmation state, without a duplicate avatar/headline hero. Seating adapts to table size: circular for 2–6 detectives, oval for 7–12, and a long rounded rectangle for 13–20. Avatar centers are distributed by equal perimeter distance; names collapse to initials above eight players. Lock-state rings remain visible, and the center summarizes the table and lock count. Table Talk bubbles identify their sender, including the current detective as “You.”
21. Locked In and Table Talk use the same detective lock-state source; only locked detectives participate in the sample conversation. Every pushed destination locally hides the system navigation bar and back button, then places Back inside the shared safe-area-aware header; hiding navigation only on the outer stack can leave a duplicate empty row. Unrevealed case lists use mystery-state titles and non-spoiling accessibility labels rather than dish answers.
22. Creating a case starts with a real food-photo input. The Post screen uses the system photo picker for library selection, offers the native camera when available, previews the selected image in place, and includes the required camera privacy description.
23. The Post flow is interactive end to end: required photo/dish/restaurant validation, multi-table selection, answer-and-recipient review, send confirmation, return to Cases, and reset for another post. Step changes scroll back to the top and each step provides an explicit Back action.
24. Sent cases move into `ForkensicsMainShell` shared session state before leaving Post. The Your Cases screen renders them first in a distinct Posted by You section, preserving the submitted photo, answer, and selected table names rather than mixing them with incoming mystery cases.
25. Case setup presents one-tap reveal-time cards for 2 hours (default), 6, 12, and 24, plus a Custom wheel for any whole-hour value from 1 through 48. The chosen duration is preserved through review and confirmation and appears on the poster’s Your Cases card.
26. Posted by You cards are navigation targets. They open a poster-facing detail screen that preserves the submitted photo and private answer, lists recipient tables, and derives a live countdown from the posting time and selected duration. The remaining production gameplay gaps and source-document conflicts are tracked in `GUIDE_AUDIT.md`.
27. Custom headers accept an explicit back action when a destination is driven by the app-owned `NavigationStack` path. The poster case header sits outside its `ScrollView` so scrolling cannot compete for its tap, and returning to Cases replaces the path with an empty value instead of relying on ambient SwiftUI dismissal or in-place path mutation.
28. The reveal and score-breakdown samples use the confirmed fixed scoring ladder. The worked example is Dish 1st (+100), Place 2nd (+80), one clue (−40), for 140 total. The onboarding sample assumes both races won with no clue for 200 total.
29. The combined challenge score floors at zero after clue deductions. Production scoring must be versioned per activated challenge so later point changes affect new challenges without silently changing historical scores.
30. Clues are private to the eligible player who accepts the 40-point deduction. Other detectives and the poster cannot see the request or clue before reveal. The poster is excluded from that challenge's Table Talk until reveal.
31. Posted cases are owned by a local `WireframeChallengeStore` and encoded atomically in Application Support. They survive ordinary app termination and relaunch on the same installation; this is prototype persistence, not cross-device delivery or a substitute for the production backend.
32. Answer evaluation uses `AnswerMatcher` version 1.0: normalized case/diacritics/punctuation/whitespace, `&`/`and`/standalone `n` equivalence, curated dish-name groups, poster aliases, and conservative typo tolerance. Restaurant alone determines the Place result; city remains display context. `ScoringRules` version 2.0 applies the confirmed 100/80/60/0 ladder.
33. Each Sent To row on the poster's case detail is a navigation target. Its table-status destination shows the posting-time roster and only Poster / Guess In / Waiting participation state. It exposes no answer text, clue activity, or Table Talk before reveal.
34. Debug builds include a persistent local multiplayer harness in Profile. “Test As” switches among table members on one device. Posted cases are delivered to eligible local personas; private clue use, irreversible guesses, lock state, per-table messages, forced/timed reveal, answer matching, rank points, and the clue deduction share one persisted source of truth. A poster sees only participation before reveal and cannot enter that case’s Table Talk until reveal. “Reveal Now (Test)” exists only in Debug on the poster case detail so the full results path can be exercised without waiting or filling a 20-person table. This harness is simulator/device validation infrastructure, not the production cross-device backend.
35. Participant reveals use a direct category comparison rather than separate answer and guess cards. Dish and Restaurant each show the locked guess, correct answer, and an explicit green Correct or red Incorrect verdict; optional restaurant location remains answer context. The scored rank rows and clue deduction follow immediately below.
36. Every posted case has a required poster-authored, non-spoiler Case Title separate from the hidden Dish answer. The title is reviewed before sending and identifies the case in participant/poster lists, active investigation, locked-in state, participation status, Table Talk, and reveal. Previously persisted records decode safely as “Untitled Case.”
37. The onboarding sample guess now uses real TextField focus so the system keyboard appears while answers type. The sequence is intentionally paced to roughly seven seconds: keyboard entrance, Dish typing, reading pause, Restaurant focus/typing, reading pause, keyboard dismissal, then Lock In activation. “Skip Typing” completes it immediately, and Reduce Motion still bypasses all staged motion.
38. Post → Choose Tables now opens the approved two-screen table-creation flow. Build Your Table validates a 30-character name, table avatar, and at least one detective; the creator is automatically the owner and may select up to 19 additional detectives for the 20-person table limit. “Invite a New Detective” opens an in-app searchable picker where detectives can be selected and confirmed; selected people then appear on Build Your Table. Editable details/selections and a safe-area-pinned CTA are represented. Per Screen 11, creating the table skips a redundant success screen and enters the new table's owner detail immediately.
39. Profile → My Tables is now a persistent table-management path. Cards focus on membership rather than scores or active-case progress, show the table visual, description, detective count, Owner/Detective role, and created/joined date. Table detail adapts its seating shape through 20 members; owners can invite, edit, manage detectives, and delete, while detectives see only Leave Table. Created and edited tables persist locally and their member roster participates in the local case-delivery harness.
40. The duplicate logo inside the Create Table title block was removed because it produced a large blank region and pushed the detective controls below the fold. The form now keeps the shared header brand only, dismisses the keyboard interactively while scrolling, and reserves space above the pinned review CTA.

## Build status

- Debug iPhone Simulator build: PASS on 2026-08-15.
- My Tables and role-based table detail simulator build: PASS on 2026-08-16.
- Built both `arm64` and `x86_64` simulator architectures with code signing disabled.
- Full simulator build, including the logo, food photo, and app-icon asset catalog: PASS on 2026-08-15 after CoreSimulator access was granted.
- Legacy `#Preview` macros were converted to `PreviewProvider` declarations so command-line compilation no longer depends on the preview macro plugin.
- After CoreSimulator access was granted, the rebuilt app was installed and launched on an iPhone 17 Pro simulator. Welcome-screen screenshot QA passed: the layout stays within the viewport and the 330-point hero image remains large. Physical-device haptic verification remains pending.
- The logo asset was visually inspected and its asset-catalog JSON validated. The earlier asset-compiler sandbox limitation was resolved for verification, and the full post-logo asset-catalog build now passes.

## Implemented wireframe routes

- Splash → Welcome → Sample Guess → Sample Reveal → Account Choice
- Sign In, Create Account, Forgot Password, and Check Email branches
- Fake completion of the account flow → Cases
- Fixed tab shell: Cases, Table Talk, Post, Leaderboard, Profile
- Cases → Active Case → Make Guess
- Optional clue confirmation → clue-revealed guess state
- Make Guess → You’re Locked In → Active Table Talk
- Case Revealed → Score Breakdown
- Cases → Alerts
- Profile → Local Multiplayer “Test As” player switcher (Debug only)
- Post as one local player → switch player → receive case → private clue/guess → lock in → live Table Talk
- Poster case → table participation status → Debug reveal → participant results and scored breakdown
- Profile → My Tables → owner/detective table detail and management
- Post → Create Table → newly created owner table detail
- Create Table → in-app searchable detective picker → Review Table

All account actions are local navigation only. No authentication is performed.

## Open questions

1. ~~Confirm whether iOS 18.0 is the intended minimum deployment target before architecture hardens.~~ **Resolved 2026-08-18:** iOS 18.0 minimum, iPhone only, portrait-only. Landscape unsupported.
2. ~~Confirm the final device-family and orientation support before the preview gallery becomes an acceptance suite.~~ **Resolved 2026-08-18:** iPhone only, portrait-only.
3. Review-required settings, privacy, support, table-role, and invitation mechanics remain unresolved unless a later product decision approves them.

## Unfinished work

- Replace food/photo placeholders with approved local assets as they become available.
- Perform interaction and screenshot QA across the remaining screens, plus physical-device haptic verification.
- Expand the first connected flow to the remaining inventoried table, settings, safety, support, leaderboard-state, profile-detail, and poster-management screens.
- Add screen-by-screen preview coverage for every approved/current mockup.
- Audit compact devices and all accessibility Dynamic Type sizes in a simulator.
- Reconcile review-required product copy and mechanics before making them interactive.
- Keep the existing prototype layer isolated until a later review decides whether it should be removed or migrated.
