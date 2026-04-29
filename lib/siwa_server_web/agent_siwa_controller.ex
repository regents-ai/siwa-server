defmodule SiwaServerWeb.AgentSiwaController do
  use SiwaServerWeb, :controller

  alias SiwaServer.Siwa
  alias SiwaServerWeb.AgentSiwaRequest

  action_fallback SiwaServerWeb.FallbackController

  def nonce(conn, params) do
    with {:ok, request} <- AgentSiwaRequest.cast_nonce(params),
         {:ok, payload} <- request |> AgentSiwaRequest.to_params() |> Siwa.issue_nonce() do
      json(conn, payload)
    end
  end

  def verify(conn, params) do
    with {:ok, request} <- AgentSiwaRequest.cast_verify(params),
         {:ok, payload} <- request |> AgentSiwaRequest.to_params() |> Siwa.verify_session() do
      json(conn, payload)
    end
  end

  def http_verify(conn, params) do
    with {:ok, audience} <- required_header(conn, "x-siwa-audience"),
         {:ok, request} <- AgentSiwaRequest.cast_http_verify(params),
         {:ok, payload} <-
           request
           |> AgentSiwaRequest.to_params()
           |> Siwa.verify_http_request(audience: audience) do
      json(conn, payload)
    end
  end

  defp required_header(conn, name) do
    conn
    |> get_req_header(name)
    |> List.first()
    |> case do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> audience_required_error()
          audience -> {:ok, audience}
        end

      _ ->
        audience_required_error()
    end
  end

  defp audience_required_error,
    do: {:error, {401, "receipt_audience_required", "request audience is required"}}
end
