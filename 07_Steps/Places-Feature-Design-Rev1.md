# Places & Public Cases — Feature Design Rev 1

**Status:** DRAFT — for external review  
**Date:** 2026-08-17  
**Author:** Bill + Claude  
**Purpose:** Define the Places directory, public case visibility, and restaurant claiming features for Forkensics. Submitted for GPT review prior to three-party approval.

---

## 1. Summary

Forkensics today is private-by-default: cases are posted within a friend group, and visibility is bounded by group membership. This proposal adds:

1. **Public cases** — any user can post a case that is visible to the whole app, not just their group.
2. **Places** — a lightweight directory of named venues (restaurants, bars, food trucks, etc.) that cases can be tagged to. The directory is built organically, not pre-seeded.
3. **Restaurant claiming** — a verified business can claim its listing in the Places directory and post cases under its own brand, visible to anyone following or viewing that place.

---

## 2. Motivation

The current model is great for friend groups playing privately. But there are adjacent use cases that generate value without changing the core game:

- A local restaurant wants to post a photo of tonight's special and let customers guess what dish it is.
- A user eats at a new spot, posts a case publicly, and tags the restaurant — the restaurant gets organic discovery.
- A food blogger runs a recurring public challenge from different venues.

The pattern is social + local, similar to Instagram Reels + Yelp listings, but wrapped in the Forkensics guess-the-dish mechanic. None of this requires Forkensics to run contests or moderate prize payouts — the platform provides the mechanics; the poster does whatever they want with it.

---

## 3. Scope

### 3.1 In scope (Rev 1)

- `visibility` flag on cases: `private` (current, group-scoped) vs. `public` (app-wide).
- Any authenticated user may post a case as public.
- `places` table: one record per real-world venue.
- Cases may optionally tag a place via a nullable FK.
- Places are created at post time via Google Places Autocomplete — not pre-seeded.
- Business claiming: a verified business account can claim ownership of a place record.
- Claimed places have a profile (name, description, avatar, location).
- Claimed-place cases are visible to all users browsing that place's page.

### 3.2 Out of scope (Rev 1)

- Forkensics-operated contests or prizing (we are the platform, not the contest operator).
- Paid promotion or boosted placement.
- Non-food places (parks, homes, etc.) — the UX may allow it, but launch focus is food venues.
- Batch-import or pre-seeding from any external directory (see §6 for rationale).
- Business payments, subscriptions, or verification fees (TBD separately).
- Follower/feed mechanics beyond viewing a place's public cases.

---

## 4. Data Model

### 4.1 New table: `places`

```sql
CREATE TABLE places (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  external_id     text NOT NULL,           -- Google Places place_id (e.g. "ChIJ...")
  external_source text NOT NULL DEFAULT 'google_places',
  name            text NOT NULL,
  address         text,
  lat             double precision,
  lng             double precision,
  claimed         boolean NOT NULL DEFAULT false,
  claimed_by      uuid REFERENCES profiles(id),
  claimed_at      timestamptz,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX places_external_id_source_idx ON places (external_id, external_source);
```

**Key design decisions:**

- `external_id` is the Google `place_id` string. Storing it enables deduplication across sessions — if two users select the same restaurant, the second upsert matches on `(external_id, external_source)` and returns the existing row rather than creating a duplicate.
- `lat`/`lng` are stored at creation time from the Autocomplete result. We do not re-query Google on every page view.
- `claimed_by` is a FK to `profiles`, not `auth.users`, consistent with the rest of the schema.
- `claimed` is a denormalized boolean for fast RLS filtering. Updated by the claiming flow; not updated directly by clients.

### 4.2 Schema change: `cases`

Add two columns to the `cases` table:

```sql
ALTER TABLE cases
  ADD COLUMN visibility text NOT NULL DEFAULT 'private'
    CHECK (visibility IN ('private', 'public')),
  ADD COLUMN place_id uuid REFERENCES places(id);
```

`place_id` is nullable — most private cases will not have a place. `visibility = 'public'` does not require a `place_id`; a user can post publicly without tagging a restaurant.

### 4.3 Indexes

```sql
-- Fast lookup for public feed
CREATE INDEX cases_public_idx ON cases (created_at DESC)
  WHERE visibility = 'public';

-- Fast lookup for a place's cases  
CREATE INDEX cases_place_id_idx ON cases (place_id, created_at DESC)
  WHERE place_id IS NOT NULL;
```

### 4.4 RLS implications

Current RLS on `cases` gates all reads on group membership. With this change:

