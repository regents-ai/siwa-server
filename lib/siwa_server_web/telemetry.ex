defmodule SiwaServerWeb.Telemetry do
  use Supervisor
  import Telemetry.Metrics

  @request_duration_buckets [0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0]
  @query_duration_buckets [0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0]

  def prometheus_reporter do
    Application.fetch_env!(:siwa_server, __MODULE__)[:prometheus_reporter]
  end

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    _previous = :erlang.system_flag(:scheduler_wall_time, true)

    children = [
      {TelemetryMetricsPrometheus.Core,
       metrics: prometheus_metrics(), name: prometheus_reporter(), start_async: false},
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def prometheus_metrics do
    [
      counter("siwa_server.phoenix.requests.total",
        event_name: [:phoenix, :router_dispatch, :stop],
        measurement: fn _measurements, _metadata -> 1 end,
        tags: [:route],
        tag_values: &route_tag_values/1,
        description: "The total number of completed HTTP requests"
      ),
      counter("siwa_server.phoenix.request_exceptions.total",
        event_name: [:phoenix, :router_dispatch, :exception],
        measurement: fn _measurements, _metadata -> 1 end,
        tags: [:route],
        tag_values: &route_tag_values/1,
        description: "The total number of HTTP requests that raised an exception"
      ),
      distribution("siwa_server.phoenix.request.duration.seconds",
        event_name: [:phoenix, :router_dispatch, :stop],
        measurement: :duration,
        tags: [:route],
        tag_values: &route_tag_values/1,
        unit: {:native, :second},
        reporter_options: [buckets: @request_duration_buckets],
        description: "The HTTP request duration in seconds"
      ),
      counter("siwa_server.repo.queries.total",
        event_name: [:siwa_server, :repo, :query],
        measurement: fn _measurements, _metadata -> 1 end,
        description: "The total number of database queries"
      ),
      distribution("siwa_server.repo.query.duration.seconds",
        event_name: [:siwa_server, :repo, :query],
        measurement: :total_time,
        unit: {:native, :second},
        reporter_options: [buckets: @query_duration_buckets],
        description: "The total database query duration in seconds"
      ),
      counter("siwa_server.ethereum.rpc.calls.total",
        event_name: [:siwa_server, :ethereum, :rpc, :stop],
        measurement: fn _measurements, _metadata -> 1 end,
        tags: [:operation, :result],
        description: "The total number of Ethereum RPC operations"
      ),
      distribution("siwa_server.ethereum.rpc.duration.seconds",
        event_name: [:siwa_server, :ethereum, :rpc, :stop],
        measurement: :duration,
        tags: [:operation, :result],
        unit: {:native, :second},
        reporter_options: [buckets: @request_duration_buckets],
        description: "Ethereum RPC operation duration in seconds"
      ),
      counter("siwa_server.siwa.cleanup.runs.total",
        event_name: [:siwa_server, :siwa, :cleanup],
        measurement: fn _measurements, _metadata -> 1 end,
        tags: [:result],
        description: "The total number of SIWA cleanup runs"
      ),
      counter("siwa_server.siwa.cleanup.nonces.deleted.total",
        event_name: [:siwa_server, :siwa, :cleanup],
        measurement: :nonce_count,
        description: "The total number of expired SIWA nonces removed"
      ),
      counter("siwa_server.siwa.cleanup.replays.deleted.total",
        event_name: [:siwa_server, :siwa, :cleanup],
        measurement: :replay_count,
        description: "The total number of expired SIWA replay records removed"
      ),
      distribution("siwa_server.siwa.cleanup.duration.seconds",
        event_name: [:siwa_server, :siwa, :cleanup],
        measurement: :duration,
        tags: [:result],
        unit: {:native, :second},
        reporter_options: [buckets: @query_duration_buckets],
        description: "SIWA cleanup duration in seconds"
      ),
      last_value("siwa_server.vm.memory.total.bytes",
        event_name: [:vm, :memory],
        measurement: :total,
        unit: :byte,
        description: "The total BEAM memory footprint in bytes"
      ),
      last_value("siwa_server.vm.system.atom_count",
        event_name: [:siwa_server, :vm, :system_counts],
        measurement: :atom_count,
        description: "The current number of loaded atoms"
      ),
      last_value("siwa_server.vm.system.ets_count",
        event_name: [:siwa_server, :vm, :system_counts],
        measurement: :ets_count,
        description: "The current number of ETS tables"
      ),
      last_value("siwa_server.vm.system.port_count",
        event_name: [:siwa_server, :vm, :system_counts],
        measurement: :port_count,
        description: "The current number of open ports"
      ),
      last_value("siwa_server.vm.system.process_count",
        event_name: [:siwa_server, :vm, :system_counts],
        measurement: :process_count,
        description: "The current number of running processes"
      )
    ]
  end

  def observe_runtime_stats do
    :telemetry.execute(
      [:siwa_server, :vm, :system_counts],
      %{
        atom_count: :erlang.system_info(:atom_count),
        ets_count: :erlang.system_info(:ets_count),
        port_count: :erlang.system_info(:port_count),
        process_count: :erlang.system_info(:process_count)
      },
      %{}
    )
  end

  defp periodic_measurements do
    [{__MODULE__, :observe_runtime_stats, []}]
  end

  defp route_tag_values(metadata) do
    %{route: metadata[:route] || "unmatched"}
  end
end
