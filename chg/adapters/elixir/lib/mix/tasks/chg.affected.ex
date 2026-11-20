defmodule Mix.Tasks.Chg.Affected do
  @shortdoc "Selects the tests a change affects (contract command `affected`)"
  @moduledoc """
  Prints the test files affected by the difference between `--base` and the working
  tree (`ChgAdapter.Select`).

      mix chg.affected --base <sha>

  A change that touches only comments and documentation (`ChgAdapter.DocOnly`) selects no
  tests, and its reason names the files treated as doc-only. Otherwise it selects by
  coverage when `chg` hands it a record in `CHG_COVER`
  (`ChgAdapter.Record.given/1`): the test files whose recorded run executed a module whose
  compiled code differs now, or that read a changed path `chg` names in `CHG_READ` (those
  matching `read_at_runtime`). Otherwise it selects from the module graph and
  the snapshot's test reference cache, and its reason says why coverage was not used.

  Prints `{"mode":"subset","reason":…,"tests":[…]}` (with `"read":true` when `CHG_READ`
  is set), or `{"mode":"all","reason":…}` when the selection cannot be trusted: no cache,
  an unreadable compile manifest, a deleted source the cache does not know, a change to a
  module every test runs, a change under a path dependency or umbrella sibling in the
  project (whose modules nothing records), or a path in `CHG_READ` with no record to say which tests read
  it, or read outside any one test file. `always_all` is applied by `chg adapter exec affected`
  before this task runs; called directly, this task does not apply it.
  """
  use Mix.Task

  alias ChgAdapter.{Digest, DocOnly, Graph, Record, Refs, Select}

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
           :ok <- ChgAdapter.path_dep_change(base),
           {:ok, graph} <- Graph.read() do
        with :code <- doc_only(base, changed, graph),
             {:error, why} <- by_coverage(base, changed, graph) do
          by_graph(changed, graph, why)
        else
          {:doc_only, files} -> {:subset, DocOnly.reason(files), []}
          selected -> selected
        end
      end

    emit(doc)
  end

  # Doc-only against the base AND against every commit selection would compare with (the
  # coverage record's, the snapshot reference cache's): selection also counts what changed
  # since those, so code changed there must not hide behind a doc-only diff. With neither,
  # selection could not run, and neither does this.
  defp doc_only(base, changed, graph) do
    refs =
      for {:ok, %{sha: sha}} <- [Record.given(base), Refs.read()], do: sha

    judged =
      for {sha, paths} <- [
            {base, {:ok, changed}} | Enum.map(refs, &{&1, ChgAdapter.changed_paths(&1)})
          ] do
        with {:ok, paths} <- paths, do: DocOnly.judge_tree(paths, sha, graph.external)
      end

    case judged do
      [{:doc_only, _} = verdict | rest] when rest != [] ->
        if Enum.all?(rest, &match?({:doc_only, _}, &1)), do: verdict, else: :code

      _ ->
        :code
    end
  end

  # Coverage selection when `chg` handed over a usable record.
  defp by_coverage(base, changed, graph) do
    with {:ok, record} <- Record.given(base),
         {:ok, since} <- ChgAdapter.changed_paths(record.sha),
         :ok <- ChgAdapter.path_dep_change(record.sha) do
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
        impl?: &protocol_impl?/1,
        read: ChgAdapter.read_paths(),
        not_read_by: ChgAdapter.not_read_by()
      })
    end
  end

  defp digest_cache, do: Path.join([Mix.Project.build_path(), "chg", "digests.etf"])

  defp protocol_impl?(m), do: Code.ensure_loaded?(m) and function_exported?(m, :__impl__, 1)

  # The module graph's selection: what `mix test --stale` would run.
  defp by_graph(changed, graph, no_coverage) do
    with {:ok, refs} <- Refs.read(),
         {:ok, since} <- ChgAdapter.changed_paths(refs.sha),
         :ok <- ChgAdapter.path_dep_change(refs.sha) do
      case Select.run(%{
             changed: changed,
             since_snapshot: since,
             graph: graph,
             refs: refs,
             test_files: ChgAdapter.test_files(),
             test_file?: &ChgAdapter.test_file?/1,
             exists?: &File.exists?/1,
             read: ChgAdapter.read_paths()
           }) do
        {:subset, reason, tests} -> {:subset, "#{reason} (#{no_coverage})", tests}
        other -> other
      end
    end
  end

  defp emit(doc) do
    case doc do
      {:subset, reason, tests} ->
        # Coverage selection accounts for `CHG_READ`; the graph's never returns a subset
        # with it set.
        read = if ChgAdapter.read_paths() != [], do: %{read: true}, else: %{}
        ChgAdapter.emit(Map.merge(%{mode: "subset", reason: reason, tests: tests}, read))

      {:all, reason} ->
        ChgAdapter.emit(%{mode: "all", reason: reason})

      {:error, why} ->
        ChgAdapter.emit(%{mode: "all", reason: why})
    end
  end
end
