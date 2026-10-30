"""airlock ui — a local web UI over the airlock CLI (D36).

Started by `airlock ui`, never directly. It is an adapter and nothing more:
every fact it shows comes from `airlock status --json`, and every change it
makes is an `airlock` command run with arguments the request supplied. It runs
no git, reads no workspace file and keeps no state but the output of the
commands it has started, so the UI can never disagree with the CLI, and D34's
sandbox covers it without its knowing.

It listens on 127.0.0.2, which no guest can reach: slirp maps a guest's
10.0.2.2 to 127.0.0.1 alone (D35). Every other user of the host, and every web
page the browser loads, can reach it all the same, so the boundary is the
token. Every /api request must carry it, which nobody but the developer has, and
no web page can send without first getting past CORS, which this server never
answers.
"""

import collections
import hmac
import http.server
import json
import os
import re
import secrets
import subprocess
import sys
import threading
import time
import urllib.parse

CLI = os.environ["AIRLOCK_UI_CLI"]
STATIC = os.path.join(os.path.dirname(os.path.abspath(__file__)), "static")

# The only files served. A fixed table rather than a directory, so no request
# path is ever joined onto the filesystem.
FILES = {
    "/": ("index.html", "text/html; charset=utf-8"),
    "/app.js": ("app.js", "text/javascript; charset=utf-8"),
    "/style.css": ("style.css", "text/css; charset=utf-8"),
}

# The same rules the CLI enforces (validate_workspace_name, validate_task_name),
# checked here too so a name can never be read as one of its options.
WORKSPACE_RE = re.compile(r"^[A-Za-z0-9._][A-Za-z0-9._-]*$")
TASK_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
UPSTREAM_RE = re.compile(r"^[a-z0-9.]+$")

MAX_BODY = 1 << 20      # a prompt, at most
MAX_OUTPUT = 1 << 20    # per job; the start is dropped past this
MAX_JOBS = 100          # finished jobs kept; the oldest go first
STATUS_TIMEOUT = 120    # seconds; status is offline, but a broken plan can be slow


class BadRequest(Exception):
    pass


def workspace_name(value):
    if not isinstance(value, str) or not WORKSPACE_RE.match(value) or value in (".", ".."):
        raise BadRequest("not a workspace name: %r" % (value,))
    return value


def task_name(value):
    if not isinstance(value, str) or not TASK_RE.match(value):
        raise BadRequest("not a task name: %r" % (value,))
    return value


def text(body, key, required=False):
    value = body.get(key, "")
    if value is None:
        value = ""
    if not isinstance(value, str):
        raise BadRequest("%s must be a string" % key)
    value = value.strip() if key != "prompt" else value
    if required and not value:
        raise BadRequest("%s is required" % key)
    return value


# --- jobs ------------------------------------------------------------------
#
# Every change is a job: an airlock command whose output the page reads as it
# arrives. Commands like init and task new can take minutes (a clone, LFS
# objects), and what they print on the way is the progress report.

class Job:
    def __init__(self, ident, title, argv):
        self.id = ident
        self.title = title
        self.argv = argv
        self.output = ""
        self.dropped = 0
        self.code = None
        self.started = time.time()
        self.ended = None
        self.lock = threading.Lock()

    def append(self, chunk):
        with self.lock:
            self.output += chunk
            over = len(self.output) - MAX_OUTPUT
            if over > 0:
                self.output = self.output[over:]
                self.dropped += over

    def view(self, since=0):
        with self.lock:
            start = max(since - self.dropped, 0)
            return {
                "id": self.id,
                "title": self.title,
                "argv": self.argv,
                "state": "running" if self.code is None else ("ok" if self.code == 0 else "failed"),
                "code": self.code,
                "started": self.started,
                "ended": self.ended,
                "offset": self.dropped + len(self.output),
                "output": self.output[start:],
            }


