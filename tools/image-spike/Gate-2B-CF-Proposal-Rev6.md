# Gate 2B — Cloudflare R2 + Images Binding Feasibility Spike
## Proposal Rev 6 — 2026-08-15

**Supersedes:** Rev 5 (not approved — 10 blockers, Codex SHA-256 `16efbdaed7d70d24947a4b80cc1bcd7c6acf57ddcbd78b655d5d815a6f02b972`)

---

## §1 Governance

### §1.1 Security Constraints (permanent — cannot be overridden)

- `CLOUDFLARE_API_TOKEN`, `SPIKE_SECRET`, and any Cloudflare credential: never in client code, never in the repo, never sent to Claude.
- `ANON_KEY` and `SERVICE_ROLE_KEY`: runtime environment variables only; never written to any file, echoed, or logged.
- Three-party governance: **Bill + Claude + Codex** must approve each phase before its authorized operations begin.
- Authorized Supabase project: `hkfrbdpedrxmbsawnbpr` (forkensics-dev ONLY).
- **Authorized Cloudflare account ID: `1dd6ede816fa36a5a824a6e21f82ad7b`**
  Verified from `dash.cloudflare.com/1dd6ede816fa36a5a824a6e21f82ad7b/images/transformations` — 2026-08-15.
- All spike resources use the suffix `-spike` and are removed at CF-P-12.

### §1.2 Two-Phase Authorization (B-2 corrected)

#### Phase 1 — Proposal sign-off

Authorizes:
- Reviewing this document.
- CF-P-0b: read-only Cloudflare Dashboard check (Workers plan).
- Wrangler `--help` verification for all commands in §4.8.
- **Local creation and editing** of the six locked spike artifacts: `src/index.ts`, `src/index.test.ts`, `wrangler.toml`, `run-spike.sh`, `fixtures/generate-fixtures.sh`, `parser/verify-webp.sh`.

Prohibits:
- Any Cloudflare cloud operation (bucket create, object upload, Worker deploy, `wrangler dev --remote`, any API mutation).
- Any read operation against the spike bucket or Worker.
- Any Supabase operation.

| Party | Status | Note |
|-------|--------|------|
| Claude | ⬜ pending | |
| Codex | ⬜ pending | |
| Bill | ⬜ pending | |

#### Phase 2 — Artifact lock and execution authorization

Requires all of the following before any cloud operation:

1. `CF_ACCOUNT_ID` placeholder replaced (§1.1).
2. All six Phase 2 artifacts exist, are frozen, and have recorded SHA-256:

| Artifact | SHA-256 | Review status |
|----------|---------|---------------|
| `src/index.ts` | ⬜ pending | ⬜ pending |
| `src/index.test.ts` | ⬜ pending | ⬜ pending |
| `wrangler.toml` | ⬜ pending | ⬜ pending |
| `run-spike.sh` | ⬜ pending | ⬜ pending |
| `fixtures/generate-fixtures.sh` | ⬜ pending | ⬜ pending |
| `parser/verify-webp.sh` | ⬜ pending | ⬜ pending |

3. Static-check evidence: `tsc --noEmit` exits 0, zero errors.
4. Local unit-test evidence: full Vitest suite passes (§5).
5. Wrangler `--help` verification recorded for all commands in §4.8.

| Party | Status | Note |
|-------|--------|------|
| Claude | ⬜ pending | |
| Codex | ⬜ pending | |
| Bill | ⬜ pending | |

### §1.3 CF-P-0 Activation — Reconciliation

Images & Stream activated 2026-08-15 by Bill at $0/month. No Worker deployed, no bucket created, no transformation called. Recorded as completed prerequisite.

---

## §2 Context

### §2.1 Why This Proposal Exists

Gate 2B Rev 15: HTTP 546 (Supabase pre-handler resource exhaustion). Gate 2B Rev 20: P-0 BLOCKED (Supabase Free plan excludes managed transformations). This proposal tests Fallback Rank 1: **Cloudflare R2 + Images binding**.

### §2.2 CF-P-0 — Images Plan Eligibility (COMPLETE — PASS, 2026-08-15)

5,000 unique transformations/month free; spike consumes ≤ 20. No existing R2 bucket.

### §2.3 CF-P-0b — Workers Plan Eligibility (Phase 1 read-only step)

Cloudflare resource exhaustion is **Error 1102** (not HTTP 546).

| Plan | CPU limit | Notes |
|------|-----------|-------|
| Free | **10 ms** hard | Error 1102 on exceed |
| Paid ($5/month) | **30 s default**, up to **5 min** via `cpu_ms` | Set in `wrangler.toml` |

Authorized read-only action: Dashboard → Workers & Pages → Overview. Record plan name and effective CPU limit. This result sets `CPU_LIMIT_MS` used by CF-P-8 to gate execution.

**Account verification** (uses account-details endpoint — not token/verify):
```bash
ACCOUNT_RESP=$(curl -s -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  "https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT_ID")
[ "$(echo "$ACCOUNT_RESP" | jq -r '.success')" = "true" ] \
  && [ "$(echo "$ACCOUNT_RESP" | jq -r '.result.id')" = "$CF_ACCOUNT_ID" ] \
  || { echo "FAIL: Account verification failed"; exit 1; }
```

**Minimum API token scopes:**

| Scope | Required for |
|-------|-------------|
| Workers Scripts:Edit | Deploy, delete |
| Workers Scripts:Read | Existence check via API |
| R2:Edit | Bucket create/delete, object put/delete |
| R2:Read | Object head/get |
| Account Settings:Read | Account details verification |

---

## §3 Architecture

