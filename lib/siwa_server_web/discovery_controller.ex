defmodule SiwaServerWeb.DiscoveryController do
  use SiwaServerWeb, :controller

  def root(conn, _params) do
    health_response(conn)
  end

  def healthz(conn, _params) do
    health_response(conn)
  end

  def readyz(conn, _params) do
    readiness = SiwaServer.Readiness.check()
    status = if readiness.ready, do: 200, else: 503

    conn
    |> put_status(status)
    |> put_resp_header("cache-control", "no-store")
    |> json(readiness)
  end

  def metrics(conn, _params) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_content_type("text/plain")
    |> send_resp(
      200,
      TelemetryMetricsPrometheus.Core.scrape(SiwaServerWeb.Telemetry.prometheus_reporter())
    )
  end

  def services_contract(conn, _params) do
    path =
      Application.app_dir(:siwa_server, "priv/static/regent-services-contract.openapiv3.yaml")

    conn
    |> put_resp_content_type("application/yaml")
    |> send_resp(200, File.read!(path))
  end

  defp health_response(conn) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, "ok")
  end
end
