# Gate 2B — Cloudflare R2 + Images Binding Feasibility Spike
## Proposal Rev 8 — 2026-08-15

**Supersedes:** Rev 7 (not approved — 4 blockers, Codex SHA-256 `64317f74f85330f64fdf0dd8baf30ca04b1263c6f9a86aa8d2d9f4350fde3253`)

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

### §1.2 Two-Phase Authorization

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
| Claude | ✅ | Rev 8 authored |
| Codex | ⬜ pending | |
| Bill | ⬜ pending | |

#### Phase 2 — Artifact lock and execution authorization

Requires all of the following before any cloud operation:

1. All six Phase 2 artifacts exist, are frozen, and have recorded SHA-256:

| Artifact | SHA-256 | Review status |
|----------|---------|---------------|
| `src/index.ts` | ⬜ pending | ⬜ pending |
| `src/index.test.ts` | ⬜ pending | ⬜ pending |
| `wrangler.toml` | ⬜ pending | ⬜ pending |
| `run-spike.sh` | ⬜ pending | ⬜ pending |
| `fixtures/generate-fixtures.sh` | ⬜ pending | ⬜ pending |
| `parser/verify-webp.sh` | ⬜ pending | ⬜ pending |

2. Static-check evidence: `tsc --noEmit` exits 0, zero errors.
3. Local unit-test evidence: full Vitest suite passes (§5).
4. Wrangler `--help` verification recorded for all commands in §4.8.

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

**Account verification:**
```bash
ACCOUNT_RESP=$(curl -s -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  "https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT_ID")
[ "$(printf '%s\n' "$ACCOUNT_RESP" | jq -r '.success')" = "true" ] \
  && [ "$(printf '%s\n' "$ACCOUNT_RESP" | jq -r '.result.id')" = "$CF_ACCOUNT_ID" ] \
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
  → Cloudflare Worker (CLOUDFLARE_ACCOUNT_ID pinned)
      GET /health → 200 (no auth, no R2, no IMAGES)
      auth boundary
      BUCKET.head(key) → ETag + size (no body stream opened)
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
- Boundary: exactly 15,500,000 pixels must PASS; 15,500,001 must FAIL. Both tested (§5.6).

### §4.3 Accepted Format Contract (JPEG + WebP only — frozen)

```typescript
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

**Atomic deployment:** `wrangler deploy --secrets-file "$SECRETS_TMP"`. Mutation-attempt flag set before the deploy call:
```bash
SECRET_OR_WORKER_CREATED=true   # set before attempt; ensures cleanup runs even on partial failure
"$WRANGLER" deploy --secrets-file "$SECRETS_TMP"
WORKER_DEPLOYED=true
```

### §4.6 Account Pinning for All Wrangler Operations

`CLOUDFLARE_ACCOUNT_ID` is exported at runner startup and inherited by every Wrangler subprocess:

```bash
export CLOUDFLARE_ACCOUNT_ID="$CF_ACCOUNT_ID"
```

### §4.7 Deploy URL Extraction via `WRANGLER_OUTPUT_FILE_PATH`

`wrangler deploy --json` is not documented. The authorized mechanism is `WRANGLER_OUTPUT_FILE_PATH`, which causes Wrangler to write JSONL deploy events. Per Cloudflare documentation, `targets` is an array of URL strings — `targets[0]` is the URL directly, not an object with a `.url` field.

```bash
WORKER_URL=$(jq -r 'select(.type == "deploy") | .targets[0] // empty' "$WRANGLER_OUT" \
  | head -1)
```

If Phase 1 `--help` verification reveals the `targets` schema differs, update before Phase 2 sign-off.

### §4.8 Wrangler Version and Command Verification

Pin version: `npm install --save-dev wrangler@<pinned>`. Use `./node_modules/.bin/wrangler` throughout. Export `CLOUDFLARE_ACCOUNT_ID` before every invocation.

**Important (Wrangler 4):** `wrangler r2 object` commands default to local storage in Wrangler 4. The `--remote` flag is required on every `r2 object put`, `r2 object get`, and `r2 object delete` to operate against the remote R2 bucket.

Commands requiring `--help` / docs verification before Phase 2 sign-off:

| Command | Notes |
|---------|-------|
| `wrangler init` (and flags) | If no suitable init flags: scaffold manually |
| `wrangler types` | Must generate `worker-configuration.d.ts` |
| `wrangler dev --remote` | Verify `preview_bucket_name` support |
| `wrangler deploy --secrets-file` | Verify flag exists in pinned version |
| `WRANGLER_OUTPUT_FILE_PATH` | Verify env var and `targets[0]` schema (string, not object) |
| `wrangler delete` | Verify `--force` flag |
| `wrangler r2 bucket create/delete` | — |
| `wrangler r2 object put/get/delete --remote` | `--remote` required in Wrangler 4; `r2 object list` NOT supported |
| `wrangler whoami` | — |
| CF API `GET /r2/buckets/{name}/domains/managed` | Verify `result.enabled` field shape |

Worker existence is verified via the Cloudflare Workers API (not `deployments list` — see §6.0 helpers).

---

## §5 Unit Test Coverage (`src/index.test.ts`) — Required before Phase 2

Full Vitest matrix using Workers Vitest integration. All tests use injected mocks — no cloud calls.

