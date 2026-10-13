defmodule SiwaServer.Siwa.ReplayStore do
  @moduledoc false
  @behaviour Siwa.RequestAuth.ReplayStore

  alias SiwaServer.Repo
  @default_cleanup_limit 1_000

  @impl Siwa.RequestAuth.ReplayStore
  def consume(replay_key, expires_at_unix) do
    consume_until(replay_key, DateTime.from_unix!(expires_at_unix), "off")
  end

  def consume_keyring_request(request_id, expires_at_ms) do
    consume_until(
      "keyring:" <> request_id,
      DateTime.from_unix!(expires_at_ms, :millisecond),
      "on"
    )
  end

  # `synchronous_commit` is set for the transaction this statement runs in. Run on
  # its own, as every caller does, that is this one statement and nothing else on
  # the connection. Never call `consume/2` from inside a transaction that writes
  # anything else: the setting would last to that transaction's end and cover those
  # writes too.
  #
  # "off" answers before the database's disk has confirmed the row. A database
  # crash can then lose every row written since the disk last confirmed (about
  # 600 ms normally, the whole pause while the disk is pausing), so a signed
  # request used in that time could be accepted once more before it expires. Only
  # a signed HTTP request's single use takes that trade. Keyring requests keep
  # "on".
  defp consume_until(replay_key, expires_at, synchronous_commit) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    expires_at = DateTime.truncate(expires_at, :second)

    case Repo.query(
           """
           WITH commit_mode AS (
             SELECT set_config('synchronous_commit', $5, true)
           ), consumed AS (
             INSERT INTO siwa_request_replays (id, replay_key, expires_at, inserted_at, updated_at)
             SELECT $1, $2, $3, $4, $4
             FROM commit_mode
             WHERE $3::timestamp > (clock_timestamp() AT TIME ZONE 'UTC')
             ON CONFLICT (replay_key) DO NOTHING
             RETURNING id, expires_at
           )
           SELECT id FROM consumed
           WHERE expires_at > (clock_timestamp() AT TIME ZONE 'UTC')
           """,
           [
             Ecto.UUID.generate() |> Ecto.UUID.dump!(),
             replay_key,
             expires_at,
             now,
             synchronous_commit
           ]
         ) do
      {:ok, %{rows: [[_id]]}} ->
        :ok

      {:ok, %{rows: []}} ->
        {:error, :replayed_request}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def cleanup_expired(now \\ DateTime.utc_now(), limit \\ @default_cleanup_limit) do
    case Repo.query(
           """
           DELETE FROM siwa_request_replays
           WHERE id IN (
             SELECT id
             FROM siwa_request_replays
             WHERE expires_at <= $1
             ORDER BY expires_at
             LIMIT $2
           )
           """,
           [DateTime.truncate(now, :second), limit],
           log: false
         ) do
      {:ok, %{num_rows: count}} -> {:ok, count}
      {:error, reason} -> {:error, reason}
    end
  end
end
