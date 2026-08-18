c# Gate 2B Proposal — Rev 11 — Pixel Ceiling Discovery Spike on forkensics-dev

**Status:** DRAFT — awaiting three-party approval

**Governance gate:** Three-party approval (Bill + Claude + Codex) required before any cloud operation is executed. The magic words are `APPROVED: Gate 2B Rev 11 — Pixel Ceiling Discovery Spike`.

**Authorized by:** Step 27 Rev 5 §3 Gate 2 Phase B.

**Supersedes:** Gate 2B Rev 10 (DRAFT — 8 runner/fixture blockers identified by Codex; never approved).

**Rev 11 changes from Rev 10 (all 8 Codex blockers addressed):**

1. **Blocker 1 — 546 boundary handling.** `invoke_case` no longer calls `exit 1` on HTTP 546. It sets `LAST_INVOKE_546=true` and returns exit code 2. The survey loop detects code 2, records the boundary, breaks ascent, and proceeds to ceiling selection with data collected so far. A 546 at 5 MP with no viable lower level remains a Gate FAIL.

2. **Blocker 2 — Confirmation telemetry failures fail the gate.** `validate_telemetry` now calls `fail()` on threshold violations in addition to INCONCLUSIVE. Return value is checked by every caller; threshold violations set `GATE2B_PASS=false`.

3. **Blocker 3 — Shutdown reason validated.** `TELEM_REASON` is validated against documented Supabase values. Acceptable (non-resource-limit): `EventLoopCompleted`, `EarlyDrop`, `TerminationRequested`. Resource-limit values `Memory`, `CPUTime`, `WallClockTime` fail the gate regardless of the cpu/memory numbers.

4. **Blocker 4 — Ceiling selection constrained.** Python ceiling-selection script writes `RECOMMENDED_CEILING=<n>` and `VIABLE_LEVELS=<n n n>` to stdout. Bash captures both. Operator may enter only a value that is (a) in VIABLE_LEVELS and (b) ≤ RECOMMENDED_CEILING. Any other entry is a hard stop requiring new three-party decision.

5. **Blocker 5 — JWT preflight restored.** Header segment decoded with correct base64url padding; `alg` must equal `HS256`. Signature segment must be nonempty. `payload.ref` must be nonempty and equal `PROJECT_REF`. Expiration checked with safe int cast.

6. **Blocker 6 — Fixture metadata accurate.** Real IPTC/APP13 block injected in every accepted JPEG. New `gate2b-verify-input-metadata.py` verifies COMMENT, EXIF, GPS, ICC, IPTC, XMP in every JPEG and EXIF, ICC, XMP in the WebP before deployment. C-WEBP byte band enforced (≤ 10 MB). Confirmation fixture preflight (dimensions, sizes, metadata) added after generation.

7. **Blocker 7 — C-REJECT proves pre-decode rejection.** `index.ts` sets `imageDecodeStarted = false` before the decode call and `imageDecodeStarted = true` immediately before invoking ImageMagick. Field is included in every response. Runner asserts `image_decode_started === false` for C-REJECT.

8. **Blocker 8 — Three distinct confirmation fixtures.** C-1 uses `test-C-jpeg-1.jpg` (seed=42), C-2 uses `test-C-jpeg-2.jpg` (seed=43), C-3 uses `test-C-jpeg-3.jpg` (seed=44). All three near the upload ceiling.

**Additional corrections:**

- Section 2: "56 MiB below" corrected (200 MiB is 56 MiB below 256 MiB, not 100 MiB).
- `update_pixel_limit()`: Uses `re.subn()` and requires exactly one substitution.
- `LAST_RUN_ID=""` reset at the top of every `invoke_case` call.
- `gitleaks` added to the required-tool preflight (`for tool in ...` loop).
- §1.2 evidence list: `bash -n gate2b-run-r11.sh` and `python3 -m py_compile` for all scripts required.

---

## Section 1 — Prerequisites

### 1.1 Rev 9 Evidence Required

`tools/image-spike/gate2b-evidence-20260814T194105Z/gate2b-results.md` must be present with SHA-256 `3903f9dc08bb7edc77720911a614a9656ad97b5c9e42a04c9a50d60f3fd1bc4f`. This establishes that 20 MP (293.5 MiB) exceeds the 256 MiB limit and is the baseline for Rev 11.

### 1.2 Pre-Deployment Code Review (blocks deployment, not approval)

Before the runner invokes `supabase functions deploy` for any phase, all three parties must sign off on:

- `supabase/functions/image-spike/index.ts` — survey version (full source; `CANONICAL_PIXEL_LIMIT = 15_500_000`; `imageDecodeStarted` field present)
- `supabase/config.toml` diff (`[functions.image-spike]` section only)
- `tools/image-spike/gate2b-run-r11.sh`
- `tools/image-spike/gate2b-fixtures-r11.py`
- `tools/image-spike/gate2b-verify-metadata.py` (unchanged from Rev 9)
- `tools/image-spike/gate2b-verify-input-metadata.py` (new — §10.3)
- SHA-256 of `tools/image-spike/magick.wasm` and `index.ts` (survey version)
- Local Edge Runtime result (§1.3)
- `deno fmt --check`, `deno lint`, `deno check` — zero findings
- `bash -n tools/image-spike/gate2b-run-r11.sh` — exit 0
- `python3 -m py_compile tools/image-spike/gate2b-fixtures-r11.py` — exit 0
- `python3 -m py_compile tools/image-spike/gate2b-verify-metadata.py` — exit 0
- `python3 -m py_compile tools/image-spike/gate2b-verify-input-metadata.py` — exit 0
- `gitleaks detect` — no findings

### 1.3 Local Edge Runtime Verification

Before Phase S-1 deploys, run `bash tools/image-spike/gate2b-local-test-r11.sh`. S-5 (accepted, `image_decode_started: true`) and a minimal rejection fixture (`image_decode_started: false`) must both pass against the local Edge Runtime.

---

## Section 2 — Purpose

Gate 2B Rev 9 proved 20 MP (5000×4000) exceeds Supabase Edge Runtime's 256 MiB memory ceiling (293.5 MiB peak). Gate 2B Rev 11 finds the highest pixel count that satisfies:

- `memory_used.total` (from ShutdownEvent) ≤ 200 MiB
- `cpu_time_used` (from ShutdownEvent) ≤ 1,500 ms

The 200 MiB threshold is 56 MiB below the 256 MiB runtime limit. The 1,500 ms threshold is 500 ms below the 2,000 ms effective CPU ceiling. This headroom accommodates isolate variance and future WASM growth.

The established ceiling becomes `CANONICAL_PIXEL_LIMIT` enforced server-side and the mandatory upload limit enforced client-side by iOS before any upload.

---

## Section 3 — Authorized Cloud Operations

**Project:** `hkfrbdpedrxmbsawnbpr` (forkensics-dev). No other project ref is authorized.

**Total deployments:** Up to 9 deployments of `image-spike`, in sequence:

| Phase | Deploy | Invocations | Purpose |
|---|---|---|---|
| S-1 | 1 | S-5 (5 MP JPEG) | Survey cold start |
| S-2 | 1 | S-8 (8 MP JPEG) | Survey cold start |
| S-3 | 1 | S-10 (10 MP JPEG) | Survey cold start |
| S-4 | 1 | S-12 (12 MP JPEG) | Survey cold start |
| S-5 | 1 | S-15 (15 MP JPEG) | Survey cold start |
| C-1 | 1 | C-JPEG-1 (seed=42, cold) | Confirmation run 1 |
| C-2 | 1 | C-JPEG-2 (seed=43, cold) | Confirmation run 2 |
| C-3 | 1 | C-JPEG-3 (seed=44, cold) | Confirmation run 3 |
| C-4 | 1 | C-WEBP (cold) → C-REJECT (warm) | Format + rejection |

Each phase: deploy → invoke → delete (confirmed absent) → telemetry gate. The next phase does not deploy until the prior phase's deletion is confirmed. Phases S-1 through S-5 use the survey function (`CANONICAL_PIXEL_LIMIT = 15_500_000`). Phases C-1 through C-4 use the confirmation function (`CANONICAL_PIXEL_LIMIT = <CHOSEN_CEILING_PX>`).

A 546 at survey level N stops ascent; phases S-(N+1) through S-5 do not deploy. Ceiling selection proceeds with data from S-1 through S-(N-1). If N=1 (546 at 5 MP), the run is FAIL — no viable ceiling.

No schema changes, Storage writes, data reads, or modification of any existing function are authorized.

---

## Section 4 — Spike Function Design

### 4.1 Shared Design

`supabase/functions/image-spike/index.ts` — first line: `// DISPOSABLE — Gate 2B only. Delete after results recorded. Do not merge to main.`

WASM loading at module level (unchanged from Rev 9):

```typescript
const wasmBytes = await Deno.readFile(
  new URL("../_shared/magick.wasm", import.meta.url),
);
await initializeImageMagick(wasmBytes);
```

### 4.2 Handler Pipeline

```typescript
Deno.serve(async (req: Request): Promise<Response> => {
  const run_id = crypto.randomUUID();
  const url = new URL(req.url);
  const label = url.searchParams.get("label") ?? "unlabeled";
  console.log(JSON.stringify({ event: "invoke", run_id, label }));

  const mem_before_rss = Deno.memoryUsage().rss;
  const t0 = performance.now();

  const body = new Uint8Array(await req.arrayBuffer());
  const input_size_bytes = body.byteLength;

  // Parse image header (width × height without full decode)
  const { width, height } = parseImageHeader(body);  // minimal header parser
  const pixel_count = width * height;

  let imageDecodeStarted = false;  // set true immediately before WASM decode

  if (pixel_count > CANONICAL_PIXEL_LIMIT) {
    return Response.json({
      run_id, label,
      accepted: false,
      reason: "pre_decode_rejected",
      pixel_count, width, height,
      image_decode_started: imageDecodeStarted,
    });
  }

  imageDecodeStarted = true;  // <- set here, before any ImageMagick call

  const result = await ImageMagick.read(body, async (img) => {
    img.strip();
    // Re-encode to WebP
    return new Promise<Uint8Array>((resolve) => {
      img.write(MagickFormat.WebP, (data) => resolve(data));
    });
  });

  const mem_after_rss = Deno.memoryUsage().rss;
  const wall_time_ms = performance.now() - t0;

  // Verify output (RIFF/WEBP header check)
  const outputValid =
    result[0] === 0x52 && result[1] === 0x49 &&
    result[2] === 0x46 && result[3] === 0x46 &&
    result[8] === 0x57 && result[9] === 0x45 &&
    result[10] === 0x42 && result[11] === 0x50;

  const sha256hex = await sha256(result);
  const output_bytes = btoa(String.fromCharCode(...result));

  return Response.json({
    run_id, label,
    accepted: true,
    image_decode_started: imageDecodeStarted,
    pixel_count, width, height,
    input_size_bytes,
    output_size_bytes: result.byteLength,
    metadata_clean: outputValid,
    sha256: sha256hex,
    output_bytes,
    diagnostic: {
      mem_before_rss_bytes: mem_before_rss,
      mem_after_rss_bytes: mem_after_rss,
      wall_time_ms,
    },
  });
});
```

### 4.3 CANONICAL_PIXEL_LIMIT Values

| Function version | Value | Used in |
|---|---|---|
| Survey | `15_500_000` | Phases S-1 through S-5 |
| Confirmation | `<CHOSEN_CEILING_PX>` | Phases C-1 through C-4 |

### 4.4 config.toml Entry

```toml
[functions.image-spike]
static_files = ["./functions/_shared/magick.wasm"]
```

---

## Section 5 — Test Manifest

### 5.1 Survey Fixtures (JPEG, generated once; full metadata)

