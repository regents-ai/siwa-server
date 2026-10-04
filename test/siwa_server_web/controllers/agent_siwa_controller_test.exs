defmodule SiwaServerWeb.AgentSiwaControllerTest do
  use SiwaServerWeb.ConnCase, async: false

  alias SiwaServer.{TestRpcServer, TestWallet}

  @wallet_address TestWallet.address()
  @chain_id 8453

  setup do
    previous_base_rpc_url = System.get_env("BASE_RPC_URL")
    previous_rate_limits = Application.get_env(:siwa_server, :rate_limits, [])

    System.put_env("BASE_RPC_URL", TestRpcServer.chain_id(8453))
    SiwaServer.RateLimiter.reset()

    on_exit(fn ->
      case previous_base_rpc_url do
        nil -> System.delete_env("BASE_RPC_URL")
        value -> System.put_env("BASE_RPC_URL", value)
      end

      Application.put_env(:siwa_server, :rate_limits, previous_rate_limits)
      SiwaServer.RateLimiter.reset()
    end)

    :ok
  end

  test "http verify requests use the signed-agent allowance bucket", %{conn: conn} do
    Application.put_env(:siwa_server, :rate_limits,
      siwa_http_verify: [limit: 1, window_ms: 60_000],
      siwa_nonce: [limit: 60, window_ms: 60_000],
      siwa_verify: [limit: 60, window_ms: 60_000]
    )

    payload = %{
      "method" => "POST",
      "path" => "/v1/agent/bug-report",
      "headers" => %{
        "x-agent-wallet-address" => @wallet_address,
        "x-agent-chain-id" => Integer.to_string(@chain_id)
      }
    }

    first_conn =
      conn
      |> recycle()
      |> put_req_header("x-siwa-audience", "patchbay")
      |> json_post("/api/shared/siwa/http-verify", payload)

    assert first_conn.status in [400, 401]

    conn =
      conn
      |> recycle()
      |> put_req_header("x-siwa-audience", "patchbay")
      |> json_post("/api/shared/siwa/http-verify", payload)

    assert_retry_after(conn)
    assert %{"error" => %{"code" => "rate_limited"}} = json_response(conn, 429)
  end

  test "public SIWA endpoints reject oversized JSON bodies", %{conn: conn} do
    body = Jason.encode!(%{"message" => String.duplicate("x", 70_000)})

    assert {413, _headers, response_body} =
             assert_error_sent(413, fn ->
               conn
               |> put_req_header("content-type", "application/json")
               |> post("/api/shared/siwa/wallet/nonce", body)
             end)

    assert %{
             "error" => %{
               "code" => "request_body_too_large",
               "message" => "Request Entity Too Large"
             }
           } = Jason.decode!(response_body)
  end

  test "public SIWA endpoints reject unsupported media types", %{conn: conn} do
    assert {415, _headers, response_body} =
             assert_error_sent(415, fn ->
               conn
               |> put_req_header("content-type", "text/plain")
               |> post("/api/shared/siwa/wallet/nonce", "not-json")
             end)

    assert %{
             "error" => %{
               "code" => "unsupported_media_type",
               "message" => "Unsupported Media Type"
             }
           } = Jason.decode!(response_body)
  end

  test "discovery endpoints expose health, metrics, and the services contract", %{conn: conn} do
    assert response(get(conn, "/"), 200) == "ok"
    assert response(get(conn, "/healthz"), 200) == "ok"

    previous_ethereum_rpc_url = System.get_env("ETHEREUM_RPC_URL")
    System.put_env("ETHEREUM_RPC_URL", TestRpcServer.chain_id(1))

    on_exit(fn ->
      if previous_ethereum_rpc_url,
        do: System.put_env("ETHEREUM_RPC_URL", previous_ethereum_rpc_url),
        else: System.delete_env("ETHEREUM_RPC_URL")
    end)

    ready_conn = get(conn, "/readyz")
    assert %{"ready" => true, "checks" => checks} = json_response(ready_conn, 200)
    assert checks["database"] == true
    assert checks["endpoint_secret"] == true
    assert checks["receipt_secret"] == true
    assert checks["keyring_backend"] == true
    assert checks["keyring_password"] == true
    assert checks["keyring_secret"] == true
    assert checks["keystore_path"] == true
    assert checks["base_rpc_url"] == true
    assert checks["base_rpc_chain_id"] == true
    assert checks["ethereum_rpc_url"] == true
    assert checks["ethereum_rpc_chain_id"] == true

    metrics = response(get(conn, "/metrics"), 200)
    assert metrics =~ "siwa_server"

    contract = response(get(conn, "/regent-services-contract.openapiv3.yaml"), 200)
    assert contract =~ "Regent Shared Services Contract"
    assert contract =~ "/agent-profiles/{profile_id}"
    assert contract =~ "agentRegistration"
    assert contract =~ "KeyringHmacSignature"
    refute contract =~ "AgentSiwaHeaders"
    assert contract =~ "KeyringSignTransactionRequest"
    refute contract =~ "/v1/agent/regent/staking"

    contract_paths =
      ~r/^  (\/[^:\n]*):$/m
      |> Regex.scan(contract, capture: :all_but_first)
      |> List.flatten()
      |> MapSet.new()

    assert contract_paths ==
             MapSet.new([
               "/",
               "/healthz",
               "/readyz",
               "/metrics",
               "/regent-services-contract.openapiv3.yaml",
               "/api/shared/siwa/audiences",
               "/api/shared/siwa/wallet/nonce",
               "/api/shared/siwa/wallet/verify",
               "/api/shared/siwa/http-verify",
               "/api/shared/siwa/activity",
               "/api/shared/siwa/agent/register-step",
               "/api/shared/siwa/agent/registered",
               "/agent-profiles/{profile_id}",
               "/api/shared/keyring/health",
               "/api/shared/keyring/create-wallet",
               "/api/shared/keyring/has-wallet",
               "/api/shared/keyring/get-address",
               "/api/shared/keyring/sign-message",
               "/api/shared/keyring/sign-raw-message",
               "/api/shared/keyring/sign-transaction",
               "/api/shared/keyring/sign-authorization"
             ])

    assert operation_response_codes(contract, "/api/shared/siwa/http-verify", "post") ==
             MapSet.new(~w(200 400 401 409 413 415 429 500 502))

    assert operation_response_codes(contract, "/api/shared/siwa/activity", "post") ==
             MapSet.new(~w(200 400 401 413 415 429))

    assert operation_response_codes(contract, "/api/shared/siwa/agent/register-step", "post") ==
             MapSet.new(~w(200 400 413 415 429))

    assert operation_response_codes(contract, "/api/shared/siwa/agent/registered", "post") ==
             MapSet.new(~w(200 400 413 415 422 429 502))

    assert operation_response_codes(contract, "/agent-profiles/{profile_id}", "get") ==
             MapSet.new(~w(200 404 429))

    assert operation_response_codes(contract, "/api/shared/keyring/sign-authorization", "post") ==
             MapSet.new(~w(200 400 401 413 415 422 429))
  end

  test "readyz fails without exposing configured secrets when RPC is unreachable", %{conn: conn} do
    System.put_env("BASE_RPC_URL", TestRpcServer.invalid_response())

    ready_conn = get(conn, "/readyz")
    body = response(ready_conn, 503)

    assert %{"ready" => false, "checks" => checks} = Jason.decode!(body)
    assert checks["base_rpc_url"] == true
    assert checks["base_rpc_chain_id"] == false

    refute body =~ "siwa-server-test-receipt-secret"
    refute body =~ "siwa-server-test-password"
    refute body =~ "siwa-server-test-keyring-secret"
  end

  test "readyz fails when the RPC reports a non-Base chain", %{conn: conn} do
    System.put_env("BASE_RPC_URL", TestRpcServer.chain_id(1))

    ready_conn = get(conn, "/readyz")

    assert %{"ready" => false, "checks" => checks} = json_response(ready_conn, 503)
    assert checks["base_rpc_url"] == true
    assert checks["base_rpc_chain_id"] == false
  end

  test "readyz fails for unsupported keyring backends", %{conn: conn} do
    original_keyring = Application.get_all_env(:siwa_keyring)
    Application.put_env(:siwa_keyring, :backend, "memory")

    on_exit(fn ->
      for {key, _value} <- Application.get_all_env(:siwa_keyring) do
        Application.delete_env(:siwa_keyring, key)
      end

      Enum.each(original_keyring, fn {key, value} ->
        Application.put_env(:siwa_keyring, key, value)
      end)
    end)

    ready_conn = get(conn, "/readyz")

    assert %{"ready" => false, "checks" => checks} = json_response(ready_conn, 503)
    assert checks["keyring_backend"] == false
    assert checks["keystore_path"] == false
  end

  defp json_post(conn, path, params) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(params))
  end

  defp operation_response_codes(contract, path, method) do
    path_pattern = Regex.compile!("^  #{Regex.escape(path)}:\\n(.*?)(?=^  /|\\z)", "ms")
    method_pattern = Regex.compile!("^    #{method}:\\n(.*?)(?=^    [a-z]+:|\\z)", "ms")

    [_, path_block] = Regex.run(path_pattern, contract)
    [_, operation_block] = Regex.run(method_pattern, path_block)

    ~r/^        "(\d{3})":$/m
    |> Regex.scan(operation_block, capture: :all_but_first)
    |> List.flatten()
    |> MapSet.new()
  end

  defp assert_retry_after(conn) do
    assert [value] = get_resp_header(conn, "retry-after")
    assert String.to_integer(value) > 0
  end
end
