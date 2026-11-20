defmodule ChgAdapter.Refs do
  @moduledoc """
  The test reference cache: for every test file, the modules it references, plus which
  modules each source defined and which sources read each external resource, all at the
  snapshot revision (so a path deleted since can still be mapped).

  `mix test --stale` keeps the same data in `compile.test_stale`, but writes it only after
  a run with zero failures, and `--stale --dry-run` ignores it (Elixir 1.20.4,
  `Mix.Compilers.Test.require_and_run/3`), so it cannot drive a selection without running
  the suite. This cache is built by compiling the test files without running them.
  """

  alias ChgAdapter.Graph

  @vsn 3

  def path, do: Path.join(ChgAdapter.state_dir(), "test_refs.etf")

  @doc "The cache, or `{:error, why}`."
  def read do
    with {:ok, bin} <- File.read(path()),
         %{vsn: @vsn} = refs <- safe_decode(bin) do
      {:ok, refs}
    else
      {:error, :enoent} -> {:error, "no test reference cache (run `mix chg.snapshot`)"}
      _ -> {:error, "unreadable test reference cache #{path()}"}
    end
  end

  defp safe_decode(bin) do
    :erlang.binary_to_term(bin)
  rescue
    _ -> :invalid
  end

  @doc """
  Rebuilds the cache for revision `sha`, compiling every test file. A file's references
  also depend on the macros it expands (`use MyApp.DataCase`), so an unchanged file can
  still gain or lose references: none is reused from a previous cache. Returns
  `{computed, unknown}` counts.
  """
  def build!(sha, %Graph{} = graph) do
    files = ChgAdapter.test_files()
    computed = compile_refs(files)
    tests = Map.new(files, &{&1, Map.get(computed, &1, :unknown)})

    ChgAdapter.write_atomic!(
      path(),
      :erlang.term_to_binary(
        %{
          vsn: @vsn,
          sha: sha,
          tests: tests,
          source_modules: graph.source_modules,
          external: graph.external
        },
        [:compressed]
      )
    )

    {map_size(computed), Enum.count(tests, &match?({_, :unknown}, &1))}
  end

  # Compiles the test files in this VM with ExUnit loaded but not running, recording each
  # file's compile and runtime references from its lexical tracker: the two `mix test
  # --stale` matches against stale modules (Mix.Compilers.Test, Elixir 1.20.4). A file
  # that does not compile on its own is left out and stays `:unknown`, which selects it.
  defp compile_refs([]), do: %{}

  defp compile_refs(files) do
    {:ok, _} = Application.ensure_all_started(:ex_unit)
    ExUnit.start(autorun: false)
    {:ok, agent} = Agent.start_link(fn -> %{} end)
    cwd = File.cwd!()

    each_file = fn file, lexical ->
      {compile, _export, runtime, _env} = Kernel.LexicalTracker.references(lexical)
      refs = Enum.uniq(compile ++ runtime)
      Agent.update(agent, &Map.put(&1, Path.relative_to(file, cwd), refs))
    end

    case Kernel.ParallelCompiler.require(files, each_file: each_file, return_diagnostics: true) do
      {:ok, _, _} ->
        :ok

      {:error, errors, _} ->
        IO.puts(
          :standard_error,
          "chg: #{length(errors)} test file(s) did not compile without the test helper; they will always be selected"
        )
    end

    Agent.get(agent, & &1)
  after
    Code.unrequire_files(files)
  end
end
