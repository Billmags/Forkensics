# Gate 2B Proposal — Rev 17
# Managed Supabase Image Transformation Feasibility Spike

**Date:** 2026-08-15  
**Status:** DRAFT — awaiting Codex review and three-party approval  
**Predecessor:** Gate-2B-Proposal-Rev16.md Revision 2 (NOT APPROVED — six blockers)  
**Authorized project:** `hkfrbdpedrxmbsawnbpr` (forkensics-dev only)

**Rev 17 blockers closed from Rev 16 R2:**

| # | Blocker | Section changed |
|---|---------|----------------|
| B-1 | Spike function caller-auth contract added: `verify_jwt=true`, service-role JWT preflight, handler `role` check; anon/user callers receive 401/403 | §3.7, §9 spike function spec |
| B-2 | P-1 rewritten: signed transformation URL method; privacy assertion uses unsigned URL (no headers) and anon-key fetch — not the signed URL | P-1 |
| B-3 | P-3 ExifTool assertion corrected: "zero prohibited metadata families" replaces "zero tags"; prohibited families listed explicitly | P-3 |
| B-4 | P-6 polyglot check rewritten: RIFF length validation + bounds-checked chunk traversal + no trailing bytes — replaces ZIP byte scan | P-6 |
| B-5 | Source-header parser defined: 1 MiB cap, Range request, incremental marker/chunk parsing, fail-closed behavior, VP8X animation detection; P-7 logging restricted to boolean `transform_fetch_attempted` | §7, P-7 |
| B-6 | P-11 deletion confirmation tightened: requires exactly HTTP 404 from an authenticated administrative read; 401/403/429/5xx fail the test; bounded retries defined | P-11 |
| Cleanup | Cleanup hardened: full prefix listing with pagination, per-key deletion, re-list confirming zero remaining objects | §3.6 |

---

## 1. Rev 14 and Rev 15 Failure Summary

| Rev | Hypothesis | H-1 result | Root cause |
|-----|-----------|-----------|-----------|
| Rev 14 | WASM init at module top-level | HTTP 546 `WORKER_RESOURCE_LIMIT` | Pre-handler resource exhaustion; no console output, no handler invocation |
| Rev 15 | Lazy init in handler (Promise-cached) | HTTP 546 `WORKER_RESOURCE_LIMIT` | Pre-handler resource exhaustion; Dashboard Edge Function logs = 0; handler never ran |

Both revisions deployed the same 9.3 MB `@imagemagick/magick-wasm` bundle. Supabase defines HTTP 546 as CPU or memory exhaustion; the specific resource is unconfirmed because no ShutdownEvent was emitted. Bundle import and JIT compilation during isolate boot is the leading inference, but remains unproven. The decision to abandon `@imagemagick/magick-wasm` is not contingent on proving the precise resource. No further magick-wasm experiments are authorized.

---

## 2. Hypothesis

**Supabase Storage Image Transformations (imgproxy) can perform the full sanitization contract — decode, re-encode to WebP, and strip all metadata — outside the Edge Function CPU budget.**

The Edge Function becomes a lightweight orchestrator: it validates the input, requests the transformation, byte-verifies the result, hashes it, writes it to `display_storage_path`, deletes the original, and records the ordering of events. No WASM is loaded. No raster is decoded inside the function.

This is a **feasibility spike**, not an implementation. The spike must prove each requirement independently before a Rev 18 implementation proposal is drafted.

---

## 3. Scope and Authorization

### 3.1 Two-Phase Authorization

**Phase 1 — Proposal sign-off (this document):**  
Authorizes:
- The read-only Dashboard plan-eligibility check (P-0)
- If transformations are already included in the current plan: drafting of spike artifacts
- If an upgrade is required: full stop pending separate three-party upgrade approval

**Phase 2 — Spike artifact §1.2 review:**  
Before any deployment or execution, spike artifacts (function code, test scripts, fixture generators) receive a separate three-party static/local review with their own magic phrase. Proposal approval does not satisfy this gate. No cloud operation occurs until Phase 2 sign-off is recorded.

### 3.2 What Phase 1 approval authorizes

