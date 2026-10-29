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

  `always_all` is not applied here: `chg` applies it before calling the adapter. Nor is
  `read_at_runtime`: `chg` names the changed paths it matches (`read`), and with no
  coverage record to say which tests read them, the whole suite runs.
  """

  alias ChgAdapter.Graph

  @type input :: %{
          changed: [String.t()],
          since_snapshot: [String.t()],
          graph: Graph.t(),
          refs: map(),
          test_files: [String.t()],
          test_file?: (String.t() -> boolean()),
          exists?: (String.t() -> boolean()),
          read: [String.t()]
        }

  @spec run(input()) :: {:all, String.t()} | {:subset, String.t(), [String.t()]}
  def run(%{read: [p | _]}),
    do:
      {:all,
       "#{p} is read at run time (read_at_runtime), and no coverage record says by which tests"}

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
          impl?: (module() -> boolean()),
          read: [String.t()],
          not_read_by: [String.t()]
        }

  # Changes that reach compiled code outside the module graph: compile-time config, deps,
  # the toolchain, and any source the graph does not map to a module (an in-repo path
  # dependency, a script, a template no module declares). With one of them every digest
  # is compared, flapping ones included.
  @gating_off ["config/", "mix.exs", "mix.lock", ".tool-versions", "deps/"]
  @source_exts ~w(.ex .exs .erl .hrl .eex .heex .leex .neex .sface .yrl .xrl)

  defp gating_off?(p, graph) do
    Enum.any?(
      @gating_off,
      &(p == &1 or (String.ends_with?(&1, "/") and String.starts_with?(p, &1)))
    ) or
      (Path.extname(p) in @source_exts and not Map.has_key?(graph.source_modules, p) and
         not Map.has_key?(graph.external, p))
  end

  # The modules whose compiled code `others` or the deletion of `gone` can reach; :all
  # when a change outside the module graph can reach any.
  defp candidates(others, graph, sourced, gone) do
    if p = Enum.find(others, &gating_off?(&1, graph)) do
      {:all, p}
    else
      changed =
        for p <- others,
            m <- Map.get(graph.source_modules, p, []),
            into: Enum.into(gone, sourced),
            do: m

      reach = Graph.with_dependents(graph, changed)
      compile = Map.get(graph, :compile_dependents, %{})

      {:some, for(m <- reach, d <- Map.get(compile, m, []), into: changed, do: d)}
    end
  end

  @doc """
  Coverage selection: the test files that executed a module this change alters, by the
  record of a full run on an earlier commit (`ChgAdapter.Record`).

  The question is which tests could now fail although they passed in the record's run,
  so everything is compared with the record, not with the base. A module is altered when
  it is new or gone, when it reads an `@external_resource` that changed since the base or
  the record (it may read the file at run time too, which no digest sees), or when it is a
  candidate and its compiled digest differs from the record's (a compile-time effect, such
  as a macro or struct default expanded into it, counts). A source edit that leaves the
  compiled code as it was (a comment, a line shift, a revert to the record's code) alters
  nothing.

  The candidates are the modules whose compiled code a change can reach, by the rule Mix
  recompiles by: those defined in a changed source or reading a changed external
  resource, and those with a compile or export reference to any module that reaches one
  of them through references of any kind (a compile-time dependency is transitive over
  the runtime ones). Only they are compared, because two compiles of one commit still do
  not always give one bytecode: OTP orders a map of more than 32 keys by a hash which,
  for the atoms the VM starts with (`:state`, `:temporary`), differs from one VM run to
  the next, so code generated by iterating one (struct field lists, encoders, a large
  LiveView's change tracking) comes out reordered. On HCB about 5 of 2817 digests differ
  between two clean builds of one commit even with `mix chg.compile`'s preloaded atoms,
  and those modules run in hundreds of test files. A change to what the module graph does
  not see (`@gating_off`: config, deps, the toolchain, or a source no module in the graph
  is defined in or declares as an external resource) compares every module. A deleted
  module's compile dependents are candidates too.

  A test file is selected when:
    * it changed since the base, or since the record (its coverage may be stale);
    * the record has no coverage for it (new, or it did not run);
    * its recorded coverage includes an altered module;
    * it read a path in `read` (the changed paths matching `read_at_runtime`), or listed
      a directory above one (a new or deleted file changes a listing), or it started a
      subprocess, whose reads are not recorded (one of the manifest's `not_read_by`
      excepted).

  The whole suite runs when a path in `read` was read outside any one test file's window
  (the record's `global_reads`), or a subprocess started there, when an altered module ran outside any one test file's window (the
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

    # Callers and records from before `read_at_runtime` carry none of these.
    read = Map.get(input, :read, [])
    ignored = Map.get(input, :not_read_by, [])
    reads = Map.new(Map.get(record, :reads, %{}), fn {f, r} -> {f, unignored(r, ignored)} end)
    global_reads = unignored(Map.get(record, :global_reads, []), ignored)

    with {:ok, _, unmapped} <- modules_of(others, input.graph, snapshot, fn _ -> true end),
         :ok <- no_test_data(unmapped -- read, input.test_path?),
         :ok <- not_read_globally(read, global_reads) do
      sourced =
        for p <- others,
            src <- Map.get(readers, p, []),
            m <- Map.get(defines, src, []),
            into: MapSet.new(),
            do: m

      old = record.digests
      new_mods = for m <- Map.keys(digests), not Map.has_key?(old, m), do: m

      # A deleted module's compile dependents recompile without it, so they are candidates.
      gone = for m <- Map.keys(old), not Map.has_key?(digests, m), do: m
      gate = candidates(others, input.graph, sourced, gone)

      compared? =
        case gate do
          {:all, _} -> fn _ -> true end
          {:some, set} -> &MapSet.member?(set, &1)
        end

      altered =
        for(
          {m, d} <- digests,
          Map.get(old, m) != d,
          not Map.has_key?(old, m) or compared?.(m),
          do: m
        )
        |> Enum.concat(gone)
        |> Enum.into(sourced)

      compared =
        case gate do
          {:all, p} -> "every module compared (#{p} changed)"
          {:some, set} -> "#{MapSet.size(set)} module(s) compared"
        end

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
                MapSet.member?(direct, f) or covers?(Map.get(record.cover, f), altered) or
                  reads_any?(Map.get(reads, f), read),
                do: f

          reason =
            "coverage of #{String.slice(record.sha, 0, 12)} (#{Map.get(record, :age, 0)} commit(s) behind): " <>
              "#{compared}, #{MapSet.size(altered)} altered module(s), #{length(read)} changed path(s) read at run time, " <>
              "#{length(tests)} of #{length(input.test_files)} test file(s)"

          {:subset, reason, Enum.sort(tests)}
      end
    else
      {:error, why} -> {:all, why}
    end
  end

  defp covers?(nil, _altered), do: true
  defp covers?(mods, altered), do: Enum.any?(mods, &MapSet.member?(altered, &1))

  defp reads_any?(_reads, []), do: false
  defp reads_any?(nil, _read), do: true
  defp reads_any?(reads, read), do: spawned(reads) != nil or Enum.any?(read, &read?(reads, &1))

  defp not_read_globally([], _global), do: :ok

  defp not_read_globally([p | _] = read, global) do
    cond do
      name = spawned(global) ->
        {:error,
         "#{p} is read at run time, and a subprocess (#{name}) started outside any one test file (the record's global_reads)"}

      q = Enum.find(read, &read?(global, &1)) ->
        {:error, "#{q} was read outside any one test file (the record's global_reads)"}

      true ->
        :ok
    end
  end

  defp unignored(reads, []), do: reads

  defp unignored(reads, ignored),
    do: Enum.reject(reads, fn r -> match?({:spawn, _}, r) and elem(r, 1) in ignored end)

  defp spawned(reads),
    do: Enum.find_value(reads, fn r -> match?({:spawn, _}, r) and elem(r, 1) end)

  # Whether one of `reads` is `path`, or a listing (`dir/`) of a directory above it.
  defp read?(reads, path) do
    Enum.any?(reads, fn
      {:spawn, _} -> false
      "./" -> true
      r -> r == path or (String.ends_with?(r, "/") and String.starts_with?(path, r))
    end)
  end

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
