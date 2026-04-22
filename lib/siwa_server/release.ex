defmodule SiwaServer.Release do
  @moduledoc false

  @app :siwa_server

  def migrate do
    load_app()

    for repo <- Application.fetch_env!(@app, :ecto_repos) do
      {:ok, _started, _apps} =
        Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  defp load_app do
    Application.load(@app)
  end
end