- Read-only Dashboard plan check (P-0)
- Spike artifact drafting, contingent on P-0 outcome

### 3.3 What Phase 2 approval authorizes

- Deployment of the spike Edge Function to `hkfrbdpedrxmbsawnbpr` (forkensics-dev only)
- Upload of test fixtures to the `game-media` bucket under `gate2b-r17/<run-id>/`
- Execution of the spike protocol (P-1 through P-14)
- Deletion of all spike objects and the deployed function

### 3.4 What neither phase authorizes

- Changes to `upload-complete`, `upload-authorize`, the V4 schema, or RLS policies
- Any operation against `torkgydbvktqebssfpdi` (forkensics-prod)
- Upgrade of `forkensics-dev` without separate three-party approval
- Session state mutations in the production `upload_sessions` table

### 3.5 Authorized mutations and storage policy

- **Bucket:** `game-media` (existing private bucket)
- **Object prefix:** `gate2b-r17/<run-id>/` where `<run-id>` is a UUID generated at spike start
- **Database:** No `upload_sessions` transitions. If DB fixtures are required for P-11 instrumentation they must use clearly marked test records and be deleted during cleanup.
- **Runtime secrets:** Service-role key and ANON_KEY are runtime environment variables only. Never written to any file, echoed, or logged.

### 3.6 Cleanup protocol (mandatory)

The spike runner script must implement EXIT/INT/TERM traps executing the following in order:

1. Delete the deployed spike Edge Function from `hkfrbdpedrxmbsawnbpr`; confirm deletion via API.
2. **List** all objects under `gate2b-r17/<run-id>/` in `game-media`, paginating through all result pages.
3. **Delete** each enumerated object individually; confirm each deletion.
4. **Re-list** the prefix; require exactly zero objects remaining. If any objects remain, log as cleanup failure and exit non-zero.
5. Delete any DB test fixtures created during the run; confirm deletion.
6. Preserve evidence directory (`gate2b-evidence-r17-<YYYYMMDDTHHMMSSZ>/`) before exiting.

Cleanup runs on normal exit, error exit, and signal interruption. Evidence is preserved regardless of cleanup success or failure.

### 3.7 Spike Function Caller-Auth Contract

The spike Edge Function handles administrative Storage credentials and must restrict invocation to service-role callers only.

**Configuration:** Deploy with `verify_jwt = true` in `config.toml`. Supabase gateway validates the JWT signature and rejects missing or malformed tokens before the handler runs.

**Handler enforcement:** The gateway's `verify_jwt` check does not inspect the `role` claim. The handler must additionally:

1. Read the `Authorization` header (format: `Bearer <jwt>`).
2. Decode the JWT payload (no re-verification required; gateway already verified the signature).
3. Check that the `role` claim equals `service_role`.
4. If `role` is absent, or is `anon`, or is `authenticated`, or is any value other than `service_role`: return HTTP 403 immediately without processing the request.

**Callers that must be rejected with 401/403:**
- Requests with no `Authorization` header (gateway returns 401 before handler)
- Requests signed with the anon key (`role=anon`)
- Requests signed with an authenticated user JWT (`role=authenticated`)
- Any JWT with `role` ≠ `service_role`

**Spike test:** P-1 must include an assertion that an anon-key request is rejected.

---

## 4. WebP Targeting

Supabase Storage Image Transformations select WebP automatically based on the client `Accept` header. `format=origin` disables optimization; no `format=webp` parameter is documented. The spike requests WebP by sending `Accept: image/webp`. P-2 verifies the response at the byte level regardless of `Content-Type`. P-12 verifies detection of a non-WebP response.

---

## 5. Canonical Display Parameters

| Parameter | Value | Basis |
|-----------|-------|-------|
| Longest edge | 2048 px | Within Supabase documented 2500 px limit |
| Resize mode | `contain` | Preserves aspect ratio; no cropping |
| Quality | 80 | Initial value; confirmed or adjusted by P-8 |
| WebP selection | `Accept: image/webp` | Documented client-driven optimization |

---

## 6. Platform Limits (Authoritative)

