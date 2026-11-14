defmodule SiwaServer.Billing do
  @moduledoc """
  Each customer's billing periods and the agents counted in them.

  The current period is the one the database clock is in
  (`SiwaServer.Billing.Period`). An agent is counted once per customer and
  period: the first time a request it signed for one of the customer's
  production sites is verified, `count_agent/3` adds its row
  (`SiwaServer.Billing.ActiveAgent`) and one to the period's `active_agents`,
  inside the transaction that uses the request up
  (`SiwaServer.Siwa.HttpVerifier`). The rule that a period counts no more agents
  than its cap pays for is one conditional `UPDATE`: it adds one only while the
  count is below the period's `max_agents`, and the row's lock makes every
  request that counts a new agent wait its turn. An agent already counted
  passes at the cap.

  `open_period/3` opens a period. A `paid` customer's periods will come from
  its billing provider; until then a paid customer has none and its production
  sites answer `billing_required`. An `internal` customer's current UTC calendar
  month opens on first use (`period_to_count/1`).

  The control API reads and sets a customer's usage and cap through
  `SiwaServer.Customers`, which finds the customer for its person.
  """

  import Ecto.Changeset
  import Ecto.Query

  alias SiwaServer.Billing.{ActiveAgent, Period, Price}
  alias SiwaServer.Customers.{Customer, Site}
  alias SiwaServer.Repo

  # PostgreSQL's largest integer.
  @max_integer 2_147_483_647
  @default_page 50
  @max_page 200

  @type refusal :: {:error, {pos_integer(), String.t(), String.t()} | Ecto.Changeset.t()}

  @doc """
  Opens a period for `customer` from `starts_at` (inclusive) to `ends_at`
  (exclusive), with the customer's cap and the most agents it pays for.
  """
  @spec open_period(Customer.t(), DateTime.t(), DateTime.t()) ::
          {:ok, Period.t()} | {:error, Ecto.Changeset.t()}
  def open_period(customer, starts_at, ends_at),
    do: customer |> period(starts_at, ends_at) |> Repo.insert()

  @doc "The customer's period the database clock is in, or nil."
  @spec current_period(Customer.t(), keyword()) :: Period.t() | nil
  def current_period(%Customer{id: customer_id}, opts \\ []) do
    query =
      from p in Period,
        where:
          p.customer_id == ^customer_id and p.starts_at <= fragment("now()") and
            p.ends_at > fragment("now()")

    query = if opts[:lock], do: lock(query, "FOR UPDATE"), else: query
    Repo.one(query)
  end

  @doc """
  The period a production verification counts its agent in. An internal
  customer's current UTC calendar month opens here the first time; two
  verifications opening it at once open it once.
  """
  @spec period_to_count(Customer.t()) :: {:ok, Period.t()} | refusal()
  def period_to_count(customer) do
    case current_period(customer) || open_month(customer) do
      nil ->
        {:error,
         {402, "billing_required", "this site's customer has no billing period running now"}}

      period ->
        {:ok, period}
    end
  end

  @doc """
  Counts `subject` in `period` for a verification at `site`: `{:ok, true}` the
  first time this period, `{:ok, false}` after. A new agent the period's cap
  has no room for is refused; the caller's transaction then rolls back, so the
  agent's row goes too.
  """
  @spec count_agent(Period.t(), Site.t(), String.t()) :: {:ok, boolean()} | refusal()
  def count_agent(period, site, subject) do
    %{num_rows: inserted} =
      Repo.query!(
        """
        INSERT INTO monthly_active_agents
          (id, billing_period_id, customer_id, subject, first_site_id, first_verified_at)
        VALUES ($1, $2, $3, $4, $5, now())
        ON CONFLICT (billing_period_id, subject) DO NOTHING
        """,
        [
          Ecto.UUID.bingenerate(),
          Ecto.UUID.dump!(period.id),
          Ecto.UUID.dump!(period.customer_id),
          subject,
          Ecto.UUID.dump!(site.id)
        ]
      )

    cond do
      inserted == 0 -> {:ok, false}
      room?(period) -> {:ok, true}
      true -> {:error, {402, "agent_cap_reached", "this site's customer has reached its cap"}}
    end
  end

  # The one place the cap is enforced: the row's lock orders every request that
  # counts a new agent, and the condition is read again on the row it waited for.
  defp room?(period) do
    {updated, _rows} =
      Repo.update_all(
        from(p in Period,
          where: p.id == ^period.id and (is_nil(p.max_agents) or p.active_agents < p.max_agents)
        ),
        inc: [active_agents: 1]
      )

    updated == 1
  end

  @doc """
  Sets the customer's cap (`capCents`, null for none) and, in the same
  transaction, its current period's cap and the most agents that pays for. A
  cap is at least the minimum fee and never below the fee the current period
  has already reached.
  """
  @spec set_cap(Customer.t(), map()) :: {:ok, {Customer.t(), Period.t() | nil}} | refusal()
  def set_cap(customer, params) do
    Repo.transact(fn ->
      period = current_period(customer, lock: true)

      with {:ok, cap_cents} <- cap(params, period) do
        customer = customer |> change(cap_cents: cap_cents) |> Repo.update!()

        period =
          period &&
            period
            |> change(cap_cents: cap_cents, max_agents: Price.max_agents(cap_cents))
            |> Repo.update!()

        {:ok, {customer, period}}
      end
    end)
  end

  defp cap(params, period) do
    {%{}, %{capCents: :integer}}
    |> cast(params, [:capCents])
    |> then(fn changeset ->
      if Map.has_key?(params, "capCents"),
        do: changeset,
        else: add_error(changeset, :capCents, "can't be blank; null means no cap")
    end)
    |> validate_number(:capCents,
      greater_than_or_equal_to: Price.min_cap_cents(),
      less_than_or_equal_to: @max_integer
    )
    |> validate_change(:capCents, fn :capCents, cap_cents ->
      if is_nil(period) or Price.within?(period.active_agents, cap_cents),
        do: [],
        else: [capCents: "is below the fee this period has already reached"]
    end)
    |> apply_action(:update)
    |> case do
      {:ok, changes} -> {:ok, changes[:capCents]}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  The current period's counted agents, newest first, a page at a time:
  `limit` (1 to #{@max_page}, #{@default_page} when not given) after the
  `after` cursor a previous page gave. The answer is the page and the cursor
  for the next, nil on the last. No current period, no agents.
  """
  @spec agents(Customer.t(), map()) :: {:ok, {[ActiveAgent.t()], String.t() | nil}} | refusal()
  def agents(customer, params) do
    with {:ok, page} <- page(params) do
      case current_period(customer) do
        nil -> {:ok, {[], nil}}
        period -> {:ok, agents_page(period, page)}
      end
    end
  end

  defp agents_page(period, %{limit: limit} = page) do
    agents =
      from(a in ActiveAgent,
        where: a.billing_period_id == ^period.id,
        order_by: [desc: a.first_verified_at, desc: a.id],
        limit: ^(limit + 1)
      )
      |> after_cursor(page[:after])
      |> Repo.all()

    case Enum.split(agents, limit) do
      {agents, []} -> {agents, nil}
      {agents, _more} -> {agents, agents |> List.last() |> cursor()}
    end
  end

  defp after_cursor(query, nil), do: query

  defp after_cursor(query, {at, id}) do
    where(
      query,
      [a],
      a.first_verified_at < ^at or (a.first_verified_at == ^at and a.id < ^id)
    )
  end

  defp page(params) do
    {%{limit: @default_page}, %{after: :string, limit: :integer}}
    |> cast(params, [:after, :limit])
    |> validate_number(:limit, greater_than_or_equal_to: 1, less_than_or_equal_to: @max_page)
    |> update_change(:after, &decode_cursor/1)
    |> validate_change(:after, fn :after, decoded ->
      if decoded == :error, do: [after: "is not a cursor this list gave"], else: []
    end)
    |> apply_action(:read)
  end

  # A cursor is the last agent's first verification, in microseconds, and its id.
  defp cursor(agent) do
    Base.url_encode64(
      "#{DateTime.to_unix(agent.first_verified_at, :microsecond)}.#{agent.id}",
      padding: false
    )
  end

  defp decode_cursor(cursor) do
    with {:ok, decoded} <- Base.url_decode64(cursor, padding: false),
         [microseconds, id] <- String.split(decoded, ".", parts: 2),
         {microseconds, ""} <- Integer.parse(microseconds),
         {:ok, at} <- DateTime.from_unix(microseconds, :microsecond),
         {:ok, id} <- Ecto.UUID.cast(id) do
      {at, id}
    else
      _invalid -> :error
    end
  end

  defp open_month(%Customer{kind: :internal} = customer) do
    %{rows: [[starts_at, ends_at]]} =
      Repo.query!("""
      SELECT month AT TIME ZONE 'UTC', (month + interval '1 month') AT TIME ZONE 'UTC'
      FROM (SELECT date_trunc('month', now() AT TIME ZONE 'UTC') AS month) AS now
      """)

    {:ok, _opened_or_already_open} =
      customer |> period(starts_at, ends_at) |> Repo.insert(on_conflict: :nothing)

    current_period(customer)
  end

  defp open_month(%Customer{kind: :paid}), do: nil

  defp period(customer, starts_at, ends_at) do
    %Period{
      customer_id: customer.id,
      cap_cents: customer.cap_cents,
      max_agents: Price.max_agents(customer.cap_cents)
    }
    |> Period.changeset(%{starts_at: starts_at, ends_at: ends_at})
  end
end
