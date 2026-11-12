#!/bin/bash
# Use Apple's installed Swift. Work around a known, locally observed CLT overlay
# collision without modifying anything in /Library/Developer or installing tools.
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SWIFT_COMPILER="$(xcrun --find swiftc)"
SWIFT_USR="$(dirname "$(dirname "$SWIFT_COMPILER")")"
SWIFT_INCLUDE="$SWIFT_USR/include/swift"
AUTO_MODULE="$SWIFT_INCLUDE/module.modulemap"
EXPLICIT_MODULE="$SWIFT_INCLUDE/bridging.modulemap"
OVERLAY_PATH=''
if [[ -f "$AUTO_MODULE" && -f "$EXPLICIT_MODULE" ]] &&
   /usr/bin/grep -q 'module SwiftBridging' "$AUTO_MODULE" &&
   /usr/bin/grep -q 'module SwiftBridging' "$EXPLICIT_MODULE"; then
    OVERLAY_DIR="$PROJECT_ROOT/.build/toolchain"
    mkdir -p "$OVERLAY_DIR"
    /usr/bin/python3 - "$OVERLAY_DIR" "$AUTO_MODULE" <<'PY'
import json
import sys
from pathlib import Path
directory = Path(sys.argv[1])
empty = directory / 'empty.modulemap'
empty.write_text('// SwiftBridging is already defined in bridging.modulemap.\n')
(directory / 'overlay.json').write_text(json.dumps({
    'version': 0,
    'roots': [{'type': 'file', 'name': sys.argv[2], 'external-contents': str(empty)}]
}))
PY
    OVERLAY_PATH="$OVERLAY_DIR/overlay.json"
fi
# Some CLT upgrades leave Swift 5 private manifest interfaces alongside Swift 6
# public interfaces/libraries. Use clean project-local copies of the public API
# only when their compiler versions differ. Other SwiftPM files stay symlinked.
CUSTOM_PM_PATH="$(/usr/bin/python3 - "$PROJECT_ROOT/.build/toolchain/pm" "$SWIFT_USR/lib/swift/pm" <<'PY'
import re
import shutil
import sys
from pathlib import Path
target, source = map(Path, sys.argv[1:])
manifest = source / 'ManifestAPI'
def compiler_version(file):
    match = re.search(r'^// swift-compiler-version: (.+)$', file.read_text(), re.M)
    return match.group(1) if match else None
stale = any(
    public.exists() and compiler_version(private) != compiler_version(public)
    for private in manifest.glob('*.swiftmodule/*.private.swiftinterface')
    for public in [private.with_name(private.name.replace('.private.', '.'))]
)
if stale:
    target.mkdir(parents=True, exist_ok=True)
    for entry in source.iterdir():
        out = target / entry.name
        if entry.name != 'ManifestAPI':
            if not out.exists(): out.symlink_to(entry)
            continue
        out.mkdir(exist_ok=True)
        for module in entry.iterdir():
            dst = out / module.name
            if module.suffix == '.swiftmodule':
                dst.mkdir(exist_ok=True)
                for file in module.iterdir():
                    if '.private.' not in file.name:
                        copy = dst / file.name
                        if not copy.exists() or copy.read_bytes() != file.read_bytes():
                            shutil.copy2(file, copy)
            elif not dst.exists(): dst.symlink_to(module)
    print(target)
PY
)"
if [[ -n "$CUSTOM_PM_PATH" ]]; then
    export SWIFTPM_CUSTOM_LIBS_DIR="$CUSTOM_PM_PATH"
fi
cd "$PROJECT_ROOT"
SUBCOMMAND="$1"
shift
if [[ -n "$OVERLAY_PATH" ]]; then
    set -- -Xswiftc -vfsoverlay -Xswiftc "$OVERLAY_PATH" "$@"
fi
exec swift "$SUBCOMMAND" "$@"
