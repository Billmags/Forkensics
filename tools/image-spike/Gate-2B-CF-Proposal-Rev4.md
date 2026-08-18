# Gate 2B — Cloudflare R2 + Images Binding Feasibility Spike
## Proposal Rev 4 — 2026-08-15

**Supersedes:** Rev 3 (not approved — 8 blockers, Codex SHA-256 `757eb7b33b3ed9d3d054dc9a8826c7cef65b5a11669f8144a5f9c0d0bab6fac3`)

---

## §1 Governance

### §1.1 Security Constraints (permanent — cannot be overridden)

- `CLOUDFLARE_API_TOKEN`, `SPIKE_SECRET`, and any Cloudflare credential never in client code, never in the repo, never sent to Claude.
- `ANON_KEY` and `SERVICE_ROLE_KEY` are runtime environment variables only; never written to any file, echoed, or logged.
- Three-party governance: **Bill + Claude + Codex** must all approve each phase before the authorized operations for that phase begin.
- Authorized Supabase project: `hkfrbdpedrxmbsawnbpr` (forkensics-dev ONLY). `torkgydbvktqebssfpdi` (forkensics-prod) NEVER.
- Authorized Cloudflare account ID: **`CF_ACCOUNT_ID_PLACEHOLDER`** ← Bill must replace this with the real account ID before Phase 1 sign-off. A proposal with this placeholder still present is not approvable.
- All spike resources use the suffix `-spike` and are removed at CF-P-12.

### §1.2 Two-Phase Authorization (B-1)

**Phase 1 — Proposal sign-off.** Authorizes: reviewing this document, running read-only checks (CF-P-0b, Wrangler `--help` verification), and drafting runner artifacts. Does **not** authorize any cloud operation.

| Party | Status | Note |
|-------|--------|------|
| Claude | ⬜ pending | |
| Codex | ⬜ pending | |
| Bill | ⬜ pending | |

**Phase 2 — Execution authorization.** Authorizes: all cloud operations from CF-P-1 through CF-P-12. Requires: Phase 1 complete, `CF_ACCOUNT_ID` filled, Workers plan confirmed (CF-P-0b), and all Wrangler commands verified with `--help`.

| Party | Status | Note |
|-------|--------|------|
| Claude | ⬜ pending | |
| Codex | ⬜ pending | |
| Bill | ⬜ pending | |

### §1.3 CF-P-0 Activation — Reconciliation

Images & Stream plan activated 2026-08-15 by Bill in the Cloudflare Dashboard at $0/month, no hosted storage selected. Zero-dollar configuration action. No Worker deployed, no bucket created, no transformation called. Recorded as an already-completed prerequisite.

---

## §2 Context

### §2.1 Why This Proposal Exists

Gate 2B Rev 15: HTTP 546 (Supabase pre-handler resource exhaustion — not a Cloudflare error code). Gate 2B Rev 20: P-0 BLOCKED (Supabase Free plan excludes managed transformations). This proposal tests Fallback Rank 1: **Cloudflare R2 + Images binding**.

### §2.2 CF-P-0 — Images Plan Eligibility (COMPLETE — PASS, 2026-08-15)

| Check | Result |
|-------|--------|
| Images & Stream plan | ✅ $0/month, activated by Bill 2026-08-15 |
| R2 binding on free Images tier | ✅ Confirmed — Cloudflare docs (2026-07-08) |
| Free quota | 5,000 unique transformations/month; spike consumes ≤ 20 |
| Existing R2 bucket | None — creation is CF-P-1 |

### §2.3 CF-P-0b — Workers Plan Eligibility (Phase 1 read-only step)

**Objective:** Record the account's Workers plan and effective `cpu_ms` limit.

Cloudflare resource exhaustion is **Error 1102**, not HTTP 546. HTTP 546 is Supabase-specific.

| Workers Plan | CPU-time limit | Notes |
|-------------|---------------|-------|
| Free | **10 ms** per invocation | Hard limit — Error 1102 if exceeded |
| Paid ($5/month) | **30 seconds** default; up to **5 minutes** via `cpu_ms` in `wrangler.toml` | Explicit `cpu_ms` configuration required if > 30 s needed |

**Authorized read-only action:** Cloudflare Dashboard → Workers & Pages → Overview → record plan name and effective `cpu_ms`.

Note: I/O-waiting time (R2 reads, Images binding network round-trip) does not count as Cloudflare CPU time. Only JavaScript execution time is metered. The Worker's JS work (SHA-256 over ≤ 5 MB, bounded stream copy, three R2 metadata calls) should be well within even the Free limit, but must be confirmed empirically at CF-P-8.

**Minimum API token scopes required:**

| Scope | Required for |
|-------|-------------|
| Workers Scripts:Edit | `wrangler deploy`, `wrangler delete` |
| Workers Scripts:Read | Deployment list / existence check |
| R2:Edit | Bucket create/delete, object put/delete |
| R2:Read | Object get (key-specific existence checks) |
| Account Settings:Read | `wrangler whoami` |

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
  ├─ GET /health → 200 (no R2, no IMAGES)
  ├─ auth boundary
  ├─ R2 get (read 1) → ETag captured, size gate (> 10 MB → 422)
  ├─ R2 get (read 2, ETag-matched) → .info() [free] → format + dims + fileSize
  ├─ format gate: JPEG or WebP only
  ├─ area gate: width * height > 15_500_000 → 422
  ├─ fileSize consistency check (if exposed by generated types)
  ├─ R2 get (read 3, ETag-matched) → .transform().output({ anim: false })
  ├─ validate response: status, Content-Type: image/webp, nonempty body
  ├─ bounded stream read (≤ 5 MB + 1 byte ceiling)
  ├─ SHA-256 over output buffer
  ├─ R2 put: display/{basename}.webp
  └─ return 200 + headers
