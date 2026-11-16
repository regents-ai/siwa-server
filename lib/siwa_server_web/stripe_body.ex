defmodule SiwaServerWeb.StripeBody do
  @moduledoc """
  The body reader `Plug.Parsers` reads JSON with (`SiwaServerWeb.Endpoint`).
  For Stripe's notices alone it also keeps the body exactly as received, in
  `conn.private.stripe_body`, since their signature is over those bytes
  (`SiwaServer.Billing.Notice.verify/4`). Every other request is read as before.
  """

  @path "/api/stripe/webhook"

  @spec read_body(Plug.Conn.t(), keyword()) ::
          {:ok, binary(), Plug.Conn.t()} | {:more, binary(), Plug.Conn.t()} | {:error, term()}
  def read_body(%Plug.Conn{request_path: @path} = conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} -> {:ok, body, Plug.Conn.put_private(conn, :stripe_body, body)}
      more_or_error -> more_or_error
    end
  end

  def read_body(conn, opts), do: Plug.Conn.read_body(conn, opts)
end
