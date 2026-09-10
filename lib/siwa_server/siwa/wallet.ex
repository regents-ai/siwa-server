defmodule SiwaServer.Siwa.Wallet do
  @moduledoc "EOA wallet proof, distinct from registered-agent and human identity."

  alias SiwaServer.{Ethereum, RuntimeConfig}
  alias SiwaServer.Siwa.NonceStore

  @nonce_fields ~w(wallet_address chain_id audience)
  @verify_fields @nonce_fields ++ ~w(nonce message signature)

  def issue_nonce(params) do
    with {:ok, fields, origin} <- validate(params, @nonce_fields),
         {:ok, _secret} <- RuntimeConfig.siwa_receipt_secret() do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      expires = DateTime.add(now, RuntimeConfig.siwa_nonce_ttl_seconds())
      nonce = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
      message = message(fields, origin, nonce, now, expires)

      attrs = %{
        nonce_key: nonce_key(fields),
        nonce: nonce,
        address: fields["wallet_address"],
        chain_id: fields["chain_id"],
        audience: fields["audience"],
        issued_at: now,
        expiration_time: expires,
        canonical_message: message
      }

      case NonceStore.put_wallet(attrs) do
        {:ok, _record} ->
          {:ok,
           %{
             "code" => "nonce_issued",
             "data" => %{
               "principalType" => "wallet",
               "walletAddress" => fields["wallet_address"],
               "chainId" => fields["chain_id"],
               "audience" => fields["audience"],
               "nonce" => nonce,
               "message" => message,
               "issuedAt" => DateTime.to_iso8601(now),
               "expiresAt" => DateTime.to_iso8601(expires)
             }
           }}

        _ ->
          unavailable()
      end
    end
  rescue
    _error in [Postgrex.Error, DBConnection.ConnectionError] -> unavailable()
  end

  def verify(params) do
    with {:ok, fields, origin} <- validate(params, @verify_fields),
         {:ok, secret} <- RuntimeConfig.siwa_receipt_secret(),
         {:ok, record} <- NonceStore.get_wallet(nonce_key(fields), fields["nonce"]),
         :ok <- validate_challenge(fields, origin, record),
         :ok <- verify_signature(record, fields),
         :ok <- NonceStore.consume_wallet(record),
         {:ok, receipt} <-
           Siwa.create_receipt(
             %{
               "typ" => "siwa_wallet_receipt",
               "verified" => "wallet_signature",
               "jti" => Ecto.UUID.generate(),
               "sub" => record.address,
               "key_id" => record.address,
               "aud" => record.audience,
               "chain_id" => record.chain_id,
               "nonce" => record.nonce
             },
             receipt_secret: secret,
             ttl_ms: RuntimeConfig.siwa_receipt_ttl_seconds() * 1_000
           ) do
      {:ok,
       %{
         "code" => "wallet_verified",
         "data" => %{
           "verified" => true,
           "principalType" => "wallet",
           "proof" => "wallet_signature",
           "walletAddress" => record.address,
           "chainId" => record.chain_id,
           "audience" => record.audience,
           "keyId" => record.address,
           "signatureScheme" => "evm_personal_sign",
           "receipt" => receipt.token,
           "receiptExpiresAt" => DateTime.to_iso8601(receipt.expires_at)
         }
       }}
    else
      {:error, {status, code, message}} ->
        {:error, {status, code, message}}

      {:error, :unknown_nonce} ->
        {:error, {404, "nonce_not_found", "challenge absent, expired or consumed"}}

      _ ->
        unavailable()
    end
  rescue
    _error in [Postgrex.Error, DBConnection.ConnectionError] -> unavailable()
  end

  defp verify_signature(record, fields) do
    case Ethereum.verify_signature(record.address, fields["message"], fields["signature"]) do
      :ok -> :ok
      {:error, _reason} -> {:error, {401, "signature_invalid", "signature does not match wallet"}}
    end
  end

  defp validate(params, allowed) when is_map(params) do
    with true <- Enum.sort(Map.keys(params)) == Enum.sort(allowed),
         8453 <- params["chain_id"],
         address when is_binary(address) <- params["wallet_address"],
         true <- Regex.match?(~r/^0x[0-9a-fA-F]{40}$/, address),
         audience when is_binary(audience) and byte_size(audience) in 1..200 <- params["audience"],
         true <- valid_proof_fields?(params),
         {:ok, origin} <- enabled_origin(audience) do
      {:ok, Map.put(params, "wallet_address", String.downcase(address)), origin}
    else
      {:error, _} = error -> error
      _ -> {:error, {400, "invalid_request", "request body does not match the wallet contract"}}
    end
  end

  defp validate(_params, _allowed),
    do: {:error, {400, "invalid_request", "invalid wallet request"}}

  defp valid_proof_fields?(%{"message" => message, "nonce" => nonce, "signature" => signature})
       when is_binary(message) and byte_size(message) in 1..2048 and is_binary(nonce) and
              is_binary(signature),
       do:
         Regex.match?(~r/^[a-f0-9]{32}$/, nonce) and
           Regex.match?(~r/^0x[0-9a-fA-F]{130}$/, signature)

  defp valid_proof_fields?(params), do: not Map.has_key?(params, "message")

  defp enabled_origin(audience) do
    case Map.fetch(RuntimeConfig.siwa_wallet_origins(), audience) do
      {:ok, origin} ->
        {:ok, origin}

      :error ->
        {:error,
         {403, "wallet_audience_disabled",
          "wallet author sign-in is not enabled for this audience"}}
    end
  end

  defp validate_challenge(fields, origin, record) do
    canonical = message(fields, origin, record.nonce, record.issued_at, record.expiration_time)

    cond do
      DateTime.compare(record.expiration_time, DateTime.utc_now()) != :gt ->
        {:error, {401, "nonce_expired", "wallet challenge expired"}}

      record.address != fields["wallet_address"] or record.chain_id != fields["chain_id"] or
        record.audience != fields["audience"] or fields["message"] != record.canonical_message or
          canonical != record.canonical_message ->
        {:error, {401, "message_invalid", "sign the exact current server-issued challenge"}}

      true ->
        :ok
    end
  end

  defp nonce_key(fields) do
    digest =
      :crypto.hash(
        :sha256,
        Jason.encode!([
          "wallet",
          fields["chain_id"],
          fields["wallet_address"],
          fields["audience"]
        ])
      )

    "wallet:" <> Base.encode16(digest, case: :lower)
  end

  defp message(fields, origin, nonce, issued, expires) do
    uri = URI.parse(origin)
    authority = if uri.port == 443, do: uri.host, else: "#{uri.host}:#{uri.port}"

    Enum.join(
      [
        "#{authority} wants you to sign in with your Ethereum account:",
        checksum_address(fields["wallet_address"]),
        "",
        "Authorize wallet-signed requests for #{fields["audience"]}. No human profile or agent registration is asserted.",
        "",
        "URI: #{origin}",
        "Version: 1",
        "Chain ID: #{fields["chain_id"]}",
        "Nonce: #{nonce}",
        "Issued At: #{DateTime.to_iso8601(issued)}",
        "Expiration Time: #{DateTime.to_iso8601(expires)}",
        "Resources:",
        "- urn:regent:audience:#{fields["audience"]}"
      ],
      "\n"
    )
  end

  defp checksum_address("0x" <> hex) do
    hash = hex |> KeccakEx.hash_256() |> Base.encode16(case: :lower)

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
