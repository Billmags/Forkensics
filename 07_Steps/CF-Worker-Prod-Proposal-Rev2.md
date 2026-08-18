# CF-Worker-Prod — Production Image Transform Worker
## Proposal Rev 2 — 2026-08-16

**Status:** DRAFT — Awaiting three-party approval (Claude + Codex + Bill)

**Supersedes:** Rev 1 (CHANGES REQUIRED — 10 Codex corrections)

**Governance gate:** All three parties must approve Phase 1 before any artifact is created or edited locally.
All three parties must approve Phase 2 before any cloud operation is performed.

Magic words:
- Claude: `APPROVED: CF-Worker-Prod Rev 2 — Phase 1`  /  `APPROVED: CF-Worker-Prod Rev 2 — Phase 2`
- Codex:  `APPROVED: CF-Worker-Prod Rev 2 — Phase 1`  /  `APPROVED: CF-Worker-Prod Rev 2 — Phase 2`
- Bill:   `APPROVED: CF-Worker-Prod Rev 2 — Phase 1`  /  `APPROVED: CF-Worker-Prod Rev 2 — Phase 2`

---

## §0 Rev 2 Changes (relative to Rev 1)

| # | Correction |
|---|-----------|
| C-1 | CF Access policy action changed to "Service Auth"; workers.dev route enforcement explicitly required |
| C-2 | `/health` protected by CF Access; no public bypass unless a concrete monitoring requirement is documented (none identified) |
| C-3 | Service token changed to expiring (1 year); rotation procedure, renewal alert, and Supabase secret-update sequence specified |
| C-4 | `[env.production.images]` binding added explicitly; Rev 1 claim that Images inherits automatically removed |
| C-5 | `typescript` added to `devDependencies`; `typecheck` script added; `tsconfig.json` `types` changed to `["./worker-configuration.d.ts"]` |
| C-6 | `package-lock.json` added to locked artifacts and SHA-256 table |
| C-7 | Phase 1 authorizations expanded: local dependency install, `wrangler types`, typecheck, fixture generation, `wrangler deploy --dry-run`, `.gitignore` edit |
| C-8 | Transform endpoint changed to POST-only; 405 for other methods; key validated against `originals/{canonical-UUID}` pattern; traversal probe updated to use `curl --path-as-is` |
| C-9 | Fixture paths corrected to `tools/image-spike/cf-spike/fixtures/`; 8193×100 JPEG fixture specified for CF-W-8 |
| C-10 | Worker response changed from full WebP body to JSON metadata: `{"displayKey","sha256","bytes"}`; rationale documented |

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
- R2 object key convention: `originals/{media_id}` (canonical lowercase UUID v4, no extension). Display key derived as `display/{media_id}.webp`.

### §1.2 Two-Phase Authorization

#### Phase 1 — Proposal sign-off

Authorizes (local operations only — no cloud operations):
- Reviewing this document.
- Creating `tools/image-transform/` directory and all files listed in §2 (source, config, package files).
- Adding `worker-configuration.d.ts` to `.gitignore`.
- Running `npm install` to install `devDependencies` locally (writes `node_modules/` and `package-lock.json`).
- Running `wrangler types` to generate `worker-configuration.d.ts` locally (reads `wrangler.toml`, writes generated file).
- Running `tsc --noEmit` (typecheck only — no deploy).
- Creating the `tools/image-transform/fixtures/` directory and generating the 8193×100 JPEG fixture for CF-W-8 (§11.8).
- Running `wrangler deploy --dry-run` if the flag is supported by the installed Wrangler version; skip without error if unsupported.
- Read-only Cloudflare Dashboard inspection to confirm Workers plan and account ID.

Prohibits:
- Any Cloudflare cloud operation (bucket create, object upload, Worker deploy, Access policy create, service token create, any API mutation).
- Any Supabase operation.
- Any read or write against any R2 bucket.
- Running `wrangler deploy` without `--dry-run`.

| Party | Status | Note |
|-------|--------|------|
| Claude | ⬜ pending | Rev 2 authored |
| Codex | ⬜ pending | |
| Bill | ⬜ pending | |

#### Phase 2 — Execution authorization (forkensics-dev only)

Requires all Phase 1 sign-off plus locked artifact SHA-256 confirmation (§2).

