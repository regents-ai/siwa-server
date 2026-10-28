defmodule SiwaServer.MixProject do
  use Mix.Project

  @elixir_utils "https://github.com/regents-ai/elixir-utils.git"
  @elixir_utils_ref "76ccfd6d8283445385e60a90ef15b6fb71bcd40a"

  def project do
    [
      app: :siwa_server,
      version: "0.1.0",
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      listeners: [Phoenix.CodeReloader],
      usage_rules: usage_rules()
    ]
  end

  # `mix usage_rules.sync` writes the marked block at the end of AGENTS.md: how to
  # read the installed version's docs, and links to each package's own rules in deps/.
  defp usage_rules do
    [
      file: "AGENTS.md",
      usage_rules: [
        {:usage_rules, sub_rules: []},
        {:usage_rules, sub_rules: :all, main: false, link: :markdown},
        {:phoenix, sub_rules: ["phoenix", "ecto"], link: :markdown}
      ]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {SiwaServer.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.8.4"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:oban, "~> 2.24"},
      {:postgrex, ">= 0.0.0"},
      {:req, "~> 0.7"},
      {:castore, "~> 1.0"},
      {:finch, "~> 0.21"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_metrics_prometheus_core, "~> 1.2"},
      {:telemetry_poller, "~> 1.0"},
      {:jason, "~> 1.2"},
      # 3.1.1 has the EEF-CVE-2026-97853 advisory in Decimal.round/3.
      {:decimal, "== 3.1.2"},
      {:ex_keccak, "~> 0.7.8"},
      {:ex_secp256k1, "~> 0.8.0"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.14"},
      {:siwa,
       git: @elixir_utils,
       ref: @elixir_utils_ref,
       sparse: "siwa/siwa-elixir/apps/siwa",
       override: true},
      {:siwa_keyring,
       git: @elixir_utils, ref: @elixir_utils_ref, sparse: "siwa/siwa-elixir/apps/siwa_keyring"},
      {:regent_chain, git: @elixir_utils, ref: @elixir_utils_ref, sparse: "chain"},
      # The signing contract's shared fixtures, read by the agent client conformance test.
      {:siwa_contract,
       git: @elixir_utils,
       ref: @elixir_utils_ref,
       sparse: "siwa/contract",
       app: false,
       compile: false,
       only: :test},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.16", only: [:dev, :test], runtime: false},
      {:stream_data, "~> 1.4", only: [:dev, :test]},
      {:usage_rules, "~> 1.2.8", only: [:dev, :test], runtime: false}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test --max-cases 8"],
      "check.services_contract": [
        "siwa_server.contract_check"
      ],
      "check.agent_clients": [
        "siwa_server.agent_clients --check"
      ],
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --check-unused",
        "format --check-formatted",
        "credo --strict",
        "sobelow --exit --skip",
        "usage_rules.sync --check",
        "check.services_contract",
        "check.agent_clients",
        "xref graph --label compile-connected --fail-above 0",
        "cmd npm --prefix e2e ci --silent",
        "test --warnings-as-errors",
        "cmd npm --prefix e2e test"
      ]
    ]
  end
end