class Jobs:
    def __init__(self):
        self.jobs = collections.OrderedDict()
        self.lock = threading.Lock()
        self.next = 1

    def start(self, title, args):
        argv = [CLI] + args
        with self.lock:
            job = Job(str(self.next), title, ["airlock"] + args)
            self.next += 1
            self.jobs[job.id] = job
            finished = [j for j in self.jobs.values() if j.code is not None]
            for old in finished[: max(len(finished) - MAX_JOBS, 0)]:
                del self.jobs[old.id]
        threading.Thread(target=self.run, args=(job, argv), daemon=True).start()
        return job

    @staticmethod
    def run(job, argv):
        try:
            proc = subprocess.Popen(
                argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT)
        except OSError as e:
            job.append("could not start airlock: %s\n" % e)
            job.code, job.ended = 127, time.time()
            return
        while True:
            chunk = proc.stdout.read1(65536)
            if not chunk:
                break
            job.append(chunk.decode("utf-8", "replace"))
        code = proc.wait()
        with job.lock:
            job.code, job.ended = code, time.time()

    def get(self, ident):
        with self.lock:
            return self.jobs.get(ident)

    def all(self):
        with self.lock:
            return list(self.jobs.values())


JOBS = Jobs()


def status(args):
    """`airlock status --json`, parsed. A broken workspace exits non-zero
    with a report all the same, so the report decides, not the exit status."""
    proc = subprocess.run(
        [CLI, "status"] + args + ["--json"], stdin=subprocess.DEVNULL,
        capture_output=True, timeout=STATUS_TIMEOUT)
    try:
        return json.loads(proc.stdout.decode("utf-8", "replace"))
    except ValueError:
        err = proc.stderr.decode("utf-8", "replace").strip()
        raise RuntimeError(err or "airlock status printed no report (exit %d)" % proc.returncode)


# --- routes ----------------------------------------------------------------

