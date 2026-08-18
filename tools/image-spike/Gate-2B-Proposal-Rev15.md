# Gate 2B Proposal — Rev 15
# Lazy Cached WASM Initialization — Controlled Hypothesis Test

**Date:** 2026-08-15  
**Status:** DRAFT — awaiting Codex review and three-party approval  
**Predecessor:** Gate-2B-Proposal-Rev14.md (APPROVED; hosted run FAIL — see §1.3 of s12-artifact-review.md)  
**Authorized project:** `hkfrbdpedrxmbsawnbpr` (forkensics-dev only)  
**No cloud operation or edit to `index.ts` is authorized until three-party sign-off.**

---

## 1. Rev 14 Failure Summary

Rev 14 deployed `image-spike` with `initializeImageMagick(wasmBytes)` called at module top-level. The first cold S-5 invocation returned:

| Field | Value |
|-------|-------|
| HTTP status | 546 |
| sb-error-code | `WORKER_RESOURCE_LIMIT` |
| execution_time_ms | 2,914 |
| Function console output | none |
| ShutdownEvent | not emitted |

No console output and no request handler invocation establish that the resource limit was reached during boot — before `serve()` fired. The specific exhausted resource (CPU, memory, or wall-clock) cannot be confirmed from available telemetry because no ShutdownEvent was emitted for this 546 termination. The 2,914 ms execution time is consistent with CPU exhaustion during WASM initialization, but this remains an inference.

---

## 2. Hypothesis

**Top-level WASM initialization is the failure mode.** Moving initialization inside the request handler — executed lazily on first use, cached for the lifetime of the isolate — removes WASM initialization from the boot path. The `per_worker` Edge Runtime policy allows an isolate to serve multiple requests, so the cache is effective after the first accepted request.

**This is a controlled experiment, not a confirmed fix.** Moving initialization inside the handler removes WASM initialization from the boot path. The initialization cost is relocated to the first accepted request. Supabase's documented per-request CPU limit is 2 seconds. Forkensics safety targets for the survey are 1,500 ms CPU and 200 MiB memory; these are project-defined thresholds, not platform limits. If cold-start initialization plus S-5 image processing together exceed the 2-second platform CPU budget, cold S-5 will still fail. A warm-only pass is insufficient for production.

---

## 3. Proposed Change to `index.ts`

**Scope:** `supabase/functions/image-spike/index.ts` only. No other files change.

### 3.1 Remove top-level initialization

Remove the two top-level await statements currently at module scope:

```typescript
// REMOVE from module top level:
const wasmBytes = await Deno.readFile(
  new URL("../_shared/magick.wasm", import.meta.url),
);
await initializeImageMagick(wasmBytes);
```

### 3.2 Add concurrency-safe Promise cache and `ensureMagick` helper

Add at module level, below imports:

```typescript
const isolateId = crypto.randomUUID();

let magickInitPromise: Promise<void> | undefined;
let magickInitialized = false;

function ensureMagick(): {
  promise: Promise<void>;
  startedThisRequest: boolean;
} {
  const startedThisRequest = !magickInitPromise;

  if (!magickInitPromise) {
    magickInitPromise = (async () => {
      const wasmBytes = await Deno.readFile(
        new URL("../_shared/magick.wasm", import.meta.url),
      );
      await initializeImageMagick(wasmBytes);
      magickInitialized = true;
    })().catch((error) => {
      magickInitPromise = undefined;
      magickInitialized = false;
      throw error;
    });
  }

  return { promise: magickInitPromise, startedThisRequest };
}
```

**Rationale for explicit `magickInitialized` flag alongside the Promise:** JavaScript cannot synchronously inspect whether a Promise is settled. `magickInitialized` is set to `true` only after `initializeImageMagick` resolves, enabling a synchronous `magick_cache_hit` read before any `await`. `startedThisRequest` captures whether this request was the one that created `magickInitPromise`, distinguishing first-caller from concurrent-waiter.

**Rationale for Promise cache over Boolean flag alone:** A Boolean alone permits concurrent cold requests to race and initialize WASM twice. The Promise cache ensures all concurrent callers await the same initialization. On error, both `magickInitPromise` and `magickInitialized` are reset so the next request retries cleanly.

**Rationale for retaining explicit `wasmBytes`:** The pinned `@imagemagick/magick-wasm@0.0.42` signature requires a `URL`, byte array, or `WebAssembly.Module`; there is no supported no-argument form. Rev 14's 2,914 ms execution time makes a missing-file error unlikely (a missing file would fail fast, not consume 2.9 s).

