import Config

# An empty variable counts as unset.
env = fn name ->
  case String.trim(System.get_env(name, "")) do
    "" -> nil
    value -> value
  end
end

required = fn name, what ->
  env.(name) || raise "Set #{name} to #{what}; see .env.example."
end

if System.get_env("PHX_SERVER") do
  config :siwa_demo, SiwaDemoWeb.Endpoint, server: true
end

config :siwa_demo,
  siwa_server_key: required.("SIWA_SERVER_KEY", "this site's server key from its Sites page"),
  siwa_handle: required.("SIWA_HANDLE", "this site's handle from its Sites page"),
  siwa_service: env.("SIWA_SERVICE") || "https://siwa.regents.sh",
  site_token: env.("SIWA_SITE_TOKEN")

config :siwa_demo, SiwaDemoWeb.Endpoint, http: [port: String.to_integer(env.("PORT") || "4000")]

if config_env() == :prod do
  config :siwa_demo, SiwaDemoWeb.Endpoint,
    url: [host: required.("PHX_HOST", "this site's public host name"), port: 443, scheme: "https"],
    http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}]
end
