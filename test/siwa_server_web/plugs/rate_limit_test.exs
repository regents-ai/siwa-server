defmodule SiwaServerWeb.Plugs.RateLimitTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias SiwaServer.RateLimiter
  alias SiwaServerWeb.Plugs.RateLimit

  setup do
    RateLimiter.reset()
    original = Application.get_env(:siwa_server, :rate_limits, [])

    Application.put_env(:siwa_server, :rate_limits,
      siwa_nonce: [limit: 2, window_ms: 60_000],
      keyring_internal: [limit: 2, window_ms: 60_000]
    )

    on_exit(fn ->
      Application.put_env(:siwa_server, :rate_limits, original)
      RateLimiter.reset()
    end)

    :ok
  end

  defp call(conn, name), do: RateLimit.call(conn, name: name)

  defp unfetched_conn(ip) do
    # Plug.Test.conn/2 without params leaves body_params as %Plug.Conn.Unfetched{},
    # matching a request whose body was never parsed upstream.
    %{conn(:post, "/v1/agent/siwa/nonce") | remote_ip: ip}
  end

  defp parsed_conn(ip, wallet_address) do
    conn =
      conn(:post, "/v1/agent/siwa/nonce", %{
        "wallet_address" => wallet_address,
        "chain_id" => 8453,
        "registry_address" => "0x3333333333333333333333333333333333333333",
        "token_id" => "77",
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
    assert conn.resp_body =~ "rate_limited"

    # A different client IP gets its own bucket.
    assert %Plug.Conn{halted: false} = call(unfetched_conn({5, 6, 7, 8}), :siwa_nonce)
  end

  test "requests with parsed body params are keyed on agent identity and IP" do
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

  test "keyring requests with unparsed bodies are rate limited per method, path, and IP" do
    build = fn -> %{conn(:post, "/internal/keyring/sign-message") | remote_ip: {9, 9, 9, 9}} end

    assert %Plug.Conn{halted: false} = call(build.(), :keyring_internal)
    assert %Plug.Conn{halted: false} = call(build.(), :keyring_internal)

    conn = call(build.(), :keyring_internal)
    assert conn.halted
    assert conn.status == 429
  end
end
