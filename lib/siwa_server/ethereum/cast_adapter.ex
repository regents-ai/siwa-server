defmodule SiwaServer.Ethereum.CastAdapter do
  @moduledoc false
  @behaviour SiwaServer.Ethereum.Adapter

  @impl true
  def namehash(name) do
    run_cast(["namehash", String.trim(name)])
  end

  @impl true
  def verify_signature(address, message, signature) do
    case System.cmd(
           "cast",
           ["wallet", "verify", "--address", String.trim(address), message, signature],
           stderr_to_stdout: true
         ) do
      {_, 0} -> :ok
      {output, _status} -> {:error, String.trim(output)}
    end
  rescue
    error in ErlangError ->
      {:error, format_system_error(error)}
  catch
    :exit, reason ->
      {:error, inspect(reason)}
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
    case System.cmd("cast", args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, _status} -> {:error, String.trim(output)}
    end
  rescue
    error in ErlangError ->
      {:error, format_system_error(error)}
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

  defp format_system_error(%ErlangError{original: :enoent}) do
    "cast executable not found on the server"
  end

  defp format_system_error(%ErlangError{original: original}) when is_atom(original) do
    Atom.to_string(original)
  end

  defp format_system_error(%ErlangError{} = error) do
    Exception.message(error)
  end
end
