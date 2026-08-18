# Gate 2B — Cloudflare R2 + Images Binding Feasibility Spike
## Proposal Rev 3 — 2026-08-15

**Supersedes:** Rev 2 (not approved — 9 blockers + 3 smaller corrections, Codex SHA-256 `87c57101cf46e325cec25f1d7733091e350e3371c8c5d9763c6d49d475a0ffb6`)

---

## §1 Governance

### §1.1 Security Constraints (permanent — cannot be overridden)

- `CLOUDFLARE_API_TOKEN`, `SPIKE_SECRET`, and any Cloudflare credential never in client code, never in the repo, never sent to Claude.
- `ANON_KEY` and `SERVICE_ROLE_KEY` are runtime environment variables only; never written to any file, echoed, or logged.
- No cloud operation (bucket creation, Worker deploy, R2 write, `wrangler dev --remote`, transformation call) is authorized until §1.2 sign-off is complete.
- Three-party governance: **Bill + Claude + Codex** must all approve before any cloud operation or code edit against forkensics infrastructure.
- Authorized Supabase project: `hkfrbdpedrxmbsawnbpr` (forkensics-dev ONLY). `torkgydbvktqebssfpdi` (forkensics-prod) NEVER.
- Authorized Cloudflare account ID: `<CF_ACCOUNT_ID — to be filled in by Bill before execution>`. All spike resources use the suffix `-spike` and are removed at CF-P-12.

### §1.2 Three-Party Sign-Off

| Party | Status | Note |
|-------|--------|------|
| Claude | ⬜ pending | |
| Codex | ⬜ pending | |
| Bill | ⬜ pending | |

**No authorized operation begins until all three rows show ✅ COMPLETE.**

### §1.3 CF-P-0 Activation — Reconciliation

The Images & Stream plan was activated on 2026-08-15 before this proposal's §1.2 sign-off, as a zero-dollar account configuration action with no storage add-ons selected. Bill executed it directly in the Cloudflare Dashboard. No Worker code was deployed, no R2 bucket was created, no transformation was called, and no data was written. Recorded here as an already-completed prerequisite, not a read-only check.

---

## §2 Context

### §2.1 Why This Proposal Exists

Gate 2B Rev 15 returned HTTP 546 (Supabase pre-handler resource exhaustion; no Cloudflare equivalent). Dashboard logs confirmed zero Edge Function entries — `@imagemagick/magick-wasm` exhausts the hosted CPU budget during module import. Gate 2B Rev 20 closed as P-0 BLOCKED (Supabase Free plan excludes managed transformations). This proposal tests Fallback Rank 1: **Cloudflare R2 + Images binding**.

### §2.2 CF-P-0 — Images Plan Eligibility (COMPLETE — PASS, 2026-08-15)

| Check | Result |
|-------|--------|
| Images & Stream plan | ✅ Activated at $0/month (Bill, 2026-08-15) — no hosted storage |
| R2 binding on free Images tier | ✅ Confirmed — Cloudflare docs (2026-07-08): all users have access to the transformations feature for images stored in R2 |
| Free quota | 5,000 unique transformations/month; spike consumes ≤ 20 |
| Existing R2 bucket | None — creation is CF-P-1 |

### §2.3 CF-P-0b — Workers Plan Eligibility (authorized read-only step, execute before CF-P-2)

**Objective:** Record the account's Workers plan and the configured `cpu_ms` limit.

Workers resource exhaustion on Cloudflare is **Error 1102**, not HTTP 546. HTTP 546 is Supabase-specific and does not apply here.

**Actual Workers plan limits (B-1):**

| Workers Plan | CPU-time limit | Notes |
|-------------|---------------|-------|
| Free | **10 ms** per invocation | Hard limit; Error 1102 if exceeded |
| Paid ($5/month) | **30 seconds** default; configurable up to 5 minutes via `cpu_ms` in `wrangler.toml` | `cpu_ms` must be explicitly set or the default applies |

**Authorized read-only action:** Cloudflare Dashboard → Workers & Pages → Overview → confirm plan name. Record plan and effective CPU limit.

**Authorized API token scopes (minimum required for this spike):**

| Scope | Required for |
|-------|-------------|
| Workers Scripts:Edit | `wrangler deploy`, `wrangler delete` |
| Workers Scripts:Read | `wrangler deployments list` |
| R2:Edit | bucket create/delete, object put/delete |
| R2:Read | object list/get |
| Account Settings:Read | `wrangler whoami` account ID check |

**Evidence to capture:** Plan name and CPU limit from Dashboard.

**CF-P-8 PASS threshold:** CPU time < plan limit. If Workers Free and Worker JS CPU time approaches 10 ms during CF-P-8, upgrade to Workers Paid ($5/month) requires separate three-party approval before continuing. Note: I/O-waiting time (R2 reads, Images binding network call) does not count against Cloudflare CPU time; only JavaScript execution time is metered.

---

## §3 Architecture

### §3.1 Target Pipeline