With `head()` for Read 1, there are exactly **two** `get()` calls in the success path: Read 2 (→ info) and Read 3 (→ transform). Mock sequences below reflect this.

### §5.1 ETag Race — Read 2 conditional miss → 409, info/put not called

Read 1 is `head()` — not mocked via `get`. The first and only `get()` call is Read 2; it must return metadata-only to simulate the race.

```typescript
it("returns 409 when Read 2 gets metadata-only (no body)", async () => {
  // Read 2: first get() returns no 'body' key → conditional miss
  const mockGet  = vi.fn(async () => ({ etag: "b", size: 500_000 }));
  const mockInfo = vi.fn();
  const mockPut  = vi.fn();
  const resp = await invoke(
    {
      BUCKET: {
        head: vi.fn(async () => ({ etag: "a", size: 500_000 })),
        get:  mockGet,
        put:  mockPut,
      },
      IMAGES: { info: mockInfo, input: vi.fn() },
    },
    "/transform/test.jpg"
  );
  expect(resp.status).toBe(409);
  expect(mockGet).toHaveBeenCalledTimes(1);   // only Read 2 attempted
  expect(mockInfo).not.toHaveBeenCalled();
  expect(mockPut).not.toHaveBeenCalled();
});
```

### §5.2 ETag Race — Read 3 conditional miss → 409, IMAGES.input/put not called

Read 2 (first `get()`) succeeds with a body so info runs; Read 3 (second `get()`) returns metadata-only.

```typescript
it("returns 409 when Read 3 gets metadata-only", async () => {
  let call = 0;
  const mockGet = vi.fn(async () => {
    call++;
    if (call === 1) return { body: new ReadableStream(), etag: "a", size: 500_000 }; // Read 2: has body
    return { etag: "b", size: 500_000 }; // Read 3: no 'body' key → conditional miss
  });
  const mockInfo  = vi.fn(async () => ({ format: "jpeg", width: 800, height: 600 }));
  const mockInput = vi.fn();
  const mockPut   = vi.fn();
  const resp = await invoke(
    {
      BUCKET: {
        head: vi.fn(async () => ({ etag: "a", size: 500_000 })),
        get:  mockGet,
        put:  mockPut,
      },
      IMAGES: { info: mockInfo, input: mockInput },
    },
    "/transform/test.jpg"
  );
  expect(resp.status).toBe(409);
  expect(mockGet).toHaveBeenCalledTimes(2);   // Read 2 + Read 3 both attempted
  expect(mockInfo).toHaveBeenCalledTimes(1);  // Read 2 succeeded → info ran
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
// Accepted aliases
for (const alias of ["jpeg", "jpg", "image/jpeg", "webp", "image/webp"]) {
  it(`accepts format alias "${alias}"`, ...);
}
// Rejected formats — IMAGES.input() and BUCKET.put() must not be called
for (const fmt of ["png", "image/png", "heic", "avif", "gif", "tiff"]) {
  it(`rejects format "${fmt}" with 422`, ...);
  it(`does not call BUCKET.put() for format "${fmt}"`, ...);
}
```

### §5.5 Size boundary

```typescript
it("accepts input at exactly 10,485,760 bytes (10 MB)", ...);    // PASS
it("rejects input at 10,485,761 bytes (10 MB + 1)", ...);         // 422, no transform
it("does not call BUCKET.put() for oversized input", ...);
```

### §5.6 Pixel area boundary (exact dimensions)

