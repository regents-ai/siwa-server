defmodule SiwaServer.Siwa.HttpVerifier do
  @moduledoc """
  Verifies signed HTTP request envelopes presented by agents signed in with
  their wallet, for the site that asks.

  A site asks in one of two ways:

    * `verify_for_key/3`: with its server key (`siwa_sk_…`), which names the
      site, its customer and its audience (`SiwaServer.Customers.site_for_key/1`).
      A key that is unknown, revoked or whose site is archived is refused before
      anything else is looked at, and so is an audience header naming another
      audience, or a production site whose origins are not proven
      (`SiwaServer.Audiences.usable?/1`).
    * `verify/2`: with only its audience, for the Regent sites
      `SIWA_WALLET_ORIGINS` names, exactly as before server keys. This is the one
      way in without a key, until those sites move to keys. A customer's site
      is refused here: its audience needs its key.

  Both check the request body once, against the contract: method, absolute
  path, the host the site received it at as `authority`, string headers (names
  compared in lower case), the optional `body_digest` the site worked out from
  the body it read (the body itself never comes here) and the optional `lease`,
  and nothing else. Then they delegate to
  `Siwa.RequestAuth.verify_authenticated_request/2`, which checks:

    * the wallet receipt issued by `SiwaServer.Siwa.Wallet.verify/1`
      (signature, expiry, and audience binding),
    * the HTTP message signature over the covered components, within the
      configured timestamp tolerance,
    * that the signed `@authority` is a host of one of the site's origins, so a
      request signed for one site is refused at another,
    * that the signed content-digest is the site's body digest when the
      request had a body, and
    * single use of the signature via `SiwaServer.Siwa.ReplayStore`.

  A keyed request's single use is made after every other check, in the same
  transaction that counts its agent for the customer's billing period
  (`SiwaServer.Billing`) when the site is a production one: a request refused
  for billing or the cap is not used up, and an agent is never counted for a
  request that was not. Only after that commits are the answer, its lease and
  the activity count made.

  Each verified request is then counted by `SiwaServer.Siwa.ActivityStore` (a
  count that cannot be written never refuses the request),
  and the answer names the agent's registry entry when it registered one
  through this server (see `SiwaServer.AgentRegistration`), and the person
  World's AgentBook last named behind the wallet (see `SiwaServer.AgentBook`).
  A keyed answer adds the agent's `subject`, and a production site's its
  `usage` this period.

  A site asks for a lease (`"lease": true`) on a request that reads. For a key's
  signature the answer adds `leaseExpiresAt`, `SiwaServer.Config.lease_seconds/0`
  from now and never past the receipt's expiry, nor past a production site's
  billing period; until then the site checks that agent's reads under the same
  receipt itself, and this server sees none of them. A smart wallet's signature
  never gets a lease.

  Library error reasons are mapped to stable client-facing status/code
  tuples by the shared contract's `refusals` (`Siwa.Contract.refusal/1`).
  """

  alias SiwaServer.{
    AgentBook,
    AgentRegistration,
    Audiences,
    Billing,
    Config,
    Customers,
    Ethereum,
    Repo
  }

  alias SiwaServer.Customers.Site
  alias SiwaServer.Siwa.{ActivityStore, ReplayStore}

  @types %{
    method: :string,
    path: :string,
    authority: :string,
    headers: :map,
    body_digest: :string,
    lease: :boolean
  }
  @fields Map.keys(@types)
  @keys Enum.map(@fields, &Atom.to_string/1)

  @type refusal :: {:error, {integer(), String.t(), String.t()}}

  @doc "Verifies a request for a site `SIWA_WALLET_ORIGINS` names, asked for by its audience alone."
  @spec verify(map(), String.t()) :: {:ok, map()} | refusal()
  def verify(params, audience) do
    with :ok <- keyless(audience),
         {:ok, request} <- cast(params),
         {:ok, verified} <-
           authenticate(
             request,
             audience,
             Map.get(Config.wallet_origins(), audience, []),
             Map.keys(Config.wallet_origins()),
             &ReplayStore.consume/2
           ) do
      {:ok, answer(request, verified, audience, nil, %{})}
    else
      error -> refusal(error)
    end
  end

  @doc """
  Verifies a request for the site whose server key the site presents.
  `audience` is the site's `x-siwa-audience` header, or nil when it sent none.
  """
  @spec verify_for_key(map(), String.t(), String.t() | nil) :: {:ok, map()} | refusal()
  def verify_for_key(params, key, audience) do
    with {:ok, %{site: site, customer: customer}} <- site(key),
         :ok <- same_audience(site, audience),
         :ok <- usable(site),
         {:ok, request} <- cast(params),
         {:ok, verified, replay} <- authenticate_once_used(request, site),
         subject = subject(verified.claims),
         {:ok, counted} <- use_up(site, customer, subject, replay) do
      {:ok, answer(request, verified, site.audience, counted, keyed_fields(subject, counted))}
    else
      error -> refusal(error)
    end
  end

  defp keyless(audience) do
    if Map.has_key?(Config.wallet_origins(), audience) or not Customers.site_audience?(audience),
      do: :ok,
      else: {:error, {401, "site_key_required", "this site's audience needs its server key"}}
  end

  defp site(key) do
    case Customers.site_for_key(key) do
      {:ok, found} ->
        {:ok, found}

      :error ->
        {:error,
         {401, "site_key_invalid", "the server key is not valid, revoked, or its site archived"}}
    end
  end

  defp same_audience(_site, nil), do: :ok
  defp same_audience(%Site{audience: audience}, audience), do: :ok

  defp same_audience(_site, _audience),
    do:
      {:error,
       {401, "site_audience_mismatch", "x-siwa-audience is not the audience of the key's site"}}

  defp usable(site) do
    if Audiences.usable?(site),
      do: :ok,
      else: {:error, {403, "site_not_verified", "this production site's origins are not proven"}}
  end

  # Method, path and authority are compared trimmed, and so are header values;
  # header names in lower case, so two spellings of one name are refused.
  defp cast(params) do
    changeset =
      {%{body_digest: nil, lease: nil}, @types}
      |> Ecto.Changeset.cast(params, @fields, empty_values: [])
      |> Ecto.Changeset.validate_required([:method, :path, :authority, :headers])

    with [] <- Map.keys(params) -- @keys,
         {:ok, request} <- Ecto.Changeset.apply_action(changeset, :verify),
         true <-
           Enum.all?(request.headers, fn {name, value} -> is_binary(name) and is_binary(value) end),
         request = %{
           request
           | method: String.trim(request.method),
             path: String.trim(request.path),
             authority: String.trim(request.authority)
         },
         false <- "" in [request.method, request.path, request.authority] do
      headers =
        Map.new(request.headers, fn {name, value} ->
          {String.downcase(name), String.trim(value)}
        end)

      cond do
        not String.starts_with?(request.path, "/") ->
          {:error, {400, "invalid_path", "path must be an absolute path"}}

        map_size(headers) != map_size(request.headers) ->
          {:error, {400, "invalid_headers", "headers must be an object of string headers"}}

        true ->
          {:ok, %{request | headers: headers}}
      end
    else
      _invalid ->
        {:error, {400, "invalid_request", "request body does not match the SIWA contract"}}
    end
  end

  defp authenticate(request, audience, origins, wallet_audiences, replay_store) do
    with {:ok, secret} <- Config.receipt_secret() do
      Siwa.RequestAuth.verify_authenticated_request(
        Map.take(request, [:method, :path, :authority, :headers, :body_digest]),
        receipt_secret: secret,
        audience: audience,
        authorities: Enum.map(origins, &Siwa.Contract.authority/1),
        wallet_audiences: wallet_audiences,
        signature_tolerance_seconds: Config.http_signature_tolerance_seconds(),
        replay_store: replay_store,
        chain_rpcs: Ethereum.chain_rpcs()
      )
    end
  end

  # Every check but the single use: the library's replay step, its last one
  # before success, is handed a step that only keeps the key and its end, and
  # `use_up/4` makes the use. A request the library accepts has always passed
  # that step, so an accepted request without a kept key is a fault, not a
  # refusal.
  defp authenticate_once_used(request, site) do
    ref = make_ref()

    keep = fn replay_key, expires ->
      send(self(), {ref, replay_key, expires})
      :ok
    end

    result = authenticate(request, site.audience, site.origins, [site.audience], keep)

    kept =
      receive do
        {^ref, replay_key, expires} -> {replay_key, expires}
      after
        0 -> nil
      end

    case {result, kept} do
      {{:ok, verified}, {_key, _expires}} -> {:ok, verified, kept}
      {{:error, _reason} = error, _kept} -> error
    end
  end

  # A sandbox site's request is only used up. A production site's is used up
  # and its agent counted in one transaction; a refusal from either rolls both back.
  defp use_up(%Site{environment: :sandbox}, _customer, _subject, {replay_key, expires}) do
    with :ok <- ReplayStore.consume(replay_key, expires), do: {:ok, nil}
  end

  defp use_up(%Site{environment: :production} = site, customer, subject, {replay_key, expires}) do
    Repo.transact(fn ->
      with :ok <- ReplayStore.consume(replay_key, expires),
           {:ok, period} <- Billing.period_to_count(customer),
           {:ok, new?} <- Billing.count_agent(period, site, subject) do
        {:ok, %{period: period, new?: new?}}
      end
    end)
  end

  defp subject(%{"chain_id" => chain_id, "sub" => address}),
    do: "eip155:#{chain_id}:#{String.downcase(address)}"

  # `counted` is the period a production site's agent was counted in, nil
  # otherwise; `fields` are added to the answer as they are.
  defp answer(request, verified, audience, counted, fields) do
    claims = verified.claims
    lease_expires_at = lease_expires_at(request, verified, counted)
    record_activity(claims, audience, lease_expires_at)

    %{
      "code" => "http_envelope_valid",
      "data" =>
        %{
          "verified" => true,
          "walletAddress" => claims["sub"],
          "chainId" => claims["chain_id"],
          "keyId" => claims["key_id"],
          "verificationMethod" => Atom.to_string(verified.verification_method),
          "receiptExpiresAt" => unix_ms_to_iso8601(claims["exp"]),
          "requiredHeaders" => Siwa.required_authenticated_request_headers(request.body_digest),
          "requiredCoveredComponents" =>
            Siwa.required_authenticated_request_components(
              request.headers,
              request.body_digest
            ),
          "coveredComponents" => verified.covered_components,
          "agentRegistration" => AgentRegistration.latest(claims["sub"]),
          "agentBook" => AgentBook.human(claims["sub"]),
          "principal" => %{
            "kind" => "wallet",
            "wallet_address" => claims["sub"],
            "chain_id" => claims["chain_id"],
            "audience" => claims["aud"]
          }
        }
        |> put_lease(lease_expires_at)
        |> Map.merge(fields)
    }
  end

  defp keyed_fields(subject, nil), do: %{"subject" => subject}

  defp keyed_fields(subject, %{new?: new?}),
    do: %{
      "subject" => subject,
      "usage" => %{"activeThisPeriod" => true, "newThisPeriod" => new?}
    }

  # A site asks for a lease only on a request that reads (`Siwa.AgentAuthPlug`'s
  # `read_only: true`). Only a key's signature gets one: the site checks it
  # itself with no chain to ask. A lease never outlasts the receipt, nor the
  # billing period its agent was counted in.
  defp lease_expires_at(%{lease: true}, %{verification_method: :eoa_recovery} = verified, counted) do
    lease_ends = System.system_time(:millisecond) + Config.lease_seconds() * 1_000
    Enum.min([lease_ends, verified.claims["exp"] | period_end(counted)])
  end

  defp lease_expires_at(_request, _verified, _counted), do: nil

  defp period_end(%{period: period}), do: [DateTime.to_unix(period.ends_at, :millisecond)]
  defp period_end(nil), do: []

  defp put_lease(data, nil), do: data

  defp put_lease(data, lease_expires_at),
    do: Map.put(data, "leaseExpiresAt", unix_ms_to_iso8601(lease_expires_at))

  # The count decides nothing, so a count that cannot be written never refuses a
  # verified request. It is counted as a failure instead.
  defp record_activity(claims, audience, lease_expires_at) do
    with {:error, _reason} <-
           ActivityStore.record(claims["sub"], audience, not is_nil(lease_expires_at)) do
      :telemetry.execute([:siwa_server, :siwa, :activity, :count_failed], %{}, %{})
    end
  end

  defp refusal({:error, {_status, _code, _message}} = error), do: error
  defp refusal({:error, reason}), do: {:error, map_shared_error(reason)}

  defp map_shared_error(reason) do
    case Siwa.Contract.refusal(reason) do
      nil -> {500, "request_replay_failed", "could not verify replay state"}
      refusal -> refusal
    end
  end

  defp unix_ms_to_iso8601(unix_ms),
    do: unix_ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()
end
