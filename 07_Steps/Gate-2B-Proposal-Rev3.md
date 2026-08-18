# Gate 2B Proposal — Rev 3 — Hosted magick-wasm Spike on forkensics-dev

**Status:** DRAFT — awaiting three-party approval

**Governance gate:** Three-party approval (Bill + Claude + Codex) required before any cloud operation is executed. The magic words are `APPROVED: Gate 2B Rev 3 — Hosted magick-wasm Spike`.

**Authorized by:** Step 27 Rev 5 §3 Gate 2 Phase B.

**Supersedes:** Gate 2B Rev 2 (rejected — 6 execution blockers).

**Rev 3 changes from Rev 2:**
1. Telemetry: ShutdownEvent is worker-lifecycle, not per-request. All metrics correlated via `execution_id`. Authoritative CPU metric is `cpu_time_used` (no `_ms` suffix). Memory criterion uses maximum `WorkerMemoryUsed` from the Supabase dashboard for the correlated execution window. `cpu_time_used` > 200 ms → FAIL. Unattributable metrics → INCONCLUSIVE → treated as FAIL.
2. CPU criterion: 200 ms (conservative; accounts for documented conflict between Supabase general-limits page [2 s] and CPU-limits guide [200 ms]). Any 546 → immediate FAIL.
3. Runner is now a complete, executable bash script (`tools/image-spike/gate2b-run.sh`) with: `trap` installed before any deployment step; correct `-w '%{time_total}'` not `--time-total`; `--max-time`; verification of all response fields including dimensions, pixel_count, reason, metadata_clean, and SHA-256 format.
4. WASM lifecycle: copy from `tools/image-spike/magick.wasm` → `supabase/functions/_shared/magick.wasm`, verify hash after copy, delete after Gate 2B (Step B not authorized). Cannot assume persistence.
5. config.toml: restored by Python regex removal of `[functions.image-spike]` section only — not `git restore`, which is too broad.
6. Preflight step verifies each test image's actual filename, byte size, dimensions, pixel count, and SHA-256 before deployment. Response fields asserted against expected. Metadata cleanliness verified by a byte-level WebP RIFF chunk parser (`gate2b-verify-metadata.py`) that proves absence of EXIF, ICCP, and XMP chunks by FourCC inspection.

---

## Section 1 — Prerequisites

### 1.1 Gate 2A Full Closure (blocks execution, not approval)

Gate 2A has a partial pass (2026-08-13). All seven remaining evidence items must be completed before any cloud operation executes. Three-party approval of this Rev 3 document may precede Gate 2A closure; `gate2b-run.sh` may not be invoked until Gate 2A is fully closed.

### 1.2 Pre-Deployment Code Review (blocks deployment, not approval)

Before invoking `supabase functions deploy`, the following artifacts must be submitted to all three parties for explicit sign-off:

- `supabase/functions/image-spike/index.ts` (full source)
- `supabase/config.toml` diff (the `[functions.image-spike]` entry only)
- `tools/image-spike/gate2b-run.sh` (this approved runner, verbatim)
- `tools/image-spike/gate2b-verify-metadata.py` (the metadata parser)
- SHA-256 of `tools/image-spike/magick.wasm` and `supabase/functions/image-spike/index.ts`
- `supabase functions serve` local run: one accepted + one rejected case, responses shown
- `deno fmt --check`, `deno lint`, `deno check` — zero findings
- `gitleaks detect` — no findings

Sign-off does not require a new document; it may occur inline in the Gate 2B execution thread. It does require an explicit three-party acknowledgement before `supabase functions deploy` is run.

---

## Section 2 — Purpose

Gate 2A verified `magick-wasm` under local Deno 2.9.5. Gate 2B verifies the same pipeline operates within Supabase's hosted Edge Runtime resource envelope. Because the hosted resource limits differ from local, and because Step B (`upload-complete`) must not be built against limits that the hosted environment later rejects, Gate 2B must pass before Step B TypeScript begins.

---

## Section 3 — Authorized Cloud Operations

Exactly:
1. Deploy one disposable Edge Function: `supabase/functions/image-spike/index.ts`
2. Invoke via `gate2b-run.sh` with the test manifest (§5)
3. Read function logs from the Supabase dashboard to obtain `execution_id`, `cpu_time_used`, and `WorkerMemoryUsed` per execution
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

WASM is initialized at module level (outside the handler) so module-load cost is captured by the worker BootEvent, not by handler timing.

### 4.3 config.toml Entry

```toml
[functions.image-spike]
static_files = ["./functions/_shared/magick.wasm"]
```

Path is config-relative (from `supabase/`). Added and removed by `gate2b-run.sh`; not committed after Gate 2B.

### 4.4 Pipeline (Corrected Order)

1. Record `mem_before_rss = Deno.memoryUsage().rss` (diagnostic only)
2. Parse image file header; extract width and height without full decode
3. Compute `pixelCount = width × height`
4. If `pixelCount > 20_000_000` → return pre-decode rejection immediately; WASM decoder never invoked
5. Full raster decode via `ImageMagick.read(bytes, ...)`
6. **Remove all profiles, properties, and comments from the in-memory MagickImage** (EXIF, ICCP, XMP, comments) — before re-encoding
7. Re-encode to WebP
8. **Independently inspect the output WebP bytes** using the RIFF chunk parser (§10); assert `EXIF`, `ICCP`, and `XMP ` chunks are absent
9. Record `mem_after_rss = Deno.memoryUsage().rss` (diagnostic only)
10. Record wall-time ms (diagnostic only; not authoritative for CPU criterion)
11. Compute SHA-256 of the output bytes (hex string, 64 chars)
12. Return response (§4.5)

### 4.5 Response Contract

