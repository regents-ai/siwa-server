defmodule SiwaServer.Siwa.Message do
  @moduledoc false

  alias SiwaServer.RuntimeConfig
  alias SiwaServer.Siwa.Error

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
  def validate(message, wallet_address, chain_id, agent_registry, token_id, audience, nonce) do
    expected = %{
      domain: RuntimeConfig.siwa_domain(),
      address: wallet_address,
      uri: RuntimeConfig.siwa_verify_uri(),
      agent_id: String.to_integer(token_id),
      agent_registry: agent_registry,
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
end
