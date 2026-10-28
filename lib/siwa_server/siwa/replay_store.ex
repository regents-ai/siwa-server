defmodule SiwaServer.Siwa.ReplayStore do
  @moduledoc false
  @behaviour Siwa.RequestAuth.ReplayStore

  alias SiwaServer.Repo
  @default_cleanup_limit 1_000

  # `synchronous_commit` is set for the transaction this statement runs in. Run on
  # its own, as every caller does, that is this one statement and nothing else on
  # the connection. Never call `consume/2` from inside a transaction that writes
  # anything else: the setting would last to that transaction's end and cover those
  # writes too.
  #
  # A key is accepted only when its row is written and its end is still ahead of the
  # database clock read after the write; that rule is the whole replay guard. The
  # refusal says "replayed" whenever another use of the key landed: the write was
  # tried and met the key's row, or a row for the key was already there. It says
  # "expired" only when nothing else landed, so an agent told to sign again never
  # repeats a request that already took effect.
  # A use refused as expired can still leave its row, so a later copy of the same
  # signed request would read "replayed" here; the library's time check refuses
  # that copy first, and a request signed again has a new key.
  #
  # "off" answers before the database's disk has confirmed the row. A database
  # crash can then lose every row written since the disk last confirmed (about
  # 600 ms normally, the whole pause while the disk is pausing), so a signed
  # request used in that time could be accepted once more before it expires.
  @impl Siwa.RequestAuth.ReplayStore
  def consume(replay_key, expires_at_unix) do
    expires_at = DateTime.from_unix!(expires_at_unix)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    case Repo.query(
           """
           WITH commit_mode AS (
             SELECT set_config('synchronous_commit', 'off', true)
           ), clock AS MATERIALIZED (
             SELECT clock_timestamp() AT TIME ZONE 'UTC' AS before_write
           ), consumed AS (
             INSERT INTO siwa_request_replays (id, replay_key, expires_at, inserted_at, updated_at)
             SELECT $1, $2, $3, $4, $4
             FROM commit_mode, clock
             WHERE $3::timestamp > clock.before_write
             ON CONFLICT (replay_key) DO NOTHING
             RETURNING id, expires_at
           )
           SELECT
             CASE
               WHEN EXISTS (
                 SELECT 1 FROM consumed
                 WHERE expires_at > (clock_timestamp() AT TIME ZONE 'UTC')
               )
                 THEN 'accepted'
               WHEN NOT EXISTS (SELECT 1 FROM consumed)
                 AND (
                   $3::timestamp > (SELECT before_write FROM clock)
                   OR EXISTS (SELECT 1 FROM siwa_request_replays WHERE replay_key = $2)
                 )
                 THEN 'replayed'
               ELSE 'expired'
             END
           """,
           [
             Ecto.UUID.generate() |> Ecto.UUID.dump!(),
             replay_key,
             expires_at,
             now
           ]
         ) do
      {:ok, %{rows: [["accepted"]]}} ->
        :ok

      {:ok, %{rows: [["replayed"]]}} ->
        {:error, :replayed_request}

      {:ok, %{rows: [["expired"]]}} ->
        {:error, :request_expired}

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
