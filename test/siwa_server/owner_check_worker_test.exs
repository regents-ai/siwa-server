defmodule SiwaServer.AgentRegistration.OwnerCheckWorkerTest do
  use SiwaServer.DataCase, async: false
  use Oban.Testing, repo: SiwaServer.Repo

  import ExUnit.CaptureLog

  alias RegentChain.Call
  alias SiwaServer.{AgentRegistration, TestRpcServer}
  alias SiwaServer.AgentRegistration.{Link, OwnerCheckWorker}

  @registry "0x8004a169fb4a3325136eb29fa0ceb6d2e539a432"
  @wallet "0x38d856b4617c9da5caeb4a6f12606249beb19161"
  @second "0x2222222222222222222222222222222222222222"
  @third "0x3333333333333333333333333333333333333333"
  @buyer "0x1111111111111111111111111111111111111111"

  setup do
    previous = System.get_env("BASE_RPC_URL")

    on_exit(fn ->
      if previous,
        do: System.put_env("BASE_RPC_URL", previous),
        else: System.delete_env("BASE_RPC_URL")
    end)
  end

  test "a link ends when the registry stops naming the wallet, and is listed again when it does" do
    insert!(@wallet, "10")
    assert %{"tokenId" => "10"} = AgentRegistration.latest(@wallet)

    base_answers(%{"10" => {:owner, @buyer}})
    assert :ok = perform_job(OwnerCheckWorker, %{})
    assert status(@wallet) == :ended
    assert AgentRegistration.latest(@wallet) == nil

    base_answers(%{"10" => {:agent_wallet, @wallet}})
    assert :ok = perform_job(OwnerCheckWorker, %{})
    assert status(@wallet) == :listed
    assert %{"tokenId" => "10"} = AgentRegistration.latest(@wallet)

    base_answers(%{"10" => {:owner, @wallet}})
    assert :ok = perform_job(OwnerCheckWorker, %{})
    assert status(@wallet) == :listed
  end

  test "an agent that does not exist ends its link" do
    insert!(@wallet, "9")

    base_answers(%{"9" => :reverts})
    assert :ok = perform_job(OwnerCheckWorker, %{})
    assert status(@wallet) == :ended
    assert AgentRegistration.latest(@wallet) == nil
  end

  test "a failed read leaves that link as it was, with a warning, and the others are checked" do
    insert!(@wallet, "9", :ended)
    insert!(@second, "10")
    insert!(@third, "11")

    base_answers(%{"9" => :fails, "10" => :fails_unnamed, "11" => {:owner, @buyer}})

    log = capture_log(fn -> assert :ok = perform_job(OwnerCheckWorker, %{}) end)

    assert log =~ "[warning] registry owner check failed token_id=9 reason=header not found"
    assert log =~ "[warning] registry owner check failed token_id=10 reason=rpc request failed"
    assert status(@wallet) == :ended
    assert status(@second) == :listed
    assert status(@third) == :ended
  end

  test "an answer that is not an address leaves the link as it was" do
    insert!(@wallet, "9")
    insert!(@second, "10")

    base_answers(%{
      "9" => {:answer, "0x" <> String.duplicate("z", 64)},
      "10" => {:answer, "0x" <> String.duplicate("f", 64)}
    })

    log = capture_log(fn -> assert :ok = perform_job(OwnerCheckWorker, %{}) end)

    assert log =~
             "registry owner check failed token_id=9 reason=the registry's answer to ownerOf(uint256) is malformed"

    assert log =~
             "registry owner check failed token_id=10 reason=the registry's answer to ownerOf(uint256) is malformed"

    assert status(@wallet) == :listed
    assert status(@second) == :listed
  end

  defp insert!(wallet_address, token_id, status \\ :listed) do
    Repo.insert!(%Link{
      wallet_address: wallet_address,
      token_id: token_id,
      profile_url: "https://agent.example/agent.json",
      status: status
    })
  end

  defp status(wallet_address), do: Repo.get!(Link, wallet_address).status

  # Base answering the registry for each agent: getAgentWallet names the zero
  # address unless the agent wallet is given; ownerOf answers its owner, a raw
  # answer, a revert as for an agent that does not exist, or a provider failure
  # with or without a message.
  defp base_answers(answers) do
    get_agent_wallet = Call.selector("getAgentWallet(uint256)")
    owner_of = Call.selector("ownerOf(uint256)")

    url =
      TestRpcServer.start(fn request ->
        [_head, body] = String.split(request, "\r\n\r\n", parts: 2)

        %{"method" => "eth_call", "params" => [%{"to" => @registry, "data" => data}, "latest"]} =
          Jason.decode!(body)

        {selector, word} = String.split_at(data, 10)
        answer = Map.fetch!(answers, word |> String.to_integer(16) |> Integer.to_string())

        case {selector, answer} do
          {^get_agent_wallet, {:agent_wallet, address}} ->
            result(address)

          {^get_agent_wallet, _answer} ->
            result("0x" <> String.duplicate("0", 40))

          {^owner_of, {:owner, address}} ->
            result(address)

          {^owner_of, {:answer, raw}} ->
            %{"id" => 1, "jsonrpc" => "2.0", "result" => raw}

          {^owner_of, :reverts} ->
            error(3, "execution reverted", "0x7e273289" <> word)

          {^owner_of, :fails} ->
            error(-32_000, "header not found", nil)

          {^owner_of, :fails_unnamed} ->
            %{"id" => 1, "jsonrpc" => "2.0", "error" => %{"code" => -32_603}}
        end
      end)

    System.put_env("BASE_RPC_URL", url)
  end

  defp result("0x" <> address),
    do: %{"id" => 1, "jsonrpc" => "2.0", "result" => "0x" <> String.pad_leading(address, 64, "0")}

  defp error(code, message, data),
    do: %{
      "id" => 1,
      "jsonrpc" => "2.0",
      "error" => %{"code" => code, "message" => message, "data" => data}
    }
end
