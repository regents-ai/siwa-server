import Config

# Behind Fly's proxy, which ends https. Fly's health check asks as localhost over
# plain http, which is answered instead of redirected.
config :siwa_demo, SiwaDemoWeb.Endpoint,
  force_ssl: [rewrite_on: [:x_forwarded_proto], exclude: [hosts: ["localhost", "127.0.0.1"]]]

config :logger, level: :info
