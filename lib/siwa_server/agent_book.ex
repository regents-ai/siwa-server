defmodule SiwaServer.AgentBook do
  @moduledoc """
  World's AgentBook on World Chain records which agent wallets a World
  ID-verified person stands behind, under that person's anonymous number (the
  World ID nullifier hash). The person registers their agent there with World's
  own tool; this server only reads it.

  AgentBook takes no signature from the agent's wallet, so anyone with a World
  ID can put their number on any wallet, or replace the number already there.
  The wallet therefore accepts its number once: `challenge/1` reads AgentBook
  and gives the wallet a single-use message naming that number, and `accept/1`
  keeps the number once the wallet has signed it and AgentBook still names it.

  Each sign-in queues `SiwaServer.AgentBook.Refresh`, which reads the wallet's
  entry and saves it. Sites receive the person with every verified request
  (`human/1`) only while AgentBook still names the number the wallet accepted,
  with how many agent wallets the same person stands behind on those terms,
  and each site decides when to show the person number.
  """

  import Ecto.Query

  alias RegentChain.Call
  alias SiwaServer.AgentBook.{Acceptance, Human}
  alias SiwaServer.{Ethereum, Repo, RuntimeConfig}
  alias SiwaServer.Siwa.NonceStore

  @chain_id 480
  @address "0xa23ab2712ea7bba896930544c7d6636a96b944da"
  @audience "agent-book"
  @challenge_fields ~w(wallet_address chain_id)
  @accept_fields @challenge_fields ++ ~w(nonce message signature)

  @type error :: {:error, {pos_integer(), String.t(), String.t()}}

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

  @doc """
  The person AgentBook last named for the wallet, when the wallet accepted
  that same person, with how many agent wallets stand on that footing for
  the same person; or nil.
  """
  @spec human(String.t()) :: %{String.t() => String.t() | pos_integer()} | nil
  def human(wallet_address) do
    from(h in accepted(), where: h.wallet_address == ^String.downcase(wallet_address))
    |> select([h], h.human_id)
    |> Repo.one()
    |> case do
      nil ->
        nil

      human_id ->
        %{
          "humanId" => human_id,
          "agentCount" =>
            Repo.aggregate(from(h in accepted(), where: h.human_id == ^human_id), :count)
        }
    end
  end

  # Wallets whose last AgentBook answer is the person they accepted.
  defp accepted,
    do:
      from(h in Human,
        join: a in Acceptance,
        on: a.wallet_address == h.wallet_address and a.human_id == h.human_id
      )

  @doc """
  A single-use message, valid for the sign-in challenge lifetime, for the
  wallet to sign to accept the person AgentBook names behind it now.
  """
  @spec challenge(map()) :: {:ok, map()} | error()
  def challenge(params) do
    with {:ok, fields} <- validate(params, @challenge_fields),
         {:ok, human_id} <- named(fields["wallet_address"]) do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      expires = DateTime.add(now, RuntimeConfig.siwa_nonce_ttl_seconds())
      nonce = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
      message = message(fields, human_id, nonce, now, expires)

      attrs = %{
        nonce_key: nonce_key(fields),
        nonce: nonce,
        address: fields["wallet_address"],
        chain_id: fields["chain_id"],
        audience: @audience,
        issued_at: now,
        expiration_time: expires,
        canonical_message: message
      }

      {:ok, _record} = NonceStore.put(attrs)

      {:ok,
       %{
         "code" => "agent_book_challenge",
         "data" => %{
           "walletAddress" => fields["wallet_address"],
           "chainId" => fields["chain_id"],
           "humanId" => human_id,
           "accepted" => accepted?(fields["wallet_address"], human_id),
           "nonce" => nonce,
           "message" => message,
           "issuedAt" => DateTime.to_iso8601(now),
           "expiresAt" => DateTime.to_iso8601(expires)
         }
       }}
    end
  end

  @doc """
  Keeps the person the wallet signed for, once the signature holds, the
  challenge is unused and AgentBook still names that person.
  """
  @spec accept(map()) :: {:ok, map()} | error()
  def accept(params) do
    with {:ok, fields} <- validate(params, @accept_fields),
         {:ok, record} <- NonceStore.get(nonce_key(fields), fields["nonce"]),
         :ok <- current(fields, record),
         {:ok, human_id} <- named(record.address),
         :ok <- unchanged(fields, record, human_id),
         :ok <- signed(record, fields),
         {:ok, _acceptance} <- keep(record, human_id) do
      {:ok,
       %{
         "code" => "agent_book_accepted",
         "data" => %{"walletAddress" => record.address, "humanId" => human_id}
       }}
    else
      {:error, :unknown_nonce} ->
        {:error, {404, "nonce_not_found", "challenge absent, expired or consumed"}}

      {:error, {_status, _code, _message}} = error ->
        error
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

  defp save(wallet_address, 0) do
    Repo.delete_all(Human.for_wallet(wallet_address))
    :ok
  end

  defp save(wallet_address, human_id) when is_integer(human_id),
    do: save(wallet_address, number(human_id))

  defp save(wallet_address, human_id) when is_binary(human_id) do
    Repo.insert!(
      Human.changeset(%{wallet_address: wallet_address, human_id: human_id}),
      on_conflict: {:replace, [:human_id, :updated_at]},
      conflict_target: :wallet_address
    )

    :ok
  end

  defp accepted?(wallet_address, human_id),
    do:
      Repo.exists?(
        from a in Acceptance,
          where: a.wallet_address == ^wallet_address and a.human_id == ^human_id
      )

  defp current(fields, record) do
    cond do
      DateTime.compare(record.expiration_time, DateTime.utc_now()) != :gt ->
        {:error, {401, "nonce_expired", "the challenge has expired"}}

      fields["message"] != record.canonical_message ->
        {:error, {401, "message_invalid", "sign the exact current server-issued challenge"}}

      true ->
        :ok
    end
  end

  # The challenge named the person AgentBook named then; AgentBook must still name them.
  defp unchanged(fields, record, human_id) do
    if message(fields, human_id, record.nonce, record.issued_at, record.expiration_time) ==
         record.canonical_message,
       do: :ok,
       else:
         {:error,
          {409, "agent_book_changed",
           "World's AgentBook names a different person behind this wallet than the challenge did"}}
  end

  defp signed(record, fields) do
    case Ethereum.verify_signature(
           record.address,
           fields["message"],
           fields["signature"],
           record.chain_id
         ) do
      {:ok, _method} ->
        :ok

      {:error, :signature_invalid} ->
        {:error, {401, "signature_invalid", "signature does not match wallet"}}

      {:error, {:lookup_failed, reason}} ->
        {:error,
         {502, "signature_lookup_failed",
          "could not check the wallet signature on #{Ethereum.chain_name(record.chain_id)}: #{reason}"}}
    end
  end

  # Uses the challenge up and keeps the person, with what AgentBook names now.
  defp keep(record, human_id) do
    Repo.transact(fn ->
      with :ok <- NonceStore.consume(record),
           :ok <- save(record.address, human_id) do
        {:ok,
         Repo.insert!(
           Acceptance.changeset(%{wallet_address: record.address, human_id: human_id}),
           on_conflict: {:replace, [:human_id, :updated_at]},
           conflict_target: :wallet_address
         )}
      end
    end)
  end

  defp validate(params, allowed) when is_map(params) do
    with true <- Enum.sort(Map.keys(params)) == Enum.sort(allowed),
         true <- params["chain_id"] in Ethereum.wallet_chain_ids(),
         address when is_binary(address) <- params["wallet_address"],
         true <- Regex.match?(~r/^0x[0-9a-fA-F]{40}$/, address),
         true <- valid_proof_fields?(params) do
      {:ok, Map.put(params, "wallet_address", String.downcase(address))}
    else
      _ -> invalid_request()
    end
  end

  defp validate(_params, _allowed), do: invalid_request()

  defp valid_proof_fields?(%{"message" => message, "nonce" => nonce, "signature" => signature})
       when is_binary(message) and byte_size(message) in 1..2048 and is_binary(nonce) and
              is_binary(signature),
       do:
         Regex.match?(~r/^[a-f0-9]{32}$/, nonce) and
           byte_size(signature) <= 2 + 2 * Siwa.WalletSignature.max_bytes() and
           Regex.match?(~r/^0x(?:[0-9a-fA-F]{2})+$/, signature)

  defp valid_proof_fields?(params), do: not Map.has_key?(params, "message")

  defp invalid_request,
    do: {:error, {400, "invalid_request", "request body does not match the AgentBook contract"}}

  defp nonce_key(fields) do
    digest =
      :crypto.hash(
        :sha256,
        Jason.encode!([@audience, fields["chain_id"], fields["wallet_address"]])
      )

    "#{@audience}:" <> Base.encode16(digest, case: :lower)
  end

  defp message(fields, human_id, nonce, issued, expires) do
    Enum.join(
      [
        "Accept a World ID person for this agent wallet on Regent sites",
        "",
        "Wallet: #{fields["wallet_address"]}",
        "Person: #{human_id}",
        "",
        "World's AgentBook names this person behind the wallet. Regent sites show",
        "them only while AgentBook still names this person.",
        "",
        "Chain ID: #{fields["chain_id"]}",
        "Nonce: #{nonce}",
        "Issued At: #{DateTime.to_iso8601(issued)}",
        "Expiration Time: #{DateTime.to_iso8601(expires)}"
      ],
      "\n"
    )
  end

  defp number(human_id),
    do:
      "0x" <>
        (human_id |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(64, "0"))
end
