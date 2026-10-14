defmodule SiwaServer.ReadinessKeeper do
  @moduledoc """
  Keeps the last readiness answer for `SiwaServer.Config.readiness_keep_ms/0`.

  `/readyz` is public, so every request used to make three chain-id calls and a
  keystore write. Requests now share one check: a caller that finds the kept
  answer stale runs the check inside this process, and callers arriving
  meanwhile wait for that same answer instead of starting their own.
  """

  use GenServer

  alias SiwaServer.Config
  alias SiwaServer.Readiness

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  # The check runs the database probe (1 s timeout) and three chain-id probes in
  # turn, so a caller may wait for all four plus a margin.
  def answer do
    GenServer.call(__MODULE__, :answer, 3 * Config.readiness_rpc_timeout_ms() + 2_000)
  end

  @impl true
  def init(_opts), do: {:ok, nil}

  @impl true
  def handle_call(:answer, _from, kept) do
    now = System.monotonic_time(:millisecond)
    keep_ms = Config.readiness_keep_ms()

    case kept do
      {checked_at, readiness} when now - checked_at < keep_ms ->
        {:reply, readiness, kept}

      _stale ->
        readiness = Readiness.check()
        {:reply, readiness, {System.monotonic_time(:millisecond), readiness}}
    end
  end
end
