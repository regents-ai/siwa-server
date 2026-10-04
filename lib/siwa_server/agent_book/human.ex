defmodule SiwaServer.AgentBook.Human do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  @primary_key {:wallet_address, :string, autogenerate: false}

  schema "agent_book_humans" do
    field :human_id, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:wallet_address, :human_id])
    |> validate_required([:wallet_address, :human_id])
  end

  def for_wallet(wallet_address),
    do: from(h in __MODULE__, where: h.wallet_address == ^wallet_address)
end
