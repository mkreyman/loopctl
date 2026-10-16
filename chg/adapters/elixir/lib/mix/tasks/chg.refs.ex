defmodule Mix.Tasks.Chg.Refs do
  @shortdoc "Records which modules each test file references (run by chg.snapshot)"
  @moduledoc """
  Compiles the project and its test files, without running a test or starting the
  application, and writes the test reference cache `mix chg.affected` selects from.

      MIX_ENV=test mix chg.refs
  """
  use Mix.Task

  alias ChgAdapter.{Graph, Refs}

  @impl true
  def run(args) do
    ChgAdapter.in_test_env("chg.refs", args, fn -> do_run(args) end)
  end

  defp do_run(_args) do
    ChgAdapter.preload_and_compile!()

    graph =
      case Graph.read() do
        {:ok, graph} -> graph
        {:error, why} -> Mix.raise(why)
      end

    sha = ChgAdapter.git!(["rev-parse", "HEAD"])
    {computed, unknown} = Refs.build!(sha, graph)

    IO.puts(
      :standard_error,
      "chg: test references at #{String.slice(sha, 0, 9)}: #{computed} compiled, #{unknown} unknown"
    )
  end
end
