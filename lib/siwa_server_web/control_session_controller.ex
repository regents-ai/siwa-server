defmodule SiwaServerWeb.ControlSessionController do
  @moduledoc """
  A site exchanges its signed-in person's Privy sign-in for a control token
  (`SiwaServerWeb.ControlToken`), so the person is proven here and never taken
  from the site's word. The access token comes only as the bearer and the
  identity token only in `privy-id-token`, so neither reaches a URL, a body or
  a log; `RegentPrivy.Session.verify/2` checks the two together. A refusal is
  logged with the fixed reason the check gave, never a token.
  """

  use SiwaServerWeb, :controller

  require Logger

  alias SiwaServerWeb.ControlToken

  action_fallback SiwaServerWeb.FallbackController

  def create(conn, _params) do
    with {:ok, pair} <- pair(conn),
         {:ok, session} <- verify(pair, conn.assigns.privy) do
      {token, expires_at} = ControlToken.issue(session.privy_user_id)

      json(conn, %{
        "code" => "control_session",
        "data" => %{
          "token" => token,
          "expiresAt" => DateTime.to_iso8601(expires_at),
          "did" => session.privy_user_id
        }
      })
    end
  end

  defp pair(conn) do
    with ["Bearer " <> access] <- get_req_header(conn, "authorization"),
         [identity] <- get_req_header(conn, "privy-id-token") do
      {:ok, %{access: access, identity: identity}}
    else
      _absent_or_repeated -> refused({:request_pair, :missing_token})
    end
  end

  defp verify(pair, privy) do
    case RegentPrivy.Session.verify(pair, privy) do
      {:ok, session} -> {:ok, session}
      {:error, reason} -> refused(reason)
    end
  end

  defp refused({stage, reason}) do
    Logger.info("control session refused stage=#{stage} reason=#{reason}")
    {:error, {401, "privy_proof_invalid", "the Privy sign-in was not accepted"}}
  end
end
