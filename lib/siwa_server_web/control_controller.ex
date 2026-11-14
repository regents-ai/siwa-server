defmodule SiwaServerWeb.ControlController do
  @moduledoc """
  The control API a Regent site calls for its signed-in person
  (`/api/control/v1`): the person's customer, its cap and usage this billing
  period, the agents counted in it, its sites and each site's server keys
  (`SiwaServer.Customers`). The person is the one the control token names
  (`SiwaServerWeb.Plugs.ControlPerson`); nothing in a request chooses whose
  records it reaches.
  """

  use SiwaServerWeb, :controller

  alias SiwaServer.Billing.Price
  alias SiwaServer.Customers

  action_fallback SiwaServerWeb.FallbackController

  def account(conn, _params) do
    did = conn.assigns.did
    %{customer: found, period: period} = Customers.account(did)

    json(conn, %{
      "code" => "account",
      "data" => %{"did" => did, "customer" => customer(found), "usage" => usage(period)}
    })
  end

  def put_cap(conn, _params) do
    with {:ok, {updated, period}} <- Customers.set_cap(conn.assigns.did, conn.body_params),
         do:
           answer(conn, :ok, "cap_updated", %{
             "customer" => customer(updated),
             "usage" => usage(period)
           })
  end

  def agents(conn, _params) do
    with {:ok, {agents, next}} <- Customers.agents(conn.assigns.did, conn.query_params),
         do:
           answer(conn, :ok, "agents", %{"agents" => Enum.map(agents, &agent/1), "next" => next})
  end

  def create_customer(conn, _params) do
    with {:ok, created} <- Customers.create_customer(conn.assigns.did, conn.body_params),
         do: answer(conn, :created, "customer_created", customer(created))
  end

  def update_customer(conn, _params) do
    with {:ok, updated} <- Customers.update_customer(conn.assigns.did, conn.body_params),
         do: answer(conn, :ok, "customer_updated", customer(updated))
  end

  def sites(conn, _params) do
    with {:ok, sites} <- Customers.list_sites(conn.assigns.did),
         do: answer(conn, :ok, "sites", %{"sites" => Enum.map(sites, &site/1)})
  end

  def site(conn, %{"id" => id}) do
    with {:ok, found} <- Customers.get_site(conn.assigns.did, id),
         do: answer(conn, :ok, "site", site(found))
  end

  def create_site(conn, _params) do
    with {:ok, created} <- Customers.create_site(conn.assigns.did, conn.body_params),
         do: answer(conn, :created, "site_created", site(created))
  end

  def update_site(conn, %{"id" => id}) do
    with {:ok, updated} <- Customers.update_site(conn.assigns.did, id, conn.body_params),
         do: answer(conn, :ok, "site_updated", site(updated))
  end

  def archive_site(conn, %{"id" => id}) do
    with {:ok, archived} <- Customers.archive_site(conn.assigns.did, id),
         do: answer(conn, :ok, "site_archived", site(archived))
  end

  def keys(conn, %{"id" => id}) do
    with {:ok, keys} <- Customers.list_keys(conn.assigns.did, id),
         do: answer(conn, :ok, "site_keys", %{"keys" => Enum.map(keys, &key/1)})
  end

  # The only answer that ever holds a key.
  def create_key(conn, %{"id" => id}) do
    with {:ok, {secret, created}} <- Customers.create_key(conn.assigns.did, id),
         do: answer(conn, :created, "site_key_created", Map.put(key(created), "key", secret))
  end

  def revoke_key(conn, %{"id" => id, "key_id" => key_id}) do
    with {:ok, revoked} <- Customers.revoke_key(conn.assigns.did, id, key_id),
         do: answer(conn, :ok, "site_key_revoked", key(revoked))
  end

  defp answer(conn, status, code, data) do
    conn
    |> put_status(status)
    |> json(%{"code" => code, "data" => data})
  end

  defp customer(nil), do: nil

  defp customer(customer) do
    %{
      "id" => customer.id,
      "name" => customer.name,
      "kind" => customer.kind,
      "capCents" => customer.cap_cents,
      "createdAt" => time(customer.inserted_at),
      "updatedAt" => time(customer.updated_at)
    }
  end

  # The fee is in cents with one decimal place, sent as a string so it stays exact.
  defp usage(nil), do: nil

  defp usage(period) do
    %{
      "periodStartsAt" => time(period.starts_at),
      "periodEndsAt" => time(period.ends_at),
      "activeAgents" => period.active_agents,
      "includedAgents" => Price.included_agents(),
      "feeCents" => period.active_agents |> Price.fee_cents() |> Decimal.to_string(:normal),
      "capCents" => period.cap_cents,
      "maxAgents" => period.max_agents
    }
  end

  defp agent(agent) do
    %{
      "subject" => agent.subject,
      "firstVerifiedAt" => time(agent.first_verified_at),
      "firstSiteId" => agent.first_site_id
    }
  end

  defp site(site) do
    %{
      "id" => site.id,
      "name" => site.name,
      "audience" => site.audience,
      "environment" => site.environment,
      "origins" => site.origins,
      "originProof" => site.origin_proof,
      "archivedAt" => time(site.archived_at),
      "createdAt" => time(site.inserted_at),
      "updatedAt" => time(site.updated_at)
    }
  end

  defp key(credential) do
    %{
      "id" => credential.id,
      "prefix" => credential.prefix,
      "createdAt" => time(credential.inserted_at),
      "revokedAt" => time(credential.revoked_at)
    }
  end

  defp time(nil), do: nil
  defp time(at), do: DateTime.to_iso8601(at)
end
