defmodule Sandbox.MixProject do
  use Mix.Project

  # loopctl's e2e sandbox (US-52.9): each nightly run adds one module under lib/sandbox/runs/.
  def project do
    [
      app: :sandbox,
      version: "0.1.0",
      elixir: "~> 1.19",
      # chg hydrates its check workspace from a snapshot built at another path.
      elixirc_options: [check_cwd: false],
      deps: []
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
