defmodule SiwaServer.Repo.Migrations.AddOriginProofChecksToSites do
  @moduledoc """
  What a production site proves its origins with (`SiwaServer.Customers.check_site_proof/2`):
  the token its company publishes at each origin, and the last check's time, the
  first origin it failed on with why, and when the origins were proven.

  It only adds columns. The token is made by the database, as the column's
  default, so adding the column gives every existing site its own token, and a
  site the release before this one makes while both run gets one too.
  """

  use Ecto.Migration

  def change do
    alter table(:sites) do
      add :origin_proof_token, :text,
        null: false,
        default: fragment("'siwa_site_' || replace(gen_random_uuid()::text, '-', '')")

      add :origin_proof_checked_at, :utc_datetime
      add :origin_proof_verified_at, :utc_datetime
      add :origin_proof_failure, :text
      add :origin_proof_failed_origin, :text
    end

    create constraint(:sites, :origin_proof_failure_known,
             check: """
             origin_proof_failure IN
               ('not_https', 'address_not_allowed', 'unreachable', 'redirected',
                'not_found', 'too_large', 'wrong_token')
             """
           )
  end
end
