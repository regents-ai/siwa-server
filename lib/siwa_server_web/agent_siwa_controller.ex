defmodule SiwaServerWeb.AgentSiwaController do
  use SiwaServerWeb, :controller

  alias SiwaServer.Siwa

  def nonce(conn, params), do: render_result(conn, Siwa.issue_nonce(params))
  def verify(conn, params), do: render_result(conn, Siwa.verify_session(params))

  def http_verify(conn, params) do
    audience =
      conn
      |> get_req_header("x-siwa-audience")
      |> List.first()

    render_result(
      conn,
      params
      |> Map.take(["method", "path", "headers", "body"])
      |> Siwa.verify_http_request(audience: audience)
    )
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
end
