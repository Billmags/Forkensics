# Gate 2B Proposal — Rev 10 — Pixel Ceiling Discovery Spike on forkensics-dev

**Status:** DRAFT — awaiting three-party approval

**Governance gate:** Three-party approval (Bill + Claude + Codex) required before any cloud operation is executed. The magic words are `APPROVED: Gate 2B Rev 10 — Pixel Ceiling Discovery Spike`.

**Authorized by:** Step 27 Rev 5 §3 Gate 2 Phase B.

**Supersedes:** Gate 2B Rev 9 (FAIL — memory limit exceeded; evidence in `tools/image-spike/gate2b-evidence-20260814T194105Z/gate2b-results.md`, SHA `3903f9dc08bb7edc77720911a614a9656ad97b5c9e42a04c9a50d60f3fd1bc4f`).

**Rev 10 changes from Rev 9:**

1. **Ascending cold-start survey replaces single 20 MP test.** Rev 9 tested B-03 (5000×4000, 20 MP) directly; it exceeded the 256 MiB memory limit (293.5 MiB peak). Rev 10 tests 5, 8, 10, 12, and 15 MP in ascending order, each with a fresh isolate (cold start), to find the highest level that stays within the accept thresholds.

2. **Dual acceptance thresholds.** Memory ≤ 200 MiB AND CPU ≤ 1,500 ms (100 MiB below the 256 MiB limit; 500 ms below the 2,000 ms effective CPU ceiling). Rev 9 had 220 MiB / 200 ms.

3. **Two-phase runner.** Phase S (survey): five ascending deployments, one per MP level. Phase C (confirmation): minimum three fresh-isolate runs at the selected ceiling, plus a WebP-format cold start and a pre-decode rejection test.

4. **Ceiling selection algorithm.** Runner computes the highest MP level where both thresholds are satisfied. If no level satisfies both, the run reports FAIL — no viable ceiling.

5. **Mid-run ceiling approval gate.** After the survey phase, the runner pauses, prints the telemetry table, and requires Bill to confirm the selected ceiling before the confirmation function is deployed.

6. **Confirmation function carries the chosen ceiling.** The survey function uses `CANONICAL_PIXEL_LIMIT = 15_500_000` to accept all survey fixtures. The confirmation function's limit is set in-place to the chosen ceiling (e.g., 10,000,000 for 10 MP) before the confirmation deploys.

7. **iOS / Swift client requirement formalized.** The server ceiling determined here becomes the mandatory upload limit enforced by the iOS client layer before any upload is attempted.

---

## Section 1 — Prerequisites

### 1.1 Rev 9 Evidence Required

`tools/image-spike/gate2b-evidence-20260814T194105Z/gate2b-results.md` must be present and its SHA-256 must equal `3903f9dc08bb7edc77720911a614a9656ad97b5c9e42a04c9a50d60f3fd1bc4f`. This evidence establishes that 20 MP (293.5 MiB) exceeds the limit and is the baseline for Rev 10.

### 1.2 Pre-Deployment Code Review (blocks deployment, not approval)

Before the runner invokes `supabase functions deploy` for any phase, all three parties must sign off on:

- `supabase/functions/image-spike/index.ts` — survey version (full source, `CANONICAL_PIXEL_LIMIT = 15_500_000`)
- `supabase/config.toml` diff (`[functions.image-spike]` section only)
- `tools/image-spike/gate2b-run-r10.sh`
- `tools/image-spike/gate2b-fixtures-r10.py`
- `tools/image-spike/gate2b-verify-metadata.py` (unchanged from Rev 9)
- SHA-256 of `tools/image-spike/magick.wasm` and both `index.ts` versions
- Local Edge Runtime result (see §1.3)
- `deno fmt --check`, `deno lint`, `deno check` — zero findings
- `gitleaks detect` — no findings

### 1.3 Local Edge Runtime Verification

Before Phase S-1 deploys, the operator must run `bash tools/image-spike/gate2b-local-test-r10.sh` and confirm S-5 (accepted) and the reject fixture (pre_decode_rejected) both pass against the local Edge Runtime. Script is structurally identical to the Rev 9 local test script; only fixture filenames and the CANONICAL_PIXEL_LIMIT differ.

---

## Section 2 — Purpose

Gate 2B Rev 9 proved that 20 MP (5000×4000) exceeds Supabase Edge Runtime's 256 MiB memory ceiling (293.5 MiB peak). Gate 2B Rev 10 finds the highest pixel count that satisfies:

- `memory_used.total` (from ShutdownEvent) ≤ 200 MiB
- `cpu_time_used` (from ShutdownEvent) ≤ 1,500 ms

This ceiling becomes the `CANONICAL_PIXEL_LIMIT` enforced by the production upload handler, and the maximum pixel count the iOS client must enforce before upload. A 56 MiB headroom below the 256 MiB limit and a 500 ms headroom below the 2,000 ms CPU ceiling are required to accommodate variance across isolates and future WASM growth.

---

## Section 3 — Authorized Cloud Operations

**Project:** `hkfrbdpedrxmbsawnbpr` (forkensics-dev). No other project ref is authorized.

**Total deployments:** Up to 9 deployments of `image-spike`, in sequence (never concurrent):

| Phase | Deploy | Invocations | Purpose |
|---|---|---|---|
| S-1 | 1 | S-5 (5 MP JPEG) | Survey cold start |
| S-2 | 1 | S-8 (8 MP JPEG) | Survey cold start |
| S-3 | 1 | S-10 (10 MP JPEG) | Survey cold start |
| S-4 | 1 | S-12 (12 MP JPEG) | Survey cold start |
| S-5 | 1 | S-15 (15 MP JPEG) | Survey cold start |
| C-1 | 1 | C-JPEG (ceiling, cold) | Confirmation run 1 |
| C-2 | 1 | C-JPEG (ceiling, cold) | Confirmation run 2 |
| C-3 | 1 | C-JPEG (ceiling, cold) | Confirmation run 3 |
| C-4 | 1 | C-WEBP (cold) → C-REJECT (warm) | Format + rejection |

Each phase: deploy → invoke → delete (confirmed absent). The next phase does not deploy until the prior phase's deletion is confirmed. Phases S-1 through S-5 use the survey function (`CANONICAL_PIXEL_LIMIT = 15_500_000`). Phases C-1 through C-4 use the confirmation function (`CANONICAL_PIXEL_LIMIT = <CHOSEN_CEILING_PX>`).

No schema changes, Storage writes, data reads, or modification of any existing function other than `image-spike` are authorized.

If the survey reveals no level satisfies both thresholds (e.g., even 5 MP exceeds 200 MiB), the runner reports FAIL — no viable ceiling — and no confirmation phase deploys.

---

## Section 4 — Spike Function Design

### 4.1 Shared Design (survey and confirmation functions)

`supabase/functions/image-spike/index.ts` — first line: `// DISPOSABLE — Gate 2B only. Delete after results recorded. Do not merge to main.`

WASM loading is identical to Rev 9:

```typescript
const wasmBytes = await Deno.readFile(
  new URL("../_shared/magick.wasm", import.meta.url),
);
await initializeImageMagick(wasmBytes);
```

Pipeline:
1. `run_id = crypto.randomUUID()`
2. Emit `console.log(JSON.stringify({ event: "invoke", run_id, label }))`
3. Record `mem_before_rss` via `Deno.memoryUsage().rss`; record `t0`
4. Parse image header; extract `width`, `height`
5. If `width × height > CANONICAL_PIXEL_LIMIT` → return pre-decode rejection (`accepted: false, reason: "pre_decode_rejected"`)
6. Full raster decode
7. `img.strip()` (removes all profiles, properties, comments)
8. Re-encode to WebP
9. Verify output bytes (EXIF, ICCP, XMP chunks absent via RIFF parser)
10. Compute SHA-256 (hex, 64 chars)
11. Record `mem_after_rss` via `Deno.memoryUsage().rss`
12. Base64-encode output → `output_bytes`
13. Return response

