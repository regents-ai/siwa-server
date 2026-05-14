defmodule SiwaServerWeb.KeyringRouterTest do
  use SiwaServerWeb.ConnCase, async: false

  import Plug.Conn
  import Plug.Test

  alias SiwaServer.Repo

  setup do
    previous_rate_limits = Application.get_env(:siwa_server, :rate_limits, [])
    SiwaServer.RateLimiter.reset()

    on_exit(fn ->
      Application.put_env(:siwa_server, :rate_limits, previous_rate_limits)
      SiwaServer.RateLimiter.reset()
    end)

    :ok
  end

  defp call_endpoint(conn), do: SiwaServerWeb.Endpoint.call(conn, [])

  defp signed_conn(method, path, body, secret, opts \\ []) do
    headers = SiwaKeyring.Auth.compute_hmac(secret, method, path, body, opts)

    conn(method, path, body)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-keyring-timestamp", headers["x-keyring-timestamp"])
    |> put_req_header("x-keyring-request-id", headers["x-keyring-request-id"])
    |> put_req_header("x-keyring-signature", headers["x-keyring-signature"])
  end

  defp restore_keyring_env(old_env) do
    current_keys = Application.get_all_env(:siwa_keyring) |> Keyword.keys()

    Enum.each(current_keys, fn key ->
      Application.delete_env(:siwa_keyring, key)
    end)

    Enum.each(old_env, fn {key, value} ->
      Application.put_env(:siwa_keyring, key, value)
    end)
  end

  test "internal keyring routes support the normal wallet lifecycle" do
    path = Path.join(System.tmp_dir!(), "siwa-keyring-#{System.unique_integer([:positive])}.json")
    old_env = Application.get_all_env(:siwa_keyring)

    Application.put_env(:siwa_keyring, :path, path)
    Application.put_env(:siwa_keyring, :password, "router-password")
    Application.put_env(:siwa_keyring, :secret, "router-secret")

    on_exit(fn ->
      File.rm(path)
      Enum.each(old_env, fn {key, value} -> Application.put_env(:siwa_keyring, key, value) end)
    end)

    create_conn = signed_conn("POST", "/internal/keyring/create-wallet", "{}", "router-secret")
    create_response = call_endpoint(create_conn)
    assert create_response.status == 200

    address_conn = signed_conn("POST", "/internal/keyring/get-address", "{}", "router-secret")
    address_response = call_endpoint(address_conn)
    assert address_response.status == 200
    %{"address" => address} = Jason.decode!(address_response.resp_body)
    assert is_binary(address)

    message_body = Jason.encode!(%{"message" => "hello from keyring"})

    sign_conn =
      signed_conn("POST", "/internal/keyring/sign-message", message_body, "router-secret")

    sign_response = call_endpoint(sign_conn)
    assert sign_response.status == 200

    %{"signature" => signature} = Jason.decode!(sign_response.resp_body)
    assert is_binary(signature)
    assert String.starts_with?(signature, "0x")
    assert byte_size(signature) == 132

    transaction_body =
      Jason.encode!(%{
        "transaction" => wallet_action(address, "keyring-test-transaction")
      })

    transaction_response =
      signed_conn("POST", "/internal/keyring/sign-transaction", transaction_body, "router-secret")
      |> call_endpoint()

    assert transaction_response.status == 200

    assert %{
             "transaction" => %{"to" => ^address, "value" => "0x0"},
             "signature" => %{
               "purpose" => "raw",
               "signer_type" => "eoa",
               "digest" => digest,
               "signature" => raw_signature,
               "public_key" => public_key,
               "address" => ^address
             }
           } = Jason.decode!(transaction_response.resp_body)

    for value <- [digest, raw_signature, public_key] do
      assert is_binary(value)
      assert String.starts_with?(value, "0x")
    end
  end

  test "internal keyring routes reject requests with a bad signature" do
    conn =
      conn("POST", "/internal/keyring/has-wallet", "{}")
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-keyring-timestamp", "123")
      |> put_req_header("x-keyring-signature", "bad")

    response = call_endpoint(conn)
    assert response.status == 401
    assert Jason.decode!(response.resp_body) == %{"error" => "unauthorized"}
  end

  test "internal keyring routes are rate limited before protected work" do
    Application.put_env(:siwa_server, :rate_limits,
      keyring_internal: [limit: 1, window_ms: 60_000]
    )

    conn =
      conn("POST", "/internal/keyring/has-wallet", "{}")
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-keyring-timestamp", "123")
      |> put_req_header("x-keyring-signature", "bad")

    first_response = call_endpoint(conn)
    assert first_response.status == 401

    second_response = call_endpoint(conn)
    assert second_response.status == 429
    assert_retry_after(second_response)
    assert %{"error" => %{"code" => "rate_limited"}} = Jason.decode!(second_response.resp_body)
  end

  test "internal keyring routes require authentication on every protected route" do
    for {method, path, body} <- protected_keyring_requests() do
      response =
        conn(method, path, body)
        |> put_req_header("content-type", "application/json")
        |> call_endpoint()

      assert response.status == 401
      assert Jason.decode!(response.resp_body) == %{"error" => "unauthorized"}
    end
  end

  test "internal keyring routes reject unsupported media types before signing work" do
    response =
      conn("POST", "/internal/keyring/sign-message", "hello")
      |> put_req_header("content-type", "text/plain")
      |> call_endpoint()

    assert response.status == 415
    assert Jason.decode!(response.resp_body) == %{"error" => "unsupported_media_type"}
  end

  test "internal keyring replay protection is stored durably" do
    path = Path.join(System.tmp_dir!(), "siwa-keyring-#{System.unique_integer([:positive])}.json")
    old_env = Application.get_all_env(:siwa_keyring)
    request_id = "durable-replay-0001"

    Application.put_env(:siwa_keyring, :path, path)
    Application.put_env(:siwa_keyring, :password, "router-password")
    Application.put_env(:siwa_keyring, :secret, "router-secret")

    on_exit(fn ->
      File.rm(path)
      restore_keyring_env(old_env)
    end)

    first_response =
      signed_conn("POST", "/internal/keyring/has-wallet", "{}", "router-secret",
        request_id: request_id
      )
      |> call_endpoint()

    second_response =
      signed_conn("POST", "/internal/keyring/has-wallet", "{}", "router-secret",
        request_id: request_id
      )
      |> call_endpoint()

    assert first_response.status == 200
    assert second_response.status == 401

    assert %Postgrex.Result{rows: [[1]]} =
             Repo.query!(
               "SELECT COUNT(*) FROM siwa_request_replays WHERE replay_key = $1",
               ["keyring:#{request_id}"]
             )
  end

  test "internal keyring routes accept signed requests with no body" do
    path = Path.join(System.tmp_dir!(), "siwa-keyring-#{System.unique_integer([:positive])}.json")
    old_env = Application.get_all_env(:siwa_keyring)

    Application.put_env(:siwa_keyring, :path, path)
    Application.put_env(:siwa_keyring, :password, "router-password")
    Application.put_env(:siwa_keyring, :secret, "router-secret")

    on_exit(fn ->
      File.rm(path)
      restore_keyring_env(old_env)
    end)

    headers =
      SiwaKeyring.Auth.compute_hmac("router-secret", "POST", "/internal/keyring/has-wallet", "")

    response =
      conn("POST", "/internal/keyring/has-wallet")
      |> put_req_header("x-keyring-timestamp", headers["x-keyring-timestamp"])
      |> put_req_header("x-keyring-request-id", headers["x-keyring-request-id"])
      |> put_req_header("x-keyring-signature", headers["x-keyring-signature"])
      |> call_endpoint()

    assert response.status == 200
    assert Jason.decode!(response.resp_body) == %{"has_wallet" => false}
  end

  test "internal keyring routes reject empty signing inputs" do
    path = Path.join(System.tmp_dir!(), "siwa-keyring-#{System.unique_integer([:positive])}.json")
    old_env = Application.get_all_env(:siwa_keyring)

    Application.put_env(:siwa_keyring, :path, path)
    Application.put_env(:siwa_keyring, :password, "router-password")
    Application.put_env(:siwa_keyring, :secret, "router-secret")

    on_exit(fn ->
      File.rm(path)
      restore_keyring_env(old_env)
    end)

    message_response =
      signed_conn("POST", "/internal/keyring/sign-message", "{}", "router-secret")
      |> call_endpoint()

    assert message_response.status == 400
    assert Jason.decode!(message_response.resp_body) == %{"error" => "message_required"}

    raw_message_response =
      signed_conn("POST", "/internal/keyring/sign-raw-message", "{}", "router-secret")
      |> call_endpoint()

    assert raw_message_response.status == 400
    assert Jason.decode!(raw_message_response.resp_body) == %{"error" => "payload_required"}

    transaction_response =
      signed_conn(
        "POST",
        "/internal/keyring/sign-transaction",
        ~s({"transaction":{}}),
        "router-secret"
      )
      |> call_endpoint()

    assert transaction_response.status == 400
    assert Jason.decode!(transaction_response.resp_body) == %{"error" => "transaction_required"}

    authorization_response =
      signed_conn(
        "POST",
        "/internal/keyring/sign-authorization",
        ~s({"authorization":{}}),
        "router-secret"
      )
      |> call_endpoint()

    assert authorization_response.status == 400

    assert Jason.decode!(authorization_response.resp_body) == %{
             "error" => "authorization_required"
           }
  end

  test "internal keyring sign-authorization returns the signed wallet-action envelope" do
    with_keyring_env(fn ->
      create_response =
        signed_conn("POST", "/internal/keyring/create-wallet", "{}", "router-secret")
        |> call_endpoint()

      assert create_response.status == 200
      %{"address" => address} = Jason.decode!(create_response.resp_body)

      authorization = wallet_action(address, "keyring-test-authorization")
      body = Jason.encode!(%{"authorization" => authorization})

      response =
        signed_conn("POST", "/internal/keyring/sign-authorization", body, "router-secret")
        |> call_endpoint()

      assert response.status == 200

      assert %{
               "authorization" => ^authorization,
               "signature" => %{
                 "purpose" => "raw",
                 "signer_type" => "eoa",
                 "digest" => digest,
                 "signature" => raw_signature,
                 "public_key" => public_key,
                 "address" => ^address
               }
             } = Jason.decode!(response.resp_body)

      for value <- [digest, raw_signature, public_key] do
        assert is_binary(value)
        assert String.starts_with?(value, "0x")
      end
    end)
  end

  test "internal keyring signer requests reject an unexpected signer" do
    with_keyring_env(fn ->
      create_response =
        signed_conn("POST", "/internal/keyring/create-wallet", "{}", "router-secret")
        |> call_endpoint()

      assert create_response.status == 200
      %{"address" => address} = Jason.decode!(create_response.resp_body)

      wrong_signer = "0x2222222222222222222222222222222222222222"

      transaction =
        wallet_action(address, "keyring-test-unexpected-tx", %{"expected_signer" => wrong_signer})

      transaction_response =
        signed_conn(
          "POST",
          "/internal/keyring/sign-transaction",
          Jason.encode!(%{"transaction" => transaction}),
          "router-secret"
        )
        |> call_endpoint()

      assert transaction_response.status == 422

      assert Jason.decode!(transaction_response.resp_body) == %{
               "error" => "transaction_sign_failed"
             }

      authorization =
        wallet_action(address, "keyring-test-unexpected", %{"expected_signer" => wrong_signer})

      response =
        signed_conn(
          "POST",
          "/internal/keyring/sign-authorization",
          Jason.encode!(%{"authorization" => authorization}),
          "router-secret"
        )
        |> call_endpoint()

      assert response.status == 422
      assert Jason.decode!(response.resp_body) == %{"error" => "authorization_sign_failed"}
    end)
  end

  test "internal keyring routes return a clean error when the wallet is missing" do
    path = Path.join(System.tmp_dir!(), "siwa-keyring-#{System.unique_integer([:positive])}.json")
    old_env = Application.get_all_env(:siwa_keyring)

    Application.put_env(:siwa_keyring, :path, path)
    Application.put_env(:siwa_keyring, :password, "router-password")
    Application.put_env(:siwa_keyring, :secret, "router-secret")

    on_exit(fn ->
      File.rm(path)
      restore_keyring_env(old_env)
    end)

    address_response =
      signed_conn("POST", "/internal/keyring/get-address", "{}", "router-secret")
      |> call_endpoint()

    assert address_response.status == 404
    assert Jason.decode!(address_response.resp_body) == %{"error" => "wallet_not_found"}

    sign_response =
      signed_conn(
        "POST",
        "/internal/keyring/sign-message",
        Jason.encode!(%{"message" => "hello from keyring"}),
        "router-secret"
      )
      |> call_endpoint()

    assert sign_response.status == 422
    assert Jason.decode!(sign_response.resp_body) == %{"error" => "message_sign_failed"}
  end

  test "internal keyring has-wallet returns false when the wallet path is missing" do
    old_env = Application.get_all_env(:siwa_keyring)
    Application.put_env(:siwa_keyring, :path, nil)
    Application.put_env(:siwa_keyring, :password, "router-password")
    Application.put_env(:siwa_keyring, :secret, "router-secret")

    on_exit(fn ->
      restore_keyring_env(old_env)
    end)

    response =
      signed_conn("POST", "/internal/keyring/has-wallet", "{}", "router-secret")
      |> call_endpoint()

    assert response.status == 200
    assert Jason.decode!(response.resp_body) == %{"has_wallet" => false}
  end

  test "internal keyring body reader preserves the full raw body across multiple reads" do
    raw_body = String.duplicate("a", 20)
    conn = conn("POST", "/internal/keyring/sign-message", raw_body)

    assert {:more, "aaaaa", conn} =
             SiwaKeyring.Router.read_body(conn, length: 5)

    assert conn.private[:raw_body] == "aaaaa"

    assert {:more, "aaaaa", conn} =
             SiwaKeyring.Router.read_body(conn, length: 5)

    assert conn.private[:raw_body] == "aaaaaaaaaa"

    assert {:more, "aaaaa", conn} =
             SiwaKeyring.Router.read_body(conn, length: 5)

    assert conn.private[:raw_body] == "aaaaaaaaaaaaaaa"

    assert {:ok, "aaaaa", conn} = SiwaKeyring.Router.read_body(conn, length: 5)
    assert conn.private[:raw_body] == raw_body
  end

  test "internal keyring routes reject oversized bodies before signing work" do
    body =
      Jason.encode!(%{"message" => String.duplicate("a", SiwaKeyring.Router.max_body_bytes())})

    response =
      signed_conn("POST", "/internal/keyring/sign-message", body, "router-secret")
      |> call_endpoint()

    assert response.status == 413
    assert Jason.decode!(response.resp_body) == %{"error" => "request_body_too_large"}
  end

  defp with_keyring_env(fun) do
    path = Path.join(System.tmp_dir!(), "siwa-keyring-#{System.unique_integer([:positive])}.json")
    old_env = Application.get_all_env(:siwa_keyring)

    Application.put_env(:siwa_keyring, :path, path)
    Application.put_env(:siwa_keyring, :password, "router-password")
    Application.put_env(:siwa_keyring, :secret, "router-secret")

    try do
      fun.()
    after
      File.rm(path)
      restore_keyring_env(old_env)
    end
  end

  defp wallet_action(address, idempotency_key, overrides \\ %{}) do
    Map.merge(
      %{
        "chain_id" => 8453,
        "to" => address,
        "value" => "0x0",
        "data" => "0x",
        "expected_signer" => address,
        "expires_at" => "2099-01-01T00:00:00Z",
        "risk_copy" => "Test wallet action",
        "idempotency_key" => idempotency_key
      },
      overrides
    )
  end

  defp protected_keyring_requests do
    address = "0x1111111111111111111111111111111111111111"

    [
      {"POST", "/internal/keyring/create-wallet", "{}"},
      {"POST", "/internal/keyring/has-wallet", "{}"},
      {"POST", "/internal/keyring/get-address", "{}"},
      {"POST", "/internal/keyring/sign-message", Jason.encode!(%{"message" => "hello"})},
      {"POST", "/internal/keyring/sign-raw-message", Jason.encode!(%{"payload" => "hello"})},
      {"POST", "/internal/keyring/sign-transaction",
       Jason.encode!(%{"transaction" => wallet_action(address, "keyring-auth-transaction")})},
      {"POST", "/internal/keyring/sign-authorization",
       Jason.encode!(%{"authorization" => wallet_action(address, "keyring-auth-authorization")})}
    ]
  end

  defp assert_retry_after(conn) do
    assert [value] = Plug.Conn.get_resp_header(conn, "retry-after")
    assert String.to_integer(value) > 0
  end
end
