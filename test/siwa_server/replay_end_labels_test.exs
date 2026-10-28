defmodule SiwaServer.ReplayEndLabelsTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias SiwaServer.Repo
  alias SiwaServer.Siwa.ReplayStore

  # A refused key is "expired" only when no other use of it landed; whenever one did,
  # it is "replayed", so an agent told to sign again never repeats a request that
  # already took effect. Each case makes a key's end pass while its use is in flight.

  test "a first use whose write waits past the key's end is refused as expired" do
    key = "replay-end:#{Ecto.UUID.generate()}"
    ends = System.system_time(:second) + 3
    parent = self()

    # Holds the key unwritten until after its end, then rolls back.
    holder =
      Task.async(fn ->
        :ok = Sandbox.checkout(Repo)
        insert!(key, ends)
        send(parent, :holding)
        Process.sleep(ends * 1000 - System.system_time(:millisecond) + 400)
        Sandbox.checkin(Repo)
      end)

    assert_receive :holding, 5_000

    consumer =
      Task.async(fn ->
        :ok = Sandbox.checkout(Repo)
        {ReplayStore.consume(key, ends), rows(key)}
      end)

    # The row is written, so the use waited on the holder rather than meeting a key
    # that had already ended.
    assert Task.await(consumer, 10_000) == {{:error, :request_expired}, 1}
    assert Task.await(holder, 10_000) == :ok
  end

  test "a use whose twin lands while it waits past the key's end is refused as replayed" do
    key = "replay-end:#{Ecto.UUID.generate()}"
    ends = System.system_time(:second) + 3
    parent = self()
    on_exit(fn -> Sandbox.unboxed_run(Repo, fn -> delete!(key) end) end)

    # The twin's use, committed after the key's end.
    holder =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Repo.transaction(fn ->
            insert!(key, ends)
            send(parent, :holding)
            Process.sleep(ends * 1000 - System.system_time(:millisecond) + 400)
          end)
        end)
      end)

    assert_receive :holding, 5_000

    consumer =
      Task.async(fn ->
        :ok = Sandbox.checkout(Repo)
        ReplayStore.consume(key, ends)
      end)

    assert Task.await(consumer, 10_000) == {:error, :replayed_request}
    assert {:ok, _} = Task.await(holder, 10_000)
  end

  test "a use whose twin already landed is refused as replayed after the key's end" do
    key = "replay-end:#{Ecto.UUID.generate()}"
    ends = System.system_time(:second) - 1

    :ok = Sandbox.checkout(Repo)
    insert!(key, ends)
    assert ReplayStore.consume(key, ends) == {:error, :replayed_request}
    Sandbox.checkin(Repo)
  end

  defp insert!(key, ends) do
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
  end

  defp rows(key) do
    %{rows: [[count]]} =
      Repo.query!("SELECT count(*) FROM siwa_request_replays WHERE replay_key = $1", [key])

    count
  end

  defp delete!(key),
    do: Repo.query!("DELETE FROM siwa_request_replays WHERE replay_key = $1", [key])
end
