#!/usr/bin/env node
// SIWA agent client: one Ethereum key for every Regent site.
//
// Guide: https://siwa.regents.sh/skill.md
//
// Pick how you sign, once:
//   npm install viem && node siwa-agent.mjs keygen       # this client makes and keeps a key (on a Mac, locked with a passkey)
//   node siwa-agent.mjs use-wallet 0xADDRESS --signer 'cast wallet sign --account agent "$SIWA_MESSAGE"'
//
// Then, for any Regent site:
//   node siwa-agent.mjs sites
//   node siwa-agent.mjs pair https://regents.sh CODE --name Astra --harness claude_code
//   node siwa-agent.mjs me https://regents.sh
//   node siwa-agent.mjs request POST https://keyfleet.ai/api/v1/agent/join/status --body '{"name":"Astra"}'
//
// Optional, once: list yourself in the agent registry on Base (your wallet pays the gas):
//   node siwa-agent.mjs register-agent --name Astra --description "What I do"
//
// Optional, once your person has vouched for you with World ID (see the guide):
//   node siwa-agent.mjs accept-world-id
//
// Environment:
//   SIWA_AGENT_HOME where the key and receipts are kept (default ~/.siwa-agent)
//   SIWA_BROKER     the SIWA server (default https://siwa.regents.sh)
//   SIWA_BASE_RPC   the Base node register-agent sends through (default https://mainnet.base.org)
//
// A private key made by keygen never leaves this machine. On a Mac it is locked
// with a passkey: your person confirms with Touch ID once after each restart, and
// `show-key` shows the plain key to copy. With use-wallet, this client never sees
// a private key at all: it hands each text to your signer.

