defmodule SiwaServer.Siwa.NonceStore do
  @moduledoc false
  @behaviour Siwa.NonceStore

  import Ecto.Query

  alias SiwaServer.Repo
  alias SiwaServer.Siwa.NonceRecord
  @default_cleanup_limit 1_000

  @impl Siwa.NonceStore
  def put(key, nonce, metadata) do
    attrs = %{
      nonce_key: key,
      nonce: nonce,
      address: metadata.address,
      agent_id: metadata.agent_id,
      agent_registry: metadata.agent_registry,
      audience: metadata.audience,
      issued_at: metadata.issued_at,
      expiration_time: metadata.expiration_time
    }

    %NonceRecord{}
    |> NonceRecord.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, _record} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def put_wallet(attrs) do
    %NonceRecord{}
    |> NonceRecord.changeset(Map.put(attrs, :principal_kind, "wallet"))
    |> Repo.insert(log: false)
  end

  def get_wallet(key, nonce) do
    query =
      from n in NonceRecord,
        where: n.principal_kind == "wallet" and n.nonce_key == ^key and n.nonce == ^nonce

    case Repo.one(query, log: false) do
      nil -> {:error, :unknown_nonce}
      record -> {:ok, record}
    end
  end

  # Fixed SQL text; every value, including both expiry checks around the row-lock
  # wait, is a bound parameter.
  # sobelow_skip ["SQL.Query"]
  def consume_wallet(record) do
    query = """
    WITH consumed AS (
      DELETE FROM siwa_nonces
      WHERE principal_kind = 'wallet' AND nonce_key = $1 AND nonce = $2
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

  @impl Siwa.NonceStore
  # Fixed SQL text; the key and nonce are bound parameters.
  # sobelow_skip ["SQL.Query"]
  def consume(key, nonce) do
    query = """
    DELETE FROM siwa_nonces
    WHERE principal_kind = 'agent' AND nonce_key = $1 AND nonce = $2
    RETURNING address, agent_id, agent_registry, audience, issued_at, expiration_time
    """

    case Repo.query(query, [key, nonce]) do
      {:ok, %{rows: [[address, agent_id, agent_registry, audience, issued_at, expiration_time]]}} ->
        {:ok,
         %{
           address: address,
           agent_id: agent_id,
           agent_registry: agent_registry,
           audience: audience,
           issued_at: utc_datetime!(issued_at),
           expiration_time: utc_datetime!(expiration_time)
         }}

      {:ok, %{rows: []}} ->
        {:error, :unknown_nonce}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp utc_datetime!(%DateTime{} = value), do: DateTime.truncate(value, :second)
  defp utc_datetime!(%NaiveDateTime{} = value), do: DateTime.from_naive!(value, "Etc/UTC")
end
