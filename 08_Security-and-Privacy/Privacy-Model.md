# Privacy Model — Draft

## Default posture

- Invite-only groups
- No public feed or search
- Least-privilege access to photos and locations
- Exact location hidden until reveal
- Clear retention and deletion controls
- Private media storage rather than permanent public URLs

## Photo protections

- Generate a sanitized game derivative.
- Remove EXIF, GPS, filenames, and other unnecessary metadata.
- Do not expose original asset identifiers.
- Prevent canonical answers from appearing in accessible image metadata or API payloads.
- Use authenticated, short-lived access to private media.

## Location protections

- Show only the information needed for the guessing interface.
- Do not expose exact coordinates before reveal.
- Allow posters to select venue, neighborhood, city, or approximate location depending on approved rules.
- Avoid creating a background location history.

## Social protections

- Membership checks apply to every group resource.
- Block, report, remove-member, and leave-group behavior must be defined before external testing.
- Push notifications should not reveal sensitive answers on a locked screen by default.

