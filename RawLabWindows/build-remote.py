#!/usr/bin/env python3
"""Build or quickly verify the current working files on a prepared Windows OpenSSH host.

Host details (address, user, jump host, key, tool paths) live only in a private profile file,
by default ~/.config/rawlab/windows-verify-hosts.json (override with RAWLAB_WINDOWS_VERIFY_HOSTS):

    {"<name>": {"host": "user@host", "port": 22, "proxy_jump": "user@jump", "identity": "~/.ssh/key",
                "known_hosts": "~/.ssh/known", "pwsh": "X:/path/pwsh.exe", "dotnet_dir": "X:/dotnet",
                "python": "X:/python.exe", "workspace": "C:/RawLabBuild/verify/rawtools",
                "path_prepend": ["X:/cargo/bin"], "env": {"NAME": "value"}}}

Command-line options override profile values. Sources are synchronized incrementally: the remote
workspace keeps a SHA-256 manifest, only changed files are uploaded and rewritten (their mtime is
set to now so CMake/MSBuild rebuild them) and unchanged files are never touched, which keeps the
remote incremental build state valid.

--verify runs only the requested checks (--models, --ctest-filter, --v08-only) with a fresh isolated
RAWLAB_APPDATA_ROOT, skips packaging and downloading the app, removes its remote temporary
directory in finally and fails if %LOCALAPPDATA%\\RawLab changed; locally it stages in the system
temporary directory and leaves nothing behind. Without --verify the script builds the
self-contained app (optionally with --test) and downloads build/RawLab-Windows as a zip.
"""
import argparse
import base64
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
import zipfile

SOURCE_PATHS = ['RawLabWindows', 'lutools', 'RawLabMac/Resources', 'Shared', 'LICENSE',
                'LICENSE-ALIYUN-RUM-EXCEPTION', 'docs/reference/licensing.md', 'scripts/ci', 'scripts/assets']
RAW_SUFFIXES = {'.arw', '.nef', '.cr2', '.cr3', '.raf', '.rw2', '.orf', '.3fr', '.dng', '.pef', '.x3f'}
SYNTHETIC_RAW_FIXTURES = {
    'lutools/tests/fixtures/' + name for name in
    ('bayer-demosaic.dng', 'linear-jxl.dng', 'linear-uncompressed.dng', 'linear-jxl-gain.dng', 'linear-doubled.dng',
     'linear-jxl-stage1.dng', 'linear-halved.dng', 'linear-jxl-crop-gain.dng',
     'linear-crop-doubled.dng', 'linear-jxl-required-unknown.dng',
     'linear-jxl-default-crop-gain.dng', 'linear-default-crop-doubled.dng',
     'linear-jxl-channel-levels.dng', 'linear-channel-levels.dng', 'linear-normalized.dng',
     'linear-jxl-lens.dng', 'linear-lens.dng', 'linear-jxl-stage3-lens.dng')
}
MANIFEST_NAME = '.rawlab-remote-manifest.json'
PLAN_NAME = '.rawlab-sync-plan.json'
DEFAULT_PROFILES = Path.home() / '.config/rawlab/windows-verify-hosts.json'
PROFILE_KEYS = {'description', 'host', 'port', 'proxy_jump', 'identity', 'known_hosts', 'pwsh', 'dotnet_dir',
                'python', 'workspace', 'path_prepend', 'env'}
# Everything interpolated into the remote PowerShell is validated against these first.
SAFE_REMOTE_PATH = re.compile(r"^[A-Za-z]:[/\\][^'\"`$\r\n;&|<>]*$")
SAFE_ENV_NAME = re.compile(r'^[A-Za-z_][A-Za-z0-9_]*$')
SAFE_FILTER = re.compile(r'^[A-Za-z0-9_.*+?^$()\[\]|-]+$')
SAFE_SUITE = re.compile(r'^[A-Za-z0-9_.,-]+$')

# 与 RumSdk.targets 的 RawLabRumSdkZipSha256 一致（测试会核对）
RUM_SDK_SHA256 = 'bfa05c0718a57eb7e94c9494499bd3c84305a3cc39b76d6a9096667553928994'


