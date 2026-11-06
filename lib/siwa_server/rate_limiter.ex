defmodule SiwaServer.RateLimiter do
  @moduledoc """
  Counts requests per limit and key in fixed windows, in the database, so every
  machine counts against the same allowance. `SiwaServer.Siwa.CleanupWorker`
  removes windows that have ended.
  """

  alias SiwaServer.Repo

  @default_cleanup_limit 1_000

  @spec check(atom(), String.t(), pos_integer(), pos_integer()) :: :ok | {:error, pos_integer()}
  def check(name, key, limit, window_ms)
      when is_atom(name) and is_binary(key) and is_integer(limit) and is_integer(window_ms) do
    now = System.os_time(:millisecond)
    bucket = div(now, window_ms)
    # Kept a window past its end, so a machine whose clock is a little behind still
    # finds the count it is adding to.
    expires_at = DateTime.from_unix!((bucket + 2) * window_ms, :millisecond)

    %{rows: [[count]]} =
      Repo.query!(
        """
        INSERT INTO siwa_rate_limits AS r (name, key, bucket, count, expires_at)
        VALUES ($1, $2, $3, 1, $4)
        ON CONFLICT (name, key, bucket) DO UPDATE SET count = r.count + 1
        RETURNING count
        """,
        [Atom.to_string(name), digest(key), bucket, DateTime.to_naive(expires_at)],
        log: false
      )

    if count <= limit, do: :ok, else: {:error, max((bucket + 1) * window_ms - now, 1)}
  end

  @doc "Removes up to `limit` ended windows."
  def cleanup_expired(limit \\ @default_cleanup_limit) do
    case Repo.query(
           """
           DELETE FROM siwa_rate_limits
           WHERE (name, key, bucket) IN (
             SELECT name, key, bucket
             FROM siwa_rate_limits
             WHERE expires_at <= (statement_timestamp() AT TIME ZONE 'UTC')
             ORDER BY expires_at
             LIMIT $1
           )
           """,
           [limit],
           log: false
         ) do
      {:ok, %{num_rows: count}} -> {:ok, count}
      {:error, reason} -> {:error, reason}
    end
  end

  # A key is built from what the caller sent, before anything is proven, so it
  # is stored at a fixed size however long the caller made it.
  defp digest(key), do: :crypto.hash(:sha256, key)
end
