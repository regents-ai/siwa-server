defmodule SiwaServerWeb.AgentRegistrationController do
  use SiwaServerWeb, :controller

  alias SiwaServer.AgentRegistration

  action_fallback SiwaServerWeb.FallbackController

  def register_step(conn, params) do
    with {:ok, payload} <- AgentRegistration.step(params), do: json(conn, payload)
  end

  def registered(conn, params) do
    with {:ok, payload} <- AgentRegistration.outcome(params), do: json(conn, payload)
  end

  def link_challenge(conn, params) do
    with {:ok, payload} <- AgentRegistration.link_challenge(params), do: json(conn, payload)
  end

  def link(conn, params) do
    with {:ok, payload} <- AgentRegistration.link(params), do: json(conn, payload)
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
