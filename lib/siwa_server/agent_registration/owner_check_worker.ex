defmodule SiwaServer.AgentRegistration.OwnerCheckWorker do
  @moduledoc """
  Keeps each registry listing's status to whether its wallet still owns the
  listing's token on Base. Oban's cron queues it every five minutes on the
  `chain` queue, and only one job exists at a time.

  Each token's owner is read with `ownerOf` at the latest block. The wallet
  owning it keeps or puts the listing back to `listed`; another owner, or a
  revert, ends it (`ended`): an ERC-721 `ownerOf` reverts only for a token
  that does not exist. A failed read, or an answer that is not an address,
  leaves that listing as it was with a warning, for the next run. A listing
  is never deleted.
  """

  use Oban.Worker,
    queue: :chain,
    max_attempts: 1,
    unique: [period: :infinity, states: :incomplete]

  import Ecto.Query

  require Logger

  alias RegentChain.Call
  alias SiwaServer.AgentRegistration.Record
  alias SiwaServer.{AgentRegistry, Ethereum, Repo, RuntimeConfig}

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    from(r in Record, select: {r.id, r.wallet_address, r.token_id})
    |> Repo.all()
    |> Enum.each(fn {id, wallet_address, token_id} ->
      case owner(token_id) do
        {:ok, ^wallet_address} ->
          set_status(id, :listed)

        {:ok, _other_or_none} ->
          set_status(id, :ended)

        {:error, reason} ->
          Logger.warning("registry owner check failed token_id=#{token_id} reason=#{reason}")
      end
    end)
  end

  defp owner(token_id) do
    call = %{
      to: AgentRegistry.address(),
      data: Call.encode("ownerOf(uint256)", [String.to_integer(token_id)])
    }

    case Ethereum.json_rpc(RuntimeConfig.base_rpc_url(), "eth_call", [call, "latest"]) do
      {:ok, answer} -> address(answer)
      {:error, "execution reverted" <> _reason} -> {:ok, :none}
      {:error, reason} -> {:error, reason}
    end
  end

  # An ABI-encoded address: twelve zero bytes, then the twenty address bytes.
  defp address("0x" <> word = answer) do
    case Base.decode16(word, case: :mixed) do
      {:ok, <<0::96, address::binary-20>>} -> {:ok, "0x" <> Base.encode16(address, case: :lower)}
      _other -> {:error, "the registry answered #{inspect(answer)}"}
    end
  end

  defp address(answer), do: {:error, "the registry answered #{inspect(answer)}"}

  defp set_status(id, status) do
    from(r in Record, where: r.id == ^id and r.status != ^status)
    |> Repo.update_all(set: [status: status, updated_at: DateTime.utc_now(:second)])
  end
end
