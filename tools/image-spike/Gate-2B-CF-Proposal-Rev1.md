# Gate 2B — Cloudflare R2 + Images Binding Feasibility Spike
## Proposal Rev 1 — 2026-08-15

---

## §1 Governance

### §1.1 Security Constraints (permanent — cannot be overridden)

- `CLOUDFLARE_API_TOKEN` and any Cloudflare secret never in client code, never in the repo, never sent to Claude.
- `ANON_KEY` and `SERVICE_ROLE_KEY` are runtime environment variables only; never written to any file, echoed, or logged.
- No cloud operation (bucket creation, Worker deploy, R2 write, transformation call) is authorized until §1.2 sign-off is complete.
- Three-party governance: **Bill + Claude + Codex** must all approve before any cloud operation or code edit against forkensics infrastructure.
- Authorized Supabase project: `hkfrbdpedrxmbsawnbpr` (forkensics-dev ONLY). `torkgydbvktqebssfpdi` (forkensics-prod) NEVER.
- Authorized Cloudflare account: `Billmags@gmail.com` (confirmed via Dashboard — 2026-08-15). All spike resources are tagged spike and cleaned up at the end.

### §1.2 Three-Party Sign-Off

| Party | Status | Note |
|-------|--------|------|
| Claude | ⬜ pending | |
| Codex | ⬜ pending | |
| Bill | ⬜ pending | |

**No authorized operation begins until all three rows show ✅ COMPLETE.**

---

## §2 Context

### §2.1 Why This Proposal Exists

Gate 2B Rev 15 (hosted magick-wasm spike) produced an HTTP 546 — pre-handler resource exhaustion. Dashboard logs confirmed zero Edge Function entries despite one API Gateway entry, proving the `@imagemagick/magick-wasm` 9.3 MB bundle exhausts the hosted CPU budget during module import. No further magick-wasm experiments are authorized.

Gate 2B Rev 20 proposed using Supabase managed Image Transformations (imgproxy). P-0 plan check on 2026-08-15 confirmed the forkensics organization is on the Free plan. Supabase Storage Image Transformations require Pro or above. Rev 20 was closed as **P-0 BLOCKED**.

This proposal tests the Fallback Rank 1 architecture: **Cloudflare R2 + Images binding**, where image transformation runs in Cloudflare's managed pipeline entirely outside the Worker's JavaScript memory budget.

### §2.2 CF-P-0 — Plan Eligibility (COMPLETE — PASS)

**Executed: 2026-08-15**

| Check | Result |
|-------|--------|
| Cloudflare account | `Billmags@gmail.com` — confirmed |
| Images plan (pre-activation) | Not subscribed (showing purchase page) |
| $0/month Images & Stream tier | Available — 5,000 unique transformations/month free |
| R2 Workers binding on free tier | **Confirmed** — Cloudflare docs (updated 2026-07-08): "All users are on the Images Free plan by default, which includes access to the transformations feature, allowing you to optimize images stored outside of Images, like in R2." |
| Plan activated | ✅ — $0/month, no storage add-ons selected, "Cloudflare Images" hosted storage unchecked, "Cloudflare Stream" unchecked |
| Existing R2 bucket | None — bucket creation is an authorized spike step |

**CF-P-0 verdict: PASS.** Images & Stream activated at $0/month. Transformation binding unlocked for R2 objects.

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
  ├─ reads original via R2 binding (env.BUCKET.get(key))
  ├─ calls Images binding (env.IMAGES.input(stream))
  ├─ .transform({ width, height, fit }) — resize within bounds
  ├─ .output({ format: "image/webp" }) — re-encode, metadata stripped
  ├─ buffers output bytes (≤ 5 MB ceiling — fail before advancing)
  ├─ computes SHA-256 of sanitized output
  └─ writes sanitized WebP to R2: forkensics-dev-display/{key}.webp
  │
  ▼
Supabase Edge Function: upload-finalize
  └─ receives { original_key, display_key, sha256, size_bytes }
  └─ advances upload session in PostgreSQL
