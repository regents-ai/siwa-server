defmodule SiwaServer.Siwa.HttpVerifier do
  @moduledoc false

  alias SiwaServer.RuntimeConfig
  alias SiwaServer.Siwa.ReplayStore

  @spec verify(map(), keyword()) :: {:ok, map()} | {:error, {integer(), String.t(), String.t()}}
  def verify(params, opts \\ []) when is_map(params) do
    with {:ok, method} <- required_string(params, "method"),
         {:ok, path} <- required_path(params, "path"),
         {:ok, body} <- optional_body(params, "body"),
         {:ok, headers} <- required_header_map(params, "headers"),
         {:ok, secret} <- receipt_secret(),
         {:ok, verified} <-
           Siwa.RequestAuth.verify_authenticated_request(
             %{method: method, path: path, headers: headers, body: body},
             receipt_secret: secret,
             audience: Keyword.get(opts, :audience),
             signature_tolerance_seconds: RuntimeConfig.siwa_http_signature_tolerance_seconds(),
             replay_store: &ReplayStore.consume/2
           ) do
      claims = verified.claims

      {:ok,
       %{
         "ok" => true,
         "code" => "http_envelope_valid",
         "data" => %{
           "verified" => true,
           "walletAddress" => claims["sub"],
           "chainId" => claims["chain_id"],
           "keyId" => claims["key_id"],
           "agent_claims" => verified_agent_claims(claims),
           "receiptExpiresAt" => unix_ms_to_iso8601(claims["exp"]),
           "requiredHeaders" => Siwa.required_authenticated_request_headers(body),
           "requiredCoveredComponents" =>
             Siwa.required_authenticated_request_components(headers, body),
           "coveredComponents" => verified.covered_components
         }
       }}
    else
      {:error, {code, message}} -> {:error, {400, code, message}}
      {:error, {status, code, message}} -> {:error, {status, code, message}}
      {:error, reason} -> {:error, map_shared_error(reason)}
    end
  end

  defp required_string(params, key) do
    case normalize_optional_text(Map.get(params, key)) do
      nil -> {:error, {"missing_#{key}", "#{key} is required"}}
      value -> {:ok, value}
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

  defp optional_body(params, key) do
    case Map.get(params, key) do
      nil -> {:ok, nil}
      body when is_binary(body) -> {:ok, body}
      _value -> {:error, {"invalid_#{key}", "#{key} must be a string when present"}}
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

  defp receipt_secret, do: RuntimeConfig.siwa_receipt_secret()

  defp map_shared_error(:missing_signed_headers),
    do: {401, "http_headers_missing", "missing required signed agent headers"}

  defp map_shared_error(reason) when reason in [:timestamp_mismatch, :signature_key_id_mismatch],
    do: {401, "http_signature_invalid", "invalid signed request"}

  defp map_shared_error(:invalid_signature_input),
    do: {401, "http_signature_input_invalid", "invalid signature-input header"}

  defp map_shared_error(:request_not_yet_valid),
    do: {401, "http_signature_invalid", "signed request is not yet valid"}

  defp map_shared_error(:request_too_old),
    do: {401, "http_signature_invalid", "signed request is too old"}

  defp map_shared_error(:request_expired),
    do: {401, "http_signature_invalid", "signed request has expired"}

  defp map_shared_error(:invalid_timestamp),
    do: {401, "http_signature_invalid", "invalid x-timestamp header"}

  defp map_shared_error(:missing_covered_components),
    do: {401, "http_required_components_missing", "missing required covered components"}

  defp map_shared_error(:invalid_covered_components),
    do: {401, "http_signature_input_invalid", "invalid covered components"}

  defp map_shared_error(:request_body_required),
    do:
      {401, "http_body_binding_missing",
       "request body is required when content-digest is present"}

  defp map_shared_error(:missing_content_digest),
    do: {401, "http_body_binding_missing", "missing content-digest header"}

  defp map_shared_error(:content_digest_mismatch),
    do: {401, "http_body_binding_invalid", "content-digest does not match the request body"}

  defp map_shared_error(:invalid_content_digest),
    do: {401, "http_body_binding_invalid", "content-digest is invalid"}

  defp map_shared_error(reason) when reason in [:invalid_receipt, :receipt_audience_required],
    do: {401, "receipt_invalid", "invalid SIWA receipt"}

  defp map_shared_error(:receipt_binding_mismatch),
    do:
      {401, "receipt_binding_mismatch", "receipt audience or claims does not match this request"}

  defp map_shared_error(:chain_binding_mismatch),
    do: {401, "receipt_binding_mismatch", "x-agent-chain-id does not match SIWA receipt"}

  defp map_shared_error(:invalid_signature_header),
    do: {401, "http_signature_invalid", "invalid signature header"}

  defp map_shared_error(:signature_invalid),
    do: {401, "signature_invalid", "signature does not match wallet"}

  defp map_shared_error(:replayed_request),
    do: {409, "request_replayed", "request replay detected"}

  defp map_shared_error(_reason),
    do: {500, "request_replay_failed", "could not verify replay state"}

  defp verified_agent_claims(receipt_claims) do
    %{
      "wallet_address" => receipt_claims["sub"],
      "chain_id" => receipt_claims["chain_id"],
      "registry_address" => receipt_claims["registry_address"],
      "token_id" => receipt_claims["token_id"]
    }
  end

  defp unix_ms_to_iso8601(unix_ms),
    do: unix_ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()
end
