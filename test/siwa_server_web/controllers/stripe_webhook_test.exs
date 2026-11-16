defmodule SiwaServerWeb.StripeWebhookTest do
  use SiwaServerWeb.ConnCase, async: true
  use Oban.Testing, repo: SiwaServer.Repo

  alias SiwaServer.Billing.{Notice, NoticeWorker}
  alias SiwaServer.Repo

  @secret "whsec_siwa_stand_in"

  test "a signed notice is recorded once and queues one job; sent again it does nothing" do
    body =
      notice("evt_1", "customer.subscription.updated", %{
        "object" => "subscription",
        "id" => "sub_1"
      })

    assert %{"code" => "notice_received"} = deliver(body, signed(body)) |> json_response(200)

    assert_enqueued(
      worker: NoticeWorker,
      args: %{kind: "subscription", object_id: "sub_1", event_id: "evt_1"}
    )

    assert %{"code" => "notice_received"} = deliver(body, signed(body)) |> json_response(200)
    assert [_one] = all_enqueued(worker: NoticeWorker)
    assert [["evt_1"]] = Repo.query!("SELECT id FROM stripe_events WHERE id = 'evt_1'").rows
  end

  test "the signature is checked over the body exactly as Stripe sent it" do
    # Spacing no JSON encoder would write again: only the bytes received verify.
    body =
      ~s({ "id":"evt_2",  "type":"invoice.created", "data":{"object":{"object":"invoice","id":"in_2"}} })

    assert deliver(body, signed(body)) |> json_response(200)
    assert_enqueued(worker: NoticeWorker, args: %{kind: "invoice_created", object_id: "in_2"})
  end

  test "a completed checkout names the subscription to read" do
    body =
      notice("evt_3", "checkout.session.completed", %{
        "object" => "checkout.session",
        "id" => "cs_3",
        "subscription" => "sub_3"
      })

    assert deliver(body, signed(body)) |> json_response(200)
    assert_enqueued(worker: NoticeWorker, args: %{kind: "subscription", object_id: "sub_3"})
  end

  test "a wrong, stale, early, malformed or missing signature is refused and records nothing" do
    body = notice("evt_4", "invoice.finalized", %{"object" => "invoice", "id" => "in_4"})
    now = System.os_time(:second)

    for header <- [
          signed(body, now, "whsec_someone_else"),
          signed(body, now - 301),
          signed(body, now + 301),
          signed(body <> " ", now),
          "t=#{now}",
          "v1=" <> Notice.signature(body, now, @secret),
          "t=soon,v1=" <> Notice.signature(body, now, @secret),
          "t=#{now},v0=" <> Notice.signature(body, now, @secret),
          nil
        ] do
      assert %{"error" => %{"code" => "stripe_signature_invalid"}} =
               deliver(body, header) |> json_response(400)
    end

    refute_enqueued(worker: NoticeWorker)
    assert [] = Repo.query!("SELECT id FROM stripe_events WHERE id = 'evt_4'").rows
  end

  test "a signature among several passes, as when Stripe rolls its secret" do
    body = notice("evt_5", "invoice.finalized", %{"object" => "invoice", "id" => "in_5"})
    now = System.os_time(:second)

    header =
      "t=#{now},v1=#{Notice.signature(body, now, "whsec_old")},v1=#{Notice.signature(body, now, @secret)}"

    assert deliver(body, header) |> json_response(200)
  end

  test "a notice billing does not act on is answered and kept nowhere" do
    body = notice("evt_6", "invoice.paid", %{"object" => "invoice", "id" => "in_6"})

    assert deliver(body, signed(body)) |> json_response(200)
    refute_enqueued(worker: NoticeWorker)
    assert [] = Repo.query!("SELECT id FROM stripe_events WHERE id = 'evt_6'").rows
  end

  defp notice(id, type, object),
    do:
      Jason.encode!(%{
        "id" => id,
        "object" => "event",
        "type" => type,
        "data" => %{"object" => object}
      })

  defp signed(body, at \\ System.os_time(:second), secret \\ @secret),
    do: "t=#{at},v1=#{Notice.signature(body, at, secret)}"

  defp deliver(body, header) do
    conn = put_req_header(build_conn(), "content-type", "application/json")
    conn = if header, do: put_req_header(conn, "stripe-signature", header), else: conn
    post(conn, "/api/stripe/webhook", body)
  end
end
