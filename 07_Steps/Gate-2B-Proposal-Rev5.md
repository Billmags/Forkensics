# Gate 2B Proposal — Rev 5 — Hosted magick-wasm Spike on forkensics-dev

**Status:** DRAFT — awaiting three-party approval

**Governance gate:** Three-party approval (Bill + Claude + Codex) required before any cloud operation is executed. The magic words are `APPROVED: Gate 2B Rev 5 — Hosted magick-wasm Spike`.

**Authorized by:** Step 27 Rev 5 §3 Gate 2 Phase B.

**Supersedes:** Gate 2B Rev 4 (rejected — 10 execution blockers).

**Rev 5 changes from Rev 4:**
1. Runner no longer pre-creates `IMG_DIR`; the fixture generator creates it exclusively via `os.makedirs(out_dir, exist_ok=False)`.
2. `--use-docker` removed (not in CLI 2.111.0). `supabase functions logs` replaced with CLI `functions log` alternatives and a dashboard procedure (see §8.2). `grep -P` replaced with portable `grep -oE` / `awk` throughout.
3. `jq .accepted // "MISSING"` replaced with `jq -r 'if has("X") and (.X | type)=="boolean" then (.X|tostring) else "MISSING" end'` for all boolean fields.
4. Two-deployment protocol: Phase 0 deploys, invokes B-03 **only**, then deletes — no other request shares that measurement window. Phase 1 redeploys for the functional matrix. The function emits `console.log(JSON.stringify({ event: "invoke", run_id, label }))` for log searchability.
5. Telemetry is captured **before** Phase 0 function deletion via an interactive gate. The operator records `cpu_time_used` and `WorkerMemoryUsed` from the Supabase Log Explorer, enters them into the runner, and the runner validates them before proceeding. The runner never exits 0 while telemetry is unresolved.
6. `RESULTS_DIR` must be absent before the runner starts (preflight fails if it exists). Evidence (responses, headers, timings) is written to `RESULTS_DIR` progressively. Failed remote deletion causes a non-zero final exit; the runner pauses for confirmation before deletion so the operator can save evidence first.
7. Local verification script (`gate2b-local-test.sh`) adds `--no-verify-jwt` to `supabase functions serve`; asserts curl exit code, HTTP status, and key response fields; and fixes signal traps to call `exit` after cleanup.
8. B-06 WebP fixture now embeds XMP (containing `Iptc4xmpCore` IPTC data and `dc:description` comment) via Pillow's `xmp` parameter. Pre-decode rejected fixtures (B-04, B-05, B-07) use uniform-color images (not random noise) to guarantee they stay within their byte-range bands. The generator verifies WebP metadata families by scanning RIFF chunks and XMP content.
9. RIFF parser: rejects files where `len(data) != 8 + declared_riff_payload` (exact length); verifies parsing ends exactly at `riff_end` (no trailing partial bytes); retains the chunk-count guard and boundary checks.
10. Bundle size is now fail-closed: unparseable size aborts the runner (FAIL). Runner additionally asserts `label`, valid UUID format for `run_id`, `input_size_bytes` equals actual file size, and `output_size_bytes` equals decoded WebP byte count.

---

## Section 1 — Prerequisites

### 1.1 Gate 2A Full Closure (blocks execution, not approval)

All seven remaining Gate 2A evidence items must be complete before any cloud operation executes.

### 1.2 Pre-Deployment Code Review (blocks deployment, not approval)

Before the runner invokes `supabase functions deploy`, all three parties must sign off on:

- `supabase/functions/image-spike/index.ts` (full source)
- `supabase/config.toml` diff (`[functions.image-spike]` section only)
- `tools/image-spike/gate2b-run.sh`
- `tools/image-spike/gate2b-fixtures.py`
- `tools/image-spike/gate2b-verify-metadata.py`
- `tools/image-spike/gate2b-local-test.sh`
- SHA-256 of `tools/image-spike/magick.wasm` and `index.ts`
- Local Edge Runtime result (see §1.3)
- `deno fmt --check`, `deno lint`, `deno check` — zero findings
- `gitleaks detect` — no findings

### 1.3 Local Edge Runtime Verification

```bash
#!/usr/bin/env bash
# tools/image-spike/gate2b-local-test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMG_DIR="$SCRIPT_DIR/test-images"
LOCAL_URL="http://localhost:54321/functions/v1/image-spike"
SERVE_PID=""
SERVE_EXIT=0

cleanup_serve() {
  if [[ -n "$SERVE_PID" ]]; then
    kill "$SERVE_PID" 2>/dev/null || true
    wait "$SERVE_PID" 2>/dev/null
    SERVE_EXIT=$?
    echo "supabase functions serve exit: $SERVE_EXIT"
  fi
}
trap 'cleanup_serve' EXIT
trap 'cleanup_serve; exit 130' INT
trap 'cleanup_serve; exit 143' TERM

[[ -d "$IMG_DIR" ]] || { echo "FATAL: generate fixtures first (gate2b-fixtures.py)" >&2; exit 1; }

# --no-verify-jwt avoids needing a real JWT locally
supabase functions serve image-spike --no-verify-jwt &
SERVE_PID=$!
echo "serve PID: $SERVE_PID"
sleep 6  # Allow worker startup + WASM init

PASS=true

run_local_case() {
  local label="$1" img="$2" mime="$3" exp_accepted="$4"
  echo ""
  echo "--- LOCAL $label ---"
  local out="/tmp/local-gate2b-${label}.json"
  local curl_w
  curl_w=$(curl -s -o "$out" -w '%{http_code}\t%{time_total}' \
    --max-time 60 \
    -X POST "${LOCAL_URL}?label=${label}" \
    -H "Content-Type: $mime" \
    --data-binary "@$img" 2>/dev/null)
  local curl_exit=$?
  local http_status wall_time resp_accepted
  http_status=$(printf '%s' "$curl_w" | awk -F'\t' '{print $1}')
  wall_time=$(printf '%s' "$curl_w" | awk -F'\t' '{print $2}')

  echo "  curl_exit=$curl_exit  HTTP=$http_status  wall_time=${wall_time}s"
  if [[ $curl_exit -ne 0 ]]; then echo "  FAIL: curl transport error"; PASS=false; return; fi
  if [[ "$http_status" != "200" ]]; then echo "  FAIL: HTTP $http_status"; PASS=false; return; fi

  resp_accepted=$(jq -r 'if has("accepted") and (.accepted | type)=="boolean" then (.accepted|tostring) else "MISSING" end' \
    "$out" 2>/dev/null || echo "PARSE_ERROR")
  echo "  accepted=$resp_accepted (expected $exp_accepted)"
  [[ "$resp_accepted" == "$exp_accepted" ]] || { echo "  FAIL: accepted mismatch"; PASS=false; }
  echo "  response: $(cat "$out" | head -c 300)"
}

run_local_case "local-B-01" "$IMG_DIR/test-B-01.jpg" "image/jpeg" "true"
run_local_case "local-B-04" "$IMG_DIR/test-B-04.jpg" "image/jpeg" "false"

echo ""
if [[ "$PASS" == "true" ]]; then
  echo "LOCAL TEST: PASS"
else
  echo "LOCAL TEST: FAIL"
  exit 1
fi
```

---

## Section 2 — Purpose

Gate 2A verified `magick-wasm` locally. Gate 2B verifies the pipeline operates within Supabase's hosted Edge Runtime resource envelope, specifically the 2-second CPU limit (200 ms conservative threshold used) and 256 MB memory limit. Gate 2B must pass before Step B TypeScript begins.

---

## Section 3 — Authorized Cloud Operations

Two deployments of `image-spike` are authorized, in sequence:

**Phase 0:** Deploy `image-spike` → invoke B-03 only (one request) → capture telemetry → delete `image-spike`.

**Phase 1:** Deploy `image-spike` → invoke B-01, B-02, B-04, B-05, B-06, B-07 → delete `image-spike`.

No other function deployments, schema changes, production data writes, or modification to existing functions are authorized.

---

## Section 4 — Spike Function Design

### 4.1 Location and Header

`supabase/functions/image-spike/index.ts` — first line: `// DISPOSABLE — Gate 2B only. Delete after results recorded. Do not merge to main.`

