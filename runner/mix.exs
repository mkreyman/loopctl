defmodule LoopctlRunner.MixProject do
  use Mix.Project

  def project do
    [
      app: :loopctl_runner,
      version: "0.1.0",
      # 1.18 is the floor: the JSON module. blockit runs 1.18.4 on OTP 27.
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      dialyzer: [plt_add_apps: [:mix, :ex_unit]],
      releases: [
        loopctl_runner: [include_executables_for: [:unix], strip_beams: false]
      ]
    ]
  end

  def application do
    [extra_applications: [:logger, :crypto], mod: {LoopctlRunner.Application, []}]
  end

  def cli do
    [preferred_envs: [precommit: :test]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:slipstream, "~> 1.2"},
      {:jason, "~> 1.4"},
      # A real Phoenix socket to test the client against, never shipped in the release.
      {:phoenix, "~> 1.8", only: :test},
      {:bandit, "~> 1.12", only: :test},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
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
