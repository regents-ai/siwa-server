defmodule SiwaServer.AgentRegistration do
  @moduledoc """
  An agent may list itself in the Base ERC-8004 agent registry. Listing is
  optional and changes nothing about sign-in. The agent pays the gas from its
  own wallet; this server never sends or funds a transaction.

  Both steps take the request body as sent and check it once against the
  contract: a wallet address, a name of at most 100 characters, a description
  of at most 1,000, an optional `https://` image link of at most 500, and for
  `outcome/1` the transaction hash; nothing else.

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

  Each wallet has one link (`SiwaServer.AgentRegistration.Link`): the listing
  it registered through this server or linked last. `latest/1` names it for
  sites to link to while it is listed; `check_owners/0` keeps it listed only
  while the registry names the wallet
  (`SiwaServer.AgentRegistration.OwnerCheckWorker`).

  Each landed registration is kept in `agent_registrations`, and each link in
  `agent_registry_links`; none is ever deleted.
  """

  use Ecto.Schema

  import Ecto.Changeset,
    only: [apply_action: 2, cast: 4, validate_format: 3, validate_length: 3, validate_required: 2]

  import Ecto.Query

  require Logger

  alias RegentChain.{Abi, Address, Call, Outcome, Review}
  alias SiwaServer.AgentRegistration.Link
  alias SiwaServer.{Config, Ethereum, Repo}
  alias SiwaServer.Siwa.Challenge

  # The ERC-8004 identity registry on Base.
  @chain_id 8453
  @registry "0x8004a169fb4a3325136eb29fa0ceb6d2e539a432"
  @agent_registry "eip155:#{@chain_id}:#{@registry}"

  @transfer_topic "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
  @zero_topic "0x" <> String.duplicate("0", 64)
  @registration_type "https://eips.ethereum.org/EIPS/eip-8004#registration-v1"
  @zero_address "0x" <> String.duplicate("0", 40)
  @link_audience "agent-link"
  @link_challenge_fields [:wallet_address, :chain_id]
  @link_fields @link_challenge_fields ++ [:nonce, :message, :signature]

  @types %{
    wallet_address: :string,
    name: :string,
    description: :string,
    image: :string,
    tx_hash: :string
  }
  @profile [:wallet_address, :name, :description, :image]

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "agent_registrations" do
    field :profile_id, :string
    field :wallet_address, :string
    field :name, :string
    field :description, :string
    field :image, :string
    field :token_id, :string
    field :tx_hash, :string

    timestamps(type: :utc_datetime)
  end

  @type error :: {:error, {pos_integer(), String.t(), String.t()}}

  @doc "The unsigned registration transaction for the profile's wallet to send on Base."
  @spec step(map()) :: {:ok, map()} | error()
  def step(params) do
    with {:ok, profile} <- request(params, @profile) do
      uri = agent_uri(profile)
      %{to: to, data: data, value: value} = register_step(uri)

      {:ok,
       %{
         "code" => "registration_step",
         "data" => %{
           "chainId" => @chain_id,
           "from" => Address.normalize!(profile.wallet_address),
           "to" => to,
           "data" => data,
           "value" => value,
           "agentUri" => uri
         }
       }}
    end
  end

  @doc "What the registration sent as `tx_hash` did, read at the latest Base block."
  @spec outcome(map()) :: {:ok, map()} | error()
  def outcome(params) do
    with {:ok, request} <- request(params, [:tx_hash | @profile]),
         hash = String.downcase(request.tx_hash),
         {:ok, chain} <- base_chain(),
         review =
           Review.new("agent-registration", request.wallet_address, chain, [
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
           from r in __MODULE__,
             where: r.profile_id == ^profile_id,
             order_by: [asc: r.inserted_at]
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
                 "agentRegistry" => @agent_registry
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
  @spec link_challenge(map()) :: {:ok, map()} | error()
  def link_challenge(params) do
    with {:ok, request} <- link_request(params, @link_challenge_fields),
         {:ok, chain} <- base_chain(),
         :ok <- named(chain, request.wallet_address, request.token_id) do
      challenge =
        Challenge.issue(
          link_scope(request),
          %{
            address: request.wallet_address,
            chain_id: request.chain_id,
            audience: @link_audience
          },
          &link_message(&1, request.token_id)
        )

      {:ok,
       %{
         "code" => "agent_link_challenge",
         "data" => %{
           "walletAddress" => challenge.address,
           "chainId" => challenge.chain_id,
           "tokenId" => request.token_id,
           "nonce" => challenge.nonce,
           "message" => challenge.canonical_message,
           "issuedAt" => DateTime.to_iso8601(challenge.issued_at),
           "expiresAt" => DateTime.to_iso8601(challenge.expiration_time)
         }
       }}
    end
  end

  @doc """
  Links the wallet to agent `token_id` once the wallet has signed the unused
  message `link_challenge/1` issued for that agent and the Base registry still
  names the wallet as the agent's owner or agent wallet.
  """
  @spec link(map()) :: {:ok, map()} | error()
  def link(params) do
    with {:ok, request} <- link_request(params, @link_fields),
         {:ok, challenge} <- Challenge.fetch(link_scope(request), request.nonce),
         :ok <- Challenge.current(challenge, request.message),
         :ok <- same_agent(challenge, request.token_id),
         {:ok, _method} <- Challenge.signed(challenge, request.message, request.signature),
         {:ok, chain} <- base_chain(),
         :ok <- named(chain, challenge.address, request.token_id),
         {:ok, token_uri} <- read(chain, "tokenURI(uint256)", request.token_id, :bytes),
         profile_url = profile_address(token_uri),
         {:ok, _link} <- consume_and_link(challenge, request.token_id, profile_url) do
      {:ok,
       %{
         "code" => "agent_linked",
         "data" =>
           Map.merge(registration(request.token_id, profile_url), %{
             "walletAddress" => challenge.address,
             "chainId" => @chain_id,
             "registryAddress" => @registry
           })
       }}
    end
  end

  @doc """
  The listing the wallet registered through this server or linked last, while
  the registry still names the wallet (`check_owners/0`), or nil.
  """
  @spec latest(String.t()) :: map() | nil
  def latest(wallet_address) do
    case Repo.get_by(Link, wallet_address: String.downcase(wallet_address), status: :listed) do
      nil -> nil
      link -> registration(link.token_id, link.profile_url)
    end
  end

  @doc """
  Reads the registry at the latest Base block for each wallet's link. While it
  names the wallet as the agent's owner or agent wallet, the link is kept or
  put back to `listed`; otherwise it is `ended`, as for an agent that does not
  exist, whose `ownerOf` reverts. A failed read, or an answer that is not an
  address, leaves that link as it was with a warning, for the next run. A link
  is never deleted.
  """
  @spec check_owners() :: :ok
  def check_owners do
    rpc_url = Config.base_rpc_url()

    from(l in Link, select: {l.wallet_address, l.token_id})
    |> Repo.all()
    |> Enum.each(fn {wallet_address, token_id} ->
      case registry_names?(rpc_url, wallet_address, token_id) do
        {:ok, true} ->
          set_status(wallet_address, token_id, :listed)

        {:ok, false} ->
          set_status(wallet_address, token_id, :ended)

        {:error, reason} ->
          Logger.warning("registry owner check failed token_id=#{token_id} reason=#{reason}")
      end
    end)
  end

  @doc false
  def transaction(chain, hash),
    do: Ethereum.json_rpc(chain.rpc_url, "eth_getTransactionByHash", [hash])

  @doc false
  def receipt(chain, hash),
    do: Ethereum.json_rpc(chain.rpc_url, "eth_getTransactionReceipt", [hash])

  # The agent's public registry profile: the text is shown as given, so it is
  # only bounded; an image is a link anyone can open.
  defp request(params, fields) do
    changeset =
      {%{image: nil}, @types}
      |> cast(params, fields, empty_values: [])
      |> validate_required(fields -- [:image])
      |> validate_format(:wallet_address, ~r/^0x[0-9a-fA-F]{40}$/)
      |> validate_length(:name, max: 100)
      |> validate_length(:description, max: 1_000)
      |> validate_length(:image, max: 500)
      |> validate_format(:image, ~r{\Ahttps://\S+\z})
      |> validate_format(:tx_hash, ~r/^0x[0-9a-fA-F]{64}$/)

    with [] <- Map.keys(params) -- Enum.map(fields, &Atom.to_string/1),
         {:ok, request} <- apply_action(changeset, :cast),
         false <- "" in [String.trim(request.name), String.trim(request.description)] do
      {:ok, request}
    else
      _invalid ->
        {:error, {400, "invalid_request", "request body does not match the SIWA contract"}}
    end
  end

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
             "chainId" => @chain_id,
             "registryAddress" => @registry
           })
       }}
    else
      {:ok, nil} -> lookup_failed("receipt disappeared")
      {:error, reason} -> lookup_failed(reason)
    end
  end

  defp registration(token_id, profile_url) do
    %{
      "agentId" => "#{@agent_registry}:#{token_id}",
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
      case Repo.insert_all(__MODULE__, [row], on_conflict: :nothing) do
        {1, _rows} -> {:ok, keep_link(row.wallet_address, row.token_id, profile_url)}
        {0, _rows} -> {:ok, nil}
      end
    end)
  end

  defp keep_link(wallet_address, token_id, profile_url) do
    Repo.insert!(
      %Link{
        wallet_address: wallet_address,
        token_id: token_id,
        profile_url: profile_url,
        status: :listed
      },
      on_conflict: {:replace, [:token_id, :profile_url, :status, :updated_at]},
      conflict_target: :wallet_address
    )
  end

  # Uses the challenge up and keeps the link, so a challenge links once.
  defp consume_and_link(challenge, token_id, profile_url) do
    Repo.transact(fn ->
      with :ok <- Challenge.consume(challenge) do
        {:ok, keep_link(challenge.address, token_id, profile_url)}
      end
    end)
  end

  defp named(chain, wallet_address, token_id) do
    case registry_names?(chain.rpc_url, wallet_address, token_id) do
      {:ok, true} -> :ok
      {:ok, false} -> not_this_wallet(token_id)
      {:error, reason} -> lookup_failed(reason)
    end
  end

  # Whether the registry names the wallet as the agent's agent wallet or its
  # owner. An agent with no agent wallet set answers the zero address, and an
  # agent that does not exist has no owner: `ownerOf` reverts.
  defp registry_names?(rpc_url, wallet_address, token_id) do
    with {:ok, agent_wallet} <- call(rpc_url, "getAgentWallet(uint256)", token_id, :address) do
      if agent_wallet != @zero_address and agent_wallet == wallet_address,
        do: {:ok, true},
        else: owner?(rpc_url, wallet_address, token_id)
    end
  end

  defp owner?(rpc_url, wallet_address, token_id) do
    case call(rpc_url, "ownerOf(uint256)", token_id, :address) do
      {:ok, owner} -> {:ok, owner == wallet_address}
      {:error, "execution reverted" <> _detail} -> {:ok, false}
      {:error, reason} -> {:error, reason}
    end
  end

  defp not_this_wallet(token_id),
    do:
      {:error,
       {422, "listing_not_this_wallet",
        "the Base agent registry does not name this wallet as agent #{token_id}'s owner or agent wallet"}}

  defp read(chain, signature, token_id, type) do
    with {:error, reason} <- call(chain.rpc_url, signature, token_id, type),
         do: lookup_failed(reason)
  end

  # The registry's answer to a view of agent `token_id`, decoded as `type`.
  defp call(rpc_url, signature, token_id, type) do
    call = %{to: @registry, data: Call.encode(signature, [String.to_integer(token_id)])}

    with {:ok, answer} <- Ethereum.json_rpc(rpc_url, "eth_call", [call, "latest"]),
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
  defp same_agent(challenge, token_id) do
    if link_message(challenge, token_id) == challenge.canonical_message,
      do: :ok,
      else: {:error, {401, "message_invalid", "the signed challenge names a different agent"}}
  end

  # The challenge's own fields, and an agent's token id in the Base registry: a
  # uint256 in decimal without leading zeros; 77 digits stay below 2^256.
  defp link_request(params, fields) do
    with {token_id, challenge_params} when is_binary(token_id) <- Map.pop(params, "token_id"),
         true <- Regex.match?(~r/^(0|[1-9][0-9]{0,76})$/, token_id),
         {:ok, request} <- Challenge.cast(challenge_params, fields) do
      {:ok, Map.put(request, :token_id, token_id)}
    else
      _invalid ->
        {:error, {400, "invalid_request", "request body does not match the SIWA contract"}}
    end
  end

  defp link_scope(request), do: [@link_audience, request.chain_id, request.wallet_address]

  defp link_message(challenge, token_id) do
    Enum.join(
      [
        "Link an agent registry listing to this agent wallet on Regent sites",
        "",
        "Wallet: #{challenge.address}",
        "Agent: #{token_id}",
        "Registry: #{@agent_registry}",
        "",
        "Regent sites show this listing for the wallet until it links or",
        "registers another.",
        "",
        "Chain ID: #{challenge.chain_id}",
        "Nonce: #{challenge.nonce}",
        "Issued At: #{DateTime.to_iso8601(challenge.issued_at)}",
        "Expiration Time: #{DateTime.to_iso8601(challenge.expiration_time)}"
      ],
      "\n"
    )
  end

  defp minted_token_id(%{"logs" => logs}, wallet_address) when is_list(logs) do
    Enum.find_value(logs, {:error, "no agent minted to the wallet"}, fn
      %{"address" => address, "topics" => [@transfer_topic, @zero_topic, to, token_id]} ->
        if Address.equal?(address, @registry) and
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
    do: Review.step("register", @registry, Call.encode("register(string)", [agent_uri]))

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

  defp base_chain do
    case Config.base_rpc_url() do
      nil -> lookup_failed("base rpc url is not configured")
      rpc_url -> {:ok, %{chain_id: @chain_id, name: "Base", rpc_url: rpc_url}}
    end
  end

  # Only the link that was read: one the wallet replaced since keeps its own status.
  defp set_status(wallet_address, token_id, status) do
    from(l in Link,
      where:
        l.wallet_address == ^wallet_address and l.token_id == ^token_id and l.status != ^status
    )
    |> Repo.update_all(set: [status: status, updated_at: DateTime.utc_now(:second)])
  end

  defp lookup_failed(reason) when is_binary(reason),
    do:
      {:error,
       {502, "agent_registration_lookup_failed",
        "could not read the registration on Base: #{reason}"}}
end
