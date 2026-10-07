defmodule SiwaServer.Repo.Migrations.AcceptedPersonIsPermanent do
  use Ecto.Migration

  # The accepted person is kept for good, so the saved AgentBook answers are no
  # longer read; the same-person count reads the acceptances instead.
  def up do
    drop table(:agent_book_humans)
    create index(:agent_book_acceptances, [:human_id])
  end

  def down do
    drop index(:agent_book_acceptances, [:human_id])

    create table(:agent_book_humans, primary_key: false) do
      add :wallet_address, :string, primary_key: true
      add :human_id, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:agent_book_humans, [:human_id])
  end
end
