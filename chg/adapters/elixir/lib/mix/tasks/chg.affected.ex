defmodule Mix.Tasks.Chg.Affected do
  @shortdoc "Selects the tests a change affects (contract command `affected`)"
  @moduledoc """
  Prints the test files affected by the difference between `--base` and the working
  tree, from the module graph and the snapshot's test reference cache
  (`ChgAdapter.Select`).

      mix chg.affected --base <sha>

  Prints `{"mode":"subset","reason":…,"tests":[…]}`, or `{"mode":"all","reason":…}` when
  the selection cannot be trusted: no cache, an unreadable compile manifest, or a deleted
  source the cache does not know. `always_all` is applied by `chg adapter exec affected`
  before this task runs; called directly, this task does not apply it.
  """
  use Mix.Task

  alias ChgAdapter.{Graph, Refs, Select}

  @impl true
  def run(args) do
    ChgAdapter.in_test_env("chg.affected", args, fn -> do_run(args) end)
  end

  defp do_run(args) do
    ChgAdapter.preload_and_compile!()
    {opts, _} = OptionParser.parse!(args, strict: [base: :string])
    base = opts[:base] || Mix.raise("mix chg.affected needs --base <sha>")

    doc =
      with {:ok, changed} <- ChgAdapter.changed_paths(base),
           {:ok, refs} <- Refs.read(),
           {:ok, since} <- ChgAdapter.changed_paths(refs.sha),
           {:ok, graph} <- Graph.read() do
        Select.run(%{
          changed: changed,
          since_snapshot: since,
          graph: graph,
          refs: refs,
          test_files: ChgAdapter.test_files(),
          test_file?: &ChgAdapter.test_file?/1,
          exists?: &File.exists?/1
        })
      end

    case doc do
      {:subset, reason, tests} -> ChgAdapter.emit(%{mode: "subset", reason: reason, tests: tests})
      {:all, reason} -> ChgAdapter.emit(%{mode: "all", reason: reason})
      {:error, why} -> ChgAdapter.emit(%{mode: "all", reason: why})
    end
  end
end
