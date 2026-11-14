# siwa-server

[![License: MIT](https://img.shields.io/badge/license-MIT-lightgrey)](LICENSE)
[![Elixir 1.20.4](https://img.shields.io/badge/elixir-1.20.4-lightgrey)](https://elixir-lang.org)
[![Phoenix 1.8](https://img.shields.io/badge/phoenix-1.8-lightgrey)](https://www.phoenixframework.org)
[![PostgreSQL](https://img.shields.io/badge/postgres-required-lightgrey)](https://www.postgresql.org)

`siwa-server` is the shared Sign-In With Agent service for the Regent apps, run by
Regents Labs on Fly.io. It answers one kind of question — is this request really from this
agent, for this audience, and has it been seen before — and nothing else.

> [!IMPORTANT]
> This service holds signing keys: each hosted connection's key, encrypted, in the sign-in
> database. Treat every deployment and every secret here as security-critical.

It owns:

- public SIWA sign-in routes under `/api/shared/siwa`
- protected request verification
- health and the served shared services contract, with metrics on a private port
- strict receipt, request-expiry, and replay checks for shared agent sign-in

It does not own product-specific app logic or Regent account registration. The platform calls
this service over HTTP rather than serving shared SIWA itself, and owns Regent staking routes
and client generation. Techtree proof and Fold policy stay in Techtree. SIWA only proves
request identity and audience when a product route needs a signed agent request.

This repository owns the shared services HTTP contract, at
`priv/static/regent-services-contract.openapiv3.yaml`. `mix siwa_server.contract_check` checks
it against this server's routes.

## Quickstart

You need the toolchain in `.tool-versions` (Erlang 29.1.2, Elixir 1.20.4, Node 26.12.0: the
Elixir and OTP the Dockerfile builds with; `mise` or `asdf` reads it) and a local
PostgreSQL 17. Copy `.env.example` to `.env.local` for local settings, then run `direnv allow`.

```bash
mix setup
make check
mix phx.server
```

`mix setup` fetches dependencies, then creates, migrates, and seeds the database.

> [!NOTE]
> Sign-in state lives in this service's own PostgreSQL database: nonces, receipts, and replay
> records (a hash of each used request, never its path). The [control API](#control-api)
> adds its customers, their sites, a hash of each site key, never the key, and each
> customer's billing periods with the agents counted in them (chain and address). It holds no
> other product data. What leaves the machine in production: the configured Base RPC endpoint, for on-chain
> checks.

## Where this sits

```text
  client surfaces
    ios                               mobile app, wallet, action signing
    regents-cli                       operator control surface
    regents-techtree-hermes-plugin    Hermes mission-control tab
                    │
                    ▼
  platform
    ash-platform                      Phoenix, LiveView, Ash: web, API, product domains
                    │
                    ▼
  services and chain
    siwa-server                       agent request signing, nonce and replay state   ◀ this repository
    media-web                         hosted card images and video
    fly-sentinel                      operator health checks
    regent-contracts                  canonical Solidity, ABIs, deployment records
    autolaunch-contracts              frozen Autolaunch V1 Solidity

  shared libraries and standalone tools
    elixir-utils                      SIWA, ENS, XMTP, cache, Credo checks
    design-system                     tokens and regent_ui components
    python-cli                        offline Techtree skill-tree inspection
    videocontrol                      video project and timeline workflows
```

## Public routes

| Route | Method | Purpose |
| --- | --- | --- |
| `/` | GET | Service root. |
| `/api/shared/siwa/wallet/nonce` | POST | Issue a wallet sign-in challenge. |
| `/api/shared/siwa/wallet/verify` | POST | Verify a wallet sign-in. |
| `/api/shared/siwa/http-verify` | POST | Verify a signed HTTP request: a customer's site with its server key, a Regent site with its audience. |
| `/api/shared/siwa/agent/register-step` | POST | Build the optional agent registry listing transaction. |
| `/api/shared/siwa/agent/registered` | POST | Read that transaction and keep the listing once it lands. |
| `/api/shared/siwa/agent/link-challenge` | POST | Check the registry names the wallet behind a listing made with another tool, and issue the message linking it. |
| `/api/shared/siwa/agent/link` | POST | Link that listing once the wallet has signed the message. |
| `/api/shared/siwa/agent-book/challenge` | POST | Read the person World's AgentBook names behind a wallet and issue the message accepting them. |
| `/api/shared/siwa/agent-book/accept` | POST | Keep that person once the wallet has signed the message. |
| `/agent-profiles/{profile_id}` | GET | A listed agent's public registration file. |
| `/healthz` | GET | Liveness. |
| `/readyz` | GET | Readiness, checked at most once every 30 seconds; requests in between get the last answer. It says which checks failed; the reasons go to the log. `hosted_keys` opens one stored hosted connection key with `KEYSTORE_PASSWORD`, and fails when it does not open. |
| `/regent-services-contract.openapiv3.yaml` | GET | The served shared services contract. |
| `/api/control/v1/...` | GET, POST, PATCH, DELETE | The control API, for Regent sites acting for a signed-in person. See [Control API](#control-api). |

Sign-in has one path: the agent's wallet. A signed request binds the wallet, chain,
audience and the request body when it has one. A site checking a request sends
`body_digest`, the content-digest of the body it read, and never the body itself.
Protected request verification also expects the signed path to include the query string when
one is present. A customer's site asks with its server key; a Regent site named in
`SIWA_WALLET_ORIGINS` may still ask with only its audience in `x-siwa-audience`.

Malformed expiry values, expired requests, receipt-binding mismatches, and replayed requests
must fail closed. The SIWA library and the service tests cover these cases.

**Server keys.** A customer's site (see [Control API](#control-api)) sends its server key
as the bearer:

```http
POST /api/shared/siwa/http-verify
Authorization: Bearer siwa_sk_live_...
content-type: application/json

{"method":"POST","path":"/v1/notes","authority":"acme.example","headers":{...},"body_digest":"sha-256=:...:"}
```

The key names the site, so `x-siwa-audience` may be left out; when it is sent it must be
the site's audience. A sandbox site always takes agents. A production site takes them only
once its `originProof` is `verified`. An archived site, or a revoked key, takes none. A
key that does not name a usable site is refused before the agent's request is looked at,
so the request is not used up and works afterwards with the right key. A customer's
site's audience sent without its key is refused.

A production site's request is used up and its agent counted in one database
transaction: the agent is counted once per customer in the customer's current billing
period, whichever of its production sites saw it first. While the period has a cap, a new
agent the cap has no room for is refused and the request is not used up; an agent already
counted this period always passes. A sandbox site's request is only used up, and counts
nothing. The answer adds the agent's `subject` (`eip155:<chain id>:<lowercase address>`)
and, for a production site, `usage`:

```json
{"subject":"eip155:8453:0xabc...","usage":{"activeThisPeriod":true,"newThisPeriod":true}}
```

An internal customer's billing period is the current UTC calendar month, opened by its
first counted agent. A paid customer's periods are opened for it; until one is running,
its production sites answer `402 billing_required`.

| Status | Code | When |
| --- | --- | --- |
| 401 | `site_key_invalid` | The key is unknown or revoked, or its site is archived. |
| 401 | `site_audience_mismatch` | `x-siwa-audience` is not the key's site's audience. |
| 401 | `site_key_required` | A customer's site's audience was sent without its key. |
| 402 | `billing_required` | The production site's customer has no billing period running now. The request is not used up. |
| 402 | `agent_cap_reached` | The period's cap has no room for another new agent. The request is not used up. |
| 403 | `site_not_verified` | The production site's origins are not proven yet. |

Wallet sign-in, agent registration and AgentBook steps are limited per wallet address
the caller names, and every computer also has one ceiling across all of them (300 a
minute), so naming new addresses buys no more requests. `http-verify` is limited per
agent (600 a minute): its caller is a site's server, speaking for all of that site's agents,
so one computer's ceiling there is 3,000 a minute.

## Control API

The paid sign-in product's customers manage their account here: a customer, its cap and
usage, the agents counted this billing period, its sites, and each site's server keys.
Regent sites (the template first, then regents.sh, Patchbay and Chainagent) call it from
their own server for the person signed in to them with Privy. A site's server key is what
the site sends to `http-verify` (see [Server keys](#public-routes)); a usable site's
audience is also one agents sign in for, from the site's own origins.

It is off until `PRIVY_APP_ID` and `PRIVY_VERIFICATION_KEY` are both set: every route then
answers `503 control_not_configured`, and the rest of the service runs as before.

**Signing in.** The site trades the person's Privy sign-in for a control token, which lasts
15 minutes and names only the person's Privy DID. Every other route takes that token as the
bearer, and reaches only that person's customer. A site, key or customer that is not theirs
answers exactly as one that does not exist. Exchanges are limited to 600 a minute per
calling computer, which is the site's server for all its people: about 450 people signed in
to one site at once.

```http
POST /api/control/v1/session
Authorization: Bearer <Privy access token>
privy-id-token: <Privy identity token>

200 {"code":"control_session","data":{"token":"SFMyNTY...","expiresAt":"2026-11-14T07:11:57Z","did":"did:privy:cmabc123"}}
```

Both Privy tokens must be current, for this server's Privy app, from the same sign-in.

**Rules.** A person has at most one customer. A site's `audience` is what its agents sign
in for: 1 to 64 lowercase letters, digits, `-` or `_`, starting with a letter or digit,
never one used by any other site (archived ones too) or listed in `SIWA_WALLET_ORIGINS`. A
`sandbox` site lists only `http://localhost:<port>` origins and needs no proof it owns them;
a `production` site lists only `https://` origins with a lowercase host and nothing after
it, and its `originProof` is `unverified` when made and again whenever its origins change.
A site lists 1 to 10 origins, none twice. Names are 1 to 100 characters. A site's audience
and environment never change. Archiving a site keeps it, hides it, keeps its audience taken,
and stops its keys. A server key (`siwa_sk_test_...` for sandbox, `siwa_sk_live_...` for
production) is shown once, when made; the server keeps only its SHA-256 hash and its first
19 characters. A site has at most 5 keys that are not revoked. A body may hold only the
fields its route names, and a query only the parameters its route names.

**Price and cap.** A billing period's fee is 99 dollars for up to 1,000 agents, then 9.9
cents for each agent after, worked out in tenths of a cent so it stays exact: `feeCents` is
a string with one decimal place, such as `"9900.0"`. `capCents` is the most the customer
pays in one period, or null for no cap; it is at least `9900` and is set on the customer and
its current period together, and never below the fee that period has already reached.
`maxAgents` is the most agents the cap pays for (`1000 + (capCents × 10 − 99000) ÷ 99`,
rounded down). A new period takes the customer's cap when it opens.

| Agents | Fee (cents) | Cap (cents) | Most agents |
| --- | --- | --- | --- |
| 0 to 1,000 | 9900.0 | 9900 | 1,000 |
| 1,001 | 9909.9 | 10000 | 1,010 |
| 2,000 | 19800.0 | 19800 | 2,000 |
| 10,000 | 99000.0 | 99000 | 10,000 |

| Route | Body | Success |
| --- | --- | --- |
| `POST /session` | none (headers above) | `200 control_session` |
| `GET /account` | none | `200 account`, with `usage` this period or null |
| `POST /customer` | `name` | `201 customer_created` |
| `PATCH /customer` | `name` | `200 customer_updated` |
| `PUT /cap` | `capCents`, a whole number of cents or null | `200 cap_updated`, the customer and `usage` |
| `GET /agents?after=&limit=` | none | `200 agents`, this period's agents newest first, `limit` 1 to 200 (50 when left out), and `next` for `after` |
| `GET /sites` | none | `200 sites`, oldest first |
| `GET /sites/{id}` | none | `200 site` |
| `POST /sites` | `name`, `audience`, `environment`, `origins` | `201 site_created` |
| `PATCH /sites/{id}` | `name` and/or `origins` | `200 site_updated` |
| `DELETE /sites/{id}` | none | `200 site_archived` |
| `GET /sites/{id}/keys` | none | `200 site_keys`, newest first, revoked ones too |
| `POST /sites/{id}/keys` | none | `201 site_key_created`, the only answer holding `key` |
| `DELETE /sites/{id}/keys/{key_id}` | none | `200 site_key_revoked`; again changes nothing |

Every path is under `/api/control/v1`. Examples, each with `Authorization: Bearer <control token>`:

```http
GET /api/control/v1/account
200 {"code":"account","data":{"did":"did:privy:cmabc123","customer":null,"usage":null}}

POST /api/control/v1/customer   {"name":"Acme"}
201 {"code":"customer_created","data":{"id":"551352af-783e-4b8e-b409-24b8555683d7","name":"Acme","kind":"paid","capCents":null,"createdAt":"2026-11-14T06:56:57Z","updatedAt":"2026-11-14T06:56:57Z"}}

PATCH /api/control/v1/customer   {"name":"Acme Labs"}
200 {"code":"customer_updated","data":{"id":"551352af-...","name":"Acme Labs","kind":"paid","capCents":null,"createdAt":"...","updatedAt":"..."}}

PUT /api/control/v1/cap   {"capCents":10000}
200 {"code":"cap_updated","data":{"customer":{"id":"551352af-...","capCents":10000, ...},"usage":{"periodStartsAt":"2026-11-01T00:00:00Z","periodEndsAt":"2026-12-01T00:00:00Z","activeAgents":2,"includedAgents":1000,"feeCents":"9900.0","capCents":10000,"maxAgents":1010}}}

GET /api/control/v1/agents?limit=2
200 {"code":"agents","data":{"agents":[{"subject":"eip155:8453:0x5f...","firstVerifiedAt":"2026-11-14T06:58:02.114071Z","firstSiteId":"204cdfd8-..."},{"subject":"eip155:8453:0x1c...","firstVerifiedAt":"2026-11-14T06:57:40.552310Z","firstSiteId":"204cdfd8-..."}],"next":"MTc2MzEwMzQ2MDU1MjMxMC4..."}}

POST /api/control/v1/sites   {"name":"Acme","audience":"acme","environment":"production","origins":["https://acme.example"]}
201 {"code":"site_created","data":{"id":"204cdfd8-3ba2-44f5-b235-268addb0e013","name":"Acme","audience":"acme","environment":"production","origins":["https://acme.example"],"originProof":"unverified","archivedAt":null,"createdAt":"2026-11-14T06:56:57Z","updatedAt":"2026-11-14T06:56:57Z"}}

GET /api/control/v1/sites
200 {"code":"sites","data":{"sites":[{"id":"204cdfd8-...","name":"Acme","audience":"acme", ...}]}}

GET /api/control/v1/sites/204cdfd8-3ba2-44f5-b235-268addb0e013
200 {"code":"site","data":{"id":"204cdfd8-...", ...}}

PATCH /api/control/v1/sites/204cdfd8-...   {"name":"Acme Web","origins":["https://www.acme.example"]}
200 {"code":"site_updated","data":{"id":"204cdfd8-...","name":"Acme Web","origins":["https://www.acme.example"],"originProof":"unverified", ...}}

DELETE /api/control/v1/sites/204cdfd8-...
200 {"code":"site_archived","data":{"id":"204cdfd8-...","archivedAt":"2026-11-14T06:56:57Z", ...}}

POST /api/control/v1/sites/204cdfd8-.../keys
201 {"code":"site_key_created","data":{"id":"f5abb4c6-284c-4708-86e4-2476f6d1e890","prefix":"siwa_sk_live_QssKxd","key":"siwa_sk_live_QssKxd...","createdAt":"2026-11-14T06:56:57Z","revokedAt":null}}

GET /api/control/v1/sites/204cdfd8-.../keys
200 {"code":"site_keys","data":{"keys":[{"id":"f5abb4c6-...","prefix":"siwa_sk_live_QssKxd","createdAt":"2026-11-14T06:56:57Z","revokedAt":null}]}}

DELETE /api/control/v1/sites/204cdfd8-.../keys/f5abb4c6-...
200 {"code":"site_key_revoked","data":{"id":"f5abb4c6-...","prefix":"siwa_sk_live_QssKxd","createdAt":"2026-11-14T06:56:57Z","revokedAt":"2026-11-14T06:56:57Z"}}
```

A refusal is `{"error":{"code","message","hint"}}`; a field refusal adds `fields`, each
field's reasons:

```http
422 {"error":{"code":"control_fields_invalid","message":"some fields are not valid","hint":"...","fields":{"audience":["has already been taken"]}}}
```

| Status | Code | When |
| --- | --- | --- |
| 400 | `control_request_invalid` | The body holds a field the route does not take, such as `audience` on `PATCH /sites/{id}`, or the query a parameter it does not take. |
| 401 | `privy_proof_invalid` | `POST /session`: the Privy tokens are missing, expired, for another app, from two sign-ins, or not signed by Privy. |
| 401 | `control_token_invalid` | The control token is missing, not valid or older than 15 minutes. |
| 404 | `customer_not_found` | The person has no customer yet (`PATCH /customer`, `PUT /cap`, `GET /agents` and every site route). |
| 404 | `site_not_found` | No site with that id among the person's sites that are not archived. |
| 404 | `site_key_not_found` | No key with that id on that site. |
| 409 | `customer_exists` | `POST /customer` when the person already has one. |
| 409 | `site_key_limit` | The site already has 5 keys that are not revoked. |
| 422 | `control_fields_invalid` | A field broke its rule; `fields` says which and why. On `PUT /cap`, a cap below 9900 or below the fee this period has already reached; on `GET /agents`, a `limit` outside 1 to 200 or an `after` this list did not give. |
| 429 | `rate_limited` | `POST /session` more than 600 times a minute from one computer; `retry-after` says when to try again. |
| 503 | `control_not_configured` | The Privy settings are not set on this server. |

## Required configuration

| Variable | Required | What it is for |
| --- | --- | --- |
| `DATABASE_URL` | Yes in production | PostgreSQL connection string for the sign-in state. |
| `SECRET_KEY_BASE` | Yes in production | Endpoint signing secret. |
| `PHX_HOST` | Yes in production | Public hostname the endpoint builds URLs from. |
| `SIWA_RECEIPT_SECRET` | Yes in production | Secret that binds and validates receipts. |
| `KEYSTORE_PASSWORD` | Yes in production | Password the hosted connections' keys are encrypted with. |
| `BASE_RPC_URL` | Yes in production | Base mainnet JSON-RPC endpoint. |
| `ETHEREUM_RPC_URL` | Yes in production | Ethereum mainnet JSON-RPC endpoint, for smart wallets that sign in on Ethereum. |
| `WORLD_RPC_URL` | Yes in production | World Chain JSON-RPC endpoint, for reading World's AgentBook. |

## Optional configuration

| Variable | Default | What it is for |
| --- | --- | --- |
| `PHX_SERVER` | unset | `true` starts the HTTP server in a release. |
| `PORT` | `4000` | HTTP port. The Fly deployment uses `8080`. |
| `ECTO_IPV6` | unset | `true` connects to PostgreSQL over IPv6. |
| `DNS_CLUSTER_QUERY` | unset | DNS query used for clustering. |
| `SIWA_NONCE_TTL_SECONDS` | `300` | How long an issued nonce stays valid. |
| `SIWA_RECEIPT_TTL_SECONDS` | `3600` | How long a receipt stays valid. |
| `SIWA_HTTP_SIGNATURE_TOLERANCE_SECONDS` | `300` | Clock skew allowed on a signed HTTP request, and the longest one may last. At least `120`, the contract's signing lifetime. |
| `SIWA_HOSTED_SIGNERS` | unset | Each site's own key for hosted signing (Patchbay's ChatGPT app, Keyfleet's, the template's and Chainagent's Claude connectors), as `site=key` pairs. Unset lets no site sign. |
| `SIWA_WALLET_ORIGINS` | unset | Approved `audience=origin` pairs for wallet sign-in, comma separated; an audience may repeat with more origins. Unset disables it. |
| `SIWA_CLEANUP_BATCH_SIZE` | `1000` | Expired nonce, replay and activity rows removed per batch. A sweep runs once a minute and repeats batches until one comes back short, at most 20 for each kind. |
| `PRIVY_APP_ID` | unset | The Privy app whose signed-in people may use the [control API](#control-api). Unset turns the control API off. |
| `PRIVY_VERIFICATION_KEY` | unset | That Privy app's ES256 verification **public** key, not its app secret: the PEM with real line breaks, for example `fly secrets set PRIVY_VERIFICATION_KEY="$(cat privy-verification-key.pem)"`. Unset turns the control API off. |

> [!WARNING]
> `SIWA_RECEIPT_SECRET` and `KEYSTORE_PASSWORD` are the two values that keep this service
> honest. Supply them from the deployment's secret store. Never commit
> one, and never write one into a checked-in example file.

## Checks

One command must pass before a change is proposed:

```bash
make check
```

`make check` runs `mix precommit` and nothing else. It compiles with warnings as errors, checks unused dependency locks and formatting, runs
Sobelow, verifies the served services contract, holds the compile-connected `xref` graph
at zero, installs the `e2e/` libraries, runs the test suite with warnings as errors, then
runs the Touch ID page checks in headless Chromium (`e2e/`, Playwright 1.64.1, on a Mac). It
needs a local PostgreSQL, because the test alias creates and migrates a database first,
Playwright's Chromium (`npx --prefix e2e playwright install --only-shell chromium`, once),
and `uv` on the path. The first-signed-request test runs the served Python client through
`uv` (its first run downloads the client's libraries, so it needs the network or a warm uv
cache) and the Node client beside `e2e/node_modules`, so a bare `mix test` on a fresh clone
needs `npm --prefix e2e ci` first.

[verification/features.yml](verification/features.yml) lists what this service does, its risk
level and the checks that prove each part, with the gaps that have no check yet.

## Deployment

> [!WARNING]
> `fly.toml` deploys this as the Fly.io app `siwa-server`. Its release command runs database
> migrations on every deploy, and the hosted connections' signing keys live in that database —
> so a deploy touches the live sign-in database. Confirm the target before running one.

The app runs two machines on separate hosts. They share nothing but the sign-in database:
sign-in codes, used signed requests, request limits and hosted connection keys are all there,
so either machine answers any request.

Release with the one script, from a clean checkout whose commit is on `origin/main`:

```bash
scripts/deploy.sh
```

It refuses a changed working tree, a commit that is not on `origin/main`, and a commit that
does not contain every live one (the `revision` label on each running image, read with
`fly image show`).
It holds `/tmp/regent-release-siwa-server.lock` for its whole run, so a second run waits for the
first; never wrap it in `lockf` yourself.
It builds from `git archive` of the commit in a fresh release folder,
`tmp/releases/<time>-<commit>/`, and deploys it with `--remote-only` and `--ha=false`, labelling
the image with the commit (`revision`) and the elixir-utils commit `mix.exs` pins
(`elixir-utils`). Fly's logs stream into that folder from before the deploy until the checks
after it end. Every check runs even when another fails, and any failure ends with a line saying
the commit is deployed but a check failed. The checks: the app runs exactly two machines and both
images name the commit, `/readyz` answers ready with every check true, and the served
helpers (`/agent/siwa_agent.py`, `/agent/siwa-agent.mjs`, `/agent/siwa-contract.json`) and guides
(`/skill.md`, `/websites.md`) have the same sha256 as the files in git. The folder stays as the release record;
then add the release to `RELEASES.md`.

[RELEASES.md](RELEASES.md) records each release's Fly version and commit; [CHANGELOG.md](CHANGELOG.md)
says what changed for agents, people and sites.

The launch and maintenance checklist is in `docs/regent-local-and-fly-launch-testing.md`.

### Hosted connection keys: backup and restore

Each hosted connection's key is one row of `siwa_hosted_identities` in the sign-in database
(`siwa_server` on the Fly managed Postgres cluster `regent-siwa-prod`, `d1zj5omk7z3ryqkv`). The
key is encrypted with AES-256-GCM under a key made from `KEYSTORE_PASSWORD` (PBKDF2-SHA256,
100,000 rounds, a salt of its own; `SiwaKeyring.HostedIdentity` in the pinned elixir-utils), so
every machine signs with the same key and the database never holds it readable.

The keys used to be files on the volume `siwa_data` (`vol_42k97729y72yy334`). v82 (6 November
2026) copied them into this table as it started and found none: in the 30 days before, hosted
signing had one refused request and signed nothing. v83 stopped mounting the volume, and it was
deleted on 6 November 2026 (Sean "2. a").

The table is on the database's protected-tables lock (Sean "1. a", 6 November 2026), as
`shared_identity_records` is: deleting its rows or emptying it is refused, and dropping it fails.

**Backup.** The cluster's own backups hold the table: a full one each day and an incremental
one each hour. List them read-only:

```bash
fly mpg backup list d1zj5omk7z3ryqkv
```

A backup holds the keys still encrypted, so it is useless without `KEYSTORE_PASSWORD`, which is
in Fly's secrets for `siwa-server` and in no backup. Losing the password loses every hosted
signer. Whether a copy of the password is kept anywhere else is unconfirmed.

**Restore. Never rehearsed: every step below is unconfirmed.** `fly mpg restore` makes a new
cluster from a backup or a point in time; the service then points at it through
`DATABASE_URL`. `KEYSTORE_PASSWORD` must be the password in use when the backup was taken:
when it does not open the stored keys, `/readyz` answers not ready with `hosted_keys` false,
and every `register` or `sign` answers `503 hosted_key_unreadable`, so no new signer is made
under the wrong password.
`/readyz` opens one key only, so check also with a real signature: from Patchbay, ask this
server to `sign` `GET /api/agents/v1/whoami` for a connection that paired before the backup,
send the signed request to Patchbay, and check that Patchbay answers with the agent and wallet
address it already holds for that connection. A `422` sign means that connection's row is
missing; a different address means the row is not the one from the backup.

A restore loses every hosted signer made after the backup. The next registration for such a
connection makes a new signer with a new address, so that connection pairs again.

## The other repositories

| Repository | What it is | What it deliberately does not do |
| --- | --- | --- |
| `ash-platform` | The Phoenix, LiveView, and Ash application: public web pages, the HTTP API, product domains, human identity, billing, and the Techtree and Autolaunch product areas. | It does not hold Solidity source or user signing keys; wallet actions remain browser-signed. |
| `autolaunch-contracts` | A clean-room Solidity implementation of the founder-frozen Autolaunch V1 system, controlled by its own `SPEC.md`. | It authorises no deployment, signature, or value movement; the older Autolaunch code in `regent-contracts` is historical reference only. |
| `design-system` | The shared Regent visual language: the style guide, design tokens, logos, fonts, and the `regent_ui` Phoenix component library. | Shared components never own product workflow state, authorisation decisions, money movement, or product database behaviour. |
| `elixir-utils` | A collection of standalone Elixir libraries used across the family: SIWA, ENS, XMTP, a cache, agentbook helpers, and the in-house `credo_ash` lint checks. | Each package is a library only; none of them runs a service or holds product behaviour. |
| `fly-sentinel` | A small Phoenix service that reports Fly.io observability and operator preview checks. | It observes and reports; it does not deploy, scale, or change any other application. |
| `ios` | The Expo and React Native mobile app: the mobile wallet, action signing, and mobile Regent records. | It consumes the platform HTTP contracts and owns no server-side product logic. |
| `media-web` | A standalone Phoenix service that serves hosted Regents card images and video files from `media.regents.sh`. | It only serves bytes over HTTP; it holds no identity, database, or product logic. |
| `python-cli` | The installable `regents-techtree` Python package, whose shipped surface is a deterministic offline inspection of one champion/challenger skill-tree pair. | It does not evaluate or execute an agent, and it makes no network calls once its locked dependencies are installed. |
| `regent-contracts` | The canonical home for Regent Solidity source, Foundry tests, deployment scripts, verified deployment records, ABIs, and the chain-contract manifest. | It holds no HTTP or CLI contracts, Ash resources, workflow logic, UI, or projection workers. |
| `regents-cli` | The operator control surface: the `regents` command line tool, its generated bindings, and its local runtime. | It drives the platform over published contracts and owns no product database or on-chain authority. |
| `regents-techtree-hermes-plugin` | The Hermes plugin that presents Techtree mission control across Forge, Techtree Verify, and Uplift. | It is presentation only: no second task store, no private Verify database, no identity model, no payment system, and no Hermes runtime of its own. |
| `videocontrol` | A separate product: video project workflows, timeline editing, preview rendering, and Codex plugin media control. | It shares the house style but no runtime, database, or contract with the Regent platform. |

## License

MIT — see [LICENSE](LICENSE).

## Wallet authors

The optional wallet flow uses `POST /api/shared/siwa/wallet/nonce` and
`POST /api/shared/siwa/wallet/verify`. Sign the exact ERC-4361 message returned by
the nonce endpoint. Base (`8453`) is the only supported chain. No private key is sent
to this service.

Both sign-in routes, this one and agent sign-in, and every signed HTTP request after
sign-in accept smart wallets, through `Siwa.WalletSignature` in the shared SIWA library.
An ordinary wallet's signature is recovered locally. Any other signature is checked on
Base with ERC-1271 `isValidSignature`, in one `eth_call` through Multicall3; a wallet not
deployed yet sends an ERC-6492-wrapped signature, and its factory call runs first in that
same read, so nothing is deployed. A failed lookup on Base answers 502
`signature_lookup_failed` and uses up neither the challenge nor the request.

`SIWA_WALLET_ORIGINS` lists the approved audiences and the HTTPS origin each one signs
in from, as comma-separated `audience=origin` pairs, for example
`patchbay=https://patchbay.help,keyfleet=https://keyfleet.example`. An audience that
signs in from several origins repeats, one entry per origin; its first origin is the one
the challenge names, and no origin may belong to two audiences. Leaving it empty
disables this flow for every Regent audience. A customer's site is a sign-in audience
too, from the origins it lists through the [control API](#control-api): a sandbox site
always, a production site once its `originProof` is `verified`, an archived site never.
The public audience list names only the audiences in this table. Callers never choose an
origin; only this table and the customer's site do. The server binds the origin, audience, address, chain and expiry in the
challenge. An origin change invalidates outstanding challenges. Rate limits use the
existing nonce/verification buckets. This option does not grant product permissions.

Every signed request names the host it is sent to (`@authority`, from contract version
2). A site sends the host it received the request at, and the server accepts it only when
that host is one of the audience's origins here, so a request signed for one site is
refused at every other (`401 http_signature_invalid`, "signed request is for another
site"). Run anywhere but production, the table also accepts `http://localhost:<port>`, so
a site run locally can check its agents' requests against a local server.

The wallet is any secp256k1 key the agent controls. A key generated locally on the
agent's own machine, holding no funds and registered nowhere, is enough to sign in;
the address is the agent's identity for the audience. On a Mac, the clients lock the key
they make with a passkey (WebAuthn PRF, relying party `localhost`, from a page the client
serves on 127.0.0.1): the person confirms with Touch ID once after each restart, a helper
the client starts keeps the unlocked key on a socket in the user's private temporary folder
until the restart, and `show-key` prints the plain key after Touch ID. Elsewhere the key
stays in plain text in `key.json`. The agent guide is served at
https://siwa.regents.sh/skill.md and the Python client at
https://siwa.regents.sh/agent/siwa_agent.py (Node: `/agent/siwa-agent.mjs`).

The local Touch ID page uses the shared shell in
`design-system/standalone/agent-key.html`, with SIWA-owned browser behavior in
`assets/agent/passkey.js`. Its fonts, tokens and crown marks are embedded: opening
the page makes no external asset requests. Each helper serves it with a Content-Security-Policy that allows only
that page's own style and script (a new nonce each time), its embedded images and fonts, and its
answer back to the helper. The page confirms the passkey step;
only the agent's subsequent `me` request confirms account pairing. It names the agent
app that opened it ("Opened by Claude Code"; Codex, Cursor, Gemini CLI, Hermes and
OpenCode are known, anything else is "your agent"), found by each client from its
parent processes, and after Touch ID it says "You can safely close this page". What the page
shows in each step, and that finishing or failing moves nothing at any width from 300 to
1280, is checked by `e2e/touch-id-page.spec.mjs`.
Regenerate both clients and the Regents CLI page from sibling checkouts with:

```sh
python3 scripts/build_agent_page.py --design-system ../design-system --cli ../regents-cli
python3 scripts/build_agent_page.py --design-system ../design-system --cli ../regents-cli --check
```

Do not edit the generated HTML inside the clients. Existing downloaded clients
need a new download after deployment; the CLI copy ships with its next release.

Wallet receipts have type `siwa_wallet_receipt` and proof `wallet_signature`.
HTTP verification returns an explicit `principal` of kind `wallet` and
`agentRegistration`: the agent registry listing the wallet registered through this
server or linked last, while the registry still names the wallet, or null. Sites link to
`agentRegistration.registryUrl` when it is set.
A site outside Regents follows the websites guide, https://siwa.regents.sh/websites.md: how
to join, the check in curl and TypeScript, and one free trial for each verified person.
It also returns `agentBook`: `{humanId, agentCount}` when the wallet accepted the World
ID-verified person World's AgentBook named behind it, or null (see below).
Product consumers check product ownership themselves. Payment and human accounts
remain separate.

A site asks for a lease (`"lease": true`) on a request that changes nothing and
spends nothing. For a wallet that signed with its own key, the answer adds
`leaseExpiresAt`: 10 minutes from now (`:siwa, :lease_seconds`), never past the
receipt's expiry, nor, for a customer's production site, past the end of the billing
period its agent was counted in. Until then the site checks that agent's read-only requests under
the same receipt itself with the shared `siwa` library and this server sees none of
them; every request that writes or pays still comes here. A smart wallet never gets
a lease. The activity read counts, for each site and day, the verified requests and
how many of them began a lease. Both nonce consumption and request replay use database-clock
expiration checks; invalid proof cannot consume a valid challenge.

A signed HTTP request may last no longer than the signature tolerance (longer is
refused as `401 http_signature_invalid`), and its use is kept until it expires, so
http-verify never accepts it again while it lasts. The use is kept as `h1:` and the SHA-256 of
what was signed (wallet, chain, audience, nonce, method, path with its query, body digest),
never as the request's path or query. The use is on the database's disk before
http-verify answers, so a database crash never lets the same request through twice. For a
customer's production site the use is written in the same transaction that counts the
agent, after every other check, so a request refused for billing or the cap is not used up. A
restore from a backup still can: the restored database has none of the uses recorded
after its backup was taken. A request is accepted only while the time it was signed for
is within the 300 second signature tolerance of the server's clock, and that time
can be up to 300 seconds after the request was used, so 600 seconds after the old
database last answered, no request it accepted can be accepted again. Serve from a
restored database only after that wait.

The day's count of verified requests is written without waiting for the disk, so
a verification is not held up when the disk pauses. If the database crashes, the
counts written since the disk last confirmed can be lost (about 600 ms normally,
as long as a disk pause, measured up to about 7 seconds); a lost count changes no
decision, and a count that cannot be written never refuses the request. Nonces and
every other write wait for the disk.

### Optional agent registry listing

An agent may list itself in the ERC-8004 agent registry on Base,
`0x8004A169FB4a3325136EB29fA0ceB6D2e539a432`. Sign-in never depends on it.
`register-step` takes the wallet, a name, a description and an optional HTTPS image,
and returns the one transaction, `register(agentUri)`, for the wallet to send and pay
for. `agentUri` is `https://siwa.regents.sh/agent-profiles/<id>`, where the id is a
digest of the wallet and the profile, so the signed transaction is consent to exactly
that profile. Nothing is stored until `registered` reads the transaction at the latest
Base block and finds the token the registry minted to that wallet. The listing is then
kept, the registration file is served at `agentUri`, and http-verify names it. This
server never sends or funds a transaction.

An agent listed by any other tool links its listing instead, in two steps.
`link-challenge` takes the wallet, its sign-in chain and the agent's token id, and reads
the registry at the latest Base block: `getAgentWallet(tokenId)` or `ownerOf(tokenId)`
must be the wallet. It then issues a single-use, five-minute message naming the wallet
and the agent. `link` checks the wallet's signature (an ordinary wallet, or a smart
wallet on Ethereum or Base), reads the registry again and keeps the link. The signature
is the wallet's consent: anyone can send a listing to any wallet, but only the wallet
can link it. The listing's `tokenURI` is its `profileUrl` when it is an `https://` or
`ipfs://` address; a listing with no profile address, or with its profile written into
itself (`data:`), links with `profileUrl: null`. The client command is `link-agent`.

Each wallet has one link, in `agent_registry_links`. A registration through this server
sets it too, so http-verify names the listing the wallet registered or linked last.

Every five minutes the server reads the registry again for each wallet's link at the
latest Base block, on its own `chain` queue. A link whose agent the registry no longer
names as the wallet's (by `getAgentWallet` or `ownerOf`), or whose agent no longer exists,
is ended and http-verify stops naming it; it is listed again when the registry names the
wallet again. A failed read, or an answer that is not an address, leaves that link as it
was until the next run. A link is never deleted, and a registration file is still served.

### World AgentBook

A person can vouch for their agent with World ID: World's own tool,
`npx @worldcoin/agentkit-cli register <address>`, records the wallet in World's
AgentBook on World Chain, `0xA23aB2712eA7BBa896930544C7d6636a96b944dA`, under the
person's anonymous World ID number (the nullifier hash), and World pays the gas.
AgentBook takes no signature from the agent's wallet, so anyone with a World ID can
put their number on any wallet, or replace the one already there. The wallet
therefore accepts its person, once and for good: `agent-book/challenge` reads `lookupHuman(wallet)`
at the latest World Chain block through `WORLD_RPC_URL` and issues a single-use,
five-minute message naming the wallet and that number; `agent-book/accept` checks
the wallet's signature (an ordinary wallet, or a smart wallet on Ethereum or Base),
reads AgentBook again and, when it still names the same number, keeps the number in
`agent_book_acceptances`. The client command is `accept-world-id`.

A wallet's accepted person is permanent: whatever AgentBook names later, http-verify
and the activity read return `agentBook: {humanId, agentCount}` for it, and both
routes refuse a wallet that has accepted already (`409 agent_book_already_accepted`),
`agent-book/accept` before it reads World Chain or checks the signature. The database
itself refuses to change, delete or empty `agent_book_acceptances` rows. `agentCount` is how many agent wallets, this one included, accepted the same person;
sites list a person's other agents on their own pages by `humanId`. Sites decide when
to show `humanId`; the same person's agents share it. The number is not secret: anyone can
read it from AgentBook with the wallet address, so any two sites can match one person by it.
Sign-in never reads World Chain.

The shared SIWA, keyring and chain packages come from one `elixir-utils` commit pinned
in `mix.exs`, the way the template pins them. The image builds from this repository
alone and Docker fetches that exact commit, so the shared commit must be on GitHub
before a release.

Hosted connections (Patchbay's ChatGPT app, and Keyfleet's, the template's and
Chainagent's Claude connectors) use `POST /api/shared/siwa/hosted`. Each site asks with its own hosted
signing key from `SIWA_HOSTED_SIGNERS` (`site=key` pairs, like
`SIWA_ACTIVITY_READERS`); that key opens no other route, and unset lets no site sign.
Everything signed is bound to the calling site's audience, and the stored signer is
named from the site and its account key together, so one site cannot reach another
site's connections. Registration reuses an encrypted signer by account key; signing
accepts only each site's approved requests: Patchbay's `whoami`, its pairing for the
`chatgpt` harness and its free questions and replies; Keyfleet's, the template's
(`ash-template`) and Chainagent's (`chainagent`) `whoami`, `me` and their pairing for the `claude` harness. It never
exports keys or signs arbitrary messages or transactions. A body that names one key twice is refused. A site's hosted signing works
only while that site has an origin in `SIWA_WALLET_ORIGINS` (`fly.toml`), since each
hosted signer signs in like any agent. Products still verify each resulting request
through http-verify and apply their own pairing and permissions. Each connection's signer
is stored encrypted in the sign-in database (`SiwaServer.HostedRequests`), so every machine
signs with the same one. A hosted connection creates no on-chain registry listing.
