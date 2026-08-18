# Gate 2B Proposal — Rev 19
# Managed Supabase Image Transformation Feasibility Spike

**Date:** 2026-08-15  
**Status:** DRAFT — awaiting Codex review and three-party approval  
**Predecessor:** Gate-2B-Proposal-Rev18.md (NOT APPROVED — three blockers)  
**Authorized project:** `hkfrbdpedrxmbsawnbpr` (forkensics-dev only)

**Rev 19 blockers closed from Rev 18:**

| # | Blocker | Section changed |
|---|---------|----------------|
| B-1 | VP8X flag masks corrected: XMP is `0x04`, EXIF is `0x08`, Alpha is `0x10` (allowed), ICC is `0x20`; prohibited mask covers reserved bits in byte 0 and all 24 reserved bits in bytes 1–3; VP8X ordering and duplication rules completed | P-6, §7 |
| B-2 | Phase 2 scope expanded: temporary Auth test user creation authorized, credentials in-memory only, deleted and confirmed during cleanup; P-1 auth matrix expanded to all four cases (no creds, anon, authenticated, service-role) | §3.3, §3.6, §3.7, P-1 |
| B-3 | P-11 catch-all added: any status other than 200 or 404 → immediate FAIL; inconclusive Method B prevents P-11 from passing | P-11 |

---

## 1. Rev 14 and Rev 15 Failure Summary

| Rev | Hypothesis | H-1 result | Root cause |
|-----|-----------|-----------|-----------|
| Rev 14 | WASM init at module top-level | HTTP 546 `WORKER_RESOURCE_LIMIT` | Pre-handler resource exhaustion; no console output, no handler invocation |
| Rev 15 | Lazy init in handler (Promise-cached) | HTTP 546 `WORKER_RESOURCE_LIMIT` | Pre-handler resource exhaustion; Dashboard Edge Function logs = 0; handler never ran |

Both revisions deployed the same 9.3 MB `@imagemagick/magick-wasm` bundle. Supabase defines HTTP 546 as CPU or memory exhaustion; the specific resource is unconfirmed (no ShutdownEvent emitted). Bundle import and JIT compilation during isolate boot is the leading inference, but remains unproven. The decision to abandon `@imagemagick/magick-wasm` is not contingent on proving the precise resource. No further magick-wasm experiments are authorized.

---

## 2. Hypothesis

**Supabase Storage Image Transformations (imgproxy) can perform the full sanitization contract — decode, re-encode to WebP, and strip all metadata — outside the Edge Function CPU budget.**

The Edge Function becomes a lightweight orchestrator: validates input, requests the transformation, byte-verifies the result, hashes it, writes to `display_storage_path`, deletes the original, and records event ordering. No WASM loaded. No raster decoded inside the function.

This is a **feasibility spike**, not an implementation. Each requirement must be proved independently before a Rev 20 implementation proposal is drafted.

---

## 3. Scope and Authorization

### 3.1 Two-Phase Authorization

**Phase 1 — Proposal sign-off (this document):**  
Authorizes: read-only Dashboard plan check (P-0); spike artifact drafting if P-0 passes without requiring upgrade; full stop if upgrade required pending separate three-party approval.

**Phase 2 — Spike artifact §1.2 review:**  
Before any deployment or execution, spike artifacts (function code, test scripts, fixture generators) receive a separate three-party static/local review with their own magic phrase. Proposal sign-off does not satisfy this gate. No cloud operation occurs until Phase 2 is recorded.

### 3.2 What Phase 1 authorizes

- Read-only Dashboard plan check (P-0)
- Spike artifact drafting, contingent on P-0 outcome

### 3.3 What Phase 2 authorizes

- Deployment of the spike Edge Function to `hkfrbdpedrxmbsawnbpr` (forkensics-dev only)
- Upload of test fixtures to `game-media` under `gate2b-r19/<run-id>/`
- Execution of the spike protocol (P-1 through P-14)
- **Creation of one temporary Auth test user** in `hkfrbdpedrxmbsawnbpr` with credentials generated in-memory at runtime, never logged or persisted. The user's `role=authenticated` access token is used solely to verify the spike function's handler rejects it.
- Deletion of all spike objects, the deployed function, and the temporary Auth user per §3.6

