# CF-Worker-Prod — Production Image Transform Worker
## Proposal Rev 1 — 2026-08-16

**Status:** DRAFT — Awaiting three-party approval (Claude + Codex + Bill)

**Supersedes:** n/a — first revision

**Governance gate:** All three parties must approve Phase 1 before any artifact is edited or created locally.
All three parties must approve Phase 2 before any Cloudflare cloud operation is performed.

Magic words:
- Claude: `APPROVED: CF-Worker-Prod Rev 1 — Phase 1`  /  `APPROVED: CF-Worker-Prod Rev 1 — Phase 2`
- Codex:  `APPROVED: CF-Worker-Prod Rev 1 — Phase 1`  /  `APPROVED: CF-Worker-Prod Rev 1 — Phase 2`
- Bill:   `APPROVED: CF-Worker-Prod Rev 1 — Phase 1`  /  `APPROVED: CF-Worker-Prod Rev 1 — Phase 2`

---

## §1 Governance

### §1.1 Security Constraints (permanent — cannot be overridden)

- `CF_ACCESS_CLIENT_ID`, `CF_ACCESS_CLIENT_SECRET`, and any Cloudflare credential: never in client code, never in the repo, never sent to Claude.
- `ANON_KEY` and `SERVICE_ROLE_KEY`: runtime environment variables only; never written to any file, echoed, or logged.
- Three-party governance: **Bill + Claude + Codex** must approve each phase before its authorized operations begin.
- Authorized Cloudflare account ID: `1dd6ede816fa36a5a824a6e21f82ad7b`
- Authorized Supabase projects:
  - `hkfrbdpedrxmbsawnbpr` (forkensics-dev) — Phase 2 target
  - `torkgydbvktqebssfpdi` (forkensics-prod) — **not authorized in this proposal; requires a separate Phase 3 sign-off**
- All production R2 objects are named `originals/{media_id}` (UUID, no extension). The display key is derived as `display/{media_id}.webp`.

### §1.2 Two-Phase Authorization

#### Phase 1 — Proposal sign-off

Authorizes:
- Reviewing this document.
- Local creation of all locked artifacts listed in §2 (TypeScript source, wrangler.toml, tsconfig.json, package.json).
- `wrangler --help` verification for all commands used in §7.
- Read-only Cloudflare Dashboard inspection to confirm the Workers plan and account ID.

Prohibits:
- Any Cloudflare cloud operation (bucket create, object upload, Worker deploy, Access policy create, service token create).
- Any Supabase secrets operation.
- Any read or write against any R2 bucket.

| Party | Status | Note |
|-------|--------|------|
| Claude | ⬜ pending | Rev 1 authored |
| Codex | ⬜ pending | |
| Bill | ⬜ pending | |

#### Phase 2 — Execution authorization (forkensics-dev only)

Requires all of Phase 1 sign-off plus locked artifact SHA-256 confirmation (§2).

Authorizes:
- Creating R2 bucket `forkensics-dev-media` in the authorized Cloudflare account.
- Deploying `forkensics-image-transform-dev` Worker to the authorized Cloudflare account.
- Creating the Cloudflare Access application and service token for the dev Worker.
- Storing `CF_ACCESS_CLIENT_ID`, `CF_ACCESS_CLIENT_SECRET`, and `CF_WORKER_URL` in forkensics-dev Supabase secrets.
- Running acceptance probes in §8.

Prohibits:
- Any operation on forkensics-prod Supabase project.
- Creating a production R2 bucket or production Worker.
- Storing credentials in the repo or any file.

| Party | Status | Note |
|-------|--------|------|
| Claude | ⬜ pending | |
| Codex | ⬜ pending | |
| Bill | ⬜ pending | |

#### Phase 3 — Production deployment (future proposal)

Scope: deploy `forkensics-image-transform` Worker bound to `forkensics-prod-media` R2 bucket; configure production CF Access service token; store secrets in forkensics-prod Supabase project. Requires a separate three-party proposal and sign-off. Not authorized by this document.

---

## §2 Locked Artifacts

The following artifacts must exist locally with the SHA-256 values confirmed before Phase 2 begins. All artifacts live under `tools/image-transform/`.