```
iPhone
  │  presigned upload (PUT to R2 S3-compatible endpoint)
  ▼
Private R2 bucket: forkensics-dev-originals
  │
  ▼
Cloudflare Worker: forkensics-image-transform
  ├─ auth boundary
  ├─ R2 get (read 1) → ETag captured
  ├─ size gate: object.size > 10 MB → 422
  ├─ R2 get (read 2, ETag-matched) → .info() [free] → format, dimensions, fileSize
  ├─ format validation: accepted set only
  ├─ area gate: width * height > 15_500_000 → 422
  ├─ fileSize vs object.size consistency check
  ├─ R2 get (read 3, ETag-matched) → .transform().output({ anim: false }) → WebP
  ├─ validate response: status, Content-Type, nonempty body
  ├─ bounded stream read (≤ 5 MB + 1 byte ceiling)
  ├─ SHA-256 over output buffer
  ├─ R2 put: display/{basename}.webp
  └─ return 200 + headers
  │
  ▼
Supabase Edge Function: upload-finalize (future)
```

### §3.2 Spike Scope

Spike Worker: `forkensics-image-spike`. Spike bucket: `forkensics-dev-spike`. Both removed at CF-P-12. No production resources are created or modified.

---

## §4 Constraints

### §4.1 Input Limits
- `object.size > 10 MB` → reject before any billable call.
- Images binding `.input()` accepts up to 20 MB — Forkensics cap fits within.

### §4.2 Output Ceiling
- Sanitized output must be ≤ 5 MB; enforced by bounded stream read before R2 write.

### §4.3 Pixel Policy (B-2)
- Area ceiling: `width * height > 15_500_000` (15.5 MP) → reject. Uses safe integer arithmetic (no overflow risk at image dimensions).
- A per-side limit may be added separately if the product requires one. No per-side limit is established in this spike.

### §4.4 Format and Animation Policy (B-3)

**Accepted input formats** (validated against `info.format` from `.info()`):

```typescript
const ACCEPTED_FORMATS = new Set([
  "image/jpeg",
  "image/png",
  "image/webp",
  "image/heic",
  "image/avif",
]);
```

If `info.format` is not in this set → 422, no billable call.

**Animation policy:** `info.anim` is not publicly documented by Cloudflare. Rather than relying on an undocumented field, the Worker always sets `anim: false` in `.output()` options. This instructs Cloudflare to convert any animated input to a still image, making the output deterministically non-animated regardless of input. The generated types from `wrangler types` must confirm whether `anim` is a supported `.info()` field; if it is present and truthy for any fixture, that is additional evidence, but the `anim: false` output option is the enforcement mechanism in all cases.

**`info.fileSize` consistency (smaller correction):** If `wrangler types` reveals that `.info()` exposes `fileSize`, compare it against `object.size` from the first R2 read. If they disagree, return 422 without transformation. If the field is absent from the generated types, skip this check and note it in the evidence file.

### §4.5 Metadata Stripping
- Proven at byte level via ExifTool inspection. Not assumed.

### §4.6 Caching
- Workers Cache not tested in the spike. Transformation correctness is the gate.

### §4.7 Production Auth
- `SPIKE_SECRET` is a one-time random secret for the spike only.
- Production uses Cloudflare service token (Option A) or HMAC-SHA256 with replay protection (Option B). See §9 OQ-3.
- Supabase service-role JWT must never be transmitted to Cloudflare.

### §4.8 Wrangler Version and Command Verification (B-6)

Before Rev 3 is frozen for execution:
1. Install a pinned Wrangler version into the spike project: `npm install --save-dev wrangler@<pinned-version>`.
2. Use `./node_modules/.bin/wrangler` (not `npx wrangler`) throughout all scripts to guarantee version consistency.
3. Run `./node_modules/.bin/wrangler --help` and `./node_modules/.bin/wrangler r2 --help` to confirm every command used in this proposal is present and the flags match.
4. Record the output of `./node_modules/.bin/wrangler --version` in the evidence file before CF-P-1.

**Commands requiring pre-execution `--help` verification:**
- `wrangler init` (and whether a `--no-bundle`-equivalent flag exists; if not, scaffold manually)
- `wrangler types`
- `wrangler dev --remote`
- `wrangler deploy`
- `wrangler delete`
- `wrangler deployments list` (for Worker existence check — NOT `wrangler list`)
- `wrangler r2 bucket create / list / delete`
- `wrangler r2 object put / get / list / delete`
- `wrangler secret put`
- `wrangler whoami`

If `wrangler deployments list` does not accept a Worker-name filter, use the Cloudflare API (`GET /accounts/{account_id}/workers/scripts`) with the authorized token instead.

### §4.9 Cloudflare Account ID (B-5)

Bill must fill in `<CF_ACCOUNT_ID>` in §1.1 before execution. The runner verifies this before CF-P-1:

```bash
CF_ACCOUNT_ID="<fill-in>"  # set once, at top of runner
ACTUAL_ID=$(./node_modules/.bin/wrangler whoami --json 2>/dev/null \
  | jq -r '.accounts[0].id // empty')
if [ "$ACTUAL_ID" != "$CF_ACCOUNT_ID" ]; then
  echo "FAIL: Account mismatch. Aborting."
  exit 1
fi
echo "Account verified: $CF_ACCOUNT_ID"
```

---

## §5 Probe Sequence

**Probes execute in order. Any FAIL stops the sequence. The runner EXIT trap (§5.0) fires on every exit — success, failure, interruption, or timeout — and attempts cleanup regardless. Cleanup failure is recorded separately and does not mask the original test result.**

---

### §5.0 — Runner Preflight and EXIT Trap

**Install EXIT trap and globals first, before any cloud operation.**

