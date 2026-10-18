defmodule SiwaServer.ReplayWindowPropertyTest do
  use SiwaServer.DataCase, async: false
  use ExUnitProperties

  alias SiwaServer.RuntimeConfig
  alias SiwaServer.Siwa.{HttpVerifier, Wallet}

  @audience "patchbay"
  @path "/v1/agent/bug-report"
  @body ~s({"summary":"window"})

  setup do
    previous = Application.get_env(:siwa_server, :siwa)

    Application.put_env(
      :siwa_server,
      :siwa,
      Keyword.put(previous, :wallet_origins, %{@audience => ["https://patchbay.help"]})
    )

    on_exit(fn -> Application.put_env(:siwa_server, :siwa, previous) end)

    {:ok, signer} = Siwa.LocalSigner.new()
    params = %{"wallet_address" => signer.address, "chain_id" => 8453, "audience" => @audience}
    {:ok, %{"data" => challenge}} = Wallet.issue_nonce(params)
    {:ok, signature} = Siwa.LocalSigner.sign_message(signer, challenge["message"])

    {:ok, %{"data" => %{"receipt" => receipt}}} =
      params
      |> Map.merge(%{
        "nonce" => challenge["nonce"],
        "message" => challenge["message"],
        "signature" => signature
      })
      |> Wallet.verify()

    %{signer: signer, receipt: receipt}
  end

  # A signed request is accepted only while its created time is within the tolerance
  # of now and it has not expired, and then only once. The server reads its own
  # clock, so each run allows the outcome of any second between the run's two
  # clock readings.
  property "a signed request is accepted once inside its window and refused outside it",
           %{signer: signer, receipt: receipt} do
    tolerance = RuntimeConfig.siwa_http_signature_tolerance_seconds()

    check all created_offset <-
                one_of([
                  integer((-tolerance - 3)..(-tolerance + 3)),
                  integer((tolerance - 3)..(tolerance + 3)),
                  integer((-2 * tolerance)..(2 * tolerance))
                ]),
              expires_offset <- one_of([integer(-3..3), integer(-60..600)]),
              max_runs: 150 do
      started = System.os_time(:second)
      created = started + created_offset
      expires = max(started + expires_offset, created + 1)
      request = sign(signer, receipt, created, expires)

      first = HttpVerifier.verify(request, audience: @audience)
      first_read = System.os_time(:second)

      assert outcome(first) in allowed(created, expires, started..first_read, tolerance)

      if outcome(first) == :accepted do
        second = HttpVerifier.verify(request, audience: @audience)
        second_read = System.os_time(:second)

        replays =
          for outcome <- allowed(created, expires, started..second_read, tolerance),
              do: if(outcome == :accepted, do: :replayed, else: outcome)

        assert outcome(second) in replays
      end
    end
  end

  defp sign(signer, receipt, created, expires) do
    {:ok, secret} = RuntimeConfig.siwa_receipt_secret()

    {:ok, signed} =
      Siwa.sign_authenticated_request(
        %{method: "POST", path: @path, body: @body},
        receipt,
        signer,
        receipt_secret: secret,
        audience: @audience,
        wallet_audiences: [@audience],
        created_at: created,
        expires_at: expires
      )

    %{
      "method" => "POST",
      "path" => @path,
      "headers" => signed.headers,
      "body_digest" => Siwa.content_digest_for_body(@body)
    }
  end

  defp allowed(created, expires, seconds, tolerance) do
    seconds
    |> Enum.map(fn now ->
      if created >= now - tolerance and created <= now + tolerance and expires > now,
        do: :accepted,
        else: :refused
    end)
    |> Enum.uniq()
  end

  defp outcome({:ok, %{"code" => "http_envelope_valid"}}), do: :accepted
  defp outcome({:error, {401, "http_signature_invalid", _message}}), do: :refused
  defp outcome({:error, {409, "request_replayed", _message}}), do: :replayed
  defp outcome(other), do: other
end
