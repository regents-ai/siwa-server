defmodule SiwaServer.Repo.Migrations.AddLeasesToSiwaAgentDailyActivity do
  use Ecto.Migration

  def change do
    alter table(:siwa_agent_daily_activity) do
      add :leases, :bigint, null: false, default: 0
    end
  end
end
