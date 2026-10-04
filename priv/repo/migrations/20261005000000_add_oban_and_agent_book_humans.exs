defmodule SiwaServer.Repo.Migrations.AddObanAndAgentBookHumans do
  use Ecto.Migration

  def up do
    Oban.Migrations.up()

    create table(:agent_book_humans, primary_key: false) do
      add :wallet_address, :string, primary_key: true
      add :human_id, :string, null: false

      timestamps(type: :utc_datetime)
    end
  end

  def down do
    drop table(:agent_book_humans)
    Oban.Migrations.down(version: 1)
  end
end
