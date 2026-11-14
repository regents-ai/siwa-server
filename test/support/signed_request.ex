defmodule SiwaServer.SignedRequest do
  @moduledoc """
  A request an agent signed in for `audience` and sent to a site at
  `authority`, as the site sends it to http-verify: a POST of a fresh body,
  signed now for two minutes by `signer` (`Siwa.LocalSigner`).
  """

  alias SiwaServer.Siwa.ReplayStore

  @chain_id 8453
  @path "/v1/notes"
  @components ~w(@method @path @authority x-siwa-receipt x-key-id x-timestamp x-agent-wallet-address x-agent-chain-id content-digest)

  @doc "A new agent wallet."
  def signer do
    {:ok, signer} = Siwa.LocalSigner.new()
    signer
  end

  @doc "The agent's subject, as a keyed answer names it."
  def subject(signer), do: "eip155:#{@chain_id}:#{String.downcase(signer.address)}"

  @doc "Options: `:receipt_ttl_ms`, how long the agent's sign-in lasts (an hour)."
  def build(signer, audience, authority, opts \\ []) do
    body = Jason.encode!(%{"note" => System.unique_integer([:positive])})
    digest = Siwa.content_digest_for_body(body)
    created = System.os_time(:second)

    headers = %{
      "x-siwa-receipt" =>
        receipt(signer.address, audience, Keyword.get(opts, :receipt_ttl_ms, 3_600_000)),
      "x-key-id" => signer.address,
      "x-timestamp" => Integer.to_string(created),
      "x-agent-wallet-address" => signer.address,
      "x-agent-chain-id" => Integer.to_string(@chain_id),
      "content-digest" => digest
    }

    signature_params =
      "(#{Enum.map_join(@components, " ", &~s("#{&1}"))})" <>
        ";created=#{created};expires=#{created + 120}" <>
        ~s(;nonce="req-#{System.unique_integer([:positive])}";keyid="#{signer.address}")

    signing_message =
      @components
      |> Enum.map(fn
        "@method" -> ~s("@method": post)
        "@path" -> ~s("@path": #{@path})
        "@authority" -> ~s("@authority": #{authority})
        header -> ~s("#{header}": #{Map.fetch!(headers, header)})
      end)
      |> Kernel.++([~s("@signature-params": #{signature_params})])
      |> Enum.join("\n")

    {:ok, "0x" <> signature} = Siwa.LocalSigner.sign_message(signer, signing_message)
    signature = signature |> Base.decode16!(case: :mixed) |> Base.encode64()

    %{
      "method" => "POST",
      "path" => @path,
      "authority" => authority,
      "body_digest" => digest,
      "headers" =>
        Map.merge(headers, %{
          "x-siwa-signature-input" => "sig1=#{signature_params}",
          "x-siwa-signature" => "sig1=:#{signature}:"
        })
    }
  end

  @doc "The replay row a use of `request`, signed in for `audience`, keeps."
  def stored_replay_key(request, audience) do
    [_whole, nonce] =
      Regex.run(~r/;nonce="([^"]+)"/, request["headers"]["x-siwa-signature-input"])

    ReplayStore.stored_key(
      Jason.encode!([
        "wallet",
        String.downcase(request["headers"]["x-agent-wallet-address"]),
        @chain_id,
        audience,
        nonce,
        "POST",
        @path,
        request["body_digest"]
      ])
    )
  end

  defp receipt(address, audience, ttl_ms) do
    secret = :siwa_server |> Application.fetch_env!(:siwa) |> Keyword.fetch!(:receipt_secret)

    {:ok, %{token: token}} =
      Siwa.create_receipt(
        %{
          "typ" => "siwa_wallet_receipt",
          "verified" => "wallet_signature",
          "jti" => Ecto.UUID.generate(),
          "sub" => address,
          "aud" => audience,
          "chain_id" => @chain_id,
          "nonce" => "receipt-#{System.unique_integer([:positive])}",
          "key_id" => address
        },
        receipt_secret: secret,
        ttl_ms: ttl_ms
      )

    token
  end
end
