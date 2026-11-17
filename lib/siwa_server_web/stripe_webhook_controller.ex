defmodule SiwaServerWeb.StripeWebhookController do
  @moduledoc """
  Takes Stripe's notices (`POST /api/stripe/webhook`): checks the signature
  over the body as received, records the notice once and queues what acts on
  it (`SiwaServer.Billing.Notice`), and answers at once. A notice Stripe sends
  again is answered the same and does nothing.
  """

  use SiwaServerWeb, :controller

  alias SiwaServer.Billing.Notice
  alias SiwaServerWeb.ErrorJSON

  def notice(conn, _params) do
    signed =
      Notice.verify(
        conn.private[:raw_body],
        get_req_header(conn, "stripe-signature"),
        conn.assigns.stripe.webhook_secret,
        System.os_time(:second)
      )

    case signed do
      :ok ->
        {:ok, _outcome} = Notice.record(conn.body_params)
        json(conn, %{"code" => "notice_received"})

      :error ->
        conn
        |> put_status(:bad_request)
        |> json(
          ErrorJSON.refusal(
            conn,
            "stripe_signature_invalid",
            "the Stripe-Signature header does not sign this body"
          )
        )
    end
  end
end
