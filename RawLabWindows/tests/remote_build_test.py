import base64
import hashlib
from unittest import mock
import re
import json
import io
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET
import zipfile


def load_module():
    path = Path(__file__).resolve().parents[1] / 'build-remote.py'
    spec = importlib.util.spec_from_file_location('remote_build', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class RumSdkArgumentsTest(unittest.TestCase):
    """远程构建默认带统计 SDK：本地有缓存就上传固定哈希的归档，否则由远端按固定地址下载"""

    def setUp(self):
        self.module = load_module()

    def test_pin_matches_the_build_rules(self):
        project = ET.parse(Path(__file__).resolve().parents[1] / 'RumSdk.targets').getroot()
        pins = [node.text for node in project.iter('RawLabRumSdkZipSha256')]
        self.assertEqual(pins, [self.module.RUM_SDK_SHA256])

    def test_offline_package_skips_the_sdk(self):
        self.assertEqual(self.module.rum_build_args(True, Path('/missing.zip'), 'C:/in'), ('-NoRumSdk', None))

    def test_missing_local_cache_lets_the_remote_download(self):
        self.assertEqual(self.module.rum_build_args(False, Path('/missing.zip'), 'C:/in'), ('', None))

    def test_cached_archive_is_verified_and_uploaded(self):
        with tempfile.TemporaryDirectory() as folder:
            archive = Path(folder) / 'sdk.zip'
            archive.write_bytes(b'vendor archive')
            self.module.RUM_SDK_SHA256 = hashlib.sha256(b'vendor archive').hexdigest()
            self.assertEqual(self.module.rum_build_args(False, archive, 'C:/RawLabBuild/incoming/1'),
                             ("-RumSdkZip 'C:/RawLabBuild/incoming/1/rum-sdk.zip'", archive))
            archive.write_bytes(b'tampered')
            with self.assertRaises(SystemExit):
                self.module.rum_build_args(False, archive, 'C:/in')

    def test_default_cache_is_in_the_main_worktree(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder).resolve()
            subprocess.run(['git', 'init', '-q', str(root)], check=True)
            self.assertEqual(self.module.rum_sdk_cache(root),
                             root / '.cache/shared/aliyun-rum/windows/0.4.4/sdk.zip')


class SourcePackageTest(unittest.TestCase):
    def test_includes_dirty_and_untracked_source_but_not_outputs_or_raws(self):
        module = load_module()
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            subprocess.run(['git', 'init', '-q', str(root)], check=True)
            for name, content in {
                '.gitignore': 'build/\n',
                'RawLabWindows/build.ps1': 'old',
                'lutools/deleted.cpp': 'deleted',
            }.items():
                file = root / name
                file.parent.mkdir(parents=True, exist_ok=True)
                file.write_text(content)
            subprocess.run(['git', '-C', str(root), 'add', '.'], check=True)
            (root / 'RawLabWindows/build.ps1').write_text('current dirty contents')
            (root / 'lutools/deleted.cpp').unlink()
            for name in ['lutools/cmake/patch-libraw.cmake',
                         'lutools/third_party/rawspeed-camera-calibration.inc',
                         'LICENSE', 'LICENSE-ALIYUN-RUM-EXCEPTION', 'docs/reference/licensing.md',
                         'lutools/tests/fixtures/bayer-demosaic.dng',
                         'lutools/tests/fixtures/linear-jxl.dng',
                         'lutools/tests/fixtures/linear-uncompressed.dng',
                         'lutools/tests/fixtures/linear-jxl-gain.dng',
                         'lutools/tests/fixtures/linear-doubled.dng',
                         'lutools/tests/fixtures/linear-jxl-stage1.dng',
                         'lutools/tests/fixtures/linear-halved.dng',
                         'lutools/tests/fixtures/linear-jxl-crop-gain.dng',
                         'lutools/tests/fixtures/linear-crop-doubled.dng',
                         'lutools/tests/fixtures/linear-jxl-required-unknown.dng',
                         'lutools/tests/fixtures/linear-jxl-default-crop-gain.dng',
                         'lutools/tests/fixtures/linear-default-crop-doubled.dng',
                         'lutools/tests/fixtures/linear-jxl-channel-levels.dng',
                         'lutools/tests/fixtures/linear-channel-levels.dng',
                         'lutools/tests/fixtures/linear-normalized.dng',
                         'lutools/tests/fixtures/private.dng',
                         'lutools/examples/private.ARW', 'build/cache.bin']:
                file = root / name
                file.parent.mkdir(parents=True, exist_ok=True)
                file.write_text('fixture')
            archive = root / 'source.zip'
            files = module.package_source(root, archive)
            self.assertIn('lutools/cmake/patch-libraw.cmake', files)
            self.assertIn('lutools/third_party/rawspeed-camera-calibration.inc', files)
            self.assertIn('LICENSE', files)
            self.assertIn('LICENSE-ALIYUN-RUM-EXCEPTION', files)
            self.assertIn('docs/reference/licensing.md', files)
            self.assertNotIn('lutools/deleted.cpp', files)
            self.assertNotIn('build/cache.bin', files)
            self.assertNotIn('lutools/examples/private.ARW', files)
            self.assertNotIn('lutools/tests/fixtures/private.dng', files)
            for name in ['linear-jxl.dng', 'linear-uncompressed.dng',
                         'linear-jxl-gain.dng', 'linear-doubled.dng',
                         'linear-jxl-stage1.dng', 'linear-halved.dng',
                         'linear-jxl-crop-gain.dng', 'linear-crop-doubled.dng',
                         'linear-jxl-required-unknown.dng',
                         'linear-jxl-default-crop-gain.dng', 'linear-default-crop-doubled.dng',
                         'linear-jxl-channel-levels.dng', 'linear-channel-levels.dng',
                         'linear-normalized.dng']:
                self.assertIn('lutools/tests/fixtures/' + name, files)
            with zipfile.ZipFile(archive) as package:
                self.assertEqual(package.read('RawLabWindows/build.ps1'), b'current dirty contents')
                self.assertIn('lutools/tests/fixtures/bayer-demosaic.dng', package.namelist())
                self.assertEqual(package.read('LICENSE-ALIYUN-RUM-EXCEPTION'), b'fixture')



def settings_for(module, profile=None, *argv):
    args = module.build_parser().parse_args(list(argv))
    return module.resolve_settings(args, profile or {})


PROFILE = {
    'host': 'builder@windows.example', 'port': 2222, 'proxy_jump': 'jump@gateway.example',
    'identity': '~/.ssh/example_key', 'known_hosts': '~/.ssh/example_known_hosts',
    'pwsh': 'E:/Tools/pwsh/pwsh.exe', 'dotnet_dir': 'E:/Tools/dotnet', 'python': 'E:/Tools/python/python.exe',
    'workspace': 'C:/RawLabBuild/verify/rawtools', 'path_prepend': ['C:/RawLabBuild/tools/cargo/bin'],
    'env': {'RUSTUP_TOOLCHAIN': '1.99.1', 'RAWLAB_SOURCE_ARCHIVE_CACHE': 'E:/RawLabCI/cache/rawlab-deps'},
}


class ProfileAndConnectionTest(unittest.TestCase):
    def setUp(self):
        self.module = load_module()

    def test_profile_file_is_loaded_and_cli_options_override_it(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'hosts.json'
            path.write_text(json.dumps({'fast': PROFILE}))
            profile = self.module.load_profile(path, 'fast')
            settings = settings_for(self.module, profile, '--port', '22', '--env', 'EXTRA=1',
                                    '--env', 'RUSTUP_TOOLCHAIN=stable')
            self.assertEqual(settings['port'], 22)
            self.assertEqual(settings['proxy_jump'], 'jump@gateway.example')
            self.assertEqual(settings['env'], {'RUSTUP_TOOLCHAIN': 'stable', 'EXTRA': '1',
                                               'RAWLAB_SOURCE_ARCHIVE_CACHE': 'E:/RawLabCI/cache/rawlab-deps'})
            path.write_text(json.dumps({'fast': {**PROFILE, 'password': 'x'}}))
            with self.assertRaises(SystemExit):
                self.module.load_profile(path, 'fast')
            with self.assertRaises(SystemExit):
                self.module.load_profile(path, 'missing')

    def test_ssh_and_scp_use_port_jump_key_known_hosts_and_unquoted_text_mode_shell(self):
        settings = settings_for(self.module, PROFILE)
        command = self.module.ssh_command(settings, 'ENCODED')
        self.assertEqual(command[0], 'ssh')
        self.assertEqual(command[command.index('-p') + 1], '2222')
        self.assertEqual(command[command.index('-J') + 1], 'jump@gateway.example')
        self.assertEqual(command[command.index('-i') + 1], str(Path('~/.ssh/example_key').expanduser()))
        self.assertIn(f"UserKnownHostsFile={Path('~/.ssh/example_known_hosts').expanduser()}", command)
        self.assertIn('StrictHostKeyChecking=yes', command)
        # Works whether the remote login shell is cmd.exe or PowerShell.
        self.assertEqual(command[-1], 'E:/Tools/pwsh/pwsh.exe -NoProfile -NonInteractive -OutputFormat Text '
                                      '-ExecutionPolicy Bypass -EncodedCommand ENCODED')
        # Full scripts run from a copied file: cmd.exe login shells cap command lines near 8 KB.
        long_script = self.module.verify_script(settings, 'C:/RawLabBuild/incoming/1', True, 'a', 'b', 'f.dng')
        self.assertGreater(len(self.module.encode(long_script)), 8191)
        by_file = self.module.ssh_command(settings, script_file='C:/RawLabBuild/incoming/1/remote.ps1')
        self.assertTrue(by_file[-1].endswith('-File C:/RawLabBuild/incoming/1/remote.ps1'))
        self.assertLess(len(' '.join(by_file)), 8191)
        scp = self.module.scp_command(settings, Path('/tmp/a.zip'), 'builder@windows.example:C:/x/a.zip')
        self.assertEqual(scp[scp.index('-P') + 1], '2222')
        self.assertIn('-J', scp)

    def test_unsafe_settings_are_rejected_before_anything_runs(self):
        for override in ({'pwsh': 'C:/Program Files/PowerShell/7/pwsh.exe'}, {'workspace': 'D:/Elsewhere/work'},
                         {'workspace': 'C:/RawLabBuild/../Windows/Temp'}, {'env': {'A': 'x\u2019; calc'}},
                         {'dotnet_dir': 'C:/dotnet\u2018x'},
                         {'workspace': "C:/RawLabBuild/x'; Remove-Item"}, {'path_prepend': ['relative/bin']},
                         {'env': {'A': "x'y"}}, {'dotnet_dir': 'C:/dotnet;calc'}, {'host': None}):
            with self.subTest(override=override):
                with self.assertRaises(SystemExit):
                    settings_for(self.module, {**PROFILE, **override})
        with self.assertRaises(SystemExit):
            settings_for(self.module, PROFILE, '--env', 'NOT-VALID=1')

    def test_repository_code_carries_no_host_details(self):
        # Addresses, accounts, jump hosts and key names belong to the private profile file only.
        text = (Path(__file__).resolve().parents[1] / 'build-remote.py').read_text(encoding='utf-8')
        self.assertIsNone(re.search(r'\b\d{1,3}(?:\.\d{1,3}){3}\b', text))
        self.assertNotIn('rawlab_vm100', text)
        self.assertNotIn('id_ed25519', text)
        self.assertNotRegex(text, r"'[a-z]+@[A-Za-z0-9.-]+'")


class IncrementalSyncTest(unittest.TestCase):
    def setUp(self):
        self.module = load_module()

    def test_plan_uploads_only_new_or_changed_content_and_removes_stale_files(self):
        local = {'same.cpp': 'a', 'edited.cpp': 'b2', 'new.cpp': 'c'}
        remote = {'same.cpp': 'a', 'edited.cpp': 'b1', 'gone.cpp': 'd'}
        self.assertEqual(self.module.sync_plan(local, remote), (['edited.cpp', 'new.cpp'], ['gone.cpp']))
        self.assertEqual(self.module.sync_plan(local, local), ([], []))

    def test_change_package_holds_changed_files_and_the_full_manifest(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            for name, content in {'a.txt': 'a', 'b.txt': 'b'}.items():
                (root / name).write_text(content)
            local = self.module.local_manifest(root, ['a.txt', 'b.txt'])
            self.assertEqual(local['a.txt'], hashlib.sha256(b'a').hexdigest())
            archive = root / 'changes.zip'
            self.module.package_changes(root, archive, local, ['b.txt'], ['old.txt'])
            with zipfile.ZipFile(archive) as package:
                self.assertEqual(sorted(package.namelist()), ['.rawlab-sync-plan.json', 'b.txt'])
                plan = json.loads(package.read('.rawlab-sync-plan.json'))
            self.assertEqual(plan, {'changed': ['b.txt'], 'removed': ['old.txt'], 'manifest': local,
                                    'base': 'none', 'known': ['a.txt', 'b.txt']})

    def test_untrusted_remote_sets_reupload_everything_and_still_remove_stale_files(self):
        local = {'keep.cs': 'a', 'new.cs': 'b'}
        remote = {'keep.cs': 'a', 'Y.cs': None}
        # pending/legacy sets or --full-sync: hashes are not trusted, deletions still happen.
        self.assertEqual(self.module.sync_plan(local, remote, trusted=False), (['keep.cs', 'new.cs'], ['Y.cs']))

    def test_remote_manifest_read_keeps_kind_path_pairs(self):
        captured = []
        def fake_run(command, **_):
            captured.append(base64.b64decode(command[-1].rsplit(' ', 1)[1]).decode('utf-16le'))
            return subprocess.CompletedProcess(command, 0, '', '')
        with mock.patch.object(self.module.subprocess, 'run', side_effect=fake_run):
            self.module.read_remote_manifest(settings_for(self.module, PROFILE))
        script = captured[0]
        self.assertIn("@(@('trusted', 'C:/RawLabBuild/verify/rawtools/.rawlab-remote-manifest.json'), @('pending'", script)
        self.assertNotIn("); @(", script)

    def test_remote_manifest_reply_kinds_and_tokens(self):
        def reply(kind, payload):
            data = json.dumps(payload).encode()
            return f'{kind} {base64.b64encode(data).decode()}\r\n', f'{kind}:{hashlib.sha256(data).hexdigest()}'
        text, token = reply('trusted', {'a.cpp': 'h'})
        self.assertEqual(self.module.parse_remote_manifest(text), ({'a.cpp': 'h'}, True, token))
        text, token = reply('pending', {'a.cpp': None, 'gone.cpp': None})
        self.assertEqual(self.module.parse_remote_manifest(text)[1:], (False, token))
        text, _ = reply('legacy', ['old.cs', 'a.cpp'])
        paths, trusted, _ = self.module.parse_remote_manifest(text)
        self.assertEqual((sorted(paths), trusted), (['a.cpp', 'old.cs'], False))
        self.assertEqual(self.module.parse_remote_manifest(''), ({}, True, 'none'))
        with self.assertRaises(SystemExit):
            self.module.parse_remote_manifest('Warning: something else')

    def test_sync_locks_checks_its_base_and_marks_pending_before_touching_files(self):
        block = self.module.SYNC_BLOCK
        check = block.index('if ($current -ne $plan.base)')
        pending = block.index('Set-Content -LiteralPath $pendingPath')
        first_change = min(block.index('Remove-Item -LiteralPath $path'), block.index('Copy-Item -LiteralPath'))
        self.assertLess(check, pending)
        self.assertLess(pending, first_change)
        self.assertLess(first_change, block.index('Set-Content -LiteralPath $manifestPath'))
        self.assertLess(block.index('Set-Content -LiteralPath $manifestPath'), block.index('Remove-Item -LiteralPath $pendingPath'))
        self.assertIn("[IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None')", self.module.LOCK_BLOCK)
        settings = settings_for(self.module, PROFILE)
        for script in (self.module.verify_script(settings, 'C:/RawLabBuild/incoming/1', True, None, None, ''),
                       self.module.build_script(settings, 'C:/RawLabBuild/incoming/1', '', '')):
            self.assertLess(script.index('[IO.File]::Open($lockPath'), script.index('Expand-Archive'))
            self.assertIn('if ($workspaceLock) { $workspaceLock.Dispose() }', script)
            self.assertLess(script.index('try {'), script.index('[IO.File]::Open($lockPath'))

    def test_remote_sync_rewrites_only_changed_files_and_marks_them_new(self):
        block = self.module.SYNC_BLOCK
        self.assertIn('foreach ($name in @($plan.changed))', block)
        self.assertIn('.LastWriteTime = $now', block)
        self.assertIn('Resolve-WorkspacePath', block)
        self.assertNotIn('Copy-Item "$staging/*"', block, 'a blanket copy would reset every mtime')
        self.assertLess(block.index('-eq $expected'), block.index('Copy-Item -LiteralPath'),
                        'identical content is skipped before any rewrite')


class VerifyModeTest(unittest.TestCase):
    def setUp(self):
        self.module = load_module()
        self.settings = settings_for(self.module, PROFILE)

    def script(self, **kwargs):
        options = {'models': False, 'ctest_filter': None, 'v08_suite': None, 'raw_name': ''}
        options.update(kwargs)
        return self.module.verify_script(self.settings, 'C:/RawLabBuild/incoming/1', options['models'],
                                         options['ctest_filter'], options['v08_suite'], options['raw_name'])

    def test_every_verify_run_isolates_app_data_cleans_up_and_checks_local_state(self):
        script = self.script(models=True)
        self.assertIn("$env:RAWLAB_APPDATA_ROOT = Join-Path $incoming 'appdata'", script)
        self.assertIn('} finally {', script)
        self.assertIn('Remove-Item -LiteralPath $incoming -Recurse -Force', script)
        self.assertIn('%LOCALAPPDATA%\\RawLab changed during verification', script)
        self.assertNotIn('Compress-Archive', script)
        self.assertLess(script.index('$stateBefore = Get-RawLabState'), script.index('try {'))
        self.assertIn("$env:RUSTUP_TOOLCHAIN = '1.99.1'", script)
        self.assertIn("$dotnet = 'E:/Tools/dotnet/dotnet.exe'", script)
        self.assertIn('$dotnetArgs = @{ DotNet = $dotnet }', script)
        # Without a configured SDK, build.ps1 keeps choosing its own (build/tools/dotnet first).
        bare = settings_for(self.module, {**PROFILE, 'dotnet_dir': None})
        self.assertIn('$dotnetArgs = @{}', self.module.verify_script(bare, 'C:/RawLabBuild/incoming/1', False, 'x', None, ''))

    def test_requested_phases_only(self):
        models = self.script(models=True)
        self.assertIn('windows-models.ps1', models)
        self.assertNotIn('build.ps1', models)
        ctest = self.script(ctest_filter='^windows_display_image$')
        self.assertLess(ctest.index('build.ps1'), ctest.index('ctest.exe'))
        self.assertIn("-R '^windows_display_image$'", ctest)
        # Skipped RAW tests (exit 77) must not pass silently; --raw points them at a fixture.
        self.assertIn("'The following tests did not run'", ctest)
        self.assertIn("if ('') {", ctest)
        with_raw = self.script(ctest_filter='^core$', raw_name='fixture.dng')
        self.assertIn('"-DSONY2FUJI_TEST_RAW=$incoming/fixture.dng"', with_raw)
        v08 = self.script(v08_suite='batch-selection', raw_name='fixture.dng')
        self.assertIn('run-v08.ps1" -RawPath "$incoming/fixture.dng"', v08)
        self.assertIn("-Only 'batch-selection'", v08)
        self.assertNotIn('-AIDenoise', v08)
        v08_ai = self.module.verify_script(self.settings, 'C:/RawLabBuild/incoming/1', False, None,
                                           'ai-panel,editor-shell', 'fixture.arw', ai_denoise=True)
        self.assertIn('-AIDenoise', v08_ai)
        build_ai = self.module.build_script(self.settings, 'C:/RawLabBuild/incoming/1', '-NoRumSdk', '', ai_denoise=True)
        self.assertIn('-AIDenoise', build_ai)

    def test_argument_combinations_are_validated(self):
        parser = self.module.build_parser()
        with tempfile.TemporaryDirectory() as folder:
            odd = Path(folder) / "fixture.$(calc)"
            odd.write_text('x')
            with self.assertRaises(SystemExit):
                self.module.validate_args(parser, parser.parse_args(['--verify', '--v08-only', 's', '--raw', str(odd)]))
            dng = Path(folder) / 'fixture.dng'
            dng.write_text('x')
            with self.assertRaises(SystemExit):
                self.module.validate_args(parser, parser.parse_args(['--verify', '--models', '--raw', str(dng)]))
            self.module.validate_args(parser, parser.parse_args(['--verify', '--ctest-filter', 'core', '--raw', str(dng)]))
        bad = (['--verify'], ['--models'], ['--verify', '--ctest-filter', "x'; calc"],
               ['--verify', '--v08-only', 'batch-selection'], ['--verify', '--models', '--test'])
        for argv in bad:
            with self.subTest(argv=argv):
                with self.assertRaises(SystemExit):
                    self.module.validate_args(parser, parser.parse_args(argv))
        self.module.validate_args(parser, parser.parse_args(['--verify', '--models', '--ctest-filter', 'a|b']))

    def test_verify_run_leaves_nothing_in_the_repository_or_temp_dir(self):
        calls = []
        remote_scripts = []

        def fake_run(command, *args, **kwargs):
            if command[0] in ('ssh', 'scp'):
                calls.append(command)
                return subprocess.CompletedProcess(command, 0, '', '')
            return real_run(command, *args, **kwargs)

        real_run = subprocess.run
        root = Path(__file__).resolve().parents[2]
        before = set((root / 'build').glob('windows-remote/*')) if (root / 'build').exists() else set()
        created = []
        real_tempdir = tempfile.TemporaryDirectory

        def tracking_tempdir(*args, **kwargs):
            directory = real_tempdir(*args, **kwargs)
            created.append(Path(directory.name))
            return directory

        with mock.patch.object(self.module.subprocess, 'run', side_effect=fake_run), \
                mock.patch.object(self.module, 'run_remote',
                                  side_effect=lambda settings, script, log, incoming: remote_scripts.append(script) or 0), \
                mock.patch.object(self.module, 'ensure_lut_assets'), \
                mock.patch.object(self.module.tempfile, 'TemporaryDirectory', side_effect=tracking_tempdir), \
                mock.patch('sys.stdout', new=io.TextIOWrapper(io.BytesIO())):
            self.module.main(['--host', 'builder@windows.example', '--workspace', 'C:/RawLabBuild/verify/x',
                              '--verify', '--models'])
        after = set((root / 'build').glob('windows-remote/*')) if (root / 'build').exists() else set()
        self.assertEqual(after, before, 'verify mode must not write build/windows-remote')
        self.assertEqual(len(created), 1)
        self.assertFalse(created[0].exists(), 'local staging directory must be removed')
        self.assertTrue(any(command[0] == 'scp' and command[-1].endswith('/changes.zip') for command in calls))
        self.assertEqual(len(remote_scripts), 1)
        self.assertIn('windows-models.ps1', remote_scripts[0])


if __name__ == '__main__':
    unittest.main()