```typescript
// 3100 × 5000 = 15,500,000 (exactly at ceiling — PASS)
it("accepts image at exactly 15,500,000 pixels (3100×5000)", ...);
// 2739 × 5659 = 15,500,001 (one over — FAIL)
it("rejects image at 15,500,001 pixels (2739×5659)", ...);        // 422
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

# Pin all Wrangler operations to the authorized account
export CLOUDFLARE_ACCOUNT_ID="$CF_ACCOUNT_ID"

# ── Mutation-attempt flags ─────────────────────────────────────────────────────
BUCKET_MUTATION_ATTEMPTED=false   # set before r2 bucket create
BUCKET_CREATED=false              # set after confirmed success
SECRET_OR_WORKER_CREATED=false    # set before wrangler deploy
WORKER_DEPLOYED=false             # set after confirmed success
DEV_PID=""
WORKER_URL=""

# ── Three-state verifier helpers ───────────────────────────────────────────────
# All helpers output exactly one of: "exists" | "absent" | "error"
# Return code: 0 for exists/absent, 1 for error.
# Call sites: capture to variable, check return code with ||, then case with default.

# key_status KEY
# Wrangler 4: --remote required for r2 object commands to reach the remote bucket
key_status() {
  local key="$1" err_tmp
  err_tmp=$(mktemp)
  if "$WRANGLER" r2 object get "$BUCKET/$key" --file /dev/null --remote \
      >"$err_tmp" 2>&1; then
    rm -f "$err_tmp"; echo "exists"; return 0
  fi
  local err; err=$(cat "$err_tmp"); rm -f "$err_tmp"
  if printf '%s\n' "$err" | grep -qiE "not found|404|no such key|object not found"; then
    echo "absent"; return 0
  fi
  printf 'FAIL: key_status error for %s: %s\n' "$key" "$err" >&2
  echo "error"; return 1
}

# worker_api_status — discard body, capture HTTP status code only
worker_api_status() {
  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
    "https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT_ID/workers/scripts/$WORKER")
  case "$http_code" in
    200) echo "exists"; return 0 ;;
    404) echo "absent"; return 0 ;;
    *)   printf 'FAIL: worker_api_status HTTP %s\n' "$http_code" >&2
         echo "error"; return 1 ;;
  esac
}

# bucket_api_status
bucket_api_status() {
  local resp success code
  resp=$(curl -s -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
    "https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT_ID/r2/buckets/$BUCKET")
  success=$(printf '%s\n' "$resp" | jq -r '.success')
  case "$success" in
    true) echo "exists"; return 0 ;;
    false)
      code=$(printf '%s\n' "$resp" | jq -r '.errors[0].code // 0')
      if [ "$code" = "10006" ]; then echo "absent"; return 0
      else
        printf 'FAIL: bucket_api_status CF error %s: %s\n' "$code" "$resp" >&2
        echo "error"; return 1
      fi ;;
    *) printf 'FAIL: bucket_api_status unexpected: %s\n' "$resp" >&2
       echo "error"; return 1 ;;
  esac
}

# ── EXIT trap ──────────────────────────────────────────────────────────────────
cleanup() {
  local orig=$?; local failed=false; local STATUS
  echo "[CLEANUP] Starting (exit=$orig) — $(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # 1. Kill wrangler dev
  if [ -n "$DEV_PID" ] && kill -0 "$DEV_PID" 2>/dev/null; then
    kill "$DEV_PID"; wait "$DEV_PID" 2>/dev/null || true
    echo "[CLEANUP] wrangler dev terminated"
  fi

  # 2. Delete temp files
  rm -f .dev.vars "$SECRETS_TMP" "$WRANGLER_OUT"

  # 3. Undeploy Worker (if any state was attempted)
  if [ "$SECRET_OR_WORKER_CREATED" = "true" ]; then
    "$WRANGLER" delete "$WORKER" --force 2>/dev/null || true
    STATUS=$(worker_api_status) || true
    case "$STATUS" in
      absent) echo "[CLEANUP] Worker confirmed absent" ;;
      exists) echo "[CLEANUP] WARNING: Worker still deployed"; failed=true ;;
      *)      echo "[CLEANUP] FAIL: worker_api_status returned '$STATUS'"; failed=true ;;
    esac
  fi

  # 4. Delete spike objects (attempt if bucket creation was ever tried)
  if [ "$BUCKET_MUTATION_ATTEMPTED" = "true" ]; then
    for KEY in \
      "spike/fixture-exif.jpg" \
      "spike/fixture-static-icc-xmp.webp" \
      "spike/fixture-animated.webp" \
      "spike/fixture-oversized-px.jpg" \
      "spike/fixture-oversized.jpg" \
      "display/fixture-exif.jpg.webp" \
      "display/fixture-static-icc-xmp.webp" \
      "display/fixture-animated.webp" \
      "display/fixture-oversized.jpg.webp" \
      "display/fixture-oversized-px.jpg.webp"; do
      # --remote required in Wrangler 4 for remote bucket operations
      "$WRANGLER" r2 object delete "$BUCKET/$KEY" --remote 2>/dev/null || true
      STATUS=$(key_status "$KEY") || true
      case "$STATUS" in
        absent) echo "[CLEANUP] Confirmed absent: $KEY" ;;
        exists) echo "[CLEANUP] WARNING: Still present: $KEY"; failed=true ;;
        *)      echo "[CLEANUP] FAIL: key_status returned '$STATUS' for $KEY"; failed=true ;;
      esac
    done

    # 5. Delete bucket
    "$WRANGLER" r2 bucket delete "$BUCKET" 2>/dev/null || true
    STATUS=$(bucket_api_status) || true
    case "$STATUS" in
      absent) BUCKET_MUTATION_ATTEMPTED=false; echo "[CLEANUP] Bucket confirmed absent" ;;
      exists) echo "[CLEANUP] WARNING: Bucket still present"; failed=true ;;
      *)      echo "[CLEANUP] FAIL: bucket_api_status returned '$STATUS'"; failed=true ;;
    esac
  fi

  if [ "$failed" = "true" ]; then
    echo "[CLEANUP] Status: REMOTE_CLEANUP_REQUIRED"
    [ "$orig" -ne 0 ] && exit "$orig" || exit 1
  else
    echo "[CLEANUP] Status: REMOTE_CLEANUP_CONFIRMED"
    exit "$orig"
  fi
}
trap cleanup EXIT

# ── Preflight ─────────────────────────────────────────────────────────────────
echo "=== PREFLIGHT ==="

echo "Wrangler: $("$WRANGLER" --version)"
command -v jq       >/dev/null || { echo "FAIL: jq not installed";       exit 1; }
command -v exiftool >/dev/null || { echo "FAIL: exiftool not installed"; exit 1; }
command -v shasum   >/dev/null || { echo "FAIL: shasum not installed";   exit 1; }
command -v bc       >/dev/null || { echo "FAIL: bc not installed";       exit 1; }

[ -n "${SPIKE_SECRET:-}"         ] || { echo "FAIL: SPIKE_SECRET not set";         exit 1; }
[ -n "${CLOUDFLARE_API_TOKEN:-}" ] || { echo "FAIL: CLOUDFLARE_API_TOKEN not set"; exit 1; }
echo "Secrets: set (not printed)"

# .dev.vars gitignore check
git check-ignore -q .dev.vars 2>/dev/null \
  || { echo "FAIL: .dev.vars not in .gitignore — add it before proceeding"; exit 1; }

# Account verification
ACCOUNT_RESP=$(curl -s -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  "https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT_ID")
[ "$(printf '%s\n' "$ACCOUNT_RESP" | jq -r '.success')" = "true" ] \
  && [ "$(printf '%s\n' "$ACCOUNT_RESP" | jq -r '.result.id')" = "$CF_ACCOUNT_ID" ] \
  || { echo "FAIL: Account verification failed: $ACCOUNT_RESP"; exit 1; }
echo "Account verified: $CF_ACCOUNT_ID"

# No pre-existing spike resources
STATUS=$(bucket_api_status) || { echo "FAIL: bucket_api_status error"; exit 1; }
[ "$STATUS" = "absent" ] || { echo "FAIL: Bucket $BUCKET already exists (status: $STATUS)"; exit 1; }

STATUS=$(worker_api_status) || { echo "FAIL: worker_api_status error"; exit 1; }
[ "$STATUS" = "absent" ] || { echo "FAIL: Worker $WORKER already deployed (status: $STATUS)"; exit 1; }

echo "Preflight passed."
```

