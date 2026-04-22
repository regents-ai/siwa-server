defmodule SiwaServer.TestEthereumAdapter do
  @moduledoc false
  @behaviour SiwaServer.Ethereum.Adapter

  @spec sign_message(String.t(), String.t()) :: String.t()
  def sign_message(address, message) do
    "signed:#{String.downcase(address)}:#{Base.url_encode64(message, padding: false)}"
  end

  @impl true
  def namehash(name) do
    {:ok, encode_hash(String.trim(name))}
  end

  @impl true
  def verify_signature(address, message, signature) do
    expected = sign_message(address, message)
    if signature == expected, do: :ok, else: {:error, "Invalid signature"}
  end

  @impl true
  def synthetic_tx_hash(payload) do
    {:ok, encode_hash(payload)}
  end

  @impl true
  def owner_of(registry_address, token_id, _opts) do
    registry_address = SiwaServer.Ethereum.normalize_address(registry_address)

    case :persistent_term.get({__MODULE__, :owner_of, registry_address, token_id}, :undefined) do
      owner when is_binary(owner) -> {:ok, owner}
      :undefined -> {:error, "owner not configured"}
    end
  end

  def put_owner(registry_address, token_id, owner_address) do
    :persistent_term.put(
      {__MODULE__, :owner_of, SiwaServer.Ethereum.normalize_address(registry_address),
       normalize_token_id(token_id)},
      String.downcase(owner_address)
    )
  end

  def delete_owner(registry_address, token_id) do
    :persistent_term.erase(
      {__MODULE__, :owner_of, SiwaServer.Ethereum.normalize_address(registry_address),
       normalize_token_id(token_id)}
    )
  end

  defp normalize_token_id(token_id) when is_integer(token_id), do: token_id
  defp normalize_token_id(token_id) when is_binary(token_id), do: String.to_integer(token_id)

  defp encode_hash(value) do
    "0x" <>
      (:crypto.hash(:sha256, value)
       |> Base.encode16(case: :lower)
       |> binary_part(0, 64))
  end
end
