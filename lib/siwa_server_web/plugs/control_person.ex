defmodule SiwaServerWeb.Plugs.ControlPerson do
  @moduledoc """
  Admits a control API request whose bearer is a current control token
  (`SiwaServerWeb.ControlToken`), with the person's Privy DID in
  `conn.assigns.did`. Any other request is refused with 401.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  @behaviour Plug

  alias SiwaServerWeb.{ControlToken, ErrorJSON}

  def init(opts), do: opts

  def call(conn, _opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, did} <- ControlToken.verify(token) do
      assign(conn, :did, did)
    else
      _absent_invalid_or_expired ->
        conn
        |> put_status(:unauthorized)
        |> json(
          ErrorJSON.refusal(
            conn,
            "control_token_invalid",
            "the control token is missing, not valid or expired"
          )
        )
        |> halt()
    end
  end
end
