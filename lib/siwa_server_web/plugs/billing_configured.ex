defmodule SiwaServerWeb.Plugs.BillingConfigured do
  @moduledoc """
  Refuses every billing request with 503 while this server has no Stripe
  settings (`SiwaServer.Config.stripe/0`); nothing else on the server depends
  on them. With them, they are kept in `conn.assigns.stripe`.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  @behaviour Plug

  alias SiwaServer.Config
  alias SiwaServerWeb.ErrorJSON

  def init(opts), do: opts

  def call(conn, _opts) do
    case Config.stripe() do
      {:ok, stripe} ->
        assign(conn, :stripe, stripe)

      :error ->
        conn
        |> put_status(:service_unavailable)
        |> json(
          ErrorJSON.refusal(
            conn,
            "billing_not_configured",
            "billing is not configured on this server"
          )
        )
        |> halt()
    end
  end
end
