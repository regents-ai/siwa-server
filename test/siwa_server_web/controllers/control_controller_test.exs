defmodule SiwaServerWeb.ControlControllerTest do
  use SiwaServerWeb.ConnCase, async: false

  import Ecto.Query

  alias SiwaServer.{Customers, PrivySignIn, Repo}
  alias SiwaServer.Customers.{Site, SiteCredential}
  alias SiwaServerWeb.ControlToken

  @alice "did:privy:alice"
  @bob "did:privy:bob"
  @sandbox %{
    "name" => "Acme sandbox",
    "audience" => "acme-test",
    "environment" => "sandbox",
    "origins" => ["http://localhost:3000"]
  }
  @production %{
    "name" => "Acme",
    "audience" => "acme",
    "environment" => "production",
    "origins" => ["https://acme.example", "https://app.acme.example"]
  }

  setup do
    PrivySignIn.configure()
    siwa = Application.fetch_env!(:siwa_server, :siwa)
    on_exit(fn -> Application.put_env(:siwa_server, :siwa, siwa) end)

    Application.put_env(
      :siwa_server,
      :siwa,
      Keyword.put(siwa, :wallet_origins, %{"patchbay" => ["https://patchbay.help"]})
    )

    :ok
  end

  test "a person makes their customer, renames it, and cannot make a second" do
    assert %{"code" => "customer_created", "data" => %{"kind" => "paid", "name" => "Acme"}} =
             call(@alice, :post, "/customer", %{"name" => "Acme"}) |> json_response(201)

    assert %{"data" => %{"did" => @alice, "customer" => %{"name" => "Acme"}}} =
             call(@alice, :get, "/account") |> json_response(200)

    assert %{"data" => %{"name" => "Acme Labs"}} =
             call(@alice, :patch, "/customer", %{"name" => "  Acme Labs "}) |> json_response(200)

    assert %{"error" => %{"code" => "customer_exists"}} =
             call(@alice, :post, "/customer", %{"name" => "Again"}) |> json_response(409)

    assert %{"error" => %{"code" => "control_fields_invalid", "fields" => %{"name" => [_]}}} =
             call(@alice, :patch, "/customer", %{"name" => " "}) |> json_response(422)
  end

  test "sites need the person's customer" do
    assert %{"error" => %{"code" => "customer_not_found"}} =
             call(@alice, :get, "/sites") |> json_response(404)

    assert %{"error" => %{"code" => "customer_not_found"}} =
             call(@alice, :post, "/sites", @sandbox) |> json_response(404)
  end

  test "a sandbox site needs no proof; a production one starts unverified" do
    customer(@alice)
    sandbox = create_site(@alice, @sandbox)
    production = create_site(@alice, @production)

    assert %{"environment" => "sandbox", "originProof" => nil, "archivedAt" => nil} = sandbox

    assert %{
             "environment" => "production",
             "originProof" => "unverified",
             "origins" => ["https://acme.example", "https://app.acme.example"]
           } = production

    assert %{"data" => %{"sites" => sites}} = call(@alice, :get, "/sites") |> json_response(200)
    assert Enum.sort(sites) == Enum.sort([sandbox, production])

    assert %{"data" => %{"audience" => "acme"}} =
             call(@alice, :get, "/sites/#{production["id"]}") |> json_response(200)
  end

  test "an audience is taken once over every site, and never one already served" do
    customer(@alice)
    customer(@bob)
    site = create_site(@alice, @production)

    assert taken?(@bob, %{@sandbox | "audience" => "acme"})

    call(@alice, :delete, "/sites/#{site["id"]}") |> json_response(200)
    assert taken?(@bob, %{@sandbox | "audience" => "acme"})
    assert taken?(@alice, %{@sandbox | "audience" => "acme"})
    assert taken?(@bob, %{@sandbox | "audience" => "patchbay"})
    assert taken?(@bob, %{@sandbox | "audience" => "agent-book"})
    assert taken?(@bob, %{@sandbox | "audience" => "agent-link"})

    for audience <- ["Acme", "-acme", "acme.example", "acme\n", String.duplicate("a", 65), ""] do
      assert %{"fields" => %{"audience" => [_]}} =
               invalid(@bob, :post, "/sites", %{@sandbox | "audience" => audience})
    end
  end

  test "origins follow the environment's rule" do
    customer(@alice)

    for {environment, origins} <- [
          {"production", ["http://localhost:3000"]},
          {"production", ["https://acme.example/"]},
          {"production", ["https://Acme.example"]},
          {"sandbox", ["https://acme.example"]},
          {"sandbox", ["http://127.0.0.1:3000"]},
          {"sandbox", ["http://localhost:3000", "http://localhost:3000"]},
          {"sandbox", []},
          {"sandbox", Enum.map(1..11, &"http://localhost:#{3000 + &1}")}
        ] do
      assert %{"fields" => %{"origins" => [_]}} =
               invalid(@alice, :post, "/sites", %{
                 @sandbox
                 | "environment" => environment,
                   "origins" => origins
               })
    end

    assert create_site(@alice, %{
             @sandbox
             | "origins" => Enum.map(1..10, &"http://localhost:#{3000 + &1}")
           })

    production = create_site(@alice, @production)

    assert %{"fields" => %{"origins" => [_]}} =
             invalid(@alice, :patch, "/sites/#{production["id"]}", %{
               "origins" => ["http://localhost:4000"]
             })
  end

  test "changing a production site's origins makes its proof unverified again" do
    customer(@alice)
    %{"id" => id} = create_site(@alice, @production)
    Repo.update_all(from(s in Site, where: s.id == ^id), set: [origin_proof: :verified])

    assert %{"data" => %{"name" => "Acme Web", "originProof" => "verified"}} =
             call(@alice, :patch, "/sites/#{id}", %{"name" => "Acme Web"}) |> json_response(200)

    assert %{"data" => %{"originProof" => "unverified", "origins" => ["https://acme.example"]}} =
             call(@alice, :patch, "/sites/#{id}", %{"origins" => ["https://acme.example"]})
             |> json_response(200)
  end

  test "a site's audience and environment never change, and unknown fields are refused" do
    customer(@alice)
    %{"id" => id} = create_site(@alice, @sandbox)

    for body <- [%{"audience" => "other"}, %{"environment" => "production"}, %{"nme" => "x"}] do
      assert %{"error" => %{"code" => "control_request_invalid"}} =
               call(@alice, :patch, "/sites/#{id}", body) |> json_response(400)
    end

    assert %{"error" => %{"code" => "control_request_invalid"}} =
             call(@alice, :post, "/customer", %{"name" => "Acme", "kind" => "internal"})
             |> json_response(400)
  end

  test "a person reaches nothing of another person's customer" do
    customer(@alice)
    customer(@bob)
    alice_site = create_site(@alice, @production)
    alice_key = create_key(@alice, alice_site["id"])
    bob_site = create_site(@bob, @sandbox)
    site = "/sites/#{alice_site["id"]}"

    for {method, path, body} <- [
          {:get, site, nil},
          {:patch, site, %{"name" => "Mine now"}},
          {:delete, site, nil},
          {:get, site <> "/keys", nil},
          {:post, site <> "/keys", nil},
          {:delete, site <> "/keys/#{alice_key["id"]}", nil},
          {:get, "/sites/not-a-site-id", nil}
        ] do
      assert %{"error" => %{"code" => "site_not_found"}} =
               call(@bob, method, path, body) |> json_response(404)
    end

    assert %{"error" => %{"code" => "site_key_not_found"}} =
             call(@bob, :delete, "/sites/#{bob_site["id"]}/keys/#{alice_key["id"]}")
             |> json_response(404)

    assert %{"data" => %{"sites" => [%{"id" => bob_site_id}]}} =
             call(@bob, :get, "/sites") |> json_response(200)

    assert bob_site_id == bob_site["id"]

    assert %{"data" => %{"name" => "Acme", "archivedAt" => nil}} =
             call(@alice, :get, site) |> json_response(200)

    assert {:ok, _found} = Customers.site_for_key(alice_key["key"])
  end

  test "a key is shown once, kept only as its hash, and finds its site" do
    %{"data" => %{"id" => customer_id}} = customer(@alice)
    sandbox = create_site(@alice, @sandbox)
    production = create_site(@alice, @production)

    created = create_key(@alice, sandbox["id"])
    assert created["key"] =~ ~r/\Asiwa_sk_test_[A-Za-z0-9_-]{43}\z/
    assert String.starts_with?(created["key"], created["prefix"])
    assert create_key(@alice, production["id"])["key"] =~ ~r/\Asiwa_sk_live_[A-Za-z0-9_-]{43}\z/

    assert %{"data" => %{"keys" => [listed]}} =
             call(@alice, :get, "/sites/#{sandbox["id"]}/keys") |> json_response(200)

    assert listed == Map.delete(created, "key")

    assert Repo.one!(from k in SiteCredential, where: k.id == ^created["id"], select: k.key_hash) ==
             :crypto.hash(:sha256, created["key"])

    sandbox_id = sandbox["id"]

    assert {:ok, %{site: %{id: ^sandbox_id}, customer: %{id: ^customer_id}}} =
             Customers.site_for_key(created["key"])

    assert Customers.site_for_key(created["key"] <> "x") == :error
    assert Customers.site_for_key(created["prefix"]) == :error
  end

  test "revoked keys and archived sites' keys find nothing" do
    customer(@alice)
    site = create_site(@alice, @sandbox)
    revoked = create_key(@alice, site["id"])
    kept = create_key(@alice, site["id"])
    path = "/sites/#{site["id"]}/keys/#{revoked["id"]}"

    assert %{"code" => "site_key_revoked", "data" => %{"revokedAt" => revoked_at}} =
             call(@alice, :delete, path) |> json_response(200)

    assert revoked_at

    assert %{"data" => %{"revokedAt" => ^revoked_at}} =
             call(@alice, :delete, path) |> json_response(200)

    assert Customers.site_for_key(revoked["key"]) == :error
    assert {:ok, _found} = Customers.site_for_key(kept["key"])

    assert %{"code" => "site_archived", "data" => %{"archivedAt" => archived_at}} =
             call(@alice, :delete, "/sites/#{site["id"]}") |> json_response(200)

    assert archived_at
    assert Customers.site_for_key(kept["key"]) == :error
    assert %{"data" => %{"sites" => []}} = call(@alice, :get, "/sites") |> json_response(200)

    for {method, path} <- [
          {:get, "/sites/#{site["id"]}"},
          {:get, "/sites/#{site["id"]}/keys"},
          {:post, "/sites/#{site["id"]}/keys"}
        ] do
      assert %{"error" => %{"code" => "site_not_found"}} =
               call(@alice, method, path) |> json_response(404)
    end
  end

  test "a site keeps at most five keys that are not revoked" do
    customer(@alice)
    %{"id" => id} = create_site(@alice, @sandbox)
    [first | _more] = for _ <- 1..5, do: create_key(@alice, id)

    assert %{"error" => %{"code" => "site_key_limit"}} =
             call(@alice, :post, "/sites/#{id}/keys") |> json_response(409)

    call(@alice, :delete, "/sites/#{id}/keys/#{first["id"]}") |> json_response(200)
    assert create_key(@alice, id)

    assert %{"data" => %{"keys" => keys}} =
             call(@alice, :get, "/sites/#{id}/keys") |> json_response(200)

    assert length(keys) == 6
  end

  defp call(did, method, path, body \\ nil) do
    {token, _expires_at} = ControlToken.issue(did)

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("content-type", "application/json")

    dispatch(conn, @endpoint, method, "/api/control/v1" <> path, body && Jason.encode!(body))
  end

  defp customer(did),
    do: call(did, :post, "/customer", %{"name" => "Acme"}) |> json_response(201)

  defp create_site(did, body),
    do: call(did, :post, "/sites", body) |> json_response(201) |> Map.fetch!("data")

  defp create_key(did, site_id),
    do: call(did, :post, "/sites/#{site_id}/keys") |> json_response(201) |> Map.fetch!("data")

  defp invalid(did, method, path, body) do
    assert %{"error" => %{"code" => "control_fields_invalid"} = error} =
             call(did, method, path, body) |> json_response(422)

    error
  end

  defp taken?(did, body) do
    %{"fields" => %{"audience" => [_reason]}} = invalid(did, :post, "/sites", body)
    true
  end
end