def rum_sdk_cache(root):
    """主工作区共享缓存里的 Windows RUM SDK 归档；worktree 也指向主工作区"""
    common = subprocess.run(['git', '-C', str(root), 'rev-parse', '--path-format=absolute', '--git-common-dir'],
                            capture_output=True, text=True)
    main = Path(common.stdout.strip()).parent if common.returncode == 0 else root
    return main / '.cache/shared/aliyun-rum/windows/0.4.4/sdk.zip'


def rum_build_args(no_rum_sdk, archive, incoming):
    """build.ps1 的统计 SDK 参数和要上传的本地归档。本地没有缓存时不传参数，
    由远端 build.ps1 从供应商固定地址下载并校验；离线包显式 -NoRumSdk"""
    if no_rum_sdk:
        return '-NoRumSdk', None
    if not archive.is_file():
        return '', None
    if hashlib.sha256(archive.read_bytes()).hexdigest() != RUM_SDK_SHA256:
        raise SystemExit(f'Unexpected RUM SDK archive SHA-256: {archive}')
    return f"-RumSdkZip '{incoming}/rum-sdk.zip'", archive


def lut_asset_files(root):
    """Externalized LUT files (gitignored, materialized by scripts/assets/prepare.py) the Windows build needs."""
    manifest = json.loads((root / 'Shared/assets-manifest.json').read_text(encoding='utf-8'))
    return [entry['path'] for entry in manifest['groups']['luts']['files']]


def ensure_lut_assets(root):
    """Materialize LUT assets from the shared local cache so the remote host never downloads them."""
    missing = [name for name in lut_asset_files(root) if not (root / name).is_file()]
    if missing:
        subprocess.run([sys.executable, str(root / 'scripts/assets/prepare.py'), '--group', 'luts', '--offline',
                        '--quiet'], check=True)


def source_files(root):
    listed = subprocess.check_output([
        'git', '-C', str(root), 'ls-files', '-z', '--cached', '--others',
        '--exclude-standard', '--', *SOURCE_PATHS])
    files = {name.decode() for name in listed.split(b'\0') if name and
             (root / name.decode()).is_file() and
             (Path(name.decode()).suffix.lower() not in RAW_SUFFIXES or
              name.decode() in SYNTHETIC_RAW_FIXTURES)}
    if (root / 'Shared/assets-manifest.json').is_file():
        files.update(name for name in lut_asset_files(root) if (root / name).is_file())
    return sorted(files)


def local_manifest(root, files):
    return {name: hashlib.sha256((root / name).read_bytes()).hexdigest() for name in files}


def sync_plan(local, remote):
    """Files to upload (new or different content) and remote files to delete."""
    changed = sorted(name for name, digest in local.items() if remote.get(name) != digest)
    removed = sorted(name for name in remote if name not in local)
    return changed, removed


def package_changes(root, archive, local, changed, removed):
    with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED) as package:
        for name in changed:
            package.write(root / name, name)
        package.writestr(PLAN_NAME, json.dumps({'changed': changed, 'removed': removed, 'manifest': local}))


def package_source(root, archive):
    """Full source package: every file is new against an empty remote manifest."""
    files = source_files(root)
    local = local_manifest(root, files)
    changed, removed = sync_plan(local, {})
    package_changes(root, archive, local, changed, removed)
    return files


def load_profile(path, name):
    if not path.is_file():
        raise SystemExit(f'Profile file not found: {path} (see the module docstring for its format)')
    profiles = json.loads(path.read_text(encoding='utf-8'))
    if name not in profiles:
        raise SystemExit(f'Unknown profile {name!r}; available: {", ".join(sorted(profiles))}')
    profile = profiles[name]
    unknown = set(profile) - PROFILE_KEYS
    if unknown:
        raise SystemExit(f'Unknown profile keys in {name!r}: {", ".join(sorted(unknown))}')
    return profile


def parse_env(pairs):
    env = {}
    for pair in pairs:
        name, separator, value = pair.partition('=')
        if not separator or not SAFE_ENV_NAME.match(name):
            raise SystemExit(f'--env expects NAME=value, got {pair!r}')
        env[name] = value
    return env


