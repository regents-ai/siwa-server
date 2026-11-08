defmodule SiwaServer.ReadinessTest do
  use SiwaServerWeb.ConnCase, async: false

  alias SiwaServer.HostedIdentities
  alias SiwaServer.Readiness
  alias SiwaServer.TestRpcServer

  setup do
    original_base_rpc_url = System.get_env("BASE_RPC_URL")
    original_ethereum_rpc_url = System.get_env("ETHEREUM_RPC_URL")
    original_world_rpc_url = System.get_env("WORLD_RPC_URL")
    System.put_env("ETHEREUM_RPC_URL", TestRpcServer.chain_id(1))
    System.put_env("WORLD_RPC_URL", TestRpcServer.chain_id(480))

    on_exit(fn ->
      restore_env("BASE_RPC_URL", original_base_rpc_url)
      restore_env("ETHEREUM_RPC_URL", original_ethereum_rpc_url)
      restore_env("WORLD_RPC_URL", original_world_rpc_url)
    end)

    :ok
  end

  test "reports ready with no failures when every check passes" do
    System.put_env("BASE_RPC_URL", TestRpcServer.chain_id(8453))

    assert %{ready: true, checks: checks, failures: failures} = Readiness.check()
    assert Enum.all?(checks, fn {_name, passed?} -> passed? == true end)
    assert failures == %{}
  end

  test "failing checks carry a reason string" do
    System.delete_env("BASE_RPC_URL")

    assert %{ready: false, checks: checks, failures: failures} = Readiness.check()
    assert checks.database == true
    assert checks.base_rpc_url == false
    assert checks.base_rpc_chain_id == false
    assert failures.base_rpc_url =~ "BASE_RPC_URL is not configured"
    assert failures.base_rpc_chain_id =~ "BASE_RPC_URL is not configured"
    refute Map.has_key?(failures, :database)
  end

  test "a wrong chain id fails readiness with the returned chain id in the reason" do
    System.put_env("BASE_RPC_URL", TestRpcServer.chain_id(1))

    assert %{ready: false, checks: checks, failures: failures} = Readiness.check()
    assert checks.base_rpc_chain_id == false
    assert failures.base_rpc_chain_id =~ "0x1"
    assert failures.base_rpc_chain_id =~ "expected 0x2105"
  end

  test "Ethereum is checked like Base: configured, and answering as chain 1" do
    System.put_env("BASE_RPC_URL", TestRpcServer.chain_id(8453))
    System.delete_env("ETHEREUM_RPC_URL")

    assert %{ready: false, failures: failures} = Readiness.check()
    assert failures.ethereum_rpc_url =~ "ETHEREUM_RPC_URL is not configured"

    System.put_env("ETHEREUM_RPC_URL", TestRpcServer.chain_id(8453))

    assert %{ready: false, checks: checks, failures: failures} = Readiness.check()
    assert checks.ethereum_rpc_url == true
    assert failures.ethereum_rpc_chain_id =~ "expected 0x1"
    refute Map.has_key?(failures, :base_rpc_chain_id)
  end

  test "the key store password must open the stored hosted keys" do
    System.put_env("BASE_RPC_URL", TestRpcServer.chain_id(8453))
    assert %{ready: true, checks: %{hosted_keys: true}} = Readiness.check()

    assert {:ok, _address} = HostedIdentities.ensure(String.duplicate("a", 64))
    assert %{ready: true, checks: %{hosted_keys: true}} = Readiness.check()

    siwa = Application.get_env(:siwa_server, :siwa)
    on_exit(fn -> Application.put_env(:siwa_server, :siwa, siwa) end)
    Application.put_env(:siwa_server, :siwa, Keyword.put(siwa, :keystore_password, "another"))

    assert %{ready: false, checks: checks, failures: failures} = Readiness.check()
    assert checks.hosted_keys == false
    assert checks.keystore_password == true
    assert failures == %{hosted_keys: "KEYSTORE_PASSWORD does not open the stored hosted keys"}
  end

  test "GET /readyz reports per-check status and logs the failure reasons", %{conn: conn} do
    System.delete_env("BASE_RPC_URL")

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        conn = get(conn, ~p"/readyz")
        body = json_response(conn, 503)

        assert Map.keys(body) |> Enum.sort() == ["checks", "ready"]
        assert body["ready"] == false
        assert body["checks"]["base_rpc_url"] == false
        assert Enum.all?(body["checks"], fn {_name, value} -> is_boolean(value) end)
      end)

    assert log =~ "check=base_rpc_url reason=BASE_RPC_URL is not configured"
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
