# Places & Public Cases — Feature Design Rev 2

**Status:** DRAFT — for external review  
**Date:** 2026-08-17  
**Author:** Bill + Claude  
**Supersedes:** Places-Feature-Design-Rev1.md  
**Rev 2 changes from Rev 1:** Primary directory source changed from Google Places Autocomplete to OpenStreetMap regional extract seeding. Data model expanded to ODbL-compliant layered architecture. Autocomplete source changed to self-hosted or OSM-commercial provider. Refresh/merge and ODbL compliance sections added. Google Places retained as an optional, separately-reviewed integration path only.

---

## 1. Summary

Forkensics today is private-by-default: cases are posted within a friend group, and visibility is bounded by group membership. This proposal adds:

1. **Public cases** — any user can post a case visible to the whole app, not just their group.
2. **Places** — a lightweight directory of named venues (restaurants, bars, food trucks, etc.) that cases can be tagged to. The directory is seeded from OpenStreetMap regional extracts and supplemented by restaurant and user contributions.
3. **Restaurant claiming** — a verified business can claim its listing, post cases under its brand, and correct or complete its record.

---

## 2. Motivation

The current model is great for friend groups playing privately. But there are adjacent use cases that generate value without changing the core game:

- A local restaurant posts a photo of tonight's special and lets customers guess the dish.
- A user eats at a new spot, posts a case publicly, and tags the restaurant — the restaurant gets organic discovery.
- A food blogger runs a recurring public challenge from different venues.

The pattern is social + local. None of this requires Forkensics to run contests or moderate prize payouts — the platform provides the mechanics; the poster does whatever they want with it.

Seeding the directory from OpenStreetMap regional extracts (rather than live API calls) means Forkensics can launch in a metro area with reasonable coverage from day one, without paying per-query costs, and without violating any API terms by pre-fetching.

---

## 3. Scope

### 3.1 In scope (Rev 2)

- `visibility` flag on cases: `private` (current, group-scoped) vs. `public` (app-wide).
- Any authenticated user may post a case as public.
- ODbL-compliant layered data model: `osm_place_sources`, `places`, `place_source_refs`, `place_profiles`, `place_claims`, `place_operators`.
- OSM regional extract import for food-related POIs in selected metro areas.
- Self-hosted or OSM-based commercial autocomplete for in-app search.
- Restaurant claiming flow.
- OSM refresh and merge process.
- Required ODbL attribution in all public-facing views.

### 3.2 Out of scope (Rev 2)

- Systematic Nominatim API queries to enumerate POIs (prohibited by Nominatim usage policy).
- Bulk download of OpenStreetMap public map tiles (prohibited by tile server policy).
- Google Places Autocomplete as the primary directory source (demoted to optional, separately reviewed).
- Forkensics-operated contests or prizing.
- Paid promotion or boosted placement.
- Non-food places at launch (parks, homes, etc.) — OSM filter targets `amenity=restaurant`, `amenity=cafe`, `amenity=fast_food`, `amenity=bar`, `amenity=pub`, `shop=bakery`, `amenity=food_court`, and similar food-related tags.
- Business payments, subscriptions, or verification fees (TBD separately).

---

## 4. Data Model

The ODbL requires that OSM-derived data be kept logically separable from proprietary data so that Forkensics can fulfill share-alike obligations on the OSM-derived layer without inadvertently exposing proprietary content. The six-table architecture below achieves this.

### 4.1 `osm_place_sources` — ODbL-derived source records

Stores the raw OSM record as imported. This table and its contents are ODbL-licensed. It must be kept logically separate from all proprietary content and must be includable in any share-alike disclosure.

```sql
CREATE TABLE osm_place_sources (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  osm_type        text NOT NULL CHECK (osm_type IN ('node', 'way', 'relation')),
  osm_id          bigint NOT NULL,
  osm_version     integer,
  osm_tags        jsonb NOT NULL DEFAULT '{}',
  -- Derived convenience columns from osm_tags (informational, not authoritative)
  name            text GENERATED ALWAYS AS (osm_tags->>'name') STORED,
  amenity         text GENERATED ALWAYS AS (osm_tags->>'amenity') STORED,
  lat             double precision,
  lng             double precision,
  import_source   text NOT NULL,              -- e.g. 'osm-extract/us-northeast-2026-08'
  imported_at     timestamptz NOT NULL DEFAULT now(),
  last_refreshed  timestamptz,
  osm_deleted     boolean NOT NULL DEFAULT false,
  osm_deleted_at  timestamptz,
  created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX osm_place_sources_type_id_idx ON osm_place_sources (osm_type, osm_id);
CREATE INDEX osm_place_sources_name_idx ON osm_place_sources (name);
CREATE INDEX osm_place_sources_location_idx ON osm_place_sources USING GIST (
  ST_MakePoint(lng, lat)  -- requires PostGIS
);
```