def resolve_settings(args, profile):
    """CLI values override the profile; returns validated connection and remote tool settings."""
    def pick(option, key, default=None):
        value = getattr(args, option)
        return value if value is not None else profile.get(key, default)

    settings = {
        'host': pick('host', 'host'),
        'port': int(pick('port', 'port', 22)),
        'proxy_jump': pick('proxy_jump', 'proxy_jump'),
        'identity': pick('identity', 'identity'),
        'known_hosts': pick('known_hosts', 'known_hosts'),
        'pwsh': pick('pwsh', 'pwsh', 'powershell.exe'),
        'dotnet_dir': pick('dotnet_dir', 'dotnet_dir'),
        'python': pick('python', 'python'),
        'workspace': pick('workspace', 'workspace', 'C:/RawLabBuild/workspace'),
        'path_prepend': list(profile.get('path_prepend', [])),
        'env': {**profile.get('env', {}), **parse_env(args.env or [])},
    }
    if not settings['host']:
        raise SystemExit('No host: pass --host or --profile')
    for key in ('workspace', 'dotnet_dir', 'python'):
        if settings[key] and not SAFE_REMOTE_PATH.match(settings[key]):
            raise SystemExit(f'{key} must be an absolute Windows path without quotes or shell characters')
    if not settings['workspace'].replace('\\', '/').startswith(('C:/RawLabBuild/', 'E:/RawLab')):
        raise SystemExit('workspace must live under C:/RawLabBuild/ or E:/RawLab*')
    # The remote login shell may be cmd.exe or PowerShell; an unquoted path runs in both.
    if settings['pwsh'] != 'powershell.exe' and (not SAFE_REMOTE_PATH.match(settings['pwsh']) or ' ' in settings['pwsh']):
        raise SystemExit('pwsh must be powershell.exe or an absolute Windows path without spaces')
    for item in settings['path_prepend']:
        if not SAFE_REMOTE_PATH.match(item):
            raise SystemExit(f'path_prepend entry is not a plain absolute Windows path: {item}')
    for name, value in settings['env'].items():
        if not SAFE_ENV_NAME.match(name) or any(c in value for c in "'\r\n"):
            raise SystemExit(f'Environment value for {name} contains a quote or line break')
    return settings


def ssh_options(settings):
    options = ['-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes', '-o', 'ConnectTimeout=20']
    if settings['identity']:
        options += ['-o', 'IdentitiesOnly=yes', '-i', str(Path(settings['identity']).expanduser())]
    if settings['known_hosts']:
        options += ['-o', f"UserKnownHostsFile={Path(settings['known_hosts']).expanduser()}"]
    if settings['proxy_jump']:
        options += ['-J', settings['proxy_jump']]
    return options


def ssh_command(settings, encoded=None, script_file=None):
    """Run a short encoded command, or a script file already copied to the host.

    cmd.exe login shells cap a command line near 8 KB, so full build/verify scripts go as files.
    -OutputFormat Text keeps Write-Host/progress streams from arriving as CLIXML on stderr.
    """
    payload = f'-File {script_file}' if script_file else f'-EncodedCommand {encoded}'
    return ['ssh', *ssh_options(settings), '-p', str(settings['port']), settings['host'],
            f'{settings["pwsh"]} -NoProfile -NonInteractive -OutputFormat Text -ExecutionPolicy Bypass {payload}']


def scp_command(settings, source, destination):
    return ['scp', *ssh_options(settings), '-P', str(settings['port']), str(source), str(destination)]


def encode(script):
    script = "$ProgressPreference = 'SilentlyContinue'\n" + script
    return base64.b64encode(script.encode('utf-16le')).decode()


def ps_quote(value):
    return "'" + value.replace("'", "''") + "'"