Accepted image:
```json
{
  "label": "B-03",
  "accepted": true,
  "pixel_count": 20000000,
  "width": 5000,
  "height": 4000,
  "input_size_bytes": 10485760,
  "output_size_bytes": 245120,
  "metadata_clean": true,
  "sha256": "a1b2c3d4...e5f6",
  "diagnostic": {
    "mem_before_rss_mb": 72.1,
    "mem_after_rss_mb": 110.4,
    "wall_time_ms": 3200
  }
}
```

Pre-decode rejection:
```json
{
  "label": "B-04",
  "accepted": false,
  "reason": "pre_decode_rejected",
  "pixel_count": 20004000,
  "width": 5001,
  "height": 4000,
  "diagnostic": { "wall_time_ms": 8 }
}
```

### 4.6 Request Contract

```
POST /functions/v1/image-spike?label=<label>
Content-Type: image/jpeg | image/webp
Authorization: Bearer <legacy-JWT-anon-key>
Body: raw image bytes
```

The response must include a `x-request-id` header (Supabase includes this automatically). The runner captures it for log correlation.

### 4.7 Authentication

Use the **legacy JWT-based anon key** from forkensics-dev API settings (Settings → API → `anon public`). This is a valid JWT bearer token. New-format publishable keys (prefixed `sb_publishable_`) are not valid bearer JWTs and must not be used.

The key is set as a shell environment variable at runtime only. It must not be written to any file, echoed to the terminal, or logged by any step of the runner.

---

## Section 5 — Test Manifest

| ID | Filename | MIME | Width | Height | Pixels | Expected accepted | Expected reason / metadata_clean |
|---|---|---|---|---|---|---|---|
| B-01 | test-B-01.jpg | image/jpeg | 2500 | 2000 | 5,000,000 | true | metadata_clean=true |
| B-02 | test-B-02.jpg | image/jpeg | 4000 | 2500 | 10,000,000 | true | metadata_clean=true |
| B-03 | test-B-03.jpg | image/jpeg | 5000 | 4000 | 20,000,000 | true | metadata_clean=true ← critical measurement |
| B-04 | test-B-04.jpg | image/jpeg | 5001 | 4000 | 20,004,000 | false | pre_decode_rejected |
| B-05 | test-B-05.jpg | image/jpeg | 10000 | 10000 | 100,000,000 | false | pre_decode_rejected |
| B-06 | test-B-06.webp | image/webp | 2500 | 2000 | 5,000,000 | true | metadata_clean=true |
| B-07 | test-B-07.jpg | image/jpeg | 6000 | 4000 | 24,000,000 | false | pre_decode_rejected |

Test images are generated locally before deployment. They are not committed to the repo.

---

## Section 6 — Pass Criteria

| # | Criterion | Threshold | Source |
|---|---|---|---|
| 1 | HTTP status — all invocations | 200 (never 546) | curl exit + status code |
| 2 | B-01, B-02, B-03, B-06: `accepted` | true | Response JSON |
| 3 | B-04, B-05, B-07: `reason` | `pre_decode_rejected` | Response JSON |
| 4 | B-01..B-07: `width`, `height`, `pixel_count` | Match manifest | Response JSON |
| 5 | B-03: `cpu_time_used` | < 200 ms | Supabase logs, correlated by `execution_id` |
| 6 | B-03: `WorkerMemoryUsed` (max in execution window) | ≤ 220 MB | Supabase dashboard |
| 7 | B-03: cold-start wall-clock | ≤ 15 s | curl `-w '%{time_total}'` |
| 8 | B-03: warm wall-clock | ≤ 30 s | curl `-w '%{time_total}'` |
| 9 | Bundle size | ≤ 20 MB | `supabase functions deploy` output |
| 10 | B-01, B-02, B-03, B-06: `metadata_clean` | true | Response JSON |
| 11 | B-01, B-02, B-03, B-06: RIFF chunk verification | EXIF, ICCP, XMP absent | `gate2b-verify-metadata.py` on output bytes |
| 12 | B-01, B-02, B-03, B-06: `sha256` format | 64-char lowercase hex | Response JSON |
| 13 | All metrics attributable to execution | Not INCONCLUSIVE | Log correlation |

---

## Section 7 — Failure and Inconclusive Definitions

**FAIL — any of:**
- Any invocation returns HTTP 546
- `accepted` or `reason` does not match manifest
- `width`, `height`, or `pixel_count` does not match manifest
- `cpu_time_used` ≥ 200 ms for B-03 execution
- `WorkerMemoryUsed` > 220 MB for B-03 execution window
- `metadata_clean` is false for any accepted image
- RIFF chunk parser finds EXIF, ICCP, or XMP in any output
- `sha256` is not 64-char lowercase hex
- Bundle size > 20 MB (abort before deployment)
- Any curl transport error (non-zero curl exit, timeout)

**INCONCLUSIVE — any of:**
- `cpu_time_used` not found in logs for the B-03 `execution_id`
- `WorkerMemoryUsed` not attributable to B-03 execution window
- ShutdownEvent `memory_used` not correlatable to B-03 (do not use if unattributable)
- `execution_id` not found in log entries for a given request

INCONCLUSIVE is treated as FAIL for the go/no-go decision.

---

## Section 8 — Telemetry Methodology

### 8.1 ShutdownEvent Limitations

A `ShutdownEvent` belongs to the worker (isolate) lifecycle, not to a single request. A single worker may process multiple requests before shutdown. Therefore, `ShutdownEvent.memory_used` and related fields cannot be attributed to a specific request without additional correlation. They must not be used as the sole metric source.

### 8.2 Execution ID Correlation

Supabase Edge Function logs include an `execution_id` (or equivalent request-scoped identifier) in the log entry for each invocation. The runner captures `x-request-id` from each curl response header and records it alongside the label. After execution, locate the log entry with the matching `x-request-id` or label (the `?label=` query param is visible in logs) to find the associated `execution_id`.