```
iPhone → presigned PUT → Private R2 (originals)
  → Cloudflare Worker (CLOUDFLARE_ACCOUNT_ID pinned — B-3)
      GET /health → 200 (no auth, no R2, no IMAGES)
      auth boundary
      BUCKET.head(key) → ETag + size (no body stream opened — AH-1)
      size gate: > 10 MB → 422
      BUCKET.get(key, ETag-matched) → IMAGES.info() [free]
      format gate: JPEG or WebP only (alias map)
      area gate: width × height > 15,500,000 px → 422
      fileSize consistency (if in generated types)
      BUCKET.get(key, ETag-matched) → IMAGES.transform().output(anim:false)
      validate response (status, exact Content-Type, nonempty body)
      bounded stream read (≤ 5 MB + 1 byte)
      SHA-256
      BUCKET.put display/{basename}.webp
      return 200 + headers
  → Supabase upload-finalize (future)
```

---

## §4 Constraints

### §4.1 Input / Output Limits
- Input: `head.size > MAX_INPUT_BYTES (10 MB)` → 422 before any billable call.
- Output: ≤ 5 MB via bounded stream read before R2 write.

### §4.2 Pixel Policy
- Area: `width * height > 15_500_000` (15.5 MP) → 422. Safe integer arithmetic.
- Boundary: exactly 15,500,000 pixels must PASS; 15,500,001 must FAIL. Both tested (B-7).

### §4.3 Accepted Format Contract (JPEG + WebP only — frozen)

```typescript
// Explicit alias map — covers documented short-name aliases (B-9 from Rev 4)
const FORMAT_ALIAS_MAP: Record<string, string> = {
  "jpg":        "image/jpeg",
  "jpeg":       "image/jpeg",
  "image/jpeg": "image/jpeg",
  "webp":       "image/webp",
  "image/webp": "image/webp",
};
const ACCEPTED_FORMATS = new Set(["image/jpeg", "image/webp"]);
```

The actual format string returned by Cloudflare `.info()` must be confirmed from `wrangler types` output and logged during CF-P-4. If Cloudflare returns an alias not in `FORMAT_ALIAS_MAP`, it is added during Phase 2 artifact lock.

### §4.4 Animation: `anim: false` always in `.output()`.

### §4.5 Secret Declaration and Atomic Deployment

**`wrangler.toml` (§7.1 is authoritative):**
```toml
[secrets]
required = ["SPIKE_SECRET"]
```

**Atomic deployment:** `wrangler deploy --secrets-file "$SECRETS_TMP"`. Mutation-attempt flag set immediately before the deploy call (B-6):
```bash
SECRET_OR_WORKER_CREATED=true   # set before attempt; ensures cleanup runs even on partial failure
"$WRANGLER" deploy --secrets-file "$SECRETS_TMP"
WORKER_DEPLOYED=true
```

### §4.6 Account Pinning for All Wrangler Operations (B-3)

`CLOUDFLARE_ACCOUNT_ID` is exported at runner startup and inherited by every Wrangler subprocess. This pins all Wrangler operations to the authorized account.

```bash
export CLOUDFLARE_ACCOUNT_ID="$CF_ACCOUNT_ID"
```

This is distinct from the API token verification in §2.3; it forces the Wrangler runtime into the correct account context regardless of which accounts the token can access.

### §4.7 Deploy URL Extraction via `WRANGLER_OUTPUT_FILE_PATH` (B-4)

`wrangler deploy --json` is not documented. The authorized mechanism is `WRANGLER_OUTPUT_FILE_PATH`, which causes Wrangler to write structured JSONL deploy events to a file. The deploy event's `targets[0]` contains the Worker URL.

```bash
WRANGLER_OUT=$(mktemp)
WRANGLER_OUTPUT_FILE_PATH="$WRANGLER_OUT" \
  "$WRANGLER" deploy --secrets-file "$SECRETS_TMP"
# Parse JSONL for the deploy event
WORKER_URL=$(jq -r 'select(.type == "deploy") | .targets[0].url // empty' "$WRANGLER_OUT" \
  | head -1)
rm -f "$WRANGLER_OUT"
[ -n "$WORKER_URL" ] \
  || { echo "FAIL: Could not extract Worker URL from WRANGLER_OUTPUT_FILE_PATH output"; exit 1; }
```

If `WRANGLER_OUTPUT_FILE_PATH` or the `targets[0].url` schema is not confirmed during `--help` verification in Phase 1, this mechanism must be replaced with a documented alternative before Phase 2 sign-off.

### §4.8 Wrangler Version and Command Verification

Pin version: `npm install --save-dev wrangler@<pinned>`. Use `./node_modules/.bin/wrangler` throughout. Export `CLOUDFLARE_ACCOUNT_ID` before every invocation.

Commands requiring `--help` verification (all must be confirmed before Phase 2 sign-off):

| Command | Notes |
|---------|-------|
| `wrangler init` (and flags) | If no suitable init flags: scaffold manually |
| `wrangler types` | Must generate `worker-configuration.d.ts` |
| `wrangler dev --remote` | Verify `preview_bucket_name` support |
| `wrangler deploy --secrets-file` | Verify flag exists in pinned version |
| `WRANGLER_OUTPUT_FILE_PATH` | Verify env var and JSONL schema |
| `wrangler delete` | Verify `--force` flag |
| `wrangler r2 bucket create/delete` | — |
| `wrangler r2 bucket list` | Verify `--json` flag; if absent, use CF API |
| `wrangler r2 bucket dev-url get` | — |
| `wrangler r2 object put/get/delete` | `r2 object list` is NOT supported |
| `wrangler whoami` | — |

Worker existence is verified via the Cloudflare Workers API (not `deployments list` — see §6.0 helpers).

---

## §5 Unit Test Coverage (`src/index.test.ts`) — Required before Phase 2

Full Vitest matrix using Workers Vitest integration. All tests use injected mocks — no cloud calls.

### §5.1 ETag Race — Read 2 conditional miss → 409, no info/put call

```typescript
it("returns 409 when Read 2 gets metadata-only (no body)", async () => {
  let call = 0;
  const mockGet = vi.fn(async () => {
    call++;
    if (call === 1) return { body: new ReadableStream(), etag: "a", size: 500_000 };
    return { etag: "b", size: 500_000 }; // no 'body' key
  });
  const mockInfo = vi.fn(); const mockPut = vi.fn();
  const resp = await invoke({ BUCKET: { head: vi.fn(async () => ({ etag:"a", size:500_000 })), get: mockGet, put: mockPut }, IMAGES: { info: mockInfo, input: vi.fn() } }, "/transform/test.jpg");
  expect(resp.status).toBe(409);
  expect(mockInfo).not.toHaveBeenCalled();
  expect(mockPut).not.toHaveBeenCalled();
});
```

