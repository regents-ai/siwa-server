defmodule SiwaServer.Repo.Migrations.WidenRequestReplayKey do
  use Ecto.Migration

  def change do
    execute("SET LOCAL lock_timeout = '5s'", "SET LOCAL lock_timeout = '5s'")

    alter table(:siwa_request_replays) do
      modify :replay_key, :text, from: :string
    end
  end
end
