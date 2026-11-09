defmodule SiwaServer.Repo.Migrations.CreateAgentRegistryLinks do
  @moduledoc """
  The one Base registry listing sites see for each wallet: the one it
  registered through this server or linked last
  (`SiwaServer.AgentRegistration`). Each wallet's newest registration made
  through this server becomes its link, at the profile address this server
  serves it from, which is also the listing's `tokenURI`. Nothing reads
  registrations by wallet any more, so that index goes.
  """

  use Ecto.Migration

  def up do
    create table(:agent_registry_links, primary_key: false) do
      add :wallet_address, :text, primary_key: true
      add :token_id, :text, null: false
      add :profile_url, :text

      timestamps(type: :utc_datetime)
    end

    execute(fn ->
      repo().query!(
        """
        INSERT INTO agent_registry_links (wallet_address, token_id, profile_url, inserted_at, updated_at)
        SELECT DISTINCT ON (wallet_address)
          wallet_address, token_id, $1 || profile_id, inserted_at, inserted_at
        FROM agent_registrations
        ORDER BY wallet_address, inserted_at DESC, token_id DESC
        """,
        [profiles_url()]
      )
    end)

    drop index(:agent_registrations, [:wallet_address, :inserted_at])
  end

  def down do
    create index(:agent_registrations, [:wallet_address, :inserted_at])
    drop table(:agent_registry_links)
  end

  # `SiwaServerWeb.Endpoint.url/0` needs the running endpoint, so the same
  # address is built from its configuration.
  defp profiles_url do
    endpoint = Application.fetch_env!(:siwa_server, SiwaServerWeb.Endpoint)
    url = Keyword.fetch!(endpoint, :url)

    port =
      Keyword.get_lazy(url, :port, fn ->
        endpoint |> Keyword.fetch!(:http) |> Keyword.fetch!(:port)
      end)

    URI.to_string(%URI{
      scheme: Keyword.get(url, :scheme, "http"),
      host: Keyword.fetch!(url, :host),
      port: port
    }) <> "/agent-profiles/"
  end
end
