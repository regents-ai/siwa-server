defmodule SiwaServer.Siwa.CleanupWorker do
  @moduledoc false

  use GenServer

  require Logger

  alias SiwaServer.Siwa.{NonceStore, ReplayStore}

  @default_interval_ms 60_000
  @default_batch_size 1_000

  def start_link(opts) do
    opts = Keyword.merge(config(), opts)

    if Keyword.get(opts, :enabled, true) do
      case Keyword.get(opts, :name, __MODULE__) do
        nil -> GenServer.start_link(__MODULE__, opts)
        name -> GenServer.start_link(__MODULE__, opts, name: name)
      end
    else
      :ignore
    end
  end

  def cleanup_once(now \\ DateTime.utc_now(), limit \\ default_batch_size()) do
    started_at = System.monotonic_time()

    result =
      with {:ok, nonce_count} <- NonceStore.cleanup_expired(now, limit),
           {:ok, replay_count} <- ReplayStore.cleanup_expired(now, limit) do
        {:ok, %{nonce_count: nonce_count, replay_count: replay_count}}
      end

    emit_cleanup_telemetry(result, started_at)
    result
  end

  @impl true
  def init(opts) do
    state = %{
      interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms),
      batch_size: Keyword.get(opts, :batch_size, @default_batch_size)
    }

    send(self(), :cleanup)

    {:ok, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    case cleanup_once(DateTime.utc_now(), state.batch_size) do
      {:ok, _counts} -> :ok
      {:error, reason} -> Logger.warning("SIWA cleanup failed: #{inspect(reason)}")
    end

    Process.send_after(self(), :cleanup, state.interval_ms)

    {:noreply, state}
  end

  defp config do
    Application.get_env(:siwa_server, :siwa_cleanup, [])
  end

  defp default_batch_size do
    config()
    |> Keyword.get(:batch_size, @default_batch_size)
  end

  defp emit_cleanup_telemetry(result, started_at) do
    duration = System.monotonic_time() - started_at

    measurements =
      case result do
        {:ok, %{nonce_count: nonce_count, replay_count: replay_count}} ->
          %{duration: duration, nonce_count: nonce_count, replay_count: replay_count}

        {:error, _reason} ->
          %{duration: duration, nonce_count: 0, replay_count: 0}
      end

    metadata =
      case result do
        {:ok, _counts} -> %{result: :ok}
        {:error, reason} -> %{result: :error, reason: reason}
      end

    :telemetry.execute([:siwa_server, :siwa, :cleanup], measurements, metadata)
  end
end
