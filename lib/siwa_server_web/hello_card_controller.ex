defmodule SiwaServerWeb.HelloCardController do
  @moduledoc """
  Hello cards (`SiwaServer.HelloCard`) and the keys they are checked with.

  `POST /api/shared/siwa/hello-card` is the agent's own signed request to this
  server, its body exactly `{"pairedOn": "<audience>"}`. While `SIWA_CARD_KEYS`
  is unset it is refused with 503 before anything else; otherwise an audience
  `SIWA_WALLET_ORIGINS` does not name is refused with 404, and the request is
  checked the way `Siwa.AgentAuthPlug` hands a request to the sign-in server:
  its method, path with query, the host it reached, the signed headers in lower
  case, and the digest of the body bytes as received (`SiwaServerWeb.RawBody`).
  """

  use SiwaServerWeb, :controller

  alias SiwaServer.{Config, HelloCard}
  alias SiwaServer.Siwa.HttpVerifier

  action_fallback SiwaServerWeb.FallbackController

  def jwks(conn, _params) do
    conn
    |> put_resp_header("cache-control", "public, max-age=3600")
    |> json(HelloCard.jwks())
  end

  def create(conn, _params) do
    with :ok <- HelloCard.configured(),
         {:ok, paired_on} <- paired_on(conn.body_params),
         {:ok, subject} <- HttpVerifier.verify_own(signed_request(conn), paired_on),
         {:ok, card} <- HelloCard.issue(subject, paired_on) do
      json(conn, %{"code" => "hello_card", "data" => card})
    end
  end

  defp paired_on(%{"pairedOn" => audience} = body)
       when is_binary(audience) and map_size(body) == 1 do
    if Map.has_key?(Config.wallet_origins(), audience),
      do: {:ok, audience},
      else:
        {:error,
         {404, "hello_card_site_unknown", "no Regent site takes hello cards by that name"}}
  end

  defp paired_on(_body),
    do:
      {:error,
       {400, "invalid_request", "the body must be {\"pairedOn\": \"<site>\"} and nothing else"}}

  defp signed_request(conn) do
    headers = Map.new(conn.req_headers, fn {name, value} -> {String.downcase(name), value} end)

    %{
      method: conn.method,
      path: path(conn),
      authority: Siwa.Contract.authority(conn),
      headers: Map.take(headers, Siwa.Contract.forwarded_headers()),
      body_digest: Siwa.RequestAuth.content_digest_for_body(conn.private.raw_body)
    }
  end

  defp path(%Plug.Conn{request_path: path, query_string: ""}), do: path
  defp path(%Plug.Conn{request_path: path, query_string: query}), do: path <> "?" <> query
end
