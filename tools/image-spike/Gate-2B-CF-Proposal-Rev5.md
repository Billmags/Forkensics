# Gate 2B — Cloudflare R2 + Images Binding Feasibility Spike
## Proposal Rev 5 — 2026-08-15

**Supersedes:** Rev 4 (not approved — 9 blockers, Codex SHA-256 `843ac4bd259a93744771bb22c65d6a9ea2582d3d0a734cf08b8a4001ce55c1ad`)

---

## §1 Governance

### §1.1 Security Constraints (permanent — cannot be overridden)

- `CLOUDFLARE_API_TOKEN`, `SPIKE_SECRET`, and any Cloudflare credential: never in client code, never in the repo, never sent to Claude.
- `ANON_KEY` and `SERVICE_ROLE_KEY`: runtime environment variables only; never written to any file, echoed, or logged.
- Three-party governance: **Bill + Claude + Codex** must approve each phase before authorized operations begin.
- Authorized Supabase project: `hkfrbdpedrxmbsawnbpr` (forkensics-dev ONLY).
- **Authorized Cloudflare account ID: `⟨BILL_MUST_FILL_IN⟩`** — Bill replaces this literal string with the verified account ID before Rev 5 is submitted for Phase 1 sign-off. The runner aborts if the literal `⟨BILL_MUST_FILL_IN⟩` string is still present. A proposal containing this placeholder is not approvable. (B-1)
- All spike resources use the suffix `-spike` and are removed at CF-P-12.

### §1.2 Two-Phase Authorization

#### Phase 1 — Proposal sign-off

Authorizes: reviewing this document, CF-P-0b read-only check, Wrangler `--help` verification, and drafting all Phase 2 artifacts. Does **not** authorize any cloud operation or code edit.

| Party | Status | Note |
|-------|--------|------|
| Claude | ⬜ pending | |
| Codex | ⬜ pending | |
| Bill | ⬜ pending | |

#### Phase 2 — Artifact lock and execution authorization

Phase 2 sign-off requires all of the following before any cloud operation:

1. Final artifacts — every file below exists, is frozen, and has a recorded SHA-256:

| Artifact | SHA-256 | Status |
|----------|---------|--------|
| `src/index.ts` | ⬜ pending | |
| `src/index.test.ts` | ⬜ pending | |
| `wrangler.toml` | ⬜ pending | |
| `run-spike.sh` | ⬜ pending | |
| `fixtures/generate-fixtures.sh` | ⬜ pending | |
| `parser/verify-webp.sh` | ⬜ pending | |

2. Static-check evidence: `tsc --noEmit` exits 0, zero errors.
3. Local unit-test evidence: Vitest suite passes (including ETag race test — §5.0 unit coverage).
4. Wrangler command `--help` verification complete for all commands in §4.8.

| Party | Status | Note |
|-------|--------|------|
| Claude | ⬜ pending | |
| Codex | ⬜ pending | |
| Bill | ⬜ pending | |

No cloud operation begins until the Phase 2 table is fully ✅.

### §1.3 CF-P-0 Activation — Reconciliation

Images & Stream plan activated 2026-08-15 by Bill at $0/month, no hosted storage selected. Zero-dollar configuration action. No Worker deployed, no bucket created, no transformation called. Recorded as an already-completed prerequisite.

---

## §2 Context

### §2.1 Why This Proposal Exists

Gate 2B Rev 15: HTTP 546 (Supabase-specific pre-handler resource exhaustion). Gate 2B Rev 20: P-0 BLOCKED (Supabase Free plan excludes managed transformations). This proposal tests Fallback Rank 1: **Cloudflare R2 + Images binding**.

### §2.2 CF-P-0 — Images Plan Eligibility (COMPLETE — PASS, 2026-08-15)

| Check | Result |
|-------|--------|
| Images & Stream | ✅ $0/month, activated by Bill 2026-08-15 |
| R2 binding on free tier | ✅ Confirmed — Cloudflare docs 2026-07-08 |
| Free quota | 5,000 unique transformations/month; spike consumes ≤ 20 |
| Existing R2 bucket | None — CF-P-1 |

### §2.3 CF-P-0b — Workers Plan Eligibility (Phase 1 read-only step)

Cloudflare resource exhaustion is **Error 1102** (not HTTP 546).

| Plan | CPU limit | Notes |
|------|-----------|-------|
| Free | **10 ms** | Hard limit; Error 1102 on exceed |
| Paid ($5/month) | **30 s default**, up to **5 min** via `cpu_ms` in `wrangler.toml` | |

**Authorized read-only action:** Dashboard → Workers & Pages → Overview. Record plan and `cpu_ms`.

**Account verification** (additional correction — replaces `/user/tokens/verify`):
```bash
ACCOUNT_RESP=$(curl -s -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  "https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT_ID")
CF_API_SUCCESS=$(echo "$ACCOUNT_RESP" | jq -r '.success')
CF_API_ID=$(echo "$ACCOUNT_RESP" | jq -r '.result.id // empty')
[ "$CF_API_SUCCESS" = "true" ] && [ "$CF_API_ID" = "$CF_ACCOUNT_ID" ] \
  || { echo "FAIL: Account verification failed"; exit 1; }
```

**Minimum API token scopes:**

| Scope | Required for |
|-------|-------------|
| Workers Scripts:Edit | `wrangler deploy`, `wrangler delete` |
| Workers Scripts:Read | Deployment list |
| R2:Edit | Bucket create/delete, object put/delete |
| R2:Read | Object get |
| Account Settings:Read | Account details verification |

---

## §3 Architecture

### §3.1 Target Pipeline

