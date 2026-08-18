# Gate 2B — Cloudflare R2 + Images Binding Feasibility Spike
## Proposal Rev 2 — 2026-08-15

**Supersedes:** Rev 1 (not approved — 15 blockers, Codex SHA-256 `36df262b8420ac3833679fd4cfe9161f1feb689aa6aab666ef907f6803e37b21`)

---

## §1 Governance

### §1.1 Security Constraints (permanent — cannot be overridden)

- `CLOUDFLARE_API_TOKEN`, `SPIKE_SECRET`, and any Cloudflare credential never in client code, never in the repo, never sent to Claude.
- `ANON_KEY` and `SERVICE_ROLE_KEY` are runtime environment variables only; never written to any file, echoed, or logged.
- No cloud operation (bucket creation, Worker deploy, R2 write, `wrangler dev --remote`, transformation call) is authorized until §1.2 sign-off is complete.
- Three-party governance: **Bill + Claude + Codex** must all approve before any cloud operation or code edit against forkensics infrastructure.
- Authorized Supabase project: `hkfrbdpedrxmbsawnbpr` (forkensics-dev ONLY). `torkgydbvktqebssfpdi` (forkensics-prod) NEVER.
- Authorized Cloudflare account: `Billmags@gmail.com`. All spike resources are tagged `-spike` and cleaned up at CF-P-12.

### §1.2 Three-Party Sign-Off

| Party | Status | Note |
|-------|--------|------|
| Claude | ⬜ pending | |
| Codex | ⬜ pending | |
| Bill | ⬜ pending | |

**No authorized operation begins until all three rows show ✅ COMPLETE.**

### §1.3 CF-P-0 Activation — Reconciliation (B-14)

The Images & Stream plan was activated on 2026-08-15 **before** this proposal's §1.2 sign-off. This was a zero-dollar account configuration action (no storage add-ons selected, both "Cloudflare Images" hosted storage and "Cloudflare Stream" checkboxes left unchecked). Bill executed it directly in the Cloudflare Dashboard. No Worker code was deployed, no R2 bucket was created, no transformation was called, and no data was written. The action is irreversible in the sense that the plan is now active, but it carries no ongoing cost and can be cancelled without data loss. It is recorded here as an already-completed prerequisite, not a read-only check.

---

## §2 Context

### §2.1 Why This Proposal Exists

Gate 2B Rev 15 (hosted magick-wasm spike) returned HTTP 546 — pre-handler resource exhaustion confirmed by Dashboard logs showing zero Edge Function entries despite one API Gateway entry. The `@imagemagick/magick-wasm` 9.3 MB bundle exhausts the hosted CPU budget during module import. No further magick-wasm experiments are authorized.

Gate 2B Rev 20 proposed Supabase managed Image Transformations (imgproxy). P-0 plan check on 2026-08-15 confirmed forkensics org is on the Free plan; Storage Image Transformations require Pro or above. Rev 20 closed as **P-0 BLOCKED**.

This proposal tests the Fallback Rank 1 architecture: **Cloudflare R2 + Images binding**, where image transformation runs in Cloudflare's managed pipeline entirely outside the Worker's JavaScript CPU budget.

### §2.2 CF-P-0 — Plan Eligibility (COMPLETE — PASS)

**Executed: 2026-08-15**

| Check | Result |
|-------|--------|
| Cloudflare account | `Billmags@gmail.com` — confirmed |
| Images & Stream plan | ✅ Activated at $0/month (2026-08-15, Bill) — no hosted storage selected |
| R2 Workers binding on free tier | ✅ Confirmed — Cloudflare docs (2026-07-08): "All users are on the Images Free plan by default, which includes access to the transformations feature, allowing you to optimize images stored outside of Images, like in R2." |
| Free transformation quota | 5,000 unique transformations/month; spike will consume ≤ 20 |
| Existing R2 bucket | None — bucket creation is CF-P-1 |
| Workers plan (see §2.3) | Must be confirmed before any deploy |

**CF-P-0 verdict: PASS (Images). Workers plan check is CF-P-0b below.**

### §2.3 CF-P-0b — Workers Plan Eligibility (must complete before CF-P-2)

Workers Free limits CPU time to **10 ms per request**. Workers Paid ($5/month) raises this limit significantly. The Images binding transform runs in Cloudflare's managed pipeline and does not count against Worker CPU time. However, the surrounding Worker JS (R2 reads, bounded stream copy, SHA-256 computation over up to 5 MB, R2 write) must be confirmed to fit within the account's actual CPU budget.

