defmodule SiwaServer.AgentRegistration.OwnerCheckWorker do
  @moduledoc """
  Keeps each registry listing's status to whether its wallet still owns the
  listing's token on Base. Oban's cron queues it every five minutes on the
  `chain` queue, and only one job exists at a time.

  Each token's owner is read with `ownerOf` at the latest block. The wallet
  owning it keeps or puts the listing back to `listed`; another owner, or a
  revert, ends it (`ended`): an ERC-721 `ownerOf` reverts only for a token
  that does not exist. Any other failed read ends the run with a warning and
  leaves that listing and the ones after it to the next run. A listing is
  never deleted.
  """

  use Oban.Worker,
    queue: :chain,
    max_attempts: 1,
    unique: [period: :infinity, states: :incomplete]

  import Ecto.Query

  require Logger

  alias RegentChain.Call
  alias SiwaServer.AgentRegistration.Record
  alias SiwaServer.{AgentRegistry, Config, Ethereum, Repo}

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    from(r in Record, select: {r.id, r.wallet_address, r.token_id})
    |> Repo.all()
    |> Enum.reduce_while(:ok, fn {id, wallet_address, token_id}, :ok ->
      case owner(token_id) do
        {:ok, ^wallet_address} ->
          set_status(id, :listed)
          {:cont, :ok}

        {:ok, _other_or_none} ->
          set_status(id, :ended)
          {:cont, :ok}

        {:error, reason} ->
          Logger.warning("registry owner check stopped token_id=#{token_id} reason=#{reason}")
          {:halt, :ok}
      end
    end)
  end

  defp owner(token_id) do
    call = %{
      to: AgentRegistry.address(),
      data: Call.encode("ownerOf(uint256)", [String.to_integer(token_id)])
    }

    case Ethereum.json_rpc(Config.base_rpc_url(), "eth_call", [call, "latest"]) do
      {:ok, "0x" <> word} when byte_size(word) == 64 ->
        {:ok, "0x" <> String.downcase(binary_part(word, 24, 40))}

      {:ok, answer} ->
        {:error, "the registry answered #{inspect(answer)}"}

      {:error, "execution reverted" <> _reason} ->
        {:ok, :none}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp set_status(id, status) do
    from(r in Record, where: r.id == ^id and r.status != ^status)
    |> Repo.update_all(set: [status: status, updated_at: DateTime.utc_now(:second)])
  end
end