### 4.2 WASM Loading

```typescript
const wasmBytes = await Deno.readFile(
  new URL("../_shared/magick.wasm", import.meta.url),
);
await initializeImageMagick(wasmBytes);
```

WASM initialized at module level so cost appears in BootEvent, not handler timing.

### 4.3 config.toml Entry

```toml
[functions.image-spike]
static_files = ["./functions/_shared/magick.wasm"]
```

### 4.4 Pipeline

1. `run_id = crypto.randomUUID()`
2. **Emit to logs:** `console.log(JSON.stringify({ event: "invoke", run_id, label }))`
3. Record `mem_before_rss = Deno.memoryUsage().rss`, `t0 = performance.now()`
4. Parse image file header; extract width, height
5. `pixelCount = width × height`; if > 20,000,000 → return pre-decode rejection
6. Full raster decode
7. **Remove all profiles, properties, comments** from in-memory image before encoding
8. Re-encode to WebP
9. **Structurally verify output bytes** (EXIF, ICCP, XMP chunks absent)
10. Compute `sha256` of output bytes (hex, 64 chars)
11. Base64-encode output bytes → `output_bytes` field
12. Return response

### 4.5 Response Contract

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
  "sha256": "a1b2c3d4e5f6...",
  "output_bytes": "<base64-encoded WebP>",
  "diagnostic": {
    "mem_before_rss_mb": 72.1,
    "mem_after_rss_mb": 110.4,
    "wall_time_ms": 3200
  }
}
```

Pre-decode rejection omits `output_bytes`, `output_size_bytes`, `sha256`, `metadata_clean`.

### 4.6 Authentication

Legacy JWT-based anon key from forkensics-dev API settings (`anon public`). Publishable-key format (`sb_publishable_` prefix) not accepted. Set as runtime environment variable; never written to any file.

---

## Section 5 — Test Manifest

Phase 0 invokes B-03 alone. Phase 1 invokes B-01 (first request of Phase 1 deployment), B-02, B-04, B-05, B-06, B-07.

| ID | Filename | MIME | W | H | Pixels | Min B | Max B | Expected accepted | Reason |
|---|---|---|---|---|---|---|---|---|---|
| B-03¹ | test-B-03.jpg | image/jpeg | 5000 | 4000 | 20,000,000 | 2,000,000 | 10,000,000 | true | — |
| B-01² | test-B-01.jpg | image/jpeg | 2500 | 2000 | 5,000,000 | 500,000 | 10,000,000 | true | — |
| B-02 | test-B-02.jpg | image/jpeg | 4000 | 2500 | 10,000,000 | 1,000,000 | 10,000,000 | true | — |
| B-04 | test-B-04.jpg | image/jpeg | 5001 | 4000 | 20,004,000 | 10,000 | 500,000 | false | pre_decode_rejected |
| B-05 | test-B-05.jpg | image/jpeg | 10000 | 10000 | 100,000,000 | 10,000 | 500,000 | false | pre_decode_rejected |
| B-06 | test-B-06.webp | image/webp | 2500 | 2000 | 5,000,000 | 200,000 | 10,000,000 | true | — |
| B-07 | test-B-07.jpg | image/jpeg | 6000 | 4000 | 24,000,000 | 10,000 | 500,000 | false | pre_decode_rejected |

¹ Phase 0, first and only request (telemetry isolation).
² First request of Phase 1 deployment.

Rejected fixtures (B-04, B-05, B-07) are uniform-color JPEGs — not noise — to guarantee small file size.
Upload ceiling: all fixtures ≤ 10,000,000 bytes. Preflight enforces this.
Accepted fixtures (B-01, B-02, B-03, B-06) must contain EXIF, GPS, ICC, XMP, IPTC, COMMENT before processing.

---

## Section 6 — Pass Criteria

| # | Criterion | Threshold | Source |
|---|---|---|---|
| 1 | All curl exit codes | 0 | curl `$?` |
| 2 | All HTTP statuses | 200 (never 546) | curl `-w '%{http_code}'` |
| 3 | B-03/B-01/B-02/B-06: `accepted` | true | Response JSON |
| 4 | B-04/B-05/B-07: `reason` | `pre_decode_rejected` | Response JSON |
| 5 | All: `label` field | matches manifest | Response JSON |
| 6 | All: `run_id` format | valid UUID | Response JSON |
| 7 | All: `width`, `height`, `pixel_count` | match manifest | Response JSON |
| 8 | Accepted: `input_size_bytes` | equals actual file size | Response JSON vs. `wc -c` |
| 9 | B-03: `cpu_time_used` (correlated by `run_id`) | < 200 ms | Supabase Log Explorer |
| 10 | B-03: `WorkerMemoryUsed` (max in B-03 window) | ≤ 220 MB | Supabase dashboard |
| 11 | B-03: cold wall-clock (Phase 0) | ≤ 15 s | curl `-w '%{time_total}'` |
| 12 | B-01: Phase 1 first-request wall-clock | ≤ 30 s | curl `-w '%{time_total}'` |
| 13 | Bundle size (both phases) | ≤ 20 MB | Deploy output, parsed |
| 14 | Accepted: `metadata_clean` | true | Response JSON |
| 15 | Accepted: `output_bytes` decodes to valid WebP | RIFF/WEBP header present | Runner |
| 16 | Accepted: SHA-256 recomputed from `output_bytes` | matches `sha256` field | Runner |
| 17 | Accepted: `output_size_bytes` | equals decoded WebP byte count | Runner vs. `wc -c` |
| 18 | Accepted: RIFF chunk parser | EXIF, ICCP, XMP absent | `gate2b-verify-metadata.py` |

---

## Section 7 — Failure and Inconclusive Definitions

**Hard failures (runner exits immediately):**
- HTTP 546 on any invocation
- Bundle size > 20 MB or unparseable
- Preflight failure (any)

**Soft failures (accumulated; runner continues collecting data):**
- Any other criterion in §6 not met

**INCONCLUSIVE (treated as FAIL):**
- B-03 `run_id` not found in Supabase logs
- `cpu_time_used` not attributable to B-03 `run_id`
- `WorkerMemoryUsed` not isolatable to B-03 Phase 0 window
- Operator types `INCONCLUSIVE` at telemetry gate

Runner exits nonzero for any FAIL or INCONCLUSIVE.

---

## Section 8 — Telemetry Methodology

### 8.1 Phase 0 Isolation Protocol

1. Deploy `image-spike` (Phase 0).
2. Invoke B-03 as the sole request to this deployment; record `run_id` from response body.
3. The function emits `console.log(JSON.stringify({ event: "invoke", run_id, label }))` to make it searchable in the Log Explorer.
4. The runner pauses: operator opens Supabase Log Explorer, searches by `run_id`, and records `cpu_time_used` and `WorkerMemoryUsed` (see §8.2) before deletion.
5. Operator enters values into the runner prompt; runner validates numerically.
6. Runner deletes Phase 0 deployment; confirms deletion.
7. Phase 1 deploys.

### 8.2 Locating Telemetry in Supabase Dashboard

**Log Explorer (`cpu_time_used`):**
1. Open: `https://supabase.com/dashboard/project/<PROJECT_REF>/logs/edge-logs`
2. Filter: `metadata.function_id = 'image-spike'`
3. Search log text for the `run_id` value from the B-03 response
4. Find the log entry that contains `"event":"invoke"` with the matching `run_id`
5. `cpu_time_used` appears in the worker lifecycle entry for that isolate

**Monitoring → Edge Functions (`WorkerMemoryUsed`):**
1. Open: `https://supabase.com/dashboard/project/<PROJECT_REF>/functions`
2. Click the `image-spike` function → Metrics tab
3. Note the timestamp of the B-03 invocation
4. Record the **maximum** `WorkerMemoryUsed` value in the 60-second window around that timestamp

If either metric is unavailable or the log entry cannot be correlated to the B-03 `run_id`: type `INCONCLUSIVE` at the runner prompt.

### 8.3 CPU Time Field

Field name: `cpu_time_used` (documented field; no `_ms` suffix). Pass threshold: < 200 ms (conservative; accounts for Supabase documentation conflict between general-limits [2 s] and CPU-limits guide [200 ms]).

---

## Section 9 — WASM Lifecycle

