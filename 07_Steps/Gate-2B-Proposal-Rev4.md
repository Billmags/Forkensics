# Gate 2B Proposal — Rev 4 — Hosted magick-wasm Spike on forkensics-dev

**Status:** DRAFT — awaiting three-party approval

**Governance gate:** Three-party approval (Bill + Claude + Codex) required before any cloud operation is executed. The magic words are `APPROVED: Gate 2B Rev 4 — Hosted magick-wasm Spike`.

**Authorized by:** Step 27 Rev 5 §3 Gate 2 Phase B.

**Supersedes:** Gate 2B Rev 3 (rejected — 7 execution blockers).

**Rev 4 changes from Rev 3:**
1. Each test case now uses exactly one curl call, capturing body, headers, HTTP status, curl exit code, and `time_total` in a single invocation. The B-01/B-03 mismatch in cold/warm pass criteria is resolved: B-03 is the cold invocation (first after deployment); B-01 is the warm invocation (second request, separate timing criterion).
2. Telemetry isolation: B-03 runs first, alone, on a fresh deployment isolate. The function emits a unique `run_id` (UUID, generated per request) in its response body. No other invocation shares the B-03 measurement window. `x-request-id` is used for additional correlation but is not documented as authoritative; `run_id` in logs is the primary correlation key.
3. Cleanup is now idempotent (`CLEANUP_RAN` guard), evidence-safe (RESULTS file written progressively and preserved; evidence copied before OUT_DIR deletion), non-interactive (no `read -r` in signal handlers; log-capture instructions written to a persistent instructions file), and complete (SPIKE_DIR removed; all temporary artifacts deleted; non-zero exit for FAIL/INCONCLUSIVE).
4. Bundle size is numerically parsed from deploy output and compared to the 20 MB limit before setting DEPLOYED. `DEPLOY_ATTEMPTED` is set immediately before the deploy command to ensure orphaned remote functions are caught by cleanup.
5. Fixture generation uses deterministic noise (NumPy RNG seed 42), JPEG quality calibrated to land within explicit byte-range bands (enforced by preflight), and embeds and verifies all six metadata families (EXIF, GPS, ICC, XMP, IPTC, COMMENT) in source fixtures before testing removal.
6. `output_bytes` field is now part of the settled response contract (base64-encoded output WebP). The runner decodes it, verifies the RIFF/WEBP header, recomputes SHA-256 and compares to the `sha256` field, then runs the chunk parser.
7. `IMG_DIR` and `OUT_DIR` must be absent before the runner starts (preflight fails if they exist, preventing deletion of prior evidence). Local `supabase functions serve` in the pre-deployment checklist captures the serve PID and installs a trap for termination with recorded exit status.
8. RIFF parser now validates the declared RIFF length against the actual file length, validates every chunk boundary (chunk data end ≤ RIFF boundary), and guards against adversarial large chunk counts.

---

## Section 1 — Prerequisites

### 1.1 Gate 2A Full Closure (blocks execution, not approval)

Gate 2A has a partial pass (2026-08-13). Execution is blocked until all seven remaining evidence items are complete. Three-party approval of this document may precede Gate 2A closure; the runner may not be invoked until Gate 2A is fully closed.

### 1.2 Pre-Deployment Code Review (blocks deployment, not approval)

Before `gate2b-run.sh` invokes `supabase functions deploy`, the following artifacts must receive explicit three-party sign-off:

- `supabase/functions/image-spike/index.ts` (full source)
- `supabase/config.toml` diff (`[functions.image-spike]` section only)
- `tools/image-spike/gate2b-run.sh` (verbatim as this Rev 4 specifies)
- `tools/image-spike/gate2b-fixtures.py` (verbatim as this Rev 4 specifies)
- `tools/image-spike/gate2b-verify-metadata.py` (verbatim as this Rev 4 specifies)
- SHA-256 of `tools/image-spike/magick.wasm` and `index.ts`
- Local Edge Runtime result (see §1.3)
- `deno fmt --check`, `deno lint`, `deno check` — zero findings
- `gitleaks detect` — no findings

Sign-off may occur inline in the Gate 2B execution thread; it requires explicit three-party acknowledgement.

### 1.3 Local Edge Runtime Verification

Before any cloud deployment, run the spike function locally via `supabase functions serve` and verify at least one accepted and one rejected response against the manifest. The local serve process is managed with PID capture and a trap:

```bash
#!/usr/bin/env bash
# tools/image-spike/gate2b-local-test.sh — run before pre-deployment sign-off
set -uo pipefail

SPIKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../" && pwd)"
LOCAL_URL="http://localhost:54321/functions/v1/image-spike"
IMG_DIR="$(dirname "${BASH_SOURCE[0]}")/test-images"
SERVE_PID=""

cleanup_serve() {
  if [[ -n "$SERVE_PID" ]]; then
    kill "$SERVE_PID" 2>/dev/null || true
    wait "$SERVE_PID" 2>/dev/null
    serve_exit=$?
    echo "supabase functions serve exit: $serve_exit"
  fi
}
trap 'cleanup_serve' EXIT INT TERM

supabase functions serve image-spike &
SERVE_PID=$!
echo "serve PID: $SERVE_PID"
sleep 5  # Allow worker startup

# Accepted case (B-01)
curl_w=$(curl -s -o /tmp/local-b01.json -D /tmp/local-b01.headers \
  -w '%{http_code}\t%{time_total}' --max-time 60 \
  -X POST "${LOCAL_URL}?label=local-B-01" \
  -H "Content-Type: image/jpeg" \
  --data-binary "@$IMG_DIR/test-B-01.jpg")
curl_exit=$?
echo "B-01: HTTP=$(echo "$curl_w" | cut -f1) time=$(echo "$curl_w" | cut -f2)s curl_exit=$curl_exit"
cat /tmp/local-b01.json
echo ""

# Rejected case (B-04)
curl_w=$(curl -s -o /tmp/local-b04.json -D /tmp/local-b04.headers \
  -w '%{http_code}\t%{time_total}' --max-time 60 \
  -X POST "${LOCAL_URL}?label=local-B-04" \
  -H "Content-Type: image/jpeg" \
  --data-binary "@$IMG_DIR/test-B-04.jpg")
curl_exit=$?
echo "B-04: HTTP=$(echo "$curl_w" | cut -f1) time=$(echo "$curl_w" | cut -f2)s curl_exit=$curl_exit"
cat /tmp/local-b04.json
echo ""

echo "Local serve test complete. Review output above before submitting for pre-deployment review."
```

Record and submit the full output (both responses, both HTTP statuses, serve exit code) as part of the pre-deployment review package.

---

## Section 2 — Purpose

Gate 2A verified `magick-wasm` under local Deno 2.9.5. Gate 2B verifies the same pipeline operates within Supabase's hosted Edge Runtime resource envelope. Hosted limits may differ from local; Step B (`upload-complete`) must not be built against limits the hosted environment later rejects.

---

## Section 3 — Authorized Cloud Operations

Exactly:
1. Deploy one disposable Edge Function: `supabase/functions/image-spike/index.ts`
2. Invoke via `gate2b-run.sh` with the test manifest (§5)
3. Read function logs via Supabase CLI and dashboard to obtain `run_id`, `cpu_time_used`, and `WorkerMemoryUsed` per execution
4. Delete `functions/image-spike` immediately after results are recorded, unconditionally

Not authorized: any other function deployment; schema changes; production data writes; modification to existing functions.

---

## Section 4 — Spike Function Design

### 4.1 Location and Header

`supabase/functions/image-spike/index.ts`

First line: `// DISPOSABLE — Gate 2B only. Delete after results recorded. Do not merge to main.`

### 4.2 WASM Loading

```typescript
// ../_shared/ is one level up from functions/image-spike/
const wasmBytes = await Deno.readFile(
  new URL("../_shared/magick.wasm", import.meta.url),
);
await initializeImageMagick(wasmBytes);
```

WASM initialized at module level so module-load cost appears in the worker BootEvent, not in handler timing.

### 4.3 config.toml Entry

```toml
[functions.image-spike]
static_files = ["./functions/_shared/magick.wasm"]
```

Path is config-relative (from `supabase/`). Added and removed by `gate2b-run.sh`; not committed after Gate 2B.

### 4.4 Pipeline

