defmodule SiwaServer.AgentBook.Acceptance do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:wallet_address, :string, autogenerate: false}

  schema "agent_book_acceptances" do
    field :human_id, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:wallet_address, :human_id])
    |> validate_required([:wallet_address, :human_id])
  end
end
