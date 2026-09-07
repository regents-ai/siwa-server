defmodule SiwaServer.Siwa.Message do
  @moduledoc false

  alias SiwaServer.Siwa.Error

  @domain "regent.cx"
  @verify_uri "https://regent.cx/api/shared/siwa/verify"

  @spec validate(
          String.t(),
          String.t(),
          pos_integer(),
          String.t(),
          String.t(),
          String.t(),
          String.t()
        ) ::
          :ok | {:error, {401, String.t(), String.t()}}
  def validate(message, wallet_address, chain_id, registry_address, token_id, audience, nonce) do
    expected = %{
      domain: @domain,
      address: wallet_address,
      uri: @verify_uri,
      agent_id: String.to_integer(token_id),
      agent_registry: agent_registry_string(chain_id, registry_address),
      chain_id: chain_id,
      nonce: nonce,
      statement: audience_statement(audience)
    }

    case Siwa.Message.validate_canonical(message, expected) do
      :ok ->
        :ok

      {:error, :invalid_canonical_message} ->
        Error.error(
          Error.unauthorized(
            "signature_invalid",
            "message does not match the canonical SIWA format"
          )
        )

      # The library contract allows exactly the two results above; anything else
      # still raises as the former `with`/`else` did.
      other ->
        raise WithClauseError, term: other
    end
  end

  defp audience_statement(audience), do: "Sign in to #{audience}."

  defp agent_registry_string(chain_id, registry_address),
    do: "eip155:#{chain_id}:#{registry_address}"
end
