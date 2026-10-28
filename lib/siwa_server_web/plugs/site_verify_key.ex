defmodule SiwaServerWeb.Plugs.SiteVerifyKey do
  @moduledoc """
  Admits a request to http-verify only when it presents a Regent site's own
  verify key (`SiwaServer.SiteVerifiers`) as `Authorization: Bearer <key>`, and
  assigns that site as `:site_audience`, the one audience the request is checked
  for. It runs before the rate limit, so a caller without a key never spends a
  site's request budget. Every decision is counted under the site, or
  "refused".
  """

  @behaviour Plug

  import Plug.Conn

  require Logger

  alias SiwaServer.{RuntimeConfig, SiteVerifiers}
  alias SiwaServerWeb.FallbackController

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    with [presented] <- get_req_header(conn, "authorization"),
         {:ok, audience} <- SiteVerifiers.site(RuntimeConfig.siwa_site_verifiers(), presented) do
      counted(audience)
      assign(conn, :site_audience, audience)
    else
      _refused ->
        counted("refused")

        Logger.info(
          "http verify mode=siwa_request audience=none wallet=none decision=refused code=site_verify_unauthorized"
        )

        conn
        |> FallbackController.call(
          {:error, {401, "site_verify_unauthorized", "a site verify key is required"}}
        )
        |> halt()
    end
  end

  defp counted(site),
    do: :telemetry.execute([:siwa_server, :siwa, :http_verify, :site], %{}, %{site: site})
end