```

### §3.2 Why This Solves the Gate 2B FAIL

| Problem | Solution |
|---------|----------|
| magick-wasm 9.3 MB exhausts Edge Function CPU budget on import | No WASM in Worker — Images binding is Cloudflare-managed, runs outside Worker memory |
| Supabase Free plan excludes managed transformations | Cloudflare Images $0/month tier includes transformation binding |
| Public URL required for URL-based transformation | R2 binding passes raw bytes — bucket stays private |

### §3.3 Spike Scope

This spike tests only the Cloudflare transformation step. It does not deploy or modify:
- `upload-authorize` Edge Function (frozen at Gate 6 baseline)
- `upload-finalize` Edge Function (not yet written)
- Any Supabase table, RLS policy, or migration
- The production R2 bucket or any production resource

All spike resources use the suffix `-spike` or are in a dedicated spike Worker and bucket, both cleaned up at CF-P-12.

---

## §4 Constraints

### §4.1 Input Limits (from Cloudflare docs, 2026-07-08)
- Images binding `.input()` accepts up to **20 MB** raw bytes from R2 or any source.
- Forkensics upload cap is **10 MB** — fits within this limit.

### §4.2 Output Ceiling
- Sanitized display image must be ≤ **5 MB** before database key is recorded.
- If transformed output exceeds 5 MB, Worker returns error; upload session does not advance.

### §4.3 Metadata Stripping
- Must be **proven**, not assumed. The spike explicitly inspects output WebP bytes for EXIF, GPS, XMP, ICC, and comment markers.
- "Cloudflare removes metadata" is not accepted as a pass criterion without byte-level evidence.

### §4.4 Caching
- Per Cloudflare docs: "Responses from the Images binding are not automatically cached. Every uncached call performs a full decode and re-encode."
- Production Worker must enable Workers Cache with `Cache-Control` headers.
- The spike tests transformation correctness; caching configuration is a production concern, not a spike gate.

### §4.5 Quota Awareness
- 5,000 unique transformations/month free. The spike will consume ≤ 20 transformations total.
- `.info()` calls are free and do not count against quota.

### §4.6 No Hosted Auth User Creation
- The spike makes no Supabase Auth calls.
- The Worker-to-Supabase boundary is covered in the `upload-finalize` proposal (future).

---

## §5 Probe Sequence

**Probes execute in order. Any FAIL or BLOCKED stops the sequence. No probe is skipped.**

---

### CF-P-1 — R2 Bucket Creation

**Objective:** Create the private spike bucket.

**Authorized action (requires §1.2 sign-off):**
- Create R2 bucket named `forkensics-dev-spike` in the `Billmags@gmail.com` account.
- Public access: **disabled**.
- No CORS rules, no public `r2.dev` subdomain.

**Evidence to capture:**
- Bucket name, region, creation timestamp from Dashboard or `wrangler r2 bucket list`.
- Confirm public access is off.

**Pass:** Bucket exists, public access disabled, list returns the bucket name.
**Fail:** Any error during creation; public access found enabled.

---

### CF-P-2 — Worker Scaffolding (local, no deploy)

**Objective:** Scaffold the spike Worker with R2 binding and Images binding configured.

**Authorized actions (local only — no deploy):**
- `wrangler init forkensics-image-spike --no-bundle`
- Add to `wrangler.toml`:

```toml
name = "forkensics-image-spike"
main = "src/index.ts"
compatibility_date = "2026-08-15"

[images]
binding = "IMAGES"

