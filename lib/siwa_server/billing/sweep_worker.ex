defmodule SiwaServer.Billing.SweepWorker do
  @moduledoc """
  Queues a report (`SiwaServer.Billing.ReportWorker`) for each paid customer's
  period that has one to send: a running period whose count has risen past the
  count last sent, and an ended period whose final count is not sent yet.
  Oban's cron queues it every five minutes on the `billing` queue, and only one
  exists at a time. Without Stripe settings it queues nothing. Each run also
  forgets the records of Stripe's notices (`SiwaServer.Billing.Notice`) older
  than thirty days.
  """

  use Oban.Worker,
    queue: :billing,
    max_attempts: 1,
    unique: [period: :infinity, states: :incomplete]

  import Ecto.Query

  alias SiwaServer.Billing.{Period, ReportWorker}
  alias SiwaServer.{Config, Repo}

  # Stripe sends a notice again for three days at most; its record is kept well past that.
  @notice_days 30

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    forget_old_notices()

    case Config.stripe() do
      {:ok, _stripe} ->
        Enum.each(due(), fn period_id ->
          {:ok, _job} = Oban.insert(ReportWorker.new(%{period_id: period_id}))
        end)

      :error ->
        :ok
    end
  end

  defp forget_old_notices do
    Repo.delete_all(
      from e in "stripe_events",
        where: e.inserted_at < fragment("now() - make_interval(days => ?)", @notice_days)
    )
  end

  defp due do
    Repo.all(
      from p in Period,
        join: c in assoc(p, :customer),
        where:
          c.kind == :paid and not is_nil(c.stripe_customer_id) and is_nil(p.final_reported_at) and
            p.starts_at <= fragment("now()") and
            (p.ends_at <= fragment("now()") or p.active_agents > p.reported_agents),
        select: p.id
    )
  end
end
