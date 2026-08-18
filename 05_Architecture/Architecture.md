# Architecture — Decisions Pending

## Confirmed

- Standalone iPhone application
- Swift implementation
- Claude is the sole application-code author
- Minimum deployment target: iOS 18
- Build target: iOS 26 SDK
- Primary design and testing: iOS 26
- Backend: Supabase (preferred, not yet approved for implementation)

## System components

- SwiftUI client
- Supabase Auth — Sign in with Apple
- PostgreSQL via Supabase — all game data
- Row-level security — group membership enforced on every table
- Supabase Storage (private bucket) — sanitized game-copy media only
- Supabase Edge Functions — server-authoritative scoring, reveal transitions, notification triggers
- Supabase Realtime — deferred until justified
- Push notifications via APNs, triggered by Edge Functions
- Optional AI service for food suggestions and fuzzy answer comparison (deferred)

## Architectural principles

- The server is authoritative for deadlines, reveal state, scores, and group membership.
- The poster is authoritative for the canonical dish and location.
- Clients never receive canonical answers before reveal.
- Original photo metadata must not leak through distributed images or APIs.
- AI failure must not block ordinary gameplay.
- Provider-specific services should sit behind narrow interfaces.

## Media pipeline

1. Poster selects or captures one photograph on device.
2. App creates a resized game copy locally.
3. App strips EXIF, GPS, filename, and unnecessary metadata client-side.
4. Original remains in Apple Photos; it is never uploaded.
5. Sanitized game copy uploads only when the challenge is posted.
6. On receipt, an Edge Function or storage trigger re-encodes the image server-side (defense in depth).
7. The stored game copy is the server-re-encoded version.
8. Storage bucket is private. No public access.
9. Image delivery: authenticated Edge Function proxy checks group membership before serving any image. Client never sees raw storage paths or signed URLs. Database stores only the internal media object identifier.
10. A thumbnail may be generated for list views.
11. Deleting a challenge deletes its game image and thumbnail per the approved retention rule.

## Authentication — Sign in with Apple

- Supabase Auth handles Sign in with Apple natively.
- Flow: iOS triggers Apple auth → authorization code and identity token → forwarded to Supabase Auth → session created.

### CRITICAL IMPLEMENTATION NOTE — Sign in with Apple name capture
Apple returns the user's full name only during the initial authorization response (`credential.fullName`). It is not included in the identity token and is not available on subsequent sign-ins.

Required sequence:
1. Capture `credential.fullName` immediately from the native Apple response.
2. Retain it in memory during the authentication flow.
3. Establish the Supabase session.
4. Write the sanitized display name to Supabase user metadata and the Player profile.
5. If Apple returns no name, require the player to choose a display name during onboarding.

No profile write should precede a valid Supabase session.

### Application identity key
- Application primary key: Supabase `auth.users.id` (UUID). Used in all application tables and RLS policies via `auth.uid()`.
- Apple stable identifier (`sub`): stored as `provider_id` on the Apple identity record in Supabase. Not used as a primary key in application tables.
- Email: optional only. May be a private Apple relay address. Never used as a primary key or contact mechanism.

## iOS compatibility

- iOS 18 minimum provides access to: SwiftUI (full feature set for this app), Sign in with Apple, PhotosUI PhotosPicker, SwiftData for local persistence.
- Claude will flag any iOS 26-specific API used without an iOS 18 fallback at implementation time.
- Pilot device inventory required before implementation begins.

## Image transform architecture — CONFIRMED 2026-08-16

Server-side re-encoding is handled by a **Cloudflare Worker + R2 + Images Binding** pipeline. Gate 2B CF spike (Rev 10) passed all probes on 2026-08-16.

- Upload target: private Cloudflare R2 bucket (`originals/` prefix).
- Transform: Cloudflare Worker calls `IMAGES.input().transform().output(format:"image/webp", anim:false)`. Worker enforces: 10 MB byte gate, 15.5 MP pixel gate, JPEG/WebP formats only, bounded 5 MB output stream.
- Metadata stripping: confirmed — Cloudflare Images strips all EXIF/XMP/ICC/GPS from output WebP.
- Write-back: transformed display copy stored at `display/{basename}.webp` in R2.
- Auth boundary: worker requires `Authorization: Bearer {SPIKE_SECRET}` — production will use Cloudflare service token or HMAC-SHA256 (OQ-3, pending decision).
- CPU budget: Free plan 10 ms limit; CF-P-9 returned 200 OK (Error 1102 would have fired if exceeded). Metric was INCONCLUSIVE due to Free plan analytics lag.
- Supabase `upload-complete` Edge Function calls the Cloudflare Worker after upload; Cloudflare is not a Supabase component.

**Design decisions (confirmed 2026-08-16):**
- Upload path: `upload-authorize` returns a 5-minute pre-signed R2 PUT URL with server-generated object key and scoped `Content-Type`. Client uploads directly to R2. URL is ephemeral and never stored.
- Display key: `display/{media_id}.webp` — derived from the media UUID. Idempotent, no double extension, no additional database field.
- Worker auth: Cloudflare Access service token. `upload-complete` sends `CF-Access-Client-Id` and `CF-Access-Client-Secret` headers (stored as Supabase secrets). No custom HMAC code.
- Pixel gates: reject when `width > 8192`, `height > 8192`, or `width × height > 15,500,000`. All three checked independently; any failure returns 422.

## Open architecture decisions

- Push notification delivery details: Edge Function triggers to APNs directly vs. third-party service.
- AI provider for fuzzy matching and dish suggestions: deferred.

