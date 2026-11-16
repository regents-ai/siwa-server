defmodule SiwaServer.Billing.Subscription do
  @moduledoc """
  A paid customer's subscription through Stripe: subscribing on a Stripe
  Checkout page, managing it on Stripe's billing page, and taking in what
  Stripe says it now is (`sync/2`).

  A customer gets one Stripe customer, made the first time it subscribes and
  named for the company, with its SIWA id and nothing about any person. A person
  comes back from either page only to a page on one of `SIWA_PORTAL_ORIGINS`.

  `sync/2` reads the subscription from Stripe rather than trusting a notice, so
  a late or repeated notice only reads it again. The read is stamped with the
  database clock before it is made, and a read older than the last one taken in
  is dropped, so two syncs racing on two machines leave the newer. A customer
  keeps the subscription it has while that one is running; a second running one
  is reported to operators and not taken in.
  """

  import Ecto.Changeset
  import Ecto.Query

  require Logger

  alias SiwaServer.Billing
  alias SiwaServer.Billing.Stripe
  alias SiwaServer.Customers.Customer
  alias SiwaServer.Repo

  @type refusal :: {:error, {pos_integer(), String.t(), String.t()} | Ecto.Changeset.t()}

  @doc """
  The `returnUrl` a person goes back to from Stripe: an `https://` address on
  one of `origins`, its origin written exactly as the setting writes it.
  """
  @spec return_url(map(), [String.t()]) :: {:ok, String.t()} | refusal()
  def return_url(params, origins) do
    {%{}, %{returnUrl: :string}}
    |> cast(params, [:returnUrl])
    |> validate_required([:returnUrl])
    |> validate_length(:returnUrl, max: 2_048)
    |> validate_change(:returnUrl, fn :returnUrl, url ->
      if returns_to?(url, origins),
        do: [],
        else: [returnUrl: "must be an https address on a page this service returns people to"]
    end)
    |> apply_action(:create)
    |> case do
      {:ok, %{returnUrl: url}} -> {:ok, url}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp returns_to?(url, origins) do
    case URI.new(url) do
      {:ok, %URI{scheme: "https", userinfo: nil, host: host, port: 443}} when is_binary(host) ->
        ("https://" <> host) in origins

      _other ->
        false
    end
  end

  @doc """
  A Stripe Checkout page that subscribes the customer to `price_id`, making its
  Stripe customer first if it has none.
  """
  @spec checkout(Customer.t(), String.t(), String.t()) :: {:ok, String.t()} | refusal()
  def checkout(%Customer{kind: :internal}, _return_url, _price_id),
    do: {:error, {409, "billing_not_needed", "this customer is not billed"}}

  def checkout(%Customer{} = customer, return_url, price_id) do
    if customer.subscription_status in Billing.working_statuses() do
      {:error, {409, "subscription_exists", "this customer's subscription is already running"}}
    else
      with {:ok, stripe_customer_id} <- stripe_customer(customer),
           {:ok, %{"url" => url}} <-
             customer.id
             |> Stripe.create_checkout_session(stripe_customer_id, price_id, return_url)
             |> provider() do
        {:ok, url}
      end
    end
  end

  @doc "Stripe's billing page for the customer, where it changes its card or cancels."
  @spec portal(Customer.t(), String.t()) :: {:ok, String.t()} | refusal()
  def portal(%Customer{stripe_customer_id: nil}, _return_url),
    do: {:error, {409, "billing_not_started", "this customer has not subscribed yet"}}

  def portal(%Customer{stripe_customer_id: stripe_customer_id}, return_url) do
    with {:ok, %{"url" => url}} <-
           provider(Stripe.create_portal_session(stripe_customer_id, return_url)),
         do: {:ok, url}
  end

  # Stripe makes one customer for two requests with the same idempotency key, and
  # the first id stored is the one kept.
  defp stripe_customer(%Customer{stripe_customer_id: id}) when is_binary(id), do: {:ok, id}

  defp stripe_customer(customer) do
    with {:ok, %{"id" => id}} <- provider(Stripe.create_customer(customer.id, customer.name)) do
      Repo.update_all(
        from(c in Customer, where: c.id == ^customer.id and is_nil(c.stripe_customer_id)),
        set: [stripe_customer_id: id]
      )

      {:ok,
       Repo.one!(from c in Customer, where: c.id == ^customer.id, select: c.stripe_customer_id)}
    end
  end

  @doc "A Stripe failure as the control API answers it; the failure itself goes to the log."
  @spec provider(Stripe.answer()) :: Stripe.answer() | refusal()
  def provider({:ok, _object} = answer), do: answer

  def provider({:error, {status, message}}) do
    Logger.warning("stripe request failed status=#{status} message=#{inspect(message)}")

    {:error,
     {502, "billing_provider_failed",
      "the billing provider could not do this just now; try again"}}
  end

  @doc """
  Takes in the subscription `subscription_id` as Stripe has it now: its status
  and, while it is running, the period of its item on `price_id`
  (`SiwaServer.Billing.put_period/3`). A subscription of no customer here is
  left alone.
  """
  @spec sync(String.t(), String.t()) :: {:ok, atom()} | Stripe.error()
  def sync(subscription_id, price_id) do
    %{rows: [[fetched_at]]} = Repo.query!("SELECT clock_timestamp()")

    with {:ok, subscription} <- Stripe.get_subscription(subscription_id) do
      Repo.transact(fn -> take_in(subscription, price_id, fetched_at) end)
    end
  end

  defp take_in(
         %{"id" => id, "customer" => stripe_customer_id} = subscription,
         price_id,
         fetched_at
       ) do
    customer =
      Repo.one(
        from c in Customer, where: c.stripe_customer_id == ^stripe_customer_id, lock: "FOR UPDATE"
      )

    cond do
      is_nil(customer) ->
        {:ok, :not_ours}

      customer.stripe_synced_at && DateTime.compare(fetched_at, customer.stripe_synced_at) != :gt ->
        {:ok, :older}

      keeps_its_own?(customer, id, subscription["status"]) ->
        {:ok, :kept}

      true ->
        adopt(customer, subscription, price_id, fetched_at)
    end
  end

  defp keeps_its_own?(%Customer{stripe_subscription_id: stored}, id, _status)
       when stored in [nil, id],
       do: false

  defp keeps_its_own?(customer, id, status) do
    running = Billing.working_statuses()

    cond do
      customer.subscription_status not in running ->
        false

      status in running ->
        Logger.error(
          "billing check failed check=subscription customer=#{customer.id} " <>
            "kept=#{customer.stripe_subscription_id} also_running=#{id}"
        )

        :telemetry.execute([:siwa_server, :billing, :check_failed], %{}, %{check: "subscription"})
        true

      true ->
        true
    end
  end

  defp adopt(customer, %{"id" => id, "status" => status} = subscription, price_id, fetched_at) do
    customer =
      customer
      |> change(
        stripe_subscription_id: id,
        subscription_status: status,
        stripe_synced_at: fetched_at
      )
      |> Repo.update!()

    if status in Billing.working_statuses() do
      %{"current_period_start" => starts_at, "current_period_end" => ends_at} =
        Enum.find(subscription["items"]["data"], &(&1["price"]["id"] == price_id))

      Billing.put_period(customer, unix(starts_at), unix(ends_at))
    end

    {:ok, :synced}
  end

  @doc "A unix time from Stripe as a database time."
  @spec unix(integer()) :: DateTime.t()
  def unix(seconds), do: DateTime.from_unix!(seconds * 1_000_000, :microsecond)
end
