defmodule SiwaServer.Siwa.ReplayKeyHashTest do
  use SiwaServer.DataCase, async: false

  alias SiwaServer.Siwa.ReplayStore

  @paths ["/v1/agent/private?token=abc", "/v1/café/日本?note=🙂"]

  test "a used request is kept only as a hash of its key, never its path or query" do
    keys = Enum.map(@paths, &key/1)
    for key <- keys, do: assert(ReplayStore.consume(key, live()) == :ok)

    %{rows: rows} = Repo.query!("SELECT replay_key FROM siwa_request_replays")
    stored = List.flatten(rows)

    for key <- keys do
      assert ReplayStore.stored_key(key) in stored
      refute key in stored
      assert ReplayStore.consume(key, live()) == {:error, :replayed_request}
    end

    assert Enum.all?(stored, &(&1 =~ ~r/\Ah1:[0-9a-f]{64}\z/))
  end

  # The shared library's key: wallet, chain, audience, nonce, method, path with its
  # query, and body digest.
  defp key(path) do
    Jason.encode!([
      "wallet",
      "0x" <> String.duplicate("ab", 20),
      8453,
      "patchbay",
      Ecto.UUID.generate(),
      "POST",
      path,
      "sha-256=:47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU=:"
    ])
  end

  defp live, do: System.system_time(:second) + 60
end
