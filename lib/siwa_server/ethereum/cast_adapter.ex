defmodule SiwaServer.Ethereum.CastAdapter do
  @moduledoc false
  @behaviour SiwaServer.Ethereum.Adapter
  @default_cast_timeout_ms 5_000

  @impl true
  def namehash(name) do
    run_cast(["namehash", String.trim(name)])
  end

  @impl true
  def verify_signature(address, message, signature) do
    case run_cast(["wallet", "verify", "--address", String.trim(address), message, signature]) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def synthetic_tx_hash(payload) do
    run_cast(["keccak", payload])
  end

  @impl true
  def owner_of(registry_address, token_id, opts) do
    with {:ok, rpc_url} <- fetch_rpc_url(opts),
         {:ok, owner} <-
           run_cast([
             "call",
             "--rpc-url",
             rpc_url,
             String.trim(registry_address),
             "ownerOf(uint256)(address)",
             Integer.to_string(token_id)
           ]),
         normalized_owner when is_binary(normalized_owner) <-
           SiwaServer.Ethereum.normalize_address(owner) do
      {:ok, normalized_owner}
    else
      nil -> {:error, "invalid ownerOf response"}
      {:error, _reason} = error -> error
    end
  end

  defp run_cast(args) do
    with {:ok, executable} <- resolve_executable(cast_executable()) do
      port =
        Port.open(
          {:spawn_executable, executable},
          [:binary, :exit_status, :hide, :use_stdio, :stderr_to_stdout, args: args]
        )

      collect_output(port, "", cast_timeout_ms())
    end
  catch
    :exit, reason ->
      {:error, inspect(reason)}
  end

  defp fetch_rpc_url(opts) do
    case Keyword.get(opts, :rpc_url) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, "rpc url is required"}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, "rpc url is required"}
    end
  end

  defp resolve_executable(executable) when is_binary(executable) do
    cond do
      Path.type(executable) != :relative and File.exists?(executable) ->
        {:ok, executable}

      resolved = System.find_executable(executable) ->
        {:ok, resolved}

      true ->
        {:error, "#{Path.basename(executable)} executable not found on the server"}
    end
  end

  defp collect_output(port, output, timeout_ms) do
    receive do
      {^port, {:data, data}} ->
        collect_output(port, output <> data, timeout_ms)

      {^port, {:exit_status, 0}} ->
        {:ok, String.trim(output)}

      {^port, {:exit_status, _status}} ->
        trimmed = String.trim(output)
        {:error, if(trimmed == "", do: "cast command failed", else: trimmed)}
    after
      timeout_ms ->
        Port.close(port)
        {:error, "cast command timed out"}
    end
  end

  defp cast_executable do
    Application.get_env(:siwa_server, :cast_executable, "cast")
  end

  defp cast_timeout_ms do
    Application.get_env(:siwa_server, :cast_timeout_ms, @default_cast_timeout_ms)
  end
end
