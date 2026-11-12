#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
MODE="${1:-adhoc}"
if [[ "$MODE" != "adhoc" && "$MODE" != "--unsigned" ]]; then
    echo 'Usage: Scripts/build.sh [--unsigned] (default: existing local ad-hoc signing)' >&2
    exit 2
fi
CONFIGURATION="${CONFIGURATION:-release}"
"$PROJECT_ROOT/Scripts/swift.sh" build --configuration "$CONFIGURATION" --product Wombat
BIN_PATH="$("$PROJECT_ROOT/Scripts/swift.sh" build --configuration "$CONFIGURATION" --show-bin-path)"
mkdir -p "$PROJECT_ROOT/build/products.noindex"
python3 "$PROJECT_ROOT/Scripts/stage-bundle.py" "$BIN_PATH/Wombat" "$PROJECT_ROOT/build/products.noindex/Wombat.app" "$MODE"
