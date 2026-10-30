import importlib
import unittest
import numpy as np
from saved_settings import SavedSettings


class RenderV2Tests(unittest.TestCase):
    def renderer(self):
        try:
            return importlib.import_module("render_v2").render_scene
        except ImportError:
            self.fail("Version two rendering is not implemented")

    def models(self):
        axis = [0., 1.]
        nodes = np.stack(np.meshgrid(axis, axis, axis, indexing="ij"), -1).reshape(-1, 3)
        return ({"axis": axis, "nodes": nodes.tolist()},
                {"color_log_gain_matrix": np.eye(3).tolist(), "tone_curves": {}, "tone_order": []},
                {"weights": np.zeros((20, 3)).tolist(), "scale": .03})

    def test_exposure_uses_unclipped_scene_values_before_display_response(self):
        base, controls, fill = self.models()
        scene = np.ones((1, 1, 3))
        result = self.renderer()(scene, SavedSettings(1, 1, 0, "Sunlight", exposure=1), base, controls, fill)
        np.testing.assert_allclose(result, .83600697, atol=1e-7)

    def test_color_log_gain_mapping_is_applied_without_using_a_reference_image(self):
        base, controls, fill = self.models()
        settings = SavedSettings(1, 1, 0, "Sunlight", color_adjustment=(.5, 1, 1))
        result = self.renderer()(np.ones((1, 1, 3)), settings, base, controls, fill)
        np.testing.assert_allclose(result, [[[.61250102, .73535698, .73535698]]], atol=1e-7)

    def test_unimplemented_settings_fail_before_any_pixel_render(self):
        base, controls, fill = self.models()
        for settings in [SavedSettings(1, 1, 0, "Monochrome"),
                         SavedSettings(1, 1, 0, "Sunlight", sharpness=.5),
                         SavedSettings(1, 1, 0, "Sunlight", unknown_adjustments=((13, .5),))]:
            with self.subTest(settings=settings), self.assertRaises(ValueError):
                self.renderer()(np.ones((1, 1, 3)), settings, base, controls, fill)


if __name__ == "__main__":
    unittest.main()