```bash
#!/usr/bin/env bash
set -euo pipefail

# ── Globals ──────────────────────────────────────────────────────────────────
CF_ACCOUNT_ID="<fill-in>"          # §4.9
BUCKET="forkensics-dev-spike"
WORKER="forkensics-image-spike"
WRANGLER="./node_modules/.bin/wrangler"
DEV_PID=""
ORIGINAL_EXIT=0
CLEANUP_STATUS="NOT_RUN"

# ── EXIT trap ─────────────────────────────────────────────────────────────────
cleanup() {
  ORIGINAL_EXIT=$?
  CLEANUP_FAILED=false
  echo "[CLEANUP] Starting — $(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # 1. Terminate wrangler dev if running
  if [ -n "$DEV_PID" ] && kill -0 "$DEV_PID" 2>/dev/null; then
    kill "$DEV_PID" 2>/dev/null || true
    wait "$DEV_PID" 2>/dev/null || true
    echo "[CLEANUP] wrangler dev terminated (PID $DEV_PID)"
  fi

  # 2. Delete .dev.vars
  rm -f .dev.vars && echo "[CLEANUP] .dev.vars removed" || true

  # 3. Undeploy Worker
  if "$WRANGLER" delete "$WORKER" --force 2>/dev/null; then
    echo "[CLEANUP] Worker undeployed"
  else
    echo "[CLEANUP] WARNING: Worker deletion returned non-zero"
    CLEANUP_FAILED=true
  fi

  # 4. Verify Worker gone (using documented list command verified in §4.8)
  if "$WRANGLER" deployments list --name "$WORKER" 2>/dev/null | grep -q "$WORKER"; then
    echo "[CLEANUP] WARNING: Worker still visible after deletion"
    CLEANUP_FAILED=true
  else
    echo "[CLEANUP] Worker confirmed absent"
  fi

  # 5. Delete all known spike objects
  for KEY in \
    "spike/fixture-exif.jpg" \
    "spike/fixture-icc.png" \
    "spike/fixture-oversized.jpg" \
    "display/fixture-exif.jpg.webp" \
    "display/fixture-icc.png.webp"; do
    if "$WRANGLER" r2 object delete "$BUCKET" "$KEY" 2>/dev/null; then
      echo "[CLEANUP] Deleted: $KEY"
    else
      echo "[CLEANUP] WARNING: Failed to delete $KEY (may not exist)"
      # Non-existence is acceptable; other errors are not — note but continue
    fi
  done

  # 6. Verify zero objects (fail if jq produces non-numeric output)
  RAW_LIST=$("$WRANGLER" r2 object list "$BUCKET" --json 2>/dev/null || echo "[]")
  REMAINING=$(echo "$RAW_LIST" | jq 'if type == "array" then length else -1 end' 2>/dev/null || echo "-1")
  if [ "$REMAINING" = "0" ]; then
    echo "[CLEANUP] Zero objects confirmed"
  elif [ "$REMAINING" = "-1" ]; then
    echo "[CLEANUP] WARNING: Could not parse object list — REMOTE_CLEANUP_REQUIRED"
    CLEANUP_FAILED=true
  else
    echo "[CLEANUP] WARNING: $REMAINING object(s) remain — REMOTE_CLEANUP_REQUIRED"
    CLEANUP_FAILED=true
  fi

  # 7. Delete bucket
  if "$WRANGLER" r2 bucket delete "$BUCKET" 2>/dev/null; then
    echo "[CLEANUP] Bucket deleted"
  else
    echo "[CLEANUP] WARNING: Bucket deletion returned non-zero"
    CLEANUP_FAILED=true
  fi

  # 8. Verify bucket gone
  if "$WRANGLER" r2 bucket list 2>/dev/null | grep -q "$BUCKET"; then
    echo "[CLEANUP] WARNING: Bucket still visible — REMOTE_CLEANUP_REQUIRED"
    CLEANUP_FAILED=true
  else
    echo "[CLEANUP] Bucket confirmed absent"
  fi

  # 9. Final status
  if [ "$CLEANUP_FAILED" = "true" ]; then
    CLEANUP_STATUS="REMOTE_CLEANUP_REQUIRED"
    echo "[CLEANUP] Status: REMOTE_CLEANUP_REQUIRED — manual verification needed"
    # Preserve original exit code if non-zero; otherwise exit 1 for cleanup failure
    [ "$ORIGINAL_EXIT" -ne 0 ] && exit "$ORIGINAL_EXIT" || exit 1
  else
    CLEANUP_STATUS="REMOTE_CLEANUP_CONFIRMED"
    echo "[CLEANUP] Status: REMOTE_CLEANUP_CONFIRMED"
    exit "$ORIGINAL_EXIT"
  fi
}
trap cleanup EXIT

# ── Preflight checks (local only — no cloud operations yet) ───────────────────

echo "[PREFLIGHT] Wrangler version: $($WRANGLER --version)"

# jq present
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq not installed"; exit 1; }

# exiftool present
command -v exiftool >/dev/null 2>&1 || { echo "FAIL: exiftool not installed"; exit 1; }

# SPIKE_SECRET set
[ -n "${SPIKE_SECRET:-}" ] || { echo "FAIL: SPIKE_SECRET not set"; exit 1; }
echo "[PREFLIGHT] SPIKE_SECRET: set (not printed)"

# CLOUDFLARE_API_TOKEN set
[ -n "${CLOUDFLARE_API_TOKEN:-}" ] || { echo "FAIL: CLOUDFLARE_API_TOKEN not set"; exit 1; }
echo "[PREFLIGHT] CLOUDFLARE_API_TOKEN: set (not printed)"

# Account ID verification (§4.9)
ACTUAL_ID=$("$WRANGLER" whoami --json 2>/dev/null | jq -r '.accounts[0].id // empty')
[ "$ACTUAL_ID" = "$CF_ACCOUNT_ID" ] || {
  echo "FAIL: Account mismatch (expected $CF_ACCOUNT_ID, got $ACTUAL_ID)"
  exit 1
}
echo "[PREFLIGHT] Account ID verified: $CF_ACCOUNT_ID"

# No pre-existing bucket
if "$WRANGLER" r2 bucket list 2>/dev/null | grep -q "$BUCKET"; then
  echo "FAIL: Bucket $BUCKET already exists — manual cleanup required"
  exit 1
fi

# No pre-existing Worker deployment
if "$WRANGLER" deployments list --name "$WORKER" 2>/dev/null | grep -q "$WORKER"; then
  echo "FAIL: Worker $WORKER already deployed — manual cleanup required"
  exit 1
fi

echo "[PREFLIGHT] All checks passed. Proceeding to CF-P-1."
```

