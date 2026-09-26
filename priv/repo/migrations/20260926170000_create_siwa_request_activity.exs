defmodule SiwaServer.Repo.Migrations.CreateSiwaRequestActivity do
  use Ecto.Migration

  def change do
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
