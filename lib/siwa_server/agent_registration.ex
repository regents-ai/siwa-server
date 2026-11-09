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
    4. `latest/1` is the wallet's newest registration, for sites to link to.
    5. `check_owners/0` keeps each registration listed only while its wallet
       still owns the token (`SiwaServer.AgentRegistration.OwnerCheckWorker`).

  Each landed registration is kept in `agent_registrations`; none is ever
  deleted.
  """

  use Ecto.Schema

  import Ecto.Changeset,
    only: [apply_action: 2, cast: 4, validate_format: 3, validate_length: 3, validate_required: 2]

  import Ecto.Query

  require Logger

  alias RegentChain.{Address, Call, Outcome, Review}
  alias SiwaServer.{Config, Ethereum, Repo}

  # The ERC-8004 identity registry on Base.
  @chain_id 8453
  @registry "0x8004a169fb4a3325136eb29fa0ceb6d2e539a432"
  @agent_registry "eip155:#{@chain_id}:#{@registry}"

  @transfer_topic "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
  @zero_topic "0x" <> String.duplicate("0", 64)
  @registration_type "https://eips.ethereum.org/EIPS/eip-8004#registration-v1"

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
    field :status, Ecto.Enum, values: [:listed, :ended], default: :listed

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
  The wallet's newest registration made through this server whose token it
  still owns (`check_owners/0`), or nil.
  """
  @spec latest(String.t()) :: map() | nil
  def latest(wallet_address) do
    from(r in __MODULE__,
      where: r.wallet_address == ^String.downcase(wallet_address) and r.status == :listed,
      order_by: [desc: r.inserted_at, desc: fragment("?::numeric", r.token_id)],
      limit: 1
    )
    |> Repo.one()
    |> case do
      nil -> nil
      record -> registration(record.token_id, record.profile_id)
    end
  end

  @doc """
  Reads each registration's token owner with `ownerOf` at the latest Base
  block. The wallet owning it keeps or puts the registration back to `listed`;
  another owner, or a revert, ends it (`ended`): an ERC-721 `ownerOf` reverts
  only for a token that does not exist. Any other failed read stops with a
  warning and leaves that registration and the ones after it to the next run.
  """
  @spec check_owners() :: :ok
  def check_owners do
    from(r in __MODULE__, select: {r.id, r.wallet_address, r.token_id})
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
      |> validate_format(:name, ~r/\S/)
      |> validate_format(:description, ~r/\S/)
      |> validate_length(:name, max: 100)
      |> validate_length(:description, max: 1_000)
      |> validate_length(:image, max: 500)
      |> validate_format(:image, ~r{\Ahttps://\S+\z})
      |> validate_format(:tx_hash, ~r/^0x[0-9a-fA-F]{64}$/)

    with [] <- Map.keys(params) -- Enum.map(fields, &Atom.to_string/1),
         {:ok, request} <- apply_action(changeset, :cast) do
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

      Repo.insert!(
        %__MODULE__{
          profile_id: profile_id,
          wallet_address: wallet_address,
          name: request.name,
          description: request.description,
          image: request.image,
          token_id: token_id,
          tx_hash: hash
        },
        on_conflict: :nothing
      )

      {:ok,
       %{
         "code" => "agent_registered",
         "data" =>
           Map.merge(registration(token_id, profile_id), %{
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

  defp registration(token_id, profile_id) do
    %{
      "agentId" => "#{@agent_registry}:#{token_id}",
      "tokenId" => token_id,
      "profileUrl" => profile_url(profile_id),
      "registryUrl" => "https://www.8004scan.io/agents/base/#{token_id}"
    }
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

  defp owner(token_id) do
    call = %{
      to: @registry,
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
    from(r in __MODULE__, where: r.id == ^id and r.status != ^status)
    |> Repo.update_all(set: [status: status, updated_at: DateTime.utc_now(:second)])
  end

  defp lookup_failed(reason) when is_binary(reason),
    do:
      {:error,
       {502, "agent_registration_lookup_failed",
        "could not read the registration on Base: #{reason}"}}
end
