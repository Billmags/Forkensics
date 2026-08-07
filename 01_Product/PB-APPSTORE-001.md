# PB-APPSTORE-001 — Forkensics App Store Marketing & Screenshot System
Version 2.0 (Approved Direction)

---

## Purpose

Create App Store screenshots that feel premium enough to be featured by Apple while remaining completely truthful to the actual Forkensics experience.

The screenshots should not simply document the app. They should market the experience.

**Goal:** People become hungry before they understand the game.

Every screenshot communicates ONE idea. Nothing shown may advertise functionality that does not exist in the shipping version of Forkensics.

---

## Design Language

- Black background
- White typography
- Orange accent (~#FF7A00)
- Inter throughout the interface
- League Spartan for logo/headlines if appropriate
- Premium food photography
- Minimal interface
- Apple-inspired spacing
- Rounded cards
- Large typography
- No gradients
- No unnecessary decoration
- High contrast
- Plenty of breathing room

**The food is always the hero. The UI supports the story.**

---

## General Principles

- Every screenshot teaches ONE idea
- Do not combine multiple features into one screenshot
- Never use tiny text
- Never clutter the layout
- Screenshots should feel like premium advertisements, not software documentation
- The released interface must remain visible and authentic

---

## Screenshot Specs

### Screenshot 1 — NAME THIS DISH.

**Purpose:** Teach the player the first half of the game.

**Show:**
- Beautiful hero food photograph
- Actual dish guessing interface
- Remaining challenge timer
- Optional Get a Clue
- Authentic UI

**Do NOT show:**
- Restaurant
- Answer
- Unsupported point totals
- Round systems that do not exist
- Settings, menus, navigation

**Bottom Card Example:**
```
Name the Dish
□ □ □ □ □ □ □ □
Get a Clue
Challenge Time Remaining
```

---

### Screenshot 2 — NOW NAIL THE PLACE.

**Highlight:** PLACE or RESTAURANT in orange.

**Purpose:** Teach the second half of Forkensics.

**Show:**
- Restaurant field
- City field
- SUBMIT GUESS (preferred) or LOCK IN GUESS
- Get a Clue
- If city has already been revealed, label it clearly as a Clue: Austin, Texas

**Never** display a clue as though the player already entered it.

---

### Screenshot 3 — FIRST CORRECT SCORES MOST.

**Purpose:** Teach competition.

**Show:**
- Authentic Forkensics scoring
- What? race results
- Where? race results
- Overall standings

**Do NOT** fabricate point totals. Represent the real scoring model.

---

### Screenshot 4 — SERVE UP A MYSTERY.

**Purpose:** Show posting.

**Show (authentic posting flow):**
- Take/select photo
- Dish
- Restaurant
- City
- Challenge duration
- Optional freeform clue

No fictional settings. No future functionality.

---

### Screenshot 5 — SHARE THE REVEAL.

**Purpose:** Celebrate the solution.

**Show:**
- Dish
- Restaurant
- City
- Poster story
- Comments
- Reactions

Communicate the emotional payoff.

**Do NOT** imply maps, discovery engines, recommendation systems, saved restaurants, or features that do not exist.

---

### Screenshot 6 — OWN THE LEADERBOARD.

**Purpose:** Long-term replay.

**Show:**
- Group leaderboard
- What? points
- Where? points
- Total points
- Clean rankings
- Authentic data

---

## Confirmed Product Decisions (from this PB)

### Hints → Clues (rename throughout)
"Hints" renamed to "Clues" everywhere in the app and schema.
- Get a Clue
- Reveal a Clue
- 1 Clue Available
- `hints` table to be renamed `clues` before SQL generation

### Letter Count (optional clue)
Letter count does NOT automatically appear. It is an optional clue the poster can supply (as freeform text, e.g. "7-letter dish"). No structured field required in v1.

### Button Language
**Preferred:** SUBMIT GUESS (matches immutable-append model, allows multiple submissions)
**Alternative:** LOCK IN GUESS — only if game mechanics explicitly support it

### Posting — Required Fields
- Photo
- Dish
- Restaurant
- City
- Duration

### Posting — Optional
- Freeform clue (e.g. "Family-owned.", "Known for brunch.", "Featured on TV.")

No structured clue system in v1.

---

## Open Questions (requires decision before screenshots are produced)

### Q1 — City visibility ✅ RESOLVED
**Decision:** Poster choice. When creating a challenge, the poster selects whether city is hidden (players must guess restaurant AND city) or revealed (city is shown; players guess restaurant only).

**Schema impact:**
- `challenges` needs a `city_revealed boolean NOT NULL DEFAULT false` field
- Guess UI shows/hides city field based on this flag
- Where? matching logic: if `city_revealed = true`, only restaurant must match; city is pre-shown
- Scoring: effective Where? difficulty differs but point formula unchanged

### Q2 — Round system
The mockup image shows "ROUND 2 OF 5" — this does not exist in our v1 design. Challenges are standalone, not grouped into rounds.
**Decision:** Remove all round indicators from production artwork. Confirmed not v1.

---

## Deferred to Future Product Cycle (NOT v1, NOT in screenshots)

- Difficulty presets (Casual / Tricky / Expert)
- Automatic clue timing
- Reveal one letter every X seconds
- First-letter reveal
- Cuisine clue
- Price range clue
- Neighborhood clue
- Narrow restaurant list
- Progressive clue engine

The clue system should remain architecturally extensible for these future mechanics.

---

## What NOT to Show (App Store screenshots)

- Settings
- Notifications
- Profile
- Navigation / menus
- Developer UI
- Debug information
- Placeholder values
- Fake statistics
- Unsupported gameplay
- Future roadmap features

---

## Production Requirements

- Original, commissioned, AI-generated (with rights), or properly licensed food photography
- Fictional player names
- Authentic Forkensics interface
- 6.9-inch master artwork (1320 × 2868 preferred)
- PNG or JPEG
- No transparency
- Large readable typography
- One message per screenshot
- Verify final dimensions in App Store Connect before export

---

## Apple Compliance

App Store screenshots must represent the authentic shipping application. Marketing overlays are acceptable. Do not advertise functionality that is unavailable.

---

## Golden Rule

Nothing shown in an App Store screenshot should promise functionality that does not exist in the shipping version of Forkensics. Marketing should elevate the experience. It should never invent it.