| Artifact | SHA-256 | Review status |
|----------|---------|---------------|
| `src/index.ts` | ⬜ pending lock | ⬜ pending |
| `wrangler.toml` | ⬜ pending lock | ⬜ pending |
| `tsconfig.json` | ⬜ pending lock | ⬜ pending |
| `package.json` | ⬜ pending lock | ⬜ pending |

SHA-256 computation: `sha256sum <file>` (Linux) or `shasum -a 256 <file>` (macOS).

---

## §3 Scope

This proposal covers:
1. The production Cloudflare Worker (`forkensics-image-transform-dev` for dev, `forkensics-image-transform` for prod — the latter is Phase 3).
2. The R2 bucket (`forkensics-dev-media`) where originals are uploaded and display copies are written.
3. The Cloudflare Access service token that authenticates `upload-complete` → Worker calls.
4. Supabase secrets (`CF_ACCESS_CLIENT_ID`, `CF_ACCESS_CLIENT_SECRET`, `CF_WORKER_URL`) in forkensics-dev.
5. Acceptance probes confirming the pipeline is operational.

This proposal does **not** cover:
- Changes to `upload-authorize` (presign to R2 — separate Step A amendment).
- The `upload-complete` Edge Function (Step B — separate proposal).
- Production deployment (Phase 3 — separate proposal).

### Relationship to existing steps

- Gate 2B CF spike (Rev 10) validated the Cloudflare Worker + R2 + Images Binding architecture. This proposal promotes that architecture to production-grade code and infrastructure.
- The Worker TypeScript is derived from `tools/image-spike/src/index.ts` with four changes:
  1. Auth removed from Worker code (delegated to Cloudflare Access).
  2. Display key derivation changed from basename to `display/${key.split("/").pop()!}.webp` — unchanged in code, but the object key convention changes to `originals/{media_id}` ensuring the derived display key is always `display/{media_id}.webp`.
  3. Per-dimension gate added: `width > 8192` or `height > 8192` → 422.
  4. `SPIKE_SECRET` env var removed from `Env` interface.

---

## §4 Directory Structure

```
tools/image-transform/
├── src/
│   └── index.ts               # Worker entry point
├── package.json               # wrangler dev dependency
├── tsconfig.json              # TypeScript config
├── wrangler.toml              # Wrangler config — dev and prod environments
└── worker-configuration.d.ts  # auto-generated by `wrangler types`; not committed
```

`worker-configuration.d.ts` is generated from `wrangler.toml` and must be listed in `.gitignore`. The `Env` interface in `src/index.ts` relies on this generated file.

---

## §5 Worker Implementation — `src/index.ts`

