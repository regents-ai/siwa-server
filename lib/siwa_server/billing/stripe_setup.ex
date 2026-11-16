defmodule SiwaServer.Billing.StripeSetup do
  @moduledoc """
  Finds or makes, in the Stripe account the secret key opens, the meter and the
  price SIWA bills on (`mix siwa_server.stripe_setup`). Running it again finds
  what it made: the meter by its event name, the price by its lookup key.

  The meter keeps each customer's last reported value (`last`): the count of
  agents so far this period (`SiwaServer.Billing.ReportWorker`). The price is
  monthly, metered on that meter and graduated: $99 covers the first 1,000
  agents and each agent after adds 9.9 cents, Price v1
  (`SiwaServer.Billing.Price`).

  A meter or price found with the right name but different terms is reported,
  never changed.
  """

  alias SiwaServer.Billing.Stripe

  @event_name "siwa_active_agents"
  @lookup_key "siwa_active_agents_monthly_v1"
  @tiers [{1_000, 9_900, "0"}, {nil, nil, "9.9"}]

  @type setup :: %{
          meter_id: String.t(),
          event_name: String.t(),
          price_id: String.t(),
          product_id: String.t()
        }

  @doc "The meter event name usage is reported under."
  @spec event_name() :: String.t()
  def event_name, do: @event_name

  @doc """
  Finds or makes the meter and price. `metadata:` is put on the product and
  price it makes.
  """
  @spec run(keyword()) :: {:ok, setup()} | {:error, {pos_integer() | atom(), String.t()}}
  def run(opts \\ []) do
    metadata = Keyword.get(opts, :metadata, %{})

    with {:ok, meter} <- meter(),
         {:ok, price} <- price(meter["id"], metadata) do
      {:ok,
       %{
         meter_id: meter["id"],
         event_name: @event_name,
         price_id: price["id"],
         product_id: price["product"]
       }}
    end
  end

  defp meter do
    with {:ok, meters} <- all("/v1/billing/meters", %{status: "active"}) do
      case Enum.find(meters, &(&1["event_name"] == @event_name)) do
        nil ->
          Stripe.call(:post, "/v1/billing/meters", %{
            display_name: "SIWA active agents",
            event_name: @event_name,
            default_aggregation: %{formula: "last"},
            customer_mapping: %{type: "by_id", event_payload_key: "stripe_customer_id"},
            value_settings: %{event_payload_key: "value"}
          })

        %{"default_aggregation" => %{"formula" => "last"}} = meter ->
          {:ok, meter}

        meter ->
          {:error, {:different_terms, "meter #{meter["id"]} does not keep the last value"}}
      end
    end
  end

  defp price(meter_id, metadata) do
    with {:ok, %{"data" => found}} <-
           Stripe.call(:get, "/v1/prices", %{
             lookup_keys: [@lookup_key],
             active: true,
             expand: ["data.tiers"]
           }) do
      case found do
        [] -> create_price(meter_id, metadata)
        [price] -> same_terms(price, meter_id)
      end
    end
  end

  defp create_price(meter_id, metadata) do
    Stripe.call(:post, "/v1/prices", %{
      currency: "usd",
      lookup_key: @lookup_key,
      nickname: "SIWA active agents, monthly",
      billing_scheme: "tiered",
      tiers_mode: "graduated",
      tiers: [
        %{up_to: 1_000, flat_amount: 9_900, unit_amount: 0},
        %{up_to: "inf", unit_amount_decimal: "9.9"}
      ],
      recurring: %{interval: "month", usage_type: "metered", meter: meter_id},
      product_data: %{name: "SIWA agents", metadata: metadata},
      metadata: metadata
    })
  end

  defp same_terms(price, meter_id) do
    terms = %{
      currency: price["currency"],
      tiers_mode: price["tiers_mode"],
      recurring: Map.take(price["recurring"] || %{}, ~w(interval usage_type meter)),
      tiers:
        Enum.map(price["tiers"], &{&1["up_to"], &1["flat_amount"], &1["unit_amount_decimal"]})
    }

    expected = %{
      currency: "usd",
      tiers_mode: "graduated",
      recurring: %{"interval" => "month", "usage_type" => "metered", "meter" => meter_id},
      tiers: @tiers
    }

    if terms == expected,
      do: {:ok, price},
      else:
        {:error, {:different_terms, "price #{price["id"]} is not Price v1 on meter #{meter_id}"}}
  end

  # Every object a list route has, a page of 100 at a time.
  defp all(path, params, starting_after \\ nil, found \\ []) do
    with {:ok, %{"data" => page, "has_more" => more}} <-
           Stripe.call(
             :get,
             path,
             Map.merge(params, %{limit: 100, starting_after: starting_after})
           ) do
      found = found ++ page

      if more,
        do: all(path, params, List.last(page)["id"], found),
        else: {:ok, found}
    end
  end
end
