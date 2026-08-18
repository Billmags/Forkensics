# Gate 2B Proposal — Rev 16 Revision 2
# Managed Supabase Image Transformation Feasibility Spike

**Date:** 2026-08-15 (Revision 2)  
**Status:** DRAFT — awaiting Codex review and three-party approval  
**Predecessor:** Gate-2B-Proposal-Rev15.md (APPROVED; hosted run FAIL — H-1 HTTP 546, pre-handler boot failure confirmed by Dashboard Edge Function log count = 0; see hosted run results in `gate2b-s12-evidence-r14/s12-artifact-review.md`)  
**Authorized project:** `hkfrbdpedrxmbsawnbpr` (forkensics-dev only)

**Revision 2 changes from Revision 1:**

| # | Blocker | Section changed |
|---|---------|----------------|
| B-1 | Rev 15 root cause language corrected: "CPU" → "pre-handler resource exhaustion; bundle import/initialization is the leading inference" | §1 |
| B-2 | Two-phase authorization made explicit: proposal sign-off → plan check + artifact drafting; spike §1.2 review → deployment + execution | §3, §12 |
| B-3 | `format=webp` removed (undocumented parameter); P-2 rewritten to use `Accept: image/webp` + RIFF byte verification; P-12 rewritten to use mock non-WebP response | P-2, P-12 |
| B-4 | Authorized mutations and cleanup protocol added: bucket name, key prefix, DB mutation policy, secrets policy, trap requirements, cleanup checklist | §3.3, §3.4 |
| B-5 | P-6 predetermined security rules established: truncated → reject; animated WebP → reject before transform; polyglot → accept only if valid standalone WebP + no trailing payload + passes metadata check | P-6 |
| B-6 | P-8 reworded to "highest observed checkpoint memory"; ShutdownEvent note added. P-9 rewritten to require raw `fetch()` + bounded streaming reader; SDK `download()` exclusion noted | P-8, P-9 |
| B-7 | P-11 session state clarified: feasibility spike records instrumentation events only; no session state mutations | P-11 |
| P-3 | Strengthened: source-fixture metadata preflight required; ExifTool added as independent verification tool | P-3 |

---

## 1. Rev 14 and Rev 15 Failure Summary

| Rev | Hypothesis | H-1 result | Root cause |
|-----|-----------|-----------|-----------|
| Rev 14 | WASM init at module top-level | HTTP 546 `WORKER_RESOURCE_LIMIT` | Pre-handler resource exhaustion; no console output, no handler invocation |
| Rev 15 | Lazy init in handler (Promise-cached) | HTTP 546 `WORKER_RESOURCE_LIMIT` | Pre-handler resource exhaustion; Dashboard Edge Function logs = 0; handler never ran |

Both revisions deployed the same 9.3 MB `@imagemagick/magick-wasm` bundle. Dashboard log evidence from Rev 15 establishes that resource exhaustion occurs during module initialization — before the handler fires — regardless of where `initializeImageMagick()` is called. Supabase defines HTTP 546 as CPU or memory exhaustion; the specific resource cannot be confirmed because no ShutdownEvent was emitted for either invocation. Bundle import and JIT compilation during isolate boot is the leading inference, but this remains unproven. The decision to abandon `@imagemagick/magick-wasm` is not contingent on proving the precise resource; the architecture is rejected regardless.

No further magick-wasm experiments are authorized.

---

## 2. Hypothesis

**Supabase Storage Image Transformations (imgproxy) can perform the full sanitization contract — decode, re-encode to WebP, and strip all metadata — outside the Edge Function CPU budget.**

The Edge Function becomes a lightweight orchestrator: it validates the session and input, requests the transformation, byte-verifies the result, hashes it, writes it to `display_storage_path`, deletes the original, and records the ordering of events. No WASM is loaded. No raster is decoded inside the function.

This is a **feasibility spike**, not an implementation. The spike must prove each requirement independently before a Rev 17 implementation proposal is drafted.

---

