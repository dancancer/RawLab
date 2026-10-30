import importlib
import unittest
import numpy as np


class BoundedLUTTests(unittest.TestCase):
    def module(self):
        try:
            return importlib.import_module("bounded_lut")
        except ImportError:
            self.fail("Bounded calibration LUT is not implemented")

    def test_interpolation_preserves_known_linear_mapping_and_clamps_domain(self):
        axis = np.array([0., 0.5, 1.])
        nodes = np.stack(np.meshgrid(axis, axis, axis, indexing="ij"), axis=-1).reshape(-1, 3)
        points = np.array([[0.25, 0.75, 0.5], [-1, 2, 0.4]])
        actual = self.module().interpolate(points, axis, nodes)
        np.testing.assert_allclose(actual, [[0.25, 0.75, 0.5], [0, 1, 0.4]], atol=1e-12)

    def test_bounded_nodes_cannot_create_polynomial_overshoot(self):
        rng = np.random.default_rng(822)
        axis = np.array([0., 0.25, 1.])
        nodes = rng.uniform(0, 1, (27, 3))
        result = self.module().interpolate(rng.uniform(-2, 3, (200, 3)), axis, nodes)
        self.assertTrue(np.all((result >= 0) & (result <= 1)))

    def test_fit_learns_color_response_and_keeps_nodes_in_display_range(self):
        rng = np.random.default_rng(714)
        source = rng.uniform(0, 1, (1000, 3))
        target = 0.1 + source @ np.array([[.6, .1, 0], [0, .6, .1], [.1, 0, .6]])
        axis = np.array([0., 0.5, 1.])
        nodes = self.module().fit(source, target, axis, np.ones(1000) / 1000,
                                  smoothness=1e-8, prior=np.full((27, 3), 0.5))
        unseen = np.array([[.1, .2, .3], [.8, .4, .6]])
        expected = np.array([[.19, .23, .30], [.64, .42, .50]])
        np.testing.assert_allclose(self.module().interpolate(unseen, axis, nodes), expected, atol=2e-4)
        self.assertTrue(np.all((nodes >= 0) & (nodes <= 1)))


if __name__ == "__main__":
    unittest.main()
