# Gate 2B Proposal — Rev 2 — Hosted magick-wasm Spike on forkensics-dev

**Status:** DRAFT — awaiting three-party approval

**Governance gate:** Three-party approval (Bill + Claude + Codex) required before any cloud operation is executed. The magic words are `APPROVED: Gate 2B Rev 2 — Hosted magick-wasm Spike`.

**Authorized by:** Step 27 Rev 5 §3 Gate 2 Phase B (approved 2026-08-12).

**Supersedes:** Gate 2B Rev 1 (rejected — 7 blockers).

**Rev 2 changes from Rev 1:**
1. CPU-time limit added to pass criteria; 546 responses treated as hard failure; `cpu_time_used_ms` recorded from shutdown-event logs, not in-handler approximation.
2. Peak memory sourced from Supabase shutdown-event `memory_used` (authoritative); in-handler `Deno.memoryUsage()` delta kept as diagnostic only.
3. WASM path corrected to `../_shared/magick.wasm`; config.toml entry fixed to config-relative `./functions/_shared/magick.wasm`; deployment requires `--use-docker`; bundle size ≤ 20 MB added as pass criterion.
4. Execution loop replaced with an explicit per-test manifest covering label, filename, MIME type, expected outcome, and HTTP status verification; B-06 WebP handled correctly.
5. Authentication specified as legacy JWT-based anon key only; new publishable-key format excluded.
6. Pipeline order corrected: decode → remove all profiles/properties/comments → re-encode to WebP → independently reopen output to verify absence of every metadata type.
7. Pre-deployment review added as a required gate before cloud deployment; cleanup defined as unconditional (PASS, FAIL, timeout, interruption); local file cleanup specified; preservation rules for gate2b-results.md defined.
8. Cold-start measurement defined using BootEvent log timestamps and end-to-end first-request wall clock; cold vs. warm results reported separately.

---

## Section 1 — Prerequisites

Gate 2B execution is blocked until both of the following are satisfied:

### 1.1 Gate 2A Full Closure

Gate 2A currently has a **partial pass** (2026-08-13). All seven remaining evidence items must be completed, recorded in `tools/image-spike/results.md`, and verified by Codex before Gate 2B executes. Approval of this document may occur before Gate 2A closes; deployment may not.

| # | Remaining Gate 2A Item |
|---|---|
| 1 | Full file-size matrix: 5 MB JPEG, 10 MB JPEG, 5 MB WebP — decode, re-encode, timing measured |
| 2 | Pre-decode header parsing tested with real JPEG and WebP file headers |
| 3 | Actual decode tests at 19 MP (pass), 20 MP (pass), 21 MP (reject pre-decode) with real files |
| 4 | Measured peak memory at 20 MP boundary via `Deno.memoryUsage()` RSS delta |
| 5 | Structural metadata removal proof: EXIF, GPS, ICC, XMP, IPTC, comments absent; verified by parsing output WebP binary |
| 6 | Full bundled function size including WASM |
| 7 | `supabase functions serve` compatibility: static_files load verified through Supabase Edge Runtime |

Phase A canonical pixel limit (pending full evidence): **20 MP**.

### 1.2 Pre-Deployment Code Review

Before any cloud deployment, the following artifacts must be submitted to all three parties for review and explicit sign-off:

- `supabase/functions/image-spike/index.ts` (full source)
- `supabase/config.toml` diff (image-spike entry only)
- Test manifest (§5) and runner script (§8)
- SHA-256 hashes of `magick.wasm` and `index.ts`
- Local Edge Runtime verification: `supabase functions serve` result for each test case in the manifest
- `deno fmt --check`, `deno lint`, `deno check` results — zero errors
- `gitleaks detect` — no findings

This review may occur as part of the Gate 2B execution thread (code is written → local tests pass → artifacts submitted → parties approve deployment → deployment proceeds). It does not require a separate document, but it does require explicit three-party acknowledgement before `supabase functions deploy` is run.

---

## Section 2 — Purpose

Gate 2A demonstrated that `magick-wasm` processes images within spec under local Deno 2.9.5. Gate 2B verifies the same pipeline operates within Supabase's hosted Edge Runtime resource envelope.

**Hosted limits (current Supabase documentation):**

