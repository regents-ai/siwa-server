defmodule SiwaServer.TestEthereumAdapter do
  @moduledoc false
  @behaviour SiwaServer.Ethereum.Adapter

  @spec sign_message(String.t(), String.t()) :: String.t()
  def sign_message(address, message) do
    "0x" <> Base.encode16(signature_bytes(address, message), case: :lower)
  end

  @impl true
  def namehash(name) do
    {:ok, encode_hash(String.trim(name))}
  end

  @impl true
  def verify_signature(address, message, signature) do
    expected = sign_message(address, message)

    case normalize_signature(signature) do
      {:ok, ^expected} -> :ok
      _ -> {:error, "Invalid signature"}
    end
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

  defp signature_bytes(address, message) do
    payload = "#{String.downcase(address)}|#{message}"
    :crypto.hash(:sha512, payload) <> <<27>>
  end

  defp normalize_signature("0x" <> hex = signature) when byte_size(hex) == 130 do
    case Base.decode16(hex, case: :mixed) do
      {:ok, <<_::binary-size(65)>>} -> {:ok, String.downcase(signature)}
      _ -> :error
    end
  end

  defp normalize_signature(_signature), do: :error
end
