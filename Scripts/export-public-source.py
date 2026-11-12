#!/usr/bin/env python3
"""Make an allowlisted LOCAL preview snapshot, with no Git history/private evidence."""
import hashlib
import json
from pathlib import Path
import re
import shutil
import sys

ROOT = Path(__file__).resolve().parent.parent
SCRIPTS = ['build.sh','test.sh','swift.sh','run.sh','build-icon.py','stage-bundle.py',
           'bundle_tools.py','install.py','prepare-release.py','export-public-source.py']
ROOT_FILES = ['Package.swift','.gitignore','README.md','SECURITY.md','PRIVACY.md',
              'CONTRIBUTING.md','CHANGELOG.md','LICENSE','README.de.md','ROADMAP.md']
TREES = ['Sources','Tests','Resources','Documentation/Public','Website','.github']
SUFFIXES = {'.swift','.py','.sh','.plist','.png','.jpg','.yml','.svg','.html','.css','.md','.txt','.iconset'}


def main():
    destination = ROOT/'build/release-audit/Wombat-source-LOCAL-PREVIEW'
    if destination.exists():
        raise SystemExit('Snapshot already exists; preserve/review it before creating a replacement.')
    paths = [ROOT/p for p in ROOT_FILES]
    paths += [ROOT/'Scripts'/p for p in SCRIPTS]
    for tree in TREES:
        paths += [p for p in (ROOT/tree).rglob('*') if p.is_file()
                  and p.suffix in SUFFIXES.union({''}) and not any(x.startswith('.') for x in p.relative_to(ROOT/tree).parts)]
    manifest = {}; findings = []
    for source in sorted(set(paths)):
        relative = source.relative_to(ROOT)
        if source.is_symlink() or not source.is_file():
            raise SystemExit('Missing/linked allowlist entry: '+str(relative))
        if '__pycache__' in source.parts or source.suffix == '.pyc':
            continue
        data = source.read_bytes()
        if source.suffix not in {'.png','.jpg','.icns'}:
            text = data.decode('utf-8')
            # Patterns deliberately return file/rule only, never a matching secret.
            for label, pattern in {
                'personal-path':r'/(?:Users|home)/[A-Za-z0-9_.-]+/',
                'credential-marker':r'(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-proj-[A-Za-z0-9_-]{20,}|-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY)',
            }.items():
                if re.search(pattern,text): findings.append({'file':str(relative),'rule':label})
        target = destination/relative
        target.parent.mkdir(parents=True,exist_ok=True)
        # Copy precisely the bytes that were scanned, even if the workspace changes.
        target.write_bytes(data)
        shutil.copymode(source,target)
        manifest[str(relative)] = hashlib.sha256(data).hexdigest()
    (destination/'SOURCE-MANIFEST.json').write_text(json.dumps(manifest,indent=2)+'\n')
    (destination/'PUBLICATION-BLOCKERS.txt').write_text(
        'LOCAL PREVIEW. DO NOT PUBLISH YET.\n'
        'No original Git history, private evidence, user DBs or runtime logs included.\n'
        'Automatic scans are heuristic, not proof of absence of secrets.\n')
    print(json.dumps({'files':len(manifest),'findings':findings,'snapshot':str(destination)},indent=2))
    if findings:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