### §5.2 ETag Race — Read 3 conditional miss → 409, no IMAGES.input/put call

```typescript
it("returns 409 when Read 3 gets metadata-only", async () => {
  let call = 0;
  const mockGet = vi.fn(async () => {
    call++;
    if (call <= 2) return { body: new ReadableStream(), etag: "a", size: 500_000 };
    return { etag: "b", size: 500_000 };
  });
  const mockInfo  = vi.fn(async () => ({ format: "jpeg", width: 800, height: 600 }));
  const mockInput = vi.fn(); const mockPut = vi.fn();
  const resp = await invoke({ BUCKET: { head: vi.fn(async () => ({ etag:"a", size:500_000 })), get: mockGet, put: mockPut }, IMAGES: { info: mockInfo, input: mockInput } }, "/transform/test.jpg");
  expect(resp.status).toBe(409);
  expect(mockInput).not.toHaveBeenCalled();
  expect(mockPut).not.toHaveBeenCalled();
});
```

### §5.3 Authorization

```typescript
it("returns 401 for missing Authorization header", ...);
it("returns 401 for wrong token", ...);
it("returns 200 for /health without Authorization", ...);
```

### §5.4 Format aliases and rejection

```typescript
// Format alias acceptance
for (const alias of ["jpeg", "jpg", "image/jpeg", "webp", "image/webp"]) {
  it(`accepts format alias "${alias}"`, ...);
}
// Format rejection — no IMAGES.input() or BUCKET.put() called
for (const fmt of ["png", "image/png", "heic", "avif", "gif", "tiff"]) {
  it(`rejects format "${fmt}" without transform`, ...);
  it(`does not call BUCKET.put() for format "${fmt}"`, ...);
}
```

### §5.5 Size boundary (B-7 extension)

```typescript
it("accepts input at exactly 10,485,760 bytes (10 MB)", ...);    // PASS
it("rejects input at 10,485,761 bytes (10 MB + 1)", ...);         // 422, no transform
it("does not call BUCKET.put() for oversized input", ...);
```

### §5.6 Pixel area boundary (B-7)

```typescript
it("accepts image at exactly 15,500,000 pixels (e.g. 3100×5000)", ...);  // PASS
it("rejects image at 15,500,001 pixels (e.g. 3101×5000)", ...);          // 422
it("does not call BUCKET.put() for over-area input", ...);
```

### §5.7 Output size boundary

```typescript
it("rejects transform output at 5,242,881 bytes (5 MB + 1)", ...);  // 422
it("does not call BUCKET.put() for over-ceiling output", ...);
it("accepts transform output at exactly 5,242,880 bytes", ...);      // PASS
```

### §5.8 Transform failure

```typescript
it("returns 500 when IMAGES.input() throws", ...);
it("does not call BUCKET.put() when transform throws", ...);
it("returns 502 when transform returns non-OK status", ...);
it("returns 502 when transform returns wrong Content-Type", ...);
```

### §5.9 No-write guarantees

```typescript
// For every non-200 path, verify BUCKET.put() was not called:
// 401, 400 (bad key), 404, 409, 422 (size/format/pixel/output), 500, 502
```

---

## §6 Probe Sequence

**Execution order:** §6.0 → CF-P-1 → CF-P-2 → CF-P-3 → CF-P-4 → CF-P-5 → CF-P-6 → CF-P-7 → CF-P-9 → **CF-P-8** (gate) → CF-P-10 → CF-P-11 → CF-P-12.

CF-P-8 gates on recorded CPU evidence before continuing.

---

### §6.0 — Runner Preflight and EXIT Trap

