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

    assert {:ok, 1} = ReplayStore.cleanup_expired(now)

    assert replay_count("expired-replay") == 0
    assert replay_count("active-replay") == 1
  end

  test "cleanup_expired deletes at most one batch per call" do
    now = ~U[2026-04-22 12:00:00Z]
    insert_replay!("expired-replay-1", DateTime.add(now, -60, :second))
    insert_replay!("expired-replay-2", DateTime.add(now, -30, :second))

    assert {:ok, 1} = ReplayStore.cleanup_expired(now, 1)

    assert replay_count("expired-replay-1") + replay_count("expired-replay-2") == 1
  end

  test "consume allows only one concurrent use of a replay key" do
    expires_at = DateTime.utc_now() |> DateTime.add(60, :second) |> DateTime.to_unix()

    results =
      1..20
      |> Task.async_stream(
        fn _ -> ReplayStore.consume("race-replay", expires_at) end,
        max_concurrency: 20,
        timeout: 5_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &(&1 == :ok)) == 1
    assert Enum.count(results, &(&1 == {:error, :replayed_request})) == 19
    assert replay_count("race-replay") == 1
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