```

### §3.2 Scope

Spike Worker: `forkensics-image-spike`. Spike bucket: `forkensics-dev-spike`. No production resources created or modified. Cleaned up at CF-P-12.

---

## §4 Constraints

### §4.1 Input Limits
- `object.size > 10 MB` → reject before any billable call.
- Images binding accepts up to 20 MB — Forkensics cap fits.

### §4.2 Output Ceiling
- ≤ 5 MB enforced by bounded stream read before R2 write.

### §4.3 Pixel Policy
- Area ceiling: `width * height > 15_500_000` (15.5 MP). Safe integer arithmetic — no overflow risk at image dimensions.
- No per-side limit established in this spike. Add separately if product requires one (OQ-4).

### §4.4 Accepted Format Contract (B-2)

The frozen MIME contract for Forkensics permits **JPEG and WebP only**. No PNG, HEIC, or AVIF.

```typescript
// JPEG and WebP only — frozen MIME contract
const ACCEPTED_FORMATS = new Set(["image/jpeg", "image/webp"]);
```

**Format string normalization (additional hardening):** Cloudflare's `.info()` may return `"jpeg"` rather than `"image/jpeg"`. The Worker normalizes before checking:

```typescript
const normalizedFormat = info.format.startsWith("image/")
  ? info.format
  : `image/${info.format}`;
if (!ACCEPTED_FORMATS.has(normalizedFormat)) {
  return new Response(`Unsupported format: ${info.format}`, { status: 422 });
}
```

The exact format string returned by `.info()` must be recorded from `wrangler types` output and from the first CF-P-4 `info` log entry before the format set is considered validated.

### §4.5 Animation Policy
`info.anim` is not publicly documented by Cloudflare. The Worker always sets `anim: false` in `.output()` to convert any animated input to a still image. This is the enforcement mechanism regardless of `.info()` response shape.

### §4.6 Metadata Stripping
Proven at byte level via ExifTool. Not assumed.

### §4.7 Production Auth
`SPIKE_SECRET` is a spike-only random secret. Production: Cloudflare service token (Option A) or HMAC-SHA256 with replay protection (Option B). Supabase service-role JWT must never be transmitted to Cloudflare. See §9 OQ-3.

### §4.8 Wrangler Version and Command Verification

Before Phase 2 execution:
1. Install a pinned Wrangler version: `npm install --save-dev wrangler@<pinned>`.
2. Use `./node_modules/.bin/wrangler` throughout all scripts.
3. Run `--help` for every command in the list below. Record output. Replace any unsupported command with a documented alternative before runner execution.

**Commands requiring `--help` verification:**

| Command | Alternative if unsupported |
|---------|---------------------------|
| `wrangler init` (and applicable flags) | Scaffold `wrangler.toml` + `src/` manually |
| `wrangler types` | — |
| `wrangler dev --remote` | — |
| `wrangler secret put` | — |
| `wrangler deploy` | — |
| `wrangler delete` | — |
| `wrangler deployments list` | CF API: `GET /accounts/{id}/workers/scripts` |
| `wrangler r2 bucket create / list / delete` | — |
| `wrangler r2 object put / get / delete` | — |
| `wrangler whoami` | — |

**`wrangler r2 object list` is not a supported command (B-6).** Object existence in the spike is verified key-by-key using `wrangler r2 object get` against each known key (see §5.0 cleanup and CF-P-12). This is sufficient for a known-key spike but does not catch unexpected additional objects.

### §4.9 Account Targeting (fail-closed)

`CF_ACCOUNT_ID` in §1.1 must be filled before Phase 1 sign-off. The runner verifies it before CF-P-1:

```bash
ACTUAL_ID=$("$WRANGLER" whoami --json 2>/dev/null | jq -r '.accounts[0].id // empty')
if [ -z "$ACTUAL_ID" ] || [ "$ACTUAL_ID" != "$CF_ACCOUNT_ID" ]; then
  echo "FAIL: Account mismatch or whoami failed. Aborting."
  exit 1
fi
```

If `wrangler whoami --json` is not supported in the pinned version, use the Cloudflare API:
```bash
ACTUAL_ID=$(curl -s -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  "https://api.cloudflare.com/client/v4/user/tokens/verify" \
  | jq -r '.result.id // empty')
```

---

## §5 Probe Sequence

**Probes execute in order. Any FAIL stops the sequence. The EXIT trap fires on every exit. Cleanup failure is recorded separately and never masks the original test result.**

Probe order: §5.0 Preflight → CF-P-1 → CF-P-2 → CF-P-3 → CF-P-4 → CF-P-5 → CF-P-6 → CF-P-7 → CF-P-9 → **CF-P-8** → CF-P-10 → CF-P-11 → CF-P-12

Note: CF-P-8 (CPU budget) appears after CF-P-9 (hosted deploy) because definitive CPU evidence comes from hosted Worker analytics. The numbering is preserved to match review references; the execution order is stated explicitly above.

---

### §5.0 — Runner Preflight and EXIT Trap

```bash
#!/usr/bin/env bash
set -euo pipefail

# ── Configuration ──────────────────────────────────────────────────────────────
CF_ACCOUNT_ID="<fill-in — see §1.1>"
BUCKET="forkensics-dev-spike"
WORKER="forkensics-image-spike"
WRANGLER="./node_modules/.bin/wrangler"

