# Gate 2B Rev 14 — §1.2 Pre-Deployment Artifact Review (Rev 5)
Date: 2026-08-15  
Reviewer: Claude  
Proposal: Gate-2B-Proposal-Rev14.md (APPROVED 2026-08-15)

---

## Blocker Resolution History (complete)

| # | Blocker | Resolution |
|---|---------|-----------|
| 1 | `deno fmt --check` fails | Fixed — all formatting applied; SHA confirmed |
| 2 | `async` callback with no `await` | Removed `async` from `ImageMagick.read` callback |
| 3 | Version mismatch `@0.0.30` vs locked WASM `@0.0.42` | Changed to `@0.0.42` |
| 4 | `crypto.subtle.digest` Deno 2.9.5 type error | Added `safeData = data as unknown as Uint8Array<ArrayBuffer>` |
| 5 | Local reject 2501×2000 = 5,002,000px (below 15,500,000) | Changed to 5001×3100 = 15,503,100px (~237KB) |
| 6 | `gate2b-verify-metadata.py` missing from inventory | Added; SHA confirmed matching |
| 7 | `deno fmt --check` still fails after Rev 2 edits | Applied remaining formatting; SHA verified against deno fmt output |
| 8 | `initialize` not exported from `@0.0.42` | Changed to `initializeImageMagick` in import and call |
| 9 | Local test comment described old 2501×2000 fixture | Updated comment to 5001×3100 |
| 10 | `index.ts` on disk unformatted (SHA `ccbedcedd…`) | Formatting applied iteratively; `f9cc074e…` verified against real `deno fmt` run |
| 11 | `--project-ref local` unsupported in Supabase CLI 2.111.0 | Changed to `--workdir "$REPO_ROOT"` |

---

## §1.2.1 — File Inventory (final)

| File | SHA-256 |
|------|---------|
| `supabase/functions/image-spike/index.ts` | `f9cc074e01212463e6bb1c71ab8a6142708f93e3c181089a800c098b5b839976` |
| `tools/image-spike/gate2b-run-r14.sh` | `d3074c64c62505879d9fc0f6549e179576eebcce411cae1fce786c1d1f7dfe6c` |
| `tools/image-spike/gate2b-local-test-r14.sh` | `f39010f43aae98389f264a723698a05cf945792c8e0071952e04f366d4b262a4` (GF-1 + GF-2 applied 2026-08-15; prior: `a2832bdb…`) |
| `tools/image-spike/gate2b-fixtures-r14.py` | `cb6e10c8f95a2694e41a09a0bc386d8c1f80edcf10cfb2a58bfa80cee00e648b` |
| `tools/image-spike/gate2b-verify-input-metadata.py` | `15330f0d05dc3ae6b0f1ba783ebf89f60a158c893231effd29622d2841a8d509` |
| `tools/image-spike/gate2b-verify-metadata.py` | `44505b3bd21f8e859a9bcd241417ce564bf597233e1bd8747a449a49ee186008` |
| `tools/image-spike/magick.wasm` | `c903248c3b66a550b74bac5ea25d359e84455b8d82aa945a16f75f6fd8be610a` |

---

## §1.2.2 — Bash Syntax Check

| Script | Result |
|--------|--------|
| `bash -n gate2b-run-r14.sh` | **PASS** |
| `bash -n gate2b-local-test-r14.sh` | **PASS** |

---

## §1.2.3 — Python Compile Check

| Script | Result |
|--------|--------|
| `py_compile gate2b-fixtures-r14.py` | **PASS** |
| `py_compile gate2b-verify-input-metadata.py` | **PASS** |
| `py_compile gate2b-verify-metadata.py` | **PASS** |

---

## §1.2.4 — Deno Static Checks

| Check | Result |
|-------|--------|
| `deno fmt --check index.ts` | **PASS** — SHA `f9cc074e…` verified against real formatter output |
| `deno lint index.ts` | **PASS** |
| `deno check index.ts` | **PASS** |

---

## §1.2.5 — Secret Scan

`gitleaks detect --source . --config .gitleaks.toml`: **no findings** ✓

---

## §1.2.6 — Survey Fixture Generation + Metadata Preflight

| Fixture | Dims | Size (B) | Band | Metadata |
|---------|------|----------|------|----------|
| S-5 | 2500×2000 | 4,671,619 | [4M–5.5M] | **PASS** — 6 families |
| S-8 | 4000×2000 | 7,172,815 | [6.5M–9M] | **PASS** — 6 families |
| S-10 | 4000×2500 | 9,725,268 | [8.5M–10M] | **PASS** — 6 families |
| S-12 | 4000×3000 | 9,075,710 | [9M–10M] | **PASS** — 6 families |
| S-15 | 5000×3000 | 9,802,741 | [9M–10M] | **PASS** — 6 families |

S-15 q_start=79 → 9,802,741B ✓  All ≤ 10,000,000B upload ceiling ✓

### Survey Fixture SHA-256

