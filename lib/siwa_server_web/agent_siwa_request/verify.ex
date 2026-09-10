defmodule SiwaServerWeb.AgentSiwaRequest.Verify do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  alias SiwaServerWeb.AgentSiwaRequest

  @base_chain_id 8453
  @fields [
    :wallet_address,
    :chain_id,
    :registry_address,
    :token_id,
    :audience,
    :nonce,
    :message,
    :signature
  ]

  @primary_key false
  embedded_schema do
    field :wallet_address, :string
    field :chain_id, :integer
    field :registry_address, :string
    field :token_id, :string
    field :audience, :string
    field :nonce, :string
    field :message, :string
    field :signature, :string
  end

  @type t :: %__MODULE__{
          wallet_address: String.t(),
          chain_id: pos_integer(),
          registry_address: String.t(),
          token_id: String.t(),
          audience: String.t(),
          nonce: String.t(),
          message: String.t(),
          signature: String.t()
        }

  def changeset(params) do
    %__MODULE__{}
    |> cast(params, @fields, empty_values: [])
    |> validate_required(@fields)
    |> validate_inclusion(:chain_id, [@base_chain_id])
    |> AgentSiwaRequest.ensure_integer_param(params, :chain_id)
    |> AgentSiwaRequest.validate_nonblank(@fields -- [:chain_id])
  end
end
