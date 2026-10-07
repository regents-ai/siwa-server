defmodule SiwaServer.Repo.Migrations.IndexAgentBookHumansByHuman do
  use Ecto.Migration

  def change do
    create index(:agent_book_humans, [:human_id])
  end
end