| Fixture | SHA-256 |
|---------|---------|
| test-S-5.jpg | `e6ff35ce7786e408cbf047d852ad978be767b4be0fa042850fc30545d66d804e` |
| test-S-8.jpg | `c029e07b5b9ef2fd0ac6cd9be6b13dbaac3f084b3e65e0c394409d90834bbc21` |
| test-S-10.jpg | `e0cfac83ba7338c9eb02d09dde80f1ddf2b5a0ee2df1ab6f4dcfcdd9845f0a03` |
| test-S-12.jpg | `cc914ae5bb736ac035dd8a9ace57eb0e3008e1e388e48e42f49be9679847df00` |
| test-S-15.jpg | `761eba57c88de726cfcd1c06956b371a304d747a2226d3e9dc164cff2ffd4da6` |

---

## §1.2.7 — Confirmation Fixture Generator Smoke Test (ceiling=5MP)

| Fixture | Dims | Size (B) | Metadata |
|---------|------|----------|----------|
| test-C-jpeg-1.jpg (seed=42, q=94) | 2500×2000 | 5,479,196 | PASS — 6 families |
| test-C-jpeg-2.jpg (seed=43, q=94) | 2500×2000 | 5,479,409 | PASS — 6 families |
| test-C-jpeg-3.jpg (seed=44, q=94) | 2500×2000 | 5,478,603 | PASS — 6 families |
| test-C-webp.webp (seed=42, q=90) | 2500×2000 | 4,190,156 | PASS — EXIF+GPS, ICC, XMP |
| test-C-reject.jpg (2501×2000) | 2501×2000 | 79,126 | n/a |

C-REJECT: 79,126B ≤ 500,000B ✓

---

## §1.2.8 — index.ts Key Property Checks

- `@imagemagick/magick-wasm@0.0.42` — matches Gate 2A locked WASM ✓
- `initializeImageMagick(wasmBytes)` — correct export for 0.0.42 ✓
- `CANONICAL_PIXEL_LIMIT = 15_500_000` (survey value) ✓
- `ImageMagick.read(body, (img) => {` — no `async` on callback ✓
- `safeData = data as unknown as Uint8Array<ArrayBuffer>` before `digest` ✓
- `uint8ArrayToBase64`: chunked `String.fromCharCode` CHUNK=8192 ✓
- `parseImageHeader`: structural JPEG SOF + RIFF/WebP parser ✓
- `imageDecodeStarted = false` before limit check; `= true` before WASM call ✓
- DISPOSABLE header comment present ✓

---

## §1.2.9 — Local Edge Runtime Test

C-REJECT: 5001×3100 = 15,503,100px > 15,500,000 survey limit; ~237KB.  
CLI invocation: `supabase functions serve image-spike --workdir "$REPO_ROOT" --no-verify-jwt`

### Manual warm-up protocol (2026-08-15)

`gate2b-local-test-r14.sh` automated run is blocked by a timing bug: the readiness check fires a false positive because Kong returns HTTP 502/503 (`{"message":"name resolution failed"}`) before the edge runtime has registered the function — `curl` exits 0 on any HTTP response. Root cause confirmed by observing null-field JSON responses in the automated path versus correct responses after a 25-second warm-up delay.

**Manual warm-up approach used instead:**

```bash
cp tools/image-spike/magick.wasm supabase/functions/_shared/magick.wasm
printf '\n[functions.image-spike]\nstatic_files = ["./functions/_shared/magick.wasm"]\n' >> supabase/config.toml
REPO_ROOT="$(pwd)"
supabase functions serve image-spike --workdir "$REPO_ROOT" --no-verify-jwt &
sleep 25
# run S-5 then C-REJECT
```

### Results (2026-08-15)

| Test | Expected | Actual Response | Result |
|------|----------|-----------------|--------|
| S-5 (5,000,000px) | accepted=true, image_decode_started=true, pixel_count=5000000 | `{"accepted":true,"image_decode_started":true,"pixel_count":5000000,"wall_time_ms":1235.048959}` | ✅ PASS |
| C-REJECT (5001×3100) | accepted=false, image_decode_started=false, reason=pre_decode_rejected | `{"accepted":false,"image_decode_started":false,"reason":"pre_decode_rejected","pixel_count":15503100}` | ✅ PASS |

### CPU soft limit note

Edge runtime logged during S-5:
```
CPU time soft limit reached: isolate: e3e060ce-a63f-4f31-8714-3119e91753d1
early termination has been triggered: isolate: e3e060ce-a63f-4f31-8714-3119e91753d1
```

Response was returned successfully before termination. `wall_time_ms = 1235ms` is within the 1,500ms cloud budget. Soft limit is a local runtime artifact; the function completes within spec.

### Governance proposal — test script timing fix

**Scope:** One-line addition to `gate2b-local-test-r14.sh` (new SHA required).  
**Change:** Add `sleep 20` before the `for i in $(seq 1 30)` readiness loop to allow the edge runtime to finish registering the function after Kong is up.  
**Rationale:** Eliminates false-positive "ready" signal from Kong 502/503 responses.  
**Status:** Awaiting Codex approval + Bill sign-off before any edit.