Authorizes:
- Creating R2 bucket `forkensics-dev-media`.
- Deploying `forkensics-image-transform-dev` Worker.
- Creating the Cloudflare Access application, Service Auth policy, and service token for the dev Worker.
- Enabling CF Access enforcement on the `workers.dev` route.
- Storing `CF_ACCESS_CLIENT_ID`, `CF_ACCESS_CLIENT_SECRET`, and `CF_WORKER_URL` in forkensics-dev Supabase secrets.
- Running acceptance probes §11.

Prohibits:
- Any operation on forkensics-prod Supabase project.
- Creating a production R2 bucket or production Worker.
- Storing credentials in the repo, any committed file, or any file sent to Claude.

| Party | Status | Note |
|-------|--------|------|
| Claude | ⬜ pending | |
| Codex | ⬜ pending | |
| Bill | ⬜ pending | |

#### Phase 3 — Production deployment (separate proposal)

Scope: deploy `forkensics-image-transform` Worker bound to `forkensics-prod-media` R2 bucket; configure production CF Access service token; store secrets in forkensics-prod Supabase project. Requires a separate three-party proposal and sign-off. Not authorized by this document.

---

## §2 Locked Artifacts

All artifacts reside under `tools/image-transform/`. SHA-256 values are populated after Phase 1 artifact creation and confirmed by all three parties before Phase 2 sign-off.

| Artifact | SHA-256 | Review status |
|----------|---------|---------------|
| `src/index.ts` | ⬜ pending lock | ⬜ pending |
| `wrangler.toml` | ⬜ pending lock | ⬜ pending |
| `tsconfig.json` | ⬜ pending lock | ⬜ pending |
| `package.json` | ⬜ pending lock | ⬜ pending |
| `package-lock.json` | ⬜ pending lock (generated by `npm install`) | ⬜ pending |

SHA-256 computation: `shasum -a 256 <file>` (macOS) or `sha256sum <file>` (Linux).

`worker-configuration.d.ts` is excluded: it is generated by `wrangler types` from the locked `wrangler.toml` and changes whenever bindings change. It must be listed in `.gitignore` and is not committed.

The 8193×100 JPEG fixture (`tools/image-transform/fixtures/fixture-8193x100.jpg`) does not require a SHA-256 entry — it is a test input, not a source artifact. Its dimensions are verified during probe CF-W-8.

---

## §3 Scope

This proposal covers:
1. The production Cloudflare Worker (`forkensics-image-transform-dev` for dev; `forkensics-image-transform` for prod in Phase 3).
2. The R2 bucket (`forkensics-dev-media`) where originals are stored and display copies are written.
3. The Cloudflare Access application, Service Auth policy, and service token authenticating `upload-complete` → Worker calls.
4. Supabase secrets (`CF_ACCESS_CLIENT_ID`, `CF_ACCESS_CLIENT_SECRET`, `CF_WORKER_URL`) in forkensics-dev.
5. Acceptance probes confirming the full pipeline is operational.

This proposal does **not** cover:
- Changes to `upload-authorize` to presign to R2 (separate Step A amendment).
- The `upload-complete` Edge Function (Step B — separate proposal).
- Production deployment (Phase 3 — separate proposal).

### Relationship to existing artifacts

The Worker TypeScript is derived from `tools/image-spike/cf-spike/src/index.ts` with five changes:

| Change | Spike | Rev 2 |
|--------|-------|-------|
| Auth | `Authorization: Bearer SPIKE_SECRET` checked in Worker | Delegated to CF Access; Worker has no auth check |
| HTTP method | All methods accepted | POST only; 405 for other methods |
| Key validation | Loose: strip `/transform/` prefix, check `..` and leading `/` | Strict: must match `originals/{canonical-UUID}` pattern |
| Per-side dimension gate | Absent | `width > 8192` or `height > 8192` → 422 |
| Response body | Full WebP bytes | JSON metadata: `{"displayKey","sha256","bytes"}` |

The display key derivation code is unchanged (`display/${key.split("/").pop()!}.webp`), but the key convention changes to `originals/{media_id}` (canonical UUID, no extension) so the derived display key is always `display/{media_id}.webp` — no double extension.

---

## §4 Directory Structure