**Authorized read-only action:** Navigate to Cloudflare Dashboard → Workers & Pages → Overview and confirm whether the account is on Workers Free or Workers Paid.

**Evidence to capture:**
- Plan name and CPU-per-request limit as shown in the Dashboard.

**Threshold alignment:**
| Workers Plan | CPU limit | CF-P-8 PASS threshold |
|-------------|-----------|----------------------|
| Free | 10 ms | < 10 ms |
| Paid | 50 ms (standard) | < 50 ms |

If Workers Free and Worker JS CPU time exceeds 10 ms during CF-P-8, upgrade to Workers Paid ($5/month) requires separate three-party approval before continuing.

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
  ├─ auth boundary (HMAC or CF service token — see §4.6)
  ├─ reads R2 object size → rejects if > 10 MB (no transform charged)
  ├─ calls Images binding .info() [free] → validates format, dimensions, animation
  ├─ calls Images binding .transform() + .output() → WebP
  ├─ bounded stream read (≤ 5 MB + 1 byte ceiling, fail before R2 write)
  ├─ validates response: status, Content-Type: image/webp, nonempty body
  ├─ computes SHA-256 of sanitized output
  └─ writes sanitized WebP to R2: display/{basename}.webp
  │
  ▼
Supabase Edge Function: upload-finalize (future)
  └─ receives { original_key, display_key, sha256, size_bytes }
  └─ advances upload session in PostgreSQL
```

### §3.2 Why This Solves the Gate 2B FAIL

| Problem | Solution |
|---------|----------|
| magick-wasm 9.3 MB exhausts Edge Function CPU on import | No WASM — Images binding is Cloudflare-managed, runs outside Worker memory |
| Supabase Free plan excludes managed transformations | Cloudflare Images $0/month tier includes transformation binding |
| Public URL required for URL-based transformation | R2 binding passes raw bytes — bucket stays private, no public URL |

### §3.3 Spike Scope

This spike tests the Cloudflare transformation step only. It does not deploy or modify:
- `upload-authorize` Edge Function (frozen at Gate 6 baseline)
- `upload-finalize` Edge Function (not yet written)
- Any Supabase table, RLS policy, or migration
- Any production R2 bucket or production resource

All spike resources use the suffix `-spike` (Worker: `forkensics-image-spike`, bucket: `forkensics-dev-spike`).

---

## §4 Constraints

### §4.1 Input Limits
- Images binding `.input()` accepts up to **20 MB** per Cloudflare docs.
- Forkensics upload cap is **10 MB** — fits within limit.
- Worker enforces the 10 MB cap against the R2 object's `size` metadata **before** calling `.info()` or any billable transform.

### §4.2 Output Ceiling
- Sanitized display image must be ≤ **5 MB** before R2 write or database key advancement.
- Ceiling is enforced via a **bounded stream read** — the transform response body is read incrementally and aborted if byte count exceeds `MAX_OUTPUT_BYTES` before buffering completes.

### §4.3 Metadata Stripping
- Must be **proven** at byte level. ExifTool inspection of output WebP is required before any probe passes.
- "Cloudflare removes metadata" is not accepted as evidence without byte-level confirmation.

### §4.4 Caching
- Per Cloudflare docs: "Responses from the Images binding are not automatically cached." Every uncached call performs a full decode and re-encode.
- The spike tests transformation correctness. Workers Cache configuration is a production concern, not a spike gate.

### §4.5 Quota Awareness
- 5,000 unique transformations/month free. Spike will consume ≤ 20 total (2 fixtures × probes).
- `.info()` calls are free and do not count against quota.

### §4.6 Production Auth — Narrow Scoped Credential (B-13)

The Supabase service-role JWT must **not** be transmitted to Cloudflare. It is a broadly privileged, long-lived credential whose compromise scope extends far beyond image transformation.

For the spike, `SPIKE_SECRET` is a dedicated random secret used only for this Worker, injected via `wrangler secret put` and never printed. For production, the Worker must use one of:
- **Option A:** Cloudflare service token (scoped to this Worker only), verified via `CF-Access-Client-Id` / `CF-Access-Client-Secret` headers.
- **Option B:** HMAC-SHA256 request signing with a per-request timestamp and a short replay window (≤ 60 seconds), keyed by a secret shared only between the Supabase caller and this Worker.

OQ-3 (see §9) must be resolved before production Worker implementation begins.

### §4.7 Wrangler Version (B-15)

Record the exact installed Wrangler version via `npx wrangler --version` at the start of every probe script. All `wrangler types`, `wrangler deploy`, `wrangler dev --remote`, `wrangler r2 object`, and `wrangler delete` commands are used exactly as documented at `developers.cloudflare.com/workers/wrangler/commands/`. `wrangler check` is not a documented command and must not be used; use `wrangler types` then `tsc --noEmit`.

---

## §5 Probe Sequence

**Probes execute in order. Any FAIL stops the sequence. The runner EXIT trap (§5.0) fires on every exit — success, failure, interruption, or timeout — and attempts cleanup regardless.**

---

### §5.0 — Runner Preflight and EXIT Trap

Before CF-P-1 executes, the runner script must:

**Preflight checks (all must pass — no cloud operations yet):**
1. `npx wrangler --version` — record exact version.
2. `which exiftool` — confirm ExifTool is installed.
3. `[ -n "$SPIKE_SECRET" ]` — confirm `SPIKE_SECRET` is set and non-empty. **Do not print it.**
4. `[ -n "$CLOUDFLARE_API_TOKEN" ]` — confirm token is set and non-empty. **Do not print it.**
5. Confirm no existing bucket named `forkensics-dev-spike`: `npx wrangler r2 bucket list` must not show it.
6. Confirm no deployed Worker named `forkensics-image-spike`: `npx wrangler list` must not show it.

**EXIT trap (install before CF-P-1):**

```bash
CLEANUP_ATTEMPTED=false

