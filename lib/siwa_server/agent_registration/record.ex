defmodule SiwaServer.AgentRegistration.Record do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  @required [:profile_id, :wallet_address, :name, :description, :token_id, :tx_hash]

  schema "agent_registrations" do
    field :profile_id, :string
    field :wallet_address, :string
    field :name, :string
    field :description, :string
    field :image, :string
    field :token_id, :string
    field :tx_hash, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:image | @required])
    |> validate_required(@required)
    |> unique_constraint(:token_id)
  end
end
