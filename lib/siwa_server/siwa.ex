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
  @supported_chain_ids [8453, 84_532]
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
  @siwa_field_names ["URI", "Version", "Chain ID", "Nonce", "Issued At"]
  @signature_components ~w(
    @method
    @path
    x-siwa-receipt
    x-key-id
    x-timestamp
    x-agent-wallet-address
    x-agent-chain-id
    x-agent-registry-address
    x-agent-token-id
    content-digest
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
      {:error, {code, message}} -> {:error, {400, code, message}}
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
    case(
      blob
      |> String.split(~r/\s+/, trim: true)
      |> Enum.reduce_while([], &reduce_signature_component/2)
    ) do
      {:error, reason} -> {:error, reason}
      components -> {:ok, Enum.reverse(components)}
    end
  end

  defp parse_signature_params(blob) do
    case(
      blob
      |> String.split(";", trim: true)
      |> Enum.reduce_while(%{}, &reduce_signature_param/2)
    ) do
      {:error, reason} ->
        {:error, reason}

      entries ->
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
    |> maybe_append_component(headers, "x-agent-registry-address")
    |> maybe_append_component(headers, "x-agent-token-id")
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
    Enum.reduce_while(field_lines, {:ok, %{}}, fn line, {:ok, fields} ->
      case parse_siwa_field(line, fields) do
        {:ok, updated_fields} -> {:cont, {:ok, updated_fields}}
        {:error, _reason} -> {:halt, {:error, :invalid}}
      end
    end)
  end

  defp validate_siwa_fields(fields) do
    with true <- Enum.sort(Map.keys(fields)) == Enum.sort(@siwa_field_names),
         "1" <- Map.get(fields, "Version"),
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

  defp parse_signature_param_entry(entry, acc) do
    case String.split(entry, "=", parts: 2) do
      [key, value] ->
        if Map.has_key?(acc, key) do
          {:error, :duplicate}
        else
          {:ok, Map.put(acc, key, String.trim(value, "\""))}
        end

      _ ->
        {:error, :invalid}
    end
  end

  defp parse_siwa_field(line, fields) do
    case String.split(line, ": ", parts: 2) do
      [key, value] ->
        cond do
          key not in @siwa_field_names -> {:error, :invalid}
          value == "" -> {:error, :invalid}
          Map.has_key?(fields, key) -> {:error, :invalid}
          true -> {:ok, Map.put(fields, key, value)}
        end

      _ ->
        {:error, :invalid}
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

  defp reduce_signature_component(token, components) do
    case parse_component(token) do
      {:ok, component} ->
        if component in components do
          {:halt, {:error, :invalid}}
        else
          {:cont, [component | components]}
        end

      {:error, _reason} ->
        {:halt, {:error, :invalid}}
    end
  end

  defp reduce_signature_param(entry, acc) do
    case parse_signature_param_entry(entry, acc) do
      {:ok, updated_acc} -> {:cont, updated_acc}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp normalize_header_entry_step(entry, acc) do
    case normalize_header_entry(entry, acc) do
      {:ok, updated_acc} -> {:cont, updated_acc}
      {:error, reason} -> {:halt, {:error, reason}}
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

  defp map_nonce_error(_reason),
    do: {400, "invalid_nonce", "could not issue or consume the SIWA nonce"}

  defp agent_registry_string(chain_id, registry_address),
    do: "eip155:#{chain_id}:#{registry_address}"

  defp parse_component(token) when is_binary(token) do
    if String.starts_with?(token, "\"") and String.ends_with?(token, "\"") do
      normalized = token |> String.trim_leading("\"") |> String.trim_trailing("\"")

      if normalized in @signature_components do
        {:ok, normalized}
      else
        {:error, :invalid}
      end
    else
      {:error, :invalid}
    end
  end

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
    ensure_optional_claim_binding(headers, claims, "x-agent-registry-address", "registry_address")
  end

  defp ensure_token_binding(headers, claims) do
    ensure_optional_claim_binding(headers, claims, "x-agent-token-id", "token_id")
  end

  defp ensure_claim_binding(headers, claims, header_name, claim_name) do
    if Map.get(headers, header_name) == claims[claim_name] do
      :ok
    else
      header_binding_mismatch(header_name, "does not match SIWA receipt")
    end
  end

  defp ensure_optional_claim_binding(headers, claims, header_name, claim_name) do
    case {claims[claim_name], Map.has_key?(headers, header_name), Map.get(headers, header_name)} do
      {nil, false, _value} ->
        :ok

      {nil, true, _value} ->
        header_binding_mismatch(header_name, "is not verified in the SIWA receipt")

      {claim_value, _present?, value} when claim_value == value ->
        :ok

      {_claim_value, _present?, _value} ->
        header_binding_mismatch(header_name, "does not match SIWA receipt")
    end
  end

  defp header_binding_mismatch(header_name, detail) do
    {:error, {401, "receipt_binding_mismatch", "#{header_name} #{detail}"}}
  end

  defp normalize_http_signature(<<_::binary-size(65)>> = bytes) do
    {:ok, "0x" <> Base.encode16(bytes, case: :lower)}
  end

  defp normalize_http_signature("0x" <> hex = signature) when byte_size(hex) == 130 do
    case Base.decode16(hex, case: :mixed) do
      {:ok, <<_::binary-size(65)>>} -> {:ok, String.downcase(signature)}
      _ -> {:error, :invalid}
    end
  end

  defp normalize_http_signature(_bytes), do: {:error, :invalid}
end