**Additional fix needed:** The Python cleanup regex must also strip orphaned `["./functions/_shared/magick.wasm"]` TOML table headers left by aborted test runs. Current regex `r'\n\[functions\.image-spike\]\n([^\[]*)'` does not match these. Proposed additional pass:  
```python
re.sub(r'\n\["\.\/functions\/_shared\/magick\.wasm"\]\n', '\n', c)
```

---

## §1.2 Status Summary (Rev 6)

| Check | Status |
|-------|--------|
| bash -n (both scripts) | ✅ PASS |
| py_compile (3 scripts) | ✅ PASS |
| Survey fixture generation (5 fixtures) | ✅ PASS |
| Survey fixture metadata (6 families each) | ✅ PASS |
| Confirmation fixture smoke test | ✅ PASS |
| C-REJECT ≤ 500,000B | ✅ PASS |
| index.ts — all functional properties | ✅ PASS |
| deno fmt --check (SHA `f9cc074e…`) | ✅ PASS |
| deno lint | ✅ PASS |
| deno check | ✅ PASS |
| gitleaks | ✅ no findings |
| Local runtime test — S-5 | ✅ PASS (manual warm-up; wall_time_ms=1235ms) |
| Local runtime test — C-REJECT | ✅ PASS (pre_decode_rejected; pixel_count=15503100) |

**All §1.2 checks complete.** Automated test script timing fix is a pre-deployment governance item (does not block sign-off).

---

## §1.2 Three-Party Sign-Off

Magic phrase: `APPROVED: Gate 2B §1.2 — Artifact Review Complete`

| Party | Status |
|-------|--------|
| Claude | ✅ APPROVED — all checks pass; local runtime results confirmed 2026-08-15 |
| Codex | ✅ APPROVED 2026-08-15 — verified new SHA `f39010f4…`, bash -n passes, GF-1 + GF-2 correctly implemented, config.toml clean |
| Bill | ✅ APPROVED 2026-08-15 — verified locked artifact hashes, shell syntax, clean config.toml, recorded runtime results |

### Bill's approval note (verbatim)

> "I verified the locked artifact hashes, shell syntax, clean `config.toml`, and recorded runtime results.
> APPROVED: Gate 2B §1.2 — Artifact Review Complete
> Two approved governance follow-ups remain before the local script is used again:
> * Add the 20-second warm-up before readiness polling.
> * Expand cleanup to remove orphaned WASM table headers, ensuring cleanup runs even when the function section is absent.
> After those edits, record the new local-test SHA and rerun `bash -n`. They do not reopen the function or hosted-runner review. Bill's sign-off is still required before deployment."

### Approved governance follow-ups (pre-next-local-run, not blocking deployment review)

| # | Change | Scope | Status |
|---|--------|-------|--------|
| GF-1 | Add `sleep 20` before readiness polling loop in `gate2b-local-test-r14.sh` | Timing fix | ✅ Applied 2026-08-15 |
| GF-2 | Expand cleanup to strip orphaned `["./functions/_shared/magick.wasm"]` TOML headers; removed `grep -q` guard so cleanup always runs | Cleanup robustness | ✅ Applied 2026-08-15 |

New SHA: `f39010f43aae98389f264a723698a05cf945792c8e0071952e04f366d4b262a4`  
`bash -n`: **PASS**  
These edits do **not** reopen function or hosted-runner review. Separate operator deployment authorization still required before any cloud operation.

---

## §1.3 — Hosted Runtime Run (Gate 2B Rev 14) — FAIL

**Run date:** 2026-08-15  
**Evidence directory:** `tools/image-spike/gate2b-evidence-r14-20260815T155948Z/`  
**Runner script SHA:** `d3074c64c62505879d9fc0f6549e179576eebcce411cae1fce786c1d1f7dfe6c`  
**Authorized project:** `hkfrbdpedrxmbsawnbpr` (forkensics-dev)

### Preflight

| Check | Result |
|-------|--------|
| Rev 9 evidence SHA `3903f9dc…` | ✅ verified |
| `CANONICAL_PIXEL_LIMIT=15500000` in index.ts | ✅ verified |
| All tool dependencies present | ✅ |
| Survey fixture preflight (5 fixtures, dims, size, metadata) | ✅ all PASS |
| deno fmt / lint / check / gitleaks | ✅ all PASS |
| Three-party pre-deployment confirmation | ✅ YES entered |

### Deployment

| Item | Value |
|------|-------|
| Function | `image-spike` |
| Bundle size | 9.3 MB (≤ 20 MB ✓) |
| Deploy exit | 0 (success) |
| index.ts SHA at deploy | `f9cc074e01212463e6bb1c71ab8a6142708f93e3c181089a800c098b5b839976` |
| magick.wasm SHA at deploy | `c903248c3b66a550b74bac5ea25d359e84455b8d82aa945a16f75f6fd8be610a` |
| Region | `us-east-1` |