```bash
#!/usr/bin/env bash
set -euo pipefail

# ── Configuration ──────────────────────────────────────────────────────────────
CF_ACCOUNT_ID="1dd6ede816fa36a5a824a6e21f82ad7b"
CPU_LIMIT_MS=10      # set from CF-P-0b — override with actual plan limit
BUCKET="forkensics-dev-spike"
WORKER="forkensics-image-spike"
WRANGLER="./node_modules/.bin/wrangler"
SECRETS_TMP=$(mktemp)
WRANGLER_OUT=$(mktemp)

# Pin all Wrangler operations to the authorized account (B-3)
export CLOUDFLARE_ACCOUNT_ID="$CF_ACCOUNT_ID"

# ── Mutation-attempt flags — set BEFORE or unconditionally after attempts (B-6) ─
BUCKET_CREATED=false
SECRET_OR_WORKER_CREATED=false
WORKER_DEPLOYED=false
DEV_PID=""
WORKER_URL=""

# ── Three-state verifier helpers ───────────────────────────────────────────────

# key_status: "exists" | "absent" | stops runner on operational failure
key_status() {
  local key="$1" err_tmp out exit_code
  err_tmp=$(mktemp)
  if "$WRANGLER" r2 object get "$BUCKET/$key" --file /dev/null \
    >"$err_tmp" 2>&1; then
    rm -f "$err_tmp"; echo "exists"; return; fi
  local err; err=$(cat "$err_tmp"); rm -f "$err_tmp"
  if echo "$err" | grep -qiE "not found|404|no such key|object not found"; then
    echo "absent"; return; fi
  echo "FAIL: key_status operational error for '$key': $err" >&2; exit 1
}
key_absent() { [ "$(key_status "$1")" = "absent" ]; }
key_exists() { [ "$(key_status "$1")" = "exists" ]; }

# worker_api_status: "exists" | "absent" | stops runner on operational failure (B-5)
worker_api_status() {
  local resp http_code body
  body=$(curl -s -w "\n%{http_code}" \
    -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
    "https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT_ID/workers/scripts/$WORKER")
  http_code=$(echo "$body" | tail -1); body=$(echo "$body" | head -n -1)
  case "$http_code" in
    200) echo "exists" ;;
    404) echo "absent" ;;
    *)   echo "FAIL: worker_api_status unexpected HTTP $http_code: $body" >&2; exit 1 ;;
  esac
}

# bucket_api_status: exact match via CF API — no substring grep (B-6, AH-3)
bucket_api_status() {
  local resp
  resp=$(curl -s -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
    "https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT_ID/r2/buckets/$BUCKET")
  case "$(echo "$resp" | jq -r '.success')" in
    true)  echo "exists" ;;
    false)
      local code; code=$(echo "$resp" | jq -r '.errors[0].code // 0')
      [ "$code" = "10006" ] && echo "absent" \
        || { echo "FAIL: bucket_api_status CF error: $resp" >&2; exit 1; }
      ;;
    *) echo "FAIL: bucket_api_status unexpected response: $resp" >&2; exit 1 ;;
  esac
}

# ── EXIT trap ──────────────────────────────────────────────────────────────────
cleanup() {
  local orig=$?; local failed=false
  echo "[CLEANUP] Starting (exit=$orig) — $(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # 1. Kill wrangler dev
  if [ -n "$DEV_PID" ] && kill -0 "$DEV_PID" 2>/dev/null; then
    kill "$DEV_PID"; wait "$DEV_PID" 2>/dev/null || true
    echo "[CLEANUP] wrangler dev terminated"; fi

  # 2. Delete temp files
  rm -f .dev.vars "$SECRETS_TMP" "$WRANGLER_OUT"

  # 3. Undeploy Worker (if any state was attempted)
  if [ "$SECRET_OR_WORKER_CREATED" = "true" ]; then
    "$WRANGLER" delete "$WORKER" --force 2>/dev/null || true
    case "$(worker_api_status)" in
      absent) echo "[CLEANUP] Worker confirmed absent" ;;
      exists) echo "[CLEANUP] WARNING: Worker still deployed"; failed=true ;;
    esac; fi

  # 4. Delete spike objects
  if [ "$BUCKET_CREATED" = "true" ]; then
    for KEY in \
      "spike/fixture-exif.jpg" \
      "spike/fixture-static-icc-xmp.webp" \
      "spike/fixture-animated.webp" \
      "spike/fixture-oversized-px.jpg" \
      "spike/fixture-oversized.jpg" \
      "display/fixture-exif.jpg.webp" \
      "display/fixture-static-icc-xmp.webp" \
      "display/fixture-animated.webp"; do
      "$WRANGLER" r2 object delete "$BUCKET/$KEY" 2>/dev/null || true
      case "$(key_status "$KEY")" in
        absent) echo "[CLEANUP] Confirmed absent: $KEY" ;;
        exists) echo "[CLEANUP] WARNING: Still present: $KEY"; failed=true ;;
      esac
    done

    # 5. Delete bucket
    "$WRANGLER" r2 bucket delete "$BUCKET" 2>/dev/null || true
    case "$(bucket_api_status)" in
      absent) BUCKET_CREATED=false; echo "[CLEANUP] Bucket confirmed absent" ;;
      exists) echo "[CLEANUP] WARNING: Bucket still present"; failed=true ;;
    esac; fi

  if [ "$failed" = "true" ]; then
    echo "[CLEANUP] Status: REMOTE_CLEANUP_REQUIRED"
    [ "$orig" -ne 0 ] && exit "$orig" || exit 1
  else
    echo "[CLEANUP] Status: REMOTE_CLEANUP_CONFIRMED"
    exit "$orig"; fi
}
trap cleanup EXIT

# ── Preflight ─────────────────────────────────────────────────────────────────
echo "=== PREFLIGHT ==="

# Placeholder guard
[ "$CF_ACCOUNT_ID" != "BILL_MUST_FILL_IN" ] \
  || { echo "FAIL: CF_ACCOUNT_ID placeholder not replaced"; exit 1; }

echo "Wrangler: $("$WRANGLER" --version)"
command -v jq       >/dev/null || { echo "FAIL: jq not installed";       exit 1; }
command -v exiftool >/dev/null || { echo "FAIL: exiftool not installed"; exit 1; }
command -v shasum   >/dev/null || { echo "FAIL: shasum not installed";   exit 1; }
command -v bc       >/dev/null || { echo "FAIL: bc not installed";       exit 1; }

[ -n "${SPIKE_SECRET:-}"         ] || { echo "FAIL: SPIKE_SECRET not set";         exit 1; }
[ -n "${CLOUDFLARE_API_TOKEN:-}" ] || { echo "FAIL: CLOUDFLARE_API_TOKEN not set"; exit 1; }
echo "Secrets: set (not printed)"

# .dev.vars gitignore check (AH-2)
git check-ignore -q .dev.vars 2>/dev/null \
  || { echo "FAIL: .dev.vars not in .gitignore — add it before proceeding"; exit 1; }

# Account verification
ACCOUNT_RESP=$(curl -s -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  "https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT_ID")
[ "$(echo "$ACCOUNT_RESP" | jq -r '.success')" = "true" ] \
  && [ "$(echo "$ACCOUNT_RESP" | jq -r '.result.id')" = "$CF_ACCOUNT_ID" ] \
  || { echo "FAIL: Account verification failed: $ACCOUNT_RESP"; exit 1; }
echo "Account verified: $CF_ACCOUNT_ID"

# No pre-existing spike resources
[ "$(bucket_api_status)" = "absent" ] \
  || { echo "FAIL: Bucket $BUCKET already exists"; exit 1; }
[ "$(worker_api_status)" = "absent" ] \
  || { echo "FAIL: Worker $WORKER already deployed"; exit 1; }

echo "Preflight passed."
```

---

### CF-P-1 — R2 Bucket Creation