| Resource | Limit |
|---|---|
| Memory | 256 MB |
| CPU time per request | 2 seconds |
| Wall-clock time per request | 150 seconds |
| Bundle size | 20 MB |

The 2-second CPU-time limit is the binding constraint. A wall-clock threshold alone does not protect against a 546 resource-limit termination; CPU time must be measured and verified.

Rationale from Step 27 Rev 5 §3: the hosted environment may impose different constraints than local Deno. Building Step B (`upload-complete`) against a pixel limit that Phase B later rejects forces a code change and re-approval cycle.

---

## Section 3 — Authorized Cloud Operations

This proposal authorizes **exactly** the following on forkensics-dev:

1. Deploy one disposable Edge Function: `supabase/functions/image-spike/index.ts`
2. Invoke that function via `curl` from the developer's local machine with test payloads per the manifest in §5
3. Read function logs from Supabase dashboard or CLI to obtain authoritative resource metrics
4. Delete `functions/image-spike` immediately after results are recorded, unconditionally

**Not authorized:** any other function deployment; any schema change; any production data write; any modification to existing forkensics-dev functions or config beyond the `[functions.image-spike]` entry.

---

## Section 4 — Spike Function Design

### 4.1 Location

```
supabase/functions/image-spike/index.ts
```

Header comment: `// DISPOSABLE — Gate 2B only. Delete after results recorded. Do not merge to main.`

### 4.2 config.toml Entry

Add to `supabase/config.toml` (removed after Gate 2B):

```toml
[functions.image-spike]
static_files = ["./functions/_shared/magick.wasm"]
```

Path is config-relative (from the `supabase/` directory). The WASM binary is shared with `upload-complete` and must not be duplicated.

### 4.3 WASM Loading

```typescript
// From functions/image-spike/index.ts, ../_shared/ is one level up.
const wasmBytes = await Deno.readFile(
  new URL("../_shared/magick.wasm", import.meta.url),
);
await initializeImageMagick(wasmBytes);
```

WASM is initialized once at module level (outside the handler) so cold-start cost is measured by the BootEvent, not added to handler timing.

### 4.4 Pipeline (Corrected Order)

The pipeline in Rev 1 stripped metadata after encoding. The correct order is:

1. Parse image file header; extract width × height without full raster decode
2. Compute `pixelCount = width × height`
3. If `pixelCount > 20_000_000` → return pre-decode rejection immediately (no WASM invocation)
4. Full raster decode
5. **Remove all profiles, properties, and comments from the in-memory image object** (EXIF, GPS, ICCP, XMP, IPTC, comments) — before re-encoding
6. Re-encode to WebP
7. **Independently reopen the output WebP bytes** (do not inspect the original in-memory object); verify structural absence of each metadata type: EXIF, GPS, ICCP, XMP, IPTC, comments
8. Compute SHA-256 of the verified output bytes (hex)
9. Record in-handler diagnostics: `mem_before_rss_mb`, `mem_after_rss_mb`, `wall_time_ms`

### 4.5 In-Handler Diagnostics (Not Authoritative for Pass/Fail)

```typescript
const memBefore = Deno.memoryUsage().rss;
const t0 = performance.now();
// ... pipeline ...
const wallTimeMs = Math.round(performance.now() - t0);
const memAfter = Deno.memoryUsage().rss;
```

`memAfter - memBefore` is an endpoint delta and may miss objects allocated and released mid-pipeline. It is recorded for diagnostic correlation but is **not** used to evaluate the 220 MB criterion.

### 4.6 Authoritative Resource Metrics

The authoritative measurements come from Supabase's platform-level telemetry:

**Memory (authoritative peak):** `memory_used` from the shutdown event in Supabase Edge Function logs. This reflects the highest RSS observed by the isolate supervisor during the request lifecycle, including intermediate allocations not visible to in-handler sampling.

**CPU time (authoritative):** `cpu_time_used_ms` from Supabase Edge Function logs. This is the platform-measured CPU time, which may differ from wall-clock time.

After each test invocation, wait for the execution log entry (typically within 5 seconds of response) and record both values. If either value is unavailable (log retention issue, regional delay), use the Supabase dashboard Monitoring → Edge Functions view as the fallback source.

