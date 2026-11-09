defmodule SiwaServerWeb.AgentSiwaRequest.LinkChallenge do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  alias SiwaServerWeb.AgentSiwaRequest

  @primary_key false
  embedded_schema do
    field :wallet_address, :string
    field :chain_id, :integer
    field :token_id, :string
  end

  @type t :: %__MODULE__{
          wallet_address: String.t(),
          chain_id: pos_integer(),
          token_id: String.t()
        }

  def changeset(params) do
    %__MODULE__{}
    |> cast(params, [:wallet_address, :chain_id, :token_id], empty_values: [])
    |> validate_required([:wallet_address, :chain_id, :token_id])
    |> AgentSiwaRequest.validate_link()
  end
end
