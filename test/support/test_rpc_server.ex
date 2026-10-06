defmodule SiwaServer.TestRpcServer do
  @moduledoc false

  def chain_id(chain_id) do
    start(fn _request -> %{"id" => 1, "jsonrpc" => "2.0", "result" => chain_id_hex(chain_id)} end)
  end

  def rpc_error(message \\ "provider error") do
    start(fn _request ->
      %{"id" => 1, "jsonrpc" => "2.0", "error" => %{"code" => -32_000, "message" => message}}
    end)
  end

  @doc """
  World Chain answering AgentBook's `lookupHuman` with `human_id`. Each call is
  sent to `listener` as `{:eth_call, call}` when one is given.
  """
  def agent_book_answers(human_id, listener \\ nil) do
    start(fn request ->
      [_head, body] = String.split(request, "\r\n\r\n", parts: 2)
      %{"method" => "eth_call", "params" => [call, "latest"]} = Jason.decode!(body)
      if listener, do: send(listener, {:eth_call, call})
      word = human_id |> Integer.to_string(16) |> String.pad_leading(64, "0")
      %{"id" => 1, "jsonrpc" => "2.0", "result" => "0x" <> word}
    end)
  end

  @doc """
  Base answering a smart-wallet signature check: the Multicall3 read returns
  `answer`, a `{success, returned_bytes}` pair, as the wallet's
  `isValidSignature` result. Each request's JSON body
  is sent to `listener` as `{:rpc_request, body}` when one is given.
  """
  def wallet_answers(answer, listener \\ nil) do
    start(fn request ->
      [_head, body] = String.split(request, "\r\n\r\n", parts: 2)
      if listener, do: send(listener, {:rpc_request, Jason.decode!(body)})

      %{"id" => 1, "jsonrpc" => "2.0", "result" => aggregate3_result(answer)}
    end)
  end

  # Multicall3's `(bool, bytes)[]` holding one result.
  defp aggregate3_result({success, returned}) do
    padding = :binary.copy(<<0>>, rem(32 - rem(byte_size(returned), 32), 32))

    encoded =
      <<32::256, 1::256, 32::256, if(success, do: 1, else: 0)::256, 64::256,
        byte_size(returned)::256>> <> returned <> padding

    "0x" <> Base.encode16(encoded, case: :lower)
  end

  @doc "The 32-byte word a wallet returns to approve a signature under ERC-1271."
  def erc1271_approval, do: <<0x1626BA7E::32, 0::224>>

  def invalid_response do
    start(fn _request -> %{} end)
  end

  def timeout do
    start(fn _request ->
      Process.sleep(500)
      %{}
    end)
  end

  defp chain_id_hex(chain_id), do: "0x" <> Integer.to_string(chain_id, 16)

  def start(handler) when is_function(handler, 1) do
    {:ok, listen_socket} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

    {:ok, port} = :inet.port(listen_socket)

    pid =
      spawn_link(fn ->
        accept_loop(listen_socket, handler)
      end)

    ExUnit.Callbacks.on_exit(fn ->
      :gen_tcp.close(listen_socket)
      Process.exit(pid, :shutdown)
    end)

    "http://127.0.0.1:#{port}"
  end

  defp accept_loop(listen_socket, handler) do
    case :gen_tcp.accept(listen_socket) do
      {:ok, socket} ->
        request =
          case :gen_tcp.recv(socket, 0, 1_000) do
            {:ok, data} -> data
            {:error, _reason} -> ""
          end

        body = request |> handler.() |> Jason.encode!()

        response =
          "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: #{byte_size(body)}\r\n\r\n#{body}"

        :gen_tcp.send(socket, response)
        :gen_tcp.close(socket)
        accept_loop(listen_socket, handler)

      {:error, :closed} ->
        :ok
    end
  end
end
