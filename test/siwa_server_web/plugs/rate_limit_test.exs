defmodule SiwaServerWeb.Plugs.RateLimitTest do
  use SiwaServer.DataCase, async: false

  import Plug.Test

  alias SiwaServer.RateLimiter
  alias SiwaServerWeb.Plugs.RateLimit

  setup do
    original = Application.get_env(:siwa_server, :rate_limits, [])

    Application.put_env(:siwa_server, :rate_limits,
      siwa_nonce: [limit: 2, window_ms: 60_000],
      siwa_computer: [limit: 3, window_ms: 60_000],
      siwa_site: [limit: 3, window_ms: 60_000]
    )

    on_exit(fn ->
      Application.put_env(:siwa_server, :rate_limits, original)
    end)

    :ok
  end

  defp call(conn, name), do: RateLimit.call(conn, name: name)

  defp unfetched_conn(ip) do
    # Plug.Test.conn/2 without params leaves body_params as %Plug.Conn.Unfetched{},
    # matching a request whose body was never parsed upstream.
    %{conn(:post, "/api/shared/siwa/wallet/nonce") | remote_ip: ip}
  end

  defp parsed_conn(ip, wallet_address) do
    conn =
      conn(:post, "/api/shared/siwa/wallet/nonce", %{
        "wallet_address" => wallet_address,
        "chain_id" => 8453,
        "audience" => "platform"
      })

    %{conn | remote_ip: ip}
  end

  test "requests without fetched body params are rate limited per IP without crashing" do
    assert %Plug.Conn{halted: false} = call(unfetched_conn({1, 2, 3, 4}), :siwa_nonce)
    assert %Plug.Conn{halted: false} = call(unfetched_conn({1, 2, 3, 4}), :siwa_nonce)

    conn = call(unfetched_conn({1, 2, 3, 4}), :siwa_nonce)

    assert conn.halted
    assert conn.status == 429
    assert [retry_after] = Plug.Conn.get_resp_header(conn, "retry-after")
    assert String.to_integer(retry_after) >= 1

    assert %{"error" => %{"code" => "rate_limited", "hint" => hint}} =
             Jason.decode!(conn.resp_body)

    assert hint =~ "Wait the seconds in Retry-After"

    # A different client IP gets its own bucket.
    assert %Plug.Conn{halted: false} = call(unfetched_conn({5, 6, 7, 8}), :siwa_nonce)
  end

  test "requests with parsed body params are keyed on wallet, chain, audience and IP" do
    wallet = "0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"

    assert %Plug.Conn{halted: false} = call(parsed_conn({1, 2, 3, 4}, wallet), :siwa_nonce)
    assert %Plug.Conn{halted: false} = call(parsed_conn({1, 2, 3, 4}, wallet), :siwa_nonce)

    conn = call(parsed_conn({1, 2, 3, 4}, wallet), :siwa_nonce)
    assert conn.halted
    assert conn.status == 429

    # Unfetched-body requests from the same IP map to the stable
    # "unknown" key parts and stay independently rate limited.
    assert %Plug.Conn{halted: false} = call(unfetched_conn({1, 2, 3, 4}), :siwa_nonce)
  end

  test "one computer naming a new wallet address each time still reaches its ceiling" do
    wallet = fn n -> "0x" <> String.pad_leading(Integer.to_string(n), 40, "0") end

    for n <- 1..3 do
      assert %Plug.Conn{halted: false} = call(parsed_conn({1, 2, 3, 4}, wallet.(n)), :siwa_nonce)
    end

    conn = call(parsed_conn({1, 2, 3, 4}, wallet.(4)), :siwa_nonce)
    assert conn.halted
    assert conn.status == 429

    # The ceiling spans every address-keyed step from that computer.
    assert %Plug.Conn{halted: true, status: 429} =
             call(parsed_conn({1, 2, 3, 4}, wallet.(5)), :siwa_verify)

    # Another computer has its own ceiling.
    assert %Plug.Conn{halted: false} = call(parsed_conn({5, 6, 7, 8}, wallet.(6)), :siwa_nonce)
  end

  # Sean SIWA-ADDRESS-TEST a (13 Oct 2026)
  test "outside production a Fly-Client-IP header is ignored and the direct peer decides" do
    from_peer_claiming = fn address ->
      {1, 2, 3, 4} |> unfetched_conn() |> Plug.Conn.put_req_header("fly-client-ip", address)
    end

    assert %Plug.Conn{halted: false} = call(from_peer_claiming.("203.0.113.7"), :siwa_nonce)
    assert %Plug.Conn{halted: false} = call(from_peer_claiming.("203.0.113.8"), :siwa_nonce)

    assert %Plug.Conn{halted: true, status: 429} =
             call(from_peer_claiming.("203.0.113.9"), :siwa_nonce)
  end

  # Sean SIWA-LIMITER-TEST a (13 Oct 2026)
  test "a key of any length is kept at a fixed size and still counted as its own key" do
    long = String.duplicate("a", 60_000)

    assert :ok = RateLimiter.check(:siwa_nonce, long)
    assert :ok = RateLimiter.check(:siwa_nonce, long)
    assert {:error, _retry_after_ms} = RateLimiter.check(:siwa_nonce, long)
    assert :ok = RateLimiter.check(:siwa_nonce, long <> "b")

    sizes = Repo.all(from(r in "siwa_rate_limits", select: fragment("octet_length(?)", r.key)))

    assert sizes == [32, 32]
  end

  test "one computer checking a new wallet's request each time still reaches the site ceiling" do
    verify_conn = fn ip, n ->
      wallet = "0x" <> String.pad_leading(Integer.to_string(n), 40, "0")

      conn =
        conn(:post, "/api/shared/siwa/http-verify", %{
          "headers" => %{"x-agent-wallet-address" => wallet, "x-agent-chain-id" => "8453"}
        })

      %{conn | remote_ip: ip}
    end

    for n <- 1..3 do
      assert %Plug.Conn{halted: false} = call(verify_conn.({1, 2, 3, 4}, n), :siwa_http_verify)
    end

    assert %Plug.Conn{halted: true, status: 429} =
             call(verify_conn.({1, 2, 3, 4}, 4), :siwa_http_verify)

    # Another site's server has its own ceiling.
    assert %Plug.Conn{halted: false} = call(verify_conn.({5, 6, 7, 8}, 4), :siwa_http_verify)
  end
end
