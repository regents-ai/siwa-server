defmodule SiwaServer.Billing.ReconcileTest do
  use SiwaServer.DataCase, async: true
  use Oban.Testing, repo: SiwaServer.Repo

  import ExUnit.CaptureLog

  alias SiwaServer.Billing.{Invoices, NoticeWorker, Period, ReconcileWorker, ReportWorker}
  alias SiwaServer.Customers.Customer
  alias SiwaServer.TestStripe

  @starts_at ~U[2026-10-01 10:00:30.000000Z]
  @ends_at ~U[2026-11-01 10:00:30.000000Z]

  setup do
    customer =
      Repo.insert!(%Customer{
        owner_did: "did:privy:#{Ecto.UUID.generate()}",
        name: "Acme",
        kind: :paid,
        subscription_status: "active",
        stripe_customer_id: "cus_#{System.unique_integer([:positive])}"
      })

    period =
      Repo.insert!(%Period{
        customer_id: customer.id,
        starts_at: @starts_at,
        ends_at: @ends_at,
        active_agents: 1_001,
        reported_agents: 1_001,
        final_reported_at: ~U[2026-11-01 10:01:31.000000Z]
      })

    %{customer: customer, period: period}
  end

  test "a meter that holds the count marks the period matched, over the minutes Stripe bills",
       %{customer: customer, period: period} do
    stripe(meter: 1_001.0)

    assert :ok = reconcile(period)
    assert %{meter_check: :matched} = Repo.reload!(period)

    assert_received {:stripe, :get, "/v1/billing/meters/mtr_siwa/event_summaries", params}
    customer_id = customer.stripe_customer_id

    assert %{customer: ^customer_id, start_time: start_time, end_time: end_time} = params
    assert start_time == DateTime.to_unix(~U[2026-10-01 10:00:00Z])
    assert end_time == DateTime.to_unix(~U[2026-11-01 10:00:00Z])
  end

  test "a meter not yet showing the count is read again, a bounded number of times",
       %{period: period} do
    stripe(meter: 999.0)

    assert {:snooze, 30} = reconcile(period, 0)
    assert {:snooze, 30} = reconcile(period, 19)
    assert %{meter_check: nil} = Repo.reload!(period)
  end

  test "a meter still wrong after the waits marks the period, reports it and holds its invoice",
       %{period: period} do
    Repo.update!(change(period, stripe_invoice_id: "in_held"))
    stripe(meter: 999.0)

    log = capture_log(fn -> assert :ok = reconcile(period, 20) end)

    assert log =~ "check=meter"
    assert log =~ "ledger_agents=1001 meter_value=999.0"
    assert %{meter_check: :mismatched, active_agents: 1_001} = Repo.reload!(period)
    assert_received {:stripe, :post, "/v1/invoices/in_held", %{auto_advance: false}}
  end

  test "a draft arriving after the meter disagreed holds itself; it queues the final report",
       %{customer: customer, period: period} do
    Repo.update!(change(period, meter_check: :mismatched))
    stripe(invoice: invoice(customer, "draft", total: 9_910, quantities: ["1000", "0", "1"]))

    assert capture_log(fn -> assert {:ok, :held} = drafted() end) =~ "invoice held invoice=in_1"
    assert %{stripe_invoice_id: "in_1"} = Repo.reload!(period)
    assert_enqueued(worker: ReportWorker, args: %{period_id: period.id})
    assert_received {:stripe, :post, "/v1/invoices/in_1", %{auto_advance: false}}
  end

  test "a draft of a period whose meter agreed is tied and not held",
       %{customer: customer, period: period} do
    stripe(invoice: invoice(customer, "draft", total: 9_910, quantities: ["1000", "0", "1"]))

    assert {:ok, :tied} = drafted()
    assert %{stripe_invoice_id: "in_1"} = Repo.reload!(period)
    refute_received {:stripe, :post, "/v1/invoices/in_1", _params}
  end

  test "an invoice not for a period's cycle is left alone", %{customer: customer} do
    stripe(
      invoice: %{
        invoice(customer, "draft", total: 0, quantities: [])
        | "billing_reason" => "manual"
      }
    )

    assert {:ok, :not_ours} = drafted()
  end

  test "a finalised invoice that bills the count at Price v1 is matched",
       %{customer: customer, period: period} do
    stripe(invoice: invoice(customer, "open", total: 9_910, quantities: ["1000", "0", "1"]))

    assert {:ok, :matched} = finalized()
    assert %{invoice_check: :matched} = Repo.reload!(period)
  end

  test "a finalised invoice billing other agents or another total is recorded, the count kept",
       %{customer: customer, period: period} do
    for {total, quantities} <- [{9_910, ["1000", "0", "2"]}, {9_909, ["1000", "0", "1"]}] do
      stripe(invoice: invoice(customer, "open", total: total, quantities: quantities))

      assert capture_log(fn -> assert {:ok, :mismatched} = finalized() end) =~ "check=invoice"
      assert %{invoice_check: :mismatched, active_agents: 1_001} = Repo.reload!(period)
    end
  end

  test "the agents an invoice bills leave out the flat fee's line" do
    for {quantities, agents} <- [
          {["0", "0"], 0},
          {["999", "0"], 999},
          {["1000", "0", "1500"], 2_500}
        ] do
      assert Decimal.equal?(
               Invoices.agents_billed(
                 invoice(%{stripe_customer_id: "cus"}, "open", total: 0, quantities: quantities)
               ),
               agents
             )
    end
  end

  defp reconcile(period, waited \\ 0),
    do: perform_job(ReconcileWorker, %{period_id: period.id}, meta: %{"snoozed" => waited})

  defp drafted,
    do:
      perform_job(NoticeWorker, %{kind: "invoice_created", object_id: "in_1", event_id: "evt_1"})

  defp finalized,
    do:
      perform_job(NoticeWorker, %{kind: "invoice_finalized", object_id: "in_1", event_id: "evt_2"})

  defp stripe(answers) do
    TestStripe.answer(fn
      :get, "/v1/prices/price_siwa_test", _params ->
        {:ok, %{"id" => "price_siwa_test", "recurring" => %{"meter" => "mtr_siwa"}}}

      :get, "/v1/billing/meters/mtr_siwa/event_summaries", _params ->
        {:ok, %{"data" => [%{"aggregated_value" => Keyword.fetch!(answers, :meter)}]}}

      :get, "/v1/invoices/in_1", _params ->
        {:ok, Keyword.fetch!(answers, :invoice)}

      :post, "/v1/invoices/" <> id, %{auto_advance: false} ->
        {:ok, %{"id" => id, "auto_advance" => false}}
    end)
  end

  # An invoice as Stripe shapes one for a period: the first usage tier, the flat
  # fee (no unit amount, quantity 0), then the second usage tier when used.
  defp invoice(customer, status, total: total, quantities: quantities) do
    unit_amounts = ["0", nil, "9.9"]

    %{
      "id" => "in_1",
      "object" => "invoice",
      "status" => status,
      "billing_reason" => "subscription_cycle",
      "customer" => customer.stripe_customer_id,
      "period_start" => DateTime.to_unix(@starts_at),
      "period_end" => DateTime.to_unix(@ends_at),
      "total" => total,
      "total_excluding_tax" => total,
      "lines" => %{
        "data" =>
          quantities
          |> Enum.zip(unit_amounts)
          |> Enum.map(fn {quantity, unit_amount} ->
            %{
              "quantity_decimal" => quantity,
              "pricing" => %{"unit_amount_decimal" => unit_amount}
            }
          end)
      }
    }
  end
end