cleanup() {
  if [ "$CLEANUP_ATTEMPTED" = "true" ]; then return; fi
  CLEANUP_ATTEMPTED=true
  echo "[CLEANUP] Starting — $(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # 1. Undeploy Worker first (prevents new writes during object cleanup)
  npx wrangler delete forkensics-image-spike --force 2>/dev/null || true

  # 2. Delete known spike objects
  for KEY in \
    "spike/fixture-exif.jpg" \
    "spike/fixture-icc.png" \
    "display/fixture-exif.jpg.webp" \
    "display/fixture-icc.png.webp"; do
    npx wrangler r2 object delete forkensics-dev-spike "$KEY" 2>/dev/null || true
  done

  # 3. Confirm zero objects before bucket deletion
  REMAINING=$(npx wrangler r2 object list forkensics-dev-spike --json 2>/dev/null | jq 'length')
  echo "[CLEANUP] Objects remaining: $REMAINING"

  # 4. Delete bucket
  npx wrangler r2 bucket delete forkensics-dev-spike 2>/dev/null || true

  echo "[CLEANUP] Complete — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
}

trap cleanup EXIT
```

---

### CF-P-1 — R2 Bucket Creation

**Objective:** Create the private spike bucket.

**Authorized cloud operation (requires §1.2 sign-off):**
- `npx wrangler r2 bucket create forkensics-dev-spike`
- Public access: disabled (default for R2 — confirm no `r2.dev` subdomain is enabled).

**Evidence to capture:**
- `npx wrangler r2 bucket list` output showing `forkensics-dev-spike`.
- Dashboard confirmation that public access is off.

**Pass:** Bucket present in list, public access disabled.
**Fail:** Any creation error, or public access found enabled.

---

### CF-P-2 — Worker Scaffolding and Type Generation (local only)

**Objective:** Scaffold the spike Worker with properly typed bindings; confirm static checks pass.

**Authorized local actions (no cloud operation):**
- `npx wrangler init forkensics-image-spike --no-bundle`
- Create `wrangler.toml`:

```toml
name = "forkensics-image-spike"
main = "src/index.ts"
compatibility_date = "2026-08-15"

[images]
binding = "IMAGES"

[[r2_buckets]]
binding = "BUCKET"
bucket_name = "forkensics-dev-spike"
preview_bucket_name = "forkensics-dev-spike"