## 3. Scope and Authorization

### 3.1 Two-Phase Authorization

This proposal defines two separate authorization gates. Neither can be skipped.

**Phase 1 — Proposal sign-off (this document):**  
Three-party approval of this proposal authorizes:
- The read-only Dashboard plan-eligibility check (P-0)
- If transformations are already included in the current plan: drafting of spike artifacts (spike Edge Function code, test scripts, fixtures)
- If an upgrade is required: a full stop; no artifact drafting and no deployment until a separate upgrade approval is obtained from all three parties

**Phase 2 — Spike artifact §1.2 review:**  
Before any deployment or test execution, the spike artifacts (spike function code, test scripts, fixture generators) must receive their own three-party static/local review. That review is a separate sign-off with its own magic phrase; it is not satisfied by approval of this proposal. No cloud operation — including deploying the spike function — occurs until Phase 2 sign-off is recorded.

### 3.2 What Phase 1 approval authorizes

- The Dashboard plan check (P-0, read-only)
- Drafting of spike artifacts, contingent on P-0 outcome

### 3.3 What Phase 2 approval authorizes (post-artifact review)

- Deployment of the spike Edge Function to `hkfrbdpedrxmbsawnbpr` (forkensics-dev only)
- Upload of test fixtures to the `game-media` bucket under the `gate2b-r16/<run-id>/` prefix
- Execution of the spike protocol (P-1 through P-14)
- Deletion of all spike objects and the deployed function at the conclusion of the run

### 3.4 What neither phase authorizes

- Any changes to the production `upload-complete` function
- Any changes to the V4 schema or RLS policies
- Any changes to `upload-authorize`
- Any changes to or operations on `torkgydbvktqebssfpdi` (forkensics-prod)
- Upgrade of `forkensics-dev` to a paid plan without a separate three-party approval
- Any session state mutations in the production `upload_sessions` table

### 3.5 Authorized mutations and storage policy

- **Bucket:** `game-media` (existing private bucket)
- **Object prefix:** `gate2b-r16/<run-id>/` where `<run-id>` is a UUID generated at spike start; all spike objects live under this prefix
- **Database:** No `upload_sessions` transitions or production record mutations. If DB fixtures are required for P-11 instrumentation, they must use a clearly marked test record and be deleted during cleanup.
- **Runtime secrets:** ANON_KEY and service-role key are runtime environment variables only. Never written to any file, echoed, or logged.

### 3.6 Cleanup protocol (mandatory)

The spike runner script must implement EXIT/INT/TERM traps that execute the following in order:

1. Delete the deployed spike Edge Function from `hkfrbdpedrxmbsawnbpr`; confirm deletion
2. Delete all objects under `gate2b-r16/<run-id>/` in the `game-media` bucket; confirm each deletion
3. Delete any DB test fixtures created during the run; confirm deletion
4. Preserve the evidence directory (`gate2b-evidence-r16-<YYYYMMDDTHHMMSSZ>/`) before exiting

Cleanup must run on normal exit, error exit, and signal interruption. Evidence is preserved regardless of cleanup success or failure.

---

## 4. WebP Targeting

Supabase Storage Image Transformations select WebP automatically based on client `Accept` header support. `format=origin` disables optimization and returns the original format; no `format=webp` parameter is documented.

**The spike requests WebP output by sending `Accept: image/webp` in the transformation request.** P-2 verifies the response at the byte level regardless of `Content-Type`. P-12 verifies that the function detects and rejects a non-WebP response.

---

## 5. Canonical Display Parameters

| Parameter | Value | Basis |
|-----------|-------|-------|
| Longest edge | 2048 px | Within Supabase documented 2500 px transformation limit |
| Resize mode | `contain` | Preserves aspect ratio; no cropping |
| Quality | 80 | Initial value; confirmed or adjusted by P-8 measurement |
| WebP selection | `Accept: image/webp` header | Documented client-driven WebP optimization |

---

## 6. Platform Limits (Authoritative)

