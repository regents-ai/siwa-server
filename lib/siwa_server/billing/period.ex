defmodule SiwaServer.Billing.Period do
  @moduledoc """
  One billing period of a customer: from `starts_at` (inclusive) to `ends_at`
  (exclusive), in UTC. It keeps the customer's cap when it opened or was last
  set (`cap_cents`, nil for none), the most agents that cap pays for
  (`max_agents`, `SiwaServer.Billing.Price`), how many agents it has counted
  (`active_agents`) and the price it is billed at (`price_version`).

  No two periods of one customer overlap, `active_agents` never passes
  `max_agents`, and a cap is never below the minimum fee: the database holds
  each rule as well as this changeset.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias SiwaServer.Customers.Customer

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "billing_periods" do
    belongs_to :customer, Customer
    field :starts_at, :utc_datetime_usec
    field :ends_at, :utc_datetime_usec
    field :cap_cents, :integer
    field :max_agents, :integer
    field :active_agents, :integer, default: 0
    field :price_version, :string, default: "v1"

    timestamps(type: :utc_datetime)
  end

  @doc "A new period from its start and end."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(period, params) do
    period
    |> cast(params, [:starts_at, :ends_at])
    |> validate_required([:starts_at, :ends_at])
    |> validate_ends_after_start()
    |> check_constraint(:ends_at, name: :ends_after_start)
    |> exclusion_constraint(:starts_at, name: :periods_do_not_overlap)
  end

  defp validate_ends_after_start(changeset) do
    with %DateTime{} = starts_at <- get_field(changeset, :starts_at),
         %DateTime{} = ends_at <- get_field(changeset, :ends_at),
         :gt <- DateTime.compare(ends_at, starts_at) do
      changeset
    else
      nil -> changeset
      _not_after -> add_error(changeset, :ends_at, "must be after starts_at")
    end
  end
end
