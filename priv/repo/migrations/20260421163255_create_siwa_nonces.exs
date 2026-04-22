defmodule SiwaServer.Repo.Migrations.CreateSiwaNonces do
  use Ecto.Migration

  def change do
    create table(:siwa_nonces, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :nonce_key, :string, null: false
      add :nonce, :string, null: false
      add :address, :string, null: false
      add :agent_id, :bigint, null: false
      add :agent_registry, :string, null: false
      add :audience, :string, null: false
      add :issued_at, :utc_datetime, null: false
      add :expiration_time, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:siwa_nonces, [:nonce_key, :nonce])
    create index(:siwa_nonces, [:expiration_time])
  end
end
