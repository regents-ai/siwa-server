defmodule SiwaServerWeb.JsonParser do
  @moduledoc false

  # A site sends http-verify the whole signed body as a JSON string. Sites accept
  # bodies up to 2 MiB, and escaping can at most double one, so this route reads
  # twice that plus room for the method, path and headers. Every other route
  # keeps the endpoint's own limit.
  @http_verify_length 2 * 2_097_152 + 65_536

  def init(opts) do
    %{
      default: Plug.Parsers.init(opts),
      http_verify: Plug.Parsers.init(Keyword.put(opts, :length, @http_verify_length))
    }
  end

  def call(%Plug.Conn{path_info: ["api", "shared", "keyring" | _]} = conn, _opts), do: conn

  def call(%Plug.Conn{path_info: ["api", "shared", "siwa", "http-verify"]} = conn, opts),
    do: Plug.Parsers.call(conn, opts.http_verify)

  def call(conn, opts), do: Plug.Parsers.call(conn, opts.default)
end