Use that `execution_id` to:
- Find the `cpu_time_used` metric for that specific invocation
- Bound the execution window timestamp range for `WorkerMemoryUsed` dashboard queries

### 8.3 cpu_time_used

The authoritative field is `cpu_time_used` (no `_ms` suffix). This appears in the Edge Function log entry (not the ShutdownEvent) for the specific invocation. Record the raw value and units as displayed in Supabase logs.

Pass threshold: < 200 ms. This is the conservative value from the Supabase CPU limits documentation. If Supabase support confirms that the forkensics-dev project plan permits 2 seconds, that may be substituted subject to three-party agreement — but the default is 200 ms.

### 8.4 WorkerMemoryUsed (Peak Memory)

From the Supabase dashboard Monitoring → Edge Functions view, filter by `image-spike` and the execution timestamp window for B-03. Record the **maximum** `WorkerMemoryUsed` value observed during that window. This is the authoritative peak memory measurement.

`Deno.memoryUsage().rss` (in-handler before/after delta) is diagnostic only and may miss intermediate allocations. It is recorded but not used for pass/fail.

### 8.5 INCONCLUSIVE Handling

If a metric cannot be obtained and attributed to the specific execution: record `INCONCLUSIVE` for that criterion, treat it as FAIL for the gate verdict. Do not substitute ShutdownEvent aggregates.

---

## Section 9 — WASM Lifecycle

The WASM binary currently lives at `tools/image-spike/magick.wasm`. It must be copied to `supabase/functions/_shared/magick.wasm` for deployment, and removed after Gate 2B regardless of outcome. Step B is not authorized; the binary's presence in `_shared/` must not be assumed to persist.

The runner manages this with state flags and the cleanup trap (§11).

Copy and verification:
```bash
cp "$WASM_SRC" "$WASM_DST"
WASM_SRC_HASH=$(shasum -a 256 "$WASM_SRC" | awk '{print $1}')
WASM_DST_HASH=$(shasum -a 256 "$WASM_DST" | awk '{print $1}')
if [[ "$WASM_SRC_HASH" != "$WASM_DST_HASH" ]]; then
  echo "FATAL: WASM copy hash mismatch — aborting"
  exit 1
fi
echo "WASM_HASH=$WASM_SRC_HASH"
WASM_COPIED=true
```

---

## Section 10 — WebP Metadata Verification

Save as `tools/image-spike/gate2b-verify-metadata.py`.

```python
#!/usr/bin/env python3
"""
Byte-level WebP RIFF chunk parser for Gate 2B metadata verification.
Exits 0 if no metadata chunks found; exits 1 with details if any are present.
Usage: python3 gate2b-verify-metadata.py <file.webp>
"""
import sys
import struct

METADATA_FOURCCS = {
    b'EXIF': 'EXIF (contains Exif, GPS, and potentially IPTC-NAA)',
    b'ICCP': 'ICCP (ICC color profile)',
    b'XMP ': 'XMP  (XMP metadata, including Dublin Core, IPTC-IIM)',
}

def parse_webp_riff(data: bytes) -> list[str]:
    """
    Parse WebP RIFF structure and return a list of metadata chunk descriptions found.
    Raises ValueError if the file is not a valid WebP.
    """
    if len(data) < 12:
        raise ValueError("File too short to be a valid WebP")
    if data[0:4] != b'RIFF':
        raise ValueError(f"Not a RIFF file (got {data[0:4]!r})")
    if data[8:12] != b'WEBP':
        raise ValueError(f"Not a WebP file (RIFF type: {data[8:12]!r})")

    found = []
    pos = 12  # Start after RIFF header (4) + size (4) + WEBP marker (4)
    file_size = len(data)

    while pos + 8 <= file_size:
        fourcc = data[pos:pos + 4]
        if len(fourcc) < 4:
            break
        chunk_size = struct.unpack_from('<I', data, pos + 4)[0]
        data_start = pos + 8
        data_end = data_start + chunk_size

        if fourcc in METADATA_FOURCCS:
            found.append(
                f"  Chunk at offset {pos}: {fourcc.decode('ascii', errors='replace')!r} "
                f"({chunk_size} bytes) — {METADATA_FOURCCS[fourcc]}"
            )

        # Advance past this chunk; chunks are word-aligned (pad byte if odd size)
        pos = data_end + (chunk_size % 2)

    return found


def main():
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <file.webp>", file=sys.stderr)
        sys.exit(2)

    path = sys.argv[1]
    try:
        with open(path, 'rb') as f:
            data = f.read()
    except OSError as e:
        print(f"ERROR: Cannot read {path}: {e}", file=sys.stderr)
        sys.exit(2)

    try:
        found = parse_webp_riff(data)
    except ValueError as e:
        print(f"ERROR: {path}: {e}", file=sys.stderr)
        sys.exit(2)

    if found:
        print(f"METADATA FOUND in {path} — Gate 2B criterion FAIL:")
        for entry in found:
            print(entry)
        sys.exit(1)
    else:
        print(f"OK: {path} — no EXIF, ICCP, or XMP chunks found in RIFF structure")
        sys.exit(0)


if __name__ == '__main__':
    main()
```

**Scope note:** GPS and IPTC data in WebP are embedded within the EXIF chunk, not stored as separate RIFF chunks. Absence of the EXIF chunk proves absence of all EXIF-embedded GPS and IPTC-NAA data. XMP can additionally carry IPTC-IIM records; absence of the XMP chunk covers that path. This parser covers all metadata pathways that ImageMagick's WebP encoder uses.

---

## Section 11 — Gate 2B Runner

Save as `tools/image-spike/gate2b-run.sh`. This is the complete, executable runner.