def environment_block(settings):
    lines = ["$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'", "$env:VSCMD_SKIP_SENDTELEMETRY = '1'",
             '[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)']
    prepend = list(settings['path_prepend'])
    if settings['dotnet_dir']:
        prepend.insert(0, settings['dotnet_dir'])
    prepend.append('C:/Program Files/dotnet')
    lines.append(f"$env:PATH = {ps_quote(';'.join(prepend))} + ';' + $env:PATH")
    for name, value in sorted(settings['env'].items()):
        lines.append(f'$env:{name} = {ps_quote(value)}')
    dotnet = f"{settings['dotnet_dir']}/dotnet.exe" if settings['dotnet_dir'] else 'dotnet'
    lines.append(f'$dotnet = {ps_quote(dotnet)}')
    lines.append(f"$python = {ps_quote(settings['python'] or '')}")
    return '\n'.join(lines)


SYNC_BLOCK = r"""
$staging = Join-Path $incoming 'changes'
Expand-Archive -LiteralPath "$incoming/changes.zip" -DestinationPath $staging
$plan = Get-Content -LiteralPath (Join-Path $staging '.rawlab-sync-plan.json') -Raw | ConvertFrom-Json
New-Item -ItemType Directory -Force $workspace | Out-Null
$prefix = [IO.Path]::GetFullPath($workspace).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
function Resolve-WorkspacePath([string]$name) {
    $path = [IO.Path]::GetFullPath((Join-Path $workspace $name))
    if (-not $path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw "Invalid source path: $name" }
    return $path
}
foreach ($name in @($plan.removed)) {
    $path = Resolve-WorkspacePath $name
    if (Test-Path -LiteralPath $path -PathType Leaf) { Remove-Item -LiteralPath $path -Force }
}
$now = Get-Date
foreach ($name in @($plan.changed)) {
    $path = Resolve-WorkspacePath $name
    New-Item -ItemType Directory -Force (Split-Path -Parent $path) | Out-Null
    Copy-Item -LiteralPath (Join-Path $staging $name) -Destination $path -Force
    # Archives carry the local mtime, which may predate remote build outputs; rewritten files must look new.
    (Get-Item -LiteralPath $path).LastWriteTime = $now
}
$plan.manifest | ConvertTo-Json -Depth 3 -Compress | Set-Content -LiteralPath (Join-Path $workspace '.rawlab-remote-manifest.json') -Encoding utf8
Write-Output ("SYNC: {0} changed, {1} removed" -f @($plan.changed).Count, @($plan.removed).Count)
"""

STATE_FUNCTION = r"""
function Get-RawLabState {
    # Directory timestamps returned by enumeration come from NTFS parent-index entries that are
    # updated lazily, so they drift without any write. Record directories by presence only and read
    # each file's size and write time from the file itself.
    $state = Join-Path $env:LOCALAPPDATA 'RawLab'
    if (-not (Test-Path -LiteralPath $state)) { return @('<absent>') }
    $lines = @(Get-ChildItem -LiteralPath $state -Recurse -Force -ErrorAction Stop | Sort-Object FullName | ForEach-Object {
        $relative = $_.FullName.Substring($state.Length)
        if ($_.PSIsContainer) { '{0}|dir' -f $relative } else {
            $file = [IO.FileInfo]::new($_.FullName)
            '{0}|{1}|{2}' -f $relative, $file.Length, $file.LastWriteTimeUtc.ToString('o')
        }
    })
    if ($lines.Count -eq 0) { return @('<empty>') }
    return $lines
}
"""


