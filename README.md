# siwa-server

`siwa-server` is the shared SIWA service that runs on Fly.io for Regent apps.

It owns:

- public SIWA sign-in routes
- protected request verification
- internal keyring routes for signer operations
- health, metrics, and the served shared services contract

It does not own product-specific app logic. Platform now calls this service over HTTP instead of serving shared SIWA locally. Platform owns Regent staking routes and client generation.

For the full local and Fly launch checklist across SIWA Server, shared services, Platform, Autolaunch, and Regents CLI, use:

- `/Users/sean/Documents/regent/docs/regent-local-and-fly-launch-testing.md`

For the repo-local mirror, use:

- `/Users/sean/Documents/regent/siwa-server/docs/regent-local-and-fly-launch-testing.md`

## Routes

Public routes:

- `POST /v1/agent/siwa/nonce`
- `POST /v1/agent/siwa/verify`
- `POST /v1/agent/siwa/http-verify`
- `GET /healthz`
- `GET /readyz`
- `GET /metrics`
- `GET /regent-services-contract.openapiv3.yaml`

The current Agent account shape is mandatory across these routes: wallet, chain,
registry address, token ID, audience, nonce, and the request body when a protected
request has one. Protected request verification also expects the signed path to
include the query string when a query string is present, and callers must send
the app audience that owns the request.

Internal signer routes:

- `GET /internal/keyring/health`
- `POST /internal/keyring/create-wallet`
- `POST /internal/keyring/has-wallet`
- `POST /internal/keyring/get-address`
- `POST /internal/keyring/sign-message`
- `POST /internal/keyring/sign-raw-message`
- `POST /internal/keyring/sign-transaction`
- `POST /internal/keyring/sign-authorization`

## Local Setup

Run:

```sh
mix setup
mix test
mix phx.server
```

## Required Environment

Production requires:

- `DATABASE_URL`
- `SECRET_KEY_BASE`
- `PHX_HOST`
- `SIWA_RECEIPT_SECRET`
- `KEYSTORE_PASSWORD`
- `KEYRING_PROXY_SECRET`
- `BASE_RPC_URL` for Base mainnet

Optional:

- `PHX_SERVER`
- `PORT`
- `DNS_CLUSTER_QUERY`
- `POOL_SIZE`
- `SIWA_NONCE_TTL_SECONDS`
- `SIWA_RECEIPT_TTL_SECONDS`
- `SIWA_HTTP_SIGNATURE_TOLERANCE_SECONDS`
- `SIWA_CLEANUP_ENABLED`
- `SIWA_CLEANUP_INTERVAL_MS`
- `SIWA_CLEANUP_BATCH_SIZE`
- `KEYSTORE_BACKEND`
- `KEYSTORE_PATH`
- `ECTO_IPV6`

## Fly.io

`fly.toml` keeps one machine running, mounts `/data` for the encrypted key store, and runs database migrations before each deploy.
