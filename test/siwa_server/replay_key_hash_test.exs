# `ecto.migrate` loads a migration only when it runs it.
if not Code.ensure_loaded?(SiwaServer.Repo.Migrations.HashRequestReplayKeys) do
  Code.require_file(
    "../../priv/repo/migrations/20261113150000_hash_request_replay_keys.exs",
    __DIR__
  )
end

defmodule SiwaServer.Siwa.ReplayKeyHashTest do
  use SiwaServer.DataCase, async: false

  alias SiwaServer.Repo.Migrations.HashRequestReplayKeys
  alias SiwaServer.Siwa.ReplayStore

  # The release before hashed keys (v88) writes and looks up the plain key. It shares
  # this table with this release while a release rolls out, and again after a rollback
  # to its image, so every case runs its statement against this one.

  @paths ["/v1/agent/bug-report?page=2", "/v1/café/日本?note=🙂"]

  test "the database hashes a plain key to the stored key this release looks up" do
    for path <- @paths do
      key = key(path)

      assert previous_release_consume(key, live()) == :ok
      assert rows(ReplayStore.stored_key(key)) == 1
      assert rows(key) == 0
    end
  end

  test "a request the previous release accepted is refused here" do
    key = key("/v1/agent/bug-report")

    assert previous_release_consume(key, live()) == :ok
    assert ReplayStore.consume(key, live()) == {:error, :replayed_request}
  end

  test "a request accepted here is refused by the previous release" do
    key = key("/v1/agent/bug-report")

    assert ReplayStore.consume(key, live()) == :ok
    assert previous_release_consume(key, live()) == {:error, :replayed_request}
    assert rows(ReplayStore.stored_key(key)) == 1
  end

  test "the previous release accepts a request once" do
    key = key("/v1/agent/bug-report")

    assert previous_release_consume(key, live()) == :ok
    assert previous_release_consume(key, live()) == {:error, :replayed_request}
  end

  test "a key kept in plain text before the migration is refused after it" do
    hashed = key("/v1/agent/hashed")
    plain = Enum.map(@paths, &key/1)

    assert ReplayStore.consume(hashed, live()) == :ok

    Repo.query!(
      "ALTER TABLE siwa_request_replays DISABLE TRIGGER siwa_request_replays_hashed_key"
    )

    for key <- plain, do: assert(previous_release_consume(key, live()) == :ok)
    Repo.query!("ALTER TABLE siwa_request_replays ENABLE TRIGGER siwa_request_replays_hashed_key")
    for key <- plain, do: assert(rows(key) == 1)

    Repo.query!(HashRequestReplayKeys.hash_plain_keys_sql())

    for key <- [hashed | plain] do
      assert rows(key) == 0
      assert rows(ReplayStore.stored_key(key)) == 1
      assert ReplayStore.consume(key, live()) == {:error, :replayed_request}
      assert previous_release_consume(key, live()) == {:error, :replayed_request}
    end
  end

  test "an accepted use leaves only a hash of its key" do
    here = key("/v1/agent/private?token=abc")
    previous = key("/v1/agent/private?token=def")

    assert ReplayStore.consume(here, live()) == :ok
    assert previous_release_consume(previous, live()) == :ok

    %{rows: rows} = Repo.query!("SELECT replay_key FROM siwa_request_replays")
    stored = List.flatten(rows)

    assert ReplayStore.stored_key(here) in stored
    assert ReplayStore.stored_key(previous) in stored
    assert Enum.all?(stored, &(&1 =~ ~r/\Ah1:[0-9a-f]{64}\z/))
  end

  # Both releases refuse every repeat. Past the key's end the previous release looks
  # for the plain key, misses the hashed row and names the refusal "expired" where
  # this release names it "replayed".
  test "a used request is refused by both releases before and after its end" do
    ends = db_now() + 2
    by_here = key("/v1/agent/here")
    by_previous = key("/v1/agent/previous")
    unused = key("/v1/agent/unused")

    assert ReplayStore.consume(by_here, ends) == :ok
    assert previous_release_consume(by_previous, ends) == :ok

    for key <- [by_here, by_previous] do
      assert ReplayStore.consume(key, ends) == {:error, :replayed_request}
      assert previous_release_consume(key, ends) == {:error, :replayed_request}
    end

    sleep_past!(ends)

    for key <- [by_here, by_previous] do
      assert ReplayStore.consume(key, ends) == {:error, :replayed_request}
      assert previous_release_consume(key, ends) == {:error, :request_expired}
    end

    assert ReplayStore.consume(unused, ends) == {:error, :request_expired}
    assert previous_release_consume(unused, ends) == {:error, :request_expired}
  end

  # The previous release's `SiwaServer.Siwa.ReplayStore.consume/2`, statement for
  # statement (e27c389).
  defp previous_release_consume(replay_key, expires_at_unix) do
    expires_at = DateTime.from_unix!(expires_at_unix)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    case Repo.query(
           """
           WITH clock AS MATERIALIZED (
             SELECT clock_timestamp() AT TIME ZONE 'UTC' AS before_write
           ), consumed AS (
             INSERT INTO siwa_request_replays (id, replay_key, expires_at, inserted_at, updated_at)
             SELECT $1, $2, $3, $4, $4
             FROM clock
             WHERE $3::timestamp > clock.before_write
             ON CONFLICT (replay_key) DO NOTHING
             RETURNING id, expires_at
           )
           SELECT
             CASE
               WHEN EXISTS (
                 SELECT 1 FROM consumed
                 WHERE expires_at > (clock_timestamp() AT TIME ZONE 'UTC')
               )
                 THEN 'accepted'
               WHEN NOT EXISTS (SELECT 1 FROM consumed)
                 AND (
                   $3::timestamp > (SELECT before_write FROM clock)
                   OR EXISTS (SELECT 1 FROM siwa_request_replays WHERE replay_key = $2)
                 )
                 THEN 'replayed'
               ELSE 'expired'
             END
           """,
           [
             Ecto.UUID.generate() |> Ecto.UUID.dump!(),
             replay_key,
             expires_at,
             now
           ]
         ) do
      {:ok, %{rows: [["accepted"]]}} ->
        :ok

      {:ok, %{rows: [["replayed"]]}} ->
        {:error, :replayed_request}

      {:ok, %{rows: [["expired"]]}} ->
        {:error, :request_expired}

      {:error, reason} ->
        {:error, reason}
    end
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

  defp db_now do
    %{rows: [[now]]} = Repo.query!("SELECT floor(extract(epoch FROM clock_timestamp()))::bigint")
    now
  end

  defp sleep_past!(ends),
    do: Repo.query!("SELECT pg_sleep_until(to_timestamp($1::bigint + 0.4))", [ends])

  defp rows(replay_key) do
    %{rows: [[count]]} =
      Repo.query!("SELECT count(*) FROM siwa_request_replays WHERE replay_key = $1", [replay_key])

    count
  end
end
