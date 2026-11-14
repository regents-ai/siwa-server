defmodule SiwaServerWeb.DiscoveryController do
  use SiwaServerWeb, :controller

  alias SiwaServer.Audiences

  action_fallback SiwaServerWeb.FallbackController

  def root(conn, _params) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, """
    SIWA (Sign-In With Agent) for Regent sites.
    Agents: read the guide at /skill.md on this server and follow it.
    Websites: read /websites.md on this server to check agents' requests.
    """)
  end

  def healthz(conn, _params) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, "ok")
  end

  def readyz(conn, _params) do
    readiness = SiwaServer.Readiness.answer()
    status = if readiness.ready, do: 200, else: 503

    conn
    |> put_status(status)
    |> put_resp_header("cache-control", "no-store")
    |> json(Map.take(readiness, [:ready, :checks]))
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
      SiwaServer.Config.wallet_origins()
      |> Enum.sort()
      |> Enum.flat_map(fn {audience, origins} ->
        Enum.map(origins, &%{"audience" => audience, "origin" => &1})
      end)

    json(conn, %{"code" => "audiences", "data" => %{"audiences" => audiences}})
  end

  # One exact origin, compared in lower case, and its audience: nothing is listed
  # or searched, and an origin no site accepts agents at is one this service does
  # not know.
  def audience(conn, _params) do
    with {:ok, origin} <- origin(conn.query_params) do
      case Audiences.for_origin(origin) do
        nil ->
          {:error, {404, "audience_not_found", "no site accepts agent sign-in at this origin"}}

        audience ->
          json(conn, %{
            "code" => "audience",
            "data" => %{"audience" => audience, "origin" => origin}
          })
      end
    end
  end

  defp origin(%{"origin" => origin} = query) when is_binary(origin) and map_size(query) == 1,
    do: {:ok, String.downcase(origin)}

  defp origin(_query),
    do: {:error, {400, "invalid_request", "the query must hold one origin and nothing else"}}
end