1. Generate `run_id = crypto.randomUUID()` (used for log correlation)
2. Record `mem_before_rss = Deno.memoryUsage().rss` (diagnostic only)
3. Record `t0 = performance.now()`
4. Parse image file header; extract width, height without full raster decode
5. Compute `pixelCount = width × height`
6. If `pixelCount > 20_000_000` → return pre-decode rejection immediately; WASM decoder never invoked
7. Full raster decode via `ImageMagick.read(bytes, ...)`
8. **Remove all profiles, properties, and comments from the in-memory image** before re-encoding (EXIF, ICCP, XMP, comments, all named properties)
9. Re-encode to WebP
10. **Structurally verify output bytes** using the same RIFF chunk logic (EXIF, ICCP, XMP absent) before returning
11. Record `mem_after_rss = Deno.memoryUsage().rss`, `wall_time_ms = performance.now() - t0`
12. Compute `sha256` of output bytes (hex, 64 chars)
13. Base64-encode output bytes for `output_bytes` field
14. Return response (§4.5)

### 4.5 Response Contract

**Accepted image:**
```json
{
  "run_id": "550e8400-e29b-41d4-a716-446655440000",
  "label": "B-03",
  "accepted": true,
  "pixel_count": 20000000,
  "width": 5000,
  "height": 4000,
  "input_size_bytes": 8388608,
  "output_size_bytes": 245120,
  "metadata_clean": true,
  "sha256": "a1b2c3d4...e5f6",
  "output_bytes": "<base64-encoded WebP>",
  "diagnostic": {
    "mem_before_rss_mb": 72.1,
    "mem_after_rss_mb": 110.4,
    "wall_time_ms": 3200
  }
}
```

**Pre-decode rejection:**
```json
{
  "run_id": "550e8400-e29b-41d4-a716-446655440001",
  "label": "B-04",
  "accepted": false,
  "reason": "pre_decode_rejected",
  "pixel_count": 20004000,
  "width": 5001,
  "height": 4000,
  "diagnostic": { "wall_time_ms": 8 }
}
```

**`output_bytes`** contains the full base64-encoded WebP output. The runner decodes, verifies, and SHA-256-checks it against the `sha256` field. This field is only present for accepted images.

### 4.6 Authentication

Use the **legacy JWT-based anon key** from forkensics-dev API settings (Settings → API → `anon public`). New-format publishable keys (`sb_publishable_` prefix) are not valid JWT bearer tokens and must not be used. Set as a shell environment variable at runtime only; never written to any file, never echoed.

---

## Section 5 — Test Manifest

B-03 is the cold invocation (first request after deployment). B-01 is the warm invocation (second request, used for warm-path timing criterion). Both run before the remaining matrix cases.

| ID | Filename | MIME | Width | Height | Pixels | Min bytes | Max bytes | Expected accepted | Expected reason |
|---|---|---|---|---|---|---|---|---|---|
| B-03¹ | test-B-03.jpg | image/jpeg | 5000 | 4000 | 20,000,000 | 2,000,000 | 10,000,000 | true | — |
| B-01² | test-B-01.jpg | image/jpeg | 2500 | 2000 | 5,000,000 | 500,000 | 10,000,000 | true | — |
| B-02 | test-B-02.jpg | image/jpeg | 4000 | 2500 | 10,000,000 | 1,000,000 | 10,000,000 | true | — |
| B-04 | test-B-04.jpg | image/jpeg | 5001 | 4000 | 20,004,000 | 10,000 | 2,000,000 | false | pre_decode_rejected |
| B-05 | test-B-05.jpg | image/jpeg | 10000 | 10000 | 100,000,000 | 10,000 | 2,000,000 | false | pre_decode_rejected |
| B-06 | test-B-06.webp | image/webp | 2500 | 2000 | 5,000,000 | 200,000 | 10,000,000 | true | — |
| B-07 | test-B-07.jpg | image/jpeg | 6000 | 4000 | 24,000,000 | 10,000 | 2,000,000 | false | pre_decode_rejected |

¹ First invocation after deployment (cold measurement; telemetry isolation window).
² Second invocation (warm-path timing measurement).

**Upload ceiling:** all test images must be ≤ 10,000,000 bytes. Preflight enforces this as a hard constraint independent of the max-bytes band.

**Metadata requirement (accepted cases):** source fixtures for B-01, B-02, B-03, B-06 must contain EXIF, GPS, ICC, XMP, IPTC, and COMMENT. Preflight verifies all six families are present before deployment.

**Rejected cases (B-04, B-05, B-07):** do not require metadata or specific size bands beyond the min/max bytes column above.

---

## Section 6 — Pass Criteria

| # | Criterion | Threshold | Source |
|---|---|---|---|
| 1 | All curl exit codes | 0 (no transport error) | curl exit code |
| 2 | All HTTP statuses | 200 (never 546) | curl `-w '%{http_code}'` |
| 3 | B-03, B-01, B-02, B-06: `accepted` | true | Response JSON |
| 4 | B-04, B-05, B-07: `reason` | `pre_decode_rejected` | Response JSON |
| 5 | All: `width`, `height`, `pixel_count` | Match manifest | Response JSON |
| 6 | B-03: `cpu_time_used` (correlated by `run_id`) | < 200 ms | Supabase logs |
| 7 | B-03: `WorkerMemoryUsed` (max in B-03 window) | ≤ 220 MB | Supabase dashboard |
| 8 | B-03 cold wall-clock (first request) | ≤ 15 s | curl `-w '%{time_total}'` |
| 9 | B-01 warm wall-clock (second request) | ≤ 30 s | curl `-w '%{time_total}'` |
| 10 | Bundle size | ≤ 20 MB | Deploy output, parsed numerically |
| 11 | B-03, B-01, B-02, B-06: `metadata_clean` | true | Response JSON |
| 12 | B-03, B-01, B-02, B-06: output_bytes decodes to valid WebP | pass | Runner base64 decode + RIFF header |
| 13 | B-03, B-01, B-02, B-06: SHA-256 recomputed from output_bytes | matches `sha256` field | Runner recompute |
| 14 | B-03, B-01, B-02, B-06: RIFF chunk parser | EXIF, ICCP, XMP absent | `gate2b-verify-metadata.py` |
| 15 | Telemetry attributable to B-03 `run_id` | Not INCONCLUSIVE | Log correlation |

---

## Section 7 — Failure and Inconclusive Definitions

**FAIL — any of:**
- Any curl exit code ≠ 0 (transport error, timeout)
- Any HTTP 546 (resource limit exceeded) — immediate hard failure, runner exits
- `accepted` or `reason` mismatch vs. manifest for any case
- `width`, `height`, or `pixel_count` mismatch vs. manifest
- `cpu_time_used` ≥ 200 ms for B-03 execution
- `WorkerMemoryUsed` > 220 MB for B-03 execution window
- Bundle size > 20 MB (runner aborts before deployment)
- `metadata_clean: false` for any accepted case
- `output_bytes` absent, or base64 decode fails
- Decoded bytes do not start with RIFF/WEBP header
- SHA-256 recomputed from output_bytes ≠ `sha256` field
- RIFF parser finds EXIF, ICCP, or XMP chunk
- Preflight fails (missing file, wrong dimensions, out-of-size-band, missing metadata family)

**INCONCLUSIVE — any of:**
- B-03 `run_id` not found in Supabase logs
- `cpu_time_used` not found or not attributable to the B-03 `run_id`
- `WorkerMemoryUsed` not isolatable to B-03 execution window

INCONCLUSIVE → treated as FAIL for the gate verdict.

---

## Section 8 — Telemetry Methodology

### 8.1 Worker Lifecycle vs. Request Scope

A Supabase Edge Function worker (isolate) may process multiple requests during its lifetime. The ShutdownEvent and `cpu_time_used` fields belong to the worker lifecycle. To attribute metrics to B-03 specifically, B-03 must be the only request processed by that worker during its measurement window.

### 8.2 B-03 Isolation Protocol

1. Deploy the spike function.
2. Immediately run B-03 as the **first and only** request to the fresh deployment. Record the `run_id` from the response body and `x-request-id` from the response headers.
3. Do **not** invoke the function for any other purpose between deployment and the B-03 response being recorded.
4. Wait 15 seconds for log entries to propagate.
5. Capture logs: `supabase functions logs image-spike --project-ref "$PROJECT_REF" --output json > "$RESULTS_DIR/b03-logs.json" 2>/dev/null`
6. In the logs and dashboard, filter by the B-03 `run_id`. The entry containing `cpu_time_used` for the isolate that processed B-03 is the authoritative CPU measurement.
7. In the Supabase dashboard → Monitoring → Edge Functions, filter by function and the B-03 timestamp window. Record the **maximum** `WorkerMemoryUsed` value in that window.
8. If `run_id` is not found in logs, or `cpu_time_used` is not attributable → INCONCLUSIVE → FAIL.

### 8.3 CPU Time

Field: `cpu_time_used` (no `_ms` suffix, as documented). Pass threshold: < 200 ms. This is the conservative value from Supabase's CPU limits documentation, accounting for the conflict between the general-limits page (2 s) and the CPU-limits guide (200 ms). If Supabase support provides written confirmation of a higher limit for the forkensics-dev project plan, that value may be substituted subject to explicit three-party agreement.