### 3.3 Call `ensureMagick()` inside the handler, after the pre-decode rejection check

In the request handler, the call order becomes:

1. Parse request / read body
2. `parseImageHeader` → extract pixel count
3. If `pixel_count > CANONICAL_PIXEL_LIMIT` → return rejection response immediately with `magick_init_called_this_request=false`; `ensureMagick()` is never called
4. Read `cacheHit = magickInitialized` synchronously (before any await)
5. Record `initStart = performance.now()`
6. Call `const { promise, startedThisRequest } = ensureMagick()`
7. `await promise`
8. Record `magick_init_wall_time_ms = startedThisRequest ? performance.now() - initStart : 0`
9. `ImageMagick.read(body, ...)` → process image

Diagnostic field mappings:
- `magick_cache_hit` ← `cacheHit` (synchronous read of `magickInitialized` before step 5)
- `magick_init_called_this_request` ← `startedThisRequest`
- `magick_init_wall_time_ms` ← computed in step 8

### 3.4 Diagnostic fields added to every response

Every response (accepted and rejected) must include:

| Field | Type | Description |
|-------|------|-------------|
| `isolate_id` | string (UUID) | Module-level random UUID; same value for all requests on the same isolate |
| `magick_cache_hit` | boolean | `true` if `magickInitPromise` was already settled when this request ran |
| `magick_init_called_this_request` | boolean | `true` if this request was the one that set `magickInitPromise` |
| `magick_init_wall_time_ms` | number | Wall time in ms for `ensureMagick()` call; ≈ 0 on cache hit; absent or 0 for rejected images |

These fields enable deterministic cache verification independent of timing.

---

## 4. Test Protocol

### 4.1 Pre-deployment static checks (§1.2)

| Check | Requirement |
|-------|-------------|
| `deno fmt --check index.ts` | PASS |
| `deno lint index.ts` | PASS |
| `deno check index.ts` | PASS |
| `gitleaks detect` | no findings |
| `bash -n gate2b-local-test-r15.sh` | PASS |
| `bash -n gate2b-run-r15.sh` | PASS |
| SHA recorded for all changed artifacts | required |

### 4.2 Local serve pre-flight (§1.2 local) — `gate2b-local-test-r15.sh`

A new local test script is required (see §7). The Rev 14 local script (`gate2b-local-test-r14.sh`) invokes S-5 once and does not cover cold/warm distinction, cache assertions, or the revised C-REJECT requirement.

Using `/opt/homebrew/bin/bash` (bash 5):

**Readiness gate:** The Rev 14 readiness probe sent requests to `image-spike` with an empty body. Under lazy initialization, any request to `image-spike` — including the empty-body probe — calls `ensureMagick()` and warms the WASM cache, invalidating the cold-start assertion on L-1. The Rev 15 local script must not send any request to `image-spike` before L-1. Readiness is established by: (1) `sleep 20` (matching GF-1), then (2) `kill -0 "$SERVE_PID"` to verify the serve process is still alive before proceeding. The polling curl loop must be removed entirely.

| Phase | Action | Pass Criteria |
|-------|--------|---------------|
| L-1 | Cold S-5 — first request to `image-spike` after serve starts (no prior invocation) | `accepted=true`, `image_decode_started=true`, `pixel_count=5000000`, `magick_cache_hit=false`, `magick_init_called_this_request=true`, `magick_init_wall_time_ms > 0` |
| L-2 | Warm S-5 — second request, same serve process | `accepted=true`, `isolate_id` == L-1 `isolate_id`, `magick_cache_hit=true`, `magick_init_called_this_request=false`, `magick_init_wall_time_ms` ≈ 0 |
| L-3 | C-REJECT (5001×3100) — on same serve process | `accepted=false`, `image_decode_started=false`, `reason=pre_decode_rejected`, `magick_init_called_this_request=false` |

Local warm/cold distinction is indicative only; the hosted run is definitive.

### 4.3 Hosted invocation protocol (§1.3) — `gate2b-run-r15.sh`

**Deploy once; do not delete between H-1, H-2, and H-3.**

**Pre-H-1 propagation delay:** After `supabase functions deploy` returns, wait a fixed interval (minimum 30 seconds) before sending H-1. No request to `image-spike` may be sent during this delay. This allows the hosted runtime to finish registering the deployment before the cold-start test begins.

