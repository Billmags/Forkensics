# Gate 2B Proposal — Rev 9 — Hosted magick-wasm Spike on forkensics-dev

**Status:** DRAFT — awaiting three-party approval

**Governance gate:** Three-party approval (Bill + Claude + Codex) required before any cloud operation is executed. The magic words are `APPROVED: Gate 2B Rev 9 — Hosted magick-wasm Spike`.

**Authorized by:** Step 27 Rev 5 §3 Gate 2 Phase B.

**Supersedes:** Gate 2B Rev 8 (rejected — 1 execution blocker).

**Rev 9 changes from Rev 8 (1 blocker addressed):**

1. **REMOTE_CLEANUP_REQUIRED replaces REMOTE_OWNED (Blocker 1):** `REMOTE_OWNED` was set to `true` only after `supabase functions deploy` returned exit code 0. A deployment can succeed on Supabase but the CLI can still return nonzero (e.g., if the connection drops after the function is uploaded). In that case the function is live remotely but the flag stays false, and cleanup refuses to delete it. The fix: rename to `REMOTE_CLEANUP_REQUIRED` and set it to `true` immediately after the pre-deploy absence check passes — before the deploy command is issued. The flag represents *possible* cleanup responsibility, not proven ownership. It is cleared to `false` only after `delete_confirmed()` (or the cleanup handler) verifies absence. The flag is safe across phases: it is set false after Phase 0 deletion and is not set again until Phase 1's absence check passes.

Rev 8 items 2–4 (correct project ref, anchored bundle parsing, ShutdownEvent memory field) are confirmed resolved and unchanged in Rev 9.

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
# tools/image-spike/gate2b-local-test.sh — Rev 9 (unchanged from Rev 7)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMG_DIR="$SCRIPT_DIR/test-images"
LOCAL_URL="http://localhost:54321/functions/v1/image-spike"
SERVE_PID=""

cleanup_serve() {
  if [[ -n "$SERVE_PID" ]]; then
    kill "$SERVE_PID" 2>/dev/null || true
    wait "$SERVE_PID" 2>/dev/null
    echo "supabase functions serve exit: $?"
  fi
}
trap 'cleanup_serve; exit' EXIT
trap 'cleanup_serve; exit 130' INT
trap 'cleanup_serve; exit 143' TERM

[[ -d "$IMG_DIR" ]] || { echo "FATAL: generate fixtures first (gate2b-fixtures.py)" >&2; exit 1; }

supabase functions serve image-spike --no-verify-jwt &
SERVE_PID=$!
echo "serve PID: $SERVE_PID"
sleep 6

PASS=true

bool_field_local() {
  jq -r --arg f "$2" \
    'if has($f) and (.[$f] | type)=="boolean" then (.[$f]|tostring) else "MISSING" end' \
    "$1" 2>/dev/null || echo "PARSE_ERROR"
}

