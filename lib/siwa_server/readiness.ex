defmodule SiwaServer.Readiness do
  @moduledoc false

  alias SiwaServer.Repo
  alias SiwaServer.RuntimeConfig
  alias Siwa.Ethereum

  @supported_keyring_backend "encrypted_file"

  def check do
    checks = %{
      database: database_ready?(),
      endpoint_secret: endpoint_secret_ready?(),
      receipt_secret: app_secret_ready?(:siwa_server, :siwa, :receipt_secret),
      keyring_backend: keyring_backend_ready?(),
      keyring_password: keyring_secret_ready?(:password),
      keyring_secret: keyring_secret_ready?(:secret),
      keystore_path: keystore_path_ready?(),
      base_rpc_url: base_rpc_url_ready?(),
      base_rpc_reachable: base_rpc_reachable?()
    }

    %{ready: Enum.all?(Map.values(checks)), checks: checks}
  end

  defp database_ready? do
    match?({:ok, _result}, Repo.query("select 1", [], timeout: 1_000))
  rescue
    _ -> false
  end

  defp app_secret_ready?(app, key, secret_key) do
    app
    |> Application.get_env(key, [])
    |> Keyword.get(secret_key)
    |> non_empty_binary?()
  end

  defp endpoint_secret_ready? do
    :siwa_server
    |> Application.get_env(SiwaServerWeb.Endpoint, [])
    |> Keyword.get(:secret_key_base)
    |> non_empty_binary?()
  end

  defp keyring_backend_ready? do
    Application.get_env(:siwa_keyring, :backend) == @supported_keyring_backend
  end

  defp keyring_secret_ready?(key) do
    :siwa_keyring
    |> Application.get_env(key)
    |> non_empty_binary?()
  end

  defp keystore_path_ready? do
    if keyring_backend_ready?() do
      encrypted_file_keystore_path_ready?()
    else
      false
    end
  end

  defp encrypted_file_keystore_path_ready? do
    path = Application.get_env(:siwa_keyring, :path)

    with true <- non_empty_binary?(path),
         parent when is_binary(parent) <- Path.dirname(path),
         true <- File.dir?(parent),
         probe <- Path.join(parent, ".siwa-readyz-#{System.unique_integer([:positive])}"),
         :ok <- File.write(probe, ""),
         :ok <- File.rm(probe) do
      true
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  defp base_rpc_url_ready? do
    case RuntimeConfig.base_rpc_url() do
      nil ->
        false

      url ->
        uri = URI.parse(url)
        uri.scheme in ["http", "https"] and is_binary(uri.host)
    end
  end

  defp base_rpc_reachable? do
    case RuntimeConfig.base_rpc_url() do
      nil ->
        false

      url ->
        match?(
          {:ok, "0x" <> _hex},
          Ethereum.json_rpc(url, "eth_chainId", [],
            timeout_ms: readiness_rpc_timeout_ms(),
            finch: SiwaServer.Finch
          )
        )
    end
  rescue
    _ -> false
  end

  defp readiness_rpc_timeout_ms do
    Application.get_env(:siwa_server, :readiness_rpc_timeout_ms, 1_000)
  end

  defp non_empty_binary?(value) when is_binary(value), do: String.trim(value) != ""
  defp non_empty_binary?(_value), do: false
end
