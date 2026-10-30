import importlib
import unittest
import numpy as np


class SensorHighlightTests(unittest.TestCase):
    def module(self):
        try:
            return importlib.import_module('sensor_highlights')
        except ImportError:
            self.fail('Sensor highlight experiment is not implemented')

    def profile(self):
        return {'camera_model': 'SIGMA DP1S', 'camera_serial': 'test-device',
                'ceiling': [1000, 2000, 4000], 'start': .8, 'end': 1.0}

    def test_dim_and_partial_channel_highlights_keep_all_original_values(self):
        scene = np.array([[[-.1, .4, 2.0], [1.2, .2, .5]]], dtype=np.float32)
        sensor = np.array([[[200, 400, 800], [1000, 1000, 4000]]], dtype=np.uint16)
        actual, mask = self.module().neutralize_highlights(scene, sensor, self.profile())
        np.testing.assert_array_equal(actual, scene)
        np.testing.assert_array_equal(mask, [[0, 0]])

    def test_all_channels_at_ceiling_recover_neutral_without_clipping_headroom(self):
        scene = np.array([[[1.4, .2, .7]]], dtype=np.float32)
        sensor = np.array([[[1000, 2000, 4000]]], dtype=np.uint16)
        actual, mask = self.module().neutralize_highlights(scene, sensor, self.profile())
        np.testing.assert_allclose(actual, [[[1.4, 1.4, 1.4]]])
        np.testing.assert_array_equal(mask, [[1]])
        np.testing.assert_array_equal(scene, np.array([[[1.4, .2, .7]]], dtype=np.float32))

    def test_midpoint_blends_halfway_using_the_least_exposed_layer(self):
        scene = np.array([[[1., .2, .6]]])
        sensor = np.array([[[1000, 1800, 4000]]], dtype=np.uint16)
        actual, mask = self.module().neutralize_highlights(scene, sensor, self.profile())
        np.testing.assert_allclose(actual, [[[1., .6, .8]]], atol=1e-7)
        np.testing.assert_allclose(mask, [[.5]], atol=1e-7)

    def test_invalid_input_or_profile_is_rejected(self):
        scene = np.ones((2, 2, 3), dtype=np.float32)
        sensor = np.ones((2, 2, 3), dtype=np.uint16)
        for bad_scene, bad_sensor, profile in [
            (scene, sensor[:1], self.profile()),
            (scene * np.nan, sensor, self.profile()),
            (scene, sensor.astype(float) * np.nan, self.profile()),
            (scene, -sensor.astype(float), self.profile()),
            (scene, sensor, {**self.profile(), 'ceiling': [0, 1, 1]}),
            (scene, sensor, {**self.profile(), 'ceiling': [1, 2]}),
            (scene, sensor, {**self.profile(), 'start': 1.1}),
            (scene, sensor, {**self.profile(), 'end': float('nan')}),
        ]:
            with self.subTest(profile=profile), self.assertRaises(ValueError):
                self.module().neutralize_highlights(bad_scene, bad_sensor, profile)

    def test_camera_identity_comes_only_from_property_section(self):
        text = ('BEGIN: CAMF meta data\n"CAMSERIAL" = "wrong"\nEND: CAMF meta data\n'
                'BEGIN: PROP meta data\n[0] "CAMMODEL" = "SIGMA DP1S"\n'
                '[1] "CAMSERIAL" = "test-device"\nEND: PROP meta data\n')
        self.module().validate_camera(text, self.profile())
        for invalid in [text.replace('test-device', 'another-device'),
                        text.replace('SIGMA DP1S', 'SIGMA DP2'),
                        text.replace('END: PROP', '[2] "CAMSERIAL" = "test-device"\nEND: PROP'),
                        text.replace('BEGIN: PROP', 'BEGIN: OTHER')]:
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                self.module().validate_camera(invalid, self.profile())


if __name__ == '__main__':
    unittest.main()
