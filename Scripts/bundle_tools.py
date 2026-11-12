"""Project-local macOS bundle operations. Never signs or changes OS trust settings."""
import ctypes
import datetime
import fcntl
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import sqlite3
import stat
import subprocess
import time
import uuid

BUNDLE_ID = 'local.wombat.app'
DATA_ROOT = Path.home()/'Library/Application Support/Wombat'


def command(args):
    result = subprocess.run([str(x) for x in args], capture_output=True, text=True, timeout=30)
    if result.returncode:
        raise RuntimeError('Command failed: '+str(args[0])+': '+(result.stderr or result.stdout).strip())
    return result.stdout+result.stderr


def inspect_bundle(path, verify=True):
    path = Path(path).absolute()
    if path.is_symlink() or path.suffix != '.app' or not path.is_dir():
        raise RuntimeError('Expected a real .app directory: '+str(path))
    info_path = path/'Contents/Info.plist'
    executable = path/'Contents/MacOS/Wombat'
    if info_path.is_symlink() or executable.is_symlink() or not executable.is_file():
        raise RuntimeError('Unsafe or incomplete bundle: '+str(path))
    with info_path.open('rb') as source:
        info = plistlib.load(source)
    if info.get('CFBundleIdentifier') != BUNDLE_ID or info.get('CFBundleExecutable') != 'Wombat' or info.get('CFBundlePackageType') != 'APPL':
        raise RuntimeError('Unexpected app identity: '+str(path))
    if not os.access(executable, os.X_OK):
        raise RuntimeError('App executable is not executable')
    result = {'path': str(path), 'bundleIdentifier': BUNDLE_ID, 'version': info.get('CFBundleShortVersionString'),
              'build': info.get('CFBundleVersion'), 'agent': info.get('LSUIElement') is True}
    if verify:
        command(['/usr/bin/codesign', '--verify', '--deep', '--strict', path])
        signature = command(['/usr/bin/codesign', '-d', '--verbose=4', '-r', '-', path])
        for field, pattern in [('cdhash', r'^CDHash=(.+)$'), ('team', r'^TeamIdentifier=(.+)$'),
                               ('requirement', r'^# designated => (.+)$')]:
            match = re.search(pattern, signature, re.MULTILINE)
            result[field] = match.group(1) if match else None
        result['adHoc'] = 'Signature=adhoc' in signature
        identifiers = re.findall(r'^Identifier=(.*)$', signature, re.MULTILINE)
        if identifiers != [BUNDLE_ID]:
            raise RuntimeError('Signature has unexpected identifier')
    return result


def copy_bundle(source, destination):
    command(['/usr/bin/ditto', source, destination])


def atomic_swap(first, second):
    """Same-volume atomic directory exchange, available on macOS (RENAME_SWAP)."""
    library = ctypes.CDLL('/usr/lib/libSystem.B.dylib', use_errno=True)
    result = library.renamex_np(os.fsencode(first), os.fsencode(second), ctypes.c_uint(2))
    if result != 0:
        raise OSError(ctypes.get_errno(), 'Atomic bundle exchange failed')


def pid_path(pid):
    library = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
    buffer = ctypes.create_string_buffer(4096)
    if library.proc_pidpath(int(pid), buffer, len(buffer)) <= 0:
        return None
    return Path(os.fsdecode(buffer.value))


def running_instances():
    lines = subprocess.check_output(['/bin/ps', '-axo', 'uid=,pid=,comm='], text=True).splitlines()
    found = []
    for line in lines:
        parts = line.strip().split(None, 2)
        if len(parts) != 3 or int(parts[0]) != os.geteuid() or not parts[2].endswith('/Contents/MacOS/Wombat'):
            continue
        pid = int(parts[1]); path = pid_path(pid)
        if path is None or path.name != 'Wombat':
            continue
        bundle = path.parent.parent.parent
        try:
            identity = inspect_bundle(bundle, verify=False)
        except (OSError, ValueError, RuntimeError):
            continue
        if identity['bundleIdentifier'] == BUNDLE_ID:
            found.append({'pid': pid, 'executable': str(path), 'bundle': str(bundle)})
    return found


