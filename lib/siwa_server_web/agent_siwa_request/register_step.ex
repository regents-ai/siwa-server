defmodule SiwaServerWeb.AgentSiwaRequest.RegisterStep do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  alias SiwaServerWeb.AgentSiwaRequest

  @primary_key false
  embedded_schema do
    field :wallet_address, :string
    field :name, :string
    field :description, :string
    field :image, :string
  end

  @type t :: %__MODULE__{
          wallet_address: String.t(),
          name: String.t(),
          description: String.t(),
          image: String.t() | nil
        }

  def changeset(params) do
    %__MODULE__{}
    |> cast(params, [:wallet_address, :name, :description, :image], empty_values: [])
    |> validate_required([:wallet_address])
    |> AgentSiwaRequest.validate_address(:wallet_address)
    |> AgentSiwaRequest.validate_profile()
  end
end
