defmodule SiwaServer.Siwa do
  @moduledoc false

  alias SiwaServer.Ethereum
  alias SiwaServer.RuntimeConfig
  alias SiwaServer.Siwa.{NonceStore, ReplayStore}

  @address_regex ~r/^0x[a-fA-F0-9]{40}$/
  @positive_int_regex ~r/^[1-9][0-9]*$/
  @signature_input_regex ~r/^sig1=\((?<components>.+)\)(?<params>(?:;.+)*)$/
  @signature_regex ~r/^sig1=:(?<payload>[A-Za-z0-9+\/=]+):$/
  @content_digest_regex ~r/^sha-256=:(?<payload>[A-Za-z0-9+\/=]+):$/
  @domain "regent.cx"
  @verify_uri "https://regent.cx/v1/agent/siwa/verify"
  @supported_chain_ids [8453, 84532]
  @required_headers ~w(
    x-siwa-receipt
    signature
    signature-input
    x-key-id
    x-timestamp
    x-agent-wallet-address
    x-agent-chain-id
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

  def issue_nonce(params) when is_map(params) do
    with {:ok, wallet_address} <- required_address(params, "wallet_address"),
         {:ok, chain_id} <- required_positive_integer(params, "chain_id"),
         {:ok, registry_address} <- required_address(params, "registry_address"),
         {:ok, token_id} <- required_positive_integer(params, "token_id"),
         {:ok, audience} <- required_string(params, "audience"),
         {:ok, nonce_result} <-
           Siwa.create_nonce(
             %{
               address: wallet_address,
               agent_id: token_id,
               agent_registry: agent_registry_string(chain_id, registry_address),
               audience: audience
             },
             store: &NonceStore.put/4,
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
           "tokenId" => Integer.to_string(token_id),
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
         {:ok, chain_id} <- required_positive_integer(params, "chain_id"),
         {:ok, registry_address} <- required_address(params, "registry_address"),
         {:ok, token_id} <- required_positive_integer(params, "token_id"),
         {:ok, nonce} <- required_string(params, "nonce"),
         {:ok, message} <- required_string(params, "message"),
         {:ok, signature} <- required_string(params, "signature"),
         :ok <- validate_siwa_message(message, wallet_address, chain_id, nonce),
         :ok <- verify_wallet_signature(wallet_address, message, signature),
         {:ok, nonce_record} <-
           consume_nonce(wallet_address, chain_id, registry_address, token_id, nonce),
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
      {:error, {status, code, message}} -> {:error, {status, code, message}}
    end
  end

  def verify_http_request(params, opts \\ []) when is_map(params) do
    with {:ok, method} <- required_string(params, "method"),
         {:ok, request_path} <- required_path(params, "path"),
         {:ok, request_body} <- optional_body(params, "body"),
         {:ok, normalized_headers} <- required_header_map(params, "headers"),
         body_digest = request_body_digest(request_body),
         :ok <- ensure_required_headers(normalized_headers, body_digest),
         {:ok, parsed_signature_input} <-
           parse_signature_input(Map.fetch!(normalized_headers, "signature-input")),
         :ok <- ensure_signature_window(parsed_signature_input, normalized_headers),
         :ok <-
           ensure_required_components(
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
      {:error, {status, code, message}} -> {:error, {status, code, message}}
    end
  end

  def content_digest_for_body(body) when is_binary(body) do
    digest =
      :crypto.hash(:sha256, body)
      |> Base.encode64()

    "sha-256=:#{digest}:"
  end

  def content_digest_for_body(_body), do: nil

  defp validate_siwa_message(message, wallet_address, chain_id, nonce) do
    with {:ok, parsed} <- parse_siwa_message(message),
         true <- parsed.wallet_address == wallet_address,
         true <- parsed.chain_id == chain_id,
         true <- parsed.nonce == nonce do
      :ok
    else
      {:error, reason} ->
        {:error, {401, "signature_invalid", reason}}

      false ->
        {:error, {401, "signature_invalid", "message does not match the requested SIWA claims"}}
    end
  end

  defp verify_wallet_signature(wallet_address, message, signature) do
    case Ethereum.verify_signature(wallet_address, message, signature) do
      :ok -> :ok
      {:error, _reason} -> {:error, {401, "signature_invalid", "signature does not match wallet"}}
    end
  end

  defp consume_nonce(wallet_address, chain_id, registry_address, token_id, nonce) do
    case Siwa.verify_nonce(
           %{
             address: wallet_address,
             agent_id: token_id,
             agent_registry: agent_registry_string(chain_id, registry_address),
             nonce: nonce
           },
           store: &NonceStore.consume/2,
           now: DateTime.utc_now()
         ) do
      {:ok, record} ->
        {:ok,
         %{
           audience: record.audience,
           registry_address: registry_address,
           token_id: Integer.to_string(token_id)
         }}

      {:error, reason} ->
        {:error, map_nonce_error(reason)}
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

  defp parse_signature_input(signature_input) when is_binary(signature_input) do
    with %{"components" => components_blob, "params" => params_blob} <-
           Regex.named_captures(@signature_input_regex, String.trim(signature_input)),
         {:ok, components} <- parse_components(components_blob),
         {:ok, params} <- parse_signature_params(params_blob) do
      {:ok,
       %{
         components: components,
         created: params.created,
         expires: params.expires,
         nonce: params.nonce,
         key_id: params.key_id,
         signature_params:
           "(#{Enum.map_join(components, " ", &~s("#{&1}"))})" <>
             ";created=#{params.created}" <>
             ";expires=#{params.expires}" <>
             ~s(;nonce="#{params.nonce}") <>
             if(params.key_id, do: ~s(;keyid="#{params.key_id}"), else: "")
       }}
    else
      _ -> {:error, {401, "http_signature_input_invalid", "invalid signature-input header"}}
    end
  end

  defp parse_signature_input(_value),
    do: {:error, {401, "http_signature_input_invalid", "invalid signature-input header"}}

  defp parse_components(blob) when is_binary(blob) do
    components =
      blob
      |> String.split(~r/\s+/, trim: true)
      |> Enum.map(&String.trim(&1, "\""))

    if components == [] do
      {:error, :invalid}
    else
      {:ok, components}
    end
  end

  defp parse_signature_params(blob) do
    entries =
      blob
      |> String.split(";", trim: true)
      |> Enum.reduce(%{}, fn entry, acc ->
        case String.split(entry, "=", parts: 2) do
          [key, value] -> Map.put(acc, key, String.trim(value, "\""))
          _ -> acc
        end
      end)

    with {:ok, created} <- parse_positive_integer(entries["created"]),
         {:ok, expires} <- parse_positive_integer(entries["expires"]),
         {:ok, nonce} <- required_value(entries["nonce"]),
         true <- expires > created do
      {:ok,
       %{
         created: created,
         expires: expires,
         nonce: nonce,
         key_id: normalize_optional_text(entries["keyid"])
       }}
    else
      _ -> {:error, :invalid}
    end
  end

  defp ensure_required_components(components, headers, body_digest) do
    required = required_components_for_headers(headers, body_digest)
    missing = Enum.reject(required, &(&1 in components))

    if missing == [] do
      :ok
    else
      {:error, {401, "http_required_components_missing", "missing required covered components"}}
    end
  end

  defp required_components_for_headers(headers, body_digest) do
    @base_components
    |> maybe_append_content_digest(body_digest)
    |> maybe_append_component(headers, "x-agent-registry-address")
    |> maybe_append_component(headers, "x-agent-token-id")
  end

  defp required_headers(body_digest) do
    if is_binary(body_digest),
      do: @required_headers ++ ["content-digest"],
      else: @required_headers
  end

  defp maybe_append_content_digest(components, body_digest) do
    if is_binary(body_digest), do: components ++ ["content-digest"], else: components
  end

  defp maybe_append_component(components, headers, header_name) do
    if Map.has_key?(headers, header_name), do: components ++ [header_name], else: components
  end

  defp ensure_signature_window(parsed_signature_input, headers) do
    now = now_unix_seconds()
    tolerance = RuntimeConfig.siwa_http_signature_tolerance_seconds()

    case required_positive_integer(headers, "x-timestamp") do
      {:ok, header_timestamp} ->
        cond do
          header_timestamp != parsed_signature_input.created ->
            {:error, {401, "http_signature_invalid", "invalid x-timestamp header"}}

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
        :ok

      expected ->
        if claims["aud"] == expected do
          :ok
        else
          {:error, {401, "receipt_binding_mismatch", "receipt audience does not match this app"}}
        end
    end
  end

  defp ensure_header_binding(headers, claims) do
    cond do
      Map.get(headers, "x-key-id") != claims["key_id"] ->
        {:error, {401, "receipt_binding_mismatch", "x-key-id does not match SIWA receipt"}}

      Map.get(headers, "x-agent-wallet-address") != claims["sub"] ->
        {:error,
         {401, "receipt_binding_mismatch", "x-agent-wallet-address does not match SIWA receipt"}}

      parse_positive_integer!(Map.get(headers, "x-agent-chain-id")) != claims["chain_id"] ->
        {:error,
         {401, "receipt_binding_mismatch", "x-agent-chain-id does not match SIWA receipt"}}

      claims["registry_address"] &&
          Map.get(headers, "x-agent-registry-address") != claims["registry_address"] ->
        {:error,
         {401, "receipt_binding_mismatch", "x-agent-registry-address does not match SIWA receipt"}}

      Map.has_key?(headers, "x-agent-registry-address") && is_nil(claims["registry_address"]) ->
        {:error,
         {401, "receipt_binding_mismatch",
          "x-agent-registry-address is not verified in the SIWA receipt"}}

      claims["token_id"] && Map.get(headers, "x-agent-token-id") != claims["token_id"] ->
        {:error,
         {401, "receipt_binding_mismatch", "x-agent-token-id does not match SIWA receipt"}}

      Map.has_key?(headers, "x-agent-token-id") && is_nil(claims["token_id"]) ->
        {:error,
         {401, "receipt_binding_mismatch", "x-agent-token-id is not verified in the SIWA receipt"}}

      true ->
        :ok
    end
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

      {:error, reason} ->
        {:error,
         {500, "request_replay_failed", "could not verify replay state: #{inspect(reason)}"}}
    end
  end

  defp decode_signature(signature_header) when is_binary(signature_header) do
    with %{"payload" => payload} <-
           Regex.named_captures(@signature_regex, String.trim(signature_header)),
         {:ok, bytes} <- Base.decode64(payload) do
      case bytes do
        <<_::binary-size(65)>> ->
          {:ok, "0x" <> Base.encode16(bytes, case: :lower)}

        printable ->
          if String.printable?(printable) do
            {:ok, printable}
          else
            {:error, {401, "http_signature_invalid", "invalid signature header"}}
          end
      end
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
          header_name -> Map.get(headers, header_name, "")
        end

      ~s("#{component}": #{value})
    end)
    |> Kernel.++([~s("@signature-params": #{parsed_signature_input.signature_params})])
    |> Enum.join("\n")
  end

  defp issue_receipt(claims) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    with {:ok, secret} <- receipt_secret(),
         {:ok, receipt} <-
           Siwa.create_receipt(
             claims,
             receipt_secret: secret,
             now: now,
             ttl_ms: receipt_ttl_seconds() * 1_000
           ) do
      {:ok, receipt.token, receipt.expires_at}
    end
  end

  defp parse_siwa_message(message) when is_binary(message) do
    normalized_message = String.trim(message)
    lines = String.split(normalized_message, "\n", trim: false)

    with [header, wallet_address, "" | rest] <- lines,
         true <- header == "#{@domain} wants you to sign in with your Ethereum account:",
         {:ok, statement_lines, field_lines} <- split_statement_and_fields(rest),
         {:ok, fields} <- parse_siwa_fields(field_lines),
         :ok <- validate_siwa_fields(fields),
         true <- Enum.all?(statement_lines, &(String.trim(&1) != "")) do
      {:ok,
       %{
         wallet_address: String.downcase(String.trim(wallet_address)),
         chain_id: parse_positive_integer!(fields["Chain ID"]),
         nonce: fields["Nonce"],
         issued_at: fields["Issued At"],
         statement: Enum.join(statement_lines, "\n")
       }}
    else
      false -> {:error, "message does not match the canonical SIWA format"}
      _ -> {:error, "message does not match the canonical SIWA format"}
    end
  end

  defp parse_siwa_message(_message),
    do: {:error, "message does not match the canonical SIWA format"}

  defp split_statement_and_fields(lines) do
    {statement_lines, remainder} = Enum.split_while(lines, &(&1 != ""))

    case remainder do
      [] -> {:ok, statement_lines, lines}
      [_blank | field_lines] -> {:ok, statement_lines, field_lines}
    end
  end

  defp parse_siwa_fields(field_lines) do
    Enum.reduce_while(field_lines, {:ok, %{}}, fn line, {:ok, acc} ->
      case String.split(line, ": ", parts: 2) do
        [key, value] when key != "" and value != "" ->
          {:cont, {:ok, Map.put(acc, key, value)}}

        _ ->
          {:halt, {:error, :invalid}}
      end
    end)
  end

  defp validate_siwa_fields(fields) do
    with "1" <- Map.get(fields, "Version"),
         @verify_uri <- Map.get(fields, "URI"),
         {:ok, _chain_id} <- parse_positive_integer(Map.get(fields, "Chain ID")),
         {:ok, _nonce} <- required_value(Map.get(fields, "Nonce")),
         {:ok, issued_at} <- required_value(Map.get(fields, "Issued At")),
         {:ok, _datetime, 0} <- DateTime.from_iso8601(issued_at) do
      :ok
    else
      _ -> {:error, "message does not match the canonical SIWA format"}
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
  defp parse_positive_integer!(value), do: value |> parse_positive_integer() |> elem(1)

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
        normalized =
          headers
          |> Enum.reduce(%{}, fn
            {name, value}, acc when is_binary(name) and is_binary(value) ->
              Map.put(acc, String.downcase(name), String.trim(value))

            _entry, acc ->
              acc
          end)

        {:ok, normalized}

      _ ->
        {:error, {"invalid_#{key}", "#{key} must be an object of string headers"}}
    end
  end

  defp required_value(nil), do: {:error, :missing}
  defp required_value(""), do: {:error, :missing}
  defp required_value(value), do: {:ok, value}

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

  defp ensure_wallet_owns_agent(wallet_address, chain_id, registry_address, token_id) do
    with {:ok, rpc_url} <- base_rpc_url_for_chain(chain_id),
         {:ok, owner_address} <- Ethereum.owner_of(registry_address, token_id, rpc_url: rpc_url),
         true <- owner_address == wallet_address do
      :ok
    else
      false ->
        {:error,
         {401, "agent_identity_not_owned", "wallet does not own the claimed agent identity"}}

      {:error, "unsupported chain"} ->
        {:error, {401, "unsupported_chain", "SIWA sign-in only supports Base agent identities"}}

      {:error, reason} ->
        {:error,
         {502, "agent_identity_lookup_failed", "could not verify agent ownership: #{reason}"}}
    end
  end

  defp base_rpc_url_for_chain(chain_id) when chain_id in @supported_chain_ids do
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

  defp nonce_ttl_seconds do
    :siwa_server
    |> Application.get_env(:siwa, [])
    |> Keyword.get(:nonce_ttl_seconds, 300)
  end

  defp receipt_ttl_seconds do
    :siwa_server
    |> Application.get_env(:siwa, [])
    |> Keyword.get(:receipt_ttl_seconds, 3_600)
  end

  defp now_unix_seconds, do: System.os_time(:second)

  defp unix_ms_to_iso8601(unix_ms),
    do: unix_ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()

  defp map_nonce_error(:unknown_nonce), do: {404, "nonce_not_found", "nonce not found"}
  defp map_nonce_error(:nonce_expired), do: {401, "nonce_expired", "nonce expired"}
  defp map_nonce_error(:nonce_already_used), do: {401, "nonce_already_used", "nonce already used"}

  defp map_nonce_error(reason)
       when reason in [
              :nonce_address_mismatch,
              :nonce_agent_id_mismatch,
              :nonce_registry_mismatch
            ] do
    {401, "signature_invalid", "message does not match the requested SIWA claims"}
  end

  defp map_nonce_error(reason) do
    {400, "invalid_nonce", "could not issue or consume the SIWA nonce: #{inspect(reason)}"}
  end

  defp agent_registry_string(chain_id, registry_address),
    do: "eip155:#{chain_id}:#{registry_address}"
end
