defmodule SiwaServer.Customers do
  @moduledoc """
  The paid product's customer boundary: a customer, its sites and each site's
  server keys, kept for the person who owns them and changed through the
  control API (`SiwaServerWeb.ControlController`).

  Every function that reads or changes them takes the person's Privy DID, which
  only a verified control token supplies, and reaches the customer through it;
  no caller names a customer. A site or key of another customer is refused
  exactly as one that does not exist, and so is an archived site or anything
  under it.

  Request bodies are taken as sent and checked once: only the fields a step
  names, each within its rules (`SiwaServer.Customers.Customer`,
  `SiwaServer.Customers.Site`). A refusal is `{status, code, message}`, with the
  wait in milliseconds after them when it is 429, or the changeset naming the
  fields that failed.

  The customer's cap, its current billing period and the agents counted in it
  are `SiwaServer.Billing`'s, and its Stripe subscription and invoices
  `SiwaServer.Billing.Subscription`'s and `SiwaServer.Billing.Invoices`'; the
  steps here find the customer for the person.

  `site_for_key/1` is how request verification finds the site a presented
  server key belongs to (`SiwaServer.Siwa.HttpVerifier`), and `site_audience?/1`
  how it knows an audience is a customer's site, which needs its key.
  """

  import Ecto.Query

  alias SiwaServer.{Billing, RateLimiter, Repo}
  alias SiwaServer.Billing.{ActiveAgent, Invoices, Period, Subscription}
  alias SiwaServer.Customers.{Customer, Site, SiteCredential, SiteFile}

  @max_keys 5

  @type did :: String.t()
  @type refusal ::
          {:error,
           {pos_integer(), String.t(), String.t()}
           | {429, String.t(), String.t(), pos_integer()}
           | Ecto.Changeset.t()}

  @doc "The person's customer, or nil."
  @spec customer(did()) :: Customer.t() | nil
  def customer(did), do: Repo.get_by(Customer, owner_did: did)

  @doc "The person's customer and its current billing period, each nil when there is none."
  @spec account(did()) :: %{customer: Customer.t() | nil, period: Period.t() | nil}
  def account(did) do
    customer = customer(did)
    %{customer: customer, period: customer && Billing.current_period(customer)}
  end

  @doc """
  Sets the customer's cap (`capCents`, null for none), and its current
  period's with it (`SiwaServer.Billing.set_cap/2`).
  """
  @spec set_cap(did(), map()) :: {:ok, {Customer.t(), Period.t() | nil}} | refusal()
  def set_cap(did, params) do
    with {:ok, params} <- body(params, ~w(capCents)),
         {:ok, customer} <- fetch_customer(did),
         do: Billing.set_cap(customer, params)
  end

  @doc """
  The agents counted in the customer's current period, a page at a time
  (`SiwaServer.Billing.agents/2`), and the cursor for the next page.
  """
  @spec agents(did(), map()) :: {:ok, {[ActiveAgent.t()], String.t() | nil}} | refusal()
  def agents(did, params) do
    with {:ok, params} <- query(params, ~w(after limit)),
         {:ok, customer} <- fetch_customer(did),
         do: Billing.agents(customer, params)
  end

  @doc """
  A Stripe Checkout page that subscribes the person's customer
  (`SiwaServer.Billing.Subscription.checkout/3`), coming back to `returnUrl`.
  """
  @spec checkout(did(), map(), map()) :: {:ok, String.t()} | refusal()
  def checkout(did, params, stripe) do
    with {:ok, params} <- body(params, ~w(returnUrl)),
         {:ok, return_url} <- Subscription.return_url(params, stripe.portal_origins),
         {:ok, customer} <- fetch_customer(did),
         do: Subscription.checkout(customer, return_url, stripe.price_id)
  end

  @doc "Stripe's billing page for the person's customer, coming back to `returnUrl`."
  @spec portal(did(), map(), map()) :: {:ok, String.t()} | refusal()
  def portal(did, params, stripe) do
    with {:ok, params} <- body(params, ~w(returnUrl)),
         {:ok, return_url} <- Subscription.return_url(params, stripe.portal_origins),
         {:ok, customer} <- fetch_customer(did),
         do: Subscription.portal(customer, return_url)
  end

  @doc """
  The customer's invoices as Stripe has them, a page at a time
  (`SiwaServer.Billing.Invoices.list/2`). At most 30 reads a minute for each
  customer, since each one asks Stripe.
  """
  @spec invoices(did(), map()) :: {:ok, {[Invoices.invoice()], String.t() | nil}} | refusal()
  def invoices(did, params) do
    with {:ok, params} <- query(params, ~w(after limit)),
         {:ok, customer} <- fetch_customer(did),
         :ok <- allowance(:siwa_billing_invoices, customer.id),
         do: Invoices.list(customer, params)
  end

  @doc "Makes the person's customer, `paid`, unless they have one already."
  @spec create_customer(did(), map()) :: {:ok, Customer.t()} | refusal()
  def create_customer(did, params) do
    with {:ok, params} <- body(params, ~w(name)) do
      %Customer{owner_did: did, kind: :paid}
      |> Customer.changeset(params)
      |> Repo.insert()
      |> case do
        {:error, %{errors: [owner_did: _taken]}} ->
          {:error, {409, "customer_exists", "this person already has a customer"}}

        inserted ->
          inserted
      end
    end
  end

  @doc "Renames the person's customer."
  @spec update_customer(did(), map()) :: {:ok, Customer.t()} | refusal()
  def update_customer(did, params) do
    with {:ok, params} <- body(params, ~w(name)),
         {:ok, customer} <- fetch_customer(did) do
      customer |> Customer.changeset(params) |> Repo.update()
    end
  end

  @doc "The customer's sites that are not archived, oldest first."
  @spec list_sites(did()) :: {:ok, [Site.t()]} | refusal()
  def list_sites(did) do
    with {:ok, customer} <- fetch_customer(did) do
      {:ok,
       customer
       |> active_sites()
       |> order_by([s], asc: s.inserted_at, asc: s.id)
       |> Repo.all()}
    end
  end

  @doc "One of the customer's sites that is not archived."
  @spec get_site(did(), String.t()) :: {:ok, Site.t()} | refusal()
  def get_site(did, id) do
    with {:ok, customer} <- fetch_customer(did), do: fetch_site(customer, id)
  end

  @doc "Adds a site to the customer."
  @spec create_site(did(), map()) :: {:ok, Site.t()} | refusal()
  def create_site(did, params) do
    with {:ok, params} <- body(params, ~w(name audience environment origins)),
         {:ok, customer} <- fetch_customer(did) do
      %Site{customer_id: customer.id} |> Site.create_changeset(params) |> Repo.insert()
    end
  end

  @doc "Renames a site or changes its origins."
  @spec update_site(did(), String.t(), map()) :: {:ok, Site.t()} | refusal()
  def update_site(did, id, params) do
    with {:ok, params} <- body(params, ~w(name origins)),
         {:ok, customer} <- fetch_customer(did),
         {:ok, site} <- fetch_site(customer, id) do
      site |> Site.update_changeset(params) |> Repo.update()
    end
  end

  @doc """
  Checks a production site's origins now: reads each origin's site file
  (`SiwaServer.Customers.SiteFile`), all at once, and compares it, surrounding
  whitespace ignored, with the site's token. When every origin serves it, the
  site is verified, with the time. Otherwise the check keeps its time and the
  first of the site's origins that failed, with why, and the site stays
  unverified. At most 10 checks a minute for each site.

  A verified site is answered as it is, with nothing read. The result is kept
  only for the origins that were read: a site whose origins changed meanwhile,
  or that another check verified, is answered as it now is.
  """
  @spec check_site_proof(did(), String.t()) :: {:ok, Site.t()} | refusal()
  def check_site_proof(did, id) do
    with {:ok, customer} <- fetch_customer(did),
         {:ok, site} <- fetch_site(customer, id),
         do: check_proof(customer, site)
  end

  defp check_proof(_customer, %Site{environment: :sandbox}),
    do: {:error, {409, "site_proof_not_needed", "a sandbox site needs no proof of its origins"}}

  defp check_proof(_customer, %Site{origin_proof: :verified} = site), do: {:ok, site}

  defp check_proof(customer, %Site{origin_proof: :unverified} = site) do
    with :ok <- allowance(:siwa_site_proof, site.id),
         do: record_proof(customer, site, first_failure(site))
  end

  defp allowance(name, key) do
    case RateLimiter.check(name, key) do
      :ok ->
        :ok

      {:error, :unavailable} ->
        {:error, {503, "service_unavailable", "The sign-in service is temporarily unavailable."}}

      {:error, retry_after_ms} ->
        {:error,
         {429, "rate_limited", "Please wait a moment before trying again.", retry_after_ms}}
    end
  end

  # Each read ends within the site file's own time limit, so none is cut short here.
  defp first_failure(site) do
    site.origins
    |> Task.async_stream(&proof_at(&1, site.origin_proof_token),
      max_concurrency: length(site.origins),
      timeout: :infinity
    )
    |> Enum.zip(site.origins)
    |> Enum.find_value(fn
      {{:ok, :proven}, _origin} -> nil
      {{:ok, reason}, origin} -> {origin, reason}
    end)
  end

  defp proof_at(origin, token) do
    case SiteFile.fetch(origin) do
      {:ok, body} -> if String.trim(body) == token, do: :proven, else: :wrong_token
      {:error, reason} -> reason
    end
  end

  defp record_proof(customer, site, failure) do
    now = DateTime.utc_now(:second)

    outcome =
      case failure do
        nil ->
          [
            origin_proof: :verified,
            origin_proof_verified_at: now,
            origin_proof_failure: nil,
            origin_proof_failed_origin: nil
          ]

        {origin, reason} ->
          [origin_proof_failure: reason, origin_proof_failed_origin: origin]
      end

    checked =
      from s in Site,
        where:
          s.id == ^site.id and s.origins == ^site.origins and s.origin_proof == :unverified and
            is_nil(s.archived_at),
        select: s

    case Repo.update_all(checked, set: [origin_proof_checked_at: now, updated_at: now] ++ outcome) do
      {1, [recorded]} -> {:ok, recorded}
      {0, []} -> fetch_site(customer, site.id)
    end
  end

  @doc """
  Archives a site: it is kept with its audience, which no other site may take,
  and no longer listed or found, so its keys stop working.
  """
  @spec archive_site(did(), String.t()) :: {:ok, Site.t()} | refusal()
  def archive_site(did, id) do
    with {:ok, customer} <- fetch_customer(did),
         {:ok, site} <- fetch_site(customer, id) do
      site |> Ecto.Changeset.change(archived_at: DateTime.utc_now(:second)) |> Repo.update()
    end
  end

  @doc "A site's keys, revoked ones included, newest first."
  @spec list_keys(did(), String.t()) :: {:ok, [SiteCredential.t()]} | refusal()
  def list_keys(did, site_id) do
    with {:ok, customer} <- fetch_customer(did),
         {:ok, site} <- fetch_site(customer, site_id) do
      {:ok,
       Repo.all(
         from k in SiteCredential,
           where: k.site_id == ^site.id,
           order_by: [desc: k.inserted_at, desc: k.id]
       )}
    end
  end

  @doc """
  Makes a server key for a site: the key, which is never shown again, and its
  record. A site has at most #{@max_keys} keys that are not revoked. Its row is
  locked while they are counted, so two requests at once cannot both take the
  last place.
  """
  @spec create_key(did(), String.t()) :: {:ok, {String.t(), SiteCredential.t()}} | refusal()
  def create_key(did, site_id) do
    with {:ok, customer} <- fetch_customer(did) do
      Repo.transact(fn -> insert_key(customer, site_id) end)
    end
  end

  defp insert_key(customer, site_id) do
    with {:ok, site} <- fetch_site(customer, site_id, lock: true),
         :ok <- room_for_key(site) do
      {key, credential} = SiteCredential.new(site)
      {:ok, {key, Repo.insert!(credential, log: false)}}
    end
  end

  @doc "Revokes a site's key; it is kept. Revoking it again changes nothing."
  @spec revoke_key(did(), String.t(), String.t()) :: {:ok, SiteCredential.t()} | refusal()
  def revoke_key(did, site_id, key_id) do
    with {:ok, customer} <- fetch_customer(did),
         {:ok, site} <- fetch_site(customer, site_id),
         {:ok, credential} <- fetch_key(site, key_id) do
      case credential.revoked_at do
        nil ->
          credential
          |> Ecto.Changeset.change(revoked_at: DateTime.utc_now(:second))
          |> Repo.update()

        _revoked ->
          {:ok, credential}
      end
    end
  end

  @doc """
  The site a presented server key belongs to, with its customer, while the key
  is not revoked and the site not archived. Found by the key's hash.
  """
  @spec site_for_key(String.t()) :: {:ok, %{site: Site.t(), customer: Customer.t()}} | :error
  def site_for_key(key) when is_binary(key) do
    query =
      from k in SiteCredential,
        join: s in assoc(k, :site),
        join: c in assoc(s, :customer),
        where:
          k.key_hash == ^SiteCredential.hash(key) and is_nil(k.revoked_at) and
            is_nil(s.archived_at),
        select: %{site: s, customer: c}

    case Repo.one(query, log: false) do
      nil -> :error
      found -> {:ok, found}
    end
  end

  @doc "Whether a customer's site, archived ones included, holds `audience`."
  @spec site_audience?(String.t()) :: boolean()
  def site_audience?(audience), do: Repo.exists?(from s in Site, where: s.audience == ^audience)

  defp body(params, fields),
    do: only(params, fields, "the request body has fields this step does not take")

  defp query(params, fields),
    do: only(params, fields, "the query has parameters this step does not take")

  defp only(params, fields, message) do
    case Map.keys(params) -- fields do
      [] -> {:ok, params}
      _other_fields -> {:error, {400, "control_request_invalid", message}}
    end
  end

  defp fetch_customer(did) do
    case customer(did) do
      nil -> {:error, {404, "customer_not_found", "this person has no customer yet"}}
      customer -> {:ok, customer}
    end
  end

  defp active_sites(customer),
    do: from(s in Site, where: s.customer_id == ^customer.id and is_nil(s.archived_at))

  defp fetch_site(customer, id, opts \\ []) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         query = where(active_sites(customer), [s], s.id == ^id),
         query = if(opts[:lock], do: lock(query, "FOR UPDATE"), else: query),
         %Site{} = site <- Repo.one(query) do
      {:ok, site}
    else
      _missing -> {:error, {404, "site_not_found", "this person's customer has no such site"}}
    end
  end

  defp fetch_key(site, id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %SiteCredential{} = credential <- Repo.get_by(SiteCredential, id: id, site_id: site.id) do
      {:ok, credential}
    else
      _missing -> {:error, {404, "site_key_not_found", "this site has no such key"}}
    end
  end

  defp room_for_key(site) do
    active =
      Repo.aggregate(
        from(k in SiteCredential, where: k.site_id == ^site.id and is_nil(k.revoked_at)),
        :count
      )

    if active < @max_keys,
      do: :ok,
      else:
        {:error,
         {409, "site_key_limit", "this site already has #{@max_keys} keys that are not revoked"}}
  end
end
