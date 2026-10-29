"""HDR v6 CLI integration. Generates its own source in an isolated directory."""
import argparse
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
