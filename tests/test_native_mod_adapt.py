"""What native_mod_adapt.py changes in a mod's code (packaging/android/native_mod_adapt.py)."""
import importlib.util
import unittest
from pathlib import Path

ADAPT = Path(__file__).resolve().parents[1] / "packaging" / "android" / "native_mod_adapt.py"
spec = importlib.util.spec_from_file_location("native_mod_adapt", ADAPT)
adapt = importlib.util.module_from_spec(spec)
spec.loader.exec_module(adapt)

OLD_STATE = """Break(ItemRenderState {
    oversized_in_gui: resolved.oversized_in_gui,
    animated,
})"""
UPDATED_STATE = """Break(ItemRenderState {
    oversized_in_gui: resolved.oversized_in_gui,
    animated,
    cit_glint: None,
    hdr_tier: 0,
    hdr_light: 0,
})"""


class Code(unittest.TestCase):
    def test_a_mod_from_before_the_new_fields_gets_them(self):
        self.assertEqual(adapt.code(OLD_STATE).count("cit_glint: None"), 1)

    def test_a_mod_that_already_has_them_stays_as_it_is(self):
        # Eating Animation 0.2.0: a second copy is E0062 and no build.
        self.assertEqual(adapt.code(UPDATED_STATE), UPDATED_STATE)


class Calls(unittest.TestCase):
    def test_a_mod_calling_content_root_again_passes_what_it_now_takes(self):
        said = adapt.code("Break(content_root(root, enabled, &with))")
        self.assertEqual(said, "Break(content_root(root, enabled, &with, None, &mut |_| {}))")


if __name__ == "__main__":
    unittest.main()
