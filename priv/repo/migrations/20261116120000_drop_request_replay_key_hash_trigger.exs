defmodule SiwaServer.Repo.Migrations.DropRequestReplayKeyHashTrigger do
  use Ecto.Migration

  # Every release since migration 20261113150000 writes the `h1:` hash itself
  # (SiwaServer.Siwa.ReplayStore.stored_key/1). The trigger that migration added
  # hashed only the plain keys a release from before it wrote, so once this runs,
  # no release from before 20261113150000 may write here again: its plain keys
  # would miss the hashed rows and could accept a used request a second time.
  # `down` puts the function and the trigger back as that migration made them.
  #
  # Dropping a trigger waits for the table's writers, and new writers wait behind
  # it, so the wait is bounded as that migration bounded its own.

  def up do
    execute "SET LOCAL lock_timeout = '5s'"
    execute "DROP TRIGGER siwa_request_replays_hashed_key ON siwa_request_replays"
    execute "DROP FUNCTION siwa_request_replay_key_hashed()"
  end

  def down do
    execute "SET LOCAL lock_timeout = '5s'"

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
end
