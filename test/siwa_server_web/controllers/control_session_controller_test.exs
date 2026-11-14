defmodule SiwaServerWeb.ControlSessionControllerTest do
  use SiwaServerWeb.ConnCase, async: false

  alias SiwaServer.{PrivySignIn, TestRpcServer, TestWallet}
  alias SiwaServerWeb.ControlToken

  @did "did:privy:person-one"

  setup do
    %{key: PrivySignIn.configure()}
  end

  test "a person's Privy sign-in becomes a control token that opens their account", %{key: key} do
    {access, identity} = PrivySignIn.tokens(key, @did)

    assert %{"code" => "control_session", "data" => data} =
             session(access, identity) |> json_response(200)

    assert data["did"] == @did
    {:ok, expires_at, 0} = DateTime.from_iso8601(data["expiresAt"])
    assert_in_delta DateTime.diff(expires_at, DateTime.utc_now()), 900, 5

    assert %{"data" => %{"did" => @did, "customer" => nil}} =
             build_conn()
             |> put_req_header("authorization", "Bearer " <> data["token"])
             |> get("/api/control/v1/account")
             |> json_response(200)
  end

  test "refuses a sign-in for another app, an expired one, or tokens of two people", %{key: key} do
    past = System.system_time(:second) - 60

    for changes <- [
          [access: %{"aud" => "another-privy-app"}, identity: %{"aud" => "another-privy-app"}],
          [access: %{"exp" => past}, identity: %{"exp" => past}],
          [identity: %{"sub" => "did:privy:someone-else"}],
          [identity: %{"sid" => "another-privy-session"}]
        ] do
      {access, identity} = PrivySignIn.tokens(key, @did, changes)

      assert %{"error" => %{"code" => "privy_proof_invalid"}} =
               session(access, identity) |> json_response(401)
    end
  end

  test "refuses tokens signed by any key but Privy's", %{key: _key} do
    {access, identity} = PrivySignIn.tokens(JOSE.JWK.generate_key({:ec, "P-256"}), @did)

    assert %{"error" => %{"code" => "privy_proof_invalid"}} =
             session(access, identity) |> json_response(401)
  end

  test "refuses an access token without its identity token", %{key: key} do
    {access, _identity} = PrivySignIn.tokens(key, @did)

    assert %{"error" => %{"code" => "privy_proof_invalid"}} =
             build_conn()
             |> put_req_header("authorization", "Bearer " <> access)
             |> post("/api/control/v1/session")
             |> json_response(401)
  end

  test "a control token works for 15 minutes and no longer" do
    now = System.system_time(:second)
    {fresh, _expires_at} = ControlToken.issue(@did, now - 890)
    {expired, _expires_at} = ControlToken.issue(@did, now - 901)

    assert account(fresh) |> json_response(200)

    for token <- [expired, "not-a-token", Phoenix.Token.sign(SiwaServerWeb.Endpoint, "x", @did)] do
      assert %{"error" => %{"code" => "control_token_invalid"}} =
               account(token) |> json_response(401)
    end

    assert %{"error" => %{"code" => "control_token_invalid"}} =
             build_conn() |> get("/api/control/v1/account") |> json_response(401)
  end

  test "the exchange is limited per address", %{key: key} do
    previous = Application.get_env(:siwa_server, :rate_limits, [])
    on_exit(fn -> Application.put_env(:siwa_server, :rate_limits, previous) end)

    Application.put_env(:siwa_server, :rate_limits,
      siwa_control_session: [limit: 2, window_ms: 60_000]
    )

    {access, identity} = PrivySignIn.tokens(key, @did)

    assert session(access, identity) |> json_response(200)
    assert session(access, identity) |> json_response(200)
    conn = session(access, identity)
    assert %{"error" => %{"code" => "rate_limited"}} = json_response(conn, 429)
    assert [_seconds] = get_resp_header(conn, "retry-after")
  end

  test "without Privy settings the control API refuses and the rest of the server is unchanged",
       %{key: key} do
    {access, identity} = PrivySignIn.tokens(key, @did)
    {token, _expires_at} = ControlToken.issue(@did)
    PrivySignIn.unconfigure()

    assert %{"error" => %{"code" => "control_not_configured"}} =
             session(access, identity) |> json_response(503)

    assert %{"error" => %{"code" => "control_not_configured"}} =
             account(token) |> json_response(503)

    for {name, chain_id} <- [
          {"BASE_RPC_URL", 8453},
          {"ETHEREUM_RPC_URL", 1},
          {"WORLD_RPC_URL", 480}
        ] do
      previous = System.get_env(name)
      System.put_env(name, TestRpcServer.chain_id(chain_id))

      on_exit(fn ->
        if previous, do: System.put_env(name, previous), else: System.delete_env(name)
      end)
    end

    assert %{"ready" => true} = build_conn() |> get("/readyz") |> json_response(200)

    siwa = Application.fetch_env!(:siwa_server, :siwa)
    on_exit(fn -> Application.put_env(:siwa_server, :siwa, siwa) end)

    Application.put_env(
      :siwa_server,
      :siwa,
      Keyword.put(siwa, :wallet_origins, %{"patchbay" => ["https://patchbay.help"]})
    )

    assert %{"code" => "nonce_issued"} =
             build_conn()
             |> put_req_header("content-type", "application/json")
             |> post(
               "/api/shared/siwa/wallet/nonce",
               Jason.encode!(%{
                 "wallet_address" => TestWallet.address(),
                 "chain_id" => 8453,
                 "audience" => "patchbay"
               })
             )
             |> json_response(200)
  end

  defp session(access, identity) do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> access)
    |> put_req_header("privy-id-token", identity)
    |> post("/api/control/v1/session")
  end

  defp account(token) do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> get("/api/control/v1/account")
  end
end
