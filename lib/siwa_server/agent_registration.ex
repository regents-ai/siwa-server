defmodule SiwaServer.AgentRegistration do
  @moduledoc """
  An agent mints its own identity in the Base ERC-8004 agent registry, paying the
  gas from its own wallet.

    1. `step/1` builds the one transaction: `register()`, or `register(string)`
       when the agent names its agent URI. The agent's wallet sends it.
    2. `outcome/1` reads that transaction at the latest Base block. It is
       `registration_pending` until the receipt exists; once it lands it is
       `agent_registered`, with the token id the registry minted to the wallet,
       or `registration_reverted`. A hash
       whose sender, target or calldata is not the step's is no answer about
       the step.

  Nothing is stored. Once registered, the agent signs in with the ordinary SIWA
  flow using the returned token id.
  """

  alias RegentChain.{Address, Call, Outcome, Review}
  alias SiwaServer.{AgentRegistry, Ethereum, RuntimeConfig, Text}

  @transfer_topic "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
  @zero_topic "0x" <> String.duplicate("0", 64)

  @type error :: {:error, {pos_integer(), String.t(), String.t()}}

  @doc "The unsigned registration transaction for `wallet_address` to send on Base."
  @spec step(%{wallet_address: String.t(), agent_uri: String.t() | nil}) :: {:ok, map()}
  def step(%{wallet_address: wallet_address, agent_uri: agent_uri}) do
    %{to: to, data: data, value: value} = register_step(agent_uri)

    {:ok,
     %{
       "code" => "registration_step",
       "data" => %{
         "chainId" => AgentRegistry.chain_id(),
         "from" => Address.normalize!(wallet_address),
         "to" => to,
         "data" => data,
         "value" => value
       }
     }}
  end

  @doc "What the registration sent as `tx_hash` did, read at the latest Base block."
  @spec outcome(%{wallet_address: String.t(), agent_uri: String.t() | nil, tx_hash: String.t()}) ::
          {:ok, map()} | error()
  def outcome(%{wallet_address: wallet_address, agent_uri: agent_uri, tx_hash: tx_hash}) do
    hash = String.downcase(tx_hash)

    with {:ok, chain} <- base_chain(),
         review =
           Review.new("agent-registration", wallet_address, chain, [register_step(agent_uri)]),
         {:ok, status} <- Outcome.of(__MODULE__, review, hd(review.steps), hash) do
      result(status, chain, review.signer, hash)
    else
      {:error, :not_this_step} ->
        {:error,
         {422, "transaction_not_registration",
          "that transaction is not this wallet's registration in the Base agent registry"}}

      {:error, {_status, _code, _message}} = error ->
        error

      {:error, reason} ->
        lookup_failed(reason)
    end
  end

  @doc false
  def transaction(chain, hash),
    do: Ethereum.json_rpc(chain.rpc_url, "eth_getTransactionByHash", [hash])

  @doc false
  def receipt(chain, hash),
    do: Ethereum.json_rpc(chain.rpc_url, "eth_getTransactionReceipt", [hash])

  defp result(:pending, _chain, _wallet_address, hash),
    do: {:ok, %{"code" => "registration_pending", "data" => %{"txHash" => hash}}}

  defp result(:reverted, _chain, _wallet_address, _hash),
    do:
      {:error,
       {422, "registration_reverted",
        "the registration transaction reverted, so no agent was minted"}}

  defp result(:confirmed, chain, wallet_address, hash) do
    with {:ok, receipt} when is_map(receipt) <- receipt(chain, hash),
         {:ok, token_id} <- minted_token_id(receipt, wallet_address) do
      registry = AgentRegistry.address()

      {:ok,
       %{
         "code" => "agent_registered",
         "data" => %{
           "txHash" => hash,
           "walletAddress" => wallet_address,
           "chainId" => AgentRegistry.chain_id(),
           "registryAddress" => registry,
           "tokenId" => token_id,
           "agentId" => "eip155:#{AgentRegistry.chain_id()}:#{registry}:#{token_id}"
         }
       }}
    else
      {:ok, nil} -> lookup_failed("receipt disappeared")
      {:error, reason} -> lookup_failed(reason)
    end
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

  defp register_step(nil),
    do: Review.step("register", AgentRegistry.address(), Call.encode("register()", []))

  defp register_step(agent_uri),
    do:
      Review.step(
        "register",
        AgentRegistry.address(),
        Call.encode("register(string)", [agent_uri])
      )

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
