"""从固定依赖的真实构建生成分代探针契约，运行时绑定二进制与 Python 实现。"""

import argparse
import json
import os
from pathlib import Path
import subprocess

from scene_cache import DECODER_REVISION, digest


def sources():
    return {name: digest(Path(__file__).with_name(name)) for name in
            ('render_family.py', 'family_contract.py', 'scene_cache.py')}


def validate(contract, decoder):
    if (contract.get('schema') != 'rawlab-family-decoder-contract-v1'
            or contract.get('source_revision') != DECODER_REVISION
            or contract.get('decoder_sha256') != digest(decoder)
            or contract.get('native_probe_sha256') != digest(Path(__file__).with_name('decode_family.rs'))
            or contract.get('python_sources') != sources()):
        raise ValueError('Native build contract, executable or rendering implementation changed')


def command(args, cwd):
    return subprocess.check_output(args, cwd=cwd, text=True).strip()


def source_identity(root):
    revision = command(['git', 'rev-parse', 'HEAD'], root)
    if revision != DECODER_REVISION or command(['git', 'status', '--porcelain'], root):
        raise ValueError('The native dependency must be the clean fixed revision')
    return revision, command(['git', 'rev-parse', 'HEAD^{tree}'], root)


def build_contract(manifest):
    manifest = Path(manifest).resolve()
    work = manifest.parent
    lock = work / 'Cargo.lock'
    if not lock.is_file():
        raise ValueError('An existing Cargo.lock is required; prepare and retain it before freezing')
    rustc_details = command(['rustc', '-vV'], work)
    host = next(line.removeprefix('host: ') for line in rustc_details.splitlines() if line.startswith('host: '))
    metadata = json.loads(command(['cargo', 'metadata', '--format-version', '1', '--locked',
                                   '--offline', '--filter-platform', host,
                                   '--manifest-path', str(manifest)], work))
    packages = metadata['packages']
    core = [p for p in packages if p['name'] == 'x3f-core']
    sys = [p for p in packages if p['name'] == 'x3f-sys']
    if len(core) != 1 or len(sys) != 1:
        raise ValueError('Expected exactly one fixed x3f-core and x3f-sys dependency')
    core_manifest = Path(core[0]['manifest_path']).resolve()
    root = Path(command(['git', 'rev-parse', '--show-toplevel'], core_manifest.parent))
    sys_manifest = Path(sys[0]['manifest_path']).resolve()
    if not sys_manifest.is_relative_to(root):
        raise ValueError('Core and sys dependencies must belong to the same fixed source tree')
    identity = source_identity(root)
    package = next(p for p in packages if p['id'] == metadata['resolve']['root'])
    binaries = [target for target in package['targets'] if 'bin' in target['kind']]
    if len(binaries) != 1:
        raise ValueError('Use a standalone probe crate with one binary target')
    probe = Path(binaries[0]['src_path'])
    expected_probe = digest(Path(__file__).with_name('decode_family.rs'))
    if digest(probe) != expected_probe:
        raise ValueError('Probe crate does not contain the current decode_family.rs')
    before = {str(path): digest(path) for path in (manifest, lock, probe, core_manifest, sys_manifest)}
    result = subprocess.run(['cargo', 'build', '--release', '--locked', '--offline',
                             '--target', host, '--manifest-path', str(manifest)], cwd=work,
                            capture_output=True, text=True, check=True)
    if source_identity(root) != identity or any(digest(Path(path)) != sha for path, sha in before.items()):
        raise ValueError('Native build inputs changed during compilation')
    suffix = '.exe' if os.name == 'nt' else ''
    binary = Path(metadata['target_directory']) / host / 'release' / (binaries[0]['name'] + suffix)
    return {
        'schema': 'rawlab-family-decoder-contract-v1', 'source_revision': identity[0],
        'source_tree': identity[1], 'source_root': str(root), 'build_inputs': before,
        'cargo_lock_sha256': digest(lock), 'native_probe_sha256': expected_probe,
        'decoder_path_at_build': str(binary), 'decoder_sha256': digest(binary),
        'python_sources': sources(), 'rustc': rustc_details, 'target': host,
        'cargo': command(['cargo', '--version'], work),
        'build_stdout': result.stdout, 'build_stderr': result.stderr,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--manifest', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.output.exists():
        raise FileExistsError('Build contract already exists')
    contract = build_contract(args.manifest)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open('x') as stream:
        json.dump(contract, stream, indent=2)
        stream.write('\n')
    args.output.chmod(0o444)
    print(json.dumps({'contract': str(args.output), 'decoder': contract['decoder_path_at_build'],
                      'decoder_sha256': contract['decoder_sha256']}))


if __name__ == '__main__':
    main()