```
iPhone → presigned PUT → Private R2 (originals)
  → Cloudflare Worker
      GET /health → 200 (no R2, no IMAGES)
      auth boundary
      Read 1: R2 get → ETag + size gate (>10 MB → 422)
      Read 2: R2 get (ETag-matched) → IMAGES.info() [free]
        → format gate (JPEG/WebP only, alias-mapped)
        → area gate (width×height > 15.5 MP → 422)
        → fileSize consistency (if exposed)
      Read 3: R2 get (ETag-matched) → IMAGES.transform().output(anim:false)
        → validate response (status, exact Content-Type, nonempty body)
        → bounded stream read (≤5 MB+1)
        → SHA-256
        → R2 put display/{basename}.webp
        → return 200
  → Supabase Edge Function: upload-finalize (future)
```

### §3.2 Scope

Worker: `forkensics-image-spike`. Bucket: `forkensics-dev-spike`. No production resources. Cleaned up at CF-P-12.

---

## §4 Constraints

### §4.1 Input / Output Limits
- Input: `object.size > 10 MB` → 422 before any billable call.
- Output: ≤ 5 MB enforced via bounded stream read before R2 write.

### §4.2 Pixel Policy
- Area: `width * height > 15_500_000` (15.5 MP) → 422. Safe integer arithmetic.

### §4.3 Accepted Format Contract (JPEG + WebP only — frozen)

Cloudflare `.info()` may return short aliases (`"jpg"`, `"jpeg"`, `"webp"`) or full MIME types. The Worker uses an explicit alias map — simple prefixing produces `"image/jpg"` which is outside the frozen contract. (B-9)

```typescript
const FORMAT_ALIAS_MAP: Record<string, string> = {
  "jpg":        "image/jpeg",
  "jpeg":       "image/jpeg",
  "image/jpeg": "image/jpeg",
  "webp":       "image/webp",
  "image/webp": "image/webp",
};

// Accepted after alias resolution — frozen MIME contract (B-2, B-4)
const ACCEPTED_FORMATS = new Set(["image/jpeg", "image/webp"]);
```

### §4.4 Animation Policy
`anim: false` always set in `.output()`. Not dependent on `.info()` response shape.

### §4.5 Metadata Stripping — Proven at byte level.

### §4.6 Production Auth
Spike: `SPIKE_SECRET` (random, one-time). Production: CF service token or HMAC-SHA256 with replay protection (OQ-3). Supabase service-role JWT never transmitted to Cloudflare.

### §4.7 Secret Declaration and Atomic Deployment (B-3, B-6)

**`wrangler.toml` (authoritative):**
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

**Atomic first deployment (B-3, B-6):**
```bash
# Write secrets file (mode 0600, deleted by EXIT trap)
printf 'SPIKE_SECRET=%s\n' "$SPIKE_SECRET" > "$SECRETS_TMP"
chmod 0600 "$SECRETS_TMP"
# Deploy Worker and provision secret atomically
"$WRANGLER" deploy --secrets-file "$SECRETS_TMP"
SECRET_OR_WORKER_CREATED=true   # set immediately after any command creating Worker state (B-6)
WORKER_DEPLOYED=true
rm -f "$SECRETS_TMP"
```

`SECRET_OR_WORKER_CREATED` is tracked separately because `wrangler secret put` (if used alone) can create remote state before `WORKER_DEPLOYED=true`. Using `--secrets-file` makes them atomic but the flag is still set immediately after the deploy command returns, before any verification.

### §4.8 Wrangler Version and Command Verification

- Pin a specific version: `npm install --save-dev wrangler@<pinned>`. Use `./node_modules/.bin/wrangler` throughout.
- Run `--help` for every command before Phase 2 execution.
- `wrangler r2 object list` is not a supported command (confirmed Rev 3 blocker). Object existence is verified key-by-key via `key_status()` helper (§5.0).
- Worker URL captured from `wrangler deploy --json` output, not constructed from account ID (B-8).

**Commands requiring `--help` verification:**
`wrangler init`, `wrangler types`, `wrangler dev --remote`, `wrangler deploy --secrets-file`, `wrangler delete`, `wrangler deployments list`, `wrangler r2 bucket create/list/delete`, `wrangler r2 bucket dev-url get`, `wrangler r2 object put/get/delete`, `wrangler whoami`.

---

## §5 Unit Test Coverage (Phase 2 artifact — required before execution)

### §5.0 ETag Race Unit Test (Workers Vitest) (B-7)

This is **mandatory** Phase 2 unit coverage. The ETag race test cannot be run as a hosted integration test (no sleep/debug endpoint). It uses the Workers Vitest integration with an injected R2 stub.

