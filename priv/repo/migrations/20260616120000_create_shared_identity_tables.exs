defmodule SiwaServer.Repo.Migrations.CreateSharedIdentityTables do
  use Ecto.Migration

  def up do
    create table(:shared_identity_records) do
      add :network, :string, null: false
      add :address, :string, null: false
      add :provider, :string, null: false
      add :agent_registry, :string, null: false
      add :verified, :string, null: false
      add :registered_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:shared_identity_records, [:network, :provider, :address])

    create table(:shared_identity_registration_intents, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :network, :string, null: false
      add :address, :string, null: false
      add :provider, :string, null: false
      add :message, :text, null: false
      add :expires_at, :utc_datetime, null: false
      add :used_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:shared_identity_registration_intents, [:address, :network, :provider])
    create index(:shared_identity_registration_intents, [:expires_at])

    create table(:shared_identity_siwa_nonces, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :nonce_token, :string, null: false
      add :network, :string, null: false
      add :address, :string, null: false
      add :agent_id, :bigint, null: false
      add :agent_registry, :string, null: false
      add :message, :text, null: false
      add :expires_at, :utc_datetime, null: false
      add :used_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:shared_identity_siwa_nonces, [:nonce_token])
    create index(:shared_identity_siwa_nonces, [:address, :network, :agent_id])
    create index(:shared_identity_siwa_nonces, [:expires_at])
  end

  def down do
    raise "shared identity tables are additive; restore from backup to reverse"
  end
end