| Resource | Platform limit | Forkensics safety target |
|----------|---------------|------------------------|
| Edge Function memory | 256 MB | < 100 MB highest observed |
| Edge Function CPU | 2 s | TBD by spike |
| Storage transform input size | 25 MB | Forkensics upload limit: 10 MB (stricter) |
| Storage transform input pixels | 50 MP | `CANONICAL_PIXEL_LIMIT`: 15,500,000 px (stricter) |

Note on P-0: Supabase currently documents Image Transformations as available on Pro and above. The Dashboard check establishes the project's actual current status.

Sources: [Supabase Edge Function limits](https://supabase.com/docs/guides/functions/limits); [Supabase Storage transformation documentation](https://supabase.com/docs/guides/storage/serving/image-transformations).

---

## 7. Source-Header Parser Contract

The spike function must determine input dimensions and animation status from a bounded read of the stored original before issuing any transformation request.

**Read cap:** 1 MiB (1,048,576 bytes) maximum source bytes inspected.

**JPEG inputs:**
- Issue HTTP `Range: bytes=0-1048575` against the stored object.
- Validate that the response honors the Range request (check `Content-Range` response header matches; if absent or mismatched, abort and treat as malformed).
- Parse SOF markers (SOF0, SOF1, SOF2, SOF3, SOF5, SOF6, SOF7, SOF9, SOF10, SOF11) incrementally within the capped bytes to extract width and height.
- Fail-closed: if no SOF marker is found within the 1 MiB cap, reject the input as malformed; do not request a transformation.

**WebP inputs:**
- Issue HTTP `Range: bytes=0-1048575` against the stored object.
- Validate Range response honor as above.
- Parse the RIFF header (bytes 0–11: `RIFF` + size + `WEBP`) to confirm it is a WebP container.
- Read the first chunk FourCC within the RIFF body:
  - `VP8 `: simple lossy — extract dimensions from bitstream header; animation flag = false.
  - `VP8L`: simple lossless — extract dimensions from signature header; animation flag = false.
  - `VP8X`: extended format — read the flags byte; bit 1 (0x02) set means animation present; extract canvas width and height from the VP8X chunk body. Animation flag = true if bit 1 is set.
- Fail-closed: if the chunk structure cannot be parsed within the 1 MiB cap, reject as malformed.

**Fail-closed rule:** Any condition that prevents unambiguous determination of dimensions or animation status within the 1 MiB cap results in rejection. The function must not request a transformation for an input it cannot fully characterize.

**P-7 logging:** Record only the boolean `transform_fetch_attempted` (true/false) and a per-fixture rejection reason string. Never log a signed transformation URL, storage path, or object key.

---

## 8. Memory Model

The function holds only:
1. A bounded header range from the original (≤ 1 MiB per §7)
2. The encoded transformed WebP bytes (bounded by P-9's stream limit)
3. A temporary hash buffer if `crypto.subtle.digest` requires a concrete `ArrayBuffer` copy

Memory measurements use `Deno.memoryUsage()` checkpoint snapshots. Results are reported as "highest observed checkpoint memory (`rss`)," not peak. ShutdownEvent telemetry is recorded if emitted.

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
| F-ANIMATED | Animated WebP (multi-frame, VP8X animation flag set) | P-6 animated-input handling |
| F-EXIF-ROT | JPEG with `Orientation: 6` (90° CW) and embedded GPS | P-4 orientation + P-3 GPS removal |
| F-XMP | WebP with XMP chunk | P-3 XMP removal regression |

**Fixture metadata preflight (required before P-3 execution):** Each source fixture is verified before the spike run using ExifTool to confirm expected metadata is present in the source. A fixture lacking its expected metadata is invalid and must be regenerated before proceeding. Preflight results are recorded in `fixture-preflight.md`.

---

## 10. Spike Protocol

Tests are ordered. A failing hard gate does not prevent recording subsequent results unless noted. All tests require Phase 2 sign-off.

---

### P-0 — Plan Eligibility Gate (hard gate; Phase 1 only; read-only)

**Objective:** Establish whether `hkfrbdpedrxmbsawnbpr` is on a plan that includes Storage Image Transformations.

**Actions:**
1. Check the forkensics-dev project plan in the Supabase Dashboard.
2. Record plan name and whether transformations are included.
3. If not included: document plan required, monthly cost, per-transformation cost. Stop — no artifact drafting until separate upgrade approval.
4. If included: record and proceed to artifact drafting.

**Pass:** Transformations confirmed available on current plan.  
**Stop gate:** Upgrade required — separate three-party approval must be obtained before proceeding.

---

### P-1 — Private-Bucket Transformed Download

**Objective:** Confirm private-bucket transformation succeeds with administrative authorization, and that the object is not accessible without authorization.

**Fixture:** F-SMALL, uploaded to `game-media` under the run prefix.

**Method:**
1. Using the service-role key, generate a **short-lived signed transformation URL** (Supabase signed URL with transformation parameters embedded) for F-SMALL.
2. Fetch the signed URL with `Accept: image/webp`. Record HTTP status and response body.
3. Confirm the equivalent **unsigned** storage URL (no signing parameters, no auth headers) returns non-200.
4. Confirm the equivalent unsigned URL fetched with the **anon key** in the `Authorization` header returns non-200.
5. Confirm a request to the spike function itself with an anon-key JWT returns 403 (§3.7 handler check).

**Assertions:**
- Signed URL with `Accept: image/webp`: HTTP 200, non-empty body
- Unsigned URL, no headers: non-200
- Unsigned URL, anon key: non-200
- Spike function, anon-key JWT: HTTP 403

**Pass:** All assertions satisfied.  
**Fail → Fallback trigger:** Private-bucket transformation requires public access, or anon key can access the signed URL after generation.

---

### P-2 — WebP Output Verification

**Objective:** Confirm `Accept: image/webp` produces RIFF/WebP bytes.

**Fixture:** F-SMALL (JPEG input).

**Method:** Fetch the signed transformation URL with `Accept: image/webp`. Inspect the first 12 bytes of the response body.

**Assertions:**
- `Content-Type` contains `image/webp`
- Bytes 0–3: `52 49 46 46` (`RIFF`)
- Bytes 8–11: `57 45 42 50` (`WEBP`)
- Bytes 0–1 are NOT `FF D8` (JPEG SOI)

**Pass:** All byte-level assertions satisfied.  
**Fail → Fallback trigger:** Response body is original JPEG, or RIFF/WEBP magic not present.

---

### P-3 — Metadata Removal (Independent Parser)

**Objective:** Confirm no prohibited metadata survives in the transformed WebP.

**Pre-condition:** Fixture preflight must confirm source contains expected metadata before the transformation is run.

**Fixtures:** F-EXIF-ROT (EXIF + GPS), F-XMP (XMP chunk).

**Prohibited metadata families:**

| Family | ExifTool group | WebP chunk IDs |
|--------|---------------|---------------|
| EXIF | `EXIF`, `ExifIFD`, `GPS` | `EXIF` |
| GPS | subset of `GPS` ExifTool group | (within EXIF chunk) |
| XMP | `XMP` | `XMP ` (trailing space) |
| IPTC | `IPTC` | (typically within EXIF) |
| ICC profile | `ICC_Profile` | `ICCP` |
| Comments | `Comment` | (VP8X or RIFF-level) |

**Method:**
1. Request transformation of each fixture (signed URL, `Accept: image/webp`).
2. Run `hasWebpMetadata` byte scanner against the transformed output.
3. Run ExifTool against the transformed output; record all tags found. Filter for tags in the prohibited groups listed above.
4. Record the full WebP chunk map (FourCC, size, offset) by parsing the RIFF structure.

**Assertions:**
- `hasWebpMetadata` returns `false`
- ExifTool reports **zero tags in prohibited families** (EXIF, GPS, XMP, IPTC, ICC_Profile, Comment). Structural tags (FileType, ImageWidth, ImageHeight, Megapixels, MIMEType, FileSize) are not prohibited and their presence does not fail this assertion.
- No prohibited chunk IDs appear in the chunk map
- Source-fixture preflight confirmed the prohibited metadata was present before transformation

**Pass:** All assertions satisfied.  
**Fail → Fallback trigger:** Any prohibited tag or chunk survives.

---

### P-4 — EXIF Orientation Applied Before Metadata Removal

**Fixture:** F-EXIF-ROT (JPEG with `Orientation: 6`, coded landscape, requires 90° CW rotation to produce portrait).

**Assertions:**
- Transformed WebP contains no EXIF chunk (passes P-3)
- Output dimensions confirm rotation was baked in: output width < output height

**Pass:** Both assertions satisfied.  
**Fail → Fallback trigger:** Incorrectly oriented output, or orientation metadata retained.

---

### P-5 — Output Dimensions and Aspect Ratio

**Fixtures:** F-DISPLAY (landscape), F-EXIF-ROT (portrait after orientation correction).

**Assertions (per fixture):**
- Longest edge ≤ 2048 px
- Aspect ratio matches input within 1% tolerance
- No upscaling beyond input resolution

**Pass:** All assertions satisfied.  
**Fail → Fallback trigger:** Dimensions incorrect or aspect ratio distorted.

---

### P-6 — Malformed, Truncated, Polyglot, and Animated WebP Inputs

**Predetermined security rules:**

| Input class | Required behavior |
|-------------|-----------------|
| F-MALFORMED (truncated JPEG) | imgproxy must return non-200. Any 200 response fails this test regardless of output content. |
| F-ANIMATED (animated WebP) | The spike function must detect the VP8X animation flag by parsing the stored object's header (§7) and return a rejection **without issuing any transformation request** to imgproxy. Confirmed by `transform_fetch_attempted=false`. First-frame normalization is not elected; a separate proposal is required if the product later elects it. |
| F-POLYGLOT (JPEG + appended ZIP) | Accepted **only if** all four conditions are met: (1) imgproxy returns HTTP 200; (2) bytes 0–3 = `RIFF`, bytes 8–11 = `WEBP`; (3) `RIFF size field + 8 == actual response body length` (no trailing bytes beyond the declared RIFF extent); (4) complete bounds-checked chunk traversal within the RIFF extent finds no prohibited metadata or animation chunks (ANIM, ANMF). If any condition fails, the output is rejected and the test records a fail. |

**WebP structural validation for polyglot detection (condition 3 + 4):**
1. Read bytes 4–7 as a little-endian uint32 → `riff_size`
2. Compute `declared_total = riff_size + 8`
3. Verify `declared_total == actual_body_length`
4. Parse chunks within `bytes[12 .. 12 + riff_size)`:
   - Each chunk: 4-byte FourCC + 4-byte little-endian chunk size + payload; odd-size payloads have 1 padding byte
   - Verify each chunk's bounds fall within the RIFF extent (abort on overrun)
   - Fail if any prohibited FourCC appears: `EXIF`, `ICCP`, `XMP `, `ANIM`, `ANMF`
5. Verify no bytes exist after `declared_total`

**Assertions per fixture:** For each fixture, record HTTP status, whether the predetermined rule was satisfied, and the specific condition that passed or failed.

**Pass:** Each fixture's observed behavior satisfies its predetermined rule.  
**Fail:** Any fixture violates its rule.

---

### P-7 — Oversized Input: Forkensics Pre-Check Gate

**Fixture:** F-REJECT (15,503,100 px, above `CANONICAL_PIXEL_LIMIT`).

**Primary control:**
- The spike function reads header dimensions from the stored original via the bounded parser (§7) before invoking the transformation API
- If `width × height > CANONICAL_PIXEL_LIMIT`, the function returns a rejection response without issuing any transformation request
- Log records `transform_fetch_attempted=false` (and nothing else about the object's path or signed URL)

**Secondary evidence (informational):**
- What does imgproxy return if F-REJECT is submitted directly, bypassing the pre-check? Record HTTP status. Note: Supabase limits are 25 MB and 50 MP — imgproxy will not independently reject F-REJECT at Forkensics' limit.

**Pass:** `transform_fetch_attempted=false` confirmed for F-REJECT; no transformation URL generated or logged.

---

### P-8 — Worst-Case Memory Profile

**Fixture:** F-WORST (≈15.5 MP JPEG near 10 MB encoded).

**Method:** `Deno.memoryUsage()` at five checkpoints (after boot, after transform headers, after body buffered, after hash, after upload). Report as "highest observed checkpoint `rss`." Record ShutdownEvent telemetry if emitted.

**Record:** Transformed WebP byte size; `heapUsed`/`rss`/`external` at each checkpoint; highest `rss`.

**Assertions:**
- HTTP 200 (no 546)
- Highest observed checkpoint `rss` < 100 MB
- No full raster decoded in the function (only ≤ 1 MiB header range + encoded WebP output)
- No base64 encoding

**Pass:** All assertions satisfied, highest `rss` < 100 MB.  
**Warning (not a fail):** 100–200 MB — acceptable at platform limit; revisit parameters before Rev 18.  
**Fail → Fallback trigger:** HTTP 546, or highest `rss` ≥ 200 MB.

---

### P-9 — Bounded Response Handling

**Implementation requirement:** The function must use raw `fetch()` with a streaming body reader and a byte counter. The Supabase SDK `download()` method returns an already-fully-buffered `Blob` and cannot enforce a limit before buffering completes; it must not be used for this operation.

**Proposed maximum transformed-output size:** 5 MB. Configurable constant; confirmed or adjusted by P-8.

**Assertions:**
- A response whose body exceeds the byte limit is aborted before the full body is buffered; the byte counter trips the abort
- A valid response within the limit passes through normally
- No base64 encoding at any point

**Pass:** All assertions satisfied.

---

### P-10 — SHA-256 Over Exact Stored Bytes

**Method:**
1. Buffer transformed bytes via bounded streaming reader
2. Compute SHA-256 over those bytes
3. Upload bytes to `display_storage_path` under the run prefix
4. Download the stored file
5. Compute SHA-256 over downloaded bytes independently
6. Compare

**Assertions:**
- Pre-upload hash equals post-download hash exactly
- No re-encoding or padding during upload

**Pass:** Hashes match.  
**Fail:** Any hash mismatch.

---

### P-11 — Deletion-Before-Advance Ordering (Instrumentation Only)

**Scope:** No `upload_sessions` mutations. The spike records instrumentation events only.

**Method:**
1. Run full pipeline on F-DISPLAY; upload to display path under run prefix.
2. Issue deletion of the original object.
3. **Confirm deletion via authenticated administrative read:** issue a service-role-authorized GET for the original object path. The response must be exactly HTTP 404 (object not found). Any other status — 401, 403, 429, or 5xx — fails the deletion confirmation; do not proceed to the next step.
   - If not 404 on first attempt: retry up to 3 times with 1-second intervals. If 404 is not confirmed after 3 retries, the test fails.
4. After confirmed 404: log `original_delete_confirmed`.
5. Log `would_advance_session`.
6. Confirm event sequence: `display_written` → `original_delete_confirmed` → `would_advance_session`.

**Assertions:**
- Deletion confirmation receives exactly HTTP 404 from an authenticated read
- Non-404 responses (401, 403, 429, 5xx) fail the test
- `original_delete_confirmed` is logged before `would_advance_session`
- No `upload_sessions` row is created, mutated, or transitioned

**Pass:** All assertions satisfied.

---

### P-12 — Non-WebP Response Detection

**Objective:** Confirm non-WebP response is rejected by byte inspection before writing to `display_storage_path`.

**Method:** Inject a mock JPEG response at the point where the function inspects the transformation result. Confirm byte check fires on bytes 0–3 and 8–11.

**Assertions:**
- If bytes 0–3 ≠ `RIFF` or bytes 8–11 ≠ `WEBP`: function rejects and does not write to `display_storage_path`
- Rejection is based on byte inspection, not `Content-Type` alone

**Pass:** Non-WebP response rejected by byte check.

---

### P-13 — Latency (Informational)

**Fixtures:** F-SMALL, F-DISPLAY, F-WORST.

Record: time to transformation response headers; time to full body buffered; total Edge Function wall time.  
**No pass/fail — informational only.**

---

### P-14 — Cost and Plan Confirmation (Informational)

Record: plan name, whether transformations included or billed per-use, per-transformation cost, quota, overage rate.  
**No pass/fail — informational only.**

---

## 11. Success Criteria Matrix

| # | Criterion | Hard gate? | Result |
|---|-----------|-----------|--------|
| P-0 | Plan eligibility confirmed; upgrade separately approved if required | YES (Phase 1 gate) | ⬜ |
| P-1 | Signed URL delivers WebP; unsigned URL and anon key are rejected; anon-JWT spike function call returns 403 | YES | ⬜ |
| P-2 | RIFF/WEBP magic bytes confirmed; not JPEG | YES | ⬜ |
| P-3 | Zero prohibited metadata families (ExifTool + `hasWebpMetadata` + chunk map); source preflight valid | YES | ⬜ |
| P-4 | Orientation baked in; output correctly oriented; no EXIF chunk | YES | ⬜ |
| P-5 | Output dimensions and aspect ratio correct | YES | ⬜ |
| P-6 | Truncated → non-200; animated → pre-transform rejection (`transform_fetch_attempted=false`); polyglot → all four structural conditions pass | YES | ⬜ |
| P-7 | Oversized input rejected by pre-check; `transform_fetch_attempted=false`; no URL logged | YES | ⬜ |
| P-8 | Highest observed `rss` < 100 MB; HTTP 200; no base64 | YES | ⬜ |
| P-9 | Bounded streaming reader; byte limit enforced; no SDK Blob; no base64 | YES | ⬜ |
| P-10 | SHA-256 matches over exact stored bytes | YES | ⬜ |
| P-11 | Deletion confirmed by exactly HTTP 404 from authenticated read; event sequence correct; no session mutations | YES | ⬜ |
| P-12 | Non-WebP response rejected by byte inspection before storage write | YES | ⬜ |
| P-13 | Latency recorded | NO | ⬜ |
| P-14 | Cost model documented | NO | ⬜ |

**Spike passes if:** All hard-gate criteria (P-0 through P-12) satisfied.  
**Spike fails:** Any hard-gate criterion unsatisfied → proceed to Fallback Ranking.

---

## 12. Fallback Ranking

| Rank | Approach | Trigger |
|------|----------|---------|
| 1 | Cloudflare Images / Image Transformations | Any hard-gate criterion fails |
| 2 | Dedicated background compute (Sharp/libvips) | Cloudflare fails or rejected architecturally |
| 3 | Smaller purpose-built WASM library | Only if hosted CPU budget confirmed sufficient |
| 4 | Client-side processing | Excluded — not acceptable as security boundary |
| 5 | Pure-JS parser | Excluded — validation only, not sanitization |

Fallback to Rank 1 requires a separate Cloudflare transformation spike proposal before any Cloudflare operations are authorized.

---

## 13. Evidence Record

`tools/image-spike/gate2b-evidence-r17-<YYYYMMDDTHHMMSSZ>/`

- `spike-results.md` — ordered result per P-step
- `responses/` — HTTP response headers and body excerpts
- `memory-profile.md` — P-8 checkpoint readings
- `chunk-maps/` — WebP chunk maps from P-3 parser
- `fixture-preflight.md` — ExifTool preflight output confirming source metadata

---

## 14. Three-Party Sign-Off

**Phase 1 — Proposal approval**  
Magic phrase: `APPROVED: Gate 2B Rev 17 §1.2 — Feasibility Spike Proposal`

Authorizes: P-0 plan check and artifact drafting (if P-0 passes). Does not authorize deployment, transformation requests, storage mutations, or plan upgrade.

| Party | Status |
|-------|--------|
| Claude | ⬜ pending |
| Codex | ⬜ pending |
| Bill | ⬜ pending |

**Phase 2 — Spike artifact §1.2 review**  
Separate sign-off after spike artifacts are drafted and reviewed. Magic phrase defined at that time.  
Authorizes: deployment and execution of the spike protocol against `hkfrbdpedrxmbsawnbpr`.
