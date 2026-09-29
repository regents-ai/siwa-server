defmodule SiwaServer.AgentRegistry do
  @moduledoc """
  The one agent registry SIWA accepts: the ERC-8004 identity registry on Base.

  An agent is its token in this registry. Sign-in checks that the signing
  wallet owns the token, and every agent id this server issues names this
  registry, so two sites that see the same agent id see the same agent.
  """

  @chain_id 8453
  @address "0x8004a169fb4a3325136eb29fa0ceb6d2e539a432"

  @doc "Base's chain id."
  @spec chain_id() :: pos_integer()
  def chain_id, do: @chain_id

  @doc "The registry's address, in lower case."
  @spec address() :: String.t()
  def address, do: @address
end
