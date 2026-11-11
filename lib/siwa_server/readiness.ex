defmodule SiwaServer.Readiness do
  @moduledoc false

  alias Siwa.Ethereum
  alias SiwaServer.Config
  alias SiwaServer.HostedIdentities
  alias SiwaServer.Repo
  alias SiwaServer.RuntimeConfig

  @base_chain_id_hex "0x2105"
  @ethereum_chain_id_hex "0x1"
  @world_chain_id_hex "0x1e0"

  def check do
    results = %{
      database: database_check(),
      endpoint_secret: endpoint_secret_check(),
      receipt_secret: receipt_secret_check(),
      siwa_ttls: siwa_ttl_check(),
      keystore_password: keystore_password_check(),
      hosted_keys: hosted_keys_check(),
      base_rpc_url: rpc_url_check("BASE_RPC_URL", RuntimeConfig.base_rpc_url()),
      base_rpc_chain_id:
        rpc_chain_id_check("BASE_RPC_URL", RuntimeConfig.base_rpc_url(), @base_chain_id_hex),
      ethereum_rpc_url: rpc_url_check("ETHEREUM_RPC_URL", RuntimeConfig.ethereum_rpc_url()),
      ethereum_rpc_chain_id:
        rpc_chain_id_check(
          "ETHEREUM_RPC_URL",
          RuntimeConfig.ethereum_rpc_url(),
          @ethereum_chain_id_hex
        ),
      world_rpc_url: rpc_url_check("WORLD_RPC_URL", RuntimeConfig.world_rpc_url()),
      world_rpc_chain_id:
        rpc_chain_id_check("WORLD_RPC_URL", RuntimeConfig.world_rpc_url(), @world_chain_id_hex)
    }

    checks = Map.new(results, fn {name, result} -> {name, result == :ok} end)
    failures = for {name, {:error, reason}} <- results, into: %{}, do: {name, reason}

    %{ready: failures == %{}, checks: checks, failures: failures}
  end

  defp database_check do
    case Repo.query("select 1", [], timeout: 1_000) do
      {:ok, _result} -> :ok
      {:error, error} -> {:error, "database query failed: #{Exception.message(error)}"}
    end
  rescue
    error in DBConnection.ConnectionError ->
      {:error, "database connection failed: #{Exception.message(error)}"}
  end

  defp endpoint_secret_check do
    Config.endpoint()
    |> Keyword.get(:secret_key_base)
    |> secret_check("endpoint secret_key_base is not configured")
  end

  defp receipt_secret_check do
    Config.siwa()
    |> Keyword.get(:receipt_secret)
    |> secret_check("SIWA receipt secret is not configured")
  end

  # TTL and tolerance readers raise ArgumentError on misconfiguration; surfacing
  # it here keeps a bad value from becoming a per-request 500 after deploy.
  defp siwa_ttl_check do
    _nonce_ttl = RuntimeConfig.siwa_nonce_ttl_seconds()
    _receipt_ttl = RuntimeConfig.siwa_receipt_ttl_seconds()
    _tolerance = RuntimeConfig.siwa_http_signature_tolerance_seconds()
    :ok
  rescue
    error in ArgumentError -> {:error, Exception.message(error)}
  end

  defp keystore_password_check do
    Config.siwa()
    |> Keyword.get(:keystore_password)
    |> secret_check("keystore password is not configured")
  end

  defp hosted_keys_check do
    case HostedIdentities.readable(timeout: 1_000) do
      :ok ->
        :ok

      {:error, :hosted_key_unreadable} ->
        {:error, "KEYSTORE_PASSWORD does not open the stored hosted keys"}
    end
  rescue
    error in DBConnection.ConnectionError ->
      {:error, "database connection failed: #{Exception.message(error)}"}

    error in Postgrex.Error ->
      {:error, "database query failed: #{Exception.message(error)}"}
  end

  defp rpc_url_check(env_name, url) do
    case url do
      nil ->
        {:error, "#{env_name} is not configured"}

      url ->
        uri = URI.parse(url)

        if uri.scheme in ["http", "https"] and is_binary(uri.host) do
          :ok
        else
          {:error, "#{env_name} is not a valid http(s) url"}
        end
    end
  end

  defp rpc_chain_id_check(env_name, nil, _expected_hex),
    do: {:error, "#{env_name} is not configured"}

  defp rpc_chain_id_check(env_name, url, expected_hex) do
    case Ethereum.json_rpc(url, "eth_chainId", [],
           timeout_ms: Config.readiness_rpc_timeout_ms(),
           finch: SiwaServer.Finch
         ) do
      {:ok, chain_id} when is_binary(chain_id) ->
        if String.downcase(chain_id) == expected_hex do
          :ok
        else
          {:error, "#{env_name} returned chain id #{chain_id}, expected #{expected_hex}"}
        end

      {:ok, other} ->
        {:error, "#{env_name} returned an invalid chain id: #{inspect(other)}"}

      {:error, reason} ->
        {:error, "#{env_name} chain id probe failed: #{inspect(reason)}"}
    end
  rescue
    # Finch raises when the SiwaServer.Finch pool is not running.
    error in ArgumentError ->
      {:error, "#{env_name} chain id probe failed: #{Exception.message(error)}"}
  end

  defp secret_check(value, missing_reason) do
    if non_empty_binary?(value), do: :ok, else: {:error, missing_reason}
  end

  defp non_empty_binary?(value) when is_binary(value), do: String.trim(value) != ""
  defp non_empty_binary?(_value), do: false
end