def route_post(parts, body):
    """A change, as the job that makes it. parts is the path after /api/."""
    if parts == ["workspaces"]:
        name = workspace_name(body.get("name"))
        source = body.get("source")
        location = text(body, "location", required=True)
        if source == "remote":
            args = ["init", name, "--from-remote", location]
        elif source == "local":
            # Relative to what? The server's directory is no answer anyone meant.
            if not location.startswith("/"):
                raise BadRequest("a local checkout is named by its absolute path")
            args = ["init", name, "--from-local", location]
        else:
            raise BadRequest("source is remote or local")
        for key, flag in (("branch", "--branch"), ("project", "--project"), ("flavor", "--flavor")):
            value = text(body, key)
            if value:
                args += [flag, value]
        return JOBS.start("create workspace %s" % name, args)

    if len(parts) == 3 and parts[0] == "workspaces" and parts[2] == "fetch":
        name = workspace_name(parts[1])
        return JOBS.start("fetch %s" % name, ["fetch", name])

    if len(parts) == 3 and parts[0] == "workspaces" and parts[2] == "tasks":
        name = workspace_name(parts[1])
        task = task_name(body.get("task"))
        args = ["task", "new", name, task]
        prompt = text(body, "prompt")
        if prompt.strip():
            args += ["--prompt", prompt]
        base = text(body, "base")
        if base:
            args += ["--base", base]
        return JOBS.start("new task %s/%s" % (name, task), args)

    if len(parts) == 5 and parts[0] == "workspaces" and parts[2] == "tasks":
        name, task, action = workspace_name(parts[1]), task_name(parts[3]), parts[4]
        if action == "stop":
            args = ["stop", name, task] + (["--force"] if body.get("force") is True else [])
            return JOBS.start("stop %s/%s" % (name, task), args)
        if action == "rm":
            # The page asks first, with what would be lost (`status --json`'s
            # changes and unpushed); task rm repeats that check after a fetch
            # and prints what it found into the job's output.
            return JOBS.start("remove task %s/%s" % (name, task), ["task", "rm", name, task, "--yes"])

    if len(parts) == 2 and parts[0] == "hub" and parts[1] in ("start", "stop", "restart"):
        return JOBS.start("hub %s" % parts[1], ["hub", parts[1]])

    if len(parts) in (2, 3) and parts[0] == "registry" and parts[1] in ("start", "stop", "restart"):
        args = ["registry", parts[1]]
        if len(parts) == 3:
            if not UPSTREAM_RE.match(parts[2]):
                raise BadRequest("not an upstream: %r" % parts[2])
            args.append(parts[2])
        return JOBS.start(" ".join(args), args)

    return None


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "airlock-ui"
    sys_version = ""
    protocol_version = "HTTP/1.1"

    # --- plumbing --------------------------------------------------------

    def send(self, code, payload, ctype="application/json"):
        if ctype == "application/json":
            payload = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Content-Security-Policy",
                         "default-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(payload)

    def error(self, code, message):
        self.send(code, {"error": message})

    def log_message(self, fmt, *args):
        sys.stderr.write("airlock ui: %s %s\n" % (self.address_string(), fmt % args))

    def log_request(self, code="-", size="-"):
        # The page polls; only what changes something, or was refused, is news.
        if self.command == "POST" or (isinstance(code, int) and code >= 400):
            super().log_request(code, size)

    def host_ok(self):
        """A DNS-rebinding page reaches this server under its own name, which
        this refuses. Only the address the printed URL names: localhost would
        be 127.0.0.1, where this does not listen."""
        addr, port = self.server.server_address[:2]
        return self.headers.get("Host", "") == "%s:%d" % (addr, port)

    def authorised(self):
        given = self.headers.get("Authorization", "")
        want = "Bearer " + self.server.token
        return hmac.compare_digest(given.encode(), want.encode())

    def guard(self):
        if not self.host_ok():
            self.error(403, "unexpected Host header")
            return False
        if self.path.startswith("/api/") and not self.authorised():
            self.error(401, "missing or wrong token; open the URL airlock ui printed")
            return False
        return True

    def body(self):
        if self.headers.get("Content-Type", "").split(";")[0].strip() != "application/json":
            raise BadRequest("send application/json")
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            raise BadRequest("bad Content-Length")
        if length < 0 or length > MAX_BODY:
            raise BadRequest("request too large")
        raw = self.rfile.read(length) if length else b"{}"
        try:
            body = json.loads(raw.decode("utf-8"))
        except ValueError:
            raise BadRequest("not JSON")
        if not isinstance(body, dict):
            raise BadRequest("send a JSON object")
        return body

    # --- methods ---------------------------------------------------------

    def do_GET(self):
        if not self.guard():
            return
        url = urllib.parse.urlsplit(self.path)
        if url.path in FILES:
            name, ctype = FILES[url.path]
            with open(os.path.join(STATIC, name), "rb") as f:
                self.send(200, f.read(), ctype)
            return
        parts = [urllib.parse.unquote(p) for p in url.path.split("/")[2:] if p] \
            if url.path.startswith("/api/") else None
        try:
            if parts == ["status"]:
                self.send(200, status([]))
            elif parts and len(parts) == 2 and parts[0] == "workspaces":
                self.send(200, status([workspace_name(parts[1])]))
            elif parts == ["jobs"]:
                self.send(200, {"jobs": [j.view(1 << 62) for j in JOBS.all()]})
            elif parts and len(parts) == 2 and parts[0] == "jobs":
                job = JOBS.get(parts[1])
                if job is None:
                    self.error(404, "no such job")
                    return
                query = urllib.parse.parse_qs(url.query)
                try:
                    since = int(query.get("since", ["0"])[0])
                except ValueError:
                    since = 0
                self.send(200, job.view(since))
            else:
                self.error(404, "not found")
        except BadRequest as e:
            self.error(400, str(e))
        except (RuntimeError, subprocess.TimeoutExpired) as e:
            self.error(502, str(e))

    def do_HEAD(self):
        self.do_GET()

    def do_POST(self):
        if not self.guard():
            return
        url = urllib.parse.urlsplit(self.path)
        if not url.path.startswith("/api/"):
            self.error(404, "not found")
            return
        parts = [urllib.parse.unquote(p) for p in url.path.split("/")[2:] if p]
        try:
            job = route_post(parts, self.body())
        except BadRequest as e:
            self.error(400, str(e))
            return
        if job is None:
            self.error(404, "not found")
            return
        self.send(202, job.view())


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True


def main():
    addr, port = sys.argv[1], int(sys.argv[2])
    server = Server((addr, port), Handler)
    server.token = secrets.token_urlsafe(32)
    # The token travels in the fragment, which a browser never sends anywhere:
    # the page reads it, keeps it for the tab and takes it out of the address.
    print("airlock ui: http://%s:%d/#token=%s" % (addr, server.server_address[1], server.token), flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
