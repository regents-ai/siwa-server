defmodule SiwaServer.Siwa.ActivityStore do
  @moduledoc """
  What each wallet's verified requests were: the audience, method, path
  without its query, and when the request was verified. Nothing else about a
  request is kept. Entries last 30 days.
  """

  import Ecto.Query

  alias SiwaServer.Repo

  @kept_days 30
  @page_size 20
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

  @doc """
  One page of the wallet's entries at or after `since`, newest first, and the
  cursor for the next page, or nil when this page is the last. `start` is the
  cursor a previous page returned, or nil for the first page.
  """
  @spec page(String.t(), DateTime.t(), String.t() | nil) ::
          {:ok, [map()], String.t() | nil} | :error
  def page(wallet_address, since, start) do
    with {:ok, query} <- after_cursor(entries(wallet_address, since), start) do
      rows = Repo.all(from(entry in query, limit: @page_size + 1))
      {page, rest} = Enum.split(rows, @page_size)
      next = if rest == [], do: nil, else: page |> List.last() |> cursor()
      {:ok, Enum.map(page, &Map.delete(&1, :id)), next}
    end
  end

  defp entries(wallet_address, since) do
    from(entry in "siwa_request_activity",
      where:
        entry.wallet_address == ^String.downcase(wallet_address) and
          entry.occurred_at >= ^since and
          entry.occurred_at > ^kept_since(DateTime.utc_now()),
      order_by: [desc: entry.occurred_at, desc: entry.id],
      select: %{
        id: type(entry.id, :binary_id),
        audience: entry.audience,
        method: entry.method,
        path: entry.path,
        occurred_at: type(entry.occurred_at, :utc_datetime_usec)
      }
    )
  end

  defp after_cursor(query, nil), do: {:ok, query}

  defp after_cursor(query, cursor) do
    with {:ok, text} <- Base.url_decode64(cursor, padding: false),
         [at, id] <- String.split(text, "~"),
         {:ok, at, 0} <- DateTime.from_iso8601(at),
         {:ok, id} <- Ecto.UUID.dump(id) do
      {:ok,
       from(entry in query,
         where:
           fragment(
             "(?, ?) < (?, ?)",
             entry.occurred_at,
             entry.id,
             type(^at, :utc_datetime_usec),
             ^id
           )
       )}
    else
      _invalid -> :error
    end
  end

  defp cursor(%{occurred_at: at, id: id}),
    do: Base.url_encode64(DateTime.to_iso8601(at) <> "~" <> id, padding: false)

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
