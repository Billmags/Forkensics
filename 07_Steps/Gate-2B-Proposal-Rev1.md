# Gate 2B Proposal — Rev 1 — Hosted magick-wasm Spike on forkensics-dev

**Status:** DRAFT — awaiting three-party approval

**Governance gate:** Three-party approval (Bill + Claude + Codex) required before any cloud operation is executed. The magic words are `APPROVED: Gate 2B Rev 1 — Hosted magick-wasm Spike`.

**Authorized by:** Step 27 Rev 5 §3 Gate 2 Phase B (approved 2026-08-12).

**Blocked on:** Gate 2A full closure (7 remaining evidence items — see §1).

---

## Section 1 — Prerequisites

Gate 2B cannot execute until Gate 2A is fully closed. Gate 2A currently has a **partial pass** verdict (2026-08-13). The following seven evidence items must be completed and recorded in `tools/image-spike/results.md` before this proposal's execution may begin. Approval of this document may proceed before Gate 2A is closed; execution may not.

| # | Remaining Gate 2A Item |
|---|---|
| 1 | Full file-size matrix: 5 MB JPEG, 10 MB JPEG, 5 MB WebP — decode, re-encode, timing measured |
| 2 | Pre-decode header parsing tested with real JPEG and WebP file headers (not only PNG) |
| 3 | Actual decode tests at 19 MP (pass), 20 MP (pass), 21 MP (reject pre-decode) with real image files |
| 4 | Measured peak memory at 20 MP boundary via `Deno.memoryUsage()` RSS delta |
| 5 | Structural metadata removal proof: EXIF, GPS, ICC, XMP, IPTC, comments absent from re-encoded output; verified by parsing output WebP binary |
| 6 | Full bundled function size including WASM (total bundle, not binary alone) |
| 7 | `supabase functions serve` compatibility: static_files load verified through Supabase Edge Runtime, not standalone Deno |

Phase A canonical pixel limit (pending full evidence): **20 MP** (20,000,000 pixels).

Additional prerequisite: Step A (`upload-authorize`) complete and Gate 6 passed — **confirmed 2026-08-13**.

---

## Section 2 — Purpose

Gate 2A demonstrated that `magick-wasm` processes images within spec under local Deno 2.9.5. Gate 2B verifies the same pipeline operates safely within Supabase's hosted V8/Deno Edge Runtime (256 MB memory hard limit, hosted CPU envelope).

**Rationale from Step 27 Rev 5 §3:** Supabase specifically warns that complex image processing above 5 MB can exceed hosted resource limits. A local Phase A pass does not guarantee the hosted 256 MB memory and CPU envelope will accept the same limits. Building Step B (`upload-complete`) TypeScript against a pixel limit that Phase B later rejects forces a code change, a new approval cycle, and potential re-testing. Phase B must pass before Step B implementation begins.

---

## Section 3 — Authorized Cloud Operations

This proposal authorizes **exactly** the following on forkensics-dev:

1. Deploy one disposable Edge Function: `supabase/functions/image-spike/index.ts`
2. Invoke that function via `supabase functions invoke` or `curl` with test payloads from the developer's local machine
3. Read function logs from the Supabase dashboard or CLI
4. Delete `functions/image-spike` immediately after Gate 2B results are recorded

**Not authorized:** deployment of any other function; any schema change; any production data write; any modification to existing forkensics-dev functions.

---

## Section 4 — Spike Function Design

### 4.1 Location

```
supabase/functions/image-spike/index.ts   ← deleted after Gate 2B
```

The function is tagged `DISPOSABLE — Gate 2B only` in its header comment and must not be committed to main after Gate 2B completes.

### 4.2 WASM Loading

```typescript
// Uses static_files pattern validated in Gate 2A Phase A
const wasmPath = new URL("../../_shared/magick.wasm", import.meta.url);
const wasmBytes = await Deno.readFile(wasmPath);
await initializeImageMagick(wasmBytes);
```

`config.toml` entry required (already present from Gate 2A validation):
```toml
[functions.image-spike]
static_files = ["supabase/functions/_shared/magick.wasm"]
```