[[r2_buckets]]
binding = "BUCKET"
bucket_name = "forkensics-dev-spike"
```

- Write `src/index.ts` (see §6 for authoritative Worker code).
- Run `wrangler check` / `tsc --noEmit` locally. No deploy at this step.

**Evidence to capture:**
- `wrangler check` output: zero errors.
- `tsc --noEmit` output: zero errors.

**Pass:** Static checks pass, no type errors.
**Fail:** Any type error, missing binding type, or build error.

---

### CF-P-3 — Fixture Upload to Spike Bucket

**Objective:** Upload a known test fixture to R2 so the Worker has a real input.

**Fixtures (two — one JPEG, one PNG):**
| Key | Format | Size | Notes |
|-----|--------|------|-------|
| `spike/fixture-exif.jpg` | JPEG | ~500 KB | Contains GPS + EXIF metadata |
| `spike/fixture-icc.png` | PNG | ~300 KB | Contains ICC color profile |

**Authorized action:**
- `wrangler r2 object put forkensics-dev-spike/spike/fixture-exif.jpg --file ./fixtures/fixture-exif.jpg`
- `wrangler r2 object put forkensics-dev-spike/spike/fixture-icc.png --file ./fixtures/fixture-icc.png`

**Evidence to capture:**
- `wrangler r2 object list forkensics-dev-spike --prefix spike/` — confirm both keys present.

**Pass:** Both keys returned in listing.
**Fail:** Any upload error; key not found in list.

---

### CF-P-4 — Local Transformation Test (`wrangler dev --remote`)

**Objective:** Confirm the Images binding transforms an R2 object to WebP in the remote (high-fidelity) dev environment without deploying to production.

**Authorized action:**
- `npx wrangler dev --remote src/index.ts`
- Send test request: `curl http://localhost:8787/transform/spike/fixture-exif.jpg`
- Worker reads from R2, transforms, returns WebP bytes.

**Evidence to capture:**
- HTTP response status.
- Response `Content-Type` header (must be `image/webp`).
- Response body size in bytes.
- Worker console output (CPU time, memory).

**Pass:** HTTP 200, `Content-Type: image/webp`, response body > 0 bytes, no Worker exception.
**Fail:** Any non-200, wrong content type, Worker error/exception, timeout.

---

### CF-P-5 — Metadata Stripping Verification

**Objective:** Prove the output WebP contains no prohibited metadata.

**Method:** Save the response body from CF-P-4 to disk and run ExifTool.

```bash
curl http://localhost:8787/transform/spike/fixture-exif.jpg -o output.webp
exiftool output.webp
```

**Prohibited metadata families:**
| Family | Tags | Pass if |
|--------|------|---------|
| EXIF | Make, Model, GPS*, DateTimeOriginal, etc. | Zero EXIF tags present |
| XMP | All XMP namespaces | Zero XMP tags present |
| ICC_Profile | ProfileDescription, etc. | Zero ICC tags present |
| Comment | ImageDescription, UserComment | Zero comment tags present |

Structural WebP properties (File Size, Image Width, Image Height, Bit Depth, Color Type) are allowed — ExifTool always reports these and they are not metadata.

**Evidence to capture:**
- Full `exiftool output.webp` output.
- Explicit list of any prohibited tag families found.

**Pass:** Zero prohibited metadata families in output.
**Fail:** Any EXIF, XMP, ICC, or comment tag present in output.
**Inconclusive:** ExifTool unavailable or errors during inspection — install and re-run before advancing.

---

### CF-P-6 — Output Size and Format Verification

**Objective:** Confirm output is valid WebP and within the 5 MB ceiling.

**Checks:**
1. File magic bytes: `52 49 46 46 ... 57 45 42 50` (RIFF...WEBP header).
2. RIFF declared size: `declared_total = riff_size + 8`; file size must equal `declared_total` (or `declared_total + 1` for padding).
3. WebP chunk sequence: one of the five valid sequences (VP8, VP8L, VP8X+VP8, VP8X+ALPH+VP8, VP8X+VP8L).
4. VP8X flag validation (if VP8X present): `(flags_u32 & ~0x00000010) === 0` — only Alpha flag (`0x10`) permitted; Animation (`0x02`), XMP (`0x04`), EXIF (`0x08`), ICC (`0x20`) must all be zero.
5. Output size ≤ 5 MB.

**Evidence to capture:**
- Hex dump of bytes 0–15 (RIFF header + size + WEBP).
- Chunk sequence identified.
- VP8X flags value (if applicable).
- Output file size in bytes.

**Pass:** Valid RIFF/WEBP header, valid chunk sequence, VP8X flags clean, size ≤ 5 MB.
**Fail:** Invalid header, forbidden VP8X flags (animation, XMP, EXIF, ICC), size > 5 MB.

---

### CF-P-7 — SHA-256 Integrity

**Objective:** Confirm the Worker's computed SHA-256 matches an independent hash of the output bytes.