### 4.2 CANONICAL_PIXEL_LIMIT Values

| Function version | Value | Used in |
|---|---|---|
| Survey | `15_500_000` | Phases S-1 through S-5 |
| Confirmation | `<CHOSEN_CEILING_PX>` (e.g., `10_000_000`) | Phases C-1 through C-4 |

The runner sets the confirmation value in-place via `update_pixel_limit()` before any C-phase deploy (see §11). The operator reviews and approves the change at the mid-run ceiling approval gate.

### 4.3 config.toml Entry

```toml
[functions.image-spike]
static_files = ["./functions/_shared/magick.wasm"]
```

### 4.4 Response Contract

Accepted:
```json
{
  "run_id": "550e8400-e29b-41d4-a716-446655440000",
  "label": "S-10",
  "accepted": true,
  "pixel_count": 10000000,
  "width": 4000,
  "height": 2500,
  "input_size_bytes": 9724898,
  "output_size_bytes": 210432,
  "metadata_clean": true,
  "sha256": "a1b2c3d4...",
  "output_bytes": "<base64>",
  "diagnostic": {
    "mem_before_rss_bytes": 75497472,
    "mem_after_rss_bytes": 178257920,
    "wall_time_ms": 810
  }
}
```

Pre-decode rejection:
```json
{
  "run_id": "...",
  "label": "C-REJECT",
  "accepted": false,
  "reason": "pre_decode_rejected",
  "pixel_count": 10002500,
  "width": 4001,
  "height": 2500
}
```

### 4.5 Authentication

Legacy JWT anon key from forkensics-dev API settings (`anon public`). Runtime environment variable only; never written to any file, echoed, or logged.

---

## Section 5 — Test Manifest

### 5.1 Survey Fixtures (generated once at runner start; JPEG)

| ID | Filename | W | H | Pixels | Min B | Max B | accepted | metadata |
|---|---|---|---|---|---|---|---|---|
| S-5 | test-S-5.jpg | 2500 | 2000 | 5,000,000 | 4,000,000 | 5,500,000 | true | all 6 families |
| S-8 | test-S-8.jpg | 4000 | 2000 | 8,000,000 | 6,500,000 | 9,000,000 | true | all 6 families |
| S-10 | test-S-10.jpg | 4000 | 2500 | 10,000,000 | 8,500,000 | 10,000,000 | true | all 6 families |
| S-12 | test-S-12.jpg | 4000 | 3000 | 12,000,000 | 9,000,000 | 10,000,000 | true | all 6 families |
| S-15 | test-S-15.jpg | 5000 | 3000 | 15,000,000 | 9,000,000 | 10,000,000 | true | all 6 families |

All 6 metadata families: COMMENT, EXIF, GPS, ICC, IPTC, XMP.

Upload ceiling: all fixtures ≤ 10,000,000 bytes. Fixture generator auto-tunes quality downward to stay within band.

### 5.2 Confirmation Fixtures (generated after ceiling is selected and approved)

Confirmation fixture dimensions are taken from the selected survey fixture. If the ceiling is 10 MP, dimensions are 4000×2500.

| ID | Filename | Format | Pixels | accepted | Notes |
|---|---|---|---|---|---|
| C-JPEG | test-C-jpeg.jpg | JPEG | `CHOSEN_CEILING_PX` | true | All 6 metadata families; reuses survey fixture if same MP level |
| C-WEBP | test-C-webp.webp | WebP | `CHOSEN_CEILING_PX` | true | EXIF, GPS, ICC, XMP families (no IPTC/COMMENT in WebP RIFF) |
| C-REJECT | test-C-reject.jpg | JPEG | `CHOSEN_CEILING_PX + ceiling_w` | false | `(ceiling_w + 1) × ceiling_h`; solid color quality=1 |

C-REJECT pixel count is `(ceiling_w + 1) × ceiling_h` — exactly one row of pixels over the limit.

---

## Section 6 — Pass Criteria

### 6.1 Survey Phase Pass Criteria (per phase S-1 through S-5)

| # | Criterion | Threshold |
|---|---|---|
| S1 | curl exit code | 0 |
| S2 | HTTP status | 200 (never 546) |
| S3 | `accepted` field | true |
| S4 | `label` field | matches fixture ID |
| S5 | `run_id` | valid UUID |
| S6 | `width`, `height`, `pixel_count` | match manifest |
| S7 | `input_size_bytes` | equals `wc -c` of fixture |
| S8 | `metadata_clean` | true |
| S9 | `output_bytes` decodes to valid WebP | RIFF/WEBP header |
| S10 | SHA-256 recomputed from `output_bytes` | matches `sha256` field |
| S11 | `output_size_bytes` | equals decoded byte count |
| S12 | RIFF chunk parser | EXIF, ICCP, XMP absent |
| S13 | Cold-start wall time | ≤ 30 s |
| S14 | Bundle size | ≤ 20 MB |
| S15 | `cpu_time_used` (ShutdownEvent) | ≤ 1,500 ms |
| S16 | `memory_used.total` (ShutdownEvent, bytes ÷ 1,048,576) | ≤ 200 MiB |
| S17 | `shutdown_reason` (ShutdownEvent) | `Normal` |

A phase fails S15 or S16 without triggering a hard stop — the result is recorded and the survey continues to the next level. A phase fails S2 with HTTP 546 → hard stop (memory or CPU exceeded Supabase runtime limit; no higher levels can pass).

### 6.2 Ceiling Selection Criterion

A survey level is **viable** if and only if:
- Criteria S1–S14 all pass, AND
- `memory_used.total ÷ 1,048,576 ≤ 200`, AND
- `cpu_time_used ≤ 1,500`

The **selected ceiling** is the highest viable MP level. If no level is viable, the run is FAIL — no viable ceiling.

### 6.3 Confirmation Phase Pass Criteria (C-1 through C-4)

| # | Criterion | Threshold |
|---|---|---|
| C1 | All three C-JPEG runs: criteria S1–S17 | Same as survey |
| C2 | All three C-JPEG `cpu_time_used` | ≤ 1,500 ms |
| C3 | All three C-JPEG `memory_used.total` | ≤ 200 MiB |
| C4 | C-WEBP: criteria S1–S17 | Same as survey |
| C5 | C-REJECT: `accepted` | false |
| C6 | C-REJECT: `reason` | `pre_decode_rejected` |
| C7 | C-REJECT: `pixel_count` | `(ceiling_w + 1) × ceiling_h` |
| C8 | C-REJECT: no WASM decode triggered | Verified by wall_time ≤ 3 s |

---

## Section 7 — Failure and Inconclusive Definitions

**Hard failures (runner exits immediately):**
- HTTP 546 in any survey or confirmation phase
- Bundle size > 20 MB or unparseable
- Any JWT preflight failure
- Any phase deletion fails to confirm (function still listed after delete)
- No survey level satisfies both thresholds (runner reports FAIL — no viable ceiling)
- Ceiling approval gate not confirmed by operator

**Soft failures (accumulated; run continues; tallied in final verdict):**
- Any criterion in §6.1 other than S2=546, for which the runner records FAIL but does not exit
- A survey level fails S15/S16 — recorded but run continues to next level

**INCONCLUSIVE (treated as FAIL):**
- `run_id` not found in logs; `execution_id` not a valid UUID; ShutdownEvent not found for that `execution_id`; `cpu_time_used` or `memory_used.total` absent or non-numeric; operator enters `INCONCLUSIVE`

---

## Section 8 — Telemetry Methodology