# ── Resource tracking (B-7) — only clean up what was created ──────────────────
BUCKET_CREATED=false
WORKER_DEPLOYED=false
DEV_PID=""
ORIGINAL_EXIT=0

# ── Helpers ────────────────────────────────────────────────────────────────────
assert_http() {
  # assert_http <actual> <expected> <label>
  local actual="$1" expected="$2" label="$3"
  if [ "$actual" != "$expected" ]; then
    echo "FAIL [$label]: expected HTTP $expected, got $actual"
    exit 1
  fi
  echo "PASS [$label]: HTTP $actual"
}

key_absent() {
  # Returns 0 (true) if key does NOT exist in bucket
  local key="$1"
  if "$WRANGLER" r2 object get "$BUCKET/$key" --file /dev/null 2>/dev/null; then
    return 1   # exists
  fi
  return 0     # absent
}

key_exists() {
  ! key_absent "$1"
}

# ── EXIT trap ──────────────────────────────────────────────────────────────────
cleanup() {
  ORIGINAL_EXIT=$?
  CLEANUP_FAILED=false
  echo "[CLEANUP] Starting — $(date -u +%Y-%m-%dT%H:%M:%SZ) (original exit: $ORIGINAL_EXIT)"

  # 1. Kill wrangler dev
  if [ -n "$DEV_PID" ] && kill -0 "$DEV_PID" 2>/dev/null; then
    kill "$DEV_PID" 2>/dev/null || true
    wait "$DEV_PID" 2>/dev/null || true
    echo "[CLEANUP] wrangler dev terminated (PID $DEV_PID)"
  fi

  # 2. Delete .dev.vars
  rm -f .dev.vars && echo "[CLEANUP] .dev.vars removed" || true

  # 3. Undeploy Worker (only if deployed)
  if [ "$WORKER_DEPLOYED" = "true" ]; then
    if "$WRANGLER" delete "$WORKER" --force 2>/dev/null; then
      echo "[CLEANUP] Worker undeployed"
    else
      echo "[CLEANUP] WARNING: Worker undeploy failed"
      CLEANUP_FAILED=true
    fi
    # Verify absence (fail-closed — B-7)
    if key_exists_worker; then
      echo "[CLEANUP] WARNING: Worker still visible after undeploy"
      CLEANUP_FAILED=true
    else
      echo "[CLEANUP] Worker confirmed absent"
    fi
  fi

  # 4. Delete known spike objects (only if bucket was created)
  if [ "$BUCKET_CREATED" = "true" ]; then
    for KEY in \
      "spike/fixture-exif.jpg" \
      "spike/fixture-icc.png" \
      "spike/fixture-oversized.jpg" \
      "display/fixture-exif.jpg.webp" \
      "display/fixture-icc.png.webp"; do
      "$WRANGLER" r2 object delete "$BUCKET/$KEY" 2>/dev/null \
        && echo "[CLEANUP] Deleted: $KEY" \
        || echo "[CLEANUP] NOTE: $KEY not present or deletion failed"
    done

    # 5. Verify each known key is absent (key-specific — wrangler r2 object list unsupported)
    for KEY in \
      "spike/fixture-exif.jpg" \
      "spike/fixture-icc.png" \
      "spike/fixture-oversized.jpg" \
      "display/fixture-exif.jpg.webp" \
      "display/fixture-icc.png.webp"; do
      if key_exists "$KEY"; then
        echo "[CLEANUP] WARNING: Key still present: $KEY"
        CLEANUP_FAILED=true
      fi
    done

    # 6. Delete bucket
    if "$WRANGLER" r2 bucket delete "$BUCKET" 2>/dev/null; then
      echo "[CLEANUP] Bucket deleted"
    else
      echo "[CLEANUP] WARNING: Bucket deletion failed"
      CLEANUP_FAILED=true
    fi

    # 7. Verify bucket absent (fail-closed)
    if "$WRANGLER" r2 bucket list 2>/dev/null | grep -qF "$BUCKET"; then
      echo "[CLEANUP] WARNING: Bucket still visible"
      CLEANUP_FAILED=true
    else
      echo "[CLEANUP] Bucket confirmed absent"
    fi
  fi

  # 8. Final status
  if [ "$CLEANUP_FAILED" = "true" ]; then
    echo "[CLEANUP] Status: REMOTE_CLEANUP_REQUIRED — manual verification needed"
    [ "$ORIGINAL_EXIT" -ne 0 ] && exit "$ORIGINAL_EXIT" || exit 1
  else
    echo "[CLEANUP] Status: REMOTE_CLEANUP_CONFIRMED"
    exit "$ORIGINAL_EXIT"
  fi
}

# Helper: check Worker existence using documented command (verified in §4.8)
key_exists_worker() {
  "$WRANGLER" deployments list 2>/dev/null | grep -qF "$WORKER"
}

trap cleanup EXIT

# ── Preflight checks ────────────────────────────────────────────────────────────

echo "=== PREFLIGHT ==="
echo "Wrangler: $("$WRANGLER" --version)"

# Required tools
command -v jq       >/dev/null 2>&1 || { echo "FAIL: jq not installed";       exit 1; }
command -v exiftool >/dev/null 2>&1 || { echo "FAIL: exiftool not installed"; exit 1; }
command -v shasum   >/dev/null 2>&1 || { echo "FAIL: shasum not installed";   exit 1; }

