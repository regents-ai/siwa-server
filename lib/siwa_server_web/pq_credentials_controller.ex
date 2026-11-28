defmodule SiwaServerWeb.PqCredentialsController do
  use SiwaServerWeb, :controller

  alias SiwaServer.PostQuantum.Credentials

  action_fallback SiwaServerWeb.FallbackController

  def enroll_challenge(conn, params) do
    with {:ok, payload} <- Credentials.issue_enrollment_challenge(params) do
      json(conn, payload)
    end
  end

  def enroll(conn, params) do
    with {:ok, payload} <- Credentials.enroll(params) do
      json(conn, payload)
    end
  end
end
