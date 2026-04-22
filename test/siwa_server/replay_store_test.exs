defmodule SiwaServer.Siwa.ReplayStoreTest do
  use SiwaServer.DataCase, async: false

  alias SiwaServer.Siwa.ReplayStore

  test "consume no longer cleans expired replay rows on the hot path" do
    now = ~U[2026-04-22 12:00:00Z]
    insert_replay!("expired-replay", DateTime.add(now, -60, :second))

    assert :ok =
             ReplayStore.consume("fresh-replay", DateTime.to_unix(DateTime.add(now, 60, :second)))

    assert replay_count("expired-replay") == 1
    assert replay_count("fresh-replay") == 1
  end

  test "cleanup_expired removes expired replay rows and keeps active ones" do
    now = ~U[2026-04-22 12:00:00Z]
    insert_replay!("expired-replay", DateTime.add(now, -60, :second))
    insert_replay!("active-replay", DateTime.add(now, 60, :second))

    assert :ok = ReplayStore.cleanup_expired(now)

    assert replay_count("expired-replay") == 0
    assert replay_count("active-replay") == 1
  end

  test "cleanup_expired deletes at most one batch per call" do
    now = ~U[2026-04-22 12:00:00Z]
    insert_replay!("expired-replay-1", DateTime.add(now, -60, :second))
    insert_replay!("expired-replay-2", DateTime.add(now, -30, :second))

    assert :ok = ReplayStore.cleanup_expired(now, 1)

    assert replay_count("expired-replay-1") + replay_count("expired-replay-2") == 1
  end

  defp insert_replay!(replay_key, expires_at) do
    now = DateTime.add(expires_at, -60, :second)

    Repo.query!(
      """
      INSERT INTO siwa_request_replays (id, replay_key, expires_at, inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, $4)
      """,
      [Ecto.UUID.generate() |> Ecto.UUID.dump!(), replay_key, expires_at, now]
    )
  end

  defp replay_count(replay_key) do
    %Postgrex.Result{rows: [[count]]} =
      Repo.query!("SELECT COUNT(*) FROM siwa_request_replays WHERE replay_key = $1", [replay_key])

    count
  end
end
