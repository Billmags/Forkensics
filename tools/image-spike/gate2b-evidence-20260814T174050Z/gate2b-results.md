# Gate 2B Results — Rev 9
Date: 2026-08-14T17:40:50Z
RESULTS_DIR: /Users/billschroeder/Desktop/WhatAndWhere/tools/image-spike/gate2b-evidence-20260814T174050Z
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
Phase 0 bundle: UNPARSEABLE → FAIL
deploy_output_head: NotFound: FileSystem.readFile (/Users/billschroeder/.supabase/profile)
Using access token for profile: supabase
Supabase CLI 2.111.0
Using profile: supabase (supabase.co)
Using access token for profile: supabase
2026/08/14 13:42:01 HTTP GET: https://api.supabase.com/v1/projects/torkgydbvktqebssfpdi/functions
Bundling Function: image-spike
DEBUG package.json auto-discovery is disabled
DEBUG No .npmrc file found
DEBUG Finished config loading.
DEBUG Opening cache /root/.cache/deno/dep_analysis_cache_v2...
DEBUG Opening cache /root/.cache/deno/node_analysis_cache_v2...
DEBUG Opening cache /root/.cache/deno/dep_analysis_cache_v2...
DEBUG Opening cache /root/.cache/deno/node_analysis_cache_v2...
DEBUG FileFetcher::fetch_no_follow_with_options - specifier: file:///Users/billschroeder/Desktop/WhatAndWhere/supabase/functions/image-spike/index.ts
DEBUG Running npm resolution.
DEBUG <package-req> - Resolved @imagemagick/magick-wasm@0.0.42 to @imagemagick/magick-wasm@0.0.42
DEBUG Building vfs with root '/root/.cache/deno/npm'
DEBUG Resolved package folder of @imagemagick/magick-wasm@0.0.42 to /root/.cache/deno/npm/registry.npmjs.org/@imagemagick/magick-wasm/0.0.42
DEBUG Ensuring directory '/root/.cache/deno/npm/registry.npmjs.org/@imagemagick/magick-wasm/0.0.42'
DEBUG Adding file '/root/.cache/deno/npm/registry.npmjs.org/@imagemagick/magick-wasm/0.0.42/README.md'
DEBUG Ensuring directory '/root/.cache/deno/npm/registry.npmjs.org/@imagemagick/magick-wasm/0.0.42'
DEBUG Adding file '/root/.cache/deno/npm/registry.npmjs.org/@imagemagick/magick-wasm/0.0.42/LICENSE'
DEBUG Ensuring directory '/root/.cache/deno/npm/registry.npmjs.org/@imagemagick/magick-wasm/0.0.42'
DEBUG Adding file '/root/.cache/deno/npm/registry.npmjs.org/@imagemagick/magick-wasm/0.0.42/NOTICE'
DEBUG Ensuring directory '/root/.cache/deno/npm/registry.npmjs.org/@imagemagick/magick-wasm/0.0.42'
DEBUG Ensuring directory '/root/.cache/deno/npm/registry.npmjs.org/@imagemagick/magick-wasm/0.0.42/dist'
DEBUG Adding file '/root/.cache/deno/npm/registry.npmjs.org/@imagemagick/magick-wasm/0.0.42/dist/index.js'
DEBUG Ensuring directory '/root/.cache/deno/npm/registry.npmjs.org/@imagemagick/magick-wasm/0.0.42/dist'
DEBUG Adding file '/root/.cache/deno/npm/registry.npmjs.org/@imagemagick/magick-wasm/0.0.42/dist/index.umd.cjs'
DEBUG Ensuring directory '/root/.cache/deno/npm/registry.npmjs.org/@imagemagick/magick-wasm/0.0.42/dist'
DEBUG Adding file '/root/.cache/deno/npm/registry.npmjs.org/@imagemagick/magick-wasm/0.0.42/dist/index.d.ts'
DEBUG Ensuring directory '/root/.cache/deno/npm/registry.npmjs.org/@imagemagick/magick-wasm/0.0.42/dist'
DEBUG Adding file '/root/.cache/deno/npm/registry.npmjs.org/@imagemagick/magick-wasm/0.0.42/dist/magick.wasm'
DEBUG Ensuring directory '/root/.cache/deno/npm/registry.npmjs.org/@imagemagick/magick-wasm/0.0.42/dist'
DEBUG Adding file '/root/.cache/deno/npm/registry.npmjs.org/@imagemagick/magick-wasm/0.0.42/package.json'
DEBUG Ensuring directory '/root/.cache/deno/npm/registry.npmjs.org/@imagemagick/magick-wasm/0.0.42'
DEBUG Flattening @imagemagick into node_modules
Deploying Function: image-spike (script size: 9.3 MB)
2026/08/14 13:42:03 HTTP POST: https://api.supabase.com/v1/projects/torkgydbvktqebssfpdi/functions
