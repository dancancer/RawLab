import copy
import importlib
import hashlib
from pathlib import Path
import tempfile
import unittest


class EvaluationContractTests(unittest.TestCase):
    def module(self):
        try:
            return importlib.import_module("evaluation_contract")
        except ImportError:
            self.fail("Evaluation contracts are not implemented")

    def test_training_input_rejects_an_unclassified_list_or_holdout_row(self):
        module = self.module()
        with self.assertRaises(ValueError):
            module.validate_training_manifest([{"name": "image"}])
        for row in [{"name": "x", "split": "holdout", "group": "new"},
                    {"name": "x", "split": "development", "group": "reserved"}]:
            with self.assertRaises(ValueError):
                module.validate_training_manifest({"role": "neutral-development-v2", "excluded_dates": ["reserved"], "samples": [row]})

    def test_frozen_check_rejects_candidate_changed_parameters_and_training_overlap(self):
        module = self.module()
        manifest = {"samples": [{"split": "holdout", "scene_group": "reserved"}]}
        model = {"base": {"training_dates": ["old"], "nodes": [1]},
                 "controls": {"training_dates": ["old"]}, "fill": {"training_dates": ["old"]}}
        directory = tempfile.TemporaryDirectory(); self.addCleanup(directory.cleanup)
        source = Path(directory.name) / "manifest.json"; source.write_bytes(b"source manifest")
        for component in model.values():
            component["source_manifests"] = [{"path": str(source), "sha256": hashlib.sha256(source.read_bytes()).hexdigest()}]
        with self.assertRaises(ValueError):
            module.validate_frozen(model, manifest, "manifest-hash", {})
        model["freeze"] = {"status": "frozen", "holdout_manifest_sha256": "manifest-hash",
                           "model_payload_sha256": module.payload_hash(model), "source_sha256": {}}
        module.validate_frozen(model, manifest, "manifest-hash", {})
        changed = copy.deepcopy(model); changed["base"]["nodes"] = [2]
        with self.assertRaises(ValueError):
            module.validate_frozen(changed, manifest, "manifest-hash", {})
        overlap = copy.deepcopy(model); overlap["fill"]["training_dates"] = ["reserved"]
        overlap["freeze"]["model_payload_sha256"] = module.payload_hash(overlap)
        with self.assertRaises(ValueError):
            module.validate_frozen(overlap, manifest, "manifest-hash", {})
        source.write_bytes(b"changed source manifest")
        with self.assertRaises(ValueError):
            module.validate_frozen(model, manifest, "manifest-hash", {})

    def test_paired_summary_uses_the_same_images_for_both_versions(self):
        metric = lambda value: {"delta_e76_mean": value, "false_white_fraction": 0}
        rows = [{"file": "shared", "group": "day", "v1": metric(8), "v2": metric(3)},
                {"file": "v1_only", "group": "day", "v1": metric(100)},
                {"file": "v2_only", "group": "day", "v2": metric(100)}]
        summary = self.module().paired_summary(rows)
        self.assertEqual(summary["files"], ["shared"])
        self.assertEqual(summary["v1"]["image_mean_delta_e76"], 8)
        self.assertEqual(summary["v2"]["image_mean_delta_e76"], 3)


if __name__ == "__main__":
    unittest.main()
