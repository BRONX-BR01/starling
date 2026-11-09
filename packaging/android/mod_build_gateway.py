#!/usr/bin/env python3
"""The door to Starling's mod build service (mod_build_server.py), on a small machine that stays on.

The build machine costs money by the hour, so it sleeps: a request wakes it, and it is put back to sleep
once it has had nothing to do for a while. Finished libraries and known failures stay here, so asking for
them again doesn't wake it. Behind Caddy, which holds the HTTPS. The machine's own identity may only start,
stop and read that one VM. Python's standard library only.

    BUILD_BACKEND    http://host:8787
    BUILD_VM         the VM's Azure resource id
    GATEWAY_PORT     default 8788
    STATE_DIRECTORY  where results stay (systemd's StateDirectory); without it nothing stays
    STORE_BYTES      how much of them, default 10 GiB
"""
import hashlib
import http.client
import http.server
import json
import os
import re
import shutil
import threading
import time
import urllib.parse
import urllib.request

BACKEND = urllib.parse.urlparse(os.environ["BUILD_BACKEND"])
VM = os.environ["BUILD_VM"]
PORT = int(os.environ.get("GATEWAY_PORT", "8788"))
ARM = "https://management.azure.com"
IDENTITY = (
    "http://169.254.169.254/metadata/identity/oauth2/token"
    "?api-version=2018-02-01&resource=https%3A%2F%2Fmanagement.azure.com%2F"
)
MAX_BODY = 32 << 20
# Nothing to do for this long, and the machine goes back to sleep. Short, as it bills by the hour and a
# player's next build waits only the minute it takes to wake.
IDLE_SECONDS = 2 * 60
# Started and never answered: put back to sleep rather than left on.
START_SECONDS = 20 * 60
# Between asks to start it, while it boots.
START_AGAIN_SECONDS = 90
# Builds a day, so one player or everyone together can't run the bill up.
PER_ADDRESS = 32
# A build that failed gives its place back, but it took the machine's time, so failing has its own limit.
FAILED_PER_ADDRESS = 24
PER_DAY = int(os.environ.get("BUILDS_PER_DAY", "80"))
FAILED_PER_DAY = PER_DAY
DAY = 24 * 3600
# As many as the service keeps results of (KEEP_RESULTS): beyond them it would build again, uncounted.
BUILT_REMEMBERED = 12
YOUR_LIMIT = "You have reached today's build limit. Try again tomorrow."
EVERYONES_LIMIT = "The build server has reached today's limit for all players. Try again tomorrow."
STORE = os.environ.get("STATE_DIRECTORY", "")
STORE_BYTES = int(os.environ.get("STORE_BYTES", str(10 << 30)))
# This machine has other work to do: results never bring its free space below this.
MIN_FREE_BYTES = 6 << 30
JOB = re.compile(r"[0-9a-f]{24}")
LIBRARY = "libhorizon_android.so"
CHUNK = 256 * 1024

lock = threading.Lock()
index_lock = threading.Lock()
last_activity = time.time()
started_at = None
asked_at = 0.0
accepted = []
built = {}
# Requests answered here: request to job, and request to the job, when and the service's words.
kept = {}
known_failures = {}
# Jobs whose library is on its way here, and proxied downloads: the machine stays on for them.
copying = {}
proxying = 0


def power(action):
    """Asks Azure to `start` or `deallocate` the VM. False when it would not."""
    try:
        request = urllib.request.Request(IDENTITY, headers={"Metadata": "true"})
        with urllib.request.urlopen(request, timeout=10) as answer:
            token = json.load(answer)["access_token"]
        request = urllib.request.Request(
            f"{ARM}{VM}/{action}?api-version=2024-07-01",
            data=b"",
            method="POST",
            headers={"Authorization": f"Bearer {token}"},
        )
        with urllib.request.urlopen(request, timeout=30):
            pass
        print(f"asked Azure to {action}", flush=True)
        return True
    except OSError as e:
        print(f"{action} failed: {e}", flush=True)
        return False


def connection(timeout):
    """To the service, connected: a sleeping machine doesn't refuse, it says nothing, so the connecting
    has a short wait of its own."""
    c = http.client.HTTPConnection(BACKEND.hostname, BACKEND.port, timeout=4)
    c.connect()
    c.sock.settimeout(timeout)
    return c