[vars]
# SPIKE_SECRET is injected via `wrangler secret put`, not here
```

- `npx wrangler types` — generates `worker-configuration.d.ts` with a typed `Env` interface.
- Write `src/index.ts` using the generated `Env` (see §6 for authoritative code).
- `tsc --noEmit` — zero errors required.

**Evidence to capture:**
- `npx wrangler --version` output.
- `npx wrangler types` output (confirms binding names recognized).
- `tsc --noEmit` output: zero errors.

**Pass:** `wrangler types` succeeds, `tsc --noEmit` exits 0, zero errors.
**Fail:** Any type error, unrecognized binding, or build failure.

---

### CF-P-3 — Fixture Upload to Spike Bucket

**Objective:** Upload two known test fixtures to R2.

**Fixtures:**
| Local path | R2 key | Format | Size | Contains |
|------------|--------|--------|------|----------|
| `fixtures/fixture-exif.jpg` | `spike/fixture-exif.jpg` | JPEG | ~500 KB | GPS + EXIF metadata |
| `fixtures/fixture-icc.png` | `spike/fixture-icc.png` | PNG | ~300 KB | ICC color profile |
| `fixtures/fixture-oversized.jpg` | `spike/fixture-oversized.jpg` | JPEG | > 10 MB | Proves rejection before transform |

**Authorized cloud operations:**
```bash
npx wrangler r2 object put forkensics-dev-spike/spike/fixture-exif.jpg \
  --file ./fixtures/fixture-exif.jpg
npx wrangler r2 object put forkensics-dev-spike/spike/fixture-icc.png \
  --file ./fixtures/fixture-icc.png
npx wrangler r2 object put forkensics-dev-spike/spike/fixture-oversized.jpg \
  --file ./fixtures/fixture-oversized.jpg
```

**Evidence to capture:**
- `npx wrangler r2 object list forkensics-dev-spike --prefix spike/` — all three keys present.

**Pass:** All three keys in listing.
**Fail:** Any upload error; any key absent from listing.

---

### CF-P-4 — Local Transformation Test (`wrangler dev --remote`)

**Objective:** Confirm the Images binding transforms R2 objects to WebP in Cloudflare's remote preview environment.

**Note on `wrangler dev --remote` (B-5):** This uploads Worker code to a temporary Cloudflare-hosted preview environment. It is a cloud operation, explicitly authorized here. The preview uses `preview_bucket_name = "forkensics-dev-spike"` (configured in CF-P-2). The preview Worker is ephemeral and does not create a named production deployment.

**Inject SPIKE_SECRET for local dev (do not print):**
```bash
# Inject as --var for wrangler dev only
# Never echo or log $SPIKE_SECRET
```

**Authorized cloud operation:**
```bash
npx wrangler dev --remote src/index.ts &
DEV_PID=$!
sleep 5  # wait for preview to be ready
```

**Test A — oversized input (must reject before transform, no quota consumed):**
```bash
curl -s -o /dev/null -w "%{http_code}" \
  -H "Authorization: Bearer $SPIKE_SECRET" \
  http://localhost:8787/transform/spike/fixture-oversized.jpg
# Expected: 422
```

**Test B — JPEG with EXIF:**
```bash
curl -s \
  -H "Authorization: Bearer $SPIKE_SECRET" \
  -D cf_p4_jpeg_headers.txt \
  -o cf_p4_jpeg_output.webp \
  http://localhost:8787/transform/spike/fixture-exif.jpg
```

**Test C — PNG with ICC:**
```bash
curl -s \
  -H "Authorization: Bearer $SPIKE_SECRET" \
  -D cf_p4_png_headers.txt \
  -o cf_p4_png_output.webp \
  http://localhost:8787/transform/spike/fixture-icc.png
