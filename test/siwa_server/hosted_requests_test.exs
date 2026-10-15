defmodule SiwaServer.HostedRequestsTest do
  use SiwaServer.DataCase, async: false

  alias SiwaServer.{HostedRequests, RuntimeConfig}
  alias SiwaServer.Siwa.HttpVerifier
  alias SiwaServerWeb.Endpoint

  test "the hosted signer endpoint requires fresh one-use internal HMAC proof" do
    path = "/api/shared/keyring/hosted"
    body = Jason.encode!(%{operation: "register", identity_key: String.duplicate("a", 64)})
    opts = SiwaKeyring.Router.init([])

    request =
      Plug.Test.conn(:post, path, body)
      |> Plug.Conn.put_req_header("content-type", "application/json")

    assert SiwaKeyring.Router.call(request, opts).status == 401

    headers =
      SiwaKeyring.Auth.compute_hmac(
        Application.fetch_env!(:siwa_keyring, :secret),
        "POST",
        path,
        body
      )

    signed =
      Enum.reduce(headers, request, fn {key, value}, conn ->
        Plug.Conn.put_req_header(conn, key, value)
      end)

    assert SiwaKeyring.Router.call(signed, opts).status == 200
    assert SiwaKeyring.Router.call(signed, opts).status == 401
  end

  setup do
    previous = Application.get_env(:siwa_keyring, :path)
    previous_siwa = Application.get_env(:siwa_server, :siwa)
    path = Path.join(System.tmp_dir!(), "hosted-siwa-test-" <> Ecto.UUID.generate())
    Application.put_env(:siwa_keyring, :path, path)

    Application.put_env(
      :siwa_server,
      :siwa,
      Keyword.put(previous_siwa, :wallet_origins, %{"patchbay" => "https://patchbay.help"})
    )

    on_exit(fn ->
      Application.put_env(:siwa_keyring, :path, previous)
      Application.put_env(:siwa_server, :siwa, previous_siwa)
      File.rm_rf!(path <> ".hosted")
    end)

    %{identity: :crypto.hash(:sha256, Ecto.UUID.generate()) |> Base.encode16(case: :lower)}
  end

  test "the same account connection reuses its key and never exports it", %{identity: identity} do
    request = %{"operation" => "register", "identity_key" => identity}
    {:ok, first} = HostedRequests.handle(request)
    {:ok, second} = HostedRequests.handle(request)
    assert first == second
    assert Map.keys(first) == [:address]
    other = :crypto.hash(:sha256, "other-account") |> Base.encode16(case: :lower)
    {:ok, third} = HostedRequests.handle(%{request | "identity_key" => other})
    assert first != third
  end

  test "free participation proof is verified by SIWA and binds the exact body", %{
    identity: identity
  } do
    {:ok, _} = HostedRequests.handle(%{"operation" => "register", "identity_key" => identity})

    body =
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: %{
          name: "post_reply",
          arguments: %{thread_id: Ecto.UUID.generate(), body_markdown: "Local fixture"}
        }
      })

    {:ok, signed} =
      HostedRequests.handle(%{
        "operation" => "sign",
        "identity_key" => identity,
        "audience" => "patchbay",
        "request" => %{"method" => "POST", "path" => "/chatgpt/agent/mcp", "body" => body}
      })

    {:ok, secret} = RuntimeConfig.siwa_receipt_secret()
    opts = [receipt_secret: secret, audience: "patchbay", wallet_audiences: ["patchbay"]]
    digest = Siwa.content_digest_for_body(body)
    envelope = signed |> Map.delete(:body) |> Map.put(:body_digest, digest)
    assert match?({:ok, _}, Siwa.verify_authenticated_request(envelope, opts))

    assert match?(
             {:error, _},
             Siwa.verify_authenticated_request(
               %{envelope | body_digest: Siwa.content_digest_for_body(body <> " ")},
               opts
             )
           )

    assert match?(
             {:error, _},
             Siwa.verify_authenticated_request(
               envelope,
               Keyword.put(opts, :audience, "ash-template")
             )
           )

    # Exercise the actual service adapter, including the canonical replay store.
    params = Map.new(envelope, fn {key, value} -> {to_string(key), value} end)

    assert match?(
             {:error, {401, _, _}},
             HttpVerifier.verify(
               %{params | "body_digest" => Siwa.content_digest_for_body(body <> " ")},
               audience: "patchbay"
             )
           )

    verified =
      Plug.Test.conn(:post, "/api/shared/siwa/http-verify", Jason.encode!(params))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("x-siwa-audience", "patchbay")
      |> Endpoint.call(Endpoint.init([]))

    assert verified.status == 200
    assert get_in(Jason.decode!(verified.resp_body), ["data", "verified"]) == true

    assert match?(
             {:error, {409, _, _}},
             HttpVerifier.verify(params, audience: "patchbay")
           )
  end

  test "arbitrary signing and unsupported paths cannot reach a signer", %{
    identity: identity
  } do
    for request <- [
          %{"method" => "POST", "path" => "/admin/actions", "body" => "{}"},
          %{"method" => "POST", "path" => "/mcp", "body" => "{}"},
          %{
            "method" => "POST",
            "path" => "/chatgpt/agent/mcp",
            "body" =>
              Jason.encode!(%{
                jsonrpc: "2.0",
                method: "tools/call",
                params: %{name: "mark_solution", arguments: %{}}
              })
          }
        ] do
      assert HostedRequests.handle(%{
               "operation" => "sign",
               "identity_key" => identity,
               "audience" => "patchbay",
               "request" => request
             }) == {:error, :hosted_request_not_allowed}
    end

    assert HostedRequests.handle(%{"operation" => "sign-message", "identity_key" => identity}) ==
             {:error, :hosted_request_not_allowed}

    assert match?({:error, _}, SiwaKeyring.HostedIdentity.ensure("../outside"))
  end
end
