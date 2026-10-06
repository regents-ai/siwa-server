defmodule SiwaServer.Repo.Migrations.CreateAgentBookAcceptances do
  use Ecto.Migration

  def change do
    create table(:agent_book_acceptances, primary_key: false) do
      add :wallet_address, :string, primary_key: true
      add :human_id, :string, null: false

      timestamps(type: :utc_datetime)
    end
  end
end
