defmodule SiwaServer.CustomersConcurrencyTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias SiwaServer.{Customers, Repo}
  alias SiwaServer.Customers.{Customer, Site, SiteCredential}

  test "keys made at once over independent connections never pass the limit of five" do
    assert String.starts_with?(Repo.config()[:database], "siwa_server_test")
    did = "did:privy:#{Ecto.UUID.generate()}"

    site =
      Sandbox.unboxed_run(Repo, fn ->
        {:ok, _customer} = Customers.create_customer(did, %{"name" => "Acme"})

        {:ok, site} =
          Customers.create_site(did, %{
            "name" => "Acme sandbox",
            "audience" => "concurrency-#{System.unique_integer([:positive])}",
            "environment" => "sandbox",
            "origins" => ["http://localhost:3000"]
          })

        site
      end)

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(from k in SiteCredential, where: k.site_id == ^site.id)
        Repo.delete_all(from s in Site, where: s.id == ^site.id)
        Repo.delete_all(from c in Customer, where: c.owner_did == ^did)
      end)
    end)

    results =
      1..8
      |> Task.async_stream(
        fn _ -> Sandbox.unboxed_run(Repo, fn -> Customers.create_key(did, site.id) end) end,
        max_concurrency: 8
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, {_key, _credential}}, &1)) == 5
    assert Enum.count(results, &match?({:error, {409, "site_key_limit", _}}, &1)) == 3
  end
end
