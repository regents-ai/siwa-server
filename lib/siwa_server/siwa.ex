defmodule SiwaServer.Siwa do
  @moduledoc false

  alias SiwaServer.Ethereum
  alias SiwaServer.RuntimeConfig
  alias SiwaServer.Siwa.{Error, HttpVerifier, Message, NonceStore}

  @address_regex ~r/^0x[a-fA-F0-9]{40}$/
  @positive_int_regex ~r/^[1-9][0-9]*$/
  @base_chain_id 8453

  def issue_nonce(params) when is_map(params) do
    with {:ok, wallet_address} <- required_address(params, "wallet_address"),
         {:ok, chain_id} <- required_base_chain_id(params, "chain_id"),
         {:ok, registry_address} <- required_address(params, "registry_address"),
         {:ok, token_id} <- required_positive_integer_string(params, "token_id"),
         {:ok, audience} <- required_string(params, "audience"),
         {:ok, nonce_result} <-
           Siwa.create_nonce(
             %{
               address: wallet_address,
               agent_id: token_id,
               agent_registry: agent_registry_string(chain_id, registry_address),
               audience: audience
             },
             store: NonceStore,
             ttl_ms: nonce_ttl_seconds() * 1_000
           ) do
      expires_at = nonce_result.expiration_time

      {:ok,
       %{
         "ok" => true,
         "code" => "nonce_issued",
         "data" => %{
           "nonce" => nonce_result.nonce,
           "walletAddress" => wallet_address,
           "chainId" => chain_id,
           "registryAddress" => registry_address,
           "tokenId" => token_id,
           "audience" => audience,
           "expiresAt" => expires_at
         }
       }}
    else
      {:error, {code, message}} -> {:error, {400, code, message}}
      {:error, reason} -> {:error, map_nonce_error(reason)}
    end
  end

  def verify_session(params) when is_map(params) do
    with {:ok, wallet_address} <- required_address(params, "wallet_address"),
         {:ok, chain_id} <- required_base_chain_id(params, "chain_id"),
         {:ok, registry_address} <- required_address(params, "registry_address"),
         {:ok, token_id} <- required_positive_integer_string(params, "token_id"),
         {:ok, audience} <- required_string(params, "audience"),
         {:ok, nonce} <- required_string(params, "nonce"),
         {:ok, message} <- required_string(params, "message"),
         {:ok, signature} <- required_string(params, "signature"),
         :ok <-
           Message.validate(
             message,
             wallet_address,
             chain_id,
             registry_address,
             token_id,
             audience,
             nonce
           ),
         :ok <- verify_wallet_signature(wallet_address, message, signature),
         {:ok, nonce_record} <-
           consume_nonce(wallet_address, chain_id, registry_address, token_id, audience, nonce),
         :ok <- ensure_wallet_owns_agent(wallet_address, chain_id, registry_address, token_id),
         {:ok, receipt, receipt_expires_at} <-
           issue_receipt(%{
             "typ" => "siwa_receipt",
             "jti" => Ecto.UUID.generate(),
             "sub" => wallet_address,
             "aud" => nonce_record.audience,
             "chain_id" => chain_id,
             "nonce" => nonce,
             "key_id" => wallet_address,
             "registry_address" => nonce_record.registry_address,
             "token_id" => nonce_record.token_id
           }) do
      issued_at = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok,
       %{
         "ok" => true,
         "code" => "siwa_verified",
         "data" => %{
           "verified" => true,
           "walletAddress" => wallet_address,
           "chainId" => chain_id,
           "registryAddress" => nonce_record.registry_address,
           "tokenId" => nonce_record.token_id,
           "audience" => nonce_record.audience,
           "nonce" => nonce,
           "keyId" => wallet_address,
           "signatureScheme" => "evm_personal_sign",
           "receipt" => receipt,
           "receiptIssuedAt" => DateTime.to_iso8601(issued_at),
           "receiptExpiresAt" => DateTime.to_iso8601(receipt_expires_at)
         }
       }}
    else
      {:error, {code, message}} -> {:error, {400, code, message}}
      {:error, {status, code, message}} -> {:error, {status, code, message}}
    end
  end

  defdelegate verify_http_request(params, opts \\ []), to: HttpVerifier, as: :verify

  defdelegate content_digest_for_body(body), to: Siwa.RequestAuth

  defp verify_wallet_signature(wallet_address, message, signature) do
    case Ethereum.verify_signature(wallet_address, message, signature) do
      :ok ->
        :ok

      {:error, _reason} ->
        Error.error(Error.unauthorized("signature_invalid", "signature does not match wallet"))
    end
  end

  defp consume_nonce(wallet_address, chain_id, registry_address, token_id, audience, nonce) do
    case Siwa.verify_nonce(
           %{
             address: wallet_address,
             agent_id: token_id,
             agent_registry: agent_registry_string(chain_id, registry_address),
             audience: audience,
             nonce: nonce
           },
           store: NonceStore,
           now: DateTime.utc_now()
         ) do
      {:ok, record} ->
        {:ok,
         %{
           audience: record.audience,
           registry_address: registry_address,
           token_id: token_id
         }}

      {:error, reason} ->
        {:error, map_nonce_error(reason)}
    end
  end

  defp issue_receipt(claims) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    with {:ok, secret} <- RuntimeConfig.siwa_receipt_secret(),
         {:ok, receipt} <-
           Siwa.create_receipt(
             claims,
             receipt_secret: secret,
             now: now,
             ttl_ms: RuntimeConfig.siwa_receipt_ttl_seconds() * 1_000
           ) do
      {:ok, receipt.token, receipt.expires_at}
    end
  end

  defp required_address(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) ->
        normalized = String.downcase(String.trim(value))

        if Regex.match?(@address_regex, normalized),
          do: {:ok, normalized},
          else: {:error, {"invalid_#{key}", "#{key} must be a valid address"}}

      _ ->
        {:error, {"missing_#{key}", "#{key} is required"}}
    end
  end

  defp required_base_chain_id(params, key) do
    case Map.get(params, key) do
      value when is_integer(value) and value == @base_chain_id ->
        {:ok, value}

      _value ->
        {:error, {"invalid_#{key}", "#{key} must be 8453"}}
    end
  end

  defp required_positive_integer_string(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) ->
        value = String.trim(value)

        if Regex.match?(@positive_int_regex, value),
          do: {:ok, value},
          else: {:error, {"invalid_#{key}", "#{key} must be a positive number"}}

      _ ->
        {:error, {"invalid_#{key}", "#{key} must be a positive number"}}
    end
  end

  defp required_string(params, key) do
    case normalize_optional_text(Map.get(params, key)) do
      nil -> {:error, {"missing_#{key}", "#{key} is required"}}
      value -> {:ok, value}
    end
  end

  defp normalize_optional_text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_optional_text(_value), do: nil

  defp ensure_wallet_owns_agent(wallet_address, chain_id, registry_address, token_id) do
    with {:ok, rpc_url} <- base_rpc_url_for_chain(chain_id),
         {:ok, owner_address} <- Ethereum.owner_of(registry_address, token_id, rpc_url: rpc_url),
         true <- owner_address == wallet_address do
      :ok
    else
      false ->
        Error.error(
          Error.unauthorized(
            "agent_identity_not_owned",
            "wallet does not own the claimed agent identity"
          )
        )

      {:error, "unsupported chain"} ->
        Error.error(
          Error.unauthorized(
            "unsupported_chain",
            "SIWA sign-in only supports Base agent identities"
          )
        )

      {:error, reason} ->
        Error.error(
          Error.upstream(
            "agent_identity_lookup_failed",
            "could not verify agent ownership: #{reason}"
          )
        )
    end
  end

  defp base_rpc_url_for_chain(@base_chain_id) do
    case RuntimeConfig.base_rpc_url() do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, "base rpc url is not configured"}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, "base rpc url is not configured"}
    end
  end

  defp base_rpc_url_for_chain(_chain_id), do: {:error, "unsupported chain"}

  defp nonce_ttl_seconds, do: RuntimeConfig.siwa_nonce_ttl_seconds()

  defp map_nonce_error(:unknown_nonce),
    do: Error.not_found("nonce_not_found", "nonce not found") |> Error.tuple()

  defp map_nonce_error(:nonce_expired),
    do: Error.unauthorized("nonce_expired", "nonce expired") |> Error.tuple()

  defp map_nonce_error(:nonce_already_used),
    do: Error.unauthorized("nonce_already_used", "nonce already used") |> Error.tuple()

  defp map_nonce_error(reason)
       when reason in [
              :nonce_address_mismatch,
              :nonce_agent_id_mismatch,
              :nonce_registry_mismatch,
              :nonce_audience_mismatch
            ] do
    Error.unauthorized("signature_invalid", "message does not match the requested SIWA claims")
    |> Error.tuple()
  end

  defp map_nonce_error(_reason),
    do:
      Error.bad_request("invalid_nonce", "could not issue or consume the SIWA nonce")
      |> Error.tuple()

  defp agent_registry_string(chain_id, registry_address),
    do: "eip155:#{chain_id}:#{registry_address}"
end
