defmodule SiwaServer.Repo.Migrations.CreateSiwaRateLimits do
  use Ecto.Migration

  # Request counts per limit, key and window, shared by every machine. A count is
  # worth nothing after its window, so the table skips the write-ahead log.
  def change do
    create table(:siwa_rate_limits, primary_key: false) do
      add :name, :text, null: false, primary_key: true
      add :key, :binary, null: false, primary_key: true
      add :bucket, :bigint, null: false, primary_key: true
      add :count, :integer, null: false
      add :expires_at, :utc_datetime_usec, null: false
    end

    execute "ALTER TABLE siwa_rate_limits SET UNLOGGED", "ALTER TABLE siwa_rate_limits SET LOGGED"

    create index(:siwa_rate_limits, [:expires_at])
  end
end