### 3.4 What neither phase authorizes

- Changes to `upload-complete`, `upload-authorize`, V4 schema, or RLS policies
- Any operation against `torkgydbvktqebssfpdi` (forkensics-prod)
- Upgrade of `forkensics-dev` without separate three-party approval
- Session state mutations in the production `upload_sessions` table

### 3.5 Authorized mutations and storage policy

- **Bucket:** `game-media` (existing private bucket)
- **Object prefix:** `gate2b-r19/<run-id>/` where `<run-id>` is a UUID generated at spike start
- **Database:** No `upload_sessions` transitions. DB fixtures for P-11 instrumentation, if needed, use clearly marked test records deleted during cleanup.
- **Runtime secrets:** Service-role key and ANON_KEY are runtime environment variables only. Never written to any file, echoed, or logged. Temporary Auth user credentials are generated in-memory and never written or logged.

### 3.6 Cleanup protocol (mandatory)

The spike runner implements EXIT/INT/TERM traps executing in order:

1. Delete the deployed spike Edge Function; confirm deletion via API.
2. **List** all objects under `gate2b-r19/<run-id>/` in `game-media`, paginating all result pages.
3. **Delete** each enumerated object; confirm each deletion individually.
4. **Re-list** the prefix; require exactly zero objects remaining. Any remaining → log cleanup failure, exit non-zero.
5. Delete DB test fixtures if created; confirm deletion.
6. **Delete the temporary Auth test user** (created for the `role=authenticated` rejection test); confirm deletion via a service-role admin API call that returns the user as not found. Retain no reference to the user's credentials after deletion.
7. Preserve evidence directory (`gate2b-evidence-r19-<YYYYMMDDTHHMMSSZ>/`) before exit.

Cleanup runs on normal exit, error exit, and signal interruption. Evidence is preserved regardless of cleanup success or failure.

### 3.7 Spike Function Caller-Auth Contract

The spike function holds administrative Storage credentials and must reject all non-service-role callers.

**Configuration:** `verify_jwt = true` in `config.toml`. The Supabase gateway validates JWT signature and rejects missing or malformed tokens before the handler runs.

**Handler enforcement:** Gateway `verify_jwt` does not inspect the `role` claim. The handler must:

1. Read the `Authorization` header (format `Bearer <jwt>`).
2. Decode the JWT payload (base64url, middle segment). Gateway already verified the signature; no re-verification required.
3. If `role` claim is absent, or is not exactly `service_role`: return HTTP 403 without processing.

**Complete caller auth matrix:**

| Caller | Expected response | Enforced by |
|--------|-----------------|------------|
| No `Authorization` header | 401 | Supabase gateway (`verify_jwt=true`) |
| Anon JWT (`role=anon`) | 403 | Handler `role` check |
| Authenticated-user JWT (`role=authenticated`) | 403 | Handler `role` check |
| Service-role JWT (`role=service_role`) | 2xx (normal processing) | Handler passes |

P-1 must assert all four cases.

**Key format note:** `verify_jwt = true` requires a JWT-format service-role key (three dot-separated base64url segments). Newer `sb_secret_...` keys are not JWTs; they will fail the gateway check. The runner preflight (§3.8) detects this before deployment.

### 3.8 Runner JWT Preflight (Pre-Deployment)

Before deploying the spike function, the runner script verifies the service-role key without printing it. All five checks must pass; any failure aborts before deployment:

1. **Project ref:** `PROJECT_REF` equals exactly `hkfrbdpedrxmbsawnbpr`. Print `✓ PROJECT_REF` or `FAIL: unexpected PROJECT_REF` and exit 1.
2. **Three JWT segments:** Split `SERVICE_ROLE_KEY` on `.`; require exactly three non-empty segments. Print `✓ key has 3 segments` or `FAIL: key does not appear to be a JWT (wrong segment count)` and exit 1. Catches `sb_secret_...` keys.
3. **Payload decodes:** Base64url-decode the middle segment and parse as JSON. Print `✓ payload decodes` or `FAIL: payload not decodable` and exit 1. Never print the decoded payload.
4. **`role` claim:** Require `role == "service_role"`. Print `✓ role=service_role` or `FAIL: role is not service_role` and exit 1. Never print the actual role value.
5. **Not expired:** Require `exp > $(date +%s)`. Print `✓ key not expired` or `FAIL: key is expired` and exit 1. Never print the exp value.

