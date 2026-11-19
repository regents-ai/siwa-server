defmodule SiwaServer.SiteExampleTest do
  @moduledoc """
  The example checks served at `/site/siwa-site.mjs` and `/site/siwa_site.py`, each run as
  the practice site the websites guide starts, and the Node example's TypeScript
  declarations served beside it.

  This server runs on a real local port. Each test downloads an example from it, as the
  guide does, checks it is the file in git, and runs it on a free port as a customer's
  sandbox site at `http://localhost:<port>`, holding that site's real test key: the Node
  file with `node`, the Python file with `python3`. The served Python client, from an empty
  home holding only a new key, signs requests for the site's handle: the example asks this
  server about each one and answers with the agent that signed it, and knows the agent
  again when the served Node client sends the next request with the same key. An unsigned
  request is refused without asking, and when the site's own key is refused, the agent
  learns only that it can try again while the site's log says why.
  """

  use SiwaServer.DataCase, async: false

  import SiwaServer.AgentWalk

  alias SiwaServer.AgentWalk.Server
  alias SiwaServer.Customers.SiteCredential

  @moduletag :tmp_dir

  @site Path.expand("priv/static/site")
  @verify "/api/shared/siwa/http-verify"

  setup do
    server =
      start_supervised!(
        {Bandit, plug: {Server, self()}, ip: :loopback, port: 0, startup_log: false}
      )

    %{broker: "http://127.0.0.1:#{port(server)}"}
  end

  test "the Node example's TypeScript declarations are served as they are in git",
       %{broker: broker} do
    download!(broker, "siwa-site.d.mts")
  end

  for {example, runtime} <- [{"siwa-site.mjs", "node"}, {"siwa_site.py", "python3"}] do
    describe example do
      @describetag example: example, runtime: runtime

      setup :start_practice_site

      test "a signed request is answered with its agent, known again when it is back through the other client",
           context do
        %{port: port, site: site, tmp_dir: tmp_dir} = context
        address = new_key!(Path.join(tmp_dir, "home"))
        run = client_runner(:python, context)
        run_node = client_runner(:node, context)
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
                 run_node.(["request", "GET", url <> "?page=2", "--handle", site.audience])

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

      test "an agent sent to a site whose key names no site learns only to try again",
           context do
        %{broker: broker, runtime: runtime, script: script, site: site, tmp_dir: tmp_dir} =
          context

        new_key!(Path.join(tmp_dir, "home"))
        run = client_runner(:python, context)
        {never_kept, _credential} = SiteCredential.new(site)
        port = free_port()
        log = start_example!(runtime, script, port, never_kept, broker)

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
    end
  end

  # Downloads the example as the guide does and runs it as a sandbox site holding its
  # real test key.
  defp start_practice_site(context) do
    %{broker: broker, example: example, runtime: runtime, tmp_dir: tmp_dir} = context
    served = download!(broker, example)
    # Run through a linked folder, as a download into /tmp on a Mac is.
    File.mkdir_p!(Path.join(tmp_dir, "downloads"))
    File.write!(Path.join([tmp_dir, "downloads", example]), served)
    File.ln_s!(Path.join(tmp_dir, "downloads"), Path.join(tmp_dir, "linked"))
    script = Path.join([tmp_dir, "linked", example])

    port = free_port()
    site = sandbox_site("http://localhost:#{port}")
    {key, credential} = SiteCredential.new(site)
    Repo.insert!(credential)
    start_example!(runtime, script, port, key, broker)

    %{port: port, script: script, site: site}
  end

  # The file this server serves at `/site/<name>`, which must be the one in git.
  defp download!(broker, name) do
    served = Req.get!(broker <> "/site/" <> name, retry: false)
    assert served.status == 200
    assert served.body == File.read!(Path.join(@site, name))
    served.body
  end

  # A port nothing listens on now, for a practice site's address.
  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: :loopback)
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  # Runs `script` with `runtime` as the guide does, on `port` with `key`, and waits until
  # it listens. Its output, the site's log, comes to the test a line at a time. The example
  # never reads its stdin, so a shell stops it once the port closes: when the test ends, and
  # when the whole run is stopped.
  defp start_example!(runtime, script, port, key, broker) do
    shell = ~s("$@" & trap 'kill $!' EXIT; read _)

    site =
      Port.open({:spawn_executable, System.find_executable("sh")}, [
        :binary,
        :stderr_to_stdout,
        {:line, 4096},
        args: ["-c", shell, "sh", runtime, script, Integer.to_string(port)],
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
