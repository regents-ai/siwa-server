defmodule SiwaServer.Billing.ReportWorkerTest do
  use SiwaServer.DataCase, async: false
  use ExUnitProperties
  use Oban.Testing, repo: SiwaServer.Repo

  alias SiwaServer.Billing.{Period, ReconcileWorker, ReportWorker, SweepWorker}
  alias SiwaServer.Customers.Customer
  alias SiwaServer.{TestClock, TestStripe}

  # A period of an hour and 17 seconds, so it does not end on a whole minute.
  @starts_at ~U[2026-11-01 10:00:00.000000Z]
  @ends_at ~U[2026-11-01 11:00:17.000000Z]
  # The minute the period ends in begins at 11:00:00.
  @last_minute DateTime.to_unix(~U[2026-11-01 11:00:00Z])

  setup do
    TestClock.start(@starts_at)
    stripe_like()
    :ok
  end

  test "a running report sends the whole count at the second it was read, and only when it rose" do
    period = period(count: 5)
    at(~U[2026-11-01 10:20:30Z])

    assert :ok = report(period)
    assert [{"siwa_active_agents", "cus_report_" <> _n, 5, identifier, at}] = sent()
    assert identifier == "#{period.id}:5"
    assert at == DateTime.to_unix(~U[2026-11-01 10:20:30Z])
    assert %{reported_agents: 5, final_reported_at: nil} = Repo.reload!(period)

    at(~U[2026-11-01 10:25:00Z])
    assert :ok = report(period)
    assert sent() == []
  end

  test "near the end a running report is timed before the minute the period ends in" do
    period = period(count: 3)
    at(~U[2026-11-01 11:00:10Z])

    assert :ok = report(period)
    assert [{_event, _customer, 3, _identifier, at}] = sent()
    assert at == @last_minute - 2

    # That second is taken, so a higher count read later waits for the final.
    count(period, 4)
    at(~U[2026-11-01 11:00:12Z])
    assert {:snooze, 65} = report(period)
    assert sent() == []
  end

  test "the final report waits out the grace, then sends the whole count once, even unchanged" do
    period = period(count: 7, reported: 7)

    at(DateTime.add(@ends_at, 10))
    assert {:snooze, 50} = report(period)
    assert sent() == []

    at(DateTime.add(@ends_at, ReportWorker.grace_seconds()))
    assert :ok = report(period)
    assert [{_event, "cus_report_" <> _n, 7, identifier, at}] = sent()
    assert identifier == "#{period.id}:final:7"
    assert at == @last_minute - 1

    assert %{reported_agents: 7, final_reported_at: %DateTime{}} = Repo.reload!(period)
    assert_enqueued(worker: ReconcileWorker, args: %{period_id: period.id})

    assert :ok = report(period)
    assert sent() == []
  end

  test "an event Stripe already has counts as sent; any other refusal is tried again" do
    period = period(count: 2)
    at(~U[2026-11-01 10:30:00Z])
    stripe_like(already: ["#{period.id}:2"])

    assert :ok = report(period)
    assert %{reported_agents: 2} = Repo.reload!(period)

    count(period, 3)
    at(~U[2026-11-01 10:31:00Z])
    stripe_like(down: true)
    assert {:error, {500, _message}} = report(period)
    assert %{reported_agents: 2} = Repo.reload!(period)
  end

  test "the sweep queues the periods with a report to send, and only those" do
    rising = period(count: 4, reported: 1)
    _sent = period(count: 4, reported: 4)
    ended = period(count: 0, starts_at: ~U[2026-10-01 10:00:00.000000Z], ends_at: @starts_at)
    _internal = period(count: 9, kind: :internal)
    _no_stripe = period(count: 9, stripe_customer_id: nil)

    _final_sent =
      period(
        count: 1,
        starts_at: ~U[2026-09-01 10:00:00.000000Z],
        ends_at: ~U[2026-10-01 10:00:00.000000Z],
        final_reported_at: ~U[2026-10-01 10:02:00.000000Z]
      )

    at(~U[2026-11-01 10:40:00Z])
    assert :ok = perform_job(SweepWorker, %{})

    assert Enum.sort([rising.id, ended.id]) ==
             all_enqueued(worker: ReportWorker) |> Enum.map(& &1.args["period_id"]) |> Enum.sort()
  end

  test "the sweep forgets the records of notices older than thirty days and keeps the rest" do
    at(~U[2026-11-01 10:40:00Z])

    Repo.insert_all("stripe_events", [
      %{id: "evt_old", type: "invoice.created", inserted_at: ~U[2026-10-02 10:39:00.000000Z]},
      %{id: "evt_recent", type: "invoice.created", inserted_at: ~U[2026-10-02 10:41:00.000000Z]}
    ])

    assert :ok = perform_job(SweepWorker, %{})

    assert ["evt_recent"] == Repo.all(from e in "stripe_events", select: e.id)
  end

  # Whatever order counts rise, reports run, fail and are retried, Stripe's last
  # event in the period carries the period's whole count, and no two share a second.
  property "the latest event Stripe holds for a period always carries the highest count" do
    check all steps <- list_of(step(), max_length: 40), max_runs: 300 do
      at(@starts_at)
      period = period(count: 0)

      final =
        Enum.reduce(steps, %{now: @starts_at, count: 0}, fn
          {:wait, seconds}, state ->
            now = DateTime.add(state.now, seconds)
            at(now)
            %{state | now: now}

          # The last minutes around the end are where the timing matters most.
          {:near_end, seconds}, state ->
            now = Enum.max([state.now, DateTime.add(@ends_at, seconds)], DateTime)
            at(now)
            %{state | now: now}

          {:agents, more}, state ->
            # Counting stops when the period ends: the next period counts after it.
            if DateTime.compare(state.now, @ends_at) == :lt do
              count(period, state.count + more)
              %{state | count: state.count + more}
            else
              state
            end

          {:run, outage}, state ->
            stripe_like(down: outage)
            report(period)
            state
        end)

      stripe_like()
      at(DateTime.add(@ends_at, ReportWorker.grace_seconds() + 1))
      assert :ok = report(period)

      held = Process.get(:stripe_events) |> Map.values() |> Enum.sort_by(&elem(&1, 4))
      seconds = Enum.map(held, &elem(&1, 4))
      counts = Enum.map(held, &elem(&1, 2))

      assert seconds == Enum.uniq(seconds)
      assert counts == Enum.sort(counts)
      assert {_event, _customer, last_count, last_identifier, last_second} = List.last(held)
      assert last_count == final.count
      assert last_identifier == "#{period.id}:final:#{final.count}"
      assert last_second == @last_minute - 1
      # Every report lands in its own period, however Stripe rounds it to minutes.
      assert Enum.all?(seconds, &(&1 >= DateTime.to_unix(@starts_at) and &1 < @last_minute))
      Process.delete(:stripe_events)
    end
  end

  defp step do
    one_of([
      tuple({constant(:wait), integer(0..900)}),
      tuple({constant(:wait), integer(0..3)}),
      tuple({constant(:near_end), integer(-90..90)}),
      tuple({constant(:agents), integer(1..50)}),
      tuple({constant(:run), frequency([{4, constant(false)}, {1, constant(true)}])})
    ])
  end

  defp report(period), do: perform_job(ReportWorker, %{period_id: period.id})

  defp at(datetime), do: TestClock.set(datetime)

  defp count(period, count),
    do: Repo.update_all(from(p in Period, where: p.id == ^period.id), set: [active_agents: count])

  # Stripe's meter events: the first with an identifier is kept and a copy refused.
  defp stripe_like(opts \\ []) do
    already = Keyword.get(opts, :already, [])

    TestStripe.answer(fn :post, "/v1/billing/meter_events", params ->
      %{
        event_name: event_name,
        identifier: identifier,
        payload: %{stripe_customer_id: customer, value: value},
        timestamp: at
      } = params

      events = Process.get(:stripe_events, %{})

      cond do
        opts[:down] ->
          {:error, {500, "Stripe is down"}}

        identifier in already or Map.has_key?(events, identifier) ->
          {:error, {400, "An event already exists with identifier #{identifier}."}}

        true ->
          Process.put(
            :stripe_events,
            Map.put(events, identifier, {event_name, customer, value, identifier, at})
          )

          {:ok, %{"identifier" => identifier}}
      end
    end)
  end

  # The meter events sent since the last look, oldest first.
  defp sent do
    events = Process.get(:sent_seen, MapSet.new())
    all = Process.get(:stripe_events, %{}) |> Map.values() |> Enum.sort_by(&elem(&1, 4))
    Process.put(:sent_seen, MapSet.new(all))
    Enum.reject(all, &MapSet.member?(events, &1))
  end

  # A period of its own customer, which Stripe knows as `cus_report_<n>`.
  defp period(opts) do
    customer =
      Repo.insert!(%Customer{
        owner_did: "did:privy:#{Ecto.UUID.generate()}",
        name: "Acme",
        kind: Keyword.get(opts, :kind, :paid),
        subscription_status: "active",
        stripe_customer_id:
          Keyword.get(
            opts,
            :stripe_customer_id,
            "cus_report_#{System.unique_integer([:positive])}"
          )
      })

    Repo.insert!(%Period{
      customer_id: customer.id,
      starts_at: Keyword.get(opts, :starts_at, @starts_at),
      ends_at: Keyword.get(opts, :ends_at, @ends_at),
      active_agents: Keyword.fetch!(opts, :count),
      reported_agents: Keyword.get(opts, :reported, 0),
      final_reported_at: Keyword.get(opts, :final_reported_at)
    })
  end
end
