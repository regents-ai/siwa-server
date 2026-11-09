defmodule SiwaServer.AgentRegistration.OwnerCheckWorker do
  @moduledoc """
  Runs `SiwaServer.AgentRegistration.check_owners/0`. Oban's cron queues it
  every five minutes on the `chain` queue, and only one job exists at a time.
  """

  use Oban.Worker,
    queue: :chain,
    max_attempts: 1,
    unique: [period: :infinity, states: :incomplete]

  @impl Oban.Worker
  def perform(%Oban.Job{}), do: SiwaServer.AgentRegistration.check_owners()
end