---

### CF-P-1 — R2 Bucket Creation

```bash
echo "=== CF-P-1 ==="

# Set mutation-attempt flag BEFORE create attempt
BUCKET_MUTATION_ATTEMPTED=true
"$WRANGLER" r2 bucket create "$BUCKET"
BUCKET_CREATED=true

STATUS=$(bucket_api_status) || { echo "FAIL CF-P-1: bucket_api_status error"; exit 1; }
[ "$STATUS" = "exists" ] \
  || { echo "FAIL CF-P-1: Bucket not found after creation (status: $STATUS)"; exit 1; }

# Verify public access disabled via CF managed-domain API (exact enabled/disabled/error).
# Endpoint: GET /r2/buckets/{name}/domains/managed — returns result.enabled (bool).
DEV_URL_RESP=$(curl -s -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  "https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT_ID/r2/buckets/$BUCKET/domains/managed")
DEV_URL_ENABLED=$(printf '%s\n' "$DEV_URL_RESP" | jq -r '.result.enabled // "error"')
case "$DEV_URL_ENABLED" in
  false) echo "PASS CF-P-1: Bucket created, public domain confirmed disabled" ;;
  true)  echo "FAIL CF-P-1: Public managed domain is enabled"; exit 1 ;;
  *)     echo "FAIL CF-P-1: managed-domain API unexpected response: $DEV_URL_RESP"; exit 1 ;;
esac
```

---

### CF-P-2 — Worker Scaffolding and Type Generation (local only)

```bash
echo "=== CF-P-2 ==="
"$WRANGLER" types
tsc --noEmit
```

Record from `worker-configuration.d.ts`:
- Return type of `env.IMAGES.info()` — does it include `fileSize`? If yes, use directly. If no, omit the fileSize check (no `as` cast in either case).
- Exact format string aliases returned by Cloudflare — update `FORMAT_ALIAS_MAP` if needed.

```bash
echo "PASS CF-P-2: Types generated, zero type errors"
```

---

### CF-P-3 — Fixture Generation and Upload

**Generator must prove fixture preconditions before upload:**

```bash
echo "=== CF-P-3 ==="

# 1. Run generate-fixtures.sh which:
#    a. Creates all fixtures
#    b. PROVES each fixture meets its preconditions:
#       - fixture-exif.jpg: exiftool -G1 -s shows [EXIF] and [GPS]
#       - fixture-static-icc-xmp.webp: shows [ICC_Profile] and [XMP]
#       - fixture-animated.webp: ANMF chunks present or exiftool FrameCount > 1
#       - fixture-oversized-px.jpg:
#           width × height > 15,500,000 (pixel gate triggers)
#           AND file_size <= 10,485,760 (byte-size gate must NOT trigger — proves
#           pixel gate is the actual barrier, not size gate)
#       - fixture-oversized.jpg: wc -c > 10,485,760 (size gate triggers)
#    c. FAILS (exit 1) if any precondition is not met
./fixtures/generate-fixtures.sh

# 2. Upload all fixtures (--remote required in Wrangler 4)
declare -A FIXTURES=(
  ["spike/fixture-exif.jpg"]="fixtures/fixture-exif.jpg"
  ["spike/fixture-static-icc-xmp.webp"]="fixtures/fixture-static-icc-xmp.webp"
  ["spike/fixture-animated.webp"]="fixtures/fixture-animated.webp"
  ["spike/fixture-oversized-px.jpg"]="fixtures/fixture-oversized-px.jpg"
  ["spike/fixture-oversized.jpg"]="fixtures/fixture-oversized.jpg"
)
for KEY in "${!FIXTURES[@]}"; do
  LOCAL="${FIXTURES[$KEY]}"
  "$WRANGLER" r2 object put "$BUCKET/$KEY" --file "$LOCAL" --remote
  STATUS=$(key_status "$KEY") || { echo "FAIL CF-P-3: key_status error for $KEY"; exit 1; }
  [ "$STATUS" = "exists" ] \
    || { echo "FAIL CF-P-3: Key $KEY not found after upload (status: $STATUS)"; exit 1; }
  echo "PASS CF-P-3: $KEY uploaded"
done
```

