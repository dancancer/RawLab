import importlib
import json
import sys
from pathlib import Path
import tempfile
import unittest

import numpy as np
import tifffile
from PIL import ImageCms


class FamilyOutputTests(unittest.TestCase):
    def module(self):
        try:
            return importlib.import_module('render_family')
        except ImportError:
            self.fail('The explicit native-family renderer is not implemented')

    def fixture(self, root, *, dtype=np.uint16, orientation=1, icc=True):
        path = Path(root) / 'native.tif'
        pixels = np.array([[101, 12345, 65535], [401, 23456, 50000]], dtype=np.uint16).astype(dtype)
        pixels = np.repeat(pixels[..., None], 3, axis=-1)
        profile = ImageCms.ImageCmsProfile(ImageCms.createProfile('sRGB')).tobytes()
        tags = [(274, 'H', 1, orientation, False)]
        if icc:
            tags.append((34675, 'B', len(profile), profile, False))
        tifffile.imwrite(path, pixels, photometric='rgb', metadata=None, extratags=tags)
        return path, pixels, profile

    def test_protocol_rejects_a_different_source_or_processing_path(self):
        module = self.module()
        with tempfile.TemporaryDirectory() as root:
            raw = Path(root) / 'input.X3F'; raw.write_bytes(b'input')
            valid = {'schema': 'rawlab-family-render-v1',
                     'decoder_revision': '00f9ef206a2d629bca35ceead4b3951833b85d3d',
                     'source_path': str(raw.resolve()), 'header_version': 0x30000,
                     'pipeline': 'merrill-spp', 'color_encoding': 'sRGB',
                     'denoise_backend': 'cpu', 'denoise_intensity': 10,
                     'spp_denoise': True, 'camera_mode': 'as-shot',
                     'environment_policy': 'x3f-tunables-cleared',
                     'settings_policy': 'fixed-native-settings-not-saved-adjustments'}
            module.validate_protocol(valid, raw, 'merrill-spp')
            for key, value in [('source_path', str(Path(root) / 'other.X3F')),
                               ('pipeline', 'native'), ('spp_denoise', False),
                               ('denoise_backend', 'auto'), ('denoise_intensity', 0),
                               ('camera_mode', None), ('color_encoding', 'AdobeRGB'),
                               ('environment_policy', 'inherited'),
                               ('decoder_revision', 'different')]:
                with self.subTest(key=key), self.assertRaises(ValueError):
                    module.validate_protocol({**valid, key: value}, raw, 'merrill-spp')

    def test_orientation_and_dpi_preserve_exact_uint16_pixels_and_icc(self):
        module = self.module()
        expected = {
            1: [[101, 12345, 65535], [401, 23456, 50000]],
            2: [[65535, 12345, 101], [50000, 23456, 401]],
            3: [[50000, 23456, 401], [65535, 12345, 101]],
            4: [[401, 23456, 50000], [101, 12345, 65535]],
            5: [[101, 401], [12345, 23456], [65535, 50000]],
            6: [[401, 101], [23456, 12345], [50000, 65535]],
            7: [[50000, 65535], [23456, 12345], [401, 101]],
            8: [[65535, 50000], [12345, 23456], [101, 401]],
        }
        for orientation, values in expected.items():
            with self.subTest(orientation=orientation), tempfile.TemporaryDirectory() as root:
                native, _, icc = self.fixture(root, orientation=orientation)
                output = Path(root) / 'output.tif'
                module.publish_output(native, output, {'role': 'test'})
                with tifffile.TiffFile(output) as tif:
                    page = tif.pages[0]
                    want = np.repeat(np.array(values, dtype=np.uint16)[..., None], 3, axis=-1)
                    np.testing.assert_array_equal(page.asarray(), want)
                    self.assertEqual(page.tags[34675].value, icc)
                    self.assertEqual(page.tags['XResolution'].value, (180, 1))
                    self.assertEqual(page.tags['YResolution'].value, (180, 1))
                    self.assertEqual(page.tags['ResolutionUnit'].value, 2)
                    self.assertNotIn('Orientation', page.tags)
                report = json.loads(Path(str(output) + '.json').read_text())
                self.assertEqual(report['shape'], list(want.shape))
                self.assertEqual(report['native_orientation'], orientation)
                self.assertEqual(report['output_sha256'], module.digest(output))

    def test_invalid_pixel_depth_profile_or_orientation_publishes_nothing(self):
        module = self.module()
        for config in ({'dtype': np.float32}, {'dtype': np.uint8}, {'icc': False}, {'orientation': 9}):
            with self.subTest(config=config), tempfile.TemporaryDirectory() as root:
                native, _, _ = self.fixture(root, **config)
                output = Path(root) / 'output.tif'
                with self.assertRaises(ValueError):
                    module.publish_output(native, output, {'role': 'test'})
                self.assertFalse(output.exists())
                self.assertFalse(Path(str(output) + '.json').exists())

    def test_existing_image_or_evidence_is_not_overwritten(self):
        module = self.module()
        for suffix in ('', '.json'):
            with self.subTest(suffix=suffix), tempfile.TemporaryDirectory() as root:
                native, _, _ = self.fixture(root)
                output = Path(root) / 'output.tif'
                protected = Path(str(output) + suffix); protected.write_bytes(b'preserve')
                with self.assertRaises(FileExistsError):
                    module.publish_output(native, output, {'role': 'test'})
                self.assertEqual(protected.read_bytes(), b'preserve')
                self.assertEqual(sorted(p.name for p in Path(root).iterdir()),
                                 sorted(['native.tif', protected.name]))

    def test_invalid_evidence_leaves_no_half_published_pair(self):
        module = self.module()
        with tempfile.TemporaryDirectory() as root:
            native, _, _ = self.fixture(root)
            output = Path(root) / 'output.tif'
            with self.assertRaises(TypeError):
                module.publish_output(native, output, {'invalid': object()})
            self.assertEqual([p.name for p in Path(root).iterdir()], ['native.tif'])

    def test_source_mutation_is_reported_even_when_decoder_fails(self):
        module = self.module()
        if not hasattr(module, 'run_decoder'):
            self.fail('A decoder boundary checking RAW integrity on failure is missing')
        for exit_code in (0, 1):
            with self.subTest(exit_code=exit_code), tempfile.TemporaryDirectory() as root:
                raw = Path(root) / 'input.X3F'; raw.write_bytes(b'original')
                decoder = Path(root) / 'decoder'
                decoder.write_text(f'#!{sys.executable}\nfrom pathlib import Path\nimport sys\n'
                                   f'Path(sys.argv[2]).write_bytes(b"changed")\nsys.exit({exit_code})\n')
                decoder.chmod(0o755)
                with self.assertRaisesRegex(ValueError, 'RAW changed'):
                    module.run_decoder(decoder, raw, Path(root) / 'native', 'native')


if __name__ == '__main__':
    unittest.main()