```
tools/image-transform/
├── src/
│   └── index.ts                  # Worker entry point
├── fixtures/
│   └── fixture-8193x100.jpg      # CF-W-8 per-side gate probe fixture (generated in Phase 1)
├── package.json
├── package-lock.json             # generated by npm install — committed; included in locked artifacts
├── tsconfig.json
├── wrangler.toml
└── worker-configuration.d.ts     # generated by wrangler types — NOT committed; in .gitignore
```

`.gitignore` addition (to the root `.gitignore` or a `tools/image-transform/.gitignore`):
```
worker-configuration.d.ts
node_modules/
```

---

## §5 Worker Implementation — `src/index.ts`

```typescript
// src/index.ts — forkensics-image-transform Production Rev 2 — 2026-08-16
// Auth: Cloudflare Access service token enforced at CF edge — no auth code in Worker
// Key convention: R2 original at "originals/{media_id}" → display at "display/{media_id}.webp"
// Response: JSON metadata; image bytes not returned to caller

const FORMAT_ALIAS_MAP: Record<string, string> = {
  "jpg":        "image/jpeg",
  "jpeg":       "image/jpeg",
  "image/jpeg": "image/jpeg",
  "webp":       "image/webp",
  "image/webp": "image/webp",
};
const ACCEPTED_FORMATS  = new Set(["image/jpeg", "image/webp"]);
const MAX_INPUT_BYTES   = 10 * 1024 * 1024;  // 10 MB
const MAX_OUTPUT_BYTES  =  5 * 1024 * 1024;  //  5 MB output ceiling
const MAX_PIXELS        = 15_500_000;         // 15.5 MP area gate
const MAX_DIMENSION_PX  = 8_192;              // px per side gate

// Canonical UUID v4 pattern (lowercase)
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;

function jsonError(status: number, message: string): Response {
  return new Response(JSON.stringify({ error: message }), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

export default {
  async fetch(
    request: Request,
    env: Env,
    _ctx: ExecutionContext,
  ): Promise<Response> {
    const url = new URL(request.url);

    // Health check — protected by CF Access (same as all other paths)
    if (url.pathname === "/health") {
      return new Response(JSON.stringify({ status: "ok" }), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      });
    }

    // Only POST is accepted for the transform endpoint
    if (request.method !== "POST") {
      return new Response(null, {
        status: 405,
        headers: { Allow: "POST" },
      });
    }

    // Key extraction and strict validation
    // Path must be: /transform/originals/{canonical-UUID}
    const pathMatch = url.pathname.match(/^\/transform\/(originals\/[^/]+)$/);
    if (!pathMatch) {
      return jsonError(400, "Path must be /transform/originals/{uuid}");
    }
    const key = pathMatch[1]; // "originals/{uuid}"
    const mediaId = key.split("/")[1];
    if (!UUID_RE.test(mediaId)) {
      return jsonError(400, "Key must be a canonical lowercase UUID v4");
    }

    // ── Read 1: HEAD — byte-size gate, no body stream opened ─────────────────
    const head = await env.BUCKET.head(key);
    if (!head) return jsonError(404, "Not found");
    const etag = head.etag;

    if (head.size > MAX_INPUT_BYTES) {
      return jsonError(422, `Input too large: ${head.size} > ${MAX_INPUT_BYTES}`);
    }

    // ── Read 2: conditional GET → IMAGES.info() ───────────────────────────────
    // IMAGES.info() is documented as free (not metered against transform quota).
    // Decode behavior is not specified by Cloudflare; no claim is made here.
    const infoObject = await env.BUCKET.get(key, {
      onlyIf: { etagMatches: etag },
    });
    if (!infoObject || !("body" in infoObject) || !infoObject.body) {
      return jsonError(409, "Input changed between reads");
    }

    const info = await env.IMAGES.info(infoObject.body);

    // SVG branch of the discriminated union has no width/height — narrow before use
    if (!("width" in info)) {
      return jsonError(422, `Unsupported format: ${info.format}`);
    }

    // Format gate
    const normalizedFormat =
      FORMAT_ALIAS_MAP[String(info.format).toLowerCase()] ?? null;
    if (!normalizedFormat || !ACCEPTED_FORMATS.has(normalizedFormat)) {
      return jsonError(422, `Unsupported format: ${info.format}`);
    }

    // Per-side dimension gate (OQ-4)
    if (info.width > MAX_DIMENSION_PX || info.height > MAX_DIMENSION_PX) {
      return jsonError(
        422,
        `Dimension ${info.width}×${info.height} exceeds ${MAX_DIMENSION_PX}px per-side limit`,
      );
    }

    // Area gate (OQ-4)
    if (info.width * info.height > MAX_PIXELS) {
      return jsonError(
        422,
        `Pixel area ${info.width * info.height} > ${MAX_PIXELS}`,
      );
    }

    // ETag consistency
    if (info.fileSize !== head.size) {
      return jsonError(
        409,
        `File size mismatch: head=${head.size} info.fileSize=${info.fileSize}`,
      );
    }

    // ── Read 3: conditional GET → transform ──────────────────────────────────
    const transformObject = await env.BUCKET.get(key, {
      onlyIf: { etagMatches: etag },
    });
    if (!transformObject || !("body" in transformObject) || !transformObject.body) {
      return jsonError(409, "Input changed between reads");
    }

    let transformResponse: Response;
    try {
      transformResponse = (
        await env.IMAGES.input(transformObject.body)
          .transform({ width: 1280, height: 1280, fit: "scale-down" })
          .output({ format: "image/webp", quality: 85, anim: false })
      ).response();
    } catch (err) {
      return jsonError(500, `Transform error: ${err}`);
    }

    if (!transformResponse.ok) {
      return jsonError(502, `Transform non-OK: ${transformResponse.status}`);
    }

    const ct = (transformResponse.headers.get("Content-Type") ?? "")
      .split(";")[0]
      .trim();
    if (ct !== "image/webp") {
      return jsonError(502, `Unexpected Content-Type: ${ct}`);
    }
    if (!transformResponse.body) {
      return jsonError(502, "Empty transform body");
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
        return jsonError(422, "Output exceeds ceiling");
      }
      chunks.push(value);
    }
    if (totalBytes === 0) return jsonError(502, "Empty output");

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
    // media_id is the UUID extracted from "originals/{media_id}"; no extension conflict.
    const displayKey = `display/${mediaId}.webp`;

    await env.BUCKET.put(displayKey, out, {
      httpMetadata: { contentType: "image/webp" },
    });

    // Return JSON metadata only — image bytes are not returned to the caller.
    // Rationale (C-10): upload-complete needs only the display key, hash, and size to
    // finalize the upload session. Returning the full WebP body adds unnecessary
    // server-to-server transfer with no downstream consumer.
    return new Response(
      JSON.stringify({ displayKey, sha256: hashHex, bytes: totalBytes }),
      {
        status: 200,
        headers: { "Content-Type": "application/json" },
      },
    );
  },
} satisfies ExportedHandler<Env>;
```