- `visibility = 'private'` → existing group-membership RLS unchanged.
- `visibility = 'public'` → any authenticated user may read the case. The policy adds an OR branch: `visibility = 'public'`.

Example policy sketch (not final SQL):

```sql
-- SELECT policy on cases
USING (
  -- existing: member of the case's group
  EXISTS (
    SELECT 1 FROM group_members
    WHERE group_members.group_id = cases.group_id
      AND group_members.user_id = auth.uid()
  )
  OR
  -- new: public cases are readable by any authenticated user
  visibility = 'public'
)
```

No change to INSERT/UPDATE/DELETE policies — ownership rules remain.

---

## 5. User Flows

### 5.1 Posting a public case (any user)

1. User composes a case as usual (photo, dish name, clue text).
2. Before posting, the user can toggle **Public** (default: matches group setting, likely private).
3. If public, an optional **Tag a Place** field appears.
4. User types a partial name → Autocomplete results from Google Places API appear in a picker.
5. User selects a result (or skips tagging entirely).
6. On selection, the app calls `POST /places/lookup` (Edge Function or client-side Supabase upsert) with the Google `place_id`. The function:
   a. Checks `places` for a row with matching `(external_id, 'google_places')`.
   b. If found, returns the existing `places.id`.
   c. If not found, inserts a new row from the Autocomplete metadata (name, address, lat/lng) and returns the new `id`.
7. App attaches the returned `place_id` to the case payload alongside `visibility = 'public'`.
8. Case is posted. Existing upload-authorize / upload-complete flow unchanged — visibility and place are metadata columns only.

### 5.2 Browsing public cases

- A **Discover** or **Public** tab shows cases where `visibility = 'public'`, ordered by `created_at DESC` (with later pagination/ranking TBD).
- Filtering by place is available: tap a restaurant's name → view all public cases tagged to it.
- Private cases are never surfaced here, regardless of group membership.

### 5.3 Restaurant claiming flow

**Precondition:** the place record already exists in the `places` table (created organically by a user post, or seeded by the restaurant operator posting their first case themselves).

1. A business operator taps **Claim This Place** on a place's public page.
2. Operator is prompted to provide verification context (TBD: email domain match, Google Business Profile link, manual review queue). This is an ops/moderation flow; the exact mechanism is deferred.
3. On approval (manual or automated), `places.claimed = true`, `places.claimed_by = operator_profile_id`, `places.claimed_at = now()`.
4. The operator can now:
   - Edit the place's display name, description, and avatar image.
   - Post cases that appear as authored by the place, not their personal profile (display name shows restaurant name).
   - See aggregate stats on their place page (total public cases tagged, guess counts, etc.).
5. Unclaimed places continue to work as before — any user can tag them.

### 5.4 What claiming does NOT do

- Claiming does not remove or hide existing cases posted by other users to that place.
- Claiming does not grant moderation authority over other users' content tagged to the place.
- Claiming does not prevent other users from continuing to post to the place.
- Forkensics retains full moderation authority over all content.

---

## 6. Why Not Batch-Seed from Google Places

**The question:** why not pre-populate `places` from the Google Places API so the directory is full on day one?

**Answer: it violates Google's Terms of Service.**

The Google Places API Terms of Service explicitly prohibit:
- Pre-fetching, caching, or storing Places data beyond the short-term caching window (generally 30 days for limited fields, with strict conditions).
- Building or updating a database using Places data without ongoing user-initiated queries.
- Storing place IDs in bulk for later use without active user interaction at query time.

Batch seeding means downloading large numbers of place records for storage and later retrieval without a live user query tied to each one. This is explicitly prohibited.

**The compliant pattern** is what this proposal uses: a live user types in a field, the Autocomplete API is called in real time for that user's session, and only the result the user selects is stored. The stored record is a small subset of the Places data (place_id, name, address, lat/lng) tied to an active user action.

**Cost analysis of the compliant approach:**

| Metric | Value |
|---|---|
| Google Places Autocomplete API price | ~$0.003/session |
| Free monthly credits | ~$200 (≈ 66,000 sessions/month) |
| Expected early-stage volume | low thousands/month |
| Break-even concern | Not until scale |

For comparison: pre-seeding even a city's worth of restaurant data (say, 50,000 places) would cost ~$150 in API calls and produce a ToS violation. The organic approach costs essentially nothing at early scale, produces a more relevant dataset (only places people actually visit), and is fully compliant.

**Duplicate prevention** is handled by the `UNIQUE INDEX` on `(external_id, external_source)`. Two users posting from the same restaurant produce one `places` row, not two.

---