### 4.3 Request Contract

```
POST /functions/v1/image-spike
Content-Type: image/jpeg | image/webp
Authorization: Bearer <ANON_KEY>
Body: raw image bytes
```

Query parameter: `?label=<test-case-name>` (for log correlation).

### 4.4 Pipeline Executed

1. Record `memBefore = Deno.memoryUsage().rss` (bytes)
2. Parse image file header to extract width × height without full raster decode
3. Compute `pixelCount = width × height`
4. If `pixelCount > 20_000_000` → return `{ accepted: false, reason: "pre_decode_rejected", pixel_count: pixelCount }` immediately; do not invoke WASM decoder
5. Full raster decode via `ImageMagick.read(bytes, ...)`
6. Re-encode to WebP via `image.write(MagickFormat.Webp, ...)`
7. Strip all metadata: EXIF, GPS, ICC, XMP, IPTC, comment profiles
8. Record `memAfter = Deno.memoryUsage().rss`
9. Compute `peakDeltaMb = (memAfter - memBefore) / (1024 * 1024)`
10. Parse output WebP binary; assert zero metadata blocks remain
11. Compute SHA-256 of output bytes (hex)

### 4.5 Response Contract

```json
{
  "label": "test-10mp-jpeg",
  "accepted": true,
  "pixel_count": 10000000,
  "width": 4000,
  "height": 2500,
  "input_size_bytes": 10485760,
  "output_size_bytes": 245000,
  "mem_delta_mb": 52.3,
  "mem_before_rss_mb": 72.1,
  "mem_after_rss_mb": 124.4,
  "timing_ms": 3200,
  "metadata_clean": true,
  "sha256": "abc123..."
}
```

Pre-decode rejection response:
```json
{
  "label": "test-21mp-jpeg",
  "accepted": false,
  "reason": "pre_decode_rejected",
  "pixel_count": 21000000,
  "width": 5250,
  "height": 4000,
  "timing_ms": 12
}
```

---

## Section 5 — Test Matrix

All test images are generated locally by the existing `tools/image-spike/run.ts` script and uploaded to the hosted function via `curl`. No test images are committed to the repo.

| ID | Image | Compressed size | Dimensions | Pixel count | Expected result |
|---|---|---|---|---|---|
| B-01 | Synthetic JPEG | ~5 MB | 2500 × 2000 | 5 MP | Accepted; WebP output; no metadata |
| B-02 | Synthetic JPEG | ~10 MB | 4000 × 2500 | 10 MP | Accepted; WebP output; no metadata |
| B-03 | Synthetic JPEG | ~10 MB | 5000 × 4000 | 20 MP (at limit) | Accepted; WebP output; no metadata; peak memory recorded |
| B-04 | Synthetic JPEG | ~1 MB | 5001 × 4000 | 20.004 MP (over limit) | Pre-decode rejected; no WASM invoked |
| B-05 | Synthetic JPEG | ~1 MB | 10000 × 10000 | 100 MP (pixel bomb) | Pre-decode rejected; no WASM invoked |
| B-06 | Synthetic WebP | ~5 MB | 2500 × 2000 | 5 MP | Accepted; WebP output; no metadata |
| B-07 | Synthetic JPEG | ~10 MB | 6000 × 4000 | 24 MP (well over limit) | Pre-decode rejected; no WASM invoked |

B-03 is the critical measurement: peak memory delta and processing time at the canonical limit.

---

## Section 6 — Pass Criteria

All of the following must hold for Gate 2B to pass:

| Criterion | Threshold | Rationale |
|---|---|---|
| B-01, B-02, B-03, B-06 accepted | 100% | Below 20 MP limit must always succeed |
| B-04, B-05, B-07 pre-decode rejected | 100% | Limit must be enforced; WASM never invoked |
| B-03 peak memory delta | ≤ 186 MB | Same budget established in Phase A (256 MB − 70 MB WASM overhead) |
| B-03 total RSS after | ≤ 220 MB | Leaves 36 MB headroom before hard 256 MB limit |
| B-03 processing time | ≤ 30 seconds | Well within hosted 150-second timeout |
| WASM cold-start time | ≤ 10 seconds | Acceptable first-request latency |
| `metadata_clean` | `true` for all accepted images | No profile leakage in output |
| Function does not crash or OOM | All invocations return HTTP 200 or 4xx | No 5xx or timeout on any test |

