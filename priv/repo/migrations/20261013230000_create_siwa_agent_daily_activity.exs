defmodule SiwaServer.Repo.Migrations.CreateSiwaAgentDailyActivity do
  use Ecto.Migration

  def change do
    create table(:siwa_agent_daily_activity, primary_key: false) do
      add :wallet_address, :string, null: false, primary_key: true
      add :audience, :string, null: false, primary_key: true
      add :day, :date, null: false, primary_key: true
      add :accepted, :bigint, null: false
      add :first_seen_at, :utc_datetime_usec, null: false
      add :last_seen_at, :utc_datetime_usec, null: false
    end

    create index(:siwa_agent_daily_activity, [:day])
  end
end
