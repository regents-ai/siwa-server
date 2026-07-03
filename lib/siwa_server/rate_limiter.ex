defmodule SiwaServer.RateLimiter do
  @moduledoc false

  use GenServer

  require Logger

  @table __MODULE__
  @cleanup_interval_ms :timer.minutes(1)
  @fail_open_log_interval_ms :timer.seconds(60)
  @fail_open_last_logged_key {__MODULE__, :fail_open_last_logged_ms}

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  def check(name, key, limit, window_ms)
      when is_atom(name) and is_binary(key) and is_integer(limit) and is_integer(window_ms) do
    now = System.monotonic_time(:millisecond)
    bucket = floor_div(now, window_ms)
    expires_at = now + window_ms * 2

    case :ets.whereis(@table) do
      :undefined ->
        allow_during_missing_table(name, now)

      table ->
        check_table(table, name, key, bucket, expires_at, limit, window_ms, now)
    end
  end

  def reset do
    if table_exists?(), do: :ets.delete_all_objects(@table)
    :persistent_term.erase(@fail_open_last_logged_key)
    :ok
  end

  @impl true
  def init(_opts) do
    create_table()
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

  defp create_table do
    if table_exists?() do
      @table
    else
      :ets.new(@table, [:named_table, :public, read_concurrency: true, write_concurrency: true])
    end
  end

  defp check_table(table, name, key, bucket, expires_at, limit, window_ms, now) do
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
  rescue
    error in ArgumentError ->
      if table_exists?() do
        reraise error, __STACKTRACE__
      else
        allow_during_missing_table(name, now)
      end
  end

  defp allow_during_missing_table(name, now) do
    metadata = %{key_class: limiter_key_class(name)}

    :telemetry.execute([:siwa_server, :rate_limiter, :fail_open], %{count: 1}, metadata)
    maybe_log_fail_open(metadata, now)

    :ok
  end

  defp maybe_log_fail_open(metadata, now) do
    last_logged_at = :persistent_term.get(@fail_open_last_logged_key, nil)

    if is_nil(last_logged_at) or now - last_logged_at >= @fail_open_log_interval_ms do
      :persistent_term.put(@fail_open_last_logged_key, now)

      Logger.warning(
        "SIWA rate limiter table is unavailable; allowing requests",
        Map.to_list(metadata)
      )
    end
  end

  defp limiter_key_class(name), do: name

  defp table_exists?, do: :ets.whereis(@table) != :undefined
  defp schedule_cleanup, do: Process.send_after(self(), :cleanup, @cleanup_interval_ms)

  defp floor_div(left, right) when left >= 0, do: div(left, right)
  defp floor_div(left, right), do: -div(-left + right - 1, right)
end