---

## 4. WebP Targeting

Supabase Storage Image Transformations select WebP based on the client `Accept` header. `format=origin` disables optimization; no `format=webp` parameter is documented. The spike uses `Accept: image/webp`. P-2 verifies the response at the byte level regardless of `Content-Type`. P-12 detects and rejects non-WebP responses.

---

## 5. Canonical Display Parameters

| Parameter | Value | Basis |
|-----------|-------|-------|
| Longest edge | 2048 px | Within Supabase documented 2500 px limit |
| Resize mode | `contain` | Preserves aspect ratio; no cropping |
| Quality | 80 | Initial value; confirmed or adjusted by P-8 |
| WebP selection | `Accept: image/webp` header | Documented client-driven optimization |

---

## 6. Platform Limits (Authoritative)

| Resource | Platform limit | Forkensics safety target |
|----------|---------------|------------------------|
| Edge Function memory | 256 MB | < 100 MB highest observed; see P-8 verdict tiers |
| Edge Function CPU | 2 s | TBD by spike |
| Storage transform input size | 25 MB | Forkensics upload limit: 10 MB (stricter) |
| Storage transform input pixels | 50 MP | `CANONICAL_PIXEL_LIMIT`: 15,500,000 px (stricter) |

Note on P-0: Supabase currently documents Image Transformations as available on Pro and above. The Dashboard check establishes the project's actual current status.

