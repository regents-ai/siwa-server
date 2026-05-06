# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :siwa_server,
  ecto_repos: [SiwaServer.Repo],
  generators: [timestamp_type: :utc_datetime, binary_id: true]

config :siwa,
  nonce_store: :unused,
  nonce_secret: "siwa-server-unused-nonce-secret"

config :siwa_server, :siwa,
  nonce_ttl_seconds: 300,
  receipt_ttl_seconds: 3_600,
  receipt_secret: nil

config :siwa_server, :siwa_cleanup,
  enabled: true,
  interval_ms: 60_000,
  batch_size: 1_000

# Configure the endpoint
config :siwa_server, SiwaServerWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: SiwaServerWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: SiwaServer.PubSub

config :siwa_server, SiwaServerWeb.Telemetry, prometheus_reporter: :siwa_server_prometheus

config :siwa_keyring,
  backend: "encrypted_file",
  password: "change-me",
  path: "/tmp/siwa-server-keystore.bin",
  secret: "siwa-dev-keyring-secret",
  replay_store: {SiwaServer.Siwa.ReplayStore, :consume_keyring_request}

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
