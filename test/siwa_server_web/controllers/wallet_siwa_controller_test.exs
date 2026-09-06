defmodule SiwaServerWeb.WalletSiwaControllerTest do
  use SiwaServerWeb.ConnCase, async: false

  alias SiwaServer.{Repo, TestWallet}
  alias SiwaServer.Siwa.{NonceRecord, NonceStore, ReplayStore, Wallet}
  import Ecto.Query

  setup do
    previous = Application.get_env(:siwa_server, :siwa)

    Application.put_env(
      :siwa_server,
      :siwa,
      Keyword.put(previous, :wallet_origins, %{"patchbay" => "https://patchbay.help"})
    )

    on_exit(fn -> Application.put_env(:siwa_server, :siwa, previous) end)
    :ok
  end

  test "canonical EOA challenge yields wallet proof without registry or human identity" do
    nonce = issue()
    assert nonce["principalType"] == "wallet"
    assert nonce["nonce"] =~ ~r/^[a-f0-9]{32}$/
    assert nonce["message"] =~ "patchbay.help wants you to sign in with your Ethereum account:"
    assert nonce["message"] =~ "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
    assert nonce["message"] =~ "URI: https://patchbay.help\nVersion: 1\nChain ID: 8453"
    assert nonce["message"] =~ "urn:regent:audience:patchbay"
    assert nonce["message"] =~ "Nonce: #{nonce["nonce"]}"
    assert nonce["message"] =~ "Issued At: #{nonce["issuedAt"]}"
    assert nonce["message"] =~ "Expiration Time: #{nonce["expiresAt"]}"

    response = json_post("/api/shared/siwa/wallet/verify", proof(nonce)) |> json_response(200)
    assert response["code"] == "wallet_verified"
    data = response["data"]
    assert data["proof"] == "wallet_signature"
    assert data["walletAddress"] == TestWallet.address()
    refute Map.has_key?(data, "agentId")
    {:ok, claims} = Siwa.verify_receipt(data["receipt"], secret: secret(), audience: "patchbay")
    assert claims["typ"] == "siwa_wallet_receipt"
    assert claims["verified"] == "wallet_signature"
    refute Map.has_key?(claims, "token_id")
    refute Map.has_key?(claims, "registry_address")

    assert json_post("/api/shared/siwa/wallet/verify", proof(nonce)) |> json_response(404)
  end

  test "nonce and verification routes reject disabled audiences" do
    assert json_post("/api/shared/siwa/wallet/nonce", %{params() | "audience" => "techtree"})
           |> json_response(403)

    nonce = issue()
    config = Application.get_env(:siwa_server, :siwa)
    Application.put_env(:siwa_server, :siwa, Keyword.put(config, :wallet_origins, %{}))
    assert json_post("/api/shared/siwa/wallet/verify", proof(nonce)) |> json_response(403)
    assert Repo.aggregate(NonceRecord, :count) == 1
  end

  test "contract rejects unknown, missing and mistyped fields" do
    for bad <- [
          Map.put(params(), "registry_address", "0x" <> String.duplicate("1", 40)),
          Map.put(params(), "private_key", "not-a-key"),
          Map.delete(params(), "wallet_address"),
          %{params() | "chain_id" => "8453"},
          %{params() | "chain_id" => 1},
          %{params() | "wallet_address" => "bad"},
          %{params() | "audience" => String.duplicate("a", 201)}
        ] do
      assert json_post("/api/shared/siwa/wallet/nonce", bad) |> json_response(400)
    end

    nonce = issue()

    for bad <- [
          Map.put(proof(nonce), "unexpected", true),
          Map.put(proof(nonce), "message", nil),
          Map.put(proof(nonce), "nonce", "bad_nonce"),
          Map.put(proof(nonce), "signature", "0x1234")
        ] do
      assert json_post("/api/shared/siwa/wallet/verify", bad) |> json_response(400)
    end
  end

  test "legacy routes do not downgrade when agent registration fields are missing" do
    assert json_post("/api/shared/siwa/nonce", params()) |> json_response(400)
    assert json_post("/api/shared/siwa/verify", proof(issue())) |> json_response(400)
  end

  test "changed messages and signatures cannot burn the correct challenge" do
    nonce = issue()

    for message <- [
          nonce["message"] <> "\n",
          String.replace(nonce["message"], "patchbay.help", "attacker.test"),
          String.replace(nonce["message"], "Chain ID: 8453", "Chain ID: 1")
        ] do
      bad =
        Map.merge(proof(nonce), %{
          "message" => message,
          "signature" => TestWallet.sign_message(message)
        })

      assert json_post("/api/shared/siwa/wallet/verify", bad) |> json_response(401)
    end

    bad = Map.put(proof(nonce), "signature", TestWallet.sign_message("different proof"))
    assert json_post("/api/shared/siwa/wallet/verify", bad) |> json_response(401)
    assert json_post("/api/shared/siwa/wallet/verify", proof(nonce)) |> json_response(200)
  end

  test "wrong wallet cannot consume another wallet's challenge" do
    nonce = issue()
    bad = Map.put(proof(nonce), "wallet_address", "0x" <> String.duplicate("1", 40))
    assert json_post("/api/shared/siwa/wallet/verify", bad) |> json_response(404)
    assert json_post("/api/shared/siwa/wallet/verify", proof(nonce)) |> json_response(200)
  end

  test "expired challenges fail and the database refuses a delayed consume" do
    nonce = issue()
    record = Repo.one!(NonceRecord)

    Repo.update_all(from(n in NonceRecord, where: n.id == ^record.id),
      set: [expiration_time: DateTime.add(DateTime.utc_now(), -1)]
    )

    assert json_post("/api/shared/siwa/wallet/verify", proof(nonce)) |> json_response(401)
    assert {:error, :unknown_nonce} = NonceStore.consume_wallet(record)
  end

  test "origin changes invalidate an outstanding challenge" do
    nonce = issue()
    config = Application.get_env(:siwa_server, :siwa)

    Application.put_env(
      :siwa_server,
      :siwa,
      Keyword.put(config, :wallet_origins, %{"patchbay" => "https://new.patchbay.help"})
    )

    assert json_post("/api/shared/siwa/wallet/verify", proof(nonce)) |> json_response(401)
  end

  test "HTTP verifier exposes only authenticated wallet principal and consumes durable replay once" do
    {:ok, signer} = Siwa.LocalSigner.new()
    {:ok, nonce} = Wallet.issue_nonce(%{params() | "wallet_address" => signer.address})
    {:ok, signature} = Siwa.LocalSigner.sign_message(signer, nonce["data"]["message"])

    {:ok, verified} =
      Wallet.verify(
        Map.merge(%{params() | "wallet_address" => signer.address}, %{
          "nonce" => nonce["data"]["nonce"],
          "message" => nonce["data"]["message"],
          "signature" => signature
        })
      )

    {:ok, signed} =
      Siwa.sign_authenticated_request(
        %{method: "POST", path: "/api/agent/payment-intents?mode=create", body: "{}"},
        verified["data"]["receipt"],
        signer,
        secret: secret(),
        audience: "patchbay",
        wallet_audiences: ["patchbay"]
      )

    request = %{
      "method" => signed.method,
      "path" => signed.path,
      "headers" => signed.headers,
      "body" => signed.body
    }

    assert http_verify(%{request | "body" => "{ }"}, "patchbay") |> json_response(401)
    assert http_verify(request, "techtree") |> json_response(401)
    response = http_verify(request, "patchbay") |> json_response(200)

    assert response["data"]["principal"] == %{
             "kind" => "wallet",
             "wallet_address" => signer.address,
             "chain_id" => 8453,
             "audience" => "patchbay"
           }

    refute Map.has_key?(response["data"], "agent_claims")
    refute "x-agent-token-id" in response["data"]["requiredHeaders"]
    assert http_verify(request, "patchbay") |> json_response(409)
  end

  test "nonce database keeps agent and wallet shapes disjoint" do
    nonce = issue()
    record = Repo.one!(NonceRecord)
    assert record.principal_kind == "wallet"
    assert is_nil(record.agent_id)
    assert is_nil(record.agent_registry)

    assert {:error, %Ecto.Changeset{}} =
             record |> NonceRecord.changeset(%{agent_id: "1"}) |> Repo.update(mode: :savepoint)

    assert {:error, :unknown_nonce} = NonceStore.consume(record.nonce_key, nonce["nonce"])
    assert json_post("/api/shared/siwa/wallet/verify", proof(nonce)) |> json_response(200)
  end

  test "durable replay store refuses already expired entries even after cleanup" do
    key = "wallet-expiry-test:#{Ecto.UUID.generate()}"
    expired = System.system_time(:second) - 1
    assert {:error, :replayed_request} = ReplayStore.consume(key, expired)
    assert {:ok, _} = ReplayStore.cleanup_expired()
    assert {:error, :replayed_request} = ReplayStore.consume(key, expired)
  end

  defp params,
    do: %{"wallet_address" => TestWallet.address(), "chain_id" => 8453, "audience" => "patchbay"}

  defp secret, do: Application.fetch_env!(:siwa_server, :siwa)[:receipt_secret]

  defp issue,
    do:
      json_post("/api/shared/siwa/wallet/nonce", params())
      |> json_response(200)
      |> Map.fetch!("data")

  defp proof(nonce),
    do:
      Map.merge(params(), %{
        "nonce" => nonce["nonce"],
        "message" => nonce["message"],
        "signature" => TestWallet.sign_message(nonce["message"])
      })

  defp json_post(path, params),
    do:
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post(path, Jason.encode!(params))

  defp http_verify(params, audience),
    do:
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-siwa-audience", audience)
      |> post("/api/shared/siwa/http-verify", Jason.encode!(params))
end