| Phase | Action | Pass Criteria |
|-------|--------|---------------|
| H-1 | Cold S-5 — first POST after propagation delay, no prior warm-up | HTTP 200, `accepted=true`, `image_decode_started=true`, `pixel_count=5000000`, `magick_cache_hit=false`, `magick_init_called_this_request=true`, `handler_invoked` log visible in Logs |
| H-2 | Warm S-5 — immediately after H-1, same deployment | HTTP 200, `accepted=true`, `isolate_id` == H-1 `isolate_id`, `magick_cache_hit=true`, `magick_init_called_this_request=false` |
| H-3 | C-REJECT (5001×3100) — after H-1/H-2 on same deployment | HTTP 200, `accepted=false`, `reason=pre_decode_rejected`, `magick_init_called_this_request=false` |
| Cleanup | `supabase functions delete image-spike` + confirm not listed | required |

**H-2 cache verification is definitive, not timing-based.** The H-2 retry protocol is:

- If H-2 `isolate_id` == H-1 `isolate_id`: require `magick_cache_hit=true` → **PASS**
- If H-2 `isolate_id` ≠ H-1 `isolate_id`: H-2 landed on a fresh isolate; treat it as another cold invocation and retry once (H-2b)
  - If H-2b `isolate_id` == H-2 `isolate_id` and `magick_cache_hit=true` → **PASS** (warm on the second isolate confirmed)
  - If H-2b still lands on a different isolate or `magick_cache_hit=false` → verdict is **INCONCLUSIVE**, not architectural FAIL; isolate routing is outside the function's control

**H-3 C-REJECT placement:** H-3 runs after WASM is initialized on H-1. The `magick_init_called_this_request=false` assertion on the rejection response proves the pre-decode path does not call `ensureMagick()` regardless of isolate state.

**If any phase returns 546:** record `x-deno-execution-id`, retrieve ShutdownEvent (`reason`, `cpu_time_used`, `memory_used.*`, `boot_time`) from Log Explorer. If ShutdownEvent is not emitted, document as INCONCLUSIVE (consistent with Rev 14 finding). Halt and record FAIL.

### 4.4 Shutdown telemetry

**Mandatory for every 546.** Retrieve ShutdownEvent or document as INCONCLUSIVE.

**Best-effort for successful invocations.** An isolate may remain alive for multiple requests after H-1; the ShutdownEvent is not emitted until the isolate terminates. Do not fail a successful H-1 solely because no ShutdownEvent is available at test time. If ShutdownEvent is retrievable for H-1 (e.g., after isolate recycling), record `reason`, `cpu_time_used`, `memory_used.total`. This telemetry, if obtained, informs whether initialization + processing fits within the 2-second platform CPU limit and whether a full survey (Rev 16) is warranted.

---

## 5. Success Criteria

All of the following must hold:

1. H-1: HTTP 200, `accepted=true`, `image_decode_started=true`, `pixel_count=5000000`, `magick_cache_hit=false`, `magick_init_called_this_request=true`
2. H-2 warm cache verified via one of two paths:
   - **(a) H-2 same isolate:** H-2 `isolate_id` == H-1 `isolate_id`, HTTP 200, `magick_cache_hit=true`, `magick_init_called_this_request=false` → **PASS**
   - **(b) H-2b retry:** H-2 lands on a different isolate; H-2b `isolate_id` == H-2 `isolate_id`, HTTP 200, `magick_cache_hit=true`, `magick_init_called_this_request=false` → **PASS** (see §4.3 H-2 retry protocol)
3. H-3: HTTP 200, `accepted=false`, `reason=pre_decode_rejected`, `magick_init_called_this_request=false`
4. No 546 at any phase
5. Remote function deleted and confirmed not listed after test

**If all criteria met:** Gate 2B Rev 15 PASS. Proceed to Rev 16 (full survey S-5 through S-15 with lazy-init architecture) under new three-party governance.

---

## 6. Failure Criteria

| Condition | Verdict |
|-----------|---------|
| H-1 returns 546 | FAIL — lazy init insufficient; Supabase may be unsuitable; escalate to platform evaluation |
| H-2 returns 546 | FAIL — warm pass insufficient for production |
| H-2b still on different isolate or no cache hit (after one retry) | INCONCLUSIVE — isolate routing outside function control; not architectural FAIL |
| H-3 `magick_init_called_this_request=true` | FAIL — pre-decode rejection path invokes WASM init |
| H-1 ShutdownEvent shows resource-limit `reason` despite HTTP 200 | FAIL — marginal pass; telemetry overrides |
| Static checks or local pre-flight fail | blocked — fix before any deployment |