### 8.1 Per-Phase Isolation

Each survey and confirmation phase (excluding C-REJECT) requires ShutdownEvent telemetry. The protocol per phase:

1. Invoke the fixture as the **sole** request for that deployment (first and only cold-start request).
2. Record `run_id` from the response body.
3. Function emits `console.log(JSON.stringify({ event: "invoke", run_id, label }))`.
4. **Delete the function** (`delete_confirmed()`).
5. Runner pauses at the telemetry gate; operator performs two-step lookup (§8.2).
6. Operator enters `execution_id`, `cpu_time_used`, `memory_used.total`, `shutdown_reason`.
7. Runner validates and records.

Deletion before telemetry lookup is allowed: Supabase function logs persist independently of the function's deployment status.

### 8.2 Two-Step Log Lookup

**Step 1 — LogEvent → `execution_id`:**

1. Open `https://supabase.com/dashboard/project/hkfrbdpedrxmbsawnbpr/logs/edge-logs`
2. Filter: `metadata.function_id = 'image-spike'`
3. Search log text for the `run_id` printed by the runner.
4. Locate the entry with `"event":"invoke"` and the matching `label`.
5. Record `execution_id` from that log entry.

**Step 2 — ShutdownEvent → telemetry:**

1. In the same Log Explorer, search for the `execution_id` from Step 1.
2. Locate the ShutdownEvent for that `execution_id`.
3. Extract `cpu_time_used` (no `_ms` suffix).
4. Extract `memory_used.total` in **bytes** (the `total` sub-field of the `memory_used` object). Do NOT use WorkerMemoryUsed, Metrics UI, or any other source.
5. Extract `reason` field from ShutdownEvent.

If `execution_id` is not a valid UUID, ShutdownEvent cannot be found, or any field is absent: enter `INCONCLUSIVE`.

### 8.3 Secondary Memory Sanity Check

If `memory_used.total` from ShutdownEvent is more than 50 MiB lower than `diagnostic.mem_after_rss_bytes` from the response body, the runner prints a warning: possible GC before ShutdownEvent; treat ShutdownEvent value as optimistic. The ShutdownEvent value is still used for threshold evaluation.

---

## Section 9 — Ceiling Selection Algorithm

After all survey phases complete (S-1 through S-5), the runner executes this algorithm:

```python
MP_LEVELS = [5, 8, 10, 12, 15]
MEM_THRESHOLD_MIB = 200.0
CPU_THRESHOLD_MS  = 1500.0
MIB = 1_048_576

viable = []
for mp in MP_LEVELS:
    cpu  = survey_cpu[mp]   # ms, float; None if INCONCLUSIVE
    mem  = survey_mem[mp]   # bytes, float; None if INCONCLUSIVE
    if cpu is None or mem is None:
        continue
    mem_mib = mem / MIB
    if mem_mib <= MEM_THRESHOLD_MIB and cpu <= CPU_THRESHOLD_MS:
        viable.append(mp)

chosen = max(viable) if viable else None
```

The runner prints the full survey table (MP level, cpu_time_used, memory_used.total MiB, PASS/FAIL) and the recommended ceiling. The operator must type the chosen MP level (e.g., `10`) to confirm. If the operator enters `NONE` or a different level, the runner records the deviation and uses the operator-entered level (or exits if `NONE`).

---

## Section 10 — Supporting Scripts

### 10.1 gate2b-verify-metadata.py

Unchanged from Rev 9. Verifies WebP RIFF output contains no EXIF, ICCP, or XMP chunks.

### 10.2 gate2b-fixtures-r10.py

Replaces `gate2b-fixtures.py`. Generates survey fixtures S-5, S-8, S-10, S-12, S-15. Confirmation fixtures C-JPEG, C-WEBP, C-REJECT are generated after ceiling selection, called by the runner at the mid-run gate.

Key differences from Rev 9 fixtures.py:

- Fixture set: S-5 through S-15 (no B-series fixtures)
- Each accepted fixture: `_noise_image(w, h, seed=42)` → auto-tune quality to stay within byte band
- `generate_confirmation_fixtures(ceiling_w, ceiling_h, ceiling_px, out_dir)`: generates C-JPEG (reuses S-fixture if already in IMG_DIR), C-WEBP, C-REJECT

