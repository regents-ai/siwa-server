defmodule SiwaServerWeb.WalletSiwaController do
  use SiwaServerWeb, :controller

  alias SiwaServer.Siwa.Wallet
  action_fallback SiwaServerWeb.FallbackController

  def nonce(conn, params) do
    with {:ok, payload} <- Wallet.issue_nonce(params), do: json(conn, payload)
  end

  def verify(conn, params) do
    with {:ok, payload} <- Wallet.verify(params), do: json(conn, payload)
  end
end
