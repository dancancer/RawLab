"""Model-export regressions; run with the optional DualDn development dependencies."""

import importlib.util
from pathlib import Path
import tempfile
import unittest

import torch

MODULE_PATH = Path(__file__).parents[1] / "tools/dualdn/export.py"
spec = importlib.util.spec_from_file_location("dualdn_export", MODULE_PATH)
export = importlib.util.module_from_spec(spec)
spec.loader.exec_module(export)


class SelectNoise(torch.nn.Module):
    def forward(self, inputs):
        return inputs[1]


class ToyDualDn(torch.nn.Module):
    def __init__(self):
        super().__init__()
        self.nm_fuse1 = SelectNoise()
        self.nm_fuse2 = SelectNoise()
        self.backbone1 = self.backbone2 = torch.nn.Identity()
        self.conv_out1 = self.conv_out2 = torch.nn.Identity()


class DualDnExportTests(unittest.TestCase):
    def test_raw_uses_variance_and_preserves_superwhite(self):
        raw = torch.tensor([-0.1, 0.0, 0.25, 1.4]).reshape(1, 4, 1, 1)
        k, b = torch.tensor([0.02]), torch.tensor([0.003])
        actual = export.RawHead(ToyDualDn())(raw, k, b)
        normalized = raw.clamp(min=1e-8)
        expected = normalized + (k * normalized + b).clamp(min=1e-7).sqrt()
        torch.testing.assert_close(actual, expected, rtol=0, atol=0)
        self.assertGreater(actual.flatten()[-1], 1.4)

    def test_rgb_adds_residual_to_skip_without_extra_gamma(self):
        skip = torch.tensor([-0.02, 0.25, 1.2]).reshape(1, 3, 1, 1)
        noise = torch.full_like(skip, 0.1)
        actual = export.RgbHead(ToyDualDn())(skip, noise)
        torch.testing.assert_close(actual, skip + noise, rtol=0, atol=0)

    def test_pinned_source_rejects_modified_content(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for relative in export.SOURCE_SHA256:
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("not the pinned source")
            with self.assertRaisesRegex(ValueError, "SHA-256"):
                export.verify_source(root)

    def test_export_dimensions_reject_unusable_shapes(self):
        for size in [0, 7, 63, 100, -64]:
            with self.subTest(size=size), self.assertRaises(ValueError):
                export.validate_tile_size(size)
        for size in [64, 640]:
            export.validate_tile_size(size)


if __name__ == "__main__":
    unittest.main()
