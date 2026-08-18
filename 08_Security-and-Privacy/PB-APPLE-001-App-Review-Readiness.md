# PB-APPLE-001 — Forkensics App Review Readiness

**Status:** Living document — update as development progresses
**Governance:** Requirements in this document should be considered during development, not retrofitted before submission.
**Last updated:** 2026-08-07 — UGC safety requirements reclassified as non-deferrable V1 requirements; photo moderation gate, text filtering, reporting, and blocking must ship with photos and Table Talk.

---

## Purpose

Build Forkensics in a way that minimizes App Store review problems before submission.

This is not a launch checklist only. These requirements should be considered during development so we are not rebuilding core flows at the end.

---

## 1. App Completeness

Before submission:

- No placeholder screens.
- No dead buttons.
- No "coming soon" buttons unless clearly appropriate and nonessential.
- No test data that looks accidental.
- No broken links.
- No crashes in normal gameplay.
- No obvious loading failures.
- No unfinished onboarding steps.
- Every feature shown in App Store screenshots must actually work in the submitted build.
- Every feature described in App Store metadata must exist and function.
- Test all major paths on a real iPhone, not just Simulator.

Primary flows to test:

- Create account
- Sign in / Sign out / Start/open app
- View mystery
- View food photo
- Enter dish guess
- Enter city guess
- Use Clues
- Submit answer
- See result/reveal
- Score correctly
- View leaderboard
- Post a mystery
- Upload/take photo
- Complete posting flow
- Report content
- Block user if applicable
- Delete account
- Recover gracefully from poor/no internet connection

---

## 2. Apple Reviewer Access

Apple must be able to experience the entire app during review.

Create a dedicated review account if login is required. The reviewer account should:

- Already contain enough sample content to demonstrate gameplay.
- Have access to all major features being reviewed.
- Not require invitation from another user.
- Not require waiting for a real player to respond.
- Not depend on a scheduled event occurring later.
- Not require us to manually approve anything during review.

Provide Apple with clear review notes explaining exactly how to test Forkensics, including: test username, test password, explanation of gameplay, how to create a mystery, how to guess, how scoring works, how to access Clues, how to see a completed/revealed game, and any unusual behavior Apple should know about.

Reviewer should be able to understand the core experience within a few minutes.

---

## 3. User-Generated Content

**This section is non-deferrable. UGC safety must ship with photos and Table Talk in V1.** Apple Guideline 1.2 applies to invitation-only private groups. EXIF stripping handles privacy; it does not satisfy objectionable-content filtering. These are separate requirements.

Apple's UGC guideline requires all four of:
- Filtering objectionable content
- Reporting with timely developer response (internal target: 24-hour response)
- Blocking abusive users
- Published contact information

The app must include:

- Ability to report inappropriate content (challenges/photos, comments, profiles).
- Ability to block users.
- Mechanism for reviewing and removing reported content.
- Terms prohibiting objectionable content.
- Clear consequences for abusive users.
- Method for contacting Forkensics/support regarding content issues (real published support email, not a placeholder).

**Reporting must not be fake UI.** If a user taps Report, the report must actually reach our moderation system or database.

Report categories to define:
- Inappropriate image
- Offensive content
- Spam
- Harassment
- Copyright concern
- Other

**Block behavior (confirmed design):** Two-way safety blocking. Neither person can interact with or receive notifications from the other. Their challenges, comments, reactions, and profiles are hidden from each other. Future challenge eligibility excludes blocked pairs. Blocking does not rewrite completed scores or historical audit records. Existing shared-group membership remains, but activity between the pair is suppressed.

**Photo moderation gate:** Uploaded photographs do not become `ready` until cleared by moderation. This is a pre-publish gate, not a report-triggered removal only. The upload pipeline must accommodate a `pending_review` status for media objects.

**Text filtering:** Server-side filtering on Table Talk comments, clues, and display names. Approach (static blocklist vs. ML-based) to be confirmed in Step 24.1.

**Server-side moderation tools required:** Admin must be able to hide/remove content and suspend users without shipping a new app version. This is a backend-only requirement — no App Store update should be required to act on a report.

Establish an internal moderation workflow with a 24-hour response target even if V1 moderation is largely manual.

**Schema required in V1 (Step 24.1):** `content_reports`, `user_blocks`, `moderation_actions` (immutable audit trail), and supporting SECURITY DEFINER functions for report, block, hide/remove, and suspend.

---

## 4. Photo Uploads

Because Forkensics revolves around user-uploaded food photography:

- Request Photos permission only when needed.
- Request Camera permission only when needed.
- Explain why the permission is necessary.
- Do not request unrelated device permissions.
- Handle permission-denied states gracefully — users should still be able to navigate the app if they deny access.

Photo upload must reject or safely handle: unsupported formats, extremely large files, failed uploads, interrupted uploads, empty uploads, and corrupt images.

Server-side image processing is used (see Step 24) rather than trusting the original uploaded file.

---

## 5. Content Safety

Because users can upload arbitrary photographs, plan for inappropriate images even though Forkensics is designed for food.

**Required (non-deferrable for V1):**

- Pre-publish moderation gate: photos held in `pending_review` state until cleared; challenge cannot be activated until media is `ready`.
- User reporting (see Section 3).
- Admin removal tools accessible without shipping a new app version.
- User suspension: suspending a user blocks posting, guessing, and commenting; does not delete account or data.
- Database record of all reports and moderation actions (immutable audit trail).

**Do not design moderation as something that requires an App Store update.**

---

## 6. Account Creation

- Account creation must work reliably.
- Login must work reliably.
- Password reset flow must work if applicable.
- Logout must be available.
- User should understand what data is associated with their account.
- If third-party login providers are added, confirm Apple's current Sign in with Apple rules before implementation.

---

## 7. Account Deletion

Users must be able to delete their account from within the app. Do not require users to email support, visit an external process, or contact us manually.

Deletion flow must be clearly accessible from Settings/Profile.

Define what deletion does to:

- Profile and personal information
- Uploaded mysteries
- Guesses and scores
- Leaderboard records
- Reports
- Authentication credentials

Determine whether some anonymized gameplay records need to remain for game integrity.

**V1 account deletion is implemented.** See Step 23/24 for the deletion architecture, including quiesce of upload sessions, storage cleanup, and Auth deletion.

---

## 8. Privacy

Before submission:

- Create an accurate privacy policy.
- App Store privacy disclosures must match what the app actually collects.

Audit every type of data Forkensics collects, potentially including: email, username/display name, profile image, uploaded food photos, guesses, device identifiers, analytics, crash logs, usage data, purchase history, push notification tokens.

Do not guess when completing Apple's App Privacy questionnaire. The answers must match the actual production app and all SDKs in use.

Also audit third-party services: analytics, authentication (Supabase Auth), database (Supabase), error monitoring, push notifications, image hosting/storage.

---

## 9. Location

Current gameplay asks users to identify a city. **Do not request the player's GPS location** — guessing a city does not require location permission.

If location is added later, document a specific product reason before requesting permission.

---

## 10. Payments and Monetization

Before adding any paid digital functionality, check Apple's current In-App Purchase requirements.

Possible future paid items: premium membership, extra Clues, game upgrades, special digital features, additional gameplay privileges, subscription, premium profile features.

Do not implement external checkout for digital app functionality without verifying Apple's rules first. Physical goods or services may be treated differently.

Review monetization architecture before implementing it.

---

## 11. Clues

Clues must operate exactly as described. Confirm:

- Clues don't produce impossible states.
- Clues don't reveal hidden information accidentally.
- Clues don't break scoring.
- Optional letter counts work.
- Clue availability is clearly communicated.

If Clues become monetized later, revisit Apple's IAP requirements before release.

---

## 12. Game Integrity

Test edge cases involving:

- Multiple players answering simultaneously
- Duplicate submissions
- User changing answer after submission
- Network interruption during submission
- Reopening the app after answering
- Poster deleting a mystery
- Poster abandoning a mystery
- Player joining late
- Tie scores
- Nobody guesses correctly
- Only one eligible player
- Zero eligible players
- A user attempting to participate twice

Server/database is the source of truth for scoring decisions — not the client.

---

## 13. App Review Demo Data

Build a review environment/account containing good examples:

| Mystery | Contents |
|---|---|
| Mystery 1 | Completed game with answer visible |
| Mystery 2 | Active game ready for reviewer to guess |
| Mystery 3 | Example demonstrating a Clue |
| Mystery 4 | Example showing leaderboard/scoring behavior |

The reviewer must not open Forkensics and see an empty home screen.

---

## 14. Reporting / Blocking

At minimum for v1, evaluate whether we need: report photo, report mystery, report user, block user.

Build the underlying functionality, not just buttons.

If users interact directly or can follow/comment/message each other later, revisit Apple's user-generated-content requirements immediately.

---

## 15. App Store Screenshots

Screenshots must represent the actual app. Do not advertise features not included in the submitted version.