Sources: [Supabase Edge Function limits](https://supabase.com/docs/guides/functions/limits); [Supabase Storage transformation documentation](https://supabase.com/docs/guides/storage/serving/image-transformations).

---

## 7. Source-Header Parser Contract

The spike function determines input dimensions and animation status from a bounded read before issuing any transformation request.

**Read cap:** 1 MiB (1,048,576 bytes).

**JPEG inputs:**
- Issue `Range: bytes=0-1048575` against the stored object.
- Validate Range is honored: `Content-Range` response header must match; if absent or mismatched, abort as malformed.
- Parse SOF markers (SOF0, SOF1, SOF2, SOF3, SOF5, SOF6, SOF7, SOF9, SOF10, SOF11) incrementally within the capped bytes to extract width and height.
- Fail-closed: no SOF found within cap → reject as malformed; do not request transformation.

**WebP inputs:**
- Issue `Range: bytes=0-1048575`; validate Range honor as above.
- Parse RIFF header (bytes 0–11: `RIFF` + size + `WEBP`).
- Read first chunk FourCC at byte 12:
  - `VP8 ` or `VP8L`: extract dimensions; animation = false.
  - `VP8X`: read the 4-byte flags field. Animation flag = bit 1 of flags byte 0 (mask `0x02`); reject if set. Extract canvas width and height from VP8X payload bytes 4–9.
- Fail-closed: chunk structure not parseable within cap → reject as malformed.

**Fail-closed rule:** Any condition preventing unambiguous determination of dimensions or animation status within the 1 MiB cap results in rejection. The function must not request a transformation for an input it cannot fully characterize.

**P-7 logging:** Record only `transform_fetch_attempted` (boolean) and a rejection reason string. Never log a signed URL, storage path, or object key.

---

## 8. Memory Model

The function holds only:
1. A bounded header range from the original (≤ 1 MiB per §7)
2. Encoded transformed WebP bytes (bounded by P-9's stream limit)
3. A temporary hash buffer if `crypto.subtle.digest` requires a concrete `ArrayBuffer` copy

Memory is measured by `Deno.memoryUsage()` checkpoint snapshots, reported as "highest observed checkpoint `rss`." ShutdownEvent telemetry recorded if emitted.

---

## 9. Fixtures

| Label | Description | Purpose |
|-------|-------------|---------|
| F-SMALL | 1000×800 JPEG, low noise | Baseline smoke test |
| F-DISPLAY | 2600×2080 JPEG (≈5.4 MP), realistic photo | Nominal display-tier transform |
| F-WORST | Noisy JPEG ≈15.5 MP near 10 MB encoded | P-8 worst-case memory |
| F-REJECT | 5001×3100 JPEG (15,503,100 px) | P-7 pre-check gate |
| F-MALFORMED | Truncated JPEG at 50% expected bytes | P-6 malformed handling |
| F-POLYGLOT | Valid JPEG + ZIP archive appended after EOI | P-6 trailing-data handling |
| F-ANIMATED | Animated WebP (VP8X animation flag set, ANIM/ANMF chunks present) | P-6 animated-input handling |
| F-EXIF-ROT | JPEG with `Orientation: 6` (90° CW) and embedded GPS | P-4 orientation + P-3 GPS removal |
| F-XMP | WebP with XMP chunk | P-3 XMP removal regression |

**Fixture metadata preflight (required before P-3):** Verified with ExifTool before the spike run. A fixture lacking its expected metadata is invalid and must be regenerated. Results in `fixture-preflight.md`.

---

## 10. Spike Protocol

Tests ordered. A failing hard gate does not block recording subsequent results. All tests require Phase 2 sign-off. Runner JWT preflight (§3.8) must pass before deployment.

---

### P-0 — Plan Eligibility Gate (hard gate; Phase 1 only; read-only)

**Objective:** Establish whether `hkfrbdpedrxmbsawnbpr` is on a plan that includes Storage Image Transformations.

1. Check the forkensics-dev project plan in the Supabase Dashboard.
2. Record plan name and whether transformations are included.
3. If not included: document plan required, monthly cost, per-transformation cost. Stop — no artifact drafting until separate upgrade approval.
4. If included: record and proceed to artifact drafting.

**Pass:** Transformations confirmed on current plan.  
**Stop gate:** Upgrade required — separate three-party approval before proceeding.

---

### P-1 — Private-Bucket Transformed Download and Auth Matrix

**Objective:** Confirm private-bucket transformation succeeds with service-role authorization and all four auth cases behave correctly.

**Fixture:** F-SMALL, uploaded to `game-media` under the run prefix.

**Method:**
1. Using the service-role key, generate a short-lived signed transformation URL for F-SMALL.
2. Fetch the signed URL with `Accept: image/webp`. (Service-role authorized.)
3. Confirm the equivalent unsigned URL returns non-200 when fetched with no headers.
4. Confirm the unsigned URL returns non-200 when fetched with both `Authorization: Bearer <anon-jwt>` and `apikey: <anon-key>` headers.
5. Send a request to the spike function with **no `Authorization` header**; confirm HTTP 401 (gateway rejects).
6. Send a request to the spike function with an **anon JWT** (`role=anon`); confirm HTTP 403 (handler rejects).
7. Send a request to the spike function with the **temporary Auth user's access token** (`role=authenticated`); confirm HTTP 403 (handler rejects).
8. Send a valid request to the spike function with the **service-role JWT**; confirm successful processing (2xx).

**Assertions:**

| Test | Expected |
|------|----------|
| Signed URL, `Accept: image/webp` | HTTP 200, non-empty WebP body |
| Unsigned URL, no headers | Non-200 |
| Unsigned URL, anon `Authorization` + `apikey` | Non-200 |
| Spike function, no credentials | 401 |
| Spike function, anon JWT | 403 |
| Spike function, authenticated-user JWT | 403 |
| Spike function, service-role JWT | 2xx |

**Pass:** All seven assertions satisfied.  
**Fail → Fallback trigger:** Private-bucket transformation requires public access, or anon credentials can access the unsigned URL.

---

### P-2 — WebP Output Verification

**Fixture:** F-SMALL (JPEG input). Fetch signed transformation URL with `Accept: image/webp`.

**Assertions:**
- `Content-Type` contains `image/webp`
- Bytes 0–3: `52 49 46 46` (`RIFF`)
- Bytes 8–11: `57 45 42 50` (`WEBP`)
- Bytes 0–1 are NOT `FF D8` (JPEG SOI)

**Pass:** All byte-level assertions satisfied.  
**Fail → Fallback trigger:** Response body is original JPEG or RIFF/WEBP magic absent.

---

### P-3 — Metadata Removal (Independent Parser)

**Pre-condition:** Fixture preflight confirms source metadata present.

**Fixtures:** F-EXIF-ROT (EXIF + GPS), F-XMP (XMP chunk).

**Prohibited metadata:**

| Category | ExifTool group names | Explicit prohibited tag names | WebP chunk IDs |
|----------|---------------------|------------------------------|---------------|
| EXIF | `EXIF`, `ExifIFD` | — | `EXIF` |
| GPS | `GPS` | — | (within EXIF chunk) |
| XMP | `XMP` | — | `XMP ` (with trailing space) |
| IPTC | `IPTC` | — | (typically within EXIF) |
| ICC profile | `ICC_Profile` | — | `ICCP` |
| Comments | — | `Comment`, `UserComment`, `XPComment` | (VP8X does not contain comment text) |

**Method:**
1. Request transformation (signed URL, `Accept: image/webp`).
2. Run `hasWebpMetadata` byte scanner against output.
3. Run ExifTool against output; record all tags found.
4. Parse full WebP chunk map (FourCC, size, offset) from RIFF structure.

**Assertions:**
- `hasWebpMetadata` returns `false`
- ExifTool reports zero tags in groups: EXIF, ExifIFD, GPS, XMP, IPTC, ICC_Profile
- ExifTool reports zero tags with names: `Comment`, `UserComment`, `XPComment`
- Structural ExifTool properties (FileType, ImageWidth, ImageHeight, MIMEType, FileSize, Megapixels) are not prohibited
- No prohibited chunk IDs in chunk map (`EXIF`, `ICCP`, `XMP `, `ANIM`, `ANMF`, or any non-allowlisted FourCC per P-6 allowlist)
- Source preflight confirmed expected metadata was present before transformation

**Pass:** All assertions satisfied.  
**Fail → Fallback trigger:** Any prohibited tag, group, or chunk survives.

---

### P-4 — EXIF Orientation Applied Before Metadata Removal

**Fixture:** F-EXIF-ROT (JPEG, `Orientation: 6`, coded landscape, 90° CW required).

**Assertions:**
- Transformed WebP contains no EXIF chunk (passes P-3)
- Output width < output height (rotation baked in, portrait result confirmed)

**Pass:** Both satisfied.  
**Fail → Fallback trigger:** Incorrectly oriented output, or EXIF retained.

---

### P-5 — Output Dimensions and Aspect Ratio

**Fixtures:** F-DISPLAY (landscape), F-EXIF-ROT (portrait after orientation correction).

**Assertions per fixture:**
- Longest edge ≤ 2048 px
- Aspect ratio matches input within 1% tolerance
- No upscaling beyond input resolution

**Pass:** All satisfied.  
**Fail → Fallback trigger:** Dimensions incorrect or aspect ratio distorted.

---

### P-6 — Malformed, Truncated, Polyglot, and Animated WebP Inputs

**Predetermined security rules:**

| Input class | Required behavior |
|-------------|-----------------|
| F-MALFORMED (truncated JPEG) | imgproxy must return non-200. Any 200 fails this test. |
| F-ANIMATED (animated WebP) | Spike function detects VP8X animation flag via §7 parser and returns rejection without issuing any transformation request. Confirmed by `transform_fetch_attempted=false`. |
| F-POLYGLOT (JPEG + appended ZIP) | Accepted only if all structural validation conditions below are met. |

**WebP structural validation for polyglot acceptance:**

Definitions:
- `riff_size` = uint32 LE at bytes 4–7
- `declared_total` = `riff_size + 8` (total file size)
- Chunk data region: `bytes[12 .. declared_total)` (length = `riff_size − 4`)

Steps — all required; any failure rejects the output:

1. Verify bytes 0–3 = `RIFF`, bytes 8–11 = `WEBP`.
2. Verify `declared_total == actual_body_length` (no bytes beyond the RIFF extent).
3. Parse all chunks within `bytes[12 .. declared_total)`:
   - Each chunk: 4-byte FourCC + 4-byte LE chunk payload size + payload + 1 padding byte (value `0x00`) if payload size is odd.
   - Verify each chunk's bounds fall strictly within `bytes[12 .. declared_total)`. Any overrun → reject.
   - Verify padding byte, where present, is exactly `0x00`. Non-zero padding → reject.
4. Verify no bytes exist after `declared_total`.
5. **Chunk allowlist** — permitted FourCCs for a sanitized still image: `VP8X`, `ALPH`, `VP8 ` (with trailing space), `VP8L`. Any other FourCC → reject. This explicitly rejects `EXIF`, `ICCP`, `XMP `, `ANIM`, `ANMF`, and all unknown chunks.
6. **VP8X validation** (if `VP8X` chunk is present):

   *Feature flags* — VP8X payload bytes 0–3 form the 32-bit little-endian flags field:

   | Byte 0 bit | Mask | Meaning | Requirement |
   |-----------|------|---------|-------------|
   | 0 | `0x01` | Reserved | Must be `0` |
   | 1 | `0x02` | Animation | Must be `0` (prohibited) |
   | 2 | `0x04` | XMP metadata | Must be `0` (prohibited) |
   | 3 | `0x08` | EXIF metadata | Must be `0` (prohibited) |
   | 4 | `0x10` | Alpha channel | May be `0` or `1` (allowed) |
   | 5 | `0x20` | ICC profile | Must be `0` (prohibited) |
   | 6–7 | `0xC0` | Reserved | Must be `0` |

   Bytes 1–3 of the flags field (24 reserved bits): all must be `0x00`.

   Validation expression: `(flags_u32 & ~0x00000010) === 0`  
   (Only bit 4 / `0x10` may be set; all other bits in the 32-bit flags field must be zero.)

7. **Structural ordering rules:**
   - At most one `VP8X` chunk; at most one `ALPH` chunk. Duplicates → reject.
   - If `VP8X` is present, it must be the **first** chunk in the file. `VP8X` appearing after any other chunk → reject.
   - `ALPH` is permitted only immediately before `VP8 ` (lossy). `ALPH` before `VP8L` → reject. `ALPH` without `VP8X` → reject.
   - Exactly one image-data chunk (`VP8 ` or `VP8L`) must be present. Zero or more than one → reject.
   - Valid complete chunk sequences for a sanitized still WebP:
     1. `VP8 ` — simple lossy, no alpha
     2. `VP8L` — simple lossless, no alpha
     3. `VP8X`, `VP8 ` — extended lossy, no alpha
     4. `VP8X`, `ALPH`, `VP8 ` — extended lossy with alpha

**Assertions per fixture:** Record HTTP status, `transform_fetch_attempted`, and which specific condition passed or failed.

**Pass:** Each fixture's observed behavior satisfies its predetermined rule exactly.  
**Fail:** Any fixture violates its rule.

---

### P-7 — Oversized Input: Forkensics Pre-Check Gate

**Fixture:** F-REJECT (15,503,100 px).

**Primary control:**
- Spike function reads dimensions via §7 parser before any transformation call.
- If `width × height > CANONICAL_PIXEL_LIMIT`: returns rejection; `transform_fetch_attempted=false` logged.
- Signed URL never generated or logged for oversized inputs.

**Secondary evidence (informational):** What does imgproxy return if F-REJECT is submitted directly? Record HTTP status.

**Pass:** `transform_fetch_attempted=false` for F-REJECT; no URL generated or logged.

---

### P-8 — Worst-Case Memory Profile

**Fixture:** F-WORST (≈15.5 MP JPEG near 10 MB encoded).

**Method:** `Deno.memoryUsage()` at five checkpoints: (1) after boot, before transformation request; (2) after transformation response headers received; (3) after full WebP body buffered; (4) after SHA-256 computed; (5) after upload complete. Report as "highest observed checkpoint `rss`." Record ShutdownEvent if emitted.

**Record:** Transformed WebP byte size; `heapUsed`/`rss`/`external` at each checkpoint; highest `rss`.

**Assertions:** HTTP 200; no raster decoded in function; no base64 encoding.

**Verdict tiers (highest observed checkpoint `rss`):**

| Range | Verdict |
|-------|---------|
| < 100 MB | **PASS** |
| 100 MB – < 200 MB | **INCONCLUSIVE** — requires separate architecture decision before Rev 20; spike cannot be declared passed automatically |
| ≥ 200 MB, or HTTP 546 | **FAIL → Fallback trigger** |

---

### P-9 — Bounded Response Handling

**Implementation requirement:** Raw `fetch()` with streaming body reader and byte counter. The Supabase SDK `download()` returns a fully-buffered `Blob` before returning; it cannot enforce a pre-buffer limit and must not be used.

**Proposed maximum transformed-output size:** 5 MB (configurable; confirmed or adjusted by P-8).

**Assertions:**
- Response body exceeding the byte limit is aborted before full buffering completes
- Valid response within limit processes normally
- No base64 encoding at any point

**Pass:** All satisfied.

---

### P-10 — SHA-256 Over Exact Stored Bytes

**Method:** Buffer via bounded streaming reader → compute SHA-256 → upload → download from `display_storage_path` → compute SHA-256 over downloaded bytes → compare.

**Assertions:**
- Hashes match exactly
- No re-encoding or padding during upload

**Pass:** Hashes match.  
**Fail:** Any hash mismatch.

---

### P-11 — Deletion-Before-Advance Ordering (Instrumentation Only)

**Scope:** No `upload_sessions` mutations. Spike records instrumentation events only.

**Method:**
1. Run full pipeline on F-DISPLAY; upload to display path under run prefix.
2. Issue deletion of the original object.
3. **Confirm deletion via two independent methods:**

   **Method A — Authenticated GET:**  
   Issue a service-role-authorized GET for the original object path.

   | Response | Action |
   |----------|--------|
   | 404 | Deletion confirmed; proceed |
   | 200 | Wait 1 s; retry GET. Repeat up to **3 total attempts** (1 initial + 2 retries). If 200 persists after all attempts → **FAIL** |
   | Any other status (400, 401, 403, 405, 408, 409, 429, 5xx, or any status not listed above) | Immediate **FAIL**; do not retry |

   **Method B — Service-role list query (independent confirmation):**  
   Issue a service-role-authorized Storage list for the exact object key. Confirm the key is absent from the result. A conclusive empty or not-found result from the list call is required; any error or inconclusive result from Method B prevents P-11 from passing (Method B cannot merely be recorded while the overall assertion is treated as confirmed).

4. After Method A returns 404 **and** Method B confirms key absent: log `original_delete_confirmed`.
5. Log `would_advance_session`.

**Event sequence required:** `display_written` → `original_delete_confirmed` → `would_advance_session`

**Assertions:**
- Method A returns exactly 404 within allowed attempts
- Method B returns a conclusive absent result; inconclusive = P-11 does not pass
- `original_delete_confirmed` logged before `would_advance_session`
- No `upload_sessions` row created, mutated, or transitioned

**Pass:** All assertions satisfied including conclusive Method B.

---

### P-12 — Non-WebP Response Detection

**Method:** Inject a mock JPEG response at the byte-inspection point. Confirm function checks bytes 0–3 and 8–11 before writing.

**Assertions:**
- If bytes 0–3 ≠ `RIFF` or bytes 8–11 ≠ `WEBP`: function rejects and does not write to `display_storage_path`
- Rejection based on byte inspection, not `Content-Type` alone

**Pass:** Non-WebP response rejected by byte check.

---

### P-13 — Latency (Informational)

**Fixtures:** F-SMALL, F-DISPLAY, F-WORST.  
Record: time to transformation response headers; time to full body buffered; total Edge Function wall time.  
No pass/fail.

---

### P-14 — Cost and Plan Confirmation (Informational)

Record: plan name, whether transformations included or per-use billed, per-transformation cost, quota, overage rate.  
No pass/fail.

---

## 11. Success Criteria Matrix

| # | Criterion | Hard gate? | Result |
|---|-----------|-----------|--------|
| P-0 | Plan eligibility confirmed; upgrade separately approved if required | YES (Phase 1) | ⬜ |
| P-1 | All four auth cases correct: no-creds=401, anon=403, auth-user=403, service-role=2xx; unsigned URL rejects anon credentials; signed URL delivers WebP | YES | ⬜ |
| P-2 | RIFF/WEBP magic confirmed; not JPEG | YES | ⬜ |
| P-3 | Zero prohibited groups, zero prohibited tag names, no non-allowlisted chunks; preflight valid | YES | ⬜ |
| P-4 | Orientation baked in; correctly oriented; no EXIF chunk | YES | ⬜ |
| P-5 | Output dimensions and aspect ratio correct | YES | ⬜ |
| P-6 | Truncated → non-200; animated → pre-transform reject; polyglot → all structural conditions including corrected VP8X flag masks and ordering rules | YES | ⬜ |
| P-7 | Oversized rejected pre-transform; `transform_fetch_attempted=false`; no URL logged | YES | ⬜ |
| P-8 | <100 MB = PASS; 100–<200 MB = INCONCLUSIVE; ≥200 MB or 546 = FAIL | YES | ⬜ |
| P-9 | Raw fetch + bounded stream; no SDK Blob; no base64 | YES | ⬜ |
| P-10 | SHA-256 matches over exact stored bytes | YES | ⬜ |
| P-11 | Method A exactly 404; Method B conclusive absent; event sequence correct; no session mutations | YES | ⬜ |
| P-12 | Non-WebP rejected by byte inspection before storage write | YES | ⬜ |
| P-13 | Latency recorded | NO | ⬜ |
| P-14 | Cost model documented | NO | ⬜ |

**Spike passes if:** All hard-gate criteria satisfied with no INCONCLUSIVE verdicts. An INCONCLUSIVE P-8 result blocks the spike from passing and requires a separate architecture decision before Rev 20.

---

## 12. Fallback Ranking

| Rank | Approach | Trigger |
|------|----------|---------|
| 1 | Cloudflare Images / Image Transformations | Any hard-gate criterion fails |
| 2 | Dedicated background compute (Sharp/libvips) | Cloudflare fails or rejected architecturally |
| 3 | Smaller purpose-built WASM library | Only if hosted CPU budget confirmed sufficient |
| 4 | Client-side processing | Excluded — not acceptable as security boundary |
| 5 | Pure-JS parser | Excluded — validation only, not sanitization |

Fallback to Rank 1 requires a separate Cloudflare spike proposal before any Cloudflare operations are authorized.

---

## 13. Evidence Record

`tools/image-spike/gate2b-evidence-r19-<YYYYMMDDTHHMMSSZ>/`

- `spike-results.md` — ordered result per P-step
- `responses/` — HTTP response headers and body excerpts
- `memory-profile.md` — P-8 checkpoint readings
- `chunk-maps/` — WebP chunk maps from P-3 parser
- `fixture-preflight.md` — ExifTool preflight confirming source metadata

---

## 14. Three-Party Sign-Off

**Phase 1 — Proposal approval**  
Magic phrase: `APPROVED: Gate 2B Rev 19 §1.2 — Feasibility Spike Proposal`

Authorizes: P-0 plan check and artifact drafting (if P-0 passes without upgrade). Does not authorize deployment, transformation requests, storage mutations, Auth user creation, or plan upgrade.

| Party | Status |
|-------|--------|
| Claude | ⬜ pending |
| Codex | ⬜ pending |
| Bill | ⬜ pending |

**Phase 2 — Spike artifact §1.2 review**  
Separate sign-off after spike artifacts are drafted and reviewed. Magic phrase defined at that time.  
Authorizes: deployment, Auth test user creation, and execution of the spike protocol against `hkfrbdpedrxmbsawnbpr`.
