defmodule SiwaServer.Repo.Migrations.CreateSiwaPqCredentials do
  use Ecto.Migration

  # Stage 2 additive schema for SIWA v3 hybrid post-quantum agent credentials.
  # Zero changes to existing v2 tables (`siwa_nonces`, `siwa_request_replays`, etc.).

  def change do
    create table(:agent_credentials, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :subject, :string, null: false
      add :wallet_address, :string, null: false
      add :chain_id, :integer, null: false
      add :pq_key_id, :string, null: false
      add :algorithm, :string, null: false, default: "mldsa65"
      add :alg_version, :integer, null: false, default: 1
      add :public_key, :binary, null: false
      add :policy, :string, null: false, default: "hybrid_both"
      add :deprecated_after, :utc_datetime
      add :retired_after, :utc_datetime
      add :enrolled_at, :utc_datetime, null: false
      add :revoked_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:agent_credentials, [:pq_key_id])
    create index(:agent_credentials, [:subject, :revoked_at])
    create index(:agent_credentials, [:wallet_address, :chain_id])

    create constraint(:agent_credentials, :agent_credentials_policy_check,
             check: "policy IN ('ecc_only', 'hybrid_both', 'pq_only')"
           )

    create constraint(:agent_credentials, :agent_credentials_algorithm_check,
             check: "algorithm = 'mldsa65' AND octet_length(public_key) = 1952"
           )

    create constraint(:agent_credentials, :agent_credentials_alg_version_positive,
             check: "alg_version > 0"
           )

    create table(:pq_enrollment_challenges, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :subject, :string, null: false
      add :wallet_address, :string, null: false
      add :chain_id, :integer, null: false
      add :pq_key_id, :string, null: false
      add :algorithm, :string, null: false, default: "mldsa65"
      add :public_key, :binary, null: false
      add :nonce, :string, null: false
      add :canonical_message, :text, null: false
      add :issued_at, :utc_datetime, null: false
      add :expiration_time, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:pq_enrollment_challenges, [:nonce])
    create index(:pq_enrollment_challenges, [:subject, :pq_key_id])
    create index(:pq_enrollment_challenges, [:expiration_time])

    create constraint(:pq_enrollment_challenges, :pq_enrollment_pubkey_length,
             check: "algorithm = 'mldsa65' AND octet_length(public_key) = 1952"
           )
  end
end
