defmodule SiwaServer.Siwa.CleanupWorkerTimerTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias SiwaServer.Siwa.CleanupWorker

  test "skips timer ticks while a cleanup run is still active" do
    test_pid = self()
    task_supervisor = start_task_supervisor!()

    cleanup_fun = fn _now, _limit ->
      send(test_pid, {:cleanup_started, self()})

      receive do
        :finish_cleanup -> {:ok, %{nonce_count: 0, replay_count: 0}}
      end
    end

    start_supervised!(
      {CleanupWorker,
       enabled: true,
       interval_ms: 10,
       batch_size: 10,
       name: nil,
       cleanup_fun: cleanup_fun,
       task_supervisor: task_supervisor}
    )

    assert_receive {:cleanup_started, first_task}, 1_000
    Process.sleep(50)
    refute_received {:cleanup_started, _}

    send(first_task, :finish_cleanup)

    assert_receive {:cleanup_started, second_task}, 1_000
    refute second_task == first_task

    send(second_task, :finish_cleanup)
  end

  test "logs a failed cleanup task without killing the worker" do
    test_pid = self()
    task_supervisor = start_task_supervisor!()

    cleanup_fun = fn _now, _limit ->
      send(test_pid, :cleanup_started)
      raise "cleanup failed"
    end

    log =
      capture_log(fn ->
        pid =
          start_supervised!(
            {CleanupWorker,
             enabled: true,
             interval_ms: 60_000,
             batch_size: 10,
             name: nil,
             cleanup_fun: cleanup_fun,
             task_supervisor: task_supervisor}
          )

        assert_receive :cleanup_started, 1_000
        assert_worker_idle(pid)
        assert Process.alive?(pid)
      end)

    assert log =~ "SIWA cleanup task failed"
    assert log =~ "cleanup failed"
  end

  defp start_task_supervisor! do
    name = :"#{__MODULE__}.TaskSupervisor.#{System.unique_integer([:positive])}"
    start_supervised!({Task.Supervisor, name: name})
    name
  end

  defp assert_worker_idle(pid, attempts \\ 20)

  defp assert_worker_idle(pid, attempts) when attempts > 0 do
    case :sys.get_state(pid) do
      %{task_ref: nil} ->
        :ok

      _state ->
        receive do
        after
          10 -> assert_worker_idle(pid, attempts - 1)
        end
    end
  end

  defp assert_worker_idle(pid, 0) do
    assert %{task_ref: nil} = :sys.get_state(pid)
  end
end
