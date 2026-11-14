defmodule SiwaServerWeb.AgentSiwaController do
  use SiwaServerWeb, :controller

  alias SiwaServer.Siwa.HttpVerifier

  action_fallback SiwaServerWeb.FallbackController

  # A site that sends `Authorization` asks with its server key; one that does
  # not, with its audience alone (`SiwaServer.Siwa.HttpVerifier`).
  def http_verify(conn, params) do
    with {:ok, payload} <- verify(conn, params), do: json(conn, payload)
  end

  defp verify(conn, params) do
    case get_req_header(conn, "authorization") do
      [] ->
        with {:ok, audience} <- audience(conn), do: HttpVerifier.verify(params, audience)

      [authorization | _rest] ->
        HttpVerifier.verify_for_key(params, bearer(authorization), named_audience(conn))
    end
  end

  # Anything but a bearer is no key, and is refused as one that matches no site.
  defp bearer("Bearer " <> key), do: String.trim(key)
  defp bearer(_not_a_bearer), do: ""

  defp audience(conn) do
    case named_audience(conn) do
      nil -> {:error, {401, "receipt_audience_required", "request audience is required"}}
      audience -> {:ok, audience}
    end
  end

  defp named_audience(conn) do
    with [value | _rest] <- get_req_header(conn, "x-siwa-audience"),
         audience when audience != "" <- String.trim(value) do
      audience
    else
      _missing -> nil
    end
  end
end
