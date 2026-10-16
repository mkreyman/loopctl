defmodule ChgAdapter.MixProject do
  use Mix.Project

  # Installed as a Mix archive (`mix archive.install`), so a product repo gets the
  # `mix chg.*` tasks without a dependency in its mix.exs or a line in its mix.lock.
  # An archive cannot carry dependencies; this project has none.
  def project do
    [
      app: :chg_adapter,
      version: "1.0.0",
      elixir: "~> 1.20",
      start_permanent: false,
      deps: [],
      elixirc_paths: ["lib"],
      test_paths: ["test"]
    ]
  end

  def application, do: [extra_applications: []]
end
