defmodule SiwaServer.Siwa.CleanupWorker do
  @moduledoc """
  Removes expired nonce, replay and activity rows. Oban's cron queues it once a
  minute on the `cleanup` queue. Each kind is removed a batch at a time until a
  batch comes back short, at most 20 batches a run; what is left waits for
  the next minute. A failed run is left to the next minute too. Only one job
  exists at a time: a minute's job is dropped while an earlier one is still
  waiting or running.
  """

  use Oban.Worker,
    queue: :cleanup,
    max_attempts: 1,
    unique: [period: :infinity, states: :incomplete]

  alias SiwaServer.Siwa.{ActivityStore, NonceStore, ReplayStore}

  @max_batches 20

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    batch_size = Keyword.fetch!(SiwaServer.Config.siwa_cleanup(), :batch_size)

    with {:ok, _counts} <- cleanup_once(DateTime.utc_now(), batch_size), do: :ok
  end

  def cleanup_once(now, limit) do
    started_at = System.monotonic_time()

    result =
      with {:ok, nonce_count} <- drain(&NonceStore.cleanup_expired(now, &1), limit),
           {:ok, replay_count} <- drain(&ReplayStore.cleanup_expired/1, limit),
           {:ok, activity_count} <- drain(&ActivityStore.cleanup_expired(now, &1), limit),
           {:ok, request_count} <-
             drain(&ActivityStore.cleanup_expired_requests(now, &1), limit) do
        {:ok,
         %{
           nonce_count: nonce_count,
           replay_count: replay_count,
           activity_count: activity_count,
           request_count: request_count
         }}
      end

    emit_cleanup_telemetry(result, started_at)
    result
  end

  defp drain(cleanup, limit, batches \\ @max_batches, removed \\ 0)
  defp drain(_cleanup, _limit, 0, removed), do: {:ok, removed}

  defp drain(cleanup, limit, batches, removed) do
    case cleanup.(limit) do
      {:ok, count} when count < limit -> {:ok, removed + count}
      {:ok, count} -> drain(cleanup, limit, batches - 1, removed + count)
      {:error, reason} -> {:error, reason}
    end
  end

  defp emit_cleanup_telemetry(result, started_at) do
    duration = System.monotonic_time() - started_at

    measurements =
      case result do
        {:ok, counts} ->
          Map.merge(%{duration: duration}, counts)

        {:error, _reason} ->
          %{
            duration: duration,
            nonce_count: 0,
            replay_count: 0,
            activity_count: 0,
            request_count: 0
          }
      end

    metadata =
      case result do
        {:ok, _counts} -> %{result: :ok}
        {:error, reason} -> %{result: :error, reason: reason}
      end

    :telemetry.execute([:siwa_server, :siwa, :cleanup], measurements, metadata)
  end
end
