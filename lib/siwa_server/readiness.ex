defmodule SiwaServer.Readiness do
  @moduledoc false

  alias SiwaServer.Config
  alias SiwaServer.Repo
  alias SiwaServer.RuntimeConfig
  alias Siwa.Ethereum

  @base_chain_id_hex "0x2105"
  @supported_keyring_backend "encrypted_file"

  def check do
    results = %{
      database: database_check(),
      endpoint_secret: endpoint_secret_check(),
      receipt_secret: receipt_secret_check(),
      keyring_backend: keyring_backend_check(),
      keyring_password: keyring_secret_check(:password),
      keyring_secret: keyring_secret_check(:secret),
      keystore_path: keystore_path_check(),
      base_rpc_url: base_rpc_url_check(),
      base_rpc_chain_id: base_rpc_chain_id_check()
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

  defp keyring_backend_check do
    case Application.get_env(:siwa_keyring, :backend) do
      @supported_keyring_backend ->
        :ok

      backend ->
        {:error, "keyring backend #{inspect(backend)} is not #{@supported_keyring_backend}"}
    end
  end

  defp keyring_secret_check(key) do
    :siwa_keyring
    |> Application.get_env(key)
    |> secret_check("keyring #{key} is not configured")
  end

  defp keystore_path_check do
    with :ok <- keyring_backend_check() do
      encrypted_file_keystore_path_check()
    end
  end

  defp encrypted_file_keystore_path_check do
    path = Application.get_env(:siwa_keyring, :path)

    cond do
      not non_empty_binary?(path) ->
        {:error, "keystore path is not configured"}

      not File.dir?(Path.dirname(path)) ->
        {:error, "keystore directory does not exist"}

      true ->
        keystore_write_check(Path.dirname(path))
    end
  end

  defp keystore_write_check(parent) do
    probe = Path.join(parent, ".siwa-readyz-#{System.unique_integer([:positive])}")

    with :ok <- File.write(probe, ""),
         :ok <- File.rm(probe) do
      :ok
    else
      {:error, posix} -> {:error, "keystore directory is not writable: #{posix}"}
    end
  end

  defp base_rpc_url_check do
    case RuntimeConfig.base_rpc_url() do
      nil ->
        {:error, "BASE_RPC_URL is not configured"}

      url ->
        uri = URI.parse(url)

        if uri.scheme in ["http", "https"] and is_binary(uri.host) do
          :ok
        else
          {:error, "BASE_RPC_URL is not a valid http(s) url"}
        end
    end
  end

  defp base_rpc_chain_id_check do
    case RuntimeConfig.base_rpc_url() do
      nil ->
        {:error, "BASE_RPC_URL is not configured"}

      url ->
        case Ethereum.json_rpc(url, "eth_chainId", [],
               timeout_ms: Config.readiness_rpc_timeout_ms(),
               finch: SiwaServer.Finch
             ) do
          {:ok, chain_id} when is_binary(chain_id) ->
            if String.downcase(chain_id) == @base_chain_id_hex do
              :ok
            else
              {:error, "base rpc returned chain id #{chain_id}, expected #{@base_chain_id_hex}"}
            end

          {:ok, other} ->
            {:error, "base rpc returned an invalid chain id: #{inspect(other)}"}

          {:error, reason} ->
            {:error, "base rpc chain id probe failed: #{inspect(reason)}"}
        end
    end
  rescue
    # Finch raises when the SiwaServer.Finch pool is not running.
    error in ArgumentError ->
      {:error, "base rpc chain id probe failed: #{Exception.message(error)}"}
  end

  defp secret_check(value, missing_reason) do
    if non_empty_binary?(value), do: :ok, else: {:error, missing_reason}
  end

  defp non_empty_binary?(value) when is_binary(value), do: String.trim(value) != ""
  defp non_empty_binary?(_value), do: false
end