```typescript
// src/index.test.ts
import { createExecutionContext, waitOnExecutionContext } from "cloudflare:test";
import { describe, it, expect, vi, beforeEach } from "vitest";
import worker from "./index";

describe("ETag race condition — Read 2 conditional miss", () => {
  it("returns 409 and does not call IMAGES.info() or BUCKET.put()", async () => {
    const mockBody = new ReadableStream();
    const mockObject1 = { body: mockBody, etag: "etag-a", size: 500_000 };
    // Conditional miss: R2 returns metadata-only object (no body property) (B-4)
    const mockObjectMetaOnly = { etag: "etag-b", size: 500_000 }; // no 'body' key

    let getCallCount = 0;
    const mockGet = vi.fn(async () => {
      getCallCount++;
      if (getCallCount === 1) return mockObject1;
      return mockObjectMetaOnly; // Read 2 returns metadata-only
    });
    const mockInfo = vi.fn();
    const mockPut  = vi.fn();

    const testEnv = {
      BUCKET: { get: mockGet, put: mockPut },
      IMAGES: { info: mockInfo, input: vi.fn() },
      SPIKE_SECRET: "test-secret",
    };

    const req = new Request("http://localhost/transform/spike/test.jpg", {
      headers: { Authorization: "Bearer test-secret" },
    });
    const ctx = createExecutionContext();
    const resp = await worker.fetch(req, testEnv as unknown as Env, ctx);
    await waitOnExecutionContext(ctx);

    expect(resp.status).toBe(409);
    expect(mockInfo).not.toHaveBeenCalled();
    expect(mockPut).not.toHaveBeenCalled();
  });
});

describe("ETag race condition — Read 3 conditional miss", () => {
  it("returns 409 after info() succeeds, does not call IMAGES.input() or BUCKET.put()", async () => {
    const mockObject1     = { body: new ReadableStream(), etag: "etag-a", size: 500_000 };
    const mockObjectInfo  = { body: new ReadableStream(), etag: "etag-a", size: 500_000 };
    const mockObjectMetaOnly = { etag: "etag-b", size: 500_000 }; // no 'body' — Read 3 miss

    let getCallCount = 0;
    const mockGet = vi.fn(async () => {
      getCallCount++;
      if (getCallCount === 1) return mockObject1;
      if (getCallCount === 2) return mockObjectInfo;
      return mockObjectMetaOnly; // Read 3 returns metadata-only
    });
    const mockInfo  = vi.fn(async () => ({ format: "jpeg", width: 800, height: 600 }));
    const mockInput = vi.fn();
    const mockPut   = vi.fn();

    const testEnv = {
      BUCKET: { get: mockGet, put: mockPut },
      IMAGES: { info: mockInfo, input: mockInput },
      SPIKE_SECRET: "test-secret",
    };

    const req = new Request("http://localhost/transform/spike/test.jpg", {
      headers: { Authorization: "Bearer test-secret" },
    });
    const ctx = createExecutionContext();
    const resp = await worker.fetch(req, testEnv as unknown as Env, ctx);
    await waitOnExecutionContext(ctx);

    expect(resp.status).toBe(409);
    expect(mockInput).not.toHaveBeenCalled();
    expect(mockPut).not.toHaveBeenCalled();
  });
});
```

---

## §6 Probe Sequence

**Execution order:** §6.0 Preflight → CF-P-1 → CF-P-2 → CF-P-3 → CF-P-4 → CF-P-5 → CF-P-6 → CF-P-7 → CF-P-9 → CF-P-8 → CF-P-10 → CF-P-11 → CF-P-12.

CF-P-8 executes after CF-P-9 because definitive CPU evidence is hosted Worker analytics. (B-8)

---

### §6.0 — Runner Preflight and EXIT Trap

