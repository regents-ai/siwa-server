defmodule SiwaServer.Ethereum do
  @moduledoc false

  alias SiwaServer.Ethereum.CastAdapter
  alias Req.TransportError

  @address_regex ~r/^0x[a-fA-F0-9]{40}$/
  @tx_hash_regex ~r/^0x[a-fA-F0-9]{64}$/
  @default_rpc_timeout_ms 5_000

  @spec normalize_address(term()) :: String.t() | nil
  def normalize_address(value) when is_binary(value) do
    trimmed = String.trim(value)

    if Regex.match?(@address_regex, trimmed) do
      String.downcase(trimmed)
    else
      nil
    end
  end

  def normalize_address(_value), do: nil

  @spec valid_address?(term()) :: boolean()
  def valid_address?(value), do: not is_nil(normalize_address(value))

  @spec valid_tx_hash?(term()) :: boolean()
  def valid_tx_hash?(value) when is_binary(value),
    do: Regex.match?(@tx_hash_regex, String.trim(value))

  def valid_tx_hash?(_value), do: false

  @spec namehash(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def namehash(name) do
    adapter().namehash(name)
  end

  @spec verify_signature(String.t(), String.t(), String.t()) :: :ok | {:error, String.t()}
  def verify_signature(address, message, signature) do
    case normalize_address(address) do
      nil -> {:error, "invalid address"}
      normalized_address -> adapter().verify_signature(normalized_address, message, signature)
    end
  end

  @spec synthetic_tx_hash([String.t()] | String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def synthetic_tx_hash(parts) when is_list(parts),
    do: parts |> Enum.join(":") |> synthetic_tx_hash()

  def synthetic_tx_hash(payload) when is_binary(payload) do
    adapter().synthetic_tx_hash(payload)
  end

  @spec owner_of(String.t(), pos_integer(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def owner_of(registry_address, token_id, opts \\ []) do
    with normalized_registry when is_binary(normalized_registry) <-
           normalize_address(registry_address),
         true <- is_integer(token_id) and token_id > 0,
         {:ok, owner} <- adapter().owner_of(normalized_registry, token_id, opts),
         normalized_owner when is_binary(normalized_owner) <- normalize_address(owner) do
      {:ok, normalized_owner}
    else
      nil -> {:error, "invalid address"}
      _ -> {:error, "invalid owner"}
    end
  end

  @spec json_rpc(String.t(), String.t(), list()) :: {:ok, map() | nil} | {:error, String.t()}
  def json_rpc(url, method, params) do
    timeout_ms = rpc_timeout_ms()

    request =
      Req.new(
        url: url,
        connect_options: [timeout: timeout_ms],
        receive_timeout: timeout_ms,
        retry: false,
        json: %{
          id: 1,
          jsonrpc: "2.0",
          method: method,
          params: params
        }
      )

    case Req.post(request) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        parse_rpc_response(body)

      {:ok, %{status: _status}} ->
        {:error, "rpc request failed"}

      {:error, %TransportError{reason: :timeout}} ->
        {:error, "rpc request timed out"}

      {:error, error} ->
        {:error, map_rpc_error(error)}
    end
  end

  @spec hex_to_integer(term()) :: integer()
  def hex_to_integer("0x"), do: 0

  def hex_to_integer(value) when is_binary(value),
    do: String.to_integer(String.replace_prefix(value, "0x", ""), 16)

  def hex_to_integer(_value), do: 0

  defp adapter do
    Application.get_env(:siwa_server, :ethereum_adapter, CastAdapter)
  end

  defp parse_rpc_response(%{"error" => %{"message" => message}})
       when is_binary(message) and byte_size(message) > 0 do
    {:error, message}
  end

  defp parse_rpc_response(%{"error" => _error}), do: {:error, "rpc request failed"}
  defp parse_rpc_response(%{"result" => result}), do: {:ok, result}
  defp parse_rpc_response(_body), do: {:error, "invalid rpc response"}

  defp map_rpc_error(error) do
    message = Exception.message(error)

    if String.contains?(String.downcase(message), "timeout") do
      "rpc request timed out"
    else
      "rpc request failed"
    end
  end

  defp rpc_timeout_ms do
    Application.get_env(:siwa_server, :ethereum_rpc_timeout_ms, @default_rpc_timeout_ms)
  end
end