---

### CF-P-1 — R2 Bucket Creation

**Authorized cloud operation.**

```bash
"$WRANGLER" r2 bucket create "$BUCKET"
"$WRANGLER" r2 bucket list | grep "$BUCKET"
```

Confirm no `r2.dev` public URL is enabled (Dashboard check — public access is off by default).

**Pass:** Bucket present in list, public access disabled.
**Fail:** Creation error, or public access found enabled.

---

### CF-P-2 — Worker Scaffolding and Type Generation (local only)

**Local operation — no cloud deployment.**

Scaffold the project (if `wrangler init` flags verified in §4.8 are unsuitable, create files manually):

**`wrangler.toml`:**
```toml
name = "forkensics-image-spike"
main = "src/index.ts"
compatibility_date = "2026-08-15"

[images]
binding = "IMAGES"

[[r2_buckets]]
binding         = "BUCKET"
bucket_name         = "forkensics-dev-spike"
preview_bucket_name = "forkensics-dev-spike"

[secrets]
# SPIKE_SECRET injected via `wrangler secret put` — not in this file
```

Run type generation and static check:
```bash
"$WRANGLER" types           # generates worker-configuration.d.ts
tsc --noEmit                # must exit 0 with zero errors
```

Confirm `worker-configuration.d.ts` contains typed definitions for `BUCKET`, `IMAGES`, and `SPIKE_SECRET`. If `IMAGES` type exposes `.info()` return shape, record whether `anim` and `fileSize` fields are present — update §4.4 accordingly.

**Evidence to capture:** `wrangler types` output, `tsc --noEmit` output (zero errors).

**Pass:** `tsc --noEmit` exits 0, zero errors, no `any` in `Env`.
**Fail:** Any type error, missing binding, build failure.

---

### CF-P-3 — Fixture Upload to Spike Bucket

**Authorized cloud operations.**

**Fixtures:**
| Local path | R2 key | Format | Approximate size | Contains |
|------------|--------|--------|-----------------|----------|
| `fixtures/fixture-exif.jpg` | `spike/fixture-exif.jpg` | JPEG | ~500 KB | GPS + EXIF metadata |
| `fixtures/fixture-icc.png` | `spike/fixture-icc.png` | PNG | ~300 KB | ICC color profile |
| `fixtures/fixture-oversized.jpg` | `spike/fixture-oversized.jpg` | JPEG | > 10 MB | Proves size rejection |

```bash
"$WRANGLER" r2 object put "$BUCKET/spike/fixture-exif.jpg" \
  --file ./fixtures/fixture-exif.jpg
"$WRANGLER" r2 object put "$BUCKET/spike/fixture-icc.png" \
  --file ./fixtures/fixture-icc.png
"$WRANGLER" r2 object put "$BUCKET/spike/fixture-oversized.jpg" \
  --file ./fixtures/fixture-oversized.jpg

"$WRANGLER" r2 object list "$BUCKET" --prefix spike/  # all three keys present
```

**Pass:** All three keys in listing.
**Fail:** Any upload error; any key absent.

---

### CF-P-4 — Local Transformation Test (`wrangler dev --remote`)

**Authorized cloud operation.** `wrangler dev --remote` uploads code to a Cloudflare-hosted ephemeral preview using `preview_bucket_name`. This is explicitly authorized here. The preview session is terminated by the EXIT trap.

**Inject secret via `.dev.vars` (B-4):**
```bash
# Write secret to .dev.vars — file stays outside git tracking (.gitignore must exclude it)
printf 'SPIKE_SECRET=%s\n' "$SPIKE_SECRET" > .dev.vars
chmod 0600 .dev.vars
# EXIT trap deletes .dev.vars on any exit
```

**Start remote dev with bounded readiness polling (B-7):**
```bash
"$WRANGLER" dev --remote src/index.ts &
DEV_PID=$!

# Bounded readiness poll — max 30 seconds
READY=false
for i in $(seq 1 30); do
  if ! kill -0 "$DEV_PID" 2>/dev/null; then
    echo "FAIL: wrangler dev process died"
    exit 1
  fi
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
    --max-time 2 \
    -H "Authorization: Bearer $SPIKE_SECRET" \
    http://localhost:8787/transform/spike/fixture-exif.jpg 2>/dev/null || echo "000")
  # Any non-connection-refused code means the server is up
  if [ "$STATUS" != "000" ]; then
    READY=true
    break
  fi
  sleep 1
done
[ "$READY" = "true" ] || { echo "FAIL: wrangler dev not ready after 30s"; exit 1; }
```

