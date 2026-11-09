"""The build gateway's day limits (packaging/android/mod_build_gateway.py)."""
import hashlib
import http.client
import http.server
import importlib.util
import json
import os
import tempfile
import threading
import time
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


class FakeService(http.server.BaseHTTPRequestHandler):
    """The build service as the gateway sees it, counting what reaches it."""

    library = b"a built game" * 100
    state = "done"
    asked = 0

    def log_message(self, *args):
        pass

    def send(self, value):
        data = json.dumps(value).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        self.rfile.read(int(self.headers["Content-Length"]))
        type(self).asked += 1
        self.send({"job": JOB})

    def do_GET(self):
        if self.path == "/v1/busy":
            return self.send({"busy": False})
        type(self).asked += 1
        cls = type(self)
        if self.path.endswith("/lib"):
            self.send_response(200)
            self.send_header("Content-Length", str(len(cls.library)))
            self.end_headers()
            self.wfile.write(cls.library)
        elif cls.state == "failed":
            self.send({"state": "failed", "error": "does not fit (E_X): no", "settled": True})
        elif cls.state == "building":
            self.send({"state": "building", "seconds": 5})
        else:
            self.send(
                {
                    "state": "done",
                    "sha256": getattr(cls, "says_sha", hashlib.sha256(cls.library).hexdigest()),
                    "size": len(cls.library),
                    "build": {},
                }
            )


JOB = "0123456789abcdef01234567"


