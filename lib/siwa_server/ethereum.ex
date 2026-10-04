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

  @wallet_chain_names %{1 => "Ethereum", 8453 => "Base"}

  @doc "The chains a wallet may sign in on."
  @spec wallet_chain_ids() :: [pos_integer()]
  def wallet_chain_ids, do: Map.keys(@wallet_chain_names)

  @spec chain_name(pos_integer()) :: String.t()
  def chain_name(chain_id), do: Map.fetch!(@wallet_chain_names, chain_id)

  @doc """
  Checks an ERC-191 personal signature over `message` from the wallet at
  `address`: an ordinary wallet's locally, a smart wallet's with ERC-1271 or
  ERC-6492 on the chain it signed in on (see `Siwa.WalletSignature`). Answers
  how the wallet was proven.
  """
  @spec verify_signature(String.t(), String.t(), String.t(), pos_integer()) ::
          {:ok, Siwa.WalletSignature.method()}
          | {:error, :signature_invalid}
          | {:error, {:lookup_failed, String.t()}}
  def verify_signature(address, message, signature, chain_id) do
    case Siwa.WalletSignature.verify(address, message, signature, rpc_opts(chain_id)) do
      {:ok, method} ->
        {:ok, method}

      {:error, :signature_invalid} ->
        {:error, :signature_invalid}

      {:error, {:lookup_failed, reason}} ->
        {:error, {:lookup_failed, lookup_reason(reason, chain_id)}}
    end
  end

  @doc "The RPC options for each sign-in chain, for signature checks through the shared SIWA library."
  @spec chain_rpcs() :: %{pos_integer() => keyword()}
  def chain_rpcs, do: Map.new(wallet_chain_ids(), &{&1, rpc_opts(&1)})

  defp rpc_opts(chain_id) do
    [
      rpc_url: Text.normalize_optional_text(rpc_url(chain_id)) || "",
      finch: SiwaServer.Finch,
      timeout_ms: rpc_timeout_ms()
    ]
  end

  defp rpc_url(1), do: RuntimeConfig.ethereum_rpc_url()
  defp rpc_url(8453), do: RuntimeConfig.base_rpc_url()

  defp lookup_reason(:rpc_url_required, chain_id),
    do: "#{String.downcase(chain_name(chain_id))} rpc url is not configured"

  defp lookup_reason(:rpc_request_timed_out, _chain_id), do: "rpc request timed out"
  defp lookup_reason(:invalid_rpc_response, _chain_id), do: "invalid rpc response"
  defp lookup_reason({:rpc_error, message}, _chain_id) when is_binary(message), do: message
  defp lookup_reason(_reason, _chain_id), do: "rpc request failed"

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
  defp telemetry_result({:error, {:rpc_error, _message}}), do: :provider_error
  defp telemetry_result({:error, _reason}), do: :bad_request

  defp map_ethereum_result({:ok, value}), do: {:ok, value}
  defp map_ethereum_result({:error, {:rpc_error, message}}), do: {:error, message}
  defp map_ethereum_result({:error, :invalid_address}), do: {:error, "invalid address"}
  defp map_ethereum_result({:error, :rpc_url_required}), do: {:error, "rpc url is required"}

  defp map_ethereum_result({:error, :rpc_request_timed_out}),
    do: {:error, "rpc request timed out"}

  defp map_ethereum_result({:error, :invalid_rpc_response}), do: {:error, "invalid rpc response"}
  defp map_ethereum_result({:error, _reason}), do: {:error, "rpc request failed"}
end
