defmodule SiwaServer.Repo.Migrations.AddStripeBilling do
  @moduledoc """
  Billing through Stripe (`SiwaServer.Billing.Subscription`,
  `SiwaServer.Billing.ReportWorker`, `SiwaServer.Billing.ReconcileWorker`). It
  only adds: nullable columns and one with a constant default, their indexes and
  checks, and the table that records each Stripe notice once. Nothing existing
  is rewritten, so the release still running beside it reads and writes as before.
  """

  use Ecto.Migration

  def change do
    alter table(:customers) do
      add :stripe_customer_id, :text
      add :stripe_subscription_id, :text
      add :subscription_status, :text
      add :stripe_synced_at, :timestamptz
    end

    create unique_index(:customers, [:stripe_customer_id])
    create unique_index(:customers, [:stripe_subscription_id])

    alter table(:billing_periods) do
      add :reported_agents, :integer, null: false, default: 0
      add :reported_at, :timestamptz
      add :final_reported_at, :timestamptz
      add :stripe_invoice_id, :text
      add :meter_check, :text
      add :invoice_check, :text
    end

    create unique_index(:billing_periods, [:stripe_invoice_id])

    create constraint(:billing_periods, :reported_agents_not_negative,
             check: "reported_agents >= 0"
           )

    create constraint(:billing_periods, :meter_check_is_known,
             check: "meter_check IN ('matched', 'mismatched')"
           )

    create constraint(:billing_periods, :invoice_check_is_known,
             check: "invoice_check IN ('matched', 'mismatched')"
           )

    create table(:stripe_events, primary_key: false) do
      add :id, :text, primary_key: true
      add :type, :text, null: false
      add :inserted_at, :timestamptz, null: false, default: fragment("now()")
    end
  end
end
