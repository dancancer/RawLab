"""Evidence-bearing native CUBE/VLT contracts. Never infer an author's colors."""
import hashlib
import io
import json
import math
import os
from pathlib import Path
import subprocess
import tempfile

PREFIX = "#RawLabColorContract:"
MAX_BYTES = 256 * 1024 * 1024
SPACES = {"srgb", "rec709-gamma24", "linear-srgb", "vlog-vgamut", "slog3-sgamut3", "slog3-sgamut3-cine"}


def _text(value):
    return isinstance(value, str) and bool(value.strip()) and len(value.encode('utf-8')) <= 4096 and '\0' not in value


def contract_state(contract):
    if not isinstance(contract, dict): return "invalid_contract"
    keys = {"version", "input", "output", "interpolation", "base_rendering", "evidence"}
    if set(contract) not in (keys, keys - {"evidence"}) or type(contract.get('version')) is not int or contract['version'] != 1:
        return "invalid_contract"
    for key in ("input", "output"):
        signal = contract[key]
        if not isinstance(signal, dict) or set(signal) != {"space", "reference", "range"}:
            return "unsupported_contract"
        if not all(isinstance(v, str) for v in signal.values()): return "invalid_contract"
        space, reference = signal['space'], signal['reference']
        if space not in SPACES or reference not in {"scene", "display"} or signal['range'] not in {"full", "legal10"}:
            return "unsupported_contract"
        if space in {"srgb", "rec709-gamma24"} and reference != "display": return "unsupported_contract"
        if space.startswith(('vlog', 'slog3')) and reference != "scene": return "unsupported_contract"
    if contract['interpolation'] not in ("linear", "tetrahedral"): return "unsupported_contract"
    base = contract['base_rendering']
    if base not in ("none", "rawlab-neutral-v1", "source-display"): return "unsupported_contract"
    if contract['input']['reference'] == 'display':
        if base == 'none' or contract['output']['reference'] == 'scene': return "unsupported_contract"
    elif base != 'none': return "unsupported_contract"
    evidence = contract.get('evidence')
    if evidence is None: return "missing_reference"
    if not isinstance(evidence, dict) or set(evidence) != {'source', 'conditions'}: return "invalid_contract"
    return "declared_unverified" if all(_text(v) for v in evidence.values()) else "missing_reference"


def _unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result: raise ValueError(f'Duplicate JSON field: {key}')
        result[key] = value
    return result


def read_json_document(path):
    path = Path(path)
    if path.stat().st_size > 32 * 1024 * 1024: raise ValueError('Reference document exceeds 32 MiB')
    return json.loads(path.read_text(encoding='utf-8-sig'), object_pairs_hook=_unique_object)


