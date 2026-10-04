defmodule SiwaServer.Siwa.NonceRecord do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @fields [
    :chain_id,
    :canonical_message,
    :nonce_key,
    :nonce,
    :address,
    :audience,
    :issued_at,
    :expiration_time
  ]

  schema "siwa_nonces" do
    field :chain_id, :integer
    field :canonical_message, :string
    field :nonce_key, :string
    field :nonce, :string
    field :address, :string
    field :audience, :string
    field :issued_at, :utc_datetime
    field :expiration_time, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, @fields)
    |> validate_required(@fields)
    |> validate_inclusion(:chain_id, SiwaServer.Ethereum.wallet_chain_ids())
    |> check_constraint(:chain_id, name: :siwa_nonces_wallet_chain)
    |> unique_constraint([:nonce_key, :nonce], name: :siwa_nonces_nonce_key_nonce_index)
  end
end
