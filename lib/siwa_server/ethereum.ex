defmodule SiwaServer.Ethereum do
  @moduledoc false

  alias RegentChain.{Abi, Call}
  alias SiwaServer.{Config, RuntimeConfig, Text}

  # ERC-1271: a contract wallet approves a signature by returning this selector.
  @erc1271_magic <<0x1626BA7E::32, 0::224>>
  # ERC-6492: a wallet not deployed yet appends this to its wrapped signature.
  @erc6492_suffix :binary.copy(<<0x64, 0x92>>, 16)
  # Multicall3, at the same address on Base and every other chain.
  @multicall3 "0xca11bde05977b3631167028862be2a173976ca11"

  @spec normalize_address(term()) :: String.t() | nil
  def normalize_address(value) do
    case Siwa.Ethereum.normalize_address(value) do
      {:ok, address} -> address
      {:error, _reason} -> nil
    end
  end

  @doc """
  Checks an ERC-191 personal signature over `message` from the wallet at
  `address` on Base.

  An ordinary wallet's signature is recovered locally. Any other signature is a
  smart wallet's, checked on Base with ERC-1271 `isValidSignature`; a wallet
  not deployed yet wraps its signature with ERC-6492, and its factory call runs
  first in the same read, so nothing is deployed.
  """
  @spec verify_signature(String.t(), String.t(), String.t()) ::
          :ok | {:error, :signature_invalid} | {:error, {:lookup_failed, String.t()}}
  def verify_signature(address, message, signature) do
    with address when is_binary(address) <- normalize_address(address),
         {:ok, bytes} <- Abi.bytes(signature),
         true <- byte_size(bytes) > 0 do
      wallet_signature(address, Siwa.EvmPersonalSign.personal_hash(message), bytes)
    else
      _invalid -> {:error, :signature_invalid}
    end
  end

  defp wallet_signature(address, digest, bytes) do
    case erc6492_unwrap(bytes) do
      {:ok, deployment, inner} -> contract_signature(address, digest, inner, [deployment])
      :not_wrapped -> key_or_contract_signature(address, digest, bytes)
      :error -> {:error, :signature_invalid}
    end
  end

  defp key_or_contract_signature(address, digest, bytes) do
    case Siwa.EvmPersonalSign.recover_address(digest, hex(bytes)) do
      {:ok, recovered} when is_binary(recovered) ->
        if String.downcase(recovered) == address,
          do: :ok,
          else: contract_signature(address, digest, bytes, [])

      {:error, _reason} ->
        contract_signature(address, digest, bytes, [])
    end
  end

  defp erc6492_unwrap(bytes) do
    wrapped_size = byte_size(bytes) - 32

    case bytes do
      <<wrapped::binary-size(wrapped_size), @erc6492_suffix>> ->
        case Abi.decode(wrapped, [:address, :bytes, :bytes]) do
          {:ok, [factory, calldata, inner]} -> {:ok, {factory, true, hex(calldata)}, inner}
          :error -> :error
        end

      _unwrapped ->
        :not_wrapped
    end
  end

  # One read through Multicall3: any deployment first, then the wallet's own
  # answer. A call that reverts comes back as a failed result, not an error.
  defp contract_signature(address, digest, signature, deployment) do
    check =
      {address, true,
       Call.encode("isValidSignature(bytes32,bytes)", [hex(digest), hex(signature)])}

    data = Call.encode("aggregate3((address,bool,bytes)[])", [deployment ++ [check]])

    with {:ok, rpc_url} <- base_rpc_url(),
         {:ok, result} <-
           json_rpc(rpc_url, "eth_call", [%{"to" => @multicall3, "data" => data}, "latest"]),
         {:ok, answer} <- wallet_answer(result) do
      case answer do
        {1, @erc1271_magic} -> :ok
        _refused -> {:error, :signature_invalid}
      end
    else
      {:error, reason} -> {:error, {:lookup_failed, reason}}
    end
  end

  # The last `(bool success, bytes returnData)` of Multicall3's result array:
  # the wallet's own answer, read in its one canonical encoding.
  defp wallet_answer(result) do
    with {:ok, <<32::256, count::256, rest::binary>>} when count > 0 <- Abi.bytes(result),
         <<_heads::binary-size(32 * (count - 1)), offset::256, _tail::binary>> <- rest,
         <<_skipped::binary-size(offset), success::256, 64::256, size::256,
           answer::binary-size(size), _padding::binary>>
         when success in [0, 1] <- rest do
      {:ok, {success, answer}}
    else
      _malformed -> {:error, "invalid rpc response"}
    end
  end

  defp base_rpc_url do
    case Text.normalize_optional_text(RuntimeConfig.base_rpc_url()) do
      nil -> {:error, "base rpc url is not configured"}
      rpc_url -> {:ok, rpc_url}
    end
  end

  defp hex(bytes), do: "0x" <> Base.encode16(bytes, case: :lower)

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
