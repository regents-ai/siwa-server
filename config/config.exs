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

config :siwa_server, :siwa,
  nonce_ttl_seconds: 300,
  receipt_ttl_seconds: 3_600,
  lease_seconds: 600,
  http_signature_tolerance_seconds: 300,
  receipt_secret: nil,
  activity_readers: %{},
  hosted_signers: %{},
  keystore_password: nil

# The control API checks a person's Privy sign-in with these; unset turns it off.
config :siwa_server, :privy, app_id: nil, verification_key: nil

config :siwa_server, Oban,
  repo: SiwaServer.Repo,
  notifier: Oban.Notifiers.PG,
  queues: [cleanup: 1, chain: 1],
  cron: [
    crontab: [
      {"* * * * *", SiwaServer.Siwa.CleanupWorker},
      {"*/5 * * * *", SiwaServer.AgentRegistration.OwnerCheckWorker}
    ]
  ],
  pruner: [max_age: {7, :days}],
  lifeline: [rescue_after: {10, :minutes}]

config :siwa_server, :siwa_cleanup, batch_size: 1_000

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

# Rate limits key on the direct peer. Production turns on Fly's client header.
config :siwa_server, :behind_fly_proxy, false

# Metrics have a listener of their own (SiwaServerWeb.Metrics), on loopback locally.
config :siwa_server, :metrics_listener, ip: {127, 0, 0, 1}, port: 0

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Any parameter whose name holds one of these is logged as [FILTERED]: keys, their
# hashes, tokens and secrets never reach a log.
config :phoenix, :filter_parameters, ["password", "secret", "token", "key", "hash"]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
