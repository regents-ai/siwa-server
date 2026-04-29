defmodule SiwaServerWeb.FallbackController do
  use SiwaServerWeb, :controller

  alias SiwaServerWeb.ErrorJSON

  def call(conn, {:error, {status, code, message}}) do
    conn
    |> put_status(status)
    |> json(ErrorJSON.error(code, message))
  end
end
