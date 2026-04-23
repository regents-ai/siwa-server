import Config

pg_username = System.get_env("PGUSER") || System.get_env("USER") || "postgres"
pg_password = System.get_env("PGPASSWORD")
pg_hostname = System.get_env("PGHOST") || "localhost"

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :siwa_server, SiwaServer.Repo,
  username: pg_username,
  password: pg_password,
  hostname: pg_hostname,
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
  receipt_secret: "siwa-server-test-receipt-secret"

config :siwa_server, :siwa_cleanup, enabled: false, interval_ms: 60_000, batch_size: 1_000

config :siwa_keyring,
  backend: "encrypted_file",
  password: "siwa-server-test-password",
  path: Path.join(System.tmp_dir!(), "siwa-server-test-keystore.bin"),
  secret: "siwa-server-test-keyring-secret"

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
