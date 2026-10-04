defmodule SiwaServer.AgentBook.Refresh do
  @moduledoc """
  Reads one wallet's AgentBook entry after it signs in. A failed read retries
  with backoff; the wallet's last saved entry stays until a read succeeds.
  """

  use Oban.Worker,
    queue: :agent_book,
    max_attempts: 5,
    unique: [keys: [:wallet_address], period: :infinity, states: :incomplete]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"wallet_address" => wallet_address}}),
    do: SiwaServer.AgentBook.refresh(wallet_address)
end