def inspect_lut(source):
    source = Path(source)
    if source.suffix.lower() not in {'.cube', '.vlt'}: raise ValueError('Expected CUBE or VLT')
    if source.stat().st_size > MAX_BYTES: raise ValueError('LUT exceeds 256 MiB')
    vlt = source.suffix.lower() == '.vlt'
    size, rows, low, high = None, 0, None, None
    declaration, declarations, state, style, legacy = None, 0, 'missing_color', '', False
    vlt_header, vlt_source = False, False
    color_keys, duplicate_color = set(), False
    compatibility, compatibility_offset, offset, extreme = None, -1, 0, False
    raw = source.read_bytes()
    with io.BytesIO(raw) as stream:
        for raw_line in stream:
            if compatibility_offset >= 0: raise ValueError('Data after compatibility record')
            line_offset = offset; offset += len(raw_line)
            line = raw_line.decode('utf-8-sig' if line_offset == 0 else 'utf-8')
            if len(raw_line) > 65537: raise ValueError('LUT line exceeds limit')
            line = line.strip()
            if not line: continue
            if line.startswith('#'):
                if line == '# panasonic vlt file version 1.0': vlt_header = True
                if line.startswith('# source vlt file "') and line.endswith('"'): vlt_source = True
                if line.startswith('#LUMIXPHOTOSTYLE '):
                    duplicate_color |= 'lumixphotostyle' in color_keys
                    color_keys.add('lumixphotostyle')
                    style = line.split()[-1].lower()
                key, _, value = line[1:].partition(':')
                key = ''.join(c.lower() for c in key if c.isascii() and c.isalnum())
                if key in {'gamma', 'gamut'}:
                    duplicate_color |= key in color_keys
                    color_keys.add(key)
                    legacy = True
                if key == 'rawlabcolorcontract':
                    declarations += 1
                    try:
                        declaration = json.loads(value, object_pairs_hook=_unique_object)
                        state = contract_state(declaration)
                    except (ValueError, TypeError): state = 'invalid_contract'
                if key == 'rawlabcompatibility':
                    compatibility_offset = line_offset
                    try: compatibility = json.loads(value, object_pairs_hook=_unique_object)
                    except (ValueError, TypeError): compatibility = {}
                continue
            fields = line.split('#', 1)[0].split()
            if fields[0] == 'TITLE': continue
            if fields[0] == 'LUT_3D_SIZE':
                if size is not None or len(fields) != 2: raise ValueError('Invalid or duplicate LUT size')
                size = int(fields[1])
                if not 2 <= size <= 256 or vlt and size != 17: raise ValueError('Unsupported LUT size')
            elif fields[0] in {'DOMAIN_MIN', 'DOMAIN_MAX'}:
                if vlt or len(fields) != 4: raise ValueError('Invalid input domain')
                values = [float(v) for v in fields[1:]]
                if not all(math.isfinite(v) for v in values): raise ValueError('Nonfinite input domain')
                if fields[0] == 'DOMAIN_MIN':
                    if low is not None: raise ValueError('Duplicate domain minimum')
                    low = values
                else:
                    if high is not None: raise ValueError('Duplicate domain maximum')
                    high = values
            else:
                if size is None or len(fields) != 3: raise ValueError('Expected three RGB values after LUT size')
                values = [float(v) for v in fields]
                if not all(math.isfinite(v) for v in values): raise ValueError('Nonfinite LUT value')
                if vlt and not all(v.is_integer() and 0 <= v <= 4095 for v in values): raise ValueError('VLT requires 12-bit integer values')
                extreme |= max(abs(v) for v in values) / (4095 if vlt else 1) > 16
                rows += 1
                if rows > size**3: raise ValueError('Extra LUT rows')
    low, high = low or [0., 0., 0.], high or [1., 1., 1.]
    if size is None or rows != size**3 or any(a >= b for a, b in zip(low, high)): raise ValueError('Incomplete LUT or invalid domain')
    if vlt and not (vlt_header and vlt_source): raise ValueError('Missing VLT 1.0 header')
    if declarations > 1 or declarations and legacy or duplicate_color or style and legacy: state = 'invalid_contract'
    if style and state == 'declared_unverified':
        matching = (style == 'vlog' and declaration['input']['space'] == 'vlog-vgamut') or (
            style == 'std' and declaration['input']['reference'] == 'display' and declaration['base_rendering'] == 'source-display')
        if not matching: state = 'unsupported_contract'
    if compatibility_offset >= 0:
        original_state = state
        state = 'invalid_contract'
        try:
            expected = {'version', 'source_bytes', 'source_sha256', 'confirmed', 'contract'}
            valid_keys = set(compatibility) in (expected, expected | {'confirmed_extreme_values'})
            effective = compatibility['contract']
            length = compatibility['source_bytes']
            original_parameters = {k: v for k, v in declaration.items() if k != 'evidence'} if declaration else None
            matches_style = not style or (style == 'vlog' and effective['input']['space'] == 'vlog-vgamut') or (
                style == 'std' and effective['input']['reference'] == 'display')
            if (valid_keys and type(compatibility['version']) is int and compatibility['version'] == 1 and
                compatibility['confirmed'] is True and type(length) is int and length >= 0 and
                length == compatibility_offset - 1 and raw[length:length+1] == b'\n' and
                hashlib.sha256(raw[:length]).hexdigest() == compatibility['source_sha256'] and
                original_state in ('missing_color', 'missing_reference') and not legacy and
                (not extreme or compatibility.get('confirmed_extreme_values') is True) and
                'evidence' not in effective and contract_state(effective) == 'missing_reference' and matches_style and
                (not declaration or original_parameters == effective)):
                declaration = effective
                state = 'approximate_base' if effective['base_rendering'] == 'rawlab-neutral-v1' else 'compatibility'
        except (ValueError, TypeError, KeyError): pass
    return {'format': 'vlt' if vlt else 'cube', 'size': size, 'domain_min': low, 'domain_max': high,
            'canonical': False, 'native_photo_compatible': state in ('declared_unverified', 'compatibility', 'approximate_base'),
            'color_state': state, 'color_contract': declaration, 'appearance': 'unverified',
            'lumix_photo_style': style or None}


def _probe(probe, *arguments, input_text=None):
    process = subprocess.run([str(probe), *map(str, arguments)], input=input_text,
                             text=True, capture_output=True, timeout=120)
    if process.returncode: raise ValueError(f'Native LUT validation failed: {process.stderr.strip()}')
    return process.stdout