def backend_status():
    """The service's `busy`, or None while it does not answer."""
    try:
        c = connection(4)
        c.request("GET", "/v1/busy")
        answer = c.getresponse()
        return json.loads(answer.read()).get("busy") if answer.status == 200 else None
    except (OSError, ValueError, http.client.HTTPException):
        return None


def wake():
    """Whether the service answers; if not, it is being woken."""
    global started_at, asked_at
    if backend_status() is not None:
        return True
    with lock:
        ask = time.time() - asked_at > START_AGAIN_SECONDS
        if ask:
            asked_at = time.time()
    if ask and power("start"):
        with lock:
            if started_at is None:
                started_at = time.time()
    return False


def sleeper():
    """Puts back to sleep what this started, when it has been idle. A machine someone else started
    is left alone, and so is one whose service answered and then stopped: someone is working on it,
    or it is already off."""
    global started_at
    answered = False
    while True:
        time.sleep(30)
        with lock:
            started, active = started_at, last_activity
            working = bool(copying) or proxying > 0
        if started is None:
            answered = False
            continue
        now = time.time()
        busy = backend_status()
        if busy is None:
            if answered:
                with lock:
                    started_at = None
                continue
            give_up = now - started > START_SECONDS
        else:
            answered = True
            give_up = (
                not busy
                and not working
                and now - active > IDLE_SECONDS
                and now - started > IDLE_SECONDS
            )
        if give_up and power("deallocate"):
            with lock:
                started_at = None


def refusal(address, request):
    """What to say if this build doesn't count within the day's, asked before it reaches the line:
    refused after, it would still be built. What is built already costs no build, and neither does the
    same request again, unless it failed and would build again. None when it may go on."""
    now = time.time()
    with lock:
        if request in built:
            return None
        accepted[:] = [a for a in accepted if now - a["at"] < DAY]
        # Failed for the mods' own fault: the service says so again without building.
        if any(a["request"] == request and a["settled"] for a in accepted):
            return None
        own = [a for a in accepted if a["address"] == address]
        if any(a["request"] == request and not a["failed"] for a in own):
            return None
        if (
            sum(not a["failed"] for a in own) >= PER_ADDRESS
            or sum(a["failed"] for a in own) >= FAILED_PER_ADDRESS
        ):
            return YOUR_LIMIT
        if (
            sum(not a["failed"] for a in accepted) >= PER_DAY
            # By job: the same mods asked in another order fail without building.
            or len({a["job"] for a in accepted if a["failed"] and a["job"]}) >= FAILED_PER_DAY
        ):
            return EVERYONES_LIMIT
        accepted.append(
            {
                "at": now,
                "address": address,
                "request": request,
                "job": None,
                "failed": False,
                "settled": False,
            }
        )
    return None


def note_job(address, request, job):
    """Ties a counted request to its job. With no job nothing will build, and its place comes back."""
    with lock:
        for a in accepted:
            if a["address"] == address and a["request"] == request and not a["failed"]:
                a["job"] = job
                a["failed"] = job is None


def job_failed(job, settled=False):
    with lock:
        for a in accepted:
            if a["job"] == job:
                a["failed"] = True
                a["settled"] = settled


def job_done(job):
    """Remembers what this job was asked with: anyone asking the same gets its library, no build."""
    with lock:
        for a in accepted:
            if a["job"] == job:
                built.pop(a["request"], None)
                built[a["request"]] = job
        while len(built) > BUILT_REMEMBERED:
            del built[next(iter(built))]


def save_index():
    """What a restart must not forget. The results themselves are their own record."""
    if not STORE:
        return
    path = os.path.join(STORE, "index.json")
    with lock:
        data = json.dumps({"kept": kept, "failures": known_failures})
    try:
        with index_lock:
            with open(path + ".part", "w", encoding="utf-8") as f:
                f.write(data)
            os.replace(path + ".part", path)
    except OSError as e:
        print(f"could not save the index: {e}", flush=True)


