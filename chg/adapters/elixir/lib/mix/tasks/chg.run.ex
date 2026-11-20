defmodule Mix.Tasks.Chg.Run do
  @shortdoc "Runs a list of tests (contract command `run`)"
  @moduledoc """
  Runs the tests listed in a file, one repo-relative `path` or `path:line` per line (the
  list `affected` selected), and reports a result per test.

      mix chg.run --tests <list-file>

  Prints `{"results":[{"id","status","ms"}]}` and exits 1 when any test failed.
  """
  use Mix.Task

  @impl true
  def run(args) do
    ChgAdapter.in_test_env("chg.run", args, fn -> do_run(args) end)
  end

  defp do_run(args) do
    {opts, _} = OptionParser.parse!(args, strict: [tests: :string])
    list = opts[:tests] || Mix.raise("mix chg.run needs --tests <list-file>")
    paths = list |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&String.trim/1)
    ChgAdapter.Runner.run(Enum.reject(paths, &(&1 == "")), false)
  end
end
