defmodule SiwaServer.AgentBookTest do
  use SiwaServer.DataCase, async: false
  use Oban.Testing, repo: SiwaServer.Repo

  alias SiwaServer.{AgentBook, TestRpcServer}

  @wallet "0x38d856b4617c9da5caeb4a6f12606249beb19161"
  @human 0x0D8E5AF4D20A7F4E9C1B2A3F4E5D6C7B8A9F0E1D2C3B4A5968778695A4B3C2D1

  setup do
    previous = System.get_env("WORLD_RPC_URL")

    on_exit(fn ->
      if previous,
        do: System.put_env("WORLD_RPC_URL", previous),
        else: System.delete_env("WORLD_RPC_URL")
    end)
  end

  test "keeps the person World's AgentBook names behind the wallet, and forgets it when it names none" do
    world_answers(@human)

    assert :ok = perform_job(AgentBook.Refresh, %{wallet_address: String.upcase(@wallet)})

    assert_receive {:eth_call,
                    %{"to" => "0xa23ab2712ea7bba896930544c7d6636a96b944da", "data" => data}}

    assert data == "0x451a02f4" <> String.pad_leading(String.trim_leading(@wallet, "0x"), 64, "0")

    assert AgentBook.human(@wallet) == %{
             "humanId" => "0x0d8e5af4d20a7f4e9c1b2a3f4e5d6c7b8a9f0e1d2c3b4a5968778695a4b3c2d1"
           }

    world_answers(0)
    assert :ok = perform_job(AgentBook.Refresh, %{wallet_address: @wallet})
    assert AgentBook.human(@wallet) == nil
  end

  test "a failed read retries and keeps what was saved" do
    world_answers(@human)
    assert :ok = AgentBook.refresh(@wallet)

    System.put_env("WORLD_RPC_URL", TestRpcServer.rpc_error())
    assert {:error, "provider error"} = perform_job(AgentBook.Refresh, %{wallet_address: @wallet})
    assert %{"humanId" => _number} = AgentBook.human(@wallet)
  end

  defp world_answers(human_id) do
    test = self()

    url =
      TestRpcServer.start(fn request ->
        [_head, body] = String.split(request, "\r\n\r\n", parts: 2)
        %{"method" => "eth_call", "params" => [call, "latest"]} = Jason.decode!(body)
        send(test, {:eth_call, call})
        word = human_id |> Integer.to_string(16) |> String.pad_leading(64, "0")
        %{"id" => 1, "jsonrpc" => "2.0", "result" => "0x" <> word}
      end)

    System.put_env("WORLD_RPC_URL", url)
  end
end