The WASM binary at `tools/image-spike/magick.wasm` is copied to `supabase/functions/_shared/magick.wasm` before Phase 0 deployment and removed unconditionally in cleanup. Step B is not authorized; the binary must not persist in `_shared/` after Gate 2B.

Cleanup checks for file existence independently of state flags (handles interrupts between copy and flag-set):
```bash
if [[ -f "$WASM_DST" ]]; then rm "$WASM_DST"; fi
```

---

## Section 10 — Supporting Scripts

### 10.1 gate2b-verify-metadata.py

```python
#!/usr/bin/env python3
"""
Byte-level WebP RIFF chunk parser — Gate 2B metadata verification.
Strict: requires file length == 8 + declared RIFF payload.
         requires parsing to end exactly at RIFF boundary.
Exit 0: clean. Exit 1: metadata found. Exit 2: invalid/malformed.
"""
import sys
import struct

METADATA_FOURCCS: dict[bytes, str] = {
    b'EXIF': 'EXIF (contains EXIF IFD, GPS IFD, IPTC-NAA embedded in EXIF)',
    b'ICCP': 'ICCP (ICC color profile)',
    b'XMP ': 'XMP  (XMP metadata; may contain IPTC-IIM, dc:description)',
}
MAX_CHUNKS = 1024


def parse_webp_riff(data: bytes) -> list[str]:
    if len(data) < 12:
        raise ValueError(f"File too short ({len(data)} bytes; need ≥12 for RIFF/WEBP header)")

    if data[0:4] != b'RIFF':
        raise ValueError(f"Not RIFF: leading bytes are {data[0:4]!r}")

    declared_payload = struct.unpack_from('<I', data, 4)[0]
    expected_len = 8 + declared_payload

    # Strict: actual file length must equal declared RIFF length
    if len(data) != expected_len:
        raise ValueError(
            f"File length {len(data)} ≠ declared RIFF size "
            f"(header declares {declared_payload} payload bytes → expected file {expected_len} bytes)"
        )

    if data[8:12] != b'WEBP':
        raise ValueError(f"RIFF type is not WEBP: got {data[8:12]!r}")

    found: list[str] = []
    riff_end = expected_len  # == len(data)
    pos = 12
    chunk_count = 0

    while pos + 8 <= riff_end:
        chunk_count += 1
        if chunk_count > MAX_CHUNKS:
            raise ValueError(f"Exceeded {MAX_CHUNKS} chunks at pos={pos} — malformed input")

        fourcc = data[pos:pos + 4]
        chunk_data_size = struct.unpack_from('<I', data, pos + 4)[0]
        chunk_data_end = pos + 8 + chunk_data_size

        # Validate chunk boundary against RIFF boundary
        if chunk_data_end > riff_end:
            raise ValueError(
                f"Chunk at pos={pos} ({fourcc!r}) declares {chunk_data_size} bytes "
                f"(end={chunk_data_end}) exceeds RIFF boundary ({riff_end})"
            )

        if fourcc in METADATA_FOURCCS:
            found.append(
                f"  pos={pos}  fourcc={fourcc.decode('ascii','replace')!r}"
                f"  size={chunk_data_size}  — {METADATA_FOURCCS[fourcc]}"
            )

        pad = chunk_data_size % 2
        pos = chunk_data_end + pad

    # Strict: parsing must end exactly at RIFF boundary
    if pos != riff_end:
        raise ValueError(
            f"Parsing ended at pos={pos} but RIFF boundary is {riff_end} "
            f"({riff_end - pos} trailing bytes before boundary)"
        )

    return found


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
        print(f"INVALID WebP — {e}", file=sys.stderr)
        sys.exit(2)
    if found:
        print(f"METADATA FOUND in {path} — Gate 2B FAIL:")
        for entry in found:
            print(entry)
        sys.exit(1)
    print(f"OK: {path} — no EXIF/ICCP/XMP chunks ({len(data)} bytes)")
    sys.exit(0)


if __name__ == '__main__':
    main()
```

### 10.2 gate2b-fixtures.py

