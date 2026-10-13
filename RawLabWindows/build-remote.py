#!/usr/bin/env python3
"""Build the current working files on a prepared Windows OpenSSH host."""
import argparse
import base64
from datetime import datetime
import json
from pathlib import Path
import subprocess
import zipfile

SOURCE_PATHS = ['RawLabWindows', 'lutools', 'RawLabMac/Resources', 'Shared', 'LICENSE',
                'docs/licensing.md']
RAW_SUFFIXES = {'.arw', '.nef', '.cr2', '.cr3', '.raf', '.rw2', '.orf', '.3fr', '.dng', '.pef'}
SYNTHETIC_RAW_FIXTURES = {
    'lutools/tests/fixtures/' + name for name in
    ('linear-jxl.dng', 'linear-uncompressed.dng', 'linear-jxl-gain.dng', 'linear-doubled.dng',
     'linear-jxl-stage1.dng', 'linear-halved.dng', 'linear-jxl-crop-gain.dng',
     'linear-crop-doubled.dng', 'linear-jxl-required-unknown.dng',
     'linear-jxl-default-crop-gain.dng', 'linear-default-crop-doubled.dng',
     'linear-jxl-channel-levels.dng', 'linear-channel-levels.dng', 'linear-normalized.dng',
     'linear-jxl-lens.dng', 'linear-lens.dng', 'linear-jxl-stage3-lens.dng')
}


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
    args = parser.parse_args()
    if args.test and (args.raw is None or not args.raw.is_file()):
        parser.error('--test requires --raw pointing to an existing external fixture')
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
& "$workspace/RawLabWindows/build.ps1" -SelfContained {test_args}
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
