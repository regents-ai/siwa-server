defmodule SiwaServer.AgentRegistration.Record do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "agent_registrations" do
    field :profile_id, :string
    field :wallet_address, :string
    field :name, :string
    field :description, :string
    field :image, :string
    field :token_id, :string
    field :tx_hash, :string

    timestamps(type: :utc_datetime)
  end
end
