defmodule SiwaServerWeb.AudienceLookupTest do
  use SiwaServerWeb.ConnCase, async: false

  import Ecto.Changeset, only: [change: 2]

  alias SiwaServer.Customers.{Customer, Site}
  alias SiwaServer.Repo

  setup do
    siwa = Application.fetch_env!(:siwa_server, :siwa)
    rate_limits = Application.get_env(:siwa_server, :rate_limits, [])

    Application.put_env(
      :siwa_server,
      :siwa,
      Keyword.put(siwa, :wallet_origins, %{
        "patchbay" => ["https://patchbay.help", "https://www.patchbay.help"]
      })
    )

    on_exit(fn ->
      Application.put_env(:siwa_server, :siwa, siwa)
      Application.put_env(:siwa_server, :rate_limits, rate_limits)
    end)

    :ok
  end

  test "a Regent site's origins name its configured audience, compared in lower case" do
    for origin <- [
          "https://patchbay.help",
          "https://www.patchbay.help",
          "HTTPS://WWW.Patchbay.HELP"
        ] do
      assert {200, %{"code" => "audience", "data" => data}} = lookup(origin)
      assert data == %{"audience" => "patchbay", "origin" => String.downcase(origin)}
    end
  end

  test "a customer's verified production site's origins name its audience" do
    site = site(:production, :verified, ["https://acme.example", "https://app.acme.example"])

    for origin <- site.origins do
      assert {200, %{"data" => %{"audience" => audience, "origin" => ^origin}}} = lookup(origin)
      assert audience == site.audience
    end
  end

  test "an unproven, archived or sandbox site answers exactly as an unknown origin" do
    assert {404, %{"error" => %{"code" => "audience_not_found"}}} =
             unknown = lookup("https://unknown.example")

    site(:production, :unverified, ["https://unproven.example"])

    :production
    |> site(:verified, ["https://archived.example"])
    |> change(archived_at: DateTime.utc_now(:second))
    |> Repo.update!()

    site(:sandbox, nil, ["http://localhost:3000"])

    for origin <- [
          "https://unproven.example",
          "https://archived.example",
          "http://localhost:3000"
        ] do
      assert lookup(origin) == unknown
    end
  end

  test "only the exact origin is found" do
    site(:production, :verified, ["https://acme.example"])

    for near <- [
          "https://acme.exampl",
          "https://cme.example",
          "https://www.acme.example",
          "https://acme.example.evil",
          "https://acme.example/",
          "https://acme.example:443",
          "https://acme.example/.well-known/siwa-site.txt",
          "acme.example",
          "http://acme.example",
          " https://acme.example",
          "https://%",
          "%acme%",
          "https://patchbay.help/",
          ""
        ] do
      assert {404, %{"error" => %{"code" => "audience_not_found"}}} = lookup(near), near
    end
  end

  test "of two sites proven at one origin, the one proven last is found" do
    earlier = site(:production, :verified, ["https://shared.example"])
    later = site(:production, :verified, ["https://shared.example"])
    now = DateTime.utc_now(:second)

    for {site, at} <- [{earlier, DateTime.add(now, -60)}, {later, now}],
        do: Repo.update!(change(site, origin_proof_verified_at: at))

    assert {200, %{"data" => %{"audience" => audience}}} = lookup("https://shared.example")
    assert audience == later.audience
  end

  test "the query holds one origin and nothing else" do
    for query <- [
          "",
          "?origin=https%3A%2F%2Facme.example&audience=acme",
          "?origin[]=https%3A%2F%2Facme.example",
          "?site=https%3A%2F%2Facme.example"
        ] do
      assert %{"error" => %{"code" => "invalid_request"}} =
               build_conn() |> get("/api/shared/siwa/audience" <> query) |> json_response(400)
    end
  end

  test "lookups are limited per calling address" do
    Application.put_env(:siwa_server, :rate_limits, siwa_audience: [limit: 2])

    assert {200, _found} = lookup("https://patchbay.help")
    assert {404, _not_found} = lookup("https://unknown.example")

    refused =
      get(build_conn(), "/api/shared/siwa/audience", %{"origin" => "https://patchbay.help"})

    assert %{"error" => %{"code" => "rate_limited"}} = json_response(refused, 429)
    assert [_seconds] = get_resp_header(refused, "retry-after")
  end

  defp lookup(origin) do
    conn = get(build_conn(), "/api/shared/siwa/audience", %{"origin" => origin})
    {conn.status, Jason.decode!(conn.resp_body)}
  end

  defp site(environment, proof, origins) do
    n = System.unique_integer([:positive])
    customer = Repo.insert!(%Customer{owner_did: "did:privy:#{n}", name: "Acme", kind: :paid})

    Repo.insert!(%Site{
      customer_id: customer.id,
      name: "Site #{n}",
      audience: "site-#{n}",
      environment: environment,
      origins: origins,
      origin_proof: proof
    })
  end
end
