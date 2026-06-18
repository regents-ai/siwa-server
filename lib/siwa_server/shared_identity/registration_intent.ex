defmodule SiwaServer.SharedIdentity.RegistrationIntent do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}
  schema "shared_identity_registration_intents" do
    field :network, :string
    field :address, :string
    field :provider, :string
    field :message, :string
    field :expires_at, :utc_datetime
    field :used_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @required ~w(id network address provider message expires_at)a

  def changeset(intent, attrs) do
    intent
    |> cast(attrs, @required ++ [:used_at])
    |> validate_required(@required)
  end
end
