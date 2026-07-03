defmodule SiwaServer.Siwa.CleanupWorker do
  @moduledoc false

  use GenServer

  require Logger

  alias SiwaServer.SharedIdentity
  alias SiwaServer.Siwa.{NonceStore, ReplayStore}

  @default_interval_ms 60_000
  @default_batch_size 1_000
  @default_task_supervisor SiwaServer.Siwa.CleanupTaskSupervisor

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
           {:ok, replay_count} <- ReplayStore.cleanup_expired(now, limit),
           {:ok, identity_counts} <- SharedIdentity.cleanup_expired(now, limit) do
        {:ok, Map.merge(%{nonce_count: nonce_count, replay_count: replay_count}, identity_counts)}
      end

    emit_cleanup_telemetry(result, started_at)
    result
  end

  @impl true
  def init(opts) do
    state = %{
      interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms),
      batch_size: Keyword.get(opts, :batch_size, @default_batch_size),
      cleanup_fun: Keyword.get(opts, :cleanup_fun, &cleanup_once/2),
      task_ref: nil,
      task_supervisor: Keyword.get(opts, :task_supervisor, @default_task_supervisor),
      timer_ref: nil
    }

    {:ok, schedule_cleanup(state, 0)}
  end

  @impl true
  def handle_info(:cleanup, state) do
    state =
      state
      |> Map.put(:timer_ref, nil)
      |> schedule_cleanup(state.interval_ms)

    {:noreply, maybe_start_cleanup(state)}
  end

  def handle_info({ref, result}, %{task_ref: ref} = state) do
    Process.demonitor(ref, [:flush])
    log_cleanup_result(result)

    {:noreply, %{state | task_ref: nil}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task_ref: ref} = state) do
    Logger.warning("SIWA cleanup task failed: #{inspect(reason)}")

    {:noreply, %{state | task_ref: nil}}
  end

  def handle_info({_ref, _result}, state), do: {:noreply, state}
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}

  defp maybe_start_cleanup(%{task_ref: nil} = state) do
    task =
      Task.Supervisor.async_nolink(state.task_supervisor, fn ->
        state.cleanup_fun.(DateTime.utc_now(), state.batch_size)
      end)

    %{state | task_ref: task.ref}
  end

  defp maybe_start_cleanup(state), do: state

  defp schedule_cleanup(state, delay_ms) do
    %{state | timer_ref: Process.send_after(self(), :cleanup, delay_ms)}
  end

  defp log_cleanup_result({:ok, _counts}), do: :ok

  defp log_cleanup_result({:error, reason}),
    do: Logger.warning("SIWA cleanup failed: #{inspect(reason)}")

  defp log_cleanup_result(_result), do: :ok

  defp config do
    SiwaServer.Config.siwa_cleanup()
  end

  defp default_batch_size do
    config()
    |> Keyword.get(:batch_size, @default_batch_size)
  end

  defp emit_cleanup_telemetry(result, started_at) do
    duration = System.monotonic_time() - started_at

    measurements =
      case result do
        {:ok, counts} ->
          Map.merge(%{duration: duration}, counts)

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