```typescript
// src/index.ts — forkensics-image-transform Production Rev 1 — 2026-08-16
// Auth: Cloudflare Access service token (enforced at CF edge — not in Worker code)
// Key contract: R2 object at "originals/{media_id}" → display copy at "display/{media_id}.webp"

const FORMAT_ALIAS_MAP: Record<string, string> = {
  "jpg":        "image/jpeg",
  "jpeg":       "image/jpeg",
  "image/jpeg": "image/jpeg",
  "webp":       "image/webp",
  "image/webp": "image/webp",
};
const ACCEPTED_FORMATS  = new Set(["image/jpeg", "image/webp"]);
const MAX_INPUT_BYTES   = 10 * 1024 * 1024;  // 10 MB — OQ-1 gate
const MAX_OUTPUT_BYTES  =  5 * 1024 * 1024;  //  5 MB — output ceiling
const MAX_PIXELS        = 15_500_000;         // 15.5 MP area — OQ-4 gate (area)
const MAX_DIMENSION_PX  = 8_192;             // px per side — OQ-4 gate (per-side)

export default {
  async fetch(
    request: Request,
    env: Env,
    _ctx: ExecutionContext,
  ): Promise<Response> {
    const url = new URL(request.url);

    // Health check — excluded from CF Access policy (see §6.3)
    if (url.pathname === "/health") {
      return new Response("ok", { status: 200 });
    }

    // Key extraction: strip leading "/transform/" and validate
    const key = url.pathname.replace(/^\/transform\//, "").trim();
    if (!key || key.includes("..") || key.startsWith("/")) {
      return new Response("Invalid key", { status: 400 });
    }

    // ── Read 1: HEAD — byte-size gate, no body stream opened ─────────────────
    const head = await env.BUCKET.head(key);
    if (!head) return new Response("Not found", { status: 404 });
    const etag = head.etag;

    if (head.size > MAX_INPUT_BYTES) {
      return new Response(
        `Input too large: ${head.size} > ${MAX_INPUT_BYTES}`,
        { status: 422 },
      );
    }

    // ── Read 2: conditional GET → Images.info() ───────────────────────────────
    const infoObject = await env.BUCKET.get(key, {
      onlyIf: { etagMatches: etag },
    });
    if (!infoObject || !("body" in infoObject) || !infoObject.body) {
      return new Response("Input changed between reads", { status: 409 });
    }

    const info = await env.IMAGES.info(infoObject.body);

    // SVG branch has no width/height — narrow to non-SVG before accessing shape fields
    if (!("width" in info)) {
      return new Response(`Unsupported format: ${info.format}`, { status: 422 });
    }

    // Format gate
    const normalizedFormat =
      FORMAT_ALIAS_MAP[String(info.format).toLowerCase()] ?? null;
    if (!normalizedFormat || !ACCEPTED_FORMATS.has(normalizedFormat)) {
      return new Response(`Unsupported format: ${info.format}`, { status: 422 });
    }

    // Per-side dimension gate — OQ-4
    if (info.width > MAX_DIMENSION_PX || info.height > MAX_DIMENSION_PX) {
      return new Response(
        `Dimension ${info.width}×${info.height} exceeds ${MAX_DIMENSION_PX}px per-side limit`,
        { status: 422 },
      );
    }

    // Area gate — OQ-4
    if (info.width * info.height > MAX_PIXELS) {
      return new Response(
        `Pixel area ${info.width * info.height} > ${MAX_PIXELS}`,
        { status: 422 },
      );
    }

    // ETag consistency: fileSize must match head.size
    if (info.fileSize !== head.size) {
      return new Response(
        `File size mismatch: head=${head.size} info.fileSize=${info.fileSize}`,
        { status: 409 },
      );
    }

    // ── Read 3: conditional GET → transform ──────────────────────────────────
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

    if (!transformResponse.ok) {
      return new Response(
        `Transform non-OK: ${transformResponse.status}`,
        { status: 502 },
      );
    }

    const ct = (transformResponse.headers.get("Content-Type") ?? "")
      .split(";")[0]
      .trim();
    if (ct !== "image/webp") {
      return new Response(`Unexpected Content-Type: ${ct}`, { status: 502 });
    }
    if (!transformResponse.body) {
      return new Response("Empty transform body", { status: 502 });
    }

    // ── Bounded stream read ───────────────────────────────────────────────────
    const reader = transformResponse.body.getReader();
    const chunks: Uint8Array[] = [];
    let totalBytes = 0;
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      totalBytes += value.byteLength;
      if (totalBytes > MAX_OUTPUT_BYTES) {
        await reader.cancel();
        return new Response("Output exceeds ceiling", { status: 422 });
      }
      chunks.push(value);
    }
    if (totalBytes === 0) return new Response("Empty output", { status: 502 });

    const out = new Uint8Array(totalBytes);
    let off = 0;
    for (const c of chunks) {
      out.set(c, off);
      off += c.byteLength;
    }

    // SHA-256 of output bytes
    const hashHex = Array.from(
      new Uint8Array(await crypto.subtle.digest("SHA-256", out)),
    )
      .map((b) => b.toString(16).padStart(2, "0"))
      .join("");

    // Display key: "display/{media_id}.webp"
    // Key convention: R2 object is at "originals/{media_id}" (UUID, no extension).
    // split("/").pop() extracts the UUID; appending ".webp" gives the display key.
    const displayKey = `display/${key.split("/").pop()!}.webp`;

    await env.BUCKET.put(displayKey, out, {
      httpMetadata: { contentType: "image/webp" },
    });

    return new Response(out, {
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

### §5.1 Changes from spike `src/index.ts`

| Change | Spike | Production |
|--------|-------|------------|
| Auth | `Authorization: Bearer SPIKE_SECRET` checked in Worker | Delegated to CF Access; Worker has no auth code |
| `Env` | `BUCKET`, `IMAGES`, `SPIKE_SECRET` | `BUCKET`, `IMAGES` only |
| Per-side dimension gate | Absent | `width > 8192` or `height > 8192` → 422 |
| Display key derivation | `display/${basename}.webp` — basename from R2 key | Same code; key convention changes to `originals/{media_id}` (UUID) so display key = `display/{media_id}.webp` |
| Health endpoint | Present, no auth | Present, excluded from CF Access policy |

---

## §6 Cloudflare Configuration

### §6.1 R2 Bucket

| Environment | Bucket name |
|-------------|-------------|
| dev | `forkensics-dev-media` |
| prod (Phase 3) | `forkensics-prod-media` |

Creation:
```
wrangler r2 bucket create forkensics-dev-media
```

Public access: **disabled** (default). No `r2_public_buckets` binding. All object access via authenticated Worker only.

### §6.2 Worker name and hostname

| Environment | Worker name | Default hostname |
|-------------|-------------|-----------------|
| dev | `forkensics-image-transform-dev` | `forkensics-image-transform-dev.<subdomain>.workers.dev` |
| prod (Phase 3) | `forkensics-image-transform` | `forkensics-image-transform.<subdomain>.workers.dev` |

### §6.3 Cloudflare Access — Service Auth Policy

Goal: only `upload-complete` (holding the service token) can call `/transform/*`. `/health` is publicly accessible.

Setup steps (performed in Cloudflare Zero Trust dashboard after Worker is deployed):

**Step 1 — Create Access application**
- Type: **Self-hosted**
- Name: `forkensics-image-transform-dev`
- Session duration: No session (service-to-service)
- Application domain: `forkensics-image-transform-dev.<subdomain>.workers.dev`
- Path exclusion: `/health` (add as a "bypass" rule so health checks skip auth)

**Step 2 — Create Access policy**
- Policy name: `upload-complete service token`
- Action: Allow
- Include rule: `Service Token` → select the service token created in Step 3

**Step 3 — Create service token**
- Navigate: Zero Trust → Access → Service Auth → Service Tokens → Create Service Token
- Name: `forkensics-upload-complete-dev`
- Duration: Non-expiring (rotate manually before deletion)
- Save: Cloudflare displays `Client ID` and `Client Secret` once — capture both immediately

**Step 4 — Record credentials**
Bill stores `CF_ACCESS_CLIENT_ID` and `CF_ACCESS_CLIENT_SECRET` in a secure location (1Password or equivalent). Never sent to Claude.

### §6.4 How CF Access service token auth works

`upload-complete` sends two headers:
```
CF-Access-Client-Id:     <CF_ACCESS_CLIENT_ID>
CF-Access-Client-Secret: <CF_ACCESS_CLIENT_SECRET>
```

Cloudflare Access validates these headers at the edge. If valid, the request is forwarded to the Worker. If invalid, CF Access returns 403 before the Worker runs. The Worker code itself performs no auth check.

The `cf-access-jwt-assertion` header forwarded by CF Access to the Worker is ignored by the Worker (not read or validated).

---

## §7 Wrangler Configuration — `wrangler.toml`

```toml
# tools/image-transform/wrangler.toml
name = "forkensics-image-transform-dev"
main = "src/index.ts"
compatibility_date = "2025-08-15"

[[r2_buckets]]
binding = "BUCKET"
bucket_name = "forkensics-dev-media"

[images]
binding = "IMAGES"

# ── Production environment (Phase 3 — not authorized by this proposal) ────────
[env.production]
name = "forkensics-image-transform"

[[env.production.r2_buckets]]
binding = "BUCKET"
bucket_name = "forkensics-prod-media"

# Images binding inherits to env.production — no override needed.
```

Notes:
- `compatibility_date` matches the spike to preserve runtime behavior. Bump only after testing on the new date.
- The `[env.production]` block is present in the file for completeness but **no production deployment is authorized until Phase 3 sign-off**.
- `worker-configuration.d.ts` is generated by `wrangler types` and must not be committed.

---

## §8 Package Files

### `package.json`

```json
{
  "name": "forkensics-image-transform",
  "version": "1.0.0",
  "private": true,
  "scripts": {
    "deploy:dev": "wrangler deploy",
    "deploy:prod": "wrangler deploy --env production",
    "types": "wrangler types"
  },
  "devDependencies": {
    "wrangler": "^4.0.0"
  }
}
```

### `tsconfig.json`

```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "ES2022",
    "moduleResolution": "Bundler",
    "lib": ["ES2022"],
    "types": ["@cloudflare/workers-types"],
    "strict": true,
    "noUnusedLocals": true,
    "noUnusedParameters": true,
    "noFallthroughCasesInSwitch": true
  },
  "include": ["src/**/*.ts", "worker-configuration.d.ts"]
}
```

---

## §9 Supabase Secrets

After Phase 2 cloud operations, Bill sets the following secrets in forkensics-dev via the Supabase dashboard or CLI (not sent to Claude):

| Secret name | Value |
|-------------|-------|
| `CF_ACCESS_CLIENT_ID` | Client ID from §6.3 Step 3 |
| `CF_ACCESS_CLIENT_SECRET` | Client Secret from §6.3 Step 3 |
| `CF_WORKER_URL` | `https://forkensics-image-transform-dev.<subdomain>.workers.dev` |