| ID | Filename | W | H | Pixels | Min B | Max B | accepted |
|---|---|---|---|---|---|---|---|
| S-5 | test-S-5.jpg | 2500 | 2000 | 5,000,000 | 4,000,000 | 5,500,000 | true |
| S-8 | test-S-8.jpg | 4000 | 2000 | 8,000,000 | 6,500,000 | 9,000,000 | true |
| S-10 | test-S-10.jpg | 4000 | 2500 | 10,000,000 | 8,500,000 | 10,000,000 | true |
| S-12 | test-S-12.jpg | 4000 | 3000 | 12,000,000 | 9,000,000 | 10,000,000 | true |
| S-15 | test-S-15.jpg | 5000 | 3000 | 15,000,000 | 9,000,000 | 10,000,000 | true |

All 6 metadata families: COMMENT, EXIF, GPS, ICC, IPTC, XMP. Verified by `gate2b-verify-input-metadata.py` before deployment.

### 5.2 Confirmation Fixtures (generated after ceiling selected; dimensions = chosen ceiling)

If the ceiling is 10 MP (4000×2500):

| ID | Filename | Format | Seed | Pixels | accepted | Notes |
|---|---|---|---|---|---|---|
| C-JPEG-1 | test-C-jpeg-1.jpg | JPEG | 42 | ceiling_px | true | all 6 families, ≤ 10 MB |
| C-JPEG-2 | test-C-jpeg-2.jpg | JPEG | 43 | ceiling_px | true | all 6 families, ≤ 10 MB |
| C-JPEG-3 | test-C-jpeg-3.jpg | JPEG | 44 | ceiling_px | true | all 6 families, ≤ 10 MB |
| C-WEBP | test-C-webp.webp | WebP | 42 | ceiling_px | true | EXIF/GPS/ICC/XMP, ≤ 10 MB |
| C-REJECT | test-C-reject.jpg | JPEG | — | (cw+1)×ch | false | solid color quality=1; pre_decode_rejected |

`C-REJECT`: width = `ceiling_w + 1`, height = `ceiling_h`, pixel count = `(ceiling_w + 1) × ceiling_h` — exactly one column over the limit.

---

## Section 6 — Pass Criteria

### 6.1 Survey Phase Pass Criteria (per phase S-1 through S-5)

| # | Criterion | Threshold |
|---|---|---|
| S1 | curl exit code | 0 |
| S2 | HTTP status | 200 (546 stops ascent; see §7) |
| S3 | `accepted` | true |
| S4 | `label` | matches fixture ID |
| S5 | `run_id` | valid UUID |
| S6 | `width`, `height`, `pixel_count` | match manifest |
| S7 | `input_size_bytes` | equals `wc -c` of fixture |
| S8 | `metadata_clean` | true |
| S9 | `image_decode_started` | true |
| S10 | `output_bytes` decodes to valid WebP | RIFF/WEBP header |
| S11 | SHA-256 recomputed from `output_bytes` | matches `sha256` |
| S12 | `output_size_bytes` | equals decoded byte count |
| S13 | RIFF chunk parser | EXIF, ICCP, XMP absent |
| S14 | Cold-start wall time | ≤ 30 s |
| S15 | Bundle size | ≤ 20 MB |
| S16 | `cpu_time_used` (ShutdownEvent) | ≤ 1,500 ms |
| S17 | `memory_used.total` (ShutdownEvent, ÷ 1,048,576) | ≤ 200 MiB |
| S18 | `shutdown_reason` (ShutdownEvent) | `EventLoopCompleted`, `EarlyDrop`, or `TerminationRequested` |

A survey level failing S16, S17, or S18 is recorded as non-viable but does not stop the survey unless HTTP 546 occurred (Blocker 1 fix). Functional failures (S1–S15) are accumulated; the level is non-viable.

### 6.2 Ceiling Selection Criterion

A survey level is **viable** if and only if: S1–S15 all pass AND S16 (cpu ≤ 1,500 ms) AND S17 (mem ≤ 200 MiB) AND S18 (reason not a resource-limit value). The **selected ceiling** is the highest viable level.

### 6.3 Confirmation Phase Pass Criteria

| # | Criterion | Threshold |
|---|---|---|
| C1 | C-JPEG-1,2,3 and C-WEBP: S1–S15 and S18 | Same thresholds |
| C2 | C-JPEG-1,2,3 and C-WEBP: `cpu_time_used` | ≤ 1,500 ms |
| C3 | C-JPEG-1,2,3 and C-WEBP: `memory_used.total` | ≤ 200 MiB |
| C4 | C-REJECT: `accepted` | false |
| C5 | C-REJECT: `reason` | `pre_decode_rejected` |
| C6 | C-REJECT: `image_decode_started` | false |
| C7 | C-REJECT: `pixel_count` | `(ceiling_w + 1) × ceiling_h` |

---

## Section 7 — Failure and Inconclusive Definitions

**Hard failures (runner exits immediately):**
- HTTP 401 or 403 in any phase
- HTTP 546 at survey level 5 MP with no viable lower level
- Bundle size > 20 MB or unparseable
- JWT preflight failure
- Any deletion fails to confirm (function still listed after delete)
- No survey level satisfies both thresholds
- Ceiling approval outside permitted range (> RECOMMENDED_CEILING or not in VIABLE_LEVELS)

**Survey 546 boundary (not a hard stop):**
- HTTP 546 at level N where N > 5 MP: record boundary, break ascent, proceed to ceiling selection. Levels already tested remain in VIABLE or non-viable as appropriate.

**Soft failures (accumulated):**
- Any non-546 HTTP error; any functional assertion miss; shutdown_reason is a resource-limit value

**INCONCLUSIVE (treated as FAIL):**
- `execution_id` not a valid UUID; ShutdownEvent not found; `cpu_time_used` or `memory_used.total` absent or non-numeric; operator enters `INCONCLUSIVE`

---

## Section 8 — Telemetry Methodology

### 8.1 Per-Phase Isolation Protocol

1. Invoke the fixture as the sole first request for that deployment.
2. Record `run_id` from the response body.
3. Function emits `console.log(JSON.stringify({ event: "invoke", run_id, label }))`.
4. Delete the function (`delete_confirmed()`). Logs persist independently.
5. Runner pauses at the telemetry gate; operator performs two-step lookup (§8.2).
6. Operator enters `execution_id`, `cpu_time_used`, `memory_used.total`, `shutdown_reason`.
7. Runner validates and records.

### 8.2 Two-Step Log Lookup (unchanged from Rev 10)

**Step 1:** Open `https://supabase.com/dashboard/project/hkfrbdpedrxmbsawnbpr/logs/edge-logs`. Filter `metadata.function_id = 'image-spike'`. Search for `run_id`. Find entry with `"event":"invoke"` and matching label. Record `execution_id`.

**Step 2:** Search for `execution_id`. Locate ShutdownEvent. Extract `cpu_time_used` (no `_ms`), `memory_used.total` in bytes, and `reason`. Do NOT use WorkerMemoryUsed or Metrics UI.

### 8.3 Valid Shutdown Reasons

| `reason` value | Category | Gate effect |
|---|---|---|
| `EventLoopCompleted` | Normal | Acceptable |
| `EarlyDrop` | Normal | Acceptable |
| `TerminationRequested` | Normal (redeployment) | Acceptable |
| `Memory` | Resource limit | FAIL |
| `CPUTime` | Resource limit | FAIL |
| `WallClockTime` | Resource limit | FAIL |
| Any other value | Unknown | FAIL (treat as resource limit) |

