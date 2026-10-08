defmodule SiwaServer.Siwa.HttpVerifier do
  @moduledoc """
  Verifies signed HTTP request envelopes presented by agents signed in with
  their wallet.

  `verify/2` validates the request shape (method, absolute path, string
  headers, optional body), then delegates to
  `Siwa.RequestAuth.verify_authenticated_request/2`, which checks:

    * the wallet receipt issued by `SiwaServer.Siwa.Wallet.verify/1`
      (signature, expiry, and audience binding),
    * the HTTP message signature over the covered components, within the
      configured timestamp tolerance,
    * the content-digest binding when a body is present, and
    * single use of the signature via `SiwaServer.Siwa.ReplayStore`.

  Each verified request is then recorded by `SiwaServer.Siwa.ActivityStore`,
  and the answer names the agent's registry entry when it registered one
  through this server (see `SiwaServer.AgentRegistration`), and the person
  World's AgentBook last named behind the wallet (see `SiwaServer.AgentBook`).

  Library error reasons are mapped to stable client-facing status/code
  tuples by the shared contract's `refusals` (`Siwa.Contract.refusal/1`).
  """

  alias SiwaServer.{AgentBook, AgentRegistration, Ethereum, RuntimeConfig}
  alias SiwaServer.Siwa.{ActivityStore, ReplayStore}
  alias SiwaServer.Text

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
             wallet_audiences: Map.keys(RuntimeConfig.siwa_wallet_origins()),
             signature_tolerance_seconds: RuntimeConfig.siwa_http_signature_tolerance_seconds(),
             replay_store: &ReplayStore.consume/2,
             chain_rpcs: Ethereum.chain_rpcs()
           ),
         :ok <- record_activity(verified.claims, Keyword.get(opts, :audience), method, path) do
      claims = verified.claims

      {:ok,
       %{
         "code" => "http_envelope_valid",
         "data" => %{
           "verified" => true,
           "walletAddress" => claims["sub"],
           "chainId" => claims["chain_id"],
           "keyId" => claims["key_id"],
           "verificationMethod" => Atom.to_string(verified.verification_method),
           "receiptExpiresAt" => unix_ms_to_iso8601(claims["exp"]),
           "requiredHeaders" => Siwa.required_authenticated_request_headers(body),
           "requiredCoveredComponents" =>
             Siwa.required_authenticated_request_components(headers, body),
           "coveredComponents" => verified.covered_components,
           "agentRegistration" => AgentRegistration.latest(claims["sub"]),
           "agentBook" => AgentBook.human(claims["sub"]),
           "principal" => %{
             "kind" => "wallet",
             "wallet_address" => claims["sub"],
             "chain_id" => claims["chain_id"],
             "audience" => claims["aud"]
           }
         }
       }}
    else
      {:error, {code, message}} -> {:error, {400, code, message}}
      {:error, {status, code, message}} -> {:error, {status, code, message}}
      {:error, reason} -> {:error, map_shared_error(reason)}
    end
  end

  defp required_string(params, key) do
    case Text.normalize_optional_text(Map.get(params, key)) do
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

  defp receipt_secret, do: RuntimeConfig.siwa_receipt_secret()

  defp record_activity(claims, audience, method, path) do
    case ActivityStore.record(claims["sub"], audience, method, path) do
      :ok -> :ok
      {:error, _reason} -> {:error, {500, "activity_record_failed", "could not record request"}}
    end
  end

  defp map_shared_error(reason) do
    case Siwa.Contract.refusal(reason) do
      nil -> {500, "request_replay_failed", "could not verify replay state"}
      refusal -> refusal
    end
  end

  defp unix_ms_to_iso8601(unix_ms),
    do: unix_ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()
end
