import hashlib
import importlib
import json
from pathlib import Path
import tempfile
import unittest
import numpy as np
from saved_settings import SavedSettings


class SceneCacheTests(unittest.TestCase):
    def module(self):
        try:
            return importlib.import_module("scene_cache")
        except ImportError:
            self.fail("Scene provenance checks are not implemented")

    def fixture(self, directory):
        source = Path(directory) / "source.X3F"; source.write_bytes(b"source bytes")
        prefix = Path(directory) / "scene"
        values = np.array([.1, .2, .3, .4, .5, .6], dtype="<f4")
        pixels = values.tobytes(); prefix.with_suffix(".f32").write_bytes(pixels)
        meta = {"source_path": str(source.resolve()), "source_sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
                "float_sha256": hashlib.sha256(pixels).hexdigest(), "decoder_revision": "00f9ef206a2d629bca35ceead4b3951833b85d3d",
                "source_width": 2, "source_height": 1, "width": 2, "height": 1, "block": 1,
                "saved_header_white_balance": "Sunlight", "denoise_intensity": 10, "denoise_backend": "cpu", "highlight_recovery": False}
        prefix.with_suffix(".json").write_text(json.dumps(meta))
        return source, prefix, meta, SavedSettings(2, 1, 0, "Sunlight")

    def test_cache_returns_the_bound_pixels(self):
        with tempfile.TemporaryDirectory() as directory:
            source, prefix, _, settings = self.fixture(directory)
            image, _ = self.module().load_scene(source, prefix, settings, expected_block=1)
            np.testing.assert_allclose(image, [[[.1, .2, .3], [.4, .5, .6]]], atol=1e-7)

    def test_same_white_balance_does_not_allow_another_source_or_changed_pixels(self):
        for mutation in ("source", "pixels", "revision", "dimensions", "block"):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as directory:
                source, prefix, meta, settings = self.fixture(directory)
                if mutation == "source": source.write_bytes(b"different source")
                if mutation == "pixels": prefix.with_suffix(".f32").write_bytes(bytes(24))
                if mutation == "revision": meta["decoder_revision"] = "other"
                if mutation == "dimensions": meta["source_width"] = 3
                if mutation == "block": meta["block"] = 8
                prefix.with_suffix(".json").write_text(json.dumps(meta))
                with self.assertRaises(ValueError):
                    self.module().load_scene(source, prefix, settings, expected_block=1)


if __name__ == "__main__":
    unittest.main()
