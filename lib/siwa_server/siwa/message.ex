defmodule SiwaServer.Siwa.Message do
  @moduledoc false

  alias SiwaServer.Siwa.Error

  @domain "regent.cx"
  @verify_uri "https://regent.cx/v1/agent/siwa/verify"
  @positive_int_regex ~r/^[1-9][0-9]*$/

  @spec validate(String.t(), String.t(), pos_integer(), String.t(), String.t(), String.t()) ::
          :ok | {:error, {401, String.t(), String.t()}}
  def validate(message, wallet_address, chain_id, registry_address, token_id, nonce) do
    with {:ok, parsed} <- parse(message),
         true <- parsed.wallet_address == wallet_address,
         true <- parsed.chain_id == chain_id,
         true <- parsed.registry_address == registry_address,
         true <- parsed.token_id == token_id,
         true <- parsed.nonce == nonce do
      :ok
    else
      {:error, reason} ->
        Error.error(Error.unauthorized("signature_invalid", reason))

      false ->
        Error.error(
          Error.unauthorized(
            "signature_invalid",
            "message does not match the requested SIWA claims"
          )
        )
    end
  end

  defp parse(message) when is_binary(message) do
    with {:ok, fields} <- Siwa.Message.parse(String.trim(message)),
         true <- fields.domain == @domain,
         true <- fields.uri == @verify_uri,
         true <- Map.get(fields, :version, "1") == "1",
         {:ok, registry} <- parse_agent_registry(fields.agent_registry),
         true <- registry.chain_id == fields.chain_id,
         :ok <- validate_issued_at(fields.issued_at) do
      {:ok,
       %{
         wallet_address: String.downcase(String.trim(fields.address)),
         chain_id: fields.chain_id,
         registry_address: registry.address,
         token_id: Integer.to_string(fields.agent_id),
         nonce: fields.nonce,
         issued_at: fields.issued_at,
         statement: Map.get(fields, :statement)
       }}
    else
      false -> {:error, "message does not match the canonical SIWA format"}
      _ -> {:error, "message does not match the canonical SIWA format"}
    end
  end

  defp parse(_message), do: {:error, "message does not match the canonical SIWA format"}

  defp parse_agent_registry("eip155:" <> rest) do
    with [chain_id, registry_address] <- String.split(rest, ":", parts: 2),
         true <- Regex.match?(@positive_int_regex, chain_id) do
      {:ok,
       %{
         chain_id: String.to_integer(chain_id),
         address: String.downcase(String.trim(registry_address))
       }}
    else
      _ -> {:error, :invalid_agent_registry}
    end
  end

  defp parse_agent_registry(_value), do: {:error, :invalid_agent_registry}

  defp validate_issued_at(issued_at) do
    case DateTime.from_iso8601(issued_at) do
      {:ok, _datetime, 0} -> :ok
      _ -> {:error, :invalid_issued_at}
    end
  end
end
