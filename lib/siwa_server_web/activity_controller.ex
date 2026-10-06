defmodule SiwaServerWeb.ActivityController do
  @moduledoc """
  Lets a Regents site read one wallet's recent verified requests, 20 at a time
  with a cursor for the next 20, so a person can see what their agent has been
  doing across the sites. The answer also names the wallet's newest agent
  registry listing made through this server, so the site can link to it, and the
  World ID-verified person AgentBook last named behind it, if any.
  Only callers holding the activity read token may read it.
  """

  use SiwaServerWeb, :controller

  alias SiwaServer.{AgentBook, AgentRegistration, RuntimeConfig}
  alias SiwaServer.Siwa.ActivityStore

  action_fallback SiwaServerWeb.FallbackController

  @address ~r/^0x[0-9a-fA-F]{40}$/

  def read(conn, params) do
    with :ok <- authorize(conn),
         {:ok, wallet_address, since, start} <- cast(params),
         {:ok, entries, next} <- page(wallet_address, since, start) do
      activity =
        Enum.map(entries, &Map.update!(&1, :occurred_at, fn at -> DateTime.to_iso8601(at) end))

      json(conn, %{
        data: %{
          activity: activity,
          next: next,
          agentRegistration: AgentRegistration.latest(wallet_address),
          agentBook: AgentBook.human(wallet_address)
        }
      })
    end
  end

  defp authorize(conn) do
    expected = "Bearer " <> RuntimeConfig.siwa_activity_read_token()

    case get_req_header(conn, "authorization") do
      [presented] ->
        if Plug.Crypto.secure_compare(presented, expected), do: :ok, else: unauthorized()

      _headers ->
        unauthorized()
    end
  end

  defp cast(%{"wallet_address" => wallet_address, "since" => since} = params)
       when is_binary(wallet_address) and is_binary(since) do
    with [] <- Map.keys(params) -- ["wallet_address", "since", "after"],
         {:ok, start} <- start(params),
         true <- Regex.match?(@address, wallet_address),
         {:ok, since, _offset} <- DateTime.from_iso8601(since) do
      {:ok, wallet_address, since, start}
    else
      _invalid -> invalid()
    end
  end

  defp cast(_params), do: invalid()

  # The page to start from: the next cursor sent back as after, or none.
  defp start(%{"after" => cursor}) when is_binary(cursor), do: {:ok, cursor}
  defp start(%{"after" => _not_a_cursor}), do: :error
  defp start(_params), do: {:ok, nil}

  defp page(wallet_address, since, start) do
    case ActivityStore.page(wallet_address, since, start) do
      {:ok, entries, next} -> {:ok, entries, next}
      :error -> invalid()
    end
  end

  defp unauthorized,
    do: {:error, {401, "activity_read_unauthorized", "invalid activity read token"}}

  defp invalid,
    do:
      {:error,
       {400, "invalid_activity_request",
        "wallet_address and an ISO 8601 since are required; after must be a next cursor from an earlier answer"}}
end
