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

        tests =
          for f <- input.test_files,
              selected?(f, direct, since, refs.tests, affected),
              do: f

        reason =
          "#{length(changed)} changed path(s), #{MapSet.size(modules)} changed module(s), " <>
            "#{MapSet.size(affected)} with dependents, #{length(unmapped)} path(s) outside the module graph"

        {:subset, reason, Enum.sort(tests)}
    end
  end

  defp selected?(f, direct, since, refs, affected) do
    MapSet.member?(direct, f) or MapSet.member?(since, f) or
      case Map.get(refs, f) do
        refs when is_list(refs) -> Enum.any?(refs, &MapSet.member?(affected, &1))
        _ -> true
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
