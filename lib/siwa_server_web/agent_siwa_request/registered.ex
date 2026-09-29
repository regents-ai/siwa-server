defmodule SiwaServerWeb.AgentSiwaRequest.Registered do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  alias SiwaServerWeb.AgentSiwaRequest

  @primary_key false
  embedded_schema do
    field :wallet_address, :string
    field :agent_uri, :string
    field :tx_hash, :string
  end

  @type t :: %__MODULE__{
          wallet_address: String.t(),
          agent_uri: String.t() | nil,
          tx_hash: String.t()
        }

  def changeset(params) do
    %__MODULE__{}
    |> cast(params, [:wallet_address, :agent_uri, :tx_hash], empty_values: [])
    |> validate_required([:wallet_address, :tx_hash])
    |> AgentSiwaRequest.validate_address(:wallet_address)
    |> AgentSiwaRequest.validate_nonblank([:agent_uri])
    |> validate_format(:tx_hash, ~r/^0x[0-9a-fA-F]{64}$/)
  end
end
