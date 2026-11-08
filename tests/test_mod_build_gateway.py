"""The build gateway's day limits (packaging/android/mod_build_gateway.py)."""
import importlib.util
import os
import unittest
from pathlib import Path
from unittest import mock

GATEWAY = Path(__file__).resolve().parents[1] / "packaging" / "android" / "mod_build_gateway.py"


def load(**env):
    """A fresh copy of the gateway, with nothing counted yet."""
    spec = importlib.util.spec_from_file_location("mod_build_gateway", GATEWAY)
    module = importlib.util.module_from_spec(spec)
    settings = {"BUILD_BACKEND": "http://127.0.0.1:8787", "BUILD_VM": "/vm", **env}
    with mock.patch.dict(os.environ, settings):
        spec.loader.exec_module(module)
    return module


class DayLimits(unittest.TestCase):
    def test_one_address_is_told_its_own_limit(self):
        gateway = load()
        for i in range(gateway.PER_ADDRESS):
            self.assertIsNone(gateway.refusal("a", f"request {i}"))
        self.assertEqual(gateway.refusal("a", "one more"), gateway.YOUR_LIMIT)
        self.assertIsNone(gateway.refusal("b", "another player's"))

    def test_everyones_limit_is_told_as_everyones(self):
        gateway = load(BUILDS_PER_DAY="3")
        for i in range(3):
            self.assertIsNone(gateway.refusal(f"address {i}", f"request {i}"))
        self.assertEqual(gateway.refusal("new player", "theirs"), gateway.EVERYONES_LIMIT)

    def test_the_day_limit_comes_from_the_environment(self):
        self.assertEqual(load().PER_DAY, 80)
        self.assertEqual(load(BUILDS_PER_DAY="200").PER_DAY, 200)

    def test_a_failed_build_gives_its_place_back(self):
        gateway = load(BUILDS_PER_DAY="2")
        self.assertIsNone(gateway.refusal("a", "broken mod"))
        gateway.note_job("a", "broken mod", "job")
        gateway.job_failed("job")
        self.assertIsNone(gateway.refusal("b", "working mod"))
        self.assertIsNone(gateway.refusal("c", "another working mod"))
        self.assertEqual(gateway.refusal("d", "one too many"), gateway.EVERYONES_LIMIT)

    def test_failures_have_their_own_day_limit(self):
        gateway = load(BUILDS_PER_DAY="2")
        for i in range(2):
            self.assertIsNone(gateway.refusal(f"address {i}", f"broken {i}"))
            gateway.note_job(f"address {i}", f"broken {i}", f"job {i}")
            gateway.job_failed(f"job {i}")
        self.assertEqual(gateway.refusal("new player", "theirs"), gateway.EVERYONES_LIMIT)

    def test_a_failure_of_the_mods_own_passes_at_the_limit_and_counts_nothing(self):
        gateway = load(BUILDS_PER_DAY="1")
        self.assertIsNone(gateway.refusal("a", "broken mod"))
        gateway.note_job("a", "broken mod", "job")
        gateway.job_failed("job", settled=True)
        self.assertIsNone(gateway.refusal("b", "broken mod"))
        self.assertIsNone(gateway.refusal("a", "broken mod"))
        self.assertEqual(len(gateway.accepted), 1)

    def test_a_failure_the_machine_may_have_caused_counts_when_asked_again(self):
        gateway = load()
        self.assertIsNone(gateway.refusal("a", "mod"))
        gateway.note_job("a", "mod", "job")
        gateway.job_failed("job")
        self.assertIsNone(gateway.refusal("a", "mod"))
        self.assertEqual(len(gateway.accepted), 2)

    def test_one_job_failing_for_many_counts_once_for_everyone(self):
        gateway = load(BUILDS_PER_DAY="2")
        for i in range(2):
            self.assertIsNone(gateway.refusal(f"address {i}", f"same mods, order {i}"))
            gateway.note_job(f"address {i}", f"same mods, order {i}", "job")
            gateway.job_failed("job", settled=True)
        self.assertIsNone(gateway.refusal("new player", "theirs"))

    def test_a_request_the_service_refused_is_no_failure_for_everyone(self):
        gateway = load(BUILDS_PER_DAY="2")
        for i in range(2):
            self.assertIsNone(gateway.refusal(f"address {i}", f"request {i}"))
            gateway.note_job(f"address {i}", f"request {i}", None)
        self.assertIsNone(gateway.refusal("new player", "theirs"))

    def test_the_same_request_again_costs_nothing(self):
        gateway = load(BUILDS_PER_DAY="1")
        self.assertIsNone(gateway.refusal("a", "mine"))
        self.assertIsNone(gateway.refusal("a", "mine"))
        self.assertEqual(len(gateway.accepted), 1)

    def test_what_is_built_passes_at_the_limit_and_counts_nothing(self):
        gateway = load(BUILDS_PER_DAY="1")
        self.assertIsNone(gateway.refusal("a", "popular mod"))
        gateway.note_job("a", "popular mod", "job")
        gateway.job_done("job")
        self.assertIsNone(gateway.refusal("b", "popular mod"))
        self.assertEqual(len(gateway.accepted), 1)
        self.assertEqual(gateway.refusal("b", "something new"), gateway.EVERYONES_LIMIT)

    def test_only_as_many_builds_as_the_service_keeps_are_remembered(self):
        gateway = load()
        for i in range(gateway.BUILT_REMEMBERED + 1):
            address = f"address {i}"
            self.assertIsNone(gateway.refusal(address, f"request {i}"))
            gateway.note_job(address, f"request {i}", f"job {i}")
            gateway.job_done(f"job {i}")
        self.assertEqual(len(gateway.built), gateway.BUILT_REMEMBERED)
        self.assertNotIn("request 0", gateway.built)
        self.assertIn(f"request {gateway.BUILT_REMEMBERED}", gateway.built)

    def test_the_gateway_remembers_as_many_as_the_service_keeps(self):
        server = (GATEWAY.parent / "mod_build_server.py").read_text(encoding="utf-8")
        self.assertIn(f"KEEP_RESULTS = {load().BUILT_REMEMBERED}\n", server)


if __name__ == "__main__":
    unittest.main()
