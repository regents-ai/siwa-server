defmodule SiwaServerWeb.ControlBillingTest do
  use SiwaServerWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

  alias SiwaServer.{Customers, PrivySignIn, Repo, TestStripe}
  alias SiwaServer.Customers.Customer
  alias SiwaServerWeb.ControlToken

  @alice "did:privy:alice"
  @bob "did:privy:bob"
  @return "https://regents.example/billing?done=1"

  setup do
    PrivySignIn.configure()
    stripe()
    :ok
  end

  test "checkout makes the customer's Stripe customer once, by company name only, and answers its page" do
    customer(@alice, "Acme")

    assert %{"code" => "billing_checkout", "data" => %{"url" => url}} =
             call(@alice, :post, "/billing/checkout", %{"returnUrl" => @return})
             |> json_response(200)

    alice = Customers.customer(@alice)
    assert url == "https://checkout.stripe.com/c/pay/#{alice.stripe_customer_id}"
    assert_received {:stripe, :post, "/v1/customers", made}
    assert made == %{name: "Acme", metadata: %{siwa_customer_id: alice.id}}

    assert_received {:stripe, :post, "/v1/checkout/sessions",
                     %{
                       mode: "subscription",
                       customer: stripe_customer_id,
                       line_items: [%{price: "price_siwa_test"}],
                       success_url: @return,
                       cancel_url: @return
                     }}

    assert stripe_customer_id == alice.stripe_customer_id

    assert %{"data" => %{"url" => ^url}} =
             call(@alice, :post, "/billing/checkout", %{"returnUrl" => @return})
             |> json_response(200)

    refute_received {:stripe, :post, "/v1/customers", _params}
  end

  test "checkout is refused while the subscription runs, and for a customer that is not billed" do
    customer(@alice, "Acme")
    Repo.update_all(Customer, set: [subscription_status: "past_due"])

    assert %{"error" => %{"code" => "subscription_exists"}} =
             call(@alice, :post, "/billing/checkout", %{"returnUrl" => @return})
             |> json_response(409)

    Repo.insert!(%Customer{owner_did: @bob, name: "Regents", kind: :internal})

    assert %{"error" => %{"code" => "billing_not_needed"}} =
             call(@bob, :post, "/billing/checkout", %{"returnUrl" => @return})
             |> json_response(409)

    refute_received {:stripe, _method, _path, _params}
  end

  test "a person comes back only to an https page on a listed origin" do
    customer(@alice, "Acme")

    for url <- [
          "http://regents.example/billing",
          "https://evil.example/billing",
          "https://regents.example.evil.example/",
          "https://REGENTS.example/",
          "https://someone@regents.example/",
          "https://regents.example:8443/",
          "javascript:alert(1)",
          "regents.example/billing",
          "https://regents.example/" <> String.duplicate("a", 2_048),
          "",
          42
        ] do
      for path <- ["/billing/checkout", "/billing/portal"] do
        assert %{
                 "error" => %{
                   "code" => "control_fields_invalid",
                   "fields" => %{"returnUrl" => [_]}
                 }
               } =
                 call(@alice, :post, path, %{"returnUrl" => url}) |> json_response(422)
      end
    end

    assert %{"error" => %{"fields" => %{"returnUrl" => [_]}}} =
             call(@alice, :post, "/billing/checkout", %{}) |> json_response(422)

    assert %{"error" => %{"code" => "control_request_invalid"}} =
             call(@alice, :post, "/billing/checkout", %{"returnUrl" => @return, "price" => "p"})
             |> json_response(400)

    refute_received {:stripe, _method, _path, _params}
  end

  test "the billing page opens for the person's own Stripe customer once it has one" do
    customer(@alice, "Acme")

    assert %{"error" => %{"code" => "billing_not_started"}} =
             call(@alice, :post, "/billing/portal", %{"returnUrl" => @return})
             |> json_response(409)

    Repo.update_all(Customer, set: [stripe_customer_id: "cus_alice"])

    assert %{
             "code" => "billing_portal",
             "data" => %{"url" => "https://billing.stripe.com/p/cus_alice"}
           } =
             call(@alice, :post, "/billing/portal", %{"returnUrl" => @return})
             |> json_response(200)

    assert_received {:stripe, :post, "/v1/billing_portal/sessions",
                     %{customer: "cus_alice", return_url: @return}}

    customer(@bob, "Bobco")

    assert %{"error" => %{"code" => "billing_not_started"}} =
             call(@bob, :post, "/billing/portal", %{"returnUrl" => @return})
             |> json_response(409)

    refute_received {:stripe, _method, _path, _params}
  end

  test "invoices are read from Stripe for the person's own customer only" do
    customer(@alice, "Acme")
    customer(@bob, "Bobco")

    Repo.update_all(from(c in Customer, where: c.owner_did == @alice),
      set: [stripe_customer_id: "cus_alice"]
    )

    assert %{"code" => "invoices", "data" => %{"invoices" => [], "next" => nil}} =
             call(@bob, :get, "/billing/invoices") |> json_response(200)

    refute_received {:stripe, _method, _path, _params}

    assert %{"data" => %{"invoices" => [invoice], "next" => "in_alice"}} =
             call(@alice, :get, "/billing/invoices?limit=1") |> json_response(200)

    assert invoice == %{
             "id" => "in_alice",
             "createdAt" => "2026-11-01T10:01:00.000000Z",
             "periodStartsAt" => "2026-10-01T10:00:00.000000Z",
             "periodEndsAt" => "2026-11-01T10:00:00.000000Z",
             "totalCents" => 24_750,
             "status" => "paid",
             "hostedUrl" => "https://invoice.stripe.com/i/cus_alice",
             "agents" => 2_500
           }

    assert_received {:stripe, :get, "/v1/invoices",
                     %{customer: "cus_alice", limit: 1, starting_after: nil}}

    Repo.update_all(from(c in Customer, where: c.owner_did == @bob),
      set: [stripe_customer_id: "cus_bob"]
    )

    assert %{"data" => %{"invoices" => [%{"id" => "in_bob"}]}} =
             call(@bob, :get, "/billing/invoices?after=in_alice") |> json_response(200)

    assert_received {:stripe, :get, "/v1/invoices",
                     %{customer: "cus_bob", starting_after: "in_alice"}}

    for query <- [
          "limit=0",
          "limit=51",
          "after=cus_alice",
          "after=in_x_y",
          "after=in_x%26customer%3Dcus_alice"
        ] do
      assert %{"error" => %{"code" => "control_fields_invalid"}} =
               call(@alice, :get, "/billing/invoices?" <> query) |> json_response(422)
    end

    assert %{"error" => %{"code" => "customer_not_found"}} =
             call("did:privy:nobody", :get, "/billing/invoices") |> json_response(404)
  end

  test "invoices are read at most so often for each customer" do
    customer(@alice, "Acme")
    rate_limits = Application.get_env(:siwa_server, :rate_limits, [])
    on_exit(fn -> Application.put_env(:siwa_server, :rate_limits, rate_limits) end)
    Application.put_env(:siwa_server, :rate_limits, siwa_billing_invoices: [limit: 2])

    for _read <- 1..2, do: call(@alice, :get, "/billing/invoices") |> json_response(200)

    assert %{"error" => %{"code" => "rate_limited"}} =
             call(@alice, :get, "/billing/invoices") |> json_response(429)
  end

  test "the account says whether billing runs and the subscription's status" do
    customer(@alice, "Acme")

    assert %{"data" => %{"billing" => %{"configured" => true, "subscriptionStatus" => nil}}} =
             call(@alice, :get, "/account") |> json_response(200)

    Repo.update_all(Customer, set: [subscription_status: "active"])

    assert %{"data" => %{"billing" => %{"subscriptionStatus" => "active"}}} =
             call(@alice, :get, "/account") |> json_response(200)
  end

  test "without its Stripe settings every billing route answers 503 and the rest still runs" do
    customer(@alice, "Acme")
    stripe = Application.fetch_env!(:siwa_server, :stripe)
    on_exit(fn -> Application.put_env(:siwa_server, :stripe, stripe) end)
    Application.put_env(:siwa_server, :stripe, Keyword.put(stripe, :price_id, nil))

    for {method, path} <- [
          post: "/billing/checkout",
          post: "/billing/portal",
          get: "/billing/invoices"
        ] do
      assert %{"error" => %{"code" => "billing_not_configured"}} =
               call(@alice, method, path, %{"returnUrl" => @return}) |> json_response(503)
    end

    assert %{"error" => %{"code" => "billing_not_configured"}} =
             build_conn()
             |> put_req_header("content-type", "application/json")
             |> post("/api/stripe/webhook", "{}")
             |> json_response(503)

    assert %{"data" => %{"billing" => %{"configured" => false}}} =
             call(@alice, :get, "/account") |> json_response(200)

    refute_received {:stripe, _method, _path, _params}
  end

  defp customer(did, name),
    do: call(did, :post, "/customer", %{"name" => name}) |> json_response(201)

  defp call(did, method, path, body \\ nil) do
    {token, _expires_at} = ControlToken.issue(did)

    build_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", "application/json")
    |> dispatch(@endpoint, method, "/api/control/v1" <> path, body && Jason.encode!(body))
  end

  # Stripe as it answers each call billing makes from the control API.
  defp stripe do
    TestStripe.answer(fn
      :post, "/v1/customers", %{metadata: %{siwa_customer_id: id}} ->
        {:ok, %{"id" => "cus_" <> String.slice(id, 0, 8)}}

      :post, "/v1/checkout/sessions", %{customer: customer} ->
        {:ok, %{"url" => "https://checkout.stripe.com/c/pay/" <> customer}}

      :post, "/v1/billing_portal/sessions", %{customer: customer} ->
        {:ok, %{"url" => "https://billing.stripe.com/p/" <> customer}}

      :get, "/v1/invoices", %{customer: customer} ->
        {:ok, %{"data" => [invoice(customer)], "has_more" => true}}
    end)
  end

  defp invoice("cus_" <> name = customer) do
    %{
      "id" => "in_" <> name,
      "created" => DateTime.to_unix(~U[2026-11-01 10:01:00Z]),
      "period_start" => DateTime.to_unix(~U[2026-10-01 10:00:00Z]),
      "period_end" => DateTime.to_unix(~U[2026-11-01 10:00:00Z]),
      "total" => 24_750,
      "status" => "paid",
      "hosted_invoice_url" => "https://invoice.stripe.com/i/" <> customer,
      "lines" => %{
        "data" => [
          %{"quantity_decimal" => "1000", "pricing" => %{"unit_amount_decimal" => "0"}},
          %{"quantity_decimal" => "0", "pricing" => %{"unit_amount_decimal" => nil}},
          %{"quantity_decimal" => "1500", "pricing" => %{"unit_amount_decimal" => "9.9"}}
        ]
      }
    }
  end
end
