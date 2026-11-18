defmodule SiwaServer.FirstSignedRequestTest do
  @moduledoc """
  A brand-new agent's first signed request, end to end, as it happens in the field.

  This server runs on a real local port. Each served client (Python through `uv`,
  Node beside its one library) starts from an empty home holding only a new key in the
  shape `keygen` writes off a Mac, and signs its first requests with `headers`: it looks
  up the site's audience, signs in on its own and signs the request. A site then checks
  those exact headers the way every Regent site does, through the shared
  `Siwa.AgentAuthPlug` and its broker client over HTTP. For each of two sites, the
  request is accepted once for the right agent and site, a repeat is refused, and the
  other site refuses it.
  """

  use SiwaServer.DataCase, async: false

  import SiwaServer.AgentWalk

  alias Siwa.AgentAuthPlug

  @sites %{"keyfleet" => "https://keyfleet.ai", "patchbay" => "https://patchbay.help"}

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

  defmodule Client do
    @moduledoc false
    @behaviour Siwa.AgentAuthPlug.Client

    alias Siwa.AgentAuthPlug.BrokerClient

    # What a site's own client does: the shared broker client over HTTP, here to this
    # test's local server.
    @impl true
    def verify_http_request(payload, opts) do
      BrokerClient.verify_http_request(
        payload,
        Keyword.merge(opts, http: Req, base_url: Process.get(:siwa_broker))
      )
    end
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

    broker = "http://127.0.0.1:#{port(server)}"
    Process.put(:siwa_broker, broker)
    %{broker: broker}
  end

  for client <- [:python, :node] do
    @tag :tmp_dir
    test "the #{client} client's first signed requests are accepted once, by their own site",
         context do
      %{tmp_dir: tmp_dir} = context
      address = new_key!(Path.join(tmp_dir, "home"))
      run = client_runner(unquote(client), context)
      body = Jason.encode!(%{code: "ABCD-1234", name: "Astra", harness: "claude_code"})

      # Each site in turn, so a client that signs for the wrong site is caught.
      for {audience, other} <- [{"keyfleet", "patchbay"}, {"patchbay", "keyfleet"}],
          {method, path, request_body} <- [
            {"GET", "/api/agents/v1/whoami", nil},
            {"POST", "/api/agents/v1/pair", body},
            {"POST", "/api/agents/v1/pair", ""}
          ] do
        body_args = if request_body, do: ["--body", request_body], else: []
        assert {0, headers} = run.(["headers", method, @sites[audience] <> path | body_args])
        check = fn site -> site_check(site, method, path, request_body, headers) end

        assert %{"walletAddress" => ^address, "principal" => %{"audience" => ^audience}} =
                 check.(audience).assigns.siwa_accepted

        assert %{siwa_status: 409} = check.(audience).assigns.siwa_denied
        assert %{siwa_status: 401} = check.(other).assigns.siwa_denied
      end

      # A pairing request whose body changed after signing is refused.
      pair = @sites["keyfleet"] <> "/api/agents/v1/pair"
      assert {0, headers} = run.(["headers", "POST", pair, "--body", body])

      changed = site_check("keyfleet", "POST", "/api/agents/v1/pair", body <> " ", headers)

      assert %{siwa_status: 401, siwa_code: "http_body_binding_invalid"} =
               changed.assigns.siwa_denied
    end
  end

  # The site's own check of a request carrying these headers, through the shared plug.
  defp site_check(audience, method, path, body, headers) do
    conn =
      Enum.reduce(headers, Plug.Test.conn(method, @sites[audience] <> path, body), fn
        {name, value}, conn ->
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
      client: Client
    )
  end
end
