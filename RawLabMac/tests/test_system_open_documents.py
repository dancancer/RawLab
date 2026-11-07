import plistlib
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
RAW_EXTENSIONS = {
    "arw", "arq", "dng", "nef", "nrw", "cr2", "cr3", "crw", "raf",
    "rw2", "rwl", "orf", "pef", "srw", "raw", "3fr", "fff", "iiq", "mos", "x3f",
}
RASTER_EXTENSIONS = {"jpg", "jpeg", "png", "tif", "tiff", "heif", "heic"}


class SystemOpenDocumentTests(unittest.TestCase):
    def read_plist(self, path):
        with (ROOT / path).open("rb") as source:
            return plistlib.load(source)

    def check_photo_documents(self, plist):
        documents = plist.get("CFBundleDocumentTypes", [])
        self.assertTrue(documents, "The OS needs photo document declarations to offer RawLab")
        extensions = set()
        types = set()
        for document in documents:
            self.assertEqual(document["LSHandlerRank"], "Alternate")
            self.assertIn(document["CFBundleTypeRole"], ["Viewer", "Editor"])
            extensions.update(document.get("CFBundleTypeExtensions", []))
            types.update(document.get("LSItemContentTypes", []))
        self.assertEqual(extensions, RAW_EXTENSIONS | RASTER_EXTENSIONS)
        self.assertTrue({"public.camera-raw-image", "public.jpeg", "public.png", "public.tiff",
                         "public.heif", "public.heic"}.issubset(types))
        declarations = plist.get("UTImportedTypeDeclarations", [])
        x3f = next((value for value in declarations
                    if "x3f" in value.get("UTTypeTagSpecification", {}).get("public.filename-extension", [])), None)
        self.assertIsNotNone(x3f, "X3F requires an explicit imported RAW type")
        self.assertIn(x3f["UTTypeIdentifier"], types)
        self.assertIn("public.camera-raw-image", x3f["UTTypeConformsTo"])

    def test_mac_offers_supported_photos_without_claiming_default_handler(self):
        self.check_photo_documents(self.read_plist("RawLabMac/Info.plist"))

    def test_ios_requests_a_copy_to_protect_the_original(self):
        plist = self.read_plist("RawLab/RawLab/Resources/Info.plist")
        self.check_photo_documents(plist)
        self.assertIs(plist.get("LSSupportsOpeningDocumentsInPlace"), False)

    def test_android_resolves_view_and_both_share_actions(self):
        namespace = "{http://schemas.android.com/apk/res/android}"
        manifest = ET.parse(ROOT / "RawLabAndroid/app/src/main/AndroidManifest.xml").getroot()
        activity = next(value for value in manifest.findall("application/activity")
                        if value.get(namespace + "name") == ".MainActivity")
        self.assertEqual(activity.get(namespace + "launchMode"), "singleTask")
        for action in ("VIEW", "SEND", "SEND_MULTIPLE"):
            matches = [value for value in activity.findall("intent-filter")
                       if "android.intent.action." + action in
                       [item.get(namespace + "name") for item in value.findall("action")]]
            self.assertTrue(matches, action)
            self.assertTrue(any("android.intent.category.DEFAULT" in
                                [item.get(namespace + "name") for item in value.findall("category")]
                                and {"image/*", "image/x-adobe-dng", "application/octet-stream"}.issubset(
                                    {item.get(namespace + "mimeType") for item in value.findall("data")})
                                for value in matches), action)


if __name__ == "__main__":
    unittest.main()
