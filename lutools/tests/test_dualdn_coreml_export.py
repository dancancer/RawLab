"""Optional macOS conversion tests; no production weights are required."""

import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest

DIRECTORY = Path(__file__).parents[1] / "tools/dualdn"
sys.path.insert(0, str(DIRECTORY))
spec = importlib.util.spec_from_file_location("dualdn_coreml_export", DIRECTORY / "export_coreml.py")
export = importlib.util.module_from_spec(spec)
spec.loader.exec_module(export)


class CoreMLExportTests(unittest.TestCase):
    def test_manifest_covers_nested_model_bytes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "raw.mlmodelc"
            (root / "weights").mkdir(parents=True)
            (root / "weights/weight.bin").write_bytes(b"abc")
            actual = export.model_files(root)
            self.assertEqual(actual, {"directory": "raw.mlmodelc", "files": [{"path": "weights/weight.bin", "bytes": 3,
                "sha256": "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"}]})

    def test_model_manifest_rejects_external_links(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "raw.mlmodelc"
            root.mkdir()
            outside = Path(temporary) / "outside"
            outside.write_bytes(b"external model")
            (root / "weights").symlink_to(outside)
            with self.assertRaisesRegex(ValueError, "symlink"):
                export.model_files(root)

    def test_model_manifest_rejects_empty_model(self):
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaisesRegex(ValueError, "empty"):
                export.model_files(Path(temporary))

    def test_native_conversion_preserves_low_signal_and_superwhite(self):
        import numpy as np
        import torch
        import coremltools as ct

        class Noise(torch.nn.Module):
            def forward(self, packed_raw, k, b):
                raw = packed_raw.clamp(min=1e-8)
                return raw + (k * raw + b).clamp(min=1e-7).sqrt()

        raw = torch.tensor([-0.1, 0.0, 0.25, 1.4]).reshape(1, 4, 1, 1)
        inputs = (raw, torch.tensor([0.02]), torch.tensor([0.003]))
        with tempfile.TemporaryDirectory() as temporary:
            model = export.convert_head(Noise(), inputs, ["packed_raw", "k", "b"], "denoised_packed", Path(temporary) / "raw.mlmodelc")
            expected = Noise()(*inputs).numpy()
            actual = model.predict({name: value.numpy() for name, value in zip(["packed_raw", "k", "b"], inputs)})["denoised_packed"]
            np.testing.assert_allclose(actual, expected, rtol=0, atol=1e-6)
            self.assertGreater(float(actual.max()), 1.4)
            self.assertEqual(actual.dtype, np.float32)


if __name__ == "__main__":
    unittest.main()