**Fixtures:**

| R2 key | Purpose | Precondition proof |
|--------|---------|-------------------|
| `spike/fixture-exif.jpg` | JPEG with GPS + EXIF | exiftool -G1 -s shows `[EXIF]` and `[GPS]` groups |
| `spike/fixture-static-icc-xmp.webp` | Static WebP with ICC + XMP | exiftool -G1 -s shows `[ICC_Profile]` and `[XMP]` groups |
| `spike/fixture-animated.webp` | Animated WebP (anim:false test) | ANMF chunks present or FrameCount > 1 |
| `spike/fixture-oversized-px.jpg` | > 15.5 MP AND ≤ 10 MB | pixel area > 15,500,000 AND `wc -c` ≤ 10,485,760 (both assertions required) |
| `spike/fixture-oversized.jpg` | > 10 MB (size gate) | `wc -c` > 10,485,760 |

**`fixtures/generate-fixtures.sh` — oversized-px precondition section (authoritative):**

```bash
# fixture-oversized-px.jpg: must exceed pixel ceiling AND fit within byte-size gate
PIXEL_W=$(exiftool -n -s3 -ImageWidth  fixtures/fixture-oversized-px.jpg)
PIXEL_H=$(exiftool -n -s3 -ImageHeight fixtures/fixture-oversized-px.jpg)
PIXEL_AREA=$(( PIXEL_W * PIXEL_H ))
PIXEL_SIZE=$(wc -c < fixtures/fixture-oversized-px.jpg | tr -d ' ')
[ "$PIXEL_AREA" -gt 15500000 ] \
  || { echo "FAIL: fixture-oversized-px.jpg area $PIXEL_AREA <= 15,500,000"; exit 1; }
[ "$PIXEL_SIZE" -le 10485760 ] \
  || { echo "FAIL: fixture-oversized-px.jpg size $PIXEL_SIZE > 10,485,760 — byte gate fires first"; exit 1; }
echo "PASS: fixture-oversized-px.jpg area=$PIXEL_AREA size=$PIXEL_SIZE"
```

---

### CF-P-4 — Local Transformation Test (`wrangler dev --remote`)

**Authorized cloud operation (Phase 2).**