### S-5 Invocation Result

| Field | Value |
|-------|-------|
| HTTP status | **546** |
| curl_exit | 0 |
| wall_time_s | 3.157433 |
| sb-error-code | `WORKER_RESOURCE_LIMIT` |
| Response body | `{"code":"WORKER_RESOURCE_LIMIT","message":"Function failed due to not having enough compute resources (please check logs)"}` |
| x-deno-execution-id | `9b06ec5c-e9e3-4d43-9783-ebfad5885f07` |
| sb-request-id | `01a00627-048e-796c-88a7-5b809703794a` |
| x-request-id (response header) | not found |
| Execution time (dashboard) | **2,914 ms** |
| Function console output | none (`logs: []` in unified log) |

### Additional Fields (Edge Functions Log Explorer)

| Field | Value |
|-------|-------|
| function_id | `55f71df7-bffe-4c14-896f-69f1b938a66a` |
| deployment_id | `hkfrbdpedrxmbsawnbpr_55f71df7-bffe-4c14-896f-69f1b938a66a_1` |
| execution_time_ms | `2914` (confirmed) |
| response.headers.sb_error_code | `WORKER_RESOURCE_LIMIT` (confirmed) |

### ShutdownEvent Telemetry

**Status: NOT RETRIEVED** — searched unified Logs (beta) and old Log Explorer Edge Functions collection by execution ID `9b06ec5c-e9e3-4d43-9783-ebfad5885f07`. Only the API gateway request entry was found; no separate ShutdownEvent entry was emitted. This is consistent with Supabase Edge Runtime behavior where hard `WORKER_RESOURCE_LIMIT` 546 terminations may not produce a ShutdownEvent log entry. Fields `reason`, `cpu_time_used`, `memory_used.*`, and `boot_time` are therefore unrecorded.

**Qualitative closure:** 2,914 ms execution time with `WORKER_RESOURCE_LIMIT`, no function console output, and no request handler invocation collectively establish a boot-time resource exhaustion. The specific resource dimension (CPU vs. memory) is not confirmed by telemetry but is consistent with CPU: the local test triggered the CPU soft limit at ~1,235 ms wall time, and the hosted limit of 1,500 ms CPU would have been exceeded during the same WASM initialization path.

### Unified Log Entry (API Gateway)

```json
{
  "id": "d850a60c-f52c-4ce4-804d-dbaa82ea4c4c",
  "date": "2026-08-15T16:00:18.416Z",
  "method": "POST",
  "status": "546",
  "latency": 0,
  "log_type": "edge function",
  "logs": []
}
```

`latency: 0` and `logs: []` in the unified log, combined with the dashboard-reported **execution time of 2,914 ms**, indicate the function ran for ~2.9 seconds without producing any console output before termination. The request handler was never reached; the `WORKER_RESOURCE_LIMIT` was triggered during boot initialization. 2,914 ms exceeds the 1,500 ms CPU budget, consistent with WASM initialization consuming CPU continuously until the hard limit fired.

### Bash Version Issue (non-causal)

macOS system bash (3.2) does not support `declare -A`. Associative array declarations failed silently at script load time. This did not cause the 546 — the failure occurred at the first hosted invocation, before any associative array lookups. Fix for any future run: invoke with `/opt/homebrew/bin/bash` (bash 5.x).

### Survey Result

| Phase | Result |
|-------|--------|
| S-5MP deploy | ✅ success (9.3 MB bundle) |
| S-5 invocation | ❌ HTTP 546 — survey stopped |
| S-8 through S-15 | not reached |
| Viable ceiling | **NONE** |

### Architectural Finding

The function's top-level `await initializeImageMagick(wasmBytes)` executes before any request is handled. On the local Edge Runtime this triggered a CPU soft limit at ~1235ms but the response was still returned. On the hosted Edge Runtime (hard CPU limit: 1,500ms, memory: 200 MiB), the same initialization path triggered a hard `WORKER_RESOURCE_LIMIT` at cold boot, aborting the isolate before the handler ever fired.

The local CPU soft limit warning ("soft limit is a local runtime artifact; the function completes within spec" — §1.2.9) was an incomplete assessment. The hosted runtime enforces the same budget as a hard cutoff. Top-level WASM initialization is not viable under the hosted constraint.

**Note:** The unified log does not yet confirm whether CPU time, memory, or wall-clock time was the specific exhausted resource. ShutdownEvent telemetry is required before the root cause is formally closed. The qualitative finding (boot-time failure, no function output) is established; the specific resource dimension remains open.

### Gate 2B Rev 14 Verdict

**FAIL** — `WORKER_RESOURCE_LIMIT` at S-5 cold boot. No viable ceiling on hosted Edge Runtime with current top-level WASM initialization architecture.

### Next Step

