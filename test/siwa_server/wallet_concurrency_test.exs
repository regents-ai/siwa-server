defmodule SiwaServer.WalletConcurrencyTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias SiwaServer.{Repo, RuntimeConfig}
  alias SiwaServer.Siwa.{NonceRecord, ReplayStore, Wallet}
  import Ecto.Query

  test "committed wallet nonce and replay have one winner across independent connections" do
    assert String.starts_with?(Repo.config()[:database], "siwa_server_test")
    previous = Application.get_env(:siwa_server, :siwa)

    Application.put_env(
      :siwa_server,
      :siwa,
      Keyword.put(previous, :wallet_origins, %{"patchbay" => "https://patchbay.help"})
    )

    on_exit(fn -> Application.put_env(:siwa_server, :siwa, previous) end)

    {:ok, signer} = Siwa.LocalSigner.new()
    params = %{"wallet_address" => signer.address, "chain_id" => 8453, "audience" => "patchbay"}
    {:ok, nonce} = Sandbox.unboxed_run(Repo, fn -> Wallet.issue_nonce(params) end)
    nonce_value = nonce["data"]["nonce"]
    replay_key = "wallet-committed:#{Ecto.UUID.generate()}"

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(
          from n in NonceRecord, where: n.address == ^signer.address and n.nonce == ^nonce_value
        )

        Repo.query!("DELETE FROM siwa_request_replays WHERE replay_key = $1", [replay_key])
      end)
    end)

    {:ok, signature} = Siwa.LocalSigner.sign_message(signer, nonce["data"]["message"])

    proof =
      Map.merge(params, %{
        "nonce" => nonce_value,
        "message" => nonce["data"]["message"],
        "signature" => signature
      })

    results = concurrently(fn -> Wallet.verify(proof) end)
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, {404, "nonce_not_found", _}}, &1)) == 3

    [{:ok, verified}] = Enum.filter(results, &match?({:ok, _}, &1))
    {:ok, secret} = RuntimeConfig.siwa_receipt_secret()

    assert {:ok, %{"typ" => "siwa_wallet_receipt"}} =
             Siwa.verify_receipt(verified["data"]["receipt"],
               secret: secret,
               audience: "patchbay"
             )

    expires = System.system_time(:second) + 30
    replay_results = concurrently(fn -> ReplayStore.consume(replay_key, expires) end)
    assert Enum.count(replay_results, &(&1 == :ok)) == 1
    assert Enum.count(replay_results, &(&1 == {:error, :replayed_request})) == 3

    expired_key = replay_key <> ":expired"

    expired_results =
      concurrently(fn -> ReplayStore.consume(expired_key, System.system_time(:second) - 1) end)

    assert expired_results == List.duplicate({:error, :replayed_request}, 4)
  end

  defp concurrently(fun) do
    1..4
    |> Task.async_stream(fn _ -> Sandbox.unboxed_run(Repo, fun) end, max_concurrency: 4)
    |> Enum.map(fn {:ok, value} -> value end)
  end
end
