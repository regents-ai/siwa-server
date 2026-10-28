defmodule SiwaServerWeb.HttpVerifySiteKeyTest do
  @moduledoc """
  A site checks an agent's signed request with its own verify key, and the key
  alone names the audience. The fixtures here are the ones the agent access
  specification asks for: the digest of the exact received bytes, a forged
  `content-digest`, another site's key, an expired sign-in, and a replay raced
  across separate database connections.
  """

  use SiwaServerWeb.ConnCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias SiwaServer.{Repo, TestRpcServer}
  alias SiwaServer.Siwa.HttpVerifier

  @path "/api/agents/v1/pair"

  setup do
    previous = Application.get_env(:siwa_server, :siwa)
    previous_base_rpc_url = System.get_env("BASE_RPC_URL")

    Application.put_env(
      :siwa_server,
      :siwa,
      Keyword.put(previous, :wallet_origins, %{
        "patchbay" => ["https://patchbay.help"],
        "techtree" => ["https://techtree.sh"]
      })
    )

    # Base answers that no smart wallet approves, so only the key's own signature counts.
    System.put_env("BASE_RPC_URL", TestRpcServer.wallet_answers({true, <<>>}))

    on_exit(fn ->
      Application.put_env(:siwa_server, :siwa, previous)

      if previous_base_rpc_url,
        do: System.put_env("BASE_RPC_URL", previous_base_rpc_url),
        else: System.delete_env("BASE_RPC_URL")
    end)

    {:ok, signer} = Siwa.LocalSigner.new()
    %{signer: signer}
  end

  test "a site's key checks requests for its own audience, and no other", %{
    conn: conn,
    signer: signer
  } do
    body = ~s({"code":"ABCD-1234"})
    request = signed(signer, "patchbay", body)

    assert %{"error" => %{"code" => code, "hint" => hint}} =
             conn |> verify("techtree", request) |> json_response(401)

    assert code in ~w(receipt_invalid receipt_binding_mismatch)
    assert hint =~ "Your sign-in for https://techtree.sh has ended or was made for another site."

    assert %{"data" => %{"verified" => true, "principal" => %{"audience" => "patchbay"}}} =
             conn |> recycle() |> verify("patchbay", request) |> json_response(200)
  end

  test "a request without a site's own verify key is refused before it is checked", %{
    conn: conn,
    signer: signer
  } do
    previous_rate_limits = Application.get_env(:siwa_server, :rate_limits, [])

    Application.put_env(:siwa_server, :rate_limits,
      siwa_http_verify: [limit: 1, window_ms: 60_000]
    )

    SiwaServer.RateLimiter.reset()

    on_exit(fn ->
      Application.put_env(:siwa_server, :rate_limits, previous_rate_limits)
      SiwaServer.RateLimiter.reset()
    end)

    request = signed(signer, "patchbay", ~s({"code":"ABCD-1234"}))
    siwa = Application.fetch_env!(:siwa_server, :siwa)
    verify_key = siwa |> Keyword.fetch!(:site_verifiers) |> Map.fetch!("patchbay")

    for authorization <- [
          nil,
          "Bearer " <> String.duplicate("x", 40),
          verify_key,
          "Basic " <> verify_key,
          "Bearer " <> (siwa |> Keyword.fetch!(:activity_readers) |> Map.fetch!("patchbay")),
          "Bearer " <> (siwa |> Keyword.fetch!(:hosted_signers) |> Map.fetch!("patchbay"))
        ] do
      conn =
        if authorization, do: put_req_header(conn, "authorization", authorization), else: conn

      assert %{"error" => %{"code" => "site_verify_unauthorized", "hint" => hint}} =
               conn |> post_json(request) |> json_response(401)

      assert hint == "This request is for Regent sites, not agents."
    end

    # None of those spent the request, nor the site's one request this minute.
    assert conn |> verify("patchbay", request) |> json_response(200)
  end

  test "the digest is of the exact bytes received: any change to them is refused", %{
    conn: conn,
    signer: signer
  } do
    body = ~s({"name":"Astra","note":"café"})
    request = signed(signer, "patchbay", body)

    for received <- [
          ~s({"name": "Astra","note":"café"}),
          ~s({"note":"café","name":"Astra"}),
          ~s({"name":"Astra","note":"café"}),
          body <> "\n",
          body <> <<0>>,
          ~s({"name":"Astra","note":"caf\\u00e9"})
        ] do
      assert %{"error" => %{"code" => "http_body_binding_invalid"}} =
               conn
               |> recycle()
               |> verify("patchbay", %{request | "body_digest" => digest(received)})
               |> json_response(401)
    end

    # The changed bytes never spent the request made over the original ones.
    assert conn |> recycle() |> verify("patchbay", request) |> json_response(200)
  end

  test "a content-digest the agent claims is checked against the bytes the site received", %{
    conn: conn,
    signer: signer
  } do
    signed_body = ~s({"code":"ABCD-1234"})
    received = ~s({"code":"WXYZ-9999"})
    request = signed(signer, "patchbay", signed_body)

    # The agent signed a digest of other bytes than the site received.
    assert %{"error" => %{"code" => "http_body_binding_invalid"}} =
             conn
             |> verify("patchbay", %{request | "body_digest" => digest(received)})
             |> json_response(401)

    # The agent swaps its claimed digest for the received bytes' without signing it again.
    forged = %{
      request
      | "headers" => Map.put(request["headers"], "content-digest", digest(received)),
        "body_digest" => digest(received)
    }

    assert %{"error" => %{"code" => code}} =
             conn |> recycle() |> verify("patchbay", forged) |> json_response(401)

    assert code in ~w(http_signature_invalid signature_invalid)
  end

  test "a sign-in that has ended is refused", %{conn: conn, signer: signer} do
    request = signed(signer, "patchbay", ~s({"code":"ABCD-1234"}), 1)
    Process.sleep(5)

    assert %{"error" => %{"code" => "receipt_invalid"}} =
             conn |> verify("patchbay", request) |> json_response(401)
  end

  test "a request is accepted once, and once only when raced on separate database connections",
       %{signer: signer} do
    request = signed(signer, "patchbay", ~s({"code":"ABCD-1234"}))
    wallet = String.downcase(signer.address)

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        Repo.query!("DELETE FROM siwa_request_replays WHERE replay_key LIKE $1", [
          "%\"#{wallet}\"%"
        ])

        Repo.query!("DELETE FROM siwa_agent_daily_activity WHERE wallet_address = $1", [wallet])
      end)
    end)

    results =
      1..12
      |> Task.async_stream(
        fn _ ->
          Sandbox.unboxed_run(Repo, fn ->
            HttpVerifier.verify(request, audience: "patchbay")
          end)
        end,
        max_concurrency: 12,
        timeout: 10_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, %{"code" => "http_envelope_valid"}}, &1)) == 1
    assert Enum.count(results, &match?({:error, {409, "request_replayed", _}}, &1)) == 11
  end

  # An agent's signed POST to `@path` for `audience`, as the site that received
  # `body` hands it over: the digest of the bytes it read, never the bytes.
  defp signed(signer, audience, body, ttl_ms \\ 3_600_000) do
    secret = :siwa_server |> Application.fetch_env!(:siwa) |> Keyword.fetch!(:receipt_secret)

    {:ok, receipt} =
      Siwa.create_receipt(
        %{
          "typ" => "siwa_wallet_receipt",
          "verified" => "wallet_signature",
          "jti" => Ecto.UUID.generate(),
          "sub" => signer.address,
          "aud" => audience,
          "chain_id" => 8453,
          "nonce" => "receipt-#{System.unique_integer([:positive])}",
          "key_id" => signer.address
        },
        receipt_secret: secret,
        ttl_ms: ttl_ms
      )

    {:ok, signed} =
      Siwa.sign_request(
        %{method: "POST", path: @path, body: body},
        %{
          receipt: receipt.token,
          key_id: signer.address,
          wallet_address: signer.address,
          chain_id: 8453
        },
        signer
      )

    %{
      "method" => signed.method,
      "path" => signed.path,
      "headers" => signed.headers,
      "body_digest" => digest(body)
    }
  end

  defp digest(bytes), do: Siwa.content_digest_for_body(bytes)

  defp verify(conn, site, request), do: conn |> put_site_verify_key(site) |> post_json(request)

  defp post_json(conn, request) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/shared/siwa/http-verify", Jason.encode!(request))
  end
end