```bash
#!/usr/bin/env bash
set -euo pipefail

CF_ACCOUNT_ID="⟨BILL_MUST_FILL_IN⟩"    # §1.1 — proposal not approvable until replaced
BUCKET="forkensics-dev-spike"
WORKER="forkensics-image-spike"
WRANGLER="./node_modules/.bin/wrangler"
SECRETS_TMP=$(mktemp)

# Resource tracking — flags stay true until absence is independently confirmed (B-6)
BUCKET_CREATED=false
SECRET_OR_WORKER_CREATED=false
WORKER_DEPLOYED=false
DEV_PID=""
WORKER_URL=""

# ── Helpers ──────────────────────────────────────────────────────────────────

assert_http() {
  local actual="$1" expected="$2" label="$3"
  if [ "$actual" != "$expected" ]; then
    echo "FAIL [$label]: expected HTTP $expected, got $actual"; exit 1; fi
  echo "PASS [$label]: HTTP $actual"
}

assert_exact_ct() {
  # Assert exact Content-Type, stripping parameters (additional correction)
  local headers_file="$1" label="$2"
  local ct
  ct=$(grep -i "^content-type:" "$headers_file" | head -1 \
    | awk '{print $2}' | tr -d '[:space:]' | cut -d';' -f1 | tr '[:upper:]' '[:lower:]')
  [ "$ct" = "image/webp" ] \
    || { echo "FAIL [$label]: Content-Type '$ct' != 'image/webp'"; exit 1; }
  echo "PASS [$label]: Content-Type image/webp (exact)"
}

assert_size_header() {
  local headers_file="$1" output_file="$2" label="$3"
  local size_header file_size
  size_header=$(grep -i "^x-forkensics-size:" "$headers_file" | head -1 \
    | awk '{print $2}' | tr -d '[:space:]')
  file_size=$(wc -c < "$output_file" | tr -d '[:space:]')
  [ -n "$size_header" ] \
    || { echo "FAIL [$label]: X-Forkensics-Size header missing"; exit 1; }
  [ "$size_header" = "$file_size" ] \
    || { echo "FAIL [$label]: Size header ($size_header) != file size ($file_size)"; exit 1; }
  [ "$file_size" -le "5242880" ] \
    || { echo "FAIL [$label]: File $file_size bytes exceeds 5 MB ceiling"; exit 1; }
  echo "PASS [$label]: X-Forkensics-Size $size_header = file $file_size bytes"
}

key_status() {
  # Returns: "exists", "absent", or stops runner on operational failure (B-5)
  local key="$1" stderr_tmp
  stderr_tmp=$(mktemp)
  if "$WRANGLER" r2 object get "$BUCKET/$key" --file /dev/null 2>"$stderr_tmp"; then
    rm -f "$stderr_tmp"; echo "exists"; return; fi
  local err; err=$(cat "$stderr_tmp"); rm -f "$stderr_tmp"
  if echo "$err" | grep -qiE "not found|404|no such|does not exist|object not found"; then
    echo "absent"; return; fi
  # Operational failure — stop the run
  echo "FAIL: Operational error checking key '$key': $err" >&2; exit 1
}

key_absent() { [ "$(key_status "$1")" = "absent" ]; }
key_exists() { [ "$(key_status "$1")" = "exists" ]; }

bucket_exists() {
  local out err_tmp; err_tmp=$(mktemp)
  out=$("$WRANGLER" r2 bucket list 2>"$err_tmp") || {
    echo "FAIL: bucket list operational failure: $(cat "$err_tmp")"; rm -f "$err_tmp"; exit 1; }
  rm -f "$err_tmp"
  echo "$out" | grep -qF "$BUCKET"
}

worker_deployed() {
  local out err_tmp; err_tmp=$(mktemp)
  out=$("$WRANGLER" deployments list 2>"$err_tmp") || {
    echo "FAIL: deployments list operational failure: $(cat "$err_tmp")"; rm -f "$err_tmp"; exit 1; }
  rm -f "$err_tmp"
  echo "$out" | grep -qF "$WORKER"
}

# ── EXIT trap ─────────────────────────────────────────────────────────────────
cleanup() {
  local orig_exit=$?
  local cleanup_failed=false
  echo "[CLEANUP] Starting (original exit: $orig_exit) — $(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # Kill wrangler dev
  if [ -n "$DEV_PID" ] && kill -0 "$DEV_PID" 2>/dev/null; then
    kill "$DEV_PID"; wait "$DEV_PID" 2>/dev/null || true
    echo "[CLEANUP] wrangler dev terminated"; fi

  # Delete temp files
  rm -f .dev.vars "$SECRETS_TMP"

  # Undeploy Worker (if any Worker state was created)
  if [ "$SECRET_OR_WORKER_CREATED" = "true" ]; then
    "$WRANGLER" delete "$WORKER" --force 2>/dev/null || true
    if worker_deployed 2>/dev/null; then
      echo "[CLEANUP] WARNING: Worker still deployed"; cleanup_failed=true
    else
      WORKER_DEPLOYED=false
      echo "[CLEANUP] Worker confirmed absent"; fi; fi

  # Delete spike objects (if bucket was created)
  if [ "$BUCKET_CREATED" = "true" ]; then
    for KEY in \
      "spike/fixture-exif.jpg" \
      "spike/fixture-static-icc-xmp.webp" \
      "spike/fixture-animated.webp" \
      "spike/fixture-oversized.jpg" \
      "display/fixture-exif.jpg.webp" \
      "display/fixture-static-icc-xmp.webp" \
      "display/fixture-animated.webp"; do
      "$WRANGLER" r2 object delete "$BUCKET/$KEY" 2>/dev/null || true
      if key_exists "$KEY" 2>/dev/null; then
        echo "[CLEANUP] WARNING: Key still present: $KEY"; cleanup_failed=true
      else
        echo "[CLEANUP] Deleted/absent: $KEY"; fi
    done

    # Delete bucket
    "$WRANGLER" r2 bucket delete "$BUCKET" 2>/dev/null || true
    if bucket_exists 2>/dev/null; then
      echo "[CLEANUP] WARNING: Bucket still present"; cleanup_failed=true
    else
      BUCKET_CREATED=false
      echo "[CLEANUP] Bucket confirmed absent"; fi; fi

  if [ "$cleanup_failed" = "true" ]; then
    echo "[CLEANUP] Status: REMOTE_CLEANUP_REQUIRED"
    [ "$orig_exit" -ne 0 ] && exit "$orig_exit" || exit 1
  else
    echo "[CLEANUP] Status: REMOTE_CLEANUP_CONFIRMED"
    exit "$orig_exit"; fi
}
trap cleanup EXIT

# ── Preflight ─────────────────────────────────────────────────────────────────
echo "=== PREFLIGHT ==="

# Placeholder guard (B-1)
[ "$CF_ACCOUNT_ID" != "⟨BILL_MUST_FILL_IN⟩" ] \
  || { echo "FAIL: CF_ACCOUNT_ID placeholder not replaced — proposal not approvable"; exit 1; }

echo "Wrangler: $("$WRANGLER" --version)"
command -v jq       >/dev/null 2>&1 || { echo "FAIL: jq not installed";       exit 1; }
command -v exiftool >/dev/null 2>&1 || { echo "FAIL: exiftool not installed"; exit 1; }
command -v shasum   >/dev/null 2>&1 || { echo "FAIL: shasum not installed";   exit 1; }

[ -n "${SPIKE_SECRET:-}"         ] || { echo "FAIL: SPIKE_SECRET not set";         exit 1; }
[ -n "${CLOUDFLARE_API_TOKEN:-}" ] || { echo "FAIL: CLOUDFLARE_API_TOKEN not set"; exit 1; }
echo "[PREFLIGHT] Secrets: set (not printed)"

# Account verification via account-details endpoint (additional correction — replaces token/verify)
ACCOUNT_RESP=$(curl -s -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  "https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT_ID")
CF_SUCCESS=$(echo "$ACCOUNT_RESP" | jq -r '.success // false')
CF_ID=$(echo "$ACCOUNT_RESP" | jq -r '.result.id // empty')
[ "$CF_SUCCESS" = "true" ] && [ "$CF_ID" = "$CF_ACCOUNT_ID" ] \
  || { echo "FAIL: Account verification failed (success=$CF_SUCCESS id=$CF_ID)"; exit 1; }
echo "[PREFLIGHT] Account verified: $CF_ACCOUNT_ID"

# No pre-existing spike resources
bucket_exists && { echo "FAIL: Bucket $BUCKET already exists"; exit 1; }
worker_deployed && { echo "FAIL: Worker $WORKER already deployed"; exit 1; }

echo "[PREFLIGHT] All checks passed."
```

---

### CF-P-1 — R2 Bucket Creation