---

## §6 Wrangler Configuration — `wrangler.toml`

```toml
# tools/image-transform/wrangler.toml
name            = "forkensics-image-transform-dev"
main            = "src/index.ts"
compatibility_date = "2026-08-15"

[images]
binding = "IMAGES"

[[r2_buckets]]
binding     = "BUCKET"
bucket_name = "forkensics-dev-media"

# ── Production environment (Phase 3 — not authorized by this proposal) ────────
[env.production]
name = "forkensics-image-transform"

[env.production.images]
binding = "IMAGES"

[[env.production.r2_buckets]]
binding     = "BUCKET"
bucket_name = "forkensics-prod-media"
```

Notes:
- `compatibility_date = "2026-08-15"` matches the tested spike date. Any future bump requires retesting on the new date before deploy.
- No `[secrets]` block: CF Access handles auth; the Worker requires no secrets.
- `preview_bucket_name` is omitted: `wrangler dev --local` is not used for local testing of this Worker.
- `[env.production.images]` is required explicitly: Wrangler environment bindings are non-inheritable (C-4).
- `[env.production]` block is present for Phase 3 readiness but **no production deploy is authorized until Phase 3 sign-off**.

---

## §7 Package Files

### `package.json`

```json
{
  "name": "forkensics-image-transform",
  "version": "1.0.0",
  "private": true,
  "scripts": {
    "types": "wrangler types",
    "typecheck": "wrangler types && tsc --noEmit",
    "deploy:dev": "wrangler deploy",
    "deploy:prod": "wrangler deploy --env production"
  },
  "devDependencies": {
    "typescript": "^5.0.0",
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
    "types": ["./worker-configuration.d.ts"],
    "strict": true,
    "noUnusedLocals": true,
    "noUnusedParameters": true,
    "noFallthroughCasesInSwitch": true
  },
  "include": ["src/**/*.ts", "worker-configuration.d.ts"]
}
```

