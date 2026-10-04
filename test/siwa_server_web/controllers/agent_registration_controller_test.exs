defmodule SiwaServerWeb.AgentRegistrationControllerTest do
  use SiwaServerWeb.ConnCase, async: false

  alias SiwaServer.{AgentRegistration, Repo, TestRpcServer, TestWallet}
  alias SiwaServer.AgentRegistration.Record

  @registry "0x8004a169fb4a3325136eb29fa0ceb6d2e539a432"
  @other_wallet "0x1111111111111111111111111111111111111111"
  @tx_hash "0x" <> String.duplicate("ab", 32)
  @transfer_topic "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
  # The selector the live Base registry answers to for register(string) (checked with eth_call).
  @register_with_uri "0xf2c298be"

  setup do
    previous_base_rpc_url = System.get_env("BASE_RPC_URL")
    SiwaServer.RateLimiter.reset()

    on_exit(fn ->
      case previous_base_rpc_url do
        nil -> System.delete_env("BASE_RPC_URL")
        value -> System.put_env("BASE_RPC_URL", value)
      end

      SiwaServer.RateLimiter.reset()
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
      assert step["data"] == register_calldata(step["agentUri"])

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
      assert Repo.aggregate(Record, :count) == 1
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

      assert Repo.aggregate(Record, :count) == 0
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

  test "a profile no registration has landed for is not served", %{conn: conn} do
    assert %{"error" => %{"code" => "agent_profile_not_found"}} =
             conn |> get("/agent-profiles/#{String.duplicate("0", 32)}") |> json_response(404)
  end

  defp register_step(conn, profile),
    do: json_post(conn, "/api/shared/siwa/agent/register-step", profile)

  defp registered(conn, profile),
    do: json_post(conn, "/api/shared/siwa/agent/registered", Map.put(profile, :tx_hash, @tx_hash))

  defp agent_uri(profile) do
    {:ok, %{"data" => %{"agentUri" => uri}}} = AgentRegistration.step(profile)
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
