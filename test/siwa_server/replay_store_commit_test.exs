defmodule SiwaServer.Siwa.ReplayStoreCommitTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias SiwaServer.Repo
  alias SiwaServer.Siwa.ReplayStore

  test "a signed request's single use does not wait for the disk and leaves the connection waiting" do
    assert String.starts_with?(Repo.config()[:database], "siwa_server_test")
    replay_key = "commit-mode:#{Ecto.UUID.generate()}"
    expires_at = DateTime.utc_now() |> DateTime.add(60, :second) |> DateTime.to_unix()

    Sandbox.unboxed_run(Repo, fn ->
      assert synchronous_commit() == "on"

      assert {:error, :used_twice} =
               Repo.transaction(fn ->
                 assert :ok = ReplayStore.consume(replay_key, expires_at)
                 assert synchronous_commit() == "off"
                 assert {:error, :replayed_request} = ReplayStore.consume(replay_key, expires_at)
                 Repo.rollback(:used_twice)
               end)

      assert synchronous_commit() == "on"
    end)
  end

  defp synchronous_commit do
    %Postgrex.Result{rows: [[value]]} = Repo.query!("SHOW synchronous_commit")
    value
  end
end
