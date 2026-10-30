import importlib
from pathlib import Path
import tempfile
import unittest
import numpy as np


class HighlightOutputTests(unittest.TestCase):
    def writer(self):
        try:
            return importlib.import_module('render_highlights').write_output
        except (ImportError, AttributeError):
            self.fail('Paired highlight output writer is not implemented')

    def test_existing_evidence_is_preserved_without_leaving_an_image(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / 'image.tif'; evidence = Path(str(path) + '.json')
            evidence.write_text('keep this evidence')
            with self.assertRaises(FileExistsError):
                self.writer()(path, np.ones((2, 2, 3)), b'', {'role': 'test'})
            self.assertFalse(path.exists())
            self.assertEqual(evidence.read_text(), 'keep this evidence')
            self.assertEqual([p.name for p in Path(root).iterdir()], ['image.tif.json'])

    def test_evidence_serialization_failure_leaves_no_output(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / 'image.tif'
            with self.assertRaises(TypeError):
                self.writer()(path, np.ones((2, 2, 3)), b'', {'invalid': object()})
            self.assertEqual(list(Path(root).iterdir()), [])

    def test_existing_image_is_preserved(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / 'image.tif'; path.write_bytes(b'keep this image')
            with self.assertRaises(FileExistsError):
                self.writer()(path, np.ones((2, 2, 3)), b'', {'role': 'test'})
            self.assertEqual(path.read_bytes(), b'keep this image')
            self.assertEqual([p.name for p in Path(root).iterdir()], ['image.tif'])

    def test_tiff_uses_spp_physical_resolution_without_resampling_pixels(self):
        import tifffile
        pixels = np.arange(4 * 6 * 3, dtype=np.uint16).reshape(4, 6, 3) * 900
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / 'image.tif'
            self.writer()(path, pixels.astype(np.float64) / 65535, b'', {'role': 'test'})
            with tifffile.TiffFile(path) as image:
                page = image.pages[0]
                self.assertEqual(page.tags['XResolution'].value, (180, 1))
                self.assertEqual(page.tags['YResolution'].value, (180, 1))
                self.assertEqual(page.tags['ResolutionUnit'].value, 2)
                np.testing.assert_array_equal(page.asarray(), pixels)


if __name__ == '__main__': unittest.main()
