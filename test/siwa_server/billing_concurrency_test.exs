defmodule SiwaServer.BillingConcurrencyTest do
  use ExUnit.Case, async: false

  import Ecto.Changeset, only: [change: 2]
  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias SiwaServer.{Billing, Repo, SignedRequest, TestRpcServer}
  alias SiwaServer.Billing.{ActiveAgent, Period}
  alias SiwaServer.Customers.{Customer, Site, SiteCredential}
  alias SiwaServer.Siwa.HttpVerifier

  # Room for this many new agents under the cap; one more arrives at once.
  @room 6

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
            cap_cents: cap_cents
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
