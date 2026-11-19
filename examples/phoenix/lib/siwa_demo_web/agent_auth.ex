defmodule SiwaDemoWeb.AgentAuth do
  @moduledoc """
  Lets a request through only when the SIWA service says a signed agent sent it,
  and keeps the service's answer in `conn.assigns.agent`.

  `Siwa.AgentAuthPlug` does the work: it sends the request's method, path, host and
  signed headers to the service through `SiwaDemo.SiwaClient`, then calls the three
  hooks below. Every request is checked by the service, so each answer is current.

  Every refusal answers `{"error": {"code", "message", "hint"}}`. When the agent's
  own request is at fault, it says why. When the trouble is this site's (its key,
  its billing, its limits) or the service cannot answer, the agent only learns that
  it can try again later, and the reason goes to this site's log.
  """

  @behaviour Plug
  @behaviour Siwa.AgentAuthPlug.Hooks

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  require Logger

  @hint "Sign in and sign each request with the SIWA agent client: https://siwa.regents.sh/skill.md"

  # Refusals made here or by the shared plug, before the service is asked.
  @refusals %{
    signature_required: "This needs a signed agent request.",
    duplicate_proof: "A signed header was sent more than once.",
    unsupported_query: "A signed request here takes no query string.",
    missing_signed_body: "A signed request here takes no body."
  }

  # Service refusals about this site and its account, never about the agent's request.
  @site_codes ~w(site_key_invalid site_audience_mismatch site_key_required billing_required
                 agent_cap_reached site_not_verified site_rate_limited verification_unavailable)

  # What the log keeps of such a refusal: never the key or the signed headers.
  @logged [:reason, :siwa_status, :siwa_code, :siwa_message, :transport_error]

  @impl Plug
  def init(opts), do: opts

  # Both routes are GET with no query and no body, so the plug's defaults fit them:
  # a query string or a body is refused before the service is asked.
  @impl Plug
  def call(conn, _opts) do
    Siwa.AgentAuthPlug.call(conn,
      client: SiwaDemo.SiwaClient,
      hooks: __MODULE__,
      audience: Application.fetch_env!(:siwa_demo, :siwa_handle)
    )
  end

  # A request with no signed header at all is refused without asking the service.
  @impl Siwa.AgentAuthPlug.Hooks
  def before_verify(conn, _headers) do
    if Siwa.AgentAuthPlug.signed_request?(conn),
      do: {:ok, nil},
      else: {:error, %{reason: :signature_required, source: :siwa_demo}}
  end

  @impl Siwa.AgentAuthPlug.Hooks
  def accept(conn, data, _context), do: {:ok, assign(conn, :agent, data)}

  @impl Siwa.AgentAuthPlug.Hooks
  def deny(conn, failure) do
    {status, code, message, hint} = refusal(failure)

    if status == 503 do
      Logger.error(
        "SIWA could not check an agent request for this site: " <>
          inspect(Map.take(failure, @logged))
      )
    end

    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message, hint: hint}})
    |> halt()
  end

  defp refusal(%{reason: reason}) when is_map_key(@refusals, reason),
    do: {401, Atom.to_string(reason), Map.fetch!(@refusals, reason), @hint}

  defp refusal(%{siwa_status: status, siwa_code: code, siwa_message: message})
       when status in [400, 401, 409] and code not in @site_codes,
       do: {401, code, message, @hint}

  defp refusal(_failure),
    do:
      {503, "service_unavailable", "This site cannot check agent requests right now.",
       "Try again in a few minutes. The client signs each request fresh."}
end
