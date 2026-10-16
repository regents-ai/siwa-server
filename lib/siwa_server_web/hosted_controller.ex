defmodule SiwaServerWeb.HostedController do
  @moduledoc """
  Hosted signing for sites' ChatGPT connections (`SiwaServer.HostedRequests`).
  Each site asks with its own hosted signing key, and only for itself. Every
  request is counted under the site whose key it presented, and every refused
  key under "refused".
  """

  use SiwaServerWeb, :controller

  require Logger

  alias SiwaServer.{HostedRequests, HostedSigners, RuntimeConfig}

  action_fallback SiwaServerWeb.FallbackController

  def handle(conn, params) do
    with {:ok, site} <- authorize(conn) do
      case HostedRequests.handle(site, params) do
        {:ok, answer} ->
          json(conn, answer)

        {:error, reason} ->
          Logger.warning("hosted request refused site=#{site} reason=#{inspect(reason)}")

          {:error, {422, "hosted_request_refused", "this hosted signing request is not allowed"}}
      end
    end
  end

  defp authorize(conn) do
    with [presented] <- get_req_header(conn, "authorization"),
         {:ok, site} <- HostedSigners.site(RuntimeConfig.siwa_hosted_signers(), presented) do
      counted(site)
      {:ok, site}
    else
      _refused ->
        counted("refused")
        Logger.warning("hosted request refused: no site's hosted signing key was presented")
        {:error, {401, "hosted_unauthorized", "invalid hosted signing key"}}
    end
  end

  defp counted(site),
    do: :telemetry.execute([:siwa_server, :siwa, :hosted, :request], %{}, %{site: site})
end
