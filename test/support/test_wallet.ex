defmodule SiwaServer.TestWallet do
  @moduledoc false

  @eth_prefix "\x19Ethereum Signed Message:\n"
  @private_key Base.decode16!(
                 "ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80",
                 case: :mixed
               )

  @spec address() :: String.t()
  def address do
    {:ok, <<4, raw::binary-size(64)>>} = ExSecp256k1.create_public_key(@private_key)

    hash = KeccakEx.hash_256(raw)
    "0x" <> Base.encode16(binary_part(hash, byte_size(hash) - 20, 20), case: :lower)
  end

  @spec sign_message(String.t()) :: String.t()
  def sign_message(message) do
    {:ok, {signature, recovery_id}} =
      ExSecp256k1.sign_compact(personal_hash(message), @private_key)

    "0x" <> Base.encode16(signature <> <<recovery_id + 27>>, case: :lower)
  end

  defp personal_hash(message) do
    ("#{@eth_prefix}#{byte_size(message)}" <> message)
    |> KeccakEx.hash_256()
  end
end