def verify_script(settings, incoming, models, ctest_filter, v08_suite, raw_name):
    """PowerShell for --verify: incremental sync, isolated app data, requested checks, cleanup."""
    phases = []
    if models:
        phases.append(r"""
    Write-Output 'PHASE models'
    $global:LASTEXITCODE = 0
    & "$workspace/scripts/ci/windows-models.ps1" -DotNet $dotnet
    if (-not $? -or $LASTEXITCODE) { throw 'Windows models failed.' }""")
    if ctest_filter or v08_suite:
        python_arg = '-Python $python' if settings['python'] else ''
        phases.append(rf"""
    Write-Output 'PHASE build'
    & "$workspace/RawLabWindows/build.ps1" -SelfContained -NoRumSdk -DotNet $dotnet {python_arg}
    if ($LASTEXITCODE -ne 0) {{ throw 'Windows build failed.' }}""")
    if ctest_filter:
        phases.append(rf"""
    Write-Output 'PHASE ctest'
    $cmake = (Get-Command cmake -ErrorAction SilentlyContinue).Source
    if (-not $cmake) {{
        $vs = & "${{env:ProgramFiles(x86)}}/Microsoft Visual Studio/Installer/vswhere.exe" -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
        $cmake = Join-Path $vs 'Common7/IDE/CommonExtensions/Microsoft/CMake/CMake/bin/cmake.exe'
    }}
    $env:PATH = "$workspace/build/RawLab-Windows;" + $env:PATH
    & (Join-Path (Split-Path $cmake) 'ctest.exe') --test-dir "$workspace/build/windows-native" -C Release -R '{ctest_filter}' --output-on-failure --no-tests=error
    if ($LASTEXITCODE -ne 0) {{ throw 'ctest failed.' }}""")
    if v08_suite:
        phases.append(rf"""
    Write-Output 'PHASE v08'
    $global:LASTEXITCODE = 0
    & "$workspace/RawLabWindows/tests/run-v08.ps1" -RawPath "$incoming/{raw_name}" -NativeArtifacts "$workspace/build/RawLab-Windows" -Only '{v08_suite}' -DotNet $dotnet
    if (-not $? -or $LASTEXITCODE) {{ throw 'v08 suite failed.' }}""")
    return f"""
$ErrorActionPreference = 'Stop'
{environment_block(settings)}
$workspace = {ps_quote(settings['workspace'])}
$incoming = {ps_quote(incoming)}
{STATE_FUNCTION}
$stateBefore = Get-RawLabState
$failure = $null
$started = Get-Date
try {{
{SYNC_BLOCK}
    # Tests and tools must never read or write the user's real app data.
    $env:RAWLAB_APPDATA_ROOT = Join-Path $incoming 'appdata'
    New-Item -ItemType Directory -Force $env:RAWLAB_APPDATA_ROOT | Out-Null
    Set-Location $workspace
{''.join(phases)}
}} catch {{
    $failure = $_
}} finally {{
    Set-Location $env:TEMP
    for ($attempt = 1; (Test-Path -LiteralPath $incoming) -and $attempt -le 3; $attempt++) {{
        if ($attempt -gt 1) {{ Start-Sleep -Seconds 2 }}
        Remove-Item -LiteralPath $incoming -Recurse -Force -ErrorAction SilentlyContinue
    }}
}}
$diff = @(Compare-Object -ReferenceObject $stateBefore -DifferenceObject @(Get-RawLabState) | ForEach-Object {{ '{{0}} {{1}}' -f $_.SideIndicator, $_.InputObject }})
if ($diff.Count -gt 0) {{ $failure = "%LOCALAPPDATA%\\RawLab changed during verification: $($diff -join '; ') $failure" }}
if (Test-Path -LiteralPath $incoming) {{ $failure = "Remote temporary directory was not removed: $incoming $failure" }}
if ($failure) {{ Write-Output "FAIL: $failure"; exit 1 }}
Write-Output ("PASS: remote verification in {{0:N0}} s; temporary directory removed; %LOCALAPPDATA%\\RawLab untouched" -f ((Get-Date) - $started).TotalSeconds)
"""


def build_script(settings, incoming, rum_args, test_args):
    """PowerShell for the default build: incremental sync, build.ps1, package the app for download."""
    python_arg = '-Python $python' if settings['python'] else ''
    return f"""
$ErrorActionPreference = 'Stop'
{environment_block(settings)}
$workspace = {ps_quote(settings['workspace'])}
$incoming = {ps_quote(incoming)}
{SYNC_BLOCK}
& "$workspace/RawLabWindows/build.ps1" -SelfContained -DotNet $dotnet {python_arg} {rum_args} {test_args}
if ($LASTEXITCODE -ne 0) {{ throw 'Windows build failed.' }}
Compress-Archive -Path "$workspace/build/RawLab-Windows/*" -DestinationPath "$incoming/RawLab-Windows.zip"
Write-Output 'PASS: Windows build and artifact packaging'
"""


