defmodule SiwaServerWeb.FallbackController do
  use SiwaServerWeb, :controller

  alias SiwaServerWeb.{ErrorJSON, Help}

  def call(conn, {:error, {status, code, message}}) do
    conn
    |> put_status(status)
    |> json(ErrorJSON.error(code, message, %{"hint" => Help.hint(code, Help.context(conn))}))
  end
end
