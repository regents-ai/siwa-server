ExUnit.start(exclude: [:stripe_live])
Ecto.Adapters.SQL.Sandbox.mode(SiwaServer.Repo, :manual)