```bash
echo "=== CF-P-1 ==="
"$WRANGLER" r2 bucket create "$BUCKET"
BUCKET_CREATED=true

[ "$(bucket_api_status)" = "exists" ] \
  || { echo "FAIL CF-P-1: Bucket not found after creation"; exit 1; }

# Verify public access disabled via Wrangler (additional correction)
DEV_URL_OUT=$("$WRANGLER" r2 bucket dev-url get "$BUCKET" 2>&1)
echo "$DEV_URL_OUT" | grep -qi "enabled" \
  && { echo "FAIL CF-P-1: Public dev URL is enabled"; exit 1; } || true
echo "PASS CF-P-1: Bucket created, dev URL disabled"
```

---

### CF-P-2 — Worker Scaffolding and Type Generation (local only)

```bash
echo "=== CF-P-2 ==="
"$WRANGLER" types
tsc --noEmit
```

Record from `worker-configuration.d.ts`:
- Return type of `env.IMAGES.info()` — does it include `fileSize`? If yes, use directly. If no, the fileSize consistency check is omitted from authoritative code (no `as` cast). (B-9)
- Exact format string aliases returned by Cloudflare — update `FORMAT_ALIAS_MAP` if needed.

```bash
echo "PASS CF-P-2: Types generated, zero type errors"
```

---

### CF-P-3 — Fixture Generation and Upload

**Generator must prove fixture preconditions before upload (B-8):**

```bash
echo "=== CF-P-3 ==="

# 1. Run generate-fixtures.sh which:
#    a. Creates all fixtures
#    b. PROVES each fixture meets its preconditions via exiftool + xxd checks:
#       - fixture-exif.jpg: exiftool -G1 -s shows [EXIF] and [GPS]
#       - fixture-static-icc-xmp.webp: shows [ICC_Profile] and [XMP]
#       - fixture-animated.webp: VP8X Animation flag (bit 1) set in header,
#                                 or ANIM/ANMF chunks present, or exiftool reports FrameCount > 1
#       - fixture-oversized-px.jpg: exiftool Width * Height > 15,500,000
#       - fixture-oversized.jpg: file size > 10,485,760 bytes
#    c. FAILS if any precondition is not met
./fixtures/generate-fixtures.sh

# 2. Upload all fixtures
declare -A FIXTURES=(
  ["spike/fixture-exif.jpg"]="fixtures/fixture-exif.jpg"
  ["spike/fixture-static-icc-xmp.webp"]="fixtures/fixture-static-icc-xmp.webp"
  ["spike/fixture-animated.webp"]="fixtures/fixture-animated.webp"
  ["spike/fixture-oversized-px.jpg"]="fixtures/fixture-oversized-px.jpg"
  ["spike/fixture-oversized.jpg"]="fixtures/fixture-oversized.jpg"
)
for KEY in "${!FIXTURES[@]}"; do
  LOCAL="${FIXTURES[$KEY]}"
  "$WRANGLER" r2 object put "$BUCKET/$KEY" --file "$LOCAL"
  [ "$(key_status "$KEY")" = "exists" ] \
    || { echo "FAIL CF-P-3: Key $KEY not found after upload"; exit 1; }
  echo "PASS CF-P-3: $KEY uploaded"
done
```

**Fixtures:**

| R2 key | Purpose | Precondition proof |
|--------|---------|-------------------|
| `spike/fixture-exif.jpg` | JPEG with GPS + EXIF | exiftool shows `[EXIF]` and `[GPS]` groups |
| `spike/fixture-static-icc-xmp.webp` | Static WebP with ICC + XMP | exiftool shows `[ICC_Profile]` and `[XMP]` groups |
| `spike/fixture-animated.webp` | Animated WebP (anim:false test) | ANMF chunks present or FrameCount > 1 |
| `spike/fixture-oversized-px.jpg` | ≤ 10 MB but > 15.5 MP (pixel gate) | width × height > 15,500,000 confirmed by exiftool |
| `spike/fixture-oversized.jpg` | > 10 MB (size gate) | `wc -c` > 10,485,760 |

---

### CF-P-4 — Local Transformation Test (`wrangler dev --remote`)

**Authorized cloud operation (Phase 2).**

