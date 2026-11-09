defmodule SiwaServer.AgentRegistration.Link do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:wallet_address, :string, autogenerate: false}

  schema "agent_registry_links" do
    field :token_id, :string
    field :profile_url, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:wallet_address, :token_id, :profile_url])
    |> validate_required([:wallet_address, :token_id])
  end
end
