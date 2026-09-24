defmodule SiwaServer.EthereumTest do
  use ExUnit.Case, async: true

  alias SiwaServer.Ethereum

  # Signatures made outside this app (Foundry `cast wallet sign`) with the
  # well-known Anvil key 0 over messages of `n` repeated "a" characters. These
  # lengths put the signed payload at a multiple of 136 bytes, where the old
  # hashing library gave wrong hashes and genuine signatures were refused.
  @address "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
  @signatures %{
    106 =>
      "0xbe8df8ef131212290c29ff482039102acb5a3e9d0c768ed3bcf2742ea90836042c5188af663cad666d3f19d67494699247b92d79e64f0f6b16d8b86d7277d43f1b",
    243 =>
      "0x1fd9124f093a41c66252cbf0b457695cdf5ca0f2c79503ce865d20cdb6ef1be02369444bd48c745e06b062067a5d42f237b826abba986b62c263fa6a81b0d1131c",
    379 =>
      "0xfd3e8349f59b5ff6788228b9c726f2029537d6f6fcf3d9cf59848fe7d01725751d2879aeb4b1bb66beb96c55605c5ff25056c05a81063e4c21f59458543e58f21c",
    515 =>
      "0x14c51c30a02493762570f4e00dc86947c00f7552368da8208bd947c9e491a3132a055ca10884a05d1acaa92447dc93312e0cf81f6e41466cc420c03046b6f3001c"
  }

  test "genuine signatures verify at every message length" do
    for {length, signature} <- @signatures do
      assert Ethereum.verify_signature(@address, String.duplicate("a", length), signature) == :ok,
             "a #{length}-byte message was refused"
    end
  end
end
