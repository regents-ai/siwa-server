defmodule SiwaServer.Siwa.Wallet do
  @moduledoc "Wallet proof, distinct from registered-agent and human identity."

  alias SiwaServer.Config
  alias SiwaServer.Siwa.Challenge

  @nonce_fields [:wallet_address, :chain_id, :audience]
  @verify_fields @nonce_fields ++ [:nonce, :message, :signature]

  def issue_nonce(params) do
    with {:ok, request, origin} <- request(params, @nonce_fields),
         {:ok, _secret} <- Config.receipt_secret() do
      challenge =
        Challenge.issue(
          scope(request),
          %{
            address: request.wallet_address,
            chain_id: request.chain_id,
            audience: request.audience
          },
          &message(origin, &1)
        )

      {:ok,
       %{
         "code" => "nonce_issued",
         "data" => %{
           "walletAddress" => challenge.address,
           "chainId" => challenge.chain_id,
           "audience" => challenge.audience,
           "nonce" => challenge.nonce,
           "message" => challenge.canonical_message,
           "issuedAt" => DateTime.to_iso8601(challenge.issued_at),
           "expiresAt" => DateTime.to_iso8601(challenge.expiration_time)
         }
       }}
    end
  rescue
    _error in [Postgrex.Error, DBConnection.ConnectionError] -> unavailable()
  end

  def verify(params) do
    with {:ok, request, origin} <- request(params, @verify_fields),
         {:ok, secret} <- Config.receipt_secret(),
         {:ok, challenge} <- Challenge.fetch(scope(request), request.nonce),
         :ok <- current(challenge, request.message, origin),
         {:ok, verification_method} <-
           Challenge.signed(challenge, request.message, request.signature),
         :ok <- Challenge.consume(challenge),
         {:ok, receipt} <-
           Siwa.create_receipt(
             %{
               "typ" => "siwa_wallet_receipt",
               "verified" => "wallet_signature",
               "jti" => Ecto.UUID.generate(),
               "sub" => challenge.address,
               "key_id" => challenge.address,
               "aud" => challenge.audience,
               "chain_id" => challenge.chain_id,
               "nonce" => challenge.nonce
             },
             receipt_secret: secret,
             ttl_ms: Config.receipt_ttl_seconds() * 1_000
           ) do
      {:ok,
       %{
         "code" => "wallet_verified",
         "data" => %{
           "verified" => true,
           "proof" => "wallet_signature",
           "walletAddress" => challenge.address,
           "chainId" => challenge.chain_id,
           "audience" => challenge.audience,
           "keyId" => challenge.address,
           "signatureScheme" => "evm_personal_sign",
           "verificationMethod" => Atom.to_string(verification_method),
           "receipt" => receipt.token,
           "receiptExpiresAt" => DateTime.to_iso8601(receipt.expires_at)
         }
       }}
    else
      {:error, {_status, _code, _message}} = error -> error
      _unavailable -> unavailable()
    end
  rescue
    _error in [Postgrex.Error, DBConnection.ConnectionError] -> unavailable()
  end

  defp request(params, fields) do
    with {:ok, request} <- Challenge.cast(params, fields),
         [origin | _more] <- Map.get(Config.wallet_origins(), request.audience) do
      {:ok, request, origin}
    else
      :error ->
        {:error, {400, "invalid_request", "request body does not match the wallet contract"}}

      nil ->
        {:error,
         {403, "wallet_audience_disabled",
          "wallet author sign-in is not enabled for this audience"}}
    end
  end

  # The challenge names the audience's first origin when it was issued; one
  # that has changed since, or a message that is not the challenge, is refused.
  defp current(challenge, message, origin) do
    cond do
      DateTime.compare(challenge.expiration_time, DateTime.utc_now()) != :gt ->
        {:error, {401, "nonce_expired", "wallet challenge expired"}}

      message != challenge.canonical_message or
          message(origin, challenge) != challenge.canonical_message ->
        {:error, {401, "message_invalid", "sign the exact current server-issued challenge"}}

      true ->
        :ok
    end
  end

  defp scope(request),
    do: ["wallet", request.chain_id, request.wallet_address, request.audience]

  defp message(origin, challenge) do
    Enum.join(
      [
        "#{URI.parse(origin).host} wants you to sign in with your Ethereum account:",
        checksum_address(challenge.address),
        "",
        "Authorize wallet-signed requests for #{challenge.audience}. No human profile or agent registration is asserted.",
        "",
        "URI: #{origin}",
        "Version: 1",
        "Chain ID: #{challenge.chain_id}",
        "Nonce: #{challenge.nonce}",
        "Issued At: #{DateTime.to_iso8601(challenge.issued_at)}",
        "Expiration Time: #{DateTime.to_iso8601(challenge.expiration_time)}",
        "Resources:",
        "- urn:regent:audience:#{challenge.audience}"
      ],
      "\n"
    )
  end

  defp checksum_address("0x" <> hex) do
    hash = hex |> ExKeccak.hash_256() |> Base.encode16(case: :lower)

    checksum =
      Enum.zip(String.graphemes(hex), String.graphemes(hash))
      |> Enum.map_join(fn {char, digit} ->
        if String.to_integer(digit, 16) >= 8, do: String.upcase(char), else: char
      end)

    "0x" <> checksum
  end

  defp unavailable,
    do: {:error, {500, "wallet_verification_unavailable", "wallet verification is unavailable"}}
end