```python
#!/usr/bin/env python3
"""
Gate 2B deterministic fixture generator.
Requires: pip install Pillow numpy piexif --break-system-packages

Accepted fixtures (B-01, B-02, B-03, B-06): high-entropy noise with full metadata.
Rejected fixtures (B-04, B-05, B-07): uniform-color with correct header dimensions,
  very small file size to satisfy ≤500 KB band.
"""
import hashlib
import io
import os
import struct
import sys

import numpy as np
from PIL import Image
import piexif

# Manifest: (id, width, height, min_bytes, max_bytes, mime, needs_metadata, is_noise)
MANIFEST = [
    ("B-01", 2500, 2000, 500_000,   10_000_000, "jpeg", True,  True),
    ("B-02", 4000, 2500, 1_000_000, 10_000_000, "jpeg", True,  True),
    ("B-03", 5000, 4000, 2_000_000, 10_000_000, "jpeg", True,  True),
    ("B-04", 5001, 4000,    10_000,    500_000,  "jpeg", False, False),
    ("B-05",10000,10000,    10_000,    500_000,  "jpeg", False, False),
    ("B-06", 2500, 2000,   200_000, 10_000_000, "webp", True,  True),
    ("B-07", 6000, 4000,    10_000,    500_000,  "jpeg", False, False),
]

# JPEG quality starting points for noise images (auto-reduced to fit size band)
JPEG_QUALITY_START = {"B-01": 65, "B-02": 35, "B-03": 20}


def _noise_image(width: int, height: int, seed: int = 42) -> Image.Image:
    rng = np.random.default_rng(seed=seed)
    return Image.fromarray(
        rng.integers(0, 256, (height, width, 3), dtype=np.uint8), "RGB"
    )


def _uniform_image(width: int, height: int, color=(30, 60, 90)) -> Image.Image:
    return Image.new("RGB", (width, height), color=color)


def _build_exif_bytes() -> bytes:
    """EXIF + GPS sub-IFD for JPEG embedding."""
    return piexif.dump({
        "0th": {
            piexif.ImageIFD.Make: b"Gate2B-Camera",
            piexif.ImageIFD.Software: b"Gate2B-v5",
            piexif.ImageIFD.Artist: b"Gate2B",
            piexif.ImageIFD.ImageDescription: b"Gate 2B test fixture",
        },
        "Exif": {
            piexif.ExifIFD.UserComment: b"ASCII\x00\x00\x00Gate2B user comment",
        },
        "GPS": {
            piexif.GPSIFD.GPSLatitudeRef: b"N",
            piexif.GPSIFD.GPSLatitude: ((37, 1), (46, 1), (2983, 100)),
            piexif.GPSIFD.GPSLongitudeRef: b"W",
            piexif.GPSIFD.GPSLongitude: ((122, 1), (25, 1), (959, 100)),
            piexif.GPSIFD.GPSDateStamp: b"2026:01:01",
        },
        "1st": {},
    })


def _build_xmp_packet() -> bytes:
    """XMP packet embedding IPTC-IIM (Iptc4xmpCore) and dc:description comment."""
    return (
        b'<?xpacket begin="\xef\xbb\xbf" id="W5M0MpCehiHzreSzNTczkc9d"?>\n'
        b'<x:xmpmeta xmlns:x="adobe:ns:meta/">\n'
        b'<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\n'
        b'<rdf:Description\n'
        b'  xmlns:dc="http://purl.org/dc/elements/1.1/"\n'
        b'  xmlns:Iptc4xmpCore="http://iptc.org/std/Iptc4xmpCore/1.0/xmlns/">\n'
        b'  <dc:description>Gate2B fixture comment via XMP</dc:description>\n'
        b'  <dc:title>Gate2B Test Fixture v5</dc:title>\n'
        b'  <Iptc4xmpCore:CreatorContactInfo>\n'
        b'    <rdf:Description>\n'
        b'      <Iptc4xmpCore:CiAdrCity>Gate2B City</Iptc4xmpCore:CiAdrCity>\n'
        b'    </rdf:Description>\n'
        b'  </Iptc4xmpCore:CreatorContactInfo>\n'
        b'</rdf:Description>\n'
        b'</rdf:RDF>\n'
        b'</x:xmpmeta>\n'
        b'<?xpacket end="w"?>'
    )


# Minimal 68-byte sRGB-like ICC profile for embedding
_ICC_PROFILE_BYTES = bytes.fromhex(
    "00000084"  # profile size (132 bytes for a real profile; use PIL's built-in)
)
# Use PIL's built-in sRGB profile if available
try:
    from PIL.ImageCms import createProfile, ImageCmsProfile as _P
    _ICC_PROFILE = _P(createProfile("sRGB")).tobytes()
except Exception:
    # Fallback: 4-byte stub that Pillow will embed as APP2 ICC_PROFILE
    # A real implementation should use a valid ICC profile binary
    _ICC_PROFILE = b'\x00' * 132


def _inject_jpeg_markers(jpeg_bytes: bytes, xmp: bytes, iptc: bytes) -> bytes:
    """Inject XMP (APP1) and IPTC (APP13) segments into JPEG after SOI."""

    def _make_app1_xmp(xmp_data: bytes) -> bytes:
        payload = b"http://ns.adobe.com/xap/1.0/\x00" + xmp_data
        length = len(payload) + 2
        return b'\xff\xe1' + struct.pack('>H', length) + payload

    def _make_app13_iptc(iptc_iim: bytes) -> bytes:
        ps3_header = b'Photoshop 3.0\x00'
        resource = (
            b'8BIM'
            + struct.pack('>H', 0x0404)
            + b'\x00\x00'
            + struct.pack('>I', len(iptc_iim))
            + iptc_iim
        )
        payload = ps3_header + resource
        length = len(payload) + 2
        return b'\xff\xed' + struct.pack('>H', length) + payload

    iptc_iim = b'\x1c\x02\x05' + struct.pack('>H', 14) + b'Gate2B fixture'
    xmp_seg = _make_app1_xmp(xmp)
    iptc_seg = _make_app13_iptc(iptc_iim)
    comment_seg = b'\xff\xfe' + struct.pack('>H', 2 + 36) + b'Gate2B JFIF comment marker v5'
    return jpeg_bytes[:2] + xmp_seg + iptc_seg + comment_seg + jpeg_bytes[2:]


def _scan_jpeg_families(data: bytes) -> set[str]:
    """Scan JPEG APP markers; return set of present metadata families."""
    if data[:2] != b'\xff\xd8':
        raise ValueError("Not JPEG")
    found: set[str] = set()
    i = 2
    while i + 4 <= len(data):
        if data[i] != 0xff:
            break
        marker = data[i + 1]
        if marker in (0xd8, 0xd9, 0x01) or 0xd0 <= marker <= 0xd7:
            i += 2
            continue
        if i + 4 > len(data):
            break
        seg_len = struct.unpack_from('>H', data, i + 2)[0]
        seg = data[i + 4: i + 2 + seg_len]
        if marker == 0xe1:
            if seg[:6] == b'Exif\x00\x00':
                found.add('EXIF')
                try:
                    d = piexif.load(seg[6:])
                    if d.get('GPS'):
                        found.add('GPS')
                except Exception:
                    pass
            elif seg[:29] == b'http://ns.adobe.com/xap/1.0/\x00':
                found.add('XMP')
        elif marker == 0xe2 and seg[:12] == b'ICC_PROFILE\x00':
            found.add('ICC')
        elif marker == 0xed and seg[:14] == b'Photoshop 3.0\x00':
            found.add('IPTC')
        elif marker == 0xfe:
            found.add('COMMENT')
        i += 2 + seg_len
    return found


def _scan_webp_families(data: bytes) -> set[str]:
    """Scan WebP RIFF chunks; return set of present metadata families."""
    if data[:4] != b'RIFF' or data[8:12] != b'WEBP':
        raise ValueError("Not WebP")
    declared = struct.unpack_from('<I', data, 4)[0]
    riff_end = min(8 + declared, len(data))
    found: set[str] = set()
    pos = 12
    while pos + 8 <= riff_end:
        fourcc = data[pos:pos + 4]
        chunk_size = struct.unpack_from('<I', data, pos + 4)[0]
        if fourcc == b'EXIF':
            found.add('EXIF')
            # GPS is in EXIF — verify presence
            exif_data = data[pos + 8: pos + 8 + chunk_size]
            for prefix in (b'', b'Exif\x00\x00'):
                try:
                    d = piexif.load(prefix + exif_data)
                    if d.get('GPS'):
                        found.add('GPS')
                    break
                except Exception:
                    pass
        elif fourcc == b'ICCP':
            found.add('ICC')
        elif fourcc == b'XMP ':
            found.add('XMP')
            xmp_content = data[pos + 8: pos + 8 + chunk_size]
            if b'Iptc4xmpCore' in xmp_content:
                found.add('IPTC')
            if b'dc:description' in xmp_content:
                found.add('COMMENT')
        pos += 8 + chunk_size + (chunk_size % 2)
    return found


def generate_jpeg_with_metadata(label: str, img: Image.Image,
                                 min_bytes: int, max_bytes: int,
                                 out_path: str) -> None:
    quality = JPEG_QUALITY_START.get(label, 50)
    exif_bytes = _build_exif_bytes()
    xmp = _build_xmp_packet()

    for attempt in range(30):
        buf = io.BytesIO()
        img.save(buf, "JPEG", quality=quality, exif=exif_bytes,
                 icc_profile=_ICC_PROFILE)
        raw = _inject_jpeg_markers(buf.getvalue(), xmp, b'')
        size = len(raw)
        if size <= max_bytes:
            break
        quality = max(1, quality - 3)
    else:
        raise RuntimeError(f"{label}: cannot fit within {max_bytes} bytes (quality={quality}, size={size})")

    if size < min_bytes:
        raise RuntimeError(f"{label}: size {size} < min {min_bytes}")
    if size > 10_000_000:
        raise RuntimeError(f"{label}: size {size} exceeds 10 MB upload ceiling")

    with open(out_path, 'wb') as f:
        f.write(raw)

    families = _scan_jpeg_families(raw)
    required = {'EXIF', 'GPS', 'ICC', 'XMP', 'IPTC', 'COMMENT'}
    missing = required - families
    if missing:
        raise RuntimeError(f"{label}: source fixture missing metadata families: {sorted(missing)}")

    sha = hashlib.sha256(raw).hexdigest()
    print(f"  metadata families: {sorted(families)} ✓")
    print(f"  {out_path} — {size:,} bytes, quality={quality}, sha256={sha[:16]}...")


def generate_uniform_jpeg(label: str, width: int, height: int,
                           min_bytes: int, max_bytes: int, out_path: str) -> None:
    """Uniform-color JPEG for pre-decode rejected fixtures (small, correct dimensions)."""
    img = _uniform_image(width, height, color=(30, 60 + hash(label) % 30, 90))
    buf = io.BytesIO()
    img.save(buf, "JPEG", quality=1)
    raw = buf.getvalue()
    size = len(raw)
    if not (min_bytes <= size <= max_bytes):
        raise RuntimeError(f"{label}: uniform JPEG size {size} outside [{min_bytes}, {max_bytes}]")
    if size > 10_000_000:
        raise RuntimeError(f"{label}: size {size} exceeds 10 MB")
    with open(out_path, 'wb') as f:
        f.write(raw)
    sha = hashlib.sha256(raw).hexdigest()
    print(f"  {out_path} — {size:,} bytes (uniform, no metadata), sha256={sha[:16]}...")


def generate_webp_with_metadata(label: str, img: Image.Image,
                                 min_bytes: int, max_bytes: int,
                                 out_path: str) -> None:
    exif_bytes = _build_exif_bytes()
    xmp_packet = _build_xmp_packet()

    buf = io.BytesIO()
    img.save(buf, "WebP", quality=60, exif=exif_bytes,
             icc_profile=_ICC_PROFILE, xmp=xmp_packet)
    raw = buf.getvalue()
    size = len(raw)

    if not (min_bytes <= size <= max_bytes):
        raise RuntimeError(f"{label}: WebP size {size} outside [{min_bytes}, {max_bytes}]")
    if size > 10_000_000:
        raise RuntimeError(f"{label}: size {size} exceeds 10 MB")

    with open(out_path, 'wb') as f:
        f.write(raw)

    families = _scan_webp_families(raw)
    required = {'EXIF', 'GPS', 'ICC', 'XMP', 'IPTC', 'COMMENT'}
    missing = required - families
    if missing:
        raise RuntimeError(f"{label}: WebP source fixture missing metadata: {sorted(missing)}")

    sha = hashlib.sha256(raw).hexdigest()
    print(f"  metadata families: {sorted(families)} ✓")
    print(f"  {out_path} — {size:,} bytes, sha256={sha[:16]}...")


def main() -> None:
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <output-dir>", file=sys.stderr)
        sys.exit(1)
    out_dir = sys.argv[1]
    # Fail if directory already exists (runner must not pre-create it)
    os.makedirs(out_dir, exist_ok=False)

    print("Gate 2B fixture generation (deterministic, seed=42) ...")
    for label, width, height, min_b, max_b, mime, needs_meta, is_noise in MANIFEST:
        print(f"\n--- {label} ({width}x{height}, {mime}) ---")
        out_path = os.path.join(out_dir, f"test-{label}.{'jpg' if mime=='jpeg' else 'webp'}")
        if mime == "jpeg" and needs_meta:
            img = _noise_image(width, height)
            generate_jpeg_with_metadata(label, img, min_b, max_b, out_path)
        elif mime == "jpeg" and not needs_meta:
            generate_uniform_jpeg(label, width, height, min_b, max_b, out_path)
        elif mime == "webp" and needs_meta:
            img = _noise_image(width, height)
            generate_webp_with_metadata(label, img, min_b, max_b, out_path)
        else:
            raise ValueError(f"Unhandled combination: mime={mime} needs_meta={needs_meta}")

    print("\nAll fixtures generated and verified.")


if __name__ == "__main__":
    main()
```

