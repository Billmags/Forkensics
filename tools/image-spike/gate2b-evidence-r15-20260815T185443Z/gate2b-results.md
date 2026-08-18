# Gate 2B Results — Rev 15
Date: 2026-08-15T18:54:43Z
PROJECT_REF: hkfrbdpedrxmbsawnbpr

## Fixture Preflight
S-5: test-S-5.jpg 2500x2000=5000000px sha256=3fda2e9358d0127a1060fab22991cf4a87be8466803790058eb4cf5fe65d92e9 ✓
C-REJECT: test-reject.jpg 5001x3100=15503100px sha256=60ba02826a0d6f06edfd853b16f27e9287fbfe151efa5a58711799291656dac6 ✓

## Artifact Hashes
magick.wasm sha256: c903248c3b66a550b74bac5ea25d359e84455b8d82aa945a16f75f6fd8be610a
index.ts sha256: ecfe70c01c9ca8f46089d1b0833e959d50e8e623038ecb9cd67c940d3f00399a
Static checks: deno fmt ✓  deno lint ✓  deno check ✓  gitleaks ✓
Three-party approval: YES

## Deploy
deploy exit: 0
bundle: 9.3 MB

## H-1: Cold S-5

### H-1
HTTP=546  curl_exit=0
x-deno-execution-id: a274cb5e-d695-4e0c-8d78-89fcd78e3b5b
sb-error-code: WORKER_RESOURCE_LIMIT
H-1: FAIL — 546
#### H-1 Telemetry
exec_id=3ZE7N5c \  cpu=/opt/homebrew/bin/bash tools/image-spike/gate2b-run-r15.shms  mem=JWT preflight: HS256, role=anon, ref=hkfrbdpedrxmbsawnbpr ✓B  reason==== Gate 2B Rev 15 Preflight ===