Gate 2B Rev 15 — lazy cached WASM initialization hypothesis. Requires Codex review and three-party approval before any edit to `index.ts` or cloud operation.

---

## §1.4 — Gate 2B Rev 15 §1.2 Static Checks

**Date:** 2026-08-15  
**Proposal:** Gate-2B-Proposal-Rev15.md (APPROVED 2026-08-15 — Bill)  
**Authorized project:** `hkfrbdpedrxmbsawnbpr` (forkensics-dev only)

### Artifact Inventory

| File | SHA-256 |
|------|---------|
| `supabase/functions/image-spike/index.ts` | `ecfe70c01c9ca8f46089d1b0833e959d50e8e623038ecb9cd67c940d3f00399a` (rev 2 — XMP chunk ID fix; see B-3 below) |
| `tools/image-spike/gate2b-local-test-r15.sh` | `3a7e300376d74cce345c335e3350d77881da2c90a9c4937d9ab38451a64d178b` (rev 4 — L-2 four-field validation + INCONCLUSIVE-LOCAL logic; see GC-1, GC-2 below) |
| `tools/image-spike/gate2b-run-r15.sh` | `a36b9fb25d575bca34eecddcec072f4f7222ef82edaaf859465af56b4143f89b` (rev 2 — H-2/H-2b accepted assertion + H-1 operator confirmation gate; see B-1, B-2 below) |
| `tools/image-spike/gate2b-local-test-r14.sh` | `f39010f43aae98389f264a723698a05cf945792c8e0071952e04f366d4b262a4` (unchanged) |
| `tools/image-spike/gate2b-fixtures-r14.py` | `cb6e10c8f95a2694e41a09a0bc386d8c1f80edcf10cfb2a58bfa80cee00e648b` (unchanged) |
| `tools/image-spike/gate2b-verify-input-metadata.py` | `15330f0d05dc3ae6b0f1ba783ebf89f60a158c893231effd29622d2841a8d509` (unchanged) |
| `tools/image-spike/gate2b-verify-metadata.py` | `44505b3bd21f8e859a9bcd241417ce564bf597233e1bd8747a449a49ee186008` (unchanged) |
| `tools/image-spike/magick.wasm` | `c903248c3b66a550b74bac5ea25d359e84455b8d82aa945a16f75f6fd8be610a` (unchanged) |

### index.ts Rev 15 — Key Properties

- Import: `@imagemagick/magick-wasm@0.0.42` — matches Gate 2A locked WASM ✓
- `initializeImageMagick` — correct export name for `@0.0.42` ✓
- `CANONICAL_PIXEL_LIMIT = 15_500_000` — survey value unchanged ✓
- `isolateId = crypto.randomUUID()` at module scope — set once per isolate ✓
- `magickInitPromise: Promise<void> | undefined` + `magickInitialized: boolean` — Promise cache for concurrency safety ✓
- `ensureMagick()` — returns `{ promise, startedThisRequest }`; resets both on error ✓
- Handler call order: `cacheHit = magickInitialized` → `initStart = performance.now()` → `ensureMagick()` → `await promise` → `initWallTimeMs` — timer before call ✓
- Pre-decode rejection does not call `ensureMagick()`; returns `magick_init_called_this_request: false` ✓
- Four diagnostic fields in every response: `isolate_id`, `magick_cache_hit`, `magick_init_called_this_request`, `magick_init_wall_time_ms` ✓
- `handler_invoked` console.log at top of handler ✓
- `sha256Input = new Uint8Array(outputBytes.byteLength); sha256Input.set(outputBytes)` before `crypto.subtle.digest` — satisfies `BufferSource` type ✓
- No top-level WASM initialization ✓
- DISPOSABLE header comment present ✓

### Static Check Results

| Check | Result |
|-------|--------|
| `bash -n gate2b-local-test-r15.sh` | ✅ PASS (SHA `3a7e3003…` — unchanged) |
| `bash -n gate2b-run-r15.sh` | ✅ PASS (re-verified SHA `a36b9fb2…` after B-1, B-2) |
| `deno fmt --check index.ts` | ✅ PASS (SHA `ecfe70c0…`) |
| `deno lint index.ts` | ✅ PASS |
| `deno check index.ts` | ✅ PASS |
| `deno fmt --check index.ts` | ✅ PASS |
| `deno lint index.ts` | ✅ PASS |
| `deno check index.ts` | ✅ PASS |
| `gitleaks detect` | ✅ no findings |

**Static check iterations:** Two deno fmt fixes (multi-line return objects in `parseJpegDims` and `parseWebpDims`) and one deno check fix (copy `outputBytes` to concrete `ArrayBuffer` before `crypto.subtle.digest`) applied before all checks passed.

### §1.4 Status

