defmodule SiwaServer.RateLimiter do
  @moduledoc """
  Counts requests per limit and key in fixed windows, in the database, so every
  machine counts against the same allowance. Each limit has a default here that
  the `:rate_limits` setting can replace. `SiwaServer.Siwa.CleanupWorker`
  removes windows that have ended.
  """

  alias SiwaServer.Repo

  @limits %{
    siwa_nonce: [limit: 60, window_ms: 60_000],
    siwa_verify: [limit: 60, window_ms: 60_000],
    siwa_http_verify: [limit: 600, window_ms: 60_000],
    siwa_activity: [limit: 600, window_ms: 60_000],
    # Each hosted signing unlocks the encrypted key store three times, about
    # 140 ms of one CPU on the live machine, so 300 a minute stays inside one CPU.
    siwa_hosted: [limit: 300, window_ms: 60_000],
    siwa_register: [limit: 60, window_ms: 60_000],
    agent_book: [limit: 60, window_ms: 60_000],
    agent_profile: [limit: 600, window_ms: 60_000],
    siwa_computer: [limit: 300, window_ms: 60_000],
    # One site's server checks every signed request its agents send. The whole
    # service has peaked at 30 checks a minute, so this leaves a site room to grow
    # a hundredfold and still bounds a caller that names a new wallet each time.
    siwa_site: [limit: 3_000, window_ms: 60_000],
    # Counted per calling address, which is a Regent site's server for all of its
    # people. Each needs a new control token every 15 minutes, so 30 a minute
    # serves about 450 people signed in to one site at once.
    siwa_control_session: [limit: 600, window_ms: 60_000]
  }

  @doc "Counts one request under `name` and `key`; the wait in ms once the window is full."
  @spec check(atom(), String.t()) :: :ok | {:error, pos_integer()}
  def check(name, key) do
    configured = :siwa_server |> Application.get_env(:rate_limits, []) |> Keyword.get(name, [])
    limits = Keyword.merge(Map.fetch!(@limits, name), configured)
    window_ms = Keyword.fetch!(limits, :window_ms)

    now = System.os_time(:millisecond)
    bucket = div(now, window_ms)
    # Kept a window past its end, so a machine whose clock is a little behind still
    # finds the count it is adding to.
    expires_at = DateTime.from_unix!((bucket + 2) * window_ms, :millisecond)

    # A key is built from what the caller sent, before anything is proven, so it
    # is stored at a fixed size however long the caller made it.
    %{rows: [[count]]} =
      Repo.query!(
        """
        INSERT INTO siwa_rate_limits AS r (name, key, bucket, count, expires_at)
        VALUES ($1, $2, $3, 1, $4)
        ON CONFLICT (name, key, bucket) DO UPDATE SET count = r.count + 1
        RETURNING count
        """,
        [Atom.to_string(name), :crypto.hash(:sha256, key), bucket, DateTime.to_naive(expires_at)],
        log: false
      )

    if count <= Keyword.fetch!(limits, :limit),
      do: :ok,
      else: {:error, max((bucket + 1) * window_ms - now, 1)}
  end

  @doc "Removes up to `limit` ended windows."
  def cleanup_expired(limit) do
    with {:ok, %{num_rows: count}} <-
           Repo.query(
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
           ),
         do: {:ok, count}
  end
end