```bash
echo "=== CF-P-1 ==="
"$WRANGLER" r2 bucket create "$BUCKET"
BUCKET_CREATED=true

bucket_exists || { echo "FAIL CF-P-1: Bucket not present after creation"; exit 1; }

# Verify public access disabled via Wrangler (additional correction)
DEV_URL_STATUS=$("$WRANGLER" r2 bucket dev-url get "$BUCKET" 2>&1 || true)
if echo "$DEV_URL_STATUS" | grep -qi "enabled"; then
  echo "FAIL CF-P-1: Public dev URL is enabled"; exit 1; fi
echo "PASS CF-P-1: Bucket created, public access disabled"
```

---

### CF-P-2 — Worker Scaffolding and Type Generation (local only)

```bash
echo "=== CF-P-2 ==="
"$WRANGLER" types
tsc --noEmit
echo "PASS CF-P-2: Types generated, zero type errors"
```

Record from `worker-configuration.d.ts`:
- Exact return type of `env.IMAGES.info()` — does it expose `anim`, `fileSize`? Record field names verbatim; update §4.3 alias map if format field reveals additional aliases.
- Worker code uses inferred return type directly (no `as typeof info` assertion — B-9).

---

### CF-P-3 — Fixture Upload

**Fixtures (B-4 — WebP contract requires static and animated WebP):**

| R2 key | Format | Approximate size | Purpose |
|--------|--------|-----------------|---------|
| `spike/fixture-exif.jpg` | JPEG | ~500 KB | JPEG with GPS + EXIF |
| `spike/fixture-static-icc-xmp.webp` | WebP (static) | ~200 KB | WebP with ICC + XMP metadata |
| `spike/fixture-animated.webp` | WebP (animated) | ~400 KB | Animated WebP → proves `anim:false` |
| `spike/fixture-oversized.jpg` | JPEG | > 10 MB | Proves size rejection |

`generate-fixtures.sh` produces all four (see Phase 2 artifact lock). PNG is no longer a fixture (format-rejection is now a unit test; PNG is outside the frozen contract).

```bash
echo "=== CF-P-3 ==="
declare -A FIXTURES=(
  ["spike/fixture-exif.jpg"]="fixtures/fixture-exif.jpg"
  ["spike/fixture-static-icc-xmp.webp"]="fixtures/fixture-static-icc-xmp.webp"
  ["spike/fixture-animated.webp"]="fixtures/fixture-animated.webp"
  ["spike/fixture-oversized.jpg"]="fixtures/fixture-oversized.jpg"
)
for KEY in "${!FIXTURES[@]}"; do
  LOCAL="${FIXTURES[$KEY]}"
  "$WRANGLER" r2 object put "$BUCKET/$KEY" --file "$LOCAL"
  key_exists "$KEY" || { echo "FAIL CF-P-3: Key $KEY not found after upload"; exit 1; }
  echo "PASS CF-P-3: $KEY uploaded"
done
```

---

### CF-P-4 — Local Transformation Test (`wrangler dev --remote`)

**Authorized cloud operation — explicit (Phase 2).**

```bash
echo "=== CF-P-4 ==="
printf 'SPIKE_SECRET=%s\n' "$SPIKE_SECRET" > .dev.vars && chmod 0600 .dev.vars

"$WRANGLER" dev --remote src/index.ts &
DEV_PID=$!

# Bounded readiness poll on /health (no R2, no IMAGES, no display write)
READY=false
for i in $(seq 1 30); do
  kill -0 "$DEV_PID" 2>/dev/null || { echo "FAIL CF-P-4: wrangler dev died"; exit 1; }
  S=$(curl -s -o /dev/null -w "%{http_code}" --max-time 2 \
    http://localhost:8787/health 2>/dev/null || echo "000")
  [ "$S" = "200" ] && { READY=true; break; }
  sleep 1
done
[ "$READY" = "true" ] || { echo "FAIL CF-P-4: wrangler dev not ready in 30s"; exit 1; }

# Test A — oversized: 422, zero display objects
S_A=$(curl -s -o /dev/null -w "%{http_code}" --max-time 30 \
  -H "Authorization: Bearer $SPIKE_SECRET" \
  http://localhost:8787/transform/spike/fixture-oversized.jpg)
assert_http "$S_A" "422" "CF-P-4-A oversized"
key_absent "display/fixture-oversized.jpg.webp" \
  || { echo "FAIL CF-P-4-A: display key written for oversized"; exit 1; }

# Test B — JPEG: 200, image/webp, size+hash (B-4 + additional corrections)
curl -s --max-time 60 -H "Authorization: Bearer $SPIKE_SECRET" \
  -D cf_p4_jpeg_headers.txt -o cf_p4_jpeg_output.webp \
  http://localhost:8787/transform/spike/fixture-exif.jpg
S_B=$(grep -m1 "^HTTP" cf_p4_jpeg_headers.txt | awk '{print $2}')
assert_http "$S_B" "200" "CF-P-4-B JPEG"
assert_exact_ct cf_p4_jpeg_headers.txt "CF-P-4-B"
assert_size_header cf_p4_jpeg_headers.txt cf_p4_jpeg_output.webp "CF-P-4-B"

# Test C — static WebP with ICC/XMP: 200, metadata stripped (B-4)
curl -s --max-time 60 -H "Authorization: Bearer $SPIKE_SECRET" \
  -D cf_p4_webp_headers.txt -o cf_p4_webp_output.webp \
  http://localhost:8787/transform/spike/fixture-static-icc-xmp.webp
S_C=$(grep -m1 "^HTTP" cf_p4_webp_headers.txt | awk '{print $2}')
assert_http "$S_C" "200" "CF-P-4-C static WebP"
assert_exact_ct cf_p4_webp_headers.txt "CF-P-4-C"
assert_size_header cf_p4_webp_headers.txt cf_p4_webp_output.webp "CF-P-4-C"

# Test D — animated WebP: 200, output must be non-animated (B-4)
curl -s --max-time 60 -H "Authorization: Bearer $SPIKE_SECRET" \
  -D cf_p4_anim_headers.txt -o cf_p4_anim_output.webp \
  http://localhost:8787/transform/spike/fixture-animated.webp
S_D=$(grep -m1 "^HTTP" cf_p4_anim_headers.txt | awk '{print $2}')
assert_http "$S_D" "200" "CF-P-4-D animated WebP"
assert_exact_ct cf_p4_anim_headers.txt "CF-P-4-D"
# Animation check: VP8X Animation flag (0x02) must be zero in output
# Verified in CF-P-6 structural check

kill "$DEV_PID" 2>/dev/null; wait "$DEV_PID" 2>/dev/null || true; DEV_PID=""
rm -f .dev.vars
echo "PASS CF-P-4: All local tests passed"
```