Note on `"types"`: `worker-configuration.d.ts` is generated by `wrangler types` and provides the `Env` interface. It must be generated before typechecking (`npm run typecheck` does this in sequence). The `@cloudflare/workers-types` package is not listed separately — the generated file includes the necessary Cloudflare types via its own references.

---

## §8 Cloudflare Access Configuration (C-1, C-2, C-3)

### §8.1 workers.dev route enforcement

By default, Cloudflare Access does not enforce on `workers.dev` routes. Enforcement must be explicitly enabled. In the Cloudflare Zero Trust dashboard, when creating the Access application:
- Set the application domain to the full `workers.dev` hostname: `forkensics-image-transform-dev.<subdomain>.workers.dev`
- Cloudflare will prompt to enable Access on the `workers.dev` route; confirm this.

Without this step, the Access policy is created but not applied to requests reaching the Worker.

### §8.2 Access application setup

- **Type:** Self-hosted
- **Name:** `forkensics-image-transform-dev`
- **Session duration:** No session (service-to-service — no user session cookie issued)
- **Application domain:** `forkensics-image-transform-dev.<subdomain>.workers.dev`
- **Path coverage:** All paths, including `/health`. No bypass rules.
  - Rationale: there is no identified operational requirement for a public health endpoint. All Worker interactions are server-to-server from `upload-complete`. Monitoring is available via the Cloudflare Workers analytics dashboard.

### §8.3 Access policy

- **Policy name:** `upload-complete service token only`
- **Action:** **Service Auth** (not "Allow" — "Service Auth" is the correct action for service-token-only policies)
- **Include rule:** Service Token → select the token created in §8.4
- No other include, require, or exclude rules.

### §8.4 Service token

- **Name:** `forkensics-upload-complete-dev`
- **Duration:** 1 year from creation date
- **Capture immediately:** Cloudflare displays the Client ID and Client Secret exactly once at creation. Bill captures both in 1Password before dismissing the dialog.

### §8.5 Renewal alert and rotation procedure

**Renewal alert:** Cloudflare sends an email notification before token expiration. Additionally, set a calendar reminder for 30 days before the 1-year expiration date.

**Rotation procedure** (when the token approaches expiration or requires replacement):

1. Create a new service token in Cloudflare Zero Trust: `forkensics-upload-complete-dev-new`.
2. Add the new token to the Access policy as an additional "Include" rule (both old and new tokens are now valid).
3. Update Supabase secrets `CF_ACCESS_CLIENT_ID` and `CF_ACCESS_CLIENT_SECRET` with the new token values.
4. Verify `upload-complete` calls succeed with the new credentials (probe CF-W-5 equivalent).
5. Remove the old token from the Access policy.
6. Delete the old token from Cloudflare Zero Trust.
7. Update the calendar reminder for the new token's expiration.

Overlap period (steps 2–4) ensures zero downtime. The old and new tokens coexist only during the rotation window.

---

## §9 Supabase Secrets

After Phase 2 cloud operations complete, Bill sets the following secrets in forkensics-dev. Values are never sent to Claude.

| Secret name | Value |
|-------------|-------|
| `CF_ACCESS_CLIENT_ID` | Client ID from §8.4 |
| `CF_ACCESS_CLIENT_SECRET` | Client Secret from §8.4 |
| `CF_WORKER_URL` | `https://forkensics-image-transform-dev.<subdomain>.workers.dev` |

Set via Supabase CLI:
```bash
supabase secrets set \
  CF_ACCESS_CLIENT_ID=<value> \
  CF_ACCESS_CLIENT_SECRET=<value> \
  CF_WORKER_URL=<value> \
  --project-ref hkfrbdpedrxmbsawnbpr
```

These are consumed by Step B (`upload-complete`). They are not stored in any file and not sent to Claude.

---

## §10 Deploy Sequence (Phase 2)

All operations performed by Bill after Phase 2 sign-off, in order:

