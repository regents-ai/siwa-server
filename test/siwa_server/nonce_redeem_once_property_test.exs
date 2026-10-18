defmodule SiwaServer.NonceRedeemOncePropertyTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias SiwaServer.{Ethereum, Repo}
  alias SiwaServer.Siwa.{NonceRecord, Wallet}

  setup do
    assert String.starts_with?(Repo.config()[:database], "siwa_server_test")
    previous = Application.get_env(:siwa_server, :siwa)

    Application.put_env(
      :siwa_server,
      :siwa,
      Keyword.put(previous, :wallet_origins, %{"patchbay" => ["https://patchbay.help"]})
    )

    on_exit(fn -> Application.put_env(:siwa_server, :siwa, previous) end)
  end

  # A signed sign-in challenge gives one receipt however many redeemers race for it,
  # each on its own committed connection; every other redeemer is told it is used.
  property "a challenge redeems once under any number of concurrent redeemers" do
    check all redeemers <- integer(2..16),
              chain_id <- member_of(Ethereum.wallet_chain_ids()),
              max_runs: 25 do
      {:ok, signer} = Siwa.LocalSigner.new()

      params = %{
        "wallet_address" => signer.address,
        "chain_id" => chain_id,
        "audience" => "patchbay"
      }

      {:ok, %{"data" => challenge}} =
        Sandbox.unboxed_run(Repo, fn -> Wallet.issue_nonce(params) end)

      {:ok, signature} = Siwa.LocalSigner.sign_message(signer, challenge["message"])

      proof =
        Map.merge(params, %{
          "nonce" => challenge["nonce"],
          "message" => challenge["message"],
          "signature" => signature
        })

      try do
        results =
          1..redeemers
          |> Task.async_stream(
            fn _ -> Sandbox.unboxed_run(Repo, fn -> Wallet.verify(proof) end) end,
            max_concurrency: redeemers,
            ordered: false
          )
          |> Enum.map(fn {:ok, result} -> result end)

        assert Enum.count(results, &match?({:ok, %{"code" => "wallet_verified"}}, &1)) == 1

        assert Enum.count(results, &match?({:error, {404, "nonce_not_found", _}}, &1)) ==
                 redeemers - 1
      after
        address = String.downcase(signer.address)

        Sandbox.unboxed_run(Repo, fn ->
          Repo.delete_all(from n in NonceRecord, where: n.address == ^address)
        end)
      end
    end
  end
end
