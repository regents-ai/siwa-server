defmodule SiwaServerWeb.AgentSiwaController do
  @moduledoc """
  Verifies an agent's signed request for the Regent site that received it.

  `SiwaServerWeb.Plugs.SiteVerifyKey` has already admitted the site by its own
  verify key and assigned the one audience the request is checked for: nothing
  in the request can name another. Every check is logged with the request id,
  the authentication mode, audience, verified wallet, decision and refusal code
  only, never the receipt, signature, headers or body digest.
  """

  use SiwaServerWeb, :controller

  require Logger

  alias SiwaServer.Siwa.HttpVerifier
  alias SiwaServerWeb.{AgentSiwaRequest, FallbackController}

  def http_verify(%{assigns: %{site_audience: audience}} = conn, params) do
    with {:ok, request} <- AgentSiwaRequest.cast_http_verify(params),
         {:ok, payload} <-
           request
           |> AgentSiwaRequest.to_params()
           |> HttpVerifier.verify(audience: audience) do
      decided(audience, payload["data"]["walletAddress"], "verified", "none")
      json(conn, payload)
    else
      {:error, {_status, code, _message}} = refusal ->
        decided(audience, "none", "refused", code)
        FallbackController.call(conn, refusal)
    end
  end

  defp decided(audience, wallet, decision, code) do
    Logger.info(
      "http verify mode=siwa_request audience=#{audience} wallet=#{wallet} decision=#{decision} code=#{code}"
    )
  end
end
