#!/usr/bin/env python3
"""Build/package a local preparation candidate; never install, sign Developer ID or upload."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import shutil
import subprocess


def run(args, **kwargs):
    return subprocess.run([str(x) for x in args], check=True, **kwargs)


def main():
    root = Path(__file__).resolve().parent.parent
    if os.environ.get('WOMBAT_HOME_LAB') == '1':
        raise SystemExit('Normal release preparation refuses WOMBAT_HOME_LAB=1. Unset it before building.')
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--arch', choices=['x86_64', 'arm64'], default=platform.machine())
    args = parser.parse_args()
    info = plistlib.loads((root/'Resources/Info.plist').read_bytes())
    label = 'Wombat-'+info['CFBundleShortVersionString']+'-build'+info['CFBundleVersion']+'-'+args.arch+'-LOCAL-PREPARATION'
    output = root/'build/release-audit'/label
    output.mkdir(parents=True, exist_ok=True)
    if (output/'Wombat.app').exists():
        raise SystemExit('Candidate already exists; preserve it and choose a new version/build before rebuilding.')
    # Separate architecture cache; prefix maps keep local source paths out of binaries.
    build = [root/'Scripts/swift.sh', 'build', '-c', 'release', '--product', 'Wombat',
             '--arch', args.arch, '--scratch-path', root/'.build'/('release-preparation-'+args.arch),
             '-Xswiftc', '-debug-prefix-map', '-Xswiftc', str(root)+'=.',
             '-Xswiftc', '-file-prefix-map', '-Xswiftc', str(root)+'=.']
    run(build, cwd=root)
    binary_dir = subprocess.check_output(build+['--show-bin-path'], cwd=root, text=True).strip()
    # The linker adds OSO object paths after the compiler's prefix maps. Remove
    # debug-only symbols from a staging copy before any final ad hoc signature.
    staging_binary = output/'Wombat-staging-executable'
    shutil.copy2(Path(binary_dir)/'Wombat', staging_binary)
    run(['/usr/bin/strip', '-S', staging_binary])
    if b'/Users/' in staging_binary.read_bytes() or b'/home/' in staging_binary.read_bytes():
        raise SystemExit('Personal path marker survived debug-symbol stripping. Packaging blocked.')
    app = output/'Wombat.app'
    run(['/usr/bin/python3', root/'Scripts/stage-bundle.py', staging_binary, app, 'adhoc'])
    staging_binary.unlink()
    binary = app/'Contents/MacOS/Wombat'
    if b'/Users/' in binary.read_bytes() or b'/home/' in binary.read_bytes():
        raise SystemExit('Personal path marker found in executable. Candidate is retained locally; packaging blocked.')
    run(['/usr/bin/codesign', '--verify', '--deep', '--strict', app])
    (output/'READ-ME-FIRST.txt').write_text(
        'LOCAL PREPARATION ONLY — NOT A PUBLIC RELEASE\n'
        'Ad hoc signed, no Developer ID, no notarization. Asset rights/license pending.\n'
        'Do not distribute or install over the production app without a separate reviewed decision.\n'
        'See Documentation/Public/INSTALLATION.md and RELEASE-CHECKLIST.md in the source preparation.\n')
    zip_path = output/(label+'.zip')
    run(['/usr/bin/ditto', '-c', '-k', '--norsrc', '--keepParent', app, zip_path])
    files = [binary, zip_path]
    (output/'SHA256SUMS.txt').write_text(''.join(hashlib.sha256(p.read_bytes()).hexdigest()+'  '+str(p.relative_to(output))+'\n' for p in files))
    metadata = {'version':info['CFBundleShortVersionString'], 'build':info['CFBundleVersion'],
        'architecture':args.arch, 'minimumMacOS':info['LSMinimumSystemVersion'],
        'swift':subprocess.check_output(['xcrun','swift','--version'],text=True).strip(),
        'sdk':subprocess.check_output(['xcrun','--show-sdk-version'],text=True).strip(),
        'scope':'mac-only', 'signing':'adhoc', 'notarized':False, 'published':False,
        'reproducibility':'Repeatable recipe; byte-identical builds are not asserted.'}
    (output/'BUILD-METADATA.json').write_text(json.dumps(metadata,indent=2)+'\n')
    print(output)


if __name__ == '__main__':
    main()