```python
#!/usr/bin/env python3
"""gate2b-fixtures-r10.py — Rev 10 fixture generator.
Usage:
  python3 gate2b-fixtures-r10.py <out_dir>
  python3 gate2b-fixtures-r10.py <out_dir> confirm <ceiling_w> <ceiling_h> <ceiling_px>
"""
import sys, os, math, io, struct
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

def _noise_image(w, h, seed=42):
    rng = np.random.default_rng(seed=seed)
    arr = rng.integers(0, 256, (h, w, 3), dtype=np.uint8)
    return Image.fromarray(arr, "RGB")

def _full_exif():
    """Return piexif-compatible EXIF dict with GPS, EXIF IFD."""
    exif = {
        "0th": {
            piexif.ImageIFD.Make: b"ForkensicsTest",
            piexif.ImageIFD.Model: b"Rev10",
            piexif.ImageIFD.Software: b"gate2b-fixtures-r10",
        },
        "Exif": {
            piexif.ExifIFD.ExposureTime: (1, 100),
            piexif.ExifIFD.FNumber: (28, 10),
        },
        "GPS": {
            piexif.GPSIFD.GPSLatitudeRef: b"N",
            piexif.GPSIFD.GPSLatitude: ((37, 1), (46, 1), (30, 1)),
            piexif.GPSIFD.GPSLongitudeRef: b"W",
            piexif.GPSIFD.GPSLongitude: ((122, 1), (25, 1), (0, 1)),
        },
        "1st": {},
        "thumbnail": None,
    }
    return piexif.dump(exif)

def _icc_profile():
    """Minimal sRGB ICC profile stub (32 bytes, passes chunk check)."""
    # 4-byte size + "acsp" signature + 44 zeros = valid enough for RIFF chunk presence
    size = 48
    data = size.to_bytes(4, "big") + b"acsp" + b"\x00" * (size - 8)
    return data

def _xmp_bytes():
    return b'<?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?>\n<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"/></x:xmpmeta><?xpacket end="w"?>'

def _write_jpeg_with_metadata(img, quality, path):
    """Save JPEG with EXIF, ICC, XMP, IPTC stub, COMMENT."""
    exif_bytes = _full_exif()
    icc = _icc_profile()
    xmp = _xmp_bytes()
    img_bytes_io = io.BytesIO()
    img.save(img_bytes_io, "JPEG", quality=quality, exif=exif_bytes,
             icc_profile=icc, comment=b"Gate2B-Rev10-Test")
    raw = img_bytes_io.getvalue()
    # Inject XMP APP1 marker manually after SOI
    # Actual production verification uses piexif + PIL; this gives a parseable XMP block
    xmp_marker = b"\xff\xe1" + (2 + 29 + len(xmp)).to_bytes(2, "big") \
                 + b"http://ns.adobe.com/xap/1.0/\x00" + xmp
    patched = raw[:2] + xmp_marker + raw[2:]
    with open(path, "wb") as f:
        f.write(patched)
    return len(patched)

def _write_webp_with_metadata(img, quality, path):
    """Save WebP with EXIF, ICC, XMP (WebP RIFF allows EXIF, ICCP, XMP chunks)."""
    exif_bytes = _full_exif()
    icc = _icc_profile()
    img_bytes_io = io.BytesIO()
    img.save(img_bytes_io, "WEBP", quality=quality, exif=exif_bytes, icc_profile=icc)
    raw = img_bytes_io.getvalue()
    # Inject XMP chunk into WebP RIFF
    xmp = _xmp_bytes()
    padded_xmp = xmp if len(xmp) % 2 == 0 else xmp + b"\x00"
    xmp_chunk = b"XMP " + len(xmp).to_bytes(4, "little") + padded_xmp
    # Insert before RIFF size ends: append before final padding
    vp8_start = raw.find(b"VP8 ")
    if vp8_start == -1:
        vp8_start = raw.find(b"VP8L")
    if vp8_start == -1:
        vp8_start = raw.find(b"VP8X")
    insert_at = vp8_start if vp8_start > 12 else 12
    patched = raw[:insert_at] + xmp_chunk + raw[insert_at:]
    # Fix RIFF size
    new_riff_size = len(patched) - 8
    patched = patched[:4] + new_riff_size.to_bytes(4, "little") + patched[8:]
    with open(path, "wb") as f:
        f.write(patched)
    return len(patched)

def generate_survey(out_dir):
    os.makedirs(out_dir, exist_ok=True)
    print(f"Gate 2B Rev 10 survey fixture generation (deterministic, seed=42) ...")
    all_ok = True
    for sid, w, h, px, lo, hi, q_start in SURVEY:
        filename = f"test-{sid}.jpg"
        path = os.path.join(out_dir, filename)
        img = _noise_image(w, h, seed=42)
        # Auto-tune quality to stay within byte band and under UPLOAD_CEIL
        q = q_start
        while q >= 50:
            size = _write_jpeg_with_metadata(img, q, path)
            if lo <= size <= hi and size <= UPLOAD_CEIL:
                break
            q -= 3
        if q < 50:
            print(f"FATAL: {sid} cannot fit in band [{lo}, {hi}] — lowest size at q=50", file=sys.stderr)
            sys.exit(1)
        sha = __import__("hashlib").sha256(open(path, "rb").read()).hexdigest()
        ok = "✓" if lo <= size <= hi else "FAIL"
        print(f"\n--- {sid} ({w}x{h}, jpeg) ---")
        print(f"  quality={q}  size={size:,} bytes ({size/1e6:.3f} MB)  sha256={sha[:32]}...")
        print(f"  band=[{lo:,},{hi:,}]  {ok}")
        if ok != "✓":
            all_ok = False
    if not all_ok:
        sys.exit(1)
    print("\n=== Survey fixtures generated ===")

def generate_confirmation(out_dir, ceiling_w, ceiling_h, ceiling_px):
    """Generate C-JPEG, C-WEBP, C-REJECT after ceiling selection."""
    os.makedirs(out_dir, exist_ok=True)
    img = _noise_image(ceiling_w, ceiling_h, seed=42)
    # C-JPEG
    jpeg_path = os.path.join(out_dir, "test-C-jpeg.jpg")
    survey_path = os.path.join(out_dir, f"test-S-{ceiling_px // 1_000_000}.jpg")
    if os.path.exists(survey_path):
        import shutil; shutil.copy(survey_path, jpeg_path)
        size = os.path.getsize(jpeg_path)
        print(f"C-JPEG: reused survey fixture ({size:,} bytes)")
    else:
        q = 85
        while q >= 50:
            size = _write_jpeg_with_metadata(img, q, jpeg_path)
            if size <= 10_000_000:
                break
            q -= 3
        print(f"C-JPEG: generated ({size:,} bytes, quality={q})")
    # C-WEBP
    webp_path = os.path.join(out_dir, "test-C-webp.webp")
    q = 90
    size_w = _write_webp_with_metadata(img, q, webp_path)
    print(f"C-WEBP: {size_w:,} bytes")
    # C-REJECT (ceiling+1 pixel wide, solid color, quality=1, tiny file)
    reject_w = ceiling_w + 1
    reject_h = ceiling_h
    reject_px = reject_w * reject_h
    reject_path = os.path.join(out_dir, "test-C-reject.jpg")
    solid = Image.new("RGB", (reject_w, reject_h), (30, 60, 90))
    solid.save(reject_path, "JPEG", quality=1)
    size_r = os.path.getsize(reject_path)
    print(f"C-REJECT: {reject_w}x{reject_h}={reject_px:,} px, {size_r:,} bytes")
    return {"ceiling_w": ceiling_w, "ceiling_h": ceiling_h, "ceiling_px": ceiling_px,
            "reject_w": reject_w, "reject_h": reject_h, "reject_px": reject_px}

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__); sys.exit(1)
    out_dir = sys.argv[1]
    if len(sys.argv) == 6 and sys.argv[2] == "confirm":
        cw, ch, cp = int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])
        generate_confirmation(out_dir, cw, ch, cp)
    else:
        generate_survey(out_dir)
```

---

## Section 11 — Runner: gate2b-run-r10.sh

