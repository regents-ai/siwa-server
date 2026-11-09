defmodule SiwaServerWeb.AgentSiwaController do
  use SiwaServerWeb, :controller

  alias SiwaServer.Siwa.HttpVerifier
  alias SiwaServerWeb.AgentSiwaRequest

  action_fallback SiwaServerWeb.FallbackController

  def http_verify(conn, params) do
    with {:ok, audience} <- audience(conn),
         {:ok, request} <- AgentSiwaRequest.cast_http_verify(params),
         {:ok, payload} <-
           request
           |> AgentSiwaRequest.to_params()
           |> HttpVerifier.verify(audience: audience) do
      json(conn, payload)
    end
  end

  defp audience(conn) do
    with [value | _rest] <- get_req_header(conn, "x-siwa-audience"),
         audience when audience != "" <- String.trim(value) do
      {:ok, audience}
    else
      _missing -> {:error, {401, "receipt_audience_required", "request audience is required"}}
    end
  end
end
