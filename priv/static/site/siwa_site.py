"""SIWA by Regents: a site's check, in one file with no dependencies (Python 3.11 or newer).

Run it as a practice site, with the site's test key in SIWA_SERVER_KEY:

    python3 siwa_site.py 4000

It answers every request at http://localhost:4000 with the agent that signed it.
In your own server, import `check_agent` and call it with the request's parts.
Guide: https://siwa.regents.sh/websites.md
"""

import base64
import contextlib
import hashlib
import http.client
import json
import logging
import os
import sys
import threading
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SERVICE = os.environ.get("SIWA_BROKER", "https://siwa.regents.sh")

# The headers an agent signs. Only these go to SIWA; the body never does.
SIGNED_HEADERS = (
    "x-siwa-signature",
    "x-siwa-signature-input",
    "x-siwa-receipt",
    "x-key-id",
    "x-timestamp",
    "x-agent-wallet-address",
    "x-agent-chain-id",
    "content-digest",
)

log = logging.getLogger("siwa")


def refused(status, code, message, retry_after=None):
    refusal = {"status": status, "code": code, "message": message, "retry_after": retry_after}
    return None, refusal


# Your site's own trouble (its key, proof, billing, cap or limits) and SIWA's. The
# agent learns only that it can try again; the reason stays in your log.
def unavailable(retry_after=None):
    message = "This site cannot check agent requests right now."
    return refused(503, "service_unavailable", message, retry_after)


def check_agent(method, path, host, headers, body=b"", *, key=None):
    """Asks SIWA whether an agent signed this exact request for your site.

    Returns (agent, refusal): exactly one is None. `agent` is SIWA's answer about the
    agent; `refusal` is {"status", "code", "message", "retry_after"}, ready to send back
    as it is. `path` keeps the query string. `host` is the public host agents send to:
    the Host header, or behind a proxy the public one. `headers` is any mapping of the
    request's headers, in any letter case, and `body` the exact bytes received. `key`
    is SIWA_SERVER_KEY unless given.
    """
    if key is None:
        key = os.environ.get("SIWA_SERVER_KEY")

    headers = {name.lower(): value for name, value in headers.items()}

    if "x-siwa-signature" not in headers:
        return refused(401, "signature_required", "This needs a signed agent request.")

    check = {
        "method": method,
        "path": path,
        "authority": host.lower(),
        "headers": {name: headers[name] for name in SIGNED_HEADERS if name in headers},
    }

    if body:
        digest = base64.b64encode(hashlib.sha256(body).digest()).decode()
        check["body_digest"] = f"sha-256=:{digest}:"

    request = urllib.request.Request(
        f"{SERVICE}/api/shared/siwa/http-verify",
        data=json.dumps(check).encode(),
        headers={"authorization": f"Bearer {key}", "content-type": "application/json"},
        method="POST",
    )

    # This waits for SIWA, so an async server runs check_agent with asyncio.to_thread.
    try:
        answer = urllib.request.urlopen(request, timeout=10)
    except urllib.error.HTTPError as refusal:
        answer = refusal  # urllib raises every answer but a 2xx; it is still SIWA's answer.
    except (OSError, http.client.HTTPException) as error:
        log.error("SIWA could not be reached: %s", error)
        return unavailable()

    try:
        said = json.loads(answer.read())
    except (OSError, http.client.HTTPException, ValueError):
        said = None

    if answer.status == 200 and said is not None:
        return said["data"], None

    error = (said or {}).get("error") or {}
    code = error.get("code")

    # A 401 or 409 whose code does not begin `site_` is about the agent's own request.
    if answer.status in (401, 409) and code and not code.startswith("site_"):
        return refused(401, code, error.get("message"))

    log.error("SIWA refused this site's check: %s %s", answer.status, code)
    return unavailable(answer.headers.get("retry-after"))


class PracticeSite(BaseHTTPRequestHandler):
    """Run directly: a practice site that answers each request with the agent that signed
    it, and how many times that agent has called since the site started."""

    visits = {}
    visits_lock = threading.Lock()

    def answer(self):
        body = self.rfile.read(int(self.headers.get("content-length", 0)))
        host = self.headers["host"]
        agent, refusal = check_agent(self.command, self.path, host, self.headers, body)

        if refusal:
            error = {"code": refusal["code"], "message": refusal["message"]}
            self.send(refusal["status"], {"error": error}, refusal["retry_after"])
            return

        # `subject` is the caller ID: the same for this agent on every visit.
        with self.visits_lock:
            count = self.visits.get(agent["subject"], 0) + 1
            self.visits[agent["subject"]] = count

        self.send(
            200,
            {
                "caller": agent["subject"],
                "wallet": agent["walletAddress"],
                "visits": count,
                "listing": agent["agentRegistration"],
                "person": agent["agentBook"],
            },
        )

    # http.server answers a method with do_<METHOD>; these are all answered alike.
    do_GET = do_HEAD = do_POST = do_PUT = do_PATCH = do_DELETE = answer

    def send(self, status, answer, retry_after=None):
        data = json.dumps(answer).encode()
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(data)))
        if retry_after:
            self.send_header("retry-after", retry_after)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    # The site's log holds only what check_agent writes, not a line per request.
    def log_message(self, format, *args):
        pass


if __name__ == "__main__":
    port = sys.argv[1] if len(sys.argv) > 1 else ""

    if not os.environ.get("SIWA_SERVER_KEY") or not port.isdecimal():
        usage = "usage: SIWA_SERVER_KEY=<the site's test key> python3 siwa_site.py <port>"
        print(usage, file=sys.stderr)
        sys.exit(2)

    logging.basicConfig(format="%(message)s")

    # 127.0.0.1 is the address every computer has, and a client sent to localhost tries it.
    site = ThreadingHTTPServer(("127.0.0.1", int(port)), PracticeSite)
    print(f"practice site at http://localhost:{port}", flush=True)

    with contextlib.suppress(KeyboardInterrupt):
        site.serve_forever()
