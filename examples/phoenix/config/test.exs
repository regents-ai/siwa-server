import Config

config :siwa_demo, SiwaDemoWeb.Endpoint, server: false

config :siwa_demo,
  siwa_client: SiwaDemo.StubClient,
  siwa_service: "http://127.0.0.1:1",
  siwa_server_key: "test-server-key",
  siwa_handle: "demo",
  site_token: nil

config :logger, level: :warning
