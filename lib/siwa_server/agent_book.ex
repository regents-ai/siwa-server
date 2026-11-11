defmodule SiwaServer.AgentBook do
  @moduledoc """
  World's AgentBook on World Chain records which agent wallets a World
  ID-verified person stands behind, under that person's anonymous number (the
  World ID nullifier hash). The person registers their agent there with World's
  own tool; this server only reads it.

  AgentBook takes no signature from the agent's wallet, so anyone with a World
  ID can put their number on any wallet, or replace the number already there.
  The wallet therefore accepts its number: `challenge/1` reads AgentBook and
  gives the wallet a single-use message naming that number, and `accept/1`
  keeps the number once the wallet has signed it and AgentBook still names it.

  Accepting is once and for good. Sites receive the accepted person with every
  verified request (`human/1`), whatever AgentBook names later, with how many
  agent wallets accepted the same person; a wallet that has accepted cannot
  accept another. Each acceptance is a row of `agent_book_acceptances`, keyed
  by the wallet, that the database refuses to change.
  """

  use Ecto.Schema

  import Ecto.Query

  alias RegentChain.Call
  alias SiwaServer.{Config, Ethereum, Repo}
  alias SiwaServer.Siwa.Challenge

  @chain_id 480
  @address "0xa23ab2712ea7bba896930544c7d6636a96b944da"
  @audience "agent-book"
  @challenge_fields [:wallet_address, :chain_id]
  @accept_fields @challenge_fields ++ [:nonce, :message, :signature]

  @primary_key {:wallet_address, :string, autogenerate: false}

  schema "agent_book_acceptances" do
    field :human_id, :string

    timestamps(type: :utc_datetime)
  end

  @type error :: {:error, {pos_integer(), String.t(), String.t()}}

  @doc "World Chain's chain id."
  @spec chain_id() :: pos_integer()
  def chain_id, do: @chain_id

  @doc "AgentBook's address on World Chain, in lower case."
  @spec address() :: String.t()
  def address, do: @address

  @doc """
  The person the wallet accepted, with how many agent wallets accepted the
  same person; or nil.
  """
  @spec human(String.t()) :: %{String.t() => String.t() | pos_integer()} | nil
  def human(wallet_address) do
    case Repo.get(__MODULE__, String.downcase(wallet_address)) do
      nil ->
        nil

      %__MODULE__{human_id: human_id} ->
        %{
          "humanId" => human_id,
          "agentCount" =>
            Repo.aggregate(from(a in __MODULE__, where: a.human_id == ^human_id), :count)
        }
    end
  end

  @doc """
  A single-use message, valid for the sign-in challenge lifetime, for a
  wallet that has not accepted a person yet to sign to accept the person
  AgentBook names behind it now.
  """
  @spec challenge(map()) :: {:ok, map()} | error()
  def challenge(params) do
    with {:ok, request} <- request(params, @challenge_fields),
         :ok <- unaccepted(request.wallet_address),
         {:ok, human_id} <- named(request.wallet_address) do
      challenge =
        Challenge.issue(
          scope(request),
          %{address: request.wallet_address, chain_id: request.chain_id, audience: @audience},
          &message(human_id, &1)
        )

      {:ok,
       %{
         "code" => "agent_book_challenge",
         "data" => %{
           "walletAddress" => challenge.address,
           "chainId" => challenge.chain_id,
           "humanId" => human_id,
           "nonce" => challenge.nonce,
           "message" => challenge.canonical_message,
           "issuedAt" => DateTime.to_iso8601(challenge.issued_at),
           "expiresAt" => DateTime.to_iso8601(challenge.expiration_time)
         }
       }}
    end
  end

  @doc """
  Keeps the person the wallet signed for, for good, once the signature holds,
  the challenge is unused and AgentBook still names that person.
  """
  @spec accept(map()) :: {:ok, map()} | error()
  def accept(params) do
    with {:ok, request} <- request(params, @accept_fields),
         {:ok, challenge} <- Challenge.fetch(scope(request), request.nonce),
         :ok <- Challenge.current(challenge, request.message),
         :ok <- unaccepted(challenge.address),
         {:ok, human_id} <- named(challenge.address),
         :ok <- unchanged(challenge, human_id),
         {:ok, _method} <- Challenge.signed(challenge, request.message, request.signature),
         {:ok, _acceptance} <- keep(challenge, human_id) do
      {:ok,
       %{
         "code" => "agent_book_accepted",
         "data" => %{"walletAddress" => challenge.address, "humanId" => human_id}
       }}
    else
      {:error, %Ecto.Changeset{}} ->
        already_accepted()

      {:error, {_status, _code, _message}} = error ->
        error
    end
  end

  defp lookup(wallet_address) do
    call = %{to: @address, data: Call.encode("lookupHuman(address)", [wallet_address])}

    case Ethereum.json_rpc(Config.world_rpc_url(), "eth_call", [call, "latest"]) do
      {:ok, "0x" <> word} when byte_size(word) == 64 -> {:ok, String.to_integer(word, 16)}
      {:ok, answer} -> {:error, "AgentBook answered #{inspect(answer)}"}
      {:error, reason} -> {:error, reason}
    end
  end

  # The person AgentBook names behind the wallet now, as a person number.
  defp named(wallet_address) do
    case lookup(wallet_address) do
      {:ok, 0} ->
        {:error,
         {404, "not_in_agent_book", "World's AgentBook names no person behind this wallet yet"}}

      {:ok, human_id} ->
        {:ok, number(human_id)}

      {:error, _reason} ->
        {:error,
         {502, "agent_book_unavailable", "could not read World's AgentBook on World Chain"}}
    end
  end

  defp unaccepted(wallet_address) do
    if Repo.exists?(from a in __MODULE__, where: a.wallet_address == ^wallet_address),
      do: already_accepted(),
      else: :ok
  end

  defp already_accepted,
    do:
      {:error,
       {409, "agent_book_already_accepted",
        "this wallet has already accepted its World ID person, for good"}}

  # The challenge named the person AgentBook named then; AgentBook must still name them.
  defp unchanged(challenge, human_id) do
    if message(human_id, challenge) == challenge.canonical_message,
      do: :ok,
      else:
        {:error,
         {409, "agent_book_changed",
          "World's AgentBook names a different person behind this wallet than the challenge did"}}
  end

  # Uses the challenge up and keeps the person. The wallet's row is unique, so
  # a second acceptance fails here even when two challenges raced.
  defp keep(challenge, human_id) do
    Repo.transact(fn ->
      with :ok <- Challenge.consume(challenge) do
        %__MODULE__{wallet_address: challenge.address, human_id: human_id}
        |> Ecto.Changeset.change()
        |> Ecto.Changeset.unique_constraint(:wallet_address, name: :agent_book_acceptances_pkey)
        |> Repo.insert()
      end
    end)
  end

  defp request(params, fields) do
    case Challenge.cast(params, fields) do
      {:ok, request} ->
        {:ok, request}

      :error ->
        {:error, {400, "invalid_request", "request body does not match the AgentBook contract"}}
    end
  end

  defp scope(request), do: [@audience, request.chain_id, request.wallet_address]

  defp message(human_id, challenge) do
    Enum.join(
      [
        "Accept a World ID person for this agent wallet on Regent sites",
        "",
        "Wallet: #{challenge.address}",
        "Person: #{human_id}",
        "",
        "World's AgentBook names this person behind the wallet. Regent sites show",
        "this person behind the wallet for good; it cannot accept another.",
        "",
        "Chain ID: #{challenge.chain_id}",
        "Nonce: #{challenge.nonce}",
        "Issued At: #{DateTime.to_iso8601(challenge.issued_at)}",
        "Expiration Time: #{DateTime.to_iso8601(challenge.expiration_time)}"
      ],
      "\n"
    )
  end

  defp number(human_id),
    do:
      "0x" <>
        (human_id |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(64, "0"))
end
