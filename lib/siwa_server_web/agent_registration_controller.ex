defmodule SiwaServerWeb.AgentRegistrationController do
  use SiwaServerWeb, :controller

  alias SiwaServer.AgentRegistration
  alias SiwaServerWeb.AgentSiwaRequest

  action_fallback SiwaServerWeb.FallbackController

  def register_step(conn, params) do
    with {:ok, request} <- AgentSiwaRequest.cast_register_step(params),
         {:ok, payload} <- AgentRegistration.step(Map.from_struct(request)) do
      json(conn, payload)
    end
  end

  def registered(conn, params) do
    with {:ok, request} <- AgentSiwaRequest.cast_registered(params),
         {:ok, payload} <- AgentRegistration.outcome(Map.from_struct(request)) do
      json(conn, payload)
    end
  end

  # The registration file explorers and other sites read, so any page may fetch it.
  def profile(conn, %{"profile_id" => profile_id}) do
    case AgentRegistration.profile(profile_id) do
      {:ok, file} ->
        conn
        |> put_resp_header("access-control-allow-origin", "*")
        |> json(file)

      :error ->
        {:error, {404, "agent_profile_not_found", "no registered agent has this profile"}}
    end
  end
end