Reference: [Supabase Edge Function Shutdown Reasons](https://supabase.com/docs/guides/troubleshooting/edge-function-shutdown-reasons-explained)

---

## Section 9 — Ceiling Selection Algorithm

After all survey phases complete (or survey stops at a 546 boundary), the runner executes:

```python
MP_LEVELS = [5, 8, 10, 12, 15]
DIMS = {5: (2500,2000,5000000), 8: (4000,2000,8000000),
        10: (4000,2500,10000000), 12: (4000,3000,12000000),
        15: (5000,3000,15000000)}
MEM_THR = 200.0   # MiB
CPU_THR = 1500.0  # ms
MIB = 1_048_576
RESOURCE_REASONS = {"Memory", "CPUTime", "WallClockTime"}

viable = []
for mp in MP_LEVELS:
    cpu = survey_cpu.get(mp)    # float or None
    mem = survey_mem.get(mp)    # bytes float or None
    reason = survey_reason.get(mp, "")
    if cpu is None or mem is None:
        continue
    if reason in RESOURCE_REASONS:
        continue
    if mem / MIB <= MEM_THR and cpu <= CPU_THR:
        viable.append(mp)

# Print machine-parseable output for bash capture
print(f"RECOMMENDED_CEILING={max(viable) if viable else 'NONE'}")
print(f"VIABLE_LEVELS={' '.join(str(m) for m in viable)}")
```

Bash captures `RECOMMENDED_CEILING` and `VIABLE_LEVELS`. Operator must enter a value that is:
1. A number present in `VIABLE_LEVELS`, AND
2. ≤ `RECOMMENDED_CEILING`

Any deviation exits with a message requiring new three-party decision.

---

## Section 10 — Supporting Scripts

### 10.1 gate2b-verify-metadata.py

Unchanged from Rev 9. Verifies WebP output contains no EXIF, ICCP, or XMP chunks.

### 10.2 gate2b-fixtures-r11.py

Full revised source. Key changes from Rev 10: real IPTC/APP13 injection; three distinct confirmation JPEGs (seeds 42/43/44); C-WEBP byte-band enforcement (≤ 10 MB).

```python
#!/usr/bin/env python3
"""gate2b-fixtures-r11.py — Rev 11 fixture generator.
Usage:
  python3 gate2b-fixtures-r11.py <out_dir>                              # survey
  python3 gate2b-fixtures-r11.py <out_dir> confirm <cw> <ch> <cx>      # confirmation
"""
import sys, os, io, struct, hashlib
import numpy as np
from PIL import Image
import piexif

SURVEY = [
    # (id, w, h, pixels, min_bytes, max_bytes, quality_start)
    ("S-5",  2500, 2000,  5_000_000,  4_000_000,  5_500_000, 91),
    ("S-8",  4000, 2000,  8_000_000,  6_500_000,  9_000_000, 90),
    ("S-10", 4000, 2500, 10_000_000,  8_500_000, 10_000_000, 92),
    ("S-12", 4000, 3000, 12_000_000,  9_000_000, 10_000_000, 85),
    ("S-15", 5000, 3000, 15_000_000,  9_000_000, 10_000_000, 72),
]
UPLOAD_CEIL = 10_000_000

# ---------------------------------------------------------------------------
# IPTC / APP13 injection
# ---------------------------------------------------------------------------
def _iptc_app13() -> bytes:
    """Construct a valid JPEG APP13 block containing an IPTC-NAA resource."""
    # IPTC Record 2, Dataset 120 (Caption/Abstract)
    caption = b"Gate2B-Rev11-IPTC-Test"
    ds120 = b"\x1c\x02\x78" + struct.pack(">H", len(caption)) + caption
    # IPTC Record 2, Dataset 080 (By-line / Creator)
    byline = b"ForkensicsSpike"
    ds080 = b"\x1c\x02\x50" + struct.pack(">H", len(byline)) + byline
    iptc_data = ds120 + ds080
    # Photoshop 3.0 / 8BIM container for IPTC-NAA (resource ID 0x0404 = 1028)
    ps_hdr  = b"Photoshop 3.0\x00"
    bim_id  = b"8BIM\x04\x04\x00\x00"          # resource ID + empty pascal-string name
    bim_len = struct.pack(">I", len(iptc_data))
    bim_block = bim_id + bim_len + iptc_data
    if len(bim_block) % 2:
        bim_block += b"\x00"                     # pad to even length
    app13_payload = ps_hdr + bim_block
    app13_len = struct.pack(">H", 2 + len(app13_payload))
    return b"\xff\xed" + app13_len + app13_payload

# ---------------------------------------------------------------------------
# Metadata builders
# ---------------------------------------------------------------------------
def _exif_bytes() -> bytes:
    exif = {
        "0th": {
            piexif.ImageIFD.Make:     b"ForkensicsTest",
            piexif.ImageIFD.Model:    b"Rev11",
            piexif.ImageIFD.Software: b"gate2b-fixtures-r11",
        },
        "Exif": {
            piexif.ExifIFD.ExposureTime: (1, 100),
            piexif.ExifIFD.FNumber:      (28, 10),
        },
        "GPS": {
            piexif.GPSIFD.GPSLatitudeRef:  b"N",
            piexif.GPSIFD.GPSLatitude:     ((37,1),(46,1),(30,1)),
            piexif.GPSIFD.GPSLongitudeRef: b"W",
            piexif.GPSIFD.GPSLongitude:    ((122,1),(25,1),(0,1)),
        },
        "1st": {},
        "thumbnail": None,
    }
    return piexif.dump(exif)

def _icc_profile() -> bytes:
    """Minimal 48-byte ICC profile stub (acsp signature)."""
    size = 48
    return size.to_bytes(4, "big") + b"acsp" + b"\x00" * (size - 8)

def _xmp_bytes() -> bytes:
    return (b'<?xpacket begin="\xef\xbb\xbf" id="W5M0MpCehiHzreSzNTczkc9d"?>\n'
            b'<x:xmpmeta xmlns:x="adobe:ns:meta/">'
            b'<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"/>'
            b'</x:xmpmeta>'
            b'<?xpacket end="w"?>')

_XMP_APP1_NS = b"http://ns.adobe.com/xap/1.0/\x00"

def _inject_app1_xmp(jpeg_bytes: bytes) -> bytes:
    """Insert XMP APP1 marker after the SOI marker (first 2 bytes)."""
    xmp = _xmp_bytes()
    marker_len = struct.pack(">H", 2 + len(_XMP_APP1_NS) + len(xmp))
    xmp_app1 = b"\xff\xe1" + marker_len + _XMP_APP1_NS + xmp
    return jpeg_bytes[:2] + xmp_app1 + jpeg_bytes[2:]

def _comment_marker(text: bytes = b"Gate2B-Rev11-COMMENT") -> bytes:
    marker_len = struct.pack(">H", 2 + len(text))
    return b"\xff\xfe" + marker_len + text

def _inject_comment(jpeg_bytes: bytes) -> bytes:
    """Insert JPEG COMMENT marker (FF FE) after SOI."""
    comment = _comment_marker()
    return jpeg_bytes[:2] + comment + jpeg_bytes[2:]

# ---------------------------------------------------------------------------
# Image builder
# ---------------------------------------------------------------------------
def _noise_image(w: int, h: int, seed: int = 42) -> Image.Image:
    rng = np.random.default_rng(seed=seed)
    arr = rng.integers(0, 256, (h, w, 3), dtype=np.uint8)
    return Image.fromarray(arr, "RGB")

def _write_jpeg_full(img: Image.Image, quality: int, path: str) -> int:
    """Save JPEG with all 6 metadata families: EXIF, GPS, ICC, XMP, IPTC, COMMENT."""
    exif_b = _exif_bytes()
    icc_b  = _icc_profile()
    buf = io.BytesIO()
    img.save(buf, "JPEG", quality=quality, exif=exif_b, icc_profile=icc_b)
    raw = buf.getvalue()
    # Inject XMP APP1, COMMENT, and IPTC APP13
    raw = _inject_app1_xmp(raw)
    raw = _inject_comment(raw)
    # IPTC: inject after SOI (before other markers)
    iptc = _iptc_app13()
    raw = raw[:2] + iptc + raw[2:]
    with open(path, "wb") as f:
        f.write(raw)
    return len(raw)

def _write_webp_full(img: Image.Image, quality: int, path: str) -> int:
    """Save WebP with EXIF, GPS, ICC, XMP in RIFF chunks."""
    exif_b = _exif_bytes()
    icc_b  = _icc_profile()
    buf = io.BytesIO()
    img.save(buf, "WEBP", quality=quality, exif=exif_b, icc_profile=icc_b)
    raw = buf.getvalue()
    # Inject XMP chunk into RIFF WebP
    xmp = _xmp_bytes()
    padded_xmp = xmp if len(xmp) % 2 == 0 else xmp + b"\x00"
    xmp_chunk = b"XMP " + len(xmp).to_bytes(4, "little") + padded_xmp
    # Append XMP chunk before RIFF container ends
    new_raw = raw[:-0] + xmp_chunk  # append at end (valid RIFF)
    # Recalculate RIFF size field
    new_riff_size = len(new_raw) - 8
    new_raw = new_raw[:4] + new_riff_size.to_bytes(4, "little") + new_raw[8:]
    with open(path, "wb") as f:
        f.write(new_raw)
    return len(new_raw)

# ---------------------------------------------------------------------------
# Survey generation
# ---------------------------------------------------------------------------
def generate_survey(out_dir: str) -> None:
    os.makedirs(out_dir, exist_ok=True)
    print("Gate 2B Rev 11 survey fixture generation (deterministic, seed=42) ...")
    all_ok = True
    for sid, w, h, px, lo, hi, q_start in SURVEY:
        filename = f"test-{sid}.jpg"
        path = os.path.join(out_dir, filename)
        img = _noise_image(w, h, seed=42)
        q = q_start
        while q >= 50:
            size = _write_jpeg_full(img, q, path)
            if lo <= size <= hi and size <= UPLOAD_CEIL:
                break
            q -= 3
        if q < 50:
            print(f"FATAL: {sid} cannot fit in band [{lo}, {hi}]", file=sys.stderr)
            sys.exit(1)
        sha = hashlib.sha256(open(path, "rb").read()).hexdigest()
        ok  = "✓" if lo <= size <= hi else "FAIL"
        print(f"\n--- {sid} ({w}x{h}, jpeg) ---")
        print(f"  quality={q}  size={size:,} bytes ({size/1e6:.3f} MB)  sha256={sha[:32]}...")
        print(f"  band=[{lo:,},{hi:,}]  {ok}")
        if ok != "✓":
            all_ok = False
    if not all_ok:
        sys.exit(1)
    print("\n=== Survey fixtures generated ===")

# ---------------------------------------------------------------------------
# Confirmation generation
# ---------------------------------------------------------------------------
def generate_confirmation(out_dir: str, cw: int, ch: int, cp: int) -> None:
    os.makedirs(out_dir, exist_ok=True)
    img42 = _noise_image(cw, ch, seed=42)
    img43 = _noise_image(cw, ch, seed=43)
    img44 = _noise_image(cw, ch, seed=44)

    # C-JPEG-1,2,3 (seeds 42, 43, 44)
    for i, (img, seed) in enumerate([(img42,42),(img43,43),(img44,44)], start=1):
        path = os.path.join(out_dir, f"test-C-jpeg-{i}.jpg")
        q = 85
        while q >= 50:
            size = _write_jpeg_full(img, q, path)
            if size <= UPLOAD_CEIL:
                break
            q -= 3
        sha = hashlib.sha256(open(path,"rb").read()).hexdigest()
        print(f"C-JPEG-{i} (seed={seed}): {cw}x{ch}={cp:,}px  {size:,}B  sha256={sha[:16]}...")

    # C-WEBP (seed=42, ≤ 10 MB)
    webp_path = os.path.join(out_dir, "test-C-webp.webp")
    q = 90
    while q >= 40:
        size_w = _write_webp_full(img42, q, webp_path)
        if size_w <= UPLOAD_CEIL:
            break
        q -= 5
    if size_w > UPLOAD_CEIL:
        print(f"FATAL: C-WEBP {size_w} > {UPLOAD_CEIL}", file=sys.stderr); sys.exit(1)
    sha_w = hashlib.sha256(open(webp_path,"rb").read()).hexdigest()
    print(f"C-WEBP (seed=42): {cw}x{ch}={cp:,}px  {size_w:,}B  sha256={sha_w[:16]}...")

    # C-REJECT (ceiling_w+1, solid color, quality=1, tiny)
    reject_w = cw + 1
    reject_path = os.path.join(out_dir, "test-C-reject.jpg")
    solid = Image.new("RGB", (reject_w, ch), (30, 60, 90))
    solid.save(reject_path, "JPEG", quality=1)
    size_r = os.path.getsize(reject_path)
    print(f"C-REJECT: {reject_w}x{ch}={reject_w*ch:,}px  {size_r:,}B")

    print("\n=== Confirmation fixtures generated ===")

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__); sys.exit(1)
    out = sys.argv[1]
    if len(sys.argv) == 6 and sys.argv[2] == "confirm":
        generate_confirmation(out, int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5]))
    else:
        generate_survey(out)
```

### 10.3 gate2b-verify-input-metadata.py (new)

Verifies required metadata families exist in each input fixture before deployment.

```python
#!/usr/bin/env python3
"""gate2b-verify-input-metadata.py — verify input fixtures contain required metadata.
Usage:
  python3 gate2b-verify-input-metadata.py jpeg <path>   # checks COMMENT,EXIF,GPS,ICC,IPTC,XMP
  python3 gate2b-verify-input-metadata.py webp <path>   # checks EXIF,ICC,XMP
Exit 0 if all families present; exit 1 otherwise.
"""
import sys, os

def _has_jpeg_marker(data: bytes, marker: bytes) -> bool:
    return marker in data

def verify_jpeg(path: str) -> bool:
    from PIL import Image
    import piexif
    try:
        with Image.open(path) as im:
            exif_raw = im.info.get("exif", b"")
            icc_raw  = im.info.get("icc_profile", b"")
    except Exception as e:
        print(f"FAIL {path}: cannot open: {e}"); return False
    with open(path, "rb") as f:
        data = f.read()
    has_exif = bool(exif_raw)
    has_icc  = bool(icc_raw)
    has_xmp  = (b"http://ns.adobe.com/xap/1.0/\x00" in data or
                b"<x:xmpmeta" in data)
    has_iptc = b"\xff\xed" in data          # APP13 marker
    has_comment = b"\xff\xfe" in data       # JPEG COMMENT marker
    has_gps = False
    if has_exif:
        try:
            exif = piexif.load(exif_raw)
            has_gps = bool(exif.get("GPS"))
        except Exception:
            pass
    families = {
        "EXIF":    has_exif,
        "GPS":     has_gps,
        "ICC":     has_icc,
        "IPTC":    has_iptc,
        "XMP":     has_xmp,
        "COMMENT": has_comment,
    }
    missing = [k for k, v in families.items() if not v]
    if missing:
        print(f"FAIL {os.path.basename(path)}: missing: {missing}")
        return False
    print(f"OK   {os.path.basename(path)}: {list(families)}")
    return True

def verify_webp(path: str) -> bool:
    with open(path, "rb") as f:
        data = f.read()
    has_exif = b"EXIF" in data
    has_icc  = b"ICCP" in data
    has_xmp  = b"XMP " in data
    families = {"EXIF": has_exif, "ICC": has_icc, "XMP": has_xmp}
    missing = [k for k, v in families.items() if not v]
    if missing:
        print(f"FAIL {os.path.basename(path)}: missing: {missing}")
        return False
    print(f"OK   {os.path.basename(path)}: {list(families)}")
    return True

if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(__doc__); sys.exit(1)
    fmt, path = sys.argv[1], sys.argv[2]
    if not os.path.exists(path):
        print(f"FAIL: {path} not found"); sys.exit(1)
    ok = verify_jpeg(path) if fmt == "jpeg" else verify_webp(path)
    sys.exit(0 if ok else 1)
```

---

## Section 11 — Runner: gate2b-run-r11.sh

```bash
#!/usr/bin/env bash
# tools/image-spike/gate2b-run-r11.sh — Gate 2B Rev 11 test runner
# DISPOSABLE — Gate 2B only. Execute only after three-party approval of Rev 11.
#
# Usage: PROJECT_REF=hkfrbdpedrxmbsawnbpr ANON_KEY=yyy bash tools/image-spike/gate2b-run-r11.sh
# ANON_KEY is never written to disk, echoed, or logged.
# Exits 0 on full PASS; exits 1 on FAIL, INCONCLUSIVE, or no viable ceiling.

set -uo pipefail
# -e intentionally absent: EXIT trap handles all paths.

# ---------------------------------------------------------------------------
# Environment validation
# ---------------------------------------------------------------------------
APPROVED_PROJECT_REF="hkfrbdpedrxmbsawnbpr"
[[ -n "${PROJECT_REF:-}" ]] || { echo "FATAL: PROJECT_REF not set" >&2; exit 1; }
[[ "$PROJECT_REF" == "$APPROVED_PROJECT_REF" ]] \
  || { echo "FATAL: PROJECT_REF must be '$APPROVED_PROJECT_REF'; got '$PROJECT_REF'" >&2; exit 1; }
[[ -n "${ANON_KEY:-}" ]] || { echo "FATAL: ANON_KEY not set" >&2; exit 1; }

# ---------------------------------------------------------------------------
# JWT preflight — full validation (Rev 11 restored)
# ---------------------------------------------------------------------------
python3 - <<'PYEOF' || { echo "FATAL: ANON_KEY failed JWT preflight" >&2; exit 1; }
import sys, base64, json, os, time

def b64url_decode(s: str) -> bytes:
    s += "=" * (4 - len(s) % 4)
    return base64.urlsafe_b64decode(s)

key = os.environ.get("ANON_KEY", "")
ref = os.environ.get("PROJECT_REF", "")

parts = key.split(".")
if len(parts) != 3:
    print(f"FATAL: ANON_KEY has {len(parts)} segment(s), expected 3", file=sys.stderr)
    sys.exit(1)
if not parts[2]:
    print("FATAL: ANON_KEY signature segment is empty", file=sys.stderr)
    sys.exit(1)

# Decode header
try:
    header = json.loads(b64url_decode(parts[0]))
except Exception as e:
    print(f"FATAL: ANON_KEY header decode failed: {e}", file=sys.stderr); sys.exit(1)
alg = header.get("alg", "")
if alg != "HS256":
    print(f"FATAL: ANON_KEY alg='{alg}', expected 'HS256'", file=sys.stderr); sys.exit(1)

# Decode payload
try:
    payload = json.loads(b64url_decode(parts[1]))
except Exception as e:
    print(f"FATAL: ANON_KEY payload decode failed: {e}", file=sys.stderr); sys.exit(1)
role = payload.get("role", "")
if role != "anon":
    print(f"FATAL: ANON_KEY role='{role}', expected 'anon'", file=sys.stderr); sys.exit(1)
jwt_ref = payload.get("ref", "")
if not jwt_ref:
    print("FATAL: ANON_KEY payload missing 'ref'", file=sys.stderr); sys.exit(1)
if jwt_ref != ref:
    print(f"FATAL: ANON_KEY ref='{jwt_ref}' != PROJECT_REF='{ref}'", file=sys.stderr); sys.exit(1)
exp = payload.get("exp")
if exp is None:
    print("FATAL: ANON_KEY payload missing 'exp'", file=sys.stderr); sys.exit(1)
try:
    exp_int = int(exp)
except (TypeError, ValueError):
    print(f"FATAL: ANON_KEY exp non-integer: {exp!r}", file=sys.stderr); sys.exit(1)
now = int(time.time())
if exp_int <= now:
    print(f"FATAL: ANON_KEY expired (exp={exp_int}, now={now})", file=sys.stderr); sys.exit(1)

print(f"ANON_KEY preflight: HS256, role=anon, ref={jwt_ref} ✓")
PYEOF

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WASM_SRC="$REPO_ROOT/tools/image-spike/magick.wasm"
WASM_DST="$REPO_ROOT/supabase/functions/_shared/magick.wasm"
CONFIG="$REPO_ROOT/supabase/config.toml"
SPIKE_DIR="$REPO_ROOT/supabase/functions/image-spike"
IMG_DIR="$REPO_ROOT/tools/image-spike/test-images-r11"
FIXTURES_PY="$SCRIPT_DIR/gate2b-fixtures-r11.py"
VERIFY_OUT_PY="$SCRIPT_DIR/gate2b-verify-metadata.py"
VERIFY_IN_PY="$SCRIPT_DIR/gate2b-verify-input-metadata.py"

TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RESULTS_DIR="$REPO_ROOT/tools/image-spike/gate2b-evidence-r11-${TIMESTAMP}"
OUT_DIR="$RESULTS_DIR/responses"
RESULTS_MD="$RESULTS_DIR/gate2b-results.md"

FUNC_URL="https://${PROJECT_REF}.supabase.co/functions/v1/image-spike"

# ---------------------------------------------------------------------------
# Thresholds
# ---------------------------------------------------------------------------
MEM_THRESHOLD_MIB=200
CPU_THRESHOLD_MS=1500
SURVEY_PIXEL_LIMIT=15500000

# ---------------------------------------------------------------------------
# Survey fixture manifest: "id|filename|w|h|pixels|min_b|max_b"
# ---------------------------------------------------------------------------
declare -a SURVEY_FIXTURES=(
  "S-5|test-S-5.jpg|2500|2000|5000000|4000000|5500000"
  "S-8|test-S-8.jpg|4000|2000|8000000|6500000|9000000"
  "S-10|test-S-10.jpg|4000|2500|10000000|8500000|10000000"
  "S-12|test-S-12.jpg|4000|3000|12000000|9000000|10000000"
  "S-15|test-S-15.jpg|5000|3000|15000000|9000000|10000000"
)
declare -A SURVEY_DIMS=(
  [5]="2500 2000 5000000"
  [8]="4000 2000 8000000"
  [10]="4000 2500 10000000"
  [12]="4000 3000 12000000"
  [15]="5000 3000 15000000"
)
declare -a SURVEY_MP_ORDER=(5 8 10 12 15)

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------
CLEANUP_RAN=false
REMOTE_CLEANUP_REQUIRED=false
WASM_COPIED=false
CONFIG_PATCHED=false
REMOTE_DELETE_FAILED=false
GATE2B_PASS=true
declare -a FAIL_REASONS=()
LAST_WALL_TIME=""
LAST_RUN_ID=""       # reset before each invoke_case call
LAST_INVOKE_546=false

# Survey telemetry (indexed by MP level)
declare -A SURVEY_CPU=()
declare -A SURVEY_MEM=()
declare -A SURVEY_REASON=()

SURVEY_STOPPED_AT=""   # MP level where 546 occurred (empty if not)
CHOSEN_MP=""
CHOSEN_W=0
CHOSEN_H=0
CHOSEN_PX=0

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
fail() {
  GATE2B_PASS=false
  FAIL_REASONS+=("$*")
  echo "FAILURE: $*" >&2
}

results_append() { printf '%s\n' "$*" >> "$RESULTS_MD"; }

bool_field() {
  jq -r --arg f "$2" \
    'if has($f) and (.[$f] | type)=="boolean" then (.[$f]|tostring) else "MISSING" end' \
    "$1" 2>/dev/null || echo "PARSE_ERROR"
}

is_valid_uuid() {
  echo "$1" | grep -qiE \
    '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
}

# ---------------------------------------------------------------------------
# Cleanup — idempotent; evidence-safe.
# ---------------------------------------------------------------------------
cleanup() {
  if [[ "$CLEANUP_RAN" == "true" ]]; then return; fi
  CLEANUP_RAN=true
  local trigger="${1:-EXIT}"
  echo "" >&2
  echo "=================================================================" >&2
  echo "Gate 2B Rev 11 Cleanup (trigger: $trigger)" >&2
  echo "=================================================================" >&2

  if [[ "$REMOTE_CLEANUP_REQUIRED" == "true" ]]; then
    supabase functions delete image-spike \
      --project-ref "$PROJECT_REF" 2>/dev/null || true
    sleep 3
    local list_out list_exit
    list_out=$(supabase functions list --project-ref "$PROJECT_REF" 2>/dev/null)
    list_exit=$?
    if [[ $list_exit -ne 0 ]]; then
      echo "WARNING: cleanup: functions list failed (exit $list_exit)" >&2
      echo "  Verify: https://supabase.com/dashboard/project/$PROJECT_REF/functions" >&2
      REMOTE_DELETE_FAILED=true
    elif printf '%s' "$list_out" | grep -q "image-spike"; then
      echo "WARNING: cleanup: image-spike still listed — manual deletion required" >&2
      echo "  https://supabase.com/dashboard/project/$PROJECT_REF/functions" >&2
      REMOTE_DELETE_FAILED=true
    else
      echo "Cleanup remote deletion: confirmed" >&2
      REMOTE_CLEANUP_REQUIRED=false
    fi
  fi

  if [[ "$CONFIG_PATCHED" == "true" ]] \
     || grep -q '\[functions\.image-spike\]' "$CONFIG" 2>/dev/null; then
    python3 - "$CONFIG" <<'PYEOF'
import re, sys
path = sys.argv[1]
with open(path) as f: content = f.read()
cleaned = re.sub(r'\n\[functions\.image-spike\]\n(?:(?!\[)[^\n]*\n)*', '\n', content)
with open(path, 'w') as f: f.write(cleaned)
print('config.toml: [functions.image-spike] removed', file=sys.stderr)
PYEOF
  fi

  if [[ -f "$WASM_DST" ]];   then rm "$WASM_DST"     && echo "Removed: $WASM_DST" >&2; fi
  if [[ -d "$SPIKE_DIR" ]];  then rm -rf "$SPIKE_DIR" && echo "Removed: $SPIKE_DIR" >&2; fi
  if [[ -d "$IMG_DIR" ]];    then rm -rf "$IMG_DIR"   && echo "Removed: $IMG_DIR" >&2; fi

  echo "Evidence preserved in: $RESULTS_DIR" >&2
  if [[ "$REMOTE_DELETE_FAILED" == "true" ]]; then
    echo "CRITICAL: Remote deletion unconfirmed — manual action required." >&2
    exit 1
  fi
  echo "=================================================================" >&2
}

trap 'cleanup EXIT' EXIT
trap 'GATE2B_PASS=false; FAIL_REASONS+=("INTERRUPTED:INT"); cleanup INT; exit 130' INT
trap 'GATE2B_PASS=false; FAIL_REASONS+=("INTERRUPTED:TERM"); cleanup TERM; exit 143' TERM

# ---------------------------------------------------------------------------
# deploy_function
# ---------------------------------------------------------------------------
deploy_function() {
  local phase="$1"
  echo ""; echo "=== Phase $phase: Deploy image-spike ==="

  local pre_list pre_exit
  pre_list=$(supabase functions list --project-ref "$PROJECT_REF" 2>/dev/null)
  pre_exit=$?
  if [[ $pre_exit -ne 0 ]]; then
    fail "Phase $phase: pre-deploy functions list failed (exit $pre_exit)"; return 1; fi
  if printf '%s' "$pre_list" | grep -q "image-spike"; then
    fail "Phase $phase: image-spike already exists on remote — aborting"; return 1; fi

  REMOTE_CLEANUP_REQUIRED=true

  local deploy_out
  deploy_out=$(supabase functions deploy image-spike \
    --project-ref "$PROJECT_REF" \
    --debug 2>&1)
  local deploy_exit=$?
  echo "$deploy_out"
  if [[ $deploy_exit -ne 0 ]]; then
    fail "Phase $phase: deployment failed (exit $deploy_exit)"; return 1; fi

  local bundle_raw
  bundle_raw=$(python3 - "$deploy_out" <<'PYEOF'
import sys, re
m = re.search(r'(?:script|bundle) size:\s*([0-9]+(?:\.[0-9]+)?)\s*(MiB|MB)\b',
              sys.argv[1], re.IGNORECASE)
if m: print(m.group(1) + " " + m.group(2))
PYEOF
  )
  if [[ -z "$bundle_raw" ]]; then
    fail "Phase $phase: bundle size not found in --debug output"
    results_append "Phase $phase bundle: UNPARSEABLE → FAIL"
    results_append "deploy_output_head: $(printf '%s' "$deploy_out" | head -40)"
    return 1
  fi

  python3 - "$bundle_raw" <<'PYEOF' || { fail "Phase $phase: bundle ${bundle_raw} > 20 MB"; return 1; }
import sys, re, math
parts = sys.argv[1].split()
num, unit = float(parts[0]), parts[1].upper()
mb = num * 1.048576 if unit == "MIB" else num
if not (math.isfinite(mb) and mb >= 0):
    print(f"FAIL: bundle {sys.argv[1]} → {mb} not finite/nonneg"); sys.exit(1)
if mb > 20:
    print(f"FAIL: {sys.argv[1]} = {mb:.2f} MB > 20 MB limit"); sys.exit(1)
print(f"bundle: {sys.argv[1]} = {mb:.2f} MB ≤ 20 MB ✓")
PYEOF

  results_append "Phase $phase bundle: ${bundle_raw}"
  return 0
}

# ---------------------------------------------------------------------------
# delete_confirmed
# ---------------------------------------------------------------------------
delete_confirmed() {
  local phase="$1"
  echo ""; echo "Deleting image-spike (Phase $phase) ..."
  supabase functions delete image-spike \
    --project-ref "$PROJECT_REF" 2>/dev/null || true
  sleep 3
  local list_out list_exit
  list_out=$(supabase functions list --project-ref "$PROJECT_REF" 2>/dev/null)
  list_exit=$?
  if [[ $list_exit -ne 0 ]]; then
    fail "Phase $phase: functions list failed (exit $list_exit)"
    REMOTE_DELETE_FAILED=true; return 1; fi
  if printf '%s' "$list_out" | grep -q "image-spike"; then
    fail "Phase $phase: image-spike still listed after deletion"
    REMOTE_DELETE_FAILED=true; return 1; fi
  echo "Phase $phase deletion: confirmed ✓"
  REMOTE_CLEANUP_REQUIRED=false
  return 0
}

# ---------------------------------------------------------------------------
# invoke_case — single curl + assertions.
# Returns:  0  = completed (assertions may have failed via fail())
#           2  = HTTP 546 (resource limit; caller decides to exit or break)
# ---------------------------------------------------------------------------
invoke_case() {
  # Reset per-invocation globals before anything else
  LAST_RUN_ID=""
  LAST_INVOKE_546=false

  local label="$1" filename="$2" mime="$3" exp_accepted="$4" exp_reason="$5"
  local exp_w="$6" exp_h="$7" exp_pixels="$8"
  local img="$IMG_DIR/$filename"
  local out="$OUT_DIR/${label}.json"
  local hdr="$OUT_DIR/${label}.headers"
  local webp_out="$OUT_DIR/${label}_output.webp"
  local actual_input_size
  actual_input_size=$(wc -c < "$img" | awk '{print $1}')

  echo ""; echo "--- $label ($filename, $mime) ---"

  local curl_w
  curl_w=$(curl -s \
    -o "$out" -D "$hdr" \
    -w '%{http_code}\t%{time_total}' \
    --max-time 120 \
    -X POST "${FUNC_URL}?label=${label}" \
    -H "Authorization: Bearer $ANON_KEY" \
    -H "Content-Type: $mime" \
    --data-binary "@$img" 2>/dev/null)
  local curl_exit=$?

  local http_status wall_time req_id
  http_status=$(printf '%s' "$curl_w" | awk -F'\t' '{print $1}')
  wall_time=$(printf '%s'   "$curl_w" | awk -F'\t' '{print $2}')
  LAST_WALL_TIME="$wall_time"
  req_id=$(grep -i '^x-request-id:' "$hdr" 2>/dev/null \
    | awk '{print $2}' | tr -d '\r' | head -1 || true)

  echo "  curl_exit=$curl_exit  HTTP=$http_status  wall_time=${wall_time}s"
  results_append ""; results_append "### $label"
  results_append "curl_exit=$curl_exit  HTTP=$http_status  wall_time_s=$wall_time"
  results_append "x-request-id: ${req_id:-<not found>}"

  if [[ $curl_exit -ne 0 ]]; then
    fail "$label: curl exit $curl_exit"; results_append "FAIL: curl transport error"; return 0; fi

  if [[ "$http_status" == "546" ]]; then
    fail "$label: HTTP 546 — resource limit exceeded"
    results_append "HARD FAIL: HTTP 546"
    LAST_INVOKE_546=true
    return 2
  fi

  if [[ "$http_status" == "401" || "$http_status" == "403" ]]; then
    fail "$label: HTTP $http_status — authentication failure; stopping run"
    results_append "HARD FAIL: HTTP $http_status"; exit 1; fi

  if [[ "$http_status" != "200" ]]; then
    fail "$label: HTTP $http_status"; results_append "FAIL: HTTP $http_status"; return 0; fi

  local resp_label
  resp_label=$(jq -r '.label // "MISSING"' "$out" 2>/dev/null || echo "PARSE_ERROR")
  [[ "$resp_label" == "$label" ]] || fail "$label: response label='$resp_label' ≠ '$label'"

  local resp_run_id
  resp_run_id=$(jq -r '.run_id // ""' "$out" 2>/dev/null || echo "")
  LAST_RUN_ID="$resp_run_id"
  results_append "run_id: ${resp_run_id:-MISSING}"
  if ! is_valid_uuid "$resp_run_id"; then
    fail "$label: run_id '${resp_run_id}' is not a valid UUID"
  else
    echo "  run_id=${resp_run_id} ✓"
  fi

  local resp_accepted
  resp_accepted=$(bool_field "$out" "accepted")
  if [[ "$resp_accepted" == "MISSING" || "$resp_accepted" == "PARSE_ERROR" ]]; then
    fail "$label: accepted field missing or not boolean"
  elif [[ "$resp_accepted" != "$exp_accepted" ]]; then
    fail "$label: accepted=$resp_accepted ≠ $exp_accepted"
  else
    echo "  accepted=$resp_accepted ✓"
  fi

  local resp_w resp_h resp_pixels
  resp_w=$(jq -r '.width // 0'       "$out" 2>/dev/null || echo 0)
  resp_h=$(jq -r '.height // 0'      "$out" 2>/dev/null || echo 0)
  resp_pixels=$(jq -r '.pixel_count // 0' "$out" 2>/dev/null || echo 0)
  [[ "$resp_w" == "$exp_w" && "$resp_h" == "$exp_h" ]] \
    || fail "$label: dimensions ${resp_w}x${resp_h} ≠ ${exp_w}x${exp_h}"
  [[ "$resp_pixels" == "$exp_pixels" ]] \
    || fail "$label: pixel_count=$resp_pixels ≠ $exp_pixels"

  # Assert image_decode_started matches expected
  local resp_decode_started
  resp_decode_started=$(bool_field "$out" "image_decode_started")
  if [[ "$resp_decode_started" == "MISSING" || "$resp_decode_started" == "PARSE_ERROR" ]]; then
    fail "$label: image_decode_started field missing or not boolean"
  elif [[ "$exp_accepted" == "false" && "$resp_decode_started" != "false" ]]; then
    fail "$label: image_decode_started=$resp_decode_started ≠ false — possible decode occurred pre-rejection"
  elif [[ "$exp_accepted" == "true" && "$resp_decode_started" != "true" ]]; then
    fail "$label: image_decode_started=$resp_decode_started ≠ true"
  else
    echo "  image_decode_started=$resp_decode_started ✓"
  fi
  results_append "image_decode_started: $resp_decode_started"

  if [[ "$exp_accepted" == "false" ]]; then
    local resp_reason
    resp_reason=$(jq -r '.reason // "MISSING"' "$out" 2>/dev/null || echo "PARSE_ERROR")
    [[ "$resp_reason" == "$exp_reason" ]] \
      || fail "$label: reason='$resp_reason' ≠ '$exp_reason'"
    results_append "accepted=false  reason=$resp_reason"
    return 0
  fi

  # --- Accepted-only assertions ---
  local resp_input_size
  resp_input_size=$(jq -r '.input_size_bytes // 0' "$out" 2>/dev/null || echo 0)
  [[ "$resp_input_size" == "$actual_input_size" ]] \
    || fail "$label: input_size_bytes=$resp_input_size ≠ $actual_input_size"

  local resp_meta_clean
  resp_meta_clean=$(bool_field "$out" "metadata_clean")
  [[ "$resp_meta_clean" == "true" ]] \
    || fail "$label: metadata_clean=$resp_meta_clean ≠ true"

  local resp_sha256
  resp_sha256=$(jq -r '.sha256 // ""' "$out" 2>/dev/null || echo "")
  printf '%s' "$resp_sha256" | grep -qE '^[0-9a-f]{64}$' \
    || fail "$label: sha256 format invalid"

  local resp_output_b64
  resp_output_b64=$(jq -r '.output_bytes // ""' "$out" 2>/dev/null || echo "")
  if [[ -z "$resp_output_b64" || "$resp_output_b64" == "null" ]]; then
    fail "$label: output_bytes field absent"
  else
    if printf '%s' "$resp_output_b64" | base64 -d > "$webp_out" 2>/dev/null; then
      local decoded_size header_check actual_sha resp_output_size
      decoded_size=$(wc -c < "$webp_out" | awk '{print $1}')
      header_check=$(python3 -c "
with open('$webp_out','rb') as f: d=f.read(12)
print('valid' if d[:4]==b'RIFF' and d[8:12]==b'WEBP' else 'invalid')
" 2>/dev/null || echo "error")
      if [[ "$header_check" != "valid" ]]; then
        fail "$label: decoded output is not valid WebP"
      else
        actual_sha=$(shasum -a 256 "$webp_out" | awk '{print $1}')
        [[ "$actual_sha" == "$resp_sha256" ]] \
          || fail "$label: SHA-256 mismatch: recomputed=$actual_sha"
        resp_output_size=$(jq -r '.output_size_bytes // 0' "$out" 2>/dev/null || echo 0)
        [[ "$resp_output_size" == "$decoded_size" ]] \
          || fail "$label: output_size_bytes=$resp_output_size ≠ $decoded_size"
        python3 "$VERIFY_OUT_PY" "$webp_out" 2>&1 \
          || fail "$label: RIFF parser found metadata or malformed WebP"
      fi
    else
      fail "$label: base64 decode of output_bytes failed"
    fi
  fi

  # Secondary memory sanity check (diagnostic only)
  local mem_after_rss_bytes
  mem_after_rss_bytes=$(jq -r '.diagnostic.mem_after_rss_bytes // 0' "$out" 2>/dev/null || echo 0)
  results_append "diagnostic.mem_after_rss_bytes: $mem_after_rss_bytes"
  results_append "sha256: $resp_sha256"
  results_append "accepted=true  wall_time_s=$wall_time"
  return 0
}

# ---------------------------------------------------------------------------
# telemetry_gate — prompt operator for ShutdownEvent fields
# Sets globals: TELEM_EXEC_ID, TELEM_CPU, TELEM_MEM, TELEM_REASON
# ---------------------------------------------------------------------------
TELEM_EXEC_ID="" TELEM_CPU="" TELEM_MEM="" TELEM_REASON=""

telemetry_gate() {
  local label="$1" run_id="$2"
  echo ""
  echo "================================================================="
  echo "$label TELEMETRY CAPTURE GATE"
  echo "================================================================="
  echo "run_id: ${run_id:-MISSING — check function logs}"
  echo ""
  echo "STEP 1 — Find LogEvent by run_id → execution_id:"
  echo "  https://supabase.com/dashboard/project/$PROJECT_REF/logs/edge-logs"
  echo "  Filter: metadata.function_id = 'image-spike'"
  echo "  Search: $run_id"
  echo "  Find entry: event='invoke', label='$label'. Record execution_id."
  echo ""
  echo "STEP 2 — Find ShutdownEvent by execution_id → telemetry:"
  echo "  Search for execution_id."
  echo "  Locate ShutdownEvent for that execution_id."
  echo "  Extract:"
  echo "    cpu_time_used     (no _ms suffix)"
  echo "    memory_used.total (bytes — 'total' sub-field of 'memory_used' object)"
  echo "    reason            (e.g., EventLoopCompleted / Memory / CPUTime)"
  echo "  DO NOT use WorkerMemoryUsed, Metrics tab, or any other source."
  echo ""
  echo "Enter INCONCLUSIVE for any field if not found."
  echo "================================================================="
  read -rp "$label execution_id (UUID, or INCONCLUSIVE): " TELEM_EXEC_ID
  read -rp "$label cpu_time_used ms (or INCONCLUSIVE): "   TELEM_CPU
  read -rp "$label memory_used.total bytes (or INCONCLUSIVE): " TELEM_MEM
  read -rp "$label shutdown_reason (or INCONCLUSIVE): "    TELEM_REASON
}

# ---------------------------------------------------------------------------
# validate_telemetry — validates inputs; evaluates thresholds; validates reason.
# Calls fail() on any violation. Returns 0 on full pass, 1 on any failure.
# ---------------------------------------------------------------------------
VALID_OK_REASONS="EventLoopCompleted EarlyDrop TerminationRequested"
RESOURCE_REASONS="Memory CPUTime WallClockTime"

validate_telemetry() {
  local label="$1"
  local all_ok=true
  results_append ""
  results_append "#### $label Telemetry"
  results_append "execution_id: ${TELEM_EXEC_ID}"
  results_append "cpu_time_used_ms: ${TELEM_CPU}"
  results_append "memory_used.total_bytes: ${TELEM_MEM}"
  results_append "shutdown_reason: ${TELEM_REASON}"

  # INCONCLUSIVE check
  if [[ "$TELEM_EXEC_ID" == "INCONCLUSIVE" || "$TELEM_CPU" == "INCONCLUSIVE" \
        || "$TELEM_MEM" == "INCONCLUSIVE" || "$TELEM_REASON" == "INCONCLUSIVE" ]]; then
    fail "$label: telemetry INCONCLUSIVE"
    results_append "$label telemetry: INCONCLUSIVE → FAIL"
    return 1
  fi

  # execution_id UUID check
  if ! is_valid_uuid "$TELEM_EXEC_ID"; then
    fail "$label: execution_id '${TELEM_EXEC_ID}' is not a valid UUID"
    results_append "$label execution_id: INVALID → FAIL"
    all_ok=false
  fi

  # Shutdown reason check
  if echo "$RESOURCE_REASONS" | grep -qw "${TELEM_REASON:-}"; then
    fail "$label: shutdown_reason='$TELEM_REASON' — resource limit exceeded"
    results_append "$label shutdown_reason: RESOURCE_LIMIT → FAIL"
    all_ok=false
  elif ! echo "$VALID_OK_REASONS" | grep -qw "${TELEM_REASON:-}"; then
    fail "$label: shutdown_reason='$TELEM_REASON' — unrecognized (treating as resource-limit failure)"
    results_append "$label shutdown_reason: UNKNOWN → FAIL"
    all_ok=false
  fi

  # Numeric threshold check
  python3 - "$TELEM_CPU" "$TELEM_MEM" "$MEM_THRESHOLD_MIB" "$CPU_THRESHOLD_MS" "$label" <<'PYEOF'
import sys, math
cpu_raw, mem_raw, mem_thr, cpu_thr, label = sys.argv[1:]
mem_thr, cpu_thr = float(mem_thr), float(cpu_thr)
try:
    cpu = float(cpu_raw); mem = float(mem_raw)
except ValueError as e:
    print(f"FAIL: non-numeric telemetry: {e}"); sys.exit(1)
if not (math.isfinite(cpu) and cpu >= 0):
    print(f"FAIL: cpu {cpu} not finite/nonneg"); sys.exit(1)
if not (math.isfinite(mem) and mem >= 0):
    print(f"FAIL: memory {mem} not finite/nonneg"); sys.exit(1)
mib = mem / 1_048_576
cpu_ok = cpu <= cpu_thr
mem_ok = mib <= mem_thr
print(f"cpu_time_used: {cpu:.0f} ms ({'≤' if cpu_ok else '>'} {cpu_thr:.0f} ms) {'✓' if cpu_ok else 'FAIL'}")
print(f"memory_used.total: {mem:.0f} bytes = {mib:.1f} MiB ({'≤' if mem_ok else '>'} {mem_thr:.0f} MiB) {'✓' if mem_ok else 'FAIL'}")
if not cpu_ok or not mem_ok:
    sys.exit(2)
print(f"{label} telemetry: PASS")
PYEOF
  local telem_exit=$?
  if [[ $telem_exit -ne 0 ]]; then
    fail "$label: telemetry threshold check failed"
    results_append "$label telemetry: THRESHOLD_FAIL"
    all_ok=false
  fi

  if [[ "$all_ok" == "true" ]]; then
    results_append "$label telemetry: PASS"; return 0
  else
    return 1
  fi
}

# ---------------------------------------------------------------------------
# update_pixel_limit — exactly one substitution required (re.subn)
# ---------------------------------------------------------------------------
update_pixel_limit() {
  local new_limit="$1"
  python3 - "$SPIKE_DIR/index.ts" "$new_limit" <<'PYEOF' \
    || { echo "FATAL: could not update CANONICAL_PIXEL_LIMIT in index.ts" >&2; exit 1; }
import sys, re
path, limit = sys.argv[1], sys.argv[2]
with open(path) as f: content = f.read()
new, count = re.subn(r'(CANONICAL_PIXEL_LIMIT\s*=\s*)[\d_]+', rf'\g<1>{limit}', content)
if count != 1:
    print(f"FATAL: expected exactly 1 substitution, got {count}", file=sys.stderr)
    sys.exit(1)
with open(path, 'w') as f: f.write(new)
print(f"CANONICAL_PIXEL_LIMIT → {limit} (1 substitution)")
PYEOF
  echo "index.ts CANONICAL_PIXEL_LIMIT → $new_limit ✓"
}

# ===========================================================================
# PREFLIGHT
# ===========================================================================
echo "=== Gate 2B Rev 11 Preflight ==="

# Required tools (including gitleaks)
for tool in supabase curl jq python3 shasum deno gitleaks; do
  command -v "$tool" &>/dev/null || { echo "FATAL: $tool not found" >&2; exit 1; }
done

# Rev 9 evidence check
REV9_EVIDENCE="$REPO_ROOT/tools/image-spike/gate2b-evidence-20260814T194105Z/gate2b-results.md"
REV9_SHA="3903f9dc08bb7edc77720911a614a9656ad97b5c9e42a04c9a50d60f3fd1bc4f"
[[ -f "$REV9_EVIDENCE" ]] \
  || { echo "FATAL: Rev 9 evidence missing: $REV9_EVIDENCE" >&2; exit 1; }
actual_sha=$(shasum -a 256 "$REV9_EVIDENCE" | awk '{print $1}')
[[ "$actual_sha" == "$REV9_SHA" ]] \
  || { echo "FATAL: Rev 9 evidence SHA mismatch: got $actual_sha" >&2; exit 1; }
echo "Rev 9 evidence SHA: verified ✓"

# File existence
for f in "$WASM_SRC" "$VERIFY_OUT_PY" "$VERIFY_IN_PY" "$FIXTURES_PY"; do
  [[ -f "$f" ]] || { echo "FATAL: file not found: $f" >&2; exit 1; }
done
[[ -d "$SPIKE_DIR" ]] || { echo "FATAL: spike dir not found: $SPIKE_DIR" >&2; exit 1; }

# Collision guards
[[ -d "$IMG_DIR" ]]     && { echo "FATAL: IMG_DIR exists — delete before running" >&2; exit 1; }
[[ -d "$RESULTS_DIR" ]] && { echo "FATAL: RESULTS_DIR collision" >&2; exit 1; }
[[ -f "$WASM_DST" ]]    && { echo "FATAL: $WASM_DST exists — clean up" >&2; exit 1; }
grep -q '\[functions\.image-spike\]' "$CONFIG" 2>/dev/null \
  && { echo "FATAL: [functions.image-spike] already in config.toml" >&2; exit 1; }

# Verify index.ts CANONICAL_PIXEL_LIMIT is at survey value
python3 - "$SPIKE_DIR/index.ts" "$SURVEY_PIXEL_LIMIT" <<'PYEOF' \
  || { echo "FATAL: index.ts CANONICAL_PIXEL_LIMIT is not $SURVEY_PIXEL_LIMIT" >&2; exit 1; }
import sys, re
path, expected = sys.argv[1], sys.argv[2].replace("_","")
with open(path) as f: content = f.read()
m = re.search(r'CANONICAL_PIXEL_LIMIT\s*=\s*([\d_]+)', content)
if not m: print("FATAL: CANONICAL_PIXEL_LIMIT not found", file=sys.stderr); sys.exit(1)
actual = m.group(1).replace("_","")
if actual != expected:
    print(f"FATAL: CANONICAL_PIXEL_LIMIT={actual}, expected {expected}", file=sys.stderr); sys.exit(1)
print(f"CANONICAL_PIXEL_LIMIT={actual} ✓")
PYEOF

mkdir -p "$OUT_DIR"
> "$RESULTS_MD"
results_append "# Gate 2B Results — Rev 11"
results_append "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
results_append "PROJECT_REF: $PROJECT_REF"
results_append "SURVEY_PIXEL_LIMIT: $SURVEY_PIXEL_LIMIT"
results_append "MEM_THRESHOLD_MIB: $MEM_THRESHOLD_MIB"
results_append "CPU_THRESHOLD_MS: $CPU_THRESHOLD_MS"
echo "Preflight: all checks passed"

# ===========================================================================
# GENERATE SURVEY FIXTURES
# ===========================================================================
echo ""; echo "=== Generating survey fixtures ==="
python3 "$FIXTURES_PY" "$IMG_DIR" \
  || { echo "FATAL: survey fixture generation failed" >&2; exit 1; }

# ===========================================================================
# VERIFY SURVEY FIXTURES (dimensions, sizes, metadata)
# ===========================================================================
echo ""; echo "=== Verifying survey fixtures ==="
results_append ""; results_append "## Fixture Preflight"
preflight_ok=true
for entry in "${SURVEY_FIXTURES[@]}"; do
  IFS="|" read -r sid filename exp_w exp_h exp_pixels min_bytes max_bytes <<< "$entry"
  img="$IMG_DIR/$filename"
  [[ -f "$img" ]] || { echo "FATAL: $img missing" >&2; exit 1; }
  byte_size=$(wc -c < "$img" | awk '{print $1}')
  sha=$(shasum -a 256 "$img" | awk '{print $1}')
  dims=$(python3 -c "
from PIL import Image
with Image.open('$img') as im: print(im.width, im.height)
" 2>/dev/null) || { echo "FATAL: cannot read dims of $img" >&2; exit 1; }
  actual_w=$(echo "$dims" | awk '{print $1}')
  actual_h=$(echo "$dims" | awk '{print $2}')
  actual_px=$((actual_w * actual_h))
  ok=true
  [[ "$actual_w" == "$exp_w" && "$actual_h" == "$exp_h" ]] \
    || { fail "PREFLIGHT $sid: dims ${actual_w}x${actual_h} ≠ ${exp_w}x${exp_h}"; ok=false; }
  [[ "$actual_px" == "$exp_pixels" ]] \
    || { fail "PREFLIGHT $sid: pixel_count $actual_px ≠ $exp_pixels"; ok=false; }
  python3 -c "import sys; sys.exit(0 if $min_bytes <= $byte_size <= $max_bytes else 1)" \
    || { fail "PREFLIGHT $sid: size $byte_size outside [$min_bytes,$max_bytes]"; ok=false; }
  [[ "$byte_size" -le 10000000 ]] \
    || { fail "PREFLIGHT $sid: size $byte_size > 10 MB upload ceiling"; ok=false; }
  # Metadata verification
  python3 "$VERIFY_IN_PY" jpeg "$img" \
    || { fail "PREFLIGHT $sid: metadata families missing"; ok=false; }
  [[ "$ok" == "true" ]] || preflight_ok=false
  results_append "$sid: $filename ${byte_size}B ${actual_w}x${actual_h} sha256=${sha}"
  echo "PREFLIGHT $sid: ${byte_size}B ${actual_w}x${actual_h} $([[ "$ok" == "true" ]] && echo ✓ || echo FAIL)"
done
[[ "$preflight_ok" == "true" && "$GATE2B_PASS" == "true" ]] \
  || { echo "FATAL: fixture preflight failed" >&2; exit 1; }

# ===========================================================================
# WASM COPY + VERIFY
# ===========================================================================
echo ""; echo "=== WASM copy ==="
cp "$WASM_SRC" "$WASM_DST"
SRC_HASH=$(shasum -a 256 "$WASM_SRC" | awk '{print $1}')
DST_HASH=$(shasum -a 256 "$WASM_DST" | awk '{print $1}')
[[ "$SRC_HASH" == "$DST_HASH" ]] || { echo "FATAL: WASM copy hash mismatch" >&2; exit 1; }
WASM_COPIED=true
INDEX_HASH=$(shasum -a 256 "$SPIKE_DIR/index.ts" | awk '{print $1}')
results_append ""; results_append "## Hashes"
results_append "magick.wasm sha256: $SRC_HASH"
results_append "index.ts (survey) sha256: $INDEX_HASH"
echo "WASM sha256: $SRC_HASH ✓"

# ===========================================================================
# CONFIG.TOML PATCH
# ===========================================================================
echo ""; echo "=== Patching config.toml ==="
printf '\n[functions.image-spike]\nstatic_files = ["./functions/_shared/magick.wasm"]\n' \
  >> "$CONFIG"
CONFIG_PATCHED=true
echo "config.toml patched"

# ===========================================================================
# STATIC CHECKS
# ===========================================================================
echo ""; echo "=== Static checks ==="
deno fmt --check "$SPIKE_DIR/index.ts" || { fail "deno fmt"; exit 1; }
deno lint "$SPIKE_DIR/index.ts"        || { fail "deno lint"; exit 1; }
deno check "$SPIKE_DIR/index.ts"       || { fail "deno check"; exit 1; }
gitleaks detect --source "$REPO_ROOT" --config "$REPO_ROOT/.gitleaks.toml" 2>/dev/null \
  || { fail "gitleaks"; exit 1; }
echo "Static checks passed"

# ===========================================================================
# PRE-DEPLOYMENT APPROVAL GATE
# ===========================================================================
echo ""
echo "All three parties must have signed off on the pre-deployment code review."
read -rp "Type YES to confirm pre-deployment approval and proceed: " _confirm
[[ "$_confirm" == "YES" ]] || { echo "Deployment aborted." >&2; exit 1; }

# ===========================================================================
# SURVEY PHASES S-1 through S-5
# ===========================================================================
results_append ""; results_append "## Survey Phase Results"

for mp in "${SURVEY_MP_ORDER[@]}"; do
  phase_label="S-${mp}MP"
  read -r exp_w exp_h exp_pixels <<< "${SURVEY_DIMS[$mp]}"
  filename="test-S-${mp}.jpg"
  sid="S-${mp}"

  results_append ""; results_append "### Phase $phase_label"
  echo ""; echo "================================================================="
  echo "=== SURVEY PHASE $phase_label ==="
  echo "================================================================="

  deploy_function "$phase_label" || exit 1

  invoke_case "$sid" "$filename" "image/jpeg" "true" "" "$exp_w" "$exp_h" "$exp_pixels"
  invoke_exit=$?
  phase_run_id="$LAST_RUN_ID"
  phase_wall="$LAST_WALL_TIME"

  if [[ $invoke_exit -eq 2 ]]; then
    # 546 boundary
    SURVEY_STOPPED_AT=$mp
    echo "Phase $phase_label hit HTTP 546 — stopping survey ascent"
    results_append "Phase $phase_label: 546 boundary — survey stopped"
    SURVEY_CPU[$mp]=""
    SURVEY_MEM[$mp]=""
    SURVEY_REASON[$mp]="546"
    # Cleanup is handled by delete_confirmed below; we still must delete
    delete_confirmed "$phase_label" || exit 1
    break
  fi

  echo "$sid cold wall-clock: ${phase_wall}s (threshold ≤ 30 s)"
  python3 -c "import sys; sys.exit(0 if float('$phase_wall') <= 30 else 1)" \
    || fail "$sid: cold wall-clock ${phase_wall}s > 30 s"
  results_append "$sid cold_wall_time_s: $phase_wall"

  delete_confirmed "$phase_label" || exit 1

  telemetry_gate "$sid" "$phase_run_id"
  validate_telemetry "$sid"
  telem_ok=$?

  SURVEY_CPU[$mp]="${TELEM_CPU}"
  SURVEY_MEM[$mp]="${TELEM_MEM}"
  SURVEY_REASON[$mp]="${TELEM_REASON}"
done

# ===========================================================================
# CEILING SELECTION
# ===========================================================================
echo ""; echo "================================================================="
echo "=== CEILING SELECTION ==="
echo "================================================================="
results_append ""; results_append "## Ceiling Selection"

ceiling_script_output=$(python3 - \
  "${SURVEY_CPU[5]:-}" \
  "${SURVEY_MEM[5]:-}" \
  "${SURVEY_REASON[5]:-}" \
  "${SURVEY_CPU[8]:-}" \
  "${SURVEY_MEM[8]:-}" \
  "${SURVEY_REASON[8]:-}" \
  "${SURVEY_CPU[10]:-}" \
  "${SURVEY_MEM[10]:-}" \
  "${SURVEY_REASON[10]:-}" \
  "${SURVEY_CPU[12]:-}" \
  "${SURVEY_MEM[12]:-}" \
  "${SURVEY_REASON[12]:-}" \
  "${SURVEY_CPU[15]:-}" \
  "${SURVEY_MEM[15]:-}" \
  "${SURVEY_REASON[15]:-}" \
  "$MEM_THRESHOLD_MIB" "$CPU_THRESHOLD_MS" <<'PYEOF'
import sys, math

args = sys.argv[1:]
MP_LEVELS = [5, 8, 10, 12, 15]
RESOURCE_REASONS = {"Memory", "CPUTime", "WallClockTime"}
mem_thr = float(args[-2]); cpu_thr = float(args[-1])
MIB = 1_048_576

survey = {}
for i, mp in enumerate(MP_LEVELS):
    survey[mp] = (args[i*3], args[i*3+1], args[i*3+2])

print("\nSurvey Results:")
print(f"{'MP':>4}  {'CPU (ms)':>10}  {'Mem (MiB)':>11}  {'Reason':>22}  {'Viable':>7}")
print("-" * 72)

viable = []
for mp in MP_LEVELS:
    cpu_raw, mem_raw, reason = survey[mp]
    if not cpu_raw or not mem_raw or reason == "546":
        print(f"{mp:>4}  {'N/A (546 or not run)':>46}  {'NO':>7}")
        continue
    try:
        cpu = float(cpu_raw); mem = float(mem_raw)
    except ValueError:
        print(f"{mp:>4}  {'INCONCLUSIVE':>46}  {'NO':>7}")
        continue
    mib = mem / MIB
    ok_cpu = cpu <= cpu_thr
    ok_mem = mib <= mem_thr
    ok_reason = reason not in RESOURCE_REASONS
    is_viable = ok_cpu and ok_mem and ok_reason
    if is_viable:
        viable.append(mp)
    print(f"{mp:>4}  {cpu:>10.0f}  {mib:>11.1f}  {reason:>22}  {'YES' if is_viable else 'NO':>7}")

print("-" * 72)
if viable:
    rec = max(viable)
    print(f"\nRECOMMENDED_CEILING={rec}")
    print(f"VIABLE_LEVELS={' '.join(str(m) for m in viable)}")
else:
    print("\nRECOMMENDED_CEILING=NONE")
    print("VIABLE_LEVELS=")
PYEOF
)

echo "$ceiling_script_output"
results_append "$ceiling_script_output"

RECOMMENDED_CEILING=$(echo "$ceiling_script_output" | grep '^RECOMMENDED_CEILING=' \
  | cut -d= -f2 | tr -d '[:space:]')
VIABLE_LEVELS_STR=$(echo "$ceiling_script_output" | grep '^VIABLE_LEVELS=' \
  | cut -d= -f2 | tr -d '[:space:]')

if [[ "$RECOMMENDED_CEILING" == "NONE" || -z "$RECOMMENDED_CEILING" ]]; then
  fail "No viable pixel ceiling found — both thresholds exceeded at all survey levels"
  results_append "CEILING SELECTION: FAIL — no viable ceiling"
  exit 1
fi

echo ""
echo "Recommended ceiling: ${RECOMMENDED_CEILING} MP"
echo "Viable levels: ${VIABLE_LEVELS_STR}"
echo ""
echo "You may select the recommended level or any lower viable level."
echo "Any other selection requires a new three-party decision."
read -rp "Enter ceiling MP level [recommended: $RECOMMENDED_CEILING]: " operator_ceiling

# Validate: must be numeric, in viable levels, ≤ recommended
if ! [[ "$operator_ceiling" =~ ^[0-9]+$ ]]; then
  echo "FATAL: ceiling must be a number; got '$operator_ceiling'" >&2; exit 1; fi

viable_ok=false
for vl in $VIABLE_LEVELS_STR; do
  [[ "$vl" == "$operator_ceiling" ]] && viable_ok=true
done
if [[ "$viable_ok" != "true" ]]; then
  echo "FATAL: $operator_ceiling is not in VIABLE_LEVELS ($VIABLE_LEVELS_STR)" >&2; exit 1; fi

if [[ "$operator_ceiling" -gt "$RECOMMENDED_CEILING" ]]; then
  echo "FATAL: $operator_ceiling > recommended $RECOMMENDED_CEILING — requires new three-party decision" >&2
  exit 1
fi

CHOSEN_MP="$operator_ceiling"
read -r CHOSEN_W CHOSEN_H CHOSEN_PX <<< "${SURVEY_DIMS[$CHOSEN_MP]}"
REJECT_W=$((CHOSEN_W + 1))
REJECT_PX=$((REJECT_W * CHOSEN_H))

results_append "Operator-confirmed ceiling: ${CHOSEN_MP} MP (${CHOSEN_W}x${CHOSEN_H}, ${CHOSEN_PX} px)"
echo "Ceiling confirmed: ${CHOSEN_MP} MP (${CHOSEN_W}×${CHOSEN_H}, ${CHOSEN_PX} px)"

# ===========================================================================
# GENERATE CONFIRMATION FIXTURES
# ===========================================================================
echo ""; echo "=== Generating confirmation fixtures ==="
python3 "$FIXTURES_PY" "$IMG_DIR" confirm "$CHOSEN_W" "$CHOSEN_H" "$CHOSEN_PX" \
  || { echo "FATAL: confirmation fixture generation failed" >&2; exit 1; }

# Preflight confirmation fixtures
echo ""; echo "=== Verifying confirmation fixtures ==="
results_append ""; results_append "## Confirmation Fixture Preflight"
conf_preflight_ok=true

for i in 1 2 3; do
  cjpeg="$IMG_DIR/test-C-jpeg-${i}.jpg"
  [[ -f "$cjpeg" ]] || { echo "FATAL: $cjpeg missing" >&2; exit 1; }
  cj_size=$(wc -c < "$cjpeg" | awk '{print $1}')
  cj_dims=$(python3 -c "
from PIL import Image
with Image.open('$cjpeg') as im: print(im.width, im.height)
" 2>/dev/null)
  cj_w=$(echo "$cj_dims" | awk '{print $1}')
  cj_h=$(echo "$cj_dims" | awk '{print $2}')
  ok=true
  [[ "$cj_w" == "$CHOSEN_W" && "$cj_h" == "$CHOSEN_H" ]] \
    || { fail "PREFLIGHT C-JPEG-$i: dims ${cj_w}x${cj_h} ≠ ${CHOSEN_W}x${CHOSEN_H}"; ok=false; }
  [[ "$cj_size" -le 10000000 ]] \
    || { fail "PREFLIGHT C-JPEG-$i: $cj_size > 10 MB"; ok=false; }
  python3 "$VERIFY_IN_PY" jpeg "$cjpeg" \
    || { fail "PREFLIGHT C-JPEG-$i: metadata families missing"; ok=false; }
  [[ "$ok" == "true" ]] || conf_preflight_ok=false
  results_append "C-JPEG-$i: ${cj_size}B ${cj_w}x${cj_h}"
  echo "PREFLIGHT C-JPEG-$i: ${cj_size}B ${cj_w}x${cj_h} $([[ "$ok" == "true" ]] && echo ✓ || echo FAIL)"
done

cwebp="$IMG_DIR/test-C-webp.webp"
[[ -f "$cwebp" ]] || { echo "FATAL: $cwebp missing" >&2; exit 1; }
cw_size=$(wc -c < "$cwebp" | awk '{print $1}')
cw_dims=$(python3 -c "
from PIL import Image
with Image.open('$cwebp') as im: print(im.width, im.height)
" 2>/dev/null)
cw_w=$(echo "$cw_dims" | awk '{print $1}')
cw_h=$(echo "$cw_dims" | awk '{print $2}')
[[ "$cw_w" == "$CHOSEN_W" && "$cw_h" == "$CHOSEN_H" ]] \
  || { fail "PREFLIGHT C-WEBP: dims ${cw_w}x${cw_h} ≠ ${CHOSEN_W}x${CHOSEN_H}"; conf_preflight_ok=false; }
[[ "$cw_size" -le 10000000 ]] \
  || { fail "PREFLIGHT C-WEBP: $cw_size > 10 MB"; conf_preflight_ok=false; }
python3 "$VERIFY_IN_PY" webp "$cwebp" \
  || { fail "PREFLIGHT C-WEBP: metadata families missing"; conf_preflight_ok=false; }
results_append "C-WEBP: ${cw_size}B ${cw_w}x${cw_h}"
echo "PREFLIGHT C-WEBP: ${cw_size}B ${cw_w}x${cw_h} $([[ "${conf_preflight_ok}" == "true" ]] && echo ✓ || echo FAIL)"

creject="$IMG_DIR/test-C-reject.jpg"
[[ -f "$creject" ]] || { echo "FATAL: $creject missing" >&2; exit 1; }
cr_dims=$(python3 -c "
from PIL import Image
with Image.open('$creject') as im: print(im.width, im.height)
" 2>/dev/null)
cr_w=$(echo "$cr_dims" | awk '{print $1}')
cr_h=$(echo "$cr_dims" | awk '{print $2}')
[[ "$cr_w" == "$REJECT_W" && "$cr_h" == "$CHOSEN_H" ]] \
  || { fail "PREFLIGHT C-REJECT: dims ${cr_w}x${cr_h} ≠ ${REJECT_W}x${CHOSEN_H}"; conf_preflight_ok=false; }
results_append "C-REJECT: ${cr_w}x${cr_h} (expected ${REJECT_W}x${CHOSEN_H})"
echo "PREFLIGHT C-REJECT: ${cr_w}x${cr_h} $([[ "${conf_preflight_ok}" == "true" ]] && echo ✓ || echo FAIL)"

[[ "$conf_preflight_ok" == "true" ]] \
  || { echo "FATAL: confirmation fixture preflight failed" >&2; exit 1; }

# ===========================================================================
# MID-RUN APPROVAL GATE — confirmation function
# ===========================================================================
update_pixel_limit "$CHOSEN_PX"
CONFIRM_INDEX_HASH=$(shasum -a 256 "$SPIKE_DIR/index.ts" | awk '{print $1}')
results_append ""; results_append "## Confirmation Function"
results_append "CANONICAL_PIXEL_LIMIT: $CHOSEN_PX"
results_append "index.ts (confirmation) sha256: $CONFIRM_INDEX_HASH"

echo ""
echo "================================================================="
echo "MID-RUN CONFIRMATION FUNCTION APPROVAL"
echo "================================================================="
echo "CANONICAL_PIXEL_LIMIT updated to: $CHOSEN_PX"
echo "index.ts sha256: $CONFIRM_INDEX_HASH"
echo ""
echo "Review $SPIKE_DIR/index.ts for the updated limit. All three parties must approve."
read -rp "Type YES to confirm and proceed with confirmation phases: " _cconfirm
[[ "$_cconfirm" == "YES" ]] || { echo "Confirmation deployment aborted." >&2; exit 1; }
results_append "Mid-run ceiling approval: YES"

# ===========================================================================
# CONFIRMATION PHASES C-1, C-2, C-3 — distinct JPEG cold starts
# ===========================================================================
results_append ""; results_append "## Confirmation Phases — JPEG"
declare -a CONFIRM_CPU=() CONFIRM_MEM=()

for i in 1 2 3; do
  clabel="C-${i}"
  cfile="test-C-jpeg-${i}.jpg"
  seed=$((41 + i))  # seeds 42, 43, 44
  results_append ""; results_append "### Phase $clabel (seed=${seed})"
  echo ""; echo "=== CONFIRMATION PHASE $clabel (JPEG seed=${seed}, cold start $i/3) ==="

  deploy_function "$clabel" || exit 1

  invoke_case "$clabel" "$cfile" "image/jpeg" "true" "" \
    "$CHOSEN_W" "$CHOSEN_H" "$CHOSEN_PX"
  if [[ $? -eq 2 ]]; then
    fail "$clabel: HTTP 546 during confirmation — ceiling selection invalid"
    delete_confirmed "$clabel" || true
    exit 1
  fi
  phase_run_id="$LAST_RUN_ID"
  phase_wall="$LAST_WALL_TIME"

  echo "$clabel cold wall-clock: ${phase_wall}s (threshold ≤ 30 s)"
  python3 -c "import sys; sys.exit(0 if float('$phase_wall') <= 30 else 1)" \
    || fail "$clabel: cold wall-clock ${phase_wall}s > 30 s"
  results_append "$clabel cold_wall_time_s: $phase_wall"

  delete_confirmed "$clabel" || exit 1

  telemetry_gate "$clabel" "$phase_run_id"
  validate_telemetry "$clabel" \
    || fail "$clabel: telemetry gate failed — confirmation invalid"
  CONFIRM_CPU+=("$TELEM_CPU")
  CONFIRM_MEM+=("$TELEM_MEM")
done

# ===========================================================================
# CONFIRMATION PHASE C-4 — WebP (cold) + Rejection (warm)
# ===========================================================================
results_append ""; results_append "## Confirmation Phase C-4 (WebP + Rejection)"
echo ""; echo "=== CONFIRMATION PHASE C-4 (WebP cold + Rejection warm) ==="

deploy_function "C-4" || exit 1

# Cold start: WebP
invoke_case "C-WEBP" "test-C-webp.webp" "image/webp" "true" "" \
  "$CHOSEN_W" "$CHOSEN_H" "$CHOSEN_PX"
if [[ $? -eq 2 ]]; then
  fail "C-WEBP: HTTP 546 during confirmation — ceiling selection invalid"
  delete_confirmed "C-4" || true
  exit 1
fi
webp_run_id="$LAST_RUN_ID"
webp_wall="$LAST_WALL_TIME"
results_append "C-WEBP cold_wall_time_s: $webp_wall"

# Warm: rejection
invoke_case "C-REJECT" "test-C-reject.jpg" "image/jpeg" "false" "pre_decode_rejected" \
  "$REJECT_W" "$CHOSEN_H" "$REJECT_PX"
reject_wall="$LAST_WALL_TIME"
results_append "C-REJECT wall_time_s: $reject_wall"

delete_confirmed "C-4" || exit 1

# Telemetry for C-WEBP
telemetry_gate "C-WEBP" "$webp_run_id"
validate_telemetry "C-WEBP" \
  || fail "C-WEBP: telemetry gate failed — confirmation invalid"

# ===========================================================================
# FINAL VERDICT
# ===========================================================================
echo ""; echo "================================================================="
results_append ""; results_append "## Final Verdict"
results_append "Chosen ceiling: ${CHOSEN_MP} MP (${CHOSEN_W}x${CHOSEN_H}, ${CHOSEN_PX} px)"
results_append "Confirmation CPU ms: ${CONFIRM_CPU[*]:-n/a}"
results_append "Confirmation Mem bytes: ${CONFIRM_MEM[*]:-n/a}"

if [[ "$GATE2B_PASS" == "true" ]]; then
  echo "Gate 2B Rev 11: PASS"
  echo "CANONICAL_PIXEL_LIMIT established: $CHOSEN_PX (${CHOSEN_MP} MP, ${CHOSEN_W}x${CHOSEN_H})"
  results_append "Verdict: PASS"
  results_append "CANONICAL_PIXEL_LIMIT: $CHOSEN_PX (${CHOSEN_MP} MP, ${CHOSEN_W}x${CHOSEN_H})"
else
  echo "Gate 2B Rev 11: FAIL"
  results_append "Verdict: FAIL"
  results_append "Failures:"
  for r in "${FAIL_REASONS[@]}"; do
    echo "  - $r"; results_append "  - $r"
  done
fi

echo "Results: $RESULTS_MD"
echo "Evidence dir: $RESULTS_DIR"
echo "================================================================="
[[ "$GATE2B_PASS" == "true" ]] || exit 1
```

---

## Section 12 — Pre-Deployment Checklist Summary

Before the first `supabase functions deploy`:

1. `python3 gate2b-fixtures-r11.py test-images-r11/` — verify all survey fixture sizes and metadata families
2. `bash gate2b-local-test-r11.sh` — S-5 (accepted, `image_decode_started: true`) and reject fixture (`image_decode_started: false`) must pass
3. `deno fmt --check supabase/functions/image-spike/index.ts`
4. `deno lint supabase/functions/image-spike/index.ts`
5. `deno check supabase/functions/image-spike/index.ts`
6. `bash -n tools/image-spike/gate2b-run-r11.sh` — exit 0
7. `python3 -m py_compile tools/image-spike/gate2b-fixtures-r11.py` — exit 0
8. `python3 -m py_compile tools/image-spike/gate2b-verify-input-metadata.py` — exit 0
9. `python3 -m py_compile tools/image-spike/gate2b-verify-metadata.py` — exit 0
10. `gitleaks detect`
11. `shasum -a 256 tools/image-spike/magick.wasm supabase/functions/image-spike/index.ts`
12. Confirm `CANONICAL_PIXEL_LIMIT = 15_500_000` in index.ts
13. Submit all artifacts + outputs; receive three-party sign-off

---

## Section 13 — Results Format

Each run produces a unique `gate2b-evidence-r11-<TIMESTAMP>/` directory (never deleted). Structure:

```
gate2b-evidence-r11-<TIMESTAMP>/
  gate2b-results.md
  responses/
    S-5.json   S-5.headers   S-5_output.webp
    S-8.json   S-8.headers   S-8_output.webp
    S-10.json  S-10.headers  S-10_output.webp
    S-12.json  S-12.headers  S-12_output.webp
    S-15.json  S-15.headers  S-15_output.webp
    C-1.json   C-1.headers   C-1_output.webp
    C-2.json   C-2.headers   C-2_output.webp
    C-3.json   C-3.headers   C-3_output.webp
    C-WEBP.json   C-WEBP.headers   C-WEBP_output.webp
    C-REJECT.json C-REJECT.headers
```

---

## Section 14 — iOS / Swift Client Requirement

The `CANONICAL_PIXEL_LIMIT` established by Gate 2B Rev 11 is the mandatory pixel ceiling for all uploads through the iOS client.

1. Before any upload, the Swift client MUST check `width × height` of the selected image.
2. If `width × height > CANONICAL_PIXEL_LIMIT`, the client MUST downscale and re-encode (HEIF → JPEG or JPEG → JPEG) before calling the upload endpoint. This is not best-effort; it is a hard prerequisite.
3. The client MUST NOT assume the server will accept oversized images. The server rejects pre-decode and returns `accepted: false, reason: pre_decode_rejected, image_decode_started: false`.
4. Client-side downscaling does not replace server-side sanitization. The server remains the authoritative sanitizer.

**Rationale:** Client-only sanitation (no server enforcement) is rejected by project security policy. Server-only sanitation at 20 MP exceeded the runtime memory limit. The established ceiling with mandatory client downscaling and authoritative server sanitation is the approved architecture.

---

## Approval Request

All 8 Codex blockers from Rev 10 are addressed. No cloud operation has been performed.

Requested action: three-party sign-off (Bill + Claude + Codex) using the magic words:

**`APPROVED: Gate 2B Rev 11 — Pixel Ceiling Discovery Spike`**
