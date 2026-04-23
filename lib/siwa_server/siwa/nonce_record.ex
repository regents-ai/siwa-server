defmodule SiwaServer.Siwa.NonceRecord do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "siwa_nonces" do
    field :nonce_key, :string
    field :nonce, :string
    field :address, :string
    field :agent_id, :string
    field :agent_registry, :string
    field :audience, :string
    field :issued_at, :utc_datetime
    field :expiration_time, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [
      :nonce_key,
      :nonce,
      :address,
      :agent_id,
      :agent_registry,
      :audience,
      :issued_at,
      :expiration_time
    ])
    |> validate_required([
      :nonce_key,
      :nonce,
      :address,
      :agent_id,
      :agent_registry,
      :audience,
      :issued_at,
      :expiration_time
    ])
    |> unique_constraint([:nonce_key, :nonce], name: :siwa_nonces_nonce_key_nonce_index)
  end
end