## 7. Implications for Existing Schema (V1–V4)

The existing migrations are frozen at V4 (`v0.4.0-case-investigation-schema`). The Places feature requires new migrations. These are not yet numbered or written — this is a design doc, not an implementation plan.

Anticipated migration structure:

- **V5 or later:** Create `places` table, add `visibility` and `place_id` to `cases`, add indexes, update RLS policies.
- No V1–V4 migration files are modified. All changes are additive.

The `upload-authorize` Edge Function (current active implementation target) is unaffected. Upload sessions deal with media objects; `place_id` and `visibility` are set at the case-posting layer (a later Edge Function, likely `case-create` or equivalent).

---

## 8. Google Places API Integration Notes

- SDK: `@googlemaps/google-maps-services-js` on the backend, or native `GMSPlacesClient` on iOS.
- The Autocomplete call happens client-side or via a thin Edge Function proxy. The API key must not be embedded in client code (proxy preferred).
- Fields requested from Autocomplete: `place_id`, `name`, `formatted_address`, `geometry.location`.
- No additional Place Details call needed if Autocomplete returns geometry — avoid the extra API call.
- The stored `external_id` (`place_id`) can support future enrichment (hours, photos from business) without re-querying for the canonical ID.

---

## 9. Open Questions for Review

1. **Visibility default:** Should new cases default to `private` (safest, opt-in public) or match a per-user preference? Recommendation: default `private`, let users opt in.

2. **Public feed moderation:** Public cases are app-wide. What is the reporting/removal flow for a public case that violates community guidelines? This is not addressed in Rev 1 — it needs a moderation plan before the public feed goes live.

3. **Place name conflicts:** Two Autocomplete sessions for slightly different spellings of the same restaurant will produce the same Google `place_id` and correctly deduplicate. But if Google ever deprecates a `place_id` and replaces it with a new one, how do we handle the stale FK? Recommendation: periodic re-validation job, but this is future scope.

4. **Claiming verification mechanism:** The proposed flow defers verification method to an ops decision. Options: (a) email domain match against a Google Business Profile, (b) a manual review queue, (c) a verification code posted to the Google Business Profile. This must be decided before building the claiming flow.

5. **Claimed place posts — author identity:** When a claimed restaurant posts a case, does it show "Posted by [Restaurant Name]" or "Posted by [Operator's personal profile]"? Recommendation: show restaurant name, hide personal identity, to match the brand-vs-individual pattern on Instagram/Facebook Pages.

6. **Public cases and group context:** A case can be both public and in a group (a group member posts publicly). Should group members see it in the group feed AND the public feed? Or only in the public feed when visibility = public? Recommendation: both feeds, since group membership is additive context.

7. **Anonymous browsing:** Should public cases be viewable without signing in? The current architecture requires authentication for all Supabase access. Allowing unauthenticated reads is an architecture change. Recommendation: authenticated only for now; reconsider if growth requires it.

8. **Migration numbering:** Is V5 reserved for R2 storage paths (Amendment D)? If so, Places migrations may start at V6. This must be confirmed against the active migration plan before writing the SQL.

---

## 10. What Does Not Change

- The core Forkensics game mechanic (post photo, group guesses, reveal).
- Private cases and group-scoped visibility — default behavior is unchanged.
- The media pipeline (EXIF stripping, R2 storage, server re-encoding) — applies equally to public and private cases.
- The upload-authorize Edge Function and Amendment D work — this feature does not touch that layer.
- Sign in with Apple authentication — required for all users including business operators.
- Three-party governance: any schema migration or new Edge Function requires Bill + Claude + Codex approval before implementation.

---

## 11. Review Checklist (for GPT reviewer)

- [ ] Does the `places` data model support the claiming flow without ambiguity?
- [ ] Is the RLS policy sketch correct — does the OR branch on `visibility = 'public'` interact safely with existing group-membership policies?
- [ ] Is there a missing index (e.g., for browsing all claimed places, or all cases by a claimed place owner)?
- [ ] Does storing `lat`/`lng` from Autocomplete (rather than a subsequent Place Details call) create any accuracy or data freshness risk?
- [ ] Are there any GDPR or privacy implications from storing Google `place_id` values tied to user-posted cases?
- [ ] Is the `claimed_by` FK to `profiles` the right join target, or should it point to a separate `business_accounts` table to avoid mixing personal and business identity?
- [ ] Does the "any user can post public" model create any content liability issue that requires the moderation plan to be defined before launch, not after?
- [ ] Is there a race condition in the upsert logic for `places` (two users simultaneously posting to the same venue for the first time)?
