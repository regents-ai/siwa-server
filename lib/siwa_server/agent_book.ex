defmodule SiwaServer.AgentBook do
  @moduledoc """
  World's AgentBook on World Chain records which agent wallets a World
  ID-verified person stands behind, under that person's anonymous number (the
  World ID nullifier hash). The person registers their agent there with World's
  own tool; this server only reads it.

  Each sign-in queues `SiwaServer.AgentBook.Refresh`, which reads the wallet's
  entry and saves it. Sites receive the saved entry with every verified request
  (`human/1`) and each site decides when to show the person number.
  """

  alias RegentChain.Call
  alias SiwaServer.AgentBook.Human
  alias SiwaServer.{Ethereum, Repo, RuntimeConfig}

  @chain_id 480
  @address "0xa23ab2712ea7bba896930544c7d6636a96b944da"

  @doc "World Chain's chain id."
  @spec chain_id() :: pos_integer()
  def chain_id, do: @chain_id

  @doc "AgentBook's address on World Chain, in lower case."
  @spec address() :: String.t()
  def address, do: @address

  @doc "Reads the wallet's AgentBook entry at the latest World Chain block and saves it."
  @spec refresh(String.t()) :: :ok | {:error, String.t()}
  def refresh(wallet_address) do
    wallet_address = String.downcase(wallet_address)

    with {:ok, human_id} <- lookup(wallet_address) do
      save(wallet_address, human_id)
    end
  end

  @doc "The person AgentBook last named for the wallet, or nil."
  @spec human(String.t()) :: %{String.t() => String.t()} | nil
  def human(wallet_address) do
    case Repo.get(Human, String.downcase(wallet_address)) do
      nil -> nil
      human -> %{"humanId" => human.human_id}
    end
  end

  defp lookup(wallet_address) do
    call = %{to: @address, data: Call.encode("lookupHuman(address)", [wallet_address])}

    case Ethereum.json_rpc(RuntimeConfig.world_rpc_url(), "eth_call", [call, "latest"]) do
      {:ok, "0x" <> word} when byte_size(word) == 64 -> {:ok, String.to_integer(word, 16)}
      {:ok, answer} -> {:error, "AgentBook answered #{inspect(answer)}"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp save(wallet_address, 0) do
    Repo.delete_all(Human.for_wallet(wallet_address))
    :ok
  end

  defp save(wallet_address, human_id) do
    Repo.insert!(
      Human.changeset(%{wallet_address: wallet_address, human_id: number(human_id)}),
      on_conflict: {:replace, [:human_id, :updated_at]},
      conflict_target: :wallet_address
    )

    :ok
  end

  defp number(human_id),
    do:
      "0x" <>
        (human_id |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(64, "0"))
end
