defmodule SiwaServer.Repo.Migrations.HashRequestReplayKeys do
  use Ecto.Migration

  # A used request is kept as "h1:" and the lowercase hex SHA-256 of its key's UTF-8
  # bytes (SiwaServer.Siwa.ReplayStore.stored_key/1), never as the key, which names
  # the request's path and query. A key is JSON starting with "[", so it never looks
  # like a hash, and a hash is never hashed again.
  #
  # The trigger hashes the plain key the release before this one writes, so an
  # INSERT ... ON CONFLICT (replay_key) from either release meets the other's row:
  # PostgreSQL checks the conflict on the row a BEFORE INSERT trigger returns. A
  # rewrite rule would not work with ON CONFLICT. The trigger is needed while that
  # release can still write here: during the rolling release and while a rollback to
  # its image remains possible. A later release drops the trigger and its function;
  # this one must not.
  #
  # Writers wait on the lock from before the existing keys are hashed until the
  # trigger is in place, so no plain key lands between the two.
  @hash_plain_keys """
  UPDATE siwa_request_replays
  SET replay_key = 'h1:' || encode(sha256(convert_to(replay_key, 'UTF8')), 'hex')
  WHERE replay_key !~ '^h1:[0-9a-f]{64}$'
  """

  def hash_plain_keys_sql, do: @hash_plain_keys

  def up do
    execute "SET LOCAL lock_timeout = '5s'"
    execute "LOCK TABLE siwa_request_replays IN SHARE ROW EXCLUSIVE MODE"
    execute @hash_plain_keys

    execute """
    CREATE FUNCTION siwa_request_replay_key_hashed() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.replay_key !~ '^h1:[0-9a-f]{64}$' THEN
        NEW.replay_key := 'h1:' || encode(sha256(convert_to(NEW.replay_key, 'UTF8')), 'hex');
      END IF;
      RETURN NEW;
    END
    $$
    """

    execute """
    CREATE TRIGGER siwa_request_replays_hashed_key
    BEFORE INSERT ON siwa_request_replays
    FOR EACH ROW EXECUTE FUNCTION siwa_request_replay_key_hashed()
    """
  end

  # Hashed keys cannot be turned back into keys, so this only removes the trigger. On
  # a live database the way back is the previous release's image with the trigger
  # left in place, never this: without the trigger the previous release writes plain
  # keys that miss the hashed rows, and can accept a used request again.
  def down do
    execute "DROP TRIGGER siwa_request_replays_hashed_key ON siwa_request_replays"
    execute "DROP FUNCTION siwa_request_replay_key_hashed()"
  end
end
