defmodule SiwaServer.AgentRegistry do
  @moduledoc """
  The ERC-8004 identity registry on Base, where an agent may choose to list
  itself (see `SiwaServer.AgentRegistration`). Sign-in never depends on it.
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
