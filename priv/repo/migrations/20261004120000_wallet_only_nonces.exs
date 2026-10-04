defmodule SiwaServer.Repo.Migrations.WalletOnlyNonces do
  use Ecto.Migration

  # Registry-token sign-in is gone: every challenge is a wallet challenge.
  # Challenges last five minutes and are used up by deleting, so any left from
  # the old sign-in are dropped with it.
  def up do
    execute "DELETE FROM siwa_nonces WHERE principal_kind = 'agent'"

    drop constraint(:siwa_nonces, :siwa_nonces_principal_shape)

    alter table(:siwa_nonces) do
      remove :principal_kind
      remove :agent_id
      remove :agent_registry
      modify :chain_id, :bigint, null: false
      modify :canonical_message, :text, null: false
    end

    create constraint(:siwa_nonces, :siwa_nonces_wallet_chain, check: "chain_id IN (1, 8453)")
  end

  def down do
    drop constraint(:siwa_nonces, :siwa_nonces_wallet_chain)

    alter table(:siwa_nonces) do
      add :principal_kind, :string, null: false, default: "wallet"
      add :agent_id, :text
      add :agent_registry, :string
      modify :chain_id, :bigint, null: true
      modify :canonical_message, :text, null: true
    end

    execute "ALTER TABLE siwa_nonces ALTER COLUMN principal_kind SET DEFAULT 'agent'"

    create constraint(:siwa_nonces, :siwa_nonces_principal_shape,
             check: """
             (principal_kind = 'agent' AND agent_id IS NOT NULL AND agent_registry IS NOT NULL
               AND chain_id IS NULL AND canonical_message IS NULL)
             OR
             (principal_kind = 'wallet' AND agent_id IS NULL AND agent_registry IS NULL
               AND chain_id IS NOT NULL AND chain_id IN (1, 8453)
               AND canonical_message IS NOT NULL)
             """
           )
  end
end
