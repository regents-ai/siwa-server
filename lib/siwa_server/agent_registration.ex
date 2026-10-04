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
    4. `latest/1` is the wallet's newest registration, for sites to link to.
  """

  import Ecto.Query

  alias RegentChain.{Address, Call, Outcome, Review}
  alias SiwaServer.AgentRegistration.Record
  alias SiwaServer.{AgentRegistry, Ethereum, Repo, RuntimeConfig, Text}

  @transfer_topic "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
  @zero_topic "0x" <> String.duplicate("0", 64)
  @registration_type "https://eips.ethereum.org/EIPS/eip-8004#registration-v1"

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

  @doc "The wallet's newest registration made through this server, or nil."
  @spec latest(String.t()) :: map() | nil
  def latest(wallet_address) do
    from(r in Record,
      where: r.wallet_address == ^String.downcase(wallet_address),
      order_by: [desc: r.inserted_at, desc: r.token_id],
      limit: 1
    )
    |> Repo.one()
    |> case do
      nil -> nil
      record -> registration(record.token_id, record.profile_id)
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

      Repo.insert!(
        Record.changeset(%{
          profile_id: profile_id,
          wallet_address: wallet_address,
          name: request.name,
          description: request.description,
          image: request.image,
          token_id: token_id,
          tx_hash: hash
        }),
        on_conflict: :nothing
      )

      {:ok,
       %{
         "code" => "agent_registered",
         "data" =>
           Map.merge(registration(token_id, profile_id), %{
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

  defp registration(token_id, profile_id) do
    %{
      "agentId" => "#{agent_registry()}:#{token_id}",
      "tokenId" => token_id,
      "profileUrl" => profile_url(profile_id),
      "registryUrl" => "https://www.8004scan.io/agents/base/#{token_id}"
    }
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
