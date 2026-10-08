defmodule SiwaServer.AgentClientsConformanceTest do
  @moduledoc """
  The served Python and Node clients sign the siwa library's fixture requests
  byte for byte: the same signed text, and the same headers.

  Each client runs its own `headers` command with the fixture's time and nonce.
  Its signer records the text it is handed and answers with the fixture's
  signature, so the test also covers how the client writes that signature into
  its header.
  """

  use ExUnit.Case, async: true

  @python Path.expand("priv/static/agent/siwa_agent.py")
  @node Path.expand("priv/static/agent/siwa-agent.mjs")
  @origin "https://fixture.example"

  defmodule Audiences do
    @moduledoc false
    @behaviour Plug

    @impl Plug
    def init(audiences), do: audiences

    @impl Plug
    def call(conn, audiences) do
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{code: "audiences", data: %{audiences: audiences}})
      )
    end
  end

  setup_all do
    fixtures =
      Mix.Project.deps_paths()
      |> Map.fetch!(:siwa)
      |> Path.join("../../../contract/fixtures.json")
      |> File.read!()
      |> Jason.decode!()

    audience = fixtures["verify"]["audience"]

    broker =
      start_supervised!(
        {Bandit,
         plug: {Audiences, [%{audience: audience, origin: @origin}]},
         ip: :loopback,
         port: 0,
         startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(broker)
    %{fixtures: fixtures, broker: "http://127.0.0.1:#{port}"}
  end

  test "the fixtures are the library's current contract", %{fixtures: fixtures} do
    assert fixtures["contract_id"] == Siwa.Contract.id()
  end

  for client <- [:python, :node] do
    @tag :tmp_dir
    test "the #{client} client signs every fixture request byte for byte", context do
      for signed <- context.fixtures["signed"] do
        home = Path.join(context.tmp_dir, signed["name"])
        expected = Map.new(signed["request"]["headers"], fn [name, value] -> {name, value} end)
        seed_home(home, context.fixtures, expected["x-siwa-signature"])

        headers = run_headers(unquote(client), home, context, signed["request"])

        assert File.read!(Path.join(home, "message.txt")) == signed["signing_message"],
               "#{signed["name"]}: signed text"

        assert headers == expected, "#{signed["name"]}: headers"
      end
    end
  end

  defp seed_home(home, fixtures, signature_header) do
    principal = fixtures["principal"]
    "sig1=:" <> encoded = signature_header

    signature =
      "0x" <> Base.encode16(Base.decode64!(String.trim_trailing(encoded, ":")), case: :lower)

    message_path = Path.join(home, "message.txt")

    write_json!(Path.join(home, "key.json"), %{
      address: principal["wallet_address"],
      chain_id: principal["chain_id"],
      signer: ~s(printf '%s' "$SIWA_MESSAGE" > '#{message_path}'; echo #{signature})
    })

    write_json!(Path.join([home, "receipts", "#{fixtures["verify"]["audience"]}.json"]), %{
      address: principal["wallet_address"],
      audience: fixtures["verify"]["audience"],
      receipt: fixtures["receipt"]["token"],
      receipt_expires_at: "2099-01-01T00:00:00Z",
      key_id: principal["key_id"]
    })

    write_fixed_clock!(home, fixtures["signing"])
  end

  # Fixes the clock and the nonce the clients read, then runs the client unchanged.
  defp write_fixed_clock!(home, %{"created" => created, "nonce" => "sig-nonce-" <> nonce}) do
    File.write!(Path.join(home, "fixed_clock.py"), """
    import runpy, secrets, sys, time
    time.time = lambda: #{created}
    secrets.token_hex = lambda size=None: "#{nonce}"
    sys.argv = sys.argv[1:]
    runpy.run_path(sys.argv[0], run_name="__main__")
    """)

    File.write!(Path.join(home, "fixed_clock.mjs"), """
    import crypto from "node:crypto";
    import { syncBuiltinESMExports } from "node:module";
    Date.now = () => #{created * 1000};
    crypto.randomBytes = () => ({ toString: () => "#{nonce}" });
    syncBuiltinESMExports();
    """)
  end

  defp run_headers(client, home, context, request) do
    url = @origin <> request["path"]
    body = if request["body"], do: ["--body", request["body"]], else: []
    args = ["headers", request["method"], url | body]
    env = [{"SIWA_AGENT_HOME", home}, {"SIWA_BROKER", context.broker}]

    {output, 0} =
      case client do
        :python ->
          System.cmd("python3", ["-I", Path.join(home, "fixed_clock.py"), @python | args],
            env: env,
            stderr_to_stdout: true
          )

        :node ->
          System.cmd("node", ["--import", Path.join(home, "fixed_clock.mjs"), @node | args],
            env: env,
            stderr_to_stdout: true
          )
      end

    Jason.decode!(output)
  end

  defp write_json!(path, value) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(value))
  end
end
