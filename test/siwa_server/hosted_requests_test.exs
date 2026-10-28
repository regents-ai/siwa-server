defmodule SiwaServer.HostedRequestsTest do
  use SiwaServer.DataCase, async: false

  alias SiwaServer.{HostedRequests, RuntimeConfig}
  alias SiwaServer.Siwa.HttpVerifier
  alias SiwaServerWeb.Endpoint

  setup do
    previous = Application.get_env(:siwa_keyring, :path)
    previous_siwa = Application.get_env(:siwa_server, :siwa)
    path = Path.join(System.tmp_dir!(), "hosted-siwa-test-" <> Ecto.UUID.generate())
    Application.put_env(:siwa_keyring, :path, path)

    Application.put_env(
      :siwa_server,
      :siwa,
      Keyword.put(previous_siwa, :wallet_origins, %{
        "patchbay" => ["https://patchbay.help"],
        "keyfleet" => ["https://keyfleet.ai"]
      })
    )

    on_exit(fn ->
      Application.put_env(:siwa_keyring, :path, previous)
      Application.put_env(:siwa_server, :siwa, previous_siwa)
      File.rm_rf!(path <> ".hosted")
    end)

    %{identity: :crypto.hash(:sha256, Ecto.UUID.generate()) |> Base.encode16(case: :lower)}
  end

  test "the hosted endpoint signs only for the site whose own hosted key is presented", %{
    identity: identity
  } do
    body = Jason.encode!(%{operation: "register", identity_key: identity})

    post = fn authorization ->
      conn =
        Plug.Test.conn(:post, "/api/shared/siwa/hosted", body)
        |> Plug.Conn.put_req_header("content-type", "application/json")

      conn =
        if authorization,
          do: Plug.Conn.put_req_header(conn, "authorization", authorization),
          else: conn

      Endpoint.call(conn, Endpoint.init([]))
    end

    assert post.(nil).status == 401
    assert post.("Bearer siwa-test-patchbay-activity-read-key-1").status == 401

    for site <- ["patchbay", "keyfleet"] do
      signed = post.("Bearer siwa-test-#{site}-hosted-signing-key-1")
      assert signed.status == 200
      {:ok, expected} = HostedRequests.handle(site, Jason.decode!(body))
      assert Jason.decode!(signed.resp_body) == %{"address" => expected.address}
    end

    refute Jason.decode!(post.("Bearer siwa-test-patchbay-hosted-signing-key-1").resp_body) ==
             Jason.decode!(post.("Bearer siwa-test-keyfleet-hosted-signing-key-1").resp_body)
  end

  test "an account connection reuses its key, never exports it, and belongs to one site", %{
    identity: identity
  } do
    request = %{"operation" => "register", "identity_key" => identity}
    {:ok, first} = HostedRequests.handle("patchbay", request)
    {:ok, second} = HostedRequests.handle("patchbay", request)
    assert first == second
    assert Map.keys(first) == [:address]
    other = :crypto.hash(:sha256, "other-account") |> Base.encode16(case: :lower)
    {:ok, third} = HostedRequests.handle("patchbay", %{request | "identity_key" => other})
    assert first != third
    {:ok, keyfleet} = HostedRequests.handle("keyfleet", request)
    assert first != keyfleet
  end

  test "free participation proof is verified by SIWA and binds the exact body", %{
    identity: identity
  } do
    {:ok, _} =
      HostedRequests.handle("patchbay", %{"operation" => "register", "identity_key" => identity})

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
      HostedRequests.handle("patchbay", %{
        "operation" => "sign",
        "identity_key" => identity,
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
               Keyword.put(opts, :audience, "keyfleet")
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
      |> SiwaServerWeb.ConnCase.put_site_verify_key("patchbay")
      |> Endpoint.call(Endpoint.init([]))

    assert verified.status == 200
    assert get_in(Jason.decode!(verified.resp_body), ["data", "verified"]) == true

    assert match?(
             {:error, {409, _, _}},
             HttpVerifier.verify(params, audience: "patchbay")
           )
  end

  test "each site signs only its own identity reads and pairing for its own harness", %{
    identity: identity
  } do
    pair = fn harness ->
      %{
        "method" => "POST",
        "path" => "/api/agents/v1/pair",
        "body" => Jason.encode!(%{code: "ABCD-1234", name: "Claude", harness: harness})
      }
    end

    whoami = %{"method" => "GET", "path" => "/api/agents/v1/whoami"}
    me = %{"method" => "GET", "path" => "/api/agents/v1/me"}

    sign = fn site, request ->
      {:ok, _} =
        HostedRequests.handle(site, %{"operation" => "register", "identity_key" => identity})

      HostedRequests.handle(site, %{
        "operation" => "sign",
        "identity_key" => identity,
        "request" => request
      })
    end

    for {site, request} <- [
          {"keyfleet", whoami},
          {"keyfleet", me},
          {"keyfleet", pair.("claude")},
          {"patchbay", whoami},
          {"patchbay", pair.("chatgpt")}
        ] do
      assert {:ok, signed} = sign.(site, request)

      {:ok, secret} = RuntimeConfig.siwa_receipt_secret()

      envelope =
        signed
        |> Map.delete(:body)
        |> Map.put(:body_digest, request["body"] && Siwa.content_digest_for_body(request["body"]))

      assert match?(
               {:ok, _},
               Siwa.verify_authenticated_request(envelope,
                 receipt_secret: secret,
                 audience: site,
                 wallet_audiences: [site]
               )
             )
    end

    for {site, request} <- [
          {"keyfleet", pair.("chatgpt")},
          {"patchbay", pair.("claude")},
          {"patchbay", me},
          {"keyfleet", Map.put(whoami, "body", "")},
          {"keyfleet", %{whoami | "path" => "/api/agents/v1/whoami/"}},
          {"keyfleet", %{me | "method" => "POST"}},
          {"regents", whoami},
          {"regents", pair.("claude")},
          {"keyfleet",
           %{
             pair.("claude")
             | "body" =>
                 Jason.encode!(%{code: "ABCD-1234", name: "Claude", harness: "claude", extra: 1})
           }},
          {"keyfleet",
           %{
             pair.("claude")
             | "body" => Jason.encode!(%{code: "", name: "Claude", harness: "claude"})
           }},
          {"keyfleet",
           %{
             pair.("claude")
             | "body" =>
                 ~s({"code":"ABCD-1234","name":"Claude","harness":"claude","harness":"chatgpt"})
           }},
          {"keyfleet",
           %{
             pair.("claude")
             | "body" =>
                 Jason.encode!(%{
                   code: "ABCD-1234",
                   name: String.duplicate("a", 101),
                   harness: "claude"
                 })
           }}
        ] do
      assert sign.(site, request) == {:error, :hosted_request_not_allowed}
    end
  end

  test "arbitrary signing, unsupported paths and another site's routes cannot reach a signer", %{
    identity: identity
  } do
    for {site, request} <- [
          {"patchbay", %{"method" => "POST", "path" => "/admin/actions", "body" => "{}"}},
          {"patchbay", %{"method" => "POST", "path" => "/mcp", "body" => "{}"}},
          {"patchbay",
           %{
             "method" => "POST",
             "path" => "/chatgpt/agent/mcp",
             "body" =>
               Jason.encode!(%{
                 jsonrpc: "2.0",
                 method: "tools/call",
                 params: %{name: "mark_solution", arguments: %{}}
               })
           }},
          {"patchbay",
           %{
             "method" => "POST",
             "path" => "/chatgpt/agent/mcp",
             "body" =>
               ~s({"jsonrpc":"2.0","method":"tools/call","params":{"name":"post_reply",) <>
                 ~s("arguments":{"thread_id":"a","body_markdown":"b","body_markdown":"c"}}})
           }},
          {"keyfleet",
           %{
             "method" => "POST",
             "path" => "/chatgpt/agent/mcp",
             "body" =>
               Jason.encode!(%{
                 jsonrpc: "2.0",
                 method: "tools/call",
                 params: %{name: "post_reply", arguments: %{}}
               })
           }}
        ] do
      assert HostedRequests.handle(site, %{
               "operation" => "sign",
               "identity_key" => identity,
               "request" => request
             }) == {:error, :hosted_request_not_allowed}
    end

    assert HostedRequests.handle("patchbay", %{
             "operation" => "sign-message",
             "identity_key" => identity
           }) == {:error, :hosted_request_not_allowed}

    assert HostedRequests.handle("patchbay", %{
             "operation" => "register",
             "identity_key" => "../outside"
           }) == {:error, :hosted_request_not_allowed}
  end
end
