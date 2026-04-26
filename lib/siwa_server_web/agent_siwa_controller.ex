defmodule SiwaServerWeb.AgentSiwaController do
  use SiwaServerWeb, :controller

  alias SiwaServer.Siwa

  def nonce(conn, params), do: render_result(conn, Siwa.issue_nonce(params))
  def verify(conn, params), do: render_result(conn, Siwa.verify_session(params))

  def http_verify(conn, params) do
    with {:ok, audience} <- required_header(conn, "x-siwa-audience") do
      render_result(
        conn,
        params
        |> Map.take(["method", "path", "headers", "body"])
        |> Siwa.verify_http_request(audience: audience)
      )
    else
      {:error, code, message} -> render_result(conn, {:error, {401, code, message}})
    end
  end

  defp render_result(conn, {:ok, payload}), do: json(conn, payload)

  defp render_result(conn, {:error, {status, code, message}}) do
    conn
    |> put_status(status)
    |> json(%{
      "ok" => false,
      "error" => %{
        "code" => code,
        "message" => message
      }
    })
  end

  defp required_header(conn, name) do
    conn
    |> get_req_header(name)
    |> List.first()
    |> case do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, "receipt_audience_required", "request audience is required"}
          audience -> {:ok, audience}
        end

      _ ->
        {:error, "receipt_audience_required", "request audience is required"}
    end
  end
end