| Step | Operation | Tool |
|------|-----------|------|
| D-1 | Create R2 bucket `forkensics-dev-media` | `wrangler r2 bucket create forkensics-dev-media` |
| D-2 | Deploy Worker | `npm run deploy:dev` (from `tools/image-transform/`) |
| D-3 | Create CF Access application | Cloudflare Zero Trust dashboard — §8.2; confirm workers.dev route enforcement |
| D-4 | Create CF Access policy (Service Auth) | Cloudflare Zero Trust dashboard — §8.3 |
| D-5 | Create service token | Cloudflare Zero Trust dashboard — §8.4; capture immediately |
| D-6 | Attach service token to policy | Add to Include rule in D-4 policy |
| D-7 | Set calendar reminder | 30 days before 1-year expiration |
| D-8 | Store Supabase secrets | Supabase CLI — §9 |
| D-9 | Run acceptance probes | §11 — all must PASS |

D-3 through D-6 must complete before D-9. D-8 is required for Step B (`upload-complete`) but not for Worker-level probe acceptance.

---

## §11 Acceptance Probes

Probes are run after D-2 through D-6 complete. Shell variables `$WORKER_URL`, `$CF_CLIENT_ID`, and `$CF_CLIENT_SECRET` are set by Bill from 1Password — not typed to Claude, not echoed to any log.

All probes use POST. Fixture files reference `tools/image-spike/cf-spike/fixtures/` (existing spike fixtures) and `tools/image-transform/fixtures/` (new fixtures generated in Phase 1).

### Pass criteria

Every probe must return its expected result. INCONCLUSIVE is not a valid outcome. CF-W-8 requires the 8193×100 JPEG fixture.

### Probe table

| Probe | Description | Expected |
|-------|-------------|----------|
| CF-W-1 | Health check with valid service token | HTTP 200, `{"status":"ok"}` |
| CF-W-2 | Request with no service token headers | HTTP 401 or 403 (CF Access rejects before Worker runs) |
| CF-W-3 | POST with path-traversal key (`--path-as-is`) | HTTP 400 |
| CF-W-4 | POST with syntactically valid path but non-UUID key | HTTP 400 |
| CF-W-5 | GET request to transform endpoint | HTTP 405, `Allow: POST` header present |
| CF-W-6 | POST with non-existent UUID key | HTTP 404 |
| CF-W-7 | Upload valid JPEG; POST `/transform/originals/{media_id}`; verify JSON response | HTTP 200; JSON with `displayKey`, `sha256`, `bytes` |
| CF-W-8 | Confirm display key object exists in R2 | `wrangler r2 object get --pipe --remote` exit 0 |
| CF-W-9 | Upload oversized file (> 10 MB) | HTTP 422, `error` contains `Input too large` |
| CF-W-10 | Upload image with side > 8192 px (8193×100 fixture) | HTTP 422, `error` contains `Dimension` |
| CF-W-11 | Upload image with area > 15.5 MP and sides ≤ 8192 px (4000×4000 fixture) | HTTP 422, `error` contains `Pixel area` |
| CF-W-12 | Confirm output WebP is metadata-stripped | `exiftool` on retrieved display object: no EXIF/GPS/XMP/ICC |
| CF-W-13 | Cleanup: delete all test objects from bucket | `wrangler r2 object delete` for each; confirm bucket is empty |

### CF-W-1 (health — valid token)

```bash
curl -s -X POST \
  -H "CF-Access-Client-Id: $CF_CLIENT_ID" \
  -H "CF-Access-Client-Secret: $CF_CLIENT_SECRET" \
  "$WORKER_URL/health"
# Expected: {"status":"ok"}  HTTP 200
```

### CF-W-2 (no token — CF Access rejects)

```bash
curl -s -w "\nHTTP %{http_code}" -X POST "$WORKER_URL/health"
# Expected: HTTP 401 or HTTP 403
```

### CF-W-3 (path traversal)

```bash
curl -s -w "\nHTTP %{http_code}" --path-as-is -X POST \
  -H "CF-Access-Client-Id: $CF_CLIENT_ID" \
  -H "CF-Access-Client-Secret: $CF_CLIENT_SECRET" \
  "$WORKER_URL/transform/originals/../etc/passwd"
# Expected: HTTP 400
```

### CF-W-4 (non-UUID key)

```bash
curl -s -w "\nHTTP %{http_code}" -X POST \
  -H "CF-Access-Client-Id: $CF_CLIENT_ID" \
  -H "CF-Access-Client-Secret: $CF_CLIENT_SECRET" \
  "$WORKER_URL/transform/originals/not-a-uuid"
# Expected: HTTP 400
```

