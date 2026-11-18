// SIWA by Regents: a site's check, in one file with no dependencies (Node 20 or newer).
//
// Run it as a practice site, with the site's test key in SIWA_SERVER_KEY:
//
//   node siwa-site.mjs 4000
//
// It answers every request at http://localhost:4000 with the agent that signed it.
// In your own server, import `checkAgent` and call it with a standard Request.
// Guide: https://siwa.regents.sh/websites.md
import { createHash } from "node:crypto";
import { createServer } from "node:http";
import { pathToFileURL } from "node:url";

const SERVICE = process.env.SIWA_BROKER ?? "https://siwa.regents.sh";

// The headers an agent signs. Only these go to SIWA; the body never does.
const SIGNED_HEADERS = [
  "x-siwa-signature",
  "x-siwa-signature-input",
  "x-siwa-receipt",
  "x-key-id",
  "x-timestamp",
  "x-agent-wallet-address",
  "x-agent-chain-id",
  "content-digest",
];

const refused = (status, code, message, retryAfter = null) => ({
  refusal: { status, code, message, retryAfter },
});

// Your site's own trouble (its key, proof, billing, cap or limits) and SIWA's. The
// agent learns only that it can try again; the reason stays in your log.
const unavailable = (retryAfter = null) =>
  refused(503, "service_unavailable", "This site cannot check agent requests right now.", retryAfter);

/**
 * Asks SIWA whether an agent signed this exact request for your site.
 *
 * Resolves to `{ agent }`, SIWA's answer about the agent, or to
 * `{ refusal: { status, code, message, retryAfter } }`, ready to send back as it is.
 * `host` is the public host agents send to, for a server behind a proxy.
 */
export async function checkAgent(request, { key = process.env.SIWA_SERVER_KEY, host } = {}) {
  if (!request.headers.has("x-siwa-signature")) {
    return refused(401, "signature_required", "This needs a signed agent request.");
  }

  const url = new URL(request.url);
  const headers = {};

  for (const name of SIGNED_HEADERS) {
    const value = request.headers.get(name);
    if (value !== null) headers[name] = value;
  }

  const check = {
    method: request.method,
    path: url.pathname + url.search,
    authority: host ?? url.host,
    headers,
  };

  const body = Buffer.from(await request.clone().arrayBuffer());

  if (body.length > 0) {
    check.body_digest = `sha-256=:${createHash("sha256").update(body).digest("base64")}:`;
  }

  let answer;

  try {
    answer = await fetch(`${SERVICE}/api/shared/siwa/http-verify`, {
      method: "POST",
      headers: { authorization: `Bearer ${key}`, "content-type": "application/json" },
      body: JSON.stringify(check),
      signal: AbortSignal.timeout(10_000),
    });
  } catch (error) {
    console.error(`SIWA could not be reached: ${error.message}`);
    return unavailable();
  }

  const said = await answer.json().catch(() => null);

  if (answer.status === 200 && said !== null) return { agent: said.data };

  const error = said?.error;

  // A 401 or 409 whose code does not begin `site_` is about the agent's own request.
  if ([401, 409].includes(answer.status) && error && !error.code.startsWith("site_")) {
    return refused(401, error.code, error.message);
  }

  console.error(`SIWA refused this site's check: ${answer.status} ${error?.code}`);
  return unavailable(answer.headers.get("retry-after"));
}

// Run directly: a practice site that answers each request with the agent that signed
// it, and how many times that agent has called since the site started.
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const port = Number(process.argv[2]);

  if (!process.env.SIWA_SERVER_KEY || !Number.isInteger(port)) {
    console.error("usage: SIWA_SERVER_KEY=<the site's test key> node siwa-site.mjs <port>");
    process.exit(2);
  }

  const visits = new Map();

  const send = (res, status, body, retryAfter = null) => {
    res.writeHead(status, {
      "content-type": "application/json",
      ...(retryAfter ? { "retry-after": retryAfter } : {}),
    });
    res.end(JSON.stringify(body));
  };

  createServer(async (req, res) => {
    const chunks = [];
    for await (const chunk of req) chunks.push(chunk);
    const body = Buffer.concat(chunks);

    let request;

    try {
      request = new Request(`http://${req.headers.host}${req.url}`, {
        method: req.method,
        headers: req.headers,
        body: body.length > 0 ? body : undefined,
      });
    } catch {
      // A GET or HEAD that carries a body, which no agent client sends.
      return send(res, 400, { error: { code: "bad_request", message: "This request cannot be read." } });
    }

    const { agent, refusal } = await checkAgent(request);

    if (refusal) {
      const { status, code, message, retryAfter } = refusal;
      return send(res, status, { error: { code, message } }, retryAfter);
    }

    // `subject` is the caller ID: the same for this agent on every visit.
    const count = (visits.get(agent.subject) ?? 0) + 1;
    visits.set(agent.subject, count);

    send(res, 200, {
      caller: agent.subject,
      wallet: agent.walletAddress,
      visits: count,
      listing: agent.agentRegistration,
      person: agent.agentBook,
    });
  }).listen(port, "localhost", () => {
    console.log(`practice site at http://localhost:${port}`);
  });
}
