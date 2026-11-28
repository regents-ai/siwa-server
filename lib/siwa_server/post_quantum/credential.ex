defmodule SiwaServer.PostQuantum.Credential do
  @moduledoc """
  Enrolled FIPS 204 `ML-DSA-65` post-quantum credential bound to an agent's
  canonical CAIP-10 subject (`eip155:<chain_id>:<wallet_address>`).

  Stores the raw 1,952-byte public key, canonical `pq_key_id`, monotonic
  signature policy (`ecc_only` < `hybrid_both` < `pq_only`), and optional
  algorithm deprecation/retirement timestamps.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  @policies ~w(ecc_only hybrid_both pq_only)

  schema "agent_credentials" do
    field :subject, :string
    field :wallet_address, :string
    field :chain_id, :integer
    field :pq_key_id, :string
    field :algorithm, :string, default: "mldsa65"
    field :alg_version, :integer, default: 1
    field :public_key, :binary
    field :policy, :string, default: "hybrid_both"
    field :deprecated_after, :utc_datetime
    field :retired_after, :utc_datetime
    field :enrolled_at, :utc_datetime
    field :revoked_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  @doc "Changeset for inserting a verified ML-DSA-65 agent credential."
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(credential \\ %__MODULE__{}, attrs) do
    credential
    |> cast(attrs, [
      :subject,
      :wallet_address,
      :chain_id,
      :pq_key_id,
      :algorithm,
      :alg_version,
      :public_key,
      :policy,
      :deprecated_after,
      :retired_after,
      :enrolled_at
    ])
    |> validate_required([
      :subject,
      :wallet_address,
      :chain_id,
      :pq_key_id,
      :algorithm,
      :alg_version,
      :public_key,
      :policy,
      :enrolled_at
    ])
    |> validate_inclusion(:algorithm, ["mldsa65"])
    |> validate_inclusion(:policy, @policies)
    |> validate_number(:alg_version, greater_than: 0)
    |> validate_change(:public_key, fn :public_key, key ->
      if is_binary(key) and byte_size(key) == 1_952,
        do: [],
        else: [public_key: "must be exactly 1952 raw ML-DSA-65 public key bytes"]
    end)
    |> unique_constraint(:pq_key_id)
  end
end
