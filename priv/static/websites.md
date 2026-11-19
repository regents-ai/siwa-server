# SIWA by Regents

SIWA (Sign-In With Agent) helps a service recognise the agents that come back to it. Each
agent holds one Ethereum key and signs every request it sends you. Your server asks SIWA
about each request, and SIWA answers with the agent that signed it: the same caller ID on
every visit, for as long as the agent keeps its key.

Agents need no account, password or API key on your site, and they pay nothing to sign in.
Your company pays, once a billing period, for each agent it lets in. This guide covers
everything your server does.

## Start

Open an account on the SIWA pages of a Regent site, signed in as a person or as an agent
with its own wallet. Today those pages are at
[template.regents.sh/siwa](https://template.regents.sh/siwa).

1. Name your company.
2. On **Sites**, add a site. A site has a name, an address and a **handle**: the short name
   agents sign in for, which can never change.
3. On the site's page, press **New key**. Copy the server key; it is shown once.

There are two kinds of site, and each has its own kind of key:

| Site | Address | Key | Billed |
| --- | --- | --- | --- |
| Practice | `http://localhost:<port>`, on your own computer | `siwa_sk_test_...` | Never |
| Production | `https://` and your host | `siwa_sk_live_...` | Yes |

Start with a practice site. It needs no subscription and no proof of its address.

There are two keys in SIWA, and they are never the same thing:

- **Server key.** Your company's. It tells SIWA which site is asking. Keep it on your
  server, the way you keep any secret: never in a page, an app, a repository or a message
  to an agent. A site can have five in use; revoke one on the site's page and it stops at once.
- **Agent key.** The agent's own. It never leaves the agent's computer, and you
  never see it. You see only its address.

## Practice

This runs a practice site on your computer and sends it one signed request. You need Node
20 or Python 3.11, or newer, for the site, and `uv` or Node for the agent client.

Start the example site on the port in your practice site's address, with the test key in
the `SIWA_SERVER_KEY` environment variable. Take the key from wherever you keep secrets;
here it is in a file only you can read:

```bash
curl -fsSO https://siwa.regents.sh/site/siwa-site.mjs
SIWA_SERVER_KEY="$(cat <key file>)" node siwa-site.mjs 4000
```

The same site in Python, with nothing to install:

```bash
curl -fsSO https://siwa.regents.sh/site/siwa_site.py
SIWA_SERVER_KEY="$(cat <key file>)" python3 siwa_site.py 4000
```

The port must be the one in the site's address. To use another, change the address on the
site's page first.

In another shell, make an agent and send a request, naming your site's handle:

```bash
curl -fsSO https://siwa.regents.sh/agent/siwa_agent.py
uv run siwa_agent.py keygen
uv run siwa_agent.py request GET http://localhost:4000/api/hello --handle <handle>
```

The agent client prints your site's answer:

```json
{
  "status": 200,
  "body": {
    "caller": "eip155:8453:0x25182c93fd8b2e3b490f0c4aede5f93a885ebeb8",
    "wallet": "0x25182c93fd8b2e3b490f0c4aede5f93a885ebeb8",
    "visits": 1,
    "listing": null,
    "person": null
  }
}
```

Send it again and `visits` is 2 with the same `caller`: your site knows the agent that came
back.

Two things can differ on your computer:

- **Mac.** `keygen` opens a page in the browser of the person at the computer and asks for
  Touch ID once. With nobody there, or with a wallet tool of your own, run `use-wallet` in
  place of `keygen`, as step 2 of [the agent guide](https://siwa.regents.sh/skill.md)
  shows. With Foundry:
  `uv run siwa_agent.py use-wallet <address> --signer 'cast wallet sign --keystore <file> --password-file <file> "$SIWA_MESSAGE"'`.
- **Node.** [`siwa-agent.mjs`](https://siwa.regents.sh/agent/siwa-agent.mjs) is the same
  client without `uv`: `node siwa-agent.mjs` in place of `uv run siwa_agent.py`. Run
  `npm install viem` beside it first if it is to make the key.

Each example is one short file with no dependencies, and one function in it is the whole
integration:

| Server | File | Function |
| --- | --- | --- |
| Node | [`siwa-site.mjs`](https://siwa.regents.sh/site/siwa-site.mjs) | `checkAgent(request)` |
| TypeScript | The same file, with [`siwa-site.d.mts`](https://siwa.regents.sh/site/siwa-site.d.mts) beside it for its types | `checkAgent(request)` |
| Python | [`siwa_site.py`](https://siwa.regents.sh/site/siwa_site.py) | `check_agent(method, path, host, headers, body)` |

Import the function into your server, or read it and write the same check in your own
language from the next section. `check_agent` waits for SIWA's answer, so an async Python
server runs it with `asyncio.to_thread`. A complete small site built this way runs at
[demo.regents.sh](https://demo.regents.sh), with
[its code](https://github.com/regents-ai/siwa-server/tree/main/examples/phoenix) in Elixir.

## Check

For each request that must come from an agent, your server sends one request to SIWA:

```http
POST https://siwa.regents.sh/api/shared/siwa/http-verify
Authorization: Bearer <your server key>
Content-Type: application/json

{
  "method": "POST",
  "path": "/v1/notes?draft=1",
  "authority": "acme.example",
  "headers": {
    "x-siwa-signature": "...",
    "x-siwa-signature-input": "...",
    "x-siwa-receipt": "...",
    "x-key-id": "...",
    "x-timestamp": "...",
    "x-agent-wallet-address": "...",
    "x-agent-chain-id": "...",
    "content-digest": "sha-256=:...:"
  },
  "body_digest": "sha-256=:...:"
}
```

| Field | Value |
| --- | --- |
| `method` | The request's method. |
| `path` | Its path, with the query string when it has one. |
| `authority` | The host the agent sent it to, in lowercase, with the port only when it is not the usual one: `acme.example`, `localhost:4000`. Behind a proxy, use the public host, not the one your server sees. It must be one of the site's addresses. |
| `headers` | The eight headers above, as the agent sent them. Leave out any it did not send, and send no others. |
| `body_digest` | Only when the request has a body: `sha-256=:` then the base64 SHA-256 of the exact bytes you received, then `:`. Work it out yourself; never copy the agent's `content-digest`. Never send the body. |

A request with no body, or an empty one, has no `body_digest` and no `content-digest`.

Refuse a request that carries no `x-siwa-signature` header yourself, with a `401`; there is
nothing to check. The example's code for it is `signature_required`.

## Answer

A `200` means the agent signed this exact request for your site. Its `data` holds:

| Field | Meaning |
| --- | --- |
| `subject` | The caller ID: `eip155:<chain id>:<address>`, in lowercase. Store this. |
| `walletAddress` | The agent's address, in lowercase. |
| `chainId` | The chain the agent signed in on: `8453` for Base, `1` for Ethereum. |
| `verificationMethod` | `eoa_recovery` for an ordinary key; `erc1271` or `erc6492` for a smart wallet. |
| `agentRegistration` | The agent's listing in the public ERC-8004 agent registry on Base, or `null`. It has `agentId` (the registry and the agent's number in it), `tokenId` (the number alone), `registryUrl` (a page you can link to) and `profileUrl` (the listing's own profile, or `null`). |
| `agentBook` | The person who vouched for the agent with World ID, or `null`. `humanId` is that person's anonymous number; `agentCount` is how many agents have accepted the same person. |
| `usage` | Production sites only. `newThisPeriod` is `true` on the agent's first check this billing period, the one that counts toward your bill, and `false` every time after. `activeThisPeriod` is always `true`: an agent you checked is active this period. |

Other fields describe the signature and can be ignored.

## Caller

Use `subject` as the agent's ID in your own records: the key of its account, its quota, its
history. It stays the same on every visit and on every site, because it comes from the
agent's key and nothing else.

- **Key.** One key is one caller. The agent client keeps its key in `~/.siwa-agent/key.json` (or
  the folder named in `SIWA_AGENT_HOME`) and uses it on every run, from any tool on that
  computer. An agent that loses the file, or starts in an empty folder, is a new caller
  with no history, and counts again toward your bill. If you run agents yourself, keep
  that folder between runs.
- **Chain.** The chain is part of the ID. The same address signed in on Base and on Ethereum is
  two callers. Never merge them yourself.
- **Names.** SIWA gives you no name, email or operator for an agent. Ask for those in
  your own product if you need them.

## Evidence

Each part of an answer is evidence for one thing. Treat them separately; none of them is a
badge of trust.

| Evidence | Proves | Not proven |
| --- | --- | --- |
| A `200` | The holder of that address's key signed this method, path, host and body, for your site, within the last five minutes, and SIWA has not passed this request before. | That the holder is an AI and not a person or a script. That it is honest, capable or able to pay. That it is the only key its operator holds. |
| `agentRegistration` | The registry on Base names this address as the listing's owner or agent wallet. SIWA reads the registry again every few minutes and drops a listing that no longer does. | Anything the listing says. Its name, description and picture are the agent's own claims. |
| `agentBook` | World's AgentBook names this person behind the address, and the agent signed to accept them. | Who the person is, or that they approved this request. The number is public; never use it as a secret. |

A signed request passes once. That stops a copied request from being used again; it does
not make your own action happen once. If an agent's answer is lost and it sends the same
order again, freshly signed, SIWA passes it. Guard your own writes the way you would for
any client, with a request key of your own.

## Refusals

Any answer but `200` is a refusal: `{"error": {"code": "...", "message": "...", "hint": "..."}}`.
There are two kinds, and your site treats them differently.

**Agent.** The agent's own request is at fault: a `401` or `409` whose code does not begin `site_`. Answer the
agent `401` with SIWA's `code` and `message`.

| Code | Meaning | Retry |
| --- | --- | --- |
| `http_headers_missing`, `http_signature_input_invalid`, `http_required_components_missing` | Signed headers are missing or malformed. | No. The agent needs the current client. |
| `http_signature_invalid` | The request has expired, is for another host, or was changed on the way. | Yes, signed fresh. |
| `http_body_binding_invalid` | The body is not the one the agent signed. | Yes, signed fresh. |
| `receipt_invalid`, `receipt_binding_mismatch` | The agent's sign-in has ended or is for another site. | Yes. The client signs in again by itself. |
| `signature_invalid` | The signature is not from that address. | No. |
| `request_replayed` | SIWA has passed this signed request before. | Only signed fresh, and only after the agent has read whether its first try landed. |

**Site.** Everything else: your site's account, or SIWA itself. Answer the agent `503`, pass on `retry-after` when
SIWA sent it, and write the code to your own log. Never show these to an agent: they
describe your account, and an agent must never be asked to pay your bill.

| Refusal | Meaning | Next step |
| --- | --- | --- |
| `401 site_key_invalid` | The key is unknown or revoked, or its site is archived. | Use a key in use. |
| `401 site_audience_mismatch` | Only when you send the optional `x-siwa-audience` header: it is not this key's handle. | Leave the header out. |
| `403 site_not_verified` | The production site's address is not proven. | Prove it; see Production. |
| `402 billing_required` | Your company has no subscription running. | Subscribe on **Billing**. |
| `402 agent_cap_reached` | Your cap has no room for a new agent this period. Agents already counted still pass. | Raise the cap, or wait for the next period. |
| `429 site_rate_limited`, `429 rate_limited` | Too many checks this minute; see Limits. | Wait the `retry-after` seconds. |
| `400` | Your check is malformed. | Compare it with Check. |
| `502 signature_lookup_failed` | A smart wallet could not be read on its chain just now. | The agent tries again shortly. |
| `503 verification_unavailable`, `500` | SIWA could not record the check, so it did not pass. | The agent sends the request again, signed fresh. |

Refusals on `402`, `403`, `429` and `503` leave the agent's request unused, and nothing is
counted for any refusal. Never act on a request SIWA did not answer `200` for, and never
ask SIWA about the same request twice: the second answer is `409 request_replayed`.

## Production

A production site takes agents once two things are true.

1. **Address.** The site's address is proven. Its page shows a token and a file address,
   `https://<your host>/.well-known/siwa-site.txt`. Publish a file there holding exactly
   the token and nothing else, then press **Check**. The page shows **Proven**. Changing
   the site's addresses sets it back to **Not proven**.
2. **Subscription.** Your company is subscribed, on **Billing**.

Then make a key on the production site's page (`siwa_sk_live_...`) and give your server
that key in place of the test key. Nothing else in your code changes.

Agents find a production site by its address. An agent sends
`uv run siwa_agent.py request GET https://acme.example/<path>` with no handle: its client
asks SIWA which site answers at `https://acme.example`, signs in for it, and signs the
request.

## Billing

- **Price.** $99 a month, which covers your first 1,000 agents. Each agent after that is
  $0.099. It is billed at the end of each billing period.
- **Count.** An agent counts once for your company in a billing period: on its first `200`
  from any of your production sites. Every later check of that agent that period is free,
  on all your sites. An agent is a chain and an address.
- **Free.** Never counted: practice sites, refusals, and any request SIWA could not check.
- **Blocking.** Blocking an agent later does not take it off that period's count.
- **Cap.** On **Overview** you can set the most your fees can reach in a period. Once they
  reach it, new agents are refused until the next period, and agents already counted still
  pass.
- **Record.** **Overview** lists every agent counted this period, with the site and day it
  was first seen, so each line of an invoice can be traced to an agent.

For now, subscriptions run on Stripe's test system: you subscribe with Stripe's test card
and no money is taken. This guide will say so when that changes.

## Limits

| Limit | Amount |
| --- | --- |
| Checks for one site | 6,000 a minute, across all its servers and keys |
| Checks from one server address | 3,000 a minute |
| Checks of one agent | 600 a minute |
| A signed request | Good once, until it expires: two minutes after signing with the agent clients here, and never more than five |
| An agent's sign-in | One hour; its client renews it without being asked |
| Keys in use on one site | 5 |

A check past a limit answers `429` with `retry-after`, and leaves the agent's request unused.

## Agents

Agents follow [the agent guide](https://siwa.regents.sh/skill.md). Three commands are all
an agent needs for your site:

```bash
curl -fsSO https://siwa.regents.sh/agent/siwa_agent.py
uv run siwa_agent.py keygen
uv run siwa_agent.py request POST https://acme.example/v1/notes --body '{"text":"hello"}'
```

`siwa-agent.mjs` is the same client for Node. An agent with its own wallet tool signs with
that instead of `keygen`. An agent that sends requests with its own tool runs `headers` in
place of `request` and gets the signed headers to send.

The agent guide is also an agent skill. An agent in Hermes, an open agent harness, takes it
with one command:

```bash
hermes skills install https://siwa.regents.sh/skill.md
```

In your own guide for agents, give the address, the paths and what each answers. Say that
refusals carry a `code`, and that a `503` means try again later.

## Clients

Agents reach a site in several ways. This is where each stands today, and how far it has
been tested.

| Client | Your site | Tested |
| --- | --- | --- |
| An agent with its own key, through `siwa_agent.py` or `siwa-agent.mjs` | Works. One key is the same caller through either client. | In every release, and on the live service. |
| The same agent, sending with its own HTTP tool from the client's `headers` | Works. | In every release. |
| An agent that signs with its own wallet tool (`use-wallet`) | Works. The key stays in the tool. | In every release, with a small stand-in for the wallet tool. On the live service, with Foundry's `cast`. |
| An agent in Hermes, an open agent harness, given the agent guide | Works. It was the same caller in a later run. | On the live service, once: Hermes 0.22.2, signing with its own wallet tool. |
| An agent key locked with Touch ID on a Mac | Works. | Locking and opening the key in every release, with a stand-in for the fingerprint reader. Signing with it, on Regent sites. |
| A smart wallet (ERC-1271 or ERC-6492) | SIWA checks its signature on its chain. | SIWA's own check in every release, against a stand-in for the chain. Not yet through an agent client, and not yet on the live service. |
| An app connected to a person's account on a Regent site, such as a ChatGPT or Claude connector | Not today. Regents signs for these apps on Regent sites only. | On Regent sites, on the live service. |
| A standard sign-in client, such as OAuth or the sign-in MCP describes | Not SIWA. It holds no agent key, and SIWA neither issues nor reads its tokens. Serve it with your own sign-in beside SIWA. | Not applicable. |

## Wallet

The address in an answer is an ordinary address on a public chain, so your site can read
anything public about it and decide for itself: a balance, a token, a pass. SIWA reads
none of this for you. This reads an agent's USDC on Base with [viem](https://viem.sh):

```ts
import { createPublicClient, erc20Abi, http } from "viem";
import { base } from "viem/chains";

const USDC = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913";
const chain = createPublicClient({ chain: base, transport: http() });

// USDC has six decimals: 10_000_000 units is ten dollars.
export async function holdsTenDollars(agent: { walletAddress: `0x${string}`; chainId: number }) {
  if (agent.chainId !== 8453) return false;

  const units = await chain.readContract({
    address: USDC,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: [agent.walletAddress],
  });

  return units >= 10_000_000n;
}
```

- **Timing.** Read at the moment you decide. Holdings change with every block. Store the decision
  you made, not the balance.
- **Chain.** Read the chain the agent signed in on. An ordinary key (`eoa_recovery`) controls the
  same address on every chain. A smart wallet's address on another chain can belong to
  someone else.
- **Payment.** A balance is not a payment. It shows the wallet holds the money now, not that the
  agent will send it.

## Trial

This gives one free trial to each verified person, however many agents they run.

```sql
CREATE TABLE free_trials (
  human_id text PRIMARY KEY,
  subject text NOT NULL,
  started_at timestamptz NOT NULL DEFAULT now()
);
```

```ts
const { agent, refusal } = await checkAgent(request);

if (refusal) return Response.json({ error: refusal }, { status: refusal.status });

if (agent.agentBook === null) {
  return new Response("The free trial needs a verified person", { status: 403 });
}

const started = await db.query(
  `INSERT INTO free_trials (human_id, subject) VALUES ($1, $2)
   ON CONFLICT (human_id) DO NOTHING`,
  [agent.agentBook.humanId, agent.subject],
);

if (started.rowCount === 0) {
  return new Response("This person has used the free trial", { status: 409 });
}

return new Response("Free trial started", { status: 201 });
```

The `PRIMARY KEY` on `human_id` keeps one trial for each person, also when two of their
agents ask at the same moment. Many agents have no verified person; choose what your site
gives them.

## Cards

An agent paired with a person on a Regent site can show your site a hello card: SIWA's
signed note that the site said so, good for a day. It comes in the `x-siwa-hello-card`
header beside a signed request. The signature does not cover that header, so check four
things:

1. The signed request, as above.
2. The card's signature. The card is a compact JWS whose header has `alg` `EdDSA`, `typ`
   `siwa-hello-card+jws` and a `kid`. Check it with the key that `kid` names in
   [SIWA's published keys](https://siwa.regents.sh/.well-known/jwks.json), which you may
   keep for an hour.
3. The payload has exactly `cardId`, `subject`, `name`, `person`, `pairedAt`, `pairedOn`,
   `issuedAt` and `expiresAt`, and `expiresAt` is still ahead.
4. The card's `subject` is the `subject` of the signed request. Otherwise the card is
   another agent's.

A card that passes says only that the site `pairedOn` has this agent paired with a person,
and calls the agent `name`. `person` is that person's profile code: the random id of their
Regent profile, never a name, and it says nothing else about them. Do not conclude from it:

- that the agent is paired on your site;
- that the person approved this request, or anything the agent does on your site;
- that `name` is unique or verified;
- that `person` is signed in to your site, or is anyone in particular there;
- that the agent or its person can pay;
- that the agent is honest or capable;
- anything at all once it has expired, or when the request beside it is not signed by its
  `subject`.

On your pages, say "paired with a person on <site>". Never say "trusted" or "verified", and
never greet anyone with `person`: it is a code, not a name.

## Origin

SIWA by Regents began as an Elixir port of [SIWA](https://siwa.id), the open Sign In With
Agent project by Builders Garden, published under the MIT licence (Copyright (c) 2026
Builders Garden SRL). It is now developed independently, and our thanks go to its authors.
Two differences matter to a site:

- **Listing.** Optional here: an agent signs in with a key alone, and a registry listing
  is extra evidence when it has one. The original asks every agent to register on chain
  first.
- **Hosted.** Here the check is a service your server calls with a key. The original is a
  library you run yourself.
