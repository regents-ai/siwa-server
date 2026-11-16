defmodule Mix.Tasks.SiwaServer.StripeSetup do
  @moduledoc """
  Finds or makes the Stripe meter and price SIWA bills on
  (`SiwaServer.Billing.StripeSetup`), in the account `STRIPE_SECRET_KEY` opens
  (or, off production, `STRIPE_TEST_KEY_FILE`), and prints the two settings
  billing needs from it. Running it again changes nothing.

      mix siwa_server.stripe_setup
  """

  use Mix.Task

  alias SiwaServer.Billing.StripeSetup

  @shortdoc "Finds or makes the Stripe meter and price SIWA bills on"
  @requirements ["app.config"]

  @impl Mix.Task
  def run(_args) do
    if is_nil(SiwaServer.Config.stripe_secret_key()),
      do: Mix.raise("Set STRIPE_SECRET_KEY, or off production STRIPE_TEST_KEY_FILE, first.")

    {:ok, _started} = Application.ensure_all_started(:req)

    case StripeSetup.run() do
      {:ok, setup} ->
        Mix.shell().info("""
        meter   #{setup.meter_id}
        product #{setup.product_id}

        STRIPE_PRICE_ID=#{setup.price_id}
        STRIPE_METER_EVENT_NAME=#{setup.event_name}
        """)

      {:error, {reason, message}} ->
        Mix.raise("Stripe setup stopped: #{reason} #{message}")
    end
  end
end
