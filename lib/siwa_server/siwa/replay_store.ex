defmodule SiwaServer.Siwa.ReplayStore do
  @moduledoc false

  alias SiwaServer.Repo
  @default_cleanup_limit 1_000

  def consume(replay_key, expires_at_unix) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    expires_at = DateTime.from_unix!(expires_at_unix)

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
           [DateTime.truncate(now, :second), limit]
         ) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
