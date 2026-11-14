defmodule SiwaServer.PricePropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias SiwaServer.Billing.Price

  # The README's table: agents, fee in cents, a cap and the most agents it pays for.
  @table [
    {0, "9900.0", 9_900, 1_000},
    {1_000, "9900.0", 9_900, 1_000},
    {1_001, "9909.9", 10_000, 1_010},
    {2_000, "19800.0", 19_800, 2_000},
    {10_000, "99000.0", 99_000, 10_000}
  ]

  test "the README's worked prices" do
    for {agents, fee, cap_cents, max_agents} <- @table do
      assert Decimal.to_string(Price.fee_cents(agents), :normal) == fee
      assert Price.max_agents(cap_cents) == max_agents
    end

    assert Price.max_agents(nil) == nil
    assert Price.included_agents() == 1_000
    assert Price.min_cap_cents() == 9_900
  end

  property "the fee is the base for the included agents, then 9.9 cents for each one after" do
    check all agents <- integer(0..5_000_000) do
      step = Decimal.sub(Price.fee_cents(agents + 1), Price.fee_cents(agents))
      expected = if agents < 1_000, do: "0.0", else: "9.9"

      assert Decimal.to_string(step, :normal) == expected
      assert Decimal.compare(Price.fee_cents(agents), Price.fee_cents(0)) in [:gt, :eq]
    end
  end

  property "a fee is exact, with one decimal place" do
    check all agents <- integer(0..5_000_000) do
      fee = Price.fee_cents(agents)

      assert fee.exp == -1
      assert Decimal.to_string(fee, :normal) =~ ~r/\A[0-9]+\.[0-9]\z/

      assert Decimal.equal?(
               fee,
               Decimal.div(Decimal.new(99_000 + max(0, agents - 1_000) * 99), 10)
             )
    end
  end

  property "a cap pays for the most agents whose fee is within it, and no more" do
    check all cap_cents <- integer(9_900..2_147_483_647) do
      most = Price.max_agents(cap_cents)

      assert Price.within?(most, cap_cents)
      refute Price.within?(most + 1, cap_cents)

      assert Decimal.compare(Price.fee_cents(most), Decimal.new(cap_cents)) in [:lt, :eq]
      assert Decimal.compare(Price.fee_cents(most + 1), Decimal.new(cap_cents)) == :gt
    end
  end

  property "a cap below the base fee pays for nothing" do
    check all cap_cents <- integer(-1_000_000..9_899) do
      assert_raise ArgumentError, fn -> Price.max_agents(cap_cents) end
    end
  end
end