class Stored(unittest.TestCase):
    """Through real sockets: the gateway in front of a fake service."""

    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.fake = type("Fake", (FakeService,), {"asked": 0, "state": "done"})
        self.service = http.server.ThreadingHTTPServer(("127.0.0.1", 0), self.fake)
        threading.Thread(target=self.service.serve_forever, daemon=True).start()
        self.addCleanup(self.service.server_close)
        self.service_up = True
        self.addCleanup(self.stop_service)
        self.gateway = load(
            BUILD_BACKEND=f"http://127.0.0.1:{self.service.server_address[1]}",
            STATE_DIRECTORY=self.folder.name,
        )
        self.gateway.MIN_FREE_BYTES = 0
        self.gateway.power = mock.Mock(return_value=True)
        self.door = http.server.ThreadingHTTPServer(("127.0.0.1", 0), self.gateway.Handler)
        threading.Thread(target=self.door.serve_forever, daemon=True).start()
        self.addCleanup(self.door.server_close)
        self.addCleanup(self.door.shutdown)

    def stop_service(self):
        if self.service_up:
            self.service.shutdown()
            self.service.server_close()
            self.service_up = False

    def call(self, method, path, body=None, headers=None):
        c = http.client.HTTPConnection("127.0.0.1", self.door.server_address[1], timeout=20)
        c.request(method, path, body, headers or {})
        response = c.getresponse()
        return response.status, response.read()

    def post(self, body=b"mods"):
        status, data = self.call("POST", "/v1/build?version=0.8.0", body)
        return status, json.loads(data)

    def poll(self):
        return json.loads(self.call("GET", f"/v1/job/{JOB}")[1])

    def settle_copy(self):
        for _ in range(200):
            if not self.gateway.copying:
                return
            time.sleep(0.02)
        self.fail("the copy did not end")

    def built_and_kept(self, body=b"mods"):
        self.assertEqual(self.post(body), (200, {"job": JOB}))
        self.assertEqual(self.poll()["state"], "done")
        self.settle_copy()

    def test_a_kept_build_is_answered_with_the_machine_asleep(self):
        self.built_and_kept()
        self.stop_service()
        self.assertEqual(self.post(), (200, {"job": JOB}))
        self.assertEqual(self.poll()["sha256"], hashlib.sha256(self.fake.library).hexdigest())
        status, data = self.call("GET", f"/v1/job/{JOB}/lib")
        self.assertEqual((status, data), (200, self.fake.library))
        status, data = self.call("GET", f"/v1/job/{JOB}/lib", headers={"Range": "bytes=5-"})
        self.assertEqual((status, data), (206, self.fake.library[5:]))
        self.gateway.power.assert_not_called()

    def test_a_restart_remembers_what_is_kept(self):
        self.built_and_kept()
        again = load(STATE_DIRECTORY=self.folder.name)
        again.load_index()
        request = next(iter(self.gateway.kept))
        self.assertEqual(again.answered_here(request), JOB)

    def test_a_library_that_came_different_is_not_kept(self):
        self.fake.says_sha = "0" * 64
        self.built_and_kept()
        self.assertEqual(self.gateway.kept, {})
        self.assertIsNone(self.gateway.kept_status(JOB))

    def test_a_known_failure_is_answered_with_the_machine_asleep(self):
        self.fake.state = "failed"
        self.assertEqual(self.post(), (200, {"job": JOB}))
        self.assertTrue(self.poll()["settled"])
        self.stop_service()
        self.assertEqual(self.post(), (200, {"job": JOB}))
        self.assertEqual(self.poll()["error"], "does not fit (E_X): no")
        self.gateway.power.assert_not_called()

    def test_a_known_failure_is_asked_again_after_a_day(self):
        self.fake.state = "failed"
        self.post()
        self.poll()
        for failure in self.gateway.known_failures.values():
            failure["at"] -= self.gateway.DAY + 1
        asked = self.fake.asked
        self.post()
        self.assertGreater(self.fake.asked, asked)

    def test_what_is_refused_or_answered_here_keeps_nothing_awake(self):
        self.built_and_kept()
        self.gateway.last_activity = 0.0
        self.post()
        self.poll()
        self.call("GET", f"/v1/job/{JOB}/lib")
        with mock.patch.object(self.gateway, "refusal", return_value="no"):
            self.assertEqual(self.post(b"other mods")[0], 429)
        self.assertEqual(self.call("POST", "/v1/build", b"")[0], 413)
        self.assertEqual(self.gateway.last_activity, 0.0)

    def test_a_build_on_its_way_keeps_the_machine_awake(self):
        self.gateway.last_activity = 0.0
        self.post()
        self.assertGreater(self.gateway.last_activity, 0.0)
        self.gateway.last_activity = 0.0
        self.fake.state = "building"
        self.assertEqual(self.poll()["state"], "building")
        self.assertGreater(self.gateway.last_activity, 0.0)

    def test_the_oldest_goes_when_the_store_is_full(self):
        self.built_and_kept()
        other = "fedcba9876543210fedcba98"
        folder = self.gateway.result_folder(other)
        os.makedirs(folder)
        with open(os.path.join(folder, self.gateway.LIBRARY), "wb") as f:
            f.write(b"x" * 100)
        with open(os.path.join(folder, "status.json"), "w", encoding="utf-8") as f:
            json.dump({"state": "done"}, f)
        os.utime(os.path.join(folder, "status.json"), (1, 1))
        self.gateway.kept["old request"] = other
        self.gateway.STORE_BYTES = len(self.fake.library)
        self.gateway.forget_oldest()
        self.assertIsNone(self.gateway.kept_status(other))
        self.assertNotIn("old request", self.gateway.kept)
        self.assertIsNotNone(self.gateway.kept_status(JOB))

    def test_a_job_that_is_not_a_job_never_reaches_a_path(self):
        for path in ("/v1/job/..%2f..%2fetc", "/v1/job/../../etc/passwd", f"/v1/job/{JOB}/lib/x", "/v1/other"):
            self.assertEqual(self.call("GET", path)[0], 404, path)

    def test_without_a_store_it_works_as_before(self):
        gateway = load()
        self.assertIsNone(gateway.kept_status(JOB))
        gateway.keep_result(JOB, {"sha256": "", "size": 0})
        self.assertEqual(gateway.copying, {})


if __name__ == "__main__":
    unittest.main()