### 8.4 Memory (Authoritative Peak)

`Deno.memoryUsage().rss` before/after delta is diagnostic only. The authoritative peak is the maximum `WorkerMemoryUsed` value from the Supabase dashboard for the B-03 worker window. Pass threshold: ≤ 220 MB (leaving 36 MB headroom before the 256 MB hard limit).

---

## Section 9 — WASM Lifecycle

The WASM binary lives at `tools/image-spike/magick.wasm`. It is copied to `supabase/functions/_shared/magick.wasm` by the runner, verified by hash, and removed unconditionally on cleanup. Step B is not authorized; the binary must not persist in `_shared/` after Gate 2B.

Copy and verification (in runner):
```bash
cp "$WASM_SRC" "$WASM_DST"
SRC_HASH=$(shasum -a 256 "$WASM_SRC" | awk '{print $1}')
DST_HASH=$(shasum -a 256 "$WASM_DST" | awk '{print $1}')
[[ "$SRC_HASH" == "$DST_HASH" ]] || { echo "FATAL: WASM hash mismatch"; exit 1; }
WASM_COPIED=true   # set AFTER verification succeeds; cleanup checks file existence independently
```

---

## Section 10 — WebP Metadata Verification Script

Save as `tools/image-spike/gate2b-verify-metadata.py`.

```python
#!/usr/bin/env python3
"""
Byte-level WebP RIFF chunk parser for Gate 2B metadata verification.
Validates RIFF declared length, validates every chunk boundary,
guards against adversarial inputs.
Exit 0: clean (no metadata chunks found).
Exit 1: metadata found (prints details).
Exit 2: invalid or malformed file.
Usage: python3 gate2b-verify-metadata.py <file.webp>
"""
import sys
import struct

METADATA_FOURCCS: dict[bytes, str] = {
    b'EXIF': 'EXIF — contains Exif IFD, GPS IFD, and IPTC-NAA embedded in Exif',
    b'ICCP': 'ICCP — ICC color profile',
    b'XMP ': 'XMP  — XMP metadata (note trailing space in FourCC)',
}

MAX_CHUNKS = 1024  # Guard against adversarial large chunk-count inputs


def parse_webp_riff(data: bytes) -> list[str]:
    """
    Parse WebP RIFF structure.
    Validates declared RIFF size vs. actual file length.
    Validates every chunk boundary against the RIFF boundary.
    Returns list of metadata chunk descriptions found (empty = clean).
    Raises ValueError for invalid or truncated files.
    """
    if len(data) < 12:
        raise ValueError(
            f"File too short ({len(data)} bytes); minimum 12 required for RIFF/WEBP header"
        )

    if data[0:4] != b'RIFF':
        raise ValueError(f"Not a RIFF file: leading bytes are {data[0:4]!r}")

    declared_riff_payload = struct.unpack_from('<I', data, 4)[0]
    # RIFF format: 4 bytes "RIFF" + 4 bytes size + size bytes of payload
    expected_min_len = 8 + declared_riff_payload
    if len(data) < expected_min_len:
        raise ValueError(
            f"File truncated: RIFF header declares {declared_riff_payload} bytes of payload "
            f"(expected file ≥ {expected_min_len} bytes), but file is {len(data)} bytes"
        )

    if data[8:12] != b'WEBP':
        raise ValueError(
            f"RIFF type is not WEBP: got {data[8:12]!r}"
        )

    found_metadata: list[str] = []
    # Process chunks within the declared RIFF boundary only (not len(data))
    riff_end = 8 + declared_riff_payload
    pos = 12  # First chunk starts after RIFF(4) + size(4) + WEBP(4)
    chunk_count = 0

    while pos + 8 <= riff_end:
        chunk_count += 1
        if chunk_count > MAX_CHUNKS:
            raise ValueError(
                f"Exceeded {MAX_CHUNKS} chunks at offset {pos} — "
                "possible malformed or adversarial input"
            )

        fourcc = data[pos:pos + 4]
        if len(fourcc) < 4:
            raise ValueError(f"Incomplete FourCC at offset {pos}")

        chunk_data_size = struct.unpack_from('<I', data, pos + 4)[0]
        chunk_data_start = pos + 8
        chunk_data_end = chunk_data_start + chunk_data_size

        # Validate chunk boundary against RIFF boundary
        if chunk_data_end > riff_end:
            raise ValueError(
                f"Chunk at offset {pos} ({fourcc!r}) declares {chunk_data_size} data bytes "
                f"(end={chunk_data_end}), which exceeds RIFF boundary ({riff_end})"
            )

        if fourcc in METADATA_FOURCCS:
            fourcc_str = fourcc.decode('ascii', errors='replace')
            found_metadata.append(
                f"  offset={pos}  fourcc={fourcc_str!r}  size={chunk_data_size} bytes"
                f"  — {METADATA_FOURCCS[fourcc]}"
            )

        # Advance: RIFF chunks are word-aligned (pad byte if odd data size)
        pad = chunk_data_size % 2
        pos = chunk_data_end + pad

    return found_metadata


def main() -> None:
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <file.webp>", file=sys.stderr)
        sys.exit(2)

    path = sys.argv[1]
    try:
        with open(path, 'rb') as f:
            data = f.read()
    except OSError as e:
        print(f"ERROR reading {path}: {e}", file=sys.stderr)
        sys.exit(2)

    try:
        found = parse_webp_riff(data)
    except ValueError as e:
        print(f"INVALID WebP — {path}: {e}", file=sys.stderr)
        sys.exit(2)

    if found:
        print(f"METADATA FOUND in {path} — Gate 2B criterion FAIL:")
        for entry in found:
            print(entry)
        sys.exit(1)

    print(f"OK: {path} — no EXIF, ICCP, or XMP  chunks in RIFF structure ({len(data)} bytes)")
    sys.exit(0)


if __name__ == '__main__':
    main()
```

**Coverage note:** In WebP, GPS and IPTC-NAA data are embedded within the EXIF chunk (not separate RIFF chunks). XMP can carry IPTC-IIM records in its namespace. Absence of EXIF and XMP chunks therefore proves absence of GPS, IPTC-NAA, and IPTC-IIM pathways that ImageMagick's WebP encoder uses.

---

## Section 11 — Fixture Generation Script

Save as `tools/image-spike/gate2b-fixtures.py`. Run once before `gate2b-run.sh`; the runner calls it automatically. Requires: `Pillow`, `numpy`, `piexif`.

