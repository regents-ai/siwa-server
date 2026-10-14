defmodule SiwaServer.ReadinessKeeper do
  @moduledoc """
  Keeps the last readiness answer for `SiwaServer.Config.readiness_keep_ms/0`.

  `/readyz` is public, so every request used to make three chain-id calls and a
  keystore write. Requests now share one check: a caller that finds the kept
  answer stale starts the check, and callers arriving meanwhile wait for that
  same answer instead of starting their own.

  The check runs in its own unlinked task, so a crash in it fails only the
  requests waiting for it, as it did before, and never this process.
  """

  use GenServer

  alias SiwaServer.Config
  alias SiwaServer.Readiness

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  # Every probe in the check carries its own timeout, so the wait is bounded
  # by them, as it was when each request ran the check itself.
  def answer do
    case GenServer.call(__MODULE__, :answer, :infinity) do
      {:ok, readiness} -> readiness
      {:exit, reason} -> exit(reason)
    end
  end

  @impl true
  def init(_opts), do: {:ok, nil}

  @impl true
  def handle_call(:answer, _from, kept) do
    now = System.monotonic_time(:millisecond)
    keep_ms = Config.readiness_keep_ms()

    case kept do
      {checked_at, readiness} when now - checked_at < keep_ms ->
        {:reply, {:ok, readiness}, kept}

      _stale ->
        SiwaServer.TaskSupervisor
        |> Task.Supervisor.async_nolink(Readiness, :check, [])
        |> Task.yield(:infinity)
        |> case do
          {:ok, readiness} ->
            {:reply, {:ok, readiness}, {System.monotonic_time(:millisecond), readiness}}

          {:exit, reason} ->
            {:reply, {:exit, reason}, kept}
        end
    end
  end
end