```bash
#!/usr/bin/env bash
# Gate 2B test runner — gate2b-run.sh
# DISPOSABLE — Gate 2B only. Execute only after three-party approval of Rev 3.
# Requires: PROJECT_REF and ANON_KEY set as environment variables.
# Usage: PROJECT_REF=xxx ANON_KEY=yyy bash tools/image-spike/gate2b-run.sh
#
# Security: ANON_KEY is never written to disk, echoed, or logged by this script.
# The key must be set as a shell variable before invocation.

set -uo pipefail
# Note: -e intentionally omitted. The EXIT trap handles cleanup on all exit paths.

# ---------------------------------------------------------------------------
# Validate environment variables (fail before any side effects)
# ---------------------------------------------------------------------------
if [[ -z "${PROJECT_REF:-}" ]]; then
  echo "FATAL: PROJECT_REF is not set" >&2; exit 1
fi
if [[ -z "${ANON_KEY:-}" ]]; then
  echo "FATAL: ANON_KEY is not set" >&2; exit 1
fi

# ---------------------------------------------------------------------------
# Paths (all absolute; derived from script location)
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WASM_SRC="$REPO_ROOT/tools/image-spike/magick.wasm"
WASM_DST="$REPO_ROOT/supabase/functions/_shared/magick.wasm"
CONFIG="$REPO_ROOT/supabase/config.toml"
SPIKE_DIR="$REPO_ROOT/supabase/functions/image-spike"
IMG_DIR="$REPO_ROOT/tools/image-spike/test-images"
OUT_DIR="$REPO_ROOT/tools/image-spike/gate2b-responses"
VERIFY_PY="$REPO_ROOT/tools/image-spike/gate2b-verify-metadata.py"
RESULTS="$REPO_ROOT/tools/image-spike/gate2b-results.md"
FUNC_URL="https://${PROJECT_REF}.supabase.co/functions/v1/image-spike"

# ---------------------------------------------------------------------------
# State flags (used by cleanup)
# ---------------------------------------------------------------------------
DEPLOYED=false
WASM_COPIED=false
CONFIG_PATCHED=false
GATE2B_PASS=true
FAIL_REASONS=()

# ---------------------------------------------------------------------------
# Cleanup — runs unconditionally on EXIT, INT, TERM
# Captures evidence first; deletes remote function second; removes local files last.
# ---------------------------------------------------------------------------
cleanup() {
  local trigger="${1:-EXIT}"
  echo ""
  echo "================================================================="
  echo "Gate 2B Cleanup (trigger: $trigger)"
  echo "================================================================="

  # Step 1: Capture logs before remote deletion (must be done manually)
  if [[ "$DEPLOYED" == "true" ]]; then
    echo ""
    echo "ACTION REQUIRED: Capture Supabase logs before deletion."
    echo "  1. Open: https://supabase.com/dashboard/project/$PROJECT_REF/functions/image-spike/logs"
    echo "  2. Save all entries for image-spike to: $OUT_DIR/platform-logs.txt"
    echo "     Key fields: execution_id, cpu_time_used, WorkerMemoryUsed, timestamp"
    echo "  3. Screenshot the Monitoring → Edge Functions dashboard for WorkerMemoryUsed"
    read -rp "  Press Enter when logs are saved... "

    # Remote deletion
    echo "Deleting remote function image-spike ..."
    if supabase functions delete image-spike --project-ref "$PROJECT_REF"; then
      echo "Remote deletion: CLI success"
    else
      echo "WARNING: CLI deletion failed. Delete manually via:"
      echo "  https://supabase.com/dashboard/project/$PROJECT_REF/functions"
      read -rp "  Press Enter after manual deletion is confirmed... "
    fi

    # Verify deletion
    sleep 3
    if supabase functions list --project-ref "$PROJECT_REF" 2>/dev/null | grep -q "image-spike"; then
      echo "WARNING: image-spike still appears in function list — manual deletion required"
    else
      echo "Remote deletion: verified (image-spike not found in list)"
    fi
  fi

  # Step 2: Restore config.toml — remove ONLY [functions.image-spike] section
  if [[ "$CONFIG_PATCHED" == "true" ]]; then
    python3 - "$CONFIG" <<'PYEOF'
import re, sys

config_path = sys.argv[1]
with open(config_path, 'r') as f:
    content = f.read()

# Remove [functions.image-spike] and any key = value lines that follow it,
# stopping at the next [section] header or end of file.
cleaned = re.sub(
    r'\n\[functions\.image-spike\]\n(?:(?!\[)[^\n]*\n)*',
    '\n',
    content,
)

with open(config_path, 'w') as f:
    f.write(cleaned)

print(f'config.toml: [functions.image-spike] section removed')
PYEOF
  fi

  # Step 3: Remove copied WASM (Step B not authorized; cannot persist)
  if [[ "$WASM_COPIED" == "true" ]] && [[ -f "$WASM_DST" ]]; then
    rm "$WASM_DST"
    echo "Removed: $WASM_DST"
  fi

  # Step 4: Remove generated test images and raw response files
  rm -rf "$IMG_DIR"
  echo "Removed: $IMG_DIR"
  rm -rf "$OUT_DIR"
  echo "Removed: $OUT_DIR"

  # Step 5: Remind about spike function directory
  if [[ -d "$SPIKE_DIR" ]]; then
    echo ""
    echo "NOTE: $SPIKE_DIR still exists."
    echo "  It must be removed before committing: rm -rf $SPIKE_DIR"
  fi

  echo ""
  echo "Cleanup complete."
  echo "================================================================="
}

trap 'cleanup EXIT' EXIT
trap 'GATE2B_PASS=false; FAIL_REASONS+=("INTERRUPTED by INT"); cleanup INT; exit 130' INT
trap 'GATE2B_PASS=false; FAIL_REASONS+=("INTERRUPTED by TERM"); cleanup TERM; exit 143' TERM

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------
echo "=== Gate 2B Preflight ==="

for tool in supabase curl jq python3 shasum; do
  if ! command -v "$tool" &>/dev/null; then
    echo "FATAL: required tool not found: $tool" >&2; exit 1
  fi
done

if [[ ! -f "$WASM_SRC" ]]; then
  echo "FATAL: WASM source not found: $WASM_SRC" >&2; exit 1
fi
if [[ ! -f "$VERIFY_PY" ]]; then
  echo "FATAL: metadata verifier not found: $VERIFY_PY" >&2; exit 1
fi
if [[ ! -d "$SPIKE_DIR" ]]; then
  echo "FATAL: spike function directory not found: $SPIKE_DIR" >&2; exit 1
fi
if [[ -f "$WASM_DST" ]]; then
  echo "FATAL: $WASM_DST already exists — Gate 2B requires a clean copy step" >&2; exit 1
fi

mkdir -p "$IMG_DIR" "$OUT_DIR"

echo "All preflight checks passed."

# ---------------------------------------------------------------------------
# Generate test images
# ---------------------------------------------------------------------------
echo ""
echo "=== Generating test images ==="

generate_jpeg() {
  local label="$1" width="$2" height="$3" path="$4"
  # Use ImageMagick (system magick) to generate a synthetic JPEG with embedded EXIF
  # so that the spike function's metadata removal is exercised on real metadata.
  if command -v magick &>/dev/null; then
    magick -size "${width}x${height}" gradient:blue-red \
      -set "EXIF:Artist" "Gate2B-test" \
      -set "EXIF:Copyright" "Gate2B-test" \
      -quality 85 "$path"
  else
    # Fallback: Python with Pillow
    python3 -c "
from PIL import Image
import piexif, struct
img = Image.new('RGB', ($width, $height), color=(100, 149, 237))
exif_dict = {'0th': {piexif.ImageIFD.Artist: b'Gate2B-test'}, 'Exif': {}, '1st': {}}
exif_bytes = piexif.dump(exif_dict)
img.save('$path', 'JPEG', quality=85, exif=exif_bytes)
" 2>/dev/null || python3 -c "
from PIL import Image
img = Image.new('RGB', ($width, $height), color=(100, 149, 237))
img.save('$path', 'JPEG', quality=85)
"
  fi
}

generate_webp() {
  local label="$1" width="$2" height="$3" path="$4"
  if command -v magick &>/dev/null; then
    magick -size "${width}x${height}" gradient:green-yellow \
      -set "EXIF:Artist" "Gate2B-test" \
      "$path"
  else
    python3 -c "
from PIL import Image
img = Image.new('RGB', ($width, $height), color=(60, 179, 113))
img.save('$path', 'WebP', quality=85)
"
  fi
}

generate_jpeg "B-01" 2500 2000 "$IMG_DIR/test-B-01.jpg"
generate_jpeg "B-02" 4000 2500 "$IMG_DIR/test-B-02.jpg"
generate_jpeg "B-03" 5000 4000 "$IMG_DIR/test-B-03.jpg"
generate_jpeg "B-04" 5001 4000 "$IMG_DIR/test-B-04.jpg"
generate_jpeg "B-05" 10000 10000 "$IMG_DIR/test-B-05.jpg"
generate_webp "B-06" 2500 2000 "$IMG_DIR/test-B-06.webp"
generate_jpeg "B-07" 6000 4000 "$IMG_DIR/test-B-07.jpg"

echo "Test images generated."

# ---------------------------------------------------------------------------
# Preflight: verify each test image's dimensions, byte size, pixel count, SHA-256
# ---------------------------------------------------------------------------
echo ""
echo "=== Verifying test image preflight ==="

# Manifest: label|filename|mime|exp_w|exp_h|exp_pixels|exp_accepted|exp_reason
declare -a MANIFEST=(
  "B-01|test-B-01.jpg|image/jpeg|2500|2000|5000000|true|"
  "B-02|test-B-02.jpg|image/jpeg|4000|2500|10000000|true|"
  "B-03|test-B-03.jpg|image/jpeg|5000|4000|20000000|true|"
  "B-04|test-B-04.jpg|image/jpeg|5001|4000|20004000|false|pre_decode_rejected"
  "B-05|test-B-05.jpg|image/jpeg|10000|10000|100000000|false|pre_decode_rejected"
  "B-06|test-B-06.webp|image/webp|2500|2000|5000000|true|"
  "B-07|test-B-07.jpg|image/jpeg|6000|4000|24000000|false|pre_decode_rejected"
)

for entry in "${MANIFEST[@]}"; do
  IFS="|" read -r label filename mime exp_w exp_h exp_pixels exp_accepted exp_reason <<< "$entry"
  img="$IMG_DIR/$filename"

  if [[ ! -f "$img" ]]; then
    echo "PREFLIGHT FAIL: $img not found" >&2; exit 1
  fi

  byte_size=$(wc -c < "$img" | tr -d ' ')
  sha=$(shasum -a 256 "$img" | awk '{print $1}')

  # Verify dimensions using Python (no dependency on system ImageMagick for verification)
  dims=$(python3 -c "
from PIL import Image
with Image.open('$img') as im:
    print(f'{im.width} {im.height}')
" 2>/dev/null) || { echo "PREFLIGHT FAIL: cannot read dimensions of $img (is Pillow installed?)" >&2; exit 1; }

  actual_w=$(echo "$dims" | awk '{print $1}')
  actual_h=$(echo "$dims" | awk '{print $2}')
  actual_pixels=$((actual_w * actual_h))

  if [[ "$actual_w" != "$exp_w" || "$actual_h" != "$exp_h" ]]; then
    echo "PREFLIGHT FAIL: $label dimensions ${actual_w}x${actual_h} != expected ${exp_w}x${exp_h}" >&2; exit 1
  fi
  if [[ "$actual_pixels" != "$exp_pixels" ]]; then
    echo "PREFLIGHT FAIL: $label pixel_count $actual_pixels != expected $exp_pixels" >&2; exit 1
  fi

  echo "PREFLIGHT OK: $label ($filename, ${byte_size} bytes, ${actual_w}x${actual_h}, sha256=${sha})"
done

echo "All test image preflight checks passed."

# ---------------------------------------------------------------------------
# WASM: copy and verify hash
# ---------------------------------------------------------------------------
echo ""
echo "=== Copying WASM ==="

cp "$WASM_SRC" "$WASM_DST"
SRC_HASH=$(shasum -a 256 "$WASM_SRC" | awk '{print $1}')
DST_HASH=$(shasum -a 256 "$WASM_DST" | awk '{print $1}')
if [[ "$SRC_HASH" != "$DST_HASH" ]]; then
  echo "FATAL: WASM copy hash mismatch (src=$SRC_HASH dst=$DST_HASH)" >&2; exit 1
fi
WASM_COPIED=true
echo "WASM copied and verified: sha256=$SRC_HASH"

# ---------------------------------------------------------------------------
# config.toml: add [functions.image-spike]
# ---------------------------------------------------------------------------
echo ""
echo "=== Patching config.toml ==="

# Verify section does not already exist
if grep -q '\[functions\.image-spike\]' "$CONFIG"; then
  echo "FATAL: [functions.image-spike] already present in config.toml" >&2; exit 1
fi

printf '\n[functions.image-spike]\nstatic_files = ["./functions/_shared/magick.wasm"]\n' >> "$CONFIG"
CONFIG_PATCHED=true
echo "config.toml patched: [functions.image-spike] added"

# ---------------------------------------------------------------------------
# Pre-deployment review gate
# ---------------------------------------------------------------------------
echo ""
echo "=== Pre-deployment review ==="
echo "Static checks must pass before deployment:"

STATIC_OK=true
deno fmt --check "$SPIKE_DIR/index.ts" || { echo "FAIL: deno fmt"; STATIC_OK=false; }
deno lint "$SPIKE_DIR/index.ts" || { echo "FAIL: deno lint"; STATIC_OK=false; }
deno check "$SPIKE_DIR/index.ts" || { echo "FAIL: deno check"; STATIC_OK=false; }
gitleaks detect --source "$REPO_ROOT" --config "$REPO_ROOT/.gitleaks.toml" 2>/dev/null || \
  { echo "FAIL: gitleaks"; STATIC_OK=false; }

if [[ "$STATIC_OK" == "false" ]]; then
  echo "FATAL: Static checks failed — deployment aborted" >&2
  GATE2B_PASS=false; FAIL_REASONS+=("Static checks failed"); exit 1
fi

echo "Static checks passed."
echo ""
echo "Record the following in gate2b-results.md before proceeding:"
echo "  WASM sha256=$SRC_HASH"
INDEX_HASH=$(shasum -a 256 "$SPIKE_DIR/index.ts" | awk '{print $1}')
echo "  index.ts sha256=$INDEX_HASH"
echo ""
read -rp "Confirm three-party pre-deployment approval has been recorded [y/N]: " confirm
if [[ "${confirm,,}" != "y" ]]; then
  echo "Deployment aborted by operator." >&2
  GATE2B_PASS=false; FAIL_REASONS+=("Pre-deployment approval not confirmed"); exit 1
fi

# ---------------------------------------------------------------------------
# Deploy
# ---------------------------------------------------------------------------
echo ""
echo "=== Deploying image-spike ==="

deploy_output=$(supabase functions deploy image-spike \
  --project-ref "$PROJECT_REF" \
  --use-docker 2>&1) || {
  echo "FATAL: Deployment failed" >&2
  echo "$deploy_output" >&2
  GATE2B_PASS=false; FAIL_REASONS+=("Deployment failed"); exit 1
}

echo "$deploy_output"

# Check bundle size from deploy output
bundle_line=$(echo "$deploy_output" | grep -i 'bundle\|size' | tail -1 || true)
echo "Bundle size line: $bundle_line"
DEPLOYED=true

# ---------------------------------------------------------------------------
# Cold-start measurement (first invocation — before test matrix)
# ---------------------------------------------------------------------------
echo ""
echo "=== Cold-start measurement ==="
sleep 2  # Allow function to register

cold_time=$(curl -s -o "$OUT_DIR/cold.json" \
  -w '%{time_total}' \
  --max-time 30 \
  -X POST "${FUNC_URL}?label=cold" \
  -H "Authorization: Bearer $ANON_KEY" \
  -H "Content-Type: image/jpeg" \
  --data-binary "@$IMG_DIR/test-B-01.jpg")
cold_http=$(curl -s -o /dev/null -w '%{http_code}' \
  -X POST "${FUNC_URL}?label=cold-verify" \
  -H "Authorization: Bearer $ANON_KEY" \
  -H "Content-Type: image/jpeg" \
  --data-binary "@$IMG_DIR/test-B-01.jpg" \
  --max-time 30 || echo "000")

echo "Cold-start wall-clock: ${cold_time}s"
if [[ "$cold_http" == "546" ]]; then
  echo "HARD FAILURE: HTTP 546 on cold-start" >&2
  GATE2B_PASS=false; FAIL_REASONS+=("HTTP 546 on cold-start"); exit 1
fi

# Warm request (immediately after)
warm_time=$(curl -s -o "$OUT_DIR/warm.json" \
  -w '%{time_total}' \
  --max-time 60 \
  -X POST "${FUNC_URL}?label=warm" \
  -H "Authorization: Bearer $ANON_KEY" \
  -H "Content-Type: image/jpeg" \
  --data-binary "@$IMG_DIR/test-B-01.jpg")
echo "Warm wall-clock: ${warm_time}s"

# ---------------------------------------------------------------------------
# Test matrix
# ---------------------------------------------------------------------------
echo ""
echo "=== Running test matrix ==="

for entry in "${MANIFEST[@]}"; do
  IFS="|" read -r label filename mime exp_w exp_h exp_pixels exp_accepted exp_reason <<< "$entry"
  img="$IMG_DIR/$filename"
  out="$OUT_DIR/${label}.json"
  hdr="$OUT_DIR/${label}.headers"

  echo ""
  echo "--- $label ($filename, $mime) ---"

  # Execute request; capture headers and body separately
  http_status=$(curl -s \
    -o "$out" \
    -D "$hdr" \
    -w '%{http_code}' \
    --max-time 120 \
    -X POST "${FUNC_URL}?label=${label}" \
    -H "Authorization: Bearer $ANON_KEY" \
    -H "Content-Type: $mime" \
    --data-binary "@$img") || {
    echo "FAILURE: $label — curl transport error (exit $?)"
    GATE2B_PASS=false; FAIL_REASONS+=("$label: curl transport error"); continue
  }

  wall_time=$(curl -s -o /dev/null \
    -w '%{time_total}' \
    --max-time 120 \
    -X POST "${FUNC_URL}?label=${label}-timing" \
    -H "Authorization: Bearer $ANON_KEY" \
    -H "Content-Type: $mime" \
    --data-binary "@$img" 2>/dev/null || echo "ERR")

  echo "  HTTP status: $http_status  wall_time: ${wall_time}s"

  # Extract x-request-id for log correlation
  req_id=$(grep -i 'x-request-id' "$hdr" 2>/dev/null | awk '{print $2}' | tr -d '\r' || echo "")
  echo "  x-request-id: ${req_id:-<not found>}"

  # Hard failure on 546
  if [[ "$http_status" == "546" ]]; then
    echo "  HARD FAILURE: HTTP 546 — resource limit exceeded"
    GATE2B_PASS=false; FAIL_REASONS+=("$label: HTTP 546")
    exit 1
  fi

  if [[ "$http_status" != "200" ]]; then
    echo "  FAILURE: unexpected HTTP status $http_status"
    GATE2B_PASS=false; FAIL_REASONS+=("$label: HTTP $http_status")
    continue
  fi

  # Parse response fields
  resp_accepted=$(jq -r '.accepted // "MISSING"' "$out")
  resp_reason=$(jq -r '.reason // ""' "$out")
  resp_w=$(jq -r '.width // 0' "$out")
  resp_h=$(jq -r '.height // 0' "$out")
  resp_pixels=$(jq -r '.pixel_count // 0' "$out")
  resp_metadata_clean=$(jq -r '.metadata_clean // "MISSING"' "$out")
  resp_sha256=$(jq -r '.sha256 // ""' "$out")

  # Verify accepted/rejected
  if [[ "$resp_accepted" != "$exp_accepted" ]]; then
    echo "  FAILURE: accepted=$resp_accepted expected=$exp_accepted"
    GATE2B_PASS=false; FAIL_REASONS+=("$label: accepted mismatch")
  else
    echo "  accepted=$resp_accepted ✓"
  fi

  # Verify rejection reason
  if [[ "$exp_accepted" == "false" ]]; then
    if [[ "$resp_reason" != "$exp_reason" ]]; then
      echo "  FAILURE: reason='$resp_reason' expected='$exp_reason'"
      GATE2B_PASS=false; FAIL_REASONS+=("$label: reason mismatch")
    else
      echo "  reason=$resp_reason ✓"
    fi
  fi

  # Verify dimensions
  if [[ "$resp_w" != "$exp_w" || "$resp_h" != "$exp_h" ]]; then
    echo "  FAILURE: dimensions ${resp_w}x${resp_h} expected ${exp_w}x${exp_h}"
    GATE2B_PASS=false; FAIL_REASONS+=("$label: dimensions mismatch")
  else
    echo "  dimensions=${resp_w}x${resp_h} ✓"
  fi

  # Verify pixel_count
  if [[ "$resp_pixels" != "$exp_pixels" ]]; then
    echo "  FAILURE: pixel_count=$resp_pixels expected=$exp_pixels"
    GATE2B_PASS=false; FAIL_REASONS+=("$label: pixel_count mismatch")
  else
    echo "  pixel_count=$resp_pixels ✓"
  fi

  # For accepted images: verify metadata_clean and sha256 format
  if [[ "$exp_accepted" == "true" ]]; then
    if [[ "$resp_metadata_clean" != "true" ]]; then
      echo "  FAILURE: metadata_clean=$resp_metadata_clean expected=true"
      GATE2B_PASS=false; FAIL_REASONS+=("$label: metadata_clean false")
    else
      echo "  metadata_clean=true ✓"
    fi

    if ! echo "$resp_sha256" | grep -qE '^[0-9a-f]{64}$'; then
      echo "  FAILURE: sha256 format invalid: '$resp_sha256'"
      GATE2B_PASS=false; FAIL_REASONS+=("$label: sha256 format invalid")
    else
      echo "  sha256=${resp_sha256:0:16}... ✓"
    fi

    # Byte-level WebP metadata verification
    # Extract output bytes from response (output_bytes field as base64, or re-fetch)
    # The spike function must return output bytes for verification; if it returns only sha256,
    # this step verifies the sha256 matches a locally re-processed copy.
    # If the function returns a base64-encoded output_bytes field:
    output_b64=$(jq -r '.output_bytes // ""' "$out")
    if [[ -n "$output_b64" && "$output_b64" != "null" ]]; then
      out_webp="$OUT_DIR/${label}.webp"
      echo "$output_b64" | base64 -d > "$out_webp"
      if python3 "$VERIFY_PY" "$out_webp"; then
        echo "  RIFF chunk verification ✓"
      else
        echo "  FAILURE: RIFF chunk verification found metadata"
        GATE2B_PASS=false; FAIL_REASONS+=("$label: metadata in output WebP")
      fi
    else
      echo "  NOTE: output_bytes not in response — RIFF verification via sha256 only"
      echo "  INCONCLUSIVE: cannot perform byte-level RIFF verification without output bytes"
      GATE2B_PASS=false; FAIL_REASONS+=("$label: INCONCLUSIVE — output bytes not returned for RIFF check")
    fi
  fi

  echo "  x-request-id=$req_id (record this for log correlation)"
done

# ---------------------------------------------------------------------------
# Write preliminary results
# ---------------------------------------------------------------------------
echo ""
echo "=== Writing preliminary results ==="

{
  echo "# Gate 2B Results"
  echo ""
  echo "**Date:** $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "**Runner verdict (automated):** $([ "$GATE2B_PASS" == "true" ] && echo "PASS (pending telemetry)" || echo "FAIL")"
  echo ""
  if [[ ${#FAIL_REASONS[@]} -gt 0 ]]; then
    echo "**Automated failures:**"
    for r in "${FAIL_REASONS[@]}"; do echo "- $r"; done
    echo ""
  fi
  echo "## Timing"
  echo "- Cold wall-clock: ${cold_time}s"
  echo "- Warm wall-clock: ${warm_time}s"
  echo ""
  echo "## Telemetry (complete manually from Supabase logs)"
  echo "- B-03 execution_id: <from logs — correlate by label=B-03 or x-request-id>"
  echo "- B-03 cpu_time_used: <from logs — must be < 200 ms>"
  echo "- B-03 WorkerMemoryUsed (max in execution window): <from dashboard — must be ≤ 220 MB>"
  echo "- If unavailable: INCONCLUSIVE → FAIL"
  echo ""
  echo "## Test Case Responses"
  for entry in "${MANIFEST[@]}"; do
    IFS="|" read -r label filename mime exp_w exp_h exp_pixels exp_accepted exp_reason <<< "$entry"
    out="$OUT_DIR/${label}.json"
    echo "### $label"
    if [[ -f "$out" ]]; then
      cat "$out"
    else
      echo "(no response captured)"
    fi
    echo ""
  done
} > "$RESULTS"

echo "Preliminary results written to: $RESULTS"
echo "(Telemetry fields require manual completion from Supabase dashboard)"

echo ""
if [[ "$GATE2B_PASS" == "true" ]]; then
  echo "Automated checks: PASS (pending telemetry verification)"
else
  echo "Automated checks: FAIL"
  for r in "${FAIL_REASONS[@]}"; do echo "  - $r"; done
fi
```

