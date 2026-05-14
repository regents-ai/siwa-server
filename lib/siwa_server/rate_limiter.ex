defmodule SiwaServer.RateLimiter do
  @moduledoc false

  use GenServer

  @table __MODULE__
  @cleanup_interval_ms :timer.minutes(1)

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  def check(name, key, limit, window_ms)
      when is_atom(name) and is_binary(key) and is_integer(limit) and is_integer(window_ms) do
    now = System.monotonic_time(:millisecond)
    bucket = floor_div(now, window_ms)
    expires_at = now + window_ms * 2
    table = ensure_table()

    count =
      :ets.update_counter(
        table,
        {name, key, bucket},
        {2, 1},
        {{name, key, bucket}, 0, expires_at}
      )

    if count <= limit do
      :ok
    else
      {:error, max((bucket + 1) * window_ms - now, 1)}
    end
  end

  def reset do
    if table_exists?(), do: :ets.delete_all_objects(@table)
    :ok
  end

  @impl true
  def init(_opts) do
    ensure_table()
    schedule_cleanup()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cleanup_expired()
    schedule_cleanup()
    {:noreply, state}
  end

  defp cleanup_expired do
    if table_exists?() do
      now = System.monotonic_time(:millisecond)
      :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:"=<", :"$1", now}], [true]}])
    end

    :ok
  end

  defp ensure_table do
    if table_exists?() do
      @table
    else
      :ets.new(@table, [:named_table, :public, read_concurrency: true, write_concurrency: true])
    end
  end

  defp table_exists?, do: :ets.whereis(@table) != :undefined
  defp schedule_cleanup, do: Process.send_after(self(), :cleanup, @cleanup_interval_ms)

  defp floor_div(left, right) when left >= 0, do: div(left, right)
  defp floor_div(left, right), do: -div(-left + right - 1, right)
end
