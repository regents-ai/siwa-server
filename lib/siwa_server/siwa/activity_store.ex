defmodule SiwaServer.Siwa.ActivityStore do
  @moduledoc """
  What each wallet's verified requests were: the audience, method, path
  without its query, and when the request was verified. Nothing else about a
  request is kept. Entries last 30 days.
  """

  import Ecto.Query

  alias SiwaServer.Repo

  @kept_days 30
  @recent 50
  @default_cleanup_limit 1_000

  @spec record(String.t(), String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def record(wallet_address, audience, method, path) do
    case Repo.query(
           """
           INSERT INTO siwa_request_activity (id, wallet_address, audience, method, path, occurred_at)
           VALUES ($1, $2, $3, $4, $5, $6)
           """,
           [
             Ecto.UUID.generate() |> Ecto.UUID.dump!(),
             String.downcase(wallet_address),
             audience,
             String.upcase(method),
             path |> String.split("?", parts: 2) |> hd(),
             DateTime.utc_now()
           ],
           log: false
         ) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec recent(String.t(), DateTime.t()) :: [map()]
  def recent(wallet_address, since) do
    from(entry in "siwa_request_activity",
      where:
        entry.wallet_address == ^String.downcase(wallet_address) and
          entry.occurred_at >= ^since and
          entry.occurred_at > ^kept_since(DateTime.utc_now()),
      order_by: [desc: entry.occurred_at],
      limit: @recent,
      select: %{
        audience: entry.audience,
        method: entry.method,
        path: entry.path,
        occurred_at: type(entry.occurred_at, :utc_datetime_usec)
      }
    )
    |> Repo.all()
  end

  def cleanup_expired(now \\ DateTime.utc_now(), limit \\ @default_cleanup_limit) do
    case Repo.query(
           """
           DELETE FROM siwa_request_activity
           WHERE id IN (
             SELECT id
             FROM siwa_request_activity
             WHERE occurred_at <= $1
             ORDER BY occurred_at
             LIMIT $2
           )
           """,
           [kept_since(now), limit],
           log: false
         ) do
      {:ok, %{num_rows: count}} -> {:ok, count}
      {:error, reason} -> {:error, reason}
    end
  end

  defp kept_since(now), do: DateTime.add(now, -@kept_days, :day)
end
