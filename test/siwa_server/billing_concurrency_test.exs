defmodule SiwaServer.BillingConcurrencyTest do
  use ExUnit.Case, async: false

  import Ecto.Changeset, only: [change: 2]
  import Ecto.Query
  import ExUnit.CaptureLog
  import Phoenix.ConnTest
  import Plug.Conn, only: [put_req_header: 3]

  alias Ecto.Adapters.SQL.Sandbox
  alias SiwaServer.{Billing, Repo, SignedRequest, TestRpcServer}
  alias SiwaServer.Billing.{ActiveAgent, Period}
  alias SiwaServer.Customers.{Customer, Site, SiteCredential}
  alias SiwaServer.Siwa.HttpVerifier

  @endpoint SiwaServerWeb.Endpoint

  # Room for this many new agents under the cap; one more arrives at once.
  @room 6

  # The address these tests' requests to the route come from, so its own limits'
  # rows are theirs alone (TEST-NET-1).
  @remote_ip {192, 0, 2, 1}

  setup do
    assert String.starts_with?(Repo.config()[:database], "siwa_server_test")
    base_rpc_url = System.get_env("BASE_RPC_URL")
    System.put_env("BASE_RPC_URL", TestRpcServer.wallet_answers({true, <<>>}))

    on_exit(fn ->
      if base_rpc_url,
        do: System.put_env("BASE_RPC_URL", base_rpc_url),
        else: System.delete_env("BASE_RPC_URL")
    end)

    :ok
  end

  test "one more new agent than the cap has room for, all at once: exactly the room is counted" do
    %{site: site, key: key, period: period} = production(:paid, 9_900)
    db(fn -> fill(period, site, 1_000 - @room) end)
    requests = for _agent <- 0..@room, do: signed(site)
    on_exit(fn -> forget(requests, site) end)

    results = concurrently(requests, &HttpVerifier.verify_for_key(&1, key, nil))

    assert Enum.count(results, &match?({_request, {:ok, _answer}}, &1)) == @room

    assert [{refused, {:error, {402, "agent_cap_reached", _message}}}] =
             Enum.reject(results, &match?({_request, {:ok, _answer}}, &1))

    db(fn ->
      assert counted(period) == {1_000, 1_000}
      refute used?(refused, site)

      refused_subject =
        "eip155:8453:" <> String.downcase(refused["headers"]["x-agent-wallet-address"])

      refute Repo.exists?(from a in ActiveAgent, where: a.subject == ^refused_subject)
    end)
  end

  test "one signed request sent at once is used once and counts its agent once" do
    %{site: site, key: key, period: period} = production(:paid, nil)
    request = signed(site)
    on_exit(fn -> forget([request], site) end)

    results = concurrently(List.duplicate(request, 6), &HttpVerifier.verify_for_key(&1, key, nil))

    assert Enum.count(results, &match?({_request, {:ok, _answer}}, &1)) == 1

    assert Enum.count(results, &match?({_request, {:error, {409, "request_replayed", _}}}, &1)) ==
             5

    db(fn -> assert counted(period) == {1, 1} end)
  end

  test "an internal customer's first agents arriving at once open its month once" do
    %{site: site, key: key, customer: customer} = production(:internal, nil)
    requests = for _agent <- 1..6, do: signed(site)
    on_exit(fn -> forget(requests, site) end)

    results = concurrently(requests, &HttpVerifier.verify_for_key(&1, key, nil))

    assert Enum.all?(results, &match?({_request, {:ok, _answer}}, &1))

    db(fn ->
      assert [period] = Repo.all(from p in Period, where: p.customer_id == ^customer.id)
      assert counted(period) == {6, 6}
    end)
  end

  # The count waits for a lock on the period's row only at its last step, the
  # `UPDATE` that adds one: the request's use and the agent's row are already
  # written in the transaction when the fault comes.
  test "a lock wait past the database's lock timeout answers 503; the request stays unused and its agent uncounted" do
    %{site: site, key: key, period: period} = production(:paid, nil)
    request = signed(site)
    on_exit(fn -> forget([request], site) end)
    holder = hold(period)

    log =
      capture_log(fn ->
        conn =
          on_pool([parameters: [lock_timeout: "100ms"]], fn -> http_verify(request, key) end)

        assert_unavailable(conn)
      end)

    assert log =~
             "not recorded site=#{site.id} ** (Postgrex.Error) ERROR 55P03 (lock_not_available)"

    release(holder)
    assert_unrecorded_then_accepted(request, site, key, period)
  end

  # The pool's reconnecting to a link that is gone is logged after the answer.
  @tag :capture_log
  test "the database connection lost while the count waits answers 503; the request stays unused and its agent uncounted" do
    %{site: site, key: key, period: period} = production(:paid, nil)
    request = signed(site)
    on_exit(fn -> forget([request], site) end)
    holder = hold(period)
    {link, port} = open_link()

    cut =
      Task.async(fn ->
        db(fn -> blocked_by(holder.backend) end)
        send(link, :cut)
      end)

    log =
      capture_log(fn ->
        conn =
          on_pool([hostname: "127.0.0.1", port: port], fn -> http_verify(request, key) end)

        assert_unavailable(conn)
      end)

    Task.await(cut)
    assert log =~ "not recorded site=#{site.id} ** (DBConnection.ConnectionError) tcp recv"
    release(holder)
    assert_unrecorded_then_accepted(request, site, key, period)
  end

  test "a request whose use waits past the lock timeout on another unfinished use answers 503 and stays unused" do
    %{site: site, key: key, period: period} = production(:paid, nil)
    request = signed(site)
    on_exit(fn -> forget([request], site) end)
    other_use = hold_use(request, site)

    log =
      capture_log(fn ->
        conn =
          on_pool([parameters: [lock_timeout: "100ms"]], fn -> http_verify(request, key) end)

        assert_unavailable(conn)
      end)

    assert log =~
             "not recorded site=#{site.id} ** (Postgrex.Error) ERROR 55P03 (lock_not_available)"

    release(other_use)
    assert_unrecorded_then_accepted(request, site, key, period)
  end

  defp assert_unavailable(conn) do
    assert %{"error" => %{"code" => "verification_unavailable"} = error} =
             json_response(conn, 503)

    assert Map.keys(error) == ["code", "hint", "message"]
  end

  # Nothing of the refused check is left, and the same signed request then
  # goes through and counts its agent once.
  defp assert_unrecorded_then_accepted(request, site, key, period) do
    db(fn ->
      refute used?(request, site)
      assert counted(period) == {0, 0}
    end)

    conn = db(fn -> http_verify(request, key) end)
    assert %{"data" => %{"usage" => %{"newThisPeriod" => true}}} = json_response(conn, 200)
    db(fn -> assert counted(period) == {1, 1} end)
  end

  # This process's queries go to a pool of the server's own kind, opened with
  # `opts`, until `fun` returns.
  defp on_pool(opts, fun) do
    pool =
      start_supervised!(
        {Repo, [name: nil, pool: DBConnection.ConnectionPool, pool_size: 1] ++ opts}
      )

    previous = Repo.put_dynamic_repo(pool)

    try do
      fun.()
    after
      Repo.put_dynamic_repo(previous)
    end
  end

  # Another transaction holds the period's row, as a count of a new agent does,
  # until `release/1`.
  defp hold(period) do
    holding(
      "SELECT 1 FROM billing_periods WHERE id = $1 FOR NO KEY UPDATE",
      [Ecto.UUID.dump!(period.id)]
    )
  end

  # Another transaction has written the request's use and not yet finished;
  # `release/1` rolls it back.
  defp hold_use(request, site) do
    holding(
      """
      INSERT INTO siwa_request_replays (id, replay_key, expires_at, inserted_at, updated_at)
      VALUES (gen_random_uuid(), $1, now() + interval '5 minutes', now(), now())
      """,
      [SignedRequest.stored_replay_key(request, site.audience)]
    )
  end

  defp holding(sql, params) do
    test = self()
    task = Task.async(fn -> db(fn -> held(sql, params, test) end) end)
    assert_receive {:held, backend}
    %{task: task, backend: backend}
  end

  defp held(sql, params, test) do
    Repo.transact(fn ->
      Repo.query!(sql, params)
      %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
      send(test, {:held, backend})

      receive do
        :release -> {:error, :released}
      end
    end)
  end

  defp release(%{task: task}) do
    send(task.pid, :release)
    assert {:error, :released} = Task.await(task)
  end

  # Returns once a query waits for a lock the `backend` holds.
  defp blocked_by(backend) do
    %{rows: [[blocked?]]} =
      Repo.query!(
        "SELECT EXISTS (SELECT 1 FROM pg_stat_activity WHERE $1 = ANY(pg_blocking_pids(pid)))",
        [backend]
      )

    if not blocked? do
      Process.sleep(10)
      blocked_by(backend)
    end
  end

  # One connection to the test database, relayed through a local port, that
  # `:cut` ends as a lost network does: both sides close and neither is told why.
  defp open_link do
    test = self()
    database = Repo.config()

    link =
      spawn_link(fn ->
        {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
        {:ok, port} = :inet.port(listen)
        send(test, {:link, port})
        {:ok, client} = :gen_tcp.accept(listen)

        {:ok, server} =
          :gen_tcp.connect(String.to_charlist(database[:hostname]), database[:port], [:binary])

        :ok = :inet.setopts(client, active: true)
        relay(listen, client, server)
      end)

    assert_receive {:link, port}
    {link, port}
  end

  defp relay(listen, client, server) do
    receive do
      {:tcp, ^client, data} ->
        :ok = :gen_tcp.send(server, data)
        relay(listen, client, server)

      {:tcp, ^server, data} ->
        :ok = :gen_tcp.send(client, data)
        relay(listen, client, server)

      :cut ->
        Enum.each([listen, client, server], &:gen_tcp.close/1)
    end
  end

  defp http_verify(request, key) do
    %{build_conn() | remote_ip: @remote_ip}
    |> put_req_header("authorization", "Bearer " <> key)
    |> put_req_header("content-type", "application/json")
    |> post("/api/shared/siwa/http-verify", Jason.encode!(request))
  end

  defp concurrently(requests, verify) do
    requests
    |> Task.async_stream(fn request -> {request, db(fn -> verify.(request) end)} end,
      max_concurrency: length(requests),
      timeout: 15_000
    )
    |> Enum.map(fn {:ok, result} -> result end)
  end

  defp db(fun), do: Sandbox.unboxed_run(Repo, fun)

  # A customer with one proven production site and its key, and for a paid
  # customer a period running now; every row goes when the test ends.
  defp production(kind, cap_cents) do
    n = System.unique_integer([:positive])

    made =
      db(fn ->
        customer =
          Repo.insert!(%Customer{
            owner_did: "did:privy:#{Ecto.UUID.generate()}",
            name: "Acme",
            kind: kind,
            cap_cents: cap_cents,
            subscription_status: if(kind == :paid, do: "active")
          })

        site =
          Repo.insert!(%Site{
            customer_id: customer.id,
            name: "Production #{n}",
            audience: "billing-race-#{n}",
            environment: :production,
            origins: ["https://billing-race-#{n}.example"],
            origin_proof: :verified
          })

        {key, credential} = SiteCredential.new(site)
        Repo.insert!(credential)

        period =
          if kind == :paid do
            %{rows: [[now]]} = Repo.query!("SELECT now()")

            {:ok, period} =
              Billing.open_period(customer, DateTime.add(now, -86_400), DateTime.add(now, 86_400))

            period
          end

        %{customer: customer, site: site, key: key, period: period}
      end)

    on_exit(fn -> db(fn -> remove(made) end) end)
    made
  end

  defp remove(%{customer: customer, site: site}) do
    Repo.delete_all(from a in ActiveAgent, where: a.customer_id == ^customer.id)
    Repo.delete_all(from p in Period, where: p.customer_id == ^customer.id)
    Repo.delete_all(from k in SiteCredential, where: k.site_id == ^site.id)
    Repo.delete_all(from a in "siwa_agent_daily_activity", where: a.audience == ^site.audience)
    Repo.delete_all(from s in Site, where: s.id == ^site.id)
    Repo.delete_all(from c in Customer, where: c.id == ^customer.id)
  end

  defp forget(requests, site) do
    keys = Enum.map(requests, &SignedRequest.stored_replay_key(&1, site.audience))

    db(fn ->
      Repo.query!("DELETE FROM siwa_request_replays WHERE replay_key = ANY($1)", [keys])

      # The site's own allowance is counted outside the test's rollback too, and
      # so are the route's limits when a test sends the request through it.
      Repo.query!("DELETE FROM siwa_rate_limits WHERE name = 'siwa_keyed_site' AND key = $1", [
        :crypto.hash(:sha256, site.id)
      ])

      address = @remote_ip |> :inet.ntoa() |> to_string()

      agents =
        Enum.map(requests, fn %{"headers" => headers} ->
          wallet = String.downcase(headers["x-agent-wallet-address"])
          :crypto.hash(:sha256, "http-verify:#{wallet}:#{headers["x-agent-chain-id"]}:#{address}")
        end)

      Repo.query!(
        """
        DELETE FROM siwa_rate_limits
        WHERE (name = 'siwa_http_verify' AND key = ANY($1)) OR (name = 'siwa_site' AND key = $2)
        """,
        [agents, :crypto.hash(:sha256, address)]
      )
    end)
  end

  defp signed(site) do
    SignedRequest.build(
      SignedRequest.signer(),
      site.audience,
      Siwa.Contract.authority(hd(site.origins))
    )
  end

  defp used?(request, site) do
    Repo.exists?(
      from r in "siwa_request_replays",
        where: r.replay_key == ^SignedRequest.stored_replay_key(request, site.audience)
    )
  end

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

    Repo.update!(change(period, active_agents: count))
  end
end
