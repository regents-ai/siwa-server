defmodule SiwaServer.Billing.Stripe do
  @moduledoc """
  The few Stripe API calls billing makes, form-encoded, on one pinned
  `Stripe-Version`, with the secret key from `SiwaServer.Config.stripe_secret_key/0`.

  An answer is the decoded JSON object, or `{:error, {status, message}}`: Stripe's
  HTTP status and its message, or `:unreachable` and why. Nothing is retried here;
  the Oban job that called retries. Every error's text has the key and any key-shaped
  text taken out before it leaves this module.
  """

  alias SiwaServer.Config

  @api "https://api.stripe.com"
  @version "2026-10-28.endive"
  @receive_timeout_ms 15_000
  @connect_timeout_ms 5_000
  @key_shape ~r/\b(sk|rk|pk|whsec)_(test_|live_)?[A-Za-z0-9*._]+/

  @type error :: {:error, {pos_integer() | :unreachable, String.t()}}
  @type answer :: {:ok, map()} | error()

  @doc "The Stripe API version every call is made on."
  @spec version() :: String.t()
  def version, do: @version

  @doc """
  Makes a Stripe customer for a SIWA customer: its company name and its id, and
  nothing about any person. The idempotency key makes two requests at once make one.
  """
  @spec create_customer(String.t(), String.t()) :: answer()
  def create_customer(siwa_customer_id, name) do
    call(:post, "/v1/customers", %{name: name, metadata: %{siwa_customer_id: siwa_customer_id}},
      idempotency_key: "siwa-customer-#{siwa_customer_id}"
    )
  end

  @doc "A Checkout page that subscribes `stripe_customer_id` to `price_id`, returning to `return_url`."
  @spec create_checkout_session(String.t(), String.t(), String.t(), String.t()) :: answer()
  def create_checkout_session(siwa_customer_id, stripe_customer_id, price_id, return_url) do
    call(:post, "/v1/checkout/sessions", %{
      mode: "subscription",
      customer: stripe_customer_id,
      client_reference_id: siwa_customer_id,
      line_items: [%{price: price_id}],
      success_url: return_url,
      cancel_url: return_url,
      metadata: %{siwa_customer_id: siwa_customer_id},
      subscription_data: %{metadata: %{siwa_customer_id: siwa_customer_id}}
    })
  end

  @doc "A billing portal page for `stripe_customer_id`, returning to `return_url`."
  @spec create_portal_session(String.t(), String.t()) :: answer()
  def create_portal_session(stripe_customer_id, return_url),
    do:
      call(:post, "/v1/billing_portal/sessions", %{
        customer: stripe_customer_id,
        return_url: return_url
      })

  @spec get_subscription(String.t()) :: answer()
  def get_subscription(id), do: call(:get, "/v1/subscriptions/#{id}", %{})

  @spec get_invoice(String.t()) :: answer()
  def get_invoice(id), do: call(:get, "/v1/invoices/#{id}", %{})

  @doc "A page of the customer's invoices, newest first, after the invoice `starting_after` when given."
  @spec list_invoices(String.t(), pos_integer(), String.t() | nil) :: answer()
  def list_invoices(stripe_customer_id, limit, starting_after) do
    call(
      :get,
      "/v1/invoices",
      %{customer: stripe_customer_id, limit: limit, starting_after: starting_after}
    )
  end

  @doc "Stops Stripe finalising a draft invoice on its own."
  @spec hold_invoice(String.t()) :: answer()
  def hold_invoice(id), do: call(:post, "/v1/invoices/#{id}", %{auto_advance: false})

  @spec get_price(String.t()) :: answer()
  def get_price(id), do: call(:get, "/v1/prices/#{id}", %{})

  @doc """
  Sends one meter event: `value` for the Stripe customer at `timestamp` (unix
  seconds). Stripe keeps the first event with an `identifier` and refuses the
  rest; that refusal is `:ok` here, since the event it names was sent.
  """
  @spec send_meter_event(String.t(), String.t(), non_neg_integer(), String.t(), integer()) ::
          :ok | error()
  def send_meter_event(event_name, stripe_customer_id, value, identifier, timestamp) do
    :post
    |> call("/v1/billing/meter_events", %{
      event_name: event_name,
      payload: %{stripe_customer_id: stripe_customer_id, value: value},
      identifier: identifier,
      timestamp: timestamp
    })
    |> case do
      {:ok, _event} ->
        :ok

      {:error, {400, message}} = refused ->
        if message =~ "already exists with identifier", do: :ok, else: refused

      refused ->
        refused
    end
  end

  @doc """
  The meter's value for the customer from `starts_at` to `ends_at` (unix seconds,
  each on a whole minute); 0 when no event falls in it.
  """
  @spec meter_value(String.t(), String.t(), integer(), integer()) :: {:ok, number()} | error()
  def meter_value(meter_id, stripe_customer_id, starts_at, ends_at) do
    with {:ok, %{"data" => summaries}} <-
           call(:get, "/v1/billing/meters/#{meter_id}/event_summaries", %{
             customer: stripe_customer_id,
             start_time: starts_at,
             end_time: ends_at
           }) do
      case summaries do
        [] -> {:ok, 0}
        [%{"aggregated_value" => value}] -> {:ok, value}
      end
    end
  end

  @doc "Makes a Stripe object, or reads or lists them: the general form setup and checks use."
  @spec call(:get | :post | :delete, String.t(), map(), keyword()) :: answer()
  def call(method, path, params, opts \\ []) do
    key = Config.stripe_secret_key()
    pairs = form_pairs(params)

    {url, body} =
      case method do
        :post -> {@api <> path, URI.encode_query(pairs)}
        _get_or_delete -> {url(path, pairs), nil}
      end

    headers =
      [
        {"authorization", "Bearer " <> key},
        {"stripe-version", @version},
        {"content-type", "application/x-www-form-urlencoded"}
      ] ++ idempotency(opts[:idempotency_key])

    [
      method: method,
      url: url,
      headers: headers,
      body: body,
      retry: false,
      receive_timeout: @receive_timeout_ms,
      connect_options: [timeout: @connect_timeout_ms]
    ]
    |> Req.request()
    |> answer(key)
  end

  defp answer({:ok, %Req.Response{status: status, body: %{} = body}}, _key)
       when status in 200..299,
       do: {:ok, body}

  defp answer({:ok, %Req.Response{status: status, body: body}}, key) do
    message =
      case body do
        %{"error" => %{"message" => message}} when is_binary(message) -> message
        _other -> "Stripe answered #{status}"
      end

    {:error, {status, scrub(message, key)}}
  end

  defp answer({:error, exception}, key),
    do: {:error, {:unreachable, scrub(Exception.message(exception), key)}}

  @doc "Takes the key, and anything shaped like a Stripe key or signing secret, out of `text`."
  @spec scrub(String.t(), String.t() | nil) :: String.t()
  def scrub(text, key) do
    text = if is_binary(key) and key != "", do: String.replace(text, key, "[key]"), else: text
    Regex.replace(@key_shape, text, "[key]")
  end

  defp url(path, []), do: @api <> path
  defp url(path, pairs), do: @api <> path <> "?" <> URI.encode_query(pairs)

  defp idempotency(nil), do: []
  defp idempotency(key), do: [{"idempotency-key", key}]

  @doc """
  `params` in Stripe's form encoding: a map's keys and a list's indexes in
  brackets after their parent (`line_items[0][price]`), nil left out.
  """
  @spec form_pairs(map()) :: [{String.t(), String.t()}]
  def form_pairs(params), do: params |> Enum.flat_map(&pairs(&1, nil)) |> Enum.sort()

  defp pairs({_name, nil}, _parent), do: []

  defp pairs({name, value}, parent) when is_map(value),
    do: Enum.flat_map(value, &pairs(&1, key(parent, name)))

  defp pairs({name, value}, parent) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.flat_map(fn {item, index} -> pairs({index, item}, key(parent, name)) end)
  end

  defp pairs({name, value}, parent), do: [{key(parent, name), to_string(value)}]

  defp key(nil, name), do: to_string(name)
  defp key(parent, name), do: "#{parent}[#{name}]"
end
