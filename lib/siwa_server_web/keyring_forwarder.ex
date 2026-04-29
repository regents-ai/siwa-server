defmodule SiwaServerWeb.KeyringForwarder do
  @moduledoc false

  @behaviour Plug

  @router_opts SiwaKeyring.Router.init([])

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    conn
    |> Map.put(:path_info, conn.script_name ++ conn.path_info)
    |> Map.put(:script_name, [])
    |> SiwaKeyring.Router.call(@router_opts)
  end
end
