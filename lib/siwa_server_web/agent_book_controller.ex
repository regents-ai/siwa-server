defmodule SiwaServerWeb.AgentBookController do
  use SiwaServerWeb, :controller

  alias SiwaServer.AgentBook
  action_fallback SiwaServerWeb.FallbackController

  def challenge(conn, params) do
    with {:ok, payload} <- AgentBook.challenge(params), do: json(conn, payload)
  end

  def accept(conn, params) do
    with {:ok, payload} <- AgentBook.accept(params), do: json(conn, payload)
  end
end
