defmodule SiwaServer.Billing.ReportWorker do
  @moduledoc """
  Reports a paid customer's period to Stripe: the period's whole count of
  agents so far, as one meter event, whenever it has risen past the count last
  sent, and once more, as its final count, after the period ends. Stripe's meter
  keeps the value of the latest event in a period (`last`), and that is what the
  invoice bills.

  ## Why the latest event always carries the highest count

  Stripe orders a period's events by the timestamp each carries, not by when it
  arrives, and its timestamps are whole seconds. So the event with the latest
  timestamp must carry the highest count:

    * The count and the database clock are read in one statement. It sees every
      counting transaction that committed before it began
      (`SiwaServer.Billing.count_agent/3`) and none after, and the clock it reads
      is when it began. Counts only rise, so a read made later never sees less.
    * A running report carries the second it was read in, and before it is sent
      that second is written to the period (`reported_at`), only if it is later
      than the second already there. So no two reports share a second, and of
      two reports the one with the later second was read later and carries at
      least the other's count. The one that finds its second taken reads again.
    * A running report is never timed later than two seconds before the minute
      the period ends in begins; one read later still is timed there, and only
      one can take that second.
    * The final report is read after the period ends and a grace has passed, so
      every transaction that counted in the period has committed and its count
      is the period's whole count. It is timed one second before the minute the
      period ends in begins, later than every running report, and it is sent
      even when it equals the count already sent.

  Stripe bills an invoice line from the minute its period starts in to the
  minute it ends in, so every report is timed before the minute the period ends
  in begins. Whether Stripe counts a period by those minutes or by its exact
  seconds, every report lands in its own period.

  Each event's identifier is the period and the count (and `final` for the
  final), so sending one again is harmless: Stripe keeps the first and refuses
  the copy, and that refusal counts as sent. The count sent is recorded only
  upward. One job per period exists at a time besides.

  Jobs are queued by `SiwaServer.Billing.SweepWorker` every five minutes and by
  the period's draft invoice (`SiwaServer.Billing.Invoices.drafted/1`). The
  final report queues the period's check (`SiwaServer.Billing.ReconcileWorker`).
  """

  use Oban.Worker,
    queue: :stripe,
    max_attempts: 20,
    unique: [keys: [:period_id], period: :infinity, states: :incomplete]

  import Ecto.Query

  alias SiwaServer.Billing.{Period, ReconcileWorker, Stripe}
  alias SiwaServer.{Config, Repo}

  # A counting transaction that found its period just before it ended commits
  # well within this; the final count is read after it.
  @grace_seconds 60

  @doc "How long after a period ends its final count is read."
  @spec grace_seconds() :: pos_integer()
  def grace_seconds, do: @grace_seconds

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"period_id" => period_id}}) do
    with {:ok, %{meter_event_name: event_name}} <- configured(),
         {:ok, state} <- read(period_id) do
      report(state, event_name)
    end
  end

  defp configured do
    case Config.stripe() do
      {:ok, stripe} -> {:ok, stripe}
      :error -> {:cancel, :billing_not_configured}
    end
  end

  defp read(period_id) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT p.active_agents, p.reported_agents, p.final_reported_at, p.ends_at,
               c.stripe_customer_id, now()
        FROM billing_periods AS p
        JOIN customers AS c ON c.id = p.customer_id
        WHERE p.id = $1
        """,
        [Ecto.UUID.dump!(period_id)]
      )

    case rows do
      [[count, reported, final_at, ends_at, stripe_customer_id, now]] ->
        {:ok,
         %{
           period_id: period_id,
           count: count,
           reported: reported,
           final_at: final_at,
           ends_at: DateTime.to_unix(ends_at),
           stripe_customer_id: stripe_customer_id,
           now: DateTime.to_unix(now)
         }}

      [] ->
        {:cancel, :period_not_found}
    end
  end

  defp report(%{final_at: %DateTime{}}, _event_name), do: :ok
  defp report(%{stripe_customer_id: nil}, _event_name), do: {:cancel, :no_stripe_customer}

  defp report(%{now: now, ends_at: ends_at} = state, event_name) do
    final_at = ends_at + @grace_seconds

    cond do
      now >= final_at -> send_final(state, event_name)
      now >= ends_at -> {:snooze, final_at - now}
      state.count <= state.reported -> :ok
      true -> send_running(state, event_name, final_at)
    end
  end

  defp send_running(state, event_name, final_at) do
    at = min(state.now, minute_start(state.ends_at) - 2)

    cond do
      reserve(state.period_id, at) ->
        with :ok <- send_event(state, event_name, "#{state.period_id}:#{state.count}", at),
             do: record(state)

      # The last second a running report may take is taken: only the final is left.
      at < state.now ->
        {:snooze, final_at - state.now}

      true ->
        {:snooze, 1}
    end
  end

  defp send_final(state, event_name) do
    at = minute_start(state.ends_at) - 1

    with :ok <- send_event(state, event_name, "#{state.period_id}:final:#{state.count}", at),
         {:ok, _job} <- Repo.transact(fn -> finish(state) end) do
      :ok
    end
  end

  defp send_event(state, event_name, identifier, at),
    do: Stripe.send_meter_event(event_name, state.stripe_customer_id, state.count, identifier, at)

  defp reserve(period_id, at) do
    second = DateTime.from_unix!(at * 1_000_000, :microsecond)

    {reserved, _rows} =
      period_id
      |> period()
      |> where([p], is_nil(p.reported_at) or p.reported_at < ^second)
      |> Repo.update_all(set: [reported_at: second])

    reserved == 1
  end

  defp record(state) do
    {1, _rows} = state.period_id |> period() |> raise_reported(state.count) |> Repo.update_all([])
    :ok
  end

  defp finish(state) do
    {1, _rows} =
      state.period_id
      |> period()
      |> raise_reported(state.count)
      |> update([p], set: [final_reported_at: fragment("now()")])
      |> Repo.update_all([])

    Oban.insert(ReconcileWorker.new(%{period_id: state.period_id}))
  end

  defp period(period_id), do: from(p in Period, where: p.id == ^period_id)

  defp raise_reported(query, count),
    do:
      update(query, [p],
        set: [reported_agents: fragment("GREATEST(?, ?)", p.reported_agents, ^count)]
      )

  @doc "The unix second the whole minute `unix` falls in begins at."
  @spec minute_start(integer()) :: integer()
  def minute_start(unix), do: unix - Integer.mod(unix, 60)
end
