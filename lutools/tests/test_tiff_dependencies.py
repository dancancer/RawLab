"""Exercise the real CMake archive downloader against a local HTTP server."""
from contextlib import contextmanager
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest


ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / "lutools/cmake/download-archive.cmake"
PAYLOAD = b"checksum-verified source archive\n"
DIGEST = hashlib.sha256(PAYLOAD).hexdigest()


@contextmanager
def server(responses):
    requests = []

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            status, body = responses[min(len(requests), len(responses) - 1)]
            requests.append(self.path)
            self.send_response(status)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *_):
            pass

    http = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=http.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{http.server_port}/tiff.tar.gz", requests
    finally:
        http.shutdown()
        http.server_close()
        thread.join()


class TiffDownloadTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.archive = self.root / "cache/tiff.tar.gz"

    def download(self, url):
        script = self.root / "download.cmake"
        script.write_text(
            f'include("{HELPER.as_posix()}")\n'
            f'rawlab_download_archive("{url}" "{DIGEST}" "{self.archive.as_posix()}")\n'
        )
        return subprocess.run(["cmake", "-P", str(script)], capture_output=True, text=True, timeout=20)

    def assert_clean_failure(self, result):
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.archive.exists())
        self.assertFalse(self.archive.with_suffix(".gz.part").exists())

    def test_http_502_is_retried_and_only_verified_archive_is_published(self):
        with server([(502, b"unavailable"), (200, PAYLOAD)]) as (url, requests):
            result = self.download(url)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(requests), 2)
        self.assertEqual(self.archive.read_bytes(), PAYLOAD)
        self.assertFalse(self.archive.with_suffix(".gz.part").exists())

    def test_permanent_http_failure_is_bounded_and_leaves_no_archive(self):
        with server([(502, b"unavailable")]) as (url, requests):
            result = self.download(url)
        self.assert_clean_failure(result)
        self.assertEqual(len(requests), 3)

    def test_checksum_failure_never_publishes_downloaded_bytes(self):
        with server([(200, b"wrong archive")]) as (url, requests):
            result = self.download(url)
        self.assert_clean_failure(result)
        self.assertEqual(len(requests), 3)
        self.assertIn("SHA256", result.stderr)

    def test_verified_cache_is_reused_without_another_network_request(self):
        with server([(200, PAYLOAD), (502, b"unavailable")]) as (url, requests):
            first = self.download(url)
            second = self.download(url)
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(len(requests), 1)
        self.assertEqual(self.archive.read_bytes(), PAYLOAD)

    def test_corrupt_cache_and_partial_download_are_replaced(self):
        self.archive.parent.mkdir()
        self.archive.write_bytes(b"corrupt cache")
        self.archive.with_suffix(".gz.part").write_bytes(b"partial download")
        with server([(200, PAYLOAD)]) as (url, requests):
            result = self.download(url)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(requests), 1)
        self.assertEqual(self.archive.read_bytes(), PAYLOAD)
        self.assertFalse(self.archive.with_suffix(".gz.part").exists())

    def test_tiff_source_override_still_configures_without_downloading(self):
        source = self.root / "tiff"
        source.mkdir()
        (source / "CMakeLists.txt").write_text(
            "add_library(tiff INTERFACE)\nadd_library(TIFF::tiff ALIAS tiff)\n"
        )
        (source / "LICENSE.md").write_text("fixture license\n")
        (self.root / "CMakeLists.txt").write_text(
            "cmake_minimum_required(VERSION 3.15)\nproject(TiffOverride LANGUAGES C)\n"
            f'include("{(ROOT / "lutools/cmake/tiff-dependencies.cmake").as_posix()}")\n'
            'if(NOT TARGET TIFF::tiff)\nmessage(FATAL_ERROR "Missing TIFF target")\nendif()\n'
        )
        build = self.root / "build"
        result = subprocess.run(
            ["cmake", "-S", str(self.root), "-B", str(build),
             f"-DFETCHCONTENT_SOURCE_DIR_RAWLAB_LIBTIFF={source}"],
            capture_output=True, text=True, timeout=20,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((build / "licenses/libtiff/LICENSE.md").read_text(), "fixture license\n")
        self.assertFalse((build / "_deps/rawlab_libtiff-cache").exists())


if __name__ == "__main__":
    unittest.main()
