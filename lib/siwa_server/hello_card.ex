defmodule SiwaServer.HelloCard do
  @moduledoc """
  Hello cards: this server's signed note that a site said an agent is paired with
  a person there. An agent shows its card to other sites, which check it against
  the keys this server publishes, without asking anyone.

  An agent asks for a card itself, with a signed request addressed to this server
  (`SiwaServer.Siwa.HttpVerifier.verify_own/2`), naming the site it is paired on.
  This server then asks that site, at its first origin in `SIWA_WALLET_ORIGINS`,
  with `POST /api/agents/v1/pairing` and the body
  `{"subject": "eip155:<chain id>:<address>"}`, presenting a service token: a
  compact JWS this server signs, typed `siwa-service+jwt`, for that site's origin
  and that subject, good for 60 seconds. Only the site's answer decides:

    * `200` with exactly `name`, the agent's name there, and `person`, the
      person's profile code (the random id of their Regent profile, never a
      name), 1 to 200 characters each, and `pairedAt` (ISO 8601, UTC) gives a
      card;
    * `404` means the agent is not paired there;
    * `409` with a JSON body whose `code` is `person_has_no_profile` means the
      agent is paired there with a person who has no profile on that site
      yet, so there is no profile code to sign; any other field in the body is
      ignored;
    * anything else, no answer within 5 seconds, or a redirect, is the site
      being unavailable. It is logged with the site and the reason, never the
      token, and nothing is retried: the agent asks again.

  The card is a compact JWS typed `siwa-hello-card+jws`, signed with the first
  of `SIWA_CARD_KEYS`. Its payload has exactly eight fields: `cardId` (16 random
  bytes), `subject`, `name`, `person`, `pairedAt`, `pairedOn` (the site's
  audience), `issuedAt` and `expiresAt`, a day later. Times are ISO 8601 UTC in
  whole seconds. Nothing is stored; each card is logged by its id, site and
  subject, never with the card or the person.

  Every key is published as an Ed25519 JWK (`jwks/0`) whose `kid` is its
  RFC 7638 thumbprint, and a site checks a card against those keys.
  """

  alias SiwaServer.Config

  require Logger

  @card_typ "siwa-hello-card+jws"
  @service_typ "siwa-service+jwt"
  @card_seconds 86_400
  @token_seconds 60
  @timeout_ms 5_000

  @type card :: %{String.t() => String.t()}
  @type refusal :: {:error, {pos_integer(), String.t(), String.t()}}

  @doc "Whether this server signs hello cards: only once `SIWA_CARD_KEYS` is set."
  @spec configured() :: :ok | refusal()
  def configured do
    case Config.card_keys() do
      [] ->
        {:error,
         {503, "hello_card_not_configured", "hello cards are not turned on on this server"}}

      _keys ->
        :ok
    end
  end

  @doc """
  The published keys, as the body of `/.well-known/jwks.json`: public keys only,
  the signing key first, and an empty list while none is set.
  """
  @spec jwks() :: %{String.t() => [map()]}
  def jwks, do: %{"keys" => Enum.map(Config.card_keys(), &jwk/1)}

  @doc """
  A card for `subject` ("eip155:<chain id>:<address>", already proven by its
  signed request), paired on the site `paired_on`, a `SIWA_WALLET_ORIGINS`
  audience, once that site says so. The answer is the eight fields and the
  signed `card`.
  """
  @spec issue(String.t(), String.t()) :: {:ok, card()} | refusal()
  def issue(subject, paired_on) do
    [seed | _published] = Config.card_keys()
    [origin | _others] = Map.fetch!(Config.wallet_origins(), paired_on)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    token =
      sign(seed, @service_typ, %{
        "iss" => SiwaServerWeb.Endpoint.url(),
        "aud" => origin,
        "sub" => subject,
        "iat" => DateTime.to_unix(now),
        "exp" => DateTime.to_unix(now) + @token_seconds,
        "jti" => encode(:crypto.strong_rand_bytes(16))
      })

    case ask_site(paired_on, origin, subject, token) do
      {:ok, pairing} ->
        fields =
          Map.merge(pairing, %{
            "cardId" => encode(:crypto.strong_rand_bytes(16)),
            "subject" => subject,
            "pairedOn" => paired_on,
            "issuedAt" => DateTime.to_iso8601(now),
            "expiresAt" => now |> DateTime.add(@card_seconds) |> DateTime.to_iso8601()
          })

        Logger.info(
          "hello card issued card_id=#{fields["cardId"]} paired_on=#{paired_on} subject=#{subject}"
        )

        {:ok, Map.put(fields, "card", sign(seed, @card_typ, fields))}

      :not_paired ->
        {:error, {404, "hello_card_not_paired", "the site says this agent is not paired there"}}

      :no_profile ->
        {:error,
         {409, "hello_card_person_has_no_profile",
          "the site says this agent is paired with a person who has no profile there yet"}}

      {:unavailable, reason} ->
        Logger.warning("hello card pairing read failed paired_on=#{paired_on} reason=#{reason}")

        {:error,
         {502, "hello_card_site_unavailable",
          "the site could not say whether this agent is paired there"}}
    end
  end

  # The site's answer, read once: no retry, and no redirect followed.
  defp ask_site(paired_on, origin, subject, token) do
    options = [
      method: :post,
      url: origin <> "/api/agents/v1/pairing",
      json: %{"subject" => subject},
      headers: [{"authorization", "Bearer " <> token}],
      retry: false,
      redirect: false,
      receive_timeout: @timeout_ms,
      connect_options: [timeout: @timeout_ms]
    ]

    :telemetry.span([:siwa_server, :hello_card, :pairing], %{audience: paired_on}, fn ->
      answer = options |> Req.request() |> pairing()
      {answer, %{audience: paired_on, result: result(answer)}}
    end)
  end

  defp pairing({:ok, %Req.Response{status: 200, body: body}}) do
    with %{"name" => name, "person" => person, "pairedAt" => paired_at} when map_size(body) == 3 <-
           body,
         true <- text?(name) and text?(person) and is_binary(paired_at),
         {:ok, paired_at, 0} <- DateTime.from_iso8601(paired_at) do
      {:ok,
       %{
         "name" => name,
         "person" => person,
         "pairedAt" => paired_at |> DateTime.truncate(:second) |> DateTime.to_iso8601()
       }}
    else
      _other_shape -> {:unavailable, "the answer was not name, person and pairedAt"}
    end
  end

  defp pairing({:ok, %Req.Response{status: 404}}), do: :not_paired

  defp pairing({:ok, %Req.Response{status: 409, body: %{"code" => "person_has_no_profile"}}}),
    do: :no_profile

  defp pairing({:ok, %Req.Response{status: status}}), do: {:unavailable, "status #{status}"}
  defp pairing({:error, exception}), do: {:unavailable, Exception.message(exception)}

  defp result({:ok, _pairing}), do: :paired
  defp result(:not_paired), do: :not_paired
  defp result(:no_profile), do: :no_profile
  defp result({:unavailable, _reason}), do: :unavailable

  defp text?(value), do: is_binary(value) and String.length(value) in 1..200

  defp sign(seed, typ, claims) do
    header = encode(Jason.encode!(%{"alg" => "EdDSA", "typ" => typ, "kid" => jwk(seed)["kid"]}))
    payload = encode(Jason.encode!(claims))
    signature = :crypto.sign(:eddsa, :none, header <> "." <> payload, [seed, :ed25519])
    header <> "." <> payload <> "." <> encode(signature)
  end

  # The public key of `seed`, with its RFC 7638 thumbprint as `kid`: the SHA-256 of
  # the key's required members in order.
  defp jwk(seed) do
    {public_key, _seed} = :crypto.generate_key(:eddsa, :ed25519, seed)
    x = encode(public_key)
    thumbprint = :crypto.hash(:sha256, ~s({"crv":"Ed25519","kty":"OKP","x":"#{x}"}))

    %{
      "kty" => "OKP",
      "crv" => "Ed25519",
      "alg" => "EdDSA",
      "use" => "sig",
      "kid" => encode(thumbprint),
      "x" => x
    }
  end

  defp encode(bytes), do: Base.url_encode64(bytes, padding: false)
end