Record: raw `info.format` value logged by Worker for each fixture type.

---

### CF-P-5 — Metadata Stripping Verification

```bash
echo "=== CF-P-5 ==="
for OUTPUT_FILE in cf_p4_jpeg_output.webp cf_p4_webp_output.webp cf_p4_anim_output.webp; do
  EXIF_OUT="cf_p5_exiftool_${OUTPUT_FILE%.webp}.txt"
  # Use -G1 -s for group-aware, short-name output (additional correction)
  exiftool -G1 -s "$OUTPUT_FILE" > "$EXIF_OUT" 2>&1
  echo "--- exiftool -G1 -s $OUTPUT_FILE ---"
  cat "$EXIF_OUT"
  # Check group names exactly (additional correction — grep on [GroupName] prefix)
  for GROUP in "EXIF" "XMP" "ICC_Profile" "IFD0" "ExifIFD" "GPS"; do
    if grep -q "^\[${GROUP}\]" "$EXIF_OUT"; then
      echo "FAIL CF-P-5: Prohibited group [$GROUP] found in $OUTPUT_FILE"; exit 1; fi
  done
  echo "PASS CF-P-5: No prohibited metadata in $OUTPUT_FILE"
done
```

Structural properties (File Size, Image Width, Height, Bit Depth from `[File]` group) are permitted.

---

### CF-P-6 — Output WebP Structural Verification

Applied to all three transformed outputs: JPEG→WebP, static WebP→WebP, animated WebP→WebP.

For each output:
1. **RIFF header:** bytes 0–3 = `52 49 46 46`; bytes 8–11 = `57 45 42 50`.
2. **Exact RIFF size:** `actual_file_size == riff_size + 8`. No extra bytes.
3. **Valid chunk sequences (exactly one of five):** VP8, VP8L, VP8X+VP8, VP8X+ALPH+VP8, VP8X+VP8L. ALPH+VP8L forbidden.
4. **VP8X flags:** `(flags_u32 & ~0x00000010) === 0`. Animation (`0x02`), XMP (`0x04`), EXIF (`0x08`), ICC (`0x20`) must be zero — including in animated WebP output (proves `anim:false` enforcement).

Evidence: hex dump bytes 0–15, RIFF size vs file size, chunk sequence, VP8X flags for each output.

---

### CF-P-7 — SHA-256 Integrity

```bash
echo "=== CF-P-7 ==="
for PAIR in \
  "cf_p4_jpeg_headers.txt:cf_p4_jpeg_output.webp" \
  "cf_p4_webp_headers.txt:cf_p4_webp_output.webp" \
  "cf_p4_anim_headers.txt:cf_p4_anim_output.webp"; do
  HDR="${PAIR%%:*}"; FILE="${PAIR##*:}"
  SHA_HDR=$(grep -i "^x-forkensics-sha256:" "$HDR" | head -1 \
    | awk '{print $2}' | tr -d '[:space:]')
  SHA_FILE=$(shasum -a 256 "$FILE" | awk '{print $1}')
  [ -n "$SHA_HDR" ] || { echo "FAIL CF-P-7 [$HDR]: SHA header missing"; exit 1; }
  [ "$SHA_HDR" = "$SHA_FILE" ] \
    || { echo "FAIL CF-P-7 [$FILE]: mismatch (hdr=$SHA_HDR file=$SHA_FILE)"; exit 1; }
  echo "PASS CF-P-7 [$FILE]: $SHA_FILE"
done
```

---

### CF-P-9 — Hosted Worker Deploy

```bash
echo "=== CF-P-9 ==="
printf 'SPIKE_SECRET=%s\n' "$SPIKE_SECRET" > "$SECRETS_TMP" && chmod 0600 "$SECRETS_TMP"

# Atomic deploy — code and secret uploaded together (B-3, B-6)
DEPLOY_JSON=$("$WRANGLER" deploy --secrets-file "$SECRETS_TMP" --json 2>/dev/null)
SECRET_OR_WORKER_CREATED=true    # set immediately after deploy command
WORKER_DEPLOYED=true
rm -f "$SECRETS_TMP"

# Capture Worker URL from structured deploy output — not constructed from account ID (B-8)
WORKER_URL=$(echo "$DEPLOY_JSON" | jq -r '.url // empty')
[ -n "$WORKER_URL" ] || {
  echo "FAIL CF-P-9: Could not extract Worker URL from deploy output"
  echo "Deploy output: $DEPLOY_JSON"
  exit 1
}
echo "Worker URL: $WORKER_URL"

worker_deployed || { echo "FAIL CF-P-9: Worker not found after deploy"; exit 1; }

# Test JPEG (definitive hosted run)
curl -s --max-time 60 -H "Authorization: Bearer $SPIKE_SECRET" \
  -D cf_p9_headers.txt -o cf_p9_output.webp "${WORKER_URL}/transform/spike/fixture-exif.jpg"
S_P9=$(grep -m1 "^HTTP" cf_p9_headers.txt | awk '{print $2}')
assert_http "$S_P9" "200" "CF-P-9 hosted JPEG"
assert_exact_ct cf_p9_headers.txt "CF-P-9"
assert_size_header cf_p9_headers.txt cf_p9_output.webp "CF-P-9"
SHA_P9=$(grep -i "^x-forkensics-sha256:" cf_p9_headers.txt | head -1 \
  | awk '{print $2}' | tr -d '[:space:]')
SHA_P9_FILE=$(shasum -a 256 cf_p9_output.webp | awk '{print $1}')
[ "$SHA_P9" = "$SHA_P9_FILE" ] \
  || { echo "FAIL CF-P-9: SHA mismatch"; exit 1; }
echo "PASS CF-P-9: Hosted transform confirmed"
```

