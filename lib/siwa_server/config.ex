defmodule SiwaServer.Config do
  @moduledoc """
  Central access point for `:siwa_server` application configuration.

  All `Application` environment reads for the `:siwa_server` app in `lib/`
  go through this module so every configuration key is discoverable in one
  place. Plain functions only — values are read from the application
  environment on every call.
  """

  @app :siwa_server

  @default_ethereum_rpc_timeout_ms 5_000
  @default_readiness_rpc_timeout_ms 1_000

  @doc "SIWA settings (`:nonce_ttl_seconds`, `:receipt_ttl_seconds`, `:receipt_secret`)."
  def siwa, do: Application.get_env(@app, :siwa, [])

  @doc "Nonce/replay cleanup worker settings (`:enabled`, `:interval_ms`, `:batch_size`)."
  def siwa_cleanup, do: Application.get_env(@app, :siwa_cleanup, [])

  @doc "Per-pipeline rate limit overrides (`:limit`, `:window_ms`)."
  def rate_limits, do: Application.get_env(@app, :rate_limits, [])

  @doc "DNS cluster query used for node discovery, or `nil` when clustering is disabled."
  def dns_cluster_query, do: Application.get_env(@app, :dns_cluster_query)

  @doc "Timeout for Ethereum JSON-RPC calls made during SIWA verification."
  def ethereum_rpc_timeout_ms,
    do: Application.get_env(@app, :ethereum_rpc_timeout_ms, @default_ethereum_rpc_timeout_ms)

  @doc "Timeout for the Base RPC chain-id probe in the readiness check."
  def readiness_rpc_timeout_ms,
    do: Application.get_env(@app, :readiness_rpc_timeout_ms, @default_readiness_rpc_timeout_ms)

  @doc "Phoenix endpoint configuration keyword list."
  def endpoint, do: Application.get_env(@app, SiwaServerWeb.Endpoint, [])

  @doc "Ecto repos started by this application."
  def ecto_repos, do: Application.fetch_env!(@app, :ecto_repos)

  @doc "Name of the Prometheus reporter started by the telemetry supervisor."
  def prometheus_reporter,
    do: Application.fetch_env!(@app, SiwaServerWeb.Telemetry)[:prometheus_reporter]
end
