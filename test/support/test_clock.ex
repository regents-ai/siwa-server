defmodule SiwaServer.TestClock do
  @moduledoc """
  Sets the database clock for one test. Inside the test's rolled-back
  transaction, `now()` is answered by a function of the same name in a schema
  searched before `pg_catalog`, which returns the time `set/1` last gave; the
  schema and the search path go when the test's transaction rolls back. The
  code under test reads the clock as it always does.

  Tests that use it are not async: the schema's name is the same in each.
  """

  alias SiwaServer.Repo

  @doc "Makes `now()` answer `at` for the rest of the test."
  @spec start(DateTime.t()) :: :ok
  def start(at) do
    Repo.query!("CREATE SCHEMA siwa_test_clock")

    Repo.query!("""
    CREATE FUNCTION siwa_test_clock.now() RETURNS timestamptz LANGUAGE sql STABLE
    AS $$ SELECT current_setting('siwa_test.now')::timestamptz $$
    """)

    Repo.query!("SET LOCAL search_path = siwa_test_clock, pg_catalog, public")
    set(at)
  end

  @doc "Moves the clock to `at`."
  @spec set(DateTime.t()) :: :ok
  def set(at) do
    Repo.query!("SELECT set_config('siwa_test.now', $1, true)", [DateTime.to_iso8601(at)])
    :ok
  end
end
