# CF-Worker-Prod — Production Image Transform Worker
## Proposal Rev 3 — 2026-08-16

**Status:** DRAFT — Awaiting three-party approval (Claude + Codex + Bill)

**Supersedes:** Rev 2 (CHANGES REQUIRED — 7 governance and probe corrections)

**Governance gate:** All three parties must approve Phase 1 before any artifact is created or edited locally.
All three parties must approve Phase 2 before any cloud operation is performed.

Magic words:
- Claude: `APPROVED: CF-Worker-Prod Rev 3 — Phase 1`  /  `APPROVED: CF-Worker-Prod Rev 3 — Phase 2`
- Codex:  `APPROVED: CF-Worker-Prod Rev 3 — Phase 1`  /  `APPROVED: CF-Worker-Prod Rev 3 — Phase 2`
- Bill:   `APPROVED: CF-Worker-Prod Rev 3 — Phase 1`  /  `APPROVED: CF-Worker-Prod Rev 3 — Phase 2`

---

## §0 Rev 3 Changes (relative to Rev 2)

| # | Correction |
|---|-----------|
| C-1 | Credential constraint language updated: "never sent to Claude, Codex, or any AI/chat system" throughout |
| C-2 | CF Access setup corrected to hostname-based protection only; removed incorrect claim that Cloudflare prompts separately to enable route enforcement |
| C-3 | Deploy creation order corrected: Worker deployed first (hostname exists), then service token created (credentials captured), then Access application, then Service Auth policy (token must exist before the Include rule can reference it) |
| C-4 | Expiration alert explicitly configured in Phase 2 authorization and deploy sequence; Cloudflare does not send this automatically |
| C-5 | Supabase secrets set via dashboard (primary) or shell variable expansion (alternative); literal credential values no longer appear in illustrated commands |
| C-6 | `$OVERSIZE_ID` assigned before use in CF-W-9 |
| C-7 | CF-W-7 made authoritative: asserts HTTP 200, `displayKey` equality, `sha256` hex format, `bytes` range |

Sections not listed above are unchanged from Rev 2. §5 (Worker TypeScript), §6 (wrangler.toml), §7 (package files), §11.8 (fixture generation), and §12 (rollback plan) are identical to Rev 2 and are reproduced in full below for completeness.

---

## §1 Governance

### §1.1 Security Constraints (permanent — cannot be overridden)

- `CF_ACCESS_CLIENT_ID`, `CF_ACCESS_CLIENT_SECRET`, and any Cloudflare credential: never in client code, never in the repo, **never sent to Claude, Codex, or any AI/chat system**.
- `ANON_KEY` and `SERVICE_ROLE_KEY`: runtime environment variables only; never written to any file, echoed, or logged; **never sent to Claude, Codex, or any AI/chat system**.
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
- Creating `tools/image-transform/` directory and all files listed in §2.
- Adding `worker-configuration.d.ts` and `node_modules/` to `.gitignore`.
- Running `npm install` locally (writes `node_modules/` and `package-lock.json`).
- Running `wrangler types` locally (reads `wrangler.toml`, writes `worker-configuration.d.ts`).
- Running `tsc --noEmit` (typecheck only — no deploy).
- Creating `tools/image-transform/fixtures/` and generating the 8193×100 JPEG fixture (§11.8).
- Running `wrangler deploy --dry-run` if supported by the installed Wrangler version; skip without error if unsupported.
- Read-only Cloudflare Dashboard inspection to confirm Workers plan and account ID.

Prohibits:
- Any Cloudflare cloud operation (bucket create, object upload, Worker deploy, Access application create, service token create, any API mutation).
- Any Supabase operation.
- Any read or write against any R2 bucket.
- Running `wrangler deploy` without `--dry-run`.

| Party | Status | Note |
|-------|--------|------|
| Claude | ✅ | Rev 3 authored; Phase 1 approved |
| Codex | ✅ | Phase 1 approved |
| Bill | ✅ | Phase 1 approved |