```bash
echo "=== CF-P-4 ==="
printf 'SPIKE_SECRET=%s\n' "$SPIKE_SECRET" > .dev.vars && chmod 0600 .dev.vars

"$WRANGLER" dev --remote src/index.ts &
DEV_PID=$!

# Bounded readiness poll on /health (no auth, no R2, no IMAGES, no display write — B-3 from Rev 3)
READY=false
for i in $(seq 1 30); do
  kill -0 "$DEV_PID" 2>/dev/null || { echo "FAIL CF-P-4: wrangler dev died"; exit 1; }
  S=$(curl -s -o /dev/null -w "%{http_code}" --max-time 2 \
    http://localhost:8787/health 2>/dev/null || echo "000")
  [ "$S" = "200" ] && { READY=true; break; }
  sleep 1
done
[ "$READY" = "true" ] || { echo "FAIL CF-P-4: not ready in 30s"; exit 1; }

# ── assert_http, assert_exact_ct, assert_size_header helpers (carried from Rev 5) ──

# Test A — oversized bytes: 422, no display write
S_A=$(curl -s -o /dev/null -w "%{http_code}" --max-time 30 \
  -H "Authorization: Bearer $SPIKE_SECRET" \
  http://localhost:8787/transform/spike/fixture-oversized.jpg)
assert_http "$S_A" "422" "CF-P-4-A oversized-bytes"
[ "$(key_status "display/fixture-oversized.jpg.webp")" = "absent" ] \
  || { echo "FAIL CF-P-4-A: display key written for oversized-bytes"; exit 1; }

# Test B — oversized pixels: 422, no display write (B-7)
S_B=$(curl -s -o /dev/null -w "%{http_code}" --max-time 30 \
  -H "Authorization: Bearer $SPIKE_SECRET" \
  http://localhost:8787/transform/spike/fixture-oversized-px.jpg)
assert_http "$S_B" "422" "CF-P-4-B oversized-pixels"
[ "$(key_status "display/fixture-oversized-px.jpg.webp")" = "absent" ] \
  || { echo "FAIL CF-P-4-B: display key written for oversized-pixels"; exit 1; }

# Test C — JPEG with EXIF: 200
curl -s --max-time 60 -H "Authorization: Bearer $SPIKE_SECRET" \
  -D cf_p4_jpeg_headers.txt -o cf_p4_jpeg_output.webp \
  http://localhost:8787/transform/spike/fixture-exif.jpg
assert_http "$(grep -m1 "^HTTP" cf_p4_jpeg_headers.txt | awk '{print $2}')" \
  "200" "CF-P-4-C JPEG"
assert_exact_ct cf_p4_jpeg_headers.txt "CF-P-4-C"
assert_size_header cf_p4_jpeg_headers.txt cf_p4_jpeg_output.webp "CF-P-4-C"

# Test D — static WebP with ICC/XMP: 200 (B-4)
curl -s --max-time 60 -H "Authorization: Bearer $SPIKE_SECRET" \
  -D cf_p4_swebp_headers.txt -o cf_p4_swebp_output.webp \
  http://localhost:8787/transform/spike/fixture-static-icc-xmp.webp
assert_http "$(grep -m1 "^HTTP" cf_p4_swebp_headers.txt | awk '{print $2}')" \
  "200" "CF-P-4-D static-WebP"
assert_exact_ct cf_p4_swebp_headers.txt "CF-P-4-D"
assert_size_header cf_p4_swebp_headers.txt cf_p4_swebp_output.webp "CF-P-4-D"

# Test E — animated WebP: 200, output non-animated (B-4)
curl -s --max-time 60 -H "Authorization: Bearer $SPIKE_SECRET" \
  -D cf_p4_awebp_headers.txt -o cf_p4_awebp_output.webp \
  http://localhost:8787/transform/spike/fixture-animated.webp
assert_http "$(grep -m1 "^HTTP" cf_p4_awebp_headers.txt | awk '{print $2}')" \
  "200" "CF-P-4-E animated-WebP"
assert_exact_ct cf_p4_awebp_headers.txt "CF-P-4-E"
# Animation elimination verified in CF-P-6 (VP8X Animation flag = 0)

kill "$DEV_PID" 2>/dev/null; wait "$DEV_PID" 2>/dev/null || true; DEV_PID=""
rm -f .dev.vars
echo "PASS CF-P-4: All local tests passed"
```

---

### CF-P-5 — Metadata Stripping Verification

```bash
echo "=== CF-P-5 ==="
for F in cf_p4_jpeg_output.webp cf_p4_swebp_output.webp cf_p4_awebp_output.webp; do
  exiftool -G1 -s "$F" > "cf_p5_$(basename $F .webp).txt"
  cat "cf_p5_$(basename $F .webp).txt"
  for G in EXIF XMP ICC_Profile IFD0 ExifIFD GPS; do
    grep -q "^\[${G}\]" "cf_p5_$(basename $F .webp).txt" \
      && { echo "FAIL CF-P-5: Prohibited group [$G] in $F"; exit 1; }
  done
  echo "PASS CF-P-5: No prohibited metadata in $F"
done
```

---

### CF-P-6 — Output WebP Structural Verification

Applied to all three transformed outputs plus the animated-WebP output (must have Animation flag = 0):

1. RIFF header bytes 0–3 = `52 49 46 46`; bytes 8–11 = `57 45 42 50`.
2. Exact size: `actual_file_size == riff_size + 8`.
3. Valid chunk sequence (one of five). ALPH+VP8L forbidden.
4. VP8X flags: `(flags_u32 & ~0x00000010) === 0`. Animation (`0x02`) must be zero — verified in animated-WebP output to confirm `anim:false` enforcement.

---

### CF-P-7 — SHA-256 Integrity

All three local outputs and their corresponding header `X-Forkensics-SHA256` values must match.

---

### CF-P-9 — Hosted Worker Deploy

```bash
echo "=== CF-P-9 ==="
printf 'SPIKE_SECRET=%s\n' "$SPIKE_SECRET" > "$SECRETS_TMP" && chmod 0600 "$SECRETS_TMP"

# Set flag before attempt (B-6)
SECRET_OR_WORKER_CREATED=true
WRANGLER_OUTPUT_FILE_PATH="$WRANGLER_OUT" \
  "$WRANGLER" deploy --secrets-file "$SECRETS_TMP"
WORKER_DEPLOYED=true
rm -f "$SECRETS_TMP"

# Extract Worker URL from JSONL output (B-4, §4.7)
WORKER_URL=$(jq -r 'select(.type == "deploy") | .targets[0].url // empty' "$WRANGLER_OUT" \
  | head -1)
rm -f "$WRANGLER_OUT"
[ -n "$WORKER_URL" ] \
  || { echo "FAIL CF-P-9: Worker URL not found in WRANGLER_OUTPUT_FILE_PATH output"; exit 1; }
echo "Worker URL: $WORKER_URL"

[ "$(worker_api_status)" = "exists" ] \
  || { echo "FAIL CF-P-9: Worker not found via API after deploy"; exit 1; }

# Hosted JPEG test
curl -s --max-time 60 -H "Authorization: Bearer $SPIKE_SECRET" \
  -D cf_p9_headers.txt -o cf_p9_output.webp "${WORKER_URL}/transform/spike/fixture-exif.jpg"
assert_http "$(grep -m1 "^HTTP" cf_p9_headers.txt | awk '{print $2}')" "200" "CF-P-9"
assert_exact_ct cf_p9_headers.txt "CF-P-9"
assert_size_header cf_p9_headers.txt cf_p9_output.webp "CF-P-9"
SHA_P9=$(grep -i "^x-forkensics-sha256:" cf_p9_headers.txt | head -1 \
  | awk '{print $2}' | tr -d '[:space:]')
[ "$(shasum -a 256 cf_p9_output.webp | awk '{print $1}')" = "$SHA_P9" ] \
  || { echo "FAIL CF-P-9: SHA mismatch"; exit 1; }
echo "PASS CF-P-9: Hosted transform confirmed"
```

