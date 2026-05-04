defmodule SiwaServer.SiwaTest do
  use SiwaServer.DataCase, async: false

  alias SiwaServer.{Ethereum, Repo, RuntimeConfig, Siwa, TestRpcServer, TestWallet}

  @wallet_address TestWallet.address()
  @chain_id 8453
  @registry_address "0x3333333333333333333333333333333333333333"
  @token_id "77"

  setup do
    original_base_rpc_url = System.get_env("BASE_RPC_URL")
    System.put_env("BASE_RPC_URL", TestRpcServer.owner_of(@wallet_address))

    on_exit(fn ->
      restore_env("BASE_RPC_URL", original_base_rpc_url)
    end)

    :ok
  end

  test "signed requests reject expired signature windows" do
    receipt = verified_receipt()
    body = Jason.encode!(%{"summary" => "Expired request", "details" => "body binding"})
    created = System.os_time(:second) - 120
    expires = created + 30

    assert {:error, {401, "http_signature_invalid", message}} =
             verify_http_request(%{
               "method" => "POST",
               "path" => "/v1/agent/bug-report",
               "headers" => signed_headers(receipt, body, created, expires),
               "body" => body
             })

    assert message =~ "expired"
  end

  test "signed requests reject stale signature windows" do
    receipt = verified_receipt()
    body = Jason.encode!(%{"summary" => "Stale request", "details" => "body binding"})
    created = System.os_time(:second) - RuntimeConfig.siwa_http_signature_tolerance_seconds() - 1
    expires = System.os_time(:second) + 30

    assert {:error, {401, "http_signature_invalid", message}} =
             verify_http_request(%{
               "method" => "POST",
               "path" => "/v1/agent/bug-report",
               "headers" => signed_headers(receipt, body, created, expires),
               "body" => body
             })

    assert message =~ "too old"
  end

  test "signed requests reject a mismatched body digest" do
    receipt = verified_receipt()
    body = Jason.encode!(%{"summary" => "Digest mismatch", "details" => "body binding"})
    created = System.os_time(:second)
    expires = created + 120

    headers =
      receipt
      |> signed_headers(body, created, expires)
      |> Map.put("content-digest", Siwa.content_digest_for_body("different-body"))

    assert {:error, {401, "http_body_binding_invalid", message}} =
             verify_http_request(%{
               "method" => "POST",
               "path" => "/v1/agent/bug-report",
               "headers" => headers,
               "body" => body
             })

    assert message =~ "does not match"
  end

  test "signed requests require the verified request body when content-digest is present" do
    receipt = verified_receipt()
    body = Jason.encode!(%{"summary" => "Missing body", "details" => "body binding"})
    created = System.os_time(:second)
    expires = created + 120

    assert {:error, {401, "http_body_binding_missing", message}} =
             verify_http_request(%{
               "method" => "POST",
               "path" => "/v1/agent/bug-report",
               "headers" => signed_headers(receipt, body, created, expires)
             })

    assert message =~ "request body is required"
  end

  test "signed requests reject unverified registry and token headers" do
    receipt = verified_receipt()
    body = Jason.encode!(%{"summary" => "Unverified claim", "details" => "blocked"})
    created = System.os_time(:second)
    expires = created + 120

    headers =
      signed_headers(receipt, body, created, expires, %{
        "x-agent-registry-address" => "0x2222222222222222222222222222222222222222",
        "x-agent-token-id" => "99"
      })

    assert {:error, {401, "receipt_binding_mismatch", message}} =
             verify_http_request(%{
               "method" => "POST",
               "path" => "/v1/agent/bug-report",
               "headers" => headers,
               "body" => body
             })

    assert message =~ "does not match"
  end

  test "signed requests accept checksum-cased registry headers when the receipt matches" do
    receipt = verified_receipt()
    body = Jason.encode!(%{"summary" => "Checksum case", "details" => "accepted"})
    created = System.os_time(:second)
    expires = created + 120

    headers =
      signed_headers(receipt, body, created, expires, %{
        "x-agent-registry-address" => String.upcase(@registry_address)
      })

    assert {:ok, %{"data" => %{"verified" => true}}} =
             verify_http_request(%{
               "method" => "POST",
               "path" => "/v1/agent/bug-report",
               "headers" => headers,
               "body" => body
             })
  end

  test "signed requests reject malformed header maps" do
    receipt = verified_receipt()
    body = Jason.encode!(%{"summary" => "Malformed headers", "details" => "blocked"})
    created = System.os_time(:second)
    expires = created + 120

    bad_headers =
      signed_headers(receipt, body, created, expires)
      |> Map.put("x-agent-chain-id", 8453)

    assert {:error, {400, "invalid_headers", message}} =
             verify_http_request(%{
               "method" => "POST",
               "path" => "/v1/agent/bug-report",
               "headers" => bad_headers,
               "body" => body
             })

    assert message =~ "string headers"
  end

  test "signed requests reject a malformed chain header without crashing" do
    receipt = verified_receipt()
    body = Jason.encode!(%{"summary" => "Malformed chain", "details" => "blocked"})
    created = System.os_time(:second)
    expires = created + 120

    headers =
      signed_headers(receipt, body, created, expires)
      |> Map.put("x-agent-chain-id", "not-a-number")

    assert {:error, {401, "receipt_binding_mismatch", message}} =
             verify_http_request(%{
               "method" => "POST",
               "path" => "/v1/agent/bug-report",
               "headers" => headers,
               "body" => body
             })

    assert message =~ "x-agent-chain-id"
  end

  test "signed requests reject duplicate normalized header names" do
    receipt = verified_receipt()
    body = Jason.encode!(%{"summary" => "Duplicate headers", "details" => "blocked"})
    created = System.os_time(:second)
    expires = created + 120

    headers =
      signed_headers(receipt, body, created, expires)
      |> Map.put("X-Key-Id", @wallet_address)

    assert {:error, {400, "invalid_headers", message}} =
             verify_http_request(%{
               "method" => "POST",
               "path" => "/v1/agent/bug-report",
               "headers" => headers,
               "body" => body
             })

    assert message =~ "string headers"
  end

  test "signed requests reject a receipt for the wrong audience" do
    receipt = verified_receipt("techtree")
    body = Jason.encode!(%{"summary" => "Audience mismatch", "details" => "blocked"})
    created = System.os_time(:second)
    expires = created + 120

    assert {:error, {401, "receipt_binding_mismatch", message}} =
             verify_http_request(
               %{
                 "method" => "POST",
                 "path" => "/v1/agent/bug-report",
                 "headers" => signed_headers(receipt, body, created, expires),
                 "body" => body
               },
               audience: "platform"
             )

    assert message =~ "audience"
  end

  test "shared sign-in rejects a wallet that does not own the claimed agent identity" do
    original_base_rpc_url = System.get_env("BASE_RPC_URL")

    System.put_env(
      "BASE_RPC_URL",
      TestRpcServer.owner_of("0x1111111111111111111111111111111111111111")
    )

    on_exit(fn ->
      restore_env("BASE_RPC_URL", original_base_rpc_url)
    end)

    assert {:ok, %{"data" => %{"nonce" => nonce}}} =
             Siwa.issue_nonce(%{
               "wallet_address" => @wallet_address,
               "chain_id" => @chain_id,
               "registry_address" => @registry_address,
               "token_id" => @token_id,
               "audience" => "platform"
             })

    message = siwa_message(nonce)
    signature = TestWallet.sign_message(message)

    assert {:error, {401, "agent_identity_not_owned", message}} =
             Siwa.verify_session(%{
               "wallet_address" => @wallet_address,
               "chain_id" => @chain_id,
               "registry_address" => @registry_address,
               "token_id" => @token_id,
               "audience" => "platform",
               "nonce" => nonce,
               "message" => message,
               "signature" => signature
             })

    assert message =~ "does not own"
  end

  test "shared sign-in rejects malformed canonical SIWA messages" do
    assert {:ok, %{"data" => %{"nonce" => nonce}}} =
             Siwa.issue_nonce(%{
               "wallet_address" => @wallet_address,
               "chain_id" => @chain_id,
               "registry_address" => @registry_address,
               "token_id" => @token_id,
               "audience" => "platform"
             })

    bad_message =
      """
      regent.cx wants you to sign in with your Agent account:
      #{@wallet_address}

      URI: https://wrong.example.com/v1/agent/siwa/verify
      Version: 1
      Agent ID: #{@token_id}
      Agent Registry: eip155:#{@chain_id}:#{@registry_address}
      Chain ID: #{@chain_id}
      Nonce: #{nonce}
      Issued At: 2026-04-16T00:00:00Z
      """
      |> String.trim()

    assert {:error, {401, "signature_invalid", message}} =
             Siwa.verify_session(%{
               "wallet_address" => @wallet_address,
               "chain_id" => @chain_id,
               "registry_address" => @registry_address,
               "token_id" => @token_id,
               "audience" => "platform",
               "nonce" => nonce,
               "message" => bad_message,
               "signature" => TestWallet.sign_message(bad_message)
             })

    assert message =~ "canonical SIWA format"
  end

  test "shared sign-in rejects messages that do not name the requested app audience" do
    assert {:ok, %{"data" => %{"nonce" => nonce}}} =
             Siwa.issue_nonce(%{
               "wallet_address" => @wallet_address,
               "chain_id" => @chain_id,
               "registry_address" => @registry_address,
               "token_id" => @token_id,
               "audience" => "platform"
             })

    bad_message = siwa_message(nonce, "techtree")

    assert {:error, {401, "signature_invalid", message}} =
             Siwa.verify_session(%{
               "wallet_address" => @wallet_address,
               "chain_id" => @chain_id,
               "registry_address" => @registry_address,
               "token_id" => @token_id,
               "audience" => "platform",
               "nonce" => nonce,
               "message" => bad_message,
               "signature" => TestWallet.sign_message(bad_message)
             })

    assert message =~ "does not match"
  end

  test "shared sign-in rejects duplicate SIWA fields" do
    assert {:ok, %{"data" => %{"nonce" => nonce}}} =
             Siwa.issue_nonce(%{
               "wallet_address" => @wallet_address,
               "chain_id" => @chain_id,
               "registry_address" => @registry_address,
               "token_id" => @token_id,
               "audience" => "platform"
             })

    bad_message =
      """
      regent.cx wants you to sign in with your Agent account:
      #{@wallet_address}

      URI: https://regent.cx/v1/agent/siwa/verify
      Version: 1
      Agent ID: #{@token_id}
      Agent Registry: eip155:#{@chain_id}:#{@registry_address}
      Chain ID: #{@chain_id}
      Nonce: #{nonce}
      Nonce: duplicate
      Issued At: 2026-04-16T00:00:00Z
      """
      |> String.trim()

    assert {:error, {401, "signature_invalid", message}} =
             Siwa.verify_session(%{
               "wallet_address" => @wallet_address,
               "chain_id" => @chain_id,
               "registry_address" => @registry_address,
               "token_id" => @token_id,
               "audience" => "platform",
               "nonce" => nonce,
               "message" => bad_message,
               "signature" => TestWallet.sign_message(bad_message)
             })

    assert message =~ "canonical SIWA format"
  end

  test "shared sign-in rejects extra SIWA fields" do
    assert {:ok, %{"data" => %{"nonce" => nonce}}} =
             Siwa.issue_nonce(%{
               "wallet_address" => @wallet_address,
               "chain_id" => @chain_id,
               "registry_address" => @registry_address,
               "token_id" => @token_id,
               "audience" => "platform"
             })

    bad_message =
      """
      regent.cx wants you to sign in with your Agent account:
      #{@wallet_address}

      URI: https://regent.cx/v1/agent/siwa/verify
      Version: 1
      Agent ID: #{@token_id}
      Agent Registry: eip155:#{@chain_id}:#{@registry_address}
      Chain ID: #{@chain_id}
      Nonce: #{nonce}
      Issued At: 2026-04-16T00:00:00Z
      Resources: https://example.com
      """
      |> String.trim()

    assert {:error, {401, "signature_invalid", message}} =
             Siwa.verify_session(%{
               "wallet_address" => @wallet_address,
               "chain_id" => @chain_id,
               "registry_address" => @registry_address,
               "token_id" => @token_id,
               "audience" => "platform",
               "nonce" => nonce,
               "message" => bad_message,
               "signature" => TestWallet.sign_message(bad_message)
             })

    assert message =~ "canonical SIWA format"
  end

  test "http verification fails closed when the receipt secret is missing" do
    receipt = verified_receipt()
    body = Jason.encode!(%{"summary" => "Missing secret", "details" => "blocked"})
    created = System.os_time(:second)
    expires = created + 120

    original = Application.get_env(:siwa_server, :siwa, [])
    Application.put_env(:siwa_server, :siwa, Keyword.delete(original, :receipt_secret))

    on_exit(fn ->
      Application.put_env(:siwa_server, :siwa, original)
    end)

    assert {:error, {500, "siwa_not_configured", message}} =
             verify_http_request(%{
               "method" => "POST",
               "path" => "/v1/agent/bug-report",
               "headers" => signed_headers(receipt, body, created, expires),
               "body" => body
             })

    assert message =~ "not configured"
  end

  test "verified agent claims expose the verified ERC-8004 identity" do
    receipt = verified_receipt()
    body = Jason.encode!(%{"summary" => "Signed request", "details" => "accepted"})
    created = System.os_time(:second)
    expires = created + 120

    assert {:ok, %{"data" => %{"agent_claims" => claims}}} =
             verify_http_request(%{
               "method" => "POST",
               "path" => "/v1/agent/bug-report",
               "headers" => signed_headers(receipt, body, created, expires),
               "body" => body
             })

    assert claims["wallet_address"] == @wallet_address
    assert claims["chain_id"] == @chain_id
    assert claims["registry_address"] == @registry_address
    assert claims["token_id"] == @token_id
  end

  test "signed requests keep replay protection for the full signature window" do
    receipt = verified_receipt()
    body = Jason.encode!(%{"summary" => "Replay window", "details" => "accepted once"})
    created = System.os_time(:second)
    expires = created + 600
    headers = signed_headers(receipt, body, created, expires)

    assert {:ok, _payload} =
             verify_http_request(%{
               "method" => "POST",
               "path" => "/v1/agent/bug-report",
               "headers" => headers,
               "body" => body
             })

    replay_key =
      "#{@wallet_address}|#{request_nonce(headers)}|POST|/v1/agent/bug-report|#{Siwa.content_digest_for_body(body)}"

    assert {:ok, %{rows: [[^replay_key, _expires_at]]}} =
             Repo.query(
               "SELECT replay_key, expires_at FROM siwa_request_replays WHERE replay_key = $1",
               [replay_key]
             )

    assert {:error, {409, "request_replayed", _message}} =
             verify_http_request(%{
               "method" => "POST",
               "path" => "/v1/agent/bug-report",
               "headers" => headers,
               "body" => body
             })
  end

  test "invalid request signatures do not consume replay protection" do
    receipt = verified_receipt()
    body = Jason.encode!(%{"summary" => "Bad signature", "details" => "does not burn replay"})
    created = System.os_time(:second)
    expires = created + 600
    headers = signed_headers(receipt, body, created, expires)
    bad_signature = "sig1=:#{Base.encode64(<<0::520>>)}:"

    assert {:error, {401, "signature_invalid", _message}} =
             verify_http_request(%{
               "method" => "POST",
               "path" => "/v1/agent/bug-report",
               "headers" => Map.put(headers, "signature", bad_signature),
               "body" => body
             })

    assert {:ok, _payload} =
             verify_http_request(%{
               "method" => "POST",
               "path" => "/v1/agent/bug-report",
               "headers" => headers,
               "body" => body
             })
  end

  test "signed requests allow only one concurrent use of the same signature" do
    receipt = test_receipt()
    body = Jason.encode!(%{"summary" => "Concurrent replay", "details" => "accepted once"})
    created = System.os_time(:second)
    expires = created + 600
    headers = signed_headers(receipt, body, created, expires)

    request = %{
      "method" => "POST",
      "path" => "/v1/agent/bug-report",
      "headers" => headers,
      "body" => body
    }

    results =
      1..20
      |> Task.async_stream(fn _ -> verify_http_request(request) end,
        max_concurrency: 20,
        timeout: 5_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, _payload}, &1)) == 1
    assert Enum.count(results, &match?({:error, {409, "request_replayed", _message}}, &1)) == 19
  end

  test "signed requests reject duplicate covered components" do
    receipt = verified_receipt()
    body = Jason.encode!(%{"summary" => "Duplicate components", "details" => "blocked"})
    created = System.os_time(:second)
    expires = created + 120

    components = [
      "@method",
      "@path",
      "x-siwa-receipt",
      "x-key-id",
      "x-key-id",
      "x-timestamp",
      "x-agent-wallet-address",
      "x-agent-chain-id",
      "x-agent-registry-address",
      "x-agent-token-id",
      "content-digest"
    ]

    assert {:error, {401, "http_signature_input_invalid", message}} =
             verify_http_request(%{
               "method" => "POST",
               "path" => "/v1/agent/bug-report",
               "headers" => signed_headers(receipt, body, created, expires, %{}, components),
               "body" => body
             })

    assert message =~ "signature-input"
  end

  test "signed requests reject unknown covered components" do
    receipt = verified_receipt()
    body = Jason.encode!(%{"summary" => "Unknown components", "details" => "blocked"})
    created = System.os_time(:second)
    expires = created + 120

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
      "content-digest",
      "x-extra-header"
    ]

    headers =
      signed_headers(
        receipt,
        body,
        created,
        expires,
        %{"x-extra-header" => "surprise"},
        components
      )

    assert {:error, {401, "http_signature_input_invalid", message}} =
             verify_http_request(%{
               "method" => "POST",
               "path" => "/v1/agent/bug-report",
               "headers" => headers,
               "body" => body
             })

    assert message =~ "signature-input"
  end

  test "signed requests reject missing covered components" do
    receipt = verified_receipt()
    body = Jason.encode!(%{"summary" => "Missing component", "details" => "blocked"})
    created = System.os_time(:second)
    expires = created + 120

    components = [
      "@method",
      "@path",
      "x-siwa-receipt",
      "x-key-id",
      "x-timestamp",
      "x-agent-wallet-address",
      "x-agent-chain-id",
      "x-agent-registry-address",
      "content-digest"
    ]

    assert {:error, {401, "http_required_components_missing", message}} =
             verify_http_request(%{
               "method" => "POST",
               "path" => "/v1/agent/bug-report",
               "headers" => signed_headers(receipt, body, created, expires, %{}, components),
               "body" => body
             })

    assert message =~ "covered components"
  end

  test "signed requests reject missing signed headers" do
    receipt = verified_receipt()
    body = Jason.encode!(%{"summary" => "Missing header", "details" => "blocked"})
    created = System.os_time(:second)
    expires = created + 120

    headers =
      receipt
      |> signed_headers(body, created, expires)
      |> Map.delete("x-key-id")

    assert {:error, {401, "http_headers_missing", message}} =
             verify_http_request(%{
               "method" => "POST",
               "path" => "/v1/agent/bug-report",
               "headers" => headers,
               "body" => body
             })

    assert message =~ "missing"
  end

  test "signed requests reject malformed signature payloads" do
    receipt = verified_receipt()
    body = Jason.encode!(%{"summary" => "Bad signature", "details" => "blocked"})
    created = System.os_time(:second)
    expires = created + 120

    headers =
      receipt
      |> signed_headers(body, created, expires)
      |> Map.put("signature", "sig1=:!!!!:")

    assert {:error, {401, "http_signature_invalid", message}} =
             verify_http_request(%{
               "method" => "POST",
               "path" => "/v1/agent/bug-report",
               "headers" => headers,
               "body" => body
             })

    assert message =~ "signature header"
  end

  test "signed requests reject reordered covered components when the signature is not rebuilt" do
    receipt = verified_receipt()
    body = Jason.encode!(%{"summary" => "Reordered", "details" => "blocked"})
    created = System.os_time(:second)
    expires = created + 120

    headers = signed_headers(receipt, body, created, expires)

    reordered_components =
      ~s|("@path" "@method" "x-siwa-receipt" "x-key-id" "x-timestamp" "x-agent-wallet-address" "x-agent-chain-id" "x-agent-registry-address" "x-agent-token-id" "content-digest")|

    headers =
      Map.update!(headers, "signature-input", fn signature_input ->
        Regex.replace(~r/^sig1=\([^)]*\)/, signature_input, "sig1=#{reordered_components}")
      end)

    assert {:error, {401, "signature_invalid", message}} =
             verify_http_request(%{
               "method" => "POST",
               "path" => "/v1/agent/bug-report",
               "headers" => headers,
               "body" => body
             })

    assert message =~ "signature"
  end

  test "json rpc rejects invalid responses cleanly" do
    url = TestRpcServer.invalid_response()

    assert {:error, "invalid rpc response"} = Ethereum.json_rpc(url, "eth_call", [])
  end

  test "json rpc times out cleanly" do
    url = TestRpcServer.timeout()

    with_app_env(:siwa_server, :ethereum_rpc_timeout_ms, 50, fn ->
      assert {:error, "rpc request timed out"} = Ethereum.json_rpc(url, "eth_call", [])
    end)
  end

  test "ethereum rpc telemetry uses bounded result labels" do
    ref = make_ref()
    handler_id = "siwa-test-ethereum-rpc-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:siwa_server, :ethereum, :rpc, :stop],
        fn _event, _measurements, metadata, _config ->
          send(parent, {ref, metadata.result})
        end,
        nil
      )

    try do
      assert {:ok, "0x2105"} = Ethereum.json_rpc(TestRpcServer.chain_id(8453), "eth_chainId", [])
      assert_receive {^ref, :success}

      assert {:error, "invalid rpc response"} =
               Ethereum.json_rpc(TestRpcServer.invalid_response(), "eth_chainId", [])

      assert_receive {^ref, :bad_response}

      assert {:error, "provider failed"} =
               Ethereum.json_rpc(TestRpcServer.rpc_error("provider failed"), "eth_call", [])

      assert_receive {^ref, :provider_error}

      with_app_env(:siwa_server, :ethereum_rpc_timeout_ms, 50, fn ->
        assert {:error, "rpc request timed out"} =
                 Ethereum.json_rpc(TestRpcServer.timeout(), "eth_call", [])
      end)

      assert_receive {^ref, :timeout}
    after
      :telemetry.detach(handler_id)
    end
  end

  test "ethereum deterministic hashes do not shell out" do
    assert {:ok, "0x0000000000000000000000000000000000000000000000000000000000000000"} =
             Ethereum.namehash("")

    assert {:ok, "0x93cdeb708b7545dc668eb9280176169d1c33cfd8ed6f04690a0bcc88a93fc4ae"} =
             Ethereum.namehash("eth")

    assert {:ok, "0xde9b09fd7c5f901e23a3f19fecc54828e9c848539801e86591bd9801b019f84f"} =
             Ethereum.namehash("foo.eth")

    assert {:ok, "0x1c8aff950685c2ed4bc3174f3472287b56d9517b9c948127319a09a7a36deac8"} =
             Ethereum.synthetic_tx_hash("hello")

    assert {:error, "invalid ENS name"} = Ethereum.namehash("foo..eth")
  end

  test "ethereum signatures are verified without shelling out" do
    message = "hello"
    signature = TestWallet.sign_message(message)

    assert :ok = Ethereum.verify_signature(@wallet_address, message, signature)

    assert {:error, "Invalid signature"} =
             Ethereum.verify_signature(
               "0x1111111111111111111111111111111111111111",
               message,
               signature
             )

    assert {:error, "Invalid signature"} =
             Ethereum.verify_signature(@wallet_address, message, "not-a-signature")
  end

  test "ethereum signatures verify concurrently without the keyring" do
    message = "concurrent signature check"
    signature = TestWallet.sign_message(message)

    results =
      1..20
      |> Task.async_stream(
        fn _ -> Ethereum.verify_signature(@wallet_address, message, signature) end,
        max_concurrency: 20,
        timeout: 5_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert results == List.duplicate(:ok, 20)
  end

  test "owner lookups time out cleanly" do
    with_app_env(:siwa_server, :ethereum_rpc_timeout_ms, 50, fn ->
      assert {:error, "rpc request timed out"} =
               Ethereum.owner_of(@registry_address, @token_id, rpc_url: TestRpcServer.timeout())
    end)
  end

  defp verified_receipt(audience \\ "regents.sh") do
    assert {:ok, %{"data" => %{"nonce" => nonce}}} =
             Siwa.issue_nonce(%{
               "wallet_address" => @wallet_address,
               "chain_id" => @chain_id,
               "registry_address" => @registry_address,
               "token_id" => @token_id,
               "audience" => audience
             })

    message = siwa_message(nonce, audience)
    signature = TestWallet.sign_message(message)

    assert {:ok, %{"data" => %{"receipt" => receipt}}} =
             Siwa.verify_session(%{
               "wallet_address" => @wallet_address,
               "chain_id" => @chain_id,
               "registry_address" => @registry_address,
               "token_id" => @token_id,
               "audience" => audience,
               "nonce" => nonce,
               "message" => message,
               "signature" => signature
             })

    receipt
  end

  defp test_receipt(audience \\ "regents.sh") do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    secret = :siwa_server |> Application.fetch_env!(:siwa) |> Keyword.fetch!(:receipt_secret)

    assert {:ok, receipt} =
             Elixir.Siwa.create_receipt(
               %{
                 "typ" => "siwa_receipt",
                 "jti" => Ecto.UUID.generate(),
                 "sub" => @wallet_address,
                 "aud" => audience,
                 "chain_id" => @chain_id,
                 "nonce" => "receipt-#{System.unique_integer([:positive])}",
                 "key_id" => @wallet_address,
                 "registry_address" => @registry_address,
                 "token_id" => @token_id
               },
               receipt_secret: secret,
               now: now,
               ttl_ms: 3_600_000
             )

    receipt.token
  end

  defp siwa_message(nonce, audience \\ "platform") do
    """
    regent.cx wants you to sign in with your Agent account:
    #{@wallet_address}

    Sign in to #{audience}.

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

  defp signed_headers(
         receipt,
         body,
         created,
         expires,
         extra_headers \\ %{},
         components_override \\ nil
       ) do
    base_headers = %{
      "x-siwa-receipt" => receipt,
      "x-key-id" => @wallet_address,
      "x-timestamp" => Integer.to_string(created),
      "x-agent-wallet-address" => @wallet_address,
      "x-agent-chain-id" => Integer.to_string(@chain_id),
      "x-agent-registry-address" => @registry_address,
      "x-agent-token-id" => @token_id,
      "content-digest" => Siwa.content_digest_for_body(body)
    }

    headers = Map.merge(base_headers, extra_headers)

    components =
      components_override ||
        [
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

  defp request_nonce(headers) do
    [_, nonce] = Regex.run(~r/;nonce="([^"]+)"/, Map.fetch!(headers, "signature-input"))
    nonce
  end

  defp verify_http_request(params, opts \\ []) do
    Siwa.verify_http_request(params, Keyword.put_new(opts, :audience, "regents.sh"))
  end

  defp signature_payload("0x" <> hex) do
    hex
    |> Base.decode16!(case: :mixed)
    |> Base.encode64()
  end

  defp with_app_env(app, key, value, fun) do
    original = Application.get_env(app, key, :__missing__)
    Application.put_env(app, key, value)

    try do
      fun.()
    after
      case original do
        :__missing__ -> Application.delete_env(app, key)
        _ -> Application.put_env(app, key, original)
      end
    end
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
