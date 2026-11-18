defmodule SiwaDemo.SiwaClient do
  @moduledoc """
  Asks the SIWA service whether one signed agent request is good, with this site's
  server key.

  A redirect is not followed, so the key goes only to the service.
  """

  @behaviour Siwa.AgentAuthPlug.Client

  @impl true
  def verify_http_request(payload, opts) do
    Req.post(
      Application.fetch_env!(:siwa_demo, :siwa_service) <> Siwa.AgentAuthPlug.http_verify_path(),
      json: payload,
      auth: {:bearer, Application.fetch_env!(:siwa_demo, :siwa_server_key)},
      headers: [{"x-siwa-audience", Keyword.fetch!(opts, :audience)}],
      redirect: false
    )
  end
end
