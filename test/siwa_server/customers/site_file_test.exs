defmodule SiwaServer.Customers.SiteFileTest do
  @moduledoc """
  The site file is read safely wherever an origin points. Host names resolve here
  through the VM's own host table, which every test in the run shares, so this
  module runs alone. The reads themselves go to a server on this computer, at the
  address the test names, as `fetch/1` connects to the address it checked.
  """

  use ExUnit.Case, async: false

  alias SiwaServer.Customers.SiteFile

  @suffix ".siwa-test.invalid"

  # Each host's addresses; one that is not public is enough to refuse the host.
  @refused [
    {"loopback", [{127, 0, 0, 1}]},
    {"loopback-v6", [{0, 0, 0, 0, 0, 0, 0, 1}]},
    {"private-10", [{10, 0, 0, 1}]},
    {"private-172", [{172, 16, 0, 1}]},
    {"private-192", [{192, 168, 1, 1}]},
    {"link-local", [{169, 254, 169, 254}]},
    {"link-local-v6", [{0xFE80, 0, 0, 0, 0, 0, 0, 1}]},
    {"unique-local", [{0xFD00, 0, 0, 0, 0, 0, 0, 1}]},
    {"cgnat", [{100, 64, 0, 1}]},
    {"multicast", [{224, 0, 0, 1}]},
    {"multicast-v6", [{0xFF02, 0, 0, 0, 0, 0, 0, 1}]},
    {"unspecified", [{0, 0, 0, 0}]},
    {"unspecified-v6", [{0, 0, 0, 0, 0, 0, 0, 0}]},
    {"mapped-loopback", [{0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 1}]},
    {"mapped-private", [{0, 0, 0, 0, 0, 0xFFFF, 0x0A00, 2}]},
    {"public-and-private", [{93, 184, 215, 14}, {0xFD00, 0, 0, 0, 0, 0, 0, 2}]}
  ]

  setup do
    lookup = :inet_db.res_option(:lookup)
    :inet_db.set_lookup([:file, :native])

    for {name, addresses} <- @refused,
        address <- addresses,
        do: :inet_db.add_host(address, [String.to_charlist(name <> @suffix)])

    on_exit(fn ->
      :inet_db.set_lookup(lookup)
      for {_name, addresses} <- @refused, address <- addresses, do: :inet_db.del_host(address)
    end)
  end

  test "a host is refused when any address it resolves to is not public" do
    for {name, _addresses} <- @refused do
      assert SiteFile.fetch("https://" <> name <> @suffix) == {:error, :address_not_allowed},
             name
    end
  end

  test "only an https origin on the default port, to a host name, is read" do
    for origin <- [
          "http://acme.example",
          "https://acme.example:8443",
          "https://acme.example:443",
          "https://acme.example/",
          "https://Acme.example",
          "https://127.0.0.1",
          "https://2130706433",
          "https://[::1]",
          "https://[::ffff:127.0.0.1]"
        ] do
      assert SiteFile.fetch(origin) == {:error, :not_https}, origin
    end
  end

  test "a host with no address is unreachable" do
    assert SiteFile.fetch("https://nothing" <> @suffix) == {:error, :unreachable}
  end

  test "the file is read from the checked address, under the origin's host name" do
    port = serve("HTTP/1.1 200 OK\r\ncontent-length: 7\r\n\r\n token\n")

    assert read(port) == {:ok, " token\n"}
    assert_received {:request, ^port, request}
    assert request =~ ~r"\AGET /\.well-known/siwa-site\.txt HTTP/1\.1\r\n"
    assert request =~ ~r"\r\nhost: acme\.example:#{port}\r\n"i
  end

  test "a redirect is an answer, and is never followed" do
    target = serve("HTTP/1.1 200 OK\r\ncontent-length: 5\r\n\r\ntoken")

    for status <- [
          "301 Moved Permanently",
          "302 Found",
          "307 Temporary Redirect",
          "308 Permanent Redirect"
        ] do
      port =
        serve(
          "HTTP/1.1 #{status}\r\nlocation: http://127.0.0.1:#{target}/.well-known/siwa-site.txt\r\n" <>
            "content-length: 0\r\n\r\n"
        )

      assert read(port) == {:error, :redirected}, status
      assert_received {:request, ^port, _request}
    end

    refute_receive {:request, ^target, _request}, 100
  end

  test "any other status is not the file" do
    for status <- ["204 No Content", "404 Not Found", "410 Gone", "500 Internal Server Error"] do
      port = serve("HTTP/1.1 #{status}\r\ncontent-length: 0\r\n\r\n")
      assert read(port) == {:error, :not_found}, status
    end
  end

  test "the body is read up to 1 KB, however it is sent" do
    full = String.duplicate("a", 1_024)

    assert read(serve("HTTP/1.1 200 OK\r\ncontent-length: 1024\r\n\r\n" <> full)) == {:ok, full}

    assert read(serve("HTTP/1.1 200 OK\r\ncontent-length: 1025\r\n\r\n" <> full <> "a")) ==
             {:error, :too_large}

    chunked =
      "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n" <>
        "400\r\n" <> full <> "\r\n1\r\na\r\n0\r\n\r\n"

    assert read(serve(chunked)) == {:error, :too_large}
  end

  test "a read stops at its deadline, and a closed port is unreachable" do
    silent = serve(nil)
    started = System.monotonic_time(:millisecond)

    assert read(silent, 200) == {:error, :unreachable}
    assert System.monotonic_time(:millisecond) - started < 1_000

    {:ok, listener} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, closed} = :inet.port(listener)
    :ok = :gen_tcp.close(listener)

    assert read(closed) == {:error, :unreachable}
  end

  defp read(port, within_ms \\ 5_000) do
    uri = URI.parse("http://acme.example:#{port}/.well-known/siwa-site.txt")
    SiteFile.get(uri, {127, 0, 0, 1}, System.monotonic_time(:millisecond) + within_ms)
  end

  # One connection: it sends the request it read to the test, then `response`, or
  # nothing at all for a while when `response` is nil.
  defp serve(response) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false, reuseaddr: true])

    {:ok, port} = :inet.port(listener)
    test = self()

    pid =
      spawn(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        send(test, {:request, port, request(socket, "")})

        if response,
          do: :gen_tcp.send(socket, response),
          else: Process.sleep(1_000)

        :gen_tcp.close(socket)
        :gen_tcp.close(listener)
      end)

    :ok = :gen_tcp.controlling_process(listener, pid)
    on_exit(fn -> Process.exit(pid, :kill) end)
    port
  end

  defp request(socket, read) do
    if String.contains?(read, "\r\n\r\n") do
      read
    else
      {:ok, more} = :gen_tcp.recv(socket, 0, 2_000)
      request(socket, read <> more)
    end
  end
end
