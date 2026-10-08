defmodule SiwaServer.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        SiwaServerWeb.Telemetry,
        SiwaServer.Repo,
        {Oban, Application.fetch_env!(:siwa_server, Oban)},
        SiwaServer.RateLimiter,
        {Finch, name: SiwaServer.Finch},
        {Task.Supervisor, name: SiwaServer.Siwa.CleanupTaskSupervisor},
        {SiwaServer.Siwa.CleanupWorker, [task_supervisor: SiwaServer.Siwa.CleanupTaskSupervisor]},
        {DNSCluster, query: SiwaServer.Config.dns_cluster_query() || :ignore},
        {Phoenix.PubSub, name: SiwaServer.PubSub},
        SiwaServerWeb.Endpoint,
        metrics_child()
      ]
      |> Enum.reject(&is_nil/1)

    opts = [strategy: :one_for_one, name: SiwaServer.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    SiwaServerWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  # Metrics are served beside the site, never by a release command or a task.
  defp metrics_child do
    if Phoenix.Endpoint.server?(:siwa_server, SiwaServerWeb.Endpoint),
      do: SiwaServerWeb.Metrics
  end
end