**Test A — oversized input (422 expected, no transform charged, no display key written):**
```bash
STATUS_A=$(curl -s -o /dev/null -w "%{http_code}" --max-time 30 \
  -H "Authorization: Bearer $SPIKE_SECRET" \
  http://localhost:8787/transform/spike/fixture-oversized.jpg)
echo "Test A status: $STATUS_A (expected 422)"
[ "$STATUS_A" = "422" ] || { echo "FAIL: expected 422, got $STATUS_A"; exit 1; }

# Verify no display key was written (smaller correction)
DISPLAY_COUNT=$("$WRANGLER" r2 object list "$BUCKET" --prefix display/ --json \
  | jq 'if type=="array" then length else -1 end')
[ "$DISPLAY_COUNT" = "0" ] || { echo "FAIL: display key written for oversized input"; exit 1; }
```

**Test B — JPEG with EXIF:**
```bash
curl -s --max-time 60 \
  -H "Authorization: Bearer $SPIKE_SECRET" \
  -D cf_p4_jpeg_headers.txt \
  -o cf_p4_jpeg_output.webp \
  http://localhost:8787/transform/spike/fixture-exif.jpg
```

**Test C — PNG with ICC:**
```bash
curl -s --max-time 60 \
  -H "Authorization: Bearer $SPIKE_SECRET" \
  -D cf_p4_png_headers.txt \
  -o cf_p4_png_output.webp \
  http://localhost:8787/transform/spike/fixture-icc.png
```

**Terminate dev process:**
```bash
kill "$DEV_PID" 2>/dev/null || true
wait "$DEV_PID" 2>/dev/null || true
DEV_PID=""
```

**Evidence to capture (Tests B and C):**
- HTTP status (must be 200).
- `Content-Type` header from `-D` dump (must be `image/webp`).
- `X-Forkensics-SHA256` header value.
- `X-Forkensics-Size` header value.
- Output file size in bytes (`wc -c`).
- Worker console CPU time (preliminary evidence; definitive CPU evidence is CF-P-8 hosted analytics).

**Pass (Test A):** 422, zero display objects in R2.
**Pass (Tests B, C):** 200, `image/webp`, `X-Forkensics-SHA256` present, 0 < size ≤ 5,242,880.
**Fail:** Any unexpected status, wrong content type, missing header, size > 5 MB, Worker exception.

---

### CF-P-5 — Metadata Stripping Verification

```bash
exiftool cf_p4_jpeg_output.webp
exiftool cf_p4_png_output.webp
```

**Prohibited metadata families (both outputs):**
| Family | Pass if |
|--------|---------|
| EXIF (Make, Model, GPS*, DateTimeOriginal, …) | Zero tags |
| XMP (all namespaces) | Zero tags |
| ICC_Profile | Zero tags |
| Comment (ImageDescription, UserComment) | Zero tags |

Structural properties (File Size, Image Width, Image Height, Bit Depth, Color Type) are permitted — ExifTool always reports these.

**Pass:** Zero prohibited families in both outputs.
**Fail:** Any prohibited tag present in either output.
**Inconclusive:** ExifTool unavailable — install and re-run; do not advance.

---

### CF-P-6 — Output WebP Structural Verification

Applied to both `cf_p4_jpeg_output.webp` and `cf_p4_png_output.webp`.

1. **RIFF header:** bytes 0–3 = `52 49 46 46`; bytes 8–11 = `57 45 42 50`.
2. **Exact RIFF size (B-12):** `riff_size = uint32LE(bytes[4..8])`. Require: `actual_file_size == riff_size + 8`. No extra bytes permitted.
3. **Chunk data region:** `bytes[12..riff_size+8)`.
4. **Valid chunk sequences (exactly one of five):**
   - `VP8 ` — simple lossy
   - `VP8L` — lossless (alpha may be embedded in bitstream)
   - `VP8X` + `VP8 ` — extended lossy
   - `VP8X` + `ALPH` + `VP8 ` — extended lossy with alpha
   - `VP8X` + `VP8L` — extended lossless
   - `ALPH` + `VP8L` is **forbidden**.
5. **VP8X flags (if VP8X present):** `flags_u32 = uint32LE(VP8X_data[0..4])`. Require: `(flags_u32 & ~0x00000010) === 0`. Only Alpha (`0x10`) permitted. Animation (`0x02`), XMP (`0x04`), EXIF (`0x08`), ICC (`0x20`) must all be zero.

**Evidence to capture:** Hex dump bytes 0–15, RIFF declared vs. actual size, chunk sequence, VP8X flags (if present).

**Pass:** All five checks pass for both outputs.
**Fail:** Invalid header, size mismatch, forbidden sequence, forbidden VP8X flag bits.

---

### CF-P-7 — SHA-256 Integrity

```bash
shasum -a 256 cf_p4_jpeg_output.webp
shasum -a 256 cf_p4_png_output.webp
```

Compare each against the corresponding `X-Forkensics-SHA256` header from CF-P-4.

**Pass:** Both pairs match exactly.
**Fail:** Any mismatch, header absent, or empty hash.

---

### CF-P-8 — Worker CPU Budget

**Objective:** Confirm Worker JS CPU time fits within the plan limit confirmed in CF-P-0b.