---

## 7. New and Changed Artifacts

### 7.1 `gate2b-local-test-r15.sh` (new)

A new local test script covering L-1 (cold S-5), L-2 (warm S-5), and L-3 (C-REJECT) with assertions on all four diagnostic fields. Must include:

- Bash 5 version guard: `[[ "${BASH_VERSINFO[0]}" -ge 5 ]] || { echo "FATAL: bash 5+ required"; exit 1; }`
- Invocation: `/opt/homebrew/bin/bash gate2b-local-test-r15.sh`
- All assertions fail-fast with `exit 1`
- Same WASM/config setup and cleanup as `gate2b-local-test-r14.sh` (GF-1 + GF-2 applied)

### 7.2 `gate2b-run-r15.sh` (new)

Replaces Rev 14's multi-phase survey runner. Simpler: single deploy → H-1 → H-2 → H-3 → telemetry prompts → delete → verify → verdict. Must include:

- Bash 5 version guard
- Assertion on `isolate_id` equality between H-1 and H-2
- Telemetry prompt after every 546 (mandatory) and after H-1 success (best-effort)
- No associative arrays (Rev 14 runner silently broke under macOS bash 3.2)

### 7.3 `index.ts` (revised)

Same file as Rev 14 but with:
- Top-level WASM init removed
- `isolateId`, `magickInitPromise`, `ensureMagick()` added
- Four diagnostic fields added to all responses
- `handler_invoked` log at top of handler

---

## 8. Governance Constraints

- `index.ts` must not be edited until three-party sign-off (Bill + Claude + Codex)
- No cloud operation until §1.2 (static + local) complete and signed off
- Authorized project: `hkfrbdpedrxmbsawnbpr` (forkensics-dev) exclusively
- `ANON_KEY` remains a runtime environment variable; never written to any file, echoed, or logged
- `CANONICAL_PIXEL_LIMIT` remains `15_500_000` for Rev 15 (survey value unchanged)
- Cleanup (remote delete + config.toml + `_shared/magick.wasm`) must complete and be confirmed

---

## 9. Artifact Inventory (to be completed at sign-off)

| File | SHA-256 | Notes |
|------|---------|-------|
| `supabase/functions/image-spike/index.ts` | TBD after edit | Rev 15 lazy-init version |
| `tools/image-spike/gate2b-local-test-r15.sh` | TBD | New local test script; bash 5 guard |
| `tools/image-spike/gate2b-run-r15.sh` | TBD | New hosted runner; bash 5 guard |
| `tools/image-spike/gate2b-local-test-r14.sh` | `f39010f43aae98389f264a723698a05cf945792c8e0071952e04f366d4b262a4` | Unchanged (GF-1+GF-2 applied) |
| `tools/image-spike/gate2b-fixtures-r14.py` | `cb6e10c8f95a2694e41a09a0bc386d8c1f80edcf10cfb2a58bfa80cee00e648b` | Unchanged |
| `tools/image-spike/gate2b-verify-input-metadata.py` | `15330f0d05dc3ae6b0f1ba783ebf89f60a158c893231effd29622d2841a8d509` | Unchanged |
| `tools/image-spike/gate2b-verify-metadata.py` | `44505b3bd21f8e859a9bcd241417ce564bf597233e1bd8747a449a49ee186008` | Unchanged |
| `tools/image-spike/magick.wasm` | `c903248c3b66a550b74bac5ea25d359e84455b8d82aa945a16f75f6fd8be610a` | Unchanged |

---

## 10. Open Items Before Sign-Off

| # | Item | Owner | Status |
|---|------|-------|--------|
| OI-1 | WASM loading path: retain `Deno.readFile` + explicit `wasmBytes` | Codex | ✅ Resolved by Codex; accepted by Bill 2026-08-15 |
| OI-2 | Write and static-check `gate2b-run-r15.sh` | Claude | Pending sign-off |
| OI-3 | Write and static-check `index.ts` Rev 15 | Claude | Pending sign-off |
| OI-4 | Write and static-check `gate2b-local-test-r15.sh` | Claude | Pending sign-off |
| OI-5 | Three-party sign-off: Bill + Claude + Codex | All | Pending |