**Notes:**
- `osm_type` + `osm_id` is the canonical OSM reference. This pair is never used as a public identifier.
- `osm_version` records the OSM object version at import time to detect changes on refresh.
- `osm_tags` stores the full OSM tag set as JSONB for completeness. Generated columns extract common fields.
- `import_source` identifies which regional extract produced this row (e.g., `osm-extract/us-northeast-2026-08`), enabling provenance tracking for ODbL compliance.

### 4.2 `places` — stable Forkensics venue identities

The stable, Forkensics-owned identifier layer. UUIDs and slugs here are permanent and do not change even if the underlying OSM record is updated, merged, or corrected. This is the table used in all public URLs and QR codes.

```sql
CREATE TABLE places (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  slug            text NOT NULL UNIQUE,          -- e.g. 'mikes-pizza-brooklyn'
  canonical_name  text NOT NULL,                  -- display name (may differ from OSM)
  place_type      text NOT NULL DEFAULT 'restaurant'
                  CHECK (place_type IN ('restaurant','cafe','bar','food_truck','bakery','other')),
  lat             double precision,
  lng             double precision,
  address         text,
  city            text,
  country         text NOT NULL DEFAULT 'US',
  status          text NOT NULL DEFAULT 'active'
                  CHECK (status IN ('active','merged','closed','duplicate')),
  merged_into     uuid REFERENCES places(id),    -- set when status = 'merged' or 'duplicate'
  redirect_slug   text,                           -- old slug → new slug after rename/merge
  claimed         boolean NOT NULL DEFAULT false,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX places_city_idx ON places (city, status);
CREATE INDEX places_location_idx ON places USING GIST (ST_MakePoint(lng, lat));
```

**Notes:**
- `slug` is the public URL component: `forkensics.com/places/mikes-pizza-brooklyn`. It is stable; when a restaurant is renamed, the old slug is retained in `redirect_slug` and the `places` row gets a new slug to avoid broken links.
- `canonical_name` is set from OSM `name` at import but may be overridden by restaurant operators.
- `merged_into` handles the case where two OSM records turn out to be the same real-world venue.

### 4.3 `place_source_refs` — links places to OSM objects

The bridge between the ODbL layer and the Forkensics identity layer. A place may be linked to more than one OSM object (e.g., two OSM records that represent the same venue).

```sql
CREATE TABLE place_source_refs (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  place_id          uuid NOT NULL REFERENCES places(id),
  osm_source_id     uuid NOT NULL REFERENCES osm_place_sources(id),
  is_primary        boolean NOT NULL DEFAULT true,
  linked_at         timestamptz NOT NULL DEFAULT now(),
  linked_by         text NOT NULL DEFAULT 'osm-import',  -- 'osm-import' | 'manual' | 'merge'
  UNIQUE (place_id, osm_source_id)
);

CREATE INDEX place_source_refs_place_idx ON place_source_refs (place_id);
CREATE INDEX place_source_refs_osm_idx ON place_source_refs (osm_source_id);
```

### 4.4 `place_profiles` — restaurant/user-supplied content

Proprietary layer: descriptions, photos, hours, and display metadata supplied by restaurant operators or Forkensics staff. This table is entirely proprietary. It must not be included in any ODbL share-alike disclosure.

```sql
CREATE TABLE place_profiles (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  place_id        uuid NOT NULL UNIQUE REFERENCES places(id),
  display_name    text,          -- operator-verified name; overrides canonical_name in UI
  description     text,
  website         text,
  phone           text,
  avatar_media_id uuid,          -- FK to media table (R2-backed, private bucket)
  hours_json      jsonb,
  tags            text[],        -- operator-supplied cuisine/vibe tags
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);
```

### 4.5 `place_claims` — claim applications and verification history

