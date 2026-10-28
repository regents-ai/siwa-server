defmodule SiwaServer.FirstSignedRequestTest do
  @moduledoc """
  A brand-new agent's first signed request, end to end, as it happens in the field.

  This server runs on a real local port. Each served client (Python through `uv`,
  Node beside its one library) starts from an empty home holding only a new key in the
  shape `keygen` writes off a Mac, and signs its first requests with `headers`: it lists
  the sites, signs in on its own and signs the request. A site then checks those exact
  headers the way every Regent site does, through the shared `Siwa.AgentAuthPlug` and
  its broker client over HTTP. For each of two sites, the request is accepted once for
  the right agent and site, a repeat is refused, and the other site refuses it.
  """

  use SiwaServer.DataCase, async: false

  alias Siwa.AgentAuthPlug
  alias Siwa.AgentAuthPlug.BrokerClient

  @python Path.expand("priv/static/agent/siwa_agent.py")
  @node Path.expand("priv/static/agent/siwa-agent.mjs")
  @node_modules Path.expand("e2e/node_modules")
  @sites %{"keyfleet" => "https://keyfleet.ai", "patchbay" => "https://patchbay.help"}
  @clients %{"keyfleet" => __MODULE__.KeyfleetClient, "patchbay" => __MODULE__.PatchbayClient}

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

  # What a site's own client does: the shared broker client over HTTP, here to this
  # test's local server, with the site's own verify key.
  def verify_for(payload, audience) do
    BrokerClient.verify_http_request(payload,
      http: Req,
      base_url: Process.get(:siwa_broker),
      verify_key:
        :siwa_server
        |> Application.fetch_env!(:siwa)
        |> Keyword.fetch!(:site_verifiers)
        |> Map.fetch!(audience)
    )
  end

  defmodule KeyfleetClient do
    @moduledoc false
    @behaviour Siwa.AgentAuthPlug.Client

    @impl true
    def verify_http_request(payload),
      do: SiwaServer.FirstSignedRequestTest.verify_for(payload, "keyfleet")
  end

  defmodule PatchbayClient do
    @moduledoc false
    @behaviour Siwa.AgentAuthPlug.Client

    @impl true
    def verify_http_request(payload),
      do: SiwaServer.FirstSignedRequestTest.verify_for(payload, "patchbay")
  end

  setup do
    previous = Application.get_env(:siwa_server, :siwa)

    Application.put_env(
      :siwa_server,
      :siwa,
      Keyword.put(
        previous,
        :wallet_origins,
        Map.new(@sites, fn {site, origin} -> {site, [origin]} end)
      )
    )

    on_exit(fn -> Application.put_env(:siwa_server, :siwa, previous) end)

    server =
      start_supervised!(
        {Bandit, plug: SiwaServerWeb.Endpoint, ip: :loopback, port: 0, startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    broker = "http://127.0.0.1:#{port}"
    Process.put(:siwa_broker, broker)
    %{broker: broker}
  end

  for client <- [:python, :node] do
    @tag :tmp_dir
    test "the #{client} client's first signed requests are accepted once, by their own site",
         %{broker: broker, tmp_dir: tmp_dir} do
      address = new_key!(Path.join(tmp_dir, "home"))
      run = client_runner(unquote(client), tmp_dir, broker)
      body = Jason.encode!(%{code: "ABCD-1234", name: "Astra", harness: "claude_code"})

      # Each site in turn, so a client that signs for the wrong site is caught.
      for {audience, other} <- [{"keyfleet", "patchbay"}, {"patchbay", "keyfleet"}],
          {method, path, request_body} <- [
            {"GET", "/api/agents/v1/whoami", nil},
            {"POST", "/api/agents/v1/pair", body}
          ] do
        body_args = if request_body, do: ["--body", request_body], else: []
        headers = run.(["headers", method, @sites[audience] <> path | body_args])
        check = fn site -> site_check(site, method, path, request_body, headers) end

        assert %{"walletAddress" => ^address, "principal" => %{"audience" => ^audience}} =
                 check.(audience).assigns.siwa_accepted

        assert %{siwa_status: 409} = check.(audience).assigns.siwa_denied
        assert %{siwa_status: 401} = check.(other).assigns.siwa_denied
      end

      # A pairing request whose body changed after signing is refused.
      headers =
        run.(["headers", "POST", @sites["keyfleet"] <> "/api/agents/v1/pair", "--body", body])

      changed = site_check("keyfleet", "POST", "/api/agents/v1/pair", body <> " ", headers)

      assert %{siwa_status: 401, siwa_code: "http_body_binding_invalid"} =
               changed.assigns.siwa_denied
    end
  end

  # A new key in the file `keygen` writes off a Mac; a Mac's keygen locks it with Touch ID,
  # which the e2e walk covers.
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

  # Runs a client command as a person installs it, and reads the JSON it prints.
  defp client_runner(client, tmp_dir, broker) do
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

    # What the client says on stderr is kept apart: a warning there is not its answer.
    fn args ->
      stderr = Path.join(tmp_dir, "stderr.txt")

      {output, status} =
        System.cmd("sh", ["-c", ~s("$@" 2>"#{stderr}"), "sh", command | start ++ args], env: env)

      assert status == 0, File.read!(stderr)
      Jason.decode!(output)
    end
  end

  # The site's own check of a request carrying these headers, through the shared plug.
  defp site_check(audience, method, path, body, headers) do
    conn =
      Enum.reduce(headers, Plug.Test.conn(method, path, body), fn {name, value}, conn ->
        Plug.Conn.put_req_header(conn, name, value)
      end)

    conn =
      if body do
        {:ok, ^body, conn} = AgentAuthPlug.read_body(conn, [], 32_768)
        conn
      else
        conn
      end

    AgentAuthPlug.call(conn,
      hooks: Hooks,
      audience: audience,
      client: Map.fetch!(@clients, audience)
    )
  end
end