| Resource | Platform limit | Forkensics safety target |
|----------|---------------|------------------------|
| Edge Function memory | 256 MB | < 100 MB highest observed |
| Edge Function CPU | 2 s | TBD by spike measurement |
| Storage transform input size | 25 MB | Forkensics upload limit: 10 MB (stricter) |
| Storage transform input pixels | 50 MP | `CANONICAL_PIXEL_LIMIT`: 15,500,000 px (stricter) |

Sources: [Supabase Edge Function limits](https://supabase.com/docs/guides/functions/limits); [Supabase Storage transformation limits](https://supabase.com/docs/guides/storage/serving/image-transformations).

---

## 7. Memory Model

The Edge Function does not hold the decoded raster. imgproxy decodes and encodes internally. The function holds only:

1. A bounded header range read from the original (for MIME and dimension validation) — fixed small buffer
2. The encoded transformed WebP bytes received from imgproxy — variable, driven by output quality and content, not input pixel count
3. A temporary hash buffer if `crypto.subtle.digest` requires a concrete `ArrayBuffer` copy

Memory measurement uses `Deno.memoryUsage()` at defined checkpoints. These are snapshot readings, not continuous peak tracking; results are reported as "highest observed checkpoint memory." ShutdownEvent telemetry is recorded if available to supplement.

---

## 8. Fixtures

| Label | Description | Purpose |
|-------|-------------|---------|
| F-SMALL | 1000×800 JPEG, low noise | Baseline smoke test |
| F-DISPLAY | 2600×2080 JPEG (≈5.4 MP), realistic photo | Nominal display-tier transform |
| F-WORST | Noisy JPEG at/near 15,500,000 px and near 10 MB encoded | P-8 worst-case memory |
| F-REJECT | 5001×3100 JPEG (15,503,100 px, above `CANONICAL_PIXEL_LIMIT`) | P-7 pre-check gate |
| F-MALFORMED | Truncated JPEG at 50% of expected bytes | P-6 malformed-input handling |
| F-POLYGLOT | Valid JPEG with ZIP archive appended after EOI marker | P-6 trailing-data handling |
| F-ANIMATED | Animated WebP (multi-frame) | P-6 animated-input handling |
| F-EXIF-ROT | JPEG with EXIF `Orientation: 6` (90° CW) and embedded GPS coordinates | P-4 orientation + P-3 GPS removal |
| F-XMP | WebP with XMP chunk | P-3 XMP removal regression |

**Fixture metadata preflight (required before P-3):** Each source fixture must be verified before the spike run using ExifTool or equivalent to confirm the expected metadata is present in the source. A fixture that lacks the metadata it is supposed to test is invalid and must be regenerated. Preflight results are recorded in the evidence file.

---

## 9. Spike Protocol

Tests are ordered; a failing hard gate does not prevent recording of subsequent results unless noted. All tests are performed after Phase 2 sign-off.

---

### P-0 — Plan Eligibility Gate (hard gate; read-only; authorized by Phase 1 sign-off)

**Objective:** Confirm whether `hkfrbdpedrxmbsawnbpr` (forkensics-dev) is on a plan that includes Storage Image Transformations.

**Actions:**
1. Check the forkensics-dev project plan in the Supabase Dashboard (read-only).
2. Confirm whether Storage Image Transformations are available on that plan.
3. If not available: document the required plan, monthly cost, and per-transformation cost; stop and request separate three-party upgrade approval.
4. If available: record the plan name and proceed to artifact drafting (no deployment until Phase 2 sign-off).

**Pass:** Transformations confirmed included in current plan.  
**Stop gate:** Upgrade required — no further progress until upgrade approval is obtained.

---

### P-1 — Private-Bucket Transformed Download

**Objective:** Confirm that a private-bucket object can be retrieved as a transformed image using administrative authorization (service-role key), without making the object public or changing bucket policy.

**Fixture:** F-SMALL, uploaded to `game-media` under the run prefix.

**Method:** Invoke the Supabase Storage transformation URL using the service-role key via a signed URL or an authenticated fetch. Do not change bucket visibility or object ACL.

**Assertions:**
- HTTP 200 received
- Response body is non-empty
- Object remains inaccessible via unauthenticated URL (confirm with anon-key fetch → expect non-200)

**Pass:** All assertions satisfied.  
**Fail → Fallback trigger:** Private-bucket transformation requires the bucket or object to be public.

---

### P-2 — WebP Output Verification

**Objective:** Confirm that requesting with `Accept: image/webp` produces actual RIFF/WebP bytes, not the original format.

**Fixture:** F-SMALL (JPEG input).

**Method:** Issue a raw `fetch()` to the transformation URL with `Accept: image/webp`. Inspect response headers and the first 12 bytes of the body.

**Assertions:**
- Response `Content-Type` contains `image/webp`
- Bytes 0–3 of response body are `52 49 46 46` (`RIFF`)
- Bytes 8–11 of response body are `57 45 42 50` (`WEBP`)
- First two bytes of response body are NOT `FF D8` (JPEG SOI marker)

**Pass:** All byte-level assertions satisfied.  
**Fail → Fallback trigger:** Response body is original JPEG despite `Accept: image/webp`, or bytes do not match RIFF/WEBP magic.

---

### P-3 — Metadata Removal (Independent Parser)

**Objective:** Confirm that no EXIF, GPS, ICC, XMP, IPTC, or comment metadata survives in the transformed WebP output.

**Pre-condition:** Source fixture metadata preflight must confirm expected metadata is present before transformation (see §8).

**Fixtures:** F-EXIF-ROT (EXIF + GPS), F-XMP (XMP chunk).

**Method:**
1. Request transformation of each fixture.
2. Run the existing `hasWebpMetadata` byte scanner (checks EXIF, ICCP, XMP chunks).
3. Run ExifTool (or equivalent independent tool) against the transformed WebP output; record all tags found.
4. Record the full WebP chunk map of the output (chunk FourCC, size, offset) for each fixture.

**Assertions:**
- `hasWebpMetadata` returns `false` for all outputs
- ExifTool (or equivalent) reports zero metadata tags in the transformed output
- No GPS, IPTC, EXIF, XMP, ICC, or comment data appears in the chunk map
- Source-fixture preflight confirmed the metadata was present before transformation

**Pass:** All parsers find zero metadata; preflight confirmed source was valid.  
**Fail → Fallback trigger:** Any metadata chunk survives, or ExifTool reports any tag.

---

### P-4 — EXIF Orientation Applied Before Metadata Removal

**Objective:** Confirm that EXIF orientation is baked into the pixel data before metadata is stripped, so the stored display image is correctly oriented.

**Fixture:** F-EXIF-ROT (JPEG with `Orientation: 6`, 90° CW rotation required; coded as landscape).

**Assertions:**
- Transformed WebP contains no EXIF chunk (passes P-3)
- Output width < output height, confirming portrait orientation was applied (rotation baked in)

**Pass:** Both assertions satisfied.  
**Fail → Fallback trigger:** Output is incorrectly oriented (landscape despite Orientation: 6), or metadata is retained.

---

### P-5 — Output Dimensions and Aspect Ratio

**Objective:** Confirm that canonical display parameters (2048 px longest edge, `contain`) produce correct dimensions and preserve aspect ratio.

**Fixtures:** F-DISPLAY (landscape), F-EXIF-ROT (portrait after orientation correction).

**Assertions (F-DISPLAY, e.g., 2600×2080 input):**
- Output longest edge ≤ 2048 px
- Aspect ratio matches input within 1% tolerance
- Output is not upscaled beyond input resolution

**Pass:** All assertions satisfied.  
**Fail → Fallback trigger:** Dimensions incorrect or aspect ratio distorted.

---

### P-6 — Malformed, Truncated, Polyglot, and Animated WebP Inputs

**Objective:** Confirm that each invalid input class is handled according to the predetermined security rule.

**Predetermined security rules:**

| Input class | Required behavior |
|-------------|------------------|
| Truncated JPEG (F-MALFORMED) | Reject — non-200 from imgproxy required. A partial or best-effort image is not acceptable. |
| Animated WebP (F-ANIMATED) | Reject before transformation is requested. The spike function must detect animated WebP by byte inspection (ANIM/ANMF chunk presence) and return a rejection without calling imgproxy. First-frame normalization is not elected for this spike; if the product elects it later, it requires a separate proposal. |
| Polyglot JPEG+ZIP (F-POLYGLOT) | Accepted only if all three conditions are met: (1) imgproxy returns HTTP 200; (2) the output is a valid standalone WebP (passes RIFF/WEBP magic check); (3) the output passes the full metadata removal check (P-3) and contains no ZIP local-file header (`50 4B 03 04`) anywhere in the response body. If any condition fails, the output is rejected. |

**Assertions:** For each fixture, record HTTP status, response body (or error), and whether the predetermined rule was satisfied.

**Pass:** Each fixture's observed behavior satisfies its predetermined rule.  
**Fail:** Any fixture's behavior violates its rule (e.g., truncated JPEG produces a 200; animated WebP is not detected pre-transform; polyglot output fails byte scan).

---

### P-7 — Oversized Input: Forkensics Pre-Check Gate

**Objective:** Confirm that an image above `CANONICAL_PIXEL_LIMIT` (15,500,000 px) is rejected by the spike function before any imgproxy transformation is requested.

**Fixture:** F-REJECT (5001×3100 = 15,503,100 px).

**Primary control (must pass):**
- The spike function reads header dimensions from the stored original before invoking the transformation API
- If `width × height > CANONICAL_PIXEL_LIMIT`, the function returns a rejection response without issuing any request to imgproxy
- Confirm via logging: the transformation URL is never fetched for F-REJECT

**Secondary evidence (informational):**
- What does imgproxy return if F-REJECT is submitted directly, bypassing the pre-check? Record HTTP status and body. Note: Supabase documented limits are 25 MB input and 50 MP — both above Forkensics' limit — so imgproxy will not independently reject F-REJECT.

**Pass:** Primary control confirmed; no transformation API call made for F-REJECT.

---

### P-8 — Worst-Case Memory Profile (S-5a)

**Objective:** Measure highest observed Edge Function memory at each phase of the worst-case transformation pipeline.

**Fixture:** F-WORST (noisy ≈15.5 MP JPEG near 10 MB encoded).

**Transformation parameters:** Canonical display (2048 px, `contain`, quality 80).

**Method:** Call `Deno.memoryUsage()` at each checkpoint. These are snapshot readings, not continuous peak sampling; report as "highest observed checkpoint memory (`rss`)." If a ShutdownEvent is emitted (for any 546 or resource-limit failure), record its telemetry fields.

**Checkpoints:**
1. After spike function boot, before transformation request
2. After transformation response headers received, before body read
3. After full transformed WebP buffered (bounded streaming reader complete)
4. After SHA-256 computed
5. After upload to display path; buffer released

**Record:**
- Transformed WebP byte size
- `heapUsed`, `rss`, `external` at each checkpoint
- Highest `rss` across all checkpoints
- HTTP status (must be 200)

**Assertions:**
- HTTP 200 (no 546)
- Highest observed `rss` < 100 MB (Forkensics safety target)
- Function never reads the full original raster into memory (only bounded header range)
- No base64 encoding of image bytes at any point

**Pass:** All assertions satisfied, highest `rss` < 100 MB.  
**Warning (not a fail):** Highest `rss` 100–200 MB — acceptable relative to platform limit but revisit quality/resize parameters before Rev 17.  
**Fail → Fallback trigger:** HTTP 546, or highest `rss` ≥ 200 MB.

---

### P-9 — Bounded Response Handling (S-5b)

**Objective:** Confirm that the spike function enforces a per-response byte limit before completing the buffer, preventing unbounded allocation if imgproxy returns an unexpectedly large response.

**Implementation requirement:** The function must use a raw `fetch()` with streaming body read and a byte counter; it must not use the Supabase SDK `download()` method, which returns an already-buffered `Blob` and cannot enforce a limit before buffering is complete.

**Proposed maximum transformed-output size:** 5 MB (above any expected WebP output at canonical display parameters; confirmed or adjusted by P-8 measurement). Configurable constant.

**Test method:**
1. Construct a mock response (or use a response URL known to return a large file) that exceeds the configured limit.
2. Confirm the function aborts the read and returns an error without having buffered more than the configured limit.
3. Confirm via a valid response that the byte counter permits normal-sized output through.

**Assertions:**
- A response exceeding the byte limit is aborted before the full body is buffered
- A valid response within the limit is processed normally
- No base64 encoding occurs at any point

**Pass:** All assertions satisfied.

---

### P-10 — SHA-256 Over Exact Stored Bytes

**Objective:** Confirm that the SHA-256 hash computed in the function matches the bytes written to `display_storage_path`.

**Method:**
1. Capture transformed bytes from imgproxy via bounded streaming reader
2. Compute SHA-256 over those bytes
3. Upload those bytes to `display_storage_path` under the run prefix
4. Download the stored file
5. Compute SHA-256 over the downloaded bytes independently
6. Compare hashes

**Assertions:**
- Computed hash before upload equals computed hash over downloaded bytes
- No re-encoding, transformation, or padding occurs during upload

**Pass:** Hashes match exactly.  
**Fail:** Any hash mismatch.

---

### P-11 — Deletion-Before-Advance Ordering (Instrumentation Only)

**Objective:** Confirm that the original stored file is deleted and deletion is confirmed before the session-advance action would be recorded.

**Scope for this feasibility spike:** No `upload_sessions` mutations occur. The spike function records a sequence of ordered instrumentation events rather than advancing real session state.

**Method:**
1. Spike function performs the full pipeline on F-DISPLAY
2. After upload to display path succeeds, issue the deletion of the original under the run prefix
3. Attempt to read the original path — must receive a storage error or 404
4. After confirmed deletion, log the instrumentation event `would_advance_session`
5. Record the event sequence: `display_written` → `original_delete_confirmed` → `would_advance_session`

**Assertions:**
- `original_delete_confirmed` is logged before `would_advance_session`
- Original path is inaccessible at the time `would_advance_session` is logged
- No `upload_sessions` row is created, mutated, or transitioned

**Pass:** Event sequence confirmed; original inaccessible; no session state touched.

---

### P-12 — Non-WebP Response Detection

**Objective:** Confirm that the spike function detects and rejects a non-WebP response by byte inspection, independent of `Content-Type`.

**Method:** Inject a mock or real JPEG response at the point where the function reads the transformation result (or test using a fixture that forces imgproxy to return the original format, if achievable). Confirm the function inspects bytes 0–3 and 8–11 before accepting the response.

**Assertions:**
- If first 4 bytes are not `RIFF` or bytes 8–11 are not `WEBP`, the function rejects the response and does not write to `display_storage_path`
- Rejection is based on byte inspection, not `Content-Type` alone
- `display_storage_path` is not written for a rejected response

**Pass:** Non-WebP response is detected and rejected by byte check.

---

### P-13 — Latency (Informational)

**Objective:** Measure end-to-end wall time for representative fixtures.

**Fixtures:** F-SMALL, F-DISPLAY, F-WORST.

**Measurements:**
- Time from transformation fetch sent to response headers received
- Time from headers received to full body buffered
- Total Edge Function wall time

**Assertions:** None — informational only. Record for UX assessment.

---

### P-14 — Cost and Plan Confirmation (Informational)

**Objective:** Document the cost model for Storage Image Transformations on the plan used.

**Record:** Plan name, monthly cost, whether transformations are included or billed per-use, per-transformation cost if applicable, included quota, overage rate.

**Pass:** Cost model documented.

---

## 10. Success Criteria Matrix

| # | Criterion | Hard gate? | Result |
|---|-----------|-----------|--------|
| P-0 | Plan eligibility confirmed; upgrade separately approved if required | YES (Phase 1 only; blocks artifact drafting) | ⬜ |
| P-1 | Private-bucket transform succeeds with admin auth; object stays private | YES | ⬜ |
| P-2 | RIFF/WEBP magic bytes confirmed in response body; not JPEG | YES | ⬜ |
| P-3 | Zero metadata (ExifTool + `hasWebpMetadata` + chunk map); source preflight confirms metadata was present | YES | ⬜ |
| P-4 | EXIF orientation baked in before metadata removal; output correctly oriented | YES | ⬜ |
| P-5 | Output dimensions and aspect ratio correct | YES | ⬜ |
| P-6 | Truncated → reject; animated → reject pre-transform; polyglot → only if passes all three conditions | YES | ⬜ |
| P-7 | Oversized input rejected by Forkensics pre-check; no imgproxy call made | YES | ⬜ |
| P-8 | Highest observed memory < 100 MB; no 546 | YES | ⬜ |
| P-9 | Bounded streaming reader enforced; no SDK buffered Blob; no base64 | YES | ⬜ |
| P-10 | SHA-256 matches over exact stored bytes | YES | ⬜ |
| P-11 | `original_delete_confirmed` logged before `would_advance_session`; original inaccessible; no session mutations | YES | ⬜ |
| P-12 | Non-WebP response rejected by byte check before `display_storage_path` write | YES | ⬜ |
| P-13 | Latency recorded | NO | ⬜ |
| P-14 | Cost model documented | NO | ⬜ |

**Spike passes if:** All hard-gate criteria (P-0 through P-12) are satisfied.  
**Spike fails:** Any hard-gate criterion unsatisfied → proceed to Fallback Ranking.

---

## 11. Fallback Ranking

| Rank | Approach | Trigger condition |
|------|----------|-----------------|
| 1 | Cloudflare Images / Image Transformations | Any hard-gate criterion fails |
| 2 | Dedicated background compute (Sharp/libvips) | Cloudflare approach fails or is rejected architecturally |
| 3 | Smaller purpose-built WASM library | Only if Supabase CPU budget is confirmed sufficient for a lightweight library |
| 4 | Client-side processing | Not acceptable as security or privacy boundary — excluded |
| 5 | Pure-JS parser | Validation only, not sanitization — excluded as sole processing path |

If Rank 1 is triggered, a separate Cloudflare transformation spike proposal is required before any Cloudflare operations are authorized.

---

## 12. Evidence Record

All spike results recorded in:  
`tools/image-spike/gate2b-evidence-r16-<YYYYMMDDTHHMMSSZ>/`

Structure:
- `spike-results.md` — full ordered result for each P-step
- `responses/` — raw HTTP response headers and body excerpts
- `memory-profile.md` — P-8 checkpoint readings
- `chunk-maps/` — raw WebP chunk maps from P-3 independent parser
- `fixture-preflight.md` — ExifTool output confirming source-fixture metadata before transformation

---

## 13. Three-Party Sign-Off

**Phase 1 — Proposal approval**  
Magic phrase: `APPROVED: Gate 2B Rev 16 §1.2 — Feasibility Spike Proposal`

Authorizes: read-only Dashboard plan check (P-0) and artifact drafting if P-0 passes.  
Does not authorize: any deployment, transformation request, storage mutation, or plan upgrade.

| Party | Status |
|-------|--------|
| Claude | ⬜ pending |
| Codex | ⬜ pending |
| Bill | ⬜ pending |

**Phase 2 — Spike artifact §1.2 review**  
Separate three-party sign-off required after spike artifacts (function code, test scripts, fixture generators) are drafted and reviewed. Magic phrase defined in the artifact review document at that time.

Authorizes: deployment and execution of the spike protocol against `hkfrbdpedrxmbsawnbpr`.