#### Phase 2 — Execution authorization (forkensics-dev only)

Requires all Phase 1 sign-off plus locked artifact SHA-256 confirmation (§2).

Authorizes:
- Creating R2 bucket `forkensics-dev-media`.
- Deploying `forkensics-image-transform-dev` Worker.
- Creating the Cloudflare Access service token for the dev Worker.
- Creating the Cloudflare Access self-hosted application protecting the Worker hostname.
- Creating the Service Auth policy with the service token as its Include rule.
- Configuring the "Expiring Access Service Token" notification in Cloudflare.
- Setting `CF_ACCESS_CLIENT_ID`, `CF_ACCESS_CLIENT_SECRET`, and `CF_WORKER_URL` in forkensics-dev Supabase secrets.
- Running acceptance probes §11.

Prohibits:
- Any operation on forkensics-prod Supabase project.
- Creating a production R2 bucket or production Worker.
- Storing credentials in the repo, any committed file, or any file or message sent to Claude, Codex, or any AI/chat system.

| Party | Status | Note |
|-------|--------|------|
| Claude | ✅ | Phase 2 approved |
| Codex | ✅ | Phase 2 approved |
| Bill | ✅ | Phase 2 approved — 2026-08-16 |

#### Phase 3 — Production deployment (separate proposal)

Scope: deploy `forkensics-image-transform` Worker bound to `forkensics-prod-media` R2 bucket; configure production CF Access service token; store secrets in forkensics-prod Supabase project. Requires a separate three-party proposal and sign-off. Not authorized by this document.

---

## §2 Locked Artifacts

All artifacts reside under `tools/image-transform/`. SHA-256 values are populated after Phase 1 artifact creation and confirmed by all three parties before Phase 2 sign-off.

| Artifact | SHA-256 | Review status |
|----------|---------|---------------|
| `src/index.ts` | `bdfe2b241ded2fdcbd185859208f6408000fce6bc16c7d216f964cdf5d2d82ca` | ✅ Claude |
| `wrangler.toml` | `fbcd760c2fec6a132bebf61af1749321a9baec5e0ce02edad3df168ca9b7e7e6` | ✅ Claude |
| `tsconfig.json` | `5cb8c7ea380acbb3c26e9aaded30b839f057c2a887bd005a34faf40459797e28` | ✅ Claude |
| `package.json` | `7c808a727ff9bf299732abf1b855ca120a3ad3ca8b988048339fee8e30d0da58` | ✅ Claude |
| `package-lock.json` | `96a14de672435cf07b6598a5cc12d58023107ee4b4fd9cba3cd2a554cbf54277` | ✅ Claude (darwin-arm64; prior hash was Linux sandbox) |

SHA-256: `shasum -a 256 <file>` (macOS) or `sha256sum <file>` (Linux).

`worker-configuration.d.ts` is excluded — generated from `wrangler.toml` by `wrangler types`; must not be committed.

---

## §3 Scope

Unchanged from Rev 2 §3.

---

## §4 Directory Structure

Unchanged from Rev 2 §4.

---

## §5 Worker Implementation — `src/index.ts`

Unchanged from Rev 2 §5. Full text reproduced:

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
    const displayKey = `display/${mediaId}.webp`;

    await env.BUCKET.put(displayKey, out, {
      httpMetadata: { contentType: "image/webp" },
    });

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

Unchanged from Rev 2 §6. Full text reproduced:

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

---

## §7 Package Files

Unchanged from Rev 2 §7.

---

## §8 Cloudflare Access Configuration (C-2, C-3, C-4)

### §8.1 Architecture — hostname-based protection

The Worker is protected by a Cloudflare Access self-hosted application scoped to its exact `workers.dev` hostname. When a request arrives at that hostname, Cloudflare Access evaluates the configured policy before the request reaches the Worker. There is no separate "enable route enforcement" step — the hostname application itself is the enforcement mechanism.