```bash
#!/usr/bin/env bash
# tools/image-spike/gate2b-run-r10.sh — Gate 2B Rev 10 test runner
# DISPOSABLE — Gate 2B only. Execute only after three-party approval of Rev 10.
#
# Usage: PROJECT_REF=hkfrbdpedrxmbsawnbpr ANON_KEY=yyy bash tools/image-spike/gate2b-run-r10.sh
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
  || { echo "FATAL: PROJECT_REF must be '$APPROVED_PROJECT_REF' (forkensics-dev); got '$PROJECT_REF'" >&2; exit 1; }
[[ -n "${ANON_KEY:-}" ]] || { echo "FATAL: ANON_KEY not set" >&2; exit 1; }

# ---------------------------------------------------------------------------
# JWT preflight (Rev 9 Patch 3 — unchanged)
# ---------------------------------------------------------------------------
python3 - <<'PYEOF' || { echo "FATAL: ANON_KEY failed JWT preflight" >&2; exit 1; }
import sys, base64, json, os, time
key = os.environ.get('ANON_KEY', '')
ref = os.environ.get('PROJECT_REF', '')
parts = key.split('.')
if len(parts) != 3:
    print(f"FATAL: ANON_KEY has {len(parts)} segment(s), expected 3 (not a JWT)", file=sys.stderr)
    sys.exit(1)
try:
    payload = json.loads(base64.urlsafe_b64decode(parts[1] + '==').decode())
except Exception as e:
    print(f"FATAL: ANON_KEY payload decode failed: {e}", file=sys.stderr)
    sys.exit(1)
role = payload.get('role', '')
if role != 'anon':
    print(f"FATAL: ANON_KEY role='{role}', expected 'anon'", file=sys.stderr)
    sys.exit(1)
jwt_ref = payload.get('ref', '')
if jwt_ref and jwt_ref != ref:
    print(f"FATAL: ANON_KEY ref='{jwt_ref}' does not match PROJECT_REF='{ref}'", file=sys.stderr)
    sys.exit(1)
exp = payload.get('exp')
if exp and int(exp) < int(time.time()):
    print(f"FATAL: ANON_KEY expired (exp={exp})", file=sys.stderr)
    sys.exit(1)
print(f"ANON_KEY preflight: 3-segment JWT, role=anon ✓")
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
IMG_DIR="$REPO_ROOT/tools/image-spike/test-images-r10"
FIXTURES_PY="$SCRIPT_DIR/gate2b-fixtures-r10.py"
VERIFY_PY="$SCRIPT_DIR/gate2b-verify-metadata.py"

TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RESULTS_DIR="$REPO_ROOT/tools/image-spike/gate2b-evidence-r10-${TIMESTAMP}"
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
# Associative: mp_level -> "w h pixels"
declare -A SURVEY_DIMS=(
  [5]="2500 2000 5000000"
  [8]="4000 2000 8000000"
  [10]="4000 2500 10000000"
  [12]="4000 3000 12000000"
  [15]="5000 3000 15000000"
)

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
LAST_RUN_ID=""

# Survey telemetry tables (indexed by MP level: 5 8 10 12 15)
declare -A SURVEY_CPU=()
declare -A SURVEY_MEM=()
declare -A SURVEY_VIABLE=()

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
  echo "Gate 2B Rev 10 Cleanup (trigger: $trigger)" >&2
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
      echo "  Verify manual deletion: https://supabase.com/dashboard/project/$PROJECT_REF/functions" >&2
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

  # Restore config.toml
  if [[ "$CONFIG_PATCHED" == "true" ]] \
     || grep -q '\[functions\.image-spike\]' "$CONFIG" 2>/dev/null; then
    python3 - "$CONFIG" <<'PYEOF'
import re, sys
path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()
cleaned = re.sub(
    r'\n\[functions\.image-spike\]\n(?:(?!\[)[^\n]*\n)*',
    '\n',
    content,
)
with open(path, 'w') as f:
    f.write(cleaned)
print('config.toml: [functions.image-spike] removed', file=sys.stderr)
PYEOF
  fi

  if [[ -f "$WASM_DST" ]];   then rm "$WASM_DST"    && echo "Removed: $WASM_DST" >&2; fi
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
# deploy_function — pre-check, set flag BEFORE deploy, parse bundle size
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
text = sys.argv[1]
m = re.search(r'(?:script|bundle) size:\s*([0-9]+(?:\.[0-9]+)?)\s*(MiB|MB)\b',
              text, re.IGNORECASE)
if m:
    print(m.group(1) + ' ' + m.group(2))
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
raw = sys.argv[1]
parts = raw.split()
num, unit = float(parts[0]), parts[1].upper()
mb = num * 1.048576 if unit == 'MIB' else num
if not (math.isfinite(mb) and mb >= 0):
    print(f"FAIL: bundle {raw} → {mb} is not finite/nonneg"); sys.exit(1)
if mb > 20:
    print(f"FAIL: {raw} = {mb:.2f} MB > 20 MB limit"); sys.exit(1)
print(f"bundle: {raw} = {mb:.2f} MB ≤ 20 MB ✓")
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
    fail "Phase $phase: 'supabase functions list' failed (exit $list_exit)"
    REMOTE_DELETE_FAILED=true; return 1; fi

  if printf '%s' "$list_out" | grep -q "image-spike"; then
    fail "Phase $phase: image-spike still listed after deletion"
    REMOTE_DELETE_FAILED=true; return 1; fi

  echo "Phase $phase deletion: confirmed ✓"
  REMOTE_CLEANUP_REQUIRED=false
  return 0
}

# ---------------------------------------------------------------------------
# invoke_case — single curl + assertions
# exp_accepted: "true" or "false"
# exp_reason: "" (for accepted) or "pre_decode_rejected"
# ---------------------------------------------------------------------------
invoke_case() {
  local label="$1" filename="$2" mime="$3" exp_accepted="$4" exp_reason="$5"
  local exp_w="$6" exp_h="$7" exp_pixels="$8"
  local img="$IMG_DIR/$filename"
  local out="$OUT_DIR/${label}.json"
  local hdr="$OUT_DIR/${label}.headers"
  local webp="$OUT_DIR/${label}_output.webp"
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
    fail "$label: HTTP 546 — resource limit exceeded"; results_append "HARD FAIL: HTTP 546"; exit 1; fi
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

  if [[ "$exp_accepted" == "false" ]]; then
    local resp_reason
    resp_reason=$(jq -r '.reason // "MISSING"' "$out" 2>/dev/null || echo "PARSE_ERROR")
    [[ "$resp_reason" == "$exp_reason" ]] \
      || fail "$label: reason='$resp_reason' ≠ '$exp_reason'"
    results_append "accepted=false  reason=$resp_reason"
    return 0
  fi

  # Accepted-only assertions
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
    if printf '%s' "$resp_output_b64" | base64 -d > "$webp" 2>/dev/null; then
      local decoded_size header_check actual_sha resp_output_size riff_out
      decoded_size=$(wc -c < "$webp" | awk '{print $1}')
      header_check=$(python3 -c "
with open('$webp','rb') as f: d=f.read(12)
print('valid' if d[:4]==b'RIFF' and d[8:12]==b'WEBP' else 'invalid')
" 2>/dev/null || echo "error")
      if [[ "$header_check" != "valid" ]]; then
        fail "$label: decoded output is not valid WebP"
      else
        actual_sha=$(shasum -a 256 "$webp" | awk '{print $1}')
        [[ "$actual_sha" == "$resp_sha256" ]] \
          || fail "$label: SHA-256 mismatch: recomputed=$actual_sha"
        resp_output_size=$(jq -r '.output_size_bytes // 0' "$out" 2>/dev/null || echo 0)
        [[ "$resp_output_size" == "$decoded_size" ]] \
          || fail "$label: output_size_bytes=$resp_output_size ≠ $decoded_size"
        if python3 "$VERIFY_PY" "$webp" 2>&1; then
          echo "  RIFF chunk parser: no metadata ✓"
        else
          fail "$label: RIFF parser found metadata or malformed WebP"
        fi
      fi
    else
      fail "$label: base64 decode of output_bytes failed"
    fi
  fi

  # Secondary memory sanity check
  local mem_after_rss_bytes
  mem_after_rss_bytes=$(jq -r '.diagnostic.mem_after_rss_bytes // 0' "$out" 2>/dev/null || echo 0)
  results_append "diagnostic.mem_after_rss_bytes: $mem_after_rss_bytes"

  results_append "sha256: $resp_sha256"
  results_append "accepted=true  wall_time_s=$wall_time"
  return 0
}

# ---------------------------------------------------------------------------
# telemetry_gate — pause, collect ShutdownEvent fields for one phase
# Sets TELEM_EXEC_ID, TELEM_CPU, TELEM_MEM, TELEM_REASON (bash globals)
# ---------------------------------------------------------------------------
TELEM_EXEC_ID=""
TELEM_CPU=""
TELEM_MEM=""
TELEM_REASON=""

telemetry_gate() {
  local label="$1" run_id="$2"
  echo ""
  echo "================================================================="
  echo "$label TELEMETRY CAPTURE GATE"
  echo "================================================================="
  echo "run_id: ${run_id:-MISSING — check function logs}"
  echo ""
  echo "STEP 1 — Find LogEvent by run_id; extract execution_id:"
  echo "  Open: https://supabase.com/dashboard/project/$PROJECT_REF/logs/edge-logs"
  echo "  Filter: metadata.function_id = 'image-spike'"
  echo "  Search log text for: $run_id"
  echo "  Locate entry with event='invoke', label='$label'. Record execution_id."
  echo ""
  echo "STEP 2 — Find ShutdownEvent by execution_id:"
  echo "  Search for the execution_id."
  echo "  Locate the ShutdownEvent for that execution_id."
  echo "  Extract:"
  echo "    cpu_time_used     (no _ms suffix)"
  echo "    memory_used.total (in bytes — the 'total' sub-field of 'memory_used')"
  echo "    reason            (Normal / Memory / CPU)"
  echo "  DO NOT use WorkerMemoryUsed or Metrics UI tab."
  echo ""
  echo "Enter INCONCLUSIVE for any field if not found."
  echo "================================================================="

  read -rp "$label execution_id (UUID, or INCONCLUSIVE): " TELEM_EXEC_ID
  read -rp "$label cpu_time_used in ms (or INCONCLUSIVE): " TELEM_CPU
  read -rp "$label memory_used.total in bytes (or INCONCLUSIVE): " TELEM_MEM
  read -rp "$label shutdown_reason (Normal/Memory/CPU, or INCONCLUSIVE): " TELEM_REASON
}

# ---------------------------------------------------------------------------
# validate_telemetry — checks inputs; evaluates thresholds; appends to results
# Returns 0 if thresholds satisfied, 1 if INCONCLUSIVE or threshold exceeded
# ---------------------------------------------------------------------------
validate_telemetry() {
  local label="$1"
  results_append ""
  results_append "#### $label Telemetry"
  results_append "execution_id: ${TELEM_EXEC_ID}"
  results_append "cpu_time_used_ms: ${TELEM_CPU}"
  results_append "memory_used.total_bytes: ${TELEM_MEM}"
  results_append "shutdown_reason: ${TELEM_REASON}"

  if [[ "$TELEM_EXEC_ID" == "INCONCLUSIVE" || "$TELEM_CPU" == "INCONCLUSIVE" \
        || "$TELEM_MEM" == "INCONCLUSIVE" || "$TELEM_REASON" == "INCONCLUSIVE" ]]; then
    fail "$label: telemetry INCONCLUSIVE"
    results_append "$label telemetry: INCONCLUSIVE → FAIL"
    return 1
  fi

  if ! is_valid_uuid "$TELEM_EXEC_ID"; then
    fail "$label: execution_id '${TELEM_EXEC_ID}' is not a valid UUID"
    results_append "$label execution_id: INVALID → FAIL"
    return 1
  fi

  python3 - "$TELEM_CPU" "$TELEM_MEM" "$MEM_THRESHOLD_MIB" "$CPU_THRESHOLD_MS" "$label" <<'PYEOF'
import sys, math
cpu_raw, mem_raw, mem_thr, cpu_thr, label = sys.argv[1:]
mem_thr, cpu_thr = float(mem_thr), float(cpu_thr)
try:
    cpu = float(cpu_raw); mem = float(mem_raw)
except ValueError as e:
    print(f"FAIL: non-numeric: {e}"); sys.exit(1)
if not (math.isfinite(cpu) and cpu >= 0):
    print(f"FAIL: cpu {cpu} not finite/nonneg"); sys.exit(1)
if not (math.isfinite(mem) and mem >= 0):
    print(f"FAIL: memory {mem} not finite/nonneg"); sys.exit(1)
mib = mem / 1_048_576
cpu_ok  = cpu <= cpu_thr
mem_ok  = mib <= mem_thr
print(f"cpu_time_used: {cpu:.0f} ms ({'≤' if cpu_ok else '>'} {cpu_thr:.0f} ms) {'✓' if cpu_ok else 'FAIL'}")
print(f"memory_used.total: {mem:.0f} bytes = {mib:.1f} MiB ({'≤' if mem_ok else '>'} {mem_thr:.0f} MiB) {'✓' if mem_ok else 'FAIL'}")
if not cpu_ok or not mem_ok:
    sys.exit(2)
print(f"{label} telemetry: PASS")
PYEOF
  local telem_exit=$?
  results_append "$label telemetry_exit: $telem_exit"
  return $telem_exit
}

# ---------------------------------------------------------------------------
# update_pixel_limit — modifies CANONICAL_PIXEL_LIMIT in index.ts in-place
# ---------------------------------------------------------------------------
update_pixel_limit() {
  local new_limit="$1"
  python3 - "$SPIKE_DIR/index.ts" "$new_limit" <<'PYEOF' \
    || { echo "FATAL: could not update CANONICAL_PIXEL_LIMIT in index.ts" >&2; exit 1; }
import sys, re
path, limit = sys.argv[1], sys.argv[2]
with open(path, 'r') as f: content = f.read()
new = re.sub(r'(CANONICAL_PIXEL_LIMIT\s*=\s*)\d[\d_]*', rf'\g<1>{limit}', content)
if new == content:
    print("FATAL: CANONICAL_PIXEL_LIMIT not found or unchanged in index.ts", file=sys.stderr)
    sys.exit(1)
with open(path, 'w') as f: f.write(new)
print(f"CANONICAL_PIXEL_LIMIT updated to {limit}")
PYEOF
  echo "index.ts CANONICAL_PIXEL_LIMIT → $new_limit ✓"
}

# ===========================================================================
# PREFLIGHT
# ===========================================================================
echo "=== Gate 2B Rev 10 Preflight ==="

# Rev 9 evidence check
REV9_EVIDENCE="$REPO_ROOT/tools/image-spike/gate2b-evidence-20260814T194105Z/gate2b-results.md"
REV9_SHA="3903f9dc08bb7edc77720911a614a9656ad97b5c9e42a04c9a50d60f3fd1bc4f"
if [[ ! -f "$REV9_EVIDENCE" ]]; then
  echo "FATAL: Rev 9 evidence missing: $REV9_EVIDENCE" >&2; exit 1; fi
actual_sha=$(shasum -a 256 "$REV9_EVIDENCE" | awk '{print $1}')
[[ "$actual_sha" == "$REV9_SHA" ]] \
  || { echo "FATAL: Rev 9 evidence SHA mismatch: got $actual_sha" >&2; exit 1; }
echo "Rev 9 evidence SHA: verified ✓"

[[ -d "$IMG_DIR" ]]     && { echo "FATAL: IMG_DIR exists — delete before running" >&2; exit 1; }
[[ -d "$RESULTS_DIR" ]] && { echo "FATAL: RESULTS_DIR collision" >&2; exit 1; }
[[ -f "$WASM_DST" ]]    && { echo "FATAL: $WASM_DST exists — clean up" >&2; exit 1; }
grep -q '\[functions\.image-spike\]' "$CONFIG" 2>/dev/null \
  && { echo "FATAL: [functions.image-spike] already in config.toml" >&2; exit 1; }

for tool in supabase curl jq python3 shasum deno; do
  command -v "$tool" &>/dev/null || { echo "FATAL: $tool not found" >&2; exit 1; }
done
for f in "$WASM_SRC" "$VERIFY_PY" "$FIXTURES_PY"; do
  [[ -f "$f" ]] || { echo "FATAL: file not found: $f" >&2; exit 1; }
done
[[ -d "$SPIKE_DIR" ]] || { echo "FATAL: spike dir not found: $SPIKE_DIR" >&2; exit 1; }

# Verify CANONICAL_PIXEL_LIMIT in index.ts is at the survey value
python3 - "$SPIKE_DIR/index.ts" "$SURVEY_PIXEL_LIMIT" <<'PYEOF' \
  || { echo "FATAL: index.ts CANONICAL_PIXEL_LIMIT is not $SURVEY_PIXEL_LIMIT — set it before running" >&2; exit 1; }
import sys, re
path, expected = sys.argv[1], sys.argv[2]
with open(path) as f: content = f.read()
m = re.search(r'CANONICAL_PIXEL_LIMIT\s*=\s*([\d_]+)', content)
if not m:
    print("FATAL: CANONICAL_PIXEL_LIMIT not found", file=sys.stderr); sys.exit(1)
actual = m.group(1).replace('_', '')
if actual != expected.replace('_', ''):
    print(f"FATAL: CANONICAL_PIXEL_LIMIT={actual}, expected {expected}", file=sys.stderr); sys.exit(1)
print(f"CANONICAL_PIXEL_LIMIT={actual} ✓")
PYEOF

mkdir -p "$OUT_DIR"
> "$RESULTS_MD"
results_append "# Gate 2B Results — Rev 10"
results_append "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
results_append "RESULTS_DIR: $RESULTS_DIR"
results_append "PROJECT_REF: $PROJECT_REF"
results_append "SURVEY_PIXEL_LIMIT: $SURVEY_PIXEL_LIMIT"
results_append "MEM_THRESHOLD_MIB: $MEM_THRESHOLD_MIB"
results_append "CPU_THRESHOLD_MS: $CPU_THRESHOLD_MS"
results_append ""
echo "Preflight: all checks passed"

# ===========================================================================
# GENERATE SURVEY FIXTURES
# ===========================================================================
echo ""; echo "=== Generating survey fixtures ==="
python3 "$FIXTURES_PY" "$IMG_DIR" \
  || { echo "FATAL: survey fixture generation failed" >&2; exit 1; }

# ===========================================================================
# VERIFY SURVEY FIXTURES AGAINST MANIFEST
# ===========================================================================
echo ""; echo "=== Verifying survey fixtures ==="
results_append "## Fixture Preflight"
preflight_ok=true
for entry in "${SURVEY_FIXTURES[@]}"; do
  IFS="|" read -r sid filename exp_w exp_h exp_pixels min_bytes max_bytes <<< "$entry"
  img="$IMG_DIR/$filename"
  [[ -f "$img" ]] || { echo "FATAL: $img missing" >&2; exit 1; }
  byte_size=$(wc -c < "$img" | awk '{print $1}')
  sha=$(shasum -a 256 "$img" | awk '{print $1}')
  dims=$(python3 -c "
from PIL import Image
with Image.open('$img') as im:
    print(im.width, im.height)
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
    || { fail "PREFLIGHT $sid: size $byte_size outside [$min_bytes, $max_bytes]"; ok=false; }
  [[ "$byte_size" -le 10000000 ]] \
    || { fail "PREFLIGHT $sid: size $byte_size > 10 MB upload ceiling"; ok=false; }
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
declare -a SURVEY_MP_ORDER=(5 8 10 12 15)

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
  phase_run_id="$LAST_RUN_ID"
  phase_wall="$LAST_WALL_TIME"

  echo "$sid cold wall-clock: ${phase_wall}s (threshold ≤ 30 s)"
  python3 -c "import sys; sys.exit(0 if float('$phase_wall') <= 30 else 1)" 2>/dev/null \
    || fail "$sid: cold wall-clock ${phase_wall}s > 30 s"
  results_append "$sid cold_wall_time_s: $phase_wall"

  # Read secondary memory from response (sanity check only — not threshold)
  mem_after_rss=$(jq -r '.diagnostic.mem_after_rss_bytes // 0' \
    "$OUT_DIR/${sid}.json" 2>/dev/null || echo 0)

  delete_confirmed "$phase_label" || exit 1

  telemetry_gate "$sid" "$phase_run_id"
  validate_telemetry "$sid"
  telem_ok=$?

  # Secondary sanity check
  if [[ "$TELEM_MEM" != "INCONCLUSIVE" ]] && python3 -c "
import sys
mem = float('$TELEM_MEM'); rss = float('$mem_after_rss')
gap = rss - mem
if rss > 0 and gap > 50 * 1048576:
    print(f'WARNING: ShutdownEvent memory ({mem/1048576:.1f} MiB) is {gap/1048576:.1f} MiB below '
          f'diagnostic.mem_after_rss ({rss/1048576:.1f} MiB) — possible GC before ShutdownEvent')
    sys.exit(0)
" 2>&1; then true; fi

  # Record for ceiling selection
  if [[ $telem_ok -eq 0 ]]; then
    SURVEY_CPU[$mp]="$TELEM_CPU"
    SURVEY_MEM[$mp]="$TELEM_MEM"
    SURVEY_VIABLE[$mp]="true"
  else
    SURVEY_CPU[$mp]="${TELEM_CPU}"
    SURVEY_MEM[$mp]="${TELEM_MEM}"
    SURVEY_VIABLE[$mp]="false"
  fi
done

# ===========================================================================
# CEILING SELECTION
# ===========================================================================
echo ""; echo "================================================================="
echo "=== CEILING SELECTION ==="
echo "================================================================="
results_append ""; results_append "## Ceiling Selection"

# Build JSON for Python
python3 - \
  "${SURVEY_CPU[5]:-INCONCLUSIVE}" \
  "${SURVEY_MEM[5]:-INCONCLUSIVE}" \
  "${SURVEY_CPU[8]:-INCONCLUSIVE}" \
  "${SURVEY_MEM[8]:-INCONCLUSIVE}" \
  "${SURVEY_CPU[10]:-INCONCLUSIVE}" \
  "${SURVEY_MEM[10]:-INCONCLUSIVE}" \
  "${SURVEY_CPU[12]:-INCONCLUSIVE}" \
  "${SURVEY_MEM[12]:-INCONCLUSIVE}" \
  "${SURVEY_CPU[15]:-INCONCLUSIVE}" \
  "${SURVEY_MEM[15]:-INCONCLUSIVE}" \
  "$MEM_THRESHOLD_MIB" "$CPU_THRESHOLD_MS" <<'PYEOF'
import sys, math

args = sys.argv[1:]
mp_levels = [5, 8, 10, 12, 15]
results = {}
for i, mp in enumerate(mp_levels):
    cpu_raw = args[i*2]
    mem_raw = args[i*2+1]
    results[mp] = (cpu_raw, mem_raw)

mem_thr = float(args[-2])
cpu_thr = float(args[-1])
MIB = 1_048_576

print("\nSurvey Results:")
print(f"{'MP':>4}  {'CPU (ms)':>10}  {'Mem (MiB)':>11}  {'CPU ≤1500':>10}  {'Mem ≤200':>9}  {'Viable':>7}")
print("-" * 65)

viable = []
for mp in mp_levels:
    cpu_raw, mem_raw = results[mp]
    try:
        cpu = float(cpu_raw)
        mem = float(mem_raw)
        mem_mib = mem / MIB
        cpu_ok = cpu <= cpu_thr
        mem_ok = mem_mib <= mem_thr
        viable_flag = cpu_ok and mem_ok
        if viable_flag:
            viable.append(mp)
        print(f"{mp:>4}  {cpu:>10.0f}  {mem_mib:>11.1f}  {'YES' if cpu_ok else 'NO':>10}  {'YES' if mem_ok else 'NO':>9}  {'YES' if viable_flag else 'NO':>7}")
    except (ValueError, TypeError):
        print(f"{mp:>4}  {'INCONCLUSIVE':>10}  {'INCONCLUSIVE':>11}  {'-':>10}  {'-':>9}  {'NO':>7}")

print("-" * 65)
if viable:
    chosen = max(viable)
    dims = {5: "2500×2000", 8: "4000×2000", 10: "4000×2500", 12: "4000×3000", 15: "5000×3000"}
    px   = {5: 5000000, 8: 8000000, 10: 10000000, 12: 12000000, 15: 15000000}
    print(f"\nRecommended ceiling: {chosen} MP ({dims[chosen]}, {px[chosen]:,} px)")
    print(f"Viable levels: {viable}")
else:
    print("\nNo viable ceiling found — both thresholds cannot be satisfied.")
    sys.exit(1)
PYEOF
ceiling_exit=$?

if [[ $ceiling_exit -ne 0 ]]; then
  fail "No viable pixel ceiling found — both thresholds exceeded at all survey levels"
  results_append "CEILING SELECTION: FAIL — no viable ceiling"
  exit 1
fi

echo ""
read -rp "Confirm ceiling MP level (enter number, e.g. '10', or NONE to abort): " operator_ceiling

if [[ "$operator_ceiling" == "NONE" ]]; then
  echo "Ceiling approval rejected by operator." >&2; exit 1; fi

CHOSEN_MP="$operator_ceiling"
read -r CHOSEN_W CHOSEN_H CHOSEN_PX <<< "${SURVEY_DIMS[$CHOSEN_MP]}"
results_append "Operator-confirmed ceiling: ${CHOSEN_MP} MP (${CHOSEN_W}x${CHOSEN_H}, ${CHOSEN_PX} px)"
echo "Ceiling confirmed: ${CHOSEN_MP} MP (${CHOSEN_W}×${CHOSEN_H}, ${CHOSEN_PX} px)"

# ===========================================================================
# GENERATE CONFIRMATION FIXTURES
# ===========================================================================
echo ""; echo "=== Generating confirmation fixtures ==="
python3 "$FIXTURES_PY" "$IMG_DIR" confirm "$CHOSEN_W" "$CHOSEN_H" "$CHOSEN_PX" \
  || { echo "FATAL: confirmation fixture generation failed" >&2; exit 1; }

REJECT_W=$((CHOSEN_W + 1))
REJECT_H=$CHOSEN_H
REJECT_PX=$((REJECT_W * REJECT_H))

# ===========================================================================
# MID-RUN APPROVAL GATE — confirmation function review
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
echo "CANONICAL_PIXEL_LIMIT has been updated to: $CHOSEN_PX"
echo "index.ts sha256: $CONFIRM_INDEX_HASH"
echo ""
echo "Review the updated CANONICAL_PIXEL_LIMIT in $SPIKE_DIR/index.ts."
echo "All three parties must approve this change before confirmation deploys."
read -rp "Type YES to confirm and proceed with confirmation phases: " _cconfirm
[[ "$_cconfirm" == "YES" ]] || { echo "Confirmation deployment aborted." >&2; exit 1; }

results_append "Mid-run ceiling approval: YES"

# ===========================================================================
# CONFIRMATION PHASES C-1, C-2, C-3 — three fresh JPEG cold starts
# ===========================================================================
results_append ""; results_append "## Confirmation Phases — JPEG"
declare -a CONFIRM_CPU=() CONFIRM_MEM=()

for i in 1 2 3; do
  clabel="C-${i}"
  results_append ""; results_append "### Phase $clabel"
  echo ""; echo "=== CONFIRMATION PHASE $clabel (JPEG cold start $i/3) ==="

  deploy_function "$clabel" || exit 1

  invoke_case "$clabel" "test-C-jpeg.jpg" "image/jpeg" "true" "" \
    "$CHOSEN_W" "$CHOSEN_H" "$CHOSEN_PX"
  phase_run_id="$LAST_RUN_ID"
  phase_wall="$LAST_WALL_TIME"

  echo "$clabel cold wall-clock: ${phase_wall}s (threshold ≤ 30 s)"
  python3 -c "import sys; sys.exit(0 if float('$phase_wall') <= 30 else 1)" \
    || fail "$clabel: cold wall-clock ${phase_wall}s > 30 s"
  results_append "$clabel cold_wall_time_s: $phase_wall"

  delete_confirmed "$clabel" || exit 1

  telemetry_gate "$clabel" "$phase_run_id"
  validate_telemetry "$clabel"
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
webp_run_id="$LAST_RUN_ID"
webp_wall="$LAST_WALL_TIME"
echo "C-WEBP cold wall-clock: ${webp_wall}s"
results_append "C-WEBP cold_wall_time_s: $webp_wall"

# Warm: rejection (ceiling+1 pixel — same deployment, no cold start needed)
invoke_case "C-REJECT" "test-C-reject.jpg" "image/jpeg" "false" "pre_decode_rejected" \
  "$REJECT_W" "$REJECT_H" "$REJECT_PX"
reject_wall="$LAST_WALL_TIME"
echo "C-REJECT wall-clock: ${reject_wall}s (expected < 3 s — no WASM decode)"
python3 -c "import sys; sys.exit(0 if float('$reject_wall') < 3 else 1)" \
  || fail "C-REJECT wall-clock ${reject_wall}s ≥ 3 s — WASM may have been invoked"
results_append "C-REJECT wall_time_s: $reject_wall"

delete_confirmed "C-4" || exit 1

# Telemetry for C-WEBP cold start only
telemetry_gate "C-WEBP" "$webp_run_id"
validate_telemetry "C-WEBP"

# ===========================================================================
# FINAL VERDICT
# ===========================================================================
echo ""; echo "================================================================="
results_append ""; results_append "## Final Verdict"

# Print confirmation telemetry summary
echo "Confirmation CPU (ms): ${CONFIRM_CPU[*]:-n/a}"
echo "Confirmation Mem (bytes): ${CONFIRM_MEM[*]:-n/a}"
results_append "Confirmation CPU ms: ${CONFIRM_CPU[*]:-n/a}"
results_append "Confirmation Mem bytes: ${CONFIRM_MEM[*]:-n/a}"
results_append "Chosen ceiling: ${CHOSEN_MP} MP (${CHOSEN_W}x${CHOSEN_H}, ${CHOSEN_PX} px)"

if [[ "$GATE2B_PASS" == "true" ]]; then
  echo "Gate 2B Rev 10: PASS"
  echo "CANONICAL_PIXEL_LIMIT established: $CHOSEN_PX (${CHOSEN_MP} MP)"
  results_append "Verdict: PASS"
  results_append "CANONICAL_PIXEL_LIMIT: $CHOSEN_PX (${CHOSEN_MP} MP, ${CHOSEN_W}x${CHOSEN_H})"
else
  echo "Gate 2B Rev 10: FAIL"
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

Before the first `supabase functions deploy` of the run:

1. `python3 gate2b-fixtures-r10.py test-images-r10/` — verify all survey fixture sizes and metadata families
2. `bash gate2b-local-test-r10.sh` — S-5 (accepted) and C-REJECT template (pre_decode_rejected) must pass against local Edge Runtime
3. `deno fmt --check supabase/functions/image-spike/index.ts`
4. `deno lint supabase/functions/image-spike/index.ts`
5. `deno check supabase/functions/image-spike/index.ts`
6. `gitleaks detect`
7. `shasum -a 256 tools/image-spike/magick.wasm supabase/functions/image-spike/index.ts`
8. Confirm `CANONICAL_PIXEL_LIMIT = 15_500_000` in index.ts
9. Submit all artifacts + outputs; receive three-party sign-off

---

## Section 13 — Results Format

Each run produces a unique `gate2b-evidence-r10-<TIMESTAMP>/` directory (never deleted). Structure:

```
gate2b-evidence-r10-<TIMESTAMP>/
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
    C-WEBP.json  C-WEBP.headers  C-WEBP_output.webp
    C-REJECT.json  C-REJECT.headers
