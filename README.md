# siwa-server

[![License: MIT](https://img.shields.io/badge/license-MIT-lightgrey)](LICENSE)
[![Elixir 1.19.5](https://img.shields.io/badge/elixir-1.19.5-lightgrey)](https://elixir-lang.org)
[![Phoenix 1.8](https://img.shields.io/badge/phoenix-1.8-lightgrey)](https://www.phoenixframework.org)
[![PostgreSQL](https://img.shields.io/badge/postgres-required-lightgrey)](https://www.postgresql.org)

`siwa-server` is the shared Sign-In With Agent service for the Regent apps, run by
Regents Labs on Fly.io. It answers one kind of question — is this request really from this
agent, for this audience, and has it been seen before — and nothing else.

> [!IMPORTANT]
> This service holds signing keys. It runs an encrypted key store on a mounted volume and
> exposes internal signer routes. Treat every deployment and every secret here as
> security-critical.

It owns:

- public SIWA sign-in routes under `/api/shared/siwa`
- protected request verification
- internal keyring routes under `/api/shared/keyring` for signer operations
- health and the served shared services contract, with metrics on a private port
- strict receipt, request-expiry, and replay checks for shared agent sign-in

It does not own product-specific app logic or Regent account registration. The platform calls
this service over HTTP rather than serving shared SIWA itself, and owns Regent staking routes
and client generation. Techtree proof and Fold policy stay in Techtree. SIWA only proves
request identity and audience when a product route needs a signed agent request.

This repository owns the shared services HTTP contract, at
`priv/static/regent-services-contract.openapiv3.yaml`. `mix siwa_server.contract_check` checks
it against this server's routes and the `siwa_keyring` router.

## Quickstart

You need Elixir and a local PostgreSQL.

```bash
mix setup
mix test
mix phx.server
```

`mix setup` fetches dependencies, then creates, migrates, and seeds the database.

> [!NOTE]
> Sign-in state lives in this service's own PostgreSQL database: nonces, receipts, and replay
> records, nothing else. It holds no product data. What leaves the machine in production: the
> configured Base RPC endpoint, for on-chain checks.

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
| `/api/shared/siwa/http-verify` | POST | Verify a signed HTTP request. |
| `/api/shared/siwa/agent/register-step` | POST | Build the optional agent registry listing transaction. |
| `/api/shared/siwa/agent/registered` | POST | Read that transaction and keep the listing once it lands. |
| `/api/shared/siwa/agent-book/challenge` | POST | Read the person World's AgentBook names behind a wallet and issue the message accepting them. |
| `/api/shared/siwa/agent-book/accept` | POST | Keep that person once the wallet has signed the message. |
| `/agent-profiles/{profile_id}` | GET | A listed agent's public registration file. |
| `/healthz` | GET | Liveness. |
| `/readyz` | GET | Readiness. |
| `/regent-services-contract.openapiv3.yaml` | GET | The served shared services contract. |

Sign-in has one path: the agent's wallet. A signed request binds the wallet, chain,
audience and the request body when it has one.
Protected request verification also expects the signed path to include the query string when
one is present, and callers must send the app audience that owns the request.

Malformed expiry values, expired requests, receipt-binding mismatches, and replayed requests
must fail closed. The SIWA library and the service tests cover these cases.

## Internal signer routes

| Route | Method | Purpose |
| --- | --- | --- |
| `/api/shared/keyring/health` | GET | Keyring liveness. |
| `/api/shared/keyring/create-wallet` | POST | Create a wallet in the key store. |
| `/api/shared/keyring/has-wallet` | POST | Ask whether a wallet exists. |
| `/api/shared/keyring/get-address` | POST | Read a wallet address. |
| `/api/shared/keyring/sign-message` | POST | Sign a message. |
| `/api/shared/keyring/sign-raw-message` | POST | Sign raw bytes. |
| `/api/shared/keyring/sign-transaction` | POST | Sign a transaction. |
| `/api/shared/keyring/sign-authorization` | POST | Sign an authorization. |

> [!WARNING]
> These routes produce real signatures from real keys. They are internal by design. Do not
> expose them beyond the private network, and do not point them at a key store you would not
> want used.

## Required configuration

| Variable | Required | What it is for |
| --- | --- | --- |
| `DATABASE_URL` | Yes in production | PostgreSQL connection string for the sign-in state. |
| `SECRET_KEY_BASE` | Yes in production | Endpoint signing secret. |
| `PHX_HOST` | Yes in production | Public hostname the endpoint builds URLs from. |
| `SIWA_RECEIPT_SECRET` | Yes in production | Secret that binds and validates receipts. |
| `KEYSTORE_PASSWORD` | Yes in production | Password for the encrypted key store. |
| `KEYRING_PROXY_SECRET` | Yes in production | Shared secret guarding the internal keyring routes. |
| `BASE_RPC_URL` | Yes in production | Base mainnet JSON-RPC endpoint. |
| `ETHEREUM_RPC_URL` | Yes in production | Ethereum mainnet JSON-RPC endpoint, for smart wallets that sign in on Ethereum. |
| `WORLD_RPC_URL` | Yes in production | World Chain JSON-RPC endpoint, for reading World's AgentBook. |

## Optional configuration

| Variable | Default | What it is for |
| --- | --- | --- |
| `PHX_SERVER` | unset | `true` starts the HTTP server in a release. |
| `PORT` | `4000` | HTTP port. The Fly deployment uses `8080`. |
| `POOL_SIZE` | `10` | Database connection pool size. |
| `ECTO_IPV6` | unset | `true` connects to PostgreSQL over IPv6. |
| `DNS_CLUSTER_QUERY` | unset | DNS query used for clustering. |
| `SIWA_NONCE_TTL_SECONDS` | `300` | How long an issued nonce stays valid. |
| `SIWA_RECEIPT_TTL_SECONDS` | `3600` | How long a receipt stays valid. |
| `SIWA_HTTP_SIGNATURE_TOLERANCE_SECONDS` | `300` | Clock skew allowed on a signed HTTP request. |
| `SIWA_WALLET_ORIGINS` | unset | Approved `audience=origin` pairs for wallet sign-in, comma separated. Unset disables it. |
| `SIWA_CLEANUP_ENABLED` | `true` | Whether expired nonce and replay rows are swept. |
| `SIWA_CLEANUP_INTERVAL_MS` | `60000` | How often that sweep runs. |
| `SIWA_CLEANUP_BATCH_SIZE` | `1000` | Rows removed per sweep. |
| `KEYSTORE_BACKEND` | `encrypted_file` | Key store backend. `encrypted_file` is the only accepted value; anything else stops the boot. |
| `KEYSTORE_PATH` | `/data/siwa-server-keystore.bin` | Where the encrypted key store lives. |

> [!WARNING]
> `SIWA_RECEIPT_SECRET`, `KEYSTORE_PASSWORD`, and `KEYRING_PROXY_SECRET` are the three values
> that keep this service honest. Supply them from the deployment's secret store. Never commit
> one, and never write one into a checked-in example file.

## Checks

One command must pass before a change is proposed:

```bash
mix precommit
```

It compiles with warnings as errors, checks unused dependency locks and formatting, runs
Sobelow, verifies the served services contract and the release packaging, holds the
compile-connected `xref` graph at zero, and runs the test suite with warnings as errors. It
needs a local PostgreSQL, because the test alias creates and migrates a database first.

## Deployment

> [!WARNING]
> `fly.toml` deploys this as the Fly.io app `siwa-server`. Its release command runs database
> migrations on every deploy, it keeps one machine running, and it mounts `/data` for the
> encrypted key store — so a deploy touches both the live sign-in database and the volume the
> signing keys live on. Confirm the target before running one.

The launch and maintenance checklist is in `docs/regent-local-and-fly-launch-testing.md`.

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
`patchbay=https://patchbay.help,keyfleet=https://keyfleet.example`. Leaving it empty
disables this flow for every audience. Callers never choose an origin; only this table
does. The server binds the origin, audience, address, chain and expiry in the
challenge. An origin change invalidates outstanding challenges. Rate limits use the
existing nonce/verification buckets. This option does not grant product permissions.

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

Wallet receipts have type `siwa_wallet_receipt` and proof `wallet_signature`.
HTTP verification returns an explicit `principal` of kind `wallet` and
`agentRegistration`: the wallet's newest listing in the agent registry made through
this server, or null. Sites link to `agentRegistration.registryUrl` when it is set.
It also returns `agentBook`: `{humanId, agentCount}` when the wallet accepted the World
ID-verified person World's AgentBook named behind it, or null (see below).
Product consumers check product ownership themselves. Payment and human accounts
remain separate. Both nonce consumption and request replay use database-clock
expiration checks; invalid proof cannot consume a valid challenge.

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
routes refuse a wallet that has accepted already (`409 agent_book_already_accepted`).
`agentCount` is how many agent wallets, this one included, accepted the same person;
sites list a person's other agents on their own pages by `humanId`. Sites decide when
to show `humanId`; the same person's agents share it. Sign-in never reads World Chain.

For an isolated checkout, set `REGENT_ELIXIR_UTILS_ROOT` to a frozen `elixir-utils`
export. `REGENT_RELEASE_CONTEXT` identifies the matching Docker input directory
containing `elixir-utils/`; the packaging check validates actual dependency paths
against that context. A passing packaging check is not a built or deployed image.
