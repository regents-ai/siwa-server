defmodule SiwaServer.AgentBookTest do
  use SiwaServer.DataCase, async: true

  alias SiwaServer.AgentBook
  alias SiwaServer.AgentBook.Acceptance

  @wallet "0x38d856b4617c9da5caeb4a6f12606249beb19161"
  @number "0x0d8e5af4d20a7f4e9c1b2a3f4e5d6c7b8a9f0e1d2c3b4a5968778695a4b3c2d1"

  test "names the accepted person with how many agent wallets accepted the same person" do
    assert AgentBook.human(@wallet) == nil

    Repo.insert!(Acceptance.changeset(%{wallet_address: @wallet, human_id: @number}))
    other = "0x" <> String.duplicate("7", 40)
    Repo.insert!(Acceptance.changeset(%{wallet_address: other, human_id: @number}))

    assert AgentBook.human(String.upcase(@wallet)) == %{"humanId" => @number, "agentCount" => 2}
  end
end
