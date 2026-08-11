#!/usr/bin/env bash
# Double-click this file in Finder to run the full V3 suite in Terminal.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export PATH="/usr/local/bin:/opt/homebrew/bin:$HOME/.supabase/bin:$HOME/Library/Application Support/Supabase/bin:$PATH"
bash "$SCRIPT_DIR/run_v3_suite.sh"
