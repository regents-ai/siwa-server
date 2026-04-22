defmodule SiwaServer.Siwa.NonceStore do
  @moduledoc false

  alias SiwaServer.Repo
  alias SiwaServer.Siwa.NonceRecord

  def put(key, nonce, metadata, params) do
    attrs = %{
      nonce_key: key,
      nonce: nonce,
      address: metadata.address,
      agent_id: metadata.agent_id,
      agent_registry: metadata.agent_registry,
      audience: params.audience,
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

  def cleanup_expired(now \\ DateTime.utc_now()) do
    case Repo.query(
           "DELETE FROM siwa_nonces WHERE expiration_time <= $1",
           [DateTime.truncate(now, :second)]
         ) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def consume(key, nonce) do
    query = """
    DELETE FROM siwa_nonces
    WHERE nonce_key = $1 AND nonce = $2
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
