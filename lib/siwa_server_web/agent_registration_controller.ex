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
end
