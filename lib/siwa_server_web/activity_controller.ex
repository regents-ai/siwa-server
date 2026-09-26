defmodule SiwaServerWeb.ActivityController do
  @moduledoc """
  Lets a Regents site read one wallet's recent verified requests, so a person
  can see what their agent has been doing across the sites. Only callers
  holding the activity read token may read it.
  """

  use SiwaServerWeb, :controller

  alias SiwaServer.RuntimeConfig
  alias SiwaServer.Siwa.ActivityStore

  action_fallback SiwaServerWeb.FallbackController

  @address ~r/^0x[0-9a-fA-F]{40}$/

  def read(conn, params) do
    with :ok <- authorize(conn),
         {:ok, wallet_address, since} <- cast(params) do
      activity =
        wallet_address
        |> ActivityStore.recent(since)
        |> Enum.map(&Map.update!(&1, :occurred_at, fn at -> DateTime.to_iso8601(at) end))

      json(conn, %{data: %{activity: activity}})
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
       when map_size(params) == 2 and is_binary(wallet_address) and is_binary(since) do
    with true <- Regex.match?(@address, wallet_address),
         {:ok, since, _offset} <- DateTime.from_iso8601(since) do
      {:ok, wallet_address, since}
    else
      _invalid -> invalid()
    end
  end

  defp cast(_params), do: invalid()

  defp unauthorized,
    do: {:error, {401, "activity_read_unauthorized", "invalid activity read token"}}

  defp invalid,
    do:
      {:error,
       {400, "invalid_activity_request", "wallet_address and an ISO 8601 since are required"}}
end
