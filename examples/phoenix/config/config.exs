import Config

config :siwa_demo, SiwaDemoWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [json: SiwaDemoWeb.ErrorJSON], layout: false]

# The module that asks the SIWA service to check each signed request. Tests swap it.
config :siwa_demo, :siwa_client, SiwaDemo.SiwaClient

config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
