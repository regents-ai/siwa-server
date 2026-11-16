defmodule SiwaServer.Billing.SubscriptionSyncTest do
  use SiwaServer.DataCase, async: false
  use Oban.Testing, repo: SiwaServer.Repo

  import ExUnit.CaptureLog

  alias SiwaServer.{Billing, TestClock, TestStripe}
  alias SiwaServer.Billing.{NoticeWorker, Period, Subscription}
  alias SiwaServer.Customers.Customer

  @price "price_siwa_test"
  @now ~U[2026-11-10 12:00:00.000000Z]
  @nov ~U[2026-11-01 09:30:00.000000Z]
  @dec ~U[2026-12-01 09:30:00.000000Z]
  @jan ~U[2027-01-01 09:30:00.000000Z]

  setup do
    TestClock.start(@now)
    customer = Repo.insert!(%Customer{owner_did: "did:privy:sync", name: "Acme", kind: :paid})
    customer = Repo.update!(change(customer, stripe_customer_id: "cus_sync"))
    %{customer: customer}
  end

  test "a running subscription sets the status and Stripe's period, and the agents count in it",
       %{customer: customer} do
    stripe(%{"sub_1" => subscription("sub_1", "active", @nov, @dec)})

    assert {:ok, :synced} = sync("sub_1")
    assert %{subscription_status: "active", stripe_subscription_id: "sub_1"} = reload(customer)
    assert [{@nov, @dec}] = periods(customer)
    assert {:ok, %Period{starts_at: @nov}} = Billing.period_to_count(reload(customer))
  end

  test "taking the same subscription in again changes nothing", %{customer: customer} do
    stripe(%{"sub_1" => subscription("sub_1", "active", @nov, @dec)})

    for _again <- 1..3, do: assert({:ok, :synced} = sync("sub_1"))
    assert [{@nov, @dec}] = periods(customer)
  end

  test "a read older than one already taken in is dropped, whichever finishes first",
       %{customer: customer} do
    # The older read reaches Stripe first, but a newer read (cancelled) is taken
    # in while it waits for Stripe's answer.
    TestStripe.answer(fn :get, "/v1/subscriptions/sub_1", _params ->
      if Process.get(:newer_read_done) do
        {:ok, subscription("sub_1", "canceled", @nov, @dec)}
      else
        Process.put(:newer_read_done, true)
        {:ok, :synced} = sync("sub_1")
        {:ok, subscription("sub_1", "active", @nov, @dec)}
      end
    end)

    assert {:ok, :older} = sync("sub_1")
    assert %{subscription_status: "canceled"} = reload(customer)
    assert periods(customer) == []
  end

  test "a subscription that stops running stops the sites taking agents", %{customer: customer} do
    stripe(%{"sub_1" => subscription("sub_1", "active", @nov, @dec)})
    {:ok, :synced} = sync("sub_1")

    for status <- ~w(canceled unpaid incomplete_expired paused) do
      stripe(%{"sub_1" => subscription("sub_1", status, @nov, @dec)})
      {:ok, :synced} = sync("sub_1")

      assert {:error, {402, "billing_required", _message}} =
               Billing.period_to_count(reload(customer))
    end

    for status <- ~w(past_due trialing active) do
      stripe(%{"sub_1" => subscription("sub_1", status, @nov, @dec)})
      {:ok, :synced} = sync("sub_1")
      assert {:ok, %Period{}} = Billing.period_to_count(reload(customer))
    end
  end

  test "a second running subscription is reported and not taken in", %{customer: customer} do
    stripe(%{
      "sub_1" => subscription("sub_1", "active", @nov, @dec),
      "sub_2" => subscription("sub_2", "active", @nov, @dec)
    })

    {:ok, :synced} = sync("sub_1")

    assert capture_log(fn -> assert {:ok, :kept} = sync("sub_2") end) =~
             "check=subscription"

    assert %{stripe_subscription_id: "sub_1"} = reload(customer)
  end

  test "a new subscription is taken in once the old one has ended", %{customer: customer} do
    stripe(%{
      "sub_1" => subscription("sub_1", "canceled", @nov, @dec),
      "sub_2" => subscription("sub_2", "active", ~U[2026-11-10 11:00:00.000000Z], @jan)
    })

    {:ok, :synced} = sync("sub_1")
    {:ok, :synced} = sync("sub_2")

    assert %{stripe_subscription_id: "sub_2", subscription_status: "active"} = reload(customer)
  end

  test "a subscription of no customer here is left alone" do
    stripe(%{
      "sub_9" => %{subscription("sub_9", "active", @nov, @dec) | "customer" => "cus_other"}
    })

    assert {:ok, :not_ours} = sync("sub_9")
  end

  test "an ended period rolls over on first use and Stripe's period replaces it",
       %{customer: customer} do
    stripe(%{"sub_1" => subscription("sub_1", "active", @nov, @dec)})
    {:ok, :synced} = sync("sub_1")

    # Stripe has not yet said what comes after December 1st.
    TestClock.set(~U[2026-12-01 09:31:00Z])
    customer = reload(customer)

    assert {:ok, %Period{starts_at: @dec, ends_at: provisional}} =
             Billing.period_to_count(customer)

    assert provisional == ~U[2027-01-01 09:30:00.000000Z]

    stripe(%{"sub_1" => subscription("sub_1", "active", @dec, ~U[2027-01-01 09:30:07.000000Z])})
    {:ok, :synced} = sync("sub_1")

    assert [{@nov, @dec}, {@dec, ~U[2027-01-01 09:30:07.000000Z]}] = periods(customer)
  end

  test "a period that starts before the last ends cuts the last short", %{customer: customer} do
    stripe(%{"sub_1" => subscription("sub_1", "active", @nov, @dec)})
    {:ok, :synced} = sync("sub_1")

    restart = ~U[2026-11-10 11:00:00.000000Z]
    stripe(%{"sub_1" => subscription("sub_1", "active", restart, @jan)})
    {:ok, :synced} = sync("sub_1")

    assert [{@nov, ^restart}, {^restart, @jan}] = periods(customer)
  end

  test "a subscription notice's job takes the subscription in", %{customer: customer} do
    stripe(%{"sub_1" => subscription("sub_1", "trialing", @nov, @dec)})

    assert {:ok, :synced} =
             perform_job(NoticeWorker, %{
               kind: "subscription",
               object_id: "sub_1",
               event_id: "evt_1"
             })

    assert %{subscription_status: "trialing"} = reload(customer)
  end

  defp sync(id), do: Subscription.sync(id, @price)

  defp stripe(subscriptions) do
    TestStripe.answer(fn :get, "/v1/subscriptions/" <> id, _params ->
      {:ok, Map.fetch!(subscriptions, id)}
    end)
  end

  defp subscription(id, status, starts_at, ends_at) do
    %{
      "id" => id,
      "object" => "subscription",
      "customer" => "cus_sync",
      "status" => status,
      "items" => %{
        "data" => [
          %{
            "price" => %{"id" => @price},
            "current_period_start" => DateTime.to_unix(starts_at),
            "current_period_end" => DateTime.to_unix(ends_at)
          }
        ]
      }
    }
  end

  defp reload(customer), do: Repo.reload!(customer)

  defp periods(customer) do
    Repo.all(
      from p in Period,
        where: p.customer_id == ^customer.id,
        order_by: p.starts_at,
        select: {p.starts_at, p.ends_at}
    )
  end
end
