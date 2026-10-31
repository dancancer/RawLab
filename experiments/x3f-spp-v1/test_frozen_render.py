import importlib
import unittest
import numpy as np
from saved_settings import SavedSettings


class FrozenRenderTests(unittest.TestCase):
    def renderer(self):
        try:
            return importlib.import_module("frozen_render")
        except ImportError:
            self.fail("Frozen rendering is not implemented")

    def test_saved_exposure_and_rgb_gain_apply_before_display_mapping(self):
        settings = SavedSettings(1, 1, 0, "Sunlight", exposure=1,
                                 color_adjustment=(0.5, 1, 1))
        rgb, context = self.renderer().prepare_input(np.array([[[0.25, 0.25, 0.25]]]),
                                                     settings, "scene", np.eye(3))
        np.testing.assert_allclose(rgb, [[0.53709873, 0.73535698, 0.73535698]], atol=1e-7)
        np.testing.assert_array_equal(context, [[0, 0]])

    def test_chunking_retains_every_row_and_matches_single_pass(self):
        module = self.renderer()
        # 一阶恒等模型的权重由已知映射给定，不经拟合产生。
        model = {"stage": "none", "degree": 1, "context": False,
                 "weights": [[0, 0, 0], [1, 0, 0], [0, 1, 0], [0, 0, 1]]}
        scene = np.full((5, 2, 3), 0.5)
        scene[4] = 1
        settings = SavedSettings(2, 5, 0, "Sunlight")
        a = module.render(scene, settings, np.eye(3), model, chunk_rows=2)
        b = module.render(scene, settings, np.eye(3), model, chunk_rows=100)
        np.testing.assert_array_equal(a, b)
        np.testing.assert_allclose(a[:4], 0.73535698, atol=1e-7)
        np.testing.assert_allclose(a[4], 1, atol=1e-7)

    def test_unmodeled_saved_controls_are_rejected_instead_of_ignored(self):
        for control in ("contrast", "shadow", "saturation", "sharpness"):
            settings = SavedSettings(1, 1, 0, "Sunlight", **{control: 0.1})
            with self.subTest(control=control), self.assertRaisesRegex(ValueError, control):
                self.renderer().prepare_input(np.ones((1, 1, 3)), settings, "scene", np.eye(3))

    def test_negative_camera_values_are_preserved_for_the_model(self):
        settings = SavedSettings(1, 1, 0, "Sunlight")
        rgb, _ = self.renderer().prepare_input(np.array([[[-0.5, 0.5, 1.]]]),
                                               settings, "none", np.eye(3))
        np.testing.assert_allclose(rgb, [[-0.73535698, 0.73535698, 1.]], atol=1e-7)

    def test_unknown_nonzero_saved_adjustment_is_not_silently_ignored(self):
        settings = SavedSettings(1, 1, 0, "Sunlight", unknown_adjustments=((13, 0.5),))
        with self.assertRaisesRegex(ValueError, "Unknown"):
            self.renderer().prepare_input(np.ones((1, 1, 3)), settings, "none", np.eye(3))


if __name__ == "__main__":
    unittest.main()
