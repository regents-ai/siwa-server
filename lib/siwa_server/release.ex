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

  @doc """
  Asserts that the Erlang/OTP runtime is linked against OpenSSL 3.5+ with
  native FIPS 204 `ML-DSA-65` support (required for SIWA v3 hybrid signing).
  """
  def verify_pqc_runtime! do
    if :mldsa65 in :crypto.supports(:public_keys) do
      :ok
    else
      raise "OTP :crypto runtime lacks native :mldsa65 support (requires OpenSSL 3.5+ / Debian Trixie)"
    end
  end

  defp load_app do
    Application.load(@app)
  end
end
