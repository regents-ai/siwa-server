defmodule SiwaServer.Billing.Price do
  @moduledoc """
  Price v1: $99 a period covers the first 1,000 agents, and each agent past
  them adds $0.099. Worked in tenths of a cent, so every figure is exact:
  a fee is `99_000 + max(0, agents - 1_000) * 99` tenths.

  A cap is in whole cents and at least the minimum, $99 (9,900 cents). The
  most agents a cap pays for is the largest count whose fee is at most it.
  """

  @included_agents 1_000
  @base_tenths 99_000
  @agent_tenths 99

  @doc "The agents the minimum fee covers."
  @spec included_agents() :: pos_integer()
  def included_agents, do: @included_agents

  @doc "The smallest cap, in cents: the minimum fee."
  @spec min_cap_cents() :: pos_integer()
  def min_cap_cents, do: div(@base_tenths, 10)

  @doc "The fee for `agents` counted in a period, in cents with one decimal place."
  @spec fee_cents(non_neg_integer()) :: Decimal.t()
  def fee_cents(agents) when is_integer(agents) and agents >= 0,
    do: Decimal.new(1, fee_tenths(agents), -1)

  @doc "Whether `agents` cost at most `cap_cents`."
  @spec within?(non_neg_integer(), pos_integer()) :: boolean()
  def within?(agents, cap_cents), do: fee_tenths(agents) <= cap_cents * 10

  @doc "The most agents `cap_cents` pays for; nil for no cap."
  @spec max_agents(pos_integer() | nil) :: pos_integer() | nil
  def max_agents(nil), do: nil

  def max_agents(cap_cents) when is_integer(cap_cents) do
    if cap_cents < min_cap_cents(), do: raise(ArgumentError, "a cap is at least 9900 cents")
    @included_agents + div(cap_cents * 10 - @base_tenths, @agent_tenths)
  end

  defp fee_tenths(agents), do: @base_tenths + max(0, agents - @included_agents) * @agent_tenths
end
