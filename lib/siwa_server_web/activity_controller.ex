defmodule SiwaServerWeb.ActivityController do
  @moduledoc """
  Lets a Regents site read how much one wallet's agent was verified at each site
  on each of the last 30 days, so a person can see where their agent has been
  active. The answer also names the wallet's newest agent
  registry listing made through this server, so the site can link to it, and the
  World ID-verified person AgentBook last named behind it, if any.
  Each site reads with its own key. Every read is counted under the site whose
  key it presented, and every refused key under "refused", so an unexpected
  reader or a run of refused keys shows up in the metrics.
  """

  use SiwaServerWeb, :controller

  require Logger

  alias SiwaServer.{ActivityReaders, AgentBook, AgentRegistration, RuntimeConfig}
  alias SiwaServer.Siwa.ActivityStore

  action_fallback SiwaServerWeb.FallbackController

  @address ~r/^0x[0-9a-fA-F]{40}$/

  def read(conn, params) do
    with {:ok, reader} <- authorize(conn),
         {:ok, wallet_address, since} <- cast(params) do
      Logger.info("activity read reader=#{reader} wallet=#{String.downcase(wallet_address)}")

      json(conn, %{
        data: %{
          days: wallet_address |> ActivityStore.days(since) |> Enum.map(&day/1),
          agentRegistration: AgentRegistration.latest(wallet_address),
          agentBook: AgentBook.human(wallet_address)
        }
      })
    end
  end

  defp authorize(conn) do
    with [presented] <- get_req_header(conn, "authorization"),
         {:ok, reader} <- ActivityReaders.reader(RuntimeConfig.siwa_activity_readers(), presented) do
      counted(reader)
      {:ok, reader}
    else
      _refused ->
        counted("refused")
        Logger.warning("activity read refused: no site's key was presented")
        unauthorized()
    end
  end

  defp counted(reader),
    do: :telemetry.execute([:siwa_server, :siwa, :activity, :read], %{}, %{reader: reader})

  defp cast(%{"wallet_address" => wallet_address, "since" => since} = params)
       when is_binary(wallet_address) and is_binary(since) do
    with [] <- Map.keys(params) -- ["wallet_address", "since"],
         true <- Regex.match?(@address, wallet_address),
         {:ok, since, _offset} <- DateTime.from_iso8601(since) do
      {:ok, wallet_address, since}
    else
      _invalid -> invalid()
    end
  end

  defp cast(_params), do: invalid()

  defp day(line) do
    %{
      line
      | day: Date.to_iso8601(line.day),
        first_seen_at: DateTime.to_iso8601(line.first_seen_at),
        last_seen_at: DateTime.to_iso8601(line.last_seen_at)
    }
  end

  defp unauthorized,
    do: {:error, {401, "activity_read_unauthorized", "invalid activity read token"}}

  defp invalid,
    do:
      {:error,
       {400, "invalid_activity_request", "wallet_address and an ISO 8601 since are required"}}
end
