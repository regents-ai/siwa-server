defmodule SiwaServer.Billing.PeriodRolloverConcurrencyTest do
  # Outside the test's rollback, so each machine's transaction commits on its own;
  # everything made is removed when the test ends.
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias SiwaServer.{Billing, Repo}
  alias SiwaServer.Billing.Period
  alias SiwaServer.Customers.Customer

  setup do
    assert String.starts_with?(Repo.config()[:database], "siwa_server_test")

    customer =
      db(fn ->
        Repo.insert!(%Customer{
          owner_did: "did:privy:#{Ecto.UUID.generate()}",
          name: "Acme",
          kind: :paid,
          subscription_status: "active"
        })
      end)

    on_exit(fn ->
      db(fn ->
        Repo.delete_all(from p in Period, where: p.customer_id == ^customer.id)
        Repo.delete_all(from c in Customer, where: c.id == ^customer.id)
      end)
    end)

    %{customer: customer, ended_at: db(fn -> ended_an_hour_ago(customer) end)}
  end

  test "verifications arriving at once after a period ends open the next period once",
       %{customer: customer, ended_at: ended_at} do
    results = at_once(List.duplicate(:count, 8), customer, ended_at)

    assert [_one_id] = results |> Enum.map(fn {:ok, period} -> period.id end) |> Enum.uniq()

    db(fn ->
      assert [{_last_start, ^ended_at}, {^ended_at, next_end}] = periods(customer)
      assert next_end == DateTime.shift(ended_at, month: 1)
    end)
  end

  test "Stripe's period arriving while verifications open the next one leaves one period, Stripe's",
       %{customer: customer, ended_at: ended_at} do
    stripe_end = DateTime.add(ended_at, 30 * 86_400 + 7)

    results =
      at_once(
        Enum.shuffle([:put | List.duplicate(:count, 6)] ++ [:put]),
        customer,
        ended_at,
        stripe_end
      )

    assert [_one_id] = results |> Enum.map(fn {:ok, period} -> period.id end) |> Enum.uniq()

    db(fn -> assert [{_last_start, ^ended_at}, {^ended_at, ^stripe_end}] = periods(customer) end)
  end

  defp at_once(steps, customer, ended_at, stripe_end \\ nil) do
    steps
    |> Task.async_stream(&db(fn -> Repo.transact(step(&1, customer, ended_at, stripe_end)) end),
      max_concurrency: length(steps),
      timeout: 15_000
    )
    |> Enum.map(fn {:ok, result} -> result end)
  end

  defp step(:count, customer, _ended_at, _stripe_end),
    do: fn -> Billing.period_to_count(customer) end

  defp step(:put, customer, ended_at, stripe_end),
    do: fn -> {:ok, Billing.put_period(customer, ended_at, stripe_end)} end

  defp ended_an_hour_ago(customer) do
    %{rows: [[now]]} = Repo.query!("SELECT date_trunc('second', now())")
    ended_at = DateTime.add(now, -3_600)

    {:ok, _period} =
      Billing.open_period(customer, DateTime.shift(ended_at, month: -1), ended_at)

    ended_at
  end

  defp periods(customer) do
    Repo.all(
      from p in Period,
        where: p.customer_id == ^customer.id,
        order_by: p.starts_at,
        select: {p.starts_at, p.ends_at}
    )
  end

  defp db(fun), do: Sandbox.unboxed_run(Repo, fun)
end
