# SIWA Server Local And Fly Launch Testing

The canonical cross-product guide is:

- `/Users/sean/Documents/regent/docs/regent-local-and-fly-launch-testing.md`

Use this mirror when you are working from `siwa-server/`.

## Local

```bash
cd /Users/sean/Documents/regent/siwa-server
direnv allow
direnv exec . mix test
direnv exec . mix precommit
direnv exec . mix release --overwrite
```

Run locally in one terminal:

```bash
direnv exec . mix phx.server
```

In another terminal:

```bash
curl -fsS http://127.0.0.1:4100/healthz
curl -fsS http://127.0.0.1:4100/regent-services-contract.openapiv3.yaml >/tmp/regent-services-contract.openapiv3.yaml
```

## Fly

```bash
export SIWA_FLY_APP=<siwa-fly-app>

fly volumes list --app "$SIWA_FLY_APP"
```

If `siwa_data` is missing, create it:

```bash
fly volumes create siwa_data --app "$SIWA_FLY_APP" --region iad --size 1
```

Set secrets from the current `direnv` environment without printing values:

```bash
direnv exec . bash -lc 'fly secrets set --app "$SIWA_FLY_APP" \
  DATABASE_URL="$DATABASE_URL" \
  SECRET_KEY_BASE="$SECRET_KEY_BASE" \
  PHX_HOST="$PHX_HOST" \
  SIWA_RECEIPT_SECRET="$SIWA_RECEIPT_SECRET" \
  BASE_RPC_URL="$BASE_RPC_URL" \
  KEYSTORE_BACKEND="$KEYSTORE_BACKEND" \
  KEYSTORE_PATH="$KEYSTORE_PATH" \
  KEYSTORE_PASSWORD="$KEYSTORE_PASSWORD" \
  KEYRING_PROXY_SECRET="$KEYRING_PROXY_SECRET" \
  SIWA_NONCE_TTL_SECONDS="$SIWA_NONCE_TTL_SECONDS" \
  SIWA_RECEIPT_TTL_SECONDS="$SIWA_RECEIPT_TTL_SECONDS" \
  SIWA_HTTP_SIGNATURE_TOLERANCE_SECONDS="$SIWA_HTTP_SIGNATURE_TOLERANCE_SECONDS" \
  SIWA_CLEANUP_ENABLED="$SIWA_CLEANUP_ENABLED" \
  SIWA_CLEANUP_INTERVAL_MS="$SIWA_CLEANUP_INTERVAL_MS" \
  SIWA_CLEANUP_BATCH_SIZE="$SIWA_CLEANUP_BATCH_SIZE" \
  ECTO_IPV6="$ECTO_IPV6"'
```

Deploy from the workspace root because the Dockerfile copies `siwa-server/` and `elixir-utils/` from there:

```bash
cd /Users/sean/Documents/regent
fly deploy --config siwa-server/fly.toml --app "$SIWA_FLY_APP"
curl -fsS "https://<siwa-host>/healthz"
curl -fsS "https://<siwa-host>/regent-services-contract.openapiv3.yaml" >/tmp/regent-services-contract.openapiv3.yaml
```

After deploy:

- Platform uses `SIWA_SERVER_BASE_URL=https://<siwa-host>`.
- Autolaunch uses `SIWA_INTERNAL_URL=https://<siwa-host>`.
- Regents CLI uses `auth.baseUrl=https://<siwa-host>`.
