import copy
import importlib
import json
from pathlib import Path
import tempfile
import unittest


class HighlightContractTests(unittest.TestCase):
    def module(self):
        try:
            return importlib.import_module('highlight_contract')
        except ImportError:
            self.fail('Highlight experiment freeze contract is not implemented')

    def profile(self):
        return {'schema': 'rawlab-sensor-highlight-profile-v1',
                'status': 'diagnostic-candidate-not-SPP-equivalent',
                'camera_model': 'SIGMA DP1S', 'camera_serial': 'test-device',
                'ceiling': [1000, 2000, 4000], 'start': .8, 'end': 1.0}

    def test_changed_profile_source_model_or_decoder_is_rejected(self):
        mod = self.module()
        with tempfile.TemporaryDirectory() as temp:
            paths = [Path(temp) / name for name in ('model.json', 'decoder', 'sensor-decoder')]
            for index, p in enumerate(paths): p.write_bytes(str(index).encode())
            contract = mod.freeze(self.profile(), *paths)
            mod.validate(contract, *paths)
            changed = copy.deepcopy(contract); changed['profile']['ceiling'][0] = 999
            with self.assertRaises(ValueError): mod.validate(changed, *paths)
            changed = copy.deepcopy(contract); changed['source_sha256']['sensor_highlights.py'] = 'wrong'
            with self.assertRaises(ValueError): mod.validate(changed, *paths)
            for p in paths:
                original = p.read_bytes(); p.write_bytes(original + b'changed')
                with self.subTest(path=p), self.assertRaises(ValueError): mod.validate(contract, *paths)
                p.write_bytes(original)

    def test_wrong_profile_schema_or_camera_scope_is_rejected(self):
        mod = self.module()
        for key, value in [('schema', 'unknown'), ('status', 'production'),
                           ('camera_serial', ''), ('camera_model', '')]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                mod.validate_profile({**self.profile(), key: value})

    def test_unknown_or_invalid_optional_detail_response_is_rejected(self):
        for detail in ({'schema': 'unknown'},
                       {'schema': 'rawlab-luma-detail-v1', 'amount': 2, 'threshold': .002}):
            with self.subTest(detail=detail), self.assertRaises(ValueError):
                self.module().validate_profile({**self.profile(), 'detail_response': detail})


if __name__ == '__main__': unittest.main()
