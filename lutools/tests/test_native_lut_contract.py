import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import contextlib
import io

from lutools.lutprep.native_lut import attach_contract, inspect_lut, verify_reference


def contract():
    return {"version": 1,
            "input": {"space": "vlog-vgamut", "reference": "scene", "range": "full"},
            "output": {"space": "srgb", "reference": "display", "range": "full"},
            "interpolation": "linear", "base_rendering": "none",
            "evidence": {"source": "Synthetic reference specification", "conditions": "RGB identity, full-range V-Log to display sRGB"}}


class NativeLUTContractTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="rawlab-native-lut-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / "original.cube"
        self.source.write_text('TITLE "Original"\nLUT_3D_SIZE 2\n' +
                               ''.join(f'{r} {g} {b}\n' for b in (0, 1) for g in (0, 1) for r in (0, 1)))
        self.manifest = {"source_sha256": hashlib.sha256(self.source.read_bytes()).hexdigest(), "contract": contract()}
        self.probe = os.environ.get("RAWLAB_LUT_PROBE")

    def test_unknown_metadata_remains_missing(self):
        self.assertEqual(inspect_lut(self.source)["color_state"], "missing_color")
        with self.source.open('a') as stream:
            stream.write('#LUMIXPHOTOSTYLE VLOG\n')
        self.assertEqual(inspect_lut(self.source)["color_state"], "missing_color")

    def test_compatibility_preserves_provenance_and_rejects_tampering(self):
        original = self.source.read_bytes()
        effective = contract(); effective.pop('evidence')
        record = {'version': 1, 'source_bytes': len(original), 'source_sha256': hashlib.sha256(original).hexdigest(),
                  'confirmed': True, 'contract': effective}
        self.source.write_bytes(original + b'\n#RawLabCompatibility:' + json.dumps(record).encode() + b'\n')
        info = inspect_lut(self.source)
        self.assertEqual(info['color_state'], 'compatibility')
        self.assertTrue(info['native_photo_compatible'])
        self.assertEqual(info['appearance'], 'unverified')
        record['confirmed'] = False
        self.source.write_bytes(original + b'\n#RawLabCompatibility:' + json.dumps(record).encode() + b'\n')
        self.assertEqual(inspect_lut(self.source)['color_state'], 'invalid_contract')
        record['confirmed'] = True; record['source_sha256'] = '0' * 64
        self.source.write_bytes(original + b'\n#RawLabCompatibility:' + json.dumps(record).encode() + b'\n')
        self.assertEqual(inspect_lut(self.source)['color_state'], 'invalid_contract')

    def test_missing_reference_and_camera_base_do_not_become_ready(self):
        c = contract(); c.pop("evidence")
        with self.source.open('a') as stream:
            stream.write('#RawLabColorContract:' + json.dumps(c) + '\n')
        self.assertEqual(inspect_lut(self.source)["color_state"], "missing_reference")

    def test_compatibility_routes_through_public_inspection_and_cli(self):
        from lutools.lutprep.bake import inspect_source
        from lutools.lutprep.__main__ import main

        table = self.source.read_bytes()
        effective = contract(); effective.pop('evidence')
        for explicit in (False, True):
            with self.subTest(explicit_contract=explicit):
                original = table
                if explicit:
                    original += b'#RawLabColorContract:' + json.dumps(effective).encode() + b'\n'
                record = {'version': 1, 'source_bytes': len(original),
                          'source_sha256': hashlib.sha256(original).hexdigest(),
                          'confirmed': True, 'contract': effective}
                self.source.write_bytes(original + b'\n#RawLabCompatibility:' + json.dumps(record).encode() + b'\n')
                info = inspect_source(self.source)
                self.assertEqual(info['color_state'], 'compatibility')
                self.assertTrue(info['native_photo_compatible'])
                for command in (['inspect', str(self.source)], ['audit', str(self.source), '--verify-compile']):
                    output = io.StringIO()
                    with contextlib.redirect_stdout(output):
                        result = main(command)
                    self.assertEqual(result, 0)
                    report = json.loads(output.getvalue())
                    if command[0] == 'audit':
                        entry, = report['entries']
                        self.assertEqual(entry['read']['status'], 'passed')
                        self.assertEqual(entry['compile']['status'], 'not_run')
                        report = entry['metadata']
                    self.assertEqual(report['color_state'], 'compatibility')
                    self.assertTrue(report['native_photo_compatible'])
                    self.assertEqual(report['appearance'], 'unverified')

                record['source_sha256'] = '0' * 64
                self.source.write_bytes(original + b'\n#RawLabCompatibility:' + json.dumps(record).encode() + b'\n')
                info = inspect_source(self.source)
                self.assertEqual(info['color_state'], 'invalid_contract')
                self.assertFalse(info['native_photo_compatible'])

    def test_repeated_color_comments_are_invalid(self):
        with self.source.open('a') as stream:
            stream.write('#LUMIXPHOTOSTYLE STD\n#LUMIXPHOTOSTYLE VLOG\n#RawLabColorContract:' + json.dumps(contract()) + '\n')
        self.assertEqual(inspect_lut(self.source)['color_state'], 'invalid_contract')

    def test_vlt_preserves_integer_knots(self):
        source = self.root / 'identity.vlt'
        source.write_text('# panasonic vlt file version 1.0\n# source vlt file ""\nLUT_3D_SIZE 17\n\n' +
                          ''.join(f'{min(r*256,4095)} {min(g*256,4095)} {min(b*256,4095)}\n'
                                  for b in range(17) for g in range(17) for r in range(17)))
        info = inspect_lut(source)
        self.assertEqual((info['format'], info['size'], info['color_state']), ('vlt', 17, 'missing_color'))
        source.write_text(source.read_text().replace('4095 4095 4095', '4096 4095 4095'))
        with self.assertRaises(ValueError): inspect_lut(source)

    def test_attach_requires_hash_reference_and_native_validation(self):
        if not self.probe: self.skipTest('Set RAWLAB_LUT_PROBE to the current native probe')
        original = self.source.read_bytes(); output = self.root/'prepared.cube'
        bad = dict(self.manifest, source_sha256='0'*64)
        with self.assertRaises(ValueError): attach_contract(self.source, output, bad, self.probe)
        self.assertFalse(output.exists())
        c = contract(); c.pop('evidence')
        with self.assertRaises(ValueError): attach_contract(self.source, output, dict(self.manifest, contract=c), self.probe)
        self.assertFalse(output.exists())
        report = attach_contract(self.source, output, self.manifest, self.probe)
        self.assertEqual(self.source.read_bytes(), original)
        self.assertTrue(output.read_bytes().startswith(original))
        self.assertEqual(report['appearance'], 'unverified')
        self.assertEqual(inspect_lut(output)['color_state'], 'declared_unverified')
        with self.assertRaises(FileExistsError): attach_contract(self.source, output, self.manifest, self.probe)
        with self.assertRaises(ValueError): attach_contract(self.source, self.source, self.manifest, self.probe)
        alias = self.root/'alias.cube'; os.link(self.source, alias)
        with self.assertRaises(ValueError): attach_contract(self.source, alias, self.manifest, self.probe)

    def test_cli_rejects_duplicate_manifest_fields(self):
        if not self.probe: self.skipTest('Set RAWLAB_LUT_PROBE to the current native probe')
        from lutools.lutprep.__main__ import main
        path = self.root/'duplicate.json'
        path.write_text('{"source_sha256":"conflicting",' + json.dumps(self.manifest)[1:])
        output = self.root/'blocked.cube'
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            result = main(['attach-contract', str(self.source), str(output), '--manifest', str(path), '--probe', self.probe])
        self.assertEqual(result, 2)
        self.assertFalse(output.exists())

    def test_independent_reference_matches_exact_asset_and_conditions(self):
        if not self.probe: self.skipTest('Set RAWLAB_LUT_PROBE to the current native probe')
        output = self.root/'prepared.cube'
        attach_contract(self.source, output, self.manifest, self.probe)
        reference = {'version': 1, 'asset_sha256': hashlib.sha256(output.read_bytes()).hexdigest(),
                     'contract': contract(), 'input_kind': 'scene', 'max_error': .0001,
                     'evaluator': {'kind': 'independent', 'name': 'Panasonic published gray anchors',
                                   'version': '1.0', 'provenance': 'VARICAM V-Log/V-Gamut manual formula, neutral D65'},
                     'samples': [{'id': 'black', 'input_rgb': [0, 0, 0], 'output_rgb': [.125]*3},
                                 {'id': 'gray', 'input_rgb': [.18]*3, 'output_rgb': [.42331144876]*3}]}
        report = verify_reference(output, reference, self.probe)
        self.assertTrue(report['sample_agreement'])
        self.assertEqual(report['appearance'], 'unverified')
        bad = dict(reference, asset_sha256='0'*64)
        with self.assertRaises(ValueError): verify_reference(output, bad, self.probe)
        bad = dict(reference, evaluator=dict(reference['evaluator'], kind='internal'))
        with self.assertRaises(ValueError): verify_reference(output, bad, self.probe)
        bad = dict(reference, samples=[])
        with self.assertRaises(ValueError): verify_reference(output, bad, self.probe)
        reference['samples'][0]['output_rgb'] = [.5]*3
        self.assertFalse(verify_reference(output, reference, self.probe)['sample_agreement'])

    def test_cli_audit_reports_vlt_instead_of_skipping_it(self):
        source = self.root/'bad.vlt'; source.write_text('broken')
        from lutools.lutprep.audit import audit_sources
        report = audit_sources([self.root])
        entry = next(e for e in report['entries'] if e['path'] == 'bad.vlt')
        self.assertEqual(entry['read']['status'], 'failed')

    def test_native_color_chain_matches_independent_ocio_with_range_and_domain(self):
        if not self.probe: self.skipTest('Set RAWLAB_LUT_PROBE to the current native probe')
        import numpy as np
        from lutools.lutprep.color import ColorSpaces, apply_processor
        from lutools.lutprep.pipeline import file_processor
        spaces = ColorSpaces()
        rng = np.random.default_rng(20261028)
        samples = np.vstack([np.eye(3), [[.18]*3], rng.uniform(-.01, 4, (256, 3))]).astype(np.float32)
        for name in ('vlog-vgamut', 'slog3-sgamut3', 'slog3-sgamut3-cine'):
            for interpolation in ('linear', 'tetrahedral'):
                with self.subTest(space=name, interpolation=interpolation):
                    c = contract(); c['input'].update(space=name, range='legal10')
                    c['output'].update(space='rec709-gamma24', range='legal10')
                    c['interpolation'] = interpolation
                    source = self.root/'oracle.cube'
                    grid = np.linspace(0, 1, 5)
                    source.write_text('#RawLabColorContract:' + json.dumps(c) +
                                      '\nLUT_3D_SIZE 5\nDOMAIN_MIN -0.1 0 0\nDOMAIN_MAX 1.1 1 0.9\n' +
                                      ''.join(f'{b*b} {r*g} {r*.8+.02}\n' for b in grid for g in grid for r in grid))
                    encoded = (64 + 876*spaces.convert(samples, 'linear-srgb', name))/1023
                    expected = apply_processor(file_processor(source, interpolation), encoded)
                    expected = np.clip(spaces.convert((expected*1023-64)/876, 'rec709-gamma24', 'srgb'), 0, 1)
                    run = subprocess.run([self.probe, 'evaluate', str(source), 'scene'],
                                         input='\n'.join(' '.join(map(str, row)) for row in samples)+'\n',
                                         text=True, capture_output=True, check=True)
                    actual = np.array([[float(v) for v in row.split()] for row in run.stdout.splitlines()])
                    np.testing.assert_allclose(actual, expected, rtol=0, atol=3e-4)


if __name__ == '__main__': unittest.main()
