defmodule SiwaServerWeb.Plugs.ControlConfigured do
  @moduledoc """
  Refuses every control API request with 503 while this server has no Privy
  settings (`SiwaServer.Config.privy/0`); nothing else on the server depends on
  them. With them, they are kept in `conn.assigns.privy` for the sign-in check.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  @behaviour Plug

  alias SiwaServer.Config
  alias SiwaServerWeb.ErrorJSON

  def init(opts), do: opts

  def call(conn, _opts) do
    case Config.privy() do
      {:ok, privy} ->
        assign(conn, :privy, privy)

      :error ->
        conn
        |> put_status(:service_unavailable)
        |> json(
          ErrorJSON.refusal(
            conn,
            "control_not_configured",
            "the control API is not configured on this server"
          )
        )
        |> halt()
    end
  end
end
