defmodule SiwaServer.SiwaTest do
  use SiwaServer.DataCase, async: false

  alias SiwaServer.{Repo, RuntimeConfig, Siwa, TestEthereumAdapter}

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

  test "signed requests reject expired signature windows" do
    receipt = verified_receipt()
    body = Jason.encode!(%{"summary" => "Expired request", "details" => "body binding"})
    created = System.os_time(:second) - 120
    expires = created + 30

    assert {:error, {401, "http_signature_invalid", message}} =
             Siwa.verify_http_request(%{
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
             Siwa.verify_http_request(%{
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
             Siwa.verify_http_request(%{
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
             Siwa.verify_http_request(%{
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
             Siwa.verify_http_request(%{
               "method" => "POST",
               "path" => "/v1/agent/bug-report",
               "headers" => headers,
               "body" => body
             })

    assert message =~ "does not match"
  end

  test "signed requests reject a receipt for the wrong audience" do
    receipt = verified_receipt("techtree")
    body = Jason.encode!(%{"summary" => "Audience mismatch", "details" => "blocked"})
    created = System.os_time(:second)
    expires = created + 120

    assert {:error, {401, "receipt_binding_mismatch", message}} =
             Siwa.verify_http_request(
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
    TestEthereumAdapter.put_owner(
      @registry_address,
      @token_id,
      "0x1111111111111111111111111111111111111111"
    )

    assert {:ok, %{"data" => %{"nonce" => nonce}}} =
             Siwa.issue_nonce(%{
               "wallet_address" => @wallet_address,
               "chain_id" => @chain_id,
               "registry_address" => @registry_address,
               "token_id" => @token_id,
               "audience" => "platform"
             })

    message = siwa_message(nonce)
    signature = TestEthereumAdapter.sign_message(@wallet_address, message)

    assert {:error, {401, "agent_identity_not_owned", message}} =
             Siwa.verify_session(%{
               "wallet_address" => @wallet_address,
               "chain_id" => @chain_id,
               "registry_address" => @registry_address,
               "token_id" => @token_id,
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
      regent.cx wants you to sign in with your Ethereum account:
      #{@wallet_address}

      URI: https://wrong.example.com/v1/agent/siwa/verify
      Version: 1
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
               "nonce" => nonce,
               "message" => bad_message,
               "signature" => TestEthereumAdapter.sign_message(@wallet_address, bad_message)
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
             Siwa.verify_http_request(%{
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
             Siwa.verify_http_request(%{
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
             Siwa.verify_http_request(%{
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
             Siwa.verify_http_request(%{
               "method" => "POST",
               "path" => "/v1/agent/bug-report",
               "headers" => headers,
               "body" => body
             })
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

    message = siwa_message(nonce)
    signature = TestEthereumAdapter.sign_message(@wallet_address, message)

    assert {:ok, %{"data" => %{"receipt" => receipt}}} =
             Siwa.verify_session(%{
               "wallet_address" => @wallet_address,
               "chain_id" => @chain_id,
               "registry_address" => @registry_address,
               "token_id" => @token_id,
               "nonce" => nonce,
               "message" => message,
               "signature" => signature
             })

    receipt
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

  defp signed_headers(receipt, body, created, expires, extra_headers \\ %{}) do
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
      TestEthereumAdapter.sign_message(@wallet_address, signing_message)
      |> Base.encode64()

    headers
    |> Map.put("signature-input", "sig1=#{signature_params}")
    |> Map.put("signature", "sig1=:#{signature}:")
  end

  defp request_nonce(headers) do
    [_, nonce] = Regex.run(~r/;nonce="([^"]+)"/, Map.fetch!(headers, "signature-input"))
    nonce
  end
end
