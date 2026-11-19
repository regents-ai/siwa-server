defmodule SiwaServer.Billing.Notice do
  @moduledoc """
  The notices Stripe sends to `POST /api/stripe/webhook`.

  A notice is taken only when its `Stripe-Signature` header signs the body as
  received: `t=<unix time>,v1=<hex>`, the HMAC-SHA256 of `<t>.<body>` under the
  webhook signing secret, compared in constant time, and `t` within five
  minutes of now.

  Each notice of a kind billing acts on is recorded once by its event id, and in
  the same transaction a job (`SiwaServer.Billing.NoticeWorker`) is queued to act
  on it, so a notice Stripe sends again is answered and does nothing. The job
  reads the object afresh from Stripe; the notice only says which to read.
  """

  alias SiwaServer.Billing.NoticeWorker
  alias SiwaServer.Repo

  @tolerance_seconds 300

  @kinds %{
    "checkout.session.completed" => "subscription",
    "customer.subscription.created" => "subscription",
    "customer.subscription.updated" => "subscription",
    "customer.subscription.deleted" => "subscription",
    "invoice.created" => "invoice_created",
    "invoice.finalized" => "invoice_finalized"
  }

  @doc "Whether the `Stripe-Signature` headers sign `body` with `secret`, at `now` (unix seconds)."
  @spec verify(binary() | nil, [String.t()], String.t(), integer()) :: :ok | :error
  def verify(body, [header], secret, now) when is_binary(body) do
    with {:ok, timestamp, signatures} <- parse(header),
         true <- abs(now - timestamp) <= @tolerance_seconds,
         expected = signature(body, timestamp, secret),
         true <- Enum.any?(signatures, &Plug.Crypto.secure_compare(&1, expected)) do
      :ok
    else
      _refused -> :error
    end
  end

  def verify(_body, _headers, _secret, _now), do: :error

  @doc "The `v1` signature of `body` sent at `timestamp`."
  @spec signature(binary(), integer(), String.t()) :: String.t()
  def signature(body, timestamp, secret),
    do:
      :hmac |> :crypto.mac(:sha256, secret, "#{timestamp}.#{body}") |> Base.encode16(case: :lower)

  defp parse(header) do
    pairs =
      header
      |> String.split(",")
      |> Enum.map(&String.split(String.trim(&1), "=", parts: 2))

    with [timestamp] <- for(["t", value] <- pairs, do: value),
         {timestamp, ""} <- Integer.parse(timestamp),
         [_ | _] = signatures <- for(["v1", value] <- pairs, do: value) do
      {:ok, timestamp, signatures}
    else
      _malformed -> :error
    end
  end

  @doc """
  Records a verified notice once and queues the job that acts on it:
  `:recorded`, `:repeat` for one recorded before, or `:ignored` for a kind
  billing does not act on.
  """
  @spec record(map()) :: {:ok, :recorded | :repeat | :ignored}
  def record(%{"id" => id, "type" => type, "data" => %{"object" => object}})
      when is_binary(id) do
    case job(@kinds[type], object) do
      nil -> {:ok, :ignored}
      args -> Repo.transact(fn -> record_once(id, type, args) end)
    end
  end

  def record(_other), do: {:ok, :ignored}

  defp record_once(id, type, args) do
    case Repo.insert_all("stripe_events", [%{id: id, type: type}], on_conflict: :nothing) do
      {1, _rows} ->
        {:ok, _job} = Oban.insert(NoticeWorker.new(Map.put(args, :event_id, id)))
        {:ok, :recorded}

      {0, _rows} ->
        {:ok, :repeat}
    end
  end

  # A completed checkout names the subscription it made.
  defp job("subscription", %{"object" => "checkout.session", "subscription" => id})
       when is_binary(id),
       do: %{kind: "subscription", object_id: id}

  defp job(kind, %{"object" => object, "id" => id})
       when is_binary(kind) and object in ["subscription", "invoice"],
       do: %{kind: kind, object_id: id}

  defp job(_kind, _object), do: nil
end
