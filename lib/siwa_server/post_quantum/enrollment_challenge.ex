defmodule SiwaServer.PostQuantum.EnrollmentChallenge do
  @moduledoc """
  Single-use, 5-minute dual Proof-of-Possession challenge binding an agent's
  wallet (`eip155:<chain_id>:<wallet_address>`) to a candidate FIPS 204
  `ML-DSA-65` public key prior to enrollment.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "pq_enrollment_challenges" do
    field :subject, :string
    field :wallet_address, :string
    field :chain_id, :integer
    field :pq_key_id, :string
    field :algorithm, :string, default: "mldsa65"
    field :public_key, :binary
    field :nonce, :string
    field :canonical_message, :string
    field :issued_at, :utc_datetime
    field :expiration_time, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}
end
