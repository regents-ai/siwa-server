defmodule SiwaServer.Siwa.ActivityStore do
  @moduledoc """
  How much each wallet's agent was verified at each site on each day: one line
  per wallet, audience and UTC day, with the number of verified requests, how
  many of them began a lease (`SiwaServer.Siwa.HttpVerifier`), and when the
  first and the last of them was verified. Reads a site checks itself on a lease
  never reach this server, so they are not counted. Nothing else about a request
  is kept. Lines last 30 days.

  The lines say what arrived for a wallet at a site. Nothing grants, refuses or
  limits on them.
  """

  import Ecto.Query

  alias SiwaServer.Repo

  @kept_days 30
  @default_cleanup_limit 1_000

  # `synchronous_commit` is set for the transaction this statement runs in. Run on
  # its own, as its one caller does, that is this one statement and nothing else on
  # the connection. Never call `record/2` from inside a transaction that writes
  # anything else: the setting would last to that transaction's end and cover those
  # writes too.
  #
  # "off" answers before the database's disk has confirmed the count. A database
  # crash can then lose the counts written since the disk last confirmed (about
  # 600 ms normally, the whole pause while the disk is pausing). A lost count
  # changes no decision anywhere, so a verification never waits on the disk for it.
  @spec record(String.t(), String.t(), boolean()) :: :ok | {:error, term()}
  def record(wallet_address, audience, lease?) do
    case Repo.query(
           """
           WITH commit_mode AS (
             SELECT set_config('synchronous_commit', 'off', true)
           ), seen AS (
             SELECT clock_timestamp() AT TIME ZONE 'UTC' AS at FROM commit_mode
           )
           INSERT INTO siwa_agent_daily_activity
             (wallet_address, audience, day, accepted, leases, first_seen_at, last_seen_at)
           SELECT $1, $2, seen.at::date, 1, $3, seen.at, seen.at
           FROM seen
           ON CONFLICT (wallet_address, audience, day) DO UPDATE
           SET accepted = siwa_agent_daily_activity.accepted + 1,
               leases = siwa_agent_daily_activity.leases + EXCLUDED.leases,
               last_seen_at = GREATEST(siwa_agent_daily_activity.last_seen_at, EXCLUDED.last_seen_at)
           """,
           [String.downcase(wallet_address), audience, if(lease?, do: 1, else: 0)],
           log: false
         ) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  The wallet's lines whose last verified request was at or after `since`, newest
  day first. At most 30 days for each site, so they are read in one answer.
  """
  @spec days(String.t(), DateTime.t()) :: [map()]
  def days(wallet_address, since) do
    Repo.all(
      from(line in "siwa_agent_daily_activity",
        where:
          line.wallet_address == ^String.downcase(wallet_address) and
            line.last_seen_at >= ^since and
            line.day > ^kept_since(DateTime.utc_now()),
        order_by: [desc: line.day, asc: line.audience],
        select: %{
          audience: line.audience,
          day: line.day,
          accepted: line.accepted,
          leases: line.leases,
          first_seen_at: type(line.first_seen_at, :utc_datetime_usec),
          last_seen_at: type(line.last_seen_at, :utc_datetime_usec)
        }
      )
    )
  end

  def cleanup_expired(now \\ DateTime.utc_now(), limit \\ @default_cleanup_limit) do
    case Repo.query(
           """
           DELETE FROM siwa_agent_daily_activity
           WHERE (wallet_address, audience, day) IN (
             SELECT wallet_address, audience, day
             FROM siwa_agent_daily_activity
             WHERE day <= $1
             ORDER BY day
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

  # The one-line-per-request record this module kept before the daily lines.
  # Nothing writes or reads it any more; its rows still leave after 30 days,
  # until the table itself is dropped.
  def cleanup_expired_requests(now \\ DateTime.utc_now(), limit \\ @default_cleanup_limit) do
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
           [DateTime.add(now, -@kept_days, :day), limit],
           log: false
         ) do
      {:ok, %{num_rows: count}} -> {:ok, count}
      {:error, reason} -> {:error, reason}
    end
  end

  defp kept_since(now), do: now |> DateTime.add(-@kept_days, :day) |> DateTime.to_date()
end
