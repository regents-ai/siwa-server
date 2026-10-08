#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["eth-account>=0.13", "cryptography>=43"]
# ///
"""SIWA agent client: one Ethereum key for every Regent site.

Guide: https://siwa.regents.sh/skill.md

Pick how you sign, once:

    uv run siwa_agent.py keygen                      # this client makes and keeps a key (on a Mac, locked with a passkey)
    uv run siwa_agent.py use-wallet 0xADDRESS --signer 'cast wallet sign --account agent "$SIWA_MESSAGE"'

Then, for any Regent site:

    uv run siwa_agent.py sites
    uv run siwa_agent.py pair https://regents.sh CODE --name Astra --harness claude_code
    uv run siwa_agent.py me https://regents.sh
    uv run siwa_agent.py request POST https://keyfleet.ai/api/v1/agent/join/status --body '{"name":"Astra"}'

Optional, once: list yourself in the agent registry on Base (your wallet pays the gas):

    uv run siwa_agent.py register-agent --name Astra --description "What I do"

Optional, once your person has vouched for you with World ID (see the guide):

    uv run siwa_agent.py accept-world-id

Environment:

    SIWA_AGENT_HOME where the key and receipts are kept (default ~/.siwa-agent)
    SIWA_BROKER     the SIWA server (default https://siwa.regents.sh; the same server answers at
                    https://siwa-server.fly.dev if your network blocks siwa.regents.sh)
    SIWA_BASE_RPC   the Base node register-agent sends through (default https://mainnet.base.org)

A private key made by keygen never leaves this machine. On a Mac it is locked
with a passkey: your person confirms with Touch ID once after each restart, and
`show-key` shows the plain key to copy. With use-wallet, this client never sees
a private key at all: it hands each text to your signer.
"""

from __future__ import annotations

import argparse
import base64
import contextlib
import hashlib
import http.server
import json
import os
import re
import secrets
import socket
import socketserver
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone

CHAINS = {"base": 8453, "ethereum": 1}
DEFAULT_BROKER = "https://siwa.regents.sh"
FLY_BROKER = "https://siwa-server.fly.dev"
DEFAULT_BASE_RPC = "https://mainnet.base.org"
REGISTRATION_WAIT_SECONDS = 120
RECEIPT_RENEW_MARGIN_SECONDS = 60
SIGNER_TIMEOUT_SECONDS = 300
PASSKEY_WAIT_SECONDS = 300
HELPER_ANSWER_SECONDS = 10
HELPER_START_SECONDS = 10
USER_AGENT = "siwa-agent-client/2.9 (python)"
# BEGIN SIWA CONTRACT
# Contract 517e597b931ea89b77e9cbc4aa688c5cedb2c1d7408ffe35aab84ab8648f4d4f, written by `mix siwa_server.agent_clients` from the siwa library; do not edit.
SIWA_CONTRACT = json.loads(
    r"""
{
  "version": 1,
  "label": "sig1",
  "signature_header": "x-siwa-signature",
  "signature_input_header": "x-siwa-signature-input",
  "components": [
    {
      "name": "@method",
      "from": "method"
    },
    {
      "name": "@path",
      "from": "path"
    },
    {
      "name": "x-siwa-receipt",
      "from": "receipt"
    },
    {
      "name": "x-key-id",
      "from": "key_id"
    },
    {
      "name": "x-timestamp",
      "from": "created"
    },
    {
      "name": "x-agent-wallet-address",
      "from": "wallet_address"
    },
    {
      "name": "x-agent-chain-id",
      "from": "chain_id"
    }
  ],
  "body": {
    "component": "content-digest",
    "algorithm": "sha-256"
  },
  "params": [
    {
      "name": "created",
      "from": "created"
    },
    {
      "name": "expires",
      "from": "expires"
    },
    {
      "name": "nonce",
      "from": "nonce"
    },
    {
      "name": "keyid",
      "from": "key_id"
    }
  ],
  "lifetime_seconds": 120,
  "forwarded_headers": [
    "x-siwa-signature",
    "x-siwa-signature-input",
    "x-siwa-receipt",
    "x-key-id",
    "x-timestamp",
    "x-agent-wallet-address",
    "x-agent-chain-id",
    "content-digest"
  ]
}
"""
)
# END SIWA CONTRACT
ADDRESS_PATTERN = re.compile(r"^0x[0-9a-fA-F]{40}$")
SIGNATURE_PATTERN = re.compile(r"0x[0-9a-fA-F]{130,}")
BOX_INFO = b"agent key box"
PASSKEY_ASKS = {
    "lock": "Ask your person to lock your new key: they press Use Touch ID on the page that just opened on this Mac.",
    "unlock": "Ask your person to unlock your key: they press Use Touch ID on the page that just opened on this Mac. They are asked once after each restart.",
    "show": "Ask your person to confirm with Touch ID on the page that just opened on this Mac.",
}

