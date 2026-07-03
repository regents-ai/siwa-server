defmodule SiwaServerWeb.Plugs.RateLimitTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Plug.Test

  alias SiwaServer.RateLimiter
  alias SiwaServerWeb.Plugs.RateLimit

  setup do
    ensure_rate_limiter_started()
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
    %{conn(:post, "/api/shared/siwa/nonce") | remote_ip: ip}
  end

  defp parsed_conn(ip, wallet_address) do
    conn =
      conn(:post, "/api/shared/siwa/nonce", %{
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
    build = fn -> %{conn(:post, "/api/shared/keyring/sign-message") | remote_ip: {9, 9, 9, 9}} end

    assert %Plug.Conn{halted: false} = call(build.(), :keyring_internal)
    assert %Plug.Conn{halted: false} = call(build.(), :keyring_internal)

    conn = call(build.(), :keyring_internal)
    assert conn.halted
    assert conn.status == 429
  end

  test "missing limiter table allows requests, emits telemetry, and does not create a caller-owned table" do
    attach_fail_open_handler()

    owner = Process.whereis(RateLimiter)
    assert is_pid(owner)

    stop_rate_limiter_owner(owner)

    assert Process.whereis(RateLimiter) == nil
    assert :ets.whereis(RateLimiter) == :undefined

    capture_log(fn ->
      assert :ok =
               RateLimiter.check(
                 :siwa_nonce,
                 "wallet:0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
                 1,
                 60_000
               )
    end)

    assert :ets.whereis(RateLimiter) == :undefined

    assert_receive {:rate_limiter_fail_open, [:siwa_server, :rate_limiter, :fail_open],
                    %{count: 1}, metadata}

    assert metadata == %{key_class: :siwa_nonce}
    refute inspect(metadata) =~ "0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
  end

  test "missing limiter table warning is throttled across rapid allowed requests" do
    owner = Process.whereis(RateLimiter)
    assert is_pid(owner)

    stop_rate_limiter_owner(owner)

    log =
      capture_log(fn ->
        assert :ok = RateLimiter.check(:siwa_nonce, "first", 1, 60_000)
        assert :ok = RateLimiter.check(:siwa_nonce, "second", 1, 60_000)
      end)

    assert length(Regex.scan(~r/SIWA rate limiter table is unavailable/, log)) == 1
  end

  defp ensure_rate_limiter_started do
    case Process.whereis(RateLimiter) do
      nil -> start_supervised!(RateLimiter)
      pid -> pid
    end
  end

  defp stop_rate_limiter_owner(owner) do
    case Process.whereis(SiwaServer.Supervisor) do
      nil ->
        stop_standalone_rate_limiter(owner)

      _supervisor ->
        assert :ok = Supervisor.terminate_child(SiwaServer.Supervisor, RateLimiter)

        on_exit(fn ->
          _result = Supervisor.restart_child(SiwaServer.Supervisor, RateLimiter)
          wait_for_rate_limiter_table()
          RateLimiter.reset()
        end)
    end
  end

  defp stop_standalone_rate_limiter(owner) do
    case stop_supervised(RateLimiter) do
      :ok ->
        :ok

      {:error, :not_found} ->
        ref = Process.monitor(owner)
        :ok = GenServer.stop(owner)

        receive do
          {:DOWN, ^ref, :process, ^owner, _reason} -> :ok
        after
          1_000 -> flunk("rate limiter did not stop")
        end
    end
  end

  defp wait_for_rate_limiter_table(attempts \\ 50)
  defp wait_for_rate_limiter_table(0), do: flunk("rate limiter table was not recreated")

  defp wait_for_rate_limiter_table(attempts) do
    if Process.whereis(RateLimiter) && :ets.whereis(RateLimiter) != :undefined do
      :ok
    else
      Process.sleep(10)
      wait_for_rate_limiter_table(attempts - 1)
    end
  end

  defp attach_fail_open_handler do
    handler_id = {__MODULE__, self(), :rate_limiter_fail_open}

    :telemetry.attach(
      handler_id,
      [:siwa_server, :rate_limiter, :fail_open],
      &__MODULE__.handle_fail_open_event/4,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  def handle_fail_open_event(event, measurements, metadata, test_pid) do
    send(test_pid, {:rate_limiter_fail_open, event, measurements, metadata})
  end
end