```

```bash
kill $DEV_PID
```

**Evidence to capture (per test):**
- HTTP status code.
- `Content-Type` header from `-D` dump file.
- `X-Forkensics-SHA256` header.
- `X-Forkensics-Size` header.
- Output file size in bytes (`wc -c`).
- Worker console CPU time.

**Pass (Test A):** HTTP 422, no output file written to R2.
**Pass (Tests B, C):** HTTP 200, `Content-Type: image/webp`, `X-Forkensics-SHA256` present, size > 0 and ≤ 5,242,880 bytes.
**Fail:** Any non-expected status, wrong content type, missing SHA header, size > 5 MB, Worker exception.

---

### CF-P-5 — Metadata Stripping Verification

**Objective:** Prove both output WebP files contain zero prohibited metadata.

**Method:**
```bash
exiftool cf_p4_jpeg_output.webp
exiftool cf_p4_png_output.webp
```

**Prohibited metadata families (both outputs must be clear):**
| Family | Pass if |
|--------|---------|
| EXIF (Make, Model, GPS*, DateTimeOriginal, etc.) | Zero EXIF tags present |
| XMP (all namespaces) | Zero XMP tags present |
| ICC_Profile | Zero ICC tags present |
| Comment (ImageDescription, UserComment) | Zero comment tags present |

Structural properties (File Size, Image Width, Image Height, Bit Depth, Color Type) reported by ExifTool are permitted — they are not metadata.

**Evidence to capture:**
- Full `exiftool` output for both files.
- Explicit confirmation: "No prohibited tags found" or list of any violations.

**Pass:** Zero prohibited metadata families in both outputs.
**Fail:** Any EXIF, XMP, ICC, or comment tag present in either output.
**Inconclusive:** ExifTool unavailable — install and re-run; do not advance.

---

### CF-P-6 — Output WebP Structural Verification

**Objective:** Confirm both outputs are valid WebP with clean VP8X flags, exact RIFF size, and no forbidden chunk combinations.

**Checks (applied to both output files):**

1. **RIFF header:** bytes 0–3 = `52 49 46 46` (`RIFF`); bytes 8–11 = `57 45 42 50` (`WEBP`).
2. **RIFF declared size:** `riff_size = uint32LE(bytes[4..8])`. Exact check: `actual_file_size == riff_size + 8`. No extra bytes permitted (B-12).
3. **Chunk data region:** `bytes[12..declared_total)` where `declared_total = riff_size + 8`.
4. **Valid WebP chunk sequences (exactly one of five):**
   - `VP8 ` (simple lossy)
   - `VP8L` (lossless; alpha may be embedded in bitstream)
   - `VP8X` + `VP8 ` (extended lossy, no alpha)
   - `VP8X` + `ALPH` + `VP8 ` (extended lossy with alpha)
   - `VP8X` + `VP8L` (extended lossless)
   - `ALPH` + `VP8L` is **forbidden**.
5. **VP8X flag validation (if VP8X present):** `flags_u32 = uint32LE(VP8X_chunk_data[0..4])`. Permitted: Alpha = `0x10`. Forbidden: Animation = `0x02`, XMP = `0x04`, EXIF = `0x08`, ICC = `0x20`, reserved `0xC1`. Required: `(flags_u32 & ~0x00000010) === 0`.

**Evidence to capture:**
- Hex dump of bytes 0–15 for each output.
- RIFF declared size vs. actual file size (must be equal: `actual == riff_size + 8`).
- Chunk sequence identified.
- VP8X flags value in hex (if applicable).

**Pass:** Valid RIFF/WEBP header, exact size match, valid chunk sequence, clean VP8X flags (if present).
**Fail:** Invalid header, size mismatch, ALPH+VP8L, forbidden VP8X flag bits set.

---

### CF-P-7 — SHA-256 Integrity

**Objective:** Confirm Worker-computed SHA-256 matches independent hash for both outputs.

```bash
shasum -a 256 cf_p4_jpeg_output.webp
shasum -a 256 cf_p4_png_output.webp
```

Compare each against the corresponding `X-Forkensics-SHA256` header captured in CF-P-4.

**Evidence to capture:**
- `X-Forkensics-SHA256` value (JPEG), `shasum` output (JPEG) — must match.
- `X-Forkensics-SHA256` value (PNG), `shasum` output (PNG) — must match.

**Pass:** Both pairs match exactly.
**Fail:** Any mismatch, missing header, or empty hash.

---

### CF-P-8 — Worker CPU Budget

**Objective:** Confirm Worker JS CPU time fits within the account's Workers plan limit (determined in CF-P-0b).

**Method:** Read CPU time from `wrangler dev --remote` console output during CF-P-4 requests.

**Pass/fail thresholds (per CF-P-0b result):**
| Workers Plan | CPU budget | PASS | INCONCLUSIVE | FAIL |
|-------------|-----------|------|-------------|------|
| Free | 10 ms | < 10 ms | — | ≥ 10 ms |
| Paid | 50 ms | < 50 ms | 50–200 ms | ≥ 200 ms |

Also confirm: no 546 response, no out-of-memory error.

**Evidence to capture:**
- CPU time per request from Worker console.
- Workers plan confirmed in CF-P-0b.

**Pass:** CPU time within plan limit, no 546, no OOM.
**Fail:** CPU time exceeds plan limit, 546, or OOM.
**Inconclusive (Paid only):** 50–200 ms — note for production SLA, continue.

---

### CF-P-9 — Hosted Worker Deploy

**Objective:** Deploy the spike Worker to production Cloudflare and confirm end-to-end transformation in the hosted environment.

**Inject SPIKE_SECRET as a Worker secret (do not print):**
```bash
# SPIKE_SECRET must already be set in shell environment
printf '%s' "$SPIKE_SECRET" | npx wrangler secret put SPIKE_SECRET
```

**Authorized cloud operation:**
```bash
npx wrangler deploy
```

**Test (JPEG fixture only — PNG confirmed in CF-P-4):**
```bash
WORKER_URL="https://forkensics-image-spike.<account>.workers.dev"
curl -s \
  -H "Authorization: Bearer $SPIKE_SECRET" \
  -D cf_p9_hosted_headers.txt \
  -o cf_p9_hosted_output.webp \
  "${WORKER_URL}/transform/spike/fixture-exif.jpg"
