defmodule SiwaServer.Billing.StripeLiveTest do
  # Billing against Stripe's test mode itself, run once by hand and alone, in
  # about 30 minutes:
  #
  #     STRIPE_TEST_KEY_FILE=<file holding a test-mode key> \
  #       mix test --only stripe_live test/siwa_server/billing/stripe_live_test.exs
  #
  # Everything is real except time: each subscription's first period is made a
  # few minutes long, and an invoice whose meter agreed is finalised here instead
  # of an hour later. Notices are read from Stripe's events list and given to the
  # same code the webhook gives them to. It runs outside the test rollback: every
  # row it makes is removed when it ends, and the Stripe subscriptions it made,
  # tagged siwa_acceptance, are cancelled and listed.
  use ExUnit.Case, async: false
  use Oban.Testing, repo: SiwaServer.Repo

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias SiwaServer.{Billing, Customers, Repo}
  alias SiwaServer.Billing.{Invoices, Notice, Period, ReportWorker, Stripe, StripeSetup}
  alias SiwaServer.Billing.{Subscription, SweepWorker}
  alias SiwaServer.Customers.{Customer, Site}

  @moduletag :stripe_live
  @moduletag timeout: :timer.minutes(60)

  @tag_value "2026-11-15"
  @stripe_tag %{siwa_acceptance: @tag_value}
  @did_prefix "did:privy:siwa-acceptance-"
  @return_url "https://regents.example/billing"
  @first_period_seconds 300
  @tick_ms 5_000

  # The agents counted before the first report, the agents at the period's end,
  # and the invoice Stripe must make for them, in cents.
  @cases [
    none: {0, 0, 9_900},
    one: {1, 1, 9_900},
    under: {999, 999, 9_900},
    included: {1_000, 1_000, 9_900},
    one_over: {1_000, 1_001, 9_910},
    many: {1_500, 2_500, 24_750}
  ]

  # Reported right, then the ledger is changed after the final report: the
  # meter check must catch it and hold the invoice.
  @wrong_ledger {:wrong_ledger, {1_001, 1_001, nil}}

  setup do
    assert String.starts_with?(Repo.config()[:database], "siwa_server_test")

    key = "STRIPE_TEST_KEY_FILE" |> System.fetch_env!() |> File.read!() |> String.trim()

    unless String.starts_with?(key, ["sk_test_", "rk_test_"]),
      do: flunk("STRIPE_TEST_KEY_FILE must hold a Stripe test-mode key")

    stripe = Application.fetch_env!(:siwa_server, :stripe)
    stripe_http = Application.fetch_env!(:siwa_server, :stripe_http)

    on_exit(fn ->
      Application.put_env(:siwa_server, :stripe, stripe)
      Application.put_env(:siwa_server, :stripe_http, stripe_http)
    end)

    Application.put_env(:siwa_server, :stripe_http, Stripe)

    Application.put_env(:siwa_server, :stripe,
      secret_key: key,
      webhook_secret: "whsec_unused_by_this_test",
      price_id: nil,
      meter_event_name: nil,
      portal_origins: ["https://regents.example"]
    )

    [[started_at]] = Sandbox.unboxed_run(Repo, fn -> Repo.query!("SELECT now()").rows end)
    on_exit(fn -> Sandbox.unboxed_run(Repo, fn -> remove_rows(started_at) end) end)
    on_exit(&cancel_subscriptions/0)

    {:ok, setup} = StripeSetup.run(metadata: @stripe_tag)
    config = Application.fetch_env!(:siwa_server, :stripe)

    Application.put_env(
      :siwa_server,
      :stripe,
      Keyword.merge(config, price_id: setup.price_id, meter_event_name: setup.event_name)
    )

    :ok = Sandbox.checkout(Repo, sandbox: false, ownership_timeout: :timer.minutes(70))
    %{setup: setup, started_at: started_at}
  end

  test "agents counted here are billed by Stripe at Price v1, checked, and a wrong ledger held",
       %{setup: setup, started_at: started_at} do
    anchor = System.os_time(:second) + @first_period_seconds

    run = %{
      setup: setup,
      since: DateTime.to_unix(started_at) - 5,
      anchor: Subscription.unix(anchor),
      cases: Map.new([@wrong_ledger | @cases], fn {name, _counts} -> subscribe(name, anchor) end),
      tampered?: false
    }

    deadline = DateTime.add(run.anchor, 35 * 60)

    # Stripe's notices of the new subscriptions set each customer's first period.
    run =
      await(run, "the subscriptions' first periods", deadline, fn run ->
        Enum.all?(run.cases, fn {_name, c} -> first_period(run, c) end)
      end)

    for {name, c} <- run.cases do
      {first, _last, _cents} = counts(name)
      count(c, 0..(first - 1)//1)
    end

    run = tick(run)

    for {name, c} <- run.cases,
        do: assert(first_period(run, c).reported_agents == elem(counts(name), 0), "#{name}")

    # Reporting again, and Stripe given the same report again, change nothing.
    included = run.cases.included
    period = first_period(run, included)
    assert :ok = perform_job(ReportWorker, %{period_id: period.id})

    assert :ok =
             Stripe.send_meter_event(
               setup.event_name,
               included.stripe_customer_id,
               1_000,
               "#{period.id}:1000",
               System.os_time(:second)
             )

    assert first_period(run, included).reported_agents == 1_000

    # Counts rise; the reports follow.
    for {name, c} <- run.cases do
      {first, last, _cents} = counts(name)
      count(c, first..(last - 1)//1)
    end

    run = tick(run)

    for {name, c} <- run.cases,
        do: assert(first_period(run, c).reported_agents == elem(counts(name), 1), "#{name}")

    # Once the period ends, the first verification opens the next one at its end,
    # before Stripe says what comes next.
    run = await(run, "the first period's end", deadline, &past?(&1.anchor, -2))
    Process.sleep(3_000)
    none = Repo.reload!(run.cases.none.customer)

    assert {:ok, %Period{starts_at: next_start, ends_at: next_end}} =
             Billing.period_to_count(none)

    assert next_start == run.anchor
    assert next_end == DateTime.shift(run.anchor, month: 1)

    run =
      await(run, "final reports, drafts and the next periods", deadline, fn run ->
        Enum.all?(run.cases, fn {_name, c} ->
          period = first_period(run, c)
          period.final_reported_at && period.stripe_invoice_id && stripes_next_period?(run, c)
        end)
      end)

    # The next period starts at zero.
    for {name, c} <- run.cases,
        do: assert(Billing.current_period(c.customer).active_agents == 0, "#{name}")

    billed = Map.new(@cases)

    run =
      await(run, "the meter checks", deadline, fn run ->
        Enum.all?(billed, fn {name, _counts} ->
          first_period(run, run.cases[name]).meter_check == :matched
        end)
      end)

    for {name, _counts} <- billed do
      {:ok, _invoice} =
        Stripe.call(
          :post,
          "/v1/invoices/#{first_period(run, run.cases[name]).stripe_invoice_id}/finalize",
          %{}
        )
    end

    run =
      await(run, "the invoice checks", deadline, fn run ->
        Enum.all?(billed, fn {name, _counts} ->
          first_period(run, run.cases[name]).invoice_check
        end)
      end)

    run =
      await(run, "the wrong ledger's meter check", deadline, fn run ->
        first_period(run, run.cases.wrong_ledger).meter_check == :mismatched
      end)

    rows =
      for {name, {_first, agents, cents}} <- [@wrong_ledger | @cases] do
        period = first_period(run, run.cases[name])
        {:ok, invoice} = Stripe.get_invoice(period.stripe_invoice_id)

        %{
          name: name,
          agents: agents,
          ledger: period.active_agents,
          reported: period.reported_agents,
          final_after_end: DateTime.diff(period.final_reported_at, run.anchor),
          expected: cents,
          total: invoice["total"],
          billed: Invoices.agents_billed(invoice),
          status: invoice["status"],
          auto_advance: invoice["auto_advance"],
          meter_check: period.meter_check,
          invoice_check: period.invoice_check
        }
      end

    print(rows)

    for row <- rows,
        do: assert(row.final_after_end >= ReportWorker.grace_seconds(), "#{row.name}")

    for %{name: name, expected: cents} = row <- rows, cents do
      assert row.total == cents, "#{name}"
      assert Decimal.equal?(row.billed, row.agents), "#{name}"
      assert row.meter_check == :matched, "#{name}"
      assert row.invoice_check == :matched, "#{name}"
    end

    assert %{status: "draft", auto_advance: false, meter_check: :mismatched, ledger: 1_002} =
             Enum.find(rows, &(&1.name == :wrong_ledger))

    # The customer's invoices as the control API lists them.
    many = run.cases.many
    {:ok, {invoices, _next}} = Customers.invoices(many.customer.owner_did, %{})
    invoice_id = first_period(run, many).stripe_invoice_id
    assert %{agents: 2_500, total_cents: 24_750} = Enum.find(invoices, &(&1.id == invoice_id))
  end

  test "checkout makes the Stripe customer once, and the billing page opens for it" do
    customer = insert_customer(:pages)

    assert {:ok, "https://checkout.stripe.com/" <> _rest} =
             Subscription.checkout(customer, @return_url, price_id())

    customer = Repo.reload!(customer)
    stripe_customer_id = customer.stripe_customer_id
    {:ok, _tagged} = tag("/v1/customers/#{stripe_customer_id}")

    assert {:ok, %{"name" => "SIWA acceptance pages", "email" => nil, "metadata" => metadata}} =
             Stripe.call(:get, "/v1/customers/#{stripe_customer_id}", %{})

    assert metadata["siwa_customer_id"] == customer.id

    assert {:ok, "https://checkout.stripe.com/" <> _rest} =
             Subscription.checkout(customer, @return_url, price_id())

    assert %{stripe_customer_id: ^stripe_customer_id} = Repo.reload!(customer)

    {:ok, %{"data" => sessions}} =
      Stripe.call(:get, "/v1/checkout/sessions", %{customer: stripe_customer_id, status: "open"})

    assert length(sessions) == 2
    for %{"id" => id} <- sessions, do: {:ok, _expired} = expire(id)

    assert {:ok, "https://billing.stripe.com/" <> _rest} =
             Subscription.portal(customer, @return_url)
  end

  # One paid customer with a production site, its tagged Stripe customer, and a
  # subscription whose first period ends at `anchor`.
  defp subscribe(name, anchor) do
    customer = insert_customer(name)
    slug = String.replace("#{name}-#{binary_part(customer.id, 0, 8)}", "_", "-")

    site =
      Repo.insert!(%Site{
        customer_id: customer.id,
        name: "SIWA acceptance #{name}",
        audience: "siwa-acceptance-" <> slug,
        environment: :production,
        origins: ["https://#{slug}.siwa-acceptance.example"],
        origin_proof: :verified
      })

    {:ok, %{"id" => stripe_customer_id}} =
      Stripe.call(
        :post,
        "/v1/customers",
        %{
          name: customer.name,
          metadata: Map.put(@stripe_tag, :siwa_customer_id, customer.id)
        },
        idempotency_key: "siwa-acceptance-customer-#{customer.id}"
      )

    customer =
      Repo.update!(Ecto.Changeset.change(customer, stripe_customer_id: stripe_customer_id))

    {:ok, %{"id" => subscription_id}} =
      Stripe.call(
        :post,
        "/v1/subscriptions",
        %{
          customer: stripe_customer_id,
          items: [%{price: price_id()}],
          billing_cycle_anchor: anchor,
          proration_behavior: "none",
          metadata: @stripe_tag
        },
        idempotency_key: "siwa-acceptance-subscription-#{customer.id}"
      )

    {name,
     %{
       customer: customer,
       site: site,
       stripe_customer_id: stripe_customer_id,
       subscription_id: subscription_id
     }}
  end

  defp insert_customer(name),
    do:
      Repo.insert!(%Customer{
        owner_did: @did_prefix <> "#{name}-#{System.unique_integer([:positive])}",
        name: "SIWA acceptance #{name}",
        kind: :paid
      })

  defp price_id, do: Application.fetch_env!(:siwa_server, :stripe)[:price_id]

  defp counts(:wrong_ledger), do: elem(@wrong_ledger, 1)
  defp counts(name), do: Keyword.fetch!(@cases, name)

  # Agents counted as a verification counts them: the period to count in, then
  # the agent, in one transaction.
  defp count(%{customer: customer, site: site}, range) do
    customer = Repo.reload!(customer)

    for n <- range,
        do:
          assert(
            {:ok, true} = Repo.transact(fn -> count(customer, site, subject(customer.id, n)) end)
          )
  end

  defp count(customer, site, subject) do
    with {:ok, period} <- Billing.period_to_count(customer),
         do: Billing.count_agent(period, site, subject)
  end

  defp subject(customer_id, n) do
    address = :sha256 |> :crypto.hash("#{customer_id}:#{n}") |> binary_part(0, 20)
    "eip155:8453:0x" <> Base.encode16(address, case: :lower)
  end

  # The customer's current period is the subscription's renewed one, as Stripe has it.
  defp stripes_next_period?(run, c) do
    case Billing.current_period(c.customer) do
      %Period{starts_at: starts_at, ends_at: ends_at} when starts_at == run.anchor ->
        {:ok, %{"items" => %{"data" => [item]}}} = Stripe.get_subscription(c.subscription_id)

        Subscription.unix(item["current_period_start"]) == starts_at and
          Subscription.unix(item["current_period_end"]) == ends_at

      _not_yet ->
        false
    end
  end

  defp first_period(run, %{customer: customer}) do
    Repo.one(
      from p in Period,
        where: p.customer_id == ^customer.id and p.ends_at == ^run.anchor
    )
  end

  # What runs on its own in production: Stripe's notices taken in, the sweep,
  # and the billing jobs that are due. Jobs a job queues wait for the next tick.
  defp tick(run) do
    for event <- events(run), do: {:ok, _outcome} = Notice.record(event)
    :ok = perform_job(SweepWorker, %{})

    Oban.drain_queue(queue: :stripe, with_scheduled: DateTime.utc_now(), with_safety: false)

    wrong = first_period(run, run.cases.wrong_ledger)

    if wrong && wrong.final_reported_at && not run.tampered? do
      {1, _rows} = Repo.update_all(where(Period, id: ^wrong.id), inc: [active_agents: 1])
      %{run | tampered?: true}
    else
      run
    end
  end

  defp await(run, what, deadline, done?) do
    run = tick(run)

    cond do
      done?.(run) ->
        run

      past?(deadline, 0) ->
        flunk("gave up waiting for #{what}")

      true ->
        Process.sleep(@tick_ms)
        await(run, what, deadline, done?)
    end
  end

  defp past?(at, offset_seconds),
    do: DateTime.compare(DateTime.utc_now(), DateTime.add(at, offset_seconds)) != :lt

  # Stripe's notices about this run's customers since it started, oldest first.
  defp events(run) do
    ours = MapSet.new(run.cases, fn {_name, c} -> c.stripe_customer_id end)

    run
    |> all_events(nil, [])
    |> Enum.filter(&(get_in(&1, ["data", "object", "customer"]) in ours))
    |> Enum.sort_by(& &1["created"])
  end

  defp all_events(run, after_id, acc) do
    {:ok, %{"data" => events, "has_more" => more?}} =
      Stripe.call(:get, "/v1/events", %{
        types: Notice.types(),
        created: %{gte: run.since},
        limit: 100,
        starting_after: after_id
      })

    acc = acc ++ events
    if more?, do: all_events(run, List.last(events)["id"], acc), else: acc
  end

  defp tag(path), do: Stripe.call(:post, path, %{metadata: @stripe_tag})

  defp expire(session_id),
    do: Stripe.call(:post, "/v1/checkout/sessions/#{session_id}/expire", %{})

  defp print(rows) do
    columns =
      ~w(name agents ledger reported final_after_end expected total billed status auto_advance meter_check invoice_check)a

    IO.puts("\n| " <> Enum.join(columns, " | ") <> " |")
    IO.puts("|" <> String.duplicate(" --- |", length(columns)))

    for row <- rows,
        do: IO.puts("| " <> Enum.map_join(columns, " | ", &to_string(row[&1])) <> " |")
  end

  # Only subscriptions this test made: its customers' and tagged.
  defp cancel_subscriptions do
    customers =
      Sandbox.unboxed_run(Repo, fn ->
        Repo.all(
          from c in Customer,
            where: like(c.owner_did, ^"#{@did_prefix}%") and not is_nil(c.stripe_customer_id),
            select: c.stripe_customer_id
        )
      end)

    cancelled =
      for customer <- customers,
          {:ok, %{"data" => subscriptions}} =
            Stripe.call(:get, "/v1/subscriptions", %{customer: customer, status: "all"}),
          %{"id" => id, "status" => status, "metadata" => %{"siwa_acceptance" => @tag_value}} <-
            subscriptions,
          status not in ["canceled", "incomplete_expired"] do
        {:ok, _cancelled} = Stripe.call(:delete, "/v1/subscriptions/#{id}", %{})
        id
      end

    IO.puts("\nStripe customers made: #{Enum.join(customers, ", ")}")
    IO.puts("Subscriptions cancelled: #{Enum.join(cancelled, ", ")}")
  end

  defp remove_rows(started_at) do
    ids =
      Repo.all(from c in Customer, where: like(c.owner_did, ^"#{@did_prefix}%"), select: c.id)

    keys = Enum.map(ids, &:crypto.hash(:sha256, &1))

    Repo.delete_all(
      from r in "siwa_rate_limits",
        where: r.name == "siwa_billing_invoices" and r.key in type(^keys, {:array, :binary})
    )

    Repo.delete_all(
      from j in Oban.Job,
        where:
          j.worker in [
            "SiwaServer.Billing.NoticeWorker",
            "SiwaServer.Billing.ReportWorker",
            "SiwaServer.Billing.ReconcileWorker"
          ] and
            j.inserted_at >= ^started_at
    )

    Repo.delete_all(
      from e in "stripe_events", where: e.inserted_at >= type(^started_at, :utc_datetime_usec)
    )

    Repo.delete_all(
      from a in "monthly_active_agents",
        where: a.customer_id in type(^ids, {:array, Ecto.UUID})
    )

    Repo.delete_all(from p in Period, where: p.customer_id in ^ids)
    Repo.delete_all(from s in Site, where: s.customer_id in ^ids)
    Repo.delete_all(from c in Customer, where: c.id in ^ids)
  end
end
