defmodule SiwaServer.AgentRegistration.Link do
  @moduledoc """
  The one Base registry listing sites see for a wallet: the one it registered
  through this server or linked last (`SiwaServer.AgentRegistration`). It is
  `listed` while the registry names the wallet as the agent's owner or agent
  wallet, and `ended` otherwise (`SiwaServer.AgentRegistration.check_owners/0`).
  """

  use Ecto.Schema

  @primary_key {:wallet_address, :string, autogenerate: false}

  schema "agent_registry_links" do
    field :token_id, :string
    field :profile_url, :string
    field :status, Ecto.Enum, values: [:listed, :ended], default: :listed

    timestamps(type: :utc_datetime)
  end
end