```

**Evidence to capture:**
- HTTP status.
- `Content-Type`, `X-Forkensics-SHA256`, `X-Forkensics-Size` headers.
- `shasum -a 256 cf_p9_hosted_output.webp` vs `X-Forkensics-SHA256`.
- Output file size.

**Pass:** HTTP 200, `image/webp`, SHA-256 matches, size ≤ 5 MB.
**Fail:** Non-200, wrong content type, SHA mismatch, size > 5 MB, 546.

---

### CF-P-10 — Auth Boundary

**Objective:** Confirm the deployed Worker rejects unauthenticated requests.

```bash
WORKER_URL="https://forkensics-image-spike.<account>.workers.dev"

# No auth header
STATUS_NO_AUTH=$(curl -s -o /dev/null -w "%{http_code}" \
  "${WORKER_URL}/transform/spike/fixture-exif.jpg")

# Wrong token
STATUS_WRONG=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "Authorization: Bearer wrongtoken" \
  "${WORKER_URL}/transform/spike/fixture-exif.jpg")

echo "No-auth status: $STATUS_NO_AUTH (expected 401)"
echo "Wrong-token status: $STATUS_WRONG (expected 401)"
```

**Evidence to capture:**
- HTTP status for each unauthenticated variant.

**Pass:** Both return 401. (Authenticated request already confirmed 200 in CF-P-9.)
**Fail:** Either unauthenticated request returns 200.

---

### CF-P-11 — Write-Back Persistence Verification (B-8)

The authoritative Worker (§6) always writes the display object during every successful transform. Write-back began at CF-P-4 (local) and CF-P-9 (hosted). CF-P-11 verifies that the objects created by CF-P-9 actually persist in R2 under the correct keys.

**Expected display keys** (from Worker: `display/${key.split('/').pop()}.webp`):
- `display/fixture-exif.jpg.webp` (from JPEG fixture)
- `display/fixture-icc.png.webp` (from PNG fixture, written at CF-P-4 local)

**Verification:**
```bash
npx wrangler r2 object list forkensics-dev-spike --prefix display/
npx wrangler r2 object get forkensics-dev-spike/display/fixture-exif.jpg.webp \
  --file cf_p11_display_verify.webp
shasum -a 256 cf_p11_display_verify.webp
```

Compare SHA-256 of downloaded display object against `X-Forkensics-SHA256` from CF-P-9.

**Evidence to capture:**
- `wrangler r2 object list` showing both display keys.
- SHA-256 of downloaded hosted display object matches CF-P-9 header.

**Pass:** Both display keys present, SHA-256 matches.
**Fail:** Either key absent, SHA mismatch, download error.

---

### CF-P-12 — Cleanup

**Objective:** Remove all spike resources. No spike Worker deployed, no spike data in R2, no spike bucket.

**Note:** The EXIT trap (§5.0) also attempts this cleanup automatically. CF-P-12 is the explicit authorized cleanup step when all probes have passed. Run it even if the EXIT trap already fired — it is idempotent.

**Authorized actions (in order):**
```bash
# 1. Undeploy Worker first (prevents new writes during cleanup)
npx wrangler delete forkensics-image-spike --force

# 2. Confirm Worker is gone
npx wrangler list  # must not show forkensics-image-spike

# 3. Delete all spike objects
npx wrangler r2 object delete forkensics-dev-spike spike/fixture-exif.jpg
npx wrangler r2 object delete forkensics-dev-spike spike/fixture-icc.png
npx wrangler r2 object delete forkensics-dev-spike spike/fixture-oversized.jpg
npx wrangler r2 object delete forkensics-dev-spike display/fixture-exif.jpg.webp
npx wrangler r2 object delete forkensics-dev-spike display/fixture-icc.png.webp

# 4. Assert zero objects
npx wrangler r2 object list forkensics-dev-spike  # must return empty

# 5. Delete bucket
npx wrangler r2 bucket delete forkensics-dev-spike