**Primary evidence — hosted Worker analytics (CF-P-9):**  
After deploying in CF-P-9, check Cloudflare Dashboard → Workers → `forkensics-image-spike` → Analytics for CPU time per invocation. This is the definitive measurement.

**Preliminary evidence — remote-dev console (CF-P-4):**  
Worker console CPU time from CF-P-4 is preliminary and collected here. If CF-P-4 preliminary CPU time already exceeds the plan limit, FAIL immediately and do not proceed to CF-P-9.

**Pass/fail thresholds (B-1):**

| Workers Plan | CPU time | Result |
|-------------|----------|--------|
| Free | < 10 ms | PASS |
| Free | ≥ 10 ms | FAIL |
| Paid | < `cpu_ms` limit | PASS |
| Paid | ≥ `cpu_ms` limit | FAIL |

Cloudflare Error 1102 (not HTTP 546) indicates CPU exhaustion on Workers. Note: I/O-waiting time (R2 reads, Images binding network round-trip) is not counted as CPU time.

**Evidence to capture:** Preliminary CPU time from CF-P-4 console; definitive CPU time from hosted analytics after CF-P-9.

---

### CF-P-9 — Hosted Worker Deploy

**Inject SPIKE_SECRET as a Worker secret before deploying (B-4):**
```bash
# Secret must be set before deploy so the Worker is never callable without it
printf '%s' "$SPIKE_SECRET" | "$WRANGLER" secret put SPIKE_SECRET
# Then deploy
"$WRANGLER" deploy
```

**Test (JPEG fixture — PNG already confirmed in CF-P-4):**
```bash
WORKER_URL="https://${WORKER}.<account>.workers.dev"
curl -s --max-time 60 \
  -H "Authorization: Bearer $SPIKE_SECRET" \
  -D cf_p9_hosted_headers.txt \
  -o cf_p9_hosted_output.webp \
  "${WORKER_URL}/transform/spike/fixture-exif.jpg"
```

**Evidence:** Status, `Content-Type`, `X-Forkensics-SHA256`, `X-Forkensics-Size`, `shasum -a 256 cf_p9_hosted_output.webp` vs header.

**Pass:** 200, `image/webp`, SHA-256 matches, size ≤ 5 MB.
**Fail:** Non-200, wrong type, SHA mismatch, size > 5 MB, Error 1102.

**After CF-P-9:** Collect hosted CPU analytics for CF-P-8 (see above).

---

### CF-P-10 — Auth Boundary

```bash
WORKER_URL="https://${WORKER}.<account>.workers.dev"

STATUS_NO_AUTH=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
  "${WORKER_URL}/transform/spike/fixture-exif.jpg")
STATUS_WRONG=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
  -H "Authorization: Bearer wrongtoken" \
  "${WORKER_URL}/transform/spike/fixture-exif.jpg")

echo "No-auth: $STATUS_NO_AUTH (expected 401)"
echo "Wrong-token: $STATUS_WRONG (expected 401)"

[ "$STATUS_NO_AUTH" = "401" ] || { echo "FAIL: unauthenticated request not rejected"; exit 1; }
[ "$STATUS_WRONG" = "401" ] || { echo "FAIL: wrong token not rejected"; exit 1; }
```

**Pass:** Both return 401.
**Fail:** Either returns 200.

---

### CF-P-11 — Write-Back Persistence Verification

Display keys from write-back during CF-P-4 (local/remote preview) and CF-P-9 (hosted). Worker derives: `display/${key.split('/').pop()}.webp`.

| Input key | Display key |
|-----------|-------------|
| `spike/fixture-exif.jpg` | `display/fixture-exif.jpg.webp` |
| `spike/fixture-icc.png` | `display/fixture-icc.png.webp` |

```bash
"$WRANGLER" r2 object list "$BUCKET" --prefix display/  # both keys must appear

# Download and verify hosted display object
"$WRANGLER" r2 object get "$BUCKET/display/fixture-exif.jpg.webp" \
  --file cf_p11_display_verify.webp
shasum -a 256 cf_p11_display_verify.webp
# Must match X-Forkensics-SHA256 from CF-P-9
```

**Pass:** Both display keys present, SHA-256 of hosted display object matches CF-P-9 header.
**Fail:** Either key absent, SHA mismatch, download error.

---

### CF-P-12 — Cleanup

The EXIT trap (§5.0) handles cleanup automatically. CF-P-12 is the explicit success-path cleanup. It is idempotent with the trap.

```bash
# 1. Undeploy Worker first
"$WRANGLER" delete "$WORKER" --force

# 2. Verify Worker absent
"$WRANGLER" deployments list --name "$WORKER" | grep -v "$WORKER" \
  || { echo "FAIL: Worker still listed"; exit 1; }

# 3. Delete spike objects
for KEY in \
  "spike/fixture-exif.jpg" \
  "spike/fixture-icc.png" \
  "spike/fixture-oversized.jpg" \
  "display/fixture-exif.jpg.webp" \
  "display/fixture-icc.png.webp"; do
  "$WRANGLER" r2 object delete "$BUCKET" "$KEY"
done

# 4. Assert zero objects
COUNT=$("$WRANGLER" r2 object list "$BUCKET" --json \
  | jq 'if type=="array" then length else -1 end')
[ "$COUNT" = "0" ] || { echo "FAIL: $COUNT object(s) remain after deletion"; exit 1; }

# 5. Delete bucket
"$WRANGLER" r2 bucket delete "$BUCKET"

# 6. Assert bucket gone
"$WRANGLER" r2 bucket list | grep -v "$BUCKET" \
  || { echo "FAIL: Bucket still listed after deletion"; exit 1; }

echo "CF-P-12: REMOTE_CLEANUP_CONFIRMED"
```

