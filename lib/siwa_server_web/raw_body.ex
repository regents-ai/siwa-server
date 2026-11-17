defmodule SiwaServerWeb.RawBody do
  @moduledoc """
  The body reader `Plug.Parsers` reads JSON with (`SiwaServerWeb.Endpoint`).
  For the two requests whose signature is over the bytes as sent, it also keeps
  the body exactly as received, in `conn.private.raw_body`: Stripe's notices
  (`SiwaServer.Billing.Notice.verify/4`) and an agent's hello card request,
  whose `content-digest` is signed (`SiwaServerWeb.HelloCardController`). Every
  other request is only read.
  """

  @paths ["/api/stripe/webhook", "/api/shared/siwa/hello-card"]

  @spec read_body(Plug.Conn.t(), keyword()) ::
          {:ok, binary(), Plug.Conn.t()} | {:more, binary(), Plug.Conn.t()} | {:error, term()}
  def read_body(%Plug.Conn{request_path: path} = conn, opts) when path in @paths do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} -> {:ok, body, Plug.Conn.put_private(conn, :raw_body, body)}
      more_or_error -> more_or_error
    end
  end

  def read_body(conn, opts), do: Plug.Conn.read_body(conn, opts)
end