Reference: [Cloudflare Workers — Cloudflare Access](https://developers.cloudflare.com/workers/configuration/cloudflare-access/)

### §8.2 Service token (create first)

The service token must exist before the Access policy can reference it as an Include rule.

- Navigate: Zero Trust → Access → Service Auth → Service Tokens → Create Service Token
- **Name:** `forkensics-upload-complete-dev`
- **Duration:** 1 year from creation date
- **Capture immediately:** Cloudflare displays the Client ID and Client Secret exactly once. Bill captures both in 1Password before dismissing the dialog. These values are **never sent to Claude, Codex, or any AI/chat system**.

### §8.3 Access application (create after token)

- Navigate: Zero Trust → Access → Applications → Add an application → Self-hosted
- **Name:** `forkensics-image-transform-dev`
- **Application domain:** `forkensics-image-transform-dev.<subdomain>.workers.dev` (exact hostname; no wildcard)
- **Session duration:** No session (service-to-service)
- **Path coverage:** All paths, including `/health`. No bypass rules applied.

### §8.4 Service Auth policy (create after application)

Every Access policy requires at least one Include rule. Create this policy after the application and after the service token both exist.

- **Policy name:** `upload-complete service token only`
- **Action:** Service Auth
- **Include rule:** Service Token → select `forkensics-upload-complete-dev`
- No Require or Exclude rules.

### §8.5 Expiration alert (configure explicitly — Cloudflare does not send automatically)

After creating the service token, configure the notification in Cloudflare:

- Navigate: Zero Trust → Settings → Notifications → Add a notification
- **Alert type:** Expiring Access Service Token
- **Recipients:** Bill's email address
- Save the notification.

Additionally, set a calendar reminder for 30 days before the 1-year expiration date (independent of the Cloudflare notification, as a second safeguard).

### §8.6 Rotation procedure

When the token approaches expiration or requires replacement:

1. Create a new service token with a dated name, e.g. `forkensics-upload-complete-dev-2027-08` (1-year duration). The new token retains this dated name permanently — do not rename or recreate it, as doing so issues different credentials.
2. Capture the new Client ID and Client Secret in 1Password.
3. Add the new token to the Access policy as a second Include rule (both tokens valid during overlap).
4. Update Supabase secrets with the new credentials (§9).
5. Verify `upload-complete` calls succeed with the new credentials (run CF-W-7 equivalent).
6. Remove the old token from the Access policy Include rules.
7. Delete the old token from Zero Trust → Service Auth → Service Tokens.
8. Update the Cloudflare expiration alert and the calendar reminder for the new token's expiration.

---

## §9 Supabase Secrets (C-5)

After D-5 completes, Bill sets the following secrets in forkensics-dev. Literal credential values must not appear in shell history, terminal logs, or any message sent to Claude, Codex, or any AI/chat system.

**Primary method — Supabase dashboard:**
Navigate to the forkensics-dev project → Settings → Edge Functions → Secrets. Add each secret by name and paste the value directly into the dashboard form. Values entered here do not enter shell history.

**Alternative — CLI with shell variable expansion:**
If using the Supabase CLI, read credential values into shell variables first (from 1Password CLI, a secrets file that is not committed, or another secure source), then pass the variable references — not literal values — to the command. The variable expansions appear in the process argument list but not in shell history:

```bash
# Example: variables CF_ID, CF_SECRET, and CF_URL are already set in the current shell
# from a secure source — literal values are not typed here
supabase secrets set \
  CF_ACCESS_CLIENT_ID="$CF_ID" \
  CF_ACCESS_CLIENT_SECRET="$CF_SECRET" \
  CF_WORKER_URL="$CF_URL" \
  --project-ref hkfrbdpedrxmbsawnbpr
```

| Secret name | Value |
|-------------|-------|
| `CF_ACCESS_CLIENT_ID` | Client ID from §8.2 |
| `CF_ACCESS_CLIENT_SECRET` | Client Secret from §8.2 |
| `CF_WORKER_URL` | `https://forkensics-image-transform-dev.<subdomain>.workers.dev` |

---

## §10 Deploy Sequence (Phase 2) (C-3, C-4)

Operations performed by Bill after Phase 2 sign-off. Order is significant: D-3 (service token) must precede D-4 (application) and D-5 (policy). D-5 requires the token from D-3 as its Include rule.

| Step | Operation | Tool |
|------|-----------|------|
| D-1 | Create R2 bucket `forkensics-dev-media` | `wrangler r2 bucket create forkensics-dev-media` |
| D-2 | Deploy Worker | `npm run deploy:dev` (from `tools/image-transform/`) |
| D-3 | Create service token; capture Client ID + Secret in 1Password | Zero Trust → Access → Service Auth → Service Tokens |
| D-4 | Create self-hosted Access application for Worker hostname | Zero Trust → Access → Applications — §8.3 |
| D-5 | Create Service Auth policy; add token from D-3 as Include rule | Zero Trust — §8.4 |
| D-6 | Configure "Expiring Access Service Token" notification | Zero Trust → Settings → Notifications — §8.5 |
| D-7 | Set calendar reminder (token expiration − 30 days) | |
| D-8 | Set Supabase secrets | Dashboard or CLI — §9 |
| D-9 | Run acceptance probes | §11 — all must PASS |

---

## §11 Acceptance Probes (C-6, C-7)

Shell variables `$WORKER_URL`, `$CF_CLIENT_ID`, and `$CF_CLIENT_SECRET` are set by Bill from 1Password — not typed to Claude, Codex, or any AI/chat system, not echoed to any log.

### Pass criteria

All probes CF-W-1 through CF-W-13 must return their expected result. INCONCLUSIVE is not valid.

### Probe table

| Probe | Description | Expected |
|-------|-------------|----------|
| CF-W-1 | Health check with valid token | HTTP 200, `{"status":"ok"}` |
| CF-W-2 | No token → CF Access rejects | HTTP 401 or 403 |
| CF-W-3 | POST path-traversal key (`--path-as-is`) | HTTP 400 |
| CF-W-4 | POST non-UUID key | HTTP 400 |
| CF-W-5 | GET request (wrong method) | HTTP 405, `Allow: POST` |
| CF-W-6 | POST non-existent UUID key | HTTP 404 |
| CF-W-7 | Upload valid JPEG; POST `/transform/originals/{media_id}`; assert response | HTTP 200; `displayKey == "display/$MEDIA_ID.webp"`; `sha256` is 64 hex chars; `0 < bytes ≤ 5242880` |
| CF-W-8 | Display key object exists in R2 | exit 0 |
| CF-W-9 | Upload oversized file (> 10 MB) | HTTP 422, error contains `Input too large` |
| CF-W-10 | Upload 8193×100 fixture (side gate) | HTTP 422, error contains `Dimension` |
| CF-W-11 | Upload 4000×4000 fixture (area gate) | HTTP 422, error contains `Pixel area` |
| CF-W-12 | Retrieve display copy; assert metadata stripped | No EXIF/GPS/XMP/ICC output from exiftool |
| CF-W-13 | Cleanup all test objects | All deletes attempted; bucket confirmed empty |

### CF-W-1

```bash
curl -s -X POST \
  -H "CF-Access-Client-Id: $CF_CLIENT_ID" \
  -H "CF-Access-Client-Secret: $CF_CLIENT_SECRET" \
  "$WORKER_URL/health"
# Expected: {"status":"ok"}  HTTP 200
```

### CF-W-2

```bash
curl -s -w "\nHTTP %{http_code}" -X POST "$WORKER_URL/health"
# Expected: HTTP 401 or HTTP 403
```

### CF-W-3

```bash
curl -s -w "\nHTTP %{http_code}" --path-as-is -X POST \
  -H "CF-Access-Client-Id: $CF_CLIENT_ID" \
  -H "CF-Access-Client-Secret: $CF_CLIENT_SECRET" \
  "$WORKER_URL/transform/originals/../etc/passwd"
# Expected: HTTP 400
```

### CF-W-4

```bash
curl -s -w "\nHTTP %{http_code}" -X POST \
  -H "CF-Access-Client-Id: $CF_CLIENT_ID" \
  -H "CF-Access-Client-Secret: $CF_CLIENT_SECRET" \
  "$WORKER_URL/transform/originals/not-a-uuid"
# Expected: HTTP 400
```

### CF-W-5

```bash
curl -s -D - \
  -H "CF-Access-Client-Id: $CF_CLIENT_ID" \
  -H "CF-Access-Client-Secret: $CF_CLIENT_SECRET" \
  "$WORKER_URL/transform/originals/00000000-0000-4000-8000-000000000000"
# Expected: HTTP 405; response headers include: Allow: POST
```

### CF-W-6

```bash
curl -s -w "\nHTTP %{http_code}" -X POST \
  -H "CF-Access-Client-Id: $CF_CLIENT_ID" \
  -H "CF-Access-Client-Secret: $CF_CLIENT_SECRET" \
  "$WORKER_URL/transform/originals/00000000-0000-4000-8000-000000000001"
# Expected: HTTP 404
```

### CF-W-7 (authoritative — assert all four conditions)

```bash
MEDIA_ID="$(uuidgen | tr '[:upper:]' '[:lower:]')"
wrangler r2 object put "forkensics-dev-media/originals/$MEDIA_ID" \
  --file tools/image-spike/cf-spike/fixtures/fixture-exif.jpg --remote

RESP_BODY="$(curl -s -w "\n%{http_code}" -X POST \
  -H "CF-Access-Client-Id: $CF_CLIENT_ID" \
  -H "CF-Access-Client-Secret: $CF_CLIENT_SECRET" \
  "$WORKER_URL/transform/originals/$MEDIA_ID")"

HTTP_CODE="$(echo "$RESP_BODY" | tail -1)"
JSON_BODY="$(echo "$RESP_BODY" | head -n -1)"

# Assert HTTP 200
[ "$HTTP_CODE" = "200" ] || { echo "FAIL CF-W-7: HTTP $HTTP_CODE"; exit 1; }

# Assert displayKey == "display/$MEDIA_ID.webp"
DISPLAY_KEY="$(echo "$JSON_BODY" | python3 -c 'import sys,json; print(json.load(sys.stdin)["displayKey"])')"
[ "$DISPLAY_KEY" = "display/$MEDIA_ID.webp" ] \
  || { echo "FAIL CF-W-7: displayKey '$DISPLAY_KEY' != 'display/$MEDIA_ID.webp'"; exit 1; }

# Assert sha256 is exactly 64 lowercase hex characters
SHA256="$(echo "$JSON_BODY" | python3 -c 'import sys,json; print(json.load(sys.stdin)["sha256"])')"
echo "$SHA256" | grep -qE '^[0-9a-f]{64}$' \
  || { echo "FAIL CF-W-7: sha256 '$SHA256' is not 64 hex chars"; exit 1; }

# Assert bytes > 0 and <= 5242880
BYTES="$(echo "$JSON_BODY" | python3 -c 'import sys,json; print(json.load(sys.stdin)["bytes"])')"
[ "$BYTES" -gt 0 ] || { echo "FAIL CF-W-7: bytes is 0"; exit 1; }
[ "$BYTES" -le 5242880 ] || { echo "FAIL CF-W-7: bytes $BYTES > 5242880"; exit 1; }

echo "PASS CF-W-7: HTTP 200, displayKey=$DISPLAY_KEY, sha256=${SHA256:0:8}..., bytes=$BYTES"
```

### CF-W-8 (display key exists in R2)

```bash
wrangler r2 object get "forkensics-dev-media/display/$MEDIA_ID.webp" \
  --pipe --remote > /dev/null
echo "Exit: $?"
# Expected: exit 0
```

### CF-W-9 (oversized byte gate)

```bash
OVERSIZE_ID="$(uuidgen | tr '[:upper:]' '[:lower:]')"
dd if=/dev/urandom bs=1 count=1 seek=10485760 of=/tmp/oversized.bin 2>/dev/null
wrangler r2 object put "forkensics-dev-media/originals/$OVERSIZE_ID" \
  --file /tmp/oversized.bin --remote

curl -s -w "\nHTTP %{http_code}" -X POST \
  -H "CF-Access-Client-Id: $CF_CLIENT_ID" \
  -H "CF-Access-Client-Secret: $CF_CLIENT_SECRET" \
  "$WORKER_URL/transform/originals/$OVERSIZE_ID"
# Expected: HTTP 422; body JSON error contains "Input too large"
```

### CF-W-10 (per-side dimension gate — 8193×100 fixture)

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

```bash
wrangler r2 object get "forkensics-dev-media/display/$MEDIA_ID.webp" \
  --pipe --remote > /tmp/display_check.webp
exiftool /tmp/display_check.webp \
  | grep -Ei "(gps|exif|xmp|icc|iptc|make|model|serial|creator|copyright)"
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

After cleanup, confirm the bucket contains no objects (Cloudflare dashboard or `wrangler r2 object list forkensics-dev-media --remote`).

### §11.8 Fixture Generation (Phase 1 — local, no cloud operation)

Generate the 8193×100 JPEG (one side exceeds the 8192 px per-side gate):

```bash
mkdir -p tools/image-transform/fixtures

# ImageMagick (preferred):
magick -size 8193x100 xc:white -quality 85 \
  tools/image-transform/fixtures/fixture-8193x100.jpg

# Verify:
magick identify tools/image-transform/fixtures/fixture-8193x100.jpg
# Expected: 8193x100 in the output

# Pillow alternative if ImageMagick is unavailable:
python3 -c "
from PIL import Image
Image.new('RGB', (8193, 100), (255, 255, 255)).save(
  'tools/image-transform/fixtures/fixture-8193x100.jpg', quality=85
)
print('Created 8193x100 fixture')
"
```

---

## §12 Rollback Plan

Unchanged from Rev 2 §12. If any probe fails and cannot be resolved in the same session:

1. Delete Worker: `wrangler delete forkensics-image-transform-dev --force` (ignore KV auth errors; verify via dashboard).
2. Revoke service token: Zero Trust → Access → Service Auth → Service Tokens → Revoke.
3. Delete Access application: Zero Trust → Access → Applications → Delete.
4. Delete expiration notification: Zero Trust → Settings → Notifications.
5. Empty and delete R2 bucket (all objects first, then `wrangler r2 bucket delete forkensics-dev-media`).
6. Unset Supabase secrets `CF_ACCESS_CLIENT_ID`, `CF_ACCESS_CLIENT_SECRET`, `CF_WORKER_URL` via dashboard if D-8 was reached.
7. Source files in `tools/image-transform/` remain locally; no source deletion.

Rollback leaves forkensics-dev Supabase project, its data, and all existing Edge Functions intact. No production resources are affected.

---

## §13 Post-Approval Sequence Summary

```
Phase 1 sign-off (all three parties)
  └─▶ Create tools/image-transform/ artifacts locally
  └─▶ npm install  →  generates package-lock.json
  └─▶ wrangler types  →  generates worker-configuration.d.ts (not committed)
  └─▶ npm run typecheck  →  must pass with 0 errors
  └─▶ Generate fixture-8193x100.jpg  →  verify 8193×100 (§11.8)
  └─▶ [optional] wrangler deploy --dry-run
  └─▶ Compute SHA-256 of all five locked artifacts
  └─▶ All three parties confirm SHA-256 values

Phase 2 sign-off (all three parties, SHA-256 confirmed)
  └─▶ D-1: wrangler r2 bucket create forkensics-dev-media
  └─▶ D-2: npm run deploy:dev
  └─▶ D-3: Create service token — capture Client ID + Secret immediately in 1Password
  └─▶ D-4: Create self-hosted Access application for Worker hostname
  └─▶ D-5: Create Service Auth policy — add token from D-3 as Include rule
  └─▶ D-6: Configure "Expiring Access Service Token" notification
  └─▶ D-7: Set calendar reminder (token expiration − 30 days)
  └─▶ D-8: Set Supabase secrets via dashboard or shell variable expansion
  └─▶ D-9: Run probes CF-W-1 through CF-W-13 — all must PASS

Phase 2 PASS
  └─▶ Step B (upload-complete) proposal authorized to begin
  └─▶ Step A amendment (upload-authorize R2 presign) authorized to begin

Phase 3 (separate proposal — production deployment)
```

---

## §14 Phase 2 Execution Evidence — 2026-08-16

**Overall verdict: PASS**

### Deploy sequence results

| Step | Operation | Result |
|------|-----------|--------|
| D-1 | Create R2 bucket `forkensics-dev-media` | ✅ Bucket created |
| D-2 | Deploy Worker `forkensics-image-transform-dev` | ✅ Deployed — `https://forkensics-image-transform-dev.billmags.workers.dev` |
| D-3 | Create service token `forkensics-upload-complete-dev` | ✅ Token created; credentials captured in 1Password |
| D-4 | Create CF Access application `forkensics-image-transform-dev` | ✅ Created — Workers destination, "A Worker's production and preview URLs" |
| D-5 | Create Service Auth policy `upload-complete service token only` | ✅ Action: Service Auth; Include: Service Token → `forkensics-upload-complete-dev` |
| D-6 | Configure "Expiring Access Service Token Alert" notification | ✅ Configured — recipient: billmags@gmail.com |
| D-7 | Calendar reminder 30 days before token expiration | ✅ Set for 2027-07-17 |
| D-8 | Set Supabase secrets (`CF_ACCESS_CLIENT_ID`, `CF_ACCESS_CLIENT_SECRET`, `CF_WORKER_URL`) | ✅ Set via dashboard — project `hkfrbdpedrxmbsawnbpr` |
| D-9 | Run acceptance probes CF-W-1 through CF-W-13 | ✅ All 13 PASS |

### Wrangler version

`wrangler 4.123.0`

### Acceptance probe results

| Probe | Description | Result |
|-------|-------------|--------|
| CF-W-1 | Health check with valid token | ✅ HTTP 200, `{"status":"ok"}` |
| CF-W-2 | No token → CF Access rejects | ✅ HTTP 403 |
| CF-W-3 | Path-traversal key | ✅ HTTP 400 |
| CF-W-4 | Non-UUID key | ✅ HTTP 400 |
| CF-W-5 | GET request (wrong method) | ✅ HTTP 405, `Allow: POST` |
| CF-W-6 | Non-existent UUID key | ✅ HTTP 404 |
| CF-W-7 | Valid JPEG transform — all 4 assertions | ✅ HTTP 200; `displayKey=display/fdb0012f-…/webp`; sha256=64 hex chars; bytes=7300 |
| CF-W-8 | Display key exists in R2 | ✅ exit 0 |
| CF-W-9 | Oversized file (> 10 MB) | ✅ HTTP 422, `Input too large: 10485761 > 10485760` |
| CF-W-10 | 8193×100 fixture — per-side gate | ✅ HTTP 422, `Dimension 8193×100 exceeds 8192px per-side limit` |
| CF-W-11 | 4000×4000 fixture — area gate | ✅ HTTP 422, `Pixel area 16000000 > 15500000` |
| CF-W-12 | Metadata stripped from display WebP | ✅ No GPS/EXIF/XMP/ICC/IPTC/Make/Model/Serial/Creator/Copyright in output |
| CF-W-13 | Cleanup all test objects | ✅ All 5 objects deleted; `forkensics-dev-media` confirmed 0 objects / 0 B |

### Credentials recorded

No credentials appear in this document. Client ID, Client Secret, and API tokens were captured in 1Password and set as Supabase secrets via the dashboard UI only.
