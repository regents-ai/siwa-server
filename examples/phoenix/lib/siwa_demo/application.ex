defmodule SiwaDemo.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link([SiwaDemoWeb.Endpoint],
      strategy: :one_for_one,
      name: SiwaDemo.Supervisor
    )
  end
end
