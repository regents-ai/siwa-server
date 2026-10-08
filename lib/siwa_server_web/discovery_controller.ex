defmodule SiwaServerWeb.DiscoveryController do
  use SiwaServerWeb, :controller

  def root(conn, _params) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, """
    SIWA (Sign-In With Agent) for Regent sites.
    Agents: read the guide at /skill.md on this server and follow it.
    """)
  end

  def healthz(conn, _params) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, "ok")
  end

  def readyz(conn, _params) do
    readiness = SiwaServer.Readiness.check()
    status = if readiness.ready, do: 200, else: 503

    conn
    |> put_status(status)
    |> put_resp_header("cache-control", "no-store")
    |> json(readiness)
  end

  # The path is a fixed application asset; nothing from the request reaches File.read!.
  # sobelow_skip ["Traversal.FileModule"]
  def services_contract(conn, _params) do
    path =
      Application.app_dir(:siwa_server, "priv/static/regent-services-contract.openapiv3.yaml")

    conn
    |> put_resp_content_type("application/yaml")
    |> send_resp(200, File.read!(path))
  end

  def audiences(conn, _params) do
    audiences =
      SiwaServer.RuntimeConfig.siwa_wallet_origins()
      |> Enum.sort()
      |> Enum.map(fn {audience, origin} -> %{"audience" => audience, "origin" => origin} end)

    json(conn, %{"code" => "audiences", "data" => %{"audiences" => audiences}})
  end
end
