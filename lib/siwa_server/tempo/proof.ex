defmodule SiwaServer.Tempo.Proof do
  @moduledoc """
  A Tempo zero-amount proof as the mppx payment library signs it: EIP-712 typed
  data `Proof(address account,string challengeId,string realm)` under the domain
  `{name: "MPP", version: "3", chainId}`, with no verifying contract and no salt.
  The payer is named `did:pkh:eip155:<chain id>:<address>`.

  Only Tempo mainnet (4217) and the Moderato testnet (42431) are taken.

  `verify/2` checks an ordinary secp256k1 key's signature, recovered here with no
  network call. Two things it does not do: an access key's signature (a Tempo
  keychain envelope) and a contract account's are refused, and it never reads the
  account's configurable-account commitment on the chain, which can retire an
  account's own key while its signatures still recover.
  """

  alias Siwa.EvmPersonalSign

  @chain_ids [4217, 42_431]
  @domain_type_hash ExKeccak.hash_256("EIP712Domain(string name,string version,uint256 chainId)")
  @name_hash ExKeccak.hash_256("MPP")
  @version_hash ExKeccak.hash_256("3")
  @proof_type_hash ExKeccak.hash_256("Proof(address account,string challengeId,string realm)")

  @enforce_keys [:chain_id, :account, :challenge_id, :realm]
  defstruct @enforce_keys

  @typedoc "Tempo mainnet or the Moderato testnet."
  @type chain_id :: 4217 | 42_431

  @typedoc "A proof's signed fields; `account` is the lowercase `0x` address."
  @type t :: %__MODULE__{
          chain_id: chain_id(),
          account: String.t(),
          challenge_id: String.t(),
          realm: String.t()
        }

  @doc """
  The proof of `account` for the challenge `challenge_id` from `realm` on
  `chain_id`. A chain other than the two Tempo chains is refused, and so is an
  account that is not a `0x` address of 40 hex digits.
  """
  @spec new(integer(), String.t(), String.t(), String.t()) ::
          {:ok, t()} | {:error, :chain_unsupported | :account_invalid}
  def new(chain_id, account, challenge_id, realm)
      when chain_id in @chain_ids and is_binary(challenge_id) and is_binary(realm) do
    with {:ok, account} <- account(account) do
      {:ok,
       %__MODULE__{chain_id: chain_id, account: account, challenge_id: challenge_id, realm: realm}}
    end
  end

  def new(chain_id, _account, challenge_id, realm)
      when is_integer(chain_id) and is_binary(challenge_id) and is_binary(realm),
      do: {:error, :chain_unsupported}

  @doc "The EIP-712 digest the payer signs, 32 bytes."
  @spec digest(t()) :: <<_::256>>
  def digest(%__MODULE__{chain_id: chain_id, account: "0x" <> account} = proof) do
    domain_separator =
      ExKeccak.hash_256(@domain_type_hash <> @name_hash <> @version_hash <> <<chain_id::256>>)

    struct_hash =
      ExKeccak.hash_256(
        @proof_type_hash <>
          <<0::96>> <>
          Base.decode16!(account, case: :lower) <>
          ExKeccak.hash_256(proof.challenge_id) <>
          ExKeccak.hash_256(proof.realm)
      )

    ExKeccak.hash_256(<<0x19, 0x01>> <> domain_separator <> struct_hash)
  end

  @doc """
  `:ok` when `signature` is the proof's account's own key signing `digest/1`:
  `0x` hex of r, s and a last byte of 0, 1, 27 or 28, the forms viem recovers.
  """
  @spec verify(t(), String.t()) :: :ok | {:error, :signature_invalid}
  def verify(%__MODULE__{account: account} = proof, signature) do
    with {:ok, <<_r_s::binary-size(64), v>>} when v in [0, 1, 27, 28] <-
           EvmPersonalSign.signature_bytes(signature),
         {:ok, ^account} <- EvmPersonalSign.recover_address(digest(proof), signature) do
      :ok
    else
      _other -> {:error, :signature_invalid}
    end
  end

  @doc "The payer's `did:pkh` subject, with the lowercase address."
  @spec subject(t()) :: String.t()
  def subject(%__MODULE__{chain_id: chain_id, account: account}),
    do: "did:pkh:eip155:#{chain_id}:#{account}"

  defp account("0x" <> hex = account) when byte_size(hex) == 40 do
    case Base.decode16(hex, case: :mixed) do
      {:ok, _bytes} -> {:ok, String.downcase(account)}
      :error -> {:error, :account_invalid}
    end
  end

  defp account(_account), do: {:error, :account_invalid}
end