import { execFile, execFileSync, execSync, spawn } from "node:child_process";
import { createHash, randomBytes, webcrypto } from "node:crypto";
import { existsSync, mkdirSync, readdirSync, readFileSync, renameSync, statSync, unlinkSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { createConnection, createServer as createSocketServer } from "node:net";
import { homedir } from "node:os";
import { basename, dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const CHAINS = { base: 8453, ethereum: 1 };
const DEFAULT_BROKER = "https://siwa.regents.sh";
const DEFAULT_BASE_RPC = "https://mainnet.base.org";
const REGISTRATION_WAIT_MS = 120_000;
const RECEIPT_RENEW_MARGIN_SECONDS = 60;
const REQUEST_SIGNATURE_LIFETIME_SECONDS = 120;
const SIGNER_TIMEOUT_MS = 300_000;
const PASSKEY_WAIT_MS = 300_000;
const HELPER_START_MS = 10_000;
const USER_AGENT = "siwa-agent-client/2.8 (node)";
const ADDRESS_PATTERN = /^0x[0-9a-fA-F]{40}$/;
const SIGNATURE_PATTERN = /0x[0-9a-fA-F]{130,}/g;
const BOX_INFO = "agent key box";
const PASSKEY_ASKS = {
  lock: "Ask your person to lock your new key: they press Use Touch ID on the page that just opened on this Mac.",
  unlock: "Ask your person to unlock your key: they press Use Touch ID on the page that just opened on this Mac. They are asked once after each restart.",
  show: "Ask your person to confirm with Touch ID on the page that just opened on this Mac.",
};

// The page where the person confirms with Touch ID. The passkey belongs to
// localhost, so only a page served on this Mac can use it.
const PASSKEY_PAGE = `<!doctype html>
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
`;

class SiwaError extends Error {}

class Unreachable extends Error {
  constructor(host, reason) {
    super(`could not reach ${host}: ${reason}`);
    this.hint = networkHint(host);
  }
}

// What to do when a host cannot be reached, shaped by the harness this runs in.
function networkHint(host) {
  const steps = [
    `Find out why before you retry: run \`curl -sv https://${host}/ -o /dev/null\` and show your person`,
    `the address ${host} resolves to and what happened. If curl also hangs, or its connection is closed`,
    `with no answer, your network blocks ${host}; retrying will not help. If curl gets an answer and this`,
    `client still cannot reach ${host}, your network lets curl through but not this client: show your`,
    "person both results.",
  ];
  if (process.env.CODEX_SANDBOX_NETWORK_DISABLED === "1") {
    steps.push("You run in Codex's sandbox with network access off: ask your person to allow network access for this command.");
  } else if (process.env.CLAUDECODE === "1") {
    steps.push(`Claude Code's sandbox may keep this command off the network: ask your person to allow ${host}.`);
  }
  return steps.join(" ");
}

function settings() {
  const home = process.env.SIWA_AGENT_HOME ?? join(homedir(), ".siwa-agent");
  const broker = (process.env.SIWA_BROKER ?? DEFAULT_BROKER).trim().replace(/\/+$/, "");
  const baseRpc = (process.env.SIWA_BASE_RPC ?? DEFAULT_BASE_RPC).trim();
  return { home, broker, baseRpc, keyPath: join(home, "key.json") };
}

function loadJson(path) {
  return existsSync(path) ? JSON.parse(readFileSync(path, "utf8")) : null;
}

// Write an owner-only file, then swap it in whole, so no one reads half of it.
function saveJson(path, value) {
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
  const temporary = `${path}.${randomBytes(8).toString("hex")}.tmp`;
  writeFileSync(temporary, JSON.stringify(value, null, 2), { mode: 0o600, flag: "wx" });
  renameSync(temporary, path);
}

function requireKey(config) {
  const key = loadJson(config.keyPath);
  if (!key) throw new SiwaError(`no key at ${config.keyPath}; run keygen or use-wallet first`);
  return key;
}

// The chain this key signs in on: the one use-wallet chose, else Base.
function chainId(key) {
  return key.chain_id ?? CHAINS.base;
}

function receiptPath(config, audience) {
  return join(config.home, "receipts", `${audience}.json`);
}

async function httpJson(method, url, body, headers = {}) {
  const init = { method, headers: { accept: "application/json", "user-agent": USER_AGENT, ...headers } };
  if (body !== undefined) {
    init.body = body;
    init.headers["content-type"] ??= "application/json";
  }
  const { status, text } = await fetch(url, init)
    .then(async (response) => ({ status: response.status, text: await response.text() }))
    .catch((error) => {
      throw new Unreachable(new URL(url).hostname, error.cause?.code ?? error.cause?.message ?? error.message);
    });
  let parsed;
  try {
    parsed = JSON.parse(text);
  } catch {
    parsed = text;
  }
  return { status, body: parsed };
}

function originOf(url) {
  let parsed;
  try {
    parsed = new URL(url);
  } catch {
    throw new SiwaError(`${url} is not an https address`);
  }
  if (parsed.protocol !== "https:") throw new SiwaError(`${url} is not an https address`);
  return parsed.origin;
}

async function audiences(config) {
  const result = await httpJson("GET", `${config.broker}/api/shared/siwa/audiences`);
  if (result.status !== 200 || result.body?.code !== "audiences") {
    throw new SiwaError(`could not list sites (${result.status}): ${JSON.stringify(result.body)}`);
  }
  return result.body.data.audiences;
}

async function audienceFor(config, url) {
  const origin = originOf(url);
  const listed = await audiences(config);
  const match = listed.find((entry) => entry.origin === origin);
  if (match) return match.audience;
  const known = listed.map((entry) => entry.origin).join(", ");
  throw new SiwaError(`${origin} does not accept agent sign-in; sites that do: ${known}`);
}

// The AES-GCM key a passkey's secret opens, the same in the Python and Node clients.
async function boxKey(secret) {
  const base = await webcrypto.subtle.importKey("raw", Buffer.from(secret, "hex"), "HKDF", false, ["deriveKey"]);
  return webcrypto.subtle.deriveKey(
    { name: "HKDF", hash: "SHA-256", salt: new Uint8Array(32), info: Buffer.from(BOX_INFO) },
    base,
    { name: "AES-GCM", length: 256 },
    false,
    ["encrypt", "decrypt"],
  );
}

// Open a page on this Mac where the person confirms with Touch ID; resolve to the passkey's id and secret.
function passkeySecret(mode, address, credentialId) {
  const token = randomBytes(18).toString("base64url");
  const page = PASSKEY_PAGE.replace("__SETUP__", JSON.stringify({ mode, address, credentialId }));
  return new Promise((resolve, reject) => {
    let answered = false;
    const finish = () => {
      clearTimeout(timer);
      server.close();
      server.closeAllConnections();
    };
    const server = createServer((request, response) => {
      if (request.url !== `/${token}`) return response.writeHead(404).end();
      if (request.method === "GET") {
        return response.writeHead(200, { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" }).end(page);
      }
      if (request.method !== "POST" || answered) return response.writeHead(404).end();
      let body = "";
      request.on("data", (chunk) => (body += chunk));
      request.on("end", () => {
        answered = true;
        response.writeHead(204).end(() => {
          finish();
          resolve(JSON.parse(body));
        });
      });
    });
    const timer = setTimeout(() => {
      finish();
      reject(new SiwaError(`no Touch ID within ${PASSKEY_WAIT_MS / 60_000} minutes; run the command again and ask your person to confirm on the page it opens`));
    }, PASSKEY_WAIT_MS);
    server.listen(0, "127.0.0.1", () => {
      const url = `http://localhost:${server.address().port}/${token}`;
      console.error(JSON.stringify({ touch_id: PASSKEY_ASKS[mode], page: url }));
      execFile("open", [url], () => {});
    });
  });
}

// Make a passkey for this key and seal the key with the passkey's secret.
async function lock(address, privateKey) {
  const answer = await passkeySecret("lock", address, null);
  const iv = randomBytes(12);
  const box = await webcrypto.subtle.encrypt(
    { name: "AES-GCM", iv, additionalData: Buffer.from(address) },
    await boxKey(answer.secret),
    Buffer.from(privateKey),
  );
  return { credential_id: answer.credential_id, iv: iv.toString("hex"), box: Buffer.from(box).toString("hex") };
}

async function openBox(key, mode) {
  const answer = await passkeySecret(mode, key.address, key.locked.credential_id);
  const privateKey = await webcrypto.subtle.decrypt(
    { name: "AES-GCM", iv: Buffer.from(key.locked.iv, "hex"), additionalData: Buffer.from(key.address) },
    await boxKey(answer.secret),
    Buffer.from(key.locked.box, "hex"),
  );
  return Buffer.from(privateKey).toString("utf8");
}

// Where the helper holding this unlocked key listens, shared by the Python and Node clients:
// the Mac's own private folder for this user, whatever TMPDIR a harness sets.
function helperSocket(key) {
  const folder = execFileSync("getconf", ["DARWIN_USER_TEMP_DIR"], { encoding: "utf8" }).trim();
  return join(folder, `siwa-agent-${createHash("sha256").update(key.address).digest("hex").slice(0, 16)}.sock`);
}

// One request to the helper; null when no helper is listening.
function askHelper(path, request) {
  return new Promise((resolve, reject) => {
    let reply = "";
    const connection = createConnection(path, () => connection.write(`${JSON.stringify(request)}\n`));
    connection.on("data", (chunk) => (reply += chunk));
    connection.on("end", () => {
      // A helper that is stopping can take the connection and close it unanswered.
      if (reply === "") return resolve(null);
      const answer = JSON.parse(reply);
      if (answer.error) reject(new SiwaError(answer.error));
      else resolve(answer);
    });
    connection.on("error", (error) =>
      ["ENOENT", "ECONNREFUSED", "ECONNRESET", "EPIPE"].includes(error.code) ? resolve(null) : reject(error),
    );
  });
}

// Hand the unlocked key to a helper that keeps it until this Mac restarts.
async function startHelper(key, privateKey) {
  const path = helperSocket(key);
  const helper = spawn(process.execPath, [fileURLToPath(import.meta.url), "key-helper", path], {
    detached: true,
    stdio: ["pipe", "ignore", "ignore"],
  });
  helper.stdin.end(privateKey);
  helper.unref();
  const deadline = Date.now() + HELPER_START_MS;
  while ((await askHelper(path, { op: "address" })) === null) {
    if (Date.now() > deadline) {
      throw new SiwaError(`the helper that keeps your unlocked key did not start within ${HELPER_START_MS / 1000} seconds`);
    }
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
}

// Ask the helper holding the unlocked key; unlock it with Touch ID first when none is running.
async function unlocked(key, request) {
  const answer = await askHelper(helperSocket(key), request);
  if (answer !== null) return answer;
  await startHelper(key, await openBox(key, "unlock"));
  return askHelper(helperSocket(key), request);
}

function stopHelper(key) {
  return askHelper(helperSocket(key), { op: "stop" });
}

async function signMessageWith(privateKey, text) {
  const { privateKeyToAccount } = await import("viem/accounts");
  return privateKeyToAccount(privateKey).signMessage({ message: text });
}

// Sign a Base transaction given as 0x quantities (chainId, nonce, gas, fees, value) and 0x hex (to, data).
async function signTransactionWith(privateKey, transaction) {
  const { privateKeyToAccount } = await import("viem/accounts");
  return privateKeyToAccount(privateKey).signTransaction({
    type: "eip1559",
    chainId: Number(BigInt(transaction.chainId)),
    nonce: Number(BigInt(transaction.nonce)),
    to: transaction.to,
    data: transaction.data,
    value: BigInt(transaction.value),
    gas: BigInt(transaction.gas),
    maxFeePerGas: BigInt(transaction.maxFeePerGas),
    maxPriorityFeePerGas: BigInt(transaction.maxPriorityFeePerGas),
  });
}

async function signText(key, text) {
  if (key.private_key) return signMessageWith(key.private_key, text);
  if (key.locked) return (await unlocked(key, { op: "sign_message", text })).signature;
  return runSigner(key.signer, text);
}

async function signTransaction(key, transaction) {
  if (key.locked) return (await unlocked(key, { op: "sign_transaction", transaction })).raw;
  return signTransactionWith(key.private_key, transaction);
}

// How this client signs, so the sign-in service can word its advice on a refusal.
function signerName(key) {
  return key.signer ? basename(key.signer.trim().split(/\s+/)[0]) : "own-key";
}

// Hand the exact text to the wallet's own signing command and read back its signature.
function runSigner(command, text) {
  let output;
  try {
    output = execSync(command, {
      input: text,
      env: { ...process.env, SIWA_MESSAGE: text },
      encoding: "utf8",
      timeout: SIGNER_TIMEOUT_MS,
      stdio: ["pipe", "pipe", "pipe"],
    });
  } catch (error) {
    const detail = (error.stderr || error.stdout || error.message || "").toString().trim();
    throw new SiwaError(`signer failed: ${detail}`);
  }
  const found = new Set(output.match(SIGNATURE_PATTERN) ?? []);
  if (found.size !== 1) throw new SiwaError(`signer must print exactly one 0x signature; it printed: ${output.trim()}`);
  return [...found][0];
}

function loadReceipt(config, key, audience) {
  const receipt = loadJson(receiptPath(config, audience));
  return receipt && receipt.address === key.address ? receipt : null;
}

function receiptIsFresh(receipt) {
  if (!receipt) return false;
  return (Date.parse(receipt.receipt_expires_at) - Date.now()) / 1000 > RECEIPT_RENEW_MARGIN_SECONDS;
}

// Obtain a fresh receipt for this key and site, and store it.
async function signIn(config, key, audience) {
  const base = { wallet_address: key.address, chain_id: chainId(key), audience };
  const nonce = await httpJson("POST", `${config.broker}/api/shared/siwa/wallet/nonce`, JSON.stringify(base));
  if (nonce.status !== 200 || nonce.body?.code !== "nonce_issued") {
    throw new SiwaError(`nonce request failed (${nonce.status}): ${JSON.stringify(nonce.body)}`);
  }
  const challenge = nonce.body.data;
  const signature = await signText(key, challenge.message);
  const proof = { ...base, nonce: challenge.nonce, message: challenge.message, signature };
  const verified = await httpJson("POST", `${config.broker}/api/shared/siwa/wallet/verify`, JSON.stringify(proof), {
    "x-agent-signer": signerName(key),
  });
  if (verified.status !== 200 || verified.body?.code !== "wallet_verified") {
    throw new SiwaError(`verification failed (${verified.status}): ${JSON.stringify(verified.body)}`);
  }
  const data = verified.body.data;
  const receipt = {
    address: key.address,
    audience,
    receipt: data.receipt,
    receipt_expires_at: data.receiptExpiresAt,
    key_id: data.keyId,
  };
  saveJson(receiptPath(config, audience), receipt);
  return receipt;
}

async function freshReceipt(config, key, audience) {
  const receipt = loadReceipt(config, key, audience);
  return receiptIsFresh(receipt) ? receipt : signIn(config, key, audience);
}

function contentDigest(body) {
  return `sha-256=:${createHash("sha256").update(body).digest("base64")}:`;
}

// Build the SIWA signed-request headers for one request. Each call signs fresh.
async function signedHeaders(key, receipt, method, url, body) {
  const parsed = new URL(url);
  const path = (parsed.pathname || "/") + parsed.search;
  const created = Math.floor(Date.now() / 1000);
  const expires = created + REQUEST_SIGNATURE_LIFETIME_SECONDS;
  const nonce = `sig-nonce-${randomBytes(16).toString("hex")}`;
  const headers = {
    "x-siwa-receipt": receipt.receipt,
    "x-key-id": receipt.key_id,
    "x-timestamp": String(created),
    "x-agent-wallet-address": key.address,
    "x-agent-chain-id": String(chainId(key)),
  };
  const components = ["@method", "@path", "x-siwa-receipt", "x-key-id", "x-timestamp", "x-agent-wallet-address", "x-agent-chain-id"];
  if (body !== undefined) {
    headers["content-digest"] = contentDigest(body);
    components.push("content-digest");
  }
  const params =
    `(${components.map((component) => `"${component}"`).join(" ")})` +
    `;created=${created};expires=${expires};nonce="${nonce}";keyid="${receipt.key_id}"`;
  const lines = components.map((component) => {
    const value = component === "@method" ? method.toLowerCase() : component === "@path" ? path : headers[component];
    return `"${component}": ${value}`;
  });
  lines.push(`"@signature-params": ${params}`);
  const signature = await signText(key, lines.join("\n"));
  headers["signature-input"] = `sig1=${params}`;
  headers["signature"] = `sig1=:${Buffer.from(signature.slice(2), "hex").toString("base64")}:`;
  return headers;
}

function receiptRejected(body) {
  const text = JSON.stringify(body);
  return text.includes("receipt_invalid") || text.includes("receipt_binding_mismatch");
}

async function sendSigned(config, method, url, body, extra = {}) {
  const key = requireKey(config);
  const audience = await audienceFor(config, url);
  let receipt = await freshReceipt(config, key, audience);
  let result = await httpJson(method, url, body, { ...extra, ...(await signedHeaders(key, receipt, method, url, body)) });
  if (result.status === 401 && receiptRejected(result.body)) {
    receipt = await signIn(config, key, audience);
    result = await httpJson(method, url, body, { ...extra, ...(await signedHeaders(key, receipt, method, url, body)) });
  }
  return result;
}

function printResponse(result) {
  console.log(JSON.stringify(result, null, 2));
  if (result.status >= 400) process.exitCode = 1;
}

function takeOption(args, name) {
  const index = args.indexOf(name);
  if (index === -1) return undefined;
  const [, value] = args.splice(index, 2);
  if (value === undefined) throw new SiwaError(`${name} needs a value`);
  return value;
}

function takeFlag(args, name) {
  const index = args.indexOf(name);
  if (index === -1) return false;
  args.splice(index, 1);
  return true;
}

function required(value, usage) {
  if (value === undefined) throw new SiwaError(`usage: ${usage}`);
  return value;
}

function parseRequestArgs(args) {
  const [method, url, ...rest] = args;
  if (!method || !url) throw new SiwaError("usage: <method> <url> [--body BODY] [--header NAME=VALUE]");
  let body;
  const extra = {};
  for (let index = 0; index < rest.length; index += 1) {
    if (rest[index] === "--body") body = Buffer.from(rest[++index] ?? "", "utf8");
    else if (rest[index] === "--header") {
      const [name, ...value] = (rest[++index] ?? "").split("=");
      extra[name] = value.join("=");
    } else throw new SiwaError(`unknown argument ${rest[index]}`);
  }
  return { method: method.toUpperCase(), url, body, extra };
}

async function keygen(config, args) {
  const existing = loadJson(config.keyPath);
  if (existing && !takeFlag(args, "--force")) {
    return console.log(JSON.stringify({ address: existing.address, key: config.keyPath, created: false }));
  }
  const { generatePrivateKey, privateKeyToAccount } = await import("viem/accounts");
  const privateKey = generatePrivateKey();
  const address = privateKeyToAccount(privateKey).address.toLowerCase();
  const mac = process.platform === "darwin";
  if (mac) {
    const key = { address, locked: await lock(address, privateKey) };
    saveJson(config.keyPath, key);
    await startHelper(key, privateKey);
  } else {
    saveJson(config.keyPath, { address, private_key: privateKey });
  }
  if (existing?.locked) await stopHelper(existing);
  return console.log(JSON.stringify({ address, key: config.keyPath, created: true, locked: mac }));
}

async function lockKey(config) {
  const key = requireKey(config);
  if (process.platform !== "darwin") throw new SiwaError("lock-key needs a Mac: the key is locked with a Mac passkey");
  if (!key.private_key) {
    throw new SiwaError(key.locked ? "this key is already locked" : "your wallet tool keeps this key; lock-key locks a key this client keeps");
  }
  const locked = { address: key.address, locked: await lock(key.address, key.private_key) };
  saveJson(config.keyPath, locked);
  await startHelper(locked, key.private_key);
  console.log(
    JSON.stringify(
      { address: key.address, key: config.keyPath, locked: true, note: "key.json no longer holds the plain key. Any copy made elsewhere still does." },
      null,
      2,
    ),
  );
}

async function showKey(config) {
  const key = requireKey(config);
  if (key.signer) throw new SiwaError("your wallet tool keeps this key; show it with that tool");
  const privateKey = key.locked ? await openBox(key, "show") : key.private_key;
  console.log(
    JSON.stringify(
      {
        address: key.address,
        private_key: privateKey,
        note: "Anyone with this key controls this wallet and everything in it. Give it only to your person, never to a chat, a log or a commit.",
      },
      null,
      2,
    ),
  );
}

// Keep an unlocked key in memory and sign with it for this user's clients until the Mac restarts.
async function keyHelper(args) {
  const path = required(args[0], "key-helper <socket>");
  const { privateKeyToAccount } = await import("viem/accounts");
  const privateKey = readFileSync(0, "utf8").trim();
  const address = privateKeyToAccount(privateKey).address.toLowerCase();
  if ((await askHelper(path, { op: "address" })) !== null) return;
  if (existsSync(path)) unlinkSync(path);
  const answer = async (request) => {
    switch (request.op) {
      case "address":
        return { address };
      case "sign_message":
        return { signature: await signMessageWith(privateKey, request.text) };
      case "sign_transaction":
        return { raw: await signTransactionWith(privateKey, request.transaction) };
      case "stop":
        return { stopped: true };
      default:
        return { error: `the key helper does not know ${request.op}` };
    }
  };
  const server = createSocketServer((connection) => {
    let received = "";
    connection.on("data", (chunk) => {
      received += chunk;
      if (!received.includes("\n")) return;
      answer(JSON.parse(received.slice(0, received.indexOf("\n"))))
        .catch((error) => ({ error: `the key helper could not sign: ${error.message}` }))
        .then((reply) => connection.end(`${JSON.stringify(reply)}\n`, () => reply.stopped && stop()));
    });
  });
  // Closing the server would remove whatever socket sits at the path, so the
  // helper removes only its own, in case a newer helper already listens there.
  let bound;
  const stop = () => {
    try {
      if (statSync(path).ino === bound) unlinkSync(path);
    } catch (error) {
      if (error.code !== "ENOENT") throw error;
    }
    process.exit(0);
  };
  process.umask(0o077);
  server.listen(path, () => (bound = statSync(path).ino));
}

async function useWallet(config, args) {
  const usage = "use-wallet <address> --signer <command> [--chain base|ethereum] [--force]";
  const signer = required(takeOption(args, "--signer"), usage);
  const chainName = takeOption(args, "--chain") ?? "base";
  const force = takeFlag(args, "--force");
  const address = required(args[0], usage);
  if (!ADDRESS_PATTERN.test(address)) throw new SiwaError(`${address} is not an Ethereum address`);
  if (!Object.hasOwn(CHAINS, chainName)) throw new SiwaError(`--chain must be base or ethereum, not ${chainName}`);
  const existing = loadJson(config.keyPath);
  if (existing && !force) throw new SiwaError(`${config.keyPath} already holds ${existing.address}; add --force to replace it`);
  const chain = CHAINS[chainName];
  saveJson(config.keyPath, { address: address.toLowerCase(), signer, chain_id: chain });
  if (existing?.locked) await stopHelper(existing);
  console.log(JSON.stringify({ address: address.toLowerCase(), key: config.keyPath, signer, chain_id: chain }));
}

async function whoami(config) {
  const key = requireKey(config);
  const receiptsDir = join(config.home, "receipts");
  const signedIn = existsSync(receiptsDir)
    ? readdirSync(receiptsDir)
        .sort()
        .map((name) => loadReceipt(config, key, name.replace(/\.json$/, "")))
        .filter(receiptIsFresh)
        .map((receipt) => ({ site: receipt.audience, until: receipt.receipt_expires_at }))
    : [];
  const signsWith = key.private_key
    ? { signs_with: "this client's key" }
    : key.locked
      ? {
          signs_with: "this client's key, locked with a Mac passkey",
          unlocked_until_restart: (await askHelper(helperSocket(key), { op: "address" })) !== null,
        }
      : { signs_with: key.signer };
  console.log(
    JSON.stringify(
      {
        address: key.address,
        ...signsWith,
        chain_id: chainId(key),
        broker: config.broker,
        signed_in: signedIn,
      },
      null,
      2,
    ),
  );
}

// Sign the registration with this client's key and send it on Base; the wallet pays the gas.
async function sendRegistration(config, key, step) {
  const { createPublicClient, http } = await import("viem");
  const { base } = await import("viem/chains");
  const chain = createPublicClient({ chain: base, transport: http(config.baseRpc) });
  const call = { account: step.from, to: step.to, data: step.data, value: BigInt(step.value) };
  const gas = ((await chain.estimateGas(call)) * 6n) / 5n;
  const { maxFeePerGas, maxPriorityFeePerGas } = await chain.estimateFeesPerGas();
  const balance = await chain.getBalance({ address: step.from });
  if (balance < gas * maxFeePerGas) {
    throw new SiwaError(
      `${step.from} holds ${balance} wei on Base; the registration needs up to ${gas * maxFeePerGas} wei of ETH on Base for gas. ` +
        "Ask your person to send a little ETH on Base to that address, then run this again.",
    );
  }
  const quantity = (value) => `0x${BigInt(value).toString(16)}`;
  const transaction = {
    chainId: quantity(step.chainId),
    nonce: quantity(await chain.getTransactionCount({ address: step.from, blockTag: "pending" })),
    to: step.to,
    data: step.data,
    value: step.value,
    gas: quantity(gas),
    maxFeePerGas: quantity(maxFeePerGas),
    maxPriorityFeePerGas: quantity(maxPriorityFeePerGas),
  };
  return chain.sendRawTransaction({ serializedTransaction: await signTransaction(key, transaction) });
}

async function waitForRegistration(config, profile, txHash) {
  const deadline = Date.now() + REGISTRATION_WAIT_MS;
  for (;;) {
    const result = await httpJson("POST", `${config.broker}/api/shared/siwa/agent/registered`, JSON.stringify({ ...profile, tx_hash: txHash }));
    const pending = result.status === 200 && result.body?.code === "registration_pending";
    if (!pending || Date.now() > deadline) return result;
    await new Promise((resolve) => setTimeout(resolve, 2000));
  }
}

async function registerAgent(config, args) {
  const usage = 'register-agent --name NAME --description "WHAT YOU DO" [--image HTTPS_URL] [--tx-hash HASH]';
  const name = required(takeOption(args, "--name"), usage);
  const description = required(takeOption(args, "--description"), usage);
  const image = takeOption(args, "--image");
  const txHash = takeOption(args, "--tx-hash");
  const key = requireKey(config);
  const profile = { wallet_address: key.address, name, description, ...(image ? { image } : {}) };
  if (txHash) return printResponse(await waitForRegistration(config, profile, txHash));
  const result = await httpJson("POST", `${config.broker}/api/shared/siwa/agent/register-step`, JSON.stringify(profile));
  if (result.status !== 200 || result.body?.code !== "registration_step") return printResponse(result);
  const step = result.body.data;
  if (key.signer) {
    const same = `--name ${JSON.stringify(name)} --description ${JSON.stringify(description)}${image ? ` --image ${JSON.stringify(image)}` : ""}`;
    return console.log(
      JSON.stringify(
        {
          step,
          send: `cast send ${step.to} 'register(string)' '${step.agentUri}' --rpc-url ${config.baseRpc} --account agent`,
          then: `node siwa-agent.mjs register-agent ${same} --tx-hash 0xTRANSACTION_HASH`,
          note: "Send this one transaction from your wallet on Base with your wallet tool, then report its hash with the `then` command.",
        },
        null,
        2,
      ),
    );
  }
  return printResponse(await waitForRegistration(config, profile, await sendRegistration(config, key, step)));
}

async function acceptWorldId(config, args) {
  const humanId = takeOption(args, "--human-id");
  const key = requireKey(config);
  const base = { wallet_address: key.address, chain_id: chainId(key) };
  const result = await httpJson("POST", `${config.broker}/api/shared/siwa/agent-book/challenge`, JSON.stringify(base));
  if (result.status !== 200 || result.body?.code !== "agent_book_challenge") return printResponse(result);
  const challenge = result.body.data;
  if (humanId === undefined) {
    return console.log(
      JSON.stringify(
        {
          humanId: challenge.humanId,
          note: "World's AgentBook names this person behind your address. Anyone with a World ID can put their number on any address, so ask your person to confirm they just vouched for you, then run the `then` command. Accepting is for good: you cannot accept another person later.",
          then: `node siwa-agent.mjs accept-world-id --human-id ${challenge.humanId}`,
        },
        null,
        2,
      ),
    );
  }
  if (humanId.toLowerCase() !== challenge.humanId) {
    throw new SiwaError(`World's AgentBook names ${challenge.humanId} behind your address, not ${humanId}; ask your person before accepting`);
  }
  const proof = { ...base, nonce: challenge.nonce, message: challenge.message, signature: await signText(key, challenge.message) };
  return printResponse(
    await httpJson("POST", `${config.broker}/api/shared/siwa/agent-book/accept`, JSON.stringify(proof), { "x-agent-signer": signerName(key) }),
  );
}

async function main(argv) {
  const [command, ...args] = argv;
  const config = settings();
  switch (command) {
    case "keygen":
      return keygen(config, args);
    case "lock-key":
      return lockKey(config);
    case "show-key":
      return showKey(config);
    case "key-helper":
      return keyHelper(args);
    case "use-wallet":
      return useWallet(config, args);
    case "whoami":
      return whoami(config);
    case "sites":
      return console.log(JSON.stringify(await audiences(config), null, 2));
    case "sign-in": {
      const site = required(args[0], "sign-in <site>");
      const key = requireKey(config);
      const receipt = await signIn(config, key, await audienceFor(config, site));
      return console.log(JSON.stringify({ address: key.address, site: receipt.audience, until: receipt.receipt_expires_at }));
    }
    case "pair": {
      const usage = "pair <site> <code> --name NAME --harness HARNESS";
      const name = required(takeOption(args, "--name"), usage);
      const harness = required(takeOption(args, "--harness"), usage);
      const site = required(args[0], usage);
      const code = required(args[1], usage);
      const body = Buffer.from(JSON.stringify({ code, name, harness }), "utf8");
      return printResponse(await sendSigned(config, "POST", `${originOf(site)}/api/agents/v1/pair`, body));
    }
    case "me": {
      const site = required(args[0], "me <site>");
      return printResponse(await sendSigned(config, "GET", `${originOf(site)}/api/agents/v1/me`, undefined));
    }
    case "request": {
      const request = parseRequestArgs(args);
      return printResponse(await sendSigned(config, request.method, request.url, request.body, request.extra));
    }
    case "register-agent":
      return registerAgent(config, args);
    case "accept-world-id":
      return acceptWorldId(config, args);
    case "headers": {
      const request = parseRequestArgs(args);
      const key = requireKey(config);
      const receipt = await freshReceipt(config, key, await audienceFor(config, request.url));
      return console.log(JSON.stringify(await signedHeaders(key, receipt, request.method, request.url, request.body), null, 2));
    }
    default:
      throw new SiwaError(
        "commands: keygen [--force], lock-key, show-key, use-wallet <address> --signer <command> [--chain base|ethereum], whoami, sites, sign-in <site>, pair <site> <code> --name NAME --harness HARNESS, me <site>, request <method> <url>, headers <method> <url>, register-agent --name NAME --description TEXT [--image URL] [--tx-hash HASH], accept-world-id [--human-id NUMBER]",
      );
  }
}

main(process.argv.slice(2)).catch((error) => {
  console.error(JSON.stringify(error.hint ? { error: error.message, hint: error.hint } : { error: error.message }));
  process.exitCode = error instanceof Unreachable ? 3 : 2;
});
