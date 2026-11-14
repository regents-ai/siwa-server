defmodule SiwaServer.Billing.ActiveAgent do
  @moduledoc """
  An agent counted in a billing period: its subject
  (`eip155:<chain id>:<lowercase address>`), the site it was first verified
  for, and when. One row per period and subject; nothing about any request is
  kept. Rows are written by `SiwaServer.Billing.count_agent/3` only.
  """

  use Ecto.Schema

  alias SiwaServer.Billing.Period
  alias SiwaServer.Customers.{Customer, Site}

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "monthly_active_agents" do
    belongs_to :billing_period, Period
    belongs_to :customer, Customer
    field :subject, :string
    belongs_to :first_site, Site
    field :first_verified_at, :utc_datetime_usec
  end
end
