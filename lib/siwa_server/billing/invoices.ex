defmodule SiwaServer.Billing.Invoices do
  @moduledoc """
  A paid customer's Stripe invoices: listed for the control API as Stripe has
  them, and checked against the ledger when Stripe makes and finalises the one
  for a period.

  Stripe makes a period's invoice, as a draft, shortly after the period ends.
  `drafted/1` ties the draft to its period and queues the period's final report
  (`SiwaServer.Billing.ReportWorker`); a period whose meter already disagreed
  with the ledger has its draft held. `finalized/1` compares the agents the
  invoice bills, every usage line but the flat fee's, with the period's count,
  and its total with what Price v1 charges for that count, rounded half up to
  the cent. Either check only records what it found; neither changes a count.
  """

  import Ecto.Changeset
  import Ecto.Query

  require Logger

  alias SiwaServer.Billing.{Period, Price, ReportWorker, Stripe, Subscription}
  alias SiwaServer.Customers.Customer
  alias SiwaServer.Repo

  @default_page 12
  @max_page 50

  @type invoice :: %{
          id: String.t(),
          created_at: DateTime.t(),
          period_starts_at: DateTime.t(),
          period_ends_at: DateTime.t(),
          total_cents: integer(),
          status: String.t(),
          hosted_url: String.t() | nil,
          agents: non_neg_integer()
        }

  @doc """
  The customer's invoices, newest first, read from Stripe a page at a time:
  `limit` (1 to #{@max_page}, #{@default_page} when not given) after the invoice
  `after` names. None before it subscribes.
  """
  @spec list(Customer.t(), map()) ::
          {:ok, {[invoice()], String.t() | nil}} | Subscription.refusal()
  def list(customer, params) do
    with {:ok, page} <- page(params) do
      case customer.stripe_customer_id do
        nil -> {:ok, {[], nil}}
        stripe_customer_id -> list_page(stripe_customer_id, page)
      end
    end
  end

  defp list_page(stripe_customer_id, page) do
    with {:ok, %{"data" => invoices, "has_more" => more}} <-
           stripe_customer_id
           |> Stripe.list_invoices(page.limit, page[:after])
           |> Subscription.provider() do
      {:ok, {Enum.map(invoices, &invoice/1), if(more, do: List.last(invoices)["id"])}}
    end
  end

  defp page(params) do
    {%{limit: @default_page}, %{after: :string, limit: :integer}}
    |> cast(params, [:after, :limit])
    |> validate_number(:limit, greater_than_or_equal_to: 1, less_than_or_equal_to: @max_page)
    |> validate_format(:after, ~r/\Ain_[A-Za-z0-9]{1,250}\z/,
      message: "is not a cursor this list gave"
    )
    |> apply_action(:read)
  end

  defp invoice(invoice) do
    %{
      id: invoice["id"],
      created_at: Subscription.unix(invoice["created"]),
      period_starts_at: Subscription.unix(invoice["period_start"]),
      period_ends_at: Subscription.unix(invoice["period_end"]),
      total_cents: invoice["total"],
      status: invoice["status"],
      hosted_url: invoice["hosted_invoice_url"],
      agents: invoice |> agents_billed() |> Decimal.to_integer()
    }
  end

  @doc """
  The agents an invoice bills: the quantities of its usage lines. The flat fee
  is a line of its own with no unit amount, and is left out.
  """
  @spec agents_billed(map()) :: Decimal.t()
  def agents_billed(%{"lines" => %{"data" => lines}}) do
    lines
    |> Enum.reject(&is_nil(&1["pricing"]["unit_amount_decimal"]))
    |> Enum.map(&Decimal.new(&1["quantity_decimal"]))
    |> Enum.reduce(Decimal.new(0), &Decimal.add/2)
  end

  @doc "Ties a period's draft invoice to it and queues the period's final report."
  @spec drafted(String.t()) :: {:ok, atom()} | Stripe.error()
  def drafted(invoice_id) do
    with {:ok, invoice} <- Stripe.get_invoice(invoice_id) do
      case period_for(invoice) do
        %Period{} = period -> tie(period, invoice)
        nil -> {:ok, :not_ours}
      end
    end
  end

  defp tie(period, %{"id" => invoice_id, "status" => status}) do
    {:ok, meter_check} =
      Repo.transact(fn ->
        {_tied, checks} =
          Repo.update_all(
            from(p in Period,
              where:
                p.id == ^period.id and
                  (is_nil(p.stripe_invoice_id) or p.stripe_invoice_id == ^invoice_id),
              select: p.meter_check
            ),
            set: [stripe_invoice_id: invoice_id]
          )

        {:ok, _job} = Oban.insert(ReportWorker.new(%{period_id: period.id}))
        {:ok, List.first(checks)}
      end)

    if meter_check == :mismatched and status == "draft",
      do: hold(invoice_id),
      else: {:ok, :tied}
  end

  @doc "Stops Stripe sending a draft invoice for payment on its own."
  @spec hold(String.t()) :: {:ok, :held} | Stripe.error()
  def hold(invoice_id) do
    with {:ok, _invoice} <- Stripe.hold_invoice(invoice_id) do
      Logger.error("billing invoice held invoice=#{invoice_id}")
      {:ok, :held}
    end
  end

  @doc "Records whether a period's finalised invoice bills what the ledger counted."
  @spec finalized(String.t()) :: {:ok, atom()} | Stripe.error()
  def finalized(invoice_id) do
    with {:ok, invoice} <- Stripe.get_invoice(invoice_id) do
      case period_for(invoice) do
        %Period{} = period -> check(period, invoice)
        nil -> {:ok, :not_ours}
      end
    end
  end

  defp check(period, invoice) do
    billed = agents_billed(invoice)

    fee =
      period.active_agents
      |> Price.fee_cents()
      |> Decimal.round(0, :half_up)
      |> Decimal.to_integer()

    outcome =
      if Decimal.equal?(billed, period.active_agents) and invoice["total_excluding_tax"] == fee,
        do: :matched,
        else: :mismatched

    Repo.update_all(from(p in Period, where: p.id == ^period.id), set: [invoice_check: outcome])

    if outcome == :mismatched do
      Logger.error(
        "billing check failed check=invoice period=#{period.id} invoice=#{invoice["id"]} " <>
          "ledger_agents=#{period.active_agents} billed_agents=#{billed} " <>
          "fee_cents=#{fee} total_cents=#{invoice["total_excluding_tax"]}"
      )

      :telemetry.execute([:siwa_server, :billing, :check_failed], %{}, %{check: "invoice"})
    end

    {:ok, outcome}
  end

  # A period's own invoice is the one Stripe makes when the subscription moves to
  # its next period, and it covers exactly the period that ended.
  defp period_for(%{
         "billing_reason" => "subscription_cycle",
         "customer" => stripe_customer_id,
         "period_end" => period_end
       }) do
    Repo.one(
      from p in Period,
        join: c in assoc(p, :customer),
        where:
          c.stripe_customer_id == ^stripe_customer_id and
            p.ends_at == ^Subscription.unix(period_end)
    )
  end

  defp period_for(_other_invoice), do: nil
end
