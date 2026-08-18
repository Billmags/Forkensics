# Gate 2B Results — Rev 9
Date: 2026-08-14T18:03:46Z
RESULTS_DIR: /Users/billschroeder/Desktop/WhatAndWhere/tools/image-spike/gate2b-evidence-20260814T180346Z
PROJECT_REF: torkgydbvktqebssfpdi

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
curl_exit=0  HTTP=401  wall_time_s=0.797656
x-request-id: <not found>
FAIL: HTTP 401
B-03 cold_wall_time_s: 0.797656
B-03 run_id: MISSING
B-03 execution_id: INCONCLUSIVE
B-03 telemetry: INCONCLUSIVE → FAIL

## Phase 1 — Functional Matrix
Phase 1 bundle: 9.3MB

### B-01
curl_exit=0  HTTP=401  wall_time_s=0.507874
x-request-id: <not found>
FAIL: HTTP 401
B-01 phase1_wall_time_s: 0.507874

### B-02
curl_exit=0  HTTP=401  wall_time_s=0.698059
x-request-id: <not found>
FAIL: HTTP 401

### B-04
curl_exit=0  HTTP=401  wall_time_s=0.440459
x-request-id: <not found>
FAIL: HTTP 401

### B-05
curl_exit=0  HTTP=401  wall_time_s=0.459993
x-request-id: <not found>
FAIL: HTTP 401

### B-06
curl_exit=0  HTTP=401  wall_time_s=0.650710
x-request-id: <not found>
FAIL: HTTP 401

### B-07
curl_exit=0  HTTP=401  wall_time_s=0.557661
x-request-id: <not found>
FAIL: HTTP 401

## Final Verdict
Verdict: FAIL
Failures:
  - B-03: HTTP 401
  - B-03 telemetry INCONCLUSIVE
  - B-01: HTTP 401
  - B-02: HTTP 401
  - B-04: HTTP 401
  - B-05: HTTP 401
  - B-06: HTTP 401
  - B-07: HTTP 401