# Secrets set (not printed)
[ -n "${SPIKE_SECRET:-}"          ] || { echo "FAIL: SPIKE_SECRET not set";          exit 1; }
[ -n "${CLOUDFLARE_API_TOKEN:-}"  ] || { echo "FAIL: CLOUDFLARE_API_TOKEN not set";  exit 1; }
echo "[PREFLIGHT] Secrets: set (not printed)"

# Account ID verification (fail-closed — §4.9)
[ "$CF_ACCOUNT_ID" != "<fill-in — see §1.1>" ] || {
  echo "FAIL: CF_ACCOUNT_ID placeholder not replaced"; exit 1; }
ACTUAL_ID=$("$WRANGLER" whoami --json 2>/dev/null | jq -r '.accounts[0].id // empty')
[ -n "$ACTUAL_ID" ] || { echo "FAIL: wrangler whoami returned no account ID"; exit 1; }
[ "$ACTUAL_ID" = "$CF_ACCOUNT_ID" ] || {
  echo "FAIL: Account mismatch (expected $CF_ACCOUNT_ID, got $ACTUAL_ID)"; exit 1; }
echo "[PREFLIGHT] Account ID verified: $CF_ACCOUNT_ID"

# No pre-existing spike resources (fail-closed)
if "$WRANGLER" r2 bucket list 2>/dev/null | grep -qF "$BUCKET"; then
  echo "FAIL: Bucket $BUCKET already exists — manual cleanup required"; exit 1; fi
if key_exists_worker; then
  echo "FAIL: Worker $WORKER already deployed — manual cleanup required"; exit 1; fi

echo "[PREFLIGHT] All checks passed."
```

---

### CF-P-1 — R2 Bucket Creation

**Authorized cloud operation (Phase 2).**

```bash
echo "=== CF-P-1 ==="
"$WRANGLER" r2 bucket create "$BUCKET"
BUCKET_CREATED=true

# Verify (fail-closed)
"$WRANGLER" r2 bucket list 2>/dev/null | grep -qF "$BUCKET" \
  || { echo "FAIL CF-P-1: Bucket not found after creation"; exit 1; }
echo "PASS CF-P-1: Bucket $BUCKET created and confirmed"
```

Confirm no `r2.dev` public URL is enabled (Dashboard check).

---

### CF-P-2 — Worker Scaffolding and Type Generation (local only)

**No cloud operation.**

**`wrangler.toml`:**
```toml
name = "forkensics-image-spike"
main = "src/index.ts"
compatibility_date = "2026-08-15"

[images]
binding = "IMAGES"

[[r2_buckets]]
binding             = "BUCKET"
bucket_name         = "forkensics-dev-spike"
preview_bucket_name = "forkensics-dev-spike"

# SPIKE_SECRET is a secret binding — declared here for type generation.
# Value is provisioned via `wrangler secret put SPIKE_SECRET` before deploy (B-5).
# Verify exact toml syntax for secret declarations with `wrangler --help`.
```

```bash
echo "=== CF-P-2 ==="
"$WRANGLER" types        # generates worker-configuration.d.ts
tsc --noEmit             # must exit 0
echo "PASS CF-P-2: Types generated, zero type errors"
```

Record from `worker-configuration.d.ts`:
- Whether `IMAGES` type exposes `info()` return shape with `anim` and/or `fileSize` fields.
- Whether format strings are `"jpeg"` or `"image/jpeg"` — update §4.4 normalization accordingly.

---

### CF-P-3 — Fixture Upload

**Authorized cloud operations.**

```bash
echo "=== CF-P-3 ==="
for FIXTURE in \
  "fixtures/fixture-exif.jpg:spike/fixture-exif.jpg" \
  "fixtures/fixture-icc.png:spike/fixture-icc.png" \
  "fixtures/fixture-oversized.jpg:spike/fixture-oversized.jpg"; do
  LOCAL="${FIXTURE%%:*}"
  KEY="${FIXTURE##*:}"
  "$WRANGLER" r2 object put "$BUCKET/$KEY" --file "$LOCAL"
  key_exists "$KEY" || { echo "FAIL CF-P-3: Key $KEY not found after upload"; exit 1; }
  echo "PASS CF-P-3: Uploaded $KEY"
done
```

**Fixtures:**
| R2 key | Format | Approximate size | Contains |
|--------|--------|-----------------|----------|
| `spike/fixture-exif.jpg` | JPEG | ~500 KB | GPS + EXIF metadata |
| `spike/fixture-icc.png` | PNG | ~300 KB | ICC color profile |
| `spike/fixture-oversized.jpg` | JPEG | > 10 MB | Proves size rejection |

Note: `fixture-icc.png` is PNG. The Worker will reject it (not in ACCEPTED_FORMATS: JPEG+WebP only). It serves as a format-rejection fixture.

---

### CF-P-4 — Local Transformation Test (`wrangler dev --remote`)

**Authorized cloud operation (Phase 2).** Uploads code to ephemeral Cloudflare preview using `preview_bucket_name`.

**Inject secret via `.dev.vars` (mode 0600):**
```bash
printf 'SPIKE_SECRET=%s\n' "$SPIKE_SECRET" > .dev.vars
chmod 0600 .dev.vars
```

**Start dev with bounded readiness polling on `/health` (B-3):**
```bash
echo "=== CF-P-4 ==="
"$WRANGLER" dev --remote src/index.ts &
DEV_PID=$!

