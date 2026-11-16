defmodule SiwaServer.Billing.NoticeWorker do
  @moduledoc """
  Acts on one Stripe notice (`SiwaServer.Billing.Notice`), on the `stripe`
  queue: takes in the subscription it names (`SiwaServer.Billing.Subscription.sync/2`),
  or ties or checks the invoice it names (`SiwaServer.Billing.Invoices`). Each
  reads the object from Stripe as it is now. A failed read is tried again.
  """

  use Oban.Worker, queue: :stripe, max_attempts: 10

  alias SiwaServer.Billing.{Invoices, Subscription}
  alias SiwaServer.Config

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"kind" => kind, "object_id" => id}}) do
    case Config.stripe() do
      {:ok, stripe} -> act(kind, id, stripe)
      :error -> {:cancel, :billing_not_configured}
    end
  end

  defp act("subscription", id, stripe), do: Subscription.sync(id, stripe.price_id)
  defp act("invoice_created", id, _stripe), do: Invoices.drafted(id)
  defp act("invoice_finalized", id, _stripe), do: Invoices.finalized(id)
end
