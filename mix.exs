defmodule Loopctl.MixProject do
  use Mix.Project

  def project do
    [
      app: :loopctl,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      releases: releases(),
      listeners: [Phoenix.CodeReloader],
      dialyzer: [
        plt_add_apps: [:mix, :ex_unit, :ecto, :ecto_sql],
        plt_file: {:no_warn, "priv/plts/dialyzer.plt"},
        ignore_warnings: "priv/plts/dialyzer_ignore.exs"
      ]
    ]
  end

  def application do
    [
      mod: {Loopctl.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  defp releases do
    [
      loopctl: [
        include_executables_for: [:unix],
        strip_beams: [keep: ["Docs"]],
        applications: [runtime_tools: :permanent]
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Phoenix
      {:phoenix, "~> 1.8.4"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},

      # HTTP client
      {:req, "~> 0.5"},

      # Background jobs
      {:oban, "~> 2.19"},

      # Encryption at rest (webhook signing secrets, API key idempotency cache)
      {:cloak, "~> 1.1"},
      {:cloak_ecto, "~> 1.3"},

      # Rate limiting
      {:hammer, "~> 6.2"},

      # Remote IP resolution behind reverse proxy
      {:remote_ip, "~> 1.2"},

      # Testing
      {:mox, "~> 1.2", only: :test},

      # Code quality
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.13", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.create", "ecto.migrate"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --check-unused",
        "format --check-formatted",
        "credo --strict",
        "dialyzer",
        "test"
      ]
    ]
  end
end