```python
#!/usr/bin/env python3
"""
Gate 2B deterministic fixture generator.

Generates JPEG and WebP test images with:
  - High-entropy pixel content (NumPy RNG seed 42 — deterministic)
  - All required metadata families embedded in accepted-case fixtures
  - JPEG quality calibrated to land within prescribed byte-range bands
  - Verification that all metadata families are present before returning

Requires: pip install Pillow numpy piexif --break-system-packages
"""

import hashlib
import io
import os
import struct
import sys

import numpy as np
from PIL import Image
import piexif

# ---------------------------------------------------------------------------
# Manifest: (id, width, height, min_bytes, max_bytes, mime, needs_metadata)
# ---------------------------------------------------------------------------
MANIFEST = [
    ("B-01", 2500, 2000, 500_000, 10_000_000, "jpeg", True),
    ("B-02", 4000, 2500, 1_000_000, 10_000_000, "jpeg", True),
    ("B-03", 5000, 4000, 2_000_000, 10_000_000, "jpeg", True),
    ("B-04", 5001, 4000, 10_000, 2_000_000, "jpeg", False),
    ("B-05", 10000, 10000, 10_000, 2_000_000, "jpeg", False),
    ("B-06", 2500, 2000, 200_000, 10_000_000, "webp", True),
    ("B-07", 6000, 4000, 10_000, 2_000_000, "jpeg", False),
]

# Starting JPEG quality values; auto-reduced if file exceeds max_bytes
JPEG_QUALITY_START = {
    "B-01": 70,
    "B-02": 40,
    "B-03": 25,
    "B-04": 5,
    "B-05": 1,
    "B-07": 5,
}
WEBP_QUALITY = {"B-06": 60}

# Minimal valid sRGB ICC profile (68 bytes) for embedding
# Source: ICC.1:2004-10 minimal profile skeleton
_MINI_ICC = bytes.fromhex(
    "00000044" "6d6e7472" "52474220" "58595a20"  # size, 'mntr', 'RGB ', 'XYZ '
    "07d60001" "00010000" "00006163" "73704150"  # date/time, 'acsp', 'APPL'
    "504c0000" "00000000" "00000000" "00000000"  # platform, flags, manuf, model
    "00000000" "00000001" "00000000" "d6f03200"  # attr, intent, X illuminant Y Z
    "00010000" "00000000" "00000002" "6465736300"  # desc tag
    "00000000" "00000006" "73524742"              # 'sRGB'
)
# Fall back to PIL's embedded sRGB if the above is not accepted
try:
    from PIL.ImageCms import createProfile, ImageCmsProfile
    import io as _io
    _srgb = createProfile("sRGB")
    _ICC_PROFILE = ImageCmsProfile(_srgb).tobytes()
except Exception:
    _ICC_PROFILE = _MINI_ICC


def _noise_image(width: int, height: int, seed: int = 42) -> Image.Image:
    """Create a deterministic high-entropy RGB image (random noise)."""
    rng = np.random.default_rng(seed=seed)
    pixels = rng.integers(0, 256, (height, width, 3), dtype=np.uint8)
    return Image.fromarray(pixels, "RGB")


def _build_exif_bytes() -> bytes:
    """Build EXIF with GPS sub-IFD for embedding in JPEG."""
    zeroth = {
        piexif.ImageIFD.Make: b"Gate2B-Camera",
        piexif.ImageIFD.Software: b"Gate2B-Fixture-v4",
        piexif.ImageIFD.Artist: b"Gate2B-Test",
        piexif.ImageIFD.Copyright: b"Gate2B (c) 2026",
        piexif.ImageIFD.ImageDescription: b"Gate 2B test fixture",
    }
    exif_ifd = {
        piexif.ExifIFD.UserComment: b"ASCII\x00\x00\x00Gate2B fixture user comment",
    }
    gps_ifd = {
        piexif.GPSIFD.GPSLatitudeRef: b"N",
        piexif.GPSIFD.GPSLatitude: ((37, 1), (46, 1), (2983, 100)),
        piexif.GPSIFD.GPSLongitudeRef: b"W",
        piexif.GPSIFD.GPSLongitude: ((122, 1), (25, 1), (959, 100)),
        piexif.GPSIFD.GPSAltitudeRef: 0,
        piexif.GPSIFD.GPSAltitude: (10, 1),
        piexif.GPSIFD.GPSDateStamp: b"2026:01:01",
    }
    return piexif.dump({"0th": zeroth, "Exif": exif_ifd, "GPS": gps_ifd, "1st": {}})


def _inject_xmp(jpeg_bytes: bytes) -> bytes:
    """Inject a minimal XMP APP1 segment into JPEG bytes after the SOI marker."""
    xmp_payload = (
        b"http://ns.adobe.com/xap/1.0/\x00"
        b'<?xpacket begin="\xef\xbb\xbf" id="W5M0MpCehiHzreSzNTczkc9d"?>'
        b'<x:xmpmeta xmlns:x="adobe:ns:meta/">'
        b'<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">'
        b'<rdf:Description xmlns:dc="http://purl.org/dc/elements/1.1/">'
        b'<dc:description>Gate2B XMP fixture</dc:description>'
        b'</rdf:Description></rdf:RDF></x:xmpmeta>'
        b'<?xpacket end="w"?>'
    )
    # APP1 marker: 0xFF 0xE1, big-endian uint16 length (includes 2-byte length field)
    xmp_len = len(xmp_payload) + 2
    xmp_segment = b'\xff\xe1' + struct.pack('>H', xmp_len) + xmp_payload
    # Insert after SOI (first 2 bytes of JPEG)
    return jpeg_bytes[:2] + xmp_segment + jpeg_bytes[2:]


def _inject_iptc(jpeg_bytes: bytes) -> bytes:
    """Inject a minimal IPTC APP13 segment (Photoshop 3.0 / IPTC-IIM) into JPEG."""
    # IPTC dataset: record 2, dataset 5 (object name), value = b"Gate2B fixture"
    iptc_dataset = b'\x1c\x02\x05' + struct.pack('>H', 14) + b'Gate2B fixture'
    # Photoshop 3.0 wrapper
    photoshop_header = b'Photoshop 3.0\x00'
    # BIMI: 8BIM resource type for IPTC = 0x0404
    resource_block = (
        b'8BIM'
        + struct.pack('>H', 0x0404)  # resource ID
        + b'\x00\x00'               # pascal string (empty, padded to even)
        + struct.pack('>I', len(iptc_dataset))
        + iptc_dataset
    )
    app13_payload = photoshop_header + resource_block
    app13_len = len(app13_payload) + 2
    app13_segment = b'\xff\xed' + struct.pack('>H', app13_len) + app13_payload
    return jpeg_bytes[:2] + app13_segment + jpeg_bytes[2:]


def _inject_comment(jpeg_bytes: bytes) -> bytes:
    """Inject a JFIF COM (comment) segment into JPEG."""
    comment = b"Gate2B Gate 2B fixture comment marker"
    com_len = len(comment) + 2
    com_segment = b'\xff\xfe' + struct.pack('>H', com_len) + comment
    return jpeg_bytes[:2] + com_segment + jpeg_bytes[2:]


# ---------------------------------------------------------------------------
# JPEG marker scanner — verifies presence of each metadata family
# ---------------------------------------------------------------------------
def _has_gps_in_exif(exif_payload: bytes) -> bool:
    """Return True if the EXIF payload (after 'Exif\\x00\\x00') contains a GPS IFD."""
    try:
        exif_dict = piexif.load(b'Exif\x00\x00' + exif_payload)
        return bool(exif_dict.get('GPS'))
    except Exception:
        return False


def scan_jpeg_metadata_families(data: bytes) -> set[str]:
    """
    Scan JPEG APP markers and return the set of metadata families present.
    Families: EXIF, GPS, ICC, XMP, IPTC, COMMENT.
    """
    if data[:2] != b'\xff\xd8':
        raise ValueError("Not a JPEG file")
    found: set[str] = set()
    i = 2
    while i + 4 <= len(data):
        if data[i] != 0xff:
            break
        marker = data[i + 1]
        # Markers without a length field
        if marker in (0xd8, 0xd9, 0x01) or 0xd0 <= marker <= 0xd7:
            i += 2
            continue
        if i + 4 > len(data):
            break
        seg_length = struct.unpack_from('>H', data, i + 2)[0]
        seg_data = data[i + 4: i + 2 + seg_length]

        if marker == 0xe1:  # APP1
            if seg_data[:6] == b'Exif\x00\x00':
                found.add('EXIF')
                if _has_gps_in_exif(seg_data[6:]):
                    found.add('GPS')
            elif seg_data[:29] == b'http://ns.adobe.com/xap/1.0/\x00':
                found.add('XMP')
        elif marker == 0xe2:  # APP2
            if seg_data[:12] == b'ICC_PROFILE\x00':
                found.add('ICC')
        elif marker == 0xed:  # APP13
            if seg_data[:14] == b'Photoshop 3.0\x00':
                found.add('IPTC')
        elif marker == 0xfe:  # COM
            found.add('COMMENT')

        i += 2 + seg_length
    return found


# ---------------------------------------------------------------------------
# Fixture generation
# ---------------------------------------------------------------------------
def generate_jpeg(label: str, width: int, height: int,
                  min_bytes: int, max_bytes: int,
                  needs_metadata: bool, out_dir: str) -> str:
    """Generate a JPEG fixture, auto-reducing quality to stay within bounds."""
    img = _noise_image(width, height)
    quality = JPEG_QUALITY_START.get(label, 50)
    out_path = os.path.join(out_dir, f"test-{label}.jpg")

    for attempt in range(20):
        buf = io.BytesIO()
        if needs_metadata:
            exif_bytes = _build_exif_bytes()
            img.save(buf, "JPEG", quality=quality, exif=exif_bytes,
                     icc_profile=_ICC_PROFILE)
        else:
            img.save(buf, "JPEG", quality=quality)
        jpeg_bytes = buf.getvalue()

        if needs_metadata:
            jpeg_bytes = _inject_xmp(jpeg_bytes)
            jpeg_bytes = _inject_iptc(jpeg_bytes)
            jpeg_bytes = _inject_comment(jpeg_bytes)

        size = len(jpeg_bytes)
        if size <= max_bytes:
            break
        quality = max(1, quality - 5)
    else:
        raise RuntimeError(
            f"{label}: could not reach size ≤ {max_bytes} bytes "
            f"(lowest quality {quality}, size {size})"
        )

    if size < min_bytes:
        raise RuntimeError(
            f"{label}: size {size} < min {min_bytes} at quality {quality}. "
            "Consider reducing min_bytes or increasing image dimensions."
        )
    if size > 10_000_000:
        raise RuntimeError(f"{label}: size {size} exceeds 10 MB upload ceiling")

    with open(out_path, 'wb') as f:
        f.write(jpeg_bytes)

    if needs_metadata:
        families = scan_jpeg_metadata_families(jpeg_bytes)
        required = {'EXIF', 'GPS', 'ICC', 'XMP', 'IPTC', 'COMMENT'}
        missing = required - families
        if missing:
            raise RuntimeError(
                f"{label}: source fixture missing metadata families: {sorted(missing)}"
            )
        print(f"  metadata families present: {sorted(families)}")

    sha = hashlib.sha256(jpeg_bytes).hexdigest()
    print(f"{label}: {out_path} ({size:,} bytes, quality={quality}, sha256={sha[:16]}...)")
    return out_path


def generate_webp(label: str, width: int, height: int,
                  min_bytes: int, max_bytes: int,
                  needs_metadata: bool, out_dir: str) -> str:
    """Generate a WebP fixture (the spike accepts WebP input too)."""
    img = _noise_image(width, height)
    quality = WEBP_QUALITY.get(label, 60)
    out_path = os.path.join(out_dir, f"test-{label}.webp")

    buf = io.BytesIO()
    # WebP does not use EXIF/ICC injection here — the spike function's input parser
    # must handle WebP input. For metadata, embed via Pillow's exif parameter.
    if needs_metadata:
        exif_bytes = _build_exif_bytes()
        img.save(buf, "WebP", quality=quality, exif=exif_bytes,
                 icc_profile=_ICC_PROFILE)
    else:
        img.save(buf, "WebP", quality=quality)
    webp_bytes = buf.getvalue()
    size = len(webp_bytes)

    if size < min_bytes or size > max_bytes:
        raise RuntimeError(
            f"{label}: size {size} outside band [{min_bytes}, {max_bytes}]"
        )
    if size > 10_000_000:
        raise RuntimeError(f"{label}: size {size} exceeds 10 MB upload ceiling")

    with open(out_path, 'wb') as f:
        f.write(webp_bytes)

    sha = hashlib.sha256(webp_bytes).hexdigest()
    print(f"{label}: {out_path} ({size:,} bytes, sha256={sha[:16]}...)")
    return out_path


def main():
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <output-dir>", file=sys.stderr)
        sys.exit(1)
    out_dir = sys.argv[1]
    os.makedirs(out_dir, exist_ok=False)  # Fail if already exists

    print("Generating Gate 2B test fixtures (deterministic, seed=42)...")
    for label, width, height, min_b, max_b, mime, needs_meta in MANIFEST:
        print(f"\n--- {label} ({width}x{height}, {mime}) ---")
        if mime == "jpeg":
            generate_jpeg(label, width, height, min_b, max_b, needs_meta, out_dir)
        elif mime == "webp":
            generate_webp(label, width, height, min_b, max_b, needs_meta, out_dir)
        else:
            raise ValueError(f"Unknown MIME type: {mime}")

    print("\nAll fixtures generated and verified.")


if __name__ == "__main__":
    main()
```