### 10.3 gate2b-run.sh

```bash
#!/usr/bin/env bash
# tools/image-spike/gate2b-run.sh — Gate 2B test runner, Rev 5
# DISPOSABLE — Gate 2B only. Execute only after three-party approval of Rev 5.
#
# Usage: PROJECT_REF=xxx ANON_KEY=yyy bash tools/image-spike/gate2b-run.sh
# ANON_KEY is never written to disk, echoed, or logged.
# Exits 0 on full PASS; exits 1 on any FAIL or INCONCLUSIVE.

set -uo pipefail
# -e intentionally absent: EXIT trap handles all paths.

# ---------------------------------------------------------------------------
# Environment validation — before any side effects
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
IMG_DIR="$REPO_ROOT/tools/image-spike/test-images"          # created by fixture generator
OUT_DIR="$REPO_ROOT/tools/image-spike/gate2b-responses"     # created by runner
RESULTS_DIR="$REPO_ROOT/tools/image-spike/gate2b-evidence"  # must be absent; created by runner
VERIFY_PY="$SCRIPT_DIR/gate2b-verify-metadata.py"
FIXTURES_PY="$SCRIPT_DIR/gate2b-fixtures.py"
RESULTS_MD="$RESULTS_DIR/gate2b-results.md"
FUNC_URL="https://${PROJECT_REF}.supabase.co/functions/v1/image-spike"

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------
CLEANUP_RAN=false
DEPLOY_ATTEMPTED=false   # set immediately before ANY deploy command
WASM_COPIED=false
CONFIG_PATCHED=false
REMOTE_DELETE_FAILED=false
GATE2B_PASS=true
declare -a FAIL_REASONS=()
LAST_WALL_TIME=""

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
  # Usage: bool_field <json-file> <field-name>
  # Returns "true", "false", or "MISSING"
  jq -r --arg f "$2" \
    'if has($f) and (.[$f] | type)=="boolean" then (.[$f]|tostring) else "MISSING" end' \
    "$1" 2>/dev/null || echo "PARSE_ERROR"
}

# ---------------------------------------------------------------------------
# Cleanup — idempotent; evidence-safe; noninteractive
# ---------------------------------------------------------------------------
cleanup() {
  if [[ "$CLEANUP_RAN" == "true" ]]; then return; fi
  CLEANUP_RAN=true
  local trigger="${1:-EXIT}"
  echo "" >&2
  echo "=================================================================" >&2
  echo "Gate 2B Cleanup (trigger: $trigger)" >&2
  echo "=================================================================" >&2

  # Remote deletion — attempt once; check existence if CLI fails
  if [[ "$DEPLOY_ATTEMPTED" == "true" ]]; then
    if ! supabase functions delete image-spike \
         --project-ref "$PROJECT_REF" 2>/dev/null; then
      # Check if the function is actually still there
      if supabase functions list --project-ref "$PROJECT_REF" 2>/dev/null \
         | grep -q "image-spike"; then
        echo "ERROR: Remote deletion failed and image-spike still listed." >&2
        echo "Delete manually: https://supabase.com/dashboard/project/$PROJECT_REF/functions" >&2
        REMOTE_DELETE_FAILED=true
      else
        echo "Remote deletion: function already absent — OK" >&2
      fi
    else
      sleep 3
      if supabase functions list --project-ref "$PROJECT_REF" 2>/dev/null \
         | grep -q "image-spike"; then
        echo "WARNING: image-spike still listed after deletion." >&2
        REMOTE_DELETE_FAILED=true
      else
        echo "Remote deletion: confirmed" >&2
      fi
    fi
  fi

  # Restore config.toml — remove [functions.image-spike] section only
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

  # Remove copied WASM (check file, not flag — handles interrupted copy)
  if [[ -f "$WASM_DST" ]]; then
    rm "$WASM_DST" && echo "Removed: $WASM_DST" >&2
  fi

  # Remove spike function source
  if [[ -d "$SPIKE_DIR" ]]; then
    rm -rf "$SPIKE_DIR" && echo "Removed: $SPIKE_DIR" >&2
  fi

  # Remove temporary directories (evidence is in RESULTS_DIR, which is kept)
  if [[ -d "$OUT_DIR" ]]; then
    rm -rf "$OUT_DIR" && echo "Removed: $OUT_DIR" >&2
  fi
  if [[ -d "$IMG_DIR" ]]; then
    rm -rf "$IMG_DIR" && echo "Removed: $IMG_DIR" >&2
  fi

  echo "Cleanup complete. Evidence in: $RESULTS_DIR" >&2

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
# Preflight — all directories must be absent before we start
# ---------------------------------------------------------------------------
echo "=== Gate 2B Preflight ==="

for dir in "$IMG_DIR" "$OUT_DIR" "$RESULTS_DIR"; do
  if [[ -d "$dir" ]]; then
    echo "FATAL: Directory already exists: $dir" >&2
    echo "  Delete it before running: rm -rf $dir" >&2
    exit 1
  fi
done
if [[ -f "$WASM_DST" ]]; then
  echo "FATAL: $WASM_DST already exists — clean up from prior run first" >&2; exit 1
fi
if grep -q '\[functions\.image-spike\]' "$CONFIG" 2>/dev/null; then
  echo "FATAL: [functions.image-spike] already in config.toml" >&2; exit 1
fi

for tool in supabase curl jq python3 shasum deno; do
  command -v "$tool" &>/dev/null || { echo "FATAL: $tool not found" >&2; exit 1; }
done
for f in "$WASM_SRC" "$VERIFY_PY" "$FIXTURES_PY"; do
  [[ -f "$f" ]] || { echo "FATAL: file not found: $f" >&2; exit 1; }
done
[[ -d "$SPIKE_DIR" ]] || { echo "FATAL: spike dir not found: $SPIKE_DIR" >&2; exit 1; }

mkdir -p "$OUT_DIR" "$RESULTS_DIR"
> "$RESULTS_MD"
results_append "# Gate 2B Results — Rev 5"
results_append "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
results_append "PROJECT_REF: $PROJECT_REF"
results_append ""
echo "Preflight: all directories clear"

# ---------------------------------------------------------------------------
# Generate fixtures (fixture generator creates IMG_DIR itself)
# ---------------------------------------------------------------------------
echo ""
echo "=== Generating fixtures ==="
python3 "$FIXTURES_PY" "$IMG_DIR" \
  || { echo "FATAL: fixture generation failed" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Verify fixtures against manifest
# ---------------------------------------------------------------------------
echo ""
echo "=== Verifying fixtures ==="

# label|filename|exp_w|exp_h|exp_pixels|min_bytes|max_bytes|exp_accepted|needs_meta
declare -a MANIFEST_CHECK=(
  "B-03|test-B-03.jpg|5000|4000|20000000|2000000|10000000|true|true"
  "B-01|test-B-01.jpg|2500|2000|5000000|500000|10000000|true|true"
  "B-02|test-B-02.jpg|4000|2500|10000000|1000000|10000000|true|true"
  "B-04|test-B-04.jpg|5001|4000|20004000|10000|500000|false|false"
  "B-05|test-B-05.jpg|10000|10000|100000000|10000|500000|false|false"
  "B-06|test-B-06.webp|2500|2000|5000000|200000|10000000|true|true"
  "B-07|test-B-07.jpg|6000|4000|24000000|10000|500000|false|false"
)

results_append "## Fixture Preflight"
preflight_ok=true
for entry in "${MANIFEST_CHECK[@]}"; do
  IFS="|" read -r label filename exp_w exp_h exp_pixels \
    min_bytes max_bytes exp_accepted needs_meta <<< "$entry"
  img="$IMG_DIR/$filename"
  [[ -f "$img" ]] || { echo "FATAL: $img missing" >&2; exit 1; }

  byte_size=$(wc -c < "$img" | awk '{print $1}')
  sha=$(shasum -a 256 "$img" | awk '{print $1}')
  dims=$(python3 -c "
from PIL import Image
with Image.open('$img') as im:
    print(im.width, im.height)
" 2>/dev/null) || { echo "FATAL: cannot read dimensions of $img" >&2; exit 1; }
  actual_w=$(echo "$dims" | awk '{print $1}')
  actual_h=$(echo "$dims" | awk '{print $2}')
  actual_px=$((actual_w * actual_h))

  ok=true
  [[ "$actual_w" == "$exp_w" && "$actual_h" == "$exp_h" ]] \
    || { fail "PREFLIGHT $label: dims ${actual_w}x${actual_h} ≠ ${exp_w}x${exp_h}"; ok=false; }
  [[ "$actual_px" == "$exp_pixels" ]] \
    || { fail "PREFLIGHT $label: pixel_count $actual_px ≠ $exp_pixels"; ok=false; }
  python3 -c "import sys; sys.exit(0 if $min_bytes <= $byte_size <= $max_bytes else 1)" \
    || { fail "PREFLIGHT $label: size $byte_size outside [$min_bytes, $max_bytes]"; ok=false; }
  [[ "$byte_size" -le 10000000 ]] \
    || { fail "PREFLIGHT $label: size $byte_size > 10 MB upload ceiling"; ok=false; }
  [[ "$ok" == "true" ]] && preflight_ok=true || preflight_ok=false

  results_append "$label: $filename ${byte_size}B ${actual_w}x${actual_h} sha256=${sha}"
  echo "PREFLIGHT $label: ${byte_size}B ${actual_w}x${actual_h} sha256=${sha:0:12}... $([ "$ok" == "true" ] && echo ✓ || echo FAIL)"
done
[[ "$preflight_ok" != "false" && "$GATE2B_PASS" == "true" ]] \
  || { echo "FATAL: preflight failed" >&2; exit 1; }

# ---------------------------------------------------------------------------
# WASM copy + verify
# ---------------------------------------------------------------------------
echo ""
echo "=== WASM copy ==="
cp "$WASM_SRC" "$WASM_DST"
SRC_HASH=$(shasum -a 256 "$WASM_SRC" | awk '{print $1}')
DST_HASH=$(shasum -a 256 "$WASM_DST" | awk '{print $1}')
[[ "$SRC_HASH" == "$DST_HASH" ]] \
  || { echo "FATAL: WASM copy hash mismatch" >&2; exit 1; }
WASM_COPIED=true
INDEX_HASH=$(shasum -a 256 "$SPIKE_DIR/index.ts" | awk '{print $1}')
results_append ""
results_append "## Hashes"
results_append "magick.wasm sha256: $SRC_HASH"
results_append "index.ts sha256: $INDEX_HASH"
echo "WASM sha256: $SRC_HASH ✓"

# ---------------------------------------------------------------------------
# config.toml patch
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
deno fmt --check "$SPIKE_DIR/index.ts" || { fail "deno fmt"; exit 1; }
deno lint "$SPIKE_DIR/index.ts"        || { fail "deno lint"; exit 1; }
deno check "$SPIKE_DIR/index.ts"       || { fail "deno check"; exit 1; }
gitleaks detect --source "$REPO_ROOT" --config "$REPO_ROOT/.gitleaks.toml" 2>/dev/null \
  || { fail "gitleaks"; exit 1; }
echo "Static checks passed"

# ---------------------------------------------------------------------------
# Approval gate
# ---------------------------------------------------------------------------
echo ""
echo "All three parties must have signed off on the pre-deployment code review."
read -rp "Type YES to confirm pre-deployment approval and proceed: " _confirm
[[ "$_confirm" == "YES" ]] || { echo "Deployment aborted." >&2; exit 1; }

# ---------------------------------------------------------------------------
# deploy_function — deploys image-spike; parses + enforces bundle size
# ---------------------------------------------------------------------------
deploy_function() {
  local phase="$1"
  echo ""
  echo "=== Phase $phase: Deploy image-spike ==="
  DEPLOY_ATTEMPTED=true   # set BEFORE the CLI command runs

  local deploy_out
  deploy_out=$(supabase functions deploy image-spike \
    --project-ref "$PROJECT_REF" 2>&1)
  local deploy_exit=$?
  echo "$deploy_out"

  if [[ $deploy_exit -ne 0 ]]; then
    fail "Phase $phase: deployment failed (exit $deploy_exit)"
    return 1
  fi

  # Parse bundle size — fail-closed if unparseable
  local bundle_mb
  bundle_mb=$(printf '%s' "$deploy_out" \
    | grep -oiE '[0-9]+(\.[0-9]+)? ?[Mm][Bb]' \
    | grep -oE '[0-9]+(\.[0-9]+)?' \
    | head -1)
  if [[ -z "$bundle_mb" ]]; then
    fail "Phase $phase: bundle size not found in deploy output — INCONCLUSIVE"
    results_append "Phase $phase bundle_mb: UNPARSEABLE → FAIL"
    return 1
  fi
  python3 -c "import sys; sys.exit(0 if float('$bundle_mb') <= 20 else 1)" \
    || { fail "Phase $phase: bundle size ${bundle_mb} MB > 20 MB"; return 1; }
  echo "Phase $phase bundle: ${bundle_mb} MB ≤ 20 MB ✓"
  results_append "Phase $phase bundle_mb: $bundle_mb"
  return 0
}

# ---------------------------------------------------------------------------
# delete_confirmed — deletes image-spike; FAILS if deletion is not confirmed
# ---------------------------------------------------------------------------
delete_confirmed() {
  local phase="$1"
  echo ""
  echo "Deleting image-spike (Phase $phase) ..."
  if supabase functions delete image-spike --project-ref "$PROJECT_REF" 2>/dev/null; then
    sleep 3
    if supabase functions list --project-ref "$PROJECT_REF" 2>/dev/null \
       | grep -q "image-spike"; then
      fail "Phase $phase: deletion unconfirmed — image-spike still listed"
      REMOTE_DELETE_FAILED=true
      return 1
    fi
    echo "Phase $phase deletion: confirmed ✓"
    return 0
  else
    # Check if it's already gone
    if supabase functions list --project-ref "$PROJECT_REF" 2>/dev/null \
       | grep -q "image-spike"; then
      fail "Phase $phase: deletion failed and function still listed"
      REMOTE_DELETE_FAILED=true
      return 1
    fi
    echo "Phase $phase deletion: function already absent — OK"
    return 0
  fi
}

# ---------------------------------------------------------------------------
# UUID validation helper (portable; no grep -P)
# ---------------------------------------------------------------------------
is_valid_uuid() {
  # Returns 0 if argument matches xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
  echo "$1" | grep -qiE \
    '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
}

# ---------------------------------------------------------------------------
# invoke_case — single curl call; all assertions; no double invocations
# Sets LAST_WALL_TIME to the curl time_total.
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

  echo ""
  echo "--- $label ($filename, $mime) ---"

  # Single curl: body (-o), headers (-D), status+time (-w), exit code ($?)
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

  local http_status wall_time req_id
  http_status=$(printf '%s' "$curl_w" | awk -F'\t' '{print $1}')
  wall_time=$(printf '%s'   "$curl_w" | awk -F'\t' '{print $2}')
  LAST_WALL_TIME="$wall_time"
  req_id=$(grep -i '^x-request-id:' "$hdr" 2>/dev/null \
    | awk '{print $2}' | tr -d '\r' | head -1 || true)

  echo "  curl_exit=$curl_exit  HTTP=$http_status  wall_time=${wall_time}s"
  echo "  x-request-id: ${req_id:-<not found>}"

  results_append ""
  results_append "### $label"
  results_append "curl_exit=$curl_exit  HTTP=$http_status  wall_time_s=$wall_time"
  results_append "x-request-id: ${req_id:-<not found>}"

  # curl transport / timeout
  if [[ $curl_exit -ne 0 ]]; then
    fail "$label: curl exit $curl_exit (transport error or timeout)"
    results_append "FAIL: curl transport error"
    return 0
  fi

  # HTTP 546 = hard failure
  if [[ "$http_status" == "546" ]]; then
    fail "$label: HTTP 546 — resource limit exceeded"
    results_append "HARD FAIL: HTTP 546"
    exit 1   # runner exits immediately
  fi

  if [[ "$http_status" != "200" ]]; then
    fail "$label: HTTP $http_status"
    results_append "FAIL: unexpected HTTP $http_status"
    return 0
  fi

  # ── label field ──
  local resp_label
  resp_label=$(jq -r '.label // "MISSING"' "$out" 2>/dev/null || echo "PARSE_ERROR")
  if [[ "$resp_label" != "$label" ]]; then
    fail "$label: response label='$resp_label' ≠ '$label'"; fi

  # ── run_id (valid UUID format) ──
  local resp_run_id
  resp_run_id=$(jq -r '.run_id // ""' "$out" 2>/dev/null || echo "")
  results_append "run_id: ${resp_run_id:-MISSING}"
  if ! is_valid_uuid "$resp_run_id"; then
    fail "$label: run_id '${resp_run_id}' is not a valid UUID"
  else
    echo "  run_id=${resp_run_id} ✓"
  fi

  # ── accepted (boolean guard) ──
  local resp_accepted
  resp_accepted=$(bool_field "$out" "accepted")
  if [[ "$resp_accepted" == "MISSING" || "$resp_accepted" == "PARSE_ERROR" ]]; then
    fail "$label: accepted field missing or not boolean"
  elif [[ "$resp_accepted" != "$exp_accepted" ]]; then
    fail "$label: accepted=$resp_accepted ≠ $exp_accepted"
  else
    echo "  accepted=$resp_accepted ✓"
  fi

  # ── reason (rejection cases only) ──
  if [[ "$exp_accepted" == "false" ]]; then
    local resp_reason
    resp_reason=$(jq -r '.reason // "MISSING"' "$out" 2>/dev/null || echo "PARSE_ERROR")
    if [[ "$resp_reason" != "$exp_reason" ]]; then
      fail "$label: reason='$resp_reason' ≠ '$exp_reason'"
    else
      echo "  reason=$resp_reason ✓"
    fi
  fi

  # ── dimensions ──
  local resp_w resp_h resp_pixels
  resp_w=$(jq -r '.width // 0' "$out" 2>/dev/null || echo 0)
  resp_h=$(jq -r '.height // 0' "$out" 2>/dev/null || echo 0)
  resp_pixels=$(jq -r '.pixel_count // 0' "$out" 2>/dev/null || echo 0)
  if [[ "$resp_w" != "$exp_w" || "$resp_h" != "$exp_h" ]]; then
    fail "$label: dimensions ${resp_w}x${resp_h} ≠ ${exp_w}x${exp_h}"
  else
    echo "  dimensions=${resp_w}x${resp_h} ✓"
  fi
  if [[ "$resp_pixels" != "$exp_pixels" ]]; then
    fail "$label: pixel_count=$resp_pixels ≠ $exp_pixels"
  fi

  # ── accepted-only assertions ──
  if [[ "$exp_accepted" == "true" ]]; then

    # input_size_bytes
    local resp_input_size
    resp_input_size=$(jq -r '.input_size_bytes // 0' "$out" 2>/dev/null || echo 0)
    if [[ "$resp_input_size" != "$actual_input_size" ]]; then
      fail "$label: input_size_bytes=$resp_input_size ≠ actual $actual_input_size"
    else
      echo "  input_size_bytes=$resp_input_size ✓"
    fi

    # metadata_clean (boolean guard)
    local resp_meta_clean
    resp_meta_clean=$(bool_field "$out" "metadata_clean")
    if [[ "$resp_meta_clean" == "MISSING" || "$resp_meta_clean" == "PARSE_ERROR" ]]; then
      fail "$label: metadata_clean field missing or not boolean"
    elif [[ "$resp_meta_clean" != "true" ]]; then
      fail "$label: metadata_clean=$resp_meta_clean ≠ true"
    else
      echo "  metadata_clean=true ✓"
    fi

    # sha256 format
    local resp_sha256
    resp_sha256=$(jq -r '.sha256 // ""' "$out" 2>/dev/null || echo "")
    if ! printf '%s' "$resp_sha256" | grep -qE '^[0-9a-f]{64}$'; then
      fail "$label: sha256 format invalid: '${resp_sha256}'"
    fi

    # output_bytes: decode → validate WebP → recompute sha256 → output_size_bytes → RIFF parser
    local resp_output_b64
    resp_output_b64=$(jq -r '.output_bytes // ""' "$out" 2>/dev/null || echo "")
    if [[ -z "$resp_output_b64" || "$resp_output_b64" == "null" ]]; then
      fail "$label: output_bytes field absent"
    else
      if printf '%s' "$resp_output_b64" | base64 -d > "$webp" 2>/dev/null; then
        local decoded_size
        decoded_size=$(wc -c < "$webp" | awk '{print $1}')
        echo "  output_bytes decoded: $decoded_size bytes"

        # Validate WebP RIFF/WEBP header
        local header_check
        header_check=$(python3 -c "
with open('$webp','rb') as f: d=f.read(12)
print('valid' if d[:4]==b'RIFF' and d[8:12]==b'WEBP' else 'invalid')
" 2>/dev/null || echo "error")
        if [[ "$header_check" != "valid" ]]; then
          fail "$label: decoded output_bytes is not valid WebP (header check failed)"
        else
          echo "  WebP RIFF/WEBP header ✓"

          # Recompute SHA-256 and compare
          local actual_sha
          actual_sha=$(shasum -a 256 "$webp" | awk '{print $1}')
          if [[ "$actual_sha" != "$resp_sha256" ]]; then
            fail "$label: SHA-256 mismatch: recomputed=$actual_sha response=$resp_sha256"
          else
            echo "  SHA-256 match ✓"
          fi

          # output_size_bytes must equal decoded WebP byte count
          local resp_output_size
          resp_output_size=$(jq -r '.output_size_bytes // 0' "$out" 2>/dev/null || echo 0)
          if [[ "$resp_output_size" != "$decoded_size" ]]; then
            fail "$label: output_size_bytes=$resp_output_size ≠ decoded size $decoded_size"
          else
            echo "  output_size_bytes=$resp_output_size ✓"
          fi

          # RIFF chunk parser
          local riff_out
          if riff_out=$(python3 "$VERIFY_PY" "$webp" 2>&1); then
            echo "  RIFF chunk parser: no metadata ✓"
            results_append "RIFF: clean"
          else
            fail "$label: RIFF parser found metadata or malformed WebP"
            results_append "RIFF: FAIL — $riff_out"
          fi
        fi
      else
        fail "$label: base64 decode of output_bytes failed"
      fi
    fi

    results_append "sha256: $resp_sha256"
  fi  # end accepted-only assertions

  # Record all key fields for the results file
  results_append "accepted=$resp_accepted  wall_time_s=$wall_time"
  return 0
}

# ---------------------------------------------------------------------------
# Phase 0 — B-03 telemetry isolation
# ---------------------------------------------------------------------------
results_append ""
results_append "## Phase 0 — B-03 Telemetry"

deploy_function "0" || exit 1

invoke_case B-03 test-B-03.jpg image/jpeg true "" 5000 4000 20000000
B03_RUN_ID=$(jq -r '.run_id // ""' "$OUT_DIR/B-03.json" 2>/dev/null || echo "")
B03_WALL_TIME="$LAST_WALL_TIME"

echo ""
echo "B-03 cold wall-clock: ${B03_WALL_TIME}s (threshold ≤ 15 s)"
python3 -c "import sys; sys.exit(0 if float('$B03_WALL_TIME') <= 15 else 1)" 2>/dev/null \
  || fail "B-03 cold wall-clock ${B03_WALL_TIME}s > 15 s"
results_append "B-03 cold_wall_time_s: $B03_WALL_TIME"

# Telemetry capture gate — happens BEFORE deletion so operator can find logs
echo ""
echo "================================================================="
echo "B-03 TELEMETRY CAPTURE GATE (before deletion)"
echo "================================================================="
echo "B-03 run_id: ${B03_RUN_ID:-MISSING — check function logs}"
echo ""
echo "1. Open Log Explorer:"
echo "   https://supabase.com/dashboard/project/$PROJECT_REF/logs/edge-logs"
echo "2. Search text for: $B03_RUN_ID"
echo "3. Locate the entry with event='invoke' for label='B-03'."
echo "   Find 'cpu_time_used' in the worker lifecycle entry for this isolate."
echo "4. Open Monitoring → Edge Functions → Metrics:"
echo "   https://supabase.com/dashboard/project/$PROJECT_REF/functions"
echo "   Record maximum WorkerMemoryUsed (MB) in the B-03 time window."
echo ""
echo "Type INCONCLUSIVE if a metric cannot be found or attributed."
echo "================================================================="
read -rp "B-03 cpu_time_used (ms, e.g. 145.3 or INCONCLUSIVE): " B03_CPU_INPUT
read -rp "B-03 WorkerMemoryUsed max (MB, e.g. 180.5 or INCONCLUSIVE): " B03_MEM_INPUT

if [[ "$B03_CPU_INPUT" == "INCONCLUSIVE" || "$B03_MEM_INPUT" == "INCONCLUSIVE" ]]; then
  fail "B-03 telemetry INCONCLUSIVE — cannot attribute cpu/memory to B-03 run_id"
  results_append "B-03 cpu_time_used: INCONCLUSIVE → FAIL"
  results_append "B-03 WorkerMemoryUsed: INCONCLUSIVE → FAIL"
else
  python3 - "$B03_CPU_INPUT" "$B03_MEM_INPUT" <<'PYEOF'
import sys
try:
    cpu = float(sys.argv[1])
    mem = float(sys.argv[2])
    print(f"cpu_time_used: {cpu} ms")
    print(f"WorkerMemoryUsed: {mem} MB")
    if cpu >= 200:
        print(f"FAIL: cpu_time_used {cpu} >= 200 ms")
        sys.exit(1)
    if mem > 220:
        print(f"FAIL: WorkerMemoryUsed {mem} > 220 MB")
        sys.exit(1)
    print("B-03 telemetry: PASS")
    sys.exit(0)
except ValueError as e:
    print(f"ERROR: invalid numeric value: {e}")
    sys.exit(1)
PYEOF
  telem_exit=$?
  if [[ $telem_exit -ne 0 ]]; then
    fail "B-03 telemetry validation failed"
  fi
  results_append "B-03 cpu_time_used: $B03_CPU_INPUT ms (threshold < 200 ms)"
  results_append "B-03 WorkerMemoryUsed: $B03_MEM_INPUT MB (threshold ≤ 220 MB)"
fi

# Phase 0 deletion — confirmed
delete_confirmed "0" || true  # failure recorded; continue to matrix

# ---------------------------------------------------------------------------
# Phase 1 — Functional matrix
# ---------------------------------------------------------------------------
results_append ""
results_append "## Phase 1 — Functional Matrix"

deploy_function "1" || { echo "Phase 1 deploy failed; proceeding to cleanup" >&2; exit 1; }

# B-01 (first request of Phase 1 deployment; warm-path timing criterion)
invoke_case B-01 test-B-01.jpg image/jpeg true "" 2500 2000 5000000
B01_WALL_TIME="$LAST_WALL_TIME"
echo "B-01 Phase-1 wall-clock: ${B01_WALL_TIME}s (threshold ≤ 30 s)"
python3 -c "import sys; sys.exit(0 if float('$B01_WALL_TIME') <= 30 else 1)" 2>/dev/null \
  || fail "B-01 Phase-1 wall-clock ${B01_WALL_TIME}s > 30 s"
results_append "B-01 phase1_wall_time_s: $B01_WALL_TIME"

invoke_case B-02 test-B-02.jpg image/jpeg true "" 4000 2500 10000000
invoke_case B-04 test-B-04.jpg image/jpeg false pre_decode_rejected 5001 4000 20004000
invoke_case B-05 test-B-05.jpg image/jpeg false pre_decode_rejected 10000 10000 100000000
invoke_case B-06 test-B-06.webp image/webp  true "" 2500 2000 5000000
invoke_case B-07 test-B-07.jpg image/jpeg false pre_decode_rejected 6000 4000 24000000

# Phase 1 deletion — confirmed
delete_confirmed "1" || true  # failure recorded; continue to verdict

# ---------------------------------------------------------------------------
# Final verdict
# ---------------------------------------------------------------------------
echo ""
echo "================================================================="
results_append ""
results_append "## Final Verdict"

if [[ "$GATE2B_PASS" == "true" ]]; then
  echo "Gate 2B: PASS"
  results_append "Verdict: PASS"
  results_append "All automated and telemetry criteria met."
else
  echo "Gate 2B: FAIL"
  results_append "Verdict: FAIL"
  results_append "Failures:"
  for r in "${FAIL_REASONS[@]}"; do
    echo "  - $r"
    results_append "  - $r"
  done
fi

echo "Results: $RESULTS_MD"
echo "================================================================="

[[ "$GATE2B_PASS" == "true" ]] || exit 1
```

