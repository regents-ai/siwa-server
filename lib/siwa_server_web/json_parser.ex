defmodule SiwaServerWeb.JsonParser do
  @moduledoc false

  def init(opts), do: Plug.Parsers.init(opts)

  def call(%Plug.Conn{path_info: ["internal", "keyring" | _]} = conn, _opts), do: conn

  def call(conn, opts), do: Plug.Parsers.call(conn, opts)
end