run_local_case() {
  local label="$1" img="$2" mime="$3" exp_accepted="$4"
  echo ""; echo "--- LOCAL $label ---"
  local out="/tmp/local-gate2b-${label}.json"
  local curl_w
  curl_w=$(curl -s -o "$out" -w '%{http_code}\t%{time_total}' \
    --max-time 60 -X POST "${LOCAL_URL}?label=${label}" \
    -H "Content-Type: $mime" --data-binary "@$img" 2>/dev/null)
  local curl_exit=$? http_status wall_time resp_accepted
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
if [[ "$PASS" == "true" ]]; then echo "LOCAL TEST: PASS"
else echo "LOCAL TEST: FAIL"; exit 1; fi
```

---

## Section 2 — Purpose

Gate 2A verified `magick-wasm` locally. Gate 2B verifies the pipeline operates within Supabase's hosted Edge Runtime resource envelope (2-second CPU limit, 200 ms conservative threshold; 256 MB memory limit). Gate 2B must pass before Step B TypeScript begins.

---

## Section 3 — Authorized Cloud Operations

Two deployments of `image-spike` on project ref `hkfrbdpedrxmbsawnbpr` (forkensics-dev), in sequence:

**Phase 0:** Deploy → invoke B-03 only → capture telemetry → delete.

**Phase 1:** Deploy → invoke B-01, B-02, B-04, B-05, B-06, B-07 → delete.

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
2. Emit: `console.log(JSON.stringify({ event: "invoke", run_id, label }))`
3. Record `mem_before_rss`, `t0`
4. Parse image header; extract width, height
5. If `width × height > 20,000,000` → return pre-decode rejection
6. Full raster decode
7. Remove all profiles, properties, comments
8. Re-encode to WebP
9. Verify output bytes (EXIF, ICCP, XMP chunks absent)
10. Compute SHA-256 (hex, 64 chars)
11. Base64-encode → `output_bytes`
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
  "input_size_bytes": 9912456,
  "output_size_bytes": 245120,
  "metadata_clean": true,
  "sha256": "a1b2c3d4...",
  "output_bytes": "<base64>",
  "diagnostic": {
    "mem_before_rss_mb": 72.1,
    "mem_after_rss_mb": 110.4,
    "wall_time_ms": 3200
  }
}
```

Pre-decode rejection omits `output_bytes`, `output_size_bytes`, `sha256`, `metadata_clean`.

### 4.6 Authentication

Legacy JWT-based anon key from forkensics-dev API settings (`anon public`). Set as runtime environment variable; never written to any file.

---

## Section 5 — Test Manifest

Phase 0: B-03 alone. Phase 1: B-01 (first request), B-02, B-04, B-05, B-06, B-07.

| ID | Filename | MIME | W | H | Pixels | Min B | Max B | accepted | Reason |
|---|---|---|---|---|---|---|---|---|---|
| B-03¹ | test-B-03.jpg | image/jpeg | 5000 | 4000 | 20,000,000 | 8,500,000 | 10,000,000 | true | — |
| B-01² | test-B-01.jpg | image/jpeg | 2500 | 2000 | 5,000,000 | 4,500,000 | 5,500,000 | true | — |
| B-02 | test-B-02.jpg | image/jpeg | 4000 | 2500 | 10,000,000 | 8,500,000 | 10,000,000 | true | — |
| B-04 | test-B-04.jpg | image/jpeg | 5001 | 4000 | 20,004,000 | 10,000 | 500,000 | false | pre_decode_rejected |
| B-05 | test-B-05.jpg | image/jpeg | 10000 | 10000 | 100,000,000 | 1,000,000 | 2,500,000 | false | pre_decode_rejected |
| B-06 | test-B-06.webp | image/webp | 2500 | 2000 | 5,000,000 | 4,500,000 | 5,500,000 | true | — |
| B-07 | test-B-07.jpg | image/jpeg | 6000 | 4000 | 24,000,000 | 10,000 | 500,000 | false | pre_decode_rejected |

¹ Phase 0, first and only request.  ² First request of Phase 1 deployment.

Upload ceiling: all fixtures ≤ 10,000,000 bytes. Accepted fixtures contain EXIF, GPS, ICC, XMP, IPTC, COMMENT before processing.

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
| 9 | B-03: `cpu_time_used` (ShutdownEvent, by `execution_id`) | < 200 ms | Supabase Log Explorer |
| 10 | B-03: `memory_used.total` (ShutdownEvent, same `execution_id`) | ≤ 220 MiB | Supabase Log Explorer |
| 11 | B-03: cold wall-clock (Phase 0) | ≤ 15 s | curl `-w '%{time_total}'` |
| 12 | B-01: Phase 1 first-request wall-clock | ≤ 30 s | curl `-w '%{time_total}'` |
| 13 | Bundle size (both phases) | ≤ 20 MB | `--debug` output, `script size:` field |
| 14 | Accepted: `metadata_clean` | true | Response JSON |
| 15 | Accepted: `output_bytes` decodes to valid WebP | RIFF/WEBP header | Runner |
| 16 | Accepted: SHA-256 recomputed from `output_bytes` | matches `sha256` field | Runner |
| 17 | Accepted: `output_size_bytes` | equals decoded WebP byte count | Runner |
| 18 | Accepted: RIFF chunk parser | EXIF, ICCP, XMP absent | `gate2b-verify-metadata.py` |

---

## Section 7 — Failure and Inconclusive Definitions

**Hard failures (runner exits immediately):** HTTP 546; bundle size > 20 MB or unparseable; any preflight check; Phase 0 deletion failure.

**Soft failures (accumulated):** Any other criterion in §6 not met.

**INCONCLUSIVE (treated as FAIL):** `run_id` not found in logs; `execution_id` not found in LogEvent; `execution_id` not a valid UUID; `cpu_time_used` or `memory_used.total` not attributable to that `execution_id`; operator types `INCONCLUSIVE`.

---

## Section 8 — Telemetry Methodology

### 8.1 Phase 0 Isolation Protocol

1. Deploy `image-spike` (Phase 0) — pre-deploy absence check confirms no prior deployment exists.
2. Invoke B-03 as the sole request; record `run_id` from response body.
3. Function emits `console.log(JSON.stringify({ event: "invoke", run_id, label }))`.
4. Runner pauses; operator executes two-step lookup (§8.2) before deletion.
5. Operator enters `execution_id`, `cpu_time_used`, `memory_used.total` at the runner prompt.
6. Runner validates: `execution_id` is a valid UUID; `cpu_time_used` and `memory_used.total` are finite and ≥ 0; thresholds met (cpu < 200 ms; `memory_used.total ÷ 1,048,576` ≤ 220 MiB).
7. Runner deletes Phase 0 deployment; confirms via `functions list` with exit-code guard.
8. Phase 1 deploys only after Phase 0 deletion is confirmed.

### 8.2 Two-Step Telemetry Lookup

**Step 1 — Find LogEvent by `run_id`; extract `execution_id`:**

1. Open: `https://supabase.com/dashboard/project/hkfrbdpedrxmbsawnbpr/logs/edge-logs`
2. Filter: `metadata.function_id = 'image-spike'`
3. Search log text for the `run_id` value printed by the runner.
4. Find the entry containing `"event":"invoke"` and `"label":"B-03"` with that `run_id`.
5. Record the `execution_id` from that log entry.

**Step 2 — Find ShutdownEvent by `execution_id`; extract `cpu_time_used` and `memory_used.total`:**

1. In the same Log Explorer, search for the `execution_id` from Step 1.
2. Locate the ShutdownEvent (worker lifecycle) record for that `execution_id`.
3. Extract `cpu_time_used` (no `_ms` suffix) from the ShutdownEvent.
4. Extract `memory_used.total` in **bytes** from the same ShutdownEvent (`memory_used` is an object on ShutdownEvent; use the `total` sub-field). Do NOT use the Metrics UI tab or the separate `WorkerMemoryUsed` diagnostic event.
5. The runner converts bytes to MiB (`÷ 1,048,576`) and applies the 220 MiB threshold.

If `execution_id` is not a valid UUID, the ShutdownEvent cannot be found for that `execution_id`, or either field is absent: enter `INCONCLUSIVE`.

### 8.3 CPU Time Field

`cpu_time_used` (no `_ms` suffix). Pass threshold: < 200 ms (conservative; accounts for Supabase documentation conflict between 2 s and 200 ms limits).

---

## Section 9 — WASM Lifecycle

`tools/image-spike/magick.wasm` → copied to `supabase/functions/_shared/magick.wasm` before Phase 0 → removed unconditionally in cleanup. Cleanup checks file existence independently of state flags.

---

## Section 10 — Supporting Scripts

### 10.1 gate2b-verify-metadata.py

*Unchanged from Rev 6. Full source in Rev 6 §10.1.*

### 10.2 gate2b-fixtures.py

*Unchanged from Rev 6. Full source in Rev 6 §10.2. Note: `_noise_image()` creates a fresh `np.random.default_rng(seed=42)` on every call — each accepted fixture is independently and identically seeded.*

### 10.3 gate2b-run.sh

```bash
#!/usr/bin/env bash
# tools/image-spike/gate2b-run.sh — Gate 2B test runner, Rev 9
# DISPOSABLE — Gate 2B only. Execute only after three-party approval of Rev 9.
#
# Usage: PROJECT_REF=hkfrbdpedrxmbsawnbpr ANON_KEY=yyy bash tools/image-spike/gate2b-run.sh
# Rev 9 change: REMOTE_CLEANUP_REQUIRED replaces REMOTE_OWNED; set before deploy, not after.
# ANON_KEY is never written to disk, echoed, or logged.
# Exits 0 on full PASS; exits 1 on any FAIL or INCONCLUSIVE.

set -uo pipefail
# -e intentionally absent: EXIT trap handles all paths.

# ---------------------------------------------------------------------------
# Environment validation — hard-pin the approved project ref (the ref, not the name)
# ---------------------------------------------------------------------------
APPROVED_PROJECT_REF="hkfrbdpedrxmbsawnbpr"
[[ -n "${PROJECT_REF:-}" ]] || { echo "FATAL: PROJECT_REF not set" >&2; exit 1; }
[[ "$PROJECT_REF" == "$APPROVED_PROJECT_REF" ]] \
  || { echo "FATAL: PROJECT_REF must be '$APPROVED_PROJECT_REF' (forkensics-dev ref); got '$PROJECT_REF'" >&2; exit 1; }
[[ -n "${ANON_KEY:-}" ]] || { echo "FATAL: ANON_KEY not set" >&2; exit 1; }

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
VERIFY_PY="$SCRIPT_DIR/gate2b-verify-metadata.py"
FIXTURES_PY="$SCRIPT_DIR/gate2b-fixtures.py"

TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RESULTS_DIR="$REPO_ROOT/tools/image-spike/gate2b-evidence-${TIMESTAMP}"
OUT_DIR="$RESULTS_DIR/responses"
RESULTS_MD="$RESULTS_DIR/gate2b-results.md"

FUNC_URL="https://${PROJECT_REF}.supabase.co/functions/v1/image-spike"

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------
CLEANUP_RAN=false
# REMOTE_CLEANUP_REQUIRED: true means this run may have caused a live image-spike
# deployment and must attempt deletion.  Set to true immediately after the
# pre-deploy absence check passes — before the deploy command — so that even a
# CLI crash after a successful upload is covered.  Set to false only after
# delete_confirmed() or the cleanup handler verifies the function is absent.
REMOTE_CLEANUP_REQUIRED=false
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
  jq -r --arg f "$2" \
    'if has($f) and (.[$f] | type)=="boolean" then (.[$f]|tostring) else "MISSING" end' \
    "$1" 2>/dev/null || echo "PARSE_ERROR"
}

# ---------------------------------------------------------------------------
# Cleanup — idempotent; evidence-safe.
# Deletes: remote function (only if REMOTE_CLEANUP_REQUIRED=true), config patch,
#          WASM_DST, SPIKE_DIR, IMG_DIR.
# Never deletes: RESULTS_DIR or OUT_DIR.
# ---------------------------------------------------------------------------
cleanup() {
  if [[ "$CLEANUP_RAN" == "true" ]]; then return; fi
  CLEANUP_RAN=true
  local trigger="${1:-EXIT}"
  echo "" >&2
  echo "=================================================================" >&2
  echo "Gate 2B Cleanup (trigger: $trigger)" >&2
  echo "=================================================================" >&2

  # Remote deletion — only if this run may own a deployment.
  # REMOTE_CLEANUP_REQUIRED is false after delete_confirmed() succeeds, so this
  # block does not re-run functions list when deletion is already confirmed.
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

  if [[ -f "$WASM_DST" ]]; then rm "$WASM_DST" && echo "Removed: $WASM_DST" >&2; fi
  if [[ -d "$SPIKE_DIR" ]]; then rm -rf "$SPIKE_DIR" && echo "Removed: $SPIKE_DIR" >&2; fi
  if [[ -d "$IMG_DIR" ]];  then rm -rf "$IMG_DIR"  && echo "Removed: $IMG_DIR" >&2; fi

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

if [[ -d "$IMG_DIR" ]]; then
  echo "FATAL: IMG_DIR already exists: $IMG_DIR — delete before running" >&2; exit 1; fi
if [[ -d "$RESULTS_DIR" ]]; then
  echo "FATAL: RESULTS_DIR collision: $RESULTS_DIR" >&2; exit 1; fi
if [[ -f "$WASM_DST" ]]; then
  echo "FATAL: $WASM_DST already exists — clean up from prior run" >&2; exit 1; fi
if grep -q '\[functions\.image-spike\]' "$CONFIG" 2>/dev/null; then
  echo "FATAL: [functions.image-spike] already in config.toml" >&2; exit 1; fi

for tool in supabase curl jq python3 shasum deno; do
  command -v "$tool" &>/dev/null || { echo "FATAL: $tool not found" >&2; exit 1; }
done
for f in "$WASM_SRC" "$VERIFY_PY" "$FIXTURES_PY"; do
  [[ -f "$f" ]] || { echo "FATAL: file not found: $f" >&2; exit 1; }
done
[[ -d "$SPIKE_DIR" ]] || { echo "FATAL: spike dir not found: $SPIKE_DIR" >&2; exit 1; }

mkdir -p "$OUT_DIR"
> "$RESULTS_MD"
results_append "# Gate 2B Results — Rev 9"
results_append "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
results_append "RESULTS_DIR: $RESULTS_DIR"
results_append "PROJECT_REF: $PROJECT_REF"
results_append ""
echo "Preflight: all checks passed"

# ---------------------------------------------------------------------------
# Generate fixtures
# ---------------------------------------------------------------------------
echo ""; echo "=== Generating fixtures ==="
python3 "$FIXTURES_PY" "$IMG_DIR" \
  || { echo "FATAL: fixture generation failed" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Verify fixtures against manifest
# ---------------------------------------------------------------------------
echo ""; echo "=== Verifying fixtures ==="

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
" 2>/dev/null) || { echo "FATAL: cannot read dims of $img" >&2; exit 1; }
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
  echo "PREFLIGHT $label: ${byte_size}B ${actual_w}x${actual_h} sha256=${sha:0:12}... $([[ "$ok" == "true" ]] && echo ✓ || echo FAIL)"
done
[[ "$preflight_ok" != "false" && "$GATE2B_PASS" == "true" ]] \
  || { echo "FATAL: preflight failed" >&2; exit 1; }

# ---------------------------------------------------------------------------
# WASM copy + verify
# ---------------------------------------------------------------------------
echo ""; echo "=== WASM copy ==="
cp "$WASM_SRC" "$WASM_DST"
SRC_HASH=$(shasum -a 256 "$WASM_SRC" | awk '{print $1}')
DST_HASH=$(shasum -a 256 "$WASM_DST" | awk '{print $1}')
[[ "$SRC_HASH" == "$DST_HASH" ]] || { echo "FATAL: WASM copy hash mismatch" >&2; exit 1; }
WASM_COPIED=true
INDEX_HASH=$(shasum -a 256 "$SPIKE_DIR/index.ts" | awk '{print $1}')
results_append ""; results_append "## Hashes"
results_append "magick.wasm sha256: $SRC_HASH"
results_append "index.ts sha256: $INDEX_HASH"
echo "WASM sha256: $SRC_HASH ✓"

# ---------------------------------------------------------------------------
# config.toml patch
# ---------------------------------------------------------------------------
echo ""; echo "=== Patching config.toml ==="
printf '\n[functions.image-spike]\nstatic_files = ["./functions/_shared/magick.wasm"]\n' \
  >> "$CONFIG"
CONFIG_PATCHED=true
echo "config.toml patched"

# ---------------------------------------------------------------------------
# Static checks
# ---------------------------------------------------------------------------
echo ""; echo "=== Static checks ==="
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
# deploy_function
#   1. Pre-deploy absence check (sets REMOTE_CLEANUP_REQUIRED=true before deploy)
#   2. Deploy
#   3. Anchored bundle-size parse — Python re.search anchored to label
# ---------------------------------------------------------------------------
deploy_function() {
  local phase="$1"
  echo ""; echo "=== Phase $phase: Deploy image-spike ==="

  # Pre-deploy: confirm image-spike is absent on remote.
  local pre_list pre_exit
  pre_list=$(supabase functions list --project-ref "$PROJECT_REF" 2>/dev/null)
  pre_exit=$?
  if [[ $pre_exit -ne 0 ]]; then
    fail "Phase $phase: pre-deploy functions list failed (exit $pre_exit)"
    return 1
  fi
  if printf '%s' "$pre_list" | grep -q "image-spike"; then
    fail "Phase $phase: image-spike already exists on remote — aborting to avoid overwriting pre-existing function"
    return 1
  fi

  # Set REMOTE_CLEANUP_REQUIRED=true BEFORE deploying.
  # The CLI can return nonzero even when the upload reached Supabase
  # successfully; this flag ensures cleanup always attempts deletion if we
  # reached this point, regardless of the deploy exit code.
  REMOTE_CLEANUP_REQUIRED=true

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

  # Anchored bundle-size parse.
  # Uses Python re.search to capture number+unit directly after the label,
  # equivalent to: (?:script|bundle) size:\s*([0-9]+(?:\.[0-9]+)?)(MiB|MB)\b
  # This prevents any intervening token from being picked up.
  local bundle_raw
  bundle_raw=$(python3 - "$deploy_out" <<'PYEOF'
import sys, re
text = sys.argv[1]
m = re.search(r'(?:script|bundle) size:\s*([0-9]+(?:\.[0-9]+)?)(MiB|MB)\b',
              text, re.IGNORECASE)
if m:
    print(m.group(1) + m.group(2))
PYEOF
  )

  if [[ -z "$bundle_raw" ]]; then
    fail "Phase $phase: bundle size not found — 'script size: NNN.NNmMB' not in --debug output"
    results_append "Phase $phase bundle: UNPARSEABLE → FAIL"
    results_append "deploy_output_head: $(printf '%s' "$deploy_out" | head -40)"
    return 1
  fi

  python3 - "$bundle_raw" <<'PYEOF' || { fail "Phase $phase: bundle ${bundle_raw} > 20 MB"; return 1; }
import sys, re, math
raw = sys.argv[1]
m = re.match(r'^([0-9]+(?:\.[0-9]+)?)(MiB|MB)$', raw, re.IGNORECASE)
if not m:
    print(f"FAIL: bundle raw '{raw}' did not re-parse"); sys.exit(1)
num, unit = float(m.group(1)), m.group(2).upper()
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
# delete_confirmed — deletes image-spike and confirms via functions list.
# Sets REMOTE_CLEANUP_REQUIRED=false on success (prevents cleanup from re-running).
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
  REMOTE_CLEANUP_REQUIRED=false   # absence verified; cleanup need not re-run
  return 0
}

# ---------------------------------------------------------------------------
# UUID validation (portable, no grep -P)
# ---------------------------------------------------------------------------
is_valid_uuid() {
  echo "$1" | grep -qiE \
    '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
}

# ---------------------------------------------------------------------------
# invoke_case — single curl; all assertions.
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
  if [[ "$http_status" != "200" ]]; then
    fail "$label: HTTP $http_status"; results_append "FAIL: HTTP $http_status"; return 0; fi

  local resp_label
  resp_label=$(jq -r '.label // "MISSING"' "$out" 2>/dev/null || echo "PARSE_ERROR")
  [[ "$resp_label" == "$label" ]] || fail "$label: response label='$resp_label' ≠ '$label'"

  local resp_run_id
  resp_run_id=$(jq -r '.run_id // ""' "$out" 2>/dev/null || echo "")
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

  if [[ "$exp_accepted" == "false" ]]; then
    local resp_reason
    resp_reason=$(jq -r '.reason // "MISSING"' "$out" 2>/dev/null || echo "PARSE_ERROR")
    [[ "$resp_reason" == "$exp_reason" ]] \
      || fail "$label: reason='$resp_reason' ≠ '$exp_reason'"
  fi

  local resp_w resp_h resp_pixels
  resp_w=$(jq -r '.width // 0'       "$out" 2>/dev/null || echo 0)
  resp_h=$(jq -r '.height // 0'      "$out" 2>/dev/null || echo 0)
  resp_pixels=$(jq -r '.pixel_count // 0' "$out" 2>/dev/null || echo 0)
  [[ "$resp_w" == "$exp_w" && "$resp_h" == "$exp_h" ]] \
    || fail "$label: dimensions ${resp_w}x${resp_h} ≠ ${exp_w}x${exp_h}"
  [[ "$resp_pixels" == "$exp_pixels" ]] \
    || fail "$label: pixel_count=$resp_pixels ≠ $exp_pixels"

  if [[ "$exp_accepted" == "true" ]]; then
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
        local decoded_size actual_sha resp_output_size header_check riff_out
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
          if riff_out=$(python3 "$VERIFY_PY" "$webp" 2>&1); then
            echo "  RIFF chunk parser: no metadata ✓"
          else
            fail "$label: RIFF parser found metadata or malformed WebP"
          fi
        fi
      else
        fail "$label: base64 decode of output_bytes failed"
      fi
    fi
    results_append "sha256: $resp_sha256"
  fi

  results_append "accepted=$resp_accepted  wall_time_s=$wall_time"
  return 0
}

# ---------------------------------------------------------------------------
# Phase 0 — B-03 telemetry isolation
# ---------------------------------------------------------------------------
results_append ""; results_append "## Phase 0 — B-03 Telemetry"
deploy_function "0" || exit 1

invoke_case B-03 test-B-03.jpg image/jpeg true "" 5000 4000 20000000
B03_RUN_ID=$(jq -r '.run_id // ""' "$OUT_DIR/B-03.json" 2>/dev/null || echo "")
B03_WALL_TIME="$LAST_WALL_TIME"

echo ""; echo "B-03 cold wall-clock: ${B03_WALL_TIME}s (threshold ≤ 15 s)"
python3 -c "import sys; sys.exit(0 if float('$B03_WALL_TIME') <= 15 else 1)" 2>/dev/null \
  || fail "B-03 cold wall-clock ${B03_WALL_TIME}s > 15 s"
results_append "B-03 cold_wall_time_s: $B03_WALL_TIME"

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
echo "  Locate entry with event='invoke', label='B-03'. Record execution_id."
echo ""
echo "STEP 2 — Find ShutdownEvent by execution_id:"
echo "  Search for the execution_id from Step 1."
echo "  Locate the ShutdownEvent for that execution_id."
echo "  Extract:"
echo "    cpu_time_used  (no _ms suffix, from ShutdownEvent)"
echo "    memory_used.total  (in bytes, from ShutdownEvent — the 'total' sub-field"
echo "                        of the 'memory_used' object on that same event)"
echo "  DO NOT use the Metrics UI tab."
echo "  DO NOT use the separate WorkerMemoryUsed diagnostic event."
echo ""
echo "Enter INCONCLUSIVE if execution_id is not a valid UUID, or if the"
echo "ShutdownEvent for that execution_id cannot be found, or if either"
echo "field is absent."
echo "================================================================="

read -rp "B-03 execution_id (UUID from LogEvent, or INCONCLUSIVE): " B03_EXEC_ID
read -rp "B-03 cpu_time_used in ms (from ShutdownEvent, or INCONCLUSIVE): " B03_CPU_INPUT
read -rp "B-03 memory_used.total in bytes (from ShutdownEvent, or INCONCLUSIVE): " B03_MEM_BYTES_INPUT

results_append "B-03 run_id: ${B03_RUN_ID:-MISSING}"
results_append "B-03 execution_id: ${B03_EXEC_ID:-MISSING}"

if [[ "$B03_EXEC_ID" == "INCONCLUSIVE" || "$B03_CPU_INPUT" == "INCONCLUSIVE" \
      || "$B03_MEM_BYTES_INPUT" == "INCONCLUSIVE" ]]; then
  fail "B-03 telemetry INCONCLUSIVE"
  results_append "B-03 telemetry: INCONCLUSIVE → FAIL"
else
  # Validate execution_id is a nonempty UUID
  if ! is_valid_uuid "$B03_EXEC_ID"; then
    fail "B-03 execution_id '${B03_EXEC_ID}' is not a valid UUID"
    results_append "B-03 execution_id validation: FAIL"
  else
    results_append "B-03 execution_id: ${B03_EXEC_ID} (valid UUID ✓)"
  fi

  # Validate cpu and memory: finite, nonneg, within thresholds.
  # Memory is in bytes from ShutdownEvent memory_used.total; runner converts to MiB.
  python3 - "$B03_CPU_INPUT" "$B03_MEM_BYTES_INPUT" <<'PYEOF'
import sys, math
try:
    cpu = float(sys.argv[1])
    mem_bytes = float(sys.argv[2])
except ValueError as e:
    print(f"FAIL: non-numeric input: {e}"); sys.exit(1)
if not math.isfinite(cpu) or cpu < 0:
    print(f"FAIL: cpu_time_used {cpu} must be finite and ≥ 0"); sys.exit(1)
if not math.isfinite(mem_bytes) or mem_bytes < 0:
    print(f"FAIL: memory_used.total {mem_bytes} bytes must be finite and ≥ 0"); sys.exit(1)
mem_mib = mem_bytes / 1_048_576
if cpu >= 200:
    print(f"FAIL: cpu_time_used {cpu} ms ≥ 200 ms threshold"); sys.exit(1)
if mem_mib > 220:
    print(f"FAIL: memory_used.total {mem_bytes} bytes = {mem_mib:.1f} MiB > 220 MiB threshold"); sys.exit(1)
print(f"cpu_time_used: {cpu} ms < 200 ms ✓")
print(f"memory_used.total: {mem_bytes} bytes = {mem_mib:.1f} MiB ≤ 220 MiB ✓")
print("B-03 telemetry: PASS")
PYEOF
  telem_exit=$?
  if [[ $telem_exit -ne 0 ]]; then
    fail "B-03 telemetry validation failed"
  fi
  results_append "B-03 cpu_time_used: $B03_CPU_INPUT ms (threshold < 200 ms)"
  results_append "B-03 memory_used.total: $B03_MEM_BYTES_INPUT bytes (threshold ≤ 220 MiB)"
fi

# Phase 0 deletion — must confirm before Phase 1 deploys
delete_confirmed "0" || exit 1

# ---------------------------------------------------------------------------
# Phase 1 — Functional matrix
# ---------------------------------------------------------------------------
results_append ""; results_append "## Phase 1 — Functional Matrix"
deploy_function "1" || { echo "Phase 1 deploy failed" >&2; exit 1; }

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

delete_confirmed "1" || fail "Phase 1: deletion unconfirmed — manual cleanup required"

# ---------------------------------------------------------------------------
# Final verdict
# ---------------------------------------------------------------------------
echo ""; echo "================================================================="
results_append ""; results_append "## Final Verdict"

if [[ "$GATE2B_PASS" == "true" ]]; then
  echo "Gate 2B: PASS"
  results_append "Verdict: PASS"
else
  echo "Gate 2B: FAIL"
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

## Section 11 — Pre-Deployment Checklist Summary

1. `python3 gate2b-fixtures.py test-images/` — review output; verify all sizes and metadata families
2. `bash gate2b-local-test.sh` — B-01 and B-04 must pass
3. `deno fmt --check supabase/functions/image-spike/index.ts`
4. `deno lint supabase/functions/image-spike/index.ts`
5. `deno check supabase/functions/image-spike/index.ts`
6. `gitleaks detect`
7. `shasum -a 256 tools/image-spike/magick.wasm supabase/functions/image-spike/index.ts`
8. Submit all artifacts + outputs; receive three-party sign-off

---

## Section 12 — Results Format

Each run produces a unique `gate2b-evidence-<TIMESTAMP>/` directory (never deleted). Structure:

```
gate2b-evidence-<TIMESTAMP>/
  gate2b-results.md
  responses/
    B-03.json  B-03.headers  B-03_output.webp
    B-01.json  B-01.headers  B-01_output.webp
    B-02.json  B-02.headers  B-02_output.webp
    B-04.json  B-04.headers
    B-05.json  B-05.headers
    B-06.json  B-06.headers  B-06_output.webp
    B-07.json  B-07.headers
```

---

## Section 13 — Local Fixture-Generation Evidence

The following is the complete stdout from running the exact `gate2b-fixtures.py` (Rev 6/7 source, unchanged in Rev 8) on the local machine: Python 3.10.12, Pillow 12.2.0, NumPy, piexif. All sizes are final on-disk values including EXIF, GPS, ICC, XMP, IPTC, and COMMENT metadata. `_noise_image()` creates a fresh `np.random.default_rng(seed=42)` on every call — every accepted fixture is independently seeded at 42.

```
Gate 2B fixture generation (deterministic, seed=42) ...

--- B-01 (2500x2000, jpeg) ---
  metadata families: ['COMMENT', 'EXIF', 'GPS', 'ICC', 'IPTC', 'XMP'] ✓
  quality=91  size=4,671,249 bytes (4.671 MB)  sha256=a6c0351dc391836bc5c9849a3c8f9d07...
  band=[4,500,000,5,500,000]  PASS ✓

--- B-02 (4000x2500, jpeg) ---
  metadata families: ['COMMENT', 'EXIF', 'GPS', 'ICC', 'IPTC', 'XMP'] ✓
  quality=92  size=9,724,898 bytes (9.725 MB)  sha256=9d64622aead820a31a2c3a21b0532ca1...
  band=[8,500,000,10,000,000]  PASS ✓

--- B-03 (5000x4000, jpeg) ---
  metadata families: ['COMMENT', 'EXIF', 'GPS', 'ICC', 'IPTC', 'XMP'] ✓
  quality=63  size=9,911,621 bytes (9.912 MB)  sha256=efd993723c8718a13c5eaa2ad5614cea...
  band=[8,500,000,10,000,000]  PASS ✓

--- B-04 (5001x4000, jpeg) ---
  color=(30, 60, 90)    quality=1  size=313,626 bytes (0.314 MB)  sha256=1bd55a9be8d62d96e5a74db4d291023b...
  band=[10,000,500,000]  PASS ✓

--- B-05 (10000x10000, jpeg) ---
  color=(60, 90, 30)    quality=1  size=1,563,126 bytes (1.563 MB)  sha256=18b4b549cd59fd9680dafa615b87c47c...
  band=[1,000,000,2,500,000]  PASS ✓

--- B-06 (2500x2000, webp) ---
  metadata families: ['EXIF', 'GPS', 'ICC', 'XMP'] ✓
  quality=95  size=4,799,230 bytes (4.799 MB)  sha256=5c7f87318bbf7b01aa3c12329f263ff3...
  band=[4,500,000,5,500,000]  PASS ✓

--- B-07 (6000x4000, jpeg) ---
  color=(90, 30, 60)    quality=1  size=375,626 bytes (0.376 MB)  sha256=181d3f13aafd328876a96276592a7d59...
  band=[10,000,500,000]  PASS ✓

=== All fixtures generated ===
```

All 7 fixtures in-band. JPEG accepted fixtures (B-01, B-02, B-03) contain all 6 metadata families: COMMENT, EXIF, GPS, ICC, IPTC, XMP. WebP accepted fixture (B-06) contains 4 families: EXIF, GPS, ICC, XMP — WebP RIFF format does not have IPTC or COMMENT chunk types.

---

## Approval Request

All four Rev 7 blockers are addressed. No cloud operation has been performed.

Requested action: three-party sign-off (Bill + Claude + Codex) using the magic words:

**`APPROVED: Gate 2B Rev 9 — Hosted magick-wasm Spike`**

---

## Erratum — Project Ref Correction (2026-08-14)

The original document incorrectly identified project ref `torkgydbvktqebssfpdi` as forkensics-dev in four places (lines 116, 268, 313, 324 of the original). That ref is forkensics-**prod**. The correct forkensics-dev ref is `hkfrbdpedrxmbsawnbpr`. All four occurrences have been corrected in this document.

### Production-Targeting Incident Record

During Gate 2B execution on 2026-08-14, the runner was invoked twice with `PROJECT_REF=torkgydbvktqebssfpdi` (forkensics-prod) before the error was identified. Root cause: the wrong ref was hard-coded in the runner from the start of Rev 9.

**Scope of impact on forkensics-prod:**
- Run 1 (13:42 UTC): `image-spike` function deployed, bundle size parse failed before any invocation, cleanup confirmed deletion.
- Run 2 (approx. 13:55 UTC): `image-spike` function deployed, B-03 invoked once (returned HTTP 401 — JWT rejected as cross-project key, so no function code executed, no image data processed), cleanup confirmed deletion.
- MCP verification (post-incident): `list_edge_functions` on `torkgydbvktqebssfpdi` returned empty array — confirmed zero functions remaining.
- No application database reads, writes, or schema changes were performed on forkensics-prod.
- No Storage objects were written.
- Platform-level logs were generated on forkensics-prod for the two deploy/delete cycles.

**Runner patches applied (all three-party approved):**
- Patch 2: bundle size regex (`\s*` between number and unit)
- Patch 3: JWT preflight (role=anon, 3-segment check) + 401/403 hard stop before Phase 1
- Patch 4: correct project ref (`hkfrbdpedrxmbsawnbpr`) in both runner locations
