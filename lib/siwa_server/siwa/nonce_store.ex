defmodule SiwaServer.Siwa.NonceStore do
  @moduledoc false

  import Ecto.Query

  alias SiwaServer.Repo
  alias SiwaServer.Siwa.NonceRecord
  @default_cleanup_limit 1_000

  def put(attrs) do
    %NonceRecord{}
    |> NonceRecord.changeset(attrs)
    |> Repo.insert(log: false)
  end

  def get(key, nonce) do
    query = from n in NonceRecord, where: n.nonce_key == ^key and n.nonce == ^nonce

    case Repo.one(query, log: false) do
      nil -> {:error, :unknown_nonce}
      record -> {:ok, record}
    end
  end

  # Fixed SQL text; every value, including both expiry checks around the row-lock
  # wait, is a bound parameter.
  # sobelow_skip ["SQL.Query"]
  def consume(record) do
    # The outer SELECT re-checks `expiration_time` after the DELETE has waited
    # on any row lock: a nonce that expires while a contender is blocked on the
    # lock is never consumed successfully. The DELETE's own WHERE alone is not
    # re-evaluated after the wait when the row was locked but not modified.
    query = """
    WITH consumed AS (
      DELETE FROM siwa_nonces
      WHERE nonce_key = $1 AND nonce = $2
        AND address = $3 AND chain_id = $4 AND audience = $5 AND canonical_message = $6
        AND issued_at = $7 AND expiration_time = $8
        AND expiration_time > (clock_timestamp() AT TIME ZONE 'UTC')
      RETURNING id, expiration_time
    )
    SELECT id FROM consumed
    WHERE expiration_time > (clock_timestamp() AT TIME ZONE 'UTC')
    """

    case Repo.query(
           query,
           [
             record.nonce_key,
             record.nonce,
             record.address,
             record.chain_id,
             record.audience,
             record.canonical_message,
             record.issued_at,
             record.expiration_time
           ],
           log: false
         ) do
      {:ok, %{rows: [[_id]]}} -> :ok
      {:ok, %{rows: []}} -> {:error, :unknown_nonce}
      {:error, reason} -> {:error, reason}
    end
  end

  def cleanup_expired(now \\ DateTime.utc_now(), limit \\ @default_cleanup_limit) do
    case Repo.query(
           """
           DELETE FROM siwa_nonces
           WHERE id IN (
             SELECT id
             FROM siwa_nonces
             WHERE expiration_time <= $1
             ORDER BY expiration_time
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
