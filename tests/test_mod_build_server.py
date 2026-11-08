"""What the mod build service tells a player about a failed build (packaging/android/mod_build_server.py)."""
import importlib.util
import tempfile
import unittest
from pathlib import Path

SERVER = Path(__file__).resolve().parents[1] / "packaging" / "android" / "mod_build_server.py"
spec = importlib.util.spec_from_file_location("mod_build_server", SERVER)
server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server)


def why_failed(log):
    with tempfile.TemporaryDirectory() as folder:
        path = Path(folder) / "build.log"
        path.write_text(log, encoding="utf-8")
        return server.why_failed(path)


class WhyFailed(unittest.TestCase):
    def test_a_refused_injection_names_its_mod(self):
        said = why_failed(
            '{\n  "code": "E_UNSUPPORTED_CONTROL_FLOW",\n  "message": "closures are unsupported",\n'
            '  "file": "crates/horizon-client/src/game.rs",\n  "mod_id": "jade",\n'
            '  "injection_id": "tooltip"\n}\n'
        )
        self.assertEqual(
            said,
            "The mod jade does not fit this game (E_UNSUPPORTED_CONTROL_FLOW): closures are unsupported",
        )

    def test_without_a_file_it_still_names_it(self):
        said = why_failed('{"code": "E_X_Y", "message": "no", "mod_id": "treefall"}')
        self.assertTrue(said.startswith("The mod treefall does not fit"), said)

    def test_a_refusal_with_no_mod_says_so_plainly(self):
        said = why_failed('{"code": "E_X_Y", "message": "no"}')
        self.assertEqual(said, "The mod does not fit this game (E_X_Y): no")

    def test_a_compile_error_keeps_its_first_lines(self):
        said = why_failed("Compiling\nerror[E0308]: mismatched types\n")
        self.assertIn("error[E0308]: mismatched types", said)

    def test_nothing_readable_is_a_plain_failure(self):
        self.assertEqual(why_failed("killed\n"), "The build failed.")


if __name__ == "__main__":
    unittest.main()