These are consumed by `upload-complete` (Step B). They are never written to any file, logged, or sent to Claude.

---

## §10 Deploy Sequence (Phase 2)

Operations are performed by Bill in this order. Each step is a cloud operation and requires Phase 2 sign-off to have occurred.

| Step | Operation | Tool |
|------|-----------|------|
| D-1 | Create R2 bucket `forkensics-dev-media` | `wrangler r2 bucket create forkensics-dev-media` |
| D-2 | Generate `worker-configuration.d.ts` | `wrangler types` (local only) |
| D-3 | Deploy Worker | `wrangler deploy` (from `tools/image-transform/`) |
| D-4 | Create CF Access application | Cloudflare Zero Trust dashboard — §6.3 Step 1 |
| D-5 | Create CF Access policy | Cloudflare Zero Trust dashboard — §6.3 Step 2 |
| D-6 | Create service token | Cloudflare Zero Trust dashboard — §6.3 Step 3 |
| D-7 | Store Supabase secrets | Supabase dashboard or CLI — §9 |
| D-8 | Run acceptance probes | §11 |

D-4 through D-6 must be completed before D-8. D-7 is needed for `upload-complete` integration (Step B) but not for Worker-level probe acceptance.

---

## §11 Acceptance Probes

Probes are curl commands executed from the local machine after D-3 through D-6 complete. `$WORKER_URL`, `$CF_CLIENT_ID`, and `$CF_CLIENT_SECRET` are shell variables set by Bill from values stored in 1Password — never typed to Claude.

