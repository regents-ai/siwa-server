defmodule SiwaServer.Repo.Migrations.CreateSiwaRequestReplays do
  use Ecto.Migration

  def change do
    create table(:siwa_request_replays, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :replay_key, :string, null: false
      add :expires_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:siwa_request_replays, [:replay_key])
    create index(:siwa_request_replays, [:expires_at])
  end
end