### CF-W-5 (GET rejected)

```bash
curl -s -D - \
  -H "CF-Access-Client-Id: $CF_CLIENT_ID" \
  -H "CF-Access-Client-Secret: $CF_CLIENT_SECRET" \
  "$WORKER_URL/transform/originals/00000000-0000-4000-8000-000000000000"
# Expected: HTTP 405; response headers include: Allow: POST
```

### CF-W-6 (non-existent UUID key)

```bash
curl -s -w "\nHTTP %{http_code}" -X POST \
  -H "CF-Access-Client-Id: $CF_CLIENT_ID" \
  -H "CF-Access-Client-Secret: $CF_CLIENT_SECRET" \
  "$WORKER_URL/transform/originals/00000000-0000-4000-8000-000000000001"
# Expected: HTTP 404
```

### CF-W-7 (valid JPEG → 200 JSON)

```bash
MEDIA_ID="$(uuidgen | tr '[:upper:]' '[:lower:]')"
wrangler r2 object put "forkensics-dev-media/originals/$MEDIA_ID" \
  --file tools/image-spike/cf-spike/fixtures/fixture-exif.jpg --remote

curl -s -X POST \
  -H "CF-Access-Client-Id: $CF_CLIENT_ID" \
  -H "CF-Access-Client-Secret: $CF_CLIENT_SECRET" \
  "$WORKER_URL/transform/originals/$MEDIA_ID"
# Expected: HTTP 200
# Response body (pretty): {"displayKey":"display/<MEDIA_ID>.webp","sha256":"<hex>","bytes":<N>}
# Confirm displayKey == "display/$MEDIA_ID.webp"
```

### CF-W-8 (display key exists in bucket)

```bash
wrangler r2 object get "forkensics-dev-media/display/$MEDIA_ID.webp" \
  --pipe --remote > /dev/null
echo "Exit: $?"
# Expected: exit 0
```

### CF-W-9 (oversized byte gate)

```bash
dd if=/dev/urandom bs=1 count=1 seek=10485760 of=/tmp/oversized.bin 2>/dev/null
wrangler r2 object put "forkensics-dev-media/originals/$OVERSIZE_ID" \
  --file /tmp/oversized.bin --remote

curl -s -w "\nHTTP %{http_code}" -X POST \
  -H "CF-Access-Client-Id: $CF_CLIENT_ID" \
  -H "CF-Access-Client-Secret: $CF_CLIENT_SECRET" \
  "$WORKER_URL/transform/originals/$OVERSIZE_ID"
# Expected: HTTP 422; body JSON error contains "Input too large"
```

(`$OVERSIZE_ID` is a fresh `uuidgen`-generated UUID for this probe.)

### CF-W-10 (per-side dimension gate — 8193×100 fixture)

The 8193×100 JPEG is generated in Phase 1 (§11.8 below). It is 8193 px wide, which exceeds the 8192 px per-side limit. Area = 819,300 px — well within the 15.5 MP area limit, so only the side gate fires.

```bash
DIM_ID="$(uuidgen | tr '[:upper:]' '[:lower:]')"
wrangler r2 object put "forkensics-dev-media/originals/$DIM_ID" \
  --file tools/image-transform/fixtures/fixture-8193x100.jpg --remote

curl -s -w "\nHTTP %{http_code}" -X POST \
  -H "CF-Access-Client-Id: $CF_CLIENT_ID" \
  -H "CF-Access-Client-Secret: $CF_CLIENT_SECRET" \
  "$WORKER_URL/transform/originals/$DIM_ID"
# Expected: HTTP 422; body JSON error contains "Dimension" and "8192"
```

### CF-W-11 (area gate — 4000×4000 fixture)

The existing spike fixture `fixture-oversized-px.jpg` is 4000×4000. Area = 16,000,000 px > 15.5 MP limit. Both sides are 4000 px ≤ 8192 px, so only the area gate fires.

```bash
AREA_ID="$(uuidgen | tr '[:upper:]' '[:lower:]')"
wrangler r2 object put "forkensics-dev-media/originals/$AREA_ID" \
  --file tools/image-spike/cf-spike/fixtures/fixture-oversized-px.jpg --remote

curl -s -w "\nHTTP %{http_code}" -X POST \
  -H "CF-Access-Client-Id: $CF_CLIENT_ID" \
  -H "CF-Access-Client-Secret: $CF_CLIENT_SECRET" \
  "$WORKER_URL/transform/originals/$AREA_ID"
# Expected: HTTP 422; body JSON error contains "Pixel area"
```

