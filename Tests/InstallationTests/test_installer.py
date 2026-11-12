import contextlib
import fcntl
import io
import json
import os
from pathlib import Path
import plistlib
import signal
import sqlite3
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2]/'Scripts'))
from bundle_tools import (acquire_install_lock, atomic_swap, backup_statistics, database_state,
                          inspect_bundle, stop_instances)
from install import autostart_notice, main, replace_bundle, install


class InstallationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
    def tearDown(self):
        self.temporary.cleanup()
    def marker(self, name, text):
        path = self.root/name; path.mkdir(); (path/'marker').write_text(text); return path
    def test_atomic_update_exchanges_complete_directories(self):
        candidate = self.marker('candidate.app', 'new'); destination = self.marker('Wombat.app', 'old')
        result = replace_bundle(candidate, destination, verify=lambda p: (p/'marker').read_text())
        self.assertEqual(result, 'new')
        self.assertEqual((candidate/'marker').read_text(), 'old')
    def test_failed_post_copy_verification_rolls_back_update(self):
        candidate = self.marker('candidate.app', 'new'); destination = self.marker('Wombat.app', 'old')
        def reject(path): raise RuntimeError('forced verification failure')
        with self.assertRaises(RuntimeError): replace_bundle(candidate, destination, verify=reject)
        self.assertEqual((destination/'marker').read_text(), 'old')
        self.assertEqual((candidate/'marker').read_text(), 'new')
    def test_first_install_is_reversible_on_verification_failure(self):
        candidate = self.marker('candidate.app', 'new'); destination = self.root/'Wombat.app'
        def reject(path): raise RuntimeError('forced verification failure')
        with self.assertRaises(RuntimeError): replace_bundle(candidate, destination, verify=reject)
        self.assertFalse(destination.exists())
        self.assertEqual((candidate/'marker').read_text(), 'new')
    def test_wrong_bundle_identity_and_symlinks_are_rejected(self):
        app = self.root/'Other.app'; (app/'Contents/MacOS').mkdir(parents=True)
        (app/'Contents/MacOS/Wombat').write_text('dummy'); os.chmod(app/'Contents/MacOS/Wombat', 0o700)
        (app/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'unrelated.project', 'CFBundleExecutable':'Wombat'}))
        with self.assertRaises(RuntimeError): inspect_bundle(app, verify=False)
        link = self.root/'Wombat.app'; link.symlink_to(app)
        with self.assertRaises(RuntimeError): inspect_bundle(link, verify=False)
    def make_database(self):
        path = self.root/'usage.sqlite'
        with sqlite3.connect(path) as db:
            db.execute('CREATE TABLE recording (id INTEGER PRIMARY KEY, first REAL,last REAL,received INTEGER,sent INTEGER,seconds REAL)')
            for name in ['minute_usage','hour_usage']:
                db.execute('CREATE TABLE '+name+' (received INTEGER,sent INTEGER)')
                db.execute('INSERT INTO '+name+' VALUES (42,17)')
            db.execute('INSERT INTO recording VALUES (1,1,2,42,17,1)')
        return path
    def test_signature_identifier_must_match_exactly_once(self):
        app = self.root/'Wombat.app'; (app/'Contents/MacOS').mkdir(parents=True)
        executable = app/'Contents/MacOS/Wombat'; executable.write_text('fixture'); executable.chmod(0o700)
        (app/'Contents/Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier':'local.wombat.app', 'CFBundleExecutable':'Wombat', 'CFBundlePackageType':'APPL'}))
        for identifiers in ['Identifier=local.wombat.app.evil', 'Identifier=prefix.local.wombat.app',
                            'Identifier=local.wombat.app\nIdentifier=local.wombat.app', 'TeamIdentifier=local.wombat.app']:
            with self.subTest(identifier=identifiers), patch('bundle_tools.command', return_value=identifiers):
                with self.assertRaises(RuntimeError): inspect_bundle(app)
        with patch('bundle_tools.command', return_value='Identifier=local.wombat.app\nSignature=adhoc\n'):
            self.assertTrue(inspect_bundle(app)['adHoc'])

    def test_backup_is_private_before_sqlite_opens_and_repairs_directory_modes(self):
        source = self.make_database(); before = source.read_bytes(); source.chmod(0o644)
        folder = self.root/'Backups'; folder.mkdir(); folder.chmod(0o755); self.root.chmod(0o755)
        connect = sqlite3.connect; observed = []
        def check_private(database, *args, **kwargs):
            if 'mode=rw' in str(database):
                backups = list(folder.glob('*.sqlite'))
                self.assertEqual(len(backups), 1)
                observed.append(backups[0].stat().st_mode & 0o777)
                self.assertEqual(observed[-1], 0o600)
                self.assertEqual(folder.stat().st_mode & 0o777, 0o700)
                self.assertEqual(self.root.stat().st_mode & 0o777, 0o700)
            return connect(database, *args, **kwargs)
        old_umask = os.umask(0o022)
        try:
            with patch('bundle_tools.sqlite3.connect', side_effect=check_private): backup_statistics(self.root)
        finally: os.umask(old_umask)
        self.assertEqual(observed, [0o600])
        self.assertEqual(source.read_bytes(), before)
        self.assertEqual(source.stat().st_mode & 0o777, 0o644)

    def test_backup_rejects_linked_root_and_backup_folder(self):
        self.make_database()
        link = self.root/'linked-root'; link.symlink_to(self.root, target_is_directory=True)
        with self.assertRaises((OSError, RuntimeError)): backup_statistics(link)
        self.assertFalse((self.root/'Backups').exists())
        real = self.root/'real-backups'; real.mkdir(); real.chmod(0o755)
        folder = self.root/'Backups'; folder.symlink_to(real, target_is_directory=True)
        with self.assertRaises((OSError, RuntimeError)): backup_statistics(self.root)
        self.assertEqual(list(real.iterdir()), [])
        self.assertEqual(real.stat().st_mode & 0o777, 0o755)

    def test_backup_rejects_linked_and_nonregular_sources(self):
        target = self.root/'sentinel'; target.write_bytes(b'fixture sentinel'); target.chmod(0o644)
        source = self.root/'usage.sqlite'
        for kind in ['symlink', 'hardlink', 'fifo']:
            with self.subTest(kind=kind):
                if kind == 'symlink': source.symlink_to(target)
                elif kind == 'hardlink': os.link(target, source)
                else: os.mkfifo(source, mode=0o600)
                with self.assertRaises((OSError, RuntimeError)): backup_statistics(self.root)
                source.unlink()
                self.assertEqual(target.read_bytes(), b'fixture sentinel')
                self.assertEqual(target.stat().st_mode & 0o777, 0o644)
                self.assertFalse((self.root/'Backups').exists())

    def test_backup_destination_collision_is_not_removed_or_overwritten(self):
        self.make_database(); folder = self.root/'Backups'; folder.mkdir()
        target = folder/'usage-install-fixture-fixedid0.sqlite'
        sentinel = self.root/'sentinel'; sentinel.write_bytes(b'existing fixture')
        for linked in [False, True]:
            with self.subTest(linked=linked):
                if linked: target.symlink_to(sentinel)
                else: target.write_bytes(b'existing fixture')
                with patch('bundle_tools.datetime.datetime') as date, patch('bundle_tools.uuid.uuid4') as identifier:
                    date.now.return_value.strftime.return_value = 'fixture'
                    identifier.return_value.hex = 'fixedid0'
                    with self.assertRaises(FileExistsError): backup_statistics(self.root)
                self.assertEqual(target.read_bytes(), b'existing fixture')
                self.assertEqual(target.is_symlink(), linked)
                self.assertEqual(sentinel.read_bytes(), b'existing fixture')
                target.unlink()

    def test_backup_rejects_directory_not_owned_by_current_user(self):
        self.make_database()
        original = os.fstat
        def foreign_owner(fd):
            info = list(original(fd)); info[4] = os.geteuid() + 1
            return os.stat_result(info)
        with patch('bundle_tools.os.fstat', side_effect=foreign_owner), patch('bundle_tools.os.fchmod') as chmod:
            with self.assertRaises(RuntimeError): backup_statistics(self.root)
            chmod.assert_not_called()
    def test_consistent_backup_preserves_totals_and_does_not_modify_source(self):
        path = self.make_database(); before = path.read_bytes()
        result = backup_statistics(self.root)
        self.assertEqual(path.read_bytes(), before)
        self.assertEqual(result['recording'][2:4], (42,17))
        with sqlite3.connect(result['path']) as backup:
            self.assertEqual(database_state(backup)[2:4], (42,17))
        self.assertEqual(Path(result['path']).stat().st_mode & 0o777, 0o600)
    def test_inconsistent_database_is_never_silently_replaced(self):
        path = self.make_database()
        with sqlite3.connect(path) as db: db.execute('UPDATE hour_usage SET received=1')
        before = path.read_bytes()
        with self.assertRaises(RuntimeError): backup_statistics(self.root)
        self.assertEqual(path.read_bytes(), before)
    def test_install_lock_is_exclusive_and_reusable_without_unlink(self):
        first = acquire_install_lock(self.root)
        try:
            with self.assertRaises(BlockingIOError): acquire_install_lock(self.root)
        finally: os.close(first)
        second = acquire_install_lock(self.root); os.close(second)
        self.assertTrue((self.root/'instance.lock').exists())
    def test_installer_never_force_kills_an_unresponsive_app(self):
        instance = {'pid':123, 'executable':'/safe/Wombat'}
        with patch('bundle_tools.pid_path', return_value=Path('/safe/Wombat')), patch('bundle_tools.os.kill') as kill:
            with self.assertRaises(RuntimeError): stop_instances([instance], timeout=0.01)
            kill.assert_called_once_with(123, signal.SIGTERM)
    def test_reused_pid_with_different_executable_is_not_signalled(self):
        with patch('bundle_tools.pid_path', return_value=Path('/other/app')), patch('bundle_tools.os.kill') as kill:
            stop_instances([{'pid':123, 'executable':'/safe/Wombat'}], timeout=0.01)
            kill.assert_not_called()
    def test_unchanged_running_install_does_not_reopen_or_stop_app(self):
        destination = self.root/'Wombat.app'; destination.mkdir()
        source = self.root/'source.app'; source.mkdir()
        identity = {'adHoc':True,'team':'not set','cdhash':'same','build':'5'}
        instance = {'pid':123,'bundle':str(destination),'executable':str(destination/'Contents/MacOS/Wombat')}
        with patch('install.inspect_bundle', return_value=identity), patch('install.installation_info', return_value={}), \
             patch('install.running_instances', return_value=[instance]), patch('install.command') as command, \
             patch('install.stop_instances') as stop:
            result = install(source, destination, data_root=self.root)
            self.assertTrue(result['unchanged'])
            command.assert_not_called(); stop.assert_not_called()


    def test_changed_autostart_has_actionable_guidance(self):
        notice = autostart_notice('enabled', 'notFound')
        self.assertIn('Wombat → Einstellungen → Allgemein', notice)
        self.assertIn('„Beim Anmelden starten“ erneut', notice)
        self.assertIn('„Anmeldeobjekte öffnen“', notice)
        for before, after in [('enabled', 'enabled'), ('notRegistered', 'notFound'), (None, 'notFound')]:
            with self.subTest(before=before, after=after):
                self.assertIsNone(autostart_notice(before, after))

    def test_pending_approval_points_directly_to_macos(self):
        notice = autostart_notice('enabled', 'requiresApproval')
        self.assertIn('wartet auf die macOS-Freigabe', notice)
        self.assertIn('„Anmeldeobjekte öffnen“', notice)
        self.assertNotIn('erneut', notice)

    def test_failed_launch_reports_reactivation_if_restored_app_needs_it(self):
        source = self.marker('source.app', 'new')
        destination = self.marker('Wombat.app', 'old')

        def identity(bundle):
            version = (bundle/'marker').read_text()
            return {'adHoc': True, 'team': 'not set', 'cdhash': version, 'build': '5'}

        states = [{'loginItemState': state} for state in ('enabled', 'notFound', 'notFound', 'notFound')]
        with patch('install.inspect_bundle', side_effect=identity), \
             patch('install.installation_info', side_effect=states), \
             patch('install.running_instances', return_value=[]), \
             patch('install.launch_and_confirm', side_effect=RuntimeError('forced start failure')), \
             patch('install.command') as command:
            with self.assertRaisesRegex(RuntimeError, 'previous bundle restored.*Beim Anmelden starten'):
                install(source, destination, data_root=self.root)
        self.assertEqual((destination/'marker').read_text(), 'old')
        command.assert_called_once_with(['/usr/bin/open', '-a', destination])

    def test_cli_keeps_json_and_prints_autostart_instruction_to_stderr(self):
        report = {'notice': autostart_notice('enabled', 'notFound')}
        stdout, stderr = io.StringIO(), io.StringIO()
        with patch('install.install', return_value=report), patch.object(sys, 'argv', ['install.py']), \
             contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            main()
        self.assertEqual(json.loads(stdout.getvalue()), report)
        self.assertEqual(stderr.getvalue().strip(), report['notice'])


if __name__ == '__main__': unittest.main()