### Probe table

| Probe | Description | Expected |
|-------|-------------|----------|
| CF-W-1 | Health check — no auth | HTTP 200, body `ok` |
| CF-W-2 | Missing service token → rejected | HTTP 401 or 403 from CF Access |
| CF-W-3 | Invalid key (path traversal) | HTTP 400 |
| CF-W-4 | Missing object key | HTTP 404 |
| CF-W-5 | Upload valid JPEG fixture, call `/transform/originals/{media_id}`, check 200 | HTTP 200, `Content-Type: image/webp`, `X-Forkensics-SHA256` present |
| CF-W-6 | Confirm `display/{media_id}.webp` object exists in bucket | `wrangler r2 object get --pipe --remote` exit 0 |
| CF-W-7 | Upload oversized JPEG (> 10 MB) | HTTP 422, body contains `Input too large` |
| CF-W-8 | Upload image with dimension > 8192 px on one side | HTTP 422, body contains `Dimension` |
| CF-W-9 | Upload image with area > 15.5 MP but sides ≤ 8192 | HTTP 422, body contains `Pixel area` |
| CF-W-10 | Confirm output is valid WebP and metadata-stripped | `exiftool` on response body: no EXIF/GPS/XMP |
| CF-W-11 | Cleanup: delete fixture originals and display copies | `wrangler r2 object delete` for each key |

### CF-W-1 (health — no auth)

```bash
curl -s -w "\nHTTP %{http_code}" "$WORKER_URL/health"
# Expected: ok\nHTTP 200
```

### CF-W-2 (no token → CF Access rejects)

```bash
curl -s -w "\nHTTP %{http_code}" "$WORKER_URL/transform/originals/test-uuid"
# Expected: HTTP 401 or HTTP 403 (from CF Access before Worker runs)
```

