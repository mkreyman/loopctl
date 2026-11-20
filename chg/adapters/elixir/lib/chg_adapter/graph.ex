defmodule ChgAdapter.Graph do
  @moduledoc """
  The project's module graph, read from Mix's own compile manifest: which modules each
  source defines, which sources read each external resource, and who references whom.

  Dependents follow compile, export and runtime references transitively, exactly as
  `mix test --stale` does (`Mix.Compilers.Test.find_all_dependent_on/4`).
  `compile_dependents` keeps only compile and export references: the modules Mix
  recompiles when what they reference changes.
  """

  require Mix.Compilers.Elixir, as: CE

  defstruct source_modules: %{}, external: %{}, dependents: %{}, compile_dependents: %{}

  @type t :: %__MODULE__{
          source_modules: %{String.t() => [module()]},
          external: %{String.t() => [String.t()]},
          dependents: %{module() => [module()]},
          compile_dependents: %{module() => [module()]}
        }

  @doc """
  Reads the compile manifest of the current Mix env. `{:error, why}` when it is missing
  or written by an Elixir whose manifest format this adapter was not built against.
  """
  def read do
    case Mix.Tasks.Compile.Elixir.manifests() do
      [manifest] ->
        case CE.read_manifest(manifest) do
          {modules, sources} when is_map(modules) and is_map(sources) and modules != %{} ->
            {:ok, build(modules, sources)}

          _ ->
            {:error, "cannot read #{Path.relative_to_cwd(manifest)} (built by another Elixir?)"}
        end

      other ->
        {:error, "expected one Elixir compile manifest, found #{length(other)} (umbrella?)"}
    end
  end

  defp build(modules, sources) do
    source_modules =
      Enum.reduce(modules, %{}, fn {module, CE.module(sources: srcs)}, acc ->
        Enum.reduce(srcs, acc, &Map.update(&2, rel(&1), [module], fn ms -> [module | ms] end))
      end)

    external =
      Enum.reduce(sources, %{}, fn {src, CE.source(external: ext)}, acc ->
        Enum.reduce(ext, acc, fn e, acc ->
          Map.update(acc, rel(external_path(e)), [rel(src)], &[rel(src) | &1])
        end)
      end)

    by = fn refs_of ->
      Enum.reduce(sources, %{}, fn {src, rec}, acc ->
        defined = Map.get(source_modules, rel(src), [])
        Enum.reduce(refs_of.(rec), acc, &Map.update(&2, &1, defined, fn ds -> defined ++ ds end))
      end)
    end

    compile = &(CE.source(&1, :compile_references) ++ CE.source(&1, :export_references))

    %__MODULE__{
      source_modules: source_modules,
      external: external,
      dependents: by.(&(compile.(&1) ++ CE.source(&1, :runtime_references))),
      compile_dependents: by.(compile)
    }
  end

  # Elixir 1.19 and 1.20 record an external resource as `{path, {mtime, size}, digest}`.
  defp external_path(t) when is_tuple(t), do: elem(t, 0)
  defp external_path(path), do: path

  defp rel(path), do: Path.relative_to_cwd(to_string(path))

  @doc "`modules` plus every module that references one of them, transitively."
  def with_dependents(%__MODULE__{dependents: deps}, modules) do
    walk(Enum.to_list(modules), deps, MapSet.new(modules))
  end

  defp walk([], _deps, seen), do: seen

  defp walk([m | rest], deps, seen) do
    new = deps |> Map.get(m, []) |> Enum.reject(&MapSet.member?(seen, &1))
    walk(new ++ rest, deps, Enum.into(new, seen))
  end
end
