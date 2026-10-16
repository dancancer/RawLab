"""The Agent test clients must decode protocol JSON independently of locale."""
import importlib.util
from pathlib import Path
import subprocess
import sys
from types import SimpleNamespace
import unittest
from unittest import mock


class ProtocolEncodingTests(unittest.TestCase):
    def test_clients_decode_utf8_even_with_a_windows_legacy_locale(self):
        payload = "\u8c03\u8272-\U0001f305"
        script = f"import sys; sys.stdout.buffer.write(bytes.fromhex('{payload.encode().hex()}'))"
        for filename, name in (("test_agent_commands.py", "AgentCommands"),
                               ("test_agent_preview.py", "AgentPreview"),
                               ("test_raw_info_cli.py", "RawInfoCLI")):
            with self.subTest(client=filename):
                spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
                module = importlib.util.module_from_spec(spec)
                spec.loader.exec_module(module)
                module.CLI = Path(sys.executable)
                client = SimpleNamespace(cwd=Path.cwd())
                with mock.patch("locale.getencoding", return_value="cp1252"), \
                        mock.patch("subprocess.run", wraps=subprocess.run) as run:
                    result = getattr(module, name).run_cli(client, "-c", script)
                self.assertEqual(run.call_args.kwargs.get("encoding"), "utf-8")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, payload)


if __name__ == "__main__":
    unittest.main()