---

### CF-P-8 — Worker CPU Budget (executes after CF-P-9)

```bash
echo "=== CF-P-8 ==="
echo "[CF-P-8] Collect CPU time from Dashboard → Workers → $WORKER → Analytics"
echo "[CF-P-8] Preliminary (remote-dev console, CF-P-4): [record manually]"
echo "[CF-P-8] Definitive (hosted analytics, CF-P-9): [record manually]"
```

| Plan | Threshold | Result |
|------|-----------|--------|
| Free | < 10 ms | PASS |
| Free | ≥ 10 ms | FAIL — Workers Paid upgrade requires separate three-party approval |
| Paid | < `cpu_ms` | PASS |
| Paid | ≥ `cpu_ms` | FAIL |

Error 1102 = Cloudflare CPU exhaustion. I/O time (R2 reads, Images binding network call) not counted.

---

### CF-P-10 — Auth Boundary

```bash
echo "=== CF-P-10 ==="
S_NO=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
  "${WORKER_URL}/transform/spike/fixture-exif.jpg")
assert_http "$S_NO" "401" "CF-P-10 no-auth"

S_WR=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
  -H "Authorization: Bearer wrongtoken" \
  "${WORKER_URL}/transform/spike/fixture-exif.jpg")
assert_http "$S_WR" "401" "CF-P-10 wrong-token"
echo "PASS CF-P-10: Auth boundary confirmed"
```

---

### CF-P-11 — Write-Back Persistence Verification

```bash
echo "=== CF-P-11 ==="
key_exists "display/fixture-exif.jpg.webp" \
  || { echo "FAIL CF-P-11: JPEG display key absent"; exit 1; }

"$WRANGLER" r2 object get "$BUCKET/display/fixture-exif.jpg.webp" \
  --file cf_p11_verify.webp
SHA_P11=$(shasum -a 256 cf_p11_verify.webp | awk '{print $1}')
[ "$SHA_P11" = "$SHA_P9" ] \
  || { echo "FAIL CF-P-11: Display SHA ($SHA_P11) != hosted SHA ($SHA_P9)"; exit 1; }
echo "PASS CF-P-11: Display object verified"
```

---

### CF-P-12 — Cleanup (explicit success-path — idempotent with EXIT trap)

```bash
echo "=== CF-P-12 ==="
"$WRANGLER" delete "$WORKER" --force
worker_deployed && { echo "FAIL CF-P-12: Worker still deployed"; exit 1; }
WORKER_DEPLOYED=false; SECRET_OR_WORKER_CREATED=false
echo "Worker confirmed absent"

for KEY in \
  "spike/fixture-exif.jpg" "spike/fixture-static-icc-xmp.webp" \
  "spike/fixture-animated.webp" "spike/fixture-oversized.jpg" \
  "display/fixture-exif.jpg.webp" "display/fixture-static-icc-xmp.webp" \
  "display/fixture-animated.webp"; do
  "$WRANGLER" r2 object delete "$BUCKET/$KEY" 2>/dev/null || true
  key_absent "$KEY" || { echo "FAIL CF-P-12: $KEY still present"; exit 1; }
done
echo "All keys confirmed absent"

"$WRANGLER" r2 bucket delete "$BUCKET"
bucket_exists && { echo "FAIL CF-P-12: Bucket still present"; exit 1; }
BUCKET_CREATED=false
echo "PASS CF-P-12: REMOTE_CLEANUP_CONFIRMED"
```

---

## §7 Authoritative Worker Code (`src/index.ts`)

