defmodule SiwaServer.PracticeSiteClientsTest do
  @moduledoc """
  An agent reaches its person's practice site, end to end.

  This server runs on a real local port, and so does one practice site: a customer's
  sandbox site at `http://localhost:<port>`, which checks every signed request with its
  own test key through the shared `Siwa.AgentAuthPlug`. For each served client (Python
  through `uv`, Node beside its one library), starting from an empty home holding only a
  new key: `request ... --handle` signs in for the site's handle and sends a request the
  site's keyed check accepts, and the client never asks this server for the address's
  audience. The same holds from an empty home given only an address and an outside
  wallet tool's signing command (`use-wallet ... --signer`): the key stays in the tool, and
  the client's home holds the address and the command. With `--handle`, an address that
  is not `http://localhost:<port>` is refused on the computer, and neither this server
  nor the site hears anything.
  """

  use SiwaServer.DataCase, async: false

  import SiwaServer.AgentWalk

  alias Siwa.AgentAuthPlug
  alias SiwaServer.AgentWalk.Server
  alias SiwaServer.Customers.SiteCredential

  @moduletag :tmp_dir

  @lookup "/api/shared/siwa/audience"

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
    test "the #{client} client's request signed by an outside wallet tool is accepted by a practice site's keyed check",
         context do
      %{port: port, handle: handle, tmp_dir: tmp_dir} = context
      {private_key, address} = new_account()
      wallet = node_folder!(Path.join(tmp_dir, "wallet"))
      File.write!(Path.join(wallet, "key.txt"), private_key)

      File.write!(Path.join(wallet, "sign.mjs"), """
      import { readFileSync } from "node:fs";
      import { privateKeyToAccount } from "viem/accounts";
      const account = privateKeyToAccount(readFileSync(new URL("key.txt", import.meta.url), "utf8"));
      console.log(await account.signMessage({ message: process.env.SIWA_MESSAGE }));
      """)

      signer = ~s(node "#{Path.join(wallet, "sign.mjs")}")
      run = client_runner(unquote(client), context)
      url = "http://localhost:#{port}/api/agents/v1/whoami"

      assert {0, %{"address" => ^address}} = run.(["use-wallet", address, "--signer", signer])

      assert {0, %{"status" => 200, "body" => verdict}} =
               run.(["request", "GET", url, "--handle", handle])

      assert_received {:site, "GET", "/api/agents/v1/whoami"}
      subject = "eip155:8453:" <> address
      assert %{"walletAddress" => ^address, "subject" => ^subject} = verdict
      assert "/api/shared/siwa/http-verify" in server_paths()

      key = tmp_dir |> Path.join("home/key.json") |> File.read!() |> Jason.decode!()
      assert %{"address" => ^address, "signer" => ^signer} = key
      assert key |> Map.keys() |> Enum.sort() == ["address", "chain_id", "signer"]
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
end
