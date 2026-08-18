# Gate 2B Proposal — Rev 6 — Hosted magick-wasm Spike on forkensics-dev

**Status:** DRAFT — awaiting three-party approval

**Governance gate:** Three-party approval (Bill + Claude + Codex) required before any cloud operation is executed. The magic words are `APPROVED: Gate 2B Rev 6 — Hosted magick-wasm Spike`.

**Authorized by:** Step 27 Rev 5 §3 Gate 2 Phase B.

**Supersedes:** Gate 2B Rev 5 (rejected — 7 script-level blockers).

**Rev 6 changes from Rev 5 (all 7 blockers addressed):**

1. **COMMENT marker length (Blocker 1):** `struct.pack('>H', 2 + 36)` replaced with `struct.pack('>H', 2 + len(comment))` where `comment = b'Gate2B JFIF comment marker v5'` (29 bytes). Declares 31 (0x001F) in the length field, matching the actual payload. Verified by local parse probe (see §13).

2. **B-05 size band (Blocker 2):** Uniform 10,000×10,000 JPEG at quality=1 measures 1,563,126 bytes (1.563 MB). Band raised to `[1,000,000, 2,500,000]` bytes. Local probe confirms PASS.

3. **Accepted fixture tight bands + quality search (Blocker 3):** New `find_quality_for_band()` function replaces the unidirectional quality reducer. Starts at quality=95, coarse-steps down by 5 until size ≤ max_bytes, then fine-tunes up by 1. Updated target bands verified locally:
   - B-01: `[4,500,000, 5,500,000]` bytes → quality=91, 4,670,106 bytes ✓
   - B-02: `[8,500,000, 10,000,000]` bytes → quality=91, 9,337,166 bytes ✓
   - B-03: `[8,500,000, 10,000,000]` bytes → quality=61, 9,619,332 bytes ✓
   - B-06: `[4,500,000, 5,500,000]` bytes → quality=95, 4,798,862 bytes ✓

4. **Unique evidence directory (Blocker 4):** `RESULTS_DIR` is now timestamp-unique: `gate2b-evidence-${TIMESTAMP}`. `OUT_DIR` is nested inside `RESULTS_DIR` and is never deleted by cleanup. IMG_DIR, SPIKE_DIR, and WASM_DST are still deleted (they are temporary, not evidence).

5. **Deletion fail-closed (Blocker 5):** `delete_confirmed()` captures `supabase functions list` exit code separately; any non-zero list exit is a hard FAIL (no longer silently treated as "absent"). Phase 0 deletion failure aborts before Phase 1: `delete_confirmed "0" || exit 1`.

6. **Telemetry via execution_id (Blocker 6):** Two-step procedure: (Step 1) find B-03 LogEvent by `run_id` → record `execution_id` from that entry; (Step 2) find ShutdownEvent by `execution_id` → extract `cpu_time_used`. Runner prompts for `execution_id` as a separate field; records both identifiers in results.md.

7. **Bundle size anchored parse (Blocker 7):** `deploy_function()` now passes `--debug` to `supabase functions deploy` and parses the anchored `script size:` label (fallback: `bundle size:`). No match = hard FAIL. Replaced `hash(label)` with `FIXTURE_COLORS` dict (deterministic per Python process).

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
# tools/image-spike/gate2b-local-test.sh — Rev 6
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
trap 'cleanup_serve; exit' EXIT
trap 'cleanup_serve; exit 130' INT
trap 'cleanup_serve; exit 143' TERM

[[ -d "$IMG_DIR" ]] || { echo "FATAL: generate fixtures first (gate2b-fixtures.py)" >&2; exit 1; }

# --no-verify-jwt avoids needing a real JWT locally
supabase functions serve image-spike --no-verify-jwt &
SERVE_PID=$!
echo "serve PID: $SERVE_PID"
sleep 6  # Allow worker startup + WASM init

PASS=true

bool_field_local() {
  jq -r --arg f "$2" \
    'if has($f) and (.[$f] | type)=="boolean" then (.[$f]|tostring) else "MISSING" end' \
    "$1" 2>/dev/null || echo "PARSE_ERROR"
}

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

  resp_accepted=$(bool_field_local "$out" "accepted")
  echo "  accepted=$resp_accepted (expected $exp_accepted)"
  [[ "$resp_accepted" == "$exp_accepted" ]] || { echo "  FAIL: accepted mismatch"; PASS=false; }
  echo "  response: $(head -c 300 "$out")"
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
| B-03¹ | test-B-03.jpg | image/jpeg | 5000 | 4000 | 20,000,000 | 8,500,000 | 10,000,000 | true | — |
| B-01² | test-B-01.jpg | image/jpeg | 2500 | 2000 | 5,000,000 | 4,500,000 | 5,500,000 | true | — |
| B-02 | test-B-02.jpg | image/jpeg | 4000 | 2500 | 10,000,000 | 8,500,000 | 10,000,000 | true | — |
| B-04 | test-B-04.jpg | image/jpeg | 5001 | 4000 | 20,004,000 | 10,000 | 500,000 | false | pre_decode_rejected |
| B-05 | test-B-05.jpg | image/jpeg | 10000 | 10000 | 100,000,000 | 1,000,000 | 2,500,000 | false | pre_decode_rejected |
| B-06 | test-B-06.webp | image/webp | 2500 | 2000 | 5,000,000 | 4,500,000 | 5,500,000 | true | — |
| B-07 | test-B-07.jpg | image/jpeg | 6000 | 4000 | 24,000,000 | 10,000 | 500,000 | false | pre_decode_rejected |

