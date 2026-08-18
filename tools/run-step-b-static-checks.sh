#!/usr/bin/env bash
# run-step-b-static-checks.sh — Step B Phase 1 static checks (§8)
# Run from the repo root: bash tools/run-step-b-static-checks.sh
# All checks must PASS before Phase 1 is declared complete.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

PASS=0
FAIL=0
SKIP=0

ok()   { echo "  ✅  $*"; PASS=$((PASS + 1)); }
fail() { echo "  ❌  $*"; FAIL=$((FAIL + 1)); }
skip() { echo "  ⏭️   $*"; SKIP=$((SKIP + 1)); }

FILES=(
  "supabase/functions/_shared/cf.ts"
  "supabase/functions/_shared/cf.test.ts"
  "supabase/functions/upload-complete/index.ts"
  "supabase/functions/upload-complete/upload-complete.test.ts"
  "supabase/functions/upload-complete/upload-complete.integration.test.ts"
  "supabase/functions/upload-cleanup-worker/index.ts"
  "supabase/functions/upload-cleanup-worker/upload-cleanup-worker.test.ts"
)

echo ""
echo "════════════════════════════════════════════════"
echo "  Step B — Phase 1 Static Checks"
echo "════════════════════════════════════════════════"
echo ""

# ── deno check ───────────────────────────────────────────────────────────────
echo "── deno check ──"
for f in "${FILES[@]}"; do
  if deno check "$f" 2>&1; then
    ok "deno check $f"
  else
    fail "deno check $f"
  fi
done
echo ""

# ── deno fmt --check ─────────────────────────────────────────────────────────
echo "── deno fmt --check ──"
for f in "${FILES[@]}"; do
  if deno fmt --check "$f" 2>&1; then
    ok "deno fmt --check $f"
  else
    fail "deno fmt --check $f"
    echo "    Fix with: deno fmt $f"
  fi
done
echo ""

# ── deno lint ────────────────────────────────────────────────────────────────
echo "── deno lint ──"
for f in "${FILES[@]}"; do
  if deno lint "$f" 2>&1; then
    ok "deno lint $f"
  else
    fail "deno lint $f"
  fi
done
echo ""

# ── config.toml section check ────────────────────────────────────────────────
echo "── config.toml verify_jwt = false ──"
if grep -A1 '\[functions.upload-cleanup-worker\]' supabase/config.toml | grep -q 'verify_jwt = false'; then
  ok "config.toml: [functions.upload-cleanup-worker] verify_jwt = false"
else
  fail "config.toml: missing [functions.upload-cleanup-worker] verify_jwt = false"
fi
echo ""

# ── gitleaks ─────────────────────────────────────────────────────────────────
echo "── gitleaks ──"
if command -v gitleaks &>/dev/null; then
  if gitleaks detect --source . --no-git 2>&1; then
    ok "gitleaks: 0 findings"
  else
    fail "gitleaks: findings detected"
  fi
else
  skip "gitleaks not found — install via: brew install gitleaks"
fi
echo ""

# ── bash -n (no new .sh files in Step B) ────────────────────────────────────
echo "── bash -n ──"
if bash -n tools/run-step-b-static-checks.sh; then
  ok "bash -n tools/run-step-b-static-checks.sh"
else
  fail "bash -n tools/run-step-b-static-checks.sh"
fi
echo ""

# ── SHA-256 ──────────────────────────────────────────────────────────────────
echo "── SHA-256 (record in §9 of Step-B-Proposal-Rev5.md) ──"
SHA_FILES=(
  "supabase/config.toml"
  "tools/run-step-b-static-checks.sh"
  "${FILES[@]}"
)
for f in "${SHA_FILES[@]}"; do
  if [[ -f "$f" ]]; then
    shasum -a 256 "$f"
  else
    fail "missing: $f"
  fi
done
echo ""

# ── Summary ──────────────────────────────────────────────────────────────────
echo "════════════════════════════════════════════════"
echo "  PASS: $PASS   FAIL: $FAIL   SKIP: $SKIP"
echo "════════════════════════════════════════════════"
if [[ $FAIL -eq 0 ]]; then
  echo "  🎉  All checks passed — ready for §9 hash recording."
else
  echo "  ⚠️   Fix all failures before Phase 1 sign-off."
fi
echo ""
