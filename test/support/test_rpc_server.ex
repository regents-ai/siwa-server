defmodule SiwaServer.TestRpcServer do
  @moduledoc false

  def owner_of(owner_address) do
    start(fn _request ->
      %{
        "id" => 1,
        "jsonrpc" => "2.0",
        "result" => "0x000000000000000000000000" <> String.trim_leading(owner_address, "0x")
      }
    end)
  end

  def invalid_response do
    start(fn _request -> %{} end)
  end

  def timeout do
    start(fn _request ->
      Process.sleep(500)
      %{}
    end)
  end

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
