defmodule SiwaServer.Siwa.ReplayStore do
  @moduledoc false
  @behaviour Siwa.RequestAuth.ReplayStore

  alias SiwaServer.Repo
  @default_cleanup_limit 1_000

  @impl Siwa.RequestAuth.ReplayStore
  def consume(replay_key, expires_at_unix) do
    consume_until(replay_key, DateTime.from_unix!(expires_at_unix))
  end

  def consume_keyring_request(request_id, expires_at_ms) do
    consume_until("keyring:" <> request_id, DateTime.from_unix!(expires_at_ms, :millisecond))
  end

  defp consume_until(replay_key, expires_at) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    expires_at = DateTime.truncate(expires_at, :second)

    case Repo.query(
           """
           INSERT INTO siwa_request_replays (id, replay_key, expires_at, inserted_at, updated_at)
           VALUES ($1, $2, $3, $4, $4)
           ON CONFLICT (replay_key) DO NOTHING
           RETURNING id
           """,
           [Ecto.UUID.generate() |> Ecto.UUID.dump!(), replay_key, expires_at, now]
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