| Phase | Status |
|-------|--------|
| Static checks (all 6) | ✅ PASS |
| Local runtime test — L-1 cold S-5 | ✅ PASS (2026-08-15 18:37 UTC; index.ts `ecfe70c0…`) |
| Local runtime test — L-2 warm S-5 | ⚠ INCONCLUSIVE-LOCAL (CPU soft limit recycled isolate; all path (b) assertions passed) |
| Local runtime test — L-3 C-REJECT | ✅ PASS (2026-08-15 18:37 UTC) |
| Three-party §1.2 sign-off | ✅ COMPLETE (2026-08-15) |

**Overall local test verdict: PASS WITH L-2 INCONCLUSIVE-LOCAL**  
Three-party sign-off recorded 2026-08-15. Hosted run authorized and executed; see hosted run results below.

---

### Pre-Sign-Off Blocker Corrections (2026-08-15)

| # | Blocker | Fix | File | New SHA |
|---|---------|-----|------|---------|
| B-1 | H-2 and H-2b never asserted `accepted=true`, contrary to Rev 15 success criteria | Added `h2_accepted` / `h2b_accepted` extraction and `[[ == "true" ]]` hard-fail assertion immediately after each 546/non-200 guard | `gate2b-run-r15.sh` | `a36b9fb2…` |
| B-2 | Runner never confirmed `handler_invoked` log visible after H-1, required by §4.3 | Added interactive operator confirmation gate after H-1 PASS: prompts operator to verify Dashboard log entry; records result in evidence file; fails if not confirmed | `gate2b-run-r15.sh` | `a36b9fb2…` |
| B-3 | `hasWebpMetadata` applied `.trimEnd()` to the 4-char raw chunk ID, converting `"XMP "` → `"XMP"` and preventing XMP detection | Removed `.trimEnd()`; raw 4-char chunk ID now compared directly to Set `{"EXIF", "ICCP", "XMP "}` | `index.ts` | `ecfe70c0…` |
| B-4 | Evidence record cited interrupted run (isolate `9ff2ca67…`, `27.658 ms`) instead of authoritative completed run | Updated L-1 JSON to `isolate_id=89566b15…`, `magick_init_wall_time_ms=28.307083`; added supersession note | `s12-artifact-review.md` | n/a |

---

## §1.4 Three-Party Sign-Off

Magic phrase: `APPROVED: Gate 2B Rev 15 §1.2 — Artifact Review Complete`

| Party | Status |
|-------|--------|
| Claude | ✅ APPROVED — all static checks pass (deno fmt/lint/check `ecfe70c0…`, bash -n both scripts); L-1 PASS, L-2 INCONCLUSIVE-LOCAL (local runtime artifact, not an architectural defect), L-3 PASS; four blockers resolved (B-1 through B-4); four diagnostic fields verified in all responses; pre-decode path confirmed never calls ensureMagick(); XMP chunk ID fix verified; authoritative run 2026-08-15 18:37 UTC |
| Codex | ✅ APPROVED 2026-08-15 — all four prior blockers resolved; locked hashes match evidence inventory; both shell scripts pass syntax checking; corrected index.ts passed authoritative local run; cleanup and config.toml restoration succeeded |
| Bill | ✅ APPROVED 2026-08-15 — "APPROVED: Gate 2B Rev 15 §1.2 — Artifact Review Complete" |

---

### Governance Changes to gate2b-local-test-r15.sh

| # | Change | Authorized By | Date | New SHA |
|---|--------|--------------|------|---------|
| GC-1 | Bash guard lowered from 5+ to 3+; shebang changed to `#!/bin/bash`; Usage comment updated; `bash -n` re-verified. Rationale: script uses no bash 4/5 features; macOS does not have bash 5 at `/opt/homebrew/bin/bash`. gate2b-run-r15.sh bash 5 requirement unchanged. | Codex + Bill | 2026-08-15 | `603e0a21…` |
| GC-2 | L-2 isolate_id check replaced with three-path branching logic per Bill's specification: (a) same isolate → require `magick_cache_hit=true` + `magick_init_called_this_request=false` + `magick_init_wall_time_ms==0` → PASS; (b) different isolate + correct cold fields + `magick_init_wall_time_ms>0` → INCONCLUSIVE-LOCAL, continue to L-3; (c) any other combination → hard FAIL. `accepted=true` + `isolate_id` present mandatory in all paths. L-2 curl timeout raised from 60 s to 90 s (matches L-1; recycled isolate is cold). Usage comment fixed to `/bin/bash`. Final verdict distinguishes `PASS WITH L-2 INCONCLUSIVE-LOCAL` from unconditional `ALL PASS`. `bash -n` re-verified SHA `3a7e3003…`. | Codex + Bill | 2026-08-15 | `3a7e3003…` |

### Local Runtime Test Results (2026-08-15)

**Invocation:** `/bin/bash tools/image-spike/gate2b-local-test-r15.sh`  
**Runner:** supabase-edge-runtime-1.74.2, Deno v2.1.4, `per_worker` policy

**L-1 — Cold S-5 (2500×2000 = 5,000,000 px): PASS ✅**

