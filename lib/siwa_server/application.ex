defmodule SiwaServer.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      SiwaServerWeb.Telemetry,
      SiwaServer.Repo,
      SiwaServer.RateLimiter,
      {Finch, name: SiwaServer.Finch},
      {SiwaServer.Siwa.CleanupWorker, []},
      {DNSCluster, query: Application.get_env(:siwa_server, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: SiwaServer.PubSub},
      SiwaServerWeb.Endpoint
    ]

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
end