**Note on output_bytes:** The spike function's response contract (§4.5) must include a `output_bytes` field (base64-encoded output WebP) for the byte-level RIFF verification step to execute. If adding base64 output to the response is impractical due to response size, the function may instead write the output to a temporary path and return the path; or the RIFF check may be performed inside the function (see §4.4, step 8) and `metadata_clean` verified solely against that in-function check. This design choice must be confirmed in the pre-deployment code review (§1.2).

---

## Section 12 — Pre-Deployment Checklist Summary

Run in order before invoking `gate2b-run.sh`:

1. `deno fmt --check supabase/functions/image-spike/index.ts`
2. `deno lint supabase/functions/image-spike/index.ts`
3. `deno check supabase/functions/image-spike/index.ts`
4. `gitleaks detect`
5. Local Edge Runtime: `supabase functions serve image-spike` → run at least one accepted and one rejected test case → confirm responses match expected shape
6. Compute hashes: `shasum -a 256 tools/image-spike/magick.wasm supabase/functions/image-spike/index.ts`
7. Submit all artifacts + results to three parties
8. Receive explicit three-party sign-off before `gate2b-run.sh` is executed

---

## Section 13 — Cold-Start Results Format

`gate2b-results.md` must include:

```
## Cold-Start Measurements
WASM initialization scope: module-level (cost is in worker BootEvent, not handler timing)
Cold wall-clock (curl %{time_total}): <N.NNN> s — threshold ≤ 15 s
Warm wall-clock (curl %{time_total}): <N.NNN> s — threshold ≤ 30 s
BootEvent timestamp (from Supabase logs): <ISO8601>
First request completion timestamp (from logs): <ISO8601>
Worker boot duration (derived): <N> ms
```

