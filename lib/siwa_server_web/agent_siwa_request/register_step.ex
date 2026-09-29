defmodule SiwaServerWeb.AgentSiwaRequest.RegisterStep do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  alias SiwaServerWeb.AgentSiwaRequest

  @primary_key false
  embedded_schema do
    field :wallet_address, :string
    field :agent_uri, :string
  end

  @type t :: %__MODULE__{wallet_address: String.t(), agent_uri: String.t() | nil}

  def changeset(params) do
    %__MODULE__{}
    |> cast(params, [:wallet_address, :agent_uri], empty_values: [])
    |> validate_required([:wallet_address])
    |> AgentSiwaRequest.validate_address(:wallet_address)
    |> AgentSiwaRequest.validate_nonblank([:agent_uri])
  end
end