**HTTP 546:** Supabase returns HTTP 546 when an Edge Function is terminated due to exceeding a resource limit (memory or CPU). Any 546 response is an immediate hard failure; do not continue the matrix.

### 4.7 Response Contract

On accepted image:
```json
{
  "label": "B-03",
  "accepted": true,
  "pixel_count": 20000000,
  "width": 5000,
  "height": 4000,
  "input_size_bytes": 10485760,
  "output_size_bytes": 245000,
  "metadata_clean": true,
  "sha256": "abc123...",
  "diagnostic": {
    "mem_before_rss_mb": 72.1,
    "mem_after_rss_mb": 110.4,
    "wall_time_ms": 3200
  }
}
```

On pre-decode rejection:
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

On 546 (HTTP level — no response body):
Gate 2B immediately fails; record the label, HTTP 546, and the function log entry.

### 4.8 Authentication

Use the **legacy JWT-based anon key** from the forkensics-dev project's API settings (Settings → API → Project API keys → `anon` `public`). This is a valid JWT bearer token.

New-format publishable keys (prefixed `sb_publishable_`) are not valid bearer JWTs and must not be used. Do not print or persist the key in any committed file; use it only as a runtime shell variable.

```bash
ANON_KEY="$(pbpaste)"  # paste at runtime; never echo to terminal
```

### 4.9 Cold-Start Measurement

Module-level WASM initialization is not captured by handler timing. Cold-start is measured as follows:

1. Immediately after deployment and before any invocation, send **one cold request** and record the end-to-end wall-clock time from `curl` (the `--time-total` option)
2. Read the Supabase logs for the BootEvent timestamp and the first request completion timestamp; compute WASM init duration
3. Send a **second request** immediately after; record wall-clock time (warm path)
4. Record both cold and warm times separately in `gate2b-results.md`

---

## Section 5 — Test Manifest

| ID | Filename | MIME type | Dimensions | Pixel count | Expected result | Expected HTTP |
|---|---|---|---|---|---|---|
| B-01 | test-B-01.jpg | image/jpeg | 2500 × 2000 | 5 MP | accepted | 200 |
| B-02 | test-B-02.jpg | image/jpeg | 4000 × 2500 | 10 MP | accepted | 200 |
| B-03 | test-B-03.jpg | image/jpeg | 5000 × 4000 | 20 MP (at limit — critical) | accepted | 200 |
| B-04 | test-B-04.jpg | image/jpeg | 5001 × 4000 | 20.004 MP (over limit) | pre_decode_rejected | 200 |
| B-05 | test-B-05.jpg | image/jpeg | 10000 × 10000 | 100 MP (pixel bomb) | pre_decode_rejected | 200 |
| B-06 | test-B-06.webp | image/webp | 2500 × 2000 | 5 MP | accepted | 200 |
| B-07 | test-B-07.jpg | image/jpeg | 6000 × 4000 | 24 MP | pre_decode_rejected | 200 |

Test images are generated locally by `tools/image-spike/run.ts` before Gate 2B executes. They are not committed to the repo.

B-03 is the **critical measurement case**: authoritative `memory_used` and `cpu_time_used_ms` from shutdown-event logs determine pass/fail for the memory and CPU criteria.

---

## Section 6 — Pass Criteria

All of the following must hold:

| Criterion | Threshold | Source |
|---|---|---|
| B-01, B-02, B-03, B-06: `accepted = true` | 100% | Function response |
| B-04, B-05, B-07: `reason = "pre_decode_rejected"` | 100% | Function response |
| All invocations: HTTP status | 200 (never 546) | curl exit status |
| B-03: `memory_used` (shutdown event) | ≤ 220 MB | Supabase logs |
| B-03: `cpu_time_used_ms` (shutdown event) | < 2000 ms | Supabase logs |
| B-03: wall-clock time (curl `--time-total`) | ≤ 30 s | curl output |
| Cold-start wall-clock (first request) | ≤ 15 s | curl `--time-total` |
| Bundle size (reported by `supabase functions deploy`) | ≤ 20 MB | Deploy output |
| All accepted outputs: `metadata_clean = true` | 100% | Function response |
| B-03 warm wall-clock (second request) | ≤ 10 s | curl `--time-total` |

