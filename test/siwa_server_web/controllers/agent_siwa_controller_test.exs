defmodule SiwaServerWeb.AgentSiwaControllerTest do
  use SiwaServerWeb.ConnCase, async: false

  alias SiwaServer.{TestRpcServer, TestWallet}

  @wallet_address TestWallet.address()
  @chain_id 8453
  @registry_address "0x3333333333333333333333333333333333333333"
  @token_id "77"

  setup do
    previous_base_rpc_url = System.get_env("BASE_RPC_URL")
    previous_rate_limits = Application.get_env(:siwa_server, :rate_limits, [])

    System.put_env("BASE_RPC_URL", TestRpcServer.owner_of(@wallet_address))
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

  test "nonce requests are rate limited by claimed identity and caller", %{conn: conn} do
    Application.put_env(:siwa_server, :rate_limits,
      siwa_nonce: [limit: 1, window_ms: 60_000],
      siwa_verify: [limit: 60, window_ms: 60_000],
      siwa_http_verify: [limit: 600, window_ms: 60_000]
    )

    body = %{
      "wallet_address" => @wallet_address,
      "chain_id" => @chain_id,
      "registry_address" => @registry_address,
      "token_id" => @token_id,
      "audience" => "platform"
    }

    assert %{"ok" => true} =
             conn
             |> recycle()
             |> json_post("/v1/agent/siwa/nonce", body)
             |> json_response(200)

    conn =
      conn
      |> recycle()
      |> json_post("/v1/agent/siwa/nonce", body)

    assert_retry_after(conn)

    assert %{"error" => %{"code" => "rate_limited", "retry_after_ms" => retry_after_ms}} =
             json_response(conn, 429)

    assert retry_after_ms > 0
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
        "x-agent-chain-id" => Integer.to_string(@chain_id),
        "x-agent-registry-address" => @registry_address,
        "x-agent-token-id" => @token_id
      }
    }

    first_conn =
      conn
      |> recycle()
      |> put_req_header("x-siwa-audience", "platform")
      |> json_post("/v1/agent/siwa/http-verify", payload)

    assert first_conn.status in [400, 401]

    conn =
      conn
      |> recycle()
      |> put_req_header("x-siwa-audience", "platform")
      |> json_post("/v1/agent/siwa/http-verify", payload)

    assert_retry_after(conn)
    assert %{"error" => %{"code" => "rate_limited"}} = json_response(conn, 429)
  end

  test "public SIWA endpoints complete the shared auth flow", %{conn: conn} do
    nonce_conn =
      json_post(conn, "/v1/agent/siwa/nonce", %{
        "wallet_address" => @wallet_address,
        "chain_id" => @chain_id,
        "registry_address" => @registry_address,
        "token_id" => @token_id,
        "audience" => "platform"
      })

    %{"data" => %{"nonce" => nonce}} = json_response(nonce_conn, 200)

    message = siwa_message(nonce)

    verify_conn =
      json_post(conn, "/v1/agent/siwa/verify", %{
        "wallet_address" => @wallet_address,
        "chain_id" => @chain_id,
        "registry_address" => @registry_address,
        "token_id" => @token_id,
        "audience" => "platform",
        "nonce" => nonce,
        "message" => message,
        "signature" => TestWallet.sign_message(message)
      })

    %{"data" => %{"receipt" => receipt}} = json_response(verify_conn, 200)

    body = Jason.encode!(%{"summary" => "Signed request", "details" => "accepted"})
    created = System.os_time(:second)
    expires = created + 120

    http_verify_conn =
      conn
      |> put_req_header("x-siwa-audience", "platform")
      |> json_post("/v1/agent/siwa/http-verify", %{
        "method" => "POST",
        "path" => "/v1/agent/bug-report",
        "headers" => signed_headers(receipt, body, created, expires),
        "body" => body
      })

    %{"data" => %{"agent_claims" => claims}} = json_response(http_verify_conn, 200)
    assert claims["wallet_address"] == @wallet_address
    assert claims["registry_address"] == @registry_address
    assert claims["token_id"] == @token_id
  end

  test "http verify enforces the requested app audience", %{conn: conn} do
    nonce_conn =
      json_post(conn, "/v1/agent/siwa/nonce", %{
        "wallet_address" => @wallet_address,
        "chain_id" => @chain_id,
        "registry_address" => @registry_address,
        "token_id" => @token_id,
        "audience" => "platform"
      })

    %{"data" => %{"nonce" => nonce}} = json_response(nonce_conn, 200)
    message = siwa_message(nonce)

    verify_conn =
      json_post(conn, "/v1/agent/siwa/verify", %{
        "wallet_address" => @wallet_address,
        "chain_id" => @chain_id,
        "registry_address" => @registry_address,
        "token_id" => @token_id,
        "audience" => "platform",
        "nonce" => nonce,
        "message" => message,
        "signature" => TestWallet.sign_message(message)
      })

    %{"data" => %{"receipt" => receipt}} = json_response(verify_conn, 200)

    body = "{}"
    created = System.os_time(:second)
    expires = created + 120

    conn =
      conn
      |> put_req_header("x-siwa-audience", "techtree")
      |> json_post("/v1/agent/siwa/http-verify", %{
        "method" => "POST",
        "path" => "/v1/agent/bug-report",
        "headers" => signed_headers(receipt, body, created, expires),
        "body" => body
      })

    %{"error" => %{"code" => code}} = json_response(conn, 401)
    assert code == "receipt_binding_mismatch"
  end

  test "public SIWA endpoints accept JSON requests", %{conn: conn} do
    conn =
      json_post(conn, "/v1/agent/siwa/nonce", %{
        "wallet_address" => @wallet_address,
        "chain_id" => @chain_id,
        "registry_address" => @registry_address,
        "token_id" => @token_id,
        "audience" => "platform"
      })

    %{"data" => %{"nonce" => nonce}} = json_response(conn, 200)
    assert is_binary(nonce)
  end

  test "public SIWA endpoints reject oversized JSON bodies", %{conn: conn} do
    body = Jason.encode!(%{"message" => String.duplicate("x", 70_000)})

    assert {413, _headers, response_body} =
             assert_error_sent(413, fn ->
               conn
               |> put_req_header("content-type", "application/json")
               |> post("/v1/agent/siwa/nonce", body)
             end)

    assert %{
             "ok" => false,
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
               |> post("/v1/agent/siwa/nonce", "not-json")
             end)

    assert %{
             "ok" => false,
             "error" => %{
               "code" => "unsupported_media_type",
               "message" => "Unsupported Media Type"
             }
           } = Jason.decode!(response_body)
  end

  test "public SIWA endpoints cast requests before verification", %{conn: conn} do
    conn =
      json_post(conn, "/v1/agent/siwa/nonce", %{
        "wallet_address" => @wallet_address,
        "chain_id" => Integer.to_string(@chain_id),
        "registry_address" => @registry_address,
        "token_id" => @token_id,
        "audience" => "platform"
      })

    assert %{
             "ok" => false,
             "error" => %{
               "code" => "invalid_request",
               "message" => "request body does not match the SIWA contract"
             }
           } = json_response(conn, 400)
  end

  test "public SIWA endpoints reject unsupported chain IDs before verification", %{conn: conn} do
    conn =
      json_post(conn, "/v1/agent/siwa/nonce", %{
        "wallet_address" => @wallet_address,
        "chain_id" => 1,
        "registry_address" => @registry_address,
        "token_id" => @token_id,
        "audience" => "platform"
      })

    assert %{
             "ok" => false,
             "error" => %{
               "code" => "invalid_request",
               "message" => "request body does not match the SIWA contract"
             }
           } = json_response(conn, 400)
  end

  test "verify returns the declared missing nonce error", %{conn: conn} do
    message = siwa_message("missing-nonce")

    conn =
      json_post(conn, "/v1/agent/siwa/verify", %{
        "wallet_address" => @wallet_address,
        "chain_id" => @chain_id,
        "registry_address" => @registry_address,
        "token_id" => @token_id,
        "audience" => "platform",
        "nonce" => "missing-nonce",
        "message" => message,
        "signature" => TestWallet.sign_message(message)
      })

    assert %{
             "ok" => false,
             "error" => %{
               "code" => "nonce_not_found",
               "message" => "nonce not found"
             }
           } = json_response(conn, 404)
  end

  test "verify returns the declared configuration error", %{conn: conn} do
    nonce = issue_nonce(conn)
    message = siwa_message(nonce)
    original_siwa = Application.get_env(:siwa_server, :siwa, [])

    Application.put_env(:siwa_server, :siwa, Keyword.put(original_siwa, :receipt_secret, " "))

    on_exit(fn ->
      Application.put_env(:siwa_server, :siwa, original_siwa)
    end)

    conn =
      json_post(conn, "/v1/agent/siwa/verify", %{
        "wallet_address" => @wallet_address,
        "chain_id" => @chain_id,
        "registry_address" => @registry_address,
        "token_id" => @token_id,
        "audience" => "platform",
        "nonce" => nonce,
        "message" => message,
        "signature" => TestWallet.sign_message(message)
      })

    assert %{
             "ok" => false,
             "error" => %{
               "code" => "siwa_not_configured",
               "message" => "SIWA receipt secret is not configured"
             }
           } = json_response(conn, 500)
  end

  test "verify returns the declared ownership lookup error", %{conn: conn} do
    System.put_env("BASE_RPC_URL", TestRpcServer.invalid_response())

    nonce = issue_nonce(conn)
    message = siwa_message(nonce)

    conn =
      json_post(conn, "/v1/agent/siwa/verify", %{
        "wallet_address" => @wallet_address,
        "chain_id" => @chain_id,
        "registry_address" => @registry_address,
        "token_id" => @token_id,
        "audience" => "platform",
        "nonce" => nonce,
        "message" => message,
        "signature" => TestWallet.sign_message(message)
      })

    assert %{
             "ok" => false,
             "error" => %{
               "code" => "agent_identity_lookup_failed",
               "message" => message
             }
           } = json_response(conn, 502)

    assert message =~ "could not verify agent ownership"
  end

  test "http verify returns the declared configuration error", %{conn: conn} do
    receipt = issue_verified_receipt(conn)
    body = "{}"
    created = System.os_time(:second)
    expires = created + 120
    original_siwa = Application.get_env(:siwa_server, :siwa, [])

    Application.put_env(:siwa_server, :siwa, Keyword.put(original_siwa, :receipt_secret, " "))

    on_exit(fn ->
      Application.put_env(:siwa_server, :siwa, original_siwa)
    end)

    conn =
      conn
      |> put_req_header("x-siwa-audience", "platform")
      |> json_post("/v1/agent/siwa/http-verify", %{
        "method" => "POST",
        "path" => "/v1/agent/bug-report",
        "headers" => signed_headers(receipt, body, created, expires),
        "body" => body
      })

    assert %{
             "ok" => false,
             "error" => %{
               "code" => "siwa_not_configured",
               "message" => "SIWA receipt secret is not configured"
             }
           } = json_response(conn, 500)
  end

  test "discovery endpoints expose health, metrics, and the services contract", %{conn: conn} do
    assert response(get(conn, "/"), 200) == "ok"
    assert response(get(conn, "/healthz"), 200) == "ok"

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

    metrics = response(get(conn, "/metrics"), 200)
    assert metrics =~ "siwa_server"

    contract = response(get(conn, "/regent-services-contract.openapiv3.yaml"), 200)
    assert contract =~ "Regent Shared Services Contract"
    assert contract =~ "/v1/agent/siwa/nonce"
    assert contract =~ "BaseChainId"
    assert contract =~ "SIWA nonce was not found"
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
               "/v1/agent/siwa/nonce",
               "/v1/agent/siwa/verify",
               "/v1/agent/siwa/http-verify",
               "/internal/keyring/health",
               "/internal/keyring/create-wallet",
               "/internal/keyring/has-wallet",
               "/internal/keyring/get-address",
               "/internal/keyring/sign-message",
               "/internal/keyring/sign-raw-message",
               "/internal/keyring/sign-transaction",
               "/internal/keyring/sign-authorization"
             ])

    assert operation_response_codes(contract, "/v1/agent/siwa/nonce", "post") ==
             MapSet.new(~w(200 400 413 415 429))

    assert operation_response_codes(contract, "/v1/agent/siwa/verify", "post") ==
             MapSet.new(~w(200 400 401 404 413 415 429 500 502))

    assert operation_response_codes(contract, "/v1/agent/siwa/http-verify", "post") ==
             MapSet.new(~w(200 400 401 409 413 415 429 500))

    assert operation_response_codes(contract, "/internal/keyring/sign-authorization", "post") ==
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

  defp siwa_message(nonce) do
    """
    regent.cx wants you to sign in with your Agent account:
    #{@wallet_address}

    Sign in to platform.

    URI: https://regent.cx/v1/agent/siwa/verify
    Version: 1
    Agent ID: #{@token_id}
    Agent Registry: eip155:#{@chain_id}:#{@registry_address}
    Chain ID: #{@chain_id}
    Nonce: #{nonce}
    Issued At: 2026-04-16T00:00:00Z
    """
    |> String.trim()
  end

  defp json_post(conn, path, params) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(params))
  end

  defp issue_nonce(conn) do
    conn =
      json_post(conn, "/v1/agent/siwa/nonce", %{
        "wallet_address" => @wallet_address,
        "chain_id" => @chain_id,
        "registry_address" => @registry_address,
        "token_id" => @token_id,
        "audience" => "platform"
      })

    %{"data" => %{"nonce" => nonce}} = json_response(conn, 200)
    nonce
  end

  defp issue_verified_receipt(conn) do
    nonce = issue_nonce(conn)
    message = siwa_message(nonce)

    conn =
      json_post(conn, "/v1/agent/siwa/verify", %{
        "wallet_address" => @wallet_address,
        "chain_id" => @chain_id,
        "registry_address" => @registry_address,
        "token_id" => @token_id,
        "audience" => "platform",
        "nonce" => nonce,
        "message" => message,
        "signature" => TestWallet.sign_message(message)
      })

    %{"data" => %{"receipt" => receipt}} = json_response(conn, 200)
    receipt
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

  defp signed_headers(receipt, body, created, expires) do
    headers = %{
      "x-siwa-receipt" => receipt,
      "x-key-id" => @wallet_address,
      "x-timestamp" => Integer.to_string(created),
      "x-agent-wallet-address" => @wallet_address,
      "x-agent-chain-id" => Integer.to_string(@chain_id),
      "x-agent-registry-address" => @registry_address,
      "x-agent-token-id" => @token_id,
      "content-digest" => SiwaServer.Siwa.content_digest_for_body(body)
    }

    components = [
      "@method",
      "@path",
      "x-siwa-receipt",
      "x-key-id",
      "x-timestamp",
      "x-agent-wallet-address",
      "x-agent-chain-id",
      "x-agent-registry-address",
      "x-agent-token-id",
      "content-digest"
    ]

    signature_params =
      "(#{Enum.map_join(components, " ", &~s("#{&1}"))})" <>
        ";created=#{created}" <>
        ";expires=#{expires}" <>
        ~s(;nonce="req-#{System.unique_integer([:positive])}") <>
        ~s(;keyid="#{@wallet_address}")

    signing_message =
      components
      |> Enum.map(fn component ->
        value =
          case component do
            "@method" -> "post"
            "@path" -> "/v1/agent/bug-report"
            header_name -> Map.fetch!(headers, header_name)
          end

        ~s("#{component}": #{value})
      end)
      |> Kernel.++([~s("@signature-params": #{signature_params})])
      |> Enum.join("\n")

    signature =
      TestWallet.sign_message(signing_message)
      |> signature_payload()

    headers
    |> Map.put("signature-input", "sig1=#{signature_params}")
    |> Map.put("signature", "sig1=:#{signature}:")
  end

  defp signature_payload("0x" <> hex) do
    hex
    |> Base.decode16!(case: :mixed)
    |> Base.encode64()
  end

  defp assert_retry_after(conn) do
    assert [value] = get_resp_header(conn, "retry-after")
    assert String.to_integer(value) > 0
  end
end
