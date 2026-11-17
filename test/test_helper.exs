ExUnit.start(exclude: [:stripe_live])

# Hello cards are on, signed with a key made for this run alone.
siwa = Application.fetch_env!(:siwa_server, :siwa)

Application.put_env(
  :siwa_server,
  :siwa,
  Keyword.put(siwa, :card_keys, [:crypto.strong_rand_bytes(32)])
)

Ecto.Adapters.SQL.Sandbox.mode(SiwaServer.Repo, :manual)