Tracks the full lifecycle of a restaurant claiming its listing: application, verification, approval, and revocation.

```sql
CREATE TABLE place_claims (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  place_id        uuid NOT NULL REFERENCES places(id),
  applicant_id    uuid NOT NULL REFERENCES profiles(id),
  status          text NOT NULL DEFAULT 'pending'
                  CHECK (status IN ('pending','approved','rejected','revoked')),
  verification_method text,       -- e.g. 'email-domain', 'manual-review', 'google-biz-code'
  verification_notes  text,
  applied_at      timestamptz NOT NULL DEFAULT now(),
  resolved_at     timestamptz,
  resolved_by     uuid REFERENCES profiles(id)
);

CREATE INDEX place_claims_place_idx ON place_claims (place_id, status);
```

### 4.6 `place_operators` — authorized restaurant personnel and roles

Once a claim is approved, multiple staff members can be granted access under different roles.

```sql
CREATE TABLE place_operators (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  place_id        uuid NOT NULL REFERENCES places(id),
  profile_id      uuid NOT NULL REFERENCES profiles(id),
  role            text NOT NULL DEFAULT 'staff'
                  CHECK (role IN ('owner','manager','staff')),
  granted_by      uuid REFERENCES profiles(id),
  granted_at      timestamptz NOT NULL DEFAULT now(),
  revoked_at      timestamptz,
  UNIQUE (place_id, profile_id)
);
```

### 4.7 Schema change: `cases`

```sql
ALTER TABLE cases
  ADD COLUMN visibility text NOT NULL DEFAULT 'private'
    CHECK (visibility IN ('private', 'public')),
  ADD COLUMN place_id uuid REFERENCES places(id);
```

`place_id` is nullable. `visibility = 'public'` does not require `place_id`.

### 4.8 Indexes on `cases`

```sql
CREATE INDEX cases_public_idx ON cases (created_at DESC) WHERE visibility = 'public';
CREATE INDEX cases_place_id_idx ON cases (place_id, created_at DESC) WHERE place_id IS NOT NULL;
```

### 4.9 RLS on `cases`

```sql
-- SELECT: existing group-membership check OR public visibility
USING (
  EXISTS (
    SELECT 1 FROM group_members
    WHERE group_members.group_id = cases.group_id
      AND group_members.user_id = auth.uid()
  )
  OR visibility = 'public'
)
```

---

## 5. OSM Import Pipeline

### 5.1 Regional extract source