Current narrative direction:
1. Food-first discovery / mystery
2. Guess the dish
3. Guess the city
4. Clues / "So close"
5. Result / reveal
6. Leaderboard / competitive payoff

Final screenshots must be built from the finished UI.

---

## 16. App Store Description

Description must clearly explain Forkensics without overstating functionality.

Core concept: a player posts a photo of a dish. Other players attempt to identify the dish and the city. Correct guesses and speed/placement contribute to gameplay and scoring.

Do not describe features that are planned but not yet shipped.

---

## 17. Age Rating

Review Apple's age-rating questionnaire carefully. User-generated content changes the risk profile compared to a closed game.

Evaluate: user-uploaded photography, social interaction, potential inappropriate content, advertising (if added), external links.

Do not automatically choose the lowest possible rating without reviewing the questionnaire.

---

## 18. Copyright / User Photos

Terms must make clear that users are responsible for content they upload.

Define how Forkensics handles: restaurant food photos, screenshots, photos copied from the internet, copyright complaints, trademarked restaurant branding, and requested takedowns.

Create a support/contact path for rights complaints.

---

## 19. Support

Before submission:

- Working support email
- Privacy Policy URL
- Terms of Service URL
- Support URL/page
- App website or landing page

All URLs supplied to Apple must work publicly.

---

## 20. Push Notifications

If Forkensics uses notifications, request permission at a sensible moment — not immediately on app launch.

Potential legitimate notifications: someone guessed your mystery, your mystery has been solved/revealed, a new relevant game is available, result/leaderboard update.

Users must be able to use the core app without enabling notifications.

---

## 21. Crash / Error Monitoring

Before beta testing, implement production-grade crash monitoring. We need visibility into: app crashes, API failures, upload failures, authentication failures, and unexpected scoring errors.

Do not depend entirely on users telling us something broke.

---

## 22. TestFlight Phase

Before App Store submission, run Forkensics through TestFlight with:

- Developer/owner
- Family/friends
- People who have never seen Forkensics before
- Multiple iPhone models
- Current supported iOS versions
- Slow internet, Wi-Fi, and cellular
- Fresh install and existing account
- Logged-out state
- Notification permission denied
- Photo permission denied

Have at least a few testers who receive almost no instructions. If they cannot understand the game, App Review may struggle too.

---

## 23. Apple Review Notes

Do not leave Review Notes empty. Draft before submission:

> "Forkensics is a social food-identification game. Players post a photograph of a dish and other players attempt to identify the dish and city.
>
> A review account has been provided with pre-populated games so all major functionality can be tested immediately.
>
> To test:
> 1. Sign in using the provided review account.
> 2. Open the active mystery.
> 3. Enter a dish and city guess.
> 4. Submit the guess.
> 5. Open the completed mystery to see the reveal and scoring.
> 6. Use the Post flow to preview creating a new mystery.
> 7. Reporting controls are available from [LOCATION].
>
> No purchase is required to test the submitted version."

Rewrite this based on the actual final app before submission.

---

## 24. Final Pre-Submission Test

Immediately before uploading the release candidate, create a brand-new account on a real iPhone and use Forkensics from beginning to end. Then:

- Delete the app.
- Reinstall from TestFlight.
- Log back in.
- Confirm data persists appropriately.
- Test posting, guessing, Clues, scoring, leaderboard, reporting, blocking (if included), and account deletion.
- Test every link.
- Test privacy/support pages.

Treat that build exactly as if it were already public.

---

## 25. Do Not Ship Until

Do not submit Forkensics for App Review until all critical items below are green:

- [ ] Core game works
- [ ] No known serious crashes
- [ ] Reviewer can access everything
- [ ] Test account works
- [ ] Sample games exist
- [ ] UGC reporting/moderation system works
- [ ] Account deletion works
- [ ] Privacy policy is live
- [ ] App Privacy disclosures are accurate
- [ ] Permissions are justified
- [ ] App Store screenshots match production
- [ ] Description matches production
- [ ] Support URL works
- [ ] No unfinished screens
- [ ] No fake/dead buttons
- [ ] Real-device testing completed
- [ ] TestFlight testing completed
- [ ] Review Notes prepared

---

## Development Principle

When deciding between:

**A.** "We can fix this before App Store submission."

**B.** "We can build it correctly now."

**Default to B.**

Forkensics should reach App Review as a polished, functioning product — not as a nearly finished development build that we hope the reviewer overlooks.

The goal is not merely to pass App Review. The goal is to make the reviewer's job extremely easy.