### CF-W-3 (invalid key)

```bash
curl -s -w "\nHTTP %{http_code}" \
  -H "CF-Access-Client-Id: $CF_CLIENT_ID" \
  -H "CF-Access-Client-Secret: $CF_CLIENT_SECRET" \
  "$WORKER_URL/transform/../etc/passwd"
# Expected: HTTP 400
```

### CF-W-4 (missing key)

```bash
curl -s -w "\nHTTP %{http_code}" \
  -H "CF-Access-Client-Id: $CF_CLIENT_ID" \
  -H "CF-Access-Client-Secret: $CF_CLIENT_SECRET" \
  "$WORKER_URL/transform/originals/does-not-exist"
# Expected: HTTP 404
```

### CF-W-5 (valid JPEG → 200 WebP)

```bash
# Upload fixture to R2
MEDIA_ID="$(uuidgen | tr '[:upper:]' '[:lower:]')"
wrangler r2 object put "forkensics-dev-media/originals/$MEDIA_ID" \
  --file tools/image-spike/fixtures/fixture-exif.jpg --remote

# Call transform
curl -s -o cf_w5_output.webp -D cf_w5_headers.txt \
  -H "CF-Access-Client-Id: $CF_CLIENT_ID" \
  -H "CF-Access-Client-Secret: $CF_CLIENT_SECRET" \
  "$WORKER_URL/transform/originals/$MEDIA_ID"

grep "HTTP" cf_w5_headers.txt          # expect HTTP/... 200
grep "X-Forkensics-SHA256" cf_w5_headers.txt   # expect non-empty value
grep "X-Forkensics-Display-Key" cf_w5_headers.txt  # expect display/{MEDIA_ID}.webp
file cf_w5_output.webp                 # expect "WebP image data"
```

### CF-W-6 (display key exists in bucket)

```bash
wrangler r2 object get "forkensics-dev-media/display/$MEDIA_ID.webp" \
  --pipe --remote > /dev/null
echo "Exit: $?"  # expect 0
```

### CF-W-7 (oversized byte gate)

Create a 10 MB + 1 byte file locally, then:
```bash
dd if=/dev/urandom bs=10485761 count=1 of=/tmp/oversized.bin
wrangler r2 object put "forkensics-dev-media/originals/oversized-test" \
  --file /tmp/oversized.bin --remote
curl -s -w "\nHTTP %{http_code}" \
  -H "CF-Access-Client-Id: $CF_CLIENT_ID" \
  -H "CF-Access-Client-Secret: $CF_CLIENT_SECRET" \
  "$WORKER_URL/transform/originals/oversized-test"
# Expected: HTTP 422, body contains "Input too large"
```

### CF-W-8 (per-side dimension gate)

Use fixture `fixture-oversized-px.jpg` from the spike fixtures (or a synthetic image with one side > 8192 px).
```bash
wrangler r2 object put "forkensics-dev-media/originals/oversized-dim-test" \
  --file tools/image-spike/fixtures/fixture-oversized-px.jpg --remote
curl -s -w "\nHTTP %{http_code}" \
  -H "CF-Access-Client-Id: $CF_CLIENT_ID" \
  -H "CF-Access-Client-Secret: $CF_CLIENT_SECRET" \
  "$WORKER_URL/transform/originals/oversized-dim-test"
# Expected: HTTP 422, body contains "Dimension" or "exceeds"
```

**Note:** The spike's `fixture-oversized-px.jpg` was designed to trigger the area gate (15.5 MP), not necessarily the per-side gate (8192 px). If its dimensions are ≤ 8192 px on each side but area > 15.5 MP, CF-W-8 should use a different fixture with a side > 8192 px, and CF-W-9 should use `fixture-oversized-px.jpg` instead. Fixture requirements:
- CF-W-8: requires image where `max(width, height) > 8192`
- CF-W-9: requires image where `width × height > 15,500,000` AND `width ≤ 8192` AND `height ≤ 8192` (e.g., ~3936 × 3940 at 100% quality)

If no existing spike fixture satisfies CF-W-8 exactly, create one: a 8193 × 100 JPEG (well under area limit, one side just over 8192).

### CF-W-9 (area gate — sides within limit)

