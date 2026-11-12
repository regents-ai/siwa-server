defmodule SiwaServer.Repo.Migrations.DropSiwaRequestActivity do
  use Ecto.Migration

  # The one-line-per-request record was replaced by one total per agent, site and
  # day on 14 October 2026 and has not been written or read since. Its rows were
  # kept 30 days, so by now it holds nothing a reader could ask for.
  def up do
    drop table(:siwa_request_activity)
  end

  def down do
    create table(:siwa_request_activity, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :wallet_address, :string, null: false
      add :audience, :string, null: false
      add :method, :string, null: false
      add :path, :string, null: false, size: 2048
      add :occurred_at, :utc_datetime_usec, null: false
    end

    create index(:siwa_request_activity, [:wallet_address, :occurred_at])
    create index(:siwa_request_activity, [:occurred_at])
  end
end