**Pass:** Worker absent, zero objects, bucket absent — `REMOTE_CLEANUP_CONFIRMED`.
**Fail:** Any object remaining, Worker still listed, bucket still present.

---

## §6 Authoritative Worker Code

```typescript
// src/index.ts — forkensics-image-spike Rev 3
// SPIKE ONLY — not production code

// Env interface is generated by `wrangler types` into worker-configuration.d.ts.
// Do not use `any`.

const MAX_INPUT_BYTES  = 10 * 1024 * 1024; // 10 MB — Forkensics upload cap
const MAX_OUTPUT_BYTES =  5 * 1024 * 1024; // 5 MB  — sanitized display ceiling
const MAX_PIXELS       = 15_500_000;        // 15.5 MP area ceiling (B-2)

// Accepted input formats — validated before any billable transform (B-3)
const ACCEPTED_FORMATS = new Set([
  "image/jpeg",
  "image/png",
  "image/webp",
  "image/heic",
  "image/avif",
]);

export default {
  async fetch(request: Request, env: Env): Promise<Response> {

    // ── Auth boundary ──────────────────────────────────────────────────────
    const auth = request.headers.get("Authorization") ?? "";
    if (auth !== `Bearer ${env.SPIKE_SECRET}`) {
      return new Response("Unauthorized", { status: 401 });
    }

    // ── Route: GET /transform/{key} ────────────────────────────────────────
    const url = new URL(request.url);
    const key = url.pathname.replace(/^\/transform\//, "").trim();
    if (!key || key.includes("..") || key.startsWith("/")) {
      return new Response("Invalid key", { status: 400 });
    }

    // ── Read 1: R2 fetch + size gate ───────────────────────────────────────
    const object = await env.BUCKET.get(key);
    if (!object) {
      return new Response("Not found", { status: 404 });
    }
    const etag = object.etag; // capture for ETag-matched subsequent reads (B-9)
    if ((object.size ?? 0) > MAX_INPUT_BYTES) {
      return new Response(
        `Input too large: ${object.size} bytes (max ${MAX_INPUT_BYTES})`,
        { status: 422 }
      );
    }

    // ── Read 2: .info() — free, no quota (B-3, smaller correction) ────────
    const infoObject = await env.BUCKET.get(key, {
      onlyIf: { etagMatches: etag },
    });
    if (!infoObject) {
      return new Response("Input changed between reads", { status: 409 });
    }

    let info: { format: string; width: number; height: number; fileSize?: number; anim?: boolean };
    try {
      info = await env.IMAGES.info(infoObject.body) as typeof info;
    } catch (err) {
      return new Response(`Info error: ${err}`, { status: 422 });
    }

    // Format validation
    if (!ACCEPTED_FORMATS.has(info.format)) {
      return new Response(`Unsupported format: ${info.format}`, { status: 422 });
    }

    // Pixel area ceiling — overflow-safe (no BigInt needed: 15.5M << MAX_SAFE_INTEGER)
    if (info.width * info.height > MAX_PIXELS) {
      return new Response(
        `Image ${info.width}×${info.height} = ${info.width * info.height}px exceeds ` +
        `${MAX_PIXELS}px area ceiling`,
        { status: 422 }
      );
    }

    // fileSize consistency (if Cloudflare exposes it — smaller correction)
    if (typeof info.fileSize === "number" && info.fileSize !== object.size) {
      return new Response(
        `File size mismatch: R2=${object.size}, info.fileSize=${info.fileSize}`,
        { status: 422 }
      );
    }

    // ── Read 3: Transform (ETag-matched — B-9) ─────────────────────────────
    const transformObject = await env.BUCKET.get(key, {
      onlyIf: { etagMatches: etag },
    });
    if (!transformObject) {
      return new Response("Input changed between reads", { status: 409 });
    }

    let transformResponse: Response;
    try {
      transformResponse = (
        await env.IMAGES.input(transformObject.body)
          .transform({ width: 1280, height: 1280, fit: "scale-down" })
          .output({ format: "image/webp", quality: 85, anim: false }) // anim:false always (B-3)
      ).response();
    } catch (err) {
      return new Response(`Transform error: ${err}`, { status: 500 });
    }

    // ── Validate transform response before buffering ───────────────────────
    if (!transformResponse.ok) {
      return new Response(
        `Transform returned non-OK: ${transformResponse.status}`,
        { status: 502 }
      );
    }
    const ct = transformResponse.headers.get("Content-Type") ?? "";
    if (!ct.includes("image/webp")) {
      return new Response(`Unexpected Content-Type: ${ct}`, { status: 502 });
    }
    if (!transformResponse.body) {
      return new Response("Transform returned empty body", { status: 502 });
    }

    // ── Bounded stream read — ceiling enforced before buffer ──────────────
    const reader = transformResponse.body.getReader();
    const chunks: Uint8Array[] = [];
    let totalBytes = 0;
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      totalBytes += value.byteLength;
      if (totalBytes > MAX_OUTPUT_BYTES) {
        await reader.cancel();
        return new Response(
          `Output exceeds ${MAX_OUTPUT_BYTES} byte ceiling`,
          { status: 422 }
        );
      }
      chunks.push(value);
    }
    if (totalBytes === 0) {
      return new Response("Transform output is empty", { status: 502 });
    }

    const outputBytes = new Uint8Array(totalBytes);
    let offset = 0;
    for (const chunk of chunks) { outputBytes.set(chunk, offset); offset += chunk.byteLength; }

    // ── SHA-256 ────────────────────────────────────────────────────────────
    const hashBuffer = await crypto.subtle.digest("SHA-256", outputBytes);
    const hashHex = Array.from(new Uint8Array(hashBuffer))
      .map((b) => b.toString(16).padStart(2, "0"))
      .join("");

    // ── Write display copy — basename only to avoid path nesting ──────────
    const basename   = key.split("/").pop()!;
    const displayKey = `display/${basename}.webp`;
    await env.BUCKET.put(displayKey, outputBytes, {
      httpMetadata: { contentType: "image/webp" },
    });

    return new Response(outputBytes, {
      status: 200,
      headers: {
        "Content-Type":           "image/webp",
        "X-Forkensics-SHA256":    hashHex,
        "X-Forkensics-Display-Key": displayKey,
        "X-Forkensics-Size":      String(totalBytes),
      },
    });
  },
} satisfies ExportedHandler<Env>;
```

