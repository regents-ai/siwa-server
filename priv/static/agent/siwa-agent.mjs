#!/usr/bin/env node
// SIWA agent client: one Ethereum key for every Regent site.
//
// Guide: https://siwa.regents.sh/skill.md
//
// Pick how you sign, once:
//   npm install viem && node siwa-agent.mjs keygen       # this client makes and keeps a key
//   node siwa-agent.mjs use-wallet 0xADDRESS --signer 'cast wallet sign --account agent "$SIWA_MESSAGE"'
//
// Then, for any Regent site:
//   node siwa-agent.mjs sites
//   node siwa-agent.mjs pair https://regents.sh CODE --name Astra --harness claude_code
//   node siwa-agent.mjs me https://regents.sh
//   node siwa-agent.mjs request POST https://keyfleet.ai/api/v1/agent/join/status --body '{"name":"Astra"}'
//
// Environment:
//   SIWA_AGENT_HOME where the key and receipts are kept (default ~/.siwa-agent)
//   SIWA_BROKER     the SIWA server (default https://siwa.regents.sh)
//
// A private key made by keygen never leaves this machine. With use-wallet, this
// client never sees a private key at all: it hands each text to your signer.

import { execSync } from "node:child_process";
import { createHash, randomBytes } from "node:crypto";
import { existsSync, mkdirSync, readdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, join } from "node:path";

const CHAIN_ID = 8453;
const DEFAULT_BROKER = "https://siwa.regents.sh";
const RECEIPT_RENEW_MARGIN_SECONDS = 60;
const REQUEST_SIGNATURE_LIFETIME_SECONDS = 120;
const SIGNER_TIMEOUT_MS = 300_000;
const USER_AGENT = "siwa-agent-client/2.2 (node)";
const ADDRESS_PATTERN = /^0x[0-9a-fA-F]{40}$/;
const SIGNATURE_PATTERN = /0x[0-9a-fA-F]{130,}/g;

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
    `the address ${host} resolves to and what happened. An address in 198.18.x.x, or a connection`,
    `closed with no answer, means your network blocks ${host}; retrying will not help.`,
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
  return { home, broker, keyPath: join(home, "key.json") };
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

async function signText(key, text) {
  if (key.private_key) {
    const { privateKeyToAccount } = await import("viem/accounts");
    return privateKeyToAccount(key.private_key).signMessage({ message: text });
  }
  return runSigner(key.signer, text);
}

// How this client signs, so the sign-in service can word its advice on a refusal.
function signerName(key) {
  return key.private_key ? "own-key" : basename(key.signer.trim().split(/\s+/)[0]);
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
  const base = { wallet_address: key.address, chain_id: CHAIN_ID, audience };
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
    "x-agent-chain-id": String(CHAIN_ID),
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
  saveJson(config.keyPath, { address, private_key: privateKey });
  return console.log(JSON.stringify({ address, key: config.keyPath, created: true }));
}

function useWallet(config, args) {
  const signer = required(takeOption(args, "--signer"), "use-wallet <address> --signer <command> [--force]");
  const force = takeFlag(args, "--force");
  const address = required(args[0], "use-wallet <address> --signer <command> [--force]");
  if (!ADDRESS_PATTERN.test(address)) throw new SiwaError(`${address} is not an Ethereum address`);
  const existing = loadJson(config.keyPath);
  if (existing && !force) throw new SiwaError(`${config.keyPath} already holds ${existing.address}; add --force to replace it`);
  saveJson(config.keyPath, { address: address.toLowerCase(), signer });
  console.log(JSON.stringify({ address: address.toLowerCase(), key: config.keyPath, signer }));
}

function whoami(config) {
  const key = requireKey(config);
  const receiptsDir = join(config.home, "receipts");
  const signedIn = existsSync(receiptsDir)
    ? readdirSync(receiptsDir)
        .sort()
        .map((name) => loadReceipt(config, key, name.replace(/\.json$/, "")))
        .filter(receiptIsFresh)
        .map((receipt) => ({ site: receipt.audience, until: receipt.receipt_expires_at }))
    : [];
  console.log(
    JSON.stringify(
      { address: key.address, signs_with: key.private_key ? "this client's key" : key.signer, broker: config.broker, signed_in: signedIn },
      null,
      2,
    ),
  );
}

async function main(argv) {
  const [command, ...args] = argv;
  const config = settings();
  switch (command) {
    case "keygen":
      return keygen(config, args);
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
    case "headers": {
      const request = parseRequestArgs(args);
      const key = requireKey(config);
      const receipt = await freshReceipt(config, key, await audienceFor(config, request.url));
      return console.log(JSON.stringify(await signedHeaders(key, receipt, request.method, request.url, request.body), null, 2));
    }
    default:
      throw new SiwaError(
        "commands: keygen [--force], use-wallet <address> --signer <command>, whoami, sites, sign-in <site>, pair <site> <code> --name NAME --harness HARNESS, me <site>, request <method> <url>, headers <method> <url>",
      );
  }
}

main(process.argv.slice(2)).catch((error) => {
  console.error(JSON.stringify(error.hint ? { error: error.message, hint: error.hint } : { error: error.message }));
  process.exitCode = error instanceof Unreachable ? 3 : 2;
});
