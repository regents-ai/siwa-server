defmodule SiwaServer.Siwa.ReplayStore do
  @moduledoc false

  alias SiwaServer.Repo

  def consume(replay_key, expires_at_unix) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    expires_at = DateTime.from_unix!(expires_at_unix)

    Repo.transaction(fn ->
      case Repo.query(
             """
             INSERT INTO siwa_request_replays (id, replay_key, expires_at, inserted_at, updated_at)
             VALUES ($1, $2, $3, $4, $4)
             ON CONFLICT (replay_key) DO NOTHING
             RETURNING id
             """,
             [Ecto.UUID.generate() |> Ecto.UUID.dump!(), replay_key, expires_at, now]
           ) do
        {:ok, %{rows: []}} ->
          Repo.rollback(:replayed_request)

        {:ok, %{rows: [[_id]]}} ->
          :ok

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, :replayed_request} -> {:error, :replayed_request}
      {:error, reason} -> {:error, reason}
    end
  end

  def cleanup_expired(now \\ DateTime.utc_now()) do
    case Repo.query(
           "DELETE FROM siwa_request_replays WHERE expires_at <= $1",
           [DateTime.truncate(now, :second)]
         ) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