def attach_contract(source, destination, manifest, probe):
    source, destination = Path(source), Path(destination)
    if source.resolve() == destination.resolve() or destination.exists() and os.path.samefile(source, destination):
        raise ValueError('Source and destination must differ')
    if destination.exists(): raise FileExistsError(destination)
    if destination.suffix.lower() != source.suffix.lower(): raise ValueError('Preserve the original CUBE/VLT format')
    if not isinstance(manifest, dict) or set(manifest) != {'source_sha256', 'contract'}: raise ValueError('Manifest requires source_sha256 and contract')
    info = inspect_lut(source)
    if info['color_contract'] is not None: raise ValueError('Source already has an explicit contract')
    original = source.read_bytes()
    digest = hashlib.sha256(original).hexdigest()
    if manifest['source_sha256'] != digest: raise ValueError('Source SHA-256 differs from the documented LUT')
    if contract_state(manifest['contract']) != 'declared_unverified': raise ValueError('Explicit supported colors and reference evidence are required')
    descriptor, name = tempfile.mkstemp(prefix='.rawlab-contract-', suffix=source.suffix, dir=destination.parent)
    temporary = Path(name)
    try:
        with os.fdopen(descriptor, 'wb') as stream:
            stream.write(original)
            stream.write(('\n' + PREFIX + json.dumps(manifest['contract'], ensure_ascii=True, separators=(',', ':')) +
                          '\n#RawLabSourceSHA256:' + digest + '\n').encode())
        native = json.loads(_probe(probe, 'inspect', temporary))
        if native['state'] != 'declared_unverified': raise ValueError(f"Native color state: {native['state']}")
        os.link(temporary, destination)
    finally:
        temporary.unlink(missing_ok=True)
    return {'mode': 'original-table', 'source': source.name, 'source_sha256': digest,
            'asset_sha256': hashlib.sha256(destination.read_bytes()).hexdigest(),
            'contract': manifest['contract'], 'appearance': 'unverified', 'resampling': False}


def verify_reference(asset, reference, probe):
    asset = Path(asset)
    info = inspect_lut(asset)
    if info['color_state'] != 'declared_unverified': raise ValueError('Asset has no usable explicit contract')
    if not isinstance(reference, dict) or set(reference) != {'version', 'asset_sha256', 'contract', 'input_kind', 'max_error', 'evaluator', 'samples'}:
        raise ValueError('Incomplete reference conditions')
    if type(reference['version']) is not int or reference['version'] != 1: raise ValueError('Unsupported reference version')
    if reference['asset_sha256'] != hashlib.sha256(asset.read_bytes()).hexdigest() or reference['contract'] != info['color_contract']:
        raise ValueError('Reference asset or color conditions differ')
    if reference['input_kind'] not in {'scene', 'display'}: raise ValueError('Reference must declare linear-sRGB scene or display input')
    evaluator = reference['evaluator']
    if not isinstance(evaluator, dict) or set(evaluator) != {'kind', 'name', 'version', 'provenance'} or evaluator['kind'] != 'independent' or not all(_text(v) for v in evaluator.values()):
        raise ValueError('An independent evaluator and reproducible provenance are required')
    if any(word in evaluator['name'].lower() for word in ('rawlab', 'lutprep')): raise ValueError('RawLab cannot be its own appearance reference')
    tolerance = reference['max_error']
    if type(tolerance) not in (int, float) or not math.isfinite(tolerance) or not 0 <= tolerance <= .02:
        raise ValueError('Reference must declare a finite channel tolerance in 0..0.02 before comparison')
    samples = reference['samples']
    if not isinstance(samples, list) or not 1 <= len(samples) <= 100000: raise ValueError('Expected 1..100000 named reference samples')
    seen, lines, expected = set(), [], []
    for sample in samples:
        if not isinstance(sample, dict) or set(sample) != {'id', 'input_rgb', 'output_rgb'} or not _text(sample['id']) or sample['id'] in seen:
            raise ValueError('Samples require unique IDs and input/output RGB')
        seen.add(sample['id'])
        for key in ('input_rgb', 'output_rgb'):
            rgb = sample[key]
            if not isinstance(rgb, list) or len(rgb) != 3 or not all(type(v) in (int, float) and math.isfinite(v) for v in rgb):
                raise ValueError('Expected finite RGB triples')
        if not all(0 <= v <= 1 for v in sample['output_rgb']): raise ValueError('Reference output must be display sRGB in 0..1')
        lines.append(' '.join(format(v, '.9g') for v in sample['input_rgb']))
        expected.append(sample['output_rgb'])
    output = _probe(probe, 'evaluate', asset, reference['input_kind'], input_text='\n'.join(lines)+'\n')
    actual = [[float(v) for v in line.split()] for line in output.splitlines()]
    if len(actual) != len(expected) or any(len(row) != 3 or not all(math.isfinite(v) for v in row) for row in actual):
        raise ValueError('Native evaluator returned invalid sample data')
    errors = [max(abs(a-b) for a, b in zip(row, ref)) for row, ref in zip(actual, expected)]
    if reference['asset_sha256'] != hashlib.sha256(asset.read_bytes()).hexdigest():
        raise ValueError('Asset changed during reference evaluation')
    return {'sample_agreement': max(errors) <= tolerance, 'max_error': max(errors), 'tolerance': tolerance,
            'samples': [{'id': sample['id'], 'max_error': error} for sample, error in zip(samples, errors)],
            'asset_sha256': reference['asset_sha256'], 'evaluator': evaluator, 'appearance': 'unverified',
            'scope': 'Named-sample agreement only; author appearance and camera base rendering need controlled image references'}