# 6. Assert bucket gone
npx wrangler r2 bucket list  # must not show forkensics-dev-spike
```

**Evidence to capture:**
- `wrangler list` output: Worker absent.
- `wrangler r2 object list` output before bucket deletion: zero objects.
- `wrangler r2 bucket list` output: bucket absent.

**Pass:** Worker absent, zero objects, bucket absent.
**Fail:** Any object remaining, bucket deletion error, Worker still listed.

---

## §6 Authoritative Worker Code

```typescript
// src/index.ts — forkensics-image-spike (Rev 2)
// SPIKE ONLY — not production code

// Types are generated by `wrangler types` into worker-configuration.d.ts.
// Do not use `any` for IMAGES or BUCKET.

const MAX_INPUT_BYTES  = 10 * 1024 * 1024; // 10 MB — Forkensics upload cap
const MAX_OUTPUT_BYTES = 5  * 1024 * 1024; // 5 MB  — sanitized display ceiling
const MAX_DIMENSION_PX = 4096;             // pixel ceiling per side

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
    if (!key || key.includes("..")) {
      return new Response("Invalid key", { status: 400 });
    }

    // ── R2 fetch + input size gate ─────────────────────────────────────────
    const object = await env.BUCKET.get(key);
    if (!object) {
      return new Response("Not found", { status: 404 });
    }
    if ((object.size ?? 0) > MAX_INPUT_BYTES) {
      return new Response(
        `Input too large: ${object.size} bytes (max ${MAX_INPUT_BYTES})`,
        { status: 422 }
      );
    }

    // ── .info() pre-validation (free — no quota consumed) ─────────────────
    // Re-fetch for info since the stream is consumed by .info()
    const infoObject = await env.BUCKET.get(key);
    if (!infoObject) {
      return new Response("Not found during info check", { status: 404 });
    }
    let info: { format: string; width: number; height: number; anim?: boolean };
    try {
      info = await env.IMAGES.info(infoObject.body);
    } catch (err) {
      return new Response(`Info error: ${err}`, { status: 422 });
    }
    if (info.anim) {
      return new Response("Animated images are not permitted", { status: 422 });
    }
    if (info.width > MAX_DIMENSION_PX || info.height > MAX_DIMENSION_PX) {
      return new Response(
        `Image dimensions ${info.width}×${info.height} exceed ceiling ${MAX_DIMENSION_PX}px`,
        { status: 422 }
      );
    }

    // ── Transform ──────────────────────────────────────────────────────────
    // Re-fetch for transform (info() consumed the previous stream)
    const transformObject = await env.BUCKET.get(key);
    if (!transformObject) {
      return new Response("Not found during transform", { status: 404 });
    }

    let transformResponse: Response;
    try {
      transformResponse = (
        await env.IMAGES.input(transformObject.body)
          .transform({ width: 1280, height: 1280, fit: "scale-down" })
          .output({ format: "image/webp", quality: 85 })
      ).response();
    } catch (err) {
      return new Response(`Transform error: ${err}`, { status: 500 });
    }

    // ── Validate transform response before buffering ───────────────────────
    if (!transformResponse.ok) {
      return new Response(
        `Transform returned non-OK status: ${transformResponse.status}`,
        { status: 502 }
      );
    }
    const ct = transformResponse.headers.get("Content-Type") ?? "";
    if (!ct.includes("image/webp")) {
      return new Response(`Unexpected Content-Type from transform: ${ct}`, {
        status: 502,
      });
    }
    if (!transformResponse.body) {
      return new Response("Transform returned empty body", { status: 502 });
    }

    // ── Bounded stream read — enforce output ceiling before buffering ───────
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
          `Transform output exceeds ${MAX_OUTPUT_BYTES} byte ceiling`,
          { status: 422 }
        );
      }
      chunks.push(value);
    }
    if (totalBytes === 0) {
      return new Response("Transform output is empty", { status: 502 });
    }

    // Assemble buffer
    const outputBytes = new Uint8Array(totalBytes);
    let offset = 0;
    for (const chunk of chunks) {
      outputBytes.set(chunk, offset);
      offset += chunk.byteLength;
    }

    // ── SHA-256 ────────────────────────────────────────────────────────────
    const hashBuffer = await crypto.subtle.digest("SHA-256", outputBytes);
    const hashHex = Array.from(new Uint8Array(hashBuffer))
      .map((b) => b.toString(16).padStart(2, "0"))
      .join("");

    // ── Write sanitized display copy to R2 ────────────────────────────────
    // Display key: flatten to basename to avoid path nesting
    const basename = key.split("/").pop()!;
    const displayKey = `display/${basename}.webp`;
    await env.BUCKET.put(displayKey, outputBytes, {
      httpMetadata: { contentType: "image/webp" },
    });

    return new Response(outputBytes, {
      status: 200,
      headers: {
        "Content-Type": "image/webp",
        "X-Forkensics-SHA256": hashHex,
        "X-Forkensics-Display-Key": displayKey,
        "X-Forkensics-Size": String(totalBytes),
      },
    });
  },
} satisfies ExportedHandler<Env>;
```

**Display key derivation:**
| Input key | Display key |
|-----------|-------------|
| `spike/fixture-exif.jpg` | `display/fixture-exif.jpg.webp` |
| `spike/fixture-icc.png` | `display/fixture-icc.png.webp` |

---

## §7 Verdict Criteria

| Tier | Condition | Meaning |
|------|-----------|---------|
| **PASS** | CF-P-0b + CF-P-1 through CF-P-12 all pass | Cloudflare R2 + Images binding is viable. Proceed to production architecture design. |
| **INCONCLUSIVE** | CF-P-8 CPU time in inconclusive range (Paid plan only) | Functional but slower than expected. Note for production SLA; does not block PASS. |
| **FAIL** | Any probe returns FAIL | Architecture not viable at that probe. Stop, document, evaluate Fallback Rank 2 (Sharp/libvips on dedicated compute). |

---

## §8 Fallback Rank 2 (if this spike fails)

Sharp/libvips on dedicated background compute (Cloud Run / Fly.io / Lambda). Full control, no vendor transformation API, operationally heaviest — adds a deployed service, queue/retry logic, and monitoring. Requires a new spike proposal if Rank 1 fails.

---

## §9 Open Questions (must resolve before production implementation)

| # | Question | Owner |
|---|----------|-------|
| OQ-1 | Does the production upload flow presign directly to R2, or does `upload-authorize` proxy the PUT? | Bill + architecture review |
| OQ-2 | Should the display WebP key be deterministic (hash of original) or random (UUID)? | Bill |
| OQ-3 | Production Worker auth: Cloudflare service token (Option A) or HMAC-SHA256 signing (Option B)? See §4.6. | Bill + Codex |

---

## §10 Blocker Resolution Table (Rev 1 → Rev 2)

| # | Rev 1 Blocker | Resolution |
|---|--------------|------------|
| B-1 | `fit: "inside"` invalid | Changed to `fit: "scale-down"` in §6 |
| B-2 | curl missing `Authorization` in CF-P-4/P-5 | All curl calls include `-H "Authorization: Bearer $SPIKE_SECRET"`; secret never printed |
| B-3 | `IMAGES: any` defeats type check | `wrangler types` generates `Env`; `satisfies ExportedHandler<Env>` added; no `any` |
| B-4 | Workers plan eligibility missing | CF-P-0b added; thresholds aligned per plan in CF-P-8 |
| B-5 | `wrangler dev --remote` unauthorized cloud op | Explicitly authorized in CF-P-4; `preview_bucket_name` added to `wrangler.toml` |
| B-6 | Cleanup not guaranteed on failure | EXIT trap installed before CF-P-1 (§5.0); cleanup runs on any exit |
| B-7 | Cleanup display key wrong | Worker uses `key.split('/').pop()` → `display/fixture-exif.jpg.webp`; CF-P-12 matches |
| B-8 | CF-P-4 already writes back; CF-P-11 inconsistent | CF-P-11 redefined as persistence verification of objects written at CF-P-4/CF-P-9 |
| B-9 | PNG fixture never transformed | Both JPEG and PNG tested in CF-P-4 (Tests B and C) |
| B-10 | Transform response not validated | Status, Content-Type, nonempty body checked before bounded read |
| B-11 | Input validation incomplete | R2 object size gate (10 MB), `.info()` pre-validation (format, dimensions, animation), oversized fixture in CF-P-3 |
| B-12 | RIFF length must match exactly | CF-P-6 requires `actual_file_size == riff_size + 8`; no extra bytes permitted |
| B-13 | Production auth must not use service-role JWT | §4.6 added; production options are CF service token or HMAC; OQ-3 tracks decision |
| B-14 | CF-P-0 activation not reconciled | §1.3 added: records activation as already-completed zero-dollar config, who authorized, exact effect |
| B-15 | Wrangler version not pinned; `wrangler check` undocumented | §4.7 added; `wrangler types` + `tsc --noEmit` used throughout; `wrangler check` removed |

---

*Proposal Rev 2 — 2026-08-15 — awaiting §1.2 three-party sign-off*
