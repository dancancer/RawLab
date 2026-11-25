"""Concurrent configures sharing RAWLAB_SOURCE_ARCHIVE_CACHE must not corrupt each other's downloads."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import hashlib
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
PAYLOAD = bytes(range(256)) * 2048  # 512 KiB


class SlowArchive(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Length", str(len(PAYLOAD)))
        self.end_headers()
        # Slow enough that every concurrent caller is still downloading when the next one starts.
        for start in range(0, len(PAYLOAD), 32768):
            self.wfile.write(PAYLOAD[start:start + 32768])
            self.wfile.flush()
            time.sleep(0.05)

    def log_message(self, *args):
        pass


@unittest.skipUnless(shutil.which("cmake"), "cmake is required")
class DownloadArchiveConcurrencyTests(unittest.TestCase):
    def test_parallel_downloads_of_one_cached_archive_all_succeed(self):
        server = ThreadingHTTPServer(("127.0.0.1", 0), SlowArchive)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.shutdown)
        url = f"http://127.0.0.1:{server.server_address[1]}/dependency.tar.gz"
        digest = hashlib.sha256(PAYLOAD).hexdigest()
        with tempfile.TemporaryDirectory(prefix="rawlab-archive-race-") as directory:
            cache = Path(directory) / "rawlab-deps"
            script = Path(directory) / "fetch.cmake"
            script.write_text(
                f'set(RAWLAB_SOURCE_ARCHIVE_CACHE "{cache.as_posix()}")\n'
                f'include("{(ROOT / "lutools/cmake/download-archive.cmake").as_posix()}")\n'
                'rawlab_archive_path(dependency dependency.tar.gz archive)\n'
                f'rawlab_download_archive("{url}" {digest} "${{archive}}")\n')
            processes = [subprocess.Popen(["cmake", "-P", str(script)], stdout=subprocess.PIPE,
                                          stderr=subprocess.STDOUT, text=True) for _ in range(3)]
            outputs = [process.communicate(timeout=300)[0] for process in processes]
            for process, output in zip(processes, outputs):
                self.assertEqual(process.returncode, 0, output)
            archive = cache / "dependency.tar.gz"
            self.assertEqual(hashlib.sha256(archive.read_bytes()).hexdigest(), digest)
            self.assertFalse((cache / "dependency.tar.gz.part").exists())


if __name__ == "__main__":
    unittest.main()