READY=false
for i in $(seq 1 30); do
  if ! kill -0 "$DEV_PID" 2>/dev/null; then
    echo "FAIL CF-P-4: wrangler dev process died"; exit 1; fi
  # Poll /health — no auth required, no R2/IMAGES touched, no display object written (B-3)
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-time 2 \
    http://localhost:8787/health 2>/dev/null || echo "000")
  if [ "$STATUS" = "200" ]; then READY=true; break; fi
  sleep 1
done
[ "$READY" = "true" ] || { echo "FAIL CF-P-4: wrangler dev not ready after 30s"; exit 1; }
```

**Test A — oversized input (422, zero display objects written):**
```bash
STATUS_A=$(curl -s -o /dev/null -w "%{http_code}" --max-time 30 \
  -H "Authorization: Bearer $SPIKE_SECRET" \
  http://localhost:8787/transform/spike/fixture-oversized.jpg)
assert_http "$STATUS_A" "422" "CF-P-4 Test A (oversized)"

# Assert no display key was written (smaller correction — B-3 follow-on)
key_absent "display/fixture-oversized.jpg.webp" \
  || { echo "FAIL CF-P-4 Test A: display key written for oversized input"; exit 1; }
echo "PASS CF-P-4 Test A: No display key for oversized input"
```

**Test B — PNG input (422, format rejected before billable transform):**
```bash
STATUS_B=$(curl -s -o /dev/null -w "%{http_code}" --max-time 30 \
  -H "Authorization: Bearer $SPIKE_SECRET" \
  http://localhost:8787/transform/spike/fixture-icc.png)
assert_http "$STATUS_B" "422" "CF-P-4 Test B (PNG — format rejected)"
key_absent "display/fixture-icc.png.webp" \
  || { echo "FAIL CF-P-4 Test B: display key written for rejected format"; exit 1; }
echo "PASS CF-P-4 Test B: No display key for PNG input"
```

**Test C — JPEG with EXIF (200, WebP output):**
```bash
curl -s --max-time 60 \
  -H "Authorization: Bearer $SPIKE_SECRET" \
  -D cf_p4_jpeg_headers.txt \
  -o cf_p4_jpeg_output.webp \
  http://localhost:8787/transform/spike/fixture-exif.jpg
STATUS_C=$(grep -m1 "^HTTP" cf_p4_jpeg_headers.txt | awk '{print $2}')
assert_http "$STATUS_C" "200" "CF-P-4 Test C (JPEG)"
grep -i "content-type: image/webp" cf_p4_jpeg_headers.txt \
  || { echo "FAIL CF-P-4 Test C: Content-Type not image/webp"; exit 1; }
grep -i "x-forkensics-sha256:" cf_p4_jpeg_headers.txt \
  || { echo "FAIL CF-P-4 Test C: SHA256 header missing"; exit 1; }
```

**Test D — ETag race test (409, no display write — additional hardening):**
```bash
# Upload a replacement object under the same key to force ETag mismatch,
# then immediately call transform — Worker should return 409.
"$WRANGLER" r2 object put "$BUCKET/spike/fixture-exif.jpg" \
  --file ./fixtures/fixture-exif.jpg   # re-upload creates new ETag
# In a real race the replacement would happen mid-transform;
# here we verify the 409 path is reachable by testing after a deliberate re-upload.
# The Worker reads ETag on Read 1 then must match it on Reads 2 and 3.
# This test exercises the 409 code path by making Reads 2+3 fail their condition.
# Implementation: add a test endpoint /transform-race/{key} that sleeps
# between Read 1 and Read 2, allowing this test to interleave a re-upload.
# If the Worker does not expose a race endpoint, document the 409 path as
# unit-test only and note it here.
echo "NOTE: ETag race test requires either a /transform-race endpoint or unit test coverage"
```

**Terminate dev process:**
```bash
kill "$DEV_PID" 2>/dev/null || true
wait "$DEV_PID" 2>/dev/null || true
DEV_PID=""
rm -f .dev.vars
```

**Evidence to capture:** HTTP status per test, Content-Type and SHA256 headers (Test C), preliminary CPU time from Worker console, `info.format` value logged by Worker (record actual string for §4.4 validation).

---

### CF-P-5 — Metadata Stripping Verification

```bash
echo "=== CF-P-5 ==="
exiftool cf_p4_jpeg_output.webp > cf_p5_exiftool_jpeg.txt 2>&1
cat cf_p5_exiftool_jpeg.txt

for TAG_FAMILY in "EXIF" "XMP" "ICC_Profile" "Comment"; do
  if grep -qi "^${TAG_FAMILY}" cf_p5_exiftool_jpeg.txt; then
    echo "FAIL CF-P-5: Prohibited metadata family found: $TAG_FAMILY"
    exit 1
  fi
done
echo "PASS CF-P-5: No prohibited metadata families in JPEG output"
```

**Prohibited families:** EXIF (Make, Model, GPS*, DateTimeOriginal, …), XMP (all namespaces), ICC_Profile, Comment (ImageDescription, UserComment). Structural properties (File Size, Image Width, Height, Bit Depth) are permitted.

---

### CF-P-6 — Output WebP Structural Verification

Applied to `cf_p4_jpeg_output.webp`.

1. **RIFF header:** bytes 0–3 = `52 49 46 46`; bytes 8–11 = `57 45 42 50`.
2. **Exact RIFF size:** `riff_size = uint32LE(bytes[4..8])`. Require: `actual_file_size == riff_size + 8`. No extra bytes (B-12 from Rev 2, retained).
3. **Chunk data region:** `bytes[12..riff_size+8)`.
4. **Valid chunk sequences (exactly one of five):** VP8, VP8L, VP8X+VP8, VP8X+ALPH+VP8, VP8X+VP8L. ALPH+VP8L forbidden.
5. **VP8X flags (if present):** `(flags_u32 & ~0x00000010) === 0`. Animation (`0x02`), XMP (`0x04`), EXIF (`0x08`), ICC (`0x20`) must be zero.

**Evidence to capture:** Hex dump bytes 0–15, RIFF declared vs. actual size, chunk sequence, VP8X flags.

---

### CF-P-7 — SHA-256 Integrity

```bash
echo "=== CF-P-7 ==="
SHA_HEADER=$(grep -i "x-forkensics-sha256:" cf_p4_jpeg_headers.txt \
  | awk '{print $2}' | tr -d '[:space:]')
SHA_FILE=$(shasum -a 256 cf_p4_jpeg_output.webp | awk '{print $1}')
[ "$SHA_HEADER" = "$SHA_FILE" ] \
  || { echo "FAIL CF-P-7: SHA mismatch (header=$SHA_HEADER file=$SHA_FILE)"; exit 1; }
echo "PASS CF-P-7: SHA-256 matches ($SHA_FILE)"
```

---

### CF-P-9 — Hosted Worker Deploy

**Atomic secret provisioning before deploy (B-5):**
```bash
echo "=== CF-P-9 ==="
# Provision secret first — Worker is not callable until deploy completes
printf '%s' "$SPIKE_SECRET" | "$WRANGLER" secret put SPIKE_SECRET
# Then deploy atomically
"$WRANGLER" deploy
WORKER_DEPLOYED=true

# Verify deployment (fail-closed)
key_exists_worker \
  || { echo "FAIL CF-P-9: Worker not found after deploy"; exit 1; }
echo "Worker deployed and confirmed"
```

```bash
WORKER_URL="https://${WORKER}.${CF_ACCOUNT_ID}.workers.dev"
curl -s --max-time 60 \
  -H "Authorization: Bearer $SPIKE_SECRET" \
  -D cf_p9_hosted_headers.txt \
  -o cf_p9_hosted_output.webp \
  "${WORKER_URL}/transform/spike/fixture-exif.jpg"

STATUS_P9=$(grep -m1 "^HTTP" cf_p9_hosted_headers.txt | awk '{print $2}')
assert_http "$STATUS_P9" "200" "CF-P-9 hosted"
grep -i "content-type: image/webp" cf_p9_hosted_headers.txt \
  || { echo "FAIL CF-P-9: Content-Type not image/webp"; exit 1; }

SHA_P9_HEADER=$(grep -i "x-forkensics-sha256:" cf_p9_hosted_headers.txt \
  | awk '{print $2}' | tr -d '[:space:]')
SHA_P9_FILE=$(shasum -a 256 cf_p9_hosted_output.webp | awk '{print $1}')
[ "$SHA_P9_HEADER" = "$SHA_P9_FILE" ] \
  || { echo "FAIL CF-P-9: Hosted SHA mismatch"; exit 1; }
echo "PASS CF-P-9: Hosted transform confirmed"
```

---

### CF-P-8 — Worker CPU Budget

**Ordered after CF-P-9 (B-8). Definitive evidence comes from hosted Worker analytics.**

```bash
echo "=== CF-P-8 ==="
echo "Collect CPU time from: Cloudflare Dashboard → Workers → $WORKER → Analytics"
echo "Preliminary CPU time from CF-P-4 remote-dev console: [record manually]"
echo "Definitive CPU time from CF-P-9 hosted invocation analytics: [record manually]"
```

**Pass/fail thresholds (per CF-P-0b plan):**

| Workers Plan | CPU time | Result |
|-------------|----------|--------|
| Free | < 10 ms | PASS |
| Free | ≥ 10 ms | FAIL — upgrade requires separate three-party approval |
| Paid | < configured `cpu_ms` | PASS |
| Paid | ≥ configured `cpu_ms` | FAIL |

Definitive evidence: hosted Worker analytics. Remote-dev console from CF-P-4 is preliminary only.

---

### CF-P-10 — Auth Boundary

```bash
echo "=== CF-P-10 ==="
WORKER_URL="https://${WORKER}.${CF_ACCOUNT_ID}.workers.dev"

STATUS_NO_AUTH=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
  "${WORKER_URL}/transform/spike/fixture-exif.jpg")
assert_http "$STATUS_NO_AUTH" "401" "CF-P-10 no-auth"

STATUS_WRONG=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
  -H "Authorization: Bearer wrongtoken" \
  "${WORKER_URL}/transform/spike/fixture-exif.jpg")
