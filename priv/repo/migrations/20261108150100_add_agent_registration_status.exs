defmodule SiwaServer.Repo.Migrations.AddAgentRegistrationStatus do
  use Ecto.Migration

  # Whether the wallet still owns the listing's token on Base
  # (SiwaServer.AgentRegistration.OwnerCheckWorker).
  def change do
    alter table(:agent_registrations) do
      add :status, :text, null: false, default: "listed"
    end

    create constraint(:agent_registrations, :status_is_listed_or_ended,
             check: "status IN ('listed', 'ended')"
           )
  end
end
