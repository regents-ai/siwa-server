defmodule SiwaServer.Siwa.CleanupWorker do
  @moduledoc """
  Removes expired nonce, replay and activity rows. Oban's cron queues it once a
  minute on the `cleanup` queue, which runs one at a time; a failed run is left
  to the next minute.
  """

  use Oban.Worker, queue: :cleanup, max_attempts: 1

  alias SiwaServer.Siwa.{ActivityStore, NonceStore, ReplayStore}

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    batch_size = Keyword.fetch!(SiwaServer.Config.siwa_cleanup(), :batch_size)

    with {:ok, _counts} <- cleanup_once(DateTime.utc_now(), batch_size), do: :ok
  end

  def cleanup_once(now, limit) do
    started_at = System.monotonic_time()

    result =
      with {:ok, nonce_count} <- NonceStore.cleanup_expired(now, limit),
           {:ok, replay_count} <- ReplayStore.cleanup_expired(now, limit),
           {:ok, activity_count} <- ActivityStore.cleanup_expired(now, limit) do
        {:ok,
         %{nonce_count: nonce_count, replay_count: replay_count, activity_count: activity_count}}
      end

    emit_cleanup_telemetry(result, started_at)
    result
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
