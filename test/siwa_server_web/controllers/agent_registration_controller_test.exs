defmodule SiwaServerWeb.AgentRegistrationControllerTest do
  use SiwaServerWeb.ConnCase, async: false

  alias RegentChain.Call
  alias SiwaServer.{AgentRegistration, Repo, TestRpcServer, TestWallet}
  alias SiwaServer.AgentRegistration.Link
  alias SiwaServer.Siwa.Challenge

  @registry "0x8004a169fb4a3325136eb29fa0ceb6d2e539a432"
  @other_wallet "0x1111111111111111111111111111111111111111"
  @zero_address "0x" <> String.duplicate("0", 40)
  @tx_hash "0x" <> String.duplicate("ab", 32)
  @transfer_topic "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
  # The selector the live Base registry answers to for register(string) (checked with eth_call).
  @register_with_uri "0xf2c298be"

  setup do
    previous_base_rpc_url = System.get_env("BASE_RPC_URL")

    on_exit(fn ->
      case previous_base_rpc_url do
        nil -> System.delete_env("BASE_RPC_URL")
        value -> System.put_env("BASE_RPC_URL", value)
      end
    end)

    wallet = String.downcase(TestWallet.address())

    %{
      wallet: wallet,
      profile: %{
        wallet_address: wallet,
        name: "Astra",
        description: "Finds bugs in Elixir code.",
        image: "https://astra.example/face.png"
      }
    }
  end

  describe "register-step" do
    test "builds register(agentUri) for the wallet to send on Base, naming its profile", %{
      conn: conn,
      wallet: wallet,
      profile: profile
    } do
      assert %{"code" => "registration_step", "data" => step} =
               conn |> register_step(profile) |> json_response(200)

      assert %{"chainId" => 8453, "from" => ^wallet, "to" => @registry, "value" => "0x0"} = step
      assert step["agentUri"] =~ ~r|/agent-profiles/[0-9a-f]{32}\z|
      assert step["data"] == RegentChain.BuilderCode.append(register_calldata(step["agentUri"]))

      assert %{"data" => %{"agentUri" => same}} =
               conn |> register_step(profile) |> json_response(200)

      assert %{"data" => %{"agentUri" => changed}} =
               conn |> register_step(%{profile | description: "Other"}) |> json_response(200)

      assert same == step["agentUri"]
      refute changed == step["agentUri"]
    end

    test "refuses a request that is not the contract's shape", %{conn: conn, profile: profile} do
      for body <- [
            %{profile | wallet_address: "not-an-address"},
            Map.delete(profile, :name),
            %{profile | description: " "},
            %{profile | name: "\u00A0"},
            %{profile | description: "\u2003"},
            %{profile | image: "http://astra.example/face.png"},
            %{profile | name: String.duplicate("a", 101)},
            Map.put(profile, :agent_uri, "https://agent.example/agent.json")
          ] do
        assert %{"error" => %{"code" => "invalid_request"}} =
                 conn |> register_step(body) |> json_response(400)
      end
    end
  end

  describe "registered" do
    test "is pending while Base has not seen the transaction", %{conn: conn, profile: profile} do
      use_chain(nil, nil)

      assert json_response(registered(conn, profile), 200) == %{
               "code" => "registration_pending",
               "data" => %{"txHash" => @tx_hash}
             }
    end

    test "is pending until the receipt exists", %{conn: conn, wallet: wallet, profile: profile} do
      use_chain(transaction(wallet, calldata(profile)), nil)

      assert %{"code" => "registration_pending"} = json_response(registered(conn, profile), 200)
      assert AgentRegistration.latest(wallet) == nil
    end

    test "keeps the listing once it lands, serves its profile and names it for the wallet", %{
      conn: conn,
      wallet: wallet,
      profile: profile
    } do
      use_chain(transaction(wallet, calldata(profile)), receipt("0x1", mint_log(wallet, 96_166)))
      profile_url = agent_uri(profile)

      registration = %{
        "agentId" => "eip155:8453:#{@registry}:96166",
        "tokenId" => "96166",
        "profileUrl" => profile_url,
        "registryUrl" => "https://www.8004scan.io/agents/base/96166"
      }

      answer = %{
        "code" => "agent_registered",
        "data" =>
          Map.merge(registration, %{
            "txHash" => @tx_hash,
            "walletAddress" => wallet,
            "chainId" => 8453,
            "registryAddress" => @registry
          })
      }

      assert json_response(registered(conn, profile), 200) == answer
      assert json_response(registered(conn, profile), 200) == answer
      assert Repo.aggregate(AgentRegistration, :count) == 1
      assert AgentRegistration.latest(wallet) == registration

      profile_conn = get(conn, URI.parse(profile_url).path)
      assert get_resp_header(profile_conn, "access-control-allow-origin") == ["*"]

      assert json_response(profile_conn, 200) == %{
               "type" => "https://eips.ethereum.org/EIPS/eip-8004#registration-v1",
               "name" => "Astra",
               "description" => "Finds bugs in Elixir code.",
               "image" => "https://astra.example/face.png",
               "services" => [],
               "x402Support" => false,
               "active" => true,
               "registrations" => [
                 %{"agentId" => 96_166, "agentRegistry" => "eip155:8453:#{@registry}"}
               ]
             }
    end

    test "says when the registration reverted", %{conn: conn, wallet: wallet, profile: profile} do
      use_chain(transaction(wallet, calldata(profile)), receipt("0x0", nil))

      assert %{"error" => %{"code" => "registration_reverted"}} =
               json_response(registered(conn, profile), 422)
    end

    test "refuses a transaction that is not this wallet's registration of this profile", %{
      conn: conn,
      wallet: wallet,
      profile: profile
    } do
      for tx <- [
            transaction(@other_wallet, calldata(profile)),
            transaction(wallet, calldata(%{profile | name: "Someone else"})),
            Map.put(transaction(wallet, calldata(profile)), "to", @other_wallet)
          ] do
        use_chain(tx, receipt("0x1", mint_log(wallet, 1)))

        assert %{"error" => %{"code" => "transaction_not_registration"}} =
                 json_response(registered(conn, profile), 422)
      end

      assert Repo.aggregate(AgentRegistration, :count) == 0
    end

    test "says when Base cannot be read", %{conn: conn, profile: profile} do
      System.put_env("BASE_RPC_URL", TestRpcServer.rpc_error())

      assert %{"error" => %{"code" => "agent_registration_lookup_failed"}} =
               json_response(registered(conn, profile), 502)
    end

    test "refuses a malformed transaction hash", %{conn: conn, profile: profile} do
      conn =
        json_post(conn, "/api/shared/siwa/agent/registered", Map.put(profile, :tx_hash, "0x1234"))

      assert %{"error" => %{"code" => "invalid_request"}} = json_response(conn, 400)
    end
  end

  describe "link" do
    test "links a listing whose agent wallet is this wallet, once the wallet signs", %{
      conn: conn,
      wallet: wallet
    } do
      use_registry(wallet, @other_wallet, "ipfs://bafyagent/agent.json")
      "0x" <> hex = wallet

      assert %{"code" => "agent_link_challenge", "data" => challenge} =
               conn |> link_challenge("0x" <> String.upcase(hex), "1") |> json_response(200)

      assert %{"walletAddress" => ^wallet, "chainId" => 8453, "tokenId" => "1"} = challenge

      assert challenge["message"] =~
               "Wallet: #{wallet}\nAgent: 1\nRegistry: eip155:8453:#{@registry}\n"

      registration = %{
        "agentId" => "eip155:8453:#{@registry}:1",
        "tokenId" => "1",
        "profileUrl" => "ipfs://bafyagent/agent.json",
        "registryUrl" => "https://www.8004scan.io/agents/base/1"
      }

      assert json_response(link(conn, challenge), 200) == %{
               "code" => "agent_linked",
               "data" =>
                 Map.merge(registration, %{
                   "walletAddress" => wallet,
                   "chainId" => 8453,
                   "registryAddress" => @registry
                 })
             }

      assert Repo.aggregate(Link, :count) == 1
      assert AgentRegistration.latest("0x" <> String.upcase(hex)) == registration

      assert %{"error" => %{"code" => "nonce_not_found"}} =
               json_response(link(conn, challenge), 404)
    end

    test "links a listing whose owner is this wallet and that names no agent wallet", %{
      conn: conn,
      wallet: wallet
    } do
      use_registry(@zero_address, wallet, "https://agent.example/agent.json")
      challenge = conn |> link_challenge(wallet, "7") |> json_response(200) |> Map.fetch!("data")

      assert %{"code" => "agent_linked", "data" => %{"tokenId" => "7"}} =
               json_response(link(conn, challenge), 200)

      assert %{"tokenId" => "7", "profileUrl" => "https://agent.example/agent.json"} =
               AgentRegistration.latest(wallet)
    end

    test "refuses a listing the registry names another wallet's, and an agent that does not exist",
         %{conn: conn, wallet: wallet} do
      for {agent_wallet, owner} <- [
            {@other_wallet, @other_wallet},
            {@zero_address, @other_wallet},
            {@zero_address, :reverts}
          ] do
        use_registry(agent_wallet, owner, "https://agent.example/agent.json")

        assert %{"error" => %{"code" => "listing_not_this_wallet", "hint" => hint}} =
                 conn |> link_challenge(wallet, "7") |> json_response(422)

        assert hint =~ "link-agent"
      end

      assert AgentRegistration.latest(wallet) == nil
    end

    test "refuses to link once the registry no longer names the wallet", %{
      conn: conn,
      wallet: wallet
    } do
      use_registry(@zero_address, wallet, "https://agent.example/agent.json")
      challenge = conn |> link_challenge(wallet, "7") |> json_response(200) |> Map.fetch!("data")

      use_registry(@zero_address, @other_wallet, "https://agent.example/agent.json")

      assert %{"error" => %{"code" => "listing_not_this_wallet"}} =
               json_response(link(conn, challenge), 422)

      assert AgentRegistration.latest(wallet) == nil
    end

    test "refuses a signature, message or agent other than the challenge's", %{
      conn: conn,
      wallet: wallet
    } do
      use_registry(wallet, wallet, "https://agent.example/agent.json")
      challenge = conn |> link_challenge(wallet, "7") |> json_response(200) |> Map.fetch!("data")
      # A signature that is not the wallet key's asks Base whether a smart wallet approves it.
      System.put_env("BASE_RPC_URL", TestRpcServer.wallet_answers({true, <<>>}))

      for {change, status, code} <- [
            {%{"signature" => TestWallet.sign_message("something else")}, 401,
             "signature_invalid"},
            {%{"message" => challenge["message"] <> " "}, 401, "message_invalid"},
            {%{"tokenId" => "8"}, 401, "message_invalid"},
            {%{"nonce" => String.duplicate("0", 32)}, 404, "nonce_not_found"}
          ] do
        assert %{"error" => %{"code" => ^code}} =
                 conn |> link(Map.merge(challenge, change)) |> json_response(status)
      end

      Repo.update_all(Challenge, set: [expiration_time: ~U[2026-01-01 00:00:00Z]])

      assert %{"error" => %{"code" => "nonce_expired"}} =
               json_response(link(conn, challenge), 401)

      assert AgentRegistration.latest(wallet) == nil
    end

    test "the listing registered or linked last is the one named", %{
      conn: conn,
      wallet: wallet,
      profile: profile
    } do
      link_agent = fn token_id ->
        use_registry(wallet, wallet, "https://agent.example/agent.json")

        challenge =
          conn |> link_challenge(wallet, token_id) |> json_response(200) |> Map.fetch!("data")

        assert %{"code" => "agent_linked"} = json_response(link(conn, challenge), 200)
      end

      link_agent.("7")
      assert %{"tokenId" => "7"} = AgentRegistration.latest(wallet)

      use_chain(transaction(wallet, calldata(profile)), receipt("0x1", mint_log(wallet, 96_166)))
      assert %{"code" => "agent_registered"} = json_response(registered(conn, profile), 200)

      assert %{"tokenId" => "96166", "profileUrl" => profile_url} =
               AgentRegistration.latest(wallet)

      assert profile_url == agent_uri(profile)

      link_agent.("7")

      # Asking again about the registration, as anyone can, leaves the later link.
      use_chain(transaction(wallet, calldata(profile)), receipt("0x1", mint_log(wallet, 96_166)))
      assert %{"code" => "agent_registered"} = json_response(registered(conn, profile), 200)
      assert %{"tokenId" => "7"} = AgentRegistration.latest(wallet)
      assert Repo.aggregate(Link, :count) == 1
    end

    test "links a listing whose profile is no web or ipfs address, with no profile", %{
      conn: conn,
      wallet: wallet
    } do
      for token_uri <- [
            "",
            "data:application/json;base64,e30=",
            "http://agent.example/agent.json",
            "https://agent.example/" <> String.duplicate("a", 2_000),
            "https://agent.example/a b",
            <<0xFF, 0xFE>>
          ] do
        use_registry(wallet, wallet, token_uri)

        challenge =
          conn |> link_challenge(wallet, "7") |> json_response(200) |> Map.fetch!("data")

        assert %{"code" => "agent_linked", "data" => %{"tokenId" => "7", "profileUrl" => nil}} =
                 json_response(link(conn, challenge), 200)

        assert %{"tokenId" => "7", "profileUrl" => nil} = AgentRegistration.latest(wallet)
      end
    end

    test "says when Base cannot be read", %{conn: conn, wallet: wallet} do
      System.put_env("BASE_RPC_URL", TestRpcServer.rpc_error())

      assert %{"error" => %{"code" => "agent_registration_lookup_failed"}} =
               conn |> link_challenge(wallet, "7") |> json_response(502)
    end

    test "refuses a request that is not the contract's shape", %{conn: conn, wallet: wallet} do
      base = %{wallet_address: wallet, chain_id: 8453, token_id: "7"}

      for body <- [
            %{base | token_id: "07"},
            %{base | token_id: "-1"},
            %{base | token_id: "1" <> String.duplicate("0", 77)},
            %{base | token_id: 7},
            %{base | wallet_address: "not-an-address"},
            %{base | chain_id: "8453"},
            %{base | chain_id: 10},
            Map.delete(base, :token_id),
            Map.put(base, :profile_url, "https://agent.example")
          ] do
        assert %{"error" => %{"code" => "invalid_request"}} =
                 conn
                 |> json_post("/api/shared/siwa/agent/link-challenge", body)
                 |> json_response(400)
      end

      proof =
        Map.merge(base, %{
          nonce: String.duplicate("a", 32),
          message: "Link",
          signature: "0x" <> String.duplicate("ab", 65)
        })

      for body <- [
            %{proof | nonce: "A" <> String.duplicate("a", 31)},
            %{proof | message: ""},
            %{proof | message: String.duplicate("a", 2_049)},
            %{proof | signature: "0xabc"},
            %{proof | token_id: "07"},
            Map.delete(proof, :signature)
          ] do
        assert %{"error" => %{"code" => "invalid_request"}} =
                 conn |> json_post("/api/shared/siwa/agent/link", body) |> json_response(400)
      end

      assert %{"error" => %{"code" => "nonce_not_found"}} =
               conn |> json_post("/api/shared/siwa/agent/link", proof) |> json_response(404)
    end
  end

  test "a profile no registration has landed for is not served", %{conn: conn} do
    assert %{"error" => %{"code" => "agent_profile_not_found"}} =
             conn |> get("/agent-profiles/#{String.duplicate("0", 32)}") |> json_response(404)
  end

  defp register_step(conn, profile),
    do: json_post(conn, "/api/shared/siwa/agent/register-step", profile)

  defp registered(conn, profile),
    do: json_post(conn, "/api/shared/siwa/agent/registered", Map.put(profile, :tx_hash, @tx_hash))

  defp link_challenge(conn, wallet, token_id),
    do:
      json_post(conn, "/api/shared/siwa/agent/link-challenge", %{
        wallet_address: wallet,
        chain_id: 8453,
        token_id: token_id
      })

  defp link(conn, challenge),
    do:
      json_post(conn, "/api/shared/siwa/agent/link", %{
        wallet_address: challenge["walletAddress"],
        chain_id: challenge["chainId"],
        token_id: challenge["tokenId"],
        nonce: challenge["nonce"],
        message: challenge["message"],
        signature: Map.get(challenge, "signature", TestWallet.sign_message(challenge["message"]))
      })

  defp agent_uri(profile) do
    {:ok, %{"data" => %{"agentUri" => uri}}} =
      profile
      |> Map.new(fn {key, value} -> {to_string(key), value} end)
      |> AgentRegistration.step()

    uri
  end

  defp calldata(profile), do: profile |> agent_uri() |> register_calldata()

  defp use_chain(transaction, receipt) do
    url =
      TestRpcServer.start(fn request ->
        [_headers, body] = String.split(request, "\r\n\r\n", parts: 2)

        result =
          case Jason.decode!(body) do
            %{"method" => "eth_getTransactionByHash", "params" => [@tx_hash]} -> transaction
            %{"method" => "eth_getTransactionReceipt", "params" => [@tx_hash]} -> receipt
          end

        %{"id" => 1, "jsonrpc" => "2.0", "result" => result}
      end)

    System.put_env("BASE_RPC_URL", url)
  end

  # The registry answers getAgentWallet, ownerOf (or reverts, as it does for an
  # agent that does not exist) and tokenURI for any agent.
  defp use_registry(agent_wallet, owner, token_uri) do
    get_agent_wallet = Call.selector("getAgentWallet(uint256)")
    owner_of = Call.selector("ownerOf(uint256)")
    token_uri_of = Call.selector("tokenURI(uint256)")

    url =
      TestRpcServer.start(fn request ->
        [_headers, body] = String.split(request, "\r\n\r\n", parts: 2)

        %{"method" => "eth_call", "params" => [%{"to" => @registry, "data" => data}, "latest"]} =
          Jason.decode!(body)

        case {String.slice(data, 0, 10), owner} do
          {^get_agent_wallet, _owner} ->
            %{"id" => 1, "jsonrpc" => "2.0", "result" => topic(agent_wallet)}

          {^owner_of, :reverts} ->
            %{
              "id" => 1,
              "jsonrpc" => "2.0",
              "error" => %{"code" => 3, "message" => "execution reverted"}
            }

          {^owner_of, owner} ->
            %{"id" => 1, "jsonrpc" => "2.0", "result" => topic(owner)}

          {^token_uri_of, _owner} ->
            %{"id" => 1, "jsonrpc" => "2.0", "result" => abi_string(token_uri)}
        end
      end)

    System.put_env("BASE_RPC_URL", url)
  end

  defp abi_string(value) do
    padded = value <> :binary.copy(<<0>>, rem(32 - rem(byte_size(value), 32), 32))
    "0x" <> Base.encode16(<<32::256, byte_size(value)::256>> <> padded, case: :lower)
  end

  defp transaction(from, input) do
    %{
      "hash" => @tx_hash,
      "chainId" => "0x2105",
      "from" => from,
      "to" => @registry,
      "input" => input,
      "value" => "0x0"
    }
  end

  defp receipt(status, log) do
    %{"transactionHash" => @tx_hash, "status" => status, "logs" => List.wrap(log)}
  end

  defp mint_log(wallet, token_id) do
    %{
      "address" => @registry,
      "topics" => [@transfer_topic, topic(0), topic(wallet), topic(token_id)]
    }
  end

  defp topic("0x" <> address), do: "0x" <> String.pad_leading(address, 64, "0")

  defp topic(integer),
    do: "0x" <> String.pad_leading(Integer.to_string(integer, 16), 64, "0")

  # register(string): selector, the string's offset, its length, then its bytes
  # padded to 32.
  defp register_calldata(uri) do
    padded = uri <> :binary.copy(<<0>>, rem(32 - rem(byte_size(uri), 32), 32))

    @register_with_uri <>
      String.downcase(Base.encode16(<<32::256, byte_size(uri)::256>>) <> Base.encode16(padded))
  end

  defp json_post(conn, path, params) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(params))
  end
end
