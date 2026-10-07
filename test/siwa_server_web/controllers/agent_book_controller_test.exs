defmodule SiwaServerWeb.AgentBookControllerTest do
  use SiwaServerWeb.ConnCase, async: false

  alias SiwaServer.{AgentBook, TestRpcServer, TestWallet}

  @human 0x0D8E5AF4D20A7F4E9C1B2A3F4E5D6C7B8A9F0E1D2C3B4A5968778695A4B3C2D1
  @number "0x0d8e5af4d20a7f4e9c1b2a3f4e5d6c7b8a9f0e1d2c3b4a5968778695a4b3c2d1"

  setup do
    previous = System.get_env("WORLD_RPC_URL")

    on_exit(fn ->
      if previous,
        do: System.put_env("WORLD_RPC_URL", previous),
        else: System.delete_env("WORLD_RPC_URL")
    end)
  end

  test "the wallet accepts the person AgentBook names once, and keeps them for good" do
    world_answers(@human, self())

    challenge = challenge() |> json_response(200) |> Map.fetch!("data")
    assert %{"humanId" => @number, "chainId" => 8453} = challenge
    assert challenge["message"] =~ "Wallet: #{TestWallet.address()}\nPerson: #{@number}"

    assert_receive {:eth_call,
                    %{"to" => "0xa23ab2712ea7bba896930544c7d6636a96b944da", "data" => data}}

    assert data ==
             "0x451a02f4" <>
               String.pad_leading(String.trim_leading(TestWallet.address(), "0x"), 64, "0")

    assert AgentBook.human(TestWallet.address()) == nil

    assert %{
             "code" => "agent_book_accepted",
             "data" => %{"walletAddress" => wallet, "humanId" => @number}
           } = accept(challenge) |> json_response(200)

    assert AgentBook.human(wallet) == %{"humanId" => @number, "agentCount" => 1}
    assert %{"code" => "nonce_not_found"} = accept(challenge) |> json_response(404) |> error()

    world_answers(@human + 1)

    assert %{"code" => "agent_book_already_accepted", "hint" => hint} =
             challenge() |> json_response(409) |> error()

    assert hint =~ "for good"
    assert AgentBook.human(wallet) == %{"humanId" => @number, "agentCount" => 1}
  end

  test "of two open challenges, only the first accepted counts" do
    world_answers(@human)
    first = challenge() |> json_response(200) |> Map.fetch!("data")
    second = challenge() |> json_response(200) |> Map.fetch!("data")

    assert accept(first) |> json_response(200)

    assert %{"code" => "agent_book_already_accepted"} =
             accept(second) |> json_response(409) |> error()
  end

  test "keeps nothing when AgentBook names someone else before the wallet signs" do
    world_answers(@human)
    challenge = challenge() |> json_response(200) |> Map.fetch!("data")

    world_answers(@human + 1)

    assert %{"code" => "agent_book_changed", "hint" => hint} =
             accept(challenge) |> json_response(409) |> error()

    assert hint =~ "Ask your person"
    assert AgentBook.human(TestWallet.address()) == nil
  end

  test "a wallet AgentBook does not list is told how its person vouches for it" do
    world_answers(0)

    assert %{"code" => "not_in_agent_book", "hint" => hint} =
             challenge() |> json_response(404) |> error()

    assert hint =~ "npx @worldcoin/agentkit-cli register"
  end

  defp world_answers(human_id, listener \\ nil),
    do: System.put_env("WORLD_RPC_URL", TestRpcServer.agent_book_answers(human_id, listener))

  defp params, do: %{"wallet_address" => TestWallet.address(), "chain_id" => 8453}

  defp challenge, do: json_post("/api/shared/siwa/agent-book/challenge", params())

  defp accept(challenge),
    do:
      json_post(
        "/api/shared/siwa/agent-book/accept",
        Map.merge(params(), %{
          "nonce" => challenge["nonce"],
          "message" => challenge["message"],
          "signature" => TestWallet.sign_message(challenge["message"])
        })
      )

  defp error(body), do: Map.fetch!(body, "error")

  defp json_post(path, params),
    do:
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post(path, Jason.encode!(params))
end