def load_index():
    if not STORE:
        return
    try:
        with open(os.path.join(STORE, "index.json"), encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        return
    with lock:
        kept.update(data.get("kept") or {})
        known_failures.update(data.get("failures") or {})


def result_folder(job):
    return os.path.join(STORE, "results", job)


def kept_status(job):
    """What the service said of a finished job whose library is here, or None. The status is written
    last: with it there, the library is whole."""
    if not STORE:
        return None
    try:
        with open(os.path.join(result_folder(job), "status.json"), encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def failure_of(job):
    """The service's words on a job that failed for the mods' own fault, while they hold."""
    now = time.time()
    with lock:
        for failure in known_failures.values():
            if failure["job"] == job and now - failure["at"] < DAY:
                return failure["status"]
    return None


def answered_here(request):
    """The job of a request that needs no machine: built and kept, or failed for the mods' own fault."""
    now = time.time()
    with lock:
        failure = known_failures.get(request)
        if failure and now - failure["at"] < DAY:
            return failure["job"]
        job = kept.get(request)
    return job if job and kept_status(job) else None


def remember_failure(job, status):
    """The same mods on the same game fail the same way, for as long as a day's count remembers it."""
    now = time.time()
    changed = False
    with lock:
        for a in accepted:
            if a["job"] == job and a["request"] not in known_failures:
                known_failures[a["request"]] = {"job": job, "at": now, "status": status}
                changed = True
        for request in [r for r, f in known_failures.items() if now - f["at"] >= DAY]:
            del known_failures[request]
            changed = True
    if changed:
        save_index()


def forget_oldest():
    """Down to the store's size, what was asked for longest ago going first."""
    root = os.path.join(STORE, "results")
    found = []
    for job in os.listdir(root):
        try:
            asked = os.path.getmtime(os.path.join(root, job, "status.json"))
            found.append((asked, os.path.getsize(os.path.join(root, job, LIBRARY)), job))
        except OSError:
            continue
    found.sort(reverse=True)
    total = 0
    gone = set()
    for _, size, job in found:
        total += size
        if total > STORE_BYTES:
            shutil.rmtree(os.path.join(root, job), ignore_errors=True)
            gone.add(job)
    with lock:
        for request in [r for r, j in kept.items() if j in gone]:
            del kept[request]


def copy_result(job, status):
    """Brings a finished library here, checked, before the machine sleeps."""
    os.makedirs(os.path.join(STORE, "results"), exist_ok=True)
    folder = result_folder(job)
    part = folder + ".part"
    try:
        if shutil.disk_usage(STORE).free - status["size"] < MIN_FREE_BYTES:
            print(f"no room to keep {job}", flush=True)
            return
        c = connection(60)
        c.request("GET", f"/v1/job/{job}/lib")
        response = c.getresponse()
        if response.status != 200:
            return
        digest = hashlib.sha256()
        with open(part, "wb") as f:
            while chunk := response.read(CHUNK):
                digest.update(chunk)
                f.write(chunk)
        if digest.hexdigest() != status["sha256"] or os.path.getsize(part) != status["size"]:
            print(f"{job} came different from what the service said", flush=True)
            return
        os.makedirs(folder, exist_ok=True)
        os.replace(part, os.path.join(folder, LIBRARY))
        with open(os.path.join(folder, "status.part"), "w", encoding="utf-8") as f:
            json.dump(status, f)
        os.replace(os.path.join(folder, "status.part"), os.path.join(folder, "status.json"))
        with lock:
            for a in accepted:
                if a["job"] == job:
                    kept[a["request"]] = job
        forget_oldest()
        save_index()
    except (OSError, ValueError, KeyError, http.client.HTTPException) as e:
        print(f"could not keep {job}: {e}", flush=True)
    finally:
        if os.path.exists(part):
            os.remove(part)
        with lock:
            copying.pop(job).set()


def keep_result(job, status):
    if not STORE or kept_status(job):
        return
    with lock:
        if job in copying:
            return
        copying[job] = threading.Event()
    threading.Thread(target=copy_result, args=(job, status), daemon=True).start()


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "StarlingModGateway"
    timeout = 120

    def address(self):
        forwarded = self.headers.get("X-Forwarded-For") or self.client_address[0]
        return forwarded.split(",")[0].strip()

    def answer(self, code, value):
        data = json.dumps(value).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def seen(self):
        global last_activity
        with lock:
            last_activity = time.time()

    def do_POST(self):
        url = urllib.parse.urlparse(self.path)
        if url.path != "/v1/build":
            return self.answer(404, {"error": "No such thing here."})
        size = int(self.headers.get("Content-Length") or 0)
        if size <= 0 or size > MAX_BODY:
            return self.answer(413, {"error": "That is too big to compile."})
        body = self.rfile.read(size)
        request = hashlib.sha256(self.path.encode() + body).hexdigest()
        job = answered_here(request)
        if job:
            return self.answer(200, {"job": job})
        refused = refusal(self.address(), request)
        if refused:
            print(f"refused: {refused}", flush=True)
            return self.answer(429, {"error": refused})
        # Only now is there something for the machine to do: asking alone keeps nothing awake.
        self.seen()
        if not wake():
            return self.answer(200, {"starting": True})
        try:
            c = connection(60)
            c.request(
                "POST",
                self.path,
                body,
                {"Content-Type": "application/octet-stream", "X-Real-IP": self.address()},
            )
            response = c.getresponse()
            data = response.read()
        except (OSError, http.client.HTTPException):
            return self.answer(200, {"starting": True})
        job = json.loads(data).get("job") if response.status == 200 else None
        note_job(self.address(), request, job)
        self.send_response(response.status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def serve_library(self, job):
        path = os.path.join(result_folder(job), LIBRARY)
        size = os.path.getsize(path)
        start = 0
        ranged = re.fullmatch(r"bytes=(\d+)-", self.headers.get("Range") or "")
        if ranged and int(ranged.group(1)) < size:
            start = int(ranged.group(1))
        self.send_response(206 if start else 200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(size - start))
        if start:
            self.send_header("Content-Range", f"bytes {start}-{size - 1}/{size}")
        self.end_headers()
        with open(path, "rb") as f:
            f.seek(start)
            shutil.copyfileobj(f, self.wfile, CHUNK)

    def do_GET(self):
        path = urllib.parse.urlparse(self.path).path
        parts = path.strip("/").split("/")
        if parts[:2] != ["v1", "job"] or len(parts) not in (3, 4) or parts[3:] not in ([], ["lib"]):
            return self.answer(404, {"error": "No such thing here."})
        job = parts[2]
        if not JOB.fullmatch(job):
            return self.answer(404, {"error": "No such thing here."})
        library = len(parts) == 4
        failure = failure_of(job)
        if failure and not library:
            return self.answer(200, failure)
        with lock:
            arriving = copying.get(job)
        if library and arriving:
            arriving.wait(60)
        status = kept_status(job)
        if status:
            try:
                os.utime(os.path.join(result_folder(job), "status.json"))
            except OSError:
                pass
            return self.serve_library(job) if library else self.answer(200, status)
        return self.forward(path, library, job)

    def forward(self, path, library, job):
        """The service's answer, for what isn't here."""
        global proxying
        headers = {}
        if self.headers.get("Range"):
            headers["Range"] = self.headers["Range"]
        try:
            c = connection(60)
            c.request("GET", path, headers=headers)
            response = c.getresponse()
        except (OSError, http.client.HTTPException):
            self.seen()
            wake()
            if library:
                return self.answer(503, {"error": "The build server is waking up."})
            return self.answer(200, {"state": "starting"})
        self.send_response(response.status)
        for name in ("Content-Type", "Content-Length", "Content-Range"):
            value = response.getheader(name)
            if value:
                self.send_header(name, value)
        self.end_headers()
        if library:
            with lock:
                proxying += 1
            try:
                shutil.copyfileobj(response, self.wfile, CHUNK)
            finally:
                with lock:
                    proxying -= 1
                self.seen()
            return
        data = response.read()
        try:
            status = json.loads(data)
            state = status.get("state")
        except ValueError:
            status, state = None, None
        if state in ("queued", "building"):
            self.seen()
        elif state == "failed":
            settled = bool(status.get("settled"))
            job_failed(job, settled)
            if settled:
                remember_failure(job, status)
        elif state == "done":
            job_done(job)
            keep_result(job, status)
        self.wfile.write(data)


def main():
    global started_at
    load_index()
    # What was on when this restarted is looked after as if this had started it: forgotten, it would stay on.
    if backend_status() is not None:
        started_at = time.time()
    threading.Thread(target=sleeper, daemon=True).start()
    http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
