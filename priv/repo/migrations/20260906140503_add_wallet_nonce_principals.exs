defmodule SiwaServer.Repo.Migrations.AddWalletNoncePrincipals do
  use Ecto.Migration

  def up do
    alter table(:siwa_nonces) do
      add :principal_kind, :string, null: false, default: "agent"
      add :chain_id, :bigint
      add :canonical_message, :text
      modify :agent_id, :text, null: true
      modify :agent_registry, :string, null: true
    end

    create constraint(:siwa_nonces, :siwa_nonces_principal_shape,
             check: """
             (principal_kind = 'agent' AND agent_id IS NOT NULL AND agent_registry IS NOT NULL
               AND chain_id IS NULL AND canonical_message IS NULL)
             OR
             (principal_kind = 'wallet' AND agent_id IS NULL AND agent_registry IS NULL
               AND chain_id IS NOT NULL AND chain_id = 8453 AND canonical_message IS NOT NULL)
             """
           )
  end

  def down do
    execute """
    DO $$ BEGIN
      IF EXISTS (SELECT 1 FROM siwa_nonces WHERE principal_kind = 'wallet') THEN
        RAISE EXCEPTION 'wallet nonces remain; do not discard active challenges during rollback';
      END IF;
    END $$
    """

    drop constraint(:siwa_nonces, :siwa_nonces_principal_shape)

    alter table(:siwa_nonces) do
      modify :agent_id, :text, null: false
      modify :agent_registry, :string, null: false
      remove :principal_kind
      remove :chain_id
      remove :canonical_message
    end
  end
end