¹ Phase 0, first and only request (telemetry isolation).
² First request of Phase 1 deployment.

Rejected fixtures (B-04, B-05, B-07) are uniform-color JPEGs — not noise — with deterministic fixed colors from `FIXTURE_COLORS` dict (not `hash(label)`).
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
| 9 | B-03: `cpu_time_used` (from ShutdownEvent correlated by `execution_id`) | < 200 ms | Supabase Log Explorer |
| 10 | B-03: `WorkerMemoryUsed` (max in B-03 execution window) | ≤ 220 MB | Supabase dashboard |
| 11 | B-03: cold wall-clock (Phase 0) | ≤ 15 s | curl `-w '%{time_total}'` |
| 12 | B-01: Phase 1 first-request wall-clock | ≤ 30 s | curl `-w '%{time_total}'` |
| 13 | Bundle size (both phases) | ≤ 20 MB | Deploy output `--debug`, `script size:` field |
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
- Phase 0 deletion failure (prevents Phase 1)

**Soft failures (accumulated; runner continues collecting data):**
- Any other criterion in §6 not met

**INCONCLUSIVE (treated as FAIL):**
- B-03 `run_id` not found in Supabase logs
- `execution_id` not found in LogEvent for that `run_id`
- `cpu_time_used` not attributable to B-03 `execution_id`
- `WorkerMemoryUsed` not isolatable to B-03 Phase 0 execution
- Operator types `INCONCLUSIVE` at telemetry gate

Runner exits nonzero for any FAIL or INCONCLUSIVE.

---

## Section 8 — Telemetry Methodology

### 8.1 Phase 0 Isolation Protocol

1. Deploy `image-spike` (Phase 0).
2. Invoke B-03 as the sole request to this deployment; record `run_id` from response body.
3. The function emits `console.log(JSON.stringify({ event: "invoke", run_id, label }))` to make it searchable in the Log Explorer.
4. The runner pauses: operator executes the two-step telemetry lookup (§8.2) before deletion.
5. Operator enters `execution_id`, `cpu_time_used`, and `WorkerMemoryUsed` at the runner prompt.
6. Runner validates values numerically.
7. Runner deletes Phase 0 deployment; confirms deletion via `supabase functions list` with exit-code guard.
8. Phase 1 deploys only if Phase 0 deletion is confirmed.

### 8.2 Two-Step Telemetry Lookup

**Step 1 — Find LogEvent by `run_id`, extract `execution_id`:**
1. Open: `https://supabase.com/dashboard/project/<PROJECT_REF>/logs/edge-logs`
2. Filter: `metadata.function_id = 'image-spike'`
3. Search log text for the `run_id` value from the B-03 response.
4. Find the log entry containing `"event":"invoke"` and `"label":"B-03"` matching that `run_id`.
5. Record the `execution_id` value from that same log entry (it appears alongside `run_id` in the function log output).

**Step 2 — Find ShutdownEvent by `execution_id`, extract `cpu_time_used`:**
1. In the same Log Explorer session, search for: `<execution_id from Step 1>`
2. Find the worker lifecycle event (ShutdownEvent or equivalent) for that `execution_id`.
3. Extract `cpu_time_used` (field name has no `_ms` suffix).
4. Open Monitoring → Edge Functions → `image-spike` → Metrics tab.
5. Identify the B-03 worker by `execution_id`; record maximum `WorkerMemoryUsed` (MB).

If either identifier cannot be found, or the ShutdownEvent cannot be correlated to the B-03 `execution_id`: type `INCONCLUSIVE` at the runner prompt.

### 8.3 CPU Time Field

Field name: `cpu_time_used` (no `_ms` suffix). Pass threshold: < 200 ms (conservative; accounts for Supabase documentation conflict between general-limits [2 s] and CPU-limits guide [200 ms]).

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
Gate 2B deterministic fixture generator — Rev 6.
Requires: pip install Pillow numpy piexif --break-system-packages