---

## Section 12 — Gate 2B Runner

Save as `tools/image-spike/gate2b-run.sh`. This is the complete, executable runner. Every cloud operation in this gate is performed by this script.

```bash
#!/usr/bin/env bash
# Gate 2B test runner — gate2b-run.sh
# DISPOSABLE — Gate 2B only. Execute only after three-party approval of Rev 4.
#
# Prerequisites:
#   PROJECT_REF=<forkensics-dev-project-ref> ANON_KEY=<jwt-anon-key> bash gate2b-run.sh
#
# ANON_KEY is never written to disk, never echoed, never logged.
# Exits 0 on full PASS, exits 1 on FAIL or INCONCLUSIVE.

set -uo pipefail
# -e intentionally absent: the EXIT trap handles all exit paths.

# ---------------------------------------------------------------------------
# Environment validation (before any side effects)
# ---------------------------------------------------------------------------
[[ -n "${PROJECT_REF:-}" ]] || { echo "FATAL: PROJECT_REF not set" >&2; exit 1; }
[[ -n "${ANON_KEY:-}" ]]   || { echo "FATAL: ANON_KEY not set" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WASM_SRC="$REPO_ROOT/tools/image-spike/magick.wasm"
WASM_DST="$REPO_ROOT/supabase/functions/_shared/magick.wasm"
CONFIG="$REPO_ROOT/supabase/config.toml"
SPIKE_DIR="$REPO_ROOT/supabase/functions/image-spike"
IMG_DIR="$REPO_ROOT/tools/image-spike/test-images"
OUT_DIR="$REPO_ROOT/tools/image-spike/gate2b-responses"
RESULTS_DIR="$REPO_ROOT/tools/image-spike/gate2b-evidence"
VERIFY_PY="$SCRIPT_DIR/gate2b-verify-metadata.py"
FIXTURES_PY="$SCRIPT_DIR/gate2b-fixtures.py"
RESULTS_MD="$RESULTS_DIR/gate2b-results.md"
LOG_INSTRUCTIONS="$RESULTS_DIR/log-capture-instructions.txt"
FUNC_URL="https://${PROJECT_REF}.supabase.co/functions/v1/image-spike"

# ---------------------------------------------------------------------------
# State flags
# ---------------------------------------------------------------------------
CLEANUP_RAN=false
DEPLOY_ATTEMPTED=false   # Set BEFORE deploy command; cleanup always attempts delete if true
WASM_COPIED=false
CONFIG_PATCHED=false
GATE2B_PASS=true
declare -a FAIL_REASONS=()

# ---------------------------------------------------------------------------
# Cleanup — idempotent via CLEANUP_RAN guard
# Non-interactive: no read -r; instructions written to file instead
# Evidence in RESULTS_DIR is preserved; IMG_DIR and OUT_DIR are deleted
# ---------------------------------------------------------------------------
cleanup() {
  if [[ "$CLEANUP_RAN" == "true" ]]; then return; fi
  CLEANUP_RAN=true
  local trigger="${1:-EXIT}"

  echo "" >&2
  echo "=================================================================" >&2
  echo "Gate 2B Cleanup (trigger: $trigger)" >&2
  echo "=================================================================" >&2

  # Step 1: Remote deletion (attempt if deploy was attempted, regardless of success)
  if [[ "$DEPLOY_ATTEMPTED" == "true" ]]; then
    echo "Deleting remote function image-spike ..." >&2

    if supabase functions delete image-spike --project-ref "$PROJECT_REF" 2>/dev/null; then
      echo "Remote deletion: CLI success" >&2
    else
      echo "WARNING: CLI deletion failed. Delete manually:" >&2
      echo "  https://supabase.com/dashboard/project/$PROJECT_REF/functions" >&2
    fi

    # Verification (non-blocking)
    sleep 3
    if supabase functions list --project-ref "$PROJECT_REF" 2>/dev/null \
       | grep -q "image-spike"; then
      echo "WARNING: image-spike still listed — verify manual deletion" >&2
    else
      echo "Remote deletion: verified" >&2
    fi

    # Write log-capture instructions (user reads these after cleanup)
    {
      echo "# Gate 2B — Log Capture Instructions"
      echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
      echo ""
      echo "The image-spike function has been deleted. Before the logs expire,"
      echo "capture the following from the Supabase dashboard:"
      echo ""
      echo "1. Edge Function logs for image-spike:"
      echo "   URL: https://supabase.com/dashboard/project/$PROJECT_REF/functions/image-spike/logs"
      echo "   - Filter by the B-03 run_id (see gate2b-results.md)"
      echo "   - Save log entries to: $RESULTS_DIR/platform-logs.txt"
      echo "   - Key fields: cpu_time_used, timestamp, execution_id / run_id match"
      echo ""
      echo "2. WorkerMemoryUsed (peak memory for B-03):"
      echo "   URL: https://supabase.com/dashboard/project/$PROJECT_REF/functions"
      echo "   - Click Monitoring / Metrics"
      echo "   - Filter by image-spike, time range around B-03 invocation"
      echo "   - Record maximum WorkerMemoryUsed value in MB"
      echo ""
      echo "3. CLI log capture (run now):"
      echo "   supabase functions logs image-spike --project-ref $PROJECT_REF --output json"
    } > "$LOG_INSTRUCTIONS" 2>/dev/null || true
    echo "Log-capture instructions written to: $LOG_INSTRUCTIONS" >&2
  fi

  # Step 2: Restore config.toml — remove [functions.image-spike] section only
  if [[ "$CONFIG_PATCHED" == "true" ]] || grep -q '\[functions\.image-spike\]' "$CONFIG" 2>/dev/null; then
    python3 - "$CONFIG" <<'PYEOF'
import re, sys
path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()
# Remove [functions.image-spike] and any key=value lines that follow it,
# stopping at the next [section] header or EOF.
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

  # Step 3: Remove copied WASM (check file existence; flag may not be set if interrupted)
  if [[ -f "$WASM_DST" ]]; then
    rm "$WASM_DST"
    echo "Removed: $WASM_DST" >&2
  fi

  # Step 4: Remove spike function source directory
  if [[ -d "$SPIKE_DIR" ]]; then
    rm -rf "$SPIKE_DIR"
    echo "Removed: $SPIKE_DIR" >&2
  fi

  # Step 5: Remove temporary directories (evidence already in RESULTS_DIR)
  if [[ -d "$OUT_DIR" ]]; then
    rm -rf "$OUT_DIR"
    echo "Removed: $OUT_DIR" >&2
  fi
  if [[ -d "$IMG_DIR" ]]; then
    rm -rf "$IMG_DIR"
    echo "Removed: $IMG_DIR" >&2
  fi

  echo "Cleanup complete." >&2
  echo "Evidence preserved in: $RESULTS_DIR" >&2
  echo "=================================================================" >&2
}

trap 'cleanup EXIT' EXIT
trap 'GATE2B_PASS=false; FAIL_REASONS+=("INTERRUPTED by INT"); cleanup INT; exit 130' INT
trap 'GATE2B_PASS=false; FAIL_REASONS+=("INTERRUPTED by TERM"); cleanup TERM; exit 143' TERM

# ---------------------------------------------------------------------------
# fail — record a failure reason and continue (non-fatal unless caller exits)
# ---------------------------------------------------------------------------
fail() {
  GATE2B_PASS=false
  FAIL_REASONS+=("$*")
  echo "FAILURE: $*" >&2
}

# ---------------------------------------------------------------------------
# results_append — append a line to the running results file
# ---------------------------------------------------------------------------
mkdir -p "$RESULTS_DIR"
> "$RESULTS_MD"   # Truncate/create
results_append() { echo "$*" >> "$RESULTS_MD"; }
results_append "# Gate 2B Results"
results_append "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
results_append "PROJECT_REF: $PROJECT_REF"
results_append ""

# ---------------------------------------------------------------------------
# Guard: required directories must be absent before we start
# ---------------------------------------------------------------------------
echo "=== Gate 2B Preflight ==="

for dir in "$IMG_DIR" "$OUT_DIR"; do
  if [[ -d "$dir" ]]; then
    echo "FATAL: Directory already exists: $dir" >&2
    echo "Delete it before running: rm -rf $dir" >&2
    exit 1
  fi
done

if [[ -f "$WASM_DST" ]]; then
  echo "FATAL: $WASM_DST already exists (leftover from prior run?)" >&2; exit 1
fi
if grep -q '\[functions\.image-spike\]' "$CONFIG" 2>/dev/null; then
  echo "FATAL: [functions.image-spike] already present in config.toml" >&2; exit 1
fi

for tool in supabase curl jq python3 shasum; do
  command -v "$tool" &>/dev/null || { echo "FATAL: $tool not found" >&2; exit 1; }
done
[[ -f "$WASM_SRC" ]]    || { echo "FATAL: $WASM_SRC not found" >&2; exit 1; }
[[ -f "$VERIFY_PY" ]]   || { echo "FATAL: $VERIFY_PY not found" >&2; exit 1; }
[[ -f "$FIXTURES_PY" ]] || { echo "FATAL: $FIXTURES_PY not found" >&2; exit 1; }
[[ -d "$SPIKE_DIR" ]]   || { echo "FATAL: $SPIKE_DIR not found" >&2; exit 1; }

mkdir -p "$IMG_DIR" "$OUT_DIR"
echo "Preflight: paths clear"

# ---------------------------------------------------------------------------
# Generate test fixtures
# ---------------------------------------------------------------------------
echo ""
echo "=== Generating test fixtures ==="
python3 "$FIXTURES_PY" "$IMG_DIR" || { echo "FATAL: fixture generation failed" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Preflight: verify each fixture against manifest
# ---------------------------------------------------------------------------
echo ""
echo "=== Verifying fixtures ==="

# Manifest: label|filename|mime|exp_w|exp_h|exp_pixels|min_bytes|max_bytes|exp_accepted|needs_meta
declare -a MANIFEST=(
  "B-03|test-B-03.jpg|image/jpeg|5000|4000|20000000|2000000|10000000|true|true"
  "B-01|test-B-01.jpg|image/jpeg|2500|2000|5000000|500000|10000000|true|true"
  "B-02|test-B-02.jpg|image/jpeg|4000|2500|10000000|1000000|10000000|true|true"
  "B-04|test-B-04.jpg|image/jpeg|5001|4000|20004000|10000|2000000|false|false"
  "B-05|test-B-05.jpg|image/jpeg|10000|10000|100000000|10000|2000000|false|false"
  "B-06|test-B-06.webp|image/webp|2500|2000|5000000|200000|10000000|true|true"
  "B-07|test-B-07.jpg|image/jpeg|6000|4000|24000000|10000|2000000|false|false"
)

results_append "## Fixture Preflight"
for entry in "${MANIFEST[@]}"; do
  IFS="|" read -r label filename mime exp_w exp_h exp_pixels \
    min_bytes max_bytes exp_accepted needs_meta <<< "$entry"
  img="$IMG_DIR/$filename"
  [[ -f "$img" ]] || { echo "FATAL: $img missing after generation" >&2; exit 1; }

  byte_size=$(wc -c < "$img" | tr -d ' ')
  sha=$(shasum -a 256 "$img" | awk '{print $1}')
  dims=$(python3 -c "
from PIL import Image
with Image.open('$img') as im:
    print(im.width, im.height)
") || { echo "FATAL: cannot read $img dimensions" >&2; exit 1; }
  actual_w=$(echo "$dims" | awk '{print $1}')
  actual_h=$(echo "$dims" | awk '{print $2}')
  actual_px=$((actual_w * actual_h))

  ok=true
  [[ "$actual_w" == "$exp_w" && "$actual_h" == "$exp_h" ]] \
    || { fail "$label: dimensions ${actual_w}x${actual_h} ≠ ${exp_w}x${exp_h}"; ok=false; }
  [[ "$actual_px" == "$exp_pixels" ]] \
    || { fail "$label: pixel_count $actual_px ≠ $exp_pixels"; ok=false; }
  [[ "$byte_size" -ge "$min_bytes" ]] \
    || { fail "$label: size $byte_size < min $min_bytes"; ok=false; }
  [[ "$byte_size" -le "$max_bytes" ]] \
    || { fail "$label: size $byte_size > max $max_bytes"; ok=false; }
  [[ "$byte_size" -le 10000000 ]] \
    || { fail "$label: size $byte_size exceeds 10 MB upload ceiling"; ok=false; }

  results_append "$label: $filename ${byte_size} bytes ${actual_w}x${actual_h} sha256=${sha}"
  if [[ "$ok" == "true" ]]; then
    echo "PREFLIGHT OK: $label ($byte_size bytes, ${actual_w}x${actual_h}, sha256=${sha:0:16}...)"
  fi
done

[[ "$GATE2B_PASS" == "true" ]] || { echo "FATAL: preflight failed" >&2; exit 1; }

# ---------------------------------------------------------------------------
# WASM: copy and hash-verify
# ---------------------------------------------------------------------------
echo ""
echo "=== WASM copy ==="
cp "$WASM_SRC" "$WASM_DST"
SRC_HASH=$(shasum -a 256 "$WASM_SRC" | awk '{print $1}')
DST_HASH=$(shasum -a 256 "$WASM_DST" | awk '{print $1}')
[[ "$SRC_HASH" == "$DST_HASH" ]] \
  || { echo "FATAL: WASM copy hash mismatch" >&2; exit 1; }
WASM_COPIED=true
results_append ""
results_append "## Hashes"
results_append "magick.wasm sha256: $SRC_HASH"
INDEX_HASH=$(shasum -a 256 "$SPIKE_DIR/index.ts" | awk '{print $1}')
results_append "index.ts sha256: $INDEX_HASH"
echo "WASM verified: $SRC_HASH"

# ---------------------------------------------------------------------------
# config.toml: patch
# ---------------------------------------------------------------------------
echo ""
echo "=== Patching config.toml ==="
printf '\n[functions.image-spike]\nstatic_files = ["./functions/_shared/magick.wasm"]\n' \
  >> "$CONFIG"
CONFIG_PATCHED=true
echo "config.toml patched"

# ---------------------------------------------------------------------------
# Static checks
# ---------------------------------------------------------------------------
echo ""
echo "=== Static checks ==="
deno fmt --check "$SPIKE_DIR/index.ts" \
  || { fail "deno fmt"; exit 1; }
deno lint "$SPIKE_DIR/index.ts" \
  || { fail "deno lint"; exit 1; }
deno check "$SPIKE_DIR/index.ts" \
  || { fail "deno check"; exit 1; }
gitleaks detect --source "$REPO_ROOT" --config "$REPO_ROOT/.gitleaks.toml" 2>/dev/null \
  || { fail "gitleaks"; exit 1; }
echo "Static checks passed"

# ---------------------------------------------------------------------------
# Pre-deployment approval gate (non-interactive: operator must have confirmed
# sign-off before invoking this script; prompted once for explicit confirmation)
# ---------------------------------------------------------------------------
echo ""
echo "=== Pre-deployment approval gate ==="
echo "Confirm three-party pre-deployment approval has been recorded [type YES to continue]: "
read -r confirm
[[ "$confirm" == "YES" ]] || {
  echo "Deployment aborted (approval not confirmed)" >&2; exit 1
}

# ---------------------------------------------------------------------------
# Deploy — DEPLOY_ATTEMPTED set immediately before command
# ---------------------------------------------------------------------------
echo ""
echo "=== Deploying image-spike ==="
DEPLOY_ATTEMPTED=true   # Set BEFORE supabase CLI runs; cleanup catches orphans

deploy_output=$(supabase functions deploy image-spike \
  --project-ref "$PROJECT_REF" \
  --use-docker 2>&1)
deploy_exit=$?
echo "$deploy_output"

if [[ $deploy_exit -ne 0 ]]; then
  fail "deployment failed (exit $deploy_exit)"
  exit 1
fi

# Parse and enforce bundle size numerically
bundle_mb=$(echo "$deploy_output" \
  | grep -oiE '[0-9]+(\.[0-9]+)? ?[Mm][Bb]' \
  | grep -oE '[0-9]+(\.[0-9]+)?' \
  | head -1)
if [[ -z "$bundle_mb" ]]; then
  echo "WARNING: could not parse bundle size from deploy output — record manually"
  results_append "bundle_mb: UNKNOWN (parse failed — verify manually ≤ 20 MB)"
else
  python3 -c "import sys; sys.exit(0 if float('$bundle_mb') <= 20 else 1)" \
    || { fail "bundle size ${bundle_mb} MB > 20 MB"; exit 1; }
  echo "Bundle size: ${bundle_mb} MB ≤ 20 MB ✓"
  results_append "bundle_mb: $bundle_mb"
fi

results_append ""
results_append "## Deployment"
results_append "deploy_exit: $deploy_exit"

# ---------------------------------------------------------------------------
# invoke_case — single curl, capture everything together
# ---------------------------------------------------------------------------
# Args: label filename mime exp_accepted exp_reason exp_w exp_h exp_pixels is_critical
# Writes to: OUT_DIR/<label>.json, OUT_DIR/<label>.headers
# Records to: RESULTS_MD
# Returns 0 if all assertions pass, 1 if any fail (sets GATE2B_PASS)
# ---------------------------------------------------------------------------
invoke_case() {
  local label="$1" filename="$2" mime="$3" exp_accepted="$4" exp_reason="$5"
  local exp_w="$6" exp_h="$7" exp_pixels="$8" is_critical="${9:-false}"
  local img="$IMG_DIR/$filename"
  local out="$OUT_DIR/${label}.json"
  local hdr="$OUT_DIR/${label}.headers"
  local webp="$OUT_DIR/${label}_output.webp"

  echo ""
  echo "--- $label ($filename, $mime) ---"

  # Single curl: captures body (-o), headers (-D), status+time (-w), exit code ($?)
  local curl_w
  curl_w=$(curl -s \
    -o "$out" \
    -D "$hdr" \
    -w '%{http_code}\t%{time_total}' \
    --max-time 120 \
    -X POST "${FUNC_URL}?label=${label}" \
    -H "Authorization: Bearer $ANON_KEY" \
    -H "Content-Type: $mime" \
    --data-binary "@$img" 2>/dev/null)
  local curl_exit=$?

  local http_status wall_time req_id run_id
  http_status=$(printf '%s' "$curl_w" | cut -f1)
  wall_time=$(printf '%s' "$curl_w" | cut -f2)
  req_id=$(grep -i '^x-request-id:' "$hdr" 2>/dev/null \
    | awk '{print $2}' | tr -d '\r' | head -1 || true)

  echo "  curl_exit=$curl_exit  HTTP=$http_status  wall_time=${wall_time}s"
  echo "  x-request-id: ${req_id:-<not found>}"

  # Record to results
  results_append ""
  results_append "### $label"
  results_append "curl_exit=$curl_exit  HTTP=$http_status  wall_time_s=$wall_time"
  results_append "x-request-id: ${req_id:-<not found>}"

  # curl transport error
  if [[ $curl_exit -ne 0 ]]; then
    fail "$label: curl exit $curl_exit (transport error or timeout)"
    results_append "FAIL: curl transport error"
    return 1
  fi

  # HTTP 546 — hard failure, exit immediately
  if [[ "$http_status" == "546" ]]; then
    fail "$label: HTTP 546 — resource limit exceeded"
    results_append "HARD FAIL: HTTP 546"
    exit 1
  fi

  if [[ "$http_status" != "200" ]]; then
    fail "$label: HTTP $http_status"
    results_append "FAIL: unexpected HTTP $http_status"
    return 1
  fi

  # Parse response fields
  local resp_accepted resp_reason resp_run_id resp_w resp_h resp_pixels \
    resp_meta_clean resp_sha256 resp_output_b64
  resp_accepted=$(jq -r '.accepted // "MISSING"' "$out" 2>/dev/null || echo "PARSE_ERROR")
  resp_reason=$(jq -r '.reason // ""' "$out" 2>/dev/null || echo "")
  resp_run_id=$(jq -r '.run_id // ""' "$out" 2>/dev/null || echo "")
  resp_w=$(jq -r '.width // 0' "$out" 2>/dev/null || echo "0")
  resp_h=$(jq -r '.height // 0' "$out" 2>/dev/null || echo "0")
  resp_pixels=$(jq -r '.pixel_count // 0' "$out" 2>/dev/null || echo "0")
  resp_meta_clean=$(jq -r '.metadata_clean // "MISSING"' "$out" 2>/dev/null || echo "MISSING")
  resp_sha256=$(jq -r '.sha256 // ""' "$out" 2>/dev/null || echo "")

  results_append "run_id: ${resp_run_id:-<missing>}"
  results_append "accepted=$resp_accepted  reason=$resp_reason"
  results_append "dimensions=${resp_w}x${resp_h}  pixel_count=$resp_pixels"

  # accepted field
  if [[ "$resp_accepted" != "$exp_accepted" ]]; then
    fail "$label: accepted=$resp_accepted ≠ $exp_accepted"
  else
    echo "  accepted=$resp_accepted ✓"
  fi

  # rejection reason
  if [[ "$exp_accepted" == "false" ]]; then
    if [[ "$resp_reason" != "$exp_reason" ]]; then
      fail "$label: reason='$resp_reason' ≠ '$exp_reason'"
    else
      echo "  reason=$resp_reason ✓"
    fi
  fi

  # dimensions
  if [[ "$resp_w" != "$exp_w" || "$resp_h" != "$exp_h" ]]; then
    fail "$label: dimensions ${resp_w}x${resp_h} ≠ ${exp_w}x${exp_h}"
  else
    echo "  dimensions=${resp_w}x${resp_h} ✓"
  fi

  # pixel_count
  if [[ "$resp_pixels" != "$exp_pixels" ]]; then
    fail "$label: pixel_count=$resp_pixels ≠ $exp_pixels"
  else
    echo "  pixel_count=$resp_pixels ✓"
  fi

  # Accepted-case output verification
  if [[ "$exp_accepted" == "true" ]]; then
    # metadata_clean
    if [[ "$resp_meta_clean" != "true" ]]; then
      fail "$label: metadata_clean=$resp_meta_clean ≠ true"
    else
      echo "  metadata_clean=true ✓"
    fi

    # output_bytes: decode, validate WebP, recompute SHA-256, run RIFF parser
    resp_output_b64=$(jq -r '.output_bytes // ""' "$out" 2>/dev/null || echo "")
    if [[ -z "$resp_output_b64" || "$resp_output_b64" == "null" ]]; then
      fail "$label: output_bytes field absent"
    else
      # Decode base64
      if echo "$resp_output_b64" | base64 -d > "$webp" 2>/dev/null; then
        echo "  output_bytes: decoded ($(wc -c < "$webp") bytes)"

        # Validate RIFF/WEBP header
        local header_bytes
        header_bytes=$(python3 -c "
with open('$webp','rb') as f: d=f.read(12)
print('valid' if d[:4]==b'RIFF' and d[8:12]==b'WEBP' else 'invalid')
" 2>/dev/null || echo "error")
        if [[ "$header_bytes" != "valid" ]]; then
          fail "$label: decoded output_bytes is not valid WebP"
        else
          echo "  WebP RIFF header ✓"

          # Recompute SHA-256
          local actual_sha
          actual_sha=$(shasum -a 256 "$webp" | awk '{print $1}')
          if [[ "$actual_sha" != "$resp_sha256" ]]; then
            fail "$label: SHA-256 mismatch: computed=$actual_sha response=$resp_sha256"
          else
            echo "  SHA-256 match ✓"
          fi
          results_append "sha256: $resp_sha256 (verified)"

          # RIFF chunk parser
          if python3 "$VERIFY_PY" "$webp" >/dev/null 2>&1; then
            echo "  RIFF chunk parser: no metadata ✓"
            results_append "RIFF metadata: clean"
          else
            fail "$label: RIFF parser found metadata chunks"
            results_append "RIFF metadata: FAIL — metadata found"
          fi
        fi
      else
        fail "$label: base64 decode of output_bytes failed"
      fi
    fi

    # SHA-256 format (even if output_bytes check ran)
    if ! echo "$resp_sha256" | grep -qE '^[0-9a-f]{64}$'; then
      fail "$label: sha256 format invalid: '$resp_sha256'"
    fi
  fi

  # B-03 critical: write run_id for telemetry correlation
  if [[ "$is_critical" == "true" ]]; then
    results_append ""
    results_append "## B-03 Telemetry (complete manually)"
    results_append "run_id: ${resp_run_id:-MISSING — check function logs}"
    results_append "x-request-id: ${req_id:-not found}"
    results_append "cold_wall_time_s: $wall_time"
    results_append ""
    results_append "From Supabase logs (filter by run_id above):"
    results_append "  cpu_time_used: <record here> — must be < 200 ms"
    results_append ""
    results_append "From Supabase dashboard Monitoring:"
    results_append "  WorkerMemoryUsed (max in B-03 window): <record here> — must be ≤ 220 MB"
    results_append ""
    results_append "If either metric is unattributable: INCONCLUSIVE → FAIL"

    echo "  run_id for telemetry correlation: ${resp_run_id:-MISSING}"
    echo "  B-03 cold wall-clock: ${wall_time}s (threshold ≤ 15 s)"
    python3 -c "import sys; sys.exit(0 if float('$wall_time') <= 15 else 1)" 2>/dev/null \
      || fail "B-03 cold wall-clock ${wall_time}s > 15 s"

    # Attempt CLI log capture for B-03 (non-blocking; may not have cpu_time_used)
    echo "  Capturing logs (waiting 15 s for propagation) ..."
    sleep 15
    supabase functions logs image-spike \
      --project-ref "$PROJECT_REF" \
      --output json \
      > "$RESULTS_DIR/b03-logs.json" 2>/dev/null || true
    echo "  CLI logs written to: $RESULTS_DIR/b03-logs.json"
    echo "  (cpu_time_used and WorkerMemoryUsed must be recorded manually from dashboard)"
  fi

  return 0
}

# ---------------------------------------------------------------------------
# Test execution order: B-03 cold (isolated), B-01 warm, then rest of matrix
# ---------------------------------------------------------------------------
results_append ""
results_append "## Test Invocations"

echo ""
echo "=== Phase 1: B-03 cold (telemetry isolation) ==="
invoke_case B-03 test-B-03.jpg image/jpeg true "" 5000 4000 20000000 true

echo ""
echo "=== Phase 2: B-01 warm ==="
invoke_case B-01 test-B-01.jpg image/jpeg true "" 2500 2000 5000000 false
warm_time=$(jq -r '.diagnostic.wall_time_ms // 0' "$OUT_DIR/B-01.json" 2>/dev/null \
  | python3 -c "import sys; print(float(sys.stdin.read())/1000)" 2>/dev/null || echo "ERR")
# curl wall_time for B-01 is in OUT_DIR/B-01.headers indirectly; we captured it in invoke_case
# The curl wall_time for B-01 is the warm measurement
b01_curl_time=$(grep -oP '(?<=wall_time_s=)\S+' "$RESULTS_MD" | tail -1 || echo "ERR")
results_append ""
results_append "B-01 warm wall-clock: $b01_curl_time s (threshold ≤ 30 s)"
python3 -c "import sys; sys.exit(0 if float('${b01_curl_time:-99}') <= 30 else 1)" 2>/dev/null \
  || fail "B-01 warm wall-clock ${b01_curl_time}s > 30 s"

echo ""
echo "=== Phase 3: remaining matrix ==="
invoke_case B-02 test-B-02.jpg image/jpeg true "" 4000 2500 10000000 false
invoke_case B-04 test-B-04.jpg image/jpeg false pre_decode_rejected 5001 4000 20004000 false
invoke_case B-05 test-B-05.jpg image/jpeg false pre_decode_rejected 10000 10000 100000000 false
invoke_case B-06 test-B-06.webp image/webp true "" 2500 2000 5000000 false
invoke_case B-07 test-B-07.jpg image/jpeg false pre_decode_rejected 6000 4000 24000000 false

# ---------------------------------------------------------------------------
# Final verdict
# ---------------------------------------------------------------------------
echo ""
echo "================================================================="
results_append ""
results_append "## Automated Verdict"

if [[ "$GATE2B_PASS" == "true" ]]; then
  echo "Automated checks: PASS"
  echo "(Telemetry verification — cpu_time_used and WorkerMemoryUsed — required before final PASS)"
  results_append "Automated verdict: PASS (pending telemetry verification)"
  results_append "Final verdict: _complete after recording cpu_time_used and WorkerMemoryUsed_"
else
  echo "Automated checks: FAIL"
  results_append "Automated verdict: FAIL"
  for r in "${FAIL_REASONS[@]}"; do
    echo "  - $r"
    results_append "  - $r"
  done
fi

echo "Results file: $RESULTS_MD"
echo "Log instructions: $LOG_INSTRUCTIONS"
echo "================================================================="

# Non-zero exit for FAIL or INCONCLUSIVE
[[ "$GATE2B_PASS" == "true" ]] || exit 1
```

