defmodule SiwaServer.Repo.Migrations.CreateCustomersSitesAndSiteCredentials do
  @moduledoc """
  The paid product's customers, their sites and each site's server keys
  (`SiwaServer.Customers`). It only adds tables and the one function their
  checks use. No foreign key cascades: an archived site and a revoked key are
  kept.
  """

  use Ecto.Migration

  def change do
    create table(:customers, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :owner_did, :text, null: false
      add :name, :text, null: false
      add :kind, :text, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:customers, [:owner_did])
    create constraint(:customers, :name_length, check: "char_length(name) BETWEEN 1 AND 100")

    create constraint(:customers, :kind_is_paid_or_internal,
             check: "kind IN ('paid', 'internal')"
           )

    # A check constraint cannot hold a subquery, so comparing an array's
    # elements needs a function of its own.
    execute(
      """
      CREATE FUNCTION siwa_distinct_origins(origins text[]) RETURNS boolean
      LANGUAGE sql IMMUTABLE STRICT
      AS $$ SELECT count(DISTINCT origin) = cardinality(origins) FROM unnest(origins) AS origin $$
      """,
      "DROP FUNCTION siwa_distinct_origins(text[])"
    )

    create table(:sites, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :customer_id, references(:customers, type: :binary_id), null: false
      add :name, :text, null: false
      add :audience, :text, null: false
      add :environment, :text, null: false
      add :origins, {:array, :text}, null: false
      add :origin_proof, :text
      add :archived_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:sites, [:customer_id])
    # Over every site, archived ones too: an audience is never handed out twice.
    create unique_index(:sites, [:audience])
    create constraint(:sites, :name_length, check: "char_length(name) BETWEEN 1 AND 100")

    create constraint(:sites, :environment_is_sandbox_or_production,
             check: "environment IN ('sandbox', 'production')"
           )

    create constraint(:sites, :origins_count, check: "cardinality(origins) BETWEEN 1 AND 10")
    create constraint(:sites, :origins_distinct, check: "siwa_distinct_origins(origins)")

    create constraint(:sites, :origin_proof_for_production_only,
             check: """
             (environment = 'production' AND origin_proof IS NOT NULL
               AND origin_proof IN ('unverified', 'verified'))
             OR (environment = 'sandbox' AND origin_proof IS NULL)
             """
           )

    create table(:site_credentials, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :site_id, references(:sites, type: :binary_id), null: false
      add :key_hash, :binary, null: false
      add :prefix, :text, null: false
      add :revoked_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:site_credentials, [:site_id])
    create unique_index(:site_credentials, [:key_hash])

    create constraint(:site_credentials, :key_hash_is_sha256,
             check: "octet_length(key_hash) = 32"
           )

    create constraint(:site_credentials, :prefix_shape,
             check: "prefix ~ '^siwa_sk_(test|live)_[A-Za-z0-9_-]{6}$'"
           )
  end
end