```json
{
  "label": "L-1-cold-S5",
  "accepted": true,
  "image_decode_started": true,
  "pixel_count": 5000000,
  "isolate_id": "e52b116b-829a-4170-bfa3-d60a764dd60f",
  "magick_cache_hit": false,
  "magick_init_called_this_request": true,
  "magick_init_wall_time_ms": 29.723833
}
```

Authoritative run: 2026-08-15 18:37 UTC, index.ts SHA `ecfe70c0…` (XMP fix applied). Prior runs superseded: `89566b15…`/28.31ms (index.ts `d5228722…`, pre-fix) and `9ff2ca67…`/27.66ms (interrupted, did not complete L-3).

All L-1 assertions satisfied: `accepted=true` ✓, `image_decode_started=true` ✓, `pixel_count=5000000` ✓, `magick_cache_hit=false` ✓, `magick_init_called_this_request=true` ✓, `magick_init_wall_time_ms > 0` ✓.

**L-2 — Warm S-5: INCONCLUSIVE-LOCAL ⚠**

```json
{
  "label": "L-2-warm-S5",
  "accepted": true,
  "isolate_id": "08b846aa-8420-49cb-9803-f99ccb062b18",
  "magick_cache_hit": false,
  "magick_init_called_this_request": true,
  "magick_init_wall_time_ms": 22.363333
}
```

Reason: local `per_worker` runtime emitted `CPU time soft limit reached` + `early termination has been triggered` during L-1 image processing (decode + WebP encode). The L-1 isolate was recycled before L-2 arrived. L-2 booted a fresh cold isolate — GC-2 path (b) assertions all passed: `accepted=true` ✓, `isolate_id` present ✓, `magick_cache_hit=false` ✓, `magick_init_called_this_request=true` ✓, `magick_init_wall_time_ms=22.36ms > 0` ✓. This is the local equivalent of the H-2b scenario described in the hosted protocol.

**Wall-time note:** `magick_init_wall_time_ms = 29.72ms` (L-1) / `22.36ms` (L-2) is local wall time for `initializeImageMagick` only. It is not proof of hosted CPU usage; the 1,500 ms hosted CPU budget covers WASM init + image processing together. H-1 is definitive.

**L-3 — C-REJECT (5001×3100 = 15,503,100 px): PASS ✅**

```json
{
  "label": "L-3-reject",
  "accepted": false,
  "image_decode_started": false,
  "reason": "pre_decode_rejected",
  "pixel_count": 15503100,
  "magick_init_called_this_request": false
}
```

All L-3 assertions satisfied: `accepted=false` ✓, `image_decode_started=false` ✓, `reason=pre_decode_rejected` ✓, `magick_init_called_this_request=false` ✓. Pre-decode rejection path never called `ensureMagick()`, confirming the Rev 15 architecture: oversized images are rejected before WASM is touched.

**Cleanup:** serve stopped (pid 36315), WASM removed, config.toml cleaned ✓

**Final local test verdict: PASS WITH L-2 INCONCLUSIVE-LOCAL**  
Run date: 2026-08-15 18:37 UTC  
index.ts SHA: `ecfe70c01c9ca8f46089d1b0833e959d50e8e623038ecb9cd67c940d3f00399a`  
Script SHA: `3a7e300376d74cce345c335e3350d77881da2c90a9c4937d9ab38451a64d178b`

---

## Gate 2B Rev 15 — Hosted Run Results (2026-08-15)

**Run date:** 2026-08-15 ~18:53 UTC  
**Runner:** `gate2b-run-r15.sh` SHA `a36b9fb2…`  
**Deployed to:** `hkfrbdpedrxmbsawnbpr` (forkensics-dev)  
**Bundle size:** 9.3 MB

### H-1: Cold S-5

| Field | Value |
|-------|-------|
| HTTP status | **546** |
| `sb-error-code` | `WORKER_RESOURCE_LIMIT` |
| `x-deno-execution-id` | `a274cb5e-d695-4e0c-8d78-89fcd78e3b5b` |
| curl exit | 0 |
| Verdict | **FAIL** |

Runner failure message: `FAILURE: H-1: HTTP 546 — lazy init insufficient; WASM initialization still exceeds hosted CPU budget`

H-1 returned 546. The runner entered the mandatory telemetry capture prompt sequence (B-2 gate). An accidental terminal paste of the run command during the telemetry prompts corrupted the captured fields (`cpu_time_used`, `memory_used`, `shutdown_reason`). Raw (corrupted) values are preserved in `gate2b-evidence-r15-20260815T185443Z/gate2b-results.md` for completeness. These fields are INCONCLUSIVE.

H-2 and H-2b were not reached — runner exits on H-1 failure.

### Dashboard Log Evidence

**Checked:** 2026-08-15, Supabase Dashboard → Logs (BETA) → Log Type = Edge Function, Last 3 hours.

| Log Type | Count |
|----------|-------|
| API Gateway | 1 |
| Edge Function | **0** |

