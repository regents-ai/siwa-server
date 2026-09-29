defmodule SiwaServerWeb.Help do
  @moduledoc """
  The next steps that come with every refusal, written for the agent that got
  it: shaped by the site it was trying to reach and by how it signs.

  The agent client says how it signs in the `x-agent-signer` header when it
  signs in: `own-key` when the client keeps the key, or the name of the agent's
  own signer command, such as `cast`. The header is advice only and is never
  trusted for anything else.
  """

  import Plug.Conn, only: [get_req_header: 2]

  alias SiwaServer.RuntimeConfig

  @guide "https://siwa.regents.sh/skill.md"
  @client "curl -fsSO https://siwa.regents.sh/agent/siwa_agent.py"

  @type context :: %{audience: String.t() | nil, signer: String.t() | nil}

  @doc "What the agent should do next about a refusal with this code."
  @spec hint(String.t(), context()) :: String.t()
  def hint(code, context), do: code |> steps(context) |> IO.iodata_to_binary()

  @doc "The site and signer named by a request, as far as it names them."
  @spec context(Plug.Conn.t()) :: context()
  def context(conn) do
    %{audience: audience(conn), signer: signer(get_req_header(conn, "x-agent-signer"))}
  end

  defp audience(conn) do
    case {get_req_header(conn, "x-siwa-audience"), conn.body_params} do
      {[audience | _rest], _body} -> audience
      {[], %{"audience" => audience}} when is_binary(audience) -> audience
      _unnamed -> nil
    end
  end

  defp signer([value | _rest]) do
    value = value |> String.trim() |> String.downcase()
    if Regex.match?(~r/\A[a-z0-9][a-z0-9._-]{0,39}\z/, value), do: value
  end

  defp signer([]), do: nil

  defp steps(code, _context)
       when code in ~w(nonce_not_found nonce_expired nonce_already_used invalid_nonce message_invalid) do
    [
      "Sign-in challenges work once and last five minutes. Run the command again; ",
      "the client asks for a fresh challenge and signs it straight away."
    ]
  end

  defp steps("signature_invalid", context) do
    ["The signature does not come from the address you gave. ", signing(context.signer)]
  end

  defp steps(code, context) when code in ~w(receipt_invalid receipt_binding_mismatch) do
    [
      "Your sign-in",
      for_site(context.audience),
      " has ended or was made for another site. Run the command again: ",
      "the client signs in afresh for the site in the address you give it."
    ]
  end

  defp steps("receipt_audience_required", _context) do
    [
      "The site did not say who it is, so this is the site's problem, not yours. ",
      "Tell your person which site answered this."
    ]
  end

  defp steps(code, _context)
       when code in ~w(http_headers_missing http_required_components_missing http_signature_input_invalid http_signature_invalid) do
    [
      "The request's signature headers are missing, too old or malformed. Send it with ",
      "`uv run siwa_agent.py request METHOD URL`, which signs each request fresh, ",
      "just before sending. Each signature works once, for two minutes."
    ]
  end

  defp steps(code, _context)
       when code in ~w(http_body_binding_missing http_body_binding_invalid) do
    [
      "The body that arrived is not the body you signed. Pass the exact body to ",
      "`request --body` and send it unchanged: no reformatting, re-encoding or added spaces."
    ]
  end

  defp steps("request_replayed", _context) do
    [
      "That signed request was already used; each one works once. Run `request` again ",
      "to sign it fresh, and never resend saved signature headers."
    ]
  end

  defp steps("wallet_audience_disabled", context) do
    [
      site_name(context.audience),
      " does not accept agent sign-in. The sites that do: ",
      open_sites(),
      ". Tell your person if you expected this one to."
    ]
  end

  defp steps(code, _context)
       when code in ~w(signature_lookup_failed agent_registration_lookup_failed) do
    [
      "Base could not be read just now to check your wallet. Wait a minute, then run ",
      "the command again. If it keeps happening, tell your person."
    ]
  end

  defp steps("rate_limited", _context) do
    "Too many requests from you in a short time. Wait the seconds in Retry-After, then run the command again."
  end

  defp steps("invalid_request", _context) do
    [
      "Your client sent a request this service does not accept. Get the current client ",
      "with `",
      @client,
      "`, then run the step again as ",
      @guide,
      " describes."
    ]
  end

  defp steps(code, _context)
       when code in ~w(transaction_not_registration registration_reverted) do
    [
      "That transaction did not register an agent. Check the transaction hash you sent, ",
      "and that the registration succeeded on Base, then send it again."
    ]
  end

  defp steps(code, _context)
       when code in ~w(activity_read_unauthorized invalid_activity_request) do
    "This request is for Regent sites, not agents."
  end

  defp steps(_code, _context) do
    [
      "The sign-in service had a problem on its side. Wait a minute and try again. ",
      "If it keeps happening, tell your person."
    ]
  end

  defp signing("own-key") do
    [
      "The client keeps your key, so the key file may have changed since you signed in. ",
      "Run `uv run siwa_agent.py whoami` and check the address is the one you expect."
    ]
  end

  defp signing("cast") do
    [
      "Your signer is `cast`: it must sign the exact text as a personal message, ",
      "for example `cast wallet sign --account <name> \"$SIWA_MESSAGE\"`, ",
      "without `--no-hash` and not as typed data. Check that `use-wallet` names the ",
      "address of that same account."
    ]
  end

  defp signing(nil) do
    [
      "Sign the exact text as an Ethereum personal message (EIP-191): not a hash of it ",
      "and not typed data, with the key of the address you gave. ",
      @guide,
      " shows how."
    ]
  end

  defp signing(signer) do
    [
      "Your signer command (",
      signer,
      ") must sign the exact text in $SIWA_MESSAGE as an Ethereum personal message and ",
      "print the 0x signature: not a hash of it and not typed data. Check that ",
      "`use-wallet` names the address of the key it signs with."
    ]
  end

  defp for_site(nil), do: ""
  defp for_site(audience), do: [" for ", site_name(audience)]

  defp site_name(nil), do: "This site"

  defp site_name(audience) do
    case RuntimeConfig.siwa_wallet_origins() do
      %{^audience => origin} -> origin
      _closed -> audience
    end
  end

  defp open_sites do
    RuntimeConfig.siwa_wallet_origins()
    |> Map.values()
    |> Enum.sort()
    |> Enum.join(", ")
  end
end
