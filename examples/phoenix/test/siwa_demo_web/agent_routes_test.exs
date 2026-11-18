defmodule SiwaDemoWeb.AgentRoutesTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Phoenix.ConnTest
  import Plug.Conn

  alias SiwaDemo.StubClient

  @endpoint SiwaDemoWeb.Endpoint

  @wallet "0x1111111111111111111111111111111111111111"
  @subject "eip155:8453:" <> @wallet
  @human_id "0x2c9f0a6e1d4b"
  @listing %{
    "agentId" => "eip155:8453:0x8004a169fb4a3325136eb29fa0ceb6d2e539a432:42",
    "tokenId" => 42,
    "profileUrl" => "https://agents.example/42.json",
    "registryUrl" => "https://www.8004scan.io/agents/base/42"
  }

  describe "GET /api/hello" do
    test "asks the service for this site's handle and names the caller from its answer" do
      verified(%{"usage" => usage(true)})
      conn = signed_get("/api/hello")

      assert %{"caller" => @subject, "wallet" => @wallet, "listing" => nil, "person" => nil} =
               json_response(conn, 200)

      assert_received {:checked, %{"method" => "GET", "path" => "/api/hello"}, opts}
      assert opts[:audience] == "demo"
    end

    test "a first visit is not a return, a later one is, and they are greeted apart" do
      verified(%{"usage" => usage(true)})
      first = json_response(signed_get("/api/hello"), 200)

      verified(%{"usage" => usage(false)})
      again = json_response(signed_get("/api/hello"), 200)

      assert first["returning"] == false
      assert again["returning"] == true
      assert first["message"] != again["message"]
    end

    test "leaves returning out when the service counts no visits, as for a practice site" do
      verified(%{})

      refute Map.has_key?(json_response(signed_get("/api/hello"), 200), "returning")
    end

    test "shows the listing and how many agents the person backs, never the person's number" do
      verified(%{
        "agentRegistration" => @listing,
        "agentBook" => %{"humanId" => @human_id, "agentCount" => 2}
      })

      conn = signed_get("/api/hello")

      assert %{
               "listing" => %{
                 "agentId" => @listing["agentId"],
                 "profileUrl" => @listing["profileUrl"]
               },
               "person" => %{"agentCount" => 2}
             } == Map.take(json_response(conn, 200), ["listing", "person"])

      refute conn.resp_body =~ @human_id
    end
  end

  describe "GET /api/lounge" do
    test "opens for an agent with a registry listing" do
      verified(%{"agentRegistration" => @listing})

      assert %{"agentId" => agent_id} = json_response(signed_get("/api/lounge"), 200)
      assert agent_id == @listing["agentId"]
    end

    test "refuses an agent without one, saying how to get one" do
      verified(%{})

      assert %{"error" => %{"code" => "listing_required", "hint" => hint}} =
               json_response(signed_get("/api/lounge"), 403)

      assert hint =~ "register-agent"
      assert hint =~ "link-agent"
    end
  end

  describe "refusals" do
    test "a request with no signature is refused without asking the service" do
      conn = get(build_conn(), "/api/hello")

      assert %{"error" => %{"code" => "signature_required"}} = json_response(conn, 401)
      refute_received {:checked, _payload, _opts}
    end

    test "a query string is refused without asking the service" do
      conn = signed_get("/api/hello?as=someone")

      assert %{"error" => %{"code" => "unsupported_query"}} = json_response(conn, 401)
      refute_received {:checked, _payload, _opts}
    end

    for {status, code} <- [
          {400, "invalid_request"},
          {401, "http_signature_invalid"},
          {401, "receipt_binding_mismatch"},
          {409, "request_replayed"}
        ] do
      test "the service's #{status} #{code} about the agent's request reaches the agent as 401 #{code}" do
        refused(unquote(status), unquote(code))

        assert %{"error" => %{"code" => unquote(code)}} =
                 json_response(signed_get("/api/hello"), 401)
      end
    end

    test "every problem of the site's own reaches the agent as the same 503, and only the log says which" do
      site_problems = [
        refusal(401, "site_key_invalid"),
        refusal(401, "site_audience_mismatch"),
        refusal(401, "site_key_required"),
        refusal(402, "billing_required"),
        refusal(402, "agent_cap_reached"),
        refusal(403, "site_not_verified"),
        refusal(429, "site_rate_limited"),
        refusal(429, "rate_limited"),
        refusal(502, "signature_lookup_failed"),
        refusal(503, "verification_unavailable"),
        {:ok, %{status: 302, body: ""}},
        {:error, %Req.TransportError{reason: :econnrefused}}
      ]

      answers =
        for problem <- site_problems do
          StubClient.answer(problem)

          {conn, log} = with_log(fn -> signed_get("/api/hello") end)

          assert conn.status == 503
          assert log =~ logged(problem)
          refute conn.resp_body =~ logged(problem)

          json_response(conn, 503)
        end

      assert [%{"error" => %{"code" => "service_unavailable"}}] = Enum.uniq(answers)
    end
  end

  defp signed_get(path) do
    Siwa.Contract.required_headers()
    |> Enum.reduce(build_conn(), &put_req_header(&2, &1, "signed"))
    |> get(path)
  end

  defp verified(fields) do
    data =
      Map.merge(
        %{
          "verified" => true,
          "walletAddress" => @wallet,
          "subject" => @subject,
          "agentRegistration" => nil,
          "agentBook" => nil
        },
        fields
      )

    StubClient.answer(
      {:ok, %{status: 200, body: %{"code" => "http_envelope_valid", "data" => data}}}
    )
  end

  defp refused(status, code), do: StubClient.answer(refusal(status, code))

  defp refusal(status, code),
    do:
      {:ok,
       %{
         status: status,
         body: %{"error" => %{"code" => code, "message" => "refused", "hint" => "hint"}}
       }}

  defp usage(new?), do: %{"activeThisPeriod" => true, "newThisPeriod" => new?}

  defp logged({:ok, %{body: %{"error" => %{"code" => code}}}}), do: code
  defp logged({:ok, %{status: _no_verdict}}), do: "siwa_request_failed"
  defp logged({:error, %Req.TransportError{reason: reason}}), do: Atom.to_string(reason)
end