Import from downloaded `.osm.pbf` regional extracts from Geofabrik (https://download.geofabrik.de/) or similar ODbL-compliant extract providers. Each extract is a snapshot of OSM data for a geographic region (e.g., US Northeast, California).

Do NOT systematically query the public Nominatim API to enumerate POIs. The Nominatim usage policy explicitly prohibits this. Do NOT bulk-download OSM public map tiles.

### 5.2 POI filter

Extract features tagged with any of:

| OSM tag | English meaning |
|---------|----------------|
| `amenity=restaurant` | Restaurant |
| `amenity=cafe` | Café |
| `amenity=fast_food` | Fast food |
| `amenity=bar` | Bar |
| `amenity=pub` | Pub |
| `amenity=food_court` | Food court |
| `shop=bakery` | Bakery |
| `amenity=ice_cream` | Ice cream shop |

Filter out features with `opening_hours=closed` or `disused:amenity` tags at import time.

### 5.3 Import process (per metro area)

1. Download regional `.osm.pbf` extract.
2. Run `osmium tags-filter` (or equivalent) to extract food-tagged features.
3. For each feature: insert a row into `osm_place_sources` with `osm_type`, `osm_id`, `osm_version`, full `osm_tags` JSONB, lat/lng (centroid for ways/relations), `import_source`, and `imported_at`.
4. Deduplicate against existing `osm_place_sources` rows by `(osm_type, osm_id)`. If a matching row exists and `osm_version` is higher, update and record `last_refreshed`.
5. For new rows (no existing `places` match): create a `places` row with auto-generated `slug` (from OSM name + city), link via `place_source_refs`.
6. For updated rows: update `osm_place_sources`; DO NOT overwrite `place_profiles` or `places.canonical_name` if either has been operator-verified.
7. Record import run metadata (extract filename, feature count, timestamp) for compliance provenance.

### 5.4 Slug generation

```
slug = slugify(osm_name) + '-' + slugify(city)
# e.g. "mikes-pizza" + "brooklyn" → "mikes-pizza-brooklyn"
# On collision: append 2-char hex suffix until unique
```

Slugs are Forkensics-owned identifiers. They are not derived from OSM IDs and are not subject to ODbL.

---

## 6. Autocomplete (In-App Search)

Autocomplete for the "Tag a Place" field in the posting flow must NOT use the public Nominatim service (prohibited for client-side autocomplete and systematic queries). Options:

**Option A — Self-hosted Photon (recommended for launch):**  
[Photon](https://github.com/komoot/photon) is an open-source geocoder built on OSM data, designed for autocomplete. It can be run on a single server. Search is against the local `places` table (augmented with PostGIS), not an external API. Latency: <50 ms for simple prefix queries.

**Option B — Commercial OSM-based provider:**  
Providers such as Stadia Maps, Maptiler, or Geoapify offer OSM-based geocoding APIs with autocomplete endpoints and permissive commercial terms. Cost is typically per-request but low volume at early scale. These providers' terms generally permit caching of results for short periods; verify before use.

**Option C — Google Places Autocomplete (optional, separately reviewed):**  
Google Places Autocomplete could be added as a fallback or for richer place data. Because the primary directory is OSM-seeded, Google would only be queried for places NOT already in the Forkensics `places` table. Before enabling this path, a separate proposal covering Google ToS compliance, pricing, and data handling must be approved by all three parties. Google Places is NOT part of the current approved design.

In-app search flow:
1. User types a partial name in the "Tag a Place" field.
2. App queries `places` table (via Edge Function) with prefix match on `canonical_name`, filtered by city/region. PostGIS proximity ranking if user location is available.
3. Results display `canonical_name` and `address` from `places` + `place_profiles`.
4. If no match found, user can flag "my venue isn't listed" — this opens a manual submission form (creates a `places` record without an OSM source, linked to the submitting user's profile).

---

## 7. User Flows

### 7.1 Posting a public case

1. User composes a case (photo, dish name, clue text).
2. User toggles **Public** (default: private).
3. Optional **Tag a Place** field appears. User types a partial name; results come from the self-hosted autocomplete against the Forkensics `places` table.
4. User selects a result. `place_id` is attached to the case payload.
5. If the venue isn't found: user can skip, or tap **Add missing venue** → minimal form (name, city) creates a new `places` row without an OSM source.
6. Case is posted. Upload-authorize / upload-complete flow unchanged.

### 7.2 Place page

A place's public page shows:
- `canonical_name` (from `places`) or `display_name` (from `place_profiles`, if set by operator).
- Address, city.
- OSM attribution: **"© OpenStreetMap contributors"** with link to `https://www.openstreetmap.org/copyright`. Required on any view that displays OSM-derived data.
- All public cases tagged to this place, sorted by `created_at DESC`.
- Claim status badge (unclaimed / verified).

### 7.3 Restaurant claiming flow

1. A business operator taps **Claim This Place** on the place page.
2. Operator submits a `place_claims` application with verification context (email domain, Google Business Profile URL, etc.).
3. Forkensics staff reviews and updates `place_claims.status` to `approved`.
4. On approval: `places.claimed = true`; an `place_operators` row is created with `role = 'owner'`.
5. Operator can now edit `place_profiles` (name, description, avatar, hours) and post cases attributed to the place.
6. Operators can grant additional staff members via `place_operators`.

### 7.4 What claiming does NOT do

- Does not remove or hide cases by other users.
- Does not grant moderation authority over other users' content.
- Does not overwrite OSM-derived data in `osm_place_sources` — operators edit `place_profiles`, not the OSM layer.

---

## 8. OSM Refresh and Merge

### 8.1 Periodic refresh

Frequency: quarterly or when Geofabrik publishes a new extract for a seeded metro area.

Refresh process:
1. Download new extract. Run the same POI filter as §5.2.
2. For each OSM feature in the new extract, look up by `(osm_type, osm_id)` in `osm_place_sources`.
3. **Not found:** new POI — insert into `osm_place_sources`; create a new `places` row; link via `place_source_refs`.
4. **Found, same version:** no change needed.
5. **Found, higher version:** update `osm_place_sources` (name, tags, lat/lng, `osm_version`, `last_refreshed`). Propagate name/location to `places.canonical_name` and `places.lat/lng` ONLY IF `place_profiles.display_name` is NULL (i.e., operator has not overridden). Log the potential change for staff review if `display_name` IS set.
6. **Present in old import, absent in new extract:** set `osm_place_sources.osm_deleted = true`, `osm_deleted_at = now()`. Do NOT delete the `places` row. Flag for staff review: the venue may have closed, been renamed, or be a data quality issue.

### 8.2 Closure and deletion handling

When OSM marks a venue as deleted or adds `disused:amenity`:
- Set `osm_place_sources.osm_deleted = true`.
- Create a staff review task.
- If confirmed closed: set `places.status = 'closed'`. The place page remains accessible (cases still exist) but displays a "This venue may be permanently closed" notice.
- Never automatically delete a `places` row. Cases and community data are preserved.

### 8.3 Merge aliases and redirects

When two `places` rows are found to represent the same real-world venue (duplicate OSM records, or a user-created record that duplicates an OSM-imported one):
1. Choose the canonical `places` row to keep.
2. Set the duplicate's `places.status = 'duplicate'`, `places.merged_into = <canonical_id>`.
3. Set `places.redirect_slug` on the duplicate to the canonical slug.
4. Move all `cases.place_id` references from the duplicate to the canonical row (or leave in place and resolve at query time via the merge chain).
5. The duplicate's `place_source_refs` entries are moved to the canonical row with `is_primary = false`.
6. HTTP 301 redirects are issued from the duplicate's public URL to the canonical URL.

### 8.4 Restaurant-verified content is never overwritten

OSM refresh MUST NOT overwrite:
- `place_profiles.display_name` if set.
- `place_profiles.description`, `phone`, `website`, `hours_json`, `avatar_media_id`.
- `places.slug` (permanent).
- Any `place_operators` or `place_claims` data.

Changes to OSM source fields during refresh are recorded in `osm_place_sources` and optionally surfaced to operators as "OSM data has changed for your listing — would you like to review?"

---

## 9. ODbL Compliance

### 9.1 What ODbL requires

The OpenStreetMap database is licensed under the Open Database License (ODbL 1.0). Key obligations:

- **Attribution:** Display "© OpenStreetMap contributors" with a link to `https://www.openstreetmap.org/copyright` on every public-facing surface that shows OSM-derived data.
- **Share-alike:** If Forkensics creates a **Produced Work** (e.g., a rendered map or a derived database distributed publicly), that work must also be made available under ODbL terms, OR Forkensics must provide the means to recreate the derived database.
- **Keep-open:** Forkensics may not add technological or contractual restrictions that prevent others from exercising ODbL rights on the OSM-derived subset.

### 9.2 How the layered schema satisfies share-alike

The schema achieves clean separation so that Forkensics can fulfill share-alike on the OSM-derived subset without disclosing proprietary content:

| Table | Layer | ODbL-covered? |
|-------|-------|---------------|
| `osm_place_sources` | ODbL source | Yes — must be shareable |
| `place_source_refs` | Bridge (structure only) | Yes — structural linkage, no proprietary content |
| `places` | Forkensics identity (UUIDs, slugs) | No — Forkensics-generated identifiers |
| `place_profiles` | Proprietary content | No — operator/user-supplied |
| `place_claims` | Proprietary business data | No — operator identity, verification notes |
| `place_operators` | Proprietary business data | No — operator identity and roles |

A share-alike disclosure would include: `osm_place_sources` (all fields) and `place_source_refs` (place_id is a Forkensics UUID, not personally identifying). It would exclude all other tables.

### 9.3 Attribution implementation

Every public-facing view that renders OSM-derived data must include:

```
© OpenStreetMap contributors
```

Linked to: `https://www.openstreetmap.org/copyright`

This includes: place pages, the public case feed when a place is shown, search results from the OSM-seeded autocomplete, and any map view showing OSM-derived venue locations.

It does NOT need to appear in contexts where no OSM-derived data is displayed (e.g., a private case with no place tag).

### 9.4 Legal review gate

The ODbL share-alike obligation's exact scope — specifically whether Forkensics' derived `places` table constitutes a "Produced Work" or "Derivative Database" under ODbL — requires legal review before implementation. The layered architecture is designed to make that review tractable by isolating OSM-derived data cleanly. **No OSM import should run in production until legal review confirms the architecture satisfies ODbL obligations.**

---

## 10. Data Quality Model

OSM data quality for restaurant POIs varies significantly by metro area and contributor density. The following is expected:

- **Incomplete records:** Missing name, phone, website, hours. Operators fill these via `place_profiles`.
- **Stale records:** Restaurants that have closed since the extract date. The refresh process catches these; the closure flow in §8.2 handles them.
- **Duplicates:** Two OSM nodes for the same physical location. The merge flow in §8.3 handles these.
- **Name variations:** "Mike's Pizza" vs "Mikes Pizza" vs "Mike's Pizza Brooklyn". Slug generation and staff review handle disambiguation.
- **Missing from OSM:** Venues that exist but were never mapped. Users can add them via the "Add missing venue" flow (§7.1). This creates a `places` row with no OSM source reference; the record is Forkensics-originated and not subject to ODbL.

Restaurant claiming is the primary quality-control mechanism: operators correct their own listing, which is always higher-quality than crowd-sourced map data.

---

## 11. Implications for Existing Schema (V1–V4)

Anticipated migration structure (not yet numbered or written — design doc only):

- **New migrations:** Create all six new tables, add `visibility` and `place_id` to `cases`, add indexes, update RLS.
- **No V1–V4 edits.** All changes are additive.
- PostGIS extension required for spatial indexes. Verify it is enabled in the local and forkensics-dev Supabase instances before writing the migration.
- The `upload-authorize` Edge Function (current active work) is unaffected. `place_id` and `visibility` are set at the case-posting layer (a later Edge Function).

---

## 12. What Does Not Change

- The core game mechanic (post photo, group guesses, reveal).
- Private cases and group-scoped visibility — default behavior is unchanged.
- The media pipeline (EXIF stripping, R2 storage, server re-encoding).
- The `upload-authorize` Edge Function and Amendment D work.
- Sign in with Apple authentication.
- Three-party governance: any schema migration or new Edge Function requires Bill + Claude + Codex approval before implementation.

---

## 13. Open Questions for Review

1. **ODbL scope of `places` table:** Do Forkensics-generated UUIDs and slugs, derived from OSM-imported data, constitute a "Derivative Database" under ODbL, making the `places` table subject to share-alike? Legal review required before production import.

2. **PostGIS dependency:** The spatial indexes and location-based queries assume PostGIS. Confirm it is available and enabled in the Supabase project before writing migrations.

3. **Autocomplete decision:** Option A (self-hosted Photon) is recommended for launch. What is the hosting environment — a dedicated VPS, a Fly.io instance? Operational complexity should be weighed against Option B (commercial OSM API). Decision needed before building the search Edge Function.

4. **Attribution placement:** Where exactly does the "© OpenStreetMap contributors" line appear in the iOS UI? A persistent footer on the place page? A tooltip on the location pin? The legal obligation is clear; the UX implementation needs a design decision.

5. **Visibility default:** Private (safest) vs. a per-user preference. Recommendation: default private.

6. **Public feed moderation:** Public cases are app-wide. A moderation plan is required before the public feed goes live. Not addressed in Rev 2.

7. **Geofabrik extract frequency:** Geofabrik updates regional extracts approximately weekly. Forkensics' proposed refresh cadence is quarterly. Is quarterly sufficient for data freshness, or should it be more frequent for active metro areas?

8. **Place operator identity on public cases:** When an operator posts a case, should it display as "[Restaurant Name]" or "[Operator's personal profile]"? Recommendation: restaurant name, personal identity hidden.

9. **User-created places (no OSM source):** Are user-created venues subject to any license? They are Forkensics-originated, not ODbL-covered. Confirm this is acceptable and documented in the ODbL compliance review.

10. **Duplicate place merge and `cases` FK:** When two `places` rows are merged (§8.3), should existing `cases.place_id` references be updated to point to the canonical row, or resolved at query time via the merge chain? Updating is simpler for queries; the merge chain is simpler to implement. Decision affects migration complexity.

11. **Google Places as optional fallback:** If Google Places Autocomplete is later approved as an optional integration, what is the data flow — does it produce `places` rows without an OSM source ref, with a new `google_place_sources` table, or only session-cached data that is never stored? This must be defined before that path is approved.