---

## Section 7 — Failure Criteria

Any of the following constitutes immediate Gate 2B failure:

- Any invocation returns HTTP 546 (resource limit exceeded)
- B-03 shutdown-event `memory_used` > 220 MB
- B-03 shutdown-event `cpu_time_used_ms` ≥ 2000 ms
- B-03 curl wall-clock > 30 s
- Any of B-04, B-05, B-07 returns `accepted: true`
- Any accepted output has `metadata_clean: false`
- WASM fails to load (function returns 5xx on all requests)
- Bundle size exceeds 20 MB (abort before deployment)

**On failure:** execute cleanup immediately (§9); record failure evidence; do not proceed to Step B. A separate proposal revision must address the failure before any further cloud operation.

---

## Section 8 — Execution Procedure

### 8.1 Pre-Deployment Checklist (run locally first)

```bash
# Static checks — must all pass before submitting for pre-deployment review
deno fmt --check supabase/functions/image-spike/index.ts
deno lint supabase/functions/image-spike/index.ts
deno check supabase/functions/image-spike/index.ts
gitleaks detect --source . --config .gitleaks.toml

# Local Edge Runtime verification — run test matrix against supabase functions serve
supabase start
supabase functions serve image-spike &
# (run the test runner against localhost; record results)
# Kill serve; stop supabase

# Compute hashes
shasum -a 256 supabase/functions/image-spike/index.ts
shasum -a 256 supabase/functions/_shared/magick.wasm
```

Submit artifacts to all three parties for pre-deployment review before proceeding.

### 8.2 Test Runner Script

```bash
#!/usr/bin/env bash
set -euo pipefail

# Runtime-only; never committed with values
FUNC_URL="https://<forkensics-dev-ref>.supabase.co/functions/v1/image-spike"
OUT_DIR="tools/image-spike/gate2b-responses"
mkdir -p "$OUT_DIR"

# Test manifest: label|filename|mime-type|expected-accepted|expected-reason
declare -a MANIFEST=(
  "B-01|test-B-01.jpg|image/jpeg|true|"
  "B-02|test-B-02.jpg|image/jpeg|true|"
  "B-03|test-B-03.jpg|image/jpeg|true|"
  "B-04|test-B-04.jpg|image/jpeg|false|pre_decode_rejected"
  "B-05|test-B-05.jpg|image/jpeg|false|pre_decode_rejected"
  "B-06|test-B-06.webp|image/webp|true|"
  "B-07|test-B-07.jpg|image/jpeg|false|pre_decode_rejected"
)

for entry in "${MANIFEST[@]}"; do
  IFS="|" read -r label filename mime expected_accepted expected_reason <<< "$entry"
  image_path="tools/image-spike/test-images/$filename"

  echo "=== $label ($filename, $mime) ==="
  http_status=$(curl -s -o "$OUT_DIR/$label.json" -w "%{http_code}" \
    --time-total \
    -X POST "$FUNC_URL?label=$label" \
    -H "Authorization: Bearer $ANON_KEY" \
    -H "Content-Type: $mime" \
    --data-binary "@$image_path")

  echo "HTTP status: $http_status"
  if [[ "$http_status" == "546" ]]; then
    echo "HARD FAILURE: HTTP 546 resource limit exceeded on $label"
    exit 1
  fi
  if [[ "$http_status" != "200" ]]; then
    echo "UNEXPECTED STATUS: $http_status on $label"
    exit 1
  fi

  # Verify response fields
  accepted=$(jq -r '.accepted' "$OUT_DIR/$label.json")
  if [[ "$accepted" != "$expected_accepted" ]]; then
    echo "FAILURE: $label expected accepted=$expected_accepted, got $accepted"
    exit 1
  fi

  echo "$label: OK (accepted=$accepted)"
done

echo "=== All test cases completed ==="
```

`ANON_KEY` is set in the shell session at runtime; never written to a file.

### 8.3 Cold-Start Measurement

