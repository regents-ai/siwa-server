defmodule SiwaServer.Siwa.ChallengeTest do
  use SiwaServer.DataCase, async: false

  alias SiwaServer.Siwa.Challenge

  test "cleanup_expired removes expired nonce rows and keeps active ones" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    insert_nonce!("expired-nonce", DateTime.add(now, -60, :second))
    insert_nonce!("active-nonce", DateTime.add(now, 60, :second))

    assert {:ok, 1} = Challenge.cleanup_expired(1_000)

    assert Repo.aggregate(Challenge, :count, :id) == 1
    assert Repo.get_by(Challenge, nonce: "expired-nonce") == nil
    assert %Challenge{nonce: "active-nonce"} = Repo.get_by(Challenge, nonce: "active-nonce")
  end

  test "cleanup_expired deletes at most one batch per call" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    insert_nonce!("expired-nonce-1", DateTime.add(now, -60, :second))
    insert_nonce!("expired-nonce-2", DateTime.add(now, -30, :second))

    assert {:ok, 1} = Challenge.cleanup_expired(1)

    assert Repo.aggregate(Challenge, :count, :id) == 1
  end

  defp insert_nonce!(nonce, expiration_time) do
    Repo.insert!(%Challenge{
      nonce_key: "key-#{nonce}",
      nonce: nonce,
      address: "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266",
      chain_id: 8453,
      canonical_message: "sign-in challenge #{nonce}",
      audience: "platform",
      issued_at: DateTime.add(expiration_time, -300, :second),
      expiration_time: expiration_time
    })
  end
end
