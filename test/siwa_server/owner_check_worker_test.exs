defmodule SiwaServer.AgentRegistration.OwnerCheckWorkerTest do
  use SiwaServer.DataCase, async: false
  use Oban.Testing, repo: SiwaServer.Repo

  import ExUnit.CaptureLog

  alias SiwaServer.{AgentRegistration, TestRpcServer}
  alias SiwaServer.AgentRegistration.{OwnerCheckWorker, Record}

  @registry "0x8004a169fb4a3325136eb29fa0ceb6d2e539a432"
  @owner_of "0x6352211e"
  @wallet "0x38d856b4617c9da5caeb4a6f12606249beb19161"
  @buyer "0x1111111111111111111111111111111111111111"

  setup do
    previous = System.get_env("BASE_RPC_URL")

    on_exit(fn ->
      if previous,
        do: System.put_env("BASE_RPC_URL", previous),
        else: System.delete_env("BASE_RPC_URL")
    end)
  end

  test "a listing ends when its token leaves the wallet, and is listed again when it returns" do
    insert!("9")
    insert!("10")
    assert %{"tokenId" => "10"} = AgentRegistration.latest(@wallet)

    base_answers(%{"9" => {:owner, @wallet}, "10" => {:owner, @buyer}})
    assert :ok = perform_job(OwnerCheckWorker, %{})
    assert status("9") == :listed
    assert status("10") == :ended
    assert %{"tokenId" => "9"} = AgentRegistration.latest(@wallet)

    base_answers(%{"9" => {:owner, @wallet}, "10" => {:owner, @wallet}})
    assert :ok = perform_job(OwnerCheckWorker, %{})
    assert status("10") == :listed
    assert %{"tokenId" => "10"} = AgentRegistration.latest(@wallet)
  end

  test "a token that does not exist ends its listing" do
    insert!("9")

    base_answers(%{"9" => :reverts})
    assert :ok = perform_job(OwnerCheckWorker, %{})
    assert status("9") == :ended
    assert AgentRegistration.latest(@wallet) == nil
  end

  test "a failed read leaves that listing as it was, with a warning, and the others are checked" do
    insert!("9", :ended)
    insert!("10")
    insert!("11")

    base_answers(%{"9" => :fails, "10" => :fails_unnamed, "11" => {:owner, @buyer}})

    log = capture_log(fn -> assert :ok = perform_job(OwnerCheckWorker, %{}) end)

    assert log =~ "[warning] registry owner check failed token_id=9 reason=header not found"
    assert log =~ "[warning] registry owner check failed token_id=10 reason=rpc request failed"
    assert status("9") == :ended
    assert status("10") == :listed
    assert status("11") == :ended
  end

  test "an answer that is not an address leaves the listing as it was" do
    insert!("9")
    insert!("10")

    base_answers(%{
      "9" => {:answer, "0x" <> String.duplicate("z", 64)},
      "10" => {:answer, "0x" <> String.duplicate("f", 64)}
    })

    log = capture_log(fn -> assert :ok = perform_job(OwnerCheckWorker, %{}) end)

    assert log =~ "registry owner check failed token_id=9 reason=the registry answered"
    assert log =~ "registry owner check failed token_id=10 reason=the registry answered"
    assert status("9") == :listed
    assert status("10") == :listed
  end

  # Both are listed in the same second, so the larger token, as a number, is the newer.
  defp insert!(token_id, status \\ :listed) do
    Repo.insert!(%Record{
      profile_id: String.duplicate("a", 32),
      wallet_address: @wallet,
      name: "Astra",
      description: "Finds bugs in Elixir code.",
      token_id: token_id,
      tx_hash: "0x" <> String.pad_leading(token_id, 64, "0"),
      status: status,
      inserted_at: ~U[2026-11-01 00:00:00Z],
      updated_at: ~U[2026-11-01 00:00:00Z]
    })
  end

  defp status(token_id), do: Repo.get_by!(Record, token_id: token_id).status

  # Base answering the registry's ownerOf for each token: its owner, a raw
  # answer, a revert as for a token that does not exist, or a provider failure
  # with or without a message.
  defp base_answers(answers) do
    url =
      TestRpcServer.start(fn request ->
        [_head, body] = String.split(request, "\r\n\r\n", parts: 2)

        %{
          "method" => "eth_call",
          "params" => [%{"to" => @registry, "data" => @owner_of <> word}, "latest"]
        } = Jason.decode!(body)

        case Map.fetch!(answers, word |> String.to_integer(16) |> Integer.to_string()) do
          {:owner, "0x" <> address} ->
            %{
              "id" => 1,
              "jsonrpc" => "2.0",
              "result" => "0x" <> String.pad_leading(address, 64, "0")
            }

          {:answer, result} ->
            %{"id" => 1, "jsonrpc" => "2.0", "result" => result}

          :reverts ->
            error(3, "execution reverted", "0x7e273289" <> word)

          :fails ->
            error(-32_000, "header not found", nil)

          :fails_unnamed ->
            %{"id" => 1, "jsonrpc" => "2.0", "error" => %{"code" => -32_603}}
        end
      end)

    System.put_env("BASE_RPC_URL", url)
  end

  defp error(code, message, data),
    do: %{
      "id" => 1,
      "jsonrpc" => "2.0",
      "error" => %{"code" => code, "message" => message, "data" => data}
    }
end
