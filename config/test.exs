import Config

pg_username = System.get_env("PGUSER") || System.get_env("USER") || "postgres"
pg_password = System.get_env("PGPASSWORD")
pg_hostname = System.get_env("PGHOST") || "localhost"
pg_port = String.to_integer(System.get_env("PGPORT") || "5432")

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :siwa_server, SiwaServer.Repo,
  username: pg_username,
  password: pg_password,
  hostname: pg_hostname,
  port: pg_port,
  database: "siwa_server_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :siwa_server, SiwaServerWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "3OnskX0TNNRGq/xv7Qljewzf8XgYe96C4rlmL23Z2ptW8irw1GICd4a22ir0sZW5",
  server: false

config :siwa_server, :siwa,
  nonce_ttl_seconds: 300,
  receipt_ttl_seconds: 3_600,
  receipt_secret: "siwa-server-test-receipt-secret",
  activity_readers: %{
    "regents" => "siwa-test-regents-activity-read-key-01",
    "patchbay" => "siwa-test-patchbay-activity-read-key-1"
  },
  hosted_signers: %{
    "patchbay" => "siwa-test-patchbay-hosted-signing-key-1",
    "keyfleet" => "siwa-test-keyfleet-hosted-signing-key-1",
    "ash-template" => "siwa-test-ash-template-hosted-signing-key-1",
    "chainagent" => "siwa-test-chainagent-hosted-signing-key-1"
  },
  keystore_password: "siwa-server-test-password"

config :siwa_server, Oban, testing: :manual

# Tests change the chain addresses between /readyz requests, so each one checks afresh.
config :siwa_server, :readiness_keep_ms, 0

# Each origin's site file is what a test sets under :site_files.
config :siwa_server, :site_file, SiwaServer.TestSiteFiles

# Billing is on, and every Stripe call is answered by what the test sets
# (SiwaServer.TestStripe); none leaves the computer.
config :siwa_server, :stripe,
  secret_key: "sk_test_siwa_stand_in",
  webhook_secret: "whsec_siwa_stand_in",
  price_id: "price_siwa_test",
  meter_event_name: "siwa_active_agents",
  portal_origins: ["https://regents.example"]

config :siwa_server, :stripe_http, SiwaServer.TestStripe

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