Accepted fixtures (B-01, B-02, B-03, B-06): high-entropy noise with full metadata.
  Quality is found by binary search so each file lands in its target band.
Rejected fixtures (B-04, B-05, B-07): uniform-color with correct header dimensions,
  small file size, fixed color mapping (no hash(label)).
"""
import hashlib
import io
import os
import struct
import sys
from typing import Callable

import numpy as np
from PIL import Image
import piexif

# ── Manifest ──────────────────────────────────────────────────────────────────
# (id, width, height, min_bytes, max_bytes, fmt, needs_metadata, is_noise)
MANIFEST = [
    ("B-01", 2500, 2000,  4_500_000,  5_500_000, "jpeg", True,  True),
    ("B-02", 4000, 2500,  8_500_000, 10_000_000, "jpeg", True,  True),
    ("B-03", 5000, 4000,  8_500_000, 10_000_000, "jpeg", True,  True),
    ("B-04", 5001, 4000,     10_000,    500_000,  "jpeg", False, False),
    ("B-05",10000,10000,  1_000_000,  2_500_000,  "jpeg", False, False),
    ("B-06", 2500, 2000,  4_500_000,  5_500_000, "webp", True,  True),
    ("B-07", 6000, 4000,     10_000,    500_000,  "jpeg", False, False),
]

# Fixed colors for rejected fixtures — deterministic across Python processes.
# hash(label) must NOT be used: Python randomizes hash() per process since 3.3.
FIXTURE_COLORS: dict[str, tuple[int, int, int]] = {
    "B-04": (30, 60, 90),
    "B-05": (60, 90, 30),
    "B-07": (90, 30, 60),
}


# ── Quality search ─────────────────────────────────────────────────────────────

def find_quality_for_band(
    encode_fn: Callable[[int], bytes],
    min_bytes: int,
    max_bytes: int,
    label: str,
) -> tuple[int, int]:
    """Return (quality, size) with min_bytes ≤ size ≤ max_bytes, maximising quality.

    Algorithm:
      1. Coarse pass: start at quality=95, step down by 5 until size ≤ max_bytes.
      2. Fine pass: step up by 1 from the coarse landing point to find the highest
         quality still in [min_bytes, max_bytes].
      If the coarse step overshoots (size < min_bytes after one step), search
      quality+1 .. quality+4 for a value in band.
    """
    q = 95
    # Coarse: step down by 5 until size <= max_bytes
    while q > 1:
        data = encode_fn(q)
        size = len(data)
        if size <= max_bytes:
            break
        q = max(1, q - 5)

    data = encode_fn(q)
    size = len(data)

    if size >= min_bytes:
        # In band at coarse landing; fine-tune upward to maximise quality
        for tq in range(q + 1, min(q + 6, 96)):
            td = encode_fn(tq)
            ts = len(td)
            if ts <= max_bytes:
                q, size = tq, ts
            else:
                break
        return q, size

    # size < min_bytes: coarse step skipped over the band (step=5 was too wide).
    # Search q+1 through q+5 for a value in [min_bytes, max_bytes].
    for dq in range(1, 6):
        tq = q + dq
        if tq > 95:
            break
        td = encode_fn(tq)
        ts = len(td)
        if min_bytes <= ts <= max_bytes:
            return tq, ts
        if ts > max_bytes:
            break

    raise RuntimeError(
        f"{label}: no quality in [1,95] produces size in "
        f"[{min_bytes:,}, {max_bytes:,}]. "
        f"At q={q}: {len(encode_fn(q)):,} bytes. "
        "Check that the image is high-entropy and bands are achievable."
    )


# ── Image factories ───────────────────────────────────────────────────────────

def _noise_image(width: int, height: int, seed: int = 42) -> Image.Image:
    """Deterministic high-entropy noise image (seed=42 each call)."""
    rng = np.random.default_rng(seed=seed)
    return Image.fromarray(
        rng.integers(0, 256, (height, width, 3), dtype=np.uint8), "RGB"
    )


def _uniform_image(width: int, height: int, color: tuple[int, int, int]) -> Image.Image:
    return Image.new("RGB", (width, height), color=color)


# ── Metadata builders ─────────────────────────────────────────────────────────

def _build_exif_bytes() -> bytes:
    """EXIF + GPS sub-IFD for JPEG embedding."""
    return piexif.dump({
        "0th": {
            piexif.ImageIFD.Make: b"Gate2B-Camera",
            piexif.ImageIFD.Software: b"Gate2B-v6",
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
        b'  <dc:title>Gate2B Test Fixture v6</dc:title>\n'
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


# Minimal sRGB ICC profile for embedding
try:
    from PIL.ImageCms import createProfile, ImageCmsProfile as _P
    _ICC_PROFILE = _P(createProfile("sRGB")).tobytes()
except Exception:
    _ICC_PROFILE = b'\x00' * 132


# ── JPEG marker injection ─────────────────────────────────────────────────────

def _inject_jpeg_markers(jpeg_bytes: bytes, xmp: bytes, iptc_iim: bytes) -> bytes:
    """Inject XMP (APP1) and IPTC (APP13) and COM segments into JPEG after SOI.

    COM segment length field: 2 + len(payload), per JFIF spec.
    The length field itself occupies 2 bytes and is included in the declared value.
    """

    def _make_app1_xmp(xmp_data: bytes) -> bytes:
        payload = b"http://ns.adobe.com/xap/1.0/\x00" + xmp_data
        length = len(payload) + 2  # +2 for the length field itself
        return b'\xff\xe1' + struct.pack('>H', length) + payload

    def _make_app13_iptc(iptc_raw: bytes) -> bytes:
        ps3_header = b'Photoshop 3.0\x00'
        resource = (
            b'8BIM'
            + struct.pack('>H', 0x0404)
            + b'\x00\x00'
            + struct.pack('>I', len(iptc_raw))
            + iptc_raw
        )
        payload = ps3_header + resource
        length = len(payload) + 2
        return b'\xff\xed' + struct.pack('>H', length) + payload

    def _make_com(text: bytes) -> bytes:
        # COM segment: 0xFF 0xFE + big-endian uint16(2 + len(payload)) + payload
        # The length field declares (2 + len(payload)) because the 2-byte length
        # field itself is included in the count.
        length = 2 + len(text)
        return b'\xff\xfe' + struct.pack('>H', length) + text

    iptc_raw = b'\x1c\x02\x05' + struct.pack('>H', 14) + b'Gate2B fixture'
    comment = b'Gate2B JFIF comment marker v6'

    xmp_seg = _make_app1_xmp(xmp)
    iptc_seg = _make_app13_iptc(iptc_raw)
    com_seg = _make_com(comment)

    return jpeg_bytes[:2] + xmp_seg + iptc_seg + com_seg + jpeg_bytes[2:]


# ── Metadata family scanners ──────────────────────────────────────────────────

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


# ── Per-format generators ─────────────────────────────────────────────────────

def generate_jpeg_with_metadata(
    label: str,
    img: Image.Image,
    min_bytes: int,
    max_bytes: int,
    out_path: str,
) -> None:
    exif_bytes = _build_exif_bytes()
    xmp = _build_xmp_packet()

    def encode(q: int) -> bytes:
        buf = io.BytesIO()
        img.save(buf, "JPEG", quality=q, exif=exif_bytes, icc_profile=_ICC_PROFILE)
        raw = _inject_jpeg_markers(buf.getvalue(), xmp, b'')
        return raw

    quality, size = find_quality_for_band(encode, min_bytes, max_bytes, label)
    raw = encode(quality)

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


def generate_uniform_jpeg(
    label: str,
    width: int,
    height: int,
    min_bytes: int,
    max_bytes: int,
    out_path: str,
) -> None:
    """Uniform-color JPEG for pre-decode rejected fixtures.

    Uses FIXTURE_COLORS dict — not hash(label) — to ensure determinism
    across Python processes (hash() is randomised per-process since Python 3.3).
    """
    color = FIXTURE_COLORS.get(label, (50, 50, 50))
    img = _uniform_image(width, height, color)
    buf = io.BytesIO()
    img.save(buf, "JPEG", quality=1)
    raw = buf.getvalue()
    size = len(raw)
    if not (min_bytes <= size <= max_bytes):
        raise RuntimeError(
            f"{label}: uniform JPEG size {size:,} outside [{min_bytes:,}, {max_bytes:,}]"
        )
    if size > 10_000_000:
        raise RuntimeError(f"{label}: size {size} exceeds 10 MB")
    with open(out_path, 'wb') as f:
        f.write(raw)
    sha = hashlib.sha256(raw).hexdigest()
    print(f"  color={color}, size={size:,} bytes (uniform, no metadata), sha256={sha[:16]}...")


def generate_webp_with_metadata(
    label: str,
    img: Image.Image,
    min_bytes: int,
    max_bytes: int,
    out_path: str,
) -> None:
    exif_bytes = _build_exif_bytes()
    xmp_packet = _build_xmp_packet()

    def encode(q: int) -> bytes:
        buf = io.BytesIO()
        img.save(buf, "WebP", quality=q, exif=exif_bytes,
                 icc_profile=_ICC_PROFILE, xmp=xmp_packet)
        return buf.getvalue()

    quality, size = find_quality_for_band(encode, min_bytes, max_bytes, label)
    raw = encode(quality)

    if size > 10_000_000:
        raise RuntimeError(f"{label}: size {size} exceeds 10 MB upload ceiling")

    with open(out_path, 'wb') as f:
        f.write(raw)

    families = _scan_webp_families(raw)
    required = {'EXIF', 'GPS', 'ICC', 'XMP', 'IPTC', 'COMMENT'}
    missing = required - families
    if missing:
        raise RuntimeError(f"{label}: WebP source fixture missing metadata: {sorted(missing)}")

    sha = hashlib.sha256(raw).hexdigest()
    print(f"  metadata families: {sorted(families)} ✓")
    print(f"  {out_path} — {size:,} bytes, quality={quality}, sha256={sha[:16]}...")


# ── Entry point ───────────────────────────────────────────────────────────────

def main() -> None:
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <output-dir>", file=sys.stderr)
        sys.exit(1)
    out_dir = sys.argv[1]
    # Fail if directory already exists (runner must not pre-create it)
    os.makedirs(out_dir, exist_ok=False)

    print("Gate 2B fixture generation (deterministic, seed=42) ...")
    for label, width, height, min_b, max_b, fmt, needs_meta, is_noise in MANIFEST:
        print(f"\n--- {label} ({width}x{height}, {fmt}) ---")
        ext = 'jpg' if fmt == 'jpeg' else 'webp'
        out_path = os.path.join(out_dir, f"test-{label}.{ext}")
        if fmt == "jpeg" and needs_meta:
            img = _noise_image(width, height)
            generate_jpeg_with_metadata(label, img, min_b, max_b, out_path)
        elif fmt == "jpeg" and not needs_meta:
            generate_uniform_jpeg(label, width, height, min_b, max_b, out_path)
        elif fmt == "webp" and needs_meta:
            img = _noise_image(width, height)
            generate_webp_with_metadata(label, img, min_b, max_b, out_path)
        else:
            raise ValueError(f"Unhandled combination: fmt={fmt} needs_meta={needs_meta}")

    print("\nAll fixtures generated and verified.")


if __name__ == "__main__":
    main()
```

### 10.3 gate2b-run.sh

```bash
#!/usr/bin/env bash
# tools/image-spike/gate2b-run.sh — Gate 2B test runner, Rev 6
# DISPOSABLE — Gate 2B only. Execute only after three-party approval of Rev 6.
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
IMG_DIR="$REPO_ROOT/tools/image-spike/test-images"    # created by fixture generator; deleted in cleanup
VERIFY_PY="$SCRIPT_DIR/gate2b-verify-metadata.py"
FIXTURES_PY="$SCRIPT_DIR/gate2b-fixtures.py"

# Unique evidence directory: timestamp ensures no conflict with prior runs.
# OUT_DIR is nested inside RESULTS_DIR and is NEVER deleted by cleanup.
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RESULTS_DIR="$REPO_ROOT/tools/image-spike/gate2b-evidence-${TIMESTAMP}"
OUT_DIR="$RESULTS_DIR/responses"
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
  # Returns "true", "false", or "MISSING".
  # jq '.field // "MISSING"' is WRONG for boolean false; use type guard.
  jq -r --arg f "$2" \
    'if has($f) and (.[$f] | type)=="boolean" then (.[$f]|tostring) else "MISSING" end' \
    "$1" 2>/dev/null || echo "PARSE_ERROR"
}

# ---------------------------------------------------------------------------
# Cleanup — idempotent; evidence-safe; noninteractive.
# Deletes: remote function, config patch, WASM_DST, SPIKE_DIR, IMG_DIR.
# NEVER deletes: RESULTS_DIR or OUT_DIR (evidence must be preserved).
# ---------------------------------------------------------------------------
cleanup() {
  if [[ "$CLEANUP_RAN" == "true" ]]; then return; fi
  CLEANUP_RAN=true
  local trigger="${1:-EXIT}"
  echo "" >&2
  echo "=================================================================" >&2
  echo "Gate 2B Cleanup (trigger: $trigger)" >&2
  echo "=================================================================" >&2

  # Remote deletion
  if [[ "$DEPLOY_ATTEMPTED" == "true" ]]; then
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

  # Remove copied WASM
  if [[ -f "$WASM_DST" ]]; then
    rm "$WASM_DST" && echo "Removed: $WASM_DST" >&2
  fi

  # Remove spike function source
  if [[ -d "$SPIKE_DIR" ]]; then
    rm -rf "$SPIKE_DIR" && echo "Removed: $SPIKE_DIR" >&2
  fi

  # Remove temporary test images (NOT RESULTS_DIR or OUT_DIR — those are evidence)
  if [[ -d "$IMG_DIR" ]]; then
    rm -rf "$IMG_DIR" && echo "Removed: $IMG_DIR" >&2
  fi

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
# Preflight
# ---------------------------------------------------------------------------
echo "=== Gate 2B Preflight ==="

# IMG_DIR must be absent (fixture generator creates it exclusively via exist_ok=False)
if [[ -d "$IMG_DIR" ]]; then
  echo "FATAL: IMG_DIR already exists: $IMG_DIR" >&2
  echo "  Delete it before running: rm -rf $IMG_DIR" >&2
  exit 1
fi
# RESULTS_DIR is timestamp-unique; it cannot already exist
if [[ -d "$RESULTS_DIR" ]]; then
  echo "FATAL: RESULTS_DIR collision (timestamp collision?): $RESULTS_DIR" >&2; exit 1
fi
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

mkdir -p "$OUT_DIR"
> "$RESULTS_MD"
results_append "# Gate 2B Results — Rev 6"
results_append "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
results_append "RESULTS_DIR: $RESULTS_DIR"
results_append "PROJECT_REF: $PROJECT_REF"
results_append ""
echo "Preflight: all checks passed"

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
  "B-03|test-B-03.jpg|5000|4000|20000000|8500000|10000000|true|true"
  "B-01|test-B-01.jpg|2500|2000|5000000|4500000|5500000|true|true"
  "B-02|test-B-02.jpg|4000|2500|10000000|8500000|10000000|true|true"
  "B-04|test-B-04.jpg|5001|4000|20004000|10000|500000|false|false"
  "B-05|test-B-05.jpg|10000|10000|100000000|1000000|2500000|false|false"
  "B-06|test-B-06.webp|2500|2000|5000000|4500000|5500000|true|true"
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
  [[ "$ok" == "true" ]] || preflight_ok=false

  results_append "$label: $filename ${byte_size}B ${actual_w}x${actual_h} sha256=${sha}"
  echo "PREFLIGHT $label: ${byte_size}B ${actual_w}x${actual_h} sha256=${sha:0:12}... $( [[ "$ok" == "true" ]] && echo ✓ || echo FAIL)"
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
# deploy_function — deploys image-spike; parses + enforces bundle size.
# Uses --debug to obtain anchored 'script size:' field in output.
# Unparseable bundle size is a hard FAIL.
# ---------------------------------------------------------------------------
deploy_function() {
  local phase="$1"
  echo ""
  echo "=== Phase $phase: Deploy image-spike ==="
  DEPLOY_ATTEMPTED=true   # set BEFORE the CLI command runs

  local deploy_out
  deploy_out=$(supabase functions deploy image-spike \
    --project-ref "$PROJECT_REF" \
    --debug 2>&1)
  local deploy_exit=$?
  echo "$deploy_out"

  if [[ $deploy_exit -ne 0 ]]; then
    fail "Phase $phase: deployment failed (exit $deploy_exit)"
    return 1
  fi

  # Parse bundle size from --debug output.
  # Anchored to 'script size:' to avoid matching Docker layer or other MB values.
  local bundle_mb
  bundle_mb=$(printf '%s' "$deploy_out" \
    | grep -i 'script size:' \
    | grep -oE '[0-9]+(\.[0-9]+)?' \
    | head -1)

  # Fallback: some CLI versions may print 'bundle size:' instead
  if [[ -z "$bundle_mb" ]]; then
    bundle_mb=$(printf '%s' "$deploy_out" \
      | grep -i 'bundle size:' \
      | grep -oE '[0-9]+(\.[0-9]+)?' \
      | head -1)
  fi

  if [[ -z "$bundle_mb" ]]; then
    fail "Phase $phase: bundle size not found in --debug deploy output — FAIL"
    results_append "Phase $phase bundle_mb: UNPARSEABLE → FAIL"
    results_append "deploy_output_head: $(printf '%s' "$deploy_out" | head -40)"
    return 1
  fi

  python3 -c "import sys; sys.exit(0 if float('$bundle_mb') <= 20 else 1)" \
    || { fail "Phase $phase: bundle size ${bundle_mb} MB > 20 MB"; return 1; }
  echo "Phase $phase bundle: ${bundle_mb} MB ≤ 20 MB ✓"
  results_append "Phase $phase bundle_mb: $bundle_mb"
  return 0
}

# ---------------------------------------------------------------------------
# delete_confirmed — deletes image-spike and confirms via functions list.
# Captures list exit code separately to detect network/auth failures.
# Returns 1 on any failure (not confirmed absent = failure).
# ---------------------------------------------------------------------------
delete_confirmed() {
  local phase="$1"
  echo ""
  echo "Deleting image-spike (Phase $phase) ..."

  # Attempt deletion (non-zero exit is acceptable if function is already absent)
  supabase functions delete image-spike \
    --project-ref "$PROJECT_REF" 2>/dev/null || true
  sleep 3

  # Confirm absence — capture list output AND exit code independently
  local list_out list_exit
  list_out=$(supabase functions list --project-ref "$PROJECT_REF" 2>/dev/null)
  list_exit=$?

  if [[ $list_exit -ne 0 ]]; then
    fail "Phase $phase: 'supabase functions list' failed (exit $list_exit) — cannot confirm deletion"
    REMOTE_DELETE_FAILED=true
    return 1
  fi

  if printf '%s' "$list_out" | grep -q "image-spike"; then
    fail "Phase $phase: image-spike still listed after deletion"
    REMOTE_DELETE_FAILED=true
    return 1
  fi

  echo "Phase $phase deletion: confirmed ✓"
  return 0
}

# ---------------------------------------------------------------------------
# UUID validation helper (portable; no grep -P)
# ---------------------------------------------------------------------------
is_valid_uuid() {
  echo "$1" | grep -qiE \
    '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
}

# ---------------------------------------------------------------------------
# invoke_case — single curl call; all assertions; no double invocations.
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

# Telemetry capture gate — operator must complete BEFORE deletion
echo ""
echo "================================================================="
echo "B-03 TELEMETRY CAPTURE GATE (before Phase 0 deletion)"
echo "================================================================="
echo "B-03 run_id: ${B03_RUN_ID:-MISSING — check function logs}"
echo ""
echo "STEP 1 — Find LogEvent by run_id; extract execution_id:"
echo "  Open: https://supabase.com/dashboard/project/$PROJECT_REF/logs/edge-logs"
echo "  Filter: metadata.function_id = 'image-spike'"
echo "  Search log text for: $B03_RUN_ID"
echo "  Find entry: event='invoke', label='B-03' — note the execution_id in that entry."
echo ""
echo "STEP 2 — Find ShutdownEvent by execution_id; extract cpu_time_used:"
echo "  In the same Log Explorer, search for: <execution_id from Step 1>"
echo "  Find the ShutdownEvent for that execution_id."
echo "  Extract cpu_time_used (no _ms suffix in field name)."
echo ""
echo "STEP 3 — WorkerMemoryUsed:"
echo "  https://supabase.com/dashboard/project/$PROJECT_REF/functions"
echo "  Click image-spike → Metrics tab."
echo "  Identify B-03 worker by execution_id; record max WorkerMemoryUsed (MB)."
echo ""
echo "Type INCONCLUSIVE if any step fails or a value cannot be attributed."
echo "================================================================="

read -rp "B-03 execution_id (from LogEvent, or INCONCLUSIVE): " B03_EXEC_ID
read -rp "B-03 cpu_time_used (ms from ShutdownEvent for that execution_id, or INCONCLUSIVE): " B03_CPU_INPUT
read -rp "B-03 WorkerMemoryUsed max (MB, or INCONCLUSIVE): " B03_MEM_INPUT

results_append "B-03 run_id: ${B03_RUN_ID:-MISSING}"
results_append "B-03 execution_id: ${B03_EXEC_ID:-MISSING}"

if [[ "$B03_CPU_INPUT" == "INCONCLUSIVE" || "$B03_MEM_INPUT" == "INCONCLUSIVE" \
      || "$B03_EXEC_ID" == "INCONCLUSIVE" ]]; then
  fail "B-03 telemetry INCONCLUSIVE — cannot attribute cpu/memory to B-03 execution_id"
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

# Phase 0 deletion — must be confirmed before Phase 1 deploys
# Exit 1 on failure to prevent Phase 1 from running on undeleted deployment.
delete_confirmed "0" || exit 1

# ---------------------------------------------------------------------------
# Phase 1 — Functional matrix
# ---------------------------------------------------------------------------
results_append ""
results_append "## Phase 1 — Functional Matrix"

deploy_function "1" || { echo "Phase 1 deploy failed; proceeding to cleanup" >&2; exit 1; }

# B-01 (first request of Phase 1 deployment; timing criterion)
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

# Phase 1 deletion — record failure but continue to write verdict
delete_confirmed "1" || fail "Phase 1: deletion unconfirmed — manual cleanup required"

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
echo "Evidence dir: $RESULTS_DIR"
echo "================================================================="

[[ "$GATE2B_PASS" == "true" ]] || exit 1
```

---

## Section 11 — Pre-Deployment Checklist Summary

Before typing YES at the runner's approval gate:
1. `python3 gate2b-fixtures.py test-images/` — review output; verify all metadata families listed and all sizes in target bands
2. `bash gate2b-local-test.sh` — both B-01 and B-04 must pass; record serve exit code
3. `deno fmt --check supabase/functions/image-spike/index.ts`
4. `deno lint supabase/functions/image-spike/index.ts`
5. `deno check supabase/functions/image-spike/index.ts`
6. `gitleaks detect`
7. `shasum -a 256 tools/image-spike/magick.wasm supabase/functions/image-spike/index.ts`
8. Submit all artifacts + outputs to three parties; receive sign-off

---

## Section 12 — Results Format

`tools/image-spike/gate2b-evidence-<TIMESTAMP>/gate2b-results.md` — written progressively by the runner; never deleted by cleanup. Each run produces a unique evidence directory.

Key manual fields (B-03 telemetry) are written by the runner from operator input at the telemetry gate. The final verdict is written at the end of the run.

Results directory structure:
```
gate2b-evidence-<TIMESTAMP>/
  gate2b-results.md          ← progressive results log
  responses/
    B-03.json                ← Phase 0 response body
    B-03.headers             ← Phase 0 response headers
    B-03_output.webp         ← Phase 0 decoded output
    B-01.json, B-01.headers, B-01_output.webp
    B-02.json, B-02.headers, B-02_output.webp
    B-04.json, B-04.headers
    B-05.json, B-05.headers
    B-06.json, B-06.headers, B-06_output.webp
    B-07.json, B-07.headers
```

---

## Section 13 — Local Fixture-Generation Evidence

The following output was produced by running the Rev 6 `gate2b-fixtures.py` quality-search logic locally (Pillow 12.3, NumPy, Python 3.x, seed=42) prior to submission. This satisfies Codex's requirement that "Rev 6 should include corrected artifacts and local fixture-generation evidence showing every file lands inside its intended size band."

### 13.1 Calibration Probe — Confirming RNG Match

The probe first validates the RNG output matches Codex's measurements from Rev 5 (confirming seed=42 reproducibility):

```
B-01 (2500x2000 noise) at quality 65: 2,556,985 bytes (2.56 MB)  ← matches Codex 2.56 MB ✓
B-02 (4000x2500 noise) at quality 35: 3,153,056 bytes (3.15 MB)  ← matches Codex 3.15 MB ✓
B-06 (2500x2000 noise WebP) at quality 60: 2,816,476 bytes (2.82 MB)  ← matches Codex 2.82 MB ✓
```

### 13.2 Quality Search Results — Accepted Fixtures

All sizes measured without additional metadata overhead (~3–6 KB from EXIF/ICC/XMP). Metadata adds a constant offset that does not affect band membership for these targets.

```
Fixture  Format  Dimensions   Quality  Size (bytes)  Size (MB)  Band              Result
────────────────────────────────────────────────────────────────────────────────────────
B-01     JPEG    2500×2000    91       4,670,106     4.670 MB   [4.5 MB, 5.5 MB]  PASS ✓
B-02     JPEG    4000×2500    91       9,337,166     9.337 MB   [8.5 MB, 10 MB]   PASS ✓
B-03     JPEG    5000×4000    61       9,619,332     9.619 MB   [8.5 MB, 10 MB]   PASS ✓
B-06     WebP    2500×2000    95       4,798,862     4.799 MB   [4.5 MB, 5.5 MB]  PASS ✓
```

Note: B-06 uses the 4th noise image from the RNG sequence (after B-01/B-02/B-03 state consumed), consistent with how `_noise_image(seed=42)` is called per fixture.

### 13.3 Rejected Fixture Sizes

```
Fixture  Format  Dimensions    Color       Quality  Size (bytes)   Band              Result
───────────────────────────────────────────────────────────────────────────────────────────
B-04     JPEG    5001×4000     (30,60,90)  1        313,626        [10K, 500K]       PASS ✓
B-05     JPEG    10000×10000   (60,90,30)  1        1,563,126      [1M, 2.5M]        PASS ✓
B-07     JPEG    6000×4000     (90,30,60)  1        375,626        [10K, 500K]       PASS ✓
```

All three use `FIXTURE_COLORS` dict — not `hash(label)`.

### 13.4 COM Segment Byte Count Verification

```
comment = b'Gate2B JFIF comment marker v6'  # 29 bytes
COM segment: 0xFF 0xFE + length_field(0x001F=31) + 29-byte payload = 33 bytes total

Parse probe:
  COM marker found: declared 29 bytes, actual payload: b'Gate2B JFIF comment marker v6'
  COM payload length matches declared (29 bytes) ✓

Rev 5 bug: struct.pack('>H', 2 + 36) declared 38 but string was 29 bytes (7-byte overrun)
Rev 6 fix: struct.pack('>H', 2 + len(comment)) = struct.pack('>H', 31)
```

---

## Approval Request

All seven Rev 5 blockers are addressed and verified locally. No cloud operation has been performed.

Requested action: three-party sign-off (Bill + Claude + Codex) using the magic words:

**`APPROVED: Gate 2B Rev 6 — Hosted magick-wasm Spike`**
