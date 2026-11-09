# Websites

SIWA (Sign-In With Agent) lets your website know which agent sent a request. Each agent
holds one Ethereum key. Its address is the agent's lasting identity: the same on every
site, for as long as the agent keeps the key. Agents need no account or password on your
site, and they pay nothing to sign in.

For each signed request, SIWA tells your server:

- **The agent:** its wallet address.
- **A registry listing, if the agent has one:** its entry in the public ERC-8004 agent
  registry on Base, with a page you can link to.
- **A verified person, if one vouched for it:** an anonymous World ID number. All agents
  of the same person share it.

## Join

Open an issue at [github.com/regents-ai/siwa-server](https://github.com/regents-ai/siwa-server/issues)
and send:

- A short name for your site, such as `acme`: lowercase letters, digits, `-` and `_`.
- Each `https://` origin agents use, such as `https://acme.example`.

When your site is added, it is in the
[site list](https://siwa.regents.sh/api/shared/siwa/audiences). You get no key to keep
secret. Each signed request names the host it is sent to, and SIWA accepts it only for
the site that has that host.

## Agents

Agents follow [the agent guide](https://siwa.regents.sh/skill.md). When your site is
added, an agent sends a signed request to your site like this:

```bash
uv run siwa_agent.py request GET https://acme.example/api/hello
```

The client finds your site in the site list, signs in for it and signs every request.

## Check

For each request that must come from an agent, your server asks SIWA. Send:

- Your site's name, in the `x-siwa-audience` header.
- The method, the path with its query, and `authority`: the host the agent sent the
  request to, such as `acme.example`.
- The signed headers.
- When the request has a body, its digest. Never send the body itself.

```bash
curl https://siwa.regents.sh/api/shared/siwa/http-verify \
  -H "x-siwa-audience: acme" \
  -H "content-type: application/json" \
  -d '{
    "method": "GET",
    "path": "/api/hello",
    "authority": "acme.example",
    "headers": {
      "x-siwa-signature": "...",
      "x-siwa-signature-input": "...",
      "x-siwa-receipt": "...",
      "x-key-id": "...",
      "x-timestamp": "...",
      "x-agent-wallet-address": "...",
      "x-agent-chain-id": "..."
    }
  }'
```

The same check in TypeScript, for any server with the standard `Request`
(Node 18 or newer, Deno, Bun, Cloudflare Workers):

```ts
const VERIFY = "https://siwa.regents.sh/api/shared/siwa/http-verify";
const SITE = "acme";

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

export type Agent = {
  walletAddress: string;
  agentRegistration: { agentId: string; registryUrl: string; profileUrl: string | null } | null;
  agentBook: { humanId: string; agentCount: number } | null;
};

// The agent, or null when the request is not a valid signed request for this site.
export async function verifyAgent(request: Request): Promise<Agent | null> {
  const url = new URL(request.url);
  const headers: Record<string, string> = {};

  for (const name of SIGNED_HEADERS) {
    const value = request.headers.get(name);
    if (value !== null) headers[name] = value;
  }

  const check: Record<string, string | Record<string, string>> = {
    method: request.method,
    path: url.pathname + url.search,
    authority: url.host,
    headers,
  };

  const body = await request.clone().arrayBuffer();

  if (body.byteLength > 0) {
    const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", body));
    check.body_digest = `sha-256=:${btoa(String.fromCharCode(...digest))}:`;
  }

  const answer = await fetch(VERIFY, {
    method: "POST",
    headers: { "x-siwa-audience": SITE, "content-type": "application/json" },
    body: JSON.stringify(check),
  });

  if (answer.status === 200) return (await answer.json()).data;
  if ([400, 401, 409, 413, 415].includes(answer.status)) return null;
  throw new Error(`SIWA could not check the request: ${answer.status}`);
}
```

`url.host` is the host your server saw. Behind a proxy, use the public host instead.

## Answer

A `200` answer means the agent signed this exact request for your site. Its `data` has:

| Field | What it is |
| --- | --- |
| `walletAddress` | The agent's address, in lowercase. Use it as the agent's ID on your site. |
| `agentRegistration` | The agent's registry listing, or `null`. Link to `registryUrl`. `profileUrl` is the listing's own profile address, or `null`. |
| `agentBook` | The verified person, or `null`. `humanId` is the person's number; `agentCount` is how many agents accepted that person. |

Other answers:

| Answer | Meaning | Your site |
| --- | --- | --- |
| `400`, `401`, `409`, `413`, `415` | Not a valid signed request for your site, or a request seen before. | Refuse the request. |
| `429`, `500`, `502` | SIWA could not check the request now. | Ask the agent to try again later. |

Each signed request is good once, for two minutes. Never check the same request twice.

## Free trial

This example gives one free trial to each verified person, however many agents they have.

```sql
CREATE TABLE free_trials (
  human_id text PRIMARY KEY,
  wallet_address text NOT NULL,
  started_at timestamptz NOT NULL DEFAULT now()
);
```

```ts
const agent = await verifyAgent(request);

if (agent === null) return new Response("Sign-in failed", { status: 401 });

if (agent.agentBook === null) {
  return new Response("The free trial needs a verified person", { status: 403 });
}

const started = await db.query(
  `INSERT INTO free_trials (human_id, wallet_address) VALUES ($1, $2)
   ON CONFLICT (human_id) DO NOTHING`,
  [agent.agentBook.humanId, agent.walletAddress],
);

if (started.rowCount === 0) {
  return new Response("This person has used the free trial", { status: 409 });
}

return new Response("Free trial started", { status: 201 });
```

The `PRIMARY KEY` on `human_id` keeps one trial for each person, also when two of their
agents ask at the same moment.

## Know

- **The person number is public.** Anyone can read it from World's AgentBook with the
  agent's address. Use it to count people, never as a secret or a password.
- **One number for each person.** World ID gives each person one number, and an agent
  accepts its person once, for good.
- **Many agents have no person.** `agentBook` is `null` for them. Choose what your site
  gives them.
- **The listing is optional.** An agent listed by any tool can link its listing. What a
  listing says about the agent is the agent's own claim.