### CF-W-12 (metadata stripped)

Retrieve the display copy and verify with exiftool:

```bash
wrangler r2 object get "forkensics-dev-media/display/$MEDIA_ID.webp" \
  --pipe --remote > /tmp/display_check.webp
exiftool /tmp/display_check.webp | grep -Ei "(gps|exif|xmp|icc|iptc|make|model|serial|creator|copyright)"
# Expected: no output
```

### CF-W-13 (cleanup)

```bash
for KEY in \
  "originals/$MEDIA_ID" \
  "display/$MEDIA_ID.webp" \
  "originals/$OVERSIZE_ID" \
  "originals/$DIM_ID" \
  "originals/$AREA_ID"; do
  wrangler r2 object delete "forkensics-dev-media/$KEY" --remote 2>/dev/null || true
  echo "[CLEANUP] $KEY"
done
```

After cleanup, confirm the bucket is empty in the Cloudflare dashboard.

### §11.8 Fixture Generation (Phase 1 — local, no cloud operation)

Generate the 8193×100 JPEG using ImageMagick. Run from the repo root after Phase 1 sign-off:

```bash
mkdir -p tools/image-transform/fixtures
magick -size 8193x100 xc:white -quality 85 \
  tools/image-transform/fixtures/fixture-8193x100.jpg
```

Verify dimensions:
```bash
magick identify tools/image-transform/fixtures/fixture-8193x100.jpg
# Expected output includes: 8193x100
```

If ImageMagick is unavailable, use Python Pillow:
```python
from PIL import Image
img = Image.new("RGB", (8193, 100), color=(255, 255, 255))
img.save("tools/image-transform/fixtures/fixture-8193x100.jpg", quality=85)
```

This fixture does not require a SHA-256 entry — it is a test input, not a committed source artifact.

---

## §12 Rollback Plan

If any probe in §11 fails and cannot be resolved in the same session:

1. Delete the Worker: `wrangler delete forkensics-image-transform-dev --force` (suppress any KV auth errors; verify via Cloudflare dashboard).
2. Revoke the service token in Cloudflare Zero Trust → Access → Service Auth → Service Tokens.
3. Delete the CF Access application in Cloudflare Zero Trust → Access → Applications.
4. Empty and delete the R2 bucket: delete all objects first, then `wrangler r2 bucket delete forkensics-dev-media`.
5. If Supabase secrets were set (D-8), unset `CF_ACCESS_CLIENT_ID`, `CF_ACCESS_CLIENT_SECRET`, `CF_WORKER_URL` via the Supabase dashboard.
6. Source files in `tools/image-transform/` remain locally — no source deletion.

Rollback leaves forkensics-dev Supabase project, its data, and all existing Edge Functions intact. No production resources are affected.

---

## §13 Post-Approval Sequence Summary

```
Phase 1 sign-off (all three parties)
  └─▶ Create tools/image-transform/ artifacts locally
  └─▶ npm install  →  generates package-lock.json
  └─▶ wrangler types  →  generates worker-configuration.d.ts (not committed)
  └─▶ npm run typecheck  →  must pass with 0 errors
  └─▶ Generate fixture-8193x100.jpg  →  verify 8193×100
  └─▶ [optional] wrangler deploy --dry-run
  └─▶ Compute SHA-256 of all five locked artifacts
  └─▶ All three parties confirm SHA-256 values

Phase 2 sign-off (all three parties, with SHA-256 confirmed)
  └─▶ D-1: Create forkensics-dev-media R2 bucket
  └─▶ D-2: npm run deploy:dev
  └─▶ D-3–D-6: CF Access application + Service Auth policy + service token; enable workers.dev route
  └─▶ D-7: Set calendar reminder (token expiration − 30 days)
  └─▶ D-8: Set Supabase secrets
  └─▶ D-9: Run probes CF-W-1 through CF-W-13 — all must PASS

Phase 2 PASS
  └─▶ Step B (upload-complete) proposal authorized to begin
  └─▶ Step A amendment (upload-authorize R2 presign) authorized to begin

Phase 3 (separate proposal — production deployment)
```
