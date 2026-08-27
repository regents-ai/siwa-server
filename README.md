# siwa-server

[![License: MIT](https://img.shields.io/badge/license-MIT-lightgrey)](LICENSE)
[![Elixir 1.19.5](https://img.shields.io/badge/elixir-1.19.5-lightgrey)](https://elixir-lang.org)
[![Phoenix 1.8](https://img.shields.io/badge/phoenix-1.8-lightgrey)](https://www.phoenixframework.org)
[![PostgreSQL](https://img.shields.io/badge/postgres-required-lightgrey)](https://www.postgresql.org)

`siwa-server` is the shared Sign-In With Anything service for the Regent apps, run by
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
- health, metrics, and the served shared services contract
- strict receipt, request-expiry, and replay checks for shared agent sign-in

It does not own product-specific app logic or Regent account registration. The platform calls
this service over HTTP rather than serving shared SIWA itself, and owns Regent staking routes
and client generation. Techtree proof and Fold policy stay in Techtree. SIWA only proves
request identity and audience when a product route needs a signed agent request.

The shared services HTTP contract is owned by `regents-cli`, at
`docs/regent-services-contract.openapiv3.yaml` in that repository. The served copy at
`priv/static/regent-services-contract.openapiv3.yaml` here is a generated artifact and must
match it.

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
| `/api/shared/siwa/nonce` | POST | Issue a nonce for a sign-in attempt. |
| `/api/shared/siwa/verify` | POST | Verify a sign-in. |
| `/api/shared/siwa/http-verify` | POST | Verify a signed HTTP request. |
| `/healthz` | GET | Liveness. |
| `/readyz` | GET | Readiness. |
| `/metrics` | GET | Prometheus scrape endpoint. |
| `/regent-services-contract.openapiv3.yaml` | GET | The served shared services contract. |

The current Agent account shape is mandatory across these routes: wallet, chain, registry
address, token ID, audience, nonce, and the request body when a protected request has one.
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
