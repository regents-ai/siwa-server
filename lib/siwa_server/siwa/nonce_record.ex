defmodule SiwaServer.Siwa.NonceRecord do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "siwa_nonces" do
    field :principal_kind, :string, default: "agent"
    field :chain_id, :integer
    field :canonical_message, :string
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
      :principal_kind,
      :chain_id,
      :canonical_message,
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
      :principal_kind,
      :nonce_key,
      :nonce,
      :address,
      :audience,
      :issued_at,
      :expiration_time
    ])
    |> validate_inclusion(:principal_kind, ["agent", "wallet"])
    |> validate_principal()
    |> check_constraint(:principal_kind, name: :siwa_nonces_principal_shape)
    |> unique_constraint([:nonce_key, :nonce], name: :siwa_nonces_nonce_key_nonce_index)
  end

  defp validate_principal(changeset) do
    case get_field(changeset, :principal_kind) do
      "wallet" ->
        changeset
        |> validate_required([:chain_id, :canonical_message])
        |> validate_inclusion(:chain_id, [8453])

      _ ->
        validate_required(changeset, [:agent_id, :agent_registry])
    end
  end
end