```bash
echo "=== CF-P-4 ==="

# Atomic creation at mode 0600 before writing any secret
(umask 077; printf 'SPIKE_SECRET=%s\n' "$SPIKE_SECRET" > .dev.vars)

"$WRANGLER" dev --remote src/index.ts &
DEV_PID=$!

READY=false
for i in $(seq 1 30); do
  kill -0 "$DEV_PID" 2>/dev/null || { echo "FAIL CF-P-4: wrangler dev died"; exit 1; }
  S=$(curl -s -o /dev/null -w "%{http_code}" --max-time 2 \
    http://localhost:8787/health 2>/dev/null || echo "000")
  [ "$S" = "200" ] && { READY=true; break; }
  sleep 1
done
[ "$READY" = "true" ] || { echo "FAIL CF-P-4: not ready in 30s"; exit 1; }

# ── Assertion helpers ──────────────────────────────────────────────────────────

assert_http() {
  local got="$1" want="$2" label="$3"
  [ "$got" = "$want" ] || { echo "FAIL $label: expected HTTP $want, got $got"; exit 1; }
}

# Exact Content-Type check: strip field name, strip parameters, normalize case,
# compare byte-for-byte to "image/webp". Rejects "image/webp-malicious" etc.
assert_exact_ct() {
  local headers="$1" label="$2" raw ct
  raw=$(grep -i "^content-type:" "$headers" | head -1 | tr -d '\r')
  ct=$(printf '%s\n' "$raw" \
    | sed 's/^[Cc]ontent-[Tt]ype:[[:space:]]*//' \
    | cut -d';' -f1 \
    | tr '[:upper:]' '[:lower:]' \
    | tr -d '[:space:]')
  [ "$ct" = "image/webp" ] \
    || { echo "FAIL $label: Content-Type exact mismatch: got '$ct' (raw: '$raw')"; exit 1; }
}

# Size header check: X-Forkensics-Size must equal actual file size AND be within 5 MB ceiling.
assert_size_header() {
  local headers="$1" file="$2" label="$3" hdr_size file_size
  hdr_size=$(grep -i "^x-forkensics-size:" "$headers" | head -1 \
    | awk '{print $2}' | tr -d '[:space:]')
  file_size=$(wc -c < "$file" | tr -d ' ')
  [ "$hdr_size" = "$file_size" ] \
    || { echo "FAIL $label: X-Forkensics-Size $hdr_size != actual $file_size"; exit 1; }
  [ "$file_size" -le 5242880 ] \
    || { echo "FAIL $label: output $file_size bytes exceeds 5 MB ceiling"; exit 1; }
}

# Test A — oversized bytes: 422, no display write
S_A=$(curl -s -o /dev/null -w "%{http_code}" --max-time 30 \
  -H "Authorization: Bearer $SPIKE_SECRET" \
  http://localhost:8787/transform/spike/fixture-oversized.jpg)
assert_http "$S_A" "422" "CF-P-4-A oversized-bytes"
STATUS=$(key_status "display/fixture-oversized.jpg.webp") \
  || { echo "FAIL CF-P-4-A: key_status error"; exit 1; }
[ "$STATUS" = "absent" ] || { echo "FAIL CF-P-4-A: display key written for oversized-bytes"; exit 1; }

# Test B — oversized pixels: 422, no display write
S_B=$(curl -s -o /dev/null -w "%{http_code}" --max-time 30 \
  -H "Authorization: Bearer $SPIKE_SECRET" \
  http://localhost:8787/transform/spike/fixture-oversized-px.jpg)
assert_http "$S_B" "422" "CF-P-4-B oversized-pixels"
STATUS=$(key_status "display/fixture-oversized-px.jpg.webp") \
  || { echo "FAIL CF-P-4-B: key_status error"; exit 1; }
[ "$STATUS" = "absent" ] || { echo "FAIL CF-P-4-B: display key written for oversized-pixels"; exit 1; }

# Test C — JPEG with EXIF: 200
curl -s --max-time 60 -H "Authorization: Bearer $SPIKE_SECRET" \
  -D cf_p4_jpeg_headers.txt -o cf_p4_jpeg_output.webp \
  http://localhost:8787/transform/spike/fixture-exif.jpg
assert_http "$(grep -m1 "^HTTP" cf_p4_jpeg_headers.txt | awk '{print $2}')" "200" "CF-P-4-C JPEG"
assert_exact_ct cf_p4_jpeg_headers.txt "CF-P-4-C"
assert_size_header cf_p4_jpeg_headers.txt cf_p4_jpeg_output.webp "CF-P-4-C"

# Test D — static WebP with ICC/XMP: 200
curl -s --max-time 60 -H "Authorization: Bearer $SPIKE_SECRET" \
  -D cf_p4_swebp_headers.txt -o cf_p4_swebp_output.webp \
  http://localhost:8787/transform/spike/fixture-static-icc-xmp.webp
assert_http "$(grep -m1 "^HTTP" cf_p4_swebp_headers.txt | awk '{print $2}')" "200" "CF-P-4-D static-WebP"
assert_exact_ct cf_p4_swebp_headers.txt "CF-P-4-D"
assert_size_header cf_p4_swebp_headers.txt cf_p4_swebp_output.webp "CF-P-4-D"

# Test E — animated WebP: 200, output non-animated
curl -s --max-time 60 -H "Authorization: Bearer $SPIKE_SECRET" \
  -D cf_p4_awebp_headers.txt -o cf_p4_awebp_output.webp \
  http://localhost:8787/transform/spike/fixture-animated.webp
assert_http "$(grep -m1 "^HTTP" cf_p4_awebp_headers.txt | awk '{print $2}')" "200" "CF-P-4-E animated-WebP"
assert_exact_ct cf_p4_awebp_headers.txt "CF-P-4-E"
assert_size_header cf_p4_awebp_headers.txt cf_p4_awebp_output.webp "CF-P-4-E"
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
  BASE=$(basename "$F" .webp)
  exiftool -G1 -s "$F" > "cf_p5_${BASE}.txt"
  cat "cf_p5_${BASE}.txt"
  for G in EXIF XMP ICC_Profile IFD0 ExifIFD GPS; do
    grep -q "^\[${G}\]" "cf_p5_${BASE}.txt" \
      && { echo "FAIL CF-P-5: Prohibited group [$G] in $F"; exit 1; }
  done
  echo "PASS CF-P-5: No prohibited metadata in $F"
done
```

---

### CF-P-6 — Output WebP Structural Verification

Applied to all three transformed outputs. Animated-WebP output additionally checked for Animation flag = 0:

1. RIFF header bytes 0–3 = `52 49 46 46`; bytes 8–11 = `57 45 42 50`.
2. Exact size: `actual_file_size == riff_size + 8`.
3. Valid chunk sequence (one of five). ALPH+VP8L forbidden.
4. VP8X flags: `(flags_u32 & ~0x00000010) === 0`. Animation (`0x02`) must be zero in animated-WebP output (confirms `anim:false` enforcement).

---

### CF-P-7 — SHA-256 Integrity

All three local outputs: compute `shasum -a 256` on each file and compare to `X-Forkensics-SHA256` header. Any mismatch → FAIL.

---

### CF-P-9 — Hosted Worker Deploy