assert_http "$STATUS_WRONG" "401" "CF-P-10 wrong-token"
echo "PASS CF-P-10: Auth boundary confirmed"
```

---

### CF-P-11 — Write-Back Persistence Verification

```bash
echo "=== CF-P-11 ==="
# Display keys written by Worker (basename derivation: key.split('/').pop() + '.webp')
# spike/fixture-exif.jpg → display/fixture-exif.jpg.webp

key_exists "display/fixture-exif.jpg.webp" \
  || { echo "FAIL CF-P-11: JPEG display key absent"; exit 1; }

"$WRANGLER" r2 object get "$BUCKET/display/fixture-exif.jpg.webp" \
  --file cf_p11_display_verify.webp
SHA_P11=$(shasum -a 256 cf_p11_display_verify.webp | awk '{print $1}')
[ "$SHA_P11" = "$SHA_P9_HEADER" ] \
  || { echo "FAIL CF-P-11: Display object SHA mismatch"; exit 1; }
echo "PASS CF-P-11: Display object present and SHA verified"
```

---

### CF-P-12 — Cleanup (explicit success-path — idempotent with EXIT trap)

```bash
echo "=== CF-P-12 ==="
# Undeploy first
"$WRANGLER" delete "$WORKER" --force
WORKER_DEPLOYED=false
key_exists_worker && { echo "FAIL CF-P-12: Worker still listed"; exit 1; }
echo "Worker confirmed absent"

