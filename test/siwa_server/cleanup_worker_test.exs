defmodule SiwaServer.Siwa.CleanupWorkerTest do
  use SiwaServer.DataCase, async: false

  alias SiwaServer.Siwa.{CleanupWorker, NonceRecord}

  test "periodically removes expired nonce and replay rows" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    insert_nonce!("expired-nonce", DateTime.add(now, -60, :second))
    insert_nonce!("active-nonce", DateTime.add(now, 60, :second))
    insert_replay!("expired-replay", DateTime.add(now, -60, :second))
    insert_replay!("active-replay", DateTime.add(now, 60, :second))

    pid =
      start_supervised!(
        {CleanupWorker, enabled: true, interval_ms: 10, batch_size: 10, name: nil}
      )

    _ = :sys.get_state(pid)

    assert nonce_count("expired-nonce") == 0
    assert replay_count("expired-replay") == 0
    assert nonce_count("active-nonce") == 1
    assert replay_count("active-replay") == 1
  end

  test "uses the configured batch size for each cleanup run" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    insert_nonce!("expired-nonce-1", DateTime.add(now, -60, :second))
    insert_nonce!("expired-nonce-2", DateTime.add(now, -30, :second))
    insert_replay!("expired-replay-1", DateTime.add(now, -60, :second))
    insert_replay!("expired-replay-2", DateTime.add(now, -30, :second))

    assert {:ok, %{nonce_count: 1, replay_count: 1}} = CleanupWorker.cleanup_once(now, 1)

    assert nonce_count("expired-nonce-1") + nonce_count("expired-nonce-2") == 1
    assert replay_count("expired-replay-1") + replay_count("expired-replay-2") == 1
  end

  test "emits cleanup telemetry counts" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    insert_nonce!("expired-nonce", DateTime.add(now, -60, :second))
    insert_replay!("expired-replay", DateTime.add(now, -60, :second))

    handler_id = {__MODULE__, self(), :cleanup_telemetry}

    :telemetry.attach(
      handler_id,
      [:siwa_server, :siwa, :cleanup],
      fn _event, measurements, metadata, test_pid ->
        send(test_pid, {:cleanup_telemetry, measurements, metadata})
      end,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, %{nonce_count: 1, replay_count: 1}} = CleanupWorker.cleanup_once(now, 10)

    assert_receive {:cleanup_telemetry, %{duration: duration, nonce_count: 1, replay_count: 1},
                    %{result: :ok}}

    assert is_integer(duration)
  end

  defp insert_nonce!(nonce, expiration_time) do
    %NonceRecord{}
    |> NonceRecord.changeset(%{
      nonce_key: "key-#{nonce}",
      nonce: nonce,
      address: "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266",
      agent_id: "77",
      agent_registry: "eip155:84532:0x3333333333333333333333333333333333333333",
      audience: "platform",
      issued_at: DateTime.add(expiration_time, -300, :second),
      expiration_time: expiration_time
    })
    |> Repo.insert!()
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

  defp nonce_count(nonce) do
    Repo.aggregate(from(n in NonceRecord, where: n.nonce == ^nonce), :count, :id)
  end

  defp replay_count(replay_key) do
    %Postgrex.Result{rows: [[count]]} =
      Repo.query!("SELECT COUNT(*) FROM siwa_request_replays WHERE replay_key = $1", [replay_key])

    count
  end
end
