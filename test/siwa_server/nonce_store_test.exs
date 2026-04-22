defmodule SiwaServer.Siwa.NonceStoreTest do
  use SiwaServer.DataCase, async: false

  alias SiwaServer.Siwa.{NonceRecord, NonceStore}

  test "cleanup_expired removes expired nonce rows and keeps active ones" do
    now = ~U[2026-04-22 12:00:00Z]

    insert_nonce!("expired-nonce", DateTime.add(now, -60, :second))
    insert_nonce!("active-nonce", DateTime.add(now, 60, :second))

    assert :ok = NonceStore.cleanup_expired(now)

    assert Repo.aggregate(NonceRecord, :count, :id) == 1
    assert Repo.get_by(NonceRecord, nonce: "expired-nonce") == nil
    assert %NonceRecord{nonce: "active-nonce"} = Repo.get_by(NonceRecord, nonce: "active-nonce")
  end

  test "cleanup_expired deletes at most one batch per call" do
    now = ~U[2026-04-22 12:00:00Z]

    insert_nonce!("expired-nonce-1", DateTime.add(now, -60, :second))
    insert_nonce!("expired-nonce-2", DateTime.add(now, -30, :second))

    assert :ok = NonceStore.cleanup_expired(now, 1)

    assert Repo.aggregate(NonceRecord, :count, :id) == 1
  end

  defp insert_nonce!(nonce, expiration_time) do
    %NonceRecord{}
    |> NonceRecord.changeset(%{
      nonce_key: "key-#{nonce}",
      nonce: nonce,
      address: "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266",
      agent_id: 77,
      agent_registry: "eip155:84532:0x3333333333333333333333333333333333333333",
      audience: "platform",
      issued_at: DateTime.add(expiration_time, -300, :second),
      expiration_time: expiration_time
    })
    |> Repo.insert!()
  end
end
