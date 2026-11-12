defmodule SiwaServerWeb.Plugs.RateLimit do
  @moduledoc """
  Refuses a request over its limit with 429 and the wait in `Retry-After`.

  Limits are keyed by the client's address. Production runs only behind Fly's
  proxy, which terminates the connection, so the peer is the proxy and the
  client address arrives in the one header the proxy sets itself, replacing any
  value a client sent. Anywhere else nothing replaces that header, so the direct
  peer decides and no request header is read. `X-Forwarded-For` is never read: a
  client writes its first entries.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  @behaviour Plug

  alias SiwaServer.RateLimiter
  alias SiwaServerWeb.ErrorJSON

  @behind_fly_proxy Application.compile_env!(:siwa_server, :behind_fly_proxy)

  # These steps come from an agent's own computer and are counted per wallet
  # address the caller names, so they also share one ceiling per computer: naming
  # new addresses does not buy a computer more requests. http-verify's caller is a
  # site's server, which speaks for all of that site's agents, so it has a far
  # higher ceiling of its own.
  @address_keyed [:siwa_nonce, :siwa_verify, :siwa_register, :agent_book]

  def init(opts), do: opts

  def call(conn, opts) do
    name = Keyword.fetch!(opts, :name)

    case check(conn, name) do
      :ok ->
        conn

      {:error, retry_after_ms} ->
        conn
        |> put_status(:too_many_requests)
        |> put_resp_header("retry-after", Integer.to_string(ceil(retry_after_ms / 1_000)))
        |> json(
          ErrorJSON.refusal(conn, "rate_limited", "Please wait a moment before trying again.", %{
            "retry_after_ms" => retry_after_ms
          })
        )
        |> halt()
    end
  end

  defp check(conn, name) when name in @address_keyed do
    with :ok <- RateLimiter.check(name, client_key(conn, name)) do
      RateLimiter.check(:siwa_computer, client_ip(conn))
    end
  end

  defp check(conn, :siwa_http_verify) do
    with :ok <- RateLimiter.check(:siwa_http_verify, client_key(conn, :siwa_http_verify)) do
      RateLimiter.check(:siwa_site, client_ip(conn))
    end
  end

  defp check(conn, name), do: RateLimiter.check(name, client_key(conn, name))

  defp client_key(conn, :siwa_http_verify) do
    [
      "http-verify",
      agent_header(conn, "x-agent-wallet-address"),
      agent_header(conn, "x-agent-chain-id"),
      client_ip(conn)
    ]
    |> Enum.join(":")
  end

  defp client_key(conn, :siwa_activity), do: "activity:#{client_ip(conn)}"
  defp client_key(conn, :siwa_hosted), do: "hosted:#{client_ip(conn)}"
  defp client_key(conn, :agent_profile), do: "agent-profile:#{client_ip(conn)}"

  defp client_key(conn, _name) do
    body = fetched_body_params(conn)

    [
      Map.get(body, "wallet_address"),
      Map.get(body, "chain_id"),
      Map.get(body, "audience"),
      client_ip(conn)
    ]
    |> Enum.map_join(":", &normalize_part/1)
  end

  defp agent_header(conn, name) do
    conn
    |> fetched_body_params()
    |> case do
      %{"headers" => headers} when is_map(headers) -> Map.get(headers, name)
      _body -> nil
    end
    |> normalize_part()
  end

  defp fetched_body_params(%Plug.Conn{body_params: %Plug.Conn.Unfetched{}}), do: %{}
  defp fetched_body_params(%Plug.Conn{body_params: body}), do: body

  defp normalize_part(value) when is_binary(value),
    do: value |> String.trim() |> String.downcase()

  defp normalize_part(value) when is_integer(value), do: Integer.to_string(value)
  defp normalize_part(_value), do: "unknown"

  # Behind Fly, anything but exactly one parseable `Fly-Client-IP` keys the
  # proxy-wide peer bucket rather than a second header a client could forge
  # itself a private budget with. The address is never persisted, rendered or
  # logged; it lives only in the limiter's key.
  defp client_ip(conn) do
    address = if @behind_fly_proxy, do: fly_client_ip(conn), else: conn.remote_ip

    address
    |> normalized()
    |> :inet.ntoa()
    |> to_string()
  end

  defp fly_client_ip(conn) do
    with [value] <- get_req_header(conn, "fly-client-ip"),
         {:ok, address} <- value |> :binary.bin_to_list() |> :inet.parse_strict_address() do
      address
    else
      _absent_duplicated_or_unparseable -> conn.remote_ip
    end
  end

  # The mapped and compatible IPv6 spellings of one IPv4 address share its
  # bucket, and a genuine IPv6 client is keyed by its /64 so one host cannot
  # spend the budget once per address in the block it was handed.
  defp normalized({_, _, _, _} = ipv4), do: ipv4

  defp normalized({0, 0, 0, 0, 0, embedding, high, low}) when embedding in [0, 0xFFFF] do
    <<a, b, c, d>> = <<high::16, low::16>>
    {a, b, c, d}
  end

  defp normalized({a, b, c, d, _, _, _, _}), do: {a, b, c, d, 0, 0, 0, 0}
end
