defmodule SiwaServer.Customers.Customer do
  @moduledoc """
  A company that uses the paid product. In this slice each person owns at most
  one, named by their Privy DID (`owner_did`), and every customer made through
  the control API is `paid`. `cap_cents` is the most it pays a billing period,
  copied into each period it opens (`SiwaServer.Billing`); nil for no cap.

  A paid customer is billed through Stripe (`SiwaServer.Billing.Subscription`):
  its Stripe customer, the subscription it pays through and that subscription's
  status as last read from Stripe, at `stripe_synced_at` by the database clock.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "customers" do
    field :owner_did, :string
    field :name, :string
    field :kind, Ecto.Enum, values: [:paid, :internal]
    field :cap_cents, :integer
    field :stripe_customer_id, :string
    field :stripe_subscription_id, :string
    field :subscription_status, :string
    field :stripe_synced_at, :utc_datetime_usec

    timestamps(type: :utc_datetime)
  end

  @doc "The name its owner gives it, of 1 to 100 characters."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(customer, params) do
    customer
    |> cast(params, [:name])
    |> update_change(:name, &(&1 && String.trim(&1)))
    |> validate_required([:name])
    |> validate_length(:name, max: 100, count: :codepoints)
    |> unique_constraint(:owner_did)
    |> check_constraint(:name, name: :name_length)
  end
end
