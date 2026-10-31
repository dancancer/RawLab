import importlib
import hashlib
from pathlib import Path
import tempfile
import unittest


class FamilyContractTests(unittest.TestCase):
    def test_changed_binary_revision_or_python_sources_are_rejected(self):
        try:
            module = importlib.import_module('family_contract')
        except ImportError:
            self.fail('The native build provenance contract is not implemented')
        def digest(path):
            return hashlib.sha256(path.read_bytes()).hexdigest()
        source = Path(__file__).parent
        with tempfile.TemporaryDirectory() as root:
            decoder = Path(root) / 'decoder'; decoder.write_bytes(b'bound executable')
            record = {'schema': 'rawlab-family-decoder-contract-v1',
                      'source_revision': '00f9ef206a2d629bca35ceead4b3951833b85d3d',
                      'decoder_sha256': digest(decoder),
                      'native_probe_sha256': digest(source / 'decode_family.rs'),
                      'python_sources': {name: digest(source / name) for name in
                                         ('render_family.py', 'family_contract.py', 'scene_cache.py')}}
            module.validate(record, decoder)
            for key, value in [('source_revision', 'other revision'),
                               ('native_probe_sha256', 'other source'),
                               ('python_sources', {})]:
                with self.subTest(key=key), self.assertRaises(ValueError):
                    module.validate({**record, key: value}, decoder)
            decoder.write_bytes(b'other executable')
            with self.assertRaises(ValueError):
                module.validate(record, decoder)


if __name__ == '__main__':
    unittest.main()
