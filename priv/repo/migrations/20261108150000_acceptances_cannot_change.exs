defmodule SiwaServer.Repo.Migrations.AcceptancesCannotChange do
  use Ecto.Migration

  # A wallet's accepted person is kept for good (SiwaServer.AgentBook), so the
  # table takes new rows and refuses every change to one already there.
  def up do
    execute """
    CREATE FUNCTION agent_book_acceptance_is_permanent() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      RAISE EXCEPTION '% on agent_book_acceptances refused: a wallet''s accepted person is permanent', TG_OP;
    END
    $$
    """

    execute """
    CREATE TRIGGER agent_book_acceptances_permanent_rows
    BEFORE UPDATE OR DELETE ON agent_book_acceptances
    FOR EACH ROW EXECUTE FUNCTION agent_book_acceptance_is_permanent()
    """

    execute """
    CREATE TRIGGER agent_book_acceptances_permanent_table
    BEFORE TRUNCATE ON agent_book_acceptances
    FOR EACH STATEMENT EXECUTE FUNCTION agent_book_acceptance_is_permanent()
    """
  end

  def down do
    execute "DROP TRIGGER agent_book_acceptances_permanent_table ON agent_book_acceptances"
    execute "DROP TRIGGER agent_book_acceptances_permanent_rows ON agent_book_acceptances"
    execute "DROP FUNCTION agent_book_acceptance_is_permanent()"
  end
end
