defmodule Sample.MixProject do
  use Mix.Project

  def project do
    [
      app: :sample,
      version: "0.1.0",
      elixir: "~> 1.19 and >= 1.19.5",
      elixirc_paths: elixirc_paths(Mix.env()),
      elixirc_options: [check_cwd: false],
      deps: [{:shared, path: "apps/shared"}]
    ]
  end

  def application, do: [extra_applications: [:logger]]

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end
