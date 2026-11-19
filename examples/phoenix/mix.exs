defmodule SiwaDemo.MixProject do
  use Mix.Project

  # The shared SIWA library, at the commit siwa-server itself builds with.
  @elixir_utils "https://github.com/regents-ai/elixir-utils.git"
  @elixir_utils_ref "e40068b39e45cc344140695cfad97790bf4da31c"

  def project do
    [
      app: :siwa_demo,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  def application do
    [
      mod: {SiwaDemo.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:phoenix, "~> 1.8.4"},
      {:phoenix_html, "~> 4.2"},
      {:bandit, "~> 1.14"},
      {:req, "~> 0.7"},
      # The certificates Req checks the SIWA service against, wherever this runs.
      {:castore, "~> 1.0"},
      {:jason, "~> 1.4"},
      {:siwa, git: @elixir_utils, ref: @elixir_utils_ref, sparse: "siwa/siwa-elixir/apps/siwa"}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get"],
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --check-unused",
        "format --check-formatted"
      ]
    ]
  end
end