**Method:**
- Worker computes SHA-256 of the transformed output bytes and returns it in a response header: `X-Forkensics-SHA256`.
- Runner independently hashes the response body: `shasum -a 256 output.webp`.
- Compare.

**Evidence to capture:**
- `X-Forkensics-SHA256` header value.
- `shasum -a 256` output.

**Pass:** Both values match exactly.
**Fail:** Mismatch, header absent, or empty hash.

---

### CF-P-8 — Worker Memory Budget

**Objective:** Confirm the Worker stays well within the 128 MB JS memory limit with no WASM involved.

**Method:** Observe `wrangler dev --remote` console output for CPU time and memory metrics during CF-P-4 requests.

**Pass criteria:**
- Worker CPU time < 50 ms per request (transformation runs in Cloudflare's pipeline, not in Worker JS).
- No out-of-memory error.
- No 546 response (resource exhaustion).

**Evidence to capture:**
- Worker console CPU time and memory readings.
- Confirm no 546 or 503 from the runtime.

**Pass:** CPU time < 50 ms, no memory error, no 546.
**Fail:** CPU time ≥ 200 ms, memory error, or 546.
**Inconclusive:** CPU time 50–200 ms — note and continue.

---

### CF-P-9 — Hosted Worker Deploy

**Objective:** Deploy the spike Worker to Cloudflare and confirm end-to-end transformation in the hosted environment.

**Authorized action (requires §1.2 sign-off — already covers this):**
- `npx wrangler deploy`
- Worker URL: `https://forkensics-image-spike.<account>.workers.dev`

**Authorized test call (one request only):**
```bash
curl -H "Authorization: Bearer $SPIKE_SECRET" \
  https://forkensics-image-spike.<account>.workers.dev/transform/spike/fixture-exif.jpg \
  -o hosted-output.webp -D -
```

**Evidence to capture:**
- HTTP status.
- `Content-Type` header.
- Response size.
- `X-Forkensics-SHA256` header.
- Independent `shasum -a 256 hosted-output.webp`.

**Pass:** HTTP 200, `image/webp`, SHA-256 matches, size ≤ 5 MB.
**Fail:** Non-200, wrong content type, SHA mismatch, size > 5 MB, 546.

---

### CF-P-10 — Auth Boundary

**Objective:** Confirm the deployed Worker is not publicly accessible without authorization.

**Tests:**
| Request | Expected | Pass if |
|---------|----------|---------|
| No `Authorization` header | 401 | Status == 401 |
| Invalid token | 401 | Status == 401 |
| Valid `SPIKE_SECRET` | 200 | Status == 200 (from CF-P-9) |

**Note:** `SPIKE_SECRET` is a simple shared secret for the spike only. Production auth will use Supabase service-role JWT verification at the Worker boundary.

**Evidence to capture:**
- HTTP status for each unauthenticated request.

**Pass:** Unauthenticated requests return 401; authenticated request returns 200.
**Fail:** Unauthenticated request returns 200 (public access leak).

---

### CF-P-11 — Write-Back to R2

**Objective:** Confirm the Worker can write the sanitized output back to R2 under a separate display key.

**Authorized action:**
- Extend Worker to write output to `forkensics-dev-spike/display/{key}.webp` via `env.BUCKET.put()`.
- Verify the object exists: `wrangler r2 object list forkensics-dev-spike --prefix display/`.
- Download and re-verify SHA-256.

**Evidence to capture:**
- `wrangler r2 object list` output showing display key.
- SHA-256 of downloaded display object matches CF-P-7 hash.

**Pass:** Display key present, SHA-256 matches.
**Fail:** Key absent, size mismatch, or SHA mismatch.

---

### CF-P-12 — Cleanup

**Objective:** Remove all spike resources from Cloudflare. Leave no spike Worker deployed and no spike data in R2.

**Authorized actions (in order):**
1. `wrangler r2 object delete forkensics-dev-spike spike/fixture-exif.jpg`
2. `wrangler r2 object delete forkensics-dev-spike spike/fixture-icc.png`
3. `wrangler r2 object delete forkensics-dev-spike display/fixture-exif.jpg.webp`
4. `wrangler r2 object list forkensics-dev-spike` — assert zero objects.
5. `wrangler r2 bucket delete forkensics-dev-spike`
6. `wrangler delete forkensics-image-spike` — undeploy Worker.
7. Confirm Worker is gone: `wrangler list` — assert not present.

**Evidence to capture:**
- `wrangler r2 object list` output showing zero objects before bucket deletion.
- `wrangler list` output showing Worker absent.

**Pass:** Zero objects, bucket deleted, Worker absent from list.
**Fail:** Any object remaining, bucket deletion error, Worker still listed.

---

## §6 Authoritative Worker Code

```typescript
// src/index.ts — forkensics-image-spike
// SPIKE ONLY — not production code

interface Env {
  BUCKET: R2Bucket;
  IMAGES: any; // Cloudflare Images binding
  SPIKE_SECRET: string;
}

const MAX_OUTPUT_BYTES = 5 * 1024 * 1024; // 5 MB

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    // Auth boundary
    const auth = request.headers.get("Authorization") ?? "";
    if (auth !== `Bearer ${env.SPIKE_SECRET}`) {
      return new Response("Unauthorized", { status: 401 });
    }

    const url = new URL(request.url);
    // Route: /transform/{key}
    const key = url.pathname.replace(/^\/transform\//, "");
    if (!key) {
      return new Response("Missing key", { status: 400 });
    }

    // Read from R2
    const object = await env.BUCKET.get(key);
    if (!object) {
      return new Response("Not found", { status: 404 });
    }

    // Transform via Images binding
    let result: Response;
    try {
      result = (
        await env.IMAGES.input(object.body)
          .transform({ width: 1280, height: 1280, fit: "inside" })
          .output({ format: "image/webp", quality: 85 })
      ).response();
    } catch (err) {
      return new Response(`Transform error: ${err}`, { status: 500 });
    }

    // Buffer output and enforce ceiling
    const outputBytes = new Uint8Array(await result.arrayBuffer());
    if (outputBytes.byteLength > MAX_OUTPUT_BYTES) {
      return new Response(
        `Output too large: ${outputBytes.byteLength} bytes`,
        { status: 422 }
      );
    }

    // SHA-256
    const hashBuffer = await crypto.subtle.digest("SHA-256", outputBytes);
    const hashHex = Array.from(new Uint8Array(hashBuffer))
      .map((b) => b.toString(16).padStart(2, "0"))
      .join("");

    // Write display copy back to R2
    const displayKey = `display/${key}.webp`;
    await env.BUCKET.put(displayKey, outputBytes, {
      httpMetadata: { contentType: "image/webp" },
    });

    return new Response(outputBytes, {
      status: 200,
      headers: {
        "Content-Type": "image/webp",
        "X-Forkensics-SHA256": hashHex,
        "X-Forkensics-Display-Key": displayKey,
        "X-Forkensics-Size": String(outputBytes.byteLength),
      },
    });
  },
};
```

---

## §7 Verdict Criteria

| Tier | Condition | Meaning |
|------|-----------|---------|
| **PASS** | CF-P-1 through CF-P-12 all pass | Cloudflare R2 + Images binding is viable. Proceed to production architecture design. |
| **INCONCLUSIVE** | CF-P-8 CPU time 50–200 ms | Transformation is slower than expected but functional. Note for production SLA. |
| **FAIL** | Any probe returns FAIL | Architecture is not viable at that probe. Stop, document, evaluate Fallback Rank 2. |

---

## §8 Fallback Rank 2 (if this spike fails)

Sharp/libvips on dedicated background compute (Cloud Run / Fly.io / Lambda). Full control, no vendor transformation API, operationally heaviest. Requires a new spike proposal if this one fails.

---

## §9 Open Questions (must resolve before Phase 2)

| # | Question | Owner |
|---|----------|-------|
| OQ-1 | Does the production upload flow presign directly to R2, or does `upload-authorize` proxy the PUT? | Bill + architecture review |
| OQ-2 | Should the display WebP key be deterministic (hash of original) or random? | Bill |
| OQ-3 | Worker auth in production: Supabase JWT verification or Cloudflare service token? | Bill + Codex |

---

*Proposal Rev 1 — 2026-08-15 — awaiting §1.2 three-party sign-off*
