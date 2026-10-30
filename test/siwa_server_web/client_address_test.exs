defmodule SiwaServerWeb.ClientAddressTest do
  # Behind Fly, only the proxy's own connection, over the machine's private IPv4
  # address, says who the client is. Another of the organisation's apps reaching
  # the machine over 6PN (IPv6) is keyed by its own address, whatever it sends.
  use ExUnit.Case, async: false

  import Plug.Test

  alias SiwaServerWeb.ClientAddress

  setup do
    previous = Application.fetch_env!(:siwa_server, :behind_fly_proxy)
    Application.put_env(:siwa_server, :behind_fly_proxy, true)
    on_exit(fn -> Application.put_env(:siwa_server, :behind_fly_proxy, previous) end)
  end

  defp request(peer, client) do
    %{conn(:get, "/") | remote_ip: peer}
    |> Plug.Conn.put_req_header("fly-client-ip", client)
  end

  test "the proxy's header names the client" do
    assert ClientAddress.key(request({172, 16, 3, 9}, "203.0.113.7")) ==
             {{203, 0, 113, 7}, :client_header}

    # A listener on both families reports the proxy's IPv4 address mapped into IPv6.
    assert ClientAddress.key(request({0, 0, 0, 0, 0, 0xFFFF, 0xAC10, 0x0309}, "203.0.113.7")) ==
             {{203, 0, 113, 7}, :client_header}
  end

  test "an unreadable or doubled header from the proxy keys the proxy's own address" do
    proxy = {172, 16, 3, 9}

    assert ClientAddress.key(request(proxy, "203.0.113.7, 198.51.100.4")) ==
             {proxy, :peer_fallback}

    assert ClientAddress.key(request(proxy, "not an address")) == {proxy, :peer_fallback}

    doubled = request(proxy, "203.0.113.7")
    doubled = %{doubled | req_headers: [{"fly-client-ip", "198.51.100.4"} | doubled.req_headers]}
    assert ClientAddress.key(doubled) == {proxy, :peer_fallback}

    assert ClientAddress.key(%{conn(:get, "/") | remote_ip: proxy}) == {proxy, :peer_fallback}
  end

  test "a header from a 6PN peer is ignored and the peer keys itself" do
    assert ClientAddress.key(
             request({0xFDAA, 0, 0x2C, 0xA7B, 0x1A2, 0x5D, 0x3E, 2}, "203.0.113.7")
           ) ==
             {{0xFDAA, 0, 0x2C, 0xA7B, 0, 0, 0, 0}, :peer}

    # An IPv6 peer written in the old IPv4-compatible form is still not the proxy.
    assert ClientAddress.key(request({0, 0, 0, 0, 0, 0, 0xAC10, 0x0309}, "203.0.113.7")) ==
             {{172, 16, 3, 9}, :peer}
  end

  test "off Fly no header is read" do
    Application.put_env(:siwa_server, :behind_fly_proxy, false)

    assert ClientAddress.key(request({127, 0, 0, 1}, "203.0.113.7")) == {{127, 0, 0, 1}, :peer}
  end
end
