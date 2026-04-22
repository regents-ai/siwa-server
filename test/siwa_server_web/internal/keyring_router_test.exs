defmodule SiwaServerWeb.Internal.KeyringRouterTest do
  use SiwaServerWeb.ConnCase, async: false

  import Plug.Conn
  import Plug.Test

  defp call_endpoint(conn), do: SiwaServerWeb.Endpoint.call(conn, [])

  defp signed_conn(method, path, body, secret) do
    headers = SiwaKeyring.Auth.compute_hmac(secret, method, path, body)

    conn(method, path, body)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-keyring-timestamp", headers["x-keyring-timestamp"])
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
    assert signature["address"] == address
    assert signature["purpose"] == "personal_sign"
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

  test "internal keyring has-wallet failures do not crash the route" do
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

    assert response.status == 422
    assert Jason.decode!(response.resp_body) == %{"error" => "wallet_check_failed"}
  end

  test "internal keyring body reader preserves the full raw body across multiple reads" do
    raw_body = String.duplicate("a", 20)
    conn = conn("POST", "/internal/keyring/sign-message", raw_body)

    assert {:more, "aaaaa", conn} =
             SiwaServerWeb.Internal.KeyringRouter.read_body(conn, length: 5)

    assert conn.private[:raw_body] == "aaaaa"

    assert {:more, "aaaaa", conn} =
             SiwaServerWeb.Internal.KeyringRouter.read_body(conn, length: 5)

    assert conn.private[:raw_body] == "aaaaaaaaaa"

    assert {:more, "aaaaa", conn} =
             SiwaServerWeb.Internal.KeyringRouter.read_body(conn, length: 5)

    assert conn.private[:raw_body] == "aaaaaaaaaaaaaaa"

    assert {:ok, "aaaaa", conn} = SiwaServerWeb.Internal.KeyringRouter.read_body(conn, length: 5)
    assert conn.private[:raw_body] == raw_body
  end
end