```bash
echo "=== CF-P-9 ==="

# Atomic 0600 creation before writing secret
(umask 077; printf 'SPIKE_SECRET=%s\n' "$SPIKE_SECRET" > "$SECRETS_TMP")

# Set flag before deploy attempt
SECRET_OR_WORKER_CREATED=true
WRANGLER_OUTPUT_FILE_PATH="$WRANGLER_OUT" \
  "$WRANGLER" deploy --secrets-file "$SECRETS_TMP"
WORKER_DEPLOYED=true
rm -f "$SECRETS_TMP"

# targets[0] is the URL string directly (§4.7)
WORKER_URL=$(jq -r 'select(.type == "deploy") | .targets[0] // empty' "$WRANGLER_OUT" \
  | head -1)
rm -f "$WRANGLER_OUT"
[ -n "$WORKER_URL" ] \
  || { echo "FAIL CF-P-9: Worker URL not found in WRANGLER_OUTPUT_FILE_PATH output"; exit 1; }
echo "Worker URL: $WORKER_URL"

STATUS=$(worker_api_status) || { echo "FAIL CF-P-9: worker_api_status error"; exit 1; }
[ "$STATUS" = "exists" ] \
  || { echo "FAIL CF-P-9: Worker not found via API after deploy (status: $STATUS)"; exit 1; }

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

### CF-P-8 — Worker CPU Budget Gate (executes after CF-P-9)

CF-P-8 pauses for the operator to record CPU analytics and enforces the threshold before continuing. Missing or ambiguous analytics → INCONCLUSIVE → FAIL.

```bash
echo "=== CF-P-8 ==="
echo "[CF-P-8] Open: dash.cloudflare.com/$CF_ACCOUNT_ID/workers/services/view/$WORKER/production/metrics"
echo "[CF-P-8] Find the CPU time per invocation for the CF-P-9 JPEG request."
echo "[CF-P-8] If analytics unavailable after 5 minutes, enter 'INCONCLUSIVE'."
echo "[CF-P-8] Enter observed CPU time in milliseconds (number) or 'INCONCLUSIVE':"
read -r CPU_MS_INPUT

if [ "$CPU_MS_INPUT" = "INCONCLUSIVE" ]; then
  echo "FAIL CF-P-8: Analytics unavailable — INCONCLUSIVE prevents PASS"; exit 1
fi

[[ "$CPU_MS_INPUT" =~ ^[0-9]+(\.[0-9]+)?$ ]] \
  || { echo "FAIL CF-P-8: Non-numeric input '$CPU_MS_INPUT'"; exit 1; }

if (( $(printf '%s < %s\n' "$CPU_MS_INPUT" "$CPU_LIMIT_MS" | bc -l) )); then
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
STATUS=$(key_status "display/fixture-exif.jpg.webp") \
  || { echo "FAIL CF-P-11: key_status error"; exit 1; }
[ "$STATUS" = "exists" ] || { echo "FAIL CF-P-11: JPEG display key absent"; exit 1; }
# --remote required in Wrangler 4
"$WRANGLER" r2 object get "$BUCKET/display/fixture-exif.jpg.webp" \
  --file cf_p11_verify.webp --remote
[ "$(shasum -a 256 cf_p11_verify.webp | awk '{print $1}')" = "$SHA_P9" ] \
  || { echo "FAIL CF-P-11: SHA mismatch"; exit 1; }
echo "PASS CF-P-11"
```

---

### CF-P-12 — Cleanup

```bash
echo "=== CF-P-12 ==="

"$WRANGLER" delete "$WORKER" --force
STATUS=$(worker_api_status) || { echo "FAIL CF-P-12: worker_api_status error"; exit 1; }
[ "$STATUS" = "absent" ] || { echo "FAIL CF-P-12: Worker still deployed"; exit 1; }
WORKER_DEPLOYED=false; SECRET_OR_WORKER_CREATED=false

for KEY in \
  "spike/fixture-exif.jpg" \
  "spike/fixture-static-icc-xmp.webp" \
  "spike/fixture-animated.webp" \
  "spike/fixture-oversized-px.jpg" \
  "spike/fixture-oversized.jpg" \
  "display/fixture-exif.jpg.webp" \
  "display/fixture-static-icc-xmp.webp" \
  "display/fixture-animated.webp" \
  "display/fixture-oversized.jpg.webp" \
  "display/fixture-oversized-px.jpg.webp"; do
  # --remote required in Wrangler 4
  "$WRANGLER" r2 object delete "$BUCKET/$KEY" --remote 2>/dev/null || true
  STATUS=$(key_status "$KEY") || { echo "FAIL CF-P-12: key_status error for $KEY"; exit 1; }
  [ "$STATUS" = "absent" ] || { echo "FAIL CF-P-12: Key $KEY still present"; exit 1; }
done

"$WRANGLER" r2 bucket delete "$BUCKET"
STATUS=$(bucket_api_status) || { echo "FAIL CF-P-12: bucket_api_status error"; exit 1; }
[ "$STATUS" = "absent" ] || { echo "FAIL CF-P-12: Bucket still present"; exit 1; }
BUCKET_MUTATION_ATTEMPTED=false; BUCKET_CREATED=false
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
// src/index.ts — forkensics-image-spike Rev 8 — SPIKE ONLY

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

    // Read 1: head-only — no body stream opened
    const head = await env.BUCKET.head(key);
    if (!head) return new Response("Not found", { status: 404 });
    const etag = head.etag;
    if (head.size > MAX_INPUT_BYTES) {
      return new Response(`Input too large: ${head.size}`, { status: 422 });
    }

    // Read 2: conditional get → info (free)
    const infoObject = await env.BUCKET.get(key, { onlyIf: { etagMatches: etag } });
    if (!infoObject || !("body" in infoObject) || !infoObject.body) {
      return new Response("Input changed between reads", { status: 409 });
    }
    // Use inferred type from generated Env — no `as` assertion
    const info = await env.IMAGES.info(infoObject.body);
    console.log(`info.format raw: ${JSON.stringify(info.format)}`);

    const normalizedFormat = FORMAT_ALIAS_MAP[String(info.format).toLowerCase()] ?? null;
    if (!normalizedFormat || !ACCEPTED_FORMATS.has(normalizedFormat)) {
      return new Response(`Unsupported format: ${info.format}`, { status: 422 });
    }
    if (info.width * info.height > MAX_PIXELS) {
      return new Response(`Pixel area ${info.width * info.height} > ${MAX_PIXELS}`, { status: 422 });
    }
    // fileSize check: use generated type field directly if present — no cast
    // Phase 2 artifact lock confirms whether this block is present or absent
    // based on wrangler types output.
    // [fileSize check — resolved during Phase 2 per generated types]

    // Read 3: conditional get → transform
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

