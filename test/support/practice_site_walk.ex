defmodule SiwaServer.PracticeSiteWalk do
  @moduledoc """
  An agent's walk to a practice site on its person's own computer: this server on a real
  loopback port, a customer's sandbox site, a new key in an empty home, and a served
  client run as a person installs it.
  """

  alias SiwaServer.Customers.{Customer, Site}
  alias SiwaServer.Repo

  @python Path.expand("priv/static/agent/siwa_agent.py")
  @node Path.expand("priv/static/agent/siwa-agent.mjs")
  @node_modules Path.expand("e2e/node_modules")

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

  @doc "Every path `Server` was sent so far."
  def server_paths do
    receive do
      {:server, path} -> [path | server_paths()]
    after
      0 -> []
    end
  end

  @doc "The port a Bandit server listens on."
  def port(server) do
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    port
  end

  @doc "A paid customer's new sandbox site at `origin`."
  def sandbox_site(origin) do
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

  @doc "A new key in the file `keygen` writes off a Mac, in `home`; answers its address."
  def new_key!(home) do
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

  @doc """
  Runs a client command as a person installs it, with its home in `tmp_dir/home`, and
  reads its exit status and the JSON it says: the site's answer on stdout (exit 1 when
  the site refused), or the client's own refusal on stderr.
  """
  def client_runner(client, %{broker: broker, tmp_dir: tmp_dir}) do
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

      said = if status in [0, 1], do: output, else: File.read!(stderr)
      {status, Jason.decode!(said)}
    end
  end
end
