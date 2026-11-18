defmodule SiwaDemoWeb.AgentController do
  @moduledoc """
  The two routes for agents. Each says only what the SIWA service answered for this
  one request (`conn.assigns.agent`, set by `SiwaDemoWeb.AgentAuth`); nothing is
  stored.
  """

  use Phoenix.Controller, formats: [:json]

  import Plug.Conn

  @list_yourself "List yourself in the agent registry with: " <>
                   ~s(uv run siwa_agent.py register-agent --name "<your name>" --description "<what you do>". ) <>
                   "Listed already with another tool? Link that listing with: " <>
                   "uv run siwa_agent.py link-agent --agent-id <id>. " <>
                   "Then ask again. Guide: https://siwa.regents.sh/skill.md"

  def hello(conn, _params) do
    agent = conn.assigns.agent
    usage = agent["usage"]

    answer = %{
      caller: agent["subject"],
      wallet: agent["walletAddress"],
      listing: listing(agent["agentRegistration"]),
      person: person(agent["agentBook"]),
      message: greeting(usage)
    }

    json(conn, returning(answer, usage))
  end

  def lounge(conn, _params) do
    case conn.assigns.agent["agentRegistration"] do
      %{"agentId" => agent_id} ->
        json(conn, %{agentId: agent_id, message: "Welcome to the lounge."})

      nil ->
        conn
        |> put_status(:forbidden)
        |> json(%{
          error: %{
            code: "listing_required",
            message: "The lounge is open only to agents with a listing in the agent registry.",
            hint: @list_yourself
          }
        })
    end
  end

  defp listing(%{"agentId" => agent_id, "profileUrl" => profile_url}),
    do: %{agentId: agent_id, profileUrl: profile_url}

  defp listing(nil), do: nil

  # How many agents the person backs, never which person.
  defp person(%{"agentCount" => agent_count}), do: %{agentCount: agent_count}
  defp person(nil), do: nil

  # A practice site's answer has no usage: it counts no visits.
  defp returning(answer, %{"newThisPeriod" => new?}), do: Map.put(answer, :returning, not new?)
  defp returning(answer, nil), do: answer

  defp greeting(%{"newThisPeriod" => true}), do: "Hello, nice to meet you."
  defp greeting(%{"newThisPeriod" => false}), do: "Welcome back."
  defp greeting(nil), do: "Hello. A practice site counts no visits, so it cannot tell a return."
end
