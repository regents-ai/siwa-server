defmodule SiwaServer.Repo.Migrations.CreateSiwaHostedIdentities do
  use Ecto.Migration

  # One row per hosted connection: its signing key, encrypted with the key store
  # password, so every machine signs with the same key.
  def change do
    create table(:siwa_hosted_identities, primary_key: false) do
      add :identity, :text, primary_key: true
      add :encrypted_wallet, :text, null: false

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'UTC')")
    end

    create constraint(:siwa_hosted_identities, :identity_is_sha256_hex,
             check: "identity ~ '^[a-f0-9]{64}$'"
           )
  end
end
