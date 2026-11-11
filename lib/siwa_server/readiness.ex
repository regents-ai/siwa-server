defmodule SiwaServer.Readiness do
  @moduledoc """
  Whether this server can serve sign-in, for `/readyz`.

  `check/0` runs every check now. `answer/0` keeps the last answer for
  `:readiness_keep_ms` (30 seconds unless set): `/readyz` is public, so
  requests share one check. A caller that finds the kept answer stale starts
  the check, and callers arriving meanwhile wait for that same answer instead
  of starting their own.

  The check runs in its own unlinked task, so a crash in it fails only the
  requests waiting for it, never this process. The reasons a check failed can
  name hosts, so they go to the log once per check and never into the public
  answer.
  """

  use GenServer

  require Logger

  alias Siwa.Ethereum
  alias SiwaServer.{Config, HostedRequests, Repo}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The kept answer, or a new one when it is stale."
  # Every probe in the check carries its own timeout, so the wait is bounded
  # by them.
  def answer do
    case GenServer.call(__MODULE__, :answer, :infinity) do
      {:ok, readiness} -> readiness
      {:exit, reason} -> exit(reason)
    end
  end

  @doc "Runs every check now."
  def check do
    base = Config.base_rpc_url()
    ethereum = Config.ethereum_rpc_url()
    world = Config.world_rpc_url()

    results = %{
      database: database_check(),
      endpoint_secret: endpoint_secret_check(),
      receipt_secret: receipt_secret_check(),
      # config/runtime.exs refuses to start with a TTL or tolerance that is not a positive integer.
      siwa_ttls: :ok,
      keystore_password: keystore_password_check(),
      hosted_keys: hosted_keys_check(),
      base_rpc_url: rpc_url_check("BASE_RPC_URL", base),
      base_rpc_chain_id: rpc_chain_id_check("BASE_RPC_URL", base, "0x2105"),
      ethereum_rpc_url: rpc_url_check("ETHEREUM_RPC_URL", ethereum),
      ethereum_rpc_chain_id: rpc_chain_id_check("ETHEREUM_RPC_URL", ethereum, "0x1"),
      world_rpc_url: rpc_url_check("WORLD_RPC_URL", world),
      world_rpc_chain_id: rpc_chain_id_check("WORLD_RPC_URL", world, "0x1e0")
    }

    checks = Map.new(results, fn {name, result} -> {name, result == :ok} end)
    failures = for {name, {:error, reason}} <- results, into: %{}, do: {name, reason}

    %{ready: failures == %{}, checks: checks, failures: failures}
  end

  @impl true
  def init(_opts), do: {:ok, nil}

  @impl true
  def handle_call(:answer, _from, kept) do
    now = System.monotonic_time(:millisecond)
    keep_ms = Application.get_env(:siwa_server, :readiness_keep_ms, 30_000)

    case kept do
      {checked_at, readiness} when now - checked_at < keep_ms ->
        {:reply, {:ok, readiness}, kept}

      _stale ->
        SiwaServer.TaskSupervisor
        |> Task.Supervisor.async_nolink(__MODULE__, :check, [])
        |> Task.yield(:infinity)
        |> case do
          {:ok, readiness} ->
            log_failures(readiness.failures)
            {:reply, {:ok, readiness}, {System.monotonic_time(:millisecond), readiness}}

          {:exit, reason} ->
            {:reply, {:exit, reason}, kept}
        end
    end
  end

  defp database_check do
    case Repo.query("select 1", [], timeout: 1_000) do
      {:ok, _result} -> :ok
      {:error, error} -> {:error, "database query failed: #{Exception.message(error)}"}
    end
  end

  defp endpoint_secret_check do
    secret = Application.get_env(:siwa_server, SiwaServerWeb.Endpoint, [])[:secret_key_base]

    if is_binary(secret) and String.trim(secret) != "",
      do: :ok,
      else: {:error, "endpoint secret_key_base is not configured"}
  end

  defp receipt_secret_check do
    case Config.receipt_secret() do
      {:ok, _secret} -> :ok
      {:error, _not_configured} -> {:error, "SIWA receipt secret is not configured"}
    end
  end

  defp keystore_password_check do
    if Config.keystore_password(),
      do: :ok,
      else: {:error, "keystore password is not configured"}
  end

  defp hosted_keys_check do
    case HostedRequests.keys_readable(timeout: 1_000) do
      :ok ->
        :ok

      {:error, :hosted_key_unreadable} ->
        {:error, "KEYSTORE_PASSWORD does not open the stored hosted keys"}

      {:error, %DBConnection.ConnectionError{} = error} ->
        {:error, "database connection failed: #{Exception.message(error)}"}

      {:error, %Postgrex.Error{} = error} ->
        {:error, "database query failed: #{Exception.message(error)}"}
    end
  end

  defp rpc_url_check(env_name, nil), do: {:error, "#{env_name} is not configured"}

  defp rpc_url_check(env_name, url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and host not in [nil, ""] ->
        :ok

      _invalid ->
        {:error, "#{env_name} is not a valid http(s) url"}
    end
  end

  # Only an http(s) url with a host is probed: the HTTP client raises on any other.
  defp rpc_chain_id_check(env_name, url, expected_hex) do
    with :ok <- rpc_url_check(env_name, url) do
      url
      |> Ethereum.json_rpc("eth_chainId", [],
        timeout_ms: Application.get_env(:siwa_server, :readiness_rpc_timeout_ms, 1_000),
        finch: SiwaServer.Finch
      )
      |> chain_id_answer(env_name, expected_hex)
    end
  end

  defp chain_id_answer({:ok, chain_id}, env_name, expected_hex) when is_binary(chain_id) do
    if String.downcase(chain_id) == expected_hex,
      do: :ok,
      else: {:error, "#{env_name} returned chain id #{chain_id}, expected #{expected_hex}"}
  end

  defp chain_id_answer({:ok, other}, env_name, _expected_hex),
    do: {:error, "#{env_name} returned an invalid chain id: #{inspect(other)}"}

  defp chain_id_answer({:error, reason}, env_name, _expected_hex),
    do: {:error, "#{env_name} chain id probe failed: #{inspect(reason)}"}

  defp log_failures(failures) do
    for {check, reason} <- failures do
      Logger.warning("readiness check failed check=#{check} reason=#{reason}")
    end
  end
end
