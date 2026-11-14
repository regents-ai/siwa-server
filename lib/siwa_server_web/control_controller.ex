defmodule SiwaServerWeb.ControlController do
  @moduledoc """
  The control API a Regent site calls for its signed-in person
  (`/api/control/v1`): the person's customer, its sites and each site's server
  keys (`SiwaServer.Customers`). The person is the one the control token names
  (`SiwaServerWeb.Plugs.ControlPerson`); nothing in a request chooses whose
  records it reaches.
  """

  use SiwaServerWeb, :controller

  alias SiwaServer.Customers

  action_fallback SiwaServerWeb.FallbackController

  def account(conn, _params) do
    did = conn.assigns.did

    json(conn, %{
      "code" => "account",
      "data" => %{"did" => did, "customer" => did |> Customers.customer() |> customer()}
    })
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
      "createdAt" => time(customer.inserted_at),
      "updatedAt" => time(customer.updated_at)
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
