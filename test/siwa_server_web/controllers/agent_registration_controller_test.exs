defmodule SiwaServerWeb.AgentRegistrationControllerTest do
  use SiwaServerWeb.ConnCase, async: false

  alias SiwaServer.{TestRpcServer, TestWallet}

  @registry "0x8004a169fb4a3325136eb29fa0ceb6d2e539a432"
  @other_wallet "0x1111111111111111111111111111111111111111"
  @tx_hash "0x" <> String.duplicate("ab", 32)
  @transfer_topic "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
  @agent_uri "https://agent.example/agent.json"
  # The selectors the live Base registry answers to (checked with eth_call).
  @register "0x1aa3a008"
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

    %{wallet: String.downcase(TestWallet.address())}
  end

  describe "register-step" do
    test "builds register() for the wallet to send on Base", %{conn: conn, wallet: wallet} do
      conn = json_post(conn, "/api/shared/siwa/agent/register-step", %{wallet_address: wallet})

      assert json_response(conn, 200) == %{
               "code" => "registration_step",
               "data" => %{
                 "chainId" => 8453,
                 "from" => wallet,
                 "to" => @registry,
                 "data" => @register,
                 "value" => "0x0"
               }
             }
    end

    test "builds register(string) when the agent names its URI", %{conn: conn, wallet: wallet} do
      conn =
        json_post(conn, "/api/shared/siwa/agent/register-step", %{
          wallet_address: wallet,
          agent_uri: @agent_uri
        })

      assert %{"code" => "registration_step", "data" => %{"data" => data}} =
               json_response(conn, 200)

      assert data == register_with_uri_calldata(@agent_uri)
    end

    test "refuses a request that is not the contract's shape", %{conn: conn, wallet: wallet} do
      for body <- [
            %{wallet_address: "not-an-address"},
            %{},
            %{wallet_address: wallet, agent_uri: " "},
            %{wallet_address: wallet, registry_address: @registry}
          ] do
        conn = json_post(conn, "/api/shared/siwa/agent/register-step", body)

        assert %{"error" => %{"code" => "invalid_request"}} = json_response(conn, 400)
      end
    end
  end

  describe "registered" do
    test "is pending while Base has not seen the transaction", %{conn: conn, wallet: wallet} do
      use_chain(nil, nil)

      assert json_response(registered(conn, wallet), 200) == %{
               "code" => "registration_pending",
               "data" => %{"txHash" => @tx_hash}
             }
    end

    test "is pending until the receipt exists", %{conn: conn, wallet: wallet} do
      use_chain(transaction(wallet, @register), nil)

      assert %{"code" => "registration_pending"} = json_response(registered(conn, wallet), 200)
    end

    test "returns the token the registry minted to the wallet", %{conn: conn, wallet: wallet} do
      use_chain(transaction(wallet, @register), receipt("0x1", mint_log(wallet, 96_166)))

      assert json_response(registered(conn, wallet), 200) == %{
               "code" => "agent_registered",
               "data" => %{
                 "txHash" => @tx_hash,
                 "walletAddress" => wallet,
                 "chainId" => 8453,
                 "registryAddress" => @registry,
                 "tokenId" => "96166",
                 "agentId" => "eip155:8453:#{@registry}:96166"
               }
             }
    end

    test "reads a registration that named its URI", %{conn: conn, wallet: wallet} do
      calldata = register_with_uri_calldata(@agent_uri)
      use_chain(transaction(wallet, calldata), receipt("0x1", mint_log(wallet, 7)))

      assert %{"code" => "agent_registered", "data" => %{"tokenId" => "7"}} =
               json_response(registered(conn, wallet, @agent_uri), 200)
    end

    test "says when the registration reverted", %{conn: conn, wallet: wallet} do
      use_chain(transaction(wallet, @register), receipt("0x0", nil))

      assert %{"error" => %{"code" => "registration_reverted"}} =
               json_response(registered(conn, wallet), 422)
    end

    test "refuses a transaction that is not this wallet's registration", %{
      conn: conn,
      wallet: wallet
    } do
      for tx <- [
            transaction(@other_wallet, @register),
            transaction(wallet, register_with_uri_calldata(@agent_uri)),
            Map.put(transaction(wallet, @register), "to", @other_wallet)
          ] do
        use_chain(tx, receipt("0x1", mint_log(wallet, 1)))

        assert %{"error" => %{"code" => "transaction_not_registration"}} =
                 json_response(registered(conn, wallet), 422)
      end
    end

    test "says when Base cannot be read", %{conn: conn, wallet: wallet} do
      System.put_env("BASE_RPC_URL", TestRpcServer.rpc_error())

      assert %{"error" => %{"code" => "agent_registration_lookup_failed"}} =
               json_response(registered(conn, wallet), 502)
    end

    test "refuses a malformed transaction hash", %{conn: conn, wallet: wallet} do
      conn =
        json_post(conn, "/api/shared/siwa/agent/registered", %{
          wallet_address: wallet,
          tx_hash: "0x1234"
        })

      assert %{"error" => %{"code" => "invalid_request"}} = json_response(conn, 400)
    end
  end

  defp registered(conn, wallet, agent_uri \\ nil) do
    body =
      %{wallet_address: wallet, tx_hash: @tx_hash}
      |> then(&if agent_uri, do: Map.put(&1, :agent_uri, agent_uri), else: &1)

    json_post(conn, "/api/shared/siwa/agent/registered", body)
  end

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
  defp register_with_uri_calldata(uri) do
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
