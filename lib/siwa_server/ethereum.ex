defmodule SiwaServer.Ethereum do
  @moduledoc false

  @default_rpc_timeout_ms 5_000

  @spec normalize_address(term()) :: String.t() | nil
  def normalize_address(value) do
    case Siwa.Ethereum.normalize_address(value) do
      {:ok, address} -> address
      {:error, _reason} -> nil
    end
  end

  @spec valid_address?(term()) :: boolean()
  def valid_address?(value), do: Siwa.Ethereum.valid_address?(value)

  @spec valid_tx_hash?(term()) :: boolean()
  def valid_tx_hash?(value), do: Siwa.Ethereum.valid_tx_hash?(value)

  @spec namehash(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def namehash(name) do
    case Siwa.Ethereum.namehash(name) do
      {:ok, hash} -> {:ok, hash}
      {:error, :invalid_ens_name} -> {:error, "invalid ENS name"}
    end
  end

  @spec verify_signature(String.t(), String.t(), String.t()) :: :ok | {:error, String.t()}
  def verify_signature(address, message, signature) do
    case normalize_address(address) do
      nil ->
        {:error, "invalid address"}

      normalized_address ->
        case Siwa.EvmPersonalSign.verify_personal_signature(
               message,
               signature,
               normalized_address
             ) do
          :ok -> :ok
          {:error, _reason} -> {:error, "Invalid signature"}
        end
    end
  end

  @spec synthetic_tx_hash([String.t()] | String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def synthetic_tx_hash(parts) when is_list(parts),
    do: parts |> Enum.join(":") |> synthetic_tx_hash()

  def synthetic_tx_hash(payload) when is_binary(payload) do
    Siwa.Ethereum.keccak_hex(payload)
  end

  @spec owner_of(String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def owner_of(registry_address, token_id, opts \\ []) do
    rpc_url = Keyword.get(opts, :rpc_url)

    telemetry_span(:owner_of, %{registry_address: registry_address}, fn ->
      result =
        Siwa.Ethereum.owner_of(registry_address, token_id, rpc_url,
          timeout_ms: rpc_timeout_ms(),
          finch: SiwaServer.Finch
        )

      {map_ethereum_result(result), %{result: telemetry_result(result)}}
    end)
  end

  @spec json_rpc(String.t(), String.t(), list()) :: {:ok, map() | nil} | {:error, String.t()}
  def json_rpc(url, method, params) do
    telemetry_span(:json_rpc, %{method: method}, fn ->
      result =
        Siwa.Ethereum.json_rpc(url, method, params,
          timeout_ms: rpc_timeout_ms(),
          finch: SiwaServer.Finch
        )

      {map_ethereum_result(result), %{result: telemetry_result(result)}}
    end)
  end

  @spec hex_to_integer(term()) :: integer()
  def hex_to_integer("0x"), do: 0

  def hex_to_integer(value) when is_binary(value),
    do: String.to_integer(String.replace_prefix(value, "0x", ""), 16)

  def hex_to_integer(_value), do: 0

  defp rpc_timeout_ms do
    Application.get_env(:siwa_server, :ethereum_rpc_timeout_ms, @default_rpc_timeout_ms)
  end

  defp telemetry_span(operation, metadata, fun) do
    :telemetry.span(
      [:siwa_server, :ethereum, :rpc],
      Map.put(metadata, :operation, operation),
      fun
    )
  end

  defp telemetry_result({:ok, _value}), do: :ok
  defp telemetry_result({:error, reason}), do: reason

  defp map_ethereum_result({:ok, value}), do: {:ok, value}
  defp map_ethereum_result({:error, {:rpc_error, message}}), do: {:error, message}
  defp map_ethereum_result({:error, :invalid_address}), do: {:error, "invalid address"}
  defp map_ethereum_result({:error, :invalid_token_id}), do: {:error, "invalid token id"}
  defp map_ethereum_result({:error, :token_id_too_large}), do: {:error, "invalid token id"}
  defp map_ethereum_result({:error, :rpc_url_required}), do: {:error, "rpc url is required"}

  defp map_ethereum_result({:error, :rpc_request_timed_out}),
    do: {:error, "rpc request timed out"}

  defp map_ethereum_result({:error, :invalid_rpc_response}), do: {:error, "invalid rpc response"}
  defp map_ethereum_result({:error, :invalid_owner}), do: {:error, "invalid owner"}
  defp map_ethereum_result({:error, _reason}), do: {:error, "rpc request failed"}
end
