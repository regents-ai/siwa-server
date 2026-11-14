defmodule SiwaServerWeb.KeyedHttpVerifyTest do
  use SiwaServerWeb.ConnCase, async: false

  import Ecto.Changeset, only: [change: 2]
  import Ecto.Query

  alias SiwaServer.{Billing, Config, Repo, SignedRequest, TestRpcServer}
  alias SiwaServer.Billing.{ActiveAgent, Period}
  alias SiwaServer.Customers.{Customer, Site, SiteCredential}
  alias SiwaServer.Siwa.Wallet

  setup do
    siwa = Application.fetch_env!(:siwa_server, :siwa)
    base_rpc_url = System.get_env("BASE_RPC_URL")

    Application.put_env(
      :siwa_server,
      :siwa,
      Keyword.put(siwa, :wallet_origins, %{"patchbay" => ["https://patchbay.help"]})
    )

    System.put_env("BASE_RPC_URL", TestRpcServer.wallet_answers({true, <<>>}))

    on_exit(fn ->
      Application.put_env(:siwa_server, :siwa, siwa)

      if base_rpc_url,
        do: System.put_env("BASE_RPC_URL", base_rpc_url),
        else: System.delete_env("BASE_RPC_URL")
    end)

    :ok
  end

  test "a sandbox site's key verifies its agent, uses the request up and counts nothing" do
    customer = customer()
    site = sandbox(customer)
    key = key(site)
    agent = SignedRequest.signer()
    request = signed(agent, site)

    assert {200, %{"data" => data}} = verify(request, bearer(key))
    assert data["subject"] == SignedRequest.subject(agent)
    assert data["principal"]["audience"] == site.audience
    refute Map.has_key?(data, "usage")

    assert {409, %{"error" => %{"code" => "request_replayed"}}} = verify(request, bearer(key))
    assert Repo.aggregate(from(p in Period, where: p.customer_id == ^customer.id), :count) == 0

    assert Repo.aggregate(from(a in ActiveAgent, where: a.customer_id == ^customer.id), :count) ==
             0
  end

  test "an agent is counted once per customer and period, whichever of its sites saw it" do
    first = customer()
    period = open(first)
    site = production(first)
    other_site = production(first)
    agent = SignedRequest.signer()

    assert {200, %{"data" => %{"usage" => usage}}} =
             verify(signed(agent, site), bearer(key(site)))

    assert usage == %{"activeThisPeriod" => true, "newThisPeriod" => true}

    assert {200, %{"data" => %{"usage" => %{"newThisPeriod" => false}}}} =
             verify(signed(agent, site), bearer(key(site)))

    assert {200, %{"data" => %{"usage" => %{"newThisPeriod" => false}}}} =
             verify(signed(agent, other_site), bearer(key(other_site)))

    assert counted(period) == {1, 1}

    assert [%ActiveAgent{first_site_id: first_site_id, subject: subject}] =
             Repo.all(from a in ActiveAgent, where: a.billing_period_id == ^period.id)

    assert {first_site_id, subject} == {site.id, SignedRequest.subject(agent)}

    second = customer()
    second_period = open(second)
    second_site = production(second)

    assert {200, %{"data" => %{"usage" => %{"newThisPeriod" => true}}}} =
             verify(signed(agent, second_site), bearer(key(second_site)))

    assert {200, %{"data" => %{"usage" => %{"newThisPeriod" => true}}}} =
             verify(signed(SignedRequest.signer(), other_site), bearer(key(other_site)))

    assert counted(period) == {2, 2}
    assert counted(second_period) == {1, 1}
  end

  test "a key that names no usable site is refused before the request is read, leaving it unused" do
    customer = customer()
    period = open(customer)
    site = production(customer)
    request = signed(SignedRequest.signer(), site)
    revoked = key(site, revoked: true)

    unknown = "siwa_sk_live_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    for authorization <- [bearer(unknown), bearer(revoked), "Basic c2l3YQ==", "Bearer"] do
      assert {401, %{"error" => %{"code" => "site_key_invalid"}}} =
               verify(request, authorization)

      assert {401, %{"error" => %{"code" => "site_key_invalid"}}} =
               verify(%{"not" => "a request"}, authorization)
    end

    assert used?(request, site) == false
    assert counted(period) == {0, 0}

    assert {200, %{"data" => %{"usage" => %{"newThisPeriod" => true}}}} =
             verify(request, bearer(key(site)))

    assert used?(request, site) == true
  end

  test "an archived site's key is refused, and so is a production site whose origins are unproven" do
    customer = customer()
    open(customer)
    archived = sandbox(customer)
    archived_key = key(archived)
    Repo.update!(change(archived, archived_at: DateTime.utc_now(:second)))

    assert {401, %{"error" => %{"code" => "site_key_invalid"}}} =
             verify(signed(SignedRequest.signer(), archived), bearer(archived_key))

    unproven = production(customer, :unverified)
    request = signed(SignedRequest.signer(), unproven)

    assert {403, %{"error" => %{"code" => "site_not_verified"}}} =
             verify(request, bearer(key(unproven)))

    assert used?(request, unproven) == false
  end

  test "x-siwa-audience sent with a key must be the key's site's audience" do
    site = sandbox(customer())
    key = key(site)
    request = signed(SignedRequest.signer(), site)

    assert {401, %{"error" => %{"code" => "site_audience_mismatch"}}} =
             verify(request, bearer(key), "patchbay")

    assert used?(request, site) == false
    assert {200, %{"data" => %{"verified" => true}}} = verify(request, bearer(key), site.audience)
    assert used?(request, site) == true
  end

  test "a customer's site's audience without its key is refused" do
    customer = customer()
    site = sandbox(customer)
    archived = sandbox(customer)
    Repo.update!(change(archived, archived_at: DateTime.utc_now(:second)))

    for refused <- [site, archived] do
      request = signed(SignedRequest.signer(), refused)

      assert {401, %{"error" => %{"code" => "site_key_required"}}} =
               verify(request, nil, refused.audience)

      assert used?(request, refused) == false
    end
  end

  test "a paid customer with no period running is refused, and the request stays unused" do
    customer = customer()
    site = production(customer)
    key = key(site)
    request = signed(SignedRequest.signer(), site)

    assert {402, %{"error" => %{"code" => "billing_required"}}} = verify(request, bearer(key))
    assert used?(request, site) == false
    assert Repo.aggregate(from(p in Period, where: p.customer_id == ^customer.id), :count) == 0

    period = open(customer)

    assert {200, %{"data" => %{"usage" => %{"newThisPeriod" => true}}}} =
             verify(request, bearer(key))

    assert used?(request, site) == true
    assert counted(period) == {1, 1}
  end

  test "an internal customer's UTC month opens with its first agent" do
    customer = customer(:internal)
    site = production(customer)

    assert {200, %{"data" => %{"usage" => %{"newThisPeriod" => true}}}} =
             verify(signed(SignedRequest.signer(), site), bearer(key(site)))

    %{rows: [[month, next_month]]} =
      Repo.query!(
        "SELECT date_trunc('month', now() AT TIME ZONE 'UTC'), date_trunc('month', now() AT TIME ZONE 'UTC') + interval '1 month'"
      )

    assert [%Period{} = period] = Repo.all(from p in Period, where: p.customer_id == ^customer.id)
    assert DateTime.to_naive(period.starts_at) == month
    assert DateTime.to_naive(period.ends_at) == next_month
    assert counted(period) == {1, 1}
  end

  test "at the cap an agent already counted passes and a new one waits, unused, for a higher cap" do
    customer = customer(:paid, 9_900)
    period = open(customer)
    assert period.max_agents == 1_000
    site = production(customer)
    key = key(site)
    counted_agent = SignedRequest.signer()

    assert {200, _counted} = verify(signed(counted_agent, site), bearer(key))
    fill(period, site, 999)

    assert {200, %{"data" => %{"usage" => %{"newThisPeriod" => false}}}} =
             verify(signed(counted_agent, site), bearer(key))

    new_agent = SignedRequest.signer()
    request = signed(new_agent, site)

    assert {402, %{"error" => %{"code" => "agent_cap_reached"} = error}} =
             verify(request, bearer(key))

    refute Map.has_key?(error, "data")
    assert used?(request, site) == false
    assert counted(period) == {1_000, 1_000}

    assert {:ok, {_customer, %Period{max_agents: 1_010}}} =
             Billing.set_cap(customer, %{"capCents" => 10_000})

    assert {200, %{"data" => %{"subject" => subject, "usage" => %{"newThisPeriod" => true}}}} =
             verify(request, bearer(key))

    assert subject == SignedRequest.subject(new_agent)
    assert used?(request, site) == true
    assert counted(period) == {1_001, 1_001}
  end

  test "a replayed keyed request is refused and counts nothing" do
    customer = customer()
    period = open(customer)
    site = production(customer)
    key = key(site)
    request = signed(SignedRequest.signer(), site)

    assert {200, _verified} = verify(request, bearer(key))
    assert {409, %{"error" => %{"code" => "request_replayed"}}} = verify(request, bearer(key))
    assert counted(period) == {1, 1}
  end

  test "a new period counts its agents again" do
    customer = customer()
    first = open(customer, -86_400, 86_400)
    site = production(customer)
    key = key(site)
    agent = SignedRequest.signer()

    assert {200, %{"data" => %{"usage" => %{"newThisPeriod" => true}}}} =
             verify(signed(agent, site), bearer(key))

    now = db_now()
    Repo.update!(change(first, ends_at: now))

    {:ok, second} =
      Billing.open_period(customer, now, DateTime.add(now, 30 * 86_400))

    assert {200, %{"data" => %{"usage" => %{"newThisPeriod" => true}}}} =
             verify(signed(agent, site), bearer(key))

    assert counted(Repo.reload!(first)) == {1, 1}
    assert counted(second) == {1, 1}
  end

  test "a production site's lease never outlasts the period its agent was counted in" do
    customer = customer()
    period_end = db_now() |> DateTime.add(60) |> DateTime.truncate(:second)
    {:ok, _period} = Billing.open_period(customer, DateTime.add(period_end, -86_400), period_end)
    site = production(customer)
    request = site |> signed_by() |> Map.put("lease", true)

    assert {200, %{"data" => %{"leaseExpiresAt" => lease_ends}}} =
             verify(request, bearer(key(site)))

    assert {:ok, lease_ends, 0} = DateTime.from_iso8601(lease_ends)
    assert DateTime.compare(lease_ends, period_end) == :eq

    sandbox = sandbox(customer)

    assert {200, %{"data" => %{"leaseExpiresAt" => sandbox_lease_ends}}} =
             verify(sandbox |> signed_by() |> Map.put("lease", true), bearer(key(sandbox)))

    assert {:ok, sandbox_lease_ends, 0} = DateTime.from_iso8601(sandbox_lease_ends)
    assert DateTime.diff(sandbox_lease_ends, DateTime.utc_now()) in 595..600
  end

  test "agents sign in for a sandbox site and a proven production site, never an unproven or archived one" do
    customer = customer()
    archived = sandbox(customer)
    Repo.update!(change(archived, archived_at: DateTime.utc_now(:second)))

    for site <- [sandbox(customer), production(customer)] do
      agent = SignedRequest.signer()

      params = %{
        "wallet_address" => agent.address,
        "chain_id" => 8453,
        "audience" => site.audience
      }

      assert {:ok, %{"data" => %{"nonce" => nonce, "message" => message}}} =
               Wallet.issue_nonce(params)

      assert message =~ hd(site.origins)
      {:ok, signature} = Siwa.LocalSigner.sign_message(agent, message)

      assert {:ok, %{"data" => %{"receipt" => receipt}}} =
               Wallet.verify(
                 Map.merge(params, %{
                   "nonce" => nonce,
                   "message" => message,
                   "signature" => signature
                 })
               )

      {:ok, secret} = Config.receipt_secret()

      assert {:ok, %{"aud" => audience}} =
               Siwa.verify_receipt(receipt, secret: secret, audience: site.audience)

      assert audience == site.audience
    end

    for refused <- [production(customer, :unverified), archived] do
      assert {:error, {403, "wallet_audience_disabled", _message}} =
               Wallet.issue_nonce(%{
                 "wallet_address" => SignedRequest.signer().address,
                 "chain_id" => 8453,
                 "audience" => refused.audience
               })
    end

    assert %{"data" => %{"audiences" => listed}} =
             build_conn() |> get("/api/shared/siwa/audiences") |> json_response(200)

    assert Enum.map(listed, & &1["audience"]) == ["patchbay"]
  end

  defp verify(request, authorization, audience \\ nil) do
    conn =
      Enum.reduce(
        [{"authorization", authorization}, {"x-siwa-audience", audience}],
        put_req_header(build_conn(), "content-type", "application/json"),
        fn
          {_name, nil}, conn -> conn
          {name, value}, conn -> put_req_header(conn, name, value)
        end
      )
      |> post("/api/shared/siwa/http-verify", Jason.encode!(request))

    {conn.status, Jason.decode!(conn.resp_body)}
  end

  defp bearer(key), do: "Bearer " <> key

  defp signed(agent, site),
    do: SignedRequest.build(agent, site.audience, Siwa.Contract.authority(hd(site.origins)))

  defp signed_by(site), do: signed(SignedRequest.signer(), site)

  defp used?(request, site) do
    Repo.exists?(
      from r in "siwa_request_replays",
        where: r.replay_key == ^SignedRequest.stored_replay_key(request, site.audience)
    )
  end

  # The period's count and its agents' rows, which always agree.
  defp counted(period) do
    {Repo.reload!(period).active_agents,
     Repo.aggregate(from(a in ActiveAgent, where: a.billing_period_id == ^period.id), :count)}
  end

  # `count` agents on another chain, counted in `period` as though verified.
  defp fill(period, site, count) do
    Repo.query!(
      """
      INSERT INTO monthly_active_agents
        (id, billing_period_id, customer_id, subject, first_site_id, first_verified_at)
      SELECT gen_random_uuid(), $1, $2, 'eip155:1:0x' || lpad(to_hex(n), 40, '0'), $3, now()
      FROM generate_series(1, $4) AS n
      """,
      [
        Ecto.UUID.dump!(period.id),
        Ecto.UUID.dump!(period.customer_id),
        Ecto.UUID.dump!(site.id),
        count
      ]
    )

    Repo.update_all(from(p in Period, where: p.id == ^period.id), inc: [active_agents: count])
  end

  defp customer(kind \\ :paid, cap_cents \\ nil) do
    Repo.insert!(%Customer{
      owner_did: "did:privy:#{Ecto.UUID.generate()}",
      name: "Acme",
      kind: kind,
      cap_cents: cap_cents
    })
  end

  defp sandbox(customer) do
    n = System.unique_integer([:positive])

    Repo.insert!(%Site{
      customer_id: customer.id,
      name: "Sandbox #{n}",
      audience: "sandbox-#{n}",
      environment: :sandbox,
      origins: ["http://localhost:3000"]
    })
  end

  defp production(customer, proof \\ :verified) do
    n = System.unique_integer([:positive])

    Repo.insert!(%Site{
      customer_id: customer.id,
      name: "Production #{n}",
      audience: "production-#{n}",
      environment: :production,
      origins: ["https://production-#{n}.example"],
      origin_proof: proof
    })
  end

  defp key(site, opts \\ []) do
    {key, credential} = SiteCredential.new(site)
    credential = Repo.insert!(credential)

    if opts[:revoked],
      do: Repo.update!(change(credential, revoked_at: DateTime.utc_now(:second)))

    key
  end

  defp open(customer, starts_in \\ -86_400, ends_in \\ 30 * 86_400) do
    now = db_now()

    {:ok, period} =
      Billing.open_period(customer, DateTime.add(now, starts_in), DateTime.add(now, ends_in))

    period
  end

  defp db_now do
    %{rows: [[now]]} = Repo.query!("SELECT now()")
    now
  end
end