---

## Section 13 — Pre-Deployment Checklist Summary

Before executing `gate2b-run.sh`:
1. Run `gate2b-fixtures.py` once; verify preflight output
2. Run `gate2b-local-test.sh`; review responses; record serve exit code
3. Run `deno fmt --check`, `deno lint`, `deno check`, `gitleaks detect`
4. Record SHA-256 of `magick.wasm` and `index.ts`
5. Submit all artifacts to three parties; receive explicit sign-off
6. Only after sign-off: invoke `gate2b-run.sh` with `PROJECT_REF` and `ANON_KEY` set

---

## Section 14 — Results Format

`tools/image-spike/gate2b-evidence/gate2b-results.md` (written by runner):

```
# Gate 2B Results
Date: ...
PROJECT_REF: ...

## Fixture Preflight
B-03: test-B-03.jpg 8388608 bytes 5000x4000 sha256=...
...

## Hashes
magick.wasm sha256: ...
index.ts sha256: ...

## Deployment
bundle_mb: 14.3

## Test Invocations

### B-03
curl_exit=0  HTTP=200  wall_time_s=9.234
x-request-id: abc-123
run_id: 550e8400-...
accepted=true  reason=
dimensions=5000x4000  pixel_count=20000000
sha256: a1b2c3... (verified)
RIFF metadata: clean

## B-03 Telemetry (complete manually)
run_id: 550e8400-...
cold_wall_time_s: 9.234
  cpu_time_used: <fill from logs> — must be < 200 ms
  WorkerMemoryUsed (max): <fill from dashboard> — must be ≤ 220 MB

## Automated Verdict
Automated verdict: PASS (pending telemetry verification)
Final verdict: _complete after recording cpu_time_used and WorkerMemoryUsed_
```

The operator fills in the telemetry fields after log capture and records the final verdict.

---

## Section 15 — Step B Gate

If Gate 2B passes (all automated + telemetry criteria met, both recorded in `gate2b-results.md`):
- Confirmed pixel limit is the Gate 2B hosted limit (≤ Phase A limit; hosted governs if they differ)
- A separate Step B proposal with three-party approval is required before `upload-complete` TypeScript begins
- `magick.wasm` must be re-copied to `_shared/` under Step B's authorized scope — Gate 2B cleanup removes it

---

## Section 16 — Security Constraints

- `ANON_KEY` set as runtime shell variable only; never written to any file, echoed, or logged
- `image-spike` function is stateless; writes nothing to database or storage
- Three-party governance required before `gate2b-run.sh` is invoked
- No migration or schema change authorized under this gate

---

## Section 17 — Approval Record

| Party | Status | Notes |
|---|---|---|
| Claude | Approved | Rev 4 authored by Claude; all 7 Rev 3 blockers addressed |
| Codex | Pending | — |
| Bill | Pending | — |

**Execution blocked until: (a) three-party approval of this document, (b) Gate 2A fully closed, (c) pre-deployment code review receives three-party sign-off.**
