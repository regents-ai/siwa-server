defmodule SiwaServerWeb.Plugs.SiteVerifyKey do
  @moduledoc """
  Admits a request to http-verify only when it presents a Regent site's own
  verify key (`SiwaServer.SiteVerifiers`) as `Authorization: Bearer <key>`, and
  assigns that site as `:site_audience`, the one audience the request is checked
  for. It runs before the rate limit, which counts each agent's requests under
  that site. A refusal spends the caller's own budget of refusals
  (`:siwa_site_key_refused`, per address); once that is spent, it answers 429.
  Each refusal within the budget writes a log line; past it, one warning per
  caller and window says the budget ran out, and the rest write no line of
  their own (the endpoint's request log still records every request). Every
  decision is counted under the site, or "refused".
  """

  @behaviour Plug

  import Plug.Conn

  require Logger

  alias SiwaServer.{RuntimeConfig, SiteVerifiers}
  alias SiwaServerWeb.FallbackController
  alias SiwaServerWeb.Plugs.RateLimit

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
        conn |> RateLimit.call(name: :siwa_site_key_refused) |> refuse()
    end
  end

  defp refuse(%Plug.Conn{halted: true} = limited) do
    if RateLimit.allow?(limited, :siwa_site_key_refused_noted) do
      Logger.warning(
        "http verify mode=siwa_request audience=none wallet=none decision=rate_limited code=site_verify_unauthorized: a caller used up its refusals for this minute; the rest are not logged"
      )
    end

    limited
  end

  defp refuse(conn) do
    Logger.info(
      "http verify mode=siwa_request audience=none wallet=none decision=refused code=site_verify_unauthorized"
    )

    conn
    |> FallbackController.call(
      {:error, {401, "site_verify_unauthorized", "a site verify key is required"}}
    )
    |> halt()
  end

  defp counted(site),
    do: :telemetry.execute([:siwa_server, :siwa, :http_verify, :site], %{}, %{site: site})
end
