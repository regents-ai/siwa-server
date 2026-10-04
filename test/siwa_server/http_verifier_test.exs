defmodule SiwaServer.HttpVerifierTest do
  use SiwaServer.DataCase, async: false

  alias SiwaServer.{Ethereum, Repo, RuntimeConfig, TestRpcServer, TestWallet}
  alias SiwaServer.Siwa.HttpVerifier

  @wallet_address TestWallet.address()
  @chain_id 8453

  setup do
    previous_siwa = Application.get_env(:siwa_server, :siwa)
    previous_base_rpc_url = System.get_env("BASE_RPC_URL")

    Application.put_env(
      :siwa_server,
      :siwa,
      Keyword.put(previous_siwa, :wallet_origins, %{
        "patchbay" => "https://patchbay.help",
        "techtree" => "https://techtree.sh"
      })
    )

    System.put_env("BASE_RPC_URL", TestRpcServer.wallet_answers({true, <<>>}))

    on_exit(fn ->
      Application.put_env(:siwa_server, :siwa, previous_siwa)
      restore_env("BASE_RPC_URL", previous_base_rpc_url)
    end)

    :ok
  end

  test "signed requests reject expired signature windows" do
    receipt = receipt()
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
    receipt = receipt()
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
    receipt = receipt()
    body = Jason.encode!(%{"summary" => "Digest mismatch", "details" => "body binding"})
    created = System.os_time(:second)
    expires = created + 120

    headers =
      receipt
      |> signed_headers(body, created, expires)
      |> Map.put("content-digest", Elixir.Siwa.content_digest_for_body("different-body"))

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
    receipt = receipt()
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

  test "signed requests from a smart wallet are accepted once Base approves the signature" do
    receipt = receipt()
    body = Jason.encode!(%{"summary" => "Smart wallet", "details" => "approved on Base"})
    created = System.os_time(:second)
    headers = signed_headers(receipt, body, created, created + 120)

    System.put_env(
      "BASE_RPC_URL",
      TestRpcServer.wallet_answers({true, TestRpcServer.erc1271_approval()})
    )

    assert {:ok, %{"data" => %{"verified" => true}}} =
             verify_http_request(%{
               "method" => "POST",
               "path" => "/v1/agent/bug-report",
               "headers" => Map.put(headers, "signature", smart_wallet_signature()),
               "body" => body
             })
  end

  test "a signed request Base cannot check answers 502 and leaves the request unused" do
    receipt = receipt()
    body = Jason.encode!(%{"summary" => "Lookup failure", "details" => "retry works"})
    created = System.os_time(:second)
    headers = signed_headers(receipt, body, created, created + 120)
    request = %{"method" => "POST", "path" => "/v1/agent/bug-report", "body" => body}

    System.put_env("BASE_RPC_URL", TestRpcServer.rpc_error())

    smart_wallet_headers = Map.put(headers, "signature", smart_wallet_signature())

    assert {:error, {502, "signature_lookup_failed", _message}} =
             verify_http_request(Map.put(request, "headers", smart_wallet_headers))

    assert {:ok, %{"data" => %{"verified" => true}}} =
             verify_http_request(Map.put(request, "headers", headers))
  end

  test "signed requests reject malformed header maps" do
    receipt = receipt()
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
    receipt = receipt()
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
    receipt = receipt()
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
    receipt = receipt("techtree")
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
               audience: "patchbay"
             )

    assert message =~ "audience"
  end

  test "http verification fails closed when the receipt secret is missing" do
    receipt = receipt()
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

  test "signed requests bind query values in the path component" do
    receipt = receipt()
    body = Jason.encode!(%{"summary" => "Query-bound request", "details" => "accepted"})
    created = System.os_time(:second)
    expires = created + 120
    signed_path = "/v1/agent/bug-report?status=open&limit=25"

    headers = signed_headers(receipt, body, created, expires, %{}, nil, signed_path)

    assert {:error, {401, "signature_invalid", _message}} =
             verify_http_request(%{
               "method" => "POST",
               "path" => "/v1/agent/bug-report?status=closed&limit=25",
               "headers" => headers,
               "body" => body
             })

    assert {:ok, _payload} =
             verify_http_request(%{
               "method" => "POST",
               "path" => signed_path,
               "headers" => headers,
               "body" => body
             })
  end

  test "signed requests keep replay protection for the full signature window" do
    receipt = receipt()
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
      Jason.encode!([
        "wallet",
        @wallet_address,
        @chain_id,
        "patchbay",
        request_nonce(headers),
        "POST",
        "/v1/agent/bug-report",
        Elixir.Siwa.content_digest_for_body(body)
      ])

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
    receipt = receipt()
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
    receipt = receipt()
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
    receipt = receipt()
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
    receipt = receipt()
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
    receipt = receipt()
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
    receipt = receipt()
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
    receipt = receipt()
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
    receipt = receipt()
    body = Jason.encode!(%{"summary" => "Reordered", "details" => "blocked"})
    created = System.os_time(:second)
    expires = created + 120

    headers = signed_headers(receipt, body, created, expires)

    reordered_components =
      ~s|("@path" "@method" "x-siwa-receipt" "x-key-id" "x-timestamp" "x-agent-wallet-address" "x-agent-chain-id" "content-digest")|

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

  test "ethereum signatures are verified without shelling out" do
    message = "hello"
    signature = TestWallet.sign_message(message)

    assert {:ok, :eoa_recovery} =
             Ethereum.verify_signature(@wallet_address, message, signature, @chain_id)

    assert {:error, :signature_invalid} =
             Ethereum.verify_signature(
               "0x1111111111111111111111111111111111111111",
               message,
               signature,
               @chain_id
             )

    assert {:error, :signature_invalid} =
             Ethereum.verify_signature(@wallet_address, message, "not-a-signature", @chain_id)
  end

  test "ethereum signatures verify concurrently without the keyring" do
    message = "concurrent signature check"
    signature = TestWallet.sign_message(message)

    results =
      1..20
      |> Task.async_stream(
        fn _ -> Ethereum.verify_signature(@wallet_address, message, signature, @chain_id) end,
        max_concurrency: 20,
        timeout: 5_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert results == List.duplicate({:ok, :eoa_recovery}, 20)
  end

  defp receipt(audience \\ "patchbay") do
    secret = :siwa_server |> Application.fetch_env!(:siwa) |> Keyword.fetch!(:receipt_secret)

    assert {:ok, receipt} =
             Elixir.Siwa.create_receipt(
               %{
                 "typ" => "siwa_wallet_receipt",
                 "verified" => "wallet_signature",
                 "jti" => Ecto.UUID.generate(),
                 "sub" => @wallet_address,
                 "aud" => audience,
                 "chain_id" => @chain_id,
                 "nonce" => "receipt-#{System.unique_integer([:positive])}",
                 "key_id" => @wallet_address
               },
               receipt_secret: secret,
               ttl_ms: 3_600_000
             )

    receipt.token
  end

  defp signed_headers(
         receipt,
         body,
         created,
         expires,
         extra_headers \\ %{},
         components_override \\ nil,
         path \\ "/v1/agent/bug-report"
       ) do
    base_headers = %{
      "x-siwa-receipt" => receipt,
      "x-key-id" => @wallet_address,
      "x-timestamp" => Integer.to_string(created),
      "x-agent-wallet-address" => @wallet_address,
      "x-agent-chain-id" => Integer.to_string(@chain_id),
      "content-digest" => Elixir.Siwa.content_digest_for_body(body)
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
            "@path" -> path
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
    HttpVerifier.verify(params, Keyword.put_new(opts, :audience, "patchbay"))
  end

  # A signature no ordinary wallet made, so only Base can approve it.
  defp smart_wallet_signature, do: "sig1=:#{Base.encode64(:binary.copy(<<0xAB>>, 224))}:"

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
