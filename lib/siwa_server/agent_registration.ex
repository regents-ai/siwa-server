defmodule SiwaServer.AgentRegistration do
  @moduledoc """
  An agent may list itself in the Base ERC-8004 agent registry. Listing is
  optional and changes nothing about sign-in. The agent pays the gas from its
  own wallet; this server never sends or funds a transaction.

    1. `step/1` builds the one transaction, `register(agentURI)`. The URI is
       the agent's public profile on this server, and it names a digest of the
       profile (wallet, name, description, image), so the transaction the
       wallet signs is also its consent to exactly that profile.
    2. `outcome/1` reads that transaction at the latest Base block. It is
       `registration_pending` until the receipt exists. Once it lands it is
       `agent_registered`, with the token the registry minted to the wallet,
       and the registration is kept so the profile is served; or it is
       `registration_reverted`. A hash whose sender, target or calldata is not
       this step's is no answer about it.
    3. `profile/1` is the registration file served at the URI.

  An agent listed by any other tool links its listing instead, in two steps.
  `link_challenge/1` reads the registry at the latest Base block and, when it
  names the wallet as the agent's owner (`ownerOf`) or its agent wallet
  (`getAgentWallet`), issues a single-use message naming the wallet and the
  agent. `link/1` keeps the link once the wallet has signed that message and
  the registry, read again, still names the wallet. The signature is the
  wallet's consent: anyone can send a listing to any wallet, but only the
  wallet can link it. The listing's profile is its own `tokenURI` when that is
  an `https://` or `ipfs://` address; a listing with no profile address, or
  with its profile written into itself (`data:`), links with none.

  `latest/1` is the listing the wallet registered or linked last, for sites to
  link to.
  """

  import Ecto.Query

  alias RegentChain.{Abi, Address, Call, Outcome, Review}
  alias SiwaServer.AgentRegistration.{Link, Record}
  alias SiwaServer.{AgentRegistry, Ethereum, Repo, RuntimeConfig, Text, WalletChallenge}
  alias SiwaServer.Siwa.NonceStore

  @transfer_topic "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
  @zero_topic "0x" <> String.duplicate("0", 64)
  @registration_type "https://eips.ethereum.org/EIPS/eip-8004#registration-v1"
  @zero_address "0x" <> String.duplicate("0", 40)
  @link_audience "agent-link"

  @type profile :: %{
          wallet_address: String.t(),
          name: String.t(),
          description: String.t(),
          image: String.t() | nil
        }
  @type error :: {:error, {pos_integer(), String.t(), String.t()}}

  @doc "The unsigned registration transaction for the profile's wallet to send on Base."
  @spec step(profile()) :: {:ok, map()}
  def step(profile) do
    uri = agent_uri(profile)
    %{to: to, data: data, value: value} = register_step(uri)

    {:ok,
     %{
       "code" => "registration_step",
       "data" => %{
         "chainId" => AgentRegistry.chain_id(),
         "from" => Address.normalize!(profile.wallet_address),
         "to" => to,
         "data" => data,
         "value" => value,
         "agentUri" => uri
       }
     }}
  end

  @doc "What the registration sent as `tx_hash` did, read at the latest Base block."
  @spec outcome(%{
          wallet_address: String.t(),
          name: String.t(),
          description: String.t(),
          image: String.t() | nil,
          tx_hash: String.t()
        }) :: {:ok, map()} | error()
  def outcome(%{tx_hash: tx_hash} = request) do
    hash = String.downcase(tx_hash)
    wallet_address = request.wallet_address

    with {:ok, chain} <- base_chain(),
         review =
           Review.new("agent-registration", wallet_address, chain, [
             register_step(agent_uri(request))
           ]),
         {:ok, status} <- Outcome.of(__MODULE__, review, hd(review.steps), hash) do
      result(status, chain, request, hash)
    else
      {:error, :not_this_step} ->
        {:error,
         {422, "transaction_not_registration",
          "that transaction is not this wallet's registration of this profile in the Base agent registry"}}

      {:error, {_status, _code, _message}} = error ->
        error

      {:error, reason} ->
        lookup_failed(reason)
    end
  end

  @doc "The ERC-8004 registration file for `profile_id`, once a registration of it has landed."
  @spec profile(String.t()) :: {:ok, map()} | :error
  def profile(profile_id) do
    case Repo.all(
           from r in Record, where: r.profile_id == ^profile_id, order_by: [asc: r.inserted_at]
         ) do
      [] ->
        :error

      [record | _more] = records ->
        {:ok,
         %{
           "type" => @registration_type,
           "name" => record.name,
           "description" => record.description,
           "image" => record.image || "",
           "services" => [],
           "x402Support" => false,
           "active" => true,
           "registrations" =>
             Enum.map(records, fn record ->
               %{
                 "agentId" => String.to_integer(record.token_id),
                 "agentRegistry" => agent_registry()
               }
             end)
         }}
    end
  end

  @doc """
  A single-use message, valid for the sign-in challenge lifetime, for the
  wallet to sign to link agent `token_id`, once the Base registry names the
  wallet as that agent's owner or agent wallet.
  """
  @spec link_challenge(%{
          wallet_address: String.t(),
          chain_id: pos_integer(),
          token_id: String.t()
        }) :: {:ok, map()} | error()
  def link_challenge(%{wallet_address: wallet_address, chain_id: chain_id, token_id: token_id}) do
    wallet_address = Address.normalize!(wallet_address)

    with {:ok, chain} <- base_chain(),
         :ok <- named(chain, wallet_address, token_id) do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      expires = DateTime.add(now, RuntimeConfig.siwa_nonce_ttl_seconds())
      nonce = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
      message = link_message(wallet_address, chain_id, token_id, nonce, now, expires)

      {:ok, _record} =
        NonceStore.put(%{
          nonce_key: link_nonce_key(wallet_address, chain_id),
          nonce: nonce,
          address: wallet_address,
          chain_id: chain_id,
          audience: @link_audience,
          issued_at: now,
          expiration_time: expires,
          canonical_message: message
        })

      {:ok,
       %{
         "code" => "agent_link_challenge",
         "data" => %{
           "walletAddress" => wallet_address,
           "chainId" => chain_id,
           "tokenId" => token_id,
           "nonce" => nonce,
           "message" => message,
           "issuedAt" => DateTime.to_iso8601(now),
           "expiresAt" => DateTime.to_iso8601(expires)
         }
       }}
    end
  end

  @doc """
  Links the wallet to agent `token_id` once the wallet has signed the unused
  message `link_challenge/1` issued for that agent and the Base registry still
  names the wallet as the agent's owner or agent wallet.
  """
  @spec link(%{
          wallet_address: String.t(),
          chain_id: pos_integer(),
          token_id: String.t(),
          nonce: String.t(),
          message: String.t(),
          signature: String.t()
        }) :: {:ok, map()} | error()
  def link(%{wallet_address: wallet_address, chain_id: chain_id, token_id: token_id} = request) do
    wallet_address = Address.normalize!(wallet_address)

    with {:ok, record} <- NonceStore.get(link_nonce_key(wallet_address, chain_id), request.nonce),
         :ok <- WalletChallenge.current(record, request.message),
         :ok <- same_agent(record, token_id),
         :ok <- WalletChallenge.signed(record, request.message, request.signature),
         {:ok, chain} <- base_chain(),
         :ok <- named(chain, wallet_address, token_id),
         {:ok, token_uri} <- read(chain, "tokenURI(uint256)", token_id, :bytes),
         profile_url = profile_address(token_uri),
         {:ok, _link} <- consume_and_link(record, token_id, profile_url) do
      {:ok,
       %{
         "code" => "agent_linked",
         "data" =>
           Map.merge(registration(token_id, profile_url), %{
             "walletAddress" => wallet_address,
             "chainId" => AgentRegistry.chain_id(),
             "registryAddress" => AgentRegistry.address()
           })
       }}
    else
      {:error, :unknown_nonce} ->
        {:error, {404, "nonce_not_found", "challenge absent, expired or consumed"}}

      {:error, {_status, _code, _message}} = error ->
        error
    end
  end

  @doc "The listing the wallet registered through this server or linked last, or nil."
  @spec latest(String.t()) :: map() | nil
  def latest(wallet_address) do
    case Repo.get(Link, String.downcase(wallet_address)) do
      nil -> nil
      link -> registration(link.token_id, link.profile_url)
    end
  end

  @doc false
  def transaction(chain, hash),
    do: Ethereum.json_rpc(chain.rpc_url, "eth_getTransactionByHash", [hash])

  @doc false
  def receipt(chain, hash),
    do: Ethereum.json_rpc(chain.rpc_url, "eth_getTransactionReceipt", [hash])

  defp result(:pending, _chain, _request, hash),
    do: {:ok, %{"code" => "registration_pending", "data" => %{"txHash" => hash}}}

  defp result(:reverted, _chain, _request, _hash),
    do:
      {:error,
       {422, "registration_reverted",
        "the registration transaction reverted, so no agent was minted"}}

  defp result(:confirmed, chain, request, hash) do
    wallet_address = Address.normalize!(request.wallet_address)

    with {:ok, receipt} when is_map(receipt) <- receipt(chain, hash),
         {:ok, token_id} <- minted_token_id(receipt, wallet_address) do
      profile_id = profile_id(request)
      profile_url = profile_url(profile_id)
      now = DateTime.utc_now(:second)

      {:ok, _link} =
        keep_registration(
          %{
            id: Ecto.UUID.generate(),
            profile_id: profile_id,
            wallet_address: wallet_address,
            name: request.name,
            description: request.description,
            image: request.image,
            token_id: token_id,
            tx_hash: hash,
            inserted_at: now,
            updated_at: now
          },
          profile_url
        )

      {:ok,
       %{
         "code" => "agent_registered",
         "data" =>
           Map.merge(registration(token_id, profile_url), %{
             "txHash" => hash,
             "walletAddress" => wallet_address,
             "chainId" => AgentRegistry.chain_id(),
             "registryAddress" => AgentRegistry.address()
           })
       }}
    else
      {:ok, nil} -> lookup_failed("receipt disappeared")
      {:error, reason} -> lookup_failed(reason)
    end
  end

  defp registration(token_id, profile_url) do
    %{
      "agentId" => "#{agent_registry()}:#{token_id}",
      "tokenId" => token_id,
      "profileUrl" => profile_url,
      "registryUrl" => "https://www.8004scan.io/agents/base/#{token_id}"
    }
  end

  # A registration links the wallet to it when it is first kept. Asking again
  # about one already kept changes nothing, so it never replaces a listing the
  # wallet linked since.
  defp keep_registration(row, profile_url) do
    Repo.transact(fn ->
      case Repo.insert_all(Record, [row], on_conflict: :nothing) do
        {1, _rows} -> {:ok, keep_link(row.wallet_address, row.token_id, profile_url)}
        {0, _rows} -> {:ok, nil}
      end
    end)
  end

  defp keep_link(wallet_address, token_id, profile_url) do
    Repo.insert!(
      Link.changeset(%{
        wallet_address: wallet_address,
        token_id: token_id,
        profile_url: profile_url
      }),
      on_conflict: {:replace, [:token_id, :profile_url, :updated_at]},
      conflict_target: :wallet_address
    )
  end

  # Uses the challenge up and keeps the link, so a challenge links once.
  defp consume_and_link(record, token_id, profile_url) do
    Repo.transact(fn ->
      with :ok <- NonceStore.consume(record) do
        {:ok, keep_link(record.address, token_id, profile_url)}
      end
    end)
  end

  # The registry names the wallet as the agent's agent wallet or its owner. An
  # agent with no agent wallet set answers the zero address, and an agent that
  # does not exist has no owner: `ownerOf` reverts.
  defp named(chain, wallet_address, token_id) do
    with {:ok, agent_wallet} <- read(chain, "getAgentWallet(uint256)", token_id, :address) do
      if agent_wallet != @zero_address and agent_wallet == wallet_address,
        do: :ok,
        else: owner(chain, wallet_address, token_id)
    end
  end

  defp owner(chain, wallet_address, token_id) do
    case call(chain, "ownerOf(uint256)", token_id, :address) do
      {:ok, ^wallet_address} -> :ok
      {:ok, _other_owner} -> not_this_wallet(token_id)
      {:error, "execution reverted" <> _detail} -> not_this_wallet(token_id)
      {:error, reason} -> lookup_failed(reason)
    end
  end

  defp not_this_wallet(token_id),
    do:
      {:error,
       {422, "listing_not_this_wallet",
        "the Base agent registry does not name this wallet as agent #{token_id}'s owner or agent wallet"}}

  defp read(chain, signature, token_id, type) do
    with {:error, reason} <- call(chain, signature, token_id, type), do: lookup_failed(reason)
  end

  # The registry's answer to a view of agent `token_id`, decoded as `type`.
  defp call(chain, signature, token_id, type) do
    call = %{
      to: AgentRegistry.address(),
      data: Call.encode(signature, [String.to_integer(token_id)])
    }

    with {:ok, answer} <- Ethereum.json_rpc(chain.rpc_url, "eth_call", [call, "latest"]),
         {:ok, data} <- Abi.bytes(answer),
         {:ok, [value]} <- Abi.decode(data, [type]) do
      {:ok, value}
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      _malformed -> {:error, "the registry's answer to #{signature} is malformed"}
    end
  end

  # Sites may link to the profile, so it is kept only when it is an address a
  # browser or an IPFS gateway opens.
  defp profile_address(token_uri) do
    if String.valid?(token_uri) and byte_size(token_uri) <= 2_000 and
         Regex.match?(~r{\A(https|ipfs)://\S+\z}, token_uri),
       do: token_uri
  end

  # The message names the agent, so the request must name the same one.
  defp same_agent(record, token_id) do
    if link_message(
         record.address,
         record.chain_id,
         token_id,
         record.nonce,
         record.issued_at,
         record.expiration_time
       ) == record.canonical_message,
       do: :ok,
       else: {:error, {401, "message_invalid", "the signed challenge names a different agent"}}
  end

  defp link_nonce_key(wallet_address, chain_id) do
    digest = :crypto.hash(:sha256, Jason.encode!([@link_audience, chain_id, wallet_address]))

    "#{@link_audience}:" <> Base.encode16(digest, case: :lower)
  end

  defp link_message(wallet_address, chain_id, token_id, nonce, issued, expires) do
    Enum.join(
      [
        "Link an agent registry listing to this agent wallet on Regent sites",
        "",
        "Wallet: #{wallet_address}",
        "Agent: #{token_id}",
        "Registry: #{agent_registry()}",
        "",
        "Regent sites show this listing for the wallet until it links or",
        "registers another.",
        "",
        "Chain ID: #{chain_id}",
        "Nonce: #{nonce}",
        "Issued At: #{DateTime.to_iso8601(issued)}",
        "Expiration Time: #{DateTime.to_iso8601(expires)}"
      ],
      "\n"
    )
  end

  defp minted_token_id(%{"logs" => logs}, wallet_address) when is_list(logs) do
    Enum.find_value(logs, {:error, "no agent minted to the wallet"}, fn
      %{"address" => address, "topics" => [@transfer_topic, @zero_topic, to, token_id]} ->
        if Address.equal?(address, AgentRegistry.address()) and
             Address.equal?(topic_address(to), wallet_address),
           do:
             {:ok,
              token_id
              |> String.replace_prefix("0x", "")
              |> String.to_integer(16)
              |> Integer.to_string()}

      _log ->
        nil
    end)
  end

  defp minted_token_id(_receipt, _wallet_address), do: {:error, "invalid receipt"}

  defp topic_address("0x" <> <<_padding::binary-size(24), address::binary-size(40)>>),
    do: "0x" <> String.downcase(address)

  defp topic_address(_topic), do: nil

  defp register_step(agent_uri),
    do:
      Review.step(
        "register",
        AgentRegistry.address(),
        Call.encode("register(string)", [agent_uri])
      )

  defp agent_uri(profile), do: profile_url(profile_id(profile))

  defp profile_url(profile_id),
    do: SiwaServerWeb.Endpoint.url() <> "/agent-profiles/" <> profile_id

  defp profile_id(profile) do
    [
      Address.normalize!(profile.wallet_address),
      profile.name,
      profile.description,
      profile.image || ""
    ]
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> binary_part(0, 16)
    |> Base.encode16(case: :lower)
  end

  defp agent_registry, do: "eip155:#{AgentRegistry.chain_id()}:#{AgentRegistry.address()}"

  defp base_chain do
    case Text.normalize_optional_text(RuntimeConfig.base_rpc_url()) do
      nil -> lookup_failed("base rpc url is not configured")
      rpc_url -> {:ok, %{chain_id: AgentRegistry.chain_id(), name: "Base", rpc_url: rpc_url}}
    end
  end

  defp lookup_failed(reason) when is_binary(reason),
    do:
      {:error,
       {502, "agent_registration_lookup_failed",
        "could not read the registration on Base: #{reason}"}}
end