def read_remote_manifest(settings, full_sync):
    if full_sync:
        return {}
    path = settings['workspace'].rstrip('/\\') + '/' + MANIFEST_NAME
    script = f"$p = {ps_quote(path)}; if (Test-Path -LiteralPath $p) {{ [Convert]::ToBase64String([IO.File]::ReadAllBytes($p)) }}"
    # Windows hosts may answer in a legacy code page (GBK); only the base64 payload matters.
    result = subprocess.run(ssh_command(settings, encode(script)), capture_output=True, text=True, errors='replace')
    if result.returncode:
        raise SystemExit(f'Cannot read the remote manifest ({result.returncode}): {result.stderr.strip()}')
    payload = ''.join(result.stdout.split())
    if not payload:
        return {}
    manifest = json.loads(base64.b64decode(payload).decode('utf-8-sig'))
    return manifest if isinstance(manifest, dict) else {}


def build_parser():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--profile', help='Profile name in the private hosts file')
    parser.add_argument('--profiles-file', type=Path,
                        default=Path(os.environ.get('RAWLAB_WINDOWS_VERIFY_HOSTS', DEFAULT_PROFILES)))
    parser.add_argument('--host', help='SSH user@Windows-host')
    parser.add_argument('--port', type=int)
    parser.add_argument('--proxy-jump', help='SSH jump host (ssh -J)')
    parser.add_argument('--identity', help='SSH private key path (passed to ssh -i, never read)')
    parser.add_argument('--known-hosts', help='Dedicated SSH host-key file')
    parser.add_argument('--pwsh', help='Remote PowerShell executable (default powershell.exe)')
    parser.add_argument('--dotnet-dir', help='Remote directory holding dotnet.exe')
    parser.add_argument('--python', help='Remote python.exe for build.ps1')
    parser.add_argument('--env', action='append', default=[], metavar='NAME=VALUE', help='Extra remote environment')
    parser.add_argument('--workspace', help='Persistent remote workspace (incremental build state lives here)')
    parser.add_argument('--full-sync', action='store_true', help='Ignore the remote manifest and upload every file')
    parser.add_argument('--verify', action='store_true', help='Quick verification instead of building a package')
    parser.add_argument('--models', action='store_true', help='--verify: run Windows model tests')
    parser.add_argument('--ctest-filter', help='--verify: build, then run ctest -R FILTER')
    parser.add_argument('--v08-only', metavar='SUITE', help='--verify: build, then run one run-v08.ps1 suite')
    parser.add_argument('--test', action='store_true', help='Build mode: run the full native/WPF/GPU suite')
    parser.add_argument('--raw', type=Path, help='External RAW fixture for --test or --v08-only')
    parser.add_argument('--rum-sdk-zip', type=Path, help='Vendor AlibabaCloud_RUM_Windows_0.4.4.zip (default: shared cache)')
    parser.add_argument('--no-rum-sdk', action='store_true', help='Offline package without usage analytics')
    return parser


def validate_args(parser, args):
    if args.verify:
        if not (args.models or args.ctest_filter or args.v08_only):
            parser.error('--verify needs at least one of --models, --ctest-filter, --v08-only')
        if args.test:
            parser.error('--test belongs to build mode; use --ctest-filter/--v08-only with --verify')
        if args.ctest_filter and not SAFE_FILTER.match(args.ctest_filter):
            parser.error('--ctest-filter may contain only regex characters [A-Za-z0-9_.*+?^$()[]|-]')
        if args.v08_only and not SAFE_SUITE.match(args.v08_only):
            parser.error('--v08-only expects a suite name')
        if args.v08_only and (args.raw is None or not args.raw.is_file()):
            parser.error('--v08-only requires --raw pointing to an existing RAW fixture')
    else:
        if args.models or args.ctest_filter or args.v08_only:
            parser.error('--models, --ctest-filter and --v08-only require --verify')
        if args.test and (args.raw is None or not args.raw.is_file()):
            parser.error('--test requires --raw pointing to an existing external fixture')
    if args.rum_sdk_zip is not None and not args.rum_sdk_zip.is_file():
        parser.error('--rum-sdk-zip must point to the vendor archive')


