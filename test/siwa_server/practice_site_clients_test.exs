defmodule SiwaServer.PracticeSiteClientsTest do
  @moduledoc """
  An agent reaches its person's practice site, end to end.

  This server runs on a real local port, and so does one practice site: a customer's
  sandbox site at `http://localhost:<port>`, which checks every signed request with its
  own test key through the shared `Siwa.AgentAuthPlug`. For each served client (Python
  through `uv`, Node beside its one library), starting from an empty home holding only a
  new key: `request ... --handle` signs in for the site's handle and sends a request the
  site's keyed check accepts, and the client never asks this server for the address's
  audience. With `--handle`, an address that is not `http://localhost:<port>` is refused
  on the computer, and neither this server nor the site hears anything.
  """

  use SiwaServer.DataCase, async: false

  alias Siwa.AgentAuthPlug
  alias SiwaServer.Customers.{Customer, Site, SiteCredential}

  @moduletag :tmp_dir

  @python Path.expand("priv/static/agent/siwa_agent.py")
  @node Path.expand("priv/static/agent/siwa-agent.mjs")
  @node_modules Path.expand("e2e/node_modules")
  @lookup "/api/shared/siwa/audience"

  defmodule Server do
    @moduledoc false
    # This server, telling the test the path of each request it is sent.
    @behaviour Plug

    alias SiwaServerWeb.Endpoint

    @impl Plug
    def init(test), do: test

    @impl Plug
    def call(conn, test) do
      send(test, {:server, conn.request_path})
      Endpoint.call(conn, Endpoint.init([]))
    end
  end

  defmodule Hooks do
    @moduledoc false
    @behaviour Siwa.AgentAuthPlug.Hooks

    @impl true
    def before_verify(_conn, _headers), do: {:ok, nil}

    @impl true
    def accept(conn, data, _context), do: {:ok, Plug.Conn.assign(conn, :siwa_accepted, data)}

    @impl true
    def deny(conn, deny_meta), do: Plug.Conn.assign(conn, :siwa_denied, deny_meta)
  end

  defmodule KeyedClient do
    @moduledoc false
    # What a customer's site does: asks this server over HTTP with its server key.
    @behaviour Siwa.AgentAuthPlug.Client

    @impl true
    def verify_http_request(payload, opts) do
      %{broker: broker, key: key} = Process.get(:practice_site)

      Req.post(broker <> AgentAuthPlug.http_verify_path(),
        json: payload,
        headers: [{"authorization", "Bearer " <> key}, {"x-siwa-audience", opts[:audience]}],
        retry: false
      )
    end
  end

  defmodule PracticeSite do
    @moduledoc false
    # A practice site that checks each request with its key and answers what it decided.
    # Its key and handle are made once it listens, as its address names its port.
    @behaviour Plug

    import Plug.Conn

    @impl Plug
    def init(names), do: names

    @impl Plug
    def call(conn, {test, record}) do
      send(test, {:site, conn.method, conn.request_path})
      site = Agent.get(record, & &1)
      Process.put(:practice_site, site)
      conn = AgentAuthPlug.call(conn, hooks: Hooks, audience: site.audience, client: KeyedClient)

      {status, verdict} =
        case conn.assigns do
          %{siwa_accepted: data} -> {200, data}
          %{siwa_denied: meta} -> {401, Map.take(meta, [:reason, :siwa_status, :siwa_code])}
        end

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(verdict))
    end
  end

  setup do
    test = self()
    record = start_supervised!({Agent, fn -> nil end})

    server =
      start_supervised!(
        {Bandit, plug: {Server, test}, ip: :loopback, port: 0, startup_log: false},
        id: :server
      )

    practice =
      start_supervised!(
        {Bandit,
         plug: {PracticeSite, {test, record}}, ip: :loopback, port: 0, startup_log: false},
        id: :practice
      )

    port = port(practice)
    site = sandbox_site("http://localhost:#{port}")
    {key, credential} = SiteCredential.new(site)
    Repo.insert!(credential)
    broker = "http://127.0.0.1:#{port(server)}"
    Agent.update(record, fn nil -> %{broker: broker, key: key, audience: site.audience} end)

    %{broker: broker, port: port, handle: site.audience}
  end

  for client <- [:python, :node] do
    test "the #{client} client's request to a practice site is accepted by its keyed check",
         context do
      %{port: port, handle: handle, tmp_dir: tmp_dir} = context
      address = new_key!(Path.join(tmp_dir, "home"))
      run = client_runner(unquote(client), context)
      url = "http://localhost:#{port}/api/agents/v1/whoami"

      assert {0, %{"status" => 200, "body" => verdict}} =
               run.(["request", "GET", url, "--handle", handle])

      assert_received {:site, "GET", "/api/agents/v1/whoami"}
      subject = "eip155:8453:" <> address

      assert %{
               "walletAddress" => ^address,
               "subject" => ^subject,
               "principal" => %{"audience" => ^handle}
             } = verdict

      paths = server_paths()
      assert "/api/shared/siwa/http-verify" in paths
      refute @lookup in paths
    end
  end

  for client <- [:python, :node] do
    test "the #{client} client refuses --handle for any other address and sends nothing",
         context do
      %{port: port, handle: handle, tmp_dir: tmp_dir} = context
      new_key!(Path.join(tmp_dir, "home"))
      run = client_runner(unquote(client), context)

      for url <- [
            "https://localhost:#{port}/api/agents/v1/whoami",
            "http://127.0.0.1:#{port}/api/agents/v1/whoami",
            "http://localhost/api/agents/v1/whoami"
          ],
          command <- ["request", "headers"] do
        assert {2, %{"error" => _}} = run.([command, "GET", url, "--handle", handle])
      end

      refute_received {:site, _method, _path}
      assert server_paths() == []
    end
  end

  # Every path this server was sent so far.
  defp server_paths do
    receive do
      {:server, path} -> [path | server_paths()]
    after
      0 -> []
    end
  end

  defp port(server) do
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    port
  end

  defp sandbox_site(origin) do
    n = System.unique_integer([:positive])

    customer =
      Repo.insert!(%Customer{
        owner_did: "did:privy:#{Ecto.UUID.generate()}",
        name: "Acme",
        kind: :paid,
        subscription_status: "active"
      })

    Repo.insert!(%Site{
      customer_id: customer.id,
      name: "Practice #{n}",
      audience: "practice-#{n}",
      environment: :sandbox,
      origins: [origin]
    })
  end

  # A new key in the file `keygen` writes off a Mac.
  defp new_key!(home) do
    private_key = :crypto.strong_rand_bytes(32)
    {:ok, <<4, public_key::binary-size(64)>>} = ExSecp256k1.create_public_key(private_key)
    hash = ExKeccak.hash_256(public_key)
    address = "0x" <> Base.encode16(binary_part(hash, 12, 20), case: :lower)
    File.mkdir_p!(home)

    File.write!(
      Path.join(home, "key.json"),
      Jason.encode!(%{
        address: address,
        private_key: "0x" <> Base.encode16(private_key, case: :lower)
      })
    )

    address
  end

  # Runs a client command as a person installs it, and reads its exit status and the
  # JSON it says: the answer on stdout, or the refusal on stderr.
  defp client_runner(client, %{broker: broker, tmp_dir: tmp_dir}) do
    env = [{"SIWA_AGENT_HOME", Path.join(tmp_dir, "home")}, {"SIWA_BROKER", broker}]

    {command, start} =
      case client do
        :python ->
          {"uv", ["run", "-q", @python]}

        :node ->
          folder = Path.join(tmp_dir, "node")
          File.mkdir_p!(folder)
          File.cp!(@node, Path.join(folder, "siwa-agent.mjs"))
          File.ln_s!(@node_modules, Path.join(folder, "node_modules"))
          {"node", [Path.join(folder, "siwa-agent.mjs")]}
      end

    fn args ->
      stderr = Path.join(tmp_dir, "stderr.txt")

      {output, status} =
        System.cmd("sh", ["-c", ~s("$@" 2>"#{stderr}"), "sh", command | start ++ args], env: env)

      said = if status == 0, do: output, else: File.read!(stderr)
      {status, Jason.decode!(said)}
    end
  end
end
