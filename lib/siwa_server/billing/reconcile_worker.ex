defmodule SiwaServer.Billing.ReconcileWorker do
  @moduledoc """
  After a period's final report, checks that Stripe's meter holds the period's
  count: the meter's value for the customer over the minutes Stripe bills the
  period on (`SiwaServer.Billing.ReportWorker`), against the ledger's
  `active_agents`.

  Stripe takes a little while to add up a meter event, so a value that does not
  match yet is read again every 30 seconds, up to 20 times. A match marks the
  period `matched`. A value still wrong after that marks it `mismatched`, is
  logged as an error for operators and counted
  (`siwa_server.billing.check_failures.total`), and holds the period's draft
  invoice so Stripe does not charge it on its own; a draft that arrives later
  holds itself (`SiwaServer.Billing.Invoices.drafted/1`). Neither changes a
  count.
  """

  use Oban.Worker,
    queue: :stripe,
    max_attempts: 10,
    unique: [keys: [:period_id], period: :infinity, states: :incomplete]

  import Ecto.Query

  require Logger

  alias SiwaServer.Billing.{Invoices, Period, ReportWorker, Stripe}
  alias SiwaServer.{Config, Repo}

  @wait_seconds 30
  @max_waits 20

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"period_id" => period_id}, meta: meta}) do
    with {:ok, %{price_id: price_id}} <- configured(),
         {:ok, period} <- fetch(period_id),
         {:ok, %{"recurring" => %{"meter" => meter_id}}} <- Stripe.get_price(price_id),
         {:ok, value} <-
           Stripe.meter_value(
             meter_id,
             period.customer.stripe_customer_id,
             minute_start(period.starts_at),
             minute_start(period.ends_at)
           ) do
      cond do
        value == period.active_agents -> matched(period)
        Map.get(meta, "snoozed", 0) < @max_waits -> {:snooze, @wait_seconds}
        true -> mismatched(period, value)
      end
    end
  end

  defp configured do
    case Config.stripe() do
      {:ok, stripe} -> {:ok, stripe}
      :error -> {:cancel, :billing_not_configured}
    end
  end

  defp fetch(period_id) do
    case Repo.one(from p in Period, where: p.id == ^period_id, preload: :customer) do
      %Period{} = period -> {:ok, period}
      nil -> {:cancel, :period_not_found}
    end
  end

  defp minute_start(at), do: at |> DateTime.to_unix() |> ReportWorker.minute_start()

  defp matched(period) do
    Repo.update_all(from(p in Period, where: p.id == ^period.id), set: [meter_check: :matched])
    :ok
  end

  # The mark and the invoice tie each read the other in the one row they both
  # change, so whichever comes second sees the first and holds the invoice.
  defp mismatched(period, value) do
    {1, [invoice_id]} =
      Repo.update_all(
        from(p in Period, where: p.id == ^period.id, select: p.stripe_invoice_id),
        set: [meter_check: :mismatched]
      )

    Logger.error(
      "billing check failed check=meter period=#{period.id} customer=#{period.customer_id} " <>
        "ledger_agents=#{period.active_agents} meter_value=#{value} invoice=#{invoice_id}"
    )

    :telemetry.execute([:siwa_server, :billing, :check_failed], %{}, %{check: "meter"})

    case invoice_id do
      nil -> :ok
      invoice_id -> with {:ok, :held} <- Invoices.hold(invoice_id), do: :ok
    end
  end
end