```typescript
// src/index.ts — forkensics-image-spike Rev 5
// SPIKE ONLY — not production code
// Env interface generated by `wrangler types` — do not use `any`

// Explicit alias map — covers documented Cloudflare short-name aliases (B-9)
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

    // Health route — no auth, no R2, no IMAGES
    if (url.pathname === "/health") {
      return new Response("ok", { status: 200 });
    }

    // Auth
    if (request.headers.get("Authorization") !== `Bearer ${env.SPIKE_SECRET}`) {
      return new Response("Unauthorized", { status: 401 });
    }

    const key = url.pathname.replace(/^\/transform\//, "").trim();
    if (!key || key.includes("..") || key.startsWith("/")) {
      return new Response("Invalid key", { status: 400 });
    }

    // Read 1 — size gate
    const object = await env.BUCKET.get(key);
    if (!object) return new Response("Not found", { status: 404 });
    const etag = object.etag;
    if ((object.size ?? 0) > MAX_INPUT_BYTES) {
      return new Response(`Input too large: ${object.size}`, { status: 422 });
    }

    // Read 2 — .info() free, ETag-matched
    const infoObject = await env.BUCKET.get(key, { onlyIf: { etagMatches: etag } });
    // Conditional miss may return metadata-only (no body property) — not null (B-4)
    if (!infoObject || !("body" in infoObject) || !infoObject.body) {
      return new Response("Input changed between reads", { status: 409 });
    }
    // Use inferred type directly from IMAGES.info() — no `as` assertion (B-9)
    const info = await env.IMAGES.info(infoObject.body);
    console.log(`info.format raw: ${JSON.stringify(info.format)}`);

    const normalizedFormat = FORMAT_ALIAS_MAP[String(info.format).toLowerCase()] ?? null;
    if (!normalizedFormat || !ACCEPTED_FORMATS.has(normalizedFormat)) {
      return new Response(`Unsupported format: ${info.format}`, { status: 422 });
    }
    if (info.width * info.height > MAX_PIXELS) {
      return new Response(
        `Image ${info.width}×${info.height}px exceeds ${MAX_PIXELS}px area ceiling`,
        { status: 422 }
      );
    }
    if (typeof (info as { fileSize?: number }).fileSize === "number" &&
        (info as { fileSize?: number }).fileSize !== object.size) {
      return new Response("File size mismatch", { status: 422 });
    }

    // Read 3 — transform, ETag-matched
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
    // Exact Content-Type check, stripping parameters
    const ct = (transformResponse.headers.get("Content-Type") ?? "").split(";")[0].trim();
    if (ct !== "image/webp") {
      return new Response(`Unexpected Content-Type: ${ct}`, { status: 502 });
    }
    if (!transformResponse.body) {
      return new Response("Transform returned empty body", { status: 502 });
    }

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
    const outputBytes = new Uint8Array(totalBytes);
    let off = 0;
    for (const c of chunks) { outputBytes.set(c, off); off += c.byteLength; }

    // SHA-256
    const hashHex = Array.from(
      new Uint8Array(await crypto.subtle.digest("SHA-256", outputBytes))
    ).map((b) => b.toString(16).padStart(2, "0")).join("");

    // Write display copy — basename only
    const displayKey = `display/${key.split("/").pop()!}.webp`;
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

## §8 Verdict Criteria

| Tier | Condition | Meaning |
|------|-----------|---------|
| **PASS** | All probes pass, `REMOTE_CLEANUP_CONFIRMED` | Architecture viable. Proceed to production design. |
| **FAIL** | Any probe FAIL | Stop. Document. Evaluate Fallback Rank 2 (Sharp/libvips). |
| **CLEANUP NOTE** | `REMOTE_CLEANUP_REQUIRED` | Manual verification needed regardless of test result. |

---

## §9 Open Questions

| # | Question | Owner |
|---|----------|-------|
| OQ-1 | Production upload: presign to R2 directly or `upload-authorize` proxies PUT? | Bill |
| OQ-2 | Display key: deterministic (hash of original) or random (UUID)? | Bill |
| OQ-3 | Production Worker auth: CF service token or HMAC-SHA256 with replay? | Bill + Codex |
| OQ-4 | Per-side dimension limit in addition to 15.5 MP area ceiling? | Bill |

---

## §10 Blocker Resolution Table (Rev 4 → Rev 5)

| # | Rev 4 Blocker | Resolution |
|---|--------------|------------|
| B-1 | Account-ID placeholder remains | §1.1 updated with `⟨BILL_MUST_FILL_IN⟩` literal; runner aborts on literal match; proposal cannot be submitted for Phase 1 sign-off until replaced by Bill |
| B-2 | Phase 2 has no locked artifact review | §1.2 Phase 2 table requires SHA-256 for all 6 artifacts + static-check + Vitest evidence before any cloud op |
| B-3 | `[secrets]` missing; `secret put` before Worker exists is not atomic | `wrangler.toml` has `[secrets] required = ["SPIKE_SECRET"]`; `wrangler deploy --secrets-file` provisions code and secret atomically |
| B-4 | WebP contract not tested | Fixtures: static WebP (ICC+XMP) + animated WebP; Tests C/D in CF-P-4; CF-P-6 checks VP8X Animation flag = 0 in animated output |
| B-5 | `key_absent()` treats all failures as absent | `key_status()` parses stderr; distinguishes "exists" / "absent" / operational-failure; operational failure stops the run |
| B-6 | Flags suppress necessary retries; `secret put` state untracked | `SECRET_OR_WORKER_CREATED` set immediately after deploy; flags stay true until absence confirmed; known-key deletion failures checked individually |
| B-7 | ETag race test is not a test | §5.0: two Vitest unit tests (Read 2 miss + Read 3 miss); assert 409 and verify `IMAGES.info()`/`BUCKET.put()` not called |
| B-8 | Worker URL constructed from account ID (wrong) | URL captured from `wrangler deploy --json` `.url` field; aborts if field absent |
| B-9 | `as typeof info` hides generated type; `image/jpg` alias | `FORMAT_ALIAS_MAP` with explicit entries for `jpg→image/jpeg`, `jpeg→image/jpeg`, `webp→image/webp`; inferred type used directly without assertion |
| AC-1 | `/user/tokens/verify` identifies token not account | Account-details endpoint `GET /accounts/{id}` used; exact `.result.id` match required |
| AC-2 | `X-Forkensics-Size` not asserted | `assert_size_header` checks header == `wc -c` and ≤ 5 MB ceiling |
| AC-3 | `includes("image/webp")` too permissive | `assert_exact_ct` strips parameters, lowercases, requires exact `"image/webp"` |
| AC-4 | ExifTool without `-G1 -s` misses some prohibited tags | `exiftool -G1 -s`; checks for `[EXIF]`, `[XMP]`, `[ICC_Profile]`, `[IFD0]`, `[ExifIFD]`, `[GPS]` group prefixes |
| AC-5 | `grep -v` absence logic fail-open | Replaced with `grep -qF` presence test with explicit failure branches throughout |
| AC-6 | Public R2 access verified only via Dashboard | `wrangler r2 bucket dev-url get` checked programmatically in CF-P-1 |

---

*Proposal Rev 5 — 2026-08-15 — awaiting Bill to fill in CF_ACCOUNT_ID, then §1.2 Phase 1 three-party sign-off*
