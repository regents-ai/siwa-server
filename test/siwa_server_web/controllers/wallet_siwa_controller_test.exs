defmodule SiwaServerWeb.WalletSiwaControllerTest do
  use SiwaServerWeb.ConnCase, async: false
  use Oban.Testing, repo: SiwaServer.Repo

  alias SiwaServer.{AgentBook, Repo, TestRpcServer, TestWallet}
  alias SiwaServer.Siwa.{ActivityStore, NonceRecord, NonceStore, ReplayStore, Wallet}
  import Ecto.Query

  setup do
    previous = Application.get_env(:siwa_server, :siwa)

    Application.put_env(
      :siwa_server,
      :siwa,
      Keyword.put(previous, :wallet_origins, %{"patchbay" => "https://patchbay.help"})
    )

    previous_rpc_urls = Map.new(~w(BASE_RPC_URL ETHEREUM_RPC_URL), &{&1, System.get_env(&1)})
    System.put_env("BASE_RPC_URL", TestRpcServer.wallet_answers({true, <<>>}))
    System.put_env("ETHEREUM_RPC_URL", TestRpcServer.wallet_answers({true, <<>>}))

    on_exit(fn ->
      Application.put_env(:siwa_server, :siwa, previous)

      for {name, value} <- previous_rpc_urls do
        if value, do: System.put_env(name, value), else: System.delete_env(name)
      end
    end)
  end

  test "lists the audiences open to wallet sign-in with their origins", %{conn: conn} do
    assert %{
             "code" => "audiences",
             "data" => %{
               "audiences" => [%{"audience" => "patchbay", "origin" => "https://patchbay.help"}]
             }
           } = json_response(get(conn, "/api/shared/siwa/audiences"), 200)
  end

  test "canonical ordinary-wallet challenge yields a wallet proof" do
    nonce = issue()
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
    assert data["verificationMethod"] == "eoa_recovery"
    assert data["walletAddress"] == TestWallet.address()
    {:ok, claims} = Siwa.verify_receipt(data["receipt"], secret: secret(), audience: "patchbay")
    assert claims["typ"] == "siwa_wallet_receipt"
    assert claims["verified"] == "wallet_signature"

    assert_enqueued(
      worker: AgentBook.Refresh,
      args: %{wallet_address: String.downcase(TestWallet.address())}
    )

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

  test "a closed site's refusal names the sites that accept agents" do
    hint =
      json_post("/api/shared/siwa/wallet/nonce", %{params() | "audience" => "techtree"})
      |> json_response(403)
      |> get_in(["error", "hint"])

    assert hint =~ "techtree does not accept agent sign-in"
    assert hint =~ "The sites that do: https://patchbay.help."
  end

  test "a wrong signature's hint speaks to how the agent signs" do
    nonce = issue()
    bad = Map.put(proof(nonce), "signature", TestWallet.sign_message("different proof"))

    for {signer, advice} <- [
          {"own-key", "uv run siwa_agent.py whoami"},
          {"Cast", "cast wallet sign --account <name>"},
          {"frost-sign", "Your signer command (frost-sign)"},
          {"frost-sign", "--chain ethereum --force"},
          {"rm -rf /", "(EIP-191)"},
          {nil, "(EIP-191)"}
        ] do
      conn = build_conn() |> put_req_header("content-type", "application/json")
      conn = if signer, do: put_req_header(conn, "x-agent-signer", signer), else: conn

      assert %{"code" => "signature_invalid", "hint" => hint} =
               conn
               |> post("/api/shared/siwa/wallet/verify", Jason.encode!(bad))
               |> json_response(401)
               |> Map.fetch!("error")

      assert hint =~ advice
    end
  end

  test "contract rejects unknown, missing and mistyped fields" do
    for bad <- [
          Map.put(params(), "private_key", "not-a-key"),
          Map.delete(params(), "wallet_address"),
          %{params() | "chain_id" => "8453"},
          %{params() | "chain_id" => 10},
          %{params() | "chain_id" => 0},
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
          Map.put(proof(nonce), "signature", "0x123"),
          Map.put(proof(nonce), "signature", "0x" <> String.duplicate("ab", 4097))
        ] do
      assert json_post("/api/shared/siwa/wallet/verify", bad) |> json_response(400)
    end
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

  test "a smart wallet signs in once Base approves its signature" do
    smart_wallet = "0x452f678f6e588069d1aef38d3d519567aa1014a4"

    System.put_env(
      "BASE_RPC_URL",
      TestRpcServer.wallet_answers({true, TestRpcServer.erc1271_approval()})
    )

    smart_params = %{params() | "wallet_address" => smart_wallet}

    nonce =
      json_post("/api/shared/siwa/wallet/nonce", smart_params)
      |> json_response(200)
      |> Map.fetch!("data")

    proof =
      Map.merge(smart_params, %{
        "nonce" => nonce["nonce"],
        "message" => nonce["message"],
        "signature" => "0x" <> String.duplicate("ab", 640)
      })

    data =
      json_post("/api/shared/siwa/wallet/verify", proof)
      |> json_response(200)
      |> Map.fetch!("data")

    assert data["walletAddress"] == smart_wallet
    assert data["verificationMethod"] == "erc1271"
  end

  test "a smart wallet that signs in on Ethereum is asked on Ethereum, not Base" do
    smart_wallet = "0x452f678f6e588069d1aef38d3d519567aa1014a4"
    System.put_env("BASE_RPC_URL", TestRpcServer.rpc_error())

    System.put_env(
      "ETHEREUM_RPC_URL",
      TestRpcServer.wallet_answers({true, TestRpcServer.erc1271_approval()})
    )

    ethereum_params = %{params() | "wallet_address" => smart_wallet, "chain_id" => 1}

    nonce =
      json_post("/api/shared/siwa/wallet/nonce", ethereum_params)
      |> json_response(200)
      |> Map.fetch!("data")

    assert nonce["message"] =~ "\nChain ID: 1\n"

    proof =
      Map.merge(ethereum_params, %{
        "nonce" => nonce["nonce"],
        "message" => nonce["message"],
        "signature" => "0x" <> String.duplicate("ab", 640)
      })

    System.delete_env("ETHEREUM_RPC_URL")

    assert %{"message" => "could not check the wallet signature on Ethereum: " <> _reason} =
             json_post("/api/shared/siwa/wallet/verify", proof)
             |> json_response(502)
             |> Map.fetch!("error")

    System.put_env(
      "ETHEREUM_RPC_URL",
      TestRpcServer.wallet_answers({true, TestRpcServer.erc1271_approval()})
    )

    data =
      json_post("/api/shared/siwa/wallet/verify", proof)
      |> json_response(200)
      |> Map.fetch!("data")

    assert data["chainId"] == 1
    assert data["verificationMethod"] == "erc1271"
  end

  test "a failed signature lookup on Base is a 502 and leaves the challenge usable" do
    nonce = issue()
    System.put_env("BASE_RPC_URL", TestRpcServer.rpc_error())
    smart_signature = Map.put(proof(nonce), "signature", "0x" <> String.duplicate("ab", 224))

    assert %{"error" => %{"code" => "signature_lookup_failed"}} =
             json_post("/api/shared/siwa/wallet/verify", smart_signature) |> json_response(502)

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
    assert {:error, :unknown_nonce} = NonceStore.consume(record)
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

    assert %{"hint" => hint} =
             http_verify(request, "techtree") |> json_response(401) |> Map.fetch!("error")

    assert hint =~ "Your sign-in for techtree has ended or was made for another site."
    human_id = "0x" <> String.duplicate("ab", 32)

    Repo.insert!(AgentBook.Human.changeset(%{wallet_address: signer.address, human_id: human_id}))

    Repo.insert!(
      AgentBook.Acceptance.changeset(%{wallet_address: signer.address, human_id: human_id})
    )

    response = http_verify(request, "patchbay") |> json_response(200)
    assert response["data"]["verificationMethod"] == "eoa_recovery"

    assert response["data"]["principal"] == %{
             "kind" => "wallet",
             "wallet_address" => signer.address,
             "chain_id" => 8453,
             "audience" => "patchbay"
           }

    assert response["data"]["agentRegistration"] == nil
    assert response["data"]["agentBook"] == %{"humanId" => human_id, "agentCount" => 1}
    assert http_verify(request, "patchbay") |> json_response(409)

    assert [
             %{
               audience: "patchbay",
               method: "POST",
               path: "/api/agent/payment-intents",
               occurred_at: %DateTime{}
             }
           ] = activity(signer.address)
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

  defp activity(wallet_address) do
    {:ok, entries, nil} =
      ActivityStore.page(wallet_address, DateTime.add(DateTime.utc_now(), -60), nil)

    entries
  end
end
