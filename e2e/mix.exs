defmodule LoopctlE2e.MixProject do
  use Mix.Project

  # US-52.9: drives one issue through the real factory on the sandbox repository. Its own mix
  # project so the root suite never compiles it; `mix e2e` from the repository root runs it.
  def project do
    [
      app: :loopctl_e2e,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: false,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps()
    ]
  end

  def application, do: [extra_applications: [:logger, :crypto]]

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Runtime deps are req and jason only (AC-52.9.2); credo is a dev/test tool, never loaded.
  defp deps do
    [
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end
end
