defmodule Mix.Tasks.Chg.Affected do
  @shortdoc "Selects the tests a change affects (contract command `affected`)"
  @moduledoc """
  Prints the test files affected by the difference between `--base` and the working
  tree (`ChgAdapter.Select`).

      mix chg.affected --base <sha>

  It selects by coverage when `chg` hands it a record in `CHG_COVER`
  (`ChgAdapter.Record.given/1`): the test files whose recorded run executed a module whose
  compiled code differs now. Otherwise it selects from the module graph and
  the snapshot's test reference cache, and its reason says why coverage was not used.

  Prints `{"mode":"subset","reason":…,"tests":[…]}`, or `{"mode":"all","reason":…}` when
  the selection cannot be trusted: no cache, an unreadable compile manifest, a deleted
  source the cache does not know, or a change to a module every test runs. `always_all` is applied by `chg adapter exec affected`
  before this task runs; called directly, this task does not apply it.
  """
  use Mix.Task

  alias ChgAdapter.{Digest, Graph, Record, Refs, Select}

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
           {:ok, graph} <- Graph.read() do
        case by_coverage(base, changed, graph) do
          {:error, why} -> by_graph(changed, graph, why)
          selected -> selected
        end
      end

    emit(doc)
  end

  # Coverage selection when `chg` handed over a usable record.
  defp by_coverage(base, changed, graph) do
    with {:ok, record} <- Record.given(base),
         {:ok, since} <- ChgAdapter.changed_paths(record.sha) do
      modules = graph.source_modules |> Map.values() |> List.flatten() |> Enum.uniq()

      Select.by_coverage(%{
        changed: changed,
        since_record: since,
        record: record,
        digests: Digest.of_modules(modules, File.cwd!(), digest_cache()),
        graph: graph,
        test_files: ChgAdapter.test_files(),
        test_file?: &ChgAdapter.test_file?/1,
        test_path?: &ChgAdapter.test_path?/1,
        impl?: &protocol_impl?/1
      })
    end
  end

  defp digest_cache, do: Path.join([Mix.Project.build_path(), "chg", "digests.etf"])

  defp protocol_impl?(m), do: Code.ensure_loaded?(m) and function_exported?(m, :__impl__, 1)

  # The module graph's selection: what `mix test --stale` would run.
  defp by_graph(changed, graph, no_coverage) do
    with {:ok, refs} <- Refs.read(),
         {:ok, since} <- ChgAdapter.changed_paths(refs.sha) do
      case Select.run(%{
             changed: changed,
             since_snapshot: since,
             graph: graph,
             refs: refs,
             test_files: ChgAdapter.test_files(),
             test_file?: &ChgAdapter.test_file?/1,
             exists?: &File.exists?/1
           }) do
        {:subset, reason, tests} -> {:subset, "#{reason} (#{no_coverage})", tests}
        other -> other
      end
    end
  end

  defp emit(doc) do
    case doc do
      {:subset, reason, tests} -> ChgAdapter.emit(%{mode: "subset", reason: reason, tests: tests})
      {:all, reason} -> ChgAdapter.emit(%{mode: "all", reason: reason})
      {:error, why} -> ChgAdapter.emit(%{mode: "all", reason: why})
    end
  end
end
