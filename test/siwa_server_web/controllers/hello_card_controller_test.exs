defmodule SiwaServerWeb.HelloCardControllerTest do
  @moduledoc """
  Hello cards end to end inside the server: an agent's signed request to this
  server, the site's pairing read (answered by the test through `Req.Test`), the
  card and the published keys, all with Ed25519 keys made for the run.
  """

  use SiwaServerWeb.ConnCase, async: false
  use ExUnitProperties

  import ExUnit.CaptureLog

  alias SiwaServer.{HelloCard, SignedRequest}

  @path "/api/shared/siwa/hello-card"
  @chain_id 8453
  @person "8c1f2e7a-3b4d-4f60-9a12-5de7c0b8a941"
  @other_person "d27a90b3-1e5c-4a88-b6f4-0c93e7125fda"
  @paired %{"name" => "Astra", "person" => @person, "pairedAt" => "2026-11-01T09:30:00.250Z"}

  setup do
    siwa = Application.fetch_env!(:siwa_server, :siwa)
    on_exit(fn -> Application.put_env(:siwa_server, :siwa, siwa) end)

    Application.put_env(
      :siwa_server,
      :siwa,
      Keyword.put(siwa, :wallet_origins, %{
        "keyfleet" => ["https://keyfleet.ai", "https://www.keyfleet.ai"],
        "patchbay" => ["https://patchbay.help"]
      })
    )

    %{signer: SignedRequest.signer(), own: Siwa.Contract.authority(SiwaServerWeb.Endpoint.url())}
  end

  test "an agent paired on a site gets a card the published keys verify, with its fields",
       %{signer: signer, own: own} do
    site(fn conn -> Req.Test.json(conn, @paired) end)

    assert %{"code" => "hello_card", "data" => data} =
             signer |> signed(own) |> send_card() |> json_response(200)

    {card, fields} = Map.pop!(data, "card")
    subject = SignedRequest.subject(signer)

    assert %{
             "subject" => ^subject,
             "name" => "Astra",
             "person" => @person,
             "pairedAt" => "2026-11-01T09:30:00Z",
             "pairedOn" => "keyfleet",
             "cardId" => card_id,
             "issuedAt" => issued_at,
             "expiresAt" => expires_at
           } = fields

    assert map_size(fields) == 8
    assert {:ok, <<_::binary-size(16)>>} = Base.url_decode64(card_id, padding: false)

    {:ok, issued, 0} = DateTime.from_iso8601(issued_at)
    {:ok, expires, 0} = DateTime.from_iso8601(expires_at)
    assert DateTime.diff(expires, issued) == 86_400
    assert abs(DateTime.diff(DateTime.utc_now(), issued)) <= 5

    keys = published_keys()
    assert HelloCard.verify(card, keys, DateTime.utc_now()) == {:ok, fields}
    assert HelloCard.verify(card, keys, expires) == {:error, :expired}
    assert HelloCard.verify(card, keys, DateTime.add(expires, -1)) == {:ok, fields}
  end

  test "the site is asked at its first origin, for the subject, with a service token it can check",
       %{signer: signer, own: own} do
    site(fn conn -> Req.Test.json(conn, @paired) end)
    signer |> signed(own) |> send_card() |> json_response(200)

    assert_received {:asked, asked, body}
    subject = SignedRequest.subject(signer)

    assert {asked.method, asked.scheme, asked.host, asked.request_path} ==
             {"POST", :https, "keyfleet.ai", "/api/agents/v1/pairing"}

    assert Jason.decode!(body) == %{"subject" => subject}
    assert ["Bearer " <> token] = Plug.Conn.get_req_header(asked, "authorization")

    assert {:ok, claims} = site_check(token, published_keys())
    issuer = SiwaServerWeb.Endpoint.url()

    assert %{
             "iss" => ^issuer,
             "aud" => "https://keyfleet.ai",
             "sub" => ^subject,
             "iat" => iat,
             "exp" => exp,
             "jti" => jti
           } = claims

    assert map_size(claims) == 6
    assert exp - iat == 60
    assert abs(System.os_time(:second) - iat) <= 5
    assert {:ok, <<_::binary-size(16)>>} = Base.url_decode64(jti, padding: false)

    # Neither is the other: a service token is no card, and a card is no service token.
    assert HelloCard.verify(token, published_keys(), DateTime.utc_now()) ==
             {:error, :wrong_type}

    card = signer |> signed(own) |> send_card() |> json_response(200) |> get_in(["data", "card"])
    assert site_check(card, published_keys()) == :error
  end

  test "a changed card is refused", %{signer: signer, own: own} do
    site(fn conn -> Req.Test.json(conn, @paired) end)
    card = signer |> signed(own) |> send_card() |> json_response(200) |> get_in(["data", "card"])
    keys = published_keys()
    now = DateTime.utc_now()
    [header, payload, signature] = String.split(card, ".")

    renamed =
      payload
      |> Base.url_decode64!(padding: false)
      |> Jason.decode!()
      |> Map.put("person", @other_person)
      |> Jason.encode!()
      |> Base.url_encode64(padding: false)

    assert HelloCard.verify(Enum.join([header, renamed, signature], "."), keys, now) ==
             {:error, :bad_signature}

    other_signature = Base.url_encode64(:crypto.strong_rand_bytes(64), padding: false)

    assert HelloCard.verify(Enum.join([header, payload, other_signature], "."), keys, now) ==
             {:error, :bad_signature}

    # Another key with the same kid is not this server's key.
    {other_public, _other_seed} = :crypto.generate_key(:eddsa, :ed25519)

    impostor =
      Enum.map(keys, &Map.put(&1, "x", Base.url_encode64(other_public, padding: false)))

    assert HelloCard.verify(card, impostor, now) == {:error, :bad_signature}
    assert HelloCard.verify(card, [], now) == {:error, :unknown_key}
    assert HelloCard.verify(card <> ".", keys, now) == {:error, :malformed}
  end

  property "a card changed in any one character is refused", %{signer: signer, own: own} do
    site(fn conn -> Req.Test.json(conn, @paired) end)
    card = signer |> signed(own) |> send_card() |> json_response(200) |> get_in(["data", "card"])
    keys = published_keys()
    now = DateTime.utc_now()

    alphabet =
      String.graphemes("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.")

    check all at <- integer(0..(byte_size(card) - 1)),
              replacement <- member_of(alphabet),
              replacement != binary_part(card, at, 1) do
      changed =
        binary_part(card, 0, at) <>
          replacement <>
          binary_part(card, at + 1, byte_size(card) - at - 1)

      assert {:error, _reason} = HelloCard.verify(changed, keys, now)
    end
  end

  test "a signed request is good for one card", %{signer: signer, own: own} do
    site(fn conn -> Req.Test.json(conn, @paired) end)
    request = signed(signer, own)

    assert request |> send_card() |> json_response(200)
    assert_received {:asked, _asked, _body}

    assert %{"error" => %{"code" => "request_replayed"}} =
             request |> send_card() |> json_response(409)

    refute_received {:asked, _asked, _body}
  end

  test "a request signed for any other host is refused", %{signer: signer} do
    site(fn conn -> Req.Test.json(conn, @paired) end)

    for authority <- ["siwa-server.fly.dev", "keyfleet.ai"] do
      assert %{"error" => %{"code" => "http_signature_invalid"}} =
               signer |> signed(authority) |> send_card() |> json_response(401)
    end

    refute_received {:asked, _asked, _body}
  end

  test "a sign-in for another site is refused", %{signer: signer, own: own} do
    site(fn conn -> Req.Test.json(conn, @paired) end)

    assert %{"error" => %{"code" => "receipt_binding_mismatch"}} =
             signer
             |> signed(own, receipt_for: "patchbay")
             |> send_card()
             |> json_response(401)

    refute_received {:asked, _asked, _body}
  end

  test "a site this server does not know, or any other body, is refused before the site is asked",
       %{signer: signer, own: own} do
    site(fn conn -> Req.Test.json(conn, @paired) end)

    assert %{"error" => %{"code" => "hello_card_site_unknown"}} =
             signer
             |> signed(own, body: ~s({"pairedOn":"acme"}))
             |> send_card()
             |> json_response(404)

    for body <- [
          ~s({"pairedOn":"keyfleet","name":"Astra"}),
          ~s({"pairedOn":["keyfleet"]}),
          ~s(["keyfleet"]),
          ~s({})
        ] do
      assert %{"error" => %{"code" => "invalid_request"}} =
               signer |> signed(own, body: body) |> send_card() |> json_response(400)
    end

    refute_received {:asked, _asked, _body}
  end

  test "a site that says the agent is not paired there gives no card",
       %{signer: signer, own: own} do
    site(fn conn -> Plug.Conn.send_resp(conn, 404, "") end)

    assert %{"error" => %{"code" => "hello_card_not_paired"}} =
             signer |> signed(own) |> send_card() |> json_response(404)
  end

  test "a site whose paired person has no profile there yet gives no card, and says what to do",
       %{signer: signer, own: own} do
    for body <- [
          %{"code" => "person_has_no_profile"},
          %{"code" => "person_has_no_profile", "message" => "they have not signed in here"}
        ] do
      site(fn conn -> conn |> Plug.Conn.put_status(409) |> Req.Test.json(body) end)

      answer = signer |> signed(own) |> send_card() |> json_response(409)

      assert %{"error" => %{"code" => "hello_card_person_has_no_profile", "hint" => hint}} =
               answer

      assert hint != ""
      refute Map.has_key?(answer, "data")
      assert_received {:asked, _asked, _body}
    end
  end

  test "a site that is down, slow, redirects or answers anything else gives no card",
       %{signer: signer, own: own} do
    for answer <- [
          &Req.Test.transport_error(&1, :econnrefused),
          &Req.Test.transport_error(&1, :timeout),
          &redirect/1,
          &Plug.Conn.send_resp(&1, 500, ""),
          &Plug.Conn.send_resp(&1, 409, ""),
          &(&1 |> Plug.Conn.put_status(409) |> Req.Test.text("person_has_no_profile")),
          &(&1 |> Plug.Conn.put_status(409) |> Req.Test.json(%{"code" => "person_unknown"})),
          &Req.Test.json(&1, Map.delete(@paired, "person")),
          &Req.Test.json(&1, Map.put(@paired, "extra", "x")),
          &Req.Test.json(&1, Map.put(@paired, "name", "")),
          &Req.Test.json(&1, Map.put(@paired, "person", String.duplicate("p", 201))),
          &Req.Test.json(&1, Map.put(@paired, "pairedAt", "2026-11-01T11:30:00+02:00")),
          &Req.Test.json(&1, Map.put(@paired, "pairedAt", "yesterday")),
          &Req.Test.text(&1, "paired")
        ] do
      site(answer)

      log =
        capture_log(fn ->
          assert %{"error" => %{"code" => "hello_card_site_unavailable"}} =
                   signer |> signed(own) |> send_card() |> json_response(502)
        end)

      assert_received {:asked, asked, _body}
      ["Bearer " <> token] = Plug.Conn.get_req_header(asked, "authorization")
      refute log =~ token
    end
  end

  test "a card is logged by its id, site and subject, never with the card or the person",
       %{signer: signer, own: own} do
    site(fn conn -> Req.Test.json(conn, Map.put(@paired, "person", @other_person)) end)
    level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: level) end)

    {%{"data" => %{"card" => card, "cardId" => card_id}}, log} =
      with_log([level: :info], fn ->
        signer |> signed(own) |> send_card() |> json_response(200)
      end)

    assert log =~ card_id
    refute log =~ card
    refute log =~ @other_person
  end

  test "the published keys: every key with its thumbprint, the first signing, public keys only" do
    seeds = [:crypto.strong_rand_bytes(32), :crypto.strong_rand_bytes(32)]
    put_card_keys(seeds)

    conn = get(build_conn(), "/.well-known/jwks.json")
    assert get_resp_header(conn, "cache-control") == ["public, max-age=3600"]
    assert %{"keys" => keys} = json_response(conn, 200)

    assert keys ==
             Enum.map(seeds, fn seed ->
               {public, _seed} = :crypto.generate_key(:eddsa, :ed25519, seed)
               x = Base.url_encode64(public, padding: false)

               thumbprint =
                 :crypto.hash(:sha256, ~s({"crv":"Ed25519","kty":"OKP","x":"#{x}"}))

               %{
                 "kty" => "OKP",
                 "crv" => "Ed25519",
                 "alg" => "EdDSA",
                 "use" => "sig",
                 "kid" => Base.url_encode64(thumbprint, padding: false),
                 "x" => x
               }
             end)

    signer = SignedRequest.signer()
    site(fn conn -> Req.Test.json(conn, @paired) end)

    card =
      signer
      |> signed(Siwa.Contract.authority(SiwaServerWeb.Endpoint.url()))
      |> send_card()
      |> json_response(200)
      |> get_in(["data", "card"])

    [first, second] = keys
    assert {:ok, _fields} = HelloCard.verify(card, [first], DateTime.utc_now())
    assert HelloCard.verify(card, [second], DateTime.utc_now()) == {:error, :unknown_key}
  end

  test "without signing keys no card is made, and none is published",
       %{signer: signer, own: own} do
    put_card_keys([])
    site(fn conn -> Req.Test.json(conn, @paired) end)

    assert %{"error" => %{"code" => "hello_card_not_configured"}} =
             signer |> signed(own) |> send_card() |> json_response(503)

    refute_received {:asked, _asked, _body}
    assert published_keys() == []
  end

  # The pairing site, answering with `answer` and telling the test what it was asked.
  defp site(answer) do
    test = self()

    Req.Test.stub(HelloCard, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:asked, conn, body})
      answer.(conn)
    end)
  end

  defp redirect(conn) do
    conn
    |> Plug.Conn.put_resp_header("location", "https://elsewhere.example/api/agents/v1/pairing")
    |> Plug.Conn.send_resp(302, "")
  end

  # A card request the agent signed with its receipt for `receipt_for` (the site it
  # names, by default) and sent to `authority`.
  defp signed(signer, authority, opts \\ []) do
    body = Keyword.get(opts, :body, ~s({"pairedOn":"keyfleet"}))

    {:ok, request} =
      Siwa.RequestAuth.sign_request(
        %{method: "POST", path: @path, authority: authority, body: body, headers: %{}},
        %{
          receipt: receipt(signer.address, Keyword.get(opts, :receipt_for, "keyfleet")),
          key_id: signer.address,
          wallet_address: signer.address,
          chain_id: @chain_id
        },
        signer
      )

    request
  end

  defp send_card(request) do
    scheme = if String.starts_with?(request.authority, "localhost:"), do: "http", else: "https"

    request.headers
    |> Enum.reduce(build_conn(), fn {name, value}, conn -> put_req_header(conn, name, value) end)
    |> put_req_header("content-type", "application/json")
    |> post("#{scheme}://#{request.authority}#{request.path}", request.body)
  end

  defp published_keys do
    build_conn() |> get("/.well-known/jwks.json") |> json_response(200) |> Map.fetch!("keys")
  end

  # A site's own check of the service token it is shown: a published key's
  # signature, and the service token's type.
  defp site_check(token, keys) do
    [header, payload, signature] = String.split(token, ".")
    named = header |> Base.url_decode64!(padding: false) |> Jason.decode!()
    key = Enum.find(keys, &(&1["kid"] == named["kid"]))
    public = Base.url_decode64!(key["x"], padding: false)
    signature = Base.url_decode64!(signature, padding: false)

    if named["typ"] == "siwa-service+jwt" and named["alg"] == "EdDSA" and
         :crypto.verify(:eddsa, :none, header <> "." <> payload, signature, [public, :ed25519]),
       do: {:ok, payload |> Base.url_decode64!(padding: false) |> Jason.decode!()},
       else: :error
  end

  defp put_card_keys(seeds) do
    siwa = Application.fetch_env!(:siwa_server, :siwa)
    Application.put_env(:siwa_server, :siwa, Keyword.put(siwa, :card_keys, seeds))
  end

  defp receipt(address, audience) do
    secret = :siwa_server |> Application.fetch_env!(:siwa) |> Keyword.fetch!(:receipt_secret)

    {:ok, %{token: token}} =
      Siwa.create_receipt(
        %{
          "typ" => "siwa_wallet_receipt",
          "verified" => "wallet_signature",
          "jti" => Ecto.UUID.generate(),
          "sub" => address,
          "aud" => audience,
          "chain_id" => @chain_id,
          "nonce" => "receipt-#{System.unique_integer([:positive])}",
          "key_id" => address
        },
        receipt_secret: secret,
        ttl_ms: 3_600_000
      )

    token
  end
end
