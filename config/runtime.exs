import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/siwa_server start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :siwa_server, SiwaServerWeb.Endpoint, server: true
end

current_siwa = Application.get_env(:siwa_server, :siwa, [])
current_keyring = Application.get_all_env(:siwa_keyring)

env_integer = fn name, default ->
  case System.get_env(name) do
    value when is_binary(value) and value != "" -> String.to_integer(value)
    _ -> default
  end
end

env_value = fn name, default ->
  case System.get_env(name) do
    value when is_binary(value) and value != "" -> value
    _ -> default
  end
end

port = String.to_integer(System.get_env("PORT", "4000"))

config :siwa_server, SiwaServerWeb.Endpoint, http: [port: port]

config :siwa_server, :siwa,
  nonce_ttl_seconds:
    env_integer.("SIWA_NONCE_TTL_SECONDS", Keyword.get(current_siwa, :nonce_ttl_seconds, 300)),
  receipt_ttl_seconds:
    env_integer.(
      "SIWA_RECEIPT_TTL_SECONDS",
      Keyword.get(current_siwa, :receipt_ttl_seconds, 3_600)
    ),
  receipt_secret: env_value.("SIWA_RECEIPT_SECRET", Keyword.get(current_siwa, :receipt_secret))

config :siwa_keyring,
  backend:
    env_value.("KEYSTORE_BACKEND", Keyword.get(current_keyring, :backend, "encrypted_file")),
  password: env_value.("KEYSTORE_PASSWORD", Keyword.get(current_keyring, :password, "change-me")),
  path:
    env_value.(
      "KEYSTORE_PATH",
      Keyword.get(current_keyring, :path, "/data/siwa-server-keystore.bin")
    ),
  secret:
    env_value.(
      "KEYRING_PROXY_SECRET",
      Keyword.get(current_keyring, :secret, "siwa-dev-keyring-secret")
    )

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :siwa_server, SiwaServer.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :siwa_server, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :siwa_server, SiwaServerWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base
end
