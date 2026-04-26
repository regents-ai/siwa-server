defmodule SiwaServer.Siwa.HttpVerifier do
  @moduledoc false

  alias SiwaServer.Ethereum
  alias SiwaServer.RuntimeConfig
  alias SiwaServer.Siwa.{Error, ReplayStore, SignatureInput}

  @positive_int_regex ~r/^[1-9][0-9]*$/
  @signature_regex ~r/^sig1=:(?<payload>[A-Za-z0-9+\/=]+):$/
  @content_digest_regex ~r/^sha-256=:(?<payload>[A-Za-z0-9+\/=]+):$/
  @required_headers ~w(
    x-siwa-receipt
    signature
    signature-input
    x-key-id
    x-timestamp
    x-agent-wallet-address
    x-agent-chain-id
    x-agent-registry-address
    x-agent-token-id
  )
  @base_components ~w(
    @method
    @path
    x-siwa-receipt
    x-key-id
    x-timestamp
    x-agent-wallet-address
    x-agent-chain-id
  )

  @spec verify(map(), keyword()) :: {:ok, map()} | {:error, {integer(), String.t(), String.t()}}
  def verify(params, opts \\ []) when is_map(params) do
    with {:ok, method} <- required_string(params, "method"),
         {:ok, request_path} <- required_path(params, "path"),
         {:ok, request_body} <- optional_body(params, "body"),
         {:ok, normalized_headers} <- required_header_map(params, "headers"),
         body_digest = request_body_digest(request_body),
         :ok <- ensure_required_headers(normalized_headers, body_digest),
         {:ok, parsed_signature_input} <-
           SignatureInput.parse(Map.fetch!(normalized_headers, "signature-input")),
         :ok <- ensure_signature_window(parsed_signature_input, normalized_headers),
         :ok <-
           ensure_covered_components(
             parsed_signature_input.components,
             normalized_headers,
             body_digest
           ),
         {:ok, receipt_claims} <-
           verify_receipt(Map.fetch!(normalized_headers, "x-siwa-receipt"), opts),
         :ok <- ensure_body_binding(normalized_headers, body_digest),
         :ok <- ensure_header_binding(normalized_headers, receipt_claims),
         :ok <-
           ensure_replay_fresh(
             receipt_claims["sub"],
             parsed_signature_input.nonce,
             method,
             request_path,
             body_digest,
             parsed_signature_input.expires
           ),
         {:ok, signature} <- decode_signature(Map.fetch!(normalized_headers, "signature")),
         signing_message <-
           build_http_signing_message(
             method,
             request_path,
             normalized_headers,
             parsed_signature_input
           ),
         :ok <- verify_wallet_signature(receipt_claims["sub"], signing_message, signature) do
      {:ok,
       %{
         "ok" => true,
         "code" => "http_envelope_valid",
         "data" => %{
           "verified" => true,
           "walletAddress" => receipt_claims["sub"],
           "chainId" => receipt_claims["chain_id"],
           "keyId" => receipt_claims["key_id"],
           "agent_claims" => verified_agent_claims(receipt_claims),
           "receiptExpiresAt" => unix_ms_to_iso8601(receipt_claims["exp"]),
           "requiredHeaders" => required_headers(body_digest),
           "requiredCoveredComponents" =>
             required_components_for_headers(normalized_headers, body_digest),
           "coveredComponents" => parsed_signature_input.components
         }
       }}
    else
      {:error, {code, message}} -> {:error, {400, code, message}}
      {:error, {status, code, message}} -> {:error, {status, code, message}}
    end
  end

  @spec content_digest_for_body(term()) :: String.t() | nil
  def content_digest_for_body(body) when is_binary(body) do
    digest =
      :crypto.hash(:sha256, body)
      |> Base.encode64()

    "sha-256=:#{digest}:"
  end

  def content_digest_for_body(_body), do: nil

  defp verify_wallet_signature(wallet_address, message, signature) do
    case Ethereum.verify_signature(wallet_address, message, signature) do
      :ok ->
        :ok

      {:error, _reason} ->
        Error.error(Error.unauthorized("signature_invalid", "signature does not match wallet"))
    end
  end

  defp ensure_required_headers(headers, body_digest) do
    missing =
      required_headers(body_digest)
      |> Enum.reject(&Map.has_key?(headers, &1))

    if missing == [] do
      :ok
    else
      {:error, {401, "http_headers_missing", "missing required signed agent headers"}}
    end
  end

  defp ensure_covered_components(components, headers, body_digest) do
    allowed = required_components_for_headers(headers, body_digest)
    missing = Enum.reject(allowed, &(&1 in components))
    extras = Enum.reject(components, &(&1 in allowed))

    cond do
      missing != [] ->
        {:error, {401, "http_required_components_missing", "missing required covered components"}}

      extras != [] ->
        {:error, {401, "http_signature_input_invalid", "invalid covered components"}}

      true ->
        :ok
    end
  end

  defp required_components_for_headers(headers, body_digest) do
    @base_components
    |> maybe_append_content_digest(headers, body_digest)
    |> Kernel.++(["x-agent-registry-address", "x-agent-token-id"])
  end

  defp required_headers(body_digest) do
    if is_binary(body_digest),
      do: @required_headers ++ ["content-digest"],
      else: @required_headers
  end

  defp maybe_append_content_digest(components, headers, body_digest) do
    if is_binary(body_digest) or Map.has_key?(headers, "content-digest") do
      components ++ ["content-digest"]
    else
      components
    end
  end

  defp ensure_signature_window(parsed_signature_input, headers) do
    now = now_unix_seconds()
    tolerance = RuntimeConfig.siwa_http_signature_tolerance_seconds()

    case required_positive_integer(headers, "x-timestamp") do
      {:ok, header_timestamp} ->
        cond do
          header_timestamp != parsed_signature_input.created ->
            {:error, {401, "http_signature_invalid", "invalid x-timestamp header"}}

          parsed_signature_input.key_id != Map.get(headers, "x-key-id") ->
            {:error, {401, "http_signature_invalid", "invalid signature keyid"}}

          parsed_signature_input.created > now + tolerance ->
            {:error, {401, "http_signature_invalid", "signed request is not yet valid"}}

          parsed_signature_input.created < now - tolerance ->
            {:error, {401, "http_signature_invalid", "signed request is too old"}}

          parsed_signature_input.expires < now ->
            {:error, {401, "http_signature_invalid", "signed request has expired"}}

          true ->
            :ok
        end

      {:error, _reason} ->
        {:error, {401, "http_signature_invalid", "invalid x-timestamp header"}}
    end
  end

  defp verify_receipt(receipt, opts) when is_binary(receipt) do
    with {:ok, secret} <- receipt_secret(),
         {:ok, claims} <- Siwa.verify_receipt(receipt, receipt_secret: secret),
         true <- claims["typ"] == "siwa_receipt",
         :ok <- ensure_current_receipt(claims),
         :ok <- ensure_audience(claims, opts) do
      {:ok, claims}
    else
      {:error, {_, _, _} = error} -> {:error, error}
      _ -> {:error, {401, "receipt_invalid", "invalid SIWA receipt"}}
    end
  end

  defp verify_receipt(_value, _opts),
    do: {:error, {401, "receipt_invalid", "invalid SIWA receipt"}}

  defp ensure_audience(claims, opts) do
    case Keyword.get(opts, :audience) do
      nil ->
        {:error, {401, "receipt_audience_required", "request audience is required"}}

      expected ->
        if claims["aud"] == expected do
          :ok
        else
          {:error, {401, "receipt_binding_mismatch", "receipt audience does not match this app"}}
        end
    end
  end

  defp ensure_current_receipt(%{
         "jti" => jti,
         "sub" => sub,
         "aud" => aud,
         "chain_id" => chain_id,
         "nonce" => nonce,
         "key_id" => key_id,
         "registry_address" => registry_address,
         "token_id" => token_id
       })
       when is_binary(jti) and is_binary(sub) and is_binary(aud) and is_integer(chain_id) and
              is_binary(nonce) and is_binary(key_id) and is_binary(registry_address) and
              is_binary(token_id),
       do: :ok

  defp ensure_current_receipt(_claims),
    do: {:error, {401, "receipt_invalid", "invalid SIWA receipt"}}

  defp ensure_header_binding(headers, claims) do
    [
      fn -> ensure_key_id_binding(headers, claims) end,
      fn -> ensure_wallet_binding(headers, claims) end,
      fn -> ensure_chain_binding(headers, claims) end,
      fn -> ensure_registry_binding(headers, claims) end,
      fn -> ensure_token_binding(headers, claims) end
    ]
    |> Enum.reduce_while(:ok, fn check, :ok ->
      case check.() do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp ensure_body_binding(headers, nil) do
    if Map.has_key?(headers, "content-digest") do
      {:error,
       {401, "http_body_binding_missing",
        "request body is required when content-digest is present"}}
    else
      :ok
    end
  end

  defp ensure_body_binding(headers, body_digest) do
    with content_digest when is_binary(content_digest) <- Map.get(headers, "content-digest"),
         true <- content_digest == body_digest,
         %{"payload" => payload} <- Regex.named_captures(@content_digest_regex, content_digest),
         {:ok, _decoded} <- Base.decode64(payload) do
      :ok
    else
      nil ->
        {:error, {401, "http_body_binding_missing", "missing content-digest header"}}

      false ->
        {:error,
         {401, "http_body_binding_invalid", "content-digest does not match the request body"}}

      _ ->
        {:error, {401, "http_body_binding_invalid", "content-digest is invalid"}}
    end
  end

  defp ensure_replay_fresh(
         wallet_address,
         nonce,
         method,
         request_path,
         body_digest,
         expires_at_unix
       ) do
    replay_key =
      "#{wallet_address}|#{nonce}|#{String.upcase(method)}|#{request_path}|#{body_digest || ""}"

    now = now_unix_seconds()
    replay_expires_at_unix = max(now, expires_at_unix)

    case ReplayStore.consume(replay_key, replay_expires_at_unix) do
      :ok ->
        :ok

      {:error, :replayed_request} ->
        {:error, {409, "request_replayed", "request replay detected"}}

      {:error, _reason} ->
        {:error, {500, "request_replay_failed", "could not verify replay state"}}
    end
  end

  defp decode_signature(signature_header) when is_binary(signature_header) do
    with %{"payload" => payload} <-
           Regex.named_captures(@signature_regex, String.trim(signature_header)),
         {:ok, bytes} <- Base.decode64(payload),
         {:ok, signature} <- normalize_http_signature(bytes) do
      {:ok, signature}
    else
      _ -> {:error, {401, "http_signature_invalid", "invalid signature header"}}
    end
  end

  defp decode_signature(_value),
    do: {:error, {401, "http_signature_invalid", "invalid signature header"}}

  defp build_http_signing_message(method, request_path, headers, parsed_signature_input) do
    parsed_signature_input.components
    |> Enum.map(fn component ->
      value =
        case component do
          "@method" -> String.downcase(method)
          "@path" -> request_path
          header_name -> Map.fetch!(headers, header_name)
        end

      ~s("#{component}": #{value})
    end)
    |> Kernel.++([~s("@signature-params": #{parsed_signature_input.signature_params})])
    |> Enum.join("\n")
  end

  defp required_positive_integer(params, key) do
    case parse_positive_integer(Map.get(params, key)) do
      {:ok, value} -> {:ok, value}
      {:error, _reason} -> {:error, {"invalid_#{key}", "#{key} must be a positive integer"}}
    end
  end

  defp parse_positive_integer(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp parse_positive_integer(value) when is_binary(value) do
    if Regex.match?(@positive_int_regex, String.trim(value)) do
      {:ok, String.to_integer(String.trim(value))}
    else
      {:error, :invalid}
    end
  end

  defp parse_positive_integer(_value), do: {:error, :invalid}

  defp required_string(params, key) do
    case normalize_optional_text(Map.get(params, key)) do
      nil -> {:error, {"missing_#{key}", "#{key} is required"}}
      value -> {:ok, value}
    end
  end

  defp optional_body(params, key) do
    case Map.get(params, key) do
      nil -> {:ok, nil}
      body when is_binary(body) -> {:ok, body}
      _value -> {:error, {"invalid_#{key}", "#{key} must be a string when present"}}
    end
  end

  defp required_path(params, key) do
    with {:ok, value} <- required_string(params, key),
         true <- String.starts_with?(value, "/") do
      {:ok, value}
    else
      _ -> {:error, {"invalid_#{key}", "#{key} must be an absolute path"}}
    end
  end

  defp required_header_map(params, key) do
    case Map.get(params, key) do
      headers when is_map(headers) ->
        case Enum.reduce_while(headers, %{}, &normalize_header_entry_step/2) do
          {:error, _reason} ->
            {:error, {"invalid_#{key}", "#{key} must be an object of string headers"}}

          normalized_headers ->
            {:ok, normalized_headers}
        end

      _ ->
        {:error, {"invalid_#{key}", "#{key} must be an object of string headers"}}
    end
  end

  defp normalize_header_entry({name, value}, acc) when is_binary(name) and is_binary(value) do
    normalized_name = String.downcase(name)

    if Map.has_key?(acc, normalized_name) do
      {:error, :duplicate}
    else
      {:ok, Map.put(acc, normalized_name, String.trim(value))}
    end
  end

  defp normalize_header_entry(_entry, _acc), do: {:error, :invalid}

  defp normalize_header_entry_step(entry, acc) do
    case normalize_header_entry(entry, acc) do
      {:ok, updated_acc} -> {:cont, updated_acc}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp normalize_optional_text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_optional_text(_value), do: nil

  defp request_body_digest(nil), do: nil
  defp request_body_digest(body) when is_binary(body), do: content_digest_for_body(body)

  defp verified_agent_claims(receipt_claims) do
    %{
      "wallet_address" => receipt_claims["sub"],
      "chain_id" => receipt_claims["chain_id"],
      "registry_address" => receipt_claims["registry_address"],
      "token_id" => receipt_claims["token_id"]
    }
  end

  defp receipt_secret do
    case :siwa_server |> Application.get_env(:siwa, []) |> Keyword.get(:receipt_secret) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, {500, "siwa_not_configured", "SIWA receipt secret is not configured"}}
          secret -> {:ok, secret}
        end

      _ ->
        {:error, {500, "siwa_not_configured", "SIWA receipt secret is not configured"}}
    end
  end

  defp now_unix_seconds, do: System.os_time(:second)

  defp unix_ms_to_iso8601(unix_ms),
    do: unix_ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()

  defp ensure_key_id_binding(headers, claims),
    do: ensure_claim_binding(headers, claims, "x-key-id", "key_id")

  defp ensure_wallet_binding(headers, claims),
    do: ensure_claim_binding(headers, claims, "x-agent-wallet-address", "sub")

  defp ensure_chain_binding(headers, claims) do
    case parse_positive_integer(Map.get(headers, "x-agent-chain-id")) do
      {:ok, chain_id} ->
        if chain_id == claims["chain_id"] do
          :ok
        else
          header_binding_mismatch("x-agent-chain-id", "does not match SIWA receipt")
        end

      _ ->
        header_binding_mismatch("x-agent-chain-id", "does not match SIWA receipt")
    end
  end

  defp ensure_registry_binding(headers, claims) do
    ensure_claim_binding(headers, claims, "x-agent-registry-address", "registry_address")
  end

  defp ensure_token_binding(headers, claims) do
    ensure_claim_binding(headers, claims, "x-agent-token-id", "token_id")
  end

  defp ensure_claim_binding(headers, claims, header_name, claim_name) do
    if Map.get(headers, header_name) == claims[claim_name] do
      :ok
    else
      header_binding_mismatch(header_name, "does not match SIWA receipt")
    end
  end

  defp header_binding_mismatch(header_name, detail) do
    {:error, {401, "receipt_binding_mismatch", "#{header_name} #{detail}"}}
  end

  defp normalize_http_signature(<<_::binary-size(65)>> = bytes) do
    {:ok, "0x" <> Base.encode16(bytes, case: :lower)}
  end

  defp normalize_http_signature(_bytes), do: {:error, :invalid}
end