```bash
curl -s -w "\nHTTP %{http_code}" \
  -H "CF-Access-Client-Id: $CF_CLIENT_ID" \
  -H "CF-Access-Client-Secret: $CF_CLIENT_SECRET" \
  "$WORKER_URL/transform/originals/oversized-area-test"
# Expected: HTTP 422, body contains "Pixel area"
```

### CF-W-10 (metadata stripped from output)

```bash
exiftool cf_w5_output.webp | grep -Ei "(gps|exif|xmp|icc|iptc|make|model|serial)"
# Expected: no output (all metadata families absent)
```

### CF-W-11 (cleanup)

```bash
for KEY in \
  "originals/$MEDIA_ID" \
  "display/$MEDIA_ID.webp" \
  "originals/oversized-test" \
  "originals/oversized-dim-test" \
  "originals/oversized-area-test"; do
  wrangler r2 object delete "forkensics-dev-media/$KEY" --remote || true
  echo "[CLEANUP] $KEY"
done
```

### Pass criteria

All of CF-W-1 through CF-W-11 must return their expected result. CF-W-8 requires either the correct existing fixture or a freshly created 8193 × 100 JPEG. INCONCLUSIVE is not a valid outcome for any probe.

---

## §12 Rollback Plan

If any probe in §11 fails and the issue cannot be resolved in the same session:

1. Delete the Worker: `wrangler delete forkensics-image-transform-dev --force`
2. Revoke the service token in Cloudflare Zero Trust dashboard.
3. Delete the CF Access application in Cloudflare Zero Trust dashboard.
4. Delete the R2 bucket contents: `wrangler r2 bucket delete forkensics-dev-media` (after objects deleted).
5. Clear Supabase secrets `CF_ACCESS_CLIENT_ID`, `CF_ACCESS_CLIENT_SECRET`, `CF_WORKER_URL` from forkensics-dev if they were set.
6. The `tools/image-transform/` source files remain locally — no source deletion.

Rollback leaves forkensics-dev Supabase project and all its data intact. No production resources are affected (none were created).

---

## §13 Open Items Before Phase 2

The following items must be resolved or accepted before Phase 2 sign-off:

| # | Item | Owner |
|---|------|-------|
| OI-1 | Codex confirms CF-W-8 fixture requirements — does `fixture-oversized-px.jpg` satisfy max(side) > 8192? If not, specify a synthetic fixture. | Codex |
| OI-2 | Codex confirms `[images]` binding syntax in `wrangler.toml` for Wrangler 4.x. (Spike used this syntax successfully; confirming it is unchanged for production.) | Codex |
| OI-3 | Bill confirms worker `compatibility_date = "2025-08-15"` is acceptable for production, or requests a bump. | Bill |
| OI-4 | Codex reviews `src/index.ts` gate ordering — specifically, confirm that running `IMAGES.info()` after the byte-size gate but before the format/dimension gates is correct (i.e., `info()` does not perform a full decode). | Codex |

---

## §14 What This Proposal Does Not Change

- `upload-authorize` presign target remains Supabase Storage until a separate Step A amendment is written and approved.
- The `upload-complete` Edge Function is not written or deployed by this proposal.
- No existing Supabase migration is modified.
- No existing Edge Function is modified.
- The spike artifacts in `tools/image-spike/` are not modified.

---

## §15 Post-Approval Sequence Summary

```
Phase 1 sign-off (all three parties)
  └─▶ Create tools/image-transform/ artifacts locally
  └─▶ Compute and confirm SHA-256 of all four artifacts
  └─▶ Resolve OI-1 through OI-4

Phase 2 sign-off (all three parties, with SHA-256 confirmed)
  └─▶ D-1: Create forkensics-dev-media R2 bucket
  └─▶ D-2: wrangler types (local)
  └─▶ D-3: wrangler deploy
  └─▶ D-4 through D-6: CF Access setup + service token
  └─▶ D-7: Supabase secrets
  └─▶ D-8: Run probes CF-W-1 through CF-W-11 — all must PASS

Phase 2 PASS
  └─▶ Step B (upload-complete) proposal authorized to begin
  └─▶ Step A amendment (presign to R2) authorized to begin

Phase 3 (separate proposal — production deployment)
```