def run_remote(settings, script, log_path, incoming):
    """Copy the script to the host, run it, stream output to the terminal and a log file; return the status."""
    local = log_path.parent / 'remote.ps1'
    # UTF-8 with BOM: Windows PowerShell 5.1 reads BOM-less files in the legacy code page.
    local.write_bytes(b'\xef\xbb\xbf' + ("$ProgressPreference = 'SilentlyContinue'\n" + script).encode('utf-8'))
    remote = f'{incoming}/remote.ps1'
    subprocess.run(scp_command(settings, local, f"{settings['host']}:{remote}"), check=True)
    process = subprocess.Popen(ssh_command(settings, script_file=remote), stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT)
    with open(log_path, 'wb') as log:
        for line in process.stdout:
            sys.stdout.buffer.write(line)
            sys.stdout.buffer.flush()
            log.write(line)
    return process.wait()


def main(argv=None):
    parser = build_parser()
    args = parser.parse_args(argv)
    validate_args(parser, args)
    profile = load_profile(args.profiles_file, args.profile) if args.profile else {}
    settings = resolve_settings(args, profile)
    root = Path(__file__).resolve().parents[1]
    stamp = datetime.now().strftime('%Y%m%d-%H%M%S')
    incoming = f'C:/RawLabBuild/incoming/{stamp}-{os.getpid()}'
    started = time.monotonic()

    ensure_lut_assets(root)
    files = source_files(root)
    local = local_manifest(root, files)
    remote = read_remote_manifest(settings, args.full_sync)
    changed, removed = sync_plan(local, remote)
    print(f'Sync to {settings["workspace"]}: {len(changed)} changed, {len(removed)} removed, '
          f'{len(files) - len(changed)} unchanged of {len(files)} files', flush=True)

    # Verify mode keeps nothing in the repository; build mode keeps its artifacts and log as before.
    staging = tempfile.TemporaryDirectory(prefix='rawlab-remote-') if args.verify else None
    output = Path(staging.name) if staging else root / 'build/windows-remote' / stamp
    output.mkdir(parents=True, exist_ok=True)
    try:
        package_changes(root, output / 'changes.zip', local, changed, removed)
        mkdir = encode(f"New-Item -ItemType Directory -Force {ps_quote(incoming)} | Out-Null")
        if subprocess.run(ssh_command(settings, mkdir)).returncode:
            raise SystemExit('Cannot create the remote incoming directory')
        destination = f"{settings['host']}:{incoming}"
        subprocess.run(scp_command(settings, output / 'changes.zip', f'{destination}/changes.zip'), check=True)
        if args.verify:
            raw_name = ''
            if args.v08_only:
                raw_name = 'fixture' + args.raw.suffix.lower()
                subprocess.run(scp_command(settings, args.raw.resolve(), f'{destination}/{raw_name}'), check=True)
            script = verify_script(settings, incoming, args.models, args.ctest_filter, args.v08_only, raw_name)
        else:
            rum_args, rum_archive = rum_build_args(args.no_rum_sdk, args.rum_sdk_zip or rum_sdk_cache(root), incoming)
            if rum_archive:
                subprocess.run(scp_command(settings, rum_archive, f'{destination}/rum-sdk.zip'), check=True)
            test_args = ''
            if args.test:
                fixture = f'fixture{args.raw.suffix.lower()}'
                subprocess.run(scp_command(settings, args.raw.resolve(), f'{destination}/{fixture}'), check=True)
                test_args = f"-Test -RawPath '{incoming}/{fixture}'"
            script = build_script(settings, incoming, rum_args, test_args)
        status = run_remote(settings, script, output / 'remote.log', incoming)
        if status:
            raise SystemExit(f'Remote operation failed ({status})' + ('' if args.verify else f'; logs: {output}'))
        if not args.verify:
            subprocess.run(scp_command(settings, f'{destination}/RawLab-Windows.zip', output), check=True)
            print(f'Built: {output / "RawLab-Windows.zip"}')
        print(f'Total {time.monotonic() - started:.0f} s', flush=True)
    finally:
        if staging:
            staging.cleanup()


if __name__ == '__main__':
    main()
