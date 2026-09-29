defmodule SiwaServer.Ethereum do
  @moduledoc false

  alias SiwaServer.{Config, RuntimeConfig, Text}

  @spec normalize_address(term()) :: String.t() | nil
  def normalize_address(value) do
    case Siwa.Ethereum.normalize_address(value) do
      {:ok, address} -> address
      {:error, _reason} -> nil
    end
  end

  @doc """
  Checks an ERC-191 personal signature over `message` from the wallet at
  `address`: an ordinary wallet's locally, a smart wallet's on Base with
  ERC-1271 or ERC-6492 (see `Siwa.WalletSignature`).
  """
  @spec verify_signature(String.t(), String.t(), String.t()) ::
          :ok | {:error, :signature_invalid} | {:error, {:lookup_failed, String.t()}}
  def verify_signature(address, message, signature) do
    case Siwa.WalletSignature.verify(address, message, signature, base_rpc_opts()) do
      :ok -> :ok
      {:error, :signature_invalid} -> {:error, :signature_invalid}
      {:error, {:lookup_failed, reason}} -> {:error, {:lookup_failed, lookup_reason(reason)}}
    end
  end

  @doc "The Base RPC options for a signature check through the shared SIWA library."
  @spec base_rpc_opts() :: keyword()
  def base_rpc_opts do
    [
      rpc_url: Text.normalize_optional_text(RuntimeConfig.base_rpc_url()) || "",
      finch: SiwaServer.Finch,
      timeout_ms: rpc_timeout_ms()
    ]
  end

  defp lookup_reason(:rpc_url_required), do: "base rpc url is not configured"
  defp lookup_reason(:rpc_request_timed_out), do: "rpc request timed out"
  defp lookup_reason(:invalid_rpc_response), do: "invalid rpc response"
  defp lookup_reason({:rpc_error, message}) when is_binary(message), do: message
  defp lookup_reason(_reason), do: "rpc request failed"

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