---

### CF-P-8 — Worker CPU Budget Gate (executes after CF-P-9) (B-10)

CF-P-8 pauses for the operator to record CPU analytics from the Cloudflare Dashboard and enforces the threshold before continuing. Missing, delayed, or ambiguous analytics produce INCONCLUSIVE/FAIL — not PASS.

```bash
echo "=== CF-P-8 ==="
echo "[CF-P-8] Open: dash.cloudflare.com/$CF_ACCOUNT_ID/workers/services/view/$WORKER/production/metrics"
echo "[CF-P-8] Find the CPU time per invocation for the CF-P-9 JPEG request."
echo "[CF-P-8] If analytics are not yet available (propagation delay), wait up to 5 minutes."
echo "[CF-P-8] If analytics are still unavailable after 5 minutes, enter 'INCONCLUSIVE'."
echo "[CF-P-8] Enter observed CPU time in milliseconds (number) or 'INCONCLUSIVE':"
read -r CPU_MS_INPUT

if [ "$CPU_MS_INPUT" = "INCONCLUSIVE" ]; then
  echo "FAIL CF-P-8: Analytics unavailable — INCONCLUSIVE prevents PASS"; exit 1; fi

# Validate numeric input
[[ "$CPU_MS_INPUT" =~ ^[0-9]+(\.[0-9]+)?$ ]] \
  || { echo "FAIL CF-P-8: Non-numeric input '$CPU_MS_INPUT'"; exit 1; }

if (( $(echo "$CPU_MS_INPUT < $CPU_LIMIT_MS" | bc -l) )); then
  echo "PASS CF-P-8: CPU $CPU_MS_INPUT ms < plan limit $CPU_LIMIT_MS ms"
else
  echo "FAIL CF-P-8: CPU $CPU_MS_INPUT ms >= plan limit $CPU_LIMIT_MS ms (Error 1102 risk)"
  exit 1
fi
```

---

### CF-P-10 — Auth Boundary

```bash
echo "=== CF-P-10 ==="
S_NO=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
  "${WORKER_URL}/transform/spike/fixture-exif.jpg")
assert_http "$S_NO" "401" "CF-P-10 no-auth"
S_WR=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
  -H "Authorization: Bearer wrongtoken" "${WORKER_URL}/transform/spike/fixture-exif.jpg")
assert_http "$S_WR" "401" "CF-P-10 wrong-token"
echo "PASS CF-P-10"
```

---

### CF-P-11 — Write-Back Persistence Verification

```bash
echo "=== CF-P-11 ==="
[ "$(key_status "display/fixture-exif.jpg.webp")" = "exists" ] \
  || { echo "FAIL CF-P-11: JPEG display key absent"; exit 1; }
"$WRANGLER" r2 object get "$BUCKET/display/fixture-exif.jpg.webp" --file cf_p11_verify.webp
[ "$(shasum -a 256 cf_p11_verify.webp | awk '{print $1}')" = "$SHA_P9" ] \
  || { echo "FAIL CF-P-11: SHA mismatch"; exit 1; }
echo "PASS CF-P-11"
```

---

### CF-P-12 — Cleanup

```bash
echo "=== CF-P-12 ==="
"$WRANGLER" delete "$WORKER" --force
[ "$(worker_api_status)" = "absent" ] \
  || { echo "FAIL CF-P-12: Worker still deployed"; exit 1; }
WORKER_DEPLOYED=false; SECRET_OR_WORKER_CREATED=false

for KEY in \
  "spike/fixture-exif.jpg" "spike/fixture-static-icc-xmp.webp" \
  "spike/fixture-animated.webp" "spike/fixture-oversized-px.jpg" \
  "spike/fixture-oversized.jpg" \
  "display/fixture-exif.jpg.webp" "display/fixture-static-icc-xmp.webp" \
  "display/fixture-animated.webp"; do
  "$WRANGLER" r2 object delete "$BUCKET/$KEY" 2>/dev/null || true
  [ "$(key_status "$KEY")" = "absent" ] \
    || { echo "FAIL CF-P-12: Key $KEY still present"; exit 1; }
done

"$WRANGLER" r2 bucket delete "$BUCKET"
[ "$(bucket_api_status)" = "absent" ] \
  || { echo "FAIL CF-P-12: Bucket still present"; exit 1; }
BUCKET_CREATED=false
echo "PASS CF-P-12: REMOTE_CLEANUP_CONFIRMED"
```

---

## §7 Authoritative Artifacts

### §7.1 `wrangler.toml`

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

[secrets]
required = ["SPIKE_SECRET"]
```

### §7.2 `src/index.ts`

```typescript
// src/index.ts — forkensics-image-spike Rev 6 — SPIKE ONLY

