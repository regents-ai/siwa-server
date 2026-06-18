defmodule SiwaServer.SharedIdentity.IdentityRecord do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  schema "shared_identity_records" do
    field :network, :string
    field :address, :string
    field :provider, :string
    field :agent_registry, :string
    field :verified, :string
    field :registered_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @required ~w(network address provider agent_registry verified registered_at)a

  def changeset(record, attrs) do
    record
    |> cast(attrs, @required)
    |> validate_required(@required)
    |> unique_constraint([:network, :provider, :address])
  end
end
