#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Swift Testing ships with these CLT; XCTest requires the full Xcode install.
exec "$PROJECT_ROOT/Scripts/swift.sh" test --disable-xctest --enable-swift-testing "$@"