```

---

## Section 14 — iOS / Swift Client Requirement

The `CANONICAL_PIXEL_LIMIT` established by Gate 2B Rev 10 is the mandatory pixel ceiling for all images uploaded through the iOS client.

**Client-side obligations:**

1. Before any upload, the Swift client MUST check the pixel count (`width × height`) of the selected image.
2. If `width × height > CANONICAL_PIXEL_LIMIT`, the client MUST downscale and re-encode (JPEG or HEIF → JPEG) to fit within the limit before calling the upload endpoint. This is not a best-effort operation; it is a hard prerequisite.
3. The client MUST NOT trust the server to accept oversized images gracefully — the server will reject pre-decode and return `accepted: false, reason: pre_decode_rejected`.
4. The client-side downscale does NOT replace server-side validation and sanitization. The server remains the authoritative sanitizer.

**Rationale:** Client-only sanitation (trusting the client to sanitize without server enforcement) is rejected by project security policy. Server-only sanitation at 20 MP exceeded the Edge Runtime memory limit. The established ceiling (≤ 200 MiB / ≤ 1,500 ms) with mandatory client-side downscaling is the approved architecture.

---

## Approval Request

Gate 2B Rev 9 is closed as FAIL (memory limit exceeded at 20 MP). Rev 10 has been designed to find the viable ceiling in ascending order with a 56 MiB headroom below the runtime limit and a 500 ms headroom below the CPU ceiling.

No cloud operation has been performed. This is a DRAFT proposal.

Requested action: three-party sign-off (Bill + Claude + Codex) using the magic words:

**`APPROVED: Gate 2B Rev 10 — Pixel Ceiling Discovery Spike`**
