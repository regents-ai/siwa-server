defmodule SiwaServer.Repo.Migrations.CreateAgentRegistrations do
  use Ecto.Migration

  def change do
    create table(:agent_registrations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :profile_id, :string, null: false
      add :wallet_address, :string, null: false
      add :name, :text, null: false
      add :description, :text, null: false
      add :image, :text
      add :token_id, :string, null: false
      add :tx_hash, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:agent_registrations, [:token_id])
    create unique_index(:agent_registrations, [:tx_hash])
    create index(:agent_registrations, [:profile_id])
    create index(:agent_registrations, [:wallet_address, :inserted_at])
  end
end
