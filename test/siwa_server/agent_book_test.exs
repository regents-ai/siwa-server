defmodule SiwaServer.AgentBookTest do
  use SiwaServer.DataCase, async: false
  use Oban.Testing, repo: SiwaServer.Repo

  alias SiwaServer.{AgentBook, TestRpcServer}

  @wallet "0x38d856b4617c9da5caeb4a6f12606249beb19161"
  @human 0x0D8E5AF4D20A7F4E9C1B2A3F4E5D6C7B8A9F0E1D2C3B4A5968778695A4B3C2D1
  @number "0x0d8e5af4d20a7f4e9c1b2a3f4e5d6c7b8a9f0e1d2c3b4a5968778695a4b3c2d1"

  setup do
    previous = System.get_env("WORLD_RPC_URL")

    on_exit(fn ->
      if previous,
        do: System.put_env("WORLD_RPC_URL", previous),
        else: System.delete_env("WORLD_RPC_URL")
    end)

    Repo.insert!(AgentBook.Acceptance.changeset(%{wallet_address: @wallet, human_id: @number}))
    :ok
  end

  test "names the person only while AgentBook still names the one the wallet accepted" do
    world_answers(@human)

    assert :ok = perform_job(AgentBook.Refresh, %{wallet_address: String.upcase(@wallet)})

    assert_receive {:eth_call,
                    %{"to" => "0xa23ab2712ea7bba896930544c7d6636a96b944da", "data" => data}}

    assert data == "0x451a02f4" <> String.pad_leading(String.trim_leading(@wallet, "0x"), 64, "0")
    assert AgentBook.human(@wallet) == %{"humanId" => @number, "agentCount" => 1}

    world_answers(@human + 1)
    assert :ok = perform_job(AgentBook.Refresh, %{wallet_address: @wallet})
    assert AgentBook.human(@wallet) == nil

    world_answers(0)
    assert :ok = perform_job(AgentBook.Refresh, %{wallet_address: @wallet})
    assert AgentBook.human(@wallet) == nil
  end

  test "counts the agent wallets that accepted the same person while AgentBook still names them" do
    other = "0x" <> String.duplicate("7", 40)
    Repo.insert!(AgentBook.Acceptance.changeset(%{wallet_address: other, human_id: @number}))
    world_answers(@human)
    assert :ok = AgentBook.refresh(@wallet)
    assert :ok = AgentBook.refresh(other)

    assert AgentBook.human(@wallet) == %{"humanId" => @number, "agentCount" => 2}

    world_answers(@human + 1)
    assert :ok = AgentBook.refresh(other)
    assert AgentBook.human(@wallet) == %{"humanId" => @number, "agentCount" => 1}
  end

  test "a failed read retries and keeps what was saved" do
    world_answers(@human)
    assert :ok = AgentBook.refresh(@wallet)

    System.put_env("WORLD_RPC_URL", TestRpcServer.rpc_error())
    assert {:error, "provider error"} = perform_job(AgentBook.Refresh, %{wallet_address: @wallet})
    assert AgentBook.human(@wallet) == %{"humanId" => @number, "agentCount" => 1}
  end

  defp world_answers(human_id),
    do: System.put_env("WORLD_RPC_URL", TestRpcServer.agent_book_answers(human_id, self()))
end
