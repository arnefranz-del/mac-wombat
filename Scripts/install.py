#!/usr/bin/env python3
"""Local Wombat install/update. Does not sign, activate login items, or change trust/index settings."""
import argparse
import datetime
import json
import os
from pathlib import Path
import shutil
import sys
import subprocess
import tempfile
import time
import uuid

from bundle_tools import (DATA_ROOT, acquire_install_lock, atomic_swap, backup_statistics, command,
                          copy_bundle, inspect_bundle, installation_info, running_instances, stop_instances)


def replace_bundle(candidate, destination, verify=inspect_bundle):
    """Rollback the exchange if post-copy validation fails. Never touches statistics."""
    existed = destination.exists()
    if existed: atomic_swap(candidate, destination)
    else: os.rename(candidate, destination)
    try:
        return verify(destination)
    except BaseException:
        if existed: atomic_swap(candidate, destination)
        else: os.rename(destination, candidate)
        raise


def launch_and_confirm(destination):
    command(['/usr/bin/open', '-a', destination])
    deadline = time.monotonic()+8
    expected = str(destination/'Contents/MacOS/Wombat')
    stable_since = None; confirmed_pid = None
    while time.monotonic() < deadline:
        running = running_instances()
        matching = [x for x in running if x['executable'] == expected]
        if len(matching) == 1 and len(running) == 1:
            if confirmed_pid != matching[0]['pid']:
                confirmed_pid = matching[0]['pid']; stable_since = time.monotonic()
            elif time.monotonic()-stable_since >= 1:
                return matching[0]
        else: stable_since = None; confirmed_pid = None
        time.sleep(0.1)
    raise RuntimeError('App was not confirmed running exactly once at the installed path')


def autostart_notice(before, after):
    if before != 'enabled' or after == 'enabled':
        return None
    settings = 'Öffne Wombat → Einstellungen → Allgemein.'
    approval = 'Wähle „Anmeldeobjekte öffnen“ und erteile die macOS-Freigabe.'
    if after == 'requiresApproval':
        return f'Autostart wartet auf die macOS-Freigabe. {settings} {approval}'
    return (f'Autostart war vor dem Austausch aktiv. {settings} Aktiviere „Beim Anmelden starten“ erneut. '
            f'Falls macOS eine Freigabe verlangt: {approval}')


def install(source, destination, data_root=DATA_ROOT, dry_run=False, launch=True):
    source = source.absolute(); destination = destination.absolute()
    source_info = inspect_bundle(source)
    if destination.name != 'Wombat.app' or destination.is_symlink():
        raise RuntimeError('Destination must be a real Wombat.app path')
    if source == destination:
        raise RuntimeError('Source and destination must differ')
    if not destination.parent.is_dir() or not os.access(destination.parent, os.W_OK):
        raise RuntimeError('Destination folder is not writable; no sudo or permissions change will be attempted')
    current = inspect_bundle(destination) if destination.exists() else None
    if current and (current['adHoc'], current['team']) != (source_info['adHoc'], source_info['team']):
        raise RuntimeError('Signing identity/method would change; explicit review is required')
    report = {'source': source_info, 'destination': str(destination), 'previous': current,
              'dry_run': dry_run, 'login_item_changed': False, 'statistics_file': str(data_root/'usage.sqlite')}
    if dry_run:
        report['running_instances'] = running_instances()
        return report
    if current and current['cdhash'] == source_info['cdhash']:
        report['unchanged'] = True
        report['installation_info'] = installation_info(destination)
        if launch:
            running = running_instances()
            if len(running) == 1 and Path(running[0]['bundle']) == destination:
                report['running_instance'] = running[0]
                return report  # Idempotent install must not steal focus/reopen UI.
            others = [x for x in running if Path(x['bundle']) != destination]
            if others:
                report['live_backup'] = backup_statistics(data_root)
                stop_instances(others)
            report['running_instance'] = launch_and_confirm(destination)
        return report
    parent = Path(tempfile.mkdtemp(prefix='.Wombat-install-', dir=destination.parent))
    candidate = parent/'Wombat.app'; lock = None; before = []
    try:
        copy_bundle(source, candidate)
        copied = inspect_bundle(candidate)
        if copied['cdhash'] != source_info['cdhash']:
            raise RuntimeError('Staged signature differs from source')
        if current:
            try:
                report['login_item_before'] = installation_info(destination).get('loginItemState', 'unknown')
            except (OSError, RuntimeError, ValueError, subprocess.SubprocessError):
                report['login_item_before'] = 'unknown'
        report['live_backup'] = backup_statistics(data_root)
        before = running_instances()
        report['stopped_instances'] = before
        stop_instances(before)
        lock = acquire_install_lock(data_root)
        if running_instances():
            raise RuntimeError('Another Wombat started during installation; retry after closing it')
        # This second backup includes the old app's final synchronous flush.
        report['final_backup'] = backup_statistics(data_root)
        if current:
            folder = data_root/'InstallBackups.noindex'; folder.mkdir(mode=0o700, exist_ok=True)
            backup = folder/('Wombat-'+datetime.datetime.now().strftime('%Y%m%d-%H%M%S')+'-'+uuid.uuid4().hex[:8]+'.app')
            copy_bundle(destination, backup); inspect_bundle(backup)
            report['previous_bundle_backup'] = str(backup)
        def verify_installed(bundle):
            checked = inspect_bundle(bundle)
            report['installation_info'] = installation_info(bundle)
            return checked
        report['installed'] = replace_bundle(candidate, destination, verify=verify_installed)
        notice = autostart_notice(report.get('login_item_before'), report['installation_info'].get('loginItemState'))
        if notice:
            report['notice'] = notice
    except BaseException:
        if lock is not None: os.close(lock); lock = None
        # A failed update must not leave a previously running monitor stopped.
        # Post-copy failures have already rolled the bundle back above.
        restart = destination if current else (Path(before[0]['bundle']) if before else None)
        if restart and restart.exists() and before and not running_instances():
            try:
                inspect_bundle(restart)
                command(['/usr/bin/open', '-a', restart])
            except Exception:
                pass  # Keep the original install error; backups are retained.
        raise
    finally:
        if lock is not None: os.close(lock)
        shutil.rmtree(parent)
    if launch:
        try:
            report['running_instance'] = launch_and_confirm(destination)
            return report
        except Exception:
            pass
        if report.get('previous_bundle_backup'):
            restored = install(Path(report['previous_bundle_backup']), destination, data_root=data_root, launch=False)
            command(['/usr/bin/open', '-a', destination])
            message = 'Updated app did not stay running exactly once; previous bundle restored. Statistics were retained.'
            notice = autostart_notice(report.get('login_item_before'), restored['installation_info'].get('loginItemState'))
            raise RuntimeError(f'{message} {notice}' if notice else message)
        raise RuntimeError('Installed app was not confirmed running exactly once. Statistics backups are retained; app remains available for diagnosis.')
    return report


def main():
    root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, default=root/'build/products.noindex/Wombat.app')
    parser.add_argument('--destination', type=Path, default=Path('/Applications/Wombat.app'))
    parser.add_argument('--dry-run', action='store_true')
    parser.add_argument('--no-launch', action='store_true')
    args = parser.parse_args()
    try:
        result = install(args.source, args.destination, dry_run=args.dry_run, launch=not args.no_launch)
        print(json.dumps(result, indent=2))
        if notice := result.get('notice'):
            print(notice, file=sys.stderr)
    except Exception as error:
        parser.exit(1, 'Installation stopped: '+str(error)+'\n')


if __name__ == '__main__': main()
