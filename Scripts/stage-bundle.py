#!/usr/bin/env python3
"""Package complete project bundle in staging, never overwrite a running bundle."""
import os
from pathlib import Path
import shutil
import sys
import tempfile
from bundle_tools import atomic_swap, command, inspect_bundle, running_instances

binary = Path(sys.argv[1]); destination = Path(sys.argv[2]); mode = sys.argv[3]
root = Path(__file__).resolve().parent.parent
if any(Path(x['bundle']) == destination for x in running_instances()):
    raise SystemExit('Build destination is running. Quit that development copy first; installed app can keep running.')
if destination.exists() or destination.is_symlink():
    inspect_bundle(destination, verify=False)
parent = Path(tempfile.mkdtemp(prefix='.Wombat-build-', dir=destination.parent))
candidate = parent/'Wombat.app'
try:
    (candidate/'Contents/MacOS').mkdir(parents=True)
    (candidate/'Contents/Resources').mkdir()
    shutil.copy2(binary, candidate/'Contents/MacOS/Wombat')
    shutil.copy2(root/'Resources/Info.plist', candidate/'Contents/Info.plist')
    shutil.copy2(root/'LICENSE', candidate/'Contents/Resources/LICENSE')
    command([sys.executable, root/'Scripts/build-icon.py', root/'Resources/AppIcon.png',
             candidate/'Contents/Resources/Wombat.icns'])
    if mode == 'adhoc':
        command(['/usr/bin/codesign', '--force', '--sign', '-', candidate])
        inspect_bundle(candidate)
    else:
        inspect_bundle(candidate, verify=False)
    if destination.exists(): atomic_swap(candidate, destination)
    else: os.rename(candidate, destination)
finally:
    shutil.rmtree(parent)
print(('Unversiegelter Kandidat' if mode == '--unsigned' else 'Lokal ad hoc signierte App')+': '+str(destination))