# The page where the person confirms with Touch ID. The passkey belongs to
# localhost, so only a page served on this Mac can use it.
PASSKEY_PAGE = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Agent key</title>
<style>
  :root { --bg: #fafaf9; --fg: #1c1917; --muted: #78716c; --bad: #b91c1c; --btn: #1c1917; --btn-fg: #fafaf9; }
  @media (prefers-color-scheme: dark) { :root { --bg: #1c1917; --fg: #fafaf9; --muted: #a8a29e; --bad: #f87171; --btn: #fafaf9; --btn-fg: #1c1917; } }
  body { background: var(--bg); color: var(--fg); font: 16px/1.5 -apple-system, system-ui, sans-serif; margin: 0; padding: 48px 16px; }
  main { max-width: 480px; margin: 0 auto; }
  h1 { font-size: 22px; margin: 0 0 4px; }
  p { color: var(--muted); margin: 0 0 20px; }
  code { font-size: 13px; word-break: break-all; }
  button { background: var(--btn); color: var(--btn-fg); border: 0; border-radius: 8px; padding: 10px 18px; font: inherit; cursor: pointer; }
  #note { color: var(--bad); margin-top: 12px; }
</style>
</head>
<body>
<main>
  <h1 id="title"></h1>
  <p id="lead"></p>
  <p><code id="address"></code></p>
  <button id="go">Use Touch ID</button>
  <p id="note"></p>
</main>
<script>
const setup = __SETUP__;
const words = {
  lock: ["Lock your agent's key", "A passkey on this Mac locks it. Touch ID opens it."],
  unlock: ["Unlock your agent's key", "Asked once after each restart."],
  show: ["Show your agent's key", "It appears where your agent asked for it."],
}[setup.mode];
const $ = (id) => document.getElementById(id);
document.title = words[0];
$("title").textContent = words[0];
$("lead").textContent = words[1];
$("address").textContent = setup.address;
const hex = (bytes) => [...new Uint8Array(bytes)].map((b) => b.toString(16).padStart(2, "0")).join("");
const unhex = (text) => new Uint8Array(text.match(/../g).map((h) => parseInt(h, 16)));
const random = (size) => crypto.getRandomValues(new Uint8Array(size));
const salt = () => crypto.subtle.digest("SHA-256", new TextEncoder().encode("regent agent key"));

async function secretOf(credentialId) {
  const credential = await navigator.credentials.get({ publicKey: {
    challenge: random(32),
    rpId: "localhost",
    allowCredentials: [{ type: "public-key", id: unhex(credentialId) }],
    userVerification: "required",
    extensions: { prf: { eval: { first: await salt() } } },
  } });
  const first = credential.getClientExtensionResults().prf?.results?.first;
  if (!first) throw new Error("This browser can't open the passkey. Open this page in Safari or Chrome.");
  return { credential_id: credentialId, secret: hex(first) };
}

async function makePasskey() {
  const credential = await navigator.credentials.create({ publicKey: {
    rp: { name: "Regent agent key", id: "localhost" },
    user: { id: random(16), name: setup.address, displayName: "Regent agent key" },
    challenge: random(32),
    pubKeyCredParams: [{ type: "public-key", alg: -7 }, { type: "public-key", alg: -257 }],
    authenticatorSelection: { residentKey: "required", userVerification: "required" },
    extensions: { prf: { eval: { first: await salt() } } },
  } });
  // A passkey store may give the secret only when the passkey is next used.
  const first = credential.getClientExtensionResults().prf?.results?.first;
  return first ? { credential_id: hex(credential.rawId), secret: hex(first) } : secretOf(hex(credential.rawId));
}

$("go").onclick = async () => {
  $("go").disabled = true;
  $("note").textContent = "";
  try {
    const answer = setup.mode === "lock" ? await makePasskey() : await secretOf(setup.credentialId);
    const sent = await fetch(location.pathname, { method: "POST", body: JSON.stringify(answer) }).catch(() => null);
    if (!sent?.ok) throw new Error("Your agent stopped waiting. Run its command again.");
    $("title").textContent = "Done";
    $("lead").textContent = "You can close this tab.";
    $("go").hidden = true;
  } catch (error) {
    $("note").textContent = error.message;
    $("go").disabled = false;
  }
};
</script>
</body>
</html>
"""


class SiwaError(Exception):
    pass


class Unreachable(Exception):
    def __init__(self, host: str, reason: object) -> None:
        super().__init__(f"could not reach {host}: {reason}")
        self.host = host


def settings() -> dict:
    home = os.path.expanduser(os.environ.get("SIWA_AGENT_HOME", "~/.siwa-agent"))
    broker = os.environ.get("SIWA_BROKER", DEFAULT_BROKER).strip().rstrip("/")
    base_rpc = os.environ.get("SIWA_BASE_RPC", DEFAULT_BASE_RPC).strip()
    return {"home": home, "broker": broker, "base_rpc": base_rpc, "key_path": os.path.join(home, "key.json")}


def load_json(path: str) -> dict | None:
    if not os.path.exists(path):
        return None
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def save_json(path: str, value: dict) -> None:
    """Write an owner-only file, then swap it in whole, so no one reads half of it."""
    folder = os.path.dirname(path)
    os.makedirs(folder, mode=0o700, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(dir=folder, suffix=".tmp")
    with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
        json.dump(value, handle, indent=2)
    os.replace(temporary, path)


def require_key(config: dict) -> dict:
    key = load_json(config["key_path"])
    if not key:
        raise SiwaError(f"no key at {config['key_path']}; run keygen or use-wallet first")
    return key


def chain_id(key: dict) -> int:
    """The chain this key signs in on: the one use-wallet chose, else Base."""
    return key.get("chain_id", CHAINS["base"])


def receipt_path(config: dict, audience: str) -> str:
    return os.path.join(config["home"], "receipts", f"{audience}.json")


def http_json(method: str, url: str, body: bytes | None = None, headers: dict | None = None) -> tuple[int, dict | str]:
    request = urllib.request.Request(url, data=body, method=method)
    request.add_header("accept", "application/json")
    request.add_header("user-agent", USER_AGENT)
    if body is not None:
        request.add_header("content-type", "application/json")
    for name, value in (headers or {}).items():
        request.add_header(name, value)
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return response.status, decode_body(response.read())
    except urllib.error.HTTPError as error:
        return error.code, decode_body(error.read())
    except OSError as error:
        raise Unreachable(urllib.parse.urlsplit(url).hostname, getattr(error, "reason", error)) from error


def network_hint(host: str) -> str:
    """What to do when a host cannot be reached, shaped by the harness this runs in."""
    steps = [
        f"Find out why before you retry: run `curl -sv https://{host}/ -o /dev/null` and show your person",
        f"the address {host} resolves to and what happened. If curl also hangs, or its connection is closed",
        f"with no answer, your network blocks {host}; retrying will not help. If curl gets an answer and this",
        f"client still cannot reach {host}, your network lets curl through but not this client: show your",
        "person both results.",
    ]
    if f"https://{host}" == DEFAULT_BROKER:
        steps.append(f"If your network blocks {host}, the same SIWA server answers at {FLY_BROKER}: set SIWA_BROKER={FLY_BROKER} for every command.")
    if os.environ.get("CODEX_SANDBOX_NETWORK_DISABLED") == "1":
        steps.append("You run in Codex's sandbox with network access off: ask your person to allow network access for this command.")
    elif os.environ.get("CLAUDECODE") == "1":
        steps.append(f"Claude Code's sandbox may keep this command off the network: ask your person to allow {host}.")
    return " ".join(steps)


def json_body(value: dict) -> bytes:
    return json.dumps(value, separators=(",", ":")).encode("utf-8")


def decode_body(raw: bytes) -> dict | str:
    text = raw.decode("utf-8", errors="replace")
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return text


def origin_of(url: str) -> str:
    parts = urllib.parse.urlsplit(url)
    if parts.scheme != "https" or not parts.hostname:
        raise SiwaError(f"{url} is not an https address")
    port = "" if parts.port in (None, 443) else f":{parts.port}"
    return f"https://{parts.hostname.lower()}{port}"


def audiences(config: dict) -> list[dict]:
    status, body = http_json("GET", f"{config['broker']}/api/shared/siwa/audiences")
    if status != 200 or not isinstance(body, dict) or body.get("code") != "audiences":
        raise SiwaError(f"could not list sites ({status}): {json.dumps(body)}")
    return body["data"]["audiences"]


def audience_for(config: dict, url: str) -> str:
    origin = origin_of(url)
    listed = audiences(config)
    for entry in listed:
        if entry["origin"] == origin:
            return entry["audience"]
    known = ", ".join(entry["origin"] for entry in listed)
    raise SiwaError(f"{origin} does not accept agent sign-in; sites that do: {known}")


def eth_account():
    try:
        from eth_account import Account
        from eth_account.messages import encode_defunct
    except ModuleNotFoundError as error:
        raise SiwaError("start this client with `uv run siwa_agent.py`; it installs what the key needs") from error
    return Account, encode_defunct


def box_cipher(secret: str):
    """The AES-GCM cipher a passkey's secret opens, the same in the Python and Node clients."""
    try:
        from cryptography.hazmat.primitives import hashes
        from cryptography.hazmat.primitives.ciphers.aead import AESGCM
        from cryptography.hazmat.primitives.kdf.hkdf import HKDF
    except ModuleNotFoundError as error:
        raise SiwaError("start this client with `uv run siwa_agent.py`; it installs what the key needs") from error
    return AESGCM(HKDF(algorithm=hashes.SHA256(), length=32, salt=bytes(32), info=BOX_INFO).derive(bytes.fromhex(secret)))


def passkey_secret(mode: str, address: str, credential_id: str | None) -> dict:
    """Open a page on this Mac where the person confirms with Touch ID; return the passkey's id and secret."""
    token = secrets.token_urlsafe(24)
    setup = json.dumps({"mode": mode, "address": address, "credentialId": credential_id})
    page = PASSKEY_PAGE.replace("__SETUP__", setup).encode("utf-8")
    answer: dict = {}
    answered = threading.Event()

    class Page(http.server.BaseHTTPRequestHandler):
        def do_GET(self) -> None:
            if self.path != f"/{token}":
                self.send_error(404)
                return
            self.send_response(200)
            self.send_header("content-type", "text/html; charset=utf-8")
            self.send_header("cache-control", "no-store")
            self.end_headers()
            self.wfile.write(page)

        def do_POST(self) -> None:
            if self.path != f"/{token}" or answered.is_set():
                self.send_error(404)
                return
            answer.update(json.loads(self.rfile.read(int(self.headers["content-length"]))))
            self.send_response(204)
            self.end_headers()
            answered.set()

        def log_message(self, *_args) -> None:
            pass

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Page)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    url = f"http://localhost:{server.server_port}/{token}"
    print(json.dumps({"touch_id": PASSKEY_ASKS[mode], "page": url}), file=sys.stderr, flush=True)
    subprocess.run(["open", url], check=False)
    try:
        if not answered.wait(PASSKEY_WAIT_SECONDS):
            raise SiwaError(f"no Touch ID within {PASSKEY_WAIT_SECONDS // 60} minutes; run the command again and ask your person to confirm on the page it opens")
    finally:
        server.shutdown()
    return answer


def lock(address: str, private_key: str) -> dict:
    """Make a passkey for this key and seal the key with the passkey's secret."""
    answer = passkey_secret("lock", address, None)
    iv = secrets.token_bytes(12)
    box = box_cipher(answer["secret"]).encrypt(iv, private_key.encode("utf-8"), address.encode("utf-8"))
    return {"credential_id": answer["credential_id"], "iv": iv.hex(), "box": box.hex()}


def open_box(key: dict, mode: str) -> str:
    locked = key["locked"]
    answer = passkey_secret(mode, key["address"], locked["credential_id"])
    private_key = box_cipher(answer["secret"]).decrypt(bytes.fromhex(locked["iv"]), bytes.fromhex(locked["box"]), key["address"].encode("utf-8"))
    return private_key.decode("utf-8")


def helper_socket(key: dict) -> str:
    """Where the helper holding this unlocked key listens, shared by the Python and Node clients:
    the Mac's own private folder for this user, whatever TMPDIR a harness sets."""
    folder = subprocess.run(["getconf", "DARWIN_USER_TEMP_DIR"], capture_output=True, text=True, check=True).stdout.strip()
    name = hashlib.sha256(key["address"].encode("utf-8")).hexdigest()[:16]
    return os.path.join(folder, f"siwa-agent-{name}.sock")


def ask_helper(path: str, request: dict) -> dict | None:
    """One request to the helper; None when no helper is listening."""
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
            connection.settimeout(HELPER_ANSWER_SECONDS)
            connection.connect(path)
            connection.sendall(json_body(request) + b"\n")
            reply = connection.makefile("rb").readline()
    except TimeoutError:
        # A stuck helper is still there: unlocking again would start a second one behind it.
        raise SiwaError(
            f"the key helper at {path} did not answer within {HELPER_ANSWER_SECONDS} seconds, so nothing was signed or sent. "
            "Stop the stuck key helper (a background siwa-agent or regents process) or restart this Mac, "
            "then run this again; Touch ID asks once"
        ) from None
    except (FileNotFoundError, ConnectionRefusedError, ConnectionResetError, BrokenPipeError):
        return None
    # A helper that is stopping can take the connection and close it unanswered.
    if not reply:
        return None
    answer = json.loads(reply)
    if "error" in answer:
        raise SiwaError(answer["error"])
    return answer


def start_helper(key: dict, private_key: str) -> None:
    """Hand the unlocked key to a helper that keeps it until this Mac restarts."""
    path = helper_socket(key)
    helper = subprocess.Popen(
        [sys.executable, os.path.abspath(__file__), "key-helper", path],
        stdin=subprocess.PIPE,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
    helper.stdin.write(private_key.encode("utf-8"))
    helper.stdin.close()
    deadline = time.time() + HELPER_START_SECONDS
    while ask_helper(path, {"op": "address"}) is None:
        if time.time() > deadline:
            raise SiwaError(f"the helper that keeps your unlocked key did not start within {HELPER_START_SECONDS} seconds")
        time.sleep(0.1)


def unlocked(key: dict, request: dict) -> dict:
    """Ask the helper holding the unlocked key; unlock it with Touch ID first when none is running."""
    answer = ask_helper(helper_socket(key), request)
    if answer is None:
        start_helper(key, open_box(key, "unlock"))
        answer = ask_helper(helper_socket(key), request)
    if answer is None:
        raise SiwaError("the key helper closed without answering; run this again")
    return answer


def stop_helper(key: dict) -> None:
    ask_helper(helper_socket(key), {"op": "stop"})


def sign_message_with(private_key: str, text: str) -> str:
    Account, encode_defunct = eth_account()
    signed = Account.sign_message(encode_defunct(text=text), private_key=private_key)
    return "0x" + signed.signature.hex().removeprefix("0x")


def sign_transaction_with(private_key: str, transaction: dict) -> str:
    """Sign a Base transaction given as 0x quantities (chainId, nonce, gas, fees, value) and 0x hex (to, data)."""
    Account, _encode_defunct = eth_account()
    signed = Account.sign_transaction({
        "type": 2,
        "chainId": int(transaction["chainId"], 16),
        "nonce": int(transaction["nonce"], 16),
        "to": bytes.fromhex(transaction["to"].removeprefix("0x")),
        "data": transaction["data"],
        "value": int(transaction["value"], 16),
        "gas": int(transaction["gas"], 16),
        "maxFeePerGas": int(transaction["maxFeePerGas"], 16),
        "maxPriorityFeePerGas": int(transaction["maxPriorityFeePerGas"], 16),
    }, private_key=private_key)
    return "0x" + signed.raw_transaction.hex().removeprefix("0x")


def sign_text(key: dict, text: str) -> str:
    if "private_key" in key:
        return sign_message_with(key["private_key"], text)
    if "locked" in key:
        return unlocked(key, {"op": "sign_message", "text": text})["signature"]
    return run_signer(key["signer"], text)


def sign_transaction(key: dict, transaction: dict) -> str:
    if "locked" in key:
        return unlocked(key, {"op": "sign_transaction", "transaction": transaction})["raw"]
    return sign_transaction_with(key["private_key"], transaction)


def signer_name(key: dict) -> str:
    """How this client signs, so the sign-in service can word its advice on a refusal."""
    if "signer" not in key:
        return "own-key"
    return os.path.basename((key["signer"].split() or [""])[0])


def run_signer(command: str, text: str) -> str:
    """Hand the exact text to the wallet's own signing command and read back its signature."""
    try:
        result = subprocess.run(
            command,
            shell=True,
            input=text,
            env={**os.environ, "SIWA_MESSAGE": text},
            capture_output=True,
            text=True,
            timeout=SIGNER_TIMEOUT_SECONDS,
        )
    except subprocess.TimeoutExpired as error:
        raise SiwaError(f"signer did not answer within {SIGNER_TIMEOUT_SECONDS} seconds") from error
    if result.returncode != 0:
        raise SiwaError(f"signer exited {result.returncode}: {result.stderr.strip() or result.stdout.strip()}")
    found = set(SIGNATURE_PATTERN.findall(result.stdout))
    if len(found) != 1:
        raise SiwaError(f"signer must print exactly one 0x signature; it printed: {result.stdout.strip()}")
    return found.pop()


def load_receipt(config: dict, key: dict, audience: str) -> dict | None:
    receipt = load_json(receipt_path(config, audience))
    if not receipt or receipt.get("address") != key["address"]:
        return None
    return receipt


def receipt_is_fresh(receipt: dict | None) -> bool:
    if not receipt:
        return False
    expires = datetime.fromisoformat(receipt["receipt_expires_at"].replace("Z", "+00:00"))
    return (expires - datetime.now(timezone.utc)).total_seconds() > RECEIPT_RENEW_MARGIN_SECONDS


def sign_in(config: dict, key: dict, audience: str) -> dict:
    """Obtain a fresh receipt for this key and site, and store it."""
    broker, address = config["broker"], key["address"]
    base = {"wallet_address": address, "chain_id": chain_id(key), "audience": audience}
    status, nonce = http_json("POST", f"{broker}/api/shared/siwa/wallet/nonce", json_body(base))
    if status != 200 or not isinstance(nonce, dict) or nonce.get("code") != "nonce_issued":
        raise SiwaError(f"nonce request failed ({status}): {json.dumps(nonce)}")
    challenge = nonce["data"]
    signature = sign_text(key, challenge["message"])
    proof = {**base, "nonce": challenge["nonce"], "message": challenge["message"], "signature": signature}
    status, verified = http_json("POST", f"{broker}/api/shared/siwa/wallet/verify", json_body(proof), {"x-agent-signer": signer_name(key)})
    if status != 200 or not isinstance(verified, dict) or verified.get("code") != "wallet_verified":
        raise SiwaError(f"verification failed ({status}): {json.dumps(verified)}")
    data = verified["data"]
    receipt = {
        "address": address,
        "audience": audience,
        "receipt": data["receipt"],
        "receipt_expires_at": data["receiptExpiresAt"],
        "key_id": data["keyId"],
    }
    save_json(receipt_path(config, audience), receipt)
    return receipt


def fresh_receipt(config: dict, key: dict, audience: str) -> dict:
    receipt = load_receipt(config, key, audience)
    return receipt if receipt_is_fresh(receipt) else sign_in(config, key, audience)


def content_digest(body: bytes) -> str:
    algorithm = SIWA_CONTRACT["body"]["algorithm"]
    digest = hashlib.new(algorithm.replace("-", ""), body).digest()
    return algorithm + "=:" + base64.b64encode(digest).decode("ascii") + ":"


def signature_param(value: int | str) -> str:
    """Integers are bare; strings are quoted."""
    return str(value) if isinstance(value, int) else f'"{value}"'


def signed_headers(key: dict, receipt: dict, method: str, url: str, body: bytes | None) -> dict:
    """Build the SIWA signed-request headers for one request from SIWA_CONTRACT. Each call signs fresh."""
    parsed = urllib.parse.urlsplit(url)
    path = parsed.path or "/"
    if parsed.query:
        path += "?" + parsed.query
    created = int(time.time())
    sources = {
        "method": method.lower(),
        "path": path,
        "receipt": receipt["receipt"],
        "key_id": receipt["key_id"],
        "created": created,
        "expires": created + SIWA_CONTRACT["lifetime_seconds"],
        "nonce": "sig-nonce-" + secrets.token_hex(16),
        "wallet_address": key["address"],
        "chain_id": chain_id(key),
    }
    covered = [(component["name"], str(sources[component["from"]])) for component in SIWA_CONTRACT["components"]]
    if body is not None:
        covered.append((SIWA_CONTRACT["body"]["component"], content_digest(body)))
    params = "(" + " ".join(f'"{name}"' for name, _ in covered) + ")" + "".join(
        f";{param['name']}={signature_param(sources[param['from']])}" for param in SIWA_CONTRACT["params"]
    )
    lines = [f'"{name}": {value}' for name, value in covered]
    lines.append(f'"@signature-params": {params}')
    signature = sign_text(key, "\n".join(lines))
    label = SIWA_CONTRACT["label"]
    headers = {name: value for name, value in covered if not name.startswith("@")}
    headers[SIWA_CONTRACT["signature_input_header"]] = f"{label}={params}"
    headers[SIWA_CONTRACT["signature_header"]] = f"{label}=:" + base64.b64encode(bytes.fromhex(signature[2:])).decode("ascii") + ":"
    return headers


def receipt_rejected(response: dict | str) -> bool:
    text = json.dumps(response)
    return "receipt_invalid" in text or "receipt_binding_mismatch" in text


def send_signed(config: dict, method: str, url: str, body: bytes | None, extra: dict | None = None) -> tuple[int, dict | str]:
    key = require_key(config)
    audience = audience_for(config, url)
    receipt = fresh_receipt(config, key, audience)
    status, response = http_json(method, url, body, {**(extra or {}), **signed_headers(key, receipt, method, url, body)})
    if status == 401 and receipt_rejected(response):
        receipt = sign_in(config, key, audience)
        status, response = http_json(method, url, body, {**(extra or {}), **signed_headers(key, receipt, method, url, body)})
    return status, response


def print_response(status: int, response: dict | str) -> None:
    print(json.dumps({"status": status, "body": response}, indent=2))
    if status >= 400:
        sys.exit(1)


def site_url(site: str, path: str) -> str:
    return origin_of(site) + path


def command_keygen(config: dict, args: argparse.Namespace) -> None:
    existing = load_json(config["key_path"])
    if existing and not args.force:
        print(json.dumps({"address": existing["address"], "key": config["key_path"], "created": False}))
        return
    Account, _encode_defunct = eth_account()
    account = Account.create()
    address, private_key = account.address.lower(), "0x" + account.key.hex().removeprefix("0x")
    if sys.platform == "darwin":
        key = {"address": address, "locked": lock(address, private_key)}
        save_json(config["key_path"], key)
        start_helper(key, private_key)
    else:
        save_json(config["key_path"], {"address": address, "private_key": private_key})
    if existing and "locked" in existing:
        stop_helper(existing)
    print(json.dumps({"address": address, "key": config["key_path"], "created": True, "locked": sys.platform == "darwin"}))


def command_lock_key(config: dict, _args: argparse.Namespace) -> None:
    key = require_key(config)
    if sys.platform != "darwin":
        raise SiwaError("lock-key needs a Mac: the key is locked with a Mac passkey")
    if "private_key" not in key:
        raise SiwaError("this key is already locked" if "locked" in key else "your wallet tool keeps this key; lock-key locks a key this client keeps")
    locked = {"address": key["address"], "locked": lock(key["address"], key["private_key"])}
    save_json(config["key_path"], locked)
    start_helper(locked, key["private_key"])
    print(json.dumps({
        "address": key["address"],
        "key": config["key_path"],
        "locked": True,
        "note": "key.json no longer holds the plain key. Any copy made elsewhere still does.",
    }, indent=2))


def command_show_key(config: dict, _args: argparse.Namespace) -> None:
    key = require_key(config)
    if "signer" in key:
        raise SiwaError("your wallet tool keeps this key; show it with that tool")
    private_key = open_box(key, "show") if "locked" in key else key["private_key"]
    print(json.dumps({
        "address": key["address"],
        "private_key": private_key,
        "note": "Anyone with this key controls this wallet and everything in it. Give it only to your person, never to a chat, a log or a commit.",
    }, indent=2))


def command_key_helper(_config: dict, args: argparse.Namespace) -> None:
    """Keep an unlocked key in memory and sign with it for this user's clients until the Mac restarts."""
    Account, _encode_defunct = eth_account()
    account = Account.from_key(sys.stdin.read().strip())
    private_key = "0x" + account.key.hex().removeprefix("0x")
    if ask_helper(args.socket, {"op": "address"}) is not None:
        return
    if os.path.exists(args.socket):
        os.unlink(args.socket)

    class Helper(socketserver.StreamRequestHandler):
        def handle(self) -> None:
            request = json.loads(self.rfile.readline())
            op = request.get("op")
            try:
                if op == "address":
                    reply = {"address": account.address.lower()}
                elif op == "sign_message":
                    reply = {"signature": sign_message_with(private_key, request["text"])}
                elif op == "sign_transaction":
                    reply = {"raw": sign_transaction_with(private_key, request["transaction"])}
                elif op == "stop":
                    reply = {"stopped": True}
                    threading.Thread(target=self.server.shutdown).start()
                else:
                    reply = {"error": f"the key helper does not know {op}"}
            except (KeyError, ValueError, TypeError) as error:
                reply = {"error": f"the key helper could not sign: {error}"}
            self.wfile.write(json_body(reply) + b"\n")

    os.umask(0o077)
    with socketserver.ThreadingUnixStreamServer(args.socket, Helper) as server:
        bound = os.stat(args.socket).st_ino
        server.serve_forever()
    # A newer helper may already listen at the same path; its socket stays.
    with contextlib.suppress(FileNotFoundError):
        if os.stat(args.socket).st_ino == bound:
            os.unlink(args.socket)


def command_use_wallet(config: dict, args: argparse.Namespace) -> None:
    if not ADDRESS_PATTERN.match(args.address):
        raise SiwaError(f"{args.address} is not an Ethereum address")
    existing = load_json(config["key_path"])
    if existing and not args.force:
        raise SiwaError(f"{config['key_path']} already holds {existing['address']}; add --force to replace it")
    chain = CHAINS[args.chain]
    save_json(config["key_path"], {"address": args.address.lower(), "signer": args.signer, "chain_id": chain})
    if existing and "locked" in existing:
        stop_helper(existing)
    print(json.dumps({"address": args.address.lower(), "key": config["key_path"], "signer": args.signer, "chain_id": chain}))


def command_whoami(config: dict, _args: argparse.Namespace) -> None:
    key = require_key(config)
    receipts_dir = os.path.join(config["home"], "receipts")
    signed_in = []
    if os.path.isdir(receipts_dir):
        for name in sorted(os.listdir(receipts_dir)):
            receipt = load_receipt(config, key, name.removesuffix(".json"))
            if receipt_is_fresh(receipt):
                signed_in.append({"site": receipt["audience"], "until": receipt["receipt_expires_at"]})
    shown = {"address": key["address"]}
    if "private_key" in key:
        shown["signs_with"] = "this client's key"
    elif "locked" in key:
        shown["signs_with"] = "this client's key, locked with a Mac passkey"
        shown["unlocked_until_restart"] = ask_helper(helper_socket(key), {"op": "address"}) is not None
    else:
        shown["signs_with"] = key["signer"]
    print(json.dumps({**shown, "chain_id": chain_id(key), "broker": config["broker"], "signed_in": signed_in}, indent=2))


def command_sites(config: dict, _args: argparse.Namespace) -> None:
    print(json.dumps(audiences(config), indent=2))


def command_sign_in(config: dict, args: argparse.Namespace) -> None:
    key = require_key(config)
    receipt = sign_in(config, key, audience_for(config, args.site))
    print(json.dumps({"address": key["address"], "site": receipt["audience"], "until": receipt["receipt_expires_at"]}))


def command_pair(config: dict, args: argparse.Namespace) -> None:
    body = json_body({"code": args.code, "name": args.name, "harness": args.harness})
    print_response(*send_signed(config, "POST", site_url(args.site, "/api/agents/v1/pair"), body))


def command_me(config: dict, args: argparse.Namespace) -> None:
    print_response(*send_signed(config, "GET", site_url(args.site, "/api/agents/v1/me"), None))


def command_request(config: dict, args: argparse.Namespace) -> None:
    body = None if args.body is None else args.body.encode("utf-8")
    extra = dict(pair.split("=", 1) for pair in args.header)
    print_response(*send_signed(config, args.method.upper(), args.url, body, extra))


def command_headers(config: dict, args: argparse.Namespace) -> None:
    key = require_key(config)
    receipt = fresh_receipt(config, key, audience_for(config, args.url))
    body = None if args.body is None else args.body.encode("utf-8")
    print(json.dumps(signed_headers(key, receipt, args.method.upper(), args.url, body), indent=2))


def base_rpc(config: dict, method: str, params: list):
    status, body = http_json("POST", config["base_rpc"], json_body({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}))
    if status != 200 or not isinstance(body, dict) or "result" not in body:
        raise SiwaError(f"Base node refused {method} ({status}): {json.dumps(body)}")
    return body["result"]


def send_registration(config: dict, key: dict, step: dict) -> str:
    """Sign the registration with this client's key and send it on Base; the wallet pays the gas."""
    call = {"from": step["from"], "to": step["to"], "data": step["data"], "value": step["value"]}
    gas = int(base_rpc(config, "eth_estimateGas", [call]), 16) * 6 // 5
    tip = int(base_rpc(config, "eth_maxPriorityFeePerGas", []), 16)
    base_fee = int(base_rpc(config, "eth_getBlockByNumber", ["latest", False])["baseFeePerGas"], 16)
    max_fee = base_fee * 2 + tip
    balance = int(base_rpc(config, "eth_getBalance", [step["from"], "latest"]), 16)
    if balance < gas * max_fee:
        raise SiwaError(
            f"{step['from']} holds {balance} wei on Base; the registration needs up to {gas * max_fee} wei of ETH on Base for gas. "
            "Ask your person to send a little ETH on Base to that address, then run this again."
        )
    transaction = {
        "chainId": hex(step["chainId"]),
        "nonce": base_rpc(config, "eth_getTransactionCount", [step["from"], "pending"]),
        "to": step["to"],
        "data": step["data"],
        "value": step["value"],
        "gas": hex(gas),
        "maxFeePerGas": hex(max_fee),
        "maxPriorityFeePerGas": hex(tip),
    }
    return base_rpc(config, "eth_sendRawTransaction", [sign_transaction(key, transaction)])


def wait_for_registration(config: dict, profile: dict, tx_hash: str) -> tuple[int, dict | str]:
    deadline = time.time() + REGISTRATION_WAIT_SECONDS
    while True:
        status, body = http_json("POST", f"{config['broker']}/api/shared/siwa/agent/registered", json_body({**profile, "tx_hash": tx_hash}))
        pending = status == 200 and isinstance(body, dict) and body.get("code") == "registration_pending"
        if not pending or time.time() > deadline:
            return status, body
        time.sleep(2)


def command_register_agent(config: dict, args: argparse.Namespace) -> None:
    key = require_key(config)
    profile = {"wallet_address": key["address"], "name": args.name, "description": args.description}
    if args.image:
        profile["image"] = args.image
    if args.tx_hash:
        print_response(*wait_for_registration(config, profile, args.tx_hash))
        return
    status, body = http_json("POST", f"{config['broker']}/api/shared/siwa/agent/register-step", json_body(profile))
    if status != 200 or not isinstance(body, dict) or body.get("code") != "registration_step":
        print_response(status, body)
        return
    step = body["data"]
    if "signer" in key:
        same = f"--name {json.dumps(args.name)} --description {json.dumps(args.description)}" + (f" --image {json.dumps(args.image)}" if args.image else "")
        print(json.dumps({
            "step": step,
            "send": f"cast send {step['to']} 'register(string)' '{step['agentUri']}' --rpc-url {config['base_rpc']} --account agent",
            "then": f"uv run siwa_agent.py register-agent {same} --tx-hash 0xTRANSACTION_HASH",
            "note": "Send this one transaction from your wallet on Base with your wallet tool, then report its hash with the `then` command.",
        }, indent=2))
        return
    print_response(*wait_for_registration(config, profile, send_registration(config, key, step)))


def command_accept_world_id(config: dict, args: argparse.Namespace) -> None:
    key = require_key(config)
    base = {"wallet_address": key["address"], "chain_id": chain_id(key)}
    status, body = http_json("POST", f"{config['broker']}/api/shared/siwa/agent-book/challenge", json_body(base))
    if status != 200 or not isinstance(body, dict) or body.get("code") != "agent_book_challenge":
        print_response(status, body)
        return
    challenge = body["data"]
    if args.human_id is None:
        print(json.dumps({
            "humanId": challenge["humanId"],
            "note": "World's AgentBook names this person behind your address. Anyone with a World ID can put their number on any address, so ask your person to confirm they just vouched for you, then run the `then` command. Accepting is for good: you cannot accept another person later.",
            "then": f"uv run siwa_agent.py accept-world-id --human-id {challenge['humanId']}",
        }, indent=2))
        return
    if args.human_id.lower() != challenge["humanId"]:
        raise SiwaError(f"World's AgentBook names {challenge['humanId']} behind your address, not {args.human_id}; ask your person before accepting")
    proof = {**base, "nonce": challenge["nonce"], "message": challenge["message"], "signature": sign_text(key, challenge["message"])}
    print_response(*http_json("POST", f"{config['broker']}/api/shared/siwa/agent-book/accept", json_body(proof), {"x-agent-signer": signer_name(key)}))


def main(argv: list[str]) -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)

    keygen = commands.add_parser("keygen", help="make a key this client keeps, locked with a passkey on a Mac (no-op when a key exists)")
    keygen.add_argument("--force", action="store_true", help="replace the existing key; the old identity is lost")
    keygen.set_defaults(run=command_keygen)

    commands.add_parser("lock-key", help="on a Mac, lock the plain key this client keeps with a passkey").set_defaults(run=command_lock_key)
    commands.add_parser("show-key", help="show this client's private key to copy, after Touch ID on a Mac").set_defaults(run=command_show_key)
    key_helper = commands.add_parser("key-helper", help="started by this client: keeps an unlocked key until the Mac restarts")
    key_helper.add_argument("socket")
    key_helper.set_defaults(run=command_key_helper)

    use_wallet = commands.add_parser("use-wallet", help="sign with your own wallet tool instead of a key kept here")
    use_wallet.add_argument("address", help="the wallet's Ethereum address")
    use_wallet.add_argument("--signer", required=True, help="shell command that signs $SIWA_MESSAGE (also on stdin) as an Ethereum personal message and prints the 0x signature")
    use_wallet.add_argument("--chain", choices=sorted(CHAINS), default="base", help="the chain a smart wallet lives on (default base); an ordinary wallet works on either")
    use_wallet.add_argument("--force", action="store_true", help="replace the existing key; the old identity is lost")
    use_wallet.set_defaults(run=command_use_wallet)

    commands.add_parser("whoami", help="show your address, how you sign and where you are signed in").set_defaults(run=command_whoami)
    commands.add_parser("sites", help="list the sites that accept agent sign-in").set_defaults(run=command_sites)

    sign_in_parser = commands.add_parser("sign-in", help="sign in to a site now (requests do this on their own)")
    sign_in_parser.add_argument("site", help="the site's address, for example https://keyfleet.ai")
    sign_in_parser.set_defaults(run=command_sign_in)

    pair = commands.add_parser("pair", help="pair with your person's account using their one-time code")
    pair.add_argument("site")
    pair.add_argument("code")
    pair.add_argument("--name", required=True, help="the name your person knows you by")
    pair.add_argument("--harness", required=True, help="what you run on, for example claude_code, codex, hermes, muse")
    pair.set_defaults(run=command_pair)

    me = commands.add_parser("me", help="check in and see which account you are paired with")
    me.add_argument("site")
    me.set_defaults(run=command_me)

    register = commands.add_parser("register-agent", help="optional: list yourself in the agent registry on Base; your wallet pays the gas")
    register.add_argument("--name", required=True, help="your public name in the registry")
    register.add_argument("--description", required=True, help="what you do, in a sentence or two")
    register.add_argument("--image", help="an https address of your picture")
    register.add_argument("--tx-hash", help="the registration you already sent with your own wallet tool")
    register.set_defaults(run=command_register_agent)

    accept = commands.add_parser("accept-world-id", help="optional: accept the person who vouched for you with World ID, so sites show it")
    accept.add_argument("--human-id", help="your person's World ID number, as the command without it printed; signs only when AgentBook still names it")
    accept.set_defaults(run=command_accept_world_id)

    for name, handler, help_text in (
        ("request", command_request, "send a signed request and print the response"),
        ("headers", command_headers, "print signed headers for a request without sending it"),
    ):
        sub = commands.add_parser(name, help=help_text)
        sub.add_argument("method")
        sub.add_argument("url")
        sub.add_argument("--body", help="exact request body; sign and send these bytes")
        sub.add_argument("--header", action="append", default=[], metavar="NAME=VALUE", help="extra unsigned header")
        sub.set_defaults(run=handler)

    args = parser.parse_args(argv)
    try:
        args.run(settings(), args)
    except SiwaError as error:
        print(json.dumps({"error": str(error)}), file=sys.stderr)
        sys.exit(2)
    except Unreachable as error:
        print(json.dumps({"error": str(error), "hint": network_hint(error.host)}), file=sys.stderr)
        sys.exit(3)


if __name__ == "__main__":
    main(sys.argv[1:])