# Delete known spike objects
for KEY in \
  "spike/fixture-exif.jpg" "spike/fixture-icc.png" "spike/fixture-oversized.jpg" \
  "display/fixture-exif.jpg.webp" "display/fixture-icc.png.webp"; do
  "$WRANGLER" r2 object delete "$BUCKET/$KEY" 2>/dev/null || true
  key_absent "$KEY" || { echo "FAIL CF-P-12: Key $KEY still present"; exit 1; }
done
echo "All known keys confirmed absent"

# Delete bucket
"$WRANGLER" r2 bucket delete "$BUCKET"
BUCKET_CREATED=false
"$WRANGLER" r2 bucket list 2>/dev/null | grep -qF "$BUCKET" \
  && { echo "FAIL CF-P-12: Bucket still listed"; exit 1; }
echo "PASS CF-P-12: REMOTE_CLEANUP_CONFIRMED"
```

---

## §6 Authoritative Worker Code

```typescript
// src/index.ts — forkensics-image-spike Rev 4
// SPIKE ONLY — not production code
// Env interface generated by `wrangler types`

const MAX_INPUT_BYTES  = 10 * 1024 * 1024; // 10 MB
const MAX_OUTPUT_BYTES =  5 * 1024 * 1024; // 5 MB
const MAX_PIXELS       = 15_500_000;        // 15.5 MP area ceiling

