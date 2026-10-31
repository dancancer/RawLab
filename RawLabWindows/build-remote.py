#!/usr/bin/env python3
"""Build the current working files on a prepared Windows OpenSSH host."""
import argparse
import base64
from datetime import datetime
import hashlib
import json
from pathlib import Path
import subprocess
import zipfile

SOURCE_PATHS = ['RawLabWindows', 'lutools', 'RawLabMac/Resources', 'Shared', 'LICENSE',
                'LICENSE-ALIYUN-RUM-EXCEPTION', 'docs/reference/licensing.md']
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


def package_source(root, archive):
    listed = subprocess.check_output([
        'git', '-C', str(root), 'ls-files', '-z', '--cached', '--others',
        '--exclude-standard', '--', *SOURCE_PATHS])
    files = sorted({name.decode() for name in listed.split(b'\0') if name and
                    (root / name.decode()).is_file() and
                    (Path(name.decode()).suffix.lower() not in RAW_SUFFIXES or
                     name.decode() in SYNTHETIC_RAW_FIXTURES)})
    with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED) as package:
        for name in files:
            package.write(root / name, name)
        package.writestr('source-files.json', json.dumps(files))
    return files


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--host', required=True, help='SSH user@Windows-host')
    parser.add_argument('--identity', type=Path, default=Path.home() / '.ssh/rawlab_vm100')
    parser.add_argument('--known-hosts', type=Path, help='Optional dedicated SSH host-key file')
    parser.add_argument('--test', action='store_true', help='Run the full native/WPF/GPU suite')
    parser.add_argument('--raw', type=Path, help='External RAW fixture required by --test')
    parser.add_argument('--workspace', default='C:/RawLabBuild/workspace', help='Isolated remote build checkout')
    parser.add_argument('--rum-sdk-zip', type=Path, help='Vendor AlibabaCloud_RUM_Windows_0.4.4.zip (default: shared cache)')
    parser.add_argument('--no-rum-sdk', action='store_true', help='Offline package without usage analytics')
    args = parser.parse_args()
    if args.test and (args.raw is None or not args.raw.is_file()):
        parser.error('--test requires --raw pointing to an existing external fixture')
    if args.rum_sdk_zip is not None and not args.rum_sdk_zip.is_file():
        parser.error('--rum-sdk-zip must point to the vendor archive')
    root = Path(__file__).resolve().parents[1]
    stamp = datetime.now().strftime('%Y%m%d-%H%M%S')
    output = root / 'build/windows-remote' / stamp
    output.mkdir(parents=True)
    files = package_source(root, output / 'source.zip')
    options = ['-o', 'BatchMode=yes', '-o', 'IdentitiesOnly=yes',
               '-o', 'StrictHostKeyChecking=yes', '-i', str(args.identity.expanduser())]
    if args.known_hosts:
        options += ['-o', f'UserKnownHostsFile={args.known_hosts.expanduser()}']

    def powershell(script, log=None):
        script = "$ProgressPreference = 'SilentlyContinue'\n" + script
        encoded = base64.b64encode(script.encode('utf-16le')).decode()
        result = subprocess.run(['ssh', *options, args.host, 'powershell.exe',
                                 '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
                                 '-EncodedCommand', encoded], stdout=log,
                                stderr=subprocess.STDOUT if log else None)
        if result.returncode:
            raise SystemExit(f'Remote operation failed ({result.returncode}); logs: {output}')

    incoming = f'C:/RawLabBuild/incoming/{stamp}'
    workspace = args.workspace
    if not workspace.startswith('C:/RawLabBuild/') or any(c in workspace for c in "'\r\n"):
        parser.error('--workspace must be a directory under C:/RawLabBuild')
    powershell(f"New-Item -ItemType Directory -Force '{incoming}' | Out-Null")
    subprocess.run(['scp', *options, str(output / 'source.zip'),
                    f'{args.host}:{incoming}/source.zip'], check=True)
    rum_args, rum_archive = rum_build_args(args.no_rum_sdk, args.rum_sdk_zip or rum_sdk_cache(root), incoming)
    if rum_archive:
        subprocess.run(['scp', *options, str(rum_archive), f'{args.host}:{incoming}/rum-sdk.zip'], check=True)
    if args.test:
        subprocess.run(['scp', *options, str(args.raw.resolve()),
                        f'{args.host}:{incoming}/fixture{args.raw.suffix.lower()}'], check=True)
    fixture = f'{incoming}/fixture{args.raw.suffix.lower()}' if args.test else ''
    test_args = f"-Test -RawPath '{fixture}'" if args.test else ''
    script = f"""
$ErrorActionPreference = 'Stop'
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$env:VSCMD_SKIP_SENDTELEMETRY = '1'
$env:PATH = 'C:\\Program Files\\dotnet;' + $env:PATH
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$workspace = '{workspace}'
$incoming = '{incoming}'
$staging = Join-Path $incoming 'source'
Expand-Archive -LiteralPath "$incoming/source.zip" -DestinationPath $staging
$current = @(Get-Content "$staging/source-files.json" -Raw | ConvertFrom-Json)
$previousManifest = Join-Path $workspace 'source-files.json'
if (Test-Path $previousManifest) {{
    foreach ($name in (Get-Content $previousManifest -Raw | ConvertFrom-Json)) {{
        $path = [IO.Path]::GetFullPath((Join-Path $workspace $name))
        $prefix = [IO.Path]::GetFullPath($workspace).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
        if (-not $path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {{ throw 'Invalid source manifest path.' }}
        if ($name -notin $current -and (Test-Path -LiteralPath $path -PathType Leaf)) {{ Remove-Item -LiteralPath $path }}
    }}
}}
New-Item -ItemType Directory -Force $workspace | Out-Null
Copy-Item "$staging/*" $workspace -Recurse -Force
& "$workspace/RawLabWindows/build.ps1" -SelfContained {rum_args} {test_args}
if ($LASTEXITCODE -ne 0) {{ throw 'Windows build failed.' }}
Compress-Archive -Path "$workspace/build/RawLab-Windows/*" -DestinationPath "$incoming/RawLab-Windows.zip"
Write-Output 'PASS: Windows build and artifact packaging'
"""
    print(f'Building {len(files)} current source files on {args.host}; log: {output / "build.log"}', flush=True)
    with (output / 'build.log').open('w') as log:
        powershell(script, log)
    subprocess.run(['scp', *options, f'{args.host}:{incoming}/RawLab-Windows.zip', str(output)], check=True)
    print(f'Built: {output / "RawLab-Windows.zip"}')


if __name__ == '__main__':
    main()
