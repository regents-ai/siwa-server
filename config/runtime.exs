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
current_siwa_cleanup = Application.get_env(:siwa_server, :siwa_cleanup, [])
current_keyring = Application.get_all_env(:siwa_keyring)

env_integer = fn name, default ->
  case System.get_env(name) do
    value when is_binary(value) and value != "" ->
      case Integer.parse(value) do
        {parsed, ""} when parsed > 0 -> parsed
        _ -> raise("environment variable #{name} must be a positive integer.")
      end

    _ ->
      default
  end
end

env_value = fn name, default ->
  case System.get_env(name) do
    value when is_binary(value) and value != "" -> value
    _ -> default
  end
end

env_boolean = fn name, default ->
  case System.get_env(name) do
    "true" ->
      true

    "1" ->
      true

    "false" ->
      false

    "0" ->
      false

    nil ->
      default

    value ->
      raise("environment variable #{name} must be true, false, 1, or 0, got #{inspect(value)}.")
  end
end

required_env = fn name ->
  case System.get_env(name) do
    value when is_binary(value) ->
      trimmed = String.trim(value)
      if trimmed == "", do: raise("environment variable #{name} is missing."), else: trimmed

    _ ->
      raise("environment variable #{name} is missing.")
  end
end

prod? = config_env() == :prod
port = String.to_integer(System.get_env("PORT", "4000"))

receipt_secret =
  if prod?,
    do: required_env.("SIWA_RECEIPT_SECRET"),
    else: env_value.("SIWA_RECEIPT_SECRET", Keyword.get(current_siwa, :receipt_secret))

keystore_password =
  if prod?,
    do: required_env.("KEYSTORE_PASSWORD"),
    else: env_value.("KEYSTORE_PASSWORD", Keyword.get(current_keyring, :password, "change-me"))

keyring_proxy_secret =
  if prod?,
    do: required_env.("KEYRING_PROXY_SECRET"),
    else:
      env_value.(
        "KEYRING_PROXY_SECRET",
        Keyword.get(current_keyring, :secret, "siwa-dev-keyring-secret")
      )

if prod?, do: required_env.("BASE_RPC_URL")

keystore_backend =
  env_value.("KEYSTORE_BACKEND", Keyword.get(current_keyring, :backend, "encrypted_file"))

unless keystore_backend == "encrypted_file" do
  raise("environment variable KEYSTORE_BACKEND must be encrypted_file.")
end

config :siwa_server, SiwaServerWeb.Endpoint, http: [port: port]

config :siwa_server, :siwa,
  nonce_ttl_seconds:
    env_integer.("SIWA_NONCE_TTL_SECONDS", Keyword.get(current_siwa, :nonce_ttl_seconds, 300)),
  receipt_ttl_seconds:
    env_integer.(
      "SIWA_RECEIPT_TTL_SECONDS",
      Keyword.get(current_siwa, :receipt_ttl_seconds, 3_600)
    ),
  receipt_secret: receipt_secret

config :siwa_server, :siwa_cleanup,
  enabled:
    env_boolean.("SIWA_CLEANUP_ENABLED", Keyword.get(current_siwa_cleanup, :enabled, true)),
  interval_ms:
    env_integer.(
      "SIWA_CLEANUP_INTERVAL_MS",
      Keyword.get(current_siwa_cleanup, :interval_ms, 60_000)
    ),
  batch_size:
    env_integer.("SIWA_CLEANUP_BATCH_SIZE", Keyword.get(current_siwa_cleanup, :batch_size, 1_000))

config :siwa_keyring,
  backend: keystore_backend,
  password: keystore_password,
  path:
    env_value.(
      "KEYSTORE_PATH",
      Keyword.get(current_keyring, :path, "/data/siwa-server-keystore.bin")
    ),
  start_server: false,
  port: Keyword.get(current_keyring, :port, 3100),
  host: Keyword.get(current_keyring, :host, "127.0.0.1"),
  secret: keyring_proxy_secret,
  replay_store: Keyword.get(current_keyring, :replay_store)

if prod? do
  database_url =
    required_env.("DATABASE_URL")

  maybe_ipv6 = if env_boolean.("ECTO_IPV6", false), do: [:inet6], else: []

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
    required_env.("SECRET_KEY_BASE")

  host = required_env.("PHX_HOST")

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
