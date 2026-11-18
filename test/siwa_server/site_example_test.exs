defmodule SiwaServer.SiteExampleTest do
  @moduledoc """
  The example check served at `/site/siwa-site.mjs`, run as the practice site the
  websites guide starts.

  This server runs on a real local port. Each test downloads the example from it, as the
  guide does, and runs it with Node on a free port as a customer's sandbox site at
  `http://localhost:<port>`, holding that site's real test key. The served Python client,
  from an empty home holding only a new key, signs requests for the site's handle: the
  example asks this server about each one and answers with the agent that signed it. An
  unsigned request is refused without asking, and when the site's own key is refused, the
  agent learns only that it can try again while the site's log says why.
  """

  use SiwaServer.DataCase, async: false

  import SiwaServer.PracticeSiteWalk

  alias SiwaServer.Customers.SiteCredential
  alias SiwaServer.PracticeSiteWalk.Server

  @moduletag :tmp_dir

  @example Path.expand("priv/static/site/siwa-site.mjs")
  @verify "/api/shared/siwa/http-verify"

  setup %{tmp_dir: tmp_dir} do
    server =
      start_supervised!(
        {Bandit, plug: {Server, self()}, ip: :loopback, port: 0, startup_log: false}
      )

    broker = "http://127.0.0.1:#{port(server)}"
    served = Req.get!(broker <> "/site/siwa-site.mjs", retry: false)
    assert served.status == 200
    assert served.body == File.read!(@example)
    example = Path.join(tmp_dir, "siwa-site.mjs")
    File.write!(example, served.body)

    port = free_port()
    site = sandbox_site("http://localhost:#{port}")
    {key, credential} = SiteCredential.new(site)
    Repo.insert!(credential)
    start_example!(example, port, key, broker)

    %{broker: broker, example: example, port: port, site: site}
  end

  test "a signed request is answered with its agent, and the agent is known when it is back",
       context do
    %{port: port, site: site, tmp_dir: tmp_dir} = context
    address = new_key!(Path.join(tmp_dir, "home"))
    run = client_runner(:python, context)
    caller = "eip155:8453:" <> address
    url = "http://localhost:#{port}/api/hello"

    assert {0, %{"status" => 200, "body" => first}} =
             run.(["request", "GET", url, "--handle", site.audience])

    assert %{
             "caller" => ^caller,
             "wallet" => ^address,
             "visits" => 1,
             "listing" => nil,
             "person" => nil
           } = first

    assert {0, %{"status" => 200, "body" => %{"caller" => ^caller, "visits" => 2}}} =
             run.(["request", "GET", url <> "?page=2", "--handle", site.audience])

    assert @verify in server_paths()
  end

  test "a signed request with a body is accepted", context do
    %{port: port, site: site, tmp_dir: tmp_dir} = context
    caller = "eip155:8453:" <> new_key!(Path.join(tmp_dir, "home"))
    run = client_runner(:python, context)
    url = "http://localhost:#{port}/api/notes"

    assert {0, %{"status" => 200, "body" => %{"caller" => ^caller, "visits" => 1}}} =
             run.([
               "request",
               "POST",
               url,
               "--body",
               ~s({"text":"hello"}),
               "--handle",
               site.audience
             ])
  end

  test "an unsigned request is refused without asking this server", %{port: port} do
    # Node listens on the first address localhost names, which is ::1 on a Mac; Mint
    # tries IPv4 alone unless told to try IPv6 first.
    response =
      Req.get!("http://localhost:#{port}/api/hello",
        connect_options: [transport_opts: [inet6: true]],
        retry: false
      )

    assert response.status == 401
    assert %{"error" => %{"code" => "signature_required"}} = response.body
    refute @verify in server_paths()
  end

  test "an agent sent to a site whose key names no site learns only to try again", context do
    %{broker: broker, example: example, site: site, tmp_dir: tmp_dir} = context
    new_key!(Path.join(tmp_dir, "home"))
    run = client_runner(:python, context)
    {never_kept, _credential} = SiteCredential.new(site)
    port = free_port()
    log = start_example!(example, port, never_kept, broker)

    assert {1, %{"status" => 503, "body" => answer}} =
             run.([
               "request",
               "GET",
               "http://localhost:#{port}/api/hello",
               "--handle",
               site.audience
             ])

    assert %{"error" => %{"code" => "service_unavailable"}} = answer
    refute Jason.encode!(answer) =~ "site_key_invalid"
    assert @verify in server_paths()
    assert_receive {^log, {:data, {:eol, line}}}, 5_000
    assert line =~ "site_key_invalid"
  end

  # A port nothing listens on now, for a practice site's address.
  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: :loopback)
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  # Runs the example as the guide does, on `port` with `key`, and waits until it listens.
  # Its output, the site's log, comes to the test a line at a time. Node never reads its
  # stdin, so a shell stops it once the port closes: when the test ends, and when the
  # whole run is stopped.
  defp start_example!(example, port, key, broker) do
    shell = ~s(node "$@" & trap 'kill $!' EXIT; read _)

    site =
      Port.open({:spawn_executable, System.find_executable("sh")}, [
        :binary,
        :stderr_to_stdout,
        {:line, 4096},
        args: ["-c", shell, "sh", example, Integer.to_string(port)],
        env: [
          {~c"SIWA_SERVER_KEY", String.to_charlist(key)},
          {~c"SIWA_BROKER", String.to_charlist(broker)}
        ]
      ])

    assert_receive {^site, {:data, {:eol, listening}}}, 10_000
    assert listening =~ "http://localhost:#{port}"
    site
  end
end
