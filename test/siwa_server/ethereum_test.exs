defmodule SiwaServer.EthereumTest do
  use ExUnit.Case, async: false

  alias SiwaServer.{Ethereum, TestRpcServer}

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
      for chain_id <- Ethereum.wallet_chain_ids() do
        assert Ethereum.verify_signature(
                 @address,
                 String.duplicate("a", length),
                 signature,
                 chain_id
               ) ==
                 {:ok, :eoa_recovery},
               "a #{length}-byte message was refused on chain #{chain_id}"
      end
    end
  end

  describe "smart wallets" do
    # Coinbase Smart Wallet v1.1 signatures over @smart_message, made with viem
    # 2.55 by fresh owner keys and checked live: the undeployed wallet's
    # ERC-6492 signature against Base, the deployed wallet's ERC-1271 signature
    # against a local copy of Base with the wallet created.
    @smart_message "regent smart wallet sign-in test"
    @undeployed_wallet "0x06D30a8DA60dDd004A93db4C1b3360c9068e64C1"
    @undeployed_factory "0xba5ed110efdba3d005bfc882d75358acbbb85842"
    @undeployed_signature "0x000000000000000000000000ba5ed110efdba3d005bfc882d75358acbbb858420000000000000000000000" <>
                            "0000000000000000000000000000000000000000600000000000000000000000000000000000000000000000" <>
                            "00000000000000016000000000000000000000000000000000000000000000000000000000000000c43ffba3" <>
                            "6f00000000000000000000000000000000000000000000000000000000000000400000000000000000000000" <>
                            "0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000" <>
                            "0000000000000000010000000000000000000000000000000000000000000000000000000000000020000000" <>
                            "0000000000000000000000000000000000000000000000000000000020000000000000000000000000429A71" <>
                            "fE1C17F890c3545F4ad05e4559c5489faA000000000000000000000000000000000000000000000000000000" <>
                            "0000000000000000000000000000000000000000000000000000000000000000e00000000000000000000000" <>
                            "0000000000000000000000000000000000000000200000000000000000000000000000000000000000000000" <>
                            "0000000000000000000000000000000000000000000000000000000000000000000000000000000040000000" <>
                            "00000000000000000000000000000000000000000000000000000000413638a953c53d446d4e108db1958e17" <>
                            "5a12f57180e105075683ad89bf66bdf8c0109405fee4a49234c2b298b8b12eeed15931b24a5d83d507a041ac" <>
                            "3943f5e3fa1c0000000000000000000000000000000000000000000000000000000000000064926492649264" <>
                            "92649264926492649264926492649264926492649264926492"
    @deployed_wallet "0x452f678f6e588069D1Aef38D3D519567aA1014A4"
    @deployed_signature "0x00000000000000000000000000000000000000000000000000000000000000200000000000000000000000" <>
                          "0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000" <>
                          "0000000000000000400000000000000000000000000000000000000000000000000000000000000041ca4d8a" <>
                          "90ca0affff9dfc4cb485e0b7a5d144ca28874beed10aa5d75f92d859f81aadc758ca6138c9fabfd20bb107a9" <>
                          "610d3cbab9ce85e8690011d28ec5894da31b0000000000000000000000000000000000000000000000000000" <>
                          "0000000000"
    @multicall3 "0xca11bde05977b3631167028862be2a173976ca11"

    setup do
      previous = System.get_env("BASE_RPC_URL")

      on_exit(fn ->
        if previous,
          do: System.put_env("BASE_RPC_URL", previous),
          else: System.delete_env("BASE_RPC_URL")
      end)
    end

    test "a deployed wallet's signature is its own answer on Base" do
      System.put_env(
        "BASE_RPC_URL",
        TestRpcServer.wallet_answers({true, TestRpcServer.erc1271_approval()}, self())
      )

      assert Ethereum.verify_signature(
               @deployed_wallet,
               @smart_message,
               @deployed_signature,
               8453
             ) ==
               {:ok, :erc1271}

      assert_received {:rpc_request, %{"method" => "eth_call", "params" => [call, "latest"]}}
      assert call["to"] == @multicall3
      assert [{wallet, true, check}] = aggregate3_calls(call["data"])
      assert wallet == String.downcase(@deployed_wallet)

      assert check ==
               RegentChain.Call.encode("isValidSignature(bytes32,bytes)", [
                 hex(Siwa.EvmPersonalSign.personal_hash(@smart_message)),
                 @deployed_signature
               ])
    end

    test "an undeployed wallet's factory call runs before its answer, in one read" do
      System.put_env(
        "BASE_RPC_URL",
        TestRpcServer.wallet_answers({true, TestRpcServer.erc1271_approval()}, self())
      )

      assert Ethereum.verify_signature(
               @undeployed_wallet,
               @smart_message,
               @undeployed_signature,
               8453
             ) ==
               {:ok, :erc6492}

      assert_received {:rpc_request, %{"params" => [call, "latest"]}}

      assert [{@undeployed_factory, true, _deploy}, {wallet, true, check}] =
               aggregate3_calls(call["data"])

      assert wallet == String.downcase(@undeployed_wallet)

      assert String.starts_with?(
               check,
               RegentChain.Call.selector("isValidSignature(bytes32,bytes)")
             )
    end

    test "any other answer from the wallet refuses the signature" do
      for answer <- [
            {false, TestRpcServer.erc1271_approval()},
            {true, <<0xFFFFFFFF::32, 0::224>>},
            {true, <<>>}
          ] do
        System.put_env("BASE_RPC_URL", TestRpcServer.wallet_answers(answer))

        assert Ethereum.verify_signature(
                 @deployed_wallet,
                 @smart_message,
                 @deployed_signature,
                 8453
               ) ==
                 {:error, :signature_invalid}
      end
    end

    test "an ordinary wallet's signature for another address asks Base, where no wallet answers" do
      System.put_env("BASE_RPC_URL", TestRpcServer.wallet_answers({true, <<>>}))

      assert Ethereum.verify_signature(
               @deployed_wallet,
               String.duplicate("a", 106),
               @signatures[106],
               8453
             ) ==
               {:error, :signature_invalid}
    end

    test "a broken ERC-6492 wrapper is refused without asking Base" do
      System.delete_env("BASE_RPC_URL")
      suffix_hex = String.duplicate("6492", 16)

      for signature <- ["0x" <> suffix_hex, "0x1234" <> suffix_hex] do
        assert Ethereum.verify_signature(@undeployed_wallet, @smart_message, signature, 8453) ==
                 {:error, :signature_invalid}
      end
    end

    test "Base being unreachable or unreadable is a failed lookup, not a refusal" do
      for rpc_url <- [
            TestRpcServer.rpc_error(),
            TestRpcServer.invalid_response(),
            TestRpcServer.chain_id(8453)
          ] do
        System.put_env("BASE_RPC_URL", rpc_url)

        assert {:error, {:lookup_failed, _reason}} =
                 Ethereum.verify_signature(
                   @deployed_wallet,
                   @smart_message,
                   @deployed_signature,
                   8453
                 )
      end

      System.delete_env("BASE_RPC_URL")

      assert Ethereum.verify_signature(
               @deployed_wallet,
               @smart_message,
               @deployed_signature,
               8453
             ) ==
               {:error, {:lookup_failed, "base rpc url is not configured"}}
    end

    test "a Base read slower than the server's time limit is a failed lookup" do
      Application.put_env(:siwa_server, :ethereum_rpc_timeout_ms, 50)
      on_exit(fn -> Application.delete_env(:siwa_server, :ethereum_rpc_timeout_ms) end)
      System.put_env("BASE_RPC_URL", TestRpcServer.timeout())

      assert Ethereum.verify_signature(
               @deployed_wallet,
               @smart_message,
               @deployed_signature,
               8453
             ) ==
               {:error, {:lookup_failed, "rpc request timed out"}}
    end
  end

  defp aggregate3_calls("0x" <> hex) do
    <<_selector::binary-size(4), arguments::binary>> = Base.decode16!(hex, case: :lower)
    [calls] = ABI.TypeDecoder.decode(arguments, [{:array, {:tuple, [:address, :bool, :bytes]}}])

    Enum.map(calls, fn {target, allow_failure, data} ->
      {hex(target), allow_failure, hex(data)}
    end)
  end

  defp hex(bytes), do: "0x" <> Base.encode16(bytes, case: :lower)
end
