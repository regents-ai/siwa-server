defmodule SiwaServer.Ethereum do
  @moduledoc false

  alias SiwaServer.Config

  @spec normalize_address(term()) :: String.t() | nil
  def normalize_address(value) do
    case Siwa.Ethereum.normalize_address(value) do
      {:ok, address} -> address
      {:error, _reason} -> nil
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

  defp rpc_timeout_ms, do: Config.ethereum_rpc_timeout_ms()

  defp telemetry_span(operation, metadata, fun) do
    :telemetry.span(
      [:siwa_server, :ethereum, :rpc],
      Map.put(metadata, :operation, operation),
      fun
    )
  end

  defp telemetry_result({:ok, _value}), do: :success
  defp telemetry_result({:error, :rpc_request_timed_out}), do: :timeout
  defp telemetry_result({:error, :invalid_rpc_response}), do: :bad_response
  defp telemetry_result({:error, :invalid_owner}), do: :bad_response
  defp telemetry_result({:error, {:rpc_error, _message}}), do: :provider_error
  defp telemetry_result({:error, _reason}), do: :bad_request

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
