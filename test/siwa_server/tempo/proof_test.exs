defmodule SiwaServer.Tempo.ProofTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias SiwaServer.Tempo.Proof

  # Proofs signed by the mppx payment library's own client with the public Anvil
  # key 0; the fixture's note says how they were made.
  @fixture Path.expand("../../fixtures/tempo/mppx_proofs.json", __DIR__)
  @external_resource @fixture
  @fixture_data @fixture |> File.read!() |> Jason.decode!()
  @vectors @fixture_data["vectors"]
  @access_key_envelope @fixture_data["access_key_envelope"]["signature"]
  @other_account "0x70997970c51812dc3a010c7d01b50e0d17dc79c8"
  @secp256k1_n 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141

  for vector <- @vectors do
    describe "mppx proof on #{vector["name"]}" do
      @vector vector

      test "the digest is mppx's" do
        assert hex(Proof.digest(proof(@vector))) == @vector["digest"]
      end

      test "mppx's signature verifies, whatever the account's letter case" do
        lowercase = %{"account" => String.downcase(@vector["account"])}

        assert Proof.verify(proof(@vector), @vector["signature"]) == :ok
        assert Proof.verify(proof(@vector, lowercase), @vector["signature"]) == :ok
      end

      test "the signature holds for no other challenge, realm, chain or account" do
        other_chain = if @vector["chain_id"] == 4217, do: 42_431, else: 4217

        for changes <- [
              %{"challenge_id" => @vector["challenge_id"] <> "A"},
              %{"realm" => @vector["realm"] <> "."},
              %{"chain_id" => other_chain},
              %{"account" => @other_account}
            ] do
          assert Proof.verify(proof(@vector, changes), @vector["signature"]) ==
                   {:error, :signature_invalid},
                 "verified with #{inspect(changes)}"
        end
      end

      test "the subject is mppx's source with the address in lowercase" do
        assert Proof.subject(proof(@vector)) == String.downcase(@vector["source"])
      end
    end
  end

  property "a signature holds only for the challenge id and realm it was made for" do
    [vector | _] = @vectors

    check all challenge_id <- string(:printable),
              realm <- string(:printable),
              {challenge_id, realm} != {vector["challenge_id"], vector["realm"]} do
      changed = proof(vector, %{"challenge_id" => challenge_id, "realm" => realm})
      assert Proof.verify(changed, vector["signature"]) == {:error, :signature_invalid}
    end
  end

  test "a malformed signature is refused" do
    [vector | _] = @vectors
    proof = proof(vector)
    "0x" <> signature_hex = vector["signature"]
    bytes = Base.decode16!(signature_hex, case: :mixed)
    <<r_first, rest::binary>> = bytes
    <<r_and_s::binary-size(64), _v>> = bytes

    for signature <- [
          "",
          "0x",
          signature_hex,
          String.slice(vector["signature"], 0..-3//1),
          vector["signature"] <> "00",
          "0x" <> String.duplicate("zz", 65),
          hex(<<r_and_s::binary, 0x1D>>),
          hex(<<Bitwise.bxor(r_first, 1), rest::binary>>),
          hex(<<0::520>>),
          nil
        ] do
      assert Proof.verify(proof, signature) == {:error, :signature_invalid},
             "accepted #{inspect(signature)}"
    end
  end

  # viem, which checks proofs for mppx, recovers a last byte of 0, 1, 27 or 28
  # and refuses 35 and above. It also recovers the high-s twin, which is refused
  # here: no viem signer makes one.
  test "a copy of mppx's signature verifies only in the forms viem reads, with low s" do
    for vector <- @vectors do
      proof = proof(vector)
      "0x" <> signature_hex = vector["signature"]
      <<r::binary-size(32), s::256, v>> = Base.decode16!(signature_hex, case: :mixed)

      assert Proof.verify(proof, hex(<<r::binary, s::256, v - 27>>)) == :ok

      for signature <- [
            hex(<<r::binary, s::256, v + 8>>),
            hex(<<r::binary, s::256, v + 10>>),
            hex(<<r::binary, @secp256k1_n - s::256, 55 - v>>)
          ] do
        assert Proof.verify(proof, signature) == {:error, :signature_invalid},
               "accepted #{signature}"
      end
    end
  end

  test "an access key's keychain envelope is refused" do
    [vector | _] = @vectors

    assert Proof.verify(proof(vector), @access_key_envelope) == {:error, :signature_invalid}
  end

  property "a chain other than Tempo mainnet and Moderato is refused" do
    [vector | _] = @vectors

    check all chain_id <- one_of([integer(), member_of([0, 1, 8453, 4216, 4218, 42_430, 42_432])]),
              chain_id not in [4217, 42_431] do
      assert Proof.new(chain_id, vector["account"], vector["challenge_id"], vector["realm"]) ==
               {:error, :chain_unsupported}
    end
  end

  test "an account that is not a 0x address of 40 hex digits is refused" do
    "0x" <> digits = @other_account

    for account <- [
          "",
          digits,
          "0x" <> String.slice(digits, 1..-1//1),
          @other_account <> "0",
          "0x" <> String.duplicate("g", 40),
          " " <> @other_account
        ] do
      assert Proof.new(4217, account, "challenge", "realm") == {:error, :account_invalid},
             "accepted #{inspect(account)}"
    end
  end

  defp proof(vector, changes \\ %{}) do
    fields = Map.merge(vector, changes)

    {:ok, proof} =
      Proof.new(fields["chain_id"], fields["account"], fields["challenge_id"], fields["realm"])

    proof
  end

  defp hex(bytes), do: "0x" <> Base.encode16(bytes, case: :lower)
end
