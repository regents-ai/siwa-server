defmodule SiwaServer.ReplayEndDuringWriteTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias SiwaServer.Repo
  alias SiwaServer.Siwa.ReplayStore

  # A first use whose write waits past the key's end is refused as expired, not as a
  # repeat. Another connection holds the same key unwritten until after the end, so
  # the write lands late; each connection works in its own rolled-back sandbox.
  test "a key whose end passes while its write waits is refused as expired" do
    key = "replay-end-during-write:#{Ecto.UUID.generate()}"
    ends = System.system_time(:second) + 2
    parent = self()

    holder =
      Task.async(fn ->
        :ok = Sandbox.checkout(Repo)

        Repo.query!(
          """
          INSERT INTO siwa_request_replays (id, replay_key, expires_at, inserted_at, updated_at)
          VALUES ($1, $2, $3, $4, $4)
          """,
          [
            Ecto.UUID.generate() |> Ecto.UUID.dump!(),
            key,
            DateTime.from_unix!(ends),
            DateTime.utc_now() |> DateTime.truncate(:second)
          ]
        )

        send(parent, :holding)
        Process.sleep(ends * 1000 - System.system_time(:millisecond) + 400)
        Sandbox.checkin(Repo)
      end)

    assert_receive :holding, 5_000

    consumer =
      Task.async(fn ->
        :ok = Sandbox.checkout(Repo)
        ReplayStore.consume(key, ends)
      end)

    assert Task.await(consumer, 10_000) == {:error, :request_expired}
    assert Task.await(holder, 10_000) == :ok
  end
end
