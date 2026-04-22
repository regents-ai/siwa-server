defmodule SiwaServer.RuntimeConfigTest do
  use ExUnit.Case, async: false

  alias SiwaServer.RuntimeConfig

  setup do
    original = System.get_env("BASE_RPC_URL")

    on_exit(fn ->
      if is_nil(original) do
        System.delete_env("BASE_RPC_URL")
      else
        System.put_env("BASE_RPC_URL", original)
      end
    end)

    :ok
  end

  test "base rpc url is absent when BASE_RPC_URL is unset" do
    System.delete_env("BASE_RPC_URL")

    assert RuntimeConfig.base_rpc_url() == nil
  end

  test "base rpc url is trimmed from BASE_RPC_URL" do
    System.put_env("BASE_RPC_URL", " https://base.example/rpc ")

    assert RuntimeConfig.base_rpc_url() == "https://base.example/rpc"
  end
end
