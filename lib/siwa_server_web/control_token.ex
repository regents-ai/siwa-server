defmodule SiwaServerWeb.ControlToken do
  @moduledoc """
  The token the control API answers to: a `Phoenix.Token` signed with the
  endpoint's secret, carrying only the person's Privy DID, good for 15 minutes.
  A Regent site gets one for its signed-in person by showing their Privy
  sign-in (`SiwaServerWeb.ControlSessionController`).
  """

  alias SiwaServerWeb.Endpoint

  @salt "siwa control token"
  @max_age 900

  @doc "A token for `did`, signed at `now` (unix seconds), and when it expires."
  @spec issue(String.t(), integer()) :: {String.t(), DateTime.t()}
  def issue(did, now \\ System.system_time(:second)) do
    {Phoenix.Token.sign(Endpoint, @salt, did, signed_at: now),
     DateTime.from_unix!(now + @max_age)}
  end

  @doc "The Privy DID a token names, while it lasts."
  @spec verify(String.t()) :: {:ok, String.t()} | :error
  def verify(token) do
    case Phoenix.Token.verify(Endpoint, @salt, token, max_age: @max_age) do
      {:ok, did} -> {:ok, did}
      {:error, _invalid_or_expired} -> :error
    end
  end
end
