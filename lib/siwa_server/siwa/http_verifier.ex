defmodule SiwaServer.Siwa.HttpVerifier do
  @moduledoc """
  Verifies signed HTTP request envelopes presented by agents signed in with
  their wallet.

  `verify/2` checks the request body once, against the contract: method,
  absolute path, the host the site received it at as `authority`, string
  headers (names compared in lower case), the optional `body_digest` the site
  worked out from the body it read (the body itself never comes here) and the
  optional `lease`, and nothing else. Then it delegates to
  `Siwa.RequestAuth.verify_authenticated_request/2`, which checks:

    * the wallet receipt issued by `SiwaServer.Siwa.Wallet.verify/1`
      (signature, expiry, and audience binding),
    * the HTTP message signature over the covered components, within the
      configured timestamp tolerance,
    * that the signed `@authority` is a host of one of the audience's origins in
      `SIWA_WALLET_ORIGINS`, so a request signed for one site is refused at another,
    * that the signed content-digest is the site's body digest when the
      request had a body, and
    * single use of the signature via `SiwaServer.Siwa.ReplayStore`.

  Each verified request is then counted by `SiwaServer.Siwa.ActivityStore` (a
  count that cannot be written never refuses the request),
  and the answer names the agent's registry entry when it registered one
  through this server (see `SiwaServer.AgentRegistration`), and the person
  World's AgentBook last named behind the wallet (see `SiwaServer.AgentBook`).

  A site asks for a lease (`"lease": true`) on a request that reads. For a key's
  signature the answer adds `leaseExpiresAt`, `SiwaServer.Config.lease_seconds/0`
  from now and never past the receipt's expiry; until then the site checks that
  agent's reads under the same receipt itself, and this server sees none of them.
  A smart wallet's signature never gets a lease.

  Library error reasons are mapped to stable client-facing status/code
  tuples by the shared contract's `refusals` (`Siwa.Contract.refusal/1`).
  """

  alias SiwaServer.{AgentBook, AgentRegistration, Config, Ethereum}
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

  @spec verify(map(), String.t()) ::
          {:ok, map()} | {:error, {integer(), String.t(), String.t()}}
  def verify(params, audience) do
    with {:ok, request} <- cast(params),
         {:ok, secret} <- Config.receipt_secret(),
         {:ok, verified} <-
           Siwa.RequestAuth.verify_authenticated_request(
             Map.take(request, [:method, :path, :authority, :headers, :body_digest]),
             receipt_secret: secret,
             audience: audience,
             authorities: authorities(audience),
             wallet_audiences: Map.keys(Config.wallet_origins()),
             signature_tolerance_seconds: Config.http_signature_tolerance_seconds(),
             replay_store: &ReplayStore.consume/2,
             chain_rpcs: Ethereum.chain_rpcs()
           ) do
      claims = verified.claims
      lease_expires_at = lease_expires_at(request, verified)
      record_activity(claims, audience, lease_expires_at)

      {:ok,
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
             "requiredHeaders" =>
               Siwa.required_authenticated_request_headers(request.body_digest),
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
       }}
    else
      {:error, {_status, _code, _message}} = error -> error
      {:error, reason} -> {:error, map_shared_error(reason)}
    end
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

  @doc "The hosts an audience is served at: the authority of each of its origins."
  @spec authorities(String.t() | nil) :: [String.t()]
  def authorities(audience) do
    Config.wallet_origins()
    |> Map.get(audience, [])
    |> Enum.map(&Siwa.Contract.authority/1)
  end

  # The count decides nothing, so a count that cannot be written never refuses a
  # verified request. It is counted as a failure instead.
  # A site asks for a lease only on a request that reads (`Siwa.AgentAuthPlug`'s
  # `read_only: true`). Only a key's signature gets one: the site checks it
  # itself with no chain to ask. A lease never outlasts the receipt.
  defp lease_expires_at(%{lease: true}, %{verification_method: :eoa_recovery, claims: claims}) do
    lease_ends = System.system_time(:millisecond) + Config.lease_seconds() * 1_000
    min(lease_ends, claims["exp"])
  end

  defp lease_expires_at(_request, _verified), do: nil

  defp put_lease(data, nil), do: data

  defp put_lease(data, lease_expires_at),
    do: Map.put(data, "leaseExpiresAt", unix_ms_to_iso8601(lease_expires_at))

  defp record_activity(claims, audience, lease_expires_at) do
    with {:error, _reason} <-
           ActivityStore.record(claims["sub"], audience, not is_nil(lease_expires_at)) do
      :telemetry.execute([:siwa_server, :siwa, :activity, :count_failed], %{}, %{})
    end
  end

  defp map_shared_error(reason) do
    case Siwa.Contract.refusal(reason) do
      nil -> {500, "request_replay_failed", "could not verify replay state"}
      refusal -> refusal
    end
  end

  defp unix_ms_to_iso8601(unix_ms),
    do: unix_ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()
end