---

## Section 14 — Step B Gate

If Gate 2B passes (all automated + telemetry criteria met):

- The confirmed pixel limit is the Gate 2B hosted limit (≤ Phase A limit; if they differ, hosted governs)
- A separate Step B proposal with its own three-party approval is required before `upload-complete` TypeScript begins
- The WASM binary must be re-copied to `supabase/functions/_shared/magick.wasm` under Step B's authorized scope — it is not assumed to persist from Gate 2B cleanup

---

## Section 15 — Security Constraints

- `ANON_KEY` is a runtime shell variable only; never written to any file, never echoed, never logged
- `image-spike` function is stateless; writes no data to the database or any storage bucket
- Three-party governance: Bill + Claude + Codex must all approve before `gate2b-run.sh` executes
- No migration or schema change authorized under this gate
- Secret key never in client code, never in the repo, never sent to Claude

---

## Section 16 — Approval Record

| Party | Status | Notes |
|---|---|---|
| Claude | Approved | Rev 3 authored by Claude; all 6 Rev 2 blockers addressed |
| Codex | Pending | — |
| Bill | Pending | — |

**Execution is blocked until: (a) all three parties approve this document, (b) Gate 2A is fully closed, and (c) pre-deployment code review (§1.2) receives three-party sign-off.**
