# Gate 2B Results — Rev 9
Date: 2026-08-14T19:41:05Z
RESULTS_DIR: /Users/billschroeder/Desktop/WhatAndWhere/tools/image-spike/gate2b-evidence-20260814T194105Z
PROJECT_REF: hkfrbdpedrxmbsawnbpr

## Fixture Preflight
B-03: test-B-03.jpg 9911621B 5000x4000 sha256=efd993723c8718a13c5eaa2ad5614ceacb49a3177ab24383c8e96fc7e13c6c0a
B-01: test-B-01.jpg 4671249B 2500x2000 sha256=a6c0351dc391836bc5c9849a3c8f9d07d69c3d2d0062ee81f54892de004188be
B-02: test-B-02.jpg 9724898B 4000x2500 sha256=9d64622aead820a31a2c3a21b0532ca1e9a2828e5275f8d2288183a9f747d7f6
B-04: test-B-04.jpg 313626B 5001x4000 sha256=1bd55a9be8d62d96e5a74db4d291023bd736313ac2742e7a01b6189482f01f3a
B-05: test-B-05.jpg 1563126B 10000x10000 sha256=18b4b549cd59fd9680dafa615b87c47c5eef13f7a38367bf79e2f28235d3ae5d
B-06: test-B-06.webp 4799230B 2500x2000 sha256=5c7f87318bbf7b01aa3c12329f263ff3e8fce1ae6c7fcb83d6a0bd0e006e3c4d
B-07: test-B-07.jpg 375626B 6000x4000 sha256=181d3f13aafd328876a96276592a7d5971932ab58a535bd62eb8febde0733c1d

## Hashes
magick.wasm sha256: c903248c3b66a550b74bac5ea25d359e84455b8d82aa945a16f75f6fd8be610a
index.ts sha256: ff538bc2da7844b0f4b5b92618b360d0eb03ed7271ab513fee213e463edc4ea8

## Phase 0 — B-03 Telemetry
Phase 0 bundle: 9.3MB

### B-03
curl_exit=0  HTTP=546  wall_time_s=2.901795
x-request-id: <not found>
HARD FAIL: HTTP 546

## Post-Run Telemetry (retrieved via Supabase MCP from function_logs)
execution_id: 9af44ab2-1f72-4502-857b-8f89121b63f9
request_id: 01a001cb-1764-74ca-9031-b66ecb6f39c4
run_id (from invoke log): 2ae6440a-2962-41a9-b773-984fd47482bd
boot_time_ms: 44
cpu_time_used_ms: 2073
shutdown_reason: Memory
event_message: Memory limit exceeded
memory_used.total: 307607473 bytes (293.5 MiB) — limit 256 MiB — exceeded by 37.5 MiB
memory_used.external: 296984745 bytes (283.2 MiB)
memory_used.heap: 10622728 bytes (10.1 MiB)

## Final Verdict
Verdict: FAIL
Failures:
  - B-03: HTTP 546 — memory limit exceeded (293.5 MiB peak > 256 MiB limit)
  - B-03 telemetry INCONCLUSIVE (runner entered before telemetry retrieved — post-run retrieval above is authoritative)

## Architecture Finding
20MP image processing requires ~293.5 MiB peak memory. Supabase Edge Runtime limit is 256 MiB.
Cloudflare Workers limit is 128 MiB — would be worse.
Recommended path: Gate 2B Rev 10 with reduced pixel ceiling (target ~5 MP), plus mandatory iOS client-side downscaling.
