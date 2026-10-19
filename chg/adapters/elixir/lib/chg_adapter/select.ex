defmodule ChgAdapter.Select do
  @moduledoc """
  Affected-test selection. Pure: every input is passed in, so it is tested without a
  project.

  A test file is selected when:
    * it changed since the base, or since the snapshot its references were recorded at
      (those references may be stale);
    * it has no recorded references (new, or did not compile on its own);
    * it has a compile or runtime reference to a module defined in a changed source, or
      in a source that reads a changed external resource, or to any module that
      transitively references one.

  `always_all` is not applied here: `chg` applies it before calling the adapter.
  """

  alias ChgAdapter.Graph

  @type input :: %{
          changed: [String.t()],
          since_snapshot: [String.t()],
          graph: Graph.t(),
          refs: map(),
          test_files: [String.t()],
          test_file?: (String.t() -> boolean()),
          exists?: (String.t() -> boolean())
        }

  @spec run(input()) :: {:all, String.t()} | {:subset, String.t(), [String.t()]}
  def run(%{changed: changed, graph: graph, refs: refs} = input) do
    {tests_changed, others} = Enum.split_with(changed, input.test_file?)

    case modules_of(others, graph, refs, input.exists?) do
      {:error, why} ->
        {:all, why}

      {:ok, modules, unmapped} ->
        affected = Graph.with_dependents(graph, modules)
        since = MapSet.new(Enum.filter(input.since_snapshot, input.test_file?))
        direct = MapSet.new(tests_changed)

        why =
          for f <- input.test_files, w = why(f, direct, since, refs.tests, affected), do: {f, w}

        counts = Enum.frequencies_by(why, &elem(&1, 1))
        count = &Map.get(counts, &1, 0)

        reason =
          "#{length(changed)} changed path(s), #{MapSet.size(modules)} changed module(s), " <>
            "#{MapSet.size(affected)} with dependents, #{length(unmapped)} path(s) outside the module graph; " <>
            "#{length(why)} of #{length(input.test_files)} test file(s): " <>
            "#{count.(:changed)} changed since the base, #{count.(:since_snapshot)} since the snapshot, " <>
            "#{count.(:unreferenced)} without recorded references, " <>
            "#{count.(:references)} referencing an affected module"

        {:subset, reason, why |> Enum.map(&elem(&1, 0)) |> Enum.sort()}
    end
  end

  # Why a test file is selected, the first reason that holds, or nil. One reason per
  # file, so the reason's counts add up to the selection.
  defp why(f, direct, since, refs, affected) do
    cond do
      MapSet.member?(direct, f) -> :changed
      MapSet.member?(since, f) -> :since_snapshot
      not is_list(Map.get(refs, f)) -> :unreferenced
      Enum.any?(Map.fetch!(refs, f), &MapSet.member?(affected, &1)) -> :references
      true -> nil
    end
  end

  @type coverage_input :: %{
          changed: [String.t()],
          since_record: [String.t()],
          record: map(),
          digests: %{module() => binary()},
          graph: Graph.t(),
          test_files: [String.t()],
          test_file?: (String.t() -> boolean()),
          test_path?: (String.t() -> boolean()),
          impl?: (module() -> boolean())
        }

  @doc """
  Coverage selection: the test files that executed a module this change alters, by the
  record of a full run on an earlier commit (`ChgAdapter.Record`).

  The question is which tests could now fail although they passed in the record's run,
  so everything is compared with the record, not with the base. A module is altered when
  its compiled digest differs from the record's (a compile-time effect, such as a macro or
  struct default expanded into it, counts), when it is new or gone, or when it reads an
  `@external_resource` that changed since the base or the record (it may read the file at
  run time too, which no digest sees). A source edit that leaves the compiled code as it
  was (a comment, a line shift, a revert to the record's code) alters nothing. A test file
  is selected when:
    * it changed since the base, or since the record (its coverage may be stale);
    * the record has no coverage for it (new, or it did not run);
    * its recorded coverage includes an altered module.

  The whole suite runs when an altered module ran outside any one test file's window (the
  record's `global`: at boot, between tests), when a new module is a protocol implementation (protocol
  dispatch reaches it with no call that names it), and when a file under the test paths
  that is not a test and defines no module (test data) changed since the base or the
  record.
  """
  @spec by_coverage(coverage_input()) :: {:all, String.t()} | {:subset, String.t(), [String.t()]}
  def by_coverage(%{record: record, digests: digests} = input) do
    {tests_changed, _} = Enum.split_with(input.changed, input.test_file?)
    others = Enum.uniq(input.changed ++ input.since_record) |> Enum.reject(input.test_file?)
    # A deleted source needs no map here: its modules are in the record's digests and not
    # in the current ones, so they count as altered below.
    snapshot = %{source_modules: %{}, external: %{}}
    %{source_modules: defines, external: readers} = input.graph

    with {:ok, _, unmapped} <- modules_of(others, input.graph, snapshot, fn _ -> true end),
         :ok <- no_test_data(unmapped, input.test_path?) do
      sourced =
        for p <- others,
            src <- Map.get(readers, p, []),
            m <- Map.get(defines, src, []),
            into: MapSet.new(),
            do: m

      old = record.digests
      new_mods = for m <- Map.keys(digests), not Map.has_key?(old, m), do: m

      altered =
        for({m, d} <- digests, Map.get(old, m) != d, do: m)
        |> Enum.concat(for m <- Map.keys(old), not Map.has_key?(digests, m), do: m)
        |> Enum.into(sourced)

      global = MapSet.new(record.global)

      cond do
        m = Enum.find(altered, &MapSet.member?(global, &1)) ->
          {:all,
           "#{inspect(m)} changed, and it ran outside any one test file (the record's global)"}

        m = Enum.find(new_mods, input.impl?) ->
          {:all, "new protocol implementation #{inspect(m)}"}

        true ->
          direct = MapSet.new(tests_changed ++ Enum.filter(input.since_record, input.test_file?))

          tests =
            for f <- input.test_files,
                MapSet.member?(direct, f) or covers?(Map.get(record.cover, f), altered),
                do: f

          reason =
            "coverage of #{String.slice(record.sha, 0, 12)} (#{Map.get(record, :age, 0)} commit(s) behind): " <>
              "#{MapSet.size(altered)} altered module(s), #{length(tests)} of #{length(input.test_files)} test file(s)"

          {:subset, reason, Enum.sort(tests)}
      end
    else
      {:error, why} -> {:all, why}
    end
  end

  defp covers?(nil, _altered), do: true
  defp covers?(mods, altered), do: Enum.any?(mods, &MapSet.member?(altered, &1))

  defp no_test_data(unmapped, test_path?) do
    case Enum.find(unmapped, test_path?) do
      nil -> :ok
      p -> {:error, "#{p} is under the test paths and is not a test: test data changed"}
    end
  end

  # The modules a changed non-test path stands for, through the current graph and the
  # snapshot's: a deleted source or external resource is only in the snapshot's. A deleted
  # Elixir source neither knows cannot be mapped, and an unmapped deletion could hide a
  # dependent, so it fails closed.
  defp modules_of(paths, graph, snapshot, exists?) do
    Enum.reduce_while(paths, {:ok, MapSet.new(), []}, fn p, {:ok, mods, unmapped} ->
      found =
        defined_by(p, graph.source_modules, graph.external) ++
          defined_by(p, snapshot.source_modules, snapshot.external)

      cond do
        found != [] ->
          {:cont, {:ok, Enum.into(found, mods), unmapped}}

        elixir_source?(p) and not exists?.(p) ->
          {:halt, {:error, "deleted #{p} is not in the snapshot's module map"}}

        true ->
          {:cont, {:ok, mods, [p | unmapped]}}
      end
    end)
  end

  defp defined_by(path, source_modules, external) do
    Map.get(source_modules, path, []) ++
      Enum.flat_map(Map.get(external, path, []), &Map.get(source_modules, &1, []))
  end

  defp elixir_source?(p), do: String.ends_with?(p, ".ex")
end
