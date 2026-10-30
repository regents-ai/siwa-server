defmodule SiwaServerWeb.ClientAddress do
  @moduledoc """
  The address a request's rate limits are keyed by. Production runs behind Fly's
  proxy, which reaches the machine over its private IPv4 address, so an IPv4 peer
  is the proxy and the client address arrives in the one header the proxy sets
  itself, replacing any value a client sent. The organisation's private network
  (6PN) is IPv6 and bypasses the proxy, so an IPv6 peer is another of its apps
  connecting directly, and its own address keys it whatever header it sent
  (docs.fly.io/networking/app-services, /networking/private-networking).
  Anywhere else nothing replaces that header, so the direct peer decides and no
  request header is read. `X-Forwarded-For` is never read: a client writes its
  first entries.
  """

  @doc """
  The limiter key for `conn` and where it came from. Behind Fly, anything but
  exactly one parseable `Fly-Client-IP` keys the proxy-wide peer bucket rather
  than a second header a client could forge itself a private budget with.
  """
  @spec key(Plug.Conn.t()) :: {:inet.ip_address(), :client_header | :peer | :peer_fallback}
  def key(conn) do
    if Application.fetch_env!(:siwa_server, :behind_fly_proxy) and ipv4?(conn.remote_ip),
      do: fly_client(conn),
      else: {normalized(conn.remote_ip), :peer}
  end

  defp fly_client(conn) do
    with [value] <- Plug.Conn.get_req_header(conn, "fly-client-ip"),
         {:ok, address} <- value |> :binary.bin_to_list() |> :inet.parse_strict_address() do
      {normalized(address), :client_header}
    else
      _absent_duplicated_or_unparseable -> {normalized(conn.remote_ip), :peer_fallback}
    end
  end

  # An IPv4 peer, as an IPv4 listener or one on both families reports it.
  defp ipv4?({_, _, _, _}), do: true
  defp ipv4?({0, 0, 0, 0, 0, 0xFFFF, _, _}), do: true
  defp ipv4?(_ipv6), do: false

  # The mapped and compatible IPv6 spellings of one IPv4 address share its
  # bucket, and a genuine IPv6 client is keyed by its /64 so one host cannot
  # spend the budget once per address in the block it was handed. The key is
  # never persisted, rendered or logged; it lives only in the limiter.
  defp normalized({_, _, _, _} = ipv4), do: ipv4

  defp normalized({0, 0, 0, 0, 0, embedding, high, low}) when embedding in [0, 0xFFFF] do
    <<a, b, c, d>> = <<high::16, low::16>>
    {a, b, c, d}
  end

  defp normalized({a, b, c, d, _, _, _, _}), do: {a, b, c, d, 0, 0, 0, 0}
end