---

## §7 Verdict Criteria

| Tier | Condition | Meaning |
|------|-----------|---------|
| **PASS** | CF-P-0b + CF-P-1 through CF-P-12 all pass | Architecture viable. Proceed to production design. |
| **FAIL** | Any probe FAIL | Stop at that probe. Document. Evaluate Fallback Rank 2. |
| **CLEANUP NOTE** | `REMOTE_CLEANUP_REQUIRED` | Manual bucket/Worker cleanup needed regardless of test result. |

---

## §8 Fallback Rank 2

Sharp/libvips on dedicated background compute (Cloud Run / Fly.io / Lambda). Full control; operationally heaviest. Requires a new spike proposal if Rank 1 fails.

---

## §9 Open Questions (resolve before production implementation)

| # | Question | Owner |
|---|----------|-------|
| OQ-1 | Production upload: presign directly to R2, or `upload-authorize` proxies the PUT? | Bill + architecture review |
| OQ-2 | Display key: deterministic (hash of original) or random (UUID)? | Bill |
| OQ-3 | Production Worker auth: CF service token (Option A) or HMAC-SHA256 with replay protection (Option B)? | Bill + Codex |
| OQ-4 | Per-side dimension limit required in addition to the 15.5 MP area ceiling? | Bill |

---

## §10 Blocker Resolution Table (Rev 2 → Rev 3)

| # | Rev 2 Blocker | Resolution |
|---|--------------|------------|
| B-1 | Workers Paid limits incorrect (50 ms); Error 546 misattributed | CF-P-0b and CF-P-8 tables updated: Free = 10 ms hard limit; Paid = 30 s default, up to 5 min; error is 1102 not 546 |
| B-2 | Pixel policy: `MAX_DIMENSION_PX = 4096` permits 16.78 MP; rejects valid 5000×3000 | Replaced with area check: `width * height > 15_500_000` (15.5 MP). Per-side limit deferred to OQ-4 |
| B-3 | Format validation not implemented; `info.anim` undocumented | `ACCEPTED_FORMATS` set validates `info.format`; `anim: false` in `.output()` is the enforcement mechanism regardless of `info.anim` availability |
| B-4 | Secret injection undefined; `--var` exposes in process listing | `.dev.vars` file, mode `0600`, outside git tracking, written with `printf`, deleted by EXIT trap; hosted secret injected via `wrangler secret put` before deploy |
| B-5 | Account targeting not fail-closed; scopes undocumented | Preflight verifies `wrangler whoami` account ID against `CF_ACCOUNT_ID`; minimum API token scopes table added to §2.3 |
| B-6 | `wrangler init --no-bundle` undocumented; `wrangler list` wrong | §4.8 requires `--help` verification of every command before execution; `wrangler deployments list` used for Worker existence; pinned local installation |
| B-7 | Remote-dev lifecycle unsafe: `sleep 5`, no DEV_PID kill | Bounded 30-second readiness poll with process-alive check; `--max-time` on all curl calls; DEV_PID killed and waited in EXIT trap |
| B-8 | Cleanup incomplete: missing oversized fixture, suppressed failures, false "Complete" | Oversized key added to trap; failures tracked in `CLEANUP_FAILED`; final state verified; REMOTE_CLEANUP_CONFIRMED or REMOTE_CLEANUP_REQUIRED recorded; cleanup failure propagates exit code without replacing original test failure |
| B-9 | Validation-to-transform race across 3 R2 reads | ETag captured from Read 1; Reads 2 and 3 use `onlyIf: { etagMatches: etag }`; mismatch returns 409 without writing display object |
| SC-1 | Oversized assertion doesn't prove display key absent | Test A verifies zero display objects via `wrangler r2 object list` after 422 |
| SC-2 | P-8 CPU evidence from remote-dev only (preliminary) | Primary evidence is hosted Worker analytics (CF-P-9); remote-dev console is preliminary; both captured |
| SC-3 | `info.fileSize` vs R2 size not checked | Checked in Worker if field present in generated types; mismatch returns 422 |

---

*Proposal Rev 3 — 2026-08-15 — awaiting §1.2 three-party sign-off*
