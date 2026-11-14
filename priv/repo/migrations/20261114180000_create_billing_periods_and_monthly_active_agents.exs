defmodule SiwaServer.Repo.Migrations.CreateBillingPeriodsAndMonthlyActiveAgents do
  @moduledoc """
  Each customer's billing periods and the agents counted in them
  (`SiwaServer.Billing`), and the cap a customer sets for its periods. It only
  adds: two tables, one nullable column, and `btree_gist`, which the rule that
  one customer's periods never overlap needs to compare a customer id inside a
  range index. No foreign key cascades.
  """

  use Ecto.Migration

  def change do
    alter table(:customers) do
      add :cap_cents, :integer
    end

    create constraint(:customers, :cap_cents_at_least_minimum,
             check: "cap_cents IS NULL OR cap_cents >= 9900"
           )

    execute("CREATE EXTENSION IF NOT EXISTS btree_gist", "DROP EXTENSION IF EXISTS btree_gist")

    create table(:billing_periods, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :customer_id, references(:customers, type: :binary_id), null: false
      add :starts_at, :timestamptz, null: false
      add :ends_at, :timestamptz, null: false
      add :cap_cents, :integer
      add :max_agents, :integer
      add :active_agents, :integer, null: false, default: 0
      add :price_version, :text, null: false, default: "v1"

      timestamps(type: :utc_datetime)
    end

    # Start inclusive, end exclusive: one period may begin exactly where another ends.
    create constraint(:billing_periods, :periods_do_not_overlap,
             exclude: ~s|gist (customer_id WITH =, tstzrange(starts_at, ends_at, '[)') WITH &&)|
           )

    create constraint(:billing_periods, :ends_after_start, check: "ends_at > starts_at")

    create constraint(:billing_periods, :cap_cents_at_least_minimum,
             check: "cap_cents IS NULL OR cap_cents >= 9900"
           )

    create constraint(:billing_periods, :max_agents_with_cap,
             check:
               "(cap_cents IS NULL) = (max_agents IS NULL) AND (max_agents IS NULL OR max_agents >= 1000)"
           )

    create constraint(:billing_periods, :active_agents_within_cap,
             check: "active_agents >= 0 AND (max_agents IS NULL OR active_agents <= max_agents)"
           )

    # The pair an agent row names, so a row can only belong to its period's customer.
    create unique_index(:billing_periods, [:id, :customer_id])

    create table(:monthly_active_agents, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :billing_period_id,
          references(:billing_periods,
            type: :binary_id,
            with: [customer_id: :customer_id],
            match: :full
          ),
          null: false

      add :customer_id, references(:customers, type: :binary_id), null: false
      add :subject, :text, null: false
      add :first_site_id, references(:sites, type: :binary_id), null: false
      add :first_verified_at, :timestamptz, null: false
    end

    create unique_index(:monthly_active_agents, [:billing_period_id, :subject])

    create index(
             :monthly_active_agents,
             [:billing_period_id, "first_verified_at DESC", "id DESC"],
             name: :monthly_active_agents_newest_first_index
           )

    create index(:monthly_active_agents, [:customer_id])
    create index(:monthly_active_agents, [:first_site_id])

    create constraint(:monthly_active_agents, :subject_shape,
             check: "subject ~ '^eip155:[1-9][0-9]*:0x[0-9a-f]{40}$'"
           )
  end
end
