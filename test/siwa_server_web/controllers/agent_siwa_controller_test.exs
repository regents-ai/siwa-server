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

  test "a request without signed headers is told where to get the newest client", %{conn: conn} do
    payload = %{
      "method" => "GET",
      "path" => "/api/agents/v1/me",
      "headers" => %{
        "x-agent-wallet-address" => @wallet_address,
        "x-agent-chain-id" => Integer.to_string(@chain_id)
      }
    }

    conn =
      conn
      |> put_req_header("x-siwa-audience", "regents")
      |> json_post("/api/shared/siwa/http-verify", payload)

    assert %{"error" => %{"code" => "http_headers_missing", "hint" => hint}} =
             json_response(conn, 401)

    assert hint =~ "curl -fsSO https://siwa.regents.sh/agent/siwa_agent.py"
    assert hint =~ "uv tool upgrade regents-cli"
  end

  # A request with every signed header present was refused with words saying the
  # headers were missing (Sentinel, 18 Oct 2026).
  test "a request with every signed header but a bad signature is told it didn't verify",
       %{conn: conn} do
    previous = Application.get_env(:siwa_server, :siwa)
    on_exit(fn -> Application.put_env(:siwa_server, :siwa, previous) end)

    Application.put_env(
      :siwa_server,
      :siwa,
      Keyword.put(previous, :wallet_origins, %{"patchbay" => ["https://patchbay.help"]})
    )

    # Base answers that no smart wallet approves the wrong signature.
    System.put_env("BASE_RPC_URL", TestRpcServer.wallet_answers({true, <<>>}))

    # The same headers, signed rightly, are accepted: only the signature differs below.
    good =
      conn
      |> put_req_header("x-siwa-audience", "patchbay")
      |> json_post("/api/shared/siwa/http-verify", %{
        "method" => "GET",
        "path" => "/api/agents/v1/me",
        "headers" => signed_headers()
      })

    assert %{"data" => %{"verified" => true}} = json_response(good, 200)

    wrong = "sig1=:" <> signature_payload(TestWallet.sign_message("some other text")) <> ":"

    for {signature, code, says} <- [
          {"sig1=:!!!!:", "http_signature_invalid", "didn't verify"},
          {wrong, "signature_invalid", "does not come from the address"}
        ] do
      payload = %{
        "method" => "GET",
        "path" => "/api/agents/v1/me",
        "headers" => Map.put(signed_headers(), "x-siwa-signature", signature)
      }

      conn =
        conn
        |> recycle()
        |> put_req_header("x-siwa-audience", "patchbay")
        |> json_post("/api/shared/siwa/http-verify", payload)

      assert %{"error" => %{"code" => ^code, "hint" => hint}} = json_response(conn, 401)
      refute hint =~ "missing"
      assert hint =~ says
    end
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

  test "discovery endpoints expose health and the services contract", %{conn: conn} do
    assert response(get(conn, "/"), 200) =~ "/skill.md"
    assert response(get(conn, "/healthz"), 200) == "ok"

    previous_rpc_urls = Map.new(~w(ETHEREUM_RPC_URL WORLD_RPC_URL), &{&1, System.get_env(&1)})
    System.put_env("ETHEREUM_RPC_URL", TestRpcServer.chain_id(1))
    System.put_env("WORLD_RPC_URL", TestRpcServer.chain_id(480))

    on_exit(fn ->
      for {name, value} <- previous_rpc_urls do
        if value, do: System.put_env(name, value), else: System.delete_env(name)
      end
    end)

    ready_conn = get(conn, "/readyz")
    assert %{"ready" => true, "checks" => checks} = json_response(ready_conn, 200)
    assert checks["database"] == true
    assert checks["endpoint_secret"] == true
    assert checks["receipt_secret"] == true
    assert checks["keyring_backend"] == true
    assert checks["keyring_password"] == true
    assert checks["keystore_path"] == true
    assert checks["base_rpc_url"] == true
    assert checks["base_rpc_chain_id"] == true
    assert checks["ethereum_rpc_url"] == true
    assert checks["ethereum_rpc_chain_id"] == true

    contract = response(get(conn, "/regent-services-contract.openapiv3.yaml"), 200)
    assert contract =~ "Regent Shared Services Contract"
    assert contract =~ "/agent-profiles/{profile_id}"
    assert contract =~ "agentRegistration"
    refute contract =~ "AgentSiwaHeaders"
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
               "/regent-services-contract.openapiv3.yaml",
               "/api/shared/siwa/audiences",
               "/api/shared/siwa/wallet/nonce",
               "/api/shared/siwa/wallet/verify",
               "/api/shared/siwa/http-verify",
               "/api/shared/siwa/activity",
               "/api/shared/siwa/agent/register-step",
               "/api/shared/siwa/agent/registered",
               "/api/shared/siwa/agent-book/challenge",
               "/api/shared/siwa/agent-book/accept",
               "/agent-profiles/{profile_id}",
               "/api/shared/siwa/hosted"
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

  # Every header a signed GET carries, signed by the test wallet for patchbay.
  defp signed_headers do
    secret = :siwa_server |> Application.fetch_env!(:siwa) |> Keyword.fetch!(:receipt_secret)

    {:ok, %{token: receipt}} =
      Siwa.create_receipt(
        %{
          "typ" => "siwa_wallet_receipt",
          "verified" => "wallet_signature",
          "jti" => Ecto.UUID.generate(),
          "sub" => @wallet_address,
          "aud" => "patchbay",
          "chain_id" => @chain_id,
          "nonce" => "receipt-#{System.unique_integer([:positive])}",
          "key_id" => @wallet_address
        },
        receipt_secret: secret,
        ttl_ms: 3_600_000
      )

    created = System.os_time(:second)

    headers = %{
      "x-siwa-receipt" => receipt,
      "x-key-id" => @wallet_address,
      "x-timestamp" => Integer.to_string(created),
      "x-agent-wallet-address" => @wallet_address,
      "x-agent-chain-id" => Integer.to_string(@chain_id)
    }

    components =
      ~w(@method @path x-siwa-receipt x-key-id x-timestamp x-agent-wallet-address x-agent-chain-id)

    params =
      "(#{Enum.map_join(components, " ", &~s("#{&1}"))});created=#{created};expires=#{created + 120}" <>
        ~s(;nonce="req-#{System.unique_integer([:positive])}";keyid="#{@wallet_address}")

    message =
      components
      |> Enum.map(fn
        "@method" -> ~s("@method": get)
        "@path" -> ~s("@path": /api/agents/v1/me)
        name -> ~s("#{name}": #{headers[name]})
      end)
      |> Kernel.++([~s("@signature-params": #{params})])
      |> Enum.join("\n")

    headers
    |> Map.put("x-siwa-signature-input", "sig1=#{params}")
    |> Map.put(
      "x-siwa-signature",
      "sig1=:#{signature_payload(TestWallet.sign_message(message))}:"
    )
  end

  defp signature_payload("0x" <> hex), do: hex |> Base.decode16!(case: :mixed) |> Base.encode64()

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
