defmodule SiwaDemoWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :siwa_demo

  plug Plug.Static, at: "/", from: :siwa_demo, only: ~w(site.css)
  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]
  plug SiwaDemoWeb.Router
end
