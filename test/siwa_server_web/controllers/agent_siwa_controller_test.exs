defmodule SiwaServerWeb.AgentSiwaControllerTest do
  use SiwaServerWeb.ConnCase, async: false

  alias SiwaServer.TestEthereumAdapter

  @wallet_address "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266"
  @chain_id 84_532
  @registry_address "0x3333333333333333333333333333333333333333"
  @token_id "77"

  setup do
    TestEthereumAdapter.put_owner(@registry_address, @token_id, @wallet_address)

    on_exit(fn ->
      TestEthereumAdapter.delete_owner(@registry_address, @token_id)
    end)

    :ok
  end

  test "public SIWA endpoints complete the shared auth flow", %{conn: conn} do
    nonce_conn =
      post(conn, "/v1/agent/siwa/nonce", %{
        "wallet_address" => @wallet_address,
        "chain_id" => @chain_id,
        "registry_address" => @registry_address,
        "token_id" => @token_id,
        "audience" => "platform"
      })

    %{"data" => %{"nonce" => nonce}} = json_response(nonce_conn, 200)

    message = siwa_message(nonce)

    verify_conn =
      post(conn, "/v1/agent/siwa/verify", %{
        "wallet_address" => @wallet_address,
        "chain_id" => @chain_id,
        "registry_address" => @registry_address,
        "token_id" => @token_id,
        "nonce" => nonce,
        "message" => message,
        "signature" => TestEthereumAdapter.sign_message(@wallet_address, message)
      })

    %{"data" => %{"receipt" => receipt}} = json_response(verify_conn, 200)

    body = Jason.encode!(%{"summary" => "Signed request", "details" => "accepted"})
    created = System.os_time(:second)
    expires = created + 120

    http_verify_conn =
      post(conn, "/v1/agent/siwa/http-verify", %{
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
      post(conn, "/v1/agent/siwa/nonce", %{
        "wallet_address" => @wallet_address,
        "chain_id" => @chain_id,
        "registry_address" => @registry_address,
        "token_id" => @token_id,
        "audience" => "platform"
      })

    %{"data" => %{"nonce" => nonce}} = json_response(nonce_conn, 200)
    message = siwa_message(nonce)

    verify_conn =
      post(conn, "/v1/agent/siwa/verify", %{
        "wallet_address" => @wallet_address,
        "chain_id" => @chain_id,
        "registry_address" => @registry_address,
        "token_id" => @token_id,
        "nonce" => nonce,
        "message" => message,
        "signature" => TestEthereumAdapter.sign_message(@wallet_address, message)
      })

    %{"data" => %{"receipt" => receipt}} = json_response(verify_conn, 200)

    body = "{}"
    created = System.os_time(:second)
    expires = created + 120

    conn =
      conn
      |> put_req_header("x-siwa-audience", "techtree")
      |> post("/v1/agent/siwa/http-verify", %{
        "method" => "POST",
        "path" => "/v1/agent/bug-report",
        "headers" => signed_headers(receipt, body, created, expires),
        "body" => body
      })

    %{"error" => %{"code" => code}} = json_response(conn, 401)
    assert code == "receipt_binding_mismatch"
  end

  test "discovery endpoints expose health, metrics, and the services contract", %{conn: conn} do
    assert response(get(conn, "/healthz"), 200) == "ok"

    metrics = response(get(conn, "/metrics"), 200)
    assert metrics =~ "siwa_server"

    contract = response(get(conn, "/regent-services-contract.openapiv3.yaml"), 200)
    assert contract =~ "Regent Shared Services Contract"
    assert contract =~ "/v1/agent/siwa/nonce"
  end

  defp siwa_message(nonce) do
    """
    regent.cx wants you to sign in with your Ethereum account:
    #{@wallet_address}

    URI: https://regent.cx/v1/agent/siwa/verify
    Version: 1
    Chain ID: #{@chain_id}
    Nonce: #{nonce}
    Issued At: 2026-04-16T00:00:00Z
    """
    |> String.trim()
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
      TestEthereumAdapter.sign_message(@wallet_address, signing_message)
      |> Base.encode64()

    headers
    |> Map.put("signature-input", "sig1=#{signature_params}")
    |> Map.put("signature", "sig1=:#{signature}:")
  end
end