const FORMAT_ALIAS_MAP: Record<string, string> = {
  "jpg":        "image/jpeg",
  "jpeg":       "image/jpeg",
  "image/jpeg": "image/jpeg",
  "webp":       "image/webp",
  "image/webp": "image/webp",
};
const ACCEPTED_FORMATS = new Set(["image/jpeg", "image/webp"]);
const MAX_INPUT_BYTES  = 10 * 1024 * 1024;
const MAX_OUTPUT_BYTES =  5 * 1024 * 1024;
const MAX_PIXELS       = 15_500_000;

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname === "/health") return new Response("ok", { status: 200 });

    if (request.headers.get("Authorization") !== `Bearer ${env.SPIKE_SECRET}`) {
      return new Response("Unauthorized", { status: 401 });
    }

    const key = url.pathname.replace(/^\/transform\//, "").trim();
    if (!key || key.includes("..") || key.startsWith("/")) {
      return new Response("Invalid key", { status: 400 });
    }

    // Read 1: head-only — no body stream opened (AH-1)
    const head = await env.BUCKET.head(key);
    if (!head) return new Response("Not found", { status: 404 });
    const etag = head.etag;
    if (head.size > MAX_INPUT_BYTES) {
      return new Response(`Input too large: ${head.size}`, { status: 422 });
    }

    // Read 2: conditional get — .info() free
    const infoObject = await env.BUCKET.get(key, { onlyIf: { etagMatches: etag } });
    if (!infoObject || !("body" in infoObject) || !infoObject.body) {
      return new Response("Input changed between reads", { status: 409 });
    }
    // Use inferred type from generated Env — no `as` assertion (B-9)
    const info = await env.IMAGES.info(infoObject.body);
    console.log(`info.format raw: ${JSON.stringify(info.format)}`);

    const normalizedFormat = FORMAT_ALIAS_MAP[String(info.format).toLowerCase()] ?? null;
    if (!normalizedFormat || !ACCEPTED_FORMATS.has(normalizedFormat)) {
      return new Response(`Unsupported format: ${info.format}`, { status: 422 });
    }
    if (info.width * info.height > MAX_PIXELS) {
      return new Response(`Pixel area ${info.width * info.height} > ${MAX_PIXELS}`, { status: 422 });
    }
    // fileSize check: use generated type field directly if present; no cast (B-9)
    // If wrangler types does not include fileSize, this block is removed entirely.
    // Phase 2 artifact lock confirms whether this block is present or absent.
    // [fileSize check placeholder — resolved during Phase 2]

    // Read 3: conditional get — transform
    const transformObject = await env.BUCKET.get(key, { onlyIf: { etagMatches: etag } });
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
      return new Response(`Transform non-OK: ${transformResponse.status}`, { status: 502 });
    }
    const ct = (transformResponse.headers.get("Content-Type") ?? "").split(";")[0].trim();
    if (ct !== "image/webp") {
      return new Response(`Unexpected Content-Type: ${ct}`, { status: 502 });
    }
    if (!transformResponse.body) return new Response("Empty body", { status: 502 });

    // Bounded stream read
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
    for (const c of chunks) { out.set(c, off); off += c.byteLength; }

    const hashHex = Array.from(
      new Uint8Array(await crypto.subtle.digest("SHA-256", out))
    ).map((b) => b.toString(16).padStart(2, "0")).join("");

    const displayKey = `display/${key.split("/").pop()!}.webp`;
    await env.BUCKET.put(displayKey, out, { httpMetadata: { contentType: "image/webp" } });

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

---

## §8 Verdict Criteria

| Tier | Condition | Meaning |
|------|-----------|---------|
| **PASS** | All probes pass, `REMOTE_CLEANUP_CONFIRMED` | Architecture viable. Proceed to production. |
| **INCONCLUSIVE** | CF-P-8 analytics unavailable | Cannot confirm CPU budget. Not a PASS. |
| **FAIL** | Any probe FAIL | Stop. Document. Evaluate Fallback Rank 2. |
| **CLEANUP NOTE** | `REMOTE_CLEANUP_REQUIRED` | Manual verification needed. |

---

## §9 Open Questions

| # | Question | Owner |
|---|----------|-------|
| OQ-1 | Production upload: presign to R2 directly or `upload-authorize` proxies PUT? | Bill |
| OQ-2 | Display key: deterministic or UUID? | Bill |
| OQ-3 | Production Worker auth: CF service token or HMAC-SHA256? | Bill + Codex |
| OQ-4 | Per-side dimension limit in addition to 15.5 MP area? | Bill |

---

## §10 Blocker Resolution Table (Rev 5 → Rev 6)

| # | Rev 5 Blocker | Resolution |
|---|--------------|------------|
| B-1 | Account ID placeholder | **RESOLVED** — `1dd6ede816fa36a5a824a6e21f82ad7b` (from Dashboard URL 2026-08-15) |
| B-2 | Phase 1 contradiction ("no code edit" vs. "draft artifacts") | §1.2 Phase 1 explicitly lists authorized local artifact creation; prohibits cloud operations |
| B-3 | Wrangler not pinned to account | `export CLOUDFLARE_ACCOUNT_ID="$CF_ACCOUNT_ID"` at runner startup; inherited by all Wrangler subprocesses |
| B-4 | `wrangler deploy --json` unsupported | `WRANGLER_OUTPUT_FILE_PATH` + `jq 'select(.type=="deploy") \| .targets[0].url'` |
| B-5 | `worker_deployed()` unreliable | `worker_api_status()` uses Workers API `GET /workers/scripts/{name}`; distinguishes 200/404/other |
| B-6 | Cleanup fails open; flags set after success only | `SECRET_OR_WORKER_CREATED=true` set before deploy attempt; all verifiers are three-state; errors stop runner; no `2>/dev/null` on verifiers |
| B-7 | 15.5 MP policy untested | `fixture-oversized-px.jpg`: ≤ 10 MB but > 15.5 MP; Tests A/B in CF-P-4; exact boundary in Vitest §5.6 |
| B-8 | Fixture preconditions not proven | `generate-fixtures.sh` verifies each fixture via exiftool/xxd before upload; aborts if precondition unmet |
| B-9 | `as` casts bypass generated type | No `as` assertions; inferred type used directly; fileSize block noted as conditional on generated types |
| B-10 | CF-P-8 informational | `read -r CPU_MS_INPUT`; validates numeric or `INCONCLUSIVE`; enforces threshold; `INCONCLUSIVE` → FAIL |
| AH-1 | Read 1 opens unused body stream | `env.BUCKET.head(key)` for Read 1; only Reads 2 and 3 open body streams |
| AH-2 | `.dev.vars` not gitignore-verified | Preflight: `git check-ignore -q .dev.vars` — fails if not ignored |
| AH-3 | Bucket list uses substring `grep -qF` | `bucket_api_status()` uses CF API `GET /r2/buckets/{name}` with exact error-code match |
| AH-4 | Vitest matrix too narrow | §5 expands to: ETag races, auth, format aliases, format rejection, size/pixel/output boundaries, transform failures, no-write guarantees |

---

*Proposal Rev 6 — 2026-08-15 — awaiting Bill to insert CF_ACCOUNT_ID, then §1.2 Phase 1 three-party sign-off*
