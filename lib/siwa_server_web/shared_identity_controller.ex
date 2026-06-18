defmodule SiwaServerWeb.SharedIdentityController do
  use SiwaServerWeb, :controller

  alias SiwaServer.SharedIdentity

  action_fallback SiwaServerWeb.FallbackController

  def status(conn, params) do
    with {:ok, payload} <- SharedIdentity.status(params) do
      json(conn, payload)
    end
  end

  def registration_intent(conn, params) do
    with {:ok, payload} <- SharedIdentity.create_registration_intent(params) do
      json(conn, payload)
    end
  end

  def registration_completion(conn, params) do
    with {:ok, payload} <- SharedIdentity.complete_registration(params) do
      json(conn, payload)
    end
  end

  def siwa_nonce(conn, params) do
    with {:ok, payload} <- SharedIdentity.create_siwa_nonce(params) do
      json(conn, payload)
    end
  end

  def siwa_verify(conn, params) do
    with {:ok, payload} <- SharedIdentity.verify_siwa(params) do
      json(conn, payload)
    end
  end
end
