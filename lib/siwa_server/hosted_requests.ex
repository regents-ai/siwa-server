defmodule SiwaServer.HostedRequests do
  @moduledoc """
  Signing for an account's persistent hosted connection (Patchbay's ChatGPT app,
  Keyfleet's Claude connector), asked for by a site with its own hosted signing key
  (`SiwaServer.HostedSigners`).

  The calling site is the audience of everything signed, and each connection's
  key belongs to the site that registered it: the stored signer is named from
  the site and the site's connection key together, so one site cannot reach
  another site's connections. Keys stay in the encrypted SIWA key store. This
  service signs only each site's identity reads and pairing (for its own harness),
  and Patchbay's free participation; never arbitrary messages, transactions or
  payment requests. Products still
  verify every resulting request through the ordinary SIWA verifier and apply
  their own permissions.
  """

  alias SiwaServer.RuntimeConfig
  alias SiwaServer.Siwa.Wallet

  def handle(site, %{"operation" => "register", "identity_key" => key} = params)
      when map_size(params) == 2 do
    with {:ok, identity} <- identity(site, key) do
      SiwaKeyring.HostedIdentity.ensure(identity)
    end
  end

  def handle(
        site,
        %{"operation" => "sign", "identity_key" => key, "request" => request} = params
      )
      when map_size(params) == 3 do
    with :ok <- allowed_request(site, request),
         {:ok, identity} <- identity(site, key),
         {:ok, signer} <- SiwaKeyring.HostedIdentity.signer(identity),
         {:ok, address} <- Siwa.RemoteSigner.get_address(signer),
         {:ok, receipt} <- receipt(signer, address, site),
         {:ok, secret} <- RuntimeConfig.siwa_receipt_secret() do
      Siwa.sign_authenticated_request(
        %{method: request["method"], path: request["path"], body: request["body"], headers: %{}},
        receipt,
        signer,
        receipt_secret: secret,
        audience: site,
        wallet_audiences: Map.keys(RuntimeConfig.siwa_wallet_origins())
      )
    end
  end

  def handle(_site, _params), do: {:error, :hosted_request_not_allowed}

  defp identity(site, key) when is_binary(key) do
    if Regex.match?(~r/\A[a-f0-9]{64}\z/, key) do
      {:ok, :crypto.hash(:sha256, site <> "\n" <> key) |> Base.encode16(case: :lower)}
    else
      {:error, :hosted_request_not_allowed}
    end
  end

  defp identity(_site, _key), do: {:error, :hosted_request_not_allowed}

  @identity_reads %{
    "patchbay" => ["/api/agents/v1/whoami"],
    "keyfleet" => ["/api/agents/v1/whoami", "/api/agents/v1/me"]
  }
  @pair_harness %{"patchbay" => "chatgpt", "keyfleet" => "claude"}

  defp allowed_request(site, %{"method" => "GET", "path" => path} = r)
       when map_size(r) == 2 do
    if path in Map.get(@identity_reads, site, []),
      do: :ok,
      else: {:error, :hosted_request_not_allowed}
  end

  defp allowed_request(
         site,
         %{
           "method" => "POST",
           "path" => "/api/agents/v1/pair",
           "body" => body
         } = r
       )
       when map_size(r) == 3 and is_map_key(@pair_harness, site) do
    harness = Map.fetch!(@pair_harness, site)

    with {:ok, %{"code" => code, "name" => name, "harness" => ^harness} = args} <- decode(body),
         true <- map_size(args) == 3 and is_binary(code) and byte_size(code) in 1..128,
         true <- is_binary(name) and String.length(name) in 1..100 do
      :ok
    else
      _ -> {:error, :hosted_request_not_allowed}
    end
  end

  defp allowed_request(
         "patchbay",
         %{
           "method" => "POST",
           "path" => "/chatgpt/agent/mcp",
           "body" => body
         } = r
       )
       when map_size(r) == 3 do
    with {:ok,
          %{
            "jsonrpc" => "2.0",
            "method" => "tools/call",
            "params" => %{"name" => name, "arguments" => args} = params
          } = message} <- decode(body),
         true <- Map.keys(message) -- ~w(jsonrpc id method params) == [],
         true <- map_size(params) == 2 and is_map(args) and not is_struct(args),
         true <- name in ["ask_question", "post_reply"] do
      :ok
    else
      _ -> {:error, :hosted_request_not_allowed}
    end
  end

  defp allowed_request(_, _), do: {:error, :hosted_request_not_allowed}

  # A body naming one key twice is refused: the check reads the first copy, and a site
  # reading the last would act on something that was never checked.
  defp decode(body) when is_binary(body) and byte_size(body) <= 32_768 do
    with {:ok, ordered} <- Jason.decode(body, objects: :ordered_objects),
         true <- unique_keys?(ordered) do
      Jason.decode(body)
    else
      _ -> {:error, :hosted_request_not_allowed}
    end
  end

  defp decode(_), do: {:error, :hosted_request_not_allowed}

  defp unique_keys?(%Jason.OrderedObject{values: values}) do
    keys = Enum.map(values, &elem(&1, 0))
    keys == Enum.uniq(keys) and Enum.all?(values, fn {_key, value} -> unique_keys?(value) end)
  end

  defp unique_keys?(list) when is_list(list), do: Enum.all?(list, &unique_keys?/1)
  defp unique_keys?(_value), do: true

  defp receipt(signer, address, audience) do
    fields = %{"wallet_address" => address, "chain_id" => 8453, "audience" => audience}

    with {:ok, %{"data" => challenge}} <- Wallet.issue_nonce(fields),
         {:ok, signature} <- Siwa.RemoteSigner.sign_message(signer, challenge["message"]),
         {:ok, %{"data" => %{"receipt" => receipt}}} <-
           Wallet.verify(
             Map.merge(fields, %{
               "nonce" => challenge["nonce"],
               "message" => challenge["message"],
               "signature" => signature
             })
           ) do
      {:ok, receipt}
    end
  end
end