// Frozen MIME contract: JPEG and WebP only (B-2)
const ACCEPTED_FORMATS = new Set(["image/jpeg", "image/webp"]);

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    // ── Health route — no R2, no IMAGES, no auth required (B-3) ──────────
    if (url.pathname === "/health") {
      return new Response("ok", { status: 200 });
    }

    // ── Auth boundary ──────────────────────────────────────────────────────
    const auth = request.headers.get("Authorization") ?? "";
    if (auth !== `Bearer ${env.SPIKE_SECRET}`) {
      return new Response("Unauthorized", { status: 401 });
    }

    // ── Route: GET /transform/{key} ────────────────────────────────────────
    const key = url.pathname.replace(/^\/transform\//, "").trim();
    if (!key || key.includes("..") || key.startsWith("/")) {
      return new Response("Invalid key", { status: 400 });
    }

    // ── Read 1: size gate ──────────────────────────────────────────────────
    const object = await env.BUCKET.get(key);
    if (!object) {
      return new Response("Not found", { status: 404 });
    }
    const etag = object.etag;
    if ((object.size ?? 0) > MAX_INPUT_BYTES) {
      return new Response(
        `Input too large: ${object.size} bytes (max ${MAX_INPUT_BYTES})`,
        { status: 422 }
      );
    }

    // ── Read 2: .info() — free, ETag-matched (B-4, B-9) ──────────────────
    const infoObject = await env.BUCKET.get(key, {
      onlyIf: { etagMatches: etag },
    });
    // Conditional miss may return metadata-only object without body (B-4)
    if (!infoObject || !("body" in infoObject) || !infoObject.body) {
      return new Response("Input changed between reads", { status: 409 });
    }

    let info: { format: string; width: number; height: number; fileSize?: number };
    try {
      info = await env.IMAGES.info(infoObject.body) as typeof info;
      console.log(`info.format raw value: ${JSON.stringify(info.format)}`); // record for §4.4
    } catch (err) {
      return new Response(`Info error: ${err}`, { status: 422 });
    }

    // Format validation — normalize to image/X before checking (additional hardening)
    const normalizedFormat = info.format.startsWith("image/")
      ? info.format
      : `image/${info.format}`;
    if (!ACCEPTED_FORMATS.has(normalizedFormat)) {
      return new Response(`Unsupported format: ${info.format}`, { status: 422 });
    }

    // Pixel area ceiling
    if (info.width * info.height > MAX_PIXELS) {
      return new Response(
        `Image ${info.width}×${info.height}px exceeds ${MAX_PIXELS}px area ceiling`,
        { status: 422 }
      );
    }

    // fileSize consistency (if type-generated field present)
    if (typeof info.fileSize === "number" && info.fileSize !== object.size) {
      return new Response(
        `File size mismatch: R2=${object.size}, info.fileSize=${info.fileSize}`,
        { status: 422 }
      );
    }

    // ── Read 3: transform — ETag-matched (B-9) ────────────────────────────
    const transformObject = await env.BUCKET.get(key, {
      onlyIf: { etagMatches: etag },
    });
    if (!transformObject || !("body" in transformObject) || !transformObject.body) {
      return new Response("Input changed between reads", { status: 409 });
    }

    let transformResponse: Response;
    try {
      transformResponse = (
        await env.IMAGES.input(transformObject.body)
          .transform({ width: 1280, height: 1280, fit: "scale-down" })
          .output({ format: "image/webp", quality: 85, anim: false })
      ).response();
    } catch (err) {
      return new Response(`Transform error: ${err}`, { status: 500 });
    }

    // ── Validate response before buffering ────────────────────────────────
    if (!transformResponse.ok) {
      return new Response(`Transform non-OK: ${transformResponse.status}`, { status: 502 });
    }
    const ct = transformResponse.headers.get("Content-Type") ?? "";
    if (!ct.includes("image/webp")) {
      return new Response(`Unexpected Content-Type: ${ct}`, { status: 502 });
    }
    if (!transformResponse.body) {
      return new Response("Transform returned empty body", { status: 502 });
    }

    // ── Bounded stream read ────────────────────────────────────────────────
    const reader = transformResponse.body.getReader();
    const chunks: Uint8Array[] = [];
    let totalBytes = 0;
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      totalBytes += value.byteLength;
      if (totalBytes > MAX_OUTPUT_BYTES) {
        await reader.cancel();
        return new Response(`Output exceeds ${MAX_OUTPUT_BYTES} byte ceiling`, { status: 422 });
      }
      chunks.push(value);
    }
    if (totalBytes === 0) {
      return new Response("Transform output empty", { status: 502 });
    }
    const outputBytes = new Uint8Array(totalBytes);
    let off = 0;
    for (const chunk of chunks) { outputBytes.set(chunk, off); off += chunk.byteLength; }

    // ── SHA-256 ────────────────────────────────────────────────────────────
    const hashBuffer = await crypto.subtle.digest("SHA-256", outputBytes);
    const hashHex = Array.from(new Uint8Array(hashBuffer))
      .map((b) => b.toString(16).padStart(2, "0"))
      .join("");

    // ── Write display copy — basename derivation ───────────────────────────
    const basename   = key.split("/").pop()!;
    const displayKey = `display/${basename}.webp`;
    await env.BUCKET.put(displayKey, outputBytes, {
      httpMetadata: { contentType: "image/webp" },
    });

    return new Response(outputBytes, {
      status: 200,
      headers: {
        "Content-Type":             "image/webp",
        "X-Forkensics-SHA256":      hashHex,
        "X-Forkensics-Display-Key": displayKey,
        "X-Forkensics-Size":        String(totalBytes),
      },
    });
  },
} satisfies ExportedHandler<Env>;
```

---

## §7 Verdict Criteria

| Tier | Condition | Meaning |
|------|-----------|---------|
| **PASS** | All probes pass, `REMOTE_CLEANUP_CONFIRMED` | Architecture viable. Proceed to production design. |
| **FAIL** | Any probe FAIL | Stop. Document. Evaluate Fallback Rank 2. |
| **CLEANUP NOTE** | `REMOTE_CLEANUP_REQUIRED` | Manual verification needed regardless of test outcome. |

---

## §8 Fallback Rank 2

Sharp/libvips on dedicated background compute (Cloud Run / Fly.io / Lambda). Requires new spike proposal if Rank 1 fails.

---

## §9 Open Questions

| # | Question | Owner |
|---|----------|-------|
| OQ-1 | Production upload: presign directly to R2 or `upload-authorize` proxies PUT? | Bill |
| OQ-2 | Display key: deterministic (hash of original) or random (UUID)? | Bill |
| OQ-3 | Production Worker auth: CF service token (A) or HMAC-SHA256 with replay (B)? | Bill + Codex |
| OQ-4 | Per-side dimension limit required in addition to 15.5 MP area ceiling? | Bill |

---

## §10 Blocker Resolution Table (Rev 3 → Rev 4)

| # | Rev 3 Blocker | Resolution |
|---|--------------|------------|
| B-1 | Proposal/execution approval not separated; placeholder not fill-before-approval | Two-phase §1.2 table added; placeholder in §1.1 must be replaced before Phase 1 sign-off; runner aborts if placeholder is literal string |
| B-2 | ACCEPTED_FORMATS includes PNG, HEIC, AVIF — not in frozen MIME contract | ACCEPTED_FORMATS = `{"image/jpeg", "image/webp"}` only; PNG fixture now tests format rejection (Test B) |
| B-3 | Readiness poll transforms JPEG and writes display object before Test A checks zero | Added `GET /health` route (no R2, no IMAGES); readiness polling uses `/health`; Test A runs first against oversized fixture |
| B-4 | Conditional R2 read may return metadata-only object without body, not null | Check `!infoObject || !("body" in infoObject) || !infoObject.body` for Reads 2 and 3 |
| B-5 | `SPIKE_SECRET` not declared; hosted provisioning not atomic | Secret documented in `wrangler.toml`; `wrangler secret put` runs before `wrangler deploy`; Worker never publicly callable without secret |
| B-6 | `wrangler r2 object list` unsupported | Removed; object existence verified key-by-key via `wrangler r2 object get` (`key_absent` / `key_exists` helpers) |
| B-7 | Worker/bucket absence checks fail-open; no resource tracking | `BUCKET_CREATED` and `WORKER_DEPLOYED` flags track created resources; cleanup only attempts to delete what was created; `key_exists_worker` and bucket list checks are explicit pass/fail |
| B-8 | CF-P-8 ordered before CF-P-9 but requires hosted analytics | Probe execution order explicitly stated (§5 header): CF-P-9 executes before CF-P-8; CF-P-8 captures definitive hosted CPU analytics after CF-P-9 runs |
| AH-1 | HTTP results not asserted in executable code | `assert_http` helper added; all curl status codes asserted with `exit 1` on mismatch |
| AH-2 | `info.format` string representation unverified | Format normalized to `image/X` before checking; Worker logs raw value; CF-P-2 instructs recording actual format string from generated types |
| AH-3 | No ETag race test | Test D added to CF-P-4; documents race endpoint or unit-test-only path |

---

*Proposal Rev 4 — 2026-08-15 — awaiting §1.2 Phase 1 three-party sign-off*