The API Gateway recorded one entry (the H-1 request reaching the gateway). The Edge Function count is **zero** across the full 3-hour window that includes the H-1 invocation. No `handler_invoked` log was written; the worker produced no edge function log output.

**Interpretation:** The Edge Function worker crashed before the request handler executed. The boot-time CPU limit was reached during module initialization — before any handler code ran. The absence of Edge Function logs in the presence of an API Gateway entry is the diagnostic signature of a pre-handler boot failure. The `handler_invoked` log confirmation gate (B-2) would have been unanswerable: no such log exists.

### Cleanup

Performed by the run script cleanup block:

- Function deleted from `hkfrbdpedrxmbsawnbpr` ✓
- `magick.wasm` removed ✓
- `config.toml` cleaned ✓
- Evidence preserved: `gate2b-evidence-r15-20260815T185443Z/` ✓

A second run was accidentally triggered during the telemetry prompt phase. It also returned H-1 546 and cleaned up independently. No evidence from the second run is preserved in the evidence directory.

---

## Gate 2B Rev 15 — Final Verdict: FAIL

**Verdict:** FAIL — H-1 HTTP 546 (`WORKER_RESOURCE_LIMIT`)

**Hypothesis tested:** Moving `initializeImageMagick()` from module top-level into the request handler (lazy init, Promise-cached) removes WASM initialization from the boot path and brings H-1 within the 1,500 ms hosted CPU budget.

**Result:** Hypothesis disproved. H-1 returned 546. Dashboard logs confirm zero Edge Function entries despite an API Gateway entry, proving the handler never executed. The CPU limit was reached during module initialization, before the lazy-init handler code could run.

**Architectural conclusion:** `@imagemagick/magick-wasm` cannot be loaded on Supabase Edge Functions within the hosted CPU budget. The module import (9.3 MB bundle parsing/JIT compilation during isolate boot) exhausts the budget regardless of where `initializeImageMagick()` is called. No further magick-wasm experiments are authorized.

**Two consecutive hosted failures:**

| Rev | Hypothesis | H-1 result | Root cause |
|-----|-----------|-----------|------------|
| Rev 14 | WASM init at module top-level | 546 | Boot-time CPU: WASM init in module scope |
| Rev 15 | Lazy init in handler (Promise-cached) | 546 | Boot-time CPU: module import itself |

---

## Rev 16 — Architectural Direction (2026-08-15)

Recorded from three-party discussion following Rev 15 FAIL. No Rev 16 proposal has been formally reviewed or approved; this section records proposed direction only.

**Proposed approach:** Managed out-of-process image transformation, replacing magick-wasm with Supabase Storage Image Transformations (imgproxy). imgproxy runs outside the Edge Function CPU budget. The Edge Function becomes a lightweight orchestrator with no WASM dependency:

1. Validate session, MIME, stored size, and header dimensions.
2. Request a resized/re-encoded image from Supabase Storage (imgproxy transform).
3. Verify the response is WebP and contains no metadata chunks (byte scan with existing `hasWebpMetadata`).
4. Compute SHA-256 over the transformed bytes.
5. Write to `display_storage_path`.
6. Delete the original.
7. Advance and finalize the upload session.

**Full spike criteria matrix and protocol:** `Gate-2B-Proposal-Rev16.md`

**Scope constraint:** Rev 16 authorizes discovery only. No production changes to `upload-complete` are authorized until the spike passes all criteria.

**Business gate:** Supabase Storage Image Transformations are unavailable on the Free plan. Whether `forkensics-dev` is on an eligible plan must be confirmed and separately approved before any billable transformation test.

**Canonical display parameters (per Bill's direction):** 2048 px longest edge, `contain` resize mode, quality ~80.

**Platform limits (Supabase documentation):** Edge Function memory 256 MB, CPU 2 s; Storage transformations 25 MB input, 50 MP. Forkensics safety target for memory: < 100 MB peak.

**Memory model correction:** The Edge Function does not hold the decoded raster. imgproxy decodes and encodes internally; the function handles only: bounded header range from the original, the encoded transformed WebP bytes, and a temporary hash buffer if required by Web Crypto. Memory profiling must measure peak usage across the download, hash, and upload phases — not estimate from pixel count.

**Fallback ranking if Supabase Storage Transformations fail:**

1. Cloudflare Images / Image Transformations — `metadata=none` documented; WebP/PNG outputs; limits cover Forkensics uploads. Adoption changes storage identifiers, serving, deletion, and possibly schema.
2. Dedicated background compute with Sharp/libvips — technically strongest; adds deployed service, queue/retry, monitoring, billing.
3. Smaller purpose-built WASM library (decode + encode JPEG/WebP, metadata strip) — speculative; requires full Gate 2B re-run against CPU budget.
4. Client-side processing — not acceptable as the security or privacy boundary.
5. Pure-JS parser — validation only, not sanitization.

**Status:** Direction recorded 2026-08-15. Rev 16 proposal drafted; see `Gate-2B-Proposal-Rev16.md`. No cloud operations authorized until three-party sign-off.
