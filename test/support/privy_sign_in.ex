defmodule SiwaServer.PrivySignIn do
  @moduledoc """
  Privy sign-ins for tests: an access token and an identity token signed as
  Privy signs them (ES256), with a key made for the test, and the control API
  pointed at that key.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  @app_id "siwa-test-privy-app"

  def app_id, do: @app_id

  @doc "Makes a signing key and gives the control API its public half, until the test ends."
  def configure do
    key = JOSE.JWK.generate_key({:ec, "P-256"})
    {_kty, pem} = key |> JOSE.JWK.to_public() |> JOSE.JWK.to_pem()
    put_privy(app_id: @app_id, verification_key: pem)
    key
  end

  @doc "Leaves the control API without Privy settings until the test ends."
  def unconfigure, do: put_privy(app_id: nil, verification_key: nil)

  @doc """
  The `{access, identity}` tokens of one sign-in by `did`. `:access` and
  `:identity` replace claims in either token.
  """
  def tokens(key, did, changes \\ []) do
    now = System.system_time(:second)

    claims = %{
      "iss" => "privy.io",
      "aud" => @app_id,
      "sub" => did,
      "sid" => "privy-session-1",
      "iat" => now,
      "exp" => now + 3_600
    }

    access = Map.merge(claims, Keyword.get(changes, :access, %{}))

    identity =
      claims
      |> Map.put("linked_accounts", "[]")
      |> Map.merge(Keyword.get(changes, :identity, %{}))

    {sign(key, access), sign(key, identity)}
  end

  defp sign(key, claims),
    do: key |> JOSE.JWT.sign(%{"alg" => "ES256"}, claims) |> JOSE.JWS.compact() |> elem(1)

  defp put_privy(privy) do
    previous = Application.fetch_env!(:siwa_server, :privy)
    Application.put_env(:siwa_server, :privy, privy)
    on_exit(fn -> Application.put_env(:siwa_server, :privy, previous) end)
  end
end
