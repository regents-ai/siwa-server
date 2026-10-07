defmodule SiwaServerWeb.ActivityControllerTest do
  use SiwaServerWeb.ConnCase, async: false

  alias SiwaServer.AgentBook.Acceptance
  alias SiwaServer.AgentRegistration.Record
  alias SiwaServer.Repo
  alias SiwaServer.Siwa.ActivityStore

  @wallet "0x1111111111111111111111111111111111111111"
  @other "0x2222222222222222222222222222222222222222"
  @token "siwa-test-regents-activity-read-key-01"
  @patchbay_token "siwa-test-patchbay-activity-read-key-1"

  test "a Regents site reads one wallet's verified requests, newest first" do
    :ok = ActivityStore.record(@wallet, "regents", "get", "/api/agents/v1/me")
    :ok = ActivityStore.record(@wallet, "autolaunch", "POST", "/v1/agent/launches?draft=1")
    :ok = ActivityStore.record(@other, "techtree", "POST", "/v1/runs")

    assert %{"activity" => activity, "agentRegistration" => nil, "agentBook" => nil} =
             read(%{
               "wallet_address" => String.upcase(@wallet) |> String.replace("0X", "0x"),
               "since" => an_hour_ago()
             })
             |> json_response(200)
             |> Map.fetch!("data")

    assert [
             %{"audience" => "autolaunch", "method" => "POST", "path" => "/v1/agent/launches"},
             %{"audience" => "regents", "method" => "GET", "path" => "/api/agents/v1/me"}
           ] = activity

    assert Enum.all?(activity, &(Map.keys(&1) == ~w(audience method occurred_at path)))
    assert {:ok, _at, 0} = DateTime.from_iso8601(hd(activity)["occurred_at"])
  end

  test "names the wallet's agent registry listing so the site can link to it" do
    Repo.insert!(
      Record.changeset(%{
        profile_id: String.duplicate("c0", 16),
        wallet_address: @wallet,
        name: "Astra",
        description: "Finds bugs in Elixir code.",
        token_id: "97609",
        tx_hash: "0x" <> String.duplicate("ab", 32)
      })
    )

    assert %{
             "agentId" => "eip155:8453:0x8004a169fb4a3325136eb29fa0ceb6d2e539a432:97609",
             "tokenId" => "97609",
             "profileUrl" => profile_url,
             "registryUrl" => "https://www.8004scan.io/agents/base/97609"
           } =
             read(%{"wallet_address" => @wallet, "since" => an_hour_ago()})
             |> json_response(200)
             |> get_in(["data", "agentRegistration"])

    assert String.ends_with?(profile_url, "/agent-profiles/" <> String.duplicate("c0", 16))
  end

  test "names the World ID-verified person the wallet accepted" do
    human_id = "0x" <> String.duplicate("24", 32)
    Repo.insert!(Acceptance.changeset(%{wallet_address: @wallet, human_id: human_id}))

    assert %{"humanId" => ^human_id, "agentCount" => 1} =
             read(%{"wallet_address" => @wallet, "since" => an_hour_ago()})
             |> json_response(200)
             |> get_in(["data", "agentBook"])
  end

  test "reads 20 at a time, newest first, and the next cursor reads the rest" do
    for n <- 1..25, do: :ok = ActivityStore.record(@wallet, "regents", "GET", "/r/#{n}")

    assert %{"activity" => first, "next" => next} =
             read(%{"wallet_address" => @wallet, "since" => an_hour_ago()})
             |> json_response(200)
             |> Map.fetch!("data")

    assert %{"activity" => rest, "next" => nil} =
             read(%{"wallet_address" => @wallet, "since" => an_hour_ago(), "after" => next})
             |> json_response(200)
             |> Map.fetch!("data")

    assert Enum.map(first ++ rest, & &1["path"]) == Enum.map(25..1//-1, &"/r/#{&1}")
  end

  test "only requests at or after since are read" do
    :ok = ActivityStore.record(@wallet, "regents", "GET", "/api/agents/v1/me")
    later = DateTime.utc_now() |> DateTime.add(1) |> DateTime.to_iso8601()

    assert %{"data" => %{"activity" => []}} =
             read(%{"wallet_address" => @wallet, "since" => later}) |> json_response(200)
  end

  test "each read is counted under the site whose key it presented" do
    ref = :telemetry_test.attach_event_handlers(self(), [[:siwa_server, :siwa, :activity, :read]])
    body = %{"wallet_address" => @wallet, "since" => an_hour_ago()}

    assert read(body) |> json_response(200)
    assert read(body, "Bearer " <> @patchbay_token) |> json_response(200)
    assert read(body, "Bearer not-a-site-key") |> json_response(401)

    for reader <- ["regents", "patchbay", "refused"] do
      assert_received {[:siwa_server, :siwa, :activity, :read], ^ref, %{}, %{reader: ^reader}}
    end
  end

  test "a missing or wrong token is refused" do
    body = %{"wallet_address" => @wallet, "since" => an_hour_ago()}

    assert %{"error" => %{"code" => "activity_read_unauthorized"}} =
             read(body, nil) |> json_response(401)

    assert read(body, "Bearer not-the-token") |> json_response(401)
    assert read(body, @token) |> json_response(401)
  end

  test "a malformed request is refused" do
    for body <- [
          %{"wallet_address" => "0x12", "since" => an_hour_ago()},
          %{"wallet_address" => @wallet, "since" => "yesterday"},
          %{"wallet_address" => @wallet},
          %{"wallet_address" => @wallet, "since" => an_hour_ago(), "limit" => 5},
          %{"wallet_address" => @wallet, "since" => an_hour_ago(), "after" => "not-a-cursor"},
          %{"wallet_address" => @wallet, "since" => an_hour_ago(), "after" => nil}
        ] do
      assert %{"error" => %{"code" => "invalid_activity_request"}} =
               read(body) |> json_response(400)
    end
  end

  test "cleanup removes entries older than 30 days" do
    :ok = ActivityStore.record(@wallet, "regents", "GET", "/api/agents/v1/me")

    assert {:ok, 0} = ActivityStore.cleanup_expired(DateTime.utc_now())
    assert {:ok, 1} = ActivityStore.cleanup_expired(DateTime.add(DateTime.utc_now(), 31, :day))
    assert ActivityStore.page(@wallet, ~U[2026-01-01 00:00:00Z], nil) == {:ok, [], nil}
  end

  defp an_hour_ago, do: DateTime.utc_now() |> DateTime.add(-3_600) |> DateTime.to_iso8601()

  defp read(body, authorization \\ "Bearer " <> @token) do
    conn = put_req_header(build_conn(), "content-type", "application/json")

    conn =
      if authorization,
        do: put_req_header(conn, "authorization", authorization),
        else: conn

    post(conn, "/api/shared/siwa/activity", Jason.encode!(body))
  end
end
