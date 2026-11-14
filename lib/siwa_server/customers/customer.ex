defmodule SiwaServer.Customers.Customer do
  @moduledoc """
  A company that uses the paid product. In this slice each person owns at most
  one, named by their Privy DID (`owner_did`), and every customer made through
  the control API is `paid`.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "customers" do
    field :owner_did, :string
    field :name, :string
    field :kind, Ecto.Enum, values: [:paid, :internal]

    timestamps(type: :utc_datetime)
  end

  @doc "The name its owner gives it, of 1 to 100 characters."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(customer, params) do
    customer
    |> cast(params, [:name])
    |> validate_required([:name])
    |> validate_length(:name, max: 100, count: :codepoints)
    |> unique_constraint(:owner_did)
    |> check_constraint(:name, name: :name_length)
  end
end
