defmodule SiwaServer.ReadinessTest do
  use SiwaServerWeb.ConnCase, async: false

  alias SiwaServer.Readiness
  alias SiwaServer.TestRpcServer

  setup do
    original_base_rpc_url = System.get_env("BASE_RPC_URL")

    on_exit(fn ->
      restore_env("BASE_RPC_URL", original_base_rpc_url)
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

  test "GET /readyz reports per-check status and failure reasons", %{conn: conn} do
    System.delete_env("BASE_RPC_URL")

    conn = get(conn, ~p"/readyz")
    body = json_response(conn, 503)

    assert body["ready"] == false
    assert body["checks"]["base_rpc_url"] == false
    assert body["failures"]["base_rpc_url"] =~ "BASE_RPC_URL is not configured"
    assert Enum.all?(body["checks"], fn {_name, value} -> is_boolean(value) end)
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