```bash
# Cold request (immediately after deploy, before any other invocation)
time curl -X POST "$FUNC_URL?label=cold" \
  -H "Authorization: Bearer $ANON_KEY" \
  -H "Content-Type: image/jpeg" \
  --data-binary "@tools/image-spike/test-images/test-B-01.jpg" \
  --time-total -o /dev/null -w "cold wall_time: %{time_total}s\n"

# Warm request (immediately after cold)
time curl -X POST "$FUNC_URL?label=warm" \
  -H "Authorization: Bearer $ANON_KEY" \
  -H "Content-Type: image/jpeg" \
  --data-binary "@tools/image-spike/test-images/test-B-01.jpg" \
  --time-total -o /dev/null -w "warm wall_time: %{time_total}s\n"
```

After execution, read Supabase logs for the BootEvent entry and record:
- `boot_duration_ms`: time from function boot to first request ready
- `cold_wall_time_s`: from curl `--time-total`
- `warm_wall_time_s`: from curl `--time-total`

### 8.4 Deployment

```bash
# Requires --use-docker; API fallback (--use-api) does not support static_files
supabase functions deploy image-spike \
  --project-ref <forkensics-dev-ref> \
  --use-docker
```

Record the bundle size reported by the deploy command. If bundle > 20 MB: abort; do not proceed; Gate 2B fails.

---

## Section 9 — Cleanup

Cleanup runs **unconditionally** — on PASS, FAIL, timeout, or interruption.

### 9.1 Remote Cleanup

```bash
# Delete the hosted function
supabase functions delete image-spike --project-ref <forkensics-dev-ref>

# Verify deletion
supabase functions list --project-ref <forkensics-dev-ref>
# image-spike must not appear; record confirmation
```

If the CLI delete fails, delete via Supabase dashboard → Edge Functions → image-spike → Delete.

### 9.2 Local Cleanup

Remove temporary artifacts created for Gate 2B:

```bash
# Remove spike function source
rm -rf supabase/functions/image-spike/

# Revert config.toml [functions.image-spike] entry
git restore supabase/config.toml

# Remove generated test images (not committed)
rm -rf tools/image-spike/test-images/

# Remove raw response files (contain URL paths; not committed)
rm -rf tools/image-spike/gate2b-responses/
```

### 9.3 What to Preserve

Preserve in `tools/image-spike/gate2b-results.md`:
- Full response JSON for each test case with the label (sanitize any paths or tokens before committing)
- Authoritative log values: `memory_used` and `cpu_time_used_ms` per test case
- Cold/warm timing
- Bundle size
- Pass/fail verdict per criterion in §6
- Overall Gate 2B verdict: PASS or FAIL

`gate2b-results.md` is committed. SHA-256 hashes of `magick.wasm` and `index.ts` (from the pre-deployment checklist) are included for traceability.

---

## Section 10 — Cold-Start Results Format

`gate2b-results.md` must record:

```
## Cold-Start Measurements
Boot event timestamp (from logs): <ISO8601>
First request completion (from logs): <ISO8601>
Boot duration (logs-derived): <N> ms
Cold wall-clock (curl --time-total): <N.NNN> s
Warm wall-clock (curl --time-total): <N.NNN> s
WASM initialization scope: module-level (excluded from handler timing)
```

---

## Section 11 — Step B Gate

If Gate 2B passes:

- `gate2b-results.md` records the passing verdict with confirmed hosted limits
- The `upload-complete` pixel limit is the **Gate 2B confirmed hosted limit** (which must match or be lower than the Phase A local limit; if they diverge, the hosted limit governs)
- A separate Step B proposal with its own three-party approval is required before `upload-complete` TypeScript implementation begins

---

## Section 12 — Security Constraints (Carried Forward)

- Secret key never in client code, never in the repo, never sent to Claude
- Anon key used only as a runtime shell variable; never written to any committed file; never echoed to terminal
- `image-spike` function does not write to the database or any storage bucket; it is stateless
- No migration or schema change authorized under this gate
- Three-party governance: Bill + Claude + Codex must all approve before cloud deployment

---

## Section 13 — Approval Record

| Party | Status | Notes |
|---|---|---|
| Claude | Approved | Rev 2 authored by Claude; all 7 Rev 1 blockers addressed |
| Codex | Pending | — |
| Bill | Pending | — |

**Execution is blocked until all three parties approve AND Gate 2A is fully closed AND pre-deployment code review (§1.2) is completed.**
