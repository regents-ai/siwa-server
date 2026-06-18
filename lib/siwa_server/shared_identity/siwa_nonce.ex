defmodule SiwaServer.SharedIdentity.SiwaNonce do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}
  schema "shared_identity_siwa_nonces" do
    field :nonce_token, :string
    field :network, :string
    field :address, :string
    field :agent_id, :integer
    field :agent_registry, :string
    field :message, :string
    field :expires_at, :utc_datetime
    field :used_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @required ~w(id nonce_token network address agent_id agent_registry message expires_at)a

  def changeset(nonce, attrs) do
    nonce
    |> cast(attrs, @required ++ [:used_at])
    |> validate_required(@required)
    |> unique_constraint(:nonce_token)
  end
end