## §10 Blocker Resolution Table

### Rev 5 → Rev 6

| # | Blocker | Resolution |
|---|---------|------------|
| B-1 | Account ID placeholder | **RESOLVED** — `1dd6ede816fa36a5a824a6e21f82ad7b` (Dashboard URL 2026-08-15) |
| B-2 | Phase 1 contradiction | Phase 1 explicitly authorizes local artifact creation; prohibits cloud ops |
| B-3 | Wrangler not account-pinned | `export CLOUDFLARE_ACCOUNT_ID="$CF_ACCOUNT_ID"` at startup |
| B-4 | `wrangler deploy --json` unsupported | `WRANGLER_OUTPUT_FILE_PATH` JSONL |
| B-5 | `worker_deployed()` unreliable | Workers API `GET /workers/scripts/{name}` — 200/404/other |
| B-6 | Cleanup fails open; flags after success | `SECRET_OR_WORKER_CREATED=true` before attempt; three-state verifiers |
| B-7 | 15.5 MP policy untested | `fixture-oversized-px.jpg`; Tests A/B in CF-P-4; §5.6 Vitest |
| B-8 | Fixture preconditions not proven | `generate-fixtures.sh` verifies via exiftool before upload |
| B-9 | `as` casts bypass generated type | No `as` assertions; fileSize block conditional on generated types |
| B-10 | CF-P-8 informational | `read -r CPU_MS_INPUT`; `INCONCLUSIVE` → FAIL; threshold enforced |
| AH-1 | Read 1 opens body stream | `BUCKET.head(key)` for Read 1 |
| AH-2 | `.dev.vars` not gitignore-verified | Preflight: `git check-ignore -q .dev.vars` |
| AH-3 | Bucket list substring grep | `bucket_api_status()` via CF API exact error-code match |
| AH-4 | Vitest matrix too narrow | §5 expanded to full matrix |

### Rev 6 → Rev 7

| # | Blocker | Resolution |
|---|---------|------------|
| C-1 | `.targets[0].url` wrong shape | Changed to `.targets[0]` (URL string directly) |
| C-2 | ETag race tests wrong after `head()` | §5.1 first `get()` metadata-only; §5.2 first body, second metadata-only; call-count assertions |
| C-3 | `3101×5000 = 15,505,000` not 15,500,001 | `3100×5000 = 15,500,000` (pass); `2739×5659 = 15,500,001` (fail) |
| C-4 | `case "$(fn)"` swallows failures | Helpers return 0/1 + "error" string; callers capture + `||` check + default branch |
| C-5 | Flag too late; missing display keys | `BUCKET_MUTATION_ATTEMPTED=true` before create; oversized display keys added |
| C-6 | `grep "enabled"` matches "not enabled" | CF API `/domains/managed` with exact `case` on `result.enabled` |
| M-1 | `.dev.vars` brief wide-open mode | `(umask 077; printf ... > .dev.vars)` |
| M-2 | "Bill must insert" sentence | Removed |
| M-3 | Claude Phase 1 row ⬜ | Updated to ✅ |

### Rev 7 → Rev 8

| # | Blocker | Resolution |
|---|---------|------------|
| D-1 | `--remote` missing from all `r2 object` commands | Added `--remote` to every `wrangler r2 object put/get/delete` in `key_status`, CF-P-3, EXIT cleanup, CF-P-11, CF-P-12; documented in §4.8 |
| D-2 | Dev-URL API endpoint wrong (`/dev-url`) | Changed to `/r2/buckets/$BUCKET/domains/managed` per CF API docs |
| D-3 | Pixel fixture doesn't prove byte-size gate bypassed | `generate-fixtures.sh` now asserts `PIXEL_SIZE <= 10,485,760` in addition to pixel area; authoritative shell snippet in CF-P-3; fixture table updated |
| D-4 | `assert_exact_ct` accepts superset values | Strip field name, strip params (`cut -d';' -f1`), normalize case/whitespace, compare exactly to `"image/webp"`; `assert_size_header` restored with `<= 5,242,880` ceiling check; Test E now calls `assert_size_header` |
| H-1 | `worker_api_status` stores downloaded Worker body | Changed to `-o /dev/null -w "%{http_code}"` — captures HTTP status code only |

---

*Proposal Rev 8 — 2026-08-15 — awaiting Codex and Bill Phase 1 sign-off*
