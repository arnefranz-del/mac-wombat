#!/bin/bash
set -euo pipefail
APP_PATH="/Applications/Wombat.app"
if [[ ! -d "$APP_PATH" ]]; then
    echo 'Wombat ist noch nicht installiert. Zuerst Scripts/build.sh und python3 Scripts/install.py ausführen.' >&2
    exit 1
fi
open -a "$APP_PATH"
