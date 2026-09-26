defmodule SiwaServerWeb.ActivityControllerTest do
  use SiwaServerWeb.ConnCase, async: false

  alias SiwaServer.Siwa.ActivityStore

  @wallet "0x1111111111111111111111111111111111111111"
  @other "0x2222222222222222222222222222222222222222"
  @token "siwa-server-test-activity-read-token"

  test "a Regents site reads one wallet's verified requests, newest first" do
    :ok = ActivityStore.record(@wallet, "regents", "get", "/api/agents/v1/me")
    :ok = ActivityStore.record(@wallet, "autolaunch", "POST", "/v1/agent/launches?draft=1")
    :ok = ActivityStore.record(@other, "techtree", "POST", "/v1/runs")

    activity =
      read(%{
        "wallet_address" => String.upcase(@wallet) |> String.replace("0X", "0x"),
        "since" => an_hour_ago()
      })
      |> json_response(200)
      |> get_in(["data", "activity"])

    assert [
             %{"audience" => "autolaunch", "method" => "POST", "path" => "/v1/agent/launches"},
             %{"audience" => "regents", "method" => "GET", "path" => "/api/agents/v1/me"}
           ] = activity

    assert Enum.all?(activity, &(Map.keys(&1) == ~w(audience method occurred_at path)))
    assert {:ok, _at, 0} = DateTime.from_iso8601(hd(activity)["occurred_at"])
  end

  test "only requests at or after since are read" do
    :ok = ActivityStore.record(@wallet, "regents", "GET", "/api/agents/v1/me")
    later = DateTime.utc_now() |> DateTime.add(1) |> DateTime.to_iso8601()

    assert %{"data" => %{"activity" => []}} =
             read(%{"wallet_address" => @wallet, "since" => later}) |> json_response(200)
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
          %{"wallet_address" => @wallet, "since" => an_hour_ago(), "limit" => 5}
        ] do
      assert %{"error" => %{"code" => "invalid_activity_request"}} =
               read(body) |> json_response(400)
    end
  end

  test "cleanup removes entries older than 30 days" do
    :ok = ActivityStore.record(@wallet, "regents", "GET", "/api/agents/v1/me")

    assert {:ok, 0} = ActivityStore.cleanup_expired(DateTime.utc_now())
    assert {:ok, 1} = ActivityStore.cleanup_expired(DateTime.add(DateTime.utc_now(), 31, :day))
    assert ActivityStore.recent(@wallet, ~U[2026-01-01 00:00:00Z]) == []
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