def stop_instances(instances, timeout=10):
    for instance in instances:
        if pid_path(instance['pid']) == Path(instance['executable']):
            try: os.kill(instance['pid'], signal.SIGTERM)
            except ProcessLookupError: pass
    end = time.monotonic()+timeout
    while time.monotonic() < end:
        remaining = [x for x in instances if pid_path(x['pid']) == Path(x['executable'])]
        if not remaining:
            return
        time.sleep(0.05)
    raise RuntimeError('Wombat did not exit cleanly; installation aborted. No force-kill was used.')


def acquire_install_lock(data_root=DATA_ROOT):
    data_root.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd = os.open(data_root/'instance.lock', os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    try:
        info = os.fstat(fd)
        if info.st_uid != os.geteuid() or not stat.S_ISREG(info.st_mode):
            raise RuntimeError('Unsafe instance lock')
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        os.fchmod(fd, 0o600)
        return fd
    except BaseException:
        os.close(fd)
        raise


def database_state(connection):
    if connection.execute('PRAGMA integrity_check').fetchone()[0] != 'ok':
        raise RuntimeError('Statistics integrity check failed; existing data was not replaced')
    state = connection.execute('SELECT first,last,received,sent,seconds FROM recording WHERE id=1').fetchone()
    expected = state[2:4] if state else (0, 0)
    for table in ['minute_usage', 'hour_usage']:
        total = connection.execute('SELECT COALESCE(SUM(received),0),COALESCE(SUM(sent),0) FROM '+table).fetchone()
        if total != expected:
            raise RuntimeError('Statistics rollups disagree; existing data was not replaced')
    return state


def backup_statistics(data_root=DATA_ROOT):
    data_root = Path(data_root).absolute()
    source = data_root/'usage.sqlite'
    try:
        data_root.lstat()
    except FileNotFoundError:
        return None
    root_fd = _private_directory(data_root)
    try:
        try:
            source_fd = os.open('usage.sqlite', os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC, dir_fd=root_fd)
        except FileNotFoundError:
            return None
        try:
            info = os.fstat(source_fd)
            if info.st_uid != os.geteuid() or not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
                raise RuntimeError('Unsafe statistics source')
            try:
                os.mkdir('Backups', mode=0o700, dir_fd=root_fd)
            except FileExistsError:
                pass
            folder = data_root/'Backups'
            folder_fd = _private_directory('Backups', dir_fd=root_fd)
            try:
                target = folder/('usage-install-'+datetime.datetime.now().strftime('%Y%m%d-%H%M%S')+'-'+uuid.uuid4().hex[:8]+'.sqlite')
                # Precreate privately and exclusively before SQLite writes any data.
                target_fd = os.open(target.name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
                                    0o600, dir_fd=folder_fd)
                try:
                    try:
                        os.fchmod(target_fd, 0o600)
                    finally:
                        os.close(target_fd)
                    # SQLite online backup, never a raw live copy of a database/journal pair.
                    with sqlite3.connect(source.as_uri()+'?mode=ro', uri=True, timeout=10) as old, \
                         sqlite3.connect(target.as_uri()+'?mode=rw', uri=True) as new:
                        old.backup(new)
                        state = database_state(new)
                except BaseException:
                    os.unlink(target.name, dir_fd=folder_fd)
                    raise
            finally:
                os.close(folder_fd)
        finally:
            os.close(source_fd)
    finally:
        os.close(root_fd)
    return {'path': str(target), 'recording': state, 'integrity': 'ok', 'rollups_equal': True}


def _private_directory(path, dir_fd=None):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=dir_fd)
    try:
        info = os.fstat(fd)
        if info.st_uid != os.geteuid() or not stat.S_ISDIR(info.st_mode):
            raise RuntimeError('Unsafe statistics directory')
        os.fchmod(fd, 0o700)
        return fd
    except BaseException:
        os.close(fd)
        raise


def installation_info(bundle):
    info = inspect_bundle(bundle)
    if int(str(info['build']).split('.')[0]) < 5:
        return {'loginItemState': 'unknownLegacyBuild'}
    output = subprocess.check_output([str(Path(bundle)/'Contents/MacOS/Wombat'), '--installation-info'], text=True, timeout=5)
    return json.loads(output)
