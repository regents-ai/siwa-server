#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["eth-account>=0.13"]
# ///
"""SIWA agent client: one Ethereum key for every Regent site.

Guide: https://siwa.regents.sh/skill.md

Pick how you sign, once:

    uv run siwa_agent.py keygen                      # this client makes and keeps a key
    uv run siwa_agent.py use-wallet 0xADDRESS --signer 'cast wallet sign --account agent "$SIWA_MESSAGE"'

Then, for any Regent site:

    uv run siwa_agent.py sites
    uv run siwa_agent.py pair https://regents.sh CODE --name Astra --harness claude_code
    uv run siwa_agent.py me https://regents.sh
    uv run siwa_agent.py request POST https://keyfleet.ai/api/v1/agent/join/status --body '{"name":"Astra"}'

Environment:

    SIWA_AGENT_HOME where the key and receipts are kept (default ~/.siwa-agent)
    SIWA_BROKER     the SIWA server (default https://siwa.regents.sh)

A private key made by keygen never leaves this machine. With use-wallet, this
client never sees a private key at all: it hands each text to your signer.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import re
import secrets
import stat
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone

CHAIN_ID = 8453
DEFAULT_BROKER = "https://siwa.regents.sh"
RECEIPT_RENEW_MARGIN_SECONDS = 60
REQUEST_SIGNATURE_LIFETIME_SECONDS = 120
SIGNER_TIMEOUT_SECONDS = 300
USER_AGENT = "siwa-agent-client/2.0 (python)"
ADDRESS_PATTERN = re.compile(r"^0x[0-9a-fA-F]{40}$")
SIGNATURE_PATTERN = re.compile(r"0x[0-9a-fA-F]{130,}")


class SiwaError(Exception):
    pass


def settings() -> dict:
    home = os.path.expanduser(os.environ.get("SIWA_AGENT_HOME", "~/.siwa-agent"))
    broker = os.environ.get("SIWA_BROKER", DEFAULT_BROKER).strip().rstrip("/")
    return {"home": home, "broker": broker, "key_path": os.path.join(home, "key.json")}


def load_json(path: str) -> dict | None:
    if not os.path.exists(path):
        return None
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def save_json(path: str, value: dict) -> None:
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(value, handle, indent=2)
    os.chmod(path, stat.S_IRUSR | stat.S_IWUSR)


def require_key(config: dict) -> dict:
    key = load_json(config["key_path"])
    if not key:
        raise SiwaError(f"no key at {config['key_path']}; run keygen or use-wallet first")
    return key


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


def sign_text(key: dict, text: str) -> str:
    if "private_key" in key:
        Account, encode_defunct = eth_account()
        signed = Account.sign_message(encode_defunct(text=text), private_key=key["private_key"])
        return "0x" + signed.signature.hex().removeprefix("0x")
    return run_signer(key["signer"], text)


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
    base = {"wallet_address": address, "chain_id": CHAIN_ID, "audience": audience}
    status, nonce = http_json("POST", f"{broker}/api/shared/siwa/wallet/nonce", json_body(base))
    if status != 200 or not isinstance(nonce, dict) or nonce.get("code") != "nonce_issued":
        raise SiwaError(f"nonce request failed ({status}): {json.dumps(nonce)}")
    challenge = nonce["data"]
    signature = sign_text(key, challenge["message"])
    proof = {**base, "nonce": challenge["nonce"], "message": challenge["message"], "signature": signature}
    status, verified = http_json("POST", f"{broker}/api/shared/siwa/wallet/verify", json_body(proof))
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
    return "sha-256=:" + base64.b64encode(hashlib.sha256(body).digest()).decode("ascii") + ":"


def signed_headers(key: dict, receipt: dict, method: str, url: str, body: bytes | None) -> dict:
    """Build the SIWA signed-request headers for one request. Each call signs fresh."""
    parsed = urllib.parse.urlsplit(url)
    path = parsed.path or "/"
    if parsed.query:
        path += "?" + parsed.query
    created = int(time.time())
    expires = created + REQUEST_SIGNATURE_LIFETIME_SECONDS
    nonce = "sig-nonce-" + secrets.token_hex(16)
    headers = {
        "x-siwa-receipt": receipt["receipt"],
        "x-key-id": receipt["key_id"],
        "x-timestamp": str(created),
        "x-agent-wallet-address": key["address"],
        "x-agent-chain-id": str(CHAIN_ID),
    }
    components = ["@method", "@path", "x-siwa-receipt", "x-key-id", "x-timestamp", "x-agent-wallet-address", "x-agent-chain-id"]
    if body is not None:
        headers["content-digest"] = content_digest(body)
        components.append("content-digest")
    params = (
        "(" + " ".join(f'"{component}"' for component in components) + ")"
        f";created={created};expires={expires};nonce=\"{nonce}\";keyid=\"{receipt['key_id']}\""
    )
    lines = []
    for component in components:
        if component == "@method":
            value = method.lower()
        elif component == "@path":
            value = path
        else:
            value = headers[component]
        lines.append(f'"{component}": {value}')
    lines.append(f'"@signature-params": {params}')
    signature = sign_text(key, "\n".join(lines))
    headers["signature-input"] = "sig1=" + params
    headers["signature"] = "sig1=:" + base64.b64encode(bytes.fromhex(signature[2:])).decode("ascii") + ":"
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
    save_json(config["key_path"], {"address": account.address.lower(), "private_key": "0x" + account.key.hex().removeprefix("0x")})
    print(json.dumps({"address": account.address.lower(), "key": config["key_path"], "created": True}))


def command_use_wallet(config: dict, args: argparse.Namespace) -> None:
    if not ADDRESS_PATTERN.match(args.address):
        raise SiwaError(f"{args.address} is not an Ethereum address")
    existing = load_json(config["key_path"])
    if existing and not args.force:
        raise SiwaError(f"{config['key_path']} already holds {existing['address']}; add --force to replace it")
    save_json(config["key_path"], {"address": args.address.lower(), "signer": args.signer})
    print(json.dumps({"address": args.address.lower(), "key": config["key_path"], "signer": args.signer}))


def command_whoami(config: dict, _args: argparse.Namespace) -> None:
    key = require_key(config)
    receipts_dir = os.path.join(config["home"], "receipts")
    signed_in = []
    if os.path.isdir(receipts_dir):
        for name in sorted(os.listdir(receipts_dir)):
            receipt = load_receipt(config, key, name.removesuffix(".json"))
            if receipt_is_fresh(receipt):
                signed_in.append({"site": receipt["audience"], "until": receipt["receipt_expires_at"]})
    print(json.dumps({
        "address": key["address"],
        "signs_with": "this client's key" if "private_key" in key else key["signer"],
        "broker": config["broker"],
        "signed_in": signed_in,
    }, indent=2))


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


def main(argv: list[str]) -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)

    keygen = commands.add_parser("keygen", help="make a key this client keeps (no-op when a key exists)")
    keygen.add_argument("--force", action="store_true", help="replace the existing key; the old identity is lost")
    keygen.set_defaults(run=command_keygen)

    use_wallet = commands.add_parser("use-wallet", help="sign with your own wallet tool instead of a key kept here")
    use_wallet.add_argument("address", help="the wallet's Ethereum address")
    use_wallet.add_argument("--signer", required=True, help="shell command that signs $SIWA_MESSAGE (also on stdin) as an Ethereum personal message and prints the 0x signature")
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
    except urllib.error.URLError as error:
        print(json.dumps({"error": f"could not reach the server: {error.reason}"}), file=sys.stderr)
        sys.exit(3)


if __name__ == "__main__":
    main(sys.argv[1:])
