"""HDR CLI integration with a synthetic source in an isolated directory."""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest


class HDRAgent(unittest.TestCase):
    def run_cli(self, *arguments):
        process = subprocess.run([str(CLI), *map(str, arguments)], capture_output=True, text=True, timeout=120)
        return process, json.loads(process.stdout)

    def test_hdr_recipe_export_preview_info_and_atomic_failure(self):
        with tempfile.TemporaryDirectory(prefix="rawlab-hdr-agent-") as temporary:
            root=Path(temporary)
            source=root / "phone.jpg"
            generated=subprocess.run([str(FIXTURE), "--fixture", str(source)], capture_output=True, text=True)
            if generated.returncode==77:
                self.skipTest("native HDR fixture requires macOS15/iOS18")
            self.assertEqual(generated.returncode,0,generated.stderr)
            original=hashlib.sha256(source.read_bytes()).hexdigest()
            process,capabilities=self.run_cli("--capabilities","--json")
            self.assertEqual(process.returncode,0)
            caps=capabilities["result"]
            self.assertIn(6,caps["recipe_versions"])
            self.assertIn("hdr_raster",caps["input_types"])
            self.assertIn("hdr_jpeg",caps["output_formats"])
            self.assertFalse(caps["hdr"]["display"])
            self.assertEqual(caps["hdr"]["preview_rendition"],"sdr")
            document={"schema_version":6,
                "processing":{"family":"rawlab_hdr","version":1,"quality":"standard"},
                "input":{"path":source.name,"type":"hdr_raster"},
                "edits":{"exposure":{"ev":1},"white_balance":{"mode":"relative"},
                    "tone":{"highlights":-.1},"geometry":{"quarter_turns":1}},
                "output":{"path":"edited.jpg","format":"hdr_jpeg","base_color":"display_p3"}}
            recipe=root / "edit.json"
            recipe.write_text(json.dumps(document),encoding="utf-8")
            process,normalized=self.run_cli("--recipe",recipe,"--print-recipe","--json")
            self.assertEqual(process.returncode,0,normalized)
            self.assertEqual(normalized["result"]["processing"],document["processing"])
            process,info=self.run_cli("--info",source,"--json")
            self.assertEqual(process.returncode,0,info)
            self.assertEqual(info["result"]["input_type"],"hdr_raster")
            self.assertEqual(info["result"]["source_sha256"],original)
            self.assertGreater(info["result"]["content_headroom"],1)
            process,export=self.run_cli("--recipe",recipe,"--json")
            self.assertEqual(process.returncode,0,export)
            self.assertEqual(export["result"]["format"],"hdr_jpeg")
            output=root / "edited.jpg"
            data=output.read_bytes()
            self.assertIn(b"urn:iso:std:iso:ts:21496:-1",data)
            self.assertIn(b"http://ns.adobe.com/hdr-gain-map/1.0/",data)
            process,reopened=self.run_cli("--info",output,"--json")
            self.assertEqual(process.returncode,0,reopened)
            self.assertGreater(reopened["result"]["content_headroom"],1)
            self.assertEqual(reopened["result"]["identified_size"]["width"],32)
            self.assertEqual(reopened["result"]["identified_size"]["height"],64)
            preview=root / "preview.png"
            process,result=self.run_cli("--recipe",recipe,"--preview",preview,"--long-edge",16,"--json")
            self.assertEqual(process.returncode,0,result)
            self.assertEqual(result["result"]["format"],"png")
            self.assertEqual(result["result"]["rendition"],"sdr")
            png=preview.read_bytes()
            self.assertEqual(png[:8],b"\x89PNG\r\n\x1a\n")
            self.assertEqual(struct.unpack(">II",png[16:24]),(8,16))
            self.assertNotIn(b"hdr-gain-map",png)
            self.assertIn(8, caps["recipe_versions"])
            tone_recipe = root / "tone.json"
            tone_document = copy.deepcopy(document)
            tone_document["schema_version"] = 8
            tone_document["processing"]["version"] = 2
            tone_document["edits"]["tone"].update(black_point=-.25, white_point=.5,
                curve={"mode": "custom", "points": [[0, 0], [.5, .625], [1, 1]]})
            tone_document["output"]["path"] = "tone.jpg"
            tone_recipe.write_text(json.dumps(tone_document), encoding="utf-8")
            tone_preview = root / "tone.png"
            process, result = self.run_cli("--recipe", tone_recipe, "--preview", tone_preview, "--long-edge", 16, "--json")
            self.assertEqual(process.returncode, 0, result)
            self.assertEqual(result["result"]["rendition"], "sdr")
            self.assertNotEqual(tone_preview.read_bytes(), png)
            process, result = self.run_cli("--recipe", tone_recipe, "--json")
            self.assertEqual(process.returncode, 0, result)
            process, result = self.run_cli("--info", root / "tone.jpg", "--json")
            self.assertEqual(process.returncode, 0, result)
            self.assertEqual(result["result"]["identified_size"], reopened["result"]["identified_size"])
            self.assertGreater(result["result"]["content_headroom"], reopened["result"]["content_headroom"])
            self.assertIn(9, caps["recipe_versions"])
            color_recipe = root / "color.json"
            color_document = copy.deepcopy(tone_document)
            # The +1 EV comparison clips the fixture's white patch in SDR.
            color_document["edits"]["exposure"]["ev"] = 0
            color_recipe.write_text(json.dumps(color_document), encoding="utf-8")
            reference_preview = root / "color-reference.png"
            process, result = self.run_cli("--recipe", color_recipe, "--preview", reference_preview, "--long-edge", 16, "--json")
            self.assertEqual(process.returncode, 0, result)
            color_document["schema_version"] = 9
            color_document["processing"]["version"] = 3
            color_document["edits"]["color"] = {"vibrance": .4}
            color_document["edits"]["hsl"] = {"hue": [40] * 8}
            color_document["edits"]["color_grading"] = {
                zone: {"hue": 210, "saturation": 80} for zone in ("shadows", "midtones", "highlights")
            }
            color_document["output"]["path"] = "color.jpg"
            color_recipe.write_text(json.dumps(color_document), encoding="utf-8")
            color_preview = root / "color.png"
            process, result = self.run_cli("--recipe", color_recipe, "--preview", color_preview, "--long-edge", 16, "--json")
            self.assertEqual(process.returncode, 0, result)
            self.assertNotEqual(color_preview.read_bytes(), reference_preview.read_bytes())
            process, result = self.run_cli("--recipe", color_recipe, "--json")
            self.assertEqual(process.returncode, 0, result)
            process, result = self.run_cli("--info", root / "color.jpg", "--json")
            self.assertEqual(process.returncode, 0, result)
            self.assertEqual(result["result"]["identified_size"], reopened["result"]["identified_size"])
            self.assertIn(11, caps["recipe_versions"])
            effects_document = copy.deepcopy(color_document)
            effects_document["schema_version"] = 11
            effects_document["processing"]["version"] = 5
            effects_document["edits"]["effects"] = {"vignette_amount": -75, "grain_amount": 70}
            effects_document["output"]["path"] = "effects.jpg"
            effects_recipe = root / "effects.json"
            effects_recipe.write_text(json.dumps(effects_document), encoding="utf-8")
            effects_preview = root / "effects.png"
            process, result = self.run_cli("--recipe", effects_recipe, "--preview", effects_preview, "--long-edge", 16, "--json")
            self.assertEqual(process.returncode, 0, result)
            self.assertNotEqual(effects_preview.read_bytes(), color_preview.read_bytes())
            process, result = self.run_cli("--recipe", effects_recipe, "--json")
            self.assertEqual(process.returncode, 0, result)
            process, result = self.run_cli("--info", root / "effects.jpg", "--json")
            self.assertEqual(process.returncode, 0, result)
            self.assertEqual(result["result"]["identified_size"], reopened["result"]["identified_size"])
            self.assertIn(12, caps["recipe_versions"])
            self.assertEqual(caps["hdr"]["detail_recipe_version"], 12)
            detail_document = copy.deepcopy(effects_document)
            detail_document["schema_version"] = 12
            detail_document["processing"]["version"] = 6
            detail_document["edits"]["detail"] = {"sharpening": 1.2, "clarity": .7, "dehaze": -.5, "denoise": .6}
            detail_document["output"]["path"] = "detail.jpg"
            detail_recipe = root / "detail.json"
            detail_recipe.write_text(json.dumps(detail_document), encoding="utf-8")
            detail_preview = root / "detail.png"
            process, result = self.run_cli("--recipe", detail_recipe, "--preview", detail_preview, "--long-edge", 16, "--json")
            self.assertEqual(process.returncode, 0, result)
            self.assertNotEqual(detail_preview.read_bytes(), effects_preview.read_bytes())
            process, result = self.run_cli("--recipe", detail_recipe, "--json")
            self.assertEqual(process.returncode, 0, result)
            process, result = self.run_cli("--info", root / "detail.jpg", "--json")
            self.assertEqual(process.returncode, 0, result)
            self.assertEqual(result["result"]["identified_size"], reopened["result"]["identified_size"])
            self.assertIn(13, caps["recipe_versions"])
            self.assertEqual(caps["hdr"]["look_recipe_version"], 13)
            look_asset = root / "look.cube"
            look_bytes = (Path(__file__).parent / "fixtures" / "hdr-look-linear.cube").read_bytes()
            look_asset.write_bytes(look_bytes)
            look_document = copy.deepcopy(detail_document)
            look_document["schema_version"] = 13
            look_document["processing"]["version"] = 7
            look_document["edits"]["look"] = {"path": "look.cube", "sha256": hashlib.sha256(look_bytes).hexdigest(), "strength": .8}
            look_document["output"]["path"] = "look.jpg"
            look_recipe = root / "look.json"
            look_recipe.write_text(json.dumps(look_document), encoding="utf-8")
            look_preview = root / "look.png"
            process, result = self.run_cli("--recipe", look_recipe, "--preview", look_preview, "--long-edge", 16, "--json")
            self.assertEqual(process.returncode, 0, result)
            self.assertNotEqual(look_preview.read_bytes(), detail_preview.read_bytes())
            process, result = self.run_cli("--recipe", look_recipe, "--json")
            self.assertEqual(process.returncode, 0, result)
            look_output = root / "look.jpg"
            process, result = self.run_cli("--info", look_output, "--json")
            self.assertEqual(process.returncode, 0, result)
            self.assertEqual(result["result"]["identified_size"], reopened["result"]["identified_size"])
            saved_look_output = look_output.read_bytes()
            look_asset.write_bytes(look_bytes.replace(b"0.125", b"0.250"))
            process, result = self.run_cli("--recipe", look_recipe, "--json")
            self.assertNotEqual(process.returncode, 0, result)
            self.assertEqual(look_output.read_bytes(), saved_look_output)
            protected=output.read_bytes()
            document["edits"]["look"]={"path":None}
            recipe.write_text(json.dumps(document),encoding="utf-8")
            process,invalid=self.run_cli("--recipe",recipe,"--json")
            self.assertNotEqual(process.returncode,0)
            self.assertIn("edits.look",invalid["error"]["message"])
            self.assertEqual(output.read_bytes(),protected)
            self.assertEqual(hashlib.sha256(source.read_bytes()).hexdigest(),original)


if __name__=="__main__":
    parser=argparse.ArgumentParser()
    parser.add_argument("--cli",type=Path,required=True)
    parser.add_argument("--fixture",type=Path,required=True)
    args,remaining=parser.parse_known_args()
    CLI,FIXTURE=args.cli.resolve(),args.fixture.resolve()
    unittest.main(argv=[__file__,*remaining])
