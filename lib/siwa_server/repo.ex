defmodule SiwaServer.Repo do
  use Ecto.Repo,
    otp_app: :siwa_server,
    adapter: Ecto.Adapters.Postgres
end
