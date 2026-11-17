defmodule SiwaServer.HelloCardClientsTest do
  @moduledoc """
  Each served client gets a hello card and shows it, end to end.

  This server runs on a real local port, and so does one Regent site, over https with a
  certificate from a root made for this run that the clients are told to trust. The
  site's pairing read is answered through its seam: the agent is paired with Ada. For
  each client (Python through `uv`, Node beside its one library): showing a card before
  there is one is refused on the computer and the site hears nothing; `hello-card` gets a
  card that this server's published keys verify, and keeps it; `request --hello-card`
  sends that card unchanged beside a signed request; and an expired card is refused on
  the computer.
  """

  use SiwaServer.DataCase, async: false

  alias SiwaServer.HelloCard
  alias SiwaServerWeb.Endpoint

  @moduletag :tmp_dir

  @python Path.expand("priv/static/agent/siwa_agent.py")
  @node Path.expand("priv/static/agent/siwa-agent.mjs")
  @node_modules Path.expand("e2e/node_modules")
  @paired %{"name" => "Astra", "person" => "Ada", "pairedAt" => "2026-11-01T09:30:00Z"}

  defmodule Site do
    @moduledoc false
    # A Regent site that answers each request with the headers it came with.
    import Plug.Conn

    def init(test), do: test

    def call(conn, test) do
      send(test, {:site, conn.method, conn.request_path})
      headers = Jason.encode!(Map.new(conn.req_headers))
      conn |> put_resp_content_type("application/json") |> send_resp(200, headers)
    end
  end

  setup %{tmp_dir: tmp_dir} do
    siwa = Application.fetch_env!(:siwa_server, :siwa)
    endpoint = Application.fetch_env!(:siwa_server, Endpoint)
    {root, tls} = site_certificate()

    site =
      start_supervised!(
        {Bandit,
         plug: {Site, self()},
         scheme: :https,
         ip: :loopback,
         port: 0,
         startup_log: false,
         thousand_island_options: [transport_options: tls]},
        id: :site
      )

    server =
      start_supervised!(
        {Bandit, plug: Endpoint, ip: :loopback, port: 0, startup_log: false},
        id: :server
      )

    site = "https://127.0.0.1:#{port(site)}"

    Application.put_env(
      :siwa_server,
      :siwa,
      Keyword.put(siwa, :wallet_origins, %{"cardsite" => [site]})
    )

    # This server's own host is the one the clients send to.
    move_endpoint(Keyword.put(endpoint, :url, host: "127.0.0.1", port: port(server)))

    on_exit(fn ->
      Application.put_env(:siwa_server, :siwa, siwa)
      move_endpoint(endpoint)
    end)

    Req.Test.set_req_test_to_shared()
    test = self()

    Req.Test.stub(HelloCard, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:pairing, Jason.decode!(body)})
      Req.Test.json(conn, @paired)
    end)

    # The clients trust this run's root beside the computer's own.
    trusted = Path.join(tmp_dir, "trusted.pem")
    roots = for {:cert, der, _otp} <- :public_key.cacerts_get(), do: der

    File.write!(
      trusted,
      :public_key.pem_encode(for der <- [root | roots], do: {:Certificate, der, :not_encrypted})
    )

    %{broker: "http://127.0.0.1:#{port(server)}", site: site, trusted: trusted}
  end

  for client <- [:python, :node] do
    test "the #{client} client gets a hello card, keeps it and shows it", context do
      %{broker: broker, site: site, tmp_dir: tmp_dir} = context
      home = Path.join(tmp_dir, "home")
      address = new_key!(home)
      run = client_runner(unquote(client), context)
      kept_at = Path.join([home, "cards", "cardsite.json"])
      show = ["request", "GET", site <> "/hello", "--hello-card", site]

      # No card yet: refused here, and the site hears nothing.
      assert {2, %{"error" => _}} = run.(show)
      refute_received {:site, _method, _path}

      assert {0, %{"status" => 200, "body" => %{"code" => "hello_card", "data" => card}}} =
               run.(["hello-card", site])

      subject = "eip155:8453:" <> address
      assert_received {:pairing, %{"subject" => ^subject}}
      assert Jason.decode!(File.read!(kept_at)) == card
      assert %{"subject" => ^subject, "pairedOn" => "cardsite", "person" => "Ada"} = card

      keys = Req.get!(broker <> "/.well-known/jwks.json").body["keys"]

      assert HelloCard.verify(card["card"], keys, DateTime.utc_now()) ==
               {:ok, Map.delete(card, "card")}

      # The kept card goes beside a signed request, unchanged.
      assert {0, %{"status" => 200, "body" => headers}} = run.(show)
      assert_received {:site, "GET", "/hello"}
      assert headers["x-siwa-hello-card"] == card["card"]
      assert Map.has_key?(headers, "x-siwa-signature")

      # Once it has expired, it is refused here, and the site hears nothing.
      expired = DateTime.utc_now() |> DateTime.add(-1) |> DateTime.to_iso8601()
      File.write!(kept_at, Jason.encode!(%{card | "expiresAt" => expired}))
      assert {2, %{"error" => _}} = run.(show)
      refute_received {:site, _method, _path}
    end
  end

  defp port(server) do
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    port
  end

  defp move_endpoint(config), do: Endpoint.config_change([{Endpoint, config}], [])

  # A certificate for 127.0.0.1 from a root made for this run, carrying the key
  # identifiers the clients' strict checks ask for. The keys never leave memory.
  defp site_certificate do
    key_id = :crypto.strong_rand_bytes(20)
    curve = {:namedCurve, :secp256r1}

    root =
      :public_key.pkix_test_root_cert(~c"Hello card test root",
        key: curve,
        digest: :sha256,
        extensions: [{:Extension, {2, 5, 29, 14}, false, key_id}]
      )

    names = [iPAddress: <<127, 0, 0, 1>>]
    authority = {:AuthorityKeyIdentifier, key_id, :asn1_NOVALUE, :asn1_NOVALUE}

    peer =
      :public_key.pkix_test_data(%{
        root: root,
        intermediates: [],
        peer: [
          key: curve,
          digest: :sha256,
          extensions: [
            {:Extension, {2, 5, 29, 17}, false, names},
            {:Extension, {2, 5, 29, 35}, false, authority}
          ]
        ]
      })

    {root.cert, Keyword.take(peer, [:cert, :key])}
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
  defp client_runner(client, %{broker: broker, tmp_dir: tmp_dir, trusted: trusted}) do
    env = [
      {"SIWA_AGENT_HOME", Path.join(tmp_dir, "home")},
      {"SIWA_BROKER", broker},
      {"SSL_CERT_FILE", trusted},
      {"NODE_EXTRA_CA_CERTS", trusted}
    ]

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