---

## Section 7 — Failure Criteria

Any of the following constitutes Gate 2B failure:

- OOM error or function crash on any test case
- B-03 total RSS exceeds 220 MB
- B-03 processing time exceeds 30 seconds
- Any of B-04, B-05, B-07 passes the pre-decode check and reaches WASM decode
- Any accepted output has `metadata_clean: false`
- WASM binary fails to load (`initializeImageMagick` throws)
- `static_files` not found in hosted runtime

**On failure:** stop immediately; record the failure evidence; do not proceed to Step B. A separate proposal revision is required to address the failure (reduced pixel limit, alternative compute path, etc.).

---

## Section 8 — Test Execution Procedure

All commands run from the `WhatAndWhere/` directory on the developer's local machine.

```bash
# 1. Deploy spike function (CLI ≥ 2.7.0 required; confirmed 2.111.0)
supabase functions deploy image-spike --project-ref <forkensics-dev-ref>

# 2. Run test matrix (one call per test case; label logged for correlation)
FUNC_URL="https://<forkensics-dev-ref>.supabase.co/functions/v1/image-spike"
ANON_KEY="<forkensics-dev-anon-key>"

for label in B-01 B-02 B-03 B-04 B-05 B-06 B-07; do
  curl -X POST "$FUNC_URL?label=$label" \
    -H "Authorization: Bearer $ANON_KEY" \
    -H "Content-Type: image/jpeg" \
    --data-binary @"tools/image-spike/test-images/$label.jpg" \
    -o "tools/image-spike/gate2b-$label.json"
done

# 3. Record results in tools/image-spike/gate2b-results.md

# 4. Delete function
supabase functions delete image-spike --project-ref <forkensics-dev-ref>
```

`<forkensics-dev-ref>` and `<forkensics-dev-anon-key>` are obtained from the Supabase dashboard at runtime. Neither is stored in the repo.

---

## Section 9 — Output

Results recorded in `tools/image-spike/gate2b-results.md`:

- Full JSON response for each test case
- Pass/fail verdict per criterion in §6
- Overall Gate 2B verdict: **PASS** or **FAIL**
- If PASS: canonical confirmed pixel limit, peak memory, processing time at limit
- If FAIL: failure evidence and recommended next step

`gate2b-results.md` is committed. Raw JSON response files are not committed (contain anon key URL paths).

---

## Section 10 — Cleanup Verification

After deletion, confirm:

```bash
supabase functions list --project-ref <forkensics-dev-ref>
# image-spike must not appear
```

If deletion fails, manually remove via the Supabase dashboard.

No other cleanup required. The function writes no data and makes no schema changes.

---

## Section 11 — Step B Gate

If Gate 2B passes:

- `tools/image-spike/gate2b-results.md` records the passing verdict with confirmed limits
- Three-party approval for Step B (`upload-complete`) may then be sought in a separate proposal
- The `upload-complete` pixel limit is the **Gate 2B confirmed hosted limit**, not the Phase A local limit (they should match; if they diverge, the hosted limit governs)

Step B TypeScript implementation does **not** begin until that separate Step B proposal is approved by all three parties.

---

## Section 12 — Security Constraints (Carried Forward)

- Secret key never in client code, never in the repo, never sent to Claude
- ANON_KEY used only at runtime via CLI/curl; not stored in any committed file
- `image-spike` function does not write to the database or any storage bucket
- No migration or schema change authorized under this gate
- Three-party governance: Bill + Claude + Codex must all approve before execution

---

## Section 13 — Approval Record

| Party | Status | Notes |
|---|---|---|
| Claude | Approved | Rev 1 authored by Claude |
| Codex | Pending | — |
| Bill | Pending | — |

**Execution is blocked until all three parties approve AND Gate 2A is fully closed.**