---

## Section 11 — Pre-Deployment Checklist Summary

Before typing YES at the runner's approval gate:
1. `python3 gate2b-fixtures.py test-images/` — review output; verify all metadata families listed
2. `bash gate2b-local-test.sh` — both B-01 and B-04 must pass; record serve exit code
3. `deno fmt --check supabase/functions/image-spike/index.ts`
4. `deno lint supabase/functions/image-spike/index.ts`
5. `deno check supabase/functions/image-spike/index.ts`
6. `gitleaks detect`
7. `shasum -a 256 tools/image-spike/magick.wasm supabase/functions/image-spike/index.ts`
8. Submit all artifacts + outputs to three parties; receive sign-off

---

## Section 12 — Results Format

`tools/image-spike/gate2b-evidence/gate2b-results.md` — written progressively by the runner; not deleted by cleanup.

Key manual fields (B-03 telemetry) are written by the runner from operator input at the telemetry gate. The final verdict is written at the end of the run.

---

## Section 13 — Step B Gate

If Gate 2B passes:
- Confirmed pixel limit is the Gate 2B hosted limit
- A separate Step B proposal with three-party approval is required before `upload-complete` TypeScript begins
- `magick.wasm` is re-copied to `_shared/` under Step B's scope — Gate 2B cleanup removes it

---

## Section 14 — Security Constraints

- `ANON_KEY` is a runtime environment variable only; never written to any file
- `image-spike` is stateless; writes nothing to database or storage
- Three-party governance required before `gate2b-run.sh` executes
- No migration or schema change authorized under this gate
- Deploy command: `supabase functions deploy image-spike --project-ref $PROJECT_REF` (no `--use-api`)

---

## Section 15 — Approval Record

| Party | Status | Notes |
|---|---|---|
| Claude | Approved | Rev 5 authored by Claude; all 10 Rev 4 blockers addressed |
| Codex | Pending | — |
| Bill | Pending | — |

**Execution blocked until: (a) three-party approval of this document; (b) Gate 2A fully closed; (c) pre-deployment code review has three-party sign-off.**
