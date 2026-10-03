defmodule SiwaServer.Repo.Migrations.AllowEthereumWalletNonces do
  use Ecto.Migration

  def up do
    drop constraint(:siwa_nonces, :siwa_nonces_principal_shape)

    create constraint(:siwa_nonces, :siwa_nonces_principal_shape,
             check: principal_shape("1, 8453")
           )
  end

  def down do
    drop constraint(:siwa_nonces, :siwa_nonces_principal_shape)
    create constraint(:siwa_nonces, :siwa_nonces_principal_shape, check: principal_shape("8453"))
  end

  defp principal_shape(wallet_chain_ids) do
    """
    (principal_kind = 'agent' AND agent_id IS NOT NULL AND agent_registry IS NOT NULL
      AND chain_id IS NULL AND canonical_message IS NULL)
    OR
    (principal_kind = 'wallet' AND agent_id IS NULL AND agent_registry IS NULL
      AND chain_id IS NOT NULL AND chain_id IN (#{wallet_chain_ids})
      AND canonical_message IS NOT NULL)
    """
  end
end
