# Public Games and Restaurant Publishing — Product Proposal

**Date:** 2026-08-16  
**Status:** DISCOVERY — Not approved for implementation  
**Audience:** Bill, Claude, and Codex

## 1. Opportunity

Forkensics could offer a public game mode in addition to its private table-based experience. The strongest initial version would allow anyone to discover and play public games while limiting public publishing to verified restaurants.

This turns a restaurant's menu photography into an interactive promotion:

> Turn a menu photo into a playable advertisement. Players guess the dish and restaurant, then receive the reveal, restaurant details, and an optional call to action.

The public mode could create a growth loop for Forkensics while giving restaurants a measurable way to promote individual dishes.

## 2. Recommended Initial Model

- Anyone can discover and play public games.
- Only verified restaurants can publish publicly at first.
- Regular player-created games remain private by default.
- A later version may let players submit a game to a restaurant for approval and public publication.
- Public play may be available without an account; an account can be required for leaderboards, prizes, saved restaurants, or offer redemption.
- Do not include public comments in the first version. This keeps the moderation surface manageable.

This model provides public distribution without immediately accepting the risks of unrestricted public user-generated content.

## 3. Restaurant Value Proposition

Forkensics should be presented to restaurants as more than a place to post photos:

> Forkensics turns a restaurant's best dishes into games that generate attention, visits, and measurable customer engagement.

Potential restaurant benefits include:

- Promotion that feels like entertainment rather than a conventional advertisement.
- Exposure for specific dishes, specials, launches, or seasonal menus.
- Measurable plays, reveals, menu clicks, saves, shares, and offer redemptions.
- Repeat engagement through weekly challenges, tournaments, or local competitions.
- Social sharing that can bring new players into Forkensics.
- Restaurant-approved customer photography in a future version.
- Direct calls to action such as viewing a menu, getting directions, reserving a table, or redeeming an offer.

## 4. Reasons Restaurants Might Decline

Restaurants will not automatically participate merely because the feature provides exposure. Likely objections include:

- Poor or unflattering photographs.
- Incorrect dish names, prices, ingredients, or location details.
- Fake restaurant accounts or unauthorized brand use.
- Negative comments or uncontrolled public content.
- Additional work for already-busy restaurant staff.
- Unclear or unmeasurable return on investment.
- Concern that discounts or prizes could reduce margins.

The product should answer these concerns through verified ownership, restaurant-controlled publishing, approval tools, moderation and takedown processes, simple setup, and useful analytics.

## 5. Suggested Public MVP

1. Public game feed, with optional location filtering.
2. Verified restaurant profiles tied to a specific business and location.
3. Restaurant-created public cases using the existing photo-and-reveal game loop.
4. Guest play, with authentication required for persistent scores, leaderboards, prizes, or saves.
5. Reveal screen containing the dish name, restaurant name, location, menu link, and optional offer.
6. Basic restaurant analytics: impressions, game starts, completed guesses, reveals, clicks, shares, and redemptions.
7. Reporting, moderation, takedown, and account-verification controls.
8. No public comments in the initial release.

## 6. Possible Business Model

Players should not be charged to participate in public games. Potential restaurant tiers could include:

- **Free starter:** restaurant profile and a limited number of active public games.
- **Paid restaurant plan:** additional games, scheduling, richer analytics, and staff accounts.
- **Featured placement:** clearly labeled sponsored placement in local discovery surfaces.
- **Branded tournaments:** restaurant, neighborhood, or city-wide competitions.
- **Offers and redemption:** optional coupons or prizes with measurable conversion.

Forkensics should avoid pay-to-win mechanics that affect player scoring. Restaurant payments should purchase publishing and promotional tools, not competitive advantage within the game.

## 7. Product and Safety Boundaries

- Restaurant publishing requires verification.
- Restaurant accounts need owner and staff roles.
- Restaurants control their own public posts and business information.
- Public display images may be broadly readable, but original uploaded files remain private.
- Public content requires reporting, moderation, removal, and appeal paths.
- Rate limits and abuse controls are required for public play and publishing.
- Public leaderboards should expose only an approved display name, never private identity or location data.
- Location should identify the restaurant, not reveal a player's precise location.
- Sponsored content and offers must be clearly labeled.

## 8. Likely Backend Additions

The existing private-game backend should remain the foundation. A future public-mode design may add concepts such as:

```text
case.visibility = private | public
case.publisher_type = player | restaurant

restaurant_profile
restaurant_location
restaurant_membership

publication_status = draft | review | published | removed
```

Additional backend work would likely include:

- Restaurant organizations, locations, staff membership, and role-based access.
- Restaurant verification and ownership-transfer workflows.
- Public read policies that remain separate from private table access.
- Public feed, discovery, filtering, and search.
- Moderation status, reports, takedowns, and audit history.
- Analytics events and privacy-preserving aggregation.
- Offer creation, redemption, and fraud controls if offers are introduced.
- Public display-image delivery while keeping originals private.

Exact schema and RLS changes require a separate technical proposal and three-party review.

## 9. Recommended Sequence

1. Finish the current Amendment D R2 upload path.
2. Complete and prove the `upload-complete` vertical slice and cleanup behavior.
3. Run a product-discovery pass with a small number of restaurant owners or managers.
4. Decide whether the first public pilot uses restaurant-created games only or includes approved customer submissions.
5. Write a dedicated public-games and restaurant-accounts proposal covering product rules, moderation, privacy, schema, RLS, analytics, and rollout.
6. Pilot with a small set of verified restaurants before opening broader enrollment.

## 10. Open Questions for Claude Review

1. Does public play fit cleanly beside the existing private table model, or should it be treated as a separate game surface?
2. What is the smallest restaurant identity and staff-role model that remains secure?
3. Should guest players be able to submit guesses without authentication, and what rate limits would be required?
4. Which analytics can be collected without creating unnecessary privacy risk?
5. Should restaurant offers be excluded from the first pilot to reduce fraud and operational complexity?
6. What moderation and takedown capabilities are mandatory before the first public post?
7. Which current schema assumptions would make public visibility difficult to add later?

## 11. Governance Note

This document records a product opportunity and recommended direction only. It does not change the approved MVP scope, reprioritize the current backend sequence, authorize schema or code changes, or authorize any cloud operation. Implementation requires a separate reviewed proposal and explicit three-party approval.
