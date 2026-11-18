defmodule SiwaDemo.SiwaClientTest do
  use ExUnit.Case, async: false

  alias SiwaDemo.SiwaClient

  # The SIWA service, on a local port: it tells the test what it was sent, then
  # answers with the status it was given.
  defmodule Service do
    @behaviour Plug

    import Plug.Conn

    @impl Plug
    def init(opts), do: opts

    @impl Plug
    def call(conn, {test, status, headers}) do
      {:ok, body, conn} = read_body(conn)
      send(test, {:asked, conn.method, conn.request_path, conn.req_headers, body})

      conn
      |> merge_resp_headers(headers)
      |> put_resp_content_type("application/json")
      |> send_resp(status, ~s({"code":"http_envelope_valid","data":{}}))
    end
  end

  @payload %{
    "method" => "GET",
    "path" => "/api/hello",
    "authority" => "demo.example",
    "headers" => %{"x-siwa-signature" => "sig1=:c2ln:"}
  }

  setup do
    service = Application.fetch_env!(:siwa_demo, :siwa_service)
    on_exit(fn -> Application.put_env(:siwa_demo, :siwa_service, service) end)
  end

  test "posts the payload to the service's check with the server key and the handle" do
    serve(200)

    assert {:ok, %{status: 200, body: %{"code" => "http_envelope_valid"}}} =
             SiwaClient.verify_http_request(@payload, audience: "demo")

    assert_received {:asked, "POST", path, headers, body}
    assert path == Siwa.AgentAuthPlug.http_verify_path()
    assert {"authorization", "Bearer test-server-key"} in headers
    assert {"x-siwa-audience", "demo"} in headers
    assert Jason.decode!(body) == @payload
  end

  test "does not follow a redirect, so the key goes nowhere else" do
    serve(307, [{"location", "/elsewhere"}])

    assert {:ok, %{status: 307}} = SiwaClient.verify_http_request(@payload, audience: "demo")
    assert_received {:asked, "POST", _path, _headers, _body}
    refute_received {:asked, _method, "/elsewhere", _headers, _body}
  end

  defp serve(status, headers \\ []) do
    server =
      start_supervised!(
        {Bandit,
         plug: {Service, {self(), status, headers}}, ip: :loopback, port: 0, startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    Application.put_env(:siwa_demo, :siwa_service, "http://127.0.0.1:#{port}")
  end
end
